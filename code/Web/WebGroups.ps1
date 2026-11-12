# Intune App Catalog & Deployment
# Copyright (C) 2026 Viktor Ljuca <https://monsama.ch>
# SPDX-License-Identifier: GPL-2.0-or-later

<#
.SYNOPSIS
    The web interface's Groups page: the Entra ID security groups the
    catalog assigns apps to.

    Reads go to Graph from the request (Invoke-WebGraph, WebGraph.ps1);
    changes run the GroupManager step (code\EmbeddedScripts\GroupManager.ps1)
    as a job.
#>

# A function, not a variable: request runspaces get this app's functions, not its script variables.
function Global:Get-WebGroupRoles { [ordered]@{ requiredFor = 'Required'; availableFor = 'Available'; uninstallFor = 'Uninstall'; excludeFor = 'Excluded' } }

function Global:Get-WebGroupUsage {
    # Pure: every group the catalog's apps use, with which apps use it and how.
    param($Apps)
    $roles = Get-WebGroupRoles
    $byName = @{}
    foreach ($a in @($Apps)) {
        foreach ($field in $roles.Keys) {
            foreach ($g in @($a.$field | Where-Object { $_ })) {
                $key = ([string]$g).ToLowerInvariant()
                if (-not $byName.ContainsKey($key)) { $byName[$key] = [ordered]@{ name = [string]$g; uses = New-Object System.Collections.Generic.List[object] } }
                $byName[$key].uses.Add([ordered]@{ app = [string]$a.appName; role = $roles[$field] })
            }
        }
    }
    return @($byName.Values | Sort-Object { $_.name } | ForEach-Object { [ordered]@{ name = $_.name; uses = $_.uses.ToArray(); apps = @($_.uses | ForEach-Object { $_.app } | Select-Object -Unique).Count } })
}

function Global:Rename-WebGroupInApps {
    # Pure: changes -Old to -New in every app's group lists (compared without case); returns the names of the apps changed.
    param($Apps, [string]$Old, [string]$New)
    $changed = New-Object System.Collections.Generic.List[string]
    foreach ($a in @($Apps)) {
        $hit = $false
        foreach ($field in (Get-WebGroupRoles).Keys) {
            if ($null -eq $a.$field) { continue }
            $list = @($a.$field)
            if (@($list | Where-Object { [string]$_ -ieq $Old }).Count -eq 0) { continue }
            # Without case, like Entra ID: an app that had both names keeps one.
            $seen = @{}
            $a.$field = @($list | ForEach-Object { if ([string]$_ -ieq $Old) { $New } else { $_ } } | Where-Object { $k = ([string]$_).ToLowerInvariant(); if ($seen.ContainsKey($k)) { $false } else { $seen[$k] = $true; $true } })
            $hit = $true
        }
        if ($hit) { $changed.Add([string]$a.appName) }
    }
    return $changed.ToArray()
}

function Global:Test-WebGroupName {
    # Pure: what's wrong with a group name, or ''.
    param([string]$Name)
    $n = ([string]$Name).Trim()
    if (-not $n) { return 'Enter a group name.' }
    if ($n.Length -gt 256) { return 'A group name can be at most 256 characters.' }
    if ($n -match '[\x00-\x1f]') { return 'A group name cannot contain control characters.' }
    return ''
}

function Global:Get-WebGroups {
    $catalog = Read-WebCatalogRecords
    return @{ ok = $true; groups = @(Get-WebGroupUsage $catalog.Apps); favorites = @($Global:App.FavoriteGroups | Where-Object { $_ }) }
}

function Global:Get-WebGroupsStatus {
    <#
      Which of the catalog's groups exist in Entra ID: looked up by exact
      name, 15 per request (Get-GroupLookupUris). state none (no connection),
      ok (with found: the names Entra ID has, as the catalog spells them, and
      their ids) or error.
    #>
    $names = @(Get-WebCatalogGroupNames -Apps (Read-WebCatalogRecords).Apps)
    if (-not (Test-GraphCredentialsConfigured -Quiet)) { return @{ ok = $true; state = 'none'; found = @() } }
    if ($names.Count -eq 0) { return @{ ok = $true; state = 'ok'; found = @() } }
    $read = Invoke-WebGraph -Permission 'Group.Read.All' -Action {
        param($Graph)
        $hits = New-Object System.Collections.Generic.List[object]
        foreach ($uri in @(Get-GroupLookupUris -Names $names)) {
            while ($uri) {
                $page = & $Graph $uri
                foreach ($g in @($page.value)) { $hits.Add([ordered]@{ name = [string]$g.displayName; id = [string]$g.id }) }
                $uri = [string]$page.'@odata.nextLink'
            }
        }
        $hits.ToArray()
    }
    if (-not $read.ok) { return @{ ok = $true; state = 'error'; error = [string]$read.error; found = @() } }
    $found = foreach ($n in $names) {
        $hit = @($read.value | Where-Object { $_.name -ieq $n }) | Select-Object -First 1
        if ($hit) { [ordered]@{ name = $n; id = $hit.id } }
    }
    return @{ ok = $true; state = 'ok'; found = @($found) }
}

