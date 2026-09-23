#!/bin/bash
# Generic macOS runner.
#   ./run.sh [local|remote] [fast|full]
# Full / Send Full only appear when HOOK_FULL is set.

set -euo pipefail

# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=../lib/gui.sh
source "$BUILD_TOOLS_ROOT/lib/gui.sh"
# shellcheck source=../lib/xcode.sh
source "$BUILD_TOOLS_ROOT/lib/xcode.sh"
# shellcheck source=../lib/worktree.sh
source "$BUILD_TOOLS_ROOT/lib/worktree.sh"

bt_usage() {
  cat <<EOF
usage: $(basename "$0") [local|remote] [fast|full] [options]

  local fast     Build and open on this Mac
  local full     Build, HOOK_FULL, open
  remote fast    SSH send and launch
  remote full    SSH send and launch, full build

Options:
  --xcode=<Xcode.app>  --send-target=<host>  --team=<id>
  --root=<app>         --print-xcode        --send-root=<remote-folder>
EOF
}

CONFIGURATION="${CONFIGURATION:-Debug}"
APP=""

bt_quit_bundle() {
  local bundle_id="${BUNDLE_ID:-$(bt_plist "$1/Contents/Info.plist" CFBundleIdentifier)}"
  [[ -n "$bundle_id" ]] || return 0
  xcrun swift "$BUILD_TOOLS_ROOT/macos/quit.swift" "$bundle_id"
}

bt_send_app() {
  [[ -n "$SEND_TARGET" ]] || bt_die "set SEND_TARGET to the receiving Mac SSH host"
  python3 "$BUILD_TOOLS_ROOT/macos/send.py" "$APP" "$SEND_TARGET" "$TAILDROP_ROOT" "${ALLOW_ADHOC_SEND:-0}"
}

bt_bootstrap "$@"
bt_parse_args "$@"

if [[ "$MODE" == sim ]]; then
  bt_die "macos runner has no simulator mode"
fi

if [[ "$PRINT_XCODE" -eq 1 ]]; then
  bt_use_xcode
  exit 0
fi

BT_HAS_SIM=0
BT_HAS_FULL=0
bt_has_full_hook && BT_HAS_FULL=1
BT_FAST_REMOTE_TITLE="Send"
BT_FULL_REMOTE_TITLE="Send Full"
BT_FAST_REMOTE_DESC="transfer and launch over SSH"
BT_FULL_REMOTE_DESC="hook, then transfer and launch"
bt_resolve_where_mode
if [[ "$WHERE" == remote ]]; then
  [[ -z "$DELIVERY" ]] || bt_die "macOS delivery uses --send-target; the KiwiOS portal currently supports iOS only"
  [[ -n "$SEND_TARGET" && "$SEND_TARGET" =~ ^[A-Za-z0-9_][A-Za-z0-9_.@-]*$ ]] || bt_die "set SEND_TARGET to the receiving Mac SSH host"
  ssh -o BatchMode=yes -o ConnectTimeout=8 -- "$SEND_TARGET" 'command -v rsync >/dev/null && command -v codesign >/dev/null' \
    || bt_die "receiving Mac is unavailable; check Tailscale, Remote Login and SSH access"
fi

case "$MODE" in
  fast) CONFIGURATION="${CONFIGURATION_FAST:-$CONFIGURATION}" ;;
  full) CONFIGURATION="${CONFIGURATION_FULL:-$CONFIGURATION}" ;;
esac

cd "$APP_ROOT"
bt_use_xcode
bt_detect_xcode_input "$APP_ROOT"
bt_collect_xcode_args
bt_resolve_worktree "$APP_ROOT"
bt_macos_cache_paths
bt_open_log
bt_prepare_cache_dirs
bt_acquire_lock

PRODUCTS="$DERIVED_DATA/Build/Products/$CONFIGURATION"
APP="$(bt_find_built_app "$PRODUCTS" "${PRODUCT_NAME:-$SCHEME}" || true)"
if [[ "$WHERE" == local ]]; then bt_quit_bundle "${APP:-}"; fi

INPUT_ARGS=()
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -n "$line" ]] && INPUT_ARGS+=("$line")
done < <(bt_xcode_input_args)

bt_step "xcodebuild $CONFIGURATION ($WHERE $MODE)"
bt_run_logged xcodebuild \
  ${INPUT_ARGS[@]+"${INPUT_ARGS[@]}"} \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$DERIVED_DATA" \
  COMPILATION_CACHE_ENABLE_CACHING=YES \
  COMPILATION_CACHE_CAS_PATH="$COMPILATION_CACHE" \
  MODULE_CACHE_DIR="$MODULE_CACHE" \
  SDK_STAT_CACHE_DIR="$SDK_STAT_CACHE" \
  COMPILER_INDEX_STORE_ENABLE=NO \
  ${TEAM_ID:+DEVELOPMENT_TEAM="$TEAM_ID"} \
  ${TEAM_ID:+CODE_SIGN_STYLE=Automatic} \
  ${TEAM_ID:+CODE_SIGN_IDENTITY="Apple Development"} \
  ${TEAM_ID:+-allowProvisioningUpdates} \
  ${XCODE_EXTRA_ARGS[@]+"${XCODE_EXTRA_ARGS[@]}"} \
  build \
  || bt_die "xcodebuild failed. Log: $BUILD_LOG"

APP="$(bt_find_built_app "$PRODUCTS" "${PRODUCT_NAME:-$SCHEME}")" \
  || bt_die "built app not found under $PRODUCTS"

bt_run_hook

if [[ "$WHERE" == remote ]]; then
  bt_send_app
  exit 0
fi

# Full hooks own their staged replacement and its final quit check.
if [[ "$MODE" == fast ]]; then bt_quit_bundle "$APP"; fi
open "$APP"
printf 'Launched %s\n' "$APP"
