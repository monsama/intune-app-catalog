<#
.SYNOPSIS
    Creates (or updates the metadata of) a Win32 app in Intune from a catalog entry.
.DESCRIPTION
    Reads a JSON config file (written by the GUI) describing the app, connects to Microsoft
    Graph app-only via certificate, and either:
      - Mode "UpdateMetadata": PATCHes an existing app's name/description/install/uninstall/
        detection/dependencies. No content re-upload.
      - Mode "Create": creates a new Win32LobApp, uploads and commits the .intunewin package
        content (decrypting nothing - the package is already encrypted by IntuneWinAppUtil;
        this script reads that encryption metadata from the package and passes it through to
        Graph/Azure Storage as-is), sets detection rules, and sets dependencies.
    Writes a result JSON (success/appId/error) to -OutputResultPath so the GUI can read back
    what happened.
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$ConfigPath
)

$ErrorActionPreference = "Stop"

# Force TLS 1.2 explicitly. Windows PowerShell 5.1 / .NET Framework doesn't
# always default to TLS 1.2 for outbound HTTPS, and Azure Blob Storage
# requires TLS 1.2+. The Microsoft.Graph SDK forces this internally for its
# own requests (which is why Invoke-MgGraphRequest calls work regardless),
# but our own raw Invoke-WebRequest calls to Azure Storage inherit whatever
# this session's default protocol is - which, left unset, can cause the
# HTTPS handshake to hang or fail silently against a server that only
# accepts TLS 1.2+, even though basic TCP connectivity succeeds fine.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Write-Host "TLS protocol forced to: $([Net.ServicePointManager]::SecurityProtocol)" -ForegroundColor DarkGray

# By default .NET adds "Expect: 100-continue" to PUT/POST requests with a
# body - the client then WAITS for the server to say "100 Continue" before
# actually sending the body. If a corporate proxy/firewall interferes with
# that specific handshake (a common occurrence), the client can hang
# indefinitely even though the underlying TCP/TLS connection is completely
# healthy. This is a well-known cause of exactly "PUT/POST just hangs"
# symptoms for .NET scripts talking to Azure from behind corporate networks -
# disabling it means the body is sent immediately, no handshake to hang on.
[System.Net.ServicePointManager]::Expect100Continue = $false
Write-Host "Expect100Continue set to: $([System.Net.ServicePointManager]::Expect100Continue)" -ForegroundColor DarkGray

function Write-Step {
    param([string]$Text)
    Write-Host ""
    Write-Host "=== $Text ===" -ForegroundColor Cyan
}

function Write-Result {
    param([bool]$Success, [string]$AppId, [string]$ErrorMessage)
    $result = [pscustomobject]@{
        success = $Success
        appId   = $AppId
        error   = $ErrorMessage
    }
    $result | ConvertTo-Json | Set-Content -Path $Config.OutputResultPath -Encoding UTF8
}

# Pulls the actual error detail out of a failed web/Graph call. The default
# exception message for a failed HTTP call is just "Response status code does
# not indicate success: 400 (Bad Request)" - completely useless on its own.
# The real reason is almost always in the response BODY, which PowerShell
# normally puts in $_.ErrorDetails.Message for REST-style cmdlets; this falls
# back to reading the raw response stream if that's empty.
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

# Adds a key to a request body hashtable ONLY if the value is non-blank. Used
# for the optional descriptive fields (owner/developer/notes/URLs) - in
# Update mode this dialog never fetches the app's current values first, so a
# blank field means "leave it as whatever it already is", not "clear it".
# Sending an empty string would actually WIPE an existing value, which this
# avoids by simply never including the key at all when there's nothing typed.
function Add-OptionalStringField {
    param([hashtable]$Body, [string]$GraphKey, [string]$Value)
    if (-not [string]::IsNullOrWhiteSpace($Value)) { $Body[$GraphKey] = $Value }
}

# $Config.MinOSVersionKey arrives in the IntuneWin32App module's own
# convention ("W10_1607", "W11_21H2", ...) - the GUI's $minOsRawValues list
# in Show-CreateInIntuneDialog is sourced directly from that module's
# ValidateSet, and this raw value is also what gets stored in the local
# catalog JSON. Confirmed live against the tenant, though, that Graph
# itself rejects that spelling outright on write ("Unknown
# MinimumSupportedWindowsRelease: W11_21H2") - Microsoft's own
# documentation for this property only shows the "Windows11_23H2" style
# (Windows<major>_<release>, no leading "W" abbreviation) as a valid
# value. Read paths elsewhere in this app (Get-ParsedMinOsRelease) already
# tolerate both spellings, since apps created via the portal or other
# tools can carry either - this just normalizes to the one spelling Graph
# actually accepts before writing.
function ConvertTo-GraphMinOsRelease {
    param([string]$RawValue)
    if (-not $RawValue) { return $RawValue }
    if ($RawValue -match '^(?i)W(10|11)_(.+)$') { return "Windows$($Matches[1])_$($Matches[2])" }
    return $RawValue
}

