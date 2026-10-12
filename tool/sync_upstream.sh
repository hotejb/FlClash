#!/usr/bin/env bash
# Replays the fork's commits onto the official FlClash dev branch, then replays
# the FlClash layer of the mihomo Core on top of MetaCubeX's latest Alpha. The
# result is kept only when tool/verify_sync.sh passes; otherwise the branch and
# the Core go back to where they started. Only --push pushes; --push-main also
# moves the fork's main to the same commit.
set -euo pipefail

# Bash reads a script as it runs, and the replay below rewrites this file.
if [[ -z "${SYNC_UPSTREAM_ROOT:-}" ]]; then
  root="$(cd "$(dirname "$0")/.." && pwd)"
  copy="$(mktemp -t sync_upstream)"
  cp "$0" "$copy"
  SYNC_UPSTREAM_ROOT="$root" exec bash "$copy" "$@"
fi
rm -f "$0"
cd "$SYNC_UPSTREAM_ROOT"

UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-origin}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-dev}"
MIHOMO_URL="https://github.com/MetaCubeX/mihomo.git"
CORE_PATH="core/Clash.Meta"
CORE_BRANCH="alpha-flclash"
CORE_TAG_PREFIX="flclash-core"
FORK_REMOTE="${FORK_REMOTE:-hotejb}"
BASE_REF="refs/sync/upstream-base"
CORE_COMMIT_SUBJECT="build(core): rebase the FlClash Core layer onto mihomo Alpha"
app_upstream=""

do_app=1
do_core=1
do_push=0
push_main=0
verify_args=()
for arg in "$@"; do
  case "$arg" in
    --app-only) do_core=0 ;;
    --core-only) do_app=0 ;;
    --full) verify_args+=(--full) ;;
    --push) do_push=1 ;;
    --push-main)
      do_push=1
      push_main=1
      ;;
    -h | --help)
      echo "usage: tool/sync_upstream.sh [--app-only | --core-only] [--full] [--push | --push-main]"
      exit 0
      ;;
    *)
      echo "unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

core() { git -C "$CORE_PATH" "$@"; }

if [[ -z "$(git branch --show-current)" ]]; then
  echo "check out a branch first" >&2
  exit 1
fi
if ! git diff --cached --quiet; then
  echo "staged changes present; commit or unstage them first" >&2
  exit 1
fi
if [[ -e "$(git rev-parse --git-path MERGE_HEAD)" || -e "$(git rev-parse --git-path CHERRY_PICK_HEAD)" ]]; then
  echo "a merge or cherry-pick is already in progress" >&2
  exit 1
fi

start_head="$(git rev-parse HEAD)"
start_checkout="$(core rev-parse HEAD)"
start_layer="$(core rev-parse --verify --quiet "refs/heads/$CORE_BRANCH" || true)"
ok=0

rollback() {
  echo "sync failed, restoring $(git rev-parse --short "$start_head")" >&2
  git cherry-pick --abort 2>/dev/null || true
  core rebase --abort 2>/dev/null || true
  git reset --keep "$start_head"
  core checkout --quiet --detach "$start_checkout"
  if [[ -n "$start_layer" ]]; then
    core branch -f "$CORE_BRANCH" "$start_layer"
  fi
}

on_exit() {
  local status=$?
  if ((!ok)); then
    rollback
  fi
  exit "$status"
}
trap on_exit EXIT

# The official dev branch gets rewritten, so a merge would replay its old and
# new histories against each other. The fork's own commits are replayed onto
# the new tip instead, from the upstream commit the last sync built on.
sync_app() {
  local ref="$UPSTREAM_REMOTE/$UPSTREAM_BRANCH" upstream base commits
  echo "==> app: fetching $ref"
  git fetch --quiet --no-recurse-submodules "$UPSTREAM_REMOTE" "$UPSTREAM_BRANCH"
  upstream="$(git rev-parse "$ref")"
  if ! base="$(git rev-parse --quiet --verify "$BASE_REF")"; then
    base="$(git merge-base "$ref" HEAD)"
    echo "    no $BASE_REF yet, assuming the merge base ${base:0:8}"
  fi
  if [[ "$base" == "$upstream" ]]; then
    echo "    already on $ref ${upstream:0:8}"
    return
  fi
  commits="$(git log --reverse --no-merges --format='%H %s' "$base..HEAD" |
    grep -v " $CORE_COMMIT_SUBJECT" | cut -d' ' -f1 || true)"
  echo "    replaying $(grep -c . <<<"$commits" || true) fork commit(s) onto $ref ${upstream:0:8}"

  git reset --quiet --keep "$upstream"
  # shellcheck disable=SC2086
  if [[ -n "$commits" ]] && ! git cherry-pick --empty=drop $commits; then
    echo "replaying the fork commits onto $ref failed:" >&2
    git --no-pager diff --name-only --diff-filter=U >&2
    exit 1
  fi
  app_upstream="$upstream"
}

