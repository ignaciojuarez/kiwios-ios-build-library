# Security

Ignacio Juarez (`@ignaciojuarez`) maintains this plugin. Do not include Apple credentials, provisioning profiles, device UDIDs, or host inventory in a public report.

Report plugin issues through the [`kiwios-ios-build-library` private vulnerability-reporting form](https://github.com/ignaciojuarez/kiwios-ios-build-library/security/advisories/new) when it is enabled. Otherwise report KiwiOS host issues through the parent repository's `SECURITY.md` and do not put sensitive plugin reports in a public issue.

This plugin is trusted executable code running with the Aqua user's authority. Its manifest permissions are disclosures, not process isolation. It reads the configured build-library folder and writes only plugin-owned index state under `KIWIOS_DATA_DIR`.
