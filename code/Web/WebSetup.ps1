# Intune App Catalog & Deployment
# Copyright (C) 2026 Viktor Ljuca <https://monsama.ch>
# SPDX-License-Identifier: GPL-2.0-or-later

<#
.SYNOPSIS
    The web interface's setup and help: Diagnostics, the prerequisites
    (the Graph module), and certificates on this machine.
#>

function Global:Get-WebDiagnostics {
    # One report: this machine's setup, the catalog itself, and how it lines up with Intune.
    $sections = New-Object System.Collections.Generic.List[object]
    $line = { param([string]$Level, [string]$Text, $Items = @()) [ordered]@{ level = $Level; text = $Text; items = @($Items | ForEach-Object { [string]$_ }) } }

    $setup = New-Object System.Collections.Generic.List[object]
    $moduleOk = [bool](Test-GraphModuleHere)
    $setup.Add((& $line $(if ($moduleOk) { 'ok' } else { 'failed' }) "Microsoft.Graph.Authentication module in this PowerShell $(if ($moduleOk) { 'installed' } else { "is missing - Settings > Prerequisites installs it" })"))
    $credsOk = [bool](Test-GraphCredentialsConfigured -Quiet)
    $setup.Add((& $line $(if ($credsOk) { 'ok' } else { 'failed' }) "Tenant ID, Client ID and certificate thumbprint $(if ($credsOk) { 'filled in' } else { 'not all filled in (Settings > Connection)' })"))
    if ($credsOk) {
        $cert = Get-CertificateStatusText -Thumbprint $Global:App.GraphCertificateThumbprint
        $lvl = switch ([string]$cert.Level) { 'ok' { 'ok' } 'warn' { 'warn' } default { 'failed' } }
        $setup.Add((& $line $lvl "Certificate: $($cert.Text)"))
    }
    $sections.Add([ordered]@{ title = 'This machine'; lines = $setup.ToArray() })

    $catalog = Read-WebCatalogRecords
    $apps = @($catalog.Apps)
    $pkgRoot = Get-AppFolder -Kind Packages
    $folders = @(if (Test-Path -LiteralPath $pkgRoot) { Get-ChildItem -LiteralPath $pkgRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object { @{ Name = $_.Name; FullName = $_.FullName } } })
    $cat = @(Get-CatalogDiagnosticLines -Apps $apps -PackageFolders $folders | ForEach-Object { & $line $_.Level $_.Text $_.Items })
    if (@($catalog.Failed).Count) { $cat = @(& $line 'failed' "$(@($catalog.Failed).Count) catalog file(s) couldn't be read" @($catalog.Failed)) + $cat }
    $sections.Add([ordered]@{ title = "Catalog ($($apps.Count) app(s))"; lines = $cat })

    $live = New-Object System.Collections.Generic.List[object]
    if (-not $credsOk -or -not $moduleOk) { $live.Add((& $line 'info' 'Skipped - the connection isn''t set up.')) }
    else {
        $read = Invoke-WebGraph -Permission 'DeviceManagementApps.ReadWrite.All' -Action {
            param($Graph)
            $items = New-Object System.Collections.Generic.List[object]
            $uri = 'https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?$select=id,displayName&$top=999'
            while ($uri) { $page = & $Graph $uri; foreach ($v in @($page.value)) { $items.Add([pscustomobject]@{ id = [string]$v.id; displayName = [string]$v.displayName }) }; $uri = [string]$page.'@odata.nextLink' }
            , $items.ToArray()
        }
        if (-not $read.ok) { $live.Add((& $line 'failed' "Couldn't read Intune: $($read.error)")) }
        else {
            $intune = @($read.value)
            $live.Add((& $line 'ok' "Connected - $($intune.Count) app(s) in Intune"))
            $f = @(Get-IntuneLinkFindings -Apps $apps -IntuneApps $intune)
            $by = { param($a) @($f | Where-Object { @($_.Actions) -contains $a }) }
            $gone = & $by 'ClearAppId'; $renamed = & $by 'RenameFromIntune'; $missing = & $by 'AddToCatalog'
            $unlinked = @($f | Where-Object { @($_.Actions) -contains 'ChooseAppId' -or @($_.Actions) -contains 'SetAppId' })
            $live.Add((& $line $(if ($gone.Count) { 'failed' } else { 'ok' }) "$($gone.Count) app(s) whose App ID no longer exists in Intune" @($gone | ForEach-Object { $_.App })))
            $live.Add((& $line $(if ($renamed.Count) { 'warn' } else { 'ok' }) "$($renamed.Count) app(s) renamed in Intune since" @($renamed | ForEach-Object { $_.App })))
            $live.Add((& $line $(if ($unlinked.Count) { 'warn' } else { 'ok' }) "$($unlinked.Count) app(s) not linked to the Intune app of the same name" @($unlinked | ForEach-Object { $_.App })))
            $live.Add((& $line $(if ($missing.Count) { 'info' } else { 'ok' }) "$($missing.Count) app(s) in Intune that aren't in the catalog - Checks can add them"))
            $live.Add((& $line 'info' 'The API permissions are checked by Settings > Connection > Test connection; every difference in detail by Checks.'))
        }
    }
    $sections.Add([ordered]@{ title = 'Intune'; lines = $live.ToArray() })
    Write-Log '[INFO] Diagnostics run.'
    return @{ ok = $true; sections = $sections.ToArray() }
}

