<#
.SYNOPSIS
    Creates, updates, deletes or assigns an Intune platform script (a
    PowerShell script Intune runs on enrolled Windows devices).
.DESCRIPTION
    Reads a JSON config (TenantId, ClientId, CertificateThumbprint, Mode and
    the fields for that mode) and writes a result JSON (success/error/
    scriptId) to Config.OutputResultPath.

    Config.Mode:
      "Save"   - creates the script, or updates Config.ScriptId when set,
                 then assigns Config.GroupNames (resolved to group IDs) if
                 Config.AssignGroups is true. An empty group list removes
                 every assignment - the assign action replaces the whole
                 list, it doesn't add to it.
      "Delete" - deletes Config.ScriptId.

    Needs DeviceManagementScripts.ReadWrite.All (or the older
    DeviceManagementConfiguration.ReadWrite.All) as an application
    permission, plus Group.Read.All to resolve group names.
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
    param([bool]$Success, [string]$ErrorMessage, [string]$ScriptId)
    $result = [pscustomobject]@{ success = $Success; error = $ErrorMessage; scriptId = $ScriptId }
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
            # Same throttling/hiccup retry as the other embedded scripts -
            # see Invoke-GraphRequestDetailed in GroupManager.ps1 for why
            # this reads the status out of the exception text.
            $isThrottled = $_.Exception.Message -match '429|TooManyRequests|Too Many Requests'
            $isTransient = $_.Exception.Message -match '\b503\b|ServiceUnavailable|Service Unavailable|\b504\b|GatewayTimeout'
            if (($isThrottled -or $isTransient) -and $attempt -lt $maxAttempts) {
                $waitSeconds = [Math]::Pow(2, $attempt)
                Write-Host "  [WARN] $StepDescription hit a temporary Graph error - retrying in $waitSeconds s (attempt $attempt/$maxAttempts)." -ForegroundColor Yellow
                Start-Sleep -Seconds $waitSeconds
                continue
            }
            $detail = Get-HttpErrorDetail $_
            if (Get-Command Write-GraphRequestLog -ErrorAction SilentlyContinue) {
                Write-GraphRequestLog -Method $Method -Uri $Uri -Milliseconds $graphTimer.ElapsedMilliseconds -ErrorText $_.Exception.Message -Detail $detail
            }
            $message = "$StepDescription failed: $($_.Exception.Message)"
            if ($detail) { $message += "`nGraph said: $detail" }
            # "Forbidden" alone never says which permission is missing, and
            # this script needs two different ones (scripts, groups).
            if ("$($_.Exception.Message) $detail" -match '\bforbidden\b|\b403\b|insufficient privileges|Authorization_RequestDenied') {
                $needed = if ($Uri -match 'deviceManagementScripts') { "DeviceManagementScripts.ReadWrite.All" } else { "Group.Read.All" }
                $message += "`nThis usually means the app registration is missing the $needed application permission (with admin consent). Settings > First time? Setup guide... walks through adding it."
            }
            throw $message
        }
    }
}

function Resolve-GroupId {
    # A group's Object ID from its exact display name
    param([string]$GroupName)
    $escapedName = $GroupName.Replace("'", "''")
    $encodedFilter = [Uri]::EscapeDataString("displayName eq '$escapedName'")
    $found = Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=$encodedFilter&`$select=id,displayName" `
        -Method GET -StepDescription "Look up group '$GroupName'"
    if (-not $found.value -or @($found.value).Count -eq 0) {
        throw "No group named '$GroupName' exists in Entra ID. Create it first (Group manager...), or correct the name."
    }
    return @($found.value)[0].id
}

