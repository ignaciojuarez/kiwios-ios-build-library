#!/bin/bash
# Generic iOS runner.
#   ./run.sh [local|remote] [sim|fast|full]
# GUI asks for any choice you omit.

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

  local sim     Simulator
  local fast    Device, fast flags
  local full    Device, full flags
  remote fast   Fast build, deliver using configured destination
  remote full   Full build, deliver using configured destination

Options:
  --device=<udid>  --simulator=<name-or-id>  --xcode=<Xcode.app>
  --team=<id>      --root=<app>              --print-xcode
  --delivery=portal|relay|both|sqim          --relay-host=<ssh-host>
  --relay-device=<udid> --relay-xcode=<Xcode.app>
  --publisher=<publish.rb> --library-root=<folder> --portal=<https-origin>
EOF
}

CONFIGURATION="${CONFIGURATION:-Debug}"
APP=""
INSTALL_URL=""

bt_bootstrap "$@"
bt_parse_args "$@"

if [[ "$PRINT_XCODE" -eq 1 ]]; then
  bt_use_xcode
  exit 0
fi

BT_HAS_SIM=1
BT_HAS_FULL=1
BT_FAST_REMOTE_TITLE="Fast"
BT_FULL_REMOTE_TITLE="Full"
BT_FAST_REMOTE_DESC="build and deliver"
BT_FULL_REMOTE_DESC="full build and deliver"
bt_resolve_where_mode
bt_resolve_delivery
bt_delivery_preflight

case "$MODE" in
  sim) CONFIGURATION="${CONFIGURATION_SIM:-$CONFIGURATION}" ;;
  fast) CONFIGURATION="${CONFIGURATION_FAST:-$CONFIGURATION}" ;;
  full) CONFIGURATION="${CONFIGURATION_FULL:-$CONFIGURATION}" ;;
esac

cd "$APP_ROOT"
bt_use_xcode
bt_detect_xcode_input "$APP_ROOT"
bt_collect_xcode_args
bt_resolve_worktree "$APP_ROOT"
bt_ios_cache_paths
bt_open_log
bt_prepare_cache_dirs
bt_acquire_lock

if [[ "$MODE" == sim ]]; then
  SIMULATOR="$(bt_resolve_simulator "$SIMULATOR")"
elif [[ "$WHERE" == local ]]; then
  bt_select_device
  bt_confirm_device
fi

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

if [[ -d "$BUILD_SOURCE/${PROJECT##*/}" ]] || [[ -n "${WORKSPACE:-}" ]]; then
  if find "$BUILD_SOURCE" -name Package.resolved | grep -q .; then
    bt_step "Resolve packages"
    bt_run_logged xcodebuild \
      -resolvePackageDependencies \
      ${INPUT_ARGS[@]+"${INPUT_ARGS[@]}"} \
      -scheme "$SCHEME" \
      -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" \
      -onlyUsePackageVersionsFromResolvedFile \
      || bt_die "package resolve failed. Log: $BUILD_LOG"
  fi
fi

if [[ "$MODE" == sim ]]; then
  if [[ "$SIMULATOR" =~ ^[0-9A-Fa-f-]{36}$ ]]; then
    DEST="platform=iOS Simulator,id=$SIMULATOR"
  else
    DEST="platform=iOS Simulator,name=$SIMULATOR"
  fi
  PRODUCTS="$DERIVED_DATA/Build/Products/${CONFIGURATION}-iphonesimulator"
elif [[ "$WHERE" == local ]]; then
  DEST="platform=iOS,id=$DEVICE_ID"
  PRODUCTS="$DERIVED_DATA/Build/Products/${CONFIGURATION}-iphoneos"
else
  DEST="generic/platform=iOS"
  PRODUCTS="$DERIVED_DATA/Build/Products/${CONFIGURATION}-iphoneos"
fi

bt_step "xcodebuild $CONFIGURATION ($WHERE $MODE)"
bt_run_logged xcodebuild \
  ${INPUT_ARGS[@]+"${INPUT_ARGS[@]}"} \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "$DEST" \
  -derivedDataPath "$DERIVED_DATA" \
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" \
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

if [[ "$MODE" == sim ]]; then
  bt_step "Install simulator"
  open -a Simulator >/dev/null 2>&1 || true
  xcrun simctl boot "$SIMULATOR" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$SIMULATOR" -b >/dev/null
  xcrun simctl install "$SIMULATOR" "$APP"
  xcrun simctl launch "$SIMULATOR" "$BUNDLE_ID"
  printf 'Launched %s on %s\n' "$BUNDLE_ID" "$SIMULATOR"
  exit 0
fi

bt_step "Install $DEVICE_NAME"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP"
if ! xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing "$BUNDLE_ID"; then
  bt_die "launch failed. Unlock $DEVICE_NAME and retry."
fi
printf 'Launched %s on %s\n' "$BUNDLE_ID" "$DEVICE_NAME"
