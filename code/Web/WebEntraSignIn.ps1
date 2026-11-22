# Sign in with Microsoft (Entra ID) - the server version's flow. The pure parts (settings, the authorize address,
# the ID token checks) are in code\Private\EntraSignIn.ps1.
#
#   GET /auth/login      a new sign-in: state, nonce and PKCE kept here for 10 minutes; the browser goes to Entra ID
#   GET /auth/callback   Entra ID sends it back with a code: the code is redeemed for an ID token with the app's
#                        certificate (no secret), the token checked, the account checked against the sign-in group
#                        (Graph, app-only), and the one session started - the page picks it up with a one-time code
#                        in the address's #fragment (never sent to a server, gone from the address at once).
#
# Entra ID does the password and the second factor (MFA, Conditional Access): the app never sees either.

function Global:Get-WebEntraAuthority {
    # login.microsoftonline.com - ICA_LOGIN_AUTHORITY only for the tests (a stand-in authority).
    if ($env:ICA_LOGIN_AUTHORITY) { return ([string]$env:ICA_LOGIN_AUTHORITY).TrimEnd('/') }
    return 'https://login.microsoftonline.com'
}

function Global:Get-WebEntraRedirectUri {
    # Where Entra ID sends the browser back: https://<the first ICA_HOST name>/auth/callback (the app registration lists it).
    $s = $Global:App.Server
    $h = if ($s -and @($s.Hosts).Count) { @($s.Hosts)[0] } else { 'localhost' }
    return "https://$h/auth/callback"
}

function Global:Get-WebSignInInfo {
    # For the sign-in page: which ways in there are.
    $si = ConvertTo-SignInSettings $Global:App.SignIn
    return @{ entra = [bool]($si.Entra -and (Test-GraphCredentialsConfigured -Quiet)); password = (Test-WebPasswordSignInAllowed) }
}

