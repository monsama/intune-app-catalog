<#
.SYNOPSIS
    GUI test: a Winget ID typed after the deploy tabs were built still
    fills in the install command, uninstall command and detection script.

.DESCRIPTION
    "Add app..." opens the editor with an empty Winget field and builds
    the deploy tabs immediately - so those tabs are built for an app with
    no Winget ID, which means no generated install command, no uninstall
    command and no detection script. The ID is typed afterwards. Without
    something telling the deploy side that it changed, Package and
    detection stays blank forever, with nothing on it that would ever
    fill it in.

    DeployDefaultsHarness.ps1 builds that exact situation in the
    PowerShell under test and reports what the fields held before and
    after. It also checks the opposite mistake: a command typed by hand
    must survive every later change of the Winget ID.

    Offline: no path here reaches Graph.

    Needs an interactive Windows desktop session - a window opens briefly
    while it runs.

.PARAMETER AppHost
    Which PowerShell(s) to run the app under. Default: both.

.PARAMETER ShotDir
    Accepted so this test can be launched exactly like the others (CI
    passes -ShotDir to every GUI test), but unused: every assertion here
    is a value read out of a field, not anything a screenshot would show.

.EXAMPLE
    pwsh -NoProfile -File code/tests/gui/DeployDefaults.GuiTests.ps1
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
    Write-Host "`n=== Deploy defaults follow the Winget ID - running under $exe ===" -ForegroundColor Cyan
    $statusFile = Join-Path ([IO.Path]::GetTempPath()) ("intune-app-catalog-deploydefaults-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + ".txt")
    $p = Start-Process $exe -ArgumentList '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'DeployDefaultsHarness.ps1'), $repoRoot, $statusFile -PassThru
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
        if ($s['ran'] -ne 'true') { continue }

        Assert-True ($s['handlePresent'] -eq 'True') "the deploy view hands back a way to retarget its Winget ID" $all
        # The bug itself: built with no ID, so nothing was generated.
        Assert-True (([string]$s['beforeGenerated']) -eq '0') "an app with no Winget ID yet has no generated commands" $all
        Assert-True ([int]$s['afterGenerated'] -ge 2) "naming the Winget ID fills in the install and uninstall commands" $all
        Assert-True ([int]$s['afterNamingId'] -ge 3) "and the detection script names that Winget ID too" $all
        # ...without the opposite mistake.
        Assert-True ($s['typedSurvived'] -eq 'True') "a command typed by hand survives a later change of Winget ID" $all
        Assert-True ([int]$s['otherFieldsFollowed'] -ge 1) "while the fields nobody touched do follow it" $all

        # Through the real editor, the way "Search winget..." does it: by
        # assigning the field's text. No focus and no keystroke, so no
        # Leave - which is how the first version of this fix still left
        # Package and detection blank.
        Assert-True ($s['editorFound'] -eq 'true') "the editor opened for a new app" $all
        Assert-True ($s['editorControls'] -ne 'missing') "its Winget field and tabs are findable by name" $all
        Assert-True (([string]$s['editorAfterAssign']) -eq '0') "assigning the ID alone generates nothing yet" $all
        Assert-True ([int]$s['editorAfterTabSwitch'] -ge 2) "switching tabs fills in the commands for a picked Winget app" $all
        Assert-True ([int]$s['editorPackagePath'] -ge 1) "and points the package at the shared init.intunewin" $all
        # The Metadata tab's display name is built before "Add app..." has
        # a name to build it from, so it started blank and stayed blank.
        Assert-True ([int]$s['displayNameFollowed'] -ge 1) "the app's name fills the display name on the Metadata tab" $all
    }
    finally {
        if (-not $p.HasExited) { $p.Kill() }
        Remove-Item $statusFile -ErrorAction SilentlyContinue
    }
}

$script:currentHost = ''
exit (Write-TestReport)
