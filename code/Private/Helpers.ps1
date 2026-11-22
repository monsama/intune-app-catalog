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
        $summary = "PowerShell module conflict: another module in the PowerShell running the app (often Az, ExchangeOnlineManagement or an older Microsoft.Graph, loaded by the PowerShell profile) brought different versions of the libraries Microsoft Graph needs. Nothing in Settings or the tenant is wrong - restart the app without the profile: powershell -NoProfile -ExecutionPolicy Bypass -File .\IntuneDeployment.ps1"
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
            "Microsoft Graph refused this request: the app registration is missing a permission. Add $permission to it and grant admin consent, then try again (Settings > Connection, In Entra ID: Add required permissions... (on the server: Entra setup script...) adds it)."
        } else {
            "Microsoft Graph refused this request - the app registration is likely missing a required permission (Settings > Connection, In Entra ID, adds them: Add required permissions..., or on the server the Entra setup script)."
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
    # Windows multi-line text boxes only ever render a
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
    # An MSI line-of-business app needs a package too: it is moved to Win32 when it's sent (2.33.0).
    $isKnownNonWin32 = $app.intuneAppType -and -not (Test-PackagedIntuneAppType ([string]$app.intuneAppType))
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

function Global:Protect-LogText {
    <#
      Pure: the text with anything shaped like a secret blanked out, before
      it reaches the Activity log, the log file or the page. A second line
      of defence - the steps already avoid writing these:
        - a signed URL's signature (sig=...), e.g. an Azure Storage upload address
        - "Bearer <token>" and any JSON Web Token (eyJ...eyJ...)
        - client_secret= / password= / access_token= values
    #>
    param([string]$Text)
    if (-not $Text) { return $Text }
    $t = $Text -replace '(?i)([?&]sig=)[^&\s"''<>]+', '$1[hidden]'
    $t = $t -replace '(?i)\b(Bearer)\s+[A-Za-z0-9\-._~+/]+=*', '$1 [hidden]'
    $t = $t -replace '\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*', '[token hidden]'
    $t = $t -replace '(?i)\b(client_secret|password|access_token|refresh_token)(["'']?\s*[=:]\s*["'']?)[^&\s"'',;]+', '$1$2[hidden]'
    return $t
}

function Global:Get-GroupLookupUris {
    <#
      Pure: Graph addresses that look up groups by exact name, -ChunkSize
      names per request (displayName in ('a','b',...)) - the names escaped
      for OData (' doubled) and the filter for the URL.
    #>
    param([string[]]$Names, [int]$ChunkSize = 15)
    $list = @($Names | Where-Object { $_ })
    for ($i = 0; $i -lt $list.Count; $i += $ChunkSize) {
        $chunk = @($list[$i..([Math]::Min($i + $ChunkSize, $list.Count) - 1)])
        $inList = ($chunk | ForEach-Object { "'" + ([string]$_).Replace("'", "''") + "'" }) -join ','
        "https://graph.microsoft.com/v1.0/groups?`$filter=$([Uri]::EscapeDataString("displayName in ($inList)"))&`$select=id,displayName&`$top=999"
    }
}

function Global:Get-AppWindowPreferencesJson {
    <#
      Pure: the app window's browser profile settings (its own profile, never
      the person's normal browser) with translation, the password manager,
      autofill, spelling correction and sync prompts switched off - merged into what the browser
      already keeps in that profile's Preferences file (-Existing, '' for none).
      Chromium and Edge read these keys at start.
    #>
    param([string]$Existing)
    $prefs = $null
    if ($Existing) { try { $prefs = $Existing | ConvertFrom-Json } catch { $prefs = $null } }
    if ($null -eq $prefs -or $prefs -isnot [System.Management.Automation.PSCustomObject]) { $prefs = [pscustomobject]@{} }
    $set = {
        param($Object, [string[]]$Path, $Value)
        $node = $Object
        for ($i = 0; $i -lt $Path.Count - 1; $i++) {
            $child = $node.PSObject.Properties[$Path[$i]]
            if (-not $child -or $child.Value -isnot [System.Management.Automation.PSCustomObject]) {
                if ($child) { $node.PSObject.Properties.Remove($Path[$i]) }
                $node | Add-Member -NotePropertyName $Path[$i] -NotePropertyValue ([pscustomobject]@{})
            }
            $node = $node.PSObject.Properties[$Path[$i]].Value
        }
        $leaf = $Path[$Path.Count - 1]
        if ($node.PSObject.Properties[$leaf]) { $node.$leaf = $Value } else { $node | Add-Member -NotePropertyName $leaf -NotePropertyValue $Value }
    }
    & $set $prefs @('translate', 'enabled') $false                 # no "translate this page?"
    & $set $prefs @('credentials_enable_service') $false           # no password manager
    & $set $prefs @('profile', 'password_manager_enabled') $false
    & $set $prefs @('autofill', 'enabled') $false                  # no address / card / form autofill
    & $set $prefs @('autofill', 'profile_enabled') $false
    & $set $prefs @('autofill', 'credit_card_enabled') $false
    & $set $prefs @('browser', 'has_seen_welcome_page') $true      # no first-run pages
    & $set $prefs @('sync', 'requested') $false                    # no "we're syncing your data"
    & $set $prefs @('browser', 'enable_spellchecking') $false      # no spelling correction
    & $set $prefs @('spellcheck', 'dictionaries') @()
    & $set $prefs @('spellcheck', 'use_spelling_service') $false
    return ($prefs | ConvertTo-Json -Depth 50 -Compress)
}


function Global:ConvertTo-PlainJsonValue {
    <#
      Pure (2.37.0): a value as ConvertTo-Json should see it - text as plain text, lists and dictionaries and
      objects rebuilt from their parts. Windows PowerShell 5.1 writes what PowerShell hangs on a value too
      (Get-Content's text carries PSPath, PSDrive, PSProvider...: many levels, and the answer fails); 7 doesn't.
    #>
    param($Value, [int]$Depth = 12)
    if ($null -eq $Value) { return $null }
    # Not "$base = if ...": an if's output is unrolled - @(5) would come out as 5, @() as nothing.
    $base = $Value
    if ($Value -is [System.Management.Automation.PSObject]) { $base = $Value.PSObject.BaseObject }
    if ($base -is [string]) { return [string]$base }
    if ($base -is [ValueType] -or $Depth -le 0) { return $base }
    if ($base -is [System.Collections.IDictionary]) {
        $o = [ordered]@{}
        foreach ($k in @($base.Keys)) { $o[[string]$k] = ConvertTo-PlainJsonValue $base[$k] ($Depth - 1) }
        return $o
    }
    if ($base -is [System.Collections.IEnumerable]) {
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($i in $base) { $list.Add((ConvertTo-PlainJsonValue $i ($Depth - 1))) }
        return , $list.ToArray()
    }
    if ($base -is [System.Management.Automation.PSCustomObject] -or $Value -is [System.Management.Automation.PSObject] -and $base.GetType().FullName -eq 'System.Management.Automation.PSCustomObject') {
        $o = [ordered]@{}
        foreach ($p in $Value.PSObject.Properties) { $o[$p.Name] = ConvertTo-PlainJsonValue $p.Value ($Depth - 1) }
        return $o
    }
    return $Value
}

function Global:ConvertTo-WebJsonText {
    <#
      An answer as JSON text. Windows PowerShell 5.1 (-Desktop) writes what PowerShell hangs on a value (Get-Content's
      PSPath, PSDrive, PSProvider - many levels, and the answer then fails): there it is rebuilt from plain values
      (ConvertTo-PlainJsonValue) - but only when it has to be (2.38.0): rebuilding every answer made the Apps list of
      500 apps a second and a half slower. Plain ConvertTo-Json first; rebuilt when that fails or writes PSPath.
    #>
    param($Object, [switch]$Desktop)
    if ($Object -is [string]) { return $Object }
    if (-not $Desktop) { return (ConvertTo-Json -InputObject $Object -Depth 12 -Compress) }
    $json = $null
    try { $json = ConvertTo-Json -InputObject $Object -Depth 12 -Compress -ErrorAction Stop } catch { $json = $null }
    if ($null -eq $json -or $json.Contains('"PSPath":') -or $json.Contains('"PSProvider":')) { $json = ConvertTo-Json -InputObject (ConvertTo-PlainJsonValue $Object) -Depth 12 -Compress }
    return $json
}

function Global:Get-VersionStringsFromBytes {
    <#
      Pure: the strings of an .exe's version block (StringFileInfo) found in -Bytes - ProductName, CompanyName,
      ProductVersion, FileDescription - as @{ key = value }, from the first VS_VERSION_INFO in them. Each String is
      wLength, wValueLength (characters), wType, the key (UTF-16, ending in 0), padding to 4 bytes, the value.
    #>
    param([byte[]]$Bytes, [string[]]$Keys = @('ProductName', 'CompanyName', 'ProductVersion', 'FileDescription'))
    $out = @{}
    if (-not $Bytes -or $Bytes.Length -lt 64) { return $out }
    $latin = [Text.Encoding]::GetEncoding(28591)
    $text = $latin.GetString($Bytes)
    $vs = $text.IndexOf($latin.GetString([Text.Encoding]::Unicode.GetBytes('VS_VERSION_INFO')), [System.StringComparison]::Ordinal)
    if ($vs -lt 0) { return $out }
    $end = [Math]::Min($Bytes.Length, $vs + 65536)
    foreach ($k in $Keys) {
        $needle = $latin.GetString([Text.Encoding]::Unicode.GetBytes($k + [char]0))
        $at = $text.IndexOf($needle, $vs, $end - $vs, [System.StringComparison]::Ordinal)
        if ($at -lt 6) { continue }
        $start = $at - 6
        $chars = [BitConverter]::ToUInt16($Bytes, $start + 2)
        if ($chars -le 0 -or $chars -gt 1024) { continue }
        $valueAt = $start + [int]([Math]::Ceiling((6 + $needle.Length) / 4.0) * 4)
        if ($valueAt + $chars * 2 -gt $Bytes.Length) { continue }
        $v = ([Text.Encoding]::Unicode.GetString($Bytes, $valueAt, $chars * 2)).TrimEnd([char]0).Trim()
        if ($v) { $out[$k] = $v }
    }
    return $out
}

function Global:Get-ExeVersionStrings {
    # An .exe's ProductName, CompanyName, ProductVersion, FileDescription: Windows reads them; elsewhere they are found in the file (the first 64 MB).
    param([string]$Path)
    if ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop') {
        try { $vi = (Get-Item -LiteralPath $Path -ErrorAction Stop).VersionInfo; return @{ ProductName = ([string]$vi.ProductName).Trim(); CompanyName = ([string]$vi.CompanyName).Trim(); ProductVersion = ([string]$vi.ProductVersion).Trim(); FileDescription = ([string]$vi.FileDescription).Trim() } }
        catch { return @{} }
    }
    $fs = $null
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        $latin = [Text.Encoding]::GetEncoding(28591); $needle = $latin.GetString([Text.Encoding]::Unicode.GetBytes('VS_VERSION_INFO'))
        $chunk = New-Object byte[] (1MB + 256); $offset = [long]0; $carry = 0
        while ($offset -lt 64MB) {
            $read = $fs.Read($chunk, $carry, 1MB); if ($read -le 0) { break }
            $len = $carry + $read
            $at = $latin.GetString($chunk, 0, $len).IndexOf($needle, [System.StringComparison]::Ordinal)
            if ($at -ge 0) {
                # The block from there on (64 KB is far more than a version block takes).
                [void]$fs.Seek($offset - $carry + $at, [System.IO.SeekOrigin]::Begin)
                $buf = New-Object byte[] 65536; $n = $fs.Read($buf, 0, $buf.Length)
                return (Get-VersionStringsFromBytes -Bytes ($buf[0..($n - 1)]))
            }
            # Keep the last bytes: the key may straddle two chunks.
            $keep = [Math]::Min(64, $len); [Array]::Copy($chunk, $len - $keep, $chunk, 0, $keep); $carry = $keep; $offset += $read
        }
        return @{}
    }
    catch { return @{} }
    finally { if ($fs) { $fs.Dispose() } }
}

function Global:Get-ExeVersionText {
    <#
      An .exe's version: its ProductVersion (else FileVersion) on Windows. Elsewhere (the server version) .NET
      reads version data only from .NET files - there the version block (VS_FIXEDFILEINFO) is found in the
      file itself: the 'VS_VERSION_INFO' key, then its signature 0xFEEF04BD. The first 64 MB are looked at
      (the resources come before an installer's appended payload). '' when there is none.
    #>
    param([string]$Path)
    if ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop') {
        try {
            $vi = (Get-Item -LiteralPath $Path -ErrorAction Stop).VersionInfo
            $v = ([string]$vi.ProductVersion).Trim(); if (-not $v) { $v = ([string]$vi.FileVersion).Trim() }
            return ($v -replace ',\s*', '.')
        }
        catch { return '' }
    }
    $latin = [Text.Encoding]::GetEncoding(28591)
    $needle = $latin.GetString([Text.Encoding]::Unicode.GetBytes('VS_VERSION_INFO'))
    $fs = $null
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        $chunk = New-Object byte[] (1MB + 256); $offset = 0; $carry = 0
        while ($offset -lt 64MB) {
            $read = $fs.Read($chunk, $carry, 1MB); if ($read -le 0) { break }
            $len = $carry + $read
            $text = $latin.GetString($chunk, 0, $len)
            $at = $text.IndexOf($needle, [System.StringComparison]::Ordinal)
            while ($at -ge 0) {
                # The fixed block follows the key (padded to 4 bytes): signature, struct version, then the versions.
                $sig = $text.IndexOf($latin.GetString([byte[]](0xBD, 0x04, 0xEF, 0xFE)), $at, [Math]::Min(64, $len - $at), [System.StringComparison]::Ordinal)
                if ($sig -ge 0 -and $sig + 24 -le $len) {
                    $pms = [BitConverter]::ToUInt32($chunk, $sig + 16); $pls = [BitConverter]::ToUInt32($chunk, $sig + 20)
                    if (-not ($pms -or $pls)) { $pms = [BitConverter]::ToUInt32($chunk, $sig + 8); $pls = [BitConverter]::ToUInt32($chunk, $sig + 12) }
                    if ($pms -or $pls) { return "$($pms -shr 16).$($pms -band 0xFFFF).$($pls -shr 16).$($pls -band 0xFFFF)" }
                }
                $at = $text.IndexOf($needle, $at + 1, [System.StringComparison]::Ordinal)
            }
            # Keep the end of this chunk: a key cut in two is found in the next.
            $carry = [Math]::Min(256, $len)
            [Array]::Copy($chunk, $len - $carry, $chunk, 0, $carry)
            $offset += $read
        }
    }
    catch { }
    finally { if ($fs) { $fs.Dispose() } }
    return ''
}

