<#
.SYNOPSIS
    Plain, no-framework unit tests for this app's pure, side-effect-free
    catalog logic - the part of this app (under .\Private\Catalog\) that
    doesn't touch WinForms or Microsoft Graph and can genuinely run
    headless.

.DESCRIPTION
    No Pester dependency deliberately - PowerShell Gallery isn't reachable
    from every environment this might need to run in (including the one
    this suite was first written in), and a single self-contained script
    with a tiny assertion helper is enough for the handful of pure
    functions this app actually has. If Pester ever becomes available
    where this runs, these Assert-* calls could be swapped for
    Should/It blocks without changing what's actually being checked.

    IMPORTANT - what this suite does NOT and CANNOT cover: almost all of
    this app's real behavior lives inside WinForms button-click closures
    and embedded scripts that make live Microsoft Graph calls - neither
    is unit-testable this way (WinForms isn't even available outside
    Windows, and Graph calls need a real tenant). This suite is
    deliberately narrow: it only exercises the handful of functions that
    are pure logic with no UI or network dependency. A green run here is
    NOT proof the GUI or the Intune-facing flows work - see this file's
    own header comment in the repo root for what would actually be needed
    to test those (a real sandbox tenant for Graph-facing flows, a
    Windows UI-automation framework for the WinForms flows - both real
    projects in their own right, not something this suite attempts).

    Extracts the functions under test directly from the real script's AST
    (never a hand-copied duplicate) so this suite can't silently drift
    from what actually ships - if a targeted function's signature changes
    incompatibly, these tests fail loudly instead of quietly testing a
    stale copy.

.EXAMPLE
    pwsh -NoProfile -File tests/CatalogLogic.Tests.ps1
#>

$ErrorActionPreference = "Stop"
$script:failures = New-Object System.Collections.Generic.List[string]
$script:passCount = 0

function Assert-Equal {
    param($Expected, $Actual, [string]$Because)
    if ("$Expected" -ne "$Actual") {
        $script:failures.Add("$Because`n    Expected: $Expected`n    Actual:   $Actual")
    } else {
        $script:passCount++
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Because)
    if (-not $Condition) {
        $script:failures.Add("$Because`n    Expected: truthy`n    Actual:   falsy")
    } else {
        $script:passCount++
    }
}

function Assert-Null {
    param($Value, [string]$Because)
    if ($null -ne $Value) {
        $script:failures.Add("$Because`n    Expected: `$null`n    Actual:   $Value")
    } else {
        $script:passCount++
    }
}

# ---------------------------------------------------------------
# Extract the pure functions under test straight from the real source
# files under .\Private\ (never a hand-copied duplicate)
# ---------------------------------------------------------------
# Scans every .\Private\**\*.ps1 file, not just IntuneDeployment.ps1
# directly - since the module rebuild, IntuneDeployment.ps1 itself is
# just a thin entry point that dot-sources those files (plus
# MainApp.ps1) and no longer contains any function BODIES of its own to
# extract an AST from. All 16 functions this suite targets currently
# live in Private\Catalog\, but this deliberately isn't hardcoded to
# just those two files - it's robust to a function moving to a
# different Private\ file later without this suite needing an update
# just to keep finding it.
# Two levels up, not one - this file lives at code\tests\, not tests\
# directly under the repo root (moved there along with Private\ and
# EmbeddedScripts\ under code\). $PSScriptRoot\.. alone already broke
# the moment Private\ itself moved to code\Private\ (confirmed: it still
# failed loudly - "expected function(s) not found under .../Private" -
# just pointing at a Private\ that no longer exists at the repo root).
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "../..")
$privateRoot = Join-Path $repoRoot "code\Private"
$privateFiles = Get-ChildItem -Path $privateRoot -Filter "*.ps1" -Recurse

# Deliberately narrow list - only genuinely pure, side-effect-free
# functions. Adding a name here is a claim that function has NO WinForms
# and NO live Graph dependency; verify that before adding one.
$testableFunctionNames = @(
    "Test-AppIsUncommon",
    "Get-SafeFileNameForApp",
    "Get-DependencyOrderedApps",
    "Get-CatalogMetadataSimpleFields",
    "Get-CatalogMetadataFieldDiffs",
    "ConvertTo-DetectionRuleJson",
    "ConvertTo-JsonStringLiteral",
    "Merge-CatalogMetadata",
    "Get-CreateAppTemplates",
    "Get-DefaultAppMetadata",
    "Get-FriendlyIntuneAppType",
    "Get-ParsedMinOsRelease",
    "Get-FriendlyMinOsRelease",
    "Test-AppHasCustomConfig",
    "ConvertTo-AppRecord",
    "Get-GroupFieldDiffs",
    # Lives in GuiHelpers.ps1, not Private\Catalog\ - the scan below isn't
    # hardcoded to Catalog files, so adding the name here is enough. Pure
    # string normalization, no WinForms/Graph dependency despite living
    # next to code that has both. ConvertTo-DetectionRuleJson (and, via
    # it, Get-CatalogMetadataFieldDiffs) calls this directly - omitting it
    # here left this whole suite unable to even LOAD ("the term
    # 'ConvertTo-CanonicalLineEndings' is not recognized") the moment
    # either of those ran, silently as a load-time error rather than a
    # test failure, so it was never actually exercising the fix it was
    # meant to be able to cover.
    "ConvertTo-CanonicalLineEndings",
    # Graph request log formatting (GraphLog.ps1) - pure string work
    "Get-GraphRequestPath",
    "Get-GraphRequestId",
    "ConvertTo-GraphLogLine",
    "ConvertTo-GraphReadSummary",
    "Format-LogDuration",
    "ConvertTo-RunLogLine",
    # Install status report parsing (GraphReports.ps1) - pure table/string work
    "ConvertFrom-GraphReportTable",
    "Get-ReportColumnValue",
    "Format-InstallStatusError",
    "Format-InstallStatusTime",
    "ConvertTo-InstallStatusRow",
    "Format-InstallStatusSummary",
    "Test-InstallStatusRowMatchesFilter",
    "Get-AppInstallStatusRows"
)

$funcAsts = New-Object System.Collections.Generic.List[object]
foreach ($file in $privateFiles) {
    $parseErrors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        Write-Host "FAIL: $($file.FullName) has $($parseErrors.Count) syntax error(s) - fix before running tests." -ForegroundColor Red
        foreach ($e in $parseErrors) { Write-Host "  Line $($e.Extent.StartLineNumber): $($e.Message)" -ForegroundColor Red }
        exit 1
    }
    $matches = $ast.FindAll({
        param($node)
        # Every top-level Private\ function is declared as "function
        # Global:Name" (see IntuneDeployment.ps1's header comment for why),
        # so the AST's own Name includes that "Global:" scope prefix - strip
        # it before comparing against the plain names below.
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $testableFunctionNames -contains ($node.Name -replace '^[A-Za-z]+:', '')
    }, $true)
    foreach ($m in $matches) { $funcAsts.Add($m) }
}

