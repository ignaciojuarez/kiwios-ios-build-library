#!/bin/bash
# Runs on the Mac with the cable-connected iPhone. No interactive prompts.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/xcode.sh"
source "$ROOT/lib/device.sh"

action="${1:-}"
DEVICE_ID="${2:-}"
XCODE_APP="${3:-}"
bt_use_xcode >&2

case "$action" in
  list)
    json="$(mktemp)"
    trap 'rm -f "$json"' EXIT
    xcrun devicectl list devices --json-output "$json" --quiet >/dev/null
    bt_deployable_devices "$json"
    ;;
  install)
    app="${4:?missing app}"
    bundle_id="${5:?missing bundle ID}"
    [[ -d "$app" && "$app" == *.app ]] || bt_die "app missing on relay: $app"
    [[ -n "$DEVICE_ID" ]] || bt_die "relay device ID is required"
    bt_confirm_device
    xcrun devicectl device install app --device "$DEVICE_ID" "$app"
    xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing "$bundle_id" \
      || bt_die "launch failed; unlock $DEVICE_NAME and retry"
    printf 'Launched %s on %s\n' "$bundle_id" "$DEVICE_NAME"
    ;;
  *) bt_die "usage: relay-receive.sh list|install <device-id> <Xcode.app> [app bundle-id]" ;;
esac
