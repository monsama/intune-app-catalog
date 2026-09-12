<#
.SYNOPSIS
    Intune App Catalog & Deployment GUI - entry point.
.DESCRIPTION
    Loads every function this app defines (grouped by area under .\Private\,
    plus one file per dialog under .\Private\Dialogs\), then runs the actual
    GUI-building code in .\MainApp.ps1. See MainApp.ps1's own header comment
    for the full app description, and .\EmbeddedScripts\ for the embedded
    pipeline step scripts.

    All of .\Private\*.ps1 are dot-sourced BEFORE MainApp.ps1 runs, so every
    function exists before any of MainApp.ps1's top-level code (which
    actually builds and shows the window) can reach it - confirmed this is
    required, not just convention: PowerShell does NOT hoist function
    definitions the way some languages do; a function must already be
    defined by the time normal (non-deferred) code reaches a call to it.
    Order among the files below doesn't matter, since none of them call
    each other at their OWN definition time - only from inside a function
    body, which isn't executed until something later calls it.
#>

. (Join-Path $PSScriptRoot "Private\Catalog\CatalogIO.ps1")
. (Join-Path $PSScriptRoot "Private\Catalog\CatalogLogic.ps1")
. (Join-Path $PSScriptRoot "Private\Dialogs\Show-AddFavoriteGroupToAppsDialog.ps1")
. (Join-Path $PSScriptRoot "Private\Dialogs\Show-AppEditor.ps1")
. (Join-Path $PSScriptRoot "Private\Dialogs\Show-AppIdMatchDialog.ps1")
. (Join-Path $PSScriptRoot "Private\Dialogs\Show-AppRegistrationGuideDialog.ps1")
. (Join-Path $PSScriptRoot "Private\Dialogs\Show-BatchAssignDialog.ps1")
. (Join-Path $PSScriptRoot "Private\Dialogs\Show-BatchDeployDialog.ps1")
. (Join-Path $PSScriptRoot "Private\Dialogs\Show-BatchEditMetadataDialog.ps1")
. (Join-Path $PSScriptRoot "Private\Dialogs\Show-BulkDeleteFromIntuneDialog.ps1")
. (Join-Path $PSScriptRoot "Private\Dialogs\Show-CertificatePickerDialog.ps1")
. (Join-Path $PSScriptRoot "Private\Dialogs\Show-CertificateSetupDialog.ps1")
. (Join-Path $PSScriptRoot "Private\Dialogs\Show-CreateInIntuneDialog.ps1")
. (Join-Path $PSScriptRoot "Private\Dialogs\Show-DefaultAppSettingsDialog.ps1")
. (Join-Path $PSScriptRoot "Private\Dialogs\Show-DeleteAppDialog.ps1")
. (Join-Path $PSScriptRoot "Private\Dialogs\Show-DependencyOverviewDialog.ps1")
. (Join-Path $PSScriptRoot "Private\Dialogs\Show-DiagnosticsDialog.ps1")
. (Join-Path $PSScriptRoot "Private\Dialogs\Show-EntraMemberPicker.ps1")
. (Join-Path $PSScriptRoot "Private\Dialogs\Show-FavoriteGroupsManager.ps1")
. (Join-Path $PSScriptRoot "Private\Dialogs\Show-GroupDriftCheckDialog.ps1")
. (Join-Path $PSScriptRoot "Private\Dialogs\Show-GroupManagerDialog.ps1")
. (Join-Path $PSScriptRoot "Private\Dialogs\Show-GroupOnlyPicker.ps1")
. (Join-Path $PSScriptRoot "Private\Dialogs\Show-IntuneAuditDialog.ps1")
. (Join-Path $PSScriptRoot "Private\Dialogs\Show-IntuneOnlyAppsDialog.ps1")
. (Join-Path $PSScriptRoot "Private\Dialogs\Show-MetadataDriftDialog.ps1")
. (Join-Path $PSScriptRoot "Private\Dialogs\Show-PackagingProgressDialog.ps1")
. (Join-Path $PSScriptRoot "Private\Dialogs\Show-RemoveGroupFromAppsDialog.ps1")
. (Join-Path $PSScriptRoot "Private\Dialogs\Show-SetDefaultsConfirmDialog.ps1")
. (Join-Path $PSScriptRoot "Private\Dialogs\Show-SyncMetadataDialog.ps1")
. (Join-Path $PSScriptRoot "Private\Dialogs\Show-TargetedAssignDialog.ps1")
. (Join-Path $PSScriptRoot "Private\Dialogs\Show-WingetSearchDialog.ps1")
. (Join-Path $PSScriptRoot "Private\Graph\GraphFetch.ps1")
. (Join-Path $PSScriptRoot "Private\GuiHelpers.ps1")
. (Join-Path $PSScriptRoot "Private\Pipeline.ps1")
. (Join-Path $PSScriptRoot "Private\QuickActions.ps1")
. (Join-Path $PSScriptRoot "Private\Settings.ps1")

. (Join-Path $PSScriptRoot "MainApp.ps1")