# Wraps Invoke-MgGraphRequest so any failure throws an exception whose message
# includes the actual Graph error body (error.code / error.message), not just
# the generic "response status does not indicate success" text.
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
            $graphTimer = [System.Diagnostics.Stopwatch]::StartNew()
            if ($Body) {
                $graphResult = Invoke-MgGraphRequest -Uri $Uri -Method $Method -Body $Body -ContentType $ContentType -ErrorAction Stop
            }
            else {
                $graphResult = Invoke-MgGraphRequest -Uri $Uri -Method $Method -ErrorAction Stop
            }
            # [GRAPH] log line / read summary - see GraphLog.ps1 (absent when run on its own)
            if (Get-Command Write-GraphRequestLog -ErrorAction SilentlyContinue) { Write-GraphRequestLog -Method $Method -Uri $Uri -Milliseconds $graphTimer.ElapsedMilliseconds }
            return $graphResult
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
            if (Get-Command Write-GraphRequestLog -ErrorAction SilentlyContinue) { Write-GraphRequestLog -Method $Method -Uri $Uri -Milliseconds $graphTimer.ElapsedMilliseconds -ErrorText $_.Exception.Message -Detail $detail }
            $msg = "$StepDescription failed [$Method $Uri]: $($_.Exception.Message)"
            if ($detail) { $msg += "`nResponse body: $detail" }
            throw $msg
        }
    }
}

# Same idea for the raw Invoke-WebRequest calls used for the Azure Storage
# block blob upload.
function Invoke-WebRequestDetailed {
    param(
        [Parameter(Mandatory=$true)][string]$Uri,
        [string]$Method = "GET",
        $Body = $null,
        [hashtable]$Headers = $null,
        [string]$ContentType = $null,
        [int]$TimeoutSec = 120,
        [Parameter(Mandatory=$true)][string]$StepDescription
    )
    try {
        # -UseBasicParsing is essential here, not optional: without it,
        # Invoke-WebRequest tries to parse the response using Internet
        # Explorer's engine (COM/MSHTML). On a machine where IE has never
        # been through its first-run setup, that throws an interactive
        # "Security Warning: Script Execution Risk... Do you want to
        # continue? [Y/N]" console prompt - which then hangs forever in a
        # hidden/non-interactive process, since nothing can ever answer it.
        # This is why successful responses (which get parsed) hung while
        # fast-failing error responses (which skip parsing) didn't.
        $params = @{ Uri = $Uri; Method = $Method; ErrorAction = "Stop"; TimeoutSec = $TimeoutSec; UseBasicParsing = $true }
        if ($null -ne $Body) { $params.Body = $Body }
        if ($Headers) { $params.Headers = $Headers }
        if ($ContentType) { $params.ContentType = $ContentType }
        return Invoke-WebRequest @params
    }
    catch {
        $detail = Get-HttpErrorDetail -ErrorRecord $_
        # (not logged as [GRAPH]: this is the Azure Storage upload, and its URL carries a SAS signature)
        $msg = "$StepDescription failed [$Method $Uri]: $($_.Exception.Message)"
        if ($detail) { $msg += "`nResponse body: $detail" }
        throw $msg
    }
}

