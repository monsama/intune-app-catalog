# Intune App Catalog & Deployment
# Copyright (C) 2026 Viktor Ljuca <https://monsama.ch>
# SPDX-License-Identifier: GPL-2.0-or-later

<#
.SYNOPSIS
    What the Apps list changes in Intune: the deploy plan, Deploy, Push
    groups, Package, Pull, Delete from Intune, Clear App ID and Install
    status. The routes are in WebApi.ps1.
#>

function Global:Get-WebDeployPlan {
    <#
      What Deploy would do for the chosen apps, before anything runs: in
      dependency order, each app ready or skipped with the reason.
    #>
    param($Data)
    $catalog = Read-WebCatalogRecords
    $names = @($Data.names | ForEach-Object { [string]$_ })
    $chosen = @($catalog.Apps | Where-Object { $names -contains $_.appName })
    if ($chosen.Count -eq 0) { return @{ ok = $false; error = 'Choose one or more apps first.' } }
    if (-not (Test-GraphCredentialsConfigured -Quiet)) { return @{ ok = $false; error = 'Set up the connection in Settings first.' } }
    $order = Get-DependencyOrderedApps -Apps $chosen
    # Winget apps deploy the shared package: built here if it isn't there yet (nothing to choose about it).
    if (@($chosen | Where-Object { $_.wingetId -and -not (Test-StoreProductId ([string]$_.wingetId)) }).Count) { [void](Initialize-SharedWingetPackage) }
    $index = Get-PackageFolderIndex -Root (Get-AppFolder -Kind Packages)
    # App IDs the connected tenant doesn't have (a catalog copied from another tenant): an update would fail.
    $tenantIds = $null; $t = $null
    if (@($chosen | Where-Object { $_.appId }).Count) {
        $t = Get-WebIntuneApps @{}
        if ($t.ok) { $tenantIds = @{}; foreach ($i in @($t.ids)) { $tenantIds[[string]$i] = $true } }
    }
    # The Intune type of each linked app: an MSI line-of-business app is sent as a new Win32 app (said in the plan).
    $typeOf = @{}
    if ($t -and $t.ok) { foreach ($x in @($t.apps)) { if ($x) { $typeOf[[string]$x.id] = [string]$x.type } } }
    # Settings > Automatic checks: before creating an app, look for one of the
    # same name already in Intune - creating a second is the mistake to stop.
    $inIntune = @{}
    $note = ''
    if ($Global:App.CheckIntuneOnDeployOpen -and @($chosen | Where-Object { -not $_.appId }).Count) {
        $read = Invoke-WebGraph -Permission 'DeviceManagementApps.ReadWrite.All' -Action {
            param($Graph)
            $names = New-Object System.Collections.Generic.List[object]
            $uri = 'https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?$select=id,displayName&$top=999'
            while ($uri) { $page = & $Graph $uri; foreach ($v in @($page.value)) { $names.Add($v) }; $uri = [string]$page.'@odata.nextLink' }
            , $names.ToArray()
        }
        if ($read.ok) { foreach ($v in @($read.value)) { $inIntune[([string]$v.displayName).Trim().ToLowerInvariant()] = [string]$v.id } }
        else { $note = "Couldn't look for apps of the same name in Intune: $($read.error)" }
    }
    $plan = foreach ($a in @($order.Ordered)) {
        $unc = Test-AppIsUncommon -App $a
        # A Microsoft Store app: Intune's own Store type - no package, no detection rule, no version to pin.
        # Microsoft 365 Apps (2.38.21) the same: Intune's own Office app, sent with its settings.
        $store = (Test-StoreProductId ([string]$a.wingetId)) -or [bool]$a.office
        $pkg = if ($store) { @{ Found = $true } } else { Resolve-AppPackagePath -AppName $a.appName -Uncommon $unc -Index $index -PackagePath $a.packagePath }
        $reason = ''
        $lt = if ($a.appId) { [string]$typeOf[([string]$a.appId).ToLowerInvariant()] } else { '' }
        if ($a.appId -and $tenantIds -and -not $tenantIds.ContainsKey(([string]$a.appId).ToLowerInvariant())) { $reason = "Its App ID isn't in this tenant (copied from another?) - clear it first: Catalog > Set up this tenant." }
        # A same-name app in Intune first: building a package would only lead to a duplicate.
        elseif (-not $a.appId -and $inIntune.ContainsKey(([string]$a.appName).Trim().ToLowerInvariant())) { $reason = 'An app with this name is already in Intune - link it (Checks > Link) instead of creating a second one.' }
        elseif (-not $store -and ($nonPkg = Get-NonPackageAppHint $a)) { $reason = $nonPkg }
        # Linked to a type it can't become (2.38.42) - the same refusals Start-WebDeploy gives, said here instead of mid-queue.
        elseif ($store -and $lt -and $lt -ne $(if ($a.office -and -not $a.wingetId) { 'officeSuiteApp' } else { 'winGetApp' })) { $reason = "It is linked to a $(Get-FriendlyIntuneAppType -ODataType $lt) in Intune, which can't become $(if ($a.office -and -not $a.wingetId) { 'Microsoft 365 Apps' } else { 'a Microsoft Store app' }) - clear its App ID (More > Clear App ID) and send it again." }
        elseif (-not $pkg.Found) {
            $reason = if ($unc) { "No package (.intunewin) yet - build it with More > Package." } else { "The shared Winget package (init.intunewin) isn't built yet - Settings > Packaging builds it." }
        }
        elseif (-not $store -and $a.managedUpdates -and $a.wingetId -and -not (Test-ReleaseVersionText ([string]$(if ($a.metadata) { $a.metadata.appVersion })))) { $reason = "Managed updates deploy a fixed version - set its App version first (Pin newest in its side panel)." }
        elseif ($unc -and -not $store -and -not ($a.metadata -and $a.metadata.detectionRule)) { $reason = "No detection rule yet - an app with a custom package needs one (the editor's Install & detection)." }
        $lob = $a.appId -and (Test-IntuneLobMsiType ([string]$typeOf[([string]$a.appId).ToLowerInvariant()]))
        # What doesn't fit together (2.36.0): said, not blocking - each can be on purpose.
        $warnings = if ($unc -and -not $store -and -not $reason) { @(Get-WebPackageWarnings $a) } else { @() }
        [ordered]@{ name = $a.appName; update = ([bool]$a.appId -and -not $lob); ready = (-not $reason); reason = $reason; deps = @($(if ($a.metadata) { @($a.metadata.dependencies) | Where-Object { $_ } | ForEach-Object { [string]$_ } }))
            replacesLob = [bool]$lob; warnings = @($warnings)
            note = $(if ($lob) { 'An MSI line-of-business app in Intune - it can''t be updated as Win32, so it is created as a new Win32 app with its groups. The MSI app stays until you retire it (the side panel).' } else { '' }) }
    }
    return @{ ok = $true; apps = @($plan); circular = @($order.CircularNames); note = $note }
}

function Global:Get-WebPackageWarnings {
    # An own package's commands, setup file, detection rule and App version against its folder and installer (Get-PackageConsistencyWarnings).
    param($App)
    if (-not $App -or $App.wingetId -or -not $App.metadata) { return @() }
    $folder = Join-Path (Get-AppFolder -Kind Packages) (Get-SafeFileNameForApp -Name $App.appName)
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) { return @() }
    $files = @(Get-PackageFolderFiles -Folder $folder | ForEach-Object { [string]$_.path })
    $inst = $null; try { $inst = Get-WebInstallerInfo $App.appName -SetupFile ([string]$App.setupFile) } catch { }
    $w = @(Get-PackageConsistencyWarnings -Metadata $App.metadata -Files $files -Installer $(if ($inst -and $inst.found) { $inst }) -SetupFile ([string]$App.setupFile))
    # The package against its files and against Intune (2.38.64): an old package (or none in Intune) under new commands
    # fails on the devices - M-Files' install.ps1 wasn't in the package Intune had.
    $pkg = Resolve-AppPackagePath -AppName $App.appName -Uncommon $true -Index $null -PackagePath ([string]$App.packagePath)
    if ($pkg.Found) {
        $item = Get-Item -LiteralPath $pkg.Path -ErrorAction SilentlyContinue
        if ($item -and @(Get-ChildItem -LiteralPath $folder -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Extension -ne '.intunewin' -and $_.LastWriteTimeUtc -gt $item.LastWriteTimeUtc.AddSeconds(2) } | Select-Object -First 1).Count) {
            $w += 'Files in its packages folder changed after the package was built - build it again (More > Build package), or Intune gets the old files.'
        }
        if ($App.appId -and $App.managedUpdates -and $App.packageStamp -and (Test-WebPackageIsNew -Stamp (Get-WebPackageStamp $pkg.Path) -Sent ([string]$App.packageStamp) -Record (Read-WebPackageSources)[(Get-SafeFileNameForApp -Name $App.appName)])) {
            $w += 'The package in Intune is older than the one built here - a send doesn''t upload it (managed updates). More > Replace package uploads it.'
        }
    }
    return @($w)
}

# ---------------------------------------------------------------- what went into a package (2.38.54)
# A rebuild always makes a new .intunewin (new time, and it is encrypted afresh, so its bytes differ too) - by the file
# alone every rebuild looked like a new package to upload. What it was built from says whether it really is: a
# fingerprint of its source files (relative path and content), kept per app in .integrity\package-sources.json as
# @{ built = the .intunewin's stamp; source = the fingerprint; sent = the fingerprint last uploaded to Intune }.

