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
    [System.IO.File]::AppendAllText($script:LogPath, $line + [Environment]::NewLine, [System.Text.Encoding]::UTF8)
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
}

function Update-PendingFocusRestoreCandidate {
    param(
        [System.Windows.Automation.AutomationElement[]]$TargetWindows,
        [IntPtr]$ForegroundHandle,
        [int[]]$TargetProcessIds
    )

    if (-not [bool]$script:Config.RestorePreviousFocusAfterRetry) {
        Clear-PendingFocusRestore
        return
    }

    $ForegroundHandle = Get-TopLevelWindowHandle -Handle $ForegroundHandle

    $foregroundProcessId = Get-WindowProcessId -Handle $ForegroundHandle
    if ($null -eq $foregroundProcessId -or $foregroundProcessId -le 0) {
        Clear-PendingFocusRestore
        return
    }

    if (-not ($TargetProcessIds -contains $foregroundProcessId)) {
        Clear-PendingFocusRestore
        return
    }

    $foregroundWindow = $null
    foreach ($window in $TargetWindows) {
        if ((Get-AutomationElementWindowHandle -Element $window) -eq $ForegroundHandle) {
            $foregroundWindow = $window
            break
        }
    }

    if ($null -eq $foregroundWindow) {
        Clear-PendingFocusRestore
        return
    }

    $popup = Find-MatchingPopupInWindow -Window $foregroundWindow
    if ($null -eq $popup) {
        # If Antigravity reached the foreground without the exact Retry popup already present,
        # assume the user intentionally focused it and do not restore an older external window later.
        Clear-PendingFocusRestore
        return
    }

    $externalHandle = $script:LastExternalForegroundWindow
    if ($externalHandle -eq [IntPtr]::Zero) {
        Clear-PendingFocusRestore
        return
    }

    if (-not [AGAutoRetry.NativeMethods]::IsWindow($externalHandle)) {
        Clear-PendingFocusRestore
        return
    }

    $externalProcessId = Get-WindowProcessId -Handle $externalHandle
    if ($null -eq $externalProcessId -or $externalProcessId -le 0) {
        Clear-PendingFocusRestore
        return
    }

    if (($externalProcessId -eq $foregroundProcessId) -or ($externalProcessId -eq $PID)) {
        Clear-PendingFocusRestore
        return
    }

    $script:PendingFocusRestoreWindow = $externalHandle
    $script:PendingFocusRestoreProcessId = $externalProcessId
    $script:PendingFocusRestoreWindowTitle = $script:LastExternalForegroundWindowTitle
}