$foundNames = @($funcAsts | ForEach-Object { $_.Name -replace '^[A-Za-z]+:', '' })
$missingNames = @($testableFunctionNames | Where-Object { $foundNames -notcontains $_ })
if ($missingNames.Count -gt 0) {
    Write-Host "FAIL: expected function(s) not found under $privateRoot`: $($missingNames -join ', ')" -ForegroundColor Red
    exit 1
}
$dupeNames = @($foundNames | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
if ($dupeNames.Count -gt 0) {
    Write-Host "FAIL: function(s) defined more than once under $privateRoot`: $($dupeNames -join ', ')" -ForegroundColor Red
    exit 1
}

foreach ($fn in $funcAsts) {
    . ([scriptblock]::Create($fn.Extent.Text))
}

# $Global:App.Apps is what Get-DefaultAppMetadata reads (its "default to
# depending on Winget AutoUpdate if it exists" check) - stubbed here since
# the real script's own startup (which populates this from the app-data
# folder) never runs in this harness.
$Global:App = @{}
$Global:App.Apps = New-Object System.Collections.Generic.List[object]

# $Global:App.DefaultAppSettings is what Get-DefaultAppMetadata now reads for
# every value it used to hardcode directly - stubbed with the exact same
# factory values the real script itself initializes this to, so this
# harness exercises the same defaults a real, never-customized install
# would compute. If the real script's own factory values above ever
# change, this needs updating to match, same as every other value this
# test suite mirrors from the real script.
$Global:App.DefaultAppSettings = [pscustomobject]@{
    Architecture             = "x64"
    InstallContext           = "System"
    MinOSKey                 = "W10_22H2"
    MinDiskSpaceMB           = 0
    MinMemoryMB              = 0
    MinProcessors            = 0
    MinCpuSpeedMHz           = 0
    InstallTimeMinutes       = 60
    DeviceRestartBehavior    = "basedOnReturnCode"
    AllowAvailableUninstall  = $false
    ReturnCodes              = @(
        [pscustomobject]@{ returnCode = 0; type = "success" }
        [pscustomobject]@{ returnCode = 1707; type = "success" }
        [pscustomobject]@{ returnCode = 3010; type = "softReboot" }
        [pscustomobject]@{ returnCode = 1641; type = "hardReboot" }
        [pscustomobject]@{ returnCode = 1618; type = "retry" }
    )
    DefaultDependencyAppNames = @("Winget AutoUpdate")
}

# =================================================================
# Test-AppIsUncommon
# =================================================================
Assert-True (Test-AppIsUncommon -App ([pscustomobject]@{ wingetId = "" })) `
    "Test-AppIsUncommon: blank Winget ID is uncommon"
Assert-True (Test-AppIsUncommon -App ([pscustomobject]@{ wingetId = $null })) `
    "Test-AppIsUncommon: null Winget ID is uncommon"
Assert-True (-not (Test-AppIsUncommon -App ([pscustomobject]@{ wingetId = "7zip.7zip" }))) `
    "Test-AppIsUncommon: real Winget ID is NOT uncommon"

# =================================================================
# Get-SafeFileNameForApp
# =================================================================
Assert-Equal "7-Zip" (Get-SafeFileNameForApp -Name "7-Zip") `
    "Get-SafeFileNameForApp: simple name passes through"
Assert-Equal "MyAppTest" (Get-SafeFileNameForApp -Name "My/App:Test") `
    "Get-SafeFileNameForApp: unsafe path characters removed outright (not dash-replaced - only whitespace becomes a dash)"
Assert-Equal "My-App" (Get-SafeFileNameForApp -Name "  My   App  ") `
    "Get-SafeFileNameForApp: whitespace collapsed and trimmed to a single dash"
Assert-Equal "App" (Get-SafeFileNameForApp -Name "") `
    "Get-SafeFileNameForApp: blank name falls back to 'App'"

# =================================================================
# Get-DependencyOrderedApps
# =================================================================
$chain = @(
    [pscustomobject]@{ appName = "C"; metadata = [pscustomobject]@{ dependencies = @("B") } }
    [pscustomobject]@{ appName = "B"; metadata = [pscustomobject]@{ dependencies = @("A") } }
    [pscustomobject]@{ appName = "A"; metadata = [pscustomobject]@{ dependencies = @() } }
)
$chainResult = Get-DependencyOrderedApps -Apps $chain
Assert-Equal "A,B,C" (($chainResult.Ordered | ForEach-Object { $_.appName }) -join ",") `
    "Get-DependencyOrderedApps: a chain (C->B->A) orders as A,B,C"
Assert-Equal 0 $chainResult.CircularNames.Count `
    "Get-DependencyOrderedApps: a chain has no circular names"

$diamond = @(
    [pscustomobject]@{ appName = "D"; metadata = [pscustomobject]@{ dependencies = @("B","C") } }
    [pscustomobject]@{ appName = "B"; metadata = [pscustomobject]@{ dependencies = @("A") } }
    [pscustomobject]@{ appName = "C"; metadata = [pscustomobject]@{ dependencies = @("A") } }
    [pscustomobject]@{ appName = "A"; metadata = [pscustomobject]@{ dependencies = @() } }
)
$diamondResult = Get-DependencyOrderedApps -Apps $diamond
$diamondOrder = @($diamondResult.Ordered | ForEach-Object { $_.appName })
Assert-Equal 0 $diamondResult.CircularNames.Count "Get-DependencyOrderedApps: a diamond has no circular names"
Assert-True ($diamondOrder.IndexOf("A") -lt $diamondOrder.IndexOf("B")) "Get-DependencyOrderedApps: diamond - A before B"
Assert-True ($diamondOrder.IndexOf("A") -lt $diamondOrder.IndexOf("C")) "Get-DependencyOrderedApps: diamond - A before C"
Assert-True ($diamondOrder.IndexOf("B") -lt $diamondOrder.IndexOf("D")) "Get-DependencyOrderedApps: diamond - B before D"
Assert-True ($diamondOrder.IndexOf("C") -lt $diamondOrder.IndexOf("D")) "Get-DependencyOrderedApps: diamond - C before D"

$cycle = @(
    [pscustomobject]@{ appName = "X"; metadata = [pscustomobject]@{ dependencies = @("Y") } }
    [pscustomobject]@{ appName = "Y"; metadata = [pscustomobject]@{ dependencies = @("X") } }
)
$cycleResult = Get-DependencyOrderedApps -Apps $cycle
Assert-Equal 2 $cycleResult.CircularNames.Count "Get-DependencyOrderedApps: a genuine cycle (X<->Y) is flagged circular"
Assert-Equal 2 $cycleResult.Ordered.Count "Get-DependencyOrderedApps: a genuine cycle still returns both apps, not neither"

$independent = @(
    [pscustomobject]@{ appName = "P"; metadata = [pscustomobject]@{ dependencies = @() } }
    [pscustomobject]@{ appName = "Q"; metadata = [pscustomobject]@{ dependencies = @() } }
)
$independentResult = Get-DependencyOrderedApps -Apps $independent
Assert-Equal 0 $independentResult.CircularNames.Count "Get-DependencyOrderedApps: independent apps have no circular names"
Assert-Equal 2 $independentResult.Ordered.Count "Get-DependencyOrderedApps: independent apps both come back"

$outsideDep = @(
    [pscustomobject]@{ appName = "R"; metadata = [pscustomobject]@{ dependencies = @("NotInThisBatch") } }
)
$outsideResult = Get-DependencyOrderedApps -Apps $outsideDep
Assert-Equal 1 $outsideResult.Ordered.Count "Get-DependencyOrderedApps: a dependency outside the batch doesn't block ordering"
Assert-Equal 0 $outsideResult.CircularNames.Count "Get-DependencyOrderedApps: a dependency outside the batch isn't a false circular flag"

# =================================================================
# Get-CatalogMetadataFieldDiffs / Merge-CatalogMetadata
# =================================================================
$localMeta = [pscustomobject]@{
    description = "Local desc"; publisher = "Contoso"; owner = ""; developer = ""
    informationUrl = ""; privacyUrl = ""; notes = ""
    installCommand = "install.ps1"; uninstallCommand = "uninstall.ps1"
    architecture = "x64"
    minDiskSpaceMB = 0; minMemoryMB = 0; minProcessors = 0; minCpuSpeedMHz = 0
    installTimeMinutes = 60; deviceRestartBehavior = "basedOnReturnCode"
    allowAvailableUninstall = $false
    detectionRule = [pscustomobject]@{ Type = "Script"; Script_Content = "local script" }
    returnCodes = @([pscustomobject]@{ returnCode = 0; type = "success" })
}
$remoteMetaSame = $localMeta | Select-Object *
$diffsNone = Get-CatalogMetadataFieldDiffs -Local $localMeta -Remote $remoteMetaSame
Assert-Equal 0 $diffsNone.Count "Get-CatalogMetadataFieldDiffs: identical local/remote produce zero diffs"

$remoteMetaDiff = $localMeta | Select-Object *
$remoteMetaDiff.description = "Remote desc"
$remoteMetaDiff.architecture = "x64,arm64"
$diffsSome = Get-CatalogMetadataFieldDiffs -Local $localMeta -Remote $remoteMetaDiff
Assert-Equal 2 $diffsSome.Count "Get-CatalogMetadataFieldDiffs: two changed simple fields produce two diffs"
Assert-True (@($diffsSome | ForEach-Object { $_.Field }) -contains "Description") "Get-CatalogMetadataFieldDiffs: Description flagged"
Assert-True (@($diffsSome | ForEach-Object { $_.Field }) -contains "Architecture") "Get-CatalogMetadataFieldDiffs: Architecture flagged"

$remoteMetaDetDiff = $localMeta | Select-Object *
$remoteMetaDetDiff.detectionRule = [pscustomobject]@{ Type = "Script"; Script_Content = "different script" }
$diffsDet = Get-CatalogMetadataFieldDiffs -Local $localMeta -Remote $remoteMetaDetDiff
Assert-True (@($diffsDet | ForEach-Object { $_.Field }) -contains "Detection rule") "Get-CatalogMetadataFieldDiffs: Detection rule content change is flagged"

$diffsNoLocal = Get-CatalogMetadataFieldDiffs -Local $null -Remote $remoteMetaDiff
Assert-Equal 0 $diffsNoLocal.Count "Get-CatalogMetadataFieldDiffs: no local metadata at all means zero diffs (nothing to compare), not 'everything differs'"

# Win32Only fields (install time/restart behavior/allow-uninstall/detection
# rule/return codes) must never be flagged for a non-Win32 app - Intune
# always reports them blank/null for e.g. a Microsoft Store app, so
# comparing them against this tool's Win32-shaped local defaults would be a
# permanent false positive, not a real difference.
$remoteMetaStoreApp = $localMeta | Select-Object *
$remoteMetaStoreApp.installTimeMinutes = $null
$remoteMetaStoreApp.deviceRestartBehavior = ""
$remoteMetaStoreApp.allowAvailableUninstall = $false
$remoteMetaStoreApp.detectionRule = $null
$remoteMetaStoreApp.returnCodes = @()
$diffsStoreApp = Get-CatalogMetadataFieldDiffs -Local $localMeta -Remote $remoteMetaStoreApp -OdataType "#microsoft.graph.winGetApp"
Assert-Equal 0 $diffsStoreApp.Count "Get-CatalogMetadataFieldDiffs: Win32Only fields aren't flagged for a non-Win32 OdataType"

# Omitting -OdataType (every pre-existing caller) still assumes Win32 - the
# same fields flag as real diffs when the type is unknown/blank.
$diffsAssumedWin32 = Get-CatalogMetadataFieldDiffs -Local $localMeta -Remote $remoteMetaStoreApp
Assert-True ($diffsAssumedWin32.Count -gt 0) "Get-CatalogMetadataFieldDiffs: omitting -OdataType still compares Win32Only fields (backward compatible default)"

# A Win32-like OdataType other than plain win32LobApp (e.g. the legacy MSI
# wrapper type) must still compare Win32Only fields, not just an exact
# "win32LobApp" match.
$diffsWindowsMobileMsi = Get-CatalogMetadataFieldDiffs -Local $localMeta -Remote $remoteMetaStoreApp -OdataType "#microsoft.graph.windowsMobileMSI"
Assert-True ($diffsWindowsMobileMsi.Count -gt 0) "Get-CatalogMetadataFieldDiffs: windowsMobileMSI is treated as Win32-like, not skipped"

# Merge: no fields kept local -> pure Remote copy
$mergedAllRemote = Merge-CatalogMetadata -Remote $remoteMetaDiff -Local $localMeta -KeepLocalFields @()
Assert-Equal $remoteMetaDiff.description $mergedAllRemote.description "Merge-CatalogMetadata: no keep-local fields -> description is Remote's"
Assert-Equal $remoteMetaDiff.architecture $mergedAllRemote.architecture "Merge-CatalogMetadata: no keep-local fields -> architecture is Remote's"

# Merge: keep Description local, everything else Remote
$mergedKeepDesc = Merge-CatalogMetadata -Remote $remoteMetaDiff -Local $localMeta -KeepLocalFields @("Description")
Assert-Equal $localMeta.description $mergedKeepDesc.description "Merge-CatalogMetadata: kept field (Description) comes from Local"
Assert-Equal $remoteMetaDiff.architecture $mergedKeepDesc.architecture "Merge-CatalogMetadata: non-kept field (Architecture) still comes from Remote"

# Merge: keep Detection rule local
$mergedKeepDet = Merge-CatalogMetadata -Remote $remoteMetaDetDiff -Local $localMeta -KeepLocalFields @("Detection rule")
Assert-Equal $localMeta.detectionRule.Script_Content $mergedKeepDet.detectionRule.Script_Content `
    "Merge-CatalogMetadata: kept 'Detection rule' pulls the composite object from Local, not just a simple field"

# =================================================================
# Get-CreateAppTemplates / Get-DefaultAppMetadata
# =================================================================
$wingetTemplates = Get-CreateAppTemplates -WingetId "7zip.7zip" -Uncommon $false
Assert-True (-not [string]::IsNullOrWhiteSpace($wingetTemplates.Detection)) `
    "Get-CreateAppTemplates: a winget app gets a real, non-blank default detection script"
Assert-True ($wingetTemplates.Install -like "*7zip.7zip*") `
    "Get-CreateAppTemplates: the winget ID is actually embedded in the install command"

$uncommonTemplates = Get-CreateAppTemplates -WingetId "" -Uncommon $true
Assert-Equal "" $uncommonTemplates.Detection `
    "Get-CreateAppTemplates: an uncommon app has no default detection - there's nothing to derive one from"

$wingetDefaults = Get-DefaultAppMetadata -AppName "Test Winget App" -WingetId "7zip.7zip" -Uncommon $false
Assert-True ($null -ne $wingetDefaults.detectionRule) `
    "Get-DefaultAppMetadata: a winget app's defaults include a usable detection rule"
Assert-Equal "x64" $wingetDefaults.architecture "Get-DefaultAppMetadata: default architecture is x64-only"
Assert-Equal "System" $wingetDefaults.installContext "Get-DefaultAppMetadata: default install context is System"
Assert-Equal "W10_22H2" $wingetDefaults.minOSKey "Get-DefaultAppMetadata: default Min OS is the newest Windows 10 release (not Windows 11)"
Assert-Equal "basedOnReturnCode" $wingetDefaults.deviceRestartBehavior "Get-DefaultAppMetadata: default restart behavior is basedOnReturnCode"
Assert-Equal 5 @($wingetDefaults.returnCodes).Count "Get-DefaultAppMetadata: the standard 5 return codes are included"
Assert-Equal "" $wingetDefaults.publisher "Get-DefaultAppMetadata: default publisher is blank (no hardcoded org name)"

$uncommonDefaults = Get-DefaultAppMetadata -AppName "Test Uncommon App" -WingetId "" -Uncommon $true
Assert-Null $uncommonDefaults.detectionRule `
    "Get-DefaultAppMetadata: an uncommon app with no Winget ID has NO usable default detection rule - this is the exact case Batch Deploy must skip, not silently deploy with broken detection"

# Winget AutoUpdate dependency default - present in $Global:App.Apps, app isn't itself Winget AutoUpdate
$Global:App.Apps.Clear()
$Global:App.Apps.Add([pscustomobject]@{ appName = "Winget AutoUpdate" })
$defaultsWithWau = Get-DefaultAppMetadata -AppName "Some Other App" -WingetId "some.app" -Uncommon $false
Assert-True (@($defaultsWithWau.dependencies) -contains "Winget AutoUpdate") `
    "Get-DefaultAppMetadata: defaults to depending on Winget AutoUpdate when it exists in the catalog"

# Winget AutoUpdate itself shouldn't depend on itself
$defaultsForWauItself = Get-DefaultAppMetadata -AppName "Winget AutoUpdate" -WingetId "some.app" -Uncommon $false
Assert-True (@($defaultsForWauItself.dependencies) -notcontains "Winget AutoUpdate") `
    "Get-DefaultAppMetadata: Winget AutoUpdate itself never defaults to depending on itself"

# Winget AutoUpdate absent from the catalog entirely
$Global:App.Apps.Clear()
$defaultsNoWau = Get-DefaultAppMetadata -AppName "Some Other App" -WingetId "some.app" -Uncommon $false
Assert-Equal 0 @($defaultsNoWau.dependencies).Count `
    "Get-DefaultAppMetadata: no dependency default when Winget AutoUpdate isn't in the catalog at all"

# -----------------------------------------------------------------
# Get-FriendlyIntuneAppType
# -----------------------------------------------------------------
Assert-Equal "Windows app (Win32)" (Get-FriendlyIntuneAppType -ODataType "#microsoft.graph.win32LobApp") `
    "Get-FriendlyIntuneAppType: win32LobApp maps to the Intune portal's own label"
Assert-Equal "Windows app (Win32)" (Get-FriendlyIntuneAppType -ODataType "microsoft.graph.win32CatalogApp") `
    "Get-FriendlyIntuneAppType: win32CatalogApp maps the same as win32LobApp (works without the leading #)"
Assert-Equal "Microsoft 365 Apps (Windows 10 and later)" (Get-FriendlyIntuneAppType -ODataType "#microsoft.graph.officeSuiteApp") `
    "Get-FriendlyIntuneAppType: officeSuiteApp maps to the Microsoft 365 Apps label"
Assert-Equal "Microsoft Store app (new)" (Get-FriendlyIntuneAppType -ODataType "#microsoft.graph.winGetApp") `
    "Get-FriendlyIntuneAppType: winGetApp maps to the new Microsoft Store app label"
Assert-Equal "" (Get-FriendlyIntuneAppType -ODataType "") `
    "Get-FriendlyIntuneAppType: blank input returns blank, not an error"
Assert-Equal "Some Unmapped Type" (Get-FriendlyIntuneAppType -ODataType "#microsoft.graph.someUnmappedType") `
    "Get-FriendlyIntuneAppType: an unrecognized type still gets a readable, space-separated fallback label"

# -----------------------------------------------------------------
# Get-FriendlyMinOsRelease / Get-ParsedMinOsRelease
# -----------------------------------------------------------------
# All three of these raw spellings have been observed live for the exact
# same minimumSupportedWindowsRelease property - the whole point of this
# function is recognizing all of them as the same underlying release.
Assert-Equal "Windows 11 21H2" (Get-FriendlyMinOsRelease -RawValue "W11_21H2") `
    "Get-FriendlyMinOsRelease: W11_21H2 (IntuneWin32App module convention)"
Assert-Equal "Windows 11 21H2" (Get-FriendlyMinOsRelease -RawValue "Windows11_21H2") `
    "Get-FriendlyMinOsRelease: Windows11_21H2 (Intune portal's own spelling)"
Assert-Equal "Windows 10 21H1" (Get-FriendlyMinOsRelease -RawValue "21H1") `
    "Get-FriendlyMinOsRelease: a bare release with no major-version marker defaults to Windows 10"
Assert-Equal "Windows 10 21H1" (Get-FriendlyMinOsRelease -RawValue "v10_21H1") `
    "Get-FriendlyMinOsRelease: legacy v10_ prefix"
Assert-Equal "Windows 10 20H2" (Get-FriendlyMinOsRelease -RawValue "v10_2H20") `
    "Get-FriendlyMinOsRelease: legacy property's own digit-swapped 20H2 spelling is un-swapped"
Assert-Equal "" (Get-FriendlyMinOsRelease -RawValue "") `
    "Get-FriendlyMinOsRelease: blank input returns blank, not an error"
$parsedForCompare1 = Get-ParsedMinOsRelease -RawValue "W11_21H2"
$parsedForCompare2 = Get-ParsedMinOsRelease -RawValue "Windows11_21H2"
Assert-Equal $true ($parsedForCompare1.Major -eq $parsedForCompare2.Major -and $parsedForCompare1.Release -eq $parsedForCompare2.Release) `
    "Get-ParsedMinOsRelease: two different raw spellings of the same release parse as equal"

# -----------------------------------------------------------------
# Test-AppHasCustomConfig
# -----------------------------------------------------------------
$Global:App.Apps.Clear()
$uncommonApp = [pscustomobject]@{ appName = "Some Custom App"; wingetId = ""; metadata = $null }
Assert-Equal $true (Test-AppHasCustomConfig -App $uncommonApp) `
    "Test-AppHasCustomConfig: an uncommon app (no Winget ID) is always Yes - no shared default to compare against"

$wingetAppNoMetadata = [pscustomobject]@{ appName = "Some Winget App"; wingetId = "some.app"; metadata = $null }
Assert-Equal $false (Test-AppHasCustomConfig -App $wingetAppNoMetadata) `
    "Test-AppHasCustomConfig: a Winget app with no saved metadata is No - nothing to have customized yet"

$defaultsForCompare = Get-DefaultAppMetadata -AppName "Some Winget App" -WingetId "some.app" -Uncommon $false
$wingetAppDefaultMetadata = [pscustomobject]@{ appName = "Some Winget App"; wingetId = "some.app"; metadata = $defaultsForCompare }
Assert-Equal $false (Test-AppHasCustomConfig -App $wingetAppDefaultMetadata) `
    "Test-AppHasCustomConfig: a Winget app whose saved metadata exactly matches the computed defaults is No"

$customizedMetadata = $defaultsForCompare.PSObject.Copy()
$customizedMetadata.installCommand = "custom-install.exe /silent"
$wingetAppCustomMetadata = [pscustomobject]@{ appName = "Some Winget App"; wingetId = "some.app"; metadata = $customizedMetadata }
Assert-Equal $true (Test-AppHasCustomConfig -App $wingetAppCustomMetadata) `
    "Test-AppHasCustomConfig: a Winget app whose saved install command differs from the default is Yes"

# -----------------------------------------------------------------
# ConvertTo-AppRecord
# -----------------------------------------------------------------
# A missing/null requiredFor/availableFor/uninstallFor in the source JSON
# used to load as @($null) - a ONE-element array containing $null, not an
# empty array (a PowerShell @() gotcha: @($null) always has Count 1) -
# which then miscounted an app with genuinely zero groups as "has a
# group" everywhere @($_.requiredFor).Count is checked, and crashed
# Show-RemoveGroupFromAppsDialog outright (CheckedListBox.Items.Add
# doesn't accept $null). This is the regression test for that fix.
$rawNoGroupFields = [pscustomobject]@{ appId = "id-1"; appName = "No Group Fields" }
$recordNoGroupFields = ConvertTo-AppRecord -Raw $rawNoGroupFields
Assert-Equal 0 @($recordNoGroupFields.requiredFor).Count `
    "ConvertTo-AppRecord: a source object with NO requiredFor property at all loads as an empty array, not [`$null]"
Assert-Equal 0 @($recordNoGroupFields.availableFor).Count `
    "ConvertTo-AppRecord: a source object with NO availableFor property at all loads as an empty array, not [`$null]"