# Reads a .intunewin package's embedded encryption metadata (already baked in
# by IntuneWinAppUtil - this just parses what's there, no encryption work of
# our own) and extracts the encrypted content blob to a temp file ready for
# upload. Used by both Create mode (new app) and Update mode's optional
# content-replace path (existing app), so the two never have their own
# separate, potentially-diverging copies of this logic.
function Get-IntuneWinPackageInfo {
    param([Parameter(Mandatory=$true)][string]$PackagePath)

    Write-Step "Reading package: $PackagePath"
    if (-not (Test-Path $PackagePath)) {
        throw "Package file not found: $PackagePath"
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($PackagePath)
    try {
        $detectionEntry = $zip.Entries | Where-Object { $_.FullName -match 'Detection\.xml$' } | Select-Object -First 1
        if (-not $detectionEntry) { throw "Detection.xml not found inside the .intunewin package - is this a valid IntuneWinAppUtil output file?" }

        $reader = New-Object System.IO.StreamReader($detectionEntry.Open())
        $xmlText = $reader.ReadToEnd()
        $reader.Close()

        # Strip the default XML namespace so plain dot-notation property access works
        $xmlText = $xmlText -replace 'xmlns="[^"]*"', ''
        [xml]$detectionXml = $xmlText
        $appInfo = $detectionXml.ApplicationInfo

        $unencryptedSize = [int64]$appInfo.UnencryptedContentSize
        $contentFileName = [string]$appInfo.FileName
        $setupFile       = [string]$appInfo.SetupFile
        Write-Host "  Setup file      : $setupFile" -ForegroundColor Gray
        Write-Host "  Unencrypted size: $unencryptedSize bytes" -ForegroundColor Gray

        $encInfo = $appInfo.EncryptionInfo
        $fileEncryptionInfo = @{
            encryptionKey         = [string]$encInfo.EncryptionKey
            macKey                = [string]$encInfo.MacKey
            initializationVector  = [string]$encInfo.InitializationVector
            mac                   = [string]$encInfo.Mac
            profileIdentifier     = [string]$encInfo.ProfileIdentifier
            fileDigest             = [string]$encInfo.FileDigest
            fileDigestAlgorithm    = [string]$encInfo.FileDigestAlgorithm
        }

        # Extract the encrypted content file to a temp location for upload
        $contentEntry = $zip.Entries | Where-Object { $_.FullName -match [regex]::Escape($contentFileName) + '$' } | Select-Object -First 1
        if (-not $contentEntry) { throw "Encrypted content file '$contentFileName' not found inside the package." }

        $tempEncryptedPath = Join-Path $env:TEMP ("intunepkg_upload_" + [guid]::NewGuid().ToString("N") + ".bin")
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($contentEntry, $tempEncryptedPath)
        $encryptedSize = (Get-Item $tempEncryptedPath).Length
        Write-Host "  Encrypted size  : $encryptedSize bytes" -ForegroundColor Gray
    }
    finally {
        $zip.Dispose()
    }

    return [pscustomobject]@{
        UnencryptedSize    = $unencryptedSize
        EncryptedSize      = $encryptedSize
        ContentFileName    = $contentFileName
        SetupFile          = $setupFile
        FileEncryptionInfo = $fileEncryptionInfo
        TempEncryptedPath  = $tempEncryptedPath
        OriginalFileName   = [System.IO.Path]::GetFileName($PackagePath)
    }
}

# Uploads a package (already read via Get-IntuneWinPackageInfo) as a new
# content version on an EXISTING app object - works identically whether that
# app was just created moments ago (Create mode) or already existed and is
# just getting new content pushed to it (Update mode's replace-content path).
function Invoke-Win32AppContentUpload {
    param(
        [Parameter(Mandatory=$true)][string]$AppId,
        [Parameter(Mandatory=$true)]$PackageInfo
    )

    Write-Step "Creating content version"
    $cv = Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$AppId/microsoft.graph.win32LobApp/contentVersions" `
        -Method POST -Body "{}" -ContentType "application/json" -StepDescription "Create content version"
    $cvId = $cv.id
    Write-Host "  [OK] Content version: $cvId" -ForegroundColor Green

    Write-Step "Registering package file with Intune"
    $fileBody = @{
        "@odata.type" = "#microsoft.graph.mobileAppContentFile"
        name          = $PackageInfo.ContentFileName
        size          = $PackageInfo.UnencryptedSize
        sizeEncrypted = $PackageInfo.EncryptedSize
        manifest      = $null
        isDependency  = $false
    } | ConvertTo-Json -Depth 8

    $fileObj = Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$AppId/microsoft.graph.win32LobApp/contentVersions/$cvId/files" `
        -Method POST -Body $fileBody -ContentType "application/json" -StepDescription "Register package file"
    $fileId = $fileObj.id
    Write-Host "  [OK] File entry: $fileId" -ForegroundColor Green

    Write-Step "Waiting for Azure Storage upload URL"
    $azureStorageUri = $null
    $attempts = 0
    while ($attempts -lt 60) {
        Start-Sleep -Seconds 2
        $attempts++
        $fileStatus = Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$AppId/microsoft.graph.win32LobApp/contentVersions/$cvId/files/$fileId" -Method GET -StepDescription "Poll for Azure Storage URI"
        if ($fileStatus.uploadState -eq "azureStorageUriRequestSuccess") {
            $azureStorageUri = $fileStatus.azureStorageUri
            break
        }
        elseif ($fileStatus.uploadState -like "*Failed*") {
            throw "Azure Storage URI request failed: $($fileStatus.uploadState)"
        }
        Write-Host "  ... waiting ($($fileStatus.uploadState))" -ForegroundColor DarkGray
    }
    if (-not $azureStorageUri) { throw "Timed out waiting for Azure Storage URI." }
    Write-Host "  [OK] Got upload URL." -ForegroundColor Green

    # Graph itself (graph.microsoft.com) working does NOT guarantee Azure Blob
    # Storage (a completely different domain, *.blob.core.windows.net) is
    # reachable too - some corporate firewalls/proxies allow one and not the
    # other. This is a fast (max ~8s) raw TCP check, so a blocked path fails
    # in seconds instead of only becoming apparent after the full upload
    # timeout expires.
    $storageHost = ([Uri]$azureStorageUri).Host
    Write-Host "  Storage host: $storageHost" -ForegroundColor Gray
    Write-Host "  Checking connectivity to $storageHost`:443..." -ForegroundColor Gray
    $reachable = $false
    try {
        $tcpClient = New-Object System.Net.Sockets.TcpClient
        $connectTask = $tcpClient.ConnectAsync($storageHost, 443)
        $reachable = $connectTask.Wait(8000) -and $tcpClient.Connected
        $tcpClient.Close()
    } catch { $reachable = $false }

    if ($reachable) {
        Write-Host "  [OK] $storageHost is reachable." -ForegroundColor Green
    }
    else {
        Write-Host "  [WARN] Could not open a TCP connection to $storageHost on port 443 within 8 seconds." -ForegroundColor Yellow
        Write-Host "  Microsoft Graph worked fine, but Azure Blob Storage is a different domain - this strongly suggests" -ForegroundColor Yellow
        Write-Host "  a firewall or proxy is blocking outbound HTTPS to it. Ask your network team to allow" -ForegroundColor Yellow
        Write-Host "  *.blob.core.windows.net (or specifically $storageHost). Attempting the upload anyway..." -ForegroundColor Yellow
    }

    Write-Step "Uploading package content"
    $blockSize = 6 * 1024 * 1024
    $bytes = [System.IO.File]::ReadAllBytes($PackageInfo.TempEncryptedPath)
    $totalBlocks = [Math]::Ceiling($bytes.Length / $blockSize)
    $blockIds = New-Object System.Collections.Generic.List[string]

    for ($b = 0; $b -lt $totalBlocks; $b++) {
        $offset = $b * $blockSize
        $len = [Math]::Min($blockSize, $bytes.Length - $offset)
        $chunk = New-Object byte[] $len
        [Array]::Copy($bytes, $offset, $chunk, 0, $len)

        $blockIdRaw = [string]$b
        $blockIdPadded = $blockIdRaw.PadLeft(20, '0')
        $blockId = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($blockIdPadded))
        $blockIds.Add($blockId)

        $blockUri = "$azureStorageUri&comp=block&blockid=$([Uri]::EscapeDataString($blockId))"
        Write-Host "  ... attempting block $($b + 1) of $totalBlocks ($len bytes)..." -ForegroundColor DarkGray
        Invoke-WebRequestDetailed -Uri $blockUri -Method PUT -Body $chunk -Headers @{ "x-ms-blob-type" = "BlockBlob" } -TimeoutSec 60 -StepDescription "Upload block $($b + 1) of $totalBlocks" | Out-Null
        Write-Host "  ... block $($b + 1) of $totalBlocks uploaded" -ForegroundColor DarkGray
    }

    $blockListXml = "<?xml version=`"1.0`" encoding=`"utf-8`"?><BlockList>"
    foreach ($id in $blockIds) { $blockListXml += "<Latest>$id</Latest>" }
    $blockListXml += "</BlockList>"
    $commitBlocksUri = "$azureStorageUri&comp=blocklist"
    Invoke-WebRequestDetailed -Uri $commitBlocksUri -Method PUT -Body $blockListXml -ContentType "text/plain" -StepDescription "Commit block list to storage" | Out-Null
    Write-Host "  [OK] All $totalBlocks block(s) uploaded and committed to storage." -ForegroundColor Green

    Remove-Item $PackageInfo.TempEncryptedPath -Force -ErrorAction SilentlyContinue

    Write-Step "Committing file"
    $commitBody = @{ fileEncryptionInfo = $PackageInfo.FileEncryptionInfo } | ConvertTo-Json -Depth 8
    Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$AppId/microsoft.graph.win32LobApp/contentVersions/$cvId/files/$fileId/commit" `
        -Method POST -Body $commitBody -ContentType "application/json" -StepDescription "Commit file" | Out-Null

    $attempts = 0
    $committed = $false
    while ($attempts -lt 60) {
        Start-Sleep -Seconds 2
        $attempts++
        $fileStatus = Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$AppId/microsoft.graph.win32LobApp/contentVersions/$cvId/files/$fileId" -Method GET -StepDescription "Poll for file commit"
        if ($fileStatus.uploadState -eq "commitFileSuccess") { $committed = $true; break }
        elseif ($fileStatus.uploadState -like "*Failed*") { throw "File commit failed: $($fileStatus.uploadState)" }
        Write-Host "  ... waiting ($($fileStatus.uploadState))" -ForegroundColor DarkGray
    }
    if (-not $committed) { throw "Timed out waiting for file commit." }
    Write-Host "  [OK] File committed." -ForegroundColor Green

    Write-Step "Finalizing app"
    $finalizeBody = @{ "@odata.type" = "#microsoft.graph.win32LobApp"; committedContentVersion = $cvId } | ConvertTo-Json -Depth 8
    Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$AppId" `
        -Method PATCH -Body $finalizeBody -ContentType "application/json" -StepDescription "Finalize app (set committedContentVersion)" | Out-Null
    Write-Host "  [OK] App content is now active." -ForegroundColor Green
}

