#!/bin/bash
# ==============================================================================
# FlClash 本地构建与部署工具
#
# 1. 打包：调用官方 setup.dart；Go 内核与 Rust 库由 Native Asset Hook 按需重编
# 2. 同步（--sync，可选）：tool/sync_upstream.sh 合并官方 dev 并把内核适配层套到
#    最新 Alpha，验证不过自动回滚；加 --push / --push-main 才推送
# 3. 部署：检测到 USB 连接的 Android 设备时自动安装本次构建出的 APK
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

FORCE_BUILD=false
SYNC=false
SYNC_ARGS=()
PUSH=""
AUTO_DEPLOY=true
TARGET_PLATFORM="android"
TARGET_ARCH=""
ENV_MODE="stable"
VERBOSE=false
DEVICE="${ANDROID_SERIAL:-}"
ADB=""
SCRIPT_START_TIME=$(date +%s)

log_info() { printf "${BLUE}[INFO]${NC} %s\n" "$*"; }
log_success() { printf "${GREEN}[SUCCESS]${NC} %s\n" "$*"; }
log_warning() { printf "${YELLOW}[WARNING]${NC} %s\n" "$*"; }
log_error() { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }
die() { log_error "$*"; exit 1; }

format_duration() {
    local seconds=$1
    if [[ $seconds -lt 60 ]]; then
        echo "${seconds}秒"
    else
        echo "$((seconds / 60))分$((seconds % 60))秒"
    fi
}

show_help() {
    cat << EOH
用法: ./build.sh [选项]

选项:
  -p, --platform <android|macos>       目标平台 (默认: android)
  -a, --arch <arm64|arm|amd64>         Android 架构；x86_64 等同 amd64
                                       (默认: 已连接设备的架构，否则 arm64)
  -e, --env <stable|pre|dev>           应用构建环境 (默认: stable)
  -s, --device <serial>                安装到指定设备 (默认: \$ANDROID_SERIAL 或第一台)
  -f, --force                          清理 Hook 指纹缓存与 build/，强制全量重编
  --sync                               构建前先与官方同步（验证通过才保留）
  --sync-app-only / --sync-core-only   只同步官方 App / 只同步 Mihomo 内核
  --push                               与 --sync 同用：验证通过后推送内核和当前分支
  --push-main                          同 --push，并把 fork 的 main 也更新到同一提交
  --no-deploy                          构建完成后不自动安装到设备
  -v, --verbose                        输出 Flutter 详细构建日志
  -h, --help                           显示帮助信息
EOH
}

require_value() {
    [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || die "选项 $1 需要一个参数"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--platform) require_value "$@"; TARGET_PLATFORM="$2"; shift 2 ;;
            -a|--arch) require_value "$@"; TARGET_ARCH="$2"; shift 2 ;;
            -e|--env) require_value "$@"; ENV_MODE="$2"; shift 2 ;;
            -s|--device) require_value "$@"; DEVICE="$2"; shift 2 ;;
            -f|--force) FORCE_BUILD=true; shift ;;
            --sync) SYNC=true; shift ;;
            --sync-app-only) SYNC=true; SYNC_ARGS=(--app-only); shift ;;
            --sync-core-only) SYNC=true; SYNC_ARGS=(--core-only); shift ;;
            --push|--push-main) PUSH="$1"; shift ;;
            --no-deploy) AUTO_DEPLOY=false; shift ;;
            -v|--verbose) VERBOSE=true; shift ;;
            -h|--help) show_help; exit 0 ;;
            *) log_error "未知选项: $1"; show_help; exit 1 ;;
        esac
    done

    case "$TARGET_PLATFORM" in
        android|macos) ;;
        *) die "不支持的平台: $TARGET_PLATFORM（可选 android|macos）" ;;
    esac
    case "$ENV_MODE" in
        stable|pre|dev) ;;
        *) die "不支持的环境: $ENV_MODE（可选 stable|pre|dev）" ;;
    esac
    case "$TARGET_ARCH" in
        ""|arm64|arm|amd64) ;;
        x86_64) TARGET_ARCH="amd64" ;;
        *) die "不支持的架构: $TARGET_ARCH（可选 arm64|arm|amd64）" ;;
    esac
    if [[ "$TARGET_PLATFORM" != "android" ]]; then
        [[ -z "$TARGET_ARCH" ]] || log_warning "--arch 只对 Android 生效，已忽略"
        AUTO_DEPLOY=false
    fi
    if [[ -n "$PUSH" ]]; then
        [[ "$SYNC" == "true" ]] || die "$PUSH 需要与 --sync 一起使用"
        SYNC_ARGS+=("$PUSH")
    fi
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "未检测到 $1，$2"
}

