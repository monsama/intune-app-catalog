# Intune App Catalog & Deployment
# Copyright (C) 2026 Viktor Ljuca <https://monsama.ch>
# SPDX-License-Identifier: GPL-2.0-or-later

<#
.SYNOPSIS
    The web interface's Platform scripts page: Intune's PowerShell scripts
    for Windows devices, with the local copies in data\script-data beside
    them - what Show-PlatformScriptsDialog does in the classic window.

    Reads go to Graph from the request (Invoke-WebGraph); changes run the
    PlatformScripts step (code\EmbeddedScripts\PlatformScripts.ps1) as a job,
    like every other change the web interface makes.
#>

function Global:Invoke-WebGraph {
    <#
      Runs -Action with Graph connected app-only, the way the classic
      background fetches connect (reusing a matching connection). -Action
      gets one argument: a scriptblock (Uri, Method, Body) that calls Graph
      and returns the parsed JSON, throwing "<status> <reason>: <body>".
      Returns @{ ok; value } or @{ ok = $false; error } with the error made
      readable.
    #>
    param([scriptblock]$Action)
    if (-not (Test-GraphCredentialsConfigured -Quiet)) { return @{ ok = $false; error = 'Set up the connection in Settings first.' } }
    try {
        Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
        $ctx = Get-MgContext -ErrorAction SilentlyContinue
        $thumb = $Global:App.GraphCertificateThumbprint
        if ($null -eq $ctx -or $ctx.AuthType -ne 'AppOnly' -or $ctx.ClientId -ne $Global:App.GraphClientId -or ($thumb -and $ctx.CertificateThumbprint -and $ctx.CertificateThumbprint -ne $thumb)) {
            Connect-MgGraph -TenantId $Global:App.GraphTenantId -ClientId $Global:App.GraphClientId -CertificateThumbprint $thumb -NoWelcome -ErrorAction Stop
        }
        $call = {
            param([string]$Uri, [string]$Method = 'GET', $Body = $null)
            $p = @{ Uri = $Uri; Method = $Method; OutputType = 'HttpResponseMessage'; ErrorAction = 'Stop' }
            if ($null -ne $Body) { $p.Body = $Body; $p.ContentType = 'application/json' }
            $response = Invoke-MgGraphRequest @p
            $text = if ($response.Content) { $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() } else { '' }
            if (-not $response.IsSuccessStatusCode) { throw "$([int]$response.StatusCode) $($response.ReasonPhrase): $text" }
            if ($text) { $text | ConvertFrom-Json } else { $null }
        }
        return @{ ok = $true; value = (& $Action $call) }
    }
    catch {
        $msg = Get-InnermostErrorMessage $_.Exception
        $friendly = ConvertTo-FriendlyGraphError $msg
        if ("$msg" -match '\b403\b|Forbidden|Authorization_RequestDenied') {
            $friendly = "$friendly`nPlatform scripts need the DeviceManagementScripts.ReadWrite.All application permission (Settings > API permissions > Add required permissions...)."
        }
        return @{ ok = $false; error = $friendly }
    }
}

function Global:ConvertTo-WebScriptRow {
    # Pure: one row of the Platform scripts list, from Intune's listing
    # (ConvertTo-PlatformScriptRow) and the local copy of the same name, if any.
    param($Remote, $Local)
    $row = [ordered]@{ id = ''; displayName = ''; description = ''; fileName = ''; runAs = ''; runAs32Bit = ''; signature = ''; modified = ''; local = ''; localOnly = $false }
    if ($Remote) {
        $row.id = [string]$Remote.Id; $row.displayName = [string]$Remote.DisplayName; $row.description = [string]$Remote.Description
        $row.fileName = [string]$Remote.FileName; $row.runAs = [string]$Remote.RunAs; $row.runAs32Bit = [string]$Remote.RunAs32Bit
        $row.signature = [string]$Remote.Signature; $row.modified = [string]$Remote.Modified
        if ($Local) {
            # Only what a listing knows: the body and the groups aren't in it.
            $diffs = @(Get-ScriptFieldDiffs -Local $Local -Remote $Remote | Where-Object { $_.Field -notin @('scriptContent', 'assignedGroups') })
            $row.local = if ($diffs.Count -eq 0) { 'Saved' } else { "Differs ($($diffs.Count))" }
        }
        else { $row.local = 'Not saved here' }
    }
    elseif ($Local) {
        $row.displayName = [string]$Local.displayName; $row.description = [string]$Local.description; $row.fileName = [string]$Local.fileName
        $row.runAs = if ($Local.runAsAccount -eq 'user') { 'Signed-in user' } else { 'System' }
        $row.runAs32Bit = if ($Local.runAs32Bit) { 'Yes' } else { 'No' }
        $row.signature = if ($Local.enforceSignatureCheck) { 'Required' } else { 'Not required' }
        $row.local = 'Local only'; $row.localOnly = $true
    }
    return $row
}

