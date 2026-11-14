# Intune App Catalog & Deployment
# Copyright (C) 2026 Viktor Ljuca <https://monsama.ch>
# SPDX-License-Identifier: GPL-2.0-or-later

<#
.SYNOPSIS
    The app editor: one app for the form and its deploy settings, checking
    and saving the edit (refused when the file changed since it was opened),
    removing an app from the catalog. The routes are in WebApi.ps1.
#>

function Global:Get-WebAppFileVersion {
    # A fingerprint of one app's saved file ('' when there is none), so a
    # save can tell whether the file changed since the editor opened it.
    param([string]$Name)
    $folder = Get-AppFolder -Kind Catalog
    if (-not $folder -or -not $Name) { return '' }
    $file = Join-Path $folder ((Get-SafeFileNameForApp -Name $Name) + '.json')
    if (-not (Test-Path -LiteralPath $file)) { return '' }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([System.IO.File]::ReadAllBytes($file))) -replace '-', '') }
    finally { $sha.Dispose() }
}

function Global:Test-WebWingetId {
    # Pure: a Winget ID as winget itself allows them (letters, digits, . _ + -).
    param([string]$Id)
    if (-not $Id) { return $true }
    return ($Id -match '^[A-Za-z0-9][A-Za-z0-9._+\-]{0,127}$')
}

function Global:Get-WebAppEditable {
    # Pure: an app record as the editor's JSON - every field it shows.
    param($App)
    $m = $App.metadata
    return [ordered]@{
        appName      = [string]$App.appName
        wingetId     = [string]$App.wingetId
        appId        = [string]$App.appId
        intuneAppType = [string]$App.intuneAppType
        requiredFor  = @($App.requiredFor | ForEach-Object { [string]$_ })
        availableFor = @($App.availableFor | ForEach-Object { [string]$_ })
        uninstallFor = @($App.uninstallFor | ForEach-Object { [string]$_ })
        excludeFor   = @($App.excludeFor | ForEach-Object { [string]$_ })
        assignmentFilter     = [string]$App.assignmentFilter
        assignmentFilterMode = $(if ([string]$App.assignmentFilterMode -eq 'exclude') { 'exclude' } else { 'include' })
        retiringSince = [string]$App.retiringSince
        hasMetadata  = [bool]$m
        managedUpdates = [bool]$App.managedUpdates
        releaseRule  = $(if ($App.releaseRule) { [ordered]@{ days = $App.releaseRule.days; maxFailedPercent = $App.releaseRule.maxFailedPercent; minInstalled = $App.releaseRule.minInstalled } } else { $null })
        detectedName = [string]$App.detectedName
        autoRelease  = [bool]$App.autoRelease
        downloadUrl  = [string]$App.downloadUrl
        releases     = @(@($App.releases) | ForEach-Object { [ordered]@{ version = [string]$_.version; appId = [string]$_.appId; state = [string]$_.state; at = [string]$_.at; ring = [int]$_.ring; fastTrack = [bool]$_.fastTrack } })
        icon         = $(if ($App.icon -and $App.icon.value) { [ordered]@{ type = [string]$App.icon.type; value = [string]$App.icon.value } } else { $null })
        metadata     = [ordered]@{
            description      = [string]$(if ($m) { $m.description })
            publisher        = [string]$(if ($m) { $m.publisher })
            owner            = [string]$(if ($m) { $m.owner })
            developer        = [string]$(if ($m) { $m.developer })
            informationUrl   = [string]$(if ($m) { $m.informationUrl })
            privacyUrl       = [string]$(if ($m) { $m.privacyUrl })
            notes            = [string]$(if ($m) { $m.notes })
            appVersion       = [string]$(if ($m) { $m.appVersion })
            installCommand   = [string]$(if ($m) { $m.installCommand })
            uninstallCommand = [string]$(if ($m) { $m.uninstallCommand })
            installContext   = [string]$(if ($m) { $m.installContext })
        }
    }
}