Assert-Equal 0 @($recordNoGroupFields.uninstallFor).Count `
    "ConvertTo-AppRecord: a source object with NO uninstallFor property at all loads as an empty array, not [`$null]"

$rawExplicitNullGroups = [pscustomobject]@{ appId = "id-2"; appName = "Null Group Fields"; requiredFor = $null; availableFor = $null; uninstallFor = $null }
$recordExplicitNull = ConvertTo-AppRecord -Raw $rawExplicitNullGroups
Assert-Equal 0 @($recordExplicitNull.requiredFor).Count `
    "ConvertTo-AppRecord: an EXPLICIT `$null requiredFor (valid JSON 'null') also loads as an empty array"

$rawRealGroups = [pscustomobject]@{
    appId = "id-3"; appName = "Real Groups"
    requiredFor = @("GroupA", "GroupB"); availableFor = @("GroupC"); uninstallFor = @()
}
$recordRealGroups = ConvertTo-AppRecord -Raw $rawRealGroups
Assert-Equal "GroupA,GroupB" (($recordRealGroups.requiredFor) -join ",") `
    "ConvertTo-AppRecord: real requiredFor values pass through unchanged, in order"
Assert-Equal "GroupC" (($recordRealGroups.availableFor) -join ",") `
    "ConvertTo-AppRecord: real availableFor values pass through unchanged"
