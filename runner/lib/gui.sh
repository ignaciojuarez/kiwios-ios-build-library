# TTY menu. Show only when a choice is still unset.

C_GOLD="" C_DIM="" C_BOLD="" C_RED="" C_RESET=""
ICONS=0

bt_setup_colors() {
  local fd="${1:-2}"
  local colors=0
  C_GOLD="" C_DIM="" C_BOLD="" C_RED="" C_RESET=""
  ICONS=0
  if [[ -z "${NO_COLOR:-}" ]] && [[ -t "$fd" ]]; then
    if command -v tput >/dev/null 2>&1; then
      colors="$(tput colors 2>/dev/null || echo 0)"
    else
      colors=8
    fi
  fi
  if [[ "$colors" -ge 8 ]]; then
    if [[ "$colors" -ge 256 || "${COLORTERM:-}" == *truecolor* || "${COLORTERM:-}" == *24bit* ]]; then
      C_GOLD=$'\033[38;2;232;200;106m'
      C_DIM=$'\033[38;2;142;142;147m'
      C_RED=$'\033[38;2;255;107;107m'
    else
      C_GOLD=$'\033[33m'
      C_DIM=$'\033[90m'
      C_RED=$'\033[31m'
    fi
    C_BOLD=$'\033[1m'
    C_RESET=$'\033[0m'
    ICONS=1
  fi
}

bt_print_option() {
  local num="$1" icon="$2" title="$3" desc="$4"
  if [[ "$ICONS" -eq 1 ]]; then
    printf '     %s%s%s  %s  %s%-12s%s %s%s%s\n' \
      "$C_GOLD$C_BOLD" "$num" "$C_RESET" "$icon" \
      "$C_BOLD" "$title" "$C_RESET" "$C_DIM$desc" "$C_RESET"
  else
    printf '  %s) %-12s %s\n' "$num" "$title" "$desc"
  fi
}

# Visible width of the banner inner edge. Pad so the right wall meets the corners.
bt_print_banner() {
  local title="${APP_NAME:-RUN}"
  local label="   ${title} · RUN"
  local inner=46
  local used="${#label}"
  local line pad
  (( used > inner )) && inner=$used
  pad=$((inner - used))
  printf -v line '%*s' "$inner" ''
  line="${line// /─}"
  printf '  %s╭%s╮%s\n' "$C_GOLD" "$line" "$C_RESET"
  printf '  %s│%s%s%s%s %s· RUN%s%*s%s│%s\n' \
    "$C_GOLD" "$C_RESET" "$C_GOLD$C_BOLD" "   $title" "$C_RESET" \
    "$C_DIM" "$C_RESET" "$pad" '' "$C_GOLD" "$C_RESET"
  printf '  %s╰%s╯%s\n\n' "$C_GOLD" "$line" "$C_RESET"
}

# Keys and labels are parallel arrays: BT_MENU_KEYS BT_MENU_ICONS BT_MENU_TITLES BT_MENU_DESCS
bt_ask_menu() {
  local heading="$1"
  local prompt="$2"
  local count="${#BT_MENU_KEYS[@]}"
  local selection key i
  local title="${APP_NAME:-RUN}"

  [[ "$count" -gt 0 ]] || bt_die "nothing to choose"
  if [[ "$count" -eq 1 ]]; then
    printf '%s\n' "${BT_MENU_KEYS[0]}"
    return 0
  fi

  if [[ ! -t 0 && ! -e /dev/tty ]]; then
    bt_die "need a terminal to choose: $heading"
  fi

  bt_setup_colors 2
  {
    printf '\n'
    if [[ "$ICONS" -eq 1 ]]; then
      bt_print_banner
      printf '   %s%s%s\n\n' "$C_DIM" "$heading" "$C_RESET"
    else
      printf '%s — %s\n\n' "$title" "$heading"
    fi
    for i in "${!BT_MENU_KEYS[@]}"; do
      bt_print_option "$((i + 1))" "${BT_MENU_ICONS[$i]}" "${BT_MENU_TITLES[$i]}" "${BT_MENU_DESCS[$i]}"
    done
    printf '\n'
  } >&2

  while true; do
    printf '   %s➜%s  %s ' "$C_GOLD$C_BOLD" "$C_RESET" "$prompt" >&2
    if ! IFS= read -r selection; then
      bt_die "no selection"
    fi
    if bt_is_int "$selection" && [[ "$selection" -ge 1 && "$selection" -le "$count" ]]; then
      printf '%s\n' "${BT_MENU_KEYS[$((selection - 1))]}"
      return 0
    fi
    key="$(printf '%s' "$selection" | tr '[:upper:]' '[:lower:]')"
    for i in "${!BT_MENU_KEYS[@]}"; do
      if [[ "$key" == "${BT_MENU_KEYS[$i]}" ]]; then
        printf '%s\n' "${BT_MENU_KEYS[$i]}"
        return 0
      fi
    done
    printf '   %s✗%s  pick 1-%s\n\n' "$C_RED" "$C_RESET" "$count" >&2
  done
}

