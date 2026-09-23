# Worktree root, lock, rsync-to-stable source, cache paths.

WORKSPACE_PATH=""
PRIMARY_ROOT=""
BUILD_SOURCE=""
DERIVED_DATA=""
SOURCE_PACKAGES=""
SHARED_DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData"
COMPILATION_CACHE=""
MODULE_CACHE=""
SDK_STAT_CACHE=""
BUILD_LOG=""

bt_safe_name() {
  printf '%s' "$1" | tr -cs '[:alnum:]._-' '-'
}

bt_resolve_worktree() {
  local start="${1:-$APP_ROOT}"
  if git -C "$start" rev-parse --show-toplevel >/dev/null 2>&1; then
    WORKSPACE_PATH="$(git -C "$start" rev-parse --show-toplevel)"
    local common
    common="$(git -C "$start" rev-parse --path-format=absolute --git-common-dir)"
    PRIMARY_ROOT="$(dirname "$common")"
  else
    WORKSPACE_PATH="$start"
    PRIMARY_ROOT="$start"
  fi
}

bt_ios_cache_paths() {
  local app
  app="$(bt_safe_name "$APP_NAME")"
  DERIVED_DATA="$SHARED_DERIVED_DATA/BuildTools/$app"
  SOURCE_PACKAGES="$DERIVED_DATA/SourcePackages"
  BUILD_SOURCE="$PRIMARY_ROOT/.context/BuildSource/$app"
  COMPILATION_CACHE="$SHARED_DERIVED_DATA/CompilationCache.noindex"
  MODULE_CACHE="$SHARED_DERIVED_DATA/ModuleCache.noindex"
  SDK_STAT_CACHE="$SHARED_DERIVED_DATA"
}

bt_macos_cache_paths() {
  local app
  app="$(bt_safe_name "$APP_NAME")"
  DERIVED_DATA="$SHARED_DERIVED_DATA/BuildTools/$app"
  BUILD_SOURCE="$WORKSPACE_PATH"
  COMPILATION_CACHE="$SHARED_DERIVED_DATA/CompilationCache.noindex"
  MODULE_CACHE="$SHARED_DERIVED_DATA/ModuleCache.noindex"
  SDK_STAT_CACHE="$SHARED_DERIVED_DATA"
}

bt_prepare_cache_dirs() {
  mkdir -p \
    "$DERIVED_DATA" \
    "${SOURCE_PACKAGES:-$DERIVED_DATA}" \
    "$COMPILATION_CACHE" \
    "$MODULE_CACHE" \
    "$(dirname "$BUILD_LOG")"
}

bt_acquire_lock() {
  local lock="$DERIVED_DATA/.build.lock"
  mkdir -p "$(dirname "$lock")"
  exec 9>>"$lock" || bt_die "unable to open build lock"
  if ! /usr/bin/lockf -s -t 0 9; then
    bt_die "another $APP_NAME build is already running"
  fi
  printf '%s\t%s\t%s\t%s\n' \
    "$(basename "$WORKSPACE_PATH")" \
    "$WHERE-$MODE" \
    "$$" \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >&9
}

bt_sync_source() {
  [[ -n "$BUILD_SOURCE" && "$BUILD_SOURCE" != "/" ]] || bt_die "refusing to sync to $BUILD_SOURCE"
  mkdir -p "$BUILD_SOURCE"
  bt_step "Sync $(basename "$WORKSPACE_PATH") → BuildSource"
  /usr/bin/rsync \
    -ac --no-times -O --delete --delete-excluded \
    --exclude '/.git' \
    --exclude '/.context' \
    "$WORKSPACE_PATH/" \
    "$BUILD_SOURCE/"
}

bt_open_log() {
  local dir="$PRIMARY_ROOT/.context/build-logs/$(bt_safe_name "$(basename "$WORKSPACE_PATH")")"
  mkdir -p "$dir"
  BUILD_LOG="$dir/$WHERE-$MODE-$$.log"
  : >"$BUILD_LOG"
  local count=0
  local old
  # bash 3.2 + set -e: `[[ cond ]] && cmd` returns 1 when cond is false and
  # kills the runner with no message. `while read` EOF is also 1.
  while IFS= read -r old || [[ -n "$old" ]]; do
    count=$((count + 1))
    if [[ "$count" -gt 5 ]]; then
      rm -f "$old"
    fi
  done < <(find "$dir" -maxdepth 1 -type f -name '*.log' -print | sort -r) || true
}
