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
    @(
        @{ Feature = "Apps in Intune";        Roles = @('DeviceManagementApps.ReadWrite.All'); Required = $true }
        @{ Feature = "Finding groups";        Roles = @('Group.ReadWrite.All', 'Group.Read.All'); Required = $true }
        @{ Feature = "Creating and assigning groups"; Roles = @('Group.ReadWrite.All'); Required = $false }
        @{ Feature = "Install status";        Roles = @('DeviceManagementApps.Read.All', 'DeviceManagementApps.ReadWrite.All'); Required = $false }
        @{ Feature = "Platform scripts (read)";   Roles = @('DeviceManagementScripts.Read.All', 'DeviceManagementScripts.ReadWrite.All'); Required = $false }
        @{ Feature = "Platform scripts (change)"; Roles = @('DeviceManagementScripts.ReadWrite.All'); Required = $false }
        @{ Feature = "Group members";         Roles = @('User.Read.All', 'Directory.Read.All'); Required = $false }
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
      The role report as the lines Test connection shows. One line per
      feature the token can't reach, naming the permission to add - that
      being the whole point of looking.
    #>
    param($Report, [string]$TokenAppId, [string]$SettingsClientId)
    $lines = New-Object System.Collections.Generic.List[string]
    if ($TokenAppId -and $SettingsClientId -and $TokenAppId -ne $SettingsClientId) {
        $lines.Add("[WARN] The token is for app $TokenAppId, but Settings names $SettingsClientId.")
    }
    $have = @($Report.Have)
    if ($have.Count -eq 0) {
        $lines.Add("[FAILED] The sign-in works, but the token carries no application permissions at all.")
        $lines.Add("[INFO] Add them under App registrations > API permissions > Application permissions, then Grant admin consent.")
        return $lines.ToArray()
    }
    $lines.Add("[INFO] Permissions in the token ($($have.Count)): $(($have | Sort-Object) -join ', ')")
    $missing = @($Report.Missing)
    if ($missing.Count -eq 0) {
        $lines.Add("[OK] Everything this app uses is covered.")
        return $lines.ToArray()
    }
    foreach ($row in $missing) {
        $tag = if ($row.Required) { '[FAILED]' } else { '[WARN]' }
        $lines.Add("$tag $($row.Feature) needs $((@($row.Roles)) -join ' or ') - not in the token.")
    }
    $lines.Add("[INFO] Add the missing ones as Application permissions and Grant admin consent. A permission already showing as granted but missing here belongs to a different app registration.")
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
