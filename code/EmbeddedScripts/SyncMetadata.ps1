<#
.SYNOPSIS
    Fetches current Intune metadata AND current group assignments for
    MULTIPLE apps in one run, writing it all back as a single JSON array -
    used to bulk-sync the local catalog's metadata and requiredFor/
    availableFor/uninstallFor fields from what's actually live in Intune
    right now.
.DESCRIPTION
    Reuses the exact same field-extraction logic as Start-AppMetadataFetch
    (the single-app version used by Deploy to Intune's Update mode) rather
    than re-deriving it - that logic has already been through several
    rounds of real bug fixes this session (architecture handling
    specifically), and re-deriving it here risked reintroducing one of
    those exact bugs.

    Group assignments are resolved by the assignment's groupId, not by
    name - the same live-assignment lookup Start-AppMetadataFetch already
    does. That's what lets this pick up a group renamed in Entra ID: the
    assignment's groupId doesn't change on a rename, so this always
    reports Intune's CURRENT displayName for it, unlike Assign Groups /
    Batch Assign, which resolve a catalog group NAME against Entra ID and
    have no way to tell a rename apart from a deletion.
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
    param([bool]$Success, [string]$ErrorMessage, [array]$Results = @())
    $result = [pscustomobject]@{ success = $Success; error = $ErrorMessage; results = $Results }
    $result | ConvertTo-Json -Depth 10 | Set-Content -Path $Config.OutputResultPath -Encoding UTF8
}