sync_core() {
  local pointer alpha base count new
  pointer="$(git rev-parse "HEAD:$CORE_PATH")"
  echo "==> core: fetching mihomo Alpha"
  core remote get-url upstream >/dev/null 2>&1 || core remote add upstream "$MIHOMO_URL"
  core fetch --quiet upstream Alpha
  if ! core cat-file -e "$pointer^{commit}" 2>/dev/null; then
    core fetch --quiet origin || true
    core fetch --quiet flclash || true
  fi
  if ! core cat-file -e "$pointer^{commit}" 2>/dev/null; then
    echo "Core commit $pointer is in no remote of $CORE_PATH" >&2
    exit 1
  fi

  alpha="$(core rev-parse upstream/Alpha)"
  if core merge-base --is-ancestor "$alpha" "$pointer"; then
    echo "    already on Alpha ${alpha:0:8}"
    return
  fi
  base="$(core merge-base "$pointer" "$alpha")"
  count="$(core rev-list --count "$base..$pointer")"
  echo "    replaying $count layer commit(s) ${base:0:8}..${pointer:0:8} onto Alpha ${alpha:0:8}"

  core checkout --quiet --detach "$pointer"
  if ! core rebase --quiet --onto "$alpha" "$base"; then
    echo "the FlClash layer conflicts with Alpha ${alpha:0:8}; resolve it by hand" >&2
    exit 1
  fi
  new="$(core rev-parse HEAD)"
  core branch -f "$CORE_BRANCH" "$new"

  (cd core && go mod tidy)
  git add "$CORE_PATH" core/go.mod core/go.sum
  git commit --quiet -F - <<EOF
$CORE_COMMIT_SUBJECT ${alpha:0:8}

The layer (${count} commit) moves from ${base:0:8} to Alpha ${alpha:0:8}, and
core/go.mod follows the dependency bumps that came with it.

Changelog: skip
EOF
}

push_core_tag() {
  local url="$1" commit="$2" tag
  tag="$CORE_TAG_PREFIX/$(core rev-parse --short=12 "$commit")"
  if [[ -z "$(core ls-remote --tags "$url" "refs/tags/$tag")" ]]; then
    core push --quiet "$url" "$commit:refs/tags/$tag"
    echo "    tagged ${commit:0:8} as $tag"
  fi
}

# Every rebase onto a new Alpha rewrites the layer branch, so each Core commit
# the main repo has ever pointed at also gets an immutable tag on the fork; a
# checkout of any older commit can still fetch its Core after the force push.
# The submodule's own origin follows whatever .gitmodules was last synced from,
# which an official checkout points at chen08209, so push to the tracked URL.
push_all() {
  local pointer remote_layer branch url
  pointer="$(git rev-parse "HEAD:$CORE_PATH")"
  branch="$(git branch --show-current)"
  url="$(git config -f .gitmodules --get "submodule.$CORE_PATH.url")"

  echo "==> pushing the Core to $url"
  push_core_tag "$url" "$pointer"
  remote_layer="$(core ls-remote --heads "$url" "$CORE_BRANCH" | cut -f1)"
  if [[ -n "$remote_layer" ]]; then
    core cat-file -e "$remote_layer^{commit}" 2>/dev/null || core fetch --quiet "$url" "$CORE_BRANCH"
    push_core_tag "$url" "$remote_layer"
  fi
  if [[ "$remote_layer" != "$pointer" ]]; then
    core push --quiet --force-with-lease="refs/heads/$CORE_BRANCH:$remote_layer" "$url" "$pointer:refs/heads/$CORE_BRANCH"
    echo "    $CORE_BRANCH -> ${pointer:0:8}"
  fi

  local targets=("$branch") target remote_tip
  if ((push_main)) && [[ "$branch" != "main" ]]; then
    targets+=(main)
  fi
  for target in "${targets[@]}"; do
    echo "==> pushing $branch to $FORK_REMOTE/$target"
    remote_tip="$(git ls-remote --heads "$FORK_REMOTE" "$target" | cut -f1)"
    git push --force-with-lease="refs/heads/$target:$remote_tip" "$FORK_REMOTE" "HEAD:refs/heads/$target"
  done
}

((do_app)) && sync_app
((do_core)) && sync_core

echo "==> verifying"
tool/verify_sync.sh ${verify_args[@]+"${verify_args[@]}"}
ok=1
if [[ -n "$app_upstream" ]]; then
  git update-ref "$BASE_REF" "$app_upstream"
fi

echo
echo "sync done: $(git rev-parse --short "$start_head")..$(git rev-parse --short HEAD)"
if ((do_push)); then
  push_all
else
  echo "Push the Core and $(git branch --show-current) with: tool/sync_upstream.sh --push"
fi
