# Audits binary and text columns for the corruption signatures this app has actually produced.
# Read-only: it runs SELECTs and writes nothing.
#
#   pwsh -NoProfile -File tools/Check-BlobIntegrity.ps1 -Dsn '127.0.0.1:3306:root:secret'
#   pwsh -NoProfile -File tools/Check-BlobIntegrity.ps1 -Dsn '...' -Schema moving_appcustomer_900000
#
# What it looks for, and why each one is a real signature rather than a guess:
#
#   hex-text        The value begins with the two CHARACTERS 0 and x. A binary cell is DISPLAYED
#                   as 0x.., so a copied one pastes back as hex; stored as text it becomes the
#                   characters instead of the bytes. This is what destroyed three blobs here.
#   embedded-hex    A run of 0x followed by 16+ hex digits somewhere inside the value - a paste
#                   that landed alongside the cell's existing contents rather than replacing it.
#   bare-hex        The whole value is hex digits with no 0x prefix and is long enough not to be
#                   a coincidence. The same accident via a tool that strips the prefix.
#   replacement     The value contains U+FFFD (EF BF BD). Nothing legitimately stores that; it is
#                   what a UTF-8 decoder leaves behind when it is handed bytes that are not UTF-8,
#                   so its presence means some layer decoded and re-encoded the data.
#   nul-in-text     A NUL byte inside a text column. Usually harmless, occasionally the tail of a
#                   truncated binary value written into the wrong column. Tested with INSTR(BINARY..)
#                   - a LIKE against CHAR(0) matches things it should not once collations differ.
#
# Anything reported is a candidate, not a verdict - a column legitimately holding hex text will
# show up, and should. The sample and length are there so you can tell the difference.

param(
    [Parameter(Mandatory)][string]$Dsn,
    [string]$Schema,
    [string]$MysqlPath
)

$parts = $Dsn.Split(':')
if ($parts.Count -ne 4) { "DSN must be host:port:user:password"; exit 2 }

if (-not $MysqlPath) { $MysqlPath = Join-Path $env:APPDATA 'NOBSSQL\bin\mysql.exe' }
if (-not (Test-Path $MysqlPath)) {
    $found = Get-Command mysql -ErrorAction SilentlyContinue
    if ($found) { $MysqlPath = $found.Source } else { "mysql client not found - pass -MysqlPath"; exit 2 }
}

$cnf = Join-Path ([IO.Path]::GetTempPath()) ("blobcheck-" + [Guid]::NewGuid().ToString('N') + ".cnf")
"[client]`nhost=$($parts[0])`nport=$($parts[1])`nuser=$($parts[2])`npassword=$($parts[3])" |
    Set-Content -NoNewline -Encoding ascii $cnf

function Sql([string]$q) { & $MysqlPath "--defaults-extra-file=$cnf" -B --silent -e $q 2>&1 }

