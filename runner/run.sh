#!/bin/bash
# Installed alongside the KiwiOS library, or run from a standalone build-kit checkout.
set -euo pipefail
runner_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$runner_root/lib/common.sh"
source "$runner_root/lib/gui.sh"
source "$runner_root/lib/xcode.sh"
platform=""
args=()
for arg in "$@"; do
  case "$arg" in
    --platform=*) platform="${arg#*=}" ;;
    -h|--help)
      printf '%s\n' 'usage: run.sh [local|remote] [fast|full|sim] [--platform=ios|macos|flutter] [options]' \
        'Detects Flutter or the Xcode application platform. Overrides and delivery options: ios/run.sh --help'
      exit 0 ;;
    *) args+=("$arg") ;;
  esac
done
bt_bootstrap ${args[@]+"${args[@]}"}
bt_parse_args ${args[@]+"${args[@]}"}
if [[ "$PRINT_XCODE" -eq 1 ]]; then bt_use_xcode; exit 0; fi
if [[ -z "$platform" ]]; then
  if [[ -f "$APP_ROOT/pubspec.yaml" ]]; then
    platform=flutter
  else
    bt_use_xcode
    bt_detect_xcode_input "$APP_ROOT"
    input=()
    while IFS= read -r arg; do input+=("$arg"); done < <(bt_xcode_input_args)
    settings="$(xcodebuild ${input[@]+"${input[@]}"} -scheme "$SCHEME" -showBuildSettings -json)"
    platforms="$(printf '%s' "$settings" | python3 -c '
import json, sys
choices = set()
for target in json.load(sys.stdin):
    s = target.get("buildSettings", {})
    if s.get("PRODUCT_TYPE") != "com.apple.product-type.application": continue
    supported = s.get("SUPPORTED_PLATFORMS", "").split()
    if "iphoneos" in supported: choices.add("ios")
    if "macosx" in supported: choices.add("macos")
print("\n".join(sorted(choices)))
')"
    BT_MENU_KEYS=() BT_MENU_ICONS=() BT_MENU_TITLES=() BT_MENU_DESCS=()
    while IFS= read -r choice; do
      [[ -n "$choice" ]] || continue
      BT_MENU_KEYS+=("$choice"); BT_MENU_ICONS+=('📱'); BT_MENU_TITLES+=("$choice"); BT_MENU_DESCS+=('')
    done <<< "$platforms"
    [[ "${#BT_MENU_KEYS[@]}" -gt 0 ]] || bt_die 'no iOS/macOS app platform detected; pass --platform=ios or --platform=macos'
    platform="$(bt_ask_menu 'Which app platform?' 'Choose:')"
    # Preserve the detected choice; do not ask for a scheme twice.
    export BT_DETECTED_PROJECT="$PROJECT" BT_DETECTED_WORKSPACE="$WORKSPACE" BT_DETECTED_SCHEME="$SCHEME"
  fi
fi
case "$platform" in ios|macos|flutter) ;; *) bt_die "unsupported platform: $platform" ;; esac
exec "$runner_root/$platform/run.sh" ${args[@]+"${args[@]}"}
