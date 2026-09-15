<#
.SYNOPSIS
    Intune App Catalog & Deployment GUI - manage the app catalog and run the Intune
    pipeline, all from one window, all from one file.

.DESCRIPTION
    A WinForms front end for the Intune deployment pipeline. Self-contained: every
    packaging, deployment, and assignment step is embedded directly in this one file -
    nothing else to keep next to it except the app-data folder. App data lives as one
    JSON file per app in an "app-data" folder next to this script - not a single combined
    file - so a Git diff for one app's change only ever touches that app's own file, and one
    corrupted file doesn't take the rest of the catalog down with it. Two tabs:

    App Catalog
        Loads every app's own JSON file from the "app-data" folder next to this script,
        shows them in a grid, and lets you add, edit, or delete apps. Group membership
        (Required / Available / Uninstall) is set with checkboxes against every group already
        used in the catalog, plus a button to add a brand new group. Save writes straight
        back to each app's own file - no export/import step. Its own toolbar covers the rest
        of the pipeline: "Package apps..." builds the .intunewin package(s) and its output
        streams into the Log tab; "Batch deploy...", "Pull metadata and groups from
        Intune...", and "Push groups to Intune (single app)..." (per app, from the app
        editor, or "Push groups to Intune (multiple apps)..." across several) sync Intune app
        names, Entra ID groups, and assignments against the catalog.

    Log
        Shows the real-time combined output of whichever pipeline step ("Package apps...",
        etc.) is currently running, and stays on the last run's output afterward.

        Each step runs as its own hidden PowerShell process so the GUI stays responsive; its
        combined output streams into this log box in real time. Under the hood, the embedded
        script text gets written out to a short-lived temp .ps1 file in this script's own
        folder (deleted again as soon as that step finishes) and run from there - this keeps
        each step safely isolated in its own process, so an "exit" call inside that logic
        (both embedded scripts use exit for error handling) only ends that one step instead
        of taking down the whole GUI.

.NOTES
    IMPORTANT - about confirmation prompts:
    The group-assignment step normally asks "proceed? (y/n)" on the console before applying
    changes. A hidden background process can never answer that prompt, so it would hang
    forever. To avoid that, this GUI always runs it with -AutoApprove $true and shows its own
    confirmation dialog first instead. Use the Dry Run checkbox to preview changes with zero
    risk before you tick that dialog's "Yes, apply".

    Requires: Windows PowerShell 5.1+ (or PowerShell 7+ on Windows), the Microsoft.Graph
    modules the deployment/assignment steps themselves check for, and an "app-data" folder
    next to this script.

.EXAMPLE
    .\IntuneDeployment.ps1
#>

[CmdletBinding()]
param()

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
Add-Type -AssemblyName System.Security   # for the native X509Certificate2UI store picker
[System.Windows.Forms.Application]::EnableVisualStyles()

# =====================================================================
# Shared app state
# =====================================================================
# Single explicit container for every piece of state that needs to be
# reachable from code\Private\ functions (main-window controls, Graph
# settings, the in-memory catalog, caches, ...) - replaces what used to
# be dozens of separate $Script:/$Global: variables scattered across
# this file. A hashtable rather than a fixed-shape object since new
# keys get added incrementally below as each piece of UI/state is
# built, and PowerShell hashtables support the same dot-notation
# property access ($Global:App.Foo) either way. Declared global (not
# script-scoped) for the same reason every code\Private\ function itself is
# declared "Global:" - a Windows PowerShell 5.1/pwsh 7 difference in
# how deeply a deferred closure's variable lookup reaches back into an
# intermediate script scope meant a script-scoped container was not
# reliably visible from inside every closure/callback; global always is.
$Global:App = @{}

# =====================================================================
# Paths & state
# =====================================================================
$Global:App.RootPath        = $PSScriptRoot
# Points at a FOLDER of per-app JSON files now (one file per app, e.g.
# "app-data/7zip.json"), not a single input.json - kept the same variable
# name despite the changed meaning to minimize how many of the many
# existing references throughout this script needed touching, given the
# genuine risk of a change this size.
$Global:App.LinkedFilePath  = Join-Path $Global:App.RootPath "app-data"
$Global:App.Apps            = New-Object System.Collections.ArrayList
$Global:App.UnsavedChangesBox = @{ Value = $false }   # container (never reassigned) so closures can mutate it safely
$Global:App.IntuneAppsCache = New-Object System.Collections.ArrayList   # populated by Start-IntuneAppLookup: array of @{ id; displayName } - mutated in place (Clear+Add), never reassigned, so every closure that references it stays in sync
$Global:App.EntraDirectoryCache = New-Object System.Collections.ArrayList   # populated by Start-EntraDirectoryLookup: array of @{ displayName; type ("Group"/"User"); id; upn } - same mutate-in-place pattern as above
$Global:App.EntraDirectoryLookupRunning = $false   # guards against two overlapping Start-EntraDirectoryLookup runs - see its own comment
# Populated whenever any live-vs-Intune check runs for an app - the
# single-app auto-fetch inside Show-CreateInIntuneDialog, or
# Show-IntuneAuditDialog's own bulk run - keyed by appName. Persisted to
# its OWN file ($Global:App.LastAuditCachePath), deliberately NOT round-tripped
# through ConvertTo-AppRecord/ConvertTo-SingleAppJson (both are strict,
# hand-rolled field whitelists that exist specifically so a Git diff for
# one app's change only ever touches that one app's file - an audit
# timestamp that changes on every check would turn every audit run into
# diff noise across every checked app's own catalog file, working against
# the whole reason that per-app-file design exists). See
# Load-LastAuditCache/Save-LastAuditCache/Set-LastAuditCacheEntry/
# Get-LastAuditSummary. A missing or corrupt cache file just leaves this
# empty, same as it always was before persistence existed - nothing here
# is load-bearing for the app to function; the main grid's own
# "Last Audit" column simply falls back to "Never audited".
$Global:App.LastAuditResults = @{}
$Global:App.LastAuditCachePath = Join-Path $Global:App.RootPath "last-audit-cache.json"
# Bumped by Import-AppsFromFile every time it (re)loads the catalog -
# Reload, Open other folder..., or startup itself. Start-TypeVersionBackfill
# captures the value in effect when its background queue starts and checks
# it again before every write; Import-AppsFromFile mutates $Global:App.Apps
# IN PLACE (.Clear()/.Add(), never replaces the list object itself), so a
# backfill queue still in flight from a folder the user has since moved
# away from would otherwise happily go on matching by app NAME against
# whatever is now in that same list - silently writing borrowed Intune
# type/version data onto an unrelated app in the newly-loaded catalog that
# just happens to share a name with one from the old one.
$Global:App.CatalogGeneration = 0
$Global:App.LogFileWriter = $null   # opened in Initialize-Folders, written to by Write-Log, closed on FormClosing - see both below
$Global:App.LogFlushTimer = $null   # periodic flush timer for the above - see Initialize-Folders
$Global:App.AppVersion = "1.1"   # bump when shipping a meaningfully different build, so "which version are you on" is answerable at a glance rather than by diffing the whole file

# App-only Graph auth (certificate) - must match the values in the Assign step /
# your Entra ID app registration. Left blank on purpose - no tenant/client
# ID or certificate thumbprint should ever be hardcoded in a script that
# lives in a repo. Configure these via "Settings..." in the app on first
# run; they're then saved to intune-deployment-settings.json next to this
# script and loaded automatically from there on every subsequent launch
# (see Import-GraphSettings below). The certificate itself must already be
# installed in this user's certificate store - Settings can also pick an
# existing one or generate a new one.
$Global:App.GraphTenantId              = ""
$Global:App.GraphClientId              = ""
$Global:App.GraphCertificateThumbprint = ""
$Global:App.SettingsFilePath = Join-Path $Global:App.RootPath "intune-deployment-settings.json"

# Group names marked as "favorites" - shown as ready-to-tick options in
# every app's Required/Available/Uninstall lists (new and existing alike),
# instead of those lists defaulting to every group ever used by any app in
# the whole catalog. Persisted in the same settings file as Graph
# credentials, so both need to be written together on every save - see the
# comment on Write-SettingsFile below for why.
$Global:App.FavoriteGroups = New-Object System.Collections.Generic.List[string]

# The computed defaults Get-DefaultAppMetadata hands out for a brand-new
# Winget app (what "Set default values..." and the custom-field
# highlighting in Show-CreateInIntuneDialog both compare against, and what
# Batch Deploy falls back to for an app with no saved metadata). Starts as
# exactly the values this app has always hardcoded here - so behavior is
# byte-for-byte identical until someone actually opens "Edit default
# values..." and changes something - then persisted in the same settings
# file as Graph credentials/Favorite groups, for the same
# write-everything-together reason documented on Write-SettingsFile below.
$Global:App.DefaultAppSettings = [pscustomobject]@{
    Architecture             = "x64"
    InstallContext           = "System"
    # Newest Windows 10 release, not Windows 11 - a sensible default
    # shouldn't silently require Windows 11 for every new app. See
    # Show-CreateInIntuneDialog's own $minOsMap for the full set this can
    # be set to.
    MinOSKey                 = "W10_22H2"
    MinDiskSpaceMB           = 0
    MinMemoryMB              = 0
    MinProcessors            = 0
    MinCpuSpeedMHz           = 0
    InstallTimeMinutes       = 60
    DeviceRestartBehavior    = "basedOnReturnCode"
    AllowAvailableUninstall  = $false
    ReturnCodes              = @(
        [pscustomobject]@{ returnCode = 0; type = "success" }
        [pscustomobject]@{ returnCode = 1707; type = "success" }
        [pscustomobject]@{ returnCode = 3010; type = "softReboot" }
        [pscustomobject]@{ returnCode = 1641; type = "hardReboot" }
        [pscustomobject]@{ returnCode = 1618; type = "retry" }
    )
    # The app(s) every OTHER app defaults to depending on, when an app by
    # that name exists in the catalog - an empty array means "no default
    # dependencies".
    DefaultDependencyAppNames = @("Winget AutoUpdate")
}

# Guards Start-TypeVersionBackfill (see its own definition) against
# running more than once per catalog load - it's kicked off automatically
# on startup and after Reload/Open other folder, not on every grid
# refresh (typing in the search box refreshes the grid on every
# keystroke - firing a Graph fetch queue on each one would be absurd).
$Global:App.TypeVersionBackfillDone = $false

# =====================================================================
# Styling - single, consistent light palette applied to every control
# =====================================================================
# A designed palette, not raw SystemColors - the previous version themed
# every control to whatever the OS's own Control/Window/Highlight colors
# happened to be, which is exactly the dated, mismatched-grey Windows look
# this was meant to move away from. Colors below are fixed values instead,
# so the app looks the same, deliberately, on every machine regardless of
# the user's own Windows accent color or theme. Only colors change here -
# no controls gain new fixed sizes/positions, so this carries none of the
# layout risk a font-size change would (many dialogs use hand-tuned pixel
# coordinates already sized for the current font).
$Global:App.LightPalette = @{
    FormBack       = [System.Drawing.Color]::FromArgb(246,247,249)
    ControlFore    = [System.Drawing.Color]::FromArgb(32,33,36)
    FieldBack      = [System.Drawing.Color]::White
    ButtonBack     = [System.Drawing.Color]::White
    ButtonHoverBack = [System.Drawing.Color]::FromArgb(237,242,253)
    ButtonPressBack = [System.Drawing.Color]::FromArgb(222,231,250)
    GridBack       = [System.Drawing.Color]::White
    GridAltBack    = [System.Drawing.Color]::FromArgb(248,249,251)
    GridHeaderBack = [System.Drawing.Color]::FromArgb(241,243,246)
    BorderColor    = [System.Drawing.Color]::FromArgb(216,219,224)
    SelectionBack  = [System.Drawing.Color]::FromArgb(37,99,235)
    SelectionFore  = [System.Drawing.Color]::White
}

