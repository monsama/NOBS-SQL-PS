# Tests for restoring a dump into a chosen target database (NobsDumpDb / Get-DumpPlan).
#
# A per-database dump - the export dialog's default - carries its own DROP DATABASE, CREATE
# DATABASE and USE, and "Target database" was only passed to mysql.exe as its default database,
# which the file's USE overrides. So importing shop.sql "into shop_copy" dropped and rebuilt shop
# itself, left shop_copy empty, and - when the file failed partway, as MySQL does on a generated
# column's value - left shop gutted. Measured on MySQL 8.0.46 and MariaDB 12.2.
#
# The C# helper is compiled from the script itself, so this also checks that it builds on the
# PowerShell running the test (run it under both pwsh and Windows PowerShell 5.1).
#
#   pwsh -NoProfile -File tests/DumpTarget.Tests.ps1 ./NOBSSQL.ps1

param([Parameter(Mandatory)][string]$ScriptPath)

$e=$null;$t=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $ScriptPath).Path,[ref]$t,[ref]$e)
if($e -and $e.Count){ "PARSE ERRORS: $($e.Count)"; exit 1 }
$src = $ast.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                     $n.Left.Extent.Text -eq '$script:DumpDbSource'},$true) | Select-Object -First 1
if (-not $src) { "  FAIL  `$script:DumpDbSource not found"; exit 1 }
$script:DumpDbSource = $src.Right.Extent.Text -replace "^@'\r?\n", '' -replace "\r?\n'@$", ''
$ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                        $n.Name -in @('Initialize-DumpDb','Get-DumpPlan')},$true) | ForEach-Object { Invoke-Expression $_.Extent.Text }
try { Initialize-DumpDb } catch { "  FAIL  the C# helper does not compile on PowerShell $($PSVersionTable.PSVersion): $_"; exit 1 }
"  (PowerShell $($PSVersionTable.PSVersion))"

$fail = 0
function Check($cond, $label, $detail) { if ($cond) { "  ok    $label" } else { "  FAIL  $label$(if($detail){" -> $detail"})"; $script:fail++ } }
function Name([string]$line) { $b=[Text.Encoding]::UTF8.GetBytes($line); $end=0; $nm=$null; $s=[NobsDumpDb]::Ident($b,$b.Length,[ref]$end,[ref]$nm); if($s -ge 0){$nm}else{$null} }
function Rw([string]$line, $from='shop', $to='shop_copy') { $b=[Text.Encoding]::UTF8.GetBytes($line); [Text.Encoding]::UTF8.GetString([NobsDumpDb]::RewriteLine($b,$b.Length,$from,$to)) }

"-- database statements in every form the dump tools write --"
foreach ($c in @(
    @('/*!40000 DROP DATABASE IF EXISTS `shop`*/;', 'shop'),
    @('CREATE DATABASE /*!32312 IF NOT EXISTS*/ `shop` /*!40100 DEFAULT CHARACTER SET utf8mb4 */;', 'shop'),
    @('USE `shop`;', 'shop'), @('use shop;', 'shop'),
    @('DROP DATABASE IF EXISTS `we``ird`;', 'we`ird'),
    @('CREATE DATABASE IF NOT EXISTS plain_name;', 'plain_name'),
    @('  CREATE SCHEMA `s2`;', 's2'), @('DROP SCHEMA s3;', 's3'), @('USE `sp ace`;', 'sp ace'))) {
    Check ((Name $c[0]) -ceq $c[1]) "recognised: $($c[0])" "got '$(Name $c[0])'"
}

"`n-- nothing else is touched --"
foreach ($l in @("INSERT INTO ``t`` VALUES (1,'USE ``shop``;');", 'DROP TABLE IF EXISTS `shop`;', 'CREATE TABLE `shop` (id INT);',
                 '-- USE `shop`;', '/*!50001 CREATE VIEW `v` AS SELECT 1 */;', 'USER `shop`;', 'USED shop;', '')) {
    Check ($null -eq (Name $l) -and (Rw $l) -ceq $l) "left alone: $l"
}

"`n-- only the identifier changes --"
Check ((Rw "/*!40000 DROP DATABASE IF EXISTS ``shop``*/;`n") -ceq "/*!40000 DROP DATABASE IF EXISTS ``shop_copy``*/;`n") 'DROP DATABASE'
Check ((Rw "CREATE DATABASE /*!32312 IF NOT EXISTS*/ ``shop`` /*!40100 X */;`r`n") -ceq "CREATE DATABASE /*!32312 IF NOT EXISTS*/ ``shop_copy`` /*!40100 X */;`r`n") 'CREATE DATABASE, CRLF kept'
Check ((Rw "USE shop;`n") -ceq "USE ``shop_copy``;`n") 'bare USE'
Check ((Rw "USE ``other``;`n") -ceq "USE ``other``;`n") 'another database is left alone'
Check ((Rw 'USE `shop`;' 'shop' 'a`b') -ceq 'USE `a``b`;') 'a backtick in the target is escaped'
$raw = [byte[]](0x49,0x4E,0x53,0x20,0xFF,0xFE,0x0A)
Check ([Convert]::ToBase64String([NobsDumpDb]::RewriteLine($raw,$raw.Length,'shop','x')) -eq [Convert]::ToBase64String($raw)) 'bytes that are not UTF-8 pass through'

"`n-- the plan follows what the file contains --"
Check ((Get-DumpPlan @('shop') '').Kind -eq 'AsIs')          'no target: restore where the file says'
Check ((Get-DumpPlan @() 'copy').Kind -eq 'AsIs')             'a per-table dump just uses the target'
Check ((Get-DumpPlan @('copy') 'copy').Kind -eq 'AsIs')       'already the target'
$p = Get-DumpPlan @('shop') 'copy'; Check ($p.Kind -eq 'Rename' -and $p.From -eq 'shop') 'one other database is renamed'
$p = Get-DumpPlan @('shop','crm') 'copy'; Check ($p.Kind -eq 'Refuse' -and $p.Why -match 'shop, crm') 'two databases are refused' $p.Why

"`n-- a whole file: names collected, and the streamed copy renamed --"
$tmp = [IO.Path]::GetTempFileName()
try {
    $body = "/*!40000 DROP DATABASE IF EXISTS ``a``*/;`nCREATE DATABASE ``a``;`nUSE ``a``;`nINSERT INTO t VALUES (1);`nUSE ``a``;`n"
    [IO.File]::WriteAllBytes($tmp, [Text.Encoding]::UTF8.GetBytes($body + "USE ``b``;`n"))
    Check ((([NobsDumpDb]::Names($tmp)) -join ',') -eq 'a,b') 'names from the whole file, in order'
    [IO.File]::WriteAllBytes($tmp, [Text.Encoding]::UTF8.GetBytes($body + "INSERT INTO t VALUES (2);"))   # no final newline
    $ms = New-Object IO.MemoryStream
    [NobsDumpDb]::CopyRenamed($tmp, $ms, 'a', 'z')
    $out = [Text.Encoding]::UTF8.GetString($ms.ToArray())
    Check ($out -ceq ($body -replace '`a`','`z`') + "INSERT INTO t VALUES (2);") 'streamed copy renamed, last line without a newline kept' $out
} finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }

if ($fail) { "`n  $fail FAILED"; exit 1 } else { "`n  all passed"; exit 0 }
