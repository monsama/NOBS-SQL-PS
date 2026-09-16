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
try {
    # The server takes the first free port from its fixed list; find whichever it got.
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline -and -not $token) {
        foreach ($try in 17673, 17674, 17675, 17676, 17677, 17678, 17679, 17680) {
            try {
                $html = Invoke-WebRequest -Uri "http://127.0.0.1:$try/" -TimeoutSec 2 -UseBasicParsing
                if ($html.Content -match 'const TOKEN="([a-f0-9]+)"') {
                    $base = "http://127.0.0.1:$try"
                    $token = $Matches[1]
                    break
                }
            } catch { }
        }
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
    # Make it deterministic instead: exclude every table, so the routines/events dump is the only
    # work the export has to do and any cancel shortly after start lands inside it. Then sweep
    # short delays, stopping as soon as the step has actually been reached.
    $tabsR = Sql "SELECT table_name FROM information_schema.tables WHERE table_schema='nobs_test'" 'nobs_test'
    $excludeAll = @($tabsR.rows | ForEach-Object { 'nobs_test.' + [string]$_[0] })

    $sawCancel = $false
    $reachedRoutines = $false
    $reasonless = @()
    # Retry until the window is actually observed rather than hoping one pass of a fixed sweep
    # lands in it. The dump is quick, so the window is narrow and a single sweep does flake; each
    # attempt is cheap (every table is excluded, so there is almost nothing else to do). The sweep
    # is cycled with a small jitter so repeated attempts do not all land in the same place.
    $delaySweep = @(20, 30, 40, 55, 70, 85, 100, 120, 145, 175, 210, 260, 320, 400, 500)
    $attempt = 0
    while (-not ($reachedRoutines -and $sawCancel) -and $attempt -lt 45) {
        $delay = $delaySweep[$attempt % $delaySweep.Count] + (Get-Random -Minimum 0 -Maximum 12)
        $attempt++
        $folder = Join-Path ([IO.Path]::GetTempPath()) "nobs-live-exp-$PID-$delay"
        Remove-Item $folder -Recurse -Force -ErrorAction SilentlyContinue
        $jobId = "live-$PID-$delay"
        $bg = Start-Job -ScriptBlock {
            param($base, $token, $conn, $folder, $jobId, $excludes)
            $b = @{
                token = $token; conn = $conn; dbs = @('nobs_test'); folder = $folder
                mode = 'table'; jobId = $jobId; excludes = $excludes
                options = @{ charset = 'utf8mb4'; routines = $true; events = $true; quick = $true; extinsert = $true }
            }
            Invoke-RestMethod -Uri "$base/api/export" -Method Post -ContentType 'application/json' -Body ($b | ConvertTo-Json -Depth 8 -Compress) -TimeoutSec 600
        } -ArgumentList $base, $token, $conn, $folder, $jobId, $excludeAll
        Start-Sleep -Milliseconds $delay
        Api '/api/cancel-job' @{ jobId = $jobId } | Out-Null
        $res = Receive-Job -Job $bg -Wait -AutoRemoveJob
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

    # --- 4d. binary values survive the trip through the CLI ------------------------------------
    # Rows are parsed out of mysql.exe's stdout. Reading that stream as UTF-8 made the decoder
    # replace every byte that was not valid UTF-8 with U+FFFD before any of this app's code saw
    # it: VARBINARY 00 FF 10 arrived as 0x00EFBFBD10. It was not merely a display problem - the
    # grid writes a cell back exactly as it holds it, so saving such a row committed the mangled
    # bytes to disk. The reader is byte-preserving now and CellVal decides per field whether the
    # bytes are text or binary.
    $cb = Api '/api/query' @{ conn = $conn; db = 'nobs_test'; sql = 'SELECT bin_col, blob_col, bit8, emoji, cjk FROM charset_binary WHERE id=1' }
    Check ($cb.ok -and [string]$cb.rows[0][0] -eq '0x00FF10') 'a VARBINARY column arrives with its bytes intact' ("got " + [string]$cb.rows[0][0])
    Check ([string]$cb.rows[0][1] -eq '0xDEADBEEF') 'a BLOB column arrives with its bytes intact' ("got " + [string]$cb.rows[0][1])
    Check ([string]$cb.rows[0][2] -eq '0xAA') 'a BIT(8) column arrives as its real byte' ("got " + [string]$cb.rows[0][2])
    # The same change must not break text: these share the stream and are decoded as UTF-8.
    Check ([string]$cb.rows[0][3] -eq ([char]::ConvertFromUtf32(0x1F600))) 'a 4-byte emoji still arrives as itself' ("got " + [string]$cb.rows[0][3])
    Check ([string]$cb.rows[0][4] -ne '' -and [string]$cb.rows[0][4] -notmatch [char]0xFFFD) 'CJK text still arrives undamaged' ("got " + [string]$cb.rows[0][4])
    # NULL must stay distinguishable from an empty binary. (This is why --binary-as-hex on the
    # client was not usable: it renders NULL and empty identically, both as "0x".)
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
  out.push({ id, label, tab, literal: F.lit(forEmpty(hex)),
             expect: tab === 'text' ? hexOf(value) : hex.slice(2).toUpperCase() });
}
console.log(JSON.stringify(out));
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
        Api '/api/exec' @{ conn = $conn; sql = 'CREATE TABLE nobs_test.rt_probe (id INT PRIMARY KEY, b LONGBLOB)' } | Out-Null
        $bad = @()
        foreach ($c in $rtCases) {
            $ins = Api '/api/exec' @{ conn = $conn; sql = "INSERT INTO nobs_test.rt_probe VALUES ($($c.id), $($c.literal))" }
            if (-not $ins.ok) { $bad += "$($c.label): insert failed - $($ins.error)"; continue }
            $got = Scalar "SELECT IFNULL(HEX(b),'<NULL>') FROM rt_probe WHERE id=$($c.id)" 'nobs_test'
            if ($got -ne $c.expect) {
                $sg = if ($got.Length -gt 40) { $got.Substring(0,40) + '...' } else { $got }
                $se = if ($c.expect.Length -gt 40) { $c.expect.Substring(0,40) + '...' } else { $c.expect }
                $bad += "[$($c.tab)] $($c.label): got $sg want $se"
            }
        }
        Check ($bad.Count -eq 0) "every one of $($rtCases.Count) inputs stores exactly the bytes it should" ($bad -join ' | ')
        Api '/api/exec' @{ conn = $conn; sql = 'DROP TABLE IF EXISTS nobs_test.rt_probe' } | Out-Null
    }

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

    # --- 6. paging a cursor delivers every row exactly once -------------------------------------
    # The Tauri edition dropped one row at every page boundary by reading a look-ahead row and
    # discarding it; a forward-only cursor cannot re-read it. This edition holds it in
    # $cursorObj.Pending and emits it first next time. Keep it that way.
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
}
finally {
    if ($token -and $base) {
        try { Invoke-RestMethod -Uri "$base/api/quit" -Method Post -ContentType 'application/json' -Body "{""token"":""$token""}" -TimeoutSec 5 | Out-Null } catch { }
    }
    Start-Sleep -Milliseconds 800
    if ($proc -and -not $proc.HasExited) { try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch { } }
    Remove-Item $outFile, $errFile -ErrorAction SilentlyContinue
}

if ($script:fail) { "`n  $script:fail FAILED"; exit 1 } else { "`n  all passed"; exit 0 }
