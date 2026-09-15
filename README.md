# iOS build library for KiwiOS

This is the inventory release of the external KiwiOS iOS build-library plugin. It indexes one staged folder of exported `.ipa` files plus `kiwios-build.json` sidecars and shows valid and invalid builds. It does not run `xcodebuild`, sign apps, or install onto an iPhone.

This is the canonical repository. An author copy remains under `examples/ios-build-library` in [KiwiOS](https://github.com/ignaciojuarez/kiwios) for local development. Ignacio Juarez (`@ignaciojuarez`) owns and maintains the plugin. KiwiOS does not bundle or auto-discover it. Install from Discover Featured, or from the GitHub URL plus an exact commit SHA.

## Requirements

- macOS 15 or later
- KiwiOS with `native.jobs = "1"`
- the system Ruby, `unzip`, `plutil`, and `shasum` declared in `plugin.toml`
- a staged library folder whose direct children are build directories

The plugin uses the current configuration and setup protocol: `library_root` is required public configuration with no default. After review, the Plugins card shows **Configure** (`setup: configuration-required`) until that path is saved. Saving the public form is enough to finish setup; there are no write-only secrets. The host Configure dialog is the primary editor; the in-plugin form page is the same schema. API 1 cannot require a non-empty string, so a blank Configure save can promote the plugin; the library check then errors until a real path is saved. The path field shows an orange warning: the folder is not sandboxed, and anyone with KiwiOS on your tailnet can see those builds.

Optional `keep_days` and `max_gb` are used only by the confirmed **Clean old builds** action. Scheduled scans do not delete files. Install re-checks the IPA at tap time and again when iOS downloads it, so a cleanup that removes the file fails the install instead of serving the wrong bytes.

## Library layout

```text
~/iOS Builds/
  kiwi-notes-1.4.0-104/
    kiwios-build.json
    KiwiNotes.ipa
```

`kiwios-build.json` is schema 1, strict, and must match the IPA bundle identifier, short version, and build number. The scanner does not recurse, rejects symbolic links, and never follows sidecar URLs or parent paths. Newest sort compares RFC 3339 UTC instants, including fractional seconds. Version sort compares major.minor.patch only and ignores SemVer prerelease identifiers. IPAs larger than 512 MiB, sidecars larger than 64 KiB, and oversized zip listings or Info.plist payloads are invalid.

## Phone install

Tap **Install** on the Builds page from iPhone Safari on your tailnet. KiwiOS serves a short-lived OTA manifest and that one IPA from the existing Serve origin. Open the page in Safari, not the Home Screen web app. The IPA must already be signed for that device. The scanner still writes `index.v1.json` under `KIWIOS_DATA_DIR` as a private cache; KiwiOS revalidates the file before creating an install link.

## Test

```sh
./tests/test.rb
```

The test builds tiny fixture IPAs in a temporary home directory. It does not contact Apple or use Xcode.
