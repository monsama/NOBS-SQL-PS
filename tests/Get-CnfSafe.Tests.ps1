# Tests for Get-CnfSafe, which strips embedded newlines from a saved connection's host/user/
# password before they're written into the temp .cnf file mysql/mysqldump are pointed at - an
# unstripped newline there could inject an arbitrary extra option-file directive.
#
#   pwsh -NoProfile -File tests/Get-CnfSafe.Tests.ps1 ./NOBSSQL.ps1

param([Parameter(Mandatory)][string]$ScriptPath)

$e=$null;$t=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $ScriptPath).Path,[ref]$t,[ref]$e)
if($e -and $e.Count){ $e | ForEach-Object { "  PARSE ERROR  line $($_.Extent.StartLineNumber): $($_.Message)" }; exit 1 }
$ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-CnfSafe'},$true) |
  ForEach-Object { Invoke-Expression $_.Extent.Text }
$fail = 0
function Check($input_, $expected, $label) {
  $got = Get-CnfSafe $input_
  if ($got -ne $expected) { "  FAIL  $label -> got '$got', want '$expected'"; $script:fail++ }
  else { "  ok    $label" }
}
Check 'normal-host' 'normal-host' 'plain value unchanged'
Check "evil`npager=touch /tmp/pwned" 'evilpager=touch /tmp/pwned' 'embedded LF stripped'
Check "evil`r`nmore" 'evilmore' 'embedded CRLF stripped'
Check '' '' 'empty value stays empty'
if ($fail) { "`n  $fail FAILED"; exit 1 } else { "`n  all passed"; exit 0 }
