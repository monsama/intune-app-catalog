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
                $answer = Get-WebTestGraphAnswer -Answers $test.Answers -Method $Method -Uri $Uri -Counters $test.Counters
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
        return @{ ok = $true; value = (& $Action $call) }
    }
    catch {
        $msg = Get-InnermostErrorMessage $_.Exception
        $friendly = ConvertTo-FriendlyGraphError $msg
        if ($Permission -and "$msg" -match '\b40[13]\b|Forbidden|Unauthorized|Authorization_RequestDenied') {
            $kind = if ($Permission -match ' and ') { 'application permissions' } else { 'application permission' }
            $friendly = "$friendly`nThis needs the $Permission $kind, with admin consent (Settings > API permissions > Add required permissions...)."
        }
        return @{ ok = $false; error = $friendly }
    }
}
