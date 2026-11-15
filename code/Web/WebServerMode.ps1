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
    $salt = New-Object byte[] 16; [System.Security.Cryptography.RandomNumberGenerator]::Fill($salt)
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
    param([string]$HostHeader)
    $h = ([string]$HostHeader).Trim().ToLowerInvariant()
    if ($h -match '^(127\.0\.0\.1|localhost|\[::1\])(:\d+)?$') { return $true }
    $s = $Global:App.Server
    if (-not $s) { return $false }
    $name = $h -replace ':\d+$', ''
    return (@($s.Hosts) -contains $name)
}

function Global:Test-WebOriginAllowed {
    # No Origin (a same-origin GET, the health check), or this server's own: https://<name>, http only when allowed.
    param([string]$Origin)
    if ([string]::IsNullOrEmpty($Origin)) { return $true }
    $o = $Origin.Trim().ToLowerInvariant()
    if ($o -match '^http://(127\.0\.0\.1|localhost|\[::1\])(:\d+)?$') { return $true }
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
      minute: none is checked for a minute.
    #>
    param($Data, [string]$Agent)
    $s = $Global:App.Server
    $now = [DateTime]::UtcNow
    [System.Threading.Monitor]::Enter($s.Fails)
    try {
        foreach ($t in @($s.Fails)) { if (($now - $t).TotalSeconds -gt 60) { $s.Fails.Remove($t) } }
        if ($s.Fails.Count -ge 5) { return @{ ok = $false; error = 'Too many wrong passwords - wait a minute, then try again.' } }
    }
    finally { [System.Threading.Monitor]::Exit($s.Fails) }
    $given = [string]$Data.password
    if ($given.Length -gt 256) { $given = $given.Substring(0, 256) }
    $ok = Test-WebBytesEqual -A (Get-WebPasswordHash -Password $given -Salt $s.Salt) -B $s.Hash
    if (-not $ok) {
        [System.Threading.Monitor]::Enter($s.Fails); try { [void]$s.Fails.Add($now) } finally { [System.Threading.Monitor]::Exit($s.Fails) }
        Write-Log "[WARN] A sign-in with a wrong password."
        return @{ ok = $false; error = 'Wrong password.' }
    }
    $bytes = New-Object byte[] 32; [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $token = -join ($bytes | ForEach-Object { $_.ToString('x2') })
    $old = $s.Session
    if ($old) { [void]$s.Ended.Add(@{ Digest = $old.Digest; Reason = 'takenover'; At = $now }); while ($s.Ended.Count -gt 20) { $s.Ended.RemoveAt(0) } }
    $s.Session = @{ Digest = (Get-WebTokenDigest $token); Token = $token; Created = $now; Last = $now; Agent = ([string]$Agent).Substring(0, [Math]::Min(160, ([string]$Agent).Length)) }
    Write-Log "[INFO] Admin signed in$(if ($old) { ' - the session that was open has ended' })."
    return @{ ok = $true; token = $token; tookOver = [bool]$old }
}

function Global:Test-WebSession {
    <#
      Whether -Token is the open session's: '' when it is, otherwise why not -
      'takenover' (someone signed in since), 'expired' (idle or too old),
      'signin' (no session, or a token that never was one).
    #>
    param([string]$Token)
    $s = $Global:App.Server
    $cur = $s.Session
    $now = [DateTime]::UtcNow
    if ($cur -and (($now - $cur.Last).TotalMinutes -gt $s.IdleMinutes -or ($now - $cur.Created).TotalHours -gt $s.SessionHours)) {
        [void]$s.Ended.Add(@{ Digest = $cur.Digest; Reason = 'expired'; At = $now }); $s.Session = $null; $cur = $null
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

function Global:Invoke-WebLogout {
    param([string]$Token)
    $s = $Global:App.Server
    if ((Test-WebSession $Token) -eq '') { [void]$s.Ended.Add(@{ Digest = $s.Session.Digest; Reason = 'signedout'; At = [DateTime]::UtcNow }); $s.Session = $null; Write-Log "[INFO] Admin signed out." }
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
    try { $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(, $bytes, [string]$Data.password, $flags) }
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
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(, $pfx, [string]$null, [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]'PersistKeySet,Exportable')
    $st = New-Object System.Security.Cryptography.X509Certificates.X509Store('My', [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
    try { $st.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite); $st.Add($cert) } finally { $st.Close() }
    $rsa.Dispose()
    return $cert
}
