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
# Scans every code\Private\**\*.ps1 file, so a function can move between
# files without this suite needing an update to keep finding it.
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "../..")
$privateRoot = Join-Path $repoRoot "code\Private"
$privateFiles = Get-ChildItem -Path $privateRoot -Filter "*.ps1" -Recurse

# Deliberately narrow list - only genuinely pure, side-effect-free
# functions. Adding a name here is a claim that function has NO WinForms
# and NO live Graph dependency; verify that before adding one.
$testableFunctionNames = @(
    "Test-AppIsUncommon",
    # winget output (Winget.ps1)
    "ConvertFrom-WingetSearchOutput",
    "ConvertTo-WindowsArgument",
    # Security: secrets out of logs, folder paths (Helpers.ps1, AppFolders.ps1)
    "Protect-LogText",
    "Get-GroupLookupUris",
    "Get-AppWindowPreferencesJson",
    "Test-AppFolderPath",
    "Get-WingetShowVerdict",
    "Compare-AppVersionText",
    # Diagnostics (Diagnostics.ps1)
    "Get-CatalogDiagnosticLines",
    "Get-SafeFileNameForApp",
    "Get-DependencyOrderedApps",
    # The Checks window's one findings list (CheckFindings.ps1)
    "Get-IntuneCatalogDrift",
    "New-CheckFinding",
    "Find-IntuneNameMatches",
    "Get-IntuneLinkFindings",
    "Get-AuditSummaryTexts",
    "Get-AppDetailFindings",
    "Get-CheckValueText",
    "Get-UnknownAssignmentText",
    "Get-UnknownAssignmentFindings",
    "Get-DependencyFindings",
    "Get-EntraGroupFindings",
    "Get-WingetFindings",
    "Get-CachedAuditFindings",
    "ConvertTo-CatalogEntryFromFetch",
    "Get-CatalogMetadataSimpleFields",
    "Get-CatalogMetadataFieldDiffs",
    "Get-ComparableDetectionRule",
    "ConvertTo-CatalogMetadataFromFetch",
    "Get-WingetIdFromInstallCommand",
    "Get-FirstWingetIdToken",
    "ConvertTo-DetectionRuleJson",
    "ConvertTo-JsonStringLiteral",
    "Merge-CatalogMetadata",
    # Supersedence: mapping, summary, compare, catalog and config JSON
    "ConvertTo-SupersedenceEntries",
    "Format-SupersedenceSummary",
    "Get-SupersedenceCompareKey",
    "ConvertTo-SupersedenceJson",
    "ConvertTo-CreateAppConfigJson",
    "Get-CreateAppTemplates",
    "ConvertTo-PsSingleQuotedContent",
    "Get-WingetCommandLines",
    "Get-AppWingetInstallMethod",
    "Convert-AppWingetInstallMethod",
    "Get-DefaultAppMetadata",
    "Get-FriendlyIntuneAppType",
    "Get-ParsedMinOsRelease",
    "Get-FriendlyMinOsRelease",
    "Test-AppHasCustomConfig",
    "ConvertTo-AppRecord",
    # The other half of that round trip. Pure string building - it writes
    # JSON field by field rather than serialising, which is exactly why it
    # is worth a test.
    "ConvertTo-SingleAppJson",
    "ConvertTo-AppIcon",
    "ConvertTo-AppReleases",
    "Test-ReleaseVersionText",
    "Get-ManagedWingetDetection",
    "Set-ManagedAppPin",
    "Test-VersionDetectionRule",
    "Set-DetectionRuleVersion",
    "Get-ReleaseDecision",
    "ConvertTo-ReleasePolicy",
    "Format-ReleaseSpan",
    "Get-EffectiveReleaseRule",
    "Get-ReleaseRingGroups",
    "ConvertFrom-ReleaseRingText",
    "Get-ReleaseAssignmentSettings",
    "Get-ManagedRunAlert",
    "ConvertTo-AppReleaseRule",
    "ConvertTo-ReleaseRings",
    "ConvertTo-AlertSettings",
    "Test-ReleaseWindow",
    "Get-InstallErrorSummary",
    "Test-AutoWithdraw",
    "Get-CertificateHealth",
    "Get-InventorySuggestions",
    "Get-GateVersion",
    "Get-MonthlyReportData",
    "ConvertFrom-WingetShowOutput",
    "Get-InstallerKind",
    "Get-InstallerProposal",
    "New-InstalledAppDetectionScript",
    "New-InstalledAppUninstallScript",
    "Get-ScriptAppTemplates",
    "Get-ScriptAppMarkerRule",
    "ConvertTo-AssignmentProfiles",
    "ConvertTo-DetectionFromInstalled",
    "ConvertTo-DetectionTestScript",
    "ConvertFrom-WingetExportJson",
    "Get-AppUpdateOffer",
    "ConvertTo-PsLiteral",
    "Get-InstalledNamePattern",
    "Test-StoreProductId",
    "Get-PermissionReport",
    "Set-PsadtTemplateValues",
    "ConvertTo-JsonStringArray",
    "ConvertTo-FriendlyGraphError",
    "Save-ScriptsToFolder",
    "ConvertTo-ScriptRecord",
    "ConvertTo-SingleScriptJson",
    "Get-SafeFileNameForScript",
    "ConvertTo-DisplayLineEndings",
    "ConvertTo-TemplateAppRecord",
    "Get-NormalizedInstallTimeMinutes",
    "Get-GroupFieldDiffs",
    "Format-GroupFieldDiffs",
    # Lives in CatalogIO.ps1 but only touches $Global:App.LastAuditResults.
    "Set-LastAuditCacheEntry",
    # Both touch the filesystem, which is not a WinForms or Graph
    # dependency - the tests below give them a real temp folder to look
    # at. Get-AppFolder comes with them because that is how they find the
    # packages folder, and it only reads $Global:App.AppFolders.
    "Get-PackageFolderIndex",
    "Resolve-AppPackagePath",
    "Get-AppFolder",
    "Get-AppFolderDefault",
    "Get-AppFolderKinds",
    # Lives in Helpers.ps1, not Private\Catalog\ - the scan below isn't
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
    # Plain-language Graph errors (Helpers.ps1)
    "Get-GraphPermissionHint",
    "ConvertTo-FriendlyGraphError",
    # Graph module vs. another module's libraries (GraphModuleConflict.ps1)
    "Test-GraphAssemblyConflictText",
    "Get-ModuleNameFromAssemblyPath",
    "Get-GraphAssemblyConflicts",
    "Test-SessionStartedWithoutProfile",
    "Format-GraphAssemblyConflictText",
    # Graph request log formatting (GraphLog.ps1) - pure string work
    "Get-GraphRequestPath",
    "Get-GraphRequestId",
    # A local catalog of platform scripts (ScriptCatalog.ps1)
    "ConvertTo-ScriptRecord",
    "ConvertTo-ScriptBool",
    "Get-SafeFileNameForScript",
    "Get-ScriptFieldDiffs",
    "ConvertTo-SingleScriptJson",
    "Save-ScriptsToFolder",
    "Import-ScriptsFromFolder",
    # Deleting several groups at once (Helpers.ps1) - pure planning work
    "Get-GroupDeletionPlan",
    "Format-GroupDeletionWarning",
    # What the token is allowed to do (GraphToken.ps1) - pure claim work
    "ConvertFrom-JwtPayload",
    "Get-GraphRoleRequirements",
    "Get-GraphRoleReport",
    "Format-GraphRoleReport",
    "Format-SetupChecklist",
    "Get-GraphErrorBodyMessage",
    "Get-GraphErrorRecordMessage",
    "Get-InnermostErrorMessage",
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
    "Get-AppInstallStatusRows",
    # Platform scripts (PlatformScripts.ps1) - body building and validation
    "ConvertTo-PlatformScriptBase64",
    "ConvertFrom-PlatformScriptBase64",
    "Get-PlatformScriptFileName",
    "Test-PlatformScriptInput",
    "New-PlatformScriptBody",
    "New-PlatformScriptAssignBody",
    "ConvertTo-PlatformScriptRow",
    "Get-PlatformScriptGroupNames",
    "ConvertTo-ScriptRunStateRow",
    "Format-ScriptRunSummary",
    # Assignments incl. exclusions (Assignments.ps1)
    "Get-AssignmentKey",
    "Get-DesiredAssignmentEntries",
    "ConvertTo-CurrentAssignmentEntries",
    "Format-AssignmentLabel",
    "Get-AssignmentDiff",
    "New-AppAssignmentBody"
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
    $found = $ast.FindAll({
        param($node)
        # Every top-level Private\ function is declared as "function
        # Global:Name" (see IntuneDeployment.ps1's header comment for why),
        # so the AST's own Name includes that "Global:" scope prefix - strip
        # it before comparing against the plain names below.
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $testableFunctionNames -contains ($node.Name -replace '^[A-Za-z]+:', '')
    }, $true)
    foreach ($m in $found) { $funcAsts.Add($m) }
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
    WingetInstallMethod      = "WAU"
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

# Install method: Winget-AutoUpdate by default, winget.exe when chosen
$wauDefaults = Get-DefaultAppMetadata -AppName "Some App" -WingetId "Vendor.App" -Uncommon $false
Assert-True ($wauDefaults.installCommand -like '*Winget-Install.ps1*-AppIDs "Vendor.App"' -and $wauDefaults.uninstallCommand -like '*-AppIDs "Vendor.App" -Uninstall') `
    "Get-DefaultAppMetadata: the built-in install method is Winget-AutoUpdate's Winget-Install.ps1"
$Global:App.DefaultAppSettings.WingetInstallMethod = "Winget"
$wingetDefaults = Get-DefaultAppMetadata -AppName "Some App" -WingetId "Vendor.App" -Uncommon $false
Assert-True ($wingetDefaults.installCommand -like "*& `$w install --id 'Vendor.App' -e*--scope machine*" -and $wingetDefaults.installCommand -notlike '*Winget-Install.ps1*') `
    "Get-DefaultAppMetadata: with the Winget command method, install calls winget.exe itself, machine-wide in System context"
Assert-True ($wingetDefaults.uninstallCommand -like "*& `$w uninstall --id 'Vendor.App' -e*") `
    "Get-DefaultAppMetadata: with the Winget command method, uninstall calls winget uninstall"
Assert-True ($wingetDefaults.installCommand.Length -le 1024 -and $wingetDefaults.uninstallCommand.Length -le 1024) `
    "Get-WingetCommandLines: the winget commands fit Intune's 1024-character command line"
Assert-Equal 'Vendor.App' (Get-WingetIdFromInstallCommand -InstallCommand $wingetDefaults.installCommand) `
    "Get-WingetIdFromInstallCommand: reads the Winget ID back out of the Winget command form"
$parseErrors = $null
$inner = [regex]::Match($wingetDefaults.installCommand, '-Command "(.*)"$').Groups[1].Value
[void][System.Management.Automation.Language.Parser]::ParseInput($inner, [ref]$null, [ref]$parseErrors)
Assert-Equal 0 @($parseErrors).Count `
    "Get-WingetCommandLines: the script inside -Command parses"
$userCommands = Get-WingetCommandLines -WingetId "Vendor.App" -Method "Winget" -InstallContext "User"
Assert-True ($userCommands.Install -notlike '*--scope machine*') `
    "Get-WingetCommandLines: a User-context install doesn't force machine scope"
$Global:App.DefaultAppSettings.WingetInstallMethod = "WAU"

# Managed updates: a pinned version, detection of it or newer, releases
$managedCmd = Get-WingetCommandLines -WingetId "Vendor.App" -Method "Managed" -InstallContext "System" -Version "24.09"
Assert-True ($managedCmd.Install -like "*install --id 'Vendor.App' -e --version '24.09' --source winget*" -and $managedCmd.Install.Length -le 1024) "Get-WingetCommandLines: Managed pins the version with --version"
$inner = [regex]::Match($managedCmd.Install, '-Command "(.*)"$').Groups[1].Value
$parseErrors = $null; [void][System.Management.Automation.Language.Parser]::ParseInput($inner, [ref]$null, [ref]$parseErrors)
Assert-Equal 0 @($parseErrors).Count "Get-WingetCommandLines: the pinned command's script parses"
Assert-Equal 'Managed' (Get-AppWingetInstallMethod -WingetId "Vendor.App" -InstallCommand $managedCmd.Install -UninstallCommand $managedCmd.Uninstall) "Get-AppWingetInstallMethod: recognises the pinned (managed) form"
Assert-True ((Get-WingetCommandLines -WingetId "Vendor.App" -Method "Managed" -InstallContext "System" -Version "1.0'; calc").Install -notlike '*--version*') "Get-WingetCommandLines: a version with a quote is never pinned (it would go into the command line)"
Assert-True ((Test-ReleaseVersionText '131.0.6778.86') -and (Test-ReleaseVersionText '1.0-beta+2') -and -not (Test-ReleaseVersionText '') -and -not (Test-ReleaseVersionText '1.0 && x')) "Test-ReleaseVersionText: versions, not commands"
$det = Get-ManagedWingetDetection -WingetId "Vendor.App" -Version "24.09"
$parseErrors = $null; [void][System.Management.Automation.Language.Parser]::ParseInput($det, [ref]$null, [ref]$parseErrors)
Assert-True ($det -like "*'Vendor.App'*" -and $det -like "*'24.09'*" -and $det -like '*--include-versions*' -and @($parseErrors).Count -eq 0) "Get-ManagedWingetDetection: checks this ID at this version or newer, and parses"
$pinApp = [pscustomobject]@{ managedUpdates = $true; wingetId = 'Vendor.App'; metadata = [pscustomobject]@{ appVersion = '5.1'; installCommand = $wingetDefaults.installCommand; uninstallCommand = $wingetDefaults.uninstallCommand; installContext = 'System'; detectionRule = $null } }
Assert-True ((Set-ManagedAppPin $pinApp) -and $pinApp.metadata.installCommand -like "*--version '5.1'*" -and $pinApp.metadata.detectionRule.Script_Content -like "*'5.1'*") "Set-ManagedAppPin: commands and detection follow the App version"
Assert-True (-not (Set-ManagedAppPin $pinApp)) "Set-ManagedAppPin: nothing to change the second time"
$handApp = [pscustomobject]@{ managedUpdates = $true; wingetId = 'Vendor.App'; metadata = [pscustomobject]@{ appVersion = '5.1'; installCommand = 'setup.exe /custom'; uninstallCommand = 'x'; installContext = 'System'; detectionRule = $null } }
Assert-True (-not (Set-ManagedAppPin $handApp) -and $handApp.metadata.installCommand -eq 'setup.exe /custom') "Set-ManagedAppPin: commands edited by hand are left alone"
$rels = @(ConvertTo-AppReleases @([pscustomobject]@{ version = '2.0'; appId = 'dddddddd-0000-4000-8000-000000000001'; state = 'pilot' }, [pscustomobject]@{ version = '1.0'; appId = '../x'; state = 'previous' }, [pscustomobject]@{ version = '0.9'; appId = 'dddddddd-0000-4000-8000-000000000002'; state = 'weird' }))
Assert-True ($rels.Count -eq 1 -and $rels[0].state -eq 'pilot') "ConvertTo-AppReleases: only GUID App IDs, pinnable versions and known states"
$relRecord = ConvertTo-AppRecord -Raw ([pscustomobject]@{ appName = 'Rel App'; managedUpdates = $true; releases = @([pscustomobject]@{ version = '2.0'; appId = 'dddddddd-0000-4000-8000-000000000001'; state = 'pilot'; at = 'x' }) })
$relBack = ConvertTo-AppRecord -Raw ((ConvertTo-SingleAppJson -App $relRecord) | ConvertFrom-Json)
Assert-True ($relBack.managedUpdates -and @($relBack.releases).Count -eq 1 -and $relBack.releases[0].version -eq '2.0') "ConvertTo-SingleAppJson/ConvertTo-AppRecord: managed updates and releases round-trip"
Assert-True ((ConvertTo-SingleAppJson -App (ConvertTo-AppRecord -Raw ([pscustomobject]@{ appName = 'Plain' }))) -notlike '*managedUpdates*') "ConvertTo-SingleAppJson: no managed fields for an unmanaged app"
$tpl = ConvertTo-TemplateAppRecord -App $relBack
Assert-True ($tpl.managedUpdates -and @($tpl.releases).Count -eq 0) "ConvertTo-TemplateAppRecord: keeps managed updates, drops this tenant's releases"
$relIntune = New-Object System.Collections.Generic.List[object]
$relIntune.Add([pscustomobject]@{ id = 'dddddddd-0000-4000-8000-000000000001'; displayName = 'Rel App 2.0 (pilot)' })
$relIntune.Add([pscustomobject]@{ id = 'dddddddd-0000-4000-8000-0000000000ff'; displayName = 'Something Else' })
$relFindings = @(Get-IntuneLinkFindings -Apps @($relBack) -IntuneApps $relIntune.ToArray() | Where-Object { $_.Problem -eq 'In Intune, not in the catalog' } | ForEach-Object { [string]$_.App })
Assert-True (($relFindings -contains 'Something Else') -and ($relFindings -notcontains 'Rel App 2.0 (pilot)')) "Get-IntuneLinkFindings: a release's app in Intune isn't 'not in the catalog' (another app still is)"

# Managed updates for own packages: the detection rule follows the version
$msiRule = [pscustomobject]@{ Type = 'Msi'; Msi_ProductCode = '{11111111-1111-1111-1111-111111111111}'; Msi_VersionOperator = 'notConfigured'; Msi_Version = '' }
$msiNew = Set-DetectionRuleVersion -Rule $msiRule -Version '2.5.0' -ProductCode '{22222222-2222-2222-2222-222222222222}'
Assert-True ($msiNew.Changed -and $msiNew.Rule.Msi_Version -eq '2.5.0' -and $msiNew.Rule.Msi_VersionOperator -eq 'greaterThanOrEqual' -and $msiNew.Rule.Msi_ProductCode -eq '{22222222-2222-2222-2222-222222222222}' -and $msiRule.Msi_Version -eq '') "Set-DetectionRuleVersion: MSI version, operator and product code - on a copy"
$fileRule = [pscustomobject]@{ Type = 'File'; File_Path = 'C:\x'; File_Name = 'a.exe'; File_DetectionType = 'version'; File_Operator = 'equal'; File_DetectionValue = '1.0' }
$fileNew = Set-DetectionRuleVersion -Rule $fileRule -Version '1.1'
Assert-True ($fileNew.Changed -and $fileNew.Rule.File_DetectionValue -eq '1.1' -and $fileNew.Rule.File_Operator -eq 'equal') "Set-DetectionRuleVersion: a file version rule keeps its version operator"
$scriptRule = [pscustomobject]@{ Type = 'Script'; Script_Content = 'x' }
Assert-True ((Test-VersionDetectionRule $scriptRule) -and -not (Set-DetectionRuleVersion -Rule $scriptRule -Version '1.1').Changed) "Test-VersionDetectionRule: a script rule can't follow a version"
Assert-True ((Test-VersionDetectionRule ([pscustomobject]@{ Type = 'File'; File_DetectionType = 'exists' })) -ne '') "Test-VersionDetectionRule: a file-exists rule can't either"
$ownApp = [pscustomobject]@{ managedUpdates = $true; wingetId = ''; metadata = [pscustomobject]@{ appVersion = '3.0'; detectionRule = $fileRule } }
Assert-True ((Set-ManagedAppPin $ownApp) -and $ownApp.metadata.detectionRule.File_DetectionValue -eq '3.0') "Set-ManagedAppPin: an own package's detection rule follows the App version"

# When a pilot release is ready for everyone
$pol = ConvertTo-ReleasePolicy ([pscustomobject]@{ Days = 3; MaxFailedPercent = 10; MinInstalled = 2 })
$t0 = [datetime]'2026-11-01 08:00'
Assert-Equal 'wait' (Get-ReleaseDecision -ReleasedAt $t0 -Now $t0.AddDays(1) -Counts @{ installed = 5; failed = 0 } -Policy $pol).Action "Get-ReleaseDecision: waits out the pilot days"
Assert-Equal 'promote' (Get-ReleaseDecision -ReleasedAt $t0 -Now $t0.AddDays(3.5) -Counts @{ installed = 9; failed = 1 } -Policy $pol).Action "Get-ReleaseDecision: promotes after the days with failures at the limit"
Assert-Equal 'hold' (Get-ReleaseDecision -ReleasedAt $t0 -Now $t0.AddDays(1) -Counts @{ installed = 3; failed = 2 } -Policy $pol).Action "Get-ReleaseDecision: holds as soon as too many failed"
Assert-Equal 'wait' (Get-ReleaseDecision -ReleasedAt $t0 -Now $t0.AddDays(4) -Counts @{ installed = 1; failed = 0 } -Policy $pol).Action "Get-ReleaseDecision: waits for enough installs"
Assert-Equal 'hold' (Get-ReleaseDecision -ReleasedAt $t0 -Now $t0.AddDays(7) -Counts @{ installed = 0; failed = 0 } -Policy $pol).Action "Get-ReleaseDecision: holds when nothing installed it for twice the pilot time"
$badPol = ConvertTo-ReleasePolicy ([pscustomobject]@{ Days = 'x'; MaxFailedPercent = 400; RunAt = '25:00'; AutoPromote = $true })
Assert-True ($badPol.Days -eq 3 -and $badPol.MaxFailedPercent -eq 5 -and $badPol.RunAt -eq '03:00' -and $badPol.AutoPromote) "ConvertTo-ReleasePolicy: wrong values fall back to the defaults, good ones are kept"
$pol2 = ConvertTo-ReleasePolicy ([pscustomobject]@{ FastTrackHours = 6; DeadlineDays = 2; RestartGraceMinutes = 90; Notifications = 'hideAll' })
Assert-True ($pol2.FastTrackHours -eq 6 -and $pol2.DeadlineDays -eq 2 -and $pol2.RestartGraceMinutes -eq 90 -and $pol2.Notifications -eq 'hideAll') "ConvertTo-ReleasePolicy: fast track, deadline, restart grace and notifications"
$pol3 = ConvertTo-ReleasePolicy ([pscustomobject]@{ FastTrackHours = 0; DeadlineDays = 99; Notifications = 'loud' })
Assert-True ($pol3.FastTrackHours -eq 4 -and $pol3.DeadlineDays -eq 0 -and $pol3.Notifications -eq 'showAll') "ConvertTo-ReleasePolicy: out-of-range fast track, deadline and notifications fall back"

# Release rings, an app's own rule, fast track
Assert-Equal 'advance' (Get-ReleaseDecision -ReleasedAt $t0 -Now $t0.AddDays(3.5) -Counts @{ installed = 9; failed = 0 } -Policy $pol -Ring 0 -RingCount 3).Action "Get-ReleaseDecision: ready in ring 1 of 3 - on to the next ring"
Assert-Equal 'promote' (Get-ReleaseDecision -ReleasedAt $t0 -Now $t0.AddDays(3.5) -Counts @{ installed = 9; failed = 0 } -Policy $pol -Ring 2 -RingCount 3).Action "Get-ReleaseDecision: ready in the last ring - to everyone"
$fastRule = Get-EffectiveReleaseRule -Policy (ConvertTo-ReleasePolicy $null) -App $null -Release ([pscustomobject]@{ fastTrack = $true })
$fastWait = Get-ReleaseDecision -ReleasedAt $t0 -Now $t0.AddHours(2) -Counts @{ installed = 3; failed = 0 } -Policy $fastRule
$fastGo = Get-ReleaseDecision -ReleasedAt $t0 -Now $t0.AddHours(5) -Counts @{ installed = 3; failed = 0 } -Policy $fastRule
Assert-True ($fastRule.FastTrack -and $fastWait.Action -eq 'wait' -and $fastWait.Reason -like '*2 hours of 4 hours*' -and $fastGo.Action -eq 'promote') "Get-EffectiveReleaseRule: a fast-track release is judged in hours"
$ownRule = Get-EffectiveReleaseRule -Policy (ConvertTo-ReleasePolicy $null) -App ([pscustomobject]@{ releaseRule = (ConvertTo-AppReleaseRule ([pscustomobject]@{ days = '1'; minInstalled = '' })) }) -Release $null
Assert-True ($ownRule.Own -and $ownRule.Days -eq 1 -and $ownRule.MaxFailedPercent -eq 5 -and $ownRule.MinInstalled -eq 1) "Get-EffectiveReleaseRule: the app's own days over the policy, the rest from the policy"
Assert-Null (ConvertTo-AppReleaseRule ([pscustomobject]@{ days = ''; maxFailedPercent = 'x'; minInstalled = '-1' })) "ConvertTo-AppReleaseRule: nothing valid set - no own rule"
$ringText = ConvertFrom-ReleaseRingText "Early adopters: SG-A, SG-B`r`n`r`nBroad: SG-C, SG-A"
Assert-True (-not $ringText.Error -and @($ringText.Rings).Count -eq 2 -and $ringText.Rings[0].Name -eq 'Early adopters' -and @($ringText.Rings[0].Groups).Count -eq 2) "ConvertFrom-ReleaseRingText: one ring per line, blank lines skipped"
Assert-True ((ConvertFrom-ReleaseRingText 'just a group').Error -like 'Line 1*') "ConvertFrom-ReleaseRingText: a line without a name says which line"
$rings = @(@{ Name = 'Pilot'; Groups = @('SG-P') }) + @($ringText.Rings)
Assert-Equal 'SG-P,SG-A,SG-B' ((Get-ReleaseRingGroups -Rings $rings -Ring 1) -join ',') "Get-ReleaseRingGroups: a ring's groups and every ring's before it"
Assert-Equal 'SG-P,SG-A,SG-B,SG-C' ((Get-ReleaseRingGroups -Rings $rings -Ring 2) -join ',') "Get-ReleaseRingGroups: each group once"
Assert-Equal 1 @(ConvertTo-ReleaseRings @(@{ Name = 'X'; Groups = @('SG-1') }, @{ Name = ''; Groups = @('SG-2') }, @{ Name = 'Y'; Groups = @() })).Count "ConvertTo-ReleaseRings: rings without a name or a group are dropped"

# Assignment settings for a release
$now = [datetime]::new(2026, 11, 13, 10, 0, 0, [DateTimeKind]::Utc)
Assert-Null (Get-ReleaseAssignmentSettings -Policy (ConvertTo-ReleasePolicy $null) -FastTrack $false -NowUtc $now) "Get-ReleaseAssignmentSettings: Intune's defaults - no settings sent"
$set = Get-ReleaseAssignmentSettings -Policy $pol2 -FastTrack $false -NowUtc $now
Assert-True ($set.installTimeSettings.deadlineDateTime -eq '2026-11-15T10:00:00Z' -and $set.restartSettings.gracePeriodInMinutes -eq 90 -and $set.notifications -eq 'hideAll' -and $set.deliveryOptimizationPriority -eq 'notConfigured') "Get-ReleaseAssignmentSettings: deadline, restart grace and notifications"
$fastSet = Get-ReleaseAssignmentSettings -Policy $pol2 -FastTrack $true -NowUtc $now
Assert-True ($null -eq $fastSet.installTimeSettings -and $fastSet.deliveryOptimizationPriority -eq 'foreground') "Get-ReleaseAssignmentSettings: a fast-track release installs at once, in the foreground"
$withSettings = New-AppAssignmentBody -Entries @(Get-DesiredAssignmentEntries -RequiredGroups @('SG-All') -AvailableGroups @('SG-Self') -ExcludeGroups @('SG-No')) -GroupIdByName @{ 'SG-All' = 'id-1'; 'SG-Self' = 'id-2'; 'SG-No' = 'id-3' } -RequiredSettings $set
$req = @($withSettings.mobileAppAssignments | Where-Object { $_.intent -eq 'required' -and $_.target.'@odata.type' -like '*groupAssignmentTarget' -and $_.target.'@odata.type' -notlike '*exclusion*' })
$others = @($withSettings.mobileAppAssignments | Where-Object { $_.ContainsKey('settings') })
Assert-True ($req.Count -eq 1 -and $others.Count -eq 1 -and $req[0].settings.notifications -eq 'hideAll') "New-AppAssignmentBody: the settings go on the Required inclusions only"

# The nightly run's other work
$winPol = ConvertTo-ReleasePolicy ([pscustomobject]@{ ReleaseDays = @(1, 2, 3, 4); SkipLastWeek = $true; AutoWithdrawPercent = 30; DriftFix = $true; GatePath = '\\srv\test\app-data' })
Assert-True ((@($winPol.ReleaseDays) -join ',') -eq '1,2,3,4' -and $winPol.SkipLastWeek -and $winPol.AutoWithdrawPercent -eq 30 -and $winPol.DriftCheck -and $winPol.DriftFix -and $winPol.BackupCatalog -and $winPol.GatePath -eq '\\srv\test\app-data') "ConvertTo-ReleasePolicy: release window, withdraw, drift, backup and the test tenant's folder"
Assert-Equal '' (ConvertTo-ReleasePolicy ([pscustomobject]@{ GatePath = 'relative\folder' })).GatePath "ConvertTo-ReleasePolicy: a relative test-tenant folder is refused"
Assert-True ((Test-ReleaseWindow -Now ([datetime]'2026-11-12 03:00') -Policy $winPol).Open) "Test-ReleaseWindow: a Thursday in the middle of the month is open"
$fri = Test-ReleaseWindow -Now ([datetime]'2026-11-13 03:00') -Policy $winPol
Assert-True (-not $fri.Open -and $fri.Reason -like '*Fridays*') "Test-ReleaseWindow: a Friday is closed, and says so"
Assert-True (-not (Test-ReleaseWindow -Now ([datetime]'2026-11-26 03:00') -Policy $winPol).Open) "Test-ReleaseWindow: a Thursday in the month's last week is closed"
Assert-True ((Test-ReleaseWindow -Now ([datetime]'2026-11-29 03:00') -Policy (ConvertTo-ReleasePolicy $null)).Open) "Test-ReleaseWindow: by default every day is open"
$errRows = @([pscustomobject]@{ State = 'Failed'; ErrorCode = '0x80070643'; Detail = 'Fatal error during installation' }, [pscustomobject]@{ State = 'Failed'; ErrorCode = '0x80070643'; Detail = '' },
    [pscustomobject]@{ State = 'Failed'; ErrorCode = '0x87D1041C'; Detail = 'not detected' }, [pscustomobject]@{ State = 'Installed'; ErrorCode = '0'; Detail = '' })
$es = Get-InstallErrorSummary -Rows $errRows
Assert-True ($es.Failed -eq 3 -and $es.Top[0].code -eq '0x80070643' -and $es.Top[0].devices -eq 2 -and $es.Text -like '2 devices: 0x80070643 (Fatal error during installation)*') "Get-InstallErrorSummary: failed devices by error code, most common first"
Assert-Equal '' (Get-InstallErrorSummary -Rows @($errRows[3])).Text "Get-InstallErrorSummary: nothing failed - no text"
Assert-True ((Test-AutoWithdraw -Counts @{ installed = 2; failed = 2 } -Percent 30) -and -not (Test-AutoWithdraw -Counts @{ installed = 1; failed = 1 } -Percent 30) -and -not (Test-AutoWithdraw -Counts @{ installed = 0; failed = 9 } -Percent 0)) "Test-AutoWithdraw: at the limit with three or more devices tried; never when off"
$nowH = [datetime]'2026-11-14'
Assert-Equal 'warn' (Get-CertificateHealth -NotAfter $nowH.AddDays(12) -Now $nowH).Level "Get-CertificateHealth: 12 days left - a warning"
Assert-Equal 'failed' (Get-CertificateHealth -NotAfter $nowH.AddDays(-1) -Now $nowH).Level "Get-CertificateHealth: expired - a failure"
Assert-Equal 'ok' (Get-CertificateHealth -NotAfter $nowH.AddDays(200) -Now $nowH).Level "Get-CertificateHealth: half a year left - fine"
Assert-Equal 'failed' (Get-CertificateHealth -NotAfter $null -Now $nowH).Level "Get-CertificateHealth: not found - a failure"
$det = @(@{ displayName = 'Notepad++ (64-bit x64)'; version = '8.6'; deviceCount = 7 }, @{ displayName = 'Notepad++'; version = '8.5'; deviceCount = 2 }, @{ displayName = '7-Zip 24.08 (x64)'; version = '24.08'; deviceCount = 40 },
    @{ displayName = 'Microsoft Visual C++ 2015-2022 Redistributable (x64)'; version = '14.40'; deviceCount = 90 }, @{ displayName = 'Rare Tool'; version = '1.0'; deviceCount = 1 })
$sug = @(Get-InventorySuggestions -Detected $det -Apps @([pscustomobject]@{ appName = '7-Zip'; detectedName = '' }))
Assert-True ($sug.Count -eq 1 -and $sug[0].name -eq 'Notepad++' -and $sug[0].devices -eq 9 -and @($sug[0].versions).Count -eq 2) "Get-InventorySuggestions: grouped by name; catalog apps, Windows parts and rare apps left out"
$prodApp = [pscustomobject]@{ appName = 'Chrome'; wingetId = 'Google.Chrome'; metadata = [pscustomobject]@{ appVersion = '130.0' } }
$testApps = @([pscustomobject]@{ appName = 'Google Chrome'; wingetId = 'Google.Chrome'; appId = 'x'; metadata = [pscustomobject]@{ appVersion = '131.0' } })
Assert-Equal '131.0' (Get-GateVersion -App $prodApp -GateApps $testApps).Version "Get-GateVersion: the test tenant's promoted version, matched by Winget ID"
Assert-Equal '' (Get-GateVersion -App $prodApp -GateApps @()).Version "Get-GateVersion: not in the test catalog - nothing to release"
$prodApp.metadata.appVersion = '131.0'
Assert-True ((Get-GateVersion -App $prodApp -GateApps $testApps).Reason -like '*nothing newer*') "Get-GateVersion: same version as the test tenant - nothing newer"
$mreps = @(@{ started = '2026-10-01 03:00'; items = @(@{ app = 'A'; outcome = 'released'; text = '2.0 released' }); trend = @{ onCurrentPercent = 80 } },
    @{ started = '2026-10-05 03:00'; items = @(@{ app = 'A'; outcome = 'promoted'; text = '2.0 promoted' }, @{ app = 'B'; outcome = 'current'; text = 'fine' }); trend = @{ onCurrentPercent = 92 } },
    @{ started = '2026-11-01 03:00'; items = @(@{ app = 'C'; outcome = 'released'; text = 'other month' }) })
$md = Get-MonthlyReportData -Reports $mreps -Month '2026-10'
Assert-True ($md.runs -eq 2 -and $md.released -eq 1 -and $md.promoted -eq 1 -and $md.startPercent -eq 80 -and $md.endPercent -eq 92 -and @($md.events).Count -eq 2) "Get-MonthlyReportData: the month's runs, what happened, and the trend from start to end"

# Adding apps: winget details, installers, script apps
$show = "Found 7-Zip [7zip.7zip]`r`nVersion: 24.08`r`nPublisher: Igor Pavlov`r`nPublisher Url: https://www.7-zip.org/`r`nDescription:`r`n  Free and open source file archiver`r`n  with a high compression ratio.`r`nHomepage: https://www.7-zip.org/`r`nLicense: LGPL-2.1-or-later`r`nPrivacy Url: https://www.7-zip.org/privacy`r`nTags:`r`n  7zip`r`n  archiver`r`nInstaller:`r`n  Installer Type: exe`r`n  Installer Url: https://example.test/7z.exe"
$sd = ConvertFrom-WingetShowOutput $show
Assert-True ($sd.Id -eq '7zip.7zip' -and $sd.Name -eq '7-Zip' -and $sd.Version -eq '24.08' -and $sd.Publisher -eq 'Igor Pavlov' -and $sd.Description -eq 'Free and open source file archiver with a high compression ratio.' -and $sd.Homepage -eq 'https://www.7-zip.org/' -and $sd.PrivacyUrl -like '*privacy' -and (@($sd.Tags) -join ',') -eq '7zip,archiver') "ConvertFrom-WingetShowOutput: name, ID, publisher, a description over two lines, URLs and tags - not the installer's keys"
Assert-Equal 'inno' (Get-InstallerKind 'xx Inno Setup Setup Data (6.2.0) xx') "Get-InstallerKind: Inno Setup"
Assert-Equal 'nsis' (Get-InstallerKind 'Nullsoft Install System v3.09') "Get-InstallerKind: NSIS"
Assert-Equal '' (Get-InstallerKind 'just a program') "Get-InstallerKind: unknown"
$msiP = Get-InstallerProposal @{ Kind = 'msi'; FileName = 'Agent.msi'; ProductName = 'Contoso Agent'; Manufacturer = 'Contoso'; ProductVersion = '3.2.1'; ProductCode = '{1c2d3e4f-1111-2222-3333-444455556666}' }
Assert-True ($msiP.Name -eq 'Contoso Agent' -and $msiP.InstallCommand -eq 'msiexec /i "Agent.msi" /qn /norestart' -and $msiP.UninstallCommand -eq 'msiexec /x {1C2D3E4F-1111-2222-3333-444455556666} /qn /norestart' -and $msiP.Detection.Type -eq 'Msi' -and $msiP.Detection.Msi_VersionOperator -eq 'greaterThanOrEqual' -and $msiP.ManagedOk -and -not (Test-VersionDetectionRule ([pscustomobject]$msiP.Detection))) "Get-InstallerProposal: an MSI - msiexec, its product code, by version (managed updates possible)"
$exeP = Get-InstallerProposal @{ Kind = 'exe'; FileName = 'tool-setup.exe'; ProductName = 'Tool'; Manufacturer = 'Vendor'; ProductVersion = '2.1.0.5'; ExeKind = 'inno' }
Assert-True ($exeP.InstallCommand -eq '"tool-setup.exe" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-' -and $exeP.UninstallCommand -like '*-File .\Uninstall.ps1' -and $exeP.NeedsUninstallScript -and $exeP.Detection.Type -eq 'Script' -and -not $exeP.ManagedOk) "Get-InstallerProposal: an Inno Setup EXE - its silent switch, an uninstall script, detection by what Windows lists"
$unkP = Get-InstallerProposal @{ Kind = 'exe'; FileName = 'Contoso_Viewer_v4.2_x64.exe'; ProductName = ''; ProductVersion = '' ; ExeKind = '' }
Assert-True ($unkP.Name -eq 'Contoso Viewer' -and $unkP.InstallCommand -eq '"Contoso_Viewer_v4.2_x64.exe"' -and @($unkP.Notes | Where-Object { $_ -like '*silent switch*' }).Count -eq 1) "Get-InstallerProposal: an unknown EXE - a name from the file, and a note to add the silent switch"
$parseErr = { param($t) $e = $null; [void][System.Management.Automation.Language.Parser]::ParseInput($t, [ref]$null, [ref]$e); @($e).Count }
Assert-Equal 0 (& $parseErr (New-InstalledAppDetectionScript -DisplayName "O'Brien Tool" -Version '2.1')) "New-InstalledAppDetectionScript: valid PowerShell, even with a quote in the name"
Assert-Equal 0 (& $parseErr (New-InstalledAppUninstallScript -DisplayName "O'Brien Tool" -ExeKind 'nsis')) "New-InstalledAppUninstallScript: valid PowerShell"
$tpl = @(Get-ScriptAppTemplates -Name "Contoso's printers" -Version '1.0')
Assert-True ($tpl.Count -eq 4 -and @($tpl | Where-Object { (& $parseErr $_.install) -or (& $parseErr $_.uninstall) -or $_.install -notmatch 'IntuneAppCatalog\\Apps' }).Count -eq 0) "Get-ScriptAppTemplates: four templates, each valid PowerShell and writing the version marker"
$mk = Get-ScriptAppMarkerRule -Name 'Contoso printers' -Version '1.0'
Assert-True ($mk.Type -eq 'Registry' -and $mk.Reg_DetectionValue -eq '1.0' -and -not (Test-VersionDetectionRule ([pscustomobject]$mk))) "Get-ScriptAppMarkerRule: a registry rule by version - managed updates can follow it"

# Conveniences: profiles, detection from an installed app, Sandbox detection, winget export lists
$profs = @(ConvertTo-AssignmentProfiles @(@{ Name = ' Standard '; Required = @('SG-A', ' SG-A ', ''); Available = @('SG-B') }, @{ Name = 'Empty'; Required = @() }, @{ Name = ''; Required = @('SG-C') }))
Assert-True ($profs.Count -eq 1 -and $profs[0].Name -eq 'Standard' -and @($profs[0].Required).Count -eq 1 -and (@($profs[0].Available) -join ',') -eq 'SG-B') "ConvertTo-AssignmentProfiles: named, with groups, each group once"
$dMsi = ConvertTo-DetectionFromInstalled @{ Key = '{1c2d3e4f-1111-2222-3333-444455556666}'; WindowsInstaller = 1; DisplayVersion = '3.2.1'; Hive = 'HKLM' }
Assert-True ($dMsi.Rule.Type -eq 'Msi' -and $dMsi.Rule.Msi_ProductCode -eq '{1C2D3E4F-1111-2222-3333-444455556666}' -and $dMsi.Rule.Msi_Version -eq '3.2.1') "ConvertTo-DetectionFromInstalled: an MSI by its product code and version"
$dFile = ConvertTo-DetectionFromInstalled @{ Key = '7-Zip'; DisplayVersion = '24.08'; Hive = 'HKLM'; MainExe = @{ Path = 'C:\Program Files\7-Zip\7zFM.exe'; Version = '24.08' } }
Assert-True ($dFile.Rule.Type -eq 'File' -and $dFile.Rule.File_Path -eq '%ProgramFiles%\7-Zip' -and $dFile.Rule.File_Name -eq '7zFM.exe' -and $dFile.Rule.File_DetectionType -eq 'version') "ConvertTo-DetectionFromInstalled: an EXE app by its program's file version, the folder as %ProgramFiles%"
$dReg = ConvertTo-DetectionFromInstalled @{ Key = 'Tool'; DisplayVersion = '1.0'; Hive = 'HKLM-WOW' }
Assert-True ($dReg.Rule.Type -eq 'Registry' -and $dReg.Rule.Reg_Check32Bit -and $dReg.Rule.Reg_ValueName -eq 'DisplayVersion' -and $dReg.Rule.Reg_DetectionType -eq 'version') "ConvertTo-DetectionFromInstalled: otherwise its Uninstall key's DisplayVersion (32-bit view)"
$probe = Join-Path ([System.IO.Path]::GetTempPath()) ("det-probe-" + [guid]::NewGuid().ToString('N') + ".txt"); Set-Content -LiteralPath $probe -Value 'x'
$fileRule = [pscustomobject]@{ Type = 'File'; File_Path = (Split-Path $probe -Parent); File_Name = (Split-Path $probe -Leaf); File_DetectionType = 'exists' }
$goneRule = [pscustomobject]@{ Type = 'File'; File_Path = (Split-Path $probe -Parent); File_Name = 'not-there-' + [guid]::NewGuid().ToString('N'); File_DetectionType = 'exists' }
Assert-True ((Invoke-Expression (ConvertTo-DetectionTestScript $fileRule)) -eq $true -and (Invoke-Expression (ConvertTo-DetectionTestScript $goneRule)) -eq $false) "ConvertTo-DetectionTestScript: a file rule finds the file that is there, and not one that isn't"
Remove-Item -LiteralPath $probe -Force
$allTypes = @([pscustomobject]@{ Type = 'Msi'; Msi_ProductCode = '{1C2D3E4F-1111-2222-3333-444455556666}'; Msi_VersionOperator = 'greaterThanOrEqual'; Msi_Version = '1.0' },
    [pscustomobject]@{ Type = 'Registry'; Reg_KeyPath = "HKEY_LOCAL_MACHINE\SOFTWARE\O'Brien"; Reg_ValueName = 'Version'; Reg_DetectionType = 'version'; Reg_Operator = 'greaterThanOrEqual'; Reg_DetectionValue = '2.0' },
    [pscustomobject]@{ Type = 'File'; File_Path = '%ProgramFiles%\X'; File_Name = 'x.exe'; File_DetectionType = 'version'; File_Operator = 'equal'; File_DetectionValue = '1.2' },
    [pscustomobject]@{ Type = 'Script'; Script_Content = "if (Test-Path 'C:\x') { Write-Output 'Installed' }" })
Assert-Equal 0 @($allTypes | Where-Object { $e = $null; [void][System.Management.Automation.Language.Parser]::ParseInput((ConvertTo-DetectionTestScript $_), [ref]$null, [ref]$e); @($e).Count }).Count "ConvertTo-DetectionTestScript: valid PowerShell for MSI, registry, file and script rules"
$exp = ConvertFrom-WingetExportJson '{"Sources":[{"Packages":[{"PackageIdentifier":"7zip.7zip"},{"PackageIdentifier":"Mozilla.Firefox"},{"PackageIdentifier":"7zip.7zip"},{"PackageIdentifier":"bad id;"}]}]}'
Assert-True (-not $exp.Error -and (@($exp.Ids) -join ',') -eq '7zip.7zip,Mozilla.Firefox') "ConvertFrom-WingetExportJson: each package once, bad IDs dropped"
Assert-True ([bool](ConvertFrom-WingetExportJson 'not json').Error) "ConvertFrom-WingetExportJson: not JSON is refused"

# Scripts built from an installer's name can't be broken out of (security review 2.12.0)
$evil = "Bob" + [char]0x2019 + "s Tool" + [char]13 + [char]10 + "Write-Output pwned; " + [char]0x2018
$lit = ConvertTo-PsLiteral $evil
$e1 = $null; [void][System.Management.Automation.Language.Parser]::ParseInput("`$x = $lit", [ref]$null, [ref]$e1)
Assert-True (@($e1).Count -eq 0 -and (Invoke-Expression $lit) -eq ("Bob" + [char]0x2019 + "s ToolWrite-Output pwned; " + [char]0x2018)) "ConvertTo-PsLiteral: typographic quotes stay text, line breaks go - the string can't be ended"
$e2 = $null; [void][System.Management.Automation.Language.Parser]::ParseInput((New-InstalledAppDetectionScript -DisplayName $evil -Version '1.0'), [ref]$null, [ref]$e2)
$e3 = $null; $un = New-InstalledAppUninstallScript -DisplayName $evil -ExeKind 'nsis'; [void][System.Management.Automation.Language.Parser]::ParseInput($un, [ref]$null, [ref]$e3)
Assert-True (@($e2).Count -eq 0 -and @($e3).Count -eq 0 -and $un -notmatch "(?m)^Write-Output pwned") "New-InstalledApp*Script: a hostile product name gives valid scripts with nothing of it run"
$tplEvil = @(Get-ScriptAppTemplates -Name $evil -Version "1.0'; Write-Output x; '")
Assert-Equal 0 @($tplEvil | Where-Object { $e = $null; [void][System.Management.Automation.Language.Parser]::ParseInput($_.install + "`n" + $_.uninstall, [ref]$null, [ref]$e); @($e).Count }).Count "Get-ScriptAppTemplates: a hostile name or version still gives valid scripts"
$pat = Get-InstalledNamePattern 'Microsoft Teams'
Assert-True ('Microsoft Teams' -match $pat -and 'Microsoft Teams 24.1 (x64)' -match $pat -and 'Microsoft Teams Meeting Add-in' -notmatch $pat -and 'Microsoft Teams classic' -notmatch $pat) "Get-InstalledNamePattern: the product, with a version or (x64) - not a sibling product"
Assert-True ('Tool [beta]' -match (Get-InstalledNamePattern 'Tool [beta]')) "Get-InstalledNamePattern: brackets in a name are matched as text"

# Microsoft Store apps, the permissions report, PSADT
Assert-True ((Test-StoreProductId '9NBLGGH4NNS1') -and (Test-StoreProductId 'XP89DCGQ3K6VLD') -and -not (Test-StoreProductId '7zip.7zip') -and -not (Test-StoreProductId '9nblggh4nns1')) "Test-StoreProductId: 9N... and XP... product IDs, not winget IDs"
$permA = @(Get-PermissionReport -Granted @('DeviceManagementApps.ReadWrite.All', 'Group.Read.All', 'Directory.ReadWrite.All', 'Mail.Send') -Usage @{ Scripts = $false; Inventory = $true; Mail = $false; GroupsPage = $true })
$st = @{}; foreach ($r in $permA) { $st[$r.name] = $r.status }
Assert-True ($st['DeviceManagementApps.ReadWrite.All'] -eq 'ok' -and $st['Group.ReadWrite.All'] -eq 'partly' -and $st['DeviceManagementManagedDevices.Read.All'] -eq 'missing' -and $st['Mail.Send'] -eq 'unused' -and $st['Directory.ReadWrite.All'] -eq 'unused' -and $st['DeviceManagementScripts.ReadWrite.All'] -eq 'optional') "Get-PermissionReport: what's there, partly there, missing, not needed and optional - by the features in use"
Assert-True (@($permA | Where-Object { $_.name -eq 'Directory.ReadWrite.All' })[0].why -like '*broad*') "Get-PermissionReport: a broad permission the app never needs is called out"
$psadtIn = "`$adtSession = @{`r`n    AppVendor = ''`r`n    AppName = ''`r`n    AppVersion = ''`r`n}`r`n    ## <Perform Post-Installation tasks here>`r`n`r`n    ## <Perform Post-Uninstallation tasks here>`r`n"
$psadt = Set-PsadtTemplateValues -Text $psadtIn -Name ("Bob" + [char]0x2019 + "s CAD") -Vendor 'Contoso' -Version '2025.1'
$pe = $null; [void][System.Management.Automation.Language.Parser]::ParseInput($psadt.Text, [ref]$null, [ref]$pe)
Assert-True (@($psadt.Missing).Count -eq 0 -and $psadt.Text -match "AppVendor = 'Contoso'" -and $psadt.Text -match "AppVersion = '2025\.1'" -and $psadt.Text -match 'Set-ItemProperty -LiteralPath' -and $psadt.Text -match 'Remove-Item -LiteralPath' -and @($pe).Count -eq 0) "Set-PsadtTemplateValues: vendor, name and version filled in, the marker after install and uninstall - still valid PowerShell"
Assert-True (@((Set-PsadtTemplateValues -Text 'nothing here' -Name 'X' -Vendor 'Y' -Version '1').Missing).Count -eq 5) "Set-PsadtTemplateValues: says what it couldn't fill in"

# A newer release of this app
$offer = Get-AppUpdateOffer -Current '2.11.0' -Tag 'v2.12.0' -Body "## Added`n- **Faster** catalog`n`n- Lock file"
Assert-True ($offer.Newer -and $offer.Version -eq '2.12.0' -and $offer.Notes -like 'Added / - Faster catalog*') "Get-AppUpdateOffer: a newer tag is offered, its notes as plain text"
Assert-True (-not (Get-AppUpdateOffer -Current '2.11.0' -Tag 'v2.11.0' -Body '').Newer -and -not (Get-AppUpdateOffer -Current '2.11.0' -Tag 'v2.9.9' -Body '').Newer) "Get-AppUpdateOffer: the same or an older release isn't"
Assert-True (-not (Get-AppUpdateOffer -Current '2.11.0' -Tag 'nightly' -Body '').Newer) "Get-AppUpdateOffer: a tag that isn't a version is ignored"

# Alerts
$rep = @{ failed = 0; planOnly = $false; items = @(@{ app = 'A'; outcome = 'current'; text = 'fine' }, @{ app = 'B'; outcome = 'hold'; text = 'too many failed' }) }
$alAtt = Get-ManagedRunAlert -Report $rep -Level 'attention'
Assert-True ($alAtt.Send -and @($alAtt.Lines).Count -eq 1 -and $alAtt.Lines[0] -like 'B - hold*' -and $alAtt.Title -like '*1 to look at*') "Get-ManagedRunAlert: 'attention' sends what needs a look, only that"
Assert-True (-not (Get-ManagedRunAlert -Report @{ failed = 0; items = @(@{ app = 'A'; outcome = 'current'; text = 'fine' }) } -Level 'attention').Send) "Get-ManagedRunAlert: nothing to look at - no alert"
Assert-True (-not (Get-ManagedRunAlert -Report $rep -Level 'off').Send -and @((Get-ManagedRunAlert -Report $rep -Level 'always').Lines).Count -eq 2) "Get-ManagedRunAlert: off sends nothing; always sends every item"
$alCfg = ConvertTo-AlertSettings ([pscustomobject]@{ Level = 'loud'; WebhookUrl = 'http://example.com/x'; MailFrom = 'reports@contoso.com'; MailTo = @('a@contoso.com', 'not an address', 'a@contoso.com') })
Assert-True ($alCfg.Level -eq 'off' -and -not $alCfg.WebhookUrl -and $alCfg.MailFrom -eq 'reports@contoso.com' -and @($alCfg.MailTo).Count -eq 1) "ConvertTo-AlertSettings: only https webhooks and real addresses are kept"

# Switching an existing app's install method
Assert-Equal 'WAU' (Get-AppWingetInstallMethod -WingetId "Vendor.App" -InstallCommand $wauDefaults.installCommand -UninstallCommand $wauDefaults.uninstallCommand) `
    "Get-AppWingetInstallMethod: recognises the Winget-AutoUpdate commands"
Assert-Equal 'Winget' (Get-AppWingetInstallMethod -WingetId "Vendor.App" -InstallCommand $userCommands.Install -UninstallCommand $userCommands.Uninstall) `
    "Get-AppWingetInstallMethod: recognises the winget commands, User context too"
Assert-Equal '' (Get-AppWingetInstallMethod -WingetId "Vendor.App" -InstallCommand ($wauDefaults.installCommand + ' -Override "/S"') -UninstallCommand $wauDefaults.uninstallCommand) `
    "Get-AppWingetInstallMethod: a command with anything added is custom"
Assert-Equal '' (Get-AppWingetInstallMethod -WingetId "Other.App" -InstallCommand $wauDefaults.installCommand -UninstallCommand $wauDefaults.uninstallCommand) `
    "Get-AppWingetInstallMethod: commands for a different Winget ID are custom"
$switched = Convert-AppWingetInstallMethod -WingetId "Vendor.App" -InstallCommand $wauDefaults.installCommand -UninstallCommand $wauDefaults.uninstallCommand -Method "Winget" -InstallContext "System"
Assert-True ($switched.Status -eq 'Switched' -and $switched.Install -eq $wingetDefaults.installCommand -and $switched.Uninstall -eq $wingetDefaults.uninstallCommand) `
    "Convert-AppWingetInstallMethod: switches WAU commands to winget"
$back = Convert-AppWingetInstallMethod -WingetId "Vendor.App" -InstallCommand $switched.Install -UninstallCommand $switched.Uninstall -Method "WAU" -InstallContext "System"
Assert-True ($back.Status -eq 'Switched' -and $back.Install -eq $wauDefaults.installCommand) `
    "Convert-AppWingetInstallMethod: and back again"
$already = Convert-AppWingetInstallMethod -WingetId "Vendor.App" -InstallCommand $wauDefaults.installCommand -UninstallCommand $wauDefaults.uninstallCommand -Method "WAU" -InstallContext "System"
Assert-Equal 'Already' $already.Status "Convert-AppWingetInstallMethod: an app already on that method is left as it is"
$custom = Convert-AppWingetInstallMethod -WingetId "Vendor.App" -InstallCommand 'setup.exe /S' -UninstallCommand 'uninst.exe /S' -Method "Winget" -InstallContext "System"
Assert-True ($custom.Status -eq 'Custom' -and $custom.Install -eq 'setup.exe /S') `
    "Convert-AppWingetInstallMethod: custom commands are kept"

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

# App version is a fact about the package, not a setting; featured is one.
$versionedMetadata = $defaultsForCompare.PSObject.Copy()
$versionedMetadata.appVersion = "24.08"
Assert-Equal $false (Test-AppHasCustomConfig -App ([pscustomobject]@{ appName = "Some Winget App"; wingetId = "some.app"; metadata = $versionedMetadata })) `
    "Test-AppHasCustomConfig: an App version alone doesn't make an app custom"
$featuredMetadata = $defaultsForCompare.PSObject.Copy()
$featuredMetadata.isFeatured = $true
Assert-Equal $true (Test-AppHasCustomConfig -App ([pscustomobject]@{ appName = "Some Winget App"; wingetId = "some.app"; metadata = $featuredMetadata })) `
    "Test-AppHasCustomConfig: being featured is a setting, so it does"

# App version / Featured app: compared once recorded, skipped while the
# catalog entry predates them ($null), so upgrading doesn't flag every app.
$unrecordedLocal = [pscustomobject]@{ description = "d"; appVersion = $null; isFeatured = $null }
$liveVersioned = [pscustomobject]@{ description = "d"; appVersion = "24.08"; isFeatured = $true }
$unrecordedDiffs = @(Get-CatalogMetadataFieldDiffs -Local $unrecordedLocal -Remote $liveVersioned | Where-Object { $_.Field -in @("App version", "Featured app") })
Assert-Equal 0 $unrecordedDiffs.Count "Get-CatalogMetadataFieldDiffs: App version/Featured app never recorded locally are not differences"
$recordedLocal = [pscustomobject]@{ description = "d"; appVersion = "23.01"; isFeatured = $false }
$recordedDiffs = @(Get-CatalogMetadataFieldDiffs -Local $recordedLocal -Remote $liveVersioned | ForEach-Object { $_.Field })
Assert-True ($recordedDiffs -contains "App version") "Get-CatalogMetadataFieldDiffs: a recorded App version that differs is flagged"
Assert-True ($recordedDiffs -contains "Featured app") "Get-CatalogMetadataFieldDiffs: a recorded Featured app that differs is flagged"
$merged = Merge-CatalogMetadata -Remote $liveVersioned -Local $recordedLocal -KeepLocalFields @("App version")
Assert-Equal "23.01" $merged.appVersion "Merge-CatalogMetadata: keeping the local App version works by its label"
Assert-Equal $true $merged.isFeatured "Merge-CatalogMetadata: ...and leaves Featured app on Intune's value"

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
# Format-GroupFieldDiffs - which side has which groups, not just which
# list differs
# -----------------------------------------------------------------
Assert-Equal "OK" (Format-GroupFieldDiffs -Diffs @()) "Format-GroupFieldDiffs: no differences reads OK"
$localOnlyApp = [pscustomobject]@{ requiredFor = @(); availableFor = @("GroupB", "GroupA"); uninstallFor = @() }
$remoteNothing = [pscustomobject]@{ RequiredGroupNames = @(); AvailableGroupNames = @(); UninstallGroupNames = @() }
Assert-Equal "1 differ: Available for - catalog: GroupA, GroupB | Intune: (none)" `
    (Format-GroupFieldDiffs -Diffs (Get-GroupFieldDiffs -LocalApp $localOnlyApp -RemoteResult $remoteNothing)) `
    "Format-GroupFieldDiffs: groups only in the catalog say Intune has none"
$remoteOnlyReq = [pscustomobject]@{ RequiredGroupNames = @("All Devices"); AvailableGroupNames = @("GroupA", "GroupB"); UninstallGroupNames = @() }
Assert-Equal "1 differ: Required for - catalog: (none) | Intune: All Devices" `
    (Format-GroupFieldDiffs -Diffs (Get-GroupFieldDiffs -LocalApp $localOnlyApp -RemoteResult $remoteOnlyReq)) `
    "Format-GroupFieldDiffs: a group only in Intune says the catalog has none"
Assert-Equal "2 differ: Required for - catalog: Old Group Name | Intune: New Group Name; Available for - catalog: (none) | Intune: X" `
    (Format-GroupFieldDiffs -Diffs @(
        [pscustomobject]@{ Field = "Required for"; Local = "Old Group Name"; Remote = "New Group Name" },
        [pscustomobject]@{ Field = "Available for"; Local = ""; Remote = "X" })) `
    "Format-GroupFieldDiffs: several lists are joined with '; '"

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
# Get-WingetIdFromInstallCommand
# -----------------------------------------------------------------
# Intune has no Winget ID field, so an imported app looked uncommon even
# when its install command plainly said which Winget package it is.
$wingetInstall = Get-CreateAppTemplates -WingetId '7zip.7zip' -Uncommon $false
Assert-Equal '7zip.7zip' (Get-WingetIdFromInstallCommand -InstallCommand $wingetInstall.Install) `
    "Get-WingetIdFromInstallCommand: reads back the ID out of this tool's OWN generated install command"
Assert-Equal '7zip.7zip' (Get-WingetIdFromInstallCommand -InstallCommand $wingetInstall.Uninstall) `
    "Get-WingetIdFromInstallCommand: ...and out of the uninstall command, -Uninstall switch and all"
Assert-Equal 'Mozilla.Firefox' (Get-WingetIdFromInstallCommand -InstallCommand "powershell.exe -File Winget-Install.ps1 -AppIDs 'Mozilla.Firefox'") `
    "Get-WingetIdFromInstallCommand: single quotes too"
Assert-Equal 'Mozilla.Firefox' (Get-WingetIdFromInstallCommand -InstallCommand "powershell.exe -File Winget-Install.ps1 -AppIDs Mozilla.Firefox") `
    "Get-WingetIdFromInstallCommand: and unquoted"
Assert-Equal 'Google.Chrome' (Get-WingetIdFromInstallCommand -InstallCommand 'winget install --id Google.Chrome -e --silent') `
    "Get-WingetIdFromInstallCommand: a plain winget command says the same thing another way"

# Quoting does not mean "all of this is the ID". A real, live command -
# the one that caught this - puts the extra arguments inside the SAME
# quoted string, and taking it whole produced a Winget ID with spaces and
# switches in it. An identifier never contains a space.
Assert-Equal 'Adobe.Acrobat.Reader.64-bit' (Get-WingetIdFromInstallCommand -InstallCommand '%SystemRoot%\sysnative\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -NoProfile -File "C:\Program Files\Winget-AutoUpdate\Winget-Install.ps1" -AppIDs "Adobe.Acrobat.Reader.64-bit --scope machine --override "') `
    "Get-WingetIdFromInstallCommand: arguments riding along inside the quotes are not part of the ID"
Assert-Equal 'Adobe.Acrobat.Reader.64-bit' (Get-WingetIdFromInstallCommand -InstallCommand '... Winget-Install.ps1 -AppIDs "Adobe.Acrobat.Reader.64-bit --scope machine"') `
    "Get-WingetIdFromInstallCommand: ...however many of them there are"
Assert-Equal 'Adobe.Acrobat.Reader.64-bit' (Get-WingetIdFromInstallCommand -InstallCommand 'winget install --id Adobe.Acrobat.Reader.64-bit --scope machine --silent') `
    "Get-WingetIdFromInstallCommand: the plain winget form stops at the ID too"
Assert-Equal '' (Get-WingetIdFromInstallCommand -InstallCommand '... Winget-Install.ps1 -AppIDs "--scope machine"') `
    "Get-WingetIdFromInstallCommand: a switch where the ID should be is not an ID"

# Where guessing would be worse than not guessing - a wrong Winget ID is
# what a later deploy would go and install.
Assert-Equal '' (Get-WingetIdFromInstallCommand -InstallCommand 'powershell.exe -File Winget-Install.ps1 -AppIDs "One.App,Two.App"') `
    "Get-WingetIdFromInstallCommand: several IDs in one command fills nothing - the catalog holds one"
Assert-Equal '' (Get-WingetIdFromInstallCommand -InstallCommand 'winget install 7zip --silent') `
    "Get-WingetIdFromInstallCommand: a bare winget search term is not an ID"
Assert-Equal '' (Get-WingetIdFromInstallCommand -InstallCommand 'setup.exe /S /NORESTART') `
    "Get-WingetIdFromInstallCommand: an ordinary installer command fills nothing"
Assert-Equal '' (Get-WingetIdFromInstallCommand -InstallCommand '') `
    "Get-WingetIdFromInstallCommand: nothing in, nothing out"
Assert-Equal '' (Get-WingetIdFromInstallCommand -InstallCommand $null) `
    "Get-WingetIdFromInstallCommand: null in, nothing out"

# The round trip that matters: what this tool generates, it can read back
# - so an app it deployed and then re-imported is recognised as its own.
foreach ($roundTripId in @('7zip.7zip', 'Microsoft.VisualStudioCode', 'Notepad++.Notepad++')) {
    $generated = Get-CreateAppTemplates -WingetId $roundTripId -Uncommon $false
    Assert-Equal $roundTripId (Get-WingetIdFromInstallCommand -InstallCommand $generated.Install) `
        "Get-WingetIdFromInstallCommand: round trips '$roundTripId' through the generated command"
}

