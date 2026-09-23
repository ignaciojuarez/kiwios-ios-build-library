# Physical iPhone picker and simulator resolve.

bt_deployable_devices() {
  local list_json="$1"
  python3 -c '
import json, subprocess, sys

def norm(value):
    return "".join(ch for ch in (value or "") if ch.isalnum()).upper()

def walk_usb(node, serials):
    if isinstance(node, list):
        for item in node:
            walk_usb(item, serials)
        return
    if not isinstance(node, dict):
        return
    vendor = str(node.get("USBDeviceKeyVendorID") or node.get("vendor_id") or "").lower()
    serial = node.get("USBDeviceKeySerialNumber") or node.get("serial_num") or node.get("serial_number")
    if "05ac" in vendor.replace("0x", "") and serial:
        serial = str(serial)
        if serial.lower() != "not provided":
            serials.add(norm(serial))
    for child in node.get("_items", []):
        walk_usb(child, serials)

usb_serials = set()
for data_type in ("SPUSBHostDataType", "SPUSBDataType"):
    try:
        raw = subprocess.check_output(["system_profiler", data_type, "-json"], text=True, timeout=20)
        walk_usb(json.loads(raw).get(data_type, []), usb_serials)
    except Exception:
        pass

preferred = norm(sys.argv[2])
data = json.load(open(sys.argv[1]))
rows = []
for device in data.get("result", {}).get("devices", []):
    hardware = device.get("hardwareProperties") or {}
    connection = device.get("connectionProperties") or {}
    properties = device.get("deviceProperties") or {}
    if hardware.get("reality") != "physical" or hardware.get("platform") != "iOS":
        continue
    udid = hardware.get("udid") or ""
    if not udid:
        continue
    transport = (connection.get("transportType") or "").lower()
    on_cable = transport in ("wired", "usb") or (
        norm(udid) in usb_serials or norm(hardware.get("serialNumber")) in usb_serials
    )
    paired = connection.get("pairingState") == "paired"
    reachable = (connection.get("tunnelState") or "") != "unavailable"
    on_network = (
        preferred
        and norm(udid) == preferred
        and paired
        and reachable
        and transport == "localnetwork"
    )
    if not on_cable and not on_network:
        continue
    name = properties.get("name") or hardware.get("marketingName") or udid
    rows.append((0 if preferred and norm(udid) == preferred else 1, udid, name))

for _, udid, name in sorted(rows, key=lambda row: (row[0], row[2].lower())):
    print(f"{udid}\t{name}")
' "$list_json" "${DEVICE_ID:-}"
}

bt_select_device() {
  local list_json devices default_id="${DEVICE_ID:-}"

  bt_require xcrun
  list_json="$(mktemp)"
  if ! xcrun devicectl list devices --json-output "$list_json" --quiet >/dev/null 2>&1; then
    rm -f "$list_json"
    [[ -n "$default_id" ]] || bt_die "could not list devices"
    return 0
  fi

  devices="$(bt_deployable_devices "$list_json")"
  rm -f "$list_json"
  bt_choose_device_rows "$devices" "$default_id"
}

bt_choose_device_rows() {
  local devices="$1" default_id="${2:-}" count line index choice
  if [[ -z "$devices" ]]; then
    [[ -n "$default_id" ]] || bt_die "no deployable iPhone (plug one in, or set DEVICE_ID)"
    DEVICE_ID="$default_id"
    return 0
  fi

  if [[ -n "$default_id" ]] && printf '%s\n' "$devices" | grep -F -q "${default_id}"$'\t'; then
    DEVICE_ID="$default_id"
    DEVICE_NAME="$(printf '%s\n' "$devices" | grep -F "${default_id}"$'\t' | head -n 1 | cut -f2-)"
    return 0
  fi

  count="$(printf '%s\n' "$devices" | wc -l | tr -d '[:space:]')"
  if [[ "$count" -eq 1 ]]; then
    DEVICE_ID="${devices%%	*}"
    DEVICE_NAME="${devices#*	}"
    return 0
  fi

  if [[ -e /dev/tty ]]; then
    printf '\n' >&2
    index=1
    while IFS=$'\t' read -r _ name || [[ -n "${name:-}" ]]; do
      [[ -n "${name:-}" ]] || continue
      printf '%s) %s\n' "$index" "$name" >&2
      index=$((index + 1))
    done <<< "$devices"
    printf '\n' >&2
    while true; do
      printf 'Select a device [1-%s]: ' "$count" >&2
      read -r choice < /dev/tty
      if bt_is_int "$choice" && [[ "$choice" -ge 1 && "$choice" -le "$count" ]]; then
        line="$(printf '%s\n' "$devices" | sed -n "${choice}p")"
        DEVICE_ID="${line%%	*}"
        DEVICE_NAME="${line#*	}"
        break
      fi
      printf 'Enter a number from 1 to %s.\n' "$count" >&2
    done
    return 0
  fi

  bt_die "multiple devices; pass --device= or run in a terminal"
}

