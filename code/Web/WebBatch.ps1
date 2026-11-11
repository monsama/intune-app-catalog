# Intune App Catalog & Deployment
# Copyright (C) 2026 Viktor Ljuca <https://monsama.ch>
# SPDX-License-Identifier: GPL-2.0-or-later

<#
.SYNOPSIS
    The web interface's actions on several apps at once: batch edit,
    adding and removing groups, and pushing settings to Intune - what the
    classic Batch edit, Push metadata, Add favorite to apps and Remove group
    from apps dialogs do.
#>

function Global:Get-WebBatchFields {
    # The fields batch edit can set, and what kind of value each takes.
    [ordered]@{
        architecture = 'arch'; minOSKey = 'minos'; installContext = 'context'; installTimeMinutes = 'int'
        minDiskSpaceMB = 'int'; minMemoryMB = 'int'; minProcessors = 'int'; minCpuSpeedMHz = 'int'
        deviceRestartBehavior = 'restart'; allowAvailableUninstall = 'bool'; isFeatured = 'bool'
        returnCodes = 'codes'; dependencies = 'deps'
        description = 'text'; publisher = 'text'; owner = 'text'; developer = 'text'; notes = 'text'
        informationUrl = 'url'; privacyUrl = 'url'; wingetInstallMethod = 'method'
    }
}

function Global:ConvertTo-WebBatchChanges {
    <#
      Pure: batch edit's form - only the fields it ticked - checked field by
      field with the same rules as the editor, as @{ Error; Changes }.
    #>
    param($Form, [string[]]$AppNames = @())
    $fields = Get-WebBatchFields
    $changes = [ordered]@{}
    $given = if ($Form -is [System.Collections.IDictionary]) { @($Form.Keys) } else { @($Form.PSObject.Properties.Name) }
    foreach ($k in $given) {
        if (-not $fields.Contains($k)) { return @{ Error = "Batch edit can't change '$k'." } }
        $v = $Form.$k
        switch ($fields[$k]) {
            'arch' {
                $arch = @(@($v) | ForEach-Object { [string]$_ } | Where-Object { $_ -in 'x86', 'x64', 'arm64' } | Select-Object -Unique)
                if ($arch.Count -eq 0) { return @{ Error = 'Choose at least one architecture.' } }
                $changes[$k] = ($arch -join ',')
            }
            'minos' { if ([string]$v -notmatch '^W1[01]_\w+$') { return @{ Error = 'Unknown minimum OS.' } }; $changes[$k] = [string]$v }
            'context' { if ([string]$v -notin 'System', 'User') { return @{ Error = 'Install for must be System or User.' } }; $changes[$k] = [string]$v }
            'int' {
                if ([string]$v -notmatch '^\d{1,9}$') { return @{ Error = "$k must be a whole number of 0 or more." } }
                $changes[$k] = if ($k -eq 'installTimeMinutes') { Get-NormalizedInstallTimeMinutes ([int][string]$v) } else { [int][string]$v }
            }
            'restart' { if ([string]$v -notin 'basedOnReturnCode', 'allow', 'suppress', 'force') { return @{ Error = 'Unknown restart behaviour.' } }; $changes[$k] = [string]$v }
            'bool' { $changes[$k] = [bool]$v }
            'codes' {
                $codes = @(@($v) | Where-Object { $_ } | ForEach-Object {
                    if ([string]$_.returnCode -notmatch '^-?\d{1,10}$' -or [string]$_.type -notin 'success', 'softReboot', 'hardReboot', 'retry', 'failed') { $null }
                    else { [pscustomobject]@{ returnCode = [int][string]$_.returnCode; type = [string]$_.type } }
                })
                if ($codes.Count -eq 0 -or @($codes | Where-Object { $null -eq $_ }).Count) { return @{ Error = 'Every return code needs a number and a type, and there must be at least one.' } }
                $changes[$k] = $codes
            }
            'deps' {
                $deps = @(@($v) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Select-Object -Unique)
                foreach ($d in $deps) { if ($AppNames -notcontains $d) { return @{ Error = "Dependency '$d' isn't an app in this catalog." } } }
                $changes[$k] = $deps
            }
            'text' { $changes[$k] = ([string]$v).Trim() }
            'url' {
                $u = ([string]$v).Trim()
                if ($u -and $u -notmatch '^https?://\S+$') { return @{ Error = "$k must start with http:// or https://." } }
                $changes[$k] = $u
            }
            'method' { if ([string]$v -notin 'WAU', 'Winget') { return @{ Error = 'Install with must be WAU or Winget.' } }; $changes[$k] = [string]$v }
        }
    }
    if ($changes.Count -eq 0) { return @{ Error = 'Tick at least one field to change.' } }
    return @{ Error = ''; Changes = $changes }
}

