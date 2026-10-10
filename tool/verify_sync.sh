#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

full=0
case "${1:-}" in
  "") ;;
  --full) full=1 ;;
  *)
    echo "usage: tool/verify_sync.sh [--full]" >&2
    exit 2
    ;;
esac

step() { echo "==> $1"; }

verify_core() {
  step "core: build, vet, test"
  (
    cd core
    export CGO_ENABLED=0
    go build -o /dev/null ./cmd/...
    go vet . ./cmd/...
    GOOS=linux go vet ./platform
    go test -count=1 .
  )
}

# The gomobile AAR only builds inside Gradle. Vetting the packages it binds
# catches a Core API change the Android side depends on; arm64 is the only
# Android target Go accepts without cgo, which is why CI vets just that one.
verify_android_core() {
  local tags
  tags="$(sed -n 's/^tags: *//p' build_config.yaml)"
  step "core: android/arm64"
  (cd core && CGO_ENABLED=0 GOOS=android GOARCH=arm64 go vet "-tags=$tags" . ./mobile ./tun ./platform)
}

verify_dart() {
  step "dart: pub get, analyze, setup_hooks tests"
  flutter pub get
  # Only tracked paths: an untracked checkout under vendor/ must not decide it.
  local paths
  paths="$(git ls-files '*.dart' | awk -F/ '{print (NF > 1 ? $1 : $0)}' | sort -u)"
  # shellcheck disable=SC2086
  flutter analyze --no-fatal-infos $paths
  (cd plugins/setup/setup_hooks && dart pub get >/dev/null && dart test)
}

verify_full() {
  step "dart: flutter test"
  flutter test
  step "android: dart setup.dart android"
  dart setup.dart android
}

verify_core
verify_android_core
verify_dart
if ((full)); then
  verify_full
fi

echo "==> verify_sync: passed"
