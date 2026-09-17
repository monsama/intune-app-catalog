# What this app sends to Microsoft Graph, shown in the log boxes:
#   - every write (POST/PATCH/PUT/DELETE) as its own line, always
#   - reads (GET) summarized ("[GRAPH] 12 read request(s) (1.4 s)"), or one
#     line each when "Detailed Graph log" is on (Log tab)
#   - every failed request with its status text and Graph's request-id -
#     what Microsoft support asks for
# Only method, address and outcome are logged - never tokens, headers or
# request bodies.
#
# Two places make Graph requests, and both report through the same format:
#   - the embedded deployment scripts (separate powershell.exe processes,
#     see Start-PipelineProcess): their Invoke-GraphRequestDetailed calls
#     Write-GraphRequestLog, which Start-PipelineProcess dot-sources from
#     Get-GraphLogScriptHelpers before running the script. Output flows
#     into the dialog's log box and the Log tab like everything else the
#     script prints.
#   - this app's own background lookups (GraphFetch.ps1 runspaces): they
#     call Invoke-LoggedGraphRequest (Initialize-GraphLogRunspace), which
#     records each request on the runspace's Information stream;
#     Write-GraphLogFromStreams turns those into Log tab lines when the
#     lookup finishes.

function Global:Get-GraphRequestPath {
    # "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/x" -> "/beta/deviceAppManagement/mobileApps/x"
    param([string]$Uri)
    $path = [string]$Uri -replace '^https?://graph\.microsoft\.com', ''
    if ($path.Length -gt 180) { $path = $path.Substring(0, 177) + '...' }
    return $path
}

function Global:Get-GraphRequestId {
    # Graph's request-id (or client-request-id) from an error message or response body, if there is one.
    param([string]$Text)
    if ([string]$Text -match '"(?:request-id|client-request-id)"\s*:\s*"([0-9a-fA-F-]{36})"') { return $Matches[1] }
    if ([string]$Text -match '(?:request-id|client-request-id)\W{1,3}([0-9a-fA-F-]{36})') { return $Matches[1] }
    return $null
}