bt_first_iphone_sim() {
  xcrun simctl list devices available 2>/dev/null \
    | grep 'iPhone' \
    | sed -nE 's/.*\(([0-9A-Fa-f-]{36})\).*/\1/p' \
    | head -n 1 || true
}

bt_sim_named() {
  xcrun simctl list devices available 2>/dev/null | grep -F -- "$1" >/dev/null
}

bt_download_ios_platform() {
  local variant="arm64"
  [[ "$(uname -m)" == arm64 ]] || variant="universal"
  bt_step "xcodebuild -downloadPlatform iOS ($variant)"
  xcodebuild -downloadPlatform iOS -architectureVariant "$variant" \
    || xcodebuild -downloadPlatform iOS
}

bt_resolve_simulator() {
  local requested="${1:-}"
  local fallback
  if [[ -n "$requested" ]] && bt_sim_named "$requested"; then
    printf '%s\n' "$requested"
    return 0
  fi
  fallback="$(bt_first_iphone_sim)"
  if [[ -z "$fallback" ]]; then
    bt_download_ios_platform
    fallback="$(bt_first_iphone_sim)"
  fi
  [[ -n "$fallback" ]] || bt_die "no available iPhone simulator"
  if [[ -n "$requested" ]]; then
    printf 'warning: simulator %s not found; using %s\n' "$requested" "$fallback" >&2
  fi
  printf '%s\n' "$fallback"
}

bt_ensure_ios_platform() {
  local dest
  dest="$(bt_xcode_destination_probe 2>&1 || true)"
  if bt_xcode_destination_ok; then
    return 0
  fi
  if ! printf '%s\n' "$dest" | grep -q 'is not installed'; then
    printf '%s\n' "$dest" >&2
    bt_die "Xcode cannot build for iOS"
  fi
  bt_download_ios_platform
  bt_xcode_destination_ok || bt_die "iOS platform support is still missing"
}

bt_xcode_destination_ok() {
  local args=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] && args+=("$line")
  done < <(bt_xcode_input_args)
  xcodebuild \
    ${args[@]+"${args[@]}"} \
    -scheme "$SCHEME" \
    -destination 'generic/platform=iOS' \
    -showBuildSettings \
    >/dev/null 2>&1
}

bt_xcode_destination_probe() {
  local args=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] && args+=("$line")
  done < <(bt_xcode_input_args)
  xcodebuild ${args[@]+"${args[@]}"} -scheme "$SCHEME" -showdestinations 2>&1 || true
}

bt_confirm_device() {
  local json name udid
  json="$(mktemp)"
  if ! xcrun devicectl device info details --device "$DEVICE_ID" --json-output "$json" --quiet >/dev/null 2>&1; then
    rm -f "$json"
    bt_die "connect ${DEVICE_NAME:-device} ($DEVICE_ID) and try again"
  fi
  name="$(bt_plist "$json" result.deviceProperties.name)"
  udid="$(bt_plist "$json" result.hardwareProperties.udid)"
  rm -f "$json"
  if [[ -n "$udid" && "$udid" != "$DEVICE_ID" ]]; then
    bt_die "expected $DEVICE_ID but found $udid"
  fi
  DEVICE_NAME="${name:-$DEVICE_ID}"
  printf 'Device: %s\n' "$DEVICE_NAME"
}