function Global:ConvertTo-WebBase64Url {
    param([byte[]]$Bytes)
    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Global:New-WebRandomHex {
    param([int]$Bytes = 16)
    $b = New-Object byte[] $Bytes; $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create(); try { $rng.GetBytes($b) } finally { $rng.Dispose() }
    return (-join ($b | ForEach-Object { $_.ToString('x2') }))
}

function Global:Start-WebEntraSignIn {
    <#
      A new sign-in with Microsoft: returns @{ ok; url } - the Entra ID address the browser goes to - or why not.
      Kept for 10 minutes: its state (the key), nonce and PKCE verifier. At most 5 under way per client
      (-Client, its address) and 200 in all - the oldest goes when it is full (2.38.0): /auth/login needs no
      sign-in, so refusing new ones when full let anyone keep every admin out by asking 50 times.
    #>
    param([string]$Client = '')
    $si = ConvertTo-SignInSettings $Global:App.SignIn
    if (-not $si.Entra) { return @{ ok = $false; why = 'entra-off' } }
    if (-not (Test-GraphCredentialsConfigured -Quiet)) { return @{ ok = $false; why = 'entra-noconnection' } }
    $pending = $Global:App.Server.Pending
    $now = [DateTime]::UtcNow
    foreach ($k in @($pending.Keys)) { if (($now - $pending[$k].At).TotalMinutes -gt 10) { $pending.Remove($k) } }
    $key = if ($Client) { Get-WebThrottleKey $Client } else { '?' }
    if (@($pending.Values | Where-Object { $_.Client -eq $key }).Count -ge 5) { return @{ ok = $false; why = 'entra-busy' } }
    while ($pending.Count -ge 200) { $oldest = @($pending.Keys | Sort-Object { $pending[$_].At })[0]; $pending.Remove($oldest) }
    $state = New-WebRandomHex 16; $nonce = New-WebRandomHex 16
    $vb = New-Object byte[] 32; $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create(); try { $rng.GetBytes($vb) } finally { $rng.Dispose() }
    $verifier = ConvertTo-WebBase64Url $vb
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $challenge = ConvertTo-WebBase64Url ($sha.ComputeHash([Text.Encoding]::ASCII.GetBytes($verifier))) } finally { $sha.Dispose() }
    $pending[$state] = @{ Nonce = $nonce; Verifier = $verifier; At = $now; Client = $key }
    $url = Get-EntraAuthorizeUrl -Authority (Get-WebEntraAuthority) -TenantId $Global:App.GraphTenantId -ClientId $Global:App.GraphClientId `
        -RedirectUri (Get-WebEntraRedirectUri) -State $state -Nonce $nonce -CodeChallenge $challenge
    return @{ ok = $true; url = $url }
}

function Global:ConvertFrom-WebQuery {
    # A query string as a hashtable (first value of each name).
    param([string]$Query)
    $q = @{}
    foreach ($pair in ([string]$Query).TrimStart('?') -split '&') {
        if (-not $pair) { continue }
        $i = $pair.IndexOf('=')
        $k = if ($i -ge 0) { $pair.Substring(0, $i) } else { $pair }
        $v = if ($i -ge 0) { $pair.Substring($i + 1) } else { '' }
        $k = [uri]::UnescapeDataString($k.Replace('+', ' ')); $v = [uri]::UnescapeDataString($v.Replace('+', ' '))
        if (-not $q.ContainsKey($k)) { $q[$k] = $v }
    }
    return $q
}

function Global:Complete-WebEntraCallback {
    <#
      Entra ID sent the browser back. Returns where the browser goes next: the sign-in page with a one-time code
      (#handoff=...) when the account may sign in, else the sign-in page with why not (?why=entra-...).
    #>
    param([string]$Query, [string]$Agent)
    $q = ConvertFrom-WebQuery $Query
    $state = [string]$q['state']
    $pending = $Global:App.Server.Pending
    $p = if ($state -match '^[0-9a-f]{32}$') { $pending[$state] } else { $null }
    if ($p) { $pending.Remove($state) }
    if (-not $p -or ([DateTime]::UtcNow - $p.At).TotalMinutes -gt 10) { return '/login.html?why=entra-expired' }
    if ($q['error']) {
        Write-Log "[WARN] Sign in with Microsoft: Entra ID answered $(Protect-LogText ([string]$q['error'])) - $(Protect-LogText (([string]$q['error_description']) -split "`n")[0])"
        return $(if ($q['error'] -eq 'access_denied') { '/login.html?why=entra-cancelled' } else { '/login.html?why=entra-failed' })
    }
    $code = [string]$q['code']
    if (-not $code -or $code.Length -gt 4000) { return '/login.html?why=entra-failed' }
    try {
        $tenant = $Global:App.GraphTenantId; $client = $Global:App.GraphClientId
        $cert = Find-AppStoreCertificate $Global:App.GraphCertificateThumbprint
        if (-not $cert -or -not $cert.HasPrivateKey) { throw "the connection's certificate (with its private key) isn't on the server" }
        $tokenUri = "$(Get-WebEntraAuthority)/$tenant/oauth2/v2.0/token"
        $response = Invoke-RestMethod -Uri $tokenUri -Method POST -ContentType 'application/x-www-form-urlencoded' -TimeoutSec 20 -ErrorAction Stop -Body @{
            client_id = $client; grant_type = 'authorization_code'; code = $code; redirect_uri = (Get-WebEntraRedirectUri)
            code_verifier = $p.Verifier; scope = 'openid profile'
            client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
            client_assertion = (New-AppClientAssertion -Certificate $cert -ClientId $client -Audience $tokenUri)
        }
        $claims = ConvertFrom-JwtPayload ([string]$response.id_token)
        $bad = Test-EntraIdTokenClaims -Claims $claims -ClientId $client -TenantId $tenant -Nonce $p.Nonce -Authority (Get-WebEntraAuthority)
        if ($bad) { throw "the ID token was refused: $bad" }
    }
    catch {
        Write-Log "[FAILED] Sign in with Microsoft: $(Protect-LogText $_.Exception.Message)"
        return '/login.html?why=entra-failed'
    }
    $who = if ($claims.name) { [string]$claims.name } else { [string]$claims.preferred_username }
    $si = ConvertTo-SignInSettings $Global:App.SignIn
    $member = Test-WebEntraGroupMember -UserId ([string]$claims.oid) -GroupId $si.GroupId
    if (-not $member.ok) {
        Write-Log "[FAILED] Sign in with Microsoft: $who's group membership couldn't be checked - $($member.error)"
        return '/login.html?why=entra-groupcheck'
    }
    if (-not $member.member) {
        Write-Log "[WARN] Sign in with Microsoft refused: $who ($([string]$claims.preferred_username)) isn't in the sign-in group $($si.GroupName)."
        return '/login.html?why=entra-notmember'
    }
    $session = New-WebSession -Agent $Agent -Method 'entra' -Name $who -Upn ([string]$claims.preferred_username) -Oid ([string]$claims.oid)
    $handoffs = $Global:App.Server.Handoffs
    foreach ($k in @($handoffs.Keys)) { if (([DateTime]::UtcNow - $handoffs[$k].At).TotalMinutes -gt 2) { $handoffs.Remove($k) } }
    $h = New-WebRandomHex 16
    $handoffs[$h] = @{ Token = $session.token; TookOver = $session.tookOver; At = [DateTime]::UtcNow }
    return "/login.html#handoff=$h"
}

