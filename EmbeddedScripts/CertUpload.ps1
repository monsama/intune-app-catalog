<#
.SYNOPSIS
    Uploads a locally-generated certificate's public key to an Entra ID app
    registration, so app-only certificate authentication can start working
    without a manual trip through the Azure portal.
.DESCRIPTION
    This is the one operation in the whole tool that CANNOT use the app-only
    certificate the rest of the app relies on - that certificate isn't
    trusted by the app registration yet, which is exactly the problem this
    script solves. Instead it uses interactive (delegated) sign-in as the
    person running it, via a regular browser-based prompt (see the note by
    Connect-MgGraph below for why -UseDeviceCode is deliberately avoided
    despite being the more obviously reliable choice for a hidden
    background process). This also means the caller must pass
    -ShowConsoleWindow to Start-PipelineProcess for this script specifically
    - Windows' WAM authentication broker needs an actual parent window
    handle to attach its sign-in prompt to, and fails outright ("A window
    handle must be configured") without one. Every other embedded script in
    this app runs fully hidden since app-only certificate auth needs no
    such window.

    Deliberately fetches the app's EXISTING keyCredentials and includes them
    unchanged in the PATCH, alongside the new one. A PATCH to keyCredentials
    is REPLACE semantics, not additive - sending only the new certificate
    would silently delete every other certificate already trusted for that
    app registration, which could break other tools or admins relying on
    them. Confirmed against Microsoft's own documentation before writing
    this, given this operates on shared, security-sensitive credentials.
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$ConfigPath
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[System.Net.ServicePointManager]::Expect100Continue = $false

function Write-Step {
    param([string]$Text)
    Write-Host ""
    Write-Host "=== $Text ===" -ForegroundColor Cyan
}

function Write-Result {
    param([bool]$Success, [string]$ErrorMessage, [array]$Certificates = @())
    $result = [pscustomobject]@{ success = $Success; error = $ErrorMessage; certificates = $Certificates }
    $result | ConvertTo-Json -Depth 6 | Set-Content -Path $Config.OutputResultPath -Encoding UTF8
}

function Get-HttpErrorDetail {
    param($ErrorRecord)
    $detail = $ErrorRecord.ErrorDetails.Message
    if ($detail) { return $detail }
    try {
        if ($ErrorRecord.Exception.Response) {
            $stream = $ErrorRecord.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)
            $body = $reader.ReadToEnd()
            $reader.Close()
            if ($body) { return $body }
        }
    } catch { }
    return $null
}

function Invoke-GraphRequestDetailed {
    param(
        [Parameter(Mandatory=$true)][string]$Uri,
        [string]$Method = "GET",
        [string]$Body = $null,
        [string]$ContentType = "application/json",
        [Parameter(Mandatory=$true)][string]$StepDescription
    )
    $maxAttempts = 4
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            if ($Body) {
                return Invoke-MgGraphRequest -Uri $Uri -Method $Method -Body $Body -ContentType $ContentType -ErrorAction Stop
            }
            else {
                return Invoke-MgGraphRequest -Uri $Uri -Method $Method -ErrorAction Stop
            }
        }
        catch {
            # Graph rate-limits (429) or has brief service hiccups (503) far
            # more often during bulk operations working through many items
            # in a row than on a single one-off call - retrying with
            # backoff instead of immediately failing the whole run on the
            # first blip. Detected from the exception TEXT rather than a
            # structured status-code property, since this cmdlet's own
            # exceptions have already been confirmed elsewhere in this app
            # to carry the status as readable text (e.g. "BadRequest (Bad
            # Request)") rather than a reliably-populated .Response object.
            $isThrottled = $_.Exception.Message -match '429|TooManyRequests|Too Many Requests'
            $isTransient = $_.Exception.Message -match '503|ServiceUnavailable|Service Unavailable'
            # 429 always means the request was rejected BEFORE any
            # processing happened, so retrying it is always safe. 503 is
            # different specifically for POST - the server may have already
            # created the resource before the response was lost in transit,
            # and retrying could then create a duplicate (a second app
            # registration, a second group, etc). GET/PUT/PATCH/DELETE don't
            # have this risk, since repeating them with the same body
            # produces the same end state no matter how many times it's
            # applied.
            $safeToRetryTransient = $isTransient -and $Method -ne "POST"
            if (($isThrottled -or $safeToRetryTransient) -and $attempt -lt $maxAttempts) {
                $waitSeconds = $attempt * $attempt * 3   # 3s, 12s, 27s
                $reason = if ($isThrottled) { "Rate-limited" } else { "Service temporarily unavailable" }
                Write-Host "  [!] $reason - waiting ${waitSeconds}s before retry $($attempt+1)/$maxAttempts..." -ForegroundColor Yellow
                Start-Sleep -Seconds $waitSeconds
                continue
            }
            $detail = Get-HttpErrorDetail -ErrorRecord $_
            $msg = "$StepDescription failed [$Method $Uri]: $($_.Exception.Message)"
            if ($detail) { $msg += "`nResponse body: $detail" }
            throw $msg
        }
    }
}

