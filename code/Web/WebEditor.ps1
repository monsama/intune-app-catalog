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
        lobToRetire = [string]$App.lobToRetire
        setupFile = [string]$App.setupFile
        blockedVersions = @($App.blockedVersions | Where-Object { $_ } | ForEach-Object { [string]$_ })
        hasMetadata  = [bool]$m
        managedUpdates = [bool]$App.managedUpdates
        releaseRule  = $(if ($App.releaseRule) { [ordered]@{ days = $App.releaseRule.days; maxFailedPercent = $App.releaseRule.maxFailedPercent; minInstalled = $App.releaseRule.minInstalled } } else { $null })
        detectedName = [string]$App.detectedName
        autoRelease  = [bool]$App.autoRelease
        downloadUrl  = [string]$App.downloadUrl
        watchWinget  = [string]$App.watchWinget
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
    # An own-package app: the installer Package builds into the .intunewin (and Deploy uploads) - its version, to compare with the App version.
    $installer = if (-not $app.wingetId) { try { Get-WebInstallerInfo $app.appName -SetupFile ([string]$app.setupFile) } catch { $null } } else { $null }
    $offers = [string]$(if ($Global:App.WingetLatest -and $app.wingetId) { $Global:App.WingetLatest[([string]$app.wingetId).ToLowerInvariant()] })
    return @{ ok = $true; app = $editable; version = (Get-WebAppFileVersion $app.appName); installer = $installer; wingetOffers = $offers; knownGroups = @(Get-AllKnownGroups | Sort-Object -Unique)
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
        # The MSI app to retire stays as it was - Send to Intune and Retire the MSI app change it, not the editor.
        lobToRetire      = $(if ($Existing) { [string]$Existing.lobToRetire } else { '' })
        # The chosen setup file stays as it was - uploads and the package file list change it, not the editor's form.
        setupFile        = $(if ($Existing) { [string]$Existing.setupFile } else { '' })
        watchWinget      = $(if ($null -ne $Edit.watchWinget) { $w = ([string]$Edit.watchWinget).Trim(); if (Test-WebWingetId $w) { $w } else { '' } } elseif ($Existing) { [string]$Existing.watchWinget } else { '' })
        # Kept as they were - releases and Send to Intune change them, not the editor.
        blockedVersions  = @($(if ($Existing) { @($Existing.blockedVersions) }) | Where-Object { $_ })
        packageStamp     = $(if ($Existing) { [string]$Existing.packageStamp } else { '' })
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
        Add-WebCopyRecord $target
        if ($PassThru) { return $target }
    }
    catch { }
}

