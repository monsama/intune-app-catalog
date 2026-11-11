function Global:Get-GraphPermissionHint {
    <#
      Which application permission a refused request most likely needs.
      "Forbidden" on its own never says which one.

      Graph often names the scopes in the response body ("Application must
      have one of the following scopes: X, Y"), and what it says beats
      anything worked out from the address, so that is read first. The
      address is the fallback for a refusal that explains nothing. $null
      when the text names no endpoint this app knows.
    #>
    param([string]$Text)
    if (-not $Text) { return $null }
    if ($Text -match '(?:following scopes|scopes required|requires the scopes?)\s*:?\s*([A-Za-z0-9_.]+(?:\.All)?(?:\s*,\s*[A-Za-z0-9_.]+)*)') {
        $named = @($Matches[1] -split '\s*,\s*' | Where-Object { $_ -match '\.' } | Select-Object -Unique)
        if ($named.Count) { return "$($named -join ' or ') (application)" }
    }
    if ($Text -match 'deviceManagementScripts|deviceHealthScripts') { return "DeviceManagementScripts.ReadWrite.All (application)" }
    if ($Text -match 'deviceManagement/reports')                    { return "DeviceManagementApps.Read.All (application)" }
    if ($Text -match 'deviceAppManagement|mobileApps')              { return "DeviceManagementApps.ReadWrite.All (application)" }
    if ($Text -match 'graph\.microsoft\.com/(v1\.0|beta)/(groups|users|directoryObjects)') { return "Group.Read.All and Directory.Read.All (application)" }
    if ($Text -match 'deviceManagement')                            { return "DeviceManagementConfiguration.ReadWrite.All (application)" }
    return $null
}

function Global:ConvertTo-FriendlyGraphError {
    # Recognizes a handful of common, recurring Connect-MgGraph/Graph SDK
    # failure shapes and puts the actual takeaway first, in plain words -
    # the raw exception (confirmed live: "ClientCertificateCredential
    # authentication failed: [At line:35 char:16 + ... ]") reads like an
    # internal parse error to anyone who isn't already familiar with this
    # app's own runspace plumbing, and gives no hint the real fix is back
    # in Settings. The original text is always kept, appended below the
    # plain-language summary, so a genuinely unfamiliar failure is still
    # fully diagnosable - this only adds context, never hides detail.
    param([string]$RawMessage)
    if (-not $RawMessage) { return $RawMessage }
    # Idempotent: a fetch converts its own message, and the dialog showing it
    # converts again. Without this the second pass wraps the first one's
    # summary and the reader gets the same sentence twice, nested.
    if ($RawMessage -like '*(Raw error:*') { return $RawMessage }
    $summary = $null
    if (Test-GraphAssemblyConflictText $RawMessage) {
        $summary = "PowerShell module conflict: another module in this window (often Az, ExchangeOnlineManagement or an older Microsoft.Graph, loaded by the PowerShell profile) brought different versions of the libraries Microsoft Graph needs. Nothing in Settings or the tenant is wrong - restart the app without the profile: powershell -NoProfile -ExecutionPolicy Bypass -File .\IntuneDeployment.ps1"
    }
    elseif ($RawMessage -match "Certificate with thumbprint '?[0-9A-Fa-f]+'? was not found|Cannot find the certificate|certificate.*not found|No certificate found|No certificate with thumbprint") {
        $summary = "The certificate in Settings isn't on this machine any more (or has expired) - it may have been replaced or deleted since Settings was last saved. Pick or generate one in Settings, make sure it's uploaded to the app registration in Entra (Certificate tab), Test connection, and Save once it succeeds."
    }
    elseif ($RawMessage -match 'ClientCertificateCredential authentication failed') {
        $summary = "Entra ID didn't accept the certificate sign-in. Usually this certificate isn't uploaded to the app registration yet (Settings > Certificate > Check certificates in Entra / Upload certificate; allow a few minutes after uploading), or Windows won't hand out its private key. Also check Tenant ID and Client ID."
    }
    elseif ($RawMessage -match 'AADSTS700027|invalid_client|AADSTS70021') {
        $summary = "Microsoft Entra ID rejected this app's credentials. Double-check the Tenant ID, Client ID, and certificate in Settings."
    }
    elseif ($RawMessage -match '\bunauthorized\b|\b401\b') {
        # Intune answers a missing permission with 401 (and "Forbidden" in
        # the body), not 403 - so this is usually a permission, and the
        # reader needs to be told which.
        $permission = Get-GraphPermissionHint $RawMessage
        $add = if ($permission) { "add $permission" } else { "add the permission it needs" }
        $summary = "Microsoft Graph refused this request (401 Unauthorized). Usually the app registration is missing a permission - $add and grant admin consent. If you've only just granted it, run Settings > Test connection again: that refreshes the sign-in, which may still be from before."
    }
    elseif ($RawMessage -match '\bforbidden\b|\b403\b|insufficient privileges|Authorization_RequestDenied') {
        $permission = Get-GraphPermissionHint $RawMessage
        $summary = if ($permission) {
            "Microsoft Graph refused this request: the app registration is missing a permission. Add $permission to it and grant admin consent, then try again (Settings > First time? Setup guide... walks through it)."
        } else {
            "Microsoft Graph refused this request - the app registration is likely missing a required permission (see Settings > First time? Setup guide...)."
        }
    }
    if (-not $summary) { return $RawMessage }
    return "$summary`n`n(Raw error: $RawMessage)"
}

function Global:Get-GroupDeletionPlan {
    <#
      What deleting these groups would cost, one row per group:
      @{ Name; UsedBy = <catalog app names>; }. -UsedByLookup does the
      catalog side (Get-CatalogAppsUsingGroup by default) so this is
      testable without a catalog.

      Rows come back in the order given, duplicates and blanks dropped -
      a list built from a checked list can contain neither, but a list
      built from anything else can.
    #>
    param([string[]]$GroupNames, [scriptblock]$UsedByLookup)
    if (-not $UsedByLookup) { $UsedByLookup = { param($Name) @(Get-CatalogAppsUsingGroup -GroupName $Name) } }
    $rows = New-Object System.Collections.Generic.List[object]
    $seen = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @($GroupNames)) {
        $trimmed = ([string]$name).Trim()
        if (-not $trimmed) { continue }
        if (-not $seen.Add($trimmed)) { continue }
        $rows.Add(@{ Name = $trimmed; UsedBy = @(& $UsedByLookup $trimmed) })
    }
    return $rows.ToArray()
}