function Restore-PendingFocusWindow {
    param([int]$TargetProcessId)

    if (-not [bool]$script:Config.RestorePreviousFocusAfterRetry) {
        return $false
    }

    $handle = $script:PendingFocusRestoreWindow
    $savedProcessId = $script:PendingFocusRestoreProcessId
    $windowTitle = $script:PendingFocusRestoreWindowTitle
    Clear-PendingFocusRestore

    if ($handle -eq [IntPtr]::Zero) {
        return $false
    }

    if (-not [AGAutoRetry.NativeMethods]::IsWindow($handle)) {
        Write-Log -Level 'WARN' -Message ('Retry clicked, but the saved foreground window is no longer valid. windowHandle={0}' -f (Format-WindowHandle -Handle $handle))
        return $false
    }

    if ($null -eq $savedProcessId -or $savedProcessId -le 0) {
        $savedProcessId = Get-WindowProcessId -Handle $handle
    }

    if ($null -eq $savedProcessId -or $savedProcessId -le 0) {
        Write-Log -Level 'WARN' -Message ('Retry clicked, but the saved foreground window no longer has a resolvable process. windowHandle={0}' -f (Format-WindowHandle -Handle $handle))
        return $false
    }

    if (($savedProcessId -eq $TargetProcessId) -or ($savedProcessId -eq $PID)) {
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($windowTitle)) {
        $windowTitle = Get-WindowTitleFromHandle -Handle $handle
    }

    $delayMs = [int]$script:Config.FocusRestoreDelayMilliseconds
    if ($delayMs -gt 0) {
        Start-Sleep -Milliseconds $delayMs
    }

    $windowIsMinimized = [AGAutoRetry.NativeMethods]::IsIconic($handle)
    $windowIsMaximized = [AGAutoRetry.NativeMethods]::IsZoomed($handle)

    if ($windowIsMinimized) {
        # Only restore when the saved window is actually minimized.
        [AGAutoRetry.NativeMethods]::ShowWindowAsync($handle, 9) | Out-Null
    }
    elseif ($windowIsMaximized) {
        # Preserve a maximized window instead of restoring it to normal size.
        [AGAutoRetry.NativeMethods]::ShowWindowAsync($handle, 3) | Out-Null
    }

    [void][AGAutoRetry.NativeMethods]::SetForegroundWindow($handle)

    $foregroundAfter = [AGAutoRetry.NativeMethods]::GetForegroundWindow()
    if ($foregroundAfter -ne $handle) {
        try {
            $element = [System.Windows.Automation.AutomationElement]::FromHandle($handle)
            if ($null -ne $element) {
                $element.SetFocus()
            }
        }
        catch {
        }
    }
    if ($foregroundAfter -ne $handle) {
        try {
            $shell = New-Object -ComObject WScript.Shell
            $activated = $shell.AppActivate($savedProcessId)
            if ((-not $activated) -and (-not [string]::IsNullOrWhiteSpace($windowTitle))) {
                $activated = $shell.AppActivate($windowTitle)
            }
        }
        catch {
        }
    }

    $foregroundAfter = [AGAutoRetry.NativeMethods]::GetForegroundWindow()
    if ($foregroundAfter -eq $handle) {
        Write-Log -Message ('Focus restored after Retry. pid={0}; windowHandle={1}; window="{2}"' -f $savedProcessId, (Format-WindowHandle -Handle $handle), $windowTitle)
        return $true
    }

    Write-Log -Level 'WARN' -Message ('Retry clicked, but focus restore did not succeed. pid={0}; windowHandle={1}; window="{2}"' -f $savedProcessId, (Format-WindowHandle -Handle $handle), $windowTitle)
    return $false
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
$script:LastExternalForegroundWindow = [IntPtr]::Zero
$script:LastExternalForegroundProcessId = $null
$script:LastExternalForegroundWindowTitle = ''
$script:PendingFocusRestoreWindow = [IntPtr]::Zero
$script:PendingFocusRestoreProcessId = $null
$script:PendingFocusRestoreWindowTitle = ''
$script:LastForegroundWindow = [IntPtr]::Zero

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
            if ($foregroundHandle -ne $script:LastForegroundWindow) {
                Update-PendingFocusRestoreCandidate -TargetWindows $windows -ForegroundHandle $foregroundHandle -TargetProcessIds $excludedProcessIds
                $script:LastForegroundWindow = $foregroundHandle
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
                $invoked = Invoke-Retry -RetryButton $popup.RetryButton
                if (-not $invoked) {
                    Write-Log -Message ('Retry button detected but still disabled. pid={0}; process={1}; window="{2}"' -f $processId, $processName, $windowName)
                    continue
                }

                $script:RetryCount++
                Write-Log -Message ('Retry clicked. pid={0}; process={1}; window="{2}"; retryCount={3}' -f $processId, $processName, $windowName, $script:RetryCount)
                [void](Restore-PendingFocusWindow -TargetProcessId $processId)

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

        Start-Sleep -Milliseconds ([int]$script:Config.PollIntervalMilliseconds)
    }
}
catch {
    Write-Log -Level 'ERROR' -Message ('Fatal watcher error: {0}' -f $_.Exception.Message)
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
    }
}