function Global:Get-WebScriptsFolder { Get-AppFolder -Kind Scripts }

function Global:Get-WebScripts {
    # Intune's scripts (when connected) and the local copies, as one list.
    $folder = Get-WebScriptsFolder
    $imported = Import-ScriptsFromFolder -Path $folder
    $localByName = @{}
    foreach ($s in @($imported.Scripts)) { if ($s.displayName) { $localByName[[string]$s.displayName] = $s } }
    $tenant = $null; $tenantError = ''
    if (Test-GraphCredentialsConfigured -Quiet) {
        $read = Invoke-WebGraph -Action {
            param($Graph)
            $rows = New-Object System.Collections.Generic.List[object]
            # No scriptContent in the listing: a script can be 200 KB.
            $uri = "https://graph.microsoft.com/beta/deviceManagement/deviceManagementScripts?`$select=id,displayName,description,fileName,runAsAccount,runAs32Bit,enforceSignatureCheck,lastModifiedDateTime"
            while ($uri) {
                $page = & $Graph $uri
                foreach ($s in @($page.value)) { $rows.Add((ConvertTo-PlatformScriptRow $s)) }
                $uri = [string]$page.'@odata.nextLink'
            }
            , $rows.ToArray()
        }
        if ($read.ok) { $tenant = @($read.value) } else { $tenantError = $read.error }
    }
    else { $tenantError = 'Not connected - only the local copies are shown. Set up the connection in Settings.' }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($r in @($tenant | Where-Object { $_ })) {
        $local = $localByName[[string]$r.DisplayName]
        $rows.Add((ConvertTo-WebScriptRow -Remote $r -Local $local))
        if ($local) { [void]$localByName.Remove([string]$r.DisplayName) }
    }
    foreach ($orphan in @($localByName.Values | Sort-Object displayName)) {
        $row = ConvertTo-WebScriptRow -Local $orphan
        # Without a tenant to compare against, "Local only" would claim something nobody checked.
        if ($null -eq $tenant) { $row.local = 'Local copy' }
        $rows.Add($row)
    }
    return @{ ok = $true; rows = $rows.ToArray(); tenantRead = ($null -ne $tenant); tenantError = $tenantError; folder = $folder
        localErrors = @($imported.Errors) }
}

