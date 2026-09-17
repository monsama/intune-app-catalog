<#
.SYNOPSIS
    Targeted, single-app version of the bulk group-assignment step: ensures
    the Entra ID groups an app's requiredFor/
    availableFor/uninstallFor reference actually exist, then sets that ONE
    app's Intune assignments to match exactly - Required, Available, and
    Uninstall. Does not touch group membership or any other app.
.DESCRIPTION
    Reads a JSON config (written by the GUI) with the app's Intune App ID and
    its three group-name lists. For each distinct group name across all three
    lists, creates a Microsoft 365 security group with that display name if
    one doesn't already exist (idempotent - existing groups are left alone).
    Then replaces the app's assignment list in Intune with exactly the groups
    named, one assignment per group per intent.
    Writes a result JSON (success/groupsCreated/error) to -OutputResultPath.
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
    param([bool]$Success, [int]$GroupsCreated, [string]$ErrorMessage)
    $result = [pscustomobject]@{
        success       = $Success
        groupsCreated = $GroupsCreated
        error         = $ErrorMessage
    }
    $result | ConvertTo-Json | Set-Content -Path $Config.OutputResultPath -Encoding UTF8
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
Write-Host "  App ID: $($Config.AppId)" -ForegroundColor Gray
Write-Host "  Required groups : $(@($Config.RequiredGroups).Count)" -ForegroundColor Gray
Write-Host "  Available groups: $(@($Config.AvailableGroups).Count)" -ForegroundColor Gray
Write-Host "  Uninstall groups: $(@($Config.UninstallGroups).Count)" -ForegroundColor Gray

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

    # ---- Ensure every referenced group exists ----
    Write-Step "Ensuring groups exist"
    $allGroupNames = @($Config.RequiredGroups) + @($Config.AvailableGroups) + @($Config.UninstallGroups) | Select-Object -Unique
    $groupIdByName = @{}
    $createdCount = 0

    foreach ($groupName in $allGroupNames) {
        if ([string]::IsNullOrWhiteSpace($groupName)) { continue }
        $escapedName = $groupName.Replace("'", "''")
        # The filter VALUE must be percent-encoded, not just quote-escaped -
        # a raw & (e.g. in "Deploy I&O Workplace") gets parsed by the server
        # as a query-string separator otherwise, silently truncating the
        # filter clause mid-value and producing a confusing 400 error.
        $encodedFilter = [Uri]::EscapeDataString("displayName eq '$escapedName'")
        $existing = Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=$encodedFilter&`$select=id,displayName" -Method GET -StepDescription "Look up group '$groupName'"
        if ($existing.value -and $existing.value.Count -gt 0) {
            $groupIdByName[$groupName] = $existing.value[0].id
            Write-Host "  [=] Exists: $groupName" -ForegroundColor DarkGray
        }
        else {
            $mailNickname = ($groupName -replace '[^a-zA-Z0-9]', '')
            if ($mailNickname.Length -gt 60) { $mailNickname = $mailNickname.Substring(0, 60) }
            if ([string]::IsNullOrWhiteSpace($mailNickname)) { $mailNickname = "grp" + (Get-Random -Minimum 1000 -Maximum 9999) }
            $groupBody = @{
                displayName     = $groupName
                mailEnabled     = $false
                mailNickname    = $mailNickname
                securityEnabled = $true
                "@odata.type"   = "#microsoft.graph.group"
            } | ConvertTo-Json -Depth 5
            $newGroup = Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/v1.0/groups" -Method POST -Body $groupBody -StepDescription "Create group '$groupName'"
            $groupIdByName[$groupName] = $newGroup.id
            $createdCount++
            Write-Host "  [+] Created: $groupName" -ForegroundColor Green
        }
    }

    # ---- Show current assignments before changing anything ----
    Write-Step "Checking current assignments (before making any change)"
    $currentAssignments = Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($Config.AppId)/assignments" -Method GET -StepDescription "Get current assignments"
    $currentByGroup = @{}   # groupId -> intent, for groups only (skips allDevices/allLicensedUsers targets)
    foreach ($a in @($currentAssignments.value)) {
        $targetType = $a.target.'@odata.type'
        if ($targetType -eq '#microsoft.graph.groupAssignmentTarget') {
            $gid = $a.target.groupId
            $groupDisplayName = $gid
            try {
                $groupInfo = Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/v1.0/groups/$gid`?`$select=displayName" -Method GET -StepDescription "Resolve current assignment's group name"
                if ($groupInfo.displayName) { $groupDisplayName = $groupInfo.displayName }
            } catch { }
            $currentByGroup[$groupDisplayName] = $a.intent
            Write-Host "  currently: [$($a.intent)] $groupDisplayName" -ForegroundColor Gray
        }
        else {
            Write-Host "  currently: [$($a.intent)] (non-group target: $targetType)" -ForegroundColor Gray
        }
    }
    if (@($currentAssignments.value).Count -eq 0) {
        Write-Host "  (no existing assignments on this app)" -ForegroundColor Gray
    }

    # Blank/whitespace entries skipped here, same as the group-creation loop
    # above already skips them ([string]::IsNullOrWhiteSpace($groupName)) -
    # left in, a blank would become a real key in $newGroupSet and show up
    # in $toAdd below (Preview promising "will add" for it), but never gets
    # an actual assignment built later since $groupIdByName only ever has
    # entries for groups that were actually looked up/created, silently
    # under-delivering what Preview said would happen.
    $newGroupSet = @{}
    foreach ($g in @($Config.RequiredGroups))  { if (-not [string]::IsNullOrWhiteSpace($g)) { $newGroupSet[$g] = "required" } }
    foreach ($g in @($Config.AvailableGroups)) { if (-not [string]::IsNullOrWhiteSpace($g)) { $newGroupSet[$g] = "available" } }
    foreach ($g in @($Config.UninstallGroups)) { if (-not [string]::IsNullOrWhiteSpace($g)) { $newGroupSet[$g] = "uninstall" } }

    # Diffs on INTENT too, not just presence of the name - a group that's
    # currently "required" but the catalog now wants "available" (moving a
    # group between Required/Available/Uninstall is a normal, supported
    # catalog edit) is a real change: Graph doesn't offer an in-place
    # "change this assignment's intent" - it's remove-the-old-intent,
    # add-the-new-one. Missing the intent check here used to make that
    # exact case invisible: same name present in both sets meant it was
    # counted as neither toAdd nor toRemove, so the diff (and this app's
    # own $btnApply gate in the GUI, which enables only when either count
    # is nonzero) silently reported "no change" even though Intune still
    # had the group under the OLD intent.
    $toRemove = @($currentByGroup.Keys | Where-Object { -not $newGroupSet.ContainsKey($_) -or $newGroupSet[$_] -ne $currentByGroup[$_] })
    $toAdd    = @($newGroupSet.Keys | Where-Object { -not $currentByGroup.ContainsKey($_) -or $currentByGroup[$_] -ne $newGroupSet[$_] })
    if ($toRemove.Count -gt 0) {
        Write-Host "  WILL BE REMOVED:" -ForegroundColor Yellow
        foreach ($g in $toRemove) { Write-Host "    - [$($currentByGroup[$g])] $g" -ForegroundColor Yellow }
    }
    if ($toAdd.Count -gt 0) {
        Write-Host "  WILL BE ADDED:" -ForegroundColor Green
        foreach ($g in $toAdd) { Write-Host "    + [$($newGroupSet[$g])] $g" -ForegroundColor Green }
    }
    if ($toRemove.Count -eq 0 -and $toAdd.Count -eq 0) {
        Write-Host "  No change - current assignments already match." -ForegroundColor Gray
    }

    # ---- Build and apply the assignment list for this app only ----
    Write-Step "Setting assignments for this app"
    # Plain array, not a List<T> - matches the pattern already used successfully
    # for dependency relationships later in this script. Avoids any ambiguity
    # ConvertTo-Json or Graph's own deserialization might have with a
    # System.Collections.Generic.List[object] specifically.
    #
    # Built from $newGroupSet (one entry per DISTINCT group name, already
    # deduped above for the toAdd/toRemove preview), not by re-walking
    # Config.RequiredGroups/AvailableGroups/UninstallGroups separately - a
    # group listed in more than one of those three buckets used to produce
    # TWO assignment entries for the same groupId with different intents,
    # which Graph's /assign endpoint rejects outright ("An inclusion intent
    # already exists for group id: ..."), failing the ENTIRE app's
    # assignment even though the preview just above had reported "no
    # change". Going through $newGroupSet guarantees exactly one entry per
    # group, with the same intent the preview already showed (last bucket
    # wins - uninstall, then available, then required, matching the order
    # $newGroupSet was built in above).
    $assignments = @()
    foreach ($g in @($newGroupSet.Keys)) {
        if ($groupIdByName.ContainsKey($g)) {
            $assignments += @{ "@odata.type" = "#microsoft.graph.mobileAppAssignment"; intent = $newGroupSet[$g]; target = @{ "@odata.type" = "#microsoft.graph.groupAssignmentTarget"; groupId = $groupIdByName[$g] } }
        }
    }

    Write-Host "  Applying $($assignments.Count) assignment(s)..." -ForegroundColor Gray
    try {
        $assignBody = [string](@{ mobileAppAssignments = @($assignments) } | ConvertTo-Json -Depth 10)
    }
    catch {
        throw "Building the assignment request body failed: $($_.Exception.Message)"
    }
    try {
        Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($Config.AppId)/assign" -Method POST -Body $assignBody -StepDescription "Assign app to groups" | Out-Null
    }
    catch {
        $groupNameById = @{}
        foreach ($name in $groupIdByName.Keys) { $groupNameById[$groupIdByName[$name]] = $name }
        throw (Get-FriendlyAssignError -RawError $_.Exception.Message -AppName $Config.AppName -GroupNameById $groupNameById)
    }
    Write-Host "  [OK] Assignments applied." -ForegroundColor Green

    Write-Step "Done"
    Write-Host "[OK] $($allGroupNames.Count) group(s) confirmed ($createdCount newly created), $($assignments.Count) assignment(s) applied to this app." -ForegroundColor Green
    Write-Result -Success $true -GroupsCreated $createdCount -ErrorMessage ""
    exit 0
}
catch {
    Write-Host ""
    Write-Host "[FAILED] $($_.Exception.Message)" -ForegroundColor Red
    Write-Result -Success $false -GroupsCreated 0 -ErrorMessage $_.Exception.Message
    exit 1
}

