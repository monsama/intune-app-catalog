# Intune App Catalog & Deployment
# Copyright (C) 2026 Viktor Ljuca <https://monsama.ch>
# SPDX-License-Identifier: GPL-2.0-or-later

<#
  The local web server behind the web interface - the same design as the
  NOBS SQL Editor's PowerShell edition:

    - listens on 127.0.0.1 only, on a fixed port (so the browser's per-site
      storage survives a restart), falling back to a random one
    - a token that is new for every start; the page gets it in the URL's
      #fragment (never sent over the wire by the browser) and every /api/
      call must carry it
    - only requests addressed to 127.0.0.1/localhost are answered (a web
      page elsewhere can point its own name at 127.0.0.1 - DNS rebinding -
      and the Host header is what gives that away), API calls only as a
      JSON POST from this origin
    - every response: no framing, no sniffing, no caching, a CSP that lets
      the page talk to nothing but this server
    - each request runs in a pooled runspace, so a slow Graph call doesn't
      block the page's other requests
    - stops when the app window closes, on Quit, or after 6 hours without
      the page's ping
#>

function Global:Read-WebRequest {
    param($Client)
    $ns = $Client.GetStream(); $ns.ReadTimeout = 8000
    $ms = New-Object System.IO.MemoryStream; $buf = New-Object byte[] 16384; $headerEnd = -1
    try {
        while ($true) {
            $read = $ns.Read($buf, 0, $buf.Length); if ($read -le 0) { break }
            $ms.Write($buf, 0, $read); $arr = $ms.ToArray()
            # Headers end within 64 KB or the request isn't answered - a client
            # that never ends them would otherwise grow this buffer forever.
            if ($headerEnd -lt 0 -and $arr.Length -gt 64KB -and -not (Test-WebHeaderEnd $arr)) { return $null }
            for ($i = [Math]::Max(0, $arr.Length - $read - 3); $i -le $arr.Length - 4; $i++) {
                if ($arr[$i] -eq 13 -and $arr[$i + 1] -eq 10 -and $arr[$i + 2] -eq 13 -and $arr[$i + 3] -eq 10) { $headerEnd = $i; break }
            }
            if ($headerEnd -ge 0) {
                $headerText = [Text.Encoding]::ASCII.GetString($arr, 0, $headerEnd); $contentLength = 0
                if ($headerText -match '(?im)^Content-Length:\s*(\d+)') { $contentLength = [int]$Matches[1] }
                if ($contentLength -gt 10MB) { return $null }
                $bodyStart = $headerEnd + 4; $have = $arr.Length - $bodyStart
                while ($have -lt $contentLength) { $read = $ns.Read($buf, 0, $buf.Length); if ($read -le 0) { break }; $ms.Write($buf, 0, $read); $have += $read }
                $arr = $ms.ToArray(); $body = ''
                if ($contentLength -gt 0) { $body = [Text.Encoding]::UTF8.GetString($arr, $bodyStart, [Math]::Min($contentLength, $arr.Length - $bodyStart)) }
                $parts = (($headerText -split "`r`n")[0]) -split ' '
                if ($parts.Count -lt 3 -or [string]$parts[1] -notmatch '^/') { return $null }
                $hostHeader = if ($headerText -match '(?im)^Host:[ \t]*([^\r\n]*)') { $Matches[1].Trim() } else { '' }
                $originHeader = if ($headerText -match '(?im)^Origin:[ \t]*([^\r\n]*)') { $Matches[1].Trim() } else { $null }
                $typeHeader = if ($headerText -match '(?im)^Content-Type:[ \t]*([^\r\n]*)') { $Matches[1].Trim() } else { '' }
                $path = [string]$parts[1]
                $q = $path.IndexOf('?'); if ($q -ge 0) { $path = $path.Substring(0, $q) }
                return @{ Method = $parts[0]; Path = $path; Body = $body; Host = $hostHeader; Origin = $originHeader; ContentType = $typeHeader }
            }
        }
    }
    catch { }
    return $null
}

function Global:Test-WebHeaderEnd {
    # Whether the bytes hold the blank line that ends HTTP headers.
    param([byte[]]$Bytes)
    for ($i = 0; $i -le $Bytes.Length - 4; $i++) {
        if ($Bytes[$i] -eq 13 -and $Bytes[$i + 1] -eq 10 -and $Bytes[$i + 2] -eq 13 -and $Bytes[$i + 3] -eq 10) { return $true }
    }
    return $false
}

function Global:Send-WebResponse {
    param($Client, [string]$Status, [string]$ContentType, [byte[]]$Body)
    $security = "X-Frame-Options: DENY`r`nX-Content-Type-Options: nosniff`r`nReferrer-Policy: no-referrer`r`n" +
        "Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; font-src 'self' data:; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'`r`n"
    $head = "HTTP/1.1 $Status`r`nContent-Type: $ContentType`r`nContent-Length: $($Body.Length)`r`nCache-Control: no-store`r`n$security" + "Connection: close`r`n`r`n"
    $headBytes = [Text.Encoding]::ASCII.GetBytes($head)
    $ns = $Client.GetStream(); $ns.Write($headBytes, 0, $headBytes.Length)
    if ($Body.Length) { $ns.Write($Body, 0, $Body.Length) }
    $ns.Flush()
}

function Global:Send-WebJson {
    param($Client, $Object)
    $json = if ($Object -is [string]) { $Object } else { $Object | ConvertTo-Json -Depth 12 -Compress }
    Send-WebResponse $Client '200 OK' 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($json))
}