function Global:Format-GroupDeletionWarning {
    <#
      The sentence above the confirmation box. Deleting a group the catalog
      still assigns apps to breaks those assignments silently - the catalog
      keeps the name and the next push fails - so the apps affected are
      named rather than counted.
    #>
    param($Plan)
    $rows = @($Plan)
    if ($rows.Count -eq 0) { return "Nothing is selected." }
    $inUse = @($rows | Where-Object { @($_.UsedBy).Count -gt 0 })
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Permanently delete $($rows.Count) group(s) from Entra ID. This can't be undone.")
    if ($inUse.Count -eq 0) {
        $lines.Add("No app in this catalog uses any of them.")
    }
    else {
        $lines.Add("$($inUse.Count) of them are still used by apps in this catalog, whose assignments will break:")
        foreach ($row in ($inUse | Select-Object -First 8)) {
            $apps = @($row.UsedBy)
            $shown = ($apps | Select-Object -First 5) -join ', '
            if ($apps.Count -gt 5) { $shown = "$shown, +$($apps.Count - 5) more" }
            $lines.Add("  $($row.Name) - $shown")
        }
        if ($inUse.Count -gt 8) { $lines.Add("  ...and $($inUse.Count - 8) more.") }
    }
    return ($lines -join "`r`n")
}

function Global:ConvertTo-DisplayLineEndings {
    # WinForms Multiline TextBox/RichTextBox controls only ever render a
    # bare `n as a line break inconsistently - they need real `r`n. This
    # repo's own source files use LF-only line endings, so any here-string
    # template (like the winget detection script below) carries bare `n
    # when read into a string - fine to execute as a script, but it shows
    # up as one giant run-on line if put straight into a TextBox.Text.
    # Idempotent: an already-CRLF string round-trips unchanged.
    param([string]$Text)
    if (-not $Text) { return $Text }
    return ($Text -replace "`r?`n", "`r`n")
}

function Global:ConvertTo-CanonicalLineEndings {
    # The inverse of ConvertTo-DisplayLineEndings, for the other direction
    # of the same round trip - reading a detection script back OUT of a
    # TextBox (now `r`n, after display normalization) to save it to the
    # catalog or upload it to Intune. Without this, a detection script
    # that was only ever VIEWED (not edited - e.g. just opening an
    # existing app to change an unrelated field like Architecture) would
    # get written back with `r`n even though the original catalog file
    # and whatever's already live in Intune both still have the original
    # bare `n - a byte-for-byte difference with no real content change
    # behind it, but enough to make the next metadata-drift check flag
    # "Detection rule" as differing (confirmed live) and needlessly dirty
    # the catalog file's own git diff. Normalizing back to `n here - not
    # leaving it as `r`n - matches this repo's own LF convention and
    # keeps re-saves of an unedited script byte-identical to before.
    param([string]$Text)
    if (-not $Text) { return $Text }
    return ($Text -replace "`r`n", "`n")
}

# Names of the catalog apps that have a group in Required, Available or
# Uninstall - shown before a group is deleted or renamed.
function Global:Get-CatalogAppsUsingGroup {
    param([string]$GroupName)
    @($Global:App.Apps | Where-Object {
        (@($_.requiredFor) + @($_.availableFor) + @($_.uninstallFor)) -contains $GroupName
    } | ForEach-Object { [string]$_.appName })
}

