# Tests for Get-BrowseCharset, which decides what this app will ask a server to send text in.
#
# The value goes into a client options file and onto a command line, so it is matched against a
# list of character sets rather than a pattern: anything else is not a charset and is ignored. The
# same list is in the desktop edition (BROWSE_CHARSETS in main.rs), so neither edition can widen
# what the other accepts.
#
# It decides one more thing: a connection browsing in another charset is read-only, because what is
# shown is not what a write would store. That gate reads this function, so a value slipping through
# would take the gate with it.
#
#   pwsh -NoProfile -File tests/BrowseCharset.Tests.ps1 ./NOBSSQL.ps1

param([Parameter(Mandatory)][string]$ScriptPath)

if (-not (Test-Path $ScriptPath)) { "  FAIL  script not found: $ScriptPath"; exit 1 }

$e=$null;$t=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $ScriptPath).Path,[ref]$t,[ref]$e)
if($e -and $e.Count){ $e | ForEach-Object { "  PARSE ERROR  line $($_.Extent.StartLineNumber): $($_.Message)" }; exit 1 }

# The list is a script-level assignment, not a function, so it is lifted by name rather than found
# among the function definitions.
$listLine = ($ast.Extent.Text -split "`n" | Select-String -Pattern '^\$script:BrowseCharsets = @\(' | Select-Object -First 1)
if (-not $listLine) { "  FAIL  `$script:BrowseCharsets is not where this test expects it"; exit 1 }
$listText = ($ast.EndBlock.Statements | Where-Object {
    $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq '$script:BrowseCharsets'
} | Select-Object -First 1).Extent.Text
Invoke-Expression $listText
$ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-BrowseCharset' }, $true) |
  ForEach-Object { Invoke-Expression $_.Extent.Text }

$fail = 0
function Check { param([bool]$ok, [string]$name, $got) if ($ok) { "  ok    $name" } else { "  FAIL  $name -> $got"; $script:fail++ } }

Check ((Get-BrowseCharset @{ charset = 'latin1' }) -eq 'latin1') 'a charset the server has is accepted'
Check ((Get-BrowseCharset @{ charset = 'BINARY' }) -eq 'binary') 'the name is not case-sensitive' (Get-BrowseCharset @{ charset = 'BINARY' })
Check ((Get-BrowseCharset @{ charset = '  utf8mb4 ' }) -eq 'utf8mb4') 'and is not upset by spaces'

Check ($null -eq (Get-BrowseCharset @{ charset = '' })) 'no charset asked for'
Check ($null -eq (Get-BrowseCharset @{ charset = 'default' })) 'the server default, said out loud'
Check ($null -eq (Get-BrowseCharset @{})) 'a connection with no charset at all'
Check ($null -eq (Get-BrowseCharset $null)) 'no connection at all'

# This ends up in an options file the client reads and on a command line. Nothing that is not a
# charset gets through, so there is nothing to escape - and an options file is line-based, which is
# why a newline is in the list below.
foreach ($bad in @('latin1; DROP DATABASE nobs_test', "latin1`nuser=root", 'latin1"', "utf8mb4'",
                   'latin1 --', '../latin1', 'utf8mb4 -e "SELECT 1"', 'binary`', 'sjis|whoami')) {
    Check ($null -eq (Get-BrowseCharset @{ charset = $bad })) "refused: $($bad -replace "`n", '\n')" (Get-BrowseCharset @{ charset = $bad })
}

# The two editions must ask for the same things: a charset offered here but rejected there would
# read as the app quietly ignoring the choice.
$editorList = $env:NOBS_EDITOR_MAIN_RS
if ($editorList -and (Test-Path $editorList)) {
    $rs = [IO.File]::ReadAllText($editorList)
    $m = [regex]::Match($rs, '(?s)const BROWSE_CHARSETS: &\[&str\] = &\[(.*?)\];')
    if (-not $m.Success) { Check $false 'the editor edition still has BROWSE_CHARSETS' 'not found' }
    else {
        $theirs = [regex]::Matches($m.Groups[1].Value, '"([a-z0-9]+)"') | ForEach-Object { $_.Groups[1].Value }
        $diff = (Compare-Object ($script:BrowseCharsets | Sort-Object) ($theirs | Sort-Object))
        Check (-not $diff) 'the two editions offer the same character sets' (($diff | ForEach-Object { "$($_.SideIndicator) $($_.InputObject)" }) -join ', ')
    }
} else {
    "  skip  the editor's main.rs was not given (NOBS_EDITOR_MAIN_RS), so the two lists were not compared"
}

if ($fail) { "`n  $fail FAILED"; exit 1 } else { "`n  all passed"; exit 0 }