function Global:Complete-WebEntraHandoff {
    # The sign-in page trades its one-time code for the session's token (once, within 2 minutes).
    param([string]$Code)
    $handoffs = $Global:App.Server.Handoffs
    $h = if ($Code -match '^[0-9a-f]{32}$') { $handoffs[$Code] } else { $null }
    if ($h) { $handoffs.Remove($Code) }
    if (-not $h -or ([DateTime]::UtcNow - $h.At).TotalMinutes -gt 2) { return @{ ok = $false; error = 'That sign-in has expired - sign in again.' } }
    return @{ ok = $true; token = $h.Token; tookOver = [bool]$h.TookOver }
}

function Global:Test-WebEntraGroupMember {
    # Whether the account is in the sign-in group (also through nested groups) - Graph, app-only: @{ ok; member; error }.
    param([string]$UserId, [string]$GroupId)
    $g = [guid]::Empty
    if (-not [guid]::TryParse($UserId, [ref]$g) -or -not [guid]::TryParse($GroupId, [ref]$g)) { return @{ ok = $false; error = 'no account or no group' } }
    $r = Invoke-WebGraph -Permission 'Group.Read.All' -Action {
        param($Graph)
        try {
            $a = & $Graph "https://graph.microsoft.com/v1.0/users/$UserId/checkMemberGroups" 'POST' @{ groupIds = @($GroupId) }
            return (@($a.value) -contains $GroupId)
        }
        catch {
            if ([string]$_.Exception.Message -notmatch '^(403|401)') { throw }
            # Not allowed to ask about the user (GroupMember.Read.All / User.ReadBasic.All missing): the group's own
            # members, nested groups' included, need only Group.Read.All - which the app has for its groups anyway.
            $uri = "https://graph.microsoft.com/v1.0/groups/$GroupId/transitiveMembers?`$select=id&`$top=999"
            for ($page = 0; $uri -and $page -lt 50; $page++) {
                $m = & $Graph $uri
                if (@($m.value | Where-Object { [string]$_.id -eq $UserId }).Count) { return $true }
                $uri = [string]$m.'@odata.nextLink'
            }
            return $false
        }
    }
    if (-not $r.ok) { return @{ ok = $false; error = $r.error } }
    return @{ ok = $true; member = [bool]$r.value }
}