function Global:Get-WebScriptDetail {
    # One script for the editor: from Intune by id (body and groups), or the local copy by name.
    param($Data)
    $id = [string]$Data.id
    if ($id) {
        if ($id -notmatch '^[0-9a-fA-F-]{36}$') { return @{ ok = $false; error = 'That is not a script id.' } }
        $read = Invoke-WebGraph -Action {
            param($Graph)
            $s = & $Graph "https://graph.microsoft.com/beta/deviceManagement/deviceManagementScripts/$id"
            $groupNames = @(); $groupsKnown = $true
            try {
                $assignments = @((& $Graph "https://graph.microsoft.com/beta/deviceManagement/deviceManagementScripts/$id/assignments").value)
                $namesById = @{}
                foreach ($a in $assignments) {
                    $gid = [string]$a.target.groupId
                    if (-not $gid -or $namesById.Contains($gid)) { continue }
                    try { $namesById[$gid] = [string](& $Graph "https://graph.microsoft.com/v1.0/groups/$gid`?`$select=displayName").displayName } catch { }
                }
                $groupNames = @(Get-PlatformScriptGroupNames -Assignments $assignments -GroupNamesById $namesById)
            }
            catch { $groupsKnown = $false }
            @{ Script = $s; GroupNames = $groupNames; GroupsKnown = $groupsKnown }
        }
        if (-not $read.ok) { return $read }
        $s = $read.value.Script
        return @{ ok = $true; script = [ordered]@{
                id = $id; displayName = [string]$s.displayName; description = [string]$s.description; fileName = [string]$s.fileName
                runAsAccount = $(if ([string]$s.runAsAccount -eq 'user') { 'user' } else { 'system' }); runAs32Bit = [bool]$s.runAs32Bit
                enforceSignatureCheck = [bool]$s.enforceSignatureCheck; scriptContent = (ConvertFrom-PlatformScriptBase64 ([string]$s.scriptContent))
                groups = @($read.value.GroupNames); groupsKnown = [bool]$read.value.GroupsKnown; inIntune = $true } }
    }
    $name = [string]$Data.name
    $local = @((Import-ScriptsFromFolder -Path (Get-WebScriptsFolder)).Scripts) | Where-Object { $_.displayName -eq $name } | Select-Object -First 1
    if (-not $local) { return @{ ok = $false; error = "No local copy of '$name'." } }
    return @{ ok = $true; script = [ordered]@{
            id = ''; displayName = $local.displayName; description = $local.description; fileName = $local.fileName; runAsAccount = $local.runAsAccount
            runAs32Bit = [bool]$local.runAs32Bit; enforceSignatureCheck = [bool]$local.enforceSignatureCheck; scriptContent = $local.scriptContent
            groups = @($local.assignedGroups); groupsKnown = $true; inIntune = $false } }
}

function Global:ConvertTo-WebScriptInput {
    # Pure: what the editor sent, checked, as @{ Error; Record } - Record in the local catalog's shape.
    param($Form)
    $problem = Test-PlatformScriptInput -DisplayName ([string]$Form.displayName) -ScriptContent ([string]$Form.scriptContent)
    if ($problem) { return @{ Error = $problem } }
    if ([string]$Form.runAsAccount -notin 'system', 'user') { return @{ Error = 'Run as must be system or user.' } }
    $groups = @(@($Form.groups) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Select-Object -Unique)
    $record = ConvertTo-ScriptRecord @{
        displayName = ([string]$Form.displayName).Trim(); description = ([string]$Form.description).Trim()
        fileName = (Get-PlatformScriptFileName -DisplayName ([string]$Form.displayName) -FileName ([string]$Form.fileName))
        runAsAccount = [string]$Form.runAsAccount; runAs32Bit = [bool]$Form.runAs32Bit; enforceSignatureCheck = [bool]$Form.enforceSignatureCheck
        scriptContent = (ConvertTo-CanonicalLineEndings ([string]$Form.scriptContent)); assignedGroups = $groups
    }
    return @{ Error = ''; Record = $record }
}

function Global:Save-WebScriptLocally {
    # One script into the local folder; the others stay as they are. A rename drops the old file.
    param($Record, [string]$OldName = '')
    $folder = Get-WebScriptsFolder
    if ($OldName -and $OldName -ne $Record.displayName) {
        $old = Join-Path $folder ((Get-SafeFileNameForScript -Name $OldName) + '.json')
        if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue }
    }
    $saved = Save-ScriptsToFolder -Path $folder -Scripts @(, $Record) -NoPrune
    return @($saved.Errors)
}

