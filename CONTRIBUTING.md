# Contributing

Thanks for helping improve AG Auto Retry.

## Scope

This project is intentionally narrow. Contributions should preserve that philosophy:

- target the Antigravity `Agent terminated due to error` popup only
- keep the automation local, auditable, and reversible
- avoid broadening the watcher into a general desktop auto-clicker

## Good Contribution Areas

- reliability improvements for UI Automation detection
- safer recovery and restart behavior
- better logging and diagnostics
- installation and uninstall polish
- documentation and reproducible troubleshooting notes

## Please Avoid

- automating unrelated buttons
- adding OCR or coordinate-based clicking
- introducing opaque third-party binaries
- increasing scope beyond the specific Retry dialog

## Development Notes

- the deployed runtime lives under `C:\ProgramData\AGAutoRetry`
- the repository installer copies project files into that location
- `test-harness-ag-retry.ps1` exists so changes can be validated without waiting for the real Antigravity error dialog

## Suggested Validation

Before opening a pull request:

1. Run `install-ag-auto-retry.ps1`
2. Verify the watcher starts and stays hidden
3. Run the controlled test harness flow
4. Confirm logs look sane
5. Confirm uninstall still works

## Pull Requests

Small, focused pull requests are easiest to review.

When possible, include:

- what changed
- why it changed
- how you validated it