Assert-Equal 0 @($recordRealGroups.uninstallFor).Count `
    "ConvertTo-AppRecord: a genuinely empty (but present) uninstallFor array stays empty"

# -----------------------------------------------------------------
# Get-GroupFieldDiffs
# -----------------------------------------------------------------
$localAppNoDrift = [pscustomobject]@{ requiredFor = @("Deploy Dev"); availableFor = @("Company Portal"); uninstallFor = @() }
$remoteResultNoDrift = [pscustomobject]@{ RequiredGroupNames = @("Deploy Dev"); AvailableGroupNames = @("Company Portal"); UninstallGroupNames = @() }
Assert-Equal 0 @(Get-GroupFieldDiffs -LocalApp $localAppNoDrift -RemoteResult $remoteResultNoDrift).Count `
    "Get-GroupFieldDiffs: identical local/remote group sets produce zero diffs"

$localAppMultiReq = [pscustomobject]@{ requiredFor = @("B", "A"); availableFor = @(); uninstallFor = @() }
$remoteResultMultiReq = [pscustomobject]@{ RequiredGroupNames = @("A", "B"); AvailableGroupNames = @(); UninstallGroupNames = @() }
Assert-Equal 0 @(Get-GroupFieldDiffs -LocalApp $localAppMultiReq -RemoteResult $remoteResultMultiReq).Count `
    "Get-GroupFieldDiffs: same membership in a different order is NOT a diff (order-insensitive)"

$localAppRenamed = [pscustomobject]@{ requiredFor = @("Old Group Name"); availableFor = @(); uninstallFor = @() }
$remoteResultRenamed = [pscustomobject]@{ RequiredGroupNames = @("New Group Name"); AvailableGroupNames = @(); UninstallGroupNames = @() }
$diffsRenamed = @(Get-GroupFieldDiffs -LocalApp $localAppRenamed -RemoteResult $remoteResultRenamed)
Assert-Equal 1 $diffsRenamed.Count "Get-GroupFieldDiffs: a renamed group in one bucket produces exactly one diff row"
Assert-Equal "Required for" $diffsRenamed[0].Field "Get-GroupFieldDiffs: the diff is reported under the correct bucket label"
Assert-Equal "Old Group Name" $diffsRenamed[0].Local "Get-GroupFieldDiffs: Local shows the stale catalog name"
Assert-Equal "New Group Name" $diffsRenamed[0].Remote "Get-GroupFieldDiffs: Remote shows Intune's current live name"

$diffsNullInputs = @(Get-GroupFieldDiffs -LocalApp $null -RemoteResult $remoteResultNoDrift)
Assert-Equal 0 $diffsNullInputs.Count "Get-GroupFieldDiffs: a `$null LocalApp produces zero diffs rather than throwing"