# -----------------------------------------------------------------
# ConvertTo-CatalogMetadataFromFetch
# -----------------------------------------------------------------
# Adding an app from Intune fetches the whole app and used to store
# $null, so imported entries arrived as shells and their dependencies -
# which deploy order, the dependency overview and the audit all read -
# were lost with everything else.
$fetched = [pscustomobject]@{
    Description             = "A description"
    Publisher               = "A publisher"
    Owner                   = "An owner"
    Developer               = "A developer"
    InformationUrl          = "https://example.invalid/info"
    PrivacyInformationUrl   = "https://example.invalid/privacy"
    Notes                   = "Some notes"
    DisplayVersion          = "24.08"
    IsFeatured              = $true
    InstallCommandLine      = "setup.exe /S"
    UninstallCommandLine    = "uninstall.exe /S"
    AllowedArchitectures    = "x64"
    ApplicableArchitectures = "x86,x64"
    RunAsAccount            = "system"
    MinimumSupportedWindowsRelease = "W11_22H2"
    MinOSPropertyName       = "Windows10_1809"
    DetectionRule           = [pscustomobject]@{ Type = "File"; File_Path = "C:\App"; File_Name = "app.exe"; File_DetectionType = "exists" }
    Dependencies            = @("Base Runtime", "Shared Library")
    MinDiskSpaceMB          = 100
    MinMemoryMB             = 2048
    MinProcessors           = 2
    MinCpuSpeedMHz          = 1400
    InstallTimeMinutes      = 45
    DeviceRestartBehavior   = "basedOnReturnCode"
    AllowAvailableUninstall = $true
    ReturnCodes             = @([pscustomobject]@{ returnCode = 3010; type = "softReboot" })
}
$mapped = ConvertTo-CatalogMetadataFromFetch -Fetched $fetched
Assert-Equal "setup.exe /S" $mapped.installCommand "ConvertTo-CatalogMetadataFromFetch: the install command survives the round trip"
Assert-Equal "uninstall.exe /S" $mapped.uninstallCommand "ConvertTo-CatalogMetadataFromFetch: so does the uninstall command"
Assert-Equal "https://example.invalid/privacy" $mapped.privacyUrl "ConvertTo-CatalogMetadataFromFetch: privacyInformationUrl lands on the catalog's privacyUrl"
Assert-Equal "system" $mapped.installContext "ConvertTo-CatalogMetadataFromFetch: runAsAccount lands on installContext"
Assert-Equal "24.08" $mapped.appVersion "ConvertTo-CatalogMetadataFromFetch: displayVersion lands on appVersion"
Assert-Equal $true $mapped.isFeatured "ConvertTo-CatalogMetadataFromFetch: isFeatured comes across"
Assert-Equal 2 @($mapped.dependencies).Count "ConvertTo-CatalogMetadataFromFetch: dependencies are kept - the whole point"
Assert-True (@($mapped.dependencies) -contains "Base Runtime") "ConvertTo-CatalogMetadataFromFetch: ...by name, as the catalog stores them"
Assert-Equal "exists" $mapped.detectionRule.File_DetectionType "ConvertTo-CatalogMetadataFromFetch: the detection rule comes across whole"
Assert-Equal 3010 @($mapped.returnCodes)[0].returnCode "ConvertTo-CatalogMetadataFromFetch: return codes keep their code"
Assert-Equal "softReboot" @($mapped.returnCodes)[0].type "ConvertTo-CatalogMetadataFromFetch: ...and their type"

