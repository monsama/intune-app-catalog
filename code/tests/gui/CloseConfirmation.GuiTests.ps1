<#
.SYNOPSIS
    GUI test: "Stop and close?" for dialogs that run a step in a child
    process (Deploy, Batch deploy/assign/edit, Bulk delete, Sync, Assign,
    Delete app, Group Manager).

.DESCRIPTION
    Those dialogs need a Graph connection before they start anything, so
    this drives a stand-in (CloseConfirmationHarness.ps1) wired the same
    way, with the real Register-CloseConfirmation and a real sleeping child
    process. Checks that:
      - the Close button (the dialog's CancelButton) asks, No is the
        default, and No keeps both the dialog and the step running
      - the window's X asks the same question, and Yes stops the step and
        closes the dialog
      - once nothing runs, closing doesn't ask

    Needs an interactive Windows desktop session.

.PARAMETER AppHost
    Which PowerShell(s) to run the stand-in under. Default: both.

.EXAMPLE
    pwsh -NoProfile -File code/tests/gui/CloseConfirmation.GuiTests.ps1
#>
param(
    [string[]]$AppHost = @('pwsh', 'powershell')
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'GuiTestDriver.ps1')
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$question = 'Stop and close?'

foreach ($exe in Resolve-AppHosts $AppHost) {
    $script:currentHost = [IO.Path]::GetFileNameWithoutExtension($exe)
    Write-Host "`n=== Stop and close? - running under $exe ===" -ForegroundColor Cyan
    $statusFile = Join-Path ([IO.Path]::GetTempPath()) ("intune-app-catalog-closetest-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + ".txt")
    $p = Start-Process $exe -ArgumentList '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'CloseConfirmationHarness.ps1'), $repoRoot, $statusFile -PassThru
    $ctx = [pscustomobject]@{ Process = $p; Pid = [uint32]$p.Id; Main = [IntPtr]::Zero }
    $childPid = $null
    try {
        $dlg = Wait-AppDialog $ctx 'Close confirmation test - running' 60
        Assert-True ([bool]$dlg) "the stand-in dialog opens"
        if (-not $dlg) { continue }

        # Close button -> question, No is the default, No keeps it open
        $W32::Click((Get-ChildWindow $dlg 'Close'))
        $q = Wait-AppDialog $ctx $question 5
        Assert-True ([bool]$q) "Close asks while the step runs"
        if ($q) {
            $no = Get-ChildWindow $q 'No'
            $defId = $W32::DefaultButtonId($q)
            Assert-True ($defId -eq 7) "No is the default button, so Enter doesn't stop the step" "default button id $defId (7 = No)"
            $W32::Click($no)
            Start-Sleep -Seconds 1
            Assert-True ($W32::IsWindow($dlg) -and $W32::IsWindowVisible($dlg)) "answering No keeps the dialog open"
            $step = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $($p.Id)" | Where-Object { $_.CommandLine -like '*Start-Sleep*' })
            Assert-True ($step.Count -eq 1) "answering No keeps the step running" "child processes found: $($step.Count)"
        }

        # X -> same question, Yes stops the step and closes
        $W32::Close($dlg)
        $q = Wait-AppDialog $ctx $question 5
        Assert-True ([bool]$q) "the window's X asks the same question"
        if ($q) { $W32::Click((Get-ChildWindow $q 'Yes')) }

        # second round: nothing runs any more, closing must not ask
        $dlg2 = Wait-AppDialog $ctx 'Close confirmation test - stopped' 15
        Assert-True ([bool]$dlg2) "answering Yes closes the dialog"
        if ($dlg2) {
            $W32::Close($dlg2)
            Start-Sleep -Seconds 1
            Assert-True (-not (Get-AppDialogs $ctx | Where-Object { $W32::Text($_) -eq $question })) "closing doesn't ask once nothing runs"
        }

        Assert-True ($p.WaitForExit(20000)) "the stand-in exits"
        $status = @{}
        if (Test-Path $statusFile) {
            foreach ($line in [IO.File]::ReadAllLines($statusFile)) { $k, $v = $line -split '=', 2; $status[$k] = $v }
        }
        $childPid = $status['childPid']
        Assert-True ($status['runningChildExited'] -eq 'True') "Yes stopped the running step" "status: $(@($status.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')"
    }
    catch {
        Assert-True $false "test run completed" "$($_.Exception.Message) @ line $($_.InvocationInfo.ScriptLineNumber)"
    }
    finally {
        foreach ($d in Get-AppDialogs $ctx) { [void](Close-AppDialog $d 5) }
        if (-not $p.HasExited) { $p.Kill() }
        if ($childPid) { Get-Process -Id $childPid -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
        Remove-Item $statusFile -ErrorAction SilentlyContinue
    }
}
$script:currentHost = ''
exit (Write-TestReport)
