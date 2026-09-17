# Live tests: start the real server, drive its real HTTP API against a real database, stop it.
#
# These cover what the other test scripts here cannot reach - the endpoints only exist while the
# server is running, and their behaviour depends on a database and on the mysql/mysqldump tools.
# Everything below is a regression test for a bug that actually shipped.
#
#   $env:NOBS_TEST_DSN = '127.0.0.1:3306:root:yourpassword'
#   pwsh -NoProfile -File tests/Live.Tests.ps1 ./NOBSSQL.ps1
#
# Load the fixture first (it lives in the sibling NOBS-SQL-Editor repo, which shares this UI):
#   mysql -u root -p < tests/fixtures/seed.sql
#
# Not run in CI: windows-latest has no database, and GitHub's service containers are Linux-only
# while this app targets Windows. Without NOBS_TEST_DSN this script says so and exits 0 - but it
# says so LOUDLY, because a test that quietly reports success for work it never did is worse than
# no test at all.

param([Parameter(Mandatory)][string]$ScriptPath)

$dsn = $env:NOBS_TEST_DSN
if (-not $dsn) {
    ""
    "  SKIPPED - NOBS_TEST_DSN is not set, so none of the live tests below ran."
    "            Set it to host:port:user:password to actually exercise them."
    ""
    exit 0
}
$parts = $dsn.Split(':')
if ($parts.Count -ne 4) { "  FAIL  NOBS_TEST_DSN must be host:port:user:password"; exit 1 }
$conn = @{ host = $parts[0]; port = $parts[1]; user = $parts[2]; password = $parts[3]; ssl = 'default' }

$script:fail = 0
function Check($cond, $label, $detail) {
    if ($cond) {
        "  ok    $label"
    } else {
        $extra = ''
        if ($detail) { $extra = " -> $detail" }
        "  FAIL  $label$extra"
        $script:fail++
    }
}

$outFile = Join-Path $env:TEMP "nobs-live-out-$PID.txt"
$errFile = Join-Path $env:TEMP "nobs-live-err-$PID.txt"
$proc = Start-Process -FilePath (Get-Process -Id $PID).Path `
    -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Resolve-Path $ScriptPath).Path, '-NoBrowser' `
    -PassThru -WindowStyle Hidden -RedirectStandardOutput $outFile -RedirectStandardError $errFile