# -----------------------------------------------------------------
# ConvertTo-JsonStringLiteral - only ever exercised indirectly before
# (through ConvertTo-DetectionRuleJson), so a broken edge case here could
# have silently corrupted the catalog's own JSON files with no test
# actually pinning down the escaping rules directly.
# -----------------------------------------------------------------
Assert-Equal '""' (ConvertTo-JsonStringLiteral "") `
    "ConvertTo-JsonStringLiteral: an empty string becomes an empty JSON string literal"
Assert-Equal '""' (ConvertTo-JsonStringLiteral $null) `
    "ConvertTo-JsonStringLiteral: `$null is treated the same as an empty string, not an error"
Assert-Equal '"plain text"' (ConvertTo-JsonStringLiteral "plain text") `
    "ConvertTo-JsonStringLiteral: plain text with no special characters passes through unescaped"
Assert-Equal '"say \"hi\""' (ConvertTo-JsonStringLiteral 'say "hi"') `
    "ConvertTo-JsonStringLiteral: embedded double quotes are escaped"
Assert-Equal '"C:\\Program Files\\App"' (ConvertTo-JsonStringLiteral 'C:\Program Files\App') `
    "ConvertTo-JsonStringLiteral: backslashes (e.g. a Windows path) are escaped"
Assert-Equal '"a\\\"b"' (ConvertTo-JsonStringLiteral 'a\"b') `
    "ConvertTo-JsonStringLiteral: a backslash immediately followed by a quote escapes to \\\" - the backslash isn't itself swallowed into escaping the quote (order-of-replacement regression)"
