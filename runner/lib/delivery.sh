# iOS delivery choices, shared by native and Flutter builds.
source "$BUILD_TOOLS_ROOT/lib/relay.sh"

bt_resolve_delivery() {
  if [[ "$WHERE" != remote ]]; then
    return 0
  fi
  if [[ -z "$KIWIOS_PUBLISHER" && -f "$BUILD_TOOLS_ROOT/../publish.rb" ]]; then
    KIWIOS_PUBLISHER="$BUILD_TOOLS_ROOT/../publish.rb"
  fi
  if [[ -z "$DELIVERY" ]]; then
    BT_MENU_KEYS=() BT_MENU_ICONS=() BT_MENU_TITLES=() BT_MENU_DESCS=()
    if [[ -n "$KIWIOS_LIBRARY_ROOT" && -n "$KIWIOS_PUBLISHER" ]]; then
      BT_MENU_KEYS+=(portal); BT_MENU_ICONS+=('📚'); BT_MENU_TITLES+=('Publish')
      BT_MENU_DESCS+=('KiwiOS build page and phone install')
    fi
    if [[ -n "$RELAY_HOST" ]]; then
      BT_MENU_KEYS+=(relay); BT_MENU_ICONS+=('📱'); BT_MENU_TITLES+=('Run on phone')
      BT_MENU_DESCS+=('install and launch through the receiving Mac')
      if [[ -n "$KIWIOS_LIBRARY_ROOT" && -n "$KIWIOS_PUBLISHER" ]]; then
        BT_MENU_KEYS+=(both); BT_MENU_ICONS+=('📦'); BT_MENU_TITLES+=('Run + publish')
        BT_MENU_DESCS+=('phone install and a shareable build page')
      fi
    fi
    # Preserve the existing Sqim workflow when no replacement is configured.
    if [[ "${#BT_MENU_KEYS[@]}" -eq 0 ]]; then
      DELIVERY=sqim
    else
      DELIVERY="$(bt_ask_menu 'Where should the build go?' 'Choose:')"
    fi
  fi
  case "$DELIVERY" in
    portal|relay|both|sqim) ;;
    *) bt_die "delivery must be portal, relay, both, or sqim" ;;
  esac
}

bt_delivery_preflight() {
  [[ "$WHERE" == remote ]] || return 0
  case "$DELIVERY" in
    portal|both)
      bt_require ruby
      [[ -f "$KIWIOS_PUBLISHER" ]] || bt_die "KiwiOS publisher missing; copy setup from the Builds page"
      ruby "$KIWIOS_PUBLISHER" --library-root "$KIWIOS_LIBRARY_ROOT" --portal "$KIWIOS_PORTAL" --check
      ;;
    sqim)
      bt_require sqim
      sqim status >/dev/null 2>&1 || bt_die "not logged in to Sqim. Run: sqim login"
      ;;
  esac
  case "$DELIVERY" in relay|both) bt_relay_preflight ;; esac
}

bt_deliver_ios() {
  case "$DELIVERY" in
    portal|both)
      bt_step "Publish to KiwiOS"
      (cd "$APP_ROOT" && ruby "$KIWIOS_PUBLISHER" --library-root "$KIWIOS_LIBRARY_ROOT" \
        --portal "$KIWIOS_PORTAL" --project "$APP_NAME" "$APP")
      ;;
    sqim) bt_step "Sqim"; bt_sqim_upload "$APP" ;;
  esac
  case "$DELIVERY" in
    relay|both) bt_step "Install through $RELAY_HOST"; bt_relay_install "$APP" "$(bt_app_bundle_id "$APP")" ;;
  esac
}
