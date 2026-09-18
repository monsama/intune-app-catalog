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

function Global:Get-InnermostErrorMessage {
    <#
      The message of the exception that actually went wrong, not the
      plumbing that carried it. A failure inside a runspace surfaces as
      Exception calling "EndInvoke" with "1" argument(s): "<the real one>"
      which tells the reader nothing about their tenant.
    #>
    param($Exception)
    if ($null -eq $Exception) { return '' }
    try {
        $inner = $Exception.GetBaseException()
        if ($inner -and $inner.Message) { return [string]$inner.Message }
    }
    catch { }
    return [string]$Exception.Message
}

function Global:Get-GraphErrorRecordMessage {
    <#
      An error record from a runspace fetch, as a message worth showing:
      the innermost exception (not the EndInvoke plumbing around it) plus
      Graph's response body, which is where a refusal names the scopes it
      wanted. Without the body a Forbidden reads only as "Forbidden
      (Forbidden)" and Get-GraphPermissionHint has nothing to work from.
    #>
    param($ErrorRecord)
    if (-not $ErrorRecord) { return '' }
    $message = Get-InnermostErrorMessage $ErrorRecord.Exception
    $body = ''
    try { $body = [string]$ErrorRecord.ErrorDetails.Message } catch { }
    # Every exception from here down, not just the outer one: a failure that
    # crossed out of a runspace arrives wrapped in EndInvoke's
    # MethodInvocationException, and the body was stashed on the exception
    # underneath it (Invoke-LoggedGraphRequest) because ErrorDetails doesn't
    # survive that crossing.
    if (-not $body) {
        $exception = $ErrorRecord.Exception
        $guard = 0
        while ($exception -and $guard -lt 10) {
            try {
                if ($exception.Data -and $exception.Data['GraphBody']) {
                    $body = [string]$exception.Data['GraphBody']
                    break
                }
            }
            catch { }
            $exception = $exception.InnerException
            $guard++
        }
    }
    if ($body) { $message = "$message`n$($body.Trim())" }
    return $message
}

