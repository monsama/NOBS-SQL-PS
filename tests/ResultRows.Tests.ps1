# Tests for how result rows are cut out of mysql.exe's --batch output (NobsLf, CellVal).
#
# mysql --batch ends each row with a bare LF and escapes tab, newline, NUL and backslash inside
# values - but not carriage return. Two things went wrong with that, both measured against MariaDB
# 12.2 through the running app:
#
#   - Rows were cut with .NET's ReadLine(), which also ends a line at CR. A value holding a CR split
#     its row in two and shifted every column after it: 'a' LF 'b' CR 'c' came back as two rows, and
#     a VARBINARY of 0x0A0D came back as NULL plus a phantom row.
#   - The NULL marker was matched with -eq, which ignores case. The escaped newline \n matched \N,
#     so a value that was one line feed read as NULL - and so did the text 'null'.
#
#   pwsh -NoProfile -File tests/ResultRows.Tests.ps1 ./NOBSSQL.ps1

param([Parameter(Mandatory)][string]$ScriptPath)

$e=$null;$t=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $ScriptPath).Path,[ref]$t,[ref]$e)
if($e -and $e.Count){ "PARSE ERRORS: $($e.Count)"; exit 1 }
# The script-level values these functions lean on, taken from the script itself.
foreach ($name in '$script:DumpDbSource','$script:RawEnc','$script:StrictUtf8','$script:CtrlChars') {
    $a = $ast.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq $name},$true) | Select-Object -First 1
    if (-not $a) { "  FAIL  $name not found"; exit 1 }
    Invoke-Expression $a.Extent.Text
}
$ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                        $n.Name -in @('Initialize-DumpDb','CellVal','ConvertFrom-BatchField')},$true) | ForEach-Object { Invoke-Expression $_.Extent.Text }
Initialize-DumpDb

$fail = 0
function Check($cond, $label, $detail) { if ($cond) { "  ok    $label" } else { "  FAIL  $label$(if($detail){" -> $detail"})"; $script:fail++ } }
# What the client really wrote for:  SELECT NULL, 'NULL', 'null', '\N', 'x' LF 'y', 'p' CR 'q', 0x0A, ''
$bytes = [byte[]](0x61,9,0x62,9,0x63,9,0x64,9,0x65,9,0x66,9,0x67,9,0x68,10,
                  0x4E,0x55,0x4C,0x4C,9, 0x4E,0x55,0x4C,0x4C,9, 0x6E,0x75,0x6C,0x6C,9, 0x5C,0x5C,0x4E,9,
                  0x78,0x5C,0x6E,0x79,9, 0x70,0x0D,0x71,9, 0x5C,0x6E,9, 10)
$reader = New-Object IO.StreamReader((New-Object IO.MemoryStream(,$bytes)), $script:RawEnc)
$lines = @(); while ($null -ne ($l = [NobsLf]::ReadLine($reader))) { $lines += $l }

"-- rows end at LF and nowhere else --"
Check ($lines.Count -eq 2) 'a CR inside a value does not start a new row' "got $($lines.Count) lines"
$cells = @($lines[1].Split([char]9) | ForEach-Object { CellVal $_ })
Check ($cells.Count -eq 8) 'every column is still in its place' "got $($cells.Count)"

"`n-- values --"
Check ($null -eq $cells[0])            'NULL is NULL'
Check ($cells[2] -ceq 'null')          "the text 'null' stays text" "got '$($cells[2])'"
Check ($cells[3] -ceq '\N')            'the two characters \N stay text'
Check ($cells[4] -ceq "x`ny")          'an escaped newline is a newline'
Check ($cells[5] -ceq "p`rq")          'a carriage return survives inside its value'
Check ($cells[6] -ceq "`n")            'a value that is one line feed is not NULL' "got $(if($null -eq $cells[6]){'NULL'}else{"'$($cells[6])'"})"
Check ($cells[7] -ceq '')              'an empty string is not NULL'
# The one case --batch output cannot tell apart: the text NULL is printed exactly like NULL.
Check ($null -eq $cells[1])            "the text 'NULL' is indistinguishable in this format (known limit)"

"`n-- the last line without a final LF, and an empty input --"
$r2 = New-Object IO.StreamReader((New-Object IO.MemoryStream(,[byte[]](0x61,0x0D))), $script:RawEnc)
Check (([NobsLf]::ReadLine($r2)) -ceq "a`r") 'a trailing CR is kept'
Check ($null -eq [NobsLf]::ReadLine($r2))    'then end of input'
$r3 = New-Object IO.StreamReader((New-Object IO.MemoryStream(,[byte[]]@())), $script:RawEnc)
Check ($null -eq [NobsLf]::ReadLine($r3))    'nothing at all is end of input'

if ($fail) { "`n  $fail FAILED"; exit 1 } else { "`n  all passed"; exit 0 }
