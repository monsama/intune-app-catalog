<#
.SYNOPSIS
    Deletes a Win32 app from Intune entirely. Irreversible.
.DESCRIPTION
    Reads a JSON config (AppId, AppName, TenantId, ClientId,
    CertificateThumbprint) and deletes that one app from Intune via Graph.
    Writes a result JSON (success/error) to -OutputResultPath.
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
    param([bool]$Success, [string]$ErrorMessage, [string]$BlockingAppId = "", [string]$BlockingAppName = "")
    $result = [pscustomobject]@{ success = $Success; error = $ErrorMessage; blockingAppId = $BlockingAppId; blockingAppName = $BlockingAppName }
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
Write-Host "  App: $($Config.AppName)" -ForegroundColor Gray
Write-Host "  App ID: $($Config.AppId)" -ForegroundColor Gray

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

    if ($Config.RemoveDependencyFromAppId) {
        Write-Step "Removing the blocking dependency first"
        # CORRECTED after being backwards the first time - a real, deeper
        # bug than just the earlier targetType direction fix. The
        # dependency relationship is OWNED by the app being deleted (this
        # one), not by the blocking app - Intune's own portal (test23's own
        # Properties > Dependencies tab) confirmed this app is the one that
        # DECLARES "I depend on X", and the blocking app's own relationships
        # list is just a read-only, reflected VIEW of that declaration, not
        # an independently editable record. Modifying the blocking app's
        # side (as this used to) never actually touched the real
        # relationship at all - which is exactly why the removal kept
        # reporting success but the dependency kept showing up again on
        # every retry. Now correctly reads and updates THIS app's own
        # relationships instead, removing the entry that points at the
        # blocking app.
        # updateRelationships is REPLACE semantics, not additive - sending
        # only a partial list would silently wipe out every OTHER
        # dependency this app has, so the full current list is read first
        # and only the one entry pointing at the blocking app is left out
        # of what gets resubmitted.
        $existingRels = Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($Config.AppId)/relationships" -Method GET -StepDescription "Read existing dependencies"
        $matchingRel = $existingRels.value | Where-Object { $_.targetId -eq $Config.RemoveDependencyFromAppId } | Select-Object -First 1
        if ($matchingRel) {
            # Only this app's own ("child") relationships go back, each as
            # its own type - every one used to be resent as a dependency,
            # supersedence and other apps' "parent" entries included.
            $keepRels = @($existingRels.value | Where-Object {
                $_.targetId -ne $Config.RemoveDependencyFromAppId -and (-not [string]$_.targetType -or [string]$_.targetType -eq 'child')
            } | ForEach-Object {
                if ([string]$_.'@odata.type' -like '*mobileAppSupersedence') {
                    @{ "@odata.type" = "#microsoft.graph.mobileAppSupersedence"; targetId = $_.targetId; supersedenceType = $_.supersedenceType }
                }
                else {
                    @{ "@odata.type" = "#microsoft.graph.mobileAppDependency"; targetId = $_.targetId; dependencyType = $_.dependencyType }
                }
            })
            $relBody = @{ relationships = $keepRels } | ConvertTo-Json -Depth 8
            Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($Config.AppId)/updateRelationships" -Method POST -Body $relBody -ContentType "application/json" -StepDescription "Remove dependency relationship" | Out-Null
            Write-Host "  [OK] Dependency relationship removed - $($keepRels.Count) other relationship(s) kept." -ForegroundColor Green

            # Graph's delete-time dependency check can briefly lag behind an
            # updateRelationships change actually taking effect - the same
            # kind of propagation delay already handled elsewhere in this
            # tool after group creation. Without waiting here, the very
            # next delete attempt below can still see the OLD, pre-removal
            # dependency state and fail with the exact same error - which
            # is exactly what looping on this same error over and over
            # looked like.
            Write-Host "  Waiting for the removal to take effect..." -ForegroundColor Gray
            $removalConfirmed = $false
            for ($attempt = 1; $attempt -le 10; $attempt++) {
                Start-Sleep -Seconds 2
                $recheckRels = Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($Config.AppId)/relationships" -Method GET -StepDescription "Re-check dependencies"
                $stillThere = $recheckRels.value | Where-Object { $_.targetId -eq $Config.RemoveDependencyFromAppId }
                if (-not $stillThere) { $removalConfirmed = $true; break }
                Write-Host "  ... still showing as a dependency (attempt $attempt/10)" -ForegroundColor Gray
            }
            if ($removalConfirmed) {
                Write-Host "  [OK] Confirmed removed." -ForegroundColor Green
            }
            else {
                Write-Host "  [!] Still showing as a dependency after waiting - proceeding to delete anyway, but it may fail again." -ForegroundColor Yellow
            }
        }
        else {
            Write-Host "  (no matching dependency found - it may have already been removed by someone else)" -ForegroundColor Yellow
        }
    }

    Write-Step "Deleting app from Intune"
    try {
        Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($Config.AppId)" -Method DELETE -StepDescription "Delete app" | Out-Null
        Write-Host "  [OK] Deleted from Intune." -ForegroundColor Green
    }
    catch {
        # This specific Graph business rule is common enough to deserve a
        # clear, actionable message instead of just the raw JSON - an app
        # can't be deleted while it's set as a dependency for another app.
        if ($_.Exception.Message -match 'is the parent of another app:\s*([0-9a-fA-F-]{36})') {
            $blockingId = $Matches[1]
            $blockingName = $blockingId
            try {
                $blockingApp = Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$blockingId`?`$select=displayName" -Method GET -StepDescription "Look up blocking app name"
                if ($blockingApp.displayName) { $blockingName = $blockingApp.displayName }
            } catch { }
            Write-Host "[FAILED] Blocked by a dependency: `"$blockingName`" ($blockingId) still requires this app." -ForegroundColor Red
            Write-Result -Success $false -ErrorMessage "This app can't be deleted because Intune has it set as a dependency for `"$blockingName`"." -BlockingAppId $blockingId -BlockingAppName $blockingName
            exit 1
        }
        # Not actually a failure - the one thing this step is trying to
        # achieve (this App ID no longer existing in Intune) is already
        # true. Happens whenever the catalog's own record is stale: someone
        # else deleted it directly in the Intune portal, "Intune sync
        # check" already flagged it as gone but this app wasn't re-saved
        # yet, or this exact delete was already run once and simply never
        # got the chance to clear the App ID locally afterward (a prior
        # crash, a closed dialog, etc.). Treated as success and continues
        # into the same after-delete steps below, rather than surfacing a
        # 404 as a scary [FAILED] for an outcome that was already achieved
        # before this run even started.
        if ($_.Exception.Message -match 'NotFound|404') {
            Write-Host "  [OK] Already not in Intune (App ID not found) - nothing to delete, treating as success." -ForegroundColor Yellow
        }
        else {
            throw
        }
    }

    Write-Step "Done"
    Write-Result -Success $true -ErrorMessage ""
    exit 0
}
catch {
    Write-Host ""
    Write-Host "[FAILED] $($_.Exception.Message)" -ForegroundColor Red
    Write-Result -Success $false -ErrorMessage $_.Exception.Message
    exit 1
}