# Invoke-MgGraphRequest under Windows PowerShell 5.1 has a known,
# reproducible bug decoding non-ASCII text in a JSON response body -
# confirmed live on Company Portal's own (fixed, Microsoft-authored)
# description, which came back with every curly apostrophe/quote/dash
# mangled into the exact "a UTF-8 byte sequence read back as Windows-1252"
# pattern (e.g. a right single quote, U+2019, turning into the three
# characters "a-circumflex, Euro sign, trademark"). Re-encoding as
# Windows-1252 and re-decoding the resulting bytes as UTF-8 reverses
# exactly that mistake. Gated on detecting the tell-tale byte pattern first
# (rather than applied unconditionally) so text that ISN'T mojibake is
# never touched, and the result is only trusted if it re-decodes clean (no
# U+FFFD replacement characters) - anything else returns the original text
# untouched.
function Repair-MojibakeText {
    param([string]$Text)
    if (-not $Text) { return $Text }
    if ($Text.IndexOf([char]0x00C3) -lt 0 -and $Text.IndexOf(([string]([char]0x00E2) + [char]0x20AC)) -lt 0) { return $Text }
    try {
        $bytes = [System.Text.Encoding]::GetEncoding(1252).GetBytes($Text)
        $repaired = [System.Text.Encoding]::UTF8.GetString($bytes)
        if ($repaired.IndexOf([char]0xFFFD) -lt 0) { return $repaired }
    } catch { }
    return $Text
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
            $isThrottled = $_.Exception.Message -match '429|TooManyRequests|Too Many Requests'
            $isTransient = $_.Exception.Message -match '503|ServiceUnavailable|Service Unavailable'
            $safeToRetryTransient = $isTransient -and $Method -ne "POST"
            if (($isThrottled -or $safeToRetryTransient) -and $attempt -lt $maxAttempts) {
                $waitSeconds = $attempt * $attempt * 3
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

Write-Step "Loading configuration"
if (-not (Test-Path $ConfigPath)) {
    Write-Host "[FAILED] Config file not found: $ConfigPath" -ForegroundColor Red
    exit 1
}
$Config = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$appList = @($Config.Apps)
Write-Host "  Apps to sync: $($appList.Count)" -ForegroundColor Gray

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
    Write-Host "  [OK] Connected." -ForegroundColor Green

    $maxConcurrency = [Math]::Max(1, [Math]::Min(6, $appList.Count))
    Write-Host "  Fetching $($appList.Count) app(s), up to $maxConcurrency at a time..." -ForegroundColor Gray

    # Runs each app's fetch in its own runspace instead of one at a time - a
    # 40+ app catalog audit/sync used to mean 40+ sequential rounds of
    # metadata + dependencies + group-assignment Graph calls, each waiting
    # on the network latency of the one before it. Windows PowerShell 5.1
    # (this embedded script's own host - see Start-PipelineProcess, which
    # launches powershell.exe, not pwsh) has no ForEach-Object -Parallel, so
    # a runspace pool is the compatible equivalent; capped at 6 concurrent
    # so this doesn't push Graph hard enough to trigger throttling beyond
    # what Invoke-GraphRequestDetailed's own 429 retry/backoff below already
    # absorbs for a single caller. Safe to parallelize freely - unlike
    # $Script:EmbeddedBatchAssignScript's Apply mode, this whole fetch is
    # read-only, with no shared mutable state (like a group-creation cache)
    # across apps that concurrent access could race on.
    #
    # Fully self-contained (its own Connect-MgGraph, Invoke-GraphRequestDetailed,
    # Get-HttpErrorDetail, Repair-MojibakeText, all redefined inside the
    # scriptblock) because a runspace does NOT share the calling script's
    # already-defined functions - only what's explicitly passed in or
    # defined inside it. Never calls Write-Host directly either - a
    # background runspace isn't reliably attached to a host UI that can
    # render it, so per-app progress/warning text comes back in the result
    # object instead and is printed by this (foreground, host-attached)
    # runspace once collected below.
    $perAppWork = {
        param($AppEntry, $TenantId, $ClientId, $CertThumbprint)

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
                    $graphTimer = [System.Diagnostics.Stopwatch]::StartNew()
                    if ($Body) {
                        $graphResult = Invoke-MgGraphRequest -Uri $Uri -Method $Method -Body $Body -ContentType $ContentType -ErrorAction Stop
                    }
                    else {
                        $graphResult = Invoke-MgGraphRequest -Uri $Uri -Method $Method -ErrorAction Stop
                    }
                    # parallel worker: recorded for the main script to log (Write-GraphLogFromInformation)
                    Write-Information -MessageData @{ IntunePackagerGraphLog = $true; Method = $Method; Uri = $Uri; Milliseconds = $graphTimer.ElapsedMilliseconds } -InformationAction SilentlyContinue
                    return $graphResult
                }
                catch {
                    $isThrottled = $_.Exception.Message -match '429|TooManyRequests|Too Many Requests'
                    $isTransient = $_.Exception.Message -match '503|ServiceUnavailable|Service Unavailable'
                    $safeToRetryTransient = $isTransient -and $Method -ne "POST"
                    if (($isThrottled -or $safeToRetryTransient) -and $attempt -lt $maxAttempts) {
                        Start-Sleep -Seconds ($attempt * $attempt * 3)
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

        function Repair-MojibakeText {
            param([string]$Text)
            if (-not $Text) { return $Text }
            if ($Text.IndexOf([char]0x00C3) -lt 0 -and $Text.IndexOf(([string]([char]0x00E2) + [char]0x20AC)) -lt 0) { return $Text }
            try {
                $bytes = [System.Text.Encoding]::GetEncoding(1252).GetBytes($Text)
                $repaired = [System.Text.Encoding]::UTF8.GetString($bytes)
                if ($repaired.IndexOf([char]0xFFFD) -lt 0) { return $repaired }
            } catch { }
            return $Text
        }

        $warnings = New-Object System.Collections.Generic.List[string]

        Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
        $ctx = Get-MgContext -ErrorAction SilentlyContinue
        if ($null -eq $ctx -or $ctx.AuthType -ne 'AppOnly' -or $ctx.ClientId -ne $ClientId) {
            Connect-MgGraph -TenantId $TenantId -ClientId $ClientId -CertificateThumbprint $CertThumbprint -NoWelcome -ErrorAction Stop
        }

        $app = Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($AppEntry.AppId)" -Method GET -StepDescription "Fetch metadata"

        $detectionRule = $null
        foreach ($rule in @($app.detectionRules)) {
            $odType = $rule.'@odata.type'
            if ($odType -eq '#microsoft.graph.win32LobAppPowerShellScriptDetection' -and $rule.scriptContent) {
                $scriptText = $null
                try { $scriptText = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($rule.scriptContent)) } catch { }
                $detectionRule = [pscustomobject]@{ Type = "Script"; Script_Content = $scriptText }
                break
            }
            elseif ($odType -eq '#microsoft.graph.win32LobAppProductCodeDetection') {
                $detectionRule = [pscustomobject]@{
                    Type                 = "Msi"
                    Msi_ProductCode      = $rule.productCode
                    Msi_VersionOperator  = $rule.productVersionOperator
                    Msi_Version          = $rule.productVersion
                }
                break
            }
            elseif ($odType -eq '#microsoft.graph.win32LobAppFileSystemDetection') {
                $detectionRule = [pscustomobject]@{
                    Type                = "File"
                    File_Path            = $rule.path
                    File_Name            = $rule.fileOrFolderName
                    File_Check32Bit      = $rule.check32BitOn64System
                    File_DetectionType   = $rule.detectionType
                    File_Operator        = $rule.operator
                    File_DetectionValue  = $rule.detectionValue
                }
                break
            }
            elseif ($odType -eq '#microsoft.graph.win32LobAppRegistryDetection') {
                $detectionRule = [pscustomobject]@{
                    Type                = "Registry"
                    Reg_KeyPath          = $rule.keyPath
                    Reg_ValueName        = $rule.valueName
                    Reg_Check32Bit       = $rule.check32BitOn64System
                    Reg_DetectionType    = $rule.detectionType
                    Reg_Operator         = $rule.operator
                    Reg_DetectionValue   = $rule.detectionValue
                }
                break
            }
        }

        $minOsPropName = $null
        if ($app.minimumSupportedOperatingSystem) {
            $minOsObj = $app.minimumSupportedOperatingSystem
            if ($minOsObj -is [System.Collections.IDictionary]) {
                foreach ($key in $minOsObj.Keys) {
                    if ($minOsObj[$key] -eq $true) { $minOsPropName = $key; break }
                }
            }
            else {
                foreach ($prop in $minOsObj.PSObject.Properties) {
                    if ($prop.Value -eq $true) { $minOsPropName = $prop.Name; break }
                }
            }
        }

        $archValue = ""
        if ($app.allowedArchitectures -and $app.allowedArchitectures -ne "none") {
            $archValue = $app.allowedArchitectures
        }
        elseif ($app.applicableArchitectures -and $app.applicableArchitectures -ne "none") {
            $archValue = $app.applicableArchitectures
        }
        if ($archValue) {
            $archTokensNorm = @($archValue -split '[,.]' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
            $archValue = (@("x86","x64","arm64") | Where-Object { $archTokensNorm -contains $_ }) -join ","
        }

        $depNames = @()
        try {
            $rels = Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($AppEntry.AppId)/relationships" -Method GET -StepDescription "Fetch dependencies"
            $depNames = @($rels.value | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.mobileAppDependency' -and $_.targetType -eq 'child' } | ForEach-Object { $_.targetDisplayName } | Where-Object { $_ })
        }
        catch {
            $warnings.Add("Could not fetch dependencies: $($_.Exception.Message)")
        }

        $requiredGroupNames = @()
        $availableGroupNames = @()
        $uninstallGroupNames = @()
        $groupFetchOk = $true
        try {
            $currentAssignments = Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($AppEntry.AppId)/assignments" -Method GET -StepDescription "Fetch group assignments"
            foreach ($a in @($currentAssignments.value)) {
                if ($a.target.'@odata.type' -ne '#microsoft.graph.groupAssignmentTarget') { continue }
                $gid = $a.target.groupId
                $groupDisplayName = $gid
                try {
                    $groupInfo = Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/v1.0/groups/$gid`?`$select=displayName" -Method GET -StepDescription "Resolve group name"
                    if ($groupInfo.displayName) { $groupDisplayName = $groupInfo.displayName }
                }
                # Left as its ID, the group compared as a difference that
                # isn't one, and a Pull wrote the ID into the catalog. The
                # lists are then not Intune's answer - same as a failed read.
                catch {
                    $groupFetchOk = $false
                    $warnings.Add("Could not read the name of assigned group $gid - groups not compared: $($_.Exception.Message)")
                }
                switch ($a.intent) {
                    "required"  { $requiredGroupNames += $groupDisplayName }
                    "available" { $availableGroupNames += $groupDisplayName }
                    "uninstall" { $uninstallGroupNames += $groupDisplayName }
                }
            }
        }
        catch {
            $groupFetchOk = $false
            $warnings.Add("Could not fetch group assignments: $($_.Exception.Message)")
        }

        $metadata = [pscustomobject]@{
            description      = Repair-MojibakeText $app.description
            publisher        = Repair-MojibakeText $app.publisher
            owner            = Repair-MojibakeText $app.owner
            developer        = Repair-MojibakeText $app.developer
            informationUrl   = $app.informationUrl
            privacyUrl       = $app.privacyInformationUrl
            notes            = Repair-MojibakeText $app.notes
            installCommand   = $app.installCommandLine
            uninstallCommand = $app.uninstallCommandLine
            architecture     = $archValue
            installContext   = $app.installExperience.runAsAccount
            minOSKey         = $minOsPropName
            detectionRule    = $detectionRule
            dependencies     = $depNames
            minDiskSpaceMB          = $app.minimumFreeDiskSpaceInMB
            minMemoryMB             = $app.minimumMemoryInMB
            minProcessors           = $app.minimumNumberOfProcessors
            minCpuSpeedMHz          = $app.minimumCpuSpeedInMHz
            installTimeMinutes      = $app.installExperience.maxRunTimeInMinutes
            deviceRestartBehavior   = $app.installExperience.deviceRestartBehavior
            allowAvailableUninstall = $app.allowAvailableUninstall
            returnCodes             = if (@($app.returnCodes).Count -gt 0) { @($app.returnCodes | ForEach-Object { [pscustomobject]@{ returnCode = $_.returnCode; type = $_.type } }) } else { @() }
        }

        return [pscustomobject]@{
            AppName              = $AppEntry.AppName
            Success              = $true
            Metadata             = $metadata
            OdataType            = $app.'@odata.type'
            DisplayVersion       = [string]$app.displayVersion
            RequiredGroupNames   = $requiredGroupNames
            AvailableGroupNames  = $availableGroupNames
            UninstallGroupNames  = $uninstallGroupNames
            GroupFetchOk         = $groupFetchOk
            Error                = ""
            Warnings             = $warnings.ToArray()
        }
    }

    $pool = [runspacefactory]::CreateRunspacePool(1, $maxConcurrency)
    $pool.Open()
    $jobs = New-Object System.Collections.Generic.List[object]
    $allResults = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($appEntry in $appList) {
            $ps = [powershell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript($perAppWork).AddParameter('AppEntry', $appEntry).AddParameter('TenantId', $Config.TenantId).AddParameter('ClientId', $Config.ClientId).AddParameter('CertThumbprint', $Config.CertificateThumbprint)
            $jobs.Add([pscustomobject]@{ Ps = $ps; Handle = $ps.BeginInvoke(); AppEntry = $appEntry })
        }

        $doneCount = 0
        foreach ($job in $jobs) {
            $doneCount++
            $output = $null
            $workerError = $null
            try {
                $output = $job.Ps.EndInvoke($job.Handle)
            }
            catch {
                # EndInvoke() itself throws for an unhandled terminating
                # error inside the runspace (a plain `throw`, which is how
                # Invoke-GraphRequestDetailed reports a failed Graph call
                # here) rather than only populating $job.Ps.Streams.Error -
                # confirmed directly against pwsh, not an assumption. Same
                # "prefer Streams.Error, fall back to the catch's own
                # exception" precedence already used by this app's other
                # runspace caller (Start-AppMetadataFetch's -OnComplete).
                $workerError = $_.Exception.Message
            }
            if (Get-Command Write-GraphLogFromInformation -ErrorAction SilentlyContinue) { Write-GraphLogFromInformation $job.Ps.Streams.Information }
            if (-not $workerError -and $job.Ps.Streams.Error.Count -gt 0) {
                $workerError = [string]$job.Ps.Streams.Error[0]
            }

            if ($workerError) {
                Write-Host ""
                Write-Host "[$doneCount/$($jobs.Count)] $($job.AppEntry.AppName)" -ForegroundColor Cyan
                Write-Host "  [FAILED] $workerError" -ForegroundColor Red
                $allResults.Add([pscustomobject]@{ AppName = $job.AppEntry.AppName; Success = $false; Metadata = $null; OdataType = ""; DisplayVersion = ""; RequiredGroupNames = @(); AvailableGroupNames = @(); UninstallGroupNames = @(); GroupFetchOk = $false; Error = $workerError })
                $job.Ps.Dispose()
                continue
            }

            $oneResult = if ($output -and $output.Count -gt 0) { $output[0] } else { $null }
            $job.Ps.Dispose()
            if (-not $oneResult) {
                $allResults.Add([pscustomobject]@{ AppName = $job.AppEntry.AppName; Success = $false; Metadata = $null; OdataType = ""; DisplayVersion = ""; RequiredGroupNames = @(); AvailableGroupNames = @(); UninstallGroupNames = @(); GroupFetchOk = $false; Error = "No result returned from worker runspace." })
                continue
            }

            Write-Host ""
            Write-Host "[$doneCount/$($jobs.Count)] $($oneResult.AppName)" -ForegroundColor Cyan
            foreach ($w in @($oneResult.Warnings)) { Write-Host "  [!] $w" -ForegroundColor Yellow }
            Write-Host "  [OK] Synced." -ForegroundColor Green
            $allResults.Add($oneResult)
        }
    }
    finally {
        $pool.Close()
        $pool.Dispose()
    }

    Write-Step "Done"
    $okCount = @($allResults | Where-Object { $_.Success }).Count
    Write-Host "$okCount of $($appList.Count) synced successfully." -ForegroundColor $(if ($okCount -eq $appList.Count) { "Green" } else { "Yellow" })
    Write-Result -Success $true -ErrorMessage "" -Results $allResults.ToArray()
    exit 0
}
catch {
    Write-Host ""
    Write-Host "[FAILED] $($_.Exception.Message)" -ForegroundColor Red
    Write-Result -Success $false -ErrorMessage $_.Exception.Message -Results @()
    exit 1
}