function Global:Get-MsiPropertyValues {
    <#
      Values from an MSI's Property table (ProductName, ProductVersion, ProductCode, ...): @{ Name = Value }
      for the -Names it has. Windows: Windows Installer itself. Linux (the container): msitools' msiinfo.
      Empty when the file can't be read.
    #>
    param([string]$Path, [string[]]$Names)
    $out = @{}
    if ($IsLinux -or $IsMacOS) {
        $tool = Get-Command msiinfo -ErrorAction SilentlyContinue
        if (-not $tool) { return $out }
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $tool.Source
            foreach ($a in @('export', $Path, 'Property')) { $psi.ArgumentList.Add($a) }
            $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
            $p = [System.Diagnostics.Process]::Start($psi)
            $errs = $p.StandardError.ReadToEndAsync()   # read alongside: a full error pipe would stop msiinfo
            $text = $p.StandardOutput.ReadToEnd(); [void]$p.WaitForExit(20000); [void]$errs
            # Tab-separated: a header of three lines, then "Property<TAB>Value".
            foreach ($line in @($text -split "`r?`n" | Select-Object -Skip 3)) {
                $k = $line.IndexOf("`t"); if ($k -le 0) { continue }
                $name = $line.Substring(0, $k)
                if ($Names -contains $name) { $out[$name] = $line.Substring($k + 1) }
            }
        }
        catch { }
        return $out
    }
    try {
        $wi = New-Object -ComObject WindowsInstaller.Installer
        $db = $wi.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $wi, @($Path, 0))
        foreach ($prop in $Names) {
            $view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @("SELECT Value FROM Property WHERE Property='$prop'"))
            [void]$view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
            $rec = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
            if ($rec) { $out[$prop] = [string]$rec.GetType().InvokeMember('StringData', 'GetProperty', $null, $rec, 1) }
            [void]$view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null)
        }
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($db); [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($wi)
    }
    catch { }
    return $out
}