function Global:ConvertTo-WebDeploySettings {
    <#
      Pure: the editor's "Deploy settings" section, checked, as
      @{ Error; Values } - Values are
      catalog metadata properties, ready to set. Error is '' when fine.
      -AppNames: the catalog's apps (a dependency must be one of them, and
      not the app itself, -Self).
    #>
    param($Form, [string[]]$AppNames = @(), [string]$Self = '', [string]$SelfAppId = '')
    $ops = 'notConfigured', 'equal', 'notEqual', 'greaterThan', 'greaterThanOrEqual', 'lessThan', 'lessThanOrEqual'
    $d = $Form.detection
    $rule = $null
    switch ([string]$d.type) {
        'Script' {
            if (-not ([string]$d.script).Trim()) { return @{ Error = 'The detection script is empty.' } }
            $rule = [pscustomobject]@{ Type = 'Script'; Script_Content = (ConvertTo-CanonicalLineEndings ([string]$d.script)).TrimEnd() }
        }
        'Msi' {
            if (-not ([string]$d.productCode).Trim()) { return @{ Error = 'An MSI detection rule needs the product code.' } }
            if ([string]$d.operator -notin $ops) { return @{ Error = 'Unknown version operator.' } }
            $rule = [pscustomobject]@{ Type = 'Msi'; Msi_ProductCode = ([string]$d.productCode).Trim(); Msi_VersionOperator = [string]$d.operator; Msi_Version = ([string]$d.value).Trim() }
        }
        'File' {
            if (-not ([string]$d.path).Trim() -or -not ([string]$d.name).Trim()) { return @{ Error = 'A file detection rule needs the folder and the file name.' } }
            if ([string]$d.detectionType -notin 'exists', 'doesNotExist', 'modifiedDate', 'createdDate', 'version', 'sizeInMB') { return @{ Error = 'Unknown file detection type.' } }
            if ([string]$d.operator -notin $ops) { return @{ Error = 'Unknown operator.' } }
            $rule = [pscustomobject]@{ Type = 'File'; File_Path = ([string]$d.path).Trim(); File_Name = ([string]$d.name).Trim(); File_Check32Bit = [bool]$d.check32Bit
                File_DetectionType = [string]$d.detectionType; File_Operator = [string]$d.operator; File_DetectionValue = ([string]$d.value).Trim() }
        }
        'Registry' {
            if (-not ([string]$d.keyPath).Trim()) { return @{ Error = 'A registry detection rule needs the key path.' } }
            if ([string]$d.detectionType -notin 'exists', 'doesNotExist', 'string', 'integer', 'version') { return @{ Error = 'Unknown registry detection type.' } }
            if ([string]$d.operator -notin $ops) { return @{ Error = 'Unknown operator.' } }
            $rule = [pscustomobject]@{ Type = 'Registry'; Reg_KeyPath = ([string]$d.keyPath).Trim(); Reg_ValueName = ([string]$d.valueName).Trim(); Reg_Check32Bit = [bool]$d.check32Bit
                Reg_DetectionType = [string]$d.detectionType; Reg_Operator = [string]$d.operator; Reg_DetectionValue = ([string]$d.value).Trim() }
        }
        '' { $rule = $null }
        default { return @{ Error = 'Unknown detection rule type.' } }
    }
    # The requirement fields are the same as the default values' - one checker.
    $base = ConvertTo-WebDefaultSettings $Form
    if ($base.Error) { return @{ Error = $base.Error } }
    $deps = @(@($Form.dependencies) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Select-Object -Unique)
    foreach ($dep in $deps) {
        if ($dep -eq $Self) { return @{ Error = "An app can't depend on itself." } }
        if ($AppNames -notcontains $dep) { return @{ Error = "Dependency '$dep' isn't an app in this catalog." } }
    }
    # Supersedence: sent only by an editor that shows it. supersedesSet false
    # means "leave Intune's as it is" (null in the catalog); true, exactly these.
    $sup = $null; $supGiven = $false
    $formKeys = if ($Form -is [System.Collections.IDictionary]) { @($Form.Keys) } else { @($Form.PSObject.Properties.Name) }
    if ($formKeys -contains 'supersedesSet') {
        $supGiven = $true
        if ($Form.supersedesSet) {
            $list = New-Object System.Collections.Generic.List[object]
            foreach ($s in @($Form.supersedes | Where-Object { $_ })) {
                $sid = ([string]$s.appId).Trim()
                if ($sid -notmatch '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$') { return @{ Error = 'Every superseded app needs an Intune App ID (a GUID).' } }
                if ($SelfAppId -and $sid -eq $SelfAppId) { return @{ Error = "An app can't supersede itself." } }
                if (@($list | Where-Object { $_.appId -eq $sid }).Count) { continue }
                $list.Add([pscustomobject]@{ appId = $sid; name = ([string]$s.name).Trim(); type = $(if ([string]$s.type -eq 'replace') { 'replace' } else { 'update' }) })
            }
            if ($list.Count -gt 10) { return @{ Error = 'Intune allows at most 10 superseded apps.' } }
            $sup = $list.ToArray()
        }
    }
    $b = $base.Settings
    $values = [ordered]@{
        detectionRule = $rule; architecture = $b.Architecture; minOSKey = $b.MinOSKey
        minDiskSpaceMB = $b.MinDiskSpaceMB; minMemoryMB = $b.MinMemoryMB; minProcessors = $b.MinProcessors; minCpuSpeedMHz = $b.MinCpuSpeedMHz
        installTimeMinutes = $b.InstallTimeMinutes; deviceRestartBehavior = $b.DeviceRestartBehavior; allowAvailableUninstall = $b.AllowAvailableUninstall
        returnCodes = @($b.ReturnCodes); dependencies = $deps
    }
    if ($supGiven) { $values.supersedes = $sup }
    return @{ Error = ''; Values = $values }
}

