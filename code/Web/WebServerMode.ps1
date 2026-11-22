# Intune App Catalog & Deployment
# Copyright (C) 2026 Viktor Ljuca <https://monsama.ch>
# SPDX-License-Identifier: GPL-2.0-or-later

<#
.SYNOPSIS
    Server mode - the app as a container (Docker), reached over the network
    behind a reverse proxy, instead of on 127.0.0.1 with an app window.

    On when the environment says ICA_SERVER=1 (the image sets it):
      - listens on every address of the container, port ICA_PORT (8080)
      - answers only requests addressed to the names in ICA_HOST (and
        localhost, for the health check) - DNS rebinding as on the desktop
      - one admin: the password is read from the file ICA_ADMIN_PASSWORD_FILE
        (a Docker secret) at start, kept only as a salted hash
      - one session at a time: signing in ends the session that was open
        (that browser is told it was taken over), it also ends after
        ICA_IDLE_MINUTES (120) without use and ICA_SESSION_HOURS (12) after
        sign-in
      - the page gets the session's token at sign-in and sends it with every
        call, as the desktop app's page sends its start token
#>

function Global:Test-WebServerMode { return ([string]$env:ICA_SERVER -match '^(1|true|yes|on)$') }

function Global:Initialize-WebServerMode {
    <#
      Reads the server's settings from the environment into $Global:App.Server.
      Throws when the admin password can't be read - a server nobody can
      sign in to (or anyone can) must not start.
    #>
    $hosts = @(([string]$env:ICA_HOST) -split '[,;\s]+' | Where-Object { $_ } | ForEach-Object { $_.Trim().ToLowerInvariant() })
    $file = if ($env:ICA_ADMIN_PASSWORD_FILE) { [string]$env:ICA_ADMIN_PASSWORD_FILE } else { '/run/secrets/admin_password' }
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "The admin password file $file isn't there - the deploy script writes it (secrets/admin_password)." }
    $password = ([System.IO.File]::ReadAllText($file)).Trim()
    if ($password.Length -lt 12) { throw "The admin password in $file is shorter than 12 characters - set a longer one." }
    $salt = New-Object byte[] 16; $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create(); try { $rng.GetBytes($salt) } finally { $rng.Dispose() }
    $Global:App.Server = [hashtable]::Synchronized(@{
            Port = $(if ([int]$env:ICA_PORT -gt 0) { [int]$env:ICA_PORT } else { 8080 })
            Hosts = $hosts
            AllowHttp = ([string]$env:ICA_ALLOW_HTTP -match '^(1|true|yes|on)$')
            Salt = $salt
            Hash = (Get-WebPasswordHash -Password $password -Salt $salt)
            IdleMinutes = $(if ([int]$env:ICA_IDLE_MINUTES -gt 0) { [int]$env:ICA_IDLE_MINUTES } else { 120 })
            SessionHours = $(if ([int]$env:ICA_SESSION_HOURS -gt 0) { [int]$env:ICA_SESSION_HOURS } else { 12 })
            Session = $null
            Ended = (New-Object System.Collections.ArrayList)
            Fails = (New-Object System.Collections.ArrayList)
            # Sign in with Microsoft: sign-ins under way (state -> nonce, PKCE verifier) and finished ones waiting
            # for their page to pick the session up (one-time handoff code -> token), each for a few minutes.
            Pending = [hashtable]::Synchronized(@{})
            Handoffs = [hashtable]::Synchronized(@{})
            # ICA_PASSWORD_SIGNIN=1: the admin password works whatever Settings says (the way back in when
            # Sign in with Microsoft was set up wrong).
            ForcePassword = ([string]$env:ICA_PASSWORD_SIGNIN -match '^(1|true|yes|on)$')
        })
    $password = $null
}

