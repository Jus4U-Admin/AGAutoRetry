# AG Auto Retry

AG Auto Retry is a focused Windows watcher for Antigravity.

It is also a local, no-patch alternative for people who found this problem through patch-based approaches such as `BigInt`.

It automatically clicks `Retry` when Antigravity shows the exact failure popup that contains all of these markers:

- `Agent terminated due to error`
- `Copy debug info`
- `Retry`

The goal is simple: remove the need for someone to sit in front of the screen waiting to manually click `Retry` when this known dialog appears.

## Search Terms

If you found this repository by searching for any of the terms below, you are in the right place:

- `Agent terminated due to error + Retry - errors 500, 503, 429 e 504`
- `Agent terminated due to error Retry 500`
- `Agent terminated due to error Retry 503`
- `Agent terminated due to error Retry 429`
- `Agent terminated due to error Retry 504`
- `error antigravity 503`
- `antigravity error 503`
- `antigravity 503 error`
- `error antigravity 500`
- `antigravity error 500`
- `error antigravity 429`
- `antigravity error 429`
- `error antigravity 504`
- `antigravity error 504`
- `agent terminated due to error antigravity`
- `BigInt Antigravity`
- `BigInt Antigravity patch`
- `BigInt alternative Antigravity`
- `BigInt Retry Antigravity`
- `Agent terminated due to error BigInt`

## Why This Project Exists

Some Antigravity workflows can stall on a recoverable error dialog that still requires a manual retry click.

This project packages a narrow, local-only automation that:

- runs in the interactive Windows session
- starts at user logon
- stays hidden
- writes local logs
- only clicks `Retry` when the popup signature matches exactly

If the popup does not match, it does nothing.

## If You Found BigInt

Some people arrive here after finding patch-based fixes such as `BigInt`.

AG Auto Retry is a different approach:

- it does not patch Antigravity
- it stays local to the Windows user session
- it is reversible and easy to uninstall
- it is intentionally limited to the exact `Retry` popup signature

If you want a narrower workaround that avoids modifying Antigravity itself, this repository is meant for that use case.

## Features

- Windows-native implementation
- PowerShell + .NET UI Automation
- Hidden runtime
- Scheduled Task startup at logon
- Keepalive trigger for self-recovery
- Single-instance protection
- Best-effort focus return to the previous app after `Retry`
- Preserves maximized windows when returning focus
- Cooldown between retry attempts
- Safety cap on retries per execution
- Controlled local test harness
- Status and diagnostics script
- Clean uninstall script
- No third-party clicker tools required

## Safety Boundaries

AG Auto Retry is intentionally strict.

It will not:

- patch Antigravity
- inject into Antigravity internals
- click `Dismiss`
- click `Copy debug info`
- click `Run`
- click `Accept`
- click `Always Allow`
- use OCR
- use coordinate-based clicking
- depend on a terminal staying open

It only acts when it sees the full intended popup signature in an Antigravity window.

## Architecture

The solution uses:

- a PowerShell watcher
- .NET UI Automation via `System.Windows.Automation`
- a hidden `wscript.exe` launcher
- a Windows Scheduled Task named `AG Auto Retry`
- the interactive user session at logon

Runtime deployment target:

- `C:\ProgramData\AGAutoRetry`

## How Detection Works

The watcher scans Antigravity UI descendants and only proceeds when it can find:

1. the text `Agent terminated due to error`
2. a visible `Copy debug info` button
3. a visible `Retry` button

Only then does it invoke `Retry`.

## Repository Layout

- `ag-auto-retry.ps1` - main watcher
- `launch-ag-auto-retry.vbs` - hidden launcher for the Scheduled Task
- `install-ag-auto-retry.ps1` - installs the package into `C:\ProgramData\AGAutoRetry`
- `uninstall-ag-auto-retry.ps1` - stops and removes the task
- `status-ag-auto-retry.ps1` - prints current task/process/log status
- `test-harness-ag-retry.ps1` - local popup simulator for validation
- `config.json` - cooldown, polling, retry cap, and target settings
- `README.md` - project overview

## Installation

Clone or download this repository anywhere on the machine, then run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install-ag-auto-retry.ps1
```

The installer will:

- create `C:\ProgramData\AGAutoRetry`
- copy the package files there
- register or update the Scheduled Task
- start the watcher
- verify that the watcher is active
- run a controlled local validation unless `-SkipTest` is used

If elevation is needed to write under `ProgramData`, the installer attempts one self-elevation.

## Runtime Behavior

Once installed:

- the watcher starts at logon
- it stays hidden
- it writes logs to `C:\ProgramData\AGAutoRetry\ag-auto-retry.log`
- after clicking `Retry`, it can attempt to restore focus to the app that was active before the Antigravity popup took focus
- if the process is closed by mistake, the keepalive trigger relaunches it automatically

## Status and Diagnostics

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\AGAutoRetry\status-ag-auto-retry.ps1
```

The status script reports:

- whether the Scheduled Task exists
- whether it is registered
- whether the watcher process is running
- the last task result
- the log path
- recent log lines

## Controlled Test Harness

The repository ships with a local validation harness that simulates the target popup:

- `Agent terminated due to error`
- `Dismiss`
- `Copy debug info`
- `Retry`

This allows reproducible testing without waiting for the real Antigravity failure dialog.

## Uninstall

Remove the Scheduled Task and stop the watcher:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\AGAutoRetry\uninstall-ag-auto-retry.ps1
```

Remove the deployed files too:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\AGAutoRetry\uninstall-ag-auto-retry.ps1 -RemoveFiles
```

Remove everything including logs:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\AGAutoRetry\uninstall-ag-auto-retry.ps1 -RemoveFiles -RemoveLogs
```

## Limitations

- Windows only
- intentionally specific to Antigravity
- intentionally limited to one popup signature
- depends on Antigravity exposing the popup via UI Automation in the user session

## Not Affiliated

This is an independent community utility and is not an official Antigravity project.

## Contributing

Contributions are welcome, especially around:

- making detection more robust without widening scope unsafely
- documentation improvements
- safer validation patterns
- Windows tasking and recovery hardening

See [CONTRIBUTING.md](./CONTRIBUTING.md) for a lightweight contribution guide.