# Applies the current theme to a control and everything nested inside it,
# recursively - call on any Form/dialog right before ShowDialog() (after all
# its controls have been built and added) so its whole tree gets themed.
# RichTextBoxes used as log consoles are deliberately skipped - they already
# have their own explicit dark styling set wherever they're created (a
# console look regardless of the app's overall theme), and re-theming them
# here would fight that.


# Overrides $Global:App.GraphTenantId/ClientId/CertificateThumbprint from
# intune-deployment-settings.json if that file exists, so choices made in the Settings
# dialog persist across restarts without editing this script's source.

# Always writes EVERY setting this file holds, not just the ones the
# caller happens to be updating - Save-GraphSettings and
# Save-FavoriteGroups both route through this single function rather
# than each independently overwriting the whole file with only their own
# fields, which would silently wipe out whichever setting the OTHER
# function manages. The same class of bug already found and fixed once
# this session (the App Editor overwriting metadata because it rebuilt
# the whole app record from only its own fields) - fixed here from the
# start by construction, not by patching around it after the fact.


# Favorites are stored as their own list, mutated directly by whichever
# UI manages them, then persisted the same way Save-GraphSettings does -
# through the one shared writer above, so this never touches (or risks
# clobbering) the Graph credential fields it doesn't manage.

# Clears the delegated user's sign-in used for Check/Upload/Delete in
# Settings - deletes the same MSAL token cache files Microsoft Graph
# PowerShell persists to disk by default. Deliberately tied to the WHOLE
# APP closing, not to Settings closing - closing and reopening Settings
# during the same session (e.g. to do something else, then come back and
# run another cert operation) shouldn't force a fresh sign-in each time.
# Only when the app itself exits does the cached credential get cleared.

Import-GraphSettings

# =====================================================================
# Embedded pipeline scripts
# =====================================================================
# Every packaging, deployment, and assignment step's full script content -
# each one lives as its own real file under .\code\EmbeddedScripts, loaded here
# once at startup relative to this script's own location ($PSScriptRoot),
# not embedded as a literal here-string in this file anymore. At runtime,
# Start-PipelineProcess writes whichever one is needed out to a temp .ps1
# file INSIDE $Global:App.RootPath (not $env:TEMP), because several of these
# scripts use $PSScriptRoot internally to find app-data / IntuneWinAppUtil.exe
# - the temp file has to live in the real deployment folder for that to
# resolve correctly. It's deleted again as soon as the child process exits,
# successfully or not.
$Global:App.EmbeddedPackageScript = Get-Content -Path (Join-Path $PSScriptRoot "code\EmbeddedScripts\Package.ps1") -Raw -Encoding UTF8
$Global:App.EmbeddedCreateAppScript = Get-Content -Path (Join-Path $PSScriptRoot "code\EmbeddedScripts\CreateApp.ps1") -Raw -Encoding UTF8
$Global:App.EmbeddedTargetedAssignScript = Get-Content -Path (Join-Path $PSScriptRoot "code\EmbeddedScripts\TargetedAssign.ps1") -Raw -Encoding UTF8
$Global:App.EmbeddedBatchAssignScript = Get-Content -Path (Join-Path $PSScriptRoot "code\EmbeddedScripts\BatchAssign.ps1") -Raw -Encoding UTF8
$Global:App.EmbeddedDeleteAppScript = Get-Content -Path (Join-Path $PSScriptRoot "code\EmbeddedScripts\DeleteApp.ps1") -Raw -Encoding UTF8
$Global:App.EmbeddedGroupManagerScript = Get-Content -Path (Join-Path $PSScriptRoot "code\EmbeddedScripts\GroupManager.ps1") -Raw -Encoding UTF8
$Global:App.EmbeddedSyncMetadataScript = Get-Content -Path (Join-Path $PSScriptRoot "code\EmbeddedScripts\SyncMetadata.ps1") -Raw -Encoding UTF8
$Global:App.EmbeddedCertUploadScript = Get-Content -Path (Join-Path $PSScriptRoot "code\EmbeddedScripts\CertUpload.ps1") -Raw -Encoding UTF8

# =====================================================================
# Data helpers
# =====================================================================


# Minimal, predictable JSON string escaping - just the characters JSON actually
# requires escaping. Deliberately does NOT do ConvertTo-Json's HTML-style
# escaping of & < > etc.

# Renders a string array as a single-line inline JSON array, matching the
# original input.json style exactly: e.g. ["a","b","c"] with no spaces after
# commas, or [] when empty.
# Renders a string array as multi-line JSON, one item per line, matching the
# desired style: "[]" inline when empty, otherwise items indented two spaces
# deeper than the array's own indent, closing bracket back at the array's indent.
# Hand-rolled serializer for detectionRule specifically - its shape
# varies by detection type (Script/Msi/File/Registry), which is exactly
# why this was originally routed through ConvertTo-Json instead of being
# hand-rolled like everything else. But the UI only ever produces
# exactly these four known, fixed shapes, each with a small, simple set
# of string/boolean fields and no further nesting - genuinely
# hand-rollable, not the open-ended case ConvertTo-Json exists for.
# Hand-rolling it too means this file's JSON output is now visually
# consistent throughout (this app's own single-space-after-colon,
# 2-space-indent style everywhere, not PowerShell's native
# double-space/alignment style for just this one nested field), and,
# more importantly, removes ConvertTo-Json from this path entirely - the
# same cmdlet already confirmed, directly and repeatedly this session,
# to sometimes silently produce a completely empty result with no error
# at all for certain inputs.


# Hand-built serializer for a SINGLE app's own JSON object (2-space indent,
# single space after colons, literal & rather than \u0026, inline [] for
# empty arrays, one item per line for non-empty arrays) - same style
# already proven for the whole-catalog array, just producing one object
# instead of wrapping many in an array. Made to produce this directly
# rather than via fragile regex post-processing, for this known, fixed
# schema.

# Hand-built serializer for the "create app in Intune" temp config, for
# the same reason ConvertTo-SingleAppJson already hand-rolls the catalog
# file: serializing this whole, larger object (30+ fields, several of
# them holding substantial script/command text) through one single
# ConvertTo-Json call was confirmed, directly and repeatedly, to
# sometimes silently produce a completely empty result with no error
# thrown at all - even with -ErrorAction Stop, even with the problematic
# earlier Select-Object step already removed. DetectionRule is the one
# field still routed through ConvertTo-Json, isolated on its own, small
# object - mirroring the exact approach that already fixed the identical
# symptom for the catalog's own metadata.detectionRule field.



# Adds a right-click "Remove from list" option to a group CheckedListBox -
# used by both the Favorite groups manager and each Required/Available/
# Uninstall list in the app editor. Deliberately right-click, not a
# regular button: CheckOnClick is already on for these lists, so a normal
# left-click always toggles the checkbox - a separate "select this row,
# then click a button" flow would conflict with that on every single
# click. Only ever removes an UNCHECKED item - a checked one has to be
# unchecked first, so a currently-active assignment for THIS app (or
# THIS session's favorites) can never be removed by accident with one
# unintended click.

# =====================================================================
# Intune App ID lookup (Microsoft Graph)
# =====================================================================
# Searches winget's repository (winget search) for packages matching a query
# and returns Name/Id/Version/Source for each match - lets the person pick
# the correct winget ID from the app editor instead of having to know or
# guess it. Runs winget.exe on a background runspace, never on the UI
# thread: winget can show an interactive first-run prompt (accept source
# agreements) that would hang forever with no console to answer it if run
# synchronously and redirected - the exact same failure class discovered
# earlier with Invoke-WebRequest/IE parsing. --accept-source-agreements and
# --disable-interactivity both defend against that, and a hard 30s
# WaitForExit+Kill is a second, unconditional safety net regardless of
# whether winget honors those flags on a given version.
# $OnComplete is called with ($success, $data) where $data is either an
# array of pscustomobjects (Name/Id/Version/Source) or an error message.

# =====================================================================
# Fetches every app currently registered in Intune (id + displayName) via
# Microsoft Graph, using the same app-only certificate authentication as
# every other Graph call in this app (see $Global:App.GraphTenantId / GraphClientId /
# GraphCertificateThumbprint above) - no interactive sign-in required, but the
# certificate must be installed in this machine's/user's certificate store.
# Runs on a background runspace so the GUI doesn't freeze during the call.
# $OnComplete is called with ($success, $data) where $data is either the
# array of apps or an error message string.


# Fetches minimumSupportedOperatingSystem/minimumSupportedWindowsRelease for
# every win32LobApp in Intune, for Show-DiagnosticsDialog's own Min OS drift
# check. Deliberately its OWN, separate call - NOT folded into Start-
# IntuneAppLookup above, after that combination was tried and broke it for
# everyone: the base deviceAppManagement/mobileApps collection is
# polymorphic (win32LobApp, officeSuiteApp, winGetApp, ...), and Graph
# rejects a $select naming a property that only exists on ONE derived type
# ("Could not find a property named 'minimumSupportedOperatingSystem' on
# type 'microsoft.graph.mobileApp'" - a real 400, confirmed live). The fix
# here is $filter=isof(...) instead of $select - that scopes the whole
# query to win32LobApp specifically, so Graph returns the FULL object
# (every win32LobApp-specific property included) with nothing needing to
# be named in a $select at all. Narrower results than Start-IntuneAppLookup
# (win32LobApp only, not every app type) is exactly what this check wants
# anyway - the properties it's after don't exist on any other type.

# Fetches every group and user in Entra ID (id, displayName, and for users their
# UPN) via Microsoft Graph, using the same app-only certificate identity as
# Start-IntuneAppLookup. Requires the app registration to have Group.Read.All
# and User.Read.All (or Directory.Read.All) as APPLICATION permissions with
# admin consent - separate from whatever DeviceManagementApps permission the
# App ID lookup needs. $OnComplete is called with ($success, $data) where
# $data is either the array of entries or an error message string.

# Returns Intune apps whose displayName relates to $Name: exact matches first,
# then partial (contains, either direction) matches.

# Search/browse picker for Entra ID groups and users, backed by
# $Global:App.EntraDirectoryCache. Includes a manual-entry fallback (whatever's
# typed in the search box is used if nothing in the list is selected) and a
# Refresh button to (re)run Start-EntraDirectoryLookup without leaving the
# dialog. Returns the chosen/typed display name, or $null if cancelled.

# Same search/refresh pattern as Show-EntraMemberPicker, but filtered to
# groups only and framed as "pick a target group" rather than "add a
# member" - used by Group Manager so you can find an existing group by name
# instead of typing one blind and risking an accidental near-duplicate from
# a typo or casing difference. Written as its own function rather than
# parameterizing Show-EntraMemberPicker, since that function already has
# established callers (the catalog's group pickers) that shouldn't be put
# at risk by changes made for this unrelated use.

# Bulk review dialog: matches every catalog app against $Global:App.IntuneAppsCache
# by name and lets the user apply App IDs for the rows they check.

# =====================================================================
# Winget search dialog
# =====================================================================
# Lets the person search winget's repository right from the app editor
# instead of having to know or look up the exact winget ID. Returns the
# selected package's winget ID, or $null if cancelled/nothing picked.

# Simple single-select list picker. Returns the selected string, or $null if cancelled.


# Purely informational - shows the manual app-registration setup steps and
# offers a link to the Entra admin center, but makes NO Graph calls of its
# own. Deliberately kept manual rather than automated: creating an app
# registration with broad tenant permissions (DeviceManagementApps, Group,
# Directory, etc.) and granting admin consent for it IS the approval-worthy
# event here, not something to script around the portal's own review
# screens for, even though only a Global/Privileged Role Admin could run
# either path. It's also a one-time, per-environment step, so automating it
# buys little repeated convenience for a real reduction in review friction.



