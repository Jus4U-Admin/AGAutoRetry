[CmdletBinding()]
param(
    [string]$ResultPath,
    [int]$TimeoutSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

if ([string]::IsNullOrWhiteSpace($ResultPath)) {
    $ResultPath = Join-Path $script:ScriptRoot 'test-harness-result.json'
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Write-Result {
    param(
        [bool]$RetryClicked,
        [string]$Reason
    )

    $payload = [ordered]@{
        retryClicked = $RetryClicked
        reason       = $Reason
        timestamp    = (Get-Date).ToString('o')
        resultPath   = $ResultPath
    }

    $payload | ConvertTo-Json | Set-Content -LiteralPath $ResultPath -Encoding UTF8
}

if (Test-Path -LiteralPath $ResultPath) {
    Remove-Item -LiteralPath $ResultPath -Force
}

$script:ResultWritten = $false
$script:RetryClicked = $false
$script:RetryReady = $false

$form = New-Object System.Windows.Forms.Form
$form.Text = 'AG Auto Retry Harness'
$form.Width = 540
$form.Height = 190
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.TopMost = $false

$label = New-Object System.Windows.Forms.Label
$label.Text = 'Agent terminated due to error'
$label.AutoSize = $true
$label.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Regular)
$label.Location = New-Object System.Drawing.Point(20, 20)
$form.Controls.Add($label)

$dismissButton = New-Object System.Windows.Forms.Button
$dismissButton.Text = 'Dismiss'
$dismissButton.Width = 110
$dismissButton.Height = 34
$dismissButton.Location = New-Object System.Drawing.Point(20, 90)
$dismissButton.Add_Click({
    if (-not $script:ResultWritten) {
        $script:ResultWritten = $true
        Write-Result -RetryClicked:$false -Reason 'dismiss_clicked'
    }
    $form.Close()
})
$form.Controls.Add($dismissButton)

$copyButton = New-Object System.Windows.Forms.Button
$copyButton.Text = 'Copy debug info'
$copyButton.Width = 140
$copyButton.Height = 34
$copyButton.Location = New-Object System.Drawing.Point(150, 90)
$copyButton.Add_Click({
})
$form.Controls.Add($copyButton)

$retryButton = New-Object System.Windows.Forms.Button
$retryButton.Text = 'Retry'
$retryButton.Width = 110
$retryButton.Height = 34
$retryButton.Location = New-Object System.Drawing.Point(310, 90)
$retryButton.Enabled = $false
$retryButton.Add_Click({
    if (-not $script:RetryReady) {
        return
    }

    $script:RetryClicked = $true
    if (-not $script:ResultWritten) {
        $script:ResultWritten = $true
        Write-Result -RetryClicked:$true -Reason 'retry_clicked'
    }
    $form.Close()
})
$form.Controls.Add($retryButton)

$armTimer = New-Object System.Windows.Forms.Timer
$armTimer.Interval = 2000
$armTimer.Add_Tick({
    $armTimer.Stop()
    $script:RetryReady = $true
    $retryButton.Enabled = $true
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = [Math]::Max(5000, $TimeoutSeconds * 1000)
$timer.Add_Tick({
    $timer.Stop()
    if (-not $script:ResultWritten) {
        $script:ResultWritten = $true
        Write-Result -RetryClicked:$false -Reason 'timeout'
    }
    $form.Close()
})

$form.Add_Shown({
    $copyButton.Focus() | Out-Null
    $armTimer.Start()
    $timer.Start()
})

$form.Add_FormClosed({
    if (-not $script:ResultWritten) {
        $script:ResultWritten = $true
        Write-Result -RetryClicked:$script:RetryClicked -Reason 'closed'
    }
})

[System.Windows.Forms.Application]::Run($form)
