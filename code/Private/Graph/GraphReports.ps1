# Intune's reporting endpoints (/deviceManagement/reports/...) answer with a
# table, not objects: a Schema (one entry per column) plus Values (one array
# per row), which is what the Intune portal's own views are built on. These
# turn that into rows this app can show, and normalize the columns of the
# app install status report, whose exact column set differs between tenants
# and changes with the beta API.
#
# Pure string/table handling only - no WinForms, no Graph call - so it's
# covered by CatalogLogic.Tests.ps1. Start-AppInstallStatusFetch
# (GraphFetch.ps1) does the actual fetching.

function Global:Get-ReportHelperScriptText {
    # The functions below as script text, so a background runspace can
    # dot-source them - same approach as Get-GraphLogScriptHelpers.
    param([string[]]$Names)
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($name in $Names) {
        $parts.Add("function global:$name {`n$((Get-Command $name).ScriptBlock.ToString())`n}")
    }
    return ($parts -join "`n`n")
}

function Global:ConvertFrom-GraphReportTable {
    <#
      { Schema = @({ Column = "DeviceName" }, ...); Values = @(@("PC-1", ...), ...) }
      -> one ordered hashtable per row, keyed by column name.
      Takes a schema entry as an object with .Column/.column or a plain string.
    #>
    param($Report)
    $rows = New-Object System.Collections.Generic.List[object]
    if (-not $Report) { return @() }
    # $Report['Values'], never $Report.Values: a hashtable (what
    # Invoke-MgGraphRequest hands back) has its own .Values property, which
    # returns every value in the hashtable instead of the report's rows.
    # Assigned inside the branches, not as $x = if (...) {...}: the value of
    # an if statement goes through the pipeline, which unrolls a one-element
    # array. For a report with exactly one device that turned Values from
    # "one row of N cells" into "N rows of one cell" - the app then showed a
    # row per column, each holding one cell of the real row.
    $schema = $null
    $values = $null
    if ($Report -is [System.Collections.IDictionary]) {
        $schema = $Report['Schema']
        $values = $Report['Values']
    }
    else {
        $schema = $Report.Schema
        $values = $Report.Values
    }
    $columns = @(@($schema) | ForEach-Object {
        if ($null -eq $_) { "" }
        elseif ($_ -is [string]) { $_ }
        elseif ($_.Column) { [string]$_.Column }
        elseif ($_.column) { [string]$_.column }
        elseif ($_.ColumnName) { [string]$_.ColumnName }
        else { [string]$_ }
    })
    foreach ($value in @($values)) {
        $cells = @($value)
        $row = [ordered]@{}
        for ($i = 0; $i -lt $columns.Count; $i++) {
            $name = $columns[$i]
            if (-not $name) { continue }
            $row[$name] = if ($i -lt $cells.Count) { $cells[$i] } else { $null }
        }
        $rows.Add($row)
    }
    # no leading comma: every caller wraps this in @(), which would then see
    # one element (the array) instead of the rows
    return $rows.ToArray()
}

function Global:Get-ReportColumnValue {
    # First of $Names the row actually has (case-insensitive), or "" - the
    # install status report doesn't name its columns the same everywhere.
    param($Row, [string[]]$Names)
    if (-not $Row) { return "" }
    $keys = @($Row.Keys)
    foreach ($name in $Names) {
        foreach ($key in $keys) {
            if ([string]$key -eq $name) {
                $value = $Row[$key]
                if ($null -ne $value -and "$value" -ne "") { return "$value" }
            }
        }
    }
    return ""
}

function Global:Format-InstallStatusError {
    <#
      An Intune error code as the portal shows it: the decimal the report
      returns plus its hex form, which is what's actually searchable
      ("0x87D00324"). "" for 0/blank - no error.
    #>
    param($ErrorCode)
    $text = "$ErrorCode".Trim()
    if (-not $text -or $text -eq "0") { return "" }
    $number = 0L
    if ([long]::TryParse($text, [ref]$number)) {
        if ($number -eq 0) { return "" }
        # negative codes are the same 32-bit value read as signed. The mask
        # is written as a long on purpose - 0xFFFFFFFF alone is -1 (an int)
        # in PowerShell, which leaves the value negative and uncastable.
        $unsigned = [uint32](([long]$number) -band 0xFFFFFFFFL)
        return ("0x{0:X8} ({1})" -f $unsigned, $number)
    }
    return $text
}

function Global:Format-InstallStatusTime {
    # Graph's timestamp as "2026-09-17 10:14", in THIS machine's time zone
    # (Graph reports UTC) - the seconds and the zone marker just cost
    # column width. Anything unparseable is left exactly as it came.
    param($Value)
    $text = "$Value".Trim()
    if (-not $text) { return "" }
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse($text, [ref]$parsed)) {
        if ($parsed.Kind -eq [System.DateTimeKind]::Utc) { $parsed = $parsed.ToLocalTime() }
        return $parsed.ToString("yyyy-MM-dd HH:mm")
    }
    return $text
}