function Global:Get-WebPasswordHash {
    # PBKDF2 (SHA-256, 200 000 rounds) - slow on purpose, so a guess costs time.
    param([string]$Password, [byte[]]$Salt)
    $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($Password, $Salt, 200000, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    try { return , $kdf.GetBytes(32) } finally { $kdf.Dispose() }
}

function Global:Test-WebBytesEqual {
    # Constant time: how long it takes says nothing about how much matched.
    param([byte[]]$A, [byte[]]$B)
    if ($null -eq $A -or $null -eq $B -or $A.Length -ne $B.Length) { return $false }
    $d = 0
    for ($i = 0; $i -lt $A.Length; $i++) { $d = $d -bor ($A[$i] -bxor $B[$i]) }
    return ($d -eq 0)
}

function Global:Get-WebTokenDigest {
    param([string]$Token)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return [Convert]::ToBase64String($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([string]$Token))) } finally { $sha.Dispose() }
}

function Global:Test-WebHostAllowed {
    # Pure apart from $Global:App.Server: the Host header names this server (its public names, or localhost).
    # localhost only from this machine itself (the health check): another container on the proxy's network
    # reaching the app directly, around the HTTPS proxy, has to use the public name - and is refused below.
    param([string]$HostHeader, [string]$Peer = '127.0.0.1')
    $h = ([string]$HostHeader).Trim().ToLowerInvariant()
    if ($h -match '^(127\.0\.0\.1|localhost|\[::1\])(:\d+)?$') { return (Test-WebLoopback $Peer) }
    $s = $Global:App.Server
    if (-not $s) { return $false }
    $name = $h -replace ':\d+$', ''
    return (@($s.Hosts) -contains $name)
}

function Global:Test-WebTrustedProxy {
    <#
      Whether a connection's address is the HTTPS proxy in front (ICA_TRUSTED_PROXY: names or addresses,
      default nobs-proxy - the container's name on the Docker network). Names are looked up again every
      5 minutes (a restarted proxy can get another address). Only its X-Forwarded-For is believed.
    #>
    param([string]$Peer)
    $s = $Global:App.Server
    if (-not $s -or -not $Peer) { return $false }
    $p = $Peer -replace '^::ffff:', ''
    $c = $s.TrustedProxy
    if (-not $c -or ((Get-Date) - $c.At).TotalMinutes -gt 5) {
        $names = @(([string]$(if ($env:ICA_TRUSTED_PROXY) { $env:ICA_TRUSTED_PROXY } else { 'nobs-proxy' })) -split '[,;\s]+' | Where-Object { $_ })
        $ips = New-Object System.Collections.Generic.List[string]
        foreach ($n in $names) {
            $a = $null
            if ([System.Net.IPAddress]::TryParse($n, [ref]$a)) { $ips.Add(($a.ToString() -replace '^::ffff:', '')); continue }
            try { foreach ($x in [System.Net.Dns]::GetHostAddresses($n)) { $ips.Add(($x.ToString() -replace '^::ffff:', '')) } } catch { }
        }
        # No address for it (another proxy is in front, ICA_TRUSTED_PROXY not set to it): every client would be
        # counted as the proxy - wrong passwords from anyone would lock the admin out. Said once (2.38.0).
        if (-not $ips.Count -and -not $s.TrustedProxyWarned) { $s.TrustedProxyWarned = $true; Write-Log "[WARN] The trusted proxy ($($names -join ', ')) has no address here: clients are counted by the proxy's address, so wrong passwords from anyone count for everyone. Set ICA_TRUSTED_PROXY to the proxy in front (its container name or address)." }
        $c = @{ At = Get-Date; Ips = @($ips) }; $s.TrustedProxy = $c
    }
    return (@($c.Ips) -contains $p)
}

