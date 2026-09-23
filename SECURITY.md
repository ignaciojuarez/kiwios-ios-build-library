# Security

Ignacio Juarez (`@ignaciojuarez`) maintains this plugin. Do not include Apple credentials, provisioning profiles, device UDIDs, or host inventory in a public report.

Report plugin issues through the [`kiwios-ios-build-library` private vulnerability-reporting form](https://github.com/ignaciojuarez/kiwios-ios-build-library/security/advisories/new) when it is enabled. Otherwise report KiwiOS host issues through the parent repository's `SECURITY.md` and do not put sensitive plugin reports in a public issue.

This plugin is trusted executable code running with the Aqua user's authority. Its manifest permissions are disclosures, not process isolation. Scheduled checks read the configured build-library folder and write plugin-owned index state under `KIWIOS_DATA_DIR`; the confirmed cleanup action deletes eligible build folders.

The bundled runner and publisher are opt-in terminal tools, not scheduled plugin actions. When invoked, they build user-selected project code with the user's Xcode/signing environment, write build caches and the configured library, and optionally transfer to an explicitly configured SSH host. They never publish a public endpoint or disable Gatekeeper. Initial SSH, signing and device trust setup is attended. An IPA is checked for unsafe archive paths and bounded expansion before extraction; Apple still determines whether its profile permits installation on a given device.
