# What the app's sign-in is actually allowed to do.
#
# "I granted the permission and it still says Forbidden" is the most
# expensive confusion this app produces, because the two causes look
# identical from the outside: the grant is on a different app registration
# than the one in Settings, or it is on the right one but the running app
# still holds a token issued before the grant. Neither is visible anywhere -
# the portal shows the permission either way.
#
# The token settles it. Its "roles" claim is the definitive list of what
# Entra ID will let this app do, its "appid" says which registration it
# belongs to, and its issue time says whether it predates the grant.

function Global:ConvertFrom-JwtPayload {
    <#
      The claims out of a JWT's payload segment. Base64url, which is
      base64 with two characters swapped and the padding left off.
      $null when the text isn't a JWT.
    #>
    param([string]$Jwt)
    if ([string]::IsNullOrWhiteSpace($Jwt)) { return $null }
    $parts = $Jwt.Split('.')
    if ($parts.Count -lt 2) { return $null }
    $payload = $parts[1].Replace('-', '+').Replace('_', '/')
    switch ($payload.Length % 4) {
        2 { $payload += '==' }
        3 { $payload += '=' }
        1 { return $null }   # never a valid length
    }
    try {
        return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
    }
    catch { return $null }
}

function Global:Get-GraphRoleRequirements {
    <#
      Which application permission each part of this app needs, and whether
      it's required for the app to be useful at all or only for one feature.
      Any one of a row's Roles is enough - Intune accepts the read-only
      permission where the app only reads.

      Reading and changing are separate rows where they are separate
      permissions, because merging them makes this report lie. A tenant
      with only DeviceManagementScripts.Read.All used to be told "Platform
      scripts: yes", list its scripts happily, and then take a 403 on the
      first Save - the check had said the feature was available because
      one of the two roles was present, and the one that was present was
      the wrong one. Same trap for Group.Read.All, which can look up a
      group but cannot assign an app to it.
    #>
    # Grant: the one permission to add when the feature is missing - the
    # one that covers the most (ReadWrite over Read). Purpose: what it's
    # for, in the words of the app's own buttons.
    @(
        @{ Feature = "Apps in Intune";        Roles = @('DeviceManagementApps.ReadWrite.All'); Required = $true
           Grant = 'DeviceManagementApps.ReadWrite.All'; Purpose = 'deploy, update, assign and delete apps' }
        @{ Feature = "Finding groups";        Roles = @('Group.ReadWrite.All', 'Group.Read.All'); Required = $true
           Grant = 'Group.ReadWrite.All'; Purpose = 'find, create and manage assignment groups (Group.Read.All is enough if you only assign to existing groups)' }
        @{ Feature = "Creating and assigning groups"; Roles = @('Group.ReadWrite.All'); Required = $false
           Grant = 'Group.ReadWrite.All'; Purpose = 'find, create and manage assignment groups (Group.Read.All is enough if you only assign to existing groups)' }
        @{ Feature = "Install status";        Roles = @('DeviceManagementApps.Read.All', 'DeviceManagementApps.ReadWrite.All'); Required = $false
           Grant = 'DeviceManagementApps.ReadWrite.All'; Purpose = 'deploy, update, assign and delete apps' }
        @{ Feature = "Platform scripts (read)";   Roles = @('DeviceManagementScripts.Read.All', 'DeviceManagementScripts.ReadWrite.All'); Required = $false
           Grant = 'DeviceManagementScripts.ReadWrite.All'; Purpose = 'the Platform scripts page only' }
        @{ Feature = "Platform scripts (change)"; Roles = @('DeviceManagementScripts.ReadWrite.All'); Required = $false
           Grant = 'DeviceManagementScripts.ReadWrite.All'; Purpose = 'the Platform scripts page only' }
        @{ Feature = "Group members";         Roles = @('User.Read.All', 'Directory.Read.All'); Required = $false
           Grant = 'Directory.Read.All'; Purpose = 'show and pick users and devices as group members' }
    )
}

