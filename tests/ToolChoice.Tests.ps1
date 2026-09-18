# Tests for which client tools export and import use for a server (Get-ToolFor and its parts).
#
# MariaDB's and MySQL's tools are not interchangeable against the other's server: MariaDB's
# mysqldump writes values into a MySQL generated column, so the dump does not restore. A MySQL
# server therefore gets MySQL's own tools when there are any, and everything else keeps the
# configured (or downloaded) pair.
#
#   pwsh -NoProfile -File tests/ToolChoice.Tests.ps1 ./NOBSSQL.ps1

param([Parameter(Mandatory)][string]$ScriptPath)

$ErrorActionPreference = 'Stop'

$e=$null;$t=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $ScriptPath).Path,[ref]$t,[ref]$e)
if($e -and $e.Count){ $e | ForEach-Object { "  PARSE ERROR  line $($_.Extent.StartLineNumber): $($_.Message)" }; exit 1 }
$ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $n.Name -in @('Get-MysqlServerBinDirs','Select-Tool','Get-MysqlDownloadInfo','Get-MysqlZipMember','Get-PluginDir','New-Cnf','Get-CnfSafe','Get-SslLines',
                  'Test-ClientIsMariaDB','Test-ToolIsMariaDB','Test-DumpIsMariaDB','Get-BrowseCharset')},$true) | ForEach-Object { Invoke-Expression $_.Extent.Text }

# The list Get-BrowseCharset matches against: a script-level value, not a function, so it is
# evaluated by name rather than picked up with the definitions above.
Invoke-Expression ($ast.EndBlock.Statements | Where-Object {
    $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq '$script:BrowseCharsets'
} | Select-Object -First 1).Extent.Text

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

    "`n-- MySQL's download page gives the ZIP and its checksum --"
    # Verbatim from https://dev.mysql.com/downloads/mysql/8.4.html (September 2026): the MSI row,
    # then the ZIP row. The MD5 has to be the one printed for the ZIP, not the MSI's before it.
    $page = @'
<td class="sub-text">(mysql-8.4.11-winx64.msi)</td>
            <td class="sub-text" style="text-align:right;" colspan="4">
                MD5: <code class="md5">b5c515a0f410cd6903cd41057ed5d662</code> |
        </tr>
                            <td class="col1"><b>Windows (x86, 64-bit), ZIP Archive</b></td>
                        <td class="col3">8.4.11</td>
            <td class="col4">268.2M</td>
            <td class="sub-text">(mysql-8.4.11-winx64.zip)</td>
            <td class="sub-text" style="text-align:right;" colspan="4">
                MD5: <code class="md5">2E833921898A9A030EA6BFE81BD811BC</code> |
            <td class="sub-text">(mysql-8.4.11-winx64-debug-test.zip)</td>
                MD5: <code class="md5">00000000000000000000000000000000</code> |
