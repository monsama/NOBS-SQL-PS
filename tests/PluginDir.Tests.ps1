# Tests for Get-PluginDir / Friendly-AuthErr - finding the client's authentication plugins.
#
# MySQL 8 authenticates every account with caching_sha2_password by default, including root. That
# is a CLIENT-side plugin: a separate DLL the client loads at connect time, looked for relative to
# the client's own location (../lib/plugin) unless it is told otherwise.
#
# Api-DownloadTools unpacked the .exe files into a flat directory and nothing else, so there was no
# lib/plugin anywhere near them and every connection to a stock MySQL 8 server failed before it got
# as far as negotiating SSL:
#
#   ERROR 1045 (28000): Plugin caching_sha2_password could not be loaded:
#   The specified module could not be found. Library path is 'caching_sha2_password.dll'
#
# Reproduced against a real MySQL 8.0.46 server, and fixed by unpacking the plugins - which ship in
# the same archive - into plugin/ beside the binaries and pointing the client at it.
#
#   pwsh -NoProfile -File tests/PluginDir.Tests.ps1 ./NOBSSQL.ps1

param([Parameter(Mandatory)][string]$ScriptPath)

$e=$null;$t=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile($ScriptPath,[ref]$t,[ref]$e)
if($e -and $e.Count){ "PARSE ERRORS: $($e.Count)"; exit 1 }
$ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                        $n.Name -in @('Get-PluginDir','Friendly-AuthErr','Get-CnfSafe')},$true) |
  ForEach-Object { Invoke-Expression $_.Extent.Text }

$fail = 0
function Check($cond, $label, $detail) {
  if ($cond) { "  ok    $label" } else { "  FAIL  $label$(if($detail){" -> $detail"})"; $script:fail++ }
}

# A throwaway tree standing in for the app's own tools directory.
$root    = Join-Path ([IO.Path]::GetTempPath()) ("plugindir-" + [Guid]::NewGuid().ToString('N'))
$ourBin  = Join-Path $root 'bin'
$ourPlug = Join-Path $ourBin 'plugin'
$sysBin  = Join-Path $root 'MariaDB\bin'
New-Item -ItemType Directory -Path $ourBin, $sysBin -Force | Out-Null
New-Item -ItemType File -Path (Join-Path $ourBin 'mysql.exe'), (Join-Path $sysBin 'mysql.exe') -Force | Out-Null

try {
    $script:ToolsDir = $ourBin

    "-- our own flat tools directory --"
    $script:MysqlPath = Join-Path $ourBin 'mysql.exe'
    Check ($null -eq (Get-PluginDir)) 'no plugin dir yet, so nothing is claimed' "got $(Get-PluginDir)"
    New-Item -ItemType Directory -Path $ourPlug -Force | Out-Null
    Check ((Get-PluginDir) -eq $ourPlug) 'once plugin/ exists beside the binaries it is used' "got $(Get-PluginDir)"

    "`n-- a client from a real installation finds its own, and must be left alone --"
    # Overriding a full MariaDB or MySQL install's plugin directory with a different product's
    # plugins is how a working connection gets broken.
    $script:MysqlPath = Join-Path $sysBin 'mysql.exe'
    Check ($null -eq (Get-PluginDir)) 'a client outside our tools directory is not redirected' "got $(Get-PluginDir)"

    "`n-- nothing configured at all --"
    $script:MysqlPath = $null
    Check ($null -eq (Get-PluginDir)) 'no client path, no plugin dir'

    "`n-- the error a missing plugin produces has to say what to do about it --"
    $real = "ERROR 1045 (28000): Plugin caching_sha2_password could not be loaded: The specified module could not be found. Library path is 'caching_sha2_password.dll'"
    $hint = Friendly-AuthErr $real
    Check ($hint -ne $real)                   'the raw message is not passed through unchanged'
    Check ($hint -match '(?i)caching_sha2')   'it names the plugin MySQL 8 actually uses'
    Check ($hint -match '(?i)settings')       'it points at where the fix lives'
    Check ($hint.StartsWith($real))           'the original error text is kept, not replaced' $hint

    "`n-- and it must not editorialise about unrelated failures --"
    foreach ($other in @(
        "ERROR 1045 (28000): Access denied for user 'root'@'localhost' (using password: YES)",
        "ERROR 2003 (HY000): Can't connect to MySQL server on '127.0.0.1'",
        "ERROR 1049 (42000): Unknown database 'nope'")) {
        Check ((Friendly-AuthErr $other) -eq $other) "left alone: $($other.Substring(0,32))..."
    }
}
finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }

if ($fail) { "`n  $fail FAILED"; exit 1 } else { "`n  all passed"; exit 0 }