function Global:Read-WebPackageSources {
    $file = Join-Path (Get-WebIntegrityFolder) 'package-sources.json'
    $map = @{}
    if (Test-Path -LiteralPath $file) {
        try { foreach ($p in (Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties) { $map[$p.Name] = @{ built = [string]$p.Value.built; source = [string]$p.Value.source; sent = [string]$p.Value.sent } } } catch { }
    }
    return $map
}

function Global:Save-WebPackageSources {
    param([hashtable]$Map)
    $o = [ordered]@{}; foreach ($k in @($Map.Keys | Sort-Object)) { $o[$k] = [ordered]@{ built = [string]$Map[$k].built; source = [string]$Map[$k].source; sent = [string]$Map[$k].sent } }
    [System.IO.File]::WriteAllText((Join-Path (Get-WebIntegrityFolder -Create) 'package-sources.json'), (ConvertTo-Json -InputObject $o -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
}

function Global:Get-WebPackageSourceFingerprint {
    # The source files in an app's packages folder (not the .intunewin) - path and content - as one SHA-256; '' for none.
    param([string]$Folder)
    $files = @(Get-PackageFolderFiles $Folder)
    if (-not $files.Count) { return '' }
    $lines = foreach ($f in $files) { "$([string]$f.path)|$((Get-FileHash -LiteralPath (Join-Path $Folder ([string]$f.path -replace '\\', [System.IO.Path]::DirectorySeparatorChar)) -Algorithm SHA256).Hash)" }
    return (Get-WebTextSha256 (($lines | Sort-Object) -join "`n"))
}

function Global:Update-WebPackageSources {
    # After Package: each own-package app whose .intunewin is new gets the fingerprint of what it was built from.
    param([string[]]$Names)
    $map = Read-WebPackageSources
    $index = Get-PackageFolderIndex -Root (Get-AppFolder -Kind Packages)
    $changed = $false
    foreach ($a in @((Read-WebCatalogRecords).Apps | Where-Object { (Test-AppIsUncommon -App $_) -and -not $_.office })) {
        if (@($Names).Count -and $Names -notcontains [string]$a.appName) { continue }
        $pkg = Resolve-AppPackagePath -AppName $a.appName -Uncommon $true -Index $index -PackagePath $a.packagePath
        if (-not $pkg.Found) { continue }
        $stamp = Get-WebPackageStamp $pkg.Path
        $key = Get-SafeFileNameForApp -Name $a.appName
        if ($map.ContainsKey($key) -and $map[$key].built -eq $stamp) { continue }
        try { $fp = Get-WebPackageSourceFingerprint ([string](Split-Path -Parent $pkg.Path)) } catch { $fp = '' }
        $old = if ($map.ContainsKey($key)) { $map[$key].sent } else { '' }
        $map[$key] = @{ built = $stamp; source = $fp; sent = $old }
        $changed = $true
    }
    if ($changed) { Save-WebPackageSources $map }
}

function Global:Test-WebPackageIsNew {
    <#
      Whether an own-package app in Intune has a package to upload: its .intunewin ('stamp') isn't the one last uploaded
      (-Sent, the app's packageStamp) - unless it was built from exactly the files last uploaded (a rebuild of the same).
    #>
    param([string]$Stamp, [string]$Sent, $Record)
    if (-not $Stamp -or $Stamp -eq $Sent) { return $false }
    if ($Record -and $Record.built -eq $Stamp -and $Record.source -and $Record.source -eq $Record.sent) { return $false }
    return $true
}

function Global:Get-WebPackageStamp {
    # A package file's time and size ("2026-11-15T10:00:00Z|12345"), '' for none - what was uploaded last, to tell a newer one.
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $f = Get-Item -LiteralPath $Path
    return ($f.LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ssZ') + '|' + $f.Length)
}

function Global:Start-WebDeploy {
    # Deploys ONE app (the page runs the plan's apps one after another).
    param($Data)
    $catalog = Read-WebCatalogRecords
    $name = [string]$Data.name
    $a = $catalog.Apps | Where-Object { $_.appName -eq $name } | Select-Object -First 1
    if (-not $a) { return @{ ok = $false; error = "'$name' is no longer in the catalog." } }
    $unc = Test-AppIsUncommon -App $a
    # Microsoft 365 Apps (2.38.21): created (or updated) as Intune's own Office app with the catalog's settings.
    if ($a.office -and -not $a.wingetId) {
        if ($Data.metadataOnly -and -not $a.appId) { return @{ ok = $false; error = "$name isn't in Intune yet - send it first." } }
        # Linked to another kind of app (an Office Deployment Tool package as Win32, say): Intune can't turn that into
        # Microsoft 365 Apps - asked of Intune now (2.38.23), not patched blindly.
        if ($a.appId) {
            $ty = Get-WebIntuneAppODataType -AppId ([string]$a.appId)
            if ($ty.ok -and $ty.type -ne 'officeSuiteApp') { return @{ ok = $false; error = "$name is linked to a $(Get-FriendlyIntuneAppType -ODataType $ty.type) in Intune, which can't become Microsoft 365 Apps. Clear its App ID (More > Clear App ID) and send it again: Microsoft 365 Apps is created as a new app - then delete the old one in Intune." } }
        }
        $resultPath = Join-Path $env:TEMP (".intunepkg_officeapp_result_" + [guid]::NewGuid().ToString('N') + ".json")
        $body = ConvertTo-OfficeSuiteBody -Name $a.appName -Description ([string]$(if ($a.metadata) { $a.metadata.description })) -Settings $a.office
        # Microsoft's description stays in Intune on an update unless changed in the catalog (2.38.52, Test-OwnContentField).
        if ($a.appId -and -not (Test-OwnContentField $a 'description')) { $body.Remove('description') }
        # Owner, developer, notes and Featured too (2.38.42) - before they never left the catalog for Microsoft 365 Apps.
        if ($a.metadata) {
            foreach ($k in 'owner', 'developer', 'notes') { $v = [string]$a.metadata.$k; if ($v -or @($a.metadata.clearedFields) -contains $k) { $body[$k] = $v } }
            if ($null -ne $a.metadata.isFeatured) { $body['isFeatured'] = [bool]$a.metadata.isFeatured }
        }
        $config = @{ TenantId = $Global:App.GraphTenantId; ClientId = $Global:App.GraphClientId; CertificateThumbprint = $Global:App.GraphCertificateThumbprint
            AppName = $a.appName; AppId = [string]$a.appId; Body = $body; OutputResultPath = $resultPath }
        $busy = Enter-WebAppBusy -Name $a.appName -What 'deploying'; if ($busy) { return @{ ok = $false; error = $busy } }
        $started = Start-WebStepJob -BusyApp $a.appName -ScriptContent $Global:App.EmbeddedCreateOfficeAppScript -Name 'createofficeapp' -ConfigJson ($config | ConvertTo-Json -Depth 6) -ResultPath $resultPath -Kind "$(if ($a.appId) { 'Update' } else { 'Create' }) $name (Microsoft 365 Apps)" `
            -After @{ Kind = 'deploy'; AppName = $a.appName; Defaults = $null; WasUpdate = [bool]$a.appId; Office = $true; SentCleared = @(@($(if ($a.metadata) { $a.metadata.clearedFields })) | Where-Object { $_ -in 'owner', 'developer', 'notes' }); SendGroups = $(if ($null -ne $Data.sendGroups) { [bool]$Data.sendGroups } else { $null }) }
        if ($started.ok) { Write-Log "[INFO] Sending $name to Intune as Microsoft 365 Apps ($(Get-OfficeSettingsSummary $a.office))..." }
        return $started
    }
    # A Microsoft Store app: created (or updated) as Intune's own Store type - the Store installs and updates it.
    if (Test-StoreProductId ([string]$a.wingetId)) {
        if ($Data.metadataOnly -and -not $a.appId) { return @{ ok = $false; error = "$name isn't in Intune yet - send it first." } }
        # Linked to another kind of app (the legacy Store app, or a Win32 package): a Store app can't be patched onto it -
        # asked of Intune now (2.38.29), with what to do instead.
        if ($a.appId) {
            $ty = Get-WebIntuneAppODataType -AppId ([string]$a.appId)
            # The Store product of an app in Intune can't change (2.38.31): another ID in the catalog would be "updated" and change nothing.
            if ($ty.ok -and $ty.type -eq 'winGetApp' -and [string]$ty.value.packageIdentifier -and [string]$ty.value.packageIdentifier -ne [string]$a.wingetId) { return @{ ok = $false; error = "$name is the Store app $($ty.value.packageIdentifier) in Intune, the catalog says $($a.wingetId) - Intune can't change an app's Store product. Clear its App ID (More > Clear App ID) and send it again to create the new one, then delete the old one in Intune - or put $($ty.value.packageIdentifier) back." } }
            if ($ty.ok -and $ty.type -ne 'winGetApp') { return @{ ok = $false; error = "$name is linked to a $(Get-FriendlyIntuneAppType -ODataType $ty.type) in Intune, which can't become the new Microsoft Store app. Clear its App ID (More > Clear App ID) and send it again: the Store app is created new with its groups - devices that have it keep it. Then delete the old one in Intune." } }
        }
        $m = $a.metadata
        $resultPath = Join-Path $env:TEMP (".intunepkg_storeapp_result_" + [guid]::NewGuid().ToString('N') + ".json")
        $config = @{ TenantId = $Global:App.GraphTenantId; ClientId = $Global:App.GraphClientId; CertificateThumbprint = $Global:App.GraphCertificateThumbprint
            AppName = $a.appName; AppId = [string]$a.appId; PackageIdentifier = [string]$a.wingetId
            # The Store's own text and links (2.38.52): sent when the app is created, afterwards only those changed in the
            # catalog (Test-OwnContentField) - an empty value leaves Intune's as it is (CreateStoreApp).
            Description = [string]$(if ($m -and (-not $a.appId -or (Test-OwnContentField $a 'description'))) { $m.description }); Publisher = [string]$(if ($m -and (-not $a.appId -or (Test-OwnContentField $a 'publisher'))) { $m.publisher })
            InformationUrl = [string]$(if ($m -and (-not $a.appId -or (Test-OwnContentField $a 'informationUrl'))) { $m.informationUrl }); PrivacyUrl = [string]$(if ($m -and (-not $a.appId -or (Test-OwnContentField $a 'privacyUrl'))) { $m.privacyUrl })
            ClearedFields = @($(if ($m) { $m.clearedFields }) | Where-Object { $_ -and ($_ -notin 'informationUrl', 'privacyUrl' -or -not $a.appId -or (Test-OwnContentField $a $_)) })
            owner = [string]$(if ($m) { $m.owner }); developer = [string]$(if ($m) { $m.developer }); notes = [string]$(if ($m) { $m.notes }); IsFeatured = $(if ($m -and $null -ne $m.isFeatured) { [bool]$m.isFeatured } else { $null })
            RunAsAccount = $(if ($m -and [string]$m.installContext -eq 'User') { 'user' } else { 'system' }); OutputResultPath = $resultPath }
        # Shown as Being changed on every PC while it runs; a second start (a double click, another admin) is refused.
        $busy = Enter-WebAppBusy -Name $a.appName -What 'deploying'; if ($busy) { return @{ ok = $false; error = $busy } }
        $started = Start-WebStepJob -BusyApp $a.appName -ScriptContent $Global:App.EmbeddedCreateStoreAppScript -Name 'createstoreapp' -ConfigJson ($config | ConvertTo-Json -Depth 4) -ResultPath $resultPath -Kind "$(if ($a.appId) { 'Update' } else { 'Create' }) $name (Microsoft Store app)" `
            -After @{ Kind = 'deploy'; AppName = $a.appName; Defaults = $null; WasUpdate = [bool]$a.appId; Store = $true; SentCleared = @(@($config.ClearedFields) | Where-Object { $_ -in 'informationUrl', 'privacyUrl', 'owner', 'developer', 'notes' }); SendGroups = $(if ($null -ne $Data.sendGroups) { [bool]$Data.sendGroups } else { $null }) }
        if ($started.ok) { Write-Log "[INFO] Sending $name to Intune as a Microsoft Store app ($($a.wingetId))..." }
        return $started
    }
    # -metadataOnly: Push settings - the catalog's settings to an app already in
    # Intune, without uploading a package.
    $metadataOnly = [bool]$Data.metadataOnly
    # Linked to an MSI line-of-business app (asked of Intune now, not taken from the catalog): Intune can't turn it
    # into a Win32 app, so it is created as a new one - the catalog then follows that, the MSI app is left to retire.
    $replacesLob = ''
    if ($a.appId) {
        $ty = Get-WebIntuneAppODataType -AppId ([string]$a.appId)
        if ($ty.ok -and (Test-IntuneLobMsiType $ty.type)) {
            if ($metadataOnly) { return @{ ok = $false; error = "$name is an MSI line-of-business app in Intune - its settings can't be pushed as a Win32 app's. Send it to Intune: it is created as a Win32 app that replaces it." } }
            $replacesLob = ([string]$a.appId).ToLowerInvariant()
            $a = $a.PSObject.Copy(); $a.appId = ''
        }
        # Another of Intune's own types (2.38.42): Win32 settings can't be patched onto it - refused, not sent and failed.
        elseif ($ty.ok -and $metadataOnly -and $ty.type -ne 'win32LobApp') { return @{ ok = $false; error = "$name is a $(Get-FriendlyIntuneAppType -ODataType $ty.type) in Intune - only a Win32 app's settings can be sent from here. Change it in the Intune portal." } }
    }
    if ($metadataOnly) {
        if (-not $a.appId) { return @{ ok = $false; error = "$name isn't in Intune yet - Deploy it first." } }
        if (-not $a.metadata) { return @{ ok = $false; error = "$name has no settings of its own yet - Pull them from Intune, or set them in the editor, first." } }
        $pkg = @{ Found = $true; Path = '' }
    }
    else {
        $pkg = Resolve-AppPackagePath -AppName $a.appName -Uncommon $unc -PackagePath $a.packagePath
        if (-not $pkg.Found) { return @{ ok = $false; error = "$name has no package to upload." } }
    }
    $defaults = $null
    $m = $a.metadata
    if (-not $m) { $defaults = Get-DefaultAppMetadata -AppName $a.appName -WingetId $a.wingetId -Uncommon $unc; $m = $defaults }
    # Managed: deployed pinned to its App version, whatever the file's commands say.
    if ($a.managedUpdates -and $a.wingetId) {
        if (-not (Test-ReleaseVersionText ([string]$m.appVersion))) { return @{ ok = $false; error = "$name has managed updates, so it is deployed at a fixed version - set its App version first (Pin newest in its side panel)." } }
        # The name too: the detection script looks for the app under its name in Windows' list of installed apps
        # (detectedName, else appName) - a copy without it got an empty pattern, and every send put that in Intune.
        $pinned = [pscustomobject]@{ managedUpdates = $true; wingetId = $a.wingetId; appName = $a.appName; detectedName = $a.detectedName; metadata = $m.PSObject.Copy() }
        [void](Set-ManagedAppPin $pinned)
        $m = $pinned.metadata
    }
    if (-not $m.detectionRule) { return @{ ok = $false; error = "$name has no detection rule - set one in the editor's Install & detection." } }
    $resultPath = Join-Path $env:TEMP (".intunepkg_createapp_result_" + [guid]::NewGuid().ToString('N') + ".json")
    $config = New-WebCreateAppConfig -Catalog $catalog -App $a -Metadata $m -Defaults $defaults -PackagePath $pkg.Path -ResultPath $resultPath
    # An own package already in Intune: a package newer than the one last uploaded goes up again - otherwise the
    # devices would keep the old installer under the new version and detection. (Managed updates: a new package
    # goes through Release new version, pilot first - never under the current app.)
    $stamp = Get-WebPackageStamp $(if (-not $metadataOnly -and $unc) { $pkg.Path } else { '' })
    # Built from the same files as the package last uploaded (2.38.54): not uploaded again - only noted as sent.
    $srcRec = if ($stamp) { (Read-WebPackageSources)[(Get-SafeFileNameForApp -Name $a.appName)] } else { $null }
    $upload = $stamp -and (-not $a.appId -or (-not $a.managedUpdates -and (Test-WebPackageIsNew -Stamp $stamp -Sent ([string]$a.packageStamp) -Record $srcRec)))
    # Replace package (2.38.64): the built package under the app as it is in Intune - also with managed updates, where a
    # send never uploads one (a new version goes through Release new version). Same version, other files.
    if ($Data.replacePackage) {
        if (-not $a.appId) { return @{ ok = $false; error = "$name isn't in Intune yet - send it first." } }
        if (-not $stamp) { return @{ ok = $false; error = "$name has no built package to upload - build it first (More > Build package)." } }
        # A version in pilot (2.38.66): the package built is that version's - under the current app it would reach everyone, unpiloted.
        $pilot = Get-WebAppRelease $a
        if ($pilot) { return @{ ok = $false; error = "Version $($pilot.version) of $name is in pilot - the package built here is that version's. Promote or withdraw it first." } }
        $upload = $true
    }
    $sameSource = $stamp -and $a.appId -and -not $a.managedUpdates -and -not $upload -and $stamp -ne [string]$a.packageStamp
    if ($Data.replacePackage -and $metadataOnly) { return @{ ok = $false; error = 'Replace package uploads the package - not with settings only.' } }
    if ($a.appId -and $upload) { $config.ReplaceContent = $true }
    # Shown as Being changed on every PC while it runs; a second start (a double click, another admin) is refused.
    $busy = Enter-WebAppBusy -Name $a.appName -What 'deploying'; if ($busy) { return @{ ok = $false; error = $busy } }
    $started = Start-WebStepJob -BusyApp $a.appName -ScriptContent $Global:App.EmbeddedCreateAppScript -Name 'createapp' -ConfigJson (ConvertTo-CreateAppConfigJson -Config $config) -ResultPath $resultPath -Kind "$(if ($metadataOnly) { 'Send settings' } else { 'Deploy' }) $name$(if ($a.appId -and $upload) { ' (new package)' })" `
        -After @{ Kind = 'deploy'; AppName = $a.appName; Defaults = $defaults; WasUpdate = [bool]$a.appId; SentCleared = @($config.ClearedFields); SendGroups = $(if ($null -ne $Data.sendGroups) { [bool]$Data.sendGroups } else { $null }); PackageStamp = $(if ($upload -or $sameSource) { $stamp } else { '' }); PackageSource = $(if ($upload -and $srcRec -and $srcRec.built -eq $stamp) { [string]$srcRec.source } else { '' }); ReplacesLobAppId = $replacesLob }
    if ($started.ok) { Write-Log "[INFO] $(if ($metadataOnly) { "Pushing $name's settings to Intune" } else { "Deploying $name ($($config.Mode)$(if ($a.appId -and $upload) { ', uploading the new package' }))" })..." }
    return $started
}

function Global:New-WebCreateAppConfig {
    # The CreateApp step's settings for one app (-Metadata: its settings, pinned for a managed app); Deploy and Release change what they need after.
    param($Catalog, $App, $Metadata, $Defaults, [string]$PackagePath, [string]$ResultPath)
    $a = $App; $m = $Metadata; $defaults = $Defaults
    # Dependencies by name -> the App IDs they have now; one not deployed yet is left out (as Batch Deploy does).
    $depIds = @(@($m.dependencies) | Where-Object { $_ } | ForEach-Object {
        $depName = [string]$_
        $dep = $Catalog.Apps | Where-Object { $_.appName -eq $depName } | Select-Object -First 1
        if ($dep -and $dep.appId) { $dep.appId }
    })
    # Assigned outside $( ) (2.38.34): an empty list - "no supersedence", which clears it in Intune - came out of a
    # subexpression as $null, "keep Intune's", so removing supersedence in the catalog never reached Intune.
    $supersedence = $null
    if (-not ($defaults -and $a.appId)) { $supersedence = Get-WebSupersedenceWithReleases -App $a -Supersedes $m.supersedes }
    return [pscustomobject]@{
        TenantId = $Global:App.GraphTenantId; ClientId = $Global:App.GraphClientId; CertificateThumbprint = $Global:App.GraphCertificateThumbprint
        Mode = $(if ($a.appId) { 'UpdateMetadata' } else { 'Create' }); ExistingAppId = [string]$a.appId
        AppName = $a.appName; Description = $m.description; Publisher = $m.publisher; Owner = $m.owner; Developer = $m.developer
        InformationUrl = $m.informationUrl; PrivacyUrl = $m.privacyUrl; Notes = $m.notes; AppVersion = $m.appVersion; ClearedFields = @($(if ($m) { $m.clearedFields }) | Where-Object { $_ }); IsFeatured = $(if ($defaults -and $a.appId) { $null } else { $m.isFeatured })
        InstallCommand = $m.installCommand; UninstallCommand = $m.uninstallCommand; DetectionRule = $m.detectionRule
        InstallContext = $m.installContext; Architecture = $m.architecture; MinOSVersionKey = $m.minOSKey; PackagePath = $PackagePath
        DependencyAppIds = $depIds; ReplaceContent = $false; LargeIcon = $a.icon
        # An app with no settings of its own, already in Intune: the defaults say nothing about supersedence or Featured - leave Intune's.
        # Its own earlier releases stay superseded (2.38.33): the catalog's list doesn't hold them, and sending it alone
        # removed the update path a promotion set up.
        Supersedence = $supersedence
        MinDiskSpaceMB = [int]$m.minDiskSpaceMB; MinMemoryMB = [int]$m.minMemoryMB; MinProcessors = [int]$m.minProcessors; MinCpuSpeedMHz = [int]$m.minCpuSpeedMHz
        InstallTimeMinutes = $(if ($m.installTimeMinutes) { [int]$m.installTimeMinutes } else { 60 }); DeviceRestartBehavior = $m.deviceRestartBehavior
        AllowAvailableUninstall = [bool]$m.allowAvailableUninstall; ReturnCodes = @($m.returnCodes); OutputResultPath = $ResultPath
    }
}

function Global:Start-WebPushGroups {
    <#
      Push groups for the chosen apps: Mode Preview lists what would be added
      and removed in Intune, Mode Apply does it (BatchAssign - Intune gets
      exactly the catalog's groups; missing groups are created). -single
      after a deploy pushes one app the way the single deploy does
      (TargetedAssign, no groups created).
    #>
    param($Data)
    $catalog = Read-WebCatalogRecords
    $names = @($Data.names | ForEach-Object { [string]$_ })
    $apps = @($catalog.Apps | Where-Object { $names -contains $_.appName -and $_.appId })
    if ($apps.Count -eq 0) { return @{ ok = $false; error = 'None of the chosen apps is in Intune yet (no App ID).' } }
    $resultPath = Join-Path $env:TEMP (".intunepkg_assign_result_" + [guid]::NewGuid().ToString('N') + ".json")
    $creds = @{ TenantId = $Global:App.GraphTenantId; ClientId = $Global:App.GraphClientId; CertificateThumbprint = $Global:App.GraphCertificateThumbprint }
    if ([string]$Data.mode -eq 'AfterDeploy') {
        $a = $apps[0]
        $config = @{
            TenantId = $creds.TenantId; ClientId = $creds.ClientId; CertificateThumbprint = $creds.CertificateThumbprint
            AppId = $a.appId; AppName = $a.appName
            RequiredGroups = @($a.requiredFor); AvailableGroups = @($a.availableFor); UninstallGroups = @($a.uninstallFor); ExcludeGroups = @($a.excludeFor)
            FilterName = [string]$a.assignmentFilter; FilterMode = [string]$a.assignmentFilterMode
            CreateMissingGroups = $false; OutputResultPath = $resultPath
        }
        $gid = Add-WebGroupIdsToConfig $config; if ($gid) { return @{ ok = $false; error = $gid } }
        # Shown as Being changed on every PC while it runs; a second start (a double click, another admin) is refused.
        $busy = Enter-WebAppBusy -Name $a.appName -What 'sending its groups'; if ($busy) { return @{ ok = $false; error = $busy } }
        return (Start-WebStepJob -BusyApp $a.appName -ScriptContent $Global:App.EmbeddedTargetedAssignScript -Name 'targetedassign' -ConfigJson ($config | ConvertTo-Json -Depth 6) -ResultPath $resultPath -Kind "Push groups $($a.appName)" -Apps @([string]$a.appName))
    }
    $mode = if ([string]$Data.mode -eq 'Apply') { 'Apply' } else { 'Preview' }
    $config = @{
        TenantId = $creds.TenantId; ClientId = $creds.ClientId; CertificateThumbprint = $creds.CertificateThumbprint
        Mode = $mode
        Apps = @($apps | ForEach-Object { @{ AppName = $_.appName; AppId = $_.appId; RequiredGroups = @($_.requiredFor); AvailableGroups = @($_.availableFor); UninstallGroups = @($_.uninstallFor); ExcludeGroups = @($_.excludeFor); FilterName = [string]$_.assignmentFilter; FilterMode = [string]$_.assignmentFilterMode } })
        CreateMissingGroups = $(if ($null -ne $Data.createMissing) { [bool]$Data.createMissing } else { $true })
        OutputResultPath = $resultPath
    }
    if ($mode -eq 'Apply') { $gid = Add-WebGroupIdsToConfig $config; if ($gid) { return @{ ok = $false; error = $gid } } }
    $started = Start-WebStepJob -ScriptContent $Global:App.EmbeddedBatchAssignScript -Name 'batchassign' -ConfigJson ($config | ConvertTo-Json -Depth 8) -ResultPath $resultPath -Kind "Push groups ($mode, $(Format-Count ($apps.Count) 'app'))" -Apps $(if ($mode -eq 'Apply') { @($apps | ForEach-Object { [string]$_.appName }) } else { @() })
    if ($started.ok) { Write-Log "[INFO] Push groups - $(if ($mode -eq 'Apply') { 'applying' } else { 'previewing' }) for $(Format-Count ($apps.Count) 'app')..." }
    return $started
}

function Global:Start-WebPackage {
    <#
      Builds .intunewin packages (Package.ps1) for apps with their own
      installer - one, several, or every one when -names is empty. Winget
      apps all deploy the shared init.intunewin and are skipped.
    #>
    param($Data)
    $catalog = Read-WebCatalogRecords
    $names = @($Data.names | ForEach-Object { [string]$_ } | Where-Object { $_ })
    $own = @($catalog.Apps | Where-Object { (Test-AppIsUncommon -App $_) -and -not $_.office })
    if ($names.Count) { $own = @($own | Where-Object { $names -contains $_.appName }) }
    if ($names.Count -and $own.Count -eq 0) { return @{ ok = $false; error = 'None of the chosen apps has a custom installer to package - Winget apps use the shared package.' } }
    $params = @{ InputFolder = (Get-AppFolder -Kind Packages -Create); Force = $true; ToolPath = (Get-PackagingToolPath) }
    if ((Get-PackagerChoice) -eq 'builtin') { $params.BuiltIn = $true }
    $folders = @($own | ForEach-Object { Get-SafeFileNameForApp -Name $_.appName })
    # The setup file chosen for an app (one in a subfolder too): Package takes it instead of guessing.
    $chosen = [ordered]@{}
    foreach ($o in $own) { if ($o.setupFile) { $chosen[(Get-SafeFileNameForApp -Name $o.appName)] = [string]$o.setupFile } }
    if ($chosen.Count) { $params.SetupFiles = ($chosen | ConvertTo-Json -Compress) }
    if ($names.Count -eq 1) { $params.SingleFolderName = $folders[0] }
    elseif ($names.Count -gt 1) { $params.FolderNames = ($folders -join ',') }
    $started = Start-WebStepJob -ScriptContent $Global:App.EmbeddedPackageScript -Name 'package' -ConfigJson '' -ResultPath '' -Kind 'Package' -Parameters $params -After @{ Kind = 'package'; Names = @($own | ForEach-Object { [string]$_.appName }) }
    if ($started.ok) { Write-Log "[INFO] Packaging $(if ($names.Count) { "$(Format-Count ($own.Count) 'app')" } else { 'every app with a custom installer' })..." }
    return $started
}

function Global:Start-WebPull {
    # Pull from Intune: reads each chosen app's settings and groups (SyncMetadata - only reads).
    param($Data)
    $catalog = Read-WebCatalogRecords
    $names = @($Data.names | ForEach-Object { [string]$_ })
    $apps = @($catalog.Apps | Where-Object { $names -contains $_.appName -and $_.appId })
    if ($apps.Count -eq 0) { return @{ ok = $false; error = 'None of the chosen apps is in Intune yet (no App ID).' } }
    $resultPath = Join-Path $env:TEMP (".intunepkg_sync_result_" + [guid]::NewGuid().ToString('N') + ".json")
    $config = @{
        TenantId = $Global:App.GraphTenantId; ClientId = $Global:App.GraphClientId; CertificateThumbprint = $Global:App.GraphCertificateThumbprint
        Apps = @($apps | ForEach-Object { @{ AppName = $_.appName; AppId = $_.appId } }); OutputResultPath = $resultPath
    }
    $started = Start-WebStepJob -ScriptContent $Global:App.EmbeddedSyncMetadataScript -Name 'syncmeta' -ConfigJson ($config | ConvertTo-Json -Depth 6) -ResultPath $resultPath -Kind "Pull ($(Format-Count ($apps.Count) 'app'))" -After @{ Kind = 'pull' }
    if ($started.ok) { Write-Log "[INFO] Reading $(Format-Count ($apps.Count) 'app') from Intune..." }
    return $started
}

function Global:Complete-WebPull {
    <#
      What Pull found: an app whose catalog entry matches
      Intune (or has no settings yet) takes Intune's at once; one that
      differs is kept back for the user to choose, field by field.
    #>
    param($Result)
    $applied = New-Object System.Collections.Generic.List[string]
    $failed = New-Object System.Collections.Generic.List[string]
    $review = New-Object System.Collections.Generic.List[object]
    $pending = @{}
    # What Intune has now, noted once after the loop (2.38.61: per app it read the whole catalog twice, under the lock).
    $stampS = New-Object System.Collections.Generic.List[string]; $stampG = New-Object System.Collections.Generic.List[string]
    foreach ($r in @($Result.results)) {
        if (-not $r.Success) { $failed.Add("$($r.AppName): $($r.Error)"); continue }
        $all = @((Read-WebCatalogRecords).Apps)
        $app = $all | Where-Object { $_.appName -eq $r.AppName } | Select-Object -First 1
        if (-not $app) { continue }
        # 2.38.34: Intune's dependencies and supersedence as the catalog would hold them - without the app's own release steps
        # (they'd come back as permanent differences), and the catalog's own when Intune's couldn't be read (they were wiped).
        $noRel = $r.PSObject.Properties['DependenciesFetchOk'] -and -not $r.DependenciesFetchOk
        $r.Metadata = Get-MetadataWithoutOwnReleases -Metadata $r.Metadata -App $app -CatalogNames @($all | ForEach-Object { [string]$_.appName }) -LocalMetadata $app.metadata -NoRelations:$noRel
        if ($noRel) { Write-Log "[WARN] $($r.AppName): Intune's dependencies and supersedence couldn't be read - the catalog's are kept." }
        $fieldDiffs = @(Get-CatalogMetadataFieldDiffs -Local $app.metadata -Remote $r.Metadata -OdataType $r.OdataType)
        # A Store app's or Microsoft 365 Apps' text and links from Microsoft, not changed here (2.38.52): Intune's are
        # simply taken - nothing to ask about (Test-OwnContentField).
        $labelKey = @{ 'Description' = 'description'; 'Publisher' = 'publisher'; 'Information URL' = 'informationUrl'; 'Privacy URL' = 'privacyUrl' }
        $fieldDiffs = @($fieldDiffs | Where-Object { -not $labelKey.ContainsKey([string]$_.Field) -or (Test-OwnContentField $app $labelKey[[string]$_.Field]) })
        # @() around the whole if: one difference on its own would otherwise be
        # unrolled to a single object without .Count (Windows PowerShell 5.1).
        $groupDiffs = @(if ($r.GroupFetchOk) { Get-GroupFieldDiffs -LocalApp $app -RemoteResult $r })
        # Microsoft 365 Apps' own settings (2.38.42): one more row to choose - Intune's, or the catalog's kept.
        if ($app.office -and -not ([string]$app.wingetId).Trim()) {
            $od = Get-WebOfficeDiff -App $app -ReportFailure
            # Intune's settings not read: not known to match - the settings aren't noted as what Intune has (2.38.61).
            if ($od -and $od.Failed) { $noRel = $true; $od = $null }
            if ($od) { $r | Add-Member -NotePropertyName OfficeFromIntune -NotePropertyValue $od.Office -Force; $groupDiffs += [pscustomobject]@{ Field = 'Microsoft 365 settings'; Local = $od.Local; Remote = $od.Remote } }
        }
        if (($app.metadata -and $fieldDiffs.Count -gt 0) -or $groupDiffs.Count -gt 0) {
            # With the catalog entry as it was reviewed (2.38.42): applied later, a promote or send in between must not be undone.
            $pending[$r.AppName] = @{ R = $r; AppId = [string]$app.appId; Stamp = (ConvertTo-Json -InputObject (Get-WebAppSentValues $app) -Compress -Depth 10); NoStampS = [bool]$noRel }
            $review.Add([ordered]@{ app = $r.AppName; diffs = @(@($fieldDiffs) + @($groupDiffs) | ForEach-Object { [ordered]@{ field = [string]$_.Field; local = (Get-CheckValueText $_.Local); intune = (Get-CheckValueText $_.Remote) } }) })
        }
        else {
            $rr = $r
            [void](Update-WebCatalogApp -Name $r.AppName -Change {
                param($a)
                $a.intuneAppType = Get-FriendlyIntuneAppType -ODataType $rr.OdataType
                $a.intuneAppVersion = [string]$rr.DisplayVersion
                $a.metadata = $rr.Metadata
            }.GetNewClosure())
            $applied.Add($r.AppName)
            # The catalog has what Intune has now (2.38.54): nothing to send - "Changes to send" compared with the last
            # send from here, so taking Intune's values left it saying the catalog had changed.
            # Not when part of it wasn't read (relations, Microsoft 365's settings): the catalog's kept values aren't Intune's.
            if ($app.appId) { if (-not $noRel) { $stampS.Add([string]$r.AppName) }; if ($r.GroupFetchOk) { $stampG.Add([string]$r.AppName) } }
        }
    }
    Save-WebPulledStamps -Settings $stampS.ToArray() -Groups $stampG.ToArray()
    $id = [guid]::NewGuid().ToString('N')
    if ($review.Count) {
        # A review left open without applying isn't kept for ever - one older than an hour goes.
        if (-not $Global:App.WebPendingAt) { $Global:App.WebPendingAt = [hashtable]::Synchronized(@{}) }
        foreach ($k in @($Global:App.WebPendingAt.Keys)) { if (((Get-Date) - [datetime]$Global:App.WebPendingAt[$k]).TotalHours -gt 1) { [void]$Global:App.WebPending.Remove($k); [void]$Global:App.WebPendingAt.Remove($k) } }
        $Global:App.WebPending[$id] = $pending
        $Global:App.WebPendingAt[$id] = Get-Date
    }
    Write-Log "[OK] Pulled from Intune: $($applied.Count) updated$(if ($review.Count) { ", $($review.Count) to review" })$(if ($failed.Count) { ", $($failed.Count) failed" })."
    return @{ ok = $true; pending = $(if ($review.Count) { $id } else { '' }); applied = $applied.ToArray(); review = $review.ToArray(); failed = $failed.ToArray() }
}

function Global:Invoke-WebPullApply {
    # The user's choice per reviewed app: which fields keep the catalog's value; the rest take Intune's.
    param($Data)
    $id = [string]$Data.pending
    if (-not $id -or -not $Global:App.WebPending.ContainsKey($id)) { return @{ ok = $false; error = 'Nothing waiting to be applied (run Pull again).' } }
    $pending = $Global:App.WebPending[$id]
    $done = New-Object System.Collections.Generic.List[string]
    $skipped = New-Object System.Collections.Generic.List[string]
    $stampS = New-Object System.Collections.Generic.List[string]; $stampG = New-Object System.Collections.Generic.List[string]
    $now = @((Read-WebCatalogRecords).Apps)
    foreach ($name in @($pending.Keys)) {
        $p = $pending[$name]
        $r = $p.R
        # Changed since the review (a promotion, a send, an edit): Intune's values shown then may be older than the
        # catalog's now - not applied; Pull again shows them as they are.
        $cur = $now | Where-Object { $_.appName -eq $name } | Select-Object -First 1
        if (-not $cur -or [string]$cur.appId -ne [string]$p.AppId -or (ConvertTo-Json -InputObject (Get-WebAppSentValues $cur) -Compress -Depth 10) -ne [string]$p.Stamp) { $skipped.Add($name); continue }
        $keep = @($Data.keep.$name | ForEach-Object { [string]$_ })
        [void](Update-WebCatalogApp -Name $name -Change {
            param($a)
            $a.intuneAppType = Get-FriendlyIntuneAppType -ODataType $r.OdataType
            $a.intuneAppVersion = [string]$r.DisplayVersion
            # A Microsoft Store app in Intune: its Store product ID too (2.38.30).
            if (-not $a.wingetId -and -not $a.office -and (Get-StoreIdFromSync $r)) { $a.wingetId = Get-StoreIdFromSync $r; $a.managedUpdates = $false }
            $a.metadata = if ($a.metadata) { Merge-CatalogMetadata -Remote $r.Metadata -Local $a.metadata -KeepLocalFields $keep } else { $r.Metadata }
            if ($r.PSObject.Properties['OfficeFromIntune'] -and $r.OfficeFromIntune -and $keep -notcontains 'Microsoft 365 settings') { $a.office = $r.OfficeFromIntune }
            if ($r.GroupFetchOk) {
                if ($keep -notcontains 'Required for') { $a.requiredFor = @($r.RequiredGroupNames) }
                if ($keep -notcontains 'Available for') { $a.availableFor = @($r.AvailableGroupNames) }
                if ($keep -notcontains 'Uninstall for') { $a.uninstallFor = @($r.UninstallGroupNames) }
            }
        }.GetNewClosure())
        $done.Add($name)
        # Intune's values taken (2.38.54): what Intune has now is the last-sent state - for the settings when none of the
        # catalog's were kept, for the groups likewise. A kept value still differs from Intune and stays a change to send.
        $groupLabels = @('Required for', 'Available for', 'Uninstall for')
        if ($cur.appId -and -not $p.NoStampS -and -not @($keep | Where-Object { $groupLabels -notcontains $_ }).Count) { $stampS.Add($name) }
        if ($cur.appId -and $r.GroupFetchOk -and -not @($keep | Where-Object { $groupLabels -contains $_ }).Count) { $stampG.Add($name) }
    }
    Save-WebPulledStamps -Settings $stampS.ToArray() -Groups $stampG.ToArray()
    [void]$Global:App.WebPending.Remove($id)
    Write-Log "[OK] Applied the pull for: $($done -join ', ')."
    if ($skipped.Count) { Write-Log "[WARN] Not applied - changed in the catalog since the review: $($skipped -join ', '). Pull them again." }
    return @{ ok = $true; applied = $done.ToArray(); skipped = $skipped.ToArray() }
}

function Global:Start-WebDeleteFromIntune {
    <#
      Deletes ONE app from Intune (DeleteApp - removes it as a dependency of
      another app first when -dependentOf says so), then clears its App ID
      in the catalog. The catalog entry itself stays.
    #>
    param($Data)
    $catalog = Read-WebCatalogRecords
    $name = [string]$Data.name
    $a = $catalog.Apps | Where-Object { $_.appName -eq $name } | Select-Object -First 1
    if (-not $a -or -not $a.appId) { return @{ ok = $false; error = "$name isn't in Intune (no App ID)." } }
    $resultPath = Join-Path $env:TEMP (".intunepkg_delete_result_" + [guid]::NewGuid().ToString('N') + ".json")
    $config = @{
        TenantId = $Global:App.GraphTenantId; ClientId = $Global:App.GraphClientId; CertificateThumbprint = $Global:App.GraphCertificateThumbprint
        AppId = $a.appId; AppName = $a.appName; RemoveDependencyFromAppId = ''; OutputResultPath = $resultPath
    }
    # Shown as Being changed on every PC while it runs; a second start (a double click, another admin) is refused.
    $busy = Enter-WebAppBusy -Name $a.appName -What 'deleting it from Intune'; if ($busy) { return @{ ok = $false; error = $busy } }
    $started = Start-WebStepJob -BusyApp $a.appName -ScriptContent $Global:App.EmbeddedDeleteAppScript -Name 'deleteapp' -ConfigJson ($config | ConvertTo-Json -Depth 4) -ResultPath $resultPath -Kind "Delete $name from Intune" -After @{ Kind = 'deleted'; AppName = $a.appName }
    if ($started.ok) { Write-Log "[INFO] Deleting $name from Intune..." }
    return $started
}

function Global:Clear-WebAppIds {
    <#
      Clears the App ID of several apps at once - after copying a catalog
      from another tenant, every App ID points at apps this tenant doesn't
      have. Intune isn't touched. Under the catalog lock (route table).
    #>
    param($Data)
    $names = @($Data.names | ForEach-Object { [string]$_ } | Where-Object { $_ } | Select-Object -Unique)
    if ($names.Count -eq 0) { return @{ ok = $false; error = 'Choose one or more apps first.' } }
    $cleared = New-Object System.Collections.Generic.List[string]
    $failed = New-Object System.Collections.Generic.List[string]
    $undo = New-WebUndo "Clear $($names.Count) App ID$(if ($names.Count -ne 1) { 's' })"
    # Supersedence pointing at apps this tenant doesn't have came along with the copy too - dropped with the App IDs.
    $t = Get-WebIntuneApps @{}
    $tenantIds = $null
    if ($t.ok) { $tenantIds = @{}; foreach ($i in @($t.ids)) { $tenantIds[[string]$i] = $true } }
    foreach ($n in $names) {
        try {
            [void](Update-WebCatalogApp -Name $n -Change {
                    param($a)
                    $a.appId = ''; $a.intuneAppType = ''; $a.intuneAppVersion = ''
                    # Its pilot and superseded releases are the other tenant's apps too.
                    $a.releases = @()
                    if ($tenantIds -and $a.metadata -and $null -ne $a.metadata.supersedes) {
                        $keep = @(@($a.metadata.supersedes) | Where-Object { $_ -and $tenantIds.ContainsKey(([string]$_.appId).ToLowerInvariant()) })
                        if ($keep.Count -ne @($a.metadata.supersedes).Count) { $a.metadata.supersedes = $(if ($keep.Count) { $keep } else { $null }) }
                    }
                } -Undo $undo)
            $cleared.Add($n)
        }
        catch { $failed.Add("$n`: $($_.Exception.Message)") }
    }
    Save-WebUndo $undo
    $Global:App.IntuneAppsCache = $null
    Write-Log "[OK] Cleared the App ID of $(Format-Count ($cleared.Count) 'app') in the catalog (Intune unchanged).$(if ($failed.Count) { " Failed: $($failed -join '; ')" })"
    return @{ ok = ($failed.Count -eq 0); cleared = $cleared.ToArray(); failed = $failed.ToArray(); error = $(if ($failed.Count) { "Not cleared: $($failed -join '; ')" } else { '' }) }
}

function Global:Clear-WebAppId {
    # Forgets the Intune link in the catalog (App ID, Intune's type and version). Intune isn't touched.
    param($Data)
    $name = [string]$Data.name
    try { [void](Update-WebCatalogApp -Name $name -Change { param($a) $a.appId = ''; $a.intuneAppType = ''; $a.intuneAppVersion = '' }) }
    catch { return @{ ok = $false; error = $_.Exception.Message } }
    Write-Log "[OK] Cleared $name's App ID in the catalog."
    return @{ ok = $true }
}

function Global:Get-WebInstallStatus {
    # Every device's install state for one app, from Intune's install status report.
    param($Data)
    $catalog = Read-WebCatalogRecords
    $name = [string]$Data.name
    $a = $catalog.Apps | Where-Object { $_.appName -eq $name } | Select-Object -First 1
    if (-not $a -or -not $a.appId) { return @{ ok = $false; error = "$name isn't in Intune (no App ID)." } }
    $id = [string]$a.appId
    $read = Invoke-WebGraph -Permission 'DeviceManagementApps.ReadWrite.All' -Action { param($Graph) Get-AppInstallStatusRows -AppId $id -Invoke $Graph }
    if (-not $read.ok) { return $read }
    $report = $read.value
    $rows = @($report.Rows | ForEach-Object {
        $why = Get-InstallErrorInfo $_.ErrorCode
        [ordered]@{ device = [string]$_.DeviceName; user = [string]$_.UserName; state = [string]$_.State; detail = [string]$_.Detail; error = [string]$_.ErrorCode; version = [string]$_.Version; lastSeen = [string]$_.LastSeen
            meaning = $(if ($why) { [string]$why.meaning } else { '' }); fix = $(if ($why) { [string]$why.fix } else { '' }) } })
    # 2.38.9: who its groups target but the report doesn't list yet - "Waiting for report" rows, so a fresh assignment
    # shows who's coming instead of an empty table. Never fails the report: a group that can't be read is a note.
    # A cut-off report (5000 rows) misses devices that did report: then "waiting" would be wrong - left out, with a note.
    $exp = if ($report.Truncated) { @{ Members = @(); Notes = @("The report has more than $(@($report.Rows).Count) rows and was cut off - devices waiting for their first report aren't listed.") } } else { Get-WebExpectedInstallMembers -App $a }
    # During an update (2.38.44): what the version before has on each device - the new release's report lists a device
    # only once it tried the update, so one still on the old version showed as just "Waiting for report".
    $before = @{}; $beforeVersion = ''
    $prev = @(Get-WebPreviousReleases $a) | Select-Object -Last 1
    if ($prev -and $prev.appId) {
        $prevId = [string]$prev.appId; $beforeVersion = [string]$prev.version
        $pr = Invoke-WebGraph -Permission 'DeviceManagementApps.ReadWrite.All' -Action { param($Graph) Get-AppInstallStatusRows -AppId $prevId -Invoke $Graph }.GetNewClosure()
        if ($pr.ok) { foreach ($r in @($pr.value.Rows)) { if ($r.DeviceName -and [string]$r.State -eq 'Installed') { $before[([string]$r.DeviceName).ToLowerInvariant()] = $true } } }
    }
    $waiting = @(Get-ExpectedInstallRows -ReportRows @($report.Rows) -Members @($exp.Members) | ForEach-Object {
        $dev = if ($_.Kind -eq 'device') { [string]$_.Name } else { '' }
        $old = $dev -and $before.ContainsKey($dev.ToLowerInvariant())
        [ordered]@{ device = $dev; user = $(if ($_.Kind -eq 'user') { $(if ($_.Upn) { $_.Upn } else { $_.Name }) } else { '' })
            state = $(if ($old) { "Has $beforeVersion" } else { 'Waiting for report' })
            detail = "In $(@($_.Groups) -join ', ')$(if ($old) { " - $beforeVersion is installed; it is updated when the device checks in (Company Portal > Sync speeds it up)" })"
            error = ''; version = $(if ($old) { $beforeVersion } else { '' }); lastSeen = ''; meaning = ''; fix = ''; waiting = $true; previous = [bool]$old } })
    return @{ ok = $true; app = $name; rows = @($rows) + @($waiting); waiting = $waiting.Count; onPrevious = @($waiting | Where-Object { $_.previous }).Count; previousVersion = $beforeVersion; truncated = [bool]$report.Truncated; summary = (Format-InstallStatusSummary @($report.Rows))
        targetNotes = @($exp.Notes)
        # The most common errors, explained - what to fix first.
        topErrors = @(Get-InstallErrorTop -Rows @($report.Rows) -Top 5) }
}

function Global:Get-WebExpectedInstallMembers {
    <#
      The members (nested too) of the app's Required and Available groups, without those of its excluded groups:
      @{ Members = @(@{ Kind; Name; Upn; Group; Intent }); Notes = @(...) }. All users / All devices aren't listed -
      a note says so. Up to 999 members a group (one page) - a bigger group is named in a note.
    #>
    param($App)
    $notes = New-Object System.Collections.Generic.List[string]
    $members = New-Object System.Collections.Generic.List[object]
    $want = New-Object System.Collections.Generic.List[object]
    foreach ($pair in @(@{ Intent = 'Required'; Names = @($App.requiredFor) }, @{ Intent = 'Available'; Names = @($App.availableFor) }, @{ Intent = 'Excluded'; Names = @($App.excludeFor) })) {
        foreach ($n in @($pair.Names | Where-Object { $_ -and ([string]$_).Trim() })) {
            $all = Get-AllTargetInfo ([string]$n)
            if ($all) { $notes.Add("$($pair.Intent): $($all.Name) - every $(if ($all.Name -eq '[All users]') { 'licensed user' } else { 'managed device' }) gets it; they aren't listed one by one."); continue }
            $want.Add(@{ Intent = $pair.Intent; Name = ([string]$n).Trim() })
        }
    }
    if (-not $want.Count) { return @{ Members = @(); Notes = $notes.ToArray() } }
    try {
        $ids = Resolve-WebGroupIds -Names @($want | ForEach-Object { $_.Name })
        if (-not $ids.ok) { $notes.Add("Its groups' members couldn't be read: $($ids.error)"); return @{ Members = @(); Notes = $notes.ToArray() } }
        # Entra ID couldn't be read at all: one note - not "isn't in Entra ID" for each group.
        if ($ids.note -and -not @($ids.ids.Keys).Count) { $notes.Add("Its groups' members couldn't be read: $($ids.note)"); return @{ Members = @(); Notes = $notes.ToArray() } }
        $excluded = @{}
        $read = Invoke-WebGraph -Permission 'Group.Read.All' -Action {
            param($Graph)
            $got = @{}
            foreach ($w in $want) {
                $gid = [string]$ids.ids[$w.Name]
                if (-not $gid) { continue }
                $page = & $Graph "https://graph.microsoft.com/v1.0/groups/$gid/transitiveMembers?`$select=id,displayName,userPrincipalName&`$top=999"
                $got["$($w.Intent)|$($w.Name)"] = @{ Items = @($page.value); More = [bool]$page.'@odata.nextLink' }
            }
            $got
        }.GetNewClosure()
        if (-not $read.ok) { $notes.Add("Its groups' members couldn't be read: $($read.error)"); return @{ Members = @(); Notes = $notes.ToArray() } }
        foreach ($w in $want) {
            $g = $read.value["$($w.Intent)|$($w.Name)"]
            if (-not $g) { $notes.Add("$($w.Intent): $($w.Name) isn't in Entra ID."); continue }
            if ($g.More) { $notes.Add($(if ($w.Intent -eq 'Excluded') { "Excluded: $($w.Name) has more than 999 members - only the first 999 are left out of the list, so some shown as waiting won't get it." } else { "$($w.Intent): $($w.Name) has more than 999 members - the first 999 are listed." })) }
            foreach ($o in @($g.Items)) {
                $type = [string]$o.'@odata.type'
                $kind = if ($type -like '*device') { 'device' } elseif ($type -like '*user') { 'user' } else { $null }
                if (-not $kind) { continue }
                if ($w.Intent -eq 'Excluded') { $excluded[[string]$o.id] = $true; continue }
                $members.Add(@{ Kind = $kind; Id = [string]$o.id; Name = [string]$o.displayName; Upn = [string]$o.userPrincipalName; Group = $w.Name; Intent = $w.Intent })
            }
        }
        return @{ Members = @($members | Where-Object { -not $excluded.ContainsKey($_.Id) }); Notes = $notes.ToArray() }
    }
    catch { $notes.Add("Its groups' members couldn't be read: $($_.Exception.Message)"); return @{ Members = @(); Notes = $notes.ToArray() } }
}

# ---------------------------------------------------------------- retiring an app
# 1. Start: every group the app was given gets it as Uninstall instead (the
#    catalog's groups move to Uninstall too, so a later Push groups or the
#    drift check doesn't install it again).
# 2. Progress: the install status report - how many devices still have it.
# 3. Finish: the app's file is archived (Backups\Retired), it is deleted
#    from Intune and removed from the catalog. Restore brings it back from
#    the archive (not in Intune, no groups - its History has them).

# ---------------------------------------------------------------- MSI line-of-business apps (2.33.0)
# Intune's MSI type can't become Win32 and never gives the .msi back. With the .msi in the app's package folder,
# Send creates a Win32 app (same groups) and the catalog follows it; the MSI app is then retired here - deleted
# from Intune, which leaves the software on the devices: the Win32 app finds it by the same MSI product code, so
# nothing is uninstalled and installed again (Microsoft's way of moving an MSI app to Win32).

function Global:Get-WebIntuneAppODataType {
    # The type Intune has for an app now (its @odata.type without the prefix) - read live, not from the catalog.
    param([string]$AppId)
    if ($AppId -notmatch '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$') { return @{ ok = $false; error = 'Not an App ID.' } }
    if (-not (Test-GraphCredentialsConfigured -Quiet)) { return @{ ok = $false; error = 'Not connected.' } }
    $r = Invoke-WebGraph -Permission 'DeviceManagementApps.ReadWrite.All' -Action { param($Graph) & $Graph "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$AppId" }.GetNewClosure()
    if (-not $r.ok) { return $r }
    return @{ ok = $true; type = ([string]$r.value.'@odata.type' -replace '^#?microsoft\.graph\.', ''); name = [string]$r.value.displayName; value = $r.value }
}

function Global:Get-WebSupersedenceWithReleases {
    # The catalog's supersedence plus the app's own earlier releases still in Intune (not the one being sent).
    # $null stays $null - "keep what Intune has" (2.38.34: it replaced supersedence set in the portal with the releases
    # alone; CreateApp keeps the existing list, the releases included). An empty list stays a list: it clears it.
    param($App, $Supersedes)
    if ($null -eq $Supersedes) { return $null }
    $own = @(@($App.releases) | Where-Object { $_ -and $_.appId -and [string]$_.appId -ne [string]$App.appId -and [string]$_.state -eq 'previous' })
    $list = @(@($Supersedes) | Where-Object { $_ })
    $have = @{}; foreach ($s in $list) { $have[([string]$s.appId).ToLowerInvariant()] = $true }
    foreach ($r in $own) { if (-not $have.ContainsKey(([string]$r.appId).ToLowerInvariant())) { $list += [pscustomobject]@{ appId = [string]$r.appId; name = "$($App.appName) $($r.version)"; type = 'update' } } }
    return , $list
}

function Global:Get-WebOfficeFromIntune {
    <#
      Microsoft 365 Apps' settings as Intune has them (2.38.23): for an app linked to Intune's own Microsoft 365 Apps,
      so switching it to "Installs from Microsoft 365" starts from the tenant's settings, not the defaults - the next
      send would otherwise overwrite them.
    #>
    param($Data)
    $a = (Read-WebCatalogRecords).Apps | Where-Object { $_.appName -eq [string]$Data.name } | Select-Object -First 1
    if (-not $a) { return @{ ok = $false; error = "No app called '$($Data.name)' in the catalog." } }
    if (-not $a.appId) { return @{ ok = $true; found = $false } }
    $ty = Get-WebIntuneAppODataType -AppId ([string]$a.appId)
    if (-not $ty.ok) { return @{ ok = $false; error = $ty.error } }
    if ($ty.type -ne 'officeSuiteApp') { return @{ ok = $true; found = $false; type = (Get-FriendlyIntuneAppType -ODataType $ty.type) } }
    return @{ ok = $true; found = $true; office = (ConvertFrom-OfficeSuiteApp $ty.value) }
}

function Global:Save-WebPulledStamps {
    <#
      After a Pull (2.38.61): the apps that took Intune's values have what Intune has - noted as sent, once for all.
      Groups only where the parts Pull doesn't read (excluded groups, the filter and its mode) are as last sent: Pull
      reads Required/Available/Uninstall only, and an exclusion changed here would otherwise never be sent.
    #>
    param([string[]]$Settings, [string[]]$Groups)
    try {
        if (@($Settings).Count) { Set-WebSentStamp -Names @($Settings) -Part 's' }
        if (@($Groups).Count) {
            $sent = Read-WebSentStamps
            $apps = @((Read-WebCatalogRecords).Apps)
            $ok = @(foreach ($n in $Groups) {
                    $a = $apps | Where-Object { $_.appName -eq $n } | Select-Object -First 1
                    if (-not $a) { continue }
                    $now = (Get-WebAppSentValues $a).g
                    $st = $sent[(Get-SafeFileNameForApp -Name $a.appName)]
                    $was = if ($st -and $st.gv) { try { $st.gv | ConvertFrom-Json } catch { $null } } else { $null }
                    $same = if ($was) { (@($was.x) -join "`n") -eq (@($now.x) -join "`n") -and [string]$was.f -eq [string]$now.f -and [string]$was.fm -eq [string]$now.fm }
                            else { -not @($now.x).Count -and -not [string]$now.f }
                    if ($same) { $n }
                })
            if ($ok.Count) { Set-WebSentStamp -Names $ok -Part 'g' }
        }
    }
    catch { Write-Log "[WARN] Couldn't note what Intune has: $($_.Exception.Message)" }
}

function Global:Get-WebOfficeDiff {
    # Microsoft 365 Apps' settings in the catalog against Intune's, in words (2.38.42): $null when they match or can't be
    # read - with -ReportFailure @{ Failed } when they couldn't be read (Pull mustn't take that as "the same").
    param($App, [switch]$ReportFailure)
    try { $o = Get-WebOfficeFromIntune @{ name = [string]$App.appName } } catch { return $(if ($ReportFailure) { @{ Failed = $true } }) }
    if (-not $o.ok -or -not $o.found) { return $(if ($ReportFailure -and -not $o.ok) { @{ Failed = $true } }) }
    # Only what differs (2.38.54) - the whole summaries were cut off before the one app that differed.
    $d = Get-OfficeSettingsDiff $App.office $o.office
    if (-not $d) { return $null }
    return @{ Local = $d.Local; Remote = $d.Remote; Office = $o.office }
}

function Global:Remove-WebReplacedLobApp {
    <#
      Retires the MSI line-of-business app a catalog app replaced as Win32: deletes it from Intune (its
      assignments go with it; the software stays on the devices), then forgets it. Only when the catalog app is
      in Intune as Win32 now, and only an app Intune still says is MSI line-of-business - checked again here.
    #>
    param($Data)
    $name = [string]$Data.name
    $a = (Read-WebCatalogRecords).Apps | Where-Object { $_.appName -eq $name } | Select-Object -First 1
    if (-not $a) { return @{ ok = $false; error = "No app called '$name' in the catalog." } }
    $old = [string]$a.lobToRetire
    if (-not $old) { return @{ ok = $false; error = "$name has no MSI app to retire." } }
    if (-not $a.appId -or [string]$a.appId -eq $old) { return @{ ok = $false; error = "$name isn't in Intune as a Win32 app yet - send it to Intune first." } }
    $ty = Get-WebIntuneAppODataType -AppId $old
    if (-not $ty.ok) {
        # Already gone from Intune (deleted there): nothing left to do but forget it.
        if ([string]$ty.error -match '(?i)not ?found|404|does not exist') { [void](Update-WebCatalogApp -Name $name -Change { param($x) $x.lobToRetire = '' }); return @{ ok = $true; gone = $true } }
        return @{ ok = $false; error = "Intune couldn't be asked about the MSI app: $($ty.error)" }
    }
    if (-not (Test-IntuneLobMsiType $ty.type)) { return @{ ok = $false; error = "The app $old is a $($ty.type) in Intune, not an MSI line-of-business app - not deleted. Clear it in Intune yourself if it should go." } }
    $del = Remove-WebIntuneAppsNewestFirst -Items @(@{ appId = $old; version = '' })
    if ($del.failed.Count) { return @{ ok = $false; error = "The MSI app couldn't be deleted from Intune: $($del.failed -join '; ')" } }
    [void](Update-WebCatalogApp -Name $name -Change { param($x) $x.lobToRetire = '' })
    $Global:App.IntuneAppsCache = $null
    Add-WebHistoryEntry -App $name -Kind 'intune' -Text "Retired the MSI line-of-business app $old ($($ty.name)) - deleted from Intune; the Win32 app $($a.appId) replaces it"
    Write-Log "[OK] $name`: the MSI line-of-business app $old is deleted from Intune - the Win32 app replaces it."
    return @{ ok = $true }
}

function Global:Get-WebRetireAppIds {
    # Every Intune app of a catalog app: the current one, then its superseded and rolled-back releases - @(@{ appId; version }), version '' for the current.
    param($App)
    $out = New-Object System.Collections.Generic.List[object]
    if ($App.appId) { $out.Add(@{ appId = [string]$App.appId; version = '' }) }
    # The MSI line-of-business app it replaced, still in Intune (2.38.0): uninstalled and deleted with it - left alone,
    # its Required groups installed the app again, and once the app was archived nothing pointed to it any more.
    if ($App.lobToRetire -and [string]$App.lobToRetire -ne [string]$App.appId) { $out.Add(@{ appId = [string]$App.lobToRetire; version = 'MSI app'; lob = $true }) }
    foreach ($r in @(@($App.releases) | Where-Object { $_ -and $_.state -in 'previous', 'rolledback', 'pilot' -and $_.appId -and [string]$_.appId -ne [string]$App.appId })) { $out.Add(@{ appId = [string]$r.appId; version = [string]$r.version }) }
    return $out.ToArray()
}

function Global:Get-WebRetireBlock {
    # Why the Uninstall step of a retirement can't start ('' when it can) - said in the dialog too (2.38.42), not only after its confirm.
    param($App, $Apps)
    $name = $App.appName
    if (@(@($App.releases) | Where-Object { $_ -and $_.state -eq 'pilot' }).Count) { return "A new version of $name is in pilot - withdraw it first (Updates)." }
    # Apps that depend on it would install it again (and Intune won't delete it while they do).
    $dependents = @(@($Apps) | Where-Object { $_.appName -ne $name -and $_.metadata -and @($_.metadata.dependencies) -contains $name } | ForEach-Object { $_.appName })
    if ($dependents.Count) { return "$($dependents -join ', ') depend$(if ($dependents.Count -eq 1) { 's' }) on $name - take it out of their dependencies (and send them to Intune) first." }
    return ''
}

function Global:Start-WebRetire {
    param($Data)
    $name = [string]$Data.name
    $all = @((Read-WebCatalogRecords).Apps)
    $a = $all | Where-Object { $_.appName -eq $name } | Select-Object -First 1
    if (-not $a) { return @{ ok = $false; error = "No app called '$name' in the catalog." } }
    if (-not $a.appId) { return @{ ok = $false; error = "$name isn't in Intune - nothing to uninstall. Remove it from the catalog instead." } }
    $block = Get-WebRetireBlock -App $a -Apps $all; if ($block) { return @{ ok = $false; error = $block } }
    $groups = @(Get-RetireGroups $a)
    if (-not $groups.Count) { return @{ ok = $false; error = "$name has no groups - nothing to uninstall. Finish the retirement to delete it from Intune." } }
    # Every version of it in Intune gets the Uninstall: devices on an older release aren't detected by the current one.
    $ids = @(Get-WebRetireAppIds $a)
    $resultPath = Join-Path $env:TEMP (".intunepkg_assign_result_" + [guid]::NewGuid().ToString('N') + ".json")
    $config = @{
        TenantId = $Global:App.GraphTenantId; ClientId = $Global:App.GraphClientId; CertificateThumbprint = $Global:App.GraphCertificateThumbprint
        Mode = 'Apply'; OutputResultPath = $resultPath
        Apps = @($ids | ForEach-Object { @{ AppName = $(if ($_.version) { "$($a.appName) $($_.version)" } else { $a.appName }); AppId = $_.appId
            RequiredGroups = @(); AvailableGroups = @(); UninstallGroups = $groups; ExcludeGroups = @($a.excludeFor); FilterName = [string]$a.assignmentFilter; FilterMode = [string]$a.assignmentFilterMode } })
    }
    $gid = Add-WebGroupIdsToConfig $config; if ($gid) { return @{ ok = $false; error = $gid } }
    $started = Start-WebStepJob -ScriptContent $Global:App.EmbeddedBatchAssignScript -Name 'batchassign' -ConfigJson ($config | ConvertTo-Json -Depth 8) -ResultPath $resultPath `
        -Kind "Retire $name - uninstall from $(Format-Count ($groups.Count) 'group')$(if ($ids.Count -gt 1) { ", $($ids.Count) versions in Intune" })" -After @{ Kind = 'retire'; AppName = $a.appName; Groups = $groups } -Apps @([string]$a.appName)
    if ($started.ok) { Write-Log "[INFO] Retiring $name - uninstalling it from: $($groups -join ', ')..." }
    return $started
}

function Global:Complete-WebRetire {
    # After the Uninstall assignments are in Intune: the catalog says so too.
    param($After)
    $groups = @($After.Groups)
    [void](Update-WebCatalogApp -Name $After.AppName -Change { param($a) $a.requiredFor = @(); $a.availableFor = @(); $a.uninstallFor = $groups; $a.retiringSince = (Get-Date).ToString('yyyy-MM-dd') }.GetNewClosure())
    Write-Log "[OK] $($After.AppName) is being retired: uninstalled from $($groups -join ', '). Finish the retirement once the devices report it gone."
    return @{ ok = $true }
}

function Global:Get-WebRetireStatus {
    # How far a retirement is: the install status report's devices that still have the app.
    param($Data)
    $name = [string]$Data.name
    $all = @((Read-WebCatalogRecords).Apps)
    $a = $all | Where-Object { $_.appName -eq $name } | Select-Object -First 1
    if (-not $a) { return @{ ok = $false; error = "No app called '$name' in the catalog." } }
    $base = [ordered]@{ ok = $true; app = $name; retiringSince = [string]$a.retiringSince; inIntune = [bool]$a.appId; groups = @(Get-RetireGroups $a); blocked = [string](Get-WebRetireBlock -App $a -Apps $all) }
    if (-not $a.appId -or -not $a.retiringSince) { return $base }
    # Every version in Intune counts - a device on an older release still has it.
    $ids = @(Get-WebRetireAppIds $a | ForEach-Object { $_.appId })
    $read = Invoke-WebGraph -Permission 'DeviceManagementApps.ReadWrite.All' -Action { param($Graph) @(foreach ($i in $ids) { @((Get-AppInstallStatusRows -AppId $i -Invoke $Graph).Rows) }) }.GetNewClosure()
    if (-not $read.ok) { $base.note = "The install status couldn't be read: $($read.error)"; return $base }
    $base.progress = Get-RetireProgress @($read.value)
    return $base
}

function Global:Get-WebRetiredFolder { return (Join-Path (Get-AppFolder -Kind Backups -Create) 'Retired') }

function Global:Complete-WebRetireFinish {
    # Deleted from Intune (or never there): archive the app's file and take it out of the catalog.
    param([string]$Name)
    $a = (Read-WebCatalogRecords).Apps | Where-Object { $_.appName -eq $Name } | Select-Object -First 1
    if (-not $a) { return @{ ok = $true } }
    # Its older versions still in Intune (superseded by the one just deleted) go too.
    $older = @(Get-WebRetireAppIds $a | Where-Object { $_.version -and $_.appId -ne [string]$a.appId })
    $leftInIntune = @()
    if ($older.Count -and (Test-GraphCredentialsConfigured -Quiet)) { $leftInIntune = @((Remove-WebIntuneAppsNewestFirst -Items $older).failed) }
    if ($leftInIntune.Count) { Write-Log "[WARN] $($a.appName): these older versions couldn't be deleted from Intune - delete them there: $($leftInIntune -join '; ')" }
    $file = Join-Path (Get-AppFolder -Kind Catalog) ((Get-SafeFileNameForApp -Name $a.appName) + '.json')
    $dir = Get-WebRetiredFolder
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $archive = Join-Path $dir ((Get-Date).ToString('yyyy-MM-dd_HHmmss') + '_' + (Split-Path $file -Leaf))
    Copy-Item -LiteralPath $file -Destination $archive -Force
    Add-WebCopyRecord $archive
    Backup-WebAppFile $file
    Remove-Item -LiteralPath $file -Force
    Add-WebHistoryEntry -App $a.appName -Kind 'catalog' -Text 'Retired: deleted from Intune, archived (Catalog > Retired apps) and removed from the catalog'
    Write-Log "[OK] Retired $($a.appName): deleted from Intune and archived to $archive."
    return @{ ok = $true; archived = (Split-Path $archive -Leaf) }
}

function Global:Remove-WebIntuneAppsNewestFirst {
    # Deletes Intune apps (@(@{ appId; version })), the newest version first - a newer one supersedes the older ones. @{ removed; failed }.
    param($Items)
    $list = @($Items)
    $sorted = New-Object System.Collections.Generic.List[object]
    foreach ($it in $list) { $i = 0; while ($i -lt $sorted.Count -and (Compare-AppVersionText ([string]$it.version) ([string]$sorted[$i].version)) -eq 1) { $i++ }; $sorted.Insert($i, $it) }
    $removed = New-Object System.Collections.Generic.List[string]; $failed = New-Object System.Collections.Generic.List[string]
    foreach ($it in $sorted) {
        $id = [string]$it.appId
        if ($id -notmatch '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$') { $failed.Add("$($it.version): not an App ID"); continue }
        $r = Invoke-WebGraph -Permission 'DeviceManagementApps.ReadWrite.All' -Action { param($Graph) [void](& $Graph "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$id" 'DELETE'); $true }.GetNewClosure()
        if ($r.ok) { $removed.Add([string]$it.version) } else { $failed.Add("$($it.version): $($r.error)") }
    }
    return @{ removed = $removed.ToArray(); failed = $failed.ToArray() }
}

function Global:Start-WebRetireFinish {
    param($Data)
    $name = [string]$Data.name
    $a = (Read-WebCatalogRecords).Apps | Where-Object { $_.appName -eq $name } | Select-Object -First 1
    if (-not $a) { return @{ ok = $false; error = "No app called '$name' in the catalog." } }
    if (-not $a.appId) { return (Invoke-WithCatalogLock { Complete-WebRetireFinish -Name $name }) }
    if (-not $a.retiringSince -and @(Get-RetireGroups $a).Count) { return @{ ok = $false; error = "Start the retirement first - its groups get it as Uninstall, so it's removed from the devices before it's deleted." } }
    # Its other versions in Intune: a newer one (rolled back from) supersedes the current one, so it goes first -
    # Intune won't delete an app another one supersedes. The older ones go after the current one (Complete-WebRetireFinish).
    $current = [string]$(if ($a.metadata) { $a.metadata.appVersion })
    $newer = @(Get-WebRetireAppIds $a | Where-Object { $_.version -and -not $_.lob -and (Compare-AppVersionText $current $_.version) -eq 1 })
    if ($newer.Count) {
        $del = Remove-WebIntuneAppsNewestFirst -Items $newer
        if ($del.failed.Count) { return @{ ok = $false; error = "These versions of $name couldn't be deleted from Intune, so the current one can't be either: $($del.failed -join '; ')" } }
    }
    $resultPath = Join-Path $env:TEMP (".intunepkg_delete_result_" + [guid]::NewGuid().ToString('N') + ".json")
    $config = @{
        TenantId = $Global:App.GraphTenantId; ClientId = $Global:App.GraphClientId; CertificateThumbprint = $Global:App.GraphCertificateThumbprint
        AppId = $a.appId; AppName = $a.appName; RemoveDependencyFromAppId = ''; OutputResultPath = $resultPath
    }
    # Shown as Being changed on every PC while it runs; a second start (a double click, another admin) is refused.
    $busy = Enter-WebAppBusy -Name $a.appName -What 'retiring it'; if ($busy) { return @{ ok = $false; error = $busy } }
    $started = Start-WebStepJob -BusyApp $a.appName -ScriptContent $Global:App.EmbeddedDeleteAppScript -Name 'deleteapp' -ConfigJson ($config | ConvertTo-Json -Depth 4) -ResultPath $resultPath -Kind "Finish retiring $name (delete from Intune)" -After @{ Kind = 'retired'; AppName = $a.appName } -Apps @([string]$a.appName)
    if ($started.ok) { Write-Log "[INFO] Finishing the retirement of $name - deleting it from Intune..." }
    return $started
}

function Global:Get-WebRetiredApps {
    # The archive of retired apps, newest first.
    $dir = Join-Path (Get-AppFolder -Kind Backups) 'Retired'
    if (-not (Test-Path -LiteralPath $dir)) { return @{ ok = $true; apps = @() } }
    $rows = @(Get-ChildItem -LiteralPath $dir -File -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}_\d{6}_.+\.json$' } | Sort-Object Name -Descending | ForEach-Object {
        $n = ''; try { $n = [string](Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json).appName } catch { }
        [ordered]@{ id = $_.Name; name = $n; retired = ($_.Name.Substring(0, 10)) }
    })
    return @{ ok = $true; apps = $rows }
}

function Global:Restore-WebRetiredApp {
    # Brings a retired app back into the catalog - not in Intune and without groups (its History has the old ones).
    param($Data)
    $id = [string]$Data.id
    if ($id -notmatch '^\d{4}-\d{2}-\d{2}_\d{6}_[^\\/:*?"<>|]+\.json$') { return @{ ok = $false; error = 'That is not a retired app.' } }
    $src = Join-Path (Get-WebRetiredFolder) $id
    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { return @{ ok = $false; error = 'That retired app is gone from the archive.' } }
    $refused = Get-WebCopyRefusal $src 'That archived app'
    if ($refused) { return @{ ok = $false; error = $refused } }
    try { $rec = ConvertTo-AppRecord (Get-Content -LiteralPath $src -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return @{ ok = $false; error = "It can't be read: $($_.Exception.Message)" } }
    $catalog = Read-WebCatalogRecords
    if (@($catalog.Apps | Where-Object { $_.appName -eq $rec.appName }).Count) { return @{ ok = $false; error = "An app called '$($rec.appName)' is in the catalog already." } }
    $rec.appId = ''; $rec.intuneAppType = ''; $rec.intuneAppVersion = ''; $rec.retiringSince = ''; $rec.releases = @()
    $rec.requiredFor = @(); $rec.availableFor = @(); $rec.uninstallFor = @()
    $problem = Test-WebAppEdit -Record $rec -OriginalName '' -Others @($catalog.Apps)
    if ($problem) { return @{ ok = $false; error = "It can't be restored: $problem" } }
    $file = Join-Path (Get-AppFolder -Kind Catalog -Create) ((Get-SafeFileNameForApp -Name $rec.appName) + '.json')
    if (Test-Path -LiteralPath $file) { return @{ ok = $false; error = "A catalog file for '$($rec.appName)' exists already." } }
    Save-WebAppJson -File $file -App $rec -Text 'Restored from the retired apps (not in Intune, no groups - see earlier entries for them)'
    Write-Log "[OK] Restored $($rec.appName) from the retired apps - set its groups and send it to Intune to use it again."
    return @{ ok = $true; name = $rec.appName }
}
