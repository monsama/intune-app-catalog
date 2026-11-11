# Intune App Catalog & Deployment
# Copyright (C) 2026 Viktor Ljuca <https://monsama.ch>
# SPDX-License-Identifier: GPL-2.0-or-later
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 2 of the License, or (at your option)
# any later version. There is NO WARRANTY, to the extent permitted by law.
# See the LICENSE file for the full text.

<#
.SYNOPSIS
    Intune App Catalog & Deployment - start here.
.DESCRIPTION
    Loads the app's functions (code\Private), then starts the web interface
    (code\Web): a small server on 127.0.0.1 and an Edge or Chrome app window.
    Closing that window stops the app. The deployment steps themselves are
    separate scripts under code\EmbeddedScripts, run through
    code\Runner\Invoke-AppStep.ps1.

    Every file is checked before it is loaded: dot-sourcing a missing path
    does NOT stop PowerShell - it writes an error and carries on, and the
    gap would only show up later as "command not found" somewhere else.
#>

param(
    # Don't open a browser window - for tests, or to open the printed address yourself.
    [switch]$NoBrowser,
    # Accepted so older shortcuts keep working; the web interface is the only one now.
    [switch]$Web
)

$Script:RequiredPrivateFiles = @(
    "code\Private\AppFolders.ps1"
    "code\Private\AppState.ps1"
    "code\Private\Catalog\CatalogIO.ps1"
    "code\Private\Catalog\CatalogLogic.ps1"
    "code\Private\Catalog\CheckFindings.ps1"
    "code\Private\Catalog\ScriptCatalog.ps1"
    "code\Private\Diagnostics.ps1"
    "code\Private\Graph\Assignments.ps1"
    "code\Private\Graph\GraphLog.ps1"
    "code\Private\Graph\GraphModuleConflict.ps1"
    "code\Private\Graph\GraphReports.ps1"
    "code\Private\Graph\GraphToken.ps1"
    "code\Private\Graph\PlatformScripts.ps1"
    "code\Private\Helpers.ps1"
    "code\Private\Packaging.ps1"
    "code\Private\Pipeline.ps1"
    "code\Private\Prerequisites.ps1"
    "code\Private\Settings.ps1"
    "code\Private\Winget.ps1"
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

$Script:WebAppPath = Join-Path $PSScriptRoot "code\Web\Start-WebApp.ps1"
if (-not (Test-Path -LiteralPath $Script:WebAppPath -PathType Leaf)) {
    throw "Startup aborted: code\Web\Start-WebApp.ps1 was not found next to IntuneDeployment.ps1."
}
. $Script:WebAppPath -RootPath $PSScriptRoot -NoBrowser:$NoBrowser
