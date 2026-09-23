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
    "Get-ComparableDetectionRule",
    "ConvertTo-CatalogMetadataFromFetch",
    "Get-WingetIdFromInstallCommand",
    "Get-FirstWingetIdToken",
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
    # The other half of that round trip. Pure string building - it writes
    # JSON field by field rather than serialising, which is exactly why it
    # is worth a test.
    "ConvertTo-SingleAppJson",
    "ConvertTo-JsonStringArray",
    # Write-DialogLogLine and Write-DialogError are deliberately NOT here.
    # Their parameters are typed [System.Windows.Forms.RichTextBox] and
    # [Label], and this suite loads no WinForms and runs on Linux - so
    # whether they bind at all depends on the machine. They did on mine
    # and did not on CI, which is exactly the claim this list is supposed
    # to make. Their null-box guards are covered by DeployDefaults, which
    # runs inside the real app.
    "Get-DialogLogLineColor",
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
    # Plain-language Graph errors (GuiHelpers.ps1)
    "Get-GraphPermissionHint",
    "ConvertTo-FriendlyGraphError",
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
    # Moving a group of controls onto its own tab (GuiHelpers.ps1) - pure maths
    "Get-ControlGroupOrigin",
    # Deleting several groups at once (GuiHelpers.ps1) - pure planning work
    "Get-GroupDeletionPlan",
    "Format-GroupDeletionWarning",
    # What the token is allowed to do (GraphToken.ps1) - pure claim work
    "ConvertFrom-JwtPayload",
    "Get-GraphRoleRequirements",
    "Get-GraphRoleReport",
    "Format-GraphRoleReport",
    "Get-GraphErrorBodyMessage",
    "Get-GraphErrorRecordMessage",
    "Get-GraphRunspaceErrorMessage",
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
# Moving a group of controls onto its own tab (GuiHelpers.ps1)
# -----------------------------------------------------------------
# A group that sat 600px down a tall panel has to start at the top of its
# own page, which means subtracting where the group actually began.
$origin = Get-ControlGroupOrigin -Points @(@{ X = 595; Y = 612 }, @{ X = 15; Y = 275 }, @{ X = 995; Y = 941 })
Assert-Equal 15 $origin.X "Get-ControlGroupOrigin: the leftmost edge of the group"
Assert-Equal 275 $origin.Y "Get-ControlGroupOrigin: the topmost edge of the group"
$emptyOrigin = Get-ControlGroupOrigin -Points @()
Assert-Equal 0 $emptyOrigin.X "Get-ControlGroupOrigin: an empty group starts at zero, not an error"
Assert-Equal 0 $emptyOrigin.Y "Get-ControlGroupOrigin: an empty group starts at zero, not an error"
$oneOrigin = Get-ControlGroupOrigin -Points @(@{ X = 42; Y = 7 })
Assert-Equal 42 $oneOrigin.X "Get-ControlGroupOrigin: one control is its own origin"

# -----------------------------------------------------------------
# Deleting several groups at once (GuiHelpers.ps1)
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

# -----------------------------------------------------------------
# Which permission a refused request needs (GuiHelpers.ps1)
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
$fromStreams = Get-GraphRunspaceErrorMessage @($forbiddenRecord)
Assert-True ($fromStreams -like "*Add DeviceManagementScripts.Read.All or DeviceManagementScripts.ReadWrite.All*") `
    "Get-GraphRunspaceErrorMessage: a refused read names the scopes to add" $fromStreams

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
# fresh, and resolved through a prebuilt index - because Update-Grid now
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
}
finally {
    $Global:App.RootPath = $savedRootPath
    $Global:App.AppFolders = $savedAppFolders
    Remove-Item -LiteralPath $pkgTestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# -----------------------------------------------------------------
# Write-DialogLogLine / Write-DialogError with nothing to write to
# -----------------------------------------------------------------
# A -LogBox that arrives $null is this codebase's recurring closure bug
# showing up at the call site: an alias taken one level too high comes
# back empty. It used to throw "The property 'SelectionStart' cannot be
# found on this object" at the user - three times in a row in one
# report - and take the message it was carrying with it.
#
# These two helpers are the funnel every dialog's log goes through, so
# guarding them turns that whole class of bug from a crash into a line
# in the main log.
# Asserted in DeployDefaults instead, inside the real app: these two take
# WinForms controls as parameters, so whether they can even be called
# depends on WinForms being present - which it is not here, and is not on
# the Linux leg of CI. Testing them from this suite passed locally and
# failed everywhere else, which is the failure this list exists to stop.

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
