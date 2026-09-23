# Newest Xcode*.app, or XCODE_APP / DEVELOPER_DIR.

bt_pick_xcode() {
  XCODE_APP="${XCODE_APP:-}" python3 - <<'PY'
import os, plistlib, subprocess, sys
from pathlib import Path

def load(app: Path):
    with (app / "Contents/Info.plist").open("rb") as stream:
        return plistlib.load(stream)

def developer_dir(app: Path) -> Path:
    return app / "Contents/Developer"

def is_xcode(app: Path) -> bool:
    info_path = app / "Contents/Info.plist"
    xcodebuild = developer_dir(app) / "usr/bin/xcodebuild"
    if not info_path.is_file() or not xcodebuild.is_file():
        return False
    return load(app).get("CFBundleIdentifier") == "com.apple.dt.Xcode"

def sort_key(app: Path):
    info = load(app)
    dtxcode = info.get("DTXcode") or 0
    try:
        dtxcode = int(dtxcode)
    except (TypeError, ValueError):
        dtxcode = 0
    parts = []
    for piece in str(info.get("CFBundleVersion") or "0").split("."):
        parts.append(int(piece) if piece.isdigit() else 0)
    return dtxcode, parts

override = os.environ.get("XCODE_APP")
if override:
    app = Path(override).expanduser()
    if not is_xcode(app):
        sys.exit(f"XCODE_APP is not an Xcode.app: {app}")
else:
    selected = os.environ.get("DEVELOPER_DIR")
    if not selected:
        try:
            selected = subprocess.check_output(["xcode-select", "-p"], text=True).strip()
        except (OSError, subprocess.CalledProcessError):
            selected = ""
    app = Path(selected).expanduser().parent.parent if selected.endswith("/Contents/Developer") else None
    if not app or not is_xcode(app):
        apps = [p for p in Path("/Applications").glob("Xcode*.app") if is_xcode(p)]
        if not apps:
            sys.exit("No Xcode.app in /Applications. Install Xcode or set XCODE_APP.")
        app = max(apps, key=sort_key)

print(developer_dir(app))
PY
}

bt_use_xcode() {
  DEVELOPER_DIR="$(bt_pick_xcode)"
  export DEVELOPER_DIR
  export PATH="$DEVELOPER_DIR/usr/bin:$PATH"
  printf 'Using %s\n' "$DEVELOPER_DIR"
  xcodebuild -version
}

bt_xcode_input_args() {
  if [[ -n "${WORKSPACE:-}" ]]; then
    printf '%s\n' -workspace "$WORKSPACE"
  elif [[ -n "${PROJECT:-}" ]]; then
    printf '%s\n' -project "$PROJECT"
  else
    return 1
  fi
}

bt_choose_xcode_path() {
  local label="$1" choice count
  shift
  count="$#"
  [[ "$count" -gt 0 ]] || return 1
  if [[ "$count" -eq 1 ]]; then printf '%s\n' "$1"; return 0; fi
  printf 'Choose %s:\n' "$label" >&2
  printf '%s\n' "$@" | nl -ba >&2
  while true; do
    printf '%s [1-%s]: ' "$label" "$count" >&2
    read -r choice < /dev/tty || bt_die "multiple $label options; set WORKSPACE or PROJECT in run.config"
    if bt_is_int "$choice" && [[ "$choice" -ge 1 && "$choice" -le "$count" ]]; then
      printf '%s\n' "${!choice}"
      return 0
    fi
  done
}

bt_detect_xcode_input() {
  local root="${1:-$APP_ROOT}"
  WORKSPACE="${WORKSPACE:-${BT_DETECTED_WORKSPACE:-}}"
  PROJECT="${PROJECT:-${BT_DETECTED_PROJECT:-}}"
  SCHEME="${SCHEME:-${BT_DETECTED_SCHEME:-}}"
  if [[ -n "${WORKSPACE:-}" ]]; then
    [[ "$WORKSPACE" == /* ]] || WORKSPACE="$root/$WORKSPACE"
  elif [[ -n "${PROJECT:-}" ]]; then
    [[ "$PROJECT" == /* ]] || PROJECT="$root/$PROJECT"
  else
    local workspaces=() projects=() path
    while IFS= read -r path || [[ -n "$path" ]]; do
      [[ -n "$path" ]] && workspaces+=("$path")
    done < <(find "$root" -maxdepth 2 -name '*.xcworkspace' ! -path '*.xcodeproj/*' 2>/dev/null | sort)
    while IFS= read -r path || [[ -n "$path" ]]; do
      [[ -n "$path" ]] && projects+=("$path")
    done < <(find "$root" -maxdepth 2 -name '*.xcodeproj' 2>/dev/null | sort)

    if [[ "${#workspaces[@]}" -gt 0 ]]; then
      WORKSPACE="$(bt_choose_xcode_path workspace ${workspaces[@]+"${workspaces[@]}"})"
    elif [[ "${#projects[@]}" -gt 0 ]]; then
      PROJECT="$(bt_choose_xcode_path project ${projects[@]+"${projects[@]}"})"
    else
      bt_die "no Xcode project or workspace under $root"
    fi
  fi

  if [[ -z "${SCHEME:-}" ]]; then
    local input kind schemes count choice
    if [[ -n "$WORKSPACE" ]]; then
      input="$WORKSPACE"
      kind=-workspace
      SCHEME="$(basename "$WORKSPACE" .xcworkspace)"
    else
      input="$PROJECT"
      kind=-project
      SCHEME="$(basename "$PROJECT" .xcodeproj)"
    fi
    schemes="$(xcodebuild "$kind" "$input" -list -json 2>/dev/null | python3 -c 'import json,sys; data=json.load(sys.stdin); print("\n".join(data.get("workspace", data.get("project", {})).get("schemes", [])))' 2>/dev/null || true)"
    count="$(printf '%s\n' "$schemes" | sed '/^$/d' | wc -l | tr -d '[:space:]')"
    if [[ "$count" -eq 1 ]]; then
      SCHEME="$schemes"
    elif [[ "$count" -gt 1 ]] && ! printf '%s\n' "$schemes" | grep -Fxq "$SCHEME"; then
      [[ -r /dev/tty ]] || bt_die "multiple schemes; set SCHEME in run.config"
      printf 'Choose scheme:\n%s\n' "$(printf '%s\n' "$schemes" | nl -ba)" >&2
      while true; do
        printf 'Scheme [1-%s]: ' "$count" >&2
        read -r choice < /dev/tty || bt_die "set SCHEME in run.config"
        if bt_is_int "$choice" && [[ "$choice" -ge 1 && "$choice" -le "$count" ]]; then
          SCHEME="$(printf '%s\n' "$schemes" | sed -n "${choice}p")"
          break
        fi
      done
    fi
  fi
  PRODUCT_NAME="${PRODUCT_NAME:-$SCHEME}"
}
