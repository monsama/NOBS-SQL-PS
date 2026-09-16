# Testing

Four test scripts, all plain PowerShell, all taking the path to `NOBSSQL.ps1` so they exercise
the file that actually ships rather than a copy of it.

```powershell
pwsh -NoProfile -File tests/Test-SqlReadOnly.Tests.ps1 ./NOBSSQL.ps1
pwsh -NoProfile -File tests/Get-CnfSafe.Tests.ps1     ./NOBSSQL.ps1
pwsh -NoProfile -File tests/ViewIndices.Tests.ps1     ./NOBSSQL.ps1
pwsh -NoProfile -File tests/Live.Tests.ps1            ./NOBSSQL.ps1
```

The first three need nothing set up and run in CI on every push. The fourth needs a database and
does not — see below.

| Script | Covers | Needs |
|---|---|---|
| `Test-SqlReadOnly` | the read-only/safe-mode guard, as a pure function | nothing |
| `Get-CnfSafe` | newline injection into the generated `.cnf` | nothing |
| `ViewIndices` | the grid's sort/filter ordering | `node` on PATH |
| `Live` | the running server, against a real database | `NOBS_TEST_DSN` |

`ViewIndices` tests JavaScript embedded in `NOBSSQL.ps1`, so unlike the other two offline scripts
it cannot lift its subject out with the PowerShell AST. It extracts the function by brace-matching
and runs it under `node`, which the `windows-latest` CI image already ships. If `node` is missing
it **fails** rather than skipping.

## The live tests

```powershell
$env:NOBS_TEST_DSN = '127.0.0.1:3306:root:yourpassword'
pwsh -NoProfile -File tests/Live.Tests.ps1 ./NOBSSQL.ps1
```

It starts the real server on its usual port, drives the real HTTP API, and stops it again. Load
the fixture first — it is shared with the sibling
[NOBS-SQL-Editor](https://github.com/monsama/NOBS-SQL-Editor) repo, at
`tests/fixtures/seed.sql` there:

```powershell
mysql -u root -p < ..\NOBS-SQL-Editor\tests\fixtures\seed.sql
```

It creates only `nobs_test` and touches no other schema. The live tests restore what they change,
so running them twice in a row behaves the same as running them once.

**Without `NOBS_TEST_DSN` the script prints `SKIPPED` and exits 0.** That is deliberate, and so is
how loud it is about it: a test that quietly reports success for work it never did is worse than
no test, and this project has been bitten by exactly that before.

### Why this one is not in CI

`windows-latest` has no database, and GitHub's service containers are Linux-only while this app
targets Windows. Wiring it up would mean either installing and seeding MariaDB on the Windows
runner, or porting the suite to Linux — where the app shells out to `mysql.exe` by name. Until
then these are a local gate, run before releasing.

### What it covers

Every check is a regression test for a bug that actually shipped:

- **The keepalive ping requires the token.** `LastPing` drives the six-hour idle shutdown, so
  while `/api/ping` was unauthenticated any web page the user had open could hold the server —
  and the live database connections it owns — open indefinitely, with a periodic cross-origin
  POST to this fixed, predictable port.
- **Read-only mode is enforced server-side**, on the SQL endpoints *and* on `/api/rowop` and the
  staged-apply path, not merely by a greyed-out button.
- **A staged batch is all-or-nothing.** A partial apply is the worst outcome this app can produce
  and the whole reason the pending-changes model exists. Five ways of failing mid-batch are
  checked, plus the control that a *valid* batch still commits — without which a transaction that
  always rolled back would pass every other case.
- **A cancelled export says `CANCELLED`**, never a `FAILED` line with no reason given.
- **Compare reports rows that exist only on the target**, including when nothing is missing —
  the case that otherwise reads as "no row differences".
- **Paging a cursor delivers every row exactly once**, with no row dropped at a page boundary.
- **Every kind of input stores exactly the bytes it should.** The byte-fidelity matrix, below.

### The byte-fidelity matrix

Three binary-fidelity bugs shipped in a single week, in code that read correctly and passed the
tests that existed at the time: the stdout reader destroying every byte that was not valid UTF-8,
hex pasted into the value editor's Text tab being stored as the characters `0x24…` rather than the
bytes they denote, and an emptied cell storing the two characters `0x` instead of nothing. None
were found by reasoning about the code. All three were found by putting a value in, reading it
back, and comparing bytes — so that comparison is a test now.

It builds each statement with the **real** editor functions lifted out of `NOBSSQL.ps1`
(`textToHex`, `normalizeHexInput`, `hexCellValueForSave`, `lit`), sends it through the app's own
API, and compares `HEX(col)` against the bytes that went in. Twenty-two inputs: quotes,
backslashes including a trailing one, four-byte emoji, CJK, RTL, embedded newlines and tabs,
injection-shaped text, 64 KB, text that looks like hex, and on the hex side app-style,
Workbench-spaced, line-wrapped, unprefixed, uppercase, a lone NUL byte, bytes that are not valid
UTF-8, and empty.

Two of those cases guard specific fixes and are worth not weakening:

- **64 KB** guards `New-SqlArg`. SQL used to go to `mysql.exe` as a single `-e` argument, and
  Windows caps a command line at about 32767 characters — so a value over roughly 8 KB became a
  hex literal too long to pass, and `Process.Start` threw. What the user saw was a raw .NET
  exception naming `mysql.exe`, with nothing in it about SQL or size. Oversized statements now go
  to a temp file that mysql is told to `source`. Raise `New-SqlArg`'s threshold so it never
  triggers and this case fails.
- **empty** guards `hexCellValueForSave`. Both tabs produce a digit-less `0x` for an empty box,
  which is not valid SQL and which `lit()` would quote — storing the characters `0` and `x`.

The export-cancel case needs the cancel to land while the routines/events dump is in flight. Since
a cancel during the table loop skips that step entirely, the test excludes every table so
routines/events is the only work left, then sweeps short delays — and **asserts that it actually
reached the step**, so it cannot pass by never getting there. An earlier version of the test, using
fixed delays and no such assertion, passed against the unfixed code.
