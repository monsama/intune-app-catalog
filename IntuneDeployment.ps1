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
    [switch]$Web,
    # The unattended managed-updates run (the nightly scheduled task) - no window, a report in Logs\reports.
    [switch]$RunUpdates,
    # With -RunUpdates: decide and report, change nothing.
    [switch]$PlanOnly,
    # With -RunUpdates: only the fast-track (urgent) releases - the second scheduled task, every two hours.
    [switch]$FastTrackOnly
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

# Files Windows marked as downloaded from the internet (the zip wasn't
# unblocked before it was unpacked): with the usual RemoteSigned policy
# PowerShell refuses to load them ("is not digitally signed"). This script
# already runs, so the person trusts this folder - offer to unblock the
# app's own files instead of failing on each one.
if ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop') {
    # Only the app's own code - never the data folder, which can hold thousands of packages.
    $Script:MarkedFiles = @(@(Get-Item -LiteralPath $PSCommandPath) + @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'code') -Recurse -File -ErrorAction SilentlyContinue) |
        Where-Object { $_ -and (Get-Item -LiteralPath $_.FullName -Stream Zone.Identifier -ErrorAction SilentlyContinue) })
    if ($Script:MarkedFiles.Count -gt 0) {
        Write-Host ""
        Write-Host " $($Script:MarkedFiles.Count) of this app's files are marked as downloaded from the internet" -ForegroundColor Yellow
        Write-Host " (the zip wasn't unblocked before it was unpacked). PowerShell won't load" -ForegroundColor Yellow
        Write-Host " them under the usual RemoteSigned policy." -ForegroundColor Yellow
        Write-Host ""
        # Ask only where someone can answer (not in a scheduled or redirected run).
        $canAsk = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
        $answer = if ($canAsk) { Read-Host " Unblock the app's own files (IntuneDeployment.ps1 and code\) now? [Y/n]" } else { 'n' }
        if ($answer -match '^(|y|yes|j|ja)$') {
            $Script:MarkedFiles | Unblock-File -ErrorAction SilentlyContinue
            Write-Host " Unblocked." -ForegroundColor Green
        }
        else {
            Write-Host " Left as they are. To do it yourself:" -ForegroundColor Yellow
            Write-Host "   Get-ChildItem -LiteralPath '$PSScriptRoot' -Recurse -File | Unblock-File" -ForegroundColor White
        }
        Write-Host ""
    }
}

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
            Path     = $relativePath
            Error    = $_.Exception.Message
            # PSSecurityException: refused by the execution policy, not broken
            Security = ($_.Exception -is [System.Management.Automation.PSSecurityException] -or $_.FullyQualifiedErrorId -like 'UnauthorizedAccess*')
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

if ($Script:FailedPrivateFiles.Count -gt 0 -and @($Script:FailedPrivateFiles | Where-Object { -not $_.Security }).Count -eq 0) {
    # Every file was refused by the execution policy - one explanation, not one per file.
    $policies = @(Get-ExecutionPolicy -List | Where-Object { $_.ExecutionPolicy -ne 'Undefined' } | ForEach-Object { "$($_.Scope)=$($_.ExecutionPolicy)" })
    $byGroupPolicy = @(Get-ExecutionPolicy -List | Where-Object { $_.Scope -in 'MachinePolicy', 'UserPolicy' -and $_.ExecutionPolicy -eq 'AllSigned' }).Count -gt 0
    Write-Host ""
    Write-Host "=================================================================" -ForegroundColor Red
    Write-Host " Cannot start: PowerShell's execution policy refused the app's files." -ForegroundColor Red
    Write-Host "=================================================================" -ForegroundColor Red
    Write-Host ""
    Write-Host " Execution policy: $($policies -join ', ')" -ForegroundColor Yellow
    Write-Host " First refusal: $($Script:FailedPrivateFiles[0].Error)" -ForegroundColor DarkGray
    Write-Host ""
    if ($byGroupPolicy) {
        Write-Host " A group policy requires every script to be signed (AllSigned). Unblocking" -ForegroundColor Yellow
        Write-Host " doesn't help: this needs a signed release - see README > Download - or an" -ForegroundColor Yellow
        Write-Host " exception from whoever manages the policy." -ForegroundColor Yellow
    }
    else {
        Write-Host " The files are most likely still marked as downloaded from the internet." -ForegroundColor Yellow
        Write-Host " Unblock them, then start the app again:" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "   Get-ChildItem -LiteralPath '$PSScriptRoot' -Recurse -File | Unblock-File" -ForegroundColor White
        Write-Host "   .\IntuneDeployment.ps1" -ForegroundColor White
    }
    Write-Host ""
    throw "Startup aborted: the execution policy refused $($Script:FailedPrivateFiles.Count) of the app's files. See above."
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
. $Script:WebAppPath -RootPath $PSScriptRoot -NoBrowser:$NoBrowser -RunUpdates:$RunUpdates -PlanOnly:$PlanOnly -FastTrackOnly:$FastTrackOnly
