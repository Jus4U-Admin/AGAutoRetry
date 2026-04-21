[CmdletBinding()]
param(
    [ValidateSet('Production', 'TestHarness')]
    [string]$Mode = 'Production',

    [switch]$ExitAfterFirstRetry,

    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $script:ScriptRoot 'config.json'
}

function Initialize-NativeMethods {
    if (-not ('AGAutoRetry.NativeMethods' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace AGAutoRetry
{
    public static class NativeMethods
    {
        [DllImport("kernel32.dll")]
        public static extern IntPtr GetConsoleWindow();

        [DllImport("user32.dll")]
        public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out int lpdwProcessId);

        [DllImport("user32.dll")]
        public static extern bool SetForegroundWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool IsWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool IsWindowVisible(IntPtr hWnd);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool IsIconic(IntPtr hWnd);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool IsZoomed(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern IntPtr GetAncestor(IntPtr hWnd, uint gaFlags);
    }
}
'@
    }
}

function Hide-ConsoleWindow {
    try {
        Initialize-NativeMethods
        $consoleHandle = [AGAutoRetry.NativeMethods]::GetConsoleWindow()
        if ($consoleHandle -ne [IntPtr]::Zero) {
            [AGAutoRetry.NativeMethods]::ShowWindow($consoleHandle, 0) | Out-Null
        }
    }
    catch {
    }
}

function Get-DefaultConfig {
    return [ordered]@{
        TaskName                    = 'AG Auto Retry'
        LogPath                     = (Join-Path $script:ScriptRoot 'ag-auto-retry.log')
        PollIntervalMilliseconds    = 1000
        CooldownSeconds             = 10
        MaxRetriesPerRun            = 1000
        RequiredMarkerText          = 'Agent terminated due to error'
        RequiredCompanionButtonText = 'Copy debug info'
        RetryButtonText             = 'Retry'
        TargetProcessNames          = @('Antigravity')
        HarnessWindowTitle          = 'AG Auto Retry Harness'
        RestorePreviousFocusAfterRetry = $true
        FocusRestoreDelayMilliseconds  = 250
        FocusStealDetectionWindowSeconds = 5
        LogFlushIntervalMilliseconds   = 1000
        LogFlushBatchSize              = 50
    }
}

function Merge-Config {
    param(
        [System.Collections.IDictionary]$BaseConfig,
        [object]$OverrideConfig
    )

    if ($null -eq $OverrideConfig) {
        return $BaseConfig
    }

    foreach ($property in $OverrideConfig.PSObject.Properties) {
        $BaseConfig[$property.Name] = $property.Value
    }

    return $BaseConfig
}

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $line = '{0} [{1}] {2}' -f $timestamp, $Level.ToUpperInvariant(), $Message
    $null = $script:LogQueue.Enqueue($line)
}

function Flush-LogQueue {
    param([switch]$Force)

    if ($null -eq $script:LogQueue) {
        return
    }

    $queuedCount = $script:LogQueue.Count
    if ($queuedCount -eq 0) {
        return
    }

    if (-not $Force) {
        $flushBatchSize = if ($null -ne $script:Config) { [int]$script:Config.LogFlushBatchSize } else { 50 }
        $now = Get-Date
        if ($queuedCount -lt $flushBatchSize -and $now -lt $script:NextLogFlushAt) {
            return
        }
    }

    $buffer = New-Object System.Text.StringBuilder
    $line = $null
    while ($script:LogQueue.TryDequeue([ref]$line)) {
        [void]$buffer.AppendLine($line)
    }

    if ($buffer.Length -eq 0) {
        return
    }

    [System.IO.File]::AppendAllText($script:LogPath, $buffer.ToString(), [System.Text.Encoding]::UTF8)
    $flushIntervalMs = if ($null -ne $script:Config) { [int]$script:Config.LogFlushIntervalMilliseconds } else { 1000 }
    $script:NextLogFlushAt = (Get-Date).AddMilliseconds($flushIntervalMs)
}

function Initialize-Configuration {
    $config = Get-DefaultConfig

    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $loaded = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
            $config = Merge-Config -BaseConfig $config -OverrideConfig $loaded
        }
        catch {
            Write-Log -Level 'WARN' -Message ('Failed to parse config "{0}": {1}. Using defaults.' -f $ConfigPath, $_.Exception.Message)
        }
    }

    $script:Config = $config
    $script:LogPath = $config.LogPath

    if (-not (Test-Path -LiteralPath $script:LogPath)) {
        New-Item -ItemType File -Path $script:LogPath -Force | Out-Null
    }
}

