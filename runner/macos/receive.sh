#!/bin/bash
# Runs on the receiving Mac. Transfer and verify before asking the old app to quit.
set -euo pipefail
stage="$(cd "$(dirname "$0")" && pwd)"
root="${1:?missing destination}"
name="${2:?missing app name}"
case "$root" in '~/'*) root="$HOME/${root#\~/}" ;; /*) ;; *) exit 2 ;; esac
[[ "$name" == *.app && "$name" != */* && "$name" != .* ]] || exit 2
source "$stage/xcode.sh"
bt_use_xcode
codesign --verify --deep --strict "$stage/App.app"
bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$stage/App.app/Contents/Info.plist")"
[[ -n "$bundle_id" ]] || exit 2
mkdir -p "$root"
# Stage on the destination filesystem so promotion is a rename, even across volumes.
incoming="$(mktemp -d "$root/.incoming.XXXXXXXX")"
trap 'rm -rf "$incoming"' EXIT
ditto "$stage/App.app" "$incoming/$name"
codesign --verify --deep --strict "$incoming/$name"
xcrun swift "$stage/quit.swift" "$bundle_id"
destination="$root/$name"
previous="$incoming/.previous.app"
if [[ -e "$destination" ]]; then mv "$destination" "$previous"; fi
if ! mv "$incoming/$name" "$destination"; then
  if [[ -e "$previous" ]]; then mv "$previous" "$destination"; fi
  exit 1
fi
if ! open "$destination"; then
  mv "$destination" "$incoming/.failed.app"
  if [[ -e "$previous" ]]; then mv "$previous" "$destination"; fi
  printf 'Launch failed; previous build restored. Check signing and quarantine on the receiving Mac.\n' >&2
  exit 1
fi
printf 'Launched %s\n' "$destination"
