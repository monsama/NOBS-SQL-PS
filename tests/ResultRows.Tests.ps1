# Tests for how result rows are read out of mysql.exe (NobsXmlRows, and NobsLf for headers).
#
# The rows used to come from --batch output, which prints NULL and the text 'NULL' identically -
# no option changes that - so Compare copied a 'NULL' string to the other server as a real NULL.
# --xml is the only output of the command-line client that keeps them apart. The captures below
# are what the two clients really wrote for the same statement (see the resultset's statement
# attribute), taken from MariaDB 12.3's mysql.exe against MariaDB 12.2, and MySQL 8.0.46's
# mysql.exe against MySQL 8.0.46 - which on Windows writes every LF as CRLF, value bytes included.
#
#   pwsh -NoProfile -File tests/ResultRows.Tests.ps1 ./NOBSSQL.ps1

param([Parameter(Mandatory)][string]$ScriptPath)

$e=$null;$t=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $ScriptPath).Path,[ref]$t,[ref]$e)
if($e -and $e.Count){ "PARSE ERRORS: $($e.Count)"; exit 1 }
# The script-level values these functions lean on, taken from the script itself.
foreach ($name in '$script:DumpDbSource','$script:RawEnc','$script:StrictUtf8') {
    $a = $ast.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq $name},$true) | Select-Object -First 1
    if (-not $a) { "  FAIL  $name not found"; exit 1 }
    Invoke-Expression $a.Extent.Text
}
$ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                        $n.Name -in @('Initialize-DumpDb','Test-SqlSafeToRerun','Test-SqlReadOnly','Split-OffKeyword','Get-ExactTextMap')},$true) | ForEach-Object { Invoke-Expression $_.Extent.Text }
Initialize-DumpDb

$fail = 0
function Check($cond, $label, $detail) { if ($cond) { "  ok    $label" } else { "  FAIL  $label$(if($detail){" -> $detail"})"; $script:fail++ } }
function Show($v) { if ($null -eq $v) { 'NULL' } else { "'" + (($v.ToCharArray() | ForEach-Object { if ([int]$_ -lt 32) { '<' + ([int]$_).ToString('X2') + '>' } else { $_ } }) -join '') + "'" } }
function Reader([string]$b64) {
    $bytes = [Convert]::FromBase64String($b64)
    New-Object NobsXmlRows (New-Object IO.StreamReader((New-Object IO.MemoryStream(,$bytes)), $script:RawEnc))
}