function Global:Get-WebDeployEditable {
    # Pure: an app's metadata as the editor's "Deploy settings" section.
    param($Metadata)
    $m = $Metadata
    $r = if ($m) { $m.detectionRule } else { $null }
    $det = [ordered]@{ type = ''; script = ''; productCode = ''; operator = 'notConfigured'; value = ''; path = ''; name = ''; check32Bit = $false; detectionType = 'exists'; keyPath = ''; valueName = '' }
    if ($r) {
        $det.type = [string]$r.Type
        switch ([string]$r.Type) {
            'Script' { $det.script = [string]$r.Script_Content }
            'Msi' { $det.productCode = [string]$r.Msi_ProductCode; $det.operator = [string]$r.Msi_VersionOperator; $det.value = [string]$r.Msi_Version }
            'File' { $det.path = [string]$r.File_Path; $det.name = [string]$r.File_Name; $det.check32Bit = [bool]$r.File_Check32Bit; $det.detectionType = [string]$r.File_DetectionType; $det.operator = [string]$r.File_Operator; $det.value = [string]$r.File_DetectionValue }
            'Registry' { $det.keyPath = [string]$r.Reg_KeyPath; $det.valueName = [string]$r.Reg_ValueName; $det.check32Bit = [bool]$r.Reg_Check32Bit; $det.detectionType = [string]$r.Reg_DetectionType; $det.operator = [string]$r.Reg_Operator; $det.value = [string]$r.Reg_DetectionValue }
        }
        if (-not $det.operator) { $det.operator = 'notConfigured' }
    }
    return [ordered]@{
        detection = $det
        architecture = @(([string]$(if ($m) { $m.architecture })) -split ',' | Where-Object { $_ }); installContext = $(if ($m -and [string]$m.installContext -eq 'User') { 'User' } else { 'System' })
        minOSKey = [string]$(if ($m) { $m.minOSKey }); minDiskSpaceMB = [int]$(if ($m) { $m.minDiskSpaceMB }); minMemoryMB = [int]$(if ($m) { $m.minMemoryMB })
        minProcessors = [int]$(if ($m) { $m.minProcessors }); minCpuSpeedMHz = [int]$(if ($m) { $m.minCpuSpeedMHz }); installTimeMinutes = [int]$(if ($m -and $m.installTimeMinutes) { $m.installTimeMinutes } else { 60 })
        deviceRestartBehavior = [string]$(if ($m -and $m.deviceRestartBehavior) { $m.deviceRestartBehavior } else { 'basedOnReturnCode' }); allowAvailableUninstall = [bool]$(if ($m) { $m.allowAvailableUninstall })
        returnCodes = @($(if ($m) { $m.returnCodes }) | Where-Object { $_ } | ForEach-Object { [ordered]@{ returnCode = [int]$_.returnCode; type = [string]$_.type } })
        dependencies = @($(if ($m) { $m.dependencies }) | Where-Object { $_ } | ForEach-Object { [string]$_ })
        supersedesSet = [bool]($m -and $null -ne $m.supersedes)
        supersedes = @($(if ($m) { $m.supersedes }) | Where-Object { $_ -and $_.appId } | ForEach-Object { [ordered]@{ appId = [string]$_.appId; name = [string]$_.name; type = [string]$_.type } })
    }
}

function Global:Get-WebApp {
    param($Data)
    $catalog = Read-WebCatalogRecords
    $name = [string]$Data.name
    $app = $catalog.Apps | Where-Object { $_.appName -eq $name } | Select-Object -First 1
    if (-not $app) { return @{ ok = $false; error = "No app called '$name' in the catalog (it may have been renamed or removed - Reload)." } }
    $editable = Get-WebAppEditable $app
    $meta = if ($app.metadata) { $app.metadata } else { try { Get-DefaultAppMetadata -AppName $app.appName -WingetId $app.wingetId -Uncommon (-not $app.wingetId) } catch { $null } }
    $editable.deploy = Get-WebDeployEditable $meta
    return @{ ok = $true; app = $editable; version = (Get-WebAppFileVersion $app.appName); knownGroups = @(Get-AllKnownGroups | Sort-Object -Unique)
        appNames = @($catalog.Apps | ForEach-Object { $_.appName } | Where-Object { $_ -ne $name } | Sort-Object); minOsChoices = @(Get-WebMinOsChoices)
        intuneApps = @($catalog.Apps | Where-Object { $_.appId -and $_.appName -ne $name } | Sort-Object appName | ForEach-Object { [ordered]@{ name = [string]$_.appName; appId = [string]$_.appId } }) }
}

