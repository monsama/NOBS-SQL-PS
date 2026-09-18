# Testing

Fifteen test scripts, all plain PowerShell, all taking the path to `NOBSSQL.ps1` so they exercise
the file that actually ships rather than a copy of it.

```powershell
pwsh -NoProfile -File tests/Test-SqlReadOnly.Tests.ps1   ./NOBSSQL.ps1
pwsh -NoProfile -File tests/Get-CnfSafe.Tests.ps1        ./NOBSSQL.ps1
pwsh -NoProfile -File tests/SslLines.Tests.ps1           ./NOBSSQL.ps1
pwsh -NoProfile -File tests/PluginDir.Tests.ps1          ./NOBSSQL.ps1
pwsh -NoProfile -File tests/BatchFailureNote.Tests.ps1   ./NOBSSQL.ps1
pwsh -NoProfile -File tests/DumpTarget.Tests.ps1         ./NOBSSQL.ps1
pwsh -NoProfile -File tests/ResultRows.Tests.ps1         ./NOBSSQL.ps1
pwsh -NoProfile -File tests/UiParses.Tests.ps1           ./NOBSSQL.ps1
pwsh -NoProfile -File tests/ConnSslCa.Tests.ps1          ./NOBSSQL.ps1
pwsh -NoProfile -File tests/TableDesigner.Tests.ps1      ./NOBSSQL.ps1
pwsh -NoProfile -File tests/DdlRecreate.Tests.ps1        ./NOBSSQL.ps1
pwsh -NoProfile -File tests/UserSql.Tests.ps1            ./NOBSSQL.ps1
pwsh -NoProfile -File tests/ViewIndices.Tests.ps1        ./NOBSSQL.ps1
pwsh -NoProfile -File tests/ToolChoice.Tests.ps1         ./NOBSSQL.ps1
pwsh -NoProfile -File tests/UpdateCheck.Tests.ps1        ./NOBSSQL.ps1
pwsh -NoProfile -File tests/TableBinding.Tests.ps1       ./NOBSSQL.ps1
pwsh -NoProfile -File tests/GridSave.Tests.ps1           ./NOBSSQL.ps1
pwsh -NoProfile -File tests/Live.Tests.ps1               ./NOBSSQL.ps1
```

All but the last need nothing set up. `Live` needs a database. CI runs all of them on every push,
`Live` against a MariaDB and a MySQL server it starts itself (see below).

| Script | Covers | Needs |
|---|---|---|
| `Test-SqlReadOnly` | the read-only/safe-mode guard, as a pure function | nothing |
| `Get-CnfSafe` | newline injection into the generated `.cnf` | nothing |
| `SslLines` | the SSL options written into the `.cnf`, per client dialect | nothing |
| `PluginDir` | where the client looks for its authentication plugins | nothing |
| `BatchFailureNote` | what a failed batch may honestly claim about rollback | nothing |
| `DumpTarget` | restoring a dump into a chosen target database, not the one it came from | nothing |
| `ResultRows` | reading rows out of `mysql --xml` output, captured from both clients: NULL vs the text `'NULL'`, CR/LF, binary, empty results; putting back text values holding a NUL in a table grid | nothing |
| `UiParses` | that every inline `<script>` in the page parses | `node` on PATH |
| `ConnSslCa` | that every save and load of a connection carries its CA certificate | `node` on PATH |
| `TableDesigner` | that editing a column keeps everything the designer does not show | `node` on PATH |
| `DdlRecreate` | recovering a procedure, function or trigger whose recreate failed | `node` on PATH |
| `UserSql` | the SQL the Users dialog and the grid build client-side, including the table grid query that reads text holding a NUL exactly | `node` on PATH |
| `ViewIndices` | the grid's sort/filter ordering | `node` on PATH |
| `UpdateCheck` | the new-version notice: shown when newer, quiet when hidden, switched off or offline | `node` on PATH |
| `TableBinding` | which database and table a result grid saves to (after a leading `USE`, or with another schema selected), and control characters shown in text | `node` on PATH |
| `GridSave` | how saving grid edits finds each row: a guard before every change, FLOAT and TIMESTAMP keys, a missing key column | `node` on PATH |
| `ToolChoice` | which client tools a MariaDB or a MySQL server gets, the options file written for them, reading MySQL's download page and a tool's version, release version comparison, the options file for Compare's UTC sessions, the column definitions schema sync writes, and that every script-level value a request reads reaches the request threads | nothing |
| `Live` | the running server, against a real database | `NOBS_TEST_DSN` |