function ConvertTo-Iso8601String {
    param($Value)
    if (-not $Value) { return $null }
    try {
        return ([datetime]$Value).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    }
    catch {
        return $Value
    }
}

Write-Step "Loading configuration"
if (-not (Test-Path $ConfigPath)) {
    Write-Host "[ERROR] Config file not found: $ConfigPath" -ForegroundColor Red
    exit 1
}
$Config = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
Write-Host "  App (client) ID: $($Config.ClientId)" -ForegroundColor Gray
# Check mode never sends CertSubject/CertThumbprint at all - it only signs
# in and lists what's already trusted in Entra, with no local certificate
# involved. Only Upload/DeleteCert actually carry these, so only show the
# line when there's something real to show instead of printing it blank.
if ($Config.CertSubject) {
    Write-Host "  Certificate: $($Config.CertSubject) (thumbprint $($Config.CertThumbprint))" -ForegroundColor Gray
}

try {
    Write-Step "Signing in (interactive - uses YOUR account, not the app-only certificate)"
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    Write-Host "  A separate console window and a browser window should both open for" -ForegroundColor Yellow
    Write-Host "  sign-in - check for them if nothing seems to be happening (they can" -ForegroundColor Yellow
    Write-Host "  occasionally open behind other windows)." -ForegroundColor Yellow
    # Check asks for read-only, matching what it actually uses - NOT unified
    # with Upload's broader read-write scope, even though that would let a
    # later Upload silently reuse Check's cached sign-in (Microsoft Graph
    # PowerShell does cache tokens to disk and reuse them across separate
    # process launches, confirmed in Microsoft's own docs). Tried that first,
    # but Application.ReadWrite.All is sensitive enough that some tenants'
    # Conditional Access policies demand an extra verification step just for
    # requesting it - meaning even a plain Check started needing two
    # authentication steps instead of one. Making the common case (just
    # checking) worse to occasionally save a prompt on the rarer case
    # (check, then also upload) is the wrong trade - so Check goes back to
    # asking only for what it needs, and Upload doing the same after it may
    # need its own separate sign-in.
    $signInScope = if ($Config.Mode -eq "Check") { "Application.Read.All" } else { "Application.ReadWrite.All" }
    #
    # Deliberately NOT using -UseDeviceCode here, even though it would
    # otherwise be the more reliable choice for a hidden background process
    # (no dependency on a browser popup succeeding from a non-interactive
    # console). Confirmed via the Microsoft Graph PowerShell SDK's own open
    # issue tracker (GitHub issue #3495) that -UseDeviceCode currently
    # leaves the acquired token unusable - sign-in appears to succeed, but
    # every subsequent Graph call then fails with "DeviceCodeCredential
    # authentication failed: Object reference not set to an instance of an
    # object." The same report confirms regular interactive sign-in doesn't
    # have this problem, so that's what's used instead despite the
    # trade-off, until that SDK bug is fixed upstream.
    Connect-MgGraph -TenantId $Config.TenantId -Scopes $signInScope -NoWelcome -ErrorAction Stop
    $ctx = Get-MgContext -ErrorAction Stop
    Write-Host "  [OK] Signed in as $($ctx.Account)." -ForegroundColor Green

    Write-Step "Finding the app registration"
    $encodedFilter = [Uri]::EscapeDataString("appId eq '$($Config.ClientId)'")
    $appLookup = Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=$encodedFilter&`$select=id,displayName,keyCredentials" -Method GET -StepDescription "Look up app registration"
    if (-not $appLookup.value -or $appLookup.value.Count -eq 0) {
        throw "No app registration found with Application (client) ID '$($Config.ClientId)' in this tenant. Double check the Client ID in Settings, and that you signed into the right tenant just now."
    }
    $objectId = $appLookup.value[0].id
    $appDisplayName = $appLookup.value[0].displayName
    $existingRaw = @($appLookup.value[0].keyCredentials)
    Write-Host "  Found: $appDisplayName ($objectId)" -ForegroundColor Gray

    if ($Config.Mode -eq "Check") {
        Write-Step "Certificates currently trusted for this app registration"
        $certList = New-Object System.Collections.Generic.List[object]
        if ($existingRaw.Count -eq 0) {
            Write-Host "  (none - nothing has been uploaded yet)" -ForegroundColor Gray
        }
        $seenThumbprints = New-Object System.Collections.Generic.HashSet[string]
        foreach ($k in $existingRaw) {
            # customKeyIdentifier defaults to the certificate's thumbprint,
            # just base64-encoded instead of the usual hex string - decoded
            # back to hex here so it's directly comparable to the thumbprint
            # shown elsewhere in this app (e.g. "Certificate thumbprint" above).
            $thumbHex = ""
            if ($k.customKeyIdentifier) {
                try {
                    $thumbBytes = [System.Convert]::FromBase64String($k.customKeyIdentifier)
                    $thumbHex = ($thumbBytes | ForEach-Object { $_.ToString("X2") }) -join ''
                } catch { }
            }
            $expiry = if ($k.endDateTime) { ([datetime]$k.endDateTime).ToString("yyyy-MM-dd") } else { "?" }
            $dupeNote = if ($thumbHex -and -not $seenThumbprints.Add($thumbHex)) { "  (DUPLICATE thumbprint - same certificate uploaded more than once)" } else { "" }
            Write-Host "  - $($k.displayName)  [thumbprint $thumbHex]  expires $expiry$dupeNote" -ForegroundColor Gray
            # KeyId (not thumbprint) is what actually identifies THIS specific
            # entry - two entries can legitimately share a thumbprint if the
            # same certificate was uploaded more than once, and matching a
            # delete by thumbprint alone would remove all of them at once
            # instead of just the one selected.
            $certList.Add([pscustomobject]@{ DisplayName = $k.displayName; Thumbprint = $thumbHex; Expiry = $expiry; KeyId = $k.keyId })
        }
        Write-Step "Done"
        Write-Result -Success $true -ErrorMessage "" -Certificates $certList.ToArray()
        exit 0
    }

    if ($Config.Mode -eq "DeleteCert") {
        Write-Step "Removing certificate from this app registration"
        $keepKeys = New-Object System.Collections.Generic.List[object]
        $matchFound = $false
        foreach ($k in $existingRaw) {
            # Matched by keyId, NOT thumbprint - two entries can legitimately
            # share the same thumbprint if the same certificate was uploaded
            # more than once, and matching by thumbprint would remove every
            # entry that shares it instead of just the one that was selected.
            # keyId is the one property Graph guarantees is unique per entry.
            if ($k.keyId -eq $Config.KeyIdToDelete) {
                $matchFound = $true
                Write-Host "  Removing: $($k.displayName)  [keyId $($k.keyId)]" -ForegroundColor Gray
                continue
            }
            # Reconstructed from only the documented, safe-to-resend
            # properties - same reasoning as Upload's $preservedKeys, since
            # this PATCH is exactly as replace-not-merge as that one is.
            $keepKeys.Add(@{
                "@odata.type" = "#microsoft.graph.keyCredential"
                type          = $k.type
                usage         = $k.usage
                key           = $k.key
                displayName   = $k.displayName
                startDateTime = ConvertTo-Iso8601String $k.startDateTime
                endDateTime   = ConvertTo-Iso8601String $k.endDateTime
            })
        }
        if (-not $matchFound) {
            throw "No certificate with keyId $($Config.KeyIdToDelete) was found on this app registration - nothing removed. It may have already been removed by someone else since the list was last loaded."
        }
        $patchBody = @{ keyCredentials = $keepKeys.ToArray() } | ConvertTo-Json -Depth 10
        Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/v1.0/applications/$objectId" -Method PATCH -Body $patchBody -ContentType "application/json" -StepDescription "Remove certificate" | Out-Null
        Write-Host "  [OK] Removed - $($keepKeys.Count) certificate(s) remain." -ForegroundColor Green
        Write-Step "Done"
        Write-Result -Success $true -ErrorMessage ""
        exit 0
    }

    Write-Host "  Currently has $($existingRaw.Count) certificate(s)/key(s) registered - all will be kept." -ForegroundColor Gray

    # Skip entirely if this exact certificate is already registered - Graph
    # doesn't enforce uniqueness on keyCredentials, so re-uploading the same
    # certificate would otherwise create a second, indistinguishable entry.
    # That's exactly what caused an earlier bug: two entries ended up
    # sharing one thumbprint, and deleting "one" of them from the list
    # removed both, since thumbprint was the only thing being matched on.
    $alreadyPresent = $false
    foreach ($k in $existingRaw) {
        if ($k.customKeyIdentifier) {
            try {
                $existingThumbBytes = [System.Convert]::FromBase64String($k.customKeyIdentifier)
                $existingThumbHex = ($existingThumbBytes | ForEach-Object { $_.ToString("X2") }) -join ''
                if ($existingThumbHex -eq $Config.CertThumbprint) { $alreadyPresent = $true; break }
            } catch { }
        }
    }
    if ($alreadyPresent) {
        Write-Host "  This certificate (thumbprint $($Config.CertThumbprint)) is already registered - nothing to add." -ForegroundColor Yellow
        Write-Step "Done"
        Write-Result -Success $true -ErrorMessage ""
        exit 0
    }

    Write-Step "Adding the new certificate"
    # Reconstructed from only the documented, safe-to-resend properties,
    # rather than passing the raw GET response straight back through - keeps
    # this from accidentally echoing back any server-computed field that
    # doesn't belong in a request body.
    $preservedKeys = @($existingRaw | ForEach-Object {
        @{
            "@odata.type" = "#microsoft.graph.keyCredential"
            type          = $_.type
            usage         = $_.usage
            key           = $_.key
            displayName   = $_.displayName
            startDateTime = ConvertTo-Iso8601String $_.startDateTime
            endDateTime   = ConvertTo-Iso8601String $_.endDateTime
        }
    })

    $newKey = @{
        "@odata.type"  = "#microsoft.graph.keyCredential"
        type           = "AsymmetricX509Cert"
        usage          = "Verify"
        key            = $Config.CertBase64
        displayName    = $Config.CertSubject
        startDateTime  = ConvertTo-Iso8601String $Config.CertNotBefore
        endDateTime    = ConvertTo-Iso8601String $Config.CertNotAfter
    }

    $combinedKeys = @($preservedKeys) + @($newKey)
    $patchBody = @{ keyCredentials = $combinedKeys } | ConvertTo-Json -Depth 10
    Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/v1.0/applications/$objectId" -Method PATCH -Body $patchBody -ContentType "application/json" -StepDescription "Add certificate" | Out-Null
    Write-Host "  [OK] Certificate added - $($combinedKeys.Count) total now registered (kept all $($existingRaw.Count) existing one(s))." -ForegroundColor Green

    Write-Step "Done"
    Write-Host "[OK] It can take a few minutes for this to propagate before app-only sign-in with this certificate works." -ForegroundColor Green
    Write-Result -Success $true -ErrorMessage ""
    exit 0
}
catch {
    Write-Host ""
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    Write-Result -Success $false -ErrorMessage $_.Exception.Message
    exit 1
}