function Global:Save-WebScript {
    <#
      destination 'Local': the local folder only. 'Intune': the PlatformScripts
      step creates (no id) or updates the script and, with assignGroups,
      replaces its assignments; a local copy of it is updated too.
    #>
    param($Data)
    $checked = ConvertTo-WebScriptInput $Data.script
    if ($checked.Error) { return @{ ok = $false; error = $checked.Error } }
    $record = $checked.Record
    $id = [string]$Data.script.id
    if ($id -and $id -notmatch '^[0-9a-fA-F-]{36}$') { return @{ ok = $false; error = 'That is not a script id.' } }
    $destination = [string]$Data.destination
    if ($destination -notin 'Local', 'Intune') { return @{ ok = $false; error = 'Save where?' } }
    # Before anything is written: a save to Intune that can't happen must not change the local copy either.
    if ($destination -eq 'Intune' -and -not (Test-GraphCredentialsConfigured -Quiet)) { return @{ ok = $false; error = 'Set up the connection in Settings first.' } }
    $oldName = [string]$Data.originalName
    $folder = Get-WebScriptsFolder
    $haveLocal = Test-Path -LiteralPath (Join-Path $folder ((Get-SafeFileNameForScript -Name $(if ($oldName) { $oldName } else { $record.displayName })) + '.json'))
    if ([string]$Data.destination -eq 'Local' -or $haveLocal) {
        $errors = Save-WebScriptLocally -Record $record -OldName $oldName
        if ($errors.Count) { return @{ ok = $false; error = ($errors -join "`n") } }
        if ([string]$Data.destination -eq 'Local') {
            Write-Log "[OK] '$($record.displayName)' saved to the local folder. Nothing was sent to Intune."
            return @{ ok = $true; local = $true }
        }
    }
    $resultPath = Join-Path $env:TEMP ".intunepkg_platformscript_result_$([guid]::NewGuid().ToString('N')).json"
    $config = [ordered]@{
        TenantId = $Global:App.GraphTenantId; ClientId = $Global:App.GraphClientId; CertificateThumbprint = $Global:App.GraphCertificateThumbprint
        OutputResultPath = $resultPath; Mode = 'Save'; ScriptId = $id
        DisplayName = $record.displayName; Description = $record.description; FileName = $record.fileName
        ScriptContentBase64 = (ConvertTo-PlatformScriptBase64 $record.scriptContent)
        RunAsAccount = $record.runAsAccount; RunAs32Bit = [bool]$record.runAs32Bit; EnforceSignatureCheck = [bool]$record.enforceSignatureCheck
        GroupNames = @($record.assignedGroups); AssignGroups = [bool]$Data.assignGroups
    }
    $verb = if ($id) { 'Save' } else { 'Create' }
    return (Start-WebStepJob -ScriptContent $Global:App.EmbeddedPlatformScriptsScript -Name 'platformscript' -ConfigJson ($config | ConvertTo-Json -Depth 6) -ResultPath $resultPath -Kind "$verb platform script $($record.displayName)")
}

function Global:Remove-WebScript {
    # With an id: deleted from Intune (the local copy stays). Without: the local copy goes.
    param($Data)
    $id = [string]$Data.id
    $name = [string]$Data.name
    if (-not $id) {
        $file = Join-Path (Get-WebScriptsFolder) ((Get-SafeFileNameForScript -Name $name) + '.json')
        if (-not (Test-Path -LiteralPath $file)) { return @{ ok = $false; error = "No local copy of '$name'." } }
        try { Remove-Item -LiteralPath $file -Force -ErrorAction Stop }
        catch { return @{ ok = $false; error = "Couldn't delete $file`: $($_.Exception.Message)" } }
        Write-Log "[OK] Local copy of '$name' deleted. Nothing was sent to Intune."
        return @{ ok = $true; local = $true }
    }
    if ($id -notmatch '^[0-9a-fA-F-]{36}$') { return @{ ok = $false; error = 'That is not a script id.' } }
    if (-not (Test-GraphCredentialsConfigured -Quiet)) { return @{ ok = $false; error = 'Set up the connection in Settings first.' } }
    $resultPath = Join-Path $env:TEMP ".intunepkg_platformscript_result_$([guid]::NewGuid().ToString('N')).json"
    $config = [ordered]@{
        TenantId = $Global:App.GraphTenantId; ClientId = $Global:App.GraphClientId; CertificateThumbprint = $Global:App.GraphCertificateThumbprint
        OutputResultPath = $resultPath; Mode = 'Delete'; ScriptId = $id; DisplayName = $name
    }
    return (Start-WebStepJob -ScriptContent $Global:App.EmbeddedPlatformScriptsScript -Name 'platformscript' -ConfigJson ($config | ConvertTo-Json -Depth 4) -ResultPath $resultPath -Kind "Delete platform script $name")
}

