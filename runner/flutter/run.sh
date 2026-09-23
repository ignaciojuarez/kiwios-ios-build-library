#!/bin/bash
# Generic Flutter runner (iOS sim / device / Sqim).
#   ./run.sh [local|remote] [sim|fast|full]

set -euo pipefail

# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=../lib/gui.sh
source "$BUILD_TOOLS_ROOT/lib/gui.sh"
# shellcheck source=../lib/xcode.sh
source "$BUILD_TOOLS_ROOT/lib/xcode.sh"
# shellcheck source=../lib/device.sh
source "$BUILD_TOOLS_ROOT/lib/device.sh"
# shellcheck source=../lib/worktree.sh
source "$BUILD_TOOLS_ROOT/lib/worktree.sh"
source "$BUILD_TOOLS_ROOT/lib/delivery.sh"

bt_usage() {
  cat <<EOF
usage: $(basename "$0") [local|remote] [sim|fast|full] [options]

  local sim     flutter run on a simulator
  local fast    Debug device install
  local full    Release device install
  remote fast   Debug build, deliver using configured destination
  remote full   Release build, deliver using configured destination

Options:
  --device=<udid>  --simulator=<name-or-id>  --xcode=<Xcode.app>
  --team=<id>      --root=<app>              --no-pub  --print-xcode
  --delivery=portal|relay|both|sqim          --relay-host=<ssh-host>
  --relay-device=<udid> --relay-xcode=<Xcode.app>
  --publisher=<publish.rb> --library-root=<folder> --portal=<https-origin>
EOF
}

CONFIGURATION=""
APP=""
INSTALL_URL=""

bt_ensure_flutter() {
  bt_require flutter
}

bt_pub_get() {
  mkdir -p "$APP_ROOT/build/localization"
  if [[ "$NO_PUB" -eq 0 ]]; then
    bt_step "flutter pub get"
    (cd "$APP_ROOT" && flutter pub get)
  fi
}

bt_config_only() {
  local flag="--debug"
  [[ "$CONFIGURATION" == Release || "$CONFIGURATION" == Profile ]] && flag="--release"
  bt_step "flutter build ios --config-only"
  (cd "$APP_ROOT" && flutter build ios --config-only --no-codesign --no-pub "$flag")
}

bt_pod_install() {
  local ios="$1"
  [[ -f "$ios/Podfile" ]] || return 0
  bt_require pod
  bt_step "pod install"
  (cd "$ios" && pod install)
}

bt_bootstrap "$@"
bt_parse_args "$@"

if [[ "$PRINT_XCODE" -eq 1 ]]; then
  bt_use_xcode
  exit 0
fi

BT_HAS_SIM=1
BT_HAS_FULL=1
BT_FAST_LOCAL_DESC="Debug on the phone"
BT_FULL_LOCAL_DESC="Release on the phone"
BT_FAST_REMOTE_TITLE="Fast"
BT_FULL_REMOTE_TITLE="Full"
BT_FAST_REMOTE_DESC="Debug build and deliver"
BT_FULL_REMOTE_DESC="Release build and deliver"
bt_resolve_where_mode
bt_resolve_delivery
bt_delivery_preflight

if [[ "$MODE" == fast ]]; then
  CONFIGURATION="${CONFIGURATION_FAST:-Debug}"
elif [[ "$MODE" == full ]]; then
  CONFIGURATION="${CONFIGURATION_FULL:-Release}"
else
  CONFIGURATION="${CONFIGURATION_SIM:-Debug}"
fi

[[ -f "$APP_ROOT/pubspec.yaml" ]] || bt_die "not a Flutter app: $APP_ROOT"
cd "$APP_ROOT"
bt_ensure_flutter

if [[ "$MODE" == sim && "$WHERE" == local ]]; then
  bt_use_xcode
  bt_pub_get
  SIMULATOR="$(bt_resolve_simulator "$SIMULATOR")"
  bt_step "flutter run -d $SIMULATOR"
  if [[ "$NO_PUB" -eq 1 ]]; then
    exec flutter run -d "$SIMULATOR" --no-pub
  fi
  exec flutter run -d "$SIMULATOR"
fi

bt_use_xcode
bt_detect_xcode_input "$APP_ROOT"
bt_collect_xcode_args
bt_resolve_worktree "$APP_ROOT"
bt_ios_cache_paths
bt_open_log
bt_prepare_cache_dirs
bt_acquire_lock
bt_pub_get

if [[ "$WHERE" == local ]]; then
  bt_select_device
  bt_confirm_device
fi

bt_config_only
bt_pod_install "$(dirname "$WORKSPACE")"
bt_ensure_ios_platform
bt_sync_source

if [[ -n "${WORKSPACE:-}" ]]; then
  WORKSPACE="${WORKSPACE/#$WORKSPACE_PATH/$BUILD_SOURCE}"
fi
if [[ -n "${PROJECT:-}" ]]; then
  PROJECT="${PROJECT/#$WORKSPACE_PATH/$BUILD_SOURCE}"
fi
cd "$BUILD_SOURCE"

INPUT_ARGS=()
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -n "$line" ]] && INPUT_ARGS+=("$line")
done < <(bt_xcode_input_args)

if [[ "$WHERE" == local ]]; then
  DEST="platform=iOS,id=$DEVICE_ID"
else
  DEST="generic/platform=iOS"
fi
PRODUCTS="$DERIVED_DATA/Build/Products/${CONFIGURATION}-iphoneos"

bt_step "xcodebuild $CONFIGURATION ($WHERE $MODE)"
bt_run_logged xcodebuild \
  ${INPUT_ARGS[@]+"${INPUT_ARGS[@]}"} \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "$DEST" \
  -derivedDataPath "$DERIVED_DATA" \
  COMPILATION_CACHE_ENABLE_CACHING=YES \
  COMPILATION_CACHE_CAS_PATH="$COMPILATION_CACHE" \
  MODULE_CACHE_DIR="$MODULE_CACHE" \
  SDK_STAT_CACHE_DIR="$SDK_STAT_CACHE" \
  COMPILER_INDEX_STORE_ENABLE=NO \
  ${TEAM_ID:+DEVELOPMENT_TEAM="$TEAM_ID"} \
  ${XCODE_EXTRA_ARGS[@]+"${XCODE_EXTRA_ARGS[@]}"} \
  build \
  || bt_die "xcodebuild failed. Log: $BUILD_LOG"

APP="$(bt_find_built_app "$PRODUCTS" "$PRODUCT_NAME")" \
  || bt_die "built app not found under $PRODUCTS"
BUNDLE_ID="${BUNDLE_ID:-$(bt_app_bundle_id "$APP")}"
[[ -n "$BUNDLE_ID" ]] || bt_die "set BUNDLE_ID in run.config"

bt_run_hook

if [[ "$WHERE" == remote ]]; then
  bt_deliver_ios
  exit 0
fi

bt_step "Install $DEVICE_NAME"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP"
if ! xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing "$BUNDLE_ID"; then
  bt_die "launch failed. Unlock $DEVICE_NAME and retry."
fi
printf 'Launched %s on %s\n' "$BUNDLE_ID" "$DEVICE_NAME"