$captures = [ordered]@{
    'MariaDB client' = @{
        Rows  = 'PD94bWwgdmVyc2lvbj0iMS4wIj8+Cgo8cmVzdWx0c2V0IHN0YXRlbWVudD0iU0VMRUNUIE5VTEwgQVMgbiwgJ05VTEwnIEFTIHRuLCAnbnVsbCcgQVMgdGwsICcnIEFTIGUsCiBDT05WRVJUKENPTkNBVCgncCcsQ0hBUigxMyksJ3EnLENIQVIoMTApLCdyJyxDSEFSKDkpLCdzJyxDSEFSKDEzKSxDSEFSKDEwKSkgVVNJTkcgdXRmOG1iNCkgQVMgY3JsZiwKICcmbHQ7JmFtcDsmZ3Q7JnF1b3Q7eCcnJyBBUyBlc2MsIDB4MDBGRjBBMEQgQVMgYmluLCB4JycgQVMgZWJpbiwgQ0FTVChOVUxMIEFTIEJJTkFSWSkgQVMgbmJpbiwKIENPTlZFUlQoeCc0NzcyQzNCQzY1N0E2OTIwRjA5Rjk4ODAnIFVTSU5HIHV0ZjhtYjQpIEFTIHVuaSwgYicxMDEnIEFTIGJpdHYsICcweDQxJyBBUyBoZXhsaWtlLAogQ09OVkVSVCh4JzAxNDEnIFVTSU5HIHV0ZjhtYjQpIEFTIGN0cmwsIENPTlZFUlQoeCc2MTAwNjInIFVTSU5HIHV0ZjhtYjQpIEFTIG51bCwgMSBBUyBgZyBoJmx0OyZndDsmYW1wOyZxdW90O2AKVU5JT04gQUxMIFNFTEVDVCAneCcsJ3gnLCd4JywneCcsJ3gnLCd4JywweDQxLDB4NDEsMHg0MSwneCcsYicwJywneCcsJ3gnLCd4JywyIiB4bWxuczp4c2k9Imh0dHA6Ly93d3cudzMub3JnLzIwMDEvWE1MU2NoZW1hLWluc3RhbmNlIj4KICA8cm93PgoJPGZpZWxkIG5hbWU9Im4iIHhzaTpuaWw9InRydWUiIC8+Cgk8ZmllbGQgbmFtZT0idG4iPk5VTEw8L2ZpZWxkPgoJPGZpZWxkIG5hbWU9InRsIj5udWxsPC9maWVsZD4KCTxmaWVsZCBuYW1lPSJlIj48L2ZpZWxkPgoJPGZpZWxkIG5hbWU9ImNybGYiPnANcQpyCXMNCjwvZmllbGQ+Cgk8ZmllbGQgbmFtZT0iZXNjIj4mbHQ7JmFtcDsmZ3Q7JnF1b3Q7eCc8L2ZpZWxkPgoJPGZpZWxkIG5hbWU9ImJpbiI+MHgwMEZGMEEwRDwvZmllbGQ+Cgk8ZmllbGQgbmFtZT0iZWJpbiI+MHg8L2ZpZWxkPgoJPGZpZWxkIG5hbWU9Im5iaW4iIHhzaTpuaWw9InRydWUiIC8+Cgk8ZmllbGQgbmFtZT0idW5pIj5HcsO8ZXppIPCfmIA8L2ZpZWxkPgoJPGZpZWxkIG5hbWU9ImJpdHYiPjB4MDU8L2ZpZWxkPgoJPGZpZWxkIG5hbWU9ImhleGxpa2UiPjB4NDE8L2ZpZWxkPgoJPGZpZWxkIG5hbWU9ImN0cmwiPgFBPC9maWVsZD4KCTxmaWVsZCBuYW1lPSJudWwiPmEgYjwvZmllbGQ+Cgk8ZmllbGQgbmFtZT0iZyBoJmx0OyZndDsmYW1wOyZxdW90OyI+MTwvZmllbGQ+CiAgPC9yb3c+CgogIDxyb3c+Cgk8ZmllbGQgbmFtZT0ibiI+eDwvZmllbGQ+Cgk8ZmllbGQgbmFtZT0idG4iPng8L2ZpZWxkPgoJPGZpZWxkIG5hbWU9InRsIj54PC9maWVsZD4KCTxmaWVsZCBuYW1lPSJlIj54PC9maWVsZD4KCTxmaWVsZCBuYW1lPSJjcmxmIj54PC9maWVsZD4KCTxmaWVsZCBuYW1lPSJlc2MiPng8L2ZpZWxkPgoJPGZpZWxkIG5hbWU9ImJpbiI+MHg0MTwvZmllbGQ+Cgk8ZmllbGQgbmFtZT0iZWJpbiI+MHg0MTwvZmllbGQ+Cgk8ZmllbGQgbmFtZT0ibmJpbiI+MHg0MTwvZmllbGQ+Cgk8ZmllbGQgbmFtZT0idW5pIj54PC9maWVsZD4KCTxmaWVsZCBuYW1lPSJiaXR2Ij4weDAwPC9maWVsZD4KCTxmaWVsZCBuYW1lPSJoZXhsaWtlIj54PC9maWVsZD4KCTxmaWVsZCBuYW1lPSJjdHJsIj54PC9maWVsZD4KCTxmaWVsZCBuYW1lPSJudWwiPng8L2ZpZWxkPgoJPGZpZWxkIG5hbWU9ImcgaCZsdDsmZ3Q7JmFtcDsmcXVvdDsiPjI8L2ZpZWxkPgogIDwvcm93Pgo8L3Jlc3VsdHNldD4KPD94bWwgdmVyc2lvbj0iMS4wIj8+Cgo8cmVzdWx0c2V0IHN0YXRlbWVudD0iU0VMRUNUIDMgQVMgb3RoZXIiIHhtbG5zOnhzaT0iaHR0cDovL3d3dy53My5vcmcvMjAwMS9YTUxTY2hlbWEtaW5zdGFuY2UiPgogIDxyb3c+Cgk8ZmllbGQgbmFtZT0ib3RoZXIiPjM8L2ZpZWxkPgogIDwvcm93Pgo8L3Jlc3VsdHNldD4K'
        Empty = 'PD94bWwgdmVyc2lvbj0iMS4wIj8+Cgo8cmVzdWx0c2V0IHN0YXRlbWVudD0iU0VMRUNUIDEgQVMgb25lIEZST00gRFVBTCBXSEVSRSAxPTAiIHhtbG5zOnhzaT0iaHR0cDovL3d3dy53My5vcmcvMjAwMS9YTUxTY2hlbWEtaW5zdGFuY2UiPjwvcmVzdWx0c2V0Pgo='
    }
    'MySQL client' = @{
        Rows  = 'PD94bWwgdmVyc2lvbj0iMS4wIj8+DQoNCjxyZXN1bHRzZXQgc3RhdGVtZW50PSJTRUxFQ1QgTlVMTCBBUyBuLCAnTlVMTCcgQVMgdG4sICdudWxsJyBBUyB0bCwgJycgQVMgZSwNCiBDT05WRVJUKENPTkNBVCgncCcsQ0hBUigxMyksJ3EnLENIQVIoMTApLCdyJyxDSEFSKDkpLCdzJyxDSEFSKDEzKSxDSEFSKDEwKSkgVVNJTkcgdXRmOG1iNCkgQVMgY3JsZiwNCiAnJmx0OyZhbXA7Jmd0OyZxdW90O3gnJycgQVMgZXNjLCAweDAwRkYwQTBEIEFTIGJpbiwgeCcnIEFTIGViaW4sIENBU1QoTlVMTCBBUyBCSU5BUlkpIEFTIG5iaW4sDQogQ09OVkVSVCh4JzQ3NzJDM0JDNjU3QTY5MjBGMDlGOTg4MCcgVVNJTkcgdXRmOG1iNCkgQVMgdW5pLCBiJzEwMScgQVMgYml0diwgJzB4NDEnIEFTIGhleGxpa2UsDQogQ09OVkVSVCh4JzAxNDEnIFVTSU5HIHV0ZjhtYjQpIEFTIGN0cmwsIENPTlZFUlQoeCc2MTAwNjInIFVTSU5HIHV0ZjhtYjQpIEFTIG51bCwgMSBBUyBgZyBoJmx0OyZndDsmYW1wOyZxdW90O2ANClVOSU9OIEFMTCBTRUxFQ1QgJ3gnLCd4JywneCcsJ3gnLCd4JywneCcsMHg0MSwweDQxLDB4NDEsJ3gnLGInMCcsJ3gnLCd4JywneCcsMiIgeG1sbnM6eHNpPSJodHRwOi8vd3d3LnczLm9yZy8yMDAxL1hNTFNjaGVtYS1pbnN0YW5jZSI+DQogIDxyb3c+DQoJPGZpZWxkIG5hbWU9Im4iIHhzaTpuaWw9InRydWUiIC8+DQoJPGZpZWxkIG5hbWU9InRuIj5OVUxMPC9maWVsZD4NCgk8ZmllbGQgbmFtZT0idGwiPm51bGw8L2ZpZWxkPg0KCTxmaWVsZCBuYW1lPSJlIj48L2ZpZWxkPg0KCTxmaWVsZCBuYW1lPSJjcmxmIj5wDXENCnIJcw0NCjwvZmllbGQ+DQoJPGZpZWxkIG5hbWU9ImVzYyI+Jmx0OyZhbXA7Jmd0OyZxdW90O3gnPC9maWVsZD4NCgk8ZmllbGQgbmFtZT0iYmluIj4weDAwRkYwQTBEPC9maWVsZD4NCgk8ZmllbGQgbmFtZT0iZWJpbiI+MHg8L2ZpZWxkPg0KCTxmaWVsZCBuYW1lPSJuYmluIiB4c2k6bmlsPSJ0cnVlIiAvPg0KCTxmaWVsZCBuYW1lPSJ1bmkiPkdyw7xlemkg8J+YgDwvZmllbGQ+DQoJPGZpZWxkIG5hbWU9ImJpdHYiPjB4MDU8L2ZpZWxkPg0KCTxmaWVsZCBuYW1lPSJoZXhsaWtlIj4weDQxPC9maWVsZD4NCgk8ZmllbGQgbmFtZT0iY3RybCI+AUE8L2ZpZWxkPg0KCTxmaWVsZCBuYW1lPSJudWwiPmEgYjwvZmllbGQ+DQoJPGZpZWxkIG5hbWU9ImcgaCZsdDsmZ3Q7JmFtcDsmcXVvdDsiPjE8L2ZpZWxkPg0KICA8L3Jvdz4NCg0KICA8cm93Pg0KCTxmaWVsZCBuYW1lPSJuIj54PC9maWVsZD4NCgk8ZmllbGQgbmFtZT0idG4iPng8L2ZpZWxkPg0KCTxmaWVsZCBuYW1lPSJ0bCI+eDwvZmllbGQ+DQoJPGZpZWxkIG5hbWU9ImUiPng8L2ZpZWxkPg0KCTxmaWVsZCBuYW1lPSJjcmxmIj54PC9maWVsZD4NCgk8ZmllbGQgbmFtZT0iZXNjIj54PC9maWVsZD4NCgk8ZmllbGQgbmFtZT0iYmluIj4weDQxPC9maWVsZD4NCgk8ZmllbGQgbmFtZT0iZWJpbiI+MHg0MTwvZmllbGQ+DQoJPGZpZWxkIG5hbWU9Im5iaW4iPjB4NDE8L2ZpZWxkPg0KCTxmaWVsZCBuYW1lPSJ1bmkiPng8L2ZpZWxkPg0KCTxmaWVsZCBuYW1lPSJiaXR2Ij4weDAwPC9maWVsZD4NCgk8ZmllbGQgbmFtZT0iaGV4bGlrZSI+eDwvZmllbGQ+DQoJPGZpZWxkIG5hbWU9ImN0cmwiPng8L2ZpZWxkPg0KCTxmaWVsZCBuYW1lPSJudWwiPng8L2ZpZWxkPg0KCTxmaWVsZCBuYW1lPSJnIGgmbHQ7Jmd0OyZhbXA7JnF1b3Q7Ij4yPC9maWVsZD4NCiAgPC9yb3c+DQo8L3Jlc3VsdHNldD4NCjw/eG1sIHZlcnNpb249IjEuMCI/Pg0KDQo8cmVzdWx0c2V0IHN0YXRlbWVudD0iU0VMRUNUIDMgQVMgb3RoZXIiIHhtbG5zOnhzaT0iaHR0cDovL3d3dy53My5vcmcvMjAwMS9YTUxTY2hlbWEtaW5zdGFuY2UiPg0KICA8cm93Pg0KCTxmaWVsZCBuYW1lPSJvdGhlciI+MzwvZmllbGQ+DQogIDwvcm93Pg0KPC9yZXN1bHRzZXQ+DQo='
        Empty = 'PD94bWwgdmVyc2lvbj0iMS4wIj8+DQoNCjxyZXN1bHRzZXQgc3RhdGVtZW50PSJTRUxFQ1QgMSBBUyBvbmUgRlJPTSBEVUFMIFdIRVJFIDE9MCIgeG1sbnM6eHNpPSJodHRwOi8vd3d3LnczLm9yZy8yMDAxL1hNTFNjaGVtYS1pbnN0YW5jZSI+PC9yZXN1bHRzZXQ+DQo='
    }
}
$wantNames = @('n','tn','tl','e','crlf','esc','bin','ebin','nbin','uni','bitv','hexlike','ctrl','nul','g h<>&"')

