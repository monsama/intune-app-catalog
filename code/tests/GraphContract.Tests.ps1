<#
.SYNOPSIS
    Checks every Graph type and property this app depends on against
    Microsoft's own published $metadata.

.DESCRIPTION
    GraphContract.json lists what the app writes into request bodies and
    reads out of responses. This fetches Graph's CSDL - which is public,
    needs no tenant and no credentials - and asserts each of those still
    exists.

    The point is to hear about a removal or a rename from CI on a quiet
    Monday rather than from somebody whose deployment just failed with a
    400.

    Its limit, measured: $metadata says what Graph DECLARES, not what it
    accepts. minimumSupportedOperatingSystem is still in beta $metadata
    today despite being replaced in practice by
    minimumSupportedWindowsRelease and rejected by the API - so this check
    passes on it. Behavioural deprecation like that needs a live call
    against a real tenant, which is the Diagnostics tab's job, not this
    one's.

    A failure here is NOT necessarily this app's bug - it usually means
    Microsoft moved something and the app has to follow. Read it as news,
    not as a regression.

    Deliberately not part of tests.yml: it needs the internet, and it can
    start failing because of a change nobody here made. A normal push must
    not go red for that. It runs on a schedule instead.

.PARAMETER Namespace
    Only check one ('beta' or 'v1.0'). Default: every namespace the
    manifest uses.

.EXAMPLE
    pwsh -NoProfile -File code/tests/GraphContract.Tests.ps1
#>
param(
    [string]$Namespace = '',
    [int]$TimeoutSec = 90
)
$ErrorActionPreference = 'Stop'

$script:passCount = 0
$script:failures = New-Object System.Collections.Generic.List[string]
function Assert-True {
    param([bool]$Condition, [string]$What, [string]$Detail = '')
    if ($Condition) { $script:passCount++; Write-Host "  ok   $What" -ForegroundColor DarkGray }
    else {
        $line = "$What$(if ($Detail) { "`n    $Detail" })"
        $script:failures.Add($line)
        Write-Host "  FAIL $What$(if ($Detail) { " - $Detail" })" -ForegroundColor Red
    }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$manifestPath = Join-Path $repoRoot 'code\GraphContract.json'
if (-not (Test-Path -LiteralPath $manifestPath)) { throw "Manifest not found: $manifestPath" }
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

$wanted = @($manifest.namespaces.PSObject.Properties.Name)
if ($Namespace) { $wanted = @($wanted | Where-Object { $_ -eq $Namespace }) }

foreach ($ns in $wanted) {
    Write-Host "`n=== Graph $ns `$metadata ===" -ForegroundColor Cyan
    $uri = "https://graph.microsoft.com/$ns/`$metadata"
    try {
        $previous = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try { $response = Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec $TimeoutSec }
        finally { $ProgressPreference = $previous }
    }
    catch {
        # Unreachable is not drift. Say which it is, and fail - a check
        # that silently passes when it could not look is worse than none.
        Assert-True $false "could fetch $ns `$metadata" $_.Exception.Message
        continue
    }
    Assert-True ($response.StatusCode -eq 200) "$ns `$metadata came back 200" "got $($response.StatusCode)"

    $xml = [xml]$response.Content
    $edm = @{ edm = 'http://docs.oasis-open.org/odata/ns/edm' }
    # Both, because a detection rule is a ComplexType and an app is an
    # EntityType, and the manifest should not have to care which.
    $declared = @{}
    $baseOf = @{}
    foreach ($node in @(Select-Xml -Xml $xml -XPath '//edm:EntityType | //edm:ComplexType' -Namespace $edm)) {
        $typeName = [string]$node.Node.Name
        if (-not $typeName) { continue }
        if (-not $declared.ContainsKey($typeName)) { $declared[$typeName] = New-Object System.Collections.Generic.HashSet[string] }
        foreach ($property in @($node.Node.Property)) {
            if ($property.Name) { [void]$declared[$typeName].Add([string]$property.Name) }
        }
        foreach ($navigation in @($node.Node.NavigationProperty)) {
            if ($navigation.Name) { [void]$declared[$typeName].Add([string]$navigation.Name) }
        }
        # "graph.mobileLobApp" -> "mobileLobApp". win32LobApp declares
        # barely any of its own properties: displayName comes from
        # mobileApp, committedContentVersion from mobileLobApp, id from
        # entity. Without this the check reports every inherited property
        # as missing, which is a drift detector that cries wolf - and one
        # nobody would look at twice.
        $base = [string]$node.Node.BaseType
        if ($base) { $baseOf[$typeName] = ($base -split '\.')[-1] }
    }
    Assert-True ($declared.Count -gt 100) "$ns `$metadata parsed into types" "found $($declared.Count)"

    # Every property a type has, its own and everything it inherits.
    $effective = {
        param([string]$Name)
        $all = New-Object System.Collections.Generic.HashSet[string]
        $seen = New-Object System.Collections.Generic.HashSet[string]
        $cursor = $Name
        while ($cursor -and $declared.ContainsKey($cursor) -and $seen.Add($cursor)) {
            foreach ($p in $declared[$cursor]) { [void]$all.Add($p) }
            $cursor = if ($baseOf.ContainsKey($cursor)) { $baseOf[$cursor] } else { $null }
        }
        return $all
    }

    foreach ($entry in @($manifest.namespaces.$ns)) {
        $typeName = [string]$entry.type
        if (-not $declared.ContainsKey($typeName)) {
            Assert-True $false "$ns type '$typeName' still exists" "needed for: $($entry.why)"
            continue
        }
        $available = & $effective $typeName
        $anywhere = $null
        $missing = 0
        foreach ($propertyName in @($entry.properties)) {
            if ($available.Contains($propertyName)) { continue }
            $missing++
            if ($null -eq $anywhere) {
                $anywhere = New-Object System.Collections.Generic.HashSet[string]
                foreach ($set in $declared.Values) { foreach ($p in $set) { [void]$anywhere.Add($p) } }
            }
            # Saying WHERE it went is most of the work of fixing it: still
            # in the namespace means renamed or moved to another type,
            # gone entirely means the feature went with it.
            $elsewhere = if ($anywhere.Contains($propertyName)) { "still exists on some other type - moved, or renamed here" } else { "gone from $ns entirely" }
            Assert-True $false "$ns $typeName.$propertyName still exists" "$elsewhere ($($entry.why))"
        }
        if ($missing -eq 0) {
            $script:passCount++
            Write-Host "  ok   $ns $typeName - all $(@($entry.properties).Count) properties present" -ForegroundColor DarkGray
        }
    }
}

Write-Host ""
if ($script:failures.Count -eq 0) {
    Write-Host "PASSED: $($script:passCount) check(s), 0 failure(s)." -ForegroundColor Green
    exit 0
}
Write-Host "FAILED: $($script:failures.Count) of $($script:passCount + $script:failures.Count) check(s)." -ForegroundColor Red
Write-Host "Graph may have moved something this app uses - see code/GraphContract.json." -ForegroundColor Yellow
foreach ($f in $script:failures) { Write-Host "`n$f" -ForegroundColor Red }
exit 1