Assert-Equal '"a\tb"' (ConvertTo-JsonStringLiteral "a`tb") `
    "ConvertTo-JsonStringLiteral: a literal tab character becomes the two-character \t escape"
Assert-Equal '"a\rb"' (ConvertTo-JsonStringLiteral "a`rb") `
    "ConvertTo-JsonStringLiteral: a literal CR character becomes the two-character \r escape"
Assert-Equal '"a\nb"' (ConvertTo-JsonStringLiteral "a`nb") `
    "ConvertTo-JsonStringLiteral: a literal LF character becomes the two-character \n escape"

# Round-trip check, not just a literal string comparison - confirms the
# escaped output is actually valid JSON that decodes back to the exact
# original value, for a value that exercises every escape rule at once.
$roundTripInput = "line1`r`nline2`ttabbed and a `"quote`" and a \backslash\"
$roundTripJson = ConvertTo-JsonStringLiteral $roundTripInput
$roundTripDecoded = $roundTripJson | ConvertFrom-Json
Assert-Equal $roundTripInput $roundTripDecoded `
    "ConvertTo-JsonStringLiteral: output round-trips through ConvertFrom-Json back to the exact original value"

# -----------------------------------------------------------------
# ConvertTo-CanonicalLineEndings
# -----------------------------------------------------------------
Assert-Equal "line1`nline2" (ConvertTo-CanonicalLineEndings "line1`r`nline2") `
    "ConvertTo-CanonicalLineEndings: CRLF is normalized to bare LF"
Assert-Equal "already`nlf" (ConvertTo-CanonicalLineEndings "already`nlf") `
    "ConvertTo-CanonicalLineEndings: bare LF passes through unchanged (idempotent)"
Assert-Equal "" (ConvertTo-CanonicalLineEndings "") `
    "ConvertTo-CanonicalLineEndings: blank input returns blank, not an error"

# -----------------------------------------------------------------
# ConvertTo-DetectionRuleJson - regression coverage for the WinMerge
# false-positive fix (live: Intune's own copy of a script came back with
# a trailing `r`n where the local catalog had a trailing `n, incorrectly
# flagging "Detection rule" as 1 field differing when the script was
# otherwise byte-identical).
# -----------------------------------------------------------------
$detLf = [pscustomobject]@{ Type = "Script"; Script_Content = "if (Test-Path 'x') { exit 0 }; exit 1`n" }
$detCrlf = [pscustomobject]@{ Type = "Script"; Script_Content = "if (Test-Path 'x') { exit 0 }; exit 1`r`n" }
$detNoTrailing = [pscustomobject]@{ Type = "Script"; Script_Content = "if (Test-Path 'x') { exit 0 }; exit 1" }
$detExtraBlankLines = [pscustomobject]@{ Type = "Script"; Script_Content = "if (Test-Path 'x') { exit 0 }; exit 1`r`n`r`n  " }
$jsonLf = ConvertTo-DetectionRuleJson -DetectionRule $detLf -IndentLevel 0
$jsonCrlf = ConvertTo-DetectionRuleJson -DetectionRule $detCrlf -IndentLevel 0
$jsonNoTrailing = ConvertTo-DetectionRuleJson -DetectionRule $detNoTrailing -IndentLevel 0
$jsonExtraBlankLines = ConvertTo-DetectionRuleJson -DetectionRule $detExtraBlankLines -IndentLevel 0
Assert-Equal $jsonLf $jsonCrlf `
    "ConvertTo-DetectionRuleJson: a trailing LF vs. a trailing CRLF on an otherwise-identical script produce identical JSON (WinMerge regression)"
Assert-Equal $jsonLf $jsonNoTrailing `
    "ConvertTo-DetectionRuleJson: a trailing newline vs. no trailing newline at all also produce identical JSON"
