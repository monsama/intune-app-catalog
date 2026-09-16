<#
.SYNOPSIS
    Intune App Catalog & Deployment GUI - entry point.
.DESCRIPTION
    Loads every function this app defines (grouped by area under .\code\Private\,
    plus one file per dialog under .\code\Private\Dialogs\), then runs the actual
    GUI-building code in .\MainApp.ps1. See MainApp.ps1's own header comment
    for the full app description, and .\code\EmbeddedScripts\ for the embedded
    pipeline step scripts.

    All of .\code\Private\*.ps1 are dot-sourced BEFORE MainApp.ps1 runs, so every
    function exists before any of MainApp.ps1's top-level code (which
    actually builds and shows the window) can reach it - confirmed this is
    required, not just convention: PowerShell does NOT hoist function
    definitions the way some languages do; a function must already be
    defined by the time normal (non-deferred) code reaches a call to it.
    Order among the files below doesn't matter, since none of them call
    each other at their OWN definition time - only from inside a function
    body, which isn't executed until something later calls it.

    Each file is checked with Test-Path before being dot-sourced. This
    matters because dot-sourcing a path that doesn't exist ". <missing path>"
    does NOT stop the script - PowerShell treats the missing path as an
    unrecognized command name, writes a non-terminating error, and keeps
    going. Left unchecked, a single missing/incompletely-extracted file
    here would silently skip that file's functions and only surface much
    later as a confusing "CommandNotFoundException" from whatever dialog
    happens to call one of them.
#>

$Script:RequiredPrivateFiles = @(
    "code\Private\Catalog\CatalogIO.ps1"
    "code\Private\Catalog\CatalogLogic.ps1"
    "code\Private\Dialogs\Show-AddFavoriteGroupToAppsDialog.ps1"
    "code\Private\Dialogs\Show-AppEditor.ps1"
    "code\Private\Dialogs\Show-AppIdMatchDialog.ps1"
    "code\Private\Dialogs\Show-AppRegistrationGuideDialog.ps1"
    "code\Private\Dialogs\Show-BatchAssignDialog.ps1"
    "code\Private\Dialogs\Show-BatchDeployDialog.ps1"
    "code\Private\Dialogs\Show-BatchEditMetadataDialog.ps1"
    "code\Private\Dialogs\Show-BulkDeleteFromIntuneDialog.ps1"
    "code\Private\Dialogs\Show-CertificatePickerDialog.ps1"
    "code\Private\Dialogs\Show-CertificateSetupDialog.ps1"
    "code\Private\Dialogs\Show-CreateInIntuneDialog.ps1"
    "code\Private\Dialogs\Show-DefaultAppSettingsDialog.ps1"
    "code\Private\Dialogs\Show-DeleteAppDialog.ps1"
    "code\Private\Dialogs\Show-DeleteLocalCertificateDialog.ps1"
    "code\Private\Dialogs\Show-DependencyOverviewDialog.ps1"
    "code\Private\Dialogs\Show-DiagnosticsDialog.ps1"
    "code\Private\Dialogs\Show-EntraMemberPicker.ps1"
    "code\Private\Dialogs\Show-FavoriteGroupsManager.ps1"
    "code\Private\Dialogs\Show-GettingStartedGuideDialog.ps1"
    "code\Private\Dialogs\Show-GroupDriftCheckDialog.ps1"
    "code\Private\Dialogs\Show-GroupManagerDialog.ps1"
    "code\Private\Dialogs\Show-GroupOnlyPicker.ps1"
    "code\Private\Dialogs\Show-IntuneAuditDialog.ps1"
    "code\Private\Dialogs\Show-IntuneOnlyAppsDialog.ps1"
    "code\Private\Dialogs\Show-MetadataDriftDialog.ps1"
    "code\Private\Dialogs\Show-PackagingProgressDialog.ps1"
    "code\Private\Dialogs\Show-RemoveGroupFromAppsDialog.ps1"
    "code\Private\Dialogs\Show-SetDefaultsConfirmDialog.ps1"
    "code\Private\Dialogs\Show-SyncMetadataDialog.ps1"
    "code\Private\Dialogs\Show-TargetedAssignDialog.ps1"
    "code\Private\Dialogs\Show-WingetSearchDialog.ps1"
    "code\Private\Graph\GraphFetch.ps1"
    "code\Private\GuiHelpers.ps1"
    "code\Private\Pipeline.ps1"
    "code\Private\QuickActions.ps1"
    "code\Private\Settings.ps1"
)

$Script:MissingPrivateFiles = @()
$Script:FailedPrivateFiles = @()
foreach ($relativePath in $Script:RequiredPrivateFiles) {
    $fullPath = Join-Path $PSScriptRoot $relativePath
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        $Script:MissingPrivateFiles += $relativePath
        continue
    }
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        # Force any error inside the dot-sourced file (including a normally
        # non-terminating one, e.g. a bad property access) to be terminating
        # for the duration of this one dot-source, so it lands in this catch
        # instead of silently being written to the error stream and skipped
        # past - which is exactly what made earlier load failures invisible.
        $ErrorActionPreference = 'Stop'
        . $fullPath
    }
    catch {
        $Script:FailedPrivateFiles += [PSCustomObject]@{
            Path  = $relativePath
            Error = $_.Exception.Message
        }
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

if ($Script:MissingPrivateFiles.Count -gt 0) {
    Write-Host ""
    Write-Host "=================================================================" -ForegroundColor Red
    Write-Host " Cannot start: required file(s) are missing from this folder." -ForegroundColor Red
    Write-Host "=================================================================" -ForegroundColor Red
    Write-Host ""
    Write-Host " Expected next to IntuneDeployment.ps1 (in `$PSScriptRoot = $PSScriptRoot):" -ForegroundColor Yellow
    foreach ($missing in $Script:MissingPrivateFiles) {
        Write-Host "   - $missing" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host " This usually means the download/extraction of this folder was" -ForegroundColor Yellow
    Write-Host " incomplete (a zip extracted without its subfolders, files not" -ForegroundColor Yellow
    Write-Host " copied recursively, etc). Re-download or re-copy the full folder" -ForegroundColor Yellow
    Write-Host " (including the code\Private\ subfolder and all its subfolders), then" -ForegroundColor Yellow
    Write-Host " run this script again." -ForegroundColor Yellow
    Write-Host ""
    throw "Startup aborted: $($Script:MissingPrivateFiles.Count) required file(s) under code\Private\ were not found. See list above."
}

if ($Script:FailedPrivateFiles.Count -gt 0) {
    Write-Host ""
    Write-Host "=================================================================" -ForegroundColor Red
    Write-Host " Cannot start: required file(s) failed to load." -ForegroundColor Red
    Write-Host "=================================================================" -ForegroundColor Red
    Write-Host ""
    foreach ($failed in $Script:FailedPrivateFiles) {
        Write-Host " - $($failed.Path)" -ForegroundColor Yellow
        Write-Host "     $($failed.Error)" -ForegroundColor Yellow
        Write-Host ""
    }
    throw "Startup aborted: $($Script:FailedPrivateFiles.Count) required file(s) under code\Private\ failed to load. See error(s) above."
}

$Script:MainAppPath = Join-Path $PSScriptRoot "MainApp.ps1"
if (-not (Test-Path -LiteralPath $Script:MainAppPath -PathType Leaf)) {
    throw "Startup aborted: MainApp.ps1 was not found next to IntuneDeployment.ps1 (expected at: $Script:MainAppPath)."
}

. $Script:MainAppPath
