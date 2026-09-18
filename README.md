# NOBS SQL Editor - PowerShell edition

A MySQL / MariaDB client that runs as a **single PowerShell script**. It starts
a tiny local HTTP server (127.0.0.1 only, no admin rights), shells out to the
`mysql` / `mysqldump` command-line tools, and opens its UI in your default
browser.

This is the same application as
[nobs-sql-editor](https://github.com/monsama/nobs-sql-editor), which packages
the same UI as a native desktop app using [Tauri](https://tauri.app). Use this
edition when you want zero installation, or a machine where you cannot install
software.

## Running

```powershell
powershell -ExecutionPolicy Bypass -File .\NOBSSQL.ps1
```

This script is not code-signed, and running it means switching the execution policy off, so it is
worth knowing you have the file that was published. Every release names its SHA-256, in the notes
and in `SHA256SUMS.txt` beside the download:

```powershell
Get-FileHash .\NOBSSQL.ps1 -Algorithm SHA256
```

[CODE_SIGNING.md](https://github.com/monsama/nobs-sql-editor/blob/main/CODE_SIGNING.md) says what
that does and does not prove: it tells you the file reached you as it was built, and nothing about
who wrote it.

If Chrome or Edge is installed, the interface opens in a window of its own, using a
separate browser profile with extensions switched off - so nothing installed in your
everyday browser reaches these fields. That matters mostly for password managers, which
otherwise offer to fill a saved credential into the box deciding which database server
you connect to. Without Chrome or Edge it falls back to your default browser, where your
extensions do apply as usual.

**Closing the console window stops the server.** Pass `-NoBrowser` to start the server
without opening a browser.

Requires Windows PowerShell 5.1 or later.

## Features

- Connections with saved profiles, a per-connection accent colour and
  environment label, and a **read-only / safe mode** to protect production
  servers.
- Browse schemas, tables, views, procedures, functions, triggers and events,
  with quick filtering and search across all schemas.
- Tabbed SQL editor with syntax highlighting, autocomplete, query formatting,
  and run-whole-script or run-selection. A procedure call, or a script with
  several SELECTs, shows each result in a tab of its own.
- Result grids with per-column filtering and sorting, column resize and
  show/hide, and a row-detail form view for wide tables.
- Inline and full-row editing staged as pending changes and applied in a single
  transaction; add and delete rows.
- Export tables or query results to CSV or INSERT statements; CSV import.
- Table designer, DDL view and edit, users and privileges, table maintenance,
  ER diagrams, server process list, and a reusable query library.

## Keeping data exact

- **Saving grid edits:** each change is checked, inside the same transaction, to match exactly
  one row. Otherwise nothing is saved. This catches a row changed or deleted since it was loaded,
  and a TIMESTAMP key in the hour the clocks go back (it shows the same as its neighbour). FLOAT
  keys are shown rounded, so they are matched by their text.
- **Grid edits go to the database the query ran in**, including after a leading `USE`.
- **Compare runs both connections in UTC.** TIMESTAMP values therefore copy correctly between
  servers in different time zones, and Compare shows them in UTC.
- **Copies name their columns** (Compare, Duplicate table, INSERT exports). Invisible columns are
  included; generated columns are left out, since the server computes them. CSV exports include
  every column, and the CSV import skips generated ones.
- **INSERT exports skip rows whose key already exists** (`ON DUPLICATE KEY UPDATE`). They used
  `INSERT IGNORE`, which also cuts a value that does not fit instead of failing.
- **The CSV import is strict.** Header names match the table's columns ignoring case. A column
  the table does not have, or a row with more or fewer fields than the header, imports nothing.
  Foreign key and unique checks stay on, and the whole file is one transaction.
- **A per-table export is one snapshot.** The whole database is dumped once and then split into
  one file per table or view, so the files are consistent with each other even while the database
  is being written to. Two tables whose names give the same file name get two files.
- **Schema sync writes each column as the source server defines it**, including its character
  set, collation, comment and generated expression.

## SSL / TLS

Each connection has an SSL mode, and optionally a CA certificate (a `.pem` file) that the two
verifying modes check the server against.

| Mode | Encrypted | Certificate checked against the CA | Host name checked |
|---|---|---|---|
| `default` | as negotiated | – | – |
| `disabled` | no | – | – |
| `required` | yes | no | no |
| `verify-ca` | yes | yes | no ¹ |
| `verify` | yes | yes | yes |

¹ With the MySQL client. The MariaDB client - the one this app downloads - cannot check a CA
without also checking the host name, except on connections to the local machine, so with it
`verify-ca` is carried out as full `verify`. It never checks less than you asked for.

**Against a MariaDB 11.4+ server, with the MariaDB client, `verify` needs no CA at all.** The
client verifies the server's certificate through the password exchange instead, and that works
for the self-signed certificate MariaDB generates for itself, remote connections included. (It is
switched off for accounts without a password.)

**Against a MySQL server using its self-signed, auto-generated certificate**, that does not
apply: you need the server's CA, and - because the certificate never names a real host - the
MySQL client with `verify-ca` (point Settings at a MySQL `mysql.exe`). The MariaDB client can only
do this for a server on the local machine.

Where to get the CA: for MySQL it is `ca.pem` in the server's data directory. MariaDB's generated
certificate has no separate CA - use the certificate itself. Either can be read off the
connection, which needs no access to the server's files:

```sh
echo | openssl s_client -starttls mysql -connect HOST:PORT -showcerts
```

The CA is the last certificate printed (for MariaDB, the only one).

## Client tools (mysql / mysqldump)

Export and Import use the official MySQL/MariaDB command-line tools, which are
**not bundled**. On first use, point the app at an existing install in
Settings, or let it download the official MariaDB client tools from
mariadb.org. The archive is checked against the SHA-256 that MariaDB's own
release API publishes for it before anything is unpacked, and a mismatch
installs nothing - the checksum comes from the API, not from the mirror the
bytes came from, so a redirected or altered download fails the check. If the
API lists no checksum, nothing is installed at all.

Auto-detection checks, in order: saved configuration, the system PATH, then
common install folders (`Program Files\MariaDB*`, `Program Files\MySQL`,
XAMPP).

**MySQL servers get MySQL's own tools** when there are any: the two optional
"MySQL servers" paths in Settings, or else the newest MySQL Server installation
(`Program Files\MySQL\MySQL Server *\bin`). That applies to everything - queries,
the grid and Compare as well as Export and Import - since this edition runs all of
it through `mysql.exe`. What a server is gets asked when you connect (with MySQL's
client too, if the default one cannot reach it) and remembered per host and port.
MariaDB servers, and MySQL servers on a machine without MySQL's tools, use the
default pair. With MySQL's client, `verify-ca` works against a MySQL server's
self-generated certificate from any address. It matters because MariaDB's
mysqldump writes values into a MySQL table's generated columns, which MySQL
refuses when the dump is restored. Without MySQL's tools such an export is
refused rather than written.

**No MySQL installed?** Settings can download MySQL's own `mysql` and `mysqldump`
(the current 8.4 LTS release from dev.mysql.com). MySQL publishes Windows binaries
only as the full server archive, so this is a ~270 MB download of which about
14 MB is kept, in `bin\mysql\`. The archive is checked against the MD5 on MySQL's
download page before anything is unpacked, and a mismatch installs nothing. If
MySQL moves its page or files, `mysql_download_page` and
`mysql_download_url_template` (with `{series}`, `{version}`, `{file_name}`) in
the config file override the defaults.

Every query goes through `mysql.exe` too, and results are read from its `--xml
--binary-as-hex` output, because XML is the only output format that tells NULL apart
from the text `'NULL'`. That needs a client with `--binary-as-hex`: the MariaDB
tools the app downloads, or MySQL 8.0.19 or later. Binary, BIT and spatial values
are shown as `0x…` hex, as in the desktop edition.

The client writes a NUL byte (`0x00`) inside a **text** column as a space. Binary
columns are not affected. Where it matters the app reads such values separately:
a table grid (a query on one table, which is what grid edits are saved from) also
asks for each text column as hex wherever it holds a NUL, so the grid shows and
saves the exact value, and Compare does the same. Should a grid not be read that
way, saving refuses a table that has any such value rather than risk matching the
wrong row. Exporting a whole table from the tree refuses such a table and points to
the Export tool, which copies bytes exactly. The result of any other query - a join,
say - still shows a NUL in text as a space, and is exported that way.

## Updates

A few seconds after it starts, the app asks GitHub (`api.github.com`) for the latest release of
[nobs-sql-editor-powershell](https://github.com/monsama/nobs-sql-editor-powershell/releases). If a newer version exists, a small
notice with a link appears in the bottom-left corner. Nothing is downloaded or installed. The
request carries nothing beyond what any web request does: your IP address and a user agent
naming the app.

Hide the notice with its **×** and it stays hidden until the next version. Switch the check off,
or run it by hand, under **Settings → Updates**.

## License

Free software under the **GNU General Public License version 2** (or, at your
option, any later version). See [LICENSE](LICENSE).

Copyright (C) 2026 Viktor Ljuca - https://monsama.ch