function Global:Test-WebToken {
    # Constant-time compare, so the time a wrong guess takes says nothing
    # about how much of it was right.
    param($Data, [string]$Expected)
    if (-not $Data -or -not $Expected) { return $false }
    $t = $Data.token
    if ($t -isnot [string] -or $t.Length -ne $Expected.Length) { return $false }
    $d = 0
    for ($i = 0; $i -lt $t.Length; $i++) { $d = $d -bor ([int][char]$t[$i] -bxor [int][char]$Expected[$i]) }
    return ($d -eq 0)
}

function Global:Test-WebRequestAllowed {
    <#
      Pure: whether a request may be answered at all, and if not, why.
      Host must name this machine (DNS rebinding); API calls must be JSON
      POSTs from this origin or none (a cross-site form can't send JSON).
    #>
    param([hashtable]$Request)
    if (-not $Request) { return 'unreadable' }
    if ([string]$Request.Host -notmatch '^(127\.0\.0\.1|localhost|\[::1\])(:\d+)?$') { return 'host' }
    if ([string]$Request.Path -like '/api/*') {
        $originOk = ($null -eq $Request.Origin) -or ([string]$Request.Origin -match '^http://(127\.0\.0\.1|localhost|\[::1\])(:\d+)?$')
        if (-not $originOk) { return 'origin' }
        if ($Request.Method -ne 'POST' -or [string]$Request.ContentType -notmatch '^application/json') { return 'method' }
    }
    return ''
}

function Global:Get-WebStaticFile {
    <#
      The interface's own files, by name - a fixed list, so no path from
      the request is ever joined to a folder.
    #>
    param([string]$Path, [string]$UiRoot)
    $files = @{
        '/'            = @('index.html', 'text/html; charset=utf-8')
        '/index.html'  = @('index.html', 'text/html; charset=utf-8')
        '/core.js'     = @('core.js', 'text/javascript; charset=utf-8')
        '/apps.js'     = @('apps.js', 'text/javascript; charset=utf-8')
        '/checks.js'   = @('checks.js', 'text/javascript; charset=utf-8')
        '/groups.js'   = @('groups.js', 'text/javascript; charset=utf-8')
        '/scripts.js'  = @('scripts.js', 'text/javascript; charset=utf-8')
        '/settings.js' = @('settings.js', 'text/javascript; charset=utf-8')
        '/app.js'      = @('app.js', 'text/javascript; charset=utf-8')
        '/app.css'     = @('app.css', 'text/css; charset=utf-8')
        '/icon.svg'    = @('icon.svg', 'image/svg+xml')
    }
    if (-not $files.ContainsKey($Path)) { return $null }
    $file = Join-Path $UiRoot $files[$Path][0]
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $null }
    return @{ Bytes = [System.IO.File]::ReadAllBytes($file); ContentType = $files[$Path][1] }
}

function Global:Start-WebAppWindow {
    <#
      Opens the interface in Edge (or Chrome) as an app window - a normal
      Windows window (move, snap, minimize, maximize, close), maximized,
      with no tabs or address bar - with a profile of its own, so the process handed
      back is really this window's (that's how the server notices it was
      closed), and nothing installed in the user's own browser (password
      managers, extensions pushed by policy) gets into it. Returns the
      process, or $null when neither browser is there.
    #>
    param([string]$Url)
    $candidates = @(
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    )
    $exe = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    if (-not $exe) { return $null }
    $browserProfile = Join-Path $env:LOCALAPPDATA 'IntuneAppCatalog\browser'
    if (-not (Test-Path -LiteralPath $browserProfile)) { [void](New-Item -ItemType Directory -Path $browserProfile -Force) }
    $arguments = @(
        "--app=$Url", "--user-data-dir=`"$browserProfile`"", '--no-first-run', '--no-default-browser-check',
        '--disable-extensions', '--disable-save-password-bubble', '--disable-session-crashed-bubble',
        '--disable-features=AutofillServerCommunication,Translate', '--start-maximized'
    )
    return (Start-Process -FilePath $exe -ArgumentList $arguments -PassThru)
}

function Global:Write-Log {
    <#
      The app's log: the lines go to the page's Activity box (/api/log)
      and the daily log file. -Color is accepted and ignored, so older
      callers that pass one keep working.
    #>
    param([string]$Text, $Color = $null)
    $line = (Protect-LogText ($Text -replace "`r`n", "`n")).TrimEnd("`n")
    if (-not $line) { return }
    $level = if ($line -match '^\s*\[(FAILED|ERROR)\]') { 'error' } elseif ($line -match '^\s*\[(WARN)\]') { 'warn' } elseif ($line -match '^\s*\[OK\]') { 'ok' } else { 'info' }
    # $null check, not truthiness: an empty list is $false in PowerShell, so the
    # first line would never get in.
    if ($null -ne $Global:App.WebLog) {
        [void]$Global:App.WebLog.Add([pscustomobject]@{ Time = (Get-Date).ToString('HH:mm:ss'); Level = $level; Text = $line })
        while ($Global:App.WebLog.Count -gt 2000) { $Global:App.WebLog.RemoveAt(0) }
    }
    if ($Global:App.WebLogFile) {
        try { Add-Content -LiteralPath $Global:App.WebLogFile -Value "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) $line" -Encoding UTF8 } catch { }
    }
}
