# Shared config, args, hooks. Source from a runner.

BUILD_TOOLS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

APP_ROOT=""
APP_NAME=""
PROJECT=""
WORKSPACE=""
SCHEME=""
BUNDLE_ID=""
PRODUCT_NAME=""
XCODE_APP=""
DEVICE_ID=""
DEVICE_NAME=""
SIMULATOR=""
TEAM_ID=""
SEND_TARGET=""
DELIVERY="${DELIVERY:-}"
RELAY_HOST="${RELAY_HOST:-}"
RELAY_DEVICE_ID="${RELAY_DEVICE_ID:-}"
RELAY_XCODE_APP="${RELAY_XCODE_APP:-}"
KIWIOS_PUBLISHER="${KIWIOS_PUBLISHER:-}"
KIWIOS_LIBRARY_ROOT="${KIWIOS_LIBRARY_ROOT:-}"
KIWIOS_PORTAL="${KIWIOS_PORTAL:-}"
TAILDROP_ROOT="${TAILDROP_ROOT:-~/Documents/taildrop}"
XCODE_ARGS_FAST=""
XCODE_ARGS_FULL=""
XCODE_ARGS_REMOTE=""
HOOK_FAST=""
HOOK_FULL=""
HOOK_SIM=""
WHERE=""
MODE=""
NO_PUB=0
PRINT_XCODE=0
XCODE_EXTRA_ARGS=()

bt_die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

bt_is_int() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

bt_require() {
  command -v "$1" >/dev/null 2>&1 || bt_die "'$1' is not on PATH"
}

bt_looks_like_app() {
  local dir="$1"
  [[ -f "$dir/scripts/run.config" || -f "$dir/Scripts/run.config" ]] && return 0
  [[ -f "$dir/pubspec.yaml" ]] && return 0
  compgen -G "$dir/*.xcodeproj" >/dev/null && return 0
  compgen -G "$dir/*.xcworkspace" >/dev/null && return 0
  compgen -G "$dir/ios/*.xcworkspace" >/dev/null && return 0
  return 1
}

bt_find_app_root() {
  local dir="${1:-$PWD}"
  dir="$(cd "$dir" && pwd)"
  local walk="$dir"
  while [[ "$walk" != "/" ]]; do
    if bt_looks_like_app "$walk"; then
      printf '%s\n' "$walk"
      return 0
    fi
    walk="$(dirname "$walk")"
  done
  if git -C "$dir" rev-parse --show-toplevel >/dev/null 2>&1; then
    git -C "$dir" rev-parse --show-toplevel
    return 0
  fi
  printf '%s\n' "$dir"
}

bt_load_config() {
  local config=""
  [[ -f "$APP_ROOT/scripts/run.config" ]] && config="$APP_ROOT/scripts/run.config"
  [[ -z "$config" && -f "$APP_ROOT/Scripts/run.config" ]] && config="$APP_ROOT/Scripts/run.config"
  # shellcheck disable=SC1090
  [[ -n "$config" ]] && source "$config"
  # Machine-specific overrides stay out of the shared project configuration.
  if [[ -n "$config" && -f "${config%.config}.local.config" ]]; then
    source "${config%.config}.local.config"
  elif [[ -f "$APP_ROOT/scripts/run.local.config" ]]; then
    source "$APP_ROOT/scripts/run.local.config"
  elif [[ -f "$APP_ROOT/Scripts/run.local.config" ]]; then
    source "$APP_ROOT/Scripts/run.local.config"
  fi

  if [[ -z "$APP_NAME" ]]; then
    if [[ -f "$APP_ROOT/pubspec.yaml" ]]; then
      APP_NAME="$(sed -nE 's/^name:[[:space:]]*//p' "$APP_ROOT/pubspec.yaml" | head -n 1)"
    fi
    APP_NAME="${APP_NAME:-$(basename "$APP_ROOT")}"
  fi
  TAILDROP_ROOT="${TAILDROP_ROOT:-~/Documents/taildrop}"
}

bt_bootstrap() {
  local arg
  APP_ROOT=""
  for arg in "$@"; do
    case "$arg" in
      --root=*)
        APP_ROOT="${arg#--root=}"
        ;;
    esac
  done
  if [[ -z "$APP_ROOT" ]]; then
    APP_ROOT="$(bt_find_app_root)"
  else
    APP_ROOT="$(cd "$APP_ROOT" && pwd)"
  fi
  bt_load_config
}

