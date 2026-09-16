# Tests for Get-SslLines / Test-ClientIsMariaDB - the SSL options written into the temp .cnf that
# mysql and mysqldump are pointed at.
#
# The MariaDB and MySQL clients name these options MUTUALLY EXCLUSIVELY, so sending the wrong
# dialect is not a weaker connection, it is no connection:
#
#   MariaDB client 15.2   ssl-mode=REQUIRED        -> unknown variable 'ssl-mode=REQUIRED'
#   MySQL   client 8.0    --ssl                    -> unknown option '--ssl'
#                         --ssl-verify-server-cert -> unknown option
#                         --skip-ssl               -> unknown option
#
# Both observed on this machine against real binaries. The dialect therefore has to be chosen from
# the CLIENT binary: these lines go into a [client] options file that the client parses at startup,
# before it opens a socket, so the server never gets a say. It used to be chosen from
# $script:ServerIsMariaDB, which is both the wrong end of the connection and a variable that could
# not answer - Api-Connect sets it inside a pooled runspace, so it never reaches the other seven.
#
#   pwsh -NoProfile -File tests/SslLines.Tests.ps1 ./NOBSSQL.ps1

param([Parameter(Mandatory)][string]$ScriptPath)

$e=$null;$t=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile($ScriptPath,[ref]$t,[ref]$e)
if($e -and $e.Count){ "PARSE ERRORS: $($e.Count)"; exit 1 }
$ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                        $n.Name -in @('Get-SslLines','Test-ClientIsMariaDB')},$true) |
  ForEach-Object { Invoke-Expression $_.Extent.Text }

$fail = 0
function Check($got, $expected, $label) {
  $g = @($got) -join ','
  if ($g -ne $expected) { "  FAIL  $label -> got '$g', want '$expected'"; $script:fail++ }
  else { "  ok    $label" }
}

"-- each dialect names the options the way its own client does --"
Check (Get-SslLines 'disabled' $true)  'skip-ssl'                  'MariaDB client, disabled'
Check (Get-SslLines 'required' $true)  'ssl'                       'MariaDB client, required'
Check (Get-SslLines 'verify'   $true)  'ssl,ssl-verify-server-cert' 'MariaDB client, verify'
Check (Get-SslLines 'disabled' $false) 'ssl-mode=DISABLED'         'MySQL client, disabled'
Check (Get-SslLines 'required' $false) 'ssl-mode=REQUIRED'         'MySQL client, required'
Check (Get-SslLines 'verify'   $false) 'ssl-mode=VERIFY_IDENTITY'  'MySQL client, verify'

"`n-- 'default' means leave it to the client, so it writes nothing at all --"
Check (Get-SslLines 'default' $true)  '' 'default, MariaDB client'
Check (Get-SslLines 'default' $false) '' 'default, MySQL client'
Check (Get-SslLines ''        $true)  '' 'empty mode'
Check (Get-SslLines $null     $true)  '' 'null mode'
Check (Get-SslLines 'bogus'   $true)  '' 'an unrecognised mode writes nothing rather than guessing'

"`n-- the SERVER type must not influence the flags: it is the client that parses them --"
$script:ServerIsMariaDB = $false
Check (Get-SslLines 'verify' $true) 'ssl,ssl-verify-server-cert' 'MariaDB client is unaffected by a MySQL server'
$script:ServerIsMariaDB = $true
Check (Get-SslLines 'verify' $false) 'ssl-mode=VERIFY_IDENTITY'  'MySQL client is unaffected by a MariaDB server'
$script:ServerIsMariaDB = $null

"`n-- Test-ClientIsMariaDB caches against the path, so swapping the binary re-probes --"
$script:ClientIsMariaDB = @{ Path = 'C:\old\mysql.exe'; Maria = $false }
$script:MysqlPath = 'C:\old\mysql.exe'
Check (Test-ClientIsMariaDB) 'False' 'a cached answer for the current path is reused'
$script:MysqlPath = 'C:\definitely\not\here\mysql.exe'
Check (Test-ClientIsMariaDB) 'True'  'a different path re-probes (and falls back to MariaDB when it cannot run)'

# The checks above all agree with each other by construction. This one asks the actual binary,
# which is the only thing that can say whether the dialect is right - and is what the original bug
# came down to. --version is enough: the client parses the options file before it does anything.
"`n-- the real client accepts every line we would write for it --"
$client = $null
foreach ($c in @((Join-Path $env:APPDATA 'NOBSSQL\bin\mysql.exe'),
                 'C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe')) {
  if (Test-Path $c) { $client = $c; break }
}
if (-not $client) {
  "  skip  no mysql client found to check against"
} else {
  $maria = ((& $client --version 2>&1 | Out-String) -match 'MariaDB')
  "  using $client (dialect: $(if($maria){'MariaDB'}else{'MySQL'}))"
  foreach ($mode in 'disabled','required','verify') {
    $cnf = Join-Path ([IO.Path]::GetTempPath()) ("ssltest-" + [Guid]::NewGuid().ToString('N') + ".cnf")
    try {
      ("[client]`n" + ((Get-SslLines $mode $maria) -join "`n")) | Set-Content -Encoding ascii $cnf
      $out = (& $client "--defaults-extra-file=$cnf" --version 2>&1 | Out-String)
      if ($out -match "unknown (variable|option)") {
        "  FAIL  the client rejects what we write for '$mode': $((($out -split "`n")[0]).Trim())"; $fail++
      } else { "  ok    '$mode' is accepted by the client" }
    } finally { Remove-Item $cnf -Force -ErrorAction SilentlyContinue }
  }
  # And the opposite dialect must be rejected - otherwise the check above proves nothing, because
  # a client that accepted everything would pass it too.
  $cnf = Join-Path ([IO.Path]::GetTempPath()) ("ssltest-" + [Guid]::NewGuid().ToString('N') + ".cnf")
  try {
    ("[client]`n" + ((Get-SslLines 'verify' (-not $maria)) -join "`n")) | Set-Content -Encoding ascii $cnf
    $out = (& $client "--defaults-extra-file=$cnf" --version 2>&1 | Out-String)
    if ($out -match "unknown (variable|option)") { "  ok    and it rejects the other dialect, as expected" }
    else { "  FAIL  the client accepted the OTHER dialect too - this check cannot detect a mix-up"; $fail++ }
  } finally { Remove-Item $cnf -Force -ErrorAction SilentlyContinue }
}

if ($fail) { "`n  $fail FAILED"; exit 1 } else { "`n  all passed"; exit 0 }
