# Sign in with Microsoft (Entra ID) for the server version - the parts that are pure logic: the settings, the
# address the browser is sent to, and the checks on the ID token Entra ID hands back. The flow itself (redirects,
# the token request, the group check, the session) is in code\Web\WebEntraSignIn.ps1.
#
# The flow: OpenID Connect authorization code with PKCE. The app registration the app already uses is the client;
# it proves itself with the same certificate it signs in to Graph with (a client assertion) - no client secret.
# Who may sign in: the members of one Entra ID group (checked with Graph, app-only, after the sign-in). Entra ID
# asks for the second factor (MFA, Conditional Access) - the app never sees a password.

function Global:ConvertTo-SignInSettings {
    <#
      Pure: the sign-in settings as kept in the settings file, with defaults - Entra (on/off), the group that may
      sign in (its ID, and its name for showing), and whether the admin password still works too (the way in
      when Entra ID can't be reached, or the setting is wrong).
    #>
    param($Raw)
    $s = [ordered]@{ Entra = $false; GroupId = ''; GroupName = ''; AllowPassword = $true }
    if (-not $Raw) { return $s }
    $s.Entra = [bool]$Raw.Entra
    $g = [string]$Raw.GroupId
    $gid = [guid]::Empty
    if ([guid]::TryParse($g.Trim(), [ref]$gid)) { $s.GroupId = $gid.ToString() }
    $s.GroupName = ([string]$Raw.GroupName).Trim()
    if ($s.GroupName.Length -gt 256) { $s.GroupName = $s.GroupName.Substring(0, 256) }
    if ($null -ne $Raw.AllowPassword) { $s.AllowPassword = [bool]$Raw.AllowPassword }
    # Entra sign-in needs its group; without one, only the password signs in.
    if (-not $s.GroupId) { $s.Entra = $false }
    if (-not $s.Entra) { $s.AllowPassword = $true }
    return $s
}

function Global:Get-EntraAuthorizeUrl {
    # Pure: where the browser is sent to sign in - the tenant's own authority (only its accounts), code + PKCE.
    param([string]$Authority = 'https://login.microsoftonline.com', [string]$TenantId, [string]$ClientId, [string]$RedirectUri,
        [string]$State, [string]$Nonce, [string]$CodeChallenge)
    $enc = { param($v) [uri]::EscapeDataString([string]$v) }
    $q = [ordered]@{
        client_id = $ClientId; response_type = 'code'; redirect_uri = $RedirectUri; response_mode = 'query'
        scope = 'openid profile'; state = $State; nonce = $Nonce; code_challenge = $CodeChallenge; code_challenge_method = 'S256'
        prompt = 'select_account'
    }
    $query = ($q.GetEnumerator() | ForEach-Object { "$($_.Key)=$(& $enc $_.Value)" }) -join '&'
    return "$($Authority.TrimEnd('/'))/$(& $enc $TenantId)/oauth2/v2.0/authorize?$query"
}

function Global:Test-EntraIdTokenClaims {
    <#
      Pure: whether an ID token's claims are the ones this sign-in asked for - '' when they are, else why not.
      The token comes straight from the token endpoint over TLS, to this app as the confidential client (with
      its certificate): OpenID Connect lets the issuer be trusted from that, without checking the signature
      (Core 1.0, 3.1.3.7). Checked here: the audience (this app), the issuer (the tenant's v2.0 authority), the
      tenant when it is set as an ID, the nonce of this very sign-in, the times, and that it names a user.
    #>
    param($Claims, [string]$ClientId, [string]$TenantId, [string]$Nonce, [string]$Authority = 'https://login.microsoftonline.com', [datetime]$Now = [datetime]::UtcNow)
    if (-not $Claims) { return 'no ID token' }
    if ([string]$Claims.aud -ne $ClientId) { return 'it was issued for another app' }
    $tid = [string]$Claims.tid
    $g = [guid]::Empty
    if (-not [guid]::TryParse($tid, [ref]$g)) { return 'it names no tenant' }
    if ([guid]::TryParse([string]$TenantId, [ref]$g) -and $tid -ne $g.ToString()) { return 'it is from another tenant' }
    if ([string]$Claims.iss -ne "$($Authority.TrimEnd('/'))/$tid/v2.0") { return 'its issuer is not the tenant''s' }
    if (-not $Nonce -or [string]$Claims.nonce -ne $Nonce) { return 'it is not the answer to this sign-in' }
    $epoch = [datetime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
    if (-not $Claims.exp -or $epoch.AddSeconds([double]$Claims.exp) -lt $Now.AddMinutes(-2)) { return 'it has expired' }
    if ($Claims.nbf -and $epoch.AddSeconds([double]$Claims.nbf) -gt $Now.AddMinutes(5)) { return 'it is not valid yet' }
    if (-not [guid]::TryParse([string]$Claims.oid, [ref]$g)) { return 'it names no user' }
    return ''
}
