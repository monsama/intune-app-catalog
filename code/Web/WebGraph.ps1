# Intune App Catalog & Deployment
# Copyright (C) 2026 Viktor Ljuca <https://monsama.ch>
# SPDX-License-Identifier: GPL-2.0-or-later

<#
.SYNOPSIS
    How the web interface's pages read Microsoft Graph from a request
    (Invoke-WebGraph), and the stand-in the server tests use instead of a
    tenant.

    Test mode: when the environment variable INTUNE_CATALOG_TEST_GRAPH names
    a JSON file at start-up (Enable-WebTestGraph), every Graph call is
    answered from that file and nothing signs in. The console says so in
    red. Only the tests set it.
#>

function Global:Enable-WebTestGraph {
    <#
      Called once at start-up. With INTUNE_CATALOG_TEST_GRAPH set to a JSON
      file: Graph answers come from it, and the connection counts as set up
      (made-up IDs, in memory only - never saved unless Settings is saved).
    #>
    $path = [string]$env:INTUNE_CATALOG_TEST_GRAPH
    if (-not $path) { return $false }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "INTUNE_CATALOG_TEST_GRAPH names '$path', which doesn't exist." }
    $answers = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $Global:App.TestGraph = @{ Path = $path; Answers = $answers; Counters = [hashtable]::Synchronized(@{}) }
    if ([string]::IsNullOrWhiteSpace($Global:App.GraphTenantId)) { $Global:App.GraphTenantId = '00000000-0000-0000-0000-00000000000a' }
    if ([string]::IsNullOrWhiteSpace($Global:App.GraphClientId)) { $Global:App.GraphClientId = '00000000-0000-0000-0000-00000000000b' }
    if ([string]::IsNullOrWhiteSpace($Global:App.GraphCertificateThumbprint)) { $Global:App.GraphCertificateThumbprint = ('0' * 40) }
    $Global:App.GraphModuleHereConfirmed = $true
    return $true
}

function Global:Get-WebTestGraphAnswer {
    <#
      Pure apart from -Counters: the stored answer to one request, as
      @{ Status; Reason; Text }. -Answers maps "METHOD path?query" (or just
      "METHOD path", for any query) to the JSON Graph would send - relative
      to https://graph.microsoft.com/, escapes undone. A list is a sequence:
      the first call gets the first entry, the last one repeats. An entry
      with __status answers with that status and __body.
    #>
    param($Answers, [string]$Method, [string]$Uri, [hashtable]$Counters)
    $relative = [Uri]::UnescapeDataString(($Uri -replace '^https://graph\.microsoft\.com/', ''))
    $keys = @("$Method $relative", "$Method $(($relative -split '\?', 2)[0])")
    $entry = $null; $found = $null
    foreach ($k in $keys) {
        $prop = $Answers.PSObject.Properties | Where-Object { [Uri]::UnescapeDataString($_.Name) -ceq $k } | Select-Object -First 1
        if ($prop) { $entry = $prop.Value; $found = $k; break }
    }
    if ($null -eq $found) {
        return @{ Status = 404; Reason = 'Not Found'; Text = (@{ error = @{ code = 'Request_ResourceNotFound'; message = "No stored answer for $($keys[0])" } } | ConvertTo-Json -Compress -Depth 5) }
    }
    if ($entry -is [System.Array]) {
        $n = 0
        if ($Counters) { $n = [int]$Counters[$found]; $Counters[$found] = $n + 1 }
        $entry = $entry[[Math]::Min($n, $entry.Count - 1)]
    }
    if ($null -ne $entry -and $entry.PSObject.Properties.Name -contains '__status') {
        $status = [int]$entry.__status
        $reason = switch ($status) { 400 { 'Bad Request' } 401 { 'Unauthorized' } 403 { 'Forbidden' } 404 { 'Not Found' } 429 { 'Too Many Requests' } default { 'Error' } }
        $text = if ($null -ne $entry.__body) { $entry.__body | ConvertTo-Json -Compress -Depth 20 } else { '' }
        return @{ Status = $status; Reason = $reason; Text = $text }
    }
    return @{ Status = 200; Reason = 'OK'; Text = $(if ($null -ne $entry) { $entry | ConvertTo-Json -Compress -Depth 20 } else { '' }) }
}

