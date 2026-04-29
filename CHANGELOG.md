# Changelog

All notable changes to this project are documented in this file.

## v1.2.0 - 2026-04-29

### Added

- Added strict handling for the Windows Antigravity hang dialog by clicking `Keep Waiting` only when the watcher finds:
  - a window title containing `Antigravity`
  - the text `The window is not responding`
  - the buttons `Reopen`, `Close`, and `Keep Waiting`
- Added a `KeepWaiting` scenario to the built-in test harness.
- Extended the installer validation to test both the `Retry` flow and the `Keep Waiting` flow.

### Improved

- Improved title matching for the hang dialog so expanded titles such as `Jus4U - Antigravity - Walkthrough` are recognized.
- Reused the existing focus-restore path for `Keep Waiting`, so the watcher behaves consistently when Antigravity was not the active app.
- Updated the public README to document the second popup signature and release-oriented versioning.

## v1.1.0 - 2026-04-21

- Restored the exact foreground window that was active right before `Retry`.
- Avoided unnecessary focus reactivation when the correct window was already in front.
- Buffered log writes in small batches to reduce synchronous disk I/O during watcher activity.
- Added config knobs for focus-steal detection and log flush cadence.

## v1.0.0 - 2026-04-20

- First public release of AG Auto Retry.
- Added exact-popup detection for `Agent terminated due to error` + `Copy debug info` + `Retry`.
- Added hidden Scheduled Task startup at user logon, local logs, installer, status script, uninstall script, and controlled test harness.
