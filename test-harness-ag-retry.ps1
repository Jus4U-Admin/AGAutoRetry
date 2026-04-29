[CmdletBinding()]
param(
    [string]$ResultPath,
    [int]$TimeoutSeconds = 30,
    [ValidateSet('Retry', 'KeepWaiting')]
    [string]$Scenario = 'Retry'
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
        [bool]$ActionClicked,
        [string]$Reason
    )

    $actionName = if ($Scenario -eq 'KeepWaiting') { 'Keep Waiting' } else { 'Retry' }
    $payload = [ordered]@{
        scenario           = $Scenario
        actionName         = $actionName
        actionClicked      = $ActionClicked
        retryClicked       = ($Scenario -eq 'Retry' -and $ActionClicked)
        keepWaitingClicked = ($Scenario -eq 'KeepWaiting' -and $ActionClicked)
        reason             = $Reason
        timestamp          = (Get-Date).ToString('o')
        resultPath         = $ResultPath
    }

    $payload | ConvertTo-Json | Set-Content -LiteralPath $ResultPath -Encoding UTF8
}

if (Test-Path -LiteralPath $ResultPath) {
    Remove-Item -LiteralPath $ResultPath -Force
}

$script:ResultWritten = $false
$script:RetryClicked = $false
$script:RetryReady = $false
$script:KeepWaitingClicked = $false

$form = New-Object System.Windows.Forms.Form
$form.Text = 'AG Auto Retry Harness'
$form.Width = if ($Scenario -eq 'KeepWaiting') { 560 } else { 540 }
$form.Height = if ($Scenario -eq 'KeepWaiting') { 220 } else { 190 }
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.TopMost = $false

$label = New-Object System.Windows.Forms.Label
$label.Text = if ($Scenario -eq 'KeepWaiting') { 'The window is not responding' } else { 'Agent terminated due to error' }
$label.AutoSize = $true
$label.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Regular)
$label.Location = New-Object System.Drawing.Point(20, 20)
$form.Controls.Add($label)

$firstPassiveButton = $null
$actionButton = $null

if ($Scenario -eq 'KeepWaiting') {
    $secondaryLabel = New-Object System.Windows.Forms.Label
    $secondaryLabel.Text = 'You can reopen or close the window or keep waiting.'
    $secondaryLabel.AutoSize = $true
    $secondaryLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
    $secondaryLabel.Location = New-Object System.Drawing.Point(20, 55)
    $form.Controls.Add($secondaryLabel)

    $checkbox = New-Object System.Windows.Forms.CheckBox
    $checkbox.Text = "Don't restore editors"
    $checkbox.AutoSize = $true
    $checkbox.Location = New-Object System.Drawing.Point(20, 128)
    $form.Controls.Add($checkbox)

    $reopenButton = New-Object System.Windows.Forms.Button
    $reopenButton.Text = 'Reopen'
    $reopenButton.Width = 110
    $reopenButton.Height = 34
    $reopenButton.Location = New-Object System.Drawing.Point(185, 120)
    $reopenButton.Add_Click({
        if (-not $script:ResultWritten) {
            $script:ResultWritten = $true
            Write-Result -ActionClicked:$false -Reason 'reopen_clicked'
        }
        $form.Close()
    })
    $form.Controls.Add($reopenButton)

    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Text = 'Close'
    $closeButton.Width = 110
    $closeButton.Height = 34
    $closeButton.Location = New-Object System.Drawing.Point(305, 120)
    $closeButton.Add_Click({
        if (-not $script:ResultWritten) {
            $script:ResultWritten = $true
            Write-Result -ActionClicked:$false -Reason 'close_clicked'
        }
        $form.Close()
    })
    $form.Controls.Add($closeButton)

    $keepWaitingButton = New-Object System.Windows.Forms.Button
    $keepWaitingButton.Text = 'Keep Waiting'
    $keepWaitingButton.Width = 120
    $keepWaitingButton.Height = 34
    $keepWaitingButton.Location = New-Object System.Drawing.Point(425, 120)
    $keepWaitingButton.Enabled = $false
    $keepWaitingButton.Add_Click({
        if (-not $script:RetryReady) {
            return
        }

        $script:KeepWaitingClicked = $true
        if (-not $script:ResultWritten) {
            $script:ResultWritten = $true
            Write-Result -ActionClicked:$true -Reason 'keep_waiting_clicked'
        }
        $form.Close()
    })
    $form.Controls.Add($keepWaitingButton)

    $firstPassiveButton = $closeButton
    $actionButton = $keepWaitingButton
}
else {
    $dismissButton = New-Object System.Windows.Forms.Button
    $dismissButton.Text = 'Dismiss'
    $dismissButton.Width = 110
    $dismissButton.Height = 34
    $dismissButton.Location = New-Object System.Drawing.Point(20, 90)
    $dismissButton.Add_Click({
        if (-not $script:ResultWritten) {
            $script:ResultWritten = $true
            Write-Result -ActionClicked:$false -Reason 'dismiss_clicked'
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
            Write-Result -ActionClicked:$true -Reason 'retry_clicked'
        }
        $form.Close()
    })
    $form.Controls.Add($retryButton)

    $firstPassiveButton = $copyButton
    $actionButton = $retryButton
}

$armTimer = New-Object System.Windows.Forms.Timer
$armTimer.Interval = 2000
$armTimer.Add_Tick({
    $armTimer.Stop()
    $script:RetryReady = $true
    $actionButton.Enabled = $true
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = [Math]::Max(5000, $TimeoutSeconds * 1000)
$timer.Add_Tick({
    $timer.Stop()
    if (-not $script:ResultWritten) {
        $script:ResultWritten = $true
        Write-Result -ActionClicked:$false -Reason 'timeout'
    }
    $form.Close()
})

$form.Add_Shown({
    $firstPassiveButton.Focus() | Out-Null
    $armTimer.Start()
    $timer.Start()
})

$form.Add_FormClosed({
    if (-not $script:ResultWritten) {
        $script:ResultWritten = $true
        Write-Result -ActionClicked:($script:RetryClicked -or $script:KeepWaitingClicked) -Reason 'closed'
    }
})

[System.Windows.Forms.Application]::Run($form)