function Global:Get-GraphErrorBodyMessage {
    <#
      The sentence out of a Graph error body that says what was actually
      wrong - {"error":{"code":"BadRequest","message":"Invalid select
      column: Foo"}} -> "Invalid select column: Foo".

      Parsed as JSON where possible and matched as text where not, since a
      gateway or proxy can answer with something that isn't Graph's shape.
      Returns $null when there's nothing worth adding.
    #>
    param([string]$Detail)
    if ([string]::IsNullOrWhiteSpace($Detail)) { return $null }
    $message = $null
    try {
        $body = $Detail | ConvertFrom-Json -ErrorAction Stop
        $message = if ($body.error -and $body.error.message) { [string]$body.error.message }
                   elseif ($body.message) { [string]$body.message }
    }
    catch {
        if ($Detail -match '"message"\s*:\s*"((?:[^"\\]|\\.)*)"') {
            $message = $Matches[1] -replace '\\"', '"' -replace '\\r?\\n', ' ' -replace '\\\\', '\'
        }
    }
    if ([string]::IsNullOrWhiteSpace($message)) { return $null }
    # one line, and short enough to sit on the end of the status line
    $message = (($message -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 1).Trim()
    if ($message.Length -gt 300) { $message = $message.Substring(0, 297) + '...' }
    return $message
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
    # "BadRequest (Bad Request)" on its own is undiagnosable. Graph's response
    # body says which property it disliked, so that sentence is worth more
    # than the whole status line - see Get-GraphErrorBodyMessage.
    $why = Get-GraphErrorBodyMessage $Detail
    if ($why -and $reason -notlike "*$why*") { $line += " - $why" }
    $requestId = Get-GraphRequestId "$Detail`n$ErrorText"
    if ($requestId -and $reason -notmatch [regex]::Escape($requestId)) { $line += " (request-id $requestId)" }
    return $line
}

function Global:ConvertTo-GraphReadSummary {
    # "[GRAPH] Intune app lookup: 4 read request(s) (1.2 s)" - $null when there were none
    param([int]$Count, [long]$Milliseconds, [string]$Operation)
    if ($Count -le 0) { return $null }
    $prefix = if ($Operation) { "[GRAPH] ${Operation}: " } else { "[GRAPH] " }
    return "$prefix$Count read request(s) ($(Format-LogDuration $Milliseconds))"
}

function Global:Format-LogDuration {
    # 450 -> "450 ms", 1430 -> "1.4 s"
    param([long]$Milliseconds)
    if ($Milliseconds -lt 1000) { return "$Milliseconds ms" }
    return "$([Math]::Round($Milliseconds / 1000.0, 1).ToString([System.Globalization.CultureInfo]::InvariantCulture)) s"
}

function Global:ConvertTo-RunLogLine {
    <#
      Other programs this app runs, in the same shape as the [GRAPH] lines:
      [RUN] winget search "7zip" -> 12 result(s) (2.3 s)
      [RUN] winget search "7zip" -> FAILED (30.0 s): winget search timed out after 30 seconds.
    #>
    param([string]$Command, [long]$Milliseconds, [string]$Result = 'OK', [string]$ErrorText)
    if ($Command.Length -gt 300) { $Command = $Command.Substring(0, 297) + '...' }
    if (-not $ErrorText) { return "[RUN] $Command -> $Result ($(Format-LogDuration $Milliseconds))" }
    $reason = (([string]$ErrorText -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 1)
    if ($reason.Length -gt 200) { $reason = $reason.Substring(0, 197) + '...' }
    return "[RUN] $Command -> FAILED ($(Format-LogDuration $Milliseconds)): $reason"
}

function Global:Write-RunLogLine {
    # A [RUN] line on the Log tab (UI thread) - never lets logging break the caller
    param([string]$Command, [long]$Milliseconds, [string]$Result = 'OK', [string]$ErrorText)
    try {
        $line = ConvertTo-RunLogLine -Command $Command -Milliseconds $Milliseconds -Result $Result -ErrorText $ErrorText
        Write-Log "$line`r`n" (Get-DialogLogLineColor -Text $line)
    }
    catch { }
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
    foreach ($name in 'Get-GraphRequestPath', 'Get-GraphRequestId', 'Get-GraphErrorBodyMessage', 'ConvertTo-GraphLogLine', 'ConvertTo-GraphReadSummary', 'Format-LogDuration') {
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
                <#
                  -AsStream is for the actions Graph declares as Edm.Stream,
                  such as the install status report. Their body is JSON but
                  it arrives as application/octet-stream, and
                  Invoke-MgGraphRequest refuses to parse that: "Request
                  returned Non-Json response of OctetStream ... Please
                  specify '-OutputFilePath'". Asking for the raw
                  HttpResponseMessage and reading it here avoids a temporary
                  file, and keeps the report in memory where the caller
                  wants it.
                #>
                [CmdletBinding()]
                param([Parameter(Mandatory)][string]$Uri, [string]$Method = 'GET', $Body, [string]$ContentType = 'application/json', [switch]$AsStream)
                $timer = [System.Diagnostics.Stopwatch]::StartNew()
                try {
                    $callParams = @{ Uri = $Uri; Method = $Method; ErrorAction = 'Stop' }
                    if ($null -ne $Body) {
                        $callParams['Body'] = $Body
                        $callParams['ContentType'] = $ContentType
                    }
                    if ($AsStream) { $callParams['OutputType'] = 'HttpResponseMessage' }
                    $result = Invoke-MgGraphRequest @callParams
                    if ($AsStream) {
                        $response = $result
                        $text = ''
                        if ($response.Content) { $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() }
                        # HttpResponseMessage hands back failures instead of
                        # throwing, so the status is checked here - the body
                        # is where Graph says what it objected to.
                        if (-not $response.IsSuccessStatusCode) {
                            $status = "$([int]$response.StatusCode) $($response.ReasonPhrase)"
                            $err = New-Object System.Exception("Response status code does not indicate success: $status.")
                            $err.Data['GraphBody'] = $text
                            throw $err
                        }
                        $result = if ([string]::IsNullOrWhiteSpace($text)) { $null } else { $text | ConvertFrom-Json }
                    }
                    Write-Information -MessageData @{ IntunePackagerGraphLog = $true; Method = $Method; Uri = $Uri; Milliseconds = $timer.ElapsedMilliseconds } -InformationAction SilentlyContinue
                    return $result
                }
                catch {
                    # A streamed call carries Graph's body on the exception,
                    # since there's no ErrorDetails for it to live in.
                    $detail = [string]$_.ErrorDetails.Message
                    if (-not $detail -and $_.Exception.Data -and $_.Exception.Data['GraphBody']) { $detail = [string]$_.Exception.Data['GraphBody'] }
                    # ErrorDetails does NOT survive leaving this runspace:
                    # EndInvoke re-wraps the failure and the caller's record
                    # has none, which is how a refusal reached the dialog as a
                    # bare "Forbidden" while the body was already in the log.
                    # Exception.Data travels with the exception object, so the
                    # body goes there before this is rethrown.
                    if ($detail -and $_.Exception) {
                        try { $_.Exception.Data['GraphBody'] = $detail } catch { }
                    }
                    Write-Information -MessageData @{ IntunePackagerGraphLog = $true; Method = $Method; Uri = $Uri; Milliseconds = $timer.ElapsedMilliseconds; ErrorText = $_.Exception.Message; Detail = $detail } -InformationAction SilentlyContinue
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
      With -LogBox (the dialog that started the lookup) the lines go there
      too, like a deployment script's output does.
    #>
    param($Streams, [string]$Operation, [System.Windows.Forms.RichTextBox]$LogBox)
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
    $out = New-Object System.Collections.Generic.List[string]
    if ($summary) { $out.Add($summary) }
    foreach ($l in $lines) {
        $out.Add($(if ($Operation -and -not $detailed) { $l.Text -replace '^\[GRAPH\] ', "[GRAPH] ${Operation}: " } else { $l.Text }))
    }
    $toDialog = $LogBox -and -not $LogBox.IsDisposed
    foreach ($text in $out) {
        if ($toDialog) { Write-DialogLogLine -LogBox $LogBox -Text "$text`r`n" -MirrorToMainLog }
        else { Write-Log "$text`r`n" (Get-DialogLogLineColor -Text $text) }
    }
}
