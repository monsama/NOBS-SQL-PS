# Tests for Get-BatchFailureNote - the sentence appended to the log when a batch wrapped in
# START TRANSACTION/COMMIT comes back non-zero from mysql.exe.
#
# Two quite different failures arrive at the same place, and only one of them can be described
# with any confidence:
#
#   A statement failed. mysql.exe stops at the first error, so it never reached the COMMIT, and
#   the server discards the open transaction when the connection closes. Nothing was applied.
#
#   The connection died. The exit code then says only that we stopped hearing back. If it broke
#   while the COMMIT was in flight the server may have completed it regardless and simply had
#   nowhere to send the acknowledgement. There is no way to tell from here.
#
# The message used to be "No rows were updated - the batch was rolled back." unconditionally. In
# the second case that is a guess stated as a fact, and the reassuring one - it is what would send
# someone off to apply the same changes a second time.
#
#   pwsh -NoProfile -File tests/BatchFailureNote.Tests.ps1 ./NOBSSQL.ps1

param([Parameter(Mandatory)][string]$ScriptPath)

$e=$null;$t=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile($ScriptPath,[ref]$t,[ref]$e)
if($e -and $e.Count){ "PARSE ERRORS: $($e.Count)"; exit 1 }
$ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                        $n.Name -eq 'Get-BatchFailureNote'},$true) |
  ForEach-Object { Invoke-Expression $_.Extent.Text }

$fail = 0
function RolledBack($err, $label) {
  $got = Get-BatchFailureNote $err
  if ($got -notmatch 'rolled back') { "  FAIL  $label -> expected a rollback claim, got: $got"; $script:fail++ }
  else { "  ok    $label" }
}
function Uncertain($err, $label) {
  $got = Get-BatchFailureNote $err
  if ($got -match 'rolled back') { "  FAIL  $label -> claimed a rollback it cannot verify: $got"; $script:fail++ }
  elseif ($got -notmatch '(?i)may|check') { "  FAIL  $label -> did not say the outcome is uncertain: $got"; $script:fail++ }
  else { "  ok    $label" }
}

"-- a statement failed: the batch really did stop before COMMIT --"
RolledBack "ERROR 1062 (23000) at line 3: Duplicate entry '7' for key 'PRIMARY'" 'duplicate key'
RolledBack "ERROR 1054 (42S22) at line 1: Unknown column 'nope' in 'field list'"  'unknown column'
RolledBack "ERROR 1452 (23000): Cannot add or update a child row"                  'foreign key'
RolledBack "ERROR 1406 (22001): Data too long for column 'x' at row 1"             'data too long'
RolledBack ""                                                                      'no error text at all'

"`n-- the connection went away: we genuinely do not know whether the commit landed --"
Uncertain "ERROR 2013 (HY000): Lost connection to MySQL server during query"       'lost connection'
Uncertain "ERROR 2006 (HY000): MySQL server has gone away"                         'server has gone away'
Uncertain "ERROR 2003 (HY000): Can't connect to MySQL server on '10.0.0.5'"        "can't connect"
Uncertain "ERROR 2013 (HY000): Lost connection to server during query"             'lost connection, MariaDB wording'
Uncertain "write: broken pipe"                                                     'broken pipe'
Uncertain "ERROR 2013: Connection reset by peer"                                   'connection reset'

"`n-- the wording is the point, so check it is actually actionable --"
$note = Get-BatchFailureNote "ERROR 2013 (HY000): Lost connection to MySQL server during query"
if ($note -notmatch '(?i)check the table') { "  FAIL  the uncertain note should tell the user to go and look: $note"; $fail++ }
else { "  ok    it says to check the table before re-applying" }

if ($fail) { "`n  $fail FAILED"; exit 1 } else { "`n  all passed"; exit 0 }