function Global:Get-WebThrottleKey {
    # The address wrong passwords are counted for: IPv4 as it is, IPv6 by its /64 (one line hands out a whole
    # /64 - counting single addresses would let a guesser just take the next one).
    param([string]$Address)
    $a = $null
    if (-not [System.Net.IPAddress]::TryParse([string]$Address, [ref]$a)) { return [string]$Address }
    if ($a.IsIPv4MappedToIPv6) { $a = $a.MapToIPv4() }
    if ($a.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetworkV6) { return $a.ToString() }
    return ((($a.GetAddressBytes())[0..7] | ForEach-Object { $_.ToString('x2') }) -join '') + '::/64'
}

function Global:Test-WebLoopback {
    # Whether a connection's address is this machine's own (127.x, ::1, or IPv4 mapped into IPv6). '' counts:
    # no address known (the desktop version listens on 127.0.0.1 only).
    param([string]$Peer)
    if (-not $Peer) { return $true }
    $p = $Peer -replace '^::ffff:', ''
    return ($p -match '^127\.' -or $p -eq '::1')
}

function Global:Test-WebOriginAllowed {
    # No Origin (a same-origin GET, the health check), or this server's own: https://<name>, http only when allowed.
    param([string]$Origin, [string]$Peer = '127.0.0.1')
    if ([string]::IsNullOrEmpty($Origin)) { return $true }
    $o = $Origin.Trim().ToLowerInvariant()
    if ($o -match '^http://(127\.0\.0\.1|localhost|\[::1\])(:\d+)?$') { return (Test-WebLoopback $Peer) }
    $s = $Global:App.Server
    if (-not $s) { return $false }
    $m = [regex]::Match($o, '^(https?)://([^/:]+)(:\d+)?$')
    if (-not $m.Success) { return $false }
    if ($m.Groups[1].Value -eq 'http' -and -not $s.AllowHttp) { return $false }
    return (@($s.Hosts) -contains $m.Groups[2].Value)
}