function Global:Get-WebScriptRunStatus {
    # How the script went on each device (deviceRunStates), with a summary.
    param($Data)
    $id = [string]$Data.id
    if ($id -notmatch '^[0-9a-fA-F-]{36}$') { return @{ ok = $false; error = 'This script is not in Intune, so it has never run anywhere.' } }
    $read = Invoke-WebGraph -Action {
        param($Graph)
        $rows = New-Object System.Collections.Generic.List[object]
        $uri = "https://graph.microsoft.com/beta/deviceManagement/deviceManagementScripts/$id/deviceRunStates?`$expand=managedDevice"
        $expanded = $true
        while ($uri) {
            try { $page = & $Graph $uri }
            catch {
                # Some tenants refuse the $expand; the plain list still works (device ids instead of names).
                if (-not $expanded) { throw }
                $expanded = $false
                $uri = "https://graph.microsoft.com/beta/deviceManagement/deviceManagementScripts/$id/deviceRunStates"
                continue
            }
            foreach ($r in @($page.value)) { $rows.Add((ConvertTo-ScriptRunStateRow $r)) }
            $uri = [string]$page.'@odata.nextLink'
        }
        , $rows.ToArray()
    }
    if (-not $read.ok) { return $read }
    $rows = @($read.value | Where-Object { $_ })
    return @{ ok = $true; summary = (Format-ScriptRunSummary $rows)
        rows = @($rows | ForEach-Object { [ordered]@{ device = $_.DeviceName; user = $_.UserName; state = $_.State; result = $_.Result; error = $_.ErrorText; lastRun = $_.LastRun } }) }
}

function Global:Save-WebScriptCopies {
    <#
      Reads every script in Intune in full (body and groups) and saves the
      local copies. Removes copies of scripts no longer in Intune only when
      every read worked - a failed read must never cost a local copy.
    #>
    $read = Invoke-WebGraph -Action {
        param($Graph)
        $ids = New-Object System.Collections.Generic.List[string]
        $uri = "https://graph.microsoft.com/beta/deviceManagement/deviceManagementScripts?`$select=id"
        while ($uri) { $page = & $Graph $uri; foreach ($s in @($page.value)) { $ids.Add([string]$s.id) }; $uri = [string]$page.'@odata.nextLink' }
        $records = New-Object System.Collections.Generic.List[object]
        $failed = New-Object System.Collections.Generic.List[string]
        $namesById = @{}
        foreach ($sid in $ids) {
            try {
                $s = & $Graph "https://graph.microsoft.com/beta/deviceManagement/deviceManagementScripts/$sid"
                $assignments = @((& $Graph "https://graph.microsoft.com/beta/deviceManagement/deviceManagementScripts/$sid/assignments").value)
                foreach ($a in $assignments) {
                    $gid = [string]$a.target.groupId
                    if ($gid -and -not $namesById.Contains($gid)) {
                        try { $namesById[$gid] = [string](& $Graph "https://graph.microsoft.com/v1.0/groups/$gid`?`$select=displayName").displayName } catch { $namesById[$gid] = $null }
                    }
                }
                $records.Add((ConvertTo-ScriptRecord @{
                    id = $sid; displayName = [string]$s.displayName; description = [string]$s.description; fileName = [string]$s.fileName
                    runAsAccount = [string]$s.runAsAccount; runAs32Bit = [bool]$s.runAs32Bit; enforceSignatureCheck = [bool]$s.enforceSignatureCheck
                    scriptContent = (ConvertFrom-PlatformScriptBase64 ([string]$s.scriptContent))
                    assignedGroups = [string[]]@(Get-PlatformScriptGroupNames -Assignments $assignments -GroupNamesById $namesById)
                }))
            }
            catch { $failed.Add("$sid`: $(Get-InnermostErrorMessage $_.Exception)") }
        }
        @{ Records = $records; Total = $ids.Count; Failed = $failed.ToArray() }
    }
    if (-not $read.ok) { return $read }
    $v = $read.value
    $everything = ($v.Failed.Count -eq 0)
    $saved = Save-ScriptsToFolder -Path (Get-WebScriptsFolder) -Scripts $v.Records -NoPrune:(-not $everything)
    $msg = "Saved $($saved.Saved) of $($v.Total) script(s) locally$(if ($saved.Removed) { ", $($saved.Removed) no longer in Intune removed" })."
    Write-Log "[OK] Platform scripts: $msg"
    foreach ($f in $v.Failed) { Write-Log "[WARN] Couldn't read platform script $f" }
    return @{ ok = $true; message = $msg; failed = @($v.Failed) + @($saved.Errors) }
}