function Import-UiAutomationAssemblies {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
}

function Get-TargetProcessIds {
    param([string]$CurrentMode)

    if ($CurrentMode -eq 'Production') {
        $names = @($script:Config.TargetProcessNames)
        $processes = Get-Process -ErrorAction SilentlyContinue | Where-Object { $names -contains $_.ProcessName }
        return @($processes | Select-Object -ExpandProperty Id)
    }

    return @()
}

function Get-TopLevelWindowsForProcessIds {
    param([int[]]$ProcessIds)

    if (-not $ProcessIds -or $ProcessIds.Count -eq 0) {
        return @()
    }

    $desktop = [System.Windows.Automation.AutomationElement]::RootElement
    $children = $desktop.FindAll(
        [System.Windows.Automation.TreeScope]::Children,
        [System.Windows.Automation.Condition]::TrueCondition
    )

    $result = New-Object System.Collections.Generic.List[System.Windows.Automation.AutomationElement]
    for ($index = 0; $index -lt $children.Count; $index++) {
        $window = $children.Item($index)
        try {
            if (($ProcessIds -contains $window.Current.ProcessId) -and (-not $window.Current.IsOffscreen)) {
                [void]$result.Add($window)
            }
        }
        catch {
        }
    }

    return $result.ToArray()
}

function Get-TestHarnessWindows {
    $desktop = [System.Windows.Automation.AutomationElement]::RootElement
    $children = $desktop.FindAll(
        [System.Windows.Automation.TreeScope]::Children,
        [System.Windows.Automation.Condition]::TrueCondition
    )

    $result = New-Object System.Collections.Generic.List[System.Windows.Automation.AutomationElement]
    for ($index = 0; $index -lt $children.Count; $index++) {
        $window = $children.Item($index)
        try {
            if (($window.Current.Name -eq $script:Config.HarnessWindowTitle) -and (-not $window.Current.IsOffscreen)) {
                [void]$result.Add($window)
            }
        }
        catch {
        }
    }

    return $result.ToArray()
}

function Find-DescendantsByName {
    param(
        [System.Windows.Automation.AutomationElement]$Root,
        [string]$Name
    )

    $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::NameProperty,
        $Name
    )

    $collection = $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)
    $result = New-Object System.Collections.Generic.List[System.Windows.Automation.AutomationElement]
    for ($index = 0; $index -lt $collection.Count; $index++) {
        [void]$result.Add($collection.Item($index))
    }

    return $result.ToArray()
}

function Find-VisibleButtonsByName {
    param(
        [System.Windows.Automation.AutomationElement]$Root,
        [string]$Name
    )

    $elements = @(Find-DescendantsByName -Root $Root -Name $Name)
    $buttons = New-Object System.Collections.Generic.List[System.Windows.Automation.AutomationElement]

    foreach ($element in $elements) {
        try {
            if (($element.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button) -and (-not $element.Current.IsOffscreen)) {
                [void]$buttons.Add($element)
            }
        }
        catch {
        }
    }

    return $buttons.ToArray()
}

function Find-FirstElementByName {
    param(
        [System.Windows.Automation.AutomationElement]$Root,
        [string]$Name
    )

    $matches = @(Find-DescendantsByName -Root $Root -Name $Name)
    if ($matches.Count -gt 0) {
        return $matches[0]
    }

    return $null
}

function Find-FirstVisibleButtonByName {
    param(
        [System.Windows.Automation.AutomationElement]$Root,
        [string]$Name
    )

    $matches = @(Find-VisibleButtonsByName -Root $Root -Name $Name)
    if ($matches.Count -gt 0) {
        return $matches[0]
    }

    return $null
}

