# Runs the app's own client-tools downloads for real and checks what they leave on disk.
#
# Nothing else covers this path. The per-function tests here evaluate pure functions, and the live
# tests use tools that the CI setup script installs directly - so the two buttons in Settings that
# actually fetch and unpack an archive were only ever exercised by hand. They depend on two things
# outside this repository staying as they are: MariaDB's release API (its file list and the SHA-256
# it publishes for each file) and the HTML of MySQL's download page, which is where that download's
# version, file name and MD5 are read from. Either can change without anyone pushing a commit, and
# when one does, the failure is silent - the app refuses to install what it cannot verify, and the
# button simply stops working for whoever clicks it next.
#
# Everything is written to a temporary tree, never to the real %APPDATA%: the config file and the
# tools directory are both redirected before anything runs.
#
#   NOBS_TEST_TOOLS_DOWNLOAD=1 pwsh -NoProfile -File tests/ToolsDownload.Tests.ps1 ./NOBSSQL.ps1
#   ... -Mysql   also downloads MySQL's archive (~270 MB, against ~90 MB for MariaDB's)

param([Parameter(Mandatory)][string]$ScriptPath, [switch]$Mysql)

# Gated, and not only #[ignore]-style off by default, because this downloads ~90 MB (or ~360 MB
# with -Mysql) and writes into a temp tree - not something a plain test run should start doing.
if (-not $env:NOBS_TEST_TOOLS_DOWNLOAD) {
    "  SKIPPED - NOBS_TEST_TOOLS_DOWNLOAD is not set, so nothing was downloaded."
    exit 0
}

$e = $null; $t = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $ScriptPath).Path, [ref]$t, [ref]$e)
if ($e -and $e.Count) { "PARSE ERRORS: $($e.Count)"; exit 1 }
$ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $n.Name -in @('Api-DownloadTools', 'Api-DownloadMysqlTools', 'Get-MysqlDownloadInfo', 'Get-MysqlZipMember',
                  'Get-PluginDir', 'J-Str', 'Load-Cfg', 'Save-Cfg', 'Use-FileLock') }, $true) |
    ForEach-Object { Invoke-Expression $_.Extent.Text }
# The mirror template and the list of authentication plugins are taken from the script itself, so
# this test cannot pass against a stale copy of either.
$ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $n.Left.Extent.Text -in @('$script:DefaultMariaDbUrlTemplate', '$script:ClientAuthPlugins',
                              '$script:JStrSpecialChars') }, $true) |
    ForEach-Object { Invoke-Expression $_.Extent.Text }

$fail = 0
function Check($cond, $label, $detail) { if ($cond) { "  ok    $label" } else { "  FAIL  $label$(if($detail){" -> $detail"})"; $script:fail++ } }

$root = Join-Path ([IO.Path]::GetTempPath()) "nobs-toolsdl-$PID"
Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
$script:ToolsDir = Join-Path $root 'bin'
$script:CfgFile = Join-Path $root 'config.json'
$script:MysqlPath = $null
$script:MysqldumpPath = $null

try {
    "-- MariaDB client tools: downloaded, checked against the API's SHA-256, unpacked --"
    $r = Api-DownloadTools | ConvertFrom-Json
    Check ($r.ok -eq $true) 'the download reports success' $r.error
    foreach ($exe in 'mysql.exe', 'mysqldump.exe', 'mariadb.exe', 'mariadb-dump.exe') {
        $p = Join-Path $script:ToolsDir $exe
        $len = if (Test-Path $p) { (Get-Item $p).Length } else { 0 }
        Check ($len -gt 1MB) "$exe is there and is not truncated" "$len bytes"
    }
    # The plugins live deeper in the archive than the binaries and were once not unpacked at all,
    # which left the app unable to log in to a stock MySQL 8 server however it was configured.
    Check (Test-Path (Join-Path $script:ToolsDir 'plugin\caching_sha2_password.dll')) 'the client authentication plugins are there'
    # And the config points at what was unpacked - this is what makes Export work afterwards.
    $cfg = Load-Cfg
    Check ($cfg -and ([string]$cfg.mysql_bin).EndsWith('.exe')) 'the saved configuration names the new client' ([string]$cfg.mysql_bin)

    if ($Mysql) {
        "-- MySQL client tools: page scraped for the MD5, downloaded, checked, unpacked --"
        $r2 = Api-DownloadMysqlTools | ConvertFrom-Json
        Check ($r2.ok -eq $true) 'the download reports success' $r2.error
        foreach ($exe in 'mysql.exe', 'mysqldump.exe') {
            $p = Join-Path (Join-Path $script:ToolsDir 'mysql') $exe
            $len = if (Test-Path $p) { (Get-Item $p).Length } else { 0 }
            Check ($len -gt 1MB) "mysql\$exe is there and is not truncated" "$len bytes"
        }
        $cfg2 = Load-Cfg
        Check ($cfg2 -and ([string]$cfg2.mysql_bin_mysql).EndsWith('.exe')) "the MySQL servers' own paths are saved separately" ([string]$cfg2.mysql_bin_mysql)
    }
} finally {
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($fail) { "FAILED: $fail"; exit 1 }
"All checks passed."