function Global:Get-WebSignInSettings {
    # Settings > Connection > Sign-in: the settings, the address to list in the app registration, and who is signed in now.
    $si = ConvertTo-SignInSettings $Global:App.SignIn
    $cur = $Global:App.Server.Session
    return @{ ok = $true; entra = $si.Entra; groupId = $si.GroupId; groupName = $si.GroupName; allowPassword = $si.AllowPassword
        redirectUri = (Get-WebEntraRedirectUri); forcedPassword = [bool]$Global:App.Server.ForcePassword
        signedInWith = $(if ($cur) { [string]$cur.Method } else { '' }); signedInAs = $(if ($cur) { [string]$cur.Name } else { '' }); upn = $(if ($cur) { [string]$cur.Upn } else { '' }) }
}

function Global:Save-WebSignInSettings {
    <#
      Sign in with Microsoft on/off, the group whose members may sign in (its name or ID - looked up in Entra ID),
      and whether the admin password still works. The password can only be turned off from a session that was
      signed in with Microsoft - proof that the way in works before the other one closes.
    #>
    param($Data)
    $entra = [bool]$Data.entra
    $allowPassword = [bool]$Data.allowPassword
    $groupText = ([string]$Data.group).Trim()
    $next = [ordered]@{ Entra = $entra; GroupId = ''; GroupName = ''; AllowPassword = $allowPassword }
    if ($entra) {
        if (-not (Test-GraphCredentialsConfigured -Quiet)) { return @{ ok = $false; error = 'Set up the connection first (tenant, client ID, certificate) - the sign-in uses the same app registration.' } }
        if (-not $groupText) { return @{ ok = $false; error = 'Name the group whose members may sign in.' } }
        if ($groupText.Length -gt 256) { return @{ ok = $false; error = 'That group name is too long.' } }
        $found = Invoke-WebGraph -Permission 'Group.Read.All' -Action {
            param($Graph)
            $g = [guid]::Empty
            if ([guid]::TryParse($groupText, [ref]$g)) { return @(& $Graph "https://graph.microsoft.com/v1.0/groups/$($g.ToString())?`$select=id,displayName") }
            $filter = [Uri]::EscapeDataString("displayName eq '$($groupText.Replace("'", "''"))'")
            return @((& $Graph "https://graph.microsoft.com/v1.0/groups?`$filter=$filter&`$select=id,displayName&`$top=5").value)
        }
        if (-not $found.ok) { return @{ ok = $false; error = "The group couldn't be looked up: $($found.error)" } }
        $groups = @($found.value | Where-Object { $_ -and $_.id })
        if ($groups.Count -eq 0) { return @{ ok = $false; error = "There is no group '$groupText' in Entra ID." } }
        if ($groups.Count -gt 1) { return @{ ok = $false; error = "More than one group is called '$groupText' - give its object ID instead." } }
        $next.GroupId = [string]$groups[0].id; $next.GroupName = [string]$groups[0].displayName
    }
    $cur = $Global:App.Server.Session
    if ($entra -and -not $allowPassword -and -not ($cur -and $cur.Method -eq 'entra')) {
        return @{ ok = $false; error = 'Sign in with Microsoft once first (sign out, then "Sign in with Microsoft") - then the admin password can be turned off. That way the new way in is proven before the old one closes.' }
    }
    $Global:App.SignIn = ConvertTo-SignInSettings $next
    # (Graph test mode keeps settings in memory only - Write-SettingsFile says so.)
    if (-not (Write-SettingsFile) -and -not $Global:App.TestGraph) { return @{ ok = $false; error = "Couldn't write the settings file." } }
    Write-Log "[OK] Sign-in: $(if ($entra) { "with Microsoft for the members of $($next.GroupName)$(if ($allowPassword) { ', the admin password too' } else { ', the admin password off' })" } else { 'the admin password only' })."
    return (Get-WebSignInSettings)
}