function Find-MatchingPopupInWindow {
    param([System.Windows.Automation.AutomationElement]$Window)

    $retryButtons = @(Find-VisibleButtonsByName -Root $Window -Name $script:Config.RetryButtonText)
    if (-not $retryButtons -or $retryButtons.Count -eq 0) {
        return $null
    }

    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker

    foreach ($retryButton in $retryButtons) {
        $current = $retryButton
        for ($depth = 0; $depth -lt 10 -and $null -ne $current; $depth++) {
            $marker = Find-FirstElementByName -Root $current -Name $script:Config.RequiredMarkerText
            $copyButton = Find-FirstVisibleButtonByName -Root $current -Name $script:Config.RequiredCompanionButtonText

            if ($null -ne $marker -and $null -ne $copyButton) {
                return [pscustomobject]@{
                    RetryButton = $retryButton
                    CopyButton  = $copyButton
                    Marker      = $marker
                    Container   = $current
                    Window      = $Window
                }
            }

            try {
                $current = $walker.GetParent($current)
            }
            catch {
                $current = $null
            }
        }
    }

    return $null
}

function Get-ProcessNameById {
    param([int]$ProcessId)

    try {
        return (Get-Process -Id $ProcessId -ErrorAction Stop).ProcessName
    }
    catch {
        return 'unknown'
    }
}

function Format-WindowHandle {
    param([IntPtr]$Handle)

    if ($Handle -eq [IntPtr]::Zero) {
        return '0x0'
    }

    return ('0x{0}' -f $Handle.ToInt64().ToString('X'))
}

function Get-AutomationElementWindowHandle {
    param([System.Windows.Automation.AutomationElement]$Element)

    if ($null -eq $Element) {
        return [IntPtr]::Zero
    }

    try {
        return [IntPtr]::new([int64]$Element.Current.NativeWindowHandle)
    }
    catch {
        return [IntPtr]::Zero
    }
}

function Get-TopLevelWindowHandle {
    param([IntPtr]$Handle)

    if ($Handle -eq [IntPtr]::Zero) {
        return [IntPtr]::Zero
    }

    try {
        $topLevelHandle = [AGAutoRetry.NativeMethods]::GetAncestor($Handle, 2)
        if ($topLevelHandle -ne [IntPtr]::Zero) {
            return $topLevelHandle
        }
    }
    catch {
    }

    return $Handle
}

function Get-WindowProcessId {
    param([IntPtr]$Handle)

    if ($Handle -eq [IntPtr]::Zero) {
        return $null
    }

    $Handle = Get-TopLevelWindowHandle -Handle $Handle

    $processId = 0
    [AGAutoRetry.NativeMethods]::GetWindowThreadProcessId($Handle, [ref]$processId) | Out-Null
    if ($processId -le 0) {
        return $null
    }

    return $processId
}

function Get-WindowTitleFromHandle {
    param([IntPtr]$Handle)

    if ($Handle -eq [IntPtr]::Zero) {
        return ''
    }

    $Handle = Get-TopLevelWindowHandle -Handle $Handle

    try {
        $element = [System.Windows.Automation.AutomationElement]::FromHandle($Handle)
        if ($null -ne $element) {
            return $element.Current.Name
        }
    }
    catch {
    }

    return ''
}

function Clear-PendingFocusRestore {
    $script:PendingFocusRestoreWindow = [IntPtr]::Zero
    $script:PendingFocusRestoreProcessId = $null
    $script:PendingFocusRestoreWindowTitle = ''
}

function Set-PendingFocusRestoreWindow {
    param(
        [IntPtr]$Handle,
        [int]$ProcessId,
        [string]$WindowTitle,
        [int]$TargetProcessId,
        [string]$Reason
    )

    if (-not [bool]$script:Config.RestorePreviousFocusAfterRetry) {
        Clear-PendingFocusRestore
        return $false
    }

    $Handle = Get-TopLevelWindowHandle -Handle $Handle
    if ($Handle -eq [IntPtr]::Zero) {
        Clear-PendingFocusRestore
        return $false
    }

    if (-not [AGAutoRetry.NativeMethods]::IsWindow($Handle)) {
        Clear-PendingFocusRestore
        return $false
    }

    if ($null -eq $ProcessId -or $ProcessId -le 0) {
        $ProcessId = Get-WindowProcessId -Handle $Handle
    }

    if ($null -eq $ProcessId -or $ProcessId -le 0) {
        Clear-PendingFocusRestore
        return $false
    }

    if (($ProcessId -eq $TargetProcessId) -or ($ProcessId -eq $PID)) {
        Clear-PendingFocusRestore
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($WindowTitle)) {
        $WindowTitle = Get-WindowTitleFromHandle -Handle $Handle
    }

    $script:PendingFocusRestoreWindow = $Handle
    $script:PendingFocusRestoreProcessId = $ProcessId
    $script:PendingFocusRestoreWindowTitle = $WindowTitle

    Write-Log -Message ('Focus restore armed from {0}. pid={1}; windowHandle={2}; window="{3}"' -f $Reason, $ProcessId, (Format-WindowHandle -Handle $Handle), $WindowTitle)
    return $true
}

