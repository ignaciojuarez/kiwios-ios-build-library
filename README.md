# iOS build library for KiwiOS

The plugin indexes signed iOS builds, provides private build pages, and asks KiwiOS to deliver tap-to-install links. It also includes a terminal/T3 build runner and publisher. Builds run only when you invoke those scripts; background library checks never compile, sign, or install apps.

Canonical repository: [`github.com/ignaciojuarez/kiwios-ios-build-library`](https://github.com/ignaciojuarez/kiwios-ios-build-library). This `examples/ios-build-library/` directory is the author copy inside the KiwiOS tree for local development. Ignacio Juarez (`@ignaciojuarez`) owns and maintains the plugin. KiwiOS does not bundle or auto-discover it. Install from Discover Featured, or from the GitHub URL plus an exact commit SHA.

## Requirements

- macOS 15 or later
- KiwiOS with `native.jobs = "1"` and `native.artifact-delivery = "1"`
- the system Ruby, `unzip`, `plutil`, and `shasum` declared in `plugin.toml`
- a staged library folder whose direct children are build directories

The plugin uses the current configuration and setup protocol: `library_root` is required public configuration with no default. After review, the Plugins card shows **Configure** (`setup: configuration-required`) until that path is saved. Saving the public form is enough to finish setup; there are no write-only secrets. The host Configure dialog is the primary editor; the in-plugin form page is the same schema. API 1 cannot require a non-empty string, so a blank Configure save can promote the plugin; the library check then errors until a real path is saved. The path field shows an orange warning: the folder is not sandboxed, and anyone with KiwiOS on your tailnet can see those builds.

Optional `keep_days` and `max_gb` are used only by the confirmed **Clean old builds** action. Scheduled scans do not delete files. Install re-checks the IPA at tap time and again when iOS downloads it, so a cleanup that removes the file fails the install instead of serving the wrong bytes.

## Build from T3 or a terminal

1. Install and enable the plugin; set **Library Folder** to a folder you own (for example `~/iOS Builds`).
2. Open **Builds → Use from T3 or terminal**. Copy the generated command into a T3 project script, or run it from your app checkout **on the build Mac**. No runner clone, account, or upload service is required.
3. The runner detects your Flutter or native Xcode app and builds it, then publishes an IPA and prints its private build-page link. Open that page in iPhone Safari with Tailscale connected.

Xcode and project signing must already work on the build Mac. The default uses the selected Xcode when usable, otherwise the newest installation. Project, scheme, and app metadata are detected; a single choice is automatic, ambiguous choices get a terminal picker. A T3 button can use the same terminal menu. Automation with no terminal must provide any ambiguous override in the project's existing `scripts/run.config`.

The runner honors existing fast/full configurations, Xcode flags, and hooks. Advanced machine-specific values go in `scripts/run.local.config`, which must be gitignored. The Builds page provides the publisher path, library root and portal URL automatically; they are not three extra settings to type.

### Install and launch through another Mac

For a phone plugged into another Mac, add `RELAY_HOST='your-ssh-alias'` to the local config and select `--delivery=relay`. Use `--delivery=both` to run and publish the same build. The receiving Mac needs Remote Login reachable over Tailscale, working key-based SSH, compatible Xcode, and a trusted, unlocked developer-enabled iPhone. No relay service installation is needed; the runner copies a temporary receiver and removes it afterward. The only connected iPhone is automatic; multiple phones get a picker on the build Mac. `RELAY_DEVICE_ID` and `RELAY_XCODE_APP` are optional overrides.

Relay transfers the signed `.app` directly, avoiding IPA packaging in the fast loop. Portal publishing and Sqim explicitly disable Xcode's separate debug dylib. `--delivery=sqim` retains the previous fallback while physical-device OTA testing is pending.

This release supports native iOS, Flutter **iOS**, and macOS. Android and automated device-test orchestration are not implemented. `remote` selects delivery; it does not SSH source code to a build host. Run T3 on the build Mac, or invoke the command there over SSH.

### Publish an already built artifact

The generated setup includes the installed publisher path. It accepts a signed `.app` or exported `.ipa`:

```sh
ruby /path/to/plugin/publish.rb --library-root "$HOME/iOS Builds" --portal https://your-hub.your-tailnet.ts.net /path/to/App.ipa
```

The publisher derives bundle ID/version/build from the artifact and defaults title/feature from Git when run in a checkout. Optional `--title`, `--description`, `--feature`, and `--project` override the labels. `--check` checks tools and folder configuration without building or publishing. Complete artifacts appear atomically; failed packaging never leaves a visible half-build. No public endpoint or automatic install is created.

## Library layout

```text
~/iOS Builds/
  kiwi-notes-1.4.0-104/
    kiwios-build.json
    KiwiNotes.ipa
```

`kiwios-build.json` is schema 1, strict, and must match the IPA bundle identifier, short version, and build number. The scanner does not recurse, rejects symbolic links, and never follows sidecar URLs or parent paths. Newest sort compares RFC 3339 UTC instants, including fractional seconds. Version sort supports Apple short versions (`1`, `1.0`, `1.0.0`) and SemVer prereleases, then compares numeric build identifiers numerically. Repeated builds with the same app version remain separate immutable history entries. IPAs larger than 512 MiB, sidecars larger than 64 KiB, and oversized zip listings or Info.plist payloads are invalid.

## Phone install

Tap **Install** on the Builds page from iPhone Safari on your tailnet. KiwiOS serves a short-lived OTA manifest and that one IPA from the existing Serve origin. Open the page in Safari, not the Home Screen web app. The IPA must already be signed for that device. The scanner still writes `index.v1.json` under `KIWIOS_DATA_DIR` as a private cache; KiwiOS revalidates the file before creating an install link.

## Test

```sh
ruby tests/test.rb
ruby tests/publish_test.rb
```

The test builds tiny fixture IPAs in a temporary home directory. It does not contact Apple or use Xcode.

## Maintaining the included runner

`runner/` is a curated copy of the shared build engine. Update it with the engine's `scripts/export-build-runner.sh <plugin-directory>`; do not copy machine notes, local configuration, credentials, or project-specific wrappers into the extension. Run both plugin tests and runner regression checks before publishing a new exact-commit plugin revision. Updating this author copy does not publish a catalog update.