# adb 不在 PATH 时退回到 android/local.properties 的 sdk.dir 或 ANDROID_HOME
resolve_adb() {
    if command -v adb >/dev/null 2>&1; then
        ADB="$(command -v adb)"
        return 0
    fi
    local sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
    if [[ -z "$sdk" && -f android/local.properties ]]; then
        sdk="$(sed -n 's/^sdk\.dir=//p' android/local.properties | head -n 1)"
    fi
    if [[ -n "$sdk" && -x "$sdk/platform-tools/adb" ]]; then
        ADB="$sdk/platform-tools/adb"
    fi
}

check_and_prepare_env() {
    log_info "检查构建环境..."

    require_command flutter "请安装 Flutter"
    require_command dart "请安装 Dart"
    require_command go "Go 内核由构建 Hook 编译"
    # rust_api 的 Hook 在每个目标上都会编译 Rust 库
    require_command cargo "Rust 库由构建 Hook 编译"
    require_command rustc "Rust 库由构建 Hook 编译"
    if [[ "$TARGET_PLATFORM" == "macos" ]]; then
        require_command npm "setup.dart 需要用它安装 appdmg"
    fi

    if git submodule status core/Clash.Meta | grep -q '^-'; then
        log_info "初始化内核子模块 core/Clash.Meta..."
        git submodule update --init --recursive core/Clash.Meta
    fi

    if [[ "$AUTO_DEPLOY" == "true" ]]; then
        resolve_adb
        if [[ -z "$ADB" ]]; then
            log_warning "未找到 adb，将跳过自动安装"
            AUTO_DEPLOY=false
        fi
    fi

    log_success "构建环境检查通过 (Flutter $(flutter --version 2>/dev/null | head -n 1 | awk '{print $2}'), Go $(go version | awk '{print $3}'), $(rustc --version | awk '{print $1, $2}'))"
}

sync_upstream() {
    log_info "同步官方 FlClash 与 Mihomo 内核（失败会自动回滚）..."
    if ! ./tool/sync_upstream.sh "${SYNC_ARGS[@]+"${SYNC_ARGS[@]}"}"; then
        die "同步失败，代码与内核已恢复到同步前的状态。"
    fi
}

pick_device() {
    if [[ -n "$DEVICE" ]]; then
        "$ADB" -s "$DEVICE" get-state >/dev/null 2>&1 || die "设备 $DEVICE 未连接或未授权"
        return 0
    fi
    DEVICE=$("$ADB" devices 2>/dev/null | awk '$2 == "device" {print $1; exit}' || true)
}

# 未指定 --arch 时跟随设备架构，避免装上不匹配 ABI 的分包
resolve_arch() {
    [[ "$TARGET_PLATFORM" == "android" && -z "$TARGET_ARCH" ]] || return 0
    TARGET_ARCH="arm64"
    [[ -n "$DEVICE" ]] || return 0
    local abi
    abi=$("$ADB" -s "$DEVICE" shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r' || true)
    case "$abi" in
        arm64-v8a) TARGET_ARCH="arm64" ;;
        armeabi-v7a) TARGET_ARCH="arm" ;;
        x86_64) TARGET_ARCH="amd64" ;;
        *) log_warning "无法识别设备 ABI \"$abi\"，使用 arm64" ;;
    esac
    log_info "按设备 [$DEVICE] 的 ABI ($abi) 选择架构 $TARGET_ARCH"
}