foreach ($client in $captures.Keys) {
    "-- $client --"
    $x = Reader $captures[$client].Rows
    $rows = $x.All()
    Check ($rows.Count -eq 2) 'two rows, and none from the second statement' "got $($rows.Count)"
    Check ((@($x.Names) -join '|') -ceq ($wantNames -join '|')) 'column names, entities decoded' ((@($x.Names) -join '|'))
    $c = $rows[0]
    Check ($c.Count -eq 15)                'every column is in its place' "got $($c.Count)"
    Check ($null -eq $c[0])                'NULL is NULL'
    Check ($c[1] -ceq 'NULL')              "the text 'NULL' is text" (Show $c[1])
    Check ($c[2] -ceq 'null')              "the text 'null' is text" (Show $c[2])
    Check ($c[3] -ceq '')                  'an empty string is not NULL' (Show $c[3])
    Check ($c[4] -ceq "p`rq`nr`ts`r`n")    'CR, LF, tab and CRLF inside a value are exact' (Show $c[4])
    Check ($c[5] -ceq "<&>`"x'")           'markup characters are exact' (Show $c[5])
    Check ($c[6] -ceq '0x00FF0A0D')        'binary is hex, NUL and CR/LF bytes included' (Show $c[6])
    Check ($c[7] -ceq '0x')                'an empty binary value is 0x' (Show $c[7])
    Check ($null -eq $c[8])                'a NULL binary value is NULL'
    Check ($c[9] -ceq "Gr$([char]0xFC)ezi $([char]::ConvertFromUtf32(0x1F600))") 'accents and emoji are text' (Show $c[9])
    Check ($c[10] -ceq '0x05')             'BIT is hex' (Show $c[10])
    Check ($c[11] -ceq '0x41')             'text that looks like hex is returned as it is' (Show $c[11])
    Check ($c[12] -ceq "$([char]1)A")      'a control character in text stays text' (Show $c[12])
    # The client writes a NUL byte as a space, and nothing in XML output says it did. Binary
    # columns avoid this through --binary-as-hex; for text there is no way around it.
    Check ($c[13] -ceq 'a b')              'NUL inside text reads as a space (known limit)' (Show $c[13])
    Check ($c[14] -ceq '1')                'numbers are text' (Show $c[14])
    $d = $rows[1]
    Check ((@($d) -join '|') -ceq 'x|x|x|x|x|x|0x41|0x41|0x41|x|0x00|x|x|x|2') 'second row' ((@($d) -join '|'))

    $y = Reader $captures[$client].Rows
    $p1 = $y.Page(1)
    Check ($p1.Count -eq 1 -and $y.More)   'a page of one says more follows'
    $p2 = $y.Page(1)
    Check ($p2.Count -eq 1 -and -not $y.More -and $p2[0][14] -ceq '2') 'the held-back row comes next, then the end'
    Check ($y.Page(5).Count -eq 0)         'nothing after the end'

    $z = Reader $captures[$client].Empty
    Check ($z.All().Count -eq 0 -and $z.HasResultSet -and $z.Names.Count -eq 0) 'an empty result is a result set with no rows and no names'
    ''
}

"-- no result set, and broken output --"
$n = Reader ''
Check ($n.All().Count -eq 0 -and -not $n.HasResultSet) 'no output is no result set'
$trunc = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("<?xml version=`"1.0`"?>`n<resultset statement=`"x`">`n  <row>`n`t<field name=`"a`">1"))
$threw = $false; try { [void](Reader $trunc).All() } catch { $threw = $true }
Check $threw 'output that ends inside a row is an error, not a short result'
$bad = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("<?xml version=`"1.0`"?>`n<resultset statement=`"x`">`n  <row>`n`t<field name=`"a`">&bogus;</field>`n  </row>`n</resultset>`n"))
$threw = $false; try { [void](Reader $bad).All() } catch { $threw = $true }
Check $threw 'an entity the client never writes is an error'
$inv = [Convert]::ToBase64String([byte[]](@([Text.Encoding]::ASCII.GetBytes("<?xml version=`"1.0`"?>`n<resultset statement=`"x`">`n  <row>`n`t<field name=`"a`">")) + @(0xC3,0x28) + @([Text.Encoding]::ASCII.GetBytes("</field>`n  </row>`n</resultset>`n"))))
Check ((Reader $inv).All()[0][0] -ceq '0xC328') 'bytes that are not UTF-8 come back as hex'

"`n-- column names for an empty result: rerun only what is safe to repeat --"
Check (Test-SqlSafeToRerun 'SELECT * FROM t WHERE 0')          'a SELECT'
Check (Test-SqlSafeToRerun "SET @a=1; SELECT @a FROM t WHERE 0") 'a session variable and a SELECT'
Check (-not (Test-SqlSafeToRerun 'INSERT INTO t VALUES (1); SELECT * FROM t WHERE 0')) 'not after an INSERT'
Check (-not (Test-SqlSafeToRerun 'SET GLOBAL max_connections=10; SELECT 1 FROM t WHERE 0')) 'not a SET GLOBAL'
Check (-not (Test-SqlSafeToRerun 'ANALYZE TABLE t'))            'not ANALYZE'

"`n-- table grids: exact text values put back --"
$nul = [string][char]0
$m = Get-ExactTextMap @('k', 'v', 'K', 'up', '__nobs_exact_0', '__nobs_exact_1') @('k', 'up')
Check ($null -eq $m.err -and $m.keep -eq 4 -and ($m.names -join ',') -eq 'k,v,K,up') 'the hex columns are not shown' ($m.names -join ',')
Check (($m.targets[0] -join ',') -eq '0,2' -and ($m.targets[1] -join ',') -eq '3') 'each text column maps to every shown column of that name, in any case' (($m.targets | ForEach-Object { $_ -join '+' }) -join ' ')
Check ([bool](Get-ExactTextMap @('k', 'v', '__nobs_exact_0') @('k', 'v')).err) 'a result without every hex column is an error'
Check ([bool](Get-ExactTextMap @('k', '__nobs_exact_1') @('k')).err) 'a hex column out of place is an error'
Check ([bool](Get-ExactTextMap @('__nobs_exact_0') @('k')).err) 'nothing left to show is an error'

$hex = { param([string]$s) -join ([Text.Encoding]::UTF8.GetBytes($s) | ForEach-Object { $_.ToString('X2') }) }
$rows = New-Object 'System.Collections.Generic.List[string[]]'
# k 'a<NUL>b' shown as 'a b'; K is an expression (UPPER) that shares the name; up untouched.
$rows.Add([string[]]@('a b', 'x', 'A B', 'é z', (& $hex "a${nul}b"), (& $hex "é${nul}z")))
# (a [string[]] cast would turn $null into '')
$r2 = New-Object string[] 6; $r2[0] = 'a b'; $r2[1] = 'y'; $r2[2] = 'A B'; $rows.Add($r2)
$rows.Add([string[]]@("c${nul}", 'z', 'C', '', $null, $null))
$out = [NobsXmlRows]::Exact($rows, $m.keep, $m.targets)
Check ($out.Count -eq 3 -and $out[0].Length -eq 4) 'rows keep only the shown columns'
Check ($out[0][0] -ceq "a${nul}b") 'the value XML showed with a space is exact again' (Show $out[0][0])
Check ($out[0][2] -ceq 'A B') 'a column that only shares the name keeps its own value' (Show $out[0][2])
Check ($out[0][3] -ceq "é${nul}z") 'non-ASCII text too' (Show $out[0][3])
Check ($out[1][0] -ceq 'a b' -and $null -eq $out[1][3]) 'a row without NULs is unchanged, NULL included'
Check ($out[2][0] -ceq "c${nul}" -and $out[2][3] -ceq '') 'as is a value that is already right'
''

"`n-- NobsLf, which reads that header line --"
$r2 = New-Object IO.StreamReader((New-Object IO.MemoryStream(,[byte[]](0x61,0x0D,0x62,0x0A,0x63))), $script:RawEnc)
Check (([NobsLf]::ReadLine($r2)) -ceq "a`rb") 'a line ends at LF, not at CR'
Check (([NobsLf]::ReadLine($r2)) -ceq 'c')    'the last line needs no LF'
Check ($null -eq [NobsLf]::ReadLine($r2))     'then end of input'

if ($fail) { "`n  $fail FAILED"; exit 1 } else { "`n  all passed"; exit 0 }
