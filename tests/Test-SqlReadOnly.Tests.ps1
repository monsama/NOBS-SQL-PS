# Tests for Test-SqlReadOnly, the server-side gate behind a connection's read-only / safe mode.
# It is the safety net people rely on when pointing this at a production server, so its
# behaviour is pinned here rather than trusted.
#
#   pwsh -NoProfile -File tests/Test-SqlReadOnly.Tests.ps1 ./NOBSSQL.ps1
#
# The function is lifted out of the script by the parser so the test does not start a server.

param([Parameter(Mandatory)][string]$ScriptPath)

$e=$null;$t=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile($ScriptPath,[ref]$t,[ref]$e)
if($e -and $e.Count){ "PARSE ERRORS: $($e.Count)"; exit 1 }
$ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and ($n.Name -eq 'Test-SqlReadOnly' -or $n.Name -eq 'Strip-Parens')},$true) |
  ForEach-Object { Invoke-Expression $_.Extent.Text }
$fail = 0
function Check($sql, $expected, $label) {
  $got = Test-SqlReadOnly $sql
  if ($got -ne $expected) { "  FAIL  $label -> got $got, want $expected"; $script:fail++ }
  else { "  ok    $label" }
}
Check 'SELECT 1' $true 'plain SELECT allowed'
Check 'SHOW TABLES' $true 'SHOW allowed'
Check 'DELETE FROM t' $false 'DELETE blocked'
Check 'SELECT 1; DELETE FROM t' $false 'DELETE after SELECT blocked'
Check '/* c */ DROP TABLE t' $false 'write behind a comment blocked'
Check '/*!50000 DELETE FROM t */' $false 'executable comment blocked'
Check 'SELECT 1; /*!DROP TABLE t */' $false 'executable comment after SELECT blocked'
Check 'SET autocommit=0' $true 'session SET allowed'
Check 'SET GLOBAL max_connections=1' $false 'SET GLOBAL blocked'
Check 'SET PERSIST max_connections=1' $false 'SET PERSIST blocked'
Check 'SET @@GLOBAL.max_connections=1' $false 'SET @@GLOBAL blocked'
Check 'WITH x AS (SELECT 1) SELECT * FROM x' $true 'CTE-prefixed SELECT allowed'
Check 'WITH x AS (SELECT 1) DELETE FROM t WHERE id IN (SELECT id FROM x)' $false 'CTE-prefixed DELETE blocked'
Check 'WITH x AS (SELECT 1) UPDATE t SET a=1' $false 'CTE-prefixed UPDATE blocked'
Check 'WITH x AS (SELECT 1) INSERT INTO t SELECT * FROM x' $false 'CTE-prefixed INSERT blocked'
Check "WITH x AS (SELECT 1 FROM t WHERE a=')SELECT(') DELETE FROM t" $false 'CTE with paren-in-string still blocks the real DELETE'
Check 'ANALYZE TABLE t' $true 'ANALYZE TABLE allowed'
Check 'ANALYZE SELECT 1' $true 'ANALYZE-wrapped SELECT allowed'
Check 'ANALYZE FORMAT=JSON SELECT * FROM t' $true 'ANALYZE FORMAT=JSON SELECT allowed'
Check 'ANALYZE DELETE FROM t' $false 'ANALYZE-wrapped DELETE blocked'
Check 'ANALYZE INSERT INTO t VALUES (1)' $false 'ANALYZE-wrapped INSERT blocked'
Check 'ANALYZE FORMAT=JSON DELETE FROM t' $false 'ANALYZE FORMAT=JSON DELETE blocked'
if ($fail) { "`n  $fail FAILED"; exit 1 } else { "`n  all passed"; exit 0 }
