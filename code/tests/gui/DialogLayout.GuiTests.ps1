<#
.SYNOPSIS
    GUI test: no cut-off, hidden or overlapping text in any dialog.

.DESCRIPTION
    Starts the app with DialogLayoutHarness.ps1, which opens every dialog
    with sample data (including long app and group names) from inside the
    app process, measures each visible control's text against the space it
    has, and closes it again. Each window it saw is one assertion here:
    labels/buttons/checkboxes whose text doesn't fit, list entries wider than
    a list without a scrollbar, grid headers too narrow, controls running
    past their container, overlapping sibling controls, and a window bigger
    than the (usable) screen all fail it.

    Offline, and as safe as the other GUI tests (throwaway sandbox, no Graph
    credentials; every Intune/Entra action stops at its own guard). Needs an
    interactive Windows desktop session; takes a few minutes per host.

.PARAMETER AppHost
    Which PowerShell(s) to run the app under. Default: both.

.PARAMETER ShotDir
    Optional folder for a screenshot of every window the harness opened.

.PARAMETER Screen
    Pretend the screen is this small (e.g. 1024x768), to check that every
    dialog still fits and stays usable on a small screen from a big monitor.
    Default: the real screen.

.EXAMPLE
    pwsh -NoProfile -File code/tests/gui/DialogLayout.GuiTests.ps1 -ShotDir .\layout-shots
.EXAMPLE
    pwsh -NoProfile -File code/tests/gui/DialogLayout.GuiTests.ps1 -Screen 1024x768
#>
param(
    [string[]]$AppHost = @('pwsh', 'powershell'),
    [string]$ShotDir,
    [ValidatePattern('^(\d+x\d+)?$')][string]$Screen = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'GuiTestDriver.ps1')

foreach ($exe in Resolve-AppHosts $AppHost) {
    $script:currentHost = [IO.Path]::GetFileNameWithoutExtension($exe)
    Write-Host "`n=== Dialog layout audit - app running under $exe ===" -ForegroundColor Cyan
    $root = New-AppSandbox
    Copy-Item (Join-Path $PSScriptRoot 'DialogLayoutHarness.ps1') (Join-Path $root 'DialogLayoutHarness.ps1')
    $outDir = Join-Path $root 'layout-audit'
    [void][IO.Directory]::CreateDirectory($outDir)
    $harnessArgs = @('-OutDir', "`"$outDir`"")
    if ($ShotDir) {
        $shots = Join-Path $ShotDir $script:currentHost
        [void][IO.Directory]::CreateDirectory($shots)
        $harnessArgs += @('-ShotDir', "`"$((Resolve-Path $shots).Path)`"")
    }
    $ctx = $null
    try {
        $envVars = @{}
        if ($Screen) { $envVars['INTUNEPACKAGER_TEST_SCREEN'] = $Screen }
        $ctx = Start-AppUnderTest -AppHost $exe -Root $root -Script 'DialogLayoutHarness.ps1' -ScriptArguments $harnessArgs -Environment $envVars
        # the harness closes the app itself once every dialog has been checked
        $finished = $ctx.Process.WaitForExit(20 * 60 * 1000)
        Assert-True $finished "the audit finished within 20 minutes$(if ($Screen) { " (screen: $Screen)" })"
        if (-not $finished) { [void](Stop-AppUnderTest $ctx) }

        $lines = @(Get-Content (Join-Path $outDir 'findings.txt') -ErrorAction SilentlyContinue)
        Assert-True ($lines -contains '== DONE') "the harness ran every step"
        $errors = @($lines | Where-Object { $_ -match '^\s+(step|closer) error:' })
        Assert-True ($errors.Count -eq 0) "no step failed to run" (($errors | ForEach-Object { $_.Trim() }) -join "`n    ")

        # one assertion per window, its issues as the failure detail
        $step = ''
        $window = $null
        $issues = New-Object System.Collections.Generic.List[string]
        $windows = 0
        $stepsWithoutWindow = New-Object System.Collections.Generic.List[string]
        $sawSomething = $true
        $flush = {
            if ($window) {
                Assert-True ($issues.Count -eq 0) "$window has no cut-off or overlapping controls" (($issues | ForEach-Object { $_.Trim() }) -join "`n    ")
            }
        }
        foreach ($line in $lines) {
            if ($line -match '^== (.+)$') {
                & $flush; $window = $null; $issues.Clear()
                if ($step -and -not $sawSomething) { $stepsWithoutWindow.Add($step) }
                $step = $Matches[1]; $sawSomething = $false
            }
            elseif ($line -match "^\s+window '(.*)' \((\d+x\d+)\):") {
                & $flush; $issues.Clear()
                $window = "'$($Matches[1])' ($step)"; $windows++; $sawSomething = $true
            }
            elseif ($line -match '^\s+msgbox:') { $sawSomething = $true }
            elseif ($line -match '^\s{6}\S' -and $window) { $issues.Add($line) }
        }
        & $flush
        Assert-True ($windows -ge 30) "the harness saw the app's dialogs" "only $windows window(s)"
        Assert-True ($stepsWithoutWindow.Count -eq 0) "every step opened a window or a message" ($stepsWithoutWindow -join ', ')
        Write-Host "  ($windows windows checked)" -ForegroundColor DarkGray
    }
    catch {
        Assert-True $false "test run completed" "$($_.Exception.Message) @ line $($_.InvocationInfo.ScriptLineNumber)"
        if ($ctx -and -not $ctx.Process.HasExited) { [void](Stop-AppUnderTest $ctx) }
    }
    finally {
        if ($ctx) {
            $err = Get-AppStdErr $ctx
            Assert-True ([string]::IsNullOrWhiteSpace($err)) "app wrote nothing to stderr" $err
        }
        Remove-AppSandbox $root
    }
}
$script:currentHost = ''
exit (Write-TestReport)
