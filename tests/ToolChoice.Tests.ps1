# Tests for which client tools export and import use for a server (Get-ToolFor and its parts).
#
# MariaDB's and MySQL's tools are not interchangeable against the other's server: MariaDB's
# mysqldump writes values into a MySQL generated column, so the dump does not restore. A MySQL
# server therefore gets MySQL's own tools when there are any, and everything else keeps the
# configured (or downloaded) pair.
#
#   pwsh -NoProfile -File tests/ToolChoice.Tests.ps1 ./NOBSSQL.ps1

param([Parameter(Mandatory)][string]$ScriptPath)

$e=$null;$t=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $ScriptPath).Path,[ref]$t,[ref]$e)
if($e -and $e.Count){ "PARSE ERRORS: $($e.Count)"; exit 1 }
$ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $n.Name -in @('Get-MysqlServerBinDirs','Select-Tool','Get-PluginDir','New-Cnf','Get-CnfSafe','Get-SslLines',
                  'Test-ClientIsMariaDB','Test-ToolIsMariaDB','Test-DumpIsMariaDB')},$true) | ForEach-Object { Invoke-Expression $_.Extent.Text }

$fail = 0
function Check($cond, $label, $detail) { if ($cond) { "  ok    $label" } else { "  FAIL  $label$(if($detail){" -> $detail"})"; $script:fail++ } }

$root = Join-Path ([IO.Path]::GetTempPath()) "nobs-toolchoice-$PID"
Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
try {
    "-- MySQL Server installations are found newest first --"
    foreach ($l in 'PF\MySQL\MySQL Server 8.0\bin', 'PF\MySQL\MySQL Server 8.10\bin', 'PF\MySQL\MySQL Server 8.4\bin',
                   'PF\MySQL\MySQL Workbench 8.0 CE', 'PF\MariaDB 11.4\bin', 'PF86\MySQL\MySQL Server 5.7\bin') {
        New-Item -ItemType Directory -Force (Join-Path $root $l) | Out-Null
    }
    $dirs = @(Get-MysqlServerBinDirs @((Join-Path $root 'PF'), (Join-Path $root 'PF86'), (Join-Path $root 'missing'), $null))
    $names = @($dirs | ForEach-Object { Split-Path -Leaf (Split-Path -Parent $_) }) -join ' | '
    Check ($names -eq 'MySQL Server 8.10 | MySQL Server 8.4 | MySQL Server 8.0 | MySQL Server 5.7') 'by version as numbers, Workbench and MariaDB left out' $names
    Check (@(Get-MysqlServerBinDirs @((Join-Path $root 'missing'))).Count -eq 0) 'no installation, no folders'

    "`n-- only a server known to be MySQL switches --"
    Check ((Select-Tool $false 'my.exe' 'def.exe') -eq 'my.exe')  'MySQL server with MySQL tools: those'
    Check ((Select-Tool $false $null 'def.exe') -eq 'def.exe')    'MySQL server without them: the default pair'
    Check ((Select-Tool $true 'my.exe' 'def.exe') -eq 'def.exe')  'MariaDB server: the default pair'
    Check ((Select-Tool $null 'my.exe' 'def.exe') -eq 'def.exe')  'a server that could not be asked: the default pair'

    "`n-- the options file follows the tool it is written for --"
    $script:ToolsDir = Join-Path $root 'tools'
    New-Item -ItemType Directory -Force (Join-Path $script:ToolsDir 'plugin') | Out-Null
    $ours = Join-Path $script:ToolsDir 'mysqldump.exe'
    $theirs = Join-Path $root 'PF\MySQL\MySQL Server 8.4\bin\mysqldump.exe'
    $script:MysqlPath = Join-Path $script:ToolsDir 'mysql.exe'
    $script:ClientIsMariaDB = @{ Path = $script:MysqlPath; Maria = $true }
    $script:ToolFlavor = @{ $ours = $true; $theirs = $false }
    Check ((Get-PluginDir $ours) -eq (Join-Path $script:ToolsDir 'plugin')) 'our own mysqldump gets our plugin folder'
    Check ($null -eq (Get-PluginDir $theirs)) "MySQL's mysqldump keeps its own"
    $conn = @{ host = 'h'; port = '3306'; user = 'u'; password = 'p'; ssl = 'required' }
    $f1 = New-Cnf $conn -Tool $theirs
    $f2 = New-Cnf $conn
    try {
        $b1 = Get-Content -Raw $f1; $b2 = Get-Content -Raw $f2
        Check ($b1 -match 'ssl-mode=REQUIRED' -and $b1 -notmatch 'plugin-dir') "for MySQL's tool: MySQL's SSL option, no plugin folder" $b1
        Check ($b2 -match '(?m)^ssl\s*$' -and $b2 -match 'plugin-dir') 'for the default client: MariaDB''s option and our plugins' $b2
    } finally { Remove-Item $f1, $f2 -Force -ErrorAction SilentlyContinue }
    $script:MysqldumpPath = $ours
    $script:DumpIsMariaDB = @{ Path = $ours; Maria = $true }
    Check (-not (Test-DumpIsMariaDB $theirs)) 'the dump flavor is asked of the tool that will run'
    Check (Test-DumpIsMariaDB) 'and without a path, of the default one'
} finally {
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($fail) { "`n  $fail FAILED"; exit 1 } else { "`n  all passed"; exit 0 }