function Global:Get-WebTestGraphMemoryAnswer {
    <#
      Test mode with "__memory" in the answers file (2.38.44): Intune's own memory of an app, so a test can send,
      read back and compare - what a PATCH sent to mobileApps/{id}, an app created there and the relationships set
      with updateRelationships are kept in <answers file>.memory.json and given back on GET, laid over the stored
      answer as Intune would merge them. $null for every other request (the stored answers answer those).
      Steps run in other processes: the file is their shared memory.
    #>
    param($Answers, [string]$Path, [string]$Method, [string]$Uri, [string]$BodyText)
    if (-not $Answers -or -not ($Answers.PSObject.Properties.Name -contains '__memory')) { return $null }
    $rel = [Uri]::UnescapeDataString(($Uri -replace '^https://graph\.microsoft\.com/', ''))
    if ($rel -notmatch '^beta/deviceAppManagement/mobileApps(?:/([0-9a-fA-F-]{36}))?(/updateRelationships|/relationships)?(?:\?.*)?$') { return $null }
    $id = ([string]$Matches[1]).ToLowerInvariant(); $sub = [string]$Matches[2]
    $file = "$Path.memory.json"
    $mem = if (Test-Path -LiteralPath $file) { Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json } else { [pscustomobject]@{} }
    $save = { [System.IO.File]::WriteAllText($file, (ConvertTo-Json -InputObject $mem -Depth 30 -Compress), (New-Object System.Text.UTF8Encoding($false))) }
    $entry = { param($k) if (-not ($mem.PSObject.Properties.Name -contains $k)) { $mem | Add-Member -NotePropertyName $k -NotePropertyValue ([pscustomobject]@{ app = [pscustomobject]@{}; rels = $null }) }; $mem.$k }
    $body = if ($BodyText) { $BodyText | ConvertFrom-Json } else { $null }
    $ok = { param($o) @{ Status = 200; Reason = 'OK'; Text = $(if ($null -ne $o) { ConvertTo-Json -InputObject $o -Depth 30 -Compress } else { '' }) } }
    $stored = { param($k) $a = Get-WebTestGraphAnswer -Answers $Answers -Method 'GET' -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$k"; if ($a.Status -eq 200 -and $a.Text) { $a.Text | ConvertFrom-Json } else { $null } }
    $m = $Method.ToUpperInvariant()
    if ($m -eq 'POST' -and -not $id -and -not $sub -and $body) {
        $newId = [guid]::NewGuid().ToString()
        $e = & $entry $newId
        foreach ($p in $body.PSObject.Properties) { $e.app | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force }
        $e.app | Add-Member -NotePropertyName id -NotePropertyValue $newId -Force
        & $save; return (& $ok $e.app)
    }
    if (-not $id) { return $null }
    if ($m -eq 'PATCH' -and -not $sub) {
        $e = & $entry $id
        foreach ($p in @($(if ($body) { $body.PSObject.Properties }))) { $e.app | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force }
        & $save; return (& $ok $null)
    }
    if ($m -eq 'POST' -and $sub -eq '/updateRelationships') {
        $e = & $entry $id
        # As Intune lists them: the target's name, and this app as the parent.
        $e.rels = @(@($(if ($body) { $body.relationships })) | Where-Object { $_ } | ForEach-Object {
                $t = ([string]$_.targetId).ToLowerInvariant()
                $tn = if ($mem.PSObject.Properties.Name -contains $t -and $mem.$t.app.displayName) { [string]$mem.$t.app.displayName } else { $sa = & $stored $t; [string]$(if ($sa) { $sa.displayName }) }
                $o = [ordered]@{}; foreach ($p in $_.PSObject.Properties) { $o[$p.Name] = $p.Value }
                $o['targetType'] = 'child'; $o['targetDisplayName'] = $tn
                [pscustomobject]$o
            })
        & $save; return (& $ok $null)
    }
    if ($m -eq 'GET' -and $sub -eq '/relationships' -and $mem.PSObject.Properties.Name -contains $id -and $null -ne $mem.$id.rels) { return (& $ok ([pscustomobject]@{ value = @($mem.$id.rels) })) }
    if ($m -eq 'GET' -and -not $sub -and $mem.PSObject.Properties.Name -contains $id) {
        $base = & $stored $id
        $o = [ordered]@{}
        if ($base) { foreach ($p in $base.PSObject.Properties) { $o[$p.Name] = $p.Value } }
        foreach ($p in $mem.$id.app.PSObject.Properties) { $o[$p.Name] = $p.Value }
        $o['id'] = $id
        return (& $ok ([pscustomobject]$o))
    }
    return $null
}

function Global:Invoke-WebGraph {
    <#
      Runs -Action with Graph connected app-only (reusing a matching
      connection). -Action gets one argument: a scriptblock (Uri, Method,
      Body) that calls Graph and returns the parsed JSON, throwing
      "<status> <reason>: <body>". Returns @{ ok; value } or
      @{ ok = $false; error } with the error made readable. -Permission: the
      application permission the calling page needs, named when Graph
      refuses the request.

      Throttling (429) and brief outages (503/504) are retried inside the
      Graph module itself (its retry handler honours Retry-After).
    #>
    param([scriptblock]$Action, [string]$Permission)
    if (-not (Test-GraphCredentialsConfigured -Quiet)) { return @{ ok = $false; error = 'Set up the connection in Settings first.' } }
    try {
        $test = $Global:App.TestGraph
        if ($test) {
            $call = {
                param([string]$Uri, [string]$Method = 'GET', $Body = $null)
                # A $batch call is answered request by request from the same answers, as Graph would.
                if ($Method -eq 'POST' -and $Uri -match '^https://graph\.microsoft\.com/(beta|v1\.0)/\$batch$') {
                    $ver = $Matches[1]
                    $responses = foreach ($r in @($Body.requests)) {
                        $one = Get-WebTestGraphAnswer -Answers $test.Answers -Method ([string]$r.method) -Uri ("https://graph.microsoft.com/$ver" + [string]$r.url) -Counters $test.Counters
                        [pscustomobject]@{ id = [string]$r.id; status = [int]$one.Status; body = $(if ($one.Text) { $one.Text | ConvertFrom-Json } else { $null }) }
                    }
                    return [pscustomobject]@{ responses = @($responses) }
                }
                $answer = Get-WebTestGraphMemoryAnswer -Answers $test.Answers -Path $test.Path -Method $Method -Uri $Uri -BodyText $(if ($null -eq $Body) { '' } elseif ($Body -is [string]) { $Body } else { ConvertTo-Json -InputObject $Body -Depth 20 -Compress })
                if (-not $answer) { $answer = Get-WebTestGraphAnswer -Answers $test.Answers -Method $Method -Uri $Uri -Counters $test.Counters }
                if ($answer.Status -ge 300) { throw "$($answer.Status) $($answer.Reason): $($answer.Text)" }
                if ($answer.Text) { $answer.Text | ConvertFrom-Json } else { $null }
            }.GetNewClosure()
        }
        else {
            Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
            $ctx = Get-MgContext -ErrorAction SilentlyContinue
            $thumb = $Global:App.GraphCertificateThumbprint
            if ($null -eq $ctx -or $ctx.AuthType -ne 'AppOnly' -or $ctx.ClientId -ne $Global:App.GraphClientId -or ($thumb -and $ctx.CertificateThumbprint -and $ctx.CertificateThumbprint -ne $thumb)) {
                Connect-MgGraph -TenantId $Global:App.GraphTenantId -ClientId $Global:App.GraphClientId -CertificateThumbprint $thumb -NoWelcome -ErrorAction Stop
            }
            $call = {
                param([string]$Uri, [string]$Method = 'GET', $Body = $null)
                $p = @{ Uri = $Uri; Method = $Method; OutputType = 'HttpResponseMessage'; ErrorAction = 'Stop' }
                if ($null -ne $Body) { $p.Body = $Body; $p.ContentType = 'application/json' }
                $response = Invoke-MgGraphRequest @p
                $text = if ($response.Content) { $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() } else { '' }
                if (-not $response.IsSuccessStatusCode) { throw "$([int]$response.StatusCode) $($response.ReasonPhrase): $text" }
                if ($text) { $text | ConvertFrom-Json } else { $null }
            }
        }
        $value = & $Action $call
        if ($Permission -and $Global:App.MissingPermissions -and $Global:App.MissingPermissions.ContainsKey($Permission)) { $Global:App.MissingPermissions.Remove($Permission) }
        return @{ ok = $true; value = $value }
    }
    catch {
        $msg = Get-InnermostErrorMessage $_.Exception
        $friendly = ConvertTo-FriendlyGraphError $msg
        if ($Permission -and "$msg" -match '\b40[13]\b|Forbidden|Unauthorized|Authorization_RequestDenied') {
            # One short sentence on the page (the full answer from Graph goes to the log), and Home says so until it works.
            $kind = if ($Permission -match ' and ') { 'application permissions' } else { 'application permission' }
            Write-Log "[WARN] Graph refused a request for lack of $Permission - $(Protect-LogText $msg)"
            if (-not $Global:App.MissingPermissions) { $Global:App.MissingPermissions = [hashtable]::Synchronized(@{}) }
            $Global:App.MissingPermissions[$Permission] = (Get-Date).ToString('HH:mm', [Globalization.CultureInfo]::InvariantCulture)
            return @{ ok = $false; permission = $Permission; error = "the app registration is missing the API permission $Permission ($kind, with admin consent) - Settings > Connection, In Entra ID: Add required permissions... (on the server: Entra setup script...) adds it." }
        }
        return @{ ok = $false; error = (Protect-LogText $friendly) }
    }
}

function Global:Invoke-WebGraphBatch {
    <#
      GET requests through Graph's $batch, 20 to a call (inside
      Invoke-WebGraph: -Graph is its call). -Requests: @(@{ id; url }) with
      url relative to the version, e.g. "/deviceAppManagement/mobileApps/<id>".
      Returns @{ <id> = @{ status; body } }. A request Graph throttled (429)
      is tried once more on its own.
    #>
    param([scriptblock]$Graph, $Requests, [string]$Version = 'beta')
    $out = @{}
    $list = @($Requests)
    for ($i = 0; $i -lt $list.Count; $i += 20) {
        $chunk = @($list[$i..([Math]::Min($i + 19, $list.Count - 1))])
        $body = @{ requests = @($chunk | ForEach-Object { @{ id = [string]$_.id; method = 'GET'; url = [string]$_.url } }) }
        $res = & $Graph "https://graph.microsoft.com/$Version/`$batch" 'POST' $body
        foreach ($r in @($res.responses)) {
            $rid = [string]$r.id
            $out[$rid] = @{ status = [int]$r.status; body = $r.body }
        }
        foreach ($c in $chunk) {
            $cid = [string]$c.id
            if (-not $out.ContainsKey($cid) -or $out[$cid].status -eq 429) {
                try { $out[$cid] = @{ status = 200; body = (& $Graph ("https://graph.microsoft.com/$Version" + [string]$c.url)) } }
                catch { $code = if ("$($_.Exception.Message)" -match '^(\d{3})') { [int]$Matches[1] } else { 500 }; $out[$cid] = @{ status = $code; body = $null } }
            }
        }
    }
    return $out
}
