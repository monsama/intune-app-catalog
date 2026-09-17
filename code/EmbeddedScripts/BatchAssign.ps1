<#
.SYNOPSIS
    Batch version of the per-app "Assign Groups to Intune" feature: checks
    (or applies) group assignments for every app in the catalog that has an
    App ID and at least one group set, in one pass.
.DESCRIPTION
    Reads a JSON config listing multiple apps (AppId, AppName, RequiredGroups,
    AvailableGroups, UninstallGroups) and a Mode:
      - "Preview": read-only. Fetches each app's CURRENT Intune assignments
        and computes what would be added/removed to match the catalog - does
        NOT create groups or change any assignment. Safe to run any time.
      - "Apply": does the real work - ensures every referenced group exists
        (creating any that don't), then sets each app's assignments to match
        the catalog exactly, same as the per-app version, just looped.
    Writes a result JSON (success/data/error) to -OutputResultPath, where
    data is an array of { AppName, AppId, ToAdd, ToRemove } - used for both
    the preview display and the post-apply summary.
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
    param([bool]$Success, [string]$ErrorMessage, $Data)
    $result = [pscustomobject]@{
        success = $Success
        error   = $ErrorMessage
        data    = $Data
    }
    $result | ConvertTo-Json -Depth 10 | Set-Content -Path $Config.OutputResultPath -Encoding UTF8
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

# Turns Graph's raw "An inclusion intent already exists for group id: ..."
# error (thrown when the SAME group ends up in the assignment body with more
# than one intent - required/available/uninstall are all "inclusion"
# intents, and Intune only allows one per group per app, same restriction
# the admin console itself enforces) into something the user can actually
# act on: which group, in plain catalog terms, and what to go fix. Falls
# through to the raw message unchanged for any other kind of failure -
# this only recognizes this one specific, previously-confirmed error shape.
function Get-FriendlyAssignError {
    param([string]$RawError, [string]$AppName, [hashtable]$GroupNameById)
    if ($RawError -match "inclusion intent already exists for group id: '([0-9a-fA-F-]{36})'") {
        $gid = $Matches[1]
        $gName = if ($GroupNameById.ContainsKey($gid)) { $GroupNameById[$gid] } else { $gid }
        return "Intune rejected the assignment for `"$AppName`": the group `"$gName`" is set in more than one of Required/Available/Uninstall for this app, and Intune only allows ONE assignment intent per group per app. Open `"$AppName`" in Edit app, remove `"$gName`" from all but one of those three lists, then try again.`n`n(Raw Intune error: $RawError)"
    }
    return $RawError
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

Write-Step "Loading configuration"
if (-not (Test-Path $ConfigPath)) {
    Write-Host "[FAILED] Config file not found: $ConfigPath" -ForegroundColor Red
    exit 1
}
$Config = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
Write-Host "  Mode: $($Config.Mode)" -ForegroundColor Gray
Write-Host "  Apps: $(@($Config.Apps).Count)" -ForegroundColor Gray

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

    # $groupIdCache/Resolve-GroupId moved into the Apply-mode branch below,
    # right next to the only mode that actually uses them now - Preview
    # never touches group creation/lookup by id at all (see that branch's
    # own comment).
    $allResults = New-Object System.Collections.Generic.List[object]
    $appList = @($Config.Apps)
    $totalApps = $appList.Count
    $appIndex = 0

    if ($Config.Mode -eq "Preview") {
        # Preview is fully read-only (no group creation, no assignment
        # writes - see the Apply-only branch below) with no shared mutable
        # state across apps, unlike Apply's $groupIdCache (used to dedupe
        # group lookups/creation) - so it's safe to fetch every app's
        # current assignments concurrently instead of one at a time. Same
        # runspace-pool approach and reasoning as
        # $Script:EmbeddedSyncMetadataScript's own per-app fetch (see its
        # comment for why a runspace pool, not ForEach-Object -Parallel,
        # and why each runspace is fully self-contained). Apply mode is
        # deliberately left as the original sequential loop below,
        # unchanged - concurrent group creation for a group name shared by
        # multiple apps would race two runspaces into creating it twice.
        $maxConcurrency = [Math]::Max(1, [Math]::Min(6, $appList.Count))
        Write-Host "  Checking $($appList.Count) app(s), up to $maxConcurrency at a time..." -ForegroundColor Gray

        $perAppPreview = {
            param($App, $TenantId, $ClientId, $CertThumbprint)

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
                        Write-Information -MessageData @{ IntunePackagerGraphLog = $true; Method = $Method; Uri = $Uri; Milliseconds = $graphTimer.ElapsedMilliseconds; ErrorText = $_.Exception.Message; Detail = [string]$detail } -InformationAction SilentlyContinue
                        $msg = "$StepDescription failed [$Method $Uri]: $($_.Exception.Message)"
                        if ($detail) { $msg += "`nResponse body: $detail" }
                        throw $msg
                    }
                }
            }

            Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
            $ctx = Get-MgContext -ErrorAction SilentlyContinue
            if ($null -eq $ctx -or $ctx.AuthType -ne 'AppOnly' -or $ctx.ClientId -ne $ClientId) {
                Connect-MgGraph -TenantId $TenantId -ClientId $ClientId -CertificateThumbprint $CertThumbprint -NoWelcome -ErrorAction Stop
            }

            $currentAssignments = Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($App.AppId)/assignments" -Method GET -StepDescription "Get current assignments for $($App.AppName)"
            $currentByGroup = @{}
            foreach ($a in @($currentAssignments.value)) {
                if ($a.target.'@odata.type' -eq '#microsoft.graph.groupAssignmentTarget') {
                    $gid = $a.target.groupId
                    $gName = $gid
                    try {
                        $gi = Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/v1.0/groups/$gid`?`$select=displayName" -Method GET -StepDescription "Resolve current assignment's group name"
                        if ($gi.displayName) { $gName = $gi.displayName }
                    } catch { }
                    $currentByGroup[$gName] = $a.intent
                }
            }

            $newGroupSet = @{}
            foreach ($g in @($App.RequiredGroups))  { if (-not [string]::IsNullOrWhiteSpace($g)) { $newGroupSet[$g] = "required" } }
            foreach ($g in @($App.AvailableGroups)) { if (-not [string]::IsNullOrWhiteSpace($g)) { $newGroupSet[$g] = "available" } }
            foreach ($g in @($App.UninstallGroups)) { if (-not [string]::IsNullOrWhiteSpace($g)) { $newGroupSet[$g] = "uninstall" } }

            $toRemove = @($currentByGroup.Keys | Where-Object { -not $newGroupSet.ContainsKey($_) -or $newGroupSet[$_] -ne $currentByGroup[$_] })
            $toAdd    = @($newGroupSet.Keys | Where-Object { -not $currentByGroup.ContainsKey($_) -or $currentByGroup[$_] -ne $newGroupSet[$_] })

            return [pscustomobject]@{
                AppName  = $App.AppName
                AppId    = $App.AppId
                ToAdd    = @($toAdd | ForEach-Object { "[$($newGroupSet[$_])] $_" })
                ToRemove = @($toRemove | ForEach-Object { "[$($currentByGroup[$_])] $_" })
            }
        }

        $pool = [runspacefactory]::CreateRunspacePool(1, $maxConcurrency)
        $pool.Open()
        $jobs = New-Object System.Collections.Generic.List[object]
        try {
            foreach ($app in $appList) {
                $ps = [powershell]::Create()
                $ps.RunspacePool = $pool
                [void]$ps.AddScript($perAppPreview).AddParameter('App', $app).AddParameter('TenantId', $Config.TenantId).AddParameter('ClientId', $Config.ClientId).AddParameter('CertThumbprint', $Config.CertificateThumbprint)
                $jobs.Add([pscustomobject]@{ Ps = $ps; Handle = $ps.BeginInvoke(); App = $app })
            }

            foreach ($job in $jobs) {
                $appIndex++
                $output = $null
                $workerError = $null
                try {
                    $output = $job.Ps.EndInvoke($job.Handle)
                }
                catch {
                    # EndInvoke() itself throws for an unhandled terminating
                    # error inside the runspace (a plain `throw`, which is
                    # how Invoke-GraphRequestDetailed reports a failed Graph
                    # call here) rather than only populating
                    # $job.Ps.Streams.Error - confirmed directly against
                    # pwsh, not an assumption. Same "prefer Streams.Error,
                    # fall back to the catch's own exception" precedence
                    # already used by this app's other runspace caller
                    # (Start-AppMetadataFetch's -OnComplete).
                    $workerError = $_.Exception.Message
                }
                if (Get-Command Write-GraphLogFromInformation -ErrorAction SilentlyContinue) { Write-GraphLogFromInformation $job.Ps.Streams.Information }
                if (-not $workerError -and $job.Ps.Streams.Error.Count -gt 0) {
                    $workerError = [string]$job.Ps.Streams.Error[0]
                }

                # Same as the original sequential loop - a single app's
                # Graph failure aborts the whole preview rather than
                # returning partial results, so this rethrows on the main
                # thread instead of silently degrading (the pool is closed
                # in the finally below either way).
                if ($workerError) {
                    $job.Ps.Dispose()
                    throw $workerError
                }

                $oneResult = if ($output -and $output.Count -gt 0) { $output[0] } else { $null }
                $job.Ps.Dispose()
                if (-not $oneResult) { throw "No result returned for `"$($job.App.AppName)`"." }

                Write-Step "[$appIndex/$totalApps] $($oneResult.AppName)"
                if ($oneResult.ToRemove.Count -eq 0 -and $oneResult.ToAdd.Count -eq 0) {
                    Write-Host "  (no change)" -ForegroundColor Gray
                }
                foreach ($g in $oneResult.ToRemove) { Write-Host "  - $g" -ForegroundColor Yellow }
                foreach ($g in $oneResult.ToAdd)    { Write-Host "  + $g" -ForegroundColor Green }
                $allResults.Add($oneResult)
            }
        }
        finally {
            $pool.Close()
            $pool.Dispose()
        }
    }
    else {
        # Cache group name -> id lookups across apps (many apps share groups
        # like "Deploy Dev Workplace", so this avoids repeating the same GET
        # call) - shared mutable state across apps is exactly why this
        # (Apply) mode stays a plain sequential loop, unlike Preview above.
        $groupIdCache = @{}

        function Resolve-GroupId {
            param([string]$GroupName, [bool]$CreateIfMissing)
            if ($groupIdCache.ContainsKey($GroupName)) { return $groupIdCache[$GroupName] }
            $escapedName = $GroupName.Replace("'", "''")
            $encodedFilter = [Uri]::EscapeDataString("displayName eq '$escapedName'")
            $existing = Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=$encodedFilter&`$select=id,displayName" -Method GET -StepDescription "Look up group '$GroupName'"
            if ($existing.value -and $existing.value.Count -gt 0) {
                $groupIdCache[$GroupName] = $existing.value[0].id
                return $existing.value[0].id
            }
            if ($CreateIfMissing) {
                $mailNickname = ($GroupName -replace '[^a-zA-Z0-9]', '')
                if ($mailNickname.Length -gt 60) { $mailNickname = $mailNickname.Substring(0, 60) }
                if ([string]::IsNullOrWhiteSpace($mailNickname)) { $mailNickname = "grp" + (Get-Random -Minimum 1000 -Maximum 9999) }
                $groupBody = @{
                    displayName     = $GroupName
                    mailEnabled     = $false
                    mailNickname    = $mailNickname
                    securityEnabled = $true
                    "@odata.type"   = "#microsoft.graph.group"
                } | ConvertTo-Json -Depth 5
                $newGroup = Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/v1.0/groups" -Method POST -Body $groupBody -StepDescription "Create group '$GroupName'"
                $groupIdCache[$GroupName] = $newGroup.id
                Write-Host "  [+] Created group: $GroupName" -ForegroundColor Green
                return $newGroup.id
            }
            $groupIdCache[$GroupName] = $null
            return $null
        }

        foreach ($app in $appList) {
            $appIndex++
            Write-Step "[$appIndex/$totalApps] $($app.AppName)"

            $currentAssignments = Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($app.AppId)/assignments" -Method GET -StepDescription "Get current assignments for $($app.AppName)"
            $currentByGroup = @{}
            foreach ($a in @($currentAssignments.value)) {
                if ($a.target.'@odata.type' -eq '#microsoft.graph.groupAssignmentTarget') {
                    $gid = $a.target.groupId
                    $gName = $gid
                    try {
                        $gi = Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/v1.0/groups/$gid`?`$select=displayName" -Method GET -StepDescription "Resolve current assignment's group name"
                        if ($gi.displayName) { $gName = $gi.displayName }
                    } catch { }
                    $currentByGroup[$gName] = $a.intent
                }
            }

            $newGroupSet = @{}
            foreach ($g in @($app.RequiredGroups))  { if (-not [string]::IsNullOrWhiteSpace($g)) { $newGroupSet[$g] = "required" } }
            foreach ($g in @($app.AvailableGroups)) { if (-not [string]::IsNullOrWhiteSpace($g)) { $newGroupSet[$g] = "available" } }
            foreach ($g in @($app.UninstallGroups)) { if (-not [string]::IsNullOrWhiteSpace($g)) { $newGroupSet[$g] = "uninstall" } }

            $toRemove = @($currentByGroup.Keys | Where-Object { -not $newGroupSet.ContainsKey($_) -or $newGroupSet[$_] -ne $currentByGroup[$_] })
            $toAdd    = @($newGroupSet.Keys | Where-Object { -not $currentByGroup.ContainsKey($_) -or $currentByGroup[$_] -ne $newGroupSet[$_] })

            if ($toRemove.Count -eq 0 -and $toAdd.Count -eq 0) {
                Write-Host "  (no change)" -ForegroundColor Gray
            }
            foreach ($g in $toRemove) { Write-Host "  - [$($currentByGroup[$g])] $g" -ForegroundColor Yellow }
            foreach ($g in $toAdd)    { Write-Host "  + [$($newGroupSet[$g])] $g" -ForegroundColor Green }

            $allResults.Add([pscustomobject]@{
                AppName  = $app.AppName
                AppId    = $app.AppId
                ToAdd    = @($toAdd | ForEach-Object { "[$($newGroupSet[$_])] $_" })
                ToRemove = @($toRemove | ForEach-Object { "[$($currentByGroup[$_])] $_" })
            })

            $assignments = @()
            foreach ($gName in @($newGroupSet.Keys)) { Resolve-GroupId -GroupName $gName -CreateIfMissing $true | Out-Null }
            foreach ($g in @($newGroupSet.Keys)) {
                if ($groupIdCache[$g]) { $assignments += @{ "@odata.type" = "#microsoft.graph.mobileAppAssignment"; intent = $newGroupSet[$g]; target = @{ "@odata.type" = "#microsoft.graph.groupAssignmentTarget"; groupId = $groupIdCache[$g] } } }
            }

            $assignBody = [string](@{ mobileAppAssignments = @($assignments) } | ConvertTo-Json -Depth 10)
            try {
                Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($app.AppId)/assign" -Method POST -Body $assignBody -ContentType "application/json" -StepDescription "Assign $($app.AppName)" | Out-Null
            }
            catch {
                $groupNameById = @{}
                foreach ($name in $groupIdCache.Keys) { if ($groupIdCache[$name]) { $groupNameById[$groupIdCache[$name]] = $name } }
                throw (Get-FriendlyAssignError -RawError $_.Exception.Message -AppName $app.AppName -GroupNameById $groupNameById)
            }
            Write-Host "  [OK] Applied." -ForegroundColor Green
        }
    }

    Write-Step "Done"
    if ($Config.Mode -eq "Preview") {
        Write-Host "[OK] Preview complete - $totalApps app(s) checked, nothing was changed." -ForegroundColor Green
    }
    else {
        Write-Host "[OK] Applied changes to $totalApps app(s)." -ForegroundColor Green
    }
    Write-Result -Success $true -ErrorMessage "" -Data $allResults.ToArray()
    exit 0
}
catch {
    Write-Host ""
    Write-Host "[FAILED] $($_.Exception.Message)" -ForegroundColor Red
    Write-Result -Success $false -ErrorMessage $_.Exception.Message -Data $null
    exit 1
}