function Clear-FocusStealCandidate {
    $script:FocusStealCandidateWindow = [IntPtr]::Zero
    $script:FocusStealCandidateProcessId = $null
    $script:FocusStealCandidateWindowTitle = ''
    $script:FocusStealCandidateExpiresAt = $null
}

function Update-LastExternalForegroundWindow {
    param([int[]]$ExcludedProcessIds)

    if (-not [bool]$script:Config.RestorePreviousFocusAfterRetry) {
        return
    }

    $foregroundHandle = [AGAutoRetry.NativeMethods]::GetForegroundWindow()
    if ($foregroundHandle -eq [IntPtr]::Zero) {
        return
    }

    $foregroundHandle = Get-TopLevelWindowHandle -Handle $foregroundHandle

    if (-not [AGAutoRetry.NativeMethods]::IsWindow($foregroundHandle)) {
        return
    }

    $foregroundProcessId = Get-WindowProcessId -Handle $foregroundHandle
    if ($null -eq $foregroundProcessId -or $foregroundProcessId -le 0) {
        return
    }

    if ($foregroundProcessId -eq $PID) {
        return
    }

    if ($ExcludedProcessIds -contains $foregroundProcessId) {
        return
    }

    $script:LastExternalForegroundWindow = $foregroundHandle
    $script:LastExternalForegroundProcessId = $foregroundProcessId
    $script:LastExternalForegroundWindowTitle = Get-WindowTitleFromHandle -Handle $foregroundHandle
    $script:LastExternalForegroundSeenAt = Get-Date
}

function Stage-FocusStealCandidate {
    param([int]$TargetProcessId)

    if (-not [bool]$script:Config.RestorePreviousFocusAfterRetry) {
        Clear-FocusStealCandidate
        return
    }

    $externalHandle = $script:LastExternalForegroundWindow
    if ($externalHandle -eq [IntPtr]::Zero) {
        Clear-FocusStealCandidate
        return
    }

    if (-not [AGAutoRetry.NativeMethods]::IsWindow($externalHandle)) {
        Clear-FocusStealCandidate
        return
    }

    $externalProcessId = Get-WindowProcessId -Handle $externalHandle
    if ($null -eq $externalProcessId -or $externalProcessId -le 0) {
        Clear-FocusStealCandidate
        return
    }

    if (($externalProcessId -eq $TargetProcessId) -or ($externalProcessId -eq $PID)) {
        Clear-FocusStealCandidate
        return
    }

    $script:FocusStealCandidateWindow = $externalHandle
    $script:FocusStealCandidateProcessId = $externalProcessId
    $script:FocusStealCandidateWindowTitle = $script:LastExternalForegroundWindowTitle
    $script:FocusStealCandidateExpiresAt = (Get-Date).AddSeconds([int]$script:Config.FocusStealDetectionWindowSeconds)

    Write-Log -Message ('Focus steal candidate staged. pid={0}; windowHandle={1}; window="{2}"' -f $externalProcessId, (Format-WindowHandle -Handle $externalHandle), $script:FocusStealCandidateWindowTitle)
}