Assert-Equal $jsonLf $jsonExtraBlankLines `
    "ConvertTo-DetectionRuleJson: extra trailing blank lines/whitespace also normalize to the same JSON"

$detRealChange = [pscustomobject]@{ Type = "Script"; Script_Content = "if (Test-Path 'x') { exit 0 }; exit 1`n; exit 2" }
$jsonRealChange = ConvertTo-DetectionRuleJson -DetectionRule $detRealChange -IndentLevel 0
Assert-True ($jsonLf -ne $jsonRealChange) `
    "ConvertTo-DetectionRuleJson: a genuine content change (not just trailing whitespace) still produces different JSON"

# -----------------------------------------------------------------
# Get-CatalogMetadataFieldDiffs - same normalization extended to Notes/
# Install command/Uninstall command (also Multiline textboxes, just as
# able to pick up a CRLF-vs-LF-only difference against Intune's own
# copy as the detection script was).
# -----------------------------------------------------------------
$localMetaMultiline = $localMeta | Select-Object *
$localMetaMultiline.installCommand = "line1`nline2`n"
$localMetaMultiline.notes = "some notes`n"
$remoteMetaMultilineSameContent = $localMetaMultiline | Select-Object *
$remoteMetaMultilineSameContent.installCommand = "line1`r`nline2`r`n"
$remoteMetaMultilineSameContent.notes = "some notes`r`n"
$diffsMultilineSame = Get-CatalogMetadataFieldDiffs -Local $localMetaMultiline -Remote $remoteMetaMultilineSameContent
Assert-Equal 0 $diffsMultilineSame.Count `
    "Get-CatalogMetadataFieldDiffs: a CRLF-vs-LF-only difference in Install command/Notes is not flagged as a diff"

$remoteMetaMultilineRealChange = $localMetaMultiline | Select-Object *
$remoteMetaMultilineRealChange.installCommand = "line1`r`nline2-changed`r`n"
$diffsMultilineRealChange = Get-CatalogMetadataFieldDiffs -Local $localMetaMultiline -Remote $remoteMetaMultilineRealChange
Assert-True (@($diffsMultilineRealChange | ForEach-Object { $_.Field }) -contains "Install command") `
    "Get-CatalogMetadataFieldDiffs: a genuine content change in Install command (not just line endings) is still flagged"

# =================================================================
# Graph request log lines (GraphLog.ps1)
# =================================================================
Assert-Equal "/beta/deviceAppManagement/mobileApps/abc" (Get-GraphRequestPath "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/abc") `
    "Get-GraphRequestPath: the graph.microsoft.com host is dropped, the version and path kept"
$longPath = Get-GraphRequestPath ("https://graph.microsoft.com/v1.0/groups?`$filter=" + ("x" * 300))
Assert-True ($longPath.Length -eq 180 -and $longPath.EndsWith("...")) `
    "Get-GraphRequestPath: a very long address is cut to 180 characters, marked with ..."

Assert-Equal "11111111-2222-3333-4444-555555555555" (Get-GraphRequestId '{"error":{"code":"NotFound","innerError":{"date":"2026-09-17T10:00:00","request-id":"11111111-2222-3333-4444-555555555555"}}}') `
    "Get-GraphRequestId: finds request-id in a Graph error body"
Assert-Equal "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" (Get-GraphRequestId "Status: 404 (NotFound) client-request-id: aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee") `
    "Get-GraphRequestId: finds client-request-id in plain error text"
Assert-Null (Get-GraphRequestId "Response status code does not indicate success: Forbidden") `
    "Get-GraphRequestId: nothing when there's no id"

