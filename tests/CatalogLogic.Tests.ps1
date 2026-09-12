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
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$privateRoot = Join-Path $repoRoot "Private"
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
    "Get-GroupFieldDiffs"
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

# $Script:Apps is what Get-DefaultAppMetadata reads (its "default to
# depending on Winget AutoUpdate if it exists" check) - stubbed here since
# the real script's own startup (which populates this from the app-data
# folder) never runs in this harness.
$Script:Apps = New-Object System.Collections.Generic.List[object]

# $Script:DefaultAppSettings is what Get-DefaultAppMetadata now reads for
# every value it used to hardcode directly - stubbed with the exact same
# factory values the real script itself initializes this to, so this
# harness exercises the same defaults a real, never-customized install
# would compute. If the real script's own factory values above ever
# change, this needs updating to match, same as every other value this
# test suite mirrors from the real script.
$Script:DefaultAppSettings = [pscustomobject]@{
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

# Winget AutoUpdate dependency default - present in $Script:Apps, app isn't itself Winget AutoUpdate
$Script:Apps.Clear()
$Script:Apps.Add([pscustomobject]@{ appName = "Winget AutoUpdate" })
$defaultsWithWau = Get-DefaultAppMetadata -AppName "Some Other App" -WingetId "some.app" -Uncommon $false
Assert-True (@($defaultsWithWau.dependencies) -contains "Winget AutoUpdate") `
    "Get-DefaultAppMetadata: defaults to depending on Winget AutoUpdate when it exists in the catalog"

# Winget AutoUpdate itself shouldn't depend on itself
$defaultsForWauItself = Get-DefaultAppMetadata -AppName "Winget AutoUpdate" -WingetId "some.app" -Uncommon $false
Assert-True (@($defaultsForWauItself.dependencies) -notcontains "Winget AutoUpdate") `
    "Get-DefaultAppMetadata: Winget AutoUpdate itself never defaults to depending on itself"

# Winget AutoUpdate absent from the catalog entirely
$Script:Apps.Clear()
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
$Script:Apps.Clear()
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