function Global:Get-WebGroupDetail {
    # One group from Entra ID by its exact name: id, description, members.
    param($Data)
    $name = ([string]$Data.name).Trim()
    $problem = Test-WebGroupName $name
    if ($problem) { return @{ ok = $false; error = $problem } }
    $read = Invoke-WebGraph -Permission 'Group.ReadWrite.All' -Action {
        param($Graph)
        $filter = [Uri]::EscapeDataString("displayName eq '$($name.Replace("'", "''"))'")
        $found = @((& $Graph "https://graph.microsoft.com/v1.0/groups?`$filter=$filter&`$select=id,displayName,description").value)
        if ($found.Count -eq 0) { return @{ Found = $false; Count = 0 } }
        $g = $found[0]
        $members = New-Object System.Collections.Generic.List[object]
        $uri = "https://graph.microsoft.com/v1.0/groups/$($g.id)/members?`$select=id,displayName,userPrincipalName&`$top=999"
        while ($uri) {
            $page = & $Graph $uri
            foreach ($m in @($page.value)) {
                $type = switch ([string]$m.'@odata.type') { '#microsoft.graph.group' { 'Group' } '#microsoft.graph.device' { 'Device' } '#microsoft.graph.user' { 'User' } default { ([string]$m.'@odata.type' -replace '^#microsoft\.graph\.', '') } }
                $members.Add([ordered]@{ id = [string]$m.id; name = [string]$m.displayName; upn = [string]$m.userPrincipalName; type = $type })
            }
            $uri = [string]$page.'@odata.nextLink'
        }
        @{ Found = $true; Count = $found.Count; Id = [string]$g.id; Description = [string]$g.description; Members = $members.ToArray() }
    }
    if (-not $read.ok) { return $read }
    $v = $read.value
    $catalog = Read-WebCatalogRecords
    $usage = @(Get-WebGroupUsage $catalog.Apps) | Where-Object { $_.name -ieq $name } | Select-Object -First 1
    return @{ ok = $true; name = $name; found = [bool]$v.Found; duplicates = [int]$v.Count; id = [string]$v.Id; description = [string]$v.Description
        members = @($v.Members | Sort-Object { $_.type }, { $_.name }); uses = @($(if ($usage) { $usage.uses })) }
}

function Global:Find-WebDirectory {
    # Users and groups whose name (or a user's sign-in name) starts with the text, to add as members.
    param($Data)
    $q = ([string]$Data.q).Trim()
    if ($q.Length -lt 2) { return @{ ok = $false; error = 'Type at least 2 characters.' } }
    if ($q.Length -gt 100) { return @{ ok = $false; error = 'That is too long to search for.' } }
    $e = $q.Replace("'", "''")
    $read = Invoke-WebGraph -Permission 'Group.Read.All and User.Read.All' -Action {
        param($Graph)
        $hits = New-Object System.Collections.Generic.List[object]
        $notes = New-Object System.Collections.Generic.List[string]
        try {
            $f = [Uri]::EscapeDataString("startswith(displayName,'$e')")
            foreach ($g in @((& $Graph "https://graph.microsoft.com/v1.0/groups?`$filter=$f&`$select=id,displayName&`$top=25").value)) { $hits.Add([ordered]@{ id = [string]$g.id; name = [string]$g.displayName; upn = ''; type = 'Group' }) }
        }
        catch { $notes.Add("Groups couldn't be searched: $(Get-InnermostErrorMessage $_.Exception)") }
        try {
            $f = [Uri]::EscapeDataString("startswith(displayName,'$e') or startswith(userPrincipalName,'$e')")
            foreach ($u in @((& $Graph "https://graph.microsoft.com/v1.0/users?`$filter=$f&`$select=id,displayName,userPrincipalName&`$top=25").value)) { $hits.Add([ordered]@{ id = [string]$u.id; name = [string]$u.displayName; upn = [string]$u.userPrincipalName; type = 'User' }) }
        }
        catch { $notes.Add("Users couldn't be searched (needs User.Read.All or Directory.Read.All): $(Get-InnermostErrorMessage $_.Exception)") }
        @{ Hits = $hits.ToArray(); Notes = $notes.ToArray() }
    }
    if (-not $read.ok) { return $read }
    return @{ ok = $true; hits = @($read.value.Hits); notes = @($read.value.Notes) }
}

function Global:Start-WebGroupJob {
    <#
      mode Save: create the group (or reuse the one with this exact name),
      set its description, add members (by id). Delete / DeleteMany: by name.
      RemoveMember: one member, by ids. Rename: by id; the catalog follows
      once Entra ID has it (Complete-WebJob 'grouprename').
    #>
    param($Data)
    if (-not (Test-GraphCredentialsConfigured -Quiet)) { return @{ ok = $false; error = 'Set up the connection in Settings first.' } }
    $guid = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    $mode = [string]$Data.mode
    $name = ([string]$Data.name).Trim()
    $resultPath = Join-Path $env:TEMP ".intunepkg_groupmanager_result_$([guid]::NewGuid().ToString('N')).json"
    $config = [ordered]@{ TenantId = $Global:App.GraphTenantId; ClientId = $Global:App.GraphClientId; CertificateThumbprint = $Global:App.GraphCertificateThumbprint
        OutputResultPath = $resultPath; Mode = $mode; GroupName = $name; MemberIds = @() }
    $after = @{}
    switch ($mode) {
        'Save' {
            $problem = Test-WebGroupName $name; if ($problem) { return @{ ok = $false; error = $problem } }
            $ids = @(@($Data.memberIds) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Select-Object -Unique)
            if (@($ids | Where-Object { $_ -notmatch $guid }).Count) { return @{ ok = $false; error = 'A member id is not a GUID.' } }
            $config.Mode = ''; $config.MemberIds = $ids; $config.Description = ([string]$Data.description).Trim()
            $kind = "Create/update group $name"
        }
        'Delete' {
            $problem = Test-WebGroupName $name; if ($problem) { return @{ ok = $false; error = $problem } }
            $kind = "Delete group $name"
        }
        'DeleteMany' {
            $names = @(@($Data.names) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Select-Object -Unique)
            if (-not $names.Count) { return @{ ok = $false; error = 'No groups chosen.' } }
            $config.GroupNames = $names; $config.GroupName = ''
            $kind = "Delete $($names.Count) group(s)"
        }
        'RemoveMember' {
            if ([string]$Data.groupId -notmatch $guid -or [string]$Data.memberId -notmatch $guid) { return @{ ok = $false; error = 'Group and member ids must be GUIDs.' } }
            $config.GroupId = [string]$Data.groupId; $config.MemberId = [string]$Data.memberId
            $kind = "Remove a member from $name"
        }
        'Rename' {
            $new = ([string]$Data.newName).Trim()
            $problem = Test-WebGroupName $new; if ($problem) { return @{ ok = $false; error = $problem } }
            if ([string]$Data.groupId -notmatch $guid) { return @{ ok = $false; error = 'Load the group first.' } }
            if ($new -ceq $name) { return @{ ok = $false; error = 'That is the name it already has.' } }
            $config.GroupId = [string]$Data.groupId; $config.NewGroupName = $new
            $after = @{ Kind = 'grouprename'; OldName = $name; NewName = $new }
            $kind = "Rename group $name to $new"
        }
        default { return @{ ok = $false; error = 'Unknown group action.' } }
    }
    return (Start-WebStepJob -ScriptContent $Global:App.EmbeddedGroupManagerScript -Name 'groupmanager' -ConfigJson ($config | ConvertTo-Json -Depth 5) -ResultPath $resultPath -Kind $kind -After $after)
}

function Global:Complete-WebGroupRename {
    # After Entra ID renamed the group (by its id): every app that named it follows, and the favourites.
    param([hashtable]$After)
    $catalog = Read-WebCatalogRecords
    $changed = @(Rename-WebGroupInApps -Apps $catalog.Apps -Old $After.OldName -New $After.NewName)
    $folder = Get-AppFolder -Kind Catalog -Create
    foreach ($n in $changed) {
        $a = $catalog.Apps | Where-Object { $_.appName -eq $n } | Select-Object -First 1
        $file = Join-Path $folder ((Get-SafeFileNameForApp -Name $a.appName) + '.json')
        Backup-WebAppFile $file
        [System.IO.File]::WriteAllText($file, (ConvertTo-SingleAppJson -App $a), (New-Object System.Text.UTF8Encoding($false)))
    }
    $fav = @($Global:App.FavoriteGroups)
    if (@($fav | Where-Object { [string]$_ -ieq $After.OldName }).Count) {
        $list = New-Object System.Collections.Generic.List[string]
        foreach ($g in @($fav | ForEach-Object { if ([string]$_ -ieq $After.OldName) { $After.NewName } else { [string]$_ } } | Select-Object -Unique)) { $list.Add($g) }
        $Global:App.FavoriteGroups = $list
        try { Write-SettingsFile | Out-Null } catch { }
    }
    Write-Log "[OK] Renamed '$($After.OldName)' to '$($After.NewName)'; $($changed.Count) app(s) in the catalog updated$(if ($changed.Count) { ": $($changed -join ', ')" })."
    return @{ ok = $true; updated = $changed }
}