bt_ask_where() {
  BT_MENU_KEYS=(local remote)
  BT_MENU_ICONS=('💻' '📡')
  BT_MENU_TITLES=('Local' 'Remote')
  BT_MENU_DESCS=('device or simulator here' 'publish or send to another Mac')
  bt_ask_menu 'Where should this build go?' 'Choose 1-2:'
}

bt_fill_mode_menu() {
  BT_MENU_KEYS=()
  BT_MENU_ICONS=()
  BT_MENU_TITLES=()
  BT_MENU_DESCS=()
  if [[ "$WHERE" == local ]]; then
    BT_MENU_KEYS+=(fast)
    BT_MENU_ICONS+=('🔥')
    BT_MENU_TITLES+=('Fast')
    BT_MENU_DESCS+=("${BT_FAST_LOCAL_DESC:-build and run here}")
    if [[ "${BT_HAS_FULL:-1}" -eq 1 ]]; then
      BT_MENU_KEYS+=(full)
      BT_MENU_ICONS+=('🐙')
      BT_MENU_TITLES+=('Full')
      BT_MENU_DESCS+=("${BT_FULL_LOCAL_DESC:-complete build and run here}")
    fi
    if [[ "${BT_HAS_SIM:-0}" -eq 1 ]]; then
      BT_MENU_KEYS+=(sim)
      BT_MENU_ICONS+=('📱')
      BT_MENU_TITLES+=('Sim')
      BT_MENU_DESCS+=('boot and run here')
    fi
  else
    BT_MENU_KEYS+=(fast)
    BT_MENU_ICONS+=('📤')
    BT_MENU_TITLES+=("${BT_FAST_REMOTE_TITLE:-Send}")
    BT_MENU_DESCS+=("${BT_FAST_REMOTE_DESC:-fast build, send away}")
    if [[ "${BT_HAS_FULL:-1}" -eq 1 ]]; then
      BT_MENU_KEYS+=(full)
      BT_MENU_ICONS+=('📦')
      BT_MENU_TITLES+=("${BT_FULL_REMOTE_TITLE:-Send Full}")
      BT_MENU_DESCS+=("${BT_FULL_REMOTE_DESC:-full build, send away}")
    fi
  fi
}

bt_ask_mode() {
  bt_fill_mode_menu
  bt_ask_menu 'How do you want to build?' 'Choose:'
}

bt_resolve_where_mode() {
  if [[ -z "$WHERE" && -z "$MODE" ]]; then
    WHERE="$(bt_ask_where)"
  fi
  if [[ -z "$WHERE" ]]; then
    WHERE="local"
  fi
  if [[ "$WHERE" == remote && "$MODE" == sim ]]; then
    bt_die "simulator is local-only"
  fi
  if [[ -z "$MODE" ]]; then
    MODE="$(bt_ask_mode)"
  fi
  if [[ "$WHERE" == remote && "$MODE" == sim ]]; then
    bt_die "simulator is local-only"
  fi
  if [[ "$MODE" == full && "${BT_HAS_FULL:-1}" -ne 1 ]]; then
    bt_die "full is not configured (set HOOK_FULL in run.config)"
  fi
}