The node-based scripts test JavaScript embedded in `NOBSSQL.ps1`, so unlike the others they
cannot lift their subject out with the PowerShell AST. They extract it by brace-matching and run it
under `node`, which the `windows-latest` CI image already ships. If `node` is missing they **fail**
rather than skipping.

`ConnSslCa`, `TableDesigner`, `DdlRecreate`, `UpdateCheck`, `TableBinding` and `GridSave` embed the very same test files the Tauri edition
runs (`tests/ui/*.test.mjs` in nobs-sql-editor), pointed at this file through `NOBS_UI_SOURCE`.
They are generated from those files - regenerate rather than edit them by hand.

`DumpTarget` and `ResultRows` compile the script's small C# helper, so they also prove it builds
on whichever PowerShell runs them; run them under Windows PowerShell 5.1 as well as pwsh.

`SslLines` and `PluginDir` are about the client binary rather than the server, so they need no
database: `SslLines` asks the real client to parse the options it would be given (`--version` is
enough - the options file is read before a socket is opened), and `PluginDir` works on a throwaway
directory tree.

## The live tests

```powershell
$env:NOBS_TEST_DSN = '127.0.0.1:3306:root:yourpassword'
pwsh -NoProfile -File tests/Live.Tests.ps1 ./NOBSSQL.ps1
```

