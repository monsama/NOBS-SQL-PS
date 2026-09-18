# Tests for Test-SqlReadOnly, the server-side gate behind a connection's read-only / safe mode.
# It is the safety net people rely on when pointing this at a production server, so its
# behaviour is pinned here rather than trusted.
#
#   pwsh -NoProfile -File tests/Test-SqlReadOnly.Tests.ps1 ./NOBSSQL.ps1
#
# The function is lifted out of the script by the parser so the test does not start a server.

param([Parameter(Mandatory)][string]$ScriptPath)

$e=$null;$t=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $ScriptPath).Path,[ref]$t,[ref]$e)
if($e -and $e.Count){ $e | ForEach-Object { "  PARSE ERROR  line $($_.Extent.StartLineNumber): $($_.Message)" }; exit 1 }
$ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and ($n.Name -eq 'Test-SqlReadOnly' -or $n.Name -eq 'Split-OffKeyword' -or $n.Name -eq 'Strip-Parens')},$true) |
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

# SELECT is allow-listed, and INTO OUTFILE / INTO DUMPFILE hang off a SELECT. They write no table
# data - they write a FILE, on the database server, as the mysqld user. Verified against a live
# MariaDB with an empty secure_file_priv: read-only mode called the statement allowed and the file
# appeared on disk with the expected contents.
Check "SELECT * FROM t INTO OUTFILE '/tmp/x.csv'" $false 'SELECT INTO OUTFILE blocked'
Check "SELECT * FROM t INTO DUMPFILE '/tmp/x.bin'" $false 'SELECT INTO DUMPFILE blocked'
Check "select 1 into outfile '/tmp/x'" $false 'lower-case INTO OUTFILE blocked'
Check "SELECT * INTO OUTFILE '/tmp/x' FROM t" $false 'INTO OUTFILE before FROM blocked'
Check "WITH x AS (SELECT 1) SELECT * FROM x INTO OUTFILE '/tmp/x'" $false 'CTE-prefixed INTO OUTFILE blocked'
Check "SELECT 1; SELECT * FROM t INTO OUTFILE '/tmp/x'" $false 'INTO OUTFILE in a later statement blocked'
# ...but an assignment, a string that merely contains the words, and a column of that name are fine.
Check 'SELECT COUNT(*) INTO @n FROM t' $true 'SELECT INTO @var still allowed'
Check "SELECT 'INTO OUTFILE' AS s" $true 'the words inside a string are not a clause'
Check 'SELECT outfile FROM t' $true 'a column called outfile is not the clause'

# Account management. The Users dialog builds these client-side and sends them through the same
# /api/exec route as any other statement, so read-only has to stop them here - there is nothing
# else between that dialog and the server. None of these verbs are on the allow-list, so they are
# blocked by default; these pin that, because an allow-list gaining a new entry is exactly the
# kind of change that would quietly let them through.
Check "CREATE USER 'u'@'%' IDENTIFIED BY 'p'" $false 'CREATE USER blocked'
Check "DROP USER 'u'@'%'" $false 'DROP USER blocked'
Check "ALTER USER 'u'@'%' ACCOUNT LOCK" $false 'ALTER USER blocked'
Check "GRANT SELECT ON d.* TO 'u'@'%'" $false 'GRANT blocked'
Check "REVOKE SELECT ON d.* FROM 'u'@'%'" $false 'REVOKE blocked'
Check 'FLUSH PRIVILEGES' $false 'FLUSH PRIVILEGES blocked'
Check "SET PASSWORD FOR 'u'@'%' = PASSWORD('x')" $false 'SET PASSWORD blocked - SET is allow-listed, this form must not be'
Check "SET PASSWORD = PASSWORD('x')" $false 'SET PASSWORD for the current user blocked too'
Check "SET DEFAULT ROLE admin FOR 'u'@'%'" $false 'SET DEFAULT ROLE blocked'

# MariaDB's SET STATEMENT <assignments> FOR <statement> EXECUTES the statement it wraps, exactly
# like the ANALYZE form below. Verified against a live server: "... FOR DELETE FROM t" emptied the
# table while read-only mode reported the statement as allowed.
Check 'SET STATEMENT max_statement_time=1 FOR DELETE FROM t' $false 'SET STATEMENT-wrapped DELETE blocked'
Check 'SET STATEMENT max_statement_time=1 FOR DROP TABLE t' $false 'SET STATEMENT-wrapped DROP blocked'
Check 'SET STATEMENT a=1, b=2 FOR UPDATE t SET x=1' $false 'SET STATEMENT-wrapped UPDATE blocked'
Check 'SET STATEMENT max_statement_time=1 FOR SELECT 1' $true 'SET STATEMENT-wrapped SELECT still allowed'
Check 'SET STATEMENT max_statement_time=1' $false 'SET STATEMENT with no FOR is refused, not guessed at'
Check "SET STATEMENT x='FOR' FOR DELETE FROM t" $false 'a FOR inside a string is not the separator'

# The guard is worthless if it makes read-only mode unusable for real work.
Check 'SET NAMES utf8mb4' $true 'SET NAMES allowed'
Check 'SET @x = 1' $true 'user variable allowed'

# Schema changes from the table designer and the DDL editor, which take the same route.
Check 'ALTER TABLE t ADD COLUMN c INT' $false 'designer ALTER blocked'
Check 'ALTER TABLE t DROP COLUMN c' $false 'designer DROP COLUMN blocked'
Check 'RENAME TABLE a TO b' $false 'RENAME TABLE blocked'
Check 'CREATE TABLE t (a INT)' $false 'designer CREATE TABLE blocked'
Check 'SHOW CREATE TABLE t' $true 'reading a table DDL is still allowed'
if ($fail) { "`n  $fail FAILED"; exit 1 } else { "`n  all passed"; exit 0 }