# =====================================================================
# Main window
# =====================================================================
$Global:App.Form = New-Object System.Windows.Forms.Form
$Global:App.Form.Text = "Intune App Catalog & Deployment (v$($Global:App.AppVersion))"
$Global:App.Form.Size = New-Object System.Drawing.Size(1080, 720)
$Global:App.Form.MinimumSize = New-Object System.Drawing.Size(860, 560)
$Global:App.Form.StartPosition = "CenterScreen"
$Global:App.Form.WindowState = [System.Windows.Forms.FormWindowState]::Maximized
$Global:App.Form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = "Fill"
$tabCatalog  = New-Object System.Windows.Forms.TabPage "App Catalog"
$tabPipeline = New-Object System.Windows.Forms.TabPage "Log"
$tabs.TabPages.AddRange(@($tabCatalog, $tabPipeline))
$Global:App.Form.Controls.Add($tabs)

$statusStrip = New-Object System.Windows.Forms.StatusStrip
$Global:App.StatusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$Global:App.StatusLabel.Spring = $true
$Global:App.StatusLabel.TextAlign = "MiddleLeft"
$statusStrip.Items.Add($Global:App.StatusLabel) | Out-Null
$Global:App.Form.Controls.Add($statusStrip)


# Shared function purely so the theme-toggle logic lives in one place
# rather than being duplicated wherever a control triggers it.
# Shared by every operation dialog that has both a short status label and a
# live log box: writes the FULL error into the log (which has room and is
# already where the play-by-play lives) and leaves the status label with
# just a short, unmissable verdict - rather than cramming a long error
# message into a small label that then has to wrap across several lines and
# crowd out the log below it.

# The one MessageBox every embedded-pipeline dialog shows when it can't even
# write the temp config file a Start-PipelineProcess run needs - identical
# wording used to be copy-pasted at every one of those ~14 call sites, which
# meant a future wording tweak would need to happen in all of them at once.
# Centralized here instead so there's exactly one place that owns it.

# The same dark-terminal ReadOnly/BackColor/ForeColor/Font setup was
# copy-pasted onto every log RichTextBox in this app (14 of them) - applied
# here instead so the theme lives in one place. Location/Size/Dock are
# layout, not theme, so callers still set those themselves after this.

# =====================================================================
# App Catalog tab
# =====================================================================
# Wraps a set of buttons in a titled GroupBox so the toolbar reads as
# labeled topic clusters instead of one long undifferentiated row. Height is
# fixed (just enough for one button row); width auto-sizes to content so
# each group is only as wide as it needs to be.

$toolbar = New-Object System.Windows.Forms.FlowLayoutPanel
$toolbar.Dock = "Top"
$toolbar.WrapContents = $true
# AutoSize (not a fixed Height) is the actual fix here - a fixed height
# would clip a second row entirely once wrapping kicks in on a narrower
# window, since the panel wouldn't actually be tall enough to show it.
$toolbar.AutoSize = $true
$toolbar.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
$toolbar.Padding = New-Object System.Windows.Forms.Padding(6)

# Ellipsis marks every one of these three as "opens another window", same
# convention used everywhere else in this app (Settings..., Batch deploy...,
# etc.) - and matches the wording the right-click context menu already uses
# for the identical actions (Edit.../Remove from catalog..., both of which
# just PerformClick() these same buttons), rather than a second, different
# label for the same click.
$btnNew    = New-Object System.Windows.Forms.Button; $btnNew.Text = "+ Add app..."
$btnEdit   = New-Object System.Windows.Forms.Button; $btnEdit.Text = "Edit..."
$Global:App.BtnDelete = New-Object System.Windows.Forms.Button; $Global:App.BtnDelete.Text = "Remove from catalog..."
$Global:App.BtnSave   = New-Object System.Windows.Forms.Button; $Global:App.BtnSave.Text = "Force save catalog"
$btnReload = New-Object System.Windows.Forms.Button; $btnReload.Text = "Reload"
$btnOpen   = New-Object System.Windows.Forms.Button; $btnOpen.Text = "Open other folder..."
$Global:App.BtnLookupIds = New-Object System.Windows.Forms.Button; $Global:App.BtnLookupIds.Text = "Look up App IDs..."
$btnCheckIntuneOnly = New-Object System.Windows.Forms.Button; $btnCheckIntuneOnly.Text = "Intune sync check..."
$btnBatchAssign = New-Object System.Windows.Forms.Button; $btnBatchAssign.Text = "Push groups to Intune (multiple apps)..."
$btnSyncMetadata = New-Object System.Windows.Forms.Button; $btnSyncMetadata.Text = "Pull metadata and groups from Intune..."
$btnBatchEdit = New-Object System.Windows.Forms.Button; $btnBatchEdit.Text = "Batch edit Intune fields..."
$btnBatchDeploy = New-Object System.Windows.Forms.Button; $btnBatchDeploy.Text = "Batch deploy..."
$btnGroupManager = New-Object System.Windows.Forms.Button; $btnGroupManager.Text = "Group manager..."
$btnFavoriteGroups = New-Object System.Windows.Forms.Button; $btnFavoriteGroups.Text = "Favorite groups..."
$btnDependencies = New-Object System.Windows.Forms.Button; $btnDependencies.Text = "View dependencies..."
$btnGroupDrift = New-Object System.Windows.Forms.Button; $btnGroupDrift.Text = "Check catalog groups against Entra ID..."
$btnIntuneAudit = New-Object System.Windows.Forms.Button; $btnIntuneAudit.Text = "Intune Audit..."
$Global:App.BtnRunLaunch = New-Object System.Windows.Forms.Button; $Global:App.BtnRunLaunch.Text = "Package apps"
$btnCertSetup = New-Object System.Windows.Forms.Button; $btnCertSetup.Text = "Settings..."
$btnDefaultValues = New-Object System.Windows.Forms.Button; $btnDefaultValues.Text = "Edit default values..."
$btnDiagnostics = New-Object System.Windows.Forms.Button; $btnDiagnostics.Text = "Run diagnostics..."

# One shared ToolTip component serves every button - there are enough of
# them doing related-but-different things (several Pull/Push/Check pairs
# across Intune and Entra ID) that a tooltip spelling out exactly what each
# one touches is worth having on all of them, not just the less obvious
# ones.
$toolbarTips = New-Object System.Windows.Forms.ToolTip
$toolbarTips.AutoPopDelay = 15000
$toolbarTips.InitialDelay = 400
$toolbarTips.ReshowDelay = 200
$toolbarTips.SetToolTip($btnNew, "Add a new app to the catalog by name - doesn't touch Intune yet.")
$toolbarTips.SetToolTip($btnEdit, "Edit the selected app's name, winget ID, and group assignments.")
$toolbarTips.SetToolTip($Global:App.BtnDelete, "Remove the selected app from the catalog. Does not delete it from Intune.")
$toolbarTips.SetToolTip($Global:App.BtnSave, "Not usually needed - every change already saves itself automatically. Force-saves the whole catalog now anyway, if you ever want to be extra sure.")
$toolbarTips.SetToolTip($btnReload, "Discard any unsaved changes and reload the catalog from disk.")
$toolbarTips.SetToolTip($btnOpen, "Switch to a different folder of per-app JSON files.")
$toolbarTips.SetToolTip($Global:App.BtnLookupIds, "Search Intune by name for apps missing an App ID, and fill it in.")
$toolbarTips.SetToolTip($btnCheckIntuneOnly, "Compares Intune against this catalog: apps in Intune not yet in the catalog, catalog apps renamed in Intune since, and catalog apps whose App ID no longer exists in Intune. Read-only.")
$toolbarTips.SetToolTip($btnBatchAssign, "Add a favorite group to multiple apps at once, then preview and apply the result to Intune.")
$toolbarTips.SetToolTip($btnSyncMetadata, "Pull current metadata from Intune into the local catalog for apps that already have an App ID. Read-only.")
$toolbarTips.SetToolTip($btnBatchEdit, "Change one or more fields (architecture, min OS, requirements, restart behavior, return codes, dependencies) across multiple deployed Win32 apps at once, then push each one to Intune.")
$toolbarTips.SetToolTip($btnBatchDeploy, "Create multiple apps in Intune, in dependency order. Uses metadata saved via 'Save for later...' where an app has it, otherwise the same defaults Deploy to Intune's own form would.")
$toolbarTips.SetToolTip($btnGroupManager, "Create, update, or delete an Entra ID group and manage its members.")
$toolbarTips.SetToolTip($btnFavoriteGroups, "Pick which groups show up as ready-to-tick options in every app's Required/Available/Uninstall lists.")
$toolbarTips.SetToolTip($btnDependencies, "See every app's dependencies, what depends on it, and any missing or circular dependency. Read-only, local only.")
$toolbarTips.SetToolTip($btnGroupDrift, "Check every group name referenced in the catalog against what actually exists in Entra ID.")
$toolbarTips.SetToolTip($btnIntuneAudit, "Check every deployed app's Metadata, Groups, Dependencies, and Assignments against what's actually live in Intune, all in one grid. Read-only.")
$toolbarTips.SetToolTip($Global:App.BtnRunLaunch, "Build the .intunewin package(s) for the selected (or all) uncommon apps.")
$toolbarTips.SetToolTip($btnCertSetup, "Configure the Tenant ID, Client ID, and certificate used to connect to Microsoft Graph.")
$toolbarTips.SetToolTip($btnDefaultValues, "Change the computed defaults every new Winget app starts with (architecture, min OS, requirements, return codes, ...). Doesn't touch any app already saved or deployed.")
$toolbarTips.SetToolTip($btnDiagnostics, "Read-only health check: Graph connectivity, certificate expiry, catalog completeness, and drift against what's actually in Intune.")

$Global:App.LblSearch = New-Object System.Windows.Forms.Label
$Global:App.LblSearch.Text = "Search:"
$Global:App.LblSearch.AutoSize = $true
$Global:App.LblSearch.Padding = New-Object System.Windows.Forms.Padding(10,4,0,0)
$Global:App.TxtSearch = New-Object System.Windows.Forms.TextBox
$Global:App.TxtSearch.Width = 220

# The toolbar used to be organized by WHICH SYSTEM a button touches
# (Catalog/Intune/Entra ID/Settings), which meant a brand-new user facing
# ~19 buttons across four boxes had no signal for which ones they'd
# actually need first. Reorganized instead around the core workflow - add
# an app, edit it, package it, deploy it, assign it, audit it - as one
# small "Get started" row, with everything else (maintenance, one-off
# lookups, Entra ID/Settings tools) tucked behind a single "More actions"
# dropdown, grouped by when you'd actually reach for it. Every button
# still exists exactly as before, fully wired the same way - nothing here
# changes what any of them do, only how many are visible before you've
# asked for more.
# Reload sits here too, not in the overflow menu - this catalog is Git-
# tracked (the whole per-app-JSON-file design exists for clean diffs), so
# "someone else pushed a change, pull it and reload" is a genuinely
# recurring step for this tool's actual audience, not a rare recovery
# action worth burying.
$gbPrimary = New-ToolbarGroup -Title "Get started" -Buttons @($btnNew, $btnEdit, $Global:App.BtnRunLaunch, $btnBatchDeploy, $btnBatchAssign, $btnIntuneAudit, $btnReload)

# Builds one ToolStripMenuItem submenu from a list of {Text;Btn} pairs -
# each item just PerformClick()s the real button (still fully wired, just
# no longer directly on the toolbar), the same "menu item delegates to
# the real control" convention the grid's own right-click context menu
# already uses.

