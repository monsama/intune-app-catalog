# Intune App Catalog & Deployment
# Copyright (C) 2026 Viktor Ljuca <https://monsama.ch>
# SPDX-License-Identifier: GPL-2.0-or-later

<#
.SYNOPSIS
    Runs one background step for the app: a pipeline step script, or a short
    command. Started by the app as

        powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File <app>\code\Runner\Invoke-AppStep.ps1 -Spec <file>.json

.DESCRIPTION
    Why this file exists: the app used to start every background PowerShell
    as "-ExecutionPolicy Bypass -EncodedCommand <base64>". That is exactly
    the shape endpoint protection (Cortex XDR, Defender ASR, ...) treats as
    malware - an unreadable command line - and it gets blocked or raises an
    alert for the security team. This way the command line names a file
    that ships with the app, and what runs is written in plain text in the
    spec file next to it.

    The spec (JSON, written by the app just before the start, deleted here
    as soon as it's read):
      Script       path of a step script to run with & (its own exit code
                   becomes this process's exit code)
      Arguments    text appended to that call, e.g. -ConfigPath "C:\x.json"
      GraphHelper  optional: a helper file dot-sourced first; its
                   Write-GraphReadSummary runs after the step
      Command      instead of Script: PowerShell text to run
      LogFile      optional: every line of output is appended there (the app
                   reads it while the step runs); without it, output goes to
                   stdout
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$Spec
)

$specData = Get-Content -LiteralPath $Spec -Raw -Encoding UTF8 | ConvertFrom-Json
Remove-Item -LiteralPath $Spec -Force -ErrorAction SilentlyContinue

$logFile = [string]$specData.LogFile

# Add-Content (not Tee-Object) and a short retry: each line is on disk the
# moment it's written, and a collision with the app reading the same file
# (it opens it with FileShare.ReadWrite) only ever lasts an instant.
function Write-StepLine {
    param($Line)
    if (-not $logFile) { $Line; return }
    for ($i = 0; $i -lt 5; $i++) {
        try { Add-Content -LiteralPath $logFile -Value $Line -Encoding UTF8 -ErrorAction Stop; return }
        catch { Start-Sleep -Milliseconds 150 }
    }
}

if ($specData.Script) {
    $scriptPath = [string]$specData.Script
    $helper = [string]$specData.GraphHelper
    # Arguments are PowerShell syntax built by the app (paths it quoted
    # itself), so they're parsed as such - the same text the step was
    # always called with.
    $call = [scriptblock]::Create("param(`$__step, `$__helper) if (`$__helper) { . `$__helper }; try { & `$__step $([string]$specData.Arguments) } finally { if (`$__helper -and (Get-Command Write-GraphReadSummary -ErrorAction SilentlyContinue)) { Write-GraphReadSummary } }")
    & $call $scriptPath $helper *>&1 | ForEach-Object { Write-StepLine $_ }
    exit $LASTEXITCODE
}
elseif ($specData.Command) {
    $command = [scriptblock]::Create([string]$specData.Command)
    & $command *>&1 | ForEach-Object { Write-StepLine $_ }
    exit $LASTEXITCODE
}
else {
    Write-StepLine "[FAILED] The step's spec names neither a script nor a command."
    exit 1
}
