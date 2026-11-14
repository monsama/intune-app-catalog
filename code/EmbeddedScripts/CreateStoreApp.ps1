<#
.SYNOPSIS
    Creates or updates a "Microsoft Store app (new)" in Intune - winGetApp,
    the Store's own package (no .intunewin: the Store installs and updates
    it). Writes a result JSON (success/appId/error) to OutputResultPath.
.DESCRIPTION
    Config: TenantId, ClientId, CertificateThumbprint, AppName, AppId (empty
    to create), PackageIdentifier (the Store product ID, e.g. 9NBLGGH4NNS1),
    Description, Publisher, InformationUrl, PrivacyUrl, RunAsAccount
    (system|user), OutputResultPath.
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
Write-Host "  App: $($Config.AppName) (Store product $($Config.PackageIdentifier))" -ForegroundColor Gray
try {
    if ([string]$Config.PackageIdentifier -notmatch '^(9[0-9A-Z]{11}|XP[0-9A-Z]{12})$') { throw "'$($Config.PackageIdentifier)' isn't a Microsoft Store product ID (12 letters and digits)." }
    Write-Step "Connecting to Microsoft Graph (app-only, certificate)"
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    $ctx = Get-MgContext -ErrorAction SilentlyContinue
    if ($null -eq $ctx -or $ctx.AuthType -ne 'AppOnly' -or $ctx.ClientId -ne $Config.ClientId) {
        Connect-MgGraph -TenantId $Config.TenantId -ClientId $Config.ClientId -CertificateThumbprint $Config.CertificateThumbprint -NoWelcome -ErrorAction Stop
    }
    Write-Host "  [OK] Connected." -ForegroundColor Green
    $body = [ordered]@{
        '@odata.type'      = '#microsoft.graph.winGetApp'
        displayName        = [string]$Config.AppName
        description        = $(if ([string]$Config.Description) { [string]$Config.Description } else { [string]$Config.AppName })
        publisher          = $(if ([string]$Config.Publisher) { [string]$Config.Publisher } else { 'Microsoft Store' })
        informationUrl     = $(if ([string]$Config.InformationUrl) { [string]$Config.InformationUrl } else { $null })
        privacyInformationUrl = $(if ([string]$Config.PrivacyUrl) { [string]$Config.PrivacyUrl } else { $null })
        installExperience  = @{ '@odata.type' = 'microsoft.graph.winGetAppInstallExperience'; runAsAccount = $(if ([string]$Config.RunAsAccount -eq 'user') { 'user' } else { 'system' }) }
    }
    if ($Config.AppId) {
        Write-Step "Updating the Store app in Intune"
        # packageIdentifier can't change on an existing app - it's left out.
        Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($Config.AppId)" -Method PATCH -Body ($body | ConvertTo-Json -Depth 6) -ContentType 'application/json' -ErrorAction Stop | Out-Null
        Write-Host "  [OK] Updated $($Config.AppName)." -ForegroundColor Green
        Write-Result -Success $true -AppId ([string]$Config.AppId) -ErrorMessage ''
    }
    else {
        Write-Step "Creating the Store app in Intune"
        $body.packageIdentifier = [string]$Config.PackageIdentifier
        $created = Invoke-MgGraphRequest -Uri 'https://graph.microsoft.com/beta/deviceAppManagement/mobileApps' -Method POST -Body ($body | ConvertTo-Json -Depth 6) -ContentType 'application/json' -ErrorAction Stop
        $id = [string]$created.id
        if (-not $id) { throw 'Intune did not return the new app''s ID.' }
        Write-Host "  [OK] Created $($Config.AppName) (App ID $id). The Store installs and updates it - no package needed." -ForegroundColor Green
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