function Global:Merge-WebAppEdit {
    <#
      Pure: the app record after the editor's changes - everything the
      editor doesn't show (detection rule, dependencies, supersedence,
      package path, Intune's type and version, ...) carried over untouched.
      Metadata is only created for an app that had none when a metadata
      field was actually filled in, from the computed defaults.
    #>
    param($Existing, $Edit, $Defaults)
    $groups = {
        param($list)
        @(@($list) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Select-Object -Unique)
    }
    $metaEdit = $Edit.metadata
    # installContext is in the Deploy settings section (ConvertTo-WebDeploySettings).
    $metaFields = 'description', 'publisher', 'owner', 'developer', 'informationUrl', 'privacyUrl', 'notes', 'appVersion', 'installCommand', 'uninstallCommand'
    $metadata = if ($Existing -and $Existing.metadata) { $Existing.metadata.PSObject.Copy() } else { $null }
    $anyMetaFilled = $metaEdit -and @($metaFields | Where-Object { [string]$metaEdit.$_ }).Count -gt 0
    if (-not $metadata -and $anyMetaFilled -and $Defaults) { $metadata = $Defaults.PSObject.Copy() }
    if ($metadata -and $metaEdit) {
        foreach ($f in $metaFields) {
            if ($metadata.PSObject.Properties.Name -contains $f) { $metadata.$f = [string]$metaEdit.$f }
            else { $metadata | Add-Member -NotePropertyName $f -NotePropertyValue ([string]$metaEdit.$f) }
        }
        if (-not $metadata.appVersion) { $metadata.appVersion = $null }
    }
    return [pscustomobject]@{
        appId            = ([string]$Edit.appId).Trim()
        appName          = (([string]$Edit.appName).Trim() -replace '\s+', ' ')
        wingetId         = ([string]$Edit.wingetId).Trim()
        intuneAppType    = $(if ($Existing) { [string]$Existing.intuneAppType } else { '' })
        intuneAppVersion = $(if ($Existing) { [string]$Existing.intuneAppVersion } else { '' })
        packagePath      = $(if ($Existing) { [string]$Existing.packagePath } else { '' })
        # Managed updates: what the editor says (only a Winget app can have them), else what the app had - or, for a new app, the default install method.
        managedUpdates   = $(if ($null -ne $Edit.managedUpdates) { [bool]$Edit.managedUpdates } elseif ($Existing) { [bool]$Existing.managedUpdates } else { ([string]$Edit.wingetId).Trim() -and -not (Test-StoreProductId ([string]$Edit.wingetId).Trim()) -and [string]$Global:App.DefaultAppSettings.WingetInstallMethod -eq 'Managed' })
        releases         = @($(if ($Existing) { $Existing.releases }))
        # The app's own release rule: what the editor sends (empty fields: Settings' rule), else what it had.
        releaseRule      = $(if ($null -ne $Edit.releaseRule) { ConvertTo-AppReleaseRule $Edit.releaseRule } elseif ($Existing) { $Existing.releaseRule } else { $null })
        autoRelease      = $(if ($null -ne $Edit.autoRelease) { [bool]$Edit.autoRelease } elseif ($Existing) { [bool]$Existing.autoRelease } else { $false })
        downloadUrl      = $(if ($null -ne $Edit.downloadUrl) { $u = ([string]$Edit.downloadUrl).Trim(); if ($u -match '^https://[^\s"<>]+$' -and $u.Length -le 2000) { $u } else { '' } } elseif ($Existing) { [string]$Existing.downloadUrl } else { '' })
        detectedName     = $(if ($null -ne $Edit.detectedName) { $dn = ([string]$Edit.detectedName).Trim(); if ($dn.Length -le 100) { $dn } else { $dn.Substring(0, 100) } } elseif ($Existing) { [string]$Existing.detectedName } else { '' })
        # iconChange: 'set' (with icon), 'remove', or anything else to keep the one it has.
        icon             = $(switch ([string]$Edit.iconChange) { 'set' { ConvertTo-AppIcon $Edit.icon } 'remove' { $null } default { if ($Existing) { $Existing.icon } else { $null } } })
        requiredFor      = & $groups $Edit.requiredFor
        availableFor     = & $groups $Edit.availableFor
        uninstallFor     = & $groups $Edit.uninstallFor
        excludeFor       = & $groups $Edit.excludeFor
        # The assignment filter: what the editor sends, else what the app had.
        assignmentFilter     = $(if ($null -ne $Edit.assignmentFilter) { $af = ([string]$Edit.assignmentFilter).Trim(); if ($af.Length -le 200) { $af } else { '' } } elseif ($Existing) { [string]$Existing.assignmentFilter } else { '' })
        # Being retired stays as it was - only Retire changes it.
        retiringSince    = $(if ($Existing) { [string]$Existing.retiringSince } else { '' })
        assignmentFilterMode = $(if ($null -ne $Edit.assignmentFilterMode) { if ([string]$Edit.assignmentFilterMode -eq 'exclude') { 'exclude' } else { 'include' } } elseif ($Existing -and [string]$Existing.assignmentFilterMode -eq 'exclude') { 'exclude' } else { 'include' })
        metadata         = $metadata
    }
}

function Global:Test-WebAppEdit {
    <#
      Pure: why an edited app can't be saved ('' when it can): a name, unique by name and by file name, a GUID or no
      App ID, a Winget ID winget would accept.
    #>
    param($Record, [string]$OriginalName, [object[]]$Others)
    if (-not $Record.appName) { return 'The app needs a name.' }
    if ($Record.appId -and $Record.appId -notmatch '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$') { return "The App ID must be a GUID (or empty for an app that isn't in Intune yet)." }
    if (-not (Test-WebWingetId $Record.wingetId)) { return "'$($Record.wingetId)' isn't a Winget ID winget accepts (letters, digits, . _ + -)." }
    $key = $Record.appName.ToLowerInvariant()
    $file = Get-SafeFileNameForApp -Name $Record.appName
    foreach ($o in @($Others)) {
        if (-not $o -or $o.appName -eq $OriginalName) { continue }
        if (($o.appName.Trim() -replace '\s+', ' ').ToLowerInvariant() -eq $key) { return "Another app is already called '$($o.appName)'." }
        if ((Get-SafeFileNameForApp -Name $o.appName) -eq $file) { return "'$($Record.appName)' and '$($o.appName)' would be saved to the same file ($file.json). Choose a different name." }
        if ($Record.appId -and $o.appId -eq $Record.appId) { return "'$($o.appName)' already has App ID $($Record.appId)." }
    }
    return ''
}