# Two fields where Intune offers more than one answer, and the app
# already had a settled opinion about which wins - this mapper must not
# invent a second one.
Assert-Equal "x64" $mapped.architecture "ConvertTo-CatalogMetadataFromFetch: allowed architectures win over applicable"
Assert-Equal "W11_22H2" $mapped.minOSKey "ConvertTo-CatalogMetadataFromFetch: the current Windows-release property wins over the legacy one"
$legacyOnly = $fetched.PSObject.Copy()
$legacyOnly | Add-Member -NotePropertyName MinimumSupportedWindowsRelease -NotePropertyValue $null -Force
$legacyOnly | Add-Member -NotePropertyName AllowedArchitectures -NotePropertyValue "none" -Force
$mappedLegacy = ConvertTo-CatalogMetadataFromFetch -Fetched $legacyOnly
Assert-Equal "Windows10_1809" $mappedLegacy.minOSKey "ConvertTo-CatalogMetadataFromFetch: an app never touched since the property changed falls back to the legacy one"
Assert-Equal "x86,x64" $mappedLegacy.architecture "ConvertTo-CatalogMetadataFromFetch: ...and 'none' allowed falls back to applicable"

# The shape has to match what the catalog writer expects, or the fields
# round-trip to disk as nothing. Checked against the writer itself rather
# than a list copied out of it.
$importedRecord = ConvertTo-AppRecord -Raw ([pscustomobject]@{ appName = "Imported"; appId = "id-1"; metadata = $mapped })
Assert-Equal "setup.exe /S" $importedRecord.metadata.installCommand "ConvertTo-CatalogMetadataFromFetch: the record reader keeps the install command"
Assert-Equal 2 @($importedRecord.metadata.dependencies).Count "ConvertTo-CatalogMetadataFromFetch: ...and the dependencies"

# And an app imported this way must not then report itself as differing
# from the Intune app it was just read from.
$selfDiffs = @(Get-CatalogMetadataFieldDiffs -Local $mapped -Remote $mapped -OdataType 'win32LobApp')
Assert-Equal 0 $selfDiffs.Count "ConvertTo-CatalogMetadataFromFetch: an app imported from Intune does not immediately differ from Intune"

$noneFetched = ConvertTo-CatalogMetadataFromFetch -Fetched $null
Assert-True ($null -eq $noneFetched) "ConvertTo-CatalogMetadataFromFetch: nothing fetched is nothing stored, not an empty shell"

# -----------------------------------------------------------------
# Get-ComparableDetectionRule
# -----------------------------------------------------------------
# An app deployed by this tool, audited straight afterwards, reported
# "Detection rule" differing because the catalog kept the operator and
# value boxes from before the type was switched to "exists", and
# CreateApp.ps1 never sends those two for "exists" - so Intune had no
# File_DetectionValue for the "1" sitting in the catalog. Nothing the
# user could do about it, on every audit, forever.
$fileExistsLocal = [pscustomobject]@{
    Type = "File"; File_Path = "C:\Program Files\App"; File_Name = "app.exe"
    File_Check32Bit = $false; File_DetectionType = "exists"
    File_Operator = "greaterThanOrEqual"; File_DetectionValue = "1"
}
$fileExistsLive = [pscustomobject]@{
    Type = "File"; File_Path = "C:\Program Files\App"; File_Name = "app.exe"
    File_Check32Bit = $false; File_DetectionType = "exists"
    File_Operator = $null; File_DetectionValue = $null
}
Assert-Equal (ConvertTo-DetectionRuleJson -DetectionRule (Get-ComparableDetectionRule -DetectionRule $fileExistsLocal) -IndentLevel 0) `
             (ConvertTo-DetectionRuleJson -DetectionRule (Get-ComparableDetectionRule -DetectionRule $fileExistsLive) -IndentLevel 0) `
    "Get-ComparableDetectionRule: a File/exists rule ignores the operator and value that type never sends"
