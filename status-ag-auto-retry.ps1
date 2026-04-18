[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$baseDir = 'C:\ProgramData\AGAutoRetry'
$taskName = 'AG Auto Retry'
$logPath = Join-Path $baseDir 'ag-auto-retry.log'
$watcherScript = Join-Path $baseDir 'ag-auto-retry.ps1'

function Resolve-TaskResultText {
    param([UInt64]$Code)

    switch ($Code) {
        0 { return '0 (Success)' }
        267008 { return '267008 (Task ready)' }
        267009 { return '267009 (Task running)' }
        2147942402 { return '2147942402 (File not found)' }
        2147946720 { return '2147946720 (Launch ignored because an instance is already running, 0x800710E0)' }
        3221225786 { return '3221225786 (Interrupted or terminated, 0xC000013A)' }
        default {
            if ($Code -le [UInt32]::MaxValue) {
                return ('{0} (0x{1})' -f $Code, ([UInt32]$Code).ToString('X8'))
            }

            return [string]$Code
        }
    }
}

$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
$taskInfo = $null
if ($null -ne $task) {
    $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName
}

$watcherProcesses = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -eq 'powershell.exe' -and $_.CommandLine -match [regex]::Escape($watcherScript)
}

Write-Output ('task_exists: {0}' -f [bool]($null -ne $task))
Write-Output ('task_registered: {0}' -f [bool]($null -ne $task))
Write-Output ('task_state: {0}' -f ($(if ($null -ne $task) { $task.State } else { 'missing' })))
Write-Output ('task_last_run_time: {0}' -f ($(if ($null -ne $taskInfo) { $taskInfo.LastRunTime } else { 'n/a' })))
Write-Output ('task_last_result: {0}' -f ($(if ($null -ne $taskInfo) { Resolve-TaskResultText -Code $taskInfo.LastTaskResult } else { 'n/a' })))
Write-Output ('watcher_running: {0}' -f [bool]($watcherProcesses))
Write-Output ('watcher_pids: {0}' -f ($(if ($watcherProcesses) { (($watcherProcesses | Select-Object -ExpandProperty ProcessId) -join ', ') } else { 'n/a' })))
Write-Output ('log_path: {0}' -f $logPath)
Write-Output 'log_tail:'

if (Test-Path -LiteralPath $logPath) {
    Get-Content -LiteralPath $logPath -Tail 20
}
else {
    Write-Output 'log file not found'
}