Write-Host "=== Intune platform script ===" -ForegroundColor Cyan
if (-not (Test-Path $ConfigPath)) {
    Write-Host "[FAILED] Config file not found: $ConfigPath" -ForegroundColor Red
    exit 1
}
$Config = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
Write-Host "  Mode:   $($Config.Mode)" -ForegroundColor Gray
Write-Host "  Script: $($Config.DisplayName)" -ForegroundColor Gray

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
        Write-Step "Deleting the script"
        # An empty id builds ".../deviceManagementScripts/" - a collection
        # URL - and Graph answers "No OData route exists that match
        # template ~/singleton/navigation with http verb DELETE", which
        # tells the user nothing about what went wrong. Say it here
        # instead. The caller should never send one; this is the backstop.
        if ([string]::IsNullOrWhiteSpace($Config.ScriptId)) {
            Write-Host "  [FAILED] No script id to delete - '$($Config.DisplayName)' has no Intune id, so there is nothing in Intune to delete." -ForegroundColor Red
            Write-Result -Success $false -ErrorMessage "No script id to delete." -ScriptId ""
            exit 1
        }
        Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/beta/deviceManagement/deviceManagementScripts/$($Config.ScriptId)" `
            -Method DELETE -StepDescription "Delete platform script" | Out-Null
        Write-Host "  [OK] Deleted '$($Config.DisplayName)' from Intune." -ForegroundColor Green
        Write-Step "Done"
        Write-Result -Success $true -ErrorMessage "" -ScriptId $Config.ScriptId
        exit 0
    }

    # ---- Save (create or update) ----
    $body = @{
        "@odata.type"         = "#microsoft.graph.deviceManagementScript"
        displayName           = [string]$Config.DisplayName
        description           = [string]$Config.Description
        fileName              = [string]$Config.FileName
        scriptContent         = [string]$Config.ScriptContentBase64
        runAsAccount          = [string]$Config.RunAsAccount
        runAs32Bit            = [bool]$Config.RunAs32Bit
        enforceSignatureCheck = [bool]$Config.EnforceSignatureCheck
    } | ConvertTo-Json -Depth 5

    $scriptId = [string]$Config.ScriptId
    if ($scriptId) {
        Write-Step "Updating the script in Intune"
        Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/beta/deviceManagement/deviceManagementScripts/$scriptId" `
            -Method PATCH -Body $body -StepDescription "Update platform script" | Out-Null
        Write-Host "  [OK] Updated '$($Config.DisplayName)'." -ForegroundColor Green
    }
    else {
        Write-Step "Creating the script in Intune"
        $created = Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/beta/deviceManagement/deviceManagementScripts" `
            -Method POST -Body $body -StepDescription "Create platform script"
        $scriptId = [string]$created.id
        Write-Host "  [OK] Created '$($Config.DisplayName)' ($scriptId)." -ForegroundColor Green
    }

    if ($Config.AssignGroups) {
        $groupNames = @($Config.GroupNames | Where-Object { $_ })
        Write-Step "Assigning groups"
        $groupIds = @()
        foreach ($groupName in $groupNames) {
            $groupIds += (Resolve-GroupId -GroupName $groupName)
            Write-Host "  [OK] $groupName" -ForegroundColor Green
        }
        # The assign action REPLACES the whole assignment list, so sending an
        # empty list is what removes every assignment - see the dialog, which
        # says so before it does it.
        $assignments = @($groupIds | ForEach-Object {
            @{
                "@odata.type" = "#microsoft.graph.deviceManagementScriptAssignment"
                target        = @{ "@odata.type" = "#microsoft.graph.groupAssignmentTarget"; groupId = "$_" }
            }
        })
        $assignBody = @{ deviceManagementScriptAssignments = $assignments } | ConvertTo-Json -Depth 8
        Invoke-GraphRequestDetailed -Uri "https://graph.microsoft.com/beta/deviceManagement/deviceManagementScripts/$scriptId/assign" `
            -Method POST -Body $assignBody -StepDescription "Assign platform script" | Out-Null
        if ($groupIds.Count -eq 0) {
            Write-Host "  [OK] Every assignment removed - this script no longer targets any group." -ForegroundColor Green
        }
        else {
            Write-Host "  [OK] Assigned to $($groupIds.Count) group(s)." -ForegroundColor Green
        }
    }

    Write-Step "Done"
    Write-Result -Success $true -ErrorMessage "" -ScriptId $scriptId
    exit 0
}
catch {
    Write-Host ""
    Write-Host "[FAILED] $($_.Exception.Message)" -ForegroundColor Red
    Write-Result -Success $false -ErrorMessage $_.Exception.Message -ScriptId ([string]$Config.ScriptId)
    exit 1
}
