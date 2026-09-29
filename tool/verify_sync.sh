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

skipped=()

step() { echo "==> $1"; }
skip() {
  echo "    skipped: $1"
  skipped+=("$1")
}

version_of() {
  sed -n "s/^$1 = \"\(.*\)\"/\1/p" android/gradle/libs.versions.toml
}

ndk_bin() {
  local sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
  local host
  host="$(uname -s | tr '[:upper:]' '[:lower:]')"
  echo "$sdk/ndk/$(version_of ndkVersion)/toolchains/llvm/prebuilt/${host}-x86_64/bin"
}

verify_core() {
  step "core: build, vet, test"
  (cd core && go build -o /dev/null ./... && go vet ./... && go test ./...)
}

verify_android_core() {
  local bin api
  bin="$(ndk_bin)"
  api="$(version_of minSdk)"
  if [[ ! -d "$bin" ]]; then
    skip "android core (NDK $(version_of ndkVersion) not installed)"
    return
  fi
  local spec arch triple
  for spec in arm64:aarch64-linux-android arm:armv7a-linux-androideabi amd64:x86_64-linux-android; do
    arch="${spec%%:*}"
    triple="${spec#*:}"
    step "core: android/$arch"
    (
      cd core
      GOOS=android GOARCH="$arch" CGO_ENABLED=1 CC="$bin/${triple}${api}-clang" \
        go build -tags with_gvisor -buildmode=c-shared -o /dev/null .
    )
  done
}

# Everything the Swift side calls into or installs, so a build tag that quietly
# drops an iOS file fails here rather than at link time in Xcode.
verify_ios_symbols() {
  local archive="$1" symbols symbol
  symbols="$(nm "$archive" 2>/dev/null)"
  for symbol in invokeMethod startTUN stopTun forceGC setEventListener \
    result_func release_object_func free_string_func protect_func \
    resolve_uid_func resolve_package_func; do
    grep -Eq " [TDSBC] _${symbol}\$" <<<"$symbols" || {
      echo "iOS archive $archive lacks $symbol" >&2
      return 1
    }
  done
}

verify_ios_core() {
  if [[ "$(uname -s)" != "Darwin" ]] || ! command -v xcrun >/dev/null; then
    skip "ios core (needs macOS with Xcode)"
    return
  fi
  step "core: ios device archive"
  dart setup.dart ios
  verify_ios_symbols libclash/ios/libclash.a
  step "core: ios simulator archive"
  dart setup.dart ios --simulator
  verify_ios_symbols libclash/ios-simulator/libclash.a
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
  if [[ "$(uname -s)" != "Darwin" ]] || ! command -v xcodegen >/dev/null; then
    skip "ios CoreSmokeTests (needs macOS with xcodegen)"
    return
  fi
  local device
  device="$(xcrun simctl list devices available |
    sed -n 's/^ *\(iPhone [^(]*[^ (]\) (.*/\1/p' | head -n 1)"
  if [[ -z "$device" ]]; then
    skip "ios CoreSmokeTests (no iPhone simulator runtime installed)"
    return
  fi
  step "ios: CoreSmokeTests on $device"
  (
    cd ios-poc
    xcodegen >/dev/null
    xcodebuild test -project FlClashPoC.xcodeproj -scheme CoreSmokeTests \
      -destination "platform=iOS Simulator,name=$device" CODE_SIGNING_ALLOWED=NO
  )
}

verify_core
verify_android_core
verify_ios_core
verify_dart
if ((full)); then
  verify_full
fi

echo "==> verify_sync: passed"
if ((${#skipped[@]})); then
  printf 'not checked: %s\n' "${skipped[@]}" >&2
fi