function Global:Set-WebBatchChanges {
    <#
      Pure: one app's metadata with -Changes laid over it, as
      @{ Metadata; Kept } - Kept is true when its install commands were
      edited by hand, so a Winget install method change left them alone.
    #>
    param($App, $Metadata, $Changes)
    $m = $Metadata.PSObject.Copy()
    $kept = $false
    foreach ($k in $Changes.Keys) {
        if ($k -eq 'wingetInstallMethod') { continue }
        $value = $Changes[$k]
        # An app can't depend on itself - dropped for that one app, not refused for all.
        if ($k -eq 'dependencies') { $value = @($value | Where-Object { $_ -ne $App.appName }) }
        if ($m.PSObject.Properties.Name -contains $k) { $m.$k = $value } else { $m | Add-Member -NotePropertyName $k -NotePropertyValue $value }
    }
    if ($Changes.Contains('wingetInstallMethod') -and $App.wingetId) {
        $c = Convert-AppWingetInstallMethod -WingetId $App.wingetId -InstallCommand $m.installCommand -UninstallCommand $m.uninstallCommand -Method $Changes.wingetInstallMethod -InstallContext $m.installContext
        $m.installCommand = $c.Install; $m.uninstallCommand = $c.Uninstall
        $kept = ($c.Status -eq 'Custom')
    }
    return @{ Metadata = $m; Kept = $kept }
}

function Global:Invoke-WebBatchEdit {
    # Batch edit: the ticked fields on the chosen apps, in the catalog. The page then offers to push them.
    param($Data)
    $catalog = Read-WebCatalogRecords
    $all = @($catalog.Apps)
    $names = @($Data.names | ForEach-Object { [string]$_ })
    $apps = @($all | Where-Object { $names -contains $_.appName })
    if ($apps.Count -eq 0) { return @{ ok = $false; error = 'Choose one or more apps first.' } }
    $checked = ConvertTo-WebBatchChanges -Form $Data.changes -AppNames @($all | ForEach-Object { $_.appName })
    if ($checked.Error) { return @{ ok = $false; error = $checked.Error } }
    $folder = Get-AppFolder -Kind Catalog -Create
    $changed = New-Object System.Collections.Generic.List[string]
    $kept = New-Object System.Collections.Generic.List[string]
    foreach ($a in $apps) {
        $base = if ($a.metadata) { $a.metadata } else { Get-DefaultAppMetadata -AppName $a.appName -WingetId $a.wingetId -Uncommon (Test-AppIsUncommon -App $a) }
        $r = Set-WebBatchChanges -App $a -Metadata $base -Changes $checked.Changes
        $a.metadata = $r.Metadata
        if ($r.Kept) { $kept.Add($a.appName) }
        $file = Join-Path $folder ((Get-SafeFileNameForApp -Name $a.appName) + '.json')
        Backup-WebAppFile $file
        [System.IO.File]::WriteAllText($file, (ConvertTo-SingleAppJson -App $a), (New-Object System.Text.UTF8Encoding($false)))
        $changed.Add($a.appName)
    }
    Write-Log "[OK] Batch edit: $(@($checked.Changes.Keys) -join ', ') changed on $($changed.Count) app(s)$(if ($kept.Count) { "; install commands edited by hand kept on $($kept -join ', ')" })."
    return @{ ok = $true; changed = $changed.ToArray(); kept = $kept.ToArray(); deployed = @($apps | Where-Object { $_.appId } | ForEach-Object { $_.appName }) }
}

