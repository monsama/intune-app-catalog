<#
.SYNOPSIS
    Ensures a security group exists (creating it if needed) and adds a set
    of members (users or groups, by Object ID) to it.
.DESCRIPTION
    Reads a JSON config (GroupName, MemberIds array, TenantId, ClientId,
    CertificateThumbprint). Idempotent: reuses the group if a group with
    that exact name already exists rather than creating a duplicate, and
    silently treats "already a member" as success rather than an error for
    each member. Writes a result JSON (success/error/groupId) to
    -OutputResultPath.

    Config.Mode selects an alternate one-off action instead of the default
    create-or-update-and-add-members flow above: "Delete" removes the group
    (looked up by GroupName), "DeleteMany" removes each of
    Config.GroupNames and keeps going when one of them fails, so a name
    that no longer exists doesn't abandon the rest of a confirmed list,
    "RemoveMember" removes Config.MemberId from
    Config.GroupId, and "Rename" PATCHes Config.GroupId's displayName to
    Config.NewGroupName - by ID, not by re-resolving GroupName, since the
    caller already has the ID from a prior Load/Search against the OLD
    name.
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
    param([bool]$Success, [string]$ErrorMessage, [string]$GroupId)
    $result = [pscustomobject]@{ success = $Success; error = $ErrorMessage; groupId = $GroupId }
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
if ($Config.Mode -eq "DeleteMany") {
    Write-Host "  Groups: $(@($Config.GroupNames).Count)" -ForegroundColor Gray
}
else {
    Write-Host "  Group: $($Config.GroupName)" -ForegroundColor Gray
    Write-Host "  Members to add: $(@($Config.MemberIds).Count)" -ForegroundColor Gray
}

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

    if ($Config.Mode -eq "Delete") {
        Write-Step "Finding group"
        $escapedName = $Config.GroupName.Replace("'", "''")
        $encodedFilter = [Uri]::EscapeDataString("displayName eq '$escapedName'")
        $existing = Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=$encodedFilter&`$select=id,displayName" -Method GET -StepDescription "Look up group"
        if (-not $existing.value -or $existing.value.Count -eq 0) {
            throw "No group named '$($Config.GroupName)' was found - nothing to delete."
        }
        $groupId = $existing.value[0].id
        Write-Host "  Found: $($Config.GroupName) ($groupId)" -ForegroundColor Gray

        Write-Step "Deleting group"
        Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/v1.0/groups/$groupId" -Method DELETE -StepDescription "Delete group" | Out-Null
        Write-Host "  [OK] Deleted from Entra ID." -ForegroundColor Green

        Write-Step "Done"
        Write-Result -Success $true -ErrorMessage "" -GroupId $groupId
        exit 0
    }

    if ($Config.Mode -eq "DeleteMany") {
        # One group failing doesn't stop the others: a name that no longer
        # exists, or one the app isn't allowed to touch, shouldn't silently
        # abandon the rest of a list the user already confirmed.
        $names = @($Config.GroupNames | Where-Object { $_ })
        Write-Host "  $($names.Count) group(s) to delete." -ForegroundColor Gray
        $deleted = 0
        $failed = New-Object System.Collections.Generic.List[string]
        foreach ($name in $names) {
            Write-Step "Deleting $name"
            try {
                $escapedName = ([string]$name).Replace("'", "''")
                $encodedFilter = [Uri]::EscapeDataString("displayName eq '$escapedName'")
                $existing = Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=$encodedFilter&`$select=id,displayName" -Method GET -StepDescription "Look up $name"
                if (-not $existing.value -or $existing.value.Count -eq 0) {
                    Write-Host "  [SKIPPED] No group named '$name' - nothing to delete." -ForegroundColor DarkGray
                    $failed.Add("$name (not found)")
                    continue
                }
                $gid = $existing.value[0].id
                Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/v1.0/groups/$gid" -Method DELETE -StepDescription "Delete $name" | Out-Null
                Write-Host "  [OK] Deleted '$name'." -ForegroundColor Green
                $deleted++
            }
            catch {
                Write-Host "  [FAILED] '$name': $($_.Exception.Message)" -ForegroundColor Red
                $failed.Add("$name ($($_.Exception.Message))")
            }
        }
        Write-Step "Done"
        Write-Host "  Deleted $deleted of $($names.Count)." -ForegroundColor $(if ($failed.Count) { "Yellow" } else { "Green" })
        if ($failed.Count) {
            Write-Result -Success $false -ErrorMessage "Deleted $deleted of $($names.Count). Not deleted: $($failed -join '; ')" -GroupId ""
            exit 1
        }
        Write-Result -Success $true -ErrorMessage "" -GroupId ""
        exit 0
    }

    if ($Config.Mode -eq "RemoveMember") {
        Write-Step "Removing member from group"
        Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/v1.0/groups/$($Config.GroupId)/members/$($Config.MemberId)/`$ref" -Method DELETE -StepDescription "Remove member" | Out-Null
        Write-Host "  [OK] Removed from group." -ForegroundColor Green
        Write-Step "Done"
        Write-Result -Success $true -ErrorMessage "" -GroupId $Config.GroupId
        exit 0
    }

    if ($Config.Mode -eq "Rename") {
        # By GroupId, not by looking the group up by its (old) name first -
        # the caller already resolved GroupId via a prior Load/Search
        # against the OLD name, so this stays correct even if that old name
        # is no longer unique or has already drifted.
        Write-Step "Renaming group"
        $renameBody = @{ displayName = $Config.NewGroupName } | ConvertTo-Json
        Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/v1.0/groups/$($Config.GroupId)" -Method PATCH -Body $renameBody -ContentType "application/json" -StepDescription "Rename group" | Out-Null
        Write-Host "  [OK] Renamed to `"$($Config.NewGroupName)`" in Entra ID." -ForegroundColor Green
        Write-Step "Done"
        Write-Result -Success $true -ErrorMessage "" -GroupId $Config.GroupId
        exit 0
    }

    Write-Step "Ensuring group exists"
    $escapedName = $Config.GroupName.Replace("'", "''")
    $encodedFilter = [Uri]::EscapeDataString("displayName eq '$escapedName'")
    $existing = Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=$encodedFilter&`$select=id,displayName" -Method GET -StepDescription "Look up group"

    if ($existing.value -and $existing.value.Count -gt 0) {
        $groupId = $existing.value[0].id
        Write-Host "  [=] Using existing group: $($Config.GroupName)" -ForegroundColor Gray

        if ($Config.Description) {
            Write-Step "Updating description"
            $descBody = @{ description = $Config.Description } | ConvertTo-Json
            Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/v1.0/groups/$groupId" -Method PATCH -Body $descBody -ContentType "application/json" -StepDescription "Update group description" | Out-Null
            Write-Host "  [OK] Description updated." -ForegroundColor Green
        }
    }
    else {
        $mailNickname = ($Config.GroupName -replace '[^a-zA-Z0-9]', '')
        if ($mailNickname.Length -gt 60) { $mailNickname = $mailNickname.Substring(0, 60) }
        if ([string]::IsNullOrWhiteSpace($mailNickname)) { $mailNickname = "grp" + (Get-Random -Minimum 1000 -Maximum 9999) }
        $groupBody = @{
            displayName     = $Config.GroupName
            mailEnabled     = $false
            mailNickname    = $mailNickname
            securityEnabled = $true
            "@odata.type"   = "#microsoft.graph.group"
        }
        if ($Config.Description) { $groupBody.description = $Config.Description }
        $groupBody = $groupBody | ConvertTo-Json -Depth 5
        $newGroup = Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/v1.0/groups" -Method POST -Body $groupBody -StepDescription "Create group"
        $groupId = $newGroup.id
        Write-Host "  [+] Created new group: $($Config.GroupName)" -ForegroundColor Green

        # Newly created Entra ID objects aren't always immediately queryable
        # across every Graph replica - the group demonstrably exists (the
        # create call above succeeded and returned this ID), but a request
        # routed to a different backend can still 404 on it for a few
        # seconds. Poll the same kind of GET the member-add calls below will
        # need, rather than guessing at a fixed delay.
        Write-Host "  Waiting for the new group to become available..." -ForegroundColor Gray
        $propagated = $false
        for ($attempt = 1; $attempt -le 10; $attempt++) {
            Start-Sleep -Seconds 2
            try {
                Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/v1.0/groups/$groupId`?`$select=id" -Method GET -StepDescription "Check group availability" | Out-Null
                $propagated = $true
                break
            }
            catch {
                Write-Host "  ... not yet visible (attempt $attempt/10)" -ForegroundColor DarkGray
            }
        }
        if ($propagated) {
            Write-Host "  [OK] Group is available." -ForegroundColor Green
        }
        else {
            Write-Host "  [WARN] Group still not confirmed visible after 20s - continuing anyway; member adds below will retry individually too." -ForegroundColor Yellow
        }
    }

    $memberIds = @($Config.MemberIds)
    if ($memberIds.Count -gt 0) {
        Write-Step "Adding members"
        foreach ($memberId in $memberIds) {
            # Per-member retry as a second line of defense against the same
            # propagation-delay issue, in case the wait above wasn't enough
            # or this specific call gets routed to a different replica.
            for ($attempt = 1; $attempt -le 3; $attempt++) {
                try {
                    $refBody = @{ "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$memberId" } | ConvertTo-Json
                    Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/v1.0/groups/$groupId/members/`$ref" -Method POST -Body $refBody -StepDescription "Add member $memberId" | Out-Null
                    Write-Host "  [+] Added: $memberId" -ForegroundColor Green
                    break
                }
                catch {
                    if ($_.Exception.Message -match 'already exist') {
                        Write-Host "  [=] Already a member: $memberId" -ForegroundColor Gray
                        break
                    }
                    elseif ($_.Exception.Message -match 'does not exist' -and $attempt -lt 3) {
                        Write-Host "  ... group not yet visible for this call, retrying ($attempt/3)..." -ForegroundColor DarkGray
                        Start-Sleep -Seconds 3
                    }
                    else {
                        Write-Host "  [WARN] Could not add $memberId : $($_.Exception.Message)" -ForegroundColor Yellow
                        break
                    }
                }
            }
        }
    }

    Write-Step "Done"
    Write-Host "[OK] Group ready: $($Config.GroupName) ($groupId)" -ForegroundColor Green
    Write-Result -Success $true -ErrorMessage "" -GroupId $groupId
    exit 0
}
catch {
    Write-Host ""
    Write-Host "[FAILED] $($_.Exception.Message)" -ForegroundColor Red
    Write-Result -Success $false -ErrorMessage $_.Exception.Message -GroupId ""
    exit 1
}