function Global:Get-GraphRoleReport {
    <#
      The token's roles measured against what this app uses:
      @{ Have = <roles present>; Missing = @(<per-feature rows it can't do>) }.
      Case-insensitive, because Entra ID is.
    #>
    param([string[]]$Roles)
    $have = @(@($Roles) | Where-Object { $_ })
    $missing = New-Object System.Collections.Generic.List[object]
    foreach ($requirement in Get-GraphRoleRequirements) {
        $satisfied = $false
        foreach ($role in $requirement.Roles) {
            if ($have -contains $role) { $satisfied = $true; break }
        }
        if (-not $satisfied) { $missing.Add($requirement) }
    }
    return @{ Have = $have; Missing = $missing.ToArray() }
}

function Global:Format-GraphRoleReport {
    <#
      The role report as the lines Test connection and Diagnostics show:
      what works, what doesn't, and - the point of looking - exactly which
      permissions to add, where, and what to click after. Written for
      someone who has never opened API permissions before.
    #>
    param($Report, [string]$TokenAppId, [string]$SettingsClientId)
    $lines = New-Object System.Collections.Generic.List[string]
    if ($TokenAppId -and $SettingsClientId -and $TokenAppId -ne $SettingsClientId) {
        $lines.Add("[WARN] The token is for app $TokenAppId, but Settings names $SettingsClientId - permissions granted to one don't count for the other.")
    }
    $have = @($Report.Have)
    $missing = @($Report.Missing)
    $appRef = if ($SettingsClientId) { "the app registration with Client ID $SettingsClientId" } else { "this app's registration" }

    if ($have.Count -eq 0) {
        $lines.Add("[FAILED] The sign-in works, but the token carries no application permissions at all - nothing in Intune will work yet.")
    }
    else {
        $lines.Add("[INFO] Permissions in the token ($($have.Count)): $(($have | Sort-Object) -join ', ')")
        $missingFeatures = @($missing | ForEach-Object { $_.Feature })
        foreach ($requirement in Get-GraphRoleRequirements) {
            if ($missingFeatures -notcontains $requirement.Feature) { $lines.Add("[OK] $($requirement.Feature)") }
        }
        foreach ($row in $missing) {
            $tag = if ($row.Required) { '[FAILED]' } else { '[WARN]' }
            $lines.Add("$tag $($row.Feature) needs $((@($row.Roles)) -join ' or ') - not in the token.")
        }
        if ($missing.Count -eq 0) {
            $lines.Add("[OK] Everything this app uses is covered.")
            return $lines.ToArray()
        }
    }

    # One line per permission to add, required ones first, each once.
    $toAdd = New-Object System.Collections.Generic.List[object]
    foreach ($row in @($missing | Sort-Object { -not $_.Required })) {
        $existing = @($toAdd | Where-Object { $_.Name -eq $row.Grant })
        if ($existing.Count -gt 0) { if ($row.Required) { $existing[0].Required = $true }; continue }
        $toAdd.Add([pscustomobject]@{ Name = $row.Grant; Required = [bool]$row.Required; Purpose = $row.Purpose })
    }
    $width = ($toAdd | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum
    $lines.Add("")
    $lines.Add("[INFO] Quickest fix: 'Add required permissions...' in Settings adds them for you and opens Entra for the admin consent.")
    $clientGuid = [guid]::Empty
    if ([guid]::TryParse([string]$SettingsClientId, [ref]$clientGuid)) {
        $lines.Add("[INFO] This app registration's API permissions page: https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/CallAnAPI/appId/$clientGuid/isMSAApp~/false")
    }
    $lines.Add("[INFO] Or by hand, in the Microsoft Entra admin center (entra.microsoft.com):")
    $lines.Add("  1. App registrations > All applications > $appRef > API permissions")
    $lines.Add("  2. + Add a permission > Microsoft Graph > Application permissions (not Delegated), and add:")
    foreach ($p in $toAdd) {
        $need = if ($p.Required) { 'required' } else { 'optional' }
        $lines.Add("       $($p.Name.PadRight($width))  $need - $($p.Purpose)")
    }
    $lines.Add("  3. Grant admin consent for your tenant (needs Global Administrator or Privileged Role Administrator).")
    $lines.Add("     Every row should then say Type: Application, Status: Granted.")
    $lines.Add("  4. Test connection again. New permissions can take a minute or two to reach the token.")
    if ($have.Count -gt 0) {
        $lines.Add("[INFO] Already listed as Granted but still missing here? Then it was added as Delegated, or to a different app registration.")
    }
    return $lines.ToArray()
}

function Global:Get-GraphAppTokenClaims {
    <#
      A brand-new app-only token from Entra ID, as its claims - nothing
      cached and nothing reused, so what comes back is what the app
      registration is allowed to do right now. That matters: the point of
      asking is to tell a stale token apart from a missing grant, and a
      cached one answers neither question.

      Signs a client assertion with the certificate, exactly as the app's
      own sign-in does. Read-only against Entra ID; it never calls Intune.
    #>
    param([string]$TenantId, [string]$ClientId, [string]$Thumbprint)

    $certificate = Get-ChildItem Cert:\CurrentUser\My, Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
        Where-Object { $_.Thumbprint -eq ($Thumbprint -replace '\s', '') } | Select-Object -First 1
    if (-not $certificate) { throw "No certificate with thumbprint $Thumbprint in CurrentUser\My or LocalMachine\My." }
    if (-not $certificate.HasPrivateKey) { throw "That certificate has no private key on this machine, so it can't sign in." }

    $toBase64Url = {
        param([byte[]]$Bytes)
        [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    }
    $tokenUri = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
    $now = [DateTimeOffset]::UtcNow
    $header = @{ alg = 'RS256'; typ = 'JWT'; x5t = (& $toBase64Url $certificate.GetCertHash()) } | ConvertTo-Json -Compress
    $payload = @{
        aud = $tokenUri
        iss = $ClientId
        sub = $ClientId
        jti = [guid]::NewGuid().ToString()
        nbf = $now.ToUnixTimeSeconds()
        exp = $now.AddMinutes(10).ToUnixTimeSeconds()
    } | ConvertTo-Json -Compress
    $signingInput = "$(& $toBase64Url ([Text.Encoding]::UTF8.GetBytes($header))).$(& $toBase64Url ([Text.Encoding]::UTF8.GetBytes($payload)))"
    $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($certificate)
    if (-not $rsa) { throw "Could not use that certificate's private key for signing." }
    $signature = $rsa.SignData([Text.Encoding]::UTF8.GetBytes($signingInput),
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)

    $response = Invoke-RestMethod -Uri $tokenUri -Method POST -ContentType 'application/x-www-form-urlencoded' -Body @{
        client_id             = $ClientId
        scope                 = 'https://graph.microsoft.com/.default'
        client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
        client_assertion      = "$signingInput.$(& $toBase64Url $signature)"
        grant_type            = 'client_credentials'
    }
    $claims = ConvertFrom-JwtPayload $response.access_token
    if (-not $claims) { throw "Entra ID returned a token this app couldn't read." }
    return $claims
}

function Global:Reset-GraphSession {
    <#
      Drops the Microsoft Graph sign-in the app's pages share, so the
      next one signs in fresh. The Graph module keeps ONE session per
      process, and every lookup reuses it while it's for the same app - so
      after the certificate or the permissions change, the old token (no new
      permission, or an old certificate) would otherwise keep being used for
      up to an hour. Cheap when there's nothing to drop: only runs when the
      module is actually loaded in this process.
    #>
    $loaded = [AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'Microsoft.Graph.Authentication' } | Select-Object -First 1
    if (-not $loaded) { return }
    $ps = $null
    try {
        $ps = [powershell]::Create()
        [void]$ps.AddScript({
            Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
            if (Get-MgContext -ErrorAction SilentlyContinue) { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null }
        })
        [void]$ps.Invoke()
    }
    catch { }
    finally { if ($ps) { $ps.Dispose() } }
}

function Global:Format-SetupChecklist {
    <#
      Pure: the whole first-time setup as one checklist, each step [OK],
      [FAILED] or [--] (not checked yet, because an earlier step failed),
      with what to do next for the first step that isn't done. Shown after
      Test connection, so someone setting this up for the first time sees
      where they are in the whole process, not just the latest error.
      -State keys (missing ones count as unknown):
        ModuleOk, FieldsOk                                 [bool]
        CertFound, CertHasKey                              [bool]
        CertNotAfter                                       [datetime]
        SignInOk                                           [bool] ($null: not tried)
        SignInError                                        [string]
        Report                                             Get-GraphRoleReport result
        Saved                                              [bool]
    #>
    param([hashtable]$State, [datetime]$Now = (Get-Date))
    $rows = New-Object System.Collections.Generic.List[object]
    $add = { param($Name, $Status, $Next) $rows.Add([pscustomobject]@{ Name = $Name; Status = $Status; Next = $Next }) }

    & $add 'Microsoft.Graph.Authentication module' $(if ($State.ModuleOk) { 'OK' } else { 'FAILED' }) 'Settings > Prerequisites installs it.'
    & $add 'Tenant ID, Client ID and certificate thumbprint filled in' $(if ($State.FieldsOk) { 'OK' } else { 'FAILED' }) 'Fill in all three on the Connection tab. The setup guide shows where each one is in Entra.'

    $certStatus = if (-not $State.FieldsOk) { 'SKIP' }
                  elseif (-not $State.CertFound) { 'FAILED' }
                  elseif (-not $State.CertHasKey) { 'FAILED' }
                  elseif ($State.CertNotAfter -and $State.CertNotAfter -lt $Now) { 'FAILED' }
                  else { 'OK' }
    $certNext = if (-not $State.CertFound) { 'Certificate tab: pick the certificate you uploaded to Entra, or generate a new one (then upload it).' }
                elseif (-not $State.CertHasKey) { 'This certificate has no private key on this machine. Import it with its key (.pfx), or generate a new one and upload it.' }
                else { 'The certificate has expired. Generate a new one on the Certificate tab and upload it.' }
    & $add 'Certificate on this machine, with its private key, not expired' $certStatus $certNext

    $signStatus = if ($certStatus -ne 'OK' -or $null -eq $State.SignInOk) { 'SKIP' } elseif ($State.SignInOk) { 'OK' } else { 'FAILED' }
    $signNext = if ([string]$State.SignInError -match 'AADSTS700016|was not found in the directory') { 'Entra doesn''t know this Client ID in this tenant. Check Tenant ID and Client ID.' }
                elseif ([string]$State.SignInError -match 'AADSTS90002|AADSTS900023|Tenant .* not found') { 'The Tenant ID is wrong.' }
                else { 'Upload this certificate to the app registration with Upload in Settings (or in Entra > App registrations > your app > Certificates & secrets). Allow a few minutes after uploading.' }
    & $add 'Entra ID accepts the certificate (uploaded to the app registration)' $signStatus $signNext

    $report = $State.Report
    $permStatus = if ($signStatus -ne 'OK' -or -not $report) { 'SKIP' }
                  elseif (@($report.Have).Count -eq 0) { 'FAILED' }
                  elseif (@(@($report.Missing) | Where-Object { $_.Required }).Count -gt 0) { 'FAILED' }
                  else { 'OK' }
    $permNext = if ($report -and @($report.Have).Count -eq 0) { 'Use Add required permissions... in Settings (or add the ones listed above by hand: Application, not Delegated), then grant admin consent.' }
                else { 'Use Add required permissions... in Settings to add the missing ones, then grant admin consent.' }
    & $add 'Required API permissions granted, with admin consent' $permStatus $permNext

    & $add 'Settings saved' $(if ($State.Saved) { 'OK' } else { 'FAILED' }) 'Click Save - until then the rest of the app keeps using the previously saved connection.'

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("")
    $lines.Add("[INFO] Setup checklist:")
    $nextShown = $false
    foreach ($row in $rows) {
        $tag = switch ($row.Status) { 'OK' { '[OK]' } 'FAILED' { '[FAILED]' } default { '[--]' } }
        $lines.Add("  $tag $($row.Name)")
        if ($row.Status -eq 'FAILED' -and -not $nextShown) {
            $lines.Add("         Next: $($row.Next)")
            $nextShown = $true
        }
    }
    # @() around the whole if: the value of an if statement is unrolled, so one
    # optional row on its own would lose .Count in Windows PowerShell 5.1.
    $optional = @(if ($report) { @($report.Missing) | Where-Object { -not $_.Required } })
    if (-not $nextShown) {
        if ($optional.Count -gt 0) { $lines.Add("[OK] Setup complete. $($optional.Count) optional feature(s) still need a permission - see above.") }
        else { $lines.Add("[OK] Setup complete - every step is done.") }
    }
    return $lines.ToArray()
}