function Global:Get-CatalogRow {
    <#
      One catalog app as a list row: Type, Version, Custom Config, Groups,
      Status, Last Audit and the flags the filters ask - the Apps list
      (Get-WebCatalog).
      -PackageIndex: Get-PackageFolderIndex, built once per list.
    #>
    param($App, [int]$Index, $PackageIndex)
    $app = $App
    $isUncommon = Test-AppIsUncommon -App $app
    # A blank Winget ID alone (what Test-AppIsUncommon actually checks)
    # doesn't distinguish "an uncommon WIN32 app that genuinely needs
    # its own .intunewin built" from "a non-Win32 app type (Company
    # Portal - Microsoft Store app (new), Microsoft 365 Apps, ...) that
    # never needs a package from this tool at all" - this app only ever
    # PACKAGES/DEPLOYS win32LobApp objects, so an app already known
    # (from a prior sync) to be some other Intune type was showing a
    # permanent, unfixable "Package missing" for something that isn't
    # actually missing - there was never going to be a package for it.
    # Same "Windows app (Win32)" friendly-label check already used
    # elsewhere (Get-FriendlyIntuneAppType collapses win32LobApp/
    # win32CatalogApp/windowsMobileMSI to this one string) - blank
    # intuneAppType (never synced, or genuinely not deployed yet) still
    # falls through to the normal uncommon/package check below, since
    # that's the only case where a real package IS actually expected.
    $isKnownNonWin32 = $app.intuneAppType -and $app.intuneAppType -ne "Windows app (Win32)"
    # A stored packagePath counts too, Winget ID or not. "Has a Winget
    # ID" normally means "deploys with the shared init.intunewin", so
    # this column ignored those apps entirely - which made a custom
    # package pointed at from the editor look like it had not been
    # saved, because nothing here ever asked about it.
    $needsPackageCheck = ($isUncommon -or $app.packagePath) -and -not $isKnownNonWin32
    # Only for the Status warning below - where the package is lives in
    # the app editor now (Package location), not in a column here.
    $pkg = if ($needsPackageCheck) { Resolve-AppPackagePath -AppName $app.appName -Uncommon $isUncommon -Index $PackageIndex -PackagePath $app.packagePath } else { $null }

    # For the Custom Config column only. Status used to repeat it as a
    # note, which said the same thing twice on one row.
    $hasCustomConfig = Test-AppHasCustomConfig -App $app

    $status = ""
    if (-not $app.appId) {
        $status = if ($app.metadata) { "Metadata saved - ready to deploy" } else { "No App ID" }
    }
    elseif ($needsPackageCheck -and -not $pkg.Found) {
        $status = "Package missing"
    }

    # An app that plainly has a Winget ID but was pointed at its own
    # .intunewin installs from that, not from the shared winget
    # wrapper - nothing else on the row says so. Only worth saying for
    # an app that WOULD otherwise use the wrapper: an app with no
    # Winget ID has its own package by definition, and its empty
    # Winget ID cell already shows that.
    if ($app.packagePath -and -not $isUncommon) {
        $status = if ($status) { "$status; Custom package" } else { "Custom package" }
    }

    $reqCount = @($app.requiredFor).Count
    $availCount = @($app.availableFor).Count
    $uninstCount = @($app.uninstallFor).Count
    return [pscustomobject]@{
        AppName   = $app.appName
        WingetId  = $app.wingetId
        Type      = if ($app.intuneAppType) { $app.intuneAppType } else { "" }
        Version   = if ($app.intuneAppVersion) { $app.intuneAppVersion } else { "" }
        # Blank (not "Yes") for an app with no Winget ID:
        # Test-AppHasCustomConfig returns true for every such app
        # unconditionally (there's no computed default for it to have
        # deviated FROM), so "Yes" there would say nothing. Left meaning
        # one specific thing everywhere it's shown: a Winget app whose
        # saved settings were hand-edited away from what this tool
        # would otherwise default it to.
        CustomConfig = if ($isUncommon) { "" } elseif ($hasCustomConfig) { "Yes" } else { "No" }
        Groups    = "$reqCount / $availCount / $uninstCount"
        # Not columns - what sorting the Groups column orders by.
        Required  = $reqCount
        Available = $availCount
        Uninstall = $uninstCount
        Status    = $status
        IntuneAudit = if ($app.appId) { Get-LastAuditSummary -AppName $app.appName } else { "" }
        # Not columns - what the "Not deployed" and "Package missing"
        # filters ask. The second is its own flag because Status only
        # says "Package missing" once an app has an App ID; before
        # that it says "No App ID", and the package is just as missing.
        HasAppId  = [bool]$app.appId
        PackageMissing = [bool]($needsPackageCheck -and -not $pkg.Found)
        Index     = $Index
    }
}

