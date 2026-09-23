# SSH relay to the Mac holding the iPhone cable.

BT_RELAY_DIR=""

bt_relay_ssh() {
  ssh -o BatchMode=yes -o ConnectTimeout=8 -- "$RELAY_HOST" "$1"
}

bt_relay_command() {
  local command
  printf -v command '/bin/bash %q %q %q %q %q %q' \
    "$BT_RELAY_DIR/ios/relay-receive.sh" "$1" "${2:-}" "${RELAY_XCODE_APP:-}" "${3:-}" "${4:-}"
  bt_relay_ssh "$command"
}

bt_relay_cleanup() {
  if [[ "$BT_RELAY_DIR" =~ ^/tmp/kiwi-relay\.[A-Za-z0-9]+$ ]]; then
    local command
    printf -v command '/bin/rm -rf -- %q' "$BT_RELAY_DIR"
    bt_relay_ssh "$command" >/dev/null 2>&1 || true
    BT_RELAY_DIR=""
  fi
}

bt_relay_preflight() {
  [[ -n "${RELAY_HOST:-}" ]] || bt_die "set RELAY_HOST to the MacBook SSH host"
  [[ "$RELAY_HOST" =~ ^[A-Za-z0-9_.@-]+$ ]] || bt_die "invalid RELAY_HOST"
  command -v rsync >/dev/null || bt_die "rsync is required for relay"
  BT_RELAY_DIR="$(bt_relay_ssh '/usr/bin/mktemp -d /tmp/kiwi-relay.XXXXXXXX' 2>/dev/null)" \
    || bt_die "SSH to $RELAY_HOST failed; check Tailscale and SSH access"
  [[ "$BT_RELAY_DIR" =~ ^/tmp/kiwi-relay\.[A-Za-z0-9]+$ ]] || bt_die "unexpected relay temp path"
  trap 'bt_relay_cleanup' EXIT

  local source_root command rows
  source_root="${BUILD_TOOLS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  printf -v command '/bin/mkdir -p %q %q' "$BT_RELAY_DIR/ios" "$BT_RELAY_DIR/lib"
  bt_relay_ssh "$command" || { bt_relay_cleanup; bt_die "cannot prepare relay on $RELAY_HOST"; }
  rsync -a -e 'ssh -o BatchMode=yes -o ConnectTimeout=8' \
    "$source_root/ios/relay-receive.sh" "$RELAY_HOST:$BT_RELAY_DIR/ios/" \
    || { bt_relay_cleanup; bt_die "cannot copy relay receiver"; }
  rsync -a -e 'ssh -o BatchMode=yes -o ConnectTimeout=8' \
    "$source_root/lib/common.sh" "$source_root/lib/xcode.sh" "$source_root/lib/device.sh" \
    "$RELAY_HOST:$BT_RELAY_DIR/lib/" \
    || { bt_relay_cleanup; bt_die "cannot copy relay helpers"; }

  rows="$(bt_relay_command list "${RELAY_DEVICE_ID:-}")" || {
    bt_relay_cleanup
    bt_die "MacBook Xcode or device discovery failed"
  }
  [[ -n "$rows" ]] || { bt_relay_cleanup; bt_die "no deployable iPhone on $RELAY_HOST"; }
  if [[ -n "${RELAY_DEVICE_ID:-}" ]] && ! printf '%s\n' "$rows" | grep -Fq "${RELAY_DEVICE_ID}"$'\t'; then
    bt_relay_cleanup
    bt_die "iPhone $RELAY_DEVICE_ID is not deployable on $RELAY_HOST"
  fi
  bt_choose_device_rows "$rows" "${RELAY_DEVICE_ID:-}"
  RELAY_DEVICE_ID="$DEVICE_ID"
  printf 'Relay: %s → %s\n' "$RELAY_HOST" "${DEVICE_NAME:-$RELAY_DEVICE_ID}"
}

bt_relay_install() {
  local app="$1" bundle_id="$2" app_remote status=0
  [[ -n "$BT_RELAY_DIR" && -d "$app" && -n "$bundle_id" ]] \
    || bt_die "relay preflight, app, and bundle ID are required"
  [[ "$app" == *.app ]] || bt_die "relay source must be a .app bundle"
  app_remote="$BT_RELAY_DIR/App.app"
  rsync -a -e 'ssh -o BatchMode=yes -o ConnectTimeout=8' \
    "$app/" "$RELAY_HOST:$app_remote/" || status=$?
  if [[ "$status" -eq 0 ]]; then
    bt_relay_command install "$RELAY_DEVICE_ID" "$app_remote" "$bundle_id" || status=$?
  fi
  bt_relay_cleanup
  [[ "$status" -eq 0 ]] || bt_die "MacBook relay install or launch failed"
}