function Global:ConvertTo-GraphLogLine {
    <#
      [GRAPH] PATCH /beta/deviceAppManagement/mobileApps/<id> -> OK (310 ms)
      [GRAPH] GET /v1.0/groups/<id> -> FAILED (95 ms): <first line of the error> (request-id <id>)
    #>
    param([string]$Method, [string]$Uri, [long]$Milliseconds, [string]$ErrorText, [string]$Detail)
    $verb = if ($Method) { $Method.ToUpperInvariant() } else { 'GET' }
    $line = "[GRAPH] $verb $(Get-GraphRequestPath $Uri)"
    if (-not $ErrorText) { return "$line -> OK ($Milliseconds ms)" }
    $reason = (([string]$ErrorText -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 1)
    if ($reason.Length -gt 200) { $reason = $reason.Substring(0, 197) + '...' }
    $line += " -> FAILED ($Milliseconds ms): $reason"
    $requestId = Get-GraphRequestId "$Detail`n$ErrorText"
    if ($requestId -and $reason -notmatch [regex]::Escape($requestId)) { $line += " (request-id $requestId)" }
    return $line
}

function Global:ConvertTo-GraphReadSummary {
    # "[GRAPH] Intune app lookup: 4 read request(s) (1.2 s)" - $null when there were none
    param([int]$Count, [long]$Milliseconds, [string]$Operation)
    if ($Count -le 0) { return $null }
    $prefix = if ($Operation) { "[GRAPH] ${Operation}: " } else { "[GRAPH] " }
    $took = if ($Milliseconds -lt 1000) { "$Milliseconds ms" } else { "$([Math]::Round($Milliseconds / 1000.0, 1).ToString([System.Globalization.CultureInfo]::InvariantCulture)) s" }
    return "$prefix$Count read request(s) ($took)"
}

function Global:Test-GraphLogDetailed {
    # "Detailed Graph log" (Log tab) - in this app, or passed down to a child process
    if ($Global:App -and $Global:App.ContainsKey('DetailedGraphLog')) { return [bool]$Global:App.DetailedGraphLog }
    return ($env:INTUNEPACKAGER_GRAPH_LOG -eq 'detailed')
}

# ---------------------------------------------------------------------------
# Embedded deployment scripts
# ---------------------------------------------------------------------------
function Global:Get-GraphLogScriptHelpers {
    <#
      Script text Start-PipelineProcess dot-sources in the child process
      before the embedded script runs: the formatting functions above plus
      Write-GraphRequestLog / Write-GraphReadSummary, which the scripts'
      Invoke-GraphRequestDetailed calls. Scripts still run fine on their
      own without it (they check for the function first).
    #>
    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add('$global:IntunePackagerGraphLog = @{ Detailed = ($env:INTUNEPACKAGER_GRAPH_LOG -eq ''detailed''); Reads = 0; ReadMs = [long]0 }')
    foreach ($name in 'Get-GraphRequestPath', 'Get-GraphRequestId', 'ConvertTo-GraphLogLine', 'ConvertTo-GraphReadSummary') {
        $parts.Add("function global:$name {`n$((Get-Command $name).ScriptBlock.ToString())`n}")
    }
    $parts.Add(@'
function global:Write-GraphReadSummary {
    $state = $global:IntunePackagerGraphLog
    if ($state.Reads -gt 0 -and -not $state.Detailed) {
        Write-Host (ConvertTo-GraphReadSummary -Count $state.Reads -Milliseconds $state.ReadMs)
    }
    $state.Reads = 0
    $state.ReadMs = [long]0
}
function global:Write-GraphRequestLog {
    param([string]$Method = 'GET', [string]$Uri, [long]$Milliseconds, [string]$ErrorText, [string]$Detail)
    $state = $global:IntunePackagerGraphLog
    $isRead = ([string]$Method).ToUpperInvariant() -eq 'GET'
    if ($isRead -and -not $ErrorText -and -not $state.Detailed) {
        $state.Reads++
        $state.ReadMs += $Milliseconds
        return
    }
    # a write (or anything shown on its own line) comes after the reads that led up to it
    Write-GraphReadSummary
    Write-Host (ConvertTo-GraphLogLine -Method $Method -Uri $Uri -Milliseconds $Milliseconds -ErrorText $ErrorText -Detail $Detail)
}
# Entries a script's parallel workers recorded (they can't call the functions above)
function global:Write-GraphLogFromInformation {
    param($InformationRecords)
    foreach ($record in @($InformationRecords)) {
        $entry = $record.MessageData
        if ($entry -is [hashtable] -and $entry.ContainsKey('IntunePackagerGraphLog')) {
            Write-GraphRequestLog -Method $entry.Method -Uri $entry.Uri -Milliseconds $entry.Milliseconds -ErrorText $entry.ErrorText -Detail $entry.Detail
        }
    }
}
'@)
    return ($parts -join "`n`n")
}

# ---------------------------------------------------------------------------
# This app's own background lookups (GraphFetch.ps1)
# ---------------------------------------------------------------------------
function Global:Initialize-GraphLogRunspace {
    <#
      Defines Invoke-LoggedGraphRequest in a freshly opened runspace: a
      drop-in for Invoke-MgGraphRequest that also records each request on
      the Information stream of whatever pipeline is running.
    #>
    param([System.Management.Automation.Runspaces.Runspace]$Runspace)
    $init = [powershell]::Create()
    try {
        $init.Runspace = $Runspace
        [void]$init.AddScript({
            function global:Invoke-LoggedGraphRequest {
                [CmdletBinding()]
                param([Parameter(Mandatory)][string]$Uri, [string]$Method = 'GET', $Body, [string]$ContentType = 'application/json')
                $timer = [System.Diagnostics.Stopwatch]::StartNew()
                try {
                    $result = if ($null -ne $Body) {
                        Invoke-MgGraphRequest -Uri $Uri -Method $Method -Body $Body -ContentType $ContentType -ErrorAction Stop
                    } else {
                        Invoke-MgGraphRequest -Uri $Uri -Method $Method -ErrorAction Stop
                    }
                    Write-Information -MessageData @{ IntunePackagerGraphLog = $true; Method = $Method; Uri = $Uri; Milliseconds = $timer.ElapsedMilliseconds } -InformationAction SilentlyContinue
                    return $result
                }
                catch {
                    Write-Information -MessageData @{ IntunePackagerGraphLog = $true; Method = $Method; Uri = $Uri; Milliseconds = $timer.ElapsedMilliseconds; ErrorText = $_.Exception.Message; Detail = [string]$_.ErrorDetails.Message } -InformationAction SilentlyContinue
                    throw
                }
            }
        })
        [void]$init.Invoke()
    }
    finally { $init.Dispose() }
}

function Global:New-GraphLogRunspace {
    # An opened runspace with Invoke-LoggedGraphRequest available.
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    Initialize-GraphLogRunspace -Runspace $rs
    return $rs
}

function Global:Write-GraphLogFromStreams {
    <#
      Called on the UI thread when a lookup has finished: writes the
      requests its runspace recorded to the Log tab - failures and writes
      always, reads as one summary line (or one line each when detailed).
    #>
    param($Streams, [string]$Operation)
    if (-not $Streams) { return }
    $detailed = Test-GraphLogDetailed
    $reads = 0
    $readMs = [long]0
    $lines = New-Object System.Collections.Generic.List[object]
    foreach ($record in @($Streams.Information)) {
        $entry = $record.MessageData
        if (-not ($entry -is [hashtable] -and $entry.ContainsKey('IntunePackagerGraphLog'))) { continue }
        $isRead = ([string]$entry.Method).ToUpperInvariant() -eq 'GET'
        if ($isRead -and -not $entry.ErrorText -and -not $detailed) {
            $reads++
            $readMs += [long]$entry.Milliseconds
            continue
        }
        $lines.Add([pscustomobject]@{
            Text   = ConvertTo-GraphLogLine -Method $entry.Method -Uri $entry.Uri -Milliseconds $entry.Milliseconds -ErrorText $entry.ErrorText -Detail $entry.Detail
            Failed = [bool]$entry.ErrorText
        })
    }
    $summary = ConvertTo-GraphReadSummary -Count $reads -Milliseconds $readMs -Operation $Operation
    if ($summary) { Write-Log "$summary`r`n" (Get-DialogLogLineColor -Text $summary) }
    foreach ($l in $lines) {
        $text = if ($Operation -and -not $detailed) { $l.Text -replace '^\[GRAPH\] ', "[GRAPH] ${Operation}: " } else { $l.Text }
        Write-Log "$text`r`n" (Get-DialogLogLineColor -Text $text)
    }
}
