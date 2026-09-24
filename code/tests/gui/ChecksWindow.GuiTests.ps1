<#
.SYNOPSIS
    GUI test: the Checks window's one list, and the fixes it offers.

.DESCRIPTION
    Checks used to be eight tabs; it is one run and one list now, with the
    fixes for whatever is selected under it. ChecksWindowHarness.ps1 opens
    the real window over a fixture catalog - with Intune's app list and
    the last audit already in hand, so there are rows without reading
    anything - and reports what the list shows and which fix buttons each
    kind of selection brings up.

    Offline: Run is never pressed, so nothing reaches Graph, Entra ID or
    winget.

    Needs an interactive Windows desktop session - a window opens briefly
    while it runs.

.PARAMETER AppHost
    Which PowerShell(s) to run the app under. Default: both.

.PARAMETER ShotDir
    Accepted so this test can be launched like the others (CI passes it to
    every GUI test), but unused: every assertion is a value read out of
    the window.

.EXAMPLE
    pwsh -NoProfile -File code/tests/gui/ChecksWindow.GuiTests.ps1
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
    Write-Host "`n=== Checks window - running under $exe ===" -ForegroundColor Cyan
    $statusFile = Join-Path ([IO.Path]::GetTempPath()) ("intune-app-catalog-checks-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + ".txt")
    $p = Start-Process $exe -ArgumentList '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'ChecksWindowHarness.ps1'), $repoRoot, $statusFile -PassThru
    try {
        $exited = $p.WaitForExit(120000)
        Assert-True $exited "the harness finished within 2 minutes"
        if (-not $exited) { $p.Kill(); continue }

        $s = @{}
        if (Test-Path $statusFile) {
            foreach ($line in [IO.File]::ReadAllLines($statusFile)) { $k, $v = $line -split '=', 2; $s[$k] = $v }
        }
        $all = (@($s.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')
        Assert-True ($s['ran'] -eq 'true') "the harness ran every step" $all
        Assert-True (-not $s.ContainsKey('error') -and -not $s.ContainsKey('inspectError')) "nothing threw" $all
        Assert-True ($s['windowFound'] -eq 'True') "the Checks window opened" $all
        if ($s['windowFound'] -ne 'True') { continue }

        # What is already known shows at once - no run needed.
        Assert-True ($s['rows'] -eq '5') "it opens on what is already known: four Intune link rows and the last audit's one" $all
        foreach ($expected in @('Intune link:Intune Only App', 'Intune link:Old Name', 'Intune link:Gone App', 'Intune link:Firefox', 'Metadata:7-Zip')) {
            Assert-True ($s['apps'] -like "*$expected*") "the list has $expected" $all
        }
        Assert-True ($s['showItems'] -like '*All areas (5)*' -and $s['showItems'] -like '*Intune link (4)*' -and $s['showItems'] -like '*Metadata (1)*') "Show offers each area with its count" $all
        Assert-True ($s['cachedChecked'] -like '*ago*') "a row from the last audit says how old it is" $all
        Assert-True ($s['runEnabled'] -eq 'True' -and $s['stopEnabled'] -eq 'False') "Run is ready and Stop isn't, before anything runs" $all

        # The fixes follow the selection.
        Assert-True ($s['fixesNothingSelected'] -eq 'Select all') "with nothing selected, no fix is offered" $all
        Assert-True ($s['fixesRenamed'] -like "*Use Intune's name*" -and $s['fixesRenamed'] -notlike '*Add to catalog*') "a rename in Intune offers Use Intune's name" $all
        Assert-True ($s['fixesNotInCatalog'] -like '*Add to catalog*') "an Intune-only app offers Add to catalog" $all
        Assert-True ($s['fixesStaleId'] -like '*Clear App ID*') "a stale App ID offers Clear App ID" $all
        Assert-True ($s['fixesNoAppId'] -like '*Set App ID*' -and $s['fixesNoAppId'] -like '*Choose App ID*') "a name match without App ID offers Set and Choose App ID" $all
        Assert-True ($s['fixesMetadata'] -like '*Pull from Intune*' -and $s['fixesMetadata'] -like '*Push metadata*') "a metadata difference offers Pull and Push metadata" $all
        Assert-True ($s['fixesTwoKinds'] -like "*Use Intune's name*" -and $s['fixesTwoKinds'] -like '*Clear App ID*') "two kinds of row selected offer both their fixes" $all

        # Show narrows the list.
        Assert-True ($s['rowsLinkOnly'] -eq '4' -and $s['linkOnlyAreas'] -eq 'Intune link') "Show: Intune link shows only those rows" $all
        Assert-True ($s['returnedChanged'] -eq 'False') "just looking changes nothing" $all
    }
    finally {
        if (-not $p.HasExited) { $p.Kill() }
        Remove-Item $statusFile -ErrorAction SilentlyContinue
    }
}

$script:currentHost = ''
exit (Write-TestReport)
