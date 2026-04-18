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

function Hide-ConsoleWindow {
    try {
        if (-not ('AGAutoRetry.NativeMethods' -as [type])) {
            Add-Type -Namespace AGAutoRetry -Name NativeMethods -MemberDefinition @'
[DllImport("kernel32.dll")]
public static extern IntPtr GetConsoleWindow();

[DllImport("user32.dll")]
public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@ -UsingNamespace System, System.Runtime.InteropServices
        }

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

try {
    Hide-ConsoleWindow
    Initialize-Configuration
    Import-UiAutomationAssemblies

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
            }
            else {
                $windows = @(Get-TestHarnessWindows)
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