function Global:Invoke-WebLogin {
    <#
      Signs the admin in: a new session, and the one that was open ends (its
      browser is told it was taken over). Five wrong passwords within a
      minute from one address: none from there is checked for a minute (per
      address, so someone else guessing can't lock the admin out). Attempts
      being checked count too - many at once don't get past the limit.
    #>
    param($Data, [string]$Agent, [string]$Client = '')
    $s = $Global:App.Server
    $now = [DateTime]::UtcNow
    # Back from signing in with Microsoft: the page trades its one-time code for the session (WebEntraSignIn.ps1).
    if ($Data -and $Data.handoff) { return (Complete-WebEntraHandoff ([string]$Data.handoff)) }
    if (-not (Test-WebPasswordSignInAllowed)) { return @{ ok = $false; error = 'The admin password is turned off - sign in with Microsoft.' } }
    $key = if ($Client) { Get-WebThrottleKey $Client } else { '?' }
    $mine = @{ Key = $key; At = $now; Pending = $true }
    [System.Threading.Monitor]::Enter($s.Fails)
    try {
        foreach ($t in @($s.Fails)) { if (($now - $t.At).TotalSeconds -gt 60 -and -not $t.Pending) { [void]$s.Fails.Remove($t) } }
        if (@($s.Fails | Where-Object { $_.Key -eq $key }).Count -ge 5) { return @{ ok = $false; error = 'Too many wrong passwords - wait a minute, then try again.' } }
        [void]$s.Fails.Add($mine)
    }
    finally { [System.Threading.Monitor]::Exit($s.Fails) }
    $ok = $false
    try {
        $given = [string]$Data.password
        if ($given.Length -gt 256) { $given = $given.Substring(0, 256) }
        $ok = Test-WebBytesEqual -A (Get-WebPasswordHash -Password $given -Salt $s.Salt) -B $s.Hash
    }
    finally {
        [System.Threading.Monitor]::Enter($s.Fails)
        try { if ($ok) { [void]$s.Fails.Remove($mine) } else { $mine.Pending = $false; $mine.At = [DateTime]::UtcNow } }
        finally { [System.Threading.Monitor]::Exit($s.Fails) }
    }
    if (-not $ok) {
        Write-Log "[WARN] A sign-in with a wrong password (from $key)."
        return @{ ok = $false; error = 'Wrong password.' }
    }
    return (New-WebSession -Agent $Agent -Method 'password' -Name 'Admin (password)')
}

function Global:New-WebSession {
    <#
      The one session: a new token, and the session that was open ends (its browser is told it was taken over).
      -Method: password or entra; -Name/-Upn/-Oid: who (with Microsoft: the Entra ID account).
    #>
    param([string]$Agent, [string]$Method, [string]$Name, [string]$Upn = '', [string]$Oid = '')
    $s = $Global:App.Server
    $now = [DateTime]::UtcNow
    $bytes = New-Object byte[] 32; $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create(); try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $token = -join ($bytes | ForEach-Object { $_.ToString('x2') })
    $cut = { param($t, $n) $t = [string]$t; $t.Substring(0, [Math]::Min($n, $t.Length)) }
    [System.Threading.Monitor]::Enter($s.Ended)
    try {
        $old = $s.Session
        if ($old) { [void]$s.Ended.Add(@{ Digest = $old.Digest; Reason = 'takenover'; At = $now; By = $(if ($Method -eq 'entra') { & $cut $Name 120 } else { '' }) }); while ($s.Ended.Count -gt 20) { $s.Ended.RemoveAt(0) } }
        $s.Session = @{ Digest = (Get-WebTokenDigest $token); Token = $token; Created = $now; Last = $now; Agent = (& $cut $Agent 160)
            Method = $Method; Name = (& $cut $Name 120); Upn = (& $cut $Upn 120); Oid = $Oid }
    }
    finally { [System.Threading.Monitor]::Exit($s.Ended) }
    Write-Log "[INFO] Signed in: $(& $cut $Name 120)$(if ($Upn) { " ($(& $cut $Upn 120))" })$(if ($old) { ' - the session that was open has ended' })."
    return @{ ok = $true; token = $token; tookOver = [bool]$old }
}

function Global:Test-WebPasswordSignInAllowed {
    # The admin password: on unless Sign in with Microsoft is on and the password turned off - or forced on (ICA_PASSWORD_SIGNIN).
    $s = $Global:App.Server
    if ($s -and $s.ForcePassword) { return $true }
    $si = ConvertTo-SignInSettings $Global:App.SignIn
    return [bool]$si.AllowPassword
}

function Global:Test-WebSession {
    <#
      Whether -Token is the open session's: '' when it is, otherwise why not -
      'takenover' (someone signed in since), 'expired' (idle or too old),
      'signin' (no session, or a token that never was one).
    #>
    param([string]$Token)
    $s = $Global:App.Server
    # The session and the list of ended ones change from requests running at the same time: one lock.
    [System.Threading.Monitor]::Enter($s.Ended)
    try {
        $cur = $s.Session
        $now = [DateTime]::UtcNow
        if ($cur -and (($now - $cur.Last).TotalMinutes -gt $s.IdleMinutes -or ($now - $cur.Created).TotalHours -gt $s.SessionHours)) {
            [void]$s.Ended.Add(@{ Digest = $cur.Digest; Reason = 'expired'; At = $now }); $s.Session = $null; $cur = $null
            while ($s.Ended.Count -gt 20) { $s.Ended.RemoveAt(0) }
        }
        if (-not $Token -or $Token -notmatch '^[0-9a-f]{64}$') { return 'signin' }
        $digest = Get-WebTokenDigest $Token
        if ($cur -and (Test-WebBytesEqual -A ([Convert]::FromBase64String($digest)) -B ([Convert]::FromBase64String($cur.Digest)))) {
            # Written at most once a minute: not on every call.
            if (($now - $cur.Last).TotalSeconds -gt 60) { $cur.Last = $now }
            return ''
        }
        $was = @($s.Ended) | Where-Object { $_.Digest -eq $digest } | Select-Object -Last 1
        if ($was) { return [string]$was.Reason }
        return 'signin'
    }
    finally { [System.Threading.Monitor]::Exit($s.Ended) }
}

function Global:Invoke-WebLogout {
    param([string]$Token)
    $s = $Global:App.Server
    if ((Test-WebSession $Token) -eq '') {
        [System.Threading.Monitor]::Enter($s.Ended)
        try { if ($s.Session) { [void]$s.Ended.Add(@{ Digest = $s.Session.Digest; Reason = 'signedout'; At = [DateTime]::UtcNow }); while ($s.Ended.Count -gt 20) { $s.Ended.RemoveAt(0) } }; $s.Session = $null }
        finally { [System.Threading.Monitor]::Exit($s.Ended) }
        Write-Log "[INFO] Admin signed out."
    }
    return @{ ok = $true }
}

# ---------------------------------------------------------------- the connection's certificate in the container
# Linux has no Cert: drive and no Windows certificate tools, but .NET's own user store works there (a folder in
# $HOME, which the image puts on the data volume) - and the Graph module finds a certificate in it by thumbprint.

function Global:Import-WebPfx {
    <#
      A .pfx (with its private key) into the user's store, for the connection: -Data.pfx is the file as
      base64, -Data.password its password. The key is kept so it can sign in; nothing else is changed.
    #>
    param($Data)
    $b64 = [string]$Data.pfx
    if (-not $b64 -or $b64.Length -gt 200000) { return @{ ok = $false; error = 'Choose a .pfx file (at most about 140 KB).' } }
    try { $bytes = [Convert]::FromBase64String($b64) } catch { return @{ ok = $false; error = "That isn't a file the page could read." } }
    $flags = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]'PersistKeySet,Exportable'
    try { $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new([byte[]]$bytes, [string]$Data.password, $flags) }
    catch { return @{ ok = $false; error = "The .pfx couldn't be opened - is the password right? ($($_.Exception.Message))" } }
    if (-not $cert.HasPrivateKey) { return @{ ok = $false; error = 'That file has no private key - export the certificate with its private key (.pfx).' } }
    if ($cert.NotAfter -le (Get-Date)) { return @{ ok = $false; error = "That certificate expired on $($cert.NotAfter.ToString('yyyy-MM-dd'))." } }
    $st = New-Object System.Security.Cryptography.X509Certificates.X509Store('My', [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
    try { $st.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite); $st.Add($cert) } finally { $st.Close() }
    Write-Log "[OK] Certificate imported: $($cert.Subject) ($($cert.Thumbprint))."
    return @{ ok = $true; thumbprint = $cert.Thumbprint; subject = $cert.Subject; notAfter = $cert.NotAfter.ToString('yyyy-MM-dd') }
}

function Global:Get-WebCertificateFile {
    # The public part of a certificate in the store, as a .cer (base64) - what Entra ID's app registration takes.
    param($Data)
    $cert = Find-AppStoreCertificate ([string]$Data.thumbprint)
    if (-not $cert) { return @{ ok = $false; error = 'No certificate with that thumbprint here - choose or create one first.' } }
    $raw = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
    $name = (($cert.Subject -replace '^CN=', '' -replace '[^\w .-]', '') + '.cer').Trim()
    return @{ ok = $true; file = [Convert]::ToBase64String($raw); name = $(if ($name -eq '.cer') { "$($cert.Thumbprint).cer" } else { $name }) }
}

function Global:New-AppSelfSignedCertificate {
    <#
      A self-signed certificate made with .NET (where New-SelfSignedCertificate isn't there - Linux), its key in
      the user's store: RSA 2048, SHA-256, for signing, two years.
    #>
    param([string]$Subject)
    $rsa = [System.Security.Cryptography.RSA]::Create(2048)
    $req = New-Object System.Security.Cryptography.X509Certificates.CertificateRequest($Subject, $rsa, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $req.CertificateExtensions.Add((New-Object System.Security.Cryptography.X509Certificates.X509KeyUsageExtension([System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature, $true)))
    $made = $req.CreateSelfSigned([DateTimeOffset]::Now.AddMinutes(-5), [DateTimeOffset]::Now.AddYears(2))
    # Through a .pfx so the key is one the store keeps (not the request's in-memory one).
    $pfx = $made.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx)
    $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new([byte[]]$pfx, [string]'', [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]'PersistKeySet,Exportable')
    $st = New-Object System.Security.Cryptography.X509Certificates.X509Store('My', [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
    try { $st.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite); $st.Add($cert) } finally { $st.Close() }
    $rsa.Dispose()
    return $cert
}

# ---------------------------------------------------------------- the nightly run without Windows' scheduled tasks
function Global:Invoke-WebServerSchedule {
    <#
      Called by the server's loop every half minute. When the nightly run is on (Settings > Nightly run & alerts):
      the run at its time each day - and once the container is back when it was down at that time - and the
      fast-track run every 2 hours, each as its own process (IntuneDeployment.ps1 -RunUpdates), as Windows'
      scheduled tasks would start it. Never two at once; when each last started is kept in data\server-schedule.json.
    #>
    param([hashtable]$State)
    $p = $Global:App.ReleasePolicy
    if (-not $p -or -not $p.ServerSchedule) { return }
    if ($State.Run -and -not $State.Run.HasExited) { return }
    $file = Join-Path $Global:App.RootPath 'data\server-schedule.json'
    if (-not $State.Loaded) {
        $State.Loaded = $true
        try { $j = Get-Content -LiteralPath $file -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json; $State.Nightly = [datetime]$j.nightly; $State.FastTrack = [datetime]$j.fastTrack } catch { }
    }
    $now = Get-Date
    $at = [datetime]::ParseExact("$($now.ToString('yyyy-MM-dd')) $($p.RunAt)", 'yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture)
    # Schedule just switched on, or moved to a time already past today (Set-WebUpdateSchedule): today's is done.
    $done = $Global:App.ServerScheduleDoneToday
    if ($done) { $Global:App.ServerScheduleDoneToday = $null; if (-not $State.Nightly -or $State.Nightly -lt $done) { $State.Nightly = $done } }
    $extra = $null
    if ($now -ge $at -and (-not $State.Nightly -or $State.Nightly -lt $at)) { $extra = @(); $State.Nightly = $now }
    elseif (-not $State.FastTrack -or ($now - $State.FastTrack).TotalHours -ge 2) { $extra = @('-FastTrackOnly'); $State.FastTrack = $now }
    if ($null -eq $extra) {
        if ($done) { try { [System.IO.File]::WriteAllText($file, (@{ nightly = $State.Nightly.ToString('o'); fastTrack = $(if ($State.FastTrack) { $State.FastTrack.ToString('o') }) } | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false))) } catch { } }
        return
    }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = (Get-Process -Id $PID).Path
        foreach ($a in @('-NoLogo', '-NoProfile', '-File', (Join-Path $Global:App.RootPath 'IntuneDeployment.ps1'), '-RunUpdates') + $extra) { $psi.ArgumentList.Add($a) }
        $psi.UseShellExecute = $false
        $State.Run = [System.Diagnostics.Process]::Start($psi)
        Write-Log "[INFO] $(if ($extra.Count) { 'Fast-track run' } else { 'Nightly run' }) started (the server's schedule)."
    }
    catch { Write-Log "[FAILED] The $(if ($extra.Count) { 'fast-track' } else { 'nightly' }) run couldn't start: $($_.Exception.Message)" }
    try { [System.IO.File]::WriteAllText($file, (@{ nightly = $(if ($State.Nightly) { $State.Nightly.ToString('o') }); fastTrack = $(if ($State.FastTrack) { $State.FastTrack.ToString('o') }) } | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false))) } catch { }
}