function Global:Backup-WebAppFile {
    # A copy of one app's file in the Backups folder before it's overwritten or removed.
    param([string]$FilePath, [switch]$PassThru)
    if (-not (Test-Path -LiteralPath $FilePath)) { return }
    try {
        $dir = Join-Path (Get-AppFolder -Kind Backups -Create) ("app-edit_" + (Get-Date -Format 'yyyy-MM-dd'))
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        # HHmmss_<file>, or HHmmss-2_<file> and on for further saves within the
        # same second - each copy is a version someone may want back.
        $stamp = Get-Date -Format 'HHmmss'; $leaf = Split-Path $FilePath -Leaf
        $target = Join-Path $dir "$($stamp)_$leaf"; $n = 1
        while (Test-Path -LiteralPath $target) { $n++; $target = Join-Path $dir "$stamp-$($n)_$leaf" }
        Copy-Item -LiteralPath $FilePath -Destination $target
        if ($PassThru) { return $target }
    }
    catch { }
}

function Global:Save-WebApp {
    param($Data)
    $catalog = Read-WebCatalogRecords
    $original = [string]$Data.originalName
    $existing = if ($original) { $catalog.Apps | Where-Object { $_.appName -eq $original } | Select-Object -First 1 } else { $null }
    if ($original -and -not $existing) { return @{ ok = $false; error = "'$original' is no longer in the catalog (renamed or removed elsewhere?). Reload and try again." } }
    if ($existing -and $Data.version -and [string]$Data.version -ne (Get-WebAppFileVersion $existing.appName)) {
        return @{ ok = $false; stale = $true; error = "'$original' was changed since you opened it (a deploy, a pull or a fix saved it). Nothing was saved - close the editor, open the app again and redo your changes." }
    }
    $edit = $Data.app
    $defaults = $null
    if (-not ($existing -and $existing.metadata)) {
        $name = ([string]$edit.appName).Trim()
        $wid = ([string]$edit.wingetId).Trim()
        try { $defaults = Get-DefaultAppMetadata -AppName $name -WingetId $wid -Uncommon (-not $wid) } catch { $defaults = $null }
    }
    $record = Merge-WebAppEdit -Existing $existing -Edit $edit -Defaults $defaults
    $problem = Test-WebAppEdit -Record $record -OriginalName $original -Others @($catalog.Apps)
    if ($problem) { return @{ ok = $false; error = $problem } }
    if ([string]$edit.iconChange -eq 'set' -and -not $record.icon) { return @{ ok = $false; error = 'The icon must be a PNG or JPEG of at most 750 KB.' } }
    if (([string]$edit.downloadUrl).Trim() -and -not $record.downloadUrl) { return @{ ok = $false; error = 'The installer download address must start with https://.' } }
    if ($record.autoRelease -and ($record.wingetId -or -not $record.managedUpdates)) { $record.autoRelease = $false }
    # The Store updates its own apps: no managed updates for a Microsoft Store app.
    if ($record.managedUpdates -and (Test-StoreProductId ([string]$record.wingetId))) { $record.managedUpdates = $false }
    foreach ($urlField in 'informationUrl', 'privacyUrl') {
        $u = [string]$edit.metadata.$urlField
        if ($u -and $u -notmatch '^https?://\S+$') { return @{ ok = $false; error = "The $(if ($urlField -eq 'informationUrl') { 'information' } else { 'privacy' }) URL must start with http:// or https://." } }
    }
    if ($edit.deploy) {
        $deploy = ConvertTo-WebDeploySettings -Form $edit.deploy -AppNames @($catalog.Apps | ForEach-Object { $_.appName }) -Self $record.appName -SelfAppId $record.appId
        if ($deploy.Error) { return @{ ok = $false; error = $deploy.Error } }
        # Deploy settings make an app's metadata exist, with the defaults underneath.
        if (-not $record.metadata) {
            $base = if ($defaults) { $defaults } else { try { Get-DefaultAppMetadata -AppName $record.appName -WingetId $record.wingetId -Uncommon (-not $record.wingetId) } catch { $null } }
            if ($base) { $record.metadata = $base.PSObject.Copy() }
        }
        if ($record.metadata) {
            foreach ($k in $deploy.Values.Keys) {
                if ($record.metadata.PSObject.Properties.Name -contains $k) { $record.metadata.$k = $deploy.Values[$k] }
                else { $record.metadata | Add-Member -NotePropertyName $k -NotePropertyValue $deploy.Values[$k] }
            }
            $record.metadata.installContext = $(if ([string]$edit.deploy.installContext -eq 'User') { 'User' } else { 'System' })
        }
    }
    # A managed app's commands and detection follow its App version (pinned).
    [void](Set-ManagedAppPin $record)

    $folder = Get-AppFolder -Kind Catalog -Create
    $newFile = Join-Path $folder ((Get-SafeFileNameForApp -Name $record.appName) + '.json')
    $oldFile = if ($existing) { Join-Path $folder ((Get-SafeFileNameForApp -Name $existing.appName) + '.json') } else { $null }
    Backup-WebAppFile $newFile
    try {
        Save-WebAppJson -File $newFile -App $record -BeforeFile $(if ($oldFile -and $oldFile -ne $newFile) { $oldFile } else { '' })
    }
    catch { return @{ ok = $false; error = "Couldn't write $newFile`: $($_.Exception.Message)" } }
    if ($oldFile -and $oldFile -ne $newFile -and (Test-Path -LiteralPath $oldFile)) {
        Backup-WebAppFile $oldFile
        Remove-Item -LiteralPath $oldFile -Force -ErrorAction SilentlyContinue
    }
    Write-Log "[OK] $(if ($existing) { 'Saved' } else { 'Added' }): $($record.appName)$(if ($existing -and $existing.appName -ne $record.appName) { " (was $($existing.appName))" })."
    return @{ ok = $true; name = $record.appName }
}

