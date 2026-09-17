<#
    Runs inside the PowerShell under test for CloseConfirmation.GuiTests.ps1:
    a stand-in for the dialogs that run a step in a child process, wired
    exactly like them - Close is the dialog's CancelButton, and
    Register-CloseConfirmation (GuiHelpers.ps1) guards closing. The step is
    a real child process that just sleeps.

    Shows the dialog twice: first while the step runs (the test answers the
    question), then again once it has been stopped (closing must not ask).
    Writes what happened to -StatusFile, one "key=value" per line.
#>
param([string]$RepoRoot, [string]$StatusFile)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$Global:App = @{}
. (Join-Path $RepoRoot 'code\Private\GuiHelpers.ps1')

$status = New-Object System.Collections.Generic.List[string]
$hostExe = (Get-Process -Id $PID).Path
$procBox = @{ Proc = (Start-Process $hostExe -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 300' -WindowStyle Hidden -PassThru) }
$status.Add("childPid=$($procBox.Proc.Id)")

foreach ($round in 'running', 'stopped') {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Close confirmation test - $round"
    $dlg.Size = New-Object System.Drawing.Size(360, 160)
    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"
    $btnClose.Location = New-Object System.Drawing.Point(130, 50)
    $dlg.Controls.Add($btnClose)
    $btnClose.Add_Click({ $dlg.Close() }.GetNewClosure())
    $dlg.CancelButton = $btnClose
    Register-CloseConfirmation -Dialog $dlg -GetQuestion {
        if ($procBox.Proc -and -not $procBox.Proc.HasExited) { "A test step is still running. Stop it and close?" }
    }.GetNewClosure() -OnConfirmed { $procBox.Proc.Kill() }.GetNewClosure()
    [void]$dlg.ShowDialog()
    $dlg.Dispose()
    [void]$procBox.Proc.WaitForExit(5000)
    $status.Add("${round}Closed=true")
    $status.Add("${round}ChildExited=$($procBox.Proc.HasExited)")
}
[IO.File]::WriteAllLines($StatusFile, $status)