function Promote-FocusStealCandidateToPendingRestore {
    if ($script:FocusStealCandidateWindow -eq [IntPtr]::Zero) {
        return $false
    }

    if ($null -ne $script:FocusStealCandidateExpiresAt -and (Get-Date) -gt $script:FocusStealCandidateExpiresAt) {
        Clear-FocusStealCandidate
        return $false
    }

    $armed = Set-PendingFocusRestoreWindow `
        -Handle $script:FocusStealCandidateWindow `
        -ProcessId $script:FocusStealCandidateProcessId `
        -WindowTitle $script:FocusStealCandidateWindowTitle `
        -TargetProcessId 0 `
        -Reason 'focus-steal candidate'
    Clear-FocusStealCandidate
    return $armed
}

function Try-ArmRecentExternalFocusRestore {
    param([int]$TargetProcessId)

    if ($script:PendingFocusRestoreWindow -ne [IntPtr]::Zero) {
        return $true
    }

    if ($script:LastExternalForegroundWindow -eq [IntPtr]::Zero -or $null -eq $script:LastExternalForegroundSeenAt) {
        return $false
    }

    $maxAge = [TimeSpan]::FromSeconds([int]$script:Config.FocusStealDetectionWindowSeconds)
    if (((Get-Date) - $script:LastExternalForegroundSeenAt) -gt $maxAge) {
        return $false
    }

    $externalHandle = $script:LastExternalForegroundWindow
    if (-not [AGAutoRetry.NativeMethods]::IsWindow($externalHandle)) {
        return $false
    }

    $externalProcessId = $script:LastExternalForegroundProcessId
    if ($null -eq $externalProcessId -or $externalProcessId -le 0) {
        $externalProcessId = Get-WindowProcessId -Handle $externalHandle
    }

    if ($null -eq $externalProcessId -or $externalProcessId -le 0) {
        return $false
    }

    if (($externalProcessId -eq $TargetProcessId) -or ($externalProcessId -eq $PID)) {
        return $false
    }

    return (Set-PendingFocusRestoreWindow `
        -Handle $externalHandle `
        -ProcessId $externalProcessId `
        -WindowTitle $script:LastExternalForegroundWindowTitle `
        -TargetProcessId $TargetProcessId `
        -Reason 'recent external focus')
}

