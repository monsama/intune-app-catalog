# Intune "Platform scripts" - the PowerShell scripts Intune runs on enrolled
# Windows devices (Graph: /beta/deviceManagement/deviceManagementScripts).
#
# Pure logic only - building the request body, validating what the dialog
# collected, turning a listed script into a grid row - so it's covered by
# CatalogLogic.Tests.ps1. The dialogs are Show-PlatformScriptsDialog and
# Show-PlatformScriptEditorDialog; the Graph calls themselves happen in
# Start-PlatformScriptListFetch (read) and EmbeddedScripts\PlatformScripts.ps1
# (create/update/delete/assign).

function Global:ConvertTo-PlatformScriptBase64 {
    # Graph takes the script as base64 of its UTF-8 bytes, no BOM - a BOM
    # ends up as visible characters at the top of the script on the device.
    param([string]$ScriptContent)
    $text = ConvertTo-CanonicalLineEndings ([string]$ScriptContent)
    return [Convert]::ToBase64String((New-Object System.Text.UTF8Encoding($false)).GetBytes($text))
}

function Global:ConvertFrom-PlatformScriptBase64 {
    # The other direction, for showing a script that already exists in Intune
    param([string]$Base64)
    if (-not $Base64) { return "" }
    try {
        $text = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Base64))
        return ($text -replace "^﻿", "")
    }
    catch { return "" }
}

function Global:Get-PlatformScriptFileName {
    <#
      The file name Intune shows for the script. Uses what was typed, or
      derives one from the display name ("Set TimeZone" -> "Set-TimeZone.ps1")
      - Intune rejects a script with no file name.
    #>
    param([string]$DisplayName, [string]$FileName)
    $name = ([string]$FileName).Trim()
    if (-not $name) {
        $name = (([string]$DisplayName).Trim() -replace '[^A-Za-z0-9._-]+', '-').Trim('-')
        if (-not $name) { $name = "script" }
    }
    if ($name -notmatch '\.ps1$') { $name = "$name.ps1" }
    return $name
}

function Global:Test-PlatformScriptInput {
    <#
      What's wrong with this script, in one sentence - or $null when it's
      fine. Checked before anything is sent, so a missing name doesn't
      become a Graph error the user has to decode.
    #>
    param([string]$DisplayName, [string]$ScriptContent)
    if (-not ([string]$DisplayName).Trim()) { return "Enter a name for the script." }
    if (-not ([string]$ScriptContent).Trim()) { return "The script is empty - paste it in, or load a .ps1 file." }
    if (([string]$DisplayName).Trim().Length -gt 256) { return "The name is longer than the 256 characters Intune allows." }
    # Intune's own limit for a platform script
    if (((New-Object System.Text.UTF8Encoding($false)).GetBytes([string]$ScriptContent)).Length -gt 200000) {
        return "The script is larger than 200 KB, which is more than Intune accepts."
    }
    return $null
}

function Global:New-PlatformScriptBody {
    <#
      The deviceManagementScript object Graph expects, as a hashtable.
      Same shape for create (POST) and update (PATCH).
    #>
    param(
        [string]$DisplayName,
        [string]$Description,
        [string]$FileName,
        [string]$ScriptContent,
        [ValidateSet('system', 'user')][string]$RunAsAccount = 'system',
        [bool]$RunAs32Bit = $false,
        [bool]$EnforceSignatureCheck = $false
    )
    return @{
        "@odata.type"         = "#microsoft.graph.deviceManagementScript"
        displayName           = ([string]$DisplayName).Trim()
        description           = ([string]$Description).Trim()
        fileName              = Get-PlatformScriptFileName -DisplayName $DisplayName -FileName $FileName
        scriptContent         = ConvertTo-PlatformScriptBase64 $ScriptContent
        runAsAccount          = $RunAsAccount
        runAs32Bit            = $RunAs32Bit
        enforceSignatureCheck = $EnforceSignatureCheck
    }
}

function Global:New-PlatformScriptAssignBody {
    <#
      The body of the assign action: one entry per group, as the
      assignments collection (the older groupAssignments collection is
      what the deprecated per-group endpoint used). An empty list is a
      real value - it removes every assignment.
    #>
    param([string[]]$GroupIds)
    $assignments = @(@($GroupIds) | Where-Object { $_ } | Select-Object -Unique | ForEach-Object {
        @{
            "@odata.type" = "#microsoft.graph.deviceManagementScriptAssignment"
            target        = @{
                "@odata.type" = "#microsoft.graph.groupAssignmentTarget"
                groupId       = "$_"
            }
        }
    })
    return @{ deviceManagementScriptAssignments = $assignments }
}

function Global:ConvertTo-PlatformScriptRow {
    <#
      A listed script as the dialog's grid shows it. Takes what Graph
      returns (a hashtable from Invoke-MgGraphRequest, or an object).
    #>
    param($Script)
    $get = {
        param($Name)
        if ($null -eq $Script) { return "" }
        if ($Script -is [System.Collections.IDictionary]) { return [string]$Script[$Name] }
        return [string]$Script.$Name
    }
    $runAs = & $get 'runAsAccount'
    return [pscustomobject]@{
        Id          = & $get 'id'
        DisplayName = & $get 'displayName'
        Description = & $get 'description'
        FileName    = & $get 'fileName'
        RunAs       = if ($runAs -eq 'user') { "Signed-in user" } elseif ($runAs) { "System" } else { "" }
        RunAs32Bit  = if ("$(& $get 'runAs32Bit')" -eq 'True') { "Yes" } else { "No" }
        Signature   = if ("$(& $get 'enforceSignatureCheck')" -eq 'True') { "Required" } else { "Not required" }
        Modified    = Format-InstallStatusTime (& $get 'lastModifiedDateTime')
    }
}

function Global:Get-PlatformScriptGroupNames {
    <#
      The group names of a script's assignments, given the assignments
      Graph returned and a lookup of group id -> name. An id with no name
      known stays as the id, so nothing silently disappears.
    #>
    param($Assignments, $GroupNamesById)
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($assignment in @($Assignments)) {
        $target = if ($assignment -is [System.Collections.IDictionary]) { $assignment['target'] } else { $assignment.target }
        if (-not $target) { continue }
        $groupId = if ($target -is [System.Collections.IDictionary]) { [string]$target['groupId'] } else { [string]$target.groupId }
        if (-not $groupId) { continue }
        $name = $null
        if ($GroupNamesById -and $GroupNamesById.Contains($groupId)) { $name = [string]$GroupNamesById[$groupId] }
        $names.Add($(if ($name) { $name } else { $groupId }))
    }
    return $names.ToArray()
}