$menuMoreActions = New-Object System.Windows.Forms.ContextMenuStrip
[void]$menuMoreActions.Items.Add((New-OverflowSubmenu -Title "Catalog maintenance" -Items @(
    @{ Text = $Global:App.BtnDelete.Text; Btn = $Global:App.BtnDelete }
    @{ Text = $Global:App.BtnSave.Text; Btn = $Global:App.BtnSave }
    @{ Text = $btnOpen.Text; Btn = $btnOpen }
    @{ Text = $btnFavoriteGroups.Text; Btn = $btnFavoriteGroups }
)))
[void]$menuMoreActions.Items.Add((New-OverflowSubmenu -Title "Intune" -Items @(
    @{ Text = $Global:App.BtnLookupIds.Text; Btn = $Global:App.BtnLookupIds }
    @{ Text = $btnCheckIntuneOnly.Text; Btn = $btnCheckIntuneOnly }
    @{ Text = $btnSyncMetadata.Text; Btn = $btnSyncMetadata }
    @{ Text = $btnBatchEdit.Text; Btn = $btnBatchEdit }
)))
[void]$menuMoreActions.Items.Add((New-OverflowSubmenu -Title "Entra ID" -Items @(
    @{ Text = $btnGroupManager.Text; Btn = $btnGroupManager }
)))
# Every read-only "check something" action grouped together here,
# regardless of which system it happens to touch - someone looking for
# "check X" shouldn't need to already know whether X lives under
# Catalog/Intune/Entra ID to find it.
[void]$menuMoreActions.Items.Add((New-OverflowSubmenu -Title "Verify" -Items @(
    @{ Text = $btnDependencies.Text; Btn = $btnDependencies }
    @{ Text = $btnGroupDrift.Text; Btn = $btnGroupDrift }
    @{ Text = $btnDiagnostics.Text; Btn = $btnDiagnostics }
)))
[void]$menuMoreActions.Items.Add((New-OverflowSubmenu -Title "Settings" -Items @(
    @{ Text = $btnCertSetup.Text; Btn = $btnCertSetup }
    @{ Text = $btnDefaultValues.Text; Btn = $btnDefaultValues }
)))

$btnMoreActions = New-Object System.Windows.Forms.Button
$btnMoreActions.Text = "More actions..."
# A plain Button doesn't show its ContextMenuStrip on a left click (that's
# right-click-only by default) - .Show() at the button's own bottom-left
# corner is the standard WinForms way to make a button open a dropdown.
$btnMoreActions.Add_Click({
    $menuMoreActions.Show($btnMoreActions, (New-Object System.Drawing.Point(0, $btnMoreActions.Height)))
}.GetNewClosure())
$toolbarTips.SetToolTip($btnMoreActions, "Catalog maintenance, one-off Intune lookups, Entra ID tools, and Settings.")
$gbMoreActions = New-ToolbarGroup -Title "More" -Buttons @($btnMoreActions)

$searchPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$searchPanel.AutoSize = $true
$searchPanel.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
$searchPanel.FlowDirection = "LeftToRight"
# Top margin bumped up from the toolbar groups' own 4px - a GroupBox (what
# every button sits inside) has its title text ABOVE the button row, so
# the buttons themselves sit well below the box's own top edge; this plain
# FlowLayoutPanel has no such header, so matching the groups' 4px margin
# left Search sitting visibly higher than the buttons beside it instead of
# level with them.
$searchPanel.Margin = New-Object System.Windows.Forms.Padding(4,24,4,0)
$searchPanel.Controls.Add($Global:App.LblSearch)
$searchPanel.Controls.Add($Global:App.TxtSearch)

$toolbar.Controls.AddRange(@($gbPrimary, $gbMoreActions, $searchPanel))
$tabCatalog.Controls.Add($toolbar)

# Hidden by default - shown only when Graph credentials aren't configured
# yet, which otherwise silently blocks every Graph-based feature in this
# app with no visible explanation on the tab a new user actually sees
# first. Previously this only ever got written to the Log tab, which
# isn't the default active one - easy to never notice until something
# fails with no obvious reason why.
$Global:App.PanelCredWarning = New-Object System.Windows.Forms.Panel
$Global:App.PanelCredWarning.Dock = "Top"
$Global:App.PanelCredWarning.Height = 40
$Global:App.PanelCredWarning.BackColor = [System.Drawing.Color]::FromArgb(255, 243, 205)
$Global:App.PanelCredWarning.Visible = $false
$Global:App.LblCredWarning = New-Object System.Windows.Forms.Label
$Global:App.LblCredWarning.Text = "No Graph connection configured yet - Intune/Entra ID features won't work until this is set up."
$Global:App.LblCredWarning.ForeColor = [System.Drawing.Color]::FromArgb(133, 100, 4)
$Global:App.LblCredWarning.Font = New-Object System.Drawing.Font($Global:App.PanelCredWarning.Font, [System.Drawing.FontStyle]::Bold)
$Global:App.LblCredWarning.Location = New-Object System.Drawing.Point(12, 10)
$Global:App.LblCredWarning.AutoSize = $true
$Global:App.PanelCredWarning.Controls.Add($Global:App.LblCredWarning)
$btnCredWarningSettings = New-Object System.Windows.Forms.Button
$btnCredWarningSettings.Text = "Open Settings..."
$btnCredWarningSettings.Location = New-Object System.Drawing.Point(720, 5)
$btnCredWarningSettings.Size = New-Object System.Drawing.Size(130, 28)
$btnCredWarningSettings.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$Global:App.PanelCredWarning.Controls.Add($btnCredWarningSettings)
$btnCredWarningSettings.Add_Click({ Show-CertificateSetupDialog; Update-CredentialWarningBanner })
$tabCatalog.Controls.Add($Global:App.PanelCredWarning)

$Global:App.Grid = New-Object System.Windows.Forms.DataGridView
$Global:App.Grid.Dock = "Fill"
$Global:App.Grid.ReadOnly = $true
$Global:App.Grid.AllowUserToAddRows = $false
$Global:App.Grid.AllowUserToDeleteRows = $false
$Global:App.Grid.AllowUserToResizeRows = $false
$Global:App.Grid.SelectionMode = "FullRowSelect"
$Global:App.Grid.MultiSelect = $true
$Global:App.Grid.AutoGenerateColumns = $false
$Global:App.Grid.AutoSizeColumnsMode = "Fill"
$Global:App.Grid.RowHeadersVisible = $false
$Global:App.Grid.BackgroundColor = [System.Drawing.Color]::White


$Global:App.Grid.Columns.Add((New-GridColumn "AppName" "App Name" -FillWeight 16)) | Out-Null
$Global:App.Grid.Columns.Add((New-GridColumn "WingetId" "Winget ID" -FillWeight 10)) | Out-Null
$Global:App.Grid.Columns.Add((New-GridColumn "Type" "Type" -FillWeight 13)) | Out-Null
$Global:App.Grid.Columns.Add((New-GridColumn "Version" "Version" -FillWeight 4)) | Out-Null
$Global:App.Grid.Columns.Add((New-GridColumn "Uncommon" "Uncommon" -FillWeight 6)) | Out-Null
$Global:App.Grid.Columns.Add((New-GridColumn "CustomConfig" "Custom Config" -FillWeight 5)) | Out-Null
# Package folder holds full filesystem paths, which routinely run longer
# than every other column's content (including the App ID GUID) - by far
# the widest allotment here on purpose.
$Global:App.Grid.Columns.Add((New-GridColumn "Folder" "Package folder" -FillWeight 42)) | Out-Null
$Global:App.Grid.Columns.Add((New-GridColumn "Required" "Required" -FillWeight 4)) | Out-Null
$Global:App.Grid.Columns.Add((New-GridColumn "Available" "Available" -FillWeight 4)) | Out-Null
$Global:App.Grid.Columns.Add((New-GridColumn "Uninstall" "Uninstall" -FillWeight 4)) | Out-Null
$Global:App.Grid.Columns.Add((New-GridColumn "AppId" "App ID" -FillWeight 20)) | Out-Null
$Global:App.Grid.Columns.Add((New-GridColumn "Status" "Status" -FillWeight 8)) | Out-Null
$Global:App.Grid.Columns.Add((New-GridColumn "IntuneAudit" "Last Audit" -FillWeight 10)) | Out-Null

$Global:App.ColIndex = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$Global:App.ColIndex.Name = "Index"
$Global:App.ColIndex.DataPropertyName = "Index"
$Global:App.ColIndex.Visible = $false
$Global:App.Grid.Columns.Add($Global:App.ColIndex) | Out-Null

$tabCatalog.Controls.Add($Global:App.Grid)
$Global:App.Grid.BringToFront()

# Highlight the Status column when it's flagging something, so problems are
# visible at a glance across the whole catalog instead of only when you open
# each app individually.
$Global:App.Grid.Add_CellFormatting({
    param($gridSender, $e)
    $colName = $Global:App.Grid.Columns[$e.ColumnIndex].Name
    if ($colName -eq "Status") {
        if ($e.Value -and [string]$e.Value) {
            if ([string]$e.Value -eq "Metadata saved - ready to deploy") {
                # Good news, not a warning - distinct from the orange/bold
                # treatment below, which is reserved for things that actually
                # need attention (no App ID at all, a missing package).
                $e.CellStyle.ForeColor = [System.Drawing.Color]::SeaGreen
                $e.CellStyle.Font = New-Object System.Drawing.Font($Global:App.Grid.Font, [System.Drawing.FontStyle]::Bold)
            }
            elseif ([string]$e.Value -eq "Custom config") {
                # Informational, not a warning either - a Winget app with
                # deliberately customized install/detection/etc. isn't a
                # problem the way a missing package or App ID is, so it gets
                # its own neutral color rather than the same DarkOrange used
                # for things that actually need fixing. Only when this is the
                # WHOLE status text, though - composed with anything else
                # (e.g. "No App ID; Custom config") falls through to
                # the orange case below, since something else there DOES need
                # attention.
                $e.CellStyle.ForeColor = [System.Drawing.Color]::SteelBlue
                $e.CellStyle.Font = New-Object System.Drawing.Font($Global:App.Grid.Font, [System.Drawing.FontStyle]::Italic)
            }
            else {
                $e.CellStyle.ForeColor = [System.Drawing.Color]::DarkOrange
                $e.CellStyle.Font = New-Object System.Drawing.Font($Global:App.Grid.Font, [System.Drawing.FontStyle]::Bold)
            }
        }
    }
    elseif ($colName -eq "IntuneAudit") {
        # Same in-memory cache Get-LastAuditSummary reads from - never
        # persisted, so this is only ever as fresh as the last audit or
        # single-app fetch that happened to run THIS session (see
        # $Global:App.LastAuditResults's own comment for why).
        $val = [string]$e.Value
        if ($val -like "*issue*" -or $val -like "Check failed*") {
            $e.CellStyle.ForeColor = [System.Drawing.Color]::DarkOrange
            $e.CellStyle.Font = New-Object System.Drawing.Font($Global:App.Grid.Font, [System.Drawing.FontStyle]::Bold)
        }
        elseif ($val -like "OK (*") {
            $e.CellStyle.ForeColor = [System.Drawing.Color]::SeaGreen
        }
        elseif ($val -eq "Never audited") {
            $e.CellStyle.ForeColor = [System.Drawing.Color]::Gray
            $e.CellStyle.Font = New-Object System.Drawing.Font($Global:App.Grid.Font, [System.Drawing.FontStyle]::Italic)
        }
    }
})



# Plural counterpart, for the multi-select-aware operations (Batch Assign,
# Package all apps) - returns every currently selected row's catalog index,
# or an empty array if nothing's selected (their callers treat that as "no
# scoping, use everything" rather than an error).

# Fetches ONE app's full current object from Intune, for pre-filling Deploy
# to Intune's fields with what's actually live there in Update mode, rather
# than local guesses. Same runspace pattern as Start-IntuneAppLookup, just
# scoped to a single app and returning its parsed fields instead of a name
# list.