Assert-Equal 0 @(Get-CatalogMetadataFieldDiffs -Local ([pscustomobject]@{ detectionRule = $fileExistsLocal }) `
                                               -Remote ([pscustomobject]@{ detectionRule = $fileExistsLive }) -OdataType 'win32LobApp').Count `
    "Get-CatalogMetadataFieldDiffs: that app reports no difference at all"

# The same fields still count for a type that DOES use them - the fix
# must not blind the check to a real detection change.
$fileVersionLocal = [pscustomobject]@{
    Type = "File"; File_Path = "C:\Program Files\App"; File_Name = "app.exe"
    File_Check32Bit = $false; File_DetectionType = "version"
    File_Operator = "greaterThanOrEqual"; File_DetectionValue = "2"
}
$fileVersionLive = $fileVersionLocal.PSObject.Copy()
$fileVersionLive | Add-Member -NotePropertyName File_DetectionValue -NotePropertyValue "1" -Force
Assert-Equal 1 @(Get-CatalogMetadataFieldDiffs -Local ([pscustomobject]@{ detectionRule = $fileVersionLocal }) `
                                               -Remote ([pscustomobject]@{ detectionRule = $fileVersionLive }) -OdataType 'win32LobApp').Count `
    "Get-ComparableDetectionRule: a File/version rule still reports a genuinely different value"

# Registry and MSI have the same shape of leftover field.
$regExistsLocal = [pscustomobject]@{
    Type = "Registry"; Reg_KeyPath = "HKLM:\SOFTWARE\App"; Reg_ValueName = "Installed"
    Reg_Check32Bit = $false; Reg_DetectionType = "exists"
    Reg_Operator = "equal"; Reg_DetectionValue = "1"
}
$regExistsLive = $regExistsLocal.PSObject.Copy()
$regExistsLive | Add-Member -NotePropertyName Reg_Operator -NotePropertyValue $null -Force
$regExistsLive | Add-Member -NotePropertyName Reg_DetectionValue -NotePropertyValue $null -Force
Assert-Equal 0 @(Get-CatalogMetadataFieldDiffs -Local ([pscustomobject]@{ detectionRule = $regExistsLocal }) `
                                               -Remote ([pscustomobject]@{ detectionRule = $regExistsLive }) -OdataType 'win32LobApp').Count `
    "Get-ComparableDetectionRule: a Registry/exists rule ignores its unused operator and value too"

$msiLocal = [pscustomobject]@{ Type = "Msi"; Msi_ProductCode = "{GUID}"; Msi_VersionOperator = "notConfigured"; Msi_Version = "1.2.3" }
$msiLive = $msiLocal.PSObject.Copy()
$msiLive | Add-Member -NotePropertyName Msi_Version -NotePropertyValue $null -Force
Assert-Equal 0 @(Get-CatalogMetadataFieldDiffs -Local ([pscustomobject]@{ detectionRule = $msiLocal }) `
                                               -Remote ([pscustomobject]@{ detectionRule = $msiLive }) -OdataType 'win32LobApp').Count `
    "Get-ComparableDetectionRule: an MSI rule with no version operator ignores the version it never sends"

# Comparison only - what gets written to the catalog keeps every field,
# so switching the type back in the editor still has the old value.
Assert-Equal "1" ([string](ConvertTo-AppRecord -Raw ([pscustomobject]@{
        appName = "X"; metadata = [pscustomobject]@{ detectionRule = $fileExistsLocal }
    })).metadata.detectionRule.File_DetectionValue) `
    "Get-ComparableDetectionRule: the stored catalog record still carries the unused value"

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

# "BadRequest (Bad Request)" says nothing; Graph's body says which property
# it disliked, and that's the whole point of reading the log.
Assert-Equal "Invalid select column: Foo" (Get-GraphErrorBodyMessage '{"error":{"code":"BadRequest","message":"Invalid select column: Foo"}}') `
    "Get-GraphErrorBodyMessage: the message out of a Graph error body"
Assert-Equal "Plain shape" (Get-GraphErrorBodyMessage '{"message":"Plain shape"}') `
    "Get-GraphErrorBodyMessage: a body that isn't wrapped in 'error'"
Assert-Equal "Not JSON at all" (Get-GraphErrorBodyMessage 'gateway said "message": "Not JSON at all" and stopped') `
    "Get-GraphErrorBodyMessage: falls back to matching text when the body isn't JSON"
Assert-Null (Get-GraphErrorBodyMessage '') "Get-GraphErrorBodyMessage: nothing to add for an empty body"
Assert-Null (Get-GraphErrorBodyMessage '<html>503</html>') "Get-GraphErrorBodyMessage: nothing to add when there's no message"
$badRequestLine = ConvertTo-GraphLogLine -Method POST -Uri "https://graph.microsoft.com/beta/deviceManagement/reports/getDeviceInstallStatusReport" `
    -Milliseconds 323 -ErrorText "Response status code does not indicate success: BadRequest (Bad Request)." `
    -Detail '{"error":{"code":"BadRequest","message":"Resource not found for the segment ''getDeviceInstallStatusReport''."}}'
# This exact line is what identified a wrong endpoint name as the cause -
# "BadRequest (Bad Request)" alone had pointed at the request body instead.
Assert-True ($badRequestLine -like "*Resource not found for the segment*") `
    "ConvertTo-GraphLogLine: a BadRequest carries Graph's own explanation" $badRequestLine

# A failure inside a runspace arrives wrapped in EndInvoke plumbing
$wrapped = New-Object System.Management.Automation.MethodInvocationException(
    'Exception calling "EndInvoke" with "1" argument(s): "Could not read the install status report"',
    (New-Object System.InvalidOperationException("Could not read the install status report")))
Assert-Equal "Could not read the install status report" (Get-InnermostErrorMessage $wrapped) `
    "Get-InnermostErrorMessage: unwraps the EndInvoke wrapper"
Assert-Equal "plain" (Get-InnermostErrorMessage (New-Object System.Exception("plain"))) `
    "Get-InnermostErrorMessage: an unwrapped exception is returned as is"
Assert-Equal "" (Get-InnermostErrorMessage $null) "Get-InnermostErrorMessage: no exception, no message"

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

# An app installed on exactly one device: the single row must stay one row.
# Assigning the value of an if statement unrolls a one-element array, which
# turned "one row of N cells" into "N rows of one cell" - so the dialog
# showed a row per column, each holding one cell of the real row.
$singleRowValues = New-Object System.Collections.Generic.List[object]
$singleRowValues.Add(@("PC-ONLY", "ada@contoso.com", "Installed"))
$singleRow = @(ConvertFrom-GraphReportTable @{
    Schema = @(@{ Column = "DeviceName" }, @{ Column = "UserPrincipalName" }, @{ Column = "InstallState" })
    Values = $singleRowValues.ToArray()
})
Assert-Equal 1 $singleRow.Count "ConvertFrom-GraphReportTable: a one-row report stays one row"
Assert-Equal "PC-ONLY" ([string]$singleRow[0]['DeviceName']) "ConvertFrom-GraphReportTable: the one row keeps its first cell"
Assert-Equal "Installed" ([string]$singleRow[0]['InstallState']) "ConvertFrom-GraphReportTable: the one row keeps its last cell"

# Paging, the fallback from beta to v1.0 and the row cap, with the Graph
# call itself faked - see Get-AppInstallStatusRows' -Invoke
$script:calls = New-Object System.Collections.Generic.List[string]
$pagingInvoke = {
    param($Uri, $Method, $Body)
    $script:calls.Add("$Method $($Uri -replace '^https://graph.microsoft.com', '') skip=$($Body.skip) top=$($Body.top) filter=$($Body.filter)")
    $names = if ($Body.skip -eq 0) { @("PC-1", "PC-2") } else { @("PC-3") }
    @{ Schema = @(@{ Column = "DeviceName" }); Values = @($names | ForEach-Object { , @($_) }) }
}
$paged = Get-AppInstallStatusRows -AppId "app-1" -Invoke $pagingInvoke -PageSize 2
Assert-Equal 3 @($paged.Rows).Count "Get-AppInstallStatusRows: keeps paging while a full page comes back"
Assert-Equal "beta" $paged.Source "Get-AppInstallStatusRows: says which version answered"
Assert-True (-not $paged.Truncated) "Get-AppInstallStatusRows: a complete result isn't truncated"
# The action is retrieveDeviceAppInstallationStatusReport. The name several
# guides give, getDeviceInstallStatusReport, is in neither beta nor v1.0 and
# answers "Resource not found for the segment" - confirmed against a tenant.
Assert-Equal "POST /beta/deviceManagement/reports/retrieveDeviceAppInstallationStatusReport skip=0 top=2 filter=(ApplicationId eq 'app-1')" $script:calls[0] `
    "Get-AppInstallStatusRows: asks the report action that actually exists"
Assert-True ($script:calls[1] -like "*skip=2 top=2*") `
    "Get-AppInstallStatusRows: the next page skips what it already has"

$cappedInvoke = {
    param($Uri, $Method, $Body)
    @{ Schema = @(@{ Column = "DeviceName" }); Values = @(1..2 | ForEach-Object { , @("PC-$_") }) }
}
$capped = Get-AppInstallStatusRows -AppId "app-1" -Invoke $cappedInvoke -PageSize 2 -MaxRows 4
Assert-Equal 4 @($capped.Rows).Count "Get-AppInstallStatusRows: stops at the row cap instead of paging forever"
Assert-True $capped.Truncated "Get-AppInstallStatusRows: says so when it stopped at the cap"

$script:fallbackCalls = New-Object System.Collections.Generic.List[string]
# One row of two cells, built through a list: written as @(, @("PC-9", ...))
# the outer @() flattens it back to two single-cell rows, which is a report
# table that says something quite different.
$script:oneRow = New-Object System.Collections.Generic.List[object]
$script:oneRow.Add(@("PC-9", -2016345308))
$fallbackInvoke = {
    param($Uri, $Method, $Body)
    $script:fallbackCalls.Add($Uri)
    if ($Uri -like '*/beta/*') { throw "Resource not found for the segment 'reports'" }
    @{ Schema = @(@{ Column = "DeviceName" }, @{ Column = "ErrorCode" }); Values = $script:oneRow.ToArray() }
}
$fallback = Get-AppInstallStatusRows -AppId "app-1" -Invoke $fallbackInvoke
Assert-Equal "v1.0" $fallback.Source "Get-AppInstallStatusRows: falls back to v1.0 when beta doesn't answer"
Assert-Equal "PC-9" @($fallback.Rows)[0].DeviceName "Get-AppInstallStatusRows: the fallback's rows are normalized the same way"
Assert-Equal "0x87D10324 (-2016345308)" @($fallback.Rows)[0].ErrorCode "Get-AppInstallStatusRows: the fallback keeps the error code"
# mobileApps/{id}/deviceStatuses is gone from mobileApp in both versions, so
# asking for it could only ever add a second, more confusing error.
Assert-True (-not (@($script:fallbackCalls) -like '*deviceStatuses*')) `
    "Get-AppInstallStatusRows: never asks for the navigation property Graph removed"

$bothFailInvoke = { param($Uri, $Method, $Body) throw "nope from $($Uri -replace '^https://graph.microsoft.com/([^/]+)/.*$', '$1')" }
$bothFailedMessage = ''
try { [void](Get-AppInstallStatusRows -AppId "app-1" -Invoke $bothFailInvoke) } catch { $bothFailedMessage = $_.Exception.Message }
Assert-True ($bothFailedMessage -like "*beta*" -and $bothFailedMessage -like "*v1.0*") `
    "Get-AppInstallStatusRows: both versions failing reports what each one said" $bothFailedMessage

# -----------------------------------------------------------------
# A local catalog of platform scripts (ScriptCatalog.ps1)
# -----------------------------------------------------------------
# The same script arrives three ways - from Graph, from the grid, from a
# file - and has to land on one shape whichever way it came.
$fromGraph = ConvertTo-ScriptRecord @{
    id = 'abc-123'; displayName = 'Set power plan'; description = 'High performance'
    fileName = 'power.ps1'; runAsAccount = 'system'; runAs32Bit = $false
    enforceSignatureCheck = $false; scriptContent = "Write-Host 'hi'"
}
Assert-Equal 'abc-123' $fromGraph.scriptId "ConvertTo-ScriptRecord: Graph's id becomes scriptId"
Assert-Equal 'system' $fromGraph.runAsAccount "ConvertTo-ScriptRecord: keeps the run-as account"
$fromGrid = ConvertTo-ScriptRecord ([pscustomobject]@{
    Id = 'abc-123'; DisplayName = 'Set power plan'; FileName = 'power.ps1'
    RunAs = 'Signed-in user'; RunAs32Bit = 'Yes'; Signature = 'Required'
})
Assert-Equal 'user' $fromGrid.runAsAccount "ConvertTo-ScriptRecord: the grid's wording maps back to Graph's"
Assert-True $fromGrid.runAs32Bit "ConvertTo-ScriptRecord: 'Yes' is true"
Assert-True $fromGrid.enforceSignatureCheck "ConvertTo-ScriptRecord: 'Required' is true"
Assert-Equal 0 (@((ConvertTo-ScriptRecord @{}).assignedGroups)).Count `
    "ConvertTo-ScriptRecord: no groups is an empty list, never null"

Assert-True (ConvertTo-ScriptBool 'True') "ConvertTo-ScriptBool: the string True"
Assert-True (ConvertTo-ScriptBool $true) "ConvertTo-ScriptBool: a real boolean"
Assert-True (-not (ConvertTo-ScriptBool 'No')) "ConvertTo-ScriptBool: No is false"
Assert-True (-not (ConvertTo-ScriptBool $null)) "ConvertTo-ScriptBool: nothing is false"

Assert-Equal "Set-power-plan" (Get-SafeFileNameForScript -Name "Set power plan") `
    "Get-SafeFileNameForScript: spaces become hyphens"
Assert-Equal "Script" (Get-SafeFileNameForScript -Name "  ") `
    "Get-SafeFileNameForScript: an unusable name still gives a file name"

# Drift: the same script, one field apart
$localScript = @{ displayName = 'Set power plan'; fileName = 'power.ps1'; runAsAccount = 'system'; scriptContent = "Write-Host 'hi'"; assignedGroups = @('SG-All') }
$remoteScript = @{ displayName = 'Set power plan'; fileName = 'power.ps1'; runAsAccount = 'user'; scriptContent = "Write-Host 'hi'"; assignedGroups = @('SG-All') }
$scriptDiffs = @(Get-ScriptFieldDiffs -Local $localScript -Remote $remoteScript)
Assert-Equal 1 $scriptDiffs.Count "Get-ScriptFieldDiffs: one field apart is one difference"
Assert-Equal 'runAsAccount' ([string]$scriptDiffs[0].Field) "Get-ScriptFieldDiffs: says which field"
# A body that only differs by line endings is not a change anyone made
$crlfDiffs = @(Get-ScriptFieldDiffs -Local @{ displayName = 'X'; scriptContent = "a`r`nb" } -Remote @{ displayName = 'X'; scriptContent = "a`nb" })
Assert-Equal 0 $crlfDiffs.Count "Get-ScriptFieldDiffs: line endings alone are not drift"
$groupDiffs = @(Get-ScriptFieldDiffs -Local @{ displayName = 'X'; assignedGroups = @('B','A') } -Remote @{ displayName = 'X'; assignedGroups = @('A','B') })
Assert-Equal 0 $groupDiffs.Count "Get-ScriptFieldDiffs: group order is not drift"
$addedGroup = @(Get-ScriptFieldDiffs -Local @{ displayName = 'X'; assignedGroups = @('A') } -Remote @{ displayName = 'X'; assignedGroups = @() })
Assert-Equal 'assignedGroups' ([string]$addedGroup[0].Field) "Get-ScriptFieldDiffs: a group only we have is drift"
Assert-Equal '(none)' ([string]$addedGroup[0].Remote) "Get-ScriptFieldDiffs: says plainly when the other side has none"

# Round trip through the folder, which is the catalog
$scriptCatalogDir = Join-Path ([IO.Path]::GetTempPath()) ("scriptcat-" + [guid]::NewGuid().ToString('N').Substring(0,8))
try {
    $saveResult = Save-ScriptsToFolder -Path $scriptCatalogDir -Scripts @(
        @{ displayName = 'Set power plan'; fileName = 'power.ps1'; runAsAccount = 'system'; scriptContent = "Write-Host 'hi'"; assignedGroups = @('SG-All') }
        @{ displayName = 'Map drives'; fileName = 'drives.ps1'; runAsAccount = 'user'; runAs32Bit = $true; scriptContent = "net use" }
    )
    Assert-Equal 2 $saveResult.Saved "Save-ScriptsToFolder: one file per script"
    Assert-Equal 0 (@($saveResult.Errors)).Count "Save-ScriptsToFolder: nothing went wrong"
    $loaded = Import-ScriptsFromFolder -Path $scriptCatalogDir
    Assert-Equal 2 (@($loaded.Scripts)).Count "Import-ScriptsFromFolder: reads them back"
    $power = @($loaded.Scripts) | Where-Object { $_.displayName -eq 'Set power plan' } | Select-Object -First 1
    Assert-Equal "Write-Host 'hi'" $power.scriptContent "Import-ScriptsFromFolder: the body survives the round trip"
    Assert-Equal 'SG-All' (@($power.assignedGroups) -join ',') "Import-ScriptsFromFolder: so do the groups"
    $drives = @($loaded.Scripts) | Where-Object { $_.displayName -eq 'Map drives' } | Select-Object -First 1
    Assert-True $drives.runAs32Bit "Import-ScriptsFromFolder: and the flags"
    Assert-Equal 0 (@(Get-ScriptFieldDiffs -Local $power -Remote $power)).Count `
        "the round trip is lossless - a saved script doesn't drift from itself"
    # Dropping one from the set removes its file: the folder is the catalog
    $second = Save-ScriptsToFolder -Path $scriptCatalogDir -Scripts @(
        @{ displayName = 'Set power plan'; fileName = 'power.ps1'; runAsAccount = 'system'; scriptContent = "Write-Host 'hi'" }
    )
    Assert-Equal 1 $second.Removed "Save-ScriptsToFolder: a script no longer in the set loses its file"
    Assert-Equal 1 (@((Import-ScriptsFromFolder -Path $scriptCatalogDir).Scripts)).Count `
        "Save-ScriptsToFolder: and is gone on the next read"
    # A broken file is named, not silently skipped
    [IO.File]::WriteAllText((Join-Path $scriptCatalogDir "broken.json"), "{ this is not json")
    $withBroken = Import-ScriptsFromFolder -Path $scriptCatalogDir
    Assert-Equal 1 (@($withBroken.Errors)).Count "Import-ScriptsFromFolder: a file that won't parse is reported"
    Assert-True ((@($withBroken.Errors) -join ' ') -like "*broken.json*") "Import-ScriptsFromFolder: and named"
}
finally { Remove-Item -LiteralPath $scriptCatalogDir -Recurse -Force -ErrorAction SilentlyContinue }
Assert-Equal 0 (@((Import-ScriptsFromFolder -Path (Join-Path ([IO.Path]::GetTempPath()) "no-such-script-folder")).Scripts)).Count `
    "Import-ScriptsFromFolder: a folder that isn't there is empty, not an error"

# -----------------------------------------------------------------
# Deleting several groups at once (Helpers.ps1)
# -----------------------------------------------------------------
# The catalog side is faked: deleting a group the catalog still assigns
# apps to breaks those assignments silently, so the plan has to find them.
$fakeUsage = { param($Name) if ($Name -eq 'Sales') { @('7-Zip', 'Notepad++') } elseif ($Name -eq 'Contractors') { @('Chrome') } else { @() } }
$plan = @(Get-GroupDeletionPlan -GroupNames @('Sales', 'Unused', 'Contractors') -UsedByLookup $fakeUsage)
Assert-Equal 3 $plan.Count "Get-GroupDeletionPlan: one row per group"
Assert-Equal "Sales" ([string]$plan[0].Name) "Get-GroupDeletionPlan: keeps the order given"
Assert-Equal 2 (@($plan[0].UsedBy).Count) "Get-GroupDeletionPlan: finds the apps using a group"
Assert-Equal 0 (@($plan[1].UsedBy).Count) "Get-GroupDeletionPlan: an unused group has no apps"
# A list of names can carry blanks and repeats; a delete must not run twice
$dedupPlan = @(Get-GroupDeletionPlan -GroupNames @('Sales', ' ', 'sales', '', 'Sales ') -UsedByLookup $fakeUsage)
Assert-Equal 1 $dedupPlan.Count "Get-GroupDeletionPlan: drops blanks and repeats, ignoring case and spacing"
Assert-Equal 0 (@(Get-GroupDeletionPlan -GroupNames @() -UsedByLookup $fakeUsage)).Count `
    "Get-GroupDeletionPlan: nothing selected, nothing planned"

$warning = Format-GroupDeletionWarning -Plan $plan
Assert-True ($warning -like "*3 group(s)*") "Format-GroupDeletionWarning: says how many will go" $warning
Assert-True ($warning -like "*can't be undone*") "Format-GroupDeletionWarning: says it can't be undone" $warning
Assert-True ($warning -like "*7-Zip*" -and $warning -like "*Chrome*") `
    "Format-GroupDeletionWarning: names the apps whose assignments break" $warning
Assert-True ($warning -notlike "*Unused -*") `
    "Format-GroupDeletionWarning: doesn't list a group nothing uses" $warning
$cleanWarning = Format-GroupDeletionWarning -Plan @(Get-GroupDeletionPlan -GroupNames @('Unused') -UsedByLookup $fakeUsage)
Assert-True ($cleanWarning -like "*No app in this catalog uses any of them*") `
    "Format-GroupDeletionWarning: says so when nothing is affected" $cleanWarning

# -----------------------------------------------------------------
# What the token is allowed to do (GraphToken.ps1)
# -----------------------------------------------------------------
# A JWT payload is base64url - base64 with two characters swapped and the
# padding left off - so decoding it needs both put back.
$claimsJson = '{"appid":"930746cc","tid":"6495c33e","roles":["Group.ReadWrite.All","DeviceManagementApps.ReadWrite.All"]}'
$claimsSegment = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($claimsJson)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
$decodedClaims = ConvertFrom-JwtPayload "header.$claimsSegment.signature"
Assert-Equal "930746cc" ([string]$decodedClaims.appid) "ConvertFrom-JwtPayload: reads the app the token was issued for"
Assert-Equal 2 (@($decodedClaims.roles).Count) "ConvertFrom-JwtPayload: reads the roles"
Assert-Null (ConvertFrom-JwtPayload "not-a-jwt") "ConvertFrom-JwtPayload: nothing from text that isn't a JWT"
Assert-Null (ConvertFrom-JwtPayload "") "ConvertFrom-JwtPayload: nothing from an empty string"
Assert-Null (ConvertFrom-JwtPayload "header.!!!not-base64!!!.sig") "ConvertFrom-JwtPayload: nothing from an unreadable payload"

# The live case this was built for: a token that looks fine until you check
# it against what the app actually uses. These are the five roles a tenant
# returned while the platform scripts kept answering Forbidden.
$liveRoles = @('Device.Read.All', 'DeviceManagementApps.ReadWrite.All', 'Directory.Read.All', 'Group.ReadWrite.All', 'User.Read.All')
$liveReport = Get-GraphRoleReport -Roles $liveRoles
$liveMissing = @($liveReport.Missing)
$liveFeatures = @($liveMissing | ForEach-Object { [string]$_.Feature })
# No scripts permission at all, so neither half of that feature works.
Assert-Equal 2 $liveMissing.Count "Get-GraphRoleReport: names the features this token can't reach"
Assert-True ($liveFeatures -contains "Platform scripts (read)") "Get-GraphRoleReport: says reading scripts is out of reach"
Assert-True ($liveFeatures -contains "Platform scripts (change)") "Get-GraphRoleReport: and says changing them is too"
Assert-True (@($liveMissing | Where-Object { $_.Required }).Count -eq 0) "Get-GraphRoleReport: platform scripts is a feature, not a blocker"

# The trap this split exists for, from a real 403: the tenant HAS
# DeviceManagementScripts.Read.All, so it can list platform scripts all
# day - and the old merged row called the whole feature available on the
# strength of it, right up until Save returned Forbidden.
$readOnlyScripts = @('DeviceManagementApps.ReadWrite.All', 'Group.ReadWrite.All', 'DeviceManagementScripts.Read.All', 'User.Read.All')
$readOnlyFeatures = @((Get-GraphRoleReport -Roles $readOnlyScripts).Missing | ForEach-Object { [string]$_.Feature })
Assert-True ($readOnlyFeatures -notcontains "Platform scripts (read)") `
    "Get-GraphRoleReport: the read-only permission is enough to LIST platform scripts"
Assert-True ($readOnlyFeatures -contains "Platform scripts (change)") `
    "Get-GraphRoleReport: but it is not enough to create or edit one" ($readOnlyFeatures -join ', ')

# Group.Read.All is the same shape: it finds a group, it cannot assign to one.
$readOnlyGroups = @((Get-GraphRoleReport -Roles @('DeviceManagementApps.ReadWrite.All', 'Group.Read.All', 'User.Read.All')).Missing | ForEach-Object { [string]$_.Feature })
Assert-True ($readOnlyGroups -notcontains "Finding groups") `
    "Get-GraphRoleReport: the read-only group permission is enough to find a group"
Assert-True ($readOnlyGroups -contains "Creating and assigning groups") `
    "Get-GraphRoleReport: but not to create one or assign an app to it" ($readOnlyGroups -join ', ')
Assert-True (@((Get-GraphRoleReport -Roles @()).Missing).Count -ge 2) `
    "Get-GraphRoleReport: a token with no roles is missing everything"

$liveLines = @(Format-GraphRoleReport -Report $liveReport -TokenAppId '930746cc' -SettingsClientId '930746cc')
Assert-True (($liveLines -join "`n") -like "*DeviceManagementScripts.Read.All or DeviceManagementScripts.ReadWrite.All*") `
    "Format-GraphRoleReport: names the permission to add" ($liveLines -join "`n")
Assert-True (-not (($liveLines -join "`n") -like "*but Settings names*")) `
    "Format-GraphRoleReport: no mismatch warning when the token is for the configured app"
# The other half of the trap: right permission, wrong registration
$otherAppLines = @(Format-GraphRoleReport -Report $liveReport -TokenAppId 'aaaa1111' -SettingsClientId '930746cc')
Assert-True (($otherAppLines -join "`n") -like "*token is for app aaaa1111*") `
    "Format-GraphRoleReport: says so when the token belongs to a different registration"
$noRoleLines = @(Format-GraphRoleReport -Report (Get-GraphRoleReport -Roles @()) -TokenAppId 'x' -SettingsClientId 'x')
Assert-True (($noRoleLines -join "`n") -like "*no application permissions at all*") `
    "Format-GraphRoleReport: says plainly when the token carries nothing"
$noRoleText = $noRoleLines -join "`n"
Assert-True ($noRoleText -like "*Application permissions (not Delegated)*" -and $noRoleText -like "*Grant admin consent*") `
    "Format-GraphRoleReport: says where to add them and to consent" $noRoleText
Assert-True ($noRoleText -like "*DeviceManagementApps.ReadWrite.All*required*" -and $noRoleText -like "*Directory.Read.All*optional*" -and $noRoleText -like "*DeviceManagementScripts.ReadWrite.All*optional*") `
    "Format-GraphRoleReport: lists each permission to add, required or optional" $noRoleText
Assert-Equal 1 ([regex]::Matches($noRoleText, '(?m)^\s+Group\.ReadWrite\.All\s').Count) `
    "Format-GraphRoleReport: a permission two features need is listed once" $noRoleText
Assert-True ($noRoleText -like "*Client ID x*") "Format-GraphRoleReport: names the registration by its Client ID"
$linkText = (Format-GraphRoleReport -Report (Get-GraphRoleReport -Roles @()) -TokenAppId 'c0ffee00-1111-4222-8333-444455556666' -SettingsClientId 'c0ffee00-1111-4222-8333-444455556666') -join "`n"
Assert-True ($linkText -like '*https://entra.microsoft.com/*/appId/c0ffee00-1111-4222-8333-444455556666/*' -and $linkText -like '*Add required permissions...*') "Format-GraphRoleReport: links straight to the registration's API permissions page, and names the button that adds them" $linkText
Assert-True ($noRoleText -notlike '*entra.microsoft.com/#view*') "Format-GraphRoleReport: no link built from a Client ID that isn't a GUID"
Assert-True (($liveLines -contains '[OK] Apps in Intune') -and (($liveLines -join "`n") -like "*DeviceManagementScripts.ReadWrite.All*optional*")) `
    "Format-GraphRoleReport: shows what works and only adds what's missing" ($liveLines -join "`n")
$allLines = @(Format-GraphRoleReport -Report (Get-GraphRoleReport -Roles @('DeviceManagementApps.ReadWrite.All', 'Group.ReadWrite.All', 'Directory.Read.All', 'DeviceManagementScripts.ReadWrite.All')) -TokenAppId 'x' -SettingsClientId 'x')
Assert-True ((($allLines -join "`n") -like "*Everything this app uses is covered*") -and -not (($allLines -join "`n") -like "*Quickest fix*")) `
    "Format-GraphRoleReport: nothing to fix, no fix instructions"

# -----------------------------------------------------------------
# Which permission a refused request needs (Helpers.ps1)
# -----------------------------------------------------------------
Assert-Equal "DeviceManagementScripts.ReadWrite.All (application)" `
    (Get-GraphPermissionHint "POST https://graph.microsoft.com/beta/deviceManagement/deviceManagementScripts failed: Forbidden") `
    "Get-GraphPermissionHint: platform scripts"
Assert-Equal "DeviceManagementApps.Read.All (application)" `
    (Get-GraphPermissionHint "POST https://graph.microsoft.com/beta/deviceManagement/reports/retrieveDeviceAppInstallationStatusReport failed") `
    "Get-GraphPermissionHint: the install status report"
Assert-Equal "DeviceManagementApps.ReadWrite.All (application)" `
    (Get-GraphPermissionHint "PATCH https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/x failed") `
    "Get-GraphPermissionHint: apps"
# What Graph itself named beats anything worked out from the address - this
# is the body a tenant actually returned for a read of the platform scripts.
# The whole chain, on the body a tenant actually returned: the refusal must
# come out naming the two scopes, not "likely missing a required permission".
$forbiddenBody = '{ "_version": 3, "Message": "Application is not authorized to perform this operation. Application must have one of the following scopes: DeviceManagementScripts.Read.All, DeviceManagementScripts.ReadWrite.All - Operation ID (for customer support): 00000000-0000-0000-0000-000000000000" }'
$forbiddenFriendly = ConvertTo-FriendlyGraphError "Response status code does not indicate success: Forbidden (Forbidden).`n$forbiddenBody"
Assert-True ($forbiddenFriendly -like "*DeviceManagementScripts.Read.All*") `
    "ConvertTo-FriendlyGraphError: a Forbidden names the scopes Graph asked for" $forbiddenFriendly
Assert-Equal $forbiddenFriendly (ConvertTo-FriendlyGraphError $forbiddenFriendly) `
    "ConvertTo-FriendlyGraphError: converting an already-converted message changes nothing"

# Through a real ErrorRecord, which is what a fetch actually hands over.
# ToString() on a record that has ErrorDetails returns the DETAILS, so
# building the message from it dropped the exception's own text and repeated
# the body - a string-only test can't catch that.
$forbiddenException = New-Object System.Exception("Response status code does not indicate success: Forbidden (Forbidden).")
$forbiddenRecord = New-Object System.Management.Automation.ErrorRecord($forbiddenException, 'GraphFail', 'NotSpecified', $null)
$forbiddenRecord.ErrorDetails = New-Object System.Management.Automation.ErrorDetails($forbiddenBody)
$recordMessage = Get-GraphErrorRecordMessage $forbiddenRecord
Assert-True ($recordMessage -like "*Forbidden (Forbidden)*") `
    "Get-GraphErrorRecordMessage: keeps the exception's own text" $recordMessage
Assert-True ($recordMessage -like "*DeviceManagementScripts.Read.All*") `
    "Get-GraphErrorRecordMessage: adds Graph's body to it" $recordMessage
Assert-Equal 1 ([regex]::Matches($recordMessage, '_version').Count) `
    "Get-GraphErrorRecordMessage: the body appears once, not twice"

# Through an actual runspace, the way every Graph fetch in this app runs.
# ErrorDetails does NOT survive that crossing - EndInvoke re-wraps the
# failure and the caller's record has none - so the body is stashed on the
# exception, which does survive. Asserting on a hand-built ErrorRecord in
# this process passed for three attempts while the real path stayed broken.
$crossingRunspace = [runspacefactory]::CreateRunspace()
$crossingRunspace.Open()
$crossingShell = [powershell]::Create()
$crossingShell.Runspace = $crossingRunspace
# no [void] in front: Windows PowerShell won't chain .AddArgument off it
$crossingShell.AddScript({
    param($Body)
    try {
        $ex = New-Object System.Exception("Response status code does not indicate success: Forbidden (Forbidden).")
        $rec = New-Object System.Management.Automation.ErrorRecord($ex, 'GraphFail', 'NotSpecified', $null)
        $rec.ErrorDetails = New-Object System.Management.Automation.ErrorDetails($Body)
        throw $rec
    }
    catch {
        $detail = [string]$_.ErrorDetails.Message
        if ($detail -and $_.Exception) { try { $_.Exception.Data['GraphBody'] = $detail } catch { } }
        throw
    }
}).AddArgument($forbiddenBody) | Out-Null
$crossingHandle = $crossingShell.BeginInvoke()
$crossedMessage = ''
try { [void]$crossingShell.EndInvoke($crossingHandle) }
catch { $crossedMessage = Get-GraphErrorRecordMessage $_ }
$crossingShell.Dispose()
$crossingRunspace.Close()
Assert-True ($crossedMessage -like "*Forbidden (Forbidden)*") `
    "Get-GraphErrorRecordMessage: a failure out of a runspace keeps its status text" $crossedMessage
Assert-True ($crossedMessage -like "*DeviceManagementScripts.Read.All*") `
    "Get-GraphErrorRecordMessage: and Graph's body, which ErrorDetails loses on the way out" $crossedMessage
Assert-True ((ConvertTo-FriendlyGraphError $crossedMessage) -like "*Add DeviceManagementScripts.Read.All*") `
    "the whole chain: a refusal crossing a runspace still names the scopes to add"

Assert-Equal "DeviceManagementScripts.Read.All or DeviceManagementScripts.ReadWrite.All (application)" `
    (Get-GraphPermissionHint 'GET https://graph.microsoft.com/beta/deviceManagement/deviceManagementScripts -> Forbidden - {"Message":"Application is not authorized to perform this operation. Application must have one of the following scopes: DeviceManagementScripts.Read.All, DeviceManagementScripts.ReadWrite.All - Operation ID"}') `
    "Get-GraphPermissionHint: prefers the scopes Graph named over the guess from the address"
Assert-Equal "Group.Read.All and Directory.Read.All (application)" `
    (Get-GraphPermissionHint "GET https://graph.microsoft.com/v1.0/groups?`$filter=... failed") `
    "Get-GraphPermissionHint: groups and users"
Assert-Null (Get-GraphPermissionHint "Something else entirely went wrong") `
    "Get-GraphPermissionHint: nothing claimed for an unrelated error"

$forbidden = ConvertTo-FriendlyGraphError "Create platform script failed: Forbidden (Forbidden)`nGraph said: {""error"":{""code"":""Forbidden""}} at https://graph.microsoft.com/beta/deviceManagement/deviceManagementScripts"
Assert-True ($forbidden -like "*DeviceManagementScripts.ReadWrite.All*") `
    "ConvertTo-FriendlyGraphError: a refused request names the permission to add"
Assert-True ($forbidden -like "*Raw error:*") `
    "ConvertTo-FriendlyGraphError: the original error text is kept underneath"
Assert-Equal "Just a plain message" (ConvertTo-FriendlyGraphError "Just a plain message") `
    "ConvertTo-FriendlyGraphError: an unrecognized error is left alone"

# -----------------------------------------------------------------
# Platform scripts (PlatformScripts.ps1)
# -----------------------------------------------------------------
Assert-Equal "V3JpdGUtSG9zdCAnaGknCg==" (ConvertTo-PlatformScriptBase64 "Write-Host 'hi'`n") `
    "ConvertTo-PlatformScriptBase64: UTF-8 base64, no BOM"
Assert-Equal "Write-Host 'hi'" (ConvertFrom-PlatformScriptBase64 (ConvertTo-PlatformScriptBase64 "Write-Host 'hi'")) `
    "ConvertFrom-PlatformScriptBase64: round-trips a script unchanged"
Assert-Equal "" (ConvertFrom-PlatformScriptBase64 "not base64 at all !!") `
    "ConvertFrom-PlatformScriptBase64: unreadable content is empty, not an error"
Assert-Equal "Set-TimeZone.ps1" (Get-PlatformScriptFileName -DisplayName "Set TimeZone" -FileName "") `
    "Get-PlatformScriptFileName: derives a file name from the script name"
Assert-Equal "my-script.ps1" (Get-PlatformScriptFileName -DisplayName "Anything" -FileName "my-script") `
    "Get-PlatformScriptFileName: adds the .ps1 extension to what was typed"
Assert-Equal "keep.me.ps1" (Get-PlatformScriptFileName -DisplayName "Anything" -FileName "keep.me.ps1") `
    "Get-PlatformScriptFileName: leaves a proper file name alone"

Assert-Equal "Enter a name for the script." (Test-PlatformScriptInput -DisplayName "  " -ScriptContent "Write-Host 1") `
    "Test-PlatformScriptInput: a script needs a name"
Assert-True ((Test-PlatformScriptInput -DisplayName "X" -ScriptContent "   ") -like "*empty*") `
    "Test-PlatformScriptInput: an empty script is refused"
Assert-True ((Test-PlatformScriptInput -DisplayName "X" -ScriptContent ("a" * 200001)) -like "*200 KB*") `
    "Test-PlatformScriptInput: a script over Intune's size limit is refused"
Assert-Null (Test-PlatformScriptInput -DisplayName "Set time zone" -ScriptContent "Set-TimeZone -Id 'W. Europe Standard Time'") `
    "Test-PlatformScriptInput: nothing wrong with a normal script"

$scriptBody = New-PlatformScriptBody -DisplayName " Set time zone " -Description "" -FileName "" `
    -ScriptContent "Set-TimeZone -Id 'W. Europe Standard Time'" -RunAsAccount 'user' -RunAs32Bit $true -EnforceSignatureCheck $false
Assert-Equal "Set time zone" $scriptBody.displayName "New-PlatformScriptBody: trims the name"
Assert-Equal "Set-time-zone.ps1" $scriptBody.fileName "New-PlatformScriptBody: fills in a file name"
Assert-Equal "user" $scriptBody.runAsAccount "New-PlatformScriptBody: keeps the run-as choice"
Assert-Equal $true $scriptBody.runAs32Bit "New-PlatformScriptBody: keeps the 32-bit choice"
Assert-Equal "#microsoft.graph.deviceManagementScript" $scriptBody.'@odata.type' "New-PlatformScriptBody: the type Graph expects"
Assert-Equal "Set-TimeZone -Id 'W. Europe Standard Time'" (ConvertFrom-PlatformScriptBase64 $scriptBody.scriptContent) `
    "New-PlatformScriptBody: the script itself survives the round trip"

$assignBody = New-PlatformScriptAssignBody -GroupIds @("11111111-1111-1111-1111-111111111111", "11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222")
Assert-Equal 2 @($assignBody.deviceManagementScriptAssignments).Count "New-PlatformScriptAssignBody: the same group twice is one assignment"
Assert-Equal "#microsoft.graph.groupAssignmentTarget" @($assignBody.deviceManagementScriptAssignments)[0].target.'@odata.type' `
    "New-PlatformScriptAssignBody: assigns to a group target"
Assert-Equal 0 @((New-PlatformScriptAssignBody -GroupIds @()).deviceManagementScriptAssignments).Count `
    "New-PlatformScriptAssignBody: no groups is an empty list, which clears the assignments"

$listed = ConvertTo-PlatformScriptRow @{ id = "s1"; displayName = "Set time zone"; fileName = "tz.ps1"; runAsAccount = "user"; runAs32Bit = $true; enforceSignatureCheck = $false; lastModifiedDateTime = "2026-09-17 08:14:00" }
Assert-Equal "Signed-in user" $listed.RunAs "ConvertTo-PlatformScriptRow: says who the script runs as in words"
Assert-Equal "Yes" $listed.RunAs32Bit "ConvertTo-PlatformScriptRow: 32-bit as Yes/No"
Assert-Equal "Not required" $listed.Signature "ConvertTo-PlatformScriptRow: signature check in words"
Assert-Equal "2026-09-17 08:14" $listed.Modified "ConvertTo-PlatformScriptRow: shortens the timestamp"
Assert-Equal "System" (ConvertTo-PlatformScriptRow @{ runAsAccount = "system" }).RunAs "ConvertTo-PlatformScriptRow: the system account"

$assignments = @(
    @{ target = @{ groupId = "g1" } },
    @{ target = @{ groupId = "g2" } },
    @{ target = @{ '@odata.type' = '#microsoft.graph.allDevicesAssignmentTarget' } }
)
$knownNames = @{ "g1" = "SG-Intune-AllDevices" }
$assignedNames = @(Get-PlatformScriptGroupNames -Assignments $assignments -GroupNamesById $knownNames)
Assert-Equal "SG-Intune-AllDevices" $assignedNames[0] "Get-PlatformScriptGroupNames: uses the group name when it's known"
Assert-Equal "g2" $assignedNames[1] "Get-PlatformScriptGroupNames: an unknown group keeps its id rather than disappearing"
Assert-Equal 2 $assignedNames.Count "Get-PlatformScriptGroupNames: a non-group target is skipped"

$runState = ConvertTo-ScriptRunStateRow @{
    runState = 'fail'; errorCode = -2147024894; errorDescription = 'The system cannot find the file specified'
    resultMessage = 'Set-TimeZone : not recognized'; lastStateUpdateDateTime = '2026-09-17 06:32:00'
    managedDevice = @{ deviceName = 'HR-PC-0110'; userPrincipalName = 'chiara.rossi@contoso.com' }
}
Assert-Equal "HR-PC-0110" $runState.DeviceName "ConvertTo-ScriptRunStateRow: the expanded device's name"
Assert-Equal "Failed" $runState.State "ConvertTo-ScriptRunStateRow: Intune's runState in plain words"
Assert-Equal "The system cannot find the file specified" $runState.ErrorText "ConvertTo-ScriptRunStateRow: prefers Intune's own error text"
Assert-Equal "2026-09-17 06:32" $runState.LastRun "ConvertTo-ScriptRunStateRow: shortened timestamp"
$noDevice = ConvertTo-ScriptRunStateRow @{ runState = 'success'; managedDeviceId = 'abc-123' }
Assert-Equal "abc-123" $noDevice.DeviceName "ConvertTo-ScriptRunStateRow: falls back to the device id when it wasn't expanded"
Assert-Equal "Success" $noDevice.State "ConvertTo-ScriptRunStateRow: success"
Assert-Equal "0x8007002E (-2147024850)" (ConvertTo-ScriptRunStateRow @{ runState = 'fail'; errorCode = -2147024850 }).ErrorText `
    "ConvertTo-ScriptRunStateRow: without error text it shows the code"

Assert-Equal "Intune hasn't reported a run of this script yet." (Format-ScriptRunSummary @()) "Format-ScriptRunSummary: nothing reported yet"
Assert-Equal "2 devices: 1 Failed, 1 Success" (Format-ScriptRunSummary @($runState, $noDevice)) "Format-ScriptRunSummary: counts the states"

# Intune stores "install time required" in steps of 5 (verified live: 61 comes back as 60)
Assert-Equal 60 (Get-NormalizedInstallTimeMinutes 60) "Get-NormalizedInstallTimeMinutes: a multiple of 5 is left alone"
Assert-Equal 60 (Get-NormalizedInstallTimeMinutes 61) "Get-NormalizedInstallTimeMinutes: 61 becomes 60, which is what Intune keeps"
Assert-Equal 65 (Get-NormalizedInstallTimeMinutes 64) "Get-NormalizedInstallTimeMinutes: rounds to the nearest step, not always down"
Assert-Equal 65 (Get-NormalizedInstallTimeMinutes 65) "Get-NormalizedInstallTimeMinutes: 65 is already a step"
Assert-Equal 5 (Get-NormalizedInstallTimeMinutes 1) "Get-NormalizedInstallTimeMinutes: never below one step"
Assert-Equal 5 (Get-NormalizedInstallTimeMinutes 0) "Get-NormalizedInstallTimeMinutes: 0 would mean give up at once"
Assert-Equal 1440 (Get-NormalizedInstallTimeMinutes 5000) "Get-NormalizedInstallTimeMinutes: capped at Intune's maximum of a day"
Assert-Null (Get-NormalizedInstallTimeMinutes "not a number") "Get-NormalizedInstallTimeMinutes: nothing to normalize"

$templateSource = [pscustomobject]@{
    appId = '3f1c2a9e-5b7d-4e21-9a0c-8d6e4b1f2a37'; appName = '7-Zip'; wingetId = '7zip.7zip'
    intuneAppType = 'Windows app (Win32)'; intuneAppVersion = '24.08'
    requiredFor = @('SG-All'); availableFor = @(); uninstallFor = @(); excludeFor = @('SG-Contractors')
    metadata = [pscustomobject]@{ publisher = 'Igor Pavlov' }
}
$template = ConvertTo-TemplateAppRecord -App $templateSource
Assert-Equal "" $template.appId "ConvertTo-TemplateAppRecord: the App ID goes"
Assert-Equal "" $template.intuneAppType "ConvertTo-TemplateAppRecord: Intune's reported type goes"
Assert-Equal "" $template.intuneAppVersion "ConvertTo-TemplateAppRecord: Intune's reported version goes"
Assert-Equal "7-Zip" $template.appName "ConvertTo-TemplateAppRecord: the name stays"
Assert-Equal "7zip.7zip" $template.wingetId "ConvertTo-TemplateAppRecord: the Winget ID stays"
Assert-Equal "SG-All" (@($template.requiredFor) -join ',') "ConvertTo-TemplateAppRecord: groups stay"
Assert-Equal "SG-Contractors" (@($template.excludeFor) -join ',') "ConvertTo-TemplateAppRecord: exclusions stay"
Assert-Equal "Igor Pavlov" $template.metadata.publisher "ConvertTo-TemplateAppRecord: the metadata stays"
Assert-Equal '3f1c2a9e-5b7d-4e21-9a0c-8d6e4b1f2a37' $templateSource.appId "ConvertTo-TemplateAppRecord: the app it came from is untouched"
$templateWithPackage = ConvertTo-TemplateAppRecord -App ([pscustomobject]@{ appName = 'Tool'; packagePath = '\\share\pkg\tool.intunewin'; requiredFor = @(); availableFor = @(); uninstallFor = @(); excludeFor = @() })
Assert-Equal '\\share\pkg\tool.intunewin' $templateWithPackage.packagePath "ConvertTo-TemplateAppRecord: the package path stays - it isn't tied to a tenant"


# -----------------------------------------------------------------
# Assignments, including exclusions (Assignments.ps1)
# -----------------------------------------------------------------
$desired = @(Get-DesiredAssignmentEntries -RequiredGroups @('SG-All') -AvailableGroups @('SG-Pilot') -ExcludeGroups @('SG-Contractors'))
Assert-Equal 4 $desired.Count "Get-DesiredAssignmentEntries: an exclusion is added to every intent the app uses"
Assert-True (@($desired | Where-Object { $_.Key -eq 'required|include|SG-All' }).Count -eq 1) "Get-DesiredAssignmentEntries: the required group"
Assert-True (@($desired | Where-Object { $_.Key -eq 'available|exclude|SG-Contractors' }).Count -eq 1) "Get-DesiredAssignmentEntries: excluded from available too"
Assert-Equal 0 @(Get-DesiredAssignmentEntries -ExcludeGroups @('SG-Contractors')).Count `
    "Get-DesiredAssignmentEntries: an exclusion alone means nothing - no intent uses it"
$bothWays = @(Get-DesiredAssignmentEntries -RequiredGroups @('SG-All', 'SG-Contractors') -ExcludeGroups @('SG-Contractors'))
Assert-True (@($bothWays | Where-Object { $_.Key -eq 'required|include|SG-Contractors' }).Count -eq 0) `
    "Get-DesiredAssignmentEntries: a group both included and excluded is only excluded"
Assert-Equal 2 @(Get-DesiredAssignmentEntries -RequiredGroups @(' SG-All ', 'SG-All', $null, '') -AvailableGroups @('SG-Pilot')).Count `
    "Get-DesiredAssignmentEntries: blanks dropped, duplicates and stray spaces collapsed"

$otherTargets = @()
$currentEntries = @(ConvertTo-CurrentAssignmentEntries -Assignments @(
    @{ intent = 'required'; target = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = 'g1' } },
    @{ intent = 'required'; target = @{ '@odata.type' = '#microsoft.graph.exclusionGroupAssignmentTarget'; groupId = 'g2' } },
    @{ intent = 'available'; target = @{ '@odata.type' = '#microsoft.graph.allDevicesAssignmentTarget' } }
) -GroupNameById @{ 'g1' = 'SG-All'; 'g2' = 'SG-Contractors' } -OtherTargets ([ref]$otherTargets))
Assert-Equal 2 $currentEntries.Count "ConvertTo-CurrentAssignmentEntries: group targets only"
Assert-Equal "required|exclude|SG-Contractors" $currentEntries[1].Key "ConvertTo-CurrentAssignmentEntries: an exclusion target is read as an exclusion"
Assert-Equal 1 $otherTargets.Count "ConvertTo-CurrentAssignmentEntries: All devices is reported separately, not dropped silently"
Assert-Equal "g9" (ConvertTo-CurrentAssignmentEntries -Assignments @(@{ intent = 'required'; target = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = 'g9' } }) -GroupNameById @{})[0].Group `
    "ConvertTo-CurrentAssignmentEntries: an unknown group keeps its id"

$noChange = Get-AssignmentDiff -Current $currentEntries -Desired @(Get-DesiredAssignmentEntries -RequiredGroups @('SG-All') -ExcludeGroups @('SG-Contractors'))
Assert-Equal 0 @($noChange.ToAdd).Count "Get-AssignmentDiff: nothing to add when Intune already matches"
Assert-Equal 0 @($noChange.ToRemove).Count "Get-AssignmentDiff: nothing to remove when Intune already matches"
$movedIntent = Get-AssignmentDiff -Current $currentEntries -Desired @(Get-DesiredAssignmentEntries -AvailableGroups @('SG-All') -ExcludeGroups @('SG-Contractors'))
Assert-True (@($movedIntent.ToAdd) -contains "[available] SG-All") "Get-AssignmentDiff: moving a group to another intent is an add"
Assert-True (@($movedIntent.ToRemove) -contains "[required] SG-All") "Get-AssignmentDiff: ...and a remove of the old intent"
Assert-True (@($movedIntent.ToRemove) -contains "[required] EXCLUDE SG-Contractors") "Get-AssignmentDiff: an exclusion under a no-longer-used intent goes too"

$body = New-AppAssignmentBody -Entries @(Get-DesiredAssignmentEntries -RequiredGroups @('SG-All') -ExcludeGroups @('SG-Contractors')) -GroupIdByName @{ 'SG-All' = 'id-1'; 'SG-Contractors' = 'id-2' }
Assert-Equal 2 @($body.mobileAppAssignments).Count "New-AppAssignmentBody: one entry per assignment"
Assert-Equal "#microsoft.graph.exclusionGroupAssignmentTarget" (@($body.mobileAppAssignments) | Where-Object { $_.target.groupId -eq 'id-2' }).target.'@odata.type' `
    "New-AppAssignmentBody: the excluded group gets an exclusion target"
Assert-Equal 1 @((New-AppAssignmentBody -Entries @(Get-DesiredAssignmentEntries -RequiredGroups @('SG-All', 'SG-Unknown')) -GroupIdByName @{ 'SG-All' = 'id-1' }).mobileAppAssignments).Count `
    "New-AppAssignmentBody: a group with no id yet is skipped rather than sent empty"

# An app with nothing on one side of the comparison - no assignments in
# Intune yet, or no groups in the catalog. Both are ordinary states, and
# both used to end the whole multi-app preview with "Index operation
# failed; the array index evaluated to null": these producers returned an
# empty array, PowerShell unrolled it to $null on the way out, and
# Get-AssignmentDiff's "@($null)" is an array holding one $null whose
# .Key is $null - which is not a legal hashtable key.
$emptyCurrent = ConvertTo-CurrentAssignmentEntries -Assignments @() -GroupNameById @{}
$emptyDesired = Get-DesiredAssignmentEntries
# Pinned, because it is the whole premise of the guard being tested and it
# reads like a bug until you know it is how PowerShell returns an empty
# array. If either of these ever stops being $null, the guard is still
# correct - but these two assertions are what says so on purpose.
Assert-True ($null -eq $emptyCurrent) "ConvertTo-CurrentAssignmentEntries: an empty result reaches the caller as null"
Assert-True ($null -eq $emptyDesired) "Get-DesiredAssignmentEntries: an empty result reaches the caller as null"

$firstPush = Get-AssignmentDiff -Current $emptyCurrent -Desired (Get-DesiredAssignmentEntries -RequiredGroups @('SG-All'))
Assert-Equal 1 @($firstPush.ToAdd).Count "Get-AssignmentDiff: an app with no assignments in Intune yet is all adds"
Assert-Equal 0 @($firstPush.ToRemove).Count "Get-AssignmentDiff: ...and nothing to remove"
$strippedAll = Get-AssignmentDiff -Current (Get-DesiredAssignmentEntries -RequiredGroups @('SG-All')) -Desired $emptyDesired
Assert-Equal 1 @($strippedAll.ToRemove).Count "Get-AssignmentDiff: an app with no groups in the catalog removes what Intune has"
Assert-Equal 0 @($strippedAll.ToAdd).Count "Get-AssignmentDiff: ...and adds nothing"

# Straight $null, and a set with a $null in it - what the embedded scripts
# can be handed, since these functions travel to them as text and their
# input comes back through a JSON config rather than from the code above.
$bothNull = Get-AssignmentDiff -Current $null -Desired $null
Assert-Equal 0 @($bothNull.ToAdd).Count "Get-AssignmentDiff: null on both sides is no change, not a crash"
Assert-Equal 0 @($bothNull.ToRemove).Count "Get-AssignmentDiff: ...on the remove side too"
$withHole = Get-AssignmentDiff -Current @($null) -Desired @(@(Get-DesiredAssignmentEntries -RequiredGroups @('SG-All'))[0], $null)
Assert-Equal 1 @($withHole.ToAdd).Count "Get-AssignmentDiff: a null among real entries is dropped, not indexed"
Assert-Equal 0 @($withHole.ToRemove).Count "Get-AssignmentDiff: a null-only current side removes nothing"
Assert-Equal 0 @((New-AppAssignmentBody -Entries @($null) -GroupIdByName @{ 'SG-All' = 'id-1' }).mobileAppAssignments).Count `
    "New-AppAssignmentBody: a null entry is skipped rather than throwing on a null lookup"

# -----------------------------------------------------------------
# Resolve-AppPackagePath / Get-PackageFolderIndex
# -----------------------------------------------------------------
# Against a real folder tree, because every branch of this resolver is
# about what is actually on disk. Each case is asserted twice - resolved
# fresh, and resolved through a prebuilt index - because the catalog list
# passes an index and the two must not be able to disagree.
$pkgTestRoot = Join-Path ([IO.Path]::GetTempPath()) ("pkgidx-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$savedRootPath = $Global:App.RootPath
$savedAppFolders = $Global:App.AppFolders
try {
    $pkgDir = Join-Path $pkgTestRoot 'pkgs'
    $Global:App.RootPath = $pkgTestRoot
    $Global:App.AppFolders = @{ Packages = $pkgDir }

    # named after the app, in its own folder - the normal case
    [void](New-Item -ItemType Directory -Path (Join-Path $pkgDir 'Seven-Zip') -Force)
    Set-Content -LiteralPath (Join-Path $pkgDir 'Seven-Zip\Seven-Zip.intunewin') -Value 'x'
    # named after the app but nested somewhere unexpected
    [void](New-Item -ItemType Directory -Path (Join-Path $pkgDir 'odd\deeper') -Force)
    Set-Content -LiteralPath (Join-Path $pkgDir 'odd\deeper\Nested-App.intunewin') -Value 'x'
    # right folder, different file name, exactly one file - packaged by
    # something that kept the source installer's own name
    [void](New-Item -ItemType Directory -Path (Join-Path $pkgDir 'Contoso-Client') -Force)
    Set-Content -LiteralPath (Join-Path $pkgDir 'Contoso-Client\OriginalInstaller.intunewin') -Value 'x'
    # right folder, two files - ambiguous, must not guess
    [void](New-Item -ItemType Directory -Path (Join-Path $pkgDir 'Two-Files') -Force)
    Set-Content -LiteralPath (Join-Path $pkgDir 'Two-Files\a.intunewin') -Value 'x'
    Set-Content -LiteralPath (Join-Path $pkgDir 'Two-Files\b.intunewin') -Value 'x'

    $prebuiltIndex = Get-PackageFolderIndex -Root $pkgDir
    # Five files across four folders - Two-Files contributes both of its.
    Assert-Equal 5 $prebuiltIndex.ByName.Count "Get-PackageFolderIndex: every .intunewin under the folder, once"
    Assert-Equal 4 $prebuiltIndex.ByFolder.Count "Get-PackageFolderIndex: and every folder that holds one"
    foreach ($mode in @('fresh', 'indexed')) {
        $useIndex = if ($mode -eq 'indexed') { $prebuiltIndex } else { $null }
        Assert-True (Resolve-AppPackagePath -AppName 'Seven Zip' -Uncommon $true -Index $useIndex).Found `
            "Resolve-AppPackagePath ($mode): finds a package named after its app"
        Assert-True (Resolve-AppPackagePath -AppName 'Nested App' -Uncommon $true -Index $useIndex).Found `
            "Resolve-AppPackagePath ($mode): finds it however deeply it is nested"
        Assert-True (Resolve-AppPackagePath -AppName 'Contoso Client' -Uncommon $true -Index $useIndex).Found `
            "Resolve-AppPackagePath ($mode): the app's own folder holding one package is that package, whatever it is called"
        Assert-True (-not (Resolve-AppPackagePath -AppName 'Two Files' -Uncommon $true -Index $useIndex).Found) `
            "Resolve-AppPackagePath ($mode): two packages in the folder is ambiguous, not a guess"
        Assert-True (-not (Resolve-AppPackagePath -AppName 'Absent App' -Uncommon $true -Index $useIndex).Found) `
            "Resolve-AppPackagePath ($mode): says so when there is nothing there"
        Assert-True (Resolve-AppPackagePath -AppName 'seven zip' -Uncommon $true -Index $useIndex).Found `
            "Resolve-AppPackagePath ($mode): matches case-insensitively, as the -Filter it replaced did"
    }

    # A stored -PackagePath beats all of the guessing above, because
    # somebody pointed at it deliberately.
    $explicitFile = Join-Path $pkgDir 'odd\deeper\Nested-App.intunewin'
    $byFile = Resolve-AppPackagePath -AppName 'Seven Zip' -Uncommon $true -PackagePath $explicitFile
    Assert-True $byFile.Found "Resolve-AppPackagePath: a stored file path is used as given"
    Assert-Equal $explicitFile $byFile.Path "Resolve-AppPackagePath: and it is that exact file, not the one matching the name"

    $byFolder = Resolve-AppPackagePath -AppName 'Whatever' -Uncommon $true -PackagePath (Join-Path $pkgDir 'Contoso-Client')
    Assert-True $byFolder.Found "Resolve-AppPackagePath: a stored folder holding one package resolves to it"

    $ambiguousFolder = Resolve-AppPackagePath -AppName 'Whatever' -Uncommon $true -PackagePath (Join-Path $pkgDir 'Two-Files')
    Assert-True (-not $ambiguousFolder.Found) "Resolve-AppPackagePath: a stored folder with two packages is still ambiguous"

    # The important one: a path that has gone must NOT quietly fall back
    # to a name match, or the app would deploy a different package than
    # the one it was told to.
    $goneOverride = Resolve-AppPackagePath -AppName 'Seven Zip' -Uncommon $true -PackagePath (Join-Path $pkgDir 'no\such\file.intunewin')
    Assert-True (-not $goneOverride.Found) "Resolve-AppPackagePath: a stored path that no longer exists is not found..."
    Assert-True ($goneOverride.Path -notlike '*Seven-Zip.intunewin') "Resolve-AppPackagePath: ...and does not silently fall back to the name match"

    Assert-True (Resolve-AppPackagePath -AppName 'Seven Zip' -Uncommon $true -PackagePath '   ').Found `
        "Resolve-AppPackagePath: a blank override means 'work it out', not 'nothing'"

    # It has to survive being written and read back. ConvertTo-SingleAppJson
    # builds its JSON field by field rather than serialising the object, so
    # a field nobody adds there is read, held in memory, shown in the
    # editor - and dropped silently the moment the catalog is saved. Which
    # is exactly what happened.
    $roundTripApp = [pscustomobject]@{
        appId = ''; appName = 'Round Trip'; wingetId = 'Some.Winget.Id'
        intuneAppType = ''; intuneAppVersion = ''
        requiredFor = @(); availableFor = @(); uninstallFor = @(); excludeFor = @()
        metadata = $null
        packagePath = 'D:\somewhere\else\Round-Trip.intunewin'
    }
    $roundTripJson = ConvertTo-SingleAppJson -App $roundTripApp
    Assert-True ($roundTripJson -like '*packagePath*') "ConvertTo-SingleAppJson: writes packagePath when it is set"
    $readBack = ConvertTo-AppRecord -Raw ($roundTripJson | ConvertFrom-Json)
    Assert-Equal 'D:\somewhere\else\Round-Trip.intunewin' $readBack.packagePath `
        "ConvertTo-AppRecord: and reads back the same path - a Winget ID does not discard it"

    # ...and an app without one must not grow an empty key.
    $plainApp = [pscustomobject]@{
        appId = ''; appName = 'Plain'; wingetId = 'x.y'
        intuneAppType = ''; intuneAppVersion = ''
        requiredFor = @(); availableFor = @(); uninstallFor = @(); excludeFor = @()
        metadata = $null; packagePath = ''
    }
    Assert-True ((ConvertTo-SingleAppJson -App $plainApp) -notlike '*packagePath*') `
        "ConvertTo-SingleAppJson: leaves packagePath out entirely when unset"

    # App version and Featured app round-trip, and "never recorded" stays
    # null rather than turning into "" / false on the way through.
    $metaRoundTrip = [pscustomobject]@{
        appId = ''; appName = 'Meta Trip'; wingetId = 'x.y'
        intuneAppType = ''; intuneAppVersion = ''
        requiredFor = @(); availableFor = @(); uninstallFor = @(); excludeFor = @()
        metadata = [pscustomobject]@{ description = 'd'; appVersion = '1.2.3'; isFeatured = $true }
    }
    $metaBack = ConvertTo-AppRecord -Raw ((ConvertTo-SingleAppJson -App $metaRoundTrip) | ConvertFrom-Json)
    Assert-Equal '1.2.3' $metaBack.metadata.appVersion "ConvertTo-SingleAppJson/ConvertTo-AppRecord: App version round-trips"
    Assert-Equal $true $metaBack.metadata.isFeatured "ConvertTo-SingleAppJson/ConvertTo-AppRecord: Featured app round-trips"
    $png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=='
    $iconApp = ConvertTo-AppRecord -Raw ([pscustomobject]@{ appName = 'Icon App'; icon = [pscustomobject]@{ type = 'image/png'; value = $png } })
    $iconBack = ConvertTo-AppRecord -Raw ((ConvertTo-SingleAppJson -App $iconApp) | ConvertFrom-Json)
    Assert-Equal $png $iconBack.icon.value "ConvertTo-SingleAppJson/ConvertTo-AppRecord: the icon round-trips"
    Assert-True ($null -eq (ConvertTo-AppIcon ([pscustomobject]@{ type = 'image/svg+xml'; value = $png }))) "ConvertTo-AppIcon: only PNG or JPEG"
    Assert-True ($null -eq (ConvertTo-AppIcon ([pscustomobject]@{ type = 'image/png'; value = 'not base64!' }))) "ConvertTo-AppIcon: only base64"
    Assert-True ((ConvertTo-SingleAppJson -App $metaBack) -notlike '*"icon"*') "ConvertTo-SingleAppJson: no icon field when there is none"
    $noSup = ConvertTo-AppRecord -Raw ([pscustomobject]@{ appName = 'No Sup'; metadata = [pscustomobject]@{ description = 'x'; supersedes = @() } })
    Assert-True ($null -ne $noSup.metadata.supersedes -and @($noSup.metadata.supersedes).Count -eq 0) "ConvertTo-AppRecord: an empty supersedence list stays empty (supersedes nothing), not null (leave Intune's)"
    $noSupBack = ConvertTo-AppRecord -Raw ((ConvertTo-SingleAppJson -App $noSup) | ConvertFrom-Json)
    Assert-True ($null -ne $noSupBack.metadata.supersedes) "ConvertTo-SingleAppJson/ConvertTo-AppRecord: an empty supersedence list round-trips"
    $metaRoundTrip.metadata = [pscustomobject]@{ description = 'd'; appVersion = $null; isFeatured = $null }
    $metaNullBack = ConvertTo-AppRecord -Raw ((ConvertTo-SingleAppJson -App $metaRoundTrip) | ConvertFrom-Json)
    Assert-Null $metaNullBack.metadata.appVersion "ConvertTo-AppRecord: an unrecorded App version stays null through a save"
    Assert-Null $metaNullBack.metadata.isFeatured "ConvertTo-AppRecord: an unrecorded Featured app stays null through a save"
    $olderFile = ConvertTo-AppRecord -Raw ([pscustomobject]@{ appName = 'Old'; metadata = [pscustomobject]@{ description = 'd' } })
    Assert-Null $olderFile.metadata.appVersion "ConvertTo-AppRecord: a file from before App version reads it as null, not blank"
}
finally {
    $Global:App.RootPath = $savedRootPath
    $Global:App.AppFolders = $savedAppFolders
    Remove-Item -LiteralPath $pkgTestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# -----------------------------------------------------------------
# Save-ScriptsToFolder pruning
# -----------------------------------------------------------------
# The folder IS the script catalog, so a save removes files for scripts
# that are no longer in the tenant. That is right when the caller read
# the tenant successfully. It is destructive when the caller did NOT:
# an empty set then means "delete everything you have", and one failed
# read would take a local copy with it.
$scriptFolder = Join-Path ([IO.Path]::GetTempPath()) ("scriptcat-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
try {
    [void](New-Item -ItemType Directory -Path $scriptFolder -Force)
    $existing = Join-Path $scriptFolder 'Already-Here.json'
    Set-Content -LiteralPath $existing -Value '{}' -Encoding UTF8

    # Normal case: this set is the tenant, so what is not in it goes.
    $pruned = Save-ScriptsToFolder -Path $scriptFolder -Scripts @(@{ displayName = 'Kept One'; scriptContent = 'x' })
    Assert-Equal 1 $pruned.Saved "Save-ScriptsToFolder: writes the script it was given"
    Assert-Equal 1 $pruned.Removed "Save-ScriptsToFolder: and removes one the tenant no longer has"
    Assert-True (-not (Test-Path -LiteralPath $existing)) "Save-ScriptsToFolder: the stale file really is gone"

    # The dangerous case: reads failed, so the set is not the tenant.
    $kept = Join-Path $scriptFolder 'Kept-One.json'
    Assert-True (Test-Path -LiteralPath $kept) "Save-ScriptsToFolder: (the written file is there to be kept)"
    $notPruned = Save-ScriptsToFolder -Path $scriptFolder -Scripts @() -NoPrune
    Assert-Equal 0 $notPruned.Removed "Save-ScriptsToFolder -NoPrune: removes nothing when the caller could not read the tenant"
    Assert-True (Test-Path -LiteralPath $kept) "Save-ScriptsToFolder -NoPrune: an existing local copy survives a failed run"

    # ...and without the switch, an empty set really would empty the folder,
    # which is exactly why the caller has to decide.
    $emptied = Save-ScriptsToFolder -Path $scriptFolder -Scripts @()
    Assert-Equal 1 $emptied.Removed "Save-ScriptsToFolder: an empty set still prunes when pruning was asked for"

    # A List[object], which is what the real caller passes - and what the
    # tests above did NOT, which is why they passed while the app threw.
    # @($list) on a generic list holding hashtables raises "Argument types
    # do not match"; nothing caught it, so it escaped the timer driving
    # the save and left the dialog stuck mid-sentence.
    $listOfScripts = New-Object System.Collections.Generic.List[object]
    [void]$listOfScripts.Add(@{ displayName = 'From A List'; scriptContent = 'x' })
    $threwOnList = $false
    $listResult = $null
    try { $listResult = Save-ScriptsToFolder -Path $scriptFolder -Scripts $listOfScripts -NoPrune }
    catch { $threwOnList = $true }
    Assert-True (-not $threwOnList) "Save-ScriptsToFolder: takes a List[object], which is what its caller actually hands it"
    Assert-Equal 1 $listResult.Saved "Save-ScriptsToFolder: and writes the script that was in the list"

    # Two of them, and a single script that is not a collection at all.
    [void]$listOfScripts.Add(@{ displayName = 'Second In List'; scriptContent = 'y' })
    Assert-Equal 2 (Save-ScriptsToFolder -Path $scriptFolder -Scripts $listOfScripts -NoPrune).Saved `
        "Save-ScriptsToFolder: more than one in the list is fine too"
    Assert-Equal 1 (Save-ScriptsToFolder -Path $scriptFolder -Scripts @{ displayName = 'Just One'; scriptContent = 'z' } -NoPrune).Saved `
        "Save-ScriptsToFolder: a lone script that is not a collection still works"
}
finally { Remove-Item -LiteralPath $scriptFolder -Recurse -Force -ErrorAction SilentlyContinue }

# -----------------------------------------------------------------
# Set-LastAuditCacheEntry - each check keeps its own time, and the
# entry's age is the oldest of them
# -----------------------------------------------------------------
$savedAuditResults = $Global:App.LastAuditResults
try {
    $Global:App.LastAuditResults = @{}
    $fiveDaysAgo = (Get-Date).AddDays(-5)
    # An entry as an old cache file loads it: one Timestamp, no per-check times.
    $Global:App.LastAuditResults['Old App'] = [pscustomobject]@{
        Timestamp = $fiveDaysAgo; Metadata = 'OK'; Groups = 'OK'; Dependencies = 'OK'; Unknown = 'OK'
    }
    Set-LastAuditCacheEntry -AppName 'Old App' -Groups '1 differ: Available for - catalog: A | Intune: (none)'
    $afterPartial = $Global:App.LastAuditResults['Old App']
    Assert-True ([Math]::Abs(([datetime]$afterPartial.Timestamp - $fiveDaysAgo).TotalMinutes) -lt 1) `
        "Set-LastAuditCacheEntry: a Groups-only check does not make five-day-old Metadata look fresh"
    Assert-Equal 'OK' $afterPartial.Metadata "Set-LastAuditCacheEntry: the checks not passed keep their result"
    Assert-True (([datetime]$afterPartial.Checked.Groups) -gt (Get-Date).AddMinutes(-1)) `
        "Set-LastAuditCacheEntry: the check that was passed is stamped now"

    # Both halves of a full audit (Metadata/Groups/Dependencies, then Unknown)
    # bring the whole entry up to date.
    Set-LastAuditCacheEntry -AppName 'Old App' -Metadata 'OK' -Groups 'OK' -Dependencies 'OK'
    Set-LastAuditCacheEntry -AppName 'Old App' -Unknown 'OK'
    Assert-True (([datetime]$Global:App.LastAuditResults['Old App'].Timestamp) -gt (Get-Date).AddMinutes(-1)) `
        "Set-LastAuditCacheEntry: once every check has run again, the entry reads as fresh"

    # A brand-new app with only part checked: its age is that part's.
    Set-LastAuditCacheEntry -AppName 'New App' -Metadata 'OK'
    Assert-True (([datetime]$Global:App.LastAuditResults['New App'].Timestamp) -gt (Get-Date).AddMinutes(-1)) `
        "Set-LastAuditCacheEntry: a new entry is as old as what it holds"
    Assert-Equal $null $Global:App.LastAuditResults['New App'].Checked.Groups "Set-LastAuditCacheEntry: an unchecked part has no time"
}
finally { $Global:App.LastAuditResults = $savedAuditResults }

# -----------------------------------------------------------------
# Get-ExistingSupersedence (EmbeddedScripts\CreateApp.ps1)
# -----------------------------------------------------------------
# Not under Private\, so loaded on its own, with Graph stubbed. What it
# returns is what survives an update's updateRelationships - which
# replaces the whole list, so anything it drops is deleted in Intune.
$createAppScript = Join-Path (Split-Path $privateRoot -Parent) 'EmbeddedScripts\CreateApp.ps1'
$createAppAst = [System.Management.Automation.Language.Parser]::ParseFile($createAppScript, [ref]$null, [ref]$null)
$supersedenceFn = $createAppAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-ExistingSupersedence' }, $true) | Select-Object -First 1
Assert-True ($null -ne $supersedenceFn) "Get-ExistingSupersedence: found in CreateApp.ps1"
if ($supersedenceFn) {
    . ([scriptblock]::Create($supersedenceFn.Extent.Text))
    $script:relPages = @(
        @{ value = @(
            @{ '@odata.type' = '#microsoft.graph.mobileAppDependency'; targetId = 'dep-1'; targetType = 'child'; dependencyType = 'autoInstall' }
            @{ '@odata.type' = '#microsoft.graph.mobileAppSupersedence'; targetId = 'old-1'; targetType = 'child'; supersedenceType = 'update' }
            @{ '@odata.type' = '#microsoft.graph.mobileAppSupersedence'; targetId = 'newer-app'; targetType = 'parent'; supersedenceType = 'replace' }
          ); '@odata.nextLink' = 'page2' }
        @{ value = @(
            @{ '@odata.type' = '#microsoft.graph.mobileAppSupersedence'; targetId = 'old-2'; targetType = 'child'; supersedenceType = 'replace' }
          ) }
    )
    $script:relPageIndex = 0
    function Invoke-GraphRequestDetailed { param($Uri, $Method, $StepDescription) $page = $script:relPages[$script:relPageIndex]; $script:relPageIndex++; return $page }
    $keptRels = Get-ExistingSupersedence -AppId 'app-1'
    Assert-Equal 2 @($keptRels).Count "Get-ExistingSupersedence: keeps this app's own supersedence, across pages"
    Assert-Equal 'old-1,old-2' ((@($keptRels) | ForEach-Object { $_.targetId }) -join ',') "Get-ExistingSupersedence: ...and only those - not dependencies, not other apps' (parent) entries"
    Assert-Equal 'update' @($keptRels)[0].supersedenceType "Get-ExistingSupersedence: the supersedence type (update/replace) is kept"
    Assert-Equal '#microsoft.graph.mobileAppSupersedence' @($keptRels)[0].'@odata.type' "Get-ExistingSupersedence: shaped to be sent straight back"
    $script:relPages = @(@{ value = @() }); $script:relPageIndex = 0
    Assert-Equal 0 @(Get-ExistingSupersedence -AppId 'app-1').Count "Get-ExistingSupersedence: none is an empty list"
    function Invoke-GraphRequestDetailed { param($Uri, $Method, $StepDescription) throw 'Forbidden' }
    $readThrew = $false
    try { [void](Get-ExistingSupersedence -AppId 'app-1') } catch { $readThrew = $true }
    Assert-True $readThrew "Get-ExistingSupersedence: a failed read throws, so the update sends nothing instead of wiping the list"
    Remove-Item Function:\Invoke-GraphRequestDetailed -ErrorAction SilentlyContinue
}

# -----------------------------------------------------------------
# Supersedence (metadata.supersedes)
# -----------------------------------------------------------------
$relList = @(
    @{ '@odata.type' = '#microsoft.graph.mobileAppDependency'; targetId = 'dep-1'; targetType = 'child'; targetDisplayName = 'Runtime' }
    @{ '@odata.type' = '#microsoft.graph.mobileAppSupersedence'; targetId = 'old-2'; targetType = 'child'; targetDisplayName = 'Tool 1.0'; supersedenceType = 'replace' }
    @{ '@odata.type' = '#microsoft.graph.mobileAppSupersedence'; targetId = 'newer'; targetType = 'parent'; targetDisplayName = 'Tool 3.0'; supersedenceType = 'update' }
)
$supEntries = @(ConvertTo-SupersedenceEntries -Relationships $relList)
Assert-Equal 1 $supEntries.Count "ConvertTo-SupersedenceEntries: only this app's own (child) supersedence, not dependencies or parents"
Assert-Equal 'old-2' $supEntries[0].appId "ConvertTo-SupersedenceEntries: keeps the target App ID"
Assert-Equal 'Tool 1.0' $supEntries[0].name "ConvertTo-SupersedenceEntries: ...and its name"
Assert-Equal 'replace' $supEntries[0].type "ConvertTo-SupersedenceEntries: ...and the type"
Assert-Equal "(none)" (Format-SupersedenceSummary @()) "Format-SupersedenceSummary: nothing reads as (none)"
Assert-True ((Format-SupersedenceSummary $supEntries) -like '*Tool 1.0*uninstall*') "Format-SupersedenceSummary: says Replace uninstalls the old app"
$sameRenamed = @([pscustomobject]@{ appId = 'old-2'; name = 'Tool 1.0 (renamed)'; type = 'replace' })
Assert-Equal (Get-SupersedenceCompareKey $supEntries) (Get-SupersedenceCompareKey $sameRenamed) "Get-SupersedenceCompareKey: a renamed app is still the same app"
$typeChanged = @([pscustomobject]@{ appId = 'old-2'; name = 'Tool 1.0'; type = 'update' })
Assert-True ((Get-SupersedenceCompareKey $supEntries) -ne (Get-SupersedenceCompareKey $typeChanged)) "Get-SupersedenceCompareKey: a changed type is a difference"

# Compare: skipped while never recorded locally, or unreadable remotely
$supLocalNull = [pscustomobject]@{ description = 'd'; supersedes = $null }
$supRemote = [pscustomobject]@{ description = 'd'; supersedes = $supEntries }
Assert-Equal 0 @(Get-CatalogMetadataFieldDiffs -Local $supLocalNull -Remote $supRemote | Where-Object { $_.Field -eq 'Supersedence' }).Count "Get-CatalogMetadataFieldDiffs: supersedence never recorded locally is not a difference"
$supLocalEmpty = [pscustomobject]@{ description = 'd'; supersedes = @() }
Assert-Equal 1 @(Get-CatalogMetadataFieldDiffs -Local $supLocalEmpty -Remote $supRemote | Where-Object { $_.Field -eq 'Supersedence' }).Count "Get-CatalogMetadataFieldDiffs: recorded as none while Intune has one is a difference"
Assert-Equal 0 @(Get-CatalogMetadataFieldDiffs -Local $supLocalEmpty -Remote ([pscustomobject]@{ description = 'd'; supersedes = $null }) | Where-Object { $_.Field -eq 'Supersedence' }).Count "Get-CatalogMetadataFieldDiffs: an unreadable remote list is not a difference"
Assert-Equal 0 @(Get-CatalogMetadataFieldDiffs -Local $supLocalEmpty -Remote $supRemote -OdataType 'winGetApp' | Where-Object { $_.Field -eq 'Supersedence' }).Count "Get-CatalogMetadataFieldDiffs: supersedence is only compared for Win32 apps"
$supMerged = Merge-CatalogMetadata -Remote $supRemote -Local $supLocalEmpty -KeepLocalFields @('Supersedence')
Assert-Equal 0 @($supMerged.supersedes).Count "Merge-CatalogMetadata: keeping the local supersedence works by its label"

# Catalog file: entries round-trip; null and [] stay different
$supApp = [pscustomobject]@{
    appId = ''; appName = 'Sup Trip'; wingetId = 'x.y'; intuneAppType = ''; intuneAppVersion = ''
    requiredFor = @(); availableFor = @(); uninstallFor = @(); excludeFor = @()
    metadata = [pscustomobject]@{ description = 'd'; supersedes = $supEntries }
}
$supBack = ConvertTo-AppRecord -Raw ((ConvertTo-SingleAppJson -App $supApp) | ConvertFrom-Json)
Assert-Equal 'old-2' @($supBack.metadata.supersedes)[0].appId "ConvertTo-SingleAppJson/ConvertTo-AppRecord: supersedence round-trips"
Assert-Equal 'replace' @($supBack.metadata.supersedes)[0].type "ConvertTo-SingleAppJson/ConvertTo-AppRecord: ...with its type"
$supApp.metadata = [pscustomobject]@{ description = 'd'; supersedes = $null }
Assert-Null (ConvertTo-AppRecord -Raw ((ConvertTo-SingleAppJson -App $supApp) | ConvertFrom-Json)).metadata.supersedes "ConvertTo-AppRecord: never-recorded supersedence stays null through a save"
Assert-Equal "[]" (ConvertTo-SupersedenceJson -Entries @()) "ConvertTo-SupersedenceJson: recorded as none is [], not null"
Assert-Equal "null" (ConvertTo-SupersedenceJson -Entries $null) "ConvertTo-SupersedenceJson: never recorded is null"

# Deploy config: SupersedenceSet says whether the list is the catalog's
$cfgBase = @{ TenantId = 't'; ClientId = 'c'; CertificateThumbprint = 'x'; Mode = 'UpdateMetadata'; ExistingAppId = 'a'; AppName = 'n'
    MinDiskSpaceMB = 0; MinMemoryMB = 0; MinProcessors = 0; MinCpuSpeedMHz = 0; InstallTimeMinutes = 60; ReturnCodes = @() }
$cfgUnknown = [pscustomobject]($cfgBase + @{ Supersedence = $null }) | ForEach-Object { (ConvertTo-CreateAppConfigJson -Config $_) | ConvertFrom-Json }
Assert-Equal $false $cfgUnknown.SupersedenceSet "ConvertTo-CreateAppConfigJson: unknown supersedence is not set (an update keeps Intune's)"
$cfgNone = [pscustomobject]($cfgBase + @{ Supersedence = @() }) | ForEach-Object { (ConvertTo-CreateAppConfigJson -Config $_) | ConvertFrom-Json }
Assert-Equal $true $cfgNone.SupersedenceSet "ConvertTo-CreateAppConfigJson: recorded as none is set (an update clears Intune's)"
$cfgSome = [pscustomobject]($cfgBase + @{ Supersedence = $supEntries }) | ForEach-Object { (ConvertTo-CreateAppConfigJson -Config $_) | ConvertFrom-Json }
Assert-Equal 'old-2' @($cfgSome.Supersedence)[0].targetId "ConvertTo-CreateAppConfigJson: entries go out as targetId..."
Assert-Equal 'replace' @($cfgSome.Supersedence)[0].supersedenceType "ConvertTo-CreateAppConfigJson: ...and supersedenceType"

# Custom Config counts supersedence (a real setting); the default is none
$supDefaults = Get-DefaultAppMetadata -AppName "Some Winget App" -WingetId "some.app" -Uncommon $false
Assert-Equal 0 @($supDefaults.supersedes).Count "Get-DefaultAppMetadata: supersedes nothing by default"
$supCustom = $supDefaults.PSObject.Copy(); $supCustom.supersedes = $supEntries
Assert-Equal $true (Test-AppHasCustomConfig -App ([pscustomobject]@{ appName = "Some Winget App"; wingetId = "some.app"; metadata = $supCustom })) "Test-AppHasCustomConfig: superseding an app is custom config"

# Get-ConfigSupersedence (CreateApp.ps1) - what an update/create sends
$configSupFn = $createAppAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-ConfigSupersedence' }, $true) | Select-Object -First 1
Assert-True ($null -ne $configSupFn) "Get-ConfigSupersedence: found in CreateApp.ps1"
if ($configSupFn) {
    . ([scriptblock]::Create($configSupFn.Extent.Text))
    Set-Variable -Name Config -Value $cfgSome   # read by the dot-sourced function
    $sent = @(Get-ConfigSupersedence)
    Assert-Equal 1 $sent.Count "Get-ConfigSupersedence: one entry in, one relationship out"
    Assert-Equal '#microsoft.graph.mobileAppSupersedence' $sent[0].'@odata.type' "Get-ConfigSupersedence: shaped as a supersedence relationship"
    Set-Variable -Name Config -Value $cfgNone
    Assert-Equal 0 @(Get-ConfigSupersedence).Count "Get-ConfigSupersedence: none recorded sends none"
    Remove-Variable Config
}

# -----------------------------------------------------------------
# Checks: one findings list (CheckFindings.ps1)
# -----------------------------------------------------------------
$chkApps = @(
    [pscustomobject]@{ appId = 'id-7zip'; appName = '7-Zip'; wingetId = '7zip.7zip'; requiredFor = @('SG-All'); availableFor = @(); uninstallFor = @(); excludeFor = @('SG-Gone')
        metadata = [pscustomobject]@{ description = '7-Zip'; publisher = 'Igor'; dependencies = @('Runtime') } }
    [pscustomobject]@{ appId = 'id-old'; appName = 'Old Name'; wingetId = ''; requiredFor = @(); availableFor = @(); uninstallFor = @(); excludeFor = @(); metadata = $null }
    [pscustomobject]@{ appId = 'id-deleted'; appName = 'Deleted App'; wingetId = ''; requiredFor = @(); availableFor = @(); uninstallFor = @(); excludeFor = @(); metadata = $null }
    [pscustomobject]@{ appId = ''; appName = 'Firefox'; wingetId = 'Mozilla.Firefox'; requiredFor = @(); availableFor = @(); uninstallFor = @(); excludeFor = @(); metadata = $null }
    [pscustomobject]@{ appId = ''; appName = 'Chrome'; wingetId = ''; requiredFor = @(); availableFor = @(); uninstallFor = @(); excludeFor = @(); metadata = $null }
    [pscustomobject]@{ appId = ''; appName = 'Not Deployed'; wingetId = ''; requiredFor = @(); availableFor = @(); uninstallFor = @(); excludeFor = @(); metadata = $null }
)
$chkIntune = @(
    [pscustomobject]@{ id = 'id-7zip'; displayName = '7-Zip' }
    [pscustomobject]@{ id = 'id-old'; displayName = 'New Name' }
    [pscustomobject]@{ id = 'id-ff'; displayName = 'Firefox' }
    [pscustomobject]@{ id = 'id-chrome1'; displayName = 'Google Chrome' }
    [pscustomobject]@{ id = 'id-only'; displayName = 'Intune Only App' }
)
$link = @(Get-IntuneLinkFindings -Apps $chkApps -IntuneApps $chkIntune)
$byProblem = @{}; foreach ($f in $link) { $byProblem["$($f.Problem)|$($f.App)"] = $f }
Assert-True ($byProblem.ContainsKey('In Intune, not in the catalog|Intune Only App')) "Get-IntuneLinkFindings: an Intune-only app is reported"
Assert-Equal 'AddToCatalog' $byProblem['In Intune, not in the catalog|Intune Only App'].Actions[0] "Get-IntuneLinkFindings: ...with Add to catalog"
Assert-True ($byProblem.ContainsKey('Renamed in Intune|Old Name')) "Get-IntuneLinkFindings: a rename in Intune is reported by the catalog name"
Assert-Equal 'New Name' $byProblem['Renamed in Intune|Old Name'].Data.IntuneName "Get-IntuneLinkFindings: ...and knows Intune's name"
Assert-True ($byProblem.ContainsKey('App ID not in Intune any more|Deleted App')) "Get-IntuneLinkFindings: a stale App ID is reported"
Assert-Equal 'ClearAppId' $byProblem['App ID not in Intune any more|Deleted App'].Actions[0] "Get-IntuneLinkFindings: ...with Clear App ID"
Assert-True ($byProblem.ContainsKey('In Intune, App ID not set|Firefox')) "Get-IntuneLinkFindings: an exact name match without App ID is reported"
Assert-Equal 'id-ff' $byProblem['In Intune, App ID not set|Firefox'].Data.MatchedId "Get-IntuneLinkFindings: ...with the matched App ID to set"
Assert-True ($byProblem.ContainsKey('Possibly in Intune, App ID not set|Chrome')) "Get-IntuneLinkFindings: a partial name match is offered as possible"
Assert-Equal 0 @($link | Where-Object { $_.App -eq 'Not Deployed' }).Count "Get-IntuneLinkFindings: an app with no App ID and no match is just not deployed - no row"
Assert-Equal 0 @($link | Where-Object { $_.App -eq 'Firefox' -and $_.Problem -like 'In Intune, not*' }).Count "Get-IntuneLinkFindings: a name-matched Intune app isn't also reported as not in the catalog"
$scopedLink = @(Get-IntuneLinkFindings -Apps @($chkApps[1]) -IntuneApps $chkIntune -Scoped)
Assert-Equal 0 @($scopedLink | Where-Object { $_.Problem -like 'In Intune, not*' }).Count "Get-IntuneLinkFindings: a scoped run leaves the tenant's other apps alone"
Assert-Equal 1 @($scopedLink | Where-Object { $_.Problem -eq 'Renamed in Intune' }).Count "Get-IntuneLinkFindings: ...but still checks the scoped app"

# Per-app detail from a SyncMetadata result
$chkResultSame = [pscustomobject]@{ Success = $true; OdataType = '#microsoft.graph.win32LobApp'; GroupFetchOk = $true
    Metadata = [pscustomobject]@{ description = '7-Zip'; publisher = 'Igor'; dependencies = @('Runtime') }
    RequiredGroupNames = @('SG-All'); AvailableGroupNames = @(); UninstallGroupNames = @() }
Assert-Equal 0 @(Get-AppDetailFindings -CatalogApp $chkApps[0] -Result $chkResultSame).Count "Get-AppDetailFindings: an app that matches Intune has no rows"
$chkResultDiff = [pscustomobject]@{ Success = $true; OdataType = '#microsoft.graph.win32LobApp'; GroupFetchOk = $true
    Metadata = [pscustomobject]@{ description = '7-Zip'; publisher = 'Someone Else'; dependencies = @() }
    RequiredGroupNames = @('SG-Other'); AvailableGroupNames = @(); UninstallGroupNames = @() }
$detail = @(Get-AppDetailFindings -CatalogApp $chkApps[0] -Result $chkResultDiff)
Assert-Equal 'Metadata,Groups,Dependencies' (($detail | ForEach-Object { $_.Area }) -join ',') "Get-AppDetailFindings: one row per area that differs"
Assert-True ($detail[0].Catalog -like '*Publisher: Igor*' -and $detail[0].Intune -like '*Publisher: Someone Else*') "Get-AppDetailFindings: shows both sides of a metadata difference"
Assert-Equal 'Pull,PushMetadata' ($detail[0].Actions -join ',') "Get-AppDetailFindings: metadata can be pulled or pushed"
Assert-Equal 'Pull,PushGroups' ($detail[1].Actions -join ',') "Get-AppDetailFindings: groups can be pulled or pushed"
$texts = Get-AuditSummaryTexts -CatalogApp $chkApps[0] -Result $chkResultDiff
Assert-Equal '1 field(s) differ: Publisher' $texts.Metadata "Get-AuditSummaryTexts: the Last Audit wording is unchanged"
Assert-Equal 'Catalog has: Runtime | Intune has: (none)' $texts.Dependencies "Get-AuditSummaryTexts: ...for dependencies too"
$failedDetail = @(Get-AppDetailFindings -CatalogApp $chkApps[0] -Result ([pscustomobject]@{ Success = $false; Error = 'Forbidden' }))
Assert-True ($failedDetail.Count -eq 1 -and $failedDetail[0].Failed) "Get-AppDetailFindings: a failed read is a row, marked failed"
$noGroups = $chkResultSame.PSObject.Copy(); $noGroups.GroupFetchOk = $false
Assert-True (@(Get-AppDetailFindings -CatalogApp $chkApps[0] -Result $noGroups | Where-Object { $_.Area -eq 'Groups' -and $_.Failed }).Count -eq 1) "Get-AppDetailFindings: unreadable groups are a failed Groups row, not a difference"

# Unknown assignments
Assert-Equal 0 @(Get-UnknownAssignmentFindings -CatalogApp $chkApps[0] -ToRemove @()).Count "Get-UnknownAssignmentFindings: none is no row"
$unknown = @(Get-UnknownAssignmentFindings -CatalogApp $chkApps[0] -ToRemove @('SG-Stray'))
Assert-Equal '1 unknown: SG-Stray' $unknown[0].Problem "Get-UnknownAssignmentFindings: same wording as Last Audit"
Assert-Equal 'PushGroups' $unknown[0].Actions[0] "Get-UnknownAssignmentFindings: pushing the catalog's groups is the fix"

# Catalog dependencies
$depApps = @(
    [pscustomobject]@{ appName = 'A'; appId = ''; metadata = [pscustomobject]@{ dependencies = @('B') } }
    [pscustomobject]@{ appName = 'B'; appId = ''; metadata = [pscustomobject]@{ dependencies = @('A') } }
    [pscustomobject]@{ appName = 'C'; appId = ''; metadata = [pscustomobject]@{ dependencies = @('Nowhere') } }
    [pscustomobject]@{ appName = 'D'; appId = ''; metadata = [pscustomobject]@{ dependencies = @('C') } }
)
$depFindings = @(Get-DependencyFindings -Apps $depApps)
Assert-Equal 'A,B' ((@($depFindings | Where-Object { $_.Problem -eq 'Circular dependency' } | ForEach-Object { $_.App })) -join ',') "Get-DependencyFindings: both apps in a circle are reported"
Assert-Equal 'C' ((@($depFindings | Where-Object { $_.Problem -like '*isn*t in the catalog' } | ForEach-Object { $_.App })) -join ',') "Get-DependencyFindings: a dependency on a missing app is reported"
Assert-Equal 0 @($depFindings | Where-Object { $_.App -eq 'D' }).Count "Get-DependencyFindings: a good dependency is fine"
Assert-Equal 1 @(Get-DependencyFindings -Apps $depApps -OnlyNames @('C')).Count "Get-DependencyFindings: a scoped run reports only its apps"

# Entra groups
$dir = @([pscustomobject]@{ type = 'Group'; displayName = 'SG-All' }, [pscustomobject]@{ type = 'User'; displayName = 'SG-Gone' })
$entra = @(Get-EntraGroupFindings -Apps $chkApps -Directory $dir)
Assert-Equal 1 $entra.Count "Get-EntraGroupFindings: only the group that doesn't exist (a user of that name doesn't count)"
Assert-Equal 'SG-Gone' $entra[0].Data.Group "Get-EntraGroupFindings: exclusions are checked too"
Assert-Equal '7-Zip' $entra[0].App "Get-EntraGroupFindings: names the app that uses it"
$entraActions = @($entra[0].Actions)
Assert-True ($entraActions -contains 'CreateGroup' -and $entraActions -contains 'OpenGroup') "Get-EntraGroupFindings: offers to create the group and to open it"

# Winget
$winget = @(Get-WingetFindings -Apps $chkApps -Results @(
    [pscustomobject]@{ AppName = '7-Zip'; WingetId = '7zip.7zip'; Ok = $true; Result = 'Found' }
    [pscustomobject]@{ AppName = 'Firefox'; WingetId = 'Mozilla.Firefox'; Ok = $false; Result = "NOT FOUND - winget doesn't know this ID any more" }
    [pscustomobject]@{ AppName = 'Chrome'; WingetId = 'Google.Chrome'; Ok = $false; Result = "winget didn't answer within 30 seconds" }
))
Assert-Equal 2 $winget.Count "Get-WingetFindings: found IDs are fine, the rest are rows"
Assert-Equal 'FindWingetId' $winget[0].Actions[0] "Get-WingetFindings: a gone ID offers finding its new one"
Assert-True ($winget[1].Failed) "Get-WingetFindings: an unanswered check is failed, not a gone package"

# Add to catalog: an entry from an Intune-only app's read
$fetchedForAdd = [pscustomobject]@{ InstallCommandLine = 'powershell -File Winget-Install.ps1 -AppIDs "Vendor.Tool"'; OdataType = '#microsoft.graph.win32LobApp'
    DisplayVersion = '2.0'; GroupFetchOk = $true; RequiredGroupNames = @('SG-A'); AvailableGroupNames = @(); UninstallGroupNames = @(); Description = 'Tool' }
$added = ConvertTo-CatalogEntryFromFetch -Id 'id-tool' -Name 'Tool' -Ok $true -Data $fetchedForAdd
Assert-Equal 'Vendor.Tool' $added.wingetId "ConvertTo-CatalogEntryFromFetch: the Winget ID comes from the install command"
Assert-Equal 'SG-A' (@($added.requiredFor) -join ',') "ConvertTo-CatalogEntryFromFetch: groups come across"
Assert-Equal 'Tool' $added.metadata.description "ConvertTo-CatalogEntryFromFetch: so does the metadata"
$fetchedNoGroups = $fetchedForAdd.PSObject.Copy(); $fetchedNoGroups.GroupFetchOk = $false
$addedNoGroups = ConvertTo-CatalogEntryFromFetch -Id 'id-tool' -Name 'Tool' -Ok $true -Data $fetchedNoGroups
Assert-True (-not $addedNoGroups.GroupsKnown -and @($addedNoGroups.requiredFor).Count -eq 0) "ConvertTo-CatalogEntryFromFetch: unreadable groups are empty and flagged unknown"
$addedFailed = ConvertTo-CatalogEntryFromFetch -Id 'id-x' -Name 'X' -Ok $false -Data $null
Assert-True ($addedFailed.appId -eq 'id-x' -and $null -eq $addedFailed.metadata) "ConvertTo-CatalogEntryFromFetch: a failed read still gives name and App ID"

# Cached (last audit) findings
$cache = @{ '7-Zip' = [pscustomobject]@{ Timestamp = (Get-Date).AddHours(-2); Metadata = '1 field(s) differ: Publisher'; Groups = 'OK'; Dependencies = $null; Unknown = 'Failed: x'
    Checked = [pscustomobject]@{ Metadata = (Get-Date).AddHours(-1).ToString('o'); Groups = $null; Dependencies = $null; Unknown = $null } } }
$cached = @(Get-CachedAuditFindings -Apps $chkApps -LastAuditResults $cache)
Assert-Equal 2 $cached.Count "Get-CachedAuditFindings: OK and never-checked areas are no rows"
Assert-True ($cached[0].Cached -and $cached[0].CheckedAt) "Get-CachedAuditFindings: marked as the last audit's, with its time"
Assert-True ($cached[1].Failed -and $cached[1].Area -eq 'Unknown assignments') "Get-CachedAuditFindings: a failed check stays failed"

# =================================================================
# Graph module conflicts (GraphModuleConflict.ps1)
# =================================================================
$deConflict = 'Ausnahme beim Aufrufen von "EndInvoke" mit 1 Argument(en): "Die Methode "RefreshCacheAsync" im Typ "Microsoft.Graph.PowerShell.Authentication.Core.TokenCache.InMemoryTokenCacheOptions" der Assembly "Microsoft.Graph.Authentication.Core, Version=2.41.2.0" hat keine Implementierung."'
$enConflict = "Method 'RefreshCacheAsync' in type 'Microsoft.Graph.PowerShell.Authentication.Core.TokenCache.InMemoryTokenCacheOptions' from assembly 'Microsoft.Graph.Authentication.Core, Version=2.41.2.0' does not have an implementation."
Assert-True (Test-GraphAssemblyConflictText $deConflict) "Test-GraphAssemblyConflictText: the German .NET Framework message"
Assert-True (Test-GraphAssemblyConflictText $enConflict) "Test-GraphAssemblyConflictText: the English one"
Assert-True (Test-GraphAssemblyConflictText "Could not load file or assembly 'Azure.Core, Version=1.44.1.0'") "Test-GraphAssemblyConflictText: a missing Azure.Core version"
Assert-True (-not (Test-GraphAssemblyConflictText "ClientCertificateCredential authentication failed: .")) "Test-GraphAssemblyConflictText: a certificate failure isn't one"
Assert-True (-not (Test-GraphAssemblyConflictText "Could not load file or assembly 'Contoso.Widgets'")) "Test-GraphAssemblyConflictText: an unrelated assembly isn't one"
Assert-True (-not (Test-GraphAssemblyConflictText "")) "Test-GraphAssemblyConflictText: empty"
Assert-True ((ConvertTo-FriendlyGraphError $deConflict) -like "PowerShell module conflict*-NoProfile*") "ConvertTo-FriendlyGraphError: a module conflict says to restart without the profile"
Assert-True ((ConvertTo-FriendlyGraphError "ClientCertificateCredential authentication failed: .") -like "*uploaded to the app registration*") "ConvertTo-FriendlyGraphError: an empty certificate failure points at Entra"
Assert-True ((ConvertTo-FriendlyGraphError "Certificate with thumbprint '09DD' was not found in certificate store or has expired.") -like "*isn't on this machine*") "ConvertTo-FriendlyGraphError: a missing certificate says so"
# Intune answers a missing permission with 401, "Forbidden" in the body - from a live run
$intune401 = ConvertTo-FriendlyGraphError 'GET https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?$top=999 HTTP/1.1 401 Unauthorized {"error":{"code":"UnknownError","message":"{\"ErrorCode\":\"Forbidden\"}"}}'
Assert-True ($intune401 -like "*DeviceManagementApps.ReadWrite.All*" -and $intune401 -like "*Test connection again*") "ConvertTo-FriendlyGraphError: an Intune 401 names the permission and the stale sign-in" $intune401

Assert-Equal 'Az.Accounts 2.12.1' (Get-ModuleNameFromAssemblyPath 'C:\Program Files\WindowsPowerShell\Modules\Az.Accounts\2.12.1\PreloadAssemblies\Azure.Core.dll') "Get-ModuleNameFromAssemblyPath: module and version"
Assert-Equal 'ExchangeOnlineManagement' (Get-ModuleNameFromAssemblyPath 'C:\Users\x\Documents\WindowsPowerShell\Modules\ExchangeOnlineManagement\netFramework\Azure.Core.dll') "Get-ModuleNameFromAssemblyPath: module without a version folder"
Assert-Equal '' (Get-ModuleNameFromAssemblyPath 'C:\Windows\Microsoft.NET\assembly\GAC_MSIL\Azure.Core.dll') "Get-ModuleNameFromAssemblyPath: not a module"

$graphBase = 'C:\Program Files\WindowsPowerShell\Modules\Microsoft.Graph.Authentication\2.41.2'
$shipped = @{ 'Azure.Core' = '1.44.1.0'; 'Azure.Identity' = '1.13.1.0'; 'Microsoft.Identity.Client' = '4.66.1.0' }
$loadedAsm = @(
    [pscustomobject]@{ Name = 'Azure.Core'; Version = '1.38.0.0'; Location = 'C:\Program Files\WindowsPowerShell\Modules\Az.Accounts\2.12.1\lib\Azure.Core.dll' }
    [pscustomobject]@{ Name = 'Azure.Core'; Version = '1.38.0.0'; Location = 'C:\Program Files\WindowsPowerShell\Modules\Az.Accounts\2.12.1\lib\Azure.Core.dll' }
    [pscustomobject]@{ Name = 'Azure.Identity'; Version = '1.13.1.0'; Location = 'C:\elsewhere\Azure.Identity.dll' }
    [pscustomobject]@{ Name = 'Microsoft.Identity.Client'; Version = '4.50.0.0'; Location = "$graphBase\Dependencies\Microsoft.Identity.Client.dll" }
    [pscustomobject]@{ Name = 'System.Xml'; Version = '4.0.0.0'; Location = 'C:\Windows\System.Xml.dll' }
)
$found = @(Get-GraphAssemblyConflicts -ModuleAssemblies $shipped -ModuleBase $graphBase -LoadedAssemblies $loadedAsm)
Assert-Equal 1 $found.Count "Get-GraphAssemblyConflicts: one collision - same version and the module's own copy don't count, duplicates are one row"
Assert-True ($found[0].Name -eq 'Azure.Core' -and $found[0].Loaded -eq '1.38.0.0' -and $found[0].Expected -eq '1.44.1.0' -and $found[0].Owner -eq 'Az.Accounts 2.12.1') "Get-GraphAssemblyConflicts: names what's loaded, what Graph needs and who brought it"
Assert-True (-not $found[0].SameModule) "Get-GraphAssemblyConflicts: Az isn't another Graph version"
$olderGraph = @([pscustomobject]@{ Name = 'Azure.Core'; Version = '1.35.0.0'; Location = 'C:\Program Files\WindowsPowerShell\Modules\Microsoft.Graph.Authentication\2.10.0\Dependencies\Azure.Core.dll' })
Assert-True (@(Get-GraphAssemblyConflicts -ModuleAssemblies $shipped -ModuleBase $graphBase -LoadedAssemblies $olderGraph)[0].SameModule) "Get-GraphAssemblyConflicts: an older Graph version is flagged as such"
Assert-Equal 0 @(Get-GraphAssemblyConflicts -ModuleAssemblies @{} -ModuleBase $graphBase -LoadedAssemblies $loadedAsm).Count "Get-GraphAssemblyConflicts: nothing known about the module, nothing claimed"
$twoCopies = @{ 'Azure.Core' = @('1.44.1.0', '1.45.0.0'); 'System.Memory' = '4.0.1.2' }
$runtimeLoaded = @(
    [pscustomobject]@{ Name = 'Azure.Core'; Version = '1.45.0.0'; Location = 'C:\x\Azure.Core.dll' }
    [pscustomobject]@{ Name = 'System.Memory'; Version = '8.0.0.0'; Location = 'C:\Program Files\PowerShell\7\System.Memory.dll' }
)
Assert-Equal 0 @(Get-GraphAssemblyConflicts -ModuleAssemblies $twoCopies -ModuleBase $graphBase -LoadedAssemblies $runtimeLoaded).Count "Get-GraphAssemblyConflicts: either shipped copy's version is fine, and PowerShell's own System.* never counts"

Assert-True (Test-SessionStartedWithoutProfile -Arguments @('powershell.exe', '-NoProfile', '-File', 'x.ps1')) "Test-SessionStartedWithoutProfile: -NoProfile"
Assert-True (Test-SessionStartedWithoutProfile -Arguments @('pwsh', '-nop')) "Test-SessionStartedWithoutProfile: -nop"
Assert-True (-not (Test-SessionStartedWithoutProfile -Arguments @('powershell.exe', '-NoLogo', '-File', 'x.ps1'))) "Test-SessionStartedWithoutProfile: -NoLogo isn't it"

$conflictText = Format-GraphAssemblyConflictText -Conflicts $found -LoadedModules @('Az.Accounts 2.12.1') -ErrorText $enConflict -NoProfile $false -GraphVersion '2.41.2'
Assert-True ($conflictText -like '*Azure.Core 1.38.0.0 (Graph needs 1.44.1.0) from Az.Accounts 2.12.1*') "Format-GraphAssemblyConflictText: lists the collision"
Assert-True ($conflictText -like '*-NoProfile*' -and $conflictText -like '*RefreshCacheAsync*') "Format-GraphAssemblyConflictText: the restart command and the original error"
Assert-True (-not ($conflictText -like '*Uninstall-Module*')) "Format-GraphAssemblyConflictText: no uninstall advice when it isn't another Graph version"
$sameText = Format-GraphAssemblyConflictText -Conflicts @(Get-GraphAssemblyConflicts -ModuleAssemblies $shipped -ModuleBase $graphBase -LoadedAssemblies $olderGraph) -NoProfile $true
Assert-True ($sameText -like '*Uninstall-Module*' -and $sameText -like '*already started without a PowerShell profile*') "Format-GraphAssemblyConflictText: two Graph versions - uninstall advice, and no false promise from a restart"

# =================================================================
# Hardening: values that end up in code, addresses or file names
# =================================================================
$rq = [string][char]0x2019
Assert-Equal "a''b" (ConvertTo-PsSingleQuotedContent "a'b") "ConvertTo-PsSingleQuotedContent: a plain quote is doubled"
Assert-Equal "a$rq${rq}b" (ConvertTo-PsSingleQuotedContent "a${rq}b") "ConvertTo-PsSingleQuotedContent: so is a typographic one, which PowerShell also ends a string on"
Assert-Equal 'ab' (ConvertTo-PsSingleQuotedContent "a`"`r`nb") "ConvertTo-PsSingleQuotedContent: double quotes and line breaks are removed"
Assert-Equal '7zip.7zip' (ConvertTo-PsSingleQuotedContent '7zip.7zip') "ConvertTo-PsSingleQuotedContent: a normal Winget ID is untouched"
$evilId = 'Foo.Bar$(Start-Process calc)'
$evilDetection = (Get-CreateAppTemplates -WingetId $evilId -Uncommon $false -Method 'WAU').Detection
Assert-True ($evilDetection.Contains("`$AppToDetect = 'Foo.Bar`$(Start-Process calc)'")) "Get-CreateAppTemplates: the Winget ID is a single-quoted literal in the detection script, so `$(...) in it never runs" $evilDetection
$quoteCmd = (Get-WingetCommandLines -WingetId "Foo'Bar`"x" -Method 'Winget' -InstallContext 'System').Install
Assert-True ($quoteCmd.Contains("--id 'Foo''Barx'")) "Get-WingetCommandLines: a quote in the ID can't close the string, a double quote can't close the command line" $quoteCmd

Assert-Equal 'CON_' (Get-SafeFileNameForApp -Name 'CON') "Get-SafeFileNameForApp: a reserved device name gets a suffix"
Assert-Equal 'Lpt1_' (Get-SafeFileNameForApp -Name 'Lpt1') "Get-SafeFileNameForApp: in any letter case"
Assert-Equal 'Console' (Get-SafeFileNameForApp -Name 'Console') "Get-SafeFileNameForApp: a name that only starts like one is fine"
Assert-Equal 'ab' (Get-SafeFileNameForApp -Name "a`tb".Replace("`t", [string][char]1)) "Get-SafeFileNameForApp: control characters are removed"

$guidId = 'c0ffee00-1111-4222-8333-444455556666'
Assert-Equal $guidId (ConvertTo-AppRecord -Raw ([pscustomobject]@{ appName = 'A'; appId = $guidId })).appId "ConvertTo-AppRecord: a GUID App ID is kept"
Assert-Equal $guidId (ConvertTo-AppRecord -Raw ([pscustomobject]@{ appName = 'A'; appId = "{$guidId}" })).appId "ConvertTo-AppRecord: braces around it are dropped"
Assert-Equal '' (ConvertTo-AppRecord -Raw ([pscustomobject]@{ appName = 'A'; appId = "../../../v1.0/groups/$guidId" })).appId "ConvertTo-AppRecord: an App ID that's really a path is not kept"

# =================================================================
# Setup checklist after Test connection (GraphToken.ps1)
# =================================================================
$future = (Get-Date).AddYears(1)
$fullReport = Get-GraphRoleReport -Roles @('DeviceManagementApps.ReadWrite.All', 'Group.ReadWrite.All', 'Directory.Read.All', 'DeviceManagementScripts.ReadWrite.All')
$doneText = (Format-SetupChecklist -State @{ ModuleOk = $true; FieldsOk = $true; CertFound = $true; CertHasKey = $true; CertNotAfter = $future; SignInOk = $true; Report = $fullReport; Saved = $true }) -join "`n"
Assert-True ($doneText -like '*Setup complete - every step is done*' -and $doneText -notlike '*FAILED*' -and $doneText -notlike '*Next:*') "Format-SetupChecklist: everything done says so" $doneText

# Today's case: reissued certificate, not uploaded yet, not saved
$notUploaded = (Format-SetupChecklist -State @{ ModuleOk = $true; FieldsOk = $true; CertFound = $true; CertHasKey = $true; CertNotAfter = $future; SignInOk = $false; SignInError = 'ClientCertificateCredential authentication failed: .'; Saved = $false }) -join "`n"
Assert-True ($notUploaded -match '(?s)\[FAILED\] Entra ID accepts the certificate.*Next: Upload this certificate') "Format-SetupChecklist: a refused certificate points at the upload" $notUploaded
Assert-True ($notUploaded -like '*`[--`] Required API permissions*') "Format-SetupChecklist: permissions can't be known yet" $notUploaded
Assert-Equal 1 ([regex]::Matches($notUploaded, 'Next:').Count) "Format-SetupChecklist: one next step, for the first thing that's not done" $notUploaded

$noRoles = (Format-SetupChecklist -State @{ ModuleOk = $true; FieldsOk = $true; CertFound = $true; CertHasKey = $true; CertNotAfter = $future; SignInOk = $true; Report = (Get-GraphRoleReport -Roles @()); Saved = $true }) -join "`n"
Assert-True ($noRoles -match '(?s)\[FAILED\] Required API permissions.*Next: Use Add required permissions\.\.\. in Settings.*Application, not Delegated') "Format-SetupChecklist: signed in without permissions says what's next" $noRoles

$unsaved = (Format-SetupChecklist -State @{ ModuleOk = $true; FieldsOk = $true; CertFound = $true; CertHasKey = $true; CertNotAfter = $future; SignInOk = $true; Report = $fullReport; Saved = $false }) -join "`n"
Assert-True ($unsaved -match '(?s)\[FAILED\] Settings saved.*Next: Click Save') "Format-SetupChecklist: a working but unsaved connection says to save" $unsaved

$noKey = (Format-SetupChecklist -State @{ ModuleOk = $true; FieldsOk = $true; CertFound = $true; CertHasKey = $false; SignInOk = $null; Saved = $true }) -join "`n"
Assert-True ($noKey -like '*no private key*' -and $noKey -like '*`[--`] Entra ID accepts*') "Format-SetupChecklist: a certificate without its key stops there" $noKey
$expired = (Format-SetupChecklist -State @{ ModuleOk = $true; FieldsOk = $true; CertFound = $true; CertHasKey = $true; CertNotAfter = (Get-Date).AddDays(-1); Saved = $true }) -join "`n"
Assert-True ($expired -like '*has expired*') "Format-SetupChecklist: an expired certificate says so" $expired
$wrongClient = (Format-SetupChecklist -State @{ ModuleOk = $true; FieldsOk = $true; CertFound = $true; CertHasKey = $true; CertNotAfter = $future; SignInOk = $false; SignInError = 'AADSTS700016: Application with identifier x was not found in the directory'; Saved = $true }) -join "`n"
Assert-True ($wrongClient -like '*Check Tenant ID and Client ID*') "Format-SetupChecklist: an unknown Client ID isn't blamed on the certificate" $wrongClient

# =================================================================
# Step runner (code\Runner\Invoke-AppStep.ps1) - run for real, in a child
# PowerShell, the way the app starts every background step
# =================================================================
$runnerPath = [System.IO.Path]::Combine("$repoRoot", "code", "Runner", "Invoke-AppStep.ps1")
$hostExe = (Get-Process -Id $PID).Path
$runnerDir = Join-Path ([System.IO.Path]::GetTempPath()) ("runner-test-" + [guid]::NewGuid().ToString("N"))
[void](New-Item -ItemType Directory -Path $runnerDir -Force)
try {
    $writeSpec = {
        param([hashtable]$Data)
        $path = Join-Path $runnerDir ([guid]::NewGuid().ToString("N") + ".json")
        [System.IO.File]::WriteAllText($path, ($Data | ConvertTo-Json -Depth 4))
        return $path
    }
    # A step script with a parameter, output and its own exit code
    $stepPath = Join-Path $runnerDir "step's.ps1"
    Set-Content -LiteralPath $stepPath -Value 'param([string]$ConfigPath) "got $ConfigPath"; Write-Warning "careful"; exit 3'
    $helperPath = Join-Path $runnerDir "helper.ps1"
    Set-Content -LiteralPath $helperPath -Value 'function Write-GraphReadSummary { "[GRAPH] summary" }'
    $logPath = Join-Path $runnerDir "step.log"
    $spec = & $writeSpec @{ Script = $stepPath; Parameters = @{ ConfigPath = 'C:\with space\x.json' }; GraphHelper = $helperPath; LogFile = $logPath }
    & $hostExe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $runnerPath -Spec $spec | Out-Null
    $stepExit = $LASTEXITCODE
    $stepLog = Get-Content -LiteralPath $logPath -Raw
    Assert-Equal 3 $stepExit "Invoke-AppStep: the step's own exit code is the process's"
    Assert-True ($stepLog -like '*got C:\with space\x.json*') "Invoke-AppStep: parameters reach the step as values" $stepLog
    Assert-True ($stepLog -like '*careful*') "Invoke-AppStep: warnings land in the log too" $stepLog
    Assert-True ($stepLog -like '*`[GRAPH`] summary*') "Invoke-AppStep: the Graph helper's summary runs after the step" $stepLog
    Assert-True (-not (Test-Path -LiteralPath $spec)) "Invoke-AppStep: the spec file is deleted once read"

    # The injection this replaced: a typographic quote in an app name closed
    # the quoted value and ran what followed. As a value, it's just text.
    $rq = [string][char]0x2019
    $evilName = "x$rq;exit 7;$rq"
    $echoPath = Join-Path $runnerDir "echo.ps1"
    Set-Content -LiteralPath $echoPath -Value 'param([string]$SingleFolderName, [switch]$Force) "name=$SingleFolderName force=$Force"; exit 0'
    $evilLog = Join-Path $runnerDir "evil.log"
    $evilSpec = & $writeSpec @{ Script = $echoPath; Parameters = @{ SingleFolderName = $evilName; Force = $true }; LogFile = $evilLog }
    & $hostExe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $runnerPath -Spec $evilSpec | Out-Null
    Assert-Equal 0 $LASTEXITCODE "Invoke-AppStep: a typographic quote in a parameter doesn't break out and run code"
    Assert-True ((Get-Content -LiteralPath $evilLog -Raw -Encoding UTF8).Contains("name=$evilName force=True")) "Invoke-AppStep: the value arrives unchanged and a switch is set" (Get-Content -LiteralPath $evilLog -Raw)

    $cmdSpec = & $writeSpec @{ Command = "'first'; 'RESULT=ok 1.2'" }
    $cmdOut = @(& $hostExe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $runnerPath -Spec $cmdSpec)
    Assert-Equal 'RESULT=ok 1.2' ([string]$cmdOut[-1]) "Invoke-AppStep: a command without a log file answers on stdout"

    $exitSpec = & $writeSpec @{ Command = "'[OK] done'; exit 0"; LogFile = (Join-Path $runnerDir "cmd.log") }
    & $hostExe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $runnerPath -Spec $exitSpec | Out-Null
    Assert-Equal 0 $LASTEXITCODE "Invoke-AppStep: a command's exit code comes through"
    Assert-True ((Get-Content -LiteralPath (Join-Path $runnerDir "cmd.log") -Raw) -like '*`[OK`] done*') "Invoke-AppStep: a command's output goes to its log file"

    $emptySpec = & $writeSpec @{ LogFile = (Join-Path $runnerDir "empty.log") }
    & $hostExe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $runnerPath -Spec $emptySpec | Out-Null
    Assert-Equal 1 $LASTEXITCODE "Invoke-AppStep: a spec with nothing to run fails"
}
finally {
    Remove-Item -LiteralPath $runnerDir -Recurse -Force -ErrorAction SilentlyContinue
}
# And nothing in the app starts PowerShell the old way any more.
$encodedLaunches = @(Get-ChildItem -Path (Join-Path $repoRoot "code\Private"), (Join-Path $repoRoot "code\Web") -Recurse -Filter *.ps1 |
    Select-String -Pattern '-EncodedCommand\s*"?\s*\+|-EncodedCommand \$' | ForEach-Object { "$($_.Filename):$($_.LineNumber)" })
Assert-Equal 0 $encodedLaunches.Count "No -EncodedCommand launches left in the app" ($encodedLaunches -join ', ')

# A path held in a variable goes to file commands as -LiteralPath: with -Path
# (or none), [ and ] in a folder or app name are wildcards and the file is
# silently not found.
$wildcardPaths = @(Get-ChildItem -Path (Join-Path $repoRoot "code") -Recurse -Filter *.ps1 | Where-Object { $_.FullName -notmatch '[\\/]tests[\\/]' } |
    Select-String -Pattern '\b(Test-Path|Get-Item|Remove-Item|Get-Content|Set-Content|Add-Content|Get-ChildItem|Copy-Item|Move-Item)\s+(-Path\s+)?\$\w' |
    ForEach-Object { "$($_.Filename):$($_.LineNumber)" })
Assert-Equal 0 $wildcardPaths.Count "File commands take variable paths as -LiteralPath" ($wildcardPaths -join ', ')


# =================================================================
# winget output (Winget.ps1)
# =================================================================
$wingetTable = @"
   - \ |
Name                          Id                          Version      Match            Source
------------------------------------------------------------------------------------------------
Notepad++                     Notepad++.Notepad++         8.6.9        Tag: notepad     winget
Visual Studio Code            Microsoft.VisualStudioCode  1.95.3       Moniker: vscode  winget
Some App With A Very Long Nam Vendor.LongName             2.0                           winget
"@
$wingetRows = @(ConvertFrom-WingetSearchOutput $wingetTable)
Assert-Equal 3 $wingetRows.Count "winget search: one row per package, header, rule and spinner skipped"
Assert-Equal "Microsoft.VisualStudioCode" $wingetRows[1].Id "winget search: the ID column, found by the header's position"
Assert-Equal "Visual Studio Code" $wingetRows[1].Name "winget search: names with spaces stay whole"
Assert-Equal "1.95.3" $wingetRows[1].Version "winget search: version stops where Match begins"
Assert-Equal "winget" $wingetRows[2].Source "winget search: a row without a Match value still has its source"
Assert-Equal 0 @(ConvertFrom-WingetSearchOutput "No package found matching input criteria.").Count "winget search: no table, no rows"
$found = Get-WingetShowVerdict -ExitCode 0 -StdOut "Found Notepad++ [Notepad++.Notepad++]`nVersion: 8.6.9`nPublisher: Notepad++ Team`n" -StdErr ""
Assert-True ($found.Ok -and $found.Result -eq "Found (Notepad++ Team)") "winget show: a known ID, with its publisher"
Assert-Equal "8.6.9" $found.Version "winget show: the version winget offers"
Assert-Equal 1 (Compare-AppVersionText '24.9' '24.10') "Compare-AppVersionText: 24.10 is newer than 24.9 (numbers, not text)"
Assert-Equal 0 (Compare-AppVersionText '8.6' '8.6.0') "Compare-AppVersionText: 8.6 and 8.6.0 are the same"
Assert-Equal -1 (Compare-AppVersionText '131.0.2' '131.0.1') "Compare-AppVersionText: an older winget version"
Assert-Equal 1 (Compare-AppVersionText '' '1.0') "Compare-AppVersionText: no catalog version - winget's counts as newer"
Assert-True ($null -eq (Compare-AppVersionText '1.0' '')) "Compare-AppVersionText: no winget version - unknown"
Assert-Equal 1 (Compare-AppVersionText '1.0-beta' '1.0') "Compare-AppVersionText: the release is newer than its pre-release"
Assert-Equal 0 (Compare-AppVersionText 'v1.2' '1.2') "Compare-AppVersionText: a leading v is ignored"
Assert-Equal 1 (Compare-AppVersionText '1.99999999999999999999999999999' '1.100000000000000000000000000000') "Compare-AppVersionText: very long numbers don't overflow"
Assert-Equal 1 (Compare-AppVersionText '1.0-beta' '1.0-rc') "Compare-AppVersionText: text parts compared as text"
$gone = Get-WingetShowVerdict -ExitCode -1978335212 -StdOut "No package found matching input criteria." -StdErr ""
Assert-True ((-not $gone.Ok) -and $gone.Result -like "NOT FOUND*") "winget show: an unknown ID reads NOT FOUND (what Get-WingetFindings looks for)"
$odd = Get-WingetShowVerdict -ExitCode 5 -StdOut "  - \`nSource agreement required" -StdErr ""
Assert-True ((-not $odd.Ok) -and $odd.Result -like "Could not check (exit code 5): Source agreement required") "winget show: anything else says it couldn't check, with winget's first real line"


# =================================================================
# Diagnostics (Diagnostics.ps1)
# =================================================================
$diagApps = @(
    [pscustomobject]@{ appName = 'Fresh'; wingetId = 'A.B'; appId = ''; metadata = $null; intuneAppType = ''; requiredFor = @(); availableFor = @(); uninstallFor = @(); packagePath = '' }
    [pscustomobject]@{ appName = 'Own Tool'; wingetId = ''; appId = ''; metadata = $null; intuneAppType = ''; requiredFor = @(); availableFor = @(); uninstallFor = @(); packagePath = '' }
    [pscustomobject]@{ appName = 'Live'; wingetId = 'C.D'; appId = 'id-1'; metadata = [pscustomobject]@{}; intuneAppType = ''; requiredFor = @(); availableFor = @(); uninstallFor = @(); packagePath = '' }
    [pscustomobject]@{ appName = 'live '; wingetId = 'E.F'; appId = 'ID-1'; metadata = [pscustomobject]@{}; intuneAppType = 'Win32'; requiredFor = @('SG'); availableFor = @(); uninstallFor = @(); packagePath = 'D:\pkgs\Custom\x.intunewin' }
)
$diagFolders = @(@{ Name = 'Own-Tool'; FullName = 'C:\p\Own-Tool' }, @{ Name = 'Old-App'; FullName = 'C:\p\Old-App' }, @{ Name = 'Custom'; FullName = 'D:\pkgs\Custom' })
$diag = @(Get-CatalogDiagnosticLines -Apps $diagApps -PackageFolders $diagFolders)
Assert-Equal 7 $diag.Count "Diagnostics: one line per catalog check"
Assert-True ($diag[0].Level -eq 'warn' -and @($diag[0].Items).Count -eq 2) "Diagnostics: apps with nothing to deploy are listed"
Assert-True ($diag[1].Level -eq 'warn' -and @($diag[1].Items) -contains 'Own Tool') "Diagnostics: an app with its own package and no settings is named"
Assert-True ($diag[2].Level -eq 'info' -and @($diag[2].Items) -contains 'Live') "Diagnostics: a deployed app never read back is info, not a problem"
Assert-True ($diag[3].Level -eq 'warn' -and @($diag[3].Items) -contains 'Live' -and @($diag[3].Items) -notcontains 'live ') "Diagnostics: a deployed app assigned to nobody"
Assert-True ($diag[4].Level -eq 'failed') "Diagnostics: names that differ only in case and spacing are duplicates"
Assert-True ($diag[5].Level -eq 'failed') "Diagnostics: App IDs that differ only in case are duplicates"
Assert-True ($diag[6].Level -eq 'info' -and (@($diag[6].Items) -join ',') -eq 'Old-App') "Diagnostics: only the package folder no app uses (by name or by its package path) is a leftover"
Assert-Equal 'ok' (@(Get-CatalogDiagnosticLines -Apps @() -PackageFolders @()))[0].Level "Diagnostics: an empty catalog has nothing to warn about"


# =================================================================
# Security: quoting, secrets in logs, folder paths
# =================================================================
Assert-Equal '"abc"' (ConvertTo-WindowsArgument 'abc') "Windows argument: plain text is quoted"
Assert-Equal '"a b"' (ConvertTo-WindowsArgument 'a b') "Windows argument: a space stays inside one argument"
Assert-Equal '"x\\"' (ConvertTo-WindowsArgument 'x\') "Windows argument: a trailing backslash can't escape the closing quote"
Assert-Equal '"say \"hi\""' (ConvertTo-WindowsArgument 'say "hi"') "Windows argument: quotes are escaped, not dropped"
Assert-Equal '"a\\\"b"' (ConvertTo-WindowsArgument 'a\"b') "Windows argument: backslashes before a quote are doubled"
Assert-Equal '"C:\dir\x"' (ConvertTo-WindowsArgument 'C:\dir\x') "Windows argument: backslashes elsewhere stay as they are"
Assert-Equal '""' (ConvertTo-WindowsArgument '') "Windows argument: empty is an empty argument"

$sasLine = 'PUT https://x.blob.core.windows.net/c/f?sv=2024-01-01&se=2026&sig=AbC%2Fdef123%3D&sp=w failed'
$hidden = Protect-LogText $sasLine
Assert-True ($hidden -notmatch 'AbC' -and $hidden -like '*sig=`[hidden`]&sp=w failed*') "Log text: a signed URL's signature is hidden, the rest kept" $hidden
Assert-True ((Protect-LogText 'Authorization: Bearer eyJ0eXAiOiJKV1QiLCJhbGciOi.abc') -notmatch 'eyJ0eXAi') "Log text: a bearer token is hidden"
$jwt = 'token eyJhbGciOiJSUzI1NiJ9.eyJhdWQiOiJodHRwczovL2dyYXBo.c2lnbmF0dXJlLXBhcnQ end'
Assert-Equal 'token [token hidden] end' (Protect-LogText $jwt) "Log text: a JSON Web Token on its own is hidden"
Assert-True ((Protect-LogText 'client_secret=s3cr3t&x=1') -eq 'client_secret=[hidden]&x=1') "Log text: client_secret values are hidden"
Assert-True ((Protect-LogText '{"password": "hunter2"}') -notmatch 'hunter2') "Log text: a password in JSON is hidden"
Assert-Equal '[OK] Deployed 7-Zip (App ID 0f0e)' (Protect-LogText '[OK] Deployed 7-Zip (App ID 0f0e)') "Log text: ordinary lines are untouched"

Assert-Equal '' (Test-AppFolderPath '') "Folder path: empty means the default"
Assert-Equal '' (Test-AppFolderPath 'D:\intune\packages') "Folder path: a drive path is fine"
Assert-Equal '' (Test-AppFolderPath '\\fileserver\share\catalog') "Folder path: a share is fine"
Assert-True ([bool](Test-AppFolderPath 'data\apps')) "Folder path: a relative path is refused"
Assert-True ([bool](Test-AppFolderPath 'C:\a" & calc')) "Folder path: a quote is refused"
Assert-True ([bool](Test-AppFolderPath 'C:\apps\*')) "Folder path: a wildcard is refused"
Assert-True ([bool](Test-AppFolderPath "C:\apps`nX")) "Folder path: a control character is refused"
Assert-True ([bool](Test-AppFolderPath 'C:\apps\..\Windows')) "Folder path: .. is refused"
Assert-True ([bool](Test-AppFolderPath ('C:\' + ('x' * 300)))) "Folder path: a path that is too long is refused"

# Group lookups by name (Checks)
$lookup = @(Get-GroupLookupUris -Names @(1..20 | ForEach-Object { "SG-$_" }))
Assert-Equal 2 $lookup.Count "Group lookup: 20 names in requests of 15"
$firstFilter = [Uri]::UnescapeDataString(($lookup[0] -split '\$filter=')[1].Split('&')[0])
Assert-True ($firstFilter -like "displayName in ('SG-1','SG-2',*'SG-15')") "Group lookup: the names in an OData in-list" $firstFilter
$quoted = [Uri]::UnescapeDataString(@(Get-GroupLookupUris -Names @("O'Brien Team"))[0])
Assert-True ($quoted -like "*('O''Brien Team')*") "Group lookup: a quote in a name is doubled for OData" $quoted
Assert-Equal 0 @(Get-GroupLookupUris -Names @()).Count "Group lookup: no names, no requests"

# The app window's browser profile settings
$fresh = Get-AppWindowPreferencesJson -Existing '' | ConvertFrom-Json
Assert-True ($fresh.translate.enabled -eq $false -and $fresh.credentials_enable_service -eq $false -and $fresh.profile.password_manager_enabled -eq $false) "Window preferences: translation and the password manager off"
Assert-True ($fresh.autofill.enabled -eq $false -and $fresh.autofill.profile_enabled -eq $false -and $fresh.sync.requested -eq $false) "Window preferences: autofill and sync off"
Assert-True ($fresh.browser.enable_spellchecking -eq $false -and $fresh.spellcheck.use_spelling_service -eq $false) "Window preferences: spelling correction off"
$kept = Get-AppWindowPreferencesJson -Existing '{"profile":{"name":"X","password_manager_enabled":true},"extensions":{"ui":1},"translate":"odd"}' | ConvertFrom-Json
Assert-True ($kept.profile.name -eq 'X' -and $kept.extensions.ui -eq 1 -and $kept.profile.password_manager_enabled -eq $false -and $kept.translate.enabled -eq $false) "Window preferences: what the browser stored stays, ours is set (even over an odd value)"
$unreadable = Get-AppWindowPreferencesJson -Existing '{not json' | ConvertFrom-Json
Assert-True ($unreadable.translate.enabled -eq $false) "Window preferences: an unreadable file is replaced, not a failure"

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
