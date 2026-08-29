# NOBS SQL Editor — PowerShell edition

A MySQL / MariaDB client that runs as a **single PowerShell script**. It starts
a tiny local HTTP server (127.0.0.1 only, no admin rights), shells out to the
`mysql` / `mysqldump` command-line tools, and opens its UI in your default
browser.

This is the same application as
[NOBS-SQL-Editor](https://github.com/monsama/NOBS-SQL-Editor), which packages
the same UI as a native desktop app using [Tauri](https://tauri.app). Use this
edition when you want zero installation, or a machine where you cannot install
software.

## Running

```powershell
powershell -ExecutionPolicy Bypass -File .\NOBSSQL.ps1
```

Your browser opens automatically. **Closing the console window stops the
server.** Pass `-NoBrowser` to start the server without opening a browser.

Requires Windows PowerShell 5.1 or later.

## Features

- Connections with saved profiles, a per-connection accent colour and
  environment label, and a **read-only / safe mode** to protect production
  servers.
- Browse schemas, tables, views, procedures, functions, triggers and events,
  with quick filtering and search across all schemas.
- Tabbed SQL editor with syntax highlighting, autocomplete, query formatting,
  and run-whole-script or run-selection.
- Result grids with per-column filtering and sorting, column resize and
  show/hide, and a row-detail form view for wide tables.
- Inline and full-row editing staged as pending changes and applied in a single
  transaction; add and delete rows.
- Export tables or query results to CSV or INSERT statements; CSV import.
- Table designer, DDL view and edit, users and privileges, table maintenance,
  ER diagrams, server process list, and a reusable query library.

## Client tools (mysql / mysqldump)

Export and Import use the official MySQL/MariaDB command-line tools, which are
**not bundled**. On first use, point the app at an existing install in
Settings, or let it download the official MariaDB client tools from
mariadb.org.

Auto-detection checks, in order: saved configuration, the system PATH, then
common install folders (`Program Files\MariaDB*`, `Program Files\MySQL`,
XAMPP).

## License

Free software under the **GNU General Public License version 2** (or, at your
option, any later version). See [LICENSE](LICENSE).

Copyright (C) 2026 Viktor Ljuca — https://monsama.ch
