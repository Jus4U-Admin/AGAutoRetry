[CmdletBinding()]
param(
    [switch]$RemoveFiles,
    [switch]$RemoveLogs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$baseDir = 'C:\ProgramData\AGAutoRetry'
$taskName = 'AG Auto Retry'
$watcherScript = Join-Path $baseDir 'ag-auto-retry.ps1'
$logPath = Join-Path $baseDir 'ag-auto-retry.log'
$filesToRemove = @(
    'ag-auto-retry.ps1',
    'launch-ag-auto-retry.vbs',
    'install-ag-auto-retry.ps1',
    'uninstall-ag-auto-retry.ps1',
    'status-ag-auto-retry.ps1',
    'test-harness-ag-retry.ps1',
    'README.md',
    'config.json',
    'test-harness-result.json'
)

Write-Output 'Stopping scheduled task and watcher processes...'

$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($null -ne $task) {
    try {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    }
    catch {
    }

    try {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Output ('Removed scheduled task: {0}' -f $taskName)
    }
    catch {
        Write-Output ('Failed to remove scheduled task: {0}' -f $_.Exception.Message)
    }
}
else {
    Write-Output ('Scheduled task not found: {0}' -f $taskName)
}

$watcherProcesses = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -eq 'powershell.exe' -and $_.CommandLine -match [regex]::Escape($watcherScript)
}

foreach ($process in $watcherProcesses) {
    try {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
        Write-Output ('Stopped watcher PID {0}' -f $process.ProcessId)
    }
    catch {
        Write-Output ('Failed to stop watcher PID {0}: {1}' -f $process.ProcessId, $_.Exception.Message)
    }
}

if ($RemoveFiles) {
    foreach ($fileName in $filesToRemove) {
        $path = Join-Path $baseDir $fileName
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            Write-Output ('Removed file: {0}' -f $path)
        }
    }

    if ($RemoveLogs -and (Test-Path -LiteralPath $logPath)) {
        Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue
        Write-Output ('Removed log: {0}' -f $logPath)
    }

    $remainingItems = Get-ChildItem -LiteralPath $baseDir -Force -ErrorAction SilentlyContinue
    if (-not $remainingItems) {
        Remove-Item -LiteralPath $baseDir -Force -ErrorAction SilentlyContinue
        Write-Output ('Removed directory: {0}' -f $baseDir)
    }
    else {
        Write-Output ('Directory kept with remaining items: {0}' -f $baseDir)
    }
}
else {
    Write-Output ('Files preserved in: {0}' -f $baseDir)
    Write-Output ('Logs preserved in: {0}' -f $logPath)
}