Assert-Equal "[GRAPH] PATCH /beta/deviceAppManagement/mobileApps/abc -> OK (310 ms)" (ConvertTo-GraphLogLine -Method "patch" -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/abc" -Milliseconds 310) `
    "ConvertTo-GraphLogLine: a successful request - upper-case method, short path, duration"
$failedLine = ConvertTo-GraphLogLine -Method "DELETE" -Uri "https://graph.microsoft.com/beta/x" -Milliseconds 40 `
    -ErrorText "NotFound (Not Found)`nat line 12" -Detail '{"error":{"innerError":{"request-id":"11111111-2222-3333-4444-555555555555"}}}'
Assert-Equal "[GRAPH] DELETE /beta/x -> FAILED (40 ms): NotFound (Not Found) (request-id 11111111-2222-3333-4444-555555555555)" $failedLine `
    "ConvertTo-GraphLogLine: a failed request - first line of the error plus Graph's request-id"
Assert-True ((ConvertTo-GraphLogLine -Method GET -Uri "https://graph.microsoft.com/v1.0/me" -Milliseconds 1 -ErrorText ("e" * 500)).Length -lt 300) `
    "ConvertTo-GraphLogLine: a huge error message is shortened"

Assert-Null (ConvertTo-GraphReadSummary -Count 0 -Milliseconds 0) `
    "ConvertTo-GraphReadSummary: no line when there were no reads"
Assert-Equal "[GRAPH] 3 read request(s) (450 ms)" (ConvertTo-GraphReadSummary -Count 3 -Milliseconds 450) `
    "ConvertTo-GraphReadSummary: under a second shows milliseconds"
Assert-Equal "[GRAPH] Intune app lookup: 12 read request(s) (1.4 s)" (ConvertTo-GraphReadSummary -Count 12 -Milliseconds 1420 -Operation "Intune app lookup") `
    "ConvertTo-GraphReadSummary: a second or more shows seconds with a dot decimal, named by operation"

Assert-Equal "[RUN] winget search `"7zip`" -> 12 result(s) (2.3 s)" (ConvertTo-RunLogLine -Command 'winget search "7zip"' -Milliseconds 2310 -Result "12 result(s)") `
    "ConvertTo-RunLogLine: a finished command with its result"
Assert-Equal "[RUN] winget search `"x`" -> FAILED (30 s): winget search timed out after 30 seconds." (ConvertTo-RunLogLine -Command 'winget search "x"' -Milliseconds 30000 -ErrorText "winget search timed out after 30 seconds.`nmore") `
    "ConvertTo-RunLogLine: a failed command with the first line of its error"
Assert-Equal "[RUN] tool.exe -> OK (5 ms)" (ConvertTo-RunLogLine -Command "tool.exe" -Milliseconds 5) `
    "ConvertTo-RunLogLine: OK by default"# -----------------------------------------------------------------
# Install status report (GraphReports.ps1)
# -----------------------------------------------------------------
$sampleReport = @{
    Schema = @(@{ Column = "DeviceName" }, @{ Column = "UserPrincipalName" }, @{ Column = "AppInstallState_loc" }, @{ Column = "ErrorCode" })
    Values = @(
        @("PC-01", "ada@contoso.com", "Installed", 0),
        @("PC-02", "bob@contoso.com", "Failed", -2016345060)
    )
}
$reportRows = @(ConvertFrom-GraphReportTable $sampleReport)
Assert-Equal 2 $reportRows.Count "ConvertFrom-GraphReportTable: one row per Values entry"
Assert-Equal "PC-02" $reportRows[1]["DeviceName"] "ConvertFrom-GraphReportTable: cells are keyed by their column name"
Assert-Equal 0 (@(ConvertFrom-GraphReportTable $null)).Count "ConvertFrom-GraphReportTable: no report means no rows"
$shortRow = @(ConvertFrom-GraphReportTable @{ Schema = @(@{ Column = "A" }, @{ Column = "B" }); Values = @(, @("only-a")) })
Assert-Equal "only-a" $shortRow[0]["A"] "ConvertFrom-GraphReportTable: a row shorter than the schema keeps the cells it has"
Assert-Equal "" "$($shortRow[0]['B'])" "ConvertFrom-GraphReportTable: the missing cells of a short row are empty"

Assert-Equal "ada@contoso.com" (Get-ReportColumnValue $reportRows[0] @('UserPrincipalName', 'UserName')) `
    "Get-ReportColumnValue: takes the first column name that exists"
Assert-Equal "" (Get-ReportColumnValue $reportRows[0] @('NoSuchColumn')) `
    "Get-ReportColumnValue: a missing column is empty, not an error"

Assert-Equal "" (Format-InstallStatusError 0) "Format-InstallStatusError: 0 means no error"
Assert-Equal "" (Format-InstallStatusError "") "Format-InstallStatusError: blank means no error"
Assert-Equal "0x87D10324 (-2016345308)" (Format-InstallStatusError -2016345308) `
    "Format-InstallStatusError: a negative code shows the searchable hex form too"

$installed = ConvertTo-InstallStatusRow $reportRows[0]
Assert-Equal "PC-01" $installed.DeviceName "ConvertTo-InstallStatusRow: device name"
Assert-Equal "Installed" $installed.State "ConvertTo-InstallStatusRow: prefers the report's own state text"
Assert-Equal "" $installed.ErrorCode "ConvertTo-InstallStatusRow: no error code for a successful install"
$numericState = ConvertTo-InstallStatusRow ([ordered]@{ DeviceName = "PC-03"; AppInstallState = 3 })
Assert-Equal "State 3" $numericState.State `
    "ConvertTo-InstallStatusRow: a state with no text column is shown as its number, not guessed"

Assert-Equal "2026-09-17 08:14" (Format-InstallStatusTime "2026-09-17 08:14:32") `
    "Format-InstallStatusTime: a timestamp without a zone keeps its time, without seconds"
Assert-Equal ([datetime]::Parse("2026-09-17T08:14:32Z").ToLocalTime().ToString("yyyy-MM-dd HH:mm")) (Format-InstallStatusTime "2026-09-17T08:14:32.7654321Z") `
    "Format-InstallStatusTime: a UTC timestamp from Graph is shown in this machine's time zone"
Assert-Equal "" (Format-InstallStatusTime "") "Format-InstallStatusTime: nothing stays nothing"
Assert-Equal "not a date" (Format-InstallStatusTime "not a date") "Format-InstallStatusTime: anything unparseable is left as it came"

Assert-Equal "No install status reported for this app yet." (Format-InstallStatusSummary @()) `
    "Format-InstallStatusSummary: nothing reported yet"
Assert-Equal "2 devices: 1 Failed, 1 Installed" (Format-InstallStatusSummary @($installed, (ConvertTo-InstallStatusRow $reportRows[1]))) `
    "Format-InstallStatusSummary: counts every state that came back, same order every time"
Assert-Equal "1 device: 1 Installed" (Format-InstallStatusSummary @($installed)) `
    "Format-InstallStatusSummary: one device isn't called devices"

Assert-True (Test-InstallStatusRowMatchesFilter -Row $installed -Filter 'All') "filter All keeps every row"
Assert-True (-not (Test-InstallStatusRowMatchesFilter -Row $installed -Filter 'Failed only')) "filter Failed only drops an installed row"
Assert-True (Test-InstallStatusRowMatchesFilter -Row ([pscustomobject]@{ State = "Failed" }) -Filter 'Failed only') "filter Failed only keeps a failed row"

# Paging, the fallback to the older endpoint and the row cap, with the Graph
# call itself faked - see Get-AppInstallStatusRows' -Invoke
$script:calls = New-Object System.Collections.Generic.List[string]
$pagingInvoke = {
    param($Uri, $Method, $Body)
    $script:calls.Add("$Method $($Uri -replace '^https://graph.microsoft.com', '') skip=$($Body.skip) top=$($Body.top)")
    $names = if ($Body.skip -eq 0) { @("PC-1", "PC-2") } else { @("PC-3") }
    @{ Schema = @(@{ Column = "DeviceName" }); Values = @($names | ForEach-Object { , @($_) }) }
}
$paged = Get-AppInstallStatusRows -AppId "app-1" -Invoke $pagingInvoke -PageSize 2
Assert-Equal 3 @($paged.Rows).Count "Get-AppInstallStatusRows: keeps paging while a full page comes back"
Assert-Equal "report" $paged.Source "Get-AppInstallStatusRows: says the rows came from the report endpoint"
Assert-True (-not $paged.Truncated) "Get-AppInstallStatusRows: a complete result isn't truncated"
Assert-Equal "POST /beta/deviceManagement/reports/getDeviceInstallStatusReport skip=0 top=2" $script:calls[0] `
    "Get-AppInstallStatusRows: asks the report endpoint, filtered by app, from the first row"
Assert-Equal "POST /beta/deviceManagement/reports/getDeviceInstallStatusReport skip=2 top=2" $script:calls[1] `
    "Get-AppInstallStatusRows: the next page skips what it already has"

$cappedInvoke = {
    param($Uri, $Method, $Body)
    @{ Schema = @(@{ Column = "DeviceName" }); Values = @(1..2 | ForEach-Object { , @("PC-$_") }) }
}
$capped = Get-AppInstallStatusRows -AppId "app-1" -Invoke $cappedInvoke -PageSize 2 -MaxRows 4
Assert-Equal 4 @($capped.Rows).Count "Get-AppInstallStatusRows: stops at the row cap instead of paging forever"
Assert-True $capped.Truncated "Get-AppInstallStatusRows: says so when it stopped at the cap"

$fallbackInvoke = {
    param($Uri, $Method, $Body)
    if ($Uri -like '*getDeviceInstallStatusReport*') { throw "Resource not found for the segment 'reports'" }
    @{ value = @(@{ deviceName = "PC-9"; userPrincipalName = "ada@contoso.com"; installState = "failed"; errorCode = -2016345308 }) }
}
$fallback = Get-AppInstallStatusRows -AppId "app-1" -Invoke $fallbackInvoke
Assert-Equal "deviceStatuses" $fallback.Source "Get-AppInstallStatusRows: falls back to the older endpoint when the report one fails"
Assert-Equal "PC-9" @($fallback.Rows)[0].DeviceName "Get-AppInstallStatusRows: the fallback's rows are normalized the same way"
Assert-Equal "0x87D10324 (-2016345308)" @($fallback.Rows)[0].ErrorCode "Get-AppInstallStatusRows: the fallback keeps the error code"

$bothFailInvoke = { param($Uri, $Method, $Body) throw "nope" }
$bothFailed = $false
try { [void](Get-AppInstallStatusRows -AppId "app-1" -Invoke $bothFailInvoke) } catch { $bothFailed = $_.Exception.Message -like "*deviceStatuses endpoint didn't work either*" }
Assert-True $bothFailed "Get-AppInstallStatusRows: both endpoints failing reports both errors"

# =================================================================
# Report
# =================================================================
Write-Host ""
if ($script:failures.Count -eq 0) {
    Write-Host "PASSED: $($script:passCount) assertion(s), 0 failure(s)." -ForegroundColor Green
    exit 0
} else {
    Write-Host "FAILED: $($script:failures.Count) of $($script:passCount + $script:failures.Count) assertion(s)." -ForegroundColor Red
    foreach ($f in $script:failures) { Write-Host "`n$f" -ForegroundColor Red }
    exit 1
}
