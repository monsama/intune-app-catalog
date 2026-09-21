<#
.SYNOPSIS
    GUI test: the catalog grid sorts by its column headers, and keeps your
    place when it is rebuilt.

.DESCRIPTION
    Update-Grid rebuilds the grid from scratch - it runs on every save,
    deploy, sync and on every keystroke in the search box - so anything
    the grid itself remembers (the sort order, which rows are selected,
    how far down you have scrolled) is lost unless it is put back.

    GridBehaviorHarness.ps1 builds the real grid, with the real
    Update-Grid and Sort-Grid, over a fixture catalog inside the
    PowerShell under test, and reports what survived. Offline: nothing
    here reads a catalog off disk, and no path reaches Graph.

    Needs an interactive Windows desktop session - a window opens briefly
    while it runs.

.PARAMETER AppHost
    Which PowerShell(s) to run the app under. Default: both.

.PARAMETER ShotDir
    Accepted so this test can be launched exactly like the others (CI
    passes -ShotDir to every GUI test), but unused: the only window here is
    a fixture grid, and every assertion is about values read out of it
    rather than anything you could see in a screenshot.

.EXAMPLE
    pwsh -NoProfile -File code/tests/gui/GridBehavior.GuiTests.ps1
#>
param(
    [string[]]$AppHost = @('pwsh', 'powershell'),
    [string]$ShotDir
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'GuiTestDriver.ps1')
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path

foreach ($exe in Resolve-AppHosts $AppHost) {
    $script:currentHost = [IO.Path]::GetFileNameWithoutExtension($exe)
    Write-Host "`n=== Catalog grid behaviour - running under $exe ===" -ForegroundColor Cyan
    $statusFile = Join-Path ([IO.Path]::GetTempPath()) ("intune-app-catalog-gridtest-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + ".txt")
    $p = Start-Process $exe -ArgumentList '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'GridBehaviorHarness.ps1'), $repoRoot, $statusFile -PassThru
    try {
        $exited = $p.WaitForExit(120000)
        Assert-True $exited "the grid harness finished within 2 minutes"
        if (-not $exited) { $p.Kill(); continue }

        $s = @{}
        if (Test-Path $statusFile) {
            foreach ($line in [IO.File]::ReadAllLines($statusFile)) { $k, $v = $line -split '=', 2; $s[$k] = $v }
        }
        $all = (@($s.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')
        Assert-True ($s['ran'] -eq 'true') "the harness ran every step" $all
        if ($s['ran'] -ne 'true') { continue }

        # Catalog order until a header is actually clicked.
        Assert-True ($s['unsortedFirst3'] -eq 'Zulu App|Mike App|Alpha App') "an unsorted grid is in catalog order" $all
        Assert-True ($s['glyphBeforeAnySort'] -eq 'None') "no column claims a sort before one is asked for" $all

        # One click sorts, a second click reverses, and only the sorted
        # column shows a glyph.
        Assert-True ($s['ascFirst'] -eq 'Alpha App') "clicking a header sorts by it, ascending" $all
        Assert-True ($s['ascLast'] -eq 'Zulu App') "ascending runs to the end of the alphabet" $all
        Assert-True ($s['glyphAsc'] -eq 'Ascending') "the sorted column shows the ascending glyph" $all
        Assert-True ($s['glyphOtherColumn'] -eq 'None') "no other column shows a glyph" $all
        Assert-True ($s['descFirst'] -eq 'Zulu App') "clicking the same header again reverses it" $all
        Assert-True ($s['glyphDesc'] -eq 'Descending') "the glyph flips with it" $all

        # The rebuild every action triggers must not undo any of it.
        Assert-True ($s['descFirstAfterRebuild'] -eq 'Zulu App') "the sort order survives a grid rebuild" $all
        Assert-True ($s['glyphAfterRebuild'] -eq 'Descending') "so does the glyph" $all

        Assert-True ($s['selectionBeforeRebuild'] -eq 'Mike App|Zulu App') "two rows can be selected at once" $all
        Assert-True ($s['selectionAfterRebuild'] -eq 'Mike App|Zulu App') "a multi-row selection survives a rebuild" $all
        Assert-True ($s['scrollBeforeRebuild'] -eq '10') "the fixture grid scrolls" $all
        Assert-True ($s['scrollAfterRebuild'] -eq '10') "the scroll position survives a rebuild" $all

        # Filtered out is the one case where the selection cannot come back.
        Assert-True ($s['rowsWhenFiltered'] -eq '1') "the search box filters the grid" $all
        Assert-True ($s['selectionWhenFilteredOut'] -eq '') "an app the filter hides leaves nothing selected in its place" $all
        Assert-True ($s['selectionWhenStillVisible'] -eq 'Mike App') "an app the filter keeps stays selected" $all

        # Which package an app installs from, as the column reports it.
        Assert-True ($s['uncommonCell_UncommonCaseWinget'] -eq '') "a Winget app with no package of its own is not flagged" $all
        Assert-True ($s['uncommonCell_UncommonCasePlain'] -eq 'Yes') "an app with no Winget ID is flagged uncommon" $all
        Assert-True ($s['uncommonCell_UncommonCaseCustom'] -eq 'Yes (custom package)') "a Winget app pointed at its own .intunewin is flagged too, and says why" $all
    }
    catch {
        Assert-True $false "test run completed" "$($_.Exception.Message) @ line $($_.InvocationInfo.ScriptLineNumber)"
    }
    finally {
        if (-not $p.HasExited) { $p.Kill() }
        Remove-Item $statusFile -ErrorAction SilentlyContinue
    }
}
$script:currentHost = ''
exit (Write-TestReport)