try {
    $schemaFilter = if ($Schema) { "AND table_schema = '$Schema'" } else { "" }

    $cols = Sql @"
SELECT table_schema, table_name, column_name, data_type
FROM information_schema.columns
WHERE table_schema NOT IN ('mysql','information_schema','performance_schema','sys') $schemaFilter
  AND data_type IN ('blob','tinyblob','mediumblob','longblob','binary','varbinary',
                    'char','varchar','text','tinytext','mediumtext','longtext')
ORDER BY table_schema, table_name, column_name;
"@
    if ($LASTEXITCODE -ne 0) { "Could not read information_schema:"; $cols; exit 2 }

    $binary = @()
    $textual = @()
    foreach ($line in $cols) {
        $f = $line -split "`t"
        if ($f.Count -lt 4) { continue }
        $entry = [pscustomobject]@{ Schema = $f[0]; Table = $f[1]; Column = $f[2]; Type = $f[3] }
        if ($f[3] -match '^(tiny|medium|long)?blob$|^(var)?binary$') { $binary += $entry } else { $textual += $entry }
    }

    "Checking $($binary.Count) binary and $($textual.Count) text column(s) on $($parts[0]):$($parts[1])"
    ""

    $findings = @()

    foreach ($c in $binary) {
        $q = @"
SELECT '$($c.Schema).$($c.Table).$($c.Column)' AS col,
  SUM(CONVERT(``$($c.Column)`` USING utf8mb4) LIKE '0x%') AS hex_text,
  SUM(CONVERT(``$($c.Column)`` USING utf8mb4) REGEXP '0[xX][0-9a-fA-F]{16,}') AS embedded_hex,
  SUM(LENGTH(``$($c.Column)``) > 32 AND CONVERT(``$($c.Column)`` USING utf8mb4) REGEXP '^[0-9a-fA-F]+$') AS bare_hex,
  SUM(HEX(``$($c.Column)``) LIKE '%EFBFBD%') AS replacement
FROM ``$($c.Schema)``.``$($c.Table)``;
"@
        $r = Sql $q
        if ($LASTEXITCODE -ne 0) { $findings += [pscustomobject]@{ Col = "$($c.Schema).$($c.Table).$($c.Column)"; Kind = 'unreadable'; N = '?'; Note = ($r -join ' ') }; continue }
        $f = ($r | Select-Object -First 1) -split "`t"
        if ($f.Count -lt 5) { continue }
        foreach ($pair in @(@('hex-text',1), @('embedded-hex',2), @('bare-hex',3), @('replacement',4))) {
            $n = 0; [void][int]::TryParse($f[$pair[1]], [ref]$n)
            if ($n -gt 0) { $findings += [pscustomobject]@{ Col = $f[0]; Kind = $pair[0]; N = $n; Note = '' } }
        }
    }

    foreach ($c in $textual) {
        $q = @"
SELECT '$($c.Schema).$($c.Table).$($c.Column)' AS col,
  SUM(HEX(``$($c.Column)``) LIKE '%EFBFBD%') AS replacement,
  SUM(INSTR(BINARY ``$($c.Column)``, 0x00) > 0) AS nul_in_text
FROM ``$($c.Schema)``.``$($c.Table)``;
"@
        $r = Sql $q
        if ($LASTEXITCODE -ne 0) { continue }
        $f = ($r | Select-Object -First 1) -split "`t"
        if ($f.Count -lt 3) { continue }
        foreach ($pair in @(@('replacement',1), @('nul-in-text',2))) {
            $n = 0; [void][int]::TryParse($f[$pair[1]], [ref]$n)
            if ($n -gt 0) { $findings += [pscustomobject]@{ Col = $f[0]; Kind = $pair[0]; N = $n; Note = '' } }
        }
    }

    if ($findings.Count -eq 0) {
        "  No corruption signatures found."
        ""
        "  Checked: hex-text, embedded-hex, bare-hex, replacement characters, NUL in text."
        exit 0
    }

    "  FINDINGS"
    ""
    foreach ($f in $findings | Sort-Object Kind, Col) {
        "  {0,-14} {1,5} row(s)  {2} {3}" -f $f.Kind, $f.N, $f.Col, $f.Note
    }
    ""
    "  Inspect one with, for example:"
    "    SELECT id, LENGTH(col), LEFT(CONVERT(col USING utf8mb4),80) FROM schema.table WHERE col LIKE '0x%';"
    ""
    "  A value that begins '0x' followed by its own hash usually recovers with:"
    "    UPDATE t SET col = UNHEX(SUBSTRING(CONVERT(col USING utf8mb4), 3,"
    "      REGEXP_INSTR(SUBSTRING(CONVERT(col USING utf8mb4),3),'[^0-9a-fA-F]') - 1)) WHERE ...;"
    "  Check the decoded value before committing to it, and take a backup first."
    exit 1
}
finally {
    Remove-Item -LiteralPath $cnf -Force -ErrorAction SilentlyContinue
}