'@
    $info = Get-MysqlDownloadInfo $page
    Check ($info.File -eq 'mysql-8.4.11-winx64.zip' -and $info.Version -eq '8.4.11') 'the ZIP and its version' "$($info.File) $($info.Version)"
    Check ($info.Md5 -ceq '2e833921898a9a030ea6bfe81bd811bc') "the ZIP's own checksum, lowercased" $info.Md5
    Check ($null -eq (Get-MysqlDownloadInfo '<html>nothing</html>')) 'no archive named, nothing claimed'
    Check ($null -eq (Get-MysqlDownloadInfo '(mysql-9.1.0-winx64.zip) and no checksum').Md5) 'no checksum on the page, none invented'

    "`n-- only the two client binaries are taken from the archive --"
    Check ((Get-MysqlZipMember 'mysql-8.4.11-winx64/bin/mysql.exe') -eq 'mysql.exe') 'bin/mysql.exe'
    Check ((Get-MysqlZipMember 'mysql-8.4.11-winx64\bin\mysqldump.exe') -eq 'mysqldump.exe') 'bin\mysqldump.exe, backslashes'
    foreach ($n in 'mysql-8.4.11-winx64/bin/mysqld.exe', 'mysql-8.4.11-winx64/lib/plugin/mysql.exe', 'mysql-8.4.11-winx64/mysql.exe', 'mysql-8.4.11-winx64/bin/x/mysql.exe', 'mysql.exe') {
        Check ($null -eq (Get-MysqlZipMember $n)) "not $n"
    }

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
        Check ($b1 -notmatch '\[mysql\]|init-command') 'an ordinary connection keeps the server''s time zone' $b1
    } finally { Remove-Item $f1, $f2 -Force -ErrorAction SilentlyContinue }
    # Compare's connections run in UTC, set only for mysql.exe: mysqldump reads the same file and
    # rejects options it does not know.
    $utc = @{ host = 'h'; port = '3306'; user = 'u'; password = 'p'; ssl = 'required'; utc = $true }
    $f3 = New-Cnf $utc -Tool $theirs
    try {
        $b3 = Get-Content -Raw $f3
        Check ($b3 -match "(?s)\[client\].*ssl-mode=REQUIRED.*\r?\n\[mysql\]\r?\ninit-command=`"SET time_zone='\+00:00'`"") 'a Compare connection sets UTC in the [mysql] group, after the client options' $b3
    } finally { Remove-Item $f3 -Force -ErrorAction SilentlyContinue }
    $script:MysqldumpPath = $ours
    $script:DumpIsMariaDB = @{ Path = $ours; Maria = $true }
    Check (-not (Test-DumpIsMariaDB $theirs)) 'the dump flavor is asked of the tool that will run'
    Check (Test-DumpIsMariaDB) 'and without a path, of the default one'
} finally {
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}

"`n-- every script-level value a request reads is shared with the request threads --"
# Requests run in a runspace pool, which sees only the variables listed in the seed loop at the
# bottom of the script; any other $script: value is $null there. The MariaDB download read two of
# those - its URL template and the plugin list - so it failed with "You cannot call a method on a
# null-valued expression" unless a template had been saved.
$topLevel = $ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.AssignmentStatementAst] } |
    ForEach-Object { $_.Left.Extent.Text } | Where-Object { $_ -like '$script:*' } | ForEach-Object { $_.Substring(8) } | Sort-Object -Unique
$seedLine = ($ast.Extent.Text -split "`n" | Where-Object { $_ -match 'foreach \(\$vn in' } | Select-Object -First 1)
$seeded = [regex]::Matches([string]$seedLine, "'(\w+)'") | ForEach-Object { $_.Groups[1].Value }
$readInFunctions = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) |
    ForEach-Object { $_.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.UserPath -like 'script:*' }, $true) } |
    ForEach-Object { $_.VariablePath.UserPath.Substring(7) } | Sort-Object -Unique
Check (@($seeded).Count -gt 10) 'the seed list was found' "found $(@($seeded).Count)"
$missing = @($topLevel | Where-Object { $readInFunctions -contains $_ -and $seeded -notcontains $_ })
Check ($missing.Count -eq 0) 'none is missing from it' ($missing -join ', ')

"`n-- a release is newer only when its version is higher --"
$ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-ReleaseIsNewer' }, $true) |
    ForEach-Object { Invoke-Expression $_.Extent.Text }
Check (Test-ReleaseIsNewer 'v1.3.0' '1.2.0')        'v1.3.0 is newer than 1.2.0'
Check (Test-ReleaseIsNewer 'v1.10.0' '1.9.3')       'compared as numbers, not text'
Check (-not (Test-ReleaseIsNewer 'v1.2.0' '1.2.0')) 'the same version is not an update'
Check (-not (Test-ReleaseIsNewer 'v1.1.0' '1.2.0')) 'an older release is not an update'
Check (-not (Test-ReleaseIsNewer 'v1.2' '1.2.0'))   '1.2 and 1.2.0 are the same version'
Check (-not (Test-ReleaseIsNewer '' '1.2.0'))       'no tag, no update'
Check (-not (Test-ReleaseIsNewer 'nightly' '1.2.0')) 'a tag that is not a version is not an update'

"`n-- the tool version is read from its --version text --"
$ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-ToolVersionLabel' }, $true) |
    ForEach-Object { Invoke-Expression $_.Extent.Text }