function Try-ArmExactForegroundFocusRestore {
    param(
        [IntPtr]$ForegroundHandle,
        [int[]]$TargetProcessIds,
        [int]$TargetProcessId
    )

    if (-not [bool]$script:Config.RestorePreviousFocusAfterRetry) {
        return $false
    }

    $ForegroundHandle = Get-TopLevelWindowHandle -Handle $ForegroundHandle
    if ($ForegroundHandle -eq [IntPtr]::Zero) {
        return $false
    }

    if (-not [AGAutoRetry.NativeMethods]::IsWindow($ForegroundHandle)) {
        return $false
    }

    $foregroundProcessId = Get-WindowProcessId -Handle $ForegroundHandle
    if ($null -eq $foregroundProcessId -or $foregroundProcessId -le 0) {
        return $false
    }

    if (($foregroundProcessId -eq $PID) -or ($TargetProcessIds -contains $foregroundProcessId)) {
        return $false
    }

    return (Set-PendingFocusRestoreWindow `
        -Handle $ForegroundHandle `
        -ProcessId $foregroundProcessId `
        -WindowTitle (Get-WindowTitleFromHandle -Handle $ForegroundHandle) `
        -TargetProcessId $TargetProcessId `
        -Reason 'exact pre-click foreground')
}

function Update-FocusStealState {
    param(
        [IntPtr]$ForegroundHandle,
        [int[]]$TargetProcessIds,
        [int]$PreviousForegroundProcessId
    )

    if (-not [bool]$script:Config.RestorePreviousFocusAfterRetry) {
        Clear-FocusStealCandidate
        Clear-PendingFocusRestore
        return
    }

    $ForegroundHandle = Get-TopLevelWindowHandle -Handle $ForegroundHandle

    $foregroundProcessId = Get-WindowProcessId -Handle $ForegroundHandle
    if ($null -eq $foregroundProcessId -or $foregroundProcessId -le 0) {
        Clear-FocusStealCandidate
        return
    }

    $isTargetForeground = $TargetProcessIds -contains $foregroundProcessId
    $wasTargetForeground = ($PreviousForegroundProcessId -gt 0) -and ($TargetProcessIds -contains $PreviousForegroundProcessId)

    if ($isTargetForeground -and (-not $wasTargetForeground)) {
        Stage-FocusStealCandidate -TargetProcessId $foregroundProcessId
        return
    }

    if (-not $isTargetForeground) {
        if ($script:FocusStealCandidateWindow -ne [IntPtr]::Zero) {
            Clear-FocusStealCandidate
        }
        return
    }

    if ($script:FocusStealCandidateWindow -ne [IntPtr]::Zero -and $null -ne $script:FocusStealCandidateExpiresAt -and (Get-Date) -gt $script:FocusStealCandidateExpiresAt) {
        Write-Log -Message 'Focus steal candidate expired before popup confirmation.'
        Clear-FocusStealCandidate
    }
}

function Restore-FocusWindow {
    param(
        [IntPtr]$Handle,
        [int]$SavedProcessId,
        [string]$WindowTitle,
        [int]$TargetProcessId,
        [string]$ContextLabel = 'after Retry',
        [switch]$SkipDelay
    )

    if (-not [bool]$script:Config.RestorePreviousFocusAfterRetry) {
        return $false
    }

    if ($Handle -eq [IntPtr]::Zero) {
        return $false
    }

    if (-not [AGAutoRetry.NativeMethods]::IsWindow($Handle)) {
        Write-Log -Level 'WARN' -Message ('Focus restore failed {0}: saved window is no longer valid. windowHandle={1}' -f $ContextLabel, (Format-WindowHandle -Handle $Handle))
        return $false
    }

    if ($null -eq $SavedProcessId -or $SavedProcessId -le 0) {
        $SavedProcessId = Get-WindowProcessId -Handle $Handle
    }

    if ($null -eq $SavedProcessId -or $SavedProcessId -le 0) {
        Write-Log -Level 'WARN' -Message ('Focus restore failed {0}: saved window no longer has a resolvable process. windowHandle={1}' -f $ContextLabel, (Format-WindowHandle -Handle $Handle))
        return $false
    }

    if (($SavedProcessId -eq $TargetProcessId) -or ($SavedProcessId -eq $PID)) {
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($WindowTitle)) {
        $WindowTitle = Get-WindowTitleFromHandle -Handle $Handle
    }

    $currentForegroundHandle = Get-TopLevelWindowHandle -Handle ([AGAutoRetry.NativeMethods]::GetForegroundWindow())
    if ($currentForegroundHandle -eq $Handle) {
        Write-Log -Message ('Focus already correct {0}. pid={1}; windowHandle={2}; window="{3}"' -f $ContextLabel, $SavedProcessId, (Format-WindowHandle -Handle $Handle), $WindowTitle)
        return $true
    }

    if (-not $SkipDelay) {
        $delayMs = [int]$script:Config.FocusRestoreDelayMilliseconds
        if ($delayMs -gt 0) {
            Start-Sleep -Milliseconds $delayMs
        }
    }

    $windowIsMinimized = [AGAutoRetry.NativeMethods]::IsIconic($Handle)
    $windowIsMaximized = [AGAutoRetry.NativeMethods]::IsZoomed($Handle)

    if ($windowIsMinimized) {
        [AGAutoRetry.NativeMethods]::ShowWindowAsync($Handle, 9) | Out-Null
    }
    elseif ($windowIsMaximized) {
        [AGAutoRetry.NativeMethods]::ShowWindowAsync($Handle, 3) | Out-Null
    }

    [void][AGAutoRetry.NativeMethods]::SetForegroundWindow($Handle)

    $foregroundAfter = Get-TopLevelWindowHandle -Handle ([AGAutoRetry.NativeMethods]::GetForegroundWindow())
    if ($foregroundAfter -ne $Handle) {
        try {
            $element = [System.Windows.Automation.AutomationElement]::FromHandle($Handle)
            if ($null -ne $element) {
                $element.SetFocus()
            }
        }
        catch {
        }
    }
    if ($foregroundAfter -ne $Handle) {
        try {
            $shell = New-Object -ComObject WScript.Shell
            $activated = $shell.AppActivate($SavedProcessId)
            if ((-not $activated) -and (-not [string]::IsNullOrWhiteSpace($WindowTitle))) {
                $activated = $shell.AppActivate($WindowTitle)
            }
        }
        catch {
        }
    }

    $foregroundAfter = Get-TopLevelWindowHandle -Handle ([AGAutoRetry.NativeMethods]::GetForegroundWindow())
    if ($foregroundAfter -eq $Handle) {
        Write-Log -Message ('Focus restored {0}. pid={1}; windowHandle={2}; window="{3}"' -f $ContextLabel, $SavedProcessId, (Format-WindowHandle -Handle $Handle), $WindowTitle)
        return $true
    }

    Write-Log -Level 'WARN' -Message ('Focus restore did not succeed {0}. pid={1}; windowHandle={2}; window="{3}"' -f $ContextLabel, $SavedProcessId, (Format-WindowHandle -Handle $Handle), $WindowTitle)
    return $false
}

function Try-RestorePendingFocusBeforeRetry {
    param([int]$TargetProcessId)

    return Restore-FocusWindow `
        -Handle $script:PendingFocusRestoreWindow `
        -SavedProcessId $script:PendingFocusRestoreProcessId `
        -WindowTitle $script:PendingFocusRestoreWindowTitle `
        -TargetProcessId $TargetProcessId `
        -ContextLabel 'before Retry' `
        -SkipDelay
}

function Restore-PendingFocusWindow {
    param([int]$TargetProcessId)

    $handle = $script:PendingFocusRestoreWindow
    $savedProcessId = $script:PendingFocusRestoreProcessId
    $windowTitle = $script:PendingFocusRestoreWindowTitle
    Clear-PendingFocusRestore

    return Restore-FocusWindow `
        -Handle $handle `
        -SavedProcessId $savedProcessId `
        -WindowTitle $windowTitle `
        -TargetProcessId $TargetProcessId `
        -ContextLabel 'after Retry'
}

function Invoke-Retry {
    param([System.Windows.Automation.AutomationElement]$RetryButton)

    if (-not $RetryButton.Current.IsEnabled) {
        return $false
    }

    $patternObject = $null
    if (-not $RetryButton.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$patternObject)) {
        throw 'InvokePattern not available on Retry button.'
    }

    $invokePattern = [System.Windows.Automation.InvokePattern]$patternObject
    $invokePattern.Invoke()
    return $true
}