# setup.dart 会改写受版本控制的 env.json，构建结束后还原
ENV_JSON_BACKUP=""
restore_env_json() {
    if [[ -n "$ENV_JSON_BACKUP" ]]; then
        printf '%s' "$ENV_JSON_BACKUP" > env.json
    fi
    if [[ -n "${BUILD_MARKER:-}" ]]; then
        rm -f "$BUILD_MARKER"
    fi
}

build_package() {
    local args=("$TARGET_PLATFORM" --env "$ENV_MODE")
    if [[ "$TARGET_PLATFORM" == "android" ]]; then
        args+=(--arch "$TARGET_ARCH")
    fi
    if [[ "$VERBOSE" == "true" ]]; then
        args+=(--verbose)
    fi

    log_info "开始构建 $TARGET_PLATFORM${TARGET_ARCH:+ ($TARGET_ARCH)} [$ENV_MODE]..."

    if [[ "$FORCE_BUILD" == "true" ]]; then
        log_info "清理构建缓存以强制全量重编..."
        rm -rf .dart_tool/setup_build_cache build/
    fi

    ENV_JSON_BACKUP="$(cat env.json)"
    BUILD_MARKER="$(mktemp -t flclash-build)"
    trap restore_env_json EXIT

    flutter pub get >/dev/null

    local build_start
    build_start=$(date +%s)
    if ! dart setup.dart "${args[@]}"; then
        log_error "构建失败；内核与 Rust Hook 的日志见 .dart_tool/setup_build_cache/hook.log"
        exit 1
    fi
    log_success "构建完成！构建耗时: $(format_duration $(( $(date +%s) - build_start )))"
}

deploy_device() {
    [[ "$AUTO_DEPLOY" == "true" ]] || return 0
    if [[ -z "$DEVICE" ]]; then
        log_info "未检测到已连接的 Android 设备，跳过安装。"
        return 0
    fi

    local apk
    apk=$(find dist -type f -name '*.apk' -newer "$BUILD_MARKER" -print0 2>/dev/null \
        | xargs -0 ls -t 2>/dev/null | head -n 1 || true)
    if [[ -z "$apk" ]]; then
        log_warning "dist/ 下没有本次构建产生的 APK，跳过安装。"
        return 0
    fi

    log_info "正在安装到设备 [$DEVICE]: $apk"
    local output
    if output=$("$ADB" -s "$DEVICE" install -r -d "$apk" 2>&1); then
        log_success "成功安装到设备 [$DEVICE]！"
        return 0
    fi
    printf '%s\n' "$output" >&2
    if grep -q 'INSTALL_FAILED_UPDATE_INCOMPATIBLE' <<< "$output"; then
        log_warning "签名与设备上已安装的版本不一致，需先卸载旧版本再安装。"
    elif grep -q 'INSTALL_FAILED_NO_MATCHING_ABIS' <<< "$output"; then
        log_warning "APK 架构 ($TARGET_ARCH) 与设备不匹配，请用 -a 指定正确架构。"
    else
        log_warning "安装失败，若手机弹出了安装确认提示请先确认后重试。"
    fi
}

main() {
    parse_args "$@"

    printf "\n${CYAN}======================================================${NC}\n"
    printf "${CYAN}              FlClash 构建与部署工具              ${NC}\n"
    printf "${CYAN}======================================================${NC}\n\n"

    check_and_prepare_env

    if [[ "$SYNC" == "true" ]]; then
        sync_upstream
    fi

    if [[ "$AUTO_DEPLOY" == "true" ]]; then
        pick_device
    fi
    resolve_arch

    build_package
    deploy_device

    local total_duration=$(( $(date +%s) - SCRIPT_START_TIME ))
    printf "\n"
    log_success "全部任务顺利完成！总耗时: $(format_duration "$total_duration")"
    printf "\n本次产物:\n"
    find dist -type f -newer "$BUILD_MARKER" -exec ls -lh {} + 2>/dev/null || true
    printf "\n"
}

main "$@"