# Backfills intuneAppType/intuneAppVersion for every deployed app (has an
# App ID) that's never had them set - the main grid's own Type/Version
# columns, populated automatically instead of only ever getting filled in
# by "Pull metadata and groups from Intune..." or a Deploy/Update run happening to touch that
# app. Kicked off automatically once per catalog load (startup, Reload,
# Open other folder) rather than on every grid refresh - see the note
# next to $Global:App.TypeVersionBackfillDone for why. Same queue-runner
# pattern as every other bulk fetch in this app (one app's Graph call at
# a time, not all in flight at once), reusing Start-AppMetadataFetch
# since the network round-trip - not the parsing - is what actually
# costs anything, and that function already returns exactly the two
# fields needed (OdataType, DisplayVersion) alongside everything else it
# fetches for the same one GET request.

# Fetches a group's current members by name, for Group Manager's "current
# members" list. Same lightweight runspace pattern as Start-AppMetadataFetch
# - read-only, no need for the heavier child-process machinery the actual
# write operations (add/remove/delete) use.


# Direct-saves after a successful deploy, same as every other single,
# atomic catalog action this session - "Force save catalog" (the main toolbar
# button) is no longer a required step for this to actually persist.
# =====================================================================



# =====================================================================
# Create in Intune - helpers
# =====================================================================

# Saves a catalog-shaped (camelCase) metadata object into the local
# per-app catalog file - shared by both "Save for later..." and the
# Create/Update Metadata success handler within Show-CreateInIntuneDialog,
# so a real deploy persists locally exactly the same way an explicit
# "save for later" already does, rather than only updating Intune and
# leaving the local catalog file behind. Finds the existing entry by
# name (creating one if it doesn't exist yet), replaces the whole
# element rather than mutating a retrieved property (see the extensive
# comment on the identical pattern in the caller for why that
# specifically matters), optionally updates appId/appName at the same
# time (for a real Create, which now has a real App ID to record; left
# $null for "Save for later...", which never changes either), and saves
# to disk immediately. Returns $true/$false for whether the disk write
# itself succeeded - matching Save-AppsToFile's own return value.

# Compares two CATALOG-shaped metadata objects (the exact schema this app's
# own "metadata" field always uses - description/publisher/.../returnCodes,
# camelCase) field by field and returns every field that differs, as
# @{ Field; Local; Remote } (display strings). Used by Show-SyncMetadataDialog's
# bulk path so it can tell "nothing to reconcile" from "local actually
# differs from Intune" - the same question Show-CreateInIntuneDialog's own
# auto-fetch answers per app, just against a much simpler pair of inputs
# here: both sides are ALREADY catalog-shaped (Show-CreateInIntuneDialog's
# own diff, by contrast, has to translate Intune's raw Graph field names on
# the fly, which is why it isn't reused here as-is).
# $Local may be $null (nothing saved locally yet) - that's "nothing to
# compare against", not "every field differs", so it always returns empty.
# Single source of truth for the "simple" (plain-value) catalog metadata
# Relative-time formatting for the "Last Audit" column below - "how long
# ago" reads at a glance far better than a raw timestamp in a narrow grid
# cell.

# Loads $Global:App.LastAuditResults from its own cache file - never the
# per-app catalog files themselves, see $Global:App.LastAuditResults's own
# comment for why. Called once at startup. A missing or corrupt file is
# silently treated as "nothing cached yet", the same state this had
# before persistence existed at all - not worth a warning over.

# Writes $Global:App.LastAuditResults out as-is. Unlike Save-AppsToFile, this
# has none of that function's Git-diff-friendliness or hand-rolled JSON
# concerns (this cache is never meant to be hand-edited, diffed, or
# checked in), so a plain ConvertTo-Json is fine here. Called after every
# audit run/single-app check completes; a failed write is silently
# ignored - worst case the cache is one run behind on next launch, never
# a reason to interrupt or warn about an otherwise-successful check.

# Merges whichever of the four check results are passed in (any omitted -
# left as $null - keep whatever was cached before) into
# $Global:App.LastAuditResults for one app, stamping the current time. Called
# from both the single-app auto-fetch inside Show-CreateInIntuneDialog
# (Metadata/Dependencies only - it has no Groups/Unknown Assignments check
# of its own, see the note by its own Dependencies diff) and
# Show-IntuneAuditDialog's two background fetches (every field, as each
# fetch completes).

# Turns one app's cache entry (if any) into the main grid's "Last Audit"
# column text - "Never audited" with nothing cached, otherwise a summary
# of whether anything's actually wrong across whichever checks have run,
# plus how long ago. A field that's never been checked (still $null) is
# simply left out - this reports on what's KNOWN, not a false "all clear"
# for a check that just hasn't happened yet.

# The main grid's "Last Audit" column only ever has room for a one-line
# summary ("1 issue (5m ago)") - this is what double-clicking that cell
# shows instead, breaking it back out into which of the four checks
# actually found something, same field-by-field detail
# Show-IntuneAuditDialog's own double-click already gives you there.

# fields both Get-CatalogMetadataFieldDiffs and Merge-CatalogMetadata key
# off of, so the two stay in sync by construction - a field added to one
# but not the other would mean either a diff that's shown but can never
# actually be applied by the merge, or one silently applied that the diff
# UI never surfaced. Detection rule and return codes are handled by name,
# not through this list, in both functions - they're composite objects,
# not simple values.


# Builds a new catalog-shaped metadata object starting from $Remote
# (Intune's fetched value - the default winner everywhere else in this
# app), substituting the LOCAL value for any field whose Label is in
# $KeepLocalFields (the same Field values Get-CatalogMetadataFieldDiffs
# produces and Show-MetadataDriftDialog returns as its "keep local"
# picks). Used by bulk "Pull metadata and groups from Intune..." to actually apply a per-field
# reviewed choice for an app instead of either blindly taking Intune's
# value for everything or skipping the app outright.

# Compares an app's local requiredFor/availableFor/uninstallFor group-NAME
# lists against Intune's CURRENT live assignment group names for that same
# app (as fetched by the bulk "Pull metadata and groups from Intune..." embedded script, which
# resolves each assignment's groupId to its live displayName). That's the
# one signal in this app that survives a group rename in Entra ID - Assign
# Groups/Batch Assign both match by the catalog's stored NAME, so a rename
# there just looks like "group not found"; this instead follows the live
# Intune assignment's groupId, which doesn't change on a rename. Kept as
# its own function rather than folded into Get-CatalogMetadataFieldDiffs -
# these three fields live directly on the app object, not under
# App.metadata, and are lists compared by membership, not scalars compared
# by string equality.
# Order-insensitive: only an actual membership difference counts, not a
# re-ordering of the same names.

# "Uncommon" is derived, not a separately-stored field: an app with a
# Winget ID gets installed via the shared winget wrapper package, so it's
# "common"; an app with no Winget ID needs its own individually-packaged
# .intunewin, so it's "uncommon". One source of truth, everywhere - no
# checkbox to fall out of sync with the actual Winget ID field.

# Maps an Intune app's raw @odata.type to the same friendly label the
# Intune admin center's own "Type" column shows for it - the ONE place
# this mapping lives (embedded child-process scripts that fetch an app's
# raw type hand it back unmapped, specifically so it isn't duplicated
# into every one of them separately). Deliberately only covers the types
# most likely to actually show up in a Windows-app-focused catalog like
# this one's; an unmapped type falls back to a readable derived label
# (e.g. "androidStoreApp" -> "Android Store App") rather than guessing at
# wrong portal wording for something rare here.

# Parses a raw minimumSupportedWindowsRelease value into its Windows major
# version (10/11) and release token (e.g. "21H2") - genuinely necessary,
# not cosmetic: THREE different raw spellings for the exact same property
# have been observed live across different apps/tenants so far -
# "W11_21H2" (the IntuneWin32App module's own convention), "Windows11_21H2"
# (set directly via the Intune portal), and a bare "21H1" with no major-
# version marker at all. Every caller that needs to compare or display
# this value goes through here so a fourth spelling only needs handling
# in one place.

# Human-readable label for a raw minimumSupportedWindowsRelease value,
# matching the Intune portal's own "Windows 11 21H2" style wording (see
# Get-ParsedMinOsRelease just above for why this needs real parsing, not
# a straight display of whatever Graph handed back).

# Mirrors Get-SafeFileName inside the embedded package script exactly, so we
# can predict what filename that script's own logic gave an uncommon app's
# .intunewin without having to run/parse it.

# Returns @{ Path = <string or $null>; Found = [bool] } - the predicted/found
# package path for an app, given its name and uncommon flag.

# Iterative topological sort (Kahn's algorithm), not recursion - deliberately
# avoids any question about how a self-recursive nested function would
# behave, given a DIFFERENT kind of self-reference bug already surfaced once
# this session (a .GetNewClosure()-wrapped scriptblock capturing itself
# before its own assignment completed). A plain, flat loop over lists and
# hashtables sidesteps that class of question entirely. Verified separately
# against five cases (a chain, independent apps, a diamond, a genuine cycle,
# and a dependency pointing outside the batch) before being written here.

# =====================================================================
# Dependency overview
# =====================================================================
# Read-only, whole-catalog report: every app, what it depends on, and what
# depends on IT (the reverse direction - dependencies are only ever stored
# on the dependent app's own metadata.dependencies, by name, so "what
# needs THIS app" isn't visible anywhere else without checking every other
# app's list by hand). Flags two real problems inline, reusing
# Get-DependencyOrderedApps against the WHOLE catalog rather than
# reimplementing cycle detection separately:
#   - Circular: this app is part of a dependency cycle - Batch Deploy can
#     never fully order it (see Get-DependencyOrderedApps's own handling).
#   - Missing: this app depends on a name that isn't in the catalog at all
#     (typo, or the dependency was renamed/removed) - Batch Deploy will
#     just skip a dependency like that silently at ordering time, so this
#     is the only place that actually surfaces it.
# Entirely local - no Graph calls, no background process, just reads
# $Global:App.Apps directly - so unlike almost every other "Check..." dialog
# in this app, this one needs no Refresh button or async plumbing at all.

# Default install/uninstall/detection templates. Only pre-filled for
# non-uncommon (winget) apps, where there's an actual established convention
# to draw from - uncommon apps get a generic Machine-scope command pattern for
# install/uninstall (matching what the embedded package script's own printed
# deployment guide recommends) and no detection default, since that's
# genuinely per-app.

# Computes the SAME default values Show-CreateInIntuneDialog's own form
# pre-fills for a brand-new (non-duplicate, non-Update) app, as one
# catalog-shaped metadata object - every default here (besides
# install/uninstall/detection templates, which are always derived per-app
# from the Winget ID) comes from $Global:App.DefaultAppSettings, editable via
# "Edit default values..." rather than hardcoded, so Batch Deploy can use
# the SAME (possibly customized) defaults for an app that was never
# manually walked through "Save for later..." instead of just skipping
# it.
#
# Detection is the one field that can't always be defaulted: for an
# UNCOMMON app there's no real install to derive a detection script from
# (same reason the single-app dialog itself leaves it blank and requires
# something be typed in before Save/Create can proceed there too) -
# .detectionRule comes back $null in that case, and callers must check
# for that themselves before treating the result as actually deployable.

# ---------------------------------------------------------------
# Edit default values dialog
# ---------------------------------------------------------------
# Lets $Global:App.DefaultAppSettings itself be edited - the values
# Get-DefaultAppMetadata hands out for every Winget app that doesn't
# override them. Same field set and controls as the "Advanced" section of
# Show-CreateInIntuneDialog (architecture, install context, min OS,
# requirements, install time, restart behavior, allow-uninstall, return
# codes, default dependency), just for the GLOBAL defaults instead of one
# app's saved metadata - install/uninstall/detection templates aren't
# here at all, since those are always derived per-app from the Winget ID,
# never a fixed default.

