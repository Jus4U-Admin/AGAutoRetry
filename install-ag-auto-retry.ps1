[CmdletBinding()]
param(
    [switch]$SkipTest,
    [switch]$SkipAutoElevate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sourceDir = if ($PSScriptRoot) { $PSScriptRoot } elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$baseDir = 'C:\ProgramData\AGAutoRetry'
$taskName = 'AG Auto Retry'
$watcherPath = Join-Path $baseDir 'ag-auto-retry.ps1'
$launcherPath = Join-Path $baseDir 'launch-ag-auto-retry.vbs'
$statusPath = Join-Path $baseDir 'status-ag-auto-retry.ps1'
$harnessPath = Join-Path $baseDir 'test-harness-ag-retry.ps1'
$logPath = Join-Path $baseDir 'ag-auto-retry.log'
$packageFiles = @(
    'ag-auto-retry.ps1',
    'launch-ag-auto-retry.vbs',
    'install-ag-auto-retry.ps1',
    'uninstall-ag-auto-retry.ps1',
    'status-ag-auto-retry.ps1',
    'test-harness-ag-retry.ps1',
    'config.json',
    'README.md',
    'LICENSE',
    'CONTRIBUTING.md',
    '.gitignore'
)
$requiredFiles = @(
    $watcherPath,
    $launcherPath,
    (Join-Path $baseDir 'install-ag-auto-retry.ps1'),
    (Join-Path $baseDir 'uninstall-ag-auto-retry.ps1'),
    $statusPath,
    $harnessPath,
    (Join-Path $baseDir 'README.md'),
    (Join-Path $baseDir 'config.json')
)

function Write-Step {
    param([string]$Message)
    Write-Output ('[AGAutoRetry] {0}' -f $Message)
}

function Test-IsAdmin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-AutoElevateOnce {
    if ($SkipAutoElevate -or (Test-IsAdmin)) {
        return $false
    }

    $args = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $PSCommandPath),
        '-SkipAutoElevate'
    )

    if ($SkipTest) {
        $args += '-SkipTest'
    }

    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList ($args -join ' ')
    return $true
}

function Ensure-BaseDirectory {
    try {
        New-Item -ItemType Directory -Path $baseDir -Force -ErrorAction Stop | Out-Null
    }
    catch {
        if (Invoke-AutoElevateOnce) {
            exit 0
        }

        throw
    }
}

function Sync-PackageFiles {
    Write-Step ('Copying package files from "{0}" to "{1}"...' -f $sourceDir, $baseDir)

    foreach ($fileName in $packageFiles) {
        $sourcePath = Join-Path $sourceDir $fileName
        if (-not (Test-Path -LiteralPath $sourcePath)) {
            throw ('Package file not found: {0}' -f $sourcePath)
        }

        $destinationPath = Join-Path $baseDir $fileName
        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
    }
}

function Test-Prerequisites {
    Write-Step 'Validating prerequisites...'
    Get-Command Register-ScheduledTask -ErrorAction Stop | Out-Null
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes

    foreach ($path in $requiredFiles) {
        if (-not (Test-Path -LiteralPath $path)) {
            throw ('Required file not found: {0}' -f $path)
        }
    }
}

function Register-OrUpdateTask {
    Write-Step 'Registering scheduled task...'

    $currentUser = '{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME
    $arguments = '"{0}"' -f $launcherPath
    $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
    $keepAliveTrigger = New-ScheduledTaskTrigger `
        -Once `
        -At (Get-Date).AddMinutes(1) `
        -RepetitionInterval (New-TimeSpan -Minutes 1) `
        -RepetitionDuration (New-TimeSpan -Days 3650)
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan) `
        -Hidden `
        -MultipleInstances IgnoreNew `
        -RestartCount 999 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -StartWhenAvailable
    $principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Limited

    try {
        Register-ScheduledTask `
            -TaskName $taskName `
            -Description 'Clicks Retry in the Antigravity popup "Agent terminated due to error" when the exact popup is detected.' `
            -Action $action `
            -Trigger @($trigger, $keepAliveTrigger) `
            -Settings $settings `
            -Principal $principal `
            -Force | Out-Null
    }
    catch {
        if (Invoke-AutoElevateOnce) {
            exit 0
        }

        throw
    }
}