Check ((Get-ToolVersionLabel 'C:\Users\x\NOBSSQL\bin\mysql.exe from 12.3.3-MariaDB, client 15.2 for Win64 (AMD64), source revision 83e909fc') -eq 'MariaDB 12.3.3') "MariaDB's client"
Check ((Get-ToolVersionLabel 'C:\x\mysqldump.exe from 12.3.3-MariaDB, client 10.20 for Win64 (AMD64)') -eq 'MariaDB 12.3.3') "MariaDB's dump tool"
Check ((Get-ToolVersionLabel 'mysqldump  Ver 8.4.9 for Win64 on x86_64 (MySQL Community Server - GPL)') -eq 'MySQL 8.4.9') "MySQL's dump tool"
Check ((Get-ToolVersionLabel 'C:\x\mysql.exe  Ver 8.0.46 for Win64 on x86_64 (MySQL Community Server - GPL)') -eq 'MySQL 8.0.46') "MySQL's client"
Check ($null -eq (Get-ToolVersionLabel 'something else')) 'anything else is not a version'

"`n-- every function using the C# helpers loads them first --"
# The helper types are compiled on first use (Initialize-DumpDb). The script-results endpoint used
# them without that, so as the first request after start it failed with "Unable to find type".
$loadsLater = @{
    'Initialize-DumpDb'    = 'defines them'
    'Run-Stdin'            = 'uses them only for -Rename, which only Api-Import passes'
    'Api-FetchCursorBatch' = 'reads a cursor Open-QueryCursor made'
}
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    $b = $f.Body.Extent.Text
    if ($b -notmatch 'Nobs(XmlRows|DumpDb|Lf|ResultSet)' -or $loadsLater.ContainsKey($f.Name)) { continue }
    Check ($b -match 'Initialize-DumpDb') "$($f.Name) loads the helpers before using them"
}

"`n-- schema sync writes a column as the server defines it --"
$ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in @('Get-ColumnDefinitions','ColDefinition','ColDefLine','ColDefaultClause','SqlId','SqlLit','Needs-Quote') }, $true) |
    ForEach-Object { Invoke-Expression $_.Extent.Text }
foreach ($name in '$script:ReservedSet') {
    $a = $ast.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq $name},$true) | Select-Object -First 1
    if ($a) { Invoke-Expression $a.Extent.Text }
}
$create = "CREATE TABLE ``t`` (`n  ``id`` int(11) NOT NULL,`n  ``we````ird`` varchar(10) CHARACTER SET latin1 COLLATE latin1_bin NOT NULL COMMENT 'x, y',`n  ``n`` varchar(5) DEFAULT 'a',`n  ``g`` int(11) GENERATED ALWAYS AS (``id`` * 2) VIRTUAL,`n  PRIMARY KEY (``id``)`n) ENGINE=InnoDB"
$defs = Get-ColumnDefinitions $create
$col = { param($name, $type, $cs, $co) [pscustomobject]@{ name = $name; type = $type; null = 'NO'; default = $null; extra = ''; charset = $cs; collation = $co; comment = ''; generation = '' } }
Check ($defs.Count -eq 4) 'every column line is read, and nothing else' ($defs.Keys -join ',')
Check ((ColDefinition (& $col 'we`ird' 'varchar(10)' 'latin1' 'latin1_bin') $defs) -ceq "``we````ird`` varchar(10) CHARACTER SET latin1 COLLATE latin1_bin NOT NULL COMMENT 'x, y'") 'a column keeps its character set, collation and comment'
Check ((ColDefinition (& $col 'n' 'varchar(5)' 'utf8mb4' 'utf8mb4_bin') $defs) -ceq "``n`` varchar(5) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT 'a'") 'a table-default character set is spelled out'
Check ((ColDefinition (& $col 'G' 'int(11)' $null $null) $defs) -ceq '`g` int(11) GENERATED ALWAYS AS (`id` * 2) VIRTUAL') 'a generated column keeps its expression'
Check ((ColDefinition (& $col 'missing' 'int' $null $null) $defs) -ceq 'missing int NOT NULL') 'without a line, the old way'

if ($fail) { "`n  $fail FAILED"; exit 1 } else { "`n  all passed"; exit 0 }