# Drives the main grid's "Custom Config" column - "Yes" means this app
# WON'T just deploy with Get-DefaultAppMetadata's plain defaults, so
# whoever's scanning the catalog knows which apps need a closer look
# before a batch action touches them, rather than only finding out at
# actual deploy time. An uncommon app (no Winget ID) is unconditionally
# "Yes" - there's no shared default for a custom install to compare
# against at all, everything about it is inherently app-specific. A
# Winget app with no saved metadata at all is "No" - Batch Deploy (or a
# manual Deploy to Intune) would default it, and defaulted is not
# customized. Otherwise, reuses Get-CatalogMetadataFieldDiffs - same
# field-by-field comparison already proven for the Local-vs-Intune drift
# dialog - just pointed at "saved metadata" vs "computed defaults"
# instead of "local" vs "live Intune".

# ---------------------------------------------------------------
# Local vs. Intune metadata drift compare dialog
# ---------------------------------------------------------------
# Shown from inside Show-CreateInIntuneDialog's auto-fetch, right after it
# finds fields that differ between what's saved locally and what's actually
# live in Intune right now. By the time this shows, every field in that
# dialog already holds Intune's value - Intune stays the default winner for
# every row here too (an unticked box is the only way a row changes), so
# this only ADDS visibility and a per-field opt-out; it never changes what
# happens if nobody looks at it before it's dismissed.
#
# -Rows is an array of @{ Field; Local; Intune } (all plain display strings
# - no live control references or scriptblocks in here, deliberately, so
# this dialog stays a simple, self-contained compare/pick UI with nothing
# that needs closure-capture care). Returns an array of Field values (a
# subset of $Rows.Field) for the rows whose "Use Intune's value" box ended
# up UNCHECKED - i.e. the fields the caller should revert back to the local
# value. An empty array (every box left checked, or Cancel) means the
# caller should leave every field exactly as the auto-fetch already set it.

# Read-only, resizable "these N things are about to change - proceed?"
# confirmation, used by Show-CreateInIntuneDialog's "Set default values..."
# button. A plain MessageBox can't scroll or resize, so a longer change
# list (many requirements/return codes differing at once) just got cut off
# or ran off the bottom of the screen - this is a real dialog instead, with
# a proper scrollable, word-wrapped list.

# ---------------------------------------------------------------
# Create in Intune dialog
# ---------------------------------------------------------------
# Builds a new Win32 app in Intune (or updates an existing one's metadata) from
# a catalog entry. Returns the resulting App ID string on success, or $null if
# cancelled/failed - the caller (Show-AppEditor) is responsible for putting
# that into its own App ID field and saving, same as the "Look up" button.

# ---------------------------------------------------------------
# Targeted (single-app) group creation + assignment dialog
# ---------------------------------------------------------------
# Lighter alternative to running the full bulk Assign step just to wire up
# one app: ensures the Entra ID groups this app's requiredFor/availableFor/
# uninstallFor reference exist, then sets ONLY this app's Intune assignments
# to match. Does not touch group membership or any other app.

# =====================================================================
# Apps in Intune not in this catalog
# =====================================================================
# Fetches every app currently in Intune and compares it against this
# catalog by App ID and by name, flagging two different kinds of drift:
#   - "Not in catalog": an Intune app with no matching catalog entry at all
#     (created directly in the portal, or removed from input.json but never
#     cleaned up in Intune).
#   - "Renamed in Intune": a catalog app whose App ID DOES match an Intune
#     app, but that Intune app's current display name no longer matches
#     what's saved in the catalog (renamed directly in the portal since).
# Offers a fix for each: add the missing one to the catalog, or pull
# Intune's current name into the catalog entry for a renamed one.
# =====================================================================
# Batch assign groups dialog
# =====================================================================
# Runs the same group-assignment logic as the per-app "Assign Groups to
# Intune" button, but across every app in the catalog that has an App ID
# and at least one group set - with a mandatory read-only preview step
# first. Nothing is changed in Intune until you explicitly click Apply
# after reviewing what would happen.


# ---------------------------------------------------------------
# Batch edit Intune fields
# ---------------------------------------------------------------
# Changes one or more win32LobApp fields (architecture, min OS,
# requirements, restart behavior, allow-uninstall, return codes,
# dependencies) across multiple ALREADY-DEPLOYED Win32 apps at once, then
# pushes each one straight to Intune - e.g. "raise the minimum Windows
# release for every app that currently requires 21H2". Deliberately does
# NOT offer install/uninstall commands or the detection rule here, unlike
# "Set default values..." - those are inherently per-app (a literal script
# path or detection script text), and setting the SAME literal value
# across several different apps would silently break them, not update
# them the way changing a shared field like Min OS safely can.
# Reuses $Global:App.EmbeddedCreateAppScript's "UpdateMetadata" mode (the same
# one Show-CreateInIntuneDialog's own "Update Metadata" button uses for a
# single app), one app at a time via the same self-referencing queue-runner
# pattern Show-BatchDeployDialog already uses - see its own $RunNextBox
# comment for why a plain self-referencing scriptblock doesn't work here.


# Bulk-REMOVES one or more groups from however many catalog apps are
# checked - the "unassign" counterpart to Show-AddFavoriteGroupToAppsDialog
# just below, with the SAME three-CheckedListBox-per-intent layout (see
# New-FavoriteGroupBox there) rather than one combined list: a group can be
# Required for one app and merely Available for another, and removal needs
# to target one specific bucket at a time just like adding does - checking
# a group under "Required for" only removes it from THAT field, leaving it
# untouched if it's also (separately) checked under Available/Uninstall
# for that same app. Unlike the Add dialog, this isn't favorites-only - it
# lists every group actually referenced in each bucket across
# $CandidateApps, since the whole point here is unassigning something
# that's already there, favorite or not.
# Purely a catalog-side edit, same division of labor as the Add dialog:
# this only removes the group NAME from the local catalog and saves: it
# does not touch Intune. Pushing the removal to Intune is still "Batch
# assign groups..."'s job - its Apply step already removes any live
# assignment that's no longer in the catalog's current group set, so
# running Preview/Apply right after this is what actually unassigns it.
# Returns the number of apps actually changed, or $null if cancelled.

# Bulk-adds ONE favorite group, at one intent (Required/Available/
# Uninstall), to however many catalog apps are checked - the piece
# "Push groups to Intune (multiple apps)..." itself never had: that
# dialog only ever RECONCILES groups an app already has set against
# what's live in Intune, with no way to add a group to several apps that
# don't have it yet without opening each one's own editor individually.
# Purely a catalog-side edit (adds to requiredFor/availableFor/
# uninstallFor and saves) - pushing the result to Intune is still
# "Push groups to Intune (multiple apps)..."'s job, same as any other
# catalog-side group change.
# Returns the number of apps actually changed (apps that already had
# this exact group+intent are left alone, not counted), or $null if
# cancelled.


# ---------------------------------------------------------------
# Diagnostics - read-only health check
# ---------------------------------------------------------------
# Reads only. Never writes to Intune, Entra ID, or the local catalog -
# this exists so "is anything actually wrong right now" can be answered
# without any of the risk every other Graph-facing dialog in this app
# carries. Split into two phases: LOCAL checks (config file shape,
# catalog completeness) that run instantly with no network at all, then
# LIVE checks (one Graph connectivity test, one bulk app list) that only
# run if credentials are configured - a missing/broken Graph setup
# doesn't block the local half of the report.


# ---------------------------------------------------------------
# Delete app from Intune dialog
# ---------------------------------------------------------------
# Deletes an app from Intune entirely - irreversible. Deliberately kept
# separate from the catalog: deleting from Intune does not remove the
# catalog entry, it just clears its App ID on success (since the ID no
# longer refers to anything), so the app can be recreated later without
# losing its group assignments/metadata already saved in input.json.

# ---------------------------------------------------------------
# Bulk delete from Intune
# ---------------------------------------------------------------
# Same permanent, irreversible Intune deletion Show-DeleteAppDialog does for
# one app, run across every checked app here in sequence - same
# self-referencing queue-runner pattern as Show-BatchDeployDialog's own
# $RunNextBox, reusing $Global:App.EmbeddedDeleteAppScript completely unchanged,
# one app at a time. Deliberately NOT taught to accept a whole batch in one
# process invocation the way the (read-only, much lower-stakes) sync-
# metadata script is - that script's dependency-block detection and
# interactive "remove the blocking dependency and retry?" prompt is exactly
# the kind of per-app judgment call that has no sane unattended answer
# across many apps at once. A dependency-blocked app here is simply
# reported as a failure with a pointer to the single-app dialog, which
# still offers that interactive retry.

# =====================================================================
# =====================================================================
# Group name drift check
# =====================================================================
# Unlike the app "Renamed in Intune" check, there's no Entra ID group Object
# ID stored anywhere in the catalog - only the group NAME (in requiredFor /
# availableFor / uninstallFor). That means an actual rename can't be traced
# back HERE the way an app rename can; all this dialog can honestly tell you
# is "this name isn't found in Entra ID right now" - could be a rename, a
# deletion, a typo, or a group that was simply never created yet.
# Deliberately informational only (no auto-fix button here) - Batch Assign /
# Assign Groups already auto-create a missing group when you actually apply
# assignments, and doing that automatically FROM this check too would risk
# silently creating a throwaway duplicate for what's actually a typo or a
# rename, which is exactly the mistake this check exists to catch before it
# happens.
#
# For an app that already has assignments live in Intune, "Pull metadata and groups from Intune..."
# (Show-SyncMetadataDialog) IS rename-safe: it reads that app's group names
# back from its live assignments by groupId, which survives a rename, and
# offers to update the catalog's stored name to match. So if this dialog
# flags a name as "Not found" and it's actually a rename, the fix is: run
# "Pull metadata and groups from Intune..." for the app(s) that reference it (this updates the
# stored name straight from Intune), not to hand-edit the name here.

# =====================================================================
# Intune Audit - the one place that checks a deployed app against what's
# actually live in Intune, across every dimension this app used to spread
# across separate dialogs: Metadata (installer/detection/requirements
# fields), Groups (Required/Available/Uninstall bucket membership),
# Dependencies, and Unknown Assignments (a live Intune assignment the
# catalog has never recorded). One grid, one row per deployed app, one
# "Run audit" click.
#
# Deliberately does NOT also fold in the group-NAME-vs-Entra-ID check
# (Show-GroupDriftCheckDialog) - that one is fundamentally group-centric
# (one row per group name, "which apps reference this"), not app-centric,
# and answers a different question ("does this group still exist at all")
# than everything else here ("does this app's catalog entry match what
# Intune has"). Forcing it into a per-app row here would either lose that
# grouping or need a second, differently-shaped grid bolted onto this one
# - not worth it for one more column. It stays its own focused tool.
# Show-SyncMetadataDialog also stays separate - this dialog only ever
# REPORTS drift, it never applies anything; pulling a finding into the
# catalog is still that dialog's job.
#
# Two independent background fetches power this, both reused as-is rather
# than duplicated: $Global:App.EmbeddedSyncMetadataScript (same one
# Show-SyncMetadataDialog and Show-CreateInIntuneDialog's own auto-fetch
# use) covers Metadata, Groups, AND Dependencies in one pass - dependency
# names already ride along in its per-app Metadata.dependencies, so
# checking them here costs nothing extra. $Global:App.EmbeddedBatchAssignScript
# in "Preview" mode (same one Show-BatchAssignDialog uses to show what an
# Apply would do) covers Unknown Assignments - a different live-vs-catalog
# diff (it also considers assignment INTENT, not just group presence) that
# the sync script doesn't compute. Both run concurrently, each filling in
# its own columns as it completes, rather than making someone wait through
# two sequential fetches for one combined view.

# Favorite groups manager
# =====================================================================
# Lets someone mark specific groups as "favorites" - these are what show
# up as ready-to-tick options in every app's Required/Available/
# Uninstall lists from now on (new and existing apps alike), instead of
# those lists defaulting to every group ever used anywhere in the whole
# catalog. "+ New group..." within each app's own lists (see
# New-GroupBox) remains the way to reach any OTHER group not marked a
# favorite - this dialog only manages which ones get that default,
# always-visible treatment.

