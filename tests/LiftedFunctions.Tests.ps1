# Checks that a test which lifts functions out of NOBSSQL.ps1 lifts what they call.
#
# Several tests here run real code by pulling named functions out of the script with the parser.
# When one of those functions grows a call to another one, the test keeps passing - PowerShell
# reports "The term 'X' is not recognized" and carries on, and a run that prints a wall of red text
# can still end with "all passed". It happened twice in one day: New-Cnf gained a call to
# Get-BrowseCharset, and Api-DownloadMysqlTools called Get-MysqlDownloadDefaults in a step that
# only runs weekly, so nothing noticed for a day.
#
# The rule is "lift what you call": every function defined in the script and called by a lifted
# function must be lifted too. It is conservative on purpose - a call on a path the test never takes
# still has to be named, which costs a word and removes a way to be wrong.
#
#   pwsh -NoProfile -File tests/LiftedFunctions.Tests.ps1 ./NOBSSQL.ps1

param([Parameter(Mandatory)][string]$ScriptPath)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ScriptPath)) { "  FAIL  script not found: $ScriptPath"; exit 1 }

$e = $null; $t = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $ScriptPath).Path, [ref]$t, [ref]$e)
if ($e -and $e.Count) { $e | ForEach-Object { "  PARSE ERROR  line $($_.Extent.StartLineNumber): $($_.Message)" }; exit 1 }

$defined = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
$names = $defined | ForEach-Object { $_.Name }

$here = Split-Path -Parent $PSCommandPath
$fail = 0; $checked = 0

foreach ($file in Get-ChildItem (Join-Path $here '*.Tests.ps1') | Sort-Object Name) {
    if ($file.Name -eq (Split-Path -Leaf $PSCommandPath)) { continue }
    $text = [IO.File]::ReadAllText($file.FullName)

    # The lists these tests are written with: $n.Name -in @('A','B',...) and $n.Name -eq 'A'.
    $lifted = @()
    foreach ($m in [regex]::Matches($text, '\$n\.Name\s+-in\s+@\(([^)]*)\)')) {
        $lifted += [regex]::Matches($m.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }
    }
    foreach ($m in [regex]::Matches($text, "\`$n\.Name\s+-eq\s+'([^']+)'")) { $lifted += $m.Groups[1].Value }
    # A test that lifts every function there is has nothing to miss. It has to be lifting them,
    # though: two of these also walk every definition to check something about the script itself,
    # and skipping those for the walk would skip the list beside it.
    if ($text -match '(?s)FunctionDefinitionAst\]\s*\},\s*\$true\)\s*\|\s*[\r\n ]*ForEach-Object\s*\{\s*Invoke-Expression') { continue }
    if (-not $lifted.Count) { continue }
    $lifted = $lifted | Sort-Object -Unique
    $checked++

    $missing = foreach ($f in $defined | Where-Object { $lifted -contains $_.Name }) {
        $f.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
            ForEach-Object { $_.GetCommandName() } |
            Where-Object { $_ -and ($names -contains $_) -and ($lifted -notcontains $_) }
    }
    $missing = @($missing | Sort-Object -Unique)

    if ($missing.Count) {
        "  FAIL  $($file.Name) lifts $($lifted.Count) function(s) and calls $($missing -join ', '), which it does not lift"
        $fail++
    } else {
        "  ok    $($file.Name) lifts what its $($lifted.Count) function(s) call"
    }
}

if (-not $checked) { "  FAIL  no test was found that lifts functions - has the way they do it changed?"; exit 1 }
if ($fail) { "`n  $fail FAILED"; exit 1 } else { "`n  all $checked passed"; exit 0 }
