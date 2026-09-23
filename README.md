# iOS build library for KiwiOS

This plugin reads a configured folder of signed iOS builds and provides private build history and tap-to-install links. It does not build apps or ship build scripts. A separate build tool may save an IPA and `kiwios-build.json` into a new child directory; KiwiOS scans that folder.

Canonical repository: [`github.com/ignaciojuarez/kiwios-ios-build-library`](https://github.com/ignaciojuarez/kiwios-ios-build-library). The KiwiOS tree also keeps an author copy for local development. KiwiOS does not bundle or auto-discover this plugin; install it from Discover Featured or its GitHub URL and exact commit.

## Setup

Configure **Library Folder** to a folder you own, such as `~/iOS Builds`. The path is not sandboxed; anyone authorized to use KiwiOS on your tailnet can see the indexed builds. Scans only read completed build directories. **Clean old builds** deletes eligible directories only after confirmation.

## Folder format

Each direct child is an immutable build directory containing `kiwios-build.json` (schema 1) and the named signed `.ipa`. The sidecar records `project`, `title`, `description`, `version`, `build`, `feature`, `createdAt`, `bundleID`, and `ipa`. The scanner validates the sidecar and IPA together, rejects symbolic links and unsafe archives, and does not recurse into project folders.

The separate shared build scripts can write this format when **Save build** is on. KiwiOS only needs the same folder path; it does not need access to the scripts or the project checkout.

## Phone install

Open Builds in iPhone Safari over the private tailnet and tap **Install**. KiwiOS revalidates the IPA and serves a short-lived OTA manifest. The IPA must already be signed for that device. Copy Link gives an authenticated link to one build; it is not an install authorization.

## Test

```sh
ruby tests/test.rb
```