function Global:Remove-WebApp {
    # Removes an app from the catalog only - nothing in Intune changes.
    param($Data)
    $catalog = Read-WebCatalogRecords
    $name = [string]$Data.name
    $app = $catalog.Apps | Where-Object { $_.appName -eq $name } | Select-Object -First 1
    if (-not $app) { return @{ ok = $false; error = "No app called '$name' in the catalog." } }
    $file = Join-Path (Get-AppFolder -Kind Catalog) ((Get-SafeFileNameForApp -Name $app.appName) + '.json')
    Backup-WebAppFile $file
    try { Remove-Item -LiteralPath $file -Force -ErrorAction Stop }
    catch { return @{ ok = $false; error = "Couldn't remove $file`: $($_.Exception.Message)" } }
    Add-WebHistoryEntry -App $name -Kind 'catalog' -Text 'Removed from the catalog'
    Write-Log "[OK] Removed from the catalog: $name (a copy is in the Backups folder; nothing in Intune changed)."
    return @{ ok = $true }
}

function Global:Get-WebAppBackups {
    <#
      The copies Backup-WebAppFile kept of one app's file, newest first:
      Backups\app-edit_<date>\<HHmmss>_<file>.json. Each with its time and
      what differs from the app as it is now (the field names), so a person
      can tell which one to go back to.
    #>
    param($Data)
    $name = [string]$Data.name
    $catalog = Read-WebCatalogRecords
    $app = $catalog.Apps | Where-Object { $_.appName -eq $name } | Select-Object -First 1
    if (-not $app) { return @{ ok = $false; error = "No app called '$name' in the catalog." } }
    $leaf = (Get-SafeFileNameForApp -Name $app.appName) + '.json'
    $root = Get-AppFolder -Kind Backups
    $rows = New-Object System.Collections.Generic.List[object]
    if (Test-Path -LiteralPath $root) {
        foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory -Filter 'app-edit_*' -ErrorAction SilentlyContinue)) {
            if ($dir.Name -notmatch '^app-edit_(\d{4}-\d{2}-\d{2})$') { continue }
            $day = $Matches[1]
            foreach ($f in @(Get-ChildItem -LiteralPath $dir.FullName -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(\d{6})(-\d+)?_(.+)$' -and $Matches[3] -eq $leaf })) {
                $time = $f.Name.Substring(0, 6)
                $seq = if ($f.Name -match '^\d{6}-(\d+)_') { [int]$Matches[1] } else { 1 }
                $changed = @()
                try {
                    $old = ConvertTo-AppRecord (Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json)
                    foreach ($k in 'appName', 'appId', 'wingetId', 'requiredFor', 'availableFor', 'uninstallFor', 'excludeFor') {
                        if ((@($old.$k) -join '|') -ne (@($app.$k) -join '|')) { $changed += $k }
                    }
                    $oldMeta = if ($old.metadata) { $old.metadata | ConvertTo-Json -Depth 8 -Compress } else { '' }
                    $nowMeta = if ($app.metadata) { $app.metadata | ConvertTo-Json -Depth 8 -Compress } else { '' }
                    if ($oldMeta -ne $nowMeta) { $changed += 'settings' }
                }
                catch { $changed = @('(unreadable)') }
                $rows.Add([ordered]@{ id = "$($dir.Name)/$($f.Name)"; when = "$day $($time.Substring(0,2)):$($time.Substring(2,2)):$($time.Substring(4,2))$(if ($seq -gt 1) { " ($seq)" })"; order = "$day $time $('{0:D4}' -f $seq)"; changed = $changed })
            }
        }
    }
    return @{ ok = $true; app = $app.appName; backups = @($rows | Sort-Object { $_.order } -Descending) }
}