$base = $null
$token = $null
$cn = $null      # the compare check's saved profile, if it got that far - see finally
try {
    # The server takes the first free port from its fixed list and prints the address it got.
    # Read it from there. Probing the ports instead found whatever answered first - including an
    # instance of the app someone had open - and this script then ran every check against that one
    # and finished by sending it /api/quit.
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline -and -not $token) {
        $said = try { Get-Content -Raw -LiteralPath $outFile -ErrorAction Stop } catch { '' }
        if ($said -match 'Open:\s+(http://127\.0\.0\.1:\d+)/') {
            try {
                $html = Invoke-WebRequest -Uri "$($Matches[1])/" -TimeoutSec 2 -UseBasicParsing
                if ($html.Content -match 'const TOKEN="([a-f0-9]+)"') { $base = ($said | Select-String 'Open:\s+(http://127\.0\.0\.1:\d+)/').Matches[0].Groups[1].Value; $token = $Matches[1] }
            } catch { }
        }
        if ($proc.HasExited) { break }
        if (-not $token) { Start-Sleep -Milliseconds 500 }
    }
    if (-not $token) { "  FAIL  server did not come up within 60s"; exit 1 }
    "  (server on $base)"

    function Api($path, $body) {
        $body.token = $token
        $json = $body | ConvertTo-Json -Depth 8 -Compress
        try {
            return Invoke-RestMethod -Uri "$base$path" -Method Post -ContentType 'application/json' -Body $json -TimeoutSec 600
        } catch {
            return [pscustomobject]@{ ok = $false; error = "HTTP: $($_.Exception.Message)" }
        }
    }
    function Sql($sql, $db) { return Api '/api/query' @{ conn = $conn; db = $db; sql = $sql } }
    function Scalar($sql, $db) {
        $r = Sql $sql $db
        if ($r.ok -and $r.rows.Count) { return [string]$r.rows[0][0] }
        return $null
    }

    # Which client the server is using: results differ between MariaDB's and MySQL's mysql.exe.
    $tools = Api '/api/tools-status' @{}
    "  (mysql client: $($tools.mysql))"

    # --- 0. without the fixture every result below is meaningless ------------------------------
    $canary = Scalar 'SELECT COUNT(*) FROM ro_canary' 'nobs_test'
    if ($canary -ne '3') {
        "  FAIL  fixture not loaded (nobs_test.ro_canary should hold 3 rows, got '$canary'). Load tests/fixtures/seed.sql."
        exit 1
    }

    # --- 1. the keepalive ping must require the token ------------------------------------------
    # LastPing drives the idle shutdown. While this was unauthenticated, any page the user had
    # open could hold the server - and the live database connections it owns - open forever.
    $pingNoToken = $null
    try {
        $pingNoToken = Invoke-RestMethod -Uri "$base/api/ping" -Method Post -ContentType 'application/json' -Body '{}' -TimeoutSec 10
    } catch { }
    Check ($pingNoToken -and -not $pingNoToken.ok) 'ping without a token is refused' ($pingNoToken | ConvertTo-Json -Compress)
    $pingOk = Api '/api/ping' @{}
    Check ($pingOk.ok -eq $true) 'ping with the token still works' ($pingOk | ConvertTo-Json -Compress)

    # --- 2. read-only mode is enforced by the SERVER, not just by a greyed-out button -----------
    $leaked = @()
    $blocked = 0
    $writes = @(
        'DELETE FROM ro_canary'
        "UPDATE ro_canary SET note='x'"
        'DROP TABLE ro_canary'
        'TRUNCATE ro_canary'
        "INSERT INTO ro_canary (label) VALUES ('nope')"
        'ALTER TABLE ro_canary ADD COLUMN x INT'
        "GRANT ALL ON nobs_test.* TO 'x'@'%'"
        "CALL p_touch_canary('via procedure')"
        '/*!50000 DELETE FROM ro_canary */'
        'SELECT 1; /*!DROP TABLE ro_canary */'
        'SET GLOBAL max_connections = 1'
        'SET PERSIST max_connections = 1'
        'SET @@GLOBAL.max_connections = 1'
    )
    foreach ($s in $writes) {
        $r = Api '/api/query' @{ conn = $conn; db = 'nobs_test'; ro = $true; sql = $s }
        if ($r.ok) { $leaked += $s } else { $blocked++ }
    }
    Check ($leaked.Count -eq 0) "read-only blocks all $($writes.Count) writes (blocked $blocked)" ($leaked -join ' | ')

    $wrong = @()
    $reads = @(
        'SELECT * FROM ro_canary'
        'SHOW TABLES'
        'EXPLAIN SELECT * FROM bulk_rows'
        'SET autocommit = 0'
        'WITH x AS (SELECT 1 AS n) SELECT * FROM x'
    )
    foreach ($s in $reads) {
        $r = Api '/api/query' @{ conn = $conn; db = 'nobs_test'; ro = $true; sql = $s }
        if (-not $r.ok) { $wrong += $s }
    }
    Check ($wrong.Count -eq 0) "read-only still allows all $($reads.Count) reads" ($wrong -join ' | ')

    # The grid's own write paths, which never go through the SQL-text check.
    $ro1 = Api '/api/rowop' @{ conn = $conn; ro = $true; db = 'nobs_test'; table = 'ro_canary'; op = 'delete'; where = @{ id = 1 } }
    Check (-not $ro1.ok) 'read-only refuses /api/rowop server-side' ($ro1 | ConvertTo-Json -Compress)
    $ro2 = Api '/api/script' @{ conn = $conn; ro = $true; db = 'nobs_test'; transaction = $true; sql = "UPDATE nobs_test.ro_canary SET note='hacked' WHERE id=1 LIMIT 1;" }
    Check (-not $ro2.ok) 'read-only refuses a staged grid apply (/api/script)' ($ro2 | ConvertTo-Json -Compress)
    $intact = Scalar "SELECT CONCAT(COUNT(*),'/',SUM(label LIKE 'untouched%')) FROM ro_canary" 'nobs_test'
    Check ($intact -eq '3/3') 'canary is untouched after all of that' "got $intact"

    # --- 3. a staged batch is all-or-nothing ---------------------------------------------------
    # A PARTIAL apply is the worst outcome this app can produce, and the whole reason the
    # pending-changes model exists. Every batch below puts a legal edit FIRST, then fails.
    $cases = @(
        @{ n = 'CHECK';    sql = "UPDATE nobs_test.txn_child SET qty=-1 WHERE code='BBB' LIMIT 1;" }
        @{ n = 'FK';       sql = "UPDATE nobs_test.txn_child SET parent_id=99 WHERE code='CCC' LIMIT 1;" }
        @{ n = 'DUPKEY';   sql = "UPDATE nobs_test.txn_child SET code='AAA' WHERE code='DDD' LIMIT 1;" }
        @{ n = 'NOT NULL'; sql = "UPDATE nobs_test.txn_child SET code=NULL WHERE code='EEE' LIMIT 1;" }
        @{ n = 'TRIGGER';  sql = "INSERT INTO nobs_test.txn_child (parent_id,code,descr,qty) VALUES (1,'ZZZ','z',-5);" }
    )
    # Read the baseline rather than hardcoding it: the fixture ships 'first' here, but any earlier
    # test run (in this repo or the sibling one) may have left something else, and what matters is
    # only that the value does not MOVE while a batch fails.
    $baseDescr = Scalar "SELECT descr FROM txn_child WHERE code='AAA'" 'nobs_test'
    foreach ($case in $cases) {
        $batch = "UPDATE nobs_test.txn_child SET descr='SHOULD-ROLL-BACK' WHERE code='AAA' LIMIT 1;`n" + $case.sql
        $r = Api '/api/script' @{ conn = $conn; db = 'nobs_test'; transaction = $true; sql = $batch }
        $descr = Scalar "SELECT descr FROM txn_child WHERE code='AAA'" 'nobs_test'
        Check ((-not $r.ok) -and ($descr -eq $baseDescr)) "a failed batch ($($case.n)) applies nothing" "ok=$($r.ok) descr=$descr want=$baseDescr"
    }
    # The control. Without it, a transaction that ALWAYS rolled back would pass every case above.
    $good = Api '/api/script' @{ conn = $conn; db = 'nobs_test'; transaction = $true; sql = "UPDATE nobs_test.txn_child SET descr='committed' WHERE code='AAA' LIMIT 1;" }
    $after = Scalar "SELECT descr FROM txn_child WHERE code='AAA'" 'nobs_test'
    Check ($good.ok -and ($after -eq 'committed')) 'a valid batch commits completely' "ok=$($good.ok) descr=$after"
    # Put the baseline back, so running this twice in a row behaves the same as running it once.
    Api '/api/script' @{ conn = $conn; db = 'nobs_test'; transaction = $true; sql = "UPDATE nobs_test.txn_child SET descr=" + (ConvertTo-Json $baseDescr) + " WHERE code='AAA' LIMIT 1;" } | Out-Null
    $restored = Scalar "SELECT descr FROM txn_child WHERE code='AAA'" 'nobs_test'
    Check ($restored -eq $baseDescr) 'the fixture is left as it was found' "descr=$restored want=$baseDescr"

    # --- 4. a cancelled export says CANCELLED, never a reasonless FAILED ------------------------
    # The routines/events step used to skip the $job.Cancelled check the table steps do, so a
    # killed mysqldump (exit -1, empty stderr) logged "FAILED (-1) <db> routines/events : " - a
    # failure with no reason, for something the user had just cancelled. The cancel has to land
    # while a dump is actually in flight, so several timings are tried.
    # Guessing a delay cannot find that window reliably. A cancel landing in the TABLE loop does
    # `break dbloop`, which skips routines/events altogether - so the branch under test never runs
    # and the assertion below passes vacuously. (Confirmed: with fixed delays this whole case
    # reported "ok" against the unfixed code.)
    #
    # Make it deterministic instead: export a database that has no tables and 300 procedures, so
    # the routines/events dump is the only work the export has to do and it lasts long enough to be
    # hit. Then sweep delays, stopping as soon as the step has actually been reached.
    #
    # The request is sent straight from this process. It used to go through Start-Job, whose new
    # PowerShell process takes a varying and often long time to start - on a CI runner the cancel
    # regularly arrived before the export had begun, and 45 attempts all missed.
    $rtDb = "nobs_live_routines_$PID"
    $procs = (1..300 | ForEach-Object { "CREATE PROCEDURE $rtDb.p$_() SELECT $_;" }) -join "`n"
    $mk = Api '/api/script' @{ conn = $conn; sql = "DROP DATABASE IF EXISTS $rtDb; CREATE DATABASE $rtDb;`n$procs" }
    if (-not $mk.ok) { "  note  could not create $rtDb : $($mk.error)" }
    $http = [System.Net.Http.HttpClient]::new()
    $http.Timeout = [TimeSpan]::FromMinutes(10)

    $sawCancel = $false
    $reachedRoutines = $false
    $reasonless = @()
    # Retry until the window is actually observed rather than hoping one pass of a fixed sweep
    # lands in it. The dump is quick, so the window is narrow and a single sweep does flake; each
    # attempt is cheap (every table is excluded, so there is almost nothing else to do). The sweep
    # is cycled with a small jitter so repeated attempts do not all land in the same place.
    $delaySweep = @(100, 200, 300, 400, 500, 650, 800, 1000, 1250, 1500, 2000)
    $attempt = 0
    while (-not ($reachedRoutines -and $sawCancel) -and $attempt -lt 45) {
        $delay = $delaySweep[$attempt % $delaySweep.Count] + (Get-Random -Minimum 0 -Maximum 12)
        $attempt++
        $folder = Join-Path ([IO.Path]::GetTempPath()) "nobs-live-exp-$PID-$delay"
        Remove-Item $folder -Recurse -Force -ErrorAction SilentlyContinue
        $jobId = "live-$PID-$delay"
        $b = @{
            token = $token; conn = $conn; dbs = @($rtDb); folder = $folder
            mode = 'table'; jobId = $jobId; excludes = @()
            options = @{ charset = 'utf8mb4'; routines = $true; events = $true; quick = $true; extinsert = $true }
        }
        $body = [System.Net.Http.StringContent]::new(($b | ConvertTo-Json -Depth 8 -Compress), [Text.Encoding]::UTF8, 'application/json')
        $pending = $http.PostAsync("$base/api/export", $body)
        Start-Sleep -Milliseconds $delay
        Api '/api/cancel-job' @{ jobId = $jobId } | Out-Null
        $res = $null
        try { $res = $pending.GetAwaiter().GetResult().Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json } catch { }
        if ($res.cancelled) {
            $sawCancel = $true
            foreach ($line in @($res.log)) {
                # "reached" has to mean the step was INTERRUPTED, not merely that it ran. A
                # successful "OK ... (routines/events)" line also mentions routines/events, and
                # counting that satisfied this check without the branch under test ever executing
                # - which is how an earlier version of this test passed against the unfixed code.
                if ($line -match 'routines/events' -and $line -notmatch '^OK') { $reachedRoutines = $true }
                if ($line -match '^FAILED' -and $line.TrimEnd().EndsWith(':')) { $reasonless += "at ${delay}ms: $line" }
            }
        }
        Remove-Item $folder -Recurse -Force -ErrorAction SilentlyContinue
    }
    Check $sawCancel 'an export could be cancelled mid-run at least once' 'no run reported cancelled:true'
    # Without this the whole case can pass by never happening: if every cancel lands during the
    # table loop, the routines/events branch under test is never executed and the assertion below
    # is vacuous. Confirmed by reverting the fix - the test only catches the bug when it gets here.
    Check $reachedRoutines 'a cancel actually reached the routines/events step' "$attempt attempts, none landed inside the routines/events dump - widen `$delaySweep above"
    Check ($reasonless.Count -eq 0) 'a cancelled export never logs a FAILED line with no reason' ($reasonless -join ' | ')
    $http.Dispose()
    Api '/api/exec' @{ conn = $conn; sql = "DROP DATABASE IF EXISTS $rtDb" } | Out-Null
    $orphans = @(Get-Process -Name 'mysqldump', 'mariadb-dump' -ErrorAction SilentlyContinue)
    Check ($orphans.Count -eq 0) 'cancelling leaves no orphaned mysqldump process' "found $($orphans.Count)"

    # --- 4b. "Continue on error" must not hide the errors it continued past --------------------
    # --force makes mysql exit 0 even when every statement failed, putting what went wrong on
    # stderr instead. Trusting the exit code turned a completely failed restore into a clean list
    # of OK lines - the worst outcome this endpoint can produce, because it looks like it worked.
    $badSql = Join-Path ([IO.Path]::GetTempPath()) "nobs-live-import-bad-$PID.sql"
    Set-Content -LiteralPath $badSql -Encoding ascii -Value @(
        'INSERT INTO nobs_test.no_such_table VALUES (1);'
        'INSERT INTO nobs_test.also_missing VALUES (2);'
    )
    $forced = Api '/api/import' @{ conn = $conn; files = @($badSql); targetDb = 'nobs_test'; force = $true }
    $forcedLine = ''
    if ($forced.log) { $forcedLine = [string]$forced.log[0] }
    # A plain success is "OK  <file>" with two spaces; "OK with N error(s) SKIPPED" is the honest
    # form. Matching on the two spaces is what tells them apart - the same discriminator the Tauri
    # edition's force_mode_reports_the_errors_it_skipped uses.
    Check ($forcedLine -notmatch '^OK  ') 'a wholly failed force-import is not reported as a plain OK' "log: $forcedLine"
    Check ($forcedLine -match 'error\(s\) SKIPPED') 'the skipped errors are named in the log' "log: $forcedLine"
    Check ($forced.errorsSkipped -eq 2) 'errorsSkipped counts them' "errorsSkipped=$($forced.errorsSkipped)"

    # The control: without --force the same file already reported correctly, and must still do so.
    $unforced = Api '/api/import' @{ conn = $conn; files = @($badSql); targetDb = 'nobs_test'; force = $false }
    $unforcedLine = ''
    if ($unforced.log) { $unforcedLine = [string]$unforced.log[0] }
    Check ($unforcedLine -match '^FAILED') 'without force, a failing import still reports FAILED' "log: $unforcedLine"

    # And a genuinely clean import must stay a plain OK - otherwise the check above could be
    # satisfied by simply never saying OK again.
    $goodSql = Join-Path ([IO.Path]::GetTempPath()) "nobs-live-import-good-$PID.sql"
    Set-Content -LiteralPath $goodSql -Encoding ascii -Value @('SELECT 1;')
    $clean = Api '/api/import' @{ conn = $conn; files = @($goodSql); targetDb = 'nobs_test'; force = $true }
    $cleanLine = ''
    if ($clean.log) { $cleanLine = [string]$clean.log[0] }
    Check ($cleanLine -match '^OK  ' -and $clean.errorsSkipped -eq 0) 'a clean import is still a plain OK' "log: $cleanLine errorsSkipped=$($clean.errorsSkipped)"
    Remove-Item -LiteralPath $badSql, $goodSql -Force -ErrorAction SilentlyContinue

    # --- 4c. CSV import: NULL and the empty string must stay different ------------------------
    # A CSV field is just text, so the only thing separating "this cell is NULL" from "this cell
    # is an empty string" is the null marker. Collapsing the two silently changes data on the way
    # in, and it is the kind of thing nobody notices until a NOT NULL constraint or an IS NULL
    # query behaves unexpectedly much later. The Tauri edition tests this; this one did not.
    $csvDir = [IO.Path]::GetTempPath()
    $csv1 = Join-Path $csvDir "nobs-live-csv-$PID.csv"
    Set-Content -LiteralPath $csv1 -Encoding ascii -Value @(
        'id,note,tag'
        '1,\N,keep'          # \N is the marker -> NULL
        '2,,keep'            # empty field -> empty string, NOT null
    )
    Api '/api/exec' @{ conn = $conn; sql = 'DROP TABLE IF EXISTS nobs_test.csv_live_rt' } | Out-Null
    Api '/api/exec' @{ conn = $conn; sql = 'CREATE TABLE nobs_test.csv_live_rt (id INT PRIMARY KEY, note VARCHAR(32) NULL, tag VARCHAR(32))' } | Out-Null
    $imp = Api '/api/importcsv' @{ conn = $conn; db = 'nobs_test'; table = 'csv_live_rt'; file = $csv1; hasHeader = $true; nullValue = '\N' }
    Check ($imp.ok -eq $true) 'CSV import succeeds' ($imp | ConvertTo-Json -Compress)
    $shape = Scalar "SELECT CONCAT(SUM(id=1 AND note IS NULL), '/', SUM(id=2 AND note='' AND note IS NOT NULL)) FROM csv_live_rt" 'nobs_test'
    Check ($shape -eq '1/1') 'the marker becomes NULL and a blank field stays an empty string' "got $shape (want 1/1)"

    # With an empty marker, a blank cell is meant to mean NULL instead.
    $csv2 = Join-Path $csvDir "nobs-live-csv2-$PID.csv"
    Set-Content -LiteralPath $csv2 -Encoding ascii -Value @('id,note,tag', '3,,keep')
    $imp2 = Api '/api/importcsv' @{ conn = $conn; db = 'nobs_test'; table = 'csv_live_rt'; file = $csv2; hasHeader = $true; nullValue = '' }
    Check ($imp2.ok -eq $true) 'CSV import with an empty null marker succeeds' ($imp2 | ConvertTo-Json -Compress)
    Check ((Scalar "SELECT note IS NULL FROM csv_live_rt WHERE id=3" 'nobs_test') -eq '1') 'an empty marker makes blank cells NULL again'

    # A CSV from the Tauri edition writes an empty binary value as the bare "0x". The hex rule
    # needed at least one digit, so it used to be stored as the two characters 0x (hex 3078).
    $csv3 = Join-Path $csvDir "nobs-live-csv3-$PID.csv"
    Set-Content -LiteralPath $csv3 -Encoding ascii -Value @('id,b,t', '1,0x,0x', '2,0x00FF,0x00FF', '3,\N,\N')
    Api '/api/exec' @{ conn = $conn; sql = 'DROP TABLE IF EXISTS nobs_test.csv_live_bin' } | Out-Null
    Api '/api/exec' @{ conn = $conn; sql = 'CREATE TABLE nobs_test.csv_live_bin (id INT PRIMARY KEY, b VARBINARY(8) NULL, t VARCHAR(8) NULL)' } | Out-Null
    $imp3 = Api '/api/importcsv' @{ conn = $conn; db = 'nobs_test'; table = 'csv_live_bin'; file = $csv3; hasHeader = $true; nullValue = '\N' }
    Check ($imp3.ok -eq $true) 'CSV import with binary values succeeds' ($imp3 | ConvertTo-Json -Compress)
    $binShape = Scalar "SELECT GROUP_CONCAT(CONCAT_WS('|', id, IFNULL(HEX(b),'N'), IFNULL(t,'N')) ORDER BY id SEPARATOR ';') FROM csv_live_bin" 'nobs_test'
    Check ($binShape -ceq '1||0x;2|00FF|0x00FF;3|N|N') 'a bare 0x is an empty binary value, and text that reads 0x stays text' "got $binShape"
    Api '/api/exec' @{ conn = $conn; sql = 'DROP TABLE IF EXISTS nobs_test.csv_live_bin' } | Out-Null
    Remove-Item -LiteralPath $csv3 -Force -ErrorAction SilentlyContinue

    # Replace-mode empties the table first. If the import then fails, that emptying must go too -
    # otherwise a botched import destroys the data it was supposed to replace. (TRUNCATE could not
    # deliver this: MySQL implicitly commits it. This path uses DELETE FROM inside the transaction
    # for exactly that reason.)
    $csvBad = Join-Path $csvDir "nobs-live-csv-bad-$PID.csv"
    Set-Content -LiteralPath $csvBad -Encoding ascii -Value @('id,note,tag', '9,a,keep', '9,b,keep')  # duplicate PK
    $before = Scalar 'SELECT COUNT(*) FROM csv_live_rt' 'nobs_test'
    $impBad = Api '/api/importcsv' @{ conn = $conn; db = 'nobs_test'; table = 'csv_live_rt'; file = $csvBad; hasHeader = $true; nullValue = '\N'; truncate = $true }
    Check ($impBad.ok -eq $false) 'an import with a duplicate key fails' ($impBad | ConvertTo-Json -Compress)
    $after = Scalar 'SELECT COUNT(*) FROM csv_live_rt' 'nobs_test'
    Check ($after -eq $before) 'a failed replace-mode import leaves the original rows untouched' "before=$before after=$after"

    Api '/api/exec' @{ conn = $conn; sql = 'DROP TABLE IF EXISTS nobs_test.csv_live_rt' } | Out-Null
    Remove-Item -LiteralPath $csv1, $csv2, $csvBad -Force -ErrorAction SilentlyContinue

    # The import skipped columns the table does not have, filled short rows with NULL, dropped
    # extra fields and switched foreign key checks off. Generated columns (which the desktop
    # edition's CSV export includes) cannot be given a value, so they are skipped and named.
    foreach ($s in @('DROP TABLE IF EXISTS nobs_test.csv_x_child', 'DROP TABLE IF EXISTS nobs_test.csv_x_parent', 'DROP TABLE IF EXISTS nobs_test.csv_x',
                     'CREATE TABLE nobs_test.csv_x (id INT PRIMARY KEY, a INT, secret VARCHAR(10) INVISIBLE, g INT GENERATED ALWAYS AS (a * 2) VIRTUAL)',
                     'CREATE TABLE nobs_test.csv_x_parent (id INT PRIMARY KEY)',
                     'CREATE TABLE nobs_test.csv_x_child (id INT PRIMARY KEY, pid INT, FOREIGN KEY (pid) REFERENCES nobs_test.csv_x_parent (id))')) {
        $sr = Api '/api/exec' @{ conn = $conn; sql = $s }; if (-not $sr.ok) { "  note  setup: $($sr.error)" }
    }
    $csvCase = {
        param($name, $lines, $table)
        $p = Join-Path $csvDir "nobs-live-$name-$PID.csv"
        Set-Content -LiteralPath $p -Encoding utf8 -Value $lines
        $r = Api '/api/importcsv' @{ conn = $conn; db = 'nobs_test'; table = $table; file = $p; hasHeader = $true; nullValue = '\N' }
        Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
        $r
    }
    $r = & $csvCase 'gen' @('ID,A,SECRET,g', '1,5,hidden,999') 'csv_x'
    Check ($r.ok -and $r.message -match 'computed by the server: g') 'CSV headers match ignoring case, and a generated column is skipped' ($r | ConvertTo-Json -Compress)
    Check ((Scalar "SELECT CONCAT_WS('|', a, secret, g) FROM csv_x" 'nobs_test') -eq '5|hidden|10') 'the invisible column is stored, the generated one computed'
    $r = & $csvCase 'unknown' @('id,nmae', '2,x') 'csv_x'
    Check ($r.error -match 'no column named nmae') 'a CSV column the table does not have is refused' ($r | ConvertTo-Json -Compress)
    $r = & $csvCase 'short' @('id,a', '2,3', '4') 'csv_x'
    Check ($r.error -match 'Data row 2 has 1 field\(s\), but the header has 2') 'a row with too few fields is refused' ($r | ConvertTo-Json -Compress)
    $r = & $csvCase 'long' @('id,a', '2,3,9') 'csv_x'
    Check ($r.error -match 'more than 2 field') 'a row with too many fields is refused' ($r | ConvertTo-Json -Compress)
    Check ((Scalar 'SELECT COUNT(*) FROM csv_x' 'nobs_test') -eq '1') 'and none of them imported anything'
    $r = & $csvCase 'fk' @('id,pid', '1,999') 'csv_x_child'
    Check (-not $r.ok -and (Scalar 'SELECT COUNT(*) FROM csv_x_child' 'nobs_test') -eq '0') 'a row pointing at a missing parent is refused' ($r | ConvertTo-Json -Compress)
    foreach ($s in @('DROP TABLE nobs_test.csv_x_child', 'DROP TABLE nobs_test.csv_x_parent', 'DROP TABLE nobs_test.csv_x')) { Api '/api/exec' @{ conn = $conn; sql = $s } | Out-Null }

    # A grid save runs a guard before each change (oneRowGuard in the UI): unless the change's
    # WHERE matches exactly one row, the batch stops (error 1172) and is rolled back. Without it a
    # FLOAT key - matched by its text now - or a row deleted meanwhile was reported as saved.
    $guard = { param($where) "SELECT 1 FROM (SELECT 1 AS x UNION ALL SELECT 2) nobs_guard WHERE (SELECT COUNT(*) FROM nobs_test.grid_guard WHERE $where) <> 1 INTO @nobs_one_row;" }
    foreach ($s in @('DROP TABLE IF EXISTS nobs_test.grid_guard', 'CREATE TABLE nobs_test.grid_guard (k FLOAT PRIMARY KEY, v VARCHAR(10))', "INSERT INTO nobs_test.grid_guard VALUES (1.1, 'a'), (2.5, 'b')")) {
        Api '/api/exec' @{ conn = $conn; sql = $s } | Out-Null
    }
    $w = "CAST(``k`` AS CHAR)='1.1'"
    $g1 = Api '/api/script' @{ conn = $conn; transaction = $true; sql = (& $guard $w) + "`nUPDATE nobs_test.grid_guard SET v='x' WHERE $w LIMIT 1;" }
    Check ($g1.ok -and (Scalar "SELECT v FROM grid_guard WHERE k > 1 AND k < 2" 'nobs_test') -eq 'x') 'a FLOAT-keyed row is saved' ($g1 | ConvertTo-Json -Compress)
    $w2 = "CAST(``k`` AS CHAR)='9.9'"
    $g2 = Api '/api/script' @{ conn = $conn; transaction = $true; sql = "UPDATE nobs_test.grid_guard SET v='y' WHERE k > 2 LIMIT 1;`n" + (& $guard $w2) + "`nDELETE FROM nobs_test.grid_guard WHERE $w2 LIMIT 1;" }
    Check (-not $g2.ok -and $g2.error -match 'Result consisted of more than one row') 'a change matching no row stops the batch' ($g2 | ConvertTo-Json -Compress)
    Check ((Scalar "SELECT v FROM grid_guard WHERE k > 2" 'nobs_test') -eq 'b') 'and the changes before it are rolled back'
    Api '/api/exec' @{ conn = $conn; sql = 'DROP TABLE nobs_test.grid_guard' } | Out-Null

    # --- 4d. binary values survive the trip through the CLI ------------------------------------
    # Rows are parsed out of mysql.exe's stdout. Reading that stream as UTF-8 made the decoder
    # replace every byte that was not valid UTF-8 with U+FFFD before any of this app's code saw
    # it: VARBINARY 00 FF 10 arrived as 0x00EFBFBD10. It was not merely a display problem - the
    # grid writes a cell back exactly as it holds it, so saving such a row committed the mangled
    # bytes to disk. The reader is byte-preserving now, and binary columns arrive as 0x.. hex.
    $cb = Api '/api/query' @{ conn = $conn; db = 'nobs_test'; sql = 'SELECT bin_col, blob_col, bit8, emoji, cjk FROM charset_binary WHERE id=1' }
    Check ($cb.ok -and [string]$cb.rows[0][0] -eq '0x00FF10') 'a VARBINARY column arrives with its bytes intact' ("got " + [string]$cb.rows[0][0])
    Check ([string]$cb.rows[0][1] -eq '0xDEADBEEF') 'a BLOB column arrives with its bytes intact' ("got " + [string]$cb.rows[0][1])
    Check ([string]$cb.rows[0][2] -eq '0xAA') 'a BIT(8) column arrives as its real byte' ("got " + [string]$cb.rows[0][2])
    # The same change must not break text: these share the stream and are decoded as UTF-8.
    Check ([string]$cb.rows[0][3] -eq ([char]::ConvertFromUtf32(0x1F600))) 'a 4-byte emoji still arrives as itself' ("got " + [string]$cb.rows[0][3])
    Check ([string]$cb.rows[0][4] -ne '' -and [string]$cb.rows[0][4] -notmatch [char]0xFFFD) 'CJK text still arrives undamaged' ("got " + [string]$cb.rows[0][4])
    # NULL must stay distinguishable from an empty binary.
    $nullRow = Api '/api/query' @{ conn = $conn; db = 'nobs_test'; sql = 'SELECT bin_col FROM charset_binary WHERE id=3' }
    Check ($null -eq $nullRow.rows[0][0]) 'a NULL binary column is still NULL, not an empty blob' ("got " + ($nullRow.rows[0][0] | ConvertTo-Json -Compress))

    # And the round trip, which is where the corruption used to become permanent.
    Api '/api/exec' @{ conn = $conn; sql = 'DROP TABLE IF EXISTS nobs_test.bin_rt' } | Out-Null
    Api '/api/exec' @{ conn = $conn; sql = 'CREATE TABLE nobs_test.bin_rt (id INT PRIMARY KEY, b VARBINARY(8))' } | Out-Null
    Api '/api/exec' @{ conn = $conn; sql = 'INSERT INTO nobs_test.bin_rt VALUES (1, 0x00FF10)' } | Out-Null
    $held = [string](Api '/api/query' @{ conn = $conn; db = 'nobs_test'; sql = 'SELECT b FROM bin_rt WHERE id=1' }).rows[0][0]
    Api '/api/rowop' @{ conn = $conn; db = 'nobs_test'; table = 'bin_rt'; op = 'update'; set = @{ b = $held }; where = @{ id = 1 } } | Out-Null
    Check ((Scalar 'SELECT HEX(b) FROM bin_rt WHERE id=1' 'nobs_test') -eq '00FF10') 'writing a binary cell back leaves the bytes unchanged' "held=$held"
    Api '/api/exec' @{ conn = $conn; sql = 'DROP TABLE IF EXISTS nobs_test.bin_rt' } | Out-Null

    # --- 4e. byte fidelity: what you type is what gets stored ---------------------------------
    # Three separate binary-fidelity bugs shipped in code that read correctly and passed the tests
    # that existed: the stdout reader destroying non-UTF-8 bytes, hex pasted into the Text tab
    # being stored as characters, and an emptied cell storing the two characters "0x". None were
    # found by reasoning about the code - all three were found by putting a value in, reading it
    # back out, and comparing bytes. So that comparison lives here now, across the kinds of input
    # that actually break things.
    #
    # The SQL literal is built by the REAL editor functions lifted out of NOBSSQL.ps1 (textToHex,
    # normalizeHexInput, lit, strLit) plus the empty-value mapping getVal applies, so this follows
    # the shipped save path rather than a description of it.
    $rtHarness = @'