function Global:Copy-WebApp {
    <#
      A new app made as a copy of one in the catalog (2.35.0): its groups, filter and managed updates, its settings
      (commands, detection, requirements, return codes, dependencies) and icon - through the same save as any app, so
      the name is checked. Not copied: its App ID, releases, package files and the supersedence (two apps replacing the
      same older one would fight over it) - the copy is new to Intune.
    #>
    param($Data)
    $all = @((Read-WebCatalogRecords).Apps)
    $a = $all | Where-Object { $_.appName -eq [string]$Data.name } | Select-Object -First 1
    if (-not $a) { return @{ ok = $false; error = "No app called '$($Data.name)' in the catalog." } }
    $newName = ([string]$Data.newName).Trim() -replace '\s+', ' '
    $why = Test-WebAddName $newName $all
    if ($why) { return @{ ok = $false; error = $why } }
    $edit = [pscustomobject]@{ appName = $newName; wingetId = [string]$a.wingetId; appId = ''; managedUpdates = [bool]$a.managedUpdates
        requiredFor = @($a.requiredFor); availableFor = @($a.availableFor); uninstallFor = @($a.uninstallFor); excludeFor = @($a.excludeFor)
        assignmentFilter = [string]$a.assignmentFilter; assignmentFilterMode = [string]$a.assignmentFilterMode; watchWinget = [string]$a.watchWinget
        # The release settings come along (2.38.0), and the name Windows lists it under: the copy's own name ("Chrome (2)")
        # is no name Windows lists, so a detection by it would never find the app.
        detectedName = $(if ([string]$a.detectedName) { [string]$a.detectedName } else { [string]$a.appName }); autoRelease = [bool]$a.autoRelease; downloadUrl = [string]$a.downloadUrl
        releaseRule = $(if ($a.releaseRule) { [pscustomobject]@{ days = [string]$a.releaseRule.days; maxFailedPercent = [string]$a.releaseRule.maxFailedPercent; minInstalled = [string]$a.releaseRule.minInstalled } } else { $null }) }
    $r = Save-WebApp @{ originalName = ''; version = ''; app = $edit }
    if (-not $r.ok) { return $r }
    # A copy of its own, not the same objects.
    $meta = if ($a.metadata) { $a.metadata | ConvertTo-Json -Depth 20 | ConvertFrom-Json } else { $null }
    if ($meta -and $meta.PSObject.Properties.Name -contains 'supersedes') { $meta.supersedes = @() }
    if ($meta -and $meta.PSObject.Properties.Name -contains 'supersedesSet') { $meta.supersedesSet = $false }
    $icon = $a.icon
    [void](Update-WebCatalogApp -Name $r.name -Change { param($x) if ($meta) { $x.metadata = $meta }; if ($icon) { $x.icon = $icon } }.GetNewClosure())
    Add-WebHistoryEntry -App $r.name -Kind 'catalog' -Text "Made as a copy of $($a.appName)"
    Write-Log "[OK] $($r.name) made as a copy of $($a.appName)."
    return @{ ok = $true; name = $r.name }
}

function Global:Save-WebApp {
    # Holding the catalog lock (2.38.0) - see Update-WebCatalogApp.
    param($Data)
    return (Invoke-WithCatalogLock { Save-WebAppHeld $Data }.GetNewClosure())
}

function Global:Save-WebAppHeld {
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
    $problem = Test-ManagedAppEdit -Existing $existing -Record $record
    if ($problem) { return @{ ok = $false; error = $problem } }
    if ([string]$edit.iconChange -eq 'set' -and -not $record.icon) { return @{ ok = $false; error = 'The icon must be a PNG or JPEG of at most 750 KB.' } }
    if (([string]$edit.downloadUrl).Trim() -and -not $record.downloadUrl) { return @{ ok = $false; error = 'The installer download address must start with https://.' } }
    if (([string]$edit.watchWinget).Trim() -and -not $record.watchWinget) { return @{ ok = $false; error = "'$(([string]$edit.watchWinget).Trim())' isn't a Winget ID (letters, digits and . _ + -)." } }
    # Watched only for an own package: a Winget app's own ID already says it.
    if ($record.wingetId) { $record.watchWinget = '' }
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
    # A new Winget ID: the generated commands and the detection follow it (hand-edited ones stay).
    if ($existing -and $existing.wingetId -and $record.wingetId -and $existing.wingetId -ne $record.wingetId) { [void](Set-AppWingetIdCommands -App $record -OldId ([string]$existing.wingetId)) }
    # A managed app's commands and detection follow its App version (pinned).
    [void](Set-ManagedAppPin $record)
    # The winget commands exit 9009 while winget isn't on a new device yet - a Retry return code.
    if ($record.metadata -and [string]$record.metadata.installCommand -like '*exit 9009*') {
        $codes = @(Add-WingetRetryReturnCode $record.metadata.returnCodes)
        if ($record.metadata.PSObject.Properties['returnCodes']) { $record.metadata.returnCodes = $codes } else { $record.metadata | Add-Member -NotePropertyName returnCodes -NotePropertyValue $codes }
    }
    # An own package's scripts write the version marker its detection rule checks - they follow a new version.
    if (-not $record.wingetId -and $record.metadata -and $existing -and $existing.metadata -and [string]$existing.metadata.appVersion -ne [string]$record.metadata.appVersion) {
        [void](Update-WebMarkerVersion -Name $record.appName -Version ([string]$record.metadata.appVersion))
    }

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
    if ($existing -and $existing.appName -ne $record.appName) { Rename-WebAppReferences -Old $existing.appName -New $record.appName }
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
                    foreach ($k in 'appName', 'appId', 'wingetId', 'requiredFor', 'availableFor', 'uninstallFor', 'excludeFor', 'assignmentFilter', 'assignmentFilterMode', 'retiringSince') {
                        if ((@($old.$k) -join '|') -ne (@($app.$k) -join '|')) { $changed += $k }
                    }
                    $oldMeta = if ($old.metadata) { $old.metadata | ConvertTo-Json -Depth 8 -Compress } else { '' }
                    $nowMeta = if ($app.metadata) { $app.metadata | ConvertTo-Json -Depth 8 -Compress } else { '' }
                    if ($oldMeta -ne $nowMeta) { $changed += 'settings' }
                }
                catch { $changed = @('(unreadable)') }
                $rows.Add([ordered]@{ verified = ((Test-WebCopyRecord $f.FullName) -eq 'ok'); id = "$($dir.Name)/$($f.Name)"; when = "$day $($time.Substring(0,2)):$($time.Substring(2,2)):$($time.Substring(4,2))$(if ($seq -gt 1) { " ($seq)" })"; at = (ConvertTo-WebIsoTime "$day $($time.Substring(0,2)):$($time.Substring(2,2)):$($time.Substring(4,2))"); seq = $seq; order = "$day $time $('{0:D4}' -f $seq)"; changed = $changed })
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
    $refused = Get-WebCopyRefusal $source 'That copy'
    if ($refused) { return @{ ok = $false; error = $refused } }
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
# line each in <catalog>\.integrity\history\<yyyy-MM>.jsonl (with the catalog's permissions). Earlier versions (above)
# keep whole files; this says who changed what, and undoes one change.