function Global:Set-WebBatchGroups {
    <#
      Pure: one app's group lists with -Groups added to (or removed from)
      the roles named in -Roles. Returns whether anything changed.
    #>
    param($App, [ValidateSet('add', 'remove')][string]$Mode, $Roles)
    $changed = $false
    foreach ($field in (Get-WebGroupRoles).Keys) {
        # Case-insensitive, like Entra ID's group names: SG-X and sg-x are one group.
        $want = New-Object System.Collections.Generic.List[string]
        foreach ($g in @(@($Roles.$field) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })) {
            if (-not @($want | Where-Object { $_ -ieq $g }).Count) { $want.Add($g) }
        }
        if (-not $want.Count) { continue }
        $current = @($App.$field | Where-Object { $_ })
        $next = if ($Mode -eq 'add') { @(@($current) + @($want | Where-Object { $g = $_; -not @($current | Where-Object { [string]$_ -ieq $g }).Count })) }
            else { @($current | Where-Object { $g = [string]$_; -not @($want | Where-Object { $_ -ieq $g }).Count }) }
        if (@($next).Count -ne $current.Count) { $App.$field = @($next); $changed = $true }
    }
    return $changed
}

function Global:Invoke-WebBatchGroups {
    # Add groups to, or remove them from, the chosen apps' lists - the catalog only; Push groups sends them.
    param($Data)
    $mode = [string]$Data.mode
    if ($mode -notin 'add', 'remove') { return @{ ok = $false; error = 'Add or remove?' } }
    $catalog = Read-WebCatalogRecords
    $names = @($Data.names | ForEach-Object { [string]$_ })
    $apps = @($catalog.Apps | Where-Object { $names -contains $_.appName })
    if ($apps.Count -eq 0) { return @{ ok = $false; error = 'Choose one or more apps first.' } }
    $any = $false
    foreach ($field in (Get-WebGroupRoles).Keys) {
        # A role that wasn't sent comes through as $null - nothing to add there, not an empty name.
        foreach ($g in @($Data.roles.$field | Where-Object { $null -ne $_ -and ([string]$_).Trim() })) {
            $problem = Test-WebGroupName ([string]$g)
            if ($problem) { return @{ ok = $false; error = $problem } }
            $any = $true
        }
    }
    if (-not $any) { return @{ ok = $false; error = 'Choose at least one group.' } }
    $folder = Get-AppFolder -Kind Catalog -Create
    $changed = New-Object System.Collections.Generic.List[string]
    foreach ($a in $apps) {
        if (-not (Set-WebBatchGroups -App $a -Mode $mode -Roles $Data.roles)) { continue }
        $file = Join-Path $folder ((Get-SafeFileNameForApp -Name $a.appName) + '.json')
        Backup-WebAppFile $file
        [System.IO.File]::WriteAllText($file, (ConvertTo-SingleAppJson -App $a), (New-Object System.Text.UTF8Encoding($false)))
        $changed.Add($a.appName)
    }
    Write-Log "[OK] Groups $(if ($mode -eq 'add') { 'added to' } else { 'removed from' }) $($changed.Count) app(s) in the catalog$(if ($changed.Count) { ': ' + ($changed -join ', ') })."
    return @{ ok = $true; changed = $changed.ToArray(); deployed = @($apps | Where-Object { $_.appId -and $changed -contains $_.appName } | ForEach-Object { $_.appName }) }
}