bt_parse_args() {
  local arg
  while [[ $# -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      -h|--help)
        bt_usage
        exit 0
        ;;
      --print-xcode)
        PRINT_XCODE=1
        shift
        ;;
      --no-pub)
        NO_PUB=1
        shift
        ;;
      --root=*)
        shift
        ;;
      --device=*)
        DEVICE_ID="${arg#--device=}"
        shift
        ;;
      --xcode=*)
        XCODE_APP="${arg#--xcode=}"
        shift
        ;;
      --simulator=*)
        SIMULATOR="${arg#--simulator=}"
        shift
        ;;
      --send-target=*)
        SEND_TARGET="${arg#--send-target=}"
        shift
        ;;
      --send-root=*) TAILDROP_ROOT="${arg#*=}"; shift ;;
      --delivery=*) DELIVERY="${arg#*=}"; shift ;;
      --relay-host=*) RELAY_HOST="${arg#*=}"; shift ;;
      --relay-device=*) RELAY_DEVICE_ID="${arg#*=}"; shift ;;
      --relay-xcode=*) RELAY_XCODE_APP="${arg#*=}"; shift ;;
      --publisher=*) KIWIOS_PUBLISHER="${arg#*=}"; shift ;;
      --library-root=*) KIWIOS_LIBRARY_ROOT="${arg#*=}"; shift ;;
      --portal=*) KIWIOS_PORTAL="${arg#*=}"; shift ;;
      --team=*)
        TEAM_ID="${arg#--team=}"
        shift
        ;;
      local|remote)
        [[ -z "$WHERE" ]] || bt_die "where already set to $WHERE"
        WHERE="$arg"
        shift
        ;;
      sim|fast|full)
        [[ -z "$MODE" ]] || bt_die "mode already set to $MODE"
        MODE="$arg"
        shift
        ;;
      preview)
        [[ -z "$MODE" ]] || bt_die "mode already set to $MODE"
        MODE="sim"
        shift
        ;;
      *)
        bt_die "unknown argument: $arg"
        ;;
    esac
  done
}

# bash 3.2 + set -u: empty "${arr[@]}" is unbound. Expand with
# ${arr[@]+"${arr[@]}"}.
bt_collect_xcode_args() {
  XCODE_EXTRA_ARGS=()
  local raw=""
  case "$MODE" in
    fast) raw="${XCODE_ARGS_FAST:-}" ;;
    full) raw="${XCODE_ARGS_FULL:-}" ;;
    sim) raw="${XCODE_ARGS_SIM:-${XCODE_ARGS_FAST:-}}" ;;
  esac
  if [[ -n "$raw" ]]; then
    # shellcheck disable=SC2206
    XCODE_EXTRA_ARGS=($raw)
  fi
  if [[ "$WHERE" == remote && -n "${XCODE_ARGS_REMOTE:-}" ]]; then
    # shellcheck disable=SC2206
    local remote_args=($XCODE_ARGS_REMOTE)
    XCODE_EXTRA_ARGS+=(${remote_args[@]+"${remote_args[@]}"})
  fi
  if [[ "$WHERE" == remote && -n "${DELIVERY:-}" && "$DELIVERY" != relay ]]; then
    # OTA installs cannot load Xcode's separate debug executable dylib.
    XCODE_EXTRA_ARGS+=(ENABLE_DEBUG_DYLIB=NO)
  fi
}