import { readFileSync } from 'node:fs';
function ex(src, name) {
  let s = src.indexOf(`async function ${name}(`);
  if (s === -1) s = src.indexOf(`function ${name}(`);
  if (s === -1) throw new Error(name + ' not found - was it renamed?');
  let d = 0;
  for (let j = src.indexOf('{', s); j < src.length; j++) {
    if (src[j] === '{') d++;
    else if (src[j] === '}' && --d === 0) return src.slice(s, j + 1);
  }
  throw new Error('unbalanced braces in ' + name);
}
const src = readFileSync(process.argv[2], 'utf8');
const names = ['strLit','lit','bytesToHex','textToHex','hexToBytes','normalizeHexInput'];
const F = new Function(names.map(n => ex(src, n)).join('\n') + `\nreturn {${names.join(',')}};`)();
const enc = new TextEncoder();
const hexOf = s => [...enc.encode(s)].map(b => b.toString(16).padStart(2,'0')).join('').toUpperCase();

const cases = [
  ['a crypt hash typed as text',          '$7$C6..../....RYngpNxfC6t.r9JyBynUxwywkD8T/MbQx7QQl.Acjv.', 'text'],
  ['single quotes',                       "it's a 'quoted' value",   'text'],
  ['double quotes',                       'he said "hello"',         'text'],
  ['backslashes',                         'C:\\path\\to\\file',      'text'],
  ['a trailing backslash',                'trailing\\',              'text'],
  ['a quote and a backslash together',    "mix'\\'end",              'text'],
  ['a 4-byte emoji',                      'hi \u{1F600} there',      'text'],
  ['CJK',                                 '\u4E2D\u6587\u6D4B\u8BD5','text'],
  ['RTL',                                 '\u0645\u0631\u062D\u0628\u0627','text'],
  ['a newline and a tab',                 'line1\nline2\tend',       'text'],
  ['Windows line breaks',                 'line1\r\nline2\r\n',    'text'],
  ['a lone carriage return',              'a\rb',                   'text'],
  ['text shaped like SQL injection',      "'; DROP TABLE x; --",     'text'],
  ['an empty box',                        '',                        'text'],
  ['text that looks like hex',            '0x1234abcd',              'text'],
  ['64 KB of text',                       'A'.repeat(65536),         'text'],
  ['hex, as this app copies it',          '0x00ff10',                'hex'],
  ['hex, Workbench-spaced',               '24 37 24 43',             'hex'],
  ['hex, wrapped across lines',           '2437\n2443',              'hex'],
  ['hex, without the 0x prefix',          'deadbeef',                'hex'],
  ['hex, uppercase',                      '0xDEADBEEF',              'hex'],
  ['hex, a lone NUL byte',                '0x00',                    'hex'],
  ['hex, bytes that are not valid UTF-8', '0x00ff10fe',              'hex'],
  ['hex, an empty box',                   '0x',                      'hex'],
];
// The mapping getVal() applies before handing the value to lit(): a digit-less "0x" is an empty
// value, not the characters 0 and x.
const forEmpty = h => (h === null || h === '0x') ? '' : h;
const out = [];
let id = 0;
for (const [label, value, tab] of cases) {
  id++;
  const hex = tab === 'text' ? F.textToHex(value) : F.normalizeHexInput(value);
  if (hex === null) throw new Error('normalizeHexInput rejected a case it should accept: ' + label);
  out.push({ id, label, tab, literal: F.lit(forEmpty(hex)), quoted: F.strLit(value),
             expect: tab === 'text' ? hexOf(value) : hex.slice(2).toUpperCase() });
}
// ASCII only: PowerShell decodes a native command's output with the console code page, which
// turned the emoji and CJK cases into different text before they were ever sent.
console.log(JSON.stringify(out).replace(/[\u007f-\uffff]/g, c => '\\u' + c.charCodeAt(0).toString(16).padStart(4, '0')));
'@
    $rtTmp = Join-Path ([IO.Path]::GetTempPath()) "rt-harness-$PID.mjs"
    Set-Content -LiteralPath $rtTmp -Value $rtHarness -Encoding utf8
    $rtJson = & node $rtTmp (Resolve-Path $ScriptPath).Path
    Remove-Item -LiteralPath $rtTmp -ErrorAction SilentlyContinue
    if (-not $rtJson) {
        Check $false 'the byte-fidelity harness produced cases' 'node returned nothing'
    } else {
        $rtCases = $rtJson | ConvertFrom-Json
        Api '/api/exec' @{ conn = $conn; sql = 'DROP TABLE IF EXISTS nobs_test.rt_probe' } | Out-Null
        Api '/api/exec' @{ conn = $conn; sql = 'CREATE TABLE nobs_test.rt_probe (id INT PRIMARY KEY, b LONGBLOB, t LONGTEXT CHARACTER SET utf8mb4)' } | Out-Null
        $bad = @()
        foreach ($c in $rtCases) {
            # /api/script, as the grid's Apply sends it: the SQL goes to mysql.exe as a script, which
            # turns CR LF into LF - a raw CR in a literal did not survive that.
            # Text also goes, quoted by strLit as the grid writes a text cell, into a real text column: a
            # BLOB stores whatever bytes arrive, so it cannot
            # see the client converting them from the wrong character set.
            $tcol = if ($c.tab -eq 'text') { $c.quoted } else { 'NULL' }
            $ins = Api '/api/script' @{ conn = $conn; sql = "INSERT INTO nobs_test.rt_probe VALUES ($($c.id), $($c.literal), $tcol);"; transaction = $true }
            if (-not $ins.ok) { $bad += "$($c.label): insert failed - $($ins.error)"; continue }
            $got = Scalar "SELECT IFNULL(HEX(b),'<NULL>') FROM rt_probe WHERE id=$($c.id)" 'nobs_test'
            if ($got -ne $c.expect) {
                $sg = if ($got.Length -gt 40) { $got.Substring(0,40) + '...' } else { $got }
                $se = if ($c.expect.Length -gt 40) { $c.expect.Substring(0,40) + '...' } else { $c.expect }
                $bad += "[$($c.tab)] $($c.label): got $sg want $se"
            }
            if ($c.tab -eq 'text') {
                $gotT = Scalar "SELECT IFNULL(HEX(t),'<NULL>') FROM rt_probe WHERE id=$($c.id)" 'nobs_test'
                if ($gotT -ne $c.expect) { $bad += "[text column] $($c.label): got $gotT" }
            }
        }
        Check ($bad.Count -eq 0) "every one of $($rtCases.Count) inputs stores exactly the bytes it should" ($bad -join ' | ')
        Api '/api/exec' @{ conn = $conn; sql = 'DROP TABLE IF EXISTS nobs_test.rt_probe' } | Out-Null
    }

    # --- 4f. export and import use the tools that match the server --------------------------------
    # MariaDB's mysqldump writes values into a MySQL generated column, and MySQL refuses them on
    # restore, so a MySQL server gets MySQL's own tools when there are any. The round trip below is
    # the thing that matters: a table with a generated column comes back out of its own dump.
    $tfc = Api '/api/tools-for-conn' @{ conn = $conn }
    $tst = Api '/api/tools-status' @{}
    Check ($tfc.ok -and $null -ne $tfc.serverIsMariadb) 'tools-for-conn knows what the server is' ($tfc | ConvertTo-Json -Compress)
    $mysqlToolsHere = [bool]$tst.mysqldump_for_mysql
    if ($tfc.serverIsMariadb) {
        Check ($tfc.mysqldump -eq $tst.mysqldump) 'a MariaDB server keeps the default mysqldump' "$($tfc.mysqldump) vs $($tst.mysqldump)"
    } elseif ($mysqlToolsHere) {
        Check ($tfc.mysqldump -eq $tst.mysqldump_for_mysql -and $tfc.mysqldumpIsMariadb -eq $false) "a MySQL server gets MySQL's mysqldump" ($tfc | ConvertTo-Json -Compress)
    } else {
        "  skip  no MySQL client tools on this machine - a MySQL server keeps the default pair"
    }
    $gs = 'nobs_live_gen_src'; $gt = 'nobs_live_gen_tgt'
    foreach ($s in @("DROP DATABASE IF EXISTS $gs", "DROP DATABASE IF EXISTS $gt", "CREATE DATABASE $gs", "CREATE DATABASE $gt",
                     "CREATE TABLE $gs.t (id INT PRIMARY KEY, a INT, dbl INT GENERATED ALWAYS AS (a * 2) STORED, v VARCHAR(8) GENERATED ALWAYS AS (CONCAT('x', a)) VIRTUAL)",
                     "INSERT INTO $gs.t (id, a) VALUES (1, 5), (2, 7)")) {
        $sr = Api '/api/exec' @{ conn = $conn; sql = $s }; if (-not $sr.ok) { "  note  setup: $($sr.error)" }
    }
    $genDir = Join-Path ([IO.Path]::GetTempPath()) "nobs-live-gen-$PID"
    Remove-Item $genDir -Recurse -Force -ErrorAction SilentlyContinue
    $ge = Api '/api/export' @{ conn = $conn; dbs = @($gs); folder = $genDir; mode = 'db'
                              options = @{ charset = 'utf8mb4'; singletx = $true; triggers = $true; extinsert = $true; createdb = $true } }
    $refused = (-not $ge.ok) -and ([string]$ge.error -match 'generated columns')
    if (-not $tfc.serverIsMariadb -and -not $mysqlToolsHere) {
        Check $refused 'without MySQL tools, the export is refused rather than written unrestorable' ($ge | ConvertTo-Json -Compress)
    } else {
        Check ($ge.ok -and -not (@($ge.log) -match '^FAILED')) 'a table with generated columns exports' ($ge | ConvertTo-Json -Compress)
        $gf = Get-ChildItem -LiteralPath $genDir -Filter '*.sql' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($gf) {
            $gi = Api '/api/import' @{ conn = $conn; files = @($gf.FullName); targetDb = $gt }
            Check ($gi.ok -and (@($gi.log) -match '^OK  ')) 'and its dump imports' ($gi | ConvertTo-Json -Compress)
            Check ((Scalar "SELECT GROUP_CONCAT(CONCAT(id, ':', a, ':', dbl, ':', v) ORDER BY id) FROM $gt.t") -eq '1:5:10:x5,2:7:14:x7') 'with every value, generated ones included' (Scalar "SELECT GROUP_CONCAT(CONCAT(id, ':', a, ':', dbl, ':', v) ORDER BY id) FROM $gt.t")
        } else { Check $false 'the export wrote a file' "nothing in $genDir" }
    }
    Remove-Item $genDir -Recurse -Force -ErrorAction SilentlyContinue
    foreach ($s in @("DROP DATABASE IF EXISTS $gs", "DROP DATABASE IF EXISTS $gt")) { Api '/api/exec' @{ conn = $conn; sql = $s } | Out-Null }

    # The per-table export ran mysqldump once per table, so with writes going on its files came
    # from different moments. A second request adds an order and its line in one transaction the
    # whole time; restored, every order must still have its line and no line may lack its order.
    $ss = 'nobs_live_snap_src'; $st = 'nobs_live_snap_tgt'
    foreach ($s in @("DROP DATABASE IF EXISTS $ss", "DROP DATABASE IF EXISTS $st", "CREATE DATABASE $ss", "CREATE DATABASE $st",
                     "CREATE TABLE $ss.a_orders (id INT PRIMARY KEY, pad TEXT)", "CREATE TABLE $ss.b_filler (id INT PRIMARY KEY, pad TEXT)",
                     "CREATE TABLE $ss.c_lines (id INT PRIMARY KEY, order_id INT, pad TEXT)",
                     "CREATE TABLE $ss.``x y`` (id INT PRIMARY KEY)", "CREATE TABLE $ss.x_y (id INT PRIMARY KEY)",
                     "INSERT INTO $ss.``x y`` VALUES (1)", "INSERT INTO $ss.x_y VALUES (2)",
                     "CREATE VIEW $ss.v_orders AS SELECT id FROM $ss.a_orders",
                     "INSERT INTO $ss.b_filler SELECT id, REPEAT('x', 300) FROM nobs_test.bulk_rows WHERE id <= 60000")) {
        $sr = Api '/api/exec' @{ conn = $conn; sql = $s }; if (-not $sr.ok) { "  note  setup: $($sr.error)" }
    }
    $pairs = (1..40000 | ForEach-Object { "START TRANSACTION; INSERT INTO $ss.a_orders VALUES ($_, 'o'); INSERT INTO $ss.c_lines VALUES ($_, $_, 'l'); COMMIT;" }) -join "`n"
    $writerId = "snap-writer-$PID"
    $writer = Start-ThreadJob -ScriptBlock {
        param($base, $token, $sql, $rid, $c)
        try { Invoke-RestMethod -Uri "$base/api/script" -Method Post -ContentType 'application/json' -TimeoutSec 600 -Body (@{ token = $token; sql = $sql; requestId = $rid; conn = $c } | ConvertTo-Json -Depth 5) }
        catch { @{ ok = $false; error = "$_" } }
    } -ArgumentList $base, $token, $pairs, $writerId, $conn
    $waited = 0
    while ([int](Scalar "SELECT COUNT(*) FROM $ss.a_orders") -lt 20 -and $waited -lt 100) { Start-Sleep -Milliseconds 100; $waited++ }
    $snapDir = Join-Path ([IO.Path]::GetTempPath()) "nobs-live-snap-$PID"
    Remove-Item $snapDir -Recurse -Force -ErrorAction SilentlyContinue
    $se = Api '/api/export' @{ conn = $conn; dbs = @($ss); folder = $snapDir; mode = 'table'
                              options = @{ charset = 'utf8mb4'; singletx = $true; quick = $true; triggers = $true; extinsert = $true } }
    Api '/api/cancel-query' @{ conn = $conn; requestId = $writerId } | Out-Null
    $null = $writer | Wait-Job -Timeout 60; $writer | Remove-Job -Force
    $written = Scalar "SELECT COUNT(*) FROM $ss.a_orders"
    $nameList = [string[]]@(Get-ChildItem -LiteralPath $snapDir -Filter '*.sql' | ForEach-Object Name); [Array]::Sort($nameList, [StringComparer]::Ordinal); $names = $nameList -join ','
    Check ($se.ok -and -not (@($se.log) -match '^FAILED') -and $names -eq "$ss.a_orders.sql,$ss.b_filler.sql,$ss.c_lines.sql,$ss.v_orders.sql,$ss.x_y.sql,$ss.x_y_2.sql") 'a per-table export writes one file per table and view, two for look-alike names' "$names $($se | ConvertTo-Json -Compress)"
    $order = @('a_orders', 'b_filler', 'c_lines', 'x_y', 'x_y_2', 'v_orders') | ForEach-Object { Join-Path $snapDir "$ss.$_.sql" }
    $si = Api '/api/import' @{ conn = $conn; files = $order; targetDb = $st }
    $shape = Scalar ("SELECT CONCAT((SELECT COUNT(*) FROM $st.a_orders), '/', (SELECT COUNT(*) FROM $st.c_lines), '/', " +
                     "(SELECT COUNT(*) FROM $st.a_orders o LEFT JOIN $st.c_lines l ON l.order_id = o.id WHERE l.id IS NULL) + (SELECT COUNT(*) FROM $st.c_lines l LEFT JOIN $st.a_orders o ON o.id = l.order_id WHERE o.id IS NULL), '/', " +
                     "(SELECT COUNT(*) FROM $st.``x y``) + (SELECT COUNT(*) FROM $st.x_y))")
    $parts = "$shape" -split '/'
    Check ($si.ok -and $parts.Count -eq 4 -and [int]$parts[0] -gt 0 -and $parts[0] -eq $parts[1] -and $parts[2] -eq '0' -and $parts[3] -eq '2') "its files restore to one moment: every order with its line ($shape of $written written)" ($si | ConvertTo-Json -Compress)
    Remove-Item $snapDir -Recurse -Force -ErrorAction SilentlyContinue
    foreach ($s in @("DROP DATABASE IF EXISTS $ss", "DROP DATABASE IF EXISTS $st")) { Api '/api/exec' @{ conn = $conn; sql = $s } | Out-Null }

    # --- 5. compare reports rows that exist only on the TARGET ---------------------------------
    # Neither "missing from target" nor the per-column diff covers those, so a target holding
    # extra rows used to read as "no row differences" - the wrong answer when checking production
    # against a copy.
    $cs = 'nobs_live_cmp_src'
    $ct = 'nobs_live_cmp_tgt'
    $cn = "nobs_live_cmp_$PID"
    Api '/api/conn-save' @{ name = $cn; conn = $conn; accent = '#3b82f6'; env = 'test'; readonly = $false; savepw = $true } | Out-Null
    $setup = @(
        "DROP DATABASE IF EXISTS $cs", "CREATE DATABASE $cs"
        "DROP DATABASE IF EXISTS $ct", "CREATE DATABASE $ct"
        "CREATE TABLE $cs.t (id INT PRIMARY KEY, v VARCHAR(16))"
        "CREATE TABLE $ct.t (id INT PRIMARY KEY, v VARCHAR(16))"
        "INSERT INTO $cs.t VALUES (1,'a'),(2,'b')"
        "INSERT INTO $ct.t VALUES (1,'a'),(2,'b'),(7,'x'),(8,'y'),(9,'z')"
    )
    foreach ($s in $setup) { Api '/api/exec' @{ conn = $conn; sql = $s } | Out-Null }
    $cmp = Api '/api/compare-rows' @{ sourceConnName = $cn; sourceDb = $cs; targetConnName = $cn; targetDb = $ct; table = 't' }
    Check ($cmp.ok -and $cmp.missingTotal -eq 0) 'compare: nothing is missing from the target' "missingTotal=$($cmp.missingTotal)"
    Check ($cmp.extraTotal -eq 3) 'compare: the 3 target-only rows ARE reported' "extraTotal=$($cmp.extraTotal) - with nothing missing, this is the case that reads as 'no differences'"
    # Guarded: when the field is missing entirely (the bug this covers), indexing it throws and
    # the script dies mid-run instead of reporting a clean failure for the remaining checks.
    $extraIds = ''
    if ($cmp.extraPks) { $extraIds = (@($cmp.extraPks | ForEach-Object { [string]$_[0] }) -join ',') }
    Check ($extraIds -eq '7,8,9') 'compare: extraPks names exactly those rows' "got $extraIds"
    foreach ($s in @("DROP DATABASE IF EXISTS $cs", "DROP DATABASE IF EXISTS $ct")) { Api '/api/exec' @{ conn = $conn; sql = $s } | Out-Null }
    Api '/api/conn-delete' @{ name = $cn } | Out-Null

    # --- 5b. compare copies every value exactly --------------------------------------------------
    # All three write paths: insert-all (server to server), apply (rows that went through the
    # browser as JSON), and apply-diff (updates). Each was wrong for some value here: the text
    # 'NULL' arrived as NULL (--batch output), a text '0x41' was written as the byte A and an empty
    # binary value as the two characters 0x (the value's shape decided, not the column's type), and
    # a binary key did not match its own row once read as text. And a NUL inside text, which XML
    # output turns into a space, has to arrive as a NUL.
    $vs = 'nobs_live_val_src'
    $vt = 'nobs_live_val_tgt'
    $vn = "nobs_live_val_$PID"
    $cn = $vn
    Api '/api/conn-save' @{ name = $vn; conn = $conn; accent = '#3b82f6'; env = 'test'; readonly = $false; savepw = $true } | Out-Null
    $vdef = '(id VARBINARY(4) PRIMARY KEY, txt TEXT NULL, bin VARBINARY(8) NULL, big MEDIUMTEXT NULL, bits BIT(8) NULL, geo GEOMETRY NULL)'
    $setup = @(
        "DROP DATABASE IF EXISTS $vs", "CREATE DATABASE $vs CHARACTER SET utf8mb4"
        "DROP DATABASE IF EXISTS $vt", "CREATE DATABASE $vt CHARACTER SET latin1"
        "CREATE TABLE $vs.t $vdef"
        # latin1 on the target on purpose: a text value is converted, never poured in as bytes.
        "CREATE TABLE $vt.t $vdef"
        ("INSERT INTO $vs.t VALUES " +
         "(0x0001, 'NULL', X'', REPEAT('xy', 40000), b'101', ST_GeomFromText('POINT(1 2)'))," +
         "(0x00FF, NULL, NULL, CONCAT('a', CHAR(13), 'b', CHAR(10), 'c', CHAR(13), CHAR(10), CHAR(9), 'd'), NULL, NULL)," +
         "(0x41, '0x41', 0x0041, 'null', b'0', NULL)," +
         "(0x0A0D, CONVERT(x'C3A9' USING utf8mb4), 0x00, '', b'11111111', NULL)," +
         "(X'', '<&>`"''\\', 0x0A0D, '0x', NULL, NULL)," +
         # NUL inside text: mysql.exe --xml prints it as a space, so it has to be fetched another way.
         "(0x0B, CONVERT(x'610062' USING utf8mb4), NULL, CONVERT(CONCAT('x', CHAR(0), 'y') USING utf8mb4), NULL, NULL)")
    )
    foreach ($s in $setup) { $sr = Api '/api/exec' @{ conn = $conn; sql = $s }; if (-not $sr.ok) { "  note  setup: $($sr.error)" } }
    $same = "SELECT COUNT(*) FROM $vs.t s JOIN $vt.t d ON s.id = d.id WHERE " +
            "CONVERT(s.txt USING utf8mb4) <=> CONVERT(d.txt USING utf8mb4) AND CAST(CONVERT(s.txt USING utf8mb4) AS BINARY) <=> CAST(CONVERT(d.txt USING utf8mb4) AS BINARY) AND " +
            "s.bin <=> d.bin AND CAST(s.big AS BINARY) <=> CAST(d.big AS BINARY) AND s.bits <=> d.bits AND ST_AsBinary(s.geo) <=> ST_AsBinary(d.geo)"

    $ia = Api '/api/compare-rows-insert-all' @{ sourceConnName = $vn; sourceDb = $vs; targetConnName = $vn; targetDb = $vt; table = 't' }
    Check ($ia.ok -and $ia.inserted -eq 6) 'compare insert-all copies all 6 rows' ($ia | ConvertTo-Json -Compress)
    Check ((Scalar $same) -eq '6') 'compare insert-all: every value arrives exactly' "identical rows: $(Scalar $same)"

    Api '/api/exec' @{ conn = $conn; sql = "DELETE FROM $vt.t" } | Out-Null
    $cmpv = Api '/api/compare-rows' @{ sourceConnName = $vn; sourceDb = $vs; targetConnName = $vn; targetDb = $vt; table = 't' }
    Check ($cmpv.ok -and $cmpv.missingTotal -eq 6 -and @($cmpv.rows).Count -eq 6) 'compare finds the 6 missing rows, binary keys included' ("missing=$($cmpv.missingTotal) rows=$(@($cmpv.rows).Count) $($cmpv.error)")
    if ($cmpv.ok) {
        $ap = Api '/api/compare-rows-apply' @{ targetConnName = $vn; targetDb = $vt; table = 't'; columns = @($cmpv.columns); rows = @($cmpv.rows) }
        Check ($ap.ok -and -not (@($ap.log) -match '^FAILED')) 'compare apply succeeds' ($ap | ConvertTo-Json -Compress)
        Check ((Scalar $same) -eq '6') 'compare apply: every value arrives exactly after a trip through JSON' "identical rows: $(Scalar $same)"
    }

    Api '/api/exec' @{ conn = $conn; sql = "UPDATE $vt.t SET txt = 'changed', bin = 0x99, big = 'x', bits = b'1', geo = NULL" } | Out-Null
    $df = Api '/api/compare-rows-diff' @{ sourceConnName = $vn; sourceDb = $vs; targetConnName = $vn; targetDb = $vt; table = 't' }
    Check ($df.ok -and @($df.diffs).Count -eq 6) 'compare diff finds the 6 changed rows' ("diffs=$(@($df.diffs).Count) $($df.error)")
    if ($df.ok) {
        $ad = Api '/api/compare-rows-apply-diff' @{ targetConnName = $vn; targetDb = $vt; table = 't'; pkCols = @($df.pkCols); updates = @($df.diffs) }
        Check ($ad.ok) 'compare apply-diff succeeds' ($ad | ConvertTo-Json -Compress)
        Check ((Scalar $same) -eq '6') 'compare apply-diff: every value is restored exactly' "identical rows: $(Scalar $same)"
    }
    # Differences a case-insensitive, NULL-blind comparison did not see.
    Api '/api/exec' @{ conn = $conn; sql = "UPDATE $vt.t SET big = NULL WHERE id = 0x0A0D" } | Out-Null
    Api '/api/exec' @{ conn = $conn; sql = "UPDATE $vt.t SET big = 'NULL' WHERE id = 0x41" } | Out-Null
    $df2 = Api '/api/compare-rows-diff' @{ sourceConnName = $vn; sourceDb = $vs; targetConnName = $vn; targetDb = $vt; table = 't' }
    Check ($df2.ok -and @($df2.diffs).Count -eq 2) "compare diff sees NULL against '' and 'null' against 'NULL'" ("diffs=$(@($df2.diffs).Count) $($df2.error)")
    if ($df2.ok -and @($df2.diffs).Count) {
        $ad2 = Api '/api/compare-rows-apply-diff' @{ targetConnName = $vn; targetDb = $vt; table = 't'; pkCols = @($df2.pkCols); updates = @($df2.diffs) }
        Check ($ad2.ok -and (Scalar $same) -eq '6') 'and applying those restores them' "identical rows: $(Scalar $same)"
    }
    foreach ($s in @("DROP DATABASE IF EXISTS $vs", "DROP DATABASE IF EXISTS $vt")) { Api '/api/exec' @{ conn = $conn; sql = $s } | Out-Null }
    Api '/api/conn-delete' @{ name = $vn } | Out-Null
    $cn = $null

    # --- 5c. text keys holding a tab or a line break -----------------------------------------------
    # The key list used to be read from tab-separated output, so such a key fell apart, never
    # matched itself on the other side, and showed up as missing on one side and extra on the other.
    $ks = "nobs_live_key_src_$PID"; $kt = "nobs_live_key_tgt_$PID"; $kn = "nobs_live_key_$PID"
    $cn = $kn
    Api '/api/conn-save' @{ name = $kn; conn = $conn; accent = '#3b82f6'; env = 'test'; readonly = $false; savepw = $true } | Out-Null
    $kdef = '(k VARCHAR(20) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin PRIMARY KEY, v VARCHAR(10))'
    $keys = "(CONCAT('a', CHAR(9), 'b'), 'tab'), (CONCAT('c', CHAR(10), 'd'), 'lf'), (CONCAT('e', CHAR(13), CHAR(10)), 'crlf'), ('NULL', 'text'), ('p\\q', 'backslash')"
    foreach ($s in @("DROP DATABASE IF EXISTS $ks", "DROP DATABASE IF EXISTS $kt", "CREATE DATABASE $ks", "CREATE DATABASE $kt",
                     "CREATE TABLE $ks.t $kdef", "CREATE TABLE $kt.t $kdef",
                     "INSERT INTO $ks.t VALUES $keys, ('only-src', 'x')",
                     "INSERT INTO $kt.t VALUES $keys, ('only-tgt', 'y')",
                     "CREATE TABLE $ks.one (k VARCHAR(20) PRIMARY KEY, v VARCHAR(10))", "CREATE TABLE $kt.one (k VARCHAR(20) PRIMARY KEY, v VARCHAR(10))",
                     "INSERT INTO $ks.one VALUES ('single', 'new')", "INSERT INTO $kt.one VALUES ('single', 'old')")) {
        $sr = Api '/api/exec' @{ conn = $conn; sql = $s }; if (-not $sr.ok) { "  note  setup: $($sr.error)" }
    }
    $kc = Api '/api/compare-rows' @{ sourceConnName = $kn; sourceDb = $ks; targetConnName = $kn; targetDb = $kt; table = 't' }
    $missingKeys = @($kc.rows | ForEach-Object { [string]$_[0] }) -join ','
    $extraKeys = @($kc.extraPks | ForEach-Object { [string]$_[0] }) -join ','
    Check ($kc.ok -and $kc.missingTotal -eq 1 -and $kc.extraTotal -eq 1) 'compare matches keys holding a tab, a line break or a backslash' "missing=$($kc.missingTotal) extra=$($kc.extraTotal) $($kc.error)"
    # One row on each side is its own case: PowerShell unrolls a one-item list, and the single missing
    # row came back without its data, the single extra key as its first character.
    Check ($missingKeys -eq 'only-src' -and (@($kc.columns) -join ',') -eq 'k,v') 'a single missing row comes with its data' "rows=$($kc.rows | ConvertTo-Json -Compress) cols=$(@($kc.columns) -join ',')"
    Check ($extraKeys -eq 'only-tgt') 'a single target-only key is named whole' "extraPks=$($kc.extraPks | ConvertTo-Json -Compress)"
    Api '/api/exec' @{ conn = $conn; sql = "UPDATE $kt.t SET v = 'changed'" } | Out-Null
    $kd = Api '/api/compare-rows-diff' @{ sourceConnName = $kn; sourceDb = $ks; targetConnName = $kn; targetDb = $kt; table = 't' }
    Check ($kd.ok -and @($kd.diffs).Count -eq 5) 'and finds each of them as a changed row' "diffs=$(@($kd.diffs).Count) $($kd.error)"
    if ($kd.ok) {
        $ka = Api '/api/compare-rows-apply-diff' @{ targetConnName = $kn; targetDb = $kt; table = 't'; pkCols = @($kd.pkCols); updates = @($kd.diffs) }
        $same = Scalar "SELECT COUNT(*) FROM $ks.t s JOIN $kt.t d ON CAST(s.k AS BINARY) = CAST(d.k AS BINARY) AND s.v <=> d.v"
        Check ($ka.ok -and $same -eq '5') 'and updates exactly those rows' "matching rows=$same $($ka | ConvertTo-Json -Compress)"
    }
    $k1 = Api '/api/compare-rows-diff' @{ sourceConnName = $kn; sourceDb = $ks; targetConnName = $kn; targetDb = $kt; table = 'one' }
    Check ($k1.ok -and @($k1.diffs).Count -eq 1 -and [string]$k1.diffs[0].pk[0] -eq 'single') 'a table with a single common row is compared too' ($k1 | ConvertTo-Json -Compress -Depth 6)
    foreach ($s in @("DROP DATABASE IF EXISTS $ks", "DROP DATABASE IF EXISTS $kt")) { Api '/api/exec' @{ conn = $conn; sql = $s } | Out-Null }
    Api '/api/conn-delete' @{ name = $kn } | Out-Null
    $cn = $null

    # --- 5e. FLOAT keys, invisible and generated columns in Compare --------------------------------
    # A FLOAT key is read as rounded text, which matches nothing when compared to the column, so
    # such rows could not be fetched or updated; an update counted as done whatever it matched;
    # SELECT * left invisible columns out of copies; a generated column made the insert fail.
    $fs = "nobs_live_fk_src_$PID"; $ft = "nobs_live_fk_tgt_$PID"; $fn = "nobs_live_fk_$PID"
    $cn = $fn
    Api '/api/conn-save' @{ name = $fn; conn = $conn; accent = '#3b82f6'; env = 'test'; readonly = $false; savepw = $true } | Out-Null
    $fdef = '(k FLOAT PRIMARY KEY, a INT, secret VARCHAR(10) INVISIBLE, g INT GENERATED ALWAYS AS (a * 2) STORED)'
    foreach ($s in @("DROP DATABASE IF EXISTS $fs", "DROP DATABASE IF EXISTS $ft", "CREATE DATABASE $fs", "CREATE DATABASE $ft",
                     "CREATE TABLE $fs.t $fdef", "CREATE TABLE $ft.t $fdef",
                     "INSERT INTO $fs.t (k, a, secret) VALUES (1.1, 5, 's1'), (0.3, 6, 's3')",
                     "INSERT INTO $ft.t (k, a, secret) VALUES (0.3, 0, 'old')")) {
        $sr = Api '/api/exec' @{ conn = $conn; sql = $s }; if (-not $sr.ok) { "  note  setup: $($sr.error)" }
    }
    $fb = @{ sourceConnName = $fn; sourceDb = $fs; targetConnName = $fn; targetDb = $ft; table = 't' }
    $fi = Api '/api/compare-rows-insert-all' $fb
    Check ($fi.ok -and $fi.inserted -eq 1) 'compare copies a FLOAT-keyed missing row' ($fi | ConvertTo-Json -Compress)
    Check ((Scalar "SELECT CONCAT_WS('|', a, secret, g) FROM $ft.t WHERE k > 1") -eq '5|s1|10') 'whole: invisible column included, generated column computed'
    $fd = Api '/api/compare-rows-diff' $fb
    Check ($fd.ok -and @($fd.diffs).Count -eq 1) 'the FLOAT-keyed common row is compared' ($fd | ConvertTo-Json -Compress -Depth 6)
    if ($fd.ok) {
        $fa = Api '/api/compare-rows-apply-diff' @{ targetConnName = $fn; targetDb = $ft; table = 't'; pkCols = @($fd.pkCols); updates = @($fd.diffs) }
        Check ($fa.ok -and (Scalar "SELECT CONCAT_WS('|', a, secret, g) FROM $ft.t WHERE k < 1") -eq '6|s3|12') 'and updated by its key' ($fa | ConvertTo-Json -Compress)
        Api '/api/exec' @{ conn = $conn; sql = "DELETE FROM $ft.t WHERE k < 1" } | Out-Null
        $fg = Api '/api/compare-rows-apply-diff' @{ targetConnName = $fn; targetDb = $ft; table = 't'; pkCols = @($fd.pkCols); updates = @($fd.diffs) }
        Check (-not $fg.ok -and (@($fg.log) -join ' ') -match 'no longer matches exactly one target row') 'a row deleted on the target since fails the batch' ($fg | ConvertTo-Json -Compress)
    }
    # Schema sync rebuilt a column from its type, NULL, default and EXTRA: MODIFY COLUMN changed a
    # latin1_bin column to the table's default collation and dropped its comment, and a generated
    # column could not be added at all.
    foreach ($s in @("DROP DATABASE IF EXISTS $fs", "DROP DATABASE IF EXISTS $ft", "CREATE DATABASE $fs DEFAULT CHARACTER SET utf8mb4", "CREATE DATABASE $ft DEFAULT CHARACTER SET utf8mb4",
                     "CREATE TABLE $fs.t (id INT PRIMARY KEY, name VARCHAR(10) CHARACTER SET latin1 COLLATE latin1_bin NOT NULL COMMENT 'customer name', a INT, g INT GENERATED ALWAYS AS (a * 2) VIRTUAL)",
                     "CREATE TABLE $ft.t (id INT PRIMARY KEY, name VARCHAR(10) CHARACTER SET latin1 COLLATE latin1_bin NULL, a INT)")) {
        $sr = Api '/api/exec' @{ conn = $conn; sql = $s }; if (-not $sr.ok) { "  note  setup: $($sr.error)" }
    }
    $sc = Api '/api/compare-schemas' @{ sourceConnName = $fn; sourceDb = $fs; targetConnName = $fn; targetDb = $ft }
    $stmts = @($sc.tables | ForEach-Object { $_.sql } | Where-Object { $_.checked } | ForEach-Object { [string]$_.stmt })
    Check ($sc.ok -and $stmts.Count -eq 2) 'schema compare offers one MODIFY and one ADD' (($stmts -join ' ; ') + " $($sc.error)")
    $sa = Api '/api/compare-apply' @{ targetConnName = $fn; targetDb = $ft; statements = $stmts }
    $shape = Scalar "SELECT CONCAT_WS('|', COLLATION_NAME, IS_NULLABLE, COLUMN_COMMENT) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='$ft' AND COLUMN_NAME='name'"
    Check ($shape -ceq 'latin1_bin|NO|customer name') 'schema sync keeps a column''s collation and comment' "$shape $($sa | ConvertTo-Json -Compress)"
    $gen = Scalar "SELECT LOWER(GENERATION_EXPRESSION) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='$ft' AND COLUMN_NAME='g'"
    Check (($gen -replace '[`() ]', '') -eq 'a*2') 'and adds a generated column with its expression' $gen
    $sc2 = Api '/api/compare-schemas' @{ sourceConnName = $fn; sourceDb = $fs; targetConnName = $fn; targetDb = $ft }
    Check ($sc2.ok -and @($sc2.tables | Where-Object { $_.status -ne 'same' }).Count -eq 0) 'after which nothing is left to sync' ($sc2 | ConvertTo-Json -Compress -Depth 5)
    foreach ($s in @("DROP DATABASE IF EXISTS $fs", "DROP DATABASE IF EXISTS $ft")) { Api '/api/exec' @{ conn = $conn; sql = $s } | Out-Null }
    Api '/api/conn-delete' @{ name = $fn } | Out-Null
    $cn = $null

    # --- 5f. a script returns every result set ----------------------------------------------------
    # A procedure's results, and every SELECT but the last in a script, were run and thrown away.
    $srp = "DELIMITER `$`$`nCREATE PROCEDURE sr_two(IN n INT)`nBEGIN`n  SELECT id, v FROM sr_t WHERE id <= n ORDER BY id;`n  UPDATE sr_t SET v = 'touched' WHERE id = 3;`n  SELECT COUNT(*) AS c, MAX(b) AS mb FROM sr_t;`nEND`$`$`nDELIMITER ;"
    $su = Api '/api/script' @{ conn = $conn; db = 'nobs_test'; sql = "DROP PROCEDURE IF EXISTS sr_two; DROP TABLE IF EXISTS sr_t; CREATE TABLE sr_t (id INT PRIMARY KEY, v VARCHAR(10), b VARBINARY(4)); INSERT INTO sr_t VALUES (1,'one',0x00FF),(2,NULL,NULL),(3,'NULL',X'');`n$srp" }
    if (-not $su.ok) { "  note  setup: $($su.error)" }
    $sr = Api '/api/script-results' @{ conn = $conn; db = 'nobs_test'; sql = 'CALL sr_two(2);'; maxRows = 1000 }
    $sets = @($sr.results)
    Check ($sr.ok -and $sets.Count -eq 2) "a procedure's two results both come back" ($sr | ConvertTo-Json -Compress -Depth 6)
    if ($sets.Count -eq 2) {
        $s0 = ($sets[0].rows | ForEach-Object { ($_ | ForEach-Object { if ($null -eq $_) { '<NULL>' } else { $_ } }) -join '|' }) -join ';'
        Check ((@($sets[0].columns) -join ',') -eq 'id,v' -and $s0 -ceq '1|one;2|<NULL>') 'with their columns, NULL kept' $s0
        Check (($sets[1].rows[0] -join '|') -ceq '3|0x00FF') 'and binary as hex' ($sets[1].rows[0] -join '|')
    }
    $sr = Api '/api/script-results' @{ conn = $conn; db = 'nobs_test'; sql = "SELECT 'NULL' AS a;`nSELECT id FROM sr_t WHERE 0;`nSELECT id FROM bulk_rows ORDER BY id;"; maxRows = 10 }
    $sets = @($sr.results)
    Check ($sr.ok -and $sets.Count -eq 3 -and [string]$sets[0].rows[0][0] -ceq 'NULL' -and @($sets[1].rows).Count -eq 0) 'every SELECT of a script, an empty one included' ($sr | ConvertTo-Json -Compress -Depth 4)
    if ($sets.Count -eq 3) {
        Check ((@($sets[1].columns) -join ',') -eq 'id') 'an empty result still has its column names' ($sets[1] | ConvertTo-Json -Compress)
        Check (@($sets[2].rows).Count -eq 10 -and $sets[2].rowCount -eq 100000 -and $sets[2].truncated) 'a big result keeps its first rows and counts all' "$(@($sets[2].rows).Count) $($sets[2].rowCount)"
    }
    # Run on its own, a statement after a USE could read a different table, so its names stay unknown;
    # and a procedure is never run twice to get them.
    $sr = Api '/api/script-results' @{ conn = $conn; db = 'nobs_test'; sql = "USE nobs_test;`nSELECT id FROM sr_t WHERE 0;`nSELECT 1 AS a;" }
    Check ($sr.ok -and @($sr.results).Count -eq 2 -and @($sr.results[0].columns).Count -eq 0) 'not after a USE' ($sr | ConvertTo-Json -Compress -Depth 4)
    $su2 = Api '/api/script' @{ conn = $conn; db = 'nobs_test'; sql = "DROP PROCEDURE IF EXISTS sr_empty;`nCREATE PROCEDURE sr_empty() SELECT id FROM sr_t WHERE 0" }
    $sr = Api '/api/script-results' @{ conn = $conn; db = 'nobs_test'; sql = "CALL sr_empty();`nSELECT 1 AS a;" }
    Check ($su2.ok -and $sr.ok -and @($sr.results[0].columns).Count -eq 0) 'not for a procedure' ($sr | ConvertTo-Json -Compress -Depth 4)
    Api '/api/script' @{ conn = $conn; db = 'nobs_test'; sql = 'DROP PROCEDURE IF EXISTS sr_empty' } | Out-Null
    $sr = Api '/api/script-results' @{ conn = $conn; db = 'nobs_test'; sql = "SELECT 1 AS a;`nSELECT * FROM sr_no_such_table;`nSELECT 2 AS b;" }
    Check (-not $sr.ok -and $sr.error -match 'at line 2' -and @($sr.results).Count -eq 1) 'an error reports its line, with the result before it' ($sr | ConvertTo-Json -Compress -Depth 4)
    $sr = Api '/api/script-results' @{ conn = $conn; db = 'nobs_test'; ro = $true; sql = 'CALL sr_two(1)' }
    Check (-not $sr.ok -and $sr.error -match 'READ-ONLY') 'read-only mode refuses a CALL' ($sr | ConvertTo-Json -Compress)
    Api '/api/script' @{ conn = $conn; db = 'nobs_test'; sql = 'DROP PROCEDURE sr_two; DROP TABLE sr_t' } | Out-Null

    # --- 5d. a table grid reads text holding a NUL exactly ---------------------------------------
    # XML output shows the NUL as a space, and Apply's WHERE then matched the row whose key really
    # is 'a b'. The grid's query asks for such values as hex as well (exactTextQuery in the UI) and
    # the server puts them back, on every page.
    $xd = "nobs_live_exact_$PID"
    $nul = [string][char]0
    foreach ($s in @("DROP DATABASE IF EXISTS $xd", "CREATE DATABASE $xd",
                     "CREATE TABLE $xd.t (k VARCHAR(10) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin PRIMARY KEY, note TEXT CHARACTER SET latin1)",
                     "INSERT INTO $xd.t VALUES (CONCAT('a', CHAR(0), 'b'), CONCAT('x', CHAR(0), 'y')), ('a b', 'plain'), ('c', CONCAT('late', CHAR(0))), ('d', 'caf$([char]0xE9)')")) {
        $sr = Api '/api/exec' @{ conn = $conn; sql = $s }; if (-not $sr.ok) { "  note  setup: $($sr.error)" }
    }
    $conv = { param($c) "CONVERT(``$c`` USING utf8mb4)" }
    $xsql = "SELECT k, note, UPPER(k) AS k" +
        ", IF(LOCATE(0x00, CAST($(& $conv 'k') AS BINARY)) > 0, HEX($(& $conv 'k')), NULL) AS ``__nobs_exact_0``" +
        ", IF(LOCATE(0x00, CAST($(& $conv 'note') AS BINARY)) > 0, HEX($(& $conv 'note')), NULL) AS ``__nobs_exact_1``" +
        " FROM $xd.t ORDER BY k"
    $xp = Api '/api/query' @{ conn = $conn; sql = $xsql; pageSize = 2; exactText = @('k', 'note') }
    $xrows = @($xp.rows)
    if ($xp.hasMore) { $xn = Api '/api/fetch-cursor-batch' @{ cursorId = $xp.cursorId; pageSize = 10 }; $xrows += @($xn.rows) }
    $xs = ($xrows | ForEach-Object { ($_ | ForEach-Object { if ($null -eq $_) { 'NULL' } else { ([string]$_).Replace($nul, '<0>') } }) -join '|' }) -join ' ; '
    Check ($xp.ok -and (@($xp.columns) -join ',') -eq 'k,note,k') 'the hex columns are not shown' "$(@($xp.columns) -join ',') $($xp.error)"
    Check ($xs -ceq "a<0>b|x<0>y|A B ; a b|plain|A B ; c|late<0>|C ; d|caf$([char]0xE9)|D") 'keys and text holding a NUL come back exactly, on every page' $xs
    $xe = Api '/api/query' @{ conn = $conn; sql = "SELECT k, note FROM $xd.t"; pageSize = 2; exactText = @('k') }
    Check (-not $xe.ok -and $xe.error -match '__nobs_exact_0') 'a result without the hex columns is an error, not a guess' ($xe | ConvertTo-Json -Compress)
    Api '/api/exec' @{ conn = $conn; sql = "DROP DATABASE IF EXISTS $xd" } | Out-Null

    # --- 6. paging a cursor delivers every row exactly once -------------------------------------
    # The Tauri edition dropped one row at every page boundary by reading a look-ahead row and
    # discarding it; a forward-only cursor cannot re-read it. This edition holds it back
    # (NobsXmlRows.Page) and emits it first next time. Keep it that way.
    $first = Api '/api/query' @{ conn = $conn; db = 'nobs_test'; sql = 'SELECT id FROM bulk_rows ORDER BY id LIMIT 25'; pageSize = 10 }
    $got = @($first.rows | ForEach-Object { [string]$_[0] })
    $more = $first.hasMore
    $guard = 0
    while ($more -and $guard -lt 10) {
        $guard++
        $next = Api '/api/fetch-cursor-batch' @{ cursorId = $first.cursorId; pageSize = 10 }
        if (-not $next.ok) { break }
        $got += @($next.rows | ForEach-Object { [string]$_[0] })
        $more = $next.hasMore
    }
    Check ($got.Count -eq 25) 'paging 25 rows at 10/page delivers all 25' "got $($got.Count): $($got -join ',')"
    Check ((@($got | Select-Object -Unique)).Count -eq 25) 'no row is delivered twice'

    # --- values holding CR / LF, and NULL-looking text, come back as themselves --------------------
    # Rows used to be parsed from --batch output. It escapes LF but not CR, and rows were cut with
    # ReadLine(), which also stops at CR - so such a row split in two and every later column
    # shifted. The NULL marker was matched ignoring case, so 'null' read as NULL. And --batch prints
    # the text 'NULL' exactly like NULL, which no option changes; the rows now come from --xml.
    # MySQL's own mysql.exe additionally writes every LF as CRLF, value bytes included.
    $crSql = "SELECT CONVERT(CONCAT('a',CHAR(10),'b',CHAR(13),'c',CHAR(13),CHAR(10)) USING utf8mb4) AS t, 0x0A0D AS b, " +
             "CONVERT(0x0A USING utf8mb4) AS lf, 'null' AS n, 'NULL' AS nn, 'x' AS after, x'' AS eb, '<&>`"' AS mk " +
             "UNION ALL SELECT '', NULL, NULL, 'Null', NULL, 'y', NULL, NULL"
    $cr = Api '/api/query' @{ conn = $conn; sql = $crSql }
    Check ($cr.ok -and @($cr.rows).Count -eq 2) 'a CR inside a value does not split its row' "rows=$(@($cr.rows).Count) $($cr.error)"
    if ($cr.ok -and @($cr.rows).Count -eq 2) {
        $r0 = $cr.rows[0]; $r1 = $cr.rows[1]
        Check ((@($cr.columns) -join ',') -ceq 't,b,lf,n,nn,after,eb,mk') 'column names' (@($cr.columns) -join ',')
        Check ($r0[0] -ceq "a`nb`rc`r`n")  'text with LF, CR and CRLF arrives intact' (($r0[0] | ConvertTo-Json -Compress))
        Check ($r0[1] -ceq '0x0A0D')       'binary 0x0A0D arrives as its hex'
        Check ($r0[2] -ceq "`n")           'a value of one line feed is not NULL'
        Check ($r0[3] -ceq 'null' -and $r1[3] -ceq 'Null') "the text 'null' is not NULL"
        Check ($r0[4] -ceq 'NULL')         "the text 'NULL' is not NULL" (($r0[4] | ConvertTo-Json -Compress))
        Check ($null -eq $r1[4])           "and NULL is still NULL"
        Check ($r0[5] -ceq 'x' -and $r1[5] -ceq 'y') 'the column after them is still in place'
        Check ($r1[0] -ceq '' -and $null -eq $r1[1]) 'empty string and NULL stay distinct'
        Check ($r0[6] -ceq '0x' -and $null -eq $r1[6]) 'empty binary and NULL binary stay distinct'
        Check ($r0[7] -ceq '<&>"')         'markup characters arrive as themselves'
    }

    # XML output carries no column names for a result without rows. They are asked for again only
    # when the statement is safe to repeat - an empty table still has to show its columns.
    $empty = Api '/api/query' @{ conn = $conn; db = 'nobs_test'; sql = 'SELECT id, bin_col FROM charset_binary WHERE 1=0' }
    Check ($empty.ok -and (@($empty.columns) -join ',') -eq 'id,bin_col' -and @($empty.rows).Count -eq 0) 'an empty result still has its column names' ($empty | ConvertTo-Json -Compress)
    $emptyW = Api '/api/query' @{ conn = $conn; sql = 'DO 1; SELECT 1 AS a FROM DUAL WHERE 1=0' }
    Check ($emptyW.ok -and @($emptyW.columns).Count -eq 0 -and $emptyW.message -match 'not available') 'a statement that is not safe to repeat is not run twice for them' ($emptyW | ConvertTo-Json -Compress)
    $multi = Api '/api/query' @{ conn = $conn; sql = 'SELECT 1 AS a; SELECT 2 AS b' }
    Check ($multi.ok -and (@($multi.columns) -join ',') -eq 'a' -and [string]$multi.rows[0][0] -eq '1' -and @($multi.rows).Count -eq 1) 'several statements show the first result' ($multi | ConvertTo-Json -Compress)
    $big = Api '/api/query' @{ conn = $conn; sql = "SELECT REPEAT(CONVERT(x'C3A9' USING utf8mb4), 70000) AS v" }
    Check ($big.ok -and ([string]$big.rows[0][0]).Length -eq 70000 -and ([string]$big.rows[0][0]).Trim([char]0xE9) -eq '') 'a 70,000-character value arrives whole' "len=$(([string]$big.rows[0][0]).Length)"
    $ddl = Api '/api/ddl' @{ conn = $conn; db = 'nobs_test'; type = 'table'; name = 'charset_binary' }
    Check ($ddl.ok -and [string]$ddl.ddl -match '(?s)CREATE TABLE.*\n') 'SHOW CREATE TABLE still arrives with its line breaks' ($ddl | ConvertTo-Json -Compress)

    # --- the CA certificate is actually used, not just written down ------------------------------
    # Writing ssl-ca= into the options file proves nothing on its own: the client could ignore it
    # and the connection would still succeed, which is exactly the shape of failure that makes a
    # security setting worthless. So point "verify" at a real, well-formed CA that did NOT sign
    # this server's certificate - it has to be refused - and then at the same CA under "required",
    # which verifies nothing and so must still connect.
    $bogusCa = Join-Path $env:TEMP ("nobs-bogus-ca-" + [Guid]::NewGuid().ToString('N') + ".pem")
    # Defined here and not borrowed from the block below: this one runs first, and relying on a
    # variable set further down the file is how it ran with a null client path the first time.
    $caClient = Join-Path $env:APPDATA 'NOBSSQL\bin\mysql.exe'
    if (-not (Test-Path $caClient)) { "  skip  no mysql client found for the CA checks" } else {
    try {
        $rsa = [System.Security.Cryptography.RSA]::Create(2048)
        $req = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
            'CN=NOBS Test Bogus CA', $rsa,
            [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $req.CertificateExtensions.Add(
            [System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($true,$false,0,$true))
        $bc = $req.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddYears(5))
        ("-----BEGIN CERTIFICATE-----`n" + [Convert]::ToBase64String($bc.RawData,'InsertLineBreaks') +
         "`n-----END CERTIFICATE-----`n") | Set-Content -Path $bogusCa -Encoding ascii

        # This file drives the app over HTTP and so does not otherwise have its functions in scope.
        # These two checks are about what New-Cnf writes, so they need the real thing rather than a
        # restatement of it - load the definitions out of the script the same way the offline tests
        # do, into a child scope so nothing here leaks into the HTTP-driven checks above.
        $caOk = & {
            $pe=$null;$pt=$null
            $pa=[System.Management.Automation.Language.Parser]::ParseFile($ScriptPath,[ref]$pt,[ref]$pe)
            $pa.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true) |
                ForEach-Object { Invoke-Expression $_.Extent.Text }
            $script:ToolsDir  = Split-Path -Parent $caClient
            $script:MysqlPath = $caClient
            $try = {
                param($mode, $ca)
                $c = [pscustomobject]@{ host=$conn.host; port=$conn.port; user=$conn.user; password=$conn.password; ssl=$mode; sslCa=$ca }
                $cnf = New-Cnf $c
                try { (Run-Proc $script:MysqlPath @("--defaults-extra-file=$cnf","-N","-B","-e","SELECT 1")).exit -eq 0 }
                finally { Remove-Item $cnf -Force -ErrorAction SilentlyContinue }
            }
            $serverCa = $env:NOBS_TEST_SERVER_CA
            [pscustomobject]@{
                verify   = (& $try 'verify' $bogusCa)
                verifyCa = (& $try 'verify-ca' $bogusCa)
                required = (& $try 'required' $bogusCa)
                # The decisive one: same modes, the server's OWN CA. Without it, "refused with the
                # wrong CA" cannot be told apart from "refused because the CA is ignored".
                rightCa  = if ($serverCa -and (Test-Path $serverCa)) { & $try 'verify-ca' $serverCa } else { $null }
            }
        }
        Check (-not $caOk.verify)   'ssl=verify refuses a CA that did not sign the server certificate'
        Check (-not $caOk.verifyCa) 'ssl=verify-ca refuses it too - it relaxes the host name, not the chain'
        Check $caOk.required        'ssl=required ignores the CA and still connects'
        # See the Tauri repo's docs/TESTING.md for pulling the server's CA off the wire with openssl.
        if ($null -eq $caOk.rightCa) { "  skip  NOBS_TEST_SERVER_CA not set - the right-CA check did not run" }
        else { Check $caOk.rightCa 'ssl=verify-ca connects with the server''s own CA' }
        # --- a MySQL server is queried with MySQL's own client ----------------------------------------
        # Only MySQL's client can check a CA without the host name ('verify-ca'), and a MySQL server's
        # generated certificate never names a real host - so over anything but loopback, MariaDB's
        # client cannot connect to it that way at all. This edition runs every query through mysql.exe,
        # so a MySQL server gets MySQL's client throughout. Needs the server's CA and an address other
        # than loopback (NOBS_TEST_REMOTE_HOST, e.g. this machine's LAN address).
        $remote = $env:NOBS_TEST_REMOTE_HOST
        $tools = Api '/api/tools-status' @{}
        $cx = Api '/api/connect' @{ conn = $conn }
        if (-not $env:NOBS_TEST_SERVER_CA -or -not $remote) {
            "  skip  NOBS_TEST_SERVER_CA / NOBS_TEST_REMOTE_HOST not set - verify-ca through MySQL's client did not run"
        } elseif ($cx.mariadb -or -not $tools.mysql_for_mysql) {
            "  skip  not a MySQL server, or no MySQL client tools here - verify-ca through MySQL's client did not run"
        } else {
            Check ($cx.client -eq $tools.mysql_for_mysql) "a MySQL server is queried with MySQL's client" "client=$($cx.client)"
            $caUser = "nobs_live_ca_$PID"; $caPw = 'Ca-' + [Guid]::NewGuid().ToString('N')
            $made = Api '/api/exec' @{ conn = $conn; sql = "CREATE USER '$caUser'@'%' IDENTIFIED BY '$caPw'" }
            try {
                Api '/api/exec' @{ conn = $conn; sql = "GRANT SELECT ON nobs_test.* TO '$caUser'@'%'" } | Out-Null
                $rc = @{ host = $remote; port = $conn.port; user = $caUser; password = $caPw; ssl = 'verify-ca'; sslCa = $env:NOBS_TEST_SERVER_CA }
                $rcx = Api '/api/connect' @{ conn = $rc }
                Check ($made.ok -and $rcx.ok) "verify-ca connects to a MySQL server over $remote" ($rcx | ConvertTo-Json -Compress)
                $rq = Api '/api/query' @{ conn = $rc; db = 'nobs_test'; sql = 'SELECT COUNT(*) FROM ro_canary' }
                Check ($rq.ok -and [string]$rq.rows[0][0] -eq '3') 'and queries over it' ($rq | ConvertTo-Json -Compress)
                $bad = @{ host = $remote; port = $conn.port; user = $caUser; password = $caPw; ssl = 'verify-ca'; sslCa = $bogusCa }
                if ($bogusCa) {
                    $bx = Api '/api/connect' @{ conn = $bad }
                    Check (-not $bx.ok) 'while a CA that did not sign the certificate is still refused' ($bx | ConvertTo-Json -Compress)
                }
            } finally {
                Api '/api/exec' @{ conn = $conn; sql = "DROP USER IF EXISTS '$caUser'@'%'" } | Out-Null
            }
        }

    } finally { Remove-Item $bogusCa -Force -ErrorAction SilentlyContinue }
    }

    # --- losing the connection halfway through an apply ------------------------------------------
    # Staged grid edits go to /api/script with transaction:true. That protects against a statement
    # FAILING; this is the other way a batch stops halfway, and the one a lid-close or a VPN drop
    # actually produces. The connection is severed for real (a second session KILLs the one running
    # the batch) because what is being checked is as much the server's behaviour as the app's.
    $mysql = Join-Path $env:APPDATA 'NOBSSQL\bin\mysql.exe'
    if (-not (Test-Path $mysql)) {
        "  skip  no mysql client found for the connection-loss test"
    } else {
        $cnf = Join-Path $env:TEMP ("livetx-" + [Guid]::NewGuid().ToString('N') + ".cnf")
        # Same plugin-dir the app's own New-Cnf writes - without it this helper cannot authenticate
        # to a MySQL 8 server at all, since caching_sha2_password is a client-side plugin.
        $body = "[client]`nhost=$($conn.host)`nport=$($conn.port)`nuser=$($conn.user)`npassword=$($conn.password)"
        $plugDir = Join-Path (Split-Path -Parent $mysql) 'plugin'
        if (Test-Path $plugDir) { $body += "`nplugin-dir=$($plugDir -replace '\\','\\')" }
        $body | Set-Content -NoNewline -Encoding ascii $cnf
        function Sql($q) { & $mysql "--defaults-extra-file=$cnf" -N -B -e $q 2>&1 }
        try {
            Sql "CREATE DATABASE IF NOT EXISTS nobs_test" | Out-Null
            Sql "DROP TABLE IF EXISTS nobs_test.tx_drop" | Out-Null
            Sql "CREATE TABLE nobs_test.tx_drop (id INT PRIMARY KEY) ENGINE=InnoDB" | Out-Null

            # Two rows land, then the batch parks on a SLEEP long enough to be killed from outside,
            # then a third row that must never be reached.
            $batch = "INSERT INTO nobs_test.tx_drop VALUES (1);`n" +
                     "INSERT INTO nobs_test.tx_drop VALUES (2);`n" +
                     "SELECT SLEEP(30) /*nobs_kill_me*/;`n" +
                     "INSERT INTO nobs_test.tx_drop VALUES (3);"
            $job = Start-ThreadJob -ScriptBlock {
                param($base,$token,$batch)
                try {
                    Invoke-RestMethod -Uri "$base/api/script" -Method Post -ContentType 'application/json' -TimeoutSec 60 -Body (
                        @{ token=$token; sql=$batch; db='nobs_test'; transaction=$true;
                           conn=$using:conn } | ConvertTo-Json -Depth 5)
                } catch { @{ ok = $false; error = "$_" } }
            } -ArgumentList $base, $token, $batch

            # Wait for the batch to show up, then kill whichever connection is running it.
            $killed = $false
            for ($i = 0; $i -lt 100 -and -not $killed; $i++) {
                $ids = Sql "SELECT ID FROM information_schema.PROCESSLIST WHERE INFO LIKE '%nobs_kill_me%' AND INFO NOT LIKE '%PROCESSLIST%'"
                foreach ($id in @($ids)) {
                    if ("$id".Trim() -match '^\d+$') { Sql "KILL $($id.Trim())" | Out-Null; $killed = $true }
                }
                if (-not $killed) { Start-Sleep -Milliseconds 50 }
            }
            Check $killed 'the mid-apply batch was found and its connection killed'

            $res = Receive-Job $job -Wait -AutoRemoveJob
            $left = "$(Sql 'SELECT COUNT(*) FROM nobs_test.tx_drop')".Trim()
            # The two rows that had already been inserted must be gone: the transaction never
            # reached its COMMIT, and the server discards an open one when the connection dies.
            Check ($left -eq '0') 'a connection lost mid-apply leaves no partial rows behind' "$left row(s) survived"
            # And it has to say so. Reporting success here is the worst of the outcomes: the user
            # closes the dialog believing the edits are saved.
            Check (-not $res.ok) 'a batch whose connection was killed is reported as failed' "got ok=$($res.ok)"
        } finally {
            Sql "DROP TABLE IF EXISTS nobs_test.tx_drop" | Out-Null
            Remove-Item $cnf -Force -ErrorAction SilentlyContinue
        }
    }
}
finally {
    if ($token -and $base) {
        # The compare check saves a profile into the user's REAL connection store, because compare
        # resolves servers by saved name. Its inline delete only runs if nothing between the two
        # threw - and an earlier run that died there left "nobs_live_cmp_<pid>" behind in a real
        # connection list. Deleting here as well makes that impossible; deleting twice is harmless.
        if ($cn) {
            try { Invoke-RestMethod -Uri "$base/api/conn-delete" -Method Post -ContentType 'application/json' -TimeoutSec 5 `
                    -Body (@{ token = $token; name = $cn } | ConvertTo-Json) | Out-Null } catch { }
        }
        try { Invoke-RestMethod -Uri "$base/api/quit" -Method Post -ContentType 'application/json' -Body "{""token"":""$token""}" -TimeoutSec 5 | Out-Null } catch { }
    }
    Start-Sleep -Milliseconds 800
    if ($proc -and -not $proc.HasExited) { try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch { } }
    Remove-Item $outFile, $errFile -ErrorAction SilentlyContinue
}

# A suite that prints "all passed" underneath a red stack trace is the exact failure this file's
# header warns about, and it happened: a block called a function that was not in scope, errored,
# skipped every one of its checks, and the run still reported success. A second block ran with a
# null path for the same reason.
#
# Not all of $Error, though. Plenty in here is expected and deliberately swallowed - a dump process
# that has already exited, a temp path already cleaned up - and failing on those would make the
# suite useless. What is NEVER expected is the test itself being wrong: a command that does not
# exist in scope, or an argument that arrived null. Those two are programming errors in this file,
# and they are precisely the ones that silently skip checks.
$unexpected = @($Error | Where-Object {
    $_.Exception -is [System.Management.Automation.CommandNotFoundException] -or
    $_.Exception -is [System.Management.Automation.ParameterBindingException]
})
if ($unexpected.Count) {
    "`n  $($unexpected.Count) unexpected error(s) - checks may have been skipped:"
    $unexpected | Select-Object -First 5 | ForEach-Object { "    $($_.ToString().Split("`n")[0])" }
}
if ($script:fail -or $unexpected.Count) {
    "`n  $($script:fail) FAILED$(if($unexpected.Count){" + $($unexpected.Count) error(s)"})"; exit 1
} else { "`n  all passed"; exit 0 }
