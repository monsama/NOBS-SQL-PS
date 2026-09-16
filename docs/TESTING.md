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

The export-cancel case needs the cancel to land while the routines/events dump is in flight. Since
a cancel during the table loop skips that step entirely, the test excludes every table so
routines/events is the only work left, then sweeps short delays — and **asserts that it actually
reached the step**, so it cannot pass by never getting there. An earlier version of the test, using
fixed delays and no such assertion, passed against the unfixed code.