# Group manager dialog
# =====================================================================
# Small, standalone tool: create a security group (or reuse one that
# already exists by that exact name - idempotent, same as the group
# handling in Assign Groups) and add users or other groups to it as
# members. Not tied to the app catalog at all - useful for setting up a
# deployment group before any app references it.

# ---------------------------------------------------------------
# App editor dialog
# ---------------------------------------------------------------

$btnNew.Add_Click({
    $editorResult = Show-AppEditor -ExistingApp $null
    if ($editorResult) {
        $newApp = $editorResult.App
        [void]$Global:App.Apps.Add($newApp)
        $Global:App.UnsavedChangesBox.Value = $true
        # Direct-save, not just staged in memory - same reasoning as every
        # other single, atomic action made direct-save this session:
        # adding one app is a complete action in itself, with no batching
        # benefit to be had from deferring the write to a separate click.
        [void](Save-AppsToFile -Path $Global:App.LinkedFilePath)
        Update-Grid
        if ($editorResult.DeployAfterSave) {
            $newIndex = -1
            for ($ni = 0; $ni -lt $Global:App.Apps.Count; $ni++) {
                if ($Global:App.Apps[$ni].appName -eq $newApp.appName) { $newIndex = $ni; break }
            }
            if ($newIndex -ge 0) { Show-BatchDeployDialog -ScopedIndices @($newIndex) }
        }
    }
})

$btnEdit.Add_Click({
    $i = Get-SelectedAppIndex
    if ($null -eq $i) {
        [System.Windows.Forms.MessageBox]::Show("Select an app first.", "No selection", "OK", "Information") | Out-Null
        return
    }
    $editorResult = Show-AppEditor -ExistingApp $Global:App.Apps[$i] -CurrentIndex $i
    if ($editorResult) {
        $updated = $editorResult.App
        # Not necessarily $i anymore - Previous/Next inside the editor can
        # navigate to (and save) a DIFFERENT app before finally returning
        # here, and Show-AppEditor's own result always carries the index
        # of whichever app it actually last saved (see its own comment
        # next to this Index field). Falling back to $i covers older
        # in-memory result shapes/callers that never set it.
        $targetIndex = if ($null -ne $editorResult.Index -and $editorResult.Index -ge 0) { $editorResult.Index } else { $i }
        $Global:App.Apps[$targetIndex] = $updated
        $Global:App.UnsavedChangesBox.Value = $true
        [void](Save-AppsToFile -Path $Global:App.LinkedFilePath)
        Update-Grid
        if ($editorResult.DeployAfterSave) { Show-BatchDeployDialog -ScopedIndices @($targetIndex) }
    }
})

# The "Last Audit" column only has room for a one-line summary ("1 issue
# (5m ago)") - double-clicking it shows the full per-check breakdown
# instead of opening the editor, same as every other cell here does.
$Global:App.Grid.Add_CellDoubleClick({
    param($gridSender, $e)
    if ($e.RowIndex -lt 0) { return }
    if ($Global:App.Grid.Columns[$e.ColumnIndex].Name -eq "IntuneAudit") {
        $clickedAppName = [string]$Global:App.Grid.Rows[$e.RowIndex].Cells["AppName"].Value
        Show-LastAuditDetail -AppName $clickedAppName
        return
    }
    $btnEdit.PerformClick()
})

# Right-click context menu - lets Deploy/Assign/Delete happen straight from
# the grid instead of always requiring a trip through the full editor first.
$gridContextMenu = New-Object System.Windows.Forms.ContextMenuStrip
$menuItemEdit = New-Object System.Windows.Forms.ToolStripMenuItem "Edit..."
$menuItemDeploy = New-Object System.Windows.Forms.ToolStripMenuItem "Deploy to Intune..."
$menuItemPackage = New-Object System.Windows.Forms.ToolStripMenuItem "Package this app for Intune"
$menuItemAssign = New-Object System.Windows.Forms.ToolStripMenuItem "Push groups to Intune (single app)..."
# Already selection-aware via -ScopedIndices, same as the toolbar button
# it reuses - was reachable only from there before, requiring a
# pre-selection made before ever opening the toolbar dialog, when a
# right-click on the row(s) in question is the more natural way in.
$menuItemSyncMetadata = New-Object System.Windows.Forms.ToolStripMenuItem "Pull metadata and groups from Intune..."
# Same eligibility/scoping as $menuItemSyncMetadata right above - an app
# needs an App ID before there's anything in Intune to audit against.
# Reuses Show-IntuneAuditDialog's own -ScopedIndices (added specifically
# for this), same as every other selection-aware item here.
$menuItemAudit = New-Object System.Windows.Forms.ToolStripMenuItem "Run audit..."
$menuItemDeleteIntune = New-Object System.Windows.Forms.ToolStripMenuItem "Delete from Intune..."
$menuItemSeparator = New-Object System.Windows.Forms.ToolStripSeparator
$menuItemRemoveCatalog = New-Object System.Windows.Forms.ToolStripMenuItem "Remove from catalog..."
[void]$gridContextMenu.Items.Add($menuItemEdit)
[void]$gridContextMenu.Items.Add($menuItemDeploy)
[void]$gridContextMenu.Items.Add($menuItemPackage)
[void]$gridContextMenu.Items.Add($menuItemAssign)
[void]$gridContextMenu.Items.Add($menuItemSyncMetadata)
[void]$gridContextMenu.Items.Add($menuItemAudit)
[void]$gridContextMenu.Items.Add($menuItemDeleteIntune)
[void]$gridContextMenu.Items.Add($menuItemSeparator)
[void]$gridContextMenu.Items.Add($menuItemRemoveCatalog)
$Global:App.Grid.ContextMenuStrip = $gridContextMenu

# Right-clicking empty grid space (below the last row, or before anything's
# ever been selected) still shows this same menu, since it's bound to the
# whole grid control - without this, clicking any item then would silently
# do nothing, with zero feedback about why. Graying them out up front is the
# standard convention instead of a silent no-op after the click.
#
# With multiple rows selected, every item here used to silently act on only
# the FIRST selected row (Get-SelectedAppIndex, singular) with zero
# indication that the rest of the selection was simply ignored - a real
# trap, not just a missing feature. Each item now does one of two things
# instead: genuinely act on the whole selection (Delete from Intune...,
# Remove from catalog... already did via $Global:App.BtnDelete; Assign Groups... and
# Package this app now do too, the latter two by reusing the exact same
# batch features already on the toolbar), or - for Edit... and Deploy to
# Intune..., which open a single interactive per-app form and have no sane
# multi-app equivalent - grey out and say why, rather than quietly editing
# just whichever row happened to be selected first.
$gridContextMenu.Add_Opening({
    $selectedIndices = Get-SelectedAppIndices
    $hasSelection = $selectedIndices.Count -gt 0
    $isMulti = $selectedIndices.Count -gt 1

    $menuItemEdit.Enabled = $hasSelection -and -not $isMulti
    $menuItemEdit.ToolTipText = if ($isMulti) { "Select just one app to edit." } else { "" }

    # Single selection still opens the full interactive per-app dialog
    # (there's no sane multi-app equivalent for that); multiple selected
    # routes to Batch Deploy instead of graying out, same as Assign
    # Groups... below - Batch Deploy already handles "no saved metadata"
    # apps with sensible defaults, so there's no real reason multi-select
    # can't reach it directly from here too.
    $menuItemDeploy.Text = if ($isMulti) { "Batch deploy..." } else { "Deploy to Intune..." }
    $menuItemDeploy.Enabled = $hasSelection
    $menuItemDeploy.ToolTipText = ""

    $menuItemAssign.Text = if ($isMulti) { "Push groups to Intune (multiple apps)..." } else { "Push groups to Intune (single app)..." }
    $menuItemAssign.Enabled = $hasSelection

    # Same eligibility Show-SyncMetadataDialog itself checks (an app needs
    # an App ID before there's anything in Intune to pull metadata FROM) -
    # checked here too so this greys out up front instead of only showing
    # "nothing to do" after the click.
    $menuItemSyncMetadata.Enabled = $hasSelection -and (@($selectedIndices | ForEach-Object { $Global:App.Apps[$_] } | Where-Object { $_.appId }).Count -gt 0)

    $menuItemAudit.Text = if ($isMulti) { "Audit $($selectedIndices.Count) app(s)..." } else { "Run audit..." }
    $menuItemAudit.Enabled = $hasSelection -and (@($selectedIndices | ForEach-Object { $Global:App.Apps[$_] } | Where-Object { $_.appId }).Count -gt 0)

    $menuItemDeleteIntune.Text = if ($isMulti) { "Delete $($selectedIndices.Count) app(s) from Intune..." } else { "Delete from Intune..." }
    $menuItemDeleteIntune.Enabled = $hasSelection

    $menuItemRemoveCatalog.Text = if ($isMulti) { "Remove $($selectedIndices.Count) app(s) from catalog..." } else { "Remove from catalog..." }
    $menuItemRemoveCatalog.Enabled = $hasSelection

    # Only uncommon apps (no Winget ID) have their own package folder to
    # build - common apps share the one generic init.intunewin, so there's
    # nothing for this action to do for them. With multiple selected, at
    # least one being uncommon is enough to enable it - Invoke-LaunchStep
    # (via Package apps... on the toolbar) already silently skips common
    # apps in a -FolderNames batch on its own.
    $menuItemPackage.Text = if ($isMulti) { "Package $($selectedIndices.Count) app(s) for Intune" } else { "Package this app for Intune" }
    $menuItemPackage.Enabled = $hasSelection -and (@($selectedIndices | ForEach-Object { $Global:App.Apps[$_] } | Where-Object { Test-AppIsUncommon -App $_ }).Count -gt 0)
})

# Right-click selects the row under the cursor first, standard convention -
# otherwise the menu would act on whatever was already selected, which is
# confusing if that's a different row than the one just right-clicked. Only
# when that row isn't ALREADY part of the current selection - ctrl/shift
# right-clicking to extend a multi-selection before opening the menu (the
# same thing left-click already lets you do) would otherwise be undone by
# this collapsing it back down to one row first.
$Global:App.Grid.Add_CellMouseDown({
    param($gridSender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right -and $e.RowIndex -ge 0) {
        if (-not $Global:App.Grid.Rows[$e.RowIndex].Selected) {
            $Global:App.Grid.ClearSelection()
            $Global:App.Grid.Rows[$e.RowIndex].Selected = $true
        }
    }
})

$menuItemEdit.Add_Click({ $btnEdit.PerformClick() })
$menuItemRemoveCatalog.Add_Click({ $Global:App.BtnDelete.PerformClick() })

$menuItemDeploy.Add_Click({
    $indices = Get-SelectedAppIndices
    if ($indices.Count -eq 0) { return }
    if ($indices.Count -eq 1) {
        Invoke-QuickDeploy -Index $indices[0]
        return
    }
    Show-BatchDeployDialog -ScopedIndices $indices
})

$menuItemPackage.Add_Click({
    $indices = Get-SelectedAppIndices
    if ($indices.Count -eq 0) { return }
    if ($indices.Count -eq 1) {
        $app = $Global:App.Apps[$indices[0]]
        Show-PackagingProgressDialog -SingleFolderName (Get-SafeFileNameForApp -Name $app.appName)
        return
    }
    $uncommonApps = @($indices | ForEach-Object { $Global:App.Apps[$_] } | Where-Object { Test-AppIsUncommon -App $_ })
    $folderNames = @($uncommonApps | ForEach-Object { Get-SafeFileNameForApp -Name $_.appName })
    Show-PackagingProgressDialog -FolderNames $folderNames
})

$menuItemAssign.Add_Click({
    $indices = Get-SelectedAppIndices
    if ($indices.Count -eq 0) { return }
    if ($indices.Count -eq 1) {
        Invoke-QuickAssignGroups -Index $indices[0]
        return
    }
    Show-BatchAssignDialog -ScopedIndices $indices
    Update-Grid
})