function Global:ConvertTo-InstallStatusRow {
    <#
      One row of the app install status report, normalized to what the
      dialog shows. Prefers the report's own localized text columns
      (*_loc, what the portal displays); falls back to the raw value, and
      to "State <n>" for a number with no text column, rather than
      guessing which number means what.
    #>
    param($Row)
    $state = Get-ReportColumnValue $Row @('AppInstallState_loc', 'InstallState_loc', 'AppInstallState', 'InstallState', 'installState')
    if ($state -match '^\d+$') { $state = "State $state" }
    $detail = Get-ReportColumnValue $Row @('AppInstallStateDetails_loc', 'InstallStateDetail_loc', 'AppInstallStateDetails', 'InstallStateDetail', 'installStateDetail', 'ErrorDescription')
    if ($detail -match '^\d+$') { $detail = "Detail $detail" }
    return [pscustomobject]@{
        DeviceName = Get-ReportColumnValue $Row @('DeviceName', 'deviceName', 'DeviceName_loc')
        UserName   = Get-ReportColumnValue $Row @('UserPrincipalName', 'userPrincipalName', 'UserName', 'userName', 'UserEmail')
        State      = $state
        Detail     = $detail
        ErrorCode  = Format-InstallStatusError (Get-ReportColumnValue $Row @('ErrorCode', 'errorCode', 'HexErrorCode'))
        Version    = Get-ReportColumnValue $Row @('AppVersion', 'appVersion', 'DisplayVersion', 'displayVersion')
        Platform   = Get-ReportColumnValue $Row @('Platform_loc', 'Platform', 'platform', 'DeviceModel')
        LastSeen   = Format-InstallStatusTime (Get-ReportColumnValue $Row @('LastModifiedDateTime', 'lastModifiedDateTime', 'LastSyncDateTime', 'lastSyncDateTime'))
    }
}

function Global:Get-AppInstallStatusRows {
    <#
      Every device row of the app install status report, paged through.
      -Invoke does the actual Graph call and is called as
      & $Invoke $uri $method $body - so this logic (paging, the fallback
      to the older endpoint, the row cap) is testable without a tenant.

      Returns @{ Rows; Source = 'beta'|'v1.0'; Truncated }.
    #>
    param([string]$AppId, [scriptblock]$Invoke, [int]$PageSize = 200, [int]$MaxRows = 5000)

    # The action is called retrieveDeviceAppInstallationStatusReport. Not
    # getDeviceInstallStatusReport, which several guides still name and which
    # answers "Resource not found for the segment" because no such action
    # exists - checked against Graph's own $metadata, where it appears in
    # neither beta nor v1.0. The same check is why there's no
    # mobileApps/{id}/deviceStatuses fallback any more: that navigation
    # property is gone from mobileApp in both versions, so trying it could
    # only ever produce a second, more confusing error.
    #
    # beta first (it's what the portal's own view uses), v1.0 if the tenant
    # doesn't serve it - the action exists in both.
    $endpoints = @(
        @{ Source = 'beta';  Uri = "https://graph.microsoft.com/beta/deviceManagement/reports/retrieveDeviceAppInstallationStatusReport" }
        @{ Source = 'v1.0';  Uri = "https://graph.microsoft.com/v1.0/deviceManagement/reports/retrieveDeviceAppInstallationStatusReport" }
    )
    $failures = New-Object System.Collections.Generic.List[string]

    foreach ($endpoint in $endpoints) {
        $rows = New-Object System.Collections.Generic.List[object]
        $truncated = $false
        try {
            $skip = 0
            while ($true) {
                # No select: the report returns its own default columns, and
                # ConvertTo-InstallStatusRow already copes with whichever
                # subset a tenant sends. Naming columns here would only add a
                # way to get BadRequest for a column this tenant doesn't have.
                $body = @{
                    filter  = "(ApplicationId eq '$AppId')"
                    orderBy = @()
                    skip    = $skip
                    top     = $PageSize
                }
                $page = & $Invoke $endpoint.Uri "POST" $body
                $pageRows = @(ConvertFrom-GraphReportTable $page)
                foreach ($r in $pageRows) { $rows.Add((ConvertTo-InstallStatusRow $r)) }
                if ($pageRows.Count -lt $PageSize) { break }
                if ($rows.Count -ge $MaxRows) { $truncated = $true; break }
                $skip += $PageSize
            }
            return @{ Rows = $rows.ToArray(); Source = $endpoint.Source; Truncated = $truncated }
        }
        catch {
            # Graph's response body says WHICH property it disliked, and
            # "BadRequest" on its own is undiagnosable without it.
            $message = $_.Exception.Message
            $detail = [string]$_.ErrorDetails.Message
            if ($detail) { $message = "$message`n$($detail.Trim())" }
            $failures.Add("$($endpoint.Source): $message")
        }
    }
    throw "Could not read the install status report.`n$($failures -join "`n")"
}

function Global:Format-InstallStatusSummary {
    <#
      "12 devices: 9 Installed, 2 Failed, 1 Pending" - counted by whatever
      state text came back, most common first, so a state this app has
      never heard of still shows up.
    #>
    param($Rows)
    $all = @($Rows)
    if ($all.Count -eq 0) { return "No install status reported for this app yet." }
    # by name as well as count, so two states with the same count always
    # come out in the same order (Sort-Object isn't stable on 5.1)
    $byState = $all | Group-Object { if ($_.State) { $_.State } else { "Unknown" } } | Sort-Object @{ Expression = 'Count'; Descending = $true }, @{ Expression = 'Name'; Descending = $false }
    $parts = @($byState | ForEach-Object { "$($_.Count) $($_.Name)" })
    $deviceWord = if ($all.Count -eq 1) { "device" } else { "devices" }
    return "$($all.Count) $($deviceWord): $($parts -join ', ')"
}

function Global:Test-InstallStatusRowMatchesFilter {
    # The dialog's state filter: "All" or the exact state text of a row
    param($Row, [string]$Filter)
    if (-not $Filter -or $Filter -eq 'All') { return $true }
    if ($Filter -eq 'Failed only') { return ([string]$Row.State -like '*fail*') }
    return ([string]$Row.State -eq $Filter)
}