Write-Step "Loading configuration"
if (-not (Test-Path $ConfigPath)) {
    Write-Host "[FAILED] Config file not found: $ConfigPath" -ForegroundColor Red
    exit 1
}
$Config = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
Write-Host "  App: $($Config.AppName)" -ForegroundColor Gray
Write-Host "  Mode: $($Config.Mode)" -ForegroundColor Gray

try {
    Write-Step "Connecting to Microsoft Graph (app-only, certificate)"
    if (-not $Config.TenantId -or -not $Config.ClientId -or -not $Config.CertificateThumbprint) {
        throw "No Graph connection is configured. Open 'Settings...' in the GUI and fill in your Tenant ID, Client ID, and certificate first."
    }
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    $ctx = Get-MgContext -ErrorAction SilentlyContinue
    if ($null -eq $ctx -or $ctx.AuthType -ne 'AppOnly' -or $ctx.ClientId -ne $Config.ClientId) {
        Connect-MgGraph -TenantId $Config.TenantId -ClientId $Config.ClientId `
            -CertificateThumbprint $Config.CertificateThumbprint -NoWelcome -ErrorAction Stop
    }
    $ctx = Get-MgContext -ErrorAction Stop
    Write-Host "  [OK] Connected as '$($ctx.AppName)'" -ForegroundColor Green

    # =====================================================================
    # Detection rule (used in both Create and UpdateMetadata modes) - built
    # per the actual selected type. Schema for each type confirmed against
    # Microsoft's own documentation (win32LobAppProductCodeDetection,
    # win32LobAppFileSystemDetection, win32LobAppRegistryDetection) before
    # writing this, given past mistakes guessing at Graph property names
    # elsewhere in this script.
    # =====================================================================
    $detType = $Config.DetectionRule.Type
    switch ($detType) {
        "Msi" {
            $detectionRule = @{
                "@odata.type"           = "#microsoft.graph.win32LobAppProductCodeDetection"
                productCode             = $Config.DetectionRule.Msi_ProductCode
                productVersionOperator  = $Config.DetectionRule.Msi_VersionOperator
            }
            if ($Config.DetectionRule.Msi_VersionOperator -ne "notConfigured" -and $Config.DetectionRule.Msi_Version) {
                $detectionRule.productVersion = $Config.DetectionRule.Msi_Version
            }
        }
        "File" {
            $detectionRule = @{
                "@odata.type"          = "#microsoft.graph.win32LobAppFileSystemDetection"
                path                    = $Config.DetectionRule.File_Path
                fileOrFolderName        = $Config.DetectionRule.File_Name
                check32BitOn64System    = [bool]$Config.DetectionRule.File_Check32Bit
                detectionType           = $Config.DetectionRule.File_DetectionType
            }
            if ($Config.DetectionRule.File_DetectionType -in @("modifiedDate", "createdDate", "version", "sizeInMB")) {
                $detectionRule.operator = $Config.DetectionRule.File_Operator
                $detectionRule.detectionValue = $Config.DetectionRule.File_DetectionValue
            }
        }
        "Registry" {
            $detectionRule = @{
                "@odata.type"          = "#microsoft.graph.win32LobAppRegistryDetection"
                keyPath                 = $Config.DetectionRule.Reg_KeyPath
                check32BitOn64System    = [bool]$Config.DetectionRule.Reg_Check32Bit
                detectionType           = $Config.DetectionRule.Reg_DetectionType
            }
            if ($Config.DetectionRule.Reg_ValueName) { $detectionRule.valueName = $Config.DetectionRule.Reg_ValueName }
            if ($Config.DetectionRule.Reg_DetectionType -in @("string", "integer", "version")) {
                $detectionRule.operator = $Config.DetectionRule.Reg_Operator
                $detectionRule.detectionValue = $Config.DetectionRule.Reg_DetectionValue
            }
        }
        default {
            $detectionRule = @{
                "@odata.type"          = "#microsoft.graph.win32LobAppPowerShellScriptDetection"
                scriptContent          = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Config.DetectionRule.Script_Content))
                enforceSignatureCheck  = $false
                runAs32Bit             = $false
            }
        }
    }

    # =====================================================================
    # UPDATE METADATA MODE - existing app, no content re-upload
    # =====================================================================
    if ($Config.Mode -eq "UpdateMetadata") {
        Write-Step "Updating metadata for existing app $($Config.ExistingAppId)"

        # Only installExperience.runAsAccount (install context) is actually
        # excluded here - confirmed rejected by Graph specifically
        # ("The 'RunAsAccount' property cannot be patched for the
        # 'Win32LobApp' type."). Architecture, min OS, requirements, return
        # codes, and the rest of installExperience were PREVIOUSLY also
        # excluded here too, based on an unverified assumption that they'd
        # behave the same way runAsAccount does - but that assumption was
        # wrong. Confirmed otherwise, directly: Microsoft's own "Update
        # win32LobApp" PATCH documentation example explicitly includes
        # applicableArchitectures and the requirement fields, an official
        # Microsoft sample script (mggraph-intune-samples) successfully
        # PATCHes deviceRestartBehavior as part of installExperience, and
        # the Intune portal itself shows "Requirements" and "Detection
        # rules" as directly editable sections on an existing app. The GUI
        # only disables the Install context control now, not
        # Architecture/Min OS/Requirements/etc.
        # installExperience is a nested complex object, not a simple
        # collection - Graph likely replaces the WHOLE object on PATCH
        # rather than merging field-by-field (the same class of risk
        # already learned the hard way with relationships/updateRelationships
        # earlier this session). runAsAccount is explicitly included here,
        # even though the GUI keeps it locked/read-only, specifically so
        # this patch preserves its current value rather than risking Graph
        # silently resetting it just because it wasn't in this particular
        # request - matching how the official Microsoft sample script
        # includes it in its own installExperience patch for the same
        # reason. $Config.InstallContext still accurately reflects the
        # live value even though the control is locked, since the dialog's
        # auto-fetch populates it from Intune regardless of editability.
        $installExperiencePatch = @{
            runAsAccount          = if ($Config.InstallContext -eq "User") { "user" } else { "system" }
            deviceRestartBehavior = if ($Config.DeviceRestartBehavior) { $Config.DeviceRestartBehavior } else { "suppress" }
            maxRunTimeInMinutes   = if ($Config.InstallTimeMinutes) { [int]$Config.InstallTimeMinutes } else { 60 }
        }
        $returnCodesPatch = if (@($Config.ReturnCodes).Count -gt 0) {
            @($Config.ReturnCodes | ForEach-Object { @{ returnCode = [int]$_.returnCode; type = [string]$_.type } })
        } else {
            @(
                @{ returnCode = 0;    type = "success" }
                @{ returnCode = 1707; type = "success" }
                @{ returnCode = 3010; type = "softReboot" }
                @{ returnCode = 1641; type = "hardReboot" }
                @{ returnCode = 1618; type = "retry" }
            )
        }
        $patchBody = @{
            "@odata.type"             = "#microsoft.graph.win32LobApp"
            displayName               = $Config.AppName
            description               = $Config.Description
            publisher                 = $Config.Publisher
            installCommandLine        = $Config.InstallCommand
            uninstallCommandLine      = $Config.UninstallCommand
            detectionRules            = @($detectionRule)
            installExperience         = $installExperiencePatch
            returnCodes               = $returnCodesPatch
            minimumFreeDiskSpaceInMB  = if ($Config.MinDiskSpaceMB) { [int]$Config.MinDiskSpaceMB } else { 0 }
            minimumMemoryInMB         = if ($Config.MinMemoryMB) { [int]$Config.MinMemoryMB } else { 0 }
            minimumNumberOfProcessors = if ($Config.MinProcessors) { [int]$Config.MinProcessors } else { 0 }
            minimumCpuSpeedInMHz      = if ($Config.MinCpuSpeedMHz) { [int]$Config.MinCpuSpeedMHz } else { 0 }
            allowAvailableUninstall   = [bool]$Config.AllowAvailableUninstall
        }
        # minimumSupportedWindowsRelease (a plain string, e.g. "W11_21H2"),
        # not the legacy minimumSupportedOperatingSystem boolean bag -
        # Microsoft has REPLACED the old property with this one (confirmed
        # against the IntuneWin32App PowerShell module's own release
        # notes: "minimumSupportedOperatingSystem property is replaced by
        # minimumSupportedWindowsRelease"), and the old property's schema
        # has no Windows 11 values at all, so it's the only one that can
        # actually express one.
        $patchBody.minimumSupportedWindowsRelease = ConvertTo-GraphMinOsRelease -RawValue $Config.MinOSVersionKey
        # applicableArchitectures is the OLD, legacy single-value property -
        # confirmed live against the tenant that Graph rejects it outright
        # inside an Update PATCH ("can only be set via ODataAction:
        # enableApplicableArchitectures"), and that action itself 404s on
        # this endpoint ("Resource not found for the segment"), so there's
        # no working way to write it directly at all anymore. It's also
        # the property responsible for Intune's June 2025 ARM64
        # backward-compatibility change: a single "x64" written there gets
        # silently expanded to "x64,arm64" live (x64 apps are treated as
        # ARM64-emulation-compatible by default) - confirmed live via a
        # brand new app created through this same code path with only x64
        # selected. allowedArchitectures is the newer flags-based property
        # Microsoft added specifically to give exact, exclusive control
        # over this (confirmed in Microsoft's own current documentation:
        # "a non-null value for allowedArchitectures forces
        # applicableArchitectures to 'none'" - it takes over entirely) -
        # and unlike applicableArchitectures it holds a single value just
        # fine, not only a comma-joined list, and isn't subject to either
        # restriction above. So this now ALWAYS goes through
        # allowedArchitectures, whether one architecture is selected or
        # several - applicableArchitectures is never written by this app
        # at all any more, on Create or Update.
        $patchBody.allowedArchitectures = $Config.Architecture
        Add-OptionalStringField -Body $patchBody -GraphKey "owner" -Value $Config.Owner
        Add-OptionalStringField -Body $patchBody -GraphKey "developer" -Value $Config.Developer
        Add-OptionalStringField -Body $patchBody -GraphKey "informationUrl" -Value $Config.InformationUrl
        Add-OptionalStringField -Body $patchBody -GraphKey "privacyInformationUrl" -Value $Config.PrivacyUrl
        Add-OptionalStringField -Body $patchBody -GraphKey "notes" -Value $Config.Notes
        $patchBody = $patchBody | ConvertTo-Json -Depth 8

        Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($Config.ExistingAppId)" `
            -Method PATCH -Body $patchBody -ContentType "application/json" -StepDescription "Update app metadata" | Out-Null
        Write-Host "  [OK] Metadata updated (name, description, publisher, install/uninstall commands, detection, architecture, min OS, requirements, return codes, install experience, and any owner/developer/notes/URL fields you filled in)." -ForegroundColor Green

        # Always runs, even with zero dependencies checked - updateRelationships
        # has REPLACE semantics (it sets the relationship list to exactly what's
        # sent, not add-only), so this is the only way to actually clear the
        # LAST remaining dependency. Gating this behind "Count -gt 0" would
        # silently leave a stale dependency in place forever whenever someone
        # unchecks the one and only dependency an app has.
        Write-Step "Setting dependencies"
        try {
            $relationships = @($Config.DependencyAppIds | ForEach-Object {
                @{ "@odata.type" = "#microsoft.graph.mobileAppDependency"; targetId = $_; dependencyType = "autoInstall" }
            })
            $relBody = @{ relationships = $relationships } | ConvertTo-Json -Depth 8
            Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($Config.ExistingAppId)/updateRelationships" `
                -Method POST -Body $relBody -ContentType "application/json" -StepDescription "Set dependencies" | Out-Null
            Write-Host "  [OK] Set $(@($Config.DependencyAppIds).Count) dependency/dependencies." -ForegroundColor Green
        }
        catch {
            Write-Host "  [WARN] Could not set dependencies: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host "  The app was still updated successfully - set dependencies manually in the Intune portal if needed." -ForegroundColor Yellow
            }

        if ($Config.ReplaceContent -and $Config.PackagePath) {
            Write-Step "Replacing package content on the existing app"
            $packageInfo = Get-IntuneWinPackageInfo -PackagePath $Config.PackagePath
            Invoke-Win32AppContentUpload -AppId $Config.ExistingAppId -PackageInfo $packageInfo
        }

        Write-Step "Done"
        Write-Host "[OK] App metadata updated successfully!" -ForegroundColor Green
        Write-Result -Success $true -AppId $Config.ExistingAppId -ErrorMessage ""
        exit 0
    }

    # =====================================================================
    # CREATE MODE
    # =====================================================================

    $packageInfo = Get-IntuneWinPackageInfo -PackagePath $Config.PackagePath

    # ---- Create the app shell ----
    Write-Step "Creating app in Intune: $($Config.AppName)"

    $installExperience = @{
        runAsAccount            = if ($Config.InstallContext -eq "User") { "user" } else { "system" }
        # Falls back to "suppress" only if this field is somehow missing -
        # older configs built before this was exposed in the UI, or a
        # config built through some other path - rather than requiring
        # every single caller to always set it.
        deviceRestartBehavior   = if ($Config.DeviceRestartBehavior) { $Config.DeviceRestartBehavior } else { "suppress" }
        maxRunTimeInMinutes     = if ($Config.InstallTimeMinutes) { [int]$Config.InstallTimeMinutes } else { 60 }
    }

    # Falls back to the original fixed 5-code set if this wasn't supplied -
    # same reasoning as deviceRestartBehavior above.
    $returnCodesPayload = if (@($Config.ReturnCodes).Count -gt 0) {
        @($Config.ReturnCodes | ForEach-Object { @{ returnCode = [int]$_.returnCode; type = [string]$_.type } })
    } else {
        @(
            @{ returnCode = 0;    type = "success" }
            @{ returnCode = 1707; type = "success" }
            @{ returnCode = 3010; type = "softReboot" }
            @{ returnCode = 1641; type = "hardReboot" }
            @{ returnCode = 1618; type = "retry" }
        )
    }

    $createBody = @{
        "@odata.type"                    = "#microsoft.graph.win32LobApp"
        displayName                       = $Config.AppName
        description                       = $Config.Description
        publisher                          = $Config.Publisher
        installCommandLine                = $Config.InstallCommand
        uninstallCommandLine              = $Config.UninstallCommand
        # minimumSupportedWindowsRelease, not the legacy
        # minimumSupportedOperatingSystem boolean bag - see the matching
        # note next to the Update path's own $patchBody assignment above
        # in this same embedded script for why.
        minimumSupportedWindowsRelease    = ConvertTo-GraphMinOsRelease -RawValue $Config.MinOSVersionKey
        installExperience                 = $installExperience
        setupFilePath                     = $packageInfo.SetupFile
        fileName                          = $packageInfo.OriginalFileName
        detectionRules                    = @($detectionRule)
        returnCodes                       = $returnCodesPayload
        # Confirmed directly against Microsoft's own win32LobApp docs - all
        # four are top-level Int32 fields, 0 meaning "not required" (matches
        # the portal's own "No X required" wording for an unset value), and
        # allowAvailableUninstall is a top-level boolean defaulting to false.
        minimumFreeDiskSpaceInMB          = if ($Config.MinDiskSpaceMB) { [int]$Config.MinDiskSpaceMB } else { 0 }
        minimumMemoryInMB                 = if ($Config.MinMemoryMB) { [int]$Config.MinMemoryMB } else { 0 }
        minimumNumberOfProcessors         = if ($Config.MinProcessors) { [int]$Config.MinProcessors } else { 0 }
        minimumCpuSpeedInMHz              = if ($Config.MinCpuSpeedMHz) { [int]$Config.MinCpuSpeedMHz } else { 0 }
        allowAvailableUninstall           = [bool]$Config.AllowAvailableUninstall
    }
    # applicableArchitectures is the OLD, legacy single-value property -
    # confirmed live against the tenant that a brand new app created with
    # only "x64" selected here ends up showing "x64,arm64" live in Intune,
    # because Microsoft's June 2025 ARM64 backward-compatibility change
    # treats an x64-only app as ARM64-emulation-compatible by default when
    # this property is used. allowedArchitectures is the newer flags-based
    # property Microsoft added specifically to give exact, exclusive
    # control over this (confirmed in Microsoft's own current
    # documentation: "a non-null value for allowedArchitectures forces
    # applicableArchitectures to 'none'" - it takes over entirely), and
    # unlike applicableArchitectures it holds a single value just fine,
    # not only a comma-joined list. So this always goes through
    # allowedArchitectures now, whether one architecture is selected or
    # several - applicableArchitectures is never written by this app at
    # all any more, on Create or Update (see the matching note next to
    # the Update path's own $patchBody assignment for the Update-side
    # history of this).
    $createBody.allowedArchitectures = $Config.Architecture
    Add-OptionalStringField -Body $createBody -GraphKey "owner" -Value $Config.Owner
    Add-OptionalStringField -Body $createBody -GraphKey "developer" -Value $Config.Developer
    Add-OptionalStringField -Body $createBody -GraphKey "informationUrl" -Value $Config.InformationUrl
    Add-OptionalStringField -Body $createBody -GraphKey "privacyInformationUrl" -Value $Config.PrivacyUrl
    Add-OptionalStringField -Body $createBody -GraphKey "notes" -Value $Config.Notes
    $createBody = $createBody | ConvertTo-Json -Depth 8

    $app = Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps" `
        -Method POST -Body $createBody -ContentType "application/json" -StepDescription "Create app"
    $appId = $app.id
    Write-Host "  [OK] App created: $appId" -ForegroundColor Green

    Invoke-Win32AppContentUpload -AppId $appId -PackageInfo $packageInfo

    # ---- Dependencies ----
    if (@($Config.DependencyAppIds).Count -gt 0) {
        Write-Step "Setting dependencies"
        try {
            $relationships = @($Config.DependencyAppIds | ForEach-Object {
                @{ "@odata.type" = "#microsoft.graph.mobileAppDependency"; targetId = $_; dependencyType = "autoInstall" }
            })
            $relBody = @{ relationships = $relationships } | ConvertTo-Json -Depth 8
            Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$appId/updateRelationships" `
                -Method POST -Body $relBody -ContentType "application/json" -StepDescription "Set dependencies" | Out-Null
            Write-Host "  [OK] Set $(@($Config.DependencyAppIds).Count) dependency/dependencies." -ForegroundColor Green
        }
        catch {
            Write-Host "  [WARN] Could not set dependencies: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host "  The app and its content uploaded successfully - set dependencies manually in the Intune portal if needed." -ForegroundColor Yellow
        }
    }

    Write-Step "Done"
    Write-Host "[OK] App created and content uploaded successfully!" -ForegroundColor Green
    Write-Host "     App ID: $appId" -ForegroundColor White
    Write-Result -Success $true -AppId $appId -ErrorMessage ""
    exit 0
}
catch {
    Write-Host ""
    Write-Host "[FAILED] $($_.Exception.Message)" -ForegroundColor Red
    Write-Result -Success $false -AppId "" -ErrorMessage $_.Exception.Message
    exit 1
}

