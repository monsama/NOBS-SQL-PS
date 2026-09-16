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
                        $n.Name -in @('Get-SslLines','Test-ClientIsMariaDB','Get-CnfSafe','Friendly-TlsErr','Test-MySqlHexIdentified')},$true) |
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

"`n-- the CA certificate, which is what makes 'verify' usable at all against a private server --"
# Both MariaDB and MySQL generate a self-signed certificate when none is configured, and no system
# trust store will ever accept one - so without a CA, 'verify' cannot succeed against an ordinary
# private server. MySQL's client is blunter still: it refuses to start without one at all.
Check (Get-SslLines 'verify' $true  'C:\certs\ca.pem') 'ssl,ssl-verify-server-cert,ssl-ca=C:\\certs\\ca.pem' 'MariaDB client, verify with a CA'
Check (Get-SslLines 'verify' $false 'C:\certs\ca.pem') 'ssl-mode=VERIFY_IDENTITY,ssl-ca=C:\\certs\\ca.pem'  'MySQL client, verify with a CA'
# Backslashes are doubled because the option-file parser treats them as escape characters - an
# undoubled Windows path would be silently mangled before the client ever saw it.
Check (Get-SslLines 'verify' $true 'C:\a\b\ca.pem') 'ssl,ssl-verify-server-cert,ssl-ca=C:\\a\\b\\ca.pem' 'backslashes are doubled for the option-file parser'

# The other modes verify nothing, so a CA there would imply a check that is not happening.
Check (Get-SslLines 'required' $true  'C:\certs\ca.pem') 'ssl'               'a CA is ignored for required (nothing is verified)'
Check (Get-SslLines 'disabled' $true  'C:\certs\ca.pem') 'skip-ssl'          'a CA is ignored for disabled'
Check (Get-SslLines 'default'  $true  'C:\certs\ca.pem') ''                  'a CA is ignored for default'
Check (Get-SslLines 'required' $false 'C:\certs\ca.pem') 'ssl-mode=REQUIRED' 'a CA is ignored for required, MySQL dialect'

# And no CA means no line at all, rather than an empty one the client would choke on.
Check (Get-SslLines 'verify' $true '')    'ssl,ssl-verify-server-cert' 'an empty CA writes no line'
Check (Get-SslLines 'verify' $true $null) 'ssl,ssl-verify-server-cert' 'a null CA writes no line'

# A newline in the path would start a fresh directive in the options file - the same injection
# Get-CnfSafe exists to stop, and it has to apply here too.
Check (Get-SslLines 'verify' $true "C:\ca.pem`npager=calc.exe") 'ssl,ssl-verify-server-cert,ssl-ca=C:\\ca.pempager=calc.exe' 'a newline in the CA path cannot inject another directive'

"`n-- verify-ca: the chain, not the host name --"
# The certificate MariaDB and MySQL generate for themselves never names a real host, so 'verify'
# refuses it even given exactly the right CA. MySQL's client has a chain-only mode for this.
Check (Get-SslLines 'verify-ca' $false 'C:\certs\ca.pem') 'ssl-mode=VERIFY_CA,ssl-ca=C:\\certs\\ca.pem' 'MySQL client, verify-ca with a CA'
Check (Get-SslLines 'verify-ca' $false)                   'ssl-mode=VERIFY_CA'                         'MySQL client, verify-ca without a CA'
# MariaDB's has none, so verify-ca must map to the STRICTER full verification - never to less.
Check (Get-SslLines 'verify-ca' $true 'C:\certs\ca.pem') 'ssl,ssl-verify-server-cert,ssl-ca=C:\\certs\\ca.pem' 'MariaDB client, verify-ca maps to full verification'
Check ((Get-SslLines 'verify-ca' $true) -join ',') ((Get-SslLines 'verify' $true) -join ',') 'MariaDB client: verify-ca is never weaker than verify'

"`n-- a failed verifying connection says which of the three things went wrong --"
# Real messages from the MariaDB client 15.2 and the MySQL client 8.0.46 against MySQL 8.0.46.
$tls = "ERROR 2026 (HY000): TLS/SSL error: Server certificate validation failed. A certificate chain processed, but terminated in a root certificate which is not trusted by the trust provider."
$script:MysqlPath = $null; $script:ClientIsMariaDB = @{ Path = ""; Maria = $true }
$m = Friendly-TlsErr $tls ([pscustomobject]@{ ssl = "verify-ca"; sslCa = "" })
Check ([int]($m -match "Set ""CA certificate""")) "1" "no CA: points at the CA setting"
$m = Friendly-TlsErr $tls ([pscustomobject]@{ ssl = "verify"; sslCa = "C:ca.pem" })
Check ([int]($m -match "could not be validated against it" -and $m -match "mysql.exe")) "1" "CA given, MariaDB client: explains the host-name check and the way round it"
$script:ClientIsMariaDB = @{ Path = ""; Maria = $false }
$m = Friendly-TlsErr "ERROR 2026 (HY000): SSL connection error: CA certificate is required if ssl-mode is VERIFY_CA or VERIFY_IDENTITY" ([pscustomobject]@{ ssl = "verify"; sslCa = "" })
Check ([int]($m -match "refuses SSL mode")) "1" "MySQL client without a CA: says it refuses to start"
$m = Friendly-TlsErr "ERROR 2026 (HY000): SSL connection error: error:0A000086:SSL routines::certificate verify failed" ([pscustomobject]@{ ssl = "verify"; sslCa = "C:ca.pem" })
Check ([int]($m -match "verify-ca")) "1" "MySQL client, verify with a CA: points at verify-ca for the host name"
# Anything else passes through unchanged.
Check (Friendly-TlsErr $tls ([pscustomobject]@{ ssl = "required"; sslCa = "" })) $tls "not a verifying mode: unchanged"
Check (Friendly-TlsErr "ERROR 1045 (28000): Access denied" ([pscustomobject]@{ ssl = "verify"; sslCa = "" })) "ERROR 1045 (28000): Access denied" "not a TLS failure: unchanged"
$script:ClientIsMariaDB = $null

"`n-- user transfer prints MySQL password hashes as 0x literals where the server can --"
foreach ($c in @(@('8.0.46',$true),@('8.0.17',$true),@('9.1.0',$true),@('8.0.16',$false),@('5.7.44-log',$false),@('12.2.2-MariaDB',$false),@('',$false))) {
  Check ([string](Test-MySqlHexIdentified $c[0])) ([string]$c[1]) "print_identified_with_as_hex for '$($c[0])'"
}

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
  foreach ($mode in 'disabled','required','verify','verify-ca') {
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
