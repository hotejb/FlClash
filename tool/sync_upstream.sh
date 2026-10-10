#!/usr/bin/env bash
# Merges the official FlClash dev branch, then replays the FlClash layer of the
# mihomo Core on top of MetaCubeX's latest Alpha. The result is kept only when
# tool/verify_sync.sh passes; otherwise the branch and the Core go back to where
# they started. Nothing is pushed.
set -euo pipefail

cd "$(dirname "$0")/.."

UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-origin}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-dev}"
MIHOMO_URL="https://github.com/MetaCubeX/mihomo.git"
CORE_PATH="core/Clash.Meta"
CORE_BRANCH="alpha-flclash"
CORE_TAG_PREFIX="flclash-core"
FORK_REMOTE="${FORK_REMOTE:-hotejb}"

do_app=1
do_core=1
do_push=0
verify_args=()
for arg in "$@"; do
  case "$arg" in
    --app-only) do_core=0 ;;
    --core-only) do_app=0 ;;
    --full) verify_args+=(--full) ;;
    --push) do_push=1 ;;
    -h | --help)
      echo "usage: tool/sync_upstream.sh [--app-only | --core-only] [--full] [--push]"
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
if [[ -e "$(git rev-parse --git-path MERGE_HEAD)" ]]; then
  echo "a merge is already in progress" >&2
  exit 1
fi

start_head="$(git rev-parse HEAD)"
start_checkout="$(core rev-parse HEAD)"
start_layer="$(core rev-parse --verify --quiet "refs/heads/$CORE_BRANCH" || true)"
ok=0

rollback() {
  echo "sync failed, restoring $(git rev-parse --short "$start_head")" >&2
  git merge --abort 2>/dev/null || true
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

sync_app() {
  local ref="$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"
  echo "==> app: fetching $ref"
  git fetch --quiet "$UPSTREAM_REMOTE" "$UPSTREAM_BRANCH"
  if git merge-base --is-ancestor "$ref" HEAD; then
    echo "    already contains $ref"
    return
  fi
  if git merge --no-edit "$ref"; then
    return
  fi
  # Both sides moved the Core pointer; the Core step recomputes it anyway.
  if [[ "$(git diff --name-only --diff-filter=U)" == "$CORE_PATH" ]]; then
    git update-index --cacheinfo "160000,$(git rev-parse "$ref:$CORE_PATH"),$CORE_PATH"
    git commit --no-edit
    return
  fi
  echo "merging $ref failed:" >&2
  git diff --name-only --diff-filter=U >&2
  exit 1
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
build(core): rebase the FlClash Core layer onto mihomo Alpha ${alpha:0:8}

The layer (${count} commit) moves from ${base:0:8} to Alpha ${alpha:0:8}, and
core/go.mod follows the dependency bumps that came with it.

Changelog: skip
EOF
}

push_core_tag() {
  local commit="$1" tag
  tag="$CORE_TAG_PREFIX/$(core rev-parse --short=12 "$commit")"
  if [[ -z "$(core ls-remote --tags origin "refs/tags/$tag")" ]]; then
    core push --quiet origin "$commit:refs/tags/$tag"
    echo "    tagged ${commit:0:8} as $tag"
  fi
}

# Every rebase onto a new Alpha rewrites the layer branch, so each Core commit
# the main repo has ever pointed at also gets an immutable tag on the fork; a
# checkout of any older commit can still fetch its Core after the force push.
push_all() {
  local pointer remote_layer branch
  pointer="$(git rev-parse "HEAD:$CORE_PATH")"
  branch="$(git branch --show-current)"

  echo "==> pushing the Core to $(core remote get-url origin)"
  push_core_tag "$pointer"
  remote_layer="$(core ls-remote --heads origin "$CORE_BRANCH" | cut -f1)"
  if [[ -n "$remote_layer" ]]; then
    core cat-file -e "$remote_layer^{commit}" 2>/dev/null || core fetch --quiet origin "$CORE_BRANCH"
    push_core_tag "$remote_layer"
  fi
  if [[ "$remote_layer" != "$pointer" ]]; then
    core push --quiet --force-with-lease="$CORE_BRANCH:$remote_layer" origin "$pointer:refs/heads/$CORE_BRANCH"
    echo "    $CORE_BRANCH -> ${pointer:0:8}"
  fi

  echo "==> pushing $branch to $FORK_REMOTE"
  git push "$FORK_REMOTE" "$branch"
}

((do_app)) && sync_app
((do_core)) && sync_core

echo "==> verifying"
tool/verify_sync.sh ${verify_args[@]+"${verify_args[@]}"}
ok=1

echo
echo "sync done: $(git rev-parse --short "$start_head")..$(git rev-parse --short HEAD)"
if ((do_push)); then
  push_all
else
  echo "Push the Core and $(git branch --show-current) with: tool/sync_upstream.sh --push"
fi