function Global:Get-WebChangeSource {
    # Pure: where a change came from, by the request that made it - shown in the history.
    param([string]$Path)
    switch -Wildcard ($Path) {
        '/api/app-save' { 'Editor' } '/api/app-quick' { 'Side panel' } '/api/app-restore' { 'Earlier versions (restore)' } '/api/history-undo' { 'History (undo)' }
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
        # Next to the catalog (with its permissions), not in the Backups folder: Undo trusts what's written here.
        $dir = Join-Path (Get-WebIntegrityFolder -Create) 'history'
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        $src = if ($Source) { $Source } elseif ($Global:WebChangeSource) { [string]$Global:WebChangeSource } else { 'This app' }
        # Who made it - with several admins on one catalog, Recent changes says whose change it was.
        $entry = [ordered]@{ id = [guid]::NewGuid().ToString('N'); at = (Get-Date).ToUniversalTime().ToString('o'); app = $App; kind = $Kind; source = $src; by = $(if ($Global:App.Server -and $Global:App.Server.Session -and $Global:App.Server.Session.Name) { [string]$Global:App.Server.Session.Name } else { [string]$env:USERNAME }); text = $Text; changes = @($Changes) }
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
    # The same as on disk: nothing to write, nothing to record.
    if ((Test-Path -LiteralPath $File) -and -not $BeforeFile -and [System.IO.File]::ReadAllText($File) -ceq $json) { return }
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
    <#
      The history, newest first: the last -Months files, at most -Max entries (reading stops there). The catalog's
      own history (<catalog>\.integrity\history) first; then what earlier versions wrote to Backups\history -
      shown, but marked legacy: it's in a folder others may write to, so nothing is undone from it.
    #>
    param([int]$Months = 24, [int]$Max = 0)
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($src in @(@{ dir = (Join-Path (Get-WebIntegrityFolder) 'history'); legacy = $false }, @{ dir = (Join-Path (Get-AppFolder -Kind Backups) 'history'); legacy = $true })) {
        if ($Max -gt 0 -and $out.Count -ge $Max) { break }
        if (-not (Test-Path -LiteralPath $src.dir)) { continue }
        $files = @(Get-ChildItem -LiteralPath $src.dir -File -Filter '*.jsonl' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d{4}-\d{2}\.jsonl$' } | Sort-Object Name -Descending | Select-Object -First $Months)
        foreach ($f in $files) {
            $lines = @(Get-Content -LiteralPath $f.FullName -Encoding UTF8 -ErrorAction SilentlyContinue)
            for ($i = $lines.Count - 1; $i -ge 0; $i--) {
                if ($Max -gt 0 -and $out.Count -ge $Max) { break }
                if (-not $lines[$i]) { continue }
                try { $e = $lines[$i] | ConvertFrom-Json; if ($src.legacy) { $e | Add-Member -NotePropertyName legacy -NotePropertyValue $true -Force }; $out.Add($e) } catch { }
            }
            if ($Max -gt 0 -and $out.Count -ge $Max) { break }
        }
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
        # PowerShell 7 reads the time as a date - written back in UTC (ISO), as it was stored.
        $rows.Add([ordered]@{ id = [string]$e.id; at = $(if ($e.at -is [datetime]) { $e.at.ToUniversalTime().ToString('o') } else { [string]$e.at }); app = [string]$e.app; kind = [string]$e.kind; source = [string]$e.source; text = [string]$e.text; changes = $changes
            canUndo = ($e.kind -eq 'catalog' -and -not $e.legacy -and @($changes | Where-Object { $_.revertable }).Count -gt 0 -and -not @($changes | Where-Object { $_.field -in 'releases', 'appId' }).Count) })
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
    if ($entry.legacy) { return @{ ok = $false; error = 'That change is from the history before version 2.23, kept in the Backups folder - it is shown, but nothing is undone from it. Earlier versions brings back a whole copy.' } }
    # Only a change of this app (under this name or one it had before) - never another app's fields.
    if (-not @((Get-WebAppHistory @{ name = $name }).entries | Where-Object { $_.id -eq $id }).Count) { return @{ ok = $false; error = "That change isn't one of $name's." } }
    # A release step (promotion, rollback, a new release) moved the app in Intune too - half of it can't be undone here.
    if (@(@($entry.changes) | Where-Object { [string]$_.field -in 'releases', 'appId' }).Count) { return @{ ok = $false; error = 'That change came with a release step (it changed which app in Intune is the current one) - take it back with Roll back or Withdraw (Updates), not here.' } }
    $catalog = Read-WebCatalogRecords
    $app = $catalog.Apps | Where-Object { $_.appName -eq $name } | Select-Object -First 1
    if (-not $app) { return @{ ok = $false; error = "No app called '$name' in the catalog." } }
    $now = Get-AppRecordFieldValues $app
    $done = New-Object System.Collections.Generic.List[string]; $skipped = New-Object System.Collections.Generic.List[string]
    $empty = @('null', '""', '[]', '')
    foreach ($c in @($entry.changes)) {
        $f = [string]$c.field
        # Only a field the app has (the history file can be edited by anyone with the Backups folder).
        if (-not $now.Contains($f)) { $skipped.Add("$f (not a field of this app)"); continue }
        if (-not (Test-AppRecordFieldRevertable $f) -or $c.long) { $skipped.Add("$f (not undone on its own - use Earlier versions)"); continue }
        $cur = if ($now.Contains($f)) { [string]$now[$f] } else { 'null' }
        if ($cur -cne [string]$c.after -and -not ($empty -contains $cur -and $empty -contains [string]$c.after)) { $skipped.Add("$f (changed again since)"); continue }
        if (Set-AppRecordFieldJson -Record $app -Field $f -Json ([string]$c.before)) { $done.Add($f) }
    }
    if (-not $done.Count) { return @{ ok = $false; error = "Nothing to undo: $($skipped -join '; ')." } }
    # Undoing the change that gave the app its own Intune details: no details again (the defaults apply), not empty ones.
    if ($app.metadata -and -not @($app.metadata.PSObject.Properties | Where-Object { $v = $_.Value; -not ($null -eq $v -or ($v -is [string] -and -not $v) -or (($v -is [array]) -and -not @($v | Where-Object { $_ }).Count)) }).Count) { $app.metadata = $null }
    # The same checks as the editor's Save, and a managed app's commands following its version.
    $problem = Test-WebAppEdit -Record $app -OriginalName $app.appName -Others @($catalog.Apps)
    if (-not $problem) { $problem = Test-ManagedAppEdit -Existing ((Read-WebCatalogRecords).Apps | Where-Object { $_.appName -eq $name } | Select-Object -First 1) -Record $app }
    if ($problem) { return @{ ok = $false; error = "It can't be undone: $problem" } }
    [void](Set-ManagedAppPin $app)
    $when = try { ([datetime]$entry.at).ToLocalTime().ToString('yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture) } catch { [string]$entry.at }
    $file = Join-Path (Get-AppFolder -Kind Catalog) ((Get-SafeFileNameForApp -Name $app.appName) + '.json')
    Backup-WebAppFile $file
    Save-WebAppJson -File $file -App $app -Text "Undid the change of $when"
    Write-Log "[OK] $name`: undid the change of $when ($($done -join ', '))."
    return @{ ok = $true; undone = $done.ToArray(); skipped = $skipped.ToArray() }
}

function Global:Update-WebAppQuick {
    <#
      A small change from the Apps page's side panel, without the editor:
      -field requiredFor | availableFor | uninstallFor | excludeFor with -add
      or -remove (one group), or appVersion with -value. A deployed app with
      managed updates gets a new version through Release new version, not here.
    #>
    param($Data)
    $name = [string]$Data.name; $field = [string]$Data.field
    $a = (Read-WebCatalogRecords).Apps | Where-Object { $_.appName -eq $name } | Select-Object -First 1
    if (-not $a) { return @{ ok = $false; error = "No app called '$name' in the catalog." } }
    if ($field -in 'requiredFor', 'availableFor', 'uninstallFor', 'excludeFor') {
        $add = ([string]$Data.add).Trim(); $remove = ([string]$Data.remove).Trim()
        if ($add) { $problem = Test-WebGroupName $add; if ($problem) { return @{ ok = $false; error = $problem } } }
        if (-not $add -and -not $remove) { return @{ ok = $false; error = 'Which group?' } }
        $list = @(@($a.$field) | ForEach-Object { [string]$_ } | Where-Object { $_ -and $_ -ne $remove })
        if ($add -and $list -notcontains $add) { $list += $add }
        [void](Update-WebCatalogApp -Name $name -Change { param($x) $x.$field = $list }.GetNewClosure())
        return @{ ok = $true; groups = $list }
    }
    if ($field -eq 'appVersion') {
        $v = ([string]$Data.value).Trim()
        if ($v.Length -gt 100) { return @{ ok = $false; error = 'That version is too long.' } }
        # No settings of its own yet: they start from the defaults (as Managed updates on does), now with this version.
        if (-not $a.metadata -and -not $a.wingetId) { return @{ ok = $false; error = "$name has no Intune details yet - set its version in the editor (Details)." } }
        if ($a.managedUpdates -and $a.appId) { return @{ ok = $false; error = "$name has managed updates and is in Intune - a new version goes through Release new version (More)." } }
        if ($a.managedUpdates -and $v -and -not (Test-ReleaseVersionText $v)) { return @{ ok = $false; error = "'$v' isn't a version managed updates can pin (digits and dots, e.g. 24.08)." } }
        [void](Update-WebCatalogApp -Name $name -Change {
            param($x)
            if (-not $x.metadata) { $x.metadata = Get-DefaultAppMetadata -AppName $x.appName -WingetId $x.wingetId -Uncommon $false }
            if ($x.metadata.PSObject.Properties['appVersion']) { $x.metadata.appVersion = $(if ($v) { $v } else { $null }) } else { $x.metadata | Add-Member -NotePropertyName appVersion -NotePropertyValue $v }
            [void](Set-ManagedAppPin $x)
        }.GetNewClosure())
        $scripts = if (-not $a.wingetId -and $v) { @(Update-WebMarkerVersion -Name $name -Version $v) } else { @() }
        return @{ ok = $true; scripts = $scripts }
    }
    return @{ ok = $false; error = 'That field cannot be changed here.' }
}

function Global:Update-WebMarkerVersion {
    <#
      A script app's or PSADT app's package scripts (Install.ps1,
      Invoke-AppDeployToolkit.ps1 in its packages folder) brought to -Version,
      so they write the version marker the detection rule checks for. The
      names of the files changed (the package needs building again).
    #>
    param([string]$Name, [string]$Version)
    if (-not (Test-ReleaseVersionText $Version)) { return @() }
    $folder = Join-Path (Get-AppFolder -Kind Packages) (Get-SafeFileNameForApp -Name $Name)
    $changed = New-Object System.Collections.Generic.List[string]
    foreach ($leaf in 'Install.ps1', 'Invoke-AppDeployToolkit.ps1') {
        $file = Join-Path $folder $leaf
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
        try {
            $r = Set-MarkerScriptVersion -Text (Get-Content -LiteralPath $file -Raw -Encoding UTF8) -Version $Version
            if ($r.Changed) { [System.IO.File]::WriteAllText($file, $r.Text, (New-Object System.Text.UTF8Encoding($true))); $changed.Add($leaf) }
        }
        catch { Write-Log "[WARN] $Name`: couldn't bring $leaf to $Version - $($_.Exception.Message)" }
    }
    if ($changed.Count) { Write-Log "[OK] $Name`: $($changed -join ', ') now write version $Version (build the package again)." }
    return @($changed)
}

function Global:Rename-WebAppReferences {
    <#
      After an app is renamed: other apps' dependencies name it by its catalog
      name (they would drop it on their next send), and its packages folder is
      named after it (its package wouldn't be found).
    #>
    param([string]$Old, [string]$New)
    $folder = Get-AppFolder -Kind Catalog
    foreach ($o in @((Read-WebCatalogRecords).Apps | Where-Object { $_.metadata -and @($_.metadata.dependencies) -contains $Old })) {
        $o.metadata.dependencies = @(@($o.metadata.dependencies) | ForEach-Object { if ([string]$_ -eq $Old) { $New } else { [string]$_ } })
        $file = Join-Path $folder ((Get-SafeFileNameForApp -Name $o.appName) + '.json')
        Backup-WebAppFile $file
        Save-WebAppJson -File $file -App $o -Text "Dependency renamed: $Old -> $New"
    }
    $pk = Get-AppFolder -Kind Packages
    $from = Join-Path $pk (Get-SafeFileNameForApp -Name $Old); $to = Join-Path $pk (Get-SafeFileNameForApp -Name $New)
    if ($from -ne $to -and (Test-Path -LiteralPath $from -PathType Container) -and -not (Test-Path -LiteralPath $to)) {
        try { Move-Item -LiteralPath $from -Destination $to -ErrorAction Stop; Write-Log "[OK] Its packages folder follows the new name: $to" }
        catch { Write-Log "[WARN] The packages folder $from couldn't be renamed to $to ($($_.Exception.Message)) - rename it by hand." }
    }
}

function Global:Get-WebWingetCommands {
    <#
      The editor's "Install with": which generated form the app's commands are
      now (Managed, Winget, WAU - the old Winget-AutoUpdate form - or '' for hand-edited), and - with -method -
      the commands for that form. Nothing is saved.
    #>
    param($Data)
    $id = ([string]$Data.wingetId).Trim()
    if (-not $id) { return @{ ok = $false; error = 'No Winget ID.' } }
    $ctx = if ([string]$Data.context -eq 'User') { 'User' } else { 'System' }
    $current = Get-AppWingetInstallMethod -WingetId $id -InstallCommand ([string]$Data.install) -UninstallCommand ([string]$Data.uninstall)
    $pinned = ''
    if ($current -eq 'Managed' -and ([string]$Data.install) -match " --version '((?:[^']|'')+)'") { $pinned = $Matches[1] -replace "''", "'" }
    # The extra winget options (2.25) the generated commands carry now - the editor's field shows them.
    $options = if ($current -in 'Managed', 'Winget') { Get-WingetCommandOptions ([string]$Data.install) } else { '' }
    $out = @{ ok = $true; current = $current; pinned = $pinned; options = $options }
    $method = [string]$Data.method
    if ($method) {
        if ($method -notin 'Managed', 'Winget') { return @{ ok = $false; error = 'Install with must be Managed or Winget.' } }
        # New options when the field sent them, else the ones the commands have.
        if ($null -ne $Data.options) {
            $o = ConvertTo-WingetOptionText ([string]$Data.options)
            if (-not $o.Ok) { return @{ ok = $false; error = $o.Error } }
            $options = $o.Options
        }
        $c = Get-WingetCommandLines -WingetId $id -Method $method -InstallContext $ctx -Version ([string]$Data.version) -Options $options
        if ($c.Install.Length -gt 1024) { return @{ ok = $false; error = "With these options the install command is $($c.Install.Length) characters - Intune takes 1024 at most. Shorten them." } }
        $out.install = $c.Install; $out.uninstall = $c.Uninstall; $out.options = $options
    }
    return $out
}

function Global:Get-WebCatalogHistory {
    <#
      The recent changes across the whole catalog, newest first, for the
      Recent changes panel: the entries of one action together (the same
      source and note, within a minute of each other - a batch edit of 12
      apps is one entry with 12 apps), and the last bulk change that Undo
      can take back. @{ ok; groups; undo }.
    #>
    param($Data)
    try { return (Get-WebCatalogHistoryCore $Data) }
    catch { return @{ ok = $false; error = "$($_.Exception.Message) - $($_.InvocationInfo.PositionMessage -replace '\s+', ' ')" } }
}

function Global:Get-WebCatalogHistoryCore {
    param($Data)
    [int]$limit = 200
    if ($Data -and $Data.limit) { $limit = [int]$Data.limit }
    if ($limit -lt 20) { $limit = 20 } elseif ($limit -gt 500) { $limit = 500 }
    $groups = New-Object System.Collections.Generic.List[object]
    $cur = $null
    $n = 0
    foreach ($e in @(Read-WebHistoryEntries -Months 3 -Max $limit)) {
        if ($n++ -ge $limit) { break }
        # The time as UTC ticks (a plain number to compare); PowerShell 7 reads it as a date already, 5.1 as text.
        [long]$ticks = 0
        try { if ($e.at -is [datetime]) { $ticks = $e.at.ToUniversalTime().Ticks } else { $ticks = ([datetime]::Parse([string]$e.at, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)).ToUniversalTime().Ticks } } catch { $ticks = 0 }
        $changes = @(@($e.changes) | Where-Object { $_ } | ForEach-Object {
            [ordered]@{ field = [string]$_.field; before = (Format-AppHistoryValue $_.before); after = (Format-AppHistoryValue $_.after); revertable = [bool]((Test-AppRecordFieldRevertable ([string]$_.field)) -and -not $_.long) }
        })
        $item = [ordered]@{ id = [string]$e.id; app = [string]$e.app; kind = [string]$e.kind; text = [string]$e.text; changes = @($changes)
            canUndo = ($e.kind -eq 'catalog' -and -not $e.legacy -and @($changes | Where-Object { $_.revertable }).Count -gt 0 -and -not @($changes | Where-Object { $_.field -in 'releases', 'appId' }).Count) }
        $key = "$([string]$e.source)|$([string]$e.by)|$([string]$e.kind)|$([string]$e.text)"
        if ($cur -and $cur.key -eq $key -and [Math]::Abs([double]($cur.last - $ticks)) -le 600000000.0) { $cur.items.Add($item); $cur.last = $ticks; continue }
        $cur = @{ key = $key; first = $ticks; last = $ticks; source = [string]$e.source; by = [string]$e.by; kind = [string]$e.kind; text = [string]$e.text; items = (New-Object System.Collections.Generic.List[object]) }
        $cur.items.Add($item)
        $groups.Add($cur)
    }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($g in $groups) {
        $list = $g['items']
        $when = (New-Object DateTime ([long]$g['first']), ([DateTimeKind]::Utc)).ToString('o')
        $out.Add([ordered]@{ at = $when; source = [string]$g['source']; by = [string]$g['by']; kind = [string]$g['kind']; text = [string]$g['text']; count = [int]$list.Count; items = $list.ToArray() })
    }
    return @{ ok = $true; groups = $out.ToArray(); undo = (Get-WebUndoInfo).undo }
}

function Global:Get-WebCatalogValues {
    # The publishers, owners and developers the catalog already uses - offered to pick, so the same name is written the same way.
    $apps = @((Read-WebCatalogRecords).Apps)
    $pick = { param($f) @($apps | ForEach-Object { if ($_.metadata) { ([string]$_.metadata.$f).Trim() } } | Where-Object { $_ } | Sort-Object -Unique) }
    return @{ ok = $true; publisher = @(& $pick 'publisher'); owner = @(& $pick 'owner'); developer = @(& $pick 'developer') }
}

# ---------------------------------------------------------------- copies the catalog can trust
# The Backups folder can be a share more people write to than the catalog folder. What comes back from it
# (Earlier versions, Undo, a retired app) is only taken when the catalog itself vouches for it: each copy
# this app writes gets its SHA-256 recorded in <catalog>\.integrity\copies.tsv - a file with the catalog's
# permissions. A copy changed since, or one that was never recorded (put there by hand, or older than 2.23),
# isn't restored. The change history itself is kept there too (<catalog>\.integrity\history).

function Global:Get-WebIntegrityFolder {
    param([switch]$Create)
    $dir = Join-Path (Get-AppFolder -Kind Catalog -Create:$Create) '.integrity'
    if ($Create -and -not (Test-Path -LiteralPath $dir)) {
        [void](New-Item -ItemType Directory -Path $dir -Force)
        try { (Get-Item -LiteralPath $dir -Force).Attributes += 'Hidden' } catch { }
    }
    return $dir
}

function Global:Get-WebBackupKey {
    # A copy's name inside the Backups folder ("app-edit_2026-11-15/101500_App.json"), the same on every PC.
    param([string]$Path)
    $root = [IO.Path]::GetFullPath((Get-AppFolder -Kind Backups)).TrimEnd('\', '/')
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { return '' }
    return $full.Substring($root.Length + 1).Replace('\', '/')
}

function Global:Add-WebCopyRecord {
    # Records a copy this app just wrote in the Backups folder: its name and SHA-256, in the catalog's integrity file.
    param([string]$Path)
    try {
        $key = Get-WebBackupKey $Path
        if (-not $key -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
        $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        [System.IO.File]::AppendAllText((Join-Path (Get-WebIntegrityFolder -Create) 'copies.tsv'), "$key`t$hash`n", (New-Object System.Text.UTF8Encoding($false)))
    }
    catch { Write-Log "[WARN] Couldn't record the copy $Path in the catalog's integrity file: $($_.Exception.Message)" }
}

function Global:Test-WebCopyRecord {
    # Whether a copy in the Backups folder is one this app wrote and nobody changed since: 'ok', 'changed' or 'unknown'.
    param([string]$Path)
    $key = Get-WebBackupKey $Path
    if (-not $key -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 'unknown' }
    $index = Join-Path (Get-WebIntegrityFolder) 'copies.tsv'
    if (-not (Test-Path -LiteralPath $index)) { return 'unknown' }
    $want = $null
    foreach ($line in [System.IO.File]::ReadAllLines($index)) {
        $p = $line.Split("`t")
        if ($p.Count -eq 2 -and [string]::Equals($p[0], $key, [StringComparison]::OrdinalIgnoreCase)) { $want = $p[1] }
    }
    if (-not $want) { return 'unknown' }
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -eq $want) { return 'ok' }
    return 'changed'
}

function Global:Get-WebCopyRefusal {
    # The reason a copy isn't taken back ('' when it may be).
    param([string]$Path, [string]$What = 'That copy')
    switch (Test-WebCopyRecord $Path) {
        'ok' { return '' }
        'changed' { return "$What was changed in the Backups folder since this app wrote it - it isn't taken back. Check the Backups folder's permissions (only the people who may change the catalog should be able to write there)." }
        default { return "$What isn't one this app recorded (it's from before version 2.23, or was put in the Backups folder by hand) - it isn't taken back automatically. Open it from the Backups folder and copy what you need by hand if you trust it." }
    }
}