$script:Mutex = $null
$script:HasMutex = $false
$script:RetryCount = 0
$script:Config = $null
$script:LogPath = Join-Path $script:ScriptRoot 'ag-auto-retry.log'
$script:LogQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$script:NextLogFlushAt = Get-Date
$script:LastExternalForegroundWindow = [IntPtr]::Zero
$script:LastExternalForegroundProcessId = $null
$script:LastExternalForegroundWindowTitle = ''
$script:LastExternalForegroundSeenAt = $null
$script:PendingFocusRestoreWindow = [IntPtr]::Zero
$script:PendingFocusRestoreProcessId = $null
$script:PendingFocusRestoreWindowTitle = ''
$script:FocusStealCandidateWindow = [IntPtr]::Zero
$script:FocusStealCandidateProcessId = $null
$script:FocusStealCandidateWindowTitle = ''
$script:FocusStealCandidateExpiresAt = $null
$script:LastForegroundWindow = [IntPtr]::Zero
$script:LastForegroundProcessId = 0

try {
    Hide-ConsoleWindow
    Initialize-Configuration
    Import-UiAutomationAssemblies
    Initialize-NativeMethods

    $script:Mutex = New-Object System.Threading.Mutex($false, 'Local\AGAutoRetryWatcher')
    try {
        $script:HasMutex = $script:Mutex.WaitOne(0, $false)
    }
    catch [System.Threading.AbandonedMutexException] {
        $script:HasMutex = $true
    }

    if (-not $script:HasMutex) {
        exit 0
    }

    Write-Log -Message ('Watcher started. mode={0}; cooldown={1}s; poll={2}ms; maxRetries={3}' -f $Mode, $script:Config.CooldownSeconds, $script:Config.PollIntervalMilliseconds, $script:Config.MaxRetriesPerRun)

    while ($true) {
        if ($script:RetryCount -ge [int]$script:Config.MaxRetriesPerRun) {
            Write-Log -Level 'ERROR' -Message ('Safety limit reached ({0} retries). Watcher is stopping.' -f $script:Config.MaxRetriesPerRun)
            exit 90
        }

        try {
            if ($Mode -eq 'Production') {
                $processIds = @(Get-TargetProcessIds -CurrentMode $Mode)
                $windows = @(Get-TopLevelWindowsForProcessIds -ProcessIds $processIds)
                $excludedProcessIds = $processIds
            }
            else {
                $windows = @(Get-TestHarnessWindows)
                $excludedProcessIds = @(
                    $windows |
                    ForEach-Object {
                        try {
                            $_.Current.ProcessId
                        }
                        catch {
                        }
                    } |
                    Sort-Object -Unique
                )
            }

            Update-LastExternalForegroundWindow -ExcludedProcessIds $excludedProcessIds

            $foregroundHandle = Get-TopLevelWindowHandle -Handle ([AGAutoRetry.NativeMethods]::GetForegroundWindow())
            $loopForegroundProcessId = Get-WindowProcessId -Handle $foregroundHandle
            $loopStartedOutsideTarget = -not ($excludedProcessIds -contains $loopForegroundProcessId)
            if ($foregroundHandle -ne $script:LastForegroundWindow) {
                Update-FocusStealState -ForegroundHandle $foregroundHandle -TargetProcessIds $excludedProcessIds -PreviousForegroundProcessId $script:LastForegroundProcessId
                $script:LastForegroundWindow = $foregroundHandle
                $script:LastForegroundProcessId = $loopForegroundProcessId
            }
            elseif ($script:FocusStealCandidateWindow -ne [IntPtr]::Zero) {
                Update-FocusStealState -ForegroundHandle $foregroundHandle -TargetProcessIds $excludedProcessIds -PreviousForegroundProcessId $script:LastForegroundProcessId
            }

            foreach ($window in $windows) {
                $popup = Find-MatchingPopupInWindow -Window $window
                if ($null -eq $popup) {
                    continue
                }

                $processId = $window.Current.ProcessId
                $processName = Get-ProcessNameById -ProcessId $processId
                $windowName = $window.Current.Name
                Write-Log -Message ('Valid popup detected. pid={0}; process={1}; window="{2}"' -f $processId, $processName, $windowName)
                $currentForegroundHandle = Get-TopLevelWindowHandle -Handle ([AGAutoRetry.NativeMethods]::GetForegroundWindow())
                $currentForegroundProcessId = Get-WindowProcessId -Handle $currentForegroundHandle
                $exactForegroundRestoreArmed = Try-ArmExactForegroundFocusRestore `
                    -ForegroundHandle $currentForegroundHandle `
                    -TargetProcessIds $excludedProcessIds `
                    -TargetProcessId $processId

                if ((-not $exactForegroundRestoreArmed) -and ($excludedProcessIds -contains $currentForegroundProcessId)) {
                    if (-not (Promote-FocusStealCandidateToPendingRestore)) {
                        if ($loopStartedOutsideTarget) {
                            [void](Try-ArmRecentExternalFocusRestore -TargetProcessId $processId)
                        }
                    }
                }

                $preClickFocusRestored = $false
                if ((-not $exactForegroundRestoreArmed) -and ($excludedProcessIds -contains $currentForegroundProcessId) -and ($script:PendingFocusRestoreWindow -ne [IntPtr]::Zero)) {
                    $preClickFocusRestored = Try-RestorePendingFocusBeforeRetry -TargetProcessId $processId
                }

                $invoked = Invoke-Retry -RetryButton $popup.RetryButton
                if (-not $invoked) {
                    Write-Log -Message ('Retry button detected but still disabled. pid={0}; process={1}; window="{2}"' -f $processId, $processName, $windowName)
                    continue
                }

                $script:RetryCount++
                Write-Log -Message ('Retry clicked. pid={0}; process={1}; window="{2}"; retryCount={3}' -f $processId, $processName, $windowName, $script:RetryCount)

                if ($preClickFocusRestored) {
                    Clear-PendingFocusRestore
                }
                else {
                    [void](Restore-PendingFocusWindow -TargetProcessId $processId)
                }

                if ($ExitAfterFirstRetry) {
                    Write-Log -Message 'ExitAfterFirstRetry enabled. Watcher will stop now.'
                    exit 0
                }

                Start-Sleep -Seconds ([int]$script:Config.CooldownSeconds)
                break
            }
        }
        catch {
            Write-Log -Level 'ERROR' -Message ('Watcher loop error: {0}' -f $_.Exception.Message)
        }

        Flush-LogQueue
        Start-Sleep -Milliseconds ([int]$script:Config.PollIntervalMilliseconds)
    }
}
catch {
    Write-Log -Level 'ERROR' -Message ('Fatal watcher error: {0}' -f $_.Exception.Message)
    Flush-LogQueue -Force
    exit 1
}
finally {
    if ($script:HasMutex -and $null -ne $script:Mutex) {
        try {
            $script:Mutex.ReleaseMutex() | Out-Null
        }
        catch {
        }
    }

    if ($null -ne $script:Mutex) {
        $script:Mutex.Dispose()
    }

    if ($script:HasMutex) {
        Write-Log -Message 'Watcher stopped.'
        Flush-LogQueue -Force
    }
}