bt_hook_path() {
  local spec="$1"
  [[ -n "$spec" ]] || return 1
  if [[ "$spec" == /* && -f "$spec" ]]; then
    printf '%s\n' "$spec"
    return 0
  fi
  if [[ -f "$APP_ROOT/$spec" ]]; then
    printf '%s\n' "$APP_ROOT/$spec"
    return 0
  fi
  return 1
}

bt_has_full_hook() {
  bt_hook_path "${HOOK_FULL:-}" >/dev/null
}

bt_run_hook() {
  local spec=""
  case "$MODE" in
    fast) spec="${HOOK_FAST:-}" ;;
    full) spec="${HOOK_FULL:-}" ;;
    sim) spec="${HOOK_SIM:-}" ;;
  esac
  local hook
  hook="$(bt_hook_path "$spec" || true)"
  [[ -n "$hook" ]] || return 0

  local hook_app
  hook_app="$(mktemp)"
  export WHERE MODE APP ROOT="$APP_ROOT" DERIVED_DATA BUILD_TOOLS_ROOT HOOK_APP_FILE="$hook_app"
  bash "$hook" || {
    rm -f "$hook_app"
    bt_die "hook failed: $hook"
  }
  if [[ -s "$hook_app" ]]; then
    APP="$(<"$hook_app")"
  fi
  rm -f "$hook_app"
}

bt_plist() {
  local plist="$1"
  local key="$2"
  plutil -extract "$key" raw -o - "$plist" 2>/dev/null || true
}

bt_app_version() {
  local info="$1/Contents/Info.plist"
  [[ -f "$info" ]] || info="$1/Info.plist"
  [[ -f "$info" ]] || return 1
  local version
  version="$(bt_plist "$info" CFBundleShortVersionString)"
  [[ -n "$version" ]] || return 1
  printf '%s\n' "$version"
}

bt_app_bundle_id() {
  local info="$1/Contents/Info.plist"
  [[ -f "$info" ]] || info="$1/Info.plist"
  [[ -f "$info" ]] || return 1
  bt_plist "$info" CFBundleIdentifier
}

bt_find_built_app() {
  local dir="$1"
  local hint="${2:-}"
  if [[ -n "$hint" && -d "$dir/$hint.app" ]]; then
    printf '%s\n' "$dir/$hint.app"
    return 0
  fi
  local found apps=()
  while IFS= read -r found; do
    [[ -n "$found" ]] && apps+=("$found")
  done < <(find "$dir" -maxdepth 1 -name '*.app' -type d 2>/dev/null | sort)
  [[ "${#apps[@]}" -gt 0 ]] || return 1
  if [[ "${#apps[@]}" -eq 1 ]]; then printf '%s\n' "${apps[0]}"; return 0; fi
  # Never silently install an unrelated app left in a shared build directory.
  BT_MENU_KEYS=() BT_MENU_ICONS=() BT_MENU_TITLES=() BT_MENU_DESCS=()
  for found in "${apps[@]}"; do
    BT_MENU_KEYS+=("$found"); BT_MENU_ICONS+=('📱')
    BT_MENU_TITLES+=("$(basename "$found")"); BT_MENU_DESCS+=('')
  done
  bt_ask_menu 'Which built app? (PRODUCT_NAME overrides this choice)' 'Choose:'
}

bt_sqim_upload() {
  local app="$1"
  bt_require sqim
  sqim status >/dev/null 2>&1 || bt_die "not logged in to Sqim. Run: sqim login"

  local name
  name="$(basename "$app" .app)"
  if [[ -e "$app/${name}.debug.dylib" ]]; then
    bt_die "refusing to package a debug-dylib build for OTA install"
  fi
  if [[ ! -e "$app/embedded.mobileprovision" ]]; then
    bt_die "app has no embedded provisioning profile; it is not device-signed"
  fi
  codesign --verify --strict "$app" || bt_die "codesign verify failed"

  local staging ipa
  staging="$(mktemp -d "${TMPDIR:-/tmp}/build-tools-sqim-XXXXXX")"
  ipa="$staging/$name.ipa"
  mkdir -p "$staging/Payload"
  /bin/cp -R "$app" "$staging/Payload/$name.app"
  (
    cd "$staging"
    /usr/bin/zip -qry "$ipa" Payload
  )
  local output url
  output="$(sqim upload --device --ipa "$ipa")"
  printf '%s\n' "$output"
  url="$(printf '%s\n' "$output" | grep -Eo 'https://[^[:space:]]+' | tail -n 1 || true)"
  rm -rf "$staging"
  [[ -n "$url" ]] || bt_die "sqim printed no install URL"
  INSTALL_URL="$url"
  printf '\nInstall: %s\n' "$INSTALL_URL"
}

bt_step() {
  printf '\n==> %s\n' "$1"
}

# Tee so a silent set -e death cannot hide xcodebuild. PIPESTATUS is bash 3.2-safe.
bt_run_logged() {
  local st
  set +e
  "$@" 2>&1 | tee -a "$BUILD_LOG"
  st="${PIPESTATUS[0]}"
  set -e
  return "$st"
}