function Global:Get-WebPrerequisites {
    # The Graph module in each PowerShell this app uses (a few seconds: Windows PowerShell is asked separately).
    $rows = @(Get-GraphModuleStatus | ForEach-Object { [ordered]@{ name = [string]$_.Name; version = [string]$_.Version; problem = [string]$_.Problem; exe = [string]$_.Exe } })
    return @{ ok = $true; module = (Get-GraphModuleName); rows = $rows; allInstalled = (@($rows | Where-Object { -not $_.version }).Count -eq 0) }
}

function Global:Start-WebPrerequisiteInstall {
    <#
      Installs the module, for the user only, into one PowerShell that's
      missing it - the page installs them one after another. -exe must be
      one of the PowerShells Get-GraphModuleStatus lists.
    #>
    param($Data)
    $exe = [string]$Data.exe
    $known = @(Get-GraphModuleStatus | Where-Object { -not $_.Version } | ForEach-Object { [string]$_.Exe })
    if ($known -notcontains $exe) { return @{ ok = $false; error = 'Nothing to install there.' } }
    $Global:App.GraphModuleHereConfirmed = $false
    return (Start-WebStepJob -ScriptContent (Get-GraphModuleInstallScript) -Name 'prereq' -ConfigJson '' -ResultPath '' -Parameters @{} -Exe $exe -Kind "Install $(Get-GraphModuleName)")
}

function Global:Get-WebAllLocalCertificates {
    # Every certificate in CurrentUser\My and LocalMachine\My, for Delete local certificate - expired and keyless ones too.
    $now = Get-Date
    $inUse = ([string]$Global:App.GraphCertificateThumbprint) -replace '\s', ''
    $list = foreach ($store in 'CurrentUser', 'LocalMachine') {
        Get-ChildItem -Path "Cert:\$store\My" -ErrorAction SilentlyContinue | ForEach-Object {
            [ordered]@{ subject = $_.Subject; thumbprint = $_.Thumbprint; notAfter = $_.NotAfter.ToString('yyyy-MM-dd'); store = $store
                expired = ($_.NotAfter -lt $now); hasKey = [bool]$_.HasPrivateKey; inUse = ($inUse -and $_.Thumbprint -eq $inUse) }
        }
    }
    return @{ ok = $true; certificates = @($list) }
}

function Global:Remove-WebLocalCertificate {
    # Deletes one certificate, private key included, from this machine. Entra ID keeps its copy.
    param($Data)
    $thumb = ([string]$Data.thumbprint) -replace '\s', ''
    $store = [string]$Data.store
    if ($thumb -notmatch '^[0-9A-Fa-f]{40}$') { return @{ ok = $false; error = 'That is not a certificate thumbprint.' } }
    if ($store -notin 'CurrentUser', 'LocalMachine') { return @{ ok = $false; error = 'Unknown certificate store.' } }
    $path = "Cert:\$store\My\$thumb"
    if (-not (Test-Path -LiteralPath $path)) { return @{ ok = $false; error = "No certificate $thumb in $store\My." } }
    try { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
    catch {
        $hint = if ($store -eq 'LocalMachine') { ' Deleting from LocalMachine\My usually needs the app started as administrator.' } else { '' }
        return @{ ok = $false; error = "Couldn't delete it: $($_.Exception.Message)$hint" }
    }
    Write-Log "[OK] Certificate $thumb deleted from $store\My (Entra ID keeps its copy)."
    return @{ ok = $true }
}
