<#
.SYNOPSIS
    GUI test: "Install missing" in the Prerequisites dialog, end to end -
    download from the PowerShell Gallery, live log, status re-check, and the
    Graph actions working past the module check afterwards.

.DESCRIPTION
    Needs internet access (downloads Microsoft.Graph.Authentication, ~10-30 s).
    Nothing is installed into the user profile: the app runs from a sandbox
    (see GuiTestDriver.ps1) with INTUNEPACKAGER_TEST_MODULE_DIR set, which
    makes the installer Save-Module into a throwaway folder that's on the
    app's PSModulePath instead of running Install-Module.

    Skips a host where the module is already installed for real - the
    dialog then has nothing to install.

.PARAMETER AppHost
    Which PowerShell(s) to run the app under. Default: both.

.EXAMPLE
    pwsh -NoProfile -File code/tests/gui/Prerequisites.GuiTests.ps1
#>
param(
    [string[]]$AppHost = @('pwsh', 'powershell'),
    [string]$ShotDir
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'GuiTestDriver.ps1')

$moduleName = 'Microsoft.Graph.Authentication'
$docs = [Environment]::GetFolderPath('MyDocuments')
$profileDirs = @((Join-Path $docs "PowerShell\Modules\$moduleName"), (Join-Path $docs "WindowsPowerShell\Modules\$moduleName"))
$profileBefore = @($profileDirs | ForEach-Object { Test-Path $_ })
# Windows PowerShell's PackageManagement creates this (empty) under the REAL
# LOCALAPPDATA whenever Save-Module runs, whatever the environment says.
$packageMgmtDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'PackageManagement'
$packageMgmtExisted = Test-Path $packageMgmtDir

foreach ($exe in Resolve-AppHosts $AppHost) {
    $script:currentHost = [IO.Path]::GetFileNameWithoutExtension($exe)
    Write-Host "`n=== Prerequisites install - app running under $exe ===" -ForegroundColor Cyan
    $already = (& $exe -NoProfile -NonInteractive -Command "[bool](Get-Module -ListAvailable -Name $moduleName)" 2>$null | Select-Object -Last 1) -eq 'True'
    if ($already) {
        Write-Host "  skip - $moduleName is already installed for this PowerShell" -ForegroundColor DarkYellow
        continue
    }

    $root = New-AppSandbox
    $moduleDir = Join-Path $root 'testmodules'
    [void][IO.Directory]::CreateDirectory($moduleDir)
    $ctx = $null
    try {
        $ctx = Start-AppUnderTest -AppHost $exe -Root $root -Environment @{
            INTUNEPACKAGER_TEST_MODULE_DIR = $moduleDir
            PSModulePath                   = "$moduleDir;$env:PSModulePath"
        }
        if ($ShotDir) {
            $ctx.ShotDir = Join-Path $ShotDir $script:currentHost
            [void][IO.Directory]::CreateDirectory($ctx.ShotDir)
        }

        [void](Invoke-MoreActionsItem $ctx 'Verify' 'Prerequisites...')
        $dlg = Wait-AppDialog $ctx 'Prerequisites'
        Close-AppMenus $ctx
        Assert-True ([bool]$dlg) "Prerequisites opens"
        if (-not $dlg) { throw "no Prerequisites dialog" }
        $install = Get-ChildWindow $dlg 'Install missing'
        $recheck = Get-ChildWindow $dlg 'Check again'
        $close = Get-ChildWindow $dlg 'Close'
        $log = $W32::Children($dlg) | Where-Object { $W32::Cls($_) -match 'RichEdit' } | Select-Object -First 1

        $end = (Get-Date).AddSeconds(60)
        while ((Get-Date) -lt $end -and -not $W32::IsWindowEnabled($recheck)) { Start-Sleep -Milliseconds 300 }
        Assert-True ($W32::IsWindowEnabled($install)) "Install missing is offered while the module is missing"
        Assert-True ($W32::IsWindowEnabled($close)) "the dialog stays responsive (Close enabled) after the status check"

        $W32::Click($install)
        Start-Sleep -Seconds 2
        Assert-True (-not $W32::IsWindowEnabled($close)) "Close is disabled while installing"
        # install finished and the status re-checked: Check again comes back
        $end = (Get-Date).AddMinutes(5)
        while ((Get-Date) -lt $end -and -not ($W32::IsWindowEnabled($recheck) -and $W32::IsWindowEnabled($close))) { Start-Sleep -Milliseconds 500 }
        Start-Sleep -Milliseconds 800
        $text = $W32::ControlText($log)
        Save-AppShot $ctx $dlg 'Prerequisites_after_install'
        Write-Host ($text -split "`r?`n" | Where-Object { $_ } | ForEach-Object { "      | $_" } | Out-String) -ForegroundColor DarkGray
        Assert-True ($text -match "\[OK\] $([regex]::Escape($moduleName)) \S+ installed") "the installer's own output reaches the log"
        Assert-True ($text -match "\[OK\] Everything's installed") "after installing, the re-check finds the module everywhere it's needed" $text
        Assert-True (-not $W32::IsWindowEnabled($install)) "Install missing is no longer offered"
        Assert-True (@(Get-ChildItem $moduleDir -Recurse -Filter "$moduleName.psd1").Count -ge 1) "the module landed in the test folder"
        [void](Close-AppDialog $dlg)
        [void](Wait-NoAppDialogs $ctx 5)

        # Graph actions now get past the module check (no credentials -> "Not configured")
        [void](Invoke-MoreActionsItem $ctx 'Intune' 'Look up App IDs...')
        $seen = Watch-AppDialogs $ctx
        Close-AppMenus $ctx
        $titles = @($seen | ForEach-Object Title)
        Assert-True ($titles.Count -eq 1 -and $titles[0] -eq 'Not configured') "Look up App IDs now stops at 'Not configured', not at the module" "saw: $($titles -join ' -> ')"
    }
    catch {
        Assert-True $false "test run completed" "$($_.Exception.Message) @ line $($_.InvocationInfo.ScriptLineNumber)"
        if ($ctx) { foreach ($d in Get-AppDialogs $ctx) { [void](Close-AppDialog $d) } }
    }
    finally {
        if ($ctx) {
            Assert-True (Stop-AppUnderTest $ctx) "app closes cleanly"
            $err = Get-AppStdErr $ctx
            Assert-True ([string]::IsNullOrWhiteSpace($err)) "app wrote nothing to stderr" $err
        }
        Remove-AppSandbox $root
    }
}
$script:currentHost = ''
$profileAfter = @($profileDirs | ForEach-Object { Test-Path $_ })
if (-not $packageMgmtExisted -and (Test-Path $packageMgmtDir) -and -not (Get-ChildItem $packageMgmtDir -Recurse -Force -File)) {
    [IO.Directory]::Delete($packageMgmtDir, $true)   # left behind by this run, and empty
}
Assert-True (($profileBefore -join ',') -eq ($profileAfter -join ',')) "nothing was installed into the user profile"
exit (Write-TestReport)