It starts the real server on its usual port, drives the real HTTP API, and stops it again. Load
the fixture first - it is shared with the sibling
[nobs-sql-editor](https://github.com/monsama/nobs-sql-editor) repo, at
`tests/fixtures/seed.sql` there:

```powershell
mysql -u root -p < ..\nobs-sql-editor\tests\fixtures\seed.sql
```

It creates only `nobs_test` and touches no other schema. The live tests restore what they change,
so running them twice in a row behaves the same as running them once.

### Run it against MySQL too, not just MariaDB

The two behave differently in ways that only surface against the real thing, and every one of
these was found that way rather than by reading:

- MySQL authenticates with `caching_sha2_password` by default. That is a *client-side* plugin, and
  the app could not connect to a stock MySQL 8 server at all until the downloaded tools started
  shipping it - see `PluginDir`.
- MySQL and MariaDB name their SSL client options mutually exclusively, so the wrong dialect is not
  a weaker connection but no connection - see `SslLines`.
- MySQL cannot reference the same `TEMPORARY` table twice in one statement, which is why the shared
  fixture builds `bulk_rows` from a plain table.
- `SLEEP()` interrupted by `KILL QUERY` *returns 1* on MySQL and the statement succeeds; MariaDB
  raises an error. Anything testing cancellation needs a real query, not a sleep.

```powershell
$env:NOBS_TEST_DSN = '127.0.0.1:3308:root:yourpassword'   # a MySQL 8 instance
pwsh -NoProfile -File tests/Live.Tests.ps1 ./NOBSSQL.ps1
```

The suite is expected to pass unchanged against MariaDB 12.x and MySQL 8.x alike.

### And with MySQL's own `mysql.exe`

The *client* matters as much as the server, because every query goes through it:

- Without a character set it takes the console code page (cp850 here), so text written through
  it was converted wrongly. The options file now sets `default-character-set=utf8mb4`.
- On Windows it writes every LF as CRLF, value bytes included. The XML reader undoes that.

The app takes the client from its `config.json`, so point it elsewhere with a scratch `APPDATA`
rather than touching your own settings. The script prints which client the server is using.

```powershell
$scratch = "$env:TEMP\nobs-mysql-client"
New-Item -ItemType Directory -Force "$scratch\NOBSSQL" | Out-Null
'{"mysql_bin":"C:/Program Files/MySQL/MySQL Server 8.0/bin/mysql.exe","mysqldump_bin":"C:/Program Files/MySQL/MySQL Server 8.0/bin/mysqldump.exe"}' |
    Set-Content "$scratch\NOBSSQL\config.json"
$env:APPDATA = $scratch; pwsh -NoProfile -File tests/Live.Tests.ps1 ./NOBSSQL.ps1
```

The CA and connection-loss checks use the downloaded client under the real `APPDATA` directly, so
in this run they say they skipped.

### The CA certificate checks

With `NOBS_TEST_REMOTE_HOST` set as well - an address of the MySQL test server other than
loopback, such as this machine's LAN address - the suite connects there with `verify-ca` through
the app, as a temporary user it creates and drops. That is the case only MySQL's client can do,
because the certificate a MySQL server generates for itself never names a real host.

Set `NOBS_TEST_SERVER_CA` to the test server's own CA to run the one check that matters most:
`verify-ca` connecting with it. Without that, the remaining CA checks only show that a *wrong* CA
is refused - and a CA being silently ignored would be refused in exactly the same way against a
self-signed server. The script says when it skipped this. The Tauri repo's `docs/TESTING.md`
shows how to take the CA off the wire with `openssl`, no access to the server's files needed.

`ConnSslCa.Tests.ps1` embeds the same JavaScript test file the Tauri edition runs
(`tests/ui/conn-ssl-ca.test.mjs` there). Keep the two copies in step.

**Without `NOBS_TEST_DSN` the script prints `SKIPPED` and exits 0.** That is deliberate, and so is
how loud it is about it: a test that quietly reports success for work it never did is worse than
no test, and this project has been bitten by exactly that before.

### In CI

GitHub's service containers are Linux-only while this app targets Windows, so the `live` job in
`.github/workflows/test.yml` starts the servers itself. It checks out nobs-sql-editor and runs
`tests/ci/start-test-servers.ps1` from there (see that repo's `docs/TESTING.md`):

- It downloads and starts MariaDB and MySQL and loads the shared fixture.
- MySQL is unpacked where a real installation lives, so this app finds MySQL's own client there.
- MariaDB's client tools and plugins go where this app's own download puts them.

The suite then runs once per server. On the MySQL run `NOBS_TEST_REMOTE_HOST` is the runner's
own network address, so the `verify-ca` check runs too.

After that the same job runs the GUI tests, which drive this script's UI in headless Edge: grid
editing, Compare, the export and import dialogs, and a script's results. The scenarios are
shared with the desktop edition and live in nobs-sql-editor (`tests/gui`, see its
`docs/TESTING.md`). To run them here:

```powershell
$env:NOBS_TEST_DSN = '127.0.0.1:3306:root:yourpassword'
node ..nobs-sql-editor	estsguiun.mjs --app ps --target .NOBSSQL.ps1
```

### What it covers

Every check is a regression test for a bug that actually shipped:

- **The keepalive ping requires the token.** `LastPing` drives the six-hour idle shutdown, so
  while `/api/ping` was unauthenticated any web page the user had open could hold the server -
  and the live database connections it owns - open indefinitely, with a periodic cross-origin
  POST to this fixed, predictable port.
- **Read-only mode is enforced server-side**, on the SQL endpoints *and* on `/api/rowop` and the
  staged-apply path, not merely by a greyed-out button.
- **A staged batch is all-or-nothing.** A partial apply is the worst outcome this app can produce
  and the whole reason the pending-changes model exists. Five ways of failing mid-batch are
  checked, plus the control that a *valid* batch still commits - without which a transaction that
  always rolled back would pass every other case.
- **A cancelled export says `CANCELLED`**, never a `FAILED` line with no reason given.
- **Compare reports rows that exist only on the target**, including when nothing is missing -
  the case that otherwise reads as "no row differences".
- **Compare copies every value exactly**, through all three write paths (insert-all, apply,
  apply-diff): the text `'NULL'` (which `--batch` output turned into NULL), text that looks like
  hex (written as bytes when the value's shape decided), an empty binary value (written as the
  characters `0x`), a binary key, CR/LF, a NUL inside text (which XML output turns into a space),
  BIT, spatial, and a latin1 target. The diff also sees NULL against `''` and `'null'` against
  `'NULL'`.
- **The tools match the server**: MySQL's own for a MySQL server when the machine has them - for
  queries (`verify-ca` over a LAN address) as well as export and import, and a table with generated columns comes back whole from its own dump.
  Without MySQL's tools the export must be refused instead.
- **Paging a cursor delivers every row exactly once**, with no row dropped at a page boundary.
- **Result values arrive as themselves**: NULL vs `'NULL'`, CR/LF inside text, empty vs NULL
  binary, markup characters, a 70,000-character value, column names of an empty result (asked for
  again only when the statement is safe to repeat), and the first of several result sets.
- **Every kind of input stores exactly the bytes it should.** The byte-fidelity matrix, below.

### The byte-fidelity matrix

Three binary-fidelity bugs shipped in a single week, in code that read correctly and passed the
tests that existed at the time: the stdout reader destroying every byte that was not valid UTF-8,
hex pasted into the value editor's Text tab being stored as the characters `0x24…` rather than the
bytes they denote, and an emptied cell storing the two characters `0x` instead of nothing. None
were found by reasoning about the code. All three were found by putting a value in, reading it
back, and comparing bytes - so that comparison is a test now.

It builds each statement with the **real** editor functions lifted out of `NOBSSQL.ps1`
(`textToHex`, `normalizeHexInput`, `hexCellValueForSave`, `lit`), sends it through the app's own
API, and compares `HEX(col)` against the bytes that went in. Twenty-four inputs: quotes,
backslashes including a trailing one, four-byte emoji, CJK, RTL, embedded newlines and tabs,
Windows line breaks, a lone CR, injection-shaped text, 64 KB, text that looks like hex, and on the
hex side app-style, Workbench-spaced, line-wrapped, unprefixed, uppercase, a lone NUL byte, bytes
that are not valid UTF-8, and empty.

The statements go through `/api/script`, as the grid's Apply sends them, and the text cases are
also written through `strLit` into a real utf8mb4 text column: a BLOB stores whatever bytes
arrive, so on its own it cannot see a client converting from the wrong character set, and
`mysql.exe` reading a script turns CR LF into LF unless the CR is escaped.

Two of those cases guard specific fixes and are worth not weakening:

- **64 KB** guards `New-SqlArg`. SQL used to go to `mysql.exe` as a single `-e` argument, and
  Windows caps a command line at about 32767 characters - so a value over roughly 8 KB became a
  hex literal too long to pass, and `Process.Start` threw. What the user saw was a raw .NET
  exception naming `mysql.exe`, with nothing in it about SQL or size. Oversized statements now go
  to a temp file that mysql is told to `source`. Raise `New-SqlArg`'s threshold so it never
  triggers and this case fails.
- **empty** guards `hexCellValueForSave`. Both tabs produce a digit-less `0x` for an empty box,
  which is not valid SQL and which `lit()` would quote - storing the characters `0` and `x`.

The export-cancel case needs the cancel to land while the routines/events dump is in flight. Since
a cancel during the table loop skips that step entirely, the test excludes every table so
routines/events is the only work left, then sweeps short delays - and **asserts that it actually
reached the step**, so it cannot pass by never getting there. An earlier version of the test, using
fixed delays and no such assertion, passed against the unfixed code.

## Checking real data for corruption

`tools/Check-BlobIntegrity.ps1` audits a live server for the corruption signatures this app has
actually produced. It is read-only - it runs SELECTs and writes nothing.

```powershell
pwsh -NoProfile -File tools/Check-BlobIntegrity.ps1 -Dsn '127.0.0.1:3306:root:yourpassword'
pwsh -NoProfile -File tools/Check-BlobIntegrity.ps1 -Dsn '...' -Schema just_this_one
```

Exit code 0 means nothing was found, 1 means it has findings to look at, 2 means it could not run.

| signature | what it means |
|---|---|
| `hex-text` | the value begins with the two **characters** `0` and `x` - a binary cell is displayed as `0x..`, so a copied one pastes back as hex, and stored as text it becomes the characters rather than the bytes |
| `embedded-hex` | a `0x` run of 16+ hex digits sits inside other content - a paste that landed alongside the cell's existing value instead of replacing it |
| `bare-hex` | the whole value is hex digits with no prefix, and long enough not to be coincidence |
| `replacement` | the value contains U+FFFD, which nothing stores on purpose - some layer decoded and re-encoded the data |
| `nul-in-text` | a NUL byte inside a text column, occasionally the tail of a binary value written to the wrong place |

Findings are candidates, not verdicts. A column that legitimately holds hex text will be reported
and should be - the row count and sample are there to tell the difference. Two worked examples
from this codebase:

- A `mediumblob` holding `0x2437…` followed by a crypt hash was a real loss, and recovered by
  un-hexing the leading run.
- A migration log holding one U+FFFD inside a column comment, **identical on two separate
  servers**, was baked into the migration script itself. Nothing to fix.

Worth running after any session of hand-editing binary columns, and before trusting a backup.