$menuItemSyncMetadata.Add_Click({
    $indices = Get-SelectedAppIndices
    if ($indices.Count -eq 0) { return }
    Show-SyncMetadataDialog -ScopedIndices $indices
    Update-Grid
})

$menuItemAudit.Add_Click({
    $indices = Get-SelectedAppIndices
    if ($indices.Count -eq 0) { return }
    Show-IntuneAuditDialog -ScopedIndices $indices
    Update-Grid
})

$menuItemDeleteIntune.Add_Click({
    $indices = Get-SelectedAppIndices
    if ($indices.Count -eq 0) { return }
    if ($indices.Count -eq 1) {
        Invoke-QuickDeleteFromIntune -Index $indices[0]
        return
    }
    if (Show-BulkDeleteFromIntuneDialog -Indices $indices) { Update-Grid }
})

$Global:App.BtnDelete.Add_Click({
    $indices = Get-SelectedAppIndices
    if ($indices.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Select an app first.", "No selection", "OK", "Information") | Out-Null
        return
    }
    if ($indices.Count -eq 1) {
        $name = $Global:App.Apps[$indices[0]].appName
        $r = [System.Windows.Forms.MessageBox]::Show("Delete '$name' from the catalog?", "Confirm delete", "YesNo", "Warning")
    }
    else {
        $names = @($indices | Sort-Object | ForEach-Object { $Global:App.Apps[$_].appName }) -join ", "
        $r = [System.Windows.Forms.MessageBox]::Show("Delete $($indices.Count) apps from the catalog?`n`n$names", "Confirm delete", "YesNo", "Warning")
    }
    if ($r -eq "Yes") {
        # Highest index first - removing from an ArrayList by index shifts
        # every later index down by one, so removing low-to-high would
        # invalidate the remaining queued indices partway through.
        foreach ($idx in ($indices | Sort-Object -Descending)) {
            $Global:App.Apps.RemoveAt($idx)
        }
        $Global:App.UnsavedChangesBox.Value = $true
        # Direct-save, not just staged in memory - matters even more here
        # than for most other actions, given the per-app file structure:
        # without this, a deleted app's own file would still sit on disk
        # untouched, and the app would silently reappear the next time the
        # catalog gets reloaded without an explicit save having happened
        # first.
        [void](Save-AppsToFile -Path $Global:App.LinkedFilePath)
        Update-Grid
    }
})

$Global:App.BtnSave.Add_Click({
    if (Save-AppsToFile -Path $Global:App.LinkedFilePath) {
        Update-Grid
        Set-Status "Saved $($Global:App.Apps.Count) app(s) to $($Global:App.LinkedFilePath)"
    }
})

# Ctrl+S saves the catalog when on the App Catalog tab - matches every other
# app's save shortcut. $Global:App.Form.KeyPreview lets the form see key presses before
# whatever control currently has focus does.
$Global:App.Form.KeyPreview = $true
$Global:App.Form.Add_KeyDown({
    if ($tabs.SelectedTab -ne $tabCatalog) { return }
    if ($_.Control -and $_.KeyCode -eq [System.Windows.Forms.Keys]::S) {
        $Global:App.BtnSave.PerformClick()
        $_.SuppressKeyPress = $true
        return
    }
    if ($_.Control -and $_.KeyCode -eq [System.Windows.Forms.Keys]::N) {
        $btnNew.PerformClick()
        $_.SuppressKeyPress = $true
        return
    }
    # Enter/Delete only act on the grid when the GRID itself has focus, so
    # they don't fire while typing in the search box or anywhere else on
    # this tab - Delete in particular removes an app from the catalog and
    # shouldn't be reachable from an unrelated control by accident.
    if ($Global:App.Grid.Focused -and $_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
        $btnEdit.PerformClick()
        $_.SuppressKeyPress = $true
        return
    }
    if ($Global:App.Grid.Focused -and $_.KeyCode -eq [System.Windows.Forms.Keys]::Delete) {
        $Global:App.BtnDelete.PerformClick()
        $_.SuppressKeyPress = $true
        return
    }
})

$btnReload.Add_Click({
    if ($Global:App.UnsavedChangesBox.Value) {
        $r = [System.Windows.Forms.MessageBox]::Show("Discard unsaved changes and reload from disk?", "Reload", "YesNo", "Warning")
        if ($r -ne "Yes") { return }
    }
    Import-AppsFromFile -Path $Global:App.LinkedFilePath
    Update-Grid
    Start-TypeVersionBackfill
})

$btnOpen.Add_Click({
    # FolderBrowserDialog now, not OpenFileDialog - the catalog is a
    # FOLDER of per-app files, not a single input.json to pick.
    $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
    $fbd.Description = "Select the folder containing per-app JSON files"
    $fbd.SelectedPath = $Global:App.RootPath
    if ($fbd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $Global:App.LinkedFilePath = $fbd.SelectedPath
        Import-AppsFromFile -Path $Global:App.LinkedFilePath
        Update-Grid
        Start-TypeVersionBackfill
    }
})

$Global:App.BtnLookupIds.Add_Click({
    Start-IntuneAppLookup -OnComplete {
        param($ok, $data)
        if ($ok) {
            Show-AppIdMatchDialog
        }
        else {
            [System.Windows.Forms.MessageBox]::Show("Could not fetch apps from Intune:`n`n$data", "Lookup failed", "OK", "Error") | Out-Null
        }
    }.GetNewClosure()
})

$btnCertSetup.Add_Click({ Show-CertificateSetupDialog; Update-CredentialWarningBanner })
$btnDefaultValues.Add_Click({ Show-DefaultAppSettingsDialog })
$btnDiagnostics.Add_Click({ Show-DiagnosticsDialog })
$btnCheckIntuneOnly.Add_Click({
    $changed = Show-IntuneOnlyAppsDialog
    if ($changed) { Update-Grid }
})

$btnBatchAssign.Add_Click({
    $selectedIndices = Get-SelectedAppIndices
    Show-BatchAssignDialog -ScopedIndices $selectedIndices
    # "+ Add favorite group..." inside this dialog writes straight to
    # disk (same as every other bulk action) and changes the main
    # grid's own Required/Available/Uninstall counts - same reasoning
    # as the identical fix just made for Sync metadata.
    Update-Grid
})
$btnSyncMetadata.Add_Click({
    $selectedIndices = Get-SelectedAppIndices
    Show-SyncMetadataDialog -ScopedIndices $selectedIndices
    # Same reasoning as every other bulk action this session (Batch
    # Deploy, Bulk Delete) - a sync run can change appName/Type/Version/
    # metadata directly on disk while this dialog is open, so the main
    # grid is stale the moment it closes regardless of how it was
    # closed (Close button vs. the window's own X).
    Update-Grid
})
$btnBatchEdit.Add_Click({
    $selectedIndices = Get-SelectedAppIndices
    Show-BatchEditMetadataDialog -ScopedIndices $selectedIndices
    Update-Grid
})
$btnBatchDeploy.Add_Click({
    $selectedIndices = Get-SelectedAppIndices
    Show-BatchDeployDialog -ScopedIndices $selectedIndices
})
$btnGroupManager.Add_Click({ Show-GroupManagerDialog })
$btnFavoriteGroups.Add_Click({ Show-FavoriteGroupsManager })
$btnGroupDrift.Add_Click({ Show-GroupDriftCheckDialog })
$btnDependencies.Add_Click({ Show-DependencyOverviewDialog })
$btnIntuneAudit.Add_Click({ Show-IntuneAuditDialog; Update-Grid })

$Global:App.TxtSearch.Add_TextChanged({ Update-Grid })

# =====================================================================
# Log tab
# =====================================================================
# Used to be "Pipeline" with Launch/Assign/Full-pipeline group boxes. Assign
# and Full Pipeline are gone (per-app group management replaced the bulk
# step - see the note further down). Launch is now a toolbar button on the
# App Catalog tab like every other action, rather than living alone in its
# own tab. This tab is kept and renamed because Write-Log is genuinely used
# throughout the app as the general status/diagnostic log - not just by
# Launch - so removing it isn't an option, just moving Launch off it.
$Global:App.Progress = New-Object System.Windows.Forms.ProgressBar
$Global:App.Progress.Dock = "Bottom"
$Global:App.Progress.Height = 6
$Global:App.Progress.Style = "Marquee"
$Global:App.Progress.Visible = $false
$tabPipeline.Controls.Add($Global:App.Progress)

$Global:App.LogBox = New-Object System.Windows.Forms.RichTextBox
$Global:App.LogBox.Dock = "Fill"
Initialize-DarkLogBox -LogBox $Global:App.LogBox -FontSize 9
$tabPipeline.Controls.Add($Global:App.LogBox)
$Global:App.LogBox.BringToFront()




# ---------------------------------------------------------------
# Async runner: launches a child powershell.exe, tails its output
# into the log box, and calls -OnComplete when it exits.
# ---------------------------------------------------------------


# Small modal wrapper around Invoke-LaunchStep - shows the run's output live
# in its own log box instead of just switching the main window to the
# Pipeline/Log tab, same reasoning as every other action dialog's own
# -ExtraLogTarget (Show-CreateInIntuneDialog, Show-SyncMetadataDialog, etc.):
# Start-PipelineProcess's Timer keeps ticking while this is modal (it's the
# same UI thread's message loop, just nested), so live output still streams
# in normally.

$Global:App.BtnRunLaunch.Add_Click({
    # Selected rows (if any) scope this to just them; nothing selected falls
    # back to the previous "package everything" behavior.
    $selectedIndices = Get-SelectedAppIndices
    if ($selectedIndices.Count -gt 0) {
        $selectedUncommon = @($selectedIndices | ForEach-Object { $Global:App.Apps[$_] } | Where-Object { Test-AppIsUncommon -App $_ })
        if ($selectedUncommon.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("None of the $($selectedIndices.Count) selected app(s) are uncommon (they all have a Winget ID, so they share the one generic package) - nothing to build for this selection. Clear the selection to package everything, or select at least one uncommon app.", "Nothing to package", "OK", "Information") | Out-Null
            return
        }
        $folderNames = @($selectedUncommon | ForEach-Object { Get-SafeFileNameForApp -Name $_.appName })
        Show-PackagingProgressDialog -FolderNames $folderNames
        return
    }
    Show-PackagingProgressDialog
})

# =====================================================================
# Startup
# =====================================================================
Initialize-Folders
Import-AppsFromFile -Path $Global:App.LinkedFilePath
Load-LastAuditCache
Update-Grid
Write-Log "Intune deployment console ready (v$($Global:App.AppVersion)). Root: $($Global:App.RootPath)`r`n" ([System.Drawing.Color]::Gainsboro)
Start-TypeVersionBackfill

Update-CredentialWarningBanner

$Global:App.Form.Add_FormClosing({
    if ($Global:App.UnsavedChangesBox.Value) {
        $r = [System.Windows.Forms.MessageBox]::Show("You have unsaved catalog changes. Close anyway?", "Unsaved changes", "YesNo", "Warning")
        if ($r -ne "Yes") { $_.Cancel = $true }
    }
})

$Global:App.Form.Add_FormClosed({
    if ($Global:App.LogFlushTimer) {
        try { $Global:App.LogFlushTimer.Stop(); $Global:App.LogFlushTimer.Dispose() } catch { }
        $Global:App.LogFlushTimer = $null
    }
    if ($Global:App.LogFileWriter) {
        try { $Global:App.LogFileWriter.Flush(); $Global:App.LogFileWriter.Close() } catch { }
        $Global:App.LogFileWriter = $null
    }
    # Only cleared here, on the whole app closing - not when Settings
    # closes, so closing/reopening Settings mid-session doesn't force a
    # fresh sign-in. See the note on Clear-DelegatedSignInCache.
    Clear-DelegatedSignInCache
})

Set-Theme -Control $Global:App.Form
[void]$Global:App.Form.ShowDialog()
