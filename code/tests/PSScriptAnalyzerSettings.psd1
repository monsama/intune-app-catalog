# The rules CI runs over code/ (tests.yml, job "lint"). Bug-catchers only,
# not style: each of these points at code that does something other than
# it seems to. Style rules (aliases, verbs, Write-Host, globals - the app
# uses $Global:App on purpose) are left out deliberately.
@{
    IncludeRules = @(
        'PSPossibleIncorrectComparisonWithNull'          # $x -eq $null filters arrays instead of testing
        'PSPossibleIncorrectUsageOfAssignmentOperator'   # if ($a = $b)
        'PSPossibleIncorrectUsageOfRedirectionOperator'  # if ($a > $b)
        'PSMisleadingBacktick'                           # a backtick followed by a space continues nothing
        'PSAvoidAssignmentToAutomaticVariable'           # $input, $args, $matches, ... overwritten
        'PSUseDeclaredVarsMoreThanAssignments'           # assigned and never read - often a typo'd name
        'PSAvoidDefaultValueSwitchParameter'
        'PSAvoidNullOrEmptyHelpMessageAttribute'
        'PSReservedCmdletChar'
        'PSReservedParams'
        'PSUseCompatibleSyntax'                          # syntax Windows PowerShell 5.1 can't parse
    )
    Rules = @{
        PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('5.1', '7.0') }
    }
}