function Start-ProductionWatcher {
    Write-Step 'Starting production watcher task...'
    Start-ScheduledTask -TaskName $taskName
    Start-Sleep -Seconds 2
}

function Stop-ProductionWatcher {
    Write-Step 'Stopping production watcher for controlled test...'

    try {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    }
    catch {
    }

    $watcherProcesses = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -eq 'powershell.exe' -and $_.CommandLine -match [regex]::Escape($watcherPath)
    }

    foreach ($process in $watcherProcesses) {
        try {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
        }
        catch {
        }
    }

    Start-Sleep -Seconds 1
}

function Assert-ProductionWatcherRunning {
    Write-Step 'Checking production watcher status...'
    $watcherProcesses = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -eq 'powershell.exe' -and $_.CommandLine -match [regex]::Escape($watcherPath)
    }

    if (-not $watcherProcesses) {
        $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName
        throw ('Watcher process was not found. Task result: {0}' -f $taskInfo.LastTaskResult)
    }
}

function Invoke-ControlledTest {
    Write-Step 'Running controlled local test harness...'

    $resultPath = Join-Path $baseDir 'test-harness-result.json'
    $logBefore = if (Test-Path -LiteralPath $logPath) { @(Get-Content -LiteralPath $logPath) } else { @() }
    if (Test-Path -LiteralPath $resultPath) {
        Remove-Item -LiteralPath $resultPath -Force
    }

    $watcherArgs = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Mode TestHarness -ExitAfterFirstRetry' -f $watcherPath
    $testWatcher = Start-Process -FilePath 'powershell.exe' -ArgumentList $watcherArgs -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 800

    $harnessArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -ResultPath "{1}"' -f $harnessPath, $resultPath
    $harness = Start-Process -FilePath 'powershell.exe' -ArgumentList $harnessArgs -PassThru

    $deadline = (Get-Date).AddSeconds(20)
    $result = $null
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $resultPath) {
            $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
            if ($result.retryClicked) {
                break
            }

            $harness.Refresh()
            if ($harness.HasExited) {
                break
            }
        }

        Start-Sleep -Milliseconds 400
    }

    if ($null -eq $result) {
        try {
            if (-not $harness.HasExited) {
                Stop-Process -Id $harness.Id -Force -ErrorAction SilentlyContinue
            }
        }
        catch {
        }

        try {
            if (-not $testWatcher.HasExited) {
                Stop-Process -Id $testWatcher.Id -Force -ErrorAction SilentlyContinue
            }
        }
        catch {
        }

        throw 'Controlled test did not produce a result file in time.'
    }

    if (-not $testWatcher.WaitForExit(10000)) {
        Stop-Process -Id $testWatcher.Id -Force -ErrorAction SilentlyContinue
        throw 'Controlled test watcher did not exit in time.'
    }

    $testWatcher.Refresh()
    if ($testWatcher.ExitCode -ne 0) {
        throw ('Controlled test watcher exited with code {0}' -f $testWatcher.ExitCode)
    }

    if (-not $result.retryClicked) {
        throw ('Controlled test failed: {0}' -f $result.reason)
    }

    $logAfter = if (Test-Path -LiteralPath $logPath) { @(Get-Content -LiteralPath $logPath) } else { @() }
    $newLogLines = @($logAfter | Select-Object -Skip $logBefore.Count)

    if (-not ($newLogLines -match 'mode=TestHarness')) {
        throw 'Controlled test did not record a TestHarness watcher start in the log.'
    }

    if (-not ($newLogLines -match 'Retry clicked')) {
        throw 'Controlled test did not record a Retry click in the log.'
    }
}

function Show-StatusSummary {
    Write-Step 'Status summary:'
    & $statusPath
}

Ensure-BaseDirectory
Sync-PackageFiles
Test-Prerequisites
Register-OrUpdateTask
Start-ProductionWatcher
Assert-ProductionWatcherRunning

if (-not $SkipTest) {
    Stop-ProductionWatcher
    try {
        Invoke-ControlledTest
    }
    finally {
        Start-ProductionWatcher
        Assert-ProductionWatcherRunning
    }
}

Show-StatusSummary
Write-Step ('Installation completed. Log: {0}' -f $logPath)
