<#
.SYNOPSIS
    Creates or updates "Microsoft 365 Apps (Windows 10 and later)" in Intune -
    officeSuiteApp, Microsoft's own Office installer (no .intunewin: the
    Office CDN installs and updates it). Writes a result JSON
    (success/appId/error) to OutputResultPath.
.DESCRIPTION
    Config: TenantId, ClientId, CertificateThumbprint, AppName, AppId (empty
    to create), Body (the officeSuiteApp as the app built it from the
    catalog: channel, architecture, languages, apps left out, ...),
    OutputResultPath.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[System.Net.ServicePointManager]::Expect100Continue = $false

function Write-Step { param([string]$Text) Write-Host ""; Write-Host "=== $Text ===" -ForegroundColor Cyan }
function Write-Result {
    param([bool]$Success, [string]$AppId, [string]$ErrorMessage)
    [pscustomobject]@{ success = $Success; appId = $AppId; error = $ErrorMessage } | ConvertTo-Json | Set-Content -LiteralPath $Config.OutputResultPath -Encoding UTF8
}

Write-Step "Loading configuration"
$Config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
Write-Host "  App: $($Config.AppName) (Microsoft 365 Apps)" -ForegroundColor Gray
try {
    $body = $Config.Body
    if (-not $body -or [string]$body.'@odata.type' -ne '#microsoft.graph.officeSuiteApp') { throw 'No Microsoft 365 Apps settings to send.' }
    Write-Host "  Channel: $($body.updateChannel), $($body.officePlatformArchitecture)$(if (@($body.localesToInstall).Count) { ', languages: ' + (@($body.localesToInstall) -join ', ') })" -ForegroundColor Gray
    Write-Step "Connecting to Microsoft Graph (app-only, certificate)"
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    $ctx = Get-MgContext -ErrorAction SilentlyContinue
    if ($null -eq $ctx -or $ctx.AuthType -ne 'AppOnly' -or $ctx.ClientId -ne $Config.ClientId) {
        Connect-MgGraph -TenantId $Config.TenantId -ClientId $Config.ClientId -CertificateThumbprint $Config.CertificateThumbprint -NoWelcome -ErrorAction Stop
    }
    Write-Host "  [OK] Connected." -ForegroundColor Green
    $json = $body | ConvertTo-Json -Depth 6
    if ($Config.AppId) {
        # Into the PATCH address as is - only a GUID.
        $parsedAppId = [guid]::Empty
        if (-not [guid]::TryParse([string]$Config.AppId, [ref]$parsedAppId)) { throw "'$($Config.AppId)' isn't an Intune App ID (a GUID)." }
        $Config.AppId = $parsedAppId.ToString()
        Write-Step "Updating Microsoft 365 Apps in Intune"
        Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($Config.AppId)" -Method PATCH -Body $json -ContentType 'application/json' -ErrorAction Stop | Out-Null
        Write-Host "  [OK] Updated $($Config.AppName) - devices pick up the new settings at their next Office update." -ForegroundColor Green
        Write-Result -Success $true -AppId ([string]$Config.AppId) -ErrorMessage ''
    }
    else {
        Write-Step "Creating Microsoft 365 Apps in Intune"
        $created = Invoke-MgGraphRequest -Uri 'https://graph.microsoft.com/beta/deviceAppManagement/mobileApps' -Method POST -Body $json -ContentType 'application/json' -ErrorAction Stop
        $id = [string]$created.id
        if (-not $id) { throw 'Intune did not return the new app''s ID.' }
        Write-Host "  [OK] Created $($Config.AppName) (App ID $id). Microsoft installs and updates it - no package needed." -ForegroundColor Green
        Write-Result -Success $true -AppId $id -ErrorMessage ''
    }
    exit 0
}
catch {
    $msg = $_.Exception.Message
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $msg = "$msg`n$($_.ErrorDetails.Message)" }
    Write-Host "[FAILED] $msg" -ForegroundColor Red
    Write-Result -Success $false -AppId '' -ErrorMessage $msg
    exit 1
}
