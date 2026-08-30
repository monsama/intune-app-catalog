<#
.SYNOPSIS
    ITSENSE Intune App Catalog & Deployment GUI - manage the app catalog and run the Intune
    pipeline, all from one window, all from one file.

.DESCRIPTION
    A WinForms front end for the ITSENSE Intune deployment pipeline. Self-contained: the
    packaging and assignment logic (what used to be 1_GenerateIntunePackage.ps1 and
    5_AssignGroupsAndNames.ps1) is embedded directly in this file. App data lives as one
    JSON file per app in an "apps-data" folder next to this script - not a single combined
    file - so a Git diff for one app's change only ever touches that app's own file, and one
    corrupted file doesn't take the rest of the catalog down with it. An older single
    input.json is migrated into this folder automatically, once, the first time this script
    doesn't find the new folder already there. Two tabs:

    App Catalog
        Loads every app's own JSON file from the "apps-data" folder next to this script,
        shows them in a grid, and lets you add, edit, or delete apps. Group membership
        (Required / Available / Uninstall) is set with checkboxes against every group already
        used in the catalog, plus a button to add a brand new group. Save writes straight
        back to each app's own file - no export/import step. Its own toolbar covers the rest
        of the pipeline: "Package apps..." builds the .intunewin package(s) (same logic as the
        old 1_GenerateIntunePackage.ps1 / runDeployment.cmd) and its output streams into the
        Log tab; "Batch deploy...", "Sync metadata...", and "Assign Groups..." (per app, from
        the app editor, or "Batch assign groups..." across several) cover what
        5_AssignGroupsAndNames.ps1 used to do - syncing Intune app names, Entra ID groups, and
        assignments against the catalog - without a separate combined "Assign" step.

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
    The Assign logic normally asks "proceed? (y/n)" on the console before applying changes.
    A hidden background process can never answer that prompt, so it would hang forever. To
    avoid that, this GUI always runs it with -AutoApprove $true and shows its own confirmation
    dialog first instead. Use the Dry Run checkbox to preview changes with zero risk before
    you tick that dialog's "Yes, apply".

    Requires: Windows PowerShell 5.1+ (or PowerShell 7+ on Windows), the Microsoft.Graph
    modules that the Assign logic itself checks for, and an "apps-data" folder (or an old
    single input.json to migrate from) next to this script.

.EXAMPLE
    .\ITSENSE-IntuneDeployment.ps1
#>

[CmdletBinding()]
param()

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
Add-Type -AssemblyName System.Security   # for the native X509Certificate2UI store picker
[System.Windows.Forms.Application]::EnableVisualStyles()

# =====================================================================
# Paths & state
# =====================================================================
$Script:RootPath        = $PSScriptRoot
# Points at a FOLDER of per-app JSON files now (one file per app, e.g.
# "apps-data/7zip.json"), not a single input.json - kept the same variable
# name despite the changed meaning to minimize how many of the many
# existing references throughout this script needed touching, given the
# genuine risk of a change this size. Load-AppsFromFile automatically
# migrates an old single-file input.json into this folder the first time
# it doesn't find the new structure already there.
$Script:LinkedFilePath  = Join-Path $RootPath "apps-data"
$Script:Apps            = New-Object System.Collections.ArrayList
$Script:UnsavedChangesBox = @{ Value = $false }   # container (never reassigned) so closures can mutate it safely
$Script:IntuneAppsCache = New-Object System.Collections.ArrayList   # populated by Start-IntuneAppLookup: array of @{ id; displayName } - mutated in place (Clear+Add), never reassigned, so every closure that references it stays in sync
$Script:EntraDirectoryCache = New-Object System.Collections.ArrayList   # populated by Start-EntraDirectoryLookup: array of @{ displayName; type ("Group"/"User"); id; upn } - same mutate-in-place pattern as above
$Script:LogFileWriter = $null   # opened in Ensure-Folders, written to by Write-Log, closed on FormClosing - see both below
$Script:LogFlushTimer = $null   # periodic flush timer for the above - see Ensure-Folders
$Script:AppVersion = "1.1"   # bump when shipping a meaningfully different build, so "which version are you on" is answerable at a glance rather than by diffing the whole file

# App-only Graph auth (certificate) - must match the values in the Assign step /
# your Entra ID app registration. Left blank on purpose - no tenant/client
# ID or certificate thumbprint should ever be hardcoded in a script that
# lives in a repo. Configure these via "Settings..." in the app on first
# run; they're then saved to itsense-intune-settings.json next to this
# script and loaded automatically from there on every subsequent launch
# (see Load-GraphSettings below). The certificate itself must already be
# installed in this user's certificate store - Settings can also pick an
# existing one or generate a new one.
$Script:GraphTenantId              = ""
$Script:GraphClientId              = ""
$Script:GraphCertificateThumbprint = ""
$Script:SettingsFilePath = Join-Path $Script:RootPath "itsense-intune-settings.json"

# Group names marked as "favorites" - shown as ready-to-tick options in
# every app's Required/Available/Uninstall lists (new and existing alike),
# instead of those lists defaulting to every group ever used by any app in
# the whole catalog. Persisted in the same settings file as Graph
# credentials, so both need to be written together on every save - see the
# comment on Write-SettingsFile below for why.
$Script:FavoriteGroups = New-Object System.Collections.Generic.List[string]

# =====================================================================
# Styling - single, consistent light palette applied to every control
# =====================================================================
$Script:LightPalette = @{
    FormBack       = [System.Drawing.SystemColors]::Control
    ControlFore    = [System.Drawing.SystemColors]::ControlText
    FieldBack      = [System.Drawing.SystemColors]::Window
    ButtonBack     = [System.Drawing.SystemColors]::Control
    GridBack       = [System.Drawing.SystemColors]::Window
    GridAltBack    = [System.Drawing.Color]::FromArgb(245,245,245)
    GridHeaderBack = [System.Drawing.SystemColors]::Control
    BorderColor    = [System.Drawing.SystemColors]::ControlDark
    SelectionBack  = [System.Drawing.SystemColors]::Highlight
    SelectionFore  = [System.Drawing.SystemColors]::HighlightText
}

# Applies the current theme to a control and everything nested inside it,
# recursively - call on any Form/dialog right before ShowDialog() (after all
# its controls have been built and added) so its whole tree gets themed.
# RichTextBoxes used as log consoles are deliberately skipped - they already
# have their own explicit dark styling set wherever they're created (a
# console look regardless of the app's overall theme), and re-theming them
# here would fight that.
function Set-Theme {
    param([System.Windows.Forms.Control]$Control)
    Set-ThemeRecursive -Ctrl $Control -Palette $Script:LightPalette
}

function Set-ThemeRecursive {
    param($Ctrl, $Palette)

    switch ($Ctrl.GetType().Name) {
        "Form" {
            $Ctrl.BackColor = $Palette.FormBack
            $Ctrl.ForeColor = $Palette.ControlFore
        }
        { $_ -in @("Panel","GroupBox","TabPage","FlowLayoutPanel","TabControl") } {
            $Ctrl.BackColor = $Palette.FormBack
            $Ctrl.ForeColor = $Palette.ControlFore
        }
        "Label" {
            $Ctrl.ForeColor = $Palette.ControlFore
        }
        { $_ -in @("TextBox","ComboBox") } {
            $Ctrl.BackColor = $Palette.FieldBack
            $Ctrl.ForeColor = $Palette.ControlFore
        }
        "Button" {
            $Ctrl.BackColor = $Palette.ButtonBack
            $Ctrl.ForeColor = $Palette.ControlFore
            $Ctrl.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
            $Ctrl.FlatAppearance.BorderColor = $Palette.BorderColor
        }
        { $_ -in @("CheckBox","RadioButton") } {
            $Ctrl.ForeColor = $Palette.ControlFore
        }
        { $_ -in @("ListBox","CheckedListBox") } {
            $Ctrl.BackColor = $Palette.FieldBack
            $Ctrl.ForeColor = $Palette.ControlFore
        }
        "DataGridView" {
            $Ctrl.BackgroundColor = $Palette.GridBack
            $Ctrl.ForeColor = $Palette.ControlFore
            $Ctrl.GridColor = $Palette.BorderColor
            $Ctrl.EnableHeadersVisualStyles = $false
            $Ctrl.DefaultCellStyle.BackColor = $Palette.GridBack
            $Ctrl.DefaultCellStyle.ForeColor = $Palette.ControlFore
            $Ctrl.DefaultCellStyle.SelectionBackColor = $Palette.SelectionBack
            $Ctrl.DefaultCellStyle.SelectionForeColor = $Palette.SelectionFore
            $Ctrl.AlternatingRowsDefaultCellStyle.BackColor = $Palette.GridAltBack
            $Ctrl.AlternatingRowsDefaultCellStyle.ForeColor = $Palette.ControlFore
            $Ctrl.ColumnHeadersDefaultCellStyle.BackColor = $Palette.GridHeaderBack
            $Ctrl.ColumnHeadersDefaultCellStyle.ForeColor = $Palette.ControlFore
            $Ctrl.RowHeadersDefaultCellStyle.BackColor = $Palette.GridHeaderBack
            $Ctrl.RowHeadersDefaultCellStyle.ForeColor = $Palette.ControlFore
        }
        "StatusStrip" {
            # StatusStrip's actual content (ToolStripStatusLabel etc.) lives
            # in .Items, not the regular .Controls tree the recursive walk
            # below descends into - so without this explicit case, the
            # status bar would silently stay stuck at default system colors
            # (a visibly mismatched light bar at the bottom of a dark form).
            $Ctrl.BackColor = $Palette.FormBack
            foreach ($item in $Ctrl.Items) {
                $item.ForeColor = $Palette.ControlFore
            }
        }
        "MenuStrip" {
            # Same ToolStrip-family issue as StatusStrip above - a MenuStrip's
            # top-level items AND their dropdown items both live outside the
            # regular .Controls tree.
            $Ctrl.BackColor = $Palette.FormBack
            foreach ($item in $Ctrl.Items) {
                $item.ForeColor = $Palette.ControlFore
                if ($item.DropDownItems) {
                    foreach ($sub in $item.DropDownItems) {
                        $sub.ForeColor = $Palette.ControlFore
                    }
                }
            }
        }
        default { }
    }

    foreach ($child in @($Ctrl.Controls)) {
        Set-ThemeRecursive -Ctrl $child -Palette $Palette
    }
}

# Overrides $Script:GraphTenantId/ClientId/CertificateThumbprint from
# itsense-intune-settings.json if that file exists, so choices made in the Settings
# dialog persist across restarts without editing this script's source.
function Load-GraphSettings {
    if (-not (Test-Path $Script:SettingsFilePath)) { return }
    try {
        $settings = Get-Content -Path $Script:SettingsFilePath -Raw | ConvertFrom-Json
        if ($settings.TenantId)  { $Script:GraphTenantId = $settings.TenantId }
        if ($settings.ClientId)  { $Script:GraphClientId = $settings.ClientId }
        if ($settings.CertificateThumbprint) { $Script:GraphCertificateThumbprint = $settings.CertificateThumbprint }
        if ($settings.FavoriteGroups) {
            $Script:FavoriteGroups.Clear()
            foreach ($g in @($settings.FavoriteGroups)) { [void]$Script:FavoriteGroups.Add([string]$g) }
        }
    }
    catch {
        # Bad/corrupt settings file - fall back to the built-in defaults silently;
        # the Settings dialog will show whatever's actually active.
    }
}

# Always writes EVERY setting this file holds, not just the ones the
# caller happens to be updating - Save-GraphSettings and
# Save-FavoriteGroups both route through this single function rather
# than each independently overwriting the whole file with only their own
# fields, which would silently wipe out whichever setting the OTHER
# function manages. The same class of bug already found and fixed once
# this session (the App Editor overwriting metadata because it rebuilt
# the whole app record from only its own fields) - fixed here from the
# start by construction, not by patching around it after the fact.
function Write-SettingsFile {
    try {
        $settings = [pscustomobject]@{
            TenantId              = $Script:GraphTenantId
            ClientId              = $Script:GraphClientId
            CertificateThumbprint = $Script:GraphCertificateThumbprint
            FavoriteGroups        = @($Script:FavoriteGroups)
        }
        $json = $settings | ConvertTo-Json -Depth 5
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($Script:SettingsFilePath, $json, $utf8NoBom)
        return $true
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Could not save settings: $($_.Exception.Message)", "Save failed", "OK", "Error") | Out-Null
        return $false
    }
}

function Save-GraphSettings {
    param(
        [string]$TenantId,
        [string]$ClientId,
        [string]$CertificateThumbprint
    )
    $Script:GraphTenantId = $TenantId
    $Script:GraphClientId = $ClientId
    $Script:GraphCertificateThumbprint = $CertificateThumbprint
    return (Write-SettingsFile)
}

# Favorites are stored as their own list, mutated directly by whichever
# UI manages them, then persisted the same way Save-GraphSettings does -
# through the one shared writer above, so this never touches (or risks
# clobbering) the Graph credential fields it doesn't manage.
function Save-FavoriteGroups {
    return (Write-SettingsFile)
}

# Clears the delegated user's sign-in used for Check/Upload/Delete in
# Settings - deletes the same MSAL token cache files Microsoft Graph
# PowerShell persists to disk by default. Deliberately tied to the WHOLE
# APP closing, not to Settings closing - closing and reopening Settings
# during the same session (e.g. to do something else, then come back and
# run another cert operation) shouldn't force a fresh sign-in each time.
# Only when the app itself exits does the cached credential get cleared.
function Clear-DelegatedSignInCache {
    try {
        $msalCacheDir = Join-Path $env:LOCALAPPDATA ".IdentityService"
        foreach ($cacheFile in @("mg.msal.cache.cae", "mg.msal.cache.nocae")) {
            $cachePath = Join-Path $msalCacheDir $cacheFile
            if (Test-Path $cachePath) { Remove-Item -Path $cachePath -Force -ErrorAction SilentlyContinue }
        }
    } catch { }
}

Load-GraphSettings

# =====================================================================
# Embedded pipeline scripts
# =====================================================================
# The full content of 1_GenerateIntunePackage.ps1 and 5_AssignGroupsAndNames.ps1,
# embedded verbatim so this GUI is a single self-contained file - nothing else
# to keep next to it except input.json. At runtime, Start-PipelineProcess writes
# whichever one is needed out to a temp .ps1 file INSIDE $Script:RootPath (not
# $env:TEMP), because both scripts use $PSScriptRoot internally to find
# input.json / IntuneWinAppUtil.exe - the temp file has to live in the real
# deployment folder for that to resolve correctly. It's deleted again as soon
# as the child process exits, successfully or not.
$Script:EmbeddedPackageScript = @'
<#
.SYNOPSIS
    Universal Intune packager - handles both installers and PowerShell scripts
.DESCRIPTION
    Automatically scans folders and packages:
    - Traditional installers (.exe, .msi) - packaged as AppName.intunewin
    - PowerShell scripts (install.ps1) - packaged as AppName.intunewin
    Downloads IntuneWinAppUtil.exe automatically if not present.
    By default, saves .intunewin files in their source app folders.
.PARAMETER InputFolder
    Root folder to scan for apps
.PARAMETER OutputFolder
    Where to save all .intunewin packages (optional - if not specified, saves in each app's folder)
.PARAMETER ToolPath
    Path to IntuneWinAppUtil.exe
.PARAMETER Recursive
    Scan subfolders recursively
.PARAMETER SkipExisting
    Skip apps that are already packaged
.PARAMETER Force
    Overwrite existing packages
.EXAMPLE
    .\2_PackageApps.ps1
    (Saves .intunewin files in each app's source folder)
.EXAMPLE
    .\2_PackageApps.ps1 -OutputFolder "packages"
    (Saves all .intunewin files to central packages folder)
.EXAMPLE
    .\2_PackageApps.ps1 -Recursive -Force
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$InputFolder = "apps_common",
    
    [Parameter(Mandatory=$false)]
    [string]$OutputFolder = "",
    
    [Parameter(Mandatory=$false)]
    [string]$ToolPath = ".\IntuneWinAppUtil.exe",
    
    [Parameter(Mandatory=$false)]
    [switch]$Recursive,
    
    [Parameter(Mandatory=$false)]
    [switch]$SkipExisting,
    
    [Parameter(Mandatory=$false)]
    [switch]$Force,

    [Parameter(Mandatory=$false)]
    [string]$SingleFolderName = "",

    [Parameter(Mandatory=$false)]
    [string]$FolderNames = ""
)

$ErrorActionPreference = "Stop"

#region Tool Download
function Download-IntuneWinAppUtil {
    param([string]$DestinationPath)
    
    Write-Host "IntuneWinAppUtil.exe not found. Downloading..." -ForegroundColor Yellow
    
    $ToolFolder = Split-Path $DestinationPath -Parent
    if (-not (Test-Path $ToolFolder)) {
        New-Item -ItemType Directory -Path $ToolFolder -Force | Out-Null
    }
    
    $DownloadUrl = "https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/archive/refs/heads/master.zip"
    $ZipPath = Join-Path $env:TEMP "IntuneWinAppUtil.zip"
    $ExtractPath = Join-Path $env:TEMP "IntuneWinAppUtil_Extract"
    
    try {
        Write-Host "  Downloading from GitHub..." -ForegroundColor Gray
        
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $DownloadUrl -OutFile $ZipPath -UseBasicParsing
        $ProgressPreference = 'Continue'
        
        if (-not (Test-Path $ZipPath)) {
            throw "Download failed - zip file not found"
        }
        
        Write-Host "  Extracting..." -ForegroundColor Gray
        
        if (Test-Path $ExtractPath) {
            Remove-Item $ExtractPath -Recurse -Force
        }
        
        Expand-Archive -Path $ZipPath -DestinationPath $ExtractPath -Force
        
        $ExeFile = Get-ChildItem -Path $ExtractPath -Filter "IntuneWinAppUtil.exe" -Recurse | Select-Object -First 1
        
        if (-not $ExeFile) {
            throw "IntuneWinAppUtil.exe not found in downloaded package"
        }
        
        Write-Host "  Installing to: $DestinationPath" -ForegroundColor Gray
        Copy-Item -Path $ExeFile.FullName -Destination $DestinationPath -Force
        
        Remove-Item $ZipPath -Force -ErrorAction SilentlyContinue
        Remove-Item $ExtractPath -Recurse -Force -ErrorAction SilentlyContinue
        
        if (Test-Path $DestinationPath) {
            Write-Host "  Successfully installed!" -ForegroundColor Green
            return $true
        } else {
            throw "Installation failed"
        }
    }
    catch {
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
        if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path $ExtractPath) { Remove-Item $ExtractPath -Recurse -Force -ErrorAction SilentlyContinue }
        return $false
    }
}
#endregion

#region Installer Functions
function Find-BestInstaller {
    param([string]$FolderPath)
    
    $Installers = Get-ChildItem -Path $FolderPath -File | Where-Object {
        $_.Extension -match '\.(exe|msi)$'
    }
    
    if ($Installers.Count -eq 0) { return $null }
    if ($Installers.Count -eq 1) { return $Installers[0] }

    # Prefer setup files with x64 in name
    $SetupX64 = $Installers | Where-Object { $_.Name -match '(setup|install)' -and $_.Name -match '(x64|64bit|amd64|win64)' } | Select-Object -First 1
    if ($SetupX64) { return $SetupX64 }

    # Then any setup file
    $Setup = $Installers | Where-Object { $_.Name -match '(setup|install)' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($Setup) { return $Setup }

    # Then MSI x64
    $MsiX64 = $Installers | Where-Object { $_.Extension -eq '.msi' -and $_.Name -match '(x64|64bit|amd64|win64)' } | Select-Object -First 1
    if ($MsiX64) { return $MsiX64 }

    # Then any MSI
    $Msi = $Installers | Where-Object { $_.Extension -eq '.msi' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($Msi) { return $Msi }

    # Then EXE x64
    $ExeX64 = $Installers | Where-Object { $_.Extension -eq '.exe' -and $_.Name -match '(x64|64bit|amd64|win64)' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($ExeX64) { return $ExeX64 }

    # Then newest file
    $Newest = $Installers | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($Newest) { return $Newest }

    # Finally largest file
    return $Installers | Sort-Object Length -Descending | Select-Object -First 1
}

function Get-AppNameFromFile {
    param([string]$FileName)
    
    $Name = $FileName -replace '\.(exe|msi|ps1)$', ''
    $Name = $Name -replace '^(install|uninstall|detect)-', ''
    $Name = $Name -replace '[-_](x64|x86|64bit|32bit|amd64|win64|win32)', ''
    $Name = $Name -replace '[-_](setup|install|installer)', ''
    $Name = $Name -replace '[-_]v?\d+(\.\d+)*', ''
    $Name = $Name -replace 'Standalone|Enterprise', ''
    $Name = $Name -replace '[-_]+', ' '
    $Name = $Name.Trim()
    
    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $FileName
    }
    
    return (Get-Culture).TextInfo.ToTitleCase($Name.ToLower())
}
#endregion

#region PowerShell Script Functions
function Get-AppNameFromScript {
    param([string]$ScriptPath)
    
    try {
        $Content = Get-Content -Path $ScriptPath -Raw -ErrorAction SilentlyContinue
        
        # Try to extract AppName from $AppConfig
        if ($Content -match '\$AppConfig\s*=\s*@\{[^}]*AppName\s*=\s*[''"]([^''"]+)[''"]') {
            return $Matches[1]
        }
        
        # Try to extract from WingetId
        if ($Content -match '\$AppConfig\s*=\s*@\{[^}]*WingetId\s*=\s*[''"]([^''"]+)[''"]') {
            $WingetId = $Matches[1]
            $Parts = $WingetId -split '\.'
            $AppPart = $Parts[-1]
            $Name = $AppPart -replace '[^a-zA-Z0-9\s]', ' '
            $Name = $Name.Trim()
            if ($Name) {
                return (Get-Culture).TextInfo.ToTitleCase($Name.ToLower())
            }
        }
        
        return $null
    }
    catch {
        return $null
    }
}

function Get-AppScope {
    param([string]$InstallScriptPath)
    
    try {
        $Content = Get-Content -Path $InstallScriptPath -Raw -ErrorAction SilentlyContinue
        
        if ($Content -match '\$AppConfig\s*=\s*@\{[^}]*Scope\s*=\s*[''"]([^''"]*)[''"]') {
            $Scope = $Matches[1]
            
            if ([string]::IsNullOrWhiteSpace($Scope)) {
                return ""
            }
            
            return $Scope
        }
        
        return ""
    }
    catch {
        return ""
    }
}

function Test-ScriptValidity {
    param([string]$ScriptPath)
    
    if (-not (Test-Path $ScriptPath)) {
        return $false
    }
    
    try {
        $Errors = $null
        $Content = Get-Content -Path $ScriptPath -Raw
        $null = [System.Management.Automation.PSParser]::Tokenize($Content, [ref]$Errors)
        return ($Errors.Count -eq 0)
    }
    catch {
        return $false
    }
}
#endregion

#region Helper Functions
function Get-SafeFileName {
    param([string]$Name)
    
    # Remove only characters that are invalid in Windows filenames: < > : " / \ | ? *
    $safeName = $Name -replace '[<>:"/\\|?*]', ''
    
    # Replace multiple spaces with single space, then spaces with hyphens
    $safeName = $safeName -replace '\s+', ' '
    $safeName = $safeName -replace '\s', '-'
    
    # Replace multiple hyphens/dots with single hyphen
    $safeName = $safeName -replace '[.-]+', '-'
    
    # Trim hyphens
    $safeName = $safeName.Trim('-')
    
    if ([string]::IsNullOrWhiteSpace($safeName)) {
        $safeName = "App-" + (Get-Random -Minimum 1000 -Maximum 9999)
    }
    
    return $safeName
}
#endregion

#region Main Script
Clear-Host
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Universal Intune Packager" -ForegroundColor Cyan
Write-Host "  Handles: Installers (.exe, .msi) & PowerShell Scripts" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# Ensure IntuneWinAppUtil.exe is available
if (-not (Test-Path $ToolPath)) {
    if (-not (Download-IntuneWinAppUtil -DestinationPath $ToolPath)) {
        Write-Host ""
        Write-Host "Failed to download IntuneWinAppUtil.exe automatically." -ForegroundColor Red
        Write-Host "Please download manually from:" -ForegroundColor Yellow
        Write-Host "https://github.com/Microsoft/Microsoft-Win32-Content-Prep-Tool/releases" -ForegroundColor Yellow
        exit 1
    }
    Write-Host ""
}

# Validate input folder
if (-not (Test-Path $InputFolder)) {
    Write-Host "Error: Input folder not found: $InputFolder" -ForegroundColor Red
    exit 1
}

# Determine if using central output folder or per-app folders
$UseCentralOutput = -not [string]::IsNullOrWhiteSpace($OutputFolder)

if ($UseCentralOutput) {
    # Create central output folder if needed
    if (-not (Test-Path $OutputFolder)) {
        New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
        Write-Host "Created output folder: $OutputFolder" -ForegroundColor Green
        Write-Host ""
    }
    $OutputMode = "Central folder: $OutputFolder"
} else {
    $OutputMode = "Per-app folders (in source)"
}

Write-Host "Configuration:" -ForegroundColor White
Write-Host "  Input:         $InputFolder" -ForegroundColor Gray
Write-Host "  Output:        $OutputMode" -ForegroundColor Gray
Write-Host "  Tool:          $ToolPath" -ForegroundColor Gray
Write-Host "  Recursive:     $(if ($Recursive) { 'Yes' } else { 'No' })" -ForegroundColor Gray
Write-Host "  Skip existing: $(if ($SkipExisting) { 'Yes' } else { 'No' })" -ForegroundColor Gray
Write-Host "  Force:         $(if ($Force) { 'Yes' } else { 'No' })" -ForegroundColor Gray
Write-Host ""

Write-Host "Scanning for apps..." -ForegroundColor Cyan

# Find all apps (installers or scripts)
$AppsToProcess = @()

if ($Recursive) {
    $AllFolders = Get-ChildItem -Path $InputFolder -Recurse -Directory
} else {
    $AllFolders = Get-ChildItem -Path $InputFolder -Directory
}

if ($SingleFolderName) {
    $AllFolders = @($AllFolders | Where-Object { $_.Name -eq $SingleFolderName })
    if ($AllFolders.Count -eq 0) {
        Write-Host "Error: Folder '$SingleFolderName' not found under $InputFolder" -ForegroundColor Red
        exit 1
    }
}
elseif ($FolderNames) {
    $wantedNames = @($FolderNames -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $AllFolders = @($AllFolders | Where-Object { $wantedNames -contains $_.Name })
    if ($AllFolders.Count -eq 0) {
        Write-Host "Error: None of the requested folders were found under $InputFolder" -ForegroundColor Red
        exit 1
    }
}

foreach ($Folder in $AllFolders) {
    # Check for PowerShell script (install.ps1)
    $InstallScript = Get-ChildItem -Path $Folder.FullName -File -Filter "install.ps1" -ErrorAction SilentlyContinue
    
    if ($InstallScript) {
        # PowerShell-based WinGet app
        $AppName = Get-AppNameFromScript -ScriptPath $InstallScript.FullName
        
        if (-not $AppName) {
            $AppName = $Folder.Name
        }
        
        $Scope = Get-AppScope -InstallScriptPath $InstallScript.FullName
        
        $UninstallScript = Get-ChildItem -Path $Folder.FullName -File -Filter "uninstall.ps1" -ErrorAction SilentlyContinue
        $DetectScript = Get-ChildItem -Path $Folder.FullName -File -Filter "detect.ps1" -ErrorAction SilentlyContinue
        
        $AppsToProcess += [PSCustomObject]@{
            Type             = "Script"
            FolderName       = $Folder.Name
            FolderPath       = $Folder.FullName
            AppName          = $AppName
            Scope            = $Scope
            SourceFile       = $InstallScript
            SourceFileName   = "install.ps1"
            UninstallScript  = $UninstallScript
            DetectScript     = $DetectScript
            HasUninstall     = ($null -ne $UninstallScript)
            HasDetect        = ($null -ne $DetectScript)
        }
    }
    else {
        # Check for traditional installer
        $Installer = Find-BestInstaller -FolderPath $Folder.FullName
        
        if ($Installer) {
            $AppName = Get-AppNameFromFile -FileName $Installer.Name
            
            # Use folder name as fallback
            if ($AppName -eq $Installer.Name) {
                $AppName = $Folder.Name
            }
            
            $AppsToProcess += [PSCustomObject]@{
                Type             = "Installer"
                FolderName       = $Folder.Name
                FolderPath       = $Folder.FullName
                AppName          = $AppName
                Scope            = "machine"
                SourceFile       = $Installer
                SourceFileName   = $Installer.Name
                UninstallScript  = $null
                DetectScript     = $null
                HasUninstall     = $false
                HasDetect        = $false
            }
        }
    }
}

if ($AppsToProcess.Count -eq 0) {
    Write-Host "No apps found!" -ForegroundColor Red
    Write-Host ""
    Write-Host "Expected structures:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  PowerShell Scripts:" -ForegroundColor Cyan
    Write-Host "    $InputFolder\" -ForegroundColor Gray
    Write-Host "      AppName1\        <-- Folder with scripts" -ForegroundColor Gray
    Write-Host "        install.ps1    <-- Required" -ForegroundColor Gray
    Write-Host "        uninstall.ps1  <-- Optional" -ForegroundColor Gray
    Write-Host "        detect.ps1     <-- Optional" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Traditional Installers:" -ForegroundColor Cyan
    Write-Host "    $InputFolder\" -ForegroundColor Gray
    Write-Host "      Chrome\          <-- Folder with installer" -ForegroundColor Gray
    Write-Host "        setup.exe      <-- .exe or .msi file" -ForegroundColor Gray
    exit 1
}

$InstallerCount = ($AppsToProcess | Where-Object { $_.Type -eq "Installer" }).Count
$ScriptCount = ($AppsToProcess | Where-Object { $_.Type -eq "Script" }).Count

Write-Host "Found $($AppsToProcess.Count) app(s):" -ForegroundColor Green
Write-Host "  Traditional Installers: $InstallerCount" -ForegroundColor Cyan
Write-Host "  PowerShell Scripts:     $ScriptCount" -ForegroundColor Cyan
Write-Host ""

$SuccessCount = 0
$FailCount = 0
$SkipCount = 0
$Results = @()
$Counter = 0

foreach ($App in $AppsToProcess) {
    $Counter++
    
    Write-Host "[$Counter/$($AppsToProcess.Count)] $($App.Type): $($App.AppName)" -ForegroundColor Yellow
    if ($App.Type -eq "Script") {
        $u = if ($App.UninstallScript) { "uninstall:Y" } else { "uninstall:N" }
        $d = if ($App.DetectScript) { "detect:Y" } else { "detect:N" }
        Write-Host "  install:Y  $u  $d" -ForegroundColor Gray

        # Validate script syntax
        $scriptsToCheck = @($App.SourceFile.FullName)
        if ($App.UninstallScript) { $scriptsToCheck += $App.UninstallScript.FullName }
        if ($App.DetectScript) { $scriptsToCheck += $App.DetectScript.FullName }
        
        $AllValid = $true
        foreach ($ScriptPath in $scriptsToCheck) {
            if (-not (Test-ScriptValidity -ScriptPath $ScriptPath)) {
                Write-Host "  ERROR: Invalid syntax in $([System.IO.Path]::GetFileName($ScriptPath))" -ForegroundColor Red
                $AllValid = $false
            }
        }
        
        if (-not $AllValid) {
            $FailCount++
            Write-Host ""
            continue
        }
    }
    
    # Generate output filename
    $SafeAppName = Get-SafeFileName -Name $App.AppName
    $OutputFileName = "$SafeAppName.intunewin"
    
    # Determine final output path - either central folder or app's source folder
    if ($UseCentralOutput) {
        $FinalOutputPath = Join-Path $OutputFolder $OutputFileName
    } else {
        $FinalOutputPath = Join-Path $App.FolderPath $OutputFileName
    }
    
    # Check if package already exists
    if ((Test-Path $FinalOutputPath) -and $SkipExisting -and -not $Force) {
        $ExistingFile = Get-Item $FinalOutputPath
        $SourceModified = $App.SourceFile.LastWriteTime
        
        if ($SourceModified -le $ExistingFile.LastWriteTime) {
            Write-Host "  Package exists and is up-to-date - Skipping" -ForegroundColor DarkGray
            $SkipCount++
            Write-Host ""
            continue
        }
        Write-Host "  Repackaging (source newer than package)" -ForegroundColor Yellow
    }
    
    if ((Test-Path $FinalOutputPath) -and -not $Force -and -not $SkipExisting) {
        Write-Host "  WARNING: Package exists, use -Force to overwrite" -ForegroundColor Yellow
        $SkipCount++
        Write-Host ""
        continue
    }
    
    Write-Host "  Packaging..." -ForegroundColor Cyan
    
    try {
        # Create a unique temporary output folder for this app
        $TempOutputFolder = Join-Path $env:TEMP ("IntunePackaging_Output_" + (Get-Random))
        New-Item -ItemType Directory -Path $TempOutputFolder -Force | Out-Null
        
        # For installers, copy to temp folder first
        if ($App.Type -eq "Installer") {
            $TempSourceFolder = Join-Path $env:TEMP ("IntunePackaging_Source_" + (Get-Random))
            New-Item -ItemType Directory -Path $TempSourceFolder -Force | Out-Null
            Copy-Item -Path $App.SourceFile.FullName -Destination $TempSourceFolder -Force
            $PackageSourceFolder = $TempSourceFolder
            $SetupFile = $App.SourceFileName
        }
        else {
            # For scripts, use the folder directly
            $PackageSourceFolder = $App.FolderPath
            $SetupFile = $App.SourceFileName
        }
        
        # Build arguments for IntuneWinAppUtil - use temp output folder
        $Args = @(
            "-c", "`"$PackageSourceFolder`"",
            "-s", "`"$SetupFile`"",
            "-o", "`"$TempOutputFolder`"",
            "-q"
        )
        
        # Convert relative path to absolute path for ProcessStartInfo
        if (-not [System.IO.Path]::IsPathRooted($ToolPath)) {
            $ToolFullPath = Join-Path $PSScriptRoot $ToolPath
        } else {
            $ToolFullPath = $ToolPath
        }
        
        # Run packaging tool - suppress all output
        $ProcessInfo = New-Object System.Diagnostics.ProcessStartInfo
        $ProcessInfo.FileName = $ToolFullPath
        $ProcessInfo.Arguments = $Args -join " "
        $ProcessInfo.RedirectStandardError = $true
        $ProcessInfo.RedirectStandardOutput = $true
        $ProcessInfo.UseShellExecute = $false
        $ProcessInfo.CreateNoWindow = $true
        
        $Process = New-Object System.Diagnostics.Process
        $Process.StartInfo = $ProcessInfo
        $Process.Start() | Out-Null
        $Process.WaitForExit()
        
        $ExitCode = $Process.ExitCode
        
        # Clean up temp source folder for installers
        if ($App.Type -eq "Installer" -and (Test-Path $TempSourceFolder)) {
            Remove-Item $TempSourceFolder -Recurse -Force -ErrorAction SilentlyContinue
        }
        
        if ($ExitCode -eq 0) {
            # IntuneWinAppUtil creates "<setupfile>.intunewin" in the temp output folder
            $CreatedFile = Get-ChildItem -Path $TempOutputFolder -Filter "*.intunewin" -File | Select-Object -First 1

            if ($CreatedFile) {
                # Remove existing file if it exists
                if (Test-Path $FinalOutputPath) {
                    Remove-Item $FinalOutputPath -Force
                }
                
                # Move to final location with correct name
                Move-Item -Path $CreatedFile.FullName -Destination $FinalOutputPath -Force
                
                # Clean up temp output folder
                Remove-Item $TempOutputFolder -Recurse -Force -ErrorAction SilentlyContinue
                
                $Size = [math]::Round((Get-Item $FinalOutputPath).Length / 1KB, 2)
                
                # Show relative path if in app folder, otherwise full path
                if ($UseCentralOutput) {
                    $DisplayPath = $OutputFileName
                } else {
                    $DisplayPath = Join-Path $App.FolderName $OutputFileName
                }
                
                Write-Host "  Success: $DisplayPath ($Size KB)" -ForegroundColor Green
                
                $SuccessCount++
                
                $Results += [PSCustomObject]@{
                    Type         = $App.Type
                    App          = $App.AppName
                    Folder       = $App.FolderName
                    Scope        = $App.Scope
                    HasUninstall = $App.HasUninstall
                    HasDetect    = $App.HasDetect
                    Status       = "Success"
                    Package      = $OutputFileName
                    Location     = if ($UseCentralOutput) { $OutputFolder } else { $App.FolderPath }
                    SizeKB       = $Size
                }
            }
            else {
                Write-Host "  Failed: Output file not created" -ForegroundColor Red
                
                # Clean up temp folder
                if (Test-Path $TempOutputFolder) {
                    Remove-Item $TempOutputFolder -Recurse -Force -ErrorAction SilentlyContinue
                }
                
                $FailCount++
                
                $Results += [PSCustomObject]@{
                    Type         = $App.Type
                    App          = $App.AppName
                    Folder       = $App.FolderName
                    Scope        = $App.Scope
                    HasUninstall = $App.HasUninstall
                    HasDetect    = $App.HasDetect
                    Status       = "Failed"
                    Package      = ""
                    Location     = ""
                    SizeKB       = 0
                }
            }
        }
        else {
            Write-Host "  Failed (Exit code: $ExitCode)" -ForegroundColor Red
            
            # Clean up temp folder
            if (Test-Path $TempOutputFolder) {
                Remove-Item $TempOutputFolder -Recurse -Force -ErrorAction SilentlyContinue
            }
            
            $FailCount++
            
            $Results += [PSCustomObject]@{
                Type         = $App.Type
                App          = $App.AppName
                Folder       = $App.FolderName
                Scope        = $App.Scope
                HasUninstall = $App.HasUninstall
                HasDetect    = $App.HasDetect
                Status       = "Failed"
                Package      = ""
                Location     = ""
                SizeKB       = 0
            }
        }
    }
    catch {
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
        $FailCount++
    }
    
    Write-Host ""
}

# Summary
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "SUMMARY" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "Processed:  $($AppsToProcess.Count)" -ForegroundColor White
Write-Host "Success:    $SuccessCount" -ForegroundColor Green
Write-Host "Failed:     $FailCount" -ForegroundColor Red
Write-Host "Skipped:    $SkipCount" -ForegroundColor Yellow
Write-Host ""

if ($UseCentralOutput) {
    Write-Host "Output location: $OutputFolder" -ForegroundColor Cyan
} else {
    Write-Host "Output location: Each app's source folder" -ForegroundColor Cyan
}

Write-Host ""
Write-Host "Done!" -ForegroundColor Green
#endregion
'@

$Script:EmbeddedCreateAppScript = @'
<#
.SYNOPSIS
    Creates (or updates the metadata of) a Win32 app in Intune from a catalog entry.
.DESCRIPTION
    Reads a JSON config file (written by the GUI) describing the app, connects to Microsoft
    Graph app-only via certificate, and either:
      - Mode "UpdateMetadata": PATCHes an existing app's name/description/install/uninstall/
        detection/dependencies. No content re-upload.
      - Mode "Create": creates a new Win32LobApp, uploads and commits the .intunewin package
        content (decrypting nothing - the package is already encrypted by IntuneWinAppUtil;
        this script reads that encryption metadata from the package and passes it through to
        Graph/Azure Storage as-is), sets detection rules, and sets dependencies.
    Writes a result JSON (success/appId/error) to -OutputResultPath so the GUI can read back
    what happened.
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$ConfigPath
)

$ErrorActionPreference = "Stop"

# Force TLS 1.2 explicitly. Windows PowerShell 5.1 / .NET Framework doesn't
# always default to TLS 1.2 for outbound HTTPS, and Azure Blob Storage
# requires TLS 1.2+. The Microsoft.Graph SDK forces this internally for its
# own requests (which is why Invoke-MgGraphRequest calls work regardless),
# but our own raw Invoke-WebRequest calls to Azure Storage inherit whatever
# this session's default protocol is - which, left unset, can cause the
# HTTPS handshake to hang or fail silently against a server that only
# accepts TLS 1.2+, even though basic TCP connectivity succeeds fine.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Write-Host "TLS protocol forced to: $([Net.ServicePointManager]::SecurityProtocol)" -ForegroundColor DarkGray

# By default .NET adds "Expect: 100-continue" to PUT/POST requests with a
# body - the client then WAITS for the server to say "100 Continue" before
# actually sending the body. If a corporate proxy/firewall interferes with
# that specific handshake (a common occurrence), the client can hang
# indefinitely even though the underlying TCP/TLS connection is completely
# healthy. This is a well-known cause of exactly "PUT/POST just hangs"
# symptoms for .NET scripts talking to Azure from behind corporate networks -
# disabling it means the body is sent immediately, no handshake to hang on.
[System.Net.ServicePointManager]::Expect100Continue = $false
Write-Host "Expect100Continue set to: $([System.Net.ServicePointManager]::Expect100Continue)" -ForegroundColor DarkGray

function Write-Step {
    param([string]$Text)
    Write-Host ""
    Write-Host "=== $Text ===" -ForegroundColor Cyan
}

function Write-Result {
    param([bool]$Success, [string]$AppId, [string]$ErrorMessage)
    $result = [pscustomobject]@{
        success = $Success
        appId   = $AppId
        error   = $ErrorMessage
    }
    $result | ConvertTo-Json | Set-Content -Path $Config.OutputResultPath -Encoding UTF8
}

# Pulls the actual error detail out of a failed web/Graph call. The default
# exception message for a failed HTTP call is just "Response status code does
# not indicate success: 400 (Bad Request)" - completely useless on its own.
# The real reason is almost always in the response BODY, which PowerShell
# normally puts in $_.ErrorDetails.Message for REST-style cmdlets; this falls
# back to reading the raw response stream if that's empty.
function Get-HttpErrorDetail {
    param($ErrorRecord)
    $detail = $ErrorRecord.ErrorDetails.Message
    if ($detail) { return $detail }
    try {
        if ($ErrorRecord.Exception.Response) {
            $stream = $ErrorRecord.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)
            $body = $reader.ReadToEnd()
            $reader.Close()
            if ($body) { return $body }
        }
    } catch { }
    return $null
}

# Adds a key to a request body hashtable ONLY if the value is non-blank. Used
# for the optional descriptive fields (owner/developer/notes/URLs) - in
# Update mode this dialog never fetches the app's current values first, so a
# blank field means "leave it as whatever it already is", not "clear it".
# Sending an empty string would actually WIPE an existing value, which this
# avoids by simply never including the key at all when there's nothing typed.
function Add-OptionalStringField {
    param([hashtable]$Body, [string]$GraphKey, [string]$Value)
    if (-not [string]::IsNullOrWhiteSpace($Value)) { $Body[$GraphKey] = $Value }
}

# Wraps Invoke-MgGraphRequest so any failure throws an exception whose message
# includes the actual Graph error body (error.code / error.message), not just
# the generic "response status does not indicate success" text.
function Invoke-GraphRequestDetailed {
    param(
        [Parameter(Mandatory=$true)][string]$Uri,
        [string]$Method = "GET",
        [string]$Body = $null,
        [string]$ContentType = "application/json",
        [Parameter(Mandatory=$true)][string]$StepDescription
    )
    $maxAttempts = 4
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            if ($Body) {
                return Invoke-MgGraphRequest -Uri $Uri -Method $Method -Body $Body -ContentType $ContentType -ErrorAction Stop
            }
            else {
                return Invoke-MgGraphRequest -Uri $Uri -Method $Method -ErrorAction Stop
            }
        }
        catch {
            # Graph rate-limits (429) or has brief service hiccups (503) far
            # more often during bulk operations working through many items
            # in a row than on a single one-off call - retrying with
            # backoff instead of immediately failing the whole run on the
            # first blip. Detected from the exception TEXT rather than a
            # structured status-code property, since this cmdlet's own
            # exceptions have already been confirmed elsewhere in this app
            # to carry the status as readable text (e.g. "BadRequest (Bad
            # Request)") rather than a reliably-populated .Response object.
            $isThrottled = $_.Exception.Message -match '429|TooManyRequests|Too Many Requests'
            $isTransient = $_.Exception.Message -match '503|ServiceUnavailable|Service Unavailable'
            # 429 always means the request was rejected BEFORE any
            # processing happened, so retrying it is always safe. 503 is
            # different specifically for POST - the server may have already
            # created the resource before the response was lost in transit,
            # and retrying could then create a duplicate (a second app
            # registration, a second group, etc). GET/PUT/PATCH/DELETE don't
            # have this risk, since repeating them with the same body
            # produces the same end state no matter how many times it's
            # applied.
            $safeToRetryTransient = $isTransient -and $Method -ne "POST"
            if (($isThrottled -or $safeToRetryTransient) -and $attempt -lt $maxAttempts) {
                $waitSeconds = $attempt * $attempt * 3   # 3s, 12s, 27s
                $reason = if ($isThrottled) { "Rate-limited" } else { "Service temporarily unavailable" }
                Write-Host "  [!] $reason - waiting ${waitSeconds}s before retry $($attempt+1)/$maxAttempts..." -ForegroundColor Yellow
                Start-Sleep -Seconds $waitSeconds
                continue
            }
            $detail = Get-HttpErrorDetail -ErrorRecord $_
            $msg = "$StepDescription failed [$Method $Uri]: $($_.Exception.Message)"
            if ($detail) { $msg += "`nResponse body: $detail" }
            throw $msg
        }
    }
}

# Same idea for the raw Invoke-WebRequest calls used for the Azure Storage
# block blob upload.
function Invoke-WebRequestDetailed {
    param(
        [Parameter(Mandatory=$true)][string]$Uri,
        [string]$Method = "GET",
        $Body = $null,
        [hashtable]$Headers = $null,
        [string]$ContentType = $null,
        [int]$TimeoutSec = 120,
        [Parameter(Mandatory=$true)][string]$StepDescription
    )
    try {
        # -UseBasicParsing is essential here, not optional: without it,
        # Invoke-WebRequest tries to parse the response using Internet
        # Explorer's engine (COM/MSHTML). On a machine where IE has never
        # been through its first-run setup, that throws an interactive
        # "Security Warning: Script Execution Risk... Do you want to
        # continue? [Y/N]" console prompt - which then hangs forever in a
        # hidden/non-interactive process, since nothing can ever answer it.
        # This is why successful responses (which get parsed) hung while
        # fast-failing error responses (which skip parsing) didn't.
        $params = @{ Uri = $Uri; Method = $Method; ErrorAction = "Stop"; TimeoutSec = $TimeoutSec; UseBasicParsing = $true }
        if ($null -ne $Body) { $params.Body = $Body }
        if ($Headers) { $params.Headers = $Headers }
        if ($ContentType) { $params.ContentType = $ContentType }
        return Invoke-WebRequest @params
    }
    catch {
        $detail = Get-HttpErrorDetail -ErrorRecord $_
        $msg = "$StepDescription failed [$Method $Uri]: $($_.Exception.Message)"
        if ($detail) { $msg += "`nResponse body: $detail" }
        throw $msg
    }
}

# Reads a .intunewin package's embedded encryption metadata (already baked in
# by IntuneWinAppUtil - this just parses what's there, no encryption work of
# our own) and extracts the encrypted content blob to a temp file ready for
# upload. Used by both Create mode (new app) and Update mode's optional
# content-replace path (existing app), so the two never have their own
# separate, potentially-diverging copies of this logic.
function Get-IntuneWinPackageInfo {
    param([Parameter(Mandatory=$true)][string]$PackagePath)

    Write-Step "Reading package: $PackagePath"
    if (-not (Test-Path $PackagePath)) {
        throw "Package file not found: $PackagePath"
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($PackagePath)
    try {
        $detectionEntry = $zip.Entries | Where-Object { $_.FullName -match 'Detection\.xml$' } | Select-Object -First 1
        if (-not $detectionEntry) { throw "Detection.xml not found inside the .intunewin package - is this a valid IntuneWinAppUtil output file?" }

        $reader = New-Object System.IO.StreamReader($detectionEntry.Open())
        $xmlText = $reader.ReadToEnd()
        $reader.Close()

        # Strip the default XML namespace so plain dot-notation property access works
        $xmlText = $xmlText -replace 'xmlns="[^"]*"', ''
        [xml]$detectionXml = $xmlText
        $appInfo = $detectionXml.ApplicationInfo

        $unencryptedSize = [int64]$appInfo.UnencryptedContentSize
        $contentFileName = [string]$appInfo.FileName
        $setupFile       = [string]$appInfo.SetupFile
        Write-Host "  Setup file      : $setupFile" -ForegroundColor Gray
        Write-Host "  Unencrypted size: $unencryptedSize bytes" -ForegroundColor Gray

        $encInfo = $appInfo.EncryptionInfo
        $fileEncryptionInfo = @{
            encryptionKey         = [string]$encInfo.EncryptionKey
            macKey                = [string]$encInfo.MacKey
            initializationVector  = [string]$encInfo.InitializationVector
            mac                   = [string]$encInfo.Mac
            profileIdentifier     = [string]$encInfo.ProfileIdentifier
            fileDigest             = [string]$encInfo.FileDigest
            fileDigestAlgorithm    = [string]$encInfo.FileDigestAlgorithm
        }

        # Extract the encrypted content file to a temp location for upload
        $contentEntry = $zip.Entries | Where-Object { $_.FullName -match [regex]::Escape($contentFileName) + '$' } | Select-Object -First 1
        if (-not $contentEntry) { throw "Encrypted content file '$contentFileName' not found inside the package." }

        $tempEncryptedPath = Join-Path $env:TEMP ("itsense_upload_" + [guid]::NewGuid().ToString("N") + ".bin")
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($contentEntry, $tempEncryptedPath)
        $encryptedSize = (Get-Item $tempEncryptedPath).Length
        Write-Host "  Encrypted size  : $encryptedSize bytes" -ForegroundColor Gray
    }
    finally {
        $zip.Dispose()
    }

    return [pscustomobject]@{
        UnencryptedSize    = $unencryptedSize
        EncryptedSize      = $encryptedSize
        ContentFileName    = $contentFileName
        SetupFile          = $setupFile
        FileEncryptionInfo = $fileEncryptionInfo
        TempEncryptedPath  = $tempEncryptedPath
        OriginalFileName   = [System.IO.Path]::GetFileName($PackagePath)
    }
}

# Uploads a package (already read via Get-IntuneWinPackageInfo) as a new
# content version on an EXISTING app object - works identically whether that
# app was just created moments ago (Create mode) or already existed and is
# just getting new content pushed to it (Update mode's replace-content path).
function Invoke-Win32AppContentUpload {
    param(
        [Parameter(Mandatory=$true)][string]$AppId,
        [Parameter(Mandatory=$true)]$PackageInfo
    )

    Write-Step "Creating content version"
    $cv = Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$AppId/microsoft.graph.win32LobApp/contentVersions" `
        -Method POST -Body "{}" -ContentType "application/json" -StepDescription "Create content version"
    $cvId = $cv.id
    Write-Host "  [OK] Content version: $cvId" -ForegroundColor Green

    Write-Step "Registering package file with Intune"
    $fileBody = @{
        "@odata.type" = "#microsoft.graph.mobileAppContentFile"
        name          = $PackageInfo.ContentFileName
        size          = $PackageInfo.UnencryptedSize
        sizeEncrypted = $PackageInfo.EncryptedSize
        manifest      = $null
        isDependency  = $false
    } | ConvertTo-Json -Depth 8

    $fileObj = Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$AppId/microsoft.graph.win32LobApp/contentVersions/$cvId/files" `
        -Method POST -Body $fileBody -ContentType "application/json" -StepDescription "Register package file"
    $fileId = $fileObj.id
    Write-Host "  [OK] File entry: $fileId" -ForegroundColor Green

    Write-Step "Waiting for Azure Storage upload URL"
    $azureStorageUri = $null
    $attempts = 0
    while ($attempts -lt 60) {
        Start-Sleep -Seconds 2
        $attempts++
        $fileStatus = Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$AppId/microsoft.graph.win32LobApp/contentVersions/$cvId/files/$fileId" -Method GET -StepDescription "Poll for Azure Storage URI"
        if ($fileStatus.uploadState -eq "azureStorageUriRequestSuccess") {
            $azureStorageUri = $fileStatus.azureStorageUri
            break
        }
        elseif ($fileStatus.uploadState -like "*Failed*") {
            throw "Azure Storage URI request failed: $($fileStatus.uploadState)"
        }
        Write-Host "  ... waiting ($($fileStatus.uploadState))" -ForegroundColor DarkGray
    }
    if (-not $azureStorageUri) { throw "Timed out waiting for Azure Storage URI." }
    Write-Host "  [OK] Got upload URL." -ForegroundColor Green

    # Graph itself (graph.microsoft.com) working does NOT guarantee Azure Blob
    # Storage (a completely different domain, *.blob.core.windows.net) is
    # reachable too - some corporate firewalls/proxies allow one and not the
    # other. This is a fast (max ~8s) raw TCP check, so a blocked path fails
    # in seconds instead of only becoming apparent after the full upload
    # timeout expires.
    $storageHost = ([Uri]$azureStorageUri).Host
    Write-Host "  Storage host: $storageHost" -ForegroundColor Gray
    Write-Host "  Checking connectivity to $storageHost`:443..." -ForegroundColor Gray
    $reachable = $false
    try {
        $tcpClient = New-Object System.Net.Sockets.TcpClient
        $connectTask = $tcpClient.ConnectAsync($storageHost, 443)
        $reachable = $connectTask.Wait(8000) -and $tcpClient.Connected
        $tcpClient.Close()
    } catch { $reachable = $false }

    if ($reachable) {
        Write-Host "  [OK] $storageHost is reachable." -ForegroundColor Green
    }
    else {
        Write-Host "  [WARNING] Could not open a TCP connection to $storageHost on port 443 within 8 seconds." -ForegroundColor Yellow
        Write-Host "  Microsoft Graph worked fine, but Azure Blob Storage is a different domain - this strongly suggests" -ForegroundColor Yellow
        Write-Host "  a firewall or proxy is blocking outbound HTTPS to it. Ask your network team to allow" -ForegroundColor Yellow
        Write-Host "  *.blob.core.windows.net (or specifically $storageHost). Attempting the upload anyway..." -ForegroundColor Yellow
    }

    Write-Step "Uploading package content"
    $blockSize = 6 * 1024 * 1024
    $bytes = [System.IO.File]::ReadAllBytes($PackageInfo.TempEncryptedPath)
    $totalBlocks = [Math]::Ceiling($bytes.Length / $blockSize)
    $blockIds = New-Object System.Collections.Generic.List[string]

    for ($b = 0; $b -lt $totalBlocks; $b++) {
        $offset = $b * $blockSize
        $len = [Math]::Min($blockSize, $bytes.Length - $offset)
        $chunk = New-Object byte[] $len
        [Array]::Copy($bytes, $offset, $chunk, 0, $len)

        $blockIdRaw = [string]$b
        $blockIdPadded = $blockIdRaw.PadLeft(20, '0')
        $blockId = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($blockIdPadded))
        $blockIds.Add($blockId)

        $blockUri = "$azureStorageUri&comp=block&blockid=$([Uri]::EscapeDataString($blockId))"
        Write-Host "  ... attempting block $($b + 1) of $totalBlocks ($len bytes)..." -ForegroundColor DarkGray
        Invoke-WebRequestDetailed -Uri $blockUri -Method PUT -Body $chunk -Headers @{ "x-ms-blob-type" = "BlockBlob" } -TimeoutSec 60 -StepDescription "Upload block $($b + 1) of $totalBlocks" | Out-Null
        Write-Host "  ... block $($b + 1) of $totalBlocks uploaded" -ForegroundColor DarkGray
    }

    $blockListXml = "<?xml version=`"1.0`" encoding=`"utf-8`"?><BlockList>"
    foreach ($id in $blockIds) { $blockListXml += "<Latest>$id</Latest>" }
    $blockListXml += "</BlockList>"
    $commitBlocksUri = "$azureStorageUri&comp=blocklist"
    Invoke-WebRequestDetailed -Uri $commitBlocksUri -Method PUT -Body $blockListXml -ContentType "text/plain" -StepDescription "Commit block list to storage" | Out-Null
    Write-Host "  [OK] All $totalBlocks block(s) uploaded and committed to storage." -ForegroundColor Green

    Remove-Item $PackageInfo.TempEncryptedPath -Force -ErrorAction SilentlyContinue

    Write-Step "Committing file"
    $commitBody = @{ fileEncryptionInfo = $PackageInfo.FileEncryptionInfo } | ConvertTo-Json -Depth 8
    Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$AppId/microsoft.graph.win32LobApp/contentVersions/$cvId/files/$fileId/commit" `
        -Method POST -Body $commitBody -ContentType "application/json" -StepDescription "Commit file" | Out-Null

    $attempts = 0
    $committed = $false
    while ($attempts -lt 60) {
        Start-Sleep -Seconds 2
        $attempts++
        $fileStatus = Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$AppId/microsoft.graph.win32LobApp/contentVersions/$cvId/files/$fileId" -Method GET -StepDescription "Poll for file commit"
        if ($fileStatus.uploadState -eq "commitFileSuccess") { $committed = $true; break }
        elseif ($fileStatus.uploadState -like "*Failed*") { throw "File commit failed: $($fileStatus.uploadState)" }
        Write-Host "  ... waiting ($($fileStatus.uploadState))" -ForegroundColor DarkGray
    }
    if (-not $committed) { throw "Timed out waiting for file commit." }
    Write-Host "  [OK] File committed." -ForegroundColor Green

    Write-Step "Finalizing app"
    $finalizeBody = @{ "@odata.type" = "#microsoft.graph.win32LobApp"; committedContentVersion = $cvId } | ConvertTo-Json -Depth 8
    Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$AppId" `
        -Method PATCH -Body $finalizeBody -ContentType "application/json" -StepDescription "Finalize app (set committedContentVersion)" | Out-Null
    Write-Host "  [OK] App content is now active." -ForegroundColor Green
}

Write-Step "Loading configuration"
if (-not (Test-Path $ConfigPath)) {
    Write-Host "[ERROR] Config file not found: $ConfigPath" -ForegroundColor Red
    exit 1
}
$Config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
Write-Host "  App: $($Config.AppName)" -ForegroundColor Gray
Write-Host "  Mode: $($Config.Mode)" -ForegroundColor Gray

try {
    Write-Step "Connecting to Microsoft Graph (app-only, certificate)"
    if (-not $Config.TenantId -or -not $Config.ClientId -or -not $Config.CertificateThumbprint) {
        throw "No Graph connection is configured. Open 'Settings...' in the GUI and fill in your Tenant ID, Client ID, and certificate first."
    }
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    $ctx = Get-MgContext -ErrorAction SilentlyContinue
    if ($null -eq $ctx -or $ctx.AuthType -ne 'AppOnly' -or $ctx.ClientId -ne $Config.ClientId) {
        Connect-MgGraph -TenantId $Config.TenantId -ClientId $Config.ClientId `
            -CertificateThumbprint $Config.CertificateThumbprint -NoWelcome -ErrorAction Stop
    }
    $ctx = Get-MgContext -ErrorAction Stop
    Write-Host "  [OK] Connected as '$($ctx.AppName)'" -ForegroundColor Green

    # =====================================================================
    # Detection rule (used in both Create and UpdateMetadata modes) - built
    # per the actual selected type. Schema for each type confirmed against
    # Microsoft's own documentation (win32LobAppProductCodeDetection,
    # win32LobAppFileSystemDetection, win32LobAppRegistryDetection) before
    # writing this, given past mistakes guessing at Graph property names
    # elsewhere in this script.
    # =====================================================================
    $detType = $Config.DetectionRule.Type
    switch ($detType) {
        "Msi" {
            $detectionRule = @{
                "@odata.type"           = "#microsoft.graph.win32LobAppProductCodeDetection"
                productCode             = $Config.DetectionRule.Msi_ProductCode
                productVersionOperator  = $Config.DetectionRule.Msi_VersionOperator
            }
            if ($Config.DetectionRule.Msi_VersionOperator -ne "notConfigured" -and $Config.DetectionRule.Msi_Version) {
                $detectionRule.productVersion = $Config.DetectionRule.Msi_Version
            }
        }
        "File" {
            $detectionRule = @{
                "@odata.type"          = "#microsoft.graph.win32LobAppFileSystemDetection"
                path                    = $Config.DetectionRule.File_Path
                fileOrFolderName        = $Config.DetectionRule.File_Name
                check32BitOn64System    = [bool]$Config.DetectionRule.File_Check32Bit
                detectionType           = $Config.DetectionRule.File_DetectionType
            }
            if ($Config.DetectionRule.File_DetectionType -in @("modifiedDate", "createdDate", "version", "sizeInMB")) {
                $detectionRule.operator = $Config.DetectionRule.File_Operator
                $detectionRule.detectionValue = $Config.DetectionRule.File_DetectionValue
            }
        }
        "Registry" {
            $detectionRule = @{
                "@odata.type"          = "#microsoft.graph.win32LobAppRegistryDetection"
                keyPath                 = $Config.DetectionRule.Reg_KeyPath
                check32BitOn64System    = [bool]$Config.DetectionRule.Reg_Check32Bit
                detectionType           = $Config.DetectionRule.Reg_DetectionType
            }
            if ($Config.DetectionRule.Reg_ValueName) { $detectionRule.valueName = $Config.DetectionRule.Reg_ValueName }
            if ($Config.DetectionRule.Reg_DetectionType -in @("string", "integer", "version")) {
                $detectionRule.operator = $Config.DetectionRule.Reg_Operator
                $detectionRule.detectionValue = $Config.DetectionRule.Reg_DetectionValue
            }
        }
        default {
            $detectionRule = @{
                "@odata.type"          = "#microsoft.graph.win32LobAppPowerShellScriptDetection"
                scriptContent          = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Config.DetectionRule.Script_Content))
                enforceSignatureCheck  = $false
                runAs32Bit             = $false
            }
        }
    }

    # =====================================================================
    # UPDATE METADATA MODE - existing app, no content re-upload
    # =====================================================================
    if ($Config.Mode -eq "UpdateMetadata") {
        Write-Step "Updating metadata for existing app $($Config.ExistingAppId)"

        # Only installExperience.runAsAccount (install context) is actually
        # excluded here - confirmed rejected by Graph specifically
        # ("The 'RunAsAccount' property cannot be patched for the
        # 'Win32LobApp' type."). Architecture, min OS, requirements, return
        # codes, and the rest of installExperience were PREVIOUSLY also
        # excluded here too, based on an unverified assumption that they'd
        # behave the same way runAsAccount does - but that assumption was
        # wrong. Confirmed otherwise, directly: Microsoft's own "Update
        # win32LobApp" PATCH documentation example explicitly includes
        # applicableArchitectures and the requirement fields, an official
        # Microsoft sample script (mggraph-intune-samples) successfully
        # PATCHes deviceRestartBehavior as part of installExperience, and
        # the Intune portal itself shows "Requirements" and "Detection
        # rules" as directly editable sections on an existing app. The GUI
        # only disables the Install context control now, not
        # Architecture/Min OS/Requirements/etc.
        # installExperience is a nested complex object, not a simple
        # collection - Graph likely replaces the WHOLE object on PATCH
        # rather than merging field-by-field (the same class of risk
        # already learned the hard way with relationships/updateRelationships
        # earlier this session). runAsAccount is explicitly included here,
        # even though the GUI keeps it locked/read-only, specifically so
        # this patch preserves its current value rather than risking Graph
        # silently resetting it just because it wasn't in this particular
        # request - matching how the official Microsoft sample script
        # includes it in its own installExperience patch for the same
        # reason. $Config.InstallContext still accurately reflects the
        # live value even though the control is locked, since the dialog's
        # auto-fetch populates it from Intune regardless of editability.
        $installExperiencePatch = @{
            runAsAccount          = if ($Config.InstallContext -eq "User") { "user" } else { "system" }
            deviceRestartBehavior = if ($Config.DeviceRestartBehavior) { $Config.DeviceRestartBehavior } else { "suppress" }
            maxRunTimeInMinutes   = if ($Config.InstallTimeMinutes) { [int]$Config.InstallTimeMinutes } else { 60 }
        }
        $returnCodesPatch = if (@($Config.ReturnCodes).Count -gt 0) {
            @($Config.ReturnCodes | ForEach-Object { @{ returnCode = [int]$_.returnCode; type = [string]$_.type } })
        } else {
            @(
                @{ returnCode = 0;    type = "success" }
                @{ returnCode = 1707; type = "success" }
                @{ returnCode = 3010; type = "softReboot" }
                @{ returnCode = 1641; type = "hardReboot" }
                @{ returnCode = 1618; type = "retry" }
            )
        }
        $patchBody = @{
            "@odata.type"             = "#microsoft.graph.win32LobApp"
            displayName               = $Config.AppName
            description               = $Config.Description
            publisher                 = $Config.Publisher
            installCommandLine        = $Config.InstallCommand
            uninstallCommandLine      = $Config.UninstallCommand
            detectionRules            = @($detectionRule)
            installExperience         = $installExperiencePatch
            returnCodes               = $returnCodesPatch
            minimumFreeDiskSpaceInMB  = if ($Config.MinDiskSpaceMB) { [int]$Config.MinDiskSpaceMB } else { 0 }
            minimumMemoryInMB         = if ($Config.MinMemoryMB) { [int]$Config.MinMemoryMB } else { 0 }
            minimumNumberOfProcessors = if ($Config.MinProcessors) { [int]$Config.MinProcessors } else { 0 }
            minimumCpuSpeedInMHz      = if ($Config.MinCpuSpeedMHz) { [int]$Config.MinCpuSpeedMHz } else { 0 }
            allowAvailableUninstall   = [bool]$Config.AllowAvailableUninstall
        }
        $minOSPatch = @{ $Config.MinOSVersionKey = $true }
        $patchBody.minimumSupportedOperatingSystem = $minOSPatch
        # Same rule already established and fixed once this session for
        # Create mode - applicableArchitectures can only hold a single
        # value; multiple architectures go through allowedArchitectures
        # instead, which forces applicableArchitectures to "none" as a
        # side effect on the server's own side.
        if ($Config.Architecture -match ',') {
            $patchBody.allowedArchitectures = $Config.Architecture
        }
        else {
            $patchBody.applicableArchitectures = $Config.Architecture
        }
        Add-OptionalStringField -Body $patchBody -GraphKey "owner" -Value $Config.Owner
        Add-OptionalStringField -Body $patchBody -GraphKey "developer" -Value $Config.Developer
        Add-OptionalStringField -Body $patchBody -GraphKey "informationUrl" -Value $Config.InformationUrl
        Add-OptionalStringField -Body $patchBody -GraphKey "privacyInformationUrl" -Value $Config.PrivacyUrl
        Add-OptionalStringField -Body $patchBody -GraphKey "notes" -Value $Config.Notes
        $patchBody = $patchBody | ConvertTo-Json -Depth 8

        Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($Config.ExistingAppId)" `
            -Method PATCH -Body $patchBody -ContentType "application/json" -StepDescription "Update app metadata" | Out-Null
        Write-Host "  [OK] Metadata updated (name, description, publisher, install/uninstall commands, detection, architecture, min OS, requirements, return codes, install experience, and any owner/developer/notes/URL fields you filled in)." -ForegroundColor Green

        # Always runs, even with zero dependencies checked - updateRelationships
        # has REPLACE semantics (it sets the relationship list to exactly what's
        # sent, not add-only), so this is the only way to actually clear the
        # LAST remaining dependency. Gating this behind "Count -gt 0" would
        # silently leave a stale dependency in place forever whenever someone
        # unchecks the one and only dependency an app has.
        Write-Step "Setting dependencies"
        try {
            $relationships = @($Config.DependencyAppIds | ForEach-Object {
                @{ "@odata.type" = "#microsoft.graph.mobileAppDependency"; targetId = $_; dependencyType = "autoInstall" }
            })
            $relBody = @{ relationships = $relationships } | ConvertTo-Json -Depth 8
            Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($Config.ExistingAppId)/updateRelationships" `
                -Method POST -Body $relBody -ContentType "application/json" -StepDescription "Set dependencies" | Out-Null
            Write-Host "  [OK] Set $(@($Config.DependencyAppIds).Count) dependency/dependencies." -ForegroundColor Green
        }
        catch {
            Write-Host "  [WARNING] Could not set dependencies: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host "  The app was still updated successfully - set dependencies manually in the Intune portal if needed." -ForegroundColor Yellow
            }

        if ($Config.ReplaceContent -and $Config.PackagePath) {
            Write-Step "Replacing package content on the existing app"
            $packageInfo = Get-IntuneWinPackageInfo -PackagePath $Config.PackagePath
            Invoke-Win32AppContentUpload -AppId $Config.ExistingAppId -PackageInfo $packageInfo
        }

        Write-Step "Done"
        Write-Host "[OK] App metadata updated successfully!" -ForegroundColor Green
        Write-Result -Success $true -AppId $Config.ExistingAppId -ErrorMessage ""
        exit 0
    }

    # =====================================================================
    # CREATE MODE
    # =====================================================================

    $packageInfo = Get-IntuneWinPackageInfo -PackagePath $Config.PackagePath

    # ---- Create the app shell ----
    Write-Step "Creating app in Intune: $($Config.AppName)"

    $installExperience = @{
        runAsAccount            = if ($Config.InstallContext -eq "User") { "user" } else { "system" }
        # Falls back to "suppress" only if this field is somehow missing -
        # older configs built before this was exposed in the UI, or a
        # config built through some other path - rather than requiring
        # every single caller to always set it.
        deviceRestartBehavior   = if ($Config.DeviceRestartBehavior) { $Config.DeviceRestartBehavior } else { "suppress" }
        maxRunTimeInMinutes     = if ($Config.InstallTimeMinutes) { [int]$Config.InstallTimeMinutes } else { 60 }
    }

    $minOS = @{ $Config.MinOSVersionKey = $true }

    # Falls back to the original fixed 5-code set if this wasn't supplied -
    # same reasoning as deviceRestartBehavior above.
    $returnCodesPayload = if (@($Config.ReturnCodes).Count -gt 0) {
        @($Config.ReturnCodes | ForEach-Object { @{ returnCode = [int]$_.returnCode; type = [string]$_.type } })
    } else {
        @(
            @{ returnCode = 0;    type = "success" }
            @{ returnCode = 1707; type = "success" }
            @{ returnCode = 3010; type = "softReboot" }
            @{ returnCode = 1641; type = "hardReboot" }
            @{ returnCode = 1618; type = "retry" }
        )
    }

    $createBody = @{
        "@odata.type"                    = "#microsoft.graph.win32LobApp"
        displayName                       = $Config.AppName
        description                       = $Config.Description
        publisher                          = $Config.Publisher
        installCommandLine                = $Config.InstallCommand
        uninstallCommandLine              = $Config.UninstallCommand
        minimumSupportedOperatingSystem   = $minOS
        installExperience                 = $installExperience
        setupFilePath                     = $packageInfo.SetupFile
        fileName                          = $packageInfo.OriginalFileName
        detectionRules                    = @($detectionRule)
        returnCodes                       = $returnCodesPayload
        # Confirmed directly against Microsoft's own win32LobApp docs - all
        # four are top-level Int32 fields, 0 meaning "not required" (matches
        # the portal's own "No X required" wording for an unset value), and
        # allowAvailableUninstall is a top-level boolean defaulting to false.
        minimumFreeDiskSpaceInMB          = if ($Config.MinDiskSpaceMB) { [int]$Config.MinDiskSpaceMB } else { 0 }
        minimumMemoryInMB                 = if ($Config.MinMemoryMB) { [int]$Config.MinMemoryMB } else { 0 }
        minimumNumberOfProcessors         = if ($Config.MinProcessors) { [int]$Config.MinProcessors } else { 0 }
        minimumCpuSpeedInMHz              = if ($Config.MinCpuSpeedMHz) { [int]$Config.MinCpuSpeedMHz } else { 0 }
        allowAvailableUninstall           = [bool]$Config.AllowAvailableUninstall
    }
    # Confirmed directly from Microsoft's own win32LobApp docs:
    # applicableArchitectures can only hold a SINGLE value (none/x86/x64/
    # arm/neutral/arm64), not a comma-joined list - multiple architectures
    # are represented via the separate allowedArchitectures property
    # instead, and setting that forces applicableArchitectures to the
    # literal "none" as a side effect on the server's own side. Sending
    # both, or a comma-joined value into the wrong one, isn't correct - so
    # exactly one of these two gets set here, chosen by whether more than
    # one architecture was actually selected.
    if ($Config.Architecture -match ',') {
        $createBody.allowedArchitectures = $Config.Architecture
    }
    else {
        $createBody.applicableArchitectures = $Config.Architecture
    }
    Add-OptionalStringField -Body $createBody -GraphKey "owner" -Value $Config.Owner
    Add-OptionalStringField -Body $createBody -GraphKey "developer" -Value $Config.Developer
    Add-OptionalStringField -Body $createBody -GraphKey "informationUrl" -Value $Config.InformationUrl
    Add-OptionalStringField -Body $createBody -GraphKey "privacyInformationUrl" -Value $Config.PrivacyUrl
    Add-OptionalStringField -Body $createBody -GraphKey "notes" -Value $Config.Notes
    $createBody = $createBody | ConvertTo-Json -Depth 8

    $app = Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps" `
        -Method POST -Body $createBody -ContentType "application/json" -StepDescription "Create app"
    $appId = $app.id
    Write-Host "  [OK] App created: $appId" -ForegroundColor Green

    Invoke-Win32AppContentUpload -AppId $appId -PackageInfo $packageInfo

    # ---- Dependencies ----
    if (@($Config.DependencyAppIds).Count -gt 0) {
        Write-Step "Setting dependencies"
        try {
            $relationships = @($Config.DependencyAppIds | ForEach-Object {
                @{ "@odata.type" = "#microsoft.graph.mobileAppDependency"; targetId = $_; dependencyType = "autoInstall" }
            })
            $relBody = @{ relationships = $relationships } | ConvertTo-Json -Depth 8
            Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$appId/updateRelationships" `
                -Method POST -Body $relBody -ContentType "application/json" -StepDescription "Set dependencies" | Out-Null
            Write-Host "  [OK] Set $(@($Config.DependencyAppIds).Count) dependency/dependencies." -ForegroundColor Green
        }
        catch {
            Write-Host "  [WARNING] Could not set dependencies: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host "  The app and its content uploaded successfully - set dependencies manually in the Intune portal if needed." -ForegroundColor Yellow
        }
    }

    Write-Step "Done"
    Write-Host "[OK] App created and content uploaded successfully!" -ForegroundColor Green
    Write-Host "     App ID: $appId" -ForegroundColor White
    Write-Result -Success $true -AppId $appId -ErrorMessage ""
    exit 0
}
catch {
    Write-Host ""
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    Write-Result -Success $false -AppId "" -ErrorMessage $_.Exception.Message
    exit 1
}

'@

$Script:EmbeddedTargetedAssignScript = @'
<#
.SYNOPSIS
    Targeted, single-app version of what 5_AssignGroupsAndNames.ps1 does for
    the whole catalog: ensures the Entra ID groups an app's requiredFor/
    availableFor/uninstallFor reference actually exist, then sets that ONE
    app's Intune assignments to match exactly - Required, Available, and
    Uninstall. Does not touch group membership or any other app.
.DESCRIPTION
    Reads a JSON config (written by the GUI) with the app's Intune App ID and
    its three group-name lists. For each distinct group name across all three
    lists, creates a Microsoft 365 security group with that display name if
    one doesn't already exist (idempotent - existing groups are left alone).
    Then replaces the app's assignment list in Intune with exactly the groups
    named, one assignment per group per intent.
    Writes a result JSON (success/groupsCreated/error) to -OutputResultPath.
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$ConfigPath
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[System.Net.ServicePointManager]::Expect100Continue = $false

function Write-Step {
    param([string]$Text)
    Write-Host ""
    Write-Host "=== $Text ===" -ForegroundColor Cyan
}

function Write-Result {
    param([bool]$Success, [int]$GroupsCreated, [string]$ErrorMessage)
    $result = [pscustomobject]@{
        success       = $Success
        groupsCreated = $GroupsCreated
        error         = $ErrorMessage
    }
    $result | ConvertTo-Json | Set-Content -Path $Config.OutputResultPath -Encoding UTF8
}

function Get-HttpErrorDetail {
    param($ErrorRecord)
    $detail = $ErrorRecord.ErrorDetails.Message
    if ($detail) { return $detail }
    try {
        if ($ErrorRecord.Exception.Response) {
            $stream = $ErrorRecord.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)
            $body = $reader.ReadToEnd()
            $reader.Close()
            if ($body) { return $body }
        }
    } catch { }
    return $null
}

function Invoke-GraphRequestDetailed {
    param(
        [Parameter(Mandatory=$true)][string]$Uri,
        [string]$Method = "GET",
        [string]$Body = $null,
        [string]$ContentType = "application/json",
        [Parameter(Mandatory=$true)][string]$StepDescription
    )
    $maxAttempts = 4
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            if ($Body) {
                return Invoke-MgGraphRequest -Uri $Uri -Method $Method -Body $Body -ContentType $ContentType -ErrorAction Stop
            }
            else {
                return Invoke-MgGraphRequest -Uri $Uri -Method $Method -ErrorAction Stop
            }
        }
        catch {
            # Graph rate-limits (429) or has brief service hiccups (503) far
            # more often during bulk operations working through many items
            # in a row than on a single one-off call - retrying with
            # backoff instead of immediately failing the whole run on the
            # first blip. Detected from the exception TEXT rather than a
            # structured status-code property, since this cmdlet's own
            # exceptions have already been confirmed elsewhere in this app
            # to carry the status as readable text (e.g. "BadRequest (Bad
            # Request)") rather than a reliably-populated .Response object.
            $isThrottled = $_.Exception.Message -match '429|TooManyRequests|Too Many Requests'
            $isTransient = $_.Exception.Message -match '503|ServiceUnavailable|Service Unavailable'
            # 429 always means the request was rejected BEFORE any
            # processing happened, so retrying it is always safe. 503 is
            # different specifically for POST - the server may have already
            # created the resource before the response was lost in transit,
            # and retrying could then create a duplicate (a second app
            # registration, a second group, etc). GET/PUT/PATCH/DELETE don't
            # have this risk, since repeating them with the same body
            # produces the same end state no matter how many times it's
            # applied.
            $safeToRetryTransient = $isTransient -and $Method -ne "POST"
            if (($isThrottled -or $safeToRetryTransient) -and $attempt -lt $maxAttempts) {
                $waitSeconds = $attempt * $attempt * 3   # 3s, 12s, 27s
                $reason = if ($isThrottled) { "Rate-limited" } else { "Service temporarily unavailable" }
                Write-Host "  [!] $reason - waiting ${waitSeconds}s before retry $($attempt+1)/$maxAttempts..." -ForegroundColor Yellow
                Start-Sleep -Seconds $waitSeconds
                continue
            }
            $detail = Get-HttpErrorDetail -ErrorRecord $_
            $msg = "$StepDescription failed [$Method $Uri]: $($_.Exception.Message)"
            if ($detail) { $msg += "`nResponse body: $detail" }
            throw $msg
        }
    }
}

Write-Step "Loading configuration"
if (-not (Test-Path $ConfigPath)) {
    Write-Host "[ERROR] Config file not found: $ConfigPath" -ForegroundColor Red
    exit 1
}
$Config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
Write-Host "  App ID: $($Config.AppId)" -ForegroundColor Gray
Write-Host "  Required groups : $(@($Config.RequiredGroups).Count)" -ForegroundColor Gray
Write-Host "  Available groups: $(@($Config.AvailableGroups).Count)" -ForegroundColor Gray
Write-Host "  Uninstall groups: $(@($Config.UninstallGroups).Count)" -ForegroundColor Gray

try {
    Write-Step "Connecting to Microsoft Graph (app-only, certificate)"
    if (-not $Config.TenantId -or -not $Config.ClientId -or -not $Config.CertificateThumbprint) {
        throw "No Graph connection is configured. Open 'Settings...' in the GUI and fill in your Tenant ID, Client ID, and certificate first."
    }
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    $ctx = Get-MgContext -ErrorAction SilentlyContinue
    if ($null -eq $ctx -or $ctx.AuthType -ne 'AppOnly' -or $ctx.ClientId -ne $Config.ClientId) {
        Connect-MgGraph -TenantId $Config.TenantId -ClientId $Config.ClientId `
            -CertificateThumbprint $Config.CertificateThumbprint -NoWelcome -ErrorAction Stop
    }
    Write-Host "  [OK] Connected." -ForegroundColor Green

    # ---- Ensure every referenced group exists ----
    Write-Step "Ensuring groups exist"
    $allGroupNames = @($Config.RequiredGroups) + @($Config.AvailableGroups) + @($Config.UninstallGroups) | Select-Object -Unique
    $groupIdByName = @{}
    $createdCount = 0

    foreach ($groupName in $allGroupNames) {
        if ([string]::IsNullOrWhiteSpace($groupName)) { continue }
        $escapedName = $groupName.Replace("'", "''")
        # The filter VALUE must be percent-encoded, not just quote-escaped -
        # a raw & (e.g. in "Deploy I&O Workplace") gets parsed by the server
        # as a query-string separator otherwise, silently truncating the
        # filter clause mid-value and producing a confusing 400 error.
        $encodedFilter = [Uri]::EscapeDataString("displayName eq '$escapedName'")
        $existing = Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=$encodedFilter&`$select=id,displayName" -Method GET -StepDescription "Look up group '$groupName'"
        if ($existing.value -and $existing.value.Count -gt 0) {
            $groupIdByName[$groupName] = $existing.value[0].id
            Write-Host "  [=] Exists: $groupName" -ForegroundColor DarkGray
        }
        else {
            $mailNickname = ($groupName -replace '[^a-zA-Z0-9]', '')
            if ($mailNickname.Length -gt 60) { $mailNickname = $mailNickname.Substring(0, 60) }
            if ([string]::IsNullOrWhiteSpace($mailNickname)) { $mailNickname = "grp" + (Get-Random -Minimum 1000 -Maximum 9999) }
            $groupBody = @{
                displayName     = $groupName
                mailEnabled     = $false
                mailNickname    = $mailNickname
                securityEnabled = $true
                "@odata.type"   = "#microsoft.graph.group"
            } | ConvertTo-Json -Depth 5
            $newGroup = Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/v1.0/groups" -Method POST -Body $groupBody -StepDescription "Create group '$groupName'"
            $groupIdByName[$groupName] = $newGroup.id
            $createdCount++
            Write-Host "  [+] Created: $groupName" -ForegroundColor Green
        }
    }

    # ---- Show current assignments before changing anything ----
    Write-Step "Checking current assignments (before making any change)"
    $currentAssignments = Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($Config.AppId)/assignments" -Method GET -StepDescription "Get current assignments"
    $currentByGroup = @{}   # groupId -> intent, for groups only (skips allDevices/allLicensedUsers targets)
    foreach ($a in @($currentAssignments.value)) {
        $targetType = $a.target.'@odata.type'
        if ($targetType -eq '#microsoft.graph.groupAssignmentTarget') {
            $gid = $a.target.groupId
            $groupDisplayName = $gid
            try {
                $groupInfo = Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/v1.0/groups/$gid`?`$select=displayName" -Method GET -StepDescription "Resolve current assignment's group name"
                if ($groupInfo.displayName) { $groupDisplayName = $groupInfo.displayName }
            } catch { }
            $currentByGroup[$groupDisplayName] = $a.intent
            Write-Host "  currently: [$($a.intent)] $groupDisplayName" -ForegroundColor Gray
        }
        else {
            Write-Host "  currently: [$($a.intent)] (non-group target: $targetType)" -ForegroundColor Gray
        }
    }
    if (@($currentAssignments.value).Count -eq 0) {
        Write-Host "  (no existing assignments on this app)" -ForegroundColor Gray
    }

    $newGroupSet = @{}
    foreach ($g in @($Config.RequiredGroups))  { $newGroupSet[$g] = "required" }
    foreach ($g in @($Config.AvailableGroups)) { $newGroupSet[$g] = "available" }
    foreach ($g in @($Config.UninstallGroups)) { $newGroupSet[$g] = "uninstall" }

    $toRemove = @($currentByGroup.Keys | Where-Object { -not $newGroupSet.ContainsKey($_) })
    $toAdd    = @($newGroupSet.Keys | Where-Object { -not $currentByGroup.ContainsKey($_) })
    if ($toRemove.Count -gt 0) {
        Write-Host "  WILL BE REMOVED:" -ForegroundColor Yellow
        foreach ($g in $toRemove) { Write-Host "    - [$($currentByGroup[$g])] $g" -ForegroundColor Yellow }
    }
    if ($toAdd.Count -gt 0) {
        Write-Host "  WILL BE ADDED:" -ForegroundColor Green
        foreach ($g in $toAdd) { Write-Host "    + [$($newGroupSet[$g])] $g" -ForegroundColor Green }
    }
    if ($toRemove.Count -eq 0 -and $toAdd.Count -eq 0) {
        Write-Host "  No change - current assignments already match." -ForegroundColor Gray
    }

    # ---- Build and apply the assignment list for this app only ----
    Write-Step "Setting assignments for this app"
    # Plain array, not a List<T> - matches the pattern already used successfully
    # for dependency relationships later in this script. Avoids any ambiguity
    # ConvertTo-Json or Graph's own deserialization might have with a
    # System.Collections.Generic.List[object] specifically.
    $assignments = @()
    foreach ($g in @($Config.RequiredGroups)) {
        if ($groupIdByName.ContainsKey($g)) {
            $assignments += @{ "@odata.type" = "#microsoft.graph.mobileAppAssignment"; intent = "required"; target = @{ "@odata.type" = "#microsoft.graph.groupAssignmentTarget"; groupId = $groupIdByName[$g] } }
        }
    }
    foreach ($g in @($Config.AvailableGroups)) {
        if ($groupIdByName.ContainsKey($g)) {
            $assignments += @{ "@odata.type" = "#microsoft.graph.mobileAppAssignment"; intent = "available"; target = @{ "@odata.type" = "#microsoft.graph.groupAssignmentTarget"; groupId = $groupIdByName[$g] } }
        }
    }
    foreach ($g in @($Config.UninstallGroups)) {
        if ($groupIdByName.ContainsKey($g)) {
            $assignments += @{ "@odata.type" = "#microsoft.graph.mobileAppAssignment"; intent = "uninstall"; target = @{ "@odata.type" = "#microsoft.graph.groupAssignmentTarget"; groupId = $groupIdByName[$g] } }
        }
    }

    Write-Host "  Applying $($assignments.Count) assignment(s)..." -ForegroundColor Gray
    try {
        $assignBody = [string](@{ mobileAppAssignments = @($assignments) } | ConvertTo-Json -Depth 10)
    }
    catch {
        throw "Building the assignment request body failed: $($_.Exception.Message)"
    }
    Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($Config.AppId)/assign" -Method POST -Body $assignBody -StepDescription "Assign app to groups" | Out-Null
    Write-Host "  [OK] Assignments applied." -ForegroundColor Green

    Write-Step "Done"
    Write-Host "[OK] $($allGroupNames.Count) group(s) confirmed ($createdCount newly created), $($assignments.Count) assignment(s) applied to this app." -ForegroundColor Green
    Write-Result -Success $true -GroupsCreated $createdCount -ErrorMessage ""
    exit 0
}
catch {
    Write-Host ""
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    Write-Result -Success $false -GroupsCreated 0 -ErrorMessage $_.Exception.Message
    exit 1
}

'@

$Script:EmbeddedBatchAssignScript = @'
<#
.SYNOPSIS
    Batch version of the per-app "Assign Groups to Intune" feature: checks
    (or applies) group assignments for every app in the catalog that has an
    App ID and at least one group set, in one pass.
.DESCRIPTION
    Reads a JSON config listing multiple apps (AppId, AppName, RequiredGroups,
    AvailableGroups, UninstallGroups) and a Mode:
      - "Preview": read-only. Fetches each app's CURRENT Intune assignments
        and computes what would be added/removed to match the catalog - does
        NOT create groups or change any assignment. Safe to run any time.
      - "Apply": does the real work - ensures every referenced group exists
        (creating any that don't), then sets each app's assignments to match
        the catalog exactly, same as the per-app version, just looped.
    Writes a result JSON (success/data/error) to -OutputResultPath, where
    data is an array of { AppName, AppId, ToAdd, ToRemove } - used for both
    the preview display and the post-apply summary.
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$ConfigPath
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[System.Net.ServicePointManager]::Expect100Continue = $false

function Write-Step {
    param([string]$Text)
    Write-Host ""
    Write-Host "=== $Text ===" -ForegroundColor Cyan
}

function Write-Result {
    param([bool]$Success, [string]$ErrorMessage, $Data)
    $result = [pscustomobject]@{
        success = $Success
        error   = $ErrorMessage
        data    = $Data
    }
    $result | ConvertTo-Json -Depth 10 | Set-Content -Path $Config.OutputResultPath -Encoding UTF8
}

function Get-HttpErrorDetail {
    param($ErrorRecord)
    $detail = $ErrorRecord.ErrorDetails.Message
    if ($detail) { return $detail }
    try {
        if ($ErrorRecord.Exception.Response) {
            $stream = $ErrorRecord.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)
            $body = $reader.ReadToEnd()
            $reader.Close()
            if ($body) { return $body }
        }
    } catch { }
    return $null
}

function Invoke-GraphRequestDetailed {
    param(
        [Parameter(Mandatory=$true)][string]$Uri,
        [string]$Method = "GET",
        [string]$Body = $null,
        [string]$ContentType = "application/json",
        [Parameter(Mandatory=$true)][string]$StepDescription
    )
    $maxAttempts = 4
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            if ($Body) {
                return Invoke-MgGraphRequest -Uri $Uri -Method $Method -Body $Body -ContentType $ContentType -ErrorAction Stop
            }
            else {
                return Invoke-MgGraphRequest -Uri $Uri -Method $Method -ErrorAction Stop
            }
        }
        catch {
            # Graph rate-limits (429) or has brief service hiccups (503) far
            # more often during bulk operations working through many items
            # in a row than on a single one-off call - retrying with
            # backoff instead of immediately failing the whole run on the
            # first blip. Detected from the exception TEXT rather than a
            # structured status-code property, since this cmdlet's own
            # exceptions have already been confirmed elsewhere in this app
            # to carry the status as readable text (e.g. "BadRequest (Bad
            # Request)") rather than a reliably-populated .Response object.
            $isThrottled = $_.Exception.Message -match '429|TooManyRequests|Too Many Requests'
            $isTransient = $_.Exception.Message -match '503|ServiceUnavailable|Service Unavailable'
            # 429 always means the request was rejected BEFORE any
            # processing happened, so retrying it is always safe. 503 is
            # different specifically for POST - the server may have already
            # created the resource before the response was lost in transit,
            # and retrying could then create a duplicate (a second app
            # registration, a second group, etc). GET/PUT/PATCH/DELETE don't
            # have this risk, since repeating them with the same body
            # produces the same end state no matter how many times it's
            # applied.
            $safeToRetryTransient = $isTransient -and $Method -ne "POST"
            if (($isThrottled -or $safeToRetryTransient) -and $attempt -lt $maxAttempts) {
                $waitSeconds = $attempt * $attempt * 3   # 3s, 12s, 27s
                $reason = if ($isThrottled) { "Rate-limited" } else { "Service temporarily unavailable" }
                Write-Host "  [!] $reason - waiting ${waitSeconds}s before retry $($attempt+1)/$maxAttempts..." -ForegroundColor Yellow
                Start-Sleep -Seconds $waitSeconds
                continue
            }
            $detail = Get-HttpErrorDetail -ErrorRecord $_
            $msg = "$StepDescription failed [$Method $Uri]: $($_.Exception.Message)"
            if ($detail) { $msg += "`nResponse body: $detail" }
            throw $msg
        }
    }
}

Write-Step "Loading configuration"
if (-not (Test-Path $ConfigPath)) {
    Write-Host "[ERROR] Config file not found: $ConfigPath" -ForegroundColor Red
    exit 1
}
$Config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
Write-Host "  Mode: $($Config.Mode)" -ForegroundColor Gray
Write-Host "  Apps: $(@($Config.Apps).Count)" -ForegroundColor Gray

try {
    Write-Step "Connecting to Microsoft Graph (app-only, certificate)"
    if (-not $Config.TenantId -or -not $Config.ClientId -or -not $Config.CertificateThumbprint) {
        throw "No Graph connection is configured. Open 'Settings...' in the GUI and fill in your Tenant ID, Client ID, and certificate first."
    }
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    $ctx = Get-MgContext -ErrorAction SilentlyContinue
    if ($null -eq $ctx -or $ctx.AuthType -ne 'AppOnly' -or $ctx.ClientId -ne $Config.ClientId) {
        Connect-MgGraph -TenantId $Config.TenantId -ClientId $Config.ClientId `
            -CertificateThumbprint $Config.CertificateThumbprint -NoWelcome -ErrorAction Stop
    }
    Write-Host "  [OK] Connected." -ForegroundColor Green

    # Cache group name -> id lookups across apps (many apps share groups like
    # "Deploy Dev Workplace", so this avoids repeating the same GET call).
    $groupIdCache = @{}

    function Resolve-GroupId {
        param([string]$GroupName, [bool]$CreateIfMissing)
        if ($groupIdCache.ContainsKey($GroupName)) { return $groupIdCache[$GroupName] }
        $escapedName = $GroupName.Replace("'", "''")
        $encodedFilter = [Uri]::EscapeDataString("displayName eq '$escapedName'")
        $existing = Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=$encodedFilter&`$select=id,displayName" -Method GET -StepDescription "Look up group '$GroupName'"
        if ($existing.value -and $existing.value.Count -gt 0) {
            $groupIdCache[$GroupName] = $existing.value[0].id
            return $existing.value[0].id
        }
        if ($CreateIfMissing) {
            $mailNickname = ($GroupName -replace '[^a-zA-Z0-9]', '')
            if ($mailNickname.Length -gt 60) { $mailNickname = $mailNickname.Substring(0, 60) }
            if ([string]::IsNullOrWhiteSpace($mailNickname)) { $mailNickname = "grp" + (Get-Random -Minimum 1000 -Maximum 9999) }
            $groupBody = @{
                displayName     = $GroupName
                mailEnabled     = $false
                mailNickname    = $mailNickname
                securityEnabled = $true
                "@odata.type"   = "#microsoft.graph.group"
            } | ConvertTo-Json -Depth 5
            $newGroup = Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/v1.0/groups" -Method POST -Body $groupBody -StepDescription "Create group '$GroupName'"
            $groupIdCache[$GroupName] = $newGroup.id
            Write-Host "  [+] Created group: $GroupName" -ForegroundColor Green
            return $newGroup.id
        }
        $groupIdCache[$GroupName] = $null
        return $null
    }

    $allResults = New-Object System.Collections.Generic.List[object]
    $appList = @($Config.Apps)
    $totalApps = $appList.Count
    $appIndex = 0

    foreach ($app in $appList) {
        $appIndex++
        Write-Step "[$appIndex/$totalApps] $($app.AppName)"

        $currentAssignments = Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($app.AppId)/assignments" -Method GET -StepDescription "Get current assignments for $($app.AppName)"
        $currentByGroup = @{}
        foreach ($a in @($currentAssignments.value)) {
            if ($a.target.'@odata.type' -eq '#microsoft.graph.groupAssignmentTarget') {
                $gid = $a.target.groupId
                $gName = $gid
                try {
                    $gi = Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/v1.0/groups/$gid`?`$select=displayName" -Method GET -StepDescription "Resolve current assignment's group name"
                    if ($gi.displayName) { $gName = $gi.displayName }
                } catch { }
                $currentByGroup[$gName] = $a.intent
            }
        }

        $newGroupSet = @{}
        foreach ($g in @($app.RequiredGroups))  { $newGroupSet[$g] = "required" }
        foreach ($g in @($app.AvailableGroups)) { $newGroupSet[$g] = "available" }
        foreach ($g in @($app.UninstallGroups)) { $newGroupSet[$g] = "uninstall" }

        $toRemove = @($currentByGroup.Keys | Where-Object { -not $newGroupSet.ContainsKey($_) })
        $toAdd    = @($newGroupSet.Keys | Where-Object { -not $currentByGroup.ContainsKey($_) })

        if ($toRemove.Count -eq 0 -and $toAdd.Count -eq 0) {
            Write-Host "  (no change)" -ForegroundColor Gray
        }
        foreach ($g in $toRemove) { Write-Host "  - [$($currentByGroup[$g])] $g" -ForegroundColor Yellow }
        foreach ($g in $toAdd)    { Write-Host "  + [$($newGroupSet[$g])] $g" -ForegroundColor Green }

        $allResults.Add([pscustomobject]@{
            AppName  = $app.AppName
            AppId    = $app.AppId
            ToAdd    = @($toAdd | ForEach-Object { "[$($newGroupSet[$_])] $_" })
            ToRemove = @($toRemove | ForEach-Object { "[$($currentByGroup[$_])] $_" })
        })

        if ($Config.Mode -eq "Apply") {
            foreach ($gName in @($newGroupSet.Keys)) { Resolve-GroupId -GroupName $gName -CreateIfMissing $true | Out-Null }

            $assignments = @()
            foreach ($g in @($app.RequiredGroups)) {
                if ($groupIdCache[$g]) { $assignments += @{ "@odata.type" = "#microsoft.graph.mobileAppAssignment"; intent = "required"; target = @{ "@odata.type" = "#microsoft.graph.groupAssignmentTarget"; groupId = $groupIdCache[$g] } } }
            }
            foreach ($g in @($app.AvailableGroups)) {
                if ($groupIdCache[$g]) { $assignments += @{ "@odata.type" = "#microsoft.graph.mobileAppAssignment"; intent = "available"; target = @{ "@odata.type" = "#microsoft.graph.groupAssignmentTarget"; groupId = $groupIdCache[$g] } } }
            }
            foreach ($g in @($app.UninstallGroups)) {
                if ($groupIdCache[$g]) { $assignments += @{ "@odata.type" = "#microsoft.graph.mobileAppAssignment"; intent = "uninstall"; target = @{ "@odata.type" = "#microsoft.graph.groupAssignmentTarget"; groupId = $groupIdCache[$g] } } }
            }

            $assignBody = [string](@{ mobileAppAssignments = @($assignments) } | ConvertTo-Json -Depth 10)
            Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($app.AppId)/assign" -Method POST -Body $assignBody -ContentType "application/json" -StepDescription "Assign $($app.AppName)" | Out-Null
            Write-Host "  [OK] Applied." -ForegroundColor Green
        }
    }

    Write-Step "Done"
    if ($Config.Mode -eq "Preview") {
        Write-Host "[OK] Preview complete - $totalApps app(s) checked, nothing was changed." -ForegroundColor Green
    }
    else {
        Write-Host "[OK] Applied changes to $totalApps app(s)." -ForegroundColor Green
    }
    Write-Result -Success $true -ErrorMessage "" -Data $allResults.ToArray()
    exit 0
}
catch {
    Write-Host ""
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    Write-Result -Success $false -ErrorMessage $_.Exception.Message -Data $null
    exit 1
}

'@

$Script:EmbeddedDeleteAppScript = @'
<#
.SYNOPSIS
    Deletes a Win32 app from Intune entirely. Irreversible.
.DESCRIPTION
    Reads a JSON config (AppId, AppName, TenantId, ClientId,
    CertificateThumbprint) and deletes that one app from Intune via Graph.
    Writes a result JSON (success/error) to -OutputResultPath.
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$ConfigPath
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[System.Net.ServicePointManager]::Expect100Continue = $false

function Write-Step {
    param([string]$Text)
    Write-Host ""
    Write-Host "=== $Text ===" -ForegroundColor Cyan
}

function Write-Result {
    param([bool]$Success, [string]$ErrorMessage, [string]$BlockingAppId = "", [string]$BlockingAppName = "")
    $result = [pscustomobject]@{ success = $Success; error = $ErrorMessage; blockingAppId = $BlockingAppId; blockingAppName = $BlockingAppName }
    $result | ConvertTo-Json | Set-Content -Path $Config.OutputResultPath -Encoding UTF8
}

function Get-HttpErrorDetail {
    param($ErrorRecord)
    $detail = $ErrorRecord.ErrorDetails.Message
    if ($detail) { return $detail }
    try {
        if ($ErrorRecord.Exception.Response) {
            $stream = $ErrorRecord.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)
            $body = $reader.ReadToEnd()
            $reader.Close()
            if ($body) { return $body }
        }
    } catch { }
    return $null
}

function Invoke-GraphRequestDetailed {
    param(
        [Parameter(Mandatory=$true)][string]$Uri,
        [string]$Method = "GET",
        [string]$Body = $null,
        [string]$ContentType = "application/json",
        [Parameter(Mandatory=$true)][string]$StepDescription
    )
    $maxAttempts = 4
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            if ($Body) {
                return Invoke-MgGraphRequest -Uri $Uri -Method $Method -Body $Body -ContentType $ContentType -ErrorAction Stop
            }
            else {
                return Invoke-MgGraphRequest -Uri $Uri -Method $Method -ErrorAction Stop
            }
        }
        catch {
            # Graph rate-limits (429) or has brief service hiccups (503) far
            # more often during bulk operations working through many items
            # in a row than on a single one-off call - retrying with
            # backoff instead of immediately failing the whole run on the
            # first blip. Detected from the exception TEXT rather than a
            # structured status-code property, since this cmdlet's own
            # exceptions have already been confirmed elsewhere in this app
            # to carry the status as readable text (e.g. "BadRequest (Bad
            # Request)") rather than a reliably-populated .Response object.
            $isThrottled = $_.Exception.Message -match '429|TooManyRequests|Too Many Requests'
            $isTransient = $_.Exception.Message -match '503|ServiceUnavailable|Service Unavailable'
            # 429 always means the request was rejected BEFORE any
            # processing happened, so retrying it is always safe. 503 is
            # different specifically for POST - the server may have already
            # created the resource before the response was lost in transit,
            # and retrying could then create a duplicate (a second app
            # registration, a second group, etc). GET/PUT/PATCH/DELETE don't
            # have this risk, since repeating them with the same body
            # produces the same end state no matter how many times it's
            # applied.
            $safeToRetryTransient = $isTransient -and $Method -ne "POST"
            if (($isThrottled -or $safeToRetryTransient) -and $attempt -lt $maxAttempts) {
                $waitSeconds = $attempt * $attempt * 3   # 3s, 12s, 27s
                $reason = if ($isThrottled) { "Rate-limited" } else { "Service temporarily unavailable" }
                Write-Host "  [!] $reason - waiting ${waitSeconds}s before retry $($attempt+1)/$maxAttempts..." -ForegroundColor Yellow
                Start-Sleep -Seconds $waitSeconds
                continue
            }
            $detail = Get-HttpErrorDetail -ErrorRecord $_
            $msg = "$StepDescription failed [$Method $Uri]: $($_.Exception.Message)"
            if ($detail) { $msg += "`nResponse body: $detail" }
            throw $msg
        }
    }
}

Write-Step "Loading configuration"
if (-not (Test-Path $ConfigPath)) {
    Write-Host "[ERROR] Config file not found: $ConfigPath" -ForegroundColor Red
    exit 1
}
$Config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
Write-Host "  App: $($Config.AppName)" -ForegroundColor Gray
Write-Host "  App ID: $($Config.AppId)" -ForegroundColor Gray

try {
    Write-Step "Connecting to Microsoft Graph (app-only, certificate)"
    if (-not $Config.TenantId -or -not $Config.ClientId -or -not $Config.CertificateThumbprint) {
        throw "No Graph connection is configured. Open 'Settings...' in the GUI and fill in your Tenant ID, Client ID, and certificate first."
    }
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    $ctx = Get-MgContext -ErrorAction SilentlyContinue
    if ($null -eq $ctx -or $ctx.AuthType -ne 'AppOnly' -or $ctx.ClientId -ne $Config.ClientId) {
        Connect-MgGraph -TenantId $Config.TenantId -ClientId $Config.ClientId `
            -CertificateThumbprint $Config.CertificateThumbprint -NoWelcome -ErrorAction Stop
    }
    Write-Host "  [OK] Connected." -ForegroundColor Green

    if ($Config.RemoveDependencyFromAppId) {
        Write-Step "Removing the blocking dependency first"
        # CORRECTED after being backwards the first time - a real, deeper
        # bug than just the earlier targetType direction fix. The
        # dependency relationship is OWNED by the app being deleted (this
        # one), not by the blocking app - Intune's own portal (test23's own
        # Properties > Dependencies tab) confirmed this app is the one that
        # DECLARES "I depend on X", and the blocking app's own relationships
        # list is just a read-only, reflected VIEW of that declaration, not
        # an independently editable record. Modifying the blocking app's
        # side (as this used to) never actually touched the real
        # relationship at all - which is exactly why the removal kept
        # reporting success but the dependency kept showing up again on
        # every retry. Now correctly reads and updates THIS app's own
        # relationships instead, removing the entry that points at the
        # blocking app.
        # updateRelationships is REPLACE semantics, not additive - sending
        # only a partial list would silently wipe out every OTHER
        # dependency this app has, so the full current list is read first
        # and only the one entry pointing at the blocking app is left out
        # of what gets resubmitted.
        $existingRels = Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($Config.AppId)/relationships" -Method GET -StepDescription "Read existing dependencies"
        $matchingRel = $existingRels.value | Where-Object { $_.targetId -eq $Config.RemoveDependencyFromAppId } | Select-Object -First 1
        if ($matchingRel) {
            $keepRels = @($existingRels.value | Where-Object { $_.targetId -ne $Config.RemoveDependencyFromAppId } | ForEach-Object {
                @{ "@odata.type" = "#microsoft.graph.mobileAppDependency"; targetId = $_.targetId; dependencyType = $_.dependencyType }
            })
            $relBody = @{ relationships = $keepRels } | ConvertTo-Json -Depth 8
            Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($Config.AppId)/updateRelationships" -Method POST -Body $relBody -ContentType "application/json" -StepDescription "Remove dependency relationship" | Out-Null
            Write-Host "  [OK] Dependency relationship removed - $($keepRels.Count) other dependency(ies) kept." -ForegroundColor Green

            # Graph's delete-time dependency check can briefly lag behind an
            # updateRelationships change actually taking effect - the same
            # kind of propagation delay already handled elsewhere in this
            # tool after group creation. Without waiting here, the very
            # next delete attempt below can still see the OLD, pre-removal
            # dependency state and fail with the exact same error - which
            # is exactly what looping on this same error over and over
            # looked like.
            Write-Host "  Waiting for the removal to take effect..." -ForegroundColor Gray
            $removalConfirmed = $false
            for ($attempt = 1; $attempt -le 10; $attempt++) {
                Start-Sleep -Seconds 2
                $recheckRels = Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($Config.AppId)/relationships" -Method GET -StepDescription "Re-check dependencies"
                $stillThere = $recheckRels.value | Where-Object { $_.targetId -eq $Config.RemoveDependencyFromAppId }
                if (-not $stillThere) { $removalConfirmed = $true; break }
                Write-Host "  ... still showing as a dependency (attempt $attempt/10)" -ForegroundColor Gray
            }
            if ($removalConfirmed) {
                Write-Host "  [OK] Confirmed removed." -ForegroundColor Green
            }
            else {
                Write-Host "  [!] Still showing as a dependency after waiting - proceeding to delete anyway, but it may fail again." -ForegroundColor Yellow
            }
        }
        else {
            Write-Host "  (no matching dependency found - it may have already been removed by someone else)" -ForegroundColor Yellow
        }
    }

    Write-Step "Deleting app from Intune"
    try {
        Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($Config.AppId)" -Method DELETE -StepDescription "Delete app" | Out-Null
        Write-Host "  [OK] Deleted from Intune." -ForegroundColor Green
    }
    catch {
        # This specific Graph business rule is common enough to deserve a
        # clear, actionable message instead of just the raw JSON - an app
        # can't be deleted while it's set as a dependency for another app.
        if ($_.Exception.Message -match 'is the parent of another app:\s*([0-9a-fA-F-]{36})') {
            $blockingId = $Matches[1]
            $blockingName = $blockingId
            try {
                $blockingApp = Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$blockingId`?`$select=displayName" -Method GET -StepDescription "Look up blocking app name"
                if ($blockingApp.displayName) { $blockingName = $blockingApp.displayName }
            } catch { }
            Write-Host "[ERROR] Blocked by a dependency: `"$blockingName`" ($blockingId) still requires this app." -ForegroundColor Red
            Write-Result -Success $false -ErrorMessage "This app can't be deleted because Intune has it set as a dependency for `"$blockingName`"." -BlockingAppId $blockingId -BlockingAppName $blockingName
            exit 1
        }
        # Not actually a failure - the one thing this step is trying to
        # achieve (this App ID no longer existing in Intune) is already
        # true. Happens whenever the catalog's own record is stale: someone
        # else deleted it directly in the Intune portal, "Intune sync
        # check" already flagged it as gone but this app wasn't re-saved
        # yet, or this exact delete was already run once and simply never
        # got the chance to clear the App ID locally afterward (a prior
        # crash, a closed dialog, etc.). Treated as success and continues
        # into the same after-delete steps below, rather than surfacing a
        # 404 as a scary [FAILED] for an outcome that was already achieved
        # before this run even started.
        if ($_.Exception.Message -match 'NotFound|404') {
            Write-Host "  [OK] Already not in Intune (App ID not found) - nothing to delete, treating as success." -ForegroundColor Yellow
        }
        else {
            throw
        }
    }

    Write-Step "Done"
    Write-Result -Success $true -ErrorMessage ""
    exit 0
}
catch {
    Write-Host ""
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    Write-Result -Success $false -ErrorMessage $_.Exception.Message
    exit 1
}

'@

$Script:EmbeddedGroupManagerScript = @'
<#
.SYNOPSIS
    Ensures a security group exists (creating it if needed) and adds a set
    of members (users or groups, by Object ID) to it.
.DESCRIPTION
    Reads a JSON config (GroupName, MemberIds array, TenantId, ClientId,
    CertificateThumbprint). Idempotent: reuses the group if a group with
    that exact name already exists rather than creating a duplicate, and
    silently treats "already a member" as success rather than an error for
    each member. Writes a result JSON (success/error/groupId) to
    -OutputResultPath.
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$ConfigPath
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[System.Net.ServicePointManager]::Expect100Continue = $false

function Write-Step {
    param([string]$Text)
    Write-Host ""
    Write-Host "=== $Text ===" -ForegroundColor Cyan
}

function Write-Result {
    param([bool]$Success, [string]$ErrorMessage, [string]$GroupId)
    $result = [pscustomobject]@{ success = $Success; error = $ErrorMessage; groupId = $GroupId }
    $result | ConvertTo-Json | Set-Content -Path $Config.OutputResultPath -Encoding UTF8
}

function Get-HttpErrorDetail {
    param($ErrorRecord)
    $detail = $ErrorRecord.ErrorDetails.Message
    if ($detail) { return $detail }
    try {
        if ($ErrorRecord.Exception.Response) {
            $stream = $ErrorRecord.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)
            $body = $reader.ReadToEnd()
            $reader.Close()
            if ($body) { return $body }
        }
    } catch { }
    return $null
}

function Invoke-GraphRequestDetailed {
    param(
        [Parameter(Mandatory=$true)][string]$Uri,
        [string]$Method = "GET",
        [string]$Body = $null,
        [string]$ContentType = "application/json",
        [Parameter(Mandatory=$true)][string]$StepDescription
    )
    $maxAttempts = 4
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            if ($Body) {
                return Invoke-MgGraphRequest -Uri $Uri -Method $Method -Body $Body -ContentType $ContentType -ErrorAction Stop
            }
            else {
                return Invoke-MgGraphRequest -Uri $Uri -Method $Method -ErrorAction Stop
            }
        }
        catch {
            # Graph rate-limits (429) or has brief service hiccups (503) far
            # more often during bulk operations working through many items
            # in a row than on a single one-off call - retrying with
            # backoff instead of immediately failing the whole run on the
            # first blip. Detected from the exception TEXT rather than a
            # structured status-code property, since this cmdlet's own
            # exceptions have already been confirmed elsewhere in this app
            # to carry the status as readable text (e.g. "BadRequest (Bad
            # Request)") rather than a reliably-populated .Response object.
            $isThrottled = $_.Exception.Message -match '429|TooManyRequests|Too Many Requests'
            $isTransient = $_.Exception.Message -match '503|ServiceUnavailable|Service Unavailable'
            # 429 always means the request was rejected BEFORE any
            # processing happened, so retrying it is always safe. 503 is
            # different specifically for POST - the server may have already
            # created the resource before the response was lost in transit,
            # and retrying could then create a duplicate (a second app
            # registration, a second group, etc). GET/PUT/PATCH/DELETE don't
            # have this risk, since repeating them with the same body
            # produces the same end state no matter how many times it's
            # applied.
            $safeToRetryTransient = $isTransient -and $Method -ne "POST"
            if (($isThrottled -or $safeToRetryTransient) -and $attempt -lt $maxAttempts) {
                $waitSeconds = $attempt * $attempt * 3   # 3s, 12s, 27s
                $reason = if ($isThrottled) { "Rate-limited" } else { "Service temporarily unavailable" }
                Write-Host "  [!] $reason - waiting ${waitSeconds}s before retry $($attempt+1)/$maxAttempts..." -ForegroundColor Yellow
                Start-Sleep -Seconds $waitSeconds
                continue
            }
            $detail = Get-HttpErrorDetail -ErrorRecord $_
            $msg = "$StepDescription failed [$Method $Uri]: $($_.Exception.Message)"
            if ($detail) { $msg += "`nResponse body: $detail" }
            throw $msg
        }
    }
}

Write-Step "Loading configuration"
if (-not (Test-Path $ConfigPath)) {
    Write-Host "[ERROR] Config file not found: $ConfigPath" -ForegroundColor Red
    exit 1
}
$Config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
Write-Host "  Group: $($Config.GroupName)" -ForegroundColor Gray
Write-Host "  Members to add: $(@($Config.MemberIds).Count)" -ForegroundColor Gray

try {
    Write-Step "Connecting to Microsoft Graph (app-only, certificate)"
    if (-not $Config.TenantId -or -not $Config.ClientId -or -not $Config.CertificateThumbprint) {
        throw "No Graph connection is configured. Open 'Settings...' in the GUI and fill in your Tenant ID, Client ID, and certificate first."
    }
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    $ctx = Get-MgContext -ErrorAction SilentlyContinue
    if ($null -eq $ctx -or $ctx.AuthType -ne 'AppOnly' -or $ctx.ClientId -ne $Config.ClientId) {
        Connect-MgGraph -TenantId $Config.TenantId -ClientId $Config.ClientId `
            -CertificateThumbprint $Config.CertificateThumbprint -NoWelcome -ErrorAction Stop
    }
    Write-Host "  [OK] Connected." -ForegroundColor Green

    if ($Config.Mode -eq "Delete") {
        Write-Step "Finding group"
        $escapedName = $Config.GroupName.Replace("'", "''")
        $encodedFilter = [Uri]::EscapeDataString("displayName eq '$escapedName'")
        $existing = Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=$encodedFilter&`$select=id,displayName" -Method GET -StepDescription "Look up group"
        if (-not $existing.value -or $existing.value.Count -eq 0) {
            throw "No group named '$($Config.GroupName)' was found - nothing to delete."
        }
        $groupId = $existing.value[0].id
        Write-Host "  Found: $($Config.GroupName) ($groupId)" -ForegroundColor Gray

        Write-Step "Deleting group"
        Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/v1.0/groups/$groupId" -Method DELETE -StepDescription "Delete group" | Out-Null
        Write-Host "  [OK] Deleted from Entra ID." -ForegroundColor Green

        Write-Step "Done"
        Write-Result -Success $true -ErrorMessage "" -GroupId $groupId
        exit 0
    }

    if ($Config.Mode -eq "RemoveMember") {
        Write-Step "Removing member from group"
        Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/v1.0/groups/$($Config.GroupId)/members/$($Config.MemberId)/`$ref" -Method DELETE -StepDescription "Remove member" | Out-Null
        Write-Host "  [OK] Removed from group." -ForegroundColor Green
        Write-Step "Done"
        Write-Result -Success $true -ErrorMessage "" -GroupId $Config.GroupId
        exit 0
    }

    Write-Step "Ensuring group exists"
    $escapedName = $Config.GroupName.Replace("'", "''")
    $encodedFilter = [Uri]::EscapeDataString("displayName eq '$escapedName'")
    $existing = Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=$encodedFilter&`$select=id,displayName" -Method GET -StepDescription "Look up group"

    if ($existing.value -and $existing.value.Count -gt 0) {
        $groupId = $existing.value[0].id
        Write-Host "  [=] Using existing group: $($Config.GroupName)" -ForegroundColor Gray

        if ($Config.Description) {
            Write-Step "Updating description"
            $descBody = @{ description = $Config.Description } | ConvertTo-Json
            Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/v1.0/groups/$groupId" -Method PATCH -Body $descBody -ContentType "application/json" -StepDescription "Update group description" | Out-Null
            Write-Host "  [OK] Description updated." -ForegroundColor Green
        }
    }
    else {
        $mailNickname = ($Config.GroupName -replace '[^a-zA-Z0-9]', '')
        if ($mailNickname.Length -gt 60) { $mailNickname = $mailNickname.Substring(0, 60) }
        if ([string]::IsNullOrWhiteSpace($mailNickname)) { $mailNickname = "grp" + (Get-Random -Minimum 1000 -Maximum 9999) }
        $groupBody = @{
            displayName     = $Config.GroupName
            mailEnabled     = $false
            mailNickname    = $mailNickname
            securityEnabled = $true
            "@odata.type"   = "#microsoft.graph.group"
        }
        if ($Config.Description) { $groupBody.description = $Config.Description }
        $groupBody = $groupBody | ConvertTo-Json -Depth 5
        $newGroup = Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/v1.0/groups" -Method POST -Body $groupBody -StepDescription "Create group"
        $groupId = $newGroup.id
        Write-Host "  [+] Created new group: $($Config.GroupName)" -ForegroundColor Green

        # Newly created Entra ID objects aren't always immediately queryable
        # across every Graph replica - the group demonstrably exists (the
        # create call above succeeded and returned this ID), but a request
        # routed to a different backend can still 404 on it for a few
        # seconds. Poll the same kind of GET the member-add calls below will
        # need, rather than guessing at a fixed delay.
        Write-Host "  Waiting for the new group to become available..." -ForegroundColor Gray
        $propagated = $false
        for ($attempt = 1; $attempt -le 10; $attempt++) {
            Start-Sleep -Seconds 2
            try {
                Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/v1.0/groups/$groupId`?`$select=id" -Method GET -StepDescription "Check group availability" | Out-Null
                $propagated = $true
                break
            }
            catch {
                Write-Host "  ... not yet visible (attempt $attempt/10)" -ForegroundColor DarkGray
            }
        }
        if ($propagated) {
            Write-Host "  [OK] Group is available." -ForegroundColor Green
        }
        else {
            Write-Host "  [WARNING] Group still not confirmed visible after 20s - continuing anyway; member adds below will retry individually too." -ForegroundColor Yellow
        }
    }

    $memberIds = @($Config.MemberIds)
    if ($memberIds.Count -gt 0) {
        Write-Step "Adding members"
        foreach ($memberId in $memberIds) {
            # Per-member retry as a second line of defense against the same
            # propagation-delay issue, in case the wait above wasn't enough
            # or this specific call gets routed to a different replica.
            for ($attempt = 1; $attempt -le 3; $attempt++) {
                try {
                    $refBody = @{ "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$memberId" } | ConvertTo-Json
                    Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/v1.0/groups/$groupId/members/`$ref" -Method POST -Body $refBody -StepDescription "Add member $memberId" | Out-Null
                    Write-Host "  [+] Added: $memberId" -ForegroundColor Green
                    break
                }
                catch {
                    if ($_.Exception.Message -match 'already exist') {
                        Write-Host "  [=] Already a member: $memberId" -ForegroundColor Gray
                        break
                    }
                    elseif ($_.Exception.Message -match 'does not exist' -and $attempt -lt 3) {
                        Write-Host "  ... group not yet visible for this call, retrying ($attempt/3)..." -ForegroundColor DarkGray
                        Start-Sleep -Seconds 3
                    }
                    else {
                        Write-Host "  [WARNING] Could not add $memberId : $($_.Exception.Message)" -ForegroundColor Yellow
                        break
                    }
                }
            }
        }
    }

    Write-Step "Done"
    Write-Host "[OK] Group ready: $($Config.GroupName) ($groupId)" -ForegroundColor Green
    Write-Result -Success $true -ErrorMessage "" -GroupId $groupId
    exit 0
}
catch {
    Write-Host ""
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    Write-Result -Success $false -ErrorMessage $_.Exception.Message -GroupId ""
    exit 1
}

'@

$Script:EmbeddedSyncMetadataScript = @'
<#
.SYNOPSIS
    Fetches current Intune metadata for MULTIPLE apps in one run, writing it
    all back as a single JSON array - used to bulk-sync the local catalog's
    metadata field from what's actually live in Intune right now.
.DESCRIPTION
    Reuses the exact same field-extraction logic as Start-AppMetadataFetch
    (the single-app version used by Deploy to Intune's Update mode) rather
    than re-deriving it - that logic has already been through several
    rounds of real bug fixes this session (architecture handling
    specifically), and re-deriving it here risked reintroducing one of
    those exact bugs.
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$ConfigPath
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[System.Net.ServicePointManager]::Expect100Continue = $false

function Write-Step {
    param([string]$Text)
    Write-Host ""
    Write-Host "=== $Text ===" -ForegroundColor Cyan
}

function Write-Result {
    param([bool]$Success, [string]$ErrorMessage, [array]$Results = @())
    $result = [pscustomobject]@{ success = $Success; error = $ErrorMessage; results = $Results }
    $result | ConvertTo-Json -Depth 10 | Set-Content -Path $Config.OutputResultPath -Encoding UTF8
}

function Get-HttpErrorDetail {
    param($ErrorRecord)
    $detail = $ErrorRecord.ErrorDetails.Message
    if ($detail) { return $detail }
    try {
        if ($ErrorRecord.Exception.Response) {
            $stream = $ErrorRecord.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)
            $body = $reader.ReadToEnd()
            $reader.Close()
            if ($body) { return $body }
        }
    } catch { }
    return $null
}

function Invoke-GraphRequestDetailed {
    param(
        [Parameter(Mandatory=$true)][string]$Uri,
        [string]$Method = "GET",
        [string]$Body = $null,
        [string]$ContentType = "application/json",
        [Parameter(Mandatory=$true)][string]$StepDescription
    )
    $maxAttempts = 4
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            if ($Body) {
                return Invoke-MgGraphRequest -Uri $Uri -Method $Method -Body $Body -ContentType $ContentType -ErrorAction Stop
            }
            else {
                return Invoke-MgGraphRequest -Uri $Uri -Method $Method -ErrorAction Stop
            }
        }
        catch {
            $isThrottled = $_.Exception.Message -match '429|TooManyRequests|Too Many Requests'
            $isTransient = $_.Exception.Message -match '503|ServiceUnavailable|Service Unavailable'
            $safeToRetryTransient = $isTransient -and $Method -ne "POST"
            if (($isThrottled -or $safeToRetryTransient) -and $attempt -lt $maxAttempts) {
                $waitSeconds = $attempt * $attempt * 3
                $reason = if ($isThrottled) { "Rate-limited" } else { "Service temporarily unavailable" }
                Write-Host "  [!] $reason - waiting ${waitSeconds}s before retry $($attempt+1)/$maxAttempts..." -ForegroundColor Yellow
                Start-Sleep -Seconds $waitSeconds
                continue
            }
            $detail = Get-HttpErrorDetail -ErrorRecord $_
            $msg = "$StepDescription failed [$Method $Uri]: $($_.Exception.Message)"
            if ($detail) { $msg += "`nResponse body: $detail" }
            throw $msg
        }
    }
}

Write-Step "Loading configuration"
if (-not (Test-Path $ConfigPath)) {
    Write-Host "[ERROR] Config file not found: $ConfigPath" -ForegroundColor Red
    exit 1
}
$Config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
$appList = @($Config.Apps)
Write-Host "  Apps to sync: $($appList.Count)" -ForegroundColor Gray

try {
    Write-Step "Connecting to Microsoft Graph (app-only, certificate)"
    if (-not $Config.TenantId -or -not $Config.ClientId -or -not $Config.CertificateThumbprint) {
        throw "No Graph connection is configured. Open 'Settings...' in the GUI and fill in your Tenant ID, Client ID, and certificate first."
    }
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    $ctx = Get-MgContext -ErrorAction SilentlyContinue
    if ($null -eq $ctx -or $ctx.AuthType -ne 'AppOnly' -or $ctx.ClientId -ne $Config.ClientId) {
        Connect-MgGraph -TenantId $Config.TenantId -ClientId $Config.ClientId `
            -CertificateThumbprint $Config.CertificateThumbprint -NoWelcome -ErrorAction Stop
    }
    Write-Host "  [OK] Connected." -ForegroundColor Green

    $allResults = New-Object System.Collections.Generic.List[object]
    $doneCount = 0
    foreach ($appEntry in $appList) {
        $doneCount++
        Write-Host ""
        Write-Host "[$doneCount/$($appList.Count)] $($appEntry.AppName)" -ForegroundColor Cyan
        try {
            $app = Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($appEntry.AppId)" -Method GET -StepDescription "Fetch metadata"

            $detectionRule = $null
            foreach ($rule in @($app.detectionRules)) {
                $odType = $rule.'@odata.type'
                if ($odType -eq '#microsoft.graph.win32LobAppPowerShellScriptDetection' -and $rule.scriptContent) {
                    $scriptText = $null
                    try { $scriptText = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($rule.scriptContent)) } catch { }
                    $detectionRule = [pscustomobject]@{ Type = "Script"; Script_Content = $scriptText }
                    break
                }
                elseif ($odType -eq '#microsoft.graph.win32LobAppProductCodeDetection') {
                    $detectionRule = [pscustomobject]@{
                        Type                 = "Msi"
                        Msi_ProductCode      = $rule.productCode
                        Msi_VersionOperator  = $rule.productVersionOperator
                        Msi_Version          = $rule.productVersion
                    }
                    break
                }
                elseif ($odType -eq '#microsoft.graph.win32LobAppFileSystemDetection') {
                    $detectionRule = [pscustomobject]@{
                        Type                = "File"
                        File_Path            = $rule.path
                        File_Name            = $rule.fileOrFolderName
                        File_Check32Bit      = $rule.check32BitOn64System
                        File_DetectionType   = $rule.detectionType
                        File_Operator        = $rule.operator
                        File_DetectionValue  = $rule.detectionValue
                    }
                    break
                }
                elseif ($odType -eq '#microsoft.graph.win32LobAppRegistryDetection') {
                    $detectionRule = [pscustomobject]@{
                        Type                = "Registry"
                        Reg_KeyPath          = $rule.keyPath
                        Reg_ValueName        = $rule.valueName
                        Reg_Check32Bit       = $rule.check32BitOn64System
                        Reg_DetectionType    = $rule.detectionType
                        Reg_Operator         = $rule.operator
                        Reg_DetectionValue   = $rule.detectionValue
                    }
                    break
                }
            }

            $minOsPropName = $null
            if ($app.minimumSupportedOperatingSystem) {
                $minOsObj = $app.minimumSupportedOperatingSystem
                if ($minOsObj -is [System.Collections.IDictionary]) {
                    foreach ($key in $minOsObj.Keys) {
                        if ($minOsObj[$key] -eq $true) { $minOsPropName = $key; break }
                    }
                }
                else {
                    foreach ($prop in $minOsObj.PSObject.Properties) {
                        if ($prop.Value -eq $true) { $minOsPropName = $prop.Name; break }
                    }
                }
            }

            # Same precedence as the GUI's own populate-from-fetch logic for
            # a single app (Deploy to Intune, Update mode) - allowedArchitectures
            # is preferred whenever it holds a real, non-"none" value, since
            # that's how Intune represents an app using MULTIPLE
            # architectures; applicableArchitectures is the single-value
            # fallback for apps that only ever set that one.
            $archValue = ""
            if ($app.allowedArchitectures -and $app.allowedArchitectures -ne "none") {
                $archValue = $app.allowedArchitectures
            }
            elseif ($app.applicableArchitectures -and $app.applicableArchitectures -ne "none") {
                $archValue = $app.applicableArchitectures
            }
            # Re-normalized into the same canonical, comma-joined
            # "x86,x64,arm64" order the local catalog's own architecture
            # field always uses - Intune has been observed returning this
            # as a PERIOD-separated string (e.g. "x64.arm64") for a
            # multi-architecture app, not comma. Without this, that raw
            # value would get written straight into the local catalog's
            # metadata.architecture field, silently corrupting it for
            # every downstream comma-based split of that field (the app
            # editor's own local-metadata prefill included).
            if ($archValue) {
                $archTokensNorm = @($archValue -split '[,.]' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
                $archValue = (@("x86","x64","arm64") | Where-Object { $archTokensNorm -contains $_ }) -join ","
            }

            # Dependencies fetched from the SAME endpoint already used
            # during the delete-dependency work earlier this session -
            # GET .../relationships returns each dependency as a
            # mobileAppDependency object, which already includes
            # targetDisplayName directly, no extra name-resolution lookup
            # needed. Filtered on TWO conditions, not just one:
            #   1. @odata.type -eq mobileAppDependency - this endpoint can
            #      also return mobileAppSupersedence entries (this app
            #      REPLACES another), a different relationship that isn't a
            #      dependency and shouldn't be mixed into this list.
            #   2. targetType -eq "child" - CORRECTED after being wrong the
            #      first time. The docs' own wording ("whether the target
            #      is a parent or child") reads as if "parent" should mean
            #      "prerequisite", but a real, concrete example settled it:
            #      a GitHub issue showing an actual create-dependency
            #      payload has target "Chocolatey" with targetType="child"
            #      and dependencyType="autoInstall" - and autoInstall is
            #      documented as "the child app should be installed before
            #      the parent app". So the PREREQUISITE is labeled "child"
            #      here, not "parent" - the opposite of the intuitive
            #      reading, confirmed against this app's own real data too
            #      (querying the app that has NO dependencies of its own
            #      but IS depended upon by another returned that other app
            #      under targetType="parent", not "child").
            # Stored by NAME, not targetId - matching how dependencies are
            # stored everywhere else in the catalog, so one that hasn't
            # been deployed yet elsewhere still resolves correctly once it
            # is, at actual batch-deploy time.
            $depNames = @()
            try {
                $rels = Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($appEntry.AppId)/relationships" -Method GET -StepDescription "Fetch dependencies"
                $relCount = @($rels.value).Count
                Write-Host "  ($relCount relationship entr$(if ($relCount -eq 1) {'y'} else {'ies'}) found)" -ForegroundColor Gray
                $depNames = @($rels.value | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.mobileAppDependency' -and $_.targetType -eq 'child' } | ForEach-Object { $_.targetDisplayName } | Where-Object { $_ })
            }
            catch {
                Write-Host "  [!] Could not fetch dependencies: $($_.Exception.Message)" -ForegroundColor Yellow
            }

            $metadata = [pscustomobject]@{
                description      = $app.description
                publisher        = $app.publisher
                owner            = $app.owner
                developer        = $app.developer
                informationUrl   = $app.informationUrl
                privacyUrl       = $app.privacyInformationUrl
                notes            = $app.notes
                installCommand   = $app.installCommandLine
                uninstallCommand = $app.uninstallCommandLine
                architecture     = $archValue
                installContext   = $app.installExperience.runAsAccount
                minOSKey         = $minOsPropName
                detectionRule    = $detectionRule
                dependencies     = $depNames
                # Same fields added to Deploy to Intune's own fetch/populate
                # logic, confirmed against the same win32LobApp schema docs.
                minDiskSpaceMB          = $app.minimumFreeDiskSpaceInMB
                minMemoryMB             = $app.minimumMemoryInMB
                minProcessors           = $app.minimumNumberOfProcessors
                minCpuSpeedMHz          = $app.minimumCpuSpeedInMHz
                installTimeMinutes      = $app.installExperience.maxRunTimeInMinutes
                deviceRestartBehavior   = $app.installExperience.deviceRestartBehavior
                allowAvailableUninstall = $app.allowAvailableUninstall
                returnCodes             = @($app.returnCodes | ForEach-Object { [pscustomobject]@{ returnCode = $_.returnCode; type = $_.type } })
            }

            $allResults.Add([pscustomobject]@{ AppName = $appEntry.AppName; Success = $true; Metadata = $metadata; Error = "" })
            Write-Host "  [OK] Synced." -ForegroundColor Green
        }
        catch {
            Write-Host "  [ERROR] $($_.Exception.Message)" -ForegroundColor Red
            $allResults.Add([pscustomobject]@{ AppName = $appEntry.AppName; Success = $false; Metadata = $null; Error = $_.Exception.Message })
        }
    }

    Write-Step "Done"
    $okCount = @($allResults | Where-Object { $_.Success }).Count
    Write-Host "$okCount of $($appList.Count) synced successfully." -ForegroundColor $(if ($okCount -eq $appList.Count) { "Green" } else { "Yellow" })
    Write-Result -Success $true -ErrorMessage "" -Results $allResults.ToArray()
    exit 0
}
catch {
    Write-Host ""
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    Write-Result -Success $false -ErrorMessage $_.Exception.Message -Results @()
    exit 1
}

'@

$Script:EmbeddedCertUploadScript = @'
<#
.SYNOPSIS
    Uploads a locally-generated certificate's public key to an Entra ID app
    registration, so app-only certificate authentication can start working
    without a manual trip through the Azure portal.
.DESCRIPTION
    This is the one operation in the whole tool that CANNOT use the app-only
    certificate the rest of the app relies on - that certificate isn't
    trusted by the app registration yet, which is exactly the problem this
    script solves. Instead it uses interactive (delegated) sign-in as the
    person running it, via a regular browser-based prompt (see the note by
    Connect-MgGraph below for why -UseDeviceCode is deliberately avoided
    despite being the more obviously reliable choice for a hidden
    background process). This also means the caller must pass
    -ShowConsoleWindow to Start-PipelineProcess for this script specifically
    - Windows' WAM authentication broker needs an actual parent window
    handle to attach its sign-in prompt to, and fails outright ("A window
    handle must be configured") without one. Every other embedded script in
    this app runs fully hidden since app-only certificate auth needs no
    such window.

    Deliberately fetches the app's EXISTING keyCredentials and includes them
    unchanged in the PATCH, alongside the new one. A PATCH to keyCredentials
    is REPLACE semantics, not additive - sending only the new certificate
    would silently delete every other certificate already trusted for that
    app registration, which could break other tools or admins relying on
    them. Confirmed against Microsoft's own documentation before writing
    this, given this operates on shared, security-sensitive credentials.
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$ConfigPath
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[System.Net.ServicePointManager]::Expect100Continue = $false

function Write-Step {
    param([string]$Text)
    Write-Host ""
    Write-Host "=== $Text ===" -ForegroundColor Cyan
}

function Write-Result {
    param([bool]$Success, [string]$ErrorMessage, [array]$Certificates = @())
    $result = [pscustomobject]@{ success = $Success; error = $ErrorMessage; certificates = $Certificates }
    $result | ConvertTo-Json -Depth 6 | Set-Content -Path $Config.OutputResultPath -Encoding UTF8
}

function Get-HttpErrorDetail {
    param($ErrorRecord)
    $detail = $ErrorRecord.ErrorDetails.Message
    if ($detail) { return $detail }
    try {
        if ($ErrorRecord.Exception.Response) {
            $stream = $ErrorRecord.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)
            $body = $reader.ReadToEnd()
            $reader.Close()
            if ($body) { return $body }
        }
    } catch { }
    return $null
}

function Invoke-GraphRequestDetailed {
    param(
        [Parameter(Mandatory=$true)][string]$Uri,
        [string]$Method = "GET",
        [string]$Body = $null,
        [string]$ContentType = "application/json",
        [Parameter(Mandatory=$true)][string]$StepDescription
    )
    $maxAttempts = 4
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            if ($Body) {
                return Invoke-MgGraphRequest -Uri $Uri -Method $Method -Body $Body -ContentType $ContentType -ErrorAction Stop
            }
            else {
                return Invoke-MgGraphRequest -Uri $Uri -Method $Method -ErrorAction Stop
            }
        }
        catch {
            # Graph rate-limits (429) or has brief service hiccups (503) far
            # more often during bulk operations working through many items
            # in a row than on a single one-off call - retrying with
            # backoff instead of immediately failing the whole run on the
            # first blip. Detected from the exception TEXT rather than a
            # structured status-code property, since this cmdlet's own
            # exceptions have already been confirmed elsewhere in this app
            # to carry the status as readable text (e.g. "BadRequest (Bad
            # Request)") rather than a reliably-populated .Response object.
            $isThrottled = $_.Exception.Message -match '429|TooManyRequests|Too Many Requests'
            $isTransient = $_.Exception.Message -match '503|ServiceUnavailable|Service Unavailable'
            # 429 always means the request was rejected BEFORE any
            # processing happened, so retrying it is always safe. 503 is
            # different specifically for POST - the server may have already
            # created the resource before the response was lost in transit,
            # and retrying could then create a duplicate (a second app
            # registration, a second group, etc). GET/PUT/PATCH/DELETE don't
            # have this risk, since repeating them with the same body
            # produces the same end state no matter how many times it's
            # applied.
            $safeToRetryTransient = $isTransient -and $Method -ne "POST"
            if (($isThrottled -or $safeToRetryTransient) -and $attempt -lt $maxAttempts) {
                $waitSeconds = $attempt * $attempt * 3   # 3s, 12s, 27s
                $reason = if ($isThrottled) { "Rate-limited" } else { "Service temporarily unavailable" }
                Write-Host "  [!] $reason - waiting ${waitSeconds}s before retry $($attempt+1)/$maxAttempts..." -ForegroundColor Yellow
                Start-Sleep -Seconds $waitSeconds
                continue
            }
            $detail = Get-HttpErrorDetail -ErrorRecord $_
            $msg = "$StepDescription failed [$Method $Uri]: $($_.Exception.Message)"
            if ($detail) { $msg += "`nResponse body: $detail" }
            throw $msg
        }
    }
}

function ConvertTo-Iso8601String {
    param($Value)
    if (-not $Value) { return $null }
    try {
        return ([datetime]$Value).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    }
    catch {
        return $Value
    }
}

Write-Step "Loading configuration"
if (-not (Test-Path $ConfigPath)) {
    Write-Host "[ERROR] Config file not found: $ConfigPath" -ForegroundColor Red
    exit 1
}
$Config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
Write-Host "  App (client) ID: $($Config.ClientId)" -ForegroundColor Gray
# Check mode never sends CertSubject/CertThumbprint at all - it only signs
# in and lists what's already trusted in Entra, with no local certificate
# involved. Only Upload/DeleteCert actually carry these, so only show the
# line when there's something real to show instead of printing it blank.
if ($Config.CertSubject) {
    Write-Host "  Certificate: $($Config.CertSubject) (thumbprint $($Config.CertThumbprint))" -ForegroundColor Gray
}

try {
    Write-Step "Signing in (interactive - uses YOUR account, not the app-only certificate)"
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    Write-Host "  A separate console window and a browser window should both open for" -ForegroundColor Yellow
    Write-Host "  sign-in - check for them if nothing seems to be happening (they can" -ForegroundColor Yellow
    Write-Host "  occasionally open behind other windows)." -ForegroundColor Yellow
    # Check asks for read-only, matching what it actually uses - NOT unified
    # with Upload's broader read-write scope, even though that would let a
    # later Upload silently reuse Check's cached sign-in (Microsoft Graph
    # PowerShell does cache tokens to disk and reuse them across separate
    # process launches, confirmed in Microsoft's own docs). Tried that first,
    # but Application.ReadWrite.All is sensitive enough that some tenants'
    # Conditional Access policies demand an extra verification step just for
    # requesting it - meaning even a plain Check started needing two
    # authentication steps instead of one. Making the common case (just
    # checking) worse to occasionally save a prompt on the rarer case
    # (check, then also upload) is the wrong trade - so Check goes back to
    # asking only for what it needs, and Upload doing the same after it may
    # need its own separate sign-in.
    $signInScope = if ($Config.Mode -eq "Check") { "Application.Read.All" } else { "Application.ReadWrite.All" }
    #
    # Deliberately NOT using -UseDeviceCode here, even though it would
    # otherwise be the more reliable choice for a hidden background process
    # (no dependency on a browser popup succeeding from a non-interactive
    # console). Confirmed via the Microsoft Graph PowerShell SDK's own open
    # issue tracker (GitHub issue #3495) that -UseDeviceCode currently
    # leaves the acquired token unusable - sign-in appears to succeed, but
    # every subsequent Graph call then fails with "DeviceCodeCredential
    # authentication failed: Object reference not set to an instance of an
    # object." The same report confirms regular interactive sign-in doesn't
    # have this problem, so that's what's used instead despite the
    # trade-off, until that SDK bug is fixed upstream.
    Connect-MgGraph -TenantId $Config.TenantId -Scopes $signInScope -NoWelcome -ErrorAction Stop
    $ctx = Get-MgContext -ErrorAction Stop
    Write-Host "  [OK] Signed in as $($ctx.Account)." -ForegroundColor Green

    Write-Step "Finding the app registration"
    $encodedFilter = [Uri]::EscapeDataString("appId eq '$($Config.ClientId)'")
    $appLookup = Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=$encodedFilter&`$select=id,displayName,keyCredentials" -Method GET -StepDescription "Look up app registration"
    if (-not $appLookup.value -or $appLookup.value.Count -eq 0) {
        throw "No app registration found with Application (client) ID '$($Config.ClientId)' in this tenant. Double check the Client ID in Settings, and that you signed into the right tenant just now."
    }
    $objectId = $appLookup.value[0].id
    $appDisplayName = $appLookup.value[0].displayName
    $existingRaw = @($appLookup.value[0].keyCredentials)
    Write-Host "  Found: $appDisplayName ($objectId)" -ForegroundColor Gray

    if ($Config.Mode -eq "Check") {
        Write-Step "Certificates currently trusted for this app registration"
        $certList = New-Object System.Collections.Generic.List[object]
        if ($existingRaw.Count -eq 0) {
            Write-Host "  (none - nothing has been uploaded yet)" -ForegroundColor Gray
        }
        $seenThumbprints = New-Object System.Collections.Generic.HashSet[string]
        foreach ($k in $existingRaw) {
            # customKeyIdentifier defaults to the certificate's thumbprint,
            # just base64-encoded instead of the usual hex string - decoded
            # back to hex here so it's directly comparable to the thumbprint
            # shown elsewhere in this app (e.g. "Certificate thumbprint" above).
            $thumbHex = ""
            if ($k.customKeyIdentifier) {
                try {
                    $thumbBytes = [System.Convert]::FromBase64String($k.customKeyIdentifier)
                    $thumbHex = ($thumbBytes | ForEach-Object { $_.ToString("X2") }) -join ''
                } catch { }
            }
            $expiry = if ($k.endDateTime) { ([datetime]$k.endDateTime).ToString("yyyy-MM-dd") } else { "?" }
            $dupeNote = if ($thumbHex -and -not $seenThumbprints.Add($thumbHex)) { "  (DUPLICATE thumbprint - same certificate uploaded more than once)" } else { "" }
            Write-Host "  - $($k.displayName)  [thumbprint $thumbHex]  expires $expiry$dupeNote" -ForegroundColor Gray
            # KeyId (not thumbprint) is what actually identifies THIS specific
            # entry - two entries can legitimately share a thumbprint if the
            # same certificate was uploaded more than once, and matching a
            # delete by thumbprint alone would remove all of them at once
            # instead of just the one selected.
            $certList.Add([pscustomobject]@{ DisplayName = $k.displayName; Thumbprint = $thumbHex; Expiry = $expiry; KeyId = $k.keyId })
        }
        Write-Step "Done"
        Write-Result -Success $true -ErrorMessage "" -Certificates $certList.ToArray()
        exit 0
    }

    if ($Config.Mode -eq "DeleteCert") {
        Write-Step "Removing certificate from this app registration"
        $keepKeys = New-Object System.Collections.Generic.List[object]
        $matchFound = $false
        foreach ($k in $existingRaw) {
            # Matched by keyId, NOT thumbprint - two entries can legitimately
            # share the same thumbprint if the same certificate was uploaded
            # more than once, and matching by thumbprint would remove every
            # entry that shares it instead of just the one that was selected.
            # keyId is the one property Graph guarantees is unique per entry.
            if ($k.keyId -eq $Config.KeyIdToDelete) {
                $matchFound = $true
                Write-Host "  Removing: $($k.displayName)  [keyId $($k.keyId)]" -ForegroundColor Gray
                continue
            }
            # Reconstructed from only the documented, safe-to-resend
            # properties - same reasoning as Upload's $preservedKeys, since
            # this PATCH is exactly as replace-not-merge as that one is.
            $keepKeys.Add(@{
                "@odata.type" = "#microsoft.graph.keyCredential"
                type          = $k.type
                usage         = $k.usage
                key           = $k.key
                displayName   = $k.displayName
                startDateTime = ConvertTo-Iso8601String $k.startDateTime
                endDateTime   = ConvertTo-Iso8601String $k.endDateTime
            })
        }
        if (-not $matchFound) {
            throw "No certificate with keyId $($Config.KeyIdToDelete) was found on this app registration - nothing removed. It may have already been removed by someone else since the list was last loaded."
        }
        $patchBody = @{ keyCredentials = $keepKeys.ToArray() } | ConvertTo-Json -Depth 10
        Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/v1.0/applications/$objectId" -Method PATCH -Body $patchBody -ContentType "application/json" -StepDescription "Remove certificate" | Out-Null
        Write-Host "  [OK] Removed - $($keepKeys.Count) certificate(s) remain." -ForegroundColor Green
        Write-Step "Done"
        Write-Result -Success $true -ErrorMessage ""
        exit 0
    }

    Write-Host "  Currently has $($existingRaw.Count) certificate(s)/key(s) registered - all will be kept." -ForegroundColor Gray

    # Skip entirely if this exact certificate is already registered - Graph
    # doesn't enforce uniqueness on keyCredentials, so re-uploading the same
    # certificate would otherwise create a second, indistinguishable entry.
    # That's exactly what caused an earlier bug: two entries ended up
    # sharing one thumbprint, and deleting "one" of them from the list
    # removed both, since thumbprint was the only thing being matched on.
    $alreadyPresent = $false
    foreach ($k in $existingRaw) {
        if ($k.customKeyIdentifier) {
            try {
                $existingThumbBytes = [System.Convert]::FromBase64String($k.customKeyIdentifier)
                $existingThumbHex = ($existingThumbBytes | ForEach-Object { $_.ToString("X2") }) -join ''
                if ($existingThumbHex -eq $Config.CertThumbprint) { $alreadyPresent = $true; break }
            } catch { }
        }
    }
    if ($alreadyPresent) {
        Write-Host "  This certificate (thumbprint $($Config.CertThumbprint)) is already registered - nothing to add." -ForegroundColor Yellow
        Write-Step "Done"
        Write-Result -Success $true -ErrorMessage ""
        exit 0
    }

    Write-Step "Adding the new certificate"
    # Reconstructed from only the documented, safe-to-resend properties,
    # rather than passing the raw GET response straight back through - keeps
    # this from accidentally echoing back any server-computed field that
    # doesn't belong in a request body.
    $preservedKeys = @($existingRaw | ForEach-Object {
        @{
            "@odata.type" = "#microsoft.graph.keyCredential"
            type          = $_.type
            usage         = $_.usage
            key           = $_.key
            displayName   = $_.displayName
            startDateTime = ConvertTo-Iso8601String $_.startDateTime
            endDateTime   = ConvertTo-Iso8601String $_.endDateTime
        }
    })

    $newKey = @{
        "@odata.type"  = "#microsoft.graph.keyCredential"
        type           = "AsymmetricX509Cert"
        usage          = "Verify"
        key            = $Config.CertBase64
        displayName    = $Config.CertSubject
        startDateTime  = ConvertTo-Iso8601String $Config.CertNotBefore
        endDateTime    = ConvertTo-Iso8601String $Config.CertNotAfter
    }

    $combinedKeys = @($preservedKeys) + @($newKey)
    $patchBody = @{ keyCredentials = $combinedKeys } | ConvertTo-Json -Depth 10
    Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/v1.0/applications/$objectId" -Method PATCH -Body $patchBody -ContentType "application/json" -StepDescription "Add certificate" | Out-Null
    Write-Host "  [OK] Certificate added - $($combinedKeys.Count) total now registered (kept all $($existingRaw.Count) existing one(s))." -ForegroundColor Green

    Write-Step "Done"
    Write-Host "[OK] It can take a few minutes for this to propagate before app-only sign-in with this certificate works." -ForegroundColor Green
    Write-Result -Success $true -ErrorMessage ""
    exit 0
}
catch {
    Write-Host ""
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    Write-Result -Success $false -ErrorMessage $_.Exception.Message
    exit 1
}

'@


# =====================================================================
# Data helpers
# =====================================================================
function ConvertTo-AppRecord {
    param($Raw)
    # Only present once metadata has actually been captured for an app
    # that doesn't exist in Intune yet (via Deploy to Intune's "Save for
    # later" option) - $null for every existing catalog entry until then,
    # so this stays fully backward compatible with every input.json
    # already in use.
    $metadata = $null
    if ($Raw.metadata) {
        $metadata = [pscustomobject]@{
            description      = [string]$Raw.metadata.description
            publisher        = [string]$Raw.metadata.publisher
            owner            = [string]$Raw.metadata.owner
            developer        = [string]$Raw.metadata.developer
            informationUrl   = [string]$Raw.metadata.informationUrl
            privacyUrl       = [string]$Raw.metadata.privacyUrl
            notes            = [string]$Raw.metadata.notes
            installCommand   = [string]$Raw.metadata.installCommand
            uninstallCommand = [string]$Raw.metadata.uninstallCommand
            # Comma-joined selection string, same as what the Deploy dialog
            # already builds and the Create-app script already knows how to
            # route correctly (a single value to applicableArchitectures, a
            # comma-joined one to allowedArchitectures) - reusing that
            # existing, already-fixed logic rather than re-deciding here.
            architecture     = [string]$Raw.metadata.architecture
            installContext   = [string]$Raw.metadata.installContext
            minOSKey         = [string]$Raw.metadata.minOSKey
            # Kept as a generic object, not re-typed here - its shape
            # varies by detection type (Script/Msi/File/Registry), and it
            # already matches the exact $Config.DetectionRule shape the
            # Create-app script expects, so it can be passed straight
            # through unchanged at actual deploy time.
            detectionRule    = $Raw.metadata.detectionRule
            # By NAME, not App ID - at the point metadata gets saved, a
            # dependency being referenced might not have an App ID yet
            # either, if it's also still pending its own first deploy.
            # Resolved to actual App IDs only at batch-deploy time, once
            # dependencies have had a chance to be created first.
            dependencies     = @($Raw.metadata.dependencies)
            # Requirements and install-experience/return-code fields below
            # all confirmed directly against Microsoft's own win32LobApp
            # schema docs before being added - minimumFreeDiskSpaceInMB,
            # minimumMemoryInMB, minimumNumberOfProcessors, and
            # minimumCpuSpeedInMHz are top-level Int32 fields (0 means "not
            # required", matching the portal's own "No X required" wording
            # for an unset value); deviceRestartBehavior and
            # maxRunTimeInMinutes live inside installExperience;
            # allowAvailableUninstall is a top-level boolean, defaulting to
            # false per the docs if never set; returnCodes is a collection
            # of {returnCode, type} pairs, same shape already used
            # elsewhere in this app for the fixed default set.
            minDiskSpaceMB          = if ($null -ne $Raw.metadata.minDiskSpaceMB) { [int]$Raw.metadata.minDiskSpaceMB } else { 0 }
            minMemoryMB             = if ($null -ne $Raw.metadata.minMemoryMB) { [int]$Raw.metadata.minMemoryMB } else { 0 }
            minProcessors           = if ($null -ne $Raw.metadata.minProcessors) { [int]$Raw.metadata.minProcessors } else { 0 }
            minCpuSpeedMHz          = if ($null -ne $Raw.metadata.minCpuSpeedMHz) { [int]$Raw.metadata.minCpuSpeedMHz } else { 0 }
            installTimeMinutes      = if ($null -ne $Raw.metadata.installTimeMinutes) { [int]$Raw.metadata.installTimeMinutes } else { 60 }
            deviceRestartBehavior   = if ($Raw.metadata.deviceRestartBehavior) { [string]$Raw.metadata.deviceRestartBehavior } else { "basedOnReturnCode" }
            allowAvailableUninstall = [bool]$Raw.metadata.allowAvailableUninstall
            # Kept as generic objects, not re-typed - same {returnCode,
            # type} shape the Create-app script's own hardcoded default
            # already uses, so it can be passed straight through unchanged.
            returnCodes             = @($Raw.metadata.returnCodes)
        }
    }
    [pscustomobject]@{
        appId        = [string]$Raw.appId
        appName      = [string]$Raw.appName
        wingetId     = [string]$Raw.wingetId
        # "uncommon" is no longer a stored field - see Test-AppIsUncommon.
        # Any stray "uncommon" key in an older input.json is simply ignored;
        # whether an app is common/uncommon is always derived from wingetId.
        requiredFor  = @($Raw.requiredFor)
        availableFor = @($Raw.availableFor)
        uninstallFor = @($Raw.uninstallFor)
        metadata     = $metadata
    }
}

function Load-AppsFromFile {
    param([string]$Path)

    # One-time automatic migration: if the new per-app folder doesn't exist
    # or is empty, but the OLD single-file input.json does, split it into
    # per-app files now rather than starting with an empty catalog. The
    # old file is renamed, not deleted, afterward - kept as a safety net
    # until the new format has actually proven itself in practice.
    $hasFolderData = (Test-Path $Path) -and (@(Get-ChildItem -Path $Path -Filter "*.json" -ErrorAction SilentlyContinue).Count -gt 0)
    if (-not $hasFolderData) {
        $oldSingleFilePath = Join-Path $Script:RootPath "input.json"
        if (Test-Path $oldSingleFilePath) {
            try {
                $rawOld = Get-Content -Path $oldSingleFilePath -Raw | ConvertFrom-Json
                if ($null -eq $rawOld) { $rawOld = @() }
                if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
                $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
                $migratedCount = 0
                foreach ($item in @($rawOld)) {
                    $record = ConvertTo-AppRecord $item
                    $fileName = (Get-SafeFileNameForApp -Name $record.appName) + ".json"
                    $filePath = Join-Path $Path $fileName
                    $json = ConvertTo-SingleAppJson -App $record
                    [System.IO.File]::WriteAllText($filePath, $json, $utf8NoBom)
                    $migratedCount++
                }
                $migratedBackupName = "input.json.migrated-$(Get-Date -Format 'yyyy-MM-dd_HHmmss')"
                Rename-Item -Path $oldSingleFilePath -NewName $migratedBackupName -Force -ErrorAction SilentlyContinue
                [System.Windows.Forms.MessageBox]::Show(
                    "Migrated $migratedCount app(s) from the old single input.json into one file per app in:`n$Path`n`nThe old file was kept, renamed to:`n$migratedBackupName",
                    "Migrated to per-app files", "OK", "Information") | Out-Null
            }
            catch {
                [System.Windows.Forms.MessageBox]::Show(
                    "Found an old input.json to migrate, but migration failed:`n$($_.Exception.Message)`n`nStarting with an empty catalog instead - the old file was left untouched, nothing was lost.",
                    "Migration failed", "OK", "Error") | Out-Null
            }
        }
    }

    if (-not (Test-Path $Path)) {
        [System.Windows.Forms.MessageBox]::Show(
            "No app data found at:`n$Path`n`nStarting with an empty catalog. Use Save to create it.",
            "No data found", "OK", "Warning") | Out-Null
        $Script:Apps.Clear()
        return
    }

    try {
        $files = @(Get-ChildItem -Path $Path -Filter "*.json" -ErrorAction SilentlyContinue)
        $Script:Apps.Clear()
        # One bad file no longer takes down the whole catalog load - each
        # app's file is now completely independent of every other one,
        # unlike the old single-array format where a single syntax error
        # anywhere broke loading everything, not just the one entry near it.
        $failedFiles = New-Object System.Collections.Generic.List[string]
        foreach ($file in $files) {
            try {
                $raw = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json
                [void]$Script:Apps.Add((ConvertTo-AppRecord $raw))
            }
            catch {
                $failedFiles.Add($file.Name)
            }
        }
        $Script:UnsavedChangesBox.Value = $false
        if ($failedFiles.Count -gt 0) {
            [System.Windows.Forms.MessageBox]::Show(
                "Loaded $($Script:Apps.Count) app(s) successfully, but these file(s) could not be parsed and were skipped:`n$($failedFiles -join "`n")",
                "Some files failed to load", "OK", "Warning") | Out-Null
        }
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Could not read app data from $Path`n`n$($_.Exception.Message)",
            "Load failed", "OK", "Error") | Out-Null
    }
}

# Minimal, predictable JSON string escaping - just the characters JSON actually
# requires escaping. Deliberately does NOT do ConvertTo-Json's HTML-style
# escaping of & < > etc.
function ConvertTo-JsonStringLiteral {
    param([string]$Value)
    if ($null -eq $Value) { return '""' }
    $escaped = $Value.Replace('\', '\\').Replace('"', '\"').Replace("`t", '\t').Replace("`r", '\r').Replace("`n", '\n')
    return '"' + $escaped + '"'
}

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
function ConvertTo-DetectionRuleJson {
    param($DetectionRule, [int]$IndentLevel)

    if (-not $DetectionRule) { return "null" }
    $pad = "  " * $IndentLevel
    $innerPad = "  " * ($IndentLevel + 1)
    $fields = New-Object System.Collections.Generic.List[string]

    switch ([string]$DetectionRule.Type) {
        "Script" {
            $fields.Add("$innerPad`"Type`": $(ConvertTo-JsonStringLiteral 'Script')")
            $fields.Add("$innerPad`"Script_Content`": $(ConvertTo-JsonStringLiteral $DetectionRule.Script_Content)")
        }
        "Msi" {
            $fields.Add("$innerPad`"Type`": $(ConvertTo-JsonStringLiteral 'Msi')")
            $fields.Add("$innerPad`"Msi_ProductCode`": $(ConvertTo-JsonStringLiteral $DetectionRule.Msi_ProductCode)")
            $fields.Add("$innerPad`"Msi_VersionOperator`": $(ConvertTo-JsonStringLiteral $DetectionRule.Msi_VersionOperator)")
            $fields.Add("$innerPad`"Msi_Version`": $(ConvertTo-JsonStringLiteral $DetectionRule.Msi_Version)")
        }
        "File" {
            $fields.Add("$innerPad`"Type`": $(ConvertTo-JsonStringLiteral 'File')")
            $fields.Add("$innerPad`"File_Path`": $(ConvertTo-JsonStringLiteral $DetectionRule.File_Path)")
            $fields.Add("$innerPad`"File_Name`": $(ConvertTo-JsonStringLiteral $DetectionRule.File_Name)")
            $fields.Add("$innerPad`"File_Check32Bit`": $(if ($DetectionRule.File_Check32Bit) { 'true' } else { 'false' })")
            $fields.Add("$innerPad`"File_DetectionType`": $(ConvertTo-JsonStringLiteral $DetectionRule.File_DetectionType)")
            $fields.Add("$innerPad`"File_Operator`": $(ConvertTo-JsonStringLiteral $DetectionRule.File_Operator)")
            $fields.Add("$innerPad`"File_DetectionValue`": $(ConvertTo-JsonStringLiteral $DetectionRule.File_DetectionValue)")
        }
        "Registry" {
            $fields.Add("$innerPad`"Type`": $(ConvertTo-JsonStringLiteral 'Registry')")
            $fields.Add("$innerPad`"Reg_KeyPath`": $(ConvertTo-JsonStringLiteral $DetectionRule.Reg_KeyPath)")
            $fields.Add("$innerPad`"Reg_ValueName`": $(ConvertTo-JsonStringLiteral $DetectionRule.Reg_ValueName)")
            $fields.Add("$innerPad`"Reg_Check32Bit`": $(if ($DetectionRule.Reg_Check32Bit) { 'true' } else { 'false' })")
            $fields.Add("$innerPad`"Reg_DetectionType`": $(ConvertTo-JsonStringLiteral $DetectionRule.Reg_DetectionType)")
            $fields.Add("$innerPad`"Reg_Operator`": $(ConvertTo-JsonStringLiteral $DetectionRule.Reg_Operator)")
            $fields.Add("$innerPad`"Reg_DetectionValue`": $(ConvertTo-JsonStringLiteral $DetectionRule.Reg_DetectionValue)")
        }
        default {
            # Shouldn't happen given the UI only ever produces these four
            # types, but falls back to null rather than silently dropping
            # data or producing invalid JSON if it ever does.
            return "null"
        }
    }
    return "{`r`n" + ($fields -join ",`r`n") + "`r`n$pad}"
}

function ConvertTo-JsonStringArray {
    param([string[]]$Items, [int]$IndentLevel)
    # Filters out null/empty entries explicitly, not just wraps and
    # counts - PowerShell coerces a $null element into an empty string
    # "" when binding to this [string[]] parameter, rather than leaving
    # it $null, so @($null) becoming a one-element array here doesn't
    # produce invalid JSON the way it did in the returnCodes case
    # elsewhere - but it DOES produce a real, silently wrong result:
    # ["",] instead of [] for a field that was actually empty/unset. A
    # genuine group or dependency name is never blank in practice, so
    # filtering these out is always correct, not just a defensive
    # workaround.
    $items = @($Items | Where-Object { $_ -and $_.Trim() })
    $pad = "  " * $IndentLevel
    if ($items.Count -eq 0) { return "[]" }
    $lines = for ($j = 0; $j -lt $items.Count; $j++) {
        $comma = if ($j -lt $items.Count - 1) { "," } else { "" }
        "$pad  $(ConvertTo-JsonStringLiteral $items[$j])$comma"
    }
    return "[`r`n" + ($lines -join "`r`n") + "`r`n$pad]"
}

# Hand-built serializer for a SINGLE app's own JSON object (2-space indent,
# single space after colons, literal & rather than \u0026, inline [] for
# empty arrays, one item per line for non-empty arrays) - same style
# already proven for the whole-catalog array, just producing one object
# instead of wrapping many in an array. Made to produce this directly
# rather than via fragile regex post-processing, for this known, fixed
# schema.
function ConvertTo-SingleAppJson {
    param($App)

    $fields = New-Object System.Collections.Generic.List[string]
    $fields.Add("  `"appId`": $(ConvertTo-JsonStringLiteral $App.appId)")
    $fields.Add("  `"appName`": $(ConvertTo-JsonStringLiteral $App.appName)")
    if ($App.wingetId) {
        $fields.Add("  `"wingetId`": $(ConvertTo-JsonStringLiteral $App.wingetId)")
    }
    $fields.Add("  `"requiredFor`": $(ConvertTo-JsonStringArray -Items @($App.requiredFor) -IndentLevel 1)")
    $fields.Add("  `"availableFor`": $(ConvertTo-JsonStringArray -Items @($App.availableFor) -IndentLevel 1)")
    $fields.Add("  `"uninstallFor`": $(ConvertTo-JsonStringArray -Items @($App.uninstallFor) -IndentLevel 1)")
    if ($App.metadata) {
        # Fully hand-rolled now, matching this whole file's style
        # throughout, rather than routing metadata through ConvertTo-Json
        # (previously the case here, and confirmed, directly and
        # repeatedly, to sometimes silently produce a completely empty
        # result with no error at all for certain inputs elsewhere in
        # this file). detectionRule is the one field with a genuinely
        # variable shape (Script/Msi/File/Registry), handled by its own
        # small, dedicated hand-rolled serializer above rather than
        # ConvertTo-Json - removing that cmdlet from this path entirely,
        # not just working around its known failure mode.
        $m = $App.metadata
        $metaFields = New-Object System.Collections.Generic.List[string]
        $metaFields.Add("    `"description`": $(ConvertTo-JsonStringLiteral $m.description)")
        $metaFields.Add("    `"publisher`": $(ConvertTo-JsonStringLiteral $m.publisher)")
        $metaFields.Add("    `"owner`": $(ConvertTo-JsonStringLiteral $m.owner)")
        $metaFields.Add("    `"developer`": $(ConvertTo-JsonStringLiteral $m.developer)")
        $metaFields.Add("    `"informationUrl`": $(ConvertTo-JsonStringLiteral $m.informationUrl)")
        $metaFields.Add("    `"privacyUrl`": $(ConvertTo-JsonStringLiteral $m.privacyUrl)")
        $metaFields.Add("    `"notes`": $(ConvertTo-JsonStringLiteral $m.notes)")
        $metaFields.Add("    `"installCommand`": $(ConvertTo-JsonStringLiteral $m.installCommand)")
        $metaFields.Add("    `"uninstallCommand`": $(ConvertTo-JsonStringLiteral $m.uninstallCommand)")
        $metaFields.Add("    `"architecture`": $(ConvertTo-JsonStringLiteral $m.architecture)")
        $metaFields.Add("    `"installContext`": $(ConvertTo-JsonStringLiteral $m.installContext)")
        $metaFields.Add("    `"minOSKey`": $(ConvertTo-JsonStringLiteral $m.minOSKey)")
        $metaFields.Add("    `"detectionRule`": $(ConvertTo-DetectionRuleJson -DetectionRule $m.detectionRule -IndentLevel 2)")
        $metaFields.Add("    `"dependencies`": $(ConvertTo-JsonStringArray -Items @($m.dependencies) -IndentLevel 2)")
        # Numeric fields explicitly default to "null" (valid JSON) rather
        # than interpolating $null directly, which would produce
        # "minDiskSpaceMB": , with nothing before the comma - invalid
        # JSON. Matters for apps saved before these fields existed at
        # all, where they'd genuinely be $null rather than 0.
        $metaFields.Add("    `"minDiskSpaceMB`": $(if ($null -ne $m.minDiskSpaceMB) { $m.minDiskSpaceMB } else { 'null' })")
        $metaFields.Add("    `"minMemoryMB`": $(if ($null -ne $m.minMemoryMB) { $m.minMemoryMB } else { 'null' })")
        $metaFields.Add("    `"minProcessors`": $(if ($null -ne $m.minProcessors) { $m.minProcessors } else { 'null' })")
        $metaFields.Add("    `"minCpuSpeedMHz`": $(if ($null -ne $m.minCpuSpeedMHz) { $m.minCpuSpeedMHz } else { 'null' })")
        $metaFields.Add("    `"installTimeMinutes`": $(if ($null -ne $m.installTimeMinutes) { $m.installTimeMinutes } else { 'null' })")
        $metaFields.Add("    `"deviceRestartBehavior`": $(ConvertTo-JsonStringLiteral $m.deviceRestartBehavior)")
        $metaFields.Add("    `"allowAvailableUninstall`": $(if ($m.allowAvailableUninstall) { 'true' } else { 'false' })")
        # Filters out $null explicitly before counting, rather than
        # trusting @($m.returnCodes).Count alone - confirmed, directly,
        # that PowerShell's @() doesn't turn a genuinely null value into
        # an empty array the way it does for an empty array or $null
        # element inside a real array. @($null) produces a ONE-element
        # array containing $null, not zero elements - so apps whose
        # returnCodes was never set at all (loaded from data that
        # predates this field) fell through to the "build real entries"
        # branch with one phantom null item, and interpolating $null
        # produced "returnCode": with nothing before the comma: invalid
        # JSON that then failed to parse and got silently skipped on
        # every subsequent load.
        $rcItems = @($m.returnCodes | Where-Object { $_ })
        if ($rcItems.Count -eq 0) {
            $metaFields.Add("    `"returnCodes`": []")
        }
        else {
            $rcLines = for ($j = 0; $j -lt $rcItems.Count; $j++) {
                $comma = if ($j -lt $rcItems.Count - 1) { "," } else { "" }
                "      { `"returnCode`": $($rcItems[$j].returnCode), `"type`": $(ConvertTo-JsonStringLiteral $rcItems[$j].type) }$comma"
            }
            $metaFields.Add("    `"returnCodes`": [`r`n" + ($rcLines -join "`r`n") + "`r`n    ]")
        }
        $fields.Add("  `"metadata`": {`r`n" + ($metaFields -join ",`r`n") + "`r`n  }")
    }

    return "{`r`n" + ($fields -join ",`r`n") + "`r`n}"
}

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
function ConvertTo-CreateAppConfigJson {
    param($Config)

    $fields = New-Object System.Collections.Generic.List[string]
    $fields.Add("  `"TenantId`": $(ConvertTo-JsonStringLiteral $Config.TenantId)")
    $fields.Add("  `"ClientId`": $(ConvertTo-JsonStringLiteral $Config.ClientId)")
    $fields.Add("  `"CertificateThumbprint`": $(ConvertTo-JsonStringLiteral $Config.CertificateThumbprint)")
    $fields.Add("  `"Mode`": $(ConvertTo-JsonStringLiteral $Config.Mode)")
    $fields.Add("  `"ExistingAppId`": $(ConvertTo-JsonStringLiteral $Config.ExistingAppId)")
    $fields.Add("  `"AppName`": $(ConvertTo-JsonStringLiteral $Config.AppName)")
    $fields.Add("  `"Description`": $(ConvertTo-JsonStringLiteral $Config.Description)")
    $fields.Add("  `"Publisher`": $(ConvertTo-JsonStringLiteral $Config.Publisher)")
    $fields.Add("  `"Owner`": $(ConvertTo-JsonStringLiteral $Config.Owner)")
    $fields.Add("  `"Developer`": $(ConvertTo-JsonStringLiteral $Config.Developer)")
    $fields.Add("  `"InformationUrl`": $(ConvertTo-JsonStringLiteral $Config.InformationUrl)")
    $fields.Add("  `"PrivacyUrl`": $(ConvertTo-JsonStringLiteral $Config.PrivacyUrl)")
    $fields.Add("  `"Notes`": $(ConvertTo-JsonStringLiteral $Config.Notes)")
    $fields.Add("  `"InstallCommand`": $(ConvertTo-JsonStringLiteral $Config.InstallCommand)")
    $fields.Add("  `"UninstallCommand`": $(ConvertTo-JsonStringLiteral $Config.UninstallCommand)")

    # DetectionRule now uses the same shared, hand-rolled serializer as
    # the catalog's own metadata.detectionRule, rather than its own
    # separate ConvertTo-Json call - removes ConvertTo-Json from this
    # path entirely, and keeps this field's formatting visually
    # consistent with the rest of this file wherever it's serialized.
    $fields.Add("  `"DetectionRule`": $(ConvertTo-DetectionRuleJson -DetectionRule $Config.DetectionRule -IndentLevel 1)")

    $fields.Add("  `"InstallContext`": $(ConvertTo-JsonStringLiteral $Config.InstallContext)")
    $fields.Add("  `"Architecture`": $(ConvertTo-JsonStringLiteral $Config.Architecture)")
    $fields.Add("  `"MinOSVersionKey`": $(ConvertTo-JsonStringLiteral $Config.MinOSVersionKey)")
    $fields.Add("  `"PackagePath`": $(ConvertTo-JsonStringLiteral $Config.PackagePath)")
    $fields.Add("  `"DependencyAppIds`": $(ConvertTo-JsonStringArray -Items @($Config.DependencyAppIds) -IndentLevel 1)")
    $fields.Add("  `"ReplaceContent`": $(if ($Config.ReplaceContent) { 'true' } else { 'false' })")
    $fields.Add("  `"MinDiskSpaceMB`": $($Config.MinDiskSpaceMB)")
    $fields.Add("  `"MinMemoryMB`": $($Config.MinMemoryMB)")
    $fields.Add("  `"MinProcessors`": $($Config.MinProcessors)")
    $fields.Add("  `"MinCpuSpeedMHz`": $($Config.MinCpuSpeedMHz)")
    $fields.Add("  `"InstallTimeMinutes`": $($Config.InstallTimeMinutes)")
    $fields.Add("  `"DeviceRestartBehavior`": $(ConvertTo-JsonStringLiteral $Config.DeviceRestartBehavior)")
    $fields.Add("  `"AllowAvailableUninstall`": $(if ($Config.AllowAvailableUninstall) { 'true' } else { 'false' })")

    # Filters out $null explicitly - same reasoning as the identical
    # pattern in ConvertTo-SingleAppJson: @($x) alone doesn't produce an
    # empty array when $x is genuinely $null, it produces a one-element
    # array containing that $null.
    $rcItems = @($Config.ReturnCodes | Where-Object { $_ })
    if ($rcItems.Count -eq 0) {
        $fields.Add("  `"ReturnCodes`": []")
    }
    else {
        $rcLines = for ($j = 0; $j -lt $rcItems.Count; $j++) {
            $comma = if ($j -lt $rcItems.Count - 1) { "," } else { "" }
            "    { `"returnCode`": $($rcItems[$j].returnCode), `"type`": $(ConvertTo-JsonStringLiteral $rcItems[$j].type) }$comma"
        }
        $fields.Add("  `"ReturnCodes`": [`r`n" + ($rcLines -join "`r`n") + "`r`n  ]")
    }

    $fields.Add("  `"OutputResultPath`": $(ConvertTo-JsonStringLiteral $Config.OutputResultPath)")

    return "{`r`n" + ($fields -join ",`r`n") + "`r`n}"
}

function Save-AppsToFile {
    param([string]$Path)

    $dupIds = $Script:Apps | Where-Object { $_.appId } | Group-Object appId | Where-Object { $_.Count -gt 1 }
    if ($dupIds) {
        $names = ($dupIds | ForEach-Object { $_.Name }) -join ", "
        $r = [System.Windows.Forms.MessageBox]::Show(
            "These App IDs are used by more than one app:`n$names`n`nSave anyway?",
            "Duplicate App IDs", "YesNo", "Warning")
        if ($r -ne "Yes") { return $false }
    }

    # Case-insensitive, whitespace-normalized - two entries that differ only
    # by casing or extra spaces still look identical everywhere this app
    # matches by name (Group Manager, App ID lookup, the drift check), and
    # would also collide on the derived package folder name for uncommon
    # apps, since that's computed directly from the name.
    $dupNames = $Script:Apps | Where-Object { $_.appName } | Group-Object { ($_.appName.Trim() -replace '\s+', ' ').ToLowerInvariant() } | Where-Object { $_.Count -gt 1 }
    if ($dupNames) {
        $names = ($dupNames | ForEach-Object { $_.Group[0].appName }) -join ", "
        $r2 = [System.Windows.Forms.MessageBox]::Show(
            "These app names are used by more than one entry:`n$names`n`nSave anyway?",
            "Duplicate app names", "YesNo", "Warning")
        if ($r2 -ne "Yes") { return $false }
    }

    # NOT just a warning like the two checks above - this one BLOCKS
    # outright, no "save anyway" option. Two apps with different real
    # names can still collide on the same derived FILENAME once unsafe
    # characters are stripped (e.g. "MyApp/Test" and "MyApp Test" both
    # become "MyApp-Test") - with one file per app now, that's not a
    # display inconsistency, it's one app's file silently overwriting the
    # other's on disk.
    $dupFileNames = $Script:Apps | Where-Object { $_.appName } | Group-Object { Get-SafeFileNameForApp -Name $_.appName } | Where-Object { $_.Count -gt 1 }
    if ($dupFileNames) {
        $collisionText = ($dupFileNames | ForEach-Object { "`"" + (($_.Group | ForEach-Object { $_.appName }) -join "`" and `"") + "`" both -> $($_.Name).json" }) -join "`n"
        [System.Windows.Forms.MessageBox]::Show(
            "These app names would collide on the same saved filename, once unsafe characters are stripped:`n`n$collisionText`n`nOne would silently overwrite the other's file. Rename one of them first, then save again.",
            "Filename collision - not saved", "OK", "Error") | Out-Null
        return $false
    }

    # A real, specific safety net - if the in-memory catalog is somehow
    # empty (a bug, or "Open other folder..." pointed somewhere unexpected)
    # while the target folder already holds real per-app files, saving
    # would otherwise delete every one of them as "no longer in the
    # catalog" (see the orphan cleanup below). That's not a save, it's
    # silently wiping out an entire existing catalog.
    if ($Script:Apps.Count -eq 0 -and (Test-Path $Path)) {
        $existingCount = @(Get-ChildItem -Path $Path -Filter "*.json" -ErrorAction SilentlyContinue).Count
        if ($existingCount -gt 0) {
            $r3 = [System.Windows.Forms.MessageBox]::Show(
                "The catalog in memory is empty, but $existingCount app file(s) already exist in:`n$Path`n`nSaving now would delete all of them. Save anyway?",
                "Empty catalog - confirm", "YesNo", "Warning")
            if ($r3 -ne "Yes") { return $false }
        }
    }

    # A backup of the WHOLE FOLDER as it was BEFORE this save, not a
    # safeguard against this specific save - if this save turns out to be
    # wrong, the backup is what lets you recover the version before it,
    # rather than the mistake being the only copy of the catalog that
    # still exists. One backup covers every app's file together, same as
    # the single-file version did, rather than one backup per app file.
    if (Test-Path $Path) {
        try {
            $backupDir = Join-Path $Script:RootPath "backups"
            if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
            $backupName = "apps-data_" + (Get-Date -Format "yyyy-MM-dd_HHmmss")
            Copy-Item -Path $Path -Destination (Join-Path $backupDir $backupName) -Recurse -Force -ErrorAction Stop

            # Keep the last 20 - enough recovery headroom without letting
            # the backups folder grow without bound over months of use.
            $existingBackups = Get-ChildItem -Path $backupDir -Filter "apps-data_*" -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
            if ($existingBackups.Count -gt 20) {
                $existingBackups | Select-Object -Skip 20 | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        catch {
            # A failed backup shouldn't block the actual save - it's a
            # safety net, not a prerequisite for saving.
        }
    }

    try {
        if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }

        # Write UTF-8 without a BOM explicitly, since Set-Content -Encoding UTF8 adds a
        # BOM on Windows PowerShell 5.1 but not on PowerShell 7+ - this keeps each file's
        # encoding identical (and Git diffs clean) regardless of which one runs this script.
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        $currentFileNames = New-Object System.Collections.Generic.HashSet[string]

        # Each app's write isolated in its own try/catch, not one shared
        # try around the whole loop - the same principle already applied
        # in Load-AppsFromFile: one app's data being unable to serialize
        # shouldn't block every OTHER app in the catalog from being saved
        # correctly. Failed apps are collected and reported clearly
        # afterward, rather than either silently skipping them or letting
        # one bad app take the whole save down with it.
        $failedSaveApps = New-Object System.Collections.Generic.List[string]
        # Logged once per save, not per app - confirms the in-memory
        # catalog's actual metadata state at the exact moment of writing,
        # right before any file gets touched. If an app that should have
        # metadata set (per a prior, separate log line from whatever
        # caller assigned it) doesn't show up here, the loss happened
        # somewhere between assignment and this save call - not inside
        # this function at all.
        $metaCountAtSave = @($Script:Apps | Where-Object { $_.metadata }).Count
        Write-Log "Save-AppsToFile: $metaCountAtSave of $($Script:Apps.Count) app(s) have metadata set at the start of this save.`r`n"
        foreach ($app in $Script:Apps) {
            $fileName = (Get-SafeFileNameForApp -Name $app.appName) + ".json"
            [void]$currentFileNames.Add($fileName)
            $filePath = Join-Path $Path $fileName
            try {
                $json = ConvertTo-SingleAppJson -App $app
                [System.IO.File]::WriteAllText($filePath, $json, $utf8NoBom)
            }
            catch {
                $failedSaveApps.Add("$($app.appName): $($_.Exception.Message)")
            }
        }

        # Removes files for apps no longer in the in-memory catalog -
        # otherwise a deleted or renamed app's old file would be left
        # behind forever, silently reappearing as a phantom entry the next
        # time the folder gets loaded.
        $existingFiles = Get-ChildItem -Path $Path -Filter "*.json" -ErrorAction SilentlyContinue
        foreach ($existingFile in $existingFiles) {
            if (-not $currentFileNames.Contains($existingFile.Name)) {
                Remove-Item -Path $existingFile.FullName -Force -ErrorAction SilentlyContinue
            }
        }

        # Always reported, and reported clearly, if even one app's save
        # failed - a caller checking only the boolean return must not see
        # a plain success when even one app's data didn't actually
        # persist. Returning $false here on any failure, not just when
        # every app fails, so the caller's own existing "save failed"
        # handling takes over correctly instead of also reporting success
        # right alongside this warning.
        if ($failedSaveApps.Count -gt 0) {
            [System.Windows.Forms.MessageBox]::Show(
                "$($Script:Apps.Count - $failedSaveApps.Count) of $($Script:Apps.Count) app(s) saved. These failed and were left unchanged on disk:`n`n$($failedSaveApps -join "`n")",
                "Some apps failed to save", "OK", "Warning") | Out-Null
            return $false
        }

        $Script:UnsavedChangesBox.Value = $false
        return $true
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Could not save to $Path`n`n$($_.Exception.Message)",
            "Save failed", "OK", "Error") | Out-Null
        return $false
    }
}

function Get-AllKnownGroups {
    $set = New-Object System.Collections.Generic.HashSet[string]
    foreach ($app in $Script:Apps) {
        foreach ($g in @($app.requiredFor))  { [void]$set.Add($g) }
        foreach ($g in @($app.availableFor)) { [void]$set.Add($g) }
        foreach ($g in @($app.uninstallFor)) { [void]$set.Add($g) }
    }
    return ($set | Sort-Object)
}

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
function Add-RemovableItemContextMenu {
    param($CheckedListBox)

    $ctxMenu = New-Object System.Windows.Forms.ContextMenuStrip
    $miRemove = New-Object System.Windows.Forms.ToolStripMenuItem "Remove from list"
    [void]$ctxMenu.Items.Add($miRemove)
    # Mutable container, not a plain variable - written by the mouse-down
    # handler below, read by the menu item's own, separately-created
    # click handler.
    $rightClickedIndexBox = @{ Value = -1 }

    $CheckedListBox.Add_MouseDown({
        param($clbSender, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
            $idx = $clbSender.IndexFromPoint($e.Location)
            $rightClickedIndexBox.Value = $idx
            if ($idx -ge 0) { $clbSender.SelectedIndex = $idx }
        }
    }.GetNewClosure())

    $miRemove.Add_Click({
        $idx = $rightClickedIndexBox.Value
        if ($idx -lt 0 -or $idx -ge $CheckedListBox.Items.Count) { return }
        if ($CheckedListBox.GetItemChecked($idx)) {
            [System.Windows.Forms.MessageBox]::Show("`"$($CheckedListBox.Items[$idx])`" is currently checked - uncheck it first, then remove it.", "Still checked", "OK", "Warning") | Out-Null
            return
        }
        $CheckedListBox.Items.RemoveAt($idx)
    }.GetNewClosure())

    $CheckedListBox.ContextMenuStrip = $ctxMenu
}

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
function Start-WingetSearch {
    param([string]$Query, [scriptblock]$OnComplete)

    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        param($SearchQuery)

        $wingetCmd = Get-Command winget.exe -ErrorAction SilentlyContinue
        if (-not $wingetCmd) {
            throw "winget.exe not found on this machine. It ships with the 'App Installer' package on modern Windows 10/11 - make sure it's installed and in PATH."
        }

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $wingetCmd.Source
        $psi.Arguments = "search `"$SearchQuery`" --accept-source-agreements --disable-interactivity"
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        [void]$proc.Start()

        # Kick off BOTH stream reads concurrently, in the background, before
        # waiting on the process at all. Reading stdout and stderr
        # sequentially (ReadToEnd on one, then the other) is a well-known
        # .NET deadlock: if winget writes enough to stderr to fill the OS
        # pipe buffer while we're still blocked reading stdout, winget
        # itself blocks trying to write - and neither side can ever
        # proceed. That made the 30s timeout below unreachable, since we'd
        # already be stuck on the ReadToEnd call before ever getting to it -
        # which is exactly why search could hang indefinitely with no
        # timeout ever kicking in.
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()

        if (-not $proc.WaitForExit(30000)) {
            try { $proc.Kill() } catch { }
            throw "winget search timed out after 30 seconds."
        }

        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()

        if ($proc.ExitCode -ne 0 -and -not $stdout) {
            throw "winget search failed (exit code $($proc.ExitCode)): $stderr"
        }

        # winget's default output is a human-readable table sized to its
        # content, not fixed-width columns - so locate each column by where
        # its header text starts, then slice every data row at those same
        # character offsets. This is the standard, well-established approach
        # for parsing this output; it can still be thrown off by unusual
        # package names/locales, since winget doesn't offer a machine
        # readable format for search specifically.
        $lines = $stdout -split "`r?`n" | Where-Object { $_.TrimEnd() -ne "" }
        $headerIdx = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^Name\s+Id\s+Version') { $headerIdx = $i; break }
        }
        if ($headerIdx -eq -1) {
            return ,@()   # "No package found..." or similar - just no results, not an error
        }

        $header = $lines[$headerIdx]
        $idPos      = $header.IndexOf("Id")
        $versionPos = $header.IndexOf("Version")
        $matchPos   = $header.IndexOf("Match")
        $sourcePos  = $header.IndexOf("Source")

        $results = New-Object System.Collections.Generic.List[object]
        for ($i = $headerIdx + 2; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            if ($line.Length -lt $idPos) { continue }

            $name = $line.Substring(0, $idPos).Trim()
            $idEnd = if ($versionPos -gt $idPos -and $versionPos -le $line.Length) { $versionPos } else { $line.Length }
            $id = $line.Substring($idPos, [Math]::Max(0, $idEnd - $idPos)).Trim()

            $versionEnd =
                if ($matchPos -gt $versionPos -and $matchPos -le $line.Length) { $matchPos }
                elseif ($sourcePos -gt $versionPos -and $sourcePos -le $line.Length) { $sourcePos }
                else { $line.Length }
            $version = if ($versionPos -ge 0 -and $versionPos -lt $line.Length) { $line.Substring($versionPos, [Math]::Max(0, $versionEnd - $versionPos)).Trim() } else { "" }

            $source = if ($sourcePos -ge 0 -and $sourcePos -lt $line.Length) { $line.Substring($sourcePos).Trim() } else { "" }

            if ($name -and $id) {
                $results.Add([pscustomobject]@{ Name = $name; Id = $id; Version = $version; Source = $source })
            }
        }
        return ,$results.ToArray()
    }).AddArgument($Query)

    $handle = $ps.BeginInvoke()
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 300
    $timer.Add_Tick({
        if (-not $handle.IsCompleted) { return }
        $timer.Stop()
        $timer.Dispose()

        try {
            $raw = @($ps.EndInvoke($handle))
            if ($ps.Streams.Error.Count -gt 0) {
                $errMsg = ($ps.Streams.Error | ForEach-Object { $_.ToString() }) -join "`n"
                if ($OnComplete) { & $OnComplete $false $errMsg }
            }
            else {
                $results = if ($raw.Count -gt 0) { $raw[0] } else { @() }
                if ($OnComplete) { & $OnComplete $true $results }
            }
        }
        catch {
            if ($OnComplete) { & $OnComplete $false $_.Exception.Message }
        }
        finally {
            $ps.Dispose()
            $rs.Close()
            $rs.Dispose()
        }
    }.GetNewClosure())
    $timer.Start()
}

# =====================================================================
# Fetches every app currently registered in Intune (id + displayName) via
# Microsoft Graph, using the same app-only certificate authentication as
# 5_AssignGroupsAndNames.ps1 (see $Script:GraphTenantId / GraphClientId /
# GraphCertificateThumbprint above) - no interactive sign-in required, but the
# certificate must be installed in this machine's/user's certificate store.
# Runs on a background runspace so the GUI doesn't freeze during the call.
# $OnComplete is called with ($success, $data) where $data is either the
# array of apps or an error message string.
function Test-GraphCredentialsConfigured {
    if ($Script:GraphTenantId -and $Script:GraphClientId -and $Script:GraphCertificateThumbprint) { return $true }
    [System.Windows.Forms.MessageBox]::Show(
        "No Graph connection is configured yet. Open 'Settings...' in the Tools group and fill in your Tenant ID, Client ID, and certificate first.",
        "Not configured", "OK", "Warning") | Out-Null
    return $false
}

function Start-IntuneAppLookup {
    param([scriptblock]$OnComplete)

    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        [System.Windows.Forms.MessageBox]::Show(
            "The Microsoft.Graph.Authentication module isn't installed.`n`nInstall it with:`nInstall-Module Microsoft.Graph.Authentication -Scope CurrentUser",
            "Module missing", "OK", "Warning") | Out-Null
        if ($OnComplete) { & $OnComplete $false "Module missing" }
        return
    }

    if (-not (Test-GraphCredentialsConfigured)) {
        if ($OnComplete) { & $OnComplete $false "Not configured" }
        return
    }

    if (-not $btnLookupIds.Enabled) {
        Write-Log "A lookup is already running - please wait for it to finish.`r`n" ([System.Drawing.Color]::Orange)
        return
    }

    $btnLookupIds.Enabled = $false
    Write-Log "=== Looking up app IDs from Intune (Microsoft Graph, app-only via certificate) ===`r`n" ([System.Drawing.Color]::DeepSkyBlue)
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

    # Plain (non-$Script:) local alias - closures reliably capture plain variables via
    # GetNewClosure(), but do NOT reliably see live $Script: state from inside the closure.
    # $Script:IntuneAppsCache is an ArrayList (reference type) so mutating it through this
    # alias is visible everywhere else that reads $Script:IntuneAppsCache normally.
    $cache = $Script:IntuneAppsCache

    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        param($TenantId, $ClientId, $CertThumb)
        Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
        $ctx = Get-MgContext -ErrorAction SilentlyContinue
        if ($null -eq $ctx -or $ctx.AuthType -ne 'AppOnly' -or $ctx.ClientId -ne $ClientId) {
            Connect-MgGraph -TenantId $TenantId -ClientId $ClientId `
                -CertificateThumbprint $CertThumb -NoWelcome -ErrorAction Stop
        }
        $ctx = Get-MgContext -ErrorAction Stop

        $apps = New-Object System.Collections.Generic.List[object]
        $uri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?`$top=999"
        do {
            $result = Invoke-MgGraphRequest -Uri $uri -Method GET -ErrorAction Stop
            foreach ($item in $result.value) {
                $apps.Add([pscustomobject]@{ id = $item.id; displayName = $item.displayName })
            }
            $uri = $result.'@odata.nextLink'
        } while ($uri)

        [pscustomobject]@{
            Apps     = $apps.ToArray()
            AuthType = $ctx.AuthType
            AppName  = $ctx.AppName
            ClientId = $ctx.ClientId
            TenantId = $ctx.TenantId
        }
    }).AddArgument($Script:GraphTenantId).AddArgument($Script:GraphClientId).AddArgument($Script:GraphCertificateThumbprint)

    $handle = $ps.BeginInvoke()
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 300
    $timer.Add_Tick({
        if (-not $handle.IsCompleted) { return }
        $timer.Stop()
        $timer.Dispose()
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default
        $btnLookupIds.Enabled = $true

        try {
            $raw = @($ps.EndInvoke($handle))
            if ($ps.Streams.Error.Count -gt 0) {
                $errMsg = ($ps.Streams.Error | ForEach-Object { $_.ToString() }) -join "`n"
                Write-Log "[ERROR] $errMsg`r`n" ([System.Drawing.Color]::Tomato)
                if ($OnComplete) { & $OnComplete $false $errMsg }
            }
            elseif ($raw.Count -eq 0) {
                Write-Log "[ERROR] No response came back from the lookup runspace.`r`n" ([System.Drawing.Color]::Tomato)
                if ($OnComplete) { & $OnComplete $false "No response from lookup" }
            }
            else {
                $info = $raw[0]
                $cache.Clear()
                foreach ($a in @($info.Apps)) { [void]$cache.Add($a) }
                Write-Log "Connected app-only as '$($info.AppName)' (client $($info.ClientId), tenant $($info.TenantId)).`r`n" ([System.Drawing.Color]::Gainsboro)
                Write-Log "Cache now holds $($cache.Count) app(s).`r`n" ([System.Drawing.Color]::Gainsboro)
                if ($cache.Count -eq 0) {
                    Write-Log "Graph returned 0 apps from /deviceAppManagement/mobileApps.`r`n" ([System.Drawing.Color]::Orange)
                    Write-Log "Check that this app registration's APPLICATION permission 'DeviceManagementApps.Read.All' (or ReadWrite.All) has admin consent - Delegated permissions used by interactive sign-in scripts do not carry over to app-only auth.`r`n" ([System.Drawing.Color]::Orange)
                }
                else {
                    Write-Log "Fetched $($cache.Count) apps from Intune. Names returned:`r`n" ([System.Drawing.Color]::LightGreen)
                    foreach ($n in ($cache | Sort-Object displayName | ForEach-Object { $_.displayName })) {
                        Write-Log "    - $n`r`n" ([System.Drawing.Color]::Gainsboro)
                    }
                }
                if ($OnComplete) { & $OnComplete $true $cache }
            }
        }
        catch {
            Write-Log "[ERROR] $($_.Exception.Message)`r`n" ([System.Drawing.Color]::Tomato)
            if ($OnComplete) { & $OnComplete $false $_.Exception.Message }
        }
        finally {
            $ps.Dispose()
            $rs.Close()
            $rs.Dispose()
        }
    }.GetNewClosure())
    $timer.Start()
}

# Fetches every group and user in Entra ID (id, displayName, and for users their
# UPN) via Microsoft Graph, using the same app-only certificate identity as
# Start-IntuneAppLookup. Requires the app registration to have Group.Read.All
# and User.Read.All (or Directory.Read.All) as APPLICATION permissions with
# admin consent - separate from whatever DeviceManagementApps permission the
# App ID lookup needs. $OnComplete is called with ($success, $data) where
# $data is either the array of entries or an error message string.
function Start-EntraDirectoryLookup {
    param([scriptblock]$OnComplete)

    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        [System.Windows.Forms.MessageBox]::Show(
            "The Microsoft.Graph.Authentication module isn't installed.`n`nInstall it with:`nInstall-Module Microsoft.Graph.Authentication -Scope CurrentUser",
            "Module missing", "OK", "Warning") | Out-Null
        if ($OnComplete) { & $OnComplete $false "Module missing" }
        return
    }

    if (-not (Test-GraphCredentialsConfigured)) {
        if ($OnComplete) { & $OnComplete $false "Not configured" }
        return
    }

    Write-Log "=== Looking up groups and users from Entra ID (Microsoft Graph, app-only via certificate) ===`r`n" ([System.Drawing.Color]::DeepSkyBlue)
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

    # Plain local alias - see note in Start-IntuneAppLookup.
    $cache = $Script:EntraDirectoryCache

    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        param($TenantId, $ClientId, $CertThumb)
        Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
        $ctx = Get-MgContext -ErrorAction SilentlyContinue
        if ($null -eq $ctx -or $ctx.AuthType -ne 'AppOnly' -or $ctx.ClientId -ne $ClientId) {
            Connect-MgGraph -TenantId $TenantId -ClientId $ClientId `
                -CertificateThumbprint $CertThumb -NoWelcome -ErrorAction Stop
        }
        $ctx = Get-MgContext -ErrorAction Stop

        $entries = New-Object System.Collections.Generic.List[object]

        $uri = "https://graph.microsoft.com/v1.0/groups?`$select=id,displayName&`$top=999"
        do {
            $result = Invoke-MgGraphRequest -Uri $uri -Method GET -ErrorAction Stop
            foreach ($item in $result.value) {
                $entries.Add([pscustomobject]@{ displayName = $item.displayName; type = "Group"; id = $item.id; upn = "" })
            }
            $uri = $result.'@odata.nextLink'
        } while ($uri)

        $uri = "https://graph.microsoft.com/v1.0/users?`$select=id,displayName,userPrincipalName&`$top=999"
        do {
            $result = Invoke-MgGraphRequest -Uri $uri -Method GET -ErrorAction Stop
            foreach ($item in $result.value) {
                $entries.Add([pscustomobject]@{ displayName = $item.displayName; type = "User"; id = $item.id; upn = $item.userPrincipalName })
            }
            $uri = $result.'@odata.nextLink'
        } while ($uri)

        [pscustomobject]@{
            Entries  = $entries.ToArray()
            AppName  = $ctx.AppName
        }
    }).AddArgument($Script:GraphTenantId).AddArgument($Script:GraphClientId).AddArgument($Script:GraphCertificateThumbprint)

    $handle = $ps.BeginInvoke()
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 300
    $timer.Add_Tick({
        if (-not $handle.IsCompleted) { return }
        $timer.Stop()
        $timer.Dispose()
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default

        try {
            $raw = @($ps.EndInvoke($handle))
            if ($ps.Streams.Error.Count -gt 0) {
                $errMsg = ($ps.Streams.Error | ForEach-Object { $_.ToString() }) -join "`n"
                Write-Log "[ERROR] $errMsg`r`n" ([System.Drawing.Color]::Tomato)
                if ($OnComplete) { & $OnComplete $false $errMsg }
            }
            elseif ($raw.Count -eq 0) {
                Write-Log "[ERROR] No response came back from the lookup runspace.`r`n" ([System.Drawing.Color]::Tomato)
                if ($OnComplete) { & $OnComplete $false "No response from lookup" }
            }
            else {
                $info = $raw[0]
                $cache.Clear()
                foreach ($e in @($info.Entries)) { [void]$cache.Add($e) }
                $groupCount = @($cache | Where-Object { $_.type -eq "Group" }).Count
                $userCount  = @($cache | Where-Object { $_.type -eq "User" }).Count
                Write-Log "Connected app-only as '$($info.AppName)'. Loaded $groupCount group(s) and $userCount user(s).`r`n" ([System.Drawing.Color]::LightGreen)
                if ($OnComplete) { & $OnComplete $true $cache }
            }
        }
        catch {
            Write-Log "[ERROR] $($_.Exception.Message)`r`n" ([System.Drawing.Color]::Tomato)
            if ($OnComplete) { & $OnComplete $false $_.Exception.Message }
        }
        finally {
            $ps.Dispose()
            $rs.Close()
            $rs.Dispose()
        }
    }.GetNewClosure())
    $timer.Start()
}

# Returns Intune apps whose displayName relates to $Name: exact matches first,
# then partial (contains, either direction) matches.
function Find-IntuneMatches {
    param([string]$Name)

    # Build the result as an explicit List and return it with a leading comma.
    # Without the comma, PowerShell unrolls the returned array onto the output
    # stream; an empty array unrolled produces ZERO output objects, so the
    # caller's "$candidates = Find-IntuneMatches ..." assignment would get
    # $null instead of an empty array - and $null.Count silently reads back
    # as $null too, which is why this looked like "no matches anywhere."
    $results = New-Object System.Collections.Generic.List[object]
    if (-not $Name) { return ,$results.ToArray() }

    $normalizedName = ($Name.Trim() -replace '\s+', ' ')

    foreach ($candidate in $Script:IntuneAppsCache) {
        $normDisplay = ($candidate.displayName.Trim() -replace '\s+', ' ')
        if ($normDisplay -eq $normalizedName) {
            $results.Add($candidate)
        }
    }
    foreach ($candidate in $Script:IntuneAppsCache) {
        $normDisplay = ($candidate.displayName.Trim() -replace '\s+', ' ')
        if ($normDisplay -ne $normalizedName -and (
            $normDisplay -like "*$normalizedName*" -or $normalizedName -like "*$normDisplay*"
        )) {
            $results.Add($candidate)
        }
    }
    return ,$results.ToArray()
}

# Search/browse picker for Entra ID groups and users, backed by
# $Script:EntraDirectoryCache. Includes a manual-entry fallback (whatever's
# typed in the search box is used if nothing in the list is selected) and a
# Refresh button to (re)run Start-EntraDirectoryLookup without leaving the
# dialog. Returns the chosen/typed display name, or $null if cancelled.
function Show-EntraMemberPicker {
    # Plain local alias - see note in Start-IntuneAppLookup. $UpdateStatus and
    # $RefreshList below are closures; even a single level of GetNewClosure()
    # does not reliably see $Script:-qualified variables, only plain ones.
    $cache = $Script:EntraDirectoryCache

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Add group or user"
    $dlg.ClientSize = New-Object System.Drawing.Size(480, 420)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $lblSearch = New-Object System.Windows.Forms.Label
    $lblSearch.Text = "Search, or type a name directly if it's not listed:"
    $lblSearch.Location = New-Object System.Drawing.Point(12,12)
    $lblSearch.AutoSize = $true
    $dlg.Controls.Add($lblSearch)

    $txtSearch = New-Object System.Windows.Forms.TextBox
    $txtSearch.Location = New-Object System.Drawing.Point(12,32)
    $txtSearch.Size = New-Object System.Drawing.Size(368,24)
    $dlg.Controls.Add($txtSearch)

    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = "Refresh"
    $btnRefresh.Location = New-Object System.Drawing.Point(388,31)
    $btnRefresh.Size = New-Object System.Drawing.Size(80,26)
    $dlg.Controls.Add($btnRefresh)

    $lst = New-Object System.Windows.Forms.ListBox
    $lst.Location = New-Object System.Drawing.Point(12,64)
    $lst.Size = New-Object System.Drawing.Size(456,260)
    $dlg.Controls.Add($lst)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Location = New-Object System.Drawing.Point(12,328)
    $lblStatus.Size = New-Object System.Drawing.Size(456,36)
    $dlg.Controls.Add($lblStatus)

    $btnAdd = New-Object System.Windows.Forms.Button
    $btnAdd.Text = "Add"
    $btnAdd.Location = New-Object System.Drawing.Point(300,370)
    $btnAdd.Size = New-Object System.Drawing.Size(80,30)
    $dlg.Controls.Add($btnAdd)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(388,370)
    $btnCancel.Size = New-Object System.Drawing.Size(80,30)
    $dlg.Controls.Add($btnCancel)

    $UpdateStatus = {
        if ($cache.Count -eq 0) {
            $lblStatus.Text = "Nothing loaded yet - click Refresh to browse Entra ID, or just type a name and Add."
            $lblStatus.ForeColor = [System.Drawing.Color]::DarkOrange
        } else {
            $groupCount = @($cache | Where-Object { $_.type -eq "Group" }).Count
            $userCount  = @($cache | Where-Object { $_.type -eq "User" }).Count
            $lblStatus.Text = "Loaded $groupCount group(s), $userCount user(s) from Entra ID."
            $lblStatus.ForeColor = [System.Drawing.Color]::SeaGreen
        }
    }.GetNewClosure()

    $RefreshList = {
        $term = $txtSearch.Text.Trim()
        $lst.Items.Clear()
        $filtered = $cache
        if ($term) {
            $filtered = @($filtered | Where-Object { $_.displayName -like "*$term*" })
        }
        $shown = $filtered | Sort-Object type, displayName | Select-Object -First 200
        foreach ($m in $shown) {
            $label = if ($m.type -eq "User" -and $m.upn) { "[User] $($m.displayName) ($($m.upn))" } else { "[$($m.type)] $($m.displayName)" }
            [void]$lst.Items.Add($label)
        }
    }.GetNewClosure()

    & $UpdateStatus
    & $RefreshList

    $txtSearch.Add_TextChanged({ & $RefreshList }.GetNewClosure())
    $lst.Add_DoubleClick({ $btnAdd.PerformClick() }.GetNewClosure())

    $btnRefresh.Add_Click({
        $btnRefresh.Enabled = $false
        $lblStatus.Text = "Connecting to Entra ID..."
        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray

        # Fresh local aliases for everything the nested -OnComplete closure below
        # touches - a closure nested inside this already-closured Add_Click does
        # not reliably re-capture variables THIS handler itself only inherited
        # from the outer Show-EntraMemberPicker scope (see the note in
        # Show-CertificateSetupDialog's Test Connection handler).
        $btnRefreshRef   = $btnRefresh
        $lblStatusRef    = $lblStatus
        $updateStatusRef = $UpdateStatus
        $refreshListRef  = $RefreshList

        Start-EntraDirectoryLookup -OnComplete {
            param($ok, $msg)
            $btnRefreshRef.Enabled = $true
            if ($ok) {
                & $updateStatusRef
                & $refreshListRef
            } else {
                $lblStatusRef.Text = "Failed: $msg"
                $lblStatusRef.ForeColor = [System.Drawing.Color]::Firebrick
            }
        }.GetNewClosure()
    }.GetNewClosure())

    $resultBox = @{ Value = $null }

    $btnAdd.Add_Click({
        if ($lst.SelectedItem) {
            $text = [string]$lst.SelectedItem
            if ($text -match '^\[(?:Group|User)\]\s+(.+?)(?:\s+\([^)]*\))?$') {
                $resultBox.Value = $Matches[1]
            } else {
                $resultBox.Value = $text
            }
        }
        elseif ($txtSearch.Text.Trim()) {
            $resultBox.Value = $txtSearch.Text.Trim()
        }
        else {
            [System.Windows.Forms.MessageBox]::Show("Select an item from the list, or type a name.", "Nothing to add", "OK", "Information") | Out-Null
            return
        }
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dlg.Close()
    }.GetNewClosure())

    $btnCancel.Add_Click({ $dlg.Close() }.GetNewClosure())

    $dlg.CancelButton = $btnCancel
    $dlg.AcceptButton = $btnAdd
    Set-Theme -Control $dlg
    $result = $dlg.ShowDialog($form)
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) { return $resultBox.Value }
    return $null
}

# Same search/refresh pattern as Show-EntraMemberPicker, but filtered to
# groups only and framed as "pick a target group" rather than "add a
# member" - used by Group Manager so you can find an existing group by name
# instead of typing one blind and risking an accidental near-duplicate from
# a typo or casing difference. Written as its own function rather than
# parameterizing Show-EntraMemberPicker, since that function already has
# established callers (the catalog's group pickers) that shouldn't be put
# at risk by changes made for this unrelated use.
function Show-GroupOnlyPicker {
    # Plain local alias - see note in Start-IntuneAppLookup.
    $cache = $Script:EntraDirectoryCache

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Find a group"
    $dlg.ClientSize = New-Object System.Drawing.Size(480, 420)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $lblSearch = New-Object System.Windows.Forms.Label
    $lblSearch.Text = "Search, or type a new name directly if it doesn't exist yet:"
    $lblSearch.Location = New-Object System.Drawing.Point(12,12)
    $lblSearch.AutoSize = $true
    $dlg.Controls.Add($lblSearch)

    $txtSearch = New-Object System.Windows.Forms.TextBox
    $txtSearch.Location = New-Object System.Drawing.Point(12,32)
    $txtSearch.Size = New-Object System.Drawing.Size(368,24)
    $dlg.Controls.Add($txtSearch)

    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = "Refresh"
    $btnRefresh.Location = New-Object System.Drawing.Point(388,31)
    $btnRefresh.Size = New-Object System.Drawing.Size(80,26)
    $dlg.Controls.Add($btnRefresh)

    $lst = New-Object System.Windows.Forms.ListBox
    $lst.Location = New-Object System.Drawing.Point(12,64)
    $lst.Size = New-Object System.Drawing.Size(456,260)
    $dlg.Controls.Add($lst)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Location = New-Object System.Drawing.Point(12,328)
    $lblStatus.Size = New-Object System.Drawing.Size(456,36)
    $dlg.Controls.Add($lblStatus)

    $btnSelect = New-Object System.Windows.Forms.Button
    $btnSelect.Text = "Select"
    $btnSelect.Location = New-Object System.Drawing.Point(300,370)
    $btnSelect.Size = New-Object System.Drawing.Size(80,30)
    $dlg.Controls.Add($btnSelect)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(388,370)
    $btnCancel.Size = New-Object System.Drawing.Size(80,30)
    $dlg.Controls.Add($btnCancel)

    $UpdateStatus = {
        $groupCount = @($cache | Where-Object { $_.type -eq "Group" }).Count
        if ($cache.Count -eq 0) {
            $lblStatus.Text = "Nothing loaded yet - click Refresh to browse Entra ID, or just type a name and Select."
            $lblStatus.ForeColor = [System.Drawing.Color]::DarkOrange
        } else {
            $lblStatus.Text = "Loaded $groupCount group(s) from Entra ID."
            $lblStatus.ForeColor = [System.Drawing.Color]::SeaGreen
        }
    }.GetNewClosure()

    $RefreshList = {
        $term = $txtSearch.Text.Trim()
        $lst.Items.Clear()
        $filtered = @($cache | Where-Object { $_.type -eq "Group" })
        if ($term) {
            $filtered = @($filtered | Where-Object { $_.displayName -like "*$term*" })
        }
        $shown = $filtered | Sort-Object displayName | Select-Object -First 200
        foreach ($m in $shown) {
            [void]$lst.Items.Add($m.displayName)
        }
    }.GetNewClosure()

    & $UpdateStatus
    & $RefreshList

    $txtSearch.Add_TextChanged({ & $RefreshList }.GetNewClosure())
    $lst.Add_DoubleClick({ $btnSelect.PerformClick() }.GetNewClosure())

    $btnRefresh.Add_Click({
        $btnRefresh.Enabled = $false
        $lblStatus.Text = "Connecting to Entra ID..."
        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray

        # Fresh local aliases for everything the nested -OnComplete closure below
        # touches - see the note in Show-EntraMemberPicker's own Refresh handler.
        $btnRefreshRef   = $btnRefresh
        $lblStatusRef    = $lblStatus
        $updateStatusRef = $UpdateStatus
        $refreshListRef  = $RefreshList

        Start-EntraDirectoryLookup -OnComplete {
            param($ok, $msg)
            $btnRefreshRef.Enabled = $true
            if ($ok) {
                & $updateStatusRef
                & $refreshListRef
            } else {
                $lblStatusRef.Text = "Failed: $msg"
                $lblStatusRef.ForeColor = [System.Drawing.Color]::Firebrick
            }
        }.GetNewClosure()
    }.GetNewClosure())

    $resultBox = @{ Value = $null }

    $btnSelect.Add_Click({
        if ($lst.SelectedItem) {
            $resultBox.Value = [string]$lst.SelectedItem
        }
        elseif ($txtSearch.Text.Trim()) {
            $resultBox.Value = $txtSearch.Text.Trim()
        }
        else {
            [System.Windows.Forms.MessageBox]::Show("Select a group from the list, or type a name.", "Nothing selected", "OK", "Information") | Out-Null
            return
        }
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dlg.Close()
    }.GetNewClosure())

    $btnCancel.Add_Click({ $dlg.Close() }.GetNewClosure())

    $dlg.CancelButton = $btnCancel
    $dlg.AcceptButton = $btnSelect
    Set-Theme -Control $dlg
    $result = $dlg.ShowDialog($form)
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) { return $resultBox.Value }
    return $null
}

# Bulk review dialog: matches every catalog app against $Script:IntuneAppsCache
# by name and lets the user apply App IDs for the rows they check.
function Show-AppIdMatchDialog {
    if ($Script:IntuneAppsCache.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("No apps were returned from Intune. Check the Pipeline tab's log for details - likely a missing 'DeviceManagementApps.Read.All' application permission (with admin consent) on the app registration.", "Nothing to match", "OK", "Information") | Out-Null
        return
    }

    # Plain (non-$Script:) local aliases - see note in Start-IntuneAppLookup. Both are
    # reference types, so mutating them through these aliases from inside closures
    # below is visible everywhere else that reads the real $Script: names.
    $appsRef = $Script:Apps
    $unsavedBox = $Script:UnsavedChangesBox
    $cache = $Script:IntuneAppsCache
    $linkedFilePath = $Script:LinkedFilePath
    $pickerChoices = @($cache | ForEach-Object { "$($_.displayName)  [$($_.id)]" })

    # Scoped to apps with NO App ID yet - this dialog exists to bootstrap
    # the App ID for a catalog app that's never been linked to anything in
    # Intune, matched by NAME since there's nothing more reliable to go on
    # yet for those. An app that ALREADY has an App ID is deliberately left
    # out here, not re-matched by name too - "Intune sync check..."'s own
    # "Renamed in Intune" already covers that same "does this app's stored
    # ID still make sense?" question, the correct direction: by the App ID
    # already on file (the durable identity), checking whether Intune's
    # CURRENT name for that exact ID has drifted from the catalog's. Doing
    # it here too, by name, could disagree with that - a name collision (or
    # a coincidentally similar name) could suggest switching an already-
    # correct App ID to a wrong one, with no way to tell which of the two
    # tools' answers to trust. One tool, one direction, per case.
    $eligibleIndices = New-Object System.Collections.Generic.List[int]
    for ($ei = 0; $ei -lt $appsRef.Count; $ei++) {
        if (-not $appsRef[$ei].appId) { $eligibleIndices.Add($ei) }
    }
    if ($eligibleIndices.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Every catalog app already has an App ID - there's nothing to look up. If one looks wrong or stale, use `"Intune sync check...`" instead, which checks against the App ID already on file rather than matching by name.", "Nothing to do", "OK", "Information") | Out-Null
        return
    }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Match App IDs from Intune"
    $dlg.ClientSize = New-Object System.Drawing.Size(1300, 520)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "Sizable"
    $dlg.MinimumSize = New-Object System.Drawing.Size(900, 360)

    # Regular weight, color-coded by outcome (below) - matches how every
    # other dialog's own status line (Intune sync check, Check group
    # names, ...) is styled, rather than this one dialog alone using bold.
    $lblHelp = New-Object System.Windows.Forms.Label
    $lblHelp.Text = "Matches each catalog app that has NO App ID yet to an Intune app by name, so you can link the App ID Intune already has into your LOCAL catalog. This only updates App IDs stored in your local catalog files - it never creates, changes, or deletes anything in Intune itself. Rows with an exact name match are pre-checked; use `"Choose...`" to pick a different match, then `"Apply checked rows`". Apps that already have an App ID aren't shown here - use `"Intune sync check...`" for those instead."
    $lblHelp.Dock = "Top"
    $lblHelp.Height = 62
    $lblHelp.ForeColor = [System.Drawing.Color]::DimGray
    $lblHelp.Padding = New-Object System.Windows.Forms.Padding(10,8,10,8)
    $dlg.Controls.Add($lblHelp)

    $lblSummary = New-Object System.Windows.Forms.Label
    $lblSummary.Dock = "Top"
    $lblSummary.Height = 24
    $lblSummary.Padding = New-Object System.Windows.Forms.Padding(10,0,10,0)
    $dlg.Controls.Add($lblSummary)

    $matchGrid = New-Object System.Windows.Forms.DataGridView
    $matchGrid.Dock = "Fill"
    $matchGrid.AllowUserToAddRows = $false
    $matchGrid.AllowUserToDeleteRows = $false
    $matchGrid.RowHeadersVisible = $false
    $matchGrid.AutoGenerateColumns = $false
    $matchGrid.AutoSizeColumnsMode = "Fill"
    $matchGrid.EditMode = "EditOnEnter"
    # Commits a checkbox cell's edit the instant it's clicked, rather than
    # leaving it pending until the cell loses focus - same fix, same
    # reasoning, as the identical DataGridView checkbox column in "Intune
    # sync check": a checkbox visually toggles immediately on click, but
    # its actual .Value doesn't update until the edit is explicitly
    # committed. The existing $matchGrid.EndEdit() below (right before
    # "Apply" reads the checked rows) already defended against this for
    # that one specific moment - this makes the checkbox itself behave
    # consistently the instant it's clicked, matching the other dialog
    # exactly, not just patched around for this one button.
    $matchGrid.Add_CurrentCellDirtyStateChanged({
        if ($matchGrid.IsCurrentCellDirty) {
            $matchGrid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit)
        }
    }.GetNewClosure())

    $colApply = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $colApply.Name = "Apply"; $colApply.HeaderText = "Apply"; $colApply.FillWeight = 7
    $matchGrid.Columns.Add($colApply) | Out-Null

    $colName = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colName.Name = "AppName"; $colName.HeaderText = "Catalog app"; $colName.ReadOnly = $true; $colName.FillWeight = 19
    $matchGrid.Columns.Add($colName) | Out-Null

    $colCurrentId = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colCurrentId.Name = "CurrentId"; $colCurrentId.HeaderText = "Current App ID"; $colCurrentId.ReadOnly = $true; $colCurrentId.FillWeight = 17
    $matchGrid.Columns.Add($colCurrentId) | Out-Null

    $colMatch = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colMatch.Name = "Match"; $colMatch.HeaderText = "Matched name in Intune"; $colMatch.ReadOnly = $true; $colMatch.FillWeight = 21
    $matchGrid.Columns.Add($colMatch) | Out-Null

    $colMatchedId = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colMatchedId.Name = "MatchedId"; $colMatchedId.HeaderText = "Matched App ID"; $colMatchedId.ReadOnly = $true; $colMatchedId.FillWeight = 17
    $matchGrid.Columns.Add($colMatchedId) | Out-Null

    $colChoose = New-Object System.Windows.Forms.DataGridViewButtonColumn
    $colChoose.Name = "Choose"; $colChoose.HeaderText = ""; $colChoose.Text = "Choose..."; $colChoose.UseColumnTextForButtonValue = $true
    $colChoose.FillWeight = 12
    $matchGrid.Columns.Add($colChoose) | Out-Null

    $colIndex = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colIndex.Name = "CatalogIndex"; $colIndex.Visible = $false
    $matchGrid.Columns.Add($colIndex) | Out-Null

    # Every eligible app here has NO App ID yet (see the eligibility filter
    # above), so any exact match is inherently a real change - going from
    # blank to a real ID - not just a possible one, unlike when this used
    # to also consider apps that already had an ID of their own.
    $changeCount = 0
    foreach ($i in $eligibleIndices) {
        $app = $appsRef[$i]
        $candidates = Find-IntuneMatches -Name $app.appName
        $normAppName = ($app.appName.Trim() -replace '\s+', ' ')
        $isExact = $candidates.Count -gt 0 -and (($candidates[0].displayName.Trim() -replace '\s+', ' ') -eq $normAppName)
        if ($isExact) { $changeCount++ }

        $rowIdx = $matchGrid.Rows.Add()
        $row = $matchGrid.Rows[$rowIdx]
        $row.Cells["Apply"].Value = $isExact
        $row.Cells["AppName"].Value = $app.appName
        $row.Cells["CurrentId"].Value = "(none)"
        if ($isExact) {
            $row.Cells["Match"].Value = $candidates[0].displayName
            $row.Cells["MatchedId"].Value = $candidates[0].id
        }
        else {
            $row.Cells["Match"].Value = "(no match)"
            $row.Cells["MatchedId"].Value = ""
        }
        $row.Cells["CatalogIndex"].Value = $i
    }

    if ($changeCount -eq 0) {
        $lblSummary.ForeColor = [System.Drawing.Color]::DarkOrange
        $lblSummary.Text = "$($eligibleIndices.Count) app(s) have no App ID yet, but none matched an Intune app by name - use `"Choose...`" to pick one manually if it's just a naming difference."
    }
    else {
        $lblSummary.ForeColor = [System.Drawing.Color]::SeaGreen
        $lblSummary.Text = "$changeCount of $($eligibleIndices.Count) app(s) with no App ID matched by name and are pre-checked below - applying sets their App ID in the local catalog only."
    }

    $dlg.Controls.Add($matchGrid)
    $matchGrid.BringToFront()

    $btnPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $btnPanel.Dock = "Bottom"
    $btnPanel.Height = 45
    $btnPanel.FlowDirection = "RightToLeft"
    $btnPanel.Padding = New-Object System.Windows.Forms.Padding(10)

    $btnCancelMatch = New-Object System.Windows.Forms.Button
    $btnCancelMatch.Text = "Close"
    $btnCancelMatch.AutoSize = $true

    $btnApplyMatch = New-Object System.Windows.Forms.Button
    $btnApplyMatch.Text = "Apply checked rows"
    $btnApplyMatch.AutoSize = $true

    $btnPanel.Controls.Add($btnCancelMatch)
    $btnPanel.Controls.Add($btnApplyMatch)
    $dlg.Controls.Add($btnPanel)

    $matchGrid.Add_CellClick({
        param($gridSender, $e)
        if ($e.RowIndex -lt 0) { return }
        if ($matchGrid.Columns[$e.ColumnIndex].Name -ne "Choose") { return }

        $row = $matchGrid.Rows[$e.RowIndex]
        $appName = [string]$row.Cells["AppName"].Value
        $pick = Show-SimpleListPicker -Title "Choose a match" -Prompt "Pick the Intune app that matches '$appName':" -Items $pickerChoices
        if ($pick -and $pick -match '^(.*?)\s+\[([0-9a-fA-F-]{36})\]\s*$') {
            $row.Cells["Match"].Value = $Matches[1]
            $row.Cells["MatchedId"].Value = $Matches[2]
            $row.Cells["Apply"].Value = $true
        }
    }.GetNewClosure())

    $btnApplyMatch.Add_Click({
        $matchGrid.EndEdit()
        $applied = 0
        foreach ($row in $matchGrid.Rows) {
            $apply = [bool]$row.Cells["Apply"].Value
            $matchedId = [string]$row.Cells["MatchedId"].Value
            if (-not $apply -or [string]::IsNullOrEmpty($matchedId)) { continue }
            $idx = [int]$row.Cells["CatalogIndex"].Value
            $appsRef[$idx].appId = $matchedId
            $applied++
        }
        if ($applied -gt 0) {
            $unsavedBox.Value = $true
            # Direct-save, not just staged in memory - same reasoning as
            # every other single, atomic action made direct-save this
            # session: applying matched App IDs is a complete action in
            # itself, with no batching benefit to be had from deferring it.
            [void](Save-AppsToFile -Path $linkedFilePath)
            Refresh-Grid
            Write-Log "Applied $applied App ID(s) from Intune lookup.`r`n" ([System.Drawing.Color]::LightGreen)
        }
        $doneMsg = if ($applied -gt 0) { "$applied App ID(s) applied and saved to the local catalog." } else { "$applied App ID(s) applied." }
        [System.Windows.Forms.MessageBox]::Show($doneMsg, "Done", "OK", "Information") | Out-Null
    }.GetNewClosure())

    $btnCancelMatch.Add_Click({ $dlg.Close() }.GetNewClosure())

    $dlg.CancelButton = $btnCancelMatch
    $dlg.AcceptButton = $btnApplyMatch
    Set-Theme -Control $dlg
    [void]$dlg.ShowDialog($form)
}

# =====================================================================
# Winget search dialog
# =====================================================================
# Lets the person search winget's repository right from the app editor
# instead of having to know or look up the exact winget ID. Returns the
# selected package's winget ID, or $null if cancelled/nothing picked.
function Show-WingetSearchDialog {
    param([string]$InitialQuery = "")

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Search winget"
    $dlg.ClientSize = New-Object System.Drawing.Size(640, 470)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $lblQuery = New-Object System.Windows.Forms.Label
    $lblQuery.Text = "Search term"
    $lblQuery.Location = New-Object System.Drawing.Point(15,15)
    $lblQuery.AutoSize = $true
    $dlg.Controls.Add($lblQuery)

    $txtQuery = New-Object System.Windows.Forms.TextBox
    $txtQuery.Location = New-Object System.Drawing.Point(15,34)
    $txtQuery.Size = New-Object System.Drawing.Size(500,24)
    $txtQuery.Text = $InitialQuery
    $dlg.Controls.Add($txtQuery)

    $btnSearch = New-Object System.Windows.Forms.Button
    $btnSearch.Text = "Search"
    $btnSearch.Location = New-Object System.Drawing.Point(525,33)
    $btnSearch.Size = New-Object System.Drawing.Size(95,26)
    $dlg.Controls.Add($btnSearch)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Location = New-Object System.Drawing.Point(15,64)
    $lblStatus.Size = New-Object System.Drawing.Size(605,18)
    $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($lblStatus)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(15,86)
    $grid.Size = New-Object System.Drawing.Size(605,330)
    $grid.ReadOnly = $true
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.SelectionMode = "FullRowSelect"
    $grid.MultiSelect = $false
    $grid.AutoSizeColumnsMode = "Fill"
    $grid.RowHeadersVisible = $false
    $grid.AutoGenerateColumns = $false
    $grid.BackgroundColor = [System.Drawing.SystemColors]::Window

    $colName = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colName.Name = "Name"; $colName.HeaderText = "Name"; $colName.FillWeight = 34
    $grid.Columns.Add($colName) | Out-Null
    $colId = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colId.Name = "Id"; $colId.HeaderText = "Winget ID"; $colId.FillWeight = 34
    $grid.Columns.Add($colId) | Out-Null
    $colVersion = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colVersion.Name = "Version"; $colVersion.HeaderText = "Version"; $colVersion.FillWeight = 16
    $grid.Columns.Add($colVersion) | Out-Null
    $colSource = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colSource.Name = "Source"; $colSource.HeaderText = "Source"; $colSource.FillWeight = 16
    $grid.Columns.Add($colSource) | Out-Null
    $dlg.Controls.Add($grid)

    $btnSelect = New-Object System.Windows.Forms.Button
    $btnSelect.Text = "Use selected ID"
    $btnSelect.Location = New-Object System.Drawing.Point(390,426)
    $btnSelect.Size = New-Object System.Drawing.Size(140,32)
    $btnSelect.Enabled = $false
    $dlg.Controls.Add($btnSelect)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Close"
    $btnCancel.Location = New-Object System.Drawing.Point(535,426)
    $btnCancel.Size = New-Object System.Drawing.Size(85,32)
    $dlg.Controls.Add($btnCancel)

    $resultBox = @{ SelectedId = $null }

    # Stored in a variable (not inlined into Add_Click) so both the Search
    # button and the query textbox's Enter key can trigger the exact same
    # logic, and so it can also run once automatically on open.
    $runSearch = {
        if (-not $btnSearch.Enabled) { return }   # a search is already running - ignore this trigger rather than overlap it
        $q = $txtQuery.Text.Trim()
        if (-not $q) { return }
        $grid.Rows.Clear()
        $btnSearch.Enabled = $false
        $btnSelect.Enabled = $false
        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblStatus.Text = "Searching winget for '$q'..."
        $dlg.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

        # Fresh aliases for the nested -OnComplete closure - see note at the
        # top of Show-CreateInIntuneDialog for why this matters here too.
        $gridRef = $grid
        $btnSearchRef = $btnSearch
        $lblStatusRef = $lblStatus
        $dlgRef = $dlg

        Start-WingetSearch -Query $q -OnComplete {
            param($ok, $data)
            try {
                if (-not $ok) {
                    $lblStatusRef.ForeColor = [System.Drawing.Color]::Firebrick
                    $lblStatusRef.Text = "Search failed: $data"
                    return
                }
                $results = @($data)
                if ($results.Count -eq 0) {
                    $lblStatusRef.ForeColor = [System.Drawing.Color]::DimGray
                    $lblStatusRef.Text = "No results."
                    return
                }
                foreach ($r in $results) {
                    [void]$gridRef.Rows.Add([string]$r.Name, [string]$r.Id, [string]$r.Version, [string]$r.Source)
                }
                $lblStatusRef.ForeColor = [System.Drawing.Color]::SeaGreen
                $lblStatusRef.Text = "$($results.Count) result(s)."
            }
            catch {
                $lblStatusRef.ForeColor = [System.Drawing.Color]::Firebrick
                $lblStatusRef.Text = "Error showing results: $($_.Exception.Message)"
            }
            finally {
                # Guaranteed to run no matter what happened above - this is
                # what actually ends the "loading" state, so it must never be
                # skippable by an exception partway through populating rows.
                $dlgRef.Cursor = [System.Windows.Forms.Cursors]::Default
                [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default
                $btnSearchRef.Enabled = $true
            }
        }.GetNewClosure()
    }.GetNewClosure()

    $btnSearch.Add_Click($runSearch)

    $txtQuery.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
            $_.SuppressKeyPress = $true
            & $runSearch
        }
    }.GetNewClosure())

    $grid.Add_SelectionChanged({
        $btnSelect.Enabled = $grid.SelectedRows.Count -gt 0
    }.GetNewClosure())

    $grid.Add_CellDoubleClick({
        param($gridSender, $e)
        if ($e.RowIndex -ge 0) { $btnSelect.PerformClick() }
    }.GetNewClosure())

    $btnSelect.Add_Click({
        if ($grid.SelectedRows.Count -gt 0) {
            $resultBox.SelectedId = [string]$grid.SelectedRows[0].Cells["Id"].Value
            $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $dlg.Close()
        }
    }.GetNewClosure())

    $btnCancel.Add_Click({ $dlg.Close() }.GetNewClosure())
    $dlg.CancelButton = $btnCancel
    $dlg.AcceptButton = $btnSearch

    if ($InitialQuery) { & $runSearch }

    Set-Theme -Control $dlg
    [void]$dlg.ShowDialog($form)
    return $resultBox.SelectedId
}

# Simple single-select list picker. Returns the selected string, or $null if cancelled.
function Show-SimpleListPicker {
    param([string]$Title, [string]$Prompt, [string[]]$Items)

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = $Title
    $dlg.ClientSize = New-Object System.Drawing.Size(420, 320)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Prompt
    $lbl.Location = New-Object System.Drawing.Point(12,12)
    $lbl.Size = New-Object System.Drawing.Size(396,40)
    $dlg.Controls.Add($lbl)

    $lst = New-Object System.Windows.Forms.ListBox
    $lst.Location = New-Object System.Drawing.Point(12,55)
    $lst.Size = New-Object System.Drawing.Size(396,210)
    $lst.Items.AddRange($Items)
    if ($lst.Items.Count -gt 0) { $lst.SelectedIndex = 0 }
    $dlg.Controls.Add($lst)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = "Select"
    $btnOk.Location = New-Object System.Drawing.Point(228,275)
    $btnOk.Size = New-Object System.Drawing.Size(85,28)
    $dlg.Controls.Add($btnOk)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(323,275)
    $btnCancel.Size = New-Object System.Drawing.Size(85,28)
    $dlg.Controls.Add($btnCancel)

    # Plain local box (not $Script:-qualified) - closures reliably capture and mutate
    # plain variables via GetNewClosure(), so the button handlers write into this box
    # and the code below (outside any closure) reads it back after ShowDialog returns.
    $resultBox = @{ Value = $null }

    $btnOk.Add_Click({
        $resultBox.Value = if ($lst.SelectedItem) { [string]$lst.SelectedItem } else { $null }
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dlg.Close()
    }.GetNewClosure())
    $btnCancel.Add_Click({
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $dlg.Close()
    }.GetNewClosure())
    $lst.Add_DoubleClick({ $btnOk.PerformClick() }.GetNewClosure())

    $dlg.AcceptButton = $btnOk
    $dlg.CancelButton = $btnCancel
    Set-Theme -Control $dlg
    $result = $dlg.ShowDialog($form)
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) { return $resultBox.Value }
    return $null
}

function Get-CertificateStatusText {
    param([string]$Thumbprint)

    if ([string]::IsNullOrWhiteSpace($Thumbprint)) {
        return @{ Text = "No thumbprint set."; Color = [System.Drawing.Color]::DarkOrange }
    }
    $clean = $Thumbprint -replace '\s', ''
    $cert = $null
    foreach ($location in @("Cert:\CurrentUser\My", "Cert:\LocalMachine\My")) {
        try {
            $found = Get-ChildItem -Path $location -ErrorAction SilentlyContinue | Where-Object { $_.Thumbprint -eq $clean } | Select-Object -First 1
            if ($found) { $cert = $found; break }
        } catch { }
    }
    if (-not $cert) {
        return @{ Text = "Not found in CurrentUser\My or LocalMachine\My on this machine."; Color = [System.Drawing.Color]::Firebrick }
    }
    $daysLeft = ($cert.NotAfter - (Get-Date)).Days
    if ($daysLeft -lt 0) {
        return @{ Text = "Found - EXPIRED on $($cert.NotAfter.ToString('yyyy-MM-dd')). Subject: $($cert.Subject)"; Color = [System.Drawing.Color]::Firebrick }
    }
    elseif ($daysLeft -lt 30) {
        return @{ Text = "Found - expires in $daysLeft day(s) ($($cert.NotAfter.ToString('yyyy-MM-dd'))). Subject: $($cert.Subject)"; Color = [System.Drawing.Color]::DarkOrange }
    }
    else {
        return @{ Text = "Found - valid until $($cert.NotAfter.ToString('yyyy-MM-dd')). Subject: $($cert.Subject)"; Color = [System.Drawing.Color]::SeaGreen }
    }
}

# Purely informational - shows the manual app-registration setup steps and
# offers a link to the Entra admin center, but makes NO Graph calls of its
# own. Deliberately kept manual rather than automated: creating an app
# registration with broad tenant permissions (DeviceManagementApps, Group,
# Directory, etc.) and granting admin consent for it IS the approval-worthy
# event here, not something to script around the portal's own review
# screens for, even though only a Global/Privileged Role Admin could run
# either path. It's also a one-time, per-environment step, so automating it
# buys little repeated convenience for a real reduction in review friction.
function Show-AppRegistrationGuideDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Set up the Entra ID app registration"
    $dlg.ClientSize = New-Object System.Drawing.Size(560, 460)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $txtGuide = New-Object System.Windows.Forms.TextBox
    $txtGuide.Location = New-Object System.Drawing.Point(15,15)
    $txtGuide.Size = New-Object System.Drawing.Size(530,390)
    $txtGuide.Multiline = $true
    $txtGuide.ReadOnly = $true
    $txtGuide.ScrollBars = "Vertical"
    $txtGuide.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $txtGuide.Text = @"
This is a one-time setup, done once per tenant/environment - not something
this tool automates. Granting an application broad tenant permissions is
worth doing deliberately through the portal's own review screens, not
silently via a script, even though only a Global/Privileged Role Admin
could run either path.

1. In the Entra admin center, go to "App registrations" and create a new
   registration (or use an existing one your organization has already
   approved for this purpose).

2. Note its "Application (client) ID" and "Directory (tenant) ID" - enter
   both into the fields in the Settings dialog.

3. Open the app registration, go to:
   API permissions > Add a permission > Microsoft Graph >
   Application permissions (NOT Delegated) - and add:
     - DeviceManagementApps.ReadWrite.All
     - Group.ReadWrite.All
     - User.Read.All
     - Device.Read.All
     - Directory.Read.All

4. Click "Grant admin consent for [tenant]" and confirm every permission
   shows "Granted."
   Requires a Global Administrator or Privileged Role Administrator.

5. Back in Settings, use "Pick certificate..." or "Generate certificate...",
   then "Upload certificate..." to link this tool to that app registration
   - or export/upload the certificate through the portal yourself instead,
   if you'd rather do that step there too.
"@
    $dlg.Controls.Add($txtGuide)

    $btnOpenPortal = New-Object System.Windows.Forms.Button
    $btnOpenPortal.Text = "Open Entra admin center"
    $btnOpenPortal.Location = New-Object System.Drawing.Point(15,415)
    $btnOpenPortal.Size = New-Object System.Drawing.Size(190,30)
    $dlg.Controls.Add($btnOpenPortal)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"
    $btnClose.Location = New-Object System.Drawing.Point(455,415)
    $btnClose.Size = New-Object System.Drawing.Size(90,30)
    $dlg.Controls.Add($btnClose)

    $btnOpenPortal.Add_Click({
        try { Start-Process "https://entra.microsoft.com" } catch { }
    })
    $btnClose.Add_Click({ $dlg.Close() }.GetNewClosure())
    $dlg.CancelButton = $btnClose
    $dlg.AcceptButton = $btnClose

    Set-Theme -Control $dlg
    [void]$dlg.ShowDialog($form)
}

function Show-CertificatePickerDialog {
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store("My", [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
    $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
    $certs = @($store.Certificates)
    $store.Close()

    if ($certs.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("No certificates found in CurrentUser\My. Use 'Generate certificate...' to create one.", "No certificates", "OK", "Information") | Out-Null
        return $null
    }

    # A custom picker instead of the built-in X509Certificate2UI.SelectFromCollection
    # dialog - that's a native Windows dialog with a fixed layout Claude can't
    # resize or add columns to. This one shows subject, friendly name,
    # thumbprint, and expiry side by side, wide enough to actually read all
    # of it, which is the whole reason to build a custom version at all.
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Select Certificate"
    $dlg.ClientSize = New-Object System.Drawing.Size(760, 420)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "Sizable"
    $dlg.MinimumSize = New-Object System.Drawing.Size(620, 300)

    $lblIntro = New-Object System.Windows.Forms.Label
    $lblIntro.Text = "Choose the certificate used for Microsoft Graph app-only authentication."
    $lblIntro.Location = New-Object System.Drawing.Point(15,12)
    $lblIntro.Size = New-Object System.Drawing.Size(730,20)
    $lblIntro.Anchor = "Top,Left,Right"
    $dlg.Controls.Add($lblIntro)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(15,38)
    $grid.Size = New-Object System.Drawing.Size(730,330)
    $grid.Anchor = "Top,Bottom,Left,Right"
    $grid.ReadOnly = $true
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.SelectionMode = "FullRowSelect"
    $grid.MultiSelect = $false
    $grid.AutoGenerateColumns = $false
    $grid.AutoSizeColumnsMode = "Fill"
    $grid.RowHeadersVisible = $false

    $colSubject = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colSubject.Name = "Subject"; $colSubject.HeaderText = "Subject"; $colSubject.FillWeight = 38
    $grid.Columns.Add($colSubject) | Out-Null
    $colFriendly = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colFriendly.Name = "FriendlyName"; $colFriendly.HeaderText = "Friendly name"; $colFriendly.FillWeight = 20
    $grid.Columns.Add($colFriendly) | Out-Null
    $colThumb = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colThumb.Name = "Thumbprint"; $colThumb.HeaderText = "Thumbprint"; $colThumb.FillWeight = 30
    $grid.Columns.Add($colThumb) | Out-Null
    $colExpiry = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colExpiry.Name = "Expiry"; $colExpiry.HeaderText = "Expires"; $colExpiry.FillWeight = 12
    $grid.Columns.Add($colExpiry) | Out-Null
    $dlg.Controls.Add($grid)

    foreach ($c in ($certs | Sort-Object Subject)) {
        $rowIdx = $grid.Rows.Add()
        $row = $grid.Rows[$rowIdx]
        $row.Cells["Subject"].Value = $c.Subject
        $row.Cells["FriendlyName"].Value = $c.FriendlyName
        $row.Cells["Thumbprint"].Value = $c.Thumbprint
        $row.Cells["Expiry"].Value = $c.NotAfter.ToString("yyyy-MM-dd")
        $row.Tag = $c.Thumbprint
        if ($c.NotAfter -lt (Get-Date)) {
            $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::Firebrick
        }
    }
    if ($grid.Rows.Count -gt 0) { $grid.Rows[0].Selected = $true }

    $btnOK = New-Object System.Windows.Forms.Button
    $btnOK.Text = "OK"
    $btnOK.Location = New-Object System.Drawing.Point(580,378)
    $btnOK.Size = New-Object System.Drawing.Size(80,28)
    $btnOK.Anchor = "Bottom,Right"
    $dlg.Controls.Add($btnOK)

    $btnCancelPick = New-Object System.Windows.Forms.Button
    $btnCancelPick.Text = "Cancel"
    $btnCancelPick.Location = New-Object System.Drawing.Point(665,378)
    $btnCancelPick.Size = New-Object System.Drawing.Size(80,28)
    $btnCancelPick.Anchor = "Bottom,Right"
    $dlg.Controls.Add($btnCancelPick)

    $resultBox = @{ Thumbprint = $null }

    $btnOK.Add_Click({
        if ($grid.SelectedRows.Count -gt 0) {
            $resultBox.Thumbprint = [string]$grid.SelectedRows[0].Tag
        }
        $dlg.Close()
    }.GetNewClosure())
    $btnCancelPick.Add_Click({ $dlg.Close() }.GetNewClosure())
    $grid.Add_CellDoubleClick({
        param($s, $e)
        if ($e.RowIndex -ge 0) {
            $resultBox.Thumbprint = [string]$grid.Rows[$e.RowIndex].Tag
            $dlg.Close()
        }
    }.GetNewClosure())

    $dlg.AcceptButton = $btnOK
    $dlg.CancelButton = $btnCancelPick
    Set-Theme -Control $dlg
    [void]$dlg.ShowDialog($form)

    return $resultBox.Thumbprint
}

function Show-CertificateSetupDialog {
    # Plain local aliases - see note in Start-IntuneAppLookup. Even a single
    # level of GetNewClosure() (like $btnUpload.Add_Click below) does not
    # reliably see $Script:-qualified variables directly, only plain ones.
    $certUploadScript = $Script:EmbeddedCertUploadScript

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Settings - Microsoft Graph Connection"
    $dlg.ClientSize = New-Object System.Drawing.Size(930, 1034)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $y = 15
    $lblIntro = New-Object System.Windows.Forms.Label
    $lblIntro.Text = "These identify the Entra ID app registration used for app-only sign-in (Launch/Assign and the App ID lookup). Changes here are saved to itsense-intune-settings.json next to this script."
    $lblIntro.Location = New-Object System.Drawing.Point(15,$y)
    $lblIntro.Size = New-Object System.Drawing.Size(900,45)
    $dlg.Controls.Add($lblIntro)
    $y += 55

    $btnSetupGuide = New-Object System.Windows.Forms.Button
    $btnSetupGuide.Text = "First time? Setup guide..."
    $btnSetupGuide.Location = New-Object System.Drawing.Point(15,$y)
    $btnSetupGuide.Size = New-Object System.Drawing.Size(900,28)
    $dlg.Controls.Add($btnSetupGuide)
    $y += 36

    $lblTenant = New-Object System.Windows.Forms.Label
    $lblTenant.Text = "Tenant ID"
    $lblTenant.Location = New-Object System.Drawing.Point(15,$y)
    $lblTenant.AutoSize = $true
    $dlg.Controls.Add($lblTenant)
    $y += 20

    $txtTenant = New-Object System.Windows.Forms.TextBox
    $txtTenant.Location = New-Object System.Drawing.Point(15,$y)
    $txtTenant.Size = New-Object System.Drawing.Size(900,24)
    $txtTenant.Text = $Script:GraphTenantId
    $dlg.Controls.Add($txtTenant)
    $y += 34

    $lblClient = New-Object System.Windows.Forms.Label
    $lblClient.Text = "Client (Application) ID"
    $lblClient.Location = New-Object System.Drawing.Point(15,$y)
    $lblClient.AutoSize = $true
    $dlg.Controls.Add($lblClient)
    $y += 20

    $txtClient = New-Object System.Windows.Forms.TextBox
    $txtClient.Location = New-Object System.Drawing.Point(15,$y)
    $txtClient.Size = New-Object System.Drawing.Size(900,24)
    $txtClient.Text = $Script:GraphClientId
    $dlg.Controls.Add($txtClient)
    $y += 34

    $lblThumb = New-Object System.Windows.Forms.Label
    $lblThumb.Text = "Certificate thumbprint"
    $lblThumb.Location = New-Object System.Drawing.Point(15,$y)
    $lblThumb.AutoSize = $true
    $dlg.Controls.Add($lblThumb)
    $y += 20

    $txtThumb = New-Object System.Windows.Forms.TextBox
    $txtThumb.Location = New-Object System.Drawing.Point(15,$y)
    $txtThumb.Size = New-Object System.Drawing.Size(900,24)
    $txtThumb.Text = $Script:GraphCertificateThumbprint
    $dlg.Controls.Add($txtThumb)
    $y += 30

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Location = New-Object System.Drawing.Point(15,$y)
    $lblStatus.Size = New-Object System.Drawing.Size(900,36)
    $dlg.Controls.Add($lblStatus)
    $y += 42

    $RefreshStatus = {
        $status = Get-CertificateStatusText -Thumbprint $txtThumb.Text
        $lblStatus.Text = $status.Text
        $lblStatus.ForeColor = $status.Color
    }.GetNewClosure()
    & $RefreshStatus

    $lblLocalSection = New-Object System.Windows.Forms.Label
    $lblLocalSection.Text = "LOCAL CERTIFICATE"
    $lblLocalSection.Location = New-Object System.Drawing.Point(15,$y)
    $lblLocalSection.AutoSize = $true
    $lblLocalSection.Font = New-Object System.Drawing.Font($dlg.Font.FontFamily, 8, [System.Drawing.FontStyle]::Bold)
    $lblLocalSection.ForeColor = [System.Drawing.Color]::FromArgb(90,90,90)
    $dlg.Controls.Add($lblLocalSection)

    $sepLocal = New-Object System.Windows.Forms.Panel
    $sepLocal.Location = New-Object System.Drawing.Point(180,($y+8))
    $sepLocal.Size = New-Object System.Drawing.Size(735,1)
    $sepLocal.BackColor = [System.Drawing.Color]::FromArgb(200,200,200)
    $dlg.Controls.Add($sepLocal)
    $y += 22

    $btnPick = New-Object System.Windows.Forms.Button
    $btnPick.Text = "Pick certificate..."
    $btnPick.Location = New-Object System.Drawing.Point(15,$y)
    $btnPick.Size = New-Object System.Drawing.Size(160,30)
    $dlg.Controls.Add($btnPick)

    $btnGenerate = New-Object System.Windows.Forms.Button
    $btnGenerate.Text = "Generate certificate..."
    $btnGenerate.Location = New-Object System.Drawing.Point(185,$y)
    $btnGenerate.Size = New-Object System.Drawing.Size(190,30)
    $dlg.Controls.Add($btnGenerate)

    $btnTest = New-Object System.Windows.Forms.Button
    $btnTest.Text = "Test connection"
    $btnTest.Location = New-Object System.Drawing.Point(385,$y)
    $btnTest.Size = New-Object System.Drawing.Size(530,30)
    $dlg.Controls.Add($btnTest)
    $y += 40

    $btnDeleteLocal = New-Object System.Windows.Forms.Button
    $btnDeleteLocal.Text = "Delete local certificate..."
    $btnDeleteLocal.Location = New-Object System.Drawing.Point(15,$y)
    $btnDeleteLocal.Size = New-Object System.Drawing.Size(900,28)
    $dlg.Controls.Add($btnDeleteLocal)
    $y += 40

    $lblEntraSection = New-Object System.Windows.Forms.Label
    $lblEntraSection.Text = "ENTRA ID APP REGISTRATION"
    $lblEntraSection.Location = New-Object System.Drawing.Point(15,$y)
    $lblEntraSection.AutoSize = $true
    $lblEntraSection.Font = New-Object System.Drawing.Font($dlg.Font.FontFamily, 8, [System.Drawing.FontStyle]::Bold)
    $lblEntraSection.ForeColor = [System.Drawing.Color]::FromArgb(90,90,90)
    $dlg.Controls.Add($lblEntraSection)

    $sepEntra = New-Object System.Windows.Forms.Panel
    $sepEntra.Location = New-Object System.Drawing.Point(240,($y+8))
    $sepEntra.Size = New-Object System.Drawing.Size(675,1)
    $sepEntra.BackColor = [System.Drawing.Color]::FromArgb(200,200,200)
    $dlg.Controls.Add($sepEntra)
    $y += 22

    # The one operation in this whole app that can't use app-only cert auth -
    # that certificate isn't trusted by the app registration yet, which is
    # exactly the problem this solves. Needs interactive sign-in as a
    # separate, explicit step, with its own visible log, since the person
    # running it has to actually complete the browser sign-in prompt.
    $btnCheckCerts = New-Object System.Windows.Forms.Button
    $btnCheckCerts.Text = "Check certificates..."
    $btnCheckCerts.Location = New-Object System.Drawing.Point(15,$y)
    $btnCheckCerts.Size = New-Object System.Drawing.Size(445,30)
    $dlg.Controls.Add($btnCheckCerts)

    $btnUpload = New-Object System.Windows.Forms.Button
    $btnUpload.Text = "Upload certificate..."
    $btnUpload.Location = New-Object System.Drawing.Point(470,$y)
    $btnUpload.Size = New-Object System.Drawing.Size(445,30)
    $dlg.Controls.Add($btnUpload)
    $y += 38

    $lblUploadStatus = New-Object System.Windows.Forms.Label
    $lblUploadStatus.Text = "Both use the app registration's Client ID above and require signing in with YOUR OWN account (not the app-only certificate) - Check just looks and may need its own sign-in even right after Upload (or vice versa). Upload needs the Application Administrator role or being an owner of this app registration."
    $lblUploadStatus.Location = New-Object System.Drawing.Point(15,$y)
    $lblUploadStatus.Size = New-Object System.Drawing.Size(900,68)
    $lblUploadStatus.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($lblUploadStatus)
    $y += 74

    $rtbUploadLog = New-Object System.Windows.Forms.RichTextBox
    $rtbUploadLog.Location = New-Object System.Drawing.Point(15,$y)
    $rtbUploadLog.Size = New-Object System.Drawing.Size(900,170)
    $rtbUploadLog.ReadOnly = $true
    $rtbUploadLog.BackColor = [System.Drawing.Color]::FromArgb(13,17,23)
    $rtbUploadLog.ForeColor = [System.Drawing.Color]::Gainsboro
    $rtbUploadLog.Font = New-Object System.Drawing.Font("Consolas", 8.5)
    # DetectUrls only makes a URL look like a link (blue, underlined) - it
    # doesn't open anything by itself, that needs its own LinkClicked handler.
    $rtbUploadLog.DetectUrls = $true
    $rtbUploadLog.Add_LinkClicked({
        param($s, $e)
        try { Start-Process $e.LinkText } catch { }
    })
    $dlg.Controls.Add($rtbUploadLog)
    $y += 178

    $lblCertList = New-Object System.Windows.Forms.Label
    $lblCertList.Text = "Certificates found by Check (select one to delete it from Entra):"
    $lblCertList.Location = New-Object System.Drawing.Point(15,$y)
    $lblCertList.AutoSize = $true
    $dlg.Controls.Add($lblCertList)
    $y += 20

    $lstCerts = New-Object System.Windows.Forms.ListBox
    $lstCerts.Location = New-Object System.Drawing.Point(15,$y)
    $lstCerts.Size = New-Object System.Drawing.Size(900,90)
    $dlg.Controls.Add($lstCerts)
    $y += 98

    $btnDeleteEntraCert = New-Object System.Windows.Forms.Button
    $btnDeleteEntraCert.Text = "Delete selected from Entra..."
    $btnDeleteEntraCert.Location = New-Object System.Drawing.Point(15,$y)
    $btnDeleteEntraCert.Size = New-Object System.Drawing.Size(250,28)
    $btnDeleteEntraCert.Enabled = $false
    $dlg.Controls.Add($btnDeleteEntraCert)
    $y += 36

    $lblTestResult = New-Object System.Windows.Forms.Label
    $lblTestResult.Location = New-Object System.Drawing.Point(15,$y)
    $lblTestResult.Size = New-Object System.Drawing.Size(900,36)
    $dlg.Controls.Add($lblTestResult)
    $y += 46

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = "Save"
    $btnSave.Location = New-Object System.Drawing.Point(745,$y)
    $btnSave.Size = New-Object System.Drawing.Size(80,30)
    $dlg.Controls.Add($btnSave)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Close"
    $btnCancel.Location = New-Object System.Drawing.Point(835,$y)
    $btnCancel.Size = New-Object System.Drawing.Size(80,30)
    $dlg.Controls.Add($btnCancel)

    $btnSetupGuide.Add_Click({ Show-AppRegistrationGuideDialog }.GetNewClosure())

    $btnPick.Add_Click({
        try {
            $picked = Show-CertificatePickerDialog
            if ($picked) {
                $txtThumb.Text = $picked
                & $RefreshStatus
            }
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Could not open certificate picker: $($_.Exception.Message)", "Error", "OK", "Error") | Out-Null
        }
    }.GetNewClosure())

    $btnDeleteLocal.Add_Click({
        $thumb = $txtThumb.Text.Trim() -replace '\s', ''
        if (-not $thumb) {
            [System.Windows.Forms.MessageBox]::Show("Enter or pick a certificate thumbprint first.", "No thumbprint", "OK", "Information") | Out-Null
            return
        }

        # Same two locations Get-CertificateStatusText already searches -
        # deletion should look wherever the status check would have found it.
        $foundPath = $null
        $foundCert = $null
        foreach ($location in @("Cert:\CurrentUser\My", "Cert:\LocalMachine\My")) {
            $candidate = Get-ChildItem -Path $location -ErrorAction SilentlyContinue | Where-Object { $_.Thumbprint -eq $thumb } | Select-Object -First 1
            if ($candidate) {
                $foundPath = Join-Path $location $thumb
                $foundCert = $candidate
                break
            }
        }
        if (-not $foundCert) {
            [System.Windows.Forms.MessageBox]::Show("No certificate with thumbprint $thumb was found in CurrentUser\My or LocalMachine\My on this machine.", "Not found", "OK", "Warning") | Out-Null
            return
        }

        $r = [System.Windows.Forms.MessageBox]::Show(
            "Permanently delete this certificate from $foundPath ?`n`n$($foundCert.Subject)`n`nThis only removes it from THIS machine - it does NOT remove it from Entra ID. Use Check certificates / Delete from Entra above for that, separately.",
            "Confirm local delete", "YesNo", "Warning")
        if ($r -ne "Yes") { return }

        try {
            Remove-Item -Path $foundPath -Force -ErrorAction Stop
            # Only clear the field if it still pointed at the cert that was
            # just deleted - not if the user had already typed something else.
            if (($txtThumb.Text.Trim() -replace '\s', '') -eq $thumb) {
                $txtThumb.Text = ""
                & $RefreshStatus
            }
            [System.Windows.Forms.MessageBox]::Show("Certificate deleted from $foundPath.", "Deleted", "OK", "Information") | Out-Null
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Could not delete the certificate: $($_.Exception.Message)`n`nDeleting from LocalMachine\My usually needs an elevated (Run as Administrator) session.", "Delete failed", "OK", "Error") | Out-Null
        }
    }.GetNewClosure())

    $btnGenerate.Add_Click({
        if (-not (Get-Command New-SelfSignedCertificate -ErrorAction SilentlyContinue)) {
            [System.Windows.Forms.MessageBox]::Show("New-SelfSignedCertificate isn't available (the PKI module is missing). This is built into Windows 10/11 and Windows Server 2012 R2+ by default.", "Not available", "OK", "Error") | Out-Null
            return
        }

        $subject = [Microsoft.VisualBasic.Interaction]::InputBox(
            "Certificate subject (the 'CN=' prefix is added automatically if you leave it out):",
            "Generate certificate", "ITSENSE Intune Deployment")
        if (-not $subject) { return }
        $subject = $subject.Trim()
        if (-not $subject) { return }
        if ($subject -notmatch '^CN=') { $subject = "CN=$subject" }

        try {
            $newCert = New-SelfSignedCertificate -Subject $subject -CertStoreLocation "Cert:\CurrentUser\My" `
                -KeyExportPolicy Exportable -KeySpec Signature -KeyLength 2048 -KeyAlgorithm RSA `
                -HashAlgorithm SHA256 -NotAfter (Get-Date).AddYears(2)

            $txtThumb.Text = $newCert.Thumbprint
            & $RefreshStatus

            $sfd = New-Object System.Windows.Forms.SaveFileDialog
            $sfd.Filter = "Certificate files (*.cer)|*.cer"
            $sfd.FileName = "ITSENSE-Intune-Deployment.cer"
            $sfd.Title = "Export public certificate (upload this to Entra ID)"
            if ($sfd.ShowDialog($dlg) -eq [System.Windows.Forms.DialogResult]::OK) {
                Export-Certificate -Cert $newCert -FilePath $sfd.FileName | Out-Null
                [System.Windows.Forms.MessageBox]::Show(
                    "Certificate created and exported to:`n$($sfd.FileName)`n`nNext steps:`n1. In Entra ID, open your app registration > Certificates & secrets > Certificates > Upload certificate, and upload this .cer file.`n2. Click Save here to start using this certificate.",
                    "Certificate created", "OK", "Information") | Out-Null
            }
            else {
                [System.Windows.Forms.MessageBox]::Show(
                    "Certificate created but not exported. You'll need to export its public key later (Certificate Manager, or re-run this dialog) and upload it to Entra ID before this certificate will work.",
                    "Certificate created", "OK", "Warning") | Out-Null
            }
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Could not create certificate: $($_.Exception.Message)", "Error", "OK", "Error") | Out-Null
        }
    }.GetNewClosure())

    # Parallel to $lstCerts.Items - index N here is the keyId for whatever's
    # shown at index N, populated by a successful Check and consumed by
    # Delete selected from Entra. Deliberately keyId, not thumbprint - two
    # entries can legitimately share a thumbprint if the same certificate
    # was uploaded more than once, and matching a delete by thumbprint alone
    # would remove every entry that shares it, not just the one selected.
    $certKeyIds = New-Object System.Collections.Generic.List[string]

    $btnCheckCerts.Add_Click({
        $checkTenant = $txtTenant.Text.Trim()
        $checkClient = $txtClient.Text.Trim()

        if (-not $checkTenant -or -not $checkClient) {
            [System.Windows.Forms.MessageBox]::Show("Fill in Tenant ID and Client ID first.", "Missing fields", "OK", "Warning") | Out-Null
            return
        }

        $btnCheckCerts.Enabled = $false
        $btnUpload.Enabled = $false
        $btnDeleteEntraCert.Enabled = $false
        $lblUploadStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblUploadStatus.Text = "Starting sign-in..."
        $rtbUploadLog.Clear()

        $configPath = Join-Path $env:TEMP (".itsense_certupload_config_" + [guid]::NewGuid().ToString("N") + ".json")
        $resultPath = Join-Path $env:TEMP (".itsense_certupload_result_" + [guid]::NewGuid().ToString("N") + ".json")
        # OutputResultPath included directly in the object literal, not
        # bolted on afterward via a separate Select-Object step - that
        # extra step was confirmed, directly and repeatedly, to sometimes
        # produce a genuinely null result with no error at all, in the
        # same pattern elsewhere in this file. Sidestepped entirely here
        # too, rather than relying on a construct already shown to
        # misbehave.
        $config = [pscustomobject]@{
            Mode             = "Check"
            TenantId         = $checkTenant
            ClientId         = $checkClient
            OutputResultPath = $resultPath
        }
        try {
            $configJsonText = $config | ConvertTo-Json -Depth 8 -ErrorAction Stop
            [System.IO.File]::WriteAllText($configPath, $configJsonText, (New-Object System.Text.UTF8Encoding($false)))
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Could not write the config file needed to run this: $($_.Exception.Message)", "Failed to prepare", "OK", "Error") | Out-Null
            return
        }

        # Fresh aliases for the nested -OnComplete closure - see note at the
        # top of Show-CreateInIntuneDialog for why this matters here too.
        $btnCheckCertsRef = $btnCheckCerts
        $btnUploadRef = $btnUpload
        $btnDeleteEntraCertRef = $btnDeleteEntraCert
        $lblUploadStatusRef = $lblUploadStatus
        $resultPathRef = $resultPath
        $configPathRef = $configPath
        $rtbUploadLogRef = $rtbUploadLog
        $lstCertsRef = $lstCerts
        $certKeyIdsRef = $certKeyIds

        Start-PipelineProcess -ScriptContent $certUploadScript -TempScriptName ".itsense_embedded_certupload.ps1" -ArgumentString "-ConfigPath `"$configPathRef`"" -ExtraLogTarget $rtbUploadLog -ShowConsoleWindow -OnComplete {
            param($code)
            $btnCheckCertsRef.Enabled = $true
            $btnUploadRef.Enabled = $true
            Remove-Item $configPathRef -Force -ErrorAction SilentlyContinue

            if (Test-Path $resultPathRef) {
                try {
                    $result = Get-Content -Path $resultPathRef -Raw | ConvertFrom-Json
                    Remove-Item $resultPathRef -Force -ErrorAction SilentlyContinue
                    if ($result.success) {
                        $lblUploadStatusRef.ForeColor = [System.Drawing.Color]::SeaGreen
                        $lblUploadStatusRef.Text = "Done - see the certificates listed above and below."
                        $lstCertsRef.Items.Clear()
                        $certKeyIdsRef.Clear()
                        foreach ($c in @($result.certificates)) {
                            [void]$lstCertsRef.Items.Add("$($c.DisplayName)  [$($c.Thumbprint)]  expires $($c.Expiry)")
                            $certKeyIdsRef.Add([string]$c.KeyId)
                        }
                    }
                    else {
                        Write-DialogError -StatusLabel $lblUploadStatusRef -LogBox $rtbUploadLogRef -ErrorMessage $result.error
                    }
                }
                catch {
                    Write-DialogError -StatusLabel $lblUploadStatusRef -LogBox $rtbUploadLogRef -ErrorMessage "Could not read result (exit code $code)."
                }
            }
            else {
                Write-DialogError -StatusLabel $lblUploadStatusRef -LogBox $rtbUploadLogRef -ErrorMessage "No result written (exit code $code). See progress above."
            }
        }.GetNewClosure()
    }.GetNewClosure())

    $btnUpload.Add_Click({
        $uploadTenant = $txtTenant.Text.Trim()
        $uploadClient = $txtClient.Text.Trim()
        $uploadThumb  = $txtThumb.Text.Trim()

        if (-not $uploadTenant -or -not $uploadClient -or -not $uploadThumb) {
            [System.Windows.Forms.MessageBox]::Show("Fill in Tenant ID, Client ID, and Certificate Thumbprint first.", "Missing fields", "OK", "Warning") | Out-Null
            return
        }

        $localCert = $null
        try {
            $store = New-Object System.Security.Cryptography.X509Certificates.X509Store("My", [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
            $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
            $localCert = $store.Certificates | Where-Object { $_.Thumbprint -eq $uploadThumb } | Select-Object -First 1
            $store.Close()
        } catch { }
        if (-not $localCert) {
            [System.Windows.Forms.MessageBox]::Show("No certificate with thumbprint $uploadThumb was found in CurrentUser\My. Pick or generate one first.", "Certificate not found", "OK", "Warning") | Out-Null
            return
        }

        $r = [System.Windows.Forms.MessageBox]::Show(
            "This adds `"$($localCert.Subject)`" to the app registration's trusted certificates in Entra ID.`n`nRequires signing in with YOUR OWN account (a console window and a browser window will both briefly open) and either the Application Administrator role or being an owner of this app registration.`n`nAny certificates already trusted for this app registration are kept, not replaced. Continue?",
            "Confirm certificate upload", "YesNo", "Question")
        if ($r -ne "Yes") { return }

        $btnUpload.Enabled = $false
        $btnCheckCerts.Enabled = $false
        $lblUploadStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblUploadStatus.Text = "Starting sign-in..."
        $rtbUploadLog.Clear()

        $configPath = Join-Path $env:TEMP (".itsense_certupload_config_" + [guid]::NewGuid().ToString("N") + ".json")
        $resultPath = Join-Path $env:TEMP (".itsense_certupload_result_" + [guid]::NewGuid().ToString("N") + ".json")
        $config = [pscustomobject]@{
            Mode             = "Upload"
            TenantId         = $uploadTenant
            ClientId         = $uploadClient
            CertThumbprint   = $uploadThumb
            CertSubject      = $localCert.Subject
            CertBase64       = [Convert]::ToBase64String($localCert.RawData)
            CertNotBefore    = $localCert.NotBefore.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            CertNotAfter     = $localCert.NotAfter.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            OutputResultPath = $resultPath
        }
        try {
            $configJsonText = $config | ConvertTo-Json -Depth 8 -ErrorAction Stop
            [System.IO.File]::WriteAllText($configPath, $configJsonText, (New-Object System.Text.UTF8Encoding($false)))
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Could not write the config file needed to run this: $($_.Exception.Message)", "Failed to prepare", "OK", "Error") | Out-Null
            return
        }

        # Fresh aliases for the nested -OnComplete closure - see note at the
        # top of Show-CreateInIntuneDialog for why this matters here too.
        $btnUploadRef = $btnUpload
        $btnCheckCertsRef = $btnCheckCerts
        $lblUploadStatusRef = $lblUploadStatus
        $resultPathRef = $resultPath
        $configPathRef = $configPath
        $rtbUploadLogRef = $rtbUploadLog

        Start-PipelineProcess -ScriptContent $certUploadScript -TempScriptName ".itsense_embedded_certupload.ps1" -ArgumentString "-ConfigPath `"$configPathRef`"" -ExtraLogTarget $rtbUploadLog -ShowConsoleWindow -OnComplete {
            param($code)
            $btnUploadRef.Enabled = $true
            $btnCheckCertsRef.Enabled = $true
            Remove-Item $configPathRef -Force -ErrorAction SilentlyContinue

            if (Test-Path $resultPathRef) {
                try {
                    $result = Get-Content -Path $resultPathRef -Raw | ConvertFrom-Json
                    Remove-Item $resultPathRef -Force -ErrorAction SilentlyContinue
                    if ($result.success) {
                        $lblUploadStatusRef.ForeColor = [System.Drawing.Color]::SeaGreen
                        $lblUploadStatusRef.Text = "Certificate added. It can take a few minutes to propagate before Test connection succeeds with it."
                    }
                    else {
                        Write-DialogError -StatusLabel $lblUploadStatusRef -LogBox $rtbUploadLogRef -ErrorMessage $result.error
                    }
                }
                catch {
                    Write-DialogError -StatusLabel $lblUploadStatusRef -LogBox $rtbUploadLogRef -ErrorMessage "Could not read result (exit code $code)."
                }
            }
            else {
                Write-DialogError -StatusLabel $lblUploadStatusRef -LogBox $rtbUploadLogRef -ErrorMessage "No result written (exit code $code). See progress above."
            }
        }.GetNewClosure()
    }.GetNewClosure())

    $lstCerts.Add_SelectedIndexChanged({
        $btnDeleteEntraCert.Enabled = ($lstCerts.SelectedIndex -ge 0)
    }.GetNewClosure())

    $btnDeleteEntraCert.Add_Click({
        if ($lstCerts.SelectedIndex -lt 0) { return }
        $idx = $lstCerts.SelectedIndex
        $certLabel = [string]$lstCerts.Items[$idx]
        $keyIdToDelete = $certKeyIds[$idx]
        $deleteTenant = $txtTenant.Text.Trim()
        $deleteClient = $txtClient.Text.Trim()

        # Removing the only certificate left would break app-only sign-in
        # for the WHOLE rest of this app entirely, not just this dialog -
        # worth a sharper warning than a routine confirmation.
        if ($certKeyIds.Count -eq 1) {
            $r0 = [System.Windows.Forms.MessageBox]::Show(
                "This is the ONLY certificate currently trusted for this app registration. Removing it will break app-only sign-in for this app entirely, everywhere it's used (Deploy, Assign, App ID lookup, etc.) until a new one is uploaded. Continue anyway?",
                "This is the last certificate", "YesNo", "Warning")
            if ($r0 -ne "Yes") { return }
        }

        $r = [System.Windows.Forms.MessageBox]::Show(
            "Remove this certificate from Entra ID?`n`n$certLabel`n`nThis only removes it from Entra - it does NOT delete it from this machine. Use Delete local certificate above for that, separately.",
            "Confirm delete from Entra", "YesNo", "Warning")
        if ($r -ne "Yes") { return }

        $btnCheckCerts.Enabled = $false
        $btnUpload.Enabled = $false
        $btnDeleteEntraCert.Enabled = $false
        $lblUploadStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblUploadStatus.Text = "Starting sign-in..."
        $rtbUploadLog.Clear()

        $configPath = Join-Path $env:TEMP (".itsense_certupload_config_" + [guid]::NewGuid().ToString("N") + ".json")
        $resultPath = Join-Path $env:TEMP (".itsense_certupload_result_" + [guid]::NewGuid().ToString("N") + ".json")
        $config = [pscustomobject]@{
            Mode             = "DeleteCert"
            TenantId         = $deleteTenant
            ClientId         = $deleteClient
            KeyIdToDelete    = $keyIdToDelete
            OutputResultPath = $resultPath
        }
        try {
            $configJsonText = $config | ConvertTo-Json -Depth 8 -ErrorAction Stop
            [System.IO.File]::WriteAllText($configPath, $configJsonText, (New-Object System.Text.UTF8Encoding($false)))
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Could not write the config file needed to run this: $($_.Exception.Message)", "Failed to prepare", "OK", "Error") | Out-Null
            return
        }

        # Fresh aliases for the nested -OnComplete closure - see note at the
        # top of Show-CreateInIntuneDialog for why this matters here too.
        $btnCheckCertsRef = $btnCheckCerts
        $btnUploadRef = $btnUpload
        $btnDeleteEntraCertRef = $btnDeleteEntraCert
        $lblUploadStatusRef = $lblUploadStatus
        $resultPathRef = $resultPath
        $configPathRef = $configPath
        $rtbUploadLogRef = $rtbUploadLog

        Start-PipelineProcess -ScriptContent $certUploadScript -TempScriptName ".itsense_embedded_certupload.ps1" -ArgumentString "-ConfigPath `"$configPathRef`"" -ExtraLogTarget $rtbUploadLog -ShowConsoleWindow -OnComplete {
            param($code)
            $btnCheckCertsRef.Enabled = $true
            $btnUploadRef.Enabled = $true
            Remove-Item $configPathRef -Force -ErrorAction SilentlyContinue

            if (Test-Path $resultPathRef) {
                try {
                    $result = Get-Content -Path $resultPathRef -Raw | ConvertFrom-Json
                    Remove-Item $resultPathRef -Force -ErrorAction SilentlyContinue
                    if ($result.success) {
                        $lblUploadStatusRef.ForeColor = [System.Drawing.Color]::SeaGreen
                        $lblUploadStatusRef.Text = "Removed. Reloading certificate list..."
                        $btnCheckCertsRef.PerformClick()
                    }
                    else {
                        $btnDeleteEntraCertRef.Enabled = $true
                        Write-DialogError -StatusLabel $lblUploadStatusRef -LogBox $rtbUploadLogRef -ErrorMessage $result.error
                    }
                }
                catch {
                    $btnDeleteEntraCertRef.Enabled = $true
                    Write-DialogError -StatusLabel $lblUploadStatusRef -LogBox $rtbUploadLogRef -ErrorMessage "Could not read result (exit code $code)."
                }
            }
            else {
                $btnDeleteEntraCertRef.Enabled = $true
                Write-DialogError -StatusLabel $lblUploadStatusRef -LogBox $rtbUploadLogRef -ErrorMessage "No result written (exit code $code). See progress above."
            }
        }.GetNewClosure()
    }.GetNewClosure())

    $btnTest.Add_Click({
        $testTenant = $txtTenant.Text.Trim()
        $testClient = $txtClient.Text.Trim()
        $testThumb  = $txtThumb.Text.Trim()

        if (-not $testTenant -or -not $testClient -or -not $testThumb) {
            $lblTestResult.ForeColor = [System.Drawing.Color]::Firebrick
            $lblTestResult.Text = "Fill in Tenant ID, Client ID, and Certificate Thumbprint first."
            return
        }

        $lblTestResult.ForeColor = [System.Drawing.Color]::DimGray
        $lblTestResult.Text = "Connecting..."
        $dlg.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $btnTest.Enabled = $false

        # Fresh local aliases, assigned here (within this closure's own execution)
        # rather than reused directly from the outer capture. A closure nested
        # inside an already-closured handler (the Timer.Add_Tick below, nested
        # inside this Add_Click) does not reliably re-capture variables that
        # were themselves captured by an outer GetNewClosure() call - only
        # variables freshly assigned in the immediately-enclosing scope, like
        # these aliases (and $ps/$handle/$timer below), come through reliably.
        $dlgRef = $dlg
        $btnTestRef = $btnTest
        $lblTestResultRef = $lblTestResult

        $rs = [runspacefactory]::CreateRunspace()
        $rs.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript({
            param($TenantId, $ClientId, $CertThumb)
            Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
            Connect-MgGraph -TenantId $TenantId -ClientId $ClientId -CertificateThumbprint $CertThumb -NoWelcome -ErrorAction Stop
            $ctx = Get-MgContext -ErrorAction Stop
            [pscustomobject]@{ AppName = $ctx.AppName; AuthType = $ctx.AuthType }
        }).AddArgument($testTenant).AddArgument($testClient).AddArgument($testThumb)

        $handle = $ps.BeginInvoke()
        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 300
        $timer.Add_Tick({
            if (-not $handle.IsCompleted) { return }
            $timer.Stop(); $timer.Dispose()
            $dlgRef.Cursor = [System.Windows.Forms.Cursors]::Default
            [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default
            $btnTestRef.Enabled = $true
            try {
                $raw = @($ps.EndInvoke($handle))
                if ($ps.Streams.Error.Count -gt 0) {
                    $lblTestResultRef.ForeColor = [System.Drawing.Color]::Firebrick
                    $lblTestResultRef.Text = "Failed: $($ps.Streams.Error[0].ToString())"
                }
                elseif ($raw.Count -eq 0) {
                    $lblTestResultRef.ForeColor = [System.Drawing.Color]::Firebrick
                    $lblTestResultRef.Text = "Failed: no response."
                }
                else {
                    $lblTestResultRef.ForeColor = [System.Drawing.Color]::SeaGreen
                    $lblTestResultRef.Text = "Success - connected as '$($raw[0].AppName)' ($($raw[0].AuthType))."
                }
            }
            catch {
                $lblTestResultRef.ForeColor = [System.Drawing.Color]::Firebrick
                $lblTestResultRef.Text = "Failed: $($_.Exception.Message)"
            }
            finally {
                $ps.Dispose(); $rs.Close(); $rs.Dispose()
            }
        }.GetNewClosure())
        $timer.Start()
    }.GetNewClosure())

    # Plain local box (not $Script:-qualified) - the btnSave handler below is a
    # closure and cannot reliably write $Script:-qualified variables (see the
    # note in Start-IntuneAppLookup). It records what to save here instead; the
    # actual $Script:GraphTenantId/etc mutation happens after ShowDialog
    # returns, in this function's own plain (non-closure) body.
    $saveResultBox = @{ Saved = $false; TenantId = $null; ClientId = $null; Thumbprint = $null }

    $btnSave.Add_Click({
        if (-not $txtTenant.Text.Trim() -or -not $txtClient.Text.Trim() -or -not $txtThumb.Text.Trim()) {
            [System.Windows.Forms.MessageBox]::Show("Tenant ID, Client ID, and thumbprint are all required.", "Missing values", "OK", "Warning") | Out-Null
            return
        }
        $saveResultBox.TenantId   = $txtTenant.Text.Trim()
        $saveResultBox.ClientId   = $txtClient.Text.Trim()
        $saveResultBox.Thumbprint = ($txtThumb.Text.Trim() -replace '\s', '')
        $saveResultBox.Saved = $true
        $dlg.Close()
    }.GetNewClosure())

    $btnCancel.Add_Click({ $dlg.Close() }.GetNewClosure())

    $dlg.CancelButton = $btnCancel
    $dlg.AcceptButton = $btnSave
    Set-Theme -Control $dlg
    [void]$dlg.ShowDialog($form)

    if ($saveResultBox.Saved) {
        if (Save-GraphSettings -TenantId $saveResultBox.TenantId -ClientId $saveResultBox.ClientId -CertificateThumbprint $saveResultBox.Thumbprint) {
            $Script:GraphTenantId = $saveResultBox.TenantId
            $Script:GraphClientId = $saveResultBox.ClientId
            $Script:GraphCertificateThumbprint = $saveResultBox.Thumbprint
            $Script:IntuneAppsCache.Clear()   # old cache may have been fetched under a different identity
            Write-Log "Settings saved. Client: $($saveResultBox.ClientId), Tenant: $($saveResultBox.TenantId).`r`n" ([System.Drawing.Color]::LightGreen)
            [System.Windows.Forms.MessageBox]::Show("Saved.", "Saved", "OK", "Information") | Out-Null
        }
    }
}

# =====================================================================
# Main window
# =====================================================================
$form = New-Object System.Windows.Forms.Form
$form.Text = "ITSENSE Intune App Catalog & Deployment (v$($Script:AppVersion))"
$form.Size = New-Object System.Drawing.Size(1080, 720)
$form.MinimumSize = New-Object System.Drawing.Size(860, 560)
$form.StartPosition = "CenterScreen"
$form.WindowState = [System.Windows.Forms.FormWindowState]::Maximized
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = "Fill"
$tabCatalog  = New-Object System.Windows.Forms.TabPage "App Catalog"
$tabPipeline = New-Object System.Windows.Forms.TabPage "Log"
$tabs.TabPages.AddRange(@($tabCatalog, $tabPipeline))
$form.Controls.Add($tabs)

$statusStrip = New-Object System.Windows.Forms.StatusStrip
$statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLabel.Spring = $true
$statusLabel.TextAlign = "MiddleLeft"
$statusStrip.Items.Add($statusLabel) | Out-Null
$form.Controls.Add($statusStrip)

function Set-Status {
    param([string]$Text)
    $statusLabel.Text = $Text
}

# Shared function purely so the theme-toggle logic lives in one place
# rather than being duplicated wherever a control triggers it.
# Shared by every operation dialog that has both a short status label and a
# live log box: writes the FULL error into the log (which has room and is
# already where the play-by-play lives) and leaves the status label with
# just a short, unmissable verdict - rather than cramming a long error
# message into a small label that then has to wrap across several lines and
# crowd out the log below it.
function Write-DialogError {
    param(
        [System.Windows.Forms.Label]$StatusLabel,
        [System.Windows.Forms.RichTextBox]$LogBox,
        [string]$ErrorMessage
    )
    $StatusLabel.ForeColor = [System.Drawing.Color]::Firebrick
    $StatusLabel.Text = "Failed - see the log below for details."
    if ($LogBox) {
        $LogBox.SelectionStart = $LogBox.TextLength
        $LogBox.SelectionLength = 0
        $LogBox.SelectionColor = [System.Drawing.Color]::FromArgb(255,110,110)
        $LogBox.AppendText("`r`n[FAILED] $ErrorMessage`r`n")
        $LogBox.SelectionColor = $LogBox.ForeColor
        $LogBox.ScrollToCaret()
    }
}

# =====================================================================
# App Catalog tab
# =====================================================================
# Wraps a set of buttons in a titled GroupBox so the toolbar reads as
# labeled topic clusters instead of one long undifferentiated row. Height is
# fixed (just enough for one button row); width auto-sizes to content so
# each group is only as wide as it needs to be.
function New-ToolbarGroup {
    param([string]$Title, [System.Windows.Forms.Control[]]$Buttons)

    $gb = New-Object System.Windows.Forms.GroupBox
    $gb.Text = $Title
    $gb.Height = 60
    $gb.AutoSize = $true
    $gb.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $gb.Margin = New-Object System.Windows.Forms.Padding(4,4,4,0)

    $flow = New-Object System.Windows.Forms.FlowLayoutPanel
    $flow.Location = New-Object System.Drawing.Point(8,20)
    $flow.AutoSize = $true
    $flow.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $flow.WrapContents = $false
    $flow.FlowDirection = "LeftToRight"

    foreach ($b in $Buttons) {
        $b.AutoSize = $true
        $b.Padding = New-Object System.Windows.Forms.Padding(8,3,8,3)
        $b.Margin = New-Object System.Windows.Forms.Padding(0,0,4,0)
        $flow.Controls.Add($b)
    }
    $gb.Controls.Add($flow)
    return $gb
}

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
$btnDelete = New-Object System.Windows.Forms.Button; $btnDelete.Text = "Remove from catalog..."
$btnSave   = New-Object System.Windows.Forms.Button; $btnSave.Text = "Force save"
$btnReload = New-Object System.Windows.Forms.Button; $btnReload.Text = "Reload"
$btnOpen   = New-Object System.Windows.Forms.Button; $btnOpen.Text = "Open other folder..."
$btnLookupIds = New-Object System.Windows.Forms.Button; $btnLookupIds.Text = "Look up App IDs..."
$btnCheckIntuneOnly = New-Object System.Windows.Forms.Button; $btnCheckIntuneOnly.Text = "Intune sync check..."
$btnBatchAssign = New-Object System.Windows.Forms.Button; $btnBatchAssign.Text = "Batch assign groups..."
$btnSyncMetadata = New-Object System.Windows.Forms.Button; $btnSyncMetadata.Text = "Sync metadata..."
$btnBatchDeploy = New-Object System.Windows.Forms.Button; $btnBatchDeploy.Text = "Batch deploy..."
$btnGroupManager = New-Object System.Windows.Forms.Button; $btnGroupManager.Text = "Group manager..."
$btnFavoriteGroups = New-Object System.Windows.Forms.Button; $btnFavoriteGroups.Text = "Favorite groups..."
$btnGroupDrift = New-Object System.Windows.Forms.Button; $btnGroupDrift.Text = "Check group names..."
$btnRunLaunch = New-Object System.Windows.Forms.Button; $btnRunLaunch.Text = "Package apps"
$btnCertSetup = New-Object System.Windows.Forms.Button; $btnCertSetup.Text = "Settings..."

# One shared ToolTip component serves every button - several have
# similar-sounding names that actually do quite different things (e.g.
# "Intune sync check..." vs "Sync metadata..."), with no way for a new
# user to tell them apart without clicking each one to find out.
$toolbarTips = New-Object System.Windows.Forms.ToolTip
$toolbarTips.AutoPopDelay = 15000
$toolbarTips.InitialDelay = 400
$toolbarTips.ReshowDelay = 200
$toolbarTips.SetToolTip($btnNew, "Add a new app to the catalog by name - doesn't touch Intune yet.")
$toolbarTips.SetToolTip($btnEdit, "Edit the selected app's name, winget ID, and group assignments.")
$toolbarTips.SetToolTip($btnDelete, "Remove the selected app from the catalog. Does not delete it from Intune.")
$toolbarTips.SetToolTip($btnSave, "Not usually needed - every change already saves itself automatically. Force-saves the whole catalog now anyway, if you ever want to be extra sure.")
$toolbarTips.SetToolTip($btnReload, "Discard any unsaved changes and reload the catalog from disk.")
$toolbarTips.SetToolTip($btnOpen, "Switch to a different folder of per-app JSON files.")
$toolbarTips.SetToolTip($btnLookupIds, "Search Intune by name for apps missing an App ID, and fill it in.")
$toolbarTips.SetToolTip($btnCheckIntuneOnly, "Find apps that exist in Intune but aren't in this catalog yet.")
$toolbarTips.SetToolTip($btnBatchAssign, "Preview and apply group assignments across multiple apps at once.")
$toolbarTips.SetToolTip($btnSyncMetadata, "Pull current metadata from Intune into the local catalog for apps that already have an App ID. Read-only.")
$toolbarTips.SetToolTip($btnBatchDeploy, "Create multiple apps in Intune, in dependency order. Uses metadata saved via 'Save for later...' where an app has it, otherwise the same defaults Deploy to Intune's own form would.")
$toolbarTips.SetToolTip($btnGroupManager, "Create, update, or delete an Entra ID group and manage its members.")
$toolbarTips.SetToolTip($btnFavoriteGroups, "Pick which groups show up as ready-to-tick options in every app's Required/Available/Uninstall lists.")
$toolbarTips.SetToolTip($btnGroupDrift, "Check every group name referenced in the catalog against what actually exists in Entra ID.")
$toolbarTips.SetToolTip($btnRunLaunch, "Build the .intunewin package(s) for the selected (or all) uncommon apps.")
$toolbarTips.SetToolTip($btnCertSetup, "Configure the Tenant ID, Client ID, and certificate used to connect to Microsoft Graph.")

$lblSearch = New-Object System.Windows.Forms.Label
$lblSearch.Text = "Search:"
$lblSearch.AutoSize = $true
$lblSearch.Padding = New-Object System.Windows.Forms.Padding(10,7,0,0)
$txtSearch = New-Object System.Windows.Forms.TextBox
$txtSearch.Width = 220

$gbCatalog = New-ToolbarGroup -Title "Catalog" -Buttons @($btnNew, $btnEdit, $btnDelete, $btnSave, $btnReload, $btnOpen, $btnFavoriteGroups)
# $btnRunLaunch ("Package apps...") lives here, not in the leftover "Tools"
# group below - it's an Intune-pipeline action (builds the .intunewin
# package(s) apps get deployed from), same category as Batch deploy/Sync
# metadata, not a general-purpose tool.
$gbIntune  = New-ToolbarGroup -Title "Intune"  -Buttons @($btnLookupIds, $btnCheckIntuneOnly, $btnBatchAssign, $btnSyncMetadata, $btnBatchDeploy, $btnRunLaunch)
$gbEntra   = New-ToolbarGroup -Title "Entra ID" -Buttons @($btnGroupManager, $btnGroupDrift)
$gbTools   = New-ToolbarGroup -Title "Settings" -Buttons @($btnCertSetup)

$searchPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$searchPanel.AutoSize = $true
$searchPanel.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
$searchPanel.FlowDirection = "LeftToRight"
$searchPanel.Margin = New-Object System.Windows.Forms.Padding(4,4,4,0)
$searchPanel.Controls.Add($lblSearch)
$searchPanel.Controls.Add($txtSearch)

$toolbar.Controls.AddRange(@($gbCatalog, $gbIntune, $gbEntra, $gbTools, $searchPanel))
$tabCatalog.Controls.Add($toolbar)

# Hidden by default - shown only when Graph credentials aren't configured
# yet, which otherwise silently blocks every Graph-based feature in this
# app with no visible explanation on the tab a new user actually sees
# first. Previously this only ever got written to the Log tab, which
# isn't the default active one - easy to never notice until something
# fails with no obvious reason why.
$panelCredWarning = New-Object System.Windows.Forms.Panel
$panelCredWarning.Dock = "Top"
$panelCredWarning.Height = 40
$panelCredWarning.BackColor = [System.Drawing.Color]::FromArgb(255, 243, 205)
$panelCredWarning.Visible = $false
$lblCredWarning = New-Object System.Windows.Forms.Label
$lblCredWarning.Text = "No Graph connection configured yet - Intune/Entra ID features won't work until this is set up."
$lblCredWarning.ForeColor = [System.Drawing.Color]::FromArgb(133, 100, 4)
$lblCredWarning.Font = New-Object System.Drawing.Font($panelCredWarning.Font, [System.Drawing.FontStyle]::Bold)
$lblCredWarning.Location = New-Object System.Drawing.Point(12, 10)
$lblCredWarning.AutoSize = $true
$panelCredWarning.Controls.Add($lblCredWarning)
$btnCredWarningSettings = New-Object System.Windows.Forms.Button
$btnCredWarningSettings.Text = "Open Settings..."
$btnCredWarningSettings.Location = New-Object System.Drawing.Point(720, 5)
$btnCredWarningSettings.Size = New-Object System.Drawing.Size(130, 28)
$btnCredWarningSettings.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$panelCredWarning.Controls.Add($btnCredWarningSettings)
$btnCredWarningSettings.Add_Click({ Show-CertificateSetupDialog })
$tabCatalog.Controls.Add($panelCredWarning)

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = "Fill"
$grid.ReadOnly = $true
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.AllowUserToResizeRows = $false
$grid.SelectionMode = "FullRowSelect"
$grid.MultiSelect = $true
$grid.AutoGenerateColumns = $false
$grid.AutoSizeColumnsMode = "Fill"
$grid.RowHeadersVisible = $false
$grid.BackgroundColor = [System.Drawing.Color]::White

function New-GridColumn {
    param($Name, $Header, $Width = 100, $FillWeight = 20)
    $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $col.Name = $Name
    $col.HeaderText = $Header
    $col.DataPropertyName = $Name
    $col.FillWeight = $FillWeight
    return $col
}

$grid.Columns.Add((New-GridColumn "AppName" "App Name" -FillWeight 18)) | Out-Null
$grid.Columns.Add((New-GridColumn "WingetId" "Winget ID" -FillWeight 14)) | Out-Null
$grid.Columns.Add((New-GridColumn "Uncommon" "Uncommon" -FillWeight 5)) | Out-Null
$grid.Columns.Add((New-GridColumn "Folder" "Package folder" -FillWeight 24)) | Out-Null
$grid.Columns.Add((New-GridColumn "Required" "Required" -FillWeight 5)) | Out-Null
$grid.Columns.Add((New-GridColumn "Available" "Available" -FillWeight 5)) | Out-Null
$grid.Columns.Add((New-GridColumn "Uninstall" "Uninstall" -FillWeight 5)) | Out-Null
$grid.Columns.Add((New-GridColumn "AppId" "App ID" -FillWeight 13)) | Out-Null
$grid.Columns.Add((New-GridColumn "Status" "Status" -FillWeight 11)) | Out-Null

$colIndex = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colIndex.Name = "Index"
$colIndex.DataPropertyName = "Index"
$colIndex.Visible = $false
$grid.Columns.Add($colIndex) | Out-Null

$tabCatalog.Controls.Add($grid)
$grid.BringToFront()

# Highlight the Status column when it's flagging something, so problems are
# visible at a glance across the whole catalog instead of only when you open
# each app individually.
$grid.Add_CellFormatting({
    param($gridSender, $e)
    if ($grid.Columns[$e.ColumnIndex].Name -ne "Status") { return }
    if ($e.Value -and [string]$e.Value) {
        if ([string]$e.Value -eq "Metadata saved - ready to deploy") {
            # Good news, not a warning - distinct from the orange/bold
            # treatment below, which is reserved for things that actually
            # need attention (no App ID at all, a missing package).
            $e.CellStyle.ForeColor = [System.Drawing.Color]::SeaGreen
            $e.CellStyle.Font = New-Object System.Drawing.Font($grid.Font, [System.Drawing.FontStyle]::Bold)
        }
        else {
            $e.CellStyle.ForeColor = [System.Drawing.Color]::DarkOrange
            $e.CellStyle.Font = New-Object System.Drawing.Font($grid.Font, [System.Drawing.FontStyle]::Bold)
        }
    }
})

function Refresh-Grid {
    $filter = $txtSearch.Text.Trim().ToLower()
    $rows = New-Object System.Collections.Generic.List[Object]

    for ($i = 0; $i -lt $Script:Apps.Count; $i++) {
        $app = $Script:Apps[$i]
        if ($filter) {
            $hay = ("$($app.appName) $($app.wingetId)").ToLower()
            if ($hay -notlike "*$filter*") { continue }
        }
        $isUncommon = Test-AppIsUncommon -App $app
        # Resolved once and reused for both the Status warning and the
        # Folder column below, rather than searching the filesystem twice
        # per uncommon app on every grid refresh.
        $pkg = if ($isUncommon) { Resolve-AppPackagePath -AppName $app.appName -Uncommon $true } else { $null }

        $status = ""
        if (-not $app.appId) {
            $status = if ($app.metadata) { "Metadata saved - ready to deploy" } else { "No App ID" }
        }
        elseif ($isUncommon -and -not $pkg.Found) {
            $status = "Package missing"
        }

        $folderDisplay = ""
        if ($isUncommon) {
            $folderDisplay = if ($pkg.Found) { Split-Path $pkg.Path -Parent } else { "(not found)" }
        }

        $rows.Add([pscustomobject]@{
            AppName   = $app.appName
            WingetId  = $app.wingetId
            Uncommon  = if ($isUncommon) { "Yes" } else { "" }
            Folder    = $folderDisplay
            Required  = @($app.requiredFor).Count
            Available = @($app.availableFor).Count
            Uninstall = @($app.uninstallFor).Count
            AppId     = if ($app.appId) { $app.appId } else { "(none yet)" }
            Status    = $status
            Index     = $i
        })
    }

    $grid.DataSource = $null
    $grid.DataSource = $rows

    $reqTotal   = ($Script:Apps | ForEach-Object { @($_.requiredFor).Count } | Measure-Object -Sum).Sum
    $availTotal = ($Script:Apps | ForEach-Object { @($_.availableFor).Count } | Measure-Object -Sum).Sum
    $uninstTotal= ($Script:Apps | ForEach-Object { @($_.uninstallFor).Count } | Measure-Object -Sum).Sum
    $dirty = if ($Script:UnsavedChangesBox.Value) { "  *unsaved changes*" } else { "" }
    Set-Status "$($Script:Apps.Count) apps  |  $reqTotal required, $availTotal available, $uninstTotal uninstall assignments  |  $Script:LinkedFilePath$dirty"
}

function Get-SelectedAppIndex {
    if ($grid.SelectedRows.Count -eq 0) { return $null }
    return [int]$grid.SelectedRows[0].Cells["Index"].Value
}

# Plural counterpart, for the multi-select-aware operations (Batch Assign,
# Package all apps) - returns every currently selected row's catalog index,
# or an empty array if nothing's selected (their callers treat that as "no
# scoping, use everything" rather than an error).
function Get-SelectedAppIndices {
    return @($grid.SelectedRows | ForEach-Object { [int]$_.Cells["Index"].Value })
}

# Fetches ONE app's full current object from Intune, for pre-filling Deploy
# to Intune's fields with what's actually live there in Update mode, rather
# than local guesses. Same runspace pattern as Start-IntuneAppLookup, just
# scoped to a single app and returning its parsed fields instead of a name
# list.
function Start-AppMetadataFetch {
    param([string]$AppId, [scriptblock]$OnComplete)

    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        if ($OnComplete) { & $OnComplete $false "Microsoft.Graph.Authentication module isn't installed." $null }
        return
    }
    if (-not (Test-GraphCredentialsConfigured)) {
        if ($OnComplete) { & $OnComplete $false "Not configured" $null }
        return
    }

    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        param($TenantId, $ClientId, $CertThumb, $TargetAppId)
        Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
        $ctx = Get-MgContext -ErrorAction SilentlyContinue
        if ($null -eq $ctx -or $ctx.AuthType -ne 'AppOnly' -or $ctx.ClientId -ne $ClientId) {
            Connect-MgGraph -TenantId $TenantId -ClientId $ClientId `
                -CertificateThumbprint $CertThumb -NoWelcome -ErrorAction Stop
        }

        $app = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$TargetAppId" -Method GET -ErrorAction Stop

        # Same endpoint and filtering as the bulk Sync metadata script -
        # targetType -eq "child" specifically. Corrected after being wrong
        # the first time (was "parent") - see the detailed note next to
        # this same fix in the sync script for the concrete evidence that
        # settled the actual direction. Wrapped in its own try/catch so a
        # failure here doesn't sink the whole fetch - falling back to an
        # empty list is a smaller, more contained failure than losing
        # every other field along with it.
        $dependencyNames = @()
        try {
            $rels = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$TargetAppId/relationships" -Method GET -ErrorAction Stop
            $dependencyNames = @($rels.value | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.mobileAppDependency' -and $_.targetType -eq 'child' } | ForEach-Object { $_.targetDisplayName } | Where-Object { $_ })
        }
        catch { }

        # Structured the same way the GUI's submit-side config is, so the
        # populate-from-fetch logic can read these fields directly into the
        # same controls the submit logic reads them back out of.
        $detectionRule = $null
        foreach ($rule in @($app.detectionRules)) {
            $odType = $rule.'@odata.type'
            if ($odType -eq '#microsoft.graph.win32LobAppPowerShellScriptDetection' -and $rule.scriptContent) {
                $scriptText = $null
                try { $scriptText = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($rule.scriptContent)) } catch { }
                $detectionRule = [pscustomobject]@{ Type = "Script"; Script_Content = $scriptText }
                break
            }
            elseif ($odType -eq '#microsoft.graph.win32LobAppProductCodeDetection') {
                $detectionRule = [pscustomobject]@{
                    Type                 = "Msi"
                    Msi_ProductCode      = $rule.productCode
                    Msi_VersionOperator  = $rule.productVersionOperator
                    Msi_Version          = $rule.productVersion
                }
                break
            }
            elseif ($odType -eq '#microsoft.graph.win32LobAppFileSystemDetection') {
                $detectionRule = [pscustomobject]@{
                    Type                = "File"
                    File_Path            = $rule.path
                    File_Name            = $rule.fileOrFolderName
                    File_Check32Bit      = $rule.check32BitOn64System
                    File_DetectionType   = $rule.detectionType
                    File_Operator        = $rule.operator
                    File_DetectionValue  = $rule.detectionValue
                }
                break
            }
            elseif ($odType -eq '#microsoft.graph.win32LobAppRegistryDetection') {
                $detectionRule = [pscustomobject]@{
                    Type                = "Registry"
                    Reg_KeyPath          = $rule.keyPath
                    Reg_ValueName        = $rule.valueName
                    Reg_Check32Bit       = $rule.check32BitOn64System
                    Reg_DetectionType    = $rule.detectionType
                    Reg_Operator         = $rule.operator
                    Reg_DetectionValue   = $rule.detectionValue
                }
                break
            }
        }

        # minimumSupportedOperatingSystem comes back as either a Hashtable or
        # a PSCustomObject depending on how the Graph module happens to
        # deserialize this particular response - handled generically here
        # rather than assuming one or the other.
        $minOsPropName = $null
        if ($app.minimumSupportedOperatingSystem) {
            $minOsObj = $app.minimumSupportedOperatingSystem
            if ($minOsObj -is [System.Collections.IDictionary]) {
                foreach ($key in $minOsObj.Keys) {
                    if ($minOsObj[$key] -eq $true) { $minOsPropName = $key; break }
                }
            }
            else {
                foreach ($prop in $minOsObj.PSObject.Properties) {
                    if ($prop.Value -eq $true) { $minOsPropName = $prop.Name; break }
                }
            }
        }

        [pscustomobject]@{
            DisplayName             = $app.displayName
            Description             = $app.description
            Publisher               = $app.publisher
            Owner                   = $app.owner
            Developer               = $app.developer
            InformationUrl          = $app.informationUrl
            PrivacyInformationUrl   = $app.privacyInformationUrl
            Notes                   = $app.notes
            InstallCommandLine      = $app.installCommandLine
            UninstallCommandLine    = $app.uninstallCommandLine
            ApplicableArchitectures = $app.applicableArchitectures
            AllowedArchitectures    = $app.allowedArchitectures
            RunAsAccount            = $app.installExperience.runAsAccount
            MinOSPropertyName       = $minOsPropName
            DetectionRule           = $detectionRule
            Dependencies            = $dependencyNames
            MinDiskSpaceMB          = $app.minimumFreeDiskSpaceInMB
            MinMemoryMB             = $app.minimumMemoryInMB
            MinProcessors           = $app.minimumNumberOfProcessors
            MinCpuSpeedMHz          = $app.minimumCpuSpeedInMHz
            InstallTimeMinutes      = $app.installExperience.maxRunTimeInMinutes
            DeviceRestartBehavior   = $app.installExperience.deviceRestartBehavior
            AllowAvailableUninstall = $app.allowAvailableUninstall
            ReturnCodes             = @($app.returnCodes | ForEach-Object { [pscustomobject]@{ returnCode = $_.returnCode; type = $_.type } })
        }
    }).AddArgument($Script:GraphTenantId).AddArgument($Script:GraphClientId).AddArgument($Script:GraphCertificateThumbprint).AddArgument($AppId)

    $handle = $ps.BeginInvoke()
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 300
    $timer.Add_Tick({
        if (-not $handle.IsCompleted) { return }
        $timer.Stop()
        $timer.Dispose()
        try {
            $raw = @($ps.EndInvoke($handle))
            if ($ps.Streams.Error.Count -gt 0) {
                $errMsg = ($ps.Streams.Error | ForEach-Object { $_.ToString() }) -join "`n"
                if ($OnComplete) { & $OnComplete $false $errMsg $null }
            }
            elseif ($raw.Count -eq 0) {
                if ($OnComplete) { & $OnComplete $false "No response came back." $null }
            }
            else {
                if ($OnComplete) { & $OnComplete $true "" $raw[0] }
            }
        }
        catch {
            if ($OnComplete) { & $OnComplete $false $_.Exception.Message $null }
        }
        finally {
            $ps.Dispose()
            $rs.Close()
            $rs.Dispose()
        }
    }.GetNewClosure())
    $timer.Start()
}

# Fetches a group's current members by name, for Group Manager's "current
# members" list. Same lightweight runspace pattern as Start-AppMetadataFetch
# - read-only, no need for the heavier child-process machinery the actual
# write operations (add/remove/delete) use.
function Start-GroupMembersFetch {
    param([string]$GroupName, [scriptblock]$OnComplete)

    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        if ($OnComplete) { & $OnComplete $false "Microsoft.Graph.Authentication module isn't installed." $null }
        return
    }
    if (-not (Test-GraphCredentialsConfigured)) {
        if ($OnComplete) { & $OnComplete $false "Not configured" $null }
        return
    }

    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        param($TenantId, $ClientId, $CertThumb, $TargetGroupName)
        Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
        $ctx = Get-MgContext -ErrorAction SilentlyContinue
        if ($null -eq $ctx -or $ctx.AuthType -ne 'AppOnly' -or $ctx.ClientId -ne $ClientId) {
            Connect-MgGraph -TenantId $TenantId -ClientId $ClientId `
                -CertificateThumbprint $CertThumb -NoWelcome -ErrorAction Stop
        }

        $escapedName = $TargetGroupName.Replace("'", "''")
        $encodedFilter = [Uri]::EscapeDataString("displayName eq '$escapedName'")
        $existing = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=$encodedFilter&`$select=id,displayName,description" -Method GET -ErrorAction Stop
        if (-not $existing.value -or $existing.value.Count -eq 0) {
            return [pscustomobject]@{ Found = $false; GroupId = $null; Description = $null; Members = @() }
        }
        $groupId = $existing.value[0].id
        $description = $existing.value[0].description

        $members = New-Object System.Collections.Generic.List[object]
        $uri = "https://graph.microsoft.com/v1.0/groups/$groupId/members?`$select=id,displayName&`$top=999"
        do {
            $result = Invoke-MgGraphRequest -Uri $uri -Method GET -ErrorAction Stop
            foreach ($m in $result.value) {
                $mType = if ($m.'@odata.type' -eq '#microsoft.graph.group') { "Group" } else { "User" }
                $members.Add([pscustomobject]@{ id = $m.id; displayName = $m.displayName; type = $mType })
            }
            $uri = $result.'@odata.nextLink'
        } while ($uri)

        [pscustomobject]@{ Found = $true; GroupId = $groupId; Description = $description; Members = $members.ToArray() }
    }).AddArgument($Script:GraphTenantId).AddArgument($Script:GraphClientId).AddArgument($Script:GraphCertificateThumbprint).AddArgument($GroupName)

    $handle = $ps.BeginInvoke()
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 300
    $timer.Add_Tick({
        if (-not $handle.IsCompleted) { return }
        $timer.Stop()
        $timer.Dispose()
        try {
            $raw = @($ps.EndInvoke($handle))
            if ($ps.Streams.Error.Count -gt 0) {
                $errMsg = ($ps.Streams.Error | ForEach-Object { $_.ToString() }) -join "`n"
                if ($OnComplete) { & $OnComplete $false $errMsg $null }
            }
            elseif ($raw.Count -eq 0) {
                if ($OnComplete) { & $OnComplete $false "No response came back." $null }
            }
            else {
                if ($OnComplete) { & $OnComplete $true "" $raw[0] }
            }
        }
        catch {
            if ($OnComplete) { & $OnComplete $false $_.Exception.Message $null }
        }
        finally {
            $ps.Dispose()
            $rs.Close()
            $rs.Dispose()
        }
    }.GetNewClosure())
    $timer.Start()
}


# Direct-saves after a successful deploy, same as every other single,
# atomic catalog action this session - "Force save" (the main toolbar
# button) is no longer a required step for this to actually persist.
# =====================================================================
function Invoke-QuickDeploy {
    param([int]$Index)
    $app = $Script:Apps[$Index]
    if (-not $app.appName.Trim()) {
        [System.Windows.Forms.MessageBox]::Show("This app has no name.", "No name", "OK", "Warning") | Out-Null
        return
    }
    $deployResult = Show-CreateInIntuneDialog -AppName $app.appName -WingetId $app.wingetId -ExistingAppId $app.appId
    if ($deployResult -and $deployResult.NewAppId) {
        $Script:Apps[$Index].appId = $deployResult.NewAppId
        if ($deployResult.NewAppName) { $Script:Apps[$Index].appName = $deployResult.NewAppName }
        $Script:UnsavedChangesBox.Value = $true
        # Direct-save, not just staged in memory - this action's entire
        # purpose IS recording the new App ID, and the stakes of NOT saving
        # it are real: if the save is forgotten and this app gets "deployed"
        # again later thinking it still needs it, that creates a genuine
        # duplicate in Intune, not just a display inconsistency.
        [void](Save-AppsToFile -Path $Script:LinkedFilePath)
        Refresh-Grid
    }
}

function Invoke-QuickAssignGroups {
    param([int]$Index)
    $app = $Script:Apps[$Index]
    if (-not $app.appId) {
        [System.Windows.Forms.MessageBox]::Show("This app doesn't have an App ID yet - use Deploy to Intune first.", "No App ID", "OK", "Warning") | Out-Null
        return
    }
    Show-TargetedAssignDialog -AppId $app.appId -AppName $app.appName `
        -RequiredGroups @($app.requiredFor) -AvailableGroups @($app.availableFor) -UninstallGroups @($app.uninstallFor) | Out-Null
}

function Invoke-QuickDeleteFromIntune {
    param([int]$Index)
    $app = $Script:Apps[$Index]
    $deleted = Show-DeleteAppDialog -AppId $app.appId -AppName $app.appName
    if (-not $deleted.Success) { return }
    # Show-DeleteAppDialog itself already removed the catalog entry and
    # saved when the user chose that - nothing left here to clear or save
    # for an entry that no longer exists. Only the "keep the entry, just
    # clear its App ID" path still needs handling here.
    if (-not $deleted.RemovedFromCatalog) {
        $Script:Apps[$Index].appId = ""
        $Script:UnsavedChangesBox.Value = $true
        # Direct-save, not just staged in memory - matters more here than
        # most other actions: without this, a stale App ID would linger in
        # the catalog after a successful Intune deletion, making the
        # catalog wrongly think the app still exists there until someone
        # remembered to save separately.
        [void](Save-AppsToFile -Path $Script:LinkedFilePath)
    }
    Refresh-Grid
}

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
function Save-AppMetadataToLocalCatalog {
    param($AppsRef, $LinkedFilePath, $AppName, $Metadata, $NewAppId = $null)

    $targetIndex = -1
    for ($si = 0; $si -lt $AppsRef.Count; $si++) {
        if ($AppsRef[$si].appName -eq $AppName) { $targetIndex = $si; break }
    }
    $createdNewEntry = $false
    if ($targetIndex -lt 0) {
        $newEntry = [pscustomobject]@{
            appId        = ""
            appName      = $AppName
            wingetId     = ""
            requiredFor  = @()
            availableFor = @()
            uninstallFor = @()
            metadata     = $null
        }
        [void]$AppsRef.Add($newEntry)
        $targetIndex = $AppsRef.Count - 1
        $createdNewEntry = $true
    }

    $existingApp = $AppsRef[$targetIndex]
    $updatedApp = [pscustomobject]@{
        appId        = if ($NewAppId) { $NewAppId } else { $existingApp.appId }
        appName      = $existingApp.appName
        wingetId     = $existingApp.wingetId
        requiredFor  = @($existingApp.requiredFor)
        availableFor = @($existingApp.availableFor)
        uninstallFor = @($existingApp.uninstallFor)
        metadata     = $Metadata
    }
    $AppsRef[$targetIndex] = $updatedApp

    $saveSucceeded = Save-AppsToFile -Path $LinkedFilePath
    return @{ Success = $saveSucceeded; CreatedNewEntry = $createdNewEntry }
}

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
# fields both Get-CatalogMetadataFieldDiffs and Merge-CatalogMetadata key
# off of, so the two stay in sync by construction - a field added to one
# but not the other would mean either a diff that's shown but can never
# actually be applied by the merge, or one silently applied that the diff
# UI never surfaced. Detection rule and return codes are handled by name,
# not through this list, in both functions - they're composite objects,
# not simple values.
function Get-CatalogMetadataSimpleFields {
    return @(
        @{ Key = "description"; Label = "Description" }
        @{ Key = "publisher"; Label = "Publisher" }
        @{ Key = "owner"; Label = "Owner" }
        @{ Key = "developer"; Label = "Developer" }
        @{ Key = "informationUrl"; Label = "Information URL" }
        @{ Key = "privacyUrl"; Label = "Privacy URL" }
        @{ Key = "notes"; Label = "Notes" }
        @{ Key = "installCommand"; Label = "Install command" }
        @{ Key = "uninstallCommand"; Label = "Uninstall command" }
        @{ Key = "architecture"; Label = "Architecture" }
        @{ Key = "minDiskSpaceMB"; Label = "Disk space requirement" }
        @{ Key = "minMemoryMB"; Label = "Memory requirement" }
        @{ Key = "minProcessors"; Label = "Min. processors requirement" }
        @{ Key = "minCpuSpeedMHz"; Label = "Min. CPU speed requirement" }
        @{ Key = "installTimeMinutes"; Label = "Install time required" }
        @{ Key = "deviceRestartBehavior"; Label = "Device restart behavior" }
        @{ Key = "allowAvailableUninstall"; Label = "Allow available uninstall" }
    )
}

function Get-CatalogMetadataFieldDiffs {
    param($Local, $Remote)

    $diffs = New-Object System.Collections.Generic.List[object]
    if (-not $Local) { return $diffs.ToArray() }

    foreach ($f in (Get-CatalogMetadataSimpleFields)) {
        $localVal = [string]$Local.($f.Key)
        $remoteVal = [string]$Remote.($f.Key)
        if ($localVal -ne $remoteVal) {
            $diffs.Add([pscustomobject]@{ Field = $f.Label; Local = $localVal; Remote = $remoteVal })
        }
    }

    $localDetSummary = if ($Local.detectionRule) { ($Local.detectionRule | ConvertTo-Json -Compress -Depth 5) } else { "" }
    $remoteDetSummary = if ($Remote.detectionRule) { ($Remote.detectionRule | ConvertTo-Json -Compress -Depth 5) } else { "" }
    if ($localDetSummary -ne $remoteDetSummary) {
        $diffs.Add([pscustomobject]@{ Field = "Detection rule"; Local = $localDetSummary; Remote = $remoteDetSummary })
    }

    $localRcSummary = if (@($Local.returnCodes).Count -gt 0) { (@($Local.returnCodes) | ConvertTo-Json -Compress -Depth 5) } else { "" }
    $remoteRcSummary = if (@($Remote.returnCodes).Count -gt 0) { (@($Remote.returnCodes) | ConvertTo-Json -Compress -Depth 5) } else { "" }
    if ($localRcSummary -ne $remoteRcSummary) {
        $diffs.Add([pscustomobject]@{ Field = "Return codes"; Local = $localRcSummary; Remote = $remoteRcSummary })
    }

    return $diffs.ToArray()
}

# Builds a new catalog-shaped metadata object starting from $Remote
# (Intune's fetched value - the default winner everywhere else in this
# app), substituting the LOCAL value for any field whose Label is in
# $KeepLocalFields (the same Field values Get-CatalogMetadataFieldDiffs
# produces and Show-MetadataDriftDialog returns as its "keep local"
# picks). Used by bulk "Sync metadata..." to actually apply a per-field
# reviewed choice for an app instead of either blindly taking Intune's
# value for everything or skipping the app outright.
function Merge-CatalogMetadata {
    param($Remote, $Local, [string[]]$KeepLocalFields)

    $merged = $Remote.PSObject.Copy()
    if (-not $Local -or @($KeepLocalFields).Count -eq 0) { return $merged }

    foreach ($f in (Get-CatalogMetadataSimpleFields)) {
        if ($KeepLocalFields -contains $f.Label) {
            $merged | Add-Member -NotePropertyName $f.Key -NotePropertyValue $Local.($f.Key) -Force
        }
    }
    if ($KeepLocalFields -contains "Detection rule") {
        $merged | Add-Member -NotePropertyName "detectionRule" -NotePropertyValue $Local.detectionRule -Force
    }
    if ($KeepLocalFields -contains "Return codes") {
        $merged | Add-Member -NotePropertyName "returnCodes" -NotePropertyValue $Local.returnCodes -Force
    }
    return $merged
}

# "Uncommon" is derived, not a separately-stored field: an app with a
# Winget ID gets installed via the shared winget wrapper package, so it's
# "common"; an app with no Winget ID needs its own individually-packaged
# .intunewin, so it's "uncommon". One source of truth, everywhere - no
# checkbox to fall out of sync with the actual Winget ID field.
function Test-AppIsUncommon {
    param($App)
    return [string]::IsNullOrWhiteSpace($App.wingetId)
}

# Mirrors Get-SafeFileName inside the embedded package script exactly, so we
# can predict what filename 1_GenerateIntunePackage.ps1's logic gave an
# uncommon app's .intunewin without having to run/parse that script.
function Get-SafeFileNameForApp {
    param([string]$Name)
    $safeName = $Name -replace '[<>:"/\\|?*]', ''
    $safeName = $safeName -replace '\s+', ' '
    $safeName = $safeName -replace '\s', '-'
    $safeName = $safeName -replace '[.-]+', '-'
    $safeName = $safeName.Trim('-')
    if ([string]::IsNullOrWhiteSpace($safeName)) { $safeName = "App" }
    return $safeName
}

# Returns @{ Path = <string or $null>; Found = [bool] } - the predicted/found
# package path for an app, given its name and uncommon flag.
function Resolve-AppPackagePath {
    param([string]$AppName, [bool]$Uncommon)

    if (-not $Uncommon) {
        # Check the expected exact location first (fast - no need to walk the
        # whole repo in the common case where it's right where expected).
        $initPath = Join-Path $Script:RootPath "init\init.intunewin"
        if (Test-Path $initPath) { return @{ Path = $initPath; Found = $true } }

        # Not there - fall back to searching under the base path, same
        # approach as uncommon apps below, in case it ended up nested
        # slightly differently, before giving up.
        $found = Get-ChildItem -Path $Script:RootPath -Recurse -Filter "init.intunewin" -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { return @{ Path = $found.FullName; Found = $true } }

        return @{ Path = $initPath; Found = $false }
    }

    $safeName = Get-SafeFileNameForApp -Name $AppName
    $uncommonRoot = Join-Path $Script:RootPath "apps_uncommon"
    if (Test-Path $uncommonRoot) {
        $found = Get-ChildItem -Path $uncommonRoot -Recurse -Filter "$safeName.intunewin" -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { return @{ Path = $found.FullName; Found = $true } }
    }
    # Not found under the predicted name - still return the guess so the
    # dialog can show it (crossed out / flagged) alongside a Browse button.
    return @{ Path = (Join-Path $uncommonRoot "$safeName\$safeName.intunewin"); Found = $false }
}

# Iterative topological sort (Kahn's algorithm), not recursion - deliberately
# avoids any question about how a self-recursive nested function would
# behave, given a DIFFERENT kind of self-reference bug already surfaced once
# this session (a .GetNewClosure()-wrapped scriptblock capturing itself
# before its own assignment completed). A plain, flat loop over lists and
# hashtables sidesteps that class of question entirely. Verified separately
# against five cases (a chain, independent apps, a diamond, a genuine cycle,
# and a dependency pointing outside the batch) before being written here.
function Get-DependencyOrderedApps {
    param($Apps)

    $byName = @{}
    foreach ($a in $Apps) { $byName[$a.appName] = $a }
    $namesInBatch = $byName.Keys

    # Only dependencies that are THEMSELVES part of this batch are tracked -
    # a dependency that's already deployed (has its own App ID) or simply
    # wasn't selected for this run doesn't need to be waited on here; its
    # App ID gets resolved separately at actual create time regardless.
    $remainingDeps = @{}
    foreach ($a in $Apps) {
        $depsInBatch = New-Object System.Collections.Generic.List[string]
        foreach ($depName in @($a.metadata.dependencies)) {
            if ($namesInBatch -contains $depName) { $depsInBatch.Add($depName) }
        }
        $remainingDeps[$a.appName] = $depsInBatch
    }

    $ordered = New-Object System.Collections.Generic.List[object]
    $remainingNames = New-Object System.Collections.Generic.List[string]
    foreach ($a in $Apps) { $remainingNames.Add($a.appName) }

    while ($remainingNames.Count -gt 0) {
        $readyName = $null
        foreach ($name in $remainingNames) {
            if ($remainingDeps[$name].Count -eq 0) { $readyName = $name; break }
        }
        if (-not $readyName) {
            # Nothing left is ready - a circular dependency among whatever
            # remains. Added in their original order rather than failing
            # outright, so the caller can still show and warn about exactly
            # which apps are involved instead of aborting with nothing.
            foreach ($name in $remainingNames) { $ordered.Add($byName[$name]) }
            return [pscustomobject]@{ Ordered = $ordered.ToArray(); CircularNames = @($remainingNames) }
        }

        $ordered.Add($byName[$readyName])
        [void]$remainingNames.Remove($readyName)
        foreach ($name in $remainingNames) {
            [void]$remainingDeps[$name].Remove($readyName)
        }
    }

    return [pscustomobject]@{ Ordered = $ordered.ToArray(); CircularNames = @() }
}

# Default install/uninstall/detection templates. Only pre-filled for
# non-uncommon (winget) apps, where there's an actual established convention
# to draw from - uncommon apps get a generic Machine-scope command pattern for
# install/uninstall (matching what 1_GenerateIntunePackage.ps1's own printed
# deployment guide recommends) and no detection default, since that's
# genuinely per-app.
function Get-CreateAppTemplates {
    param([string]$WingetId, [bool]$Uncommon)

    if (-not $Uncommon -and $WingetId) {
        $install = "%SystemRoot%\sysnative\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -NoProfile -File `"C:\Program Files\Winget-AutoUpdate\Winget-Install.ps1`" -AppIDs `"$WingetId`""
        $uninstall = "%SystemRoot%\sysnative\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -NoProfile -File `"C:\Program Files\Winget-AutoUpdate\Winget-Install.ps1`" -AppIDs `"$WingetId`" -Uninstall"
        $detection = @"
`$AppToDetect = "$WingetId"

Function Get-WingetCmd {
    `$WingetCmd = `$null
    try {
        `$WingetInfo = (Get-Item "`$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_8wekyb3d8bbwe\winget.exe").VersionInfo | Sort-Object -Property FileVersionRaw
        `$WingetCmd = `$WingetInfo[-1].FileName
    }
    catch {
        if (Test-Path "`$env:LocalAppData\Microsoft\WindowsApps\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\winget.exe") {
            `$WingetCmd = "`$env:LocalAppData\Microsoft\WindowsApps\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\winget.exe"
        }
    }
    return `$WingetCmd
}

`$winget   = Get-WingetCmd
`$JsonFile = "`$env:TEMP\InstalledApps.json"
& `$Winget export -o `$JsonFile --accept-source-agreements | Out-Null
`$Json     = Get-Content `$JsonFile -Raw | ConvertFrom-Json
`$Packages = `$Json.Sources.Packages
Remove-Item `$JsonFile -Force
`$Apps = `$Packages | Where-Object { `$_.PackageIdentifier -eq `$AppToDetect }
if (`$Apps) { return "Installed!" }
"@
        return @{ Install = $install; Uninstall = $uninstall; Detection = $detection }
    }
    else {
        $install = "%SystemRoot%\sysnative\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -NoProfile -File install.ps1"
        $uninstall = "%SystemRoot%\sysnative\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -NoProfile -File uninstall.ps1"
        return @{ Install = $install; Uninstall = $uninstall; Detection = "" }
    }
}

# Computes the SAME default values Show-CreateInIntuneDialog's own form
# pre-fills for a brand-new (non-duplicate, non-Update) app, as one
# catalog-shaped metadata object - every default that function sets
# unconditionally (install/uninstall/detection templates, x64-only
# architecture, System context, newest Min OS, the standard 5 return
# codes, "basedOnReturnCode" restart behavior, 0 for every requirement,
# and defaulting to depend on "Winget AutoUpdate" when it exists) lives
# here exactly once, so Batch Deploy can use the identical defaults for
# an app that was never manually walked through "Save for later..."
# instead of just skipping it.
#
# Detection is the one field that can't always be defaulted: for an
# UNCOMMON app there's no real install to derive a detection script from
# (same reason the single-app dialog itself leaves it blank and requires
# something be typed in before Save/Create can proceed there too) -
# .detectionRule comes back $null in that case, and callers must check
# for that themselves before treating the result as actually deployable.
function Get-DefaultAppMetadata {
    param([string]$AppName, [string]$WingetId, [bool]$Uncommon)

    $templates = Get-CreateAppTemplates -WingetId $WingetId -Uncommon $Uncommon
    $defaultDeps = @()
    if ($AppName -ne "Winget AutoUpdate" -and ($Script:Apps | Where-Object { $_.appName -eq "Winget AutoUpdate" })) {
        $defaultDeps = @("Winget AutoUpdate")
    }

    return [pscustomobject]@{
        description      = $AppName
        publisher        = "ITSENSE"
        owner            = ""
        developer        = ""
        informationUrl   = ""
        privacyUrl       = ""
        notes            = ""
        installCommand   = $templates.Install
        uninstallCommand = $templates.Uninstall
        architecture     = "x64"
        installContext   = "System"
        minOSKey         = "v10_21H1"
        detectionRule    = if ($templates.Detection) { [pscustomobject]@{ Type = "Script"; Script_Content = $templates.Detection } } else { $null }
        dependencies     = $defaultDeps
        minDiskSpaceMB          = 0
        minMemoryMB             = 0
        minProcessors           = 0
        minCpuSpeedMHz          = 0
        installTimeMinutes      = 60
        deviceRestartBehavior   = "basedOnReturnCode"
        allowAvailableUninstall = $false
        returnCodes = @(
            [pscustomobject]@{ returnCode = 0; type = "success" }
            [pscustomobject]@{ returnCode = 1707; type = "success" }
            [pscustomobject]@{ returnCode = 3010; type = "softReboot" }
            [pscustomobject]@{ returnCode = 1641; type = "hardReboot" }
            [pscustomobject]@{ returnCode = 1618; type = "retry" }
        )
    }
}

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
function Show-MetadataDriftDialog {
    # -AppName is optional and purely cosmetic (title/header only) - lets a
    # caller reviewing MULTIPLE apps in a row (bulk "Sync metadata...")
    # make clear which app each popup is actually about, since several of
    # these can appear back to back in that flow.
    param($Rows, [string]$AppName = "")

    $dlg = New-Object System.Windows.Forms.Form
    $rowWord = if (@($Rows).Count -eq 1) { "field" } else { "fields" }
    $appSuffix = if ($AppName) { " - $AppName" } else { "" }
    $dlg.Text = "Local vs. Intune - $(@($Rows).Count) $rowWord differ$appSuffix"
    $dlg.ClientSize = New-Object System.Drawing.Size(800, 480)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "Sizable"
    $dlg.MinimumSize = New-Object System.Drawing.Size(600, 320)
    $dlg.MaximizeBox = $true
    $dlg.MinimizeBox = $false

    $lblHeader = New-Object System.Windows.Forms.Label
    $appPhrase = if ($AppName) { " for `"$AppName`"" } else { "" }
    $lblHeader.Text = "These fields$appPhrase differ between your local catalog copy and what's actually live in Intune. Intune's value wins by default for every row - untick a row below to keep your local value for that field instead."
    $lblHeader.Location = New-Object System.Drawing.Point(15,12)
    $lblHeader.Size = New-Object System.Drawing.Size(770,40)
    $dlg.Controls.Add($lblHeader)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(15,58)
    $grid.Size = New-Object System.Drawing.Size(770,362)
    $grid.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.RowHeadersVisible = $false
    $grid.SelectionMode = "FullRowSelect"
    $grid.AutoSizeRowsMode = [System.Windows.Forms.DataGridViewAutoSizeRowsMode]::AllCells
    $grid.ColumnHeadersHeightSizeMode = [System.Windows.Forms.DataGridViewColumnHeadersHeightSizeMode]::AutoSize

    $colUse = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $colUse.Name = "UseIntune"
    $colUse.HeaderText = "Use Intune's value"
    $colUse.Width = 110
    [void]$grid.Columns.Add($colUse)

    $colField = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colField.Name = "Field"
    $colField.HeaderText = "Field"
    $colField.ReadOnly = $true
    $colField.Width = 150
    [void]$grid.Columns.Add($colField)

    $colLocal = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colLocal.Name = "Local"
    $colLocal.HeaderText = "Local (catalog)"
    $colLocal.ReadOnly = $true
    $colLocal.Width = 250
    $colLocal.DefaultCellStyle.WrapMode = [System.Windows.Forms.DataGridViewTriState]::True
    [void]$grid.Columns.Add($colLocal)

    $colIntune = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colIntune.Name = "Intune"
    $colIntune.HeaderText = "Intune (live)"
    $colIntune.ReadOnly = $true
    $colIntune.Width = 250
    $colIntune.DefaultCellStyle.WrapMode = [System.Windows.Forms.DataGridViewTriState]::True
    [void]$grid.Columns.Add($colIntune)

    $dlg.Controls.Add($grid)

    foreach ($row in @($Rows)) {
        $rIdx = $grid.Rows.Add()
        $grid.Rows[$rIdx].Cells["UseIntune"].Value = $true
        $grid.Rows[$rIdx].Cells["Field"].Value = $row.Field
        $grid.Rows[$rIdx].Cells["Local"].Value = if ([string]::IsNullOrWhiteSpace($row.Local)) { "(blank)" } else { $row.Local }
        $grid.Rows[$rIdx].Cells["Intune"].Value = if ([string]::IsNullOrWhiteSpace($row.Intune)) { "(blank)" } else { $row.Intune }
    }

    $btnAllIntune = New-Object System.Windows.Forms.Button
    $btnAllIntune.Text = "Use Intune for all"
    $btnAllIntune.Location = New-Object System.Drawing.Point(15,428)
    $btnAllIntune.Size = New-Object System.Drawing.Size(140,28)
    $btnAllIntune.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
    $dlg.Controls.Add($btnAllIntune)

    $btnAllLocal = New-Object System.Windows.Forms.Button
    $btnAllLocal.Text = "Keep local for all"
    $btnAllLocal.Location = New-Object System.Drawing.Point(160,428)
    $btnAllLocal.Size = New-Object System.Drawing.Size(140,28)
    $btnAllLocal.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
    $dlg.Controls.Add($btnAllLocal)

    $btnAllIntune.Add_Click({
        $grid.EndEdit()
        foreach ($r in $grid.Rows) { $r.Cells["UseIntune"].Value = $true }
    }.GetNewClosure())
    $btnAllLocal.Add_Click({
        $grid.EndEdit()
        foreach ($r in $grid.Rows) { $r.Cells["UseIntune"].Value = $false }
    }.GetNewClosure())

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = "OK"
    $btnOk.Location = New-Object System.Drawing.Point(615,428)
    $btnOk.Size = New-Object System.Drawing.Size(80,28)
    $btnOk.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
    $dlg.Controls.Add($btnOk)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(705,428)
    $btnCancel.Size = New-Object System.Drawing.Size(80,28)
    $btnCancel.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
    $dlg.Controls.Add($btnCancel)

    # Plain local box (not $Script:-qualified) - see the same pattern/reasoning
    # in Show-SimpleListPicker.
    $resultBox = @{ Value = @() }
    $btnOk.Add_Click({
        $grid.EndEdit()
        $keepLocal = New-Object System.Collections.Generic.List[string]
        foreach ($r in $grid.Rows) {
            if (-not [bool]$r.Cells["UseIntune"].Value) { $keepLocal.Add([string]$r.Cells["Field"].Value) }
        }
        $resultBox.Value = @($keepLocal)
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dlg.Close()
    }.GetNewClosure())
    $btnCancel.Add_Click({
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $dlg.Close()
    }.GetNewClosure())

    $dlg.AcceptButton = $btnOk
    $dlg.CancelButton = $btnCancel
    Set-Theme -Control $dlg

    $result = $dlg.ShowDialog($form)
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) { return $resultBox.Value }
    return @()
}

# ---------------------------------------------------------------
# Create in Intune dialog
# ---------------------------------------------------------------
# Builds a new Win32 app in Intune (or updates an existing one's metadata) from
# a catalog entry. Returns the resulting App ID string on success, or $null if
# cancelled/failed - the caller (Show-AppEditor) is responsible for putting
# that into its own App ID field and saving, same as the "Look up" button.
function Show-CreateInIntuneDialog {
    param([string]$AppName, [string]$WingetId, [string]$ExistingAppId, [switch]$FromAppEditor)

    # Derived, not passed in separately - see Test-AppIsUncommon. Keeps this
    # dialog's notion of "uncommon" in sync with the same single source of
    # truth the rest of the app uses, rather than a second copy that could
    # drift from it.
    $Uncommon = [string]::IsNullOrWhiteSpace($WingetId)

    # Plain local aliases - see note in Start-IntuneAppLookup. Everything the
    # nested -OnComplete closure inside btnCreate's handler touches must be a
    # freshly-assigned plain variable, not a $Script:-qualified read or a
    # variable this function itself only inherited from an outer closure.
    $rootPath      = $Script:RootPath
    $tenantId      = $Script:GraphTenantId
    $clientId      = $Script:GraphClientId
    $certThumb     = $Script:GraphCertificateThumbprint
    $createScript  = $Script:EmbeddedCreateAppScript
    $appsRef       = $Script:Apps
    $unsavedBox    = $Script:UnsavedChangesBox
    $linkedFilePath = $Script:LinkedFilePath

    # A mutable container, not a plain variable - needs to be WRITTEN from
    # inside the auto-fetch's nested -OnComplete closure further down (a
    # two-level closure, which can only safely mutate a reference type's
    # contents, not reassign a plain outer variable), then READ later from
    # "Save local copy..."'s own, separate button handler - a real gap this
    # was built to fix: that handler used to hardcode dependencies as
    # always empty for every existing app, regardless of what Intune
    # actually had. Declared HERE, at the very top of the function, before
    # ANY button or closure gets built - the "Save local copy..." button's
    # own .GetNewClosure() runs earlier in this function's execution than
    # where this was originally declared, and .GetNewClosure() captures
    # variables BY VALUE at the moment it's called, not as a live reference
    # to something declared afterward. Declaring this after that closure
    # was already built would have meant it captured $null, not this
    # container - the exact same class of bug as the self-referencing
    # $RunDelete closure fixed earlier this session, caught here before
    # shipping by explicitly checking declaration order rather than
    # assuming it was fine.
    $fetchedDependencyBox = @{ Names = @() }

    $isDuplicate = [bool]$ExistingAppId

    # Single source of truth for every default value this form pre-fills
    # for a brand-new app - Batch Deploy's own Get-DefaultAppMetadata
    # computes the exact same defaults for an app that has no saved
    # metadata, so both places read from one function instead of
    # maintaining two separately-hardcoded copies of "what a new app
    # defaults to" that could silently drift apart. Computed unconditionally
    # (not just when -not $isDuplicate) - several of these fields (requirements,
    # return codes, restart behavior) are set as a sensible placeholder even
    # in Update mode, later overwritten by the live Intune fetch below if
    # that succeeds; same reasoning the original hardcoded values already
    # followed.
    $defaults = Get-DefaultAppMetadata -AppName $AppName -WingetId $WingetId -Uncommon $Uncommon

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Deploy to Intune - $AppName"
    $dlg.ClientSize = New-Object System.Drawing.Size(645, 990)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    # This dialog has grown past what fits on a typical screen - everything
    # from here down to the Dependencies checklist lives inside a scrollable
    # panel with a fixed visible height, instead of the dialog itself just
    # being 1230px tall. Status/log/buttons stay pinned below it, outside
    # the scroll area, so they're always reachable without scrolling down to
    # find them.
    $scrollPanel = New-Object System.Windows.Forms.Panel
    $scrollPanel.Location = New-Object System.Drawing.Point(0,0)
    $scrollPanel.Size = New-Object System.Drawing.Size(645,560)
    $scrollPanel.AutoScroll = $true
    $dlg.Controls.Add($scrollPanel)

    if ($isDuplicate) {
        $lblDup = New-Object System.Windows.Forms.Label
        $lblDup.Text = "This app already has an App ID ($ExistingAppId). By default this will UPDATE that app's metadata (name/description/install/uninstall/detection/dependencies) - it will NOT touch or re-upload package content."
        $lblDup.Location = New-Object System.Drawing.Point(15,12)
        $lblDup.Size = New-Object System.Drawing.Size(590,44)
        $lblDup.ForeColor = [System.Drawing.Color]::DarkOrange
        $scrollPanel.Controls.Add($lblDup)

        $chkForceNew = New-Object System.Windows.Forms.CheckBox
        $chkForceNew.Text = "Create a brand new app instead (uploads package content, leaves the existing app untouched)"
        $chkForceNew.Location = New-Object System.Drawing.Point(15,58)
        $chkForceNew.Size = New-Object System.Drawing.Size(590,20)
        $scrollPanel.Controls.Add($chkForceNew)

        $chkReplaceContent = New-Object System.Windows.Forms.CheckBox
        $chkReplaceContent.Text = "Also replace package content on the existing app (uses the Package field below)"
        $chkReplaceContent.Location = New-Object System.Drawing.Point(15,80)
        $chkReplaceContent.Size = New-Object System.Drawing.Size(590,20)
        $scrollPanel.Controls.Add($chkReplaceContent)
    }

    $lblName = New-Object System.Windows.Forms.Label
    $lblName.Text = "Name"
    $lblName.Location = New-Object System.Drawing.Point(15,109)
    $lblName.AutoSize = $true
    $scrollPanel.Controls.Add($lblName)

    $txtCreateName = New-Object System.Windows.Forms.TextBox
    $txtCreateName.Location = New-Object System.Drawing.Point(15,128)
    $txtCreateName.Size = New-Object System.Drawing.Size(590,24)
    $txtCreateName.Text = $AppName
    $scrollPanel.Controls.Add($txtCreateName)

    $lblDesc = New-Object System.Windows.Forms.Label
    $lblDesc.Text = "Description"
    $lblDesc.Location = New-Object System.Drawing.Point(15,160)
    $lblDesc.AutoSize = $true
    $scrollPanel.Controls.Add($lblDesc)

    $txtDesc = New-Object System.Windows.Forms.TextBox
    $txtDesc.Location = New-Object System.Drawing.Point(15,179)
    $txtDesc.Size = New-Object System.Drawing.Size(590,24)
    if (-not $isDuplicate) { $txtDesc.Text = $AppName }
    $scrollPanel.Controls.Add($txtDesc)

    $lblPublisher = New-Object System.Windows.Forms.Label
    $lblPublisher.Text = "Publisher"
    $lblPublisher.Location = New-Object System.Drawing.Point(15,211)
    $lblPublisher.AutoSize = $true
    $scrollPanel.Controls.Add($lblPublisher)

    $txtPublisher = New-Object System.Windows.Forms.TextBox
    $txtPublisher.Location = New-Object System.Drawing.Point(15,230)
    $txtPublisher.Size = New-Object System.Drawing.Size(590,24)
    if (-not $isDuplicate) { $txtPublisher.Text = $defaults.publisher }
    $scrollPanel.Controls.Add($txtPublisher)

    # Optional, purely descriptive fields - not tied to install mechanics, so
    # (unlike install context/architecture/min OS) these are freely editable
    # at any time, in both Create and Update mode. In Update mode these start
    # blank and then get repopulated with what's actually live in Intune once
    # Start-AppMetadataFetch comes back (see the dialog's Add_Shown handler
    # below) - if that fetch fails, they stay blank, and the embedded script
    # only includes a field in the request if you've actually typed
    # something, so a blank field here still never overwrites an existing
    # value with nothing even when the fetch didn't succeed.
    $lblOwner = New-Object System.Windows.Forms.Label
    $lblOwner.Text = "Owner (optional)"
    $lblOwner.Location = New-Object System.Drawing.Point(15,262)
    $lblOwner.AutoSize = $true
    $scrollPanel.Controls.Add($lblOwner)

    $txtOwner = New-Object System.Windows.Forms.TextBox
    $txtOwner.Location = New-Object System.Drawing.Point(15,281)
    $txtOwner.Size = New-Object System.Drawing.Size(280,24)
    $scrollPanel.Controls.Add($txtOwner)

    $lblDeveloper = New-Object System.Windows.Forms.Label
    $lblDeveloper.Text = "Developer (optional)"
    $lblDeveloper.Location = New-Object System.Drawing.Point(325,262)
    $lblDeveloper.AutoSize = $true
    $scrollPanel.Controls.Add($lblDeveloper)

    $txtDeveloper = New-Object System.Windows.Forms.TextBox
    $txtDeveloper.Location = New-Object System.Drawing.Point(325,281)
    $txtDeveloper.Size = New-Object System.Drawing.Size(280,24)
    $scrollPanel.Controls.Add($txtDeveloper)

    $lblInfoUrl = New-Object System.Windows.Forms.Label
    $lblInfoUrl.Text = "Information URL (optional)"
    $lblInfoUrl.Location = New-Object System.Drawing.Point(15,313)
    $lblInfoUrl.AutoSize = $true
    $scrollPanel.Controls.Add($lblInfoUrl)

    $txtInfoUrl = New-Object System.Windows.Forms.TextBox
    $txtInfoUrl.Location = New-Object System.Drawing.Point(15,332)
    $txtInfoUrl.Size = New-Object System.Drawing.Size(280,24)
    $scrollPanel.Controls.Add($txtInfoUrl)

    $lblPrivacyUrl = New-Object System.Windows.Forms.Label
    $lblPrivacyUrl.Text = "Privacy URL (optional)"
    $lblPrivacyUrl.Location = New-Object System.Drawing.Point(325,313)
    $lblPrivacyUrl.AutoSize = $true
    $scrollPanel.Controls.Add($lblPrivacyUrl)

    $txtPrivacyUrl = New-Object System.Windows.Forms.TextBox
    $txtPrivacyUrl.Location = New-Object System.Drawing.Point(325,332)
    $txtPrivacyUrl.Size = New-Object System.Drawing.Size(280,24)
    $scrollPanel.Controls.Add($txtPrivacyUrl)

    $lblNotes = New-Object System.Windows.Forms.Label
    $lblNotes.Text = "Notes (optional)"
    $lblNotes.Location = New-Object System.Drawing.Point(15,364)
    $lblNotes.AutoSize = $true
    $scrollPanel.Controls.Add($lblNotes)

    $txtNotes = New-Object System.Windows.Forms.TextBox
    $txtNotes.Location = New-Object System.Drawing.Point(15,383)
    $txtNotes.Size = New-Object System.Drawing.Size(590,40)
    $txtNotes.Multiline = $true
    $scrollPanel.Controls.Add($txtNotes)

    $lblPackage = New-Object System.Windows.Forms.Label
    $lblPackage.Text = "Package (.intunewin) - used when creating a new app, or when replacing content on an existing one"
    $lblPackage.Location = New-Object System.Drawing.Point(15,433)
    $lblPackage.AutoSize = $true
    $scrollPanel.Controls.Add($lblPackage)

    $txtPackagePath = New-Object System.Windows.Forms.TextBox
    $txtPackagePath.Location = New-Object System.Drawing.Point(15,452)
    $txtPackagePath.Size = New-Object System.Drawing.Size(495,24)
    $scrollPanel.Controls.Add($txtPackagePath)

    $btnBrowsePackage = New-Object System.Windows.Forms.Button
    $btnBrowsePackage.Text = "Browse..."
    $btnBrowsePackage.Location = New-Object System.Drawing.Point(515,451)
    $btnBrowsePackage.Size = New-Object System.Drawing.Size(90,26)
    $scrollPanel.Controls.Add($btnBrowsePackage)

    $resolved = Resolve-AppPackagePath -AppName $AppName -Uncommon $Uncommon
    $txtPackagePath.Text = $resolved.Path
    $txtPackagePath.ForeColor = if ($resolved.Found) { [System.Drawing.Color]::Black } else { [System.Drawing.Color]::Firebrick }

    $btnBrowsePackage.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = "Intune package (*.intunewin)|*.intunewin|All files (*.*)|*.*"
        $ofd.InitialDirectory = $rootPath
        if ($ofd.ShowDialog($dlg) -eq [System.Windows.Forms.DialogResult]::OK) {
            $txtPackagePath.Text = $ofd.FileName
            $txtPackagePath.ForeColor = [System.Drawing.Color]::Black
        }
    }.GetNewClosure())

    $lblInstall = New-Object System.Windows.Forms.Label
    $lblInstall.Text = "Install command"
    $lblInstall.Location = New-Object System.Drawing.Point(15,485)
    $lblInstall.AutoSize = $true
    $scrollPanel.Controls.Add($lblInstall)

    $txtInstall = New-Object System.Windows.Forms.TextBox
    $txtInstall.Location = New-Object System.Drawing.Point(15,504)
    $txtInstall.Size = New-Object System.Drawing.Size(590,46)
    $txtInstall.Multiline = $true
    $txtInstall.ScrollBars = "Vertical"
    $scrollPanel.Controls.Add($txtInstall)

    $lblUninstall = New-Object System.Windows.Forms.Label
    $lblUninstall.Text = "Uninstall command"
    $lblUninstall.Location = New-Object System.Drawing.Point(15,555)
    $lblUninstall.AutoSize = $true
    $scrollPanel.Controls.Add($lblUninstall)

    $txtUninstall = New-Object System.Windows.Forms.TextBox
    $txtUninstall.Location = New-Object System.Drawing.Point(15,574)
    $txtUninstall.Size = New-Object System.Drawing.Size(590,46)
    $txtUninstall.Multiline = $true
    $txtUninstall.ScrollBars = "Vertical"
    $scrollPanel.Controls.Add($txtUninstall)

    $lblDetection = New-Object System.Windows.Forms.Label
    $lblDetection.Text = "Detection method"
    $lblDetection.Location = New-Object System.Drawing.Point(15,568)
    $lblDetection.AutoSize = $true
    $dlg.Controls.Add($lblDetection)

    $cmbDetectionType = New-Object System.Windows.Forms.ComboBox
    $cmbDetectionType.Location = New-Object System.Drawing.Point(15,587)
    $cmbDetectionType.Size = New-Object System.Drawing.Size(260,24)
    $cmbDetectionType.DropDownStyle = "DropDownList"
    [void]$cmbDetectionType.Items.AddRange(@("PowerShell script","MSI product code","File or folder","Registry"))
    $cmbDetectionType.SelectedIndex = 0
    $dlg.Controls.Add($cmbDetectionType)

    # Shared by MSI/File/Registry's version/value comparison dropdowns -
    # confirmed against Microsoft's documented win32LobAppDetectionOperator
    # values, same list for all three detection types.
    $operatorMap = [ordered]@{
        "(any / not configured)"   = "notConfigured"
        "Equal to"                 = "equal"
        "Not equal to"             = "notEqual"
        "Greater than"             = "greaterThan"
        "Greater than or equal to" = "greaterThanOrEqual"
        "Less than"                = "lessThan"
        "Less than or equal to"    = "lessThanOrEqual"
    }

    $detPanelY = 615
    $detPanelH = 150

    # --- PowerShell script panel (default, matches previous behavior) ---
    $pnlDetScript = New-Object System.Windows.Forms.Panel
    $pnlDetScript.Location = New-Object System.Drawing.Point(15,$detPanelY)
    $pnlDetScript.Size = New-Object System.Drawing.Size(590,$detPanelH)
    $dlg.Controls.Add($pnlDetScript)

    $txtDetection = New-Object System.Windows.Forms.TextBox
    $txtDetection.Location = New-Object System.Drawing.Point(0,0)
    $txtDetection.Size = New-Object System.Drawing.Size(590,$detPanelH)
    $txtDetection.Multiline = $true
    $txtDetection.ScrollBars = "Vertical"
    $txtDetection.Font = New-Object System.Drawing.Font("Consolas", 8.5)
    $pnlDetScript.Controls.Add($txtDetection)

    # --- MSI product code panel ---
    $pnlDetMsi = New-Object System.Windows.Forms.Panel
    $pnlDetMsi.Location = New-Object System.Drawing.Point(15,$detPanelY)
    $pnlDetMsi.Size = New-Object System.Drawing.Size(590,$detPanelH)
    $dlg.Controls.Add($pnlDetMsi)

    $lblMsiCode = New-Object System.Windows.Forms.Label
    $lblMsiCode.Text = "MSI product code (GUID)"
    $lblMsiCode.Location = New-Object System.Drawing.Point(0,0)
    $lblMsiCode.AutoSize = $true
    $pnlDetMsi.Controls.Add($lblMsiCode)

    $txtMsiCode = New-Object System.Windows.Forms.TextBox
    $txtMsiCode.Location = New-Object System.Drawing.Point(0,19)
    $txtMsiCode.Size = New-Object System.Drawing.Size(590,24)
    $pnlDetMsi.Controls.Add($txtMsiCode)

    $lblMsiVer = New-Object System.Windows.Forms.Label
    $lblMsiVer.Text = "Version check (optional - leave as 'any' to skip)"
    $lblMsiVer.Location = New-Object System.Drawing.Point(0,51)
    $lblMsiVer.AutoSize = $true
    $pnlDetMsi.Controls.Add($lblMsiVer)

    $cmbMsiOperator = New-Object System.Windows.Forms.ComboBox
    $cmbMsiOperator.Location = New-Object System.Drawing.Point(0,70)
    $cmbMsiOperator.Size = New-Object System.Drawing.Size(280,24)
    $cmbMsiOperator.DropDownStyle = "DropDownList"
    [void]$cmbMsiOperator.Items.AddRange(@($operatorMap.Keys))
    $cmbMsiOperator.SelectedIndex = 0
    $pnlDetMsi.Controls.Add($cmbMsiOperator)

    $txtMsiVersion = New-Object System.Windows.Forms.TextBox
    $txtMsiVersion.Location = New-Object System.Drawing.Point(300,70)
    $txtMsiVersion.Size = New-Object System.Drawing.Size(290,24)
    $pnlDetMsi.Controls.Add($txtMsiVersion)

    # --- File or folder panel ---
    $pnlDetFile = New-Object System.Windows.Forms.Panel
    $pnlDetFile.Location = New-Object System.Drawing.Point(15,$detPanelY)
    $pnlDetFile.Size = New-Object System.Drawing.Size(590,$detPanelH)
    $dlg.Controls.Add($pnlDetFile)

    $lblFilePath = New-Object System.Windows.Forms.Label
    $lblFilePath.Text = "Folder path"
    $lblFilePath.Location = New-Object System.Drawing.Point(0,0)
    $lblFilePath.AutoSize = $true
    $pnlDetFile.Controls.Add($lblFilePath)

    $txtFilePath = New-Object System.Windows.Forms.TextBox
    $txtFilePath.Location = New-Object System.Drawing.Point(0,19)
    $txtFilePath.Size = New-Object System.Drawing.Size(430,24)
    $pnlDetFile.Controls.Add($txtFilePath)

    $chkFileCheck32 = New-Object System.Windows.Forms.CheckBox
    $chkFileCheck32.Text = "32-bit on 64-bit"
    $chkFileCheck32.Location = New-Object System.Drawing.Point(440,21)
    $chkFileCheck32.Size = New-Object System.Drawing.Size(150,22)
    $pnlDetFile.Controls.Add($chkFileCheck32)

    $lblFileName = New-Object System.Windows.Forms.Label
    $lblFileName.Text = "File or folder name"
    $lblFileName.Location = New-Object System.Drawing.Point(0,51)
    $lblFileName.AutoSize = $true
    $pnlDetFile.Controls.Add($lblFileName)

    $txtFileName = New-Object System.Windows.Forms.TextBox
    $txtFileName.Location = New-Object System.Drawing.Point(0,70)
    $txtFileName.Size = New-Object System.Drawing.Size(590,24)
    $pnlDetFile.Controls.Add($txtFileName)

    $lblFileDetType = New-Object System.Windows.Forms.Label
    $lblFileDetType.Text = "Detection type"
    $lblFileDetType.Location = New-Object System.Drawing.Point(0,102)
    $lblFileDetType.AutoSize = $true
    $pnlDetFile.Controls.Add($lblFileDetType)

    $lblFileOp = New-Object System.Windows.Forms.Label
    $lblFileOp.Text = "Operator (if comparing)"
    $lblFileOp.Location = New-Object System.Drawing.Point(200,102)
    $lblFileOp.AutoSize = $true
    $pnlDetFile.Controls.Add($lblFileOp)

    $lblFileVal = New-Object System.Windows.Forms.Label
    $lblFileVal.Text = "Value (if comparing)"
    $lblFileVal.Location = New-Object System.Drawing.Point(400,102)
    $lblFileVal.AutoSize = $true
    $pnlDetFile.Controls.Add($lblFileVal)

    $fileDetTypeMap = [ordered]@{
        "Exists"           = "exists"
        "Does not exist"   = "doesNotExist"
        "Modified date"    = "modifiedDate"
        "Created date"     = "createdDate"
        "Version"          = "version"
        "Size (MB)"        = "sizeInMB"
    }
    $cmbFileDetType = New-Object System.Windows.Forms.ComboBox
    $cmbFileDetType.Location = New-Object System.Drawing.Point(0,121)
    $cmbFileDetType.Size = New-Object System.Drawing.Size(190,24)
    $cmbFileDetType.DropDownStyle = "DropDownList"
    [void]$cmbFileDetType.Items.AddRange(@($fileDetTypeMap.Keys))
    $cmbFileDetType.SelectedIndex = 0
    $pnlDetFile.Controls.Add($cmbFileDetType)

    $cmbFileOperator = New-Object System.Windows.Forms.ComboBox
    $cmbFileOperator.Location = New-Object System.Drawing.Point(200,121)
    $cmbFileOperator.Size = New-Object System.Drawing.Size(190,24)
    $cmbFileOperator.DropDownStyle = "DropDownList"
    [void]$cmbFileOperator.Items.AddRange(@($operatorMap.Keys))
    $cmbFileOperator.SelectedIndex = 0
    $pnlDetFile.Controls.Add($cmbFileOperator)

    $txtFileDetValue = New-Object System.Windows.Forms.TextBox
    $txtFileDetValue.Location = New-Object System.Drawing.Point(400,121)
    $txtFileDetValue.Size = New-Object System.Drawing.Size(190,24)
    $pnlDetFile.Controls.Add($txtFileDetValue)

    # --- Registry panel ---
    $pnlDetReg = New-Object System.Windows.Forms.Panel
    $pnlDetReg.Location = New-Object System.Drawing.Point(15,$detPanelY)
    $pnlDetReg.Size = New-Object System.Drawing.Size(590,$detPanelH)
    $dlg.Controls.Add($pnlDetReg)

    $lblRegPath = New-Object System.Windows.Forms.Label
    $lblRegPath.Text = "Registry key path (e.g. HKEY_LOCAL_MACHINE\SOFTWARE\...)"
    $lblRegPath.Location = New-Object System.Drawing.Point(0,0)
    $lblRegPath.AutoSize = $true
    $pnlDetReg.Controls.Add($lblRegPath)

    $txtRegKeyPath = New-Object System.Windows.Forms.TextBox
    $txtRegKeyPath.Location = New-Object System.Drawing.Point(0,19)
    $txtRegKeyPath.Size = New-Object System.Drawing.Size(430,24)
    $pnlDetReg.Controls.Add($txtRegKeyPath)

    $chkRegCheck32 = New-Object System.Windows.Forms.CheckBox
    $chkRegCheck32.Text = "32-bit on 64-bit"
    $chkRegCheck32.Location = New-Object System.Drawing.Point(440,21)
    $chkRegCheck32.Size = New-Object System.Drawing.Size(150,22)
    $pnlDetReg.Controls.Add($chkRegCheck32)

    $lblRegValueName = New-Object System.Windows.Forms.Label
    $lblRegValueName.Text = "Value name (optional - blank checks the key itself)"
    $lblRegValueName.Location = New-Object System.Drawing.Point(0,51)
    $lblRegValueName.AutoSize = $true
    $pnlDetReg.Controls.Add($lblRegValueName)

    $txtRegValueName = New-Object System.Windows.Forms.TextBox
    $txtRegValueName.Location = New-Object System.Drawing.Point(0,70)
    $txtRegValueName.Size = New-Object System.Drawing.Size(590,24)
    $pnlDetReg.Controls.Add($txtRegValueName)

    $lblRegDetType = New-Object System.Windows.Forms.Label
    $lblRegDetType.Text = "Detection type"
    $lblRegDetType.Location = New-Object System.Drawing.Point(0,102)
    $lblRegDetType.AutoSize = $true
    $pnlDetReg.Controls.Add($lblRegDetType)

    $lblRegOp = New-Object System.Windows.Forms.Label
    $lblRegOp.Text = "Operator (if comparing)"
    $lblRegOp.Location = New-Object System.Drawing.Point(200,102)
    $lblRegOp.AutoSize = $true
    $pnlDetReg.Controls.Add($lblRegOp)

    $lblRegVal = New-Object System.Windows.Forms.Label
    $lblRegVal.Text = "Value (if comparing)"
    $lblRegVal.Location = New-Object System.Drawing.Point(400,102)
    $lblRegVal.AutoSize = $true
    $pnlDetReg.Controls.Add($lblRegVal)

    $regDetTypeMap = [ordered]@{
        "Exists"          = "exists"
        "Does not exist"  = "doesNotExist"
        "String"          = "string"
        "Integer"         = "integer"
        "Version"         = "version"
    }
    $cmbRegDetType = New-Object System.Windows.Forms.ComboBox
    $cmbRegDetType.Location = New-Object System.Drawing.Point(0,121)
    $cmbRegDetType.Size = New-Object System.Drawing.Size(190,24)
    $cmbRegDetType.DropDownStyle = "DropDownList"
    [void]$cmbRegDetType.Items.AddRange(@($regDetTypeMap.Keys))
    $cmbRegDetType.SelectedIndex = 0
    $pnlDetReg.Controls.Add($cmbRegDetType)

    $cmbRegOperator = New-Object System.Windows.Forms.ComboBox
    $cmbRegOperator.Location = New-Object System.Drawing.Point(200,121)
    $cmbRegOperator.Size = New-Object System.Drawing.Size(190,24)
    $cmbRegOperator.DropDownStyle = "DropDownList"
    [void]$cmbRegOperator.Items.AddRange(@($operatorMap.Keys))
    $cmbRegOperator.SelectedIndex = 0
    $pnlDetReg.Controls.Add($cmbRegOperator)

    $txtRegDetValue = New-Object System.Windows.Forms.TextBox
    $txtRegDetValue.Location = New-Object System.Drawing.Point(400,121)
    $txtRegDetValue.Size = New-Object System.Drawing.Size(190,24)
    $pnlDetReg.Controls.Add($txtRegDetValue)

    # Toggling .Visible on siblings stacked at identical coordinates inside
    # an AutoScroll panel doesn't reliably repaint in WinForms (confirmed by
    # testing - the panel toggled but rendered blank). Physically adding and
    # removing the panel from the Controls collection instead always forces
    # a full, correct layout+paint cycle, since that's ordinary control
    # attachment rather than relying on invalidation of an already-attached,
    # merely-hidden sibling.
    $detPanels = @($pnlDetScript, $pnlDetMsi, $pnlDetFile, $pnlDetReg)
    foreach ($p in $detPanels) { $dlg.Controls.Remove($p) }
    $UpdateDetPanel = {
        $sel = $cmbDetectionType.SelectedIndex
        foreach ($p in $detPanels) { $dlg.Controls.Remove($p) }
        if ($sel -ge 0 -and $sel -lt $detPanels.Count) {
            $dlg.Controls.Add($detPanels[$sel])
        }
    }.GetNewClosure()
    $cmbDetectionType.Add_SelectedIndexChanged({ & $UpdateDetPanel }.GetNewClosure())
    & $UpdateDetPanel

    if (-not $isDuplicate) {
        $txtInstall.Text = $defaults.installCommand
        $txtUninstall.Text = $defaults.uninstallCommand
        # .detectionRule is $null for an uncommon app (see
        # Get-DefaultAppMetadata) - there's genuinely no default to give it,
        # so $txtDetection is deliberately left however it already started
        # (blank) rather than risk assigning a WinForms TextBox.Text a $null
        # value, which throws.
        if ($defaults.detectionRule) { $txtDetection.Text = $defaults.detectionRule.Script_Content }
    }

    # --- Context / Architecture / Min OS, one row ---
    $lblContext = New-Object System.Windows.Forms.Label
    $lblContext.Text = if ($isDuplicate) { "Install context (locked - set at creation only)" } else { "Install context" }
    $lblContext.Location = New-Object System.Drawing.Point(15,631)
    $lblContext.AutoSize = $true
    $scrollPanel.Controls.Add($lblContext)

    $cmbContext = New-Object System.Windows.Forms.ComboBox
    $cmbContext.Location = New-Object System.Drawing.Point(15,650)
    $cmbContext.Size = New-Object System.Drawing.Size(180,24)
    $cmbContext.DropDownStyle = "DropDownList"
    [void]$cmbContext.Items.AddRange(@("System","User"))
    if (-not $isDuplicate) { $cmbContext.SelectedItem = $defaults.installContext }
    $scrollPanel.Controls.Add($cmbContext)

    $lblArch = New-Object System.Windows.Forms.Label
    $lblArch.Text = "Applicable architectures"
    $lblArch.Location = New-Object System.Drawing.Point(205,631)
    $lblArch.AutoSize = $true
    $scrollPanel.Controls.Add($lblArch)

    $chkArchX86 = New-Object System.Windows.Forms.CheckBox
    $chkArchX86.Text = "x86"
    $chkArchX86.Location = New-Object System.Drawing.Point(205,651)
    $chkArchX86.Size = New-Object System.Drawing.Size(48,22)
    $scrollPanel.Controls.Add($chkArchX86)

    $chkArchX64 = New-Object System.Windows.Forms.CheckBox
    $chkArchX64.Text = "x64"
    $chkArchX64.Location = New-Object System.Drawing.Point(261,651)
    $chkArchX64.Size = New-Object System.Drawing.Size(48,22)
    $scrollPanel.Controls.Add($chkArchX64)

    $chkArchArm64 = New-Object System.Windows.Forms.CheckBox
    $chkArchArm64.Text = "ARM64"
    $chkArchArm64.Location = New-Object System.Drawing.Point(317,651)
    $chkArchArm64.Size = New-Object System.Drawing.Size(65,22)
    $chkArchArm64.Checked = $false
    $scrollPanel.Controls.Add($chkArchArm64)

    # All three set together, from $defaults.architecture, now that all
    # three controls exist - same comma-split parsing already used
    # elsewhere in this function for the live-fetched value, applied here
    # to the DEFAULT value instead, so a future change to what
    # Get-DefaultAppMetadata defaults to (e.g. adding arm64) is reflected
    # here automatically instead of needing this checkbox logic updated
    # separately too.
    if (-not $isDuplicate -and $defaults.architecture) {
        $defaultArchList = @($defaults.architecture -split ',' | ForEach-Object { $_.Trim().ToLower() })
        $chkArchX86.Checked = $defaultArchList -contains "x86"
        $chkArchX64.Checked = $defaultArchList -contains "x64"
        $chkArchArm64.Checked = $defaultArchList -contains "arm64"
    }

    $lblMinOS = New-Object System.Windows.Forms.Label
    $lblMinOS.Text = "Minimum Windows"
    $lblMinOS.Location = New-Object System.Drawing.Point(415,631)
    $lblMinOS.AutoSize = $true
    $scrollPanel.Controls.Add($lblMinOS)

    $cmbMinOS = New-Object System.Windows.Forms.ComboBox
    $cmbMinOS.Location = New-Object System.Drawing.Point(415,650)
    $cmbMinOS.Size = New-Object System.Drawing.Size(190,24)
    $cmbMinOS.DropDownStyle = "DropDownList"
    # Confirmed against Microsoft's own documentation (learn.microsoft.com,
    # windowsMinimumOperatingSystem, beta) after v10_21H2 was rejected by
    # Graph with "the property does not exist on this type" - the beta
    # schema's property list genuinely stops at v10_21H1; there is no
    # v10_21H2 or v10_22H2 despite those being real Windows versions. Note
    # the 20H2 property is spelled "v10_2H20" (digits swapped) in Microsoft's
    # own docs, not "v10_20H2" - used exactly as documented since Graph
    # validates the literal property name server-side.
    $minOsMap = [ordered]@{
        "1607 or later (broadest)" = "v10_1607"
        "1809 or later"            = "v10_1809"
        "1909 or later"            = "v10_1909"
        "2004 or later"            = "v10_2004"
        "20H2 or later"            = "v10_2H20"
        "21H1 or later (newest available)" = "v10_21H1"
    }
    [void]$cmbMinOS.Items.AddRange(@($minOsMap.Keys))
    if (-not $isDuplicate -and $defaults.minOSKey) {
        $defaultMinOsLabel = $minOsMap.Keys | Where-Object { $minOsMap[$_] -eq $defaults.minOSKey } | Select-Object -First 1
        if ($defaultMinOsLabel) { $cmbMinOS.SelectedItem = $defaultMinOsLabel }
    }
    $scrollPanel.Controls.Add($cmbMinOS)

    # Only install context is actually excluded here - confirmed rejected
    # by Graph specifically ("The 'RunAsAccount' property cannot be
    # patched for the 'Win32LobApp' type."). Architecture and Min OS were
    # PREVIOUSLY also locked here too, based on an unverified assumption
    # they'd behave the same way - that assumption was wrong, confirmed
    # otherwise directly against Microsoft's own PATCH documentation
    # example, an official Microsoft sample script, and the Intune
    # portal's own editable "Requirements"/"Detection rules" sections on
    # an existing app.
    if ($isDuplicate) {
        $cmbContext.Enabled = $false
    }

    # A visual separator, not an actual collapsible section - this dialog's
    # fixed-coordinate layout would make a true collapse/expand risky (every
    # control below it would need dynamic repositioning). This still gives
    # new users a clear visual signal that everything below has sensible
    # defaults and rarely needs touching for a typical app, without the
    # complexity of actually hiding it.
    $lblAdvancedSeparator = New-Object System.Windows.Forms.Label
    $lblAdvancedSeparator.Text = "Advanced (usually fine to leave as-is)"
    $lblAdvancedSeparator.Location = New-Object System.Drawing.Point(15,665)
    $lblAdvancedSeparator.AutoSize = $true
    $lblAdvancedSeparator.ForeColor = [System.Drawing.Color]::Gray
    $lblAdvancedSeparator.Font = New-Object System.Drawing.Font($lblAdvancedSeparator.Font, [System.Drawing.FontStyle]::Italic)
    $scrollPanel.Controls.Add($lblAdvancedSeparator)

    # --- Dependencies ---
    $lblDeps = New-Object System.Windows.Forms.Label
    $lblDeps.Text = "Dependencies (undeployed apps shown too - resolved by name at actual deploy time)"
    $lblDeps.Location = New-Object System.Drawing.Point(15,685)
    $lblDeps.AutoSize = $true
    $scrollPanel.Controls.Add($lblDeps)

    $clbDeps = New-Object System.Windows.Forms.CheckedListBox
    $clbDeps.Location = New-Object System.Drawing.Point(15,704)
    $clbDeps.Size = New-Object System.Drawing.Size(590,85)
    $clbDeps.CheckOnClick = $true
    # Undeployed apps (no App ID yet) are now included, not just ones
    # already in Intune - Batch Deploy's own ordering logic already
    # resolves dependencies by NAME at actual deploy time specifically so
    # one undeployed app can depend on another undeployed one, but this
    # picker was still filtering those out, an artificial gap rather than
    # a real one. Immediate deploy (the Create/Update button) still needs
    # a REAL App ID right now, though - that path can't defer resolution
    # the way Batch Deploy can, so it validates and blocks separately,
    # below, rather than silently sending Graph something it can't use.
    $depCandidates = @($Script:Apps | Where-Object { $_.appName -ne $AppName })
    $depIdByLabel = @{}
    $depNameByLabel = @{}
    foreach ($d in ($depCandidates | Sort-Object appName)) {
        $label = if ($d.appId) { $d.appName } else { "$($d.appName)  [not deployed yet]" }
        $idx = $clbDeps.Items.Add($label)
        $depIdByLabel[$label] = $d.appId
        $depNameByLabel[$label] = $d.appName
        if ($d.appName -eq "Winget AutoUpdate") { $clbDeps.SetItemChecked($idx, $true) }
    }
    $scrollPanel.Controls.Add($clbDeps)

    # --- Requirements (0 = not required, matching the portal's own "No X
    # required" wording for an unset value) ---
    $lblReqs = New-Object System.Windows.Forms.Label
    $lblReqs.Text = "Requirements (0 = not required)"
    $lblReqs.Location = New-Object System.Drawing.Point(15,798)
    $lblReqs.AutoSize = $true
    $scrollPanel.Controls.Add($lblReqs)

    $lblDiskSpace = New-Object System.Windows.Forms.Label
    $lblDiskSpace.Text = "Disk space (MB)"
    $lblDiskSpace.Location = New-Object System.Drawing.Point(15,819)
    $lblDiskSpace.AutoSize = $true
    $scrollPanel.Controls.Add($lblDiskSpace)
    $txtDiskSpace = New-Object System.Windows.Forms.TextBox
    $txtDiskSpace.Location = New-Object System.Drawing.Point(15,836)
    $txtDiskSpace.Size = New-Object System.Drawing.Size(130,23)
    $txtDiskSpace.Text = [string]$defaults.minDiskSpaceMB
    $scrollPanel.Controls.Add($txtDiskSpace)

    $lblMemory = New-Object System.Windows.Forms.Label
    $lblMemory.Text = "Memory (MB)"
    $lblMemory.Location = New-Object System.Drawing.Point(160,819)
    $lblMemory.AutoSize = $true
    $scrollPanel.Controls.Add($lblMemory)
    $txtMemory = New-Object System.Windows.Forms.TextBox
    $txtMemory.Location = New-Object System.Drawing.Point(160,836)
    $txtMemory.Size = New-Object System.Drawing.Size(130,23)
    $txtMemory.Text = [string]$defaults.minMemoryMB
    $scrollPanel.Controls.Add($txtMemory)

    $lblProcessors = New-Object System.Windows.Forms.Label
    $lblProcessors.Text = "Min. processors"
    $lblProcessors.Location = New-Object System.Drawing.Point(305,819)
    $lblProcessors.AutoSize = $true
    $scrollPanel.Controls.Add($lblProcessors)
    $txtProcessors = New-Object System.Windows.Forms.TextBox
    $txtProcessors.Location = New-Object System.Drawing.Point(305,836)
    $txtProcessors.Size = New-Object System.Drawing.Size(130,23)
    $txtProcessors.Text = [string]$defaults.minProcessors
    $scrollPanel.Controls.Add($txtProcessors)

    $lblCpuSpeed = New-Object System.Windows.Forms.Label
    $lblCpuSpeed.Text = "Min. CPU speed (MHz)"
    $lblCpuSpeed.Location = New-Object System.Drawing.Point(450,819)
    $lblCpuSpeed.AutoSize = $true
    $scrollPanel.Controls.Add($lblCpuSpeed)
    $txtCpuSpeed = New-Object System.Windows.Forms.TextBox
    $txtCpuSpeed.Location = New-Object System.Drawing.Point(450,836)
    $txtCpuSpeed.Size = New-Object System.Drawing.Size(130,23)
    $txtCpuSpeed.Text = [string]$defaults.minCpuSpeedMHz
    $scrollPanel.Controls.Add($txtCpuSpeed)

    # --- Install experience extras ---
    $lblInstallTime = New-Object System.Windows.Forms.Label
    $lblInstallTime.Text = "Install time required (mins)"
    $lblInstallTime.Location = New-Object System.Drawing.Point(15,872)
    $lblInstallTime.AutoSize = $true
    $scrollPanel.Controls.Add($lblInstallTime)
    $txtInstallTime = New-Object System.Windows.Forms.TextBox
    $txtInstallTime.Location = New-Object System.Drawing.Point(15,889)
    $txtInstallTime.Size = New-Object System.Drawing.Size(130,23)
    $txtInstallTime.Text = [string]$defaults.installTimeMinutes
    $scrollPanel.Controls.Add($txtInstallTime)

    $lblRestartBehavior = New-Object System.Windows.Forms.Label
    $lblRestartBehavior.Text = "Device restart behavior"
    $lblRestartBehavior.Location = New-Object System.Drawing.Point(160,872)
    $lblRestartBehavior.AutoSize = $true
    $scrollPanel.Controls.Add($lblRestartBehavior)
    $cmbRestartBehavior = New-Object System.Windows.Forms.ComboBox
    $cmbRestartBehavior.Location = New-Object System.Drawing.Point(160,889)
    $cmbRestartBehavior.Size = New-Object System.Drawing.Size(230,23)
    $cmbRestartBehavior.DropDownStyle = "DropDownList"
    # Display labels map to the exact win32LobAppRestartBehavior enum
    # values confirmed against Microsoft's own resource docs.
    $restartBehaviorMap = [ordered]@{
        "No specific action" = "basedOnReturnCode"
        "Allow"              = "allow"
        "Suppress"           = "suppress"
        "Force"              = "force"
    }
    foreach ($k in $restartBehaviorMap.Keys) { [void]$cmbRestartBehavior.Items.Add($k) }
    $defaultRestartLabel = $restartBehaviorMap.Keys | Where-Object { $restartBehaviorMap[$_] -eq $defaults.deviceRestartBehavior } | Select-Object -First 1
    $cmbRestartBehavior.SelectedItem = if ($defaultRestartLabel) { $defaultRestartLabel } else { "No specific action" }
    $scrollPanel.Controls.Add($cmbRestartBehavior)

    $chkAllowUninstall = New-Object System.Windows.Forms.CheckBox
    $chkAllowUninstall.Text = "Allow available uninstall"
    $chkAllowUninstall.Location = New-Object System.Drawing.Point(405,891)
    $chkAllowUninstall.AutoSize = $true
    $chkAllowUninstall.Checked = [bool]$defaults.allowAvailableUninstall
    $scrollPanel.Controls.Add($chkAllowUninstall)

    # --- Return codes ---
    $lblReturnCodes = New-Object System.Windows.Forms.Label
    $lblReturnCodes.Text = "Return codes"
    $lblReturnCodes.Location = New-Object System.Drawing.Point(15,925)
    $lblReturnCodes.AutoSize = $true
    $scrollPanel.Controls.Add($lblReturnCodes)

    $grdReturnCodes = New-Object System.Windows.Forms.DataGridView
    $grdReturnCodes.Location = New-Object System.Drawing.Point(15,944)
    $grdReturnCodes.Size = New-Object System.Drawing.Size(460,110)
    $grdReturnCodes.AllowUserToAddRows = $false
    $grdReturnCodes.AllowUserToDeleteRows = $false
    $grdReturnCodes.RowHeadersVisible = $false
    $grdReturnCodes.SelectionMode = "FullRowSelect"
    $grdReturnCodes.MultiSelect = $false
    $colCode = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colCode.Name = "Code"; $colCode.HeaderText = "Return code"; $colCode.FillWeight = 40
    [void]$grdReturnCodes.Columns.Add($colCode)
    $colType = New-Object System.Windows.Forms.DataGridViewComboBoxColumn
    $colType.Name = "Type"; $colType.HeaderText = "Type"; $colType.FillWeight = 60
    # Exact win32LobAppReturnCode "type" enum values, confirmed against the
    # same docs as the rest of this section.
    [void]$colType.Items.AddRange(@("success", "softReboot", "hardReboot", "retry", "failed"))
    [void]$grdReturnCodes.Columns.Add($colType)
    $scrollPanel.Controls.Add($grdReturnCodes)

    $btnAddReturnCode = New-Object System.Windows.Forms.Button
    $btnAddReturnCode.Text = "Add row"
    $btnAddReturnCode.Location = New-Object System.Drawing.Point(485,944)
    $btnAddReturnCode.Size = New-Object System.Drawing.Size(120,26)
    $scrollPanel.Controls.Add($btnAddReturnCode)
    $btnAddReturnCode.Add_Click({
        $rowIdx = $grdReturnCodes.Rows.Add()
        $grdReturnCodes.Rows[$rowIdx].Cells["Type"].Value = "success"
    }.GetNewClosure())

    $btnRemoveReturnCode = New-Object System.Windows.Forms.Button
    $btnRemoveReturnCode.Text = "Remove row"
    $btnRemoveReturnCode.Location = New-Object System.Drawing.Point(485,974)
    $btnRemoveReturnCode.Size = New-Object System.Drawing.Size(120,26)
    $scrollPanel.Controls.Add($btnRemoveReturnCode)
    $btnRemoveReturnCode.Add_Click({
        if ($grdReturnCodes.CurrentRow) { $grdReturnCodes.Rows.RemoveAt($grdReturnCodes.CurrentRow.Index) }
    }.GetNewClosure())

    # Standard defaults - the same fixed set Get-DefaultAppMetadata also
    # uses for Batch Deploy, shown here as editable, pre-filled rows
    # instead of being invisible and fixed.
    foreach ($rc in @($defaults.returnCodes)) {
        $rowIdx = $grdReturnCodes.Rows.Add()
        $grdReturnCodes.Rows[$rowIdx].Cells["Code"].Value = [string]$rc.returnCode
        $grdReturnCodes.Rows[$rowIdx].Cells["Type"].Value = $rc.type
    }

    # Requirements, return codes, and install time/restart behavior/
    # allow-uninstall are NOT locked (unlike Install context above) -
    # confirmed patchable on an existing app, correcting an earlier,
    # unverified assumption that they'd behave the same way as
    # runAsAccount. See the note on Install context above for the
    # confirming evidence.

    $lblCreateStatus = New-Object System.Windows.Forms.Label
    $lblCreateStatus.Location = New-Object System.Drawing.Point(15,773)
    $lblCreateStatus.Size = New-Object System.Drawing.Size(615,40)
    $dlg.Controls.Add($lblCreateStatus)

    $rtbCreateLog = New-Object System.Windows.Forms.RichTextBox
    $rtbCreateLog.Location = New-Object System.Drawing.Point(15,821)
    $rtbCreateLog.Size = New-Object System.Drawing.Size(615,110)
    $rtbCreateLog.ReadOnly = $true
    $rtbCreateLog.BackColor = [System.Drawing.Color]::FromArgb(13,17,23)
    $rtbCreateLog.ForeColor = [System.Drawing.Color]::Gainsboro
    $rtbCreateLog.Font = New-Object System.Drawing.Font("Consolas", 8.5)
    $dlg.Controls.Add($rtbCreateLog)

    $btnCreate = New-Object System.Windows.Forms.Button
    $btnCreate.Text = if ($isDuplicate) { "Update Metadata" } else { "Create" }
    $btnCreate.Location = New-Object System.Drawing.Point(340,941)
    $btnCreate.Size = New-Object System.Drawing.Size(200,32)
    $dlg.Controls.Add($btnCreate)

    # For a new app, lets its metadata be captured and saved locally
    # without requiring the package to exist yet - so a batch of new apps
    # can be filled in ahead of time and deployed together later. For an
    # EXISTING app, saves whatever's currently displayed (typically the
    # live Intune values, just fetched below, or the user's own edits on
    # top of them) as a local copy - a way to keep a browsable, editable
    # record of an app's metadata without needing to push anything back to
    # Intune at all.
    $btnSaveForLater = New-Object System.Windows.Forms.Button
    $btnSaveForLater.Text = if ($isDuplicate) { "Save local copy..." } else { "Save for later..." }
    $btnSaveForLater.Location = New-Object System.Drawing.Point(150,941)
    $btnSaveForLater.Size = New-Object System.Drawing.Size(180,32)
    $dlg.Controls.Add($btnSaveForLater)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(550,941)
    $btnCancel.Size = New-Object System.Drawing.Size(80,32)
    $dlg.Controls.Add($btnCancel)

    if ($isDuplicate) {
        # Button label follows both checkboxes live. Force-new and
        # Replace-content are mutually exclusive - Create mode always
        # uploads content, so "also replace content" is meaningless once
        # Force-new is checked.
        $chkForceNew.Add_Click({
            if ($chkForceNew.Checked) {
                $chkReplaceContent.Checked = $false
                $chkReplaceContent.Enabled = $false
                # Creating a brand new app - install context is meaningful
                # again. Architecture/Min OS/Requirements/return codes/
                # install experience were never actually locked below
                # (confirmed patchable on an existing app), so there's
                # nothing else to re-enable here now.
                $cmbContext.Enabled = $true
            }
            else {
                $chkReplaceContent.Enabled = $true
                # Back to updating the existing app - install context is
                # the one field Graph genuinely won't let get changed
                # post-creation.
                $cmbContext.Enabled = $false
            }
            $btnCreate.Text = if ($chkForceNew.Checked) { "Create" } elseif ($chkReplaceContent.Checked) { "Update + Replace Content" } else { "Update Metadata" }
        }.GetNewClosure())
        $chkReplaceContent.Add_Click({
            $btnCreate.Text = if ($chkForceNew.Checked) { "Create" } elseif ($chkReplaceContent.Checked) { "Update + Replace Content" } else { "Update Metadata" }
        }.GetNewClosure())
    }

    # Metadata is $null unless -FromAppEditor deferred a local-catalog save
    # to the caller (see the Create/Update success handler and
    # $btnSaveForLater below) - the caller then folds it into its own save.
    $resultBox = @{ NewAppId = $null; NewAppName = $null; Metadata = $null }
    $procBox = @{ Proc = $null }   # lets btnCancel below terminate a still-running step

    $btnCreate.Add_Click({
        if (-not $txtCreateName.Text.Trim() -or -not $txtInstall.Text.Trim() -or -not $txtUninstall.Text.Trim() -or -not $txtDetection.Text.Trim()) {
            [System.Windows.Forms.MessageBox]::Show("Name, install command, uninstall command, and detection script are all required.", "Missing values", "OK", "Warning") | Out-Null
            return
        }

        $mode = if ($isDuplicate -and -not $chkForceNew.Checked) { "UpdateMetadata" } else { "Create" }
        $replaceContent = ($mode -eq "UpdateMetadata") -and $isDuplicate -and $chkReplaceContent.Checked

        if ($mode -eq "Create" -or $replaceContent) {
            if (-not (Test-Path $txtPackagePath.Text)) {
                [System.Windows.Forms.MessageBox]::Show("Package file not found:`n$($txtPackagePath.Text)`n`nUse Browse... to point at the correct .intunewin file.", "Package not found", "OK", "Warning") | Out-Null
                return
            }
        }

        $selectedDepIds = New-Object System.Collections.Generic.List[string]
        $undeployedDepNames = New-Object System.Collections.Generic.List[string]
        foreach ($checkedLabel in $clbDeps.CheckedItems) {
            $depId = $depIdByLabel[[string]$checkedLabel]
            if ($depId) {
                $selectedDepIds.Add($depId)
            }
            elseif ($depNameByLabel.ContainsKey([string]$checkedLabel)) {
                # This path (immediate Create/Update) can't defer
                # dependency resolution the way "Save for later..." or
                # Batch Deploy can - Graph needs a real App ID right now,
                # not a name to resolve later.
                $undeployedDepNames.Add($depNameByLabel[[string]$checkedLabel])
            }
        }
        if ($undeployedDepNames.Count -gt 0) {
            [System.Windows.Forms.MessageBox]::Show("These checked dependencies aren't deployed to Intune yet, so there's no App ID to set: $($undeployedDepNames -join ', ')`n`nDeploy them first, or use `"Save for later...`" instead and let Batch Deploy resolve dependencies once everything's created.", "Dependency not deployed yet", "OK", "Warning") | Out-Null
            return
        }

        $selectedArches = New-Object System.Collections.Generic.List[string]
        if ($chkArchX86.Checked)   { $selectedArches.Add("x86") }
        if ($chkArchX64.Checked)   { $selectedArches.Add("x64") }
        if ($chkArchArm64.Checked) { $selectedArches.Add("arm64") }
        if ($selectedArches.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Check at least one architecture.", "No architecture selected", "OK", "Warning") | Out-Null
            return
        }

        foreach ($urlCheck in @(@{ Label = "Information URL"; Text = $txtInfoUrl.Text.Trim() }, @{ Label = "Privacy URL"; Text = $txtPrivacyUrl.Text.Trim() })) {
            if (-not $urlCheck.Text) { continue }
            $parsedUri = $null
            $isValidUrl = [Uri]::TryCreate($urlCheck.Text, [UriKind]::Absolute, [ref]$parsedUri) -and ($parsedUri.Scheme -eq 'http' -or $parsedUri.Scheme -eq 'https')
            if (-not $isValidUrl) {
                [System.Windows.Forms.MessageBox]::Show("$($urlCheck.Label) doesn't look like a valid URL:`n`n$($urlCheck.Text)`n`nIt needs a scheme, e.g. https://example.com - or leave it blank.", "Invalid URL", "OK", "Warning") | Out-Null
                return
            }
        }

        $numericChecks = @(
            @{ Label = "Disk space (MB)"; Text = $txtDiskSpace.Text.Trim() }
            @{ Label = "Memory (MB)"; Text = $txtMemory.Text.Trim() }
            @{ Label = "Min. processors"; Text = $txtProcessors.Text.Trim() }
            @{ Label = "Min. CPU speed (MHz)"; Text = $txtCpuSpeed.Text.Trim() }
            @{ Label = "Install time required (mins)"; Text = $txtInstallTime.Text.Trim() }
        )
        foreach ($numCheck in $numericChecks) {
            $parsedNum = 0
            if (-not [int]::TryParse($numCheck.Text, [ref]$parsedNum) -or $parsedNum -lt 0) {
                [System.Windows.Forms.MessageBox]::Show("$($numCheck.Label) must be a whole number, 0 or greater.", "Invalid value", "OK", "Warning") | Out-Null
                return
            }
        }

        $returnCodesConfig = New-Object System.Collections.Generic.List[object]
        foreach ($rcRow in $grdReturnCodes.Rows) {
            if ($rcRow.IsNewRow) { continue }
            $codeText = [string]$rcRow.Cells["Code"].Value
            $typeText = [string]$rcRow.Cells["Type"].Value
            if (-not $codeText -and -not $typeText) { continue }
            $parsedCode = 0
            if (-not [int]::TryParse([string]$codeText.Trim(), [ref]$parsedCode)) {
                [System.Windows.Forms.MessageBox]::Show("Return code `"$codeText`" isn't a valid whole number.", "Invalid return code", "OK", "Warning") | Out-Null
                return
            }
            if (-not $typeText) {
                [System.Windows.Forms.MessageBox]::Show("Return code $parsedCode needs a type selected.", "Missing return code type", "OK", "Warning") | Out-Null
                return
            }
            $returnCodesConfig.Add([pscustomobject]@{ returnCode = $parsedCode; type = $typeText })
        }
        if ($returnCodesConfig.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("At least one return code is required.", "No return codes", "OK", "Warning") | Out-Null
            return
        }

        switch ($cmbDetectionType.SelectedIndex) {
            0 {
                if (-not $txtDetection.Text.Trim()) {
                    [System.Windows.Forms.MessageBox]::Show("Enter a detection script.", "No detection script", "OK", "Warning") | Out-Null
                    return
                }
                $detectionRuleConfig = [pscustomobject]@{ Type = "Script"; Script_Content = $txtDetection.Text }
            }
            1 {
                if (-not $txtMsiCode.Text.Trim()) {
                    [System.Windows.Forms.MessageBox]::Show("Enter the MSI product code.", "No product code", "OK", "Warning") | Out-Null
                    return
                }
                $detectionRuleConfig = [pscustomobject]@{
                    Type                = "Msi"
                    Msi_ProductCode     = $txtMsiCode.Text.Trim()
                    Msi_VersionOperator = $operatorMap[[string]$cmbMsiOperator.SelectedItem]
                    Msi_Version         = $txtMsiVersion.Text.Trim()
                }
            }
            2 {
                if (-not $txtFilePath.Text.Trim() -or -not $txtFileName.Text.Trim()) {
                    [System.Windows.Forms.MessageBox]::Show("Enter both the folder path and the file or folder name.", "Missing fields", "OK", "Warning") | Out-Null
                    return
                }
                $detectionRuleConfig = [pscustomobject]@{
                    Type               = "File"
                    File_Path           = $txtFilePath.Text.Trim()
                    File_Name           = $txtFileName.Text.Trim()
                    File_Check32Bit     = $chkFileCheck32.Checked
                    File_DetectionType  = $fileDetTypeMap[[string]$cmbFileDetType.SelectedItem]
                    File_Operator       = $operatorMap[[string]$cmbFileOperator.SelectedItem]
                    File_DetectionValue = $txtFileDetValue.Text.Trim()
                }
            }
            3 {
                if (-not $txtRegKeyPath.Text.Trim()) {
                    [System.Windows.Forms.MessageBox]::Show("Enter the registry key path.", "No key path", "OK", "Warning") | Out-Null
                    return
                }
                $detectionRuleConfig = [pscustomobject]@{
                    Type               = "Registry"
                    Reg_KeyPath         = $txtRegKeyPath.Text.Trim()
                    Reg_ValueName       = $txtRegValueName.Text.Trim()
                    Reg_Check32Bit      = $chkRegCheck32.Checked
                    Reg_DetectionType   = $regDetTypeMap[[string]$cmbRegDetType.SelectedItem]
                    Reg_Operator        = $operatorMap[[string]$cmbRegOperator.SelectedItem]
                    Reg_DetectionValue  = $txtRegDetValue.Text.Trim()
                }
            }
        }

        if ($replaceContent) {
            $r = [System.Windows.Forms.MessageBox]::Show(
                "This replaces the package content on the EXISTING, live app ($ExistingAppId) with:`n$($txtPackagePath.Text)`n`nDevices that already have this app installed will get the new content on their next check-in. This cannot be undone from here. Continue?",
                "Confirm content replacement", "YesNo", "Warning")
            if ($r -ne "Yes") { return }
        }

        # $resultPath computed BEFORE $config now, specifically so
        # OutputResultPath can be included directly in the object literal
        # below - the previous approach built $config first, then bolted
        # this one extra property on afterward via
        # "$config | Select-Object *, @{...}". That extra step was
        # confirmed, directly and repeatedly, to sometimes produce a
        # genuinely null result with no error at all - not a timing issue,
        # not a write issue, not an antivirus issue, all three already
        # ruled out. Rather than keep chasing why that specific PowerShell
        # construct misbehaves, this sidesteps it entirely by never using
        # it in the first place.
        $configPath = Join-Path $env:TEMP (".itsense_createapp_config_" + [guid]::NewGuid().ToString("N") + ".json")
        $resultPath = Join-Path $env:TEMP (".itsense_createapp_result_" + [guid]::NewGuid().ToString("N") + ".json")

        $config = [pscustomobject]@{
            TenantId              = $tenantId
            ClientId              = $clientId
            CertificateThumbprint = $certThumb
            Mode                  = $mode
            ExistingAppId         = $ExistingAppId
            AppName               = $txtCreateName.Text.Trim()
            Description           = $txtDesc.Text.Trim()
            Publisher             = $txtPublisher.Text.Trim()
            Owner                 = $txtOwner.Text.Trim()
            Developer             = $txtDeveloper.Text.Trim()
            InformationUrl        = $txtInfoUrl.Text.Trim()
            PrivacyUrl            = $txtPrivacyUrl.Text.Trim()
            Notes                 = $txtNotes.Text.Trim()
            InstallCommand        = $txtInstall.Text
            UninstallCommand      = $txtUninstall.Text
            DetectionRule         = $detectionRuleConfig
            InstallContext        = [string]$cmbContext.SelectedItem
            Architecture          = ($selectedArches -join ",")
            MinOSVersionKey       = $minOsMap[[string]$cmbMinOS.SelectedItem]
            PackagePath           = $txtPackagePath.Text
            DependencyAppIds      = @($selectedDepIds)
            ReplaceContent        = $replaceContent
            MinDiskSpaceMB        = [int]$txtDiskSpace.Text.Trim()
            MinMemoryMB           = [int]$txtMemory.Text.Trim()
            MinProcessors         = [int]$txtProcessors.Text.Trim()
            MinCpuSpeedMHz        = [int]$txtCpuSpeed.Text.Trim()
            InstallTimeMinutes    = [int]$txtInstallTime.Text.Trim()
            DeviceRestartBehavior = $restartBehaviorMap[[string]$cmbRestartBehavior.SelectedItem]
            AllowAvailableUninstall = $chkAllowUninstall.Checked
            # .ToArray() now, not @(...) - confirmed, directly and
            # precisely, to sometimes throw "Argument types do not match"
            # for this exact List[object] pattern elsewhere in this same
            # function (Save for later's own return-codes handling). If
            # this same construct was ALSO throwing here, inside $config's
            # own construction, that would silently abort the whole
            # object - explaining why Create never actually worked even
            # after the serializer itself was rewritten to hand-roll
            # everything else: the real failure was upstream of
            # serialization entirely, in building $config in the first
            # place.
            ReturnCodes           = $returnCodesConfig.ToArray()
            OutputResultPath      = $resultPath
        }

        # Hand-rolled via ConvertTo-CreateAppConfigJson, not a direct
        # ConvertTo-Json call on the whole $config object - serializing
        # this whole, larger, 30+ field object through one single
        # ConvertTo-Json call was confirmed, directly and repeatedly, to
        # sometimes silently produce a completely empty result with no
        # error thrown at all, even with -ErrorAction Stop, even with the
        # earlier Select-Object step already removed. This mirrors the
        # exact approach that already fixed the identical symptom for the
        # catalog's own per-app metadata: hand-roll every simple field,
        # isolate only the genuinely complex nested object (DetectionRule)
        # through its own, separate ConvertTo-Json call.
        $configJsonTextLength = 0
        try {
            $configJsonText = ConvertTo-CreateAppConfigJson -Config $config
            $configJsonTextLength = if ($configJsonText) { $configJsonText.Length } else { 0 }
            [System.IO.File]::WriteAllText($configPath, $configJsonText, (New-Object System.Text.UTF8Encoding($false)))
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Could not write the config file needed to run this: $($_.Exception.Message)", "Failed to prepare", "OK", "Error") | Out-Null
            return
        }
        # Verified explicitly, immediately after the write, rather than
        # trusting it succeeded just because no exception surfaced -
        # exceptions inside a WinForms event handler scriptblock don't
        # always propagate the same way they would in the main script body,
        # even with $ErrorActionPreference = "Stop" set globally. Launching
        # the child process anyway, on an unverified assumption the config
        # is actually there, is exactly what would produce "Config file not
        # found" from the child instead of a clear, immediate error here.
        #
        # Checks CONTENT, not just existence - a real failure mode already
        # seen once: Test-Path alone can find the file, but the child
        # process that reads it right after gets back empty/incomplete
        # content, which silently parses to a blank config (empty AppName,
        # empty Mode) instead of throwing any error at all. Retried briefly
        # rather than checked once, on the same reasoning as before - a
        # real-time antivirus/EDR scan intercepting a newly-written file
        # (this one contains embedded PowerShell script content, which can
        # draw extra scrutiny even though it's completely legitimate here)
        # is a well-known cause of exactly this kind of transient gap
        # between "the file exists" and "the file's actual content is
        # available to read." Same kind of short, transient-visibility
        # retry already proven elsewhere in this app (group creation
        # propagation delay).
        $configVerified = $false
        # The specific failure reason from the LAST attempt, not just a
        # generic "didn't work" - the empty catch block this replaced was
        # silently throwing away exactly the information needed to tell
        # apart "file never appeared", "file appeared but is empty",
        # "file has content but won't parse as JSON", and "parsed fine but
        # a field came back blank" - four genuinely different problems
        # that all produced the identical, unhelpful message before.
        $lastVerifyDetail = "the file does not exist"
        for ($verifyAttempt = 1; $verifyAttempt -le 5; $verifyAttempt++) {
            if (Test-Path $configPath) {
                try {
                    $fileInfo = Get-Item -Path $configPath -ErrorAction Stop
                    $verifyContent = Get-Content -Path $configPath -Raw -ErrorAction Stop
                    if (-not $verifyContent -or $verifyContent.Trim().Length -eq 0) {
                        $lastVerifyDetail = "the file exists ($($fileInfo.Length) bytes on disk) but its content read back empty"
                        # Not just noted and retried unchanged - actively
                        # re-attempted with a different, lower-level write
                        # path: raw bytes through a FileStream with an
                        # explicit OS-level flush, rather than
                        # WriteAllText's higher-level buffering. Worth
                        # trying in its own right after "0 bytes on disk"
                        # has now been seen twice already, at two
                        # completely different folder locations - giving
                        # this attempt a real chance to actually succeed,
                        # not just collecting more information about the
                        # same failure a third time.
                        try {
                            $configBytesRetry = [System.Text.Encoding]::UTF8.GetBytes($configJsonText)
                            $retryStream = [System.IO.File]::Open($configPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                            try {
                                $retryStream.Write($configBytesRetry, 0, $configBytesRetry.Length)
                                $retryStream.Flush($true)
                            }
                            finally {
                                $retryStream.Close()
                                $retryStream.Dispose()
                            }
                        }
                        catch {
                            $lastVerifyDetail = "the file exists ($($fileInfo.Length) bytes on disk) but its content read back empty, and the fallback rewrite attempt also failed: $($_.Exception.Message)"
                        }
                    }
                    else {
                        try {
                            $verifyParsed = $verifyContent | ConvertFrom-Json -ErrorAction Stop
                            if ($verifyParsed.AppName) { $configVerified = $true; break }
                            $lastVerifyDetail = "the file parsed as JSON ($($verifyContent.Length) chars) but its AppName field came back blank"
                        }
                        catch {
                            $lastVerifyDetail = "the file has content ($($verifyContent.Length) chars) but failed to parse as JSON: $($_.Exception.Message)"
                        }
                    }
                }
                catch {
                    $lastVerifyDetail = "the file exists but could not be read: $($_.Exception.Message)"
                }
            }
            Start-Sleep -Milliseconds 200
        }
        if (-not $configVerified) {
            [System.Windows.Forms.MessageBox]::Show("The config file at:`n$configPath`n`ncould not be verified after waiting a moment: $lastVerifyDetail.`n`nThe JSON text generated before the write was $configJsonTextLength characters long.`n`nNothing was started.`n`nIf this keeps happening, check whether antivirus/EDR software on this machine is intercepting, delaying, or quarantining newly-written .json files.", "Failed to prepare", "OK", "Error") | Out-Null
            return
        }

        $btnCreate.Enabled = $false
        $lblCreateStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblCreateStatus.Text = "Working... this can take a few minutes for larger packages. See progress below. Cancel stops it."

        # Fresh aliases for the nested -OnComplete closure below - see note at
        # the top of this function.
        $btnCreateRef = $btnCreate
        $lblStatusRef = $lblCreateStatus
        $dlgRef = $dlg
        $resultBoxRef = $resultBox
        $resultPathRef = $resultPath
        $configPathRef = $configPath
        $procBoxRef = $procBox
        $appNameRef = $config.AppName
        $fromAppEditorRef = $FromAppEditor
        $rtbLogRef = $rtbCreateLog
        # Added specifically so the success handler below can build and
        # save a catalog-shaped metadata object via
        # Save-AppMetadataToLocalCatalog - a real Create/Update Metadata
        # previously only ever touched Intune, never the local catalog
        # file, even though "Save for later..." (right next to it, same
        # dialog) already did this correctly. $detectionRuleConfig,
        # $selectedArches, and $returnCodesConfig are already-built local
        # variables from this same button's own validation just above,
        # not re-read from the UI a second time.
        $appsRefRef = $appsRef
        $linkedFilePathRef = $linkedFilePath
        $txtDescRef = $txtDesc
        $txtPublisherRef = $txtPublisher
        $txtOwnerRef = $txtOwner
        $txtDeveloperRef = $txtDeveloper
        $txtInfoUrlRef = $txtInfoUrl
        $txtPrivacyUrlRef = $txtPrivacyUrl
        $txtNotesRef = $txtNotes
        $txtInstallRef = $txtInstall
        $txtUninstallRef = $txtUninstall
        $cmbContextRef = $cmbContext
        $cmbMinOSRef = $cmbMinOS
        $minOsMapRef = $minOsMap
        $detectionRuleConfigRef = $detectionRuleConfig
        $selectedArchesRef = $selectedArches
        $txtDiskSpaceRef = $txtDiskSpace
        $txtMemoryRef = $txtMemory
        $txtProcessorsRef = $txtProcessors
        $txtCpuSpeedRef = $txtCpuSpeed
        $txtInstallTimeRef = $txtInstallTime
        $cmbRestartBehaviorRef = $cmbRestartBehavior
        $restartBehaviorMapRef = $restartBehaviorMap
        $chkAllowUninstallRef = $chkAllowUninstall
        $returnCodesConfigRef = $returnCodesConfig
        $clbDepsRef = $clbDeps
        $depNameByLabelRef = $depNameByLabel

        $procBoxRef.Proc = Start-PipelineProcess -ScriptContent $createScript -TempScriptName ".itsense_embedded_createapp.ps1" -ArgumentString "-ConfigPath `"$configPathRef`"" -ExtraLogTarget $rtbCreateLog -OnComplete {
            param($code)
            $btnCreateRef.Enabled = $true
            $procBoxRef.Proc = $null
            Remove-Item $configPathRef -Force -ErrorAction SilentlyContinue

            if (Test-Path $resultPathRef) {
                try {
                    $result = Get-Content -Path $resultPathRef -Raw | ConvertFrom-Json
                    Remove-Item $resultPathRef -Force -ErrorAction SilentlyContinue
                    if ($result.success) {
                        $resultBoxRef.NewAppId = $result.appId
                        $resultBoxRef.NewAppName = $appNameRef

                        # Builds and saves a catalog-shaped metadata object
                        # now, same schema and same shared function "Save
                        # for later..." uses - a real Create/Update
                        # Metadata previously only ever reached Intune,
                        # never the local catalog file, even though
                        # everything entered here (description, install
                        # command, detection script, requirements, return
                        # codes...) was successfully sent to Intune and
                        # then simply never recorded locally at all.
                        # Wrapped in its own try/catch, not left bare - the
                        # same defensive pattern already proven necessary
                        # for this exact kind of object construction in
                        # "Save for later...".
                        $localSaveOk = $true
                        try {
                            $depNamesForSave = New-Object System.Collections.Generic.List[string]
                            foreach ($checkedLabel in $clbDepsRef.CheckedItems) {
                                if ($depNameByLabelRef.ContainsKey([string]$checkedLabel)) { $depNamesForSave.Add($depNameByLabelRef[[string]$checkedLabel]) }
                            }
                            $createMetadata = [pscustomobject]@{
                                description      = $txtDescRef.Text.Trim()
                                publisher        = $txtPublisherRef.Text.Trim()
                                owner            = $txtOwnerRef.Text.Trim()
                                developer        = $txtDeveloperRef.Text.Trim()
                                informationUrl   = $txtInfoUrlRef.Text.Trim()
                                privacyUrl       = $txtPrivacyUrlRef.Text.Trim()
                                notes            = $txtNotesRef.Text.Trim()
                                installCommand   = $txtInstallRef.Text
                                uninstallCommand = $txtUninstallRef.Text
                                architecture     = ($selectedArchesRef -join ",")
                                installContext   = [string]$cmbContextRef.SelectedItem
                                minOSKey         = $minOsMapRef[[string]$cmbMinOSRef.SelectedItem]
                                detectionRule    = $detectionRuleConfigRef
                                dependencies     = @($depNamesForSave)
                                minDiskSpaceMB          = [int]$txtDiskSpaceRef.Text.Trim()
                                minMemoryMB             = [int]$txtMemoryRef.Text.Trim()
                                minProcessors           = [int]$txtProcessorsRef.Text.Trim()
                                minCpuSpeedMHz          = [int]$txtCpuSpeedRef.Text.Trim()
                                installTimeMinutes      = [int]$txtInstallTimeRef.Text.Trim()
                                deviceRestartBehavior   = $restartBehaviorMapRef[[string]$cmbRestartBehaviorRef.SelectedItem]
                                allowAvailableUninstall = $chkAllowUninstallRef.Checked
                                returnCodes             = $returnCodesConfigRef.ToArray()
                            }
                            if ($fromAppEditorRef) {
                                # Deferred, not saved here - the App Editor
                                # this dialog was opened from is still open,
                                # with its own unsaved appName/wingetId/group
                                # fields, and hasn't had its own "Save app to
                                # catalog" clicked yet. Writing this metadata
                                # (and $result.appId) straight to $Script:Apps
                                # and disk here, unconditionally, used to mean
                                # a brand-new app got ADDED to the catalog the
                                # instant Create succeeded - so that editor's
                                # own later "Save app to catalog" click added
                                # a second, duplicate entry for the same app,
                                # and clicking Cancel instead couldn't undo
                                # the first one at all, leaving a stray entry
                                # behind. Handing it back via $resultBoxRef
                                # instead lets the App Editor fold it into the
                                # ONE save (or discard) it already owns.
                                $resultBoxRef.Metadata = $createMetadata
                            }
                            else {
                                $localSaveResult = Save-AppMetadataToLocalCatalog -AppsRef $appsRefRef -LinkedFilePath $linkedFilePathRef -AppName $appNameRef -Metadata $createMetadata -NewAppId $result.appId
                                $localSaveOk = $localSaveResult.Success
                            }
                        }
                        catch {
                            $localSaveOk = $false
                            Write-Log "[ERROR] Create/Update Metadata: saving to the local catalog threw: $($_.Exception.Message)`r`n" ([System.Drawing.Color]::Tomato)
                        }

                        $lblStatusRef.ForeColor = [System.Drawing.Color]::SeaGreen
                        $lblStatusRef.Text = "Success - App ID: $($result.appId)"
                        # Accurate for both callers, not just one - this
                        # dialog is opened from two different places with two
                        # different save behaviors: the App Editor (which
                        # still has its own separate appName/wingetId/group
                        # fields, and this app's App ID/metadata now stay
                        # staged - not written anywhere - until its own "Save
                        # app to catalog" is clicked) and everywhere else
                        # (where App ID and metadata are both already saved
                        # directly, right above).
                        $doneMsg = if (-not $localSaveOk) {
                            "Done. App ID: $($result.appId)`n`n...but saving this to the local catalog failed - check the Log tab. The app was still created/updated in Intune successfully."
                        } elseif ($fromAppEditorRef) {
                            "Done. App ID: $($result.appId)`n`nThe App ID has been filled in above. Nothing is saved to the catalog yet - click `"Save app to catalog`" in the app editor to save it there (or Cancel to discard it; the app in Intune itself is unaffected either way)."
                        } else {
                            "Done. App ID: $($result.appId)`n`nAlready saved to disk."
                        }
                        [System.Windows.Forms.MessageBox]::Show($doneMsg, "Success", "OK", "Information") | Out-Null
                        $dlgRef.Close()
                    }
                    else {
                        Write-DialogError -StatusLabel $lblStatusRef -LogBox $rtbLogRef -ErrorMessage $result.error
                    }
                }
                catch {
                    Write-DialogError -StatusLabel $lblStatusRef -LogBox $rtbLogRef -ErrorMessage "Could not read result (exit code $code)."
                }
            }
            else {
                Write-DialogError -StatusLabel $lblStatusRef -LogBox $rtbLogRef -ErrorMessage "No result written (exit code $code). See progress above for the last thing it was doing."
            }
        }.GetNewClosure()
    }.GetNewClosure())

    $btnSaveForLater.Add_Click({
        if (-not $txtCreateName.Text.Trim() -or -not $txtInstall.Text.Trim() -or -not $txtUninstall.Text.Trim() -or -not $txtDetection.Text.Trim()) {
            [System.Windows.Forms.MessageBox]::Show("Name, install command, uninstall command, and detection script are all required.", "Missing values", "OK", "Warning") | Out-Null
            return
        }

        $selectedArches = New-Object System.Collections.Generic.List[string]
        if ($chkArchX86.Checked)   { $selectedArches.Add("x86") }
        if ($chkArchX64.Checked)   { $selectedArches.Add("x64") }
        if ($chkArchArm64.Checked) { $selectedArches.Add("arm64") }
        if ($selectedArches.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Check at least one architecture.", "No architecture selected", "OK", "Warning") | Out-Null
            return
        }

        foreach ($urlCheck in @(@{ Label = "Information URL"; Text = $txtInfoUrl.Text.Trim() }, @{ Label = "Privacy URL"; Text = $txtPrivacyUrl.Text.Trim() })) {
            if (-not $urlCheck.Text) { continue }
            $parsedUri = $null
            $isValidUrl = [Uri]::TryCreate($urlCheck.Text, [UriKind]::Absolute, [ref]$parsedUri) -and ($parsedUri.Scheme -eq 'http' -or $parsedUri.Scheme -eq 'https')
            if (-not $isValidUrl) {
                [System.Windows.Forms.MessageBox]::Show("$($urlCheck.Label) doesn't look like a valid URL:`n`n$($urlCheck.Text)`n`nIt needs a scheme, e.g. https://example.com - or leave it blank.", "Invalid URL", "OK", "Warning") | Out-Null
                return
            }
        }

        $numericChecksSave = @(
            @{ Label = "Disk space (MB)"; Text = $txtDiskSpace.Text.Trim() }
            @{ Label = "Memory (MB)"; Text = $txtMemory.Text.Trim() }
            @{ Label = "Min. processors"; Text = $txtProcessors.Text.Trim() }
            @{ Label = "Min. CPU speed (MHz)"; Text = $txtCpuSpeed.Text.Trim() }
            @{ Label = "Install time required (mins)"; Text = $txtInstallTime.Text.Trim() }
        )
        foreach ($numCheckSave in $numericChecksSave) {
            $parsedNumSave = 0
            if (-not [int]::TryParse($numCheckSave.Text, [ref]$parsedNumSave) -or $parsedNumSave -lt 0) {
                [System.Windows.Forms.MessageBox]::Show("$($numCheckSave.Label) must be a whole number, 0 or greater.", "Invalid value", "OK", "Warning") | Out-Null
                return
            }
        }

        $returnCodesConfigSave = New-Object System.Collections.Generic.List[object]
        foreach ($rcRowSave in $grdReturnCodes.Rows) {
            if ($rcRowSave.IsNewRow) { continue }
            $codeTextSave = [string]$rcRowSave.Cells["Code"].Value
            $typeTextSave = [string]$rcRowSave.Cells["Type"].Value
            if (-not $codeTextSave -and -not $typeTextSave) { continue }
            $parsedCodeSave = 0
            if (-not [int]::TryParse([string]$codeTextSave.Trim(), [ref]$parsedCodeSave)) {
                [System.Windows.Forms.MessageBox]::Show("Return code `"$codeTextSave`" isn't a valid whole number.", "Invalid return code", "OK", "Warning") | Out-Null
                return
            }
            if (-not $typeTextSave) {
                [System.Windows.Forms.MessageBox]::Show("Return code $parsedCodeSave needs a type selected.", "Missing return code type", "OK", "Warning") | Out-Null
                return
            }
            $returnCodesConfigSave.Add([pscustomobject]@{ returnCode = $parsedCodeSave; type = $typeTextSave })
        }
        if ($returnCodesConfigSave.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("At least one return code is required.", "No return codes", "OK", "Warning") | Out-Null
            return
        }

        $detectionRuleConfig = $null
        switch ($cmbDetectionType.SelectedIndex) {
            0 {
                if (-not $txtDetection.Text.Trim()) {
                    [System.Windows.Forms.MessageBox]::Show("Enter a detection script.", "No detection script", "OK", "Warning") | Out-Null
                    return
                }
                $detectionRuleConfig = [pscustomobject]@{ Type = "Script"; Script_Content = $txtDetection.Text }
            }
            1 {
                if (-not $txtMsiCode.Text.Trim()) {
                    [System.Windows.Forms.MessageBox]::Show("Enter the MSI product code.", "No product code", "OK", "Warning") | Out-Null
                    return
                }
                $detectionRuleConfig = [pscustomobject]@{
                    Type                = "Msi"
                    Msi_ProductCode     = $txtMsiCode.Text.Trim()
                    Msi_VersionOperator = $operatorMap[[string]$cmbMsiOperator.SelectedItem]
                    Msi_Version         = $txtMsiVersion.Text.Trim()
                }
            }
            2 {
                if (-not $txtFilePath.Text.Trim() -or -not $txtFileName.Text.Trim()) {
                    [System.Windows.Forms.MessageBox]::Show("Enter both the folder path and the file or folder name.", "Missing fields", "OK", "Warning") | Out-Null
                    return
                }
                $detectionRuleConfig = [pscustomobject]@{
                    Type               = "File"
                    File_Path           = $txtFilePath.Text.Trim()
                    File_Name           = $txtFileName.Text.Trim()
                    File_Check32Bit     = $chkFileCheck32.Checked
                    File_DetectionType  = $fileDetTypeMap[[string]$cmbFileDetType.SelectedItem]
                    File_Operator       = $operatorMap[[string]$cmbFileOperator.SelectedItem]
                    File_DetectionValue = $txtFileDetValue.Text.Trim()
                }
            }
            3 {
                if (-not $txtRegKeyPath.Text.Trim()) {
                    [System.Windows.Forms.MessageBox]::Show("Enter the registry key path.", "No key path", "OK", "Warning") | Out-Null
                    return
                }
                $detectionRuleConfig = [pscustomobject]@{
                    Type               = "Registry"
                    Reg_KeyPath         = $txtRegKeyPath.Text.Trim()
                    Reg_ValueName       = $txtRegValueName.Text.Trim()
                    Reg_Check32Bit      = $chkRegCheck32.Checked
                    Reg_DetectionType   = $regDetTypeMap[[string]$cmbRegDetType.SelectedItem]
                    Reg_Operator        = $operatorMap[[string]$cmbRegOperator.SelectedItem]
                    Reg_DetectionValue  = $txtRegDetValue.Text.Trim()
                }
            }
        }

        # Read directly from the picker's current checked state, not just
        # whatever was passively fetched/loaded earlier - the picker now
        # includes undeployed apps too (resolved by name at actual deploy
        # time, same as Batch Deploy already does), so this is the only
        # way to actually SET a dependency when saving metadata for a new
        # app that doesn't exist in Intune yet to fetch anything from.
        $depNamesFromPicker = New-Object System.Collections.Generic.List[string]
        foreach ($checkedLabel in $clbDeps.CheckedItems) {
            if ($depNameByLabel.ContainsKey([string]$checkedLabel)) { $depNamesFromPicker.Add($depNameByLabel[[string]$checkedLabel]) }
        }

        # Built field by field, each into its own variable, with a
        # checkpoint logged after each group - "Argument types do not
        # match" was confirmed as the actual, specific exception here,
        # but that alone doesn't say WHICH of the ~20 fields threw it.
        # Rather than guess again, this pinpoints the exact line: the
        # checkpoint log written right before the exception fires tells
        # us precisely how far construction got before failing.
        try {
            $fDescription = $txtDesc.Text.Trim()
            $fPublisher = $txtPublisher.Text.Trim()
            $fOwner = $txtOwner.Text.Trim()
            $fDeveloper = $txtDeveloper.Text.Trim()
            $fInformationUrl = $txtInfoUrl.Text.Trim()
            $fPrivacyUrl = $txtPrivacyUrl.Text.Trim()
            $fNotes = $txtNotes.Text.Trim()
            $fInstallCommand = $txtInstall.Text
            $fUninstallCommand = $txtUninstall.Text
            Write-Log "Save for later: checkpoint 1/6 (simple text fields) OK.`r`n"

            $fArchitecture = ($selectedArches -join ",")
            Write-Log "Save for later: checkpoint 2/6 (architecture join) OK.`r`n"

            $fInstallContext = [string]$cmbContext.SelectedItem
            Write-Log "Save for later: checkpoint 3/6 (installContext cast) OK - value=`"$fInstallContext`".`r`n"

            $fMinOSKeySelected = [string]$cmbMinOS.SelectedItem
            Write-Log "Save for later: checkpoint 3.5/6 (minOS SelectedItem cast) OK - value=`"$fMinOSKeySelected`", type=$($fMinOSKeySelected.GetType().FullName).`r`n"
            $fMinOSKey = $minOsMap[$fMinOSKeySelected]
            Write-Log "Save for later: checkpoint 4/6 (minOsMap lookup) OK - value=`"$fMinOSKey`".`r`n"

            $fDetectionRule = $detectionRuleConfig
            $fDependencies = @($depNamesFromPicker)
            Write-Log "Save for later: checkpoint 5/6 (detectionRule, dependencies) OK.`r`n"

            $fMinDiskSpaceMB = [int]$txtDiskSpace.Text.Trim()
            $fMinMemoryMB = [int]$txtMemory.Text.Trim()
            $fMinProcessors = [int]$txtProcessors.Text.Trim()
            $fMinCpuSpeedMHz = [int]$txtCpuSpeed.Text.Trim()
            $fInstallTimeMinutes = [int]$txtInstallTime.Text.Trim()
            Write-Log "Save for later: checkpoint 6/6a ([int] casts) OK.`r`n"

            $fRestartBehaviorSelected = [string]$cmbRestartBehavior.SelectedItem
            Write-Log "Save for later: checkpoint 6/6b (restartBehavior SelectedItem cast) OK - value=`"$fRestartBehaviorSelected`", type=$($fRestartBehaviorSelected.GetType().FullName).`r`n"
            $fDeviceRestartBehavior = $restartBehaviorMap[$fRestartBehaviorSelected]
            Write-Log "Save for later: checkpoint 6/6c (restartBehaviorMap lookup) OK - value=`"$fDeviceRestartBehavior`".`r`n"

            $fAllowAvailableUninstall = $chkAllowUninstall.Checked
            Write-Log "Save for later: checkpoint 6/6d1 (allowUninstall) OK - value=$fAllowAvailableUninstall, type=$($fAllowAvailableUninstall.GetType().FullName).`r`n"

            Write-Log "Save for later: about to wrap returnCodesConfigSave - Count=$($returnCodesConfigSave.Count), type=$($returnCodesConfigSave.GetType().FullName).`r`n"
            # .ToArray() now, not the @(...) array-subexpression operator -
            # confirmed, directly and precisely (via checkpoint logging
            # isolating this exact statement, on its own, outside any
            # larger expression), to be the one specific operation
            # throwing "Argument types do not match" for this particular
            # List[object]. .ToArray() is a plain method call already
            # defined on the list itself, sidestepping whatever PowerShell's
            # own @(...) enumeration logic was doing differently here.
            $fReturnCodes = $returnCodesConfigSave.ToArray()
            Write-Log "Save for later: checkpoint 6/6d2 (returnCodes wrap) OK - result Count=$($fReturnCodes.Count).`r`n"

            $newMetadata = [pscustomobject]@{
                description      = $fDescription
                publisher        = $fPublisher
                owner            = $fOwner
                developer        = $fDeveloper
                informationUrl   = $fInformationUrl
                privacyUrl       = $fPrivacyUrl
                notes            = $fNotes
                installCommand   = $fInstallCommand
                uninstallCommand = $fUninstallCommand
                architecture     = $fArchitecture
                installContext   = $fInstallContext
                minOSKey         = $fMinOSKey
                detectionRule    = $fDetectionRule
                dependencies     = $fDependencies
                minDiskSpaceMB          = $fMinDiskSpaceMB
                minMemoryMB             = $fMinMemoryMB
                minProcessors           = $fMinProcessors
                minCpuSpeedMHz          = $fMinCpuSpeedMHz
                installTimeMinutes      = $fInstallTimeMinutes
                deviceRestartBehavior   = $fDeviceRestartBehavior
                allowAvailableUninstall = $fAllowAvailableUninstall
                returnCodes             = $fReturnCodes
            }
            Write-Log "Save for later: final object assembly OK.`r`n"
        }
        catch {
            Write-Log "[ERROR] Save for later: building the metadata object threw: $($_.Exception.Message)`r`n" ([System.Drawing.Color]::Tomato)
            [System.Windows.Forms.MessageBox]::Show("Could not build the metadata to save: $($_.Exception.Message)", "Save failed", "OK", "Error") | Out-Null
            return
        }
        Write-Log "Save for later: `$newMetadata built - is `$null: $($null -eq $newMetadata), description in it: `"$($newMetadata.description)`".`r`n"

        # Opened from the App Editor (-FromAppEditor): stage this metadata
        # for that still-open editor's own "Save app to catalog" instead of
        # writing it here - same reasoning as the Create/Update Metadata
        # success handler above. Writing it here unconditionally used to
        # mean a brand-new app's editor Save afterward added a SECOND,
        # duplicate catalog entry, and Cancelling that editor couldn't undo
        # the entry this button had already written.
        if ($FromAppEditor) {
            $resultBox.Metadata = $newMetadata
            Write-Log "Save for later (from app editor): metadata staged for `"$AppName`" - will be saved when `"Save app to catalog`" is clicked there.`r`n" ([System.Drawing.Color]::LightGreen)
            $dlg.Close()
            return
        }

        # Saves straight to disk rather than just staging the change in
        # memory - unlike most other actions in this app (which batch
        # several related edits before one explicit Save), this button's
        # entire job IS the save; requiring a separate click afterward just
        # to persist it was pure friction, and had already caused real,
        # demonstrated confusion earlier this session (mistaking "not yet
        # written to disk" for "the save silently failed"). Routed through
        # the same shared function the Create/Update Metadata success
        # handler now also uses (see Save-AppMetadataToLocalCatalog) -
        # find/create-by-name, whole-element replacement, and the actual
        # write all happen there now, not duplicated here.
        $saveResult = Save-AppMetadataToLocalCatalog -AppsRef $appsRef -LinkedFilePath $linkedFilePath -AppName $AppName -Metadata $newMetadata
        $saveSucceeded = $saveResult.Success
        $createdNewEntry = $saveResult.CreatedNewEntry
        $unsavedBox.Value = $true
        Write-Log "Save for later: Save-AppMetadataToLocalCatalog returned Success=$saveSucceeded, CreatedNewEntry=$createdNewEntry.`r`n"

        $createdMsg = if ($createdNewEntry) { "`"$AppName`" wasn't in the catalog yet, so it was added. " } else { "" }
        if (-not $saveSucceeded) {
            # A real failure worth seeing and acting on, not just a
            # confirmation - dialog stays open so the user can retry
            # (e.g. via the main toolbar's Save to input.json) rather than
            # closing on them right when something needs attention.
            $lblCreateStatus.ForeColor = [System.Drawing.Color]::DarkOrange
            $lblCreateStatus.Text = "$($createdMsg)Metadata saved in memory for `"$AppName`", but writing to disk was cancelled or failed - use Force save to try again."
            return
        }

        $savedMsg = if ($isDuplicate) {
            "$($createdMsg)Local copy saved and written to disk for `"$AppName`"."
        } else {
            "$($createdMsg)Metadata saved and written to disk for `"$AppName`". Deploy later once its package is ready."
        }
        # No popup on success - a modal box requiring its own click to
        # dismiss, on an action that now virtually always succeeds, was
        # exactly the kind of friction worth removing. The dialog closing
        # is itself sufficient confirmation; the details still go to the
        # Log tab for anyone who wants to check back on them.
        Write-Log $savedMsg ([System.Drawing.Color]::LightGreen)
        $dlg.Close()
    }.GetNewClosure())

    $btnCancel.Add_Click({
        if ($procBox.Proc -and -not $procBox.Proc.HasExited) {
            $r = [System.Windows.Forms.MessageBox]::Show(
                "A step is currently running (PID $($procBox.Proc.Id)). Stop it and close this dialog?`n`nIf the app object was already created in Intune, it may be left in an incomplete state - check the Intune portal afterward and delete it if needed before retrying.",
                "Stop and close?", "YesNo", "Warning")
            if ($r -ne "Yes") { return }
            try { $procBox.Proc.Kill() } catch { }
        }
        $dlg.Close()
    }.GetNewClosure())

    # Pre-fill from LOCALLY saved metadata (if any), before anything else -
    # for a new app that was already "Saved for later" once, this restores
    # what was entered instead of starting over from generic templates. For
    # an EXISTING app (about to be auto-refreshed from Intune just below),
    # this also gives something to diff the live fetch against, so a field
    # that's drifted between the two gets flagged instead of the live value
    # silently overwriting it with nobody noticing the difference.
    $localSnapshot = $null
    $targetCatalogApp = $appsRef | Where-Object { $_.appName -eq $AppName } | Select-Object -First 1
    if ($targetCatalogApp -and $targetCatalogApp.metadata) {
        $m = $targetCatalogApp.metadata
        if ($null -ne $m.description)    { $txtDesc.Text = $m.description }
        if ($null -ne $m.publisher)      { $txtPublisher.Text = $m.publisher }
        if ($null -ne $m.owner)          { $txtOwner.Text = $m.owner }
        if ($null -ne $m.developer)      { $txtDeveloper.Text = $m.developer }
        if ($null -ne $m.informationUrl) { $txtInfoUrl.Text = $m.informationUrl }
        if ($null -ne $m.privacyUrl)     { $txtPrivacyUrl.Text = $m.privacyUrl }
        if ($null -ne $m.notes)          { $txtNotes.Text = $m.notes }
        if ($m.installCommand)           { $txtInstall.Text = $m.installCommand }
        if ($m.uninstallCommand)         { $txtUninstall.Text = $m.uninstallCommand }
        if ($m.detectionRule) {
            switch ($m.detectionRule.Type) {
                "Script" {
                    $cmbDetectionType.SelectedIndex = 0
                    if ($m.detectionRule.Script_Content) { $txtDetection.Text = $m.detectionRule.Script_Content }
                }
                "Msi" {
                    $cmbDetectionType.SelectedIndex = 1
                    $txtMsiCode.Text = $m.detectionRule.Msi_ProductCode
                    $opKey = $operatorMap.Keys | Where-Object { $operatorMap[$_] -eq $m.detectionRule.Msi_VersionOperator } | Select-Object -First 1
                    if ($opKey) { $cmbMsiOperator.SelectedItem = $opKey }
                    $txtMsiVersion.Text = $m.detectionRule.Msi_Version
                }
                "File" {
                    $cmbDetectionType.SelectedIndex = 2
                    $txtFilePath.Text = $m.detectionRule.File_Path
                    $txtFileName.Text = $m.detectionRule.File_Name
                    $chkFileCheck32.Checked = [bool]$m.detectionRule.File_Check32Bit
                    $dtKey = $fileDetTypeMap.Keys | Where-Object { $fileDetTypeMap[$_] -eq $m.detectionRule.File_DetectionType } | Select-Object -First 1
                    if ($dtKey) { $cmbFileDetType.SelectedItem = $dtKey }
                    $opKey = $operatorMap.Keys | Where-Object { $operatorMap[$_] -eq $m.detectionRule.File_Operator } | Select-Object -First 1
                    if ($opKey) { $cmbFileOperator.SelectedItem = $opKey }
                    $txtFileDetValue.Text = $m.detectionRule.File_DetectionValue
                }
                "Registry" {
                    $cmbDetectionType.SelectedIndex = 3
                    $txtRegKeyPath.Text = $m.detectionRule.Reg_KeyPath
                    $txtRegValueName.Text = $m.detectionRule.Reg_ValueName
                    $chkRegCheck32.Checked = [bool]$m.detectionRule.Reg_Check32Bit
                    $dtKey = $regDetTypeMap.Keys | Where-Object { $regDetTypeMap[$_] -eq $m.detectionRule.Reg_DetectionType } | Select-Object -First 1
                    if ($dtKey) { $cmbRegDetType.SelectedItem = $dtKey }
                    $opKey = $operatorMap.Keys | Where-Object { $operatorMap[$_] -eq $m.detectionRule.Reg_Operator } | Select-Object -First 1
                    if ($opKey) { $cmbRegOperator.SelectedItem = $opKey }
                    $txtRegDetValue.Text = $m.detectionRule.Reg_DetectionValue
                }
            }
        }
        if ($m.architecture) {
            $archList = @($m.architecture -split ',' | ForEach-Object { $_.Trim().ToLower() })
            $chkArchX86.Checked = $archList -contains "x86"
            $chkArchX64.Checked = $archList -contains "x64"
            $chkArchArm64.Checked = $archList -contains "arm64"
        }
        if ($m.installContext) { $cmbContext.SelectedItem = $m.installContext }
        if ($m.minOSKey) {
            $matchKey = $minOsMap.Keys | Where-Object { $minOsMap[$_] -eq $m.minOSKey } | Select-Object -First 1
            if ($matchKey) { $cmbMinOS.SelectedItem = $matchKey }
        }
        if ($m.dependencies) {
            $fetchedDependencyBox.Names = @($m.dependencies)
            # Pre-checks the picker to match EXACTLY what's saved, not just
            # storing the names silently in the background - without this,
            # "Save for later..." reading from the picker (below) would
            # show existing dependencies as unchecked and silently wipe
            # them out the moment someone clicked Save without noticing.
            # Cleared first, not just added to - otherwise the picker's own
            # default "Winget AutoUpdate" pre-check could stick around even
            # when the saved dependencies deliberately don't include it.
            for ($ci = 0; $ci -lt $clbDeps.Items.Count; $ci++) { $clbDeps.SetItemChecked($ci, $false) }
            for ($ci = 0; $ci -lt $clbDeps.Items.Count; $ci++) {
                $itemLabel = [string]$clbDeps.Items[$ci]
                if ($depNameByLabel.ContainsKey($itemLabel) -and (@($m.dependencies) -contains $depNameByLabel[$itemLabel])) {
                    $clbDeps.SetItemChecked($ci, $true)
                }
            }
        }
        if ($null -ne $m.minDiskSpaceMB)     { $txtDiskSpace.Text = [string]$m.minDiskSpaceMB }
        if ($null -ne $m.minMemoryMB)        { $txtMemory.Text = [string]$m.minMemoryMB }
        if ($null -ne $m.minProcessors)      { $txtProcessors.Text = [string]$m.minProcessors }
        if ($null -ne $m.minCpuSpeedMHz)     { $txtCpuSpeed.Text = [string]$m.minCpuSpeedMHz }
        if ($null -ne $m.installTimeMinutes) { $txtInstallTime.Text = [string]$m.installTimeMinutes }
        if ($m.deviceRestartBehavior) {
            $rbKey = $restartBehaviorMap.Keys | Where-Object { $restartBehaviorMap[$_] -eq $m.deviceRestartBehavior } | Select-Object -First 1
            if ($rbKey) { $cmbRestartBehavior.SelectedItem = $rbKey }
        }
        $chkAllowUninstall.Checked = [bool]$m.allowAvailableUninstall
        if (@($m.returnCodes).Count -gt 0) {
            $grdReturnCodes.Rows.Clear()
            foreach ($rc in @($m.returnCodes)) {
                $rcRowIdx = $grdReturnCodes.Rows.Add()
                $grdReturnCodes.Rows[$rcRowIdx].Cells["Code"].Value = [string]$rc.returnCode
                $grdReturnCodes.Rows[$rcRowIdx].Cells["Type"].Value = [string]$rc.type
            }
        }

        # Captured AFTER setting the fields above, as an exact snapshot of
        # what LOCAL held - compared later against the live Intune fetch
        # (for existing apps only) to flag any drift between the two.
        $localSnapshot = [pscustomobject]@{
            Description        = $txtDesc.Text
            Publisher          = $txtPublisher.Text
            Owner              = $txtOwner.Text
            Developer          = $txtDeveloper.Text
            InformationUrl     = $txtInfoUrl.Text
            PrivacyUrl         = $txtPrivacyUrl.Text
            Notes              = $txtNotes.Text
            InstallCommand     = $txtInstall.Text
            UninstallCommand   = $txtUninstall.Text
            Architecture       = $m.architecture
            DetectionSummary   = if ($m.detectionRule) { ($m.detectionRule | ConvertTo-Json -Compress -Depth 5) } else { "" }
            MinDiskSpaceMB     = $txtDiskSpace.Text
            MinMemoryMB        = $txtMemory.Text
            MinProcessors      = $txtProcessors.Text
            MinCpuSpeedMHz     = $txtCpuSpeed.Text
            InstallTimeMinutes = $txtInstallTime.Text
            DeviceRestartBehavior = if ($m.deviceRestartBehavior) { $m.deviceRestartBehavior } else { "basedOnReturnCode" }
            AllowAvailableUninstall = [bool]$m.allowAvailableUninstall
            ReturnCodesSummary = if (@($m.returnCodes).Count -gt 0) { (@($m.returnCodes) | ConvertTo-Json -Compress -Depth 5) } else { "" }
            # The raw structured objects behind the two summary strings
            # above - only used if the drift-compare dialog needs to
            # actually REVERT one of these two composite fields back to the
            # local value (repopulating the detection-rule sub-form or the
            # return-codes grid needs the real object, not the JSON string
            # used for the diff/display).
            DetectionRule = $m.detectionRule
            ReturnCodes   = @($m.returnCodes)
        }
    }

    if ($isDuplicate) {
        # Fetches what's actually live in Intune right now and repopulates
        # the fields above (which start out holding local guesses/templates)
        # once it comes back, so Update Metadata edits a real, current
        # picture instead of possibly overwriting a correct Intune value
        # with a stale local guess.
        $dlg.Add_Shown({
            $lblCreateStatus.ForeColor = [System.Drawing.Color]::DimGray
            $lblCreateStatus.Text = "Loading current metadata from Intune..."

            # Fresh aliases for the nested -OnComplete closure - see note at
            # the top of this function for why this matters.
            $existingAppIdRef = $ExistingAppId
            $lblCreateStatusRef = $lblCreateStatus
            $txtCreateNameRef = $txtCreateName
            $txtDescRef = $txtDesc
            $txtPublisherRef = $txtPublisher
            $txtOwnerRef = $txtOwner
            $txtDeveloperRef = $txtDeveloper
            $txtInfoUrlRef = $txtInfoUrl
            $txtPrivacyUrlRef = $txtPrivacyUrl
            $txtNotesRef = $txtNotes
            $txtInstallRef = $txtInstall
            $txtUninstallRef = $txtUninstall
            $txtDetectionRef = $txtDetection
            $cmbContextRef = $cmbContext
            $chkArchX86Ref = $chkArchX86
            $chkArchX64Ref = $chkArchX64
            $chkArchArm64Ref = $chkArchArm64
            $cmbMinOSRef = $cmbMinOS
            $minOsMapRef = $minOsMap
            $cmbDetectionTypeRef = $cmbDetectionType
            $operatorMapRef = $operatorMap
            $txtMsiCodeRef = $txtMsiCode
            $cmbMsiOperatorRef = $cmbMsiOperator
            $txtMsiVersionRef = $txtMsiVersion
            $txtFilePathRef = $txtFilePath
            $txtFileNameRef = $txtFileName
            $chkFileCheck32Ref = $chkFileCheck32
            $cmbFileDetTypeRef = $cmbFileDetType
            $fileDetTypeMapRef = $fileDetTypeMap
            $cmbFileOperatorRef = $cmbFileOperator
            $txtFileDetValueRef = $txtFileDetValue
            $txtRegKeyPathRef = $txtRegKeyPath
            $txtRegValueNameRef = $txtRegValueName
            $chkRegCheck32Ref = $chkRegCheck32
            $cmbRegDetTypeRef = $cmbRegDetType
            $regDetTypeMapRef = $regDetTypeMap
            $cmbRegOperatorRef = $cmbRegOperator
            $txtRegDetValueRef = $txtRegDetValue
            $localSnapshotRef = $localSnapshot
            $fetchedDependencyBoxRef = $fetchedDependencyBox
            $clbDepsRef = $clbDeps
            $depNameByLabelRef = $depNameByLabel
            $txtDiskSpaceRef = $txtDiskSpace
            $txtMemoryRef = $txtMemory
            $txtProcessorsRef = $txtProcessors
            $txtCpuSpeedRef = $txtCpuSpeed
            $txtInstallTimeRef = $txtInstallTime
            $cmbRestartBehaviorRef = $cmbRestartBehavior
            $restartBehaviorMapRef = $restartBehaviorMap
            $chkAllowUninstallRef = $chkAllowUninstall
            $grdReturnCodesRef = $grdReturnCodes

            Start-AppMetadataFetch -AppId $existingAppIdRef -OnComplete {
                param($ok, $errMsg, $data)
                if (-not $ok) {
                    $lblCreateStatusRef.ForeColor = [System.Drawing.Color]::DarkOrange
                    $lblCreateStatusRef.Text = "Could not load current metadata ($errMsg) - fields above are local guesses, not confirmed live values."
                    return
                }
                if ($data.DisplayName)              { $txtCreateNameRef.Text = $data.DisplayName }
                if ($null -ne $data.Description)    { $txtDescRef.Text = $data.Description }
                if ($null -ne $data.Publisher)      { $txtPublisherRef.Text = $data.Publisher }
                if ($null -ne $data.Owner)          { $txtOwnerRef.Text = $data.Owner }
                if ($null -ne $data.Developer)      { $txtDeveloperRef.Text = $data.Developer }
                if ($null -ne $data.InformationUrl) { $txtInfoUrlRef.Text = $data.InformationUrl }
                if ($null -ne $data.PrivacyInformationUrl) { $txtPrivacyUrlRef.Text = $data.PrivacyInformationUrl }
                if ($null -ne $data.Notes)          { $txtNotesRef.Text = $data.Notes }
                if ($null -ne $data.InstallCommandLine)   { $txtInstallRef.Text = $data.InstallCommandLine }
                if ($null -ne $data.UninstallCommandLine) { $txtUninstallRef.Text = $data.UninstallCommandLine }
                # Live Intune value replaces whatever local held, once it's
                # actually back - fixes a real gap where "Save local
                # copy..." used to hardcode dependencies as always empty
                # for every existing app, regardless of what Intune had.
                if ($null -ne $data.Dependencies) {
                    $fetchedDependencyBoxRef.Names = @($data.Dependencies)
                    # Same reasoning as the local-metadata prefill above -
                    # pre-checks the picker to match exactly what's live in
                    # Intune, cleared first so the picker's own default
                    # pre-check doesn't linger if the real data doesn't
                    # include it.
                    for ($ci = 0; $ci -lt $clbDepsRef.Items.Count; $ci++) { $clbDepsRef.SetItemChecked($ci, $false) }
                    for ($ci = 0; $ci -lt $clbDepsRef.Items.Count; $ci++) {
                        $itemLabel = [string]$clbDepsRef.Items[$ci]
                        if ($depNameByLabelRef.ContainsKey($itemLabel) -and (@($data.Dependencies) -contains $depNameByLabelRef[$itemLabel])) {
                            $clbDepsRef.SetItemChecked($ci, $true)
                        }
                    }
                }

                # Shown even though these controls are disabled for an
                # existing app (Graph rejects PATCHing them post-creation,
                # same as Context/Architecture/MinOS) - same reasoning
                # already established for those: a wrong/default guess
                # displayed next to a grayed-out control would be actively
                # misleading about what's really set.
                if ($null -ne $data.MinDiskSpaceMB)     { $txtDiskSpaceRef.Text = [string]$data.MinDiskSpaceMB }
                if ($null -ne $data.MinMemoryMB)        { $txtMemoryRef.Text = [string]$data.MinMemoryMB }
                if ($null -ne $data.MinProcessors)      { $txtProcessorsRef.Text = [string]$data.MinProcessors }
                if ($null -ne $data.MinCpuSpeedMHz)     { $txtCpuSpeedRef.Text = [string]$data.MinCpuSpeedMHz }
                if ($null -ne $data.InstallTimeMinutes) { $txtInstallTimeRef.Text = [string]$data.InstallTimeMinutes }
                if ($data.DeviceRestartBehavior) {
                    $rbKey = $restartBehaviorMapRef.Keys | Where-Object { $restartBehaviorMapRef[$_] -eq $data.DeviceRestartBehavior } | Select-Object -First 1
                    if ($rbKey) { $cmbRestartBehaviorRef.SelectedItem = $rbKey }
                }
                $chkAllowUninstallRef.Checked = [bool]$data.AllowAvailableUninstall
                if (@($data.ReturnCodes).Count -gt 0) {
                    $grdReturnCodesRef.Rows.Clear()
                    foreach ($rc in @($data.ReturnCodes)) {
                        $rcRowIdx = $grdReturnCodesRef.Rows.Add()
                        $grdReturnCodesRef.Rows[$rcRowIdx].Cells["Code"].Value = [string]$rc.returnCode
                        $grdReturnCodesRef.Rows[$rcRowIdx].Cells["Type"].Value = [string]$rc.type
                    }
                }

                if ($data.DetectionRule) {
                    switch ($data.DetectionRule.Type) {
                        "Script" {
                            $cmbDetectionTypeRef.SelectedIndex = 0
                            if ($data.DetectionRule.Script_Content) { $txtDetectionRef.Text = $data.DetectionRule.Script_Content }
                        }
                        "Msi" {
                            $cmbDetectionTypeRef.SelectedIndex = 1
                            $txtMsiCodeRef.Text = $data.DetectionRule.Msi_ProductCode
                            $opKey = $operatorMapRef.Keys | Where-Object { $operatorMapRef[$_] -eq $data.DetectionRule.Msi_VersionOperator } | Select-Object -First 1
                            if ($opKey) { $cmbMsiOperatorRef.SelectedItem = $opKey }
                            $txtMsiVersionRef.Text = $data.DetectionRule.Msi_Version
                        }
                        "File" {
                            $cmbDetectionTypeRef.SelectedIndex = 2
                            $txtFilePathRef.Text = $data.DetectionRule.File_Path
                            $txtFileNameRef.Text = $data.DetectionRule.File_Name
                            $chkFileCheck32Ref.Checked = [bool]$data.DetectionRule.File_Check32Bit
                            $dtKey = $fileDetTypeMapRef.Keys | Where-Object { $fileDetTypeMapRef[$_] -eq $data.DetectionRule.File_DetectionType } | Select-Object -First 1
                            if ($dtKey) { $cmbFileDetTypeRef.SelectedItem = $dtKey }
                            $opKey = $operatorMapRef.Keys | Where-Object { $operatorMapRef[$_] -eq $data.DetectionRule.File_Operator } | Select-Object -First 1
                            if ($opKey) { $cmbFileOperatorRef.SelectedItem = $opKey }
                            $txtFileDetValueRef.Text = $data.DetectionRule.File_DetectionValue
                        }
                        "Registry" {
                            $cmbDetectionTypeRef.SelectedIndex = 3
                            $txtRegKeyPathRef.Text = $data.DetectionRule.Reg_KeyPath
                            $txtRegValueNameRef.Text = $data.DetectionRule.Reg_ValueName
                            $chkRegCheck32Ref.Checked = [bool]$data.DetectionRule.Reg_Check32Bit
                            $dtKey = $regDetTypeMapRef.Keys | Where-Object { $regDetTypeMapRef[$_] -eq $data.DetectionRule.Reg_DetectionType } | Select-Object -First 1
                            if ($dtKey) { $cmbRegDetTypeRef.SelectedItem = $dtKey }
                            $opKey = $operatorMapRef.Keys | Where-Object { $operatorMapRef[$_] -eq $data.DetectionRule.Reg_Operator } | Select-Object -First 1
                            if ($opKey) { $cmbRegOperatorRef.SelectedItem = $opKey }
                            $txtRegDetValueRef.Text = $data.DetectionRule.Reg_DetectionValue
                        }
                    }
                }

                # These three stay disabled either way (Graph rejects changing
                # them via PATCH), but setting the DISPLAYED value even while
                # disabled matters - showing a wrong/default guess next to a
                # grayed-out control would be actively misleading about what's
                # really set.
                if ($data.RunAsAccount) {
                    $cmbContextRef.SelectedItem = if ($data.RunAsAccount -eq "user") { "User" } else { "System" }
                }
                # Confirmed directly from Microsoft's own win32LobApp docs:
                # when an app uses MULTIPLE architectures, that's actually
                # represented via the separate allowedArchitectures property
                # - and setting that forces applicableArchitectures to the
                # literal string "none" as a side effect, not blank/null.
                # Reading only applicableArchitectures (as this used to)
                # meant any multi-architecture app came back as "none",
                # matched nothing, and silently left every checkbox
                # unchecked - which is exactly what this looked like.
                # allowedArchitectures is checked first and preferred
                # whenever it holds a real, non-"none" value; single-
                # architecture apps that only ever set applicableArchitectures
                # still fall back to that correctly.
                $archSource = $null
                if ($data.AllowedArchitectures -and $data.AllowedArchitectures -ne "none") {
                    $archSource = $data.AllowedArchitectures
                }
                elseif ($data.ApplicableArchitectures -and $data.ApplicableArchitectures -ne "none") {
                    $archSource = $data.ApplicableArchitectures
                }
                # Re-normalized into the same canonical, comma-joined
                # "x86,x64,arm64" order the local catalog's own architecture
                # field always uses (see the -join "," that builds it) -
                # Intune has been observed returning this as a
                # PERIOD-separated string (e.g. "x64.arm64") for a
                # multi-architecture app, not comma. Splitting on [,.]
                # handles either separator; re-joining in this fixed order
                # (rather than whatever order/separator Intune used) means
                # both the checkbox pre-fill right below AND the
                # local-vs-Intune comparison further down are comparing the
                # actual architecture SET, not incidental formatting -
                # without this, splitting a period-joined value on a comma
                # leaves it as one unmatched token, so every checkbox below
                # would silently end up unchecked, and an identical local
                # copy would always be flagged as "different".
                if ($archSource) {
                    $archTokensNorm = @($archSource -split '[,.]' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
                    $archSource = (@("x86","x64","arm64") | Where-Object { $archTokensNorm -contains $_ }) -join ","
                }
                if ($archSource) {
                    $archList = @($archSource -split ',' | ForEach-Object { $_.Trim().ToLower() })
                    $chkArchX86Ref.Checked = $archList -contains "x86"
                    $chkArchX64Ref.Checked = $archList -contains "x64"
                    $chkArchArm64Ref.Checked = $archList -contains "arm64"
                }
                if ($data.MinOSPropertyName) {
                    $matchKey = $minOsMapRef.Keys | Where-Object { $minOsMapRef[$_] -eq $data.MinOSPropertyName } | Select-Object -First 1
                    if ($matchKey) { $cmbMinOSRef.SelectedItem = $matchKey }
                }

                # Compared against whatever was saved locally BEFORE this
                # fetch overwrote the fields above with live values - Intune
                # still wins as the actually-displayed value either way
                # (it's the current truth), but drift from the local copy
                # is worth surfacing rather than silently disappearing the
                # moment this dialog is opened.
                $diffFields = New-Object System.Collections.Generic.List[string]
                if ($localSnapshotRef) {
                    if (([string]$data.Description) -ne ([string]$localSnapshotRef.Description)) { $diffFields.Add("Description") }
                    if (([string]$data.Publisher) -ne ([string]$localSnapshotRef.Publisher)) { $diffFields.Add("Publisher") }
                    if (([string]$data.Owner) -ne ([string]$localSnapshotRef.Owner)) { $diffFields.Add("Owner") }
                    if (([string]$data.Developer) -ne ([string]$localSnapshotRef.Developer)) { $diffFields.Add("Developer") }
                    if (([string]$data.InformationUrl) -ne ([string]$localSnapshotRef.InformationUrl)) { $diffFields.Add("Information URL") }
                    if (([string]$data.PrivacyInformationUrl) -ne ([string]$localSnapshotRef.PrivacyUrl)) { $diffFields.Add("Privacy URL") }
                    if (([string]$data.Notes) -ne ([string]$localSnapshotRef.Notes)) { $diffFields.Add("Notes") }
                    if (([string]$data.InstallCommandLine) -ne ([string]$localSnapshotRef.InstallCommand)) { $diffFields.Add("Install command") }
                    if (([string]$data.UninstallCommandLine) -ne ([string]$localSnapshotRef.UninstallCommand)) { $diffFields.Add("Uninstall command") }
                    if (([string]$archSource) -ne ([string]$localSnapshotRef.Architecture)) { $diffFields.Add("Architecture") }
                    $liveDetSummary = if ($data.DetectionRule) { ($data.DetectionRule | ConvertTo-Json -Compress -Depth 5) } else { "" }
                    if ($liveDetSummary -ne $localSnapshotRef.DetectionSummary) { $diffFields.Add("Detection rule") }
                    if (([string]$data.MinDiskSpaceMB) -ne ([string]$localSnapshotRef.MinDiskSpaceMB)) { $diffFields.Add("Disk space requirement") }
                    if (([string]$data.MinMemoryMB) -ne ([string]$localSnapshotRef.MinMemoryMB)) { $diffFields.Add("Memory requirement") }
                    if (([string]$data.MinProcessors) -ne ([string]$localSnapshotRef.MinProcessors)) { $diffFields.Add("Min. processors requirement") }
                    if (([string]$data.MinCpuSpeedMHz) -ne ([string]$localSnapshotRef.MinCpuSpeedMHz)) { $diffFields.Add("Min. CPU speed requirement") }
                    if (([string]$data.InstallTimeMinutes) -ne ([string]$localSnapshotRef.InstallTimeMinutes)) { $diffFields.Add("Install time required") }
                    if (([string]$data.DeviceRestartBehavior) -ne ([string]$localSnapshotRef.DeviceRestartBehavior)) { $diffFields.Add("Device restart behavior") }
                    if (([string][bool]$data.AllowAvailableUninstall) -ne ([string]$localSnapshotRef.AllowAvailableUninstall)) { $diffFields.Add("Allow available uninstall") }
                    $liveReturnCodesSummary = if (@($data.ReturnCodes).Count -gt 0) { (@($data.ReturnCodes) | ConvertTo-Json -Compress -Depth 5) } else { "" }
                    if ($liveReturnCodesSummary -ne $localSnapshotRef.ReturnCodesSummary) { $diffFields.Add("Return codes") }
                }

                if ($archSource) {
                    $lblCreateStatusRef.ForeColor = [System.Drawing.Color]::SeaGreen
                    $statusMsg = "Loaded current metadata from Intune - fields above now reflect what's actually live there."
                    if ($diffFields.Count -gt 0) {
                        $lblCreateStatusRef.ForeColor = [System.Drawing.Color]::DarkOrange
                        $statusMsg += " Differs from the locally saved copy in: $($diffFields -join ', ')."
                    }
                    $lblCreateStatusRef.Text = $statusMsg
                }
                else {
                    # Two genuinely different situations were being shown
                    # as the same generic warning before this fix:
                    #   1. Intune explicitly has this set to "None" (shown
                    #      in the portal as "Check operating system
                    #      architecture: No") - a real, valid, intentional
                    #      setting meaning this app doesn't check
                    #      architecture at all. Not an error, and not
                    #      something this tool can currently reproduce -
                    #      there's no checkbox here for "none of the
                    #      above", only x86/x64/arm64 - but it deserves an
                    #      accurate message, not one implying the fetch
                    #      came back broken.
                    #   2. Genuinely missing/empty in BOTH fields - actually
                    #      unexpected, and the "select manually" guidance
                    #      still applies there.
                    $isExplicitlyNone = ($data.ApplicableArchitectures -eq "none") -or ($data.AllowedArchitectures -eq "none")
                    $lblCreateStatusRef.ForeColor = [System.Drawing.Color]::DarkOrange
                    if ($isExplicitlyNone) {
                        $lblCreateStatusRef.Text = "This app is set to NOT check architecture at all in Intune (`"Check operating system architecture: No`"). This tool has no equivalent for that - only x86/x64/arm64 checkboxes - so none are pre-checked. Deploying an update through this tool requires picking at least one, which won't exactly match the original `"no check`" setting."
                    }
                    else {
                        # Genuinely no usable value in either field - surfaced
                        # directly here instead of leaving every architecture
                        # checkbox silently unchecked with no explanation, only
                        # to be discovered later via a confusing "check at least
                        # one" validation error on submit.
                        $lblCreateStatusRef.Text = "Loaded current metadata from Intune - but it didn't return a usable architecture value, so none are pre-checked below. Select the correct one(s) manually."
                    }
                }

                # Every field above already holds Intune's value - this only
                # offers a look at what actually differs and a way to pick
                # individual fields back to the local value, it never
                # changes the outcome on its own. Built as flat, explicit
                # per-field checks against $diffFields/$keepLocalFields
                # (not scriptblocks built inside a loop) - a closure built
                # per loop iteration to capture that iteration's own control
                # reference is exactly the class of bug already hunted down
                # elsewhere in this file (self-referencing/loop-captured
                # closures), so this sidesteps it entirely by never doing
                # that in the first place.
                if ($diffFields.Count -gt 0) {
                    $driftRows = New-Object System.Collections.Generic.List[object]
                    if ($diffFields -contains "Description")              { $driftRows.Add([pscustomobject]@{ Field = "Description"; Local = $localSnapshotRef.Description; Intune = [string]$data.Description }) }
                    if ($diffFields -contains "Publisher")                { $driftRows.Add([pscustomobject]@{ Field = "Publisher"; Local = $localSnapshotRef.Publisher; Intune = [string]$data.Publisher }) }
                    if ($diffFields -contains "Owner")                    { $driftRows.Add([pscustomobject]@{ Field = "Owner"; Local = $localSnapshotRef.Owner; Intune = [string]$data.Owner }) }
                    if ($diffFields -contains "Developer")                { $driftRows.Add([pscustomobject]@{ Field = "Developer"; Local = $localSnapshotRef.Developer; Intune = [string]$data.Developer }) }
                    if ($diffFields -contains "Information URL")         { $driftRows.Add([pscustomobject]@{ Field = "Information URL"; Local = $localSnapshotRef.InformationUrl; Intune = [string]$data.InformationUrl }) }
                    if ($diffFields -contains "Privacy URL")              { $driftRows.Add([pscustomobject]@{ Field = "Privacy URL"; Local = $localSnapshotRef.PrivacyUrl; Intune = [string]$data.PrivacyInformationUrl }) }
                    if ($diffFields -contains "Notes")                    { $driftRows.Add([pscustomobject]@{ Field = "Notes"; Local = $localSnapshotRef.Notes; Intune = [string]$data.Notes }) }
                    if ($diffFields -contains "Install command")          { $driftRows.Add([pscustomobject]@{ Field = "Install command"; Local = $localSnapshotRef.InstallCommand; Intune = [string]$data.InstallCommandLine }) }
                    if ($diffFields -contains "Uninstall command")        { $driftRows.Add([pscustomobject]@{ Field = "Uninstall command"; Local = $localSnapshotRef.UninstallCommand; Intune = [string]$data.UninstallCommandLine }) }
                    if ($diffFields -contains "Architecture")             { $driftRows.Add([pscustomobject]@{ Field = "Architecture"; Local = $localSnapshotRef.Architecture; Intune = [string]$archSource }) }
                    if ($diffFields -contains "Detection rule")           { $driftRows.Add([pscustomobject]@{ Field = "Detection rule"; Local = $localSnapshotRef.DetectionSummary; Intune = $liveDetSummary }) }
                    if ($diffFields -contains "Disk space requirement")   { $driftRows.Add([pscustomobject]@{ Field = "Disk space requirement"; Local = [string]$localSnapshotRef.MinDiskSpaceMB; Intune = [string]$data.MinDiskSpaceMB }) }
                    if ($diffFields -contains "Memory requirement")       { $driftRows.Add([pscustomobject]@{ Field = "Memory requirement"; Local = [string]$localSnapshotRef.MinMemoryMB; Intune = [string]$data.MinMemoryMB }) }
                    if ($diffFields -contains "Min. processors requirement")  { $driftRows.Add([pscustomobject]@{ Field = "Min. processors requirement"; Local = [string]$localSnapshotRef.MinProcessors; Intune = [string]$data.MinProcessors }) }
                    if ($diffFields -contains "Min. CPU speed requirement")   { $driftRows.Add([pscustomobject]@{ Field = "Min. CPU speed requirement"; Local = [string]$localSnapshotRef.MinCpuSpeedMHz; Intune = [string]$data.MinCpuSpeedMHz }) }
                    if ($diffFields -contains "Install time required")    { $driftRows.Add([pscustomobject]@{ Field = "Install time required"; Local = [string]$localSnapshotRef.InstallTimeMinutes; Intune = [string]$data.InstallTimeMinutes }) }
                    if ($diffFields -contains "Device restart behavior")  { $driftRows.Add([pscustomobject]@{ Field = "Device restart behavior"; Local = [string]$localSnapshotRef.DeviceRestartBehavior; Intune = [string]$data.DeviceRestartBehavior }) }
                    if ($diffFields -contains "Allow available uninstall") { $driftRows.Add([pscustomobject]@{ Field = "Allow available uninstall"; Local = [string]$localSnapshotRef.AllowAvailableUninstall; Intune = [string][bool]$data.AllowAvailableUninstall }) }
                    if ($diffFields -contains "Return codes")             { $driftRows.Add([pscustomobject]@{ Field = "Return codes"; Local = $localSnapshotRef.ReturnCodesSummary; Intune = $liveReturnCodesSummary }) }

                    $keepLocalFields = @(Show-MetadataDriftDialog -Rows $driftRows.ToArray())

                    if ($keepLocalFields.Count -gt 0) {
                        if ($keepLocalFields -contains "Description")          { $txtDescRef.Text = $localSnapshotRef.Description }
                        if ($keepLocalFields -contains "Publisher")            { $txtPublisherRef.Text = $localSnapshotRef.Publisher }
                        if ($keepLocalFields -contains "Owner")                { $txtOwnerRef.Text = $localSnapshotRef.Owner }
                        if ($keepLocalFields -contains "Developer")            { $txtDeveloperRef.Text = $localSnapshotRef.Developer }
                        if ($keepLocalFields -contains "Information URL")      { $txtInfoUrlRef.Text = $localSnapshotRef.InformationUrl }
                        if ($keepLocalFields -contains "Privacy URL")          { $txtPrivacyUrlRef.Text = $localSnapshotRef.PrivacyUrl }
                        if ($keepLocalFields -contains "Notes")                { $txtNotesRef.Text = $localSnapshotRef.Notes }
                        if ($keepLocalFields -contains "Install command")      { $txtInstallRef.Text = $localSnapshotRef.InstallCommand }
                        if ($keepLocalFields -contains "Uninstall command")    { $txtUninstallRef.Text = $localSnapshotRef.UninstallCommand }
                        if ($keepLocalFields -contains "Architecture") {
                            $localArchList = @([string]$localSnapshotRef.Architecture -split ',' | ForEach-Object { $_.Trim().ToLower() })
                            $chkArchX86Ref.Checked = $localArchList -contains "x86"
                            $chkArchX64Ref.Checked = $localArchList -contains "x64"
                            $chkArchArm64Ref.Checked = $localArchList -contains "arm64"
                        }
                        # Mirrors the local-prefill switch earlier in this
                        # function almost exactly - same field-by-field
                        # mapping, just re-pointed at $localSnapshotRef's
                        # raw DetectionRule instead of $m.detectionRule, and
                        # using the *Ref control aliases this nested closure
                        # actually has in scope.
                        if ($keepLocalFields -contains "Detection rule" -and $localSnapshotRef.DetectionRule) {
                            $localDetRule = $localSnapshotRef.DetectionRule
                            switch ($localDetRule.Type) {
                                "Script" {
                                    $cmbDetectionTypeRef.SelectedIndex = 0
                                    if ($localDetRule.Script_Content) { $txtDetectionRef.Text = $localDetRule.Script_Content }
                                }
                                "Msi" {
                                    $cmbDetectionTypeRef.SelectedIndex = 1
                                    $txtMsiCodeRef.Text = $localDetRule.Msi_ProductCode
                                    $opKey = $operatorMapRef.Keys | Where-Object { $operatorMapRef[$_] -eq $localDetRule.Msi_VersionOperator } | Select-Object -First 1
                                    if ($opKey) { $cmbMsiOperatorRef.SelectedItem = $opKey }
                                    $txtMsiVersionRef.Text = $localDetRule.Msi_Version
                                }
                                "File" {
                                    $cmbDetectionTypeRef.SelectedIndex = 2
                                    $txtFilePathRef.Text = $localDetRule.File_Path
                                    $txtFileNameRef.Text = $localDetRule.File_Name
                                    $chkFileCheck32Ref.Checked = [bool]$localDetRule.File_Check32Bit
                                    $dtKey = $fileDetTypeMapRef.Keys | Where-Object { $fileDetTypeMapRef[$_] -eq $localDetRule.File_DetectionType } | Select-Object -First 1
                                    if ($dtKey) { $cmbFileDetTypeRef.SelectedItem = $dtKey }
                                    $opKey = $operatorMapRef.Keys | Where-Object { $operatorMapRef[$_] -eq $localDetRule.File_Operator } | Select-Object -First 1
                                    if ($opKey) { $cmbFileOperatorRef.SelectedItem = $opKey }
                                    $txtFileDetValueRef.Text = $localDetRule.File_DetectionValue
                                }
                                "Registry" {
                                    $cmbDetectionTypeRef.SelectedIndex = 3
                                    $txtRegKeyPathRef.Text = $localDetRule.Reg_KeyPath
                                    $txtRegValueNameRef.Text = $localDetRule.Reg_ValueName
                                    $chkRegCheck32Ref.Checked = [bool]$localDetRule.Reg_Check32Bit
                                    $dtKey = $regDetTypeMapRef.Keys | Where-Object { $regDetTypeMapRef[$_] -eq $localDetRule.Reg_DetectionType } | Select-Object -First 1
                                    if ($dtKey) { $cmbRegDetTypeRef.SelectedItem = $dtKey }
                                    $opKey = $operatorMapRef.Keys | Where-Object { $operatorMapRef[$_] -eq $localDetRule.Reg_Operator } | Select-Object -First 1
                                    if ($opKey) { $cmbRegOperatorRef.SelectedItem = $opKey }
                                    $txtRegDetValueRef.Text = $localDetRule.Reg_DetectionValue
                                }
                            }
                        }
                        if ($keepLocalFields -contains "Disk space requirement")        { $txtDiskSpaceRef.Text = [string]$localSnapshotRef.MinDiskSpaceMB }
                        if ($keepLocalFields -contains "Memory requirement")            { $txtMemoryRef.Text = [string]$localSnapshotRef.MinMemoryMB }
                        if ($keepLocalFields -contains "Min. processors requirement")   { $txtProcessorsRef.Text = [string]$localSnapshotRef.MinProcessors }
                        if ($keepLocalFields -contains "Min. CPU speed requirement")    { $txtCpuSpeedRef.Text = [string]$localSnapshotRef.MinCpuSpeedMHz }
                        if ($keepLocalFields -contains "Install time required")         { $txtInstallTimeRef.Text = [string]$localSnapshotRef.InstallTimeMinutes }
                        if ($keepLocalFields -contains "Device restart behavior") {
                            $rbKeyLocal = $restartBehaviorMapRef.Keys | Where-Object { $restartBehaviorMapRef[$_] -eq $localSnapshotRef.DeviceRestartBehavior } | Select-Object -First 1
                            if ($rbKeyLocal) { $cmbRestartBehaviorRef.SelectedItem = $rbKeyLocal }
                        }
                        if ($keepLocalFields -contains "Allow available uninstall") { $chkAllowUninstallRef.Checked = [bool]$localSnapshotRef.AllowAvailableUninstall }
                        if ($keepLocalFields -contains "Return codes" -and $localSnapshotRef.ReturnCodes) {
                            $grdReturnCodesRef.Rows.Clear()
                            foreach ($rc in @($localSnapshotRef.ReturnCodes)) {
                                $rcRowIdxLocal = $grdReturnCodesRef.Rows.Add()
                                $grdReturnCodesRef.Rows[$rcRowIdxLocal].Cells["Code"].Value = [string]$rc.returnCode
                                $grdReturnCodesRef.Rows[$rcRowIdxLocal].Cells["Type"].Value = [string]$rc.type
                            }
                        }
                        $lblCreateStatusRef.ForeColor = [System.Drawing.Color]::DarkOrange
                        $lblCreateStatusRef.Text = "Loaded current metadata from Intune - kept your local value for: $($keepLocalFields -join ', ')."
                    }
                }
            }.GetNewClosure()
        }.GetNewClosure())
    }

    $dlg.CancelButton = $btnCancel
    Set-Theme -Control $dlg
    [void]$dlg.ShowDialog($form)
    return $resultBox
}

# ---------------------------------------------------------------
# Targeted (single-app) group creation + assignment dialog
# ---------------------------------------------------------------
# Lighter alternative to running the full bulk Assign step just to wire up
# one app: ensures the Entra ID groups this app's requiredFor/availableFor/
# uninstallFor reference exist, then sets ONLY this app's Intune assignments
# to match. Does not touch group membership or any other app.
function Show-TargetedAssignDialog {
    param(
        [string]$AppId,
        [string]$AppName,
        [string[]]$RequiredGroups,
        [string[]]$AvailableGroups,
        [string[]]$UninstallGroups
    )

    if (-not $AppId) {
        [System.Windows.Forms.MessageBox]::Show("This app doesn't have an App ID yet. Use 'Deploy to Intune...' or 'Look up' first.", "No App ID", "OK", "Warning") | Out-Null
        return
    }

    $allGroups = @(@($RequiredGroups) + @($AvailableGroups) + @($UninstallGroups) | Select-Object -Unique)
    if ($allGroups.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("This app has no groups set in Required/Available/Uninstall. Add at least one group first.", "Nothing to assign", "OK", "Warning") | Out-Null
        return
    }

    # Plain local aliases - see note in Start-IntuneAppLookup.
    $tenantId       = $Script:GraphTenantId
    $clientId       = $Script:GraphClientId
    $certThumb      = $Script:GraphCertificateThumbprint
    $targetedScript = $Script:EmbeddedTargetedAssignScript

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Assign Groups - $AppName"
    $dlg.ClientSize = New-Object System.Drawing.Size(560, 560)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $lblIntro = New-Object System.Windows.Forms.Label
    $lblIntro.Text = "Creates any of these Entra ID groups that don't already exist, then sets THIS APP's Intune assignments to match exactly - replacing any existing assignments on this app. Does not touch group membership or any other app."
    $lblIntro.Location = New-Object System.Drawing.Point(15,12)
    $lblIntro.Size = New-Object System.Drawing.Size(530,48)
    $dlg.Controls.Add($lblIntro)

    $lblSummaryHeader = New-Object System.Windows.Forms.Label
    $lblSummaryHeader.Text = "Groups involved ($($allGroups.Count) total):"
    $lblSummaryHeader.Location = New-Object System.Drawing.Point(15,64)
    $lblSummaryHeader.AutoSize = $true
    $dlg.Controls.Add($lblSummaryHeader)

    $summaryLines = New-Object System.Collections.Generic.List[string]
    $summaryLines.Add("REQUIRED ($(@($RequiredGroups).Count)):")
    foreach ($g in $RequiredGroups) { $summaryLines.Add("  - $g") }
    $summaryLines.Add("")
    $summaryLines.Add("AVAILABLE ($(@($AvailableGroups).Count)):")
    foreach ($g in $AvailableGroups) { $summaryLines.Add("  - $g") }
    $summaryLines.Add("")
    $summaryLines.Add("UNINSTALL ($(@($UninstallGroups).Count)):")
    foreach ($g in $UninstallGroups) { $summaryLines.Add("  - $g") }

    $txtSummary = New-Object System.Windows.Forms.TextBox
    $txtSummary.Multiline = $true
    $txtSummary.ReadOnly = $true
    $txtSummary.ScrollBars = "Vertical"
    $txtSummary.Location = New-Object System.Drawing.Point(15,84)
    $txtSummary.Size = New-Object System.Drawing.Size(530,170)
    $txtSummary.Font = New-Object System.Drawing.Font("Consolas", 8.5)
    $txtSummary.Text = ($summaryLines -join "`r`n")
    $dlg.Controls.Add($txtSummary)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Location = New-Object System.Drawing.Point(15,262)
    $lblStatus.Size = New-Object System.Drawing.Size(530,18)
    $dlg.Controls.Add($lblStatus)

    $rtbLog = New-Object System.Windows.Forms.RichTextBox
    $rtbLog.Location = New-Object System.Drawing.Point(15,282)
    $rtbLog.Size = New-Object System.Drawing.Size(530,180)
    $rtbLog.ReadOnly = $true
    $rtbLog.BackColor = [System.Drawing.Color]::FromArgb(13,17,23)
    $rtbLog.ForeColor = [System.Drawing.Color]::Gainsboro
    $rtbLog.Font = New-Object System.Drawing.Font("Consolas", 8.5)
    $dlg.Controls.Add($rtbLog)

    $btnRun = New-Object System.Windows.Forms.Button
    $btnRun.Text = "Assign"
    $btnRun.Location = New-Object System.Drawing.Point(370,476)
    $btnRun.Size = New-Object System.Drawing.Size(85,32)
    $dlg.Controls.Add($btnRun)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Close"
    $btnCancel.Location = New-Object System.Drawing.Point(460,476)
    $btnCancel.Size = New-Object System.Drawing.Size(85,32)
    $dlg.Controls.Add($btnCancel)

    $resultBox = @{ Success = $false }
    $procBox = @{ Proc = $null }

    $btnRun.Add_Click({
        $r = [System.Windows.Forms.MessageBox]::Show(
            "This REPLACES this app's entire Intune assignment list with exactly the $($allGroups.Count) group(s) listed above.`n`nAny assignment currently on this app that isn't in that list - including ones this catalog doesn't know about - will be REMOVED. The log will show the app's current assignments before making any change, so you can Cancel if something looks unexpected.`n`nContinue?",
            "Confirm", "YesNo", "Question")
        if ($r -ne "Yes") { return }

        $configPath = Join-Path $env:TEMP (".itsense_targetedassign_config_" + [guid]::NewGuid().ToString("N") + ".json")
        $resultPath = Join-Path $env:TEMP (".itsense_targetedassign_result_" + [guid]::NewGuid().ToString("N") + ".json")
        $config = [pscustomobject]@{
            TenantId              = $tenantId
            ClientId              = $clientId
            CertificateThumbprint = $certThumb
            AppId                 = $AppId
            RequiredGroups        = @($RequiredGroups)
            AvailableGroups       = @($AvailableGroups)
            UninstallGroups       = @($UninstallGroups)
            OutputResultPath      = $resultPath
        }
        try {
            $configJsonText = $config | ConvertTo-Json -Depth 8 -ErrorAction Stop
            [System.IO.File]::WriteAllText($configPath, $configJsonText, (New-Object System.Text.UTF8Encoding($false)))
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Could not write the config file needed to run this: $($_.Exception.Message)", "Failed to prepare", "OK", "Error") | Out-Null
            return
        }

        $btnRun.Enabled = $false
        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblStatus.Text = "Working... see progress below. Cancel stops it."

        # Fresh aliases for the nested -OnComplete closure - see note in
        # Show-CreateInIntuneDialog.
        $btnRunRef = $btnRun
        $lblStatusRef = $lblStatus
        $resultBoxRef = $resultBox
        $resultPathRef = $resultPath
        $configPathRef = $configPath
        $procBoxRef = $procBox
        $rtbLogRef = $rtbLog

        $procBoxRef.Proc = Start-PipelineProcess -ScriptContent $targetedScript -TempScriptName ".itsense_embedded_targetedassign.ps1" -ArgumentString "-ConfigPath `"$configPathRef`"" -ExtraLogTarget $rtbLog -OnComplete {
            param($code)
            $btnRunRef.Enabled = $true
            $procBoxRef.Proc = $null
            Remove-Item $configPathRef -Force -ErrorAction SilentlyContinue

            if (Test-Path $resultPathRef) {
                try {
                    $result = Get-Content -Path $resultPathRef -Raw | ConvertFrom-Json
                    Remove-Item $resultPathRef -Force -ErrorAction SilentlyContinue
                    if ($result.success) {
                        $resultBoxRef.Success = $true
                        $lblStatusRef.ForeColor = [System.Drawing.Color]::SeaGreen
                        $lblStatusRef.Text = "Success - $($result.groupsCreated) group(s) newly created."
                    }
                    else {
                        Write-DialogError -StatusLabel $lblStatusRef -LogBox $rtbLogRef -ErrorMessage $result.error
                    }
                }
                catch {
                    Write-DialogError -StatusLabel $lblStatusRef -LogBox $rtbLogRef -ErrorMessage "Could not read result (exit code $code)."
                }
            }
            else {
                Write-DialogError -StatusLabel $lblStatusRef -LogBox $rtbLogRef -ErrorMessage "No result written (exit code $code). See progress above."
            }
        }.GetNewClosure()
    }.GetNewClosure())

    $btnCancel.Add_Click({
        if ($procBox.Proc -and -not $procBox.Proc.HasExited) {
            $r = [System.Windows.Forms.MessageBox]::Show("A step is currently running. Stop it and close this dialog?", "Stop and close?", "YesNo", "Warning")
            if ($r -ne "Yes") { return }
            try { $procBox.Proc.Kill() } catch { }
        }
        $dlg.Close()
    }.GetNewClosure())

    $dlg.CancelButton = $btnCancel
    $dlg.AcceptButton = $btnRun
    Set-Theme -Control $dlg
    [void]$dlg.ShowDialog($form)
    return $resultBox.Success
}

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
function Show-BatchDeployDialog {
    param([int[]]$ScopedIndices = @())

    # Plain local aliases - see note in Start-IntuneAppLookup.
    $appsRef      = $Script:Apps
    $tenantId     = $Script:GraphTenantId
    $clientId     = $Script:GraphClientId
    $certThumb    = $Script:GraphCertificateThumbprint
    $createScript = $Script:EmbeddedCreateAppScript
    $unsavedBox   = $Script:UnsavedChangesBox
    $linkedFilePath = $Script:LinkedFilePath

    $candidateApps = if ($ScopedIndices.Count -gt 0) { @($ScopedIndices | ForEach-Object { $appsRef[$_] }) } else { @($appsRef) }
    $isScoped = $ScopedIndices.Count -gt 0

    # Eligible: just no App ID yet (not deployed) - metadata is no longer
    # required up front. An app with saved metadata (from "Save for
    # later...") uses it; one without gets the same defaults
    # Show-CreateInIntuneDialog's own form would pre-fill for a brand-new
    # app (see Get-DefaultAppMetadata), computed and saved into the
    # catalog at actual deploy time below - rather than being excluded
    # from the batch just for never having been opened in that dialog
    # once first. The one real exception: an UNCOMMON app with no saved
    # metadata has no detection script to default to (there's no real
    # install to derive one from), so that specific case is still skipped
    # at deploy time, same as a missing package.
    $eligibleApps = @($candidateApps | Where-Object { -not $_.appId })

    if ($eligibleApps.Count -eq 0) {
        $msg = if ($isScoped) { "None of the selected app(s) need deploying - they all already have an App ID." } else { "No apps need deploying - they all already have an App ID." }
        [System.Windows.Forms.MessageBox]::Show($msg, "Nothing to do", "OK", "Information") | Out-Null
        return
    }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Batch deploy to Intune"
    $dlg.ClientSize = New-Object System.Drawing.Size(660, 630)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $lblIntro = New-Object System.Windows.Forms.Label
    $scopeText = if ($isScoped) { "$($eligibleApps.Count) selected app(s)" } else { "all $($eligibleApps.Count) app(s)" }
    $lblIntro.Text = "Creates $scopeText in Intune, in dependency order where one depends on another. Uses saved metadata where an app has it; otherwise uses the same defaults Deploy to Intune's own form would, and saves them to the catalog. Apps whose package isn't built yet (or, for an uncommon app with no saved metadata, has no detection to default to) are skipped, not failed."
    $lblIntro.Location = New-Object System.Drawing.Point(15,12)
    $lblIntro.Size = New-Object System.Drawing.Size(630,66)
    $dlg.Controls.Add($lblIntro)

    # Package readiness is shown up front, per app, rather than only
    # discovered mid-run - so a missing package can be noticed and fixed
    # before starting, instead of the run just skipping past it silently.
    # Same for whether saved metadata exists or defaults will be used.
    $clbApps = New-Object System.Windows.Forms.CheckedListBox
    $clbApps.Location = New-Object System.Drawing.Point(15,84)
    $clbApps.Size = New-Object System.Drawing.Size(630,240)
    $clbApps.CheckOnClick = $true
    $dlg.Controls.Add($clbApps)
    $itemLabelToApp = @{}
    foreach ($eligibleApp in ($eligibleApps | Sort-Object appName)) {
        $isUncommon = Test-AppIsUncommon -App $eligibleApp
        $pkg = Resolve-AppPackagePath -AppName $eligibleApp.appName -Uncommon $isUncommon
        $tag = if (-not $pkg.Found) {
            "  [package not built yet]"
        }
        elseif (-not $eligibleApp.metadata) {
            if ($isUncommon) { "  [no saved metadata and no Winget ID - can't default detection]" } else { "  [no saved metadata - will use defaults]" }
        }
        else { "" }
        $label = "$($eligibleApp.appName)$tag"
        $itemLabelToApp[$label] = $eligibleApp
        $canCheck = $pkg.Found -and (-not $isUncommon -or $eligibleApp.metadata)
        [void]$clbApps.Items.Add($label, $canCheck)
    }

    $btnSelectAll = New-Object System.Windows.Forms.Button
    $btnSelectAll.Text = "Select all"
    $btnSelectAll.Location = New-Object System.Drawing.Point(15,328)
    $btnSelectAll.Size = New-Object System.Drawing.Size(100,26)
    $dlg.Controls.Add($btnSelectAll)

    $btnSelectNone = New-Object System.Windows.Forms.Button
    $btnSelectNone.Text = "Select none"
    $btnSelectNone.Location = New-Object System.Drawing.Point(125,328)
    $btnSelectNone.Size = New-Object System.Drawing.Size(110,26)
    $dlg.Controls.Add($btnSelectNone)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Location = New-Object System.Drawing.Point(15,362)
    $lblStatus.Size = New-Object System.Drawing.Size(630,36)
    $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($lblStatus)

    $rtbLog = New-Object System.Windows.Forms.RichTextBox
    $rtbLog.Location = New-Object System.Drawing.Point(15,402)
    $rtbLog.Size = New-Object System.Drawing.Size(630,150)
    $rtbLog.ReadOnly = $true
    $rtbLog.BackColor = [System.Drawing.Color]::FromArgb(13,17,23)
    $rtbLog.ForeColor = [System.Drawing.Color]::Gainsboro
    $rtbLog.Font = New-Object System.Drawing.Font("Consolas", 8.5)
    $dlg.Controls.Add($rtbLog)

    $btnDeploy = New-Object System.Windows.Forms.Button
    $btnDeploy.Text = "Deploy selected"
    $btnDeploy.Location = New-Object System.Drawing.Point(455,582)
    $btnDeploy.Size = New-Object System.Drawing.Size(185,32)
    $dlg.Controls.Add($btnDeploy)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"
    $btnClose.Location = New-Object System.Drawing.Point(365,582)
    $btnClose.Size = New-Object System.Drawing.Size(85,32)
    $dlg.Controls.Add($btnClose)

    $procBox = @{ Proc = $null }

    $btnSelectAll.Add_Click({
        for ($ci = 0; $ci -lt $clbApps.Items.Count; $ci++) { $clbApps.SetItemChecked($ci, $true) }
    }.GetNewClosure())
    $btnSelectNone.Add_Click({
        for ($ci = 0; $ci -lt $clbApps.Items.Count; $ci++) { $clbApps.SetItemChecked($ci, $false) }
    }.GetNewClosure())

    # A mutable container, not a plain variable - RunNext needs to call
    # ITSELF again (moving on to the next app) from within its own
    # -OnComplete. .GetNewClosure() captures variables BY VALUE at the
    # moment it's called, not as a live reference to their future state -
    # a plain self-referencing "$RunNext = {...$RunNext...}.GetNewClosure()"
    # would capture $null, since the variable doesn't exist yet at that
    # exact instant. This exact bug already happened once this session (the
    # delete-app dependency retry) - same fix reused here rather than
    # repeating the mistake in a new dialog.
    $RunNextBox = @{ Value = $null }

    $RunNextBox.Value = {
        param($Queue, $QueueIndex, $Results)

        if ($QueueIndex -ge $Queue.Count) {
            $createdCount = @($Results | Where-Object { $_.Status -eq "Created" }).Count
            $skippedCount = @($Results | Where-Object { $_.Status -eq "Skipped" }).Count
            $failedCount  = @($Results | Where-Object { $_.Status -eq "Failed" }).Count
            $btnDeploy.Enabled = $true
            $btnSelectAll.Enabled = $true
            $btnSelectNone.Enabled = $true
            $clbApps.Enabled = $true
            $lblStatus.ForeColor = if ($failedCount -gt 0) { [System.Drawing.Color]::DarkOrange } else { [System.Drawing.Color]::SeaGreen }
            # No longer says "use Save to persist" - stale wording left
            # over from before each successful app started saving directly
            # to disk right after its own creation, inside the loop above,
            # rather than only once at the very end here.
            $lblStatus.Text = "Done - $createdCount created, $skippedCount skipped, $failedCount failed."
            return
        }

        $currentApp = $Queue[$QueueIndex]
        $rtbLog.AppendText("`r`n[$($QueueIndex+1)/$($Queue.Count)] $($currentApp.appName)`r`n")
        $lblStatus.Text = "Deploying $($QueueIndex+1) of $($Queue.Count): $($currentApp.appName)..."

        $isUncommon = Test-AppIsUncommon -App $currentApp
        $pkg = Resolve-AppPackagePath -AppName $currentApp.appName -Uncommon $isUncommon
        if (-not $pkg.Found) {
            $rtbLog.AppendText("  [SKIPPED] Package not built yet: $($pkg.Path)`r`n")
            $Results.Add([pscustomobject]@{ AppName = $currentApp.appName; Status = "Skipped"; Message = "Package not built yet" })
            # $RunNextBox directly, not an alias - still the outer
            # scriptblock's own direct body at this point, not the nested
            # -OnComplete closure further below, so no alias is needed (or
            # would even be defined yet) here.
            & $RunNextBox.Value -Queue $Queue -QueueIndex ($QueueIndex + 1) -Results $Results
            return
        }

        # An app with no saved metadata gets the same defaults
        # Show-CreateInIntuneDialog's own form would pre-fill for it - see
        # Get-DefaultAppMetadata. $usedDefaults is threaded through to the
        # success handler below so it knows to actually save this computed
        # metadata into the catalog alongside the new App ID, same as if
        # "Save for later..." had been done first.
        $usedDefaults = -not $currentApp.metadata
        $effectiveMetadata = if ($currentApp.metadata) { $currentApp.metadata } else { Get-DefaultAppMetadata -AppName $currentApp.appName -WingetId $currentApp.wingetId -Uncommon $isUncommon }
        if (-not $effectiveMetadata.detectionRule) {
            # Calls out the Winget ID specifically, not just "uncommon" -
            # a blank Winget ID IS what makes Test-AppIsUncommon call this
            # app uncommon in the first place (see its own definition), so
            # for an app that was actually meant to be a winget app, a
            # missing/typo'd ID here is the single most likely, and most
            # directly fixable, reason detection couldn't be defaulted.
            $rtbLog.AppendText("  [SKIPPED] No detection available - this app has no Winget ID (so it's treated as uncommon) and no saved metadata to default detection from. If it should be a winget app, set its Winget ID; otherwise use `"Deploy to Intune...`" to set detection manually. Then re-run.`r`n")
            $Results.Add([pscustomobject]@{ AppName = $currentApp.appName; Status = "Skipped"; Message = "No Winget ID and no detection script available" })
            & $RunNextBox.Value -Queue $Queue -QueueIndex ($QueueIndex + 1) -Results $Results
            return
        }
        if ($usedDefaults) {
            $rtbLog.AppendText("  [i] No saved metadata - using the same defaults Deploy to Intune's own form would.`r`n")
        }

        # Dependency names resolved to App IDs at the moment each app is
        # actually about to be created, not once up front - a dependency
        # earlier in this SAME batch may only have just received its own
        # App ID a few seconds ago, from an earlier step in this loop.
        $resolvedDepIds = New-Object System.Collections.Generic.List[string]
        foreach ($depName in @($effectiveMetadata.dependencies)) {
            $depApp = $appsRef | Where-Object { $_.appName -eq $depName } | Select-Object -First 1
            if ($depApp -and $depApp.appId) {
                $resolvedDepIds.Add($depApp.appId)
            }
            else {
                $rtbLog.AppendText("  [!] Dependency `"$depName`" has no App ID yet - skipping just that dependency, not the whole app.`r`n")
            }
        }

        $configPath = Join-Path $env:TEMP (".itsense_batchdeploy_config_" + [guid]::NewGuid().ToString("N") + ".json")
        $resultPath = Join-Path $env:TEMP (".itsense_batchdeploy_result_" + [guid]::NewGuid().ToString("N") + ".json")

        $config = [pscustomobject]@{
            TenantId                = $tenantId
            ClientId                = $clientId
            CertificateThumbprint   = $certThumb
            Mode                    = "Create"
            ExistingAppId           = ""
            AppName                 = $currentApp.appName
            Description             = $effectiveMetadata.description
            Publisher               = $effectiveMetadata.publisher
            Owner                   = $effectiveMetadata.owner
            Developer               = $effectiveMetadata.developer
            InformationUrl          = $effectiveMetadata.informationUrl
            PrivacyUrl              = $effectiveMetadata.privacyUrl
            Notes                   = $effectiveMetadata.notes
            InstallCommand          = $effectiveMetadata.installCommand
            UninstallCommand        = $effectiveMetadata.uninstallCommand
            DetectionRule           = $effectiveMetadata.detectionRule
            InstallContext          = $effectiveMetadata.installContext
            Architecture            = $effectiveMetadata.architecture
            MinOSVersionKey         = $effectiveMetadata.minOSKey
            # Previously omitted here entirely (this config never had these
            # fields at all) - the embedded create script silently fell back
            # to ITS OWN internal defaults for them instead, which for
            # DeviceRestartBehavior ("suppress") and ReturnCodes (none at
            # all) actually differed from what Deploy to Intune's own form
            # defaults to ("basedOnReturnCode" and the standard 5 rows) -
            # every batch-deployed app was silently getting different
            # requirements/return-code/restart-behavior settings than a
            # manually-created one, not just ones using generated defaults.
            MinDiskSpaceMB          = $effectiveMetadata.minDiskSpaceMB
            MinMemoryMB             = $effectiveMetadata.minMemoryMB
            MinProcessors           = $effectiveMetadata.minProcessors
            MinCpuSpeedMHz          = $effectiveMetadata.minCpuSpeedMHz
            InstallTimeMinutes      = $effectiveMetadata.installTimeMinutes
            DeviceRestartBehavior   = $effectiveMetadata.deviceRestartBehavior
            AllowAvailableUninstall = $effectiveMetadata.allowAvailableUninstall
            ReturnCodes             = @($effectiveMetadata.returnCodes)
            PackagePath             = $pkg.Path
            DependencyAppIds        = @($resolvedDepIds)
            ReplaceContent          = $false
            OutputResultPath        = $resultPath
        }

        try {
            $configJsonText = $config | ConvertTo-Json -Depth 10 -ErrorAction Stop
            [System.IO.File]::WriteAllText($configPath, $configJsonText, (New-Object System.Text.UTF8Encoding($false)))
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Could not write the config file needed to run this: $($_.Exception.Message)", "Failed to prepare", "OK", "Error") | Out-Null
            return
        }

        # Fresh aliases for this nested -OnComplete closure - see note at
        # the top of Show-CreateInIntuneDialog for why this matters here too.
        $currentAppRef = $currentApp
        $queueRef = $Queue
        $queueIndexRef = $QueueIndex
        $resultsRef = $Results
        $configPathRef = $configPath
        $resultPathRef = $resultPath
        $procBoxRef = $procBox
        $rtbLogRef = $rtbLog
        $appsRefRef = $appsRef
        $RunNextBoxRef = $RunNextBox
        $linkedFilePathRef = $linkedFilePath
        $unsavedBoxRef = $unsavedBox
        $usedDefaultsRef = $usedDefaults
        $effectiveMetadataRef = $effectiveMetadata

        $procBoxRef.Proc = Start-PipelineProcess -ScriptContent $createScript -TempScriptName ".itsense_embedded_batchdeploy.ps1" -ArgumentString "-ConfigPath `"$configPathRef`"" -ExtraLogTarget $rtbLogRef -OnComplete {
            param($code)
            $procBoxRef.Proc = $null
            Remove-Item $configPathRef -Force -ErrorAction SilentlyContinue

            $status = "Failed"
            $message = "No result written (exit code $code)."
            if (Test-Path $resultPathRef) {
                try {
                    $result = Get-Content -Path $resultPathRef -Raw | ConvertFrom-Json
                    Remove-Item $resultPathRef -Force -ErrorAction SilentlyContinue
                    if ($result.success) {
                        $status = "Created"
                        $message = "Created"
                        if ($result.appId) {
                            for ($ai = 0; $ai -lt $appsRefRef.Count; $ai++) {
                                if ($appsRefRef[$ai].appName -eq $currentAppRef.appName) {
                                    $appsRefRef[$ai].appId = $result.appId
                                    # The generated defaults are only saved
                                    # into the catalog on actual SUCCESS,
                                    # not the moment they're computed above -
                                    # a failed create (bad detection script,
                                    # Graph rejecting something, etc.)
                                    # shouldn't leave unvalidated, made-up
                                    # metadata sitting in the catalog for an
                                    # app that was never actually deployed.
                                    if ($usedDefaultsRef) {
                                        $appsRefRef[$ai].metadata = $effectiveMetadataRef
                                    }
                                    break
                                }
                            }
                            $unsavedBoxRef.Value = $true
                            # Direct-save after EACH successful app, not just
                            # once at the very end of the whole batch - the
                            # stakes of losing progress here are real: if a
                            # multi-app batch gets interrupted partway
                            # through and nothing was ever saved, re-running
                            # it later would recreate apps that already
                            # exist in Intune, not just redo harmless work.
                            [void](Save-AppsToFile -Path $linkedFilePathRef)
                        }
                        $defaultsNote = if ($usedDefaultsRef) { " - default metadata saved to the catalog" } else { "" }
                        $rtbLogRef.AppendText("  [OK] Created (App ID: $($result.appId))$defaultsNote`r`n")
                    }
                    else {
                        $message = $result.error
                        $rtbLogRef.AppendText("  [FAILED] $($result.error)`r`n")
                    }
                }
                catch {
                    $message = "Could not read result: $($_.Exception.Message)"
                    $rtbLogRef.AppendText("  [FAILED] Could not read result: $($_.Exception.Message)`r`n")
                }
            }
            else {
                $rtbLogRef.AppendText("  [FAILED] $message`r`n")
            }

            $resultsRef.Add([pscustomobject]@{ AppName = $currentAppRef.appName; Status = $status; Message = $message })
            & $RunNextBoxRef.Value -Queue $queueRef -QueueIndex ($queueIndexRef + 1) -Results $resultsRef
        }.GetNewClosure()
    }.GetNewClosure()

    $btnDeploy.Add_Click({
        $checkedLabels = @($clbApps.CheckedItems | ForEach-Object { [string]$_ })
        if ($checkedLabels.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Check at least one app to deploy.", "Nothing selected", "OK", "Warning") | Out-Null
            return
        }

        $checkedApps = New-Object System.Collections.Generic.List[object]
        foreach ($label in $checkedLabels) {
            if ($itemLabelToApp.ContainsKey($label)) { $checkedApps.Add($itemLabelToApp[$label]) }
        }

        $orderResult = Get-DependencyOrderedApps -Apps $checkedApps.ToArray()
        if ($orderResult.CircularNames.Count -gt 0) {
            $names = $orderResult.CircularNames -join ", "
            $r = [System.Windows.Forms.MessageBox]::Show(
                "These apps have a circular dependency and can't be fully ordered: $names`n`nThey'll still be attempted, but one or more may fail to reference a dependency that isn't created yet. Continue anyway?",
                "Circular dependency", "YesNo", "Warning")
            if ($r -ne "Yes") { return }
        }

        $btnDeploy.Enabled = $false
        $btnSelectAll.Enabled = $false
        $btnSelectNone.Enabled = $false
        $clbApps.Enabled = $false
        $rtbLog.Clear()
        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblStatus.Text = "Starting..."

        $resultsList = New-Object System.Collections.Generic.List[object]
        & $RunNextBox.Value -Queue $orderResult.Ordered -QueueIndex 0 -Results $resultsList
    }.GetNewClosure())

    $btnClose.Add_Click({
        if ($procBox.Proc -and -not $procBox.Proc.HasExited) {
            $r = [System.Windows.Forms.MessageBox]::Show(
                "A deployment is currently running. Stop it and close this dialog?`n`nAny app already created in Intune stays created - check the catalog's App ID column afterward.",
                "Stop and close?", "YesNo", "Warning")
            if ($r -ne "Yes") { return }
            try { $procBox.Proc.Kill() } catch { }
        }
        $dlg.Close()
    }.GetNewClosure())
    $dlg.CancelButton = $btnClose
    $dlg.AcceptButton = $btnDeploy

    Set-Theme -Control $dlg
    [void]$dlg.ShowDialog($form)
}


function Show-SyncMetadataDialog {
    param([int[]]$ScopedIndices = @())

    # Plain local aliases - see note in Start-IntuneAppLookup.
    $appsRef      = $Script:Apps
    $tenantId     = $Script:GraphTenantId
    $clientId     = $Script:GraphClientId
    $certThumb    = $Script:GraphCertificateThumbprint
    $syncScript   = $Script:EmbeddedSyncMetadataScript
    $unsavedBox   = $Script:UnsavedChangesBox
    $linkedFilePath = $Script:LinkedFilePath

    # Selected rows (if any, passed in by the caller) scope this to just
    # them; nothing selected checks the whole catalog like Batch Assign
    # and Package apps already do, for the same reason - consistency with
    # how every other selection-aware action in this app already behaves.
    $candidateApps = if ($ScopedIndices.Count -gt 0) { @($ScopedIndices | ForEach-Object { $appsRef[$_] }) } else { @($appsRef) }
    $isScoped = $ScopedIndices.Count -gt 0

    $eligibleApps = @($candidateApps | Where-Object { $_.appId })

    if ($eligibleApps.Count -eq 0) {
        $msg = if ($isScoped) { "None of the selected app(s) have an App ID yet - nothing to sync." } else { "No apps have an App ID yet - nothing to sync." }
        [System.Windows.Forms.MessageBox]::Show($msg, "Nothing to do", "OK", "Information") | Out-Null
        return
    }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Sync metadata from Intune"
    $dlg.ClientSize = New-Object System.Drawing.Size(620, 576)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $lblIntro = New-Object System.Windows.Forms.Label
    $scopeText = if ($isScoped) { "$($eligibleApps.Count) selected app(s)" } else { "all $($eligibleApps.Count) app(s) with an App ID" }
    $lblIntro.Text = "Fetches current metadata from Intune for $scopeText and stores it locally in the catalog. This is READ-ONLY - it never changes anything in Intune itself. An app whose local copy already differs from Intune isn't silently overwritten - a compare dialog opens for it, one app at a time, so you can pick which fields keep your local value before it's applied."
    $lblIntro.Location = New-Object System.Drawing.Point(15,12)
    $lblIntro.Size = New-Object System.Drawing.Size(590,56)
    $dlg.Controls.Add($lblIntro)

    $clbApps = New-Object System.Windows.Forms.CheckedListBox
    $clbApps.Location = New-Object System.Drawing.Point(15,74)
    $clbApps.Size = New-Object System.Drawing.Size(590,260)
    $clbApps.CheckOnClick = $true
    $dlg.Controls.Add($clbApps)
    foreach ($eligibleApp in ($eligibleApps | Sort-Object appName)) {
        [void]$clbApps.Items.Add($eligibleApp.appName, $true)
    }

    $btnSelectAll = New-Object System.Windows.Forms.Button
    $btnSelectAll.Text = "Select all"
    $btnSelectAll.Location = New-Object System.Drawing.Point(15,338)
    $btnSelectAll.Size = New-Object System.Drawing.Size(100,26)
    $dlg.Controls.Add($btnSelectAll)

    $btnSelectNone = New-Object System.Windows.Forms.Button
    $btnSelectNone.Text = "Select none"
    $btnSelectNone.Location = New-Object System.Drawing.Point(125,338)
    $btnSelectNone.Size = New-Object System.Drawing.Size(110,26)
    $dlg.Controls.Add($btnSelectNone)

    # Hidden until a sync run actually has failures to retry - nothing to
    # show before that point, and showing it disabled/greyed the whole
    # time would just be visual noise for the common case where a sync
    # fully succeeds.
    $btnRetryFailed = New-Object System.Windows.Forms.Button
    $btnRetryFailed.Text = "Retry failed only"
    $btnRetryFailed.Location = New-Object System.Drawing.Point(245,338)
    $btnRetryFailed.Size = New-Object System.Drawing.Size(155,26)
    $btnRetryFailed.Visible = $false
    $dlg.Controls.Add($btnRetryFailed)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Location = New-Object System.Drawing.Point(15,372)
    $lblStatus.Size = New-Object System.Drawing.Size(590,36)
    $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($lblStatus)

    $rtbLog = New-Object System.Windows.Forms.RichTextBox
    $rtbLog.Location = New-Object System.Drawing.Point(15,412)
    $rtbLog.Size = New-Object System.Drawing.Size(590,110)
    $rtbLog.ReadOnly = $true
    $rtbLog.BackColor = [System.Drawing.Color]::FromArgb(13,17,23)
    $rtbLog.ForeColor = [System.Drawing.Color]::Gainsboro
    $rtbLog.Font = New-Object System.Drawing.Font("Consolas", 8.5)
    $dlg.Controls.Add($rtbLog)

    $btnSync = New-Object System.Windows.Forms.Button
    $btnSync.Text = "Sync selected"
    $btnSync.Location = New-Object System.Drawing.Point(420,532)
    $btnSync.Size = New-Object System.Drawing.Size(185,32)
    $dlg.Controls.Add($btnSync)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"
    $btnClose.Location = New-Object System.Drawing.Point(330,532)
    $btnClose.Size = New-Object System.Drawing.Size(85,32)
    $dlg.Controls.Add($btnClose)

    $procBox = @{ Proc = $null }
    # Mutable container, not a plain variable - written from within the
    # nested -OnComplete closure below when a sync run finishes, then read
    # from this button's own separate click handler.
    $lastFailedBox = @{ Names = @() }

    $btnSelectAll.Add_Click({
        for ($ci = 0; $ci -lt $clbApps.Items.Count; $ci++) { $clbApps.SetItemChecked($ci, $true) }
    }.GetNewClosure())
    $btnSelectNone.Add_Click({
        for ($ci = 0; $ci -lt $clbApps.Items.Count; $ci++) { $clbApps.SetItemChecked($ci, $false) }
    }.GetNewClosure())
    $btnRetryFailed.Add_Click({
        for ($ci = 0; $ci -lt $clbApps.Items.Count; $ci++) {
            $itemName = [string]$clbApps.Items[$ci]
            $clbApps.SetItemChecked($ci, ($lastFailedBox.Names -contains $itemName))
        }
    }.GetNewClosure())

    $btnSync.Add_Click({
        $checkedNames = @($clbApps.CheckedItems | ForEach-Object { [string]$_ })
        if ($checkedNames.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Check at least one app to sync.", "Nothing selected", "OK", "Warning") | Out-Null
            return
        }

        # Deliberately a plain foreach, not ForEach-Object, for the outer
        # loop here - nesting a Where-Object INSIDE a ForEach-Object would
        # have both blocks fighting over the same $_ variable, silently
        # comparing an app's name against itself instead of against the
        # checked name actually being looked for.
        $configApps = New-Object System.Collections.Generic.List[object]
        foreach ($checkedName in $checkedNames) {
            $matchApp = $eligibleApps | Where-Object { $_.appName -eq $checkedName } | Select-Object -First 1
            if ($matchApp) {
                $configApps.Add([pscustomobject]@{ AppName = $matchApp.appName; AppId = $matchApp.appId })
            }
        }

        $btnSync.Enabled = $false
        $btnSelectAll.Enabled = $false
        $btnSelectNone.Enabled = $false
        $clbApps.Enabled = $false
        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblStatus.Text = "Syncing $($configApps.Count) app(s)..."
        $rtbLog.Clear()

        $configPath = Join-Path $env:TEMP (".itsense_syncmeta_config_" + [guid]::NewGuid().ToString("N") + ".json")
        $resultPath = Join-Path $env:TEMP (".itsense_syncmeta_result_" + [guid]::NewGuid().ToString("N") + ".json")
        $config = [pscustomobject]@{
            TenantId              = $tenantId
            ClientId              = $clientId
            CertificateThumbprint = $certThumb
            Apps                  = $configApps.ToArray()
            OutputResultPath      = $resultPath
        }
        try {
            $configJsonText = $config | ConvertTo-Json -Depth 10 -ErrorAction Stop
            [System.IO.File]::WriteAllText($configPath, $configJsonText, (New-Object System.Text.UTF8Encoding($false)))
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Could not write the config file needed to run this: $($_.Exception.Message)", "Failed to prepare", "OK", "Error") | Out-Null
            return
        }

        # Fresh aliases for the nested -OnComplete closure - see note at the
        # top of Show-CreateInIntuneDialog for why this matters here too.
        $btnSyncRef = $btnSync
        $btnSelectAllRef = $btnSelectAll
        $btnSelectNoneRef = $btnSelectNone
        $clbAppsRef = $clbApps
        $lblStatusRef = $lblStatus
        $resultPathRef = $resultPath
        $configPathRef = $configPath
        $procBoxRef = $procBox
        $rtbLogRef = $rtbLog
        $appsRefRef = $appsRef
        $unsavedBoxRef = $unsavedBox
        $linkedFilePathRef = $linkedFilePath
        $lastFailedBoxRef = $lastFailedBox
        $btnRetryFailedRef = $btnRetryFailed

        $procBoxRef.Proc = Start-PipelineProcess -ScriptContent $syncScript -TempScriptName ".itsense_embedded_syncmeta.ps1" -ArgumentString "-ConfigPath `"$configPathRef`"" -ExtraLogTarget $rtbLog -OnComplete {
            param($code)
            $procBoxRef.Proc = $null
            $btnSyncRef.Enabled = $true
            $btnSelectAllRef.Enabled = $true
            $btnSelectNoneRef.Enabled = $true
            $clbAppsRef.Enabled = $true
            Remove-Item $configPathRef -Force -ErrorAction SilentlyContinue

            if (-not (Test-Path $resultPathRef)) {
                Write-DialogError -StatusLabel $lblStatusRef -LogBox $rtbLogRef -ErrorMessage "No result written (exit code $code). See progress above."
                return
            }

            $result = $null
            try {
                $result = Get-Content -Path $resultPathRef -Raw | ConvertFrom-Json
                Remove-Item $resultPathRef -Force -ErrorAction SilentlyContinue
            }
            catch {
                Write-DialogError -StatusLabel $lblStatusRef -LogBox $rtbLogRef -ErrorMessage "Could not read result (exit code $code): $($_.Exception.Message)"
                return
            }

            if (-not $result.success) {
                Write-DialogError -StatusLabel $lblStatusRef -LogBox $rtbLogRef -ErrorMessage $result.error
                return
            }

            try {
                $okCount = 0
                $reviewedCount = 0
                $totalCount = @($result.results).Count
                $failedNames = New-Object System.Collections.Generic.List[string]
                # Apps with real drift are queued here, not resolved
                # inline - the loop below still needs to finish matching
                # every result against $appsRefRef by name before any
                # review dialog pops up, so a slow/interactive review for
                # app #2 doesn't delay even starting to process app #3..N.
                $reviewQueue = New-Object System.Collections.Generic.List[object]
                foreach ($oneResult in @($result.results)) {
                    if (-not $oneResult.Success) { $failedNames.Add($oneResult.AppName); continue }
                    for ($ai = 0; $ai -lt $appsRefRef.Count; $ai++) {
                        if ($appsRefRef[$ai].appName -eq $oneResult.AppName) {
                            # Not a blind overwrite - an app whose local copy
                            # already differs from what Intune actually has
                            # right now is queued for an interactive
                            # per-field compare below, same one
                            # Show-CreateInIntuneDialog's own auto-fetch
                            # already offers for one app at a time, rather
                            # than silently taking Intune's value.
                            $existingMetadata = $appsRefRef[$ai].metadata
                            $fieldDiffs = Get-CatalogMetadataFieldDiffs -Local $existingMetadata -Remote $oneResult.Metadata
                            if ($existingMetadata -and $fieldDiffs.Count -gt 0) {
                                $reviewQueue.Add([pscustomobject]@{ Index = $ai; AppName = $oneResult.AppName; Local = $existingMetadata; Remote = $oneResult.Metadata; Diffs = $fieldDiffs })
                            }
                            else {
                                $appsRefRef[$ai].metadata = $oneResult.Metadata
                                $okCount++
                            }
                            break
                        }
                    }
                }

                # Reviewed one app at a time, right here - each compare
                # dialog blocks until closed (safe to do from inside this
                # background process's -OnComplete: it still runs on the
                # UI thread, same as everything else in this callback), but
                # it only ever appears for an app that actually has real
                # drift; the common no-drift case above never triggers it.
                foreach ($reviewItem in $reviewQueue) {
                    $driftRows = New-Object System.Collections.Generic.List[object]
                    foreach ($d in $reviewItem.Diffs) {
                        $driftRows.Add([pscustomobject]@{ Field = $d.Field; Local = $d.Local; Intune = $d.Remote })
                    }
                    $keepLocalFields = @(Show-MetadataDriftDialog -Rows $driftRows.ToArray() -AppName $reviewItem.AppName)
                    $mergedMetadata = Merge-CatalogMetadata -Remote $reviewItem.Remote -Local $reviewItem.Local -KeepLocalFields $keepLocalFields
                    $appsRefRef[$reviewItem.Index].metadata = $mergedMetadata
                    $okCount++
                    $reviewedCount++
                    $keptMsg = if ($keepLocalFields.Count -gt 0) { "kept your local value for: $($keepLocalFields -join ', ')" } else { "took Intune's value for everything" }
                    $rtbLogRef.AppendText("  [REVIEWED] $($reviewItem.AppName): $keptMsg`r`n")
                }

                # Shown only when there's actually something to retry -
                # re-checks just the failed apps in the picker so "Sync
                # selected" can be re-run on them directly, instead of
                # manually re-selecting from a list of 50 apps by hand.
                if ($failedNames.Count -gt 0) {
                    $lastFailedBoxRef.Names = @($failedNames)
                    $btnRetryFailedRef.Visible = $true
                }
                else {
                    $btnRetryFailedRef.Visible = $false
                }
                if ($okCount -gt 0) { $unsavedBoxRef.Value = $true }
                # Direct-save, not just staging in memory - same reasoning
                # as "Save for later..."/"Save local copy...": this
                # button's entire job IS the save, with no batching benefit
                # to be had from deferring it, so a separate click
                # afterward just to persist it is pure friction.
                $syncSaveOk = if ($okCount -gt 0) { Save-AppsToFile -Path $linkedFilePathRef } else { $true }
                $summaryParts = New-Object System.Collections.Generic.List[string]
                $summaryParts.Add("$okCount synced")
                if ($reviewedCount -gt 0) { $summaryParts.Add("$reviewedCount of those reviewed") }
                if ($failedNames.Count -gt 0) { $summaryParts.Add("$($failedNames.Count) failed") }
                $summary = ($summaryParts -join ", ") + " of $totalCount."
                if (-not $syncSaveOk) {
                    $lblStatusRef.ForeColor = [System.Drawing.Color]::DarkOrange
                    $lblStatusRef.Text = "$summary Writing to disk was cancelled or failed - use Force save to try again."
                }
                elseif ($failedNames.Count -gt 0) {
                    $lblStatusRef.ForeColor = [System.Drawing.Color]::DarkOrange
                    $lblStatusRef.Text = "$summary See log for what failed."
                }
                else {
                    $lblStatusRef.ForeColor = [System.Drawing.Color]::SeaGreen
                    $lblStatusRef.Text = "$summary"
                }
            }
            catch {
                Write-DialogError -StatusLabel $lblStatusRef -LogBox $rtbLogRef -ErrorMessage "Sync completed, but something went wrong applying the results: $($_.Exception.Message)"
            }
        }.GetNewClosure()
    }.GetNewClosure())

    $btnClose.Add_Click({
        if ($procBox.Proc -and -not $procBox.Proc.HasExited) {
            $r = [System.Windows.Forms.MessageBox]::Show("A sync is currently running. Stop it and close this dialog?", "Stop and close?", "YesNo", "Warning")
            if ($r -ne "Yes") { return }
            try { $procBox.Proc.Kill() } catch { }
        }
        $dlg.Close()
    }.GetNewClosure())
    $dlg.CancelButton = $btnClose
    $dlg.AcceptButton = $btnSync

    Set-Theme -Control $dlg
    [void]$dlg.ShowDialog($form)
}

function Show-BatchAssignDialog {
    param([int[]]$ScopedIndices = @())

    # Plain local aliases - see note in Start-IntuneAppLookup.
    $appsRef      = $Script:Apps
    $tenantId     = $Script:GraphTenantId
    $clientId     = $Script:GraphClientId
    $certThumb    = $Script:GraphCertificateThumbprint
    $batchScript  = $Script:EmbeddedBatchAssignScript

    # Selected rows (if any, passed in by the caller) scope this to just
    # them; nothing selected checks the whole catalog like before.
    $candidateApps = if ($ScopedIndices.Count -gt 0) { @($ScopedIndices | ForEach-Object { $appsRef[$_] }) } else { @($appsRef) }
    $isScoped = $ScopedIndices.Count -gt 0

    $eligibleApps = @($candidateApps | Where-Object {
        $_.appId -and (@($_.requiredFor).Count -gt 0 -or @($_.availableFor).Count -gt 0 -or @($_.uninstallFor).Count -gt 0)
    })

    if ($eligibleApps.Count -eq 0) {
        $msg = if ($isScoped) { "None of the selected app(s) have both an App ID and at least one group set - nothing to check." } else { "No apps have both an App ID and at least one group set - nothing to check." }
        [System.Windows.Forms.MessageBox]::Show($msg, "Nothing to do", "OK", "Information") | Out-Null
        return
    }

    # Config apps array is built once, up front, from a snapshot of the
    # catalog at the moment this dialog opened - both the Preview and
    # (later) Apply runs use this same snapshot, so what Apply does always
    # matches exactly what Preview showed, even if you keep the dialog open
    # a while before applying.
    $appsForScript = @($eligibleApps | ForEach-Object {
        [pscustomobject]@{
            AppName         = $_.appName
            AppId           = $_.appId
            RequiredGroups  = @($_.requiredFor)
            AvailableGroups = @($_.availableFor)
            UninstallGroups = @($_.uninstallFor)
        }
    })

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Batch assign groups"
    $dlg.ClientSize = New-Object System.Drawing.Size(780, 530)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $lblIntro = New-Object System.Windows.Forms.Label
    $scopeText = if ($isScoped) { "$($eligibleApps.Count) of your selected app(s) that have" } else { "every app with" }
    $lblIntro.Text = "Checks $scopeText an App ID and at least one group against Intune's CURRENT assignments. Nothing changes until you click Apply below."
    $lblIntro.Location = New-Object System.Drawing.Point(15,12)
    $lblIntro.Size = New-Object System.Drawing.Size(750,34)
    $dlg.Controls.Add($lblIntro)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Text = "Checking $($eligibleApps.Count) app(s)..."
    $lblStatus.Location = New-Object System.Drawing.Point(15,50)
    $lblStatus.Size = New-Object System.Drawing.Size(750,20)
    $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($lblStatus)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(15,76)
    $grid.Size = New-Object System.Drawing.Size(750,210)
    $grid.ReadOnly = $true
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.SelectionMode = "FullRowSelect"
    $grid.MultiSelect = $false
    $grid.AutoSizeColumnsMode = "Fill"
    $grid.RowHeadersVisible = $false
    $grid.AutoGenerateColumns = $false
    $grid.BackgroundColor = [System.Drawing.SystemColors]::Window

    $colApp = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colApp.Name = "App"; $colApp.HeaderText = "App"; $colApp.FillWeight = 50
    $grid.Columns.Add($colApp) | Out-Null
    $colAdd = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colAdd.Name = "Add"; $colAdd.HeaderText = "Will add"; $colAdd.FillWeight = 25
    $grid.Columns.Add($colAdd) | Out-Null
    $colRemove = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colRemove.Name = "Remove"; $colRemove.HeaderText = "Will remove"; $colRemove.FillWeight = 25
    $grid.Columns.Add($colRemove) | Out-Null
    $dlg.Controls.Add($grid)

    $rtbLog = New-Object System.Windows.Forms.RichTextBox
    $rtbLog.Location = New-Object System.Drawing.Point(15,296)
    $rtbLog.Size = New-Object System.Drawing.Size(750,170)
    $rtbLog.ReadOnly = $true
    $rtbLog.BackColor = [System.Drawing.Color]::FromArgb(13,17,23)
    $rtbLog.ForeColor = [System.Drawing.Color]::Gainsboro
    $rtbLog.Font = New-Object System.Drawing.Font("Consolas", 8.5)
    $dlg.Controls.Add($rtbLog)

    $btnViewDetails = New-Object System.Windows.Forms.Button
    $btnViewDetails.Text = "View details..."
    $btnViewDetails.Location = New-Object System.Drawing.Point(15,476)
    $btnViewDetails.Size = New-Object System.Drawing.Size(150,32)
    $btnViewDetails.Enabled = $false
    $dlg.Controls.Add($btnViewDetails)

    $btnApply = New-Object System.Windows.Forms.Button
    $btnApply.Text = "Apply changes..."
    $btnApply.Location = New-Object System.Drawing.Point(535,476)
    $btnApply.Size = New-Object System.Drawing.Size(130,32)
    $btnApply.Enabled = $false
    $dlg.Controls.Add($btnApply)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"
    $btnClose.Location = New-Object System.Drawing.Point(675,476)
    $btnClose.Size = New-Object System.Drawing.Size(90,32)
    $dlg.Controls.Add($btnClose)

    $procBox = @{ Proc = $null }
    $previewDataBox = @{ Results = @() }

    # Rebuilds the grid from whatever preview/apply results just came back.
    $populateGrid = {
        param($Results)
        $grid.DataSource = $null
        $grid.Rows.Clear()
        foreach ($r in $Results) {
            $addText = if (@($r.ToAdd).Count -gt 0) { "$(@($r.ToAdd).Count)" } else { "-" }
            $removeText = if (@($r.ToRemove).Count -gt 0) { "$(@($r.ToRemove).Count)" } else { "-" }
            [void]$grid.Rows.Add($r.AppName, $addText, $removeText)
        }
        $previewDataBox.Results = $Results
    }.GetNewClosure()

    # Shared by both the initial Preview run and the later Apply run - only
    # the Mode differs between the two calls.
    $runBatch = {
        param($Mode)

        $btnApply.Enabled = $false
        $btnViewDetails.Enabled = $false
        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblStatus.Text = if ($Mode -eq "Preview") { "Checking $($eligibleApps.Count) app(s)..." } else { "Applying changes to $($eligibleApps.Count) app(s)..." }

        $configPath = Join-Path $env:TEMP (".itsense_batchassign_config_" + [guid]::NewGuid().ToString("N") + ".json")
        $resultPath = Join-Path $env:TEMP (".itsense_batchassign_result_" + [guid]::NewGuid().ToString("N") + ".json")
        $config = [pscustomobject]@{
            TenantId              = $tenantId
            ClientId              = $clientId
            CertificateThumbprint = $certThumb
            Mode                  = $Mode
            Apps                  = $appsForScript
            OutputResultPath      = $resultPath
        }
        try {
            $configJsonText = $config | ConvertTo-Json -Depth 8 -ErrorAction Stop
            [System.IO.File]::WriteAllText($configPath, $configJsonText, (New-Object System.Text.UTF8Encoding($false)))
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Could not write the config file needed to run this: $($_.Exception.Message)", "Failed to prepare", "OK", "Error") | Out-Null
            return
        }

        # Fresh aliases for the nested -OnComplete closure - see note at the
        # top of Show-CreateInIntuneDialog for why this matters here too.
        $btnApplyRef = $btnApply
        $btnViewDetailsRef = $btnViewDetails
        $lblStatusRef = $lblStatus
        $resultPathRef = $resultPath
        $configPathRef = $configPath
        $procBoxRef = $procBox
        $populateGridRef = $populateGrid
        $modeRef = $Mode
        $rtbLogRef = $rtbLog

        $procBoxRef.Proc = Start-PipelineProcess -ScriptContent $batchScript -TempScriptName ".itsense_embedded_batchassign.ps1" -ArgumentString "-ConfigPath `"$configPathRef`"" -ExtraLogTarget $rtbLog -OnComplete {
            param($code)
            $procBoxRef.Proc = $null
            Remove-Item $configPathRef -Force -ErrorAction SilentlyContinue

            if (Test-Path $resultPathRef) {
                try {
                    $result = Get-Content -Path $resultPathRef -Raw | ConvertFrom-Json
                    Remove-Item $resultPathRef -Force -ErrorAction SilentlyContinue
                    if ($result.success) {
                        $results = @($result.data)
                        & $populateGridRef $results
                        $btnViewDetailsRef.Enabled = $true
                        $totalAdd = ($results | ForEach-Object { @($_.ToAdd).Count } | Measure-Object -Sum).Sum
                        $totalRemove = ($results | ForEach-Object { @($_.ToRemove).Count } | Measure-Object -Sum).Sum
                        if ($modeRef -eq "Preview") {
                            $btnApplyRef.Enabled = ($totalAdd -gt 0 -or $totalRemove -gt 0)
                            $lblStatusRef.ForeColor = [System.Drawing.Color]::SeaGreen
                            $lblStatusRef.Text = "Checked $(@($results).Count) app(s) - $totalAdd to add, $totalRemove to remove in total."
                        }
                        else {
                            $lblStatusRef.ForeColor = [System.Drawing.Color]::SeaGreen
                            $lblStatusRef.Text = "Applied. $(@($results).Count) app(s) processed."
                        }
                    }
                    else {
                        Write-DialogError -StatusLabel $lblStatusRef -LogBox $rtbLogRef -ErrorMessage $result.error
                    }
                }
                catch {
                    Write-DialogError -StatusLabel $lblStatusRef -LogBox $rtbLogRef -ErrorMessage "Could not read result (exit code $code)."
                }
            }
            else {
                Write-DialogError -StatusLabel $lblStatusRef -LogBox $rtbLogRef -ErrorMessage "No result written (exit code $code). See progress above."
            }
        }.GetNewClosure()
    }.GetNewClosure()

    $btnViewDetails.Add_Click({
        if ($grid.SelectedRows.Count -eq 0) { return }
        $rowIndex = $grid.SelectedRows[0].Index
        if ($rowIndex -ge $previewDataBox.Results.Count) { return }
        $r = $previewDataBox.Results[$rowIndex]
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add("App: $($r.AppName)")
        $lines.Add("")
        $lines.Add("Will add ($(@($r.ToAdd).Count)):")
        foreach ($g in @($r.ToAdd)) { $lines.Add("  + $g") }
        if (@($r.ToAdd).Count -eq 0) { $lines.Add("  (none)") }
        $lines.Add("")
        $lines.Add("Will remove ($(@($r.ToRemove).Count)):")
        foreach ($g in @($r.ToRemove)) { $lines.Add("  - $g") }
        if (@($r.ToRemove).Count -eq 0) { $lines.Add("  (none)") }
        [System.Windows.Forms.MessageBox]::Show(($lines -join "`r`n"), "Details", "OK", "Information") | Out-Null
    }.GetNewClosure())

    $btnApply.Add_Click({
        $totalAdd = ($previewDataBox.Results | ForEach-Object { @($_.ToAdd).Count } | Measure-Object -Sum).Sum
        $totalRemove = ($previewDataBox.Results | ForEach-Object { @($_.ToRemove).Count } | Measure-Object -Sum).Sum
        $r = [System.Windows.Forms.MessageBox]::Show(
            "This applies the changes shown above to $($eligibleApps.Count) app(s) in Intune: $totalAdd assignment(s) added, $totalRemove removed in total.`n`nAny assignment not in an app's catalog groups gets removed, including ones this catalog doesn't know about. This cannot be undone from here. Continue?",
            "Confirm batch apply", "YesNo", "Warning")
        if ($r -ne "Yes") { return }
        & $runBatch "Apply"
    }.GetNewClosure())

    $btnClose.Add_Click({
        if ($procBox.Proc -and -not $procBox.Proc.HasExited) {
            $r = [System.Windows.Forms.MessageBox]::Show("A step is currently running. Stop it and close this dialog?", "Stop and close?", "YesNo", "Warning")
            if ($r -ne "Yes") { return }
            try { $procBox.Proc.Kill() } catch { }
        }
        $dlg.Close()
    }.GetNewClosure())
    $dlg.CancelButton = $btnClose
    $dlg.AcceptButton = $btnApply

    $dlg.Add_Shown({
        & $runBatch "Preview"
    }.GetNewClosure())

    Set-Theme -Control $dlg
    [void]$dlg.ShowDialog($form)
}

function Show-IntuneOnlyAppsDialog {
    # Plain local aliases - see note in Start-IntuneAppLookup. This dialog's
    # own closures (populateGrid, the action button handler) cannot reliably
    # read or write $Script:-qualified variables directly.
    $appsRef       = $Script:Apps
    $cacheRef      = $Script:IntuneAppsCache
    $unsavedBoxRef = $Script:UnsavedChangesBox
    $linkedFilePathRef = $Script:LinkedFilePath

    # Tracks whether anything changed, so the caller (a plain, top-level
    # button handler - the same proven-safe context every other Refresh-Grid
    # call site uses) can refresh the main catalog grid itself after this
    # dialog closes, rather than this dialog trying to reach across into the
    # main grid's own refresh from deep inside a nested closure.
    $anyAddedBox = @{ Value = $false }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Intune sync check"
    $dlg.ClientSize = New-Object System.Drawing.Size(760, 534)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $lblIntro = New-Object System.Windows.Forms.Label
    $lblIntro.Text = "Compares Intune against this catalog three ways: apps in Intune with no matching catalog entry (`"Not in catalog`"), catalog apps whose Intune app was renamed since (`"Renamed in Intune`" - matched by App ID, not name), and catalog apps whose stored App ID no longer exists in Intune at all (`"Deleted from Intune`")."
    $lblIntro.Location = New-Object System.Drawing.Point(15,12)
    $lblIntro.Size = New-Object System.Drawing.Size(730,48)
    $dlg.Controls.Add($lblIntro)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Location = New-Object System.Drawing.Point(15,68)
    $lblStatus.Size = New-Object System.Drawing.Size(570,20)
    $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($lblStatus)

    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = "Refresh from Intune"
    $btnRefresh.Location = New-Object System.Drawing.Point(595,66)
    $btnRefresh.Size = New-Object System.Drawing.Size(150,26)
    $dlg.Controls.Add($btnRefresh)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(15,96)
    $grid.Size = New-Object System.Drawing.Size(730,368)
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.SelectionMode = "FullRowSelect"
    $grid.MultiSelect = $false
    $grid.AutoSizeColumnsMode = "Fill"
    $grid.RowHeadersVisible = $false
    $grid.AutoGenerateColumns = $false
    $grid.BackgroundColor = [System.Drawing.SystemColors]::Window
    # Commits a checkbox cell's edit the instant it's clicked, rather than
    # leaving it pending until the cell loses focus - a well-known
    # DataGridView quirk (unlike CheckedListBox, there's no CheckOnClick
    # here) where a checkbox visually toggles immediately but its actual
    # .Value doesn't update until the edit is explicitly committed. Without
    # this, checking a box and immediately clicking a button elsewhere -
    # without first clicking away to commit it - reads back the OLD,
    # unchanged value, making it look like the checkbox "can't be checked"
    # at all.
    $grid.Add_CurrentCellDirtyStateChanged({
        if ($grid.IsCurrentCellDirty) {
            $grid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit)
        }
    }.GetNewClosure())

    $colSelected = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $colSelected.Name = "Selected"; $colSelected.HeaderText = ""; $colSelected.FillWeight = 8
    $grid.Columns.Add($colSelected) | Out-Null
    $colType = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colType.Name = "Type"; $colType.HeaderText = "Type"; $colType.FillWeight = 16
    $colType.ReadOnly = $true
    $grid.Columns.Add($colType) | Out-Null
    $colIntuneName = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colIntuneName.Name = "IntuneName"; $colIntuneName.HeaderText = "Name in Intune"; $colIntuneName.FillWeight = 27
    $colIntuneName.ReadOnly = $true
    $grid.Columns.Add($colIntuneName) | Out-Null
    $colCatalogName = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colCatalogName.Name = "CatalogName"; $colCatalogName.HeaderText = "Name in catalog"; $colCatalogName.FillWeight = 27
    $colCatalogName.ReadOnly = $true
    $grid.Columns.Add($colCatalogName) | Out-Null
    $colId = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colId.Name = "Id"; $colId.HeaderText = "App ID"; $colId.FillWeight = 30
    $colId.ReadOnly = $true
    $grid.Columns.Add($colId) | Out-Null
    $dlg.Controls.Add($grid)

    # Bulk path, separate from $btnAction below - check any number of
    # "Not in catalog" rows and add them all at once with just name and
    # App ID, no full editor per app. $btnAction (further right) remains
    # for the single-row, full-editor add, plus the Renamed/Deleted
    # actions, which don't make sense to batch the same way.
    $btnAddChecked = New-Object System.Windows.Forms.Button
    $btnAddChecked.Text = "Add checked to catalog"
    $btnAddChecked.Location = New-Object System.Drawing.Point(15,474)
    $btnAddChecked.Size = New-Object System.Drawing.Size(175,32)
    $dlg.Controls.Add($btnAddChecked)

    $btnAction = New-Object System.Windows.Forms.Button
    $btnAction.Text = "Add to catalog..."
    $btnAction.Location = New-Object System.Drawing.Point(515,474)
    $btnAction.Size = New-Object System.Drawing.Size(140,32)
    $btnAction.Enabled = $false
    $dlg.Controls.Add($btnAction)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"
    $btnClose.Location = New-Object System.Drawing.Point(665,474)
    $btnClose.Size = New-Object System.Drawing.Size(80,32)
    $dlg.Controls.Add($btnClose)

    # Stored in a variable so both the initial load and the post-action
    # refresh can reuse the exact same logic.
    $populateGrid = {
        # Explicitly force DataSource to $null before clearing - this grid is
        # never meant to be data-bound (rows are always added manually via
        # .Rows.Add() below), but .Rows.Clear() throws "cannot be
        # programmatically cleared when...data-bound..." if DataSource is
        # ever non-null for any reason, which has been observed happening
        # here. This unconditionally prevents that regardless of cause.
        $grid.DataSource = $null
        $grid.Rows.Clear()

        $catalogByNormName = @{}
        $catalogByAppId = @{}
        foreach ($app in $appsRef) {
            $normName = ($app.appName.Trim() -replace '\s+', ' ')
            $catalogByNormName[$normName] = $true
            if ($app.appId) { $catalogByAppId[$app.appId] = $app }
        }

        # Every ID actually live in Intune right now, for the third
        # comparison direction below - a catalog entry can only be flagged
        # as genuinely deleted if its own stored ID isn't in this set at all,
        # not just absent from a name-based lookup.
        $intuneIds = New-Object System.Collections.Generic.HashSet[string]
        foreach ($ia in $cacheRef) { [void]$intuneIds.Add($ia.id) }

        $missing = New-Object System.Collections.Generic.List[object]
        $renamed = New-Object System.Collections.Generic.List[object]
        foreach ($ia in $cacheRef) {
            $normIntuneName = ($ia.displayName.Trim() -replace '\s+', ' ')
            if ($catalogByAppId.ContainsKey($ia.id)) {
                # Known App ID - check whether the catalog's name still matches
                $catalogApp = $catalogByAppId[$ia.id]
                $normCatalogName = ($catalogApp.appName.Trim() -replace '\s+', ' ')
                if ($normCatalogName -ne $normIntuneName) {
                    $renamed.Add([pscustomobject]@{ IntuneName = $ia.displayName; CatalogName = $catalogApp.appName; Id = $ia.id })
                }
            }
            elseif (-not $catalogByNormName.ContainsKey($normIntuneName)) {
                $missing.Add($ia)
            }
        }

        # The third direction, walked from the CATALOG's own side rather
        # than Intune's - the two loops above only ever iterate Intune's
        # app list, so a catalog entry whose own stored App ID has been
        # deleted from Intune entirely (not renamed - genuinely gone, e.g.
        # removed directly in the portal, bypassing this tool) would never
        # surface in either "Not in catalog" or "Renamed in Intune", since
        # neither of those checks ever looks the other way.
        $deletedFromIntune = New-Object System.Collections.Generic.List[object]
        foreach ($app in $appsRef) {
            if ($app.appId -and -not $intuneIds.Contains($app.appId)) {
                $deletedFromIntune.Add($app)
            }
        }

        foreach ($o in ($missing | Sort-Object displayName)) {
            [void]$grid.Rows.Add($false, "Not in catalog", $o.displayName, "", $o.id)
        }
        foreach ($r in ($renamed | Sort-Object IntuneName)) {
            # Checkbox column disabled (read-only) for these rows - bulk
            # "add checked" below only ever applies to "Not in catalog"
            # rows, so leaving this checkable here would silently do
            # nothing when checked, which is worse than not offering it
            # at all.
            $rIdx = $grid.Rows.Add($false, "Renamed in Intune", $r.IntuneName, $r.CatalogName, $r.Id)
            $grid.Rows[$rIdx].Cells["Selected"].ReadOnly = $true
        }
        foreach ($d in ($deletedFromIntune | Sort-Object appName)) {
            $dIdx = $grid.Rows.Add($false, "Deleted from Intune", "", $d.appName, $d.appId)
            $grid.Rows[$dIdx].Cells["Selected"].ReadOnly = $true
        }

        if ($missing.Count -eq 0 -and $renamed.Count -eq 0 -and $deletedFromIntune.Count -eq 0) {
            $lblStatus.ForeColor = [System.Drawing.Color]::SeaGreen
            $lblStatus.Text = "No differences found - all $($cacheRef.Count) app(s) in Intune match the catalog."
        }
        else {
            $lblStatus.ForeColor = [System.Drawing.Color]::DarkOrange
            $lblStatus.Text = "$($cacheRef.Count) app(s) in Intune - $($missing.Count) not in catalog, $($renamed.Count) renamed since last synced, $($deletedFromIntune.Count) deleted from Intune."
        }
    }.GetNewClosure()

    $btnRefresh.Add_Click({
        $btnRefresh.Enabled = $false
        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblStatus.Text = "Fetching apps from Intune..."
        $dlg.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

        # Fresh aliases for the nested -OnComplete closure - see note at the
        # top of Show-CreateInIntuneDialog for why this matters here too.
        $btnRefreshRef = $btnRefresh
        $dlgRef = $dlg
        $lblStatusRef = $lblStatus
        $populateGridRef = $populateGrid

        Start-IntuneAppLookup -OnComplete {
            param($ok, $data)
            $dlgRef.Cursor = [System.Windows.Forms.Cursors]::Default
            [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default
            $btnRefreshRef.Enabled = $true
            if (-not $ok) {
                $lblStatusRef.ForeColor = [System.Drawing.Color]::Firebrick
                $lblStatusRef.Text = "Fetch failed: $data"
                return
            }
            & $populateGridRef
        }.GetNewClosure()
    }.GetNewClosure())

    $grid.Add_SelectionChanged({
        if ($grid.SelectedRows.Count -eq 0) {
            $btnAction.Enabled = $false
            return
        }
        $btnAction.Enabled = $true
        $type = [string]$grid.SelectedRows[0].Cells["Type"].Value
        $btnAction.Text = if ($type -eq "Renamed in Intune") { "Sync name from Intune" } elseif ($type -eq "Deleted from Intune") { "Clear stale App ID" } else { "Add to catalog..." }
    }.GetNewClosure())

    $btnAction.Add_Click({
        if ($grid.SelectedRows.Count -eq 0) { return }
        $type = [string]$grid.SelectedRows[0].Cells["Type"].Value
        $intuneName = [string]$grid.SelectedRows[0].Cells["IntuneName"].Value
        $id = [string]$grid.SelectedRows[0].Cells["Id"].Value

        if ($type -eq "Renamed in Intune") {
            $catalogName = [string]$grid.SelectedRows[0].Cells["CatalogName"].Value
            $r = [System.Windows.Forms.MessageBox]::Show(
                "Rename this catalog entry from`n`n  `"$catalogName`"`n`nto match Intune's current name:`n`n  `"$intuneName`"`n`nContinue?",
                "Sync name from Intune", "YesNo", "Question")
            if ($r -ne "Yes") { return }
            $target = $appsRef | Where-Object { $_.appId -eq $id } | Select-Object -First 1
            if ($target) {
                $target.appName = $intuneName
                $unsavedBoxRef.Value = $true
                $anyAddedBox.Value = $true
                # Direct-save, not just staged in memory - same reasoning
                # as every other single, atomic action made direct-save
                # this session.
                [void](Save-AppsToFile -Path $linkedFilePathRef)
                & $populateGrid
            }
        }
        elseif ($type -eq "Deleted from Intune") {
            $catalogName = [string]$grid.SelectedRows[0].Cells["CatalogName"].Value
            $r = [System.Windows.Forms.MessageBox]::Show(
                "`"$catalogName`" has App ID $id in the catalog, but that App ID no longer exists in Intune - it was likely deleted there directly, outside this tool.`n`nClear the stale App ID from this catalog entry? It stays in the catalog, just without an ID - use `"Deploy to Intune`" afterward if it should be re-created.",
                "Clear stale App ID", "YesNo", "Warning")
            if ($r -ne "Yes") { return }
            $target = $appsRef | Where-Object { $_.appId -eq $id } | Select-Object -First 1
            if ($target) {
                $target.appId = ""
                $unsavedBoxRef.Value = $true
                $anyAddedBox.Value = $true
                [void](Save-AppsToFile -Path $linkedFilePathRef)
                & $populateGrid
            }
        }
        else {
            $prefill = [pscustomobject]@{ appName = $intuneName; appId = $id }
            $newApp = Show-AppEditor -ExistingApp $prefill
            if ($newApp) {
                [void]$appsRef.Add($newApp)
                $unsavedBoxRef.Value = $true
                $anyAddedBox.Value = $true
                [void](Save-AppsToFile -Path $linkedFilePathRef)
                & $populateGrid   # the just-added app drops out of the "not in catalog" list
            }
        }
    }.GetNewClosure())

    $btnAddChecked.Add_Click({
        # Defensive, on top of the CurrentCellDirtyStateChanged commit
        # above - forces any still-pending checkbox edit to commit right
        # before reading values below, in case a checkbox was just
        # clicked and this button clicked again before that event had a
        # chance to run.
        $grid.EndEdit()
        $toAdd = New-Object System.Collections.Generic.List[object]
        foreach ($row in $grid.Rows) {
            $rowType = [string]$row.Cells["Type"].Value
            if ($rowType -ne "Not in catalog") { continue }
            $isChecked = [bool]$row.Cells["Selected"].Value
            if (-not $isChecked) { continue }
            $toAdd.Add([pscustomobject]@{ Name = [string]$row.Cells["IntuneName"].Value; Id = [string]$row.Cells["Id"].Value })
        }
        if ($toAdd.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Check at least one `"Not in catalog`" app first.", "Nothing checked", "OK", "Information") | Out-Null
            return
        }
        # Minimal entries added directly, no full editor per app - just
        # name and App ID, matching exactly what the single-row "Add to
        # catalog..." button pre-fills that editor with anyway. Winget ID,
        # group assignments, and metadata are all still fully editable
        # afterward from the main catalog - this only removes having to
        # open and close that editor once per app when adding several at
        # once.
        foreach ($item in $toAdd) {
            $newEntry = [pscustomobject]@{
                appId        = $item.Id
                appName      = $item.Name
                wingetId     = ""
                requiredFor  = @()
                availableFor = @()
                uninstallFor = @()
                metadata     = $null
            }
            [void]$appsRef.Add($newEntry)
        }
        $unsavedBoxRef.Value = $true
        $anyAddedBox.Value = $true
        [void](Save-AppsToFile -Path $linkedFilePathRef)
        [System.Windows.Forms.MessageBox]::Show("Added $($toAdd.Count) app(s) to the catalog. Set Winget ID, group assignments, and metadata for them later from the main catalog.", "Added", "OK", "Information") | Out-Null
        & $populateGrid   # the just-added apps drop out of the "not in catalog" list
    }.GetNewClosure())

    $btnClose.Add_Click({ $dlg.Close() }.GetNewClosure())
    $dlg.CancelButton = $btnClose

    # Deferred to Add_Shown rather than called directly here - kicking off
    # the async refresh (PerformClick -> Start-.../timer) BEFORE ShowDialog()
    # has actually shown/realized the window let the WaitCursor assignment
    # get set on a not-yet-created window handle, which doesn't reliably
    # "stick" - the cursor could end up stuck spinning even after the async
    # work (and its Cursor = Default reset) had already completed.
    #
    # Always a live fetch, never the reused-cache branch this used to have -
    # $cacheRef ($Script:IntuneAppsCache) is shared across the whole app, so
    # it can already be non-empty here purely from something unrelated (e.g.
    # the app editor's own "Look up" button) run earlier in the session.
    # This dialog's entire job is telling you what's actually different
    # right now, so opening it must mean "check now", not "show whatever
    # happened to be cached from something else, however old that is".
    $dlg.Add_Shown({
        $btnRefresh.PerformClick()
    }.GetNewClosure())

    Set-Theme -Control $dlg
    [void]$dlg.ShowDialog($form)
    return $anyAddedBox.Value
}

# ---------------------------------------------------------------
# Delete app from Intune dialog
# ---------------------------------------------------------------
# Deletes an app from Intune entirely - irreversible. Deliberately kept
# separate from the catalog: deleting from Intune does not remove the
# catalog entry, it just clears its App ID on success (since the ID no
# longer refers to anything), so the app can be recreated later without
# losing its group assignments/metadata already saved in input.json.
function Show-DeleteAppDialog {
    param([string]$AppId, [string]$AppName)

    if (-not $AppId) {
        [System.Windows.Forms.MessageBox]::Show("This app doesn't have an App ID - nothing to delete in Intune.", "No App ID", "OK", "Information") | Out-Null
        return @{ Success = $false; RemovedFromCatalog = $false }
    }

    # Plain local aliases - see note in Start-IntuneAppLookup.
    $tenantId      = $Script:GraphTenantId
    $clientId      = $Script:GraphClientId
    $certThumb     = $Script:GraphCertificateThumbprint
    $deleteScript  = $Script:EmbeddedDeleteAppScript
    $appsRef       = $Script:Apps
    $unsavedBox    = $Script:UnsavedChangesBox
    $linkedFilePath = $Script:LinkedFilePath

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Delete from Intune - $AppName"
    $dlg.ClientSize = New-Object System.Drawing.Size(560, 380)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $lblWarning = New-Object System.Windows.Forms.Label
    $lblWarning.Text = "This permanently deletes `"$AppName`" (App ID: $AppId) from Intune, including its content, assignments, and install history. This CANNOT be undone.`n`nOn success, you'll be asked whether to also remove the catalog entry itself, or just clear its App ID and keep the entry (and its group assignments) around to recreate later."
    $lblWarning.Location = New-Object System.Drawing.Point(15,12)
    $lblWarning.Size = New-Object System.Drawing.Size(530,90)
    $lblWarning.ForeColor = [System.Drawing.Color]::Firebrick
    $dlg.Controls.Add($lblWarning)

    $lblConfirmPrompt = New-Object System.Windows.Forms.Label
    $lblConfirmPrompt.Text = "Type the app name below to confirm:"
    $lblConfirmPrompt.Location = New-Object System.Drawing.Point(15,108)
    $lblConfirmPrompt.AutoSize = $true
    $dlg.Controls.Add($lblConfirmPrompt)

    $txtConfirm = New-Object System.Windows.Forms.TextBox
    $txtConfirm.Location = New-Object System.Drawing.Point(15,128)
    $txtConfirm.Size = New-Object System.Drawing.Size(530,24)
    $dlg.Controls.Add($txtConfirm)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Location = New-Object System.Drawing.Point(15,158)
    $lblStatus.Size = New-Object System.Drawing.Size(530,50)
    $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($lblStatus)

    $rtbLog = New-Object System.Windows.Forms.RichTextBox
    $rtbLog.Location = New-Object System.Drawing.Point(15,212)
    $rtbLog.Size = New-Object System.Drawing.Size(530,120)
    $rtbLog.ReadOnly = $true
    $rtbLog.BackColor = [System.Drawing.Color]::FromArgb(13,17,23)
    $rtbLog.ForeColor = [System.Drawing.Color]::Gainsboro
    $rtbLog.Font = New-Object System.Drawing.Font("Consolas", 8.5)
    $dlg.Controls.Add($rtbLog)

    $btnDelete = New-Object System.Windows.Forms.Button
    $btnDelete.Text = "Delete permanently"
    $btnDelete.Location = New-Object System.Drawing.Point(345,336)
    $btnDelete.Size = New-Object System.Drawing.Size(150,32)
    $btnDelete.Enabled = $false
    $dlg.Controls.Add($btnDelete)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(255,336)
    $btnCancel.Size = New-Object System.Drawing.Size(85,32)
    $dlg.Controls.Add($btnCancel)

    $procBox = @{ Proc = $null }
    $deletedBox = @{ Success = $false; RemovedFromCatalog = $false }

    # Stored as a named closure (rather than inline in the button handler)
    # specifically so it can call itself again from within its own
    # -OnComplete - if the delete is blocked by a dependency and the user
    # confirms removing it, this re-runs with that dependency's App ID set,
    # rather than needing a second, separate code path to express the retry.
    # A mutable container, not a plain variable - $RunDelete needs to call
    # ITSELF recursively (from within its own -OnComplete, when retrying
    # after removing a blocking dependency), and .GetNewClosure() captures
    # variables BY VALUE at the moment it's called, not as a live reference
    # to their future state. A plain "$RunDelete = {...$RunDelete...}
    # .GetNewClosure()" self-reference would capture $RunDelete's value from
    # BEFORE the assignment even completes - which is $null, since the
    # variable doesn't exist yet at that instant - not the scriptblock being
    # assigned to it. A hashtable is a reference type: the closure captures
    # the CONTAINER, so reading .Value later (once it's actually been set)
    # correctly sees the real, fully-assigned scriptblock. Same pattern
    # already used everywhere else in this app for exactly this kind of
    # "closures need to see an updated value" problem (see $procBox above).
    $RunDeleteBox = @{ Value = $null }

    $RunDeleteBox.Value = {
        param([string]$RemoveDependencyFromAppId = "")

        $btnDelete.Enabled = $false
        $txtConfirm.Enabled = $false
        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblStatus.Text = if ($RemoveDependencyFromAppId) { "Removing the blocking dependency, then deleting..." } else { "Deleting..." }

        $configPath = Join-Path $env:TEMP (".itsense_deleteapp_config_" + [guid]::NewGuid().ToString("N") + ".json")
        $resultPath = Join-Path $env:TEMP (".itsense_deleteapp_result_" + [guid]::NewGuid().ToString("N") + ".json")
        $config = [pscustomobject]@{
            TenantId                  = $tenantId
            ClientId                  = $clientId
            CertificateThumbprint     = $certThumb
            AppId                     = $AppId
            AppName                   = $AppName
            RemoveDependencyFromAppId = $RemoveDependencyFromAppId
            OutputResultPath          = $resultPath
        }
        try {
            $configJsonText = $config | ConvertTo-Json -Depth 8 -ErrorAction Stop
            [System.IO.File]::WriteAllText($configPath, $configJsonText, (New-Object System.Text.UTF8Encoding($false)))
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Could not write the config file needed to run this: $($_.Exception.Message)", "Failed to prepare", "OK", "Error") | Out-Null
            return
        }

        # Fresh aliases for the nested -OnComplete closure - see note at the
        # top of Show-CreateInIntuneDialog for why this matters here too.
        $btnDeleteRef = $btnDelete
        $lblStatusRef = $lblStatus
        $resultPathRef = $resultPath
        $configPathRef = $configPath
        $procBoxRef = $procBox
        $deletedBoxRef = $deletedBox
        $dlgRef = $dlg
        $rtbLogRef = $rtbLog
        $RunDeleteBoxRef = $RunDeleteBox
        $AppNameRef = $AppName
        $appsRefRef = $appsRef
        $unsavedBoxRef = $unsavedBox
        $linkedFilePathRef = $linkedFilePath

        $procBoxRef.Proc = Start-PipelineProcess -ScriptContent $deleteScript -TempScriptName ".itsense_embedded_deleteapp.ps1" -ArgumentString "-ConfigPath `"$configPathRef`"" -ExtraLogTarget $rtbLog -OnComplete {
            param($code)
            $procBoxRef.Proc = $null
            Remove-Item $configPathRef -Force -ErrorAction SilentlyContinue

            if (-not (Test-Path $resultPathRef)) {
                $btnDeleteRef.Enabled = $true
                Write-DialogError -StatusLabel $lblStatusRef -LogBox $rtbLogRef -ErrorMessage "No result written (exit code $code). See progress above."
                return
            }

            # Parsing kept in its OWN try/catch, separate from handling the
            # parsed result below - they were previously one block, which
            # meant a failure while HANDLING a successfully-parsed result
            # (e.g. the recursive retry call below, if it throws for any
            # reason) would get misreported as "Could not read result",
            # pointing at completely the wrong step.
            $result = $null
            try {
                $result = Get-Content -Path $resultPathRef -Raw | ConvertFrom-Json
                Remove-Item $resultPathRef -Force -ErrorAction SilentlyContinue
            }
            catch {
                $btnDeleteRef.Enabled = $true
                Write-DialogError -StatusLabel $lblStatusRef -LogBox $rtbLogRef -ErrorMessage "Could not read result (exit code $code): $($_.Exception.Message)"
                return
            }

            try {
                if ($result.success) {
                    $deletedBoxRef.Success = $true
                    $lblStatusRef.ForeColor = [System.Drawing.Color]::SeaGreen
                    $lblStatusRef.Text = "Deleted from Intune."
                    # Asked now, right after Intune confirms the delete,
                    # rather than leaving the caller to always just clear
                    # the App ID and silently keep the entry around - most
                    # of the time deleting an app from Intune means you're
                    # actually done with it, not planning to recreate it, so
                    # leaving a now-orphaned catalog entry behind by default
                    # was the more surprising outcome, not the friendlier one.
                    $removeChoice = [System.Windows.Forms.MessageBox]::Show(
                        "Deleted `"$AppNameRef`" from Intune.`n`nAlso remove it from the local catalog entirely? Choosing No just clears its App ID here, keeping the entry (and its group assignments) so it's easy to recreate later.",
                        "Remove from catalog too?", "YesNo", "Question")
                    if ($removeChoice -eq "Yes") {
                        $delCatalogIdx = -1
                        for ($dci = 0; $dci -lt $appsRefRef.Count; $dci++) {
                            if ($appsRefRef[$dci].appName -eq $AppNameRef) { $delCatalogIdx = $dci; break }
                        }
                        if ($delCatalogIdx -ge 0) { $appsRefRef.RemoveAt($delCatalogIdx) }
                        $unsavedBoxRef.Value = $true
                        # Direct-save here too - the caller's own post-close
                        # handling (clearing the App ID and saving) is
                        # skipped entirely when RemovedFromCatalog is true,
                        # since there's no longer an entry left for it to
                        # act on, so this has to be the one place that
                        # actually persists the removal.
                        [void](Save-AppsToFile -Path $linkedFilePathRef)
                        $deletedBoxRef.RemovedFromCatalog = $true
                    }
                    $dlgRef.Close()
                }
                elseif ($result.blockingAppId) {
                    $r2 = [System.Windows.Forms.MessageBox]::Show(
                        "This app can't be deleted because Intune has it set as a dependency for `"$($result.blockingAppName)`".`n`nRemove that dependency relationship and then delete this app?",
                        "Dependency in the way", "YesNo", "Warning")
                    if ($r2 -eq "Yes") {
                        & $RunDeleteBoxRef.Value -RemoveDependencyFromAppId $result.blockingAppId
                    }
                    else {
                        $btnDeleteRef.Enabled = $true
                        $lblStatusRef.ForeColor = [System.Drawing.Color]::DarkOrange
                        $lblStatusRef.Text = "Not deleted - still blocked by that dependency."
                    }
                }
                else {
                    $btnDeleteRef.Enabled = $true
                    Write-DialogError -StatusLabel $lblStatusRef -LogBox $rtbLogRef -ErrorMessage $result.error
                }
            }
            catch {
                $btnDeleteRef.Enabled = $true
                Write-DialogError -StatusLabel $lblStatusRef -LogBox $rtbLogRef -ErrorMessage "Result was read, but something went wrong acting on it: $($_.Exception.Message)"
            }
        }.GetNewClosure()
    }.GetNewClosure()

    $txtConfirm.Add_TextChanged({
        $btnDelete.Enabled = ($txtConfirm.Text.Trim() -eq $AppName)
    }.GetNewClosure())

    $btnDelete.Add_Click({
        & $RunDeleteBox.Value
    }.GetNewClosure())

    $btnCancel.Add_Click({
        if ($procBox.Proc -and -not $procBox.Proc.HasExited) {
            $r = [System.Windows.Forms.MessageBox]::Show("A step is currently running. Stop it and close this dialog?", "Stop and close?", "YesNo", "Warning")
            if ($r -ne "Yes") { return }
            try { $procBox.Proc.Kill() } catch { }
        }
        $dlg.Close()
    }.GetNewClosure())
    $dlg.CancelButton = $btnCancel
    $dlg.AcceptButton = $btnDelete

    Set-Theme -Control $dlg
    [void]$dlg.ShowDialog($form)
    # A hashtable now, not a plain bool - callers must check .Success
    # explicitly (a hashtable reference is truthy on its own, even one with
    # Success=$false), and .RemovedFromCatalog tells them whether they still
    # need to do their own "clear the App ID and save" step, or whether this
    # dialog already removed the whole entry (and saved) itself.
    return $deletedBox
}

# ---------------------------------------------------------------
# Bulk delete from Intune
# ---------------------------------------------------------------
# Same permanent, irreversible Intune deletion Show-DeleteAppDialog does for
# one app, run across every checked app here in sequence - same
# self-referencing queue-runner pattern as Show-BatchDeployDialog's own
# $RunNextBox, reusing $Script:EmbeddedDeleteAppScript completely unchanged,
# one app at a time. Deliberately NOT taught to accept a whole batch in one
# process invocation the way the (read-only, much lower-stakes) sync-
# metadata script is - that script's dependency-block detection and
# interactive "remove the blocking dependency and retry?" prompt is exactly
# the kind of per-app judgment call that has no sane unattended answer
# across many apps at once. A dependency-blocked app here is simply
# reported as a failure with a pointer to the single-app dialog, which
# still offers that interactive retry.
function Show-BulkDeleteFromIntuneDialog {
    param([int[]]$Indices)

    # Plain local aliases - see note in Start-IntuneAppLookup.
    $appsRef        = $Script:Apps
    $tenantId       = $Script:GraphTenantId
    $clientId       = $Script:GraphClientId
    $certThumb      = $Script:GraphCertificateThumbprint
    $deleteScript   = $Script:EmbeddedDeleteAppScript
    $unsavedBox     = $Script:UnsavedChangesBox
    $linkedFilePath = $Script:LinkedFilePath

    $candidateApps = @($Indices | ForEach-Object { $appsRef[$_] })
    $eligibleApps  = @($candidateApps | Where-Object { $_.appId })

    if ($eligibleApps.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("None of the selected app(s) have an App ID - there's nothing in Intune to delete for them.", "Nothing to do", "OK", "Information") | Out-Null
        return $false
    }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Delete from Intune - $($eligibleApps.Count) app(s)"
    $dlg.ClientSize = New-Object System.Drawing.Size(660, 646)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $lblWarning = New-Object System.Windows.Forms.Label
    $skippedNote = if ($candidateApps.Count -gt $eligibleApps.Count) { " $($candidateApps.Count - $eligibleApps.Count) of the app(s) you selected have no App ID and are left out below - there's nothing in Intune to delete for them." } else { "" }
    $lblWarning.Text = "This PERMANENTLY deletes every checked app below from Intune, including its content, assignments, and install history. This CANNOT be undone.$skippedNote`n`nEach catalog entry itself is not removed - only its App ID is cleared on success, so you can recreate it later without losing the groups already set here."
    $lblWarning.Location = New-Object System.Drawing.Point(15,12)
    $lblWarning.Size = New-Object System.Drawing.Size(630,72)
    $lblWarning.ForeColor = [System.Drawing.Color]::Firebrick
    $dlg.Controls.Add($lblWarning)

    $clbApps = New-Object System.Windows.Forms.CheckedListBox
    $clbApps.Location = New-Object System.Drawing.Point(15,90)
    $clbApps.Size = New-Object System.Drawing.Size(630,220)
    $clbApps.CheckOnClick = $true
    $dlg.Controls.Add($clbApps)
    foreach ($eligibleApp in ($eligibleApps | Sort-Object appName)) {
        [void]$clbApps.Items.Add($eligibleApp.appName, $true)
    }

    $btnSelectAll = New-Object System.Windows.Forms.Button
    $btnSelectAll.Text = "Select all"
    $btnSelectAll.Location = New-Object System.Drawing.Point(15,316)
    $btnSelectAll.Size = New-Object System.Drawing.Size(100,26)
    $dlg.Controls.Add($btnSelectAll)

    $btnSelectNone = New-Object System.Windows.Forms.Button
    $btnSelectNone.Text = "Select none"
    $btnSelectNone.Location = New-Object System.Drawing.Point(125,316)
    $btnSelectNone.Size = New-Object System.Drawing.Size(110,26)
    $dlg.Controls.Add($btnSelectNone)

    # Hidden until a run actually has failures to retry - same convention
    # as Show-SyncMetadataDialog's own "Retry failed only".
    $btnRetryFailed = New-Object System.Windows.Forms.Button
    $btnRetryFailed.Text = "Retry failed only"
    $btnRetryFailed.Location = New-Object System.Drawing.Point(245,316)
    $btnRetryFailed.Size = New-Object System.Drawing.Size(155,26)
    $btnRetryFailed.Visible = $false
    $dlg.Controls.Add($btnRetryFailed)

    # Checked by default - a checked app blocked because Intune itself has
    # it set as a dependency for another app (Winget AutoUpdate depending
    # on nearly everything else being a very common real case, per testing)
    # is by far the more likely outcome than a genuine "leave it alone"
    # case, and leaving this unchecked just means every blocked app fails
    # outright instead. No per-app Yes/No prompt during the run itself,
    # unlike the single-app dialog's own version of this same retry - a
    # bulk run with N apps queued up is exactly the case where stopping to
    # ask mid-run, once per blocked app, defeats the point of doing this in
    # bulk at all; this single upfront checkbox is the batch-appropriate
    # equivalent of that same Yes/No.
    $chkAutoRemoveDeps = New-Object System.Windows.Forms.CheckBox
    $chkAutoRemoveDeps.Text = "Automatically remove blocking dependency relationships (e.g. `"Winget AutoUpdate`") and retry, instead of just failing"
    $chkAutoRemoveDeps.Location = New-Object System.Drawing.Point(15,346)
    $chkAutoRemoveDeps.Size = New-Object System.Drawing.Size(630,20)
    $chkAutoRemoveDeps.Checked = $true
    $dlg.Controls.Add($chkAutoRemoveDeps)

    $lblConfirmPrompt = New-Object System.Windows.Forms.Label
    # Typing the exact name (like the single-app dialog) doesn't scale to N
    # apps at once - typing the literal word DELETE is the same convention
    # widely used elsewhere for an irreversible bulk/multi-item action.
    $lblConfirmPrompt.Text = "Type DELETE below to confirm:"
    $lblConfirmPrompt.Location = New-Object System.Drawing.Point(15,376)
    $lblConfirmPrompt.AutoSize = $true
    $dlg.Controls.Add($lblConfirmPrompt)

    $txtConfirm = New-Object System.Windows.Forms.TextBox
    $txtConfirm.Location = New-Object System.Drawing.Point(15,396)
    $txtConfirm.Size = New-Object System.Drawing.Size(630,24)
    $dlg.Controls.Add($txtConfirm)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Location = New-Object System.Drawing.Point(15,426)
    $lblStatus.Size = New-Object System.Drawing.Size(630,36)
    $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($lblStatus)

    $rtbLog = New-Object System.Windows.Forms.RichTextBox
    $rtbLog.Location = New-Object System.Drawing.Point(15,466)
    $rtbLog.Size = New-Object System.Drawing.Size(630,120)
    $rtbLog.ReadOnly = $true
    $rtbLog.BackColor = [System.Drawing.Color]::FromArgb(13,17,23)
    $rtbLog.ForeColor = [System.Drawing.Color]::Gainsboro
    $rtbLog.Font = New-Object System.Drawing.Font("Consolas", 8.5)
    $dlg.Controls.Add($rtbLog)

    $btnDelete = New-Object System.Windows.Forms.Button
    $btnDelete.Text = "Delete permanently"
    $btnDelete.Location = New-Object System.Drawing.Point(455,602)
    $btnDelete.Size = New-Object System.Drawing.Size(190,32)
    $btnDelete.Enabled = $false
    $dlg.Controls.Add($btnDelete)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"
    $btnClose.Location = New-Object System.Drawing.Point(365,602)
    $btnClose.Size = New-Object System.Drawing.Size(85,32)
    $dlg.Controls.Add($btnClose)

    $procBox = @{ Proc = $null }
    $lastFailedBox = @{ Names = @() }
    $deletedAnyBox = @{ Value = $false }

    $txtConfirm.Add_TextChanged({
        $btnDelete.Enabled = ($txtConfirm.Text.Trim() -eq "DELETE")
    }.GetNewClosure())

    $btnSelectAll.Add_Click({
        for ($ci = 0; $ci -lt $clbApps.Items.Count; $ci++) { $clbApps.SetItemChecked($ci, $true) }
    }.GetNewClosure())
    $btnSelectNone.Add_Click({
        for ($ci = 0; $ci -lt $clbApps.Items.Count; $ci++) { $clbApps.SetItemChecked($ci, $false) }
    }.GetNewClosure())
    $btnRetryFailed.Add_Click({
        for ($ci = 0; $ci -lt $clbApps.Items.Count; $ci++) {
            $itemName = [string]$clbApps.Items[$ci]
            $clbApps.SetItemChecked($ci, ($lastFailedBox.Names -contains $itemName))
        }
    }.GetNewClosure())

    # A mutable container, not a plain variable - RunNext needs to call
    # ITSELF again (moving on to the next app) from within its own
    # -OnComplete - see the extensive reasoning on the identical pattern in
    # Show-BatchDeployDialog's own $RunNextBox for why a plain
    # self-referencing scriptblock would capture $null instead.
    $RunNextBox = @{ Value = $null }

    $RunNextBox.Value = {
        # $RemoveDependencyFromAppId/$RetryAttempt let this same queue item
        # be re-run in place (same $QueueIndex, not the next one) after
        # removing a blocking dependency, mirroring what the single-app
        # dialog's own $RunDeleteBox does interactively - just without a
        # Yes/No prompt each time, since $chkAutoRemoveDeps up front already
        # covers that consent for the whole run. $RetryAttempt caps how many
        # times in a row THIS app can loop back on itself (a fresh
        # dependency found each time) - protects against a pathological
        # dependency chain looping forever; a single-app dependency block
        # only ever needs one or two removals in practice.
        param($Queue, $QueueIndex, $Results, $RemoveDependencyFromAppId = "", $RetryAttempt = 0)

        if ($QueueIndex -ge $Queue.Count) {
            $deletedNames = @($Results | Where-Object { $_.Status -eq "Deleted" } | ForEach-Object { $_.AppName })
            $okCount = $deletedNames.Count
            $failedCount = @($Results | Where-Object { $_.Status -eq "Failed" }).Count
            $btnSelectAll.Enabled = $true
            $btnSelectNone.Enabled = $true
            $clbApps.Enabled = $true
            $chkAutoRemoveDeps.Enabled = $true
            $txtConfirm.Enabled = $true
            $btnDelete.Enabled = ($txtConfirm.Text.Trim() -eq "DELETE")
            $failedNames = @($Results | Where-Object { $_.Status -eq "Failed" } | ForEach-Object { $_.AppName })
            $lastFailedBox.Names = $failedNames
            $btnRetryFailed.Visible = ($failedNames.Count -gt 0)

            # Asked once for the whole run, right after it finishes - not
            # per app mid-run, same reasoning as $chkAutoRemoveDeps above:
            # a single upfront-or-afterward choice, not a popup for every
            # item. Most of the time deleting an app from Intune means
            # you're actually done with it, so leaving every one of these
            # now-orphaned catalog entries behind by default would just be
            # more manual cleanup afterward, not the friendlier outcome.
            $removedCatalogCount = 0
            if ($okCount -gt 0) {
                $catalogChoice = [System.Windows.Forms.MessageBox]::Show(
                    "Deleted $okCount app(s) from Intune.`n`nAlso remove these from the local catalog entirely?`n`n$($deletedNames -join ", ")`n`nChoosing No just clears their App IDs, keeping the entries (and group assignments) so they're easy to recreate later.",
                    "Remove from catalog too?", "YesNo", "Question")
                if ($catalogChoice -eq "Yes") {
                    foreach ($deletedName in $deletedNames) {
                        for ($dci = 0; $dci -lt $appsRef.Count; $dci++) {
                            if ($appsRef[$dci].appName -eq $deletedName) {
                                $appsRef.RemoveAt($dci)
                                $removedCatalogCount++
                                break
                            }
                        }
                    }
                    $unsavedBox.Value = $true
                    [void](Save-AppsToFile -Path $linkedFilePath)
                }
            }

            $lblStatus.ForeColor = if ($failedCount -gt 0) { [System.Drawing.Color]::DarkOrange } else { [System.Drawing.Color]::SeaGreen }
            $catalogSuffix = if ($removedCatalogCount -gt 0) { " $removedCatalogCount removed from the catalog entirely." } else { "" }
            $lblStatus.Text = "Done - $okCount deleted, $failedCount failed.$catalogSuffix"
            return
        }

        $currentApp = $Queue[$QueueIndex]
        if ($RemoveDependencyFromAppId) {
            $rtbLog.AppendText("  [!] Blocked by a dependency - removing it and retrying ($($RetryAttempt+1)/5)...`r`n")
            $lblStatus.Text = "Removing a blocking dependency for $($currentApp.appName), then retrying..."
        }
        else {
            $rtbLog.AppendText("`r`n[$($QueueIndex+1)/$($Queue.Count)] $($currentApp.appName)`r`n")
            $lblStatus.Text = "Deleting $($QueueIndex+1) of $($Queue.Count): $($currentApp.appName)..."
        }

        $configPath = Join-Path $env:TEMP (".itsense_bulkdelete_config_" + [guid]::NewGuid().ToString("N") + ".json")
        $resultPath = Join-Path $env:TEMP (".itsense_bulkdelete_result_" + [guid]::NewGuid().ToString("N") + ".json")
        $config = [pscustomobject]@{
            TenantId                  = $tenantId
            ClientId                  = $clientId
            CertificateThumbprint     = $certThumb
            AppId                     = $currentApp.appId
            AppName                   = $currentApp.appName
            RemoveDependencyFromAppId = $RemoveDependencyFromAppId
            OutputResultPath          = $resultPath
        }
        try {
            $configJsonText = $config | ConvertTo-Json -Depth 8 -ErrorAction Stop
            [System.IO.File]::WriteAllText($configPath, $configJsonText, (New-Object System.Text.UTF8Encoding($false)))
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Could not write the config file needed to run this: $($_.Exception.Message)", "Failed to prepare", "OK", "Error") | Out-Null
            return
        }

        # Fresh aliases for this nested -OnComplete closure - see note at
        # the top of Show-CreateInIntuneDialog for why this matters here too.
        $currentAppRef = $currentApp
        $queueRef = $Queue
        $queueIndexRef = $QueueIndex
        $resultsRef = $Results
        $retryAttemptRef = $RetryAttempt
        $chkAutoRemoveDepsRef = $chkAutoRemoveDeps
        $configPathRef = $configPath
        $resultPathRef = $resultPath
        $procBoxRef = $procBox
        $rtbLogRef = $rtbLog
        $appsRefRef = $appsRef
        $unsavedBoxRef = $unsavedBox
        $linkedFilePathRef = $linkedFilePath
        $deletedAnyBoxRef = $deletedAnyBox
        $RunNextBoxRef = $RunNextBox

        $procBoxRef.Proc = Start-PipelineProcess -ScriptContent $deleteScript -TempScriptName ".itsense_embedded_bulkdelete.ps1" -ArgumentString "-ConfigPath `"$configPathRef`"" -ExtraLogTarget $rtbLogRef -OnComplete {
            param($code)
            $procBoxRef.Proc = $null
            Remove-Item $configPathRef -Force -ErrorAction SilentlyContinue

            $status = "Failed"
            $message = "No result written (exit code $code)."
            $retryBlockingAppId = $null
            if (Test-Path $resultPathRef) {
                try {
                    $result = Get-Content -Path $resultPathRef -Raw | ConvertFrom-Json
                    Remove-Item $resultPathRef -Force -ErrorAction SilentlyContinue
                    if ($result.success) {
                        $status = "Deleted"
                        $message = "Deleted"
                        for ($ai = 0; $ai -lt $appsRefRef.Count; $ai++) {
                            if ($appsRefRef[$ai].appName -eq $currentAppRef.appName) {
                                $appsRefRef[$ai].appId = ""
                                break
                            }
                        }
                        $unsavedBoxRef.Value = $true
                        $deletedAnyBoxRef.Value = $true
                        # Direct-save after EACH successful delete, not just
                        # once at the very end - same reasoning as the
                        # identical per-item save in Show-BatchDeployDialog's
                        # own queue runner: a batch interrupted partway
                        # through must not leave an already-deleted app's
                        # stale App ID sitting in the catalog looking like
                        # it's still there.
                        [void](Save-AppsToFile -Path $linkedFilePathRef)
                        $rtbLogRef.AppendText("  [OK] Deleted`r`n")
                    }
                    elseif ($result.blockingAppId -and $chkAutoRemoveDepsRef.Checked -and $retryAttemptRef -lt 5) {
                        # Not recorded as Failed and not advancing the queue
                        # yet - retried in place below instead, same as the
                        # single-app dialog's own Yes/No retry, just without
                        # asking each time (the checkbox up front already
                        # covers that consent for the whole run).
                        $retryBlockingAppId = $result.blockingAppId
                    }
                    elseif ($result.blockingAppId) {
                        $message = if (-not $chkAutoRemoveDepsRef.Checked) {
                            "Blocked - Intune has it set as a dependency for `"$($result.blockingAppName)`". Tick `"Automatically remove blocking dependency relationships`" above and retry, or use `"Delete from Intune...`" on just this one app."
                        } else {
                            "Still blocked after removing $retryAttemptRef blocking dependenc$(if ($retryAttemptRef -eq 1) {'y'} else {'ies'}) in a row - stopping here to avoid looping forever. Currently blocked by `"$($result.blockingAppName)`" - use `"Delete from Intune...`" on just this one app to look closer."
                        }
                        $rtbLogRef.AppendText("  [FAILED] $message`r`n")
                    }
                    else {
                        $message = $result.error
                        $rtbLogRef.AppendText("  [FAILED] $message`r`n")
                    }
                }
                catch {
                    $message = "Could not read result: $($_.Exception.Message)"
                    $rtbLogRef.AppendText("  [FAILED] $message`r`n")
                }
            }
            else {
                $rtbLogRef.AppendText("  [FAILED] $message`r`n")
            }

            if ($retryBlockingAppId) {
                & $RunNextBoxRef.Value -Queue $queueRef -QueueIndex $queueIndexRef -Results $resultsRef -RemoveDependencyFromAppId $retryBlockingAppId -RetryAttempt ($retryAttemptRef + 1)
                return
            }

            $resultsRef.Add([pscustomobject]@{ AppName = $currentAppRef.appName; Status = $status; Message = $message })
            & $RunNextBoxRef.Value -Queue $queueRef -QueueIndex ($queueIndexRef + 1) -Results $resultsRef
        }.GetNewClosure()
    }.GetNewClosure()

    $btnDelete.Add_Click({
        $checkedNames = @($clbApps.CheckedItems | ForEach-Object { [string]$_ })
        if ($checkedNames.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Check at least one app to delete.", "Nothing selected", "OK", "Warning") | Out-Null
            return
        }
        $r = [System.Windows.Forms.MessageBox]::Show("Permanently delete these $($checkedNames.Count) app(s) from Intune?`n`n$($checkedNames -join ", ")", "Confirm bulk delete", "YesNo", "Warning")
        if ($r -ne "Yes") { return }

        $queueApps = New-Object System.Collections.Generic.List[object]
        foreach ($checkedName in $checkedNames) {
            $matchApp = $eligibleApps | Where-Object { $_.appName -eq $checkedName } | Select-Object -First 1
            if ($matchApp) { $queueApps.Add($matchApp) }
        }

        $btnDelete.Enabled = $false
        $btnSelectAll.Enabled = $false
        $btnSelectNone.Enabled = $false
        $clbApps.Enabled = $false
        $chkAutoRemoveDeps.Enabled = $false
        $txtConfirm.Enabled = $false
        $btnRetryFailed.Visible = $false
        $rtbLog.Clear()
        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblStatus.Text = "Starting..."

        $resultsList = New-Object System.Collections.Generic.List[object]
        & $RunNextBox.Value -Queue $queueApps.ToArray() -QueueIndex 0 -Results $resultsList
    }.GetNewClosure())

    $btnClose.Add_Click({
        if ($procBox.Proc -and -not $procBox.Proc.HasExited) {
            $r = [System.Windows.Forms.MessageBox]::Show(
                "A deletion is currently running. Stop it and close this dialog?`n`nAny app already deleted from Intune stays deleted - check the catalog's App ID column afterward.",
                "Stop and close?", "YesNo", "Warning")
            if ($r -ne "Yes") { return }
            try { $procBox.Proc.Kill() } catch { }
        }
        $dlg.Close()
    }.GetNewClosure())
    $dlg.CancelButton = $btnClose

    Set-Theme -Control $dlg
    [void]$dlg.ShowDialog($form)
    return $deletedAnyBox.Value
}

# =====================================================================
# =====================================================================
# Group name drift check
# =====================================================================
# Unlike the app "Renamed in Intune" check, there's no Entra ID group Object
# ID stored anywhere in the catalog - only the group NAME (in requiredFor /
# availableFor / uninstallFor). That means an actual rename can't be traced
# back the way an app rename can; all this can honestly tell you is "this
# name isn't found in Entra ID right now" - could be a rename, a deletion, a
# typo, or a group that was simply never created yet. Deliberately
# informational only (no auto-create button here) - Batch Assign / Assign
# Groups already auto-create a missing group when you actually apply
# assignments, and doing that automatically FROM this check too would risk
# silently creating a throwaway duplicate for what's actually a typo or a
# rename, which is exactly the mistake this check exists to catch before it
# happens.
function Show-GroupDriftCheckDialog {
    # Plain local aliases - see note in Start-IntuneAppLookup.
    $appsRef  = $Script:Apps
    $cacheRef = $Script:EntraDirectoryCache

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Group name check"
    $dlg.ClientSize = New-Object System.Drawing.Size(700, 500)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $lblIntro = New-Object System.Windows.Forms.Label
    $lblIntro.Text = "Checks every group name referenced anywhere in the catalog (Required/Available/Uninstall) against Entra ID, and lists any that aren't found - could be a rename, a deletion, a typo, or one that was never created. Review each and fix the catalog or Entra ID as needed."
    $lblIntro.Location = New-Object System.Drawing.Point(15,12)
    $lblIntro.Size = New-Object System.Drawing.Size(670,48)
    $dlg.Controls.Add($lblIntro)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Location = New-Object System.Drawing.Point(15,62)
    $lblStatus.Size = New-Object System.Drawing.Size(480,20)
    $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($lblStatus)

    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = "Refresh from Entra ID"
    $btnRefresh.Location = New-Object System.Drawing.Point(505,60)
    $btnRefresh.Size = New-Object System.Drawing.Size(180,26)
    $dlg.Controls.Add($btnRefresh)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(15,92)
    $grid.Size = New-Object System.Drawing.Size(670,340)
    $grid.ReadOnly = $true
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.SelectionMode = "FullRowSelect"
    $grid.MultiSelect = $false
    $grid.AutoSizeColumnsMode = "Fill"
    $grid.RowHeadersVisible = $false
    $grid.AutoGenerateColumns = $false
    $grid.BackgroundColor = [System.Drawing.SystemColors]::Window

    $colName = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colName.Name = "GroupName"; $colName.HeaderText = "Group name"; $colName.FillWeight = 35
    $grid.Columns.Add($colName) | Out-Null
    $colStatus = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colStatus.Name = "Status"; $colStatus.HeaderText = "Status"; $colStatus.FillWeight = 20
    $grid.Columns.Add($colStatus) | Out-Null
    $colUsedBy = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colUsedBy.Name = "UsedBy"; $colUsedBy.HeaderText = "Referenced by"; $colUsedBy.FillWeight = 45
    $grid.Columns.Add($colUsedBy) | Out-Null
    $dlg.Controls.Add($grid)

    # Not-found rows in bold orange, so the ones that actually need
    # attention stand out at a glance rather than blending into a full list.
    $grid.Add_CellFormatting({
        param($gridSender, $e)
        if ($grid.Columns[$e.ColumnIndex].Name -eq "Status" -and $e.Value -eq "Not found in Entra ID") {
            $e.CellStyle.ForeColor = [System.Drawing.Color]::DarkOrange
            $e.CellStyle.Font = New-Object System.Drawing.Font($grid.Font, [System.Drawing.FontStyle]::Bold)
        }
    }.GetNewClosure())

    # "Referenced by" can be a long, comma-joined app list that gets
    # truncated within the cell - double-click any row to see the full text
    # rather than needing to widen the column or scroll horizontally.
    $grid.Add_CellDoubleClick({
        param($gridSender, $e)
        if ($e.RowIndex -lt 0) { return }
        $row = $grid.Rows[$e.RowIndex]
        $groupName = [string]$row.Cells["GroupName"].Value
        $usedBy = [string]$row.Cells["UsedBy"].Value
        [System.Windows.Forms.MessageBox]::Show($usedBy, "Referenced by - $groupName", "OK", "Information") | Out-Null
    }.GetNewClosure())

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"
    $btnClose.Location = New-Object System.Drawing.Point(605,444)
    $btnClose.Size = New-Object System.Drawing.Size(80,32)
    $dlg.Controls.Add($btnClose)

    $populateGrid = {
        $grid.DataSource = $null
        $grid.Rows.Clear()

        $entraGroupNames = @{}
        foreach ($e in $cacheRef) {
            if ($e.type -eq "Group") {
                $norm = ($e.displayName.Trim() -replace '\s+', ' ')
                $entraGroupNames[$norm] = $true
            }
        }

        # Map every referenced group name -> the app names that reference it
        $usage = @{}
        foreach ($app in $appsRef) {
            $refs = @($app.requiredFor) + @($app.availableFor) + @($app.uninstallFor)
            foreach ($g in ($refs | Select-Object -Unique)) {
                if (-not $g) { continue }
                if (-not $usage.ContainsKey($g)) { $usage[$g] = New-Object System.Collections.Generic.List[string] }
                if (-not $usage[$g].Contains($app.appName)) { $usage[$g].Add($app.appName) }
            }
        }

        $rows = @($usage.Keys | ForEach-Object {
            $norm = ($_.Trim() -replace '\s+', ' ')
            [pscustomobject]@{
                Name  = $_
                Found = $entraGroupNames.ContainsKey($norm)
            }
        })
        # Not-found rows first (the ones that need a look), each bucket
        # sorted alphabetically within itself - PowerShell's default
        # ascending sort already puts $false before $true, so sorting by
        # Found ascending correctly puts "not found" (false) rows first.
        $ordered = @($rows | Sort-Object Found, Name)

        $missingCount = 0
        foreach ($r in $ordered) {
            if ($r.Found) {
                $status = "OK"
            }
            else {
                $status = "Not found in Entra ID"
                $missingCount++
            }
            [void]$grid.Rows.Add($r.Name, $status, ($usage[$r.Name] -join ", "))
        }

        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblStatus.Text = "$($usage.Keys.Count) group name(s) referenced in the catalog - $missingCount not found in Entra ID."
    }.GetNewClosure()

    $btnRefresh.Add_Click({
        $btnRefresh.Enabled = $false
        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblStatus.Text = "Fetching groups from Entra ID..."
        $dlg.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

        # Fresh aliases for the nested -OnComplete closure - see note at the
        # top of Show-CreateInIntuneDialog for why this matters here too.
        $btnRefreshRef = $btnRefresh
        $dlgRef = $dlg
        $lblStatusRef = $lblStatus
        $populateGridRef = $populateGrid

        Start-EntraDirectoryLookup -OnComplete {
            param($ok, $msg)
            $dlgRef.Cursor = [System.Windows.Forms.Cursors]::Default
            [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default
            $btnRefreshRef.Enabled = $true
            if (-not $ok) {
                $lblStatusRef.ForeColor = [System.Drawing.Color]::Firebrick
                $lblStatusRef.Text = "Fetch failed: $msg"
                return
            }
            & $populateGridRef
        }.GetNewClosure()
    }.GetNewClosure())

    $btnClose.Add_Click({ $dlg.Close() }.GetNewClosure())
    $dlg.CancelButton = $btnClose
    $dlg.AcceptButton = $btnClose

    # Deferred to Add_Shown rather than called directly here - kicking off
    # the async refresh (PerformClick -> Start-.../timer) BEFORE ShowDialog()
    # has actually shown/realized the window let the WaitCursor assignment
    # get set on a not-yet-created window handle, which doesn't reliably
    # "stick" - the cursor could end up stuck spinning even after the async
    # work (and its Cursor = Default reset) had already completed.
    #
    # Always a live fetch, never the reused-cache branch this used to have -
    # $cacheRef ($Script:EntraDirectoryCache) is shared across the whole
    # app, so it can already be non-empty here purely from something
    # unrelated done earlier in the session. This dialog's entire job is
    # telling you what's actually missing in Entra ID right now, so opening
    # it must mean "check now", not "show whatever happened to be cached
    # from something else, however old that is" - same reasoning as the
    # identical fix in Show-IntuneOnlyAppsDialog's own Add_Shown.
    $dlg.Add_Shown({
        $btnRefresh.PerformClick()
    }.GetNewClosure())

    Set-Theme -Control $dlg
    [void]$dlg.ShowDialog($form)
}

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
function Show-FavoriteGroupsManager {
    # Plain local alias - see note in Start-IntuneAppLookup. Needed here
    # specifically because $btnSave's own closure below mutates this
    # (Clear/Add), not just reads it.
    $favoriteGroupsRef = $Script:FavoriteGroups

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Favorite groups"
    $dlg.ClientSize = New-Object System.Drawing.Size(420, 400)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $lblIntro = New-Object System.Windows.Forms.Label
    $lblIntro.Text = "Checked groups show up as ready-to-tick options in every app's Required/Available/Uninstall lists. Unchecked groups still work fine via `"+ New group...`" in those lists - they just aren't shown by default. Right-click an unchecked group to remove it from this list entirely."
    $lblIntro.Location = New-Object System.Drawing.Point(15,12)
    $lblIntro.Size = New-Object System.Drawing.Size(390,60)
    $dlg.Controls.Add($lblIntro)

    $clb = New-Object System.Windows.Forms.CheckedListBox
    $clb.Location = New-Object System.Drawing.Point(15,78)
    $clb.Size = New-Object System.Drawing.Size(390,255)
    $clb.CheckOnClick = $true
    # Union of every group already used anywhere in the catalog and
    # whatever's currently marked a favorite - a favorite that no app
    # happens to use yet (e.g. one added here directly via "+ New
    # group...", below) still needs to show up checked, not silently
    # dropped just because Get-AllKnownGroups doesn't know about it yet.
    $knownGroups = @(Get-AllKnownGroups)
    $currentFavorites = @($favoriteGroupsRef)
    # First time this is ever opened - no favorites have been marked at
    # all yet - defaults to every group already in use as a sensible
    # starting point to prune from, rather than opening on an entirely
    # blank list that offers nothing to work with until every box gets
    # checked by hand one at a time.
    if ($currentFavorites.Count -eq 0 -and $knownGroups.Count -gt 0) {
        $currentFavorites = $knownGroups
    }
    $allOptions = @(@($knownGroups) + @($currentFavorites) | Select-Object -Unique | Sort-Object)
    foreach ($g in $allOptions) {
        $idx = $clb.Items.Add($g)
        if ($currentFavorites -contains $g) { $clb.SetItemChecked($idx, $true) }
    }
    Add-RemovableItemContextMenu -CheckedListBox $clb
    $dlg.Controls.Add($clb)

    $btnAddGroup = New-Object System.Windows.Forms.Button
    $btnAddGroup.Text = "+ New group..."
    $btnAddGroup.Location = New-Object System.Drawing.Point(15,340)
    $btnAddGroup.Size = New-Object System.Drawing.Size(120,30)
    $btnAddGroup.Add_Click({
        $picked = Show-EntraMemberPicker
        if ($picked) {
            $picked = $picked.Trim()
            if ($picked -and ($clb.Items -notcontains $picked)) {
                $idx = $clb.Items.Add($picked)
                $clb.SetItemChecked($idx, $true)
            }
        }
    }.GetNewClosure())
    $dlg.Controls.Add($btnAddGroup)

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = "Save"
    $btnSave.Location = New-Object System.Drawing.Point(230,340)
    $btnSave.Size = New-Object System.Drawing.Size(85,30)
    $btnSave.Add_Click({
        $favoriteGroupsRef.Clear()
        foreach ($item in $clb.CheckedItems) { [void]$favoriteGroupsRef.Add([string]$item) }
        if (Save-FavoriteGroups) {
            $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $dlg.Close()
        }
    }.GetNewClosure())
    $dlg.Controls.Add($btnSave)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(320,340)
    $btnCancel.Size = New-Object System.Drawing.Size(85,30)
    $btnCancel.Add_Click({
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $dlg.Close()
    }.GetNewClosure())
    $dlg.Controls.Add($btnCancel)

    $dlg.CancelButton = $btnCancel
    $dlg.AcceptButton = $btnSave
    Set-Theme -Control $dlg
    [void]$dlg.ShowDialog($form)
}

# Group manager dialog
# =====================================================================
# Small, standalone tool: create a security group (or reuse one that
# already exists by that exact name - idempotent, same as the group
# handling in Assign Groups) and add users or other groups to it as
# members. Not tied to the app catalog at all - useful for setting up a
# deployment group before any app references it.
function Show-GroupManagerDialog {
    # Plain local aliases - see note in Start-IntuneAppLookup.
    $tenantId    = $Script:GraphTenantId
    $clientId    = $Script:GraphClientId
    $certThumb   = $Script:GraphCertificateThumbprint
    $gmScript    = $Script:EmbeddedGroupManagerScript
    $cacheRef    = $Script:EntraDirectoryCache

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Group manager"
    $dlg.ClientSize = New-Object System.Drawing.Size(620, 600)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $lblIntro = New-Object System.Windows.Forms.Label
    $lblIntro.Text = "Creates a security group (or reuses one that already has this exact name). Shows its current members on the left, so you can review and remove them here too - not just add new ones."
    $lblIntro.Location = New-Object System.Drawing.Point(15,12)
    $lblIntro.Size = New-Object System.Drawing.Size(590,32)
    $dlg.Controls.Add($lblIntro)

    $lblGroupName = New-Object System.Windows.Forms.Label
    $lblGroupName.Text = "Group name"
    $lblGroupName.Location = New-Object System.Drawing.Point(15,50)
    $lblGroupName.AutoSize = $true
    $dlg.Controls.Add($lblGroupName)

    $txtGroupName = New-Object System.Windows.Forms.TextBox
    $txtGroupName.Location = New-Object System.Drawing.Point(15,69)
    $txtGroupName.Size = New-Object System.Drawing.Size(473,24)
    $dlg.Controls.Add($txtGroupName)

    $btnSearchGroup = New-Object System.Windows.Forms.Button
    $btnSearchGroup.Text = "Search..."
    $btnSearchGroup.Location = New-Object System.Drawing.Point(498,68)
    $btnSearchGroup.Size = New-Object System.Drawing.Size(107,26)
    $dlg.Controls.Add($btnSearchGroup)

    $lblDescription = New-Object System.Windows.Forms.Label
    $lblDescription.Text = "Description (optional)"
    $lblDescription.Location = New-Object System.Drawing.Point(15,104)
    $lblDescription.AutoSize = $true
    $dlg.Controls.Add($lblDescription)

    $txtDescription = New-Object System.Windows.Forms.TextBox
    $txtDescription.Location = New-Object System.Drawing.Point(15,123)
    $txtDescription.Size = New-Object System.Drawing.Size(590,48)
    $txtDescription.Multiline = $true
    $dlg.Controls.Add($txtDescription)

    # Left column - current, actual members (fetched live). Right column -
    # members queued up to add on the next Create/Update. Kept as two
    # visually separate lists rather than one merged view, since "what's
    # really there right now" and "what you're about to change" are
    # different things and conflating them invites mistakes.
    $lblCurrentMembers = New-Object System.Windows.Forms.Label
    $lblCurrentMembers.Text = "Current members"
    $lblCurrentMembers.Location = New-Object System.Drawing.Point(15,181)
    $lblCurrentMembers.AutoSize = $true
    $dlg.Controls.Add($lblCurrentMembers)

    $lstCurrentMembers = New-Object System.Windows.Forms.ListBox
    $lstCurrentMembers.Location = New-Object System.Drawing.Point(15,201)
    $lstCurrentMembers.Size = New-Object System.Drawing.Size(290,140)
    $dlg.Controls.Add($lstCurrentMembers)

    $btnLoadMembers = New-Object System.Windows.Forms.Button
    $btnLoadMembers.Text = "Load members"
    $btnLoadMembers.Location = New-Object System.Drawing.Point(15,345)
    $btnLoadMembers.Size = New-Object System.Drawing.Size(130,28)
    $dlg.Controls.Add($btnLoadMembers)

    $btnRemoveCurrentMember = New-Object System.Windows.Forms.Button
    $btnRemoveCurrentMember.Text = "Remove member..."
    $btnRemoveCurrentMember.Location = New-Object System.Drawing.Point(155,345)
    $btnRemoveCurrentMember.Size = New-Object System.Drawing.Size(150,28)
    $dlg.Controls.Add($btnRemoveCurrentMember)

    $lblMembers = New-Object System.Windows.Forms.Label
    $lblMembers.Text = "Members to add"
    $lblMembers.Location = New-Object System.Drawing.Point(315,181)
    $lblMembers.AutoSize = $true
    $dlg.Controls.Add($lblMembers)

    $lstMembers = New-Object System.Windows.Forms.ListBox
    $lstMembers.Location = New-Object System.Drawing.Point(315,201)
    $lstMembers.Size = New-Object System.Drawing.Size(290,140)
    $dlg.Controls.Add($lstMembers)

    $btnAddMember = New-Object System.Windows.Forms.Button
    $btnAddMember.Text = "+ Add member..."
    $btnAddMember.Location = New-Object System.Drawing.Point(315,345)
    $btnAddMember.Size = New-Object System.Drawing.Size(140,28)
    $dlg.Controls.Add($btnAddMember)

    $btnRemoveMember = New-Object System.Windows.Forms.Button
    $btnRemoveMember.Text = "Remove selected"
    $btnRemoveMember.Location = New-Object System.Drawing.Point(465,345)
    $btnRemoveMember.Size = New-Object System.Drawing.Size(140,28)
    $dlg.Controls.Add($btnRemoveMember)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Location = New-Object System.Drawing.Point(15,381)
    $lblStatus.Size = New-Object System.Drawing.Size(590,40)
    $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($lblStatus)

    $rtbLog = New-Object System.Windows.Forms.RichTextBox
    $rtbLog.Location = New-Object System.Drawing.Point(15,423)
    $rtbLog.Size = New-Object System.Drawing.Size(590,120)
    $rtbLog.ReadOnly = $true
    $rtbLog.BackColor = [System.Drawing.Color]::FromArgb(13,17,23)
    $rtbLog.ForeColor = [System.Drawing.Color]::Gainsboro
    $rtbLog.Font = New-Object System.Drawing.Font("Consolas", 8.5)
    $dlg.Controls.Add($rtbLog)

    $btnDeleteGroup = New-Object System.Windows.Forms.Button
    $btnDeleteGroup.Text = "Delete group..."
    $btnDeleteGroup.Location = New-Object System.Drawing.Point(15,553)
    $btnDeleteGroup.Size = New-Object System.Drawing.Size(150,32)
    $dlg.Controls.Add($btnDeleteGroup)

    $btnRun = New-Object System.Windows.Forms.Button
    $btnRun.Text = "Create / Update Group"
    $btnRun.Location = New-Object System.Drawing.Point(420,553)
    $btnRun.Size = New-Object System.Drawing.Size(185,32)
    $dlg.Controls.Add($btnRun)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"
    $btnClose.Location = New-Object System.Drawing.Point(325,553)
    $btnClose.Size = New-Object System.Drawing.Size(85,32)
    $dlg.Controls.Add($btnClose)

    # Parallel to $lstCurrentMembers.Items - index N here is the resolved
    # Object ID for whatever's at index N, as of the last Load.
    $currentMemberIds = New-Object System.Collections.Generic.List[string]
    $currentGroupIdBox = @{ Value = $null }

    # Parallel to $lstMembers.Items - index N here is the resolved Object ID
    # for whatever display text is at index N in the listbox.
    $pendingMemberIds = New-Object System.Collections.Generic.List[string]
    $procBox = @{ Proc = $null }

    # Stored closure so both btnLoadMembers and (after picking via Search,
    # or after a successful removal) other handlers can reuse the exact same
    # fetch-and-populate logic rather than duplicating it.
    $LoadCurrentMembers = {
        $groupName = $txtGroupName.Text.Trim()
        if (-not $groupName) { return }
        $btnLoadMembers.Enabled = $false
        $btnRemoveCurrentMember.Enabled = $false
        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblStatus.Text = "Loading current members..."

        # Fresh aliases for the nested -OnComplete closure - see note at the
        # top of Show-CreateInIntuneDialog for why this matters here too.
        $btnLoadMembersRef = $btnLoadMembers
        $btnRemoveCurrentMemberRef = $btnRemoveCurrentMember
        $lblStatusRef = $lblStatus
        $lstCurrentMembersRef = $lstCurrentMembers
        $currentMemberIdsRef = $currentMemberIds
        $currentGroupIdBoxRef = $currentGroupIdBox
        $groupNameRef = $groupName
        $txtDescriptionRef = $txtDescription

        Start-GroupMembersFetch -GroupName $groupNameRef -OnComplete {
            param($ok, $errMsg, $data)
            $btnLoadMembersRef.Enabled = $true
            $lstCurrentMembersRef.Items.Clear()
            $currentMemberIdsRef.Clear()
            $currentGroupIdBoxRef.Value = $null

            if (-not $ok) {
                $lblStatusRef.ForeColor = [System.Drawing.Color]::Firebrick
                $lblStatusRef.Text = "Could not load members: $errMsg"
                return
            }
            if (-not $data.Found) {
                $lblStatusRef.ForeColor = [System.Drawing.Color]::DarkOrange
                $lblStatusRef.Text = "No group named `"$groupNameRef`" exists yet - nothing to load."
                return
            }
            $currentGroupIdBoxRef.Value = $data.GroupId
            $txtDescriptionRef.Text = $data.Description
            foreach ($m in @($data.Members)) {
                [void]$lstCurrentMembersRef.Items.Add("[$($m.type)] $($m.displayName)")
                $currentMemberIdsRef.Add($m.id)
            }
            $btnRemoveCurrentMemberRef.Enabled = ($currentMemberIdsRef.Count -gt 0)
            $lblStatusRef.ForeColor = [System.Drawing.Color]::SeaGreen
            $lblStatusRef.Text = "Loaded $($currentMemberIdsRef.Count) current member(s) and description."
        }.GetNewClosure()
    }.GetNewClosure()

    $btnLoadMembers.Add_Click({ & $LoadCurrentMembers }.GetNewClosure())

    $txtGroupName.Add_TextChanged({
        # The loaded members belonged to whatever name was in this field
        # before - the moment that name changes, they're potentially
        # describing a different group entirely (or nothing, if this is now
        # a brand new name to create), so clear them rather than leave a
        # stale, misleading list sitting under a name it no longer matches.
        if ($currentGroupIdBox.Value -or $lstCurrentMembers.Items.Count -gt 0) {
            $lstCurrentMembers.Items.Clear()
            $currentMemberIds.Clear()
            $currentGroupIdBox.Value = $null
            $btnRemoveCurrentMember.Enabled = $false
            $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
            $lblStatus.Text = "Name changed - click Load members to see this group's current members."
        }
    }.GetNewClosure())

    $btnSearchGroup.Add_Click({
        $picked = Show-GroupOnlyPicker
        if ($picked) {
            $txtGroupName.Text = $picked
            & $LoadCurrentMembers
        }
    }.GetNewClosure())

    $btnAddMember.Add_Click({
        $pickedName = Show-EntraMemberPicker
        if (-not $pickedName) { return }
        $match = $cacheRef | Where-Object { $_.displayName -eq $pickedName } | Select-Object -First 1
        if (-not $match) {
            [System.Windows.Forms.MessageBox]::Show("`"$pickedName`" isn't in the fetched directory list, so there's no Object ID to add as a member. Use Refresh in the picker first, then pick from the list rather than typing a name manually.", "Can't resolve", "OK", "Warning") | Out-Null
            return
        }
        if ($pendingMemberIds.Contains($match.id)) { return }   # already queued
        [void]$lstMembers.Items.Add("[$($match.type)] $($match.displayName)")
        $pendingMemberIds.Add($match.id)
    }.GetNewClosure())

    $btnRemoveMember.Add_Click({
        if ($lstMembers.SelectedIndex -lt 0) { return }
        $idx = $lstMembers.SelectedIndex
        $pendingMemberIds.RemoveAt($idx)
        $lstMembers.Items.RemoveAt($idx)
    }.GetNewClosure())

    $btnRun.Add_Click({
        $groupName = $txtGroupName.Text.Trim()
        if (-not $groupName) {
            [System.Windows.Forms.MessageBox]::Show("Enter a group name first.", "No name", "OK", "Warning") | Out-Null
            return
        }

        $r = [System.Windows.Forms.MessageBox]::Show(
            "Creates `"$groupName`" if it doesn't already exist (exact name match), sets its description if you entered one, and adds $($pendingMemberIds.Count) member(s) to it. Continue?",
            "Confirm", "YesNo", "Question")
        if ($r -ne "Yes") { return }

        $btnRun.Enabled = $false
        $btnDeleteGroup.Enabled = $false
        $btnRemoveCurrentMember.Enabled = $false
        $btnLoadMembers.Enabled = $false
        $btnClose.Enabled = $false
        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblStatus.Text = "Working..."

        $configPath = Join-Path $env:TEMP (".itsense_groupmanager_config_" + [guid]::NewGuid().ToString("N") + ".json")
        $resultPath = Join-Path $env:TEMP (".itsense_groupmanager_result_" + [guid]::NewGuid().ToString("N") + ".json")
        $config = [pscustomobject]@{
            TenantId              = $tenantId
            ClientId              = $clientId
            CertificateThumbprint = $certThumb
            GroupName             = $groupName
            Description           = $txtDescription.Text.Trim()
            MemberIds             = @($pendingMemberIds)
            OutputResultPath      = $resultPath
        }
        try {
            $configJsonText = $config | ConvertTo-Json -Depth 8 -ErrorAction Stop
            [System.IO.File]::WriteAllText($configPath, $configJsonText, (New-Object System.Text.UTF8Encoding($false)))
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Could not write the config file needed to run this: $($_.Exception.Message)", "Failed to prepare", "OK", "Error") | Out-Null
            return
        }

        # Fresh aliases for the nested -OnComplete closure - see note at the
        # top of Show-CreateInIntuneDialog for why this matters here too.
        $btnRunRef = $btnRun
        $btnDeleteGroupRef = $btnDeleteGroup
        $btnRemoveCurrentMemberRef = $btnRemoveCurrentMember
        $btnLoadMembersRef = $btnLoadMembers
        $btnCloseRef = $btnClose
        $lblStatusRef = $lblStatus
        $resultPathRef = $resultPath
        $configPathRef = $configPath
        $procBoxRef = $procBox
        $rtbLogRef = $rtbLog
        $loadCurrentMembersRef = $LoadCurrentMembers
        $lstMembersRef = $lstMembers
        $pendingMemberIdsRef = $pendingMemberIds

        $procBoxRef.Proc = Start-PipelineProcess -ScriptContent $gmScript -TempScriptName ".itsense_embedded_groupmanager.ps1" -ArgumentString "-ConfigPath `"$configPathRef`"" -ExtraLogTarget $rtbLog -OnComplete {
            param($code)
            $btnRunRef.Enabled = $true
            $btnDeleteGroupRef.Enabled = $true
            $btnRemoveCurrentMemberRef.Enabled = $true
            $btnLoadMembersRef.Enabled = $true
            $btnCloseRef.Enabled = $true
            $procBoxRef.Proc = $null
            Remove-Item $configPathRef -Force -ErrorAction SilentlyContinue

            if (Test-Path $resultPathRef) {
                try {
                    $result = Get-Content -Path $resultPathRef -Raw | ConvertFrom-Json
                    Remove-Item $resultPathRef -Force -ErrorAction SilentlyContinue
                    if ($result.success) {
                        $lblStatusRef.ForeColor = [System.Drawing.Color]::SeaGreen
                        $lblStatusRef.Text = "Done - group ID: $($result.groupId). Reloading current members and description..."
                        # These were just successfully applied - leaving them
                        # sitting in "Members to add" would make them look
                        # still-pending even though they're now also showing
                        # up in "Current members" below, which is exactly the
                        # kind of stale-looking mismatch worth avoiding.
                        $lstMembersRef.Items.Clear()
                        $pendingMemberIdsRef.Clear()
                        & $loadCurrentMembersRef
                    }
                    else {
                        Write-DialogError -StatusLabel $lblStatusRef -LogBox $rtbLogRef -ErrorMessage $result.error
                    }
                }
                catch {
                    Write-DialogError -StatusLabel $lblStatusRef -LogBox $rtbLogRef -ErrorMessage "Could not read result (exit code $code)."
                }
            }
            else {
                Write-DialogError -StatusLabel $lblStatusRef -LogBox $rtbLogRef -ErrorMessage "No result written (exit code $code). See progress above."
            }
        }.GetNewClosure()
    }.GetNewClosure())

    $btnDeleteGroup.Add_Click({
        $groupName = $txtGroupName.Text.Trim()
        if (-not $groupName) {
            [System.Windows.Forms.MessageBox]::Show("Enter (or search for) a group name first.", "No name", "OK", "Warning") | Out-Null
            return
        }

        $r = [System.Windows.Forms.MessageBox]::Show(
            "This permanently deletes the group `"$groupName`" from Entra ID. If any app is currently assigned to it (required/available/uninstall), that assignment breaks too. This CANNOT be undone.`n`nContinue?",
            "Confirm group deletion", "YesNo", "Warning")
        if ($r -ne "Yes") { return }

        $btnRun.Enabled = $false
        $btnDeleteGroup.Enabled = $false
        $btnRemoveCurrentMember.Enabled = $false
        $btnLoadMembers.Enabled = $false
        $btnClose.Enabled = $false
        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblStatus.Text = "Deleting..."

        $configPath = Join-Path $env:TEMP (".itsense_groupmanager_config_" + [guid]::NewGuid().ToString("N") + ".json")
        $resultPath = Join-Path $env:TEMP (".itsense_groupmanager_result_" + [guid]::NewGuid().ToString("N") + ".json")
        $config = [pscustomobject]@{
            TenantId              = $tenantId
            ClientId              = $clientId
            CertificateThumbprint = $certThumb
            Mode                  = "Delete"
            GroupName             = $groupName
            MemberIds             = @()
            OutputResultPath      = $resultPath
        }
        try {
            $configJsonText = $config | ConvertTo-Json -Depth 8 -ErrorAction Stop
            [System.IO.File]::WriteAllText($configPath, $configJsonText, (New-Object System.Text.UTF8Encoding($false)))
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Could not write the config file needed to run this: $($_.Exception.Message)", "Failed to prepare", "OK", "Error") | Out-Null
            return
        }

        # Fresh aliases for the nested -OnComplete closure - see note at the
        # top of Show-CreateInIntuneDialog for why this matters here too.
        $btnRunRef = $btnRun
        $btnDeleteGroupRef = $btnDeleteGroup
        $btnRemoveCurrentMemberRef = $btnRemoveCurrentMember
        $btnLoadMembersRef = $btnLoadMembers
        $btnCloseRef = $btnClose
        $lblStatusRef = $lblStatus
        $resultPathRef = $resultPath
        $configPathRef = $configPath
        $procBoxRef = $procBox
        $rtbLogRef = $rtbLog
        $lstCurrentMembersRef = $lstCurrentMembers
        $currentMemberIdsRef = $currentMemberIds
        $currentGroupIdBoxRef = $currentGroupIdBox

        $procBoxRef.Proc = Start-PipelineProcess -ScriptContent $gmScript -TempScriptName ".itsense_embedded_groupmanager.ps1" -ArgumentString "-ConfigPath `"$configPathRef`"" -ExtraLogTarget $rtbLog -OnComplete {
            param($code)
            $btnRunRef.Enabled = $true
            $btnDeleteGroupRef.Enabled = $true
            $btnRemoveCurrentMemberRef.Enabled = $true
            $btnLoadMembersRef.Enabled = $true
            $btnCloseRef.Enabled = $true
            $procBoxRef.Proc = $null
            Remove-Item $configPathRef -Force -ErrorAction SilentlyContinue

            if (Test-Path $resultPathRef) {
                try {
                    $result = Get-Content -Path $resultPathRef -Raw | ConvertFrom-Json
                    Remove-Item $resultPathRef -Force -ErrorAction SilentlyContinue
                    if ($result.success) {
                        $lblStatusRef.ForeColor = [System.Drawing.Color]::SeaGreen
                        $lblStatusRef.Text = "Group deleted."
                        # The group no longer exists - clear the stale
                        # current-members list so it can't be confused for
                        # still being accurate.
                        $lstCurrentMembersRef.Items.Clear()
                        $currentMemberIdsRef.Clear()
                        $currentGroupIdBoxRef.Value = $null
                        $btnRemoveCurrentMemberRef.Enabled = $false
                    }
                    else {
                        Write-DialogError -StatusLabel $lblStatusRef -LogBox $rtbLogRef -ErrorMessage $result.error
                    }
                }
                catch {
                    Write-DialogError -StatusLabel $lblStatusRef -LogBox $rtbLogRef -ErrorMessage "Could not read result (exit code $code)."
                }
            }
            else {
                Write-DialogError -StatusLabel $lblStatusRef -LogBox $rtbLogRef -ErrorMessage "No result written (exit code $code). See progress above."
            }
        }.GetNewClosure()
    }.GetNewClosure())

    $btnRemoveCurrentMember.Add_Click({
        if ($lstCurrentMembers.SelectedIndex -lt 0) { return }
        if (-not $currentGroupIdBox.Value) {
            [System.Windows.Forms.MessageBox]::Show("Load members first.", "Nothing loaded", "OK", "Warning") | Out-Null
            return
        }
        $idx = $lstCurrentMembers.SelectedIndex
        $memberLabel = [string]$lstCurrentMembers.Items[$idx]
        $memberId = $currentMemberIds[$idx]

        $r = [System.Windows.Forms.MessageBox]::Show("Remove $memberLabel from this group? This only removes them from the group - it does not delete the user or group itself.", "Confirm removal", "YesNo", "Warning")
        if ($r -ne "Yes") { return }

        $btnRun.Enabled = $false
        $btnDeleteGroup.Enabled = $false
        $btnRemoveCurrentMember.Enabled = $false
        $btnLoadMembers.Enabled = $false
        $btnClose.Enabled = $false
        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblStatus.Text = "Removing..."

        $configPath = Join-Path $env:TEMP (".itsense_groupmanager_config_" + [guid]::NewGuid().ToString("N") + ".json")
        $resultPath = Join-Path $env:TEMP (".itsense_groupmanager_result_" + [guid]::NewGuid().ToString("N") + ".json")
        $config = [pscustomobject]@{
            TenantId              = $tenantId
            ClientId              = $clientId
            CertificateThumbprint = $certThumb
            Mode                  = "RemoveMember"
            GroupId               = $currentGroupIdBox.Value
            MemberId              = $memberId
            GroupName             = $txtGroupName.Text.Trim()
            MemberIds             = @()
            OutputResultPath      = $resultPath
        }
        try {
            $configJsonText = $config | ConvertTo-Json -Depth 8 -ErrorAction Stop
            [System.IO.File]::WriteAllText($configPath, $configJsonText, (New-Object System.Text.UTF8Encoding($false)))
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Could not write the config file needed to run this: $($_.Exception.Message)", "Failed to prepare", "OK", "Error") | Out-Null
            return
        }

        # Fresh aliases for the nested -OnComplete closure - see note at the
        # top of Show-CreateInIntuneDialog for why this matters here too.
        $btnRunRef = $btnRun
        $btnDeleteGroupRef = $btnDeleteGroup
        $btnRemoveCurrentMemberRef = $btnRemoveCurrentMember
        $btnLoadMembersRef = $btnLoadMembers
        $btnCloseRef = $btnClose
        $lblStatusRef = $lblStatus
        $resultPathRef = $resultPath
        $configPathRef = $configPath
        $procBoxRef = $procBox
        $rtbLogRef = $rtbLog
        $loadCurrentMembersRef = $LoadCurrentMembers

        $procBoxRef.Proc = Start-PipelineProcess -ScriptContent $gmScript -TempScriptName ".itsense_embedded_groupmanager.ps1" -ArgumentString "-ConfigPath `"$configPathRef`"" -ExtraLogTarget $rtbLog -OnComplete {
            param($code)
            $btnRunRef.Enabled = $true
            $btnDeleteGroupRef.Enabled = $true
            $btnRemoveCurrentMemberRef.Enabled = $true
            $btnLoadMembersRef.Enabled = $true
            $btnCloseRef.Enabled = $true
            $procBoxRef.Proc = $null
            Remove-Item $configPathRef -Force -ErrorAction SilentlyContinue

            if (Test-Path $resultPathRef) {
                try {
                    $result = Get-Content -Path $resultPathRef -Raw | ConvertFrom-Json
                    Remove-Item $resultPathRef -Force -ErrorAction SilentlyContinue
                    if ($result.success) {
                        $lblStatusRef.ForeColor = [System.Drawing.Color]::SeaGreen
                        $lblStatusRef.Text = "Removed. Reloading members..."
                        & $loadCurrentMembersRef
                    }
                    else {
                        Write-DialogError -StatusLabel $lblStatusRef -LogBox $rtbLogRef -ErrorMessage $result.error
                    }
                }
                catch {
                    Write-DialogError -StatusLabel $lblStatusRef -LogBox $rtbLogRef -ErrorMessage "Could not read result (exit code $code)."
                }
            }
            else {
                Write-DialogError -StatusLabel $lblStatusRef -LogBox $rtbLogRef -ErrorMessage "No result written (exit code $code). See progress above."
            }
        }.GetNewClosure()
    }.GetNewClosure())

    $btnClose.Add_Click({
        if ($procBox.Proc -and -not $procBox.Proc.HasExited) {
            $r = [System.Windows.Forms.MessageBox]::Show("A step is currently running. Stop it and close this dialog?", "Stop and close?", "YesNo", "Warning")
            if ($r -ne "Yes") { return }
            try { $procBox.Proc.Kill() } catch { }
        }
        $dlg.Close()
    }.GetNewClosure())
    $dlg.CancelButton = $btnClose

    Set-Theme -Control $dlg
    [void]$dlg.ShowDialog($form)
}

# ---------------------------------------------------------------
# App editor dialog
# ---------------------------------------------------------------
function Show-AppEditor {
    param($ExistingApp) # $null when adding a new app

    # Plain (non-$Script:) local alias - see note in Start-IntuneAppLookup.
    $cache = $Script:IntuneAppsCache
    $linkedFilePath = $Script:LinkedFilePath
    $appsRef = $Script:Apps
    $unsavedBoxRef = $Script:UnsavedChangesBox

    # Holds metadata handed back from "Deploy to Intune..." (Create/Update or
    # Save for later) while this editor is still open, so it can be folded
    # into the object this editor itself saves once "Save app to catalog" is
    # clicked. Declared here, before ANY button handler below gets
    # .GetNewClosure()'d - same reasoning as every other mutable container in
    # this file: closures capture variable VALUES at the moment they're
    # built, not a live reference, so this has to exist before the first
    # closure that touches it is created. A container (never reassigned), not
    # a plain variable, so the Deploy handler can WRITE into it and the Save
    # handler can later READ that write back out.
    $pendingDeployMetadataBox = @{ Value = $null }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = if ($ExistingApp) { "Edit app" } else { "Add app" }
    $dlg.ClientSize = New-Object System.Drawing.Size(470, 745)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $lblName = New-Object System.Windows.Forms.Label
    $lblName.Text = "App name"
    $lblName.Location = New-Object System.Drawing.Point(15,15)
    $lblName.AutoSize = $true
    $dlg.Controls.Add($lblName)

    $txtName = New-Object System.Windows.Forms.TextBox
    $txtName.Location = New-Object System.Drawing.Point(15,35)
    $txtName.Size = New-Object System.Drawing.Size(430,24)
    $txtName.Text = if ($ExistingApp) { $ExistingApp.appName } else { "" }
    $dlg.Controls.Add($txtName)

    $lblWinget = New-Object System.Windows.Forms.Label
    $lblWinget.Text = "Winget ID (leave blank for custom install scripts)"
    $lblWinget.Location = New-Object System.Drawing.Point(15,68)
    $lblWinget.AutoSize = $true
    $dlg.Controls.Add($lblWinget)

    $txtWinget = New-Object System.Windows.Forms.TextBox
    $txtWinget.Location = New-Object System.Drawing.Point(15,88)
    $txtWinget.Size = New-Object System.Drawing.Size(290,24)
    $txtWinget.Text = if ($ExistingApp) { $ExistingApp.wingetId } else { "" }
    $dlg.Controls.Add($txtWinget)

    $btnSearchWinget = New-Object System.Windows.Forms.Button
    $btnSearchWinget.Text = "Search winget..."
    $btnSearchWinget.Location = New-Object System.Drawing.Point(313,87)
    $btnSearchWinget.Size = New-Object System.Drawing.Size(132,26)
    $dlg.Controls.Add($btnSearchWinget)

    $lblUncommonNote = New-Object System.Windows.Forms.Label
    $lblUncommonNote.Text = "No Winget ID = treated as an uncommon app (needs its own .intunewin, not the shared init package)."
    $lblUncommonNote.Location = New-Object System.Drawing.Point(15,118)
    $lblUncommonNote.Size = New-Object System.Drawing.Size(430,32)
    $lblUncommonNote.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($lblUncommonNote)

    $lblId = New-Object System.Windows.Forms.Label
    $lblId.Text = "App ID (Intune mobileApp GUID - generated by Intune, from 3_GetAppIdFromIntune.ps1)"
    $lblId.Location = New-Object System.Drawing.Point(15,152)
    $lblId.AutoSize = $true
    $lblId.MaximumSize = New-Object System.Drawing.Size(430,0)
    $dlg.Controls.Add($lblId)

    $txtId = New-Object System.Windows.Forms.TextBox
    $txtId.Location = New-Object System.Drawing.Point(15,186)
    $txtId.Size = New-Object System.Drawing.Size(320,24)
    $txtId.Text = if ($ExistingApp) { $ExistingApp.appId } else { "" }
    $dlg.Controls.Add($txtId)

    $btnLookupId = New-Object System.Windows.Forms.Button
    $btnLookupId.Text = "Look up"
    $btnLookupId.Location = New-Object System.Drawing.Point(345,185)
    $btnLookupId.Size = New-Object System.Drawing.Size(100,26)
    $dlg.Controls.Add($btnLookupId)

    $btnCreateInIntune = New-Object System.Windows.Forms.Button
    $btnCreateInIntune.Text = "Deploy to Intune..."
    $btnCreateInIntune.Location = New-Object System.Drawing.Point(15,216)
    $btnCreateInIntune.Size = New-Object System.Drawing.Size(430,30)
    $dlg.Controls.Add($btnCreateInIntune)

    # Lives at the bottom now, to the right of "Save app to catalog" -
    # created here (rather than down where the Save/Cancel buttons are)
    # since $updateDeleteButtonState and its Add_Click handler are both
    # defined right below, next to the rest of this button's own logic.
    $btnDeleteFromIntune = New-Object System.Windows.Forms.Button
    $btnDeleteFromIntune.Text = "Delete from Intune..."
    $btnDeleteFromIntune.Location = New-Object System.Drawing.Point(170,705)
    $btnDeleteFromIntune.Size = New-Object System.Drawing.Size(190,30)
    $dlg.Controls.Add($btnDeleteFromIntune)
    $appEditorTip = New-Object System.Windows.Forms.ToolTip

    $lblIdStatus = New-Object System.Windows.Forms.Label
    $lblIdStatus.Text = ""
    $lblIdStatus.Location = New-Object System.Drawing.Point(15,250)
    $lblIdStatus.Size = New-Object System.Drawing.Size(430,20)
    $lblIdStatus.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($lblIdStatus)

    $TryFillIdFromCache = {
        $candidates = Find-IntuneMatches -Name $txtName.Text.Trim()
        if ($candidates.Count -eq 0) {
            $lblIdStatus.Text = "No matching app found in Intune for '$($txtName.Text.Trim())'."
            $lblIdStatus.ForeColor = [System.Drawing.Color]::DarkOrange
        }
        elseif ($candidates.Count -eq 1 -or $candidates[0].displayName -eq $txtName.Text.Trim()) {
            $txtId.Text = $candidates[0].id
            $lblIdStatus.Text = "Matched: $($candidates[0].displayName)"
            $lblIdStatus.ForeColor = [System.Drawing.Color]::SeaGreen
        }
        else {
            $pick = Show-SimpleListPicker -Title "Multiple matches" -Prompt "Several Intune apps match '$($txtName.Text.Trim())'. Pick one:" -Items ($candidates | ForEach-Object { "$($_.displayName)  [$($_.id)]" })
            if ($pick -and $pick -match '\[([0-9a-fA-F-]{36})\]\s*$') {
                $txtId.Text = $Matches[1]
                $lblIdStatus.Text = "Matched: $pick"
                $lblIdStatus.ForeColor = [System.Drawing.Color]::SeaGreen
            }
        }
    }.GetNewClosure()

    $btnLookupId.Add_Click({
        if (-not $txtName.Text.Trim()) {
            [System.Windows.Forms.MessageBox]::Show("Enter an app name first.", "No name", "OK", "Information") | Out-Null
            return
        }
        if ($cache.Count -eq 0) {
            $lblIdStatus.Text = "Connecting to Intune..."
            $lblIdStatus.ForeColor = [System.Drawing.Color]::DimGray
            # Fresh local aliases - see note in Show-CertificateSetupDialog's Test
            # Connection handler. The -OnComplete block below is a closure nested
            # inside this already-closured Add_Click handler, so it needs its own
            # freshly-assigned copies of anything it touches rather than reusing
            # $lblIdStatus/$TryFillIdFromCache directly.
            $lblIdStatusRef = $lblIdStatus
            $tryFillRef = $TryFillIdFromCache
            Start-IntuneAppLookup -OnComplete {
                param($ok, $data)
                if ($ok) { & $tryFillRef }
                else {
                    $lblIdStatusRef.Text = "Lookup failed: $data"
                    $lblIdStatusRef.ForeColor = [System.Drawing.Color]::Firebrick
                }
            }.GetNewClosure()
        }
        else {
            & $TryFillIdFromCache
        }
    }.GetNewClosure())

    $btnSearchWinget.Add_Click({
        # Deliberately not pre-filled with the app's Name field - the two
        # are often different (a custom/short catalog display name doesn't
        # necessarily match what the real winget package is called), so
        # pre-filling just meant clearing stale text before typing an actual
        # search term most of the time.
        $picked = Show-WingetSearchDialog
        if ($picked) { $txtWinget.Text = $picked }
    }.GetNewClosure())

    $btnCreateInIntune.Add_Click({
        if (-not $txtName.Text.Trim()) {
            [System.Windows.Forms.MessageBox]::Show("Enter an app name first.", "No name", "OK", "Information") | Out-Null
            return
        }
        $deployResult = Show-CreateInIntuneDialog -AppName $txtName.Text.Trim() -WingetId $txtWinget.Text.Trim() -ExistingAppId $txtId.Text.Trim() -FromAppEditor
        # Metadata (from Create/Update or "Save for later") is staged here,
        # not written to the catalog yet - Show-CreateInIntuneDialog, called
        # with -FromAppEditor, deliberately defers that write to this
        # editor's own "Save app to catalog" click, so Cancelling out of
        # THIS editor genuinely discards it instead of leaving a stray or
        # duplicate catalog entry behind (the bug this staging replaces:
        # that write used to happen immediately inside the Deploy dialog,
        # so a later "Save app to catalog" click added a SECOND entry for a
        # brand-new app, and Cancel couldn't undo the first one at all).
        if ($deployResult -and $deployResult.Metadata) {
            $pendingDeployMetadataBox.Value = $deployResult.Metadata
        }
        if ($deployResult -and $deployResult.NewAppId) {
            $txtId.Text = $deployResult.NewAppId
            if ($deployResult.NewAppName) { $txtName.Text = $deployResult.NewAppName }
            $lblIdStatus.Text = "Created/updated in Intune: $($deployResult.NewAppId) - click `"Save app to catalog`" below to save it here."
            $lblIdStatus.ForeColor = [System.Drawing.Color]::SeaGreen
        }
        elseif ($deployResult -and $deployResult.Metadata) {
            $lblIdStatus.Text = "Metadata staged - click `"Save app to catalog`" below to save it here."
            $lblIdStatus.ForeColor = [System.Drawing.Color]::SeaGreen
        }
    }.GetNewClosure())

    $btnDeleteFromIntune.Add_Click({
        if (-not $txtId.Text.Trim()) {
            # No App ID to delete from Intune at all - this click means
            # "remove the catalog entry itself" instead, matching what the
            # button's own text and tooltip say in this state (set below).
            # Same confirmation style as the main grid's own Delete button
            # (a plain Yes/No) rather than Show-DeleteAppDialog's
            # type-the-name-to-confirm - that stricter flow exists because
            # deleting an app FROM INTUNE is the genuinely irreversible,
            # live action; removing a catalog entry that already has no
            # Intune presence at all is a much lower-stakes, purely local
            # change.
            $r = [System.Windows.Forms.MessageBox]::Show("Delete '$($txtName.Text.Trim())' from the catalog? It has no App ID, so this only removes the local entry - there is nothing left in Intune to delete.", "Confirm delete", "YesNo", "Warning")
            if ($r -ne "Yes") { return }
            $delIdx = -1
            for ($di = 0; $di -lt $appsRef.Count; $di++) {
                if ($ExistingApp -and $appsRef[$di].appName -eq $ExistingApp.appName) { $delIdx = $di; break }
            }
            if ($delIdx -ge 0) { $appsRef.RemoveAt($delIdx) }
            $unsavedBoxRef.Value = $true
            [void](Save-AppsToFile -Path $linkedFilePath)
            $dlg.Close()
            return
        }
        $deleted = Show-DeleteAppDialog -AppId $txtId.Text.Trim() -AppName $txtName.Text.Trim()
        if (-not $deleted.Success) { return }
        if ($deleted.RemovedFromCatalog) {
            # Show-DeleteAppDialog already removed the whole catalog entry
            # and saved, when the user chose that there - nothing left in
            # this editor to keep editing, since the entry it opened for no
            # longer exists. Closing it (same as the "no App ID" branch
            # above) rather than leaving it open on a now-nonexistent app.
            $dlg.Close()
            return
        }
        $txtId.Text = ""
        # Direct-save immediately, matching the main grid's own "Quick
        # delete from Intune" - this specific branch was the one gap
        # left over from before that convention existed everywhere
        # else. Without this, the App ID was only ever cleared in this
        # dialog's own textbox and in-memory copy, not actually
        # persisted - reopening the editor without first clicking
        # "Save app" separately would reload the OLD, still-persisted
        # App ID from disk, making it look like the Intune delete
        # itself hadn't done anything at all, since this button's own
        # dynamic text (see $updateDeleteButtonState) would then
        # incorrectly still read the stale, non-empty value too.
        # Whole-element replacement, not property mutation - see the
        # extensive comment on the identical pattern in
        # Save-AppMetadataToLocalCatalog for why that distinction
        # specifically matters here.
        $delFromIntuneIdx = -1
        for ($dfi = 0; $dfi -lt $appsRef.Count; $dfi++) {
            if ($ExistingApp -and $appsRef[$dfi].appName -eq $ExistingApp.appName) { $delFromIntuneIdx = $dfi; break }
        }
        if ($delFromIntuneIdx -ge 0) {
            $existingForClear = $appsRef[$delFromIntuneIdx]
            $appsRef[$delFromIntuneIdx] = [pscustomobject]@{
                appId        = ""
                appName      = $existingForClear.appName
                wingetId     = $existingForClear.wingetId
                requiredFor  = @($existingForClear.requiredFor)
                availableFor = @($existingForClear.availableFor)
                uninstallFor = @($existingForClear.uninstallFor)
                metadata     = $existingForClear.metadata
            }
        }
        $unsavedBoxRef.Value = $true
        $delFromIntuneSaveOk = Save-AppsToFile -Path $linkedFilePath
        if ($delFromIntuneSaveOk) {
            $lblIdStatus.Text = "Deleted from Intune - App ID cleared and saved."
            $lblIdStatus.ForeColor = [System.Drawing.Color]::SeaGreen
        }
        else {
            $lblIdStatus.Text = "Deleted from Intune, but saving the cleared App ID failed - check the Log tab, then use Force save."
            $lblIdStatus.ForeColor = [System.Drawing.Color]::Firebrick
        }
    }.GetNewClosure())

    # Same button, two different meanings depending on state, rather than
    # a second button squeezed in somewhere - this dialog has no spare
    # width or height left for one without repositioning every control
    # below it (see the identical reasoning on the duplicate-name check
    # above). No App ID at all - nothing new was ever deployed, or it was
    # just deleted from Intune above - means "delete from Intune" makes no
    # sense; "delete from catalog" does instead. A brand-new, never-saved
    # app (no $ExistingApp yet) disables this entirely, since there is
    # neither an Intune app nor a catalog entry yet to delete either way.
    $updateDeleteButtonState = {
        if (-not $ExistingApp) {
            $btnDeleteFromIntune.Enabled = $false
            $btnDeleteFromIntune.Text = "Delete from Intune..."
            $appEditorTip.SetToolTip($btnDeleteFromIntune, "Save this app first - there's nothing to delete yet.")
        }
        elseif (-not $txtId.Text.Trim()) {
            $btnDeleteFromIntune.Enabled = $true
            $btnDeleteFromIntune.Text = "Delete app from catalog..."
            $appEditorTip.SetToolTip($btnDeleteFromIntune, "No App ID - removes this app from the local catalog instead, since there's nothing in Intune to delete.")
        }
        else {
            $btnDeleteFromIntune.Enabled = $true
            $btnDeleteFromIntune.Text = "Delete from Intune..."
            $appEditorTip.SetToolTip($btnDeleteFromIntune, "Permanently deletes this app from Intune and clears its App ID here.")
        }
    }.GetNewClosure()
    $txtId.Add_TextChanged({ & $updateDeleteButtonState }.GetNewClosure())
    & $updateDeleteButtonState

    # Favorites now, not every group ever used by any app in the whole
    # catalog - that "everything, always" list only grows over time and
    # gets harder to scan the more groups exist. "+ New member" (below,
    # within each list) remains the way to reach any other group not
    # marked a favorite - see Show-FavoriteGroupsManager for managing
    # which ones get this default, always-visible treatment.
    $known = @($Script:FavoriteGroups)

    function New-GroupBox {
        param($Title, $Top, $Selected)
        $gb = New-Object System.Windows.Forms.GroupBox
        $gb.Text = $Title
        $gb.Location = New-Object System.Drawing.Point(15,$Top)
        $gb.Size = New-Object System.Drawing.Size(430,120)

        $clb = New-Object System.Windows.Forms.CheckedListBox
        $clb.Location = New-Object System.Drawing.Point(10,20)
        $clb.Size = New-Object System.Drawing.Size(300,85)
        $clb.CheckOnClick = $true
        # Union of already-known groups and whatever's pre-selected (e.g. a
        # default group from Settings that no existing app has used yet) -
        # otherwise a brand-new default group would be silently dropped
        # instead of showing up checked.
        $allOptions = @(@($known) + @($Selected) | Select-Object -Unique)
        foreach ($g in $allOptions) {
            $idx = $clb.Items.Add($g)
            if ($Selected -contains $g) { $clb.SetItemChecked($idx, $true) }
        }
        Add-RemovableItemContextMenu -CheckedListBox $clb
        $gb.Controls.Add($clb)

        $btnAddGroup = New-Object System.Windows.Forms.Button
        $btnAddGroup.Text = "+ New group..."
        $btnAddGroup.Location = New-Object System.Drawing.Point(310,20)
        $btnAddGroup.Size = New-Object System.Drawing.Size(110,28)
        $btnAddGroup.Add_Click({
            $picked = Show-EntraMemberPicker
            if ($picked) {
                $picked = $picked.Trim()
                if ($picked -and ($clb.Items -notcontains $picked)) {
                    $idx = $clb.Items.Add($picked)
                    $clb.SetItemChecked($idx, $true)
                }
            }
        }.GetNewClosure())
        $gb.Controls.Add($btnAddGroup)

        return @{ Box = $gb; List = $clb }
    }

    $reqGroup   = New-GroupBox -Title "Required for"  -Top 280 -Selected @($ExistingApp.requiredFor)
    $availGroup = New-GroupBox -Title "Available for" -Top 410 -Selected @($ExistingApp.availableFor)
    $uninstGroup= New-GroupBox -Title "Uninstall for" -Top 540 -Selected @($ExistingApp.uninstallFor)
    $dlg.Controls.Add($reqGroup.Box)
    $dlg.Controls.Add($availGroup.Box)
    $dlg.Controls.Add($uninstGroup.Box)

    $btnAssignGroups = New-Object System.Windows.Forms.Button
    $btnAssignGroups.Text = "Assign Groups to Intune (this app only)..."
    $btnAssignGroups.Location = New-Object System.Drawing.Point(15,665)
    $btnAssignGroups.Size = New-Object System.Drawing.Size(430,30)
    $dlg.Controls.Add($btnAssignGroups)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = "Save app to catalog"
    $btnOk.Location = New-Object System.Drawing.Point(15,705)
    $btnOk.Size = New-Object System.Drawing.Size(150,30)
    $dlg.Controls.Add($btnOk)

    # $btnDeleteFromIntune itself is created earlier, up next to
    # $btnCreateInIntune's own logic - only its position, right here to
    # the right of "Save app to catalog", is decided at this end of the
    # bottom row.
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(365,705)
    $btnCancel.Size = New-Object System.Drawing.Size(90,30)
    $dlg.Controls.Add($btnCancel)

    $btnAssignGroups.Add_Click({
        if (-not $txtName.Text.Trim()) {
            [System.Windows.Forms.MessageBox]::Show("Enter an app name first.", "No name", "OK", "Information") | Out-Null
            return
        }
        Show-TargetedAssignDialog -AppId $txtId.Text.Trim() -AppName $txtName.Text.Trim() `
            -RequiredGroups @($reqGroup.List.CheckedItems) -AvailableGroups @($availGroup.List.CheckedItems) -UninstallGroups @($uninstGroup.List.CheckedItems) | Out-Null
    }.GetNewClosure())

    # Plain local box (not $Script:-qualified) - see the same pattern/reasoning in
    # Show-SimpleListPicker. $Script:-qualified reads/writes from inside a
    # .GetNewClosure()'d block do not reliably reach the real script scope.
    $resultBox = @{ Value = $null }

    $btnOk.Add_Click({
        if (-not $txtName.Text.Trim()) {
            [System.Windows.Forms.MessageBox]::Show("App name is required.", "Missing name", "OK", "Warning") | Out-Null
            return
        }
        # metadata explicitly preserved, not dropped - this editor has no
        # fields for it at all (that's what "Deploy to Intune..." is for),
        # so building the result without it would silently wipe out any
        # metadata already saved for this app the moment "Save app" is
        # clicked, even if nothing metadata-related was touched in this
        # dialog at all.
        #
        # Read directly from this app's own file on disk now, not from
        # $Script:Apps in memory - confirmed, directly, that by the time
        # this handler runs, $Script:Apps can have already lost this
        # app entirely (a name-based lookup against it came back with no
        # match at all, despite the app definitively existing seconds
        # earlier), even though the file on disk was independently
        # confirmed correct at that same moment. Rather than keep
        # chasing why the in-memory collection loses this specific entry
        # in this specific nested-dialog sequence, this reads from the
        # one source that's actually been reliable throughout: disk.
        # Falls back to $Script:Apps only if no file exists yet (a brand
        # new app that's never been saved at all).
        $preservedMetadata = $null
        $metadataSource = "none"
        # Freshest first: metadata just staged by "Deploy to Intune..." in
        # THIS still-open editing session (see $pendingDeployMetadataBox
        # above) is more current than whatever's already on disk or in
        # memory - a Create/Update or Save for later click that just ran
        # deliberately hasn't been written anywhere yet, precisely so this
        # click is the one that commits it.
        if ($pendingDeployMetadataBox.Value) {
            $preservedMetadata = $pendingDeployMetadataBox.Value
            $metadataSource = "pending-deploy"
        }
        if (-not $preservedMetadata) {
            try {
                $existingFilePath = Join-Path $linkedFilePath ((Get-SafeFileNameForApp -Name $ExistingApp.appName) + ".json")
                if ($ExistingApp -and (Test-Path $existingFilePath)) {
                    $onDiskApp = Get-Content -Path $existingFilePath -Raw | ConvertFrom-Json
                    if ($onDiskApp.metadata) {
                        $preservedMetadata = $onDiskApp.metadata
                        $metadataSource = "disk"
                    }
                }
            }
            catch {
                # Falls through to the in-memory fallback below - a failed
                # disk read here shouldn't block saving the rest of the edit.
            }
        }
        if (-not $preservedMetadata) {
            $liveAppForMetadata = $Script:Apps | Where-Object { $_.appName -eq $ExistingApp.appName } | Select-Object -First 1
            $preservedMetadata = if ($liveAppForMetadata) { $liveAppForMetadata.metadata } else { $ExistingApp.metadata }
            if ($preservedMetadata) { $metadataSource = "memory" }
        }
        # Logged explicitly - confirms which source actually supplied the
        # preserved metadata (disk, memory, or neither), rather than
        # assuming.
        Write-Log "Save app: ExistingApp.appName=`"$($ExistingApp.appName)`" - metadata source: $metadataSource, preservedMetadata is `$null: $($null -eq $preservedMetadata).`r`n"
        $resultBox.Value = [pscustomobject]@{
            appId        = $txtId.Text.Trim()
            appName      = $txtName.Text.Trim()
            wingetId     = $txtWinget.Text.Trim()
            requiredFor  = @($reqGroup.List.CheckedItems)
            availableFor = @($availGroup.List.CheckedItems)
            uninstallFor = @($uninstGroup.List.CheckedItems)
            metadata     = $preservedMetadata
        }
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dlg.Close()
    }.GetNewClosure())
    $btnCancel.Add_Click({
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $dlg.Close()
    }.GetNewClosure())

    $dlg.CancelButton = $btnCancel
    $dlg.AcceptButton = $btnOk
    Set-Theme -Control $dlg

    # Flags a duplicate name the moment it's typed, rather than only at
    # the very end when "Save app" is clicked - Save-AppsToFile's own
    # duplicate-name check (case-insensitive, whitespace-normalized, same
    # comparison used here for consistency) already blocks this at save
    # time regardless, but discovering that only after filling out the
    # entire form - metadata, requirements, groups, everything - is exactly
    # the kind of late, avoidable surprise this catches earlier instead.
    # Reuses the existing "App name" label above the field for the message
    # itself - a tooltip alone isn't visible without hovering, and this
    # dialog has no spare vertical room for a new label without
    # repositioning every control below it. Tints the field too, as a
    # second, immediate visual cue.
    #
    # Defined here, after Set-Theme, not up where $txtName/$lblName are
    # created - $lblNameThemedColor has to be captured after theming has
    # already set $lblName's real ForeColor, and .GetNewClosure() captures
    # variable VALUES at the moment it's called, not a live reference to
    # them - defining this any earlier would have captured
    # $lblNameThemedColor as $null, permanently, before it was ever
    # assigned.
    $lblNameOriginalText = $lblName.Text
    $lblNameThemedColor = $lblName.ForeColor
    $nameWarningTip = New-Object System.Windows.Forms.ToolTip
    $checkDuplicateName = {
        $typed = ($txtName.Text.Trim() -replace '\s+', ' ').ToLowerInvariant()
        $isDup = $false
        if ($typed) {
            foreach ($otherApp in $appsRef) {
                if (-not $otherApp.appName) { continue }
                if ($ExistingApp -and $otherApp.appName -eq $ExistingApp.appName) { continue }
                $otherNorm = ($otherApp.appName.Trim() -replace '\s+', ' ').ToLowerInvariant()
                if ($otherNorm -eq $typed) { $isDup = $true; break }
            }
        }
        if ($isDup) {
            $txtName.BackColor = [System.Drawing.Color]::FromArgb(255, 244, 214)
            $lblName.Text = "$lblNameOriginalText  -  an app with this name already exists"
            $lblName.ForeColor = [System.Drawing.Color]::DarkOrange
            $nameWarningTip.SetToolTip($txtName, "An app with this name already exists in the catalog. Saving will still warn again, but two apps with the same name isn't recommended.")
        }
        else {
            $txtName.BackColor = [System.Drawing.SystemColors]::Window
            $lblName.Text = $lblNameOriginalText
            $lblName.ForeColor = $lblNameThemedColor
            $nameWarningTip.SetToolTip($txtName, "")
        }
    }.GetNewClosure()
    $txtName.Add_TextChanged({ & $checkDuplicateName }.GetNewClosure())
    & $checkDuplicateName   # catches a pre-filled duplicate (e.g. Intune sync check's prefill) immediately on open, not just after the first keystroke

    $dlgResult = $dlg.ShowDialog($form)
    if ($dlgResult -eq [System.Windows.Forms.DialogResult]::OK) {
        return $resultBox.Value
    }
    return $null
}

$btnNew.Add_Click({
    $newApp = Show-AppEditor -ExistingApp $null
    if ($newApp) {
        [void]$Script:Apps.Add($newApp)
        $Script:UnsavedChangesBox.Value = $true
        # Direct-save, not just staged in memory - same reasoning as every
        # other single, atomic action made direct-save this session:
        # adding one app is a complete action in itself, with no batching
        # benefit to be had from deferring the write to a separate click.
        [void](Save-AppsToFile -Path $Script:LinkedFilePath)
        Refresh-Grid
    }
})

$btnEdit.Add_Click({
    $i = Get-SelectedAppIndex
    if ($null -eq $i) {
        [System.Windows.Forms.MessageBox]::Show("Select an app first.", "No selection", "OK", "Information") | Out-Null
        return
    }
    $updated = Show-AppEditor -ExistingApp $Script:Apps[$i]
    if ($updated) {
        # Logged before and after the assignment/save, mirroring the
        # checkpoint approach that already found the actual bug in Save
        # for later - confirms $updated genuinely carries metadata coming
        # OUT of the editor, and separately confirms $Script:Apps[$i]
        # still has it immediately after the assignment, before Save-
        # AppsToFile even runs. Narrows this down the same way: is
        # metadata already missing by the time the editor returns, or
        # does it go missing somewhere after that.
        Write-Log "btnEdit: `$updated returned from editor - has metadata: $($null -ne $updated.metadata).`r`n"
        $Script:Apps[$i] = $updated
        Write-Log "btnEdit: after assignment, `$Script:Apps[$i] has metadata: $($null -ne $Script:Apps[$i].metadata).`r`n"
        $Script:UnsavedChangesBox.Value = $true
        [void](Save-AppsToFile -Path $Script:LinkedFilePath)
        Refresh-Grid
    }
})

$grid.Add_CellDoubleClick({ $btnEdit.PerformClick() })

# Right-click context menu - lets Deploy/Assign/Delete happen straight from
# the grid instead of always requiring a trip through the full editor first.
$gridContextMenu = New-Object System.Windows.Forms.ContextMenuStrip
$menuItemEdit = New-Object System.Windows.Forms.ToolStripMenuItem "Edit..."
$menuItemDeploy = New-Object System.Windows.Forms.ToolStripMenuItem "Deploy to Intune..."
$menuItemPackage = New-Object System.Windows.Forms.ToolStripMenuItem "Package this app"
$menuItemAssign = New-Object System.Windows.Forms.ToolStripMenuItem "Assign Groups..."
# Already selection-aware via -ScopedIndices, same as the toolbar button
# it reuses - was reachable only from there before, requiring a
# pre-selection made before ever opening the toolbar dialog, when a
# right-click on the row(s) in question is the more natural way in.
$menuItemSyncMetadata = New-Object System.Windows.Forms.ToolStripMenuItem "Sync metadata from Intune..."
$menuItemDeleteIntune = New-Object System.Windows.Forms.ToolStripMenuItem "Delete from Intune..."
$menuItemSeparator = New-Object System.Windows.Forms.ToolStripSeparator
$menuItemRemoveCatalog = New-Object System.Windows.Forms.ToolStripMenuItem "Remove from catalog..."
[void]$gridContextMenu.Items.Add($menuItemEdit)
[void]$gridContextMenu.Items.Add($menuItemDeploy)
[void]$gridContextMenu.Items.Add($menuItemPackage)
[void]$gridContextMenu.Items.Add($menuItemAssign)
[void]$gridContextMenu.Items.Add($menuItemSyncMetadata)
[void]$gridContextMenu.Items.Add($menuItemDeleteIntune)
[void]$gridContextMenu.Items.Add($menuItemSeparator)
[void]$gridContextMenu.Items.Add($menuItemRemoveCatalog)
$grid.ContextMenuStrip = $gridContextMenu

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
# Remove from catalog... already did via $btnDelete; Assign Groups... and
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

    $menuItemDeploy.Enabled = $hasSelection -and -not $isMulti
    $menuItemDeploy.ToolTipText = if ($isMulti) { "Select just one app, or use `"Batch deploy...`" on the toolbar for apps already saved for later." } else { "" }

    $menuItemAssign.Text = if ($isMulti) { "Batch assign groups..." } else { "Assign Groups..." }
    $menuItemAssign.Enabled = $hasSelection

    # Same eligibility Show-SyncMetadataDialog itself checks (an app needs
    # an App ID before there's anything in Intune to pull metadata FROM) -
    # checked here too so this greys out up front instead of only showing
    # "nothing to do" after the click.
    $menuItemSyncMetadata.Enabled = $hasSelection -and (@($selectedIndices | ForEach-Object { $Script:Apps[$_] } | Where-Object { $_.appId }).Count -gt 0)

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
    $menuItemPackage.Text = if ($isMulti) { "Package $($selectedIndices.Count) app(s)" } else { "Package this app" }
    $menuItemPackage.Enabled = $hasSelection -and (@($selectedIndices | ForEach-Object { $Script:Apps[$_] } | Where-Object { Test-AppIsUncommon -App $_ }).Count -gt 0)
})

# Right-click selects the row under the cursor first, standard convention -
# otherwise the menu would act on whatever was already selected, which is
# confusing if that's a different row than the one just right-clicked. Only
# when that row isn't ALREADY part of the current selection - ctrl/shift
# right-clicking to extend a multi-selection before opening the menu (the
# same thing left-click already lets you do) would otherwise be undone by
# this collapsing it back down to one row first.
$grid.Add_CellMouseDown({
    param($gridSender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right -and $e.RowIndex -ge 0) {
        if (-not $grid.Rows[$e.RowIndex].Selected) {
            $grid.ClearSelection()
            $grid.Rows[$e.RowIndex].Selected = $true
        }
    }
})

$menuItemEdit.Add_Click({ $btnEdit.PerformClick() })
$menuItemRemoveCatalog.Add_Click({ $btnDelete.PerformClick() })

$menuItemDeploy.Add_Click({
    $i = Get-SelectedAppIndex
    if ($null -eq $i) { return }
    Invoke-QuickDeploy -Index $i
})

$menuItemPackage.Add_Click({
    $indices = Get-SelectedAppIndices
    if ($indices.Count -eq 0) { return }
    $tabs.SelectedTab = $tabPipeline
    if ($indices.Count -eq 1) {
        $app = $Script:Apps[$indices[0]]
        Invoke-LaunchStep -OnComplete $null -SingleFolderName (Get-SafeFileNameForApp -Name $app.appName)
        return
    }
    $uncommonApps = @($indices | ForEach-Object { $Script:Apps[$_] } | Where-Object { Test-AppIsUncommon -App $_ })
    $folderNames = @($uncommonApps | ForEach-Object { Get-SafeFileNameForApp -Name $_.appName })
    Invoke-LaunchStep -OnComplete $null -FolderNames $folderNames
})

$menuItemAssign.Add_Click({
    $indices = Get-SelectedAppIndices
    if ($indices.Count -eq 0) { return }
    if ($indices.Count -eq 1) {
        Invoke-QuickAssignGroups -Index $indices[0]
        return
    }
    Show-BatchAssignDialog -ScopedIndices $indices
})

$menuItemSyncMetadata.Add_Click({
    $indices = Get-SelectedAppIndices
    if ($indices.Count -eq 0) { return }
    Show-SyncMetadataDialog -ScopedIndices $indices
})

$menuItemDeleteIntune.Add_Click({
    $indices = Get-SelectedAppIndices
    if ($indices.Count -eq 0) { return }
    if ($indices.Count -eq 1) {
        Invoke-QuickDeleteFromIntune -Index $indices[0]
        return
    }
    if (Show-BulkDeleteFromIntuneDialog -Indices $indices) { Refresh-Grid }
})

$btnDelete.Add_Click({
    $indices = Get-SelectedAppIndices
    if ($indices.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Select an app first.", "No selection", "OK", "Information") | Out-Null
        return
    }
    if ($indices.Count -eq 1) {
        $name = $Script:Apps[$indices[0]].appName
        $r = [System.Windows.Forms.MessageBox]::Show("Delete '$name' from the catalog?", "Confirm delete", "YesNo", "Warning")
    }
    else {
        $names = @($indices | Sort-Object | ForEach-Object { $Script:Apps[$_].appName }) -join ", "
        $r = [System.Windows.Forms.MessageBox]::Show("Delete $($indices.Count) apps from the catalog?`n`n$names", "Confirm delete", "YesNo", "Warning")
    }
    if ($r -eq "Yes") {
        # Highest index first - removing from an ArrayList by index shifts
        # every later index down by one, so removing low-to-high would
        # invalidate the remaining queued indices partway through.
        foreach ($idx in ($indices | Sort-Object -Descending)) {
            $Script:Apps.RemoveAt($idx)
        }
        $Script:UnsavedChangesBox.Value = $true
        # Direct-save, not just staged in memory - matters even more here
        # than for most other actions, given the per-app file structure:
        # without this, a deleted app's own file would still sit on disk
        # untouched, and the app would silently reappear the next time the
        # catalog gets reloaded without an explicit save having happened
        # first.
        [void](Save-AppsToFile -Path $Script:LinkedFilePath)
        Refresh-Grid
    }
})

$btnSave.Add_Click({
    if (Save-AppsToFile -Path $Script:LinkedFilePath) {
        Refresh-Grid
        Set-Status "Saved $($Script:Apps.Count) app(s) to $Script:LinkedFilePath"
    }
})

# Ctrl+S saves the catalog when on the App Catalog tab - matches every other
# app's save shortcut. $form.KeyPreview lets the form see key presses before
# whatever control currently has focus does.
$form.KeyPreview = $true
$form.Add_KeyDown({
    if ($tabs.SelectedTab -ne $tabCatalog) { return }
    if ($_.Control -and $_.KeyCode -eq [System.Windows.Forms.Keys]::S) {
        $btnSave.PerformClick()
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
    if ($grid.Focused -and $_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
        $btnEdit.PerformClick()
        $_.SuppressKeyPress = $true
        return
    }
    if ($grid.Focused -and $_.KeyCode -eq [System.Windows.Forms.Keys]::Delete) {
        $btnDelete.PerformClick()
        $_.SuppressKeyPress = $true
        return
    }
})

$btnReload.Add_Click({
    if ($Script:UnsavedChangesBox.Value) {
        $r = [System.Windows.Forms.MessageBox]::Show("Discard unsaved changes and reload from disk?", "Reload", "YesNo", "Warning")
        if ($r -ne "Yes") { return }
    }
    Load-AppsFromFile -Path $Script:LinkedFilePath
    Refresh-Grid
})

$btnOpen.Add_Click({
    # FolderBrowserDialog now, not OpenFileDialog - the catalog is a
    # FOLDER of per-app files, not a single input.json to pick.
    $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
    $fbd.Description = "Select the folder containing per-app JSON files"
    $fbd.SelectedPath = $Script:RootPath
    if ($fbd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $Script:LinkedFilePath = $fbd.SelectedPath
        Load-AppsFromFile -Path $Script:LinkedFilePath
        Refresh-Grid
    }
})

$btnLookupIds.Add_Click({
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

$btnCertSetup.Add_Click({ Show-CertificateSetupDialog })
$btnCheckIntuneOnly.Add_Click({
    $changed = Show-IntuneOnlyAppsDialog
    if ($changed) { Refresh-Grid }
})

$btnBatchAssign.Add_Click({
    $selectedIndices = Get-SelectedAppIndices
    Show-BatchAssignDialog -ScopedIndices $selectedIndices
})
$btnSyncMetadata.Add_Click({
    $selectedIndices = Get-SelectedAppIndices
    Show-SyncMetadataDialog -ScopedIndices $selectedIndices
})
$btnBatchDeploy.Add_Click({
    $selectedIndices = Get-SelectedAppIndices
    Show-BatchDeployDialog -ScopedIndices $selectedIndices
})
$btnGroupManager.Add_Click({ Show-GroupManagerDialog })
$btnFavoriteGroups.Add_Click({ Show-FavoriteGroupsManager })
$btnGroupDrift.Add_Click({ Show-GroupDriftCheckDialog })

$txtSearch.Add_TextChanged({ Refresh-Grid })

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
$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Dock = "Bottom"
$progress.Height = 6
$progress.Style = "Marquee"
$progress.Visible = $false
$tabPipeline.Controls.Add($progress)

$logBox = New-Object System.Windows.Forms.RichTextBox
$logBox.Dock = "Fill"
$logBox.ReadOnly = $true
$logBox.BackColor = [System.Drawing.Color]::FromArgb(13,17,23)
$logBox.ForeColor = [System.Drawing.Color]::Gainsboro
$logBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$tabPipeline.Controls.Add($logBox)
$logBox.BringToFront()

function Write-Log {
    param([string]$Text, [System.Drawing.Color]$Color = [System.Drawing.Color]::Gainsboro)
    if ($logBox.InvokeRequired) {
        $logBox.Invoke([Action]{ Write-Log -Text $Text -Color $Color })
        return
    }
    $logBox.SelectionStart = $logBox.TextLength
    $logBox.SelectionLength = 0
    $logBox.SelectionColor = $Color
    $logBox.AppendText($Text)
    $logBox.ScrollToCaret()

    if ($Script:LogFileWriter) {
        try {
            $stamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            $Script:LogFileWriter.Write("[$stamp] $Text")
        }
        catch { }
    }
}

function Set-PipelineButtonsEnabled {
    param([bool]$Enabled)
    $btnRunLaunch.Enabled = $Enabled
    $progress.Visible = -not $Enabled
}

function Ensure-Folders {
    $folders = @("apps_uncommon","apps-data","logs","backups")
    foreach ($f in $folders) {
        $p = Join-Path $Script:RootPath $f
        if (-not (Test-Path $p)) {
            New-Item -ItemType Directory -Path $p -Force | Out-Null
            Write-Log "[+] Created folder: $f`r`n" ([System.Drawing.Color]::LightGreen)
        }
    }

    # Persistent, timestamped record of everything this app does -
    # separate from the in-app Log tab, which is lost the moment the
    # window closes. Worth having given this tool performs real
    # destructive, audit-relevant actions (deleting apps, changing group
    # membership, granting certificate trust).
    if (-not $Script:LogFileWriter) {
        try {
            $logPath = Join-Path (Join-Path $Script:RootPath "logs") ("itsense-intune-" + (Get-Date -Format "yyyy-MM-dd") + ".log")
            $Script:LogFileWriter = New-Object System.IO.StreamWriter($logPath, $true, [System.Text.Encoding]::UTF8)
            # Flushed periodically (below) rather than on every single
            # Write-Log call - AutoFlush forces a synchronous disk write on
            # every call, which runs on the UI thread and could cause
            # noticeable lag during high-volume logging (a busy batch
            # operation streaming a lot of child-process output). A
            # 2-second periodic flush keeps worst-case data loss on a
            # crash small (a couple of seconds of log lines) without
            # paying that cost on every single line.
            $Script:LogFileWriter.AutoFlush = $false

            # Plain local alias, referenced by the timer handler instead of
            # $Script:LogFileWriter directly - even code inside a function
            # (not just nested dialog closures) doesn't reliably see
            # $Script:-qualified variables from within an event handler
            # scriptblock; see the note in Start-IntuneAppLookup. Safe to
            # alias once here since Ensure-Folders only ever opens this
            # writer once per app session (guarded by the outer "if (-not
            # $Script:LogFileWriter)" check above), so this reference never
            # goes stale during the run.
            $logWriterRef = $Script:LogFileWriter

            $Script:LogFlushTimer = New-Object System.Windows.Forms.Timer
            $Script:LogFlushTimer.Interval = 2000
            $Script:LogFlushTimer.Add_Tick({
                try { $logWriterRef.Flush() } catch { }
            }.GetNewClosure())
            $Script:LogFlushTimer.Start()
        }
        catch {
            # A file-logging failure shouldn't take down the app itself -
            # the in-app Log tab still works fine either way.
            $Script:LogFileWriter = $null
        }
    }
}

# ---------------------------------------------------------------
# Async runner: launches a child powershell.exe, tails its output
# into the log box, and calls -OnComplete when it exits.
# ---------------------------------------------------------------
function Start-PipelineProcess {
    param(
        [string]$ScriptContent,
        [string]$TempScriptName,
        [string]$ArgumentString,
        [scriptblock]$OnComplete,
        # Optional - lets a caller (like Show-CreateInIntuneDialog, which is
        # modal and blocks the main window entirely) show live output locally
        # instead of only in the Pipeline tab's log, which the user can't
        # reach while a modal dialog is open.
        [System.Windows.Forms.RichTextBox]$ExtraLogTarget = $null,
        # Only needed for interactive Entra ID sign-in (certificate
        # upload/check). WAM (Windows' broker for interactive auth) needs an
        # actual parent window handle to attach its sign-in prompt to, and
        # fails outright ("A window handle must be configured") from a
        # hidden/windowless process - confirmed as a genuine WAM
        # requirement across multiple independent reports, including
        # Microsoft's own docs, which state Set-MgGraphOption
        # -DisableLoginByWAM has no effect in current module versions. A
        # normal, visible console window is the one fix confirmed to
        # actually work, so this is opt-in rather than default - every
        # other embedded script here uses app-only certificate auth and has
        # no reason to ever show a window.
        [switch]$ShowConsoleWindow
    )

    # The temp file has to live inside $Script:RootPath (not $env:TEMP), because
    # both embedded scripts use $PSScriptRoot internally to find input.json /
    # IntuneWinAppUtil.exe - see the note above $Script:EmbeddedPackageScript.
    $tempScriptPath = Join-Path $Script:RootPath $TempScriptName
    try {
        # No BOM, matching how the catalog file itself is written.
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tempScriptPath, $ScriptContent, $utf8NoBom)
    }
    catch {
        Write-Log "[ERROR] Could not write temp script: $($_.Exception.Message)`r`n" ([System.Drawing.Color]::Tomato)
        Set-PipelineButtonsEnabled $true
        return
    }

    $logFile = Join-Path $env:TEMP ("itsense_" + [guid]::NewGuid().ToString("N") + ".log")
    New-Item -Path $logFile -ItemType File -Force | Out-Null

    $escapedScript = $tempScriptPath -replace "'", "''"
    # Add-Content (not Tee-Object) deliberately - Tee-Object keeps an internal
    # buffered writer open for the whole pipeline and doesn't reliably flush to
    # disk as output is produced, only in unpredictable bursts. That left our
    # polling reader seeing wildly incomplete output on some runs. Add-Content
    # opens, writes, and fully closes the file handle on every single call, so
    # each line is guaranteed to be on disk (and visible to our reader) the
    # moment it's written, at the cost of only-trivial per-line overhead.
    #
    # Wrapped in a short retry loop - the reader side (below) explicitly opens
    # with FileShare.ReadWrite specifically to avoid locking out the writer,
    # but that only controls how OUR reader behaves; Add-Content's own
    # internal file handle isn't something this app can configure directly,
    # and it can occasionally land in the same instant the reader has the
    # file open, throwing "being used by another process." That's expected
    # to be rare and momentary (the other side always closes its handle
    # quickly), so a few short retries resolve it silently instead of
    # dropping that line of output and surfacing a visible error for what's
    # really just a timing collision, not a real failure.
    $innerCommand = "& '$escapedScript' $ArgumentString *>&1 | ForEach-Object { `$line = `$_; `$ok = `$false; for (`$i = 0; `$i -lt 5 -and -not `$ok; `$i++) { try { Add-Content -LiteralPath '$logFile' -Value `$line -Encoding UTF8 -ErrorAction Stop; `$ok = `$true } catch { Start-Sleep -Milliseconds 150 } } }"
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($innerCommand))

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell.exe"
    $psi.Arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = -not $ShowConsoleWindow
    if ($ShowConsoleWindow) {
        # Minimized rather than Normal - WAM (Windows' interactive sign-in
        # broker) needs SOME window handle to exist to attach its prompt to,
        # confirmed as a genuine requirement directly from Microsoft's own
        # MSAL docs ("trying to infer a window is not feasible"). What isn't
        # confirmed anywhere is that the window has to be VISIBLE rather
        # than just existing - a minimized window still has a valid handle,
        # it's just collapsed to the taskbar instead of sitting on screen as
        # a distracting black console. This is a reasonable, low-risk
        # experiment based on how window handles generally work, not a
        # documented guarantee - if sign-in starts failing with "A window
        # handle must be configured" again, this line is exactly what to
        # revert (back to the default Normal style).
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Minimized
    }
    # Without this, the child process inherits whatever folder the GUI itself happened
    # to be launched from - breaking relative paths inside the target script (e.g.
    # 1_GenerateIntunePackage.ps1's default ".\IntuneWinAppUtil.exe").
    $psi.WorkingDirectory = $Script:RootPath

    Set-PipelineButtonsEnabled $false

    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    }
    catch {
        Write-Log "[ERROR] Could not start process: $($_.Exception.Message)`r`n" ([System.Drawing.Color]::Tomato)
        Remove-Item $tempScriptPath -Force -ErrorAction SilentlyContinue
        Set-PipelineButtonsEnabled $true
        return
    }

    $readPos = [ref]0L
    $ReadNewLogContent = {
        if (-not (Test-Path $logFile)) { return }
        try {
            $stream = [System.IO.File]::Open($logFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $stream.Seek($readPos.Value, [System.IO.SeekOrigin]::Begin) | Out-Null
            $reader = New-Object System.IO.StreamReader($stream)
            $newText = $reader.ReadToEnd()
            $readPos.Value = $stream.Position
            $reader.Close(); $stream.Close()
            if ($newText) {
                Write-Log $newText
                if ($ExtraLogTarget) {
                    $ExtraLogTarget.AppendText($newText)
                    $ExtraLogTarget.SelectionStart = $ExtraLogTarget.TextLength
                    $ExtraLogTarget.ScrollToCaret()
                }
            }
        } catch { }
    }.GetNewClosure()

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 400
    $timer.Add_Tick({
        & $ReadNewLogContent
        if ($proc.HasExited) {
            $timer.Stop()
            $timer.Dispose()
            # The process reporting HasExited doesn't guarantee every last buffered
            # write has landed on disk yet - give it a brief moment, then do one more
            # read so a burst of output right at exit isn't silently dropped.
            Start-Sleep -Milliseconds 300
            & $ReadNewLogContent

            $code = $proc.ExitCode
            if ($code -eq 0) {
                Write-Log "`r`n[Finished - exit code 0]`r`n`r`n" ([System.Drawing.Color]::LightGreen)
            } else {
                Write-Log "`r`n[Finished - exit code $code]`r`n`r`n" ([System.Drawing.Color]::Orange)
            }
            Remove-Item $logFile -Force -ErrorAction SilentlyContinue
            Remove-Item $tempScriptPath -Force -ErrorAction SilentlyContinue
            Set-PipelineButtonsEnabled $true
            if ($OnComplete) { & $OnComplete $code }
        }
    }.GetNewClosure())
    $timer.Start()
    return $proc
}

function Invoke-LaunchStep {
    param([scriptblock]$OnComplete, [string]$SingleFolderName = "", [string[]]$FolderNames = @())
    Ensure-Folders
    $rootPath = $Script:RootPath   # plain local alias - see note in Start-IntuneAppLookup
    if ($SingleFolderName) {
        Write-Log "=== Package single app: $SingleFolderName ===`r`n" ([System.Drawing.Color]::DeepSkyBlue)
    }
    elseif ($FolderNames.Count -gt 0) {
        Write-Log "=== Package selected apps ($($FolderNames.Count)) ===`r`n" ([System.Drawing.Color]::DeepSkyBlue)
    }
    else {
        Write-Log "=== Package all apps (apps_uncommon) ===`r`n" ([System.Drawing.Color]::DeepSkyBlue)
    }
    $argStr = "-InputFolder '$(Join-Path $rootPath 'apps_uncommon')' -Force"
    if ($SingleFolderName) {
        $argStr += " -SingleFolderName '$SingleFolderName'"
    }
    elseif ($FolderNames.Count -gt 0) {
        $argStr += " -FolderNames '$($FolderNames -join ',')'"
    }
    Start-PipelineProcess -ScriptContent $Script:EmbeddedPackageScript -TempScriptName ".itsense_embedded_launch.ps1" -ArgumentString $argStr -OnComplete $OnComplete
}

$btnRunLaunch.Add_Click({
    # Selected rows (if any) scope this to just them; nothing selected falls
    # back to the previous "package everything" behavior.
    $selectedIndices = Get-SelectedAppIndices
    if ($selectedIndices.Count -gt 0) {
        $selectedUncommon = @($selectedIndices | ForEach-Object { $Script:Apps[$_] } | Where-Object { Test-AppIsUncommon -App $_ })
        if ($selectedUncommon.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("None of the $($selectedIndices.Count) selected app(s) are uncommon (they all have a Winget ID, so they share the one generic package) - nothing to build for this selection. Clear the selection to package everything, or select at least one uncommon app.", "Nothing to package", "OK", "Information") | Out-Null
            return
        }
        $folderNames = @($selectedUncommon | ForEach-Object { Get-SafeFileNameForApp -Name $_.appName })
        $tabs.SelectedTab = $tabPipeline
        Invoke-LaunchStep -OnComplete $null -FolderNames $folderNames
        return
    }
    $tabs.SelectedTab = $tabPipeline   # switch to the Log tab so the run is visible without an extra click
    Invoke-LaunchStep -OnComplete $null
})

# =====================================================================
# Startup
# =====================================================================
Ensure-Folders
Load-AppsFromFile -Path $Script:LinkedFilePath
Refresh-Grid
Write-Log "ITSENSE Intune deployment console ready (v$($Script:AppVersion)). Root: $Script:RootPath`r`n" ([System.Drawing.Color]::Gainsboro)

if (-not $Script:GraphTenantId -or -not $Script:GraphClientId -or -not $Script:GraphCertificateThumbprint) {
    Write-Log "No Graph connection configured yet - open 'Settings...' to set your Tenant ID, Client ID, and certificate before using anything that talks to Intune or Entra ID (App ID lookup, Deploy to Intune, Assign Groups, Intune sync check, Batch assign).`r`n" ([System.Drawing.Color]::Orange)
    # Also shown as a banner on the App Catalog tab itself, not just logged -
    # the Log tab isn't the default active one, so this is otherwise easy
    # for a new user to never see until something fails with no obvious
    # explanation why.
    $panelCredWarning.Visible = $true
}
else {
    # Proactive, since every Graph-based feature in this app depends on this
    # one certificate - previously this status only ever showed up if
    # someone happened to open Settings, meaning it could quietly expire
    # with zero warning until every Graph-based feature started failing
    # all at once.
    $certStatus = Get-CertificateStatusText -Thumbprint $Script:GraphCertificateThumbprint
    if ($certStatus.Color -ne [System.Drawing.Color]::SeaGreen) {
        Write-Log "Certificate warning: $($certStatus.Text) Open 'Settings...' to check or replace it.`r`n" ([System.Drawing.Color]::Orange)
        $lblCredWarning.Text = "Certificate warning: $($certStatus.Text) Open Settings to check or replace it."
        $panelCredWarning.Visible = $true
    }
}

$form.Add_FormClosing({
    if ($Script:UnsavedChangesBox.Value) {
        $r = [System.Windows.Forms.MessageBox]::Show("You have unsaved catalog changes. Close anyway?", "Unsaved changes", "YesNo", "Warning")
        if ($r -ne "Yes") { $_.Cancel = $true }
    }
})

$form.Add_FormClosed({
    if ($Script:LogFlushTimer) {
        try { $Script:LogFlushTimer.Stop(); $Script:LogFlushTimer.Dispose() } catch { }
        $Script:LogFlushTimer = $null
    }
    if ($Script:LogFileWriter) {
        try { $Script:LogFileWriter.Flush(); $Script:LogFileWriter.Close() } catch { }
        $Script:LogFileWriter = $null
    }
    # Only cleared here, on the whole app closing - not when Settings
    # closes, so closing/reopening Settings mid-session doesn't force a
    # fresh sign-in. See the note on Clear-DelegatedSignInCache.
    Clear-DelegatedSignInCache
})

Set-Theme -Control $form
[void]$form.ShowDialog()