function Global:Restore-WebAppBackup {
    <#
      Puts one kept copy back as the app's file - the current file is kept
      as a copy first, so a restore can itself be undone. -id must be one
      Get-WebAppBackups listed for this app (a name inside the Backups
      folder, never a path).
    #>
    param($Data)
    $name = [string]$Data.name
    $id = [string]$Data.id
    if ($id -notmatch '^app-edit_\d{4}-\d{2}-\d{2}/\d{6}(-\d+)?_[^\\/:*?"<>|]+\.json$') { return @{ ok = $false; error = 'That is not a backup of this app.' } }
    $catalog = Read-WebCatalogRecords
    $app = $catalog.Apps | Where-Object { $_.appName -eq $name } | Select-Object -First 1
    if (-not $app) { return @{ ok = $false; error = "No app called '$name' in the catalog." } }
    $leaf = (Get-SafeFileNameForApp -Name $app.appName) + '.json'
    if (-not $id.EndsWith("_$leaf")) { return @{ ok = $false; error = 'That backup is of another app.' } }
    $source = Join-Path (Get-AppFolder -Kind Backups) ($id -replace '/', [IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { return @{ ok = $false; error = 'That backup is gone.' } }
    try { $old = ConvertTo-AppRecord (Get-Content -LiteralPath $source -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { return @{ ok = $false; error = "That backup can't be read: $($_.Exception.Message)" } }
    if ((Get-SafeFileNameForApp -Name $old.appName) + '.json' -ne $leaf) { return @{ ok = $false; error = "That copy is of '$($old.appName)' - rename the app back first." } }
    $problem = Test-WebAppEdit -Record $old -OriginalName $app.appName -Others @($catalog.Apps)
    if ($problem) { return @{ ok = $false; error = "It can't go back as it was: $problem" } }
    $file = Join-Path (Get-AppFolder -Kind Catalog) $leaf
    Backup-WebAppFile $file
    try { Save-WebAppJson -File $file -App $old -Text "Restored the version from $($id.Split('/')[0] -replace 'app-edit_', '')" }
    catch { return @{ ok = $false; error = "Couldn't write $file`: $($_.Exception.Message)" } }
    Write-Log "[OK] $($app.appName): restored the copy from $($id.Split('/')[0] -replace 'app-edit_', '') (the version before the restore is kept too)."
    return @{ ok = $true; name = $old.appName }
}


# ---------------------------------------------------------------- change history
# Every change to an app's catalog file, field by field (from -> to), and
# every step that changed it in Intune, with where it came from - one JSON
# line each in Backups\history\<yyyy-MM>.jsonl. Earlier versions (above)
# keep whole files; this says who changed what, and undoes one change.

function Global:Get-WebChangeSource {
    # Pure: where a change came from, by the request that made it - shown in the history.
    param([string]$Path)
    switch -Wildcard ($Path) {
        '/api/app-save' { 'Editor' } '/api/app-restore' { 'Earlier versions (restore)' } '/api/history-undo' { 'History (undo)' }
        '/api/batch-*' { 'Batch edit' } '/api/replace-group' { 'Replace group' } '/api/assignments-set' { 'Groups x apps' } '/api/undo-last' { 'Undo' }
        '/api/pull-apply' { 'Pull from Intune' } '/api/csv-import' { 'CSV import' } '/api/add-*' { 'Add apps' } '/api/checks-fix' { 'Checks (fix)' }
        '/api/release-*' { 'Updates' } '/api/managed-*' { 'Managed updates' } '/api/winget-take-version' { 'Updates' } '/api/job-poll' { 'Step result' }
        '/api/retire-*' { 'Retire' } '/api/clear-appid*' { 'Clear App ID' } '/api/group-*' { 'Groups' }
        default { if ($Path) { 'This app (' + ($Path -replace '^/api/', '') + ')' } else { 'This app' } }
    }
}

function Global:Add-WebHistoryEntry {
    # One line in the change history. -Kind: catalog (with -Changes) or intune (a step that changed it there).
    param([string]$App, [string]$Kind, [string]$Text = '', $Changes = @(), [string]$Source = '')
    try {
        $dir = Join-Path (Get-AppFolder -Kind Backups -Create) 'history'
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        $src = if ($Source) { $Source } elseif ($Global:WebChangeSource) { [string]$Global:WebChangeSource } else { 'This app' }
        $entry = [ordered]@{ id = [guid]::NewGuid().ToString('N'); at = (Get-Date).ToUniversalTime().ToString('o'); app = $App; kind = $Kind; source = $src; text = $Text; changes = @($Changes) }
        $line = (ConvertTo-Json -InputObject $entry -Compress -Depth 6) + "`n"
        [System.IO.File]::AppendAllText((Join-Path $dir ((Get-Date).ToString('yyyy-MM') + '.jsonl')), $line, (New-Object System.Text.UTF8Encoding($false)))
    }
    catch { }
}

function Global:Save-WebAppJson {
    <#
      Writes one app's catalog file - the one place every catalog write goes
      through - and puts what changed, field by field, into the history.
    #>
    param([string]$File, $App, [string]$Text = '',
        # A rename: the app's file under its old name, the "before" of this write.
        [string]$BeforeFile = '')
    $json = ConvertTo-SingleAppJson -App $App
    $before = $null
    $from = if ($BeforeFile -and (Test-Path -LiteralPath $BeforeFile)) { $BeforeFile } else { $File }
    if (Test-Path -LiteralPath $from) { try { $before = ConvertTo-AppRecord (Get-Content -LiteralPath $from -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { } }
    [System.IO.File]::WriteAllText($File, $json, (New-Object System.Text.UTF8Encoding($false)))
    try {
        $after = ConvertTo-AppRecord ($json | ConvertFrom-Json)
        if (-not $before) { Add-WebHistoryEntry -App ([string]$after.appName) -Kind 'catalog' -Text $(if ($Text) { $Text } else { 'Added to the catalog' }); return }
        $changes = @(Get-AppRecordChanges -Before $before -After $after | ForEach-Object {
            # Very long values (a detection script) are named, not kept - Earlier versions has them.
            if ($_.before.Length -gt 20000 -or $_.after.Length -gt 20000) { $_.before = '"(long - see Earlier versions)"'; $_.after = '"(long - see Earlier versions)"'; $_.long = $true }
            $_
        })
        if ($changes.Count) { Add-WebHistoryEntry -App ([string]$after.appName) -Kind 'catalog' -Text $Text -Changes $changes }
    }
    catch { }
}

function Global:Read-WebHistoryEntries {
    # The history, newest first: the last -Months files.
    param([int]$Months = 24)
    $dir = Join-Path (Get-AppFolder -Kind Backups) 'history'
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    $files = @(Get-ChildItem -LiteralPath $dir -File -Filter '*.jsonl' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d{4}-\d{2}\.jsonl$' } | Sort-Object Name -Descending | Select-Object -First $Months)
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($f in $files) {
        $lines = @(Get-Content -LiteralPath $f.FullName -Encoding UTF8 -ErrorAction SilentlyContinue)
        for ($i = $lines.Count - 1; $i -ge 0; $i--) { if ($lines[$i]) { try { $out.Add(($lines[$i] | ConvertFrom-Json)) } catch { } } }
    }
    return $out.ToArray()
}

function Global:Get-WebAppHistory {
    <#
      One app's history, newest first - following renames back, so what
      happened under its old name is there too. Catalog changes with each
      field's before and after, and whether it can be undone on its own.
    #>
    param($Data)
    $name = [string]$Data.name
    $names = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
    [void]$names.Add($name)
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($e in @(Read-WebHistoryEntries)) {
        if (-not $names.Contains([string]$e.app)) { continue }
        $changes = @(@($e.changes) | Where-Object { $_ } | ForEach-Object {
            if ($_.field -eq 'appName') { [void]$names.Add((Format-AppHistoryValue $_.before)) }
            [ordered]@{ field = [string]$_.field; before = (Format-AppHistoryValue $_.before); after = (Format-AppHistoryValue $_.after); revertable = [bool]((Test-AppRecordFieldRevertable ([string]$_.field)) -and -not $_.long) }
        })
        $rows.Add([ordered]@{ id = [string]$e.id; at = [string]$e.at; app = [string]$e.app; kind = [string]$e.kind; source = [string]$e.source; text = [string]$e.text; changes = $changes
            canUndo = ($e.kind -eq 'catalog' -and @($changes | Where-Object { $_.revertable }).Count -gt 0) })
        if ($rows.Count -ge 300) { break }
    }
    return @{ ok = $true; app = $name; entries = $rows.ToArray() }
}

function Global:Undo-WebHistoryChange {
    <#
      Puts the fields one catalog change changed back to what they were -
      only those still as that change left them; a field changed again
      since is left alone and named.
    #>
    param($Data)
    $name = [string]$Data.name; $id = [string]$Data.id
    if ($id -notmatch '^[0-9a-f]{32}$') { return @{ ok = $false; error = 'That is not a change in the history.' } }
    $entry = @(Read-WebHistoryEntries | Where-Object { $_.id -eq $id }) | Select-Object -First 1
    if (-not $entry -or $entry.kind -ne 'catalog') { return @{ ok = $false; error = 'That change is not in the history (or was not a catalog change).' } }
    $catalog = Read-WebCatalogRecords
    $app = $catalog.Apps | Where-Object { $_.appName -eq $name } | Select-Object -First 1
    if (-not $app) { return @{ ok = $false; error = "No app called '$name' in the catalog." } }
    $now = Get-AppRecordFieldValues $app
    $done = New-Object System.Collections.Generic.List[string]; $skipped = New-Object System.Collections.Generic.List[string]
    $empty = @('null', '""', '[]')
    foreach ($c in @($entry.changes)) {
        $f = [string]$c.field
        if (-not (Test-AppRecordFieldRevertable $f) -or $c.long) { $skipped.Add("$f (not undone on its own - use Earlier versions)"); continue }
        $cur = if ($now.Contains($f)) { [string]$now[$f] } else { 'null' }
        if ($cur -cne [string]$c.after -and -not ($empty -contains $cur -and $empty -contains [string]$c.after)) { $skipped.Add("$f (changed again since)"); continue }
        if (Set-AppRecordFieldJson -Record $app -Field $f -Json ([string]$c.before)) { $done.Add($f) }
    }
    if (-not $done.Count) { return @{ ok = $false; error = "Nothing to undo: $($skipped -join '; ')." } }
    $when = try { ([datetime]$entry.at).ToLocalTime().ToString('yyyy-MM-dd HH:mm') } catch { [string]$entry.at }
    $file = Join-Path (Get-AppFolder -Kind Catalog) ((Get-SafeFileNameForApp -Name $app.appName) + '.json')
    Backup-WebAppFile $file
    Save-WebAppJson -File $file -App $app -Text "Undid the change of $when"
    Write-Log "[OK] $name`: undid the change of $when ($($done -join ', '))."
    return @{ ok = $true; undone = $done.ToArray(); skipped = $skipped.ToArray() }
}
