<#
================================================================================
 NOBSSQL.ps1  -  local web-based MySQL/MariaDB client
 ------------------------------------------------------------------------------
 A tiny PowerShell HTTP server (127.0.0.1 only, no admin) that shells out to
 mysql.exe / mysqldump.exe and returns JSON; the UI is a self-contained HTML
 page in your default browser.

 Features: browse schemas + objects (tables/views/routines/triggers/events),
 run SQL in tabs, editable result grids (insert/update/delete), view & edit
 object DDL, create/drop schemas, drop/rename/truncate tables, data export and
 import.

 USAGE:  powershell -ExecutionPolicy Bypass -File .\NOBSSQL.ps1
         (browser opens automatically; close THIS console to stop the server)

 COPYRIGHT & LICENSE:
 NOBS SQL Editor (PowerShell edition) - a MySQL/MariaDB client.
 Copyright (C) 2026 Viktor Ljuca <https://monsama.ch>

 This program is free software; you can redistribute it and/or modify it
 under the terms of the GNU General Public License as published by the Free
 Software Foundation; either version 2 of the License, or (at your option)
 any later version.

 This program is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
 or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License
 for more details.

 You should have received a copy of the GNU General Public License along
 with this program; if not, see <https://www.gnu.org/licenses/>. A copy is
 in the LICENSE file at the root of this repository.
================================================================================
#>
param([switch]$NoBrowser)

# Shown in the startup banner and the About box. Same numbering as the desktop edition's releases.
$script:AppVersion = '1.3.5'
$script:PackedPayload = ''
# Default MariaDB client-tools download URL, editable in Settings and stored under
# "mariadb_download_url_template" in the same config file as the tool paths. {version} and
# {file_name} are filled in from the latest LTS release the MariaDB REST API reports. A direct
# mirror is the default rather than the API's own file_download_url, which has been observed
# answering 403 with an error page instead of the archive.
$script:DefaultMariaDbUrlTemplate = 'https://mirror.mariadb.org/mariadb-{version}/winx64-packages/{file_name}'

$ErrorActionPreference = 'Stop'
$script:MysqldumpPath = $null
$script:MysqlPath     = $null
$script:ServerIsMariaDB = $null
# Which SSL flag dialect the CLIENT binary speaks - see Test-ClientIsMariaDB. Deliberately
# separate from ServerIsMariaDB above, which describes the far end of the connection.
$script:ClientIsMariaDB = $null
$script:DumpIsMariaDB = $null
$script:RunningQueries = [System.Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
$script:RunningJobs = [System.Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
# Live, streaming query cursors opened by /api/query and read incrementally by
# /api/fetch-cursor-batch (possibly from a DIFFERENT pooled runspace than the one that opened
# it - see the RUNSPACE POOL SETUP section near the bottom, which shares this dictionary the
# same way it already shares $script:RunningQueries). Keyed by a generated cursorId; each value
# is the pscustomobject built by Open-QueryCursor (Process/Reader/Rows/Headers/RequestId/
# Cnf/LastUsed/Lock). See Open-QueryCursor, Api-FetchCursorBatch, Api-CloseCursor below.
$script:OpenCursors = [System.Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
# What each server is (host:port -> $true for MariaDB), shared by every runspace - see Get-ServerIsMariaDB.
$script:ServerFlavor = [System.Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
# A simple thread-safe set of requestIds the user has asked to cancel. Compare operations run
# MANY sequential queries (one per table/chunk) rather than one big one, so instead of trying to
# kill whichever single sub-query happens to be in flight, each loop just checks this set between
# iterations and stops cleanly if its requestId shows up here.
$script:CancelledCompares = [System.Collections.Concurrent.ConcurrentDictionary[string,bool]]::new()

$script:CfgFile = Join-Path $env:APPDATA 'NOBSSQL\config.json'
$script:ToolsDir = Join-Path $env:APPDATA 'NOBSSQL\bin'

# Snapshot builtin function names now, before any of our own functions exist,
# so later we can diff out just the ones we need to hand to each runspace.
$BuiltinFunctionNames = (Get-ChildItem function:).Name

# Serializes writes to the small JSON config files (connections/library/config) so two
# near-simultaneous saves from different runspaces can't clobber each other.
function Use-FileLock {
    param([string]$Name,[scriptblock]$Body)
    $mtx = New-Object System.Threading.Mutex($false, "Global\NOBSSQL_$Name")
    $got = $false
    try {
        $got = $mtx.WaitOne(5000)
        & $Body
    } finally {
        if ($got) { $mtx.ReleaseMutex() }
        $mtx.Dispose()
    }
}

# Read the saved app config (config.json) - e.g. where mysql.exe lives.
function Load-Cfg { if(Test-Path $script:CfgFile){ try { $raw=[IO.File]::ReadAllText($script:CfgFile); $raw=$raw.TrimStart([char]0xFEFF); if($raw.Trim()){ return ($raw | ConvertFrom-Json) } } catch {} } return $null }
# Write the app config back to disk (config.json).
function Save-Cfg { param($obj) Use-FileLock 'Cfg' { $d=Split-Path $script:CfgFile; if(-not(Test-Path $d)){New-Item -ItemType Directory -Path $d -Force|Out-Null}; [IO.File]::WriteAllText($script:CfgFile, ($obj | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false))) } }
# Find mysql.exe / mysqldump.exe: config -> env vars -> common install folders -> PATH.
# Same order and same directories as the Tauri build's resolve_bin / tool_search_dirs.
function Resolve-Tools {
    $script:MysqlSource = $null; $script:MysqldumpSource = $null
    # 0) user-configured / downloaded paths win
    $cfg = Load-Cfg
    if ($cfg) {
        if ($cfg.mysql_bin -and (Test-Path $cfg.mysql_bin))         { $script:MysqlPath     = [string]$cfg.mysql_bin; $script:MysqlSource = 'Saved configuration' }
        if ($cfg.mysqldump_bin -and (Test-Path $cfg.mysqldump_bin)) { $script:MysqldumpPath = [string]$cfg.mysqldump_bin; $script:MysqldumpSource = 'Saved configuration' }
        if ($script:MysqlPath -and $script:MysqldumpPath) { return }
    }
    if ($script:PackedPayload -and $script:PackedPayload.Trim().Length -gt 0) {
        try {
            $dir = Join-Path $env:TEMP ("mysqlweb_" + [Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $zip = Join-Path $dir 'payload.zip'
            [IO.File]::WriteAllBytes($zip, [Convert]::FromBase64String($script:PackedPayload))
            Expand-Archive -Path $zip -DestinationPath $dir -Force
            Remove-Item $zip -Force
            $dd = Get-ChildItem -Path $dir -Recurse -Filter 'mysqldump.exe' | Select-Object -First 1
            $mm = Get-ChildItem -Path $dir -Recurse -Filter 'mysql.exe'     | Select-Object -First 1
            if ($dd) { $script:MysqldumpPath = $dd.FullName; $script:MysqldumpSource = 'Bundled with this script' }
            if ($mm) { $script:MysqlPath     = $mm.FullName; $script:MysqlSource = 'Bundled with this script' }
            if ($script:MysqlPath) { return }
        } catch { }
    }
    # 1) environment variables, matching the Tauri build's MYSQL_BIN / MYSQLDUMP_BIN step
    if (-not $script:MysqlPath -and $env:MYSQL_BIN -and (Test-Path $env:MYSQL_BIN)) {
        $script:MysqlPath = [string]$env:MYSQL_BIN; $script:MysqlSource = 'MYSQL_BIN environment variable'
    }
    if (-not $script:MysqldumpPath -and $env:MYSQLDUMP_BIN -and (Test-Path $env:MYSQLDUMP_BIN)) {
        $script:MysqldumpPath = [string]$env:MYSQLDUMP_BIN; $script:MysqldumpSource = 'MYSQLDUMP_BIN environment variable'
    }
    # 2) common install folders, BEFORE the PATH, same order and same set of directories as the
    #    Tauri build's tool_search_dirs: under each base, any child named MariaDB*/MySQL*
    #    contributes its own bin and each of its children's bin. That covers both layouts these
    #    products use - "Program Files\MariaDB 11.4\bin" with the version in the folder name, and
    #    "Program Files\MySQL\MySQL Server 8.0\bin" one level deeper - plus WAMP. XAMPP keeps
    #    its bin directly at "xampp\mysql\bin", so it is listed as-is.
    if (-not $script:MysqlPath -or -not $script:MysqldumpPath) {
        $dirs = New-Object System.Collections.Generic.List[string]
        foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, 'C:\wamp64\bin')) {
            if (-not $base) { continue }
            foreach ($kid in (Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
                if ($kid.Name -notmatch '^(?i)(mariadb|mysql)') { continue }
                $dirs.Add((Join-Path $kid.FullName 'bin'))
                foreach ($sub in (Get-ChildItem -LiteralPath $kid.FullName -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
                    $dirs.Add((Join-Path $sub.FullName 'bin'))
                }
            }
        }
        $dirs.Add('C:\xampp\mysql\bin')
        foreach ($d in $dirs) {
            if ($script:MysqlPath -and $script:MysqldumpPath) { break }
            $m = Join-Path $d 'mysql.exe'; $dp = Join-Path $d 'mysqldump.exe'
            if (-not $script:MysqlPath -and (Test-Path $m))      { $script:MysqlPath=$m;      $script:MysqlSource     = "Found in $d" }
            if (-not $script:MysqldumpPath -and (Test-Path $dp)) { $script:MysqldumpPath=$dp; $script:MysqldumpSource = "Found in $d" }
        }
    }
    # 3) last resort: the bare name on the PATH
    if (-not $script:MysqlPath)     { $c=Get-Command mysql.exe -ErrorAction SilentlyContinue;     if($c){$script:MysqlPath=$c.Source; $script:MysqlSource = 'Found on the system PATH'} }
    if (-not $script:MysqldumpPath) { $c=Get-Command mysqldump.exe -ErrorAction SilentlyContinue; if($c){$script:MysqldumpPath=$c.Source; $script:MysqldumpSource = 'Found on the system PATH'} }
}

# Which SSL flag dialect the client binary speaks.
#
# The MariaDB and MySQL clients accept MUTUALLY EXCLUSIVE option names, so getting this wrong does
# not weaken the connection, it stops it dead before a single byte reaches the server:
#   MariaDB client 15.2  --ssl-mode=REQUIRED      -> unknown variable 'ssl-mode=REQUIRED'
#   MySQL   client 8.0   --ssl                    -> unknown option '--ssl'
#                        --ssl-verify-server-cert -> unknown option
#                        --skip-ssl               -> unknown option
#
# This is a property of the BINARY, not of the server: these lines go into a [client] options file
# that the client parses on startup, long before it opens a socket. Choosing from the server type
# was wrong twice over - it asked the wrong end, and it asked a variable that could not answer.
# $script:ServerIsMariaDB is set by Api-Connect from INSIDE a pooled runspace, so the assignment
# stays in whichever of the 8 runspaces happened to serve that request; every other runspace still
# sees the startup $null. Measured against a MySQL server, 8 concurrent requests split 4/4 between
# the two dialects. $script:MysqlPath, by contrast, is resolved at startup and seeded into every
# runspace, so deriving the dialect from it is deterministic everywhere.
# Cached against the path it probed, so pointing Settings at a different client re-probes rather
# than answering for the binary that used to be there.
function Test-ClientIsMariaDB { param([string]$Path)
    if ($Path -and $Path -ne [string]$script:MysqlPath) { return Test-ToolIsMariaDB $Path }
    $path = [string]$script:MysqlPath
    if ($script:ClientIsMariaDB -and $script:ClientIsMariaDB.Path -eq $path) { return $script:ClientIsMariaDB.Maria }
    # The bundled client is MariaDB, so that is the safe assumption if the probe cannot run.
    $maria = $true
    if ($path -and (Test-Path $path)) {
        try { $maria = ((& $path --version 2>&1 | Out-String) -match 'MariaDB') } catch { }
    }
    $script:ClientIsMariaDB = @{ Path = $path; Maria = $maria }
    return $maria
}

# The same probe for any other tool - export and import may use a different pair (see
# Get-ToolFor). One cache entry per path, so switching between the two does not re-probe.
function Test-ToolIsMariaDB { param([string]$Path)
    if (-not $script:ToolFlavor) { $script:ToolFlavor = @{} }
    if ($script:ToolFlavor.ContainsKey($Path)) { return $script:ToolFlavor[$Path] }
    $maria = $true
    if ($Path -and (Test-Path $Path)) {
        try { $maria = ((& $Path --version 2>&1 | Out-String) -match 'MariaDB') } catch { }
    }
    $script:ToolFlavor[$Path] = $maria
    return $maria
}

# Build the SSL-related lines for the temporary my.cnf options file.
#
# $Ca is an optional path to a PEM certificate to trust as the root, and is only meaningful for
# 'verify' - the other modes check nothing, so writing it there would imply a verification that is
# not happening. It is what makes 'verify' usable at all against an ordinary private server: both
# MariaDB and MySQL generate a self-signed certificate when none is configured, and no system trust
# store will ever accept one. MySQL's client is blunter still and refuses to start without it -
# "CA certificate is required if ssl-mode is VERIFY_CA or VERIFY_IDENTITY".
function Get-SslLines {
    param($Mode, $Maria, $Ca)
    if (-not $Mode -or $Mode -eq 'default') { return @() }
    if ($null -eq $Maria) { $Maria = Test-ClientIsMariaDB }
    $lines = @()
    # 'verify-ca' checks the certificate chain but not the host name - which is what a CA needs to
    # be any use against the certificate MariaDB and MySQL generate for themselves, since its name
    # never matches a host. MySQL's client has exactly that (VERIFY_CA). MariaDB's does not: once a
    # CA is supplied it checks the name too (bar loopback), and nothing on its command line turns
    # that off without also putting the chain check in doubt. So on the MariaDB client verify-ca gets
    # the full, STRICTER verification. A setting that asks for verification must never quietly get
    # less; getting more only means failing where a looser client would have connected.
    if ($Maria) { switch ($Mode) { 'disabled'{$lines=@('skip-ssl')} 'required'{$lines=@('ssl')} 'verify'{$lines=@('ssl','ssl-verify-server-cert')} 'verify-ca'{$lines=@('ssl','ssl-verify-server-cert')} } }
    else        { switch ($Mode) { 'disabled'{$lines=@('ssl-mode=DISABLED')} 'required'{$lines=@('ssl-mode=REQUIRED')} 'verify'{$lines=@('ssl-mode=VERIFY_IDENTITY')} 'verify-ca'{$lines=@('ssl-mode=VERIFY_CA')} } }
    if (($Mode -eq 'verify' -or $Mode -eq 'verify-ca') -and $Ca) { $lines += "ssl-ca=$((Get-CnfSafe ([string]$Ca)) -replace '\\','\\')" }
    return $lines
}
# Where the client should look for authentication plugins.
#
# MySQL 8 authenticates with caching_sha2_password by default - every account on a stock install,
# including root. That is a CLIENT-side plugin, a separate DLL the client dlopens at connect time,
# and a client resolves it relative to its own location (../lib/plugin) unless told otherwise.
# Api-DownloadTools extracts the .exe files into a flat directory with no lib/plugin beside them,
# so the bundled client had nowhere to find it and every connection to a stock MySQL 8 server died
# before it could even ask for SSL:
#
#   ERROR 1045 (28000): Plugin caching_sha2_password could not be loaded:
#   The specified module could not be found. Library path is 'caching_sha2_password.dll'
#
# The plugins ship in the same archive the binaries come from; they were simply not being unpacked.
# They are now, into a plugin/ directory beside them, and this points the client at it.
#
# Only for OUR copy. A client from a real MariaDB or MySQL installation sits in a proper bin/ with
# its own lib/plugin next door and finds the right ones by itself - overriding that with a plugin
# set from a different product is how you turn a working connection into a broken one.
function Get-PluginDir { param([string]$Tool)
    $exe = if ($Tool) { $Tool } else { [string]$script:MysqlPath }
    if (-not $exe) { return $null }
    $binDir = Split-Path -Parent $exe
    if (-not $binDir -or -not $script:ToolsDir) { return $null }
    if ($binDir.TrimEnd('\') -ne ([string]$script:ToolsDir).TrimEnd('\')) { return $null }
    $p = Join-Path $script:ToolsDir 'plugin'
    if (Test-Path $p) { return $p }
    return $null
}

# The client plugins worth unpacking: the ones that let it AUTHENTICATE. The archive also carries
# storage engines, audit plugins and the like, which belong to a server and have no business here.
$script:ClientAuthPlugins = @(
    'caching_sha2_password.dll',        # MySQL 8's default, and the reason this exists
    'sha256_password.dll',              # MySQL 5.7's equivalent, still accepted by 8
    'client_ed25519.dll', 'parsec.dll', # MariaDB's own
    'dialog.dll', 'mysql_clear_password.dll',
    'auth_gssapi_client.dll', 'authentication_windows_client.dll', 'auth_named_pipe.dll'
)

# Create a temp my.cnf so the CLI tools can log in WITHOUT the password showing on the command line.
# A raw newline in a value would otherwise start a brand new line in the .cnf file, letting a
# saved connection's host/user/password inject an arbitrary extra option-file directive (e.g.
# "pager=<command>", which the mysql CLI executes) rather than staying part of THIS value.
# Backslash-doubling (below) only protects against a value being misread as an escape sequence -
# it does nothing for an actual embedded newline character, which this strips outright since none
# of these fields have any legitimate use for one.
function Get-CnfSafe { param([string]$s) if(-not $s){ return $s }; return ($s -replace "[\r\n]", '') }
# -Tool: the binary the file is for, when it is not the default mysql.exe. SSL option names and
# the plugin directory both depend on which client reads the file.
function New-Cnf {
    param($conn, [string]$Tool)
    $tmp = Join-Path $env:TEMP ("mysqlcnf_" + [Guid]::NewGuid().ToString('N') + ".cnf")
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('[client]'); [void]$sb.AppendLine("host=$(Get-CnfSafe $conn.host)"); [void]$sb.AppendLine("port=$(Get-CnfSafe $conn.port)"); [void]$sb.AppendLine("user=$(Get-CnfSafe $conn.user)")
    if ($conn.password) { [void]$sb.AppendLine("password=$((Get-CnfSafe $conn.password) -replace '\\','\\')") }
    # Every statement this app sends is UTF-8. Without this MySQL's mysql.exe takes the console code
    # page (cp850 here), so text written through it was converted as if it were cp850: an accented
    # letter was refused by a latin1 column, and stored as other characters elsewhere. MariaDB's
    # client happens to default to utf8mb4. A --default-character-set on the command line still takes precedence.
    [void]$sb.AppendLine('default-character-set=utf8mb4')
    $maria = if ($Tool) { Test-ClientIsMariaDB $Tool } else { $null }
    foreach ($l in (Get-SslLines $conn.ssl $maria $conn.sslCa)) { [void]$sb.AppendLine($l) }
    $pluginDir = Get-PluginDir $Tool
    if ($pluginDir) { [void]$sb.AppendLine("plugin-dir=$((Get-CnfSafe $pluginDir) -replace '\\','\\')") }
    # Only mysql.exe reads [mysql]; mysqldump shares this file and would reject the option. It
    # writes TIMESTAMP values in UTC on its own (--tz-utc). Set for Compare's connections.
    if ($conn.utc) { [void]$sb.AppendLine('[mysql]'); [void]$sb.AppendLine("init-command=`"SET time_zone='+00:00'`"") }
    # Create the file empty first, then lock its ACL down to the current user only,
    # BEFORE writing the password content into it.
    [IO.File]::WriteAllText($tmp, '', (New-Object System.Text.UTF8Encoding($false)))
    try {
        $acl = Get-Acl $tmp
        $acl.SetAccessRuleProtection($true, $false)
        $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($me, 'FullControl', 'Allow')
        $acl.AddAccessRule($rule)
        Set-Acl -Path $tmp -AclObject $acl
    } catch { }
    [IO.File]::WriteAllText($tmp, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
    return $tmp
}
# Safely quote a single command-line argument for the external tools.
function Format-OneArg {
    param([string]$a)
    if ($a -ne '' -and $a -notmatch '[ \t\n\v"]') { return $a }
    $sb=New-Object System.Text.StringBuilder; [void]$sb.Append('"'); $bs=0
    foreach ($ch in $a.ToCharArray()) {
        if ($ch -eq '\'){ $bs++; continue }
        if ($ch -eq '"'){ [void]$sb.Append('\'*($bs*2+1)); [void]$sb.Append('"'); $bs=0; continue }
        if ($bs){ [void]$sb.Append('\'*$bs); $bs=0 }
        [void]$sb.Append($ch)
    }
    if ($bs){ [void]$sb.Append('\'*($bs*2)) }
    [void]$sb.Append('"'); $sb.ToString()
}
# Quote a whole list of command-line arguments.
function Format-Args { param([string[]]$Arguments) ($Arguments | ForEach-Object { Format-OneArg $_ }) -join ' ' }

# Run an external process (mysql/mysqldump) and capture its stdout + stderr.
# If $RequestId is supplied, the running process is registered so /api/cancel-query can kill it.
function Run-Proc {
    param([string]$Exe,[string[]]$Arguments,[string]$RequestId,[string]$JobId,[switch]$RawOut)
    $psi=New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName=$Exe; $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true
    $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true
    $psi.StandardOutputEncoding=$(if($RawOut){$script:RawEnc}else{[System.Text.Encoding]::UTF8}); $psi.StandardErrorEncoding=[System.Text.Encoding]::UTF8
    $psi.Arguments=Format-Args $Arguments
    $p=New-Object System.Diagnostics.Process; $p.StartInfo=$psi; [void]$p.Start()
    $entry=[pscustomobject]@{ Process=$p; Cancelled=$false }
    if ($RequestId) { $script:RunningQueries[$RequestId] = $entry }
    if ($JobId -and $script:RunningJobs.ContainsKey($JobId)) { $script:RunningJobs[$JobId].CurrentProcess = $p }
    try {
        $ot=$p.StandardOutput.ReadToEndAsync(); $et=$p.StandardError.ReadToEndAsync(); $p.WaitForExit()
        $outTxt = try { $ot.Result } catch { '' }
        $errTxt = try { $et.Result } catch { '' }
        if ($entry.Cancelled) { $errTxt = 'Query cancelled by user.' }
        @{ exit=$p.ExitCode; out=$outTxt; err=$errTxt }
    } finally {
        if ($RequestId) { $null = $script:RunningQueries.TryRemove($RequestId, [ref]$null) }
        if ($JobId -and $script:RunningJobs.ContainsKey($JobId)) { $script:RunningJobs[$JobId].CurrentProcess = $null }
    }
}
# Like Run-Proc, but also pipes SQL text into the process via standard input.
function Run-Stdin {
    param([string]$Exe,[string[]]$Arguments,[string]$Text,[string]$File,[string]$JobId,[string]$RequestId,[hashtable]$Rename)
    $psi=New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName=$Exe; $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true
    $psi.RedirectStandardInput=$true; $psi.RedirectStandardError=$true; $psi.Arguments=Format-Args $Arguments
    $p=New-Object System.Diagnostics.Process; $p.StartInfo=$psi; [void]$p.Start()
    if ($JobId -and $script:RunningJobs.ContainsKey($JobId)) { $script:RunningJobs[$JobId].CurrentProcess = $p }
    $qEntry=$null
    if ($RequestId) { $qEntry=[pscustomobject]@{ Process=$p; Cancelled=$false }; $script:RunningQueries[$RequestId]=$qEntry }
    try {
        $et=$p.StandardError.ReadToEndAsync()
        if ($File -and $Rename) {
            # See Get-DumpPlan: the dump's own database statements are pointed at the chosen target.
            try { [NobsDumpDb]::CopyRenamed($File, $p.StandardInput.BaseStream, $Rename.From, $Rename.To) } finally { try { $p.StandardInput.Close() } catch {} }
        } elseif ($File) {
            $fs=[IO.File]::OpenRead($File); $buf=New-Object byte[] 1048576
            try { while(($n=$fs.Read($buf,0,$buf.Length)) -gt 0){ try { $p.StandardInput.BaseStream.Write($buf,0,$n) } catch { break } }; try { $p.StandardInput.BaseStream.Flush() } catch {} } finally { $fs.Close(); try { $p.StandardInput.Close() } catch {} }
        } else {
            $bytes=[Text.Encoding]::UTF8.GetBytes($Text); try { $p.StandardInput.BaseStream.Write($bytes,0,$bytes.Length); $p.StandardInput.BaseStream.Flush() } catch {}; try { $p.StandardInput.Close() } catch {}
        }
        $p.WaitForExit()
        $errTxt = try { $et.Result } catch { '' }
        if ($qEntry -and $qEntry.Cancelled) { $errTxt = 'Cancelled by user.' }
        @{ exit=$p.ExitCode; err=$errTxt }
    } finally {
        if ($JobId -and $script:RunningJobs.ContainsKey($JobId)) { $script:RunningJobs[$JobId].CurrentProcess = $null }
        if ($RequestId) { $null = $script:RunningQueries.TryRemove($RequestId, [ref]$null) }
    }
}

$script:ReservedSet = [System.Collections.Generic.HashSet[string]]::new([string[]]@('accessible','add','all','alter','analyze','and','as','asc','asensitive','before','between','bigint','binary','blob','both','by','call','cascade','case','change','char','character','check','collate','column','condition','constraint','continue','convert','create','cross','cube','cume_dist','current_date','current_time','current_timestamp','current_user','cursor','database','databases','day_hour','day_microsecond','day_minute','day_second','dec','decimal','declare','default','delayed','delete','dense_rank','desc','describe','deterministic','distinct','distinctrow','div','double','drop','dual','each','else','elseif','empty','enclosed','escaped','except','exists','exit','explain','false','fetch','first_value','float','float4','float8','for','force','foreign','from','fulltext','function','generated','get','grant','group','grouping','groups','having','high_priority','hour_microsecond','hour_minute','hour_second','if','ignore','in','index','infile','inner','inout','insensitive','insert','int','int1','int2','int3','int4','int8','integer','intersect','interval','into','io_after_gtids','io_before_gtids','is','iterate','join','json_table','key','keys','kill','lag','last_value','lateral','lead','leading','leave','left','like','limit','linear','lines','load','localtime','localtimestamp','lock','long','longblob','longtext','loop','low_priority','master_bind','master_ssl_verify_server_cert','match','maxvalue','mediumblob','mediumint','mediumtext','middleint','minute_microsecond','minute_second','mod','modifies','natural','not','no_write_to_binlog','nth_value','ntile','null','numeric','of','on','optimize','optimizer_costs','option','optionally','or','order','out','outer','outfile','over','partition','percent_rank','precision','primary','procedure','purge','range','rank','read','reads','read_write','real','recursive','references','regexp','release','rename','repeat','replace','require','resignal','restrict','return','revoke','right','rlike','row','rows','row_number','schema','schemas','second_microsecond','select','sensitive','separator','set','show','signal','smallint','spatial','specific','sql','sqlexception','sqlstate','sqlwarning','sql_big_result','sql_calc_found_rows','sql_small_result','ssl','starting','stored','straight_join','system','table','terminated','then','tinyblob','tinyint','tinytext','to','trailing','trigger','true','undo','union','unique','unlock','unsigned','update','usage','use','using','utc_date','utc_time','utc_timestamp','values','varbinary','varchar','varcharacter','varying','virtual','when','where','while','window','with','write','xor','year_month','zerofill'))
# True if a table/column name must be backtick-quoted (reserved word or odd characters).
function Needs-Quote { param([string]$n) if ($n -eq '' -or $n -notmatch '^[A-Za-z_$][A-Za-z0-9_$]*$') { return $true } return $script:ReservedSet.Contains($n.ToLower()) }
# Result rows are read off mysql.exe's stdout with a byte-preserving Latin-1 reader (see
# NobsXmlRows), so every char in a raw field is exactly one byte the server sent.
#
# Reading stdout as UTF-8 instead - which is what this did - silently destroyed every byte that
# was not valid UTF-8: the .NET decoder replaced each one with U+FFFD before any of this code saw
# it. A VARBINARY holding 00 FF 10 came back as 0x00EFBFBD10 (EFBFBD being U+FFFD re-encoded), and
# because the grid writes a cell back exactly as it displays it, saving that row committed the
# corruption to disk. Verified against a live server, before and after.
$script:RawEnc    = [System.Text.Encoding]::GetEncoding(28591)              # ISO-8859-1: byte <-> char, lossless
$script:StrictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)     # throws rather than substituting

# Recovers real text from a Latin-1-read string, for values that are known to be text (column
# headers). Falls back to the raw string if it is somehow not valid UTF-8, since a header is more
# useful mangled than missing.
function ConvertFrom-RawText {
    param([string]$s)
    if ([string]::IsNullOrEmpty($s)) { return $s }
    try { return $script:StrictUtf8.GetString($script:RawEnc.GetBytes($s)) } catch { return $s }
}

# Quote an identifier (table/column) with backticks when needed - prevents broken/injected SQL.
function SqlId  { param($x) $s=[string]$x; if (Needs-Quote $s) { '`' + ($s -replace '`','``') + '`' } else { $s } }
# Quote a value as a SQL string literal (single quotes, escaped) - or NULL.
# CR and NUL are written as escapes. mysql.exe reading a script (stdin, or source) turns every CR LF
# into LF, so a raw CR before a line feed was silently dropped - measured with both clients. A raw
# NUL makes it refuse the whole statement unless --binary-mode is on.
function SqlLit { param($x) if($null -eq $x){'NULL'} else { "'" + ((((([string]$x) -replace '\\','\\') -replace "'","''") -replace "`r",'\r') -replace "`0",'\0') + "'" } }
# Run-Query2 represents binary/control-character values (e.g. a bit(1) byte, or blob content
# with unprintable bytes) as hex text like "0x00" for safe display - that is NOT a real value,
# it's our own display encoding. If we quote it with SqlLit as a string, MySQL tries to store
# the literal 4-character text '0x00' instead of the 1-byte value it represents, which is why
# a bit(1)/binary column fails with "Data too long". This emits it as a raw (unquoted) hex
# literal instead, which MySQL correctly interprets as the original binary value.
function SqlValLit { param($x)
    if($null -eq $x){ return 'NULL' }
    $s = [string]$x
    if($s -match '^0x[0-9A-Fa-f]+$'){ return $s }
    return (SqlLit $x)
}
# SqlValLit guesses from the value's shape, which is wrong both ways for data being copied: a text
# column holding '0x41' was written as the byte A, and an empty binary value - read as the bare
# 0x - was written as the two characters 0x. Where the table is known, ask it instead. $Binary is
# whether the column is one mysql.exe --binary-as-hex prints as 0x.. (see Get-BinaryColumnSet).
function SqlValFor { param($x, [bool]$Binary)
    if($null -eq $x){ return 'NULL' }
    $s = [string]$x
    if($Binary -and $s -cmatch '^0x([0-9A-Fa-f]*)$'){ if($matches[1].Length -eq 0){ return "X''" } return $s }
    return (SqlLit $s)
}
# The columns of a table whose values come back as 0x.. hex (binary strings, BIT, and spatial
# types - checked against both clients). $null if the table cannot be read.
function Get-BinaryColumnSet { param($conn,$db,$table)
    Get-ColumnSetOf $conn $db $table @('binary','varbinary','tinyblob','blob','mediumblob','longblob','bit',
             'geometry','point','linestring','polygon','multipoint','multilinestring','multipolygon','geometrycollection','geomcollection')
}
# A FLOAT is read as rounded text (1.1 is stored as 1.10000002384), and that text compared to the
# column matches nothing - so rows keyed by one could not be fetched or updated by their key. Such
# key columns are compared as text instead (Get-KeyCol).
function Get-FloatColumnSet { param($conn,$db,$table) Get-ColumnSetOf $conn $db $table @('float') }
function Get-KeyCol { param($col, $floatSet)
    if ($floatSet -and $floatSet.Contains([string]$col)) { return 'CAST(' + (SqlId $col) + ' AS CHAR)' }
    return (SqlId $col)
}
# The names of the columns of db.table whose DATA_TYPE is one of $types, ignoring case; $null when
# the table's columns cannot be read.
function Get-ColumnSetOf { param($conn,$db,$table,$types)
    $r = Run-Query2 $conn ("SELECT COLUMN_NAME, DATA_TYPE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=" + (SqlLit $db) + " AND TABLE_NAME=" + (SqlLit $table)) $null
    if(-not $r.ok -or $r.rows.Count -eq 0){ return $null }
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($row in $r.rows){ if($types -contains ([string]$row[1]).ToLower()){ [void]$set.Add([string]$row[0]) } }
    return ,$set
}
# SELECT * for rows that are about to be copied, exactly. mysql.exe --xml writes a NUL byte inside
# a text value as a space, so a copy made from that output would change the value. Each text
# column therefore also comes back, in the same statement, as hex - but only where it holds a
# NUL, which leaves the extra columns NULL (and cheap) everywhere else - and those values replace
# the ones XML mangled.
#
# The columns are named rather than SELECT *: SELECT * leaves out INVISIBLE columns (MySQL 8.0.23+,
# MariaDB 10.3+), so a copy made from it stored NULL in them, and a generated column cannot be given
# a value, so a copy that included one was refused. All but the generated columns are read, plus
# any generated one in -Keep (a key column, without which rows could not be told apart), or exactly
# -Columns, so that both sides of a comparison come back in the same order.
function Get-ExactRows { param($conn,$db,$table,$where,$RequestId,$Keep,$Columns)
    $types = 'char','varchar','tinytext','text','mediumtext','longtext'
    $cr = Run-Query2 $conn ("SELECT COLUMN_NAME, DATA_TYPE, EXTRA FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=" + (SqlLit $db) + " AND TABLE_NAME=" + (SqlLit $table) + " ORDER BY ORDINAL_POSITION") $null
    if(-not $cr.ok){ return $cr }
    if(@($cr.rows).Count -eq 0){ return @{ ok=$false; err="Could not read the columns of $db.$table." } }
    $typeOf = @{}; foreach($row in $cr.rows){ $typeOf[[string]$row[0]] = ([string]$row[1]).ToLower() }
    if ($Columns) { $selCols = @($Columns | ForEach-Object { [string]$_ }) }
    else { $selCols = @($cr.rows | Where-Object { -not (Test-GeneratedExtra ([string]$_[2])) -or ($Keep -and (@($Keep) -contains [string]$_[0])) } | ForEach-Object { [string]$_[0] }) }
    $textCols = @($selCols | Where-Object { $types -contains $typeOf[$_] })
    $extra = ''
    for($i=0; $i -lt $textCols.Count; $i++){
        $c = SqlId $textCols[$i]
        $extra += ", IF(LOCATE(0x00, CAST(CONVERT($c USING utf8mb4) AS BINARY)) > 0, HEX(CONVERT($c USING utf8mb4)), NULL) AS ``nobs_nul_$i``"
    }
    $r = Run-Query2 $conn ("SELECT " + (($selCols | ForEach-Object { SqlId $_ }) -join ',') + "$extra FROM " + (SqlId $db) + '.' + (SqlId $table) + ' WHERE ' + $where) $null $RequestId
    if(-not $r.ok -or $textCols.Count -eq 0){ return $r }
    $n = @($r.columns).Count - $textCols.Count
    if($n -le 0){ return @{ ok=$true; columns=@(); rows=(New-Object System.Collections.ArrayList) } }
    $cols = @(@($r.columns)[0..($n-1)])
    $idx = @($textCols | ForEach-Object { [Array]::IndexOf($cols, $_) })
    $rows = New-Object System.Collections.ArrayList
    foreach($row in $r.rows){
        $out = New-Object string[] $n
        [Array]::Copy($row, $out, $n)
        for($i=0; $i -lt $textCols.Count; $i++){
            $hex = $row[$n + $i]
            if($null -ne $hex -and $idx[$i] -ge 0){
                $bytes = New-Object byte[] ($hex.Length / 2)
                for($b=0; $b -lt $bytes.Length; $b++){ $bytes[$b] = [Convert]::ToByte($hex.Substring($b*2, 2), 16) }
                $out[$idx[$i]] = [Text.Encoding]::UTF8.GetString($bytes)
            }
        }
        [void]$rows.Add($out)
    }
    return @{ ok=$true; columns=$cols; rows=$rows }
}
# EXTRA for a generated column: VIRTUAL/STORED GENERATED on both servers, PERSISTENT GENERATED on
# older MariaDB. MySQL's DEFAULT_GENERATED only marks an expression default.
function Test-GeneratedExtra { param([string]$Extra) return ($Extra -match '(?i)(VIRTUAL|STORED|PERSISTENT) GENERATED') }
# A WHERE clause matching a chunk of primary-key tuples, each value written for its column's type.
function Get-PkWhere { param($pkCols, $chunk, $binSet, $floatSet)
    $bin = @($pkCols | ForEach-Object { $binSet.Contains([string]$_) })
    $flt = @($pkCols | ForEach-Object { [bool]($floatSet -and $floatSet.Contains([string]$_)) })
    $val = { param($v, $i) if ($flt[$i]) { SqlLit $v } else { SqlValFor $v $bin[$i] } }
    if($pkCols.Count -eq 1){
        return (Get-KeyCol $pkCols[0] $floatSet) + ' IN (' + (($chunk | ForEach-Object { & $val $_[0] 0 }) -join ',') + ')'
    }
    $tuples = ($chunk | ForEach-Object { $row = $_; '(' + ((0..($pkCols.Count-1) | ForEach-Object { & $val $row[$_] $_ }) -join ',') + ')' }) -join ','
    return '(' + (($pkCols | ForEach-Object { Get-KeyCol $_ $floatSet }) -join ',') + ') IN (' + $tuples + ')'
}
# One VALUES tuple, each value written for its column's type.
function Get-ValuesTuple { param($cols, $row, $binSet)
    '(' + ((0..($cols.Count-1) | ForEach-Object { SqlValFor $row[$_] ($binSet.Contains([string]$cols[$_])) }) -join ',') + ')'
}
# Pull the first meaningful error line out of tool output.
function FirstErr { param($e)
    $lines=@(($e -split "`r?`n")|Where-Object{ $_.Trim() -and ($_ -notmatch '^\s*-+\s*$') })
    $err=$lines | Where-Object{ $_ -match '(?i)error' } | Select-Object -First 1
    if($err){ $err } elseif($lines.Count){ $lines[0] } else { '' }
}
# What a batch wrapped in START TRANSACTION/COMMIT can honestly claim after mysql.exe exits
# non-zero. Two quite different things end up here.
#
# A statement failed - a duplicate key, a bad type, a missing column. mysql.exe stops at the first
# error by default, so it never reached the COMMIT, and the server discards the open transaction
# when the connection closes. Nothing was applied, and saying so is true.
#
# The connection died. Then the exit code tells us only that we stopped hearing back. If it broke
# while the COMMIT was in flight, the server may have completed it and had nowhere to send the
# acknowledgement. "Rolled back" there is a guess dressed as a fact, and the reassuring guess at
# that - the one that invites someone to apply the same changes a second time.
function Get-BatchFailureNote { param([string]$Err)
    if ($Err -match '(?i)lost connection|server has gone away|can.t connect|broken pipe|connection reset') {
        return "The changes may or may not have been saved - the connection dropped, and if it did so while the commit was in flight the server may have completed it anyway. Check the table before applying these changes again."
    }
    return "No rows were updated - the batch was rolled back."
}
# mysqldump/mysql print exactly this wording (no "ERROR NNNN" prefix, so FirstErr returns it
# verbatim) when a flag the binary doesn't recognise is passed - which happens whenever an
# export/import option only supported by one dump-tool flavor (MySQL vs MariaDB, or an older
# version of either) is used against the other. Name the likely cause instead of leaving a bare
# "unknown variable" for the user to puzzle over.
# A missing client authentication plugin reads like a broken install, and the fix is not obvious
# from the message. It is also the single thing standing between this app and a stock MySQL 8
# server, since caching_sha2_password is what every account on one uses by default.
#
# Client tools downloaded before the plugins were unpacked (see Get-PluginDir) are in exactly this
# state, and no amount of retrying fixes them - the plugin simply is not on disk. Say what to do.
# A verifying connection that fails prints a bare TLS error that names neither the setting nor the
# fix - and the usual cause is a perfectly normal server using the self-signed certificate MariaDB
# and MySQL generate for themselves. Same three cases the Tauri edition explains (no CA, a CA that
# does not match, a name that does not match), worded for whichever client is in use, because the
# MariaDB client cannot check a CA without also checking the host name.
function Friendly-TlsErr { param($raw, $conn)
    $mode = [string]$conn.ssl
    if ($mode -ne 'verify' -and $mode -ne 'verify-ca') { return $raw }
    if ($raw -notmatch '(?i)ERROR 2026|certificate|TLS/SSL|SSL connection error') { return $raw }
    if ($raw -match 'CA certificate is required') {
        return "$raw - the MySQL client refuses SSL mode ""$mode"" without a CA. Set ""CA certificate"" on this connection to the server's CA file, or use ""required"" to encrypt without verifying."
    }
    if (-not [string]$conn.sslCa) {
        return "$raw - SSL mode ""$mode"" needs the server's certificate to be signed by a CA this machine already trusts, and the self-signed certificate MariaDB and MySQL generate by default never is. Set ""CA certificate"" on this connection to the server's CA file, or use ""required"" to encrypt without verifying."
    }
    $tail = ''
    if (Test-ClientIsMariaDB) {
        $tail = " The MariaDB client also checks that the certificate names the host you connected to (except for this machine), and the certificates MariaDB and MySQL generate for themselves never do. For such a server, point Settings at MySQL's own mysql.exe and use ""verify-ca"", which checks only the CA."
    } elseif ($mode -eq 'verify') {
        $tail = " If the CA is right, the certificate may not name the host you connected to - the certificates MariaDB and MySQL generate for themselves never do. ""verify-ca"" checks the CA but not the host name."
    }
    return "$raw - a CA certificate was supplied, but the server's certificate could not be validated against it. Check that the CA file belongs to this server (for a MySQL server with an auto-generated certificate, that is ca.pem in its data directory).$tail"
}
function Friendly-AuthErr { param($raw)
    if ($raw -match "(?i)plugin\s+(\S+)\s+could not be loaded") {
        return "$raw - the client tools are missing the authentication plugin this server asked for. MySQL 8 uses caching_sha2_password for every account by default. Open Settings and download the client tools again (the plugins are unpacked alongside the binaries now), or point Settings at a full MySQL/MariaDB client installation."
    }
    return $raw
}
function Friendly-DumpErr { param($raw)
    if($raw -match "unknown variable '([^']*)'"){
        return "$raw - '$($matches[1])' isn't supported by this build of the tool (MySQL and MariaDB's client tools, and different versions of each, support different flag sets). Uncheck the matching export/import option, or point Settings at the other flavor's .exe."
    }
    return $raw
}

$script:JStrSpecialChars = [char[]]@('\','"',"`r","`n","`t",[char]0,[char]1,[char]2,[char]3,[char]4,[char]5,[char]6,[char]7,[char]8,[char]11,[char]12,[char]14,[char]15,[char]16,[char]17,[char]18,[char]19,[char]20,[char]21,[char]22,[char]23,[char]24,[char]25,[char]26,[char]27,[char]28,[char]29,[char]30,[char]31)
# Encode ONE raw value as JSON (we build JSON by hand to avoid ConvertTo-Json quirks).
function J-Str { param($s)
    if ($null -eq $s) { return 'null' }
    $t=[string]$s
    if ($t.Length -eq 0) { return '""' }
    if ($t.IndexOfAny($script:JStrSpecialChars) -lt 0) { return '"'+$t+'"' }
    $t=$t -replace '\\','\\'; $t=$t -replace '"','\"'; $t=$t -replace "`r",'\r'; $t=$t -replace "`n",'\n'; $t=$t -replace "`t",'\t'
    $t=[regex]::Replace($t,'[\x00-\x08\x0B\x0C\x0E-\x1F]',{ param($m) '\u{0:x4}' -f [int][char]$m.Value[0] })
    '"'+$t+'"'
}
# Encode an array of RAW values as a JSON array. Do NOT pass already-built JSON strings here.
function J-Arr { param($items) '['+(($items|ForEach-Object{ J-Str $_ }) -join ',')+']' }

# Fast path for large result grids: one StringBuilder pass, inlined escaping for the
# common case (no special characters), falling back to J-Str only for the rare cell
# that actually needs it. Avoids a PowerShell function call per cell at scale.
function J-RowsFast {
    param($rows)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('[')
    $rCount = $rows.Count
    for ($r=0; $r -lt $rCount; $r++) {
        if ($r -gt 0) { [void]$sb.Append(',') }
        [void]$sb.Append('[')
        $row = $rows[$r]
        $cCount = $row.Count
        for ($c=0; $c -lt $cCount; $c++) {
            if ($c -gt 0) { [void]$sb.Append(',') }
            $v = $row[$c]
            if ($null -eq $v) { [void]$sb.Append('null') }
            else {
                $t = [string]$v
                if ($t.Length -eq 0) { [void]$sb.Append('""') }
                elseif ($t.IndexOfAny($script:JStrSpecialChars) -lt 0) { [void]$sb.Append('"'); [void]$sb.Append($t); [void]$sb.Append('"') }
                else { [void]$sb.Append((J-Str $t)) }
            }
        }
        [void]$sb.Append(']')
    }
    [void]$sb.Append(']')
    $sb.ToString()
}

# --- run a query, return a hashtable with columns + row-arrays (or error) ---
# Output options every result-reading mysql.exe call uses. See NobsXmlRows for why XML: it is the
# only format in which NULL and the text 'NULL' differ. --binary-as-hex keeps binary and BIT values
# exact (XML turns a NUL byte into a space) and renders them as 0x.., as the Tauri build does.
function Get-ResultArgs { param([string]$Client)
    if (-not $Client) { $Client = [string]$script:MysqlPath }
    if (-not (Test-ClientHasBinaryAsHex $Client)) {
        throw "This mysql.exe ($Client) does not support --binary-as-hex, which this app needs to read binary values without losing bytes. Open Settings and download the client tools, or select a newer MySQL (8.0.19 or later) or MariaDB client."
    }
    return @('--xml','--binary-as-hex','--default-character-set=utf8mb4')
}
# Cached against the path it probed, like Test-ClientIsMariaDB. MariaDB's client reports an unknown
# option and still prints its version with exit code 0, so the text is what tells.
function Test-ClientHasBinaryAsHex { param([string]$Path)
    if (-not $Path) { $Path = [string]$script:MysqlPath }
    if (-not ($script:BinHexByPath -is [hashtable])) { $script:BinHexByPath = @{} }
    if ($script:BinHexByPath.ContainsKey($Path)) { return $script:BinHexByPath[$Path] }
    $ok = $true
    if ($Path -and (Test-Path $Path)) {
        try { $ok = -not ((& $Path --binary-as-hex --version 2>&1 | Out-String) -match '(?i)unknown (option|variable)') } catch { }
    }
    $script:BinHexByPath[$Path] = $ok
    return $ok
}
# Whether running $sql a second time is harmless: Test-SqlReadOnly, minus the statements that
# allows but that change something outside this one session.
function Test-SqlSafeToRerun { param([string]$sql)
    if (-not (Test-SqlReadOnly $sql)) { return $false }
    $s = [regex]::Replace($sql, '/\*.*?\*/', ' ', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    foreach ($stmt in ($s -split ';')) {
        $t = $stmt.Trim()
        if (-not $t) { continue }
        $w = (($t -split '\s+',2)[0]).ToUpper()
        if ($w -in 'ANALYZE','CHECK','CHECKSUM') { return $false }
        if ($w -eq 'SET' -and $t -match '(?i)\b(GLOBAL|PERSIST|PERSIST_ONLY|PASSWORD)\b|@@global') { return $false }
    }
    return $true
}
# The column names of a result that came back without rows, which XML output does not carry.
# --quick --batch prints the header even for an empty result. This runs the statement again, so
# only for one that is safe to repeat; otherwise the names are simply not known ($null).
function Get-ResultHeaders { param($conn,$sql,$db)
    if (-not (Test-SqlSafeToRerun $sql)) { return $null }
    Initialize-DumpDb
    $my = Get-Mysql $conn
    $cnf = New-Cnf $conn -Tool $my
    $sa = New-SqlArg $sql
    $p = $null
    try {
        $a = @("--defaults-extra-file=$cnf","--quick","--batch","--default-character-set=utf8mb4")
        if ($db) { $a += "--database=$db" }
        $a += @("-e",$sa.arg)
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $my; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = $script:RawEnc; $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
        $psi.Arguments = Format-Args $a
        $p = New-Object System.Diagnostics.Process; $p.StartInfo = $psi; [void]$p.Start()
        $et = $p.StandardError.ReadToEndAsync()
        $line = $null
        try { $line = [NobsLf]::ReadLine($p.StandardOutput) } catch { $line = $null }
        # Only the header is wanted; if rows have appeared since, there is no need to read them.
        try { if (-not $p.HasExited) { $p.Kill() } } catch { }
        $p.WaitForExit()
        if ($null -eq $line -or $line -eq '') { return $null }
        # MySQL's client ends lines with CRLF on Windows (see NobsXmlRows).
        if (-not (Test-ClientIsMariaDB $my) -and $line.EndsWith("`r")) { $line = $line.Substring(0, $line.Length - 1) }
        return ,@($line.Split([char]9) | ForEach-Object { ConvertFrom-RawText $_ })
    } finally {
        if ($p) { try { $p.Dispose() } catch { } }
        Remove-Item $cnf -Force -ErrorAction SilentlyContinue
        if ($sa.file) { Remove-Item $sa.file -Force -ErrorAction SilentlyContinue }
    }
}
function Get-InnerMessage { param($err) $e = $err.Exception; while ($e.InnerException) { $e = $e.InnerException }; return $e.Message }
$script:NoHeadersNote = "Query OK. The result was empty, and its column names are not available: mysql.exe only reports them alongside rows, and a statement that changes data is not run a second time to ask."

# Core query runner: send SQL to mysql.exe and parse the result into columns + rows.
# An empty result comes back without column names unless -WithColumns asks for them, since getting
# them means running the statement again (see Get-ResultHeaders) and internal callers never need them.
function Run-Query2 {
    param($conn,$sql,$db,$RequestId,[switch]$WithColumns)
    Initialize-DumpDb
    $my = Get-Mysql $conn
    try { $ra = Get-ResultArgs $my } catch { return @{ ok=$false; err=$_.Exception.Message } }
    $cnf=New-Cnf $conn -Tool $my
    try {
        $a=@("--defaults-extra-file=$cnf") + $ra
        if($db){ $a+="--database=$db" }
        $sa=New-SqlArg $sql; $a+=@("-e",$sa.arg)
        # Read losslessly, then parse (see NobsXmlRows). This used to parse --batch output, which
        # cannot tell NULL from the text 'NULL' - so Compare copied such a value as a real NULL.
        $r=Run-Proc $my $a $RequestId -RawOut
        if($sa.file){ Remove-Item $sa.file -Force -ErrorAction SilentlyContinue }
        if($r.exit -ne 0){ return @{ ok=$false; err=(FirstErr $r.err) } }
        $x = New-Object NobsXmlRows (New-Object System.IO.StringReader ([string]$r.out))
        try { $rows = $x.All() } catch { return @{ ok=$false; err=("Could not read the result from mysql.exe: " + (Get-InnerMessage $_)) } }
        if(-not $x.HasResultSet){ return @{ ok=$true; columns=@(); rows=$rows } }
        if($rows.Count -gt 0){ return @{ ok=$true; columns=@($x.Names); rows=$rows } }
        if(-not $WithColumns){ return @{ ok=$true; columns=@(); rows=$rows } }
        $h = Get-ResultHeaders $conn $sql $db
        if($null -eq $h){ return @{ ok=$true; columns=@(); rows=$rows; note=$script:NoHeadersNote } }
        return @{ ok=$true; columns=$h; rows=$rows }
    } finally { Remove-Item $cnf -Force -ErrorAction SilentlyContinue }
}

# ============================================================================
#  STREAMING QUERY CURSORS (large-result-set editor queries)
#  ----------------------------------------------------------------------------
#  Run-Query2 above (and Run-Query2Bulk below) read the ENTIRE mysql.exe stdout
#  via ReadToEndAsync() before parsing a single row - fine for the DDL/PK/FK/
#  compare-support queries they're used for, but a real crash risk for an
#  editor query against a large table: a high/missing LIMIT fully materializes
#  the whole result set as one giant .NET string before any of it is returned.
#
#  mysql.exe (both the Oracle and MariaDB client) makes this WORSE than it
#  looks: by default it buffers the entire result set INSIDE the client
#  process (mysql_store_result semantics) before it prints anything at all -
#  so reading its stdout incrementally, by itself, does NOT bound memory; the
#  full buffering already happened before a single line reaches us. The
#  --quick flag switches the client to unbuffered/streaming mode
#  (mysql_use_result semantics: fetch-and-print one row at a time as the
#  server sends it), which is what actually makes incremental reading here
#  meaningful. Every cursor-path invocation below passes --quick for exactly
#  this reason - Run-Query2/Run-Query2Bulk deliberately do NOT, since their
#  callers already assume a fully-materialized in-memory result.
#
#  Because every query still shells out to a fresh mysql.exe process (there is
#  no persistent DB connection object to hold a server-side cursor on, unlike
#  a real DB driver), the "cursor" here IS the live mysql.exe process plus an
#  open StreamReader over its stdout: Open-QueryCursor starts it and reads
#  just the first page; Api-FetchCursorBatch reads more pages from the SAME
#  still-running process on a later request (possibly handled by a different
#  pooled runspace, which is why the registry is a ConcurrentDictionary shared
#  via $iss.Variables exactly like $script:RunningQueries already is). The
#  process is registered under the caller's RequestId in $script:RunningQueries
#  using the EXISTING Api-CancelQuery kill path - no second cancel mechanism -
#  and that registration is intentionally NOT cleared just because the first
#  page returned; only whichever event eventually finishes the cursor
#  (exhaustion, an explicit /api/close-cursor, the idle sweep in the main
#  server loop, or a Cancel-triggered kill) clears it, via Close-QueryCursorProc.
# ============================================================================

# A table grid's query also asks for every text column of its table as hex, in columns named
# __nobs_exact_0, _1, ... after the ones shown, wherever the value holds a NUL - which XML output
# turns into a space (see exactTextQuery in the UI). $ExactText names those text columns in order.
# Returns how many columns are shown, and for each text column the shown columns carrying its name;
# or err when the result does not end in exactly those columns.
function Get-ExactTextMap { param([string[]]$Names, [string[]]$ExactText)
    $n = $ExactText.Count
    $keep = $Names.Count - $n
    if ($keep -lt 1) { return @{ err = 'The table query came back with fewer columns than it asked for.' } }
    for ($i = 0; $i -lt $n; $i++) {
        if ($Names[$keep + $i] -cne "__nobs_exact_$i") { return @{ err = "The table query came back without its column __nobs_exact_$i." } }
    }
    $targets = New-Object 'int[][]' $n
    for ($i = 0; $i -lt $n; $i++) {
        $l = New-Object 'System.Collections.Generic.List[int]'
        for ($j = 0; $j -lt $keep; $j++) { if ([string]::Equals($Names[$j], $ExactText[$i], [StringComparison]::OrdinalIgnoreCase)) { $l.Add($j) } }
        $targets[$i] = $l.ToArray()
    }
    return @{ keep = $keep; targets = $targets; names = @($Names[0..($keep - 1)]) }
}

# Reads up to $PageSize more data rows from a cursor's stream. NobsXmlRows reads one row past the
# page and holds on to it, which is how hasMore is known without waiting on a row that may never
# come. A result that cannot be parsed ends the page and is reported via ParseError.
function Read-CursorRows {
    param($cursorObj, [int]$PageSize)
    try {
        $rows = $cursorObj.Rows.Page($PageSize)
        return @{ rows=$rows; hasMore=$cursorObj.Rows.More }
    } catch {
        $cursorObj.ParseError = "Could not read the result from mysql.exe: " + (Get-InnerMessage $_)
        try { if (-not $cursorObj.Process.HasExited) { $cursorObj.Process.Kill() } } catch {}
        return @{ rows=(New-Object 'System.Collections.Generic.List[string[]]'); hasMore=$false }
    }
}

# Finishes a cursor: waits for the process to exit (it is expected to be at or
# very near EOF/exit by the time this is called - either naturally exhausted,
# or already Kill()ed by the caller), collects stderr, disposes the
# reader/process, removes its RunningQueries registration (the SAME dictionary
# /api/cancel-query already looks requestId up in - this is the sole point
# that clears it for a cursor-backed query), and deletes its temp my.cnf.
function Close-QueryCursorProc {
    param($cursor)
    try { $cursor.Process.WaitForExit() } catch {}
    $errTxt = try { $cursor.ErrTask.Result } catch { '' }
    $exitCode = try { $cursor.Process.ExitCode } catch { -1 }
    try { $cursor.Reader.Dispose() } catch {}
    try { $cursor.Process.Dispose() } catch {}
    if ($cursor.RequestId) { $null = $script:RunningQueries.TryRemove($cursor.RequestId, [ref]$null) }
    if ($cursor.Cnf) { Remove-Item $cursor.Cnf -Force -ErrorAction SilentlyContinue }
    # The temp file New-SqlArg may have written for an oversized statement lives as long as the
    # cursor does - mysql.exe is still reading from it while rows are being paged.
    if ($cursor.SqlFile) { Remove-Item $cursor.SqlFile -Force -ErrorAction SilentlyContinue }
    @{ exit=$exitCode; err=$errTxt }
}

# Starts mysql.exe --quick for an editor query, registers it in RunningQueries
# under $RequestId (the existing Api-CancelQuery kill path), then reads up to
# $PageSize+1 rows. If the whole result fit in one page
# the process has already finished by the time this returns - it is closed
# immediately and no cursor is registered. Otherwise a cursorId is generated
# and the still-open process/reader is registered in $script:OpenCursors for
# Api-FetchCursorBatch to continue from.
function Open-QueryCursor {
    param($conn,$sql,$db,$RequestId,[int]$PageSize=1000,[string[]]$ExactText)
    if ($PageSize -lt 1) { $PageSize = 1000 }
    Initialize-DumpDb
    $my = Get-Mysql $conn
    try { $ra = Get-ResultArgs $my } catch { return @{ ok=$false; err=$_.Exception.Message } }
    $cnf = New-Cnf $conn -Tool $my
    $a=@("--defaults-extra-file=$cnf","--quick") + $ra
    if ($db) { $a += "--database=$db" }
    $sqlArg = New-SqlArg $sql
    $a += @("-e",$sqlArg.arg)
    $psi=New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName=$my; $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true
    $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true
    # Result rows are parsed out of this stream, so it must not lose bytes. A UTF-8 reader
    # replaces every invalid byte with U+FFFD, which silently destroyed binary column values
    # before they were ever looked at. Latin-1 maps each byte to one char untouched; NobsXmlRows
    # then decides per field whether those bytes are text. stderr stays UTF-8 - it carries
    # human-readable server messages, not row data.
    $psi.StandardOutputEncoding=$script:RawEnc; $psi.StandardErrorEncoding=[System.Text.Encoding]::UTF8
    $psi.Arguments=Format-Args $a
    $p=New-Object System.Diagnostics.Process; $p.StartInfo=$psi; [void]$p.Start()
    $entry=[pscustomobject]@{ Process=$p; Cancelled=$false }
    if ($RequestId) { $script:RunningQueries[$RequestId] = $entry }
    $cursor=[pscustomobject]@{
        Process=$p; Reader=$p.StandardOutput; Rows=(New-Object NobsXmlRows $p.StandardOutput)
        ErrTask=$p.StandardError.ReadToEndAsync(); Entry=$entry; ParseError=$null
        Headers=$null; RequestId=$RequestId; Cnf=$cnf; SqlFile=$sqlArg.file
        LastUsed=[DateTime]::UtcNow; Lock=[object]::new(); ExactMap=$null
    }
    $page = Read-CursorRows $cursor $PageSize
    if ($ExactText.Count -gt 0 -and $cursor.Rows.Names.Count -gt 0) {
        $cursor.ExactMap = Get-ExactTextMap @($cursor.Rows.Names) $ExactText
        if ($cursor.ExactMap.err) {
            try { if (-not $p.HasExited) { $p.Kill() } } catch {}
            $null = Close-QueryCursorProc $cursor
            return @{ ok=$false; err=$cursor.ExactMap.err }
        }
        $page.rows = [NobsXmlRows]::Exact($page.rows, $cursor.ExactMap.keep, $cursor.ExactMap.targets)
    }
    $shownNames = if ($cursor.ExactMap) { $cursor.ExactMap.names } else { @($cursor.Rows.Names) }
    if (-not $page.hasMore) {
        $r = Close-QueryCursorProc $cursor
        if ($entry.Cancelled) { return @{ ok=$false; err='Query cancelled.'; cancelled=$true } }
        # --quick may already have streamed some rows before the connection/query failed partway
        # through (lost connection, deadlock victim, etc). Surface as an error rather than
        # silently showing a truncated result as if it were the complete one.
        if ($r.exit -ne 0) { return @{ ok=$false; err=(FirstErr $r.err) } }
        if ($cursor.ParseError) { return @{ ok=$false; err=$cursor.ParseError } }
        # No result set at all: a statement that returns none.
        if (-not $cursor.Rows.HasResultSet) { return @{ ok=$true; columns=@(); rows=$page.rows; hasMore=$false } }
        if ($page.rows.Count -gt 0) { return @{ ok=$true; columns=@($shownNames); rows=$page.rows; hasMore=$false } }
        $h = Get-ResultHeaders $conn $sql $db
        if ($null -eq $h) { return @{ ok=$true; columns=@(); rows=$page.rows; hasMore=$false; note=$script:NoHeadersNote } }
        if ($ExactText.Count -gt 0) {
            $m = Get-ExactTextMap $h $ExactText
            if ($m.err) { return @{ ok=$false; err=$m.err } }
            $h = $m.names
        }
        return @{ ok=$true; columns=$h; rows=$page.rows; hasMore=$false }
    }
    $cursor.Headers = @($shownNames)
    $cursorId = [guid]::NewGuid().ToString()
    $script:OpenCursors[$cursorId] = $cursor
    return @{ ok=$true; columns=$cursor.Headers; rows=$page.rows; hasMore=$true; cursorId=$cursorId }
}

# Fetches a PRIMARY KEY column list in bulk (e.g. ~950,000 ids, to work out what is missing or
# different in Compare), streamed straight from mysql.exe into NobsXmlRows rather than read into
# one string first.
#
# This used to read --batch --raw output and split it on tabs and line breaks, which misread any key
# holding a tab or a line break: its row fell apart, it never matched itself on the other side,
# and Compare reported it as missing on both. The XML reader reads every key exactly, and is fast
# enough for this - 100,000 full rows take about a second.
function Run-Query2Bulk { param($conn,$sql,$db,$RequestId)
    Initialize-DumpDb
    $my = Get-Mysql $conn
    try { $ra = Get-ResultArgs $my } catch { return @{ ok=$false; err=$_.Exception.Message } }
    $cnf = New-Cnf $conn -Tool $my
    $sa = New-SqlArg $sql
    $p = $null
    $entry = $null
    try {
        $a = @("--defaults-extra-file=$cnf","--quick") + $ra
        if($db){ $a += "--database=$db" }
        $a += @("-e",$sa.arg)
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $my; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = $script:RawEnc; $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
        $psi.Arguments = Format-Args $a
        $p = New-Object System.Diagnostics.Process; $p.StartInfo = $psi; [void]$p.Start()
        # Registered like Run-Proc does, so Compare's Cancel can kill it mid-read.
        $entry = [pscustomobject]@{ Process=$p; Cancelled=$false }
        if ($RequestId) { $script:RunningQueries[$RequestId] = $entry }
        $et = $p.StandardError.ReadToEndAsync()
        $x = New-Object NobsXmlRows $p.StandardOutput
        $rows = $null; $readErr = $null
        try { $rows = $x.All() } catch { $readErr = Get-InnerMessage $_ }
        $p.WaitForExit()
        $errTxt = try { $et.Result } catch { '' }
        if ($entry.Cancelled) { return @{ ok=$false; err='Query cancelled by user.' } }
        if ($p.ExitCode -ne 0) { return @{ ok=$false; err=(FirstErr $errTxt) } }
        if ($readErr) { return @{ ok=$false; err=("Could not read the result from mysql.exe: " + $readErr) } }
        return @{ ok=$true; columns=@($x.Names); rows=$rows }
    } finally {
        if ($RequestId) { $null = $script:RunningQueries.TryRemove($RequestId, [ref]$null) }
        if ($p) { try { if (-not $p.HasExited) { $p.Kill() } } catch { }; try { $p.Dispose() } catch { } }
        Remove-Item $cnf -Force -ErrorAction SilentlyContinue
        if ($sa.file) { Remove-Item $sa.file -Force -ErrorAction SilentlyContinue }
    }
}


# ---------------------------------------------------------------------------
# API handlers
# ---------------------------------------------------------------------------
# Test the connection and return the server version (called when you click Connect).
function Api-Connect { param($conn)
    if (-not $script:MysqlPath -or -not (Test-Path $script:MysqlPath)) { return '{"ok":false,"error":"mysql.exe not found. Open Settings in the app to select it, or to download the MariaDB client tools."}' }
    # Always asked afresh here, so a server swapped behind the same address is noticed.
    $v = Get-ServerVersion $conn
    if ($null -ne $v.version) {
        $maria = [bool]($v.version -match 'MariaDB')
        $script:ServerFlavor[(Get-ServerFlavorKey $conn)] = $maria
        return '{"ok":true,"version":'+(J-Str $v.version)+',"mariadb":'+$maria.ToString().ToLower()+',"client":'+(J-Str (Get-Mysql $conn))+'}'
    }
    return '{"ok":false,"error":'+(J-Str ("Connection failed: "+(Friendly-TlsErr (Friendly-AuthErr (FirstErr $v.err)) $conn)))+'}'
}
# List databases with their sizes for the left sidebar.
function Api-Schemas { param($conn)
    $r=Run-Query2 $conn "SHOW DATABASES" $null
    if(-not $r.ok){ return '{"ok":false,"error":'+(J-Str $r.err)+'}' }
    $dbs=@($r.rows | ForEach-Object { $_[0] } | Sort-Object)

    # Fetch sizes for each schema
    $sizes = @{}
    foreach ($db in $dbs) {
        $escapedDb = $db -replace "'", "''"
		$sizeQuery = "SELECT SUM(DATA_LENGTH + INDEX_LENGTH) as total_size FROM information_schema.TABLES WHERE TABLE_SCHEMA = "+(SqlLit $db)+" AND TABLE_TYPE = 'BASE TABLE'"
        $sizeR = Run-Query2 $conn $sizeQuery $null
        if ($sizeR.ok -and $sizeR.rows.Count -gt 0 -and $sizeR.rows[0][0] -ne $null) {
            $sizes[$db] = [math]::Round([double]$sizeR.rows[0][0], 2)
        } else {
            $sizes[$db] = 0
        }
    }

    # Build schema list with sizes
    $schemasWithSizes = @()
    foreach ($db in $dbs) {
        $schemasWithSizes += @{ name = $db; size = $sizes[$db] }
    }

    '{"ok":true,"schemas":[' + (($schemasWithSizes | ForEach-Object { '{"name":' + (J-Str $_.name) + ',"size":' + $_.size + '}' }) -join ',') + ']}'
}
# List everything inside a database: tables, views, routines, triggers, events.
function Api-Objects { param($conn,$db)
    $dbl=SqlLit $db
    $sql="SELECT 'table' t,TABLE_NAME n FROM information_schema.TABLES WHERE TABLE_SCHEMA=$dbl AND TABLE_TYPE='BASE TABLE' " +
         "UNION ALL SELECT 'view',TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA=$dbl AND TABLE_TYPE='VIEW' " +
         "UNION ALL SELECT IF(ROUTINE_TYPE='PROCEDURE','procedure','function'),ROUTINE_NAME FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA=$dbl " +
         "UNION ALL SELECT 'trigger',TRIGGER_NAME FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA=$dbl " +
         "UNION ALL SELECT 'event',EVENT_NAME FROM information_schema.EVENTS WHERE EVENT_SCHEMA=$dbl ORDER BY 1,2"
    $r=Run-Query2 $conn $sql $null
    if(-not $r.ok){ return '{"ok":false,"error":'+(J-Str $r.err)+'}' }
    $g=@{ table=@(); view=@(); procedure=@(); function=@(); trigger=@(); event=@() }
    foreach($row in $r.rows){ $t=$row[0]; if($g.ContainsKey($t)){ $g[$t]+=$row[1] } }

    # Which table each trigger belongs to, so a table's own right-click menu can offer its
    # EXISTING triggers directly, not just the flat "Triggers" list elsewhere in the tree.
    # A separate lookup (rather than adding a 3rd column to the UNION above) so the shape of
    # the existing flat trigger-name array - which other code already relies on - never changes.
    $trigTablesJson = '{}'
    if ($g.trigger.Count -gt 0) {
        $tr = Run-Query2 $conn ("SELECT TRIGGER_NAME, EVENT_OBJECT_TABLE FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA=$dbl") $null
        if ($tr.ok -and $tr.rows.Count -gt 0) {
            $pairs = $tr.rows | ForEach-Object { (J-Str ([string]$_[0])) + ':' + (J-Str ([string]$_[1])) }
            $trigTablesJson = '{' + ($pairs -join ',') + '}'
        }
    }

    '{"ok":true,"tables":'+(J-Arr $g.table)+',"views":'+(J-Arr $g.view)+',"procedures":'+(J-Arr $g.procedure)+',"functions":'+(J-Arr $g.function)+',"triggers":'+(J-Arr $g.trigger)+',"events":'+(J-Arr $g.event)+',"triggerTables":'+$trigTablesJson+'}'
}
# Return the CREATE statement (DDL) for a chosen object.
function Api-Ddl { param($conn,$db,$type,$name)
    $obj=(SqlId $db)+'.'+(SqlId $name)
    switch ($type) {
        'table'     { $sql="SHOW CREATE TABLE $obj" }
        'view'      { $sql="SHOW CREATE VIEW $obj" }
        'procedure' { $sql="SHOW CREATE PROCEDURE $obj" }
        'function'  { $sql="SHOW CREATE FUNCTION $obj" }
        'trigger'   { $sql="SHOW CREATE TRIGGER $obj" }
        'event'     { $sql="SHOW CREATE EVENT $obj" }
        default     { return '{"ok":false,"error":"unknown type"}' }
    }
    $r=Run-Query2 $conn $sql $null
    if(-not $r.ok){ return '{"ok":false,"error":'+(J-Str $r.err)+'}' }
    if($r.rows.Count -eq 0){ return '{"ok":false,"error":"no DDL returned"}' }
    $cols=$r.columns; $idx=-1
    for($i=0;$i -lt $cols.Count;$i++){ if($cols[$i] -match '(?i)create|statement'){ $idx=$i; break } }
    if($idx -lt 0){ $idx=$cols.Count-1 }
    $ddl=$r.rows[0][$idx]
    '{"ok":true,"ddl":'+(J-Str $ddl)+'}'
}
# Find a table primary-key columns - needed so grid edits update the correct row.
function Api-Pk { param($conn,$db,$table)
	$dbl=SqlLit $db; $tl=SqlLit $table
	$sql="SELECT COLUMN_NAME FROM information_schema.KEY_COLUMN_USAGE WHERE TABLE_SCHEMA=$dbl AND TABLE_NAME=$tl AND CONSTRAINT_NAME='PRIMARY' ORDER BY ORDINAL_POSITION"
    $r=Run-Query2 $conn $sql $null
    if(-not $r.ok){ return '{"ok":false,"error":'+(J-Str $r.err)+'}' }
    $pk=@($r.rows | ForEach-Object { $_[0] })
    '{"ok":true,"pk":'+(J-Arr $pk)+'}'
}

function Api-SearchAllSchemas { param($conn,$term)
    if(-not $term -or -not ([string]$term).Trim()){ return '{"ok":false,"error":"Empty search term."}' }
    $t = SqlLit ('%'+$term+'%')
    $sql = "SELECT TABLE_SCHEMA,'table',TABLE_NAME FROM information_schema.TABLES WHERE TABLE_TYPE='BASE TABLE' AND TABLE_NAME LIKE $t " +
           "UNION ALL SELECT TABLE_SCHEMA,'view',TABLE_NAME FROM information_schema.TABLES WHERE TABLE_TYPE='VIEW' AND TABLE_NAME LIKE $t " +
           "UNION ALL SELECT ROUTINE_SCHEMA,IF(ROUTINE_TYPE='PROCEDURE','procedure','function'),ROUTINE_NAME FROM information_schema.ROUTINES WHERE ROUTINE_NAME LIKE $t " +
           "UNION ALL SELECT TRIGGER_SCHEMA,'trigger',TRIGGER_NAME FROM information_schema.TRIGGERS WHERE TRIGGER_NAME LIKE $t " +
           "UNION ALL SELECT EVENT_SCHEMA,'event',EVENT_NAME FROM information_schema.EVENTS WHERE EVENT_NAME LIKE $t " +
           "ORDER BY 1,2,3"
    $r=Run-Query2 $conn $sql $null
    if(-not $r.ok){ return '{"ok":false,"error":'+(J-Str $r.err)+'}' }
    $items = @($r.rows | ForEach-Object { '{"schema":'+(J-Str $_[0])+',"type":'+(J-Str $_[1])+',"name":'+(J-Str $_[2])+'}' })
    '{"ok":true,"items":['+($items -join ',')+']}'
}

# SQL goes to mysql.exe as a single command-line argument (-e "..."), and Windows caps a whole
# command line at about 32767 characters. Past that Process.Start throws, and the user saw a raw
# .NET exception - "An error occurred trying to start process" - with nothing about SQL or size in
# it. Saving a BLOB of any real size hit this: a 16 KB value becomes a ~33 KB hex literal.
#
# Past a safe threshold, hand mysql a file to read instead. "source <file>" keeps the argument
# short, and is exactly what Api-Script has always done for multi-statement scripts. The caller
# gets the temp path back and is responsible for deleting it once the process has finished with
# it - for a cursor that means when the cursor closes, not when it is opened.
function New-SqlArg {
    param([string]$Sql)
    # Well under the limit, leaving room for the other arguments and the executable path.
    if ($null -eq $Sql -or $Sql.Length -le 16000) { return @{ arg = $Sql; file = $null } }
    $tmp = Join-Path $env:TEMP ("nobs-sql-" + [Guid]::NewGuid().ToString('N') + ".sql")
    [IO.File]::WriteAllText($tmp, $Sql, (New-Object System.Text.UTF8Encoding($false)))
    return @{ arg = ("source " + ($tmp -replace '\\','/')); file = $tmp }
}

# Execute SQL that returns no rows (INSERT / UPDATE / DDL ...).
function Run-Exec { param($conn,$sql)
    $my=Get-Mysql $conn
    $cnf=New-Cnf $conn -Tool $my
    $sa=New-SqlArg $sql
    try { $r=Run-Proc $my @("--defaults-extra-file=$cnf","--comments","-e",$sa.arg)
        if($r.exit -eq 0){ return '{"ok":true}' } else { return '{"ok":false,"error":'+(J-Str (FirstErr $r.err))+'}' }
    } finally { Remove-Item $cnf -Force -ErrorAction SilentlyContinue; if($sa.file){ Remove-Item $sa.file -Force -ErrorAction SilentlyContinue } }
}
# Read-only guard: true only if EVERY statement is a pure read (SELECT/SHOW/EXPLAIN...).
# Removes every balanced (...) group, tracking nesting depth AND quote state (so a ')' or keyword
# inside a quoted string/identifier - "WHERE a=')SELECT('" is one string literal, not tokens -
# never gets mistaken for a real paren or a real keyword). Used by Test-SqlReadOnly to see past a
# CTE's own body (or a subquery's) to the keyword actually driving the statement. Each removed
# group leaves a single space behind so words on either side don't get glued together.
function Strip-Parens { param([string]$s)
    $out = New-Object System.Text.StringBuilder
    $depth = 0
    $quote = $null
    $escaped = $false
    $chars = $s.ToCharArray()
    for($i = 0; $i -lt $chars.Length; $i++){
        $c = $chars[$i]
        if($quote){
            if($escaped){ $escaped = $false; continue }
            if($c -eq '\'){ $escaped = $true; continue }
            if($c -eq $quote){
                if(($i + 1) -lt $chars.Length -and $chars[$i + 1] -eq $quote){ $i++ }
                else { $quote = $null }
            }
            continue
        }
        if($c -eq "'" -or $c -eq '"' -or $c -eq '`'){ $quote = $c; continue }
        if($c -eq '('){ if($depth -eq 0){ [void]$out.Append(' ') }; $depth++; continue }
        if($c -eq ')'){ if($depth -gt 0){ $depth-- }; if($depth -eq 0){ [void]$out.Append(' ') }; continue }
        if($depth -eq 0){ [void]$out.Append($c) }
    }
    return $out.ToString()
}
# Returns whatever follows the first top-level occurrence of $Keyword, or $null if it never appears
# outside a quoted string. Used to unwrap MariaDB's "SET STATEMENT <assignments> FOR <statement>",
# where the part after FOR is a whole statement that really executes. A FOR inside a string literal
# - SET STATEMENT x='FOR' FOR SELECT 1 - is not the separator and must not be taken for one.
function Split-OffKeyword {
    param([string]$Sql, [string]$Keyword)
    if (-not $Sql) { return $null }
    $up = $Sql.ToUpper()
    $kw = $Keyword.ToUpper()
    $quote = $null
    $escaped = $false
    $i = 0
    while ($i -lt $Sql.Length) {
        $c = $Sql[$i]
        if ($null -ne $quote) {
            if ($escaped) { $escaped = $false }
            elseif ($c -eq '\') { $escaped = $true }
            elseif ($c -eq $quote) { $quote = $null }
            $i++
            continue
        }
        if ($c -eq "'" -or $c -eq '"' -or $c -eq '`') { $quote = $c; $i++; continue }
        # Match on word boundaries, so FORMAT - or a column named for_id - is not read as FOR.
        $beforeOk = ($i -eq 0) -or -not ([char]::IsLetterOrDigit($Sql[$i-1]) -or $Sql[$i-1] -eq '_')
        if ($beforeOk -and ($i + $kw.Length) -le $up.Length -and $up.Substring($i, $kw.Length) -eq $kw) {
            $after = $i + $kw.Length
            if ($after -ge $up.Length -or -not ([char]::IsLetterOrDigit($Sql[$after]) -or $Sql[$after] -eq '_')) {
                return $Sql.Substring($after).Trim()
            }
        }
        $i++
    }
    return $null
}

function Test-SqlReadOnly { param([string]$sql)
    if(-not $sql){ return $true }
    # /*! ... */ and /*!50000 ... */ are NOT comments: MySQL executes their contents. Stripping
    # them like a comment hid the statement inside from the keyword check below, so
    # "/*!50000 DELETE FROM t */" passed as read-only and then deleted rows. Unwrap them first so
    # the SQL they carry is checked like any other, and only then strip real comments.
    $s = [regex]::Replace($sql, '/\*!\d*(.*?)\*/', ' $1 ', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $s = [regex]::Replace($s, '/\*.*?\*/', ' ', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $s = [regex]::Replace($s, '(?m)--.*$', ' ')
    $s = [regex]::Replace($s, '(?m)#.*$', ' ')
    $allow = 'SELECT','SHOW','DESCRIBE','DESC','EXPLAIN','USE','WITH','SET','HELP','VALUES','TABLE','ANALYZE','CHECK','CHECKSUM'
    foreach($stmt in ($s -split ';')){
        $t = $stmt.Trim()
        if(-not $t){ continue }
        $w = (($t -split '\s+',2)[0]).ToUpper()
        if($allow -notcontains $w){ return $false }
        # SELECT ... INTO OUTFILE / INTO DUMPFILE writes a file on the DATABASE SERVER's
        # filesystem, as the mysqld user. It changes no table data, which is presumably why it was
        # never considered here - but a connection the user marked "read-only / safe mode" being
        # able to drop files on the server is not read-only. Verified against a live MariaDB whose
        # secure_file_priv was empty: the statement was reported as read-only and the file appeared
        # on disk. Only the OUTFILE/DUMPFILE forms are refused; SELECT ... INTO @var is an ordinary
        # variable assignment, and an INTO inside a string literal is not a clause at all - which
        # is why this looks for the keyword outside quotes.
        $afterInto = Split-OffKeyword $t 'INTO'
        if ($null -ne $afterInto) {
            $head = (($afterInto -split '\s+')[0]).ToUpper()
            if ($head -eq 'OUTFILE' -or $head -eq 'DUMPFILE') { return $false }
        }
        # SET is allowed because a session variable is harmless, but SET GLOBAL / SET PERSIST -
        # and their @@GLOBAL. / @@PERSIST. spellings - reconfigure the server for every
        # connection, which a read-only connection should not be able to do.
        if($w -eq 'SET'){
            $up = $t.ToUpper()
            $second = ($up -split '\s+')[1]
            if($second -match '^(GLOBAL|PERSIST)' -or $up -match '@@(GLOBAL|PERSIST)'){ return $false }
            # SET is allow-listed for session variables, but several SET forms are not variable
            # assignments at all. These three write, and were reaching the server on a connection
            # the user had marked read-only:
            #   SET PASSWORD FOR 'u'@'%' = ...   changes any account's credentials, root included
            #   SET DEFAULT ROLE admin FOR ...   grants a role to an account
            #   SET STATEMENT x=1 FOR <stmt>     MariaDB: EXECUTES the statement it wraps, so
            #                                    "... FOR DELETE FROM t" really does delete
            # The last is the same shape as the ANALYZE wrapper handled below - a read-only looking
            # prefix carrying an arbitrary statement - so it gets the same treatment: unwrap it and
            # judge the statement that is actually going to run.
            if($second -eq 'PASSWORD'){ return $false }
            if($second -eq 'DEFAULT' -and ($up -split '\s+')[2] -eq 'ROLE'){ return $false }
            if($second -eq 'STATEMENT'){
                $inner = Split-OffKeyword $t 'FOR'
                # No FOR at all is not a form we recognise; refuse rather than guess.
                if($null -eq $inner){ return $false }
                if(-not (Test-SqlReadOnly $inner)){ return $false }
            }
        }
        # A CTE only stays read-only if it's actually prefixing a SELECT/TABLE/VALUES - MySQL
        # 8.0.19+/MariaDB also allow "WITH x AS (...) DELETE/UPDATE FROM t ...", which the leading
        # "WITH" alone can't reveal. Strip every CTE's own (possibly nested) body via Strip-Parens,
        # leaving roughly "WITH cte1 AS , cte2 AS  DELETE FROM t ..." - the first remaining
        # recognizable verb after that is the statement actually being run.
        if($w -eq 'WITH'){
            $verbs = 'SELECT','INSERT','UPDATE','DELETE','REPLACE','TABLE','VALUES'
            $verb = $null
            foreach($tok in ((Strip-Parens $t) -split '\s+')){
                $tu = $tok.ToUpper()
                if($verbs -contains $tu){ $verb = $tu; break }
            }
            if($verb -ne 'SELECT' -and $verb -ne 'TABLE' -and $verb -ne 'VALUES'){ return $false }
        }
        # MariaDB's ANALYZE [FORMAT=JSON] <statement> form (distinct from ANALYZE TABLE) actually
        # EXECUTES the wrapped statement while profiling it - bare "ANALYZE" was allow-listed for
        # the genuinely read-only ANALYZE TABLE form, which would otherwise let "ANALYZE DELETE
        # FROM t" straight through untouched.
        if($w -eq 'ANALYZE'){
            $parts = $t -split '\s+', 2
            $rest = if($parts.Length -gt 1){ $parts[1].TrimStart() } else { '' }
            $firstTok = ($rest -split '\s+')[0]
            if($firstTok -notmatch '(?i)^TABLE$'){
                $inner = [regex]::Replace($rest, '(?i)^FORMAT\s*=\s*JSON\s+', '')
                $innerW = (($inner.Trim() -split '\s+')[0]).ToUpper()
                if($innerW -ne 'SELECT'){ return $false }
            }
        }
    }
    return $true
}
# Endpoint: run a single non-SELECT statement.
function Api-Exec { param($conn,$data) Run-Exec $conn ([string]$data.sql) }
function Api-SchemaErd { param($conn,$db)
    $dbl = SqlLit $db
    $colsR = Run-Query2 $conn ("SELECT TABLE_NAME, COLUMN_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=$dbl ORDER BY TABLE_NAME, ORDINAL_POSITION") $null
    if(-not $colsR.ok){ return '{"ok":false,"error":'+(J-Str $colsR.err)+'}' }
    # PK detection deliberately matches Get-TablePkCols's approach (CONSTRAINT_NAME='PRIMARY'),
    # NOT information_schema.COLUMNS.COLUMN_KEY='PRI'. COLUMN_KEY has a documented MySQL edge
    # case: a table with NO actual primary key but a UNIQUE NOT NULL index will still show that
    # index's column as 'PRI', since it behaves like one. Using the same precise method as the
    # grid means the ER diagram can never highlight a column as PK that the grid itself disagrees
    # is one.
    $pkR = Run-Query2 $conn ("SELECT TABLE_NAME, COLUMN_NAME FROM information_schema.KEY_COLUMN_USAGE WHERE TABLE_SCHEMA=$dbl AND CONSTRAINT_NAME='PRIMARY'") $null
    if(-not $pkR.ok){ return '{"ok":false,"error":'+(J-Str $pkR.err)+'}' }
    $fkR = Run-Query2 $conn ("SELECT TABLE_NAME, COLUMN_NAME, REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME FROM information_schema.KEY_COLUMN_USAGE WHERE TABLE_SCHEMA=$dbl AND REFERENCED_TABLE_NAME IS NOT NULL") $null
    if(-not $fkR.ok){ return '{"ok":false,"error":'+(J-Str $fkR.err)+'}' }
    '{"ok":true,"columns":'+(J-RowsFast $colsR.rows)+',"pks":'+(J-RowsFast $pkR.rows)+',"fks":'+(J-RowsFast $fkR.rows)+'}'
}
function Api-ProcessList { param($conn)
    $r = Run-Query2 $conn "SHOW FULL PROCESSLIST" $null $null
    if(-not $r.ok){ return '{"ok":false,"error":'+(J-Str $r.err)+'}' }
    '{"ok":true,"columns":'+(J-Arr $r.columns)+',"rows":'+(J-RowsFast $r.rows)+'}'
}
function Api-KillProcess { param($conn,$data)
    $pid_ = [string]$data.pid
    if(-not $pid_ -or -not ($pid_ -match '^[0-9]+$')){ return '{"ok":false,"error":"Invalid process id."}' }
    Run-Exec $conn ("KILL " + $pid_)
}
# Endpoint: run a multi-statement SQL script.
function Api-Script { param($conn,$data)
    $my=Get-Mysql $conn
    $cnf=New-Cnf $conn -Tool $my
    $tmp=Join-Path $env:TEMP ("mysqlscript_"+[Guid]::NewGuid().ToString('N')+".sql")
    $requestId=[string]$data.requestId
    try {
        $scriptSql = [string]$data.sql
        if($data.db){ $bt=[string][char]96; $dbEsc=([string]$data.db).Replace($bt,$bt+$bt); $scriptSql = "USE $bt$dbEsc$bt;`n" + $scriptSql }
        # Applying staged grid edits sends several statements that only make sense together: if
        # the third fails, the first two must not stay. mysql.exe stops at the first error by
        # default, so it never reaches the COMMIT and the transaction is rolled back when the
        # connection closes. Without this the batch ran on autocommit and a failure left the
        # table half-updated - the one outcome a pending-changes model exists to prevent.
        if($data.transaction){ $scriptSql = "START TRANSACTION;`n" + $scriptSql + "`nCOMMIT;" }
        [IO.File]::WriteAllText($tmp, $scriptSql, (New-Object System.Text.UTF8Encoding($false)))
        $r=Run-Stdin $my @("--defaults-extra-file=$cnf","--comments") $null $tmp $null $requestId
        if ($r.exit -ne 0 -and (FirstErr $r.err) -match "ASCII '\\0'.*--binary-mode") {
            $r=Run-Stdin $my @("--defaults-extra-file=$cnf","--comments","--binary-mode") $null $tmp $null $requestId
            if($r.exit -eq 0){ return '{"ok":true,"message":"Auto-retried with --binary-mode (statement contained raw NUL bytes)."}' }
        }
        if($r.exit -eq 0){ return '{"ok":true}' } else { return '{"ok":false,"error":'+(J-Str (FirstErr $r.err))+'}' }
    } finally { Remove-Item $cnf -Force -ErrorAction SilentlyContinue; Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}
# Endpoint: run a script on one connection and return every result set it produces - a
# procedure's SELECTs, or several SELECTs in a row - which Api-Script discards. At most maxRows
# rows (default 1000) are kept per result; rowCount counts them all. mysql.exe stops at the first
# error, which is returned with the results produced before it.
function Api-ScriptResults { param($conn,$data)
    Initialize-DumpDb
    $my = Get-Mysql $conn
    try { $ra = Get-ResultArgs $my } catch { return '{"ok":false,"error":'+(J-Str $_.Exception.Message)+'}' }
    $maxRows = [int]$data.maxRows; if ($maxRows -lt 1) { $maxRows = 1000 }
    $scriptSql = [string]$data.sql
    # The database as an option rather than a USE line, so error line numbers match the script.
    $dbArg = @(); if ($data.db) { $dbArg = @("--database=" + [string]$data.db) }
    $cnf = New-Cnf $conn -Tool $my
    $requestId = [string]$data.requestId
    $p = $null; $entry = $null
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $my; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = $script:RawEnc; $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
        $psi.Arguments = Format-Args (@("--defaults-extra-file=$cnf", "--comments") + $ra + $dbArg)
        $p = New-Object System.Diagnostics.Process; $p.StartInfo = $psi; [void]$p.Start()
        if ($requestId) { $entry = [pscustomobject]@{ Process=$p; Cancelled=$false }; $script:RunningQueries[$requestId] = $entry }
        $et = $p.StandardError.ReadToEndAsync()
        $feed = [NobsXmlRows]::FeedAndClose($p.StandardInput.BaseStream, [Text.Encoding]::UTF8.GetBytes($scriptSql))
        $sets = $null; $readErr = $null
        try { $sets = (New-Object NobsXmlRows $p.StandardOutput).AllSets($maxRows) } catch { $readErr = Get-InnerMessage $_ }
        $p.WaitForExit()
        try { $feed.Wait() } catch { }
        $errTxt = try { $et.Result } catch { '' }
        # XML output leaves out the column names of a result without rows. A statement that is safe
        # to repeat is run again on its own for them (Get-ResultHeaders) - but not when the script
        # switches databases, where on its own it could read a different table; and never a CALL.
        $switchesDb = $scriptSql -match '(?im)(^|;)\s*use\s'
        $reruns = 0
        foreach ($s in @($sets)) {
            if ($null -eq $s -or $s.Rows.Count -gt 0 -or $s.Names.Count -gt 0 -or $switchesDb -or $reruns -ge 20) { continue }
            if (-not (Test-SqlSafeToRerun ([string]$s.Statement))) { continue }
            $reruns++
            $h = Get-ResultHeaders $conn ([string]$s.Statement) ([string]$data.db)
            if ($h) { $s.Names.AddRange([string[]]@($h)) }
        }
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append('[')
        $n = 0
        foreach ($s in @($sets)) {
            if ($null -eq $s) { continue }
            if ($n -gt 0) { [void]$sb.Append(',') }
            $n++
            $stmt = [string]$s.Statement; if ($stmt.Length -gt 120) { $stmt = $stmt.Substring(0, 120) }
            [void]$sb.Append('{"statement":' + $n + ',"sql":' + (J-Str $stmt) + ',"columns":' + (J-Arr @($s.Names)) + ',"rows":' + (J-RowsFast $s.Rows) +
                             ',"rowCount":' + $s.Count + ',"truncated":' + $(if ($s.Count -gt $s.Rows.Count) { 'true' } else { 'false' }) + '}')
        }
        [void]$sb.Append(']')
        $results = $sb.ToString()
        if ($entry -and $entry.Cancelled) { return '{"ok":false,"cancelled":true,"error":"Query cancelled.","results":'+$results+'}' }
        if ($p.ExitCode -ne 0) { return '{"ok":false,"error":'+(J-Str (FirstErr $errTxt))+',"results":'+$results+'}' }
        if ($readErr) { return '{"ok":false,"error":'+(J-Str ("Could not read the result from mysql.exe: " + $readErr))+',"results":'+$results+'}' }
        return '{"ok":true,"results":'+$results+'}'
    } finally {
        if ($requestId) { $null = $script:RunningQueries.TryRemove($requestId, [ref]$null) }
        if ($p) { try { if (-not $p.HasExited) { $p.Kill() } } catch { }; try { $p.Dispose() } catch { } }
        Remove-Item $cnf -Force -ErrorAction SilentlyContinue
    }
}
# Endpoint: apply grid edits (insert/update/delete rows) the user made in the results table.
# NOTE: not currently called by the frontend (row edits are built and sent as plain SQL via
# applyChanges()/`lit()` -> /api/script instead), but the endpoint is still registered, so it
# writes each value for its column's type, as Compare does (see SqlValFor).
function Api-RowOp { param($conn,$data)
    $obj=(SqlId $data.db)+'.'+(SqlId $data.table)
    $binSet=Get-BinaryColumnSet $conn ([string]$data.db) ([string]$data.table)
    if($null -eq $binSet){ return '{"ok":false,"error":"Could not read the column types of that table."}' }
    $op=[string]$data.op
    if($op -eq 'update'){
        $sets=@(); foreach($p in $data.set.PSObject.Properties){ $sets+=(SqlId $p.Name)+'='+(SqlValFor $p.Value ($binSet.Contains([string]$p.Name))) }
        $whs=@();  foreach($p in $data.where.PSObject.Properties){ $whs+=(SqlId $p.Name)+'='+(SqlValFor $p.Value ($binSet.Contains([string]$p.Name))) }
        if($whs.Count -eq 0){ return '{"ok":false,"error":"no key columns; cannot update safely"}' }
        $sql="UPDATE $obj SET "+($sets -join ',')+" WHERE "+($whs -join ' AND ')+" LIMIT 1"
    } elseif($op -eq 'delete'){
        $whs=@(); foreach($p in $data.where.PSObject.Properties){ $whs+=(SqlId $p.Name)+'='+(SqlValFor $p.Value ($binSet.Contains([string]$p.Name))) }
        if($whs.Count -eq 0){ return '{"ok":false,"error":"no key columns; cannot delete safely"}' }
        $sql="DELETE FROM $obj WHERE "+($whs -join ' AND ')+" LIMIT 1"
    } elseif($op -eq 'insert'){
        $cols=@(); $vals=@(); foreach($p in $data.values.PSObject.Properties){ $cols+=(SqlId $p.Name); $vals+=(SqlValFor $p.Value ($binSet.Contains([string]$p.Name))) }
        if($cols.Count -eq 0){ return '{"ok":false,"error":"no values"}' }
        $sql="INSERT INTO $obj ("+($cols -join ',')+") VALUES ("+($vals -join ',')+")"
    } else { return '{"ok":false,"error":"bad op"}' }
    Run-Exec $conn $sql
}
# Endpoint: run a SELECT and return the first page of rows for the results grid, via a streaming
# --quick cursor (Open-QueryCursor) instead of Run-Query2's full-buffer read - the fix for a
# high/missing LIMIT against a large table crashing the whole server. The SQL runs completely
# as-is: no LIMIT/OFFSET rewriting, no detection of whether it already has a LIMIT. If more rows
# remain than fit in one page, the response carries hasMore:true and a cursorId for
# Api-FetchCursorBatch to continue from; otherwise the cursor is already closed server-side.
function Api-Query { param($conn,$sql,$db,$RequestId,$PageSize,[string[]]$ExactText)
    if(-not $sql -or -not ([string]$sql).Trim()){ return '{"ok":false,"error":"Empty query."}' }
    $ps=[int]$PageSize; if($ps -lt 1){ $ps=1000 }
    $sw=[System.Diagnostics.Stopwatch]::StartNew()
    $r=Open-QueryCursor $conn $sql $db $RequestId $ps -ExactText $ExactText
    $sw.Stop()
    if(-not $r.ok){
        if($r.cancelled){ return '{"ok":false,"error":'+(J-Str $r.err)+',"cancelled":true}' }
        return '{"ok":false,"error":'+(J-Str $r.err)+'}'
    }
    if($r.columns.Count -eq 0){ $msg = if($r.note){ $r.note } else { 'Query OK. No result set.' }; return '{"ok":true,"columns":[],"rows":[],"elapsedMs":'+$sw.ElapsedMilliseconds+',"message":'+(J-Str $msg)+'}' }
    $rowsJson = J-RowsFast $r.rows
    $tail = if($r.hasMore){ ',"hasMore":true,"cursorId":"'+$r.cursorId+'"' } else { '' }
    '{"ok":true,"columns":'+(J-Arr $r.columns)+',"rows":'+$rowsJson+',"elapsedMs":'+$sw.ElapsedMilliseconds+$tail+'}'
}
# Endpoint: continue reading from a still-open cursor opened by Api-Query, returning the next
# page. On exhaustion, closes the cursor (process + reader + its RunningQueries registration).
# A cursor killed via Cancel (same $script:RunningQueries entry Api-CancelQuery already kills)
# is reported as a cancellation here rather than a raw read/pipe error.
function Api-FetchCursorBatch { param($data)
    $cid = [string]$data.cursorId
    if (-not $cid) { return '{"ok":false,"error":"no cursorId"}' }
    $cursor = $null
    if (-not $script:OpenCursors.TryGetValue($cid, [ref]$cursor)) {
        return '{"ok":false,"error":"Cursor not found - it may have already finished or been closed."}'
    }
    $ps=[int]$data.pageSize; if($ps -lt 1){ $ps=1000 }
    [System.Threading.Monitor]::Enter($cursor.Lock)
    try {
        $cursor.LastUsed = [DateTime]::UtcNow
        $page = Read-CursorRows $cursor $ps
        if ($cursor.ExactMap) { $page.rows = [NobsXmlRows]::Exact($page.rows, $cursor.ExactMap.keep, $cursor.ExactMap.targets) }
        if (-not $page.hasMore) {
            $null = $script:OpenCursors.TryRemove($cid, [ref]$null)
            $r = Close-QueryCursorProc $cursor
            if ($cursor.Entry.Cancelled) { return '{"ok":false,"error":"Query cancelled.","cancelled":true}' }
            if ($r.exit -ne 0) { return '{"ok":false,"error":'+(J-Str (FirstErr $r.err))+'}' }
            if ($cursor.ParseError) { return '{"ok":false,"error":'+(J-Str $cursor.ParseError)+'}' }
            return '{"ok":true,"columns":'+(J-Arr $cursor.Headers)+',"rows":'+(J-RowsFast $page.rows)+',"hasMore":false}'
        }
        return '{"ok":true,"columns":'+(J-Arr $cursor.Headers)+',"rows":'+(J-RowsFast $page.rows)+',"hasMore":true,"cursorId":"'+$cid+'"}'
    } finally { [System.Threading.Monitor]::Exit($cursor.Lock) }
}
# Endpoint: close a cursor the frontend no longer needs (tab closed, new query replacing it, or
# just tidying up after a fully-consumed one). Always returns ok:true, even for an
# unknown/already-gone cursorId - the frontend calls this defensively at several sites.
function Api-CloseCursor { param($data)
    $cid = [string]$data.cursorId
    if ($cid) {
        $cursor = $null
        if ($script:OpenCursors.TryRemove($cid, [ref]$cursor)) {
            try { if (-not $cursor.Process.HasExited) { $cursor.Process.Kill() } } catch {}
            $null = Close-QueryCursorProc $cursor
        }
    }
    '{"ok":true}'
}
# Endpoint: cancel a running query started with the given requestId (kills its mysql.exe process).
# This is also what kills a streaming cursor's process mid-read - the cursor stays registered
# under its original RequestId in $script:RunningQueries for its whole life (see Open-QueryCursor
# / Close-QueryCursorProc above), so Cancel keeps working across "fetch next" calls too, not just
# the very first page.
function Api-CancelQuery { param($data)
    $rid = [string]$data.requestId
    if (-not $rid) { return '{"ok":false,"error":"no requestId"}' }
    $entry = $null
    if ($script:RunningQueries.TryGetValue($rid, [ref]$entry)) {
        try {
            $entry.Cancelled = $true
            if (-not $entry.Process.HasExited) { $entry.Process.Kill() }
            return '{"ok":true,"message":"Cancel signal sent."}'
        } catch {
            return '{"ok":false,"error":'+(J-Str $_.Exception.Message)+'}'
        }
    }
    return '{"ok":false,"error":"Query not found - it may have already finished."}'
}
# Endpoint: cancel a running export/import job. Kills the in-flight process and
# sets a flag so the job's loop stops starting new tables/files.
function Api-CancelJob { param($data)
    $jid = [string]$data.jobId
    if (-not $jid) { return '{"ok":false,"error":"no jobId"}' }
    $job = $null
    if ($script:RunningJobs.TryGetValue($jid, [ref]$job)) {
        $job.Cancelled = $true
        try { if ($job.CurrentProcess -and -not $job.CurrentProcess.HasExited) { $job.CurrentProcess.Kill() } } catch {}
        return '{"ok":true,"message":"Cancel requested."}'
    }
    return '{"ok":false,"error":"Job not found - it may have already finished."}'
}
# Endpoint: export data (mysqldump for whole schemas, or CSV / INSERT statements).
# mysqldump has no flag for this (unlike HeidiSQL's own exporter) - DEFINER=`user`@`host`
# hardcodes whichever MySQL account happened to create each view/trigger/procedure/event into
# the dump. Restoring on a server where that exact account doesn't exist (a different host, a
# managed DB service, a teammate's machine, CI) then fails or warns on every one of those
# objects. Strip it from the resulting file after a successful dump, leaving the surrounding
# `SQL SECURITY DEFINER/INVOKER` clause and versioned comment wrappers intact - the object just
# falls back to CURRENT_USER at creation time, which restores identically on the original server too.
function Strip-DefinerFile { param($file)
    try {
        $content = [IO.File]::ReadAllText($file)
        $stripped = [regex]::Replace($content, 'DEFINER=`(?:[^`]|``)*`@`(?:[^`]|``)*`\s*', '')
        [IO.File]::WriteAllText($file, $stripped)
    } catch {}
}
# Whether a dump binary is MariaDB's, cached against its path like Test-ClientIsMariaDB.
function Test-DumpIsMariaDB { param([string]$Path)
    if ($Path -and $Path -ne [string]$script:MysqldumpPath) { return Test-ToolIsMariaDB $Path }
    $path = [string]$script:MysqldumpPath
    if ($script:DumpIsMariaDB -and $script:DumpIsMariaDB.Path -eq $path) { return $script:DumpIsMariaDB.Maria }
    $maria = $true
    if ($path -and (Test-Path $path)) { try { $maria = ((& $path --version 2>&1 | Out-String) -match 'MariaDB') } catch { } }
    $script:DumpIsMariaDB = @{ Path = $path; Maria = $maria }
    return $maria
}
# Which tools export and import use for a server. MariaDB's and MySQL's are not interchangeable
# against the other's server: MariaDB's mysqldump writes values into a MySQL generated column, so
# the dump does not restore, and only MySQL's client can check a CA without the host name. The
# configured (or downloaded) pair stays the default; a MySQL server gets MySQL's own tools when
# there are any - set in Settings (mysql_bin_mysql / mysqldump_bin_mysql), or found in a MySQL
# Server installation. The same rule as the Tauri edition's resolve_tool_for.
#
# The bin folders of MySQL Server installations under $Bases, newest version first.
function Get-MysqlServerBinDirs { param([string[]]$Bases)
    $found = foreach ($b in @($Bases)) {
        if (-not $b) { continue }
        $m = Join-Path $b 'MySQL'
        if (-not (Test-Path -LiteralPath $m)) { continue }
        foreach ($d in (Get-ChildItem -LiteralPath $m -Directory -ErrorAction SilentlyContinue)) {
            if ($d.Name -notmatch '^(?i)MySQL Server\s*(.*)$') { continue }
            $v = [version]'0.0'; [void][version]::TryParse(($Matches[1] -replace '[^\d\.]', ''), [ref]$v)
            [pscustomobject]@{ Ver = $v; Dir = (Join-Path $d.FullName 'bin') }
        }
    }
    return @($found | Sort-Object -Property @{ Expression = 'Ver'; Descending = $true }, Dir | ForEach-Object { $_.Dir })
}
# The tool to use for a MySQL server, with where it came from, or $null for "the default pair".
# Asked on every query to a MySQL server, so the answer is kept until the config file or a MySQL
# folder under Program Files changes.
function Get-MysqlFlavorTool { param([string]$Base)
    $bases = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ }
    $stamp = "$Base"
    foreach ($f in @([string]$script:CfgFile) + @($bases | ForEach-Object { Join-Path $_ 'MySQL' })) {
        try { $stamp += '|' + (Get-Item -LiteralPath $f -ErrorAction Stop).LastWriteTimeUtc.Ticks } catch { $stamp += '|-' }
    }
    if (-not ($script:FlavorToolCache -is [hashtable])) { $script:FlavorToolCache = @{} }
    if ($script:FlavorToolCache.ContainsKey($stamp)) { return $script:FlavorToolCache[$stamp] }
    $res = $null
    $cfg = Load-Cfg
    $key = "$($Base)_bin_mysql"
    if ($cfg -and $cfg.$key -and (Test-Path -LiteralPath ([string]$cfg.$key))) { $res = @{ Path = [string]$cfg.$key; Source = 'Saved configuration' } }
    if (-not $res) {
        foreach ($d in (Get-MysqlServerBinDirs $bases)) {
            $f = Join-Path $d "$Base.exe"
            if (Test-Path -LiteralPath $f) { $res = @{ Path = $f; Source = "Found in $(Split-Path -Parent $d)" }; break }
        }
    }
    $script:FlavorToolCache[$stamp] = $res
    return $res
}
# $true for MariaDB, $false for MySQL, $null if the server could not be asked. Remembered per
# host and port in a dictionary every runspace shares, so it costs one query per server, not one
# per request; connecting asks again.
function Get-ServerFlavorKey { param($conn) '{0}:{1}' -f ([string]$conn.host).Trim().ToLower(), ([string]$conn.port).Trim() }
function Get-ServerIsMariaDB { param($conn)
    if (-not $conn -or $null -eq $script:ServerFlavor) { return $null }
    $key = Get-ServerFlavorKey $conn
    $known = $null
    if ($script:ServerFlavor.TryGetValue($key, [ref]$known)) { return $known }
    $v = Get-ServerVersion $conn
    if ($null -eq $v.version) { return $null }
    $maria = [bool]($v.version -match 'MariaDB')
    $script:ServerFlavor[$key] = $maria
    return $maria
}
# SELECT VERSION() with the default client, and then with MySQL's when that one cannot connect -
# only MySQL's client can verify a MySQL server's CA without its host name, so for such a
# connection it is the only way to find out what the server is. Returns version (or $null) and err.
function Get-ServerVersion { param($conn)
    $cands = @([string]$script:MysqlPath)
    $myTool = Get-MysqlFlavorTool 'mysql'
    if ($myTool -and $myTool.Path -ne $cands[0]) { $cands += $myTool.Path }
    $firstErr = $null
    foreach ($exe in $cands) {
        if (-not $exe -or -not (Test-Path -LiteralPath $exe)) { continue }
        $cnf = New-Cnf $conn -Tool $exe
        try {
            $r = Run-Proc $exe @("--defaults-extra-file=$cnf","-N","-e","SELECT VERSION()")
            if ($r.exit -eq 0) { return @{ version = ([string]$r.out).Trim(); err = $null } }
            if ($null -eq $firstErr) { $firstErr = $r.err }
        } finally { Remove-Item $cnf -Force -ErrorAction SilentlyContinue }
    }
    return @{ version = $null; err = $firstErr }
}
# The mysql.exe for a connection: MySQL's own for a MySQL server when there is one, the default
# client otherwise. Every place that runs mysql.exe for a connection asks this.
function Get-Mysql { param($conn)
    if (-not $conn) { return [string]$script:MysqlPath }
    return Get-ToolFor $conn 'mysql'
}
# Only a server known to be MySQL switches; MariaDB, or a server that could not be asked, keeps
# the default pair - which is also the fallback when there are no MySQL tools.
function Select-Tool { param($ServerIsMariaDB, $MysqlTool, $Default)
    if ($ServerIsMariaDB -is [bool] -and -not $ServerIsMariaDB -and $MysqlTool) { return $MysqlTool }
    return $Default
}
function Get-ToolFor { param($conn, [string]$Base)
    $default = if ($Base -eq 'mysqldump') { [string]$script:MysqldumpPath } else { [string]$script:MysqlPath }
    $maria = Get-ServerIsMariaDB $conn
    $my = $null
    if ($maria -is [bool] -and -not $maria) { $t = Get-MysqlFlavorTool $Base; if ($t) { $my = $t.Path } }
    return Select-Tool $maria $my $default
}

# Tables with a generated column in the given databases - only when the dump tool is MariaDB's and
# the server is MySQL (MariaDB's tool understands MariaDB's own generated columns). Empty when the
# check cannot be made, so the export goes ahead as before.
function Get-MySqlGeneratedTables { param($conn, $dbs, $excl, [string]$Dump)
    if (-not (Test-DumpIsMariaDB $Dump)) { return @() }
    $v = Run-Query2 $conn 'SELECT VERSION()' $null $null
    if (-not $v.ok -or ([string]$v.rows[0][0]) -match 'MariaDB') { return @() }
    $list = (@($dbs) | ForEach-Object { SqlLit $_ }) -join ','
    if (-not $list) { return @() }
    $r = Run-Query2 $conn ("SELECT DISTINCT TABLE_SCHEMA, TABLE_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA IN ($list) AND GENERATION_EXPRESSION IS NOT NULL AND GENERATION_EXPRESSION <> '' ORDER BY 1,2") $null $null
    if (-not $r.ok) { return @() }
    return @($r.rows | ForEach-Object { "$($_[0]).$($_[1])" } | Where-Object { -not $excl.ContainsKey($_) })
}
function Api-Export { param($conn,$data)
    $dump = Get-ToolFor $conn 'mysqldump'
    if(-not $dump -or -not (Test-Path $dump)){ return '{"ok":false,"error":"mysqldump.exe not found. Open Settings in the app to select it, or to download the MariaDB client tools."}' }
    $dbs=@($data.dbs); if($dbs.Count -eq 0){ return '{"ok":false,"error":"No databases selected."}' }
    $jobId=[string]$data.jobId
    $job=[pscustomobject]@{ Cancelled=$false; CurrentProcess=$null }
    if($jobId){ $script:RunningJobs[$jobId]=$job }
    $folder=[string]$data.folder
    if(-not (Test-Path $folder)){ try { New-Item -ItemType Directory -Path $folder -Force|Out-Null } catch { return '{"ok":false,"error":'+(J-Str ("Cannot create folder: "+$_.Exception.Message))+'}' } }
    $o=$data.options; $cnf=New-Cnf $conn -Tool $dump; $log=New-Object System.Collections.ArrayList
    $excl=@{}; if($data.excludes){ foreach($e in @($data.excludes)){ $excl[[string]$e]=$true } }
    # mode: 'table' (one file per table, the default), 'db' (one file per database), 'single' (one combined file)
    $mode=[string]$data.mode; if(-not $mode){ if($data.single){$mode='single'}else{$mode='table'} }
    try {
        # MariaDB's dump tool does not recognise a MySQL generated column as generated, so it writes
        # a value for it into every INSERT - and MySQL refuses exactly that on restore ("The value
        # specified for generated column ... is not allowed"). MySQL's own mysqldump leaves those
        # columns out. Measured on MySQL 8.0.46: the export reported OK and the file could not be
        # restored. A backup that looks fine and is not is worse than none, so refuse up front.
        $genTables = Get-MySqlGeneratedTables $conn $dbs $excl $dump
        if ($genTables.Count -gt 0) {
            return '{"ok":false,"error":'+(J-Str ("Not exported: $($genTables.Count) table(s) on this MySQL server have generated columns ($($genTables -join ', ')). The MariaDB dump tool writes values into those columns, which MySQL refuses when the file is restored - the dump would not restore. In Settings, point mysqldump at MySQL's own mysqldump.exe (for example C:\Program Files\MySQL\MySQL Server 8.0\bin\mysqldump.exe), or exclude those tables."))+'}'
        }
        $stamp = if($data.stamp){ '_'+(Get-Date -Format 'yyyyMMdd_HHmmss') } else { '' }
        # Flags shared by EVERY mysqldump call in this run (per-table-safe: no database-level flags here).
        $common=@("--defaults-extra-file=$cnf","--default-character-set=$($o.charset)")
        if($o.singletx){$common+='--single-transaction'}; if($o.quick){$common+='--quick'}; if($o.hexblob){$common+='--hex-blob'}
        if($o.triggers){$common+='--triggers'}else{$common+='--skip-triggers'}
        if($o.diskeys){$common+='--disable-keys'}; if($o.notablespaces){$common+='--no-tablespaces'}; if($o.colstats){$common+='--column-statistics=0'}
        if($o.compress){$common+='--compress'}; if($o.gtid){$common+='--set-gtid-purged=OFF'}
        if($o.complete){$common+='--complete-insert'}; if($o.extinsert){$common+='--extended-insert'}else{$common+='--skip-extended-insert'}
        if($o.tzutc){$common+='--tz-utc'}else{$common+='--skip-tz-utc'}
        if($o.maxpacket){ $common+=("--max-allowed-packet="+[string]$o.maxpacket) }

        # Only meaningful in 'single' mode - db/table mode each produce one file per object, so
        # a single manual name has nowhere to go. A trailing .sql the user typed themselves is
        # stripped so it doesn't end up doubled ("backup.sql" + our own ".sql" suffix).
        $customName = ([string]$data.filename).Trim()
        $singleBase = if(-not $customName){ 'all_selected' } else { ($customName -replace '\.sql$','' -replace '[^\w\.\-]','_') }

        if($mode -eq 'single'){
            # One combined file for all selected databases.
            $file=Join-Path $folder ("$singleBase$stamp.sql")
            $a=@()+$common+@('--databases')
            if($o.routines){$a+='--routines'}; if($o.events){$a+='--events'}
            if($o.adddropdb){$a+='--add-drop-database'}; if($o.adddroptb){$a+='--add-drop-table'}else{$a+='--skip-add-drop-table'}
            if(-not $o.createdb){$a+='--no-create-db'}
            foreach($k in $excl.Keys){ $a+=("--ignore-table="+$k) }
            $a+=$dbs; $a+="--result-file=$file"
            $r=Run-Proc $dump $a $null $jobId
            if($job.Cancelled){
                if(Test-Path $file){ try{ Rename-Item $file ($file+'.partial') -Force }catch{} }
                [void]$log.Add("CANCELLED (partial file kept as $([IO.Path]::GetFileName($file)).partial)")
            }
            elseif($r.exit -eq 0 -and (Test-Path $file)){ if($o.nodefiner){ Strip-DefinerFile $file }; $mb=[math]::Round((Get-Item $file).Length/1MB,2); [void]$log.Add("OK  $file ($mb MB)") } else { [void]$log.Add("FAILED ($($r.exit)) $singleBase : "+(Friendly-DumpErr (FirstErr $r.err))) }
        }
        elseif($mode -eq 'db'){
            # One file per database (includes routines/events/create-db as chosen).
            foreach($d in $dbs){
                if($job.Cancelled){ [void]$log.Add("CANCELLED (remaining databases skipped)"); break }
                $safe=($d -replace '[^\w\.\-]','_'); $file=Join-Path $folder "$safe$stamp.sql"
                $a=@()+$common+@('--databases')
                if($o.routines){$a+='--routines'}; if($o.events){$a+='--events'}
                if($o.adddropdb){$a+='--add-drop-database'}; if($o.adddroptb){$a+='--add-drop-table'}else{$a+='--skip-add-drop-table'}
                if(-not $o.createdb){$a+='--no-create-db'}
                foreach($k in $excl.Keys){ if($k -like ($d+'.*')){ $a+=("--ignore-table="+$k) } }
                $a+=$d; $a+="--result-file=$file"
                $r=Run-Proc $dump $a $null $jobId
                if($job.Cancelled){
                    if(Test-Path $file){ try{ Rename-Item $file ($file+'.partial') -Force }catch{} }
                    [void]$log.Add("CANCELLED (partial file kept as $([IO.Path]::GetFileName($file)).partial)")
                    break
                }
                if($r.exit -eq 0 -and (Test-Path $file)){ if($o.nodefiner){ Strip-DefinerFile $file }; $mb=[math]::Round((Get-Item $file).Length/1MB,2); [void]$log.Add("OK  $file ($mb MB)") } else { [void]$log.Add("FAILED ($($r.exit)) $d : "+(Friendly-DumpErr (FirstErr $r.err))) }
            }
        }
        else {
            # PER TABLE (default): every table/view to its own file, like Workbench's Dump Project
            # Folder - cut from one dump of the database, so all of them come from the same moment
            # (see NobsDumpDb.SplitByTable).
            Initialize-DumpDb
            :dbloop foreach($d in $dbs){
                if($job.Cancelled){ [void]$log.Add("CANCELLED (remaining databases skipped)"); break }
                $q=Run-Query2 $conn ("SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA="+(SqlLit $d)+" ORDER BY TABLE_NAME") $null
                if(-not $q.ok){ [void]$log.Add("FAILED (list tables) $d : "+$q.err); continue }
                $tabs=@($q.rows | ForEach-Object { [string]$_[0] })
                $dsafe=($d -replace '[^\w\.\-]','_')
                if($tabs.Count -eq 0){ [void]$log.Add("(no tables) $d") }
                $wanted = @(); $skipped = @()
                foreach($t in $tabs){ if($excl.ContainsKey("$d.$t")){ [void]$log.Add("(excluded) $d.$t"); $skipped += $t } else { $wanted += $t } }
                if($wanted.Count){
                    if($job.Cancelled){ [void]$log.Add("CANCELLED (remaining tables skipped)"); break dbloop }
                    $whole = Join-Path $folder ".$dsafe$stamp.whole.sql.tmp"
                    $a=@()+$common
                    if($o.adddroptb){$a+='--add-drop-table'}else{$a+='--skip-add-drop-table'}
                    # The excluded tables are left out; when they are most of the database, the
                    # wanted ones are named instead, which keeps the command line short.
                    if($skipped.Count -gt $wanted.Count){ $a+=$d; $a+=$wanted } else { foreach($t in $skipped){ $a+=("--ignore-table=$d.$t") }; $a+=$d }
                    $a+="--result-file=$whole"
                    $r=Run-Proc $dump $a $null $jobId
                    try {
                        if($job.Cancelled){ [void]$log.Add("CANCELLED $d"); break dbloop }
                        if($r.exit -eq 0 -and (Test-Path $whole)){
                            if($o.nodefiner){ Strip-DefinerFile $whole }
                            $files = $null
                            try { $files = [NobsDumpDb]::SplitByTable($whole, $folder, "$dsafe.", "$stamp.sql") }
                            catch { [void]$log.Add("FAILED $d : could not split the dump into tables: " + (Get-InnerMessage $_)) }
                            if($null -ne $files){
                                $pathOf = New-Object 'System.Collections.Generic.Dictionary[string,string]'
                                foreach($f in $files){ $pathOf[$f[0]] = $f[1] }
                                foreach($t in $wanted){
                                    if($pathOf.ContainsKey($t)){ $p=$pathOf[$t]; $mb=[math]::Round((Get-Item -LiteralPath $p).Length/1MB,2); [void]$log.Add("OK  $p ($mb MB)") }
                                    else { [void]$log.Add("FAILED $d.$t : not in the dump") }
                                }
                            }
                        } else { [void]$log.Add("FAILED ($($r.exit)) $d : "+(Friendly-DumpErr (FirstErr $r.err))) }
                    } finally { Remove-Item -LiteralPath $whole -Force -ErrorAction SilentlyContinue }
                }
                if($job.Cancelled){ break }
                # Routines + events are database-level, so they go in one extra file per database.
                if($o.routines -or $o.events){
                    $file=Join-Path $folder "$dsafe.routines_events$stamp.sql"
                    $a=@()+$common+@('--no-create-info','--no-data','--no-create-db','--skip-triggers')
                    if($o.routines){$a+='--routines'}; if($o.events){$a+='--events'}
                    $a+=$d; $a+="--result-file=$file"
                    $r=Run-Proc $dump $a $null $jobId
                    # Cancelling kills mysqldump, which comes back as exit -1 with nothing on
                    # stderr. Without this check that fell through to the generic FAILED branch
                    # below and logged "FAILED (-1) <db> routines/events : " - a failure with no
                    # reason given, for something the user themselves just cancelled. Every other
                    # step in this export already distinguishes the two; this one did not.
                    if($job.Cancelled){
                        if(Test-Path $file){ try{ Rename-Item $file ($file+'.partial') -Force }catch{} }
                        [void]$log.Add("CANCELLED (routines/events for $d stopped)")
                    }
                    elseif($r.exit -eq 0 -and (Test-Path $file)){ if($o.nodefiner){ Strip-DefinerFile $file }; $mb=[math]::Round((Get-Item $file).Length/1MB,2); [void]$log.Add("OK  $file ($mb MB, routines/events)") }
                    else { [void]$log.Add("FAILED ($($r.exit)) $d routines/events : "+(Friendly-DumpErr (FirstErr $r.err))) }
                }
            }
        }
        # A cancel that arrived after the last step had finished still answers the click.
        if($job.Cancelled -and -not (@($log) -match '^CANCELLED')){ [void]$log.Add('CANCELLED (after the last step had finished - the files listed above are complete)') }
        if($job.Cancelled){ '{"ok":true,"cancelled":true,"log":'+(J-Arr $log)+'}' } else { '{"ok":true,"log":'+(J-Arr $log)+'}' }
    } finally { Remove-Item $cnf -Force -ErrorAction SilentlyContinue; if($jobId){ $null=$script:RunningJobs.TryRemove($jobId,[ref]$null) } }
}
# Endpoint: import one or more .sql dump files.
# ---------------------------------------------------------------------------
# Restoring a dump into a database of your choosing
# ---------------------------------------------------------------------------
# A dump made per database - the export dialog's default - opens with its own
#
#   /*!40000 DROP DATABASE IF EXISTS `shop`*/;
#   CREATE DATABASE /*!32312 IF NOT EXISTS*/ `shop` ...;
#   USE `shop`;
#
# and "Target database" was only handed to mysql.exe as its default database, which the file's own
# USE overrides on line three. So "import shop.sql into shop_copy" dropped and rebuilt `shop`
# itself and left `shop_copy` empty - and when the file then failed partway (MySQL rejecting a
# generated column's value, measured on 8.0.46), `shop` was left with the tables up to that point
# and nothing after them.
#
# When a target is chosen those statements now name the target instead. Only whole statements of
# those three kinds at the start of a line are touched, and only their database identifier; data
# rows never start a line with them, because mysqldump escapes newlines inside values. A file that
# names more than one database is refused rather than squashed into one.
#
# Byte-level and streaming: a dump can be many GB, may hold bytes that are not UTF-8, and a
# PowerShell loop per line would take minutes. Compiled once per process; C# 5 so Windows
# PowerShell 5.1 can build it too. The same logic lives in the Tauri edition (dump_db_ident).
$script:DumpDbSource = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
// mysql --batch ends a row with LF alone and escapes tab, newline, NUL and backslash inside
// values - but NOT carriage return. .NET's ReadLine() also ends a line at CR, so a value holding a
// CR split its row in two and shifted every column after it (measured: 'a' LF 'b' CR 'c' came back
// as two rows). This ends a line at LF and nowhere else.
public static class NobsLf {
    public static string ReadLine(TextReader r) {
        var sb = new StringBuilder(); int c; bool any = false;
        while ((c = r.Read()) >= 0) { any = true; if (c == 10) return sb.ToString(); sb.Append((char)c); }
        return any ? sb.ToString() : null;
    }
}
// Rows out of mysql --xml --binary-as-hex, read from a Latin-1 reader so each char is one byte.
//
// --xml is the only output mode of the command-line client that tells NULL apart from the text
// 'NULL': --batch prints both as NULL, and no option changes that. So a 'NULL' string copied or
// compared through this app became a real NULL. In XML a NULL is <field xsi:nil="true" />.
//
// What XML costs, and how each is dealt with:
//  - the client writes a NUL byte as a space. --binary-as-hex writes binary and BIT columns as
//    0x.. instead, so only a NUL inside a text column is lost (it reads as a space).
//  - MySQL's own client on Windows writes every LF as CRLF, value bytes included. It does so for
//    the XML declaration as well, which is how it is detected and undone here.
//  - a result with no rows carries no column names; the caller asks for those separately.
//  - several statements give several result sets; only the first is returned, and the rest is
//    read and dropped so the process never blocks on a full pipe.
public sealed class NobsXmlRows {
    static readonly Encoding Latin1 = Encoding.GetEncoding(28591);
    static readonly Encoding Strict = new UTF8Encoding(false, true);
    readonly TextReader r;
    readonly char[] buf = new char[1 << 16];
    int pos, len;
    bool eolKnown, crlf, firstClosed, pendingSet;
    int sets;
    string[] pending;
    public readonly List<string> Names = new List<string>();
    public bool HasResultSet { get { return sets > 0; } }
    public bool More;
    public NobsXmlRows(TextReader r) { this.r = r; }

    int Peek() {
        if (pos >= len) {
            // A cursor whose process was killed ends here, the same as a finished one.
            try { len = r.Read(buf, 0, buf.Length); } catch (IOException) { len = 0; } catch (ObjectDisposedException) { len = 0; }
            pos = 0;
            if (len <= 0) { len = 0; return -1; }
        }
        return buf[pos];
    }
    int Read() { int c = Peek(); if (c >= 0) pos++; return c; }

    string TagName() {
        var sb = new StringBuilder();
        int c = Peek();
        if (c == '/' || c == '?') sb.Append((char)Read());
        while (true) {
            c = Peek();
            if (c < 0 || c == '>' || c == '/' || c == ' ' || c == '\t' || c == '\r' || c == '\n') break;
            sb.Append((char)Read());
        }
        return sb.ToString();
    }
    // Reads the rest of a tag. Attribute values never hold a raw '>' - the client escapes it.
    bool TagRest(StringBuilder attrs) {
        int prev = 0, c;
        while ((c = Read()) >= 0 && c != '>') { if (attrs != null) attrs.Append((char)c); prev = c; }
        return prev == '/';
    }
    void AppendChar(StringBuilder sb, int c) {
        if (c < 256) { sb.Append((char)c); return; }
        foreach (byte b in Encoding.UTF8.GetBytes(char.ConvertFromUtf32(c))) sb.Append((char)b);
    }
    void Entity(StringBuilder sb, Func<int> next) {
        var e = new StringBuilder();
        int c;
        while (e.Length < 12 && (c = next()) >= 0) { if (c == ';') break; e.Append((char)c); }
        string s = e.ToString();
        if (s == "lt") sb.Append('<');
        else if (s == "gt") sb.Append('>');
        else if (s == "amp") sb.Append('&');
        else if (s == "quot") sb.Append('"');
        else if (s == "apos") sb.Append('\'');
        else if (s.StartsWith("#x") && s.Length > 2) AppendChar(sb, Convert.ToInt32(s.Substring(2), 16));
        else if (s.StartsWith("#") && s.Length > 1) AppendChar(sb, int.Parse(s.Substring(1)));
        else throw new InvalidDataException("Unexpected entity &" + s + "; in mysql --xml output.");
    }
    string Text() {
        var sb = new StringBuilder();
        while (true) {
            int c = Peek();
            if (c < 0 || c == '<') break;
            pos++;
            if (c == '&') { Entity(sb, Read); continue; }
            if (c == '\r' && crlf && Peek() == '\n') continue;
            sb.Append((char)c);
        }
        return sb.ToString();
    }
    string AttrValue(string attrs, string name, out bool found) {
        found = false;
        int i = 0;
        while (i < attrs.Length) {
            while (i < attrs.Length && (attrs[i] == ' ' || attrs[i] == '\t' || attrs[i] == '\r' || attrs[i] == '\n' || attrs[i] == '/')) i++;
            int eq = attrs.IndexOf('=', i);
            if (eq < 0 || eq + 1 >= attrs.Length || attrs[eq + 1] != '"') return null;
            string key = attrs.Substring(i, eq - i).Trim();
            int end = attrs.IndexOf('"', eq + 2);
            if (end < 0) return null;
            if (key == name) {
                found = true;
                var sb = new StringBuilder();
                int j = eq + 2;
                Func<int> next = () => j < end ? attrs[j++] : -1;
                while (j < end) {
                    char c = attrs[j++];
                    if (c == '&') { Entity(sb, next); continue; }
                    if (c == '\r' && crlf && j < end && attrs[j] == '\n') continue;
                    sb.Append(c);
                }
                return sb.ToString();
            }
            i = end + 1;
        }
        return null;
    }
    // Text as text; anything that is not valid UTF-8 as 0x.. hex, as the rest of the app shows it.
    public static string Cell(string raw) {
        if (raw == null) return null;
        bool ascii = true;
        for (int i = 0; i < raw.Length; i++) if (raw[i] > 127) { ascii = false; break; }
        if (ascii) return raw;
        byte[] b = Latin1.GetBytes(raw);
        try { return Strict.GetString(b); }
        catch (DecoderFallbackException) { return "0x" + BitConverter.ToString(b).Replace("-", ""); }
    }
    static string Name(string raw) {
        try { return Strict.GetString(Latin1.GetBytes(raw)); } catch (DecoderFallbackException) { return raw; }
    }
    string[] Row(bool keep) {
        var vals = keep ? new List<string>() : null;
        bool names = keep && Names.Count == 0;
        while (true) {
            int c = Read();
            if (c < 0) throw new InvalidDataException("mysql --xml output ended inside a row.");
            if (c != '<') continue;
            string tag = TagName();
            if (tag == "/row") { TagRest(null); break; }
            if (tag != "field") { TagRest(null); continue; }
            var attrs = new StringBuilder();
            bool closed = TagRest(attrs);
            string a = attrs.ToString();
            bool found, nil;
            string name = AttrValue(a, "name", out found);
            string nilv = AttrValue(a, "xsi:nil", out nil);
            string val = null;
            if (!closed) {
                val = Text();
                if (Read() != '<' || TagName() != "/field") throw new InvalidDataException("Unexpected markup inside a field in mysql --xml output.");
                TagRest(null);
            } else if (!(nil && nilv == "true")) val = "";
            if (nil && nilv == "true") val = null;
            if (keep) {
                vals.Add(Cell(val));
                if (names) Names.Add(Name(name ?? ""));
            }
        }
        return keep ? vals.ToArray() : null;
    }
    string[] NextCore() {
        while (true) {
            int c = Read();
            if (c < 0) return null;
            if (c != '<') continue;
            string tag = TagName();
            if (tag == "?xml") {
                TagRest(null);
                if (!eolKnown) { eolKnown = true; crlf = Peek() == '\r'; }
            } else if (tag == "resultset") {
                sets++;
                if (TagRest(null) && sets == 1) firstClosed = true;
            } else if (tag == "/resultset") {
                TagRest(null);
                if (sets == 1) firstClosed = true;
            } else if (tag == "row") {
                TagRest(null);
                bool keep = sets == 1 && !firstClosed;
                string[] row = Row(keep);
                if (keep) return row;
            } else TagRest(null);
        }
    }
    public string[] Next() {
        if (pendingSet) { pendingSet = false; var p = pending; pending = null; return p; }
        return NextCore();
    }
    // Up to n rows; More says whether another one follows (it is held back for the next call).
    public List<string[]> Page(int n) {
        var list = new List<string[]>();
        while (list.Count < n) {
            var row = Next();
            if (row == null) { More = false; return list; }
            list.Add(row);
        }
        var peek = Next();
        More = peek != null;
        if (More) { pending = peek; pendingSet = true; }
        return list;
    }
    public List<string[]> All() { return Page(int.MaxValue); }
    // Every result set in the output - a script's SELECTs, a procedure's results - each with at
    // most maxRows rows kept and all of them counted. The column names of a result without rows
    // are not in the output, so such a result has none.
    public List<NobsResultSet> AllSets(int maxRows) {
        var list = new List<NobsResultSet>();
        NobsResultSet cur = null;
        while (true) {
            int c = Read();
            if (c < 0) break;
            if (c != '<') continue;
            string tag = TagName();
            if (tag == "?xml") {
                TagRest(null);
                if (!eolKnown) { eolKnown = true; crlf = Peek() == '\r'; }
            } else if (tag == "resultset") {
                var attrs = new StringBuilder();
                bool closed = TagRest(attrs);
                bool found;
                cur = new NobsResultSet { Statement = AttrValue(attrs.ToString(), "statement", out found) };
                list.Add(cur);
                Names.Clear();
                if (closed) cur = null;
            } else if (tag == "/resultset") {
                TagRest(null);
                cur = null;
            } else if (tag == "row") {
                TagRest(null);
                if (cur == null) { Row(false); continue; }
                bool keep = cur.Rows.Count < maxRows;
                string[] row = Row(keep);
                if (keep) { cur.Rows.Add(row); if (cur.Names.Count == 0) cur.Names.AddRange(Names); }
                cur.Count++;
            } else TagRest(null);
        }
        return list;
    }
    // Writes data to a process's input and closes it, without waiting: the process writes its
    // results meanwhile, and they are read as they come.
    public static System.Threading.Tasks.Task FeedAndClose(Stream s, byte[] data) {
        return System.Threading.Tasks.Task.Run(() => {
            try { s.Write(data, 0, data.Length); s.Flush(); } catch (IOException) { } catch (ObjectDisposedException) { }
            finally { try { s.Close(); } catch (IOException) { } }
        });
    }
    // A grid query that also asked for each text column as hex wherever it holds a NUL (see
    // Get-ExactTextMap): drops those hex columns and puts each exact value back in place of the
    // one in which XML turned the NUL into a space. targets[i] lists the shown columns named after
    // text column i. A value is replaced only where it is that value with its NULs shown as spaces,
    // so an expression that merely shares the column's name keeps its own value.
    public static List<string[]> Exact(List<string[]> rows, int keep, int[][] targets) {
        var result = new List<string[]>(rows.Count);
        foreach (var row in rows) {
            var o = new string[keep];
            Array.Copy(row, o, Math.Min(keep, row.Length));
            for (int i = 0; i < targets.Length && keep + i < row.Length; i++) {
                string hex = row[keep + i];
                if (hex == null) continue;
                var b = new byte[hex.Length / 2];
                for (int k = 0; k < b.Length; k++) b[k] = Convert.ToByte(hex.Substring(k * 2, 2), 16);
                string exact = Encoding.UTF8.GetString(b);
                string shown = exact.Replace('\0', ' ');
                foreach (int j in targets[i]) if (o[j] == shown) o[j] = exact;
            }
            result.Add(o);
        }
        return result;
    }
}
public sealed class NobsResultSet {
    public string Statement;
    public readonly List<string> Names = new List<string>();
    public readonly List<string[]> Rows = new List<string[]>();
    public long Count;
}
public static class NobsDumpDb {
    static bool Kw(byte[] l, int n, ref int i, string w) {
        if (i + w.Length > n) return false;
        for (int k = 0; k < w.Length; k++) { byte c = l[i + k]; if (c >= 97 && c <= 122) c = (byte)(c - 32); if (c != (byte)w[k]) return false; }
        int e = i + w.Length;
        if (e < n) { byte c = l[e]; if ((c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95) return false; }
        i = e; return true;
    }
    static void Ws(byte[] l, int n, ref int i) { while (i < n && (l[i] == 32 || l[i] == 9)) i++; }
    // Start, end and unescaped name of the database identifier in a USE / CREATE DATABASE /
    // DROP DATABASE line; start is -1 for any other line.
    public static int Ident(byte[] l, int n, out int end, out string name) {
        end = -1; name = null;
        int i = 0; Ws(l, n, ref i);
        if (i + 3 <= n && l[i] == 47 && l[i + 1] == 42 && l[i + 2] == 33) {          // /*!40000 DROP ...
            int j = i + 3; while (j < n && l[j] >= 48 && l[j] <= 57) j++;
            Ws(l, n, ref j); int k = j;
            if (!Kw(l, n, ref k, "DROP")) return -1;
            i = j;
        }
        if (Kw(l, n, ref i, "USE")) { Ws(l, n, ref i); }
        else if (Kw(l, n, ref i, "CREATE")) {
            Ws(l, n, ref i);
            if (!(Kw(l, n, ref i, "DATABASE") || Kw(l, n, ref i, "SCHEMA"))) return -1;
            Ws(l, n, ref i);
            if (i + 3 <= n && l[i] == 47 && l[i + 1] == 42 && l[i + 2] == 33) {
                int c = i; while (c + 1 < n && !(l[c] == 42 && l[c + 1] == 47)) c++;
                if (c + 1 < n) i = c + 2;
            }
            Ws(l, n, ref i);
            if (Kw(l, n, ref i, "IF")) { Ws(l, n, ref i); if (!Kw(l, n, ref i, "NOT")) return -1; Ws(l, n, ref i); if (!Kw(l, n, ref i, "EXISTS")) return -1; Ws(l, n, ref i); }
        }
        else if (Kw(l, n, ref i, "DROP")) {
            Ws(l, n, ref i);
            if (!(Kw(l, n, ref i, "DATABASE") || Kw(l, n, ref i, "SCHEMA"))) return -1;
            Ws(l, n, ref i);
            if (Kw(l, n, ref i, "IF")) { Ws(l, n, ref i); if (!Kw(l, n, ref i, "EXISTS")) return -1; Ws(l, n, ref i); }
        }
        else return -1;
        if (i >= n) return -1;
        int start = i;
        var ms = new MemoryStream();
        if (l[i] == 96) {
            i++;
            while (true) {
                if (i >= n) return -1;
                if (l[i] == 96) { if (i + 1 < n && l[i + 1] == 96) { ms.WriteByte(96); i += 2; continue; } i++; break; }
                ms.WriteByte(l[i]); i++;
            }
        } else {
            while (i < n && ((l[i] >= 48 && l[i] <= 57) || (l[i] >= 65 && l[i] <= 90) || (l[i] >= 97 && l[i] <= 122) || l[i] == 95 || l[i] == 36)) { ms.WriteByte(l[i]); i++; }
            if (i == start) return -1;
        }
        end = i; name = Encoding.UTF8.GetString(ms.ToArray());
        return start;
    }
    // Reads a stream line by line, keeping the line ending; returns false at end of input.
    sealed class LineReader {
        readonly Stream s; readonly byte[] buf = new byte[1 << 20]; int pos, len;
        public LineReader(Stream s) { this.s = s; }
        public bool Next(MemoryStream line) {
            line.SetLength(0);
            while (true) {
                if (pos >= len) { len = s.Read(buf, 0, buf.Length); pos = 0; if (len <= 0) return line.Length > 0; }
                int nl = Array.IndexOf(buf, (byte)10, pos, len - pos);
                if (nl < 0) { line.Write(buf, pos, len - pos); pos = len; continue; }
                line.Write(buf, pos, nl - pos + 1); pos = nl + 1; return true;
            }
        }
    }
    public static string[] Names(string path) {
        var seen = new List<string>();
        using (var f = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16)) {
            var r = new LineReader(f); var line = new MemoryStream();
            while (r.Next(line)) {
                int end; string name;
                if (Ident(line.GetBuffer(), (int)line.Length, out end, out name) >= 0 && !seen.Contains(name)) seen.Add(name);
            }
        }
        return seen.ToArray();
    }
    public static byte[] RewriteLine(byte[] l, int n, string from, string to) {
        int end; string name;
        int start = Ident(l, n, out end, out name);
        var o = new MemoryStream();
        if (start >= 0 && name == from) {
            o.Write(l, 0, start);
            var q = Encoding.UTF8.GetBytes("`" + to.Replace("`", "``") + "`");
            o.Write(q, 0, q.Length);
            o.Write(l, end, n - end);
        } else o.Write(l, 0, n);
        return o.ToArray();
    }
    // Copies a dump to a process's stdin with the database renamed. Stops quietly when the reader
    // goes away - a failed statement ends mysql.exe, and that failure is reported from its stderr.
    // Splits a whole-database dump into one file per table or view, each with the dump's own
    // opening and closing lines, so each restores on its own - the files the per-table export
    // writes. That export used to run mysqldump once per table, and --single-transaction makes one
    // run consistent, not several: with writes going on, the files came from different moments.
    // One dump is one snapshot; splitting it keeps that. Files are named prefix + name + suffix,
    // with characters a file name cannot hold replaced; two names that come out the same get
    // _2, _3. Returns {name, path} in dump order. The dump is streamed, never held in memory.
    public static List<string[]> SplitByTable(string src, string folder, string prefix, string suffix) {
        long off = 0, prevOff = 0, first = -1, lastSection = 0, tz = -1, mode = -1;
        bool prevDashes = false;
        using (var fs = File.OpenRead(src)) {
            var r = new ByteLines(fs);
            while (r.Next()) {
                int n = r.Length;
                if (SectionName(r.Line, n) != null) { if (first < 0) first = prevDashes ? prevOff : off; lastSection = off; }
                if (LineIs(r.Line, n, "/*!40103 SET TIME_ZONE=@OLD_TIME_ZONE */;")) tz = off;
                if (LineIs(r.Line, n, "/*!40101 SET SQL_MODE=@OLD_SQL_MODE */;")) mode = off;
                prevDashes = LineIs(r.Line, n, "--");
                prevOff = off;
                off += n;
            }
        }
        long total = off;
        var result = new List<string[]>();
        if (first < 0) return result;
        // The closing lines restore what the opening ones set; they start with the time zone (when
        // --tz-utc set one) or the SQL mode. A view's own closing lines look alike but come earlier.
        long closing = (tz > lastSection && tz < mode) ? tz : (mode > lastSection ? mode : total);
        byte[] header = new byte[first], footer = new byte[total - closing];
        using (var fs = File.OpenRead(src)) {
            ReadFully(fs, header);
            fs.Position = closing;
            ReadFully(fs, footer);
        }
        var used = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var pathOf = new Dictionary<string, string>(StringComparer.Ordinal);
        FileStream cur = null;
        byte[] pending = null;
        try {
            using (var fs = File.OpenRead(src)) {
                fs.Position = first;
                var r = new ByteLines(fs);
                long pos = first;
                while (pos < closing && r.Next()) {
                    int n = r.Length;
                    pos += n;
                    string name = SectionName(r.Line, n);
                    if (name != null) {
                        if (cur != null) { cur.Dispose(); cur = null; }
                        string path;
                        if (!pathOf.TryGetValue(name, out path)) {
                            string safe = System.Text.RegularExpressions.Regex.Replace(name, @"[^\w\.\-]", "_");
                            path = Path.Combine(folder, prefix + safe + suffix);
                            for (int i = 2; !used.Add(path); i++) path = Path.Combine(folder, prefix + safe + "_" + i + suffix);
                            File.WriteAllBytes(path, header);
                            pathOf[name] = path;
                            result.Add(new[] { name, path });
                        }
                        cur = new FileStream(path, FileMode.Append, FileAccess.Write);
                        if (pending != null) { cur.Write(pending, 0, pending.Length); pending = null; }
                        cur.Write(r.Line, 0, n);
                        continue;
                    }
                    // A "--" line belongs to the section it heads, so it waits for the next line.
                    if (pending != null) { if (cur != null) cur.Write(pending, 0, pending.Length); pending = null; }
                    if (LineIs(r.Line, n, "--")) { pending = new byte[n]; Array.Copy(r.Line, pending, n); }
                    else if (cur != null) cur.Write(r.Line, 0, n);
                }
                if (pending != null && cur != null) cur.Write(pending, 0, pending.Length);
            }
        } finally { if (cur != null) cur.Dispose(); }
        foreach (var e in result) using (var f = new FileStream(e[1], FileMode.Append, FileAccess.Write)) f.Write(footer, 0, footer.Length);
        return result;
    }
    static readonly string[] SectionHeads = { "-- Table structure for table ", "-- Temporary view structure for view ",
                                               "-- Temporary table structure for view ", "-- Final view structure for view " };
    static readonly Encoding StrictUtf8 = new UTF8Encoding(false, true);
    static int TrimEol(byte[] b, int n) { while (n > 0 && (b[n - 1] == 10 || b[n - 1] == 13)) n--; return n; }
    static bool LineIs(byte[] b, int n, string text) {
        n = TrimEol(b, n);
        if (n != text.Length) return false;
        for (int i = 0; i < n; i++) if (b[i] != (byte)text[i]) return false;
        return true;
    }
    // The name in a mysqldump section heading, or null for any other line. Data never looks like
    // this: every data line is a statement, and a line break inside a value is written as \n.
    public static string SectionName(byte[] b, int n) {
        if (n < 3 || b[0] != 45 || b[1] != 45 || b[2] != 32) return null;
        n = TrimEol(b, n);
        string s;
        try { s = StrictUtf8.GetString(b, 0, n); } catch (DecoderFallbackException) { return null; }
        foreach (var h in SectionHeads) {
            if (!s.StartsWith(h, StringComparison.Ordinal)) continue;
            string rest = s.Substring(h.Length);
            if (rest.Length < 2 || rest[0] != '`' || rest[rest.Length - 1] != '`') return null;
            return rest.Substring(1, rest.Length - 2).Replace("``", "`");
        }
        return null;
    }
    static void ReadFully(Stream s, byte[] buf) {
        int got = 0;
        while (got < buf.Length) { int k = s.Read(buf, got, buf.Length - got); if (k <= 0) throw new EndOfStreamException(); got += k; }
    }
    sealed class ByteLines {
        readonly Stream s;
        readonly byte[] buf = new byte[1 << 16];
        int pos, len;
        public byte[] Line = new byte[256];
        public int Length;
        public ByteLines(Stream s) { this.s = s; }
        // The next line, its LF included; false at the end.
        public bool Next() {
            Length = 0;
            while (true) {
                if (pos >= len) { len = s.Read(buf, 0, buf.Length); pos = 0; if (len <= 0) { len = 0; return Length > 0; } }
                byte c = buf[pos++];
                if (Length == Line.Length) Array.Resize(ref Line, Line.Length * 2);
                Line[Length++] = c;
                if (c == 10) return true;
            }
        }
    }
    public static void CopyRenamed(string path, Stream dst, string from, string to) {
        using (var f = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16)) {
            var r = new LineReader(f); var line = new MemoryStream();
            var w = new BufferedStream(dst, 1 << 20);
            try {
                while (r.Next(line)) { var b = RewriteLine(line.GetBuffer(), (int)line.Length, from, to); w.Write(b, 0, b.Length); }
                w.Flush();
            } catch (IOException) { }
        }
    }
}
'@
function Initialize-DumpDb {
    if (-not ('NobsDumpDb' -as [type])) { Add-Type -TypeDefinition $script:DumpDbSource -Language CSharp }
}
# What to do with one file for a given target: AsIs, Rename (with .From), or Refuse (with .Why).
function Get-DumpPlan { param([string[]]$Names, [string]$Target)
    $Names = @($Names)
    if (-not $Target -or $Names.Count -eq 0 -or ($Names.Count -eq 1 -and $Names[0] -ceq $Target)) { return @{ Kind = 'AsIs' } }
    if ($Names.Count -eq 1) { return @{ Kind = 'Rename'; From = $Names[0] } }
    return @{ Kind = 'Refuse'; Why = "this file contains $($Names.Count) databases ($($Names -join ', ')), so it cannot be restored into the single target '$Target'. Clear ""Target database"" to restore each under its own name." }
}

function Api-Import { param($conn,$data)
    $files=@($data.files); if($files.Count -eq 0){ return '{"ok":false,"error":"No files."}' }
    $mysql = Get-ToolFor $conn 'mysql'
    if(-not $mysql -or -not (Test-Path $mysql)){ return '{"ok":false,"error":"mysql.exe not found. Open Settings in the app to select it, or to download the MariaDB client tools."}' }
    $cnf=New-Cnf $conn -Tool $mysql; $log=New-Object System.Collections.ArrayList
    # Statements mysql skipped because --force ("Continue on error") was in effect. Counted and
    # reported back so a failed restore cannot quietly present itself as a screen full of OK
    # lines - see the per-file logging below.
    $errorsSkipped=0
    $jobId=[string]$data.jobId
    $job=[pscustomobject]@{ Cancelled=$false; CurrentProcess=$null }
    if($jobId){ $script:RunningJobs[$jobId]=$job }
    try {
        $target=[string]$data.targetDb
        if($target -and $data.createDb){ $r=Run-Proc $mysql @("--defaults-extra-file=$cnf","-e",('CREATE DATABASE IF NOT EXISTS '+(SqlId $target))); [void]$log.Add($(if($r.exit -eq 0){"Ensured database $target"}else{"Create DB failed: "+(FirstErr $r.err)})) }
        foreach($f in $files){
            if($job.Cancelled){ [void]$log.Add("CANCELLED (remaining files skipped)"); break }
            if(-not (Test-Path $f)){ [void]$log.Add("SKIP (missing): $f"); continue }
            $binMode = [bool]$data.binaryMode
            # Export lets you raise mysqldump's --max-allowed-packet (needed for extended-insert
            # with large rows/BLOBs), but the mysql client re-importing that exact file has its
            # own, separate default (16M) - without a matching bump here, re-importing a dump
            # exported with a larger packet size fails with "MySQL server has gone away".
            $maxPacket = ([string]$data.maxpacket).Trim()
            $a=@("--defaults-extra-file=$cnf"); if($data.force){$a+='--force'}; if($binMode){$a+='--binary-mode'}; if($maxPacket){$a+="--max-allowed-packet=$maxPacket"}; if($data.fkOff){$a+='--init-command=SET FOREIGN_KEY_CHECKS=0; SET UNIQUE_CHECKS=0'}; if($target){$a+=$target}
            $short = [IO.Path]::GetFileName($f)
            Initialize-DumpDb
            $plan = Get-DumpPlan ([NobsDumpDb]::Names($f)) $target
            if ($plan.Kind -eq 'Refuse') { [void]$log.Add("SKIPPED $short : "+$plan.Why); continue }
            $rename = $null
            if ($plan.Kind -eq 'Rename') { $rename = @{ From = $plan.From; To = $target }; [void]$log.Add("$short holds database '$($plan.From)' - restoring it into '$target' instead") }
            $r=Run-Stdin $mysql $a $null $f $jobId -Rename $rename
            if($job.Cancelled){ [void]$log.Add("CANCELLED"); break }
            $autoRetried = $false
            if ($r.exit -ne 0 -and -not $binMode -and (FirstErr $r.err) -match "ASCII '\\0'.*--binary-mode") {
                $a2=@("--defaults-extra-file=$cnf","--binary-mode"); if($data.force){$a2+='--force'}; if($maxPacket){$a2+="--max-allowed-packet=$maxPacket"}; if($data.fkOff){$a2+='--init-command=SET FOREIGN_KEY_CHECKS=0; SET UNIQUE_CHECKS=0'}; if($target){$a2+=$target}
                $r=Run-Stdin $mysql $a2 $null $f $jobId -Rename $rename
                $autoRetried = $true
            }
            $retryNote = $(if($autoRetried){" (auto-retried with --binary-mode)"}else{""})
            if($r.exit -eq 0){
                # "Continue on error" passes --force, and mysql then exits 0 even when every statement
                # failed, reporting what went wrong on stderr instead. Taking the exit code at face value
                # turned a completely failed import into a clean list of OK lines - the worst possible
                # outcome for a restore, because it looks like it worked. Report what the tool said.
                $skipped = @(($r.err -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -match "ERROR" })
                if($skipped.Count -eq 0){
                    [void]$log.Add("OK  $short$retryNote")
                } else {
                    $errorsSkipped += $skipped.Count
                    $more = $(if($skipped.Count -gt 1){" (+"+($skipped.Count-1)+" more)"}else{""})
                    [void]$log.Add("OK with $($skipped.Count) error(s) SKIPPED  $short : "+$skipped[0]+$more+$retryNote)
                }
            } else {
                $failNote = $(if($autoRetried){" (retried with --binary-mode, still failed)"}else{""})
                [void]$log.Add("FAILED ($($r.exit)) $short : "+(Friendly-DumpErr (FirstErr $r.err))+$failNote)
            }
        }
        if($job.Cancelled){ '{"ok":true,"cancelled":true,"errorsSkipped":'+$errorsSkipped+',"log":'+(J-Arr $log)+'}' } else { '{"ok":true,"errorsSkipped":'+$errorsSkipped+',"log":'+(J-Arr $log)+'}' }
    } finally { Remove-Item $cnf -Force -ErrorAction SilentlyContinue; if($jobId){ $null=$script:RunningJobs.TryRemove($jobId,[ref]$null) } }
}

# ---------------------------------------------------------------------------
# HTTP server
# ---------------------------------------------------------------------------
# Parse a raw HTTP request from the browser into method / path / headers / body.
function Read-Request { param($client)
    $ns=$client.GetStream(); $ns.ReadTimeout=8000
    $ms=New-Object System.IO.MemoryStream; $buf=New-Object byte[] 16384; $headerEnd=-1
    try {
        while($true){
            $read=$ns.Read($buf,0,$buf.Length); if($read -le 0){ break }
            $ms.Write($buf,0,$read); $arr=$ms.ToArray()
            for($i=0;$i -le $arr.Length-4;$i++){ if($arr[$i]-eq 13 -and $arr[$i+1]-eq 10 -and $arr[$i+2]-eq 13 -and $arr[$i+3]-eq 10){ $headerEnd=$i; break } }
            if($headerEnd -ge 0){
                $htext=[Text.Encoding]::ASCII.GetString($arr,0,$headerEnd); $cl=0
                if($htext -match '(?im)^Content-Length:\s*(\d+)'){ $cl=[int]$Matches[1] }
                $bodyStart=$headerEnd+4; $have=$arr.Length-$bodyStart
                while($have -lt $cl){ $read=$ns.Read($buf,0,$buf.Length); if($read -le 0){break}; $ms.Write($buf,0,$read); $have+=$read }
                $arr=$ms.ToArray(); $body=''
                if($cl -gt 0){ $take=[Math]::Min($cl,$arr.Length-$bodyStart); $body=[Text.Encoding]::UTF8.GetString($arr,$bodyStart,$take) }
                $first=($htext -split "`r`n")[0]; $parts=$first -split ' '
                return @{ method=$parts[0]; path=$parts[1]; body=$body }
            }
        }
    } catch { }
    return @{ method='GET'; path='/'; body='' }
}
# Write a raw HTTP response back to the browser.
function Send-Http { param($client,[string]$status,[string]$ctype,[byte[]]$body)
    $head="HTTP/1.1 $status`r`nContent-Type: $ctype`r`nContent-Length: $($body.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n"
    $hb=[Text.Encoding]::ASCII.GetBytes($head); $ns=$client.GetStream(); $ns.Write($hb,0,$hb.Length); if($body.Length){ $ns.Write($body,0,$body.Length) }; $ns.Flush()
}
# Shortcut: send a JSON response (200 OK).
function Send-Json { param($client,[string]$json) Send-Http $client '200 OK' 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($json)) }

# Endpoint: import a CSV file into a table.
function Api-ImportCsv { param($conn,$data)
    # An EMPTY null marker is a real setting - it means "a blank cell is NULL" - and is exactly
    # what the CSV dialog sends when the user clears the NULL value box. PowerShell treats the
    # empty string as false, so the old truthiness test could not tell "not supplied" from
    # "supplied as empty" and quietly substituted \N for both, leaving blank cells as empty
    # strings instead of NULL. Test for the property being absent instead. The Tauri edition
    # already draws this distinction - its unwrap_or only applies when the field is missing.
    $nullMarker = if($null -ne $data.nullValue){[string]$data.nullValue}else{'\N'}
    $file=[string]$data.file
    if(-not $file -or -not (Test-Path $file)){ return '{"ok":false,"error":"CSV file not found."}' }
    $fsz = (Get-Item $file).Length
    if ($fsz -gt 200MB -and -not [bool]$data.forceLarge) {
        return '{"ok":false,"error":"This CSV is '+([math]::Round($fsz/1MB,0))+' MB. The built-in CSV import loads the whole file into memory and is not recommended above ~200 MB - use mysqlimport or LOAD DATA INFILE for very large files instead. Pass forceLarge to proceed anyway."}'
    }
    $db=[string]$data.db; $table=[string]$data.table
    if(-not $db -or -not $table){ return '{"ok":false,"error":"No target table."}' }
    $dbl=SqlLit $db; $tl=SqlLit $table
	$cr=Run-Query2 $conn ("SELECT COLUMN_NAME,DATA_TYPE,EXTRA FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=$dbl AND TABLE_NAME=$tl ORDER BY ORDINAL_POSITION") $null
    if(-not $cr.ok){ return '{"ok":false,"error":'+(J-Str $cr.err)+'}' }
    $tableCols=@($cr.rows | ForEach-Object { $_[0] })
    if($tableCols.Count -eq 0){ return '{"ok":false,"error":"Table not found or has no columns."}' }
    # The "0xDEADBEEF passes through unquoted as a hex literal" rule below exists so a genuinely
    # binary/BIT column can be filled from its own hex display - it's not meant for an ordinary
    # text column that merely happens to contain a value that LOOKS like hex ("0xFF", a hash, an
    # ID). Only the columns information_schema actually reports as binary/BIT get that treatment.
    $binTypes=@('binary','varbinary','blob','tinyblob','mediumblob','longblob','bit')
    $binCols=@($cr.rows | Where-Object { $binTypes -contains ([string]$_[1]).ToLower() } | ForEach-Object { $_[0] })
    # Read with numbered columns, one more than the header has, so a row's field count shows: a
    # missing field comes back $null (an empty one is ''), and anything in the extra column is a
    # field too many. Import-Csv with the file's own header made missing fields NULL and dropped
    # extra ones - a stray separator or an unquoted line break imported as a shifted or cut row.
    try {
        $first = @(Import-Csv -Path $file -Header 'c0' | Select-Object -First 1)
        $width = if ($data.hasHeader) { $null } else { $tableCols.Count }
        if ($data.hasHeader) {
            if ($first.Count -eq 0) { return '{"ok":false,"error":"The CSV is empty."}' }
            # Just the header line, parsed on its own to count its fields.
            $probe = @(Get-Content -LiteralPath $file -TotalCount 1 -Encoding UTF8 | ConvertFrom-Csv -Header (0..4095 | ForEach-Object { "c$_" }))
            $width = @($probe[0].PSObject.Properties | Where-Object { $null -ne $_.Value }).Count
        }
        $names = @(0..$width | ForEach-Object { "c$_" })
        $all = @(Import-Csv -Path $file -Header $names)
    }
    catch { return '{"ok":false,"error":'+(J-Str ("CSV parse error: "+$_.Exception.Message))+'}' }
    if ($data.hasHeader) {
        $csvCols = @(0..($width-1) | ForEach-Object { [string]$all[0]."c$_" })
        $rows = @($all | Select-Object -Skip 1)
    } else { $csvCols = $tableCols; $rows = $all }
    if($rows.Count -eq 0){ return '{"ok":false,"error":"CSV has no data rows."}' }
    for ($ri = 0; $ri -lt $rows.Count; $ri++) {
        $row = $rows[$ri]; $n = $width
        if ($null -ne $row."c$width") { $n = 'more than ' + $width }
        else { for ($k = $width - 1; $k -ge 0 -and $null -eq $row."c$k"; $k--) { $n = $k } }
        if ($n -ne $width) {
            $what = if ($data.hasHeader) { 'header' } else { 'table' }
            return '{"ok":false,"error":'+(J-Str ("Data row $($ri + 1) has $n field(s), but the $what has $width. Nothing was imported."))+'}'
        }
    }
    # A header is matched to the table's columns ignoring case, as MySQL does. A column the table
    # does not have used to be skipped without a word - a typo in the header row left that
    # column's data out of every row imported.
    $useCols = @(); $unknown = @()
    foreach ($h in $csvCols) {
        $tc = @($tableCols | Where-Object { $_ -eq $h.Trim() }) | Select-Object -First 1
        if ($null -eq $tc) { $unknown += $(if ($h) { $h } else { '(empty)' }); continue }
        if ($useCols -contains $tc) { return '{"ok":false,"error":'+(J-Str "The CSV has the column $tc twice. Nothing was imported.")+'}' }
        $useCols += $tc
    }
    if ($unknown.Count) { return '{"ok":false,"error":'+(J-Str ("The table has no column named " + ($unknown -join ', ') + ". Nothing was imported - rename the CSV column(s) or remove them."))+'}' }
    # A generated column cannot be given a value - the server computes it - so the CSV's copy of it
    # (this app's own CSV export includes them) is left out.
    $generated = @($cr.rows | Where-Object { Test-GeneratedExtra ([string]$_[2]) } | ForEach-Object { [string]$_[0] })
    $csvIdx = @(0..($useCols.Count-1) | Where-Object { $generated -notcontains $useCols[$_] })
    $skippedGen = @($useCols | Where-Object { $generated -contains $_ })
    $useCols = @($csvIdx | ForEach-Object { $useCols[$_] })
    if ($useCols.Count -eq 0) { return '{"ok":false,"error":"The CSV has no column that can be written."}' }
    $tbl=(SqlId $db)+'.'+(SqlId $table)
    $colList=($useCols | ForEach-Object { SqlId $_ }) -join ','
    # "Truncate table" + a mid-file failure (a bad value, an FK violation, disk full) used to
    # leave the table permanently truncated and only partially reloaded - mysql.exe stops at the
    # first error by default, but every statement before that had already committed on its own
    # (autocommit), with nothing to undo them. Wrapped in START TRANSACTION/COMMIT instead: if any
    # statement fails, mysql.exe stops before reaching COMMIT, and MySQL automatically rolls back
    # whatever's still open the moment the connection closes.
    #
    # TRUNCATE TABLE itself is DDL - MySQL/MariaDB implicitly commit it the moment it runs,
    # transaction or not, so wrapping THAT in START TRANSACTION would do nothing to protect it.
    # DELETE FROM (no WHERE) does the same job here and, unlike TRUNCATE, is ordinary
    # transactional DML that a rollback genuinely undoes - the one real cost is that it doesn't
    # reset an AUTO_INCREMENT counter the way TRUNCATE does.
    $sb=New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('START TRANSACTION;')
    # Foreign key and unique checks stay on. They were switched off here, which let a CSV row
    # point at a parent that does not exist - stored without an error.
    if($data.truncate){ [void]$sb.AppendLine('DELETE FROM '+$tbl+';') }
    $batch=New-Object System.Collections.ArrayList; $n=0
    foreach($row in $rows){
        $vals=@()
        # The export writes NULL as an explicit marker (\N by default) so it stays distinct
        # from an empty string in the file. Read it back the same way; an empty cell keeps its
        # long-standing meaning of NULL, so importing a spreadsheet is unchanged.
        # A bare "0x" in a binary column is an EMPTY binary value - that is how the Tauri edition exports
        # one - and the hex rule below needs at least one digit, so it used to be stored as the text "0x".
        for($ci=0; $ci -lt $useCols.Count; $ci++){ $c=$useCols[$ci]; $v=$row."c$($csvIdx[$ci])"; if($null -eq $v -or ($nullMarker -and $v -ceq $nullMarker) -or (-not $nullMarker -and $v -eq '')){ $vals+='NULL' } elseif(($binCols -contains $c) -and $v -eq '0x'){ $vals+="X''" } elseif(($binCols -contains $c) -and $v -match '^0x[0-9A-Fa-f]+$'){ $vals+=$v } else { $vals+=(SqlLit $v) } }
        [void]$batch.Add('('+($vals -join ',')+')'); $n++
        if($batch.Count -ge 500){ [void]$sb.AppendLine('INSERT INTO '+$tbl+' ('+$colList+') VALUES '+($batch -join ',')+';'); $batch.Clear() }
    }
    if($batch.Count){ [void]$sb.AppendLine('INSERT INTO '+$tbl+' ('+$colList+') VALUES '+($batch -join ',')+';') }
    [void]$sb.AppendLine('COMMIT;')
    $my=Get-Mysql $conn
    $cnf=New-Cnf $conn -Tool $my
    $tmp=Join-Path $env:TEMP ("mysqlcsv_"+[Guid]::NewGuid().ToString('N')+".sql")
    try {
        [IO.File]::WriteAllText($tmp,$sb.ToString(),(New-Object System.Text.UTF8Encoding($false)))
        $r=Run-Stdin $my @("--defaults-extra-file=$cnf") $null $tmp
        $note = if ($skippedGen.Count) { '; generated, so computed by the server: ' + ($skippedGen -join ', ') } else { '' }
        if($r.exit -eq 0){ return '{"ok":true,"message":'+(J-Str ("Imported $n row(s) into $db.$table (columns: "+($useCols -join ', ')+$note+")"))+'}' }
        return '{"ok":false,"error":'+(J-Str (FirstErr $r.err))+'}'
    } finally { Remove-Item $cnf -Force -ErrorAction SilentlyContinue; Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}
# Endpoint: open a native file/folder picker dialog for the UI.
function Api-Browse { param($data)
    $path=[string]$data.path; $filter=[string]$data.filter; $dirsOnly=[bool]$data.dirsOnly
    try {
        if(-not $path -or $path -eq 'ROOT'){
            $roots=New-Object System.Collections.ArrayList
            if($env:USERPROFILE -and (Test-Path $env:USERPROFILE)){ [void]$roots.Add([pscustomobject]@{name='Home ('+(Split-Path $env:USERPROFILE -Leaf)+')';path=$env:USERPROFILE}) }
            Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | ForEach-Object { [void]$roots.Add([pscustomobject]@{name=$_.Root;path=$_.Root}) }
            $dj=($roots | ForEach-Object { '{"name":'+(J-Str $_.name)+',"path":'+(J-Str $_.path)+'}' }) -join ','
            return '{"ok":true,"path":"","parent":"ROOT","dirs":['+$dj+'],"files":[]}'
        }
        if(-not (Test-Path $path)){ return '{"ok":false,"error":"path not found"}' }
        $item=$null
        try { $item=Get-Item -LiteralPath $path -Force -ErrorAction Stop } catch { return '{"ok":false,"error":'+(J-Str ("Could not access this path: "+$_.Exception.Message))+'}' }
        if(-not $item){ return '{"ok":false,"error":"Could not access this path (unknown reason)."}' }
        $dir = if($item.PSIsContainer){ $item.FullName } else { $item.DirectoryName }
        if(-not $dir){ return '{"ok":false,"error":"Could not resolve a directory for this path."}' }
        $parent=(Split-Path $dir -Parent); if(-not $parent){ $parent='ROOT' }
        $subs=@(Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction SilentlyContinue | Sort-Object Name)
        $dj=($subs | ForEach-Object { '{"name":'+(J-Str $_.Name)+',"path":'+(J-Str $_.FullName)+'}' }) -join ','
        $fj=''
        if(-not $dirsOnly){
            $ff = if($filter){ Get-ChildItem -LiteralPath $dir -File -Force -Filter $filter -ErrorAction SilentlyContinue } else { Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction SilentlyContinue }
            $fj=(@($ff | Sort-Object Name) | ForEach-Object { '{"name":'+(J-Str $_.Name)+',"path":'+(J-Str $_.FullName)+'}' }) -join ','
        }
        return '{"ok":true,"path":'+(J-Str $dir)+',"parent":'+(J-Str $parent)+',"dirs":['+$dj+'],"files":['+$fj+']}'
    } catch { return '{"ok":false,"error":'+(J-Str $_.Exception.Message)+'}' }
}

# --- Saved connections (passwords encrypted with Windows DPAPI, per-user) ---
$script:ConnFile = Join-Path $env:APPDATA 'NOBSSQL\connections.json'
$script:LibFile = Join-Path $env:APPDATA 'NOBSSQL\library.json'
# Read the saved-query library from disk (library.json).
function Load-Lib {
    if(-not (Test-Path $script:LibFile)){ return @() }
    try {
        $raw=[IO.File]::ReadAllText($script:LibFile); $raw=$raw.TrimStart([char]0xFEFF)
        if(-not $raw.Trim()){ return @() }
        $parsed = $raw | ConvertFrom-Json
        $acc = New-Object System.Collections.ArrayList
        foreach($x in @($parsed)){ if($x -and $x.PSObject -and $x.PSObject.Properties['name']){ [void]$acc.Add($x) } }
        return @($acc.ToArray())
    } catch { return @() }
}
# Write the saved-query library to disk.
function Save-Lib { param($list)
    Use-FileLock 'Lib' {
        $d=Split-Path $script:LibFile; if(-not(Test-Path $d)){New-Item -ItemType Directory -Path $d -Force|Out-Null}
        $parts=@(); foreach($it in @($list)){ if($it -and $it.PSObject -and $it.PSObject.Properties['name']){ $parts += ($it | ConvertTo-Json -Depth 5 -Compress) } }
        [IO.File]::WriteAllText($script:LibFile, '['+($parts -join ',')+']', (New-Object System.Text.UTF8Encoding($false)))
    }
}
# Endpoint: return all saved queries.
function Api-LibList {
    $items = Load-Lib | ForEach-Object { '{"name":'+(J-Str $_.name)+',"sql":'+(J-Str $_.sql)+',"schema":'+(J-Str $_.schema)+',"ts":'+([long]($_.ts)).ToString()+'}' }
    '{"ok":true,"items":['+($items -join ',')+']}'
}
# Endpoint: add or update one saved query.
function Api-LibSave { param($data)
    $name=[string]$data.name; if(-not $name){ return '{"ok":false,"error":"name required"}' }
    $ts = if($data.ts){ [long]$data.ts } else { [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) }
    $list=@(Load-Lib | Where-Object { $_.name -ne $name })
    $list=,([pscustomobject]@{name=$name;sql=[string]$data.sql;schema=[string]$data.schema;ts=$ts}) + $list
    Save-Lib $list; '{"ok":true}'
}
# Endpoint: delete one saved query by name.
function Api-LibDelete { param($data)
    $list=@(Load-Lib | Where-Object { $_.name -ne [string]$data.name }); Save-Lib $list; '{"ok":true}'
}
# Endpoint: delete ALL saved queries.
function Api-LibClear { Save-Lib @(); '{"ok":true}' }
# Endpoint: replace the whole library at once (used by Import).
function Api-LibReplace { param($data)
    $list=New-Object System.Collections.ArrayList
    foreach($x in @($data.items)){
        if($x -and $x.name){
            $t = if($x.ts){ [long]$x.ts } else { [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) }
            [void]$list.Add([pscustomobject]@{name=[string]$x.name;sql=[string]$x.sql;schema=[string]$x.schema;ts=$t})
        }
    }
    Save-Lib $list; '{"ok":true}'
}
# Endpoint: delete ALL saved connections (used by Clear all app data).
function Api-ConnClear { Save-Conns @(); '{"ok":true}' }
# Endpoint: mark one connection primary so it auto-opens on startup (clears the others).
function Api-ConnSetPrimary { param($data)
    $name=[string]$data.name
    $list = Load-Conns | ForEach-Object {
        $pass = if($_.pass){ [string]$_.pass } else { '' }
        [pscustomobject]@{name=$_.name;host=$_.host;port=$_.port;user=$_.user;ssl=$_.ssl;sslCa=[string]$_.sslCa;pass=$pass;primary=($name -ne '' -and $_.name -eq $name);accent=[string]$_.accent;env=[string]$_.env;readonly=[bool]$_.readonly}
    }
    Save-Conns @($list); '{"ok":true}'
}
# Recursively collect real connection objects - self-heals a file that got wrongly nested.
function Add-ConnObjs { param($x,$acc)
    if($null -eq $x){ return }
    if($x -is [string]){ return }
    if($x -is [System.Collections.IEnumerable]){ foreach($y in $x){ Add-ConnObjs $y $acc }; return }
    if($x.PSObject -and $x.PSObject.Properties['name']){ [void]$acc.Add($x) }
}
# Read saved connections (connections.json). Passwords are DPAPI-encrypted per Windows user.
function Load-Conns {
    if(-not (Test-Path $script:ConnFile)){ return @() }
    try {
        $raw=[IO.File]::ReadAllText($script:ConnFile); $raw=$raw.TrimStart([char]0xFEFF)
        if(-not $raw.Trim()){ return @() }
        $parsed = $raw | ConvertFrom-Json
        $acc = New-Object System.Collections.ArrayList
        Add-ConnObjs $parsed $acc
        return @($acc.ToArray())
    } catch { return @() }
}
# Write saved connections back to disk as a flat JSON array.
function Save-Conns { param($list)
    Use-FileLock 'Conn' {
        $d=Split-Path $script:ConnFile; if(-not(Test-Path $d)){New-Item -ItemType Directory -Path $d -Force|Out-Null}
        $acc = New-Object System.Collections.ArrayList
        Add-ConnObjs $list $acc
        $parts=@(); foreach($it in $acc){ $parts += ($it | ConvertTo-Json -Depth 5 -Compress) }
        $json='['+($parts -join ',')+']'
        [IO.File]::WriteAllText($script:ConnFile, $json, (New-Object System.Text.UTF8Encoding($false)))
    }
}
# "MariaDB 12.3.3" or "MySQL 8.4.9" out of a client tool's --version text, so Settings can show what
# a download (or an installation) actually is - downloaded tools never update themselves.
function Get-ToolVersionLabel { param([string]$Text)
    if ($Text -match '(\d+\.\d+\.\d+)-MariaDB') { return "MariaDB $($Matches[1])" }
    if ($Text -match 'Ver (\d+\.\d+\.\d+)\b.*MySQL') { return "MySQL $($Matches[1])" }
    return $null
}
function Get-ToolVersion { param([string]$Path)
    if (-not $Path -or $Path -eq '(not found)' -or -not (Test-Path -LiteralPath $Path)) { return $null }
    try { return Get-ToolVersionLabel ((& $Path --version 2>$null) -join ' ') } catch { return $null }
}
# Endpoint: report whether the mysql client tools were found.
function Api-ToolsStatus {
    Resolve-Tools
    $m = if($script:MysqlPath){$script:MysqlPath}else{'(not found)'}
    $d = if($script:MysqldumpPath){$script:MysqldumpPath}else{'(not found)'}
    $ms = if($script:MysqlSource){$script:MysqlSource}else{''}
    $ds = if($script:MysqldumpSource){$script:MysqldumpSource}else{''}
    # A handful of export options only exist on one dump-tool flavor: --set-gtid-purged is
    # MySQL 5.6+ only, --column-statistics is MySQL 8+ only - MariaDB's mysqldump has neither,
    # and checking either against it aborts the whole export with "unknown variable". Running
    # --version once here lets the export dialog grey those options out up front instead of
    # letting the user discover it mid-export.
    $dumpIsMariaDb = 'null'
    if($script:MysqldumpPath){
        try { $ver = & $script:MysqldumpPath --version 2>$null; if($ver -match '(?i)mariadb'){ $dumpIsMariaDb='true' } else { $dumpIsMariaDb='false' } } catch {}
    }
    $myM = Get-MysqlFlavorTool 'mysql'; $myD = Get-MysqlFlavorTool 'mysqldump'
    $versions = ',"mysql_version":'+(J-Str (Get-ToolVersion $m))+',"mysqldump_version":'+(J-Str (Get-ToolVersion $d))+
        ',"mysql_for_mysql_version":'+(J-Str (Get-ToolVersion $myM.Path))+',"mysqldump_for_mysql_version":'+(J-Str (Get-ToolVersion $myD.Path))
    $forMysql = $versions+',"mysql_for_mysql":'+(J-Str $myM.Path)+',"mysql_for_mysql_source":'+(J-Str $myM.Source)+',"mysqldump_for_mysql":'+(J-Str $myD.Path)+',"mysqldump_for_mysql_source":'+(J-Str $myD.Source)
    '{"ok":true,"mysql":'+(J-Str $m)+',"mysqldump":'+(J-Str $d)+',"mysql_source":'+(J-Str $ms)+',"mysqldump_source":'+(J-Str $ds)+',"mysqldump_is_mariadb":'+$dumpIsMariaDb+$forMysql+',"download_dir":'+(J-Str $script:ToolsDir)+',"config_file":'+(J-Str $script:CfgFile)+'}'
}
# Endpoint: the tools export and import will use for the CONNECTED server, and whether that
# mysqldump is MariaDB's - the export dialog greys out the options only MySQL's understands.
function Api-ToolsForConn { param($conn)
    $maria = Get-ServerIsMariaDB $conn
    $m = Get-ToolFor $conn 'mysql'
    $d = Get-ToolFor $conn 'mysqldump'
    $dm = 'null'
    if ($d -and (Test-Path $d)) { $dm = $(if (Test-DumpIsMariaDB $d) { 'true' } else { 'false' }) }
    $sm = if ($maria -is [bool]) { $maria.ToString().ToLower() } else { 'null' }
    '{"ok":true,"serverIsMariadb":'+$sm+',"mysql":'+(J-Str $m)+',"mysqldump":'+(J-Str $d)+',"mysqldumpIsMariadb":'+$dm+'}'
}
# Endpoint: return the current tool paths / config for the Settings dialog.
function Api-GetConfig {
    $cfg = Load-Cfg
    $mb = if($cfg -and $cfg.mysql_bin){[string]$cfg.mysql_bin}else{''}
    $db = if($cfg -and $cfg.mysqldump_bin){[string]$cfg.mysqldump_bin}else{''}
    $tpl = if($cfg -and $cfg.mariadb_download_url_template){[string]$cfg.mariadb_download_url_template}else{''}
    $mbm = if($cfg -and $cfg.mysql_bin_mysql){[string]$cfg.mysql_bin_mysql}else{''}
    $dbm = if($cfg -and $cfg.mysqldump_bin_mysql){[string]$cfg.mysqldump_bin_mysql}else{''}
    '{"ok":true,"config":{"mysql_bin":'+(J-Str $mb)+',"mysqldump_bin":'+(J-Str $db)+',"mysql_bin_mysql":'+(J-Str $mbm)+',"mysqldump_bin_mysql":'+(J-Str $dbm)+',"mariadb_download_url_template":'+(J-Str $tpl)+'},"mariadbDownloadUrlDefault":'+(J-Str $script:DefaultMariaDbUrlTemplate)+'}'
}
# Endpoint: save tool paths from the Settings dialog.
function Api-SaveConfig { param($data)
    $cfg = Load-Cfg; if(-not $cfg){ $cfg=[pscustomobject]@{} }
    # Merge the keys that were actually sent instead of rebuilding the object. The Settings
    # dialog saves all three together, but the Download button saves only the URL template, and
    # rebuilding from scratch would blank the tool paths it never sent.
    if($data.config){
        foreach($k in @('mysql_bin','mysqldump_bin','mysql_bin_mysql','mysqldump_bin_mysql','mariadb_download_url_template')){
            $prop = $data.config.PSObject.Properties[$k]
            if($prop){ $cfg | Add-Member -NotePropertyName $k -NotePropertyValue ([string]$prop.Value) -Force }
        }
    }
    Save-Cfg $cfg
    $mb = if($cfg.mysql_bin){[string]$cfg.mysql_bin}else{''}
    $db = if($cfg.mysqldump_bin){[string]$cfg.mysqldump_bin}else{''}
    if($mb -and (Test-Path $mb)){ $script:MysqlPath=$mb }
    if($db -and (Test-Path $db)){ $script:MysqldumpPath=$db }
    '{"ok":true}'
}
# ---------- update notice ----------
# The app says when a newer release exists and links to it; it never downloads or installs
# anything itself. The page asks once per start unless that is switched off in Settings.
$script:ReleasesRepo = 'monsama/nobs-sql-editor-powershell'
function Test-ReleaseIsNewer { param([string]$Latest, [string]$Current)
    $a = $null; $b = $null
    if (-not [version]::TryParse(([string]$Latest).Trim().TrimStart('v', 'V'), [ref]$a)) { return $false }
    if (-not [version]::TryParse(([string]$Current).Trim().TrimStart('v', 'V'), [ref]$b)) { return $false }
    # 1.2 and 1.2.0 are the same release; [version] would call the second one newer.
    $norm = { param($v) [version]::new($v.Major, $v.Minor, [Math]::Max($v.Build, 0), [Math]::Max($v.Revision, 0)) }
    return (& $norm $a) -gt (& $norm $b)
}
function Api-UpdateCheck {
    $current = [string]$script:AppVersion
    try {
        # Windows PowerShell 5.1 does not offer TLS 1.2 by default, and GitHub requires it.
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
        $r = Invoke-RestMethod -Uri "https://api.github.com/repos/$($script:ReleasesRepo)/releases/latest" -UseBasicParsing `
            -UserAgent 'NOBSSQL' -Headers @{ Accept = 'application/vnd.github+json' } -TimeoutSec 10 -ErrorAction Stop
        $tag = [string]$r.tag_name
        $newer = Test-ReleaseIsNewer $tag $current
        '{"ok":true,"current":'+(J-Str $current)+',"latest":'+(J-Str $tag.TrimStart('v','V'))+',"url":'+(J-Str ([string]$r.html_url))+',"newer":'+$newer.ToString().ToLower()+'}'
    } catch {
        '{"ok":false,"current":'+(J-Str $current)+',"error":'+(J-Str $_.Exception.Message)+'}'
    }
}

# ---------- MySQL's own client tools ----------
# For machines without a MySQL installation: a MySQL server otherwise gets MariaDB's tools (see
# Get-ToolFor). MySQL has no release API like MariaDB's, but its download page names the current
# Windows ZIP and prints its MD5 beside it. Both addresses can be overridden in config.json
# (mysql_download_page, mysql_download_url_template). The same as the Tauri edition's
# download_mysql_tools.
function Get-MysqlDownloadDefaults {
    @{
        Page     = 'https://dev.mysql.com/downloads/mysql/8.4.html'
        Template = 'https://cdn.mysql.com/Downloads/MySQL-{series}/{file_name}'
        # Where a release goes once a newer one replaces it on the CDN.
        Archive  = 'https://downloads.mysql.com/archives/get/p/23/file/{file_name}'
    }
}
# The ZIP archive named on MySQL's download page, its version, and the MD5 printed after it.
function Get-MysqlDownloadInfo { param([string]$Html)
    $m = [regex]::Match($Html, '\((mysql-(\d+\.\d+\.\d+)-winx64\.zip)\)')
    if (-not $m.Success) { return $null }
    $after = $Html.Substring($m.Index + $m.Length)
    if ($after.Length -gt 2000) { $after = $after.Substring(0, 2000) }
    $h = [regex]::Match($after, 'class="md5">\s*([0-9a-fA-F]{32})\s*<')
    return @{ File = $m.Groups[1].Value; Version = $m.Groups[2].Value; Md5 = $(if ($h.Success) { $h.Groups[1].Value.ToLower() } else { $null }) }
}
# Only the two binaries the app runs, from <root>/bin/. Both are self-contained - OpenSSL and MySQL
# 8's default authentication are built in, which was checked by running them from an empty folder.
function Get-MysqlZipMember { param([string]$Name)
    $parts = ($Name -replace '\\', '/').Split('/')
    if ($parts.Count -ne 3 -or $parts[1] -ne 'bin') { return $null }
    if ($parts[2] -in 'mysql.exe', 'mysqldump.exe') { return $parts[2] }
    return $null
}
function Api-DownloadMysqlTools {
    $tmpZip = $null
    try {
        $ProgressPreference = 'SilentlyContinue'
        # dev.mysql.com answers a browser-like User-Agent with 403 (it expects the JavaScript a
        # browser would run first) and serves the page to one that says it is curl. Measured.
        $ua = 'curl/8.0 NOBSSQL'
        $def = Get-MysqlDownloadDefaults
        $cfg = Load-Cfg
        $page = if ($cfg -and $cfg.mysql_download_page) { [string]$cfg.mysql_download_page } else { $def.Page }
        $tpl = if ($cfg -and $cfg.mysql_download_url_template) { [string]$cfg.mysql_download_url_template } else { $def.Template }
        try { $html = (Invoke-WebRequest -Uri $page -UseBasicParsing -UserAgent $ua -ErrorAction Stop).Content }
        catch { return '{"ok":false,"error":'+(J-Str "Could not read MySQL's download page $page : $($_.Exception.Message)")+'}' }
        $info = Get-MysqlDownloadInfo $html
        if (-not $info) { return '{"ok":false,"error":'+(J-Str "MySQL's download page $page did not name a Windows ZIP archive.")+'}' }
        # A download that cannot be checked is not installed.
        if (-not $info.Md5) { return '{"ok":false,"error":'+(J-Str "MySQL's download page did not show a checksum for $($info.File), so the download was not attempted.")+'}' }
        $series = ($info.Version.Split('.')[0..1]) -join '.'
        $fill = { param($t) $t.Replace('{series}', $series).Replace('{version}', $info.Version).Replace('{file_name}', $info.File) }
        $tmpZip = Join-Path $env:TEMP ("nobs-mysql-" + [Guid]::NewGuid().ToString('N') + ".zip")
        $errs = @(); $ok = $false
        foreach ($src in @(@{ Label = 'download URL'; Url = (& $fill $tpl) }, @{ Label = 'MySQL archive'; Url = (& $fill $def.Archive) })) {
            Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue
            & curl.exe -fsSL --retry 3 -A $ua -o $tmpZip $src.Url
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path $tmpZip)) { $errs += "$($src.Label) $($src.Url): curl exit $LASTEXITCODE"; continue }
            $got = (Get-FileHash -LiteralPath $tmpZip -Algorithm MD5).Hash.ToLower()
            if ($got -ne $info.Md5) { $errs += "$($src.Label) $($src.Url): checksum mismatch (got $got, the page says $($info.Md5))"; continue }
            $ok = $true; break
        }
        if (-not $ok) { return '{"ok":false,"error":'+(J-Str ("Could not download $($info.File)." + [Environment]::NewLine + ($errs -join [Environment]::NewLine)))+'}' }
        $dest = Join-Path $script:ToolsDir 'mysql'
        if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($tmpZip)
        $got = @()
        try {
            foreach ($e in $zip.Entries) {
                $base = Get-MysqlZipMember $e.FullName
                if ($base) { [IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path $dest $base), $true); $got += $base }
            }
        } finally { $zip.Dispose() }
        if ($got.Count -lt 2) { return '{"ok":false,"error":'+(J-Str "$($info.File) was downloaded and checked, but mysql.exe and mysqldump.exe were not both inside.")+'}' }
        $mb = Join-Path $dest 'mysql.exe'; $db = Join-Path $dest 'mysqldump.exe'
        $cfgSave = Load-Cfg; if (-not $cfgSave) { $cfgSave = [pscustomobject]@{} }
        $cfgSave | Add-Member -NotePropertyName mysql_bin_mysql -NotePropertyValue $mb -Force
        $cfgSave | Add-Member -NotePropertyName mysqldump_bin_mysql -NotePropertyValue $db -Force
        Save-Cfg $cfgSave
        '{"ok":true,"message":'+(J-Str "Downloaded MySQL $($info.Version) client tools to $dest (checksum verified)")+',"config":{"mysql_bin_mysql":'+(J-Str $mb)+',"mysqldump_bin_mysql":'+(J-Str $db)+'}}'
    } catch {
        '{"ok":false,"error":'+(J-Str ("Download failed: " + $_.Exception.Message))+'}'
    } finally {
        if ($tmpZip) { Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue }
    }
}
function Api-DownloadTools {
    try {
        $ProgressPreference='SilentlyContinue'
        $ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'
        $root = Invoke-RestMethod -Uri 'https://downloads.mariadb.org/rest-api/mariadb/' -UseBasicParsing -UserAgent $ua -ErrorAction Stop
        $branch = ($root.major_releases |
            Where-Object { $_.release_status -eq 'Stable' -and $_.release_support_type -eq 'Long Term Support' } |
            Sort-Object { [version]$_.release_id } -Descending | Select-Object -First 1).release_id
        if(-not $branch){ return '{"ok":false,"error":"No stable LTS branch found."}' }
        $binfo = Invoke-RestMethod -Uri "https://downloads.mariadb.org/rest-api/mariadb/$branch/" -UseBasicParsing -UserAgent $ua -ErrorAction Stop
        $patch = ($binfo.releases.PSObject.Properties.Name | Sort-Object { [version]$_ } -Descending | Select-Object -First 1)
        if(-not $patch){ return '{"ok":false,"error":"No patch version found."}' }
        $candidates = $binfo.releases.$patch.files |
            Where-Object { $_.os -match 'Windows' -and $_.file_name -match '\.zip$' -and $_.file_name -notmatch 'debug' }
        $zipEntry = $candidates | Where-Object { $_.cpu -match '64' } | Select-Object -First 1
        if(-not $zipEntry){ $zipEntry = $candidates | Select-Object -First 1 }
        if(-not $zipEntry){ return '{"ok":false,"error":"No Windows zip found for this release."}' }
        $tmpZip = Join-Path $env:TEMP $zipEntry.file_name
        # The REST API's own file_download_url has been observed returning 403 regardless of http/https.
        # A direct mirror URL (same layout MariaDB Foundation publishes at mirror.mariadb.org) works reliably,
        # so try that first and only fall back to the API-provided URL if the mirror layout ever changes.
        $cfgNow = Load-Cfg
        $tpl = if($cfgNow -and $cfgNow.mariadb_download_url_template){[string]$cfgNow.mariadb_download_url_template}else{''}
        if(-not $tpl){ $tpl = $script:DefaultMariaDbUrlTemplate }
        $mirrorUrl = $tpl.Replace('{version}', [string]$patch).Replace('{file_name}', [string]$zipEntry.file_name)
        $apiUrl = [string]$zipEntry.file_download_url -replace '^http://','https://'
        $curlOk = $false
        foreach ($tryUrl in @($mirrorUrl, $apiUrl)) {
            if ($curlOk) { break }
            try {
                & curl.exe -fL --retry 3 -A $ua -o $tmpZip $tryUrl
                if ($LASTEXITCODE -eq 0 -and (Test-Path $tmpZip) -and (Get-Item $tmpZip).Length -gt 1MB) { $curlOk = $true }
                else { Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue }
            } catch { Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue }
        }
        if(-not $curlOk){
            foreach ($tryUrl in @($mirrorUrl, $apiUrl)) {
                if (Test-Path $tmpZip) { break }
                try { Invoke-WebRequest -Uri $tryUrl -OutFile $tmpZip -UseBasicParsing -UserAgent $ua -ErrorAction Stop } catch { Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue }
            }
        }
        if(-not (Test-Path $tmpZip) -or (Get-Item $tmpZip).Length -lt 1MB){ return '{"ok":false,"error":"Download failed from both the mirror and the API-provided URL."}' }

        # Verify integrity before extracting. A download that cannot be checked is not installed -
        # the same rule Api-DownloadMysqlTools applies to its MD5 - because the binaries and the
        # authentication plugins unpacked below are executed afterwards. The checksum comes from the
        # release API and never from the mirror that served the bytes: a mirror that returned the
        # wrong archive cannot also vouch for it, and the mirror URL is a user-editable template
        # while the API address is not.
        $expectedHash = $null
        if ($zipEntry.checksum -and $zipEntry.checksum.sha256sum) { $expectedHash = ([string]$zipEntry.checksum.sha256sum).Trim().ToLower() }
        # Anything that is not a full hex SHA-256 reads as no checksum at all rather than as
        # something to compare against - a truncated or renamed field must mean "cannot be checked".
        if ($expectedHash -notmatch '^[0-9a-f]{64}$') {
            Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue
            return '{"ok":false,"error":'+(J-Str "The MariaDB release API listed no SHA-256 checksum for $($zipEntry.file_name), so the download was not installed.")+'}'
        }
        # -ne rather than -notmatch: -match is a substring test, so a short or partial expected
        # value would pass against any hash that happens to contain it.
        $actualHash = (Get-FileHash -LiteralPath $tmpZip -Algorithm SHA256).Hash.ToLower()
        if ($actualHash -ne $expectedHash) {
            Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue
            return '{"ok":false,"error":'+(J-Str "Checksum mismatch for $($zipEntry.file_name) - got $actualHash, the release API says $expectedHash. Nothing was installed.")+'}'
        }

        if(-not(Test-Path $script:ToolsDir)){ New-Item -ItemType Directory -Path $script:ToolsDir -Force | Out-Null }
        $want = @('mysqldump.exe','mysql.exe','mysqlimport.exe','mysqlcheck.exe','mariadb.exe','mariadb-dump.exe')
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip=[IO.Compression.ZipFile]::OpenRead($tmpZip); $got=@(); $gotPlugins=0
        # Authentication plugins go into plugin/ beside the binaries - without caching_sha2_password
        # the client cannot log in to a stock MySQL 8 server at all (see Get-PluginDir). Matched on
        # the archive path as well as the name so this takes the client plugins from lib/plugin and
        # not something else that happens to share a file name.
        $pluginDir = Join-Path $script:ToolsDir 'plugin'
        foreach($e in $zip.Entries){
            if($want -contains $e.Name){
                [IO.Compression.ZipFileExtensions]::ExtractToFile($e,(Join-Path $script:ToolsDir $e.Name),$true); $got+=$e.Name
            } elseif(($script:ClientAuthPlugins -contains $e.Name) -and ($e.FullName -replace '\\','/') -match '/lib/plugin/'){
                if(-not(Test-Path $pluginDir)){ New-Item -ItemType Directory -Path $pluginDir -Force | Out-Null }
                [IO.Compression.ZipFileExtensions]::ExtractToFile($e,(Join-Path $pluginDir $e.Name),$true); $gotPlugins++
            }
        }
        $zip.Dispose(); Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue
        if($got.Count -eq 0){ return '{"ok":false,"error":"Archive downloaded but no client binaries inside."}' }
        $mb = @('mysql.exe','mariadb.exe') | ForEach-Object { Join-Path $script:ToolsDir $_ } | Where-Object { Test-Path $_ } | Select-Object -First 1
        $db = @('mysqldump.exe','mariadb-dump.exe') | ForEach-Object { Join-Path $script:ToolsDir $_ } | Where-Object { Test-Path $_ } | Select-Object -First 1
        # Merged into what is already saved: writing only these two keys dropped the download URL
        # template and the MySQL-server paths.
        $cfgSave = Load-Cfg; if (-not $cfgSave) { $cfgSave = [pscustomobject]@{} }
        $cfgSave | Add-Member -NotePropertyName mysql_bin -NotePropertyValue ([string]$mb) -Force
        $cfgSave | Add-Member -NotePropertyName mysqldump_bin -NotePropertyValue ([string]$db) -Force
        Save-Cfg $cfgSave
        if($mb){ $script:MysqlPath=[string]$mb }; if($db){ $script:MysqldumpPath=[string]$db }
        '{"ok":true,"message":'+(J-Str ("Downloaded MariaDB $patch client tools to $script:ToolsDir ($gotPlugins auth plugins)"))+',"config":{"mysql_bin":'+(J-Str ([string]$mb))+',"mysqldump_bin":'+(J-Str ([string]$db))+'}}'
    } catch {
        $detail = $_.Exception.Message
        try {
            $resp = $_.Exception.Response
            if ($resp) {
                $stream = $resp.GetResponseStream()
                $reader = New-Object IO.StreamReader($stream)
                $body = $reader.ReadToEnd()
                $reader.Close()
                if ($body) {
                    $snippet = if ($body.Length -gt 800) { $body.Substring(0,800) } else { $body }
                    $detail = $detail + " | Response body: " + $snippet
                }
                $hdrNames = @()
                try { $hdrNames = $resp.Headers.AllKeys } catch {}
                if ($hdrNames.Count -gt 0) { $detail = $detail + " | Headers: " + ($hdrNames -join ', ') }
            }
        } catch {}
        return '{"ok":false,"error":'+(J-Str $detail)+'}'
    }
}
function Api-ConnList {
    # hasPassword: whether the stored $_.pass field is non-empty - just a presence check, not a
    # decrypt, so this never needs to touch the actual DPAPI-protected secret just to report
    # whether one exists. Lets the connection dropdown show which saved connections will prompt
    # for a password on connect versus which already have one stored on this machine.
    $items = Load-Conns | ForEach-Object { $pr = if($_.primary){'true'}else{'false'}; $ro = if($_.readonly){'true'}else{'false'}; $hp = if($_.pass){'true'}else{'false'}; '{"name":'+(J-Str $_.name)+',"host":'+(J-Str $_.host)+',"port":'+(J-Str $_.port)+',"user":'+(J-Str $_.user)+',"ssl":'+(J-Str $_.ssl)+',"sslCa":'+(J-Str ([string]$_.sslCa))+',"primary":'+$pr+',"accent":'+(J-Str ([string]$_.accent))+',"env":'+(J-Str ([string]$_.env))+',"readonly":'+$ro+',"hasPassword":'+$hp+'}' }
    '{"ok":true,"items":['+($items -join ',')+']}'
}
# Look up a saved connection by name (host/port/user/ssl/password/readonly) - used by the
# Compare Databases feature, which needs TWO independent connections that may not be the one
# currently loaded in the connection form.
function Resolve-SavedConn { param($name)
    $c = Load-Conns | Where-Object { $_.name -eq [string]$name } | Select-Object -First 1
    if(-not $c){ return $null }
    $pass=''
    if($c.pass){ try { $sec=ConvertTo-SecureString $c.pass; $b=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec); $pass=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($b); [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) } catch {} }
    # Saved connections are what Compare uses, and Compare reads TIMESTAMP values as text on one
    # server and writes that text on the other. Each server reads it in its own session time zone,
    # so between servers in different zones every copied TIMESTAMP moved by the difference (Zurich
    # to UTC: 12:00 UTC arrived as 14:00 UTC), and equal values showed as different. utc runs
    # both sessions in UTC (see New-Cnf), so the text means the same instant everywhere.
    [pscustomobject]@{ host=$c.host; port=$c.port; user=$c.user; ssl=$c.ssl; sslCa=[string]$c.sslCa; password=$pass; readonly=[bool]$c.readonly; utc=$true }
}
# Returns an ordered map of table -> ordered list of columns {name,type,null,default,extra} for
# every table in the given schema, via one information_schema query (cheap, single round trip).
function Get-SchemaColumns { param($conn,$db)
    $sql = "SELECT TABLE_NAME,COLUMN_NAME,COLUMN_TYPE,IS_NULLABLE,COLUMN_DEFAULT,EXTRA,CHARACTER_SET_NAME,COLLATION_NAME,COLUMN_COMMENT,GENERATION_EXPRESSION FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=" + (SqlLit $db) + " ORDER BY TABLE_NAME,ORDINAL_POSITION"
    $r = Run-Query2 $conn $sql $null
    if(-not $r.ok){ return $null }
    $map = [ordered]@{}
    foreach($row in $r.rows){
        $t = [string]$row[0]
        if(-not $map.Contains($t)){ $map[$t] = New-Object System.Collections.ArrayList }
        [void]$map[$t].Add([pscustomobject]@{ name=[string]$row[1]; type=[string]$row[2]; null=[string]$row[3]; default=$row[4]; extra=[string]$row[5]
                                              charset=$row[6]; collation=$row[7]; comment=[string]$row[8]; generation=[string]$row[9] })
    }
    $map
}
function Get-CreateTableSql { param($conn,$db,$table)
    $r = Run-Query2 $conn ("SHOW CREATE TABLE " + (SqlId $table)) $db
    if($r.ok -and $r.rows.Count -gt 0){ [string]$r.rows[0][1] } else { $null }
}# Fetches CREATE TABLE for MANY tables via mysqldump (ONE process invocation per chunk of up
# to 50 tables), instead of one mysql.exe process per table. Process-spawn overhead (loading the
# client, connecting, authenticating, exiting) is the actual cause of slow schema compares when
# many tables are flagged "missing on target" - this cuts hundreds of spawns down to a handful.
# Falls back gracefully (empty map) on any failure; the caller re-fetches per-table if needed.
function Get-CreateTableSqlBatch { param($conn,$db,$tables,$RequestId)
    $result = @{}
    if(-not $tables -or $tables.Count -eq 0){ return $result }
    $chunkSize = 50
    $dump = Get-ToolFor $conn 'mysqldump'
    $cnf = New-Cnf $conn -Tool $dump
    try {
        for($i=0; $i -lt $tables.Count; $i += $chunkSize){
            if($RequestId -and $script:CancelledCompares.ContainsKey($RequestId)){ break }
            $endIdx = [Math]::Min($i+$chunkSize,$tables.Count) - 1
            $chunk = $tables[$i..$endIdx]
            $a = @("--defaults-extra-file=$cnf","--no-data","--compact","--skip-comments",$db) + $chunk
            $r = Run-Proc $dump $a $RequestId
            if($r.exit -ne 0 -or -not $r.out){ continue }
            $parts = $r.out -split '(?=CREATE TABLE `)'
            foreach($part in $parts){
                if($part -notmatch '^CREATE TABLE `([^`]+)`'){ continue }
                $result[$Matches[1]] = $part.Trim()
            }
        }
    } finally { Remove-Item $cnf -Force -ErrorAction SilentlyContinue }
    $result
}

# Best-effort DEFAULT clause: numeric and keyword defaults (CURRENT_TIMESTAMP, NULL) are emitted
# bare; everything else is quoted as a string literal. Always double-check via Preview SQL.
function ColDefaultClause { param($default)
    if($null -eq $default){ return '' }
    $d = [string]$default
    if($d -match '^-?[0-9]+(\.[0-9]+)?$'){ return " DEFAULT $d" }
    if($d -match '^(CURRENT_TIMESTAMP(\(\d*\))?|NULL)$'){ return " DEFAULT $d" }
    return " DEFAULT " + (SqlLit $d)
}
function ColDefLine { param($col)
    $nullPart = if($col.null -eq 'YES'){'NULL'}else{'NOT NULL'}
    $extraPart = if($col.extra){' ' + $col.extra}else{''}
    (SqlId $col.name) + ' ' + $col.type + ' ' + $nullPart + (ColDefaultClause $col.default) + $extraPart
}
# Each column's definition as the server writes it in SHOW CREATE TABLE, keyed by name (any case).
# Schema sync used to rebuild a column from its type, NULL, default and EXTRA alone, so MODIFY
# COLUMN turned a latin1_bin column into the table's default character set and collation (case-
# insensitive utf8mb4), dropped its comment, and could not write a generated column at all.
function Get-ColumnDefinitions { param([string]$Create)
    $defs = @{}
    foreach ($line in ($Create -split "`r?`n")) {
        $l = $line.Trim()
        if (-not $l.StartsWith('`')) { continue }
        $sb = New-Object System.Text.StringBuilder; $i = 1; $closed = $false
        while ($i -lt $l.Length) {
            if ($l[$i] -eq '`') { if ($i + 1 -lt $l.Length -and $l[$i + 1] -eq '`') { [void]$sb.Append('`'); $i += 2; continue }; $closed = $true; break }
            [void]$sb.Append($l[$i]); $i++
        }
        if ($closed) { $defs[$sb.ToString()] = $l.TrimEnd(',') }
    }
    return $defs
}
# The definition to write for $col: the server's own line, with the character set and collation
# spelled out when the line leaves them to the table default - which on the target may differ.
function ColDefinition { param($col, $defs)
    if (-not $defs -or -not $defs.ContainsKey([string]$col.name)) { return (ColDefLine $col) }
    $def = [string]$defs[[string]$col.name]
    if ($col.charset -and $col.collation -and $def -notmatch '(?i) CHARACTER SET | COLLATE ') {
        # SqlId leaves plain names bare; the server always quotes them.
        $head = '`' + ([string]$col.name).Replace('`', '``') + '` ' + $col.type
        if ($def.StartsWith($head, [StringComparison]::OrdinalIgnoreCase)) {
            return $head + " CHARACTER SET $($col.charset) COLLATE $($col.collation)" + $def.Substring($head.Length)
        }
    }
    return $def
}
# Compares every table in $srcCols/$tgtCols and returns an array of table-diff objects:
# {name, status, sql:[{stmt,checked,kind}]} - status is one of missing_target/missing_source/diff/same.
function Compare-TableSets { param($srcConn,$srcDb,$srcCols,$tgtCols,$RequestId)
    $names = @{}
    foreach($k in $srcCols.Keys){ $names[$k]=$true }; foreach($k in $tgtCols.Keys){ $names[$k]=$true }
    $out = New-Object System.Collections.ArrayList
    $cancelled = $false
    # Two-phase: classify every table first WITHOUT fetching DDL (fast), collecting the names of
    # "missing_target" tables; their DDL is then fetched all at once in a batch (see below) rather
    # than one mysqldump/mysql.exe process per table, which is what actually made large compares slow.
    $missingTargetEntries = New-Object System.Collections.ArrayList
    foreach($t in ($names.Keys | Sort-Object)){
        if($RequestId -and $script:CancelledCompares.ContainsKey($RequestId)){ $cancelled = $true; break }
        $inSrc = $srcCols.Contains($t); $inTgt = $tgtCols.Contains($t)
        if($inSrc -and -not $inTgt){
            $entry = [pscustomobject]@{ name=$t; status='missing_target'; sql=@() }
            [void]$out.Add($entry)
            [void]$missingTargetEntries.Add($entry)
            continue
        }
        if($inTgt -and -not $inSrc){
            [void]$out.Add([pscustomobject]@{ name=$t; status='missing_source'; sql=@([pscustomobject]@{stmt=('DROP TABLE '+(SqlId $t)+';');checked=$false;kind='drop_table'}) })
            continue
        }
        $sCols = $srcCols[$t]; $tCols = $tgtCols[$t]
        $tByName = @{}; foreach($c in $tCols){ $tByName[$c.name]=$c }
        $sByName = @{}; foreach($c in $sCols){ $sByName[$c.name]=$c }
        $diffs = New-Object System.Collections.ArrayList
        $defs = $null
        foreach($c in $sCols){
            $kind = $null
            if(-not $tByName.Contains($c.name)){ $kind = 'add_column' }
            else {
                $tc = $tByName[$c.name]
                if($c.type -ne $tc.type -or $c.null -ne $tc.null -or [string]$c.default -ne [string]$tc.default -or
                   [string]$c.collation -ne [string]$tc.collation -or $c.comment -cne $tc.comment -or $c.generation -ne $tc.generation){ $kind = 'modify_column' }
            }
            if ($kind) {
                if ($null -eq $defs) { $defs = Get-ColumnDefinitions (Get-CreateTableSql $srcConn $srcDb $t) }
                $verb = if ($kind -eq 'add_column') { ' ADD COLUMN ' } else { ' MODIFY COLUMN ' }
                [void]$diffs.Add([pscustomobject]@{ stmt=('ALTER TABLE '+(SqlId $t)+$verb+(ColDefinition $c $defs)+';'); checked=$true; kind=$kind })
            }
        }
        foreach($c in $tCols){
            if(-not $sByName.Contains($c.name)){
                [void]$diffs.Add([pscustomobject]@{ stmt=('ALTER TABLE '+(SqlId $t)+' DROP COLUMN '+(SqlId $c.name)+';'); checked=$false; kind='drop_column' })
            }
        }
        if($diffs.Count -eq 0){ [void]$out.Add([pscustomobject]@{ name=$t; status='same'; sql=@() }) }
        else { [void]$out.Add([pscustomobject]@{ name=$t; status='diff'; sql=@($diffs) }) }
    }
    if(-not $cancelled -and $missingTargetEntries.Count -gt 0){
        $namesToFetch = @($missingTargetEntries | ForEach-Object { $_.name })
        $ddlMap = Get-CreateTableSqlBatch $srcConn $srcDb $namesToFetch $RequestId
        foreach($me in $missingTargetEntries){
            if($RequestId -and $script:CancelledCompares.ContainsKey($RequestId)){ $cancelled = $true; break }
            $ddl = $null
            if($ddlMap.ContainsKey($me.name)){ $ddl = $ddlMap[$me.name] }
            if(-not $ddl){ $ddl = Get-CreateTableSql $srcConn $srcDb $me.name }
            $me.sql = @([pscustomobject]@{stmt=$ddl;checked=$true;kind='create_table'})
        }
    }
    [pscustomobject]@{ tables=$out; cancelled=$cancelled }
}
function Api-CompareDbs { param($data)
    $c = Resolve-SavedConn $data.connName
    if(-not $c){ return '{"ok":false,"error":"Connection not found."}' }
    $r = Run-Query2 $c 'SHOW DATABASES' $null
    if(-not $r.ok){ return '{"ok":false,"error":'+(J-Str $r.err)+'}' }
    $names = @($r.rows | ForEach-Object { [string]$_[0] })
    '{"ok":true,"databases":'+(J-Arr $names)+',"readonly":'+($(if($c.readonly){'true'}else{'false'}))+'}'
}
function Api-CompareTables { param($data)
    $src = Resolve-SavedConn $data.sourceConnName; $tgt = Resolve-SavedConn $data.targetConnName
    if(-not $src -or -not $tgt){ return '{"ok":false,"error":"Connection not found."}' }
    $sql1 = "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA=" + (SqlLit ([string]$data.sourceDb)) + " ORDER BY TABLE_NAME"
    $sql2 = "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA=" + (SqlLit ([string]$data.targetDb)) + " ORDER BY TABLE_NAME"
    $r1 = Run-Query2 $src $sql1 $null; $r2 = Run-Query2 $tgt $sql2 $null
    if(-not $r1.ok){ return '{"ok":false,"error":'+(J-Str $r1.err)+'}' }
    if(-not $r2.ok){ return '{"ok":false,"error":'+(J-Str $r2.err)+'}' }
    $set = @{}; foreach($row in $r1.rows){ $set[[string]$row[0]]=$true }; foreach($row in $r2.rows){ $set[[string]$row[0]]=$true }
    $names = @($set.Keys | Sort-Object)
    '{"ok":true,"tables":'+(J-Arr $names)+'}'
}
# Reusable primary-key lookup (plain array, not a JSON response) - used by the row-level
# compare below. Returns $null on failure, an empty array if the table has no primary key.
function Get-TablePkCols { param($conn,$db,$table)
    $sql = "SELECT COLUMN_NAME FROM information_schema.KEY_COLUMN_USAGE WHERE TABLE_SCHEMA=" + (SqlLit $db) + " AND TABLE_NAME=" + (SqlLit $table) + " AND CONSTRAINT_NAME='PRIMARY' ORDER BY ORDINAL_POSITION"
    $r = Run-Query2 $conn $sql $null
    if(-not $r.ok){ return $null }
    # IMPORTANT: for a single-column PK, PowerShell's pipeline silently "unrolls" a one-element
    # array into a bare string on return (e.g. @("id") becomes just "id" to the caller) - then
    # $pk[0] indexes into the STRING and returns its first CHARACTER ('i'), not the column name.
    # The leading comma forces the array to be emitted as a single object, not enumerated.
    $arr = @($r.rows | ForEach-Object { [string]$_[0] })
    return ,$arr
}
# Same idea as Get-TablePkCols, but for foreign keys (columns with a REFERENCED_TABLE_NAME).
# Same single-column-array unroll gotcha applies here too - the leading comma guards it.
function Get-TableFkCols { param($conn,$db,$table)
    $sql = "SELECT COLUMN_NAME FROM information_schema.KEY_COLUMN_USAGE WHERE TABLE_SCHEMA=" + (SqlLit $db) + " AND TABLE_NAME=" + (SqlLit $table) + " AND REFERENCED_TABLE_NAME IS NOT NULL ORDER BY ORDINAL_POSITION"
    $r = Run-Query2 $conn $sql $null
    if(-not $r.ok){ return $null }
    $arr = @($r.rows | ForEach-Object { [string]$_[0] })
    return ,$arr
}
# JSON endpoint mirroring Api-Pk's shape, used when opening a table tab so the grid can
# highlight foreign-key columns the same way it already highlights the primary key.
# Full FK detail (which table/column each FK column actually references), kept as a SEPARATE
# helper/field from Get-TableFkCols/the "fk" array above - those are used elsewhere purely for
# PK/FK badge display and only need the local column names, so their existing shape stays
# untouched. This powers "go to referenced row" navigation instead.
function Get-TableFkDetails { param($conn,$db,$table)
    $sql = "SELECT COLUMN_NAME, REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME FROM information_schema.KEY_COLUMN_USAGE WHERE TABLE_SCHEMA=" + (SqlLit $db) + " AND TABLE_NAME=" + (SqlLit $table) + " AND REFERENCED_TABLE_NAME IS NOT NULL ORDER BY ORDINAL_POSITION"
    $r = Run-Query2 $conn $sql $null
    if(-not $r.ok){ return $null }
    return ,@($r.rows)
}
function Api-Fk { param($conn,$db,$table)
    $fk = Get-TableFkCols $conn $db $table
    if($null -eq $fk){ return '{"ok":false,"error":"Could not read foreign keys."}' }
    $details = Get-TableFkDetails $conn $db $table
    $detailsJson = if($details){ (J-RowsFast $details) } else { '[]' }
    '{"ok":true,"fk":'+(J-Arr $fk)+',"fkDetails":'+$detailsJson+'}'
}

# Finds rows present in the source table but missing (by primary key) on the target - INSERT
# only, never UPDATE/DELETE. Row data is fetched from the source and re-inserted with the exact
# same primary key value(s), so ids stay identical between the two databases. Capped at 2000
# rows per comparison to stay interactive; a larger gap should go through Export/Import instead.
# Fetches full row data for a SPECIFIC list of primary-key values, chunked for safety (same
# reasoning as elsewhere: a huge WHERE...IN(...) as a mysql.exe command-line argument can exceed
# Windows' command-line length limit). Shared by Api-CompareRows (its first page) and
# Api-CompareRowsFetchByPk (loading a later page the client already knows about, without
# re-scanning the whole table again).
function Get-RowsByPk { param($conn,$db,$table,$pkCols,$pkValues,$RequestId)
    if(-not $pkValues -or $pkValues.Count -eq 0){ return @{ ok=$true; columns=@(); rows=(New-Object System.Collections.ArrayList) } }
    $binSet = Get-BinaryColumnSet $conn $db $table
    $floatSet = Get-FloatColumnSet $conn $db $table
    if($null -eq $binSet){ return @{ ok=$false; err="Could not read the column types of $db.$table." } }
    $fetchChunk = 200
    $fullCols = $null
    $fullRows = New-Object System.Collections.ArrayList
    for($fi=0; $fi -lt $pkValues.Count; $fi += $fetchChunk){
        if($RequestId -and $script:CancelledCompares.ContainsKey($RequestId)){ break }
        $fEnd = [Math]::Min($fi+$fetchChunk,$pkValues.Count) - 1
        $chunk = $pkValues[$fi..$fEnd]
        $where = Get-PkWhere $pkCols $chunk $binSet $floatSet
        $fr = Get-ExactRows $conn $db $table $where $RequestId -Keep $pkCols
        if(-not $fr.ok){ return @{ ok=$false; err=$fr.err } }
        if(-not $fullCols -or @($fullCols).Count -eq 0){ $fullCols = $fr.columns }
        foreach($row in $fr.rows){ [void]$fullRows.Add($row) }
    }
    @{ ok=$true; columns=$fullCols; rows=$fullRows }
}
# Standalone endpoint for loading a LATER page of missing rows the client already knows about
# (from Api-CompareRows' allMissingPks) - a lightweight, bounded fetch that never re-scans the
# whole table, unlike re-running the full comparison.
function Api-CompareRowsFetchByPk { param($data)
    $src = Resolve-SavedConn $data.sourceConnName
    if(-not $src){ return '{"ok":false,"error":"Source connection not found."}' }
    $table = [string]$data.table; $srcDb = [string]$data.sourceDb
    $pkCols = @($data.pkCols)
    $pkValues = @($data.pks)
    if($pkCols.Count -eq 0){ return '{"ok":false,"error":"Missing primary key columns."}' }
    $rid = [string]$data.requestId
    $r = Get-RowsByPk $src $srcDb $table $pkCols $pkValues $rid
    if(-not $r.ok){ return '{"ok":false,"error":'+(J-Str $r.err)+'}' }
    '{"ok":true,"columns":'+(J-Arr $r.columns)+',"rows":'+(J-RowsFast $r.rows)+'}'
}
# Generates a user + grants transfer script for the CURRENT connection, using SHOW CREATE USER
# and SHOW GRANTS FOR rather than hand-building CREATE USER/GRANT text from the grant tables
# directly. This matters: SHOW CREATE USER encodes whatever auth plugin and password hash the
# account actually uses (native password, ed25519, unix_socket, etc.) instead of assuming
# mysql_native_password, and SHOW GRANTS FOR already includes column/routine grants, WITH GRANT
# OPTION, and (on MariaDB) role grants - all of which a plain SELECT against the grant tables
# would silently miss. Works unchanged on MySQL 5.7.6+ and MariaDB 10.2+.
# CREATE USER statements are emitted before any GRANT statements (not just alphabetically, but
# genuinely grouped that way) so replaying the result on a target server never grants to a user
# that doesn't exist yet.
# True for MySQL 8.0.17 and later - the first version with print_identified_with_as_hex.
function Test-MySqlHexIdentified { param([string]$Version)
    if ($Version -match 'MariaDB') { return $false }
    $m = [regex]::Match($Version, '^(\d+)\.(\d+)\.(\d+)')
    if (-not $m.Success) { return $false }
    $v = [version]("{0}.{1}.{2}" -f $m.Groups[1].Value, $m.Groups[2].Value, $m.Groups[3].Value)
    return $v -ge [version]'8.0.17'
}
function Api-GenUserTransfer { param($conn,$data)
    $exclRaw = [string]$data.exclude
    $excl = @($exclRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 0 })
    if ($excl.Count -eq 0) { $excl = @('mysql.sys','root','debian-sys-maint','mariadb.sys','healthcheck','mariabackup','galera','replica','PUBLIC') }
    # The server's own internal accounts are never moved, whatever the list says. They exist on
    # every install of that server and are managed by it, so a script carrying them cannot run: on
    # MySQL 8 it opened with CREATE USER `mysql.infoschema` and `mysql.session` - which already
    # exist on the target - and handed SUPER and SYSTEM_USER grants to them. Only mysql.sys was on
    # the default list. Named, not matched as mysql.%: an account called mysql.backup is a user's.
    foreach ($sys in @('mysql.sys','mysql.session','mysql.infoschema','mariadb.sys')) { if ($excl -notcontains $sys) { $excl += $sys } }
    $inList = ($excl | ForEach-Object { SqlLit $_ }) -join ','
    $usersR = Run-Query2 $conn ("SELECT user, host FROM mysql.user WHERE user NOT IN ($inList) AND user <> ''") $null $null
    if (-not $usersR.ok) { return '{"ok":false,"error":'+(J-Str $usersR.err)+'}' }
    if ($usersR.rows.Count -eq 0) { return '{"ok":true,"sql":"-- No accounts matched (everything was excluded, or mysql.user is empty).","userCount":0,"errorCount":0}' }

    $createLines = New-Object System.Collections.ArrayList
    $grantLines = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList

    # A MySQL 8 caching_sha2_password hash carries a salt of arbitrary 7-bit bytes, control
    # characters included. This edition used to show a value holding control characters as hex, so the
    # CREATE USER line came back as one long 0x... blob, was written into the script as-is, and the
    # account silently went missing from the transfer (measured on MySQL 8.0.46). With
    # print_identified_with_as_hex (8.0.17+) the hash is printed as a 0x literal inside a readable
    # statement instead - plain text, and safe to paste or save. It is a session variable, and each
    # query here is its own mysql.exe session, so it goes in front of the statement itself.
    $hexPrefix = ''
    $vr = Run-Query2 $conn 'SELECT VERSION()' $null $null
    if ($vr.ok -and (Test-MySqlHexIdentified ([string]$vr.rows[0][0]))) { $hexPrefix = 'SET SESSION print_identified_with_as_hex = ON; ' }
    foreach ($row in $usersR.rows) {
        $u = [string]$row[0]; $h = [string]$row[1]
        $uq = $u -replace "'", "''"
        $hq = $h -replace "'", "''"
        $cr = Run-Query2 $conn ($hexPrefix + "SHOW CREATE USER '$uq'@'$hq'") $null $null
        if ($cr.ok -and $cr.rows.Count -gt 0) { [void]$createLines.Add([string]$cr.rows[0][0] + ';') }
        else { [void]$errors.Add("SHOW CREATE USER for '$u'@'$h': " + $(if ($cr.err) { $cr.err } else { 'no result returned' })) }

        $gr = Run-Query2 $conn ("SHOW GRANTS FOR '$uq'@'$hq'") $null $null
        if ($gr.ok) { foreach ($grow in $gr.rows) { [void]$grantLines.Add([string]$grow[0] + ';') } }
        else { [void]$errors.Add("SHOW GRANTS for '$u'@'$h': " + $gr.err) }
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("-- Generated user transfer script - $($usersR.rows.Count) account(s) matched (after exclusions)")
    [void]$sb.AppendLine("-- Run this on the TARGET server. CREATE USER statements are listed first so the GRANT")
    [void]$sb.AppendLine("-- statements below can reference them.")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("-- ===== CREATE USER =====")
    foreach ($l in $createLines) { [void]$sb.AppendLine($l) }
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("-- ===== GRANTS =====")
    foreach ($l in $grantLines) { [void]$sb.AppendLine($l) }
    if ($errors.Count -gt 0) {
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("-- ===== $($errors.Count) account(s) could not be read (the script above is complete for everyone else) =====")
        foreach ($e in $errors) { [void]$sb.AppendLine("-- " + ($e -replace "[\r\n]+", " ")) }
    }

    '{"ok":true,"sql":'+(J-Str $sb.ToString())+',"userCount":'+$usersR.rows.Count+',"errorCount":'+$errors.Count+'}'
}
function Api-CompareRows { param($data)
    $src = Resolve-SavedConn $data.sourceConnName; $tgt = Resolve-SavedConn $data.targetConnName
    if(-not $src -or -not $tgt){ return '{"ok":false,"error":"Connection not found."}' }
    $rid = [string]$data.requestId
    $table = [string]$data.table; $srcDb = [string]$data.sourceDb; $tgtDb = [string]$data.targetDb
    $pk = Get-TablePkCols $src $srcDb $table
    if(-not $pk -or $pk.Count -eq 0){ return '{"ok":false,"error":"Table has no primary key - cannot compare rows."}' }
    $fk = Get-TableFkCols $src $srcDb $table
    if($null -eq $fk){ $fk = @() }
    $pkList = ($pk | ForEach-Object { SqlId $_ }) -join ','
    # Every fetch below is registered under $rid (via Run-Query2's RequestId param) so Cancel can
    # actually KILL the in-flight mysql.exe process for large tables, not just stop between chunks.
    $srcR = Run-Query2Bulk $src ("SELECT $pkList FROM " + (SqlId $srcDb) + '.' + (SqlId $table)) $null $rid
    if(-not $srcR.ok){ return '{"ok":false,"error":'+(J-Str $srcR.err)+'}' }
    $tgtR = Run-Query2Bulk $tgt ("SELECT $pkList FROM " + (SqlId $tgtDb) + '.' + (SqlId $table)) $null $rid
    if(-not $tgtR.ok){
        # The target table hasn't been created yet (e.g. structure hasn't been synced) - treat
        # it as a new, empty table rather than failing: every source row is then "missing".
        if($tgtR.err -match '1146' -or $tgtR.err -match "doesn't exist"){ $tgtR = @{ ok=$true; rows=(New-Object System.Collections.ArrayList) } }
        else { return '{"ok":false,"error":'+(J-Str $tgtR.err)+'}' }
    }
    $tgtSet = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach($row in $tgtR.rows){ [void]$tgtSet.Add(($row -join "`u{1}")) }
    $missingRows = New-Object System.Collections.ArrayList
    foreach($row in $srcR.rows){ if(-not $tgtSet.Contains(($row -join "`u{1}"))){ [void]$missingRows.Add($row) } }
    $missingTotal = $missingRows.Count
    # Rows present only on the TARGET. Nothing here acts on them - this comparison inserts into
    # the target and never deletes from it - but not REPORTING them let a target holding extra
    # rows read as "no row differences", which is the wrong answer to hand someone comparing a
    # production database against a copy. Both key sets are already in memory, so this costs one
    # more pass and no extra query; only key values are returned, never full row data.
    $srcSet = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach($row in $srcR.rows){ [void]$srcSet.Add(($row -join "`u{1}")) }
    $extraRows = New-Object System.Collections.ArrayList
    foreach($row in $tgtR.rows){ if(-not $srcSet.Contains(($row -join "`u{1}"))){ [void]$extraRows.Add($row) } }
    $extraTotal = $extraRows.Count
    # Assigned, not returned from an if-expression: PowerShell unrolls a collection that comes out of
    # one, so with a single row these held that row's key values instead of a list of rows. Compare
    # then looked up the characters of the key and showed a single missing row as having no data.
    $extraPks = $extraRows; if($extraTotal -gt 2000){ $extraPks = $extraRows.GetRange(0,2000) }
    $cap = 2000
    $truncated = $missingTotal -gt $cap
    $useRows = $missingRows; if($truncated){ $useRows = $missingRows.GetRange(0,$cap) }
    $roJson = $(if($tgt.readonly){'true'}else{'false'})
    if($useRows.Count -eq 0){
        return '{"ok":true,"pkCols":'+(J-Arr $pk)+',"columns":[],"rows":[],"missingTotal":0,"truncated":false,"targetReadonly":'+$roJson+',"extraTotal":'+$extraTotal+',"extraPks":'+(J-RowsFast $extraPks)+',"allMissingPks":[]}'
    }
    $fetch = Get-RowsByPk $src $srcDb $table $pk $useRows $rid
    if(-not $fetch.ok){ return '{"ok":false,"error":'+(J-Str $fetch.err)+'}' }
    $cancelled = ($rid -and $script:CancelledCompares.ContainsKey($rid))
    if($rid){ $null = $script:CancelledCompares.TryRemove($rid, [ref]$null) }
    # allMissingPks: the FULL (uncapped) list of missing primary-key values, sent to the client
    # alongside the first page. It's just id values, not full row data, so it's cheap compared to
    # what a full table re-scan would cost - the client can use it to load later pages, or to
    # remove just-inserted rows and pull the next batch, WITHOUT ever re-scanning the table again.
    # J-RowsFast (StringBuilder + plain loop, no pipeline) is dramatically faster than piping
    # through ForEach-Object for large collections - measured ~6x faster at 200,000 rows, and
    # the gap widens further at scale. This list can have hundreds of thousands of entries, so
    # using the pipeline version here would silently reintroduce the exact kind of slowness this
    # whole feature was built to eliminate.
    '{"ok":true,"pkCols":'+(J-Arr $pk)+',"columns":'+(J-Arr $fetch.columns)+',"rows":'+(J-RowsFast $fetch.rows)+',"missingTotal":'+$missingTotal+',"truncated":'+($(if($truncated){'true'}else{'false'}))+',"targetReadonly":'+$roJson+',"extraTotal":'+$extraTotal+',"extraPks":'+(J-RowsFast $extraPks)+',"cancelled":'+($(if($cancelled){'true'}else{'false'}))+',"allMissingPks":'+(J-RowsFast $missingRows)+'}'
}
# Inserts the (client-selected) missing rows into the target, batched, using the exact column
# list and values fetched from the source - so ids/keys match the source exactly. Always
# INSERT-only; never touches an existing target row.
# Finds rows present on BOTH sides (same primary key) whose CONTENT differs - detection only,
# never writes anything. Capped tighter (500) than the missing-rows check since this fetches
# full row data from BOTH source and target for every candidate, which is heavier.
function Api-CompareRowsDiff { param($data)
    $src = Resolve-SavedConn $data.sourceConnName; $tgt = Resolve-SavedConn $data.targetConnName
    if(-not $src -or -not $tgt){ return '{"ok":false,"error":"Connection not found."}' }
    $rid = [string]$data.requestId
    $table = [string]$data.table; $srcDb = [string]$data.sourceDb; $tgtDb = [string]$data.targetDb
    $pk = Get-TablePkCols $src $srcDb $table
    if(-not $pk -or $pk.Count -eq 0){ return '{"ok":false,"error":"Table has no primary key - cannot compare rows."}' }
    $fk = Get-TableFkCols $src $srcDb $table
    if($null -eq $fk){ $fk = @() }
    $pkList = ($pk | ForEach-Object { SqlId $_ }) -join ','
    # Every fetch below is registered under $rid (via Run-Query2's RequestId param) so Cancel can
    # actually KILL the in-flight mysql.exe process for large tables, not just stop between chunks.
    $srcR = Run-Query2Bulk $src ("SELECT $pkList FROM " + (SqlId $srcDb) + '.' + (SqlId $table)) $null $rid
    if(-not $srcR.ok){ return '{"ok":false,"error":'+(J-Str $srcR.err)+'}' }
    $tgtR = Run-Query2Bulk $tgt ("SELECT $pkList FROM " + (SqlId $tgtDb) + '.' + (SqlId $table)) $null $rid
    if(-not $tgtR.ok){
        # Target table doesn't exist yet - treat as empty (nothing in common, so no content diffs).
        if($tgtR.err -match '1146' -or $tgtR.err -match "doesn't exist"){ $tgtR = @{ ok=$true; rows=(New-Object System.Collections.ArrayList) } }
        else { return '{"ok":false,"error":'+(J-Str $tgtR.err)+'}' }
    }
    $tgtSet = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach($row in $tgtR.rows){ [void]$tgtSet.Add(($row -join "`u{1}")) }
    $common = New-Object System.Collections.ArrayList
    foreach($row in $srcR.rows){ if($tgtSet.Contains(($row -join "`u{1}"))){ [void]$common.Add($row) } }
    $commonTotal = $common.Count
    $cap = 500
    $truncated = $commonTotal -gt $cap
    # Assigned, not returned from an if-expression - see Api-CompareRows.
    $useCommon = $common; if($truncated){ $useCommon = $common.GetRange(0,$cap) }
    $roJson = $(if($tgt.readonly){'true'}else{'false'})
    if($useCommon.Count -eq 0){
        return '{"ok":true,"pkCols":'+(J-Arr $pk)+',"fkCols":'+(J-Arr $fk)+',"diffs":[],"commonTotal":'+$commonTotal+',"comparedCount":0,"truncated":false,"targetReadonly":'+$roJson+'}'
    }
    $binSet = Get-BinaryColumnSet $src $srcDb $table
    $floatSet = Get-FloatColumnSet $src $srcDb $table
    if($null -eq $binSet){ return '{"ok":false,"error":'+(J-Str "Could not read the column types of $srcDb.$table.")+'}' }
    $fetchChunk = 200
    $fullCols = $null
    # Keyed by exact key text: a PowerShell hashtable ignores case, so keys 'a' and 'A' were one row.
    $srcFull = New-Object 'System.Collections.Generic.Dictionary[string,object]'
    $tgtFull = New-Object 'System.Collections.Generic.Dictionary[string,object]'
    $cancelled = $false
    for($fi=0; $fi -lt $useCommon.Count; $fi += $fetchChunk){
        if($rid -and $script:CancelledCompares.ContainsKey($rid)){ $cancelled = $true; break }
        $fEnd = [Math]::Min($fi+$fetchChunk,$useCommon.Count) - 1
        $chunk = $useCommon[$fi..$fEnd]
        $where = Get-PkWhere $pk $chunk $binSet $floatSet
        $sr = Get-ExactRows $src $srcDb $table $where $rid -Keep $pk
        if(-not $sr.ok){ return '{"ok":false,"error":'+(J-Str $sr.err)+'}' }
        if(-not $fullCols -or @($fullCols).Count -eq 0){ $fullCols = $sr.columns }
        $pkIdx = @($pk | ForEach-Object { [Array]::IndexOf($fullCols,$_) })
        foreach($row in $sr.rows){ $k = (($pkIdx | ForEach-Object { $row[$_] }) -join "`u{1}"); $srcFull[$k] = $row }
        $tr = Get-ExactRows $tgt $tgtDb $table $where $rid -Columns $sr.columns
        if(-not $tr.ok){ return '{"ok":false,"error":'+(J-Str $tr.err)+'}' }
        foreach($row in $tr.rows){ $k = (($pkIdx | ForEach-Object { $row[$_] }) -join "`u{1}"); $tgtFull[$k] = $row }
    }
    $pkIdxFinal = @($pk | ForEach-Object { [Array]::IndexOf($fullCols,$_) })
    $diffsJ = New-Object System.Collections.ArrayList
    foreach($k in $srcFull.Keys){
        if(-not $tgtFull.ContainsKey($k)){ continue }
        $sRow = $srcFull[$k]; $tRow = $tgtFull[$k]
        $cdJ = New-Object System.Collections.ArrayList
        for($ci=0; $ci -lt $fullCols.Count; $ci++){
            # -ne ignores case, and [string] makes NULL and '' the same - so 'null' against 'NULL',
            # or NULL against an empty string, was reported as no difference at all.
            $sv = $sRow[$ci]; $tv = $tRow[$ci]
            if((($null -eq $sv) -ne ($null -eq $tv)) -or ([string]$sv -cne [string]$tv)){ [void]$cdJ.Add('{"col":'+(J-Str $fullCols[$ci])+',"src":'+(J-Str $sRow[$ci])+',"tgt":'+(J-Str $tRow[$ci])+'}') }
        }
        if($cdJ.Count -gt 0){
            $pkVals = @($pkIdxFinal | ForEach-Object { $sRow[$_] })
            [void]$diffsJ.Add('{"pk":'+(J-Arr $pkVals)+',"colDiffs":['+($cdJ -join ',')+']}')
        }
    }
    if($rid){ $null = $script:CancelledCompares.TryRemove($rid, [ref]$null) }
    '{"ok":true,"pkCols":'+(J-Arr $pk)+',"fkCols":'+(J-Arr $fk)+',"diffs":['+($diffsJ -join ',')+'],"commonTotal":'+$commonTotal+',"comparedCount":'+$useCommon.Count+',"truncated":'+($(if($truncated){'true'}else{'false'}))+',"targetReadonly":'+$roJson+',"cancelled":'+($(if($cancelled){'true'}else{'false'}))+'}'
}
# Applies the (client-selected) content updates: one UPDATE per row, using the SOURCE value for
# each column flagged as different, matched by primary key. This OVERWRITES existing target
# data for those rows - the only write path in Compare that does so - and is always
# client-confirmed with an explicit warning before this is ever called.
function Api-CompareRowsApplyDiff { param($data)
    $tgt = Resolve-SavedConn $data.targetConnName
    if(-not $tgt){ return '{"ok":false,"error":"Target connection not found."}' }
    if($tgt.readonly){ return '{"ok":false,"error":"Target connection is read-only / safe mode - blocked."}' }
    $db = [string]$data.targetDb; $table = [string]$data.table
    $pkCols = @($data.pkCols); $updates = @($data.updates)
    if($pkCols.Count -eq 0 -or $updates.Count -eq 0){ return '{"ok":false,"error":"No rows to update."}' }
    $obj = (SqlId $db) + '.' + (SqlId $table)
    $binSet = Get-BinaryColumnSet $tgt $db $table
    if($null -eq $binSet){ return '{"ok":false,"error":'+(J-Str "Could not read the column types of $db.$table.")+'}' }
    $floatSet = Get-FloatColumnSet $tgt $db $table
    # Unlike Api-CompareRowsApply/Api-CompareRowsInsertAll (INSERT-only, each batch already atomic
    # as one statement, and a chunk failing partway through a large bulk insert shouldn't block
    # the rest), this updates EXISTING target rows one at a time - the exact "apply this reviewed
    # set of corrections" shape the grid's own staged-edits apply already treats as one
    # transaction. Every statement used to run as its own separate mysql.exe process/connection
    # (so a per-connection START TRANSACTION couldn't have spanned them even if added naively) -
    # now the whole batch is one script in one connection, wrapped in START TRANSACTION/COMMIT:
    # mysql.exe stops at the first error by default, and MySQL rolls back whatever's still open
    # the moment the connection then closes.
    $stmts = New-Object System.Collections.ArrayList
    $pkDescs = New-Object System.Collections.ArrayList
    $skipped = New-Object System.Collections.ArrayList
    foreach($u in $updates){
        $sets = @(); foreach($cd in $u.colDiffs){ $sets += (SqlId ([string]$cd.col)) + '=' + (SqlValFor $cd.src ($binSet.Contains([string]$cd.col))) }
        $whs = @(); $pkv = @($u.pk)
        for($i=0; $i -lt $pkCols.Count; $i++){
            if ($floatSet -and $floatSet.Contains([string]$pkCols[$i])) { $whs += (Get-KeyCol $pkCols[$i] $floatSet) + '=' + (SqlLit $pkv[$i]) }
            else { $whs += (SqlId $pkCols[$i]) + '=' + (SqlValFor $pkv[$i] ($binSet.Contains([string]$pkCols[$i]))) }
        }
        $pkDesc = ($pkv -join ',')
        if($sets.Count -eq 0 -or $whs.Count -eq 0){ [void]$skipped.Add($pkDesc); continue }
        # The update used to count as done whatever it matched: a row deleted on the target since
        # the comparison, or a key that could not be matched, was reported as updated. This stops
        # the batch (error 1172, both servers) unless the key matches exactly one row.
        [void]$stmts.Add('SELECT 1 FROM (SELECT 1 AS x UNION ALL SELECT 2) nobs_guard WHERE (SELECT COUNT(*) FROM ' + $obj + ' WHERE ' + ($whs -join ' AND ') + ') <> 1 INTO @nobs_one_row;')
        [void]$stmts.Add("UPDATE $obj SET " + ($sets -join ',') + ' WHERE ' + ($whs -join ' AND ') + ' LIMIT 1;')
        [void]$pkDescs.Add($pkDesc)
    }
    $log = New-Object System.Collections.ArrayList
    foreach($s in $skipped){ [void]$log.Add("SKIPPED (no columns/key) id=$s") }
    if($stmts.Count -eq 0){ return '{"ok":true,"log":'+(J-Arr $log)+'}' }
    $script = "START TRANSACTION;`n" + ($stmts -join "`n") + "`nCOMMIT;`n"
    $my = Get-Mysql $tgt
    $cnf = New-Cnf $tgt -Tool $my
    try {
        $r2 = Run-Stdin $my @("--defaults-extra-file=$cnf","--comments") $script $null
        if($r2.exit -eq 0){
            foreach($d in $pkDescs){ [void]$log.Add("OK  updated id=$d") }
            return '{"ok":true,"log":'+(J-Arr $log)+'}'
        } else {
            $fe = FirstErr $r2.err
            if ($fe -match 'Result consisted of more than one row') { $fe = 'a row to update no longer matches exactly one target row (changed or deleted since the comparison, or its key cannot be matched) - ' + $fe }
            [void]$log.Add("FAILED : "+$fe)
            [void]$log.Add((Get-BatchFailureNote (FirstErr $r2.err)))
            return '{"ok":false,"log":'+(J-Arr $log)+'}'
        }
    } finally { Remove-Item $cnf -Force -ErrorAction SilentlyContinue }
}
# Inserts EVERY missing row (source rows absent from target), not just the first 2000 that fit
# in the interactive review list. Unlike Api-CompareRows/Api-CompareRowsApply, this never sends
# the row data to the browser at all - it fetches a chunk of missing rows from source and
# inserts that SAME chunk into target immediately, chunk by chunk, so the full amount of data
# moved is not limited by what's practical to render as a checkbox list. Still insert-only.
#
# Deliberately not wrapped in one big transaction across every chunk: each chunk's INSERT is
# already its own mysql.exe invocation/statement, which MySQL/InnoDB only ever applies
# all-or-nothing - a chunk failing partway through can't leave that chunk half-inserted. What
# continue-on-error across chunks buys here is that ONE bad chunk (say, a duplicate key from a
# row someone else inserted since the scan started) doesn't abort inserting the rest of what
# could be tens of thousands of otherwise-good rows - unlike Api-CompareRowsApplyDiff above, this
# never touches an existing row, so a chunk that fails simply leaves those rows still missing,
# not corrupted.
function Api-CompareRowsInsertAll { param($data)
    $src = Resolve-SavedConn $data.sourceConnName; $tgt = Resolve-SavedConn $data.targetConnName
    if(-not $src -or -not $tgt){ return '{"ok":false,"error":"Connection not found."}' }
    if($tgt.readonly){ return '{"ok":false,"error":"Target connection is read-only / safe mode - blocked."}' }
    $rid = [string]$data.requestId
    $table = [string]$data.table; $srcDb = [string]$data.sourceDb; $tgtDb = [string]$data.targetDb
    $pk = Get-TablePkCols $src $srcDb $table
    if(-not $pk -or $pk.Count -eq 0){ return '{"ok":false,"error":"Table has no primary key - cannot compare rows."}' }
    $pkList = ($pk | ForEach-Object { SqlId $_ }) -join ','
    # Every fetch below is registered under $rid (via Run-Query2's RequestId param) so Cancel can
    # actually KILL the in-flight mysql.exe process for large tables, not just stop between chunks.
    $srcR = Run-Query2Bulk $src ("SELECT $pkList FROM " + (SqlId $srcDb) + '.' + (SqlId $table)) $null $rid
    if(-not $srcR.ok){ return '{"ok":false,"error":'+(J-Str $srcR.err)+'}' }
    $tgtR = Run-Query2Bulk $tgt ("SELECT $pkList FROM " + (SqlId $tgtDb) + '.' + (SqlId $table)) $null $rid
    if(-not $tgtR.ok){
        if($tgtR.err -match '1146' -or $tgtR.err -match "doesn't exist"){ $tgtR = @{ ok=$true; rows=(New-Object System.Collections.ArrayList) } }
        else { return '{"ok":false,"error":'+(J-Str $tgtR.err)+'}' }
    }
    $tgtSet = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach($row in $tgtR.rows){ [void]$tgtSet.Add(($row -join "`u{1}")) }
    $missingRows = New-Object System.Collections.ArrayList
    foreach($row in $srcR.rows){ if(-not $tgtSet.Contains(($row -join "`u{1}"))){ [void]$missingRows.Add($row) } }
    $missingTotal = $missingRows.Count
    if($missingTotal -eq 0){ return '{"ok":true,"missingTotal":0,"inserted":0,"cancelled":false,"log":[]}' }

    $cancelled = $false
    $chunkSize = 200
    $log = New-Object System.Collections.ArrayList
    $inserted = 0
    $srcBin = Get-BinaryColumnSet $src $srcDb $table
    $tgtBin = Get-BinaryColumnSet $tgt $tgtDb $table
    $srcFloat = Get-FloatColumnSet $src $srcDb $table
    if($null -eq $srcBin -or $null -eq $tgtBin){ return '{"ok":false,"error":'+(J-Str "Could not read the column types of $table on both sides.")+'}' }
    $my = Get-Mysql $tgt
    $cnf = New-Cnf $tgt -Tool $my
    try {
        for($fi=0; $fi -lt $missingRows.Count; $fi += $chunkSize){
            if($rid -and $script:CancelledCompares.ContainsKey($rid)){ $cancelled = $true; break }
            $fEnd = [Math]::Min($fi+$chunkSize,$missingRows.Count) - 1
            $chunk = $missingRows[$fi..$fEnd]
            $where = Get-PkWhere $pk $chunk $srcBin $srcFloat
            $fr = Get-ExactRows $src $srcDb $table $where $rid -Keep $pk
            if(-not $fr.ok){ [void]$log.Add("FAILED (fetch) rows "+$fi+"-"+$fEnd+" : "+$fr.err); continue }
            # A row that cannot be read back by its key is not copied; say so rather than
            # reporting the chunk as done.
            if($fr.rows.Count -ne @($chunk).Count){ [void]$log.Add("FAILED (fetch) rows "+$fi+"-"+$fEnd+" : "+(@($chunk).Count - $fr.rows.Count)+" of "+@($chunk).Count+" row(s) could not be read back by their key and were not copied") }
            if($fr.rows.Count -eq 0){ continue }
            $cols = @($fr.columns)
            $colList = ($cols | ForEach-Object { SqlId $_ }) -join ','
            $obj = (SqlId $tgtDb) + '.' + (SqlId $table)
            $valuesSql = ($fr.rows | ForEach-Object { Get-ValuesTuple $cols $_ $tgtBin }) -join ','
            $sql = "INSERT INTO $obj ($colList) VALUES $valuesSql"
            $r2 = Run-Stdin $my @("--defaults-extra-file=$cnf","--comments") $sql $null $null $rid
            if($r2.exit -eq 0){ $inserted += $fr.rows.Count; [void]$log.Add("OK  inserted "+$fr.rows.Count+" row(s) ("+($inserted)+" of "+$missingTotal+" so far)") }
            else { [void]$log.Add("FAILED (insert) rows "+$fi+"-"+$fEnd+" : "+(FirstErr $r2.err)) }
        }
    } finally { Remove-Item $cnf -Force -ErrorAction SilentlyContinue }
    if($rid){ $null = $script:CancelledCompares.TryRemove($rid, [ref]$null) }
    '{"ok":true,"missingTotal":'+$missingTotal+',"inserted":'+$inserted+',"cancelled":'+($(if($cancelled){'true'}else{'false'}))+',"log":'+(J-Arr $log)+'}'
}
# Same reasoning as Api-CompareRowsInsertAll above: insert-only, each batch already its own
# atomic mysql.exe invocation, continue-on-error across batches so one bad batch doesn't block
# the rest of a large reviewed set from landing.
function Api-CompareRowsApply { param($data)
    $tgt = Resolve-SavedConn $data.targetConnName
    if(-not $tgt){ return '{"ok":false,"error":"Target connection not found."}' }
    if($tgt.readonly){ return '{"ok":false,"error":"Target connection is read-only / safe mode - blocked."}' }
    $db = [string]$data.targetDb; $table = [string]$data.table
    $cols = @($data.columns); $rows = @($data.rows)
    if($cols.Count -eq 0 -or $rows.Count -eq 0){ return '{"ok":false,"error":"No rows to insert."}' }
    $colList = ($cols | ForEach-Object { SqlId $_ }) -join ','
    $obj = (SqlId $db) + '.' + (SqlId $table)
    $binSet = Get-BinaryColumnSet $tgt $db $table
    if($null -eq $binSet){ return '{"ok":false,"error":'+(J-Str "Could not read the column types of $db.$table.")+'}' }
    $log = New-Object System.Collections.ArrayList
    $batchSize = 500
    $my = Get-Mysql $tgt
    $cnf = New-Cnf $tgt -Tool $my
    try {
        for($i=0; $i -lt $rows.Count; $i += $batchSize){
            $endIdx = [Math]::Min($i+$batchSize,$rows.Count) - 1
            $batch = $rows[$i..$endIdx]
            $valuesSql = ($batch | ForEach-Object { Get-ValuesTuple $cols $_ $binSet }) -join ','
            $sql = "INSERT INTO $obj ($colList) VALUES $valuesSql"
            # IMPORTANT: pipe the SQL via stdin (Run-Stdin), not as a "-e" command-line argument
            # (Run-Proc) - a batch of rows easily exceeds Windows' command-line length limit
            # ("The filename or extension is too long"), especially for wide tables.
            $r2 = Run-Stdin $my @("--defaults-extra-file=$cnf","--comments") $sql $null
            $batchNum = [int]($i/$batchSize)+1
            if($r2.exit -eq 0){ [void]$log.Add("OK  inserted "+$batch.Count+" row(s) (batch $batchNum)") }
            else { [void]$log.Add("FAILED batch $batchNum : "+(FirstErr $r2.err)) }
        }
    } finally { Remove-Item $cnf -Force -ErrorAction SilentlyContinue }
    '{"ok":true,"log":'+(J-Arr $log)+'}'
}
# Marks a compare operation's requestId as cancelled; the running loop (Compare-TableSets,
# Api-CompareRows, Api-CompareRowsDiff) checks this between iterations and stops cleanly.
function Api-CompareCancel { param($data)
    $rid = [string]$data.requestId
    if(-not $rid){ return '{"ok":true}' }
    # Mark cancelled first (so any loop that's between chunks stops on its next check), THEN
    # actually kill whatever's currently running under this id - a compare's slow phase is
    # usually one single huge SELECT, not a chunk loop, so without this Cancel would only ever
    # take effect once that one call finally finishes on its own.
    $script:CancelledCompares[$rid] = $true
    $entry = $null
    if ($script:RunningQueries.TryGetValue($rid, [ref]$entry)) {
        try {
            $entry.Cancelled = $true
            if (-not $entry.Process.HasExited) { $entry.Process.Kill() }
        } catch {}
    }
    '{"ok":true}'
}
function Api-CompareSchemas { param($data)
    $src = Resolve-SavedConn $data.sourceConnName; $tgt = Resolve-SavedConn $data.targetConnName
    if(-not $src){ return '{"ok":false,"error":"Source connection not found."}' }
    if(-not $tgt){ return '{"ok":false,"error":"Target connection not found."}' }
    $srcDb = [string]$data.sourceDb; $tgtDb = [string]$data.targetDb
    if(-not $srcDb -or -not $tgtDb){ return '{"ok":false,"error":"Pick a database on both sides."}' }
    $srcCols = Get-SchemaColumns $src $srcDb; if($null -eq $srcCols){ return '{"ok":false,"error":"Could not read the source schema."}' }
    $tgtCols = Get-SchemaColumns $tgt $tgtDb; if($null -eq $tgtCols){ return '{"ok":false,"error":"Could not read the target schema."}' }
    if($null -ne $data.tables){
        $keep = @{}; foreach($tn in @($data.tables)){ $keep[[string]$tn]=$true }
        $srcCols2=[ordered]@{}; foreach($k in $srcCols.Keys){ if($keep.ContainsKey($k)){ $srcCols2[$k]=$srcCols[$k] } }
        $tgtCols2=[ordered]@{}; foreach($k in $tgtCols.Keys){ if($keep.ContainsKey($k)){ $tgtCols2[$k]=$tgtCols[$k] } }
        $srcCols=$srcCols2; $tgtCols=$tgtCols2
    }
    $rid = [string]$data.requestId
    $cmpResult = Compare-TableSets $src $srcDb $srcCols $tgtCols $rid
    if($rid){ $null = $script:CancelledCompares.TryRemove($rid, [ref]$null) }
    $tj = New-Object System.Collections.ArrayList
    foreach($t in $cmpResult.tables){
        $sj = New-Object System.Collections.ArrayList
        foreach($s in $t.sql){ [void]$sj.Add('{"stmt":'+(J-Str $s.stmt)+',"checked":'+($(if($s.checked){'true'}else{'false'}))+',"kind":'+(J-Str $s.kind)+'}') }
        [void]$tj.Add('{"name":'+(J-Str $t.name)+',"status":'+(J-Str $t.status)+',"sql":['+($sj -join ',')+']}')
    }
    '{"ok":true,"tables":['+($tj -join ',')+'],"targetReadonly":'+($(if($tgt.readonly){'true'}else{'false'}))+',"cancelled":'+($(if($cmpResult.cancelled){'true'}else{'false'}))+'}'
}
# Deliberately NOT wrapped in a transaction: these are schema-diff statements (ALTER/CREATE/DROP
# TABLE), and every one of them is an implicit-commit statement in MySQL/MariaDB - a
# START TRANSACTION here would be silently ignored the moment the first DDL statement ran, giving
# false confidence that a failure partway through could be rolled back when it can't be. Running
# each independently and reporting OK/FAILED per line (as already done below) is the honest
# behavior given that constraint - a half-migrated schema is visible in the log, not hidden by a
# rollback that was never actually possible.
function Api-CompareApply { param($data)
    $tgt = Resolve-SavedConn $data.targetConnName
    if(-not $tgt){ return '{"ok":false,"error":"Target connection not found."}' }
    if($tgt.readonly){ return '{"ok":false,"error":"Target connection is read-only / safe mode - blocked."}' }
    $db = [string]$data.targetDb
    $stmts = @($data.statements)
    $log = New-Object System.Collections.ArrayList
    foreach($stmt in $stmts){
        $r = Run-Query2 $tgt $stmt $db
        if($r.ok){ [void]$log.Add('OK  '+$stmt) } else { [void]$log.Add('FAILED  '+$stmt+'  :  '+$r.err) }
    }
    '{"ok":true,"log":['+(($log|ForEach-Object{ J-Str $_ }) -join ',')+']}'
}

function Api-ConnGet { param($data)
    $c = Load-Conns | Where-Object { $_.name -eq [string]$data.name } | Select-Object -First 1
    if(-not $c){ return '{"ok":false}' }
    $pass=''
    if($c.pass){ try { $sec=ConvertTo-SecureString $c.pass; $b=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec); $pass=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($b); [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) } catch {} }
    $ro = if($c.readonly){'true'}else{'false'}; '{"ok":true,"conn":{"host":'+(J-Str $c.host)+',"port":'+(J-Str $c.port)+',"user":'+(J-Str $c.user)+',"ssl":'+(J-Str $c.ssl)+',"sslCa":'+(J-Str ([string]$c.sslCa))+',"password":'+(J-Str $pass)+',"accent":'+(J-Str ([string]$c.accent))+',"env":'+(J-Str ([string]$c.env))+',"readonly":'+$ro+'}}'
}
function Api-ConnSave { param($data)
    $name=[string]$data.name; if(-not $name){ return '{"ok":false,"error":"name required"}' }
    $c=$data.conn; $enc=''
    $before=@(Load-Conns)
    $savePw = $true
    if($data.PSObject.Properties['savepw']){ $savePw = [bool]$data.savepw }
    if(-not $savePw){
        $enc = ''   # explicitly do not store / remove the saved password
    } elseif($c.password){
        $sec=ConvertTo-SecureString ([string]$c.password) -AsPlainText -Force; $enc=ConvertFrom-SecureString $sec
    } else {
        $prev = $before | Where-Object { $_.name -eq $name } | Select-Object -First 1; if($prev -and $prev.pass){ $enc = [string]$prev.pass }
    }
    $prevPrimary = $false
    $prevObj = $before | Where-Object { $_.name -eq $name } | Select-Object -First 1
    if($prevObj -and $prevObj.primary){ $prevPrimary = $true }
    # accent colour / environment label / read-only flag: use provided value, else keep the previous one
    if($data.PSObject.Properties['accent']){ $accent=[string]$data.accent } elseif($prevObj){ $accent=[string]$prevObj.accent } else { $accent='' }
    if($data.PSObject.Properties['env']){ $env=[string]$data.env } elseif($prevObj){ $env=[string]$prevObj.env } else { $env='' }
    if($data.PSObject.Properties['readonly']){ $ro=[bool]$data.readonly } elseif($prevObj -and $prevObj.readonly){ $ro=$true } else { $ro=$false }
    $list=@($before | Where-Object { $_.name -ne $name })
    $list+=[pscustomobject]@{name=$name;host=$c.host;port=$c.port;user=$c.user;ssl=$c.ssl;sslCa=[string]$c.sslCa;pass=$enc;primary=$prevPrimary;accent=$accent;env=$env;readonly=$ro}
    Save-Conns $list
    '{"ok":true}'
}
function Api-ConnDelete { param($data)
    $list=@(Load-Conns | Where-Object { $_.name -ne [string]$data.name }); Save-Conns $list; '{"ok":true}'
}

$Token = [Guid]::NewGuid().ToString('N')
$Html = @'
<!doctype html><html><head><meta charset="utf-8"><title>NOBS SQL Editor</title><link rel="icon" type="image/png" sizes="32x32" href="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAHOklEQVR4nH2XW4idVxXHf2vt/X3nnLlkMiFJ05nESdpUCtYa9cELEUxtYtXYQGEktdDHvEmgr4IIvhcC2kjfBB9KU9BIHyRF02hBCr2kqa22WNvcJpfm3pkz5/LtvXzY3+WcTPHAN/Od77D3f63/+q/1358AsLjoOHYsbPnWngXNssNq7DdsAZFMQBABARGqPwjp3gABDLAYMTMsRmKM5XcMsyEiZ0XlZYl25PI/Tp6tMKW6mdv9yEFVf0RUN5sZmPH/gJF0b0L6GDV4HYAZaa+0RpwDi1fN4uErr/31BRYXnQDM7967qJl/sVwcREUREUloNVgNXD+n/hiAGRatyT4aliLDzAyI6pwT74mh+MnlU68ck7nv7Nsm2BlRncEsouIasDJnuTsI6iCsZCUxXV6xYcLM6uDSIgvivILdlsIe9ir2jPhsvRVFEBW3BhgQkTXAdUlKFgRJINFAYxmcIqPlBBB1WAya5euN8Iw30QOCmTjRps4VWAOMgIqiqrX4rKRfK40YhBCIwUAVISbsMoZ6T0TBDJUDXpRtYIJoDZzq3NRYVVB19AYDVvsDDMgyj888AKEIDEMBBp1WTu4zQggpe2oN1rqp1eV0mxdRPy6wJuMUiyPEwO2VZRa2zrP7a1/h6w8+yNYt9zA50QGElW6XC1eu8Na/P+C1t0/z8fmLTLbbqHMpkJIdq1mtS+zlC9/7od2dsVS1V2VYFHQ6bX729FMc3LcXnZ7g0mCVm/0evVAA0Hae2bzFva0J4mddXjjxCkd+93u63VW898QY624ZL6sgC3t/ZA01IwIr6+yc8ttf/YK9u3Zx4tOLXOt12Zx3mMlyWuoA6MfA7eGAq4NVNrYn2LdpnhNvn+bQz39JCCHtZTbCrtRJ+rG+ponOOcft5WUef3RPAr90jqDCE/feRy8WpPlidQeIQFs9J68vceLSOfZ9dRd7vv0N/njiL8xMTxNiKFt5PAhNkSRlo+kSVUQVA2ZnZghmzOQtuqHgxrCfmBHBi+JFcSVbN4Z9urFgXd4imLFxdjYJUBOYyOj+KVmPNJSP6yDVy8zoi7BzYh3eKX+7cYmWOiadJy9LMIiBlVDQj4EHJtexvTXFoKK9BEK1pn0UyzfgI9O1elYuEqAfI/dPrGNHZ5prwz53hgNWYwBgQ9Zi+8Q0G7MWKkJ3OGSyrupI9mNdlu792JQbHbtl5CbUjtcv1bwxa7M5b9N2aQ70QkE0GFoEs9oda02pjO89ogOtplnT+FQ0YAJelQyI5cZSqj53juc/PMPzH54hd45+DPXv0YyMtDZlqiCKiK7Rga+wRwqPlOAtdVzorXBx2GODz1ixUOpU6IXA7nvmSwYCKoJhRINpn3Nh2ONCf4XcuTEG7taBB6u9wixpwSTxEjBmsxZvfnad+yRn59R6zIyBRXJVlrrLAHxx3SzRjFwcIsJ/lm/xMQNmsxaxFLNo0+ajOvBmVREEkTKYkswiRqZcxqPrt/DnpU/47+oyc+0JNmQtNrU69EIouyByfdDjxrDPUq9LEQOPze3gjSwnkOgmVvjjTuprfKyxN6G0r9RibXXs2zjP1WGPC70VlvpdWL7JpaIHwMnrSwCs9zkPTc+yOWvTUcfAIuq0EfUaly0ZqFVbBRDBNB0unAjBjG5RsCnvMNeeTMxkGb/54DQAj+9YYHk4xKsyjJHucEjbDK+uoT/KGHDV7k0JyiiSABO4ADfv3CErBTaMgYGVtA8iT9//JQBuDPoYRj+E5P0YXoTrd+6grpwlqmtbXUBHE0+HjKSDEAOTnQ4nX3+DV995h7mpaVQVC5auGOkXBf2iaM5/0VBV5qamOfXuu7z65ltMTU6m8lftqImRNGcU2fr9/SN2PP6/tuN2m8NPHeTAI99l48wMAgQgWhpMKoorE7h25zZ/OvV3fv3iS6wOBuRZlhKsan+XDmTrYz9OxI+N5Oa7qhJiZLm3yo75eb758EN8+YGdzG/ezNTkBADL3S4XP73Gex99xOv/fJ9PLl9mqtPBeT9iw2sFKAKy9QcHhpUpNWYkY4tUFHVKfzBkddAHETLvyTIPIhQhUISAiNJpt2i3WsTyNCxrgEd1QOFF5Lw43V5OI1l7aEhTMZqRt3LanXZySRqAdskUIkQzglntpqPTr5kBmHgHZudVVI+r94IQpToPVDNbKsFoefSlBIhlXRvDCiUwkvw/2e/oPlqfN1CJmmUiyHEtXHg2hnBLfaZAWHNoqA8TowrW+nkKQhtlVxZ+9z5SJxbUe7WiuKVen9Wl48fP4+SQ5ploljmQICI2smAcWD4voDKIGngkoLqjxBCCeu9cKxdROfTe0aPnlcVFd+4PLx0Lg/6TqFx17ZYT76XOsqRytDVr4NpmR7KvmRl/rt6La7cdTq8W/f6T7x89emyxejmt3pC3P/HTBc3ksIjsN2xBIGuEuUbBnztaR1u5vDcTHarqWRF9OVo48q/nnqtfz/8HqCQ+Gd1SFxwAAAAASUVORK5CYII="><link rel="icon" type="image/png" sizes="128x128" href="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAIAAAACACAYAAADDPmHLAAAw3klEQVR4nO19e5QexXXn71Z3f4+Zb0YjaUboLSEJYWSwAWMgxmYcAgZsnKztMyZ2SOJzYvuPLNkcO4/1sXdX0SZOyNn1Y4PN2egcxyZONgtKOJuYrMFgs8IGY4zDewAhgYTeo9doXt+ju+vuH/2qqq7+vm9GMwInlI7m675dj1v1u/fWrUdXE84sEIaHHezcGSSEoeHhWoUrl4Tgywn8DoA3s8RKEAYIVLXnQnFmWs4mRbvNP6ZcHPVGz4lSAjNbMyQGmDiixXGYOYrCEZ2ZAU4iR9dJdhzfJPcxJY2XhSRvhcKoE2GcwYcA2kUkfiYJj5MXPnls586pNOLwsIudO0MYOc4mUOcoBelGRgR27AgBYNMNN5RnpuR1RPxhAMMANpDjAGojsIXHOQCfj2JKRf5GuzLyikC1xKWYfWS8RxCSdk+cgJ3EV4QlxVqVDAbrmSMtgrK807YRInouJRj8CpHYSYLu6at5D+y+774mAGBkxMGOHRJzEITZC0BUWAgA5/zCdctcF79FwCdIOJtBBOYQLCXAHMYNTnFtlFaeR+BzNbDkbQFejZQodi6hoaysCDExx8BTCjpSWoJjJgykCkNcplpwmnV8QZGB4SgxACKHhAAJJzIiMtxFDn0LgfjG0R8/MAZAw6bbMDsBiAtYfeWVVZT7bmWJ3xOOcw5LCZZhJIFEBEBYs44RPHsaD027i/JPFDt7kAGtmeZYd63aHkfOcNT6gywHVgRAzVntidQ89HrLWCCIHEeQcMChPArBX/L86a8deOyx+myFoFsBSFtm5buv/SUi+opw3Is4DMDMAYgFQKIwy3kBXrk5I+DzINslIqJzppGZ+Y6126rtaXeQgZ/SEqBJScN6eaYkcJLAYJMACSYJh1zhuOAwfFYCnxn70YPfL6ikNYhOEbB1q4gzotXvvvbPhBAPEtFFMvADBjMIbgS+buUzTiN6W/DJcqvR4hsbzUxOSY9jlEd6/CyVjQ8lbpqdEtfggdL81SzihKRGzfMWkYy8LXXMfijpVQUEXDCz9P0ARBcJQQ8uv/raP4tjc4xd29DeAsTmZMU7hgdFb+lvhONeL31fAhwx0C6LBfPsM0J3/bxhIZRCOGd3U7Ur0CHWFTYZKcSOrt7PZ85v1gOwZi2y/DPLYJaZpKZcQxn1ZpYggvA8IcPwfkGtWw7v3Hm8U5dQLAAJ+Fddu1Y49F0h3C0y9H0AXtvkc3XwFhp4Cx+sml41u9TLJ0MYFA8+ihCPBDiNm40aMmFRfYQsXZYnKBGMDgJoAz5fcd/xPI/DYBQh33j4kQdfaycEdhOxdatIwHcc8YAQzhYZ+AFS8C3mPjZveQtWZGaNKObDnECY4Bsm1uBDS1XEh1Felp1i2oViwynv22aDHIPddv2a1i1Y6k0pB7lm0SJo1ab4Pzzp+wEcZwu74oEVV127Fjt2hEXdgU2GBABefeX7FnOJfxiBHwQgcm0ZnP2xfFamjY98tsV8JGa32AwqPlqqnNGQLn1mTPikFiA1/cqDxBpQMkdAqbVQYqb5R48NK2UVQINpIoARCNd1WYajThPvOfDY907FqaUa1ZQKwsgIAVuJPXmXcNxi8GOJnrPGF0i+eaOTbdqm09pqvJlUqKUocUzB1B7bLE9GoxxJ6JosbPVO0iYOnqUtcvxHGm8FP3rsysAPyHW3BBXcha1bY2z1FLoAxLN7K9/9yBeFV7pWBr6fAz8FngweZwM8oDdAPlFn4AETeOqCj4RGcYNnjUu2CHmubA1OpCUnQbGPbOPDALQQ+DwfCY2M8lQ+tCCEKwPfd9zStct3PvpF7NgRYmREwzxLkUzyvOe6q+E4OzmUAcCOFqcbc2/ByZLATsuRzVrmMyQLzcZHQjNLajdQJiDnnadjejLuNccQuW4g8wMNhzAN6roBaZwlcwG25mjXRpRkTAjJcVwpafjIQ//3YdUpFGmSLVt43fBwhYHtUX8lMxGejYNX+LjYlClPM1phP6/En7XGW0uyJqKkPGFkVjCWt/NB2Y2m8YC177ZqPLrX+LhMwzoTGAJMAMvt64aHK9iyJRXrSACGhx1s2yZ9Wb5VuN75HIYBiMScPfuugTfyLmiAQs/+DIAv4i2qnl5e+/yL2iKvGBnwpKpeYb0Tz94gdgu8mrdgGQZOyT2/Kaq3Yts2ieFhR4u2Ynh4qZDlF0FYDGYCGUWblSq6JctDi8bnriwKPxfPPp+dLWM9EreJlTyPLjJvnVISZ12BQVPn/sEEbYLIXEhSFolIXRVM8iust22W1YhLcQEkGMynIN23HN557wkAELEksJDlTwrPWwqGJBX8bjRei2KqUz6RTp6Fxnfj2bfV+JhulJl59h20LTbFmmqkRsRW78gZtHv25ux5bB8Knd18gxdqvL39iZilU/KWQgSfBMAYHnYIAG264YZSfTp8UTjOOpaSAYiF1fikUkYw+9Z8IVY+9KSdNb5dmTD2BwDIVgFBufF9NoxXZwHTx9A3higp02niyBJEReobSFLVNaas7dPCxe2fNSFLEg6x5H09JX7L7vvuawkAXJ8Jr3Fcbz2HIYMgfh6HdLPR+EI+EnouBwsf6oWmdAVDuoLyCh08VXEUK5OfHSzU+OifRhOCpWThueunQroGAMfTEvRRCGIQydkDbzNvswWejNvugc9SmmEWwHcnB0pchWdzEic3/I/KMy3U7Bw8YzKpA/DIAR/To7aVIGJH4qMAQCvecVOPqLVGhXDWsZQSiX9qCryZWY6mVM6kWfHRNd5SSDGu3UewlmcpODXdpNA008vZRTYFrOSVOoKczA4j6yYUBy/JQe0CUoY5Nz2gPMnX2YJJvpq59pAkHMEc7uOKs8V1a8GlTGKt3vcryRca+PSiqGK27AoiFPFmsR42YSOzBoLSSZhUCOLfJG4KjCYkgLI2nBZAJi1pC8uKH6l0QjyKyMebBfBJmQIsmUis5UZwqcvAlSQc4tAPQeRo2RqFmJd2SM4AeMttZ+CLyuzSEiTR2FZHO40I9iVbouxGoaXRNCUmfTYwppE6q6jxYaPNCvgsFbMk13VI8pUugy8jYjX5HIG3cjN34LWkCwB8SlJQ7FBvU8nTmxzCSPt3wwgU5G3YkzS/4vbPN2EXwGs0Akm6zAXReWBOhpX50uYB+DT+ggLfHR8ZycaHpd6KuQcZtjqx0ybKiYUw8zZNPZudTns+CoG3VMcOvFJwZMHOcwlyBUGAU5fUluFsgLfE7xL4DNezDTwybdPa3qCpizW5Pj7ReraYeqO8Arch03jOtb+N9XYW0A58xilDAqAVLhENxNuRikTGQl4o4LuK0IEPG/CUgk9JHDOa2vfGlxo4Jh8piJkl0Dx4opyA6Fqv+hCdgdez6hL4hA+TB4DABCYecJG8rmW3RQa5MxCvN/DZ1qio8SQzpJQIQ4mQJaSM5ueZpeZkEwkIIggh4AiR/ka7RghghmSp7dCJMLZ1Aaa3H8dXlwW0C7MJkrp00x6zAj7LGwwiVN15BT690OyoJV0XwFsf5fkgQRAxSGEYotlqwQ8ChFJCEKHkeaiWy+iv9aK3pwc91QoqpRIqlQpE4qgxo95ootlqYaZRx/RM9H+m2UQr8CGZ4ZIDz3PgeR5cx4kEQiqLPemQrsiz16YS7G2UWAd9z5m13mqZs7HOOjwE14iVv5or8JbbzsAXlanTKNZUBtBstdBoNgEGarUerFu1AueuXo1N69Zi/aqVWHnOEAYXL0Z/rYaeSgWlUgSg46hTdowwlAjCEK2Wj5lGAxNTUzh+ahyHxsaw9+Ah7Nm3H68eOIhDY8dw6vQEiIBKqYxSqQQiQErVOkRtRAVdQFKm2QUQcbGpt8wfzAb4/G2cx5prbmSd1C7DOQKvJT1z4Fu+j+lGA65wsHblclz61gvwzosuxIXnn4e1K5ajv1aDB4IEEIIRSokwDBHGIHG6fVsvJuk6HCHgOE70C4IA4IMxMTWF1w4fwXO7XsZPn30eT46+gH2HjiAIQ/RWyvC8ElhKRBOqiGb6KPpNl37NGUO1RdgUgCyoL7HqOFnatAvg058119zIswFez3ChgNfLTICvN5toNJtYuWwZhi+/DNdddSUueesFGFo0AALQ4hDNlo8wDPVtVJQ5f0VcJCFZ0Ut/Y0khIjiOg7LnoSQcMIBjp8fx5PMv4oFHf4ydjz+Bg0fHUC2XUSmXI39BSmXlD/FLJNnUMCm0pPAIjPyMYfKOqNpscwLevFybWIA36JDOcRw0Wi3UGw1csHEDbv7ADbjhPVdhzbJlCAHUW034QQAwg4RInb8kRFPu6ex9VyFJX5QXSwkQwXNdVEtlOAD2HxvDfQ8/grv++T6M7tmDaqWCSqmMIAwUrUcqDNnW8BR1ZLGUIUhiQTTmzhz4FJ21v/T+fLvMC/BdRVDIhpWJzfH45CTWr1qFT330w/iV667Bkt4apv0Wmq0WQARhrKrJeDhGAAQRXBJwieAkceN4tu45oUtmhMwImBGwhIwtApG+WMLMkPHmz3KphF6vhJPTU/jHB3+A7Xf9A149eBADfTWwjPKkdHEIKagaH0YXQMlz09E0mS5w8PLxlJuk28sJwBtgSOc4Dlq+j5bv45ZfuQm33vIxrFiyBBPNBvwggBNrehIS0B0ilIWDUnyoQj0McMpv4XirgbFWHcdaDYz7LUyHAabDACFHfbVDAr2Oi17HxYBXwlCpgmWlKgZLFSz2Sqg6ka/ckhJNGSKMZk5zwhBKCc910V+u4PCpk7j923+Hb/+f76DkeSh5LsIwjOMi7fz1t4kJTIgExRwIWNt/7sCn1FQA3gBDOgBwXAcz9Qb6a734k8/8Dn756vdgstVE0/ej4ZcSZKwZVcdFWQhMhQFenZnE05Mn8czESeyZmcBYq4563PCeEKjEAlIWDpyYgRCMpgzRkhINGcKPnbiq42BZqYqNPf14W/8SvL1vCc7t6UPNcdGUEvUwOhlHGEIchCHKnoe+Uhn/9PAP8YUv347TU5PoqVQQBBLqPEF+HkFBnsiwAHqbngnwCYHWXvuB/CigG63vCLy1VDstLs8RAjONBpYPDWL7H/8XXLRxI05MT+U0PumLe10PAsALU+O4//hB/PDkERxoTKPiOFhT6cV5PYuwoacPa6q9GCpV0O+WUBUuSiLqFtIFm9jct6REXQaYCFo41mpgf30ar8xM4uWZ09jfmEYjDLG60ov3LFmO6wdX4YLaACSA6cDP+wuxRVjaW8Mze/bgU/9pG46MHUO1UkEoQ8PPU29ib1+1AJZNoVbwZwF8erf22g/wrIAH5ujZt+8CiAh+EGBRrRff/u9/hvPXr8epqUl4rv5ikmSGJwSqwsXjp4/hzoO78NPx41haKuNdi8/BuwbOwQW1RRgsVVAWTpomjP/LZBDG+haLBECByF9IfAYAaMoQx1sNvDB1Go+OH8Wjp47iRKuJdw4M4jdXbcbli4ZQlwH8ePJJDX4QYHGtDy+9uhcf//3/iNOT0/BcNy6f0+Vf7QWUiBT9EDQL0VnruwM+pa679gO8sMBrCQtpRIRGs4m//JOteN8Vl+O4BfyQGb2Oi/Gghf/x6nO499h+XNy/FB9bsQFXDCzDYq+EkBlNKeHHzlvKLQGqjpocsXbNmlIKIngkUBYCDhFO+S38ZHwMf3f4FTw1cQI3Da3B7557IQbcEqbDAI5FCAZrfbj/sZ/gk1/4I1QrZbDM5gKi18Mpx0k68GMTojbmPmcMOijeuutuyk0+5SNrvU67CNZCOtFc18H4xCR+7YMfwJ9/9j/gxPSUtb/vcVy8Up/EZ0cfQ0NKfG7j2/CLS1fCATAThvBZato8n0G1Gh4J9DgOQgAPnTiE2/Y8g4oQ+PKWK7Gh2oeZMLD6BYO9Nfz+l76Kb//jvRjo78ucwvQPYv+AUjqpG09m1c93h0n2oiCZmcZ5tAVfi6AXkhuy5GkRiRCEEv21Gn79Qx9Ew9J4DKAsHBxp1nHr849iaamCuy75RVw3uArTgY/TgY8QnBvqzWcgRJbAIUIIxunAx3Tg47rBVbjrkl/E0lIFtz7/KI406yjHE0VqEESohwF+88O/jP5aDUE8l5BWMG3/rLVJoymqrQkEWXDqjEmSv+gO+LYRCgvRa2JGi/IVQqDeaODtF2zGpnVrUW+1IIT+0jLH/f6X9z4LAuGrF1yJfreEU34rBWUhQC8KBKTCdspvod8t4asXXAkC4ct7n4UnhL4uAET1bLWwad06XLzlLajXG9EiVpLhGQOPlJbvFvLAJ4XoLd0N8IUOXhHwZETTaSQIQRjgvHXrIs2R2vkFYAAVx8He+iQeOXUUn1h9HgZLFUwFPlxbF3OWg0uEqcDHYKmCT6w+D4+cOoq99UlUnLwVYClREQ7OW7cWfhCABKVtZALPswbexEWnmcAnQeTj2oBPIpmP2lgCC/C5N1oS5oiwfvXKjK4EZoZLAkebdYTM2NjTj6YMc47W6xkcIjRliI09/QiZcbRZh0t5KwCKjufYfO56OK6T9vtac6k7k0gbp8wd+Fwh2QPRHfDtC8nIeUsQRbMDH1U4WmhZ1NcXn12STx8wY7AUrd+/Vp9CSQjInH69fkGCURICr9WnIIgwWKogiGcL9RCtUA4tXQJXJKfv6c+19uHZAI9i4K1TyGkXMBvg0YZmAd4mdUaIJrwIjVbLCimB0AwDbOjpw+WLhnDnwZcxEfioOi6C3CELZz8EzKg6LiYCH3cefBmXLxrChp4+NMMApmdCiOrbiNcxMqqCmkqbFfCGGrf1x8wuwIw1D569zdzYQvJKlWrszMAUzQF89tyLMBH4+IMXf4KWlFjketHkzusgCMnk0iLXQ0tK/MGLP8FE4OOz516EMNkHUBBSBU9ukv8xQV0ITFN0gUmm2J2BT5IKLdbrAHy7OEkQIDTCEOuqvfjall/Ay9MT+PhTD+Gx8WNY5JVQc6PT6xJhWAhxUFcJAaDmeljklfDY+DF8/KmH8PL0BL625RewrtqLRhjmX7GyBbNbVbU+fSOpO+BtDl474JPyXEPU9EKsDOeBz2XQVvpNc9ddEESYCgJs6RvAX7/9vfhvrzyD337+Ebx78Tn41RUbccmipeh3PfjMaMkwXsbNilL5LCpanYNLz3hAdEqMSwIlx4VHhKkwwI9PjeF/H96DH506ivcuWYE/2PA2nFOuYCrIzwQWNITCCWswpPOXuWwoh68NkyJarvYE2DeF5iSuKMPZAF+QtyL5nYITC8ESr4wvXXAFHj55GN888DJ+94UfY22lF1cvWYErB5bhvN5+DHhleBRvC2NGyDIyzYzUgTS7HQfRDiKHRPw/3g7GjHG/iacnTuKx8TE8fPIwXmtM4621xfjKBVfg6iUr0JKye/ABxcFTTiBHPP2rEizt1h54g14AfBJcS0wj0zMDPnps03rF/M/CGjhE8DlEKwwxvGQF3r14OZ6aPIHvjh3A/ccP4G8P7cEi18OGnj5s7h3Axp4+rKr0YqlXRs31UBEOvGSvX1w3yYwQDF9KNMIQU4GPE34TBxvT2DMziV3T43hlZhKnAx+DpTLeNXAOPr/pYlzctxQOESZDHxTz1nXQTL3SHoCyA8gCPGDv4/WLjsAnN7PqAnLmfq7AW9N233jJjMJkvAx7Sf9SvHPREMb9FnZNn8aTEyfwzORJ/L8Th3DPkSZ8ZrhEqAgHVcdFRTioOPp+gEYYoiFD1MMADRkiYIZHhCVeGet7+vDRFRtwSf9SbO5dhAGvhIAlZuK9h+bUdfdBWQK09fNmy3TTLWtwdm5/SxeQL2j++vm8sEWnWMytAZOGnw6CdJHm0kWDuGJgCCEzpkIfx1tNHG3WcTTeEXTKb2I6CDAjg3QY6RKhR7jodV0s9soYKlVwTqmKc8pVDJbKqDlebHkYzTDEuN8CxeXPlfes6zN3/1Aet1n5Ywq9g+IRtC5ACeZhCepa9TwBD9hOsZhbSAQhBGM68FN2HRJYVenB2mot7c8BZQeWyo3Couo3+JIxqeRJRGc+C6l2fam1j/NUd/8WKt6ZA59gYhUAq8Znm9isWpwvOCskn/88oG4JCUBJYDCaksEcFm4CzeLa80o0ff6DsjEwp/EWDrsBPhfF5kPoNE0A2pt6i08wH8Db5hnmMZhC8cYJpglIyJ2B79bB03/smLjZsy6ANzO0FTwb4N8MKb7Z0fHqA+1i1sBHlwVKGre/az2YsE0hs/Hsuwb+36AsRPofbQPXZiXmDXgtofJAJ2RdQLfAJyH1BfKF2A9CVtNyxghZcz8rIVlDWJg+vkNIvM5E6dX2TOOod90pXrG5twkD4GavLFHKl553p8ZJNjbGMt0xerLHTXEqF2j+vi0bYPTEawj10D+LIsjaZbYnv4ODN2fg83lHpLgLMHNJv1KVbEykZHRaZH5UgvIBxC7HrqkvdBYDgVASDp49dQwA8NaBQfhS4myLIQuKxpza4VIZl+pPEW2uwCchdQKzDO39OSs0zSwVFKw1pa0PS2/PrgQwAE8Qvjz6BP5h3y4AwEfWbcZntrwDLclnj5N0EsR8MatNPz+PwCfJ4y8TA8TtHDy9oGjBosDBKBzGGNzbrMECh2Rr+ZMnx3D33pfQ43rocT3cvfclPHlyDD2Oe5b2FmQWE0h2DiltpDWX3v5xR9t1+2fL9EbxsQC6Kjv6nKRRQDpnUVCwtY62s+yLQT8bRpiI0Ig+eZtuKmVmNMJgwecLGMpKJClgpsxpnOZonYZ0eVKRMmZBJMwkw5G8dmdSSsl9/Ep0UeEAgZhyexoL7FUUnwg9ILhm9zGPQRBhJvBx2dLluGrZKhxrzOBYYwZXLVuFy5Yux0zgL9iIgBGvOSQ78ZOJQKBY43NaD70JCyxu118xocQHUOejyVyJLtbuKK0uCFaJTjPMv+VCYAiKTuB6dmYClSDEULkabarMl3zGIVk0+uKl78YPDr8GALhmxVq4JNI3ixaiTJcIx1sNHOIAIWxv49k0Pv6bY8pmhS1YUe5CKSa6EPoERKbdprAlO2RyT9L+RLEQxFYGVYaSZEzRtu/JIMC/H30E9x7dj5rjpVuv5jsQAJ8lXHLwoXWb8aF1m+GSs2DgA9HCUs3x8J2x/fjt5x/BZODDiQ+5aq/xRf28SSracp/LNM45o2XfQk1NkrnEGT9QSJkw6CGhcXwSqcYQssLV3oVYoCkZKys9uGbpSvz9kVcx1qqjvIBbvwlRX3yq2cCpZgMSC+f9SzDKQmCsVcffH34V1yxdiZWVHrSkzJn1zsCTQbJ9cyDLCblLyj0WyWvKSSGJIciN41JarOFJHmwmoFwSVtJm/+JnFOXXkhKfWn0+6jLAV/c+h17H1SdK5j0w+rwS+rySWdl5LCH60+u4+Ore51CXAT65ZnMEPlG6JXfegKd2wJs+RHSTfDEk5jg5Qo0NGdCtgObgmaWlAqIYOLM/sUh+XQZY61XwhY0X454j+/D1fS9gsVeOtHWeuwMCoSxcPHvqGJ49dQxl4dp9nTMIMu5GF3tlfH3fC7jnyD58YdPFWOdV0ZBh6qXP55BOo6E98MmPm/bbailJSDQwYTadveWMlqi62WvAtuHDUtGYE5cEJsB4/7I1GA99/OmepzAd+vjd9RcCQPre/ZnCtNATQYzsHAMA+PNXnsZfHdiFz2+8GO8fWoMJyLgeUV1y7w+cwZBOBd6kpTdGEje14OmOlCRvFeSCmmrCkMVN0wNZDZX8dWaT07MYDgin/RZuWbUJPY6LP979JF6cOo3Pb3o7NvUswlTop6dwzAUoGR8r89MTR3D33pdi8w/cvfclvHf5Grxz6XJMz3EoyMhOL1nklrB75jT+dPfT+NnEcfzJ5svw4eXrMd5sor/kZfUntT0sZZKl9Sl30R3wFlrcCyVAJWN7xfwrCzXq6ZbasC6l6UewRdllb7koHoFWH5MqiDDht/CR5evxzYuuxgm/gY89+RDu2DeKZhhisVeCR2LOL4GYE0Eu0ZwnghLQQ2Z4JLDYK6EZhrhj3yg+9uRDOOE38M2LrsZHlq/HhN/KfYU2m3DLgzwbz15zrduY+4yaLdq5nHECVYa0SZxY3dO4qrOYmnrD7Ve3ZhlSnqVVOc7iCyKM+y1c1LcYd759GN8+uBvfOvgy7jm6Fx9dsQHvH1qNlZXe6JBnGSKIT+QUNo1RgjkR9PDR/QCAq89Z0/VEEIMhY6PnCoGq44KIcKgxjb85dAB3H34FE4GP31h9Hn591Sb0ChfjfgsOkeHLJG2ki/Ds9meQ9bFd45H5A0pw7f138m5b4uyZ0hV9SlHVeDJANqeTAGR74EmJq1geNThEmA4DuCRw67otuGloLf7Xod34q/278K0Du3D1kuV43+BqvK1vCZaUImexJSVa8Tl+qvxmDlc2KWNOBDlE6eRTIujq20GE5BzC6JQxBnCy1cTj48fwveMH8PDJI5AMfHDZGnx85Sas76lhOgisZwZpbZA2RVEcu1mf7Zb7XPbZcjCUfj9fkGYhEu+f1AwZ0ccH9BTZ0eeKJTAYTZzKIqUVFB3HMu63sLxSxec3XYxbVm3C/ccO4rvH9+P+YwextFTGpf2DuHxgCG+tDWBlpRd9brSN23wrKNFAX0o4JPDv1p4HIDrmTfUtolPC9LeDom3mAV6ZmcDzU+N4fPwY/mXiOE60mljfU8MnVm3G9UOrsLZaQ0NGW8cFUXuLUmSxFhJ4QMMk3RGUAa3O4SuOnCYcybq/xdNP+7XkXtV60mgcz/tbDIBWNYcILRmiEYZYVqri02vPx8dXbcQLU+N4+OQRPDY+hp0nD0MyY6hUwbk9fTivdxHWVWtYWe7BEq+MPtdDxXFQIgFHRK+EtOJDmirxmT4hS7RYYjoIMBn4OOk3cag5g331Kbw8fRqvzkziWKsBQYS11RpuHFqDq5csxwW1AdQcF/UwAb7zW0JJH695MSbwyu18A58EVzuEMLblrEVWPPvE4UtQp6THSEDOZpp0PtubwPZNlXHhENBiiYYfnRBycf8SvHPRIGbCEAeb03hhahzPTZ7CrunTuHfsNUwEPgKW8Cg6IbTXddEjXJTjN4N6ncgjnw59NMIQTRliRgaYDqK3g6IpY4F+18PqSi/evWQ5LuxbjAtqA1hV7kWPE00h18NQO6+om9rkbzsAn4uS789nA7zRBSiSxMovAKLI6VPNNyWdvqrt2vyBIUSmFUh5z4aA3YbEIgDZG0EOEdZUerGx2o9fXrYWLSkxEfg44Tcw1mpgrJm9FXQ68NGM3x5+Jt4RdNHiQfS7JZSFg0Wul74dtKxcxbJSBUu9CvpdLzqZhKNj6VtS4pQfgoBZAG+pzFyAt9C6B17PPRsFUBaDWAUJSI+xTPBM/8QCgsiZy+qTxDUcQUO4EtJcp1/U/rUpQ9Q5TOkVx8E6t4aNPf1RX4xseOoJgS89/wSempwGAGxcvAq/t+Uy+FKmk3IS0RAvYIkgHm1Mp2cDJxZpbnxnCqNqWvIzG+Dj+CYbXQCf0LJdwZkVT/v+COjYYUs1PrIIpsZHUVWavWDt4MN0E8JsR/P5kHQRSUicv4byVpBkRq/n4dGxQ/jmnufSiaBv7nkOlw0tx2WDyzHdyoaCmWHLnMN5D6ri5WjKzTwDnyR21S9raP28psWkjeUjsioxym8qJHEe2r0qJGlps57M6SYkEKptQogOemjJ7PTwJLRkCDfx+hcCaBuDBG0Cbe4Onk0Y4riWLNXIIpLyCIZ0Bg/mrpzMTKUywdmTKJ3yBS0g1e6knmkGaVrGwsFvD6/njiA1RDVW5u+0Ropv9IaL4pMF/IKFJG0eMc1LyTS+NHYE6SyyMo+flWFovmHqs1vODEB2ofgMana84PvxksA4+zuCzOAKEWueSp2NxqPA3Gddl56tza9IuoA0rdF/J5mlKg9lwodShy4BOnFoSJ0zMD/Hmn4WjaFWWEqJqemZeIPiwloEgr4jCACmff/sgM8MAeDE+OnsrOCc8mWcLgzwcd4xLX0vQJs8VTFMNVfNQdXzzNQn+WTsWEYBaRGcxZKMQ0eP5lIsVCBEO3VOt5oAsGAHTJuBEZ149urBgwhDCSIBUJjjbq5DOpWWj5ddqFlZu4B0nK/EToHRR4SZ0VcKZjU9oFkC3aBEzqXrunhp7z40ZQgSlqMLFyAQFsirb1emEGiGIXbvPxB9NMJcCLI6c/MIfC4KQeTANx0z1WlTNnsmM4DphjI1Wd77QHQaVhYp+T5eKENUymU8/dIu7N73GqqlEqQ8G3bg7AbJjGqphN0H9uPpl3ejWi2nH5ik2MHTwDGH2lHEDg6ejZZtwNUSxeVl5xnG2CQTM6yqvLomYHr2MY0BMMUCwXpXTlANQl7KXdfBxNQ0/vqf7kXFcSFZPzH8X0OQUqLiuPj2P38XE1PTcONtaDngMRfgyUqzAm+0v0iRz8dWhIFSK0BkUXVNiExfQdkAGt+ln2+NBScIQ/TXenH3/Q/ge48/jqW9tehjkP9Kgh8EWNpbw/eeeAJ//+BDWFSrRUJuM/cW2rwCn+sCkoIBZMKgeva6hYm2fKubQ4wuQy3HFIg0qsJJamAIruPic1++HaN792Fxre9fhRD4YfTRqNHX9uELX/ufcF2nAHhT6wkwndNC4KOb2QCfLOlH7wXk5mMS4GONJ7vGRxNApMwXGD5EavvV+0zY4m/YRyywRNnzcGpiAr+1dRtGX3kFg7U+BOl3gH++AjPH3wnqw+irr+LTX7wNpyYnUPY8/ZPzbYDXcSwGHjCX5TsDn5D1bwYlmbGRTnHkci+1kYZpbB2ydX51ZjGbA0gWjvRSAhmiWq3g8PET+LXP/Wd850c/wmBvDa7jIAjN4dIbNwRhCNdxsLS3hnsf/TF+Y+t/xZETJ9FTqSBMxv+F/Xwb4JF7aMmqGPic+0UEWnX9TSncWleillZQQE5I8vOUBbxbKq9cCCHgBz5afoBfv+n9uPXjN2PF4sWFn459IwRmhpQSbvzp2CPjp/D1u/8Bf3vf/Si5LjzPi7x+a93nZ0iX61oUmgl8ernqfdFn45JVLy1nG8gw6kC2EnSCpu0dwE+sAwkBQvLx6BX41Ec+hF+55r3Zx6N9H8CZntZ5ZiH9eDSAsuelH4/+p50/xDf+8TvYe/gwBmp90UApdzJl9CcPvHbRHfA2WgfgU9Lq991kHk2ZpVJX7nKWxSZx+UJI/2N7YEma8eE4DhrN+PPxG87FzTe+Dzdc9S6sHhqChPr5eIBEvGBiYWs+grnolXw+XgA4ePwY7v/xT3DXA9/Hi3v3oqdcQblciky+pd4LAzzSRuwEfMrHaqULsKRMf4q02GbWdd7nBrz+XESfXWs20Gg2sWrZMgxf9g5ce+XluOSC8zG0aACEaEm36fsIE8cxEQbzt03IJrj0XyKC4zgoeR7KwoEEcPz0aTz10i48+PhP8fCTT+LQ2HFUyiVUK5XonQXLebQLBryipGp5uWBkSKuv/2A2KW8pJKfPVvNvSB3lZLxQGHLyahGGpBkFRd8ZbPkBpht1uMLB2hXn4NK3vAXvvHALLjxvE9YsPweLajV4iHcFx7ONYSgRSpnNQVjaJXnp0hEi+h+fKE4AAjAmpqaw/+gYnt29B0+Mvoindr2E144cRRhK9FQrKHleIfC52pvtYTw8I+Bt1tkEPom2+oYPGnN2Zvr2BesZUpuKKTm2lXx7mVkTRtooKBpZNH0fjWYLDEZfTw9WDg3i3FWrsGntGqxfuQIrlw1hcGAR+ms19FQikFzHgSNExggzwjB6waTl+5hpNDAxNY3jp0/j8Ngx7D18BLv378erhw7j8PETmKrPgIhQKZVQLpVARJBSecvaqOhsgNfbx94WKcGCc7vVwnzxlAhAlxpvodm6AOOBJamtUu1AN+NmmSXCAAJCKeH7AfwgQBCGEEKg5LmolivorVbRW62ip1pBpVRCtVJOv9wpmVFvNtD0fczUG5iuNzDdqKPebKIVBGDJqfkveW4kPHE66wxF3Mptgbe0UVc7fRRaZ3NfDHwS0g9GdAbekqGt4LbAK/Ruwc+ZMp3AHH0SPtpaRSiXSqiWy2k8yYxQMsanJnFi4nTktTP0z8dTYv4jX8MRBOEIVMpl9FSq8SiDU/Me2oZzKdOv35DOViZZaOoDlwh1EFXNnb96hl0AX1BIzgjOFfiCMs0hICP+spcyBU0CcMmFh8wZtPKhGvH4QrI0tjXMBnjtojvgbbQ5AK/fWgQwWoqvuwyMC1A1nt43DEHOLrSR6KKkZ6jxFj4iUncCmAaOF6IISFehUj7yLmFX5nhBgUda73kFPgpMJIiZx10QHYYjViAIso158wl8vgZnFfiFeqXqDTmk65IPgJkEETEfFgC/HGceOYOGuafsDywPdJ5TDpSKaYWT8ShOZJN8UwjJAn4Rb3He6Q4bGw8GEMU7bs0yqQD84nrn2Szmw1ysMTGx1Vu/tfGh04iIo5lWflkAzhNpIWTmbwMeOVqUtAvgFXCsWt8W+M4CCFKAN9icT+D1qrWv99yBT8q08NY18NBoWXbRDZN4wiXBj7EMGUTZARZzGdIZlxozGqWoUiYtEZTOfEQ/3fORApMr085HjhNTCSy8vR5DuqJ6U54mZBCwQ/yYCBD8C1i+JhyHAEg7+KYJMcDvqPFxE9q8b0t5Z+t4lIxo5wNk242Ty1DjLY1i1rGAprNczEeuqLYaTxacksJYkuMQM79WBf5FHL733hki8RC5LoMoW7mwVNaeYb7gzsDDSjuTEy+7A94oc1bAJxd23vLNpfChJpo18FmLFwqgUV7eh8jiMZMUrsdE4qGfbd8+E58TKO6ON/6JQuBJL+TMgCeDZFnSbSPlc3mlygqEWV5b4PMC2BH4nLDNDfjO/ljGmw68rd4QDCYSuBuI3gsgL5j+QRPVvcJx13G0V1kk/GWl5S9NCScLTWuAHMkS0aZp6SXlaLDS4thd8vHzPaSDkb+t/WMasxSuS9xs7vUr5R8AIIHhYWf3ffc1IegvyXUJgMxpvHGpSXl6NxuNt4BfJOVIND6nPhkPFo3/tzOk01IWtH96Jx3PI3LEX+6+/fbm8NatTprbiptuWuqJ8otEtBgsM047SLldK5GvaEqyNICVpuRt4+MMNd6WZZHlSZt4rhrfgY988e35yGl8Gz7SO2Ymx2FmPhWyfMuu7dtPJO8qMoaHncP33nschNuE50UvrHWQ8kzrjcIL+rXZfMSgK89eSdS9xiPVeDJo9kaPa5nLqljj8+zZ+ND1q7uxPBVrfAEfWf4EJgpFuSwg6LZd27cfHx7e6oAoXTEhbN1K6/buLfH41FPCcc7nIJDpi3q5trFrYN4KGFqs5ZVv8NmN5RUB1Ig2Tcvl3tbyqE3cjeWxstehnycLzZKJpdguNV7lg1kKzxMyCF+aaSy7eN96tLBtGwPg7IPao6O07847G8JxPg0QIIQEpa/6Khpf0Og5IX9zSGfykROsMxzSmXzoVUn5iIb3RIBDn95357YGRkcJ8XJY9l7Ajh0hRkacvffc/bAM5W2iXHbBHHQGngzSm0M6kw8V+Pkd0rUFHgDAQOBUq670g9teuOOOh0fuvtvBjh2hkovB8siIwJYtvO7p0fudknetbLUCEOmfmX9zSNeBBz2xflvMh1KE7cZK0wTQCMwcuNWqG7RaD764bOj6kdFR2rFjh4Syw8F8GZ+xYwdj2zYOPdwsg3BUeJ4L5iAt5M0hnUZrV2/9ttjyqNmRGsFab7N69rZgIHAqFTf0/VHRKt+Mbdt4x5YtuZcAbacxSGzdSgd27DgpWvJGKXmXKJVdBrQ3NTPgTVNmN29vrtLZ+EiLyANv4UOvXrEAMnPglMsuB+EuCvwbR7/xlZPYupWwbVvuvfu83UjCyIiDHTvCDTeNrJVV57tCuFtkq+mDyJvNkeZvrtLlMrEUayssz1uWta2OEY0B3y2XPQ78Ufb9G0e3b38twTLPfDsBAFIhWHHTTYOVSu1vHK90fdhqyvjz76JdZd8c0lnKyxU7f8CDo1Ou3GpVhL5/f9Bq3bJr+/bj7cC3Fp0LW7eK2HSIDSO/+kWQ+BwIkEEYEMFJuVJawSYXCwe8kWk3wNtocwBev+1gFXPVbC+AehZtLA+DGRw6JS9y1KW87fmvD34B2CYV7ApDZwGISkk44w033/xLgPsV4bgXSd+H5DAgQIBInLlnbxOGOK6V6zMFHnn5VWg2PvK3HYCPL8l+Y6V1BzxLBqRwHNcplyCD4FkZ0mdeuOMvvp8e2EC53a650OWRXPGhACMjzit33fX9lmxdIcPgD0E46pYrrnA8QRy/iUXJAT+UVcwAYiFOvEwuKM4ql8jCR955JLuZbevgtedNc/DmOJZPH6afKGJJriu8nqoLoqPSl394+oh7xQt3/MX3R0ZGHBBxN+AbNegyKH3KhltuWUYBfgvgT5DjbAYROAjBUgKEqN9hTmZv7G9xt5HyvALb1CS66VrjY2HoaI4LNb6IjzYa34YPPX8tEsdvpSZvbjnkOBCeG720GspdRPiWKJW+8cyXvjQGAJ36e1uYvQAk6UZGRFLYpt/5nXJ4Yvw6IeWHGTRM4A3kuukbOOknQbSjw7oAvm2DRzc/d8Cb8ygWGpLZVCHS5RgZfdXsFSLaCSHuaTI/sPv225sAMDIy4pgTPN2GuQpAmn54eNjZuXNnOkewZWSkVi+VLhGhuByEdxDxZpZYCfAAgOrP1ZDOxkeBsM1J4218ROXVQRgH6BBAu8ihnzHwOEn55Ogdd0wlUYe3bnV3/tEfhd2ae1v4/4KaEGUZg1QaAAAAAElFTkSuQmCC">
<style>
 /* erd-pk/erd-fk/erd-line/diff-tgt: separate from the regular text/accent colors above because
   these specific shades are used as plain TEXT/LINE colors directly on the panel background (in
   the ER diagram's SVG and the row-compare diff table) rather than as a background+text PAIR
   like a status badge - a badge's own background moves with it, but these sit on whatever the
   current theme's panel color is, so they need their OWN theme-appropriate variant to keep
   working WCAG-reasonable contrast in both themes rather than just the one they were originally
   picked to look good on. */
:root{--bg:#fff;--fg:#1c1c1c;--panel:#eef0f3;--panel2:#e6e6e6;--bd:#ccc;--bd2:#e2e2e2;--hover:#eaf2fb;--accent:#1565c0;--muted:#777;--gridh:#f0f0f0;--even:#fafafa;--dirty:#fff6cc;--del:#ffdede;--btn:#fafafa;--log:#1e1e1e;--logfg:#d4d4d4;--str:#a31515;--kw:#0000c0;--com:#008000;--num:#098658;--in:#fff;--sb:rgba(0,0,0,.28);--sbh:rgba(0,0,0,.48);--erd-pk:#1a7a5e;--erd-fk:#2a5a9e;--erd-line:#2a5a9e;--diff-tgt:#a8442a;--err-line:#d6373a;--log-warn:#d19a1f}
 body.dark{--bg:#1e1e1e;--fg:#e0e0e0;--panel:#2a2d31;--panel2:#333;--bd:#444;--bd2:#3a3a3a;--hover:#33404d;--accent:#3b82f6;--muted:#999;--gridh:#2d2d2d;--even:#262626;--dirty:#4a4526;--del:#4a2626;--btn:#333;--log:#141414;--logfg:#d4d4d4;--str:#ce9178;--kw:#569cd6;--com:#6a9955;--num:#b5cea8;--in:#2a2a2a;--sb:rgba(255,255,255,.24);--sbh:rgba(255,255,255,.42);--erd-pk:#5dcaa5;--erd-fk:#8fb8e8;--erd-line:#7aa8d8;--diff-tgt:#f0997b;--err-line:#e5484d;--log-warn:#e0a828}
 *{box-sizing:border-box}
*{scrollbar-width:thin;scrollbar-color:var(--sb) transparent}
::-webkit-scrollbar{width:11px;height:11px}
::-webkit-scrollbar-track{background:transparent}
::-webkit-scrollbar-thumb{background:var(--sb);border-radius:8px;border:3px solid transparent;background-clip:content-box}
::-webkit-scrollbar-thumb:hover{background:var(--sbh);border:2px solid transparent;background-clip:content-box}
::-webkit-scrollbar-corner{background:transparent} html,body{height:100%;margin:0;font-family:system-ui,"Segoe UI",Roboto,Arial,sans-serif;font-size:13px;color:var(--fg);background:var(--bg)}
 body{display:flex;flex-direction:column}
 #bar{display:flex;flex-direction:column;gap:5px;padding:6px 8px;background:var(--panel);border-bottom:1px solid var(--bd)} .barrow{display:flex;gap:6px;align-items:center;flex-wrap:wrap} .brand{font-size:12px;font-weight:600;color:var(--muted);white-space:nowrap;margin-right:2px;letter-spacing:.2px} .fld{display:inline-flex;align-items:center;gap:3px;white-space:nowrap;font-size:12px;color:var(--muted)}
 input,select,textarea{background:var(--in);color:var(--fg);border:1px solid var(--bd);border-radius:3px;padding:3px 6px;box-sizing:border-box}
 #bar input,#bar select{height:28px}
 #bar input.h{width:130px}#bar input.s{width:52px}#bar input.p{width:120px} #pass{-webkit-text-security:disc;text-security:disc}
 /* white-space:nowrap: a button squeezed by a flex-shrinking sibling (e.g. the OBJECTS panel's
    filter input) has no min-width floor otherwise, so its own label can wrap to two lines inside
    the fixed 28px height instead of the button just staying its natural single-line width. */
 button{padding:0 9px;height:28px;box-sizing:border-box;border:1px solid var(--bd);border-radius:4px;background:var(--btn);color:var(--fg);cursor:pointer;display:inline-flex;align-items:center;justify-content:center;line-height:1;vertical-align:middle;font-size:13px;white-space:nowrap}
 button:hover:not(:disabled){filter:brightness(1.08)} button:active:not(:disabled){filter:brightness(.93)} button:disabled{opacity:.45;cursor:not-allowed;filter:none} button:focus-visible{outline:2px solid var(--accent);outline-offset:1px} .chip{display:inline-flex;align-items:center;padding:2px 9px;border-radius:999px;font-size:10.5px;font-weight:600;line-height:1.5;letter-spacing:.4px;white-space:nowrap;border:1px solid transparent;box-shadow:inset 0 0 0 1px rgba(255,255,255,.10)} .chip.ok{background:#2e7d46;color:#fff} .chip.bad{background:#c0504d;color:#fff}
 /* A saved connection name or environment label is free text with no length limit at the point
    of use (only a maxlength on the input, as a soft cap) - without this, a long one would either
    stretch the bar past the window or wrap it onto a second line. Ellipsize instead; the title
    attribute (set alongside the text in JS) carries the untruncated value on hover. */
 #connStatus,#envChip,#schemaBadge{overflow:hidden;text-overflow:ellipsis;max-width:220px} button.primary{background:var(--accent);color:#fff;border-color:var(--accent);font-weight:600;box-shadow:0 1px 2px rgba(0,0,0,.18)} button.go{background:#2e7d32;color:#fff;border-color:#276b2b} button.sm{padding:0 6px;font-size:12px} button.warn{background:#b23b3b;color:#fff;border-color:#933}
 #main{flex:1;display:flex;min-height:0}
 /* 280px is not an arbitrary floor - it's the narrowest the SCHEMAS header's label + its 4
    buttons (+ Schema/+ Table/ER/refresh) fit on one line without wrapping into an overlapping
    mess (measured empirically; wraps below ~270px, so 280 keeps a small safety margin for
    font-metric differences across platforms). Below this, the header row that's been fixed to
    never move would go right back to breaking. */
 #side{width:280px;min-width:280px;flex:0 0 auto;display:flex;flex-direction:column} #sideResize{flex:0 0 7px;cursor:col-resize;background:var(--bd);position:relative;touch-action:none;z-index:5} #sideResize:hover,#sideResize.drag{background:var(--accent)} body.disconnected #sideResize{pointer-events:auto !important;opacity:1 !important}
 .hdr{background:var(--panel2);padding:4px 8px;font-weight:600;font-size:11px;letter-spacing:.5px;border-bottom:1px solid var(--bd);display:flex;justify-content:space-between;align-items:center;gap:8px;height:52px;box-sizing:border-box}
 #schemas{flex:0 0 40%;overflow:auto;border-bottom:1px solid var(--bd)} #objects{flex:1;overflow:auto}
 .item{padding:3px 10px 3px 16px;cursor:pointer;white-space:nowrap} #schemas .item{overflow:hidden;text-overflow:ellipsis} .uitem{padding:3px 10px;cursor:pointer;white-space:nowrap;overflow:hidden;text-overflow:ellipsis} .uitem:hover{background:var(--hover)} .uitem.sel{background:var(--accent);color:#fff} .item:hover{background:var(--hover)} .item.sel{background:var(--accent);color:#fff}
 .ohdr{padding:3px 8px;font-weight:600;font-size:11px;color:var(--muted);background:var(--panel);border-top:1px solid var(--bd2);position:sticky;top:0}
 #content{flex:1;display:flex;flex-direction:column;min-width:0}
 #tabsbar{display:flex;gap:4px;background:var(--panel2);padding:0 6px;overflow-x:auto;overflow-y:hidden;height:52px;box-sizing:border-box;align-items:center;border-bottom:1px solid var(--bd)}
 .tab{display:inline-flex;align-items:center;gap:6px;height:30px;padding:0 12px;background:var(--btn);border:1px solid var(--bd);border-radius:6px;cursor:pointer;white-space:nowrap;box-sizing:border-box}
 .tab.active{background:var(--bg);font-weight:600} .tab .x{margin-left:0;color:var(--muted);font-size:14px;line-height:1} .tab .x:hover{color:#c00}
 .tab.dragging{opacity:.4}
 .tab.dragover{box-shadow:inset 2px 0 0 var(--accent)}
 .runningdot{display:inline-block;width:7px;height:7px;border-radius:50%;background:var(--accent);margin-right:6px;animation:rundotpulse 1s ease-in-out infinite}
 @keyframes rundotpulse{0%,100%{opacity:1}50%{opacity:.25}}
 .tabpane{flex:1;display:none;flex-direction:column;min-height:0} .tabpane.active{display:flex}
 .edwrap{position:relative;height:calc(50% - 34px);min-height:44px;border-bottom:1px solid var(--bd);overflow:hidden}
 .edwrap.big{height:280px}
 .edsplit{height:7px;cursor:row-resize;background:var(--panel2);border-bottom:1px solid var(--bd);flex:0 0 auto} .edsplit:hover{background:var(--accent)}
 .hl,.editor{position:absolute;inset:0;margin:0;padding:8px;font-family:'Cascadia Code',Consolas,'SF Mono',Menlo,'DejaVu Sans Mono',monospace;font-size:13px;line-height:1.4;white-space:pre;overflow:auto;border:0;tab-size:4}
 .hl{pointer-events:none;z-index:1;color:var(--fg)} .editor{z-index:2;color:transparent;background:transparent;caret-color:var(--fg);resize:none;outline:none}
 .c-str{color:var(--str)} .c-kw{color:var(--kw);font-weight:600} .c-com{color:var(--com);font-style:italic} .c-num{color:var(--num)}
 .toolbar{padding:4px 8px;background:var(--panel);border-bottom:1px solid var(--bd2);display:flex;gap:9px;align-items:center;flex-wrap:wrap}
 .tbsep{width:1px;align-self:stretch;background:var(--bd);margin:2px 8px}
 .result{flex:1;overflow:auto} table.grid{border-collapse:collapse;width:100%;table-layout:fixed} .grid th .rz{position:absolute;right:-3px;top:0;width:7px;height:100%;cursor:col-resize;z-index:3} .grid th .rz:hover,.grid th .rz.drag{background:var(--accent);opacity:.55}
 table.grid th{position:sticky;top:0;background:var(--gridh);border:none;border-right:1px solid var(--bd);box-shadow:inset 0 -2px 0 var(--bd);padding:3px 8px;text-align:left;white-space:nowrap;z-index:1;transform:translateZ(0);will-change:transform}
table.grid td{border:none;border-right:1px solid var(--bd2);border-bottom:1px solid var(--bd2);padding:2px 8px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
table.grid td:first-child{text-align:center;vertical-align:middle;padding:0}
table.grid td:first-child input[type="checkbox"]{display:block;margin:0 auto}
table.grid td:has(input[type="checkbox"]){text-align:center;vertical-align:middle;padding:0}
table.grid td input[type="checkbox"]{display:block;margin:0 auto;vertical-align:middle}
.wraptext table.grid td{white-space:normal;word-break:break-word}
.grid th input[type=checkbox],.grid td input[type=checkbox]{vertical-align:middle;margin:0;display:inline-block}
 table.grid th:first-child,table.grid td:first-child{text-align:center;padding-left:2px;padding-right:2px} table.grid input[type=checkbox]{margin:0;vertical-align:middle}
 table.grid td.editable{cursor:cell} table.grid tr:nth-child(even) td{background:var(--even)}
 table.grid tr.insrow td{background:rgba(80,200,120,.14);border-bottom:1px solid rgba(80,200,120,.25)}
 table.grid tr.insrow td.editable:hover{background:rgba(80,200,120,.22)}
 table.grid tr.insrow td.delcell{color:#7ee0a0}
 table.grid td.kbfocus{outline:2px solid var(--accent);outline-offset:-2px}
 td.dirty{background:var(--dirty)!important} tr.del td{background:var(--del)!important;text-decoration:line-through}
 /* Inline cell-edit input: kept visually close to the plain cell text it replaces - the td's own
    padding is zeroed while editing (.cellEditing) and moved onto the input itself instead, so the
    input fills the cell exactly (no inset "box" look, no row growth from stacking both paddings)
    with just a faint tint on focus rather than a distinct form control's border. */
 table.grid td.cellEditing{padding:0}
 table.grid td input,table.grid td textarea{width:100%;height:100%;box-sizing:border-box;border:none;font:inherit;padding:2px 8px;background:transparent;color:var(--fg);vertical-align:middle}
 table.grid td textarea{display:block;resize:vertical;white-space:pre-wrap}
 /* The "Set NULL" button next to the input is a regular <button> (height:28px by default) - taller
    than a grid row, which was what was actually forcing the row to grow while editing. Shrunk to
    match the cell instead. */
 table.grid td button{height:19px;min-width:0;padding:0 4px;border:1px solid var(--bd2);vertical-align:middle}
 table.grid td input:focus,table.grid td textarea:focus{background:var(--hover);outline:none}
 input:focus,select:focus,textarea:focus{border-color:var(--accent);outline:none}
 /* Every textarea in the app is natively resizable by the browser (resize:both by default) with no
    built-in ceiling - dragging one's corner past the window's own bounds could grow it to an
    enormous size and make the window unresponsive while it repainted. This caps growth to the
    element's own container width and the viewport height, everywhere, so no textarea - the cell
    editor, the generated-SQL boxes, a plain prompt field, the transfer-script output - can ever be
    dragged wider than the space it already has or taller than the visible window. table.grid td
    textarea already has its own explicit height:100%/max sizing (see above) and is unaffected.
    */
 textarea{max-width:100%;max-height:calc(100vh - 40px)}
 .delcell{color:#c00;cursor:pointer;text-align:center;width:22px}
 .status{padding:3px 8px;font-size:12px;color:var(--fg);border-top:1px solid var(--bd2);background:var(--panel)} .status.err{color:#e06}
 #loghdr{background:#333;color:#ddd;padding:2px 8px;font-size:11px;display:flex;justify-content:space-between}
 #log{height:104px;overflow:auto;background:var(--log);color:var(--logfg);font-family:'Cascadia Code',Consolas,'SF Mono',Menlo,'DejaVu Sans Mono',monospace;font-size:12px;padding:6px 8px;white-space:pre-wrap}
 .modal{position:fixed;inset:0;background:rgba(0,0,0,.4);display:none;align-items:center;justify-content:center;z-index:9000}
/* A floating modal drops the full-screen blocking backdrop and lets its box be dragged around
   freely, so it can sit alongside the rest of the app instead of covering it - meant for the
   handful of dialogs that work better left open as a reference while doing other things (the
   ER diagram, the auto-refreshing process list) rather than the majority that are answer-and-
   dismiss confirmations, where a blocking modal is still the right, simpler behavior. */
.modal.floating{background:transparent;pointer-events:none}
.modal.floating .box{position:fixed;pointer-events:auto;margin:0;resize:both;overflow:auto;min-width:340px;min-height:200px} kbd{display:inline-block;padding:1px 7px;border:1px solid var(--bd);border-bottom-width:2px;border-radius:4px;background:var(--panel);font-family:'Cascadia Code',Consolas,monospace;font-size:11px;white-space:nowrap}
 #mInput{z-index:9600} #mRowForm{z-index:9500}
 .modal.show{display:flex} .box{background:var(--bg);color:var(--fg);border-radius:6px;padding:16px;max-width:900px;width:94%;max-height:92%;overflow:auto;box-shadow:0 10px 40px rgba(0,0,0,.4)}
 .box h3{margin:0 0 10px} .grid2{display:grid;grid-template-columns:1fr 1fr;gap:4px 18px}
 label.ck{display:block;padding:2px 0} .row{display:flex;gap:8px;align-items:center;margin:6px 0;flex-wrap:wrap} .muted{color:var(--muted);font-size:12px}
 #vHexTabs button{border:1px solid var(--bd);background:var(--btn);color:var(--fg);border-radius:4px;padding:4px 12px;cursor:pointer;font:inherit}
 #vHexTabs button.on{background:var(--accent);border-color:var(--accent);color:#fff;font-weight:600}
 #ctx{position:fixed;background:var(--bg);border:1px solid var(--bd);box-shadow:0 4px 14px rgba(0,0,0,.3);z-index:9500;display:none;min-width:180px}
 #colPicker,#objTypePicker,#impDbPicker{position:fixed;background:var(--bg);border:1px solid var(--bd);box-shadow:0 4px 14px rgba(0,0,0,.3);z-index:9500;display:none;min-width:200px;max-height:320px;overflow:auto;padding:6px 0}
 #copyMenu{position:fixed;background:var(--bg);border:1px solid var(--bd);box-shadow:0 4px 14px rgba(0,0,0,.3);z-index:9500;display:none;min-width:200px;max-height:320px;overflow:auto;padding:6px 0}
 .cphdr{display:flex;justify-content:space-between;align-items:center;padding:4px 12px 6px;font-size:11px;color:var(--muted);border-bottom:1px solid var(--bd2);margin-bottom:4px}
 .cplink{color:var(--accent);cursor:pointer}
 .cplink.disabled{pointer-events:none;opacity:.6}
 .logpanel{background:var(--log);color:var(--logfg);border:1px solid var(--bd);border-radius:4px;padding:8px 8px 8px 2px}
 .logpanel:empty{display:none;border:none;padding:0}
 .logpanel .ln{border-left:3px solid transparent;padding-left:8px}
 .logpanel .ln.ok{border-left-color:var(--erd-pk)}
 .logpanel .ln.warn{border-left-color:var(--log-warn)}
 .logpanel .ln.err{border-left-color:var(--err-line)}
 .cpitem{display:flex;align-items:center;gap:6px;padding:3px 12px;font-size:12px;cursor:pointer;white-space:nowrap}
 .cpitem:hover{background:var(--hover,rgba(127,127,127,.12))}
 #ctx .item{padding:5px 12px} #ctx .sep{height:1px;background:var(--bd2);margin:3px 0}
 .item.kbsel{background:var(--hover);outline:1px solid var(--accent);outline-offset:-1px}
 #acx{position:fixed;background:var(--bg);border:1px solid var(--bd);box-shadow:0 4px 14px rgba(0,0,0,.3);z-index:9600;display:none;max-height:230px;overflow:auto;min-width:160px;font-family:'Cascadia Code',Consolas,'SF Mono',Menlo,'DejaVu Sans Mono',monospace;font-size:12px}
 #acx .ai{padding:3px 10px;cursor:pointer;white-space:nowrap} #acx .ai.on{background:var(--accent);color:#fff}
 table.dz{border-collapse:collapse;width:100%} table.dz th{border:none;border-bottom:2px solid var(--bd);padding:4px 6px;text-align:left;color:var(--muted);font-weight:600;font-size:12px} table.dz td{border:none;border-bottom:1px solid var(--bd2);padding:4px} table.dz tr:last-child td{border-bottom:none} table.dz input,table.dz select{width:100%}
.pill{background:var(--accent);color:#fff;border-radius:10px;padding:0 7px;font-size:11px}
#toasts{position:fixed;bottom:16px;right:16px;z-index:99997;display:flex;flex-direction:column;gap:8px;max-width:360px}
.toast{background:var(--panel2);border:1px solid var(--bd);border-left:4px solid var(--accent);border-radius:6px;padding:10px 14px;font-size:13px;white-space:pre-wrap;box-shadow:0 4px 14px rgba(0,0,0,.3);animation:toastin .2s ease-out}
.toast.err{border-left-color:#c0504d}
.toast.ok{border-left-color:#2e8f4f}
@keyframes toastin{from{opacity:0;transform:translateY(8px)}to{opacity:1;transform:translateY(0)}}
 @keyframes expmove{0%{margin-left:-40%}50%{margin-left:60%}100%{margin-left:-40%}}
 body.disconnected .needsconn{display:none !important}
 /* Once connected, host/port/user/pass duplicate what connStatus already shows and cost a
    full row of permanent vertical space for something rarely touched again after the initial
    connect - hidden by default, but "Connect with different details..." in the Manage menu
    (itself only offered while connected, since toggling this has no visible effect otherwise)
    can force it back with .show-connform, for connecting with different, temporary values
    without touching the saved connection - see saveConn()'s comment for why this and Save's
    behavior are deliberately kept distinct. */
 body:not(.disconnected):not(.show-connform) #connFormRow{display:none}
 body.disconnected #main.needsconn{display:flex !important;visibility:hidden}
 /* Same reasoning as #main above: hiding topActions outright while disconnected would let
    Settings/Quit slide left to fill the gap, then jump right the moment you connect - keeping
    its layout box (just invisible) holds Settings/Quit in a fixed spot in both states. */
 body.disconnected #topActions.needsconn{display:inline-flex !important;visibility:hidden}
 body.ro .write{opacity:.4;pointer-events:none;filter:grayscale(45%);cursor:not-allowed} #ctx .item.rodis{opacity:.4;pointer-events:none;cursor:not-allowed} .ctxsub{display:none;position:absolute;background:var(--panel);border:1px solid var(--bd);border-radius:4px;box-shadow:0 4px 16px rgba(0,0,0,.35);min-width:180px;z-index:9999;padding:3px 0} .ctxsub .item{white-space:nowrap} #objects .item{display:flex;justify-content:space-between;gap:8px;align-items:center} #objects .onm{overflow:hidden;text-overflow:ellipsis;white-space:nowrap} #objects .osz{color:var(--muted);font-size:11px;flex:none} #overview h2{margin:2px 0 12px;font-size:15px;font-weight:600} table.ovgrid{border-collapse:collapse;width:auto;min-width:60%} table.ovgrid th{border:none;border-bottom:2px solid var(--bd);padding:4px 12px;text-align:left;white-space:nowrap} .ovgrid td{border:none;border-bottom:1px solid var(--bd2);padding:4px 12px;text-align:left;white-space:nowrap} table.ovgrid th{background:var(--gridh);font-weight:600} table.ovgrid td.num{text-align:right} table.ovgrid tbody tr{cursor:pointer} table.ovgrid tbody tr:hover{background:var(--hover,rgba(127,127,127,.12))}
.expdbrow{margin:1px 0}
.exptoggle{display:inline-block;width:14px;cursor:pointer;color:var(--muted);user-select:none;font-size:10px;text-align:center}
.exptoggle:hover{color:var(--accent)}
.exptbls{margin:2px 0 6px 22px;max-height:170px;overflow:auto;border-left:2px solid var(--bd2);padding-left:8px}
.toolcards{display:grid;grid-template-columns:1fr 1fr;gap:10px}
@media (max-width:760px){.toolcards{grid-template-columns:1fr}}
.toolcard{border:1px solid var(--bd);border-radius:8px;padding:10px 12px;background:var(--panel2);min-width:0}
.toolcard.inuse{border-color:var(--accent);box-shadow:0 0 0 1px var(--accent)}
.toolcard-h{font-size:13px;font-weight:700;margin-bottom:4px;display:flex;align-items:center;gap:6px}
.tooldot{width:10px;height:10px;border-radius:50%;display:inline-block;flex:none}
.toolstatus{font-size:12px;margin:4px 0 8px}
.toolpath{display:flex;align-items:baseline;gap:6px;min-width:0}
.toolpath>.p{font-family:Consolas,monospace;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;min-width:0}
.toolcard .row>span:first-child{flex:none}
</style></head><body>
<div id="deadOverlay" style="display:none;position:fixed;inset:0;z-index:99999;background:rgba(0,0,0,.78);align-items:center;justify-content:center;flex-direction:column">
 <div style="background:var(--panel,#1e1e1e);border:1px solid var(--bd,#444);border-radius:10px;padding:24px 28px;max-width:440px;text-align:center;color:var(--fg,#eee)">
  <div style="font-size:16px;font-weight:600;margin-bottom:8px">Local server not responding</div>
  <div style="font-size:13px;line-height:1.6;margin-bottom:16px;opacity:.85">The NOBS SQL Editor background server has stopped or is unreachable.<br>Re-run <b>NOBSSQL.ps1</b> if needed, then click Retry.</div>
  <button class="primary" onclick="location.reload()">Retry</button>
 </div>
</div>
<div id="bar">
 <div class="barrow">
  <b class="brand">NOBS SQL Editor</b>
  <span id="updNote" style="display:none;position:fixed;left:16px;bottom:16px;z-index:9400;background:var(--panel2);border:1px solid var(--bd);border-left:4px solid var(--accent);border-radius:6px;padding:8px 12px;font-size:13px;white-space:nowrap;box-shadow:0 4px 14px rgba(0,0,0,.3)"><a href="#" id="updLink" style="color:var(--accent)" onclick="openUpdatePage();return false"></a> <a href="#" title="Hide until the next version" style="color:var(--muted);text-decoration:none" onclick="dismissUpdate();return false">&times;</a></span>
	<select id="connlist" onchange="pickConnGuarded();connTitle()" title="Saved connections" style="width:210px;max-width:210px"><option value="" disabled hidden selected>Connections</option></select>
  <button class="sm" title="Start a new connection (clear the form)" onclick="newConn()">New</button><button class="sm" title="Save these connection details" onclick="saveConn()">Save</button><button id="mgrBtn" class="sm" title="Edit, clone, delete or set primary for the selected connection" onclick="connMenu(event)">Manage &#9662;</button>
  <span id="connStatusGroup" style="display:inline-flex;gap:6px;align-items:center;min-width:0;margin-left:4px"><span id="pwChip" title="This connection has a saved password" style="display:none;font-size:14px;cursor:default;flex:none">&#128274;</span><span id="connStatus" class="chip bad">Not connected</span><span id="envChip" class="chip bad" style="display:none"></span><span id="schemaBadge" class="chip ok" style="display:none"></span></span>
  <span style="flex:1"></span><span id="topActions" class="needsconn" style="display:inline-flex;gap:9px;align-items:center"><button class="primary" onclick="newTab()" title="Open a new query tab">+ New Query</button><span class="tbsep"></span><button class="sm" title="View users and privileges" onclick="openUsers()">Users</button><button class="sm" title="View and kill server processes/queries (SHOW FULL PROCESSLIST)" onclick="openProcessList()">Processes</button><button class="sm" title="Browse and reopen previous queries" onclick="openHistory()">History</button><button class="sm" title="Save and browse reusable queries" onclick="openLibrary()">Library</button><span class="tbsep"></span><button class="sm" title="Export databases with mysqldump" onclick="openExport()">Export</button><button class="sm" title="Import SQL files or a whole folder" onclick="openImport()">Import</button><button class="sm" title="Compare table structure between two databases" onclick="openCompare()">Compare DB</button></span><button class="sm" title="Configure or download the mysql / mysqldump client tools" onclick="openSettings()">Settings</button><span class="tbsep" style="margin:2px 10px"></span><a href="https://buymeacoffee.com/monsama" target="_blank" rel="noopener" title="Buy me a coffee, if NOBS SQL Editor saved you some time" style="cursor:pointer;line-height:1;text-decoration:none"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy me a coffee" style="height:26px;vertical-align:middle;opacity:.85;border-radius:4px" onmouseover="this.style.opacity=1" onmouseout="this.style.opacity=.85"></a><button class="sm warn" title="Stop the local server and exit (the clean way to close the app)" onclick="quit()" style="margin-left:10px">Quit</button>
 </div>
 <div class="barrow" id="connFormRow">
  <span class="fld">Host <input id="host" class="h" value="127.0.0.1" onkeydown="if(event.key==='Enter')connect()"></span><span class="fld">Port <input id="port" class="s" value="3306" onkeydown="if(event.key==='Enter')connect()"></span><span class="fld">User <input id="user" class="s" style="width:80px" value="root" autocomplete="off" name="mwt_user" data-lpignore="true" onkeydown="if(event.key==='Enter')connect()"></span><span class="fld">Pass <input id="pass" class="p" type="password" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false" name="mwt_secret" data-lpignore="true" data-form-type="other" onkeydown="if(event.key==='Enter')connect()"></span>
  <select id="ssl" onchange="sslCaToggle()"><option value="default">default</option><option value="disabled">disabled</option><option value="required">required</option><option value="verify">verify</option><option value="verify-ca">verify-ca</option></select>
  <span class="fld" id="sslcaWrap" style="display:none">CA <input id="sslca" class="s" style="width:150px" placeholder="CA certificate (.pem)" title="The CA certificate that signed this server's certificate. Needed for &quot;verify&quot; against a server using a private or self-signed certificate - which is what MariaDB and MySQL generate by default, and which no system trust store accepts. Leave empty to verify against the system trust store instead." onkeydown="if(event.key==='Enter')connect()"><button class="sm" title="Browse for the CA certificate file" onclick="browse({title:'Select CA certificate',filter:'*.pem',mode:'file',onPick:pp=>$('sslca').value=pp})">...</button></span>
  <button class="primary" title="Connect to the server with the details above" onclick="connect()">Connect</button><button class="sm" title="Disconnect and lock the UI" onclick="disconnect()">Disconnect</button>
  <span style="flex:1"></span>
 </div>
</div>
<div id="main" class="needsconn">
 <div id="side">
  <div class="hdr"><span>SCHEMAS</span><span style="white-space:nowrap"><button class="sm" title="Create a new schema" onclick="newSchema()">+ Schema</button> <button class="sm" title="Open the table designer" onclick="designTable(null)">+ Table</button> <button class="sm" title="ER Diagram for the selected schema" onclick="openErdForCurSchema()">ER</button> <button class="sm" title="Refresh the schema list and tables" onclick="refreshSchemasAndTables()">&#8635;</button></span></div>
  <div id="schemas" tabindex="0"></div>
  <!-- The schema name gets its own row under the "OBJECTS" label rather than squeezed onto the
       same line - a flat width cap still truncated a real schema name that only just didn't fit
       alongside "OBJECTS" but comfortably fits on a full-width line of its own. -->
  <div class="hdr" style="flex-direction:column;align-items:flex-start;justify-content:center;gap:2px"><span>OBJECTS</span><span id="objdb" class="muted" style="width:100%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap"></span></div>
<div style="display:flex;gap:4px;margin:4px 6px;align-items:center">
<input id="objFilter" placeholder="filter objects..." oninput="renderObjects()" onkeydown="if(event.key==='ArrowDown'){event.preventDefault();focusList($('objects'));}" style="flex:1;min-width:0;font-size:12px">
<button class="sm" id="objTypeBtn" title="Show or hide object types (tables, views, procedures...)" onclick="event.stopPropagation();toggleObjTypePicker(this)" style="padding:2px 6px;font-size:11px">Types &#9662;</button>
<button class="sm" id="allSchemasBtn" title="Search this name across all schemas" onclick="searchAllSchemas()" style="padding:2px 6px;font-size:11px">All DBs</button>
</div>
  <div id="objects" tabindex="0"></div>
 </div>
 <div id="sideResize" title="Drag to resize the sidebar (double-click to reset)"></div>
 <div id="content"><div id="tabsbar"></div><div id="panes" style="flex:1;display:flex;flex-direction:column;min-height:0"><div id="overview" style="display:none;flex:1;overflow:auto;padding:14px"></div></div></div>
</div>
<div id="loghdr"><span>Action Output</span><span style="cursor:pointer" onclick="document.getElementById('log').textContent=''">clear</span></div><div id="log"></div>
<div id="ctx"></div>
<div id="minimizedTray" style="display:none;position:fixed;bottom:10px;right:10px;gap:8px;z-index:9500;max-width:70vw;flex-wrap:wrap;justify-content:flex-end"></div>
<div id="colPicker"></div>
<div id="objTypePicker"></div>
<div id="impDbPicker"></div>
<div id="copyMenu"></div>
<div id="acx"></div>
<div class="modal floating" id="mBrowse"><div class="box" style="max-width:660px;top:60px;left:100px"><div style="display:flex;align-items:center;justify-content:space-between;cursor:move;user-select:none" onmousedown="floatDragStart(event,'mBrowse')" title="Drag to move"><h3 id="brTitle" style="margin:0">Browse</h3><span style="display:flex;gap:2px"><span onmousedown="event.stopPropagation()" onclick="floatToggleMaximize('mBrowse')" title="Maximize" id="maxBtn_mBrowse" style="cursor:pointer;padding:2px 10px;font-weight:700;font-size:14px;line-height:1">&#9974;</span><span onmousedown="event.stopPropagation()" onclick="floatMinimize('mBrowse')" title="Minimize" style="cursor:pointer;padding:2px 10px;font-weight:700;font-size:16px;line-height:1">&#8722;</span></span></div>
 <div class="row"><button class="sm" onclick="brUp()">&#8593; Up</button> <b id="brPath" style="font-family:'Cascadia Code',Consolas,'SF Mono',Menlo,'DejaVu Sans Mono',monospace;font-size:12px"></b></div>
 <div id="brList" style="height:340px;overflow:auto;border:1px solid var(--bd2);padding:2px"></div>
 <div class="row"><span id="brActions"></span><span style="flex:1"></span><button onclick="brClose()">Cancel</button></div></div></div>

<div class="modal floating" id="mView"><div class="box" style="width:1000px;max-width:95vw;display:flex;flex-direction:column;overflow:hidden;top:60px;left:100px"><div style="display:flex;align-items:center;justify-content:space-between;cursor:move;user-select:none;flex:none" onmousedown="floatDragStart(event,'mView')" title="Drag to move"><h3 id="vTitle" style="margin:0 0 10px">Value</h3><span style="display:flex;gap:2px"><span onmousedown="event.stopPropagation()" onclick="floatToggleMaximize('mView')" title="Maximize" id="maxBtn_mView" style="cursor:pointer;padding:2px 10px;font-weight:700;font-size:14px;line-height:1">&#9974;</span><span onmousedown="event.stopPropagation()" onclick="floatMinimize('mView')" title="Minimize" style="cursor:pointer;padding:2px 10px;font-weight:700;font-size:16px;line-height:1">&#8722;</span></span></div>
 <img id="vImg" style="display:none;max-width:100%;max-height:340px;margin-bottom:6px;border:1px solid var(--bd);border-radius:3px;flex:none">
 <div id="vNote" style="display:none;font-size:11px;color:var(--log-warn);margin-bottom:4px;flex:none"></div>
 <textarea id="vText" style="width:100%;height:520px;flex:1;min-height:0;font-family:'Cascadia Code',Consolas,'SF Mono',Menlo,'DejaVu Sans Mono',monospace;font-size:12px"></textarea>
 <select id="vSelect" style="width:100%;display:none;padding:8px;font-size:13px;flex:none"></select>
 <div id="vMulti" style="width:100%;display:none;max-height:520px;overflow:auto;padding:8px;border:1px solid var(--bd);border-radius:3px;background:var(--in);box-sizing:border-box;font-size:13px;flex:1;min-height:0"></div>
 <input id="vDate" style="width:100%;display:none;padding:8px;font-size:13px;box-sizing:border-box;flex:none">
 <div class="row" style="justify-content:flex-end;align-items:center;flex:none">
  <div id="vHexTabs" style="display:none;gap:6px;margin-right:auto"><button id="vTabText" onclick="switchHexTab('text')">Text</button><button id="vTabHex" onclick="switchHexTab('hex')">Hex</button></div>
  <div class="row" id="vActions"></div>
 </div></div></div>
<div class="modal floating" id="mCsv"><div class="box" style="top:70px;left:140px"><div style="display:flex;align-items:center;justify-content:space-between;cursor:move;user-select:none" onmousedown="floatDragStart(event,'mCsv')" title="Drag to move"><h3 id="csvTitle" style="margin:0">Import CSV into table</h3><span style="display:flex;gap:2px"><span onmousedown="event.stopPropagation()" onclick="floatToggleMaximize('mCsv')" title="Maximize" id="maxBtn_mCsv" style="cursor:pointer;padding:2px 10px;font-weight:700;font-size:14px;line-height:1">&#9974;</span><span onmousedown="event.stopPropagation()" onclick="floatMinimize('mCsv')" title="Minimize" style="cursor:pointer;padding:2px 10px;font-weight:700;font-size:16px;line-height:1">&#8722;</span></span></div>
 <div class="row">CSV file <input id="csvFile" style="flex:1"><button onclick="browse({title:'Select CSV file',filter:'*.csv',mode:'file',onPick:pp=>$('csvFile').value=pp})">Browse...</button></div>
 <div class="row"><label title="The first row of the CSV contains the column names"><input type="checkbox" id="csvHeader" checked> first row is header</label>
  <span style="margin-left:12px">Mode:</span>
  <label title="Add the CSV rows to the existing table (does not delete anything)"><input type="radio" name="csvmode" id="csvAppend" checked> Append</label>
  <label title="Empty the table first, then load (use this to restore a table from its own export)"><input type="radio" name="csvmode" id="csvReplace"> Replace (truncate first)</label><label style="margin-left:14px" title="A cell holding exactly this is imported as NULL. Clear it to treat empty cells as NULL instead.">NULL value <input id="csvNullVal" value="\N" style="width:52px;font-family:Consolas,monospace"></label></div>
 <div class="muted" style="font-size:11px">Columns are matched to the table by header name; unmatched CSV columns are ignored. A cell equal to the NULL value below is imported as NULL; an empty cell is imported as an empty string. Clear the NULL value to import empty cells as NULL instead, which is usually what a spreadsheet means. For an exact restore of a whole database, prefer Export/Import (mysqldump).</div>
 <div class="row"><button class="go" onclick="runCsvImport()">Import</button><button onclick="hide('mCsv')">Close</button></div>
 <div id="csvLog" class="muted" style="white-space:pre-wrap;font-family:'Cascadia Code',Consolas,'SF Mono',Menlo,'DejaVu Sans Mono',monospace;font-size:11px;max-height:200px;overflow:auto;margin-top:6px"></div></div></div>
<div class="modal floating" id="mExport"><div class="box" style="top:80px;left:120px"><div style="display:flex;align-items:center;justify-content:space-between;cursor:move;user-select:none" onmousedown="floatDragStart(event,'mExport')" title="Drag to move"><h3 style="margin:0">Data Export</h3><span style="display:flex;gap:2px"><span onmousedown="event.stopPropagation()" onclick="floatToggleMaximize('mExport')" title="Maximize" id="maxBtn_mExport" style="cursor:pointer;padding:2px 10px;font-weight:700;font-size:14px;line-height:1">&#9974;</span><span onmousedown="event.stopPropagation()" onclick="floatMinimize('mExport')" title="Minimize" style="cursor:pointer;padding:2px 10px;font-weight:700;font-size:16px;line-height:1">&#8722;</span></span></div>
 <div class="row"><b>Databases</b> <button onclick="expAll(true)">All</button><button onclick="expAll(false)">None</button></div>
 <div id="expDbs" style="max-height:150px;overflow:auto;border:1px solid var(--bd2);padding:6px"></div>
 <div class="row"><b>Options</b></div><div class="grid2" id="expOpts"></div>
 <div class="row"><label title="How a NULL is written to CSV. \N is what LOAD DATA reads back; blank makes NULL and an empty string indistinguishable in the file.">NULL value <input id="expNullVal" value="\N" style="width:52px;font-family:Consolas,monospace"></label> Charset <select id="expCharset"><option>utf8mb4</option><option>utf8</option><option>latin1</option><option>binary</option></select>
  <label title="One .sql file per table or view - lets you restore a single table (like Workbench Dump Project Folder). All files come from one dump of the database, so they are consistent with each other."><input type="radio" name="expmode" id="expTable" checked onchange="expSyncFilenameField()"> per table</label><label title="One .sql file per database."><input type="radio" name="expmode" id="expPer" onchange="expSyncFilenameField()"> per DB</label><label title="Everything in one combined .sql file."><input type="radio" name="expmode" id="expSingle" onchange="expSyncFilenameField()"> single file</label>
  <label title="Append a date-time stamp to each file name."><input type="checkbox" id="expStamp" checked onchange="expUpdateFilenamePreview()"> timestamp</label>
  <label title="mysqldump --max-allowed-packet. Raise this for very large rows or BLOBs (e.g. 1G).">max packet <input id="expMaxPacket" value="1G" style="width:56px"></label>
  <div id="expFilenameRow" title="Only applies to \u201Csingle file\u201D mode - db/table mode each produce one file per object, so a manual name has nowhere to go. Leave blank to keep the default (all_selected)." style="display:none;flex-direction:column;gap:2px">
  <div class="row" style="flex:none">Filename <input id="expFilename" placeholder="all_selected" maxlength="100" style="flex:1" oninput="expUpdateFilenamePreview()"><span id="expFilenameCount" class="muted" style="font-size:10px;white-space:nowrap;display:none"></span></div>
  <div id="expFilenamePreview" class="muted" style="font-size:11px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis"></div>
 </div></div>
 <div class="row">Folder <input id="expFolder" style="flex:1" value="C:\temp"><button onclick="browse({title:'Select export folder',mode:'folder',start:$('expFolder').value,onPick:pp=>$('expFolder').value=pp})">Browse...</button></div>
 <div class="row"><button class="go" id="expGoBtn" onclick="runExport()">Start Export</button><button class="warn" id="expCancelBtn" disabled onclick="cancelJob('exp')">Cancel</button><button onclick="hide('mExport')">Close</button></div>
 <div id="expProgress" style="display:none;margin-top:8px">
   <div style="height:6px;border-radius:3px;background:var(--panel2);overflow:hidden"><div id="expBar" style="height:100%;width:40%;background:var(--accent);animation:expmove 1.1s ease-in-out infinite"></div></div>
   <div id="expProgLabel" class="muted" style="font-size:11px;margin-top:4px"></div>
 </div>
 <div id="expLog" class="logpanel" style="white-space:pre-wrap;font-family:'Cascadia Code',Consolas,'SF Mono',Menlo,'DejaVu Sans Mono',monospace;font-size:11px;max-height:220px;overflow:auto;margin-top:6px"></div></div></div>

<div class="modal floating" id="mImport"><div class="box" style="top:80px;left:200px"><div style="display:flex;align-items:center;justify-content:space-between;cursor:move;user-select:none" onmousedown="floatDragStart(event,'mImport')" title="Drag to move"><h3 style="margin:0">Data Import</h3><span style="display:flex;gap:2px"><span onmousedown="event.stopPropagation()" onclick="floatToggleMaximize('mImport')" title="Maximize" id="maxBtn_mImport" style="cursor:pointer;padding:2px 10px;font-weight:700;font-size:14px;line-height:1">&#9974;</span><span onmousedown="event.stopPropagation()" onclick="floatMinimize('mImport')" title="Minimize" style="cursor:pointer;padding:2px 10px;font-weight:700;font-size:16px;line-height:1">&#8722;</span></span></div><div class="row">SQL file paths (one per line):</div>
 <textarea id="impFiles" style="width:100%;height:90px;font-family:'Cascadia Code',Consolas,'SF Mono',Menlo,'DejaVu Sans Mono',monospace;font-size:11px;white-space:pre;overflow:auto"></textarea>
 <div class="row"><button onclick="impAddFiles()">Add files...</button><button onclick="impAddFolder()">Add folder (all .sql)...</button><button class="sm" onclick="$('impFiles').value=''">Clear</button></div>
 <div class="row">Target DB <input id="impDb" list="impDbList" placeholder="(blank if dump has CREATE DATABASE)" style="width:320px"><datalist id="impDbList"></datalist></div>
 <div class="row"><label title="Create the target database first if it doesn't exist"><input type="checkbox" id="impCreate"> create DB</label><label title="Disable foreign-key and unique checks during import (for out-of-order or circular tables)"><input type="checkbox" id="impFk" checked> disable FK checks</label><label title="Keep going when a file or statement fails instead of stopping (mysql --force)"><input type="checkbox" id="impForce"> continue on errors</label><label title="Required if the dump contains raw NUL bytes in binary/text columns (fixes: ASCII '\0' appeared in the statement). Safe to leave on for any dump that might contain binary data."><input type="checkbox" id="impBinary"> binary-mode</label><label title="mysql --max-allowed-packet. Raise this to match (or exceed) whatever the dump was exported with - a file created with a bumped packet size (needed for extended-insert with large rows/BLOBs) can otherwise fail to re-import with &quot;MySQL server has gone away&quot; against this client's smaller default (16M).">max packet <input id="impMaxPacket" value="1G" style="width:56px"></label></div>
 <div class="row"><button class="go" id="impGoBtn" onclick="runImport()">Run Import</button><button class="warn" id="impCancelBtn" disabled onclick="cancelJob('imp')">Cancel</button><button onclick="hide('mImport')">Close</button></div>
 <div id="impProgress" style="display:none;margin-top:8px">
   <div style="height:6px;border-radius:3px;background:var(--panel2);overflow:hidden"><div id="impBar" style="height:100%;width:40%;background:var(--accent);animation:expmove 1.1s ease-in-out infinite"></div></div>
   <div id="impProgLabel" class="muted" style="font-size:11px;margin-top:4px"></div>
 </div>
 <div id="impLog" class="logpanel" style="white-space:pre-wrap;font-family:'Cascadia Code',Consolas,'SF Mono',Menlo,'DejaVu Sans Mono',monospace;font-size:11px;max-height:220px;overflow:auto;margin-top:6px"></div></div></div>

<div class="modal floating" id="mCompare"><div class="box" style="width:820px;max-width:94vw;top:50px;left:90px"><div style="display:flex;align-items:center;justify-content:space-between;cursor:move;user-select:none" onmousedown="floatDragStart(event,'mCompare')" title="Drag to move"><h3 style="margin:0">Compare Databases <span class="muted" style="font-size:13px;cursor:help;font-weight:400" title="Connects to both sides independently of whatever's currently active, using each saved connection's stored password - so both the source and target connection need &quot;Save password&quot; checked (Edit... on the connection) or this will fail to log in.">&#9432;</span></h3><span style="display:flex;gap:2px"><span onmousedown="event.stopPropagation()" onclick="floatToggleMaximize('mCompare')" title="Maximize" id="maxBtn_mCompare" style="cursor:pointer;padding:2px 10px;font-weight:700;font-size:14px;line-height:1">&#9974;</span><span onmousedown="event.stopPropagation()" onclick="floatMinimize('mCompare')" title="Minimize" style="cursor:pointer;padding:2px 10px;font-weight:700;font-size:16px;line-height:1">&#8722;</span></span></div>
 <div class="row" style="display:flex;gap:10px">
   <div style="flex:1"><div class="muted" style="font-size:11px;margin-bottom:3px">Source</div>
     <select id="cmpSrcConn" style="width:100%" onchange="cmpResetResults();cmpLoadDbs('src')"></select>
     <select id="cmpSrcDb" style="width:100%;margin-top:4px" onchange="cmpResetResults();cmpSrcDbChanged()"></select></div>
   <div style="align-self:center;color:var(--accent);font-size:16px;padding-top:16px">&#8594;</div>
   <div style="flex:1"><div class="muted" style="font-size:11px;margin-bottom:3px">Target</div>
     <select id="cmpTgtConn" style="width:100%" onchange="cmpResetResults();cmpLoadDbs('tgt')"></select>
     <select id="cmpTgtDb" style="width:100%;margin-top:4px" onchange="cmpResetResults();cmpResetTablePicker()"></select></div>
 </div>
 <div class="row"><a href="#" onclick="cmpToggleTablePicker();return false" style="font-size:11px;color:var(--accent)">Choose specific tables (optional)</a></div>
<div id="cmpTablesBox" style="display:none;max-height:140px;overflow:auto;border:1px solid var(--bd2);border-radius:4px;padding:4px 8px;margin-bottom:6px"></div>
<div class="row"><button class="go" onclick="runCompare()">Run comparison</button><span id="cmpRoNote" class="muted" style="font-size:11px;margin-left:8px;display:none;color:var(--del)">Target is read-only / safe mode - apply will be blocked.</span></div>
 <div class="row" id="cmpTallyRow" style="display:none"><span id="cmpTally" class="muted" style="font-size:11px"></span></div>
 <div class="row" id="cmpRowScanRow" style="display:none"><button id="cmpRowScanBtn" onclick="cmpScanRowDiffs()" title="For every table marked structure identical, run the same missing-rows + content check that clicking rows\u2026 on it does - just automatically, one table at a time, so you know which ones are worth opening. If &quot;Choose specific tables&quot; has checked tables, only those are scanned.">Check row differences</button><span id="cmpRowScanStatus" class="muted" style="font-size:11px;margin-left:8px"></span></div>
 <div class="row" id="cmpResultsSearchRow" style="display:none"><input id="cmpResultSearch" type="text" placeholder="filter results by table name\u2026" oninput="cmpFilterResults()" style="width:100%;font-size:12px"></div>
 <div id="cmpResults" style="max-height:320px;overflow:auto;margin-top:6px"></div>
 <div class="row" style="display:flex;justify-content:space-between;align-items:center">
   <span id="cmpSummary" class="muted" style="font-size:11px"></span>
   <span style="display:inline-flex;gap:6px"><button onclick="previewCompareSql()">Preview SQL</button><button class="go write" onclick="applyCompare()">Apply to target</button><button onclick="cmpCloseAndCancel()">Close</button></span>
 </div>
 <div id="cmpLog" class="logpanel" style="white-space:pre-wrap;font-family:'Cascadia Code',Consolas,'SF Mono',Menlo,'DejaVu Sans Mono',monospace;font-size:11px;max-height:140px;overflow:auto;margin-top:6px"></div>
</div></div>

<div class="modal floating" id="mCompareRows"><div class="box" style="width:900px;max-width:96vw;top:50px;left:110px"><div style="display:flex;align-items:center;justify-content:space-between;cursor:move;user-select:none" onmousedown="floatDragStart(event,'mCompareRows')" title="Drag to move"><h3 id="cmprTitle" style="margin:0">Row comparison</h3><span style="display:flex;gap:2px"><span onmousedown="event.stopPropagation()" onclick="floatToggleMaximize('mCompareRows')" title="Maximize" id="maxBtn_mCompareRows" style="cursor:pointer;padding:2px 10px;font-weight:700;font-size:14px;line-height:1">&#9974;</span><span onmousedown="event.stopPropagation()" onclick="floatMinimize('mCompareRows')" title="Minimize" style="cursor:pointer;padding:2px 10px;font-weight:700;font-size:16px;line-height:1">&#8722;</span></span></div>

 <div class="muted" style="font-size:12px;font-weight:600;margin-top:4px">Missing on target</div>
 <div id="cmprNote" class="muted" style="font-size:11px;margin-bottom:6px"></div>
 <div class="row"><a href="#" onclick="cmprSetAll(true);return false" style="font-size:11px;color:var(--accent)">All</a> / <a href="#" onclick="cmprSetAll(false);return false" style="font-size:11px;color:var(--accent)">None</a> <span id="cmprSummary" class="muted" style="font-size:11px;margin-left:8px"></span></div>
 <div id="cmprGrid" style="max-height:220px;overflow:auto;border:1px solid var(--bd2);border-radius:4px;margin-top:4px"></div>
 <div class="row" style="display:flex;align-items:center;gap:10px">
   <button class="go write" onclick="cmprApply()">Insert selected rows</button>
   <span id="cmprRoNote" class="muted" style="font-size:11px;display:none;color:var(--del)">Target is read-only / safe mode - blocked.</span>
   <span id="cmprMissingNote" class="muted" style="font-size:11px;display:none;color:var(--del)">Table doesn't exist on the target yet - create it first (via the schema comparison's "details"), then come back to insert rows.</span>
 </div>

 <div class="muted" style="font-size:12px;font-weight:600;margin-top:14px">Column differences (rows matched by id, content compared column-by-column)</div>
 <div id="cmprDiffNote" class="muted" style="font-size:11px;margin-bottom:6px"></div>
 <div class="row"><a href="#" onclick="cmprDiffSetAll(true);return false" style="font-size:11px;color:var(--accent)">All</a> / <a href="#" onclick="cmprDiffSetAll(false);return false" style="font-size:11px;color:var(--accent)">None</a> <span id="cmprDiffSummary" class="muted" style="font-size:11px;margin-left:8px"></span></div>
 <div id="cmprDiffGrid" style="max-height:220px;overflow:auto;border:1px solid var(--bd2);border-radius:4px;margin-top:4px"></div>
 <div class="row" style="display:flex;align-items:center;gap:10px">
   <button class="warn write" onclick="cmprDiffApply()" title="Overwrites the target row's differing columns with the source values shown">Update selected rows (overwrites target)</button>
   <span id="cmprDiffRoNote" class="muted" style="font-size:11px;display:none;color:var(--del)">Target is read-only / safe mode - blocked.</span>
 </div>

 <div class="row" style="display:flex;justify-content:flex-end;margin-top:6px"><button onclick="cmprCloseAndCancel()">Close</button></div>
 <div id="cmprLog" class="muted" style="white-space:pre-wrap;font-family:'Cascadia Code',Consolas,'SF Mono',Menlo,'DejaVu Sans Mono',monospace;font-size:11px;max-height:120px;overflow:auto;margin-top:6px"></div>
</div></div>

<div class="modal floating" id="mUsers"><div class="box" style="width:1050px;max-width:96vw;top:40px;left:70px"><div style="display:flex;align-items:center;justify-content:space-between;cursor:move;user-select:none" onmousedown="floatDragStart(event,'mUsers')" title="Drag to move"><h3 style="margin:0">Users &amp; Privileges</h3><span style="display:flex;gap:2px"><span onmousedown="event.stopPropagation()" onclick="floatToggleMaximize('mUsers')" title="Maximize" id="maxBtn_mUsers" style="cursor:pointer;padding:2px 10px;font-weight:700;font-size:14px;line-height:1">&#9974;</span><span onmousedown="event.stopPropagation()" onclick="floatMinimize('mUsers')" title="Minimize" style="cursor:pointer;padding:2px 10px;font-weight:700;font-size:16px;line-height:1">&#8722;</span></span></div>
 <div class="row" style="align-items:flex-start"><div id="userSel" style="min-width:240px;height:260px;overflow:auto;border:1px solid var(--bd2);border-radius:4px"></div>
  <div style="flex:1"><div id="grantsBox" class="muted" style="white-space:pre-wrap;font-family:'Cascadia Code',Consolas,'SF Mono',Menlo,'DejaVu Sans Mono',monospace;height:260px;overflow:auto;border:1px solid var(--bd2);padding:6px"></div></div></div>
 <div class="row"><button onclick="newUser()">Create user...</button><span class="tbsep"></span><button onclick="grantUser()">Grant...</button><button onclick="revokeUser()">Revoke...</button><span class="tbsep"></span><button onclick="changePassword()">Change password...</button><button onclick="lockUser(true)" title="Disable this login (ACCOUNT LOCK)">Lock</button><button onclick="lockUser(false)" title="Re-enable this login (ACCOUNT UNLOCK)">Unlock</button><span class="tbsep"></span><button onclick="openUserTransfer()" title="Build CREATE USER + GRANT statements to migrate accounts to another server">Transfer script...</button><span class="tbsep"></span><button class="warn" onclick="dropUser()">Drop user</button><span style="flex:1"></span><button onclick="hide('mUsers')">Close</button></div></div></div>

<div class="modal floating" id="mUserTransfer"><div class="box" style="width:820px;max-width:94vw;top:60px;left:130px"><div style="display:flex;align-items:center;justify-content:space-between;cursor:move;user-select:none" onmousedown="floatDragStart(event,'mUserTransfer')" title="Drag to move"><h3 style="margin:0">Generate User Transfer Script</h3><span style="display:flex;gap:2px"><span onmousedown="event.stopPropagation()" onclick="floatToggleMaximize('mUserTransfer')" title="Maximize" id="maxBtn_mUserTransfer" style="cursor:pointer;padding:2px 10px;font-weight:700;font-size:14px;line-height:1">&#9974;</span><span onmousedown="event.stopPropagation()" onclick="floatMinimize('mUserTransfer')" title="Minimize" style="cursor:pointer;padding:2px 10px;font-weight:700;font-size:16px;line-height:1">&#8722;</span></span></div>
 <div class="muted" style="margin-bottom:8px">Uses SHOW CREATE USER and SHOW GRANTS FOR against this connection - the same statements the server itself would emit, so the correct auth plugin, password hash, column/routine grants, and grant options all come through correctly (works on MySQL and MariaDB alike). CREATE USER statements are listed first so the grants below can reference them. Copy or save the result and run it on the TARGET server.</div>
 <div class="row"><b>Exclude these accounts</b> <input id="utExclude" style="flex:1" value="mysql.sys,mysql.session,mysql.infoschema,root,debian-sys-maint,mariadb.sys,healthcheck,mariabackup,galera,replica,PUBLIC"></div>
 <div class="row"><button class="go" onclick="genUserTransfer()">Generate</button><span id="utStatus" class="muted" style="margin-left:8px"></span></div>
 <textarea id="utResult" readonly style="width:100%;height:340px;box-sizing:border-box;font-family:'Cascadia Code',Consolas,'SF Mono',Menlo,'DejaVu Sans Mono',monospace;font-size:12px;margin-top:8px"></textarea>
 <div class="row"><button onclick="copyUserTransfer()">Copy</button><button onclick="saveUserTransferFile()">Save to file...</button><button onclick="hide('mUserTransfer')">Close</button></div>
</div></div>

<div class="modal floating" id="mErd"><div class="box" style="width:96vw;max-width:1400px;height:92vh;display:flex;flex-direction:column;top:40px;left:60px"><div style="display:flex;align-items:center;justify-content:space-between;cursor:move;user-select:none" onmousedown="floatDragStart(event,'mErd')" title="Drag to move"><h3 id="erdTitle" style="margin:0">ER Diagram</h3><span style="display:flex;gap:2px"><span onmousedown="event.stopPropagation()" onclick="floatToggleMaximize('mErd')" title="Maximize" id="maxBtn_mErd" style="cursor:pointer;padding:2px 10px;font-weight:700;font-size:14px;line-height:1">&#9974;</span><span onmousedown="event.stopPropagation()" onclick="floatMinimize('mErd')" title="Minimize" style="cursor:pointer;padding:2px 10px;font-weight:700;font-size:16px;line-height:1">&#8722;</span></span></div>
 <div class="muted" style="margin-bottom:6px">Foreign key relationships for this schema. Primary key columns are highlighted. Simple grid layout - not auto-arranged for minimal crossing lines, but functional for getting an overview.</div>
 <div id="erdStatus" class="muted" style="margin-bottom:6px;font-size:11px"></div>
 <div class="row" style="margin-bottom:6px"><input id="erdFind" placeholder="Find table..." style="width:240px" oninput="erdFindTable()"><label style="display:inline-flex;align-items:center;gap:5px;margin-left:10px;font-size:12px;color:var(--muted)"><input type="checkbox" id="erdOnlyRelated" checked onchange="erdRender()"> Only show tables with a relationship</label><button class="sm" onclick="erdExportPng()" title="Save the diagram as a PNG image, at its full size regardless of current zoom" style="margin-left:14px">Export PNG</button></div>
 <div style="position:relative;flex:1;min-height:0">
  <div id="erdBox" style="position:absolute;inset:0;overflow:auto;border:1px solid var(--bd2);background:var(--bg);cursor:grab" onmousedown="erdPanStart(event)" ondblclick="erdDblClickZoom(event)" title="Drag to pan the diagram - Double-click to zoom in - Shift+double-click to zoom out"></div>
  <div style="position:absolute;bottom:10px;right:10px;display:flex;align-items:center;gap:4px;background:var(--panel);border:1px solid var(--bd2);border-radius:6px;padding:4px 6px;box-shadow:0 2px 8px rgba(0,0,0,.3)">
   <button class="sm" onclick="erdZoomOut()" title="Zoom out">&minus;</button>
   <span id="erdZoomLabel" class="muted" style="font-size:11px;min-width:36px;text-align:center;display:inline-block">100%</span>
   <button class="sm" onclick="erdZoomIn()" title="Zoom in">+</button>
   <button class="sm" onclick="erdZoomReset()" title="Reset zoom to 100%" style="margin-left:2px">Reset</button>
  </div>
 </div>
 <div class="row" style="justify-content:flex-end"><button onclick="hide('mErd')">Close</button></div>
</div></div>

<div class="modal floating" id="mProcessList"><div class="box" style="width:900px;max-width:96vw;top:40px;left:140px" id="mProcessListBox"><div style="display:flex;align-items:center;justify-content:space-between;cursor:move;user-select:none" onmousedown="floatDragStart(event,'mProcessList')" title="Drag to move"><h3 style="margin:0">Server Processes</h3><span style="display:flex;gap:2px"><span onmousedown="event.stopPropagation()" onclick="floatToggleMaximize('mProcessList')" title="Maximize" id="maxBtn_mProcessList" style="cursor:pointer;padding:2px 10px;font-weight:700;font-size:14px;line-height:1">&#9974;</span><span onmousedown="event.stopPropagation()" onclick="floatMinimize('mProcessList')" title="Minimize" style="cursor:pointer;padding:2px 10px;font-weight:700;font-size:16px;line-height:1">&#8722;</span></span></div>
 <div class="row"><button onclick="refreshProcessList()">Refresh</button><label title="This connection's own SHOW PROCESSLIST row is filtered out by default, since it's always present and can never actually be killed - check this to reveal it anyway." style="display:inline-flex;align-items:center;gap:5px;margin-left:10px;font-size:12px;color:var(--muted)"><input type="checkbox" id="plShowHidden" onchange="refreshProcessList()"> Show hidden</label><label style="display:inline-flex;align-items:center;gap:5px;margin-left:10px;font-size:12px;color:var(--muted)"><input type="checkbox" id="plAutoRefresh" onchange="plToggleAutoRefresh()"> Auto-refresh (3s)</label><span id="plStatus" class="muted" style="margin-left:8px"></span></div>
 <div id="plGrid" style="max-height:60vh;overflow:auto;border:1px solid var(--bd2);margin-top:8px"></div>
 <div class="row" style="justify-content:flex-end"><button onclick="hide('mProcessList')">Close</button></div>
</div></div>

<div class="modal floating" id="mHist"><div class="box" style="top:60px;left:100px"><div style="display:flex;align-items:center;justify-content:space-between;cursor:move;user-select:none" onmousedown="floatDragStart(event,'mHist')" title="Drag to move"><h3 style="margin:0">Query History</h3><span style="display:flex;gap:2px"><span onmousedown="event.stopPropagation()" onclick="floatToggleMaximize('mHist')" title="Maximize" id="maxBtn_mHist" style="cursor:pointer;padding:2px 10px;font-weight:700;font-size:14px;line-height:1">&#9974;</span><span onmousedown="event.stopPropagation()" onclick="floatMinimize('mHist')" title="Minimize" style="cursor:pointer;padding:2px 10px;font-weight:700;font-size:16px;line-height:1">&#8722;</span></span></div>
 <div id="histList" style="max-height:400px;overflow:auto"></div>
 <div class="row"><button class="warn" onclick="clearHistory()">Clear history</button><button onclick="hide('mHist')">Close</button></div></div></div>
<div class="modal floating" id="mRowForm"><div class="box" style="width:560px;max-width:94vw;top:70px;left:160px"><div style="display:flex;align-items:center;justify-content:space-between;cursor:move;user-select:none" onmousedown="floatDragStart(event,'mRowForm')" title="Drag to move"><h3 id="rfTitle" style="margin:0">Edit row</h3><span onmousedown="event.stopPropagation()" onclick="floatMinimize('mRowForm')" title="Minimize" style="cursor:pointer;padding:2px 10px;font-weight:700;font-size:16px;line-height:1">&#8722;</span></div>
 <div id="rfFields" style="max-height:60vh;overflow:auto"></div>
 <div class="row" style="justify-content:flex-end;margin-top:6px"><button class="go" onclick="rfSave()">Save to pending</button><button onclick="hide('mRowForm')">Cancel</button></div></div></div>
<div class="modal floating" id="mSettings"><div class="box" style="width:1300px;max-width:96vw;top:40px;left:80px"><div style="display:flex;align-items:center;justify-content:space-between;cursor:move;user-select:none" onmousedown="floatDragStart(event,'mSettings')" title="Drag to move"><h3 style="margin:0">Client tools</h3><span onmousedown="event.stopPropagation()" onclick="floatMinimize('mSettings')" title="Minimize" style="cursor:pointer;padding:2px 10px;font-weight:700;font-size:16px;line-height:1">&#8722;</span></div>
 <div class="muted" style="font-size:12px">Export, Import and multi-statement Run use the MySQL/MariaDB command-line tools.<br>They are not bundled - point to an existing install, or download them automatically.</div>
 <div style="margin:10px 0 4px;font-size:11px;font-weight:700;letter-spacing:.6px;color:var(--muted)">STATUS</div>
 <div id="cfgStatus" class="muted" style="font-size:12px;margin:2px 0 8px"></div>
 <div class="toolcards">
  <div class="toolcard" id="cfgCardMaria">
   <div class="toolcard-h"><span class="tooldot" style="background:#c0765a"></span>For MariaDB servers</div>
   <div class="muted" style="font-size:11px;line-height:1.5;margin-bottom:6px">Also used for a MySQL server when there are no MySQL tools. MariaDB's client tools are the usual choice here.</div>
   <div id="cfgStatusMaria" class="toolstatus"></div>
   <div class="row"><span style="width:92px">mysql</span><input id="cfgMysql" style="flex:1" placeholder="full path to mysql.exe (or mariadb.exe)"><button onclick="browse({title:'Select mysql.exe / mariadb.exe',filter:'*.exe',mode:'file',onPick:pp=>$('cfgMysql').value=pp})">Browse...</button></div>
   <div class="row"><span style="width:92px">mysqldump</span><input id="cfgDump" style="flex:1" placeholder="full path to mysqldump.exe (or mariadb-dump.exe)"><button onclick="browse({title:'Select mysqldump.exe / mariadb-dump.exe',filter:'*.exe',mode:'file',onPick:pp=>$('cfgDump').value=pp})">Browse...</button></div>
   <div class="row" style="margin-top:6px"><button class="go" onclick="downloadTools()">Download MariaDB client tools</button><span class="muted" style="font-size:12px">The latest LTS client for Windows from mariadb.org (~90 MB).</span></div>
   <details style="margin-top:6px"><summary class="muted" style="font-size:11px;cursor:pointer">Download address</summary>
    <div class="row" style="margin-top:6px"><span style="width:92px">URL</span><input id="cfgDownloadUrl" style="flex:1;font-family:Consolas,monospace;font-size:11px" placeholder="https://mirror.mariadb.org/mariadb-{version}/winx64-packages/{file_name}"><button onclick="resetDownloadUrl()" title="Reset to the built-in default">Reset</button></div>
    <div class="muted" style="font-size:11px;line-height:1.4;margin:2px 0 0">{version} and {file_name} are filled in from the latest MariaDB LTS release. Only change this if the download fails (mariadb.org occasionally changes its layout) - the error message shows what happened.</div>
   </details>
  </div>
  <div class="toolcard" id="cfgCardMysql">
   <div class="toolcard-h"><span class="tooldot" style="background:#00758f"></span>For MySQL servers <span class="muted" style="font-weight:400">- optional</span></div>
   <div class="muted" style="font-size:11px;line-height:1.5;margin-bottom:6px">This edition runs everything through mysql.exe, so a MySQL server gets MySQL's own tools throughout - queries as well as Export and Import: these two paths, or else the newest MySQL Server installation (Program Files\MySQL\MySQL Server *\bin). MariaDB's mysqldump cannot make a restorable dump of a MySQL table with generated columns, and only MySQL's client checks a CA without the host name. Leave empty to detect automatically.</div>
   <div id="cfgStatusMysql" class="toolstatus"></div>
   <div class="row"><span style="width:92px">mysql</span><input id="cfgMysqlMy" style="flex:1" placeholder="MySQL's mysql.exe - empty: detect a MySQL Server installation"><button onclick="browse({title:'Select MySQL\'s mysql.exe',filter:'*.exe',mode:'file',onPick:pp=>$('cfgMysqlMy').value=pp})">Browse...</button></div>
   <div class="row"><span style="width:92px">mysqldump</span><input id="cfgDumpMy" style="flex:1" placeholder="MySQL's mysqldump.exe - empty: detect a MySQL Server installation"><button onclick="browse({title:'Select MySQL\'s mysqldump.exe',filter:'*.exe',mode:'file',onPick:pp=>$('cfgDumpMy').value=pp})">Browse...</button></div>
   <div class="row" style="margin-top:6px"><button class="go" onclick="downloadMysqlTools()">Download MySQL client tools</button><span class="muted" style="font-size:12px">mysql and mysqldump from the current MySQL 8.4 LTS release on dev.mysql.com (~270 MB, of which about 14 MB is kept), checked against the MD5 MySQL publishes.</span></div>
  </div>
 </div>
 <div class="muted" style="font-size:11px;line-height:1.5;margin-top:8px">Downloaded tools do not update themselves; downloading again replaces them with the current release, whose version is shown in the card. Paths left empty are detected: saved configuration &rarr; MYSQL_BIN / MYSQLDUMP_BIN environment variables &rarr; common install folders (Program Files\MariaDB*, Program Files\MySQL*, WAMP, XAMPP) &rarr; system PATH.</div>
 <div id="cfgLog" class="muted" style="white-space:pre-wrap;font-family:Consolas,monospace;font-size:11px;max-height:120px;overflow:auto;margin-top:6px"></div>
 <div id="cfgPaths" class="muted" style="font-size:11px;font-family:Consolas,monospace;margin-top:10px;border-top:1px solid var(--bd2);padding-top:8px;line-height:1.6"></div>
 <div style="margin:12px 0 4px;font-size:11px;font-weight:700;letter-spacing:.6px;color:var(--muted)">UPDATES</div>
 <div class="row"><label class="ck" style="font-size:12px"><input type="checkbox" id="cfgUpdateCheck" onchange="setUpdateCheck(this.checked)"> At startup, check whether a newer version has been released</label><button class="sm" onclick="checkForUpdate(true)">Check now</button></div>
 <div class="muted" style="font-size:11px;line-height:1.4;margin:2px 0 0">Asks GitHub for the latest release and shows a notice in the top bar with a link. Nothing is downloaded or installed.</div>
 <div style="margin:12px 0 4px;font-size:11px;font-weight:700;letter-spacing:.6px;color:var(--muted)">LOCAL DATA</div>
 <div class="row"><button class="warn" onclick="clearAllData()">Clear all app data</button></div>
 <hr style="border:none;border-top:1px solid var(--bd2);margin:10px 0">
 <div class="row" style="gap:8px"><button class="sm needsconn" title="Clear the database overview cache and reload" onclick="clearOverviewCache()">Refresh Cache</button><button class="sm" title="Toggle light / dark theme" onclick="toggleTheme()">Switch Theme</button><button class="sm" title="Keyboard shortcuts" onclick="show('mShortcuts')">Shortcut Info</button><button class="sm" title="Version, license and project information" onclick="openAbout()">About</button></div>
 <div class="row" style="justify-content:flex-end;margin-top:12px"><button class="go" onclick="saveSettings()">Save</button><button onclick="hide('mSettings')">Close</button></div></div></div>
<div class="modal floating" id="mAbout"><div class="box" style="width:560px;max-width:92vw;top:70px;left:150px"><div style="display:flex;align-items:center;justify-content:space-between;cursor:move;user-select:none" onmousedown="floatDragStart(event,'mAbout')" title="Drag to move"><h3 id="aboutTitle" style="margin:0">NOBS SQL Editor __APP_VERSION__</h3><span onmousedown="event.stopPropagation()" onclick="floatMinimize('mAbout')" title="Minimize" style="cursor:pointer;padding:2px 10px;font-weight:700;font-size:16px;line-height:1">&#8722;</span></div>
 <div class="muted" style="font-size:12px;line-height:1.6">
  A lightweight client for MySQL and MariaDB, running as a single PowerShell script.<br>
  Copyright &copy; 2026 Viktor Ljuca
 </div>
 <div style="margin:12px 0 4px;font-size:11px;font-weight:700;letter-spacing:.6px;color:var(--muted)">LICENSE</div>
 <div class="muted" style="font-size:12px;line-height:1.6">
  This program is free software: you may redistribute and/or modify it under the terms of the
  <b>GNU General Public License version 2</b>, or (at your option) any later version.<br>
  It is distributed in the hope that it will be useful, but <b>WITHOUT ANY WARRANTY</b> - without
  even the implied warranty of merchantability or fitness for a particular purpose. See the
  GNU General Public License for details.
 </div>
 <div style="margin:12px 0 4px;font-size:11px;font-weight:700;letter-spacing:.6px;color:var(--muted)">LINKS</div>
 <div class="muted" style="font-size:12px;line-height:1.8;font-family:Consolas,monospace;user-select:text">
  Website&nbsp;&nbsp;&nbsp;https://monsama.ch<br>
  Source&nbsp;&nbsp;&nbsp;&nbsp;https://github.com/monsama/nobs-sql-editor-powershell<br>
  License&nbsp;&nbsp;&nbsp;https://www.gnu.org/licenses/old-licenses/gpl-2.0.html
 </div>
 <div style="margin:12px 0 4px;font-size:11px;font-weight:700;letter-spacing:.6px;color:var(--muted)">THIRD PARTY</div>
 <div class="muted" style="font-size:11px;line-height:1.6">
  Runs on Windows PowerShell with the .NET base class library; no third-party modules are
  required. The MySQL / MariaDB client tools are not bundled; the MariaDB client tools, when
  downloaded, are &copy; MariaDB Foundation under GPLv2 and come from mariadb.org.
 </div>
 <div class="row" style="justify-content:flex-end;margin-top:14px"><button onclick="hide('mAbout')">Close</button></div></div></div>
<div class="modal floating" id="mShortcuts"><div class="box" style="width:560px;max-width:92vw;top:70px;left:170px"><div style="display:flex;align-items:center;justify-content:space-between;cursor:move;user-select:none" onmousedown="floatDragStart(event,'mShortcuts')" title="Drag to move"><h3 style="margin:0">Keyboard shortcuts &amp; tips</h3><span onmousedown="event.stopPropagation()" onclick="floatMinimize('mShortcuts')" title="Minimize" style="cursor:pointer;padding:2px 10px;font-weight:700;font-size:16px;line-height:1">&#8722;</span></div>
 <table style="border-collapse:collapse;font-size:13px"><tr><td style="padding:3px 14px 3px 0;white-space:nowrap"><kbd>F5</kbd></td><td style="padding:3px 0;color:var(--muted)">Run the whole query</td></tr><tr><td style="padding:3px 14px 3px 0;white-space:nowrap"><kbd>Ctrl + Enter</kbd></td><td style="padding:3px 0;color:var(--muted)">Run the selected text (or all, if nothing is selected)</td></tr><tr><td style="padding:3px 14px 3px 0;white-space:nowrap"><kbd>Ctrl + Space</kbd></td><td style="padding:3px 0;color:var(--muted)">Autocomplete</td></tr><tr><td style="padding:3px 14px 3px 0;white-space:nowrap"><kbd>Tab</kbd></td><td style="padding:3px 0;color:var(--muted)">Indent (in the editor)</td></tr><tr><td style="padding:3px 14px 3px 0;white-space:nowrap"><kbd>Ctrl + D</kbd></td><td style="padding:3px 0;color:var(--muted)">Duplicate the current line (or every line touched by the selection) below</td></tr><tr><td style="padding:3px 14px 3px 0;white-space:nowrap"><kbd>Ctrl + /</kbd></td><td style="padding:3px 0;color:var(--muted)">Toggle "-- " comment on the current line or selection</td></tr><tr><td style="padding:3px 14px 3px 0;white-space:nowrap"><kbd>Alt + &uarr; / &darr;</kbd></td><td style="padding:3px 0;color:var(--muted)">Move the current line (or selection) up or down</td></tr><tr><td style="padding:3px 14px 3px 0;white-space:nowrap"><kbd>Ctrl + Shift + K</kbd></td><td style="padding:3px 0;color:var(--muted)">Delete the current line (or every line touched by the selection)</td></tr><tr><td style="padding:3px 14px 3px 0;white-space:nowrap"><kbd>Ctrl + S</kbd></td><td style="padding:3px 0;color:var(--muted)">Apply pending grid edits (save changes)</td></tr><tr><td style="padding:3px 14px 3px 0;white-space:nowrap"><kbd>Ctrl + T</kbd></td><td style="padding:3px 0;color:var(--muted)">New query tab</td></tr><tr><td style="padding:3px 14px 3px 0;white-space:nowrap"><kbd>Ctrl + W</kbd></td><td style="padding:3px 0;color:var(--muted)">Close current tab</td></tr><tr><td style="padding:3px 14px 3px 0;white-space:nowrap"><kbd>Ctrl + L</kbd></td><td style="padding:3px 0;color:var(--muted)">Focus the editor and select all</td></tr><tr><td style="padding:3px 14px 3px 0;white-space:nowrap"><kbd>Enter</kbd></td><td style="padding:3px 0;color:var(--muted)">Connect (when focused in Host / Port / User / Pass)</td></tr><tr><td style="padding:3px 14px 3px 0;white-space:nowrap"><kbd>Esc</kbd></td><td style="padding:3px 0;color:var(--muted)">Close a dialog or the autocomplete popup</td></tr><tr><td style="padding:3px 14px 3px 0;white-space:nowrap"><kbd>Drag column edge</kbd></td><td style="padding:3px 0;color:var(--muted)">Resize a results column</td></tr><tr><td style="padding:3px 14px 3px 0;white-space:nowrap"><kbd>Double-click column edge</kbd></td><td style="padding:3px 0;color:var(--muted)">Auto-fit a results column</td></tr><tr><td style="padding:3px 14px 3px 0;white-space:nowrap"><kbd>Drag sidebar divider</kbd></td><td style="padding:3px 0;color:var(--muted)">Resize the schema/objects sidebar</td></tr><tr><td style="padding:3px 14px 3px 0;white-space:nowrap"><kbd>Double-click sidebar divider</kbd></td><td style="padding:3px 0;color:var(--muted)">Reset the sidebar width</td></tr></table>
 <div class="row" style="justify-content:flex-end;margin-top:14px"><button onclick="hide('mShortcuts')">Close</button></div></div></div>
<div class="modal floating" id="mInput"><div class="box" style="width:460px;max-width:92vw;display:flex;flex-direction:column;overflow:hidden;top:90px;left:200px"><div style="display:flex;align-items:center;justify-content:space-between;cursor:move;user-select:none;flex:none" onmousedown="floatDragStart(event,'mInput')" title="Drag to move"><h3 id="inpTitle" style="margin:0">Input</h3><span onmousedown="event.stopPropagation()" onclick="floatMinimize('mInput')" title="Minimize" style="cursor:pointer;padding:2px 10px;font-weight:700;font-size:16px;line-height:1">&#8722;</span></div>
 <div id="inpFields" style="flex:1 1 auto;min-height:0;overflow:auto"></div>
 <div class="row" style="justify-content:flex-end;margin-top:6px;flex:none"><button class="go" id="inpOk" onclick="inpOk()">OK</button><button onclick="inpCancel()">Cancel</button></div></div></div>
<div class="modal floating" id="mLib"><div class="box" style="width:640px;max-width:92vw;top:60px;left:180px"><div style="display:flex;align-items:center;justify-content:space-between;cursor:move;user-select:none" onmousedown="floatDragStart(event,'mLib')" title="Drag to move"><h3 style="margin:0">Query Library</h3><span style="display:flex;gap:2px"><span onmousedown="event.stopPropagation()" onclick="floatToggleMaximize('mLib')" title="Maximize" id="maxBtn_mLib" style="cursor:pointer;padding:2px 10px;font-weight:700;font-size:14px;line-height:1">&#9974;</span><span onmousedown="event.stopPropagation()" onclick="floatMinimize('mLib')" title="Minimize" style="cursor:pointer;padding:2px 10px;font-weight:700;font-size:16px;line-height:1">&#8722;</span></span></div>
 <div class="row"><input id="libName" placeholder="Name for the current query" maxlength="80" style="flex:1" onkeydown="if(event.key==='Enter')libSaveCurrent()"><button class="go" onclick="libSaveCurrent()">Save current query</button></div>
 <div class="row"><input id="libSearch" placeholder="Search saved queries..." oninput="libRender()" style="flex:1"></div>
 <div id="libList" style="max-height:380px;overflow:auto;border:1px solid var(--bd);border-radius:4px"></div>
 <div class="row"><button class="warn" onclick="libClearAll()" title="Delete all saved queries">Clear all</button><button onclick="libExport()" title="Download the whole library as a JSON file">Export library</button><button onclick="$('libFile').click()" title="Load a query-library.json from another machine (merges)">Import library</button><input type="file" id="libFile" accept="application/json,.json" style="display:none" onchange="libImportFile(event)"><span style="flex:1"></span><button onclick="hide('mLib')">Close</button></div></div></div>

<div class="modal floating" id="mDesign"><div class="box" style="max-width:960px;top:40px;left:100px"><div style="display:flex;align-items:center;justify-content:space-between;cursor:move;user-select:none" onmousedown="floatDragStart(event,'mDesign')" title="Drag to move"><h3 id="dTitle" style="margin:0">Table designer</h3><span style="display:flex;gap:2px"><span onmousedown="event.stopPropagation()" onclick="floatToggleMaximize('mDesign')" title="Maximize" id="maxBtn_mDesign" style="cursor:pointer;padding:2px 10px;font-weight:700;font-size:14px;line-height:1">&#9974;</span><span onmousedown="event.stopPropagation()" onclick="floatMinimize('mDesign')" title="Minimize" style="cursor:pointer;padding:2px 10px;font-weight:700;font-size:16px;line-height:1">&#8722;</span></span></div>
 <div class="row">Schema <input id="dSchema" style="width:180px"> Table <input id="dName" style="width:220px"> <span id="dMode" class="muted"></span></div>
 <table class="dz"><thead><tr><th>Column</th><th>Type</th><th>Length</th><th title="NOT NULL">NN</th><th title="AUTO_INCREMENT">AI</th><th title="PRIMARY KEY">PK</th><th>Default</th><th>Comment</th><th></th></tr></thead><tbody id="dCols"></tbody></table>
 <div class="row"><button onclick="dAddCol()">+ Column</button></div>
 <div class="row">Generated SQL: <span id="dEditNote" class="muted" style="color:#b26a00"></span></div><textarea id="dSql" oninput="dMark()" style="width:100%;height:120px;font-family:'Cascadia Code',Consolas,'SF Mono',Menlo,'DejaVu Sans Mono',monospace"></textarea>
 <div class="row"><button title="Rebuild the SQL from the column grid (discards manual edits in the box)" onclick="dGen(true)">Regenerate from columns</button><button class="go write" title="Run the SQL shown above against the database - creates the table if it's new, or alters it if it already exists" onclick="dApply()">Apply</button><button onclick="hide('mDesign')">Close</button></div>
 <div id="dLog" class="muted" style="white-space:pre-wrap;font-family:'Cascadia Code',Consolas,'SF Mono',Menlo,'DejaVu Sans Mono',monospace;font-size:11px;max-height:220px;overflow:auto;margin-top:6px"></div></div></div>

<script>
const TOKEN="__TOKEN__";
const PAGE_BATCH=1000;
let curSchema=null, tabs=[], tabSeq=0, activeTab=null;
/* ============================================================================
   FRONT-END (runs in the browser)
   ----------------------------------------------------------------------------
   This whole app is ONE HTML page. All talking to the database goes through
   api('/api/...') -> the PowerShell server -> mysql.exe -> back as JSON.

   Big pieces below, in order:
     - helpers ($ = getElementById, esc = HTML-escape, log = status line)
     - api() ....... the single function that calls the server
     - connections . save / pick / primary / read-only handling
     - schemas + objects sidebar
     - query tabs .. editor with syntax highlight + autocomplete
     - results grid  sortable, filterable, editable, resizable columns
     - overview .... per-database summary + size caching
     - library ..... saved queries (stored on the server)
   NOTE: this text lives inside a PowerShell here-string, so keep it valid JS.
   ============================================================================ */
const $=id=>document.getElementById(id);window.$=$;
function esc(s){return (s==null?'':String(s)).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));}
function connMeta(){return window._connMeta||{};}
function connMetaSet(n,m){window._connMeta=window._connMeta||{};if(m){const cur=window._connMeta[n]||{};window._connMeta[n]={accent:cur.accent||'',env:m.env||'',readonly:!!m.readonly};}else{delete window._connMeta[n];}}
window.readOnly=false;window.curEnv='';
// Pure DOM rendering for the env chip - no side effects on window.readOnly/curEnv, so it's
// safe to call for a merely-selected (not yet connected) connection as a preview, same as the
// password lock icon already does. Only applyEnv() (below) touches the real enforcement state.
function renderEnvChip(env,ro,acc){const el=$('envChip');if(!el)return;if(env||ro){el.style.display='inline-flex';el.textContent=(env||'')+(ro?(env?' - ':'')+'READ-ONLY':'');el.title=el.textContent;if(acc){el.className='chip';el.style.background=acc;el.style.color='#fff';el.style.borderColor='transparent';}else{el.className='chip '+(ro?'bad':'ok');el.style.background='';el.style.color='';el.style.borderColor='';}}else{el.style.display='none';}}
function applyEnv(name){const m=connMeta()[name]||{};window.readOnly=!!m.readonly;window.curEnv=m.env||'';const acc=window.curAccent||accMap()[name]||'';renderEnvChip(window.curEnv,window.readOnly,acc);document.body.classList.toggle('ro',window.readOnly);}
function roBlock(){if(window.readOnly){toast('This connection is marked READ-ONLY (safe mode). Writes are disabled.\nUncheck "Read-only" in the saved connection to allow changes.',true);return true;}return false;}
function accMap(){const m=window._connMeta||{};const o={};for(const k in m){if(m[k]&&m[k].accent)o[k]=m[k].accent;}return o;}
function accSet(n,c){window._connMeta=window._connMeta||{};const cur=window._connMeta[n]||{};window._connMeta[n]={accent:c||'',env:cur.env||'',readonly:!!cur.readonly};}
function hexA(hex,a){hex=(hex||'').replace('#','');if(hex.length===3)hex=hex.split('').map(c=>c+c).join('');const v=parseInt(hex,16);if(isNaN(v)||hex.length!==6)return '';return 'rgba('+((v>>16)&255)+','+((v>>8)&255)+','+(v&255)+','+a+')';}
function applyAccent(color){const bar=$('bar');if(!bar)return;if(!color){bar.style.borderTop='';bar.style.borderBottom='';bar.style.boxShadow='';return;}bar.style.borderTop='2px solid '+color;bar.style.borderBottom='';bar.style.boxShadow='';}
window.curAccent='';
function getConn(){return {host:$('host').value,port:$('port').value,user:$('user').value,password:$('pass').value,ssl:$('ssl').value,sslCa:$('sslca').value};}
// The CA only does anything for "verify" - the other modes check nothing - so it only appears for
// that one, rather than sitting there inviting someone to fill in a box that will be ignored.
function sslCaToggle(){const w=$('sslcaWrap');if(w)w.style.display=(/^verify(-ca)?$/.test($('ssl').value))?'inline-flex':'none';}
function logLineCls(l){
 if(/^OK\s+with\s+\d+\s+error/i.test(l))return 'warn';
 if(/^OK\b/.test(l))return 'ok';
 if(/^FAILED\b/.test(l))return 'err';
 if(/^(SKIP\b|CANCELLED\b|\(excluded\)|\(no tables\))/.test(l))return 'warn';
 return '';
}
function logLinesHtml(lines){return lines.map(l=>{const c=logLineCls(l);return '<div class="ln'+(c?' '+c:'')+'">'+esc(l)+'</div>';}).join('');}
function log(s){const l=$('log');l.textContent+=s+"\n";l.scrollTop=l.scrollHeight;}
// kind: true (legacy) or 'err' -> red, 6s; 'ok' -> green success, 3.5s; omitted/falsy -> neutral
// info, 3.5s. The boolean form is kept working so none of this function's many existing callers
// needed to change - only call sites that want the new green "success" variant pass 'ok'.
function toast(msg,kind){
  const cls=(kind===true||kind==='err')?'err':(kind==='ok'?'ok':'');
  let box=$('toasts');if(!box){box=document.createElement('div');box.id='toasts';document.body.appendChild(box);}
  const t=document.createElement('div');t.className='toast'+(cls?' '+cls:'');t.textContent=msg;box.appendChild(t);
  setTimeout(()=>{t.style.opacity='0';t.style.transition='opacity .3s';setTimeout(()=>t.remove(),300);},cls==='err'?6000:3500);
}
function showDead(){const d=$('deadOverlay');if(d)d.style.display='flex';}
function hideDead(){const d=$('deadOverlay');if(d)d.style.display='none';}
// --- api(): the ONE way the UI talks to the server. Adds token + connection + read-only flag, returns parsed JSON, and shows the 'server down' overlay on failure.
// /api/query answers with its first 1000 rows and a cursor for the rest, which the grid reads as
// you scroll. Every other caller wants the whole result, and got only that first page: in the
// PowerShell edition exporting a table from the tree left out every row past 1000 without a word, and
// lists such as a schema's tables or its column names for autocomplete stopped at 1000 in both.
// Only the grid passes pageSize; for everyone else the remaining rows are read here.
async function api(path,p,signal){
 const r=await apiCall(path,p,signal);
 if(path!=='/api/query'||!p||p.pageSize!=null||!r||!r.ok||!r.hasMore||!r.cursorId)return r;
 // The desktop backend does not repeat cursorId in a fetch answer; the id stays the same.
 const rows=r.rows,cid=r.cursorId;let cur=r;
 while(cur.hasMore){
  cur=await apiCall('/api/fetch-cursor-batch',{cursorId:cid,requestId:p.requestId,pageSize:5000},signal);
  if(!cur||!cur.ok){apiCall('/api/close-cursor',{cursorId:cid});return cur||{ok:false,error:'Reading the rest of the result failed.'};}
  for(const x of cur.rows)rows.push(x);
 }
 r.rows=rows;r.hasMore=false;delete r.cursorId;
 return r;
}
async function apiCall(path,p,signal){p=p||{};p.token=TOKEN;
 // Every call goes to the server you are actually CONNECTED to, never to whatever profile happens
 // to be loaded in the form - so the connection is filled in here rather than trusted from the
 // caller. conn-save is the one exception, because its conn is not a server to talk to at all:
 // it is the profile being saved. Overwriting it made Save, Edit, Clone and Forget-password
 // store the CONNECTED server's host, port, user, SSL settings and CA - and save its password
 // under the other profile's name - whenever you were connected somewhere else.
 if(path==='/api/connect'){p.conn=getConn();p.ro=!!window.readOnly;}
 else if(path==='/api/conn-save'&&p.conn){p.ro=false;}
 else{p.conn=window._activeConn||getConn();p.ro=(window._activeConn?!!window._activeReadOnly:!!window.readOnly);}
 busyStart();try{const r=await fetch(path,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(p),signal});return await r.json();}catch(e){if(e&&e.name==='AbortError')return {ok:false,aborted:true};showDead();return {ok:false,error:'Server unavailable'};}finally{busyStop();}}
// Floating (draggable, non-blocking) modals remember where they were left, keyed by id, and
// get bumped to the top of the floating stack whenever they're (re)opened or clicked - a plain
// z-index counter that only ever increases, so "last touched" is always visually on top without
// needing to track or reorder every floating modal's stacking position explicitly.
window._floatingPos = {};
let _floatZCounter = 9001;
function floatBringToFront(id){ const el=$(id); if(el) el.style.zIndex=String(++_floatZCounter); }
function floatApplyPos(id){
 const box=$(id).querySelector('.box');
 const pos=window._floatingPos[id];
 if(!box||!pos)return;
 box.style.top=pos.top+'px';
 box.style.left=pos.left+'px';
}
// Floating windows used to open at a fixed left offset baked into their markup (left:100px,
// left:180px, ...), which put them well off to the left on a wide screen. Centre horizontally on
// open instead, measured from the box's own width so boxes of different widths all land centred.
// The inline top is left alone. Only called when the window has no remembered position, so once
// it has been dragged the dragged position keeps winning.
function floatCenterX(id){
 const box=$(id).querySelector('.box');
 if(!box)return;
 const w=box.getBoundingClientRect().width;
 box.style.left=Math.max(0,Math.round((window.innerWidth-w)/2))+'px';
}
function floatCenterY(id){
 const box=$(id).querySelector('.box');
 if(!box)return;
 const h=box.getBoundingClientRect().height;
 // Biased a bit above dead-center (not a plain 50/50 split) - looks more natural than true
 // centering, and keeps tall modals (e.g. Compare Databases) from crowding the bottom edge.
 // Compare Databases grows tall once results load, so it gets a stronger upward bias than
 // the rest so it doesn't visually creep back toward dead-center as it fills up.
 const biasFrac=id==='mCompare'?0.12:0.06;
 box.style.top=Math.max(0,Math.round((window.innerHeight-h)/2-window.innerHeight*biasFrac))+'px';
}
let _floatDrag=null;
function floatDragStart(e,id){
 e.preventDefault();
 const box=$(id).querySelector('.box');
 if(!box)return;
 const rect=box.getBoundingClientRect();
 _floatDrag={id,startMouseX:e.clientX,startMouseY:e.clientY,startTop:rect.top,startLeft:rect.left};
 floatBringToFront(id);
 document.addEventListener('mousemove',floatDragMove);
 document.addEventListener('mouseup',floatDragEnd);
}
function floatDragMove(e){
 if(!_floatDrag)return;
 const dx=e.clientX-_floatDrag.startMouseX,dy=e.clientY-_floatDrag.startMouseY;
 // Only the lower bound was clamped before (top/left >= 0) - a fast drag toward the bottom-right
 // could push the box far enough that its title bar (the only draggable handle) ends up entirely
 // off-screen, with no way to grab it back. Clamping the upper bound too keeps a reasonable
 // chunk of the title bar always reachable, regardless of how far the drag goes.
 const maxTop=Math.max(0,window.innerHeight-40);
 const maxLeft=Math.max(0,window.innerWidth-120);
 window._floatingPos[_floatDrag.id]={top:Math.max(0,Math.min(maxTop,_floatDrag.startTop+dy)),left:Math.max(0,Math.min(maxLeft,_floatDrag.startLeft+dx))};
 floatApplyPos(_floatDrag.id);
}
function floatDragEnd(){
 _floatDrag=null;
 document.removeEventListener('mousemove',floatDragMove);
 document.removeEventListener('mouseup',floatDragEnd);
}
// Minimized floating modals stay technically "open" (still has the .show class) but their box
// is hidden and a small chip is added to the tray instead - restoring just reverses that, rather
// than tearing down and rebuilding the modal's state each time.
window._floatingMinimized = {};
function floatTrayLabel(id){
 // Reads the title text at render time rather than storing a label up front, so a DYNAMIC title
 // (the ER diagram's "ER Diagram - schemaname") shows correctly on the chip even if it changed
 // after the modal was minimized, not a stale snapshot from whenever minimize was first clicked.
 const titleEl=$(id).querySelector('h3');
 return titleEl?titleEl.textContent:id;
}
function floatRenderTray(){
 const tray=$('minimizedTray');
 if(!tray)return;
 const ids=Object.keys(window._floatingMinimized).filter(id=>window._floatingMinimized[id]);
 if(!ids.length){tray.style.display='none';tray.innerHTML='';return;}
 tray.style.display='flex';
 // Restore-label and close-x are independent SIBLING spans, not nested inside one another or
 // inside a shared clickable wrapper - a click on either fires only its own handler and bubbles
 // up through elements with no onclick of their own, so there's no risk of clicking the x also
 // triggering restore (or vice versa), and no stopPropagation is needed for that reason.
 // A minimized modal's title can be arbitrarily long (e.g. the ER Diagram title includes the
 // schema name) - the label gets its own width cap + ellipsis so one long chip can't push earlier
 // ones off the left edge of the tray (the tray itself wraps to a new row once it runs out of
 // room - see its max-width/flex-wrap above).
 tray.innerHTML=ids.map(id=>{const lbl=floatTrayLabel(id);return '<span class="chip" style="background:var(--panel);border-color:var(--bd2);color:var(--fg);gap:8px;cursor:default">'
  +'<span onclick="floatRestore(\''+id+'\')" style="cursor:pointer;display:inline-block;max-width:160px;overflow:hidden;white-space:nowrap;text-overflow:ellipsis;vertical-align:middle" title="'+esc(lbl)+' \u2014 Restore">'+esc(lbl)+'</span>'
  +'<span onclick="modalClose(\''+id+'\')" style="cursor:pointer;font-weight:700;padding:0 1px" title="Close">&times;</span>'
  +'</span>';}
 ).join('');
}
function floatMinimize(id){
 const box=$(id).querySelector('.box');
 if(!box)return;
 box.style.display='none';
 window._floatingMinimized[id]=true;
 floatRenderTray();
}
function floatRestore(id){
 const box=$(id).querySelector('.box');
 if(!box)return;
 box.style.display='';
 delete window._floatingMinimized[id];
 floatBringToFront(id);
 floatRenderTray();
}
// Captured once, right here at script load - before any user interaction has had a chance to
// drag-resize anything - so hide() above always has the modal's true pristine size to snap back
// to. Also captures any persistent inner textarea (the cell-edit box, generated-SQL boxes, etc. -
// elements that live in the page permanently rather than being rebuilt fresh on every open, unlike
// e.g. Query History's per-row code blocks) so a manually resized one of those resets too.
window._floatingDefaultSize={};
window._floatingInnerDefaults={};
document.querySelectorAll('.modal.floating').forEach(m=>{
 const box=m.querySelector('.box');
 if(box)window._floatingDefaultSize[m.id]={width:box.style.width,height:box.style.height,maxWidth:box.style.maxWidth,maxHeight:box.style.maxHeight};
 window._floatingInnerDefaults[m.id]=[...m.querySelectorAll('textarea[id]')].map(ta=>({id:ta.id,width:ta.style.width,height:ta.style.height}));
});
// Snapshotting the exact prior inline top/left/width/height (rather than re-deriving them) means
// restore always lands back exactly where the window was, including a size/position from a
// manual drag-resize - not just back to the modal's hardcoded default.
window._floatingMaxState={};
// Row comparison's two grids keep a compact default max-height (like before dynamic sizing was
// added) so the modal's normal size stays small - but that same cap would stop them from actually
// growing into the extra room once the modal is maximized, so their max-height is cleared here too
// alongside the box's, and restored exactly on toggle-back.
const FLOAT_MAX_EXTRA={mCompareRows:['cmprGrid','cmprDiffGrid']};
function floatToggleMaximize(id){
 const box=$(id).querySelector('.box');
 if(!box)return;
 const btn=$('maxBtn_'+id);
 const extraIds=FLOAT_MAX_EXTRA[id]||[];
 if(window._floatingMaxState[id]){
  const s=window._floatingMaxState[id];
  box.style.top=s.top;box.style.left=s.left;box.style.width=s.width;box.style.height=s.height;box.style.maxWidth=s.maxWidth;box.style.maxHeight=s.maxHeight;
  extraIds.forEach(eid=>{const el=$(eid);if(el&&s.extra&&(eid in s.extra))el.style.maxHeight=s.extra[eid];});
  delete window._floatingMaxState[id];
  if(btn)btn.title='Maximize';
 } else {
  // Every modal has a max-width (95vw-ish, from the resize-ceiling fix) and the shared .box
  // rule's max-height:92% - both still apply to an inline width/height set here, silently
  // clamping the "full screen" size to something visibly short of the actual viewport (a bigger
  // gap on the right/bottom than the 10px on top/left) unless overridden too.
  const extra={};
  extraIds.forEach(eid=>{const el=$(eid);if(el)extra[eid]=el.style.maxHeight;});
  window._floatingMaxState[id]={top:box.style.top,left:box.style.left,width:box.style.width,height:box.style.height,maxWidth:box.style.maxWidth,maxHeight:box.style.maxHeight,extra};
  box.style.top='10px';box.style.left='10px';box.style.width='calc(100vw - 20px)';box.style.height='calc(100vh - 20px)';box.style.maxWidth='none';box.style.maxHeight='none';
  extraIds.forEach(eid=>{const el=$(eid);if(el)el.style.maxHeight='none';});
  if(btn)btn.title='Restore';
 }
 floatBringToFront(id);
}
function show(id){
 const el=$(id);
 document.body.appendChild(el);
 el.classList.add('show');
 if(el.classList.contains('floating')){
  // Re-opening a modal that's currently minimized should restore it, not leave it invisible
  // with the outer .modal showing 'open' while its box stays hidden - a confusing, broken-
  // looking state that would otherwise occur since neither classList.add('show') above nor the
  // position-apply below touches box.style.display at all.
  if(window._floatingMinimized[id]) floatRestore(id);
  else { floatBringToFront(id); if(!window._floatingPos[id]){floatCenterX(id);floatCenterY(id);} floatApplyPos(id); }
 }
}
function hide(id){
 $(id).classList.remove('show');
 const box=$(id).querySelector('.box');
 if(window._floatingMinimized[id]){
  delete window._floatingMinimized[id];
  if(box)box.style.display='';
  floatRenderTray();
 }
 // Always reset back to default size on close - reopening a window later should start fresh at
 // its normal size rather than carrying over whatever a manual drag-resize (or an un-restored
 // Maximize) last left it at. Position is left alone; only size is reset.
 delete window._floatingMaxState[id];
 const d=window._floatingDefaultSize&&window._floatingDefaultSize[id];
 if(box&&d){box.style.width=d.width;box.style.height=d.height;box.style.maxWidth=d.maxWidth;box.style.maxHeight=d.maxHeight;const btn=$('maxBtn_'+id);if(btn)btn.title='Maximize';}
 (window._floatingInnerDefaults&&window._floatingInnerDefaults[id]||[]).forEach(dd=>{const ta=$(dd.id);if(ta){ta.style.width=dd.width;ta.style.height=dd.height;}});
}
const RESERVED=new Set(['accessible','add','all','alter','analyze','and','as','asc','before','between','bigint','binary','blob','both','by','call','cascade','case','change','char','character','check','collate','column','condition','constraint','continue','convert','create','cross','current_date','current_time','current_timestamp','cursor','database','databases','default','delete','desc','describe','distinct','div','double','drop','dual','each','else','exists','explain','false','fetch','float','for','force','foreign','from','fulltext','function','group','having','if','ignore','in','index','inner','insert','int','integer','interval','into','is','join','key','keys','left','like','limit','lock','long','longblob','longtext','match','mediumblob','mediumint','mediumtext','natural','not','null','numeric','offset','on','optimize','option','or','order','outer','primary','procedure','references','rename','repeat','replace','restrict','return','revoke','right','rlike','schema','schemas','select','set','show','smallint','spatial','sql','table','then','tinyblob','tinyint','tinytext','to','trigger','true','union','unique','unlock','unsigned','update','usage','use','using','values','varbinary','varchar','varying','when','where','while','with','write','zerofill']);
function qid(n){n=String(n);if(n===''||!/^[A-Za-z_$][A-Za-z0-9_$]*$/.test(n)||RESERVED.has(n.toLowerCase()))return '`'+n.replace(/`/g,'``')+'`';return n;}
function lit(v){if(v===null)return 'NULL';const s=String(v);if(/^0x[0-9A-Fa-f]+$/.test(s))return s;return strLit(s);}
// Which of a grid's columns hold binary values - the ones shown as 0x... The Tauri build reads that
// from the result set itself; the PowerShell one asks information_schema, which needs a table.
// null when neither can tell, and the caller then falls back to lit(), which goes by the value.
const BIN_COL_TYPE=/^(binary|varbinary|tinyblob|blob|mediumblob|longblob|bit|geometry|point|linestring|polygon|multipoint|multilinestring|multipolygon|geometrycollection|geomcollection)\b/i;
async function tableBinCols(db,table,cols){
 try{
  const r=await api('/api/query',{sql:"SELECT COLUMN_NAME, DATA_TYPE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA="+strLit(db)+" AND TABLE_NAME="+strLit(table)});
  if(!r.ok||!r.rows||!r.rows.length)return null;
  const m={};r.rows.forEach(x=>{m[String(x[0]).toLowerCase()]=BIN_COL_TYPE.test(String(x[1]));});
  const out=[];for(const c of cols){const k=String(c).toLowerCase();if(!(k in m))return null;out.push(m[k]);}
  return out;
 }catch(e){return null;}
}
async function gridBinCols(id){
 const t=T(id);if(!t||!t.cols)return null;
 if(t.binCols&&t.binCols.length===t.cols.length)return t.binCols.map(Boolean);
 if(!t.table)return null;
 return tableBinCols(t.db,t.table,t.cols);
}
// A table's columns in order, each with whether it is generated; null when they cannot be read.
// Copies name their columns from this rather than using SELECT *: SELECT * leaves out INVISIBLE
// columns (MySQL 8.0.23+, MariaDB 10.3+), so a copy made from it stored NULL in them, and a
// generated column cannot be given a value, so a copy that included one was refused.
async function tableColumnsInfo(db,table){
 try{
  const r=await api('/api/query',{sql:"SELECT COLUMN_NAME, EXTRA FROM information_schema.COLUMNS WHERE TABLE_SCHEMA="+strLit(db)+" AND TABLE_NAME="+strLit(table)+" ORDER BY ORDINAL_POSITION"});
  if(!r.ok||!r.rows.length)return null;
  return r.rows.map(x=>({name:String(x[0]),generated:GENERATED_EXTRA.test(String(x[1]||''))}));
 }catch(e){return null;}
}
// EXTRA for a generated column; MySQL's DEFAULT_GENERATED only marks an expression default.
const GENERATED_EXTRA=/(VIRTUAL|STORED|PERSISTENT) GENERATED/i;
// An INSERT that skips a row whose key already exists, as INSERT IGNORE did - without IGNORE's
// other effect: it turns errors into warnings, so a value too long for its column was cut short
// and an impossible date stored as 0000-00-00, silently, when the file was run.
function insertSkipExisting(tbl,cols,tuple){const f=qid(cols[0]);return 'INSERT INTO '+tbl+' ('+cols.map(qid).join(',')+') VALUES '+tuple+' ON DUPLICATE KEY UPDATE '+f+'='+f+';';}
// How Apply finds a grid row: by its key, as the grid holds it. Two key types do not survive that:
//  - FLOAT is shown rounded (1.1 is stored as 1.10000002384), so k = '1.1' matched nothing, and the
//    edit or delete did nothing while the app reported it applied. Matched by its text instead.
//  - TIMESTAMP is shown in the session time zone, where the hour clocks go back in autumn happens
//    twice: two keys an hour apart both showed as 02:30, and editing one changed the other. Matched
//    by its text within a few hours of it, so both show up and the guard below refuses.
// null when a key column is not in the result.
function keyWhere(t,ri,bc,types){
 const parts=[];
 for(const p of t.pk){
  const ci=t.cols.indexOf(p);if(ci<0)return null;
  const v=t.rows[ri][ci],q=qid(p),ty=types&&types[String(p).toLowerCase()];
  if(v===null||v===undefined){parts.push(q+' IS NULL');continue;}
  const l=strLit(String(v));
  if(ty==='float'){parts.push('CAST('+q+' AS CHAR)='+l);continue;}
  if(ty==='timestamp'){parts.push('('+q+' BETWEEN '+l+' - INTERVAL 3 HOUR AND '+l+' + INTERVAL 3 HOUR AND CAST('+q+' AS CHAR)='+l+')');continue;}
  parts.push(q+'='+litAs(v,bc?bc[ci]:null));
 }
 return parts.join(' AND ');
}
// Stops the batch - which runs as one transaction - unless where matches exactly one row: none when
// the row was changed or deleted since it was read, or its key cannot be matched; more when the key
// is ambiguous. Both servers refuse to put two rows into a variable (error 1172).
function oneRowGuard(tbl,where){return 'SELECT 1 FROM (SELECT 1 AS x UNION ALL SELECT 2) nobs_guard WHERE (SELECT COUNT(*) FROM '+tbl+' WHERE '+where+') <> 1 INTO @nobs_one_row;';}
const ONE_ROW_REFUSED='Nothing was saved. A row you changed or deleted no longer matches exactly one row in the table: it may have been changed or deleted since it was loaded, or its key cannot be matched exactly (a FLOAT key shown rounded, or a TIMESTAMP key in the hour the clocks go back). Reload the table and try again.';
async function tableColTypes(db,table){
 try{
  const r=await api('/api/query',{sql:"SELECT COLUMN_NAME, DATA_TYPE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA="+strLit(db)+" AND TABLE_NAME="+strLit(table)});
  if(!r.ok)return null;
  const m={};r.rows.forEach(x=>{m[String(x[0]).toLowerCase()]=String(x[1]).toLowerCase();});
  return m;
 }catch(e){return null;}
}
// lit() decides from the value's shape, which is wrong both ways for row data: a text cell holding
// 0x41 was written as the byte A, and an empty binary value - shown as the bare 0x - as the two
// characters 0x. With the column's type known (bin true/false) the type decides instead; with it
// unknown (null) this is lit().
function litAs(v,bin){
 if(bin==null)return lit(v);
 if(v===null||v===undefined)return 'NULL';
 const s=String(v);
 if(bin){if(s==='0x')return "X''";if(/^0x[0-9A-Fa-f]+$/.test(s))return s;}
 return strLit(s);
}
// This edition reads results from mysql.exe's XML output, which writes a NUL byte inside a text
// value as a space. An export built from such a grid would carry the space, so exports of a table
// check for it first and send the user to the Export tool (mysqldump), which copies bytes exactly.
async function tableTextCols(db,table){
 const r=await api('/api/query',{sql:"SELECT COLUMN_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA="+strLit(db)+" AND TABLE_NAME="+strLit(table)+" AND DATA_TYPE IN ('char','varchar','tinytext','text','mediumtext','longtext') ORDER BY ORDINAL_POSITION"});
 return r.ok?r.rows.map(x=>x[0]):null;
}
const nulIn=c=>"LOCATE(0x00,CAST(CONVERT("+qid(c)+" USING utf8mb4) AS BINARY))>0";
async function tableNulTextCount(db,table){
 try{
  const cols=await tableTextCols(db,table);
  if(!cols)return null;
  if(!cols.length)return 0;
  const cond=cols.map(nulIn).join(' OR ');
  const c=await api('/api/query',{sql:'SELECT COUNT(*) FROM '+qid(db)+'.'+qid(table)+' WHERE '+cond});
  return c.ok&&c.rows.length?+c.rows[0][0]:null;
 }catch(e){return null;}
}
// Where the top-level FROM of a SELECT starts, skipping strings, quoted names, comments and
// anything in parentheses; -1 if there is none.
function topLevelFromAt(sql){
 const s=String(sql);let depth=0;
 for(let i=0;i<s.length;i++){
  const c=s[i];
  if(c==="'"||c==='"'||c==='`'){const q=c;i++;while(i<s.length){if(s[i]==='\\'&&q!=='`'){i+=2;continue;}if(s[i]===q){if(s[i+1]===q){i+=2;continue;}break;}i++;}continue;}
  if(c==='#'||(c==='-'&&s[i+1]==='-'&&(i+2>=s.length||/\s/.test(s[i+2])))){const nl=s.indexOf('\n',i);if(nl<0)return -1;i=nl;continue;}
  if(c==='/'&&s[i+1]==='*'){const e=s.indexOf('*/',i+2);if(e<0)return -1;i=e+1;continue;}
  if(c==='(')depth++;
  else if(c===')')depth--;
  else if(depth===0&&(c==='f'||c==='F')&&/^from\b/i.test(s.slice(i,i+5))&&(i===0||!/[\w$]/.test(s[i-1])))return i;
 }
 return -1;
}
// This edition reads results from mysql.exe's XML output, which writes a NUL inside a text value as
// a space. A table grid is what edits are made from - a key shown that way made Apply's WHERE match
// a different row, one whose key really has a space there - so its query also asks for every text
// column of the table as hex wherever the value holds a NUL, and the server puts the exact value
// back (Get-ExactTextMap). q is the SQL to send, ending with lastStmt. Returns the SQL to send and
// the text columns asked for, or null when that cannot be done - the grid is then not exact.
async function exactTextQuery(q,lastStmt,bind){
 const last=String(lastStmt).trim().replace(/;+\s*$/,'');
 if(!q.endsWith(last))return null;
 const at=topLevelFromAt(last);
 if(at<0)return null;
 const cols=await tableTextCols(bind.db,bind.table);
 if(!cols)return null;
 if(!cols.length)return {sql:q,cols:[]};
 const conv=c=>'CONVERT('+qid(c)+' USING utf8mb4)';
 const extra=cols.map((c,i)=>', IF(LOCATE(0x00, CAST('+conv(c)+' AS BINARY)) > 0, HEX('+conv(c)+'), NULL) AS '+qid('__nobs_exact_'+i)).join('');
 return {sql:q.slice(0,q.length-last.length)+last.slice(0,at)+extra+' '+last.slice(at),cols};
}
async function refuseNulTextExport(db,table){
 const n=await tableNulTextCount(db,table);
 if(!n)return false;
 toast(fmtCount(n)+' row(s) of '+db+'.'+table+' hold a NUL byte inside a text value, which this edition reads as a space, so this export would not be exact. Use the Export tool in the top toolbar instead - it copies them byte for byte.',true);
 return true;
}
// Always a quoted string literal - unlike lit(), never reinterprets a hex-looking value as a raw
// unquoted hex literal. lit()'s passthrough is meant for grid cell values; a password or other
// plain-text field that happens to look like hex should stay exactly the text the user typed.
// CR and NUL are written as escapes. mysql.exe reading a script (stdin, or source) turns every CR LF
// into LF, so a raw CR before a line feed was silently dropped; a raw NUL makes it refuse the
// statement unless --binary-mode is on.
function strLit(v){return "'"+String(v).replace(/\\/g,'\\\\').replace(/'/g,"''").replace(/\r/g,'\\r').replace(/\0/g,'\\0')+"'";}

async function searchAllSchemas(){
  const term=($('objFilter').value||'').trim();
  if(!term){toast('Type something in the filter box first, then click "All DBs".',true);return;}
  const r=await api('/api/search-all-schemas',{term});
  if(!r.ok){toast(r.error,true);return;}
  const box=$('objects');box.innerHTML='';
  if(!r.items.length){box.innerHTML='<div class="muted" style="padding:8px">No matches for "'+esc(term)+'" in any schema.</div>';return;}
  const h=document.createElement('div');h.className='ohdr';h.textContent='Matches across all schemas ('+r.items.length+')';box.appendChild(h);
  r.items.forEach(it=>{
    const d=document.createElement('div');d.className='item';
    d.innerHTML='<span class="onm">'+esc(it.name)+'</span><span class="osz">'+esc(it.schema)+' \u00B7 '+esc(it.type)+'</span>';
    d.onclick=()=>{
      curSchema=it.schema;
      $('objdb').textContent=it.schema;$('objdb').title=it.schema;

      // Highlight the schema in the schemas list
      const schemasBox = $('schemas');
      if (schemasBox) {
        [...schemasBox.children].forEach(c => {
          c.classList.remove('sel');
          if (c.textContent.includes(it.schema)) {
            c.classList.add('sel');
          }
        });
      }

      loadObjects(it.schema).then(()=>objOpen(it.schema,it.type,it.name));
    };
    box.appendChild(d);
  });
}

// theme
function toggleTheme(){document.body.classList.toggle('dark');localStorage.setItem('theme',document.body.classList.contains('dark')?'dark':'light');}
if(localStorage.getItem('theme')!=='light')document.body.classList.add('dark');

// context menu
function _clearKeys(includeAll){const keys=[];for(let i=0;i<localStorage.length;i++){const k=localStorage.key(i);if(!k)continue;if(k.indexOf('overviewCache')===0||k.indexOf('tableSizes')===0){keys.push(k);}else if(includeAll&&['session','history','connmeta','accents','theme'].indexOf(k)>=0){keys.push(k);}}keys.forEach(k=>localStorage.removeItem(k));return keys.length;}
async function clearAllData(){if(!(await ask('Clear ALL app data?\n\nThis permanently deletes:\n\u2022 saved connections (host / user / password)\n\u2022 the query library\n\u2022 caches, accent colors, environment labels, history and session tabs.\n\nThis cannot be undone.')))return;const n=_clearKeys(true);try{await api('/api/conn-clear');}catch(e){}try{await api('/api/lib-clear');}catch(e){}log('Cleared '+n+' local entr'+(n===1?'y':'ies')+' + saved connections + library. Reloading...');setTimeout(()=>location.reload(),500);}
async function openSettings(){$('cfgLog').textContent='';try{const r=await api('/api/get-config');const c=(r&&r.config)||{};$('cfgMysql').value=c.mysql_bin||'';$('cfgDump').value=c.mysqldump_bin||'';$('cfgMysqlMy').value=c.mysql_bin_mysql||'';$('cfgDumpMy').value=c.mysqldump_bin_mysql||'';window._mariadbDownloadUrlDefault=(r&&r.mariadbDownloadUrlDefault)||'';$('cfgDownloadUrl').value=c.mariadb_download_url_template||window._mariadbDownloadUrlDefault;}catch(e){}if($('cfgUpdateCheck'))$('cfgUpdateCheck').checked=updateCheckOn();show('mSettings');refreshToolsStatus();}
// Export and Import shell out to mysql.exe / mysqldump.exe. When the backend reports one
// missing, the bare error leaves the user stuck - it names PATH and an environment variable but
// not the dialog that actually fixes it - so pair it with a button that opens Settings, where the
// path can be set or the tools downloaded. The message itself goes in via textContent, never
// innerHTML: it can carry raw output from the server or the shelled-out tool.
function showToolError(logId,ownerModalId,msg){
 const el=$(logId); if(!el)return;
 el.textContent=msg;
 // Two wordings reach here: the Tauri build's "Could not find '<tool>'" and the PowerShell
 // build's "<tool>.exe not found". Match both so the two front-ends can stay identical.
 if(!/Could not find '|\.exe not found/.test(msg))return;
 const row=document.createElement('div'); row.style.marginTop='8px';
 const btn=document.createElement('button'); btn.className='sm'; btn.textContent='Open Settings...';
 btn.title='Set the path to the client tools, or download them';
 // Settings is a plain centred modal at z-index 9000 while an open floating window has been
 // pushed above that by floatBringToFront, so Settings would open BEHIND the window the user
 // clicked from. Closing that window first avoids the stacking problem entirely, and its form
 // values stay in the DOM for when it is reopened.
 btn.onclick=()=>{if(ownerModalId)hide(ownerModalId);openSettings();};
 row.appendChild(btn); el.appendChild(row);
}
// No version lookup here, unlike the Tauri build: the version is written into this page when the
// server starts (a placeholder in the title). This backend has no app-info endpoint, and
// api() treats any failed call as the server being gone - it calls showDead(), which would throw
// a false "server down" overlay over the app just for opening the About box.
function openAbout(){ show('mAbout'); }
// Each tool set in its own card: the path, a check mark, and what it is (e.g. "MariaDB 12.3.3 -
// downloaded"). Above them, which set the connected server uses.
function renderToolsStatus(r){
 const row=(name,path,src,ver,none)=>{const ok=path&&path!=='(not found)';
  return '<div style="margin:2px 0"><div class="toolpath"><b>'+name+':</b>'+(ok?'<span class="p" title="'+esc(path)+'">'+esc(path)+'</span><span style="color:#3fb950">&#10003;</span></div><div class="muted" style="font-size:11px;margin-left:2px">'+esc((ver?ver+' - ':'')+(src||''))+'</div>':none+'</div>')+'</div>';};
 const missing='<span style="color:#e5534b">&#10007; not found</span>';
 const ma=$('cfgStatusMaria'),my=$('cfgStatusMysql');
 if(ma)ma.innerHTML=row('mysql',r.mysql,r.mysql_source,r.mysql_version,missing)+row('mysqldump',r.mysqldump,r.mysqldump_source,r.mysqldump_version,missing);
 if(my)my.innerHTML=row('mysql',r.mysql_for_mysql,r.mysql_for_mysql_source,r.mysql_for_mysql_version,'<span class="muted">none - the tools for MariaDB servers are used</span>')
  +row('mysqldump',r.mysqldump_for_mysql,r.mysqldump_for_mysql_source,r.mysqldump_for_mysql_version,'<span class="muted">none - the tools for MariaDB servers are used</span>');
 showToolsInUse(r);
}
async function showToolsInUse(st){
 const el=$('cfgStatus'),ma=$('cfgCardMaria'),my=$('cfgCardMysql');if(!el||!ma||!my)return;
 // The marks change only with the answer, and only the latest check writes one: Settings can check
 // twice at once, and the second check cleared the marks under the first one's line.
 const mark=c=>{ma.classList.toggle('inuse',c===ma);my.classList.toggle('inuse',c===my);};
 const seq=showToolsInUse.seq=(showToolsInUse.seq||0)+1;
 if(!window._activeConn){mark(null);el.textContent='Not connected. Which set is used is decided per server when you connect.';return;}
 let r=null;try{r=await api('/api/tools-for-conn');}catch(e){}
 if(seq!==showToolsInUse.seq)return;
 if(!r||!r.ok||r.serverIsMariadb==null){el.textContent='Could not tell whether the connected server is MariaDB or MySQL; the tools for MariaDB servers are used.';mark(ma);return;}
 const ownMysql=!r.serverIsMariadb&&st&&st.mysqldump_for_mysql&&r.mysqldump===st.mysqldump_for_mysql;
 el.textContent='The connected server is '+(r.serverIsMariadb?'MariaDB':'MySQL')+', so it uses the tools for '+(ownMysql?'MySQL servers.':'MariaDB servers'+(r.serverIsMariadb?'.':' - there are no MySQL tools.'));
 mark(ownMysql?my:ma);
}
async function refreshToolsStatus(){const el=$('cfgStatus');if(!el)return;el.innerHTML='Checking...';try{const r=await api('/api/tools-status');if(!r||!r.ok){el.textContent='';return;}renderToolsStatus(r);
 if(r.mysql&&r.mysql!=='(not found)'&&!$('cfgMysql').value)$('cfgMysql').value=r.mysql;
 if(r.mysqldump&&r.mysqldump!=='(not found)'&&!$('cfgDump').value)$('cfgDump').value=r.mysqldump;
 const pe=$('cfgPaths');if(pe)pe.innerHTML='Downloads: '+esc(r.download_dir)+'<br>Config: '+esc(r.config_file);}catch(e){el.textContent='';}}
function resetDownloadUrl(){$('cfgDownloadUrl').value=window._mariadbDownloadUrlDefault||'';}
async function saveSettings(){try{const r=await api('/api/save-config',{config:{mysql_bin:$('cfgMysql').value.trim(),mysqldump_bin:$('cfgDump').value.trim(),mysql_bin_mysql:$('cfgMysqlMy').value.trim(),mysqldump_bin_mysql:$('cfgDumpMy').value.trim(),mariadb_download_url_template:$('cfgDownloadUrl').value.trim()}});if(r&&r.ok){log('Saved client-tool paths.');refreshToolsStatus();hide('mSettings');}else toast('Save failed: '+(r?r.error:''),true);}catch(e){toast('Save failed: '+e,true);}}
async function downloadTools(){try{await api('/api/save-config',{config:{mariadb_download_url_template:$('cfgDownloadUrl').value.trim()}});}catch(e){}$('cfgLog').textContent='Downloading MariaDB client tools (~90 MB). This can take a minute...';try{const r=await api('/api/download-tools');if(r&&r.ok){$('cfgLog').textContent=r.message;if(r.config){$('cfgMysql').value=r.config.mysql_bin||$('cfgMysql').value;$('cfgDump').value=r.config.mysqldump_bin||$('cfgDump').value;}log(r.message);refreshToolsStatus();}else{$('cfgLog').textContent='Failed: '+(r?r.error:'unknown');}}catch(e){$('cfgLog').textContent='Failed: '+e;}}
// MySQL's archive is the whole server (~270 MB), and only two binaries are kept from it. The paths
// it fills in are the "MySQL servers" ones, used only for MySQL servers.
async function downloadMysqlTools(){
 $('cfgLog').textContent='Downloading MySQL client tools (~270 MB). This can take a few minutes...';
 try{const r=await api('/api/download-mysql-tools');
  if(r&&r.ok){$('cfgLog').textContent=r.message;if(r.config){$('cfgMysqlMy').value=r.config.mysql_bin_mysql||$('cfgMysqlMy').value;$('cfgDumpMy').value=r.config.mysqldump_bin_mysql||$('cfgDumpMy').value;}log(r.message);refreshToolsStatus();}
  else{$('cfgLog').textContent='Failed: '+(r?r.error:'unknown');}
 }catch(e){$('cfgLog').textContent='Failed: '+e;}}
let _inpResolve=null;
function inputBox(opts){return new Promise(res=>{_inpResolve=res;$('inpTitle').textContent=opts.title||'Input';const box=$('inpFields');box.innerHTML='';
 (opts.fields||[]).forEach(f=>{const w=document.createElement('div');w.style.margin='6px 0';if(f.type==='checkbox'){w.style.display='flex';w.style.alignItems='center';w.style.gap='8px';const cbx=document.createElement('input');cbx.id='inp_'+f.key;cbx.type='checkbox';cbx.checked=!!f.value;const clb=document.createElement('label');clb.textContent=f.label||f.key;clb.style.fontSize='13px';clb.htmlFor=cbx.id;clb.style.cursor='pointer';cbx.onkeydown=e=>{if(e.key==='Escape'){e.preventDefault();inpCancel();}};w.appendChild(cbx);w.appendChild(clb);box.appendChild(w);return;}const lb=document.createElement('label');lb.textContent=f.label||f.key;lb.style.display='block';lb.style.fontSize='12px';lb.style.marginBottom='2px';lb.style.color='var(--muted)';
  if(f.type==='select'){const sel=document.createElement('select');sel.id='inp_'+f.key;sel.style.width='100%';(f.options||[]).forEach(o=>{const opt=document.createElement('option');if(o&&typeof o==='object'){opt.value=o.value;opt.textContent=o.label;}else{opt.value=o;opt.textContent=o;}sel.appendChild(opt);});if(f.value!=null)sel.value=f.value;sel.onkeydown=e=>{if(e.key==='Escape'){e.preventDefault();inpCancel();}};w.appendChild(lb);w.appendChild(sel);box.appendChild(w);return;}
  // Masked by default with a small reveal toggle, rather than plain text - screen shares and
  // bug-report recordings are exactly the situations where a visible saved password becomes a
  // real problem, even in a local, developer-facing tool. inpOk()'s extraction needs no changes
  // for this: it already just reads .value off any non-checkbox input regardless of its type.
  if(f.type==='password'){const wrap=document.createElement('div');wrap.style.position='relative';const inp=document.createElement('input');inp.id='inp_'+f.key;inp.type='password';inp.style.width='100%';inp.style.paddingRight='28px';inp.style.boxSizing='border-box';
   // Same anti-autofill hardening as the toolbar's own #pass field (see below): this app launches
   // as a REAL Chrome/Edge --app window backed by a persistent --user-data-dir profile, not a
   // one-off embedded webview - so Chrome's own password manager is live here, remembers whatever
   // it's ever been allowed to save for this "site", and will happily autofill (or overwrite) an
   // unguarded password field with that OLD saved value the instant it appears, silently replacing
   // whatever this dialog's caller just set as f.value. Without this, editing/saving a connection
   // could show (and then persist) Chrome's own stale remembered password instead of the real one.
   inp.autocomplete='new-password';inp.setAttribute('autocorrect','off');inp.setAttribute('autocapitalize','off');inp.spellcheck=false;inp.name='mwt_secret';inp.setAttribute('data-lpignore','true');inp.setAttribute('data-form-type','other');
   if(f.value!=null)inp.value=f.value;inp.onkeydown=e=>{if(e.key==='Enter'){e.preventDefault();inpOk();}else if(e.key==='Escape'){e.preventDefault();inpCancel();}};const eye=document.createElement('span');eye.textContent='\u{1F441}';eye.title='Show/hide password';eye.style.cssText='position:absolute;right:6px;top:50%;transform:translateY(-50%);cursor:pointer;font-size:13px;user-select:none;opacity:.7';eye.onclick=()=>{inp.type=(inp.type==='password')?'text':'password';};wrap.appendChild(inp);wrap.appendChild(eye);w.appendChild(lb);w.appendChild(wrap);box.appendChild(w);return;}
  // A path field: a plain text input plus the app's own file browser. Not <input type="file">,
  // which hands back a File object and deliberately never a real path - and a path is exactly
  // what has to be written into the options file. The button is a <button>, so inpOk()'s
  // "read every input/textarea/select" sweep picks up the field and ignores this.
  if(f.type==='file'){const wrap=document.createElement('div');wrap.style.cssText='display:flex;gap:6px';
   const inp=document.createElement('input');inp.id='inp_'+f.key;inp.type='text';inp.style.flex='1';inp.style.minWidth='0';
   if(f.value!=null)inp.value=f.value;if(f.placeholder)inp.placeholder=f.placeholder;
   inp.onkeydown=e=>{if(e.key==='Enter'){e.preventDefault();inpOk();}else if(e.key==='Escape'){e.preventDefault();inpCancel();}};
   const b=document.createElement('button');b.className='sm';b.textContent='Browse...';b.style.flex='none';
   b.onclick=()=>browse({title:f.browseTitle||('Select '+(f.label||f.key)),filter:f.filter||'*.*',mode:'file',onPick:pp=>{inp.value=pp;}});
   wrap.appendChild(inp);wrap.appendChild(b);w.appendChild(lb);w.appendChild(wrap);box.appendChild(w);return;}
  const isTa=(f.type==='textarea');const inp=document.createElement(isTa?'textarea':'input');inp.id='inp_'+f.key;if(!isTa)inp.type=f.type||'text';inp.style.width='100%';if(isTa){inp.rows=Math.min(16,Math.max(5,String(f.value||'').split('\n').length+1));inp.style.fontFamily='"Cascadia Code",Consolas,"SF Mono",Menlo,"DejaVu Sans Mono",monospace';inp.style.fontSize='12px';inp.style.boxSizing='border-box';
   // A textarea field fills whatever room the dialog actually has (both directions) instead of
   // sitting at a small fixed row-count with dead space below it - #inpFields is a flex column
   // (see its own style), so making this field's wrapper flex:1 and the textarea itself flex:1
   // lets it claim that space; the dialog is given a real default height below specifically so
   // there's space to claim in the first place.
   w.style.cssText+=';display:flex;flex-direction:column;flex:1;min-height:0';lb.style.flex='none';inp.style.flex='1';inp.style.minHeight='0';
  }if(f.value!=null)inp.value=f.value;if(f.placeholder)inp.placeholder=f.placeholder;if(f.maxlength)inp.maxLength=f.maxlength;
  inp.onkeydown=e=>{if(e.key==='Enter'&&!isTa){e.preventDefault();inpOk();}else if(e.key==='Escape'){e.preventDefault();inpCancel();}};w.appendChild(lb);w.appendChild(inp);box.appendChild(w);});
 // A textarea field (e.g. editing a saved query's SQL) already resizes both ways like any browser
 // textarea, but the dialog's normal 460px width cramps that - widen it so there's real room to
 // drag into, matching the cell-edit modal's more generous default size.
 // opts.width lets a caller with a denser form (several selects, not just one textarea) ask for
 // more room directly, instead of every such case needing its own heuristic here.
 const hasTa=(opts.fields||[]).some(f=>f.type==='textarea');
 const mbox=$('mInput').querySelector('.box');mbox.style.width=opts.width||(hasTa?'700px':'460px');mbox.style.maxWidth=opts.maxWidth||(hasTa?'95vw':'92vw');
 // A textarea field's flex:1 (above) has nothing to grow into without the dialog itself having a
 // real height - it's normally auto/content-sized, which is exactly the flex-basis-collapse trap
 // hit elsewhere in this app (see mView/mCompare) if left unset here.
 mbox.style.height=hasTa?(opts.height||'560px'):'';mbox.style.maxHeight=hasTa?'85vh':'';
 $('inpOk').textContent=opts.okText||'OK';show('mInput');setTimeout(()=>{const f0=box.querySelector('input,textarea,select');if(f0){f0.focus();f0.select&&f0.select();}},40);});}
function inpOk(){const out={};$('inpFields').querySelectorAll('input,textarea,select').forEach(i=>{out[i.id.slice(4)]=(i.type==='checkbox')?i.checked:i.value;});hide('mInput');const r=_inpResolve;_inpResolve=null;if(r)r(out);}
function inpCancel(){hide('mInput');const r=_inpResolve;_inpResolve=null;if(r)r(null);}
async function ask(msg){const d=(window.__TAURI__&&window.__TAURI__.dialog);if(d&&d.confirm){try{return await d.confirm(msg,{title:'Confirm',kind:'warning'});}catch(e){}}return window.confirm(msg);}
function menu(x,y,items){const m=$('ctx');m.innerHTML='';buildMenuItems(m,items);m.style.display='block';m.style.visibility='hidden';m.style.left='0';m.style.top='0';const w=m.offsetWidth||190,h=m.offsetHeight||0;let nx=Math.min(x,innerWidth-w-6);if(nx<6)nx=6;let ny=y;if(y+h>innerHeight-6)ny=Math.max(6,innerHeight-h-6);m.style.left=nx+'px';m.style.top=ny+'px';m.style.visibility='visible';}
function buildMenuItems(container,items){items.forEach(it=>{if(it==='-'){const s=document.createElement('div');s.className='sep';container.appendChild(s);return;}const d=document.createElement('div');d.className='item';const isSub=Array.isArray(it[1]);d.textContent=it[0]+(isSub?'  \u25B8':'');const _destr=/^(drop|truncate|delete|rename|create|alter|import|design)/i.test(it[0]||'');if(window.readOnly&&_destr){d.className='item rodis';d.title='Disabled in read-only mode';container.appendChild(d);return;}
 if(isSub){d.style.position='relative';const fly=document.createElement('div');fly.className='ctxsub';buildMenuItems(fly,it[1]);d.appendChild(fly);let ht=null;const showFly=()=>{if(ht){clearTimeout(ht);ht=null;}fly.style.display='block';fly.style.left='';fly.style.right='';fly.style.top='0';const r=fly.getBoundingClientRect(),dr=d.getBoundingClientRect();if(dr.right+r.width>innerWidth-4){fly.style.right='100%';}else{fly.style.left='100%';}if(dr.top+r.height>innerHeight-4){fly.style.top=(innerHeight-4-(dr.top+r.height))+'px';}};const hideFly=()=>{ht=setTimeout(()=>{fly.style.display='none';},200);};d.onmouseenter=showFly;d.onmouseleave=hideFly;fly.onmouseenter=()=>{if(ht){clearTimeout(ht);ht=null;}};fly.onmouseleave=hideFly;
 }else{d.onclick=()=>{$('ctx').style.display='none';it[1]();};}
 container.appendChild(d);});}
document.addEventListener('click',(e)=>{$('ctx').style.display='none';const cp=$('colPicker');if(cp&&cp.style.display==='block'&&!cp.contains(e.target))cp.style.display='none';const cm=$('copyMenu');if(cm&&cm.style.display==='block'&&!cm.contains(e.target))cm.style.display='none';});

// syntax highlight (single-pass tokenizer)
const KW=RESERVED;
// hl(): lightweight SQL syntax highlighter drawn behind the editor textarea.
function hl(code){let re=/(\/\*[\s\S]*?\*\/|--[^\n]*)|('(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*"|`(?:[^`]|``)*`)|(\b\d+(?:\.\d+)?\b)|([A-Za-z_][A-Za-z0-9_]*)|([\s\S])/g;let out='',m;
 while((m=re.exec(code))){if(m[1])out+='<span class="c-com">'+esc(m[1])+'</span>';else if(m[2])out+='<span class="c-str">'+esc(m[2])+'</span>';else if(m[3])out+='<span class="c-num">'+esc(m[3])+'</span>';else if(m[4])out+=(KW.has(m[4].toLowerCase())?'<span class="c-kw">'+esc(m[4])+'</span>':esc(m[4]));else out+=esc(m[5]);}
 return out;}
function syncHl(id){const ta=$('ed_'+id),pre=$('hl_'+id);if(!ta||!pre)return;pre.innerHTML=hl(ta.value)+'\n';pre.scrollTop=ta.scrollTop;pre.scrollLeft=ta.scrollLeft;}

// connection profiles
function connTitle(){const s=$('connlist');if(s)s.title=(s.selectedIndex>0?s.options[s.selectedIndex].text:'Saved connections');}
// --- Connections: dropdown, New/Save/pick, and the 'primary' (auto-open) flag.
function updatePrimeBtn(){const b=$('primeBtn');if(!b)return;const n=$('connlist').value;const isP=(n&&n===window._primaryConn);b.textContent=(isP?'\u2605':'\u2606')+' Primary';b.style.color=isP?'#f5c518':'';b.title=isP?'This is the primary connection (opens on startup). Click to unset.':'Set as primary connection (opens automatically on startup)';}
function connMenu(e){e.stopPropagation();if(!$('connlist').value){toast('Select a saved connection first.',true);return;}const b=e.currentTarget.getBoundingClientRect();const isP=($('connlist').value===window._primaryConn);const items=[['Edit\u2026',()=>editConn()],['Clone\u2026',()=>cloneConn()],[(isP?'Unset primary':'Set as primary'),()=>setPrimary()],['Clear password',()=>forgetPassword()]];if(!document.body.classList.contains('disconnected')){items.push('-');items.push(['Connect with different details\u2026',()=>toggleConnForm()]);}items.push('-');items.push(['Delete\u2026',()=>delConn()]);menu(b.left,b.bottom+2,items);}
async function forgetPassword(){const n=$('connlist').value;if(!n){toast('Select a connection first.',true);return;}if(!(await ask('Remove the saved password for "'+n+'"? You will type it on next connect.')))return;const g=await api('/api/conn-get',{name:n});if(!g.ok){toast('Could not load connection.',true);return;}const r=await api('/api/conn-save',{name:n,conn:{host:g.conn.host,port:g.conn.port,user:g.conn.user,ssl:g.conn.ssl,sslCa:g.conn.sslCa,password:''},savepw:false});if(r.ok){log('Removed saved password for '+n+'.');if($('connlist').value===n)setPass('');}else toast(r.error||'Failed',true);}
async function setPrimary(){const n=$('connlist').value;if(!n){toast('Select a connection first.',true);return;}const target=(n===window._primaryConn)?'':n;const r=await api('/api/conn-primary',{name:target});if(!r.ok){toast(r.error||'Failed',true);return;}await refreshConns();$('connlist').value=n;updatePrimeBtn();log(target?('Primary connection set: '+n+' (opens on startup)'):'Primary connection cleared.');}
async function refreshConns(){const r=await api('/api/conn-list');const sel=$('connlist');sel.innerHTML='<option value="" disabled hidden>Connections</option>';const n=(r.ok&&r.items)?r.items.length:0;window._primaryConn='';window._connMeta={};if(r.ok)r.items.forEach(c=>{if(c.primary)window._primaryConn=c.name;window._connMeta[c.name]={accent:c.accent||'',env:c.env||'',readonly:!!c.readonly};const o=document.createElement('option');o.value=c.name;
  // Only READ-ONLY here: the environment label has its own chip (envChip) beside the
  // connection state, and repeating it made the entry read as part of the connection's name.
  const tags=[];if(c.readonly)tags.push('READ-ONLY');
  o.textContent=(c.primary?'\u2605 ':'')+c.name+(tags.length?'  ['+tags.join(' \u2013 ')+']':'');
  sel.appendChild(o);});sel.disabled=(n===0);sel.title=(n===0?'No saved connections yet - fill in the details and Save':'Saved connections');connTitle();updatePrimeBtn();}
// Manually forces #connFormRow visible even while connected, overriding the CSS rule that
// hides it by default at that point - see the CSS comment above body:not(.disconnected) for
// the reasoning. Purely a visibility toggle; doesn't touch any saved connection data.
function toggleConnForm(){document.body.classList.toggle('show-connform');}
function newConn(){$('connlist').value='';$('host').value='127.0.0.1';$('port').value='3306';$('user').value='';$('pass').value='';$('ssl').value='default';$('sslca').value='';sslCaToggle();window.curAccent='';applyAccent('');window.readOnly=false;window.curEnv='';const ec=$('envChip');if(ec)ec.style.display='none';const pwc=$('pwChip');if(pwc)pwc.style.display='none';document.body.classList.add('show-connform');document.body.classList.remove('ro');connTitle();$('user').focus();log('New connection - enter details and Save.');}
function setPass(pw){const el=$('pass');if(el)el.value=pw;}
async function pickConnGuarded(){
  if (anyPending() && !(await ask('You have unsaved grid edits open. Switching connections will leave them orphaned. Switch anyway?'))) return;
  return pickConn();
}
// pickConn(): loads a saved connection's details into the FORM ONLY when you pick it - this
// is just a preview/starting point for a future Connect click. It deliberately does NOT touch
// window.readOnly, the env chip, or the accent border, because those describe the connection
// you are ACTUALLY connected to and must never change just from browsing the dropdown - doing
// so previously let a merely-selected (not connected) profile silently redirect live queries
// and read-only enforcement to the wrong server. All of that is applied atomically in connect()
// once a connection actually succeeds.
async function pickConn() {
    const n = $('connlist').value;
    if (!n) { return; }
    const r = await api('/api/conn-get', { name: n });
    if (r.ok) {
        $('host').value = r.conn.host;
        $('port').value = r.conn.port;
        $('user').value = r.conn.user;
        $('ssl').value = r.conn.ssl;
        $('sslca').value = r.conn.sslCa || '';
        sslCaToggle();
        const _pw = r.conn.password || '';
        setPass(_pw);
        window._connMeta = window._connMeta || {};
        window._connMeta[n] = {accent:r.conn.accent||'', env:r.conn.env||'', readonly:!!r.conn.readonly};
        // Persistent, tied only to which connection is currently selected - not to whether
        // you're actually connected. Deliberately does NOT defer to connStatus the way an
        // earlier version did: that meant the indicator only ever showed AFTER connecting,
        // which is exactly backwards from the point (knowing beforehand whether you'll need to
        // type a password). Simple icon rather than a text chip, so it doesn't compete for
        // width with the dropdown itself or wrap awkwardly at narrower window sizes.
        const pwc=$('pwChip');if(pwc)pwc.style.display=_pw?'inline':'none';
        // Env label / read-only chip: same "preview the selected connection, not the active
        // one" treatment as the password icon above. Uses renderEnvChip() only (not applyEnv())
        // so it's purely cosmetic here - window.readOnly/curEnv, and therefore actual write
        // blocking, still only flip once connect() itself succeeds.
        renderEnvChip(r.conn.env||'', !!r.conn.readonly, r.conn.accent||accMap()[n]||'');
        // Force #connFormRow visible: if already connected and switching to a DIFFERENT saved
        // connection, the Connect button itself lives inside that row - if it stayed collapsed
        // there'd be no way to actually click it. connect()'s own success path resets this
        // back to collapsed once it actually succeeds, regardless of how it got shown.
        document.body.classList.add('show-connform');
        log('Loaded connection: ' + n + (_pw ? '' : ' (no saved password - type one and Save)') + ' - click Connect to switch to it.');
    }
}
// Always saves through an explicit, full dialog - never a silent, one-click overwrite of
// whichever connection happened to be selected. Previously, with a connection selected, this
// wrote the LIVE inline form's current host/port/user/pass straight over the saved profile with
// zero confirmation - genuinely risky once that form became collapsed-by-default elsewhere in
// this app, since you could easily forget it held temporary, unsaved values (e.g. from testing
// a different user via "Connect with different details...") and clobber the real saved details by
// mistake. Now the dialog always shows exactly what's about to be written, pre-filled from
// whatever's currently live - keeping the same name as an already-selected connection updates
// it (matching the backend's existing same-name-means-update behavior); a different name saves
// a new, separate one, leaving the original untouched. "Edit..." remains the place to
// deliberately change a saved connection's details regardless of what's currently loaded live.
async function saveConn(){
 const n0=$('connlist').value;
 const m0=n0?(connMeta()[n0]||{}):{};
 const dn=n0||($('user').value+'@'+$('host').value);
 const res=await inputBox({title:'Save connection',okText:'Save',fields:[
  {key:'name',label:'Save connection as',value:dn,maxlength:60},
  {key:'host',label:'Host',value:$('host').value},
  {key:'port',label:'Port',value:$('port').value},
  {key:'user',label:'User',value:$('user').value},
  {key:'password',label:'Password',type:'password',value:$('pass').value},
  {key:'ssl',label:'SSL',type:'select',options:[{value:'default',label:'default'},{value:'disabled',label:'disabled'},{value:'required',label:'required'},{value:'verify',label:'verify (CA and host name)'},{value:'verify-ca',label:'verify-ca (CA only - for auto-generated server certificates)'}],value:$('ssl').value},
  {key:'sslCa',label:'CA certificate - only used by SSL "verify"; leave empty to use the system trust store',type:'file',filter:'*.pem',browseTitle:'Select CA certificate',placeholder:'e.g. C:\\certs\\server-ca.pem',value:$('sslca').value},
  {key:'color',label:'Accent color (tell servers apart at a glance)',type:'color',value:n0?(accMap()[n0]||'#3b82f6'):'#3b82f6'},
  {key:'env',label:'Environment label (e.g. Production, Dev) - optional',value:m0.env||'',maxlength:40},
  {key:'ro',label:'Read-only / safe mode (block all writes)',type:'checkbox',value:!!m0.readonly},
  {key:'savepw',label:'Save password (unchecked = type it each time)',type:'checkbox',value:n0?!!$('pass').value:true}
 ]});
 if(!res||!res.name.trim())return;const n=res.name.trim();
 const r=await api('/api/conn-save',{name:n,conn:{host:res.host,port:res.port,user:res.user,password:res.password,ssl:res.ssl,sslCa:res.sslCa},accent:res.color,env:(res.env||'').trim(),readonly:!!res.ro,savepw:!!res.savepw});
 if(!r.ok){toast(r.error,true);return;}
 window.curAccent=res.color;applyAccent(res.color);log('Saved connection: '+n);await refreshConns();$('connlist').value=n;applyEnv(n);
 $('host').value=res.host;$('port').value=res.port;$('user').value=res.user;$('ssl').value=res.ssl;$('sslca').value=res.sslCa||'';sslCaToggle();setPass(res.password);
 const pwc=$('pwChip');if(pwc)pwc.style.display=res.password?'inline':'none';
}
// Edits a saved connection entirely within its own dialog - host/port/user/password/ssl are
// fields here directly, fetched fresh from the actual saved data, rather than the dialog only
// covering name/accent/env/etc. while silently relying on whatever the inline form (behind the
// dialog) happened to already contain. A dialog titled "Edit connection" that didn't actually
// let you edit the connection's own host or credentials was the real problem being fixed here.
async function editConn(){const n0=$('connlist').value;if(!n0){toast('Select a saved connection to edit first.',true);return;}
 const g=await api('/api/conn-get',{name:n0});if(!g.ok){toast('Could not load connection.',true);return;}
 const m0=connMeta()[n0]||{};
 const res=await inputBox({title:'Edit connection',okText:'Save',fields:[
  {key:'name',label:'Name',value:n0,maxlength:60},
  {key:'host',label:'Host',value:g.conn.host},
  {key:'port',label:'Port',value:g.conn.port},
  {key:'user',label:'User',value:g.conn.user},
  {key:'password',label:'Password',type:'password',value:g.conn.password||''},
  {key:'ssl',label:'SSL',type:'select',options:[{value:'default',label:'default'},{value:'disabled',label:'disabled'},{value:'required',label:'required'},{value:'verify',label:'verify (CA and host name)'},{value:'verify-ca',label:'verify-ca (CA only - for auto-generated server certificates)'}],value:g.conn.ssl},
  {key:'sslCa',label:'CA certificate - only used by SSL "verify"; leave empty to use the system trust store',type:'file',filter:'*.pem',browseTitle:'Select CA certificate',placeholder:'e.g. C:\\certs\\server-ca.pem',value:g.conn.sslCa||''},
  {key:'color',label:'Accent color',type:'color',value:accMap()[n0]||'#3b82f6'},
  {key:'env',label:'Environment label (optional)',value:m0.env||'',maxlength:40},
  {key:'ro',label:'Read-only / safe mode (block all writes)',type:'checkbox',value:!!m0.readonly},
  {key:'savepw',label:'Save password (uncheck to remove the saved password)',type:'checkbox',value:!!(g.ok&&g.conn.password)}
 ]});
 if(!res||!res.name.trim())return;const nn=res.name.trim();
 const r=await api('/api/conn-save',{name:nn,conn:{host:res.host,port:res.port,user:res.user,password:res.password,ssl:res.ssl,sslCa:res.sslCa},accent:res.color,env:(res.env||'').trim(),readonly:!!res.ro,savepw:!!res.savepw});if(!r.ok){toast(r.error,true);return;}
 if(nn!==n0){await api('/api/conn-delete',{name:n0});}
 window.curAccent=res.color;applyAccent(res.color);await refreshConns();$('connlist').value=nn;applyEnv(nn);
 // If this connection is the one currently loaded into the (largely internal, now rarely
 // shown) inline form, keep it in sync with what was just saved - otherwise a subsequent
 // Connect click would silently use stale values from before the edit.
 if($('connlist').value===nn){$('host').value=res.host;$('port').value=res.port;$('user').value=res.user;$('ssl').value=res.ssl;$('sslca').value=res.sslCa||'';sslCaToggle();setPass(res.password);const pwc=$('pwChip');if(pwc)pwc.style.display=res.password?'inline':'none';}
 log('Updated connection: '+nn);}
async function cloneConn(){const n0=$('connlist').value;
 if(n0){const g=await api('/api/conn-get',{name:n0});if(g.ok){$('host').value=g.conn.host;$('port').value=g.conn.port;$('user').value=g.conn.user;$('ssl').value=g.conn.ssl;$('sslca').value=g.conn.sslCa||'';sslCaToggle();$('pass').value=g.conn.password;}}
 const base=n0||($('user').value+'@'+$('host').value);
 const res=await inputBox({title:'Clone connection',okText:'Clone',fields:[{key:'name',label:'New connection name',value:base+' (copy)',maxlength:60}]});
 if(!res||!res.name.trim())return;const nn=res.name.trim();
 const r=await api('/api/conn-save',{name:nn,conn:getConn()});if(!r.ok){toast(r.error,true);return;}
 if(n0){const c=accMap()[n0];if(c)accSet(nn,c);const m=connMeta()[n0];if(m)connMetaSet(nn,m);}
 await refreshConns();$('connlist').value=nn;window.curAccent=accMap()[nn]||'';applyAccent(window.curAccent);applyEnv(nn);
 log('Cloned connection: '+nn);}
async function delConn(){const n=$('connlist').value;if(!n)return;if(!(await ask('Delete saved connection "'+n+'"?')))return;await api('/api/conn-delete',{name:n});accSet(n,'');window.curAccent='';applyAccent('');refreshConns();}

// connect(): open the connection, then load the schema sidebar.
async function connect() {
  if (anyPending()) {
    if (!(await ask('You have unsaved grid edits open. Connecting will leave them orphaned. Continue?'))) return;
  }
  // If a saved connection is selected but no password is typed, load its details first
  // (so you can just pick a connection and hit Connect). A typed password is respected.
  try { if ($('connlist').value && !$('pass').value) { await pickConn(); } } catch (e) {}
  log('Connecting to ' + $('host').value + ' ...');
  const r = await api('/api/connect');
  if (!r.ok) {
    log('  ' + r.error);
    // Both backends already open their message with "Connection failed:", so adding it here too
    // printed it twice.
    toast(/^Connection failed/i.test(String(r.error)) ? r.error : 'Connection failed: ' + r.error, true);
    disconnect();
    if (tabs.length) { await closeAll(); }
    return;
  }
  log('  Connected: ' + r.version + ' (' + (r.mariadb ? 'MariaDB' : 'MySQL') + ')');
  window.mariadb = !!r.mariadb;
  document.body.classList.remove('disconnected');
  document.body.classList.remove('show-connform');
  const _cs = $('connStatus'); if (_cs) { const _sel=$('connlist'); _cs.textContent = 'Connected: ' + (_sel && _sel.value ? _sel.options[_sel.selectedIndex].text.replace(/^\u2605 /, '') : ($('user').value + '@' + $('host').value)); _cs.title = _cs.textContent; _cs.className = 'chip ok'; }
  applyAccent(window.curAccent || '');
  applyEnv($('connlist').value);
  // IMPORTANT: snapshot the active connection BEFORE restoring any tabs below - restoring a
  // table tab auto-runs its query, and every api() call (other than the connect attempt
  // itself) uses this snapshot rather than the live form. Setting it after restore meant
  // restored tabs briefly queried the CONNECTION YOU JUST LEFT instead of the new one.
  window._activeConn = getConn();
  window._activeReadOnly = window.readOnly;
  // Each connection remembers its own open tabs. Switching to a different connection saves
  // the tabs you're leaving (under its own key) and restores the new connection's own tabs.
  const _newKey = sessionKeyFor();
  if (window._sessionKey && window._sessionKey !== _newKey) {
    saveSession(window._sessionKey);
    clearAllTabsSilently();
    clearObjectsPanel();
    restoreSessionFor(_newKey);
  } else if (!window._sessionKey) {
    clearObjectsPanel();
    restoreSessionFor(_newKey);
  }
  window._sessionKey = _newKey;
  if (activeTab) updateSchemaBadge(activeTab);
  loadSchemas();
  if (curSchema) { loadObjects(curSchema); }
  toggleOverview();

}
function clearObjectsPanel(){$('objects').innerHTML='';$('objdb').textContent='';if($('objFilter'))$('objFilter').value='';curSchema=null;objData=null;}
function disconnect(){window.mariadb=false;document.body.classList.add('disconnected');window._activeConn=null;window._activeReadOnly=false;$('schemas').innerHTML='';clearObjectsPanel();applyAccent('');const _cs=$('connStatus');if(_cs){_cs.textContent='Not connected';_cs.className='chip bad';}window.curAccent='';window.readOnly=false;window.curEnv='';
 // Re-preview the still-selected connection's env chip rather than hard-hiding it, same as the
 // password icon (never touched here) already does - "Not connected" shouldn't also erase what
 // you were just looking at in the dropdown.
 const _n=$('connlist')&&$('connlist').value;const _m=_n?(connMeta()[_n]||{}):{};renderEnvChip(_m.env||'', !!_m.readonly, _m.accent||(_n?accMap()[_n]:'')||'');
 const _sb=$('schemaBadge');if(_sb){_sb.style.display='none';_sb.textContent='';}
 document.body.classList.remove('ro');log('Disconnected.');}
async function refreshSchemasAndTables(){await loadSchemas();if(typeof curSchema!=='undefined'&&curSchema){await loadObjects(curSchema);}}
async function loadSchemas() {
    const r = await api('/api/schemas');
    const box = $('schemas');
    box.innerHTML = '';
    if (!r.ok) { log('  ' + r.error); return; }

    // Store schema names for backward compatibility
    window.allSchemas = r.schemas.map(s => s.name);
    log('  Schemas (' + r.schemas.length + '): ' + r.schemas.map(s => s.name).join(', '));

    r.schemas.forEach(sc => {
        const d = document.createElement('div');
        d.className = 'item';
        const sizeStr = sc.size > 0 ? ' (' + fmtBytes(sc.size) + ')' : '';
        d.textContent = sc.name + sizeStr;
        d.title = sc.name + sizeStr;

        d.onclick = () => {
            [...box.children].forEach(c => c.classList.remove('sel'));
            d.classList.add('sel');
            curSchema = sc.name;
            $('objdb').textContent = sc.name;
            $('objdb').title = sc.name;
            // dbOf() gives curSchema priority for a plain query tab, so this click changes
            // where the next query runs - the badge has to say so, or it keeps advertising
            // the previous schema while queries go somewhere else.
            if (activeTab) updateSchemaBadge(activeTab);
            loadObjects(sc.name);
        };

        d.oncontextmenu = e => {
            e.preventDefault();
            menu(e.clientX, e.clientY, [
                ['New table (designer)...', () => designTable(null, sc.name)],
                ['New procedure...', () => newProcedure(sc.name)],
                ['New function...', () => newFunction(sc.name)],
                ['ER Diagram...', () => openErd(sc.name)],
                ['Drop schema...', () => dropSchema(sc.name)],
                '-',
                ['Refresh', () => loadSchemas()]
            ]);
        };
        box.appendChild(d);
    });
}
function fmtBytes(b){b=+b||0;if(b<1024)return b+" B";const u=["KB","MB","GB","TB"];let i=-1;do{b/=1024;i++;}while(b>=1024&&i<u.length-1);return (b<10?b.toFixed(1):Math.round(b))+" "+u[i];}
function invalidateTableCache(db,table){
  if(!db||!table)return;
  try{
    const key='tableSizes_'+connKey()+'_'+db;
    const cached=localStorage.getItem(key);
    if(cached){
      const parsed=JSON.parse(cached);
      if(parsed.sizes) delete parsed.sizes[table];
      if(parsed.rowCounts) delete parsed.rowCounts[table];
      localStorage.setItem(key, JSON.stringify(parsed));
    }
  }catch(e){}
  if(objData && objData.db===db){
    if(objData.sizes) delete objData.sizes[table];
    if(objData.rowCounts) delete objData.rowCounts[table];
  }
}

function pinnedTables(db){try{return JSON.parse(localStorage.getItem('pinned_'+connKey()+'_'+db)||'[]');}catch(e){return [];}}
function setPinnedTables(db,arr){try{localStorage.setItem('pinned_'+connKey()+'_'+db,JSON.stringify(arr));}catch(e){}}
function togglePin(db,name){const p=pinnedTables(db);const i=p.indexOf(name);if(i>=0)p.splice(i,1);else p.push(name);setPinnedTables(db,p);renderObjects();}

function fmtCount(n){n=Math.round(+n||0);return String(n).replace(/\B(?=(\d{3})+(?!\d))/g,"'");}
function fmtMs(ms){ms=+ms||0;if(ms>=10000)return Math.round(ms/1000)+'s';if(ms>=1000)return (ms/1000).toFixed(1)+'s';return Math.round(ms)+'ms';}
function updateStatusLine(id){const t=T(id);if(!t||!t.rows)return;const st=$('st_'+id);if(!st)return;
  const rowLabel=(t.table&&t.estRows!=null)?(t.rows.length+' row(s) of '+fmtCount(t.estRows)+' rows.'):(t.rows.length+' row(s).');
  const ms=(t.lastElapsedMs!=null)?(' '+t.lastElapsedMs+' ms'):'';
  st.className='status';
  // The grid itself is a single continuous virtualized list over everything loaded so far - no
  // "page" to move to - so this just says more is available; scrolling near the bottom (see
  // maybePrefetchNextBatch) is what actually goes and gets it, automatically.
  const moreLabel=t.hasMore?'  |  more rows available - keep scrolling to load more':'';
  st.textContent=rowLabel+ms+moreLabel+(t.pk?('  |  editable PK: '+t.pk.join(', ')):'');
}
let objData=null;
async function loadObjects(db) {
    const r = await api('/api/objects', { db });
    if (!r.ok) { log('  ' + r.error); return; }

    // Try to load cached sizes from localStorage
    let cachedSizes = {};
    let cachedRowCounts = {};
    let cacheValid = false;
    try {
        const cacheKey = 'tableSizes_' + connKey() + '_' + db;
        const cached = localStorage.getItem(cacheKey);
        if (cached) {
            const parsedCache = JSON.parse(cached);
            if (parsedCache.timestamp && (Date.now() - parsedCache.timestamp) < 300000) { // Cache valid for 5 minutes
                cachedSizes = parsedCache.sizes;
                cachedRowCounts = parsedCache.rowCounts || {};
                cacheValid = true;
            }
        }
    } catch (e) { /* ignore cache read errors */ }

    objData = { db, r, sizes: cachedSizes, rowCounts: cachedRowCounts };
    $('objFilter').value = '';
    renderObjects();
    buildColHints(db);

    // Fetch fresh sizes if not cached or cache expired
    if (!cacheValid) {
        try {
            const sz = await api('/api/query', { sql: "SELECT TABLE_NAME, DATA_LENGTH+INDEX_LENGTH, TABLE_ROWS FROM information_schema.TABLES WHERE TABLE_SCHEMA=" + lit(db) });
            if (!sz.ok) { /* size query failed; leave sizes as-is */ }
            else {
                const m = {}, rc = {};
                sz.rows.forEach(r2 => { m[String(r2[0])] = r2[1]; rc[String(r2[0])] = r2[2]; });
                objData.sizes = m;
                objData.rowCounts = rc;
                // Cache the sizes in localStorage with a timestamp
                try {
                    localStorage.setItem(
                        'tableSizes_' + connKey() + '_' + db,
                        JSON.stringify({
                            timestamp: Date.now(),
                            sizes: m,
                            rowCounts: rc
                        })
                    );
                } catch (e) { /* ignore cache write errors */ }
                renderObjects();
            }
        } catch (e) { /* ignore size errors */ }
    }
}

let _busyDepth=0;
function busyStart(){_busyDepth++;let bar=$('_globalBusy');if(!bar){bar=document.createElement('div');bar.id='_globalBusy';bar.style.cssText='position:fixed;top:0;left:0;height:3px;width:100%;background:var(--accent);z-index:99998;animation:expmove 1s ease-in-out infinite;display:none';document.body.appendChild(bar);}bar.style.display='block';}
function busyStop(){_busyDepth=Math.max(0,_busyDepth-1);if(_busyDepth===0){const bar=$('_globalBusy');if(bar)bar.style.display='none';}}

let _progTimers={},_progJobIds={};
function progStart(prefix,totalLabel,jobId){
  const box=$(prefix+'Progress'),lbl=$(prefix+'ProgLabel'),btn=$(prefix+'GoBtn'),cbtn=$(prefix+'CancelBtn');
  // visibility, not display: hiding the Cancel button with display:none reflows the row
  // and slides Close into the pixel Cancel just occupied. A user who clicks Cancel and
  // sees nothing happen clicks again - onto Close, which shuts the dialog. Reserving
  // the space keeps every other button where it was.
  if(box)box.style.display='block'; if(btn)btn.disabled=true; if(cbtn)cbtn.disabled=false;
  _progJobIds[prefix]=jobId;
  const t0=Date.now();
  _progTimers[prefix]=setInterval(()=>{const secs=((Date.now()-t0)/1000).toFixed(0);if(lbl)lbl.textContent=(totalLabel?totalLabel+' \u2014 ':'')+'running for '+secs+'s...';},250);
}
function progStop(prefix){
  const box=$(prefix+'Progress'),btn=$(prefix+'GoBtn'),cbtn=$(prefix+'CancelBtn');
  if(_progTimers[prefix]){clearInterval(_progTimers[prefix]);delete _progTimers[prefix];}
  if(box)box.style.display='none'; if(btn)btn.disabled=false; if(cbtn)cbtn.disabled=true;
  delete _progJobIds[prefix];
}
async function cancelJob(prefix){
  const jobId=_progJobIds[prefix]; if(!jobId)return;
  const lbl=$(prefix+'ProgLabel'); if(lbl)lbl.textContent='Cancelling...';
  try{await fetch('/api/cancel-job',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({token:TOKEN,jobId})});}catch(e){}
  log('Cancel requested for '+prefix+' job.');
}
const OBJ_TYPES=[['table','Tables'],['view','Views'],['procedure','Procedures'],['function','Functions'],['trigger','Triggers'],['event','Events']];
window._objTypeFilter=window._objTypeFilter||new Set(OBJ_TYPES.map(t=>t[0]));
function setObjTypeVis(type,visible){const s=window._objTypeFilter;if(visible)s.add(type);else s.delete(type);renderObjects();}
function showAllObjTypes(){window._objTypeFilter=new Set(OBJ_TYPES.map(t=>t[0]));renderObjects();const btn=$('objTypeBtn');if(btn)openObjTypePicker(btn);}
function hideAllObjTypes(){window._objTypeFilter=new Set();renderObjects();const btn=$('objTypeBtn');if(btn)openObjTypePicker(btn);}
// Same toggle-close behavior as the Columns picker - a second click on the Types button while
// its own picker is already open closes it, instead of relying only on the outside-click listener.
function toggleObjTypePicker(btn){const p=$('objTypePicker');if(p&&p.style.display==='block'){p.style.display='none';return;}openObjTypePicker(btn);}
function openObjTypePicker(btn){const p=$('objTypePicker');const s=window._objTypeFilter;
 let h='<div class="cphdr"><span>Show/hide object types</span><span><span class="cplink" onclick="event.stopPropagation();showAllObjTypes()">Show all</span> \u00b7 <span class="cplink" onclick="event.stopPropagation();hideAllObjTypes()">Hide all</span></span></div>';
 OBJ_TYPES.forEach(([type,label])=>{h+='<label class="cpitem"><input type="checkbox" '+(s.has(type)?'checked':'')+' onchange="setObjTypeVis(\''+type+'\',this.checked)"> '+label+'</label>';});
 p.innerHTML=h;
 p.style.display='block';p.style.visibility='hidden';p.style.left='0';p.style.top='0';
 const r=btn.getBoundingClientRect();const w=p.offsetWidth||200,hgt=p.offsetHeight||0;
 let nx=Math.min(r.left,innerWidth-w-6);if(nx<6)nx=6;
 let ny=r.bottom+2;if(ny+hgt>innerHeight-6)ny=Math.max(6,r.top-hgt-2);
 p.style.left=nx+'px';p.style.top=ny+'px';p.style.visibility='visible';}
function renderObjects(){const box=$('objects');box.innerHTML='';if(!objData)return;const db=objData.db,r=objData.r;const f=($('objFilter').value||'').toLowerCase();const tf=window._objTypeFilter;
 const pinned=tf.has('table')?pinnedTables(db):[];
 if(pinned.length){
   const fil=pinned.filter(n=>r.tables.includes(n)&&(!f||n.toLowerCase().includes(f)));
   if(fil.length){const h=document.createElement('div');h.className='ohdr';h.textContent='\u2605 Pinned ('+fil.length+')';box.appendChild(h);
     fil.forEach(n=>{const d=document.createElement('div');d.className='item';d.title=n;if(objData.sizes&&(n in objData.sizes)){const a=document.createElement('span');a.className='onm';a.textContent=n;const b=document.createElement('span');b.className='osz';b.textContent=fmtBytes(objData.sizes[n]);d.appendChild(a);d.appendChild(b);}else{d.textContent=n;}
      d.onclick=()=>{[...box.querySelectorAll('.item')].forEach(c=>c.classList.remove('sel'));d.classList.add('sel');objOpen(db,'table',n);};
      d.oncontextmenu=e=>{e.preventDefault();objMenu(e,db,'table',n);};box.appendChild(d);});}
 }
 const groups=[['Tables',r.tables,'table'],['Views',r.views,'view'],['Procedures',r.procedures,'procedure'],['Functions',r.functions,'function'],['Triggers',r.triggers,'trigger'],['Events',r.events,'event']];
 groups.forEach(([label,items,type])=>{if(!tf.has(type))return;const fil=(items||[]).filter(n=>!f||n.toLowerCase().includes(f));if(!fil.length)return;const h=document.createElement('div');h.className='ohdr';h.textContent=label+' ('+fil.length+(f?'/'+items.length:'')+')';box.appendChild(h);
  fil.forEach(n=>{const d=document.createElement('div');d.className='item';d.title=n;if(type==='table'&&objData.sizes&&(n in objData.sizes)){const a=document.createElement('span');a.className='onm';a.textContent=n;const b=document.createElement('span');b.className='osz';b.textContent=fmtBytes(objData.sizes[n]);d.appendChild(a);d.appendChild(b);}else{d.textContent=n;}
   d.onclick=()=>{[...box.querySelectorAll('.item')].forEach(c=>c.classList.remove('sel'));d.classList.add('sel');objOpen(db,type,n);};
   d.oncontextmenu=e=>{e.preventDefault();objMenu(e,db,type,n);};box.appendChild(d);});});}
async function buildColHints(db){try{const r=await api('/api/query',{sql:"SELECT DISTINCT COLUMN_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA="+lit(db)});window.acColumns=(r.ok?r.rows.map(x=>x[0]):[]);}catch(e){window.acColumns=[];}}
// Cache keys are scoped to the active connection so a different server can't show stale schemas.
// --- Caching: sizes/overview are cached in the browser, keyed per connection (host:port:user).
function connKey(){try{return ($('host').value||'')+':'+($('port').value||'')+':'+($('user').value||'');}catch(e){return 'default';}}
function overviewCacheKey(){return 'overviewCache:'+connKey();}

// {r, fetchedAt} - the last fetched-or-loaded-from-cache overview data. Kept separately from
// the rendering step so sorting/filtering can re-render instantly against data already in hand,
// without a server round-trip every time the user clicks a column header or types a filter.
window._overviewRaw = null;
// Which column to sort by, and direction (1=ascending, -1=descending). Column 0 (Database) is
// the same order the underlying SQL query already returns, so this default renders identically
// to the pre-existing behavior until the user actually clicks a header.
window._overviewSort = {col: 0, dir: 1};

async function showOverview(forceRefresh) {
    const ov = $('overview');
    if (!ov) return;

    if (document.body.classList.contains('disconnected')) {
        ov.innerHTML = '<div class="muted" style="padding:8px">Connect to a database to view the overview.</div>';
        ov.style.display = 'block';
        return;
    }

    // Try to load cached data from localStorage, unless a refresh was explicitly requested (the
    // panel's own Refresh button passes forceRefresh=true to bypass this and always hit the server)
    if (!forceRefresh) {
        try {
            const cachedData = localStorage.getItem(overviewCacheKey());
            if (cachedData) {
                const parsedCache = JSON.parse(cachedData);
                if (parsedCache.timestamp && (Date.now() - parsedCache.timestamp) < 300000) { // Cache valid for 5 minutes
                    window._overviewRaw = { r: parsedCache.data, fetchedAt: parsedCache.timestamp };
                    renderOverview();
                    return;
                }
            }
        } catch (e) {
            /* ignore cache read errors */
        }
    }

    // No valid cache (or a refresh was requested), fetch fresh data
    ov.innerHTML = '<div class="muted" style="padding:8px">Loading database overview...</div>';
    ov.style.display = 'block';

    const sql = `SELECT s.SCHEMA_NAME, COALESCE(t.tbls,0), COALESCE(t.rws,0), COALESCE(t.sz,0), COALESCE(v.vw,0), COALESCE(r.pr,0), COALESCE(r.fn,0), COALESCE(tr.trg,0), COALESCE(ev.evt,0), s.DEFAULT_CHARACTER_SET_NAME, s.DEFAULT_COLLATION_NAME
        FROM information_schema.SCHEMATA s
        LEFT JOIN (SELECT TABLE_SCHEMA sc, COUNT(*) tbls, SUM(TABLE_ROWS) rws, SUM(DATA_LENGTH+INDEX_LENGTH) sz FROM information_schema.TABLES WHERE TABLE_TYPE='BASE TABLE' GROUP BY TABLE_SCHEMA) t ON t.sc=s.SCHEMA_NAME
        LEFT JOIN (SELECT TABLE_SCHEMA sc, COUNT(*) vw FROM information_schema.TABLES WHERE TABLE_TYPE='VIEW' GROUP BY TABLE_SCHEMA) v ON v.sc=s.SCHEMA_NAME
        LEFT JOIN (SELECT ROUTINE_SCHEMA sc, SUM(ROUTINE_TYPE='PROCEDURE') pr, SUM(ROUTINE_TYPE='FUNCTION') fn FROM information_schema.ROUTINES GROUP BY ROUTINE_SCHEMA) r ON r.sc=s.SCHEMA_NAME
        LEFT JOIN (SELECT TRIGGER_SCHEMA sc, COUNT(*) trg FROM information_schema.TRIGGERS GROUP BY TRIGGER_SCHEMA) tr ON tr.sc=s.SCHEMA_NAME
        LEFT JOIN (SELECT EVENT_SCHEMA sc, COUNT(*) evt FROM information_schema.EVENTS GROUP BY EVENT_SCHEMA) ev ON ev.sc=s.SCHEMA_NAME
        ORDER BY s.SCHEMA_NAME`;

    try {
        const r = await api('/api/query', { sql });
        if (!r.ok) {
            ov.innerHTML = '<div class="muted" style="padding:8px">Overview unavailable: ' + esc(r.error) + '</div>';
            return;
        }

        const fetchedAt = Date.now();
        // Cache the data in localStorage with a timestamp
        try {
            localStorage.setItem(
                overviewCacheKey(),
                JSON.stringify({
                    timestamp: fetchedAt,
                    data: r
                })
            );
        } catch (e) {
            /* ignore cache write errors */
        }

        window._overviewRaw = { r, fetchedAt };
        renderOverview();
    } catch (e) {
        ov.innerHTML = '<div class="muted" style="padding:8px">Overview error: ' + esc(e.message) + '</div>';
    }
}

function overviewTimeAgo(ts) {
    const secs = Math.floor((Date.now() - ts) / 1000);
    if (secs < 60) return 'just now';
    const mins = Math.floor(secs / 60);
    if (mins < 60) return mins + 'm ago';
    const hrs = Math.floor(mins / 60);
    return hrs + 'h ago';
}

function overviewSetSort(col) {
    const cur = window._overviewSort;
    // Toggle direction on a repeat click of the same column; a fresh column defaults to
    // descending for the numeric metrics (Tables/Rows/Size/etc - "biggest first" is usually
    // what's wanted when you click one of those) and ascending for the text columns
    // (Database/Charset/Collation - alphabetical is the natural first look).
    if (cur.col === col) cur.dir = -cur.dir;
    else { cur.col = col; cur.dir = (col >= 1 && col <= 8) ? -1 : 1; }
    renderOverview();
}

function overviewFilteredSortedRows() {
    const raw = window._overviewRaw;
    if (!raw) return [];
    const filterEl = $('overviewFilter');
    const filterText = (filterEl ? filterEl.value : '').trim().toLowerCase();
    let rows = raw.r.rows.filter(row => row[0] != null && row[0] !== '');
    if (filterText) rows = rows.filter(row => String(row[0]).toLowerCase().includes(filterText));
    const { col, dir } = window._overviewSort;
    const isNumericCol = col >= 1 && col <= 8;
    rows = rows.slice().sort((a, b) => {
        let av = a[col], bv = b[col];
        if (isNumericCol) { av = +av || 0; bv = +bv || 0; return (av - bv) * dir; }
        av = String(av == null ? '' : av); bv = String(bv == null ? '' : bv);
        return av.localeCompare(bv) * dir;
    });
    return rows;
}

function renderOverview() {
    const ov = $('overview');
    if (!ov) return;
    const raw = window._overviewRaw;
    if (!raw) return;

    // Preserve the filter box's focus/cursor/value across re-renders triggered by typing in it -
    // rebuilding innerHTML on every keystroke would otherwise destroy and recreate the input,
    // losing focus after a single character typed.
    const prevFilterEl = $('overviewFilter');
    const hadFocus = prevFilterEl && document.activeElement === prevFilterEl;
    const filterValue = prevFilterEl ? prevFilterEl.value : '';
    const cursorPos = prevFilterEl ? prevFilterEl.selectionStart : null;

    const H = ['Database', 'Tables', 'Rows', 'Size', 'Views', 'Procedures', 'Functions', 'Triggers', 'Events', 'Charset', 'Collation'];
    const allCount = raw.r.rows.filter(row => row[0] != null && row[0] !== '').length;
    const rows = overviewFilteredSortedRows();
    const { col: sortCol, dir: sortDir } = window._overviewSort;

    let h = '<div style="display:flex;align-items:center;gap:10px;margin-bottom:10px;flex-wrap:wrap">';
    h += '<h2 style="margin:0">Databases (' + rows.length + (rows.length !== allCount ? (' of ' + allCount) : '') + ')</h2>';
    h += '<input id="overviewFilter" placeholder="Filter databases..." style="width:200px" oninput="renderOverview()" value="' + esc(filterValue) + '">';
    h += '<span class="muted" style="font-size:11px">Updated ' + esc(overviewTimeAgo(raw.fetchedAt)) + '</span>';
    h += '<button class="sm" onclick="showOverview(true)">Refresh</button>';
    h += '</div>';
    h += '<table class="ovgrid"><thead><tr>' + H.map((x, i) => {
        const isNum = i >= 1 && i <= 8;
        const arrow = i === sortCol ? (sortDir > 0 ? ' \u25B2' : ' \u25BC') : '';
        return '<th' + (isNum ? ' class=num' : '') + ' style="cursor:pointer;user-select:none" onclick="overviewSetSort(' + i + ')" title="Click to sort">' + esc(x) + arrow + '</th>';
    }).join('') + '</tr></thead><tbody>';
    rows.forEach(row => {
        h += '<tr data-db="' + esc(String(row[0])) + '"><td>' + esc(String(row[0])) + '</td>'
            + '<td class=num>' + (+row[1] || 0) + '</td>'
            + '<td class=num>' + (+row[2] || 0) + '</td>'
            + '<td class=num>' + fmtBytes(row[3]) + '</td>'
            + '<td class=num>' + (+row[4] || 0) + '</td><td class=num>' + (+row[5] || 0) + '</td><td class=num>' + (+row[6] || 0) + '</td>'
            + '<td class=num>' + (+row[7] || 0) + '</td><td class=num>' + (+row[8] || 0) + '</td>'
            + '<td>' + esc(row[9] || '') + '</td><td>' + esc(row[10] || '') + '</td></tr>';
    });
    // Totals reflect the currently visible (filtered) rows, not the whole server - matches what
    // someone filtering down to a few databases would actually want summed.
    if (rows.length) {
        const sum = (idx) => rows.reduce((a, row) => a + (+row[idx] || 0), 0);
        h += '<tr style="font-weight:600;border-top:2px solid var(--bd)"><td>Total</td>'
            + '<td class=num>' + sum(1) + '</td><td class=num>' + sum(2) + '</td><td class=num>' + fmtBytes(sum(3)) + '</td>'
            + '<td class=num>' + sum(4) + '</td><td class=num>' + sum(5) + '</td><td class=num>' + sum(6) + '</td>'
            + '<td class=num>' + sum(7) + '</td><td class=num>' + sum(8) + '</td><td></td><td></td></tr>';
    }
    h += '</tbody></table><div class="muted" style="margin-top:10px;font-size:11px">Click a row to browse that database. Click a column header to sort by it.</div>';
    ov.innerHTML = h;

    if (hadFocus) {
        const newFilterEl = $('overviewFilter');
        if (newFilterEl) {
            newFilterEl.focus();
            if (cursorPos != null) newFilterEl.setSelectionRange(cursorPos, cursorPos);
        }
    }

    [...ov.querySelectorAll('tr[data-db]')].forEach(tr => {
        tr.onclick = () => {
            const db = tr.getAttribute('data-db');
            const box = $('schemas');
            [...box.children].forEach(c => {
                if (c.textContent.includes(db)) c.classList.add('sel');
                else c.classList.remove('sel');
            });
            curSchema = db;
            $('objdb').textContent = db;
            $('objdb').title = db;
            loadObjects(db);
        };
    });
}

// Function to clear the Overview cache
function clearOverviewCache() {
    // Clear ALL cached overview + table-size data (every connection), then reload the current view.
    const n = _clearKeys(false);
    if (!document.body.classList.contains('disconnected')) {
        loadSchemas(); // refresh the sidebar schema sizes (KB numbers)
        if (typeof curSchema !== 'undefined' && curSchema) {
            loadObjects(curSchema); // refresh the objects list + its table sizes
        }
    }
    if (tabs.length === 0 && !document.body.classList.contains('disconnected')) {
        showOverview(); // reload the overview panel if it is what is visible
    }
    log('Cache refreshed (' + n + ' cached entr' + (n === 1 ? 'y' : 'ies') + ' cleared).');
}
function toggleOverview() {
    const ov = $('overview');
    if (!ov) return;

    // Skip if disconnected (Option 3)
    if (document.body.classList.contains('disconnected')) {
        ov.style.display = 'none';
        return;
    }

    if (tabs.length === 0) {
        ov.innerHTML = `
            <div style="padding: 14px; text-align: center;">
                <div class="muted" style="margin-bottom: 10px;">Database Overview</div>
                <button class="primary" onclick="showOverview()">Load Overview</button>
            </div>
        `;
        ov.style.display = 'block';
    } else {
        ov.style.display = 'none';
    }
}
function objOpen(db,type,name){if(type==='table'){const _id=openTab(name,'SELECT * FROM '+qid(db)+'.'+qid(name)+' LIMIT 1000;',db,false,name);openRun(_id);}else if(type==='view'){openTab(name,'SELECT * FROM '+qid(db)+'.'+qid(name)+' LIMIT 1000;',db,true,null);}else{openDdl(db,type,name);}}
function objMenu(e,db,type,name){const b=[];
 if(type==='table'){const isPinned=pinnedTables(db).includes(name);b.push([isPinned?'\u2605 Unpin':'\u2606 Pin to top',()=>togglePin(db,name)]);b.push(['SELECT *',()=>{const _i=openTab(name,'SELECT * FROM '+qid(db)+'.'+qid(name)+' LIMIT 1000;',db,false,name);openRun(_i);}]);b.push(['SELECT COUNT(*)',()=>openTab('count '+name,'SELECT COUNT(*) FROM '+qid(db)+'.'+qid(name)+';',db,true,null)]);b.push(['Generate SELECT/INSERT/UPDATE...',()=>genTemplate(db,name)]);
  b.push(['Design / Alter...',()=>designTable(name,db)]);b.push(['Show CREATE',()=>openDdl(db,type,name)]);
  const _trigMap=(objData&&objData.r&&objData.r.triggerTables)||{};const _existingTriggers=Object.keys(_trigMap).filter(tn=>_trigMap[tn]===name);
  if(_existingTriggers.length){b.push(['Existing triggers ('+_existingTriggers.length+')',_existingTriggers.map(tn=>[tn,()=>openDdl(db,'trigger',tn)])]);}
  b.push(['New trigger on this table...',()=>newTrigger(db,name)]);b.push(['Inspect...',()=>inspect(db,name)]);b.push(['Import CSV into table...',()=>importCsv(db,name)]);b.push(['Export table to CSV (all rows)...',()=>exportFull(db,name,'csv')]);b.push(['Export table INSERTs (all rows)...',()=>exportFull(db,name,'inserts')]);b.push('-');
  b.push(['Rename...',()=>renameTable(db,name)]);b.push(['Duplicate table...',()=>duplicateTable(db,name)]);b.push(['Truncate...',()=>truncateTable(db,name)]);b.push(['Drop table...',()=>dropObject(db,type,name)]);b.push('-');
  b.push(['Optimize',()=>maint(db,name,'OPTIMIZE')]);b.push(['Analyze',()=>maint(db,name,'ANALYZE')]);b.push(['Check',()=>maint(db,name,'CHECK')]);b.push(['Repair',()=>maint(db,name,'REPAIR')]);}
 else if(type==='view'){b.push(['Open',()=>openTab(name,'SELECT * FROM '+qid(db)+'.'+qid(name)+' LIMIT 1000;',db,true,null)]);b.push(['Show CREATE / edit',()=>openDdl(db,type,name)]);b.push(['Drop view...',()=>dropObject(db,type,name)]);}
 else {b.push(['Show CREATE / edit',()=>openDdl(db,type,name)]);b.push(['Drop '+type+'...',()=>dropObject(db,type,name)]);}
 menu(e.clientX,e.clientY,b);}

async function exec(sql,note,btn){if(roBlock())return false;
 let orig=null;if(btn){orig=btn.textContent;btn.disabled=true;btn.textContent='Working...';}
 const r=await api('/api/exec',{sql});
 if(btn){btn.disabled=false;btn.textContent=orig;}
 if(r.ok){log((note||'OK')+': '+sql);}else{log('ERROR: '+r.error);toast(r.error,true);}return r.ok;}
async function newSchema(){const res=await inputBox({title:'New schema',okText:'Create',fields:[{key:'name',label:'Schema name'}]});if(!res||!res.name.trim())return;if(await exec('CREATE DATABASE '+qid(res.name.trim()),'Created schema'))loadSchemas();}
// Reuse the SAME DELIMITER-wrapped scaffold openDdl() already uses for EDITING an existing
// procedure/function/trigger - applyDdl() sends it through /api/script, which both PS and Tauri
// deliberately implement by shelling out to the real mysql/mariadb CLI (not the native driver),
// specifically because DELIMITER is a CLIENT-side directive the CLI understands and a raw wire
// protocol call does not. New objects reuse this same proven, already-DELIMITER-safe path.
async function newProcedure(db){
 const res=await inputBox({title:'New procedure',okText:'Create',fields:[{key:'name',label:'Procedure name'}]});
 if(!res||!res.name.trim())return;
 const name=res.name.trim();if(!(await ddlConfirmNew(db,'procedure',name)))return;
 const body=window.mariadb
  ?('-- Fill in the procedure body, then click "Apply (recreate)".\nDELIMITER $$\nCREATE OR REPLACE PROCEDURE '+qid(db)+'.'+qid(name)+'()\nBEGIN\n\n  -- your logic here\n\nEND$$\nDELIMITER ;\n')
  :('-- Fill in the procedure body, then click "Apply (recreate)".\nDROP PROCEDURE IF EXISTS '+qid(db)+'.'+qid(name)+';\nDELIMITER $$\nCREATE PROCEDURE '+qid(db)+'.'+qid(name)+'()\nBEGIN\n\n  -- your logic here\n\nEND$$\nDELIMITER ;\n');
 openTab('procedure: '+name,body,db,false,null,{type:'procedure',db,name});
}
async function newFunction(db){
 const res=await inputBox({title:'New function',okText:'Create',fields:[{key:'name',label:'Function name'},{key:'returns',label:'Return type',value:'INT'}]});
 if(!res||!res.name.trim())return;
 const name=res.name.trim();if(!(await ddlConfirmNew(db,'function',name)))return;const rt=(res.returns||'INT').trim()||'INT';
 const body=window.mariadb
  ?('-- Fill in the function body, then click "Apply (recreate)".\nDELIMITER $$\nCREATE OR REPLACE FUNCTION '+qid(db)+'.'+qid(name)+'() RETURNS '+rt+'\nDETERMINISTIC\nBEGIN\n\n  -- your logic here\n  RETURN NULL;\n\nEND$$\nDELIMITER ;\n')
  :('-- Fill in the function body, then click "Apply (recreate)".\nDROP FUNCTION IF EXISTS '+qid(db)+'.'+qid(name)+';\nDELIMITER $$\nCREATE FUNCTION '+qid(db)+'.'+qid(name)+'() RETURNS '+rt+'\nDETERMINISTIC\nBEGIN\n\n  -- your logic here\n  RETURN NULL;\n\nEND$$\nDELIMITER ;\n');
 openTab('function: '+name,body,db,false,null,{type:'function',db,name});
}
async function newTrigger(db,table){
 const res=await inputBox({title:'New trigger on '+table,okText:'Create',fields:[
  {key:'name',label:'Trigger name',value:table+'_trigger'},
  {key:'timing',label:'Timing',type:'select',options:['BEFORE','AFTER'],value:'BEFORE'},
  {key:'event',label:'Event',type:'select',options:['INSERT','UPDATE','DELETE'],value:'INSERT'}
 ]});
 if(!res||!res.name.trim())return;
 const name=res.name.trim();if(!(await ddlConfirmNew(db,'trigger',name)))return;
 const body=window.mariadb
  ?('-- Fill in the trigger body, then click "Apply (recreate)".\nDELIMITER $$\nCREATE OR REPLACE TRIGGER '+qid(db)+'.'+qid(name)+'\n'+res.timing+' '+res.event+' ON '+qid(db)+'.'+qid(table)+'\nFOR EACH ROW\nBEGIN\n\n  -- your logic here\n\nEND$$\nDELIMITER ;\n')
  :('-- Fill in the trigger body, then click "Apply (recreate)".\nDROP TRIGGER IF EXISTS '+qid(db)+'.'+qid(name)+';\nDELIMITER $$\nCREATE TRIGGER '+qid(db)+'.'+qid(name)+'\n'+res.timing+' '+res.event+' ON '+qid(db)+'.'+qid(table)+'\nFOR EACH ROW\nBEGIN\n\n  -- your logic here\n\nEND$$\nDELIMITER ;\n');
 openTab('trigger: '+name,body,db,false,null,{type:'trigger',db,name});
}
async function dropSchema(db){if(!(await ask('DROP DATABASE '+db+' ? Deletes ALL its data.')))return;if(await exec('DROP DATABASE '+qid(db),'Dropped schema')){[...tabs].forEach(t=>{if(t.db===db&&t.table)closeTab(t.id);});loadSchemas();$('objects').innerHTML='';}}
async function dropObject(db,type,name){const kw={table:'TABLE',view:'VIEW',procedure:'PROCEDURE',function:'FUNCTION',trigger:'TRIGGER',event:'EVENT'}[type];if(!(await ask('DROP '+kw+' '+db+'.'+name+'?\n\nThis permanently removes the '+type+' and cannot be undone.')))return;if(await exec('DROP '+kw+' IF EXISTS '+qid(db)+'.'+qid(name),'Dropped '+type+' '+db+'.'+name)){[...tabs].forEach(t=>{if(t.db===db&&t.table===name)closeTab(t.id);});loadObjects(db);}}
async function truncateTable(db,name){if(!(await ask('TRUNCATE TABLE '+db+'.'+name+'?\n\nThis permanently deletes ALL rows and cannot be undone.')))return;if(await exec('TRUNCATE TABLE '+qid(db)+'.'+qid(name),'Truncated '+db+'.'+name)){invalidateTableCache(db,name);[...tabs].forEach(t=>{if(t.table===name&&t.db===db)openRun(t.id);});}}
async function renameTable(db,name){const res=await inputBox({title:'Rename table',okText:'Rename',fields:[{key:'name',label:'New table name',value:name}]});if(!res||!res.name.trim()||res.name.trim()===name)return;if(await exec('RENAME TABLE '+qid(db)+'.'+qid(name)+' TO '+qid(db)+'.'+qid(res.name.trim()),'Renamed')){[...tabs].forEach(t=>{if(t.db===db&&t.table===name)closeTab(t.id);});loadObjects(db);}}
async function duplicateTable(db,name){
 const res=await inputBox({title:'Duplicate table',okText:'Create',fields:[
  {key:'name',label:'New table name',value:name+'_copy'},
  {key:'data',label:'Copy data too',type:'checkbox',value:true}
 ]});
 if(!res||!res.name.trim())return;
 const newName=res.name.trim();
 if(roBlock())return;
 let sql='CREATE TABLE '+qid(db)+'.'+qid(newName)+' LIKE '+qid(db)+'.'+qid(name)+';';
 if(res.data){
  // Named columns: SELECT * left invisible columns NULL in the copy, and a generated column in it
  // made the copy fail - after the empty table had already been created.
  const info=await tableColumnsInfo(db,name);
  if(!info){toast('Could not read the columns of '+db+'.'+name+'. Nothing was created.',true);return;}
  const cl=info.filter(c=>!c.generated).map(c=>qid(c.name)).join(',');
  sql+='\nINSERT INTO '+qid(db)+'.'+qid(newName)+' ('+cl+') SELECT '+cl+' FROM '+qid(db)+'.'+qid(name)+';';
 }
 const r=await api('/api/script',{sql,db});
 if(r.ok){log('Duplicated '+name+' as '+newName+(res.data?' (with data)':' (structure only)')+'.');loadObjects(db);}
 else{toast(r.error||'Duplicate failed',true);}
}
async function maint(db,name,op){const kw=op==='OPTIMIZE'?'OPTIMIZE TABLE':op==='ANALYZE'?'ANALYZE TABLE':op==='CHECK'?'CHECK TABLE':'REPAIR TABLE';const r=await api('/api/query',{sql:kw+' '+qid(db)+'.'+qid(name)});if(r.ok&&r.rows&&r.rows.length){log(op+': '+r.rows.map(x=>x.join(' | ')).join(' ; '));}else if(r.ok){log(op+' OK');}else{log(op+' error: '+r.error);}}
async function genTemplate(db,name){const r=await api('/api/query',{sql:"SELECT COLUMN_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA="+lit(db)+" AND TABLE_NAME="+lit(name)+" ORDER BY ORDINAL_POSITION"});if(!r.ok||!r.rows.length){toast('Could not read columns.',true);return;}const cols=r.rows.map(x=>x[0]);const tbl=qid(db)+'.'+qid(name);const cl=cols.map(qid).join(', ');const vals=cols.map(()=>'?').join(', ');const sets=cols.map(c=>qid(c)+' = ?').join(',\n  ');const sql='-- SELECT\nSELECT '+cl+'\nFROM '+tbl+'\nWHERE 1=1\nLIMIT 100;\n\n-- INSERT\nINSERT INTO '+tbl+' ('+cl+')\nVALUES ('+vals+');\n\n-- UPDATE\nUPDATE '+tbl+' SET\n  '+sets+'\nWHERE /* key */ ;';openTab(name+' templates',sql,db,false,null);}
async function inspect(db,name){const q=await api('/api/query',{sql:"SELECT ENGINE,TABLE_ROWS,DATA_LENGTH,INDEX_LENGTH,TABLE_COLLATION,CREATE_TIME,UPDATE_TIME FROM information_schema.TABLES WHERE TABLE_SCHEMA="+lit(db)+" AND TABLE_NAME="+lit(name)});
 let t='';if(q.ok&&q.rows.length){const r=q.rows[0];t='Engine: '+r[0]+'\nApprox rows: '+r[1]+'\nData size: '+fmtB(r[2])+'\nIndex size: '+fmtB(r[3])+'\nCollation: '+r[4]+'\nCreated: '+r[5]+'\nUpdated: '+r[6];}
 const idx=await api('/api/query',{sql:'SHOW INDEX FROM '+qid(db)+'.'+qid(name)});if(idx.ok&&idx.rows.length){t+='\n\nIndexes:\n'+idx.rows.map(r=>' '+r[2]+' ('+r[4]+')'+(r[1]=='0'?' UNIQUE':'')).join('\n');}
 const fks=await api('/api/query',{sql:"SELECT CONSTRAINT_NAME,COLUMN_NAME,REFERENCED_TABLE_NAME,REFERENCED_COLUMN_NAME FROM information_schema.KEY_COLUMN_USAGE WHERE TABLE_SCHEMA="+lit(db)+" AND TABLE_NAME="+lit(name)+" AND REFERENCED_TABLE_NAME IS NOT NULL ORDER BY CONSTRAINT_NAME"});if(fks.ok&&fks.rows.length){t+='\n\nForeign keys:\n'+fks.rows.map(r=>' '+r[1]+' -> '+r[2]+'.'+r[3]).join('\n');}
 const ref=await api('/api/query',{sql:"SELECT TABLE_NAME,COLUMN_NAME FROM information_schema.KEY_COLUMN_USAGE WHERE REFERENCED_TABLE_SCHEMA="+lit(db)+" AND REFERENCED_TABLE_NAME="+lit(name)+" ORDER BY TABLE_NAME"});if(ref.ok&&ref.rows.length){t+='\n\nReferenced by:\n'+ref.rows.map(r=>' '+r[0]+'.'+r[1]).join('\n');}
 viewText('Table '+db+'.'+name,t,{readonly:true});}
function fmtB(n){n=+n||0;return n>1048576?(n/1048576).toFixed(1)+' MB':n>1024?(n/1024).toFixed(1)+' KB':n+' B';}

// ---- DDL ----
async function openDdl(db,type,name){const r=await api('/api/ddl',{db,type,name});if(!r.ok){log('DDL error: '+r.error);toast(r.error,true);return;}
 let body=r.ddl;
 if(type==='procedure'||type==='function'||type==='trigger'){const kw={procedure:'PROCEDURE',function:'FUNCTION',trigger:'TRIGGER'}[type];
  if(window.mariadb){
   // MariaDB: CREATE OR REPLACE is atomic - no window where the routine is missing, and no separate DROP.
   body='-- Edit then "Apply (recreate)". (MariaDB CREATE OR REPLACE - atomic)\nDELIMITER $$\n'+body.replace(/^CREATE/i,'CREATE OR REPLACE')+'$$\nDELIMITER ;\n';
  } else {
   // MySQL has no CREATE OR REPLACE for routines/triggers, so drop then create.
   body='-- Edit then "Apply (recreate)".\nDROP '+kw+' IF EXISTS '+qid(db)+'.'+qid(name)+';\nDELIMITER $$\n'+body+'$$\nDELIMITER ;\n';
  }}
 else if(type==='view'){body='-- Edit then "Apply (recreate)".\n'+body.replace(/^CREATE/i,'CREATE OR REPLACE')+';\n';}
 openTab(type+': '+name,body,db,false,null,{type,db,name,orig:r.ddl});}

// ---- tabs & editor ----
// --- Query tabs: each tab has its own editor + result grid + pending edits.
function openTab(title,sql,db,run,table,ddl){const id='t'+(++tabSeq);title=uniqueTabTitle(title||'Query');const tab={id,title,db:db||null,table:table||null,ddl:ddl||null,genSql:sql||'',sqlEdited:false,pk:null,cols:null,rows:null,limit:1000,offset:0,pending:null,filter:null,hiddenCols:new Set()};
 tabs.push(tab);
 const tb=document.createElement('div');tb.className='tab';tb.id='tabbtn_'+id;tb.draggable=true;tb.innerHTML='<span class="tablabel">'+esc(tab.title)+'</span><span class="x">&times;</span>';
 tb.onclick=()=>activate(id);tb.querySelector('.x').onclick=e=>{e.stopPropagation();closeTabAsk(id);};tb.oncontextmenu=e=>{e.preventDefault();menu(e.clientX,e.clientY,[['Close',()=>closeTabAsk(id)],['Close others',()=>closeOthers(id)],['Close all',()=>closeAll()]]);};
 tb.addEventListener('dragstart',e=>{e.dataTransfer.effectAllowed='move';e.dataTransfer.setData('text/plain',id);tb.classList.add('dragging');});
 tb.addEventListener('dragend',()=>{tb.classList.remove('dragging');});
 tb.addEventListener('dragover',e=>{e.preventDefault();e.dataTransfer.dropEffect='move';tb.classList.add('dragover');});
 tb.addEventListener('dragleave',()=>{tb.classList.remove('dragover');});
 tb.addEventListener('drop',e=>{e.preventDefault();tb.classList.remove('dragover');const srcId=e.dataTransfer.getData('text/plain');if(!srcId||srcId===id)return;reorderTab(srcId,id);});
 $('tabsbar').appendChild(tb);saveSession();
 const pane=document.createElement('div');pane.className='tabpane';pane.id='pane_'+id;
 const applyBtn=tab.ddl?'<button class="go write" onclick="applyDdl(\''+id+'\')">Apply (recreate)</button>':'';const lastBtn=tab.ddl?'':'<button title="Toggle between the current query and the last one you ran" onclick="toggleLast(\''+id+'\')">\u21C4 Last query</button>';const selBtn='<span id="selbtn_'+id+'">'+selBtnHtml(id,tab.table)+'</span>';
 const pager='<span class="tbsep"></span><span id="pager_'+id+'" style="display:inline-flex;align-items:center;gap:6px"></span>';
 pane.innerHTML='<div class="edwrap" id="ew_'+id+'"><pre class="hl" id="hl_'+id+'"></pre><textarea class="editor" id="ed_'+id+'" spellcheck="false"></textarea></div>'+
  '<div class="edsplit" id="es_'+id+'" title="Drag to resize the editor"></div>'+
  // Run Query and Cancel are mutually-exclusive states of the same "primary action" slot, not
  // two independent buttons - stacked in one shared grid cell (both always in layout, only one
  // ever visible) so swapping between them on every run/cancel never shifts Run Query Selection/
  // Explain/Format, which display:none toggling used to do on every single query execution.
  '<div class="toolbar"><span style="display:inline-grid"><button class="primary" id="runbtn_'+id+'" style="grid-area:1/1" title="Run the query (F5)" onclick="runTab(\''+id+'\')">Run Query</button><button class="warn" id="cancelbtn_'+id+'" style="grid-area:1/1;visibility:hidden" title="Cancel the running query" onclick="cancelQuery(\''+id+'\')">Cancel</button></span><button title="Run the selected text (Ctrl+Enter) - or, if nothing is selected, whichever statement the cursor is currently inside" onclick="runSel(\''+id+'\')">Run Query Selection</button><button title="Prepend EXPLAIN to the current statement and run it" onclick="explainTab(\''+id+'\')">Explain</button><button title="Reformat the query for readability (safe - only changes whitespace/line breaks, never the query itself)" onclick="formatTabSql(\''+id+'\')">Format</button>'+
  '<span class="tbsep"></span>'+
  lastBtn+selBtn+applyBtn+
  '<label title="If a statement fails, keep running the rest of the script instead of stopping at the first error - useful for bulk, mostly-independent statements like seed data or batch table creation. Every failure is reported, not just the first. Only applies to a script that does NOT end in a SELECT." style="display:inline-flex;align-items:center;gap:5px;margin-left:10px;font-size:12px;color:var(--muted)"><input type="checkbox" id="coe_'+id+'"> Continue on error</label>'+
  '<span class="tbsep"></span>'+
  '<span id="resultActions_'+id+'" style="display:none;gap:9px;align-items:center" class="tbgroup">'+
  '<button title="Copy the grid to the clipboard, as CSV or Markdown, all rows or just the selected (checked) ones (binary/control-character values are copied as 0x... hex text, not the literal bytes)" onclick="event.stopPropagation();toggleCopyMenu(\''+id+'\',this)">Copy \u25BE</button>'+'<button class="sm" id="wrapbtn_'+id+'" title="Toggle text wrapping in the grid" onclick="toggleWrap(\''+id+'\')">Wrap: Off</button>'+'<button class="sm" id="colsbtn_'+id+'" title="Show or hide columns" onclick="event.stopPropagation();toggleColPicker(\''+id+'\',this)">Columns</button>'+
  '<span class="tbsep"></span></span>'+
  '<span style="flex:1 1 auto"></span>'+
  '<span id="edit_'+id+'" style="display:inline-flex;align-items:center;gap:6px"></span>'+pager+'</div>'+
  '<div id="rsets_'+id+'" style="display:none;gap:6px;align-items:center;flex-wrap:wrap;padding:4px 8px"></div><div class="result" id="res_'+id+'"></div><div class="status" id="st_'+id+'">Ready.</div>';
 $('panes').appendChild(pane);const ta=$('ed_'+id);ta.value=sql||'';
 const ra1=$('resultActions_'+id);if(ra1)ra1.style.display='none';
 (function(){const es=$('es_'+id),ew=$('ew_'+id);es.addEventListener('mousedown',e=>{e.preventDefault();const sy=e.clientY,sh=ew.offsetHeight,maxH=ew.parentElement.clientHeight-120;
  const mv=ev=>{let h=sh+(ev.clientY-sy);h=Math.max(44,Math.min(h,Math.max(80,maxH)));ew.style.height=h+'px';syncHl(id);};
  const up=()=>{document.removeEventListener('mousemove',mv);document.removeEventListener('mouseup',up);document.body.style.userSelect='';};
  document.body.style.userSelect='none';document.addEventListener('mousemove',mv);document.addEventListener('mouseup',up);});})();
 ta.addEventListener('input',()=>{syncHl(id);acUpdate(id);markEdited(id);});ta.addEventListener('scroll',()=>{syncHl(id);acHide();});
 ta.addEventListener('blur',()=>{setTimeout(acHide,150);saveSession();});
 ta.addEventListener('keydown',e=>{
  if(acVisible()){
   // Guarded with !e.altKey so Alt+Up/Down (move line) still reaches its own handler below even
   // while the autocomplete popup happens to be open, rather than being silently swallowed here
   // as autocomplete-list navigation instead.
   if(e.key==='ArrowDown'&&!e.altKey){e.preventDefault();acMove(1);return;}
   if(e.key==='ArrowUp'&&!e.altKey){e.preventDefault();acMove(-1);return;}
   if(e.key==='Enter'||e.key==='Tab'){e.preventDefault();acAccept(id);return;}
   if(e.key==='Escape'){e.preventDefault();acHide();return;}
  }
  if(e.key==='F5'){e.preventDefault();runTab(id);}
  else if(e.ctrlKey&&e.key==='Enter'){e.preventDefault();runSel(id);}
  else if(e.ctrlKey&&e.code==='Space'){e.preventDefault();acUpdate(id,true);}
  else if(e.ctrlKey&&!e.shiftKey&&!e.altKey&&e.key.toLowerCase()==='d'){
   // Duplicate the current line (or every line touched by the selection) directly below,
   // matching Ctrl+D in VS Code/Sublime - operates on whole lines, not just the selected text,
   // and the cursor lands at the same relative column on the newly-duplicated line.
   e.preventDefault();
   const val=ta.value,selStart=ta.selectionStart,selEnd=ta.selectionEnd;
   let lineStart=val.lastIndexOf('\n',selStart-1)+1;
   let lineEnd=val.indexOf('\n',selEnd);
   if(lineEnd<0)lineEnd=val.length;
   const block=val.slice(lineStart,lineEnd);
   ta.value=val.slice(0,lineEnd)+'\n'+block+val.slice(lineEnd);
   const newLineStart=lineEnd+1;
   ta.selectionStart=newLineStart+(selStart-lineStart);
   ta.selectionEnd=newLineStart+(selEnd-lineStart);
   syncHl(id);
  }
  else if(e.ctrlKey&&e.key==='/'){
   // Deliberately does NOT exclude Shift here: KeyboardEvent.key reports the character actually
   // produced, not the physical key pressed, and on many keyboard layouts producing "/" genuinely
   // requires holding Shift. On a layout where Shift+/ produces a DIFFERENT character (like "?"
   // on US QWERTY), this condition simply never matches in that case anyway, since e.key would
   // report "?" instead - so there's nothing to exclude, and doing so only breaks the shortcut
   // on layouts that need Shift to type "/" at all.
   // Toggle "-- " line comments on the current line, or every line the selection touches -
   // matches Ctrl+/ in VS Code. If any touched line isn't yet commented, comments them all
   // (even ones already commented, same as VS Code's own convention); only uncomments when
   // EVERY non-blank touched line already starts with "-- ". Blank lines are left alone either
   // way. The comment marker is inserted right after each line's own leading whitespace, so
   // indentation is preserved rather than being pushed out to column 0.
   e.preventDefault();
   const val=ta.value,selStart=ta.selectionStart,selEnd=ta.selectionEnd;
   let lineStart=val.lastIndexOf('\n',selStart-1)+1;
   let lineEnd=val.indexOf('\n',selEnd);
   if(lineEnd<0)lineEnd=val.length;
   const lines=val.slice(lineStart,lineEnd).split('\n');
   const nonBlank=lines.filter(l=>l.trim()!=='');
   const allCommented=nonBlank.length>0&&nonBlank.every(l=>l.trimStart().startsWith('-- '));
   const newLines=allCommented
    ?lines.map(l=>l.trim()===''?l:l.replace(/^(\s*)-- ?/,'$1'))
    :lines.map(l=>l.trim()===''?l:l.replace(/^(\s*)/,'$1-- '));
   const newBlock=newLines.join('\n');
   ta.value=val.slice(0,lineStart)+newBlock+val.slice(lineEnd);
   ta.selectionStart=lineStart;ta.selectionEnd=lineStart+newBlock.length;
   syncHl(id);
  }
  else if(e.altKey&&(e.key==='ArrowUp'||e.key==='ArrowDown')){
   // Move the current line (or every line the selection touches) up or down by one line,
   // swapping places with its neighbor - matches Alt+Up/Down in VS Code. Does nothing at the
   // very top (for Up) or very bottom (for Down) rather than wrapping around.
   e.preventDefault();
   const dir=e.key==='ArrowUp'?-1:1;
   const val=ta.value,selStart=ta.selectionStart,selEnd=ta.selectionEnd;
   let lineStart=val.lastIndexOf('\n',selStart-1)+1;
   let lineEnd=val.indexOf('\n',selEnd);
   if(lineEnd<0)lineEnd=val.length;
   const block=val.slice(lineStart,lineEnd);
   if(dir<0&&lineStart>0){
    const prevLineStart=val.lastIndexOf('\n',lineStart-2)+1;
    const prevLine=val.slice(prevLineStart,lineStart-1);
    ta.value=val.slice(0,prevLineStart)+block+'\n'+prevLine+val.slice(lineEnd);
    ta.selectionStart=prevLineStart+(selStart-lineStart);ta.selectionEnd=prevLineStart+(selEnd-lineStart);
    syncHl(id);
   } else if(dir>0&&lineEnd<val.length){
    let nextLineEnd=val.indexOf('\n',lineEnd+1);
    if(nextLineEnd<0)nextLineEnd=val.length;
    const nextLine=val.slice(lineEnd+1,nextLineEnd);
    ta.value=val.slice(0,lineStart)+nextLine+'\n'+block+val.slice(nextLineEnd);
    const newBlockStart=lineStart+nextLine.length+1;
    ta.selectionStart=newBlockStart+(selStart-lineStart);ta.selectionEnd=newBlockStart+(selEnd-lineStart);
    syncHl(id);
   }
  }
  else if(e.ctrlKey&&e.shiftKey&&e.key.toLowerCase()==='k'){
   // Delete the current line (or every line the selection touches) entirely, including its
   // own line break - matches Ctrl+Shift+K in VS Code.
   e.preventDefault();
   const val=ta.value,selStart=ta.selectionStart,selEnd=ta.selectionEnd;
   let lineStart=val.lastIndexOf('\n',selStart-1)+1;
   let lineEnd=val.indexOf('\n',selEnd);
   let deleteEnd;
   if(lineEnd<0){deleteEnd=val.length;if(lineStart>0)lineStart=lineStart-1;}
   else{deleteEnd=lineEnd+1;}
   ta.value=val.slice(0,lineStart)+val.slice(deleteEnd);
   ta.selectionStart=ta.selectionEnd=Math.min(lineStart,ta.value.length);
   syncHl(id);
  }
  else if(e.key==='Tab'){e.preventDefault();const st=ta.selectionStart;ta.value=ta.value.slice(0,st)+'  '+ta.value.slice(ta.selectionEnd);ta.selectionStart=ta.selectionEnd=st+2;syncHl(id);}
 });
 syncHl(id);activate(id);if(run)runTab(id);return id;}
function activate(id){activeTab=id;const _ov=$('overview');if(_ov)_ov.style.display='none';tabs.forEach(t=>{$('tabbtn_'+t.id).classList.toggle('active',t.id===id);$('pane_'+t.id).classList.toggle('active',t.id===id);});const ta=$('ed_'+id);if(ta)setTimeout(()=>ta.focus(),0);updateSchemaBadge(id);const _t=T(id);if(_t&&_t.cols&&_t.cols.length&&!_t.colsFitted){requestAnimationFrame(()=>autofitAll(id));}}
function updateSchemaBadge(id){const el=$('schemaBadge');if(!el)return;if(document.body.classList.contains('disconnected')){el.style.display='none';el.textContent='';return;}const t=T(id);const db=t?dbOf(t):null;el.textContent=db?('Schema: '+db):'';el.title=el.textContent;el.style.display=db?'inline-flex':'none';}
function pendingCount(t){if(!t||!t.pending)return 0;return Object.keys(t.pending.upd||{}).length+((t.pending.del&&t.pending.del.size)||0)+((t.pending.ins&&t.pending.ins.length)||0);}
function uniqueTabTitle(base){
  let title=base, n=2;
  while(tabs.some(t=>t.title===title)){ title=base+' ('+n+')'; n++; }
  return title;
}
function refreshTabDirty(id){const t=T(id);const tb=$('tabbtn_'+id);if(!tb)return;const lbl=tb.querySelector('.tablabel');if(!lbl)return;
 const n=pendingCount(t);lbl.textContent=(n>0?'\u25CF ':'')+(t?t.title:'');lbl.title=n>0?(n+' unsaved change'+(n===1?'':'s')):'';}
async function closeTabAsk(id){const t=T(id);const n=pendingCount(t);if(n>0){if(!(await ask('This tab has '+n+' unsaved change'+(n===1?'':'s')+'. Close and discard?')))return;}closeTab(id);}
function reorderTab(srcId,targetId){
  const srcIdx=tabs.findIndex(t=>t.id===srcId),tgtIdx=tabs.findIndex(t=>t.id===targetId);
  if(srcIdx<0||tgtIdx<0)return;
  const [moved]=tabs.splice(srcIdx,1);
  tabs.splice(tgtIdx,0,moved);
  const srcEl=$('tabbtn_'+srcId),tgtEl=$('tabbtn_'+targetId);
  if(srcEl&&tgtEl){
    if(srcIdx<tgtIdx) tgtEl.after(srcEl);
    else tgtEl.before(srcEl);
  }
  saveSession();
}
function anyPending(){return tabs.some(t=>pendingCount(t)>0);}
document.addEventListener('keydown',e=>{const mod=e.ctrlKey||e.metaKey;if(!mod)return;const k=e.key.toLowerCase();
 if(k==='t'){e.preventDefault();if(!document.body.classList.contains('disconnected'))newTab();}
 else if(k==='w'){e.preventDefault();if(activeTab)closeTabAsk(activeTab);}
 else if(k==='l'){e.preventDefault();const ta=activeTab&&$('ed_'+activeTab);if(ta){ta.focus();ta.select&&ta.select();}}
 else if(k==='s'){e.preventDefault();if(activeTab){const t=T(activeTab);if(pendingCount(t)>0)applyChanges(activeTab);}}});
// Skip minimized floating modals when picking which one Escape should close - a minimized modal
// isn't visually present, so silently closing it (with no visible change on screen) would be
// confusing. Going through hide() here, rather than manipulating the class directly, also
// matters for any OTHER open floating modal that happens to be minimized at the time: it ensures
// whichever modal Escape does close gets its own minimize-tracking and tray chip cleaned up
// correctly, instead of the same kind of stale, non-functional leftover state browse() could
// previously cause.
// A handful of modals need more than a plain hide() to close cleanly - e.g. Compare Databases
// (mCompare) has to stop a running row-diff scan first, same as its own Close button does, or
// the scan keeps going in the background against a now-hidden dialog. Escape used to call hide()
// directly and skip all of that, so it behaved differently from clicking Close on the exact same
// window - this map lets Escape reuse each modal's own close function where one exists.
const MODAL_CLOSE_OVERRIDES={mCompare:cmpCloseAndCancel,mCompareRows:cmprCloseAndCancel,mBrowse:brClose,mInput:inpCancel};
// Shared by the Escape handler below AND the minimized-window tray's own x (floatRenderTray) -
// both are ways to close a modal that DON'T go through its own Close button, so both need the
// same override lookup. Missing this on the tray's x specifically would have been a real
// regression from making Compare Databases minimizable: minimize it mid-scan, then close it from
// the tray, and a plain hide() would leave the scan running in the background uncancelled -
// exactly the bug Escape already had before this existed.
function modalClose(id){const fn=MODAL_CLOSE_OVERRIDES[id];if(fn)fn();else hide(id);}
document.addEventListener('keydown',e=>{if(e.key==='Escape'){const open=[...document.querySelectorAll('.modal.show')].filter(m=>!window._floatingMinimized[m.id]);if(open.length){modalClose(open[open.length-1].id);}}});
function closeTab(id){const t=T(id);if(t&&t.runningReqId){cancelQuery(id);}closeCursorFor(t);const i=tabs.findIndex(t=>t.id===id);if(i<0)return;tabs.splice(i,1);$('tabbtn_'+id).remove();$('pane_'+id).remove();if(activeTab===id&&tabs.length)activate(tabs[tabs.length-1].id);if(tabs.length===0){activeTab=null;}saveSession();toggleOverview();}
// Each saved connection remembers its own open tabs (keyed by connection name; ad-hoc/unsaved
// connections are keyed by host+user+port so different credentials don't collide).
function sessionKeyFor(){const cn=$('connlist')?$('connlist').value:'';if(cn)return 'conn:'+cn;return 'adhoc:'+($('user')?$('user').value:'')+'@'+($('host')?$('host').value:'')+':'+($('port')?$('port').value:'');}
function saveSession(key){try{const k=key||sessionKeyFor();const arr=tabs.map(t=>({title:t.title,sql:($('ed_'+t.id)?$('ed_'+t.id).value:''),db:t.db,table:t.table}));localStorage.setItem('session:'+k,JSON.stringify(arr));}catch(e){}}
function restoreSessionFor(key){if(tabs.length)return;let arr=[];try{const raw=localStorage.getItem('session:'+key);if(raw!=null){arr=JSON.parse(raw);}else if(!localStorage.getItem('_sessionMigrated')){const old=localStorage.getItem('session');if(old)arr=JSON.parse(old);localStorage.setItem('_sessionMigrated','1');}}catch(e){}if(Array.isArray(arr)&&arr.length){arr.forEach(t=>{
  // Table tabs are always bounded (LIMIT 1000), so it's safe to auto-run them on restore -
  // otherwise the tab looks silently empty even though the table has data (never actually queried).
  // Plain query tabs could be arbitrary/heavy, so those restore WITHOUT auto-running; a clear
  // status message replaces what would otherwise look like a blank, broken result.
  const id=openTab(t.title,t.sql,t.db,!!t.table,t.table);
  if(!t.table){const st=$('st_'+id);if(st)st.textContent='Restored - not yet run. Click Run Query.';}
});}}
// Closes every tab without the "unsaved changes" prompt - only called right after the user has
// already confirmed switching connections (connect() asks that separately, once, up front).
function clearAllTabsSilently(){[...tabs].forEach(t=>{const b=$('tabbtn_'+t.id);if(b)b.remove();const p=$('pane_'+t.id);if(p)p.remove();});tabs=[];activeTab=null;toggleOverview();const _sb=$('schemaBadge');if(_sb){_sb.style.display='none';_sb.textContent='';}}
// Deliberately does NOT prepend "USE <schema>;" to the new tab's text - that's redundant
// (Api-Query/Api-Script already receive the schema via a SEPARATE db parameter, passed to
// mysql.exe as --database=..., independent of whatever text is in the query itself), and it was
// actively harmful: with "USE ...;" present as its own statement, ANY query typed after it
// became a two-statement script to splitStmts(), which made isSelect() false even when the
// second statement was a plain SELECT - routing the whole thing through the script-execution
// path (runs it, reports OK) instead of the query path that actually displays a result grid.
// The active schema is still shown via the "Schema: <db>" badge, so nothing is lost here.
function newTab(){openTab('Query','',curSchema,false,null);}
const T=id=>tabs.find(t=>t.id===id);

// withPos (optional): when truthy, each entry is {text,start,end} (offsets into the ORIGINAL
// sql string) instead of a plain string - used by runSel() below to find which statement a
// cursor position falls within. Existing callers all omit it, so their return shape (plain
// trimmed strings) is completely unaffected; only the SAME reset point that already existed
// (an actual delimiter match, never the DELIMITER directive itself) also updates curStart.
// Comments are not statements, but splitStmts() has no reason to know that - it splits on the
// delimiter, so "SELECT 1; -- note" comes back as two pieces and a leading "-- note" ends up
// glued to the front of the statement it precedes. Both then defeat the keyword test that
// decides whether a run can show a result grid, so an ordinary commented SELECT ran fine and
// displayed nothing but "Script OK". Same failure the USE-statement comment above describes.
// sqlHead() returns a statement with leading whitespace and comments removed, for classifying
// only - what gets SENT is still the original text, comments and all.
function sqlHead(s){
 let t=String(s==null?'':s);
 for(;;){
  const b=t.replace(/^\s+/,'');
  if(b.startsWith('--')||b.startsWith('#')){ const nl=b.indexOf('\n'); if(nl<0)return ''; t=b.slice(nl+1); continue; }
  if(b.startsWith('/*')){ const e=b.indexOf('*/'); if(e<0)return ''; t=b.slice(e+2); continue; }
  return b;
 }
}
function isCommentOnly(s){ return sqlHead(s)===''; }
function splitStmts(sql,withPos){let out=[],cur='',curStart=0,i=0,q=null,delim=';';sql=sql.replace(/\r\n/g,'\n');
 while(i<sql.length){const c=sql[i];
  if(q){cur+=c;if(c==='\\'&&q!=='`'){cur+=sql[i+1]||'';i+=2;continue;}if(c===q)q=null;i++;continue;}
  if(c==='-'&&sql[i+1]==='-'){const e=sql.indexOf('\n',i);const seg=sql.slice(i,e<0?sql.length:e);cur+=seg;i+=seg.length;continue;}
  if(c==='/'&&sql[i+1]==='*'){const e=sql.indexOf('*/',i);const seg=sql.slice(i,e<0?sql.length:e+2);cur+=seg;i+=seg.length;continue;}
  if(c==="'"||c==='"'||c==='`'){q=c;cur+=c;i++;continue;}
  if(sql.slice(i).match(/^delimiter[ \t]+(\S+)/i)){const mm=sql.slice(i).match(/^delimiter[ \t]+(\S+)[^\n]*\n?/i);delim=mm[1];i+=mm[0].length;continue;}
  if(sql.slice(i,i+delim.length)===delim){if(cur.trim())out.push(withPos?{text:cur.trim(),start:curStart,end:i}:cur.trim());cur='';i+=delim.length;curStart=i;continue;}
  cur+=c;i++;}
 if(cur.trim())out.push(withPos?{text:cur.trim(),start:curStart,end:sql.length}:cur.trim());
 return out;}

async function runTab(id){await runSql(id,$('ed_'+id).value);}
async function explainTab(id){
 const ta=$('ed_'+id);const sel=ta.value.substring(ta.selectionStart,ta.selectionEnd).trim();
 const src=sel||ta.value;const stmts=splitStmts(src).filter(s=>!isCommentOnly(s));const stmt=(stmts[0]||src).trim().replace(/;+\s*$/,'');
 if(!stmt){toast('Nothing to explain.',true);return;}
 await runSql(id,'EXPLAIN '+stmt);
}
// Heuristic SQL formatter, built on the SAME tokenizer as the syntax highlighter (hl()), so it
// can never touch the CONTENT of a string, comment, or identifier - only the whitespace and line
// breaks BETWEEN tokens. Not a full parser (deeply nested subqueries won't get perfect
// indentation), but that limitation is purely cosmetic: the one thing this is guaranteed to
// never do is alter what the query actually says, since every non-whitespace token passes
// through completely unchanged.
function formatSql(sql){
 const re=/(\/\*[\s\S]*?\*\/|--[^\n]*)|('(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*"|`(?:[^`]|``)*`)|(\b\d+(?:\.\d+)?\b)|([A-Za-z_][A-Za-z0-9_]*)|([\s\S])/g;
 let m,toks=[];
 while((m=re.exec(sql))){
  if(m[1])toks.push({t:'comment',v:m[1]});
  else if(m[2])toks.push({t:'str',v:m[2]});
  else if(m[3])toks.push({t:'num',v:m[3]});
  else if(m[4])toks.push({t:'word',v:m[4]});
  else if(!/\s/.test(m[5]))toks.push({t:'ch',v:m[5]});
 }
 const BREAK1=new Set(['select','from','where','set','values','union']);
 const COMPOUND={group:'by',order:'by',left:'join',right:'join',inner:'join',full:'join',union:'all',insert:'into','delete':'from'};
 let out='',depth=0;
 for(let i=0;i<toks.length;i++){
  const tok=toks[i];
  if(tok.t==='ch'&&tok.v==='('){depth++;out+=(out&&!/[\s(]$/.test(out)?' ':'')+'(';continue;}
  if(tok.t==='ch'&&tok.v===')'){depth=Math.max(0,depth-1);out+=')';continue;}
  if(tok.t==='ch'&&(tok.v===','||tok.v===';'||tok.v==='.')){out+=tok.v;continue;}
  const lw=tok.t==='word'?tok.v.toLowerCase():'';
  let isBreak=tok.t==='word'&&depth===0&&(BREAK1.has(lw)||lw==='join'||lw==='having'||lw==='limit'||lw==='on');
  if(tok.t==='word'&&depth===0&&COMPOUND[lw]&&toks[i+1]&&toks[i+1].t==='word'&&toks[i+1].v.toLowerCase()===COMPOUND[lw]){isBreak=true;}
  const prevTok=toks[i-1];
  const isCompoundContinuation=tok.t==='word'&&prevTok&&prevTok.t==='word'&&COMPOUND[prevTok.v.toLowerCase()]===lw;
  const afterDot=prevTok&&prevTok.t==='ch'&&prevTok.v==='.';
  if(isBreak&&out.trim().length&&!isCompoundContinuation&&!afterDot){
   out=out.replace(/[ \t]+$/,'');
   out+=(out.endsWith('\n')||out.length===0?'':'\n')+tok.v;
  }else{
   if(out.length&&!out.endsWith('\n')&&!out.endsWith('(')&&!out.endsWith('.')&&tok.v!==','){
    const prevCh=out[out.length-1];
    if(!/\s/.test(prevCh)&&prevCh!=='('&&prevCh!=='.')out+=' ';
   }
   out+=tok.v;
  }
 }
 return out.trim();
}
function formatTabSql(id){const ta=$('ed_'+id);ta.value=formatSql(ta.value);syncHl(id);log('Formatted query.');}
async function runSel(id){
 const ta=$('ed_'+id);
 const sel=ta.value.substring(ta.selectionStart,ta.selectionEnd).trim();
 if(sel){await runSql(id,sel);return;}
 // No selection: run whichever statement the cursor is currently positioned within, rather
 // than falling back to the whole editor - matches the "execute statement at cursor"
 // convention most SQL editors (DBeaver, DataGrip, SSMS) already use. A selection, when
 // present, is always honored above and takes priority over this.
 const pos=ta.selectionStart;
 const stmts=splitStmts(ta.value,true);
 const hit=stmts.find(s=>pos>=s.start&&pos<=s.end);
 await runSql(id,hit?hit.text:ta.value);
}
// Server errors already start with "ERROR 1146 (42S02): ...", so prefixing them produced
// "ERROR: ERROR 1146 ...". Only add the prefix when the message does not carry one.
function logErr(msg){ msg=String(msg==null?'':msg); return /^ERROR\b/.test(msg)?msg:('ERROR: '+msg); }
// A table-view or DDL tab is pinned to the schema it was opened from, so browsing elsewhere
// cannot silently retarget its generated query. Once the user replaces that query with their
// own SQL, the reasoning no longer holds: it is an ordinary query now and should run against
// the schema selected in the sidebar, like any other query tab. Reverting the text back to the
// generated query pins it again.
function markEdited(id){
 const t=T(id), ta=$('ed_'+id);
 if(!t||!ta||!(t.table||t.ddl))return;
 const edited=(ta.value!==(t.genSql||''));
 if(edited!==!!t.sqlEdited){ t.sqlEdited=edited; if(activeTab===id) updateSchemaBadge(id); }
}
function dbOf(t){ if(t&&(t.table||t.ddl)&&!t.sqlEdited)return t.db||curSchema||null; /* table-view + DDL tabs keep their own schema, until their SQL is edited - see markEdited() */ return curSchema||(t&&t.db)||null; /* plain query tabs follow the selected sidebar schema */ }
// Whether a script's results are all worth showing: it calls a procedure, or has more than one
// statement that returns rows. Both used to show nothing but the last SELECT - a procedure's results
// and every earlier SELECT were run and thrown away.
function scriptShowsResults(stmts){
 const heads=stmts.map(s=>sqlHead(s));
 if(heads.some(h=>/^call\b/i.test(h)))return true;
 return heads.filter(h=>/^(select|show|describe|desc|explain|with|table|values)\b/i.test(h)).length>1;
}
// Runs such a script on one connection and shows each result in a tab of its own. These grids
// are read-only: a result of a script is not tied to one table's rows.
async function runScriptResults(id,sql,reqId){
 const t=T(id);const st=$('st_'+id);
 const stmts=splitStmts(sql).filter(s=>!isCommentOnly(s));
 const writes=stmts.some(s=>!/^(select|show|describe|desc|explain|with|table|values|use)\b/i.test(sqlHead(s)));
 if(writes&&roBlock()){st.className='status';st.textContent='Read-only mode: statement blocked.';return;}
 const r=await api('/api/script-results',{sql,db:dbOf(t),requestId:reqId,maxRows:PAGE_BATCH},t.abortCtrl.signal);
 if(r.aborted){if(T(id)){st.className='status';st.textContent='Query cancelled.';}return;}
 if(!T(id))return;
 t.table=null;t.pk=null;t.pending=null;t.cursorId=null;t.cursorReqId=null;t.hasMore=false;t.exact=false;
 {const eb=$('edit_'+id);eb.innerHTML='';delete eb.dataset.sig;}
 const selb=$('selbtn_'+id);if(selb)selb.innerHTML='';
 t.resultSets=r.results||[];
 if(t.resultSets.length){showResultSet(id,0);}
 else{t.cols=[];t.rows=[];$('res_'+id).innerHTML='';renderResultSetTabs(id);updatePager(id);const ra0=$('resultActions_'+id);if(ra0)ra0.style.display='none';}
 const n=t.resultSets.length;
 if(r.ok){st.className='status';st.textContent='OK. '+stmts.length+' statement(s) executed, '+n+' result(s).';log('SCRIPT OK ('+stmts.length+' statements, '+n+' results)');}
 else{st.className='status err';st.textContent=(r.error||'Failed.')+(n?' - showing the '+n+' result(s) produced before it.':'');log(logErr(r.error||'Failed.'));}
 if(writes&&t.db)loadObjects(t.db);
}
function showResultSet(id,i){
 const t=T(id);if(!t||!t.resultSets||!t.resultSets[i])return;
 const rs=t.resultSets[i];t.resultIdx=i;
 t.cols=rs.columns;t.rows=rs.rows;t.binCols=rs.binaryCols||[];t.bitCols=rs.bitCols||null;
 t.filters={};t.sortCol=-1;t.sortDir=1;t.selected=new Set();t._total=null;
 renderResultSetTabs(id);
 const ra=$('resultActions_'+id);if(ra)ra.style.display=t.cols.length?'inline-flex':'none';
 if(!t.cols.length){$('res_'+id).innerHTML='<div class="muted" style="padding:8px">No rows. (The column names of this result are not available: it came from a procedure, or after a USE.)</div>';}
 else renderGrid(id);
 updatePager(id);
}
function renderResultSetTabs(id){
 const t=T(id);const el=$('rsets_'+id);if(!el)return;
 const sets=(t&&t.resultSets)||[];const cur=sets[t&&t.resultIdx||0];
 if(!sets.length||(sets.length===1&&!cur.truncated)){el.style.display='none';el.innerHTML='';return;}
 el.style.display='flex';
 el.innerHTML=(sets.length>1?sets.map((s,i)=>'<button class="sm" style="'+(i===t.resultIdx?'border-color:var(--accent);font-weight:600':'')+'" title="'+esc('Statement '+s.statement+': '+s.sql)+'" onclick="showResultSet(\''+id+'\','+i+')">Result '+(i+1)+' ('+fmtCount(s.rowCount)+')</button>').join(''):'')
  +(cur&&cur.truncated?'<span class="muted">Showing the first '+fmtCount(cur.rows.length)+' of '+fmtCount(cur.rowCount)+' rows.</span>':'');
}
// runSql(): send the editor SQL to the server and show the rows (or the error).
async function runSql(id,sql,paging){const t=T(id);if(!t)return;if(sql!=null&&sql!==t.curRun){t.prevRun=t.curRun;t.curRun=sql;}const st=$('st_'+id);st.className='status';st.textContent='Running\u2026';
 closeCursorFor(t);
 addHistory(sql);
 const stmts=splitStmts(sql).filter(s=>!isCommentOnly(s));
 const lastStmt=(stmts[stmts.length-1]||sql).trim();
 // Any multi-statement input is now eligible to show a result grid, as long as its FINAL
 // statement is a plain, ordinary SELECT-like one - not just "single statement" or "USE(s) then
 // a SELECT" as before. Two execution paths, chosen for correctness AND to avoid an unnecessary
 // extra round-trip for the common case:
 //  - leadingAreAllUse: a leading run of plain "USE <schema>;" statements is safe to send ALONG
 //    WITH the trailing SELECT in ONE combined call - USE produces no output of its own in
 //    mysql's batch mode, so the existing single-result-set parser sees exactly the same output
 //    it would for the SELECT alone. Cheapest path, one round trip, used whenever it applies.
 //  - otherwise (a leading statement is something OTHER than USE - another SELECT, an UPDATE,
 //    etc): those leading statements run first as a SCRIPT (a SEPARATE connection from the one
 //    that runs the displayed final query) purely for their side effects, then the final
 //    statement runs alone as the actual displayed query. Committed data changes and schema
 //    switches ARE correctly visible to the final query this way, but genuinely session-scoped
 //    state (user-defined @variables, temp tables, an uncommitted transaction spanning both
 //    steps) will NOT carry over, since that state belongs to a connection that's now closed.
 const isSelectLast=/^(select|show|describe|desc|explain|with|table|values)\b/i.test(sqlHead(lastStmt));
 const leadingAreAllUse=stmts.length>1&&stmts.slice(0,-1).every(s=>/^use\s+\S/i.test(sqlHead(s)));
 const needsScriptStep=stmts.length>1&&isSelectLast&&!leadingAreAllUse;
 const isSelect=isSelectLast;
 // A CALL, or more than one SELECT: every result is shown, each in its own tab.
 const multiResult=scriptShowsResults(stmts);
 if(t.resultSets){t.resultSets=null;renderResultSetTabs(id);}
 const reqId=(crypto.randomUUID?crypto.randomUUID():('r'+Date.now()+Math.random()));
 t.abortCtrl=new AbortController();t.runningReqId=reqId;setRunning(id,true);
 try{
  if(multiResult){
    await runScriptResults(id,sql,reqId);
  } else if(isSelect){
    if(needsScriptStep){
      // Each leading statement was already correctly, individually extracted by splitStmts()
      // above - including correctly handling any DELIMITER directive within it (a procedure's
      // BEGIN...END body full of internal semicolons comes back as ONE complete piece). But a
      // naive rejoin with a plain ';' throws that context away entirely: the reconstructed text
      // has no DELIMITER directive left in it at all, while still containing every one of the
      // procedure's own internal semicolons - so /api/script's OWN delimiter-aware splitter
      // would then incorrectly re-split THOSE, seeing no directive telling it not to. Wrapping
      // each piece in its own DELIMITER guarantees it survives as exactly one statement,
      // regardless of what's inside it. The token itself (8 dollar signs) was chosen by testing
      // directly against a real mysql CLI: a raw control character is flatly rejected ("Unknown
      // command"), and a longer mixed alphanumeric token gets mis-parsed after the first
      // statement - but extending the CLI's own "$$" convention this far tested cleanly, while
      // still being implausible to ever collide with real SQL content.
      const leadingSql=stmts.slice(0,-1).map(s=>'DELIMITER $$$$$$$$\n'+s+'\n$$$$$$$$\nDELIMITER ;').join('\n');
      const scriptR=await api('/api/script',{sql:leadingSql,db:dbOf(t)},t.abortCtrl.signal);
      if(scriptR.aborted){if(T(id)){st.className='status';st.textContent='Query cancelled.';}return;}
      if(!T(id))return;
      if(!scriptR.ok){st.className='status err';st.textContent=scriptR.error;$('res_'+id).innerHTML='';log('ERROR: '+scriptR.error);return;}
    }
    const _q=(leadingAreAllUse&&stmts.length>1?sql:lastStmt).trim().replace(/;+\s*$/,'');
    // The database a bare table name in the query refers to: the last leading USE, which runs in
    // the same call, or else the one the query is sent with.
    const runDb=dbOf(t);
    const tableDb=(leadingAreAllUse&&useTarget(stmts))||runDb;
    const bind=t.ddl?null:parseSingleEditableTable(lastStmt,tableDb);
    const exact=bind?await exactTextQuery(_q,lastStmt,bind):null;
    if(!T(id))return;
    const r=await api('/api/query',{sql:exact?exact.sql:_q,db:runDb,requestId:reqId,pageSize:PAGE_BATCH,exactText:exact&&exact.cols.length?exact.cols:undefined},t.abortCtrl.signal);
    if(r.aborted){if(T(id)){st.className='status';st.textContent='Query cancelled.';}return;}
    if(!T(id))return;
    if(!r.ok){st.className='status err';st.textContent=r.error;$('res_'+id).innerHTML='';log(logErr(r.error));return;}
    t.cols=r.columns;t.binCols=r.binaryCols||[];t.rows=r.rows;t.exact=!!exact;t.pk=null;t.pending=null;t.filters={};t.sortCol=-1;t.sortDir=1;t.selected=new Set();
    // Direct clear (not updateEditBar) since a fresh query's table-ness isn't known yet - gives
    // instant feedback instead of showing stale buttons from whatever was loaded before while
    // this one is still fetching. Must also drop updateEditBar's own "nothing changed" cache
    // (dataset.sig) here, or a freshly-loaded editable table whose starting state (0 pending, no
    // selection) happens to match whatever sig was last cached gets wrongly treated as "already
    // showing this" and the bar - now genuinely empty from the innerHTML='' below - never gets
    // rebuilt at all, even though this new table has a PK and should show +Row/Apply/etc.
    {const eb=$('edit_'+id);eb.innerHTML='';delete eb.dataset.sig;}
    t.cursorId=r.cursorId||null;t.hasMore=!!r.hasMore;t.cursorReqId=t.cursorId?reqId:null;
    if(!r.columns.length){st.textContent=r.message||'Query OK.';$('res_'+id).innerHTML='';updatePager(id);const ra0=$('resultActions_'+id);if(ra0)ra0.style.display='none';return;}
    const ra=$('resultActions_'+id);if(ra)ra.style.display='inline-flex';
    refreshRunTableBinding(id,lastStmt,tableDb);
    if(t.table){const pk=await api('/api/pk',{db:t.db,table:t.table});if(pk.ok&&pk.pk.length){t.pk=pk.pk;t.pending={upd:{},del:new Set(),ins:[]};}
      const fk=await api('/api/fk',{db:t.db,table:t.table});if(fk.ok){t.fk=fk.fk||[];t.fkDetails=fk.fkDetails||[];}
      // Prime column-type info (and derive which columns are BIT) right away, alongside pk/fk -
      // this is what lets the grid show a BIT column's plain decimal value on first render (see
      // cellHtml's isBit param) instead of only once the user starts editing, which is as far as
      // getColType's own lazy caching (used by editWidgetFor) would otherwise get it for free.
      try{const ct=await api('/api/query',{sql:"SELECT COLUMN_NAME, COLUMN_TYPE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA="+lit(t.db)+" AND TABLE_NAME="+lit(t.table)});
        if(ct.ok){t.colTypes={};ct.rows.forEach(row=>{t.colTypes[row[0]]=row[1];});t.bitCols=t.cols.map(c=>!!(t.colTypes[c]&&/^bit\(/i.test(t.colTypes[c])));}
      }catch(e){}
      if(objData && objData.db===t.db && objData.rowCounts && (t.table in objData.rowCounts) && objData.rowCounts[t.table]!=null){
        t.estRows=+objData.rowCounts[t.table];
      } else {
        try{const cq=await api('/api/query',{sql:"SELECT TABLE_ROWS FROM information_schema.TABLES WHERE TABLE_SCHEMA="+lit(t.db)+" AND TABLE_NAME="+lit(t.table)});t.estRows=(cq.ok&&cq.rows.length&&cq.rows[0][0]!=null)?+cq.rows[0][0]:null;}catch(e){t.estRows=null;}
      }
    } else { t.estRows=null; }
    if(!T(id))return;
    t.lastElapsedMs=r.elapsedMs;
    if(r.fetchMs!=null&&r.jsonMs!=null&&r.elapsedMs>=300){log(fmtCount(t.rows.length)+' row(s) fetched in '+fmtMs(r.elapsedMs)+' (parse '+fmtMs(r.fetchMs)+', JSON '+fmtMs(r.jsonMs)+').');}
    renderGrid(id);updatePager(id);
    updateStatusLine(id);
    updateSchemaBadge(id);
  } else {
    if(roBlock()){st.className='status';st.textContent='Read-only mode: statement blocked.';return;}
    const continueOnError=!!($('coe_'+id)&&$('coe_'+id).checked);
    const r=await api('/api/script',{sql,db:dbOf(t),requestId:reqId,continueOnError},t.abortCtrl.signal);
    if(r.aborted){if(T(id)){st.className='status';st.textContent='Cancelled.';}return;}
    if(!T(id))return;
    if(r.failures){
      // continueOnError response shape: always a full breakdown, whether it ended up fully
      // clean or partially failed - this is the whole point of turning the option on, seeing
      // every problem in one pass rather than fixing and re-running one failure at a time.
      if(!r.failures.length){
        st.textContent='OK. '+r.succeeded+' of '+r.total+' statement(s) executed.';
        log('SCRIPT OK ('+r.succeeded+'/'+r.total+' statements)');
      } else {
        st.className='status err';
        st.textContent=r.succeeded+' of '+r.total+' succeeded, '+r.failures.length+' failed (see log for details).';
        // The log only lists failures, which left "did statement N even run?" genuinely
        // ambiguous - answering it required subtracting the failure count from the total and
        // cross-checking which specific numbers were missing from the list. Naming exactly
        // which statement numbers succeeded removes that arithmetic entirely.
        const failedIdx=new Set(r.failures.map(f=>f.index));
        const succeededIdx=[];for(let i=1;i<=r.total;i++){if(!failedIdx.has(i))succeededIdx.push(i);}
        const succNote=succeededIdx.length?' (statement(s) '+succeededIdx.join(', ')+')':'';
        const detail=r.failures.map(f=>'Statement '+f.index+' of '+r.total+': '+f.error+'\n  '+f.preview).join('\n\n');
        log('SCRIPT: '+r.succeeded+' of '+r.total+' succeeded'+succNote+'.\n\nFailed:\n'+detail);
      }
      if(t.db)loadObjects(t.db);
    } else if(r.ok){st.textContent='OK. '+stmts.length+' statement(s) executed.';log('SCRIPT OK ('+stmts.length+' statements)');if(t.db)loadObjects(t.db);}
    else{st.className='status err';st.textContent=r.error;log('SCRIPT ERROR: '+r.error);}
  }
 } finally {
  if(T(id)){t.runningReqId=null;t.abortCtrl=null;setRunning(id,false);}
 }
}

// Swapping to Cancel is delayed 900ms rather than instant: most runs - including every silent
// background "fetch more rows" call, which goes through this exact same function - finish well
// under that, so the button bar never flips at all for the common case instead of flashing to
// Cancel and back within a fraction of a second on every one of them. A run that's still going
// when the delay elapses shows Cancel immediately, same as before; cancelling (or finishing)
// always clears the pending timer so a since-completed run can't pop it up late.
const _runDelayTimers={};
function setRunning(id,running){const rb=$('runbtn_'+id),cb=$('cancelbtn_'+id);if(!rb||!cb)return;
 if(_runDelayTimers[id]){clearTimeout(_runDelayTimers[id]);delete _runDelayTimers[id];}
 if(running){_runDelayTimers[id]=setTimeout(()=>{delete _runDelayTimers[id];rb.style.visibility='hidden';cb.style.visibility='';},900);}
 else{rb.style.visibility='';cb.style.visibility='hidden';}
 const tb=$('tabbtn_'+id);if(tb){let dot=tb.querySelector('.runningdot');if(running){if(!dot){dot=document.createElement('span');dot.className='runningdot';dot.title='Query running';tb.insertBefore(dot,tb.firstChild);}}else if(dot){dot.remove();}}}
async function cancelQuery(id){const t=T(id);if(!t)return;if(t.abortCtrl){try{t.abortCtrl.abort();}catch(e){}}
 const rid=t.runningReqId;
 if(rid){
   if(window.__TAURI__&&window.__TAURI__.core){try{await window.__TAURI__.core.invoke('cancel_query',{req:{requestId:rid}});}catch(e){}}
   else{try{await fetch('/api/cancel-query',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({token:TOKEN,requestId:rid})});}catch(e){}}
 }
 log('Cancel requested.');}

// Fire-and-forget: tell the server to close a tab's open streaming query cursor (if any), and
// clear the local handle. Safe to call whenever - an unknown/already-gone cursorId is a no-op on
// the server. Called before a tab starts a new run (replacing whatever cursor the previous run
// left open) and from closeTab/closeAll/closeOthers, since a tab can have an open cursor waiting
// on "fetch next" independently of whether a query is actively "running" (t.runningReqId).
function closeCursorFor(t){if(!t||!t.cursorId)return;const cid=t.cursorId;t.cursorId=null;t.cursorReqId=null;t.hasMore=false;
 try{api('/api/close-cursor',{cursorId:cid});}catch(e){}}
// fetchNextBatch(): pulls the next page of rows from the SAME still-open server-side cursor (not
// a re-run with a growing OFFSET) and appends them to the tab's already-loaded rows. Reuses the
// same t.runningReqId/setRunning toggle the initial run uses - and keeps t.cursorReqId (the SAME
// requestId the cursor was originally registered under) as the id sent to /api/cancel-query - so
// the existing Cancel button/cancelQuery(id) plumbing keeps working unmodified during a slow
// "fetch next" too, not just on the very first page.
// t.fetchingMore makes an overlapping call (e.g. two scroll events firing close together) a no-op.
async function fetchNextBatch(id){const t=T(id);if(!t||!t.cursorId||t.runningReqId||t.fetchingMore)return;
 const st=$('st_'+id);const wasClassName=st?st.className:'';const wasText=st?st.textContent:'';
 t.fetchingMore=true;t.abortCtrl=new AbortController();t.runningReqId=t.cursorReqId;setRunning(id,true);
 if(st){st.className='status';st.textContent='Fetching next '+PAGE_BATCH+' rows\u2026';}
 try{
  const r=await api('/api/fetch-cursor-batch',{cursorId:t.cursorId,requestId:t.cursorReqId,pageSize:PAGE_BATCH},t.abortCtrl.signal);
  if(r.aborted){if(T(id)&&st){st.className='status';st.textContent='Query cancelled.';}return;}
  if(!T(id))return;
  if(!r.ok){if(st){st.className='status err';st.textContent=r.error;}log(logErr(r.error));t.cursorId=null;t.cursorReqId=null;t.hasMore=false;return;}
  t.rows=t.rows.concat(r.rows);
  t.hasMore=!!r.hasMore;t.cursorId=r.hasMore?(r.cursorId||t.cursorId):null;t.cursorReqId=t.hasMore?t.cursorReqId:null;
  if(st){st.className=wasClassName;st.textContent=wasText;}
  // renderBody (not renderGrid) deliberately: it only rewrites tbody's own innerHTML, not the
  // scrollable wrap element's - renderGrid replacing wrap's innerHTML resets scrollTop to 0,
  // which would yank the view back to the top on every background scroll-triggered prefetch.
  renderBody(id);updatePager(id);updateStatusLine(id);
 } finally {
  if(T(id)){t.fetchingMore=false;t.runningReqId=null;t.abortCtrl=null;setRunning(id,false);}
 }
}

function updatePager(id){const t=T(id);const p=$('pager_'+id);if(!p)return;const total=(t._total!=null?t._total:(t.rows?t.rows.length:0));if(!total){p.innerHTML='';return;}
 p.innerHTML='<span class="muted">'+fmtCount(total)+(t.hasMore?'+':'')+' row(s) loaded</span>';}
function toggleLast(id){const t=T(id);const ta=$('ed_'+id);if(t.prevRun==null){log('No previous query to toggle to yet.');return;}ta.value=t.prevRun;if(typeof syncHl==='function')syncHl(id);runSql(id,t.prevRun);}
function toggleAll(id){const t=T(id);if(!t.table)return;const ta=$('ed_'+id);const base='SELECT * FROM '+qid(t.db)+'.'+qid(t.table)+';';const cur=(ta.value||'').trim();if(cur!==base.trim()){t.beforeAll=ta.value;ta.value=base;}else if(t.beforeAll!=null){ta.value=t.beforeAll;}else{ta.value=base;}if(typeof syncHl==='function')syncHl(id);runSql(id,ta.value);}
function selBtnHtml(id,table){return table?'<button title="Toggle between your query and SELECT * (the whole table)" onclick="toggleAll(\''+id+'\')">\u21C4 Show all</button>':'';}
// t.table (and thus row-edit capability, export-as-table, quick filter, ...) used to be fixed
// at whatever the tab was opened with and never revisited - so a tab opened as a non-editable
// "SELECT COUNT(*)" stayed permanently non-editable even after retyping it into a plain
// "SELECT * FROM x", AND (worse) a tab opened against one table that got hand-edited to query a
// DIFFERENT one stayed silently bound to the ORIGINAL table for Apply's UPDATE/DELETE target -
// editing rows that were never really identified by the PK it thought it had. Called once per
// run with the statement actually about to execute, so t.table always reflects the query that
// produced what's on screen right now, not whatever the tab happened to start as.
// fallbackDb is where the query itself looked for a table named without a database. Using the
// tab's own database instead bound "USE b; SELECT * FROM t" - or an edited table tab run while
// another schema was selected - to a different database's t, and Apply wrote to that table.
function refreshRunTableBinding(id,lastStmt,fallbackDb){
 const t=T(id);if(!t||t.ddl)return;
 const m=parseSingleEditableTable(lastStmt,fallbackDb||t.db||curSchema);
 const newTable=m?m.table:null, newDb=m?m.db:(t.db||curSchema);
 if(t.table===newTable&&t.db===newDb)return;
 t.table=newTable;t.db=newDb;
 const sb=$('selbtn_'+id);if(sb)sb.innerHTML=selBtnHtml(id,t.table);
}
// The database the last "USE db" among these statements switches to, or null.
function useTarget(stmts){
 let db=null;
 for(const s of stmts){const m=sqlHead(s).match(/^use\s+(`(?:[^`]|``)+`|[^\s;`]+)/i);if(m)db=m[1].startsWith('`')?m[1].slice(1,-1).replace(/``/g,'`'):m[1];}
 return db;
}
// Conservative on purpose: only recognizes "SELECT ... FROM <one table>" with no JOIN/comma-join,
// UNION, GROUP BY, DISTINCT, or bare aggregate call - any of those can produce a result that
// isn't one row per primary key, which is exactly what row-editing (and Apply's UPDATE/DELETE
// WHERE pk=...) assumes. No alias support either, matching the one pattern this app itself ever
// generates (openRun/toggleAll's own "SELECT * FROM db.table"). False negatives (a hand-written
// query that IS safely editable but doesn't match) just mean no edit bar, never a false positive.
function parseSingleEditableTable(sql,fallbackDb){
 const head=sqlHead(sql).replace(/;\s*$/,'').trim();
 if(!/^select\b/i.test(head))return null;
 if(/^select\s+distinct\b/i.test(head))return null;
 if(/\bunion\b/i.test(head))return null;
 if(/\bgroup\s+by\b/i.test(head))return null;
 const ID='(?:`(?:[^`]|``)+`|[A-Za-z_$][A-Za-z0-9_$]*)';
 const m=head.match(new RegExp('\\bfrom\\s+('+ID+')(?:\\s*\\.\\s*('+ID+'))?','i'));
 if(!m)return null;
 if(/\b(count|sum|avg|min|max|group_concat|std|stddev|variance|bit_and|bit_or|bit_xor)\s*\(/i.test(head.slice(0,m.index)))return null;
 const rest=head.slice(m.index+m[0].length).trim();
 if(rest&&!/^(where|order\s+by|limit|having)\b/i.test(rest))return null;
 const unq=s=>s.startsWith('`')?s.slice(1,-1).replace(/``/g,'`'):s;
 return m[2]?{db:unq(m[1]),table:unq(m[2])}:{db:fallbackDb,table:unq(m[1])};
}
async function openRun(id){const t=T(id);const where=combinedFilterWhere(t);const wh=where?(' WHERE '+where):'';const sql='SELECT * FROM '+qid(t.db)+'.'+qid(t.table)+wh+';';$('ed_'+id).value=sql;syncHl(id);await runSql(id,sql);updateFilterBar(id);}

// ---- editable grid with pending changes ----
function clip(v,n){const s=String(v);return s.length>n?s.slice(0,n)+'\u2026':s;}
// Decodes a "0x.." hex-encoded cell value (our OWN display encoding for text containing real
// control characters) back into readable text, marking ONLY the actual control-character byte
// positions with a small inline badge - like MySQL Workbench does - instead of hex-dumping the
// whole value. Splits at control-byte positions (always unambiguous single ASCII bytes that can
// never occur inside a multi-byte UTF-8 sequence) and decodes each segment properly as UTF-8, so
// accented/non-ASCII text around the control character stays readable, not garbled.
// IMPORTANT: this is a DISPLAY-ONLY transform. The underlying value (t.rows[ri][ci]) is left as
// the "0x.." string exactly as before - editing, Apply, and SQL generation are untouched, since
// that hex form is what makes round-tripping a value with a real embedded NUL byte safe (a raw
// NUL in the actual SQL text risks truncation when passed as a command-line argument).
const CTRL_NAMES={0:'NUL',1:'SOH',2:'STX',3:'ETX',4:'EOT',5:'ENQ',6:'ACK',7:'BEL',8:'BS',11:'VT',12:'FF',14:'SO',15:'SI',16:'DLE',17:'DC1',18:'DC2',19:'DC3',20:'DC4',21:'NAK',22:'SYN',23:'ETB',24:'CAN',25:'EM',26:'SUB',27:'ESC',28:'FS',29:'GS',30:'RS',31:'US'};
function ctrlBadge(b){return '<span style="background:#4a3a1f;color:#e8c589;border-radius:3px;padding:0 3px;font-size:10px;font-weight:600;margin:0 1px" title="Control character (0x'+b.toString(16).padStart(2,'0').toUpperCase()+') - not printable text">'+CTRL_NAMES[b]+'</span>';}
// Text holding a control character (a NUL, say) showed it as nothing at all, so 'a<NUL>b' looked
// like 'ab'. Marked the same way as above.
const CTRL_RE=/[\x00-\x08\x0B\x0C\x0E-\x1F]/g;
function textCellHtml(s,maxChars){const h=esc(clip(s,maxChars));return h.search(CTRL_RE)<0?h:h.replace(CTRL_RE,ch=>ctrlBadge(ch.charCodeAt(0)));}
// What a <textarea> cannot show. The grid marks a control character with a badge above, but the
// cell editor is a plain textarea, where the same byte takes no space at all - so a value the grid
// shows as a<NUL>b reads in there as "ab", and one that ends in a NUL looks like it just ends.
// This is said BESIDE the box rather than marked up inside it on purpose: Text mode saves whatever
// the box holds (textToHex runs over the whole thing), so a visible stand-in for an invisible byte
// would be stored as that character's own bytes - the way to lose a value, not to show it.
function ctrlCharNote(s,hasHexTab){
 if(typeof s!=='string')return '';
 const found=s.match(CTRL_RE);
 if(!found)return '';
 const counts={};
 found.forEach(ch=>{const n=CTRL_NAMES[ch.charCodeAt(0)];counts[n]=(counts[n]||0)+1;});
 const named=Object.keys(counts).map(n=>counts[n]>1?n+' ×'+counts[n]:n).join(', ');
 const n=found.length;
 return 'This value holds '+n+' control character'+(n>1?'s':'')+' ('+named+'), which take'+(n>1?'':'s')+' no space in the box above'
  +(hasHexTab?' - switch to Hex to see or edit the bytes.'
   :n>1?' - editing the text around them leaves them as they are.':' - editing the text around it leaves it as it is.');
}
function setVNote(text){const n=$('vNote');if(!n)return;n.textContent=text||'';n.style.display=text?'block':'none';}
function decodeCtrlCharCell(hexStr,maxChars){
 const hex=hexStr.slice(2);const bytes=[];for(let i=0;i<hex.length;i+=2){bytes.push(parseInt(hex.substr(i,2),16));}
 const decoder=new TextDecoder('utf-8',{fatal:false});
 let html='',shown=0,segStart=0,truncated=false;
 for(let i=0;i<=bytes.length;i++){
  const isCtrl=i<bytes.length&&CTRL_NAMES.hasOwnProperty(bytes[i]);
  if(isCtrl||i===bytes.length){
   if(i>segStart){
    const segText=decoder.decode(new Uint8Array(bytes.slice(segStart,i)));
    if(shown+segText.length>maxChars){html+=esc(segText.slice(0,Math.max(0,maxChars-shown)));shown=maxChars;truncated=true;}
    else{html+=esc(segText);shown+=segText.length;}
   }
   if(isCtrl&&!truncated){html+=ctrlBadge(bytes[i]);shown++;}
   segStart=i+1;
  }
  if(truncated)break;
 }
 if(truncated)html+='\u2026';
 return html;
}
// A binary column holding no bytes arrives as a bare "0x" - the prefix with nothing after it. The
// hex branch below needs at least one digit, so such a value used to fall through to the plain-text
// renderer and print the marker itself, the one value in a grid shown as its own wire format. It is
// only said for a column the server declared binary (binCols), because a VARCHAR can perfectly
// well hold the two characters "0x" and that is exactly what should be shown for it.
function cellHtml(v,isBit,isBin){if(v===null)return '<span style="color:#999;font-style:italic">(NULL)</span>';if(v==='')return '<span style="color:#999;font-style:italic;opacity:.6">(empty)</span>';if(v==='0x'&&isBin)return '<span style="color:#999;font-style:italic;opacity:.6">(0 bytes)</span>';if(typeof v==='string'&&/^0x[0-9A-Fa-f]+$/.test(v))return isBit?esc(hexToBitNumber(v)):decodeCtrlCharCell(v,300);return textCellHtml(v,300);}
function colgroupHtml(id){const t=T(id);const ed=!!t.pk;const hidden=t.hiddenCols||new Set();let h='<colgroup><col style="width:30px">'+(ed?'<col style="width:34px">':'');t.cols.forEach((c,ci)=>{h+='<col style="width:150px'+(hidden.has(ci)?';display:none':'')+'">';});return h+'<col></colgroup>';}
// wireColResize(): drag a column edge to resize, double-click to auto-fit (widths saved per table).
function wireColResize(id){const wrap=$('res_'+id);if(!wrap)return;const table=wrap.querySelector('table.grid');if(!table)return;const cg=table.querySelector('colgroup');if(!cg)return;const t=T(id);const off=(!!t.pk)?2:1;
 wrap.querySelectorAll('thead .rz').forEach(rz=>{const ci=+rz.getAttribute('data-ci');const col=cg.children[ci+off];if(!col)return;let sx=0,sw=0,drag=false;
  rz.addEventListener('pointerdown',e=>{e.stopPropagation();e.preventDefault();drag=true;sx=e.clientX;sw=col.getBoundingClientRect().width;try{rz.setPointerCapture(e.pointerId);}catch(_){}rz.classList.add('drag');});
  rz.addEventListener('pointermove',e=>{if(!drag)return;const w=Math.max(40,Math.round(sw+(e.clientX-sx)));col.style.width=w+'px';});
  const end=e=>{if(!drag)return;drag=false;rz.classList.remove('drag');try{rz.releasePointerCapture(e.pointerId);}catch(_){}};
  rz.addEventListener('pointerup',end);rz.addEventListener('pointercancel',end);
  rz.addEventListener('click',e=>e.stopPropagation());
  rz.addEventListener('dblclick',e=>{e.stopPropagation();autofitCol(id,ci);});
 });}
function autofitAll(id,retries){const t=T(id);if(!t.cols||!t.cols.length)return;const off=(!!t.pk)?2:1;const wrap=$('res_'+id);if(!wrap)return;const table=wrap.querySelector('table.grid');if(!table)return;const cg=table.querySelector('colgroup');if(!cg)return;
 if(wrap.clientWidth<150){if((retries||0)<5){requestAnimationFrame(()=>autofitAll(id,(retries||0)+1));}return;}
 t.colsFitted=true;
 const hidden=t.hiddenCols||new Set();const n=t.cols.length;const w=[];const heads=table.querySelectorAll('thead tr:first-child th');for(let ci=0;ci<n;ci++){if(hidden.has(ci)){w[ci]=0;continue;}let mx=heads[ci+off]?heads[ci+off].scrollWidth:60;const cells=table.querySelectorAll('tbody td:nth-child('+(ci+off+1)+')');for(let i=0;i<cells.length;i++){mx=Math.max(mx,cells[i].scrollWidth);}w[ci]=Math.min(Math.max(60,mx+18),400);}const visCount=n-hidden.size;const fixed=30+(off===2?34:0);let sum=fixed;for(let i=0;i<n;i++)sum+=w[i];const avail=wrap.clientWidth-2;if(avail>sum&&visCount>0){const extra=Math.floor((avail-sum)/visCount);for(let i=0;i<n;i++){if(!hidden.has(i))w[i]+=extra;}}for(let ci=0;ci<n;ci++){const col=cg.children[ci+off];if(col&&!hidden.has(ci))col.style.width=w[ci]+'px';}}
function applyColVis(id){const t=T(id);const ed=!!t.pk;const off=ed?2:1;const wrap=$('res_'+id);if(!wrap)return;const table=wrap.querySelector('table.grid');if(!table)return;const cg=table.querySelector('colgroup');if(!cg)return;const hidden=t.hiddenCols||new Set();t.cols.forEach((c,ci)=>{const col=cg.children[ci+off];if(col)col.style.display=hidden.has(ci)?'none':'';});autofitAll(id);}
function setColVis(id,ci,visible){const t=T(id);if(!t.hiddenCols)t.hiddenCols=new Set();if(visible)t.hiddenCols.delete(ci);else t.hiddenCols.add(ci);applyColVis(id);}
function showAllCols(id){const t=T(id);t.hiddenCols=new Set();applyColVis(id);const btn=$('colsbtn_'+id);if(btn)openColPicker(id,btn);}
function hideAllCols(id){const t=T(id);t.hiddenCols=new Set(t.cols.map((_,ci)=>ci));applyColVis(id);const btn=$('colsbtn_'+id);if(btn)openColPicker(id,btn);}
// Toggles: a second click on the SAME Columns button while its picker is already open closes
// it, instead of only closing via the document-level "click outside" listener (which never even
// sees this click, since the button's own onclick calls stopPropagation() first).
function toggleColPicker(id,btn){const p=$('colPicker');if(p&&p.style.display==='block'&&p.dataset.forId===id){p.style.display='none';return;}openColPicker(id,btn);}
function openColPicker(id,btn){const t=T(id);if(!t||!t.cols)return;if(!t.hiddenCols)t.hiddenCols=new Set();
 const p=$('colPicker');p.dataset.forId=id;
 let h='<div class="cphdr"><span>Show/hide columns</span><span><span class="cplink" onclick="event.stopPropagation();showAllCols(\''+id+'\')">Show all</span> \u00B7 <span class="cplink" onclick="event.stopPropagation();hideAllCols(\''+id+'\')">Hide all</span></span></div>';
 t.cols.forEach((c,ci)=>{h+='<label class="cpitem"><input type="checkbox" '+(t.hiddenCols.has(ci)?'':'checked')+' onchange="setColVis(\''+id+'\','+ci+',this.checked)"> '+esc(c)+'</label>';});
 p.innerHTML=h;
 p.style.display='block';p.style.visibility='hidden';p.style.left='0';p.style.top='0';
 const r=btn.getBoundingClientRect();const w=p.offsetWidth||200,hgt=p.offsetHeight||0;
 let nx=Math.min(r.left,innerWidth-w-6);if(nx<6)nx=6;
 let ny=r.bottom+2;if(ny+hgt>innerHeight-6)ny=Math.max(6,r.top-hgt-2);
 p.style.left=nx+'px';p.style.top=ny+'px';p.style.visibility='visible';}
// Consolidates what used to be 4 separate, always-visible buttons (Copy CSV / Copy selected CSV
// / Copy Markdown / Copy selected Markdown) into one dropdown - same underlying actions, same
// behavior when nothing's selected, just not eating four button-widths of toolbar space for a
// 2-format-by-2-scope combination. Mirrors openColPicker()'s exact positioning logic above.
// Same toggle-close fix as toggleColPicker() above - a second click on the SAME Copy button
// while its menu is already open closes it, instead of only closing via the document-level
// "click outside" listener (which never sees this click, since the button's own onclick calls
// stopPropagation() first).
function toggleCopyMenu(id,btn){const p=$('copyMenu');if(p&&p.style.display==='block'&&p.dataset.forId===id){p.style.display='none';return;}openCopyMenu(id,btn);}
function openCopyMenu(id,btn){
 const p=$('copyMenu');p.dataset.forId=id;
 let h='<div class="cphdr"><span>Copy grid as...</span></div>';
 h+='<div class="cpitem" onclick="copyCsv(\''+id+'\');closeCopyMenu();">CSV (all rows)</div>';
 h+='<div class="cpitem" onclick="copySelCsv(\''+id+'\');closeCopyMenu();">CSV (selected rows)</div>';
 h+='<div class="cpitem" onclick="copyMd(\''+id+'\');closeCopyMenu();">Markdown (all rows)</div>';
 h+='<div class="cpitem" onclick="copyMdSel(\''+id+'\');closeCopyMenu();">Markdown (selected rows)</div>';
 p.innerHTML=h;
 p.style.display='block';p.style.visibility='hidden';p.style.left='0';p.style.top='0';
 const r=btn.getBoundingClientRect();const w=p.offsetWidth||200,hgt=p.offsetHeight||0;
 let nx=Math.min(r.left,innerWidth-w-6);if(nx<6)nx=6;
 let ny=r.bottom+2;if(ny+hgt>innerHeight-6)ny=Math.max(6,r.top-hgt-2);
 p.style.left=nx+'px';p.style.top=ny+'px';p.style.visibility='visible';}
function closeCopyMenu(){const p=$('copyMenu');if(p)p.style.display='none';}
function autofitCol(id,ci){const t=T(id);const off=(!!t.pk)?2:1;const wrap=$('res_'+id);const table=wrap.querySelector('table.grid');const cg=table.querySelector('colgroup');const col=cg.children[ci+off];if(!col)return;let max=0;
 const th=table.querySelectorAll('thead tr:first-child th')[ci+off];if(th)max=Math.max(max,th.scrollWidth);
 table.querySelectorAll('tbody td:nth-child('+(ci+off+1)+')').forEach(td=>{max=Math.max(max,td.scrollWidth);});
 const w=Math.min(Math.max(60,max+16),600);col.style.width=w+'px';}
// renderGrid(): build the results table (header, filters, colgroup) then fill the body.
function renderGrid(id){const t=T(id);const ed=!!t.pk;if(!t.filters)t.filters={};if(t.sortCol===undefined){t.sortCol=-1;t.sortDir=1;}
 let h='<table class="grid">'+colgroupHtml(id)+'<thead><tr id="sortrow_'+id+'">'+sortHeader(id,ed)+'</tr><tr id="filterrow_'+id+'">';
 h+='<th style="top:24px"></th>';if(ed)h+='<th style="top:24px"></th>';
 t.cols.forEach((c,ci)=>{h+='<th style="top:24px;padding:1px"><input data-ci="'+ci+'" oninput="setFilter(\''+id+'\','+ci+',this.value)" value="'+esc(t.filters[ci]||'')+'" placeholder="filter" style="width:100%;font-weight:400;font-size:11px"></th>';});
 h+='<th style="top:24px"></th>';
 h+='</tr></thead><tbody id="tbody_'+id+'"></tbody></table>';
 $('res_'+id).innerHTML=h;renderBody(id);syncFilterRowTop(id);requestAnimationFrame(()=>autofitAll(id));wireColResize(id);updateStatusLine(id);refreshTabDirty(id);
 const wrap=$('res_'+id);if(wrap&&!wrap.dataset.kbWired){wrap.tabIndex=-1;wrap.addEventListener('keydown',e=>gridKeyNav(id,e));wrap.addEventListener('mousedown',e=>{const td=e.target.closest('td.editable');if(td){const tr=td.closest('tr[data-r]');if(tr){const ri=+tr.getAttribute('data-r');const t2=T(id);const off=(!!t2.pk)?2:1;const ci=[...tr.children].indexOf(td)-off;if(ci>=0)gridSetFocus(id,ri,ci,false);}}});
  let _vraf=null;wrap.addEventListener('scroll',()=>{if(_vraf)return;_vraf=requestAnimationFrame(()=>{_vraf=null;renderBody(id);maybePrefetchNextBatch(id,wrap);});});
  wrap.dataset.kbWired='1';}}
// Silently tops up a tab's loaded rows once the user scrolls near the bottom of the grid's own
// scrollable area (true infinite scroll - the grid is one continuous virtualized list over
// everything loaded, see renderBody, not a fixed-size page) - mirrors how DBeaver/DataGrip
// transparently extend a result set near the end of what's loaded, with no "load more" click
// and no page boundary to hit. Safe no-op mid-fetch (fetchNextBatch's own t.fetchingMore guard)
// or once the cursor is exhausted (t.hasMore false).
function maybePrefetchNextBatch(id,wrap){
 const t=T(id);if(!t||!t.hasMore||t.fetchingMore||!wrap)return;
 if((wrap.scrollTop+wrap.clientHeight)>=(wrap.scrollHeight-200))fetchNextBatch(id);
}
function toggleWrap(id){const t=T(id);t.wrap=!t.wrap;const wrap=$('res_'+id);if(wrap)wrap.classList.toggle('wraptext',t.wrap);const btn=$('wrapbtn_'+id);if(btn)btn.textContent='Wrap: '+(t.wrap?'On':'Off');}
// The filter row's sticky "top" offset needs to sit at exactly the main header row's actual
// height, or a gap opens up between them that the first scrolled-past data row peeks through -
// a thin sliver of ghosted text right where the filter row should meet the header row. Rather
// than trust a hardcoded guess at that height (fragile: anything added to a header cell in the
// future - a badge, an icon, different font metrics - can silently push the real height past
// whatever number was hardcoded), this measures the header row's ACTUAL rendered height each
// time it's built and applies that exact value, so it stays correct regardless of what's inside it.
function syncFilterRowTop(id){
 const hdr=$('sortrow_'+id),fr=$('filterrow_'+id);
 if(!hdr||!fr)return;
 const h=hdr.getBoundingClientRect().height;
 if(h>0)[...fr.children].forEach(th=>th.style.top=h+'px');
}
// Header cells force an explicit height (28px, matching the app's button height) on both the
// th AND its inner flex wrapper, instead of centering via height:100% (percentage) or the
// browser's default table vertical-align - a sticky th (position:sticky, which every header
// cell here is) doesn't reliably get treated as having a "definite" height for either of those
// in every rendering engine, which is what let header text and the select-all checkbox render
// top-aligned instead of centered under a real WebView2 build. An explicit pixel height on both
// sides of the relationship sidesteps the question entirely.
function sortHeader(id,ed){const t=T(id);const H=28;let h='<th style="width:22px;height:'+H+'px;padding:0"><span style="display:flex;align-items:center;justify-content:center;height:'+H+'px"><input type="checkbox" title="Select/clear all shown rows" onclick="selAll(\''+id+'\',this.checked)"></span></th>'+(ed?'<th></th>':'');t.cols.forEach((c,ci)=>{const ar=t.sortCol===ci?(t.sortDir>0?' \u25B2':' \u25BC'):'';const isPk=t.pk&&t.pk.indexOf(c)>=0;const isFk=t.fk&&t.fk.indexOf(c)>=0;const kb=(isPk?' <span class="muted" style="font-size:9px;font-weight:700;line-height:1;vertical-align:middle;color:var(--erd-pk,#5dcaa5)" title="Primary key">PK</span>':'')+(isFk?' <span class="muted" style="font-size:9px;font-weight:700;line-height:1;vertical-align:middle;color:var(--erd-line,#7aa8d8)" title="Foreign key">FK</span>':'');h+='<th style="cursor:pointer;height:'+H+'px;padding:0 8px" title="'+esc(c)+' \u2014 click to sort (drag edge to resize, double-click edge to auto-fit)" onclick="sortBy(\''+id+'\','+ci+')"><span style="display:flex;align-items:center;gap:4px;height:'+H+'px;min-width:0"><span style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0">'+esc(c)+'</span>'+kb+ar+'</span><span class="rz" data-ci="'+ci+'"></span></th>';});return h+'<th></th>';}
function setFilter(id,ci,v){const t=T(id);t.filters[ci]=v;renderBody(id);updatePager(id);updateStatusLine(id);}
function sortBy(id,ci){const t=T(id);if(t.sortCol===ci){if(t.sortDir>0){t.sortDir=-1;}else{t.sortCol=-1;t.sortDir=1;}}else{t.sortCol=ci;t.sortDir=1;}$('sortrow_'+id).innerHTML=sortHeader(id,!!t.pk);renderBody(id);syncFilterRowTop(id);wireColResize(id);updatePager(id);updateStatusLine(id);}
function viewIndices(id){const t=T(id);let view=t.rows.map((r,ri)=>ri);
 const fk=Object.keys(t.filters).filter(k=>t.filters[k]!=='' && t.filters[k]!=null);
 if(fk.length)view=view.filter(ri=>fk.every(ci=>{const v=t.rows[ri][ci];return v!=null&&String(v).toLowerCase().includes(String(t.filters[ci]).toLowerCase());}));
 if(t.sortCol>=0){const sc=t.sortCol;
   // Decide numeric-vs-text ONCE for the whole column, not per compared pair. The old test
   // asked, for each pair, whether parseFloat(v) round-tripped back to the same string - which
   // any trailing zero fails ("1000.10" -> 1000.1, "0.00" -> 0, "20.00" -> 20). So on an
   // ordinary DECIMAL column some pairs compared as numbers and others as text: an inconsistent
   // comparator, which leaves Array.sort free to return an order sorted by neither rule. It did -
   // sorting a money column put "1000.10" between "1.37" and "2.74".
   // A full-string match (rather than parseFloat, which happily reads "1abc" as 1) is what keeps
   // genuinely non-numeric text out of the numeric path.
   const NUMERIC=/^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/;
   const numericCol=view.every(ri=>{const v=t.rows[ri][sc];return v==null||NUMERIC.test(String(v).trim());});
   view=view.slice().sort((a,b)=>{let va=t.rows[a][sc],vb=t.rows[b][sc];
   if(va==null&&vb==null)return 0;if(va==null)return 1;if(vb==null)return -1;
   if(numericCol){const d=Number(va)-Number(vb);if(d)return d<0?-1:1;
    // Equal as floats - including two values that differ only past float precision. Fall back to
    // text so the comparator still defines a total order instead of calling them interchangeable.
    return String(va).localeCompare(String(vb));}
   return String(va).localeCompare(String(vb));});if(t.sortDir<0)view.reverse();}
 return view;}
function renderBody(id){const t=T(id);const ed=!!t.pk;if(!t.selected)t.selected=new Set();const view=viewIndices(id);t._total=view.length;
 const wrap=$('res_'+id);const rowH=t._rowH||23;const VIRT_THRESHOLD=300;const BUFFER=15;
 let startIdx=0,endIdx=view.length,topH=0,botH=0;
 if(view.length>VIRT_THRESHOLD&&wrap){
  const scrollTop=wrap.scrollTop,viewportH=wrap.clientHeight||600;
  startIdx=Math.max(0,Math.floor(scrollTop/rowH)-BUFFER);
  endIdx=Math.min(view.length,Math.ceil((scrollTop+viewportH)/rowH)+BUFFER);
  if(startIdx>=view.length)startIdx=Math.max(0,view.length-1);
  if(endIdx<startIdx)endIdx=startIdx;
  topH=startIdx*rowH;botH=(view.length-endIdx)*rowH;
 }
 const slice=view.slice(startIdx,endIdx);
 const nCols=1+(ed?1:0)+t.cols.length;
 let h='';
 if(topH>0)h+='<tr class="vpad" style="height:'+topH+'px"><td colspan="'+nCols+'" style="padding:0;border:none"></td></tr>';
 slice.forEach(ri=>{const row=t.rows[ri];const del=ed&&t.pending.del.has(ri);h+='<tr data-r="'+ri+'" class="'+(del?'del':'')+'">';
  h+='<td style="text-align:center;width:22px"><input type="checkbox" class="rowsel" '+(t.selected.has(ri)?'checked':'')+' onclick="toggleSel(\''+id+'\','+ri+',this.checked)"></td>';
  if(ed)h+='<td class="delcell" onclick="toggleDel(\''+id+'\','+ri+')">'+(del?'\u21A9':'\u00D7')+'</td>';
  row.forEach((v,ci)=>{const key=ri+':'+ci;const pend=t.pending&&(key in t.pending.upd);const val=pend?t.pending.upd[key]:v;
   const attr=(ed?'class="editable'+(pend?' dirty':'')+'" onclick="cellClick(this,\''+id+'\','+ri+','+ci+')" ondblclick="editCell(this,\''+id+'\','+ri+','+ci+')" ':'')+'oncontextmenu="cellMenu(event,\''+id+'\','+ri+','+ci+')"';
   h+='<td '+attr+' title="'+esc(clip(val,300))+'">'+cellHtml(val,t.bitCols&&t.bitCols[ci],t.binCols&&t.binCols[ci])+'</td>';});h+='</tr>';});
 if(botH>0)h+='<tr class="vpad" style="height:'+botH+'px"><td colspan="'+nCols+'" style="padding:0;border:none"></td></tr>';
 if(ed)t.pending.ins.forEach((row,ii)=>{h+='<tr class="insrow"><td></td><td class="delcell" onclick="delIns(\''+id+'\','+ii+')">\u00D7</td>';
   t.cols.forEach((c,ci)=>{const v=row[c];const cAttr=esc(c).replace(/\x27/g,'\\x27');h+='<td class="editable" onclick="insClick(this,\''+id+'\','+ii+',\''+cAttr+'\')" ondblclick="editIns(this,\''+id+'\','+ii+',\''+cAttr+'\')" oncontextmenu="insCellMenu(event,\''+id+'\','+ii+',\''+cAttr+'\')" title="'+esc(v)+'">'+cellHtml(v===undefined?null:v,t.bitCols&&t.bitCols[ci],t.binCols&&t.binCols[ci])+'</td>';});h+='</tr>';});
 $('tbody_'+id).innerHTML=h;
 if(wrap&&slice.length){const sampleTr=wrap.querySelector('tbody tr[data-r]');if(sampleTr){const mh=sampleTr.getBoundingClientRect().height;if(mh>4)t._rowH=mh;}}
 updateEditBar(id);}
// renderBody() (the grid's own virtualized-scroll re-render, up to ~60/sec while actively
// scrolling) calls this every time, but the pending count/selection it depends on almost never
// actually changes between those calls - rebuilding the whole innerHTML anyway tore the buttons
// down and recreated them dozens of times a second during plain scrolling, which is what read as
// a flicker. Skip the rebuild entirely when the two values this bar's markup actually depends on
// haven't changed since the last time it was built.
function updateEditBar(id){const t=T(id);const el=$('edit_'+id);if(!el)return;if(!t.pk){if(el.innerHTML){el.innerHTML='';delete el.dataset.sig;}return;}
 const n=Object.keys(t.pending.upd).length+t.pending.del.size+t.pending.ins.length;
 const hasSel=t.selected&&t.selected.size>0;
 const sig=n+':'+hasSel;
 if(el.dataset.sig===sig)return;
 el.dataset.sig=sig;
 el.innerHTML='<button class="write" onclick="addRow(\''+id+'\')">+ Row</button><button class="warn write" '+(hasSel?'':'disabled')+' title="Mark all checked rows for deletion (applied on Apply)" onclick="deleteSel(\''+id+'\')">Delete selected</button><span class="tbsep"></span><button class="go write" '+(n?'':'disabled')+' onclick="applyChanges(\''+id+'\')">Apply</button><button '+(n?'':'disabled')+' onclick="revertChanges(\''+id+'\')">Revert</button><span class="pill">'+n+' pending</span>';}
// MySQL's own DATE/DATETIME/TIME text format <-> what a native <input type="date"/"datetime-
// local"/"time"> needs. Deliberately conservative: anything the native widget can't faithfully
// round-trip - a zero-date ('0000-00-00'), a zero month/day, a TIME past the widget's 00:00:00-
// 23:59:59 range (MySQL TIME can hold up to 838:59:59, and negative) - returns '' rather than a
// silently-wrong guess, which the caller treats as "don't offer the picker for this value",
// falling back to plain text so nothing gets discarded just by opening and closing the editor.
function mysqlToNativeDate(v,dateType){
 if(v==null)return '';
 const s=String(v).trim();
 if(dateType==='time'){
  const m=s.match(/^(\d{1,2}):(\d{2}):(\d{2})/);
  if(!m||+m[1]>23)return '';
  return m[1].padStart(2,'0')+':'+m[2]+':'+m[3];
 }
 const m=s.match(dateType==='date' ? /^(\d{4})-(\d{2})-(\d{2})$/ : /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})(:\d{2})?/);
 if(!m)return '';
 const mo=+m[2],da=+m[3];
 if(mo<1||mo>12||da<1||da>31)return '';
 return dateType==='date' ? s : (m[1]+'-'+m[2]+'-'+m[3]+'T'+m[4]+':'+m[5]+(m[6]||''));
}
function nativeDateToMysql(v,dateType){ return dateType==='datetime-local' ? v.replace('T',' ') : v; }
// ---- Text/Hex toggle for binary/BLOB cells (not BIT - see is_bit_col) ----
// A LOT of real-world binary columns hold plain ASCII/UTF-8 (bcrypt hashes, tokens, UUIDs stored
// as bytes), and forcing hex-only entry for those is a real usability regression vs Heidi/
// Workbench. So both Text and Hex are offered as explicit, user-picked EDIT modes here - but
// Text is only ever offered when it is PROVABLY lossless: strict (fatal) UTF-8 decode, then
// re-encoded and compared byte-for-byte against the original. Anything that doesn't round-trip
// exactly (real binary data, legacy non-UTF8 text, malformed byte sequences) never gets offered
// as Text at all, so there is no best-effort/lossy guess that could silently swap bytes on Save.
const MAX_HEXTEXT_BYTES=2000000; // ~2MB - beyond this, skip the round-trip check and image
                                  // preview (still fully editable as Hex) rather than risk UI jank
function hexToBytes(hexStr){const hex=(hexStr||'').slice(2);const bytes=new Uint8Array(Math.floor(hex.length/2));for(let i=0;i<bytes.length;i++)bytes[i]=parseInt(hex.substr(i*2,2),16);return bytes;}
function bytesToHex(bytes){let s='0x';for(let i=0;i<bytes.length;i++)s+=bytes[i].toString(16).padStart(2,'0');return s;}
function bytesToBase64(bytes){let bin='';for(let i=0;i<bytes.length;i++)bin+=String.fromCharCode(bytes[i]);return btoa(bin);}
// What "Copy value" puts on the clipboard for one cell.
//
// A binary cell is DISPLAYED as 0x.. - that is this app's encoding for bytes, not the value
// itself. Copying that string and pasting it into another cell's Text tab stored the characters
// 0,x,2,4..., which is how two blobs in a real database came to hold a hex dump in place of a
// crypt hash. So when the bytes are ordinary text, copy the text: paste it anywhere and the same
// bytes come back. Bytes that are not valid UTF-8 have no representation but the hex, and the
// Text tab now refuses hex outright, so that path is safe too.
//
// "Copy value as hex" beside it still yields the 0x.. form, for pasting into a WHERE clause or
// another tool - nothing that was possible before has been taken away.
function cellCopyValue(v){
 if(v==null)return '';
 const s=String(v);
 if(/^0x[0-9A-Fa-f]*$/.test(s)){
  const decoded=hexToStrictText(s);
  if(decoded!=null)return decoded;
 }
 return s;
}
function hexToStrictText(hexStr){
 const hex=hexStr||'0x';if(hex.length>MAX_HEXTEXT_BYTES*2)return null;
 try{
  const bytes=hexToBytes(hex);
  const text=new TextDecoder('utf-8',{fatal:true}).decode(bytes);
  if(bytesToHex(new TextEncoder().encode(text)).toLowerCase()!==hex.toLowerCase())return null; // paranoia: enforce an exact round-trip, not just "decodes without throwing"
  return text;
 }catch(e){return null;}
}
// Accepts the hex people actually have to hand and returns the canonical 0x.. form this app
// stores, or null when the input is not usable hex. Whitespace goes first, so a value copied out
// of MySQL Workbench's hex view - "24 37 24 43", or several lines of it - works as well as the
// plain "0x2437.." a cell here copies. The 0x prefix is optional for the same reason.
//
// Validation matters as much as the tidying: hexToBytes() slices off two characters and runs
// parseInt on each pair, so "zz" silently became byte 0 and a stray character turned into a hole
// in the data. An odd number of digits is half a byte and is not a value either.
function normalizeHexInput(s){
 const t=String(s==null?'':s).replace(/\s+/g,'');
 const body=/^0[xX]/.test(t)?t.slice(2):t;
 if(body==='')return '0x';
 if(!/^[0-9A-Fa-f]+$/.test(body))return null;
 if(body.length%2)return null;
 return '0x'+body.toLowerCase();
}
// The value a binary/BLOB cell hands to lit() for a given tab. Named and top-level so the tests
// exercise this exact function rather than a restatement of it - an earlier version of those
// tests reimplemented the empty-value rule and would have kept passing without it.
// Screens staged grid edits for a hex value mixed into other content in a binary column, and
// returns the columns that have one. Named and top-level so the tests drive this exact function
// rather than a restatement of it.
//
// A binary cell DISPLAYS as 0x.., so a copied one pastes in as hex. Clean hex is how you set bytes
// from the grid and passes through lit() unquoted - but hex with anything else attached is a paste
// that landed alongside what was already in the cell, and lit() would quote the lot and store the
// characters. A blob in a real database ended up holding 919 bytes of nested hex text in place of
// a 102-byte hash that way, through the grid, after the value editor had already been fixed.
function pastedHexColumns(t){
 const out=[];
 const bad=(ci,v)=>{
  if(ci<0||!(t.binCols&&t.binCols[ci]))return false;
  if(v===null||v===undefined)return false;
  const s=String(v);
  return looksLikePastedHex(s)&&normalizeHexInput(s)===null;
 };
 Object.keys((t.pending&&t.pending.upd)||{}).forEach(k=>{
  const ci=Number(k.split(':')[1]);
  if(bad(ci,t.pending.upd[k])) out.push(t.cols[ci]);
 });
 ((t.pending&&t.pending.ins)||[]).forEach(row=>{Object.keys(row).forEach(cn=>{
  if(bad(t.cols.indexOf(cn),row[cn])) out.push(cn);
 });});
 return [...new Set(out)];
}
function hexCellValueForSave(mode, raw){
 const h = mode==='text' ? textToHex(raw) : normalizeHexInput(raw);
 // An empty box is an empty value, and both conversions give "0x" - zero digits. That is not
 // valid SQL, and lit()'s hex passthrough requires at least one digit, so it fell through to
 // being quoted and stored the two CHARACTERS 0 and x instead of nothing at all.
 return (h===null||h==='0x')?'':h;
}
// True when Text-mode content looks like it contains a hex value that was meant for the Hex tab.
// Text mode runs textToHex() over the whole box on save, so anything here is stored as the
// CHARACTERS it consists of - "0x24.." becomes 0,x,2,4, not the bytes those digits denote.
//
// Two shapes, and the second is the one that keeps happening. An earlier version of this check
// tested only the first, anchored ^...$, and so stayed silent for the case it was written to
// prevent: a value pasted WITHOUT first selecting what was already in the box, which leaves the
// hex sitting in front of (or behind) the old value. Two blobs in a real database were corrupted
// that way - each holding a hex dump immediately followed by a crypt hash.
function looksLikePastedHex(s){
 const t=String(s==null?'':s).replace(/\s+/g,'');
 if(t==='')return false;
 // The whole box is a hex value: a clean paste into the wrong tab.
 if(/^0[xX][0-9A-Fa-f]{8,}$/.test(t))return true;
 // A hex run sits among other content: pasted alongside what was already there. 16 digits is
 // 8 bytes - long enough that it is not going to be ordinary text that happens to start "0x".
 if(/0[xX][0-9A-Fa-f]{16,}/.test(t))return true;
 return false;
}

function textToHex(text){return bytesToHex(new TextEncoder().encode(text));}
const IMAGE_SIGS=[[[0x89,0x50,0x4E,0x47],'image/png'],[[0xFF,0xD8,0xFF],'image/jpeg'],[[0x47,0x49,0x46,0x38],'image/gif'],[[0x42,0x4D],'image/bmp']];
function detectImageMime(bytes){
 for(const [sig,mime] of IMAGE_SIGS){if(bytes.length>=sig.length&&sig.every((b,i)=>bytes[i]===b))return mime;}
 if(bytes.length>=12&&bytes[0]===0x52&&bytes[1]===0x49&&bytes[2]===0x46&&bytes[3]===0x46&&bytes[8]===0x57&&bytes[9]===0x45&&bytes[10]===0x42&&bytes[11]===0x50)return 'image/webp'; // 'RIFF'....'WEBP'
 return null;
}
// BIT columns get the same Text/Hex-shaped toggle, but relabelled "Number"/Hex and converting
// decimal<->hex instead of UTF8-text<->hex - matching how Heidi/Workbench display BIT values
// (as their plain numeric value, not a byte dump), while still leaving Hex available for anyone
// who wants to see/set the exact bit pattern. Unlike the binary Text/Hex case, this conversion
// is ALWAYS lossless both ways (a fixed-width integer has exactly one hex and one decimal
// representation), so there's no round-trip validity check needed here - only input validation.
function hexToBitNumber(hexStr){const bytes=hexToBytes(hexStr||'0x0');let n=0n;for(let i=0;i<bytes.length;i++)n=(n<<8n)|BigInt(bytes[i]);return n.toString();}
function bitNumberToHex(decStr){return '0x'+BigInt(decStr).toString(16);}
let _vHexState=null; // {kind:'binText'|'bitNum', mode:'text'|'hex'} for the modal currently open on a binary/BIT cell - null otherwise
function updateHexTabButtons(){
 const bt=$('vTabText'),bh=$('vTabHex');if(!bt||!bh||!_vHexState)return;
 bt.classList.toggle('on',_vHexState.mode==='text');bh.classList.toggle('on',_vHexState.mode==='hex');
 // Only Text mode hides control characters; in Hex mode the bytes are right there in the box.
 const ta=$('vText');
 if(_vHexState.kind==='binText'&&ta)setVNote(_vHexState.mode==='text'?ctrlCharNote(ta.value,true):'');
}
function switchHexTab(mode){
 if(!_vHexState||_vHexState.mode===mode)return;
 const ta=$('vText');
 if(_vHexState.kind==='bitNum'){
  if(mode==='text'){
   if(!/^0x[0-9A-Fa-f]*$/.test(ta.value.trim())){toast('Enter valid hex (0x...) first.',true);return;}
   ta.value=hexToBitNumber(ta.value.trim());
  } else {
   if(!/^\d+$/.test(ta.value.trim())){toast('Enter a whole, non-negative number first.',true);return;}
   ta.value=bitNumberToHex(ta.value.trim());
  }
 } else if(mode==='text'){
  const decoded=hexToStrictText(ta.value); // leaving hex mode, so the box currently holds hex
  if(decoded==null){toast('This value is not valid UTF-8 text - edit it as Hex instead.',true);return;}
  ta.value=decoded;
 } else {
  ta.value=textToHex(ta.value); // leaving text mode, so the box currently holds text
 }
 _vHexState.mode=mode;updateHexTabButtons();
}
const NL = String.fromCharCode(10);
// The two things said when hex turns up in the Text tab. Kept as named constants so the strings
// are built once, out of the way of the save handler - an earlier version inlined one of these
// and a mangled escape inside it took the whole page down.
const HEXPASTE_WHOLE = 'That is a hex value, and this is the Text tab.'
 + NL + NL + 'Saved as Text it would store the characters 0, x, 2, 4... rather than the bytes they stand for.'
 + NL + NL + 'Store it as the bytes instead? (This is what pasting a copied cell is meant to do.)';
const HEXPASTE_MIXED = 'There is a hex value mixed into this text, so nothing was saved.'
 + ' That usually means a paste landed alongside the old value instead of replacing it -'
 + ' select everything in the box before pasting, or use the Hex tab.';
function viewText(title,text,opts){opts=opts||{};$('vTitle').textContent=title;const ta=$('vText');const sel=$('vSelect');const multi=$('vMulti');const dt=$('vDate');const hexTabs=$('vHexTabs');const img=$('vImg');
 if(!window._floatingMaxState||!window._floatingMaxState.mView){const box=$('mView').querySelector('.box');box.style.width=opts.dateType?'380px':'1000px';box.style.maxWidth=opts.dateType?'600px':'95vw';const growable=!opts.options&&!opts.dateType;box.style.height=growable?'640px':'';
  box.style.minHeight=opts.dateType?'0':'';
  box.style.resize=opts.dateType?'none':'';
 }
 ta.style.display='none';sel.style.display='none';multi.style.display='none';dt.style.display='none';hexTabs.style.display='none';img.style.display='none';img.removeAttribute('src');_vHexState=null;setVNote('');
 // Checkbox mode: SET columns, whose valid values are any comma-joined COMBINATION of the
 // column's defined members - unlike ENUM (exactly one value), a single dropdown can't represent
 // that, but a checkbox per member can, mirroring how Heidi/Workbench edit SET data.
 if(opts.multiOptions&&opts.multiOptions.length){
  multi.style.display='block';multi.innerHTML='';
  const cur=new Set((text||'').split(',').filter(s=>s!==''));
  opts.multiOptions.forEach(o=>{
   const lbl=document.createElement('label');lbl.style.cssText='display:flex;align-items:center;gap:6px;padding:3px 2px';
   const cb=document.createElement('input');cb.type='checkbox';cb.value=o;cb.checked=cur.has(o);
   lbl.appendChild(cb);lbl.appendChild(document.createTextNode(o===''?'(empty string)':o));
   multi.appendChild(lbl);
  });
 // Dropdown mode: used for ENUM columns (their real defined values) and tinyint(1) "boolean"
 // columns (treated as a 2-value enum of '0'/'1') - picking from the actual valid values is
 // safer and faster than free-typing, and can't produce an out-of-range value by mistake.
 } else if(opts.options&&opts.options.length){
  sel.style.display='block';sel.innerHTML='';
  opts.options.forEach(o=>{const op=document.createElement('option');op.value=o;op.textContent=(o===''?'(empty string)':o);sel.appendChild(op);});
  sel.value=(text==null?opts.options[0]:text);
 // Native date/datetime/time picker - a real calendar/clock widget instead of guessing at format
 // order, matching Heidi/Workbench. Only reached when editWidgetFor() already confirmed the
 // current value round-trips through it (or the cell is empty), so there's nothing to lose here.
 } else if(opts.dateType){
  dt.type=opts.dateType;dt.style.display='block';
  dt.value=mysqlToNativeDate(text,opts.dateType);
 // BIT column: offer Number/Hex, defaulting to Number (Heidi/Workbench-style) - see the block
 // comment above hexToBitNumber for why this conversion needs no round-trip validity check.
 } else if(opts.bitNumeric){
  ta.style.display='block';hexTabs.style.display='flex';
  $('vTabText').textContent='Number';
  _vHexState={kind:'bitNum',mode:'text'};
  ta.value=hexToBitNumber(text==null?'0x0':text);
  updateHexTabButtons();
 // Binary/BLOB column (not BIT): offer both Text and Hex as explicit edit modes - see the block
 // comment above hexToStrictText for why Text is only ever offered when provably lossless.
 } else if(opts.hexText){
  ta.style.display='block';hexTabs.style.display='flex';
  $('vTabText').textContent='Text';
  const rawHex=(text==null?'0x':text);
  const decoded=hexToStrictText(rawHex);
  _vHexState={kind:'binText',mode:decoded!=null?'text':'hex'};
  ta.value=decoded!=null?decoded:rawHex;
  updateHexTabButtons();
  const bytes=hexToBytes(rawHex);
  if(bytes.length<=MAX_HEXTEXT_BYTES){
   const mime=detectImageMime(bytes);
   if(mime){img.src='data:'+mime+';base64,'+bytesToBase64(bytes);img.style.display='block';}
  }
 } else {
  ta.style.display='block';
  ta.value=(text==null?'':text);ta.readOnly=!!opts.readonly;
  // No Hex tab on this path (an ordinary text column), so this note is the only place the
  // invisible bytes are mentioned at all. A value shown as hex because its bytes could not be
  // read as text takes precedence: what that box holds is saved as text either way, and saying so
  // matters more than counting control characters it does not have.
  setVNote(opts.hexShownAsText
   ? "These bytes are not readable as text in this connection's character set, so they are shown as hex. This column is not a binary one, so what the box holds is saved as text - the characters, not the bytes they spell."
   : ctrlCharNote(ta.value,false));
 }
 const a=$('vActions');a.innerHTML='';const add=(label,cls,fn)=>{const b=document.createElement('button');b.textContent=label;if(cls)b.className=cls;b.onclick=fn;a.appendChild(b);};
 const getVal=()=>{
  if(opts.multiOptions&&opts.multiOptions.length)return [...multi.querySelectorAll('input:checked')].map(cb=>cb.value).join(',');
  if(opts.dateType)return nativeDateToMysql(dt.value,opts.dateType);
  // bitNumeric: both tabs pass their box content straight through unconverted - a plain decimal
  // string goes unquoted via litForCol's existing BIT-integer path, a "0x.." string goes unquoted
  // via lit()'s existing hex-literal passthrough. Neither needs re-encoding here.
  if(opts.bitNumeric)return ta.value;
  if(opts.hexText)return hexCellValueForSave(_vHexState.mode, ta.value);
  return opts.options?sel.value:ta.value;
 };
 if(!opts.options&&!opts.multiOptions&&!opts.dateType){
  add('Copy','',()=>{copyText(ta.value,'Copied to clipboard.',opts.hexText?'Copy it from the Hex tab instead to keep the whole value.':'');});
  // Offer to pretty-print, but only when the content genuinely parses as a JSON object/array -
  // a bare number or quoted string technically "parses" too, but reformatting those does nothing
  // useful, so they're excluded. Not offered for binary/BIT cells - decoded/hex/numeric content
  // is never JSON.
  if(!opts.hexText&&!opts.bitNumeric){
   let isJson=false;try{const p=JSON.parse(ta.value);isJson=(p!==null&&typeof p==='object');}catch(e){}
   if(isJson&&!opts.readonly)add('Format JSON','',()=>{try{ta.value=JSON.stringify(JSON.parse(ta.value),null,2);}catch(e){}});
  }
 }
 if(opts.onNull)add('Set NULL','',()=>{opts.onNull();hide('mView');});
 // Binary cells are checked before anything is written, and nothing here can save a value that
// would store the characters of a hex dump in place of the bytes they denote. Two blobs in a real
// database were lost that way, twice over, so there is deliberately no "save it anyway": the two
// outcomes are the correct value or nothing at all.
//
//   Hex mode  - the box must actually hold hex. normalizeHexInput accepts spaces, line breaks and
//               a missing 0x, so a value copied from Workbench's hex view works, but anything it
//               cannot read is refused rather than quietly padded with zero bytes.
//   Text mode - Text runs textToHex() over the whole box, so a hex value here becomes its own
//               characters. If the box is ENTIRELY hex the intent is not in doubt and it is
//               offered as bytes, which is what pasting a copied cell is meant to do. If hex is
//               merely mixed INTO the text, a paste has landed alongside the old value and there
//               is no way to know which part was wanted - so nothing is saved.
if(opts.onSave)add('Save','go',async()=>{
 if(opts.hexText&&_vHexState){
  if(_vHexState.mode==='hex'&&normalizeHexInput(ta.value)===null){
   toast('That is not a usable hex value. Expected hex digits, optionally 0x-prefixed, an even number of them - spaces and line breaks are fine.',true);return;
  }
  if(_vHexState.mode==='text'&&looksLikePastedHex(ta.value)){
   const whole=normalizeHexInput(ta.value);
   if(whole!==null){
    if(!(await ask(HEXPASTE_WHOLE)))return;
    _vHexState.mode='hex';ta.value=whole;updateHexTabButtons();
   } else {
    toast(HEXPASTE_MIXED,true);return;
   }
  }
 }
 opts.onSave(getVal());hide('mView');
});
 add('Close','',()=>hide('mView'));
 show('mView');setTimeout(()=>{if(opts.multiOptions){}else if(opts.options){sel.focus();}else if(opts.dateType){dt.focus();}else if(!opts.readonly){ta.focus();}},60);}
// Column type info, fetched once per table (lazily, only when the user actually starts editing
// a cell there) and cached on the tab, so browsing/running queries never pays this extra cost -
// only editing a table-backed result does.
async function getColType(id,colName){
 const t=T(id);if(!t||!t.table)return null;
 if(!t.colTypes){
  t.colTypes={};
  try{
   const r=await api('/api/query',{sql:"SELECT COLUMN_NAME, COLUMN_TYPE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA="+lit(dbOf(t))+" AND TABLE_NAME="+lit(t.table)});
   if(r.ok)r.rows.forEach(row=>{t.colTypes[row[0]]=row[1];});
  }catch(e){}
 }
 return t.colTypes[colName]||null;
}
// Parses MySQL's enum('a','b','c') or set('a','b','c') column-type text into the actual list of
// values - both share the exact same parenthesized-quoted-list syntax. Values can contain commas
// and escaped quotes (enum('a,b','c''d')), so this can't just split on ',' - it walks the string
// tracking whether it's currently inside a quoted value.
function parseQuotedOptionList(colType){
 const m=colType.match(/^(?:enum|set)\((.*)\)$/i);if(!m)return [];
 const out=[];let cur='',inQ=false;
 for(let i=0;i<m[1].length;i++){
  const c=m[1][i];
  if(inQ){
   if(c==="'"&&m[1][i+1]==="'"){cur+="'";i++;continue;}
   if(c==="'"){inQ=false;continue;}
   cur+=c;
  } else {
   if(c==="'"){inQ=true;continue;}
   if(c===','){out.push(cur);cur='';continue;}
  }
 }
 out.push(cur);
 return out;
}
// Picks the right editing widget for a column - a single-select dropdown of its real defined
// values for ENUM (typos aren't possible), a checkbox per member for SET (its value is any
// comma-joined COMBINATION of members, which a single dropdown can't represent), the same
// 2-value on/off dropdown as ENUM for tinyint(1)/BOOLEAN, a native date/time picker for DATE/
// DATETIME/TIMESTAMP/TIME (matching Heidi/Workbench's calendar widget instead of guessing at
// format order) - or nothing (plain free text) for everything else. Shared by editCell (existing
// rows) and editIns (new rows) so both get the same picker instead of only already-saved rows.
// curVal is needed only for the date/time case: the picker is offered exclusively when the
// CURRENT value actually round-trips through it (see mysqlToNativeDate), so a legacy zero-date
// or other value it can't represent falls back to plain text instead of risking Save silently
// discarding it the moment the dialog opens.
// Unlike the Editor (which has real per-column binary/BIT flags from the server's own result-set
// metadata - see bitCols/binaryCols in main.rs), this PS backend shells out to mysql.exe and has
// no equivalent metadata channel to hand back per query. So BIT/binary detection here goes
// entirely through getColType()'s already-existing information_schema.COLUMNS lookup (same
// mechanism ENUM/SET/tinyint(1)/date detection already uses) instead of a flag on the row data -
// which works for exactly the case that matters (an editable, table-bound grid always has a real
// column to look up), plus the same value-shape fallback ("looks like 0x...") the rest of this
// app already uses for a column whose declared type doesn't say binary but whose value does.
async function editWidgetFor(id,colName,curVal){
 const colType=await getColType(id,colName);
 if(colType&&/^enum\(/i.test(colType))return {options:parseQuotedOptionList(colType)};
 if(colType&&/^set\(/i.test(colType))return {multiOptions:parseQuotedOptionList(colType)};
 if(colType&&/^tinyint\(1\)/i.test(colType))return {options:['0','1']};
 let dateType=null;
 if(colType&&/^date$/i.test(colType))dateType='date';
 else if(colType&&/^(datetime|timestamp)/i.test(colType))dateType='datetime-local';
 else if(colType&&/^time/i.test(colType))dateType='time';
 // The picker is only safe for a value it can hand back unchanged. This used to ask merely
 // whether the conversion produced SOMETHING, which is not the same thing: a DATETIME(6) of
 // 2024-01-01 12:34:56.123456 converts happily to 2024-01-01T12:34:56, and saving that back
 // dropped the fractional seconds without a word. Same for TIME(3). Require a real round trip -
 // anything that does not survive one falls through to the plain text editor, where it is edited
 // exactly as stored. That is what the comment below has always claimed; now it is true.
 if(dateType&&(curVal==null||curVal==='')) return {dateType};
 if(dateType){
  const native=mysqlToNativeDate(curVal,dateType);
  if(native&&nativeDateToMysql(native,dateType)===String(curVal)) return {dateType};
 }
 // BIT columns get their own Number/Hex toggle (Heidi/Workbench show these as a plain numeric
 // value, not a byte dump) - see the block comment above hexToBitNumber.
 if(colType&&/^bit\(/i.test(colType))return {bitNumeric:true};
 // True binary/BLOB columns (not BIT) always render as "0x.." hex; offering a Text tab too lets
 // you type/read things like bcrypt hashes or tokens directly instead of hand-converting to hex,
 // while Hex stays available (and is all that's offered) for genuinely non-text bytes like images.
 const flaggedBinary=colType&&/^(binary|varbinary|(tiny|medium|long)?blob)\b/i.test(colType);
 const mode=binaryEditMode(flaggedBinary,curVal);
 if(mode==='hex')return {hexText:true};
 if(mode==='hexShownAsText')return {hexShownAsText:true};
 return {};
}
// Which editor a value gets once ENUM/SET/date are out of the way. The byte editor - the Text/Hex
// tabs, whose Save writes a hex literal - is offered only for a column the server itself calls
// binary, because that is the same thing the WRITE path asks: litAs() quotes for any column
// binCols does not flag, so a value edited as bytes in a column that is not binary would be stored
// as the characters of its hex, and would read back looking much like it did before.
//
// A column that is not declared binary can still arrive here as "0x.." hex all the same: the
// backend hex-encodes any value whose bytes fail a UTF-8 decode, whatever the column (a legacy
// non-UTF8 hash in a VARCHAR is the real example). Such a value used to get the byte editor too,
// which is the disagreement above. It now gets a plain text box, matching what will actually be
// stored, and the box says so rather than leaving the hex looking like something it is not - the
// value is only readable as hex, but this column holds text and text is what a save writes.
function binaryEditMode(flaggedBinary,v){
 if(flaggedBinary)return 'hex';
 if(typeof v==='string'&&/^0x[0-9A-Fa-f]+$/.test(v))return 'hexShownAsText';
 return null;
}
async function editCell(td,id,ri,ci){clearTimeout(clickTimer);const t=T(id);const key=ri+':'+ci;const cur=(key in t.pending.upd)?t.pending.upd[key]:t.rows[ri][ci];
 const ew=await editWidgetFor(id,t.cols[ci],cur);
 viewText('Cell - '+t.cols[ci]+(cur===null?'  (currently NULL)':''),cur,{onSave:v=>setUpd(id,ri,ci,v),onNull:()=>setUpd(id,ri,ci,null),...ew});}
function setUpd(id,ri,ci,v){const t=T(id);if(!t.pending){toast('This result is not editable (no primary key detected).',true);return;}if(v===null&&t.pk&&t.pk.indexOf(t.cols[ci])>=0){toast('Column "'+t.cols[ci]+'" is part of the primary key and cannot be set to NULL.',true);return;}const key=ri+':'+ci;if(v===t.rows[ri][ci])delete t.pending.upd[key];else t.pending.upd[key]=v;renderGrid(id);}
let clickTimer=null;
let gridFocus={}; // per-tab: {ri, ci} of the currently keyboard-focused cell
function gridCellEl(id,ri,ci){const t=T(id);const wrap=$('res_'+id);if(!wrap||!t)return null;const off=(!!t.pk)?2:1;
 let tr=wrap.querySelector('tr[data-r="'+ri+'"]');
 if(!tr){
  const view=viewIndices(id);const pos=view.indexOf(ri);
  if(pos>=0){const rowH=t._rowH||23;wrap.scrollTop=Math.max(0,pos*rowH-rowH*4);renderBody(id);tr=wrap.querySelector('tr[data-r="'+ri+'"]');}
 }
 if(!tr)return null;return tr.children[ci+off]||null;}
function gridSetFocus(id,ri,ci,scroll){const t=T(id);if(!t)return;const view=viewIndices(id);if(view.indexOf(ri)<0)return;
 const old=gridFocus[id];if(old){const oe=gridCellEl(id,old.ri,old.ci);if(oe)oe.classList.remove('kbfocus');}
 gridFocus[id]={ri,ci};const el=gridCellEl(id,ri,ci);if(el){el.classList.add('kbfocus');if(scroll!==false)el.scrollIntoView({block:'nearest',inline:'nearest'});el.focus({preventScroll:true});}}
function gridClearFocus(id){const old=gridFocus[id];if(old){const oe=gridCellEl(id,old.ri,old.ci);if(oe)oe.classList.remove('kbfocus');}delete gridFocus[id];}
function gridKeyNav(id,e){const t=T(id);if(!t||!t.pk)return;const f=gridFocus[id];
 const view=viewIndices(id);
 if(!f){ if(['ArrowDown','ArrowUp','ArrowLeft','ArrowRight','Tab'].includes(e.key) && view.length){e.preventDefault();gridSetFocus(id,view[0],0);} return; }
 let {ri,ci}=f; const rowPos=view.indexOf(ri); if(rowPos<0)return;
 const nCols=t.cols.length;
 if(e.key==='ArrowDown'){e.preventDefault();if(rowPos<view.length-1)gridSetFocus(id,view[rowPos+1],ci);}
 else if(e.key==='ArrowUp'){e.preventDefault();if(rowPos>0)gridSetFocus(id,view[rowPos-1],ci);}
 else if(e.key==='ArrowLeft'){e.preventDefault();if(ci>0)gridSetFocus(id,ri,ci-1);}
 else if(e.key==='ArrowRight'){e.preventDefault();if(ci<nCols-1)gridSetFocus(id,ri,ci+1);}
 else if(e.key==='Tab'){e.preventDefault();if(e.shiftKey){if(ci>0)gridSetFocus(id,ri,ci-1);else if(rowPos>0)gridSetFocus(id,view[rowPos-1],nCols-1);}
   else{if(ci<nCols-1)gridSetFocus(id,ri,ci+1);else if(rowPos<view.length-1)gridSetFocus(id,view[rowPos+1],0);}}
 else if(e.key==='Enter'||e.key==='F2'){e.preventDefault();const el=gridCellEl(id,ri,ci);if(el)inlineEdit(el,id,ri,ci);}
 else if(e.key==='Escape'){gridClearFocus(id);}
}
// No delay/timer here to disambiguate a single click from the first click of a double-click - the
// "if input already present" guard already makes a second click a no-op, and a genuine
// double-click's dblclick handler (editCell/editIns) opens the full modal regardless of whether an
// inline edit is mid-flight, so waiting around just made the tint feel laggy for no real benefit.
function cellClick(td,id,ri,ci){if(td.querySelector('input'))return;inlineEdit(td,id,ri,ci);}
function insClick(td,id,ii,col){if(td.querySelector('input'))return;inlineEditIns(td,id,ii,col);}
// Reverts a single cell back to its plain display markup - same output renderBody would have
// produced for it, but touching only this one <td> instead of tearing down and rebuilding the
// entire grid. Discarding an inline edit (Escape, or blur with nothing typed) used to call the
// full renderGrid(id), and its blur path in particular runs after a 120ms delay - long enough that
// clicking straight into a DIFFERENT cell to start editing it, then having this cell's delayed
// "nothing changed" cleanup fire afterward, would wipe out that other cell's fresh inline editor
// out from under the user (intermittently, depending on exact timing) since a full grid rebuild
// regenerates every cell from persisted state, and a not-yet-committed inline edit isn't part of
// that state. Reverting only the one cell that actually needs reverting avoids the whole class of
// race entirely.
function cellRevert(td,id,ri,ci){const t=T(id);const key=ri+':'+ci;const pend=t.pending&&(key in t.pending.upd);const val=pend?t.pending.upd[key]:t.rows[ri][ci];
 td.className='editable'+(pend?' dirty':'');td.title=String(clip(val,300));td.innerHTML=cellHtml(val,t.bitCols&&t.bitCols[ci],t.binCols&&t.binCols[ci]);}
function insCellRevert(td,id,ii,col){const t=T(id);const v=t.pending.ins[ii][col];const ci=t.cols.indexOf(col);
 td.className='editable';td.title=(v===undefined?'undefined':String(v));td.innerHTML=cellHtml(v===undefined?null:v,t.bitCols&&t.bitCols[ci],t.binCols&&t.binCols[ci]);}
async function inlineEdit(td,id,ri,ci){const t=T(id);const key=ri+':'+ci;const cur=(key in t.pending.upd)?t.pending.upd[key]:t.rows[ri][ci];
 // Enum/boolean columns always go through editCell's dropdown - a plain inline text input would
 // let you type a value the column can't actually hold, which the double-click path already avoids.
 const colType=await getColType(id,t.cols[ci]);
 if(colType&&(/^enum\(/i.test(colType)||/^tinyint\(1\)/i.test(colType))){editCell(td,id,ri,ci);return;}
 // A value with embedded newlines used to jump straight to the big modal on a single click, which
 // read as "one click opened the double-click editor" - it's a plain multi-line <textarea> inline
 // instead now, sized to roughly fit the existing line count; the big modal is still one
 // double-click away for anything that genuinely needs more room.
 const isMulti=cur!=null&&/[\r\n]/.test(String(cur));
 // No inp.select() here on purpose - auto-selecting the whole value made entering edit mode look
 // like a big blue highlight box instead of just dropping into the text, so the cursor is placed
 // at the end of the existing value instead (still lets you type to replace via Home+shift, etc).
 td.classList.add('cellEditing');td.innerHTML=(isMulti?'<textarea rows="'+Math.min(8,Math.max(2,String(cur).split(/\r\n|\r|\n/).length))+'"></textarea>':'<input>')+'<button tabindex="-1" title="Set NULL" style="padding:0 4px">&empty;</button>';const inp=td.querySelector(isMulti?'textarea':'input');const nb=td.querySelector('button');inp.value=(cur===null?'':cur);inp.focus();const vlen=inp.value.length;inp.setSelectionRange(vlen,vlen);let done=false,dirty=false;
 const set=v=>{done=true;setUpd(id,ri,ci,v);};
 inp.addEventListener('input',()=>dirty=true);
 nb.addEventListener('mousedown',e=>{e.preventDefault();set(null);});
 // A plain Enter commits for a single-line input, but inserts a newline (as it always does in a
 // textarea) for the multi-line case - Ctrl/Cmd+Enter commits there instead, same convention as
 // "Run Query Selection" elsewhere in the app.
 inp.addEventListener('keydown',e=>{if(e.key==='Enter'&&(!isMulti||e.ctrlKey||e.metaKey)){e.preventDefault();if(dirty)set(inp.value);else{done=true;cellRevert(td,id,ri,ci);}}else if(e.key==='Escape'){done=true;cellRevert(td,id,ri,ci);}});
 inp.addEventListener('blur',()=>setTimeout(()=>{if(!done){if(dirty)set(inp.value);else cellRevert(td,id,ri,ci);}},120));}
function inlineEditIns(td,id,ii,col){const t=T(id);const cur=t.pending.ins[ii][col];
 const isMulti=cur!=null&&/[\r\n]/.test(String(cur));
 td.classList.add('cellEditing');td.innerHTML=(isMulti?'<textarea rows="'+Math.min(8,Math.max(2,String(cur).split(/\r\n|\r|\n/).length))+'"></textarea>':'<input>')+'<button tabindex="-1" style="padding:0 4px" title="Set NULL">&empty;</button>';const inp=td.querySelector(isMulti?'textarea':'input');const nb=td.querySelector('button');inp.value=(cur==null?'':cur);inp.focus();let done=false,dirty=false;
 const set=v=>{done=true;t.pending.ins[ii][col]=v;renderGrid(id);};
 inp.addEventListener('input',()=>dirty=true);
 nb.addEventListener('mousedown',e=>{e.preventDefault();set(null);});
 inp.addEventListener('keydown',e=>{if(e.key==='Enter'&&(!isMulti||e.ctrlKey||e.metaKey)){e.preventDefault();if(dirty)set(inp.value);else{done=true;insCellRevert(td,id,ii,col);}}else if(e.key==='Escape'){done=true;insCellRevert(td,id,ii,col);}});
 inp.addEventListener('blur',()=>setTimeout(()=>{if(!done){if(dirty)set(inp.value);else insCellRevert(td,id,ii,col);}},120));}
function cellMenu(e,id,ri,ci){e.preventDefault();const t=T(id);const key=ri+':'+ci;const cur=(t.pending&&(key in t.pending.upd))?t.pending.upd[key]:t.rows[ri][ci];const items=[['Copy value',()=>{copyText(cellCopyValue(cur),'Copied cell value.','Use "Copy value as hex" to keep the whole value.');}],['Copy value as hex',()=>{clipWrite(cur===null?'':String(cur));log('Copied cell value as hex.');}],['Copy row',()=>copyRow(id,ri)],['Copy rows (selected)',()=>copySelRows(id)],['Paste row here (overwrite)',()=>pasteRowInto(id,ri)],['Paste rows as new',()=>pasteRowsAsNew(id)],['Copy column: '+t.cols[ci],()=>copyColumn(id,ci)],['Edit full row (form)...',()=>rowForm(id,ri)],'-'];if(t.table){const col=t.cols[ci];items.push(['Quick filter',qfSub(id,col,cur)]);if(t.filterClauses&&t.filterClauses.length)items.push(['Clear filter ('+t.filterClauses.length+')',()=>clearFilters(id)]);
  const fkd=(t.fkDetails||[]).find(f=>f[0]===col);
  if(fkd&&cur!=null){items.push(['Go to referenced row ('+fkd[1]+'.'+fkd[2]+')',()=>goToFkRow(t.db,fkd[1],fkd[2],cur)]);}
  items.push('-');}items.push(['Export to CSV (all rows)...',()=>csvGrid(id)],['Export to CSV (selected rows)...',()=>csvSel(id)],['Export to INSERTs (all rows)...',()=>insGrid(id)],['Export to INSERTs (selected rows)...',()=>insSel(id)],'-',['Set NULL',()=>setUpd(id,ri,ci,null)],['Set empty',()=>setUpd(id,ri,ci,'')]);menu(e.clientX,e.clientY,items);}
// The condition goes in as the tab's filter: openRun() rebuilds the query from the table and its
// filters, so a WHERE written into the tab's SQL was dropped and the whole table came up. The
// value is written for the column's type, so an empty binary key (0x) and a text key that looks
// like hex both find their row.
async function goToFkRow(db,refTable,refCol,val){
 const bc=await tableBinCols(db,refTable,[refCol]);
 const cond=qid(refCol)+'='+litAs(val,bc?bc[0]:null);
 const _i=openTab(refTable+' (FK: '+refCol+'='+val+')','SELECT * FROM '+qid(db)+'.'+qid(refTable)+' WHERE '+cond+';',db,false,refTable);
 T(_i).filterClauses=[cond];
 await openRun(_i);
}
// The Windows clipboard's text format ends at the first NUL. Copying "a<NUL>b" puts "a" on it and
// drops the rest, and the Clipboard API still reports success - measured: a three-character value
// arrived as one. Nothing here can carry a NUL through it, so what this does is stop calling that
// "Copied" when most of the value was left behind. Only NUL truncates; other control characters
// travel fine.
function clipboardCutMsg(s){
 const str=(s==null?'':String(s));const i=str.indexOf(String.fromCharCode(0));
 if(i<0)return '';
 const lost=str.length-i;
 return 'The clipboard cannot carry a NUL, so it stops at the first one: '+lost+' character'+(lost>1?'s':'')+' not copied.';
}
// Every clipboard write in the app goes through this, so none of them can quietly hand over a
// truncated value. A toast rather than a log line when something was lost: a log line is easy to
// miss, and the difference between what is in the cell and what is now on the clipboard is not.
function clipWrite(text,alsoTry){
 const s=(text==null?'':String(text));
 return navigator.clipboard.writeText(s).then(()=>{
  const cut=clipboardCutMsg(s);
  if(!cut)return 'ok';
  const full=cut+(alsoTry?' '+alsoTry:'');
  toast(full,true);log(full);
  return 'cut';
 },err=>{
  // A refused write (no focus, no permission) used to be reported as a successful copy, because
  // nothing was watching the promise. Whatever else happens, the clipboard does not now hold what
  // the user was told it holds.
  toast('Could not copy to the clipboard: '+err,true);log('Copy failed: '+err);
  return 'failed';
 });
}
// For the copies that have something useful to suggest instead. Their own "Copied ..." line is
// skipped when the value was cut, because it would be describing something that did not happen.
function copyText(text,okMsg,alsoTry){
 return clipWrite(text,alsoTry).then(st=>{ if(st==='ok')log(okMsg); return st; });
}
function copyRow(id,ri){const t=T(id);const vals=t.cols.map((c,ci)=>{const key=ri+':'+ci;return (t.pending&&(key in t.pending.upd))?t.pending.upd[key]:t.rows[ri][ci];});window._rowClipboard=vals;copyText(vals.map(v=>v===null?'':v).join('\t'),'Copied 1 row (TSV, '+t.cols.length+' column(s)).','Pasting it back into this app is unaffected - the row is kept as it is.');}
function copySelRows(id){const t=T(id);const idxs=viewIndices(id).filter(ri=>t.selected&&t.selected.has(ri));if(!idxs.length){toast('No rows selected. Tick the checkboxes on the rows you want.',true);return;}const rowsData=idxs.map(ri=>t.cols.map((c,ci)=>{const key=ri+':'+ci;return (t.pending&&(key in t.pending.upd))?t.pending.upd[key]:t.rows[ri][ci];}));window._rowsClipboard=rowsData;const lines=rowsData.map(vals=>vals.map(v=>v===null?'':v).join('\t'));copyText(lines.join('\n'),'Copied '+idxs.length+' row(s) (TSV, '+t.cols.length+' column(s)).','Pasting them back into this app is unaffected - the rows are kept as they are.');}
// "Copy row" and "Copy rows (selected)" write to two separate clipboards (single row vs a
// list), since pasting several rows only makes sense as new rows, never as an overwrite of one
// target row - but a single-row paste shouldn't care which command put that one row there.
// Falls back to _rowsClipboard when it holds exactly one row and _rowClipboard is empty/stale.
function singleRowClipboard(){if(window._rowClipboard&&window._rowClipboard.length)return window._rowClipboard;if(window._rowsClipboard&&window._rowsClipboard.length===1)return window._rowsClipboard[0];return null;}
// Distinguishes "nothing copied" from "multiple rows copied" for the two single-row-target paste
// spots below - both used to show the same "Copy a row first" message for either case, which is
// actively misleading when rows genuinely were copied, just more than the one this paste can use.
function noSingleRowMsg(target){const n=window._rowsClipboard&&window._rowsClipboard.length;if(n>1)return 'You copied '+n+' rows - overwrite can only use one. Copy just the row you want, or use "Paste rows as new" instead.';return 'Copy a row first, then right-click a '+target+' row to paste it.';}
function pasteRowInto(id,ri){const t=T(id);if(!t.pk){toast('This result is not editable (no primary key).',true);return;}const vals=singleRowClipboard();if(!vals||!vals.length){toast(noSingleRowMsg('target'),true);return;}if(vals.length!==t.cols.length){toast('Copied row has '+vals.length+' column(s) but this table has '+t.cols.length+'. Cannot paste.',true);return;}
 t.cols.forEach((c,ci)=>{if(t.pk.indexOf(c)>=0)return;const v=vals[ci];const key=ri+':'+ci;if(v===t.rows[ri][ci])delete t.pending.upd[key];else t.pending.upd[key]=v;});
 renderGrid(id);log('Pasted copied row into row '+(ri+1)+' (primary key column(s) left unchanged). Review and click Apply to commit.');}
// Mirror image of singleRowClipboard() above: "Copy row" (singular) only ever fills
// _rowClipboard, so pasting-as-new after copying exactly one row that way needs the same
// fallback the single-row overwrite paste already got, or it wrongly says nothing was copied.
function rowsClipboard(){if(window._rowsClipboard&&window._rowsClipboard.length)return window._rowsClipboard;if(window._rowClipboard&&window._rowClipboard.length)return [window._rowClipboard];return null;}
function pasteRowsAsNew(id){const t=T(id);if(!t.pending){toast('This result is not editable (no primary key detected).',true);return;}const rowsData=rowsClipboard();if(!rowsData||!rowsData.length){toast('Copy some rows first (Copy rows (selected)), then paste them as new rows.',true);return;}const bad=rowsData.find(vals=>vals.length!==t.cols.length);if(bad){toast('Copied row(s) have a different number of columns than this table. Cannot paste.',true);return;}rowsData.forEach(vals=>{const obj={};t.cols.forEach((c,ci)=>{obj[c]=vals[ci];});t.pending.ins.push(obj);});renderGrid(id);log('Pasted '+rowsData.length+' row(s) as new rows. Review and click Apply to commit.');}
function copyColumn(id,ci){const t=T(id);const vals=t.rows.map((row,ri)=>{const key=ri+':'+ci;return (t.pending&&(key in t.pending.upd))?t.pending.upd[key]:row[ci];});copyText(vals.map(v=>v===null?'':v).join('\n'),'Copied '+vals.length+' value(s) from column "'+t.cols[ci]+'".');}
// The comparisons are built when picked, with the value written for the column's type (see litAs):
// lit() alone turned an empty binary value into the text '0x' and a text value like 0x41 into a
// byte, so the filter found nothing, or the wrong rows.
function qfSub(id,col,val){const q=qid(col);const lv=lit(val);
 const cmp=op=>async()=>{const bc=await gridBinCols(id);const ci=T(id).cols.indexOf(col);await addFilterClause(id,q+' '+op+' '+litAs(val,bc&&ci>=0?bc[ci]:null));};const esc=s=>String(s).replace(/([%_\\])/g,'\\$1').replace(/'/g,"''");const sub=[];
 if(val===null){sub.push([q+' IS NULL',()=>addFilterClause(id,q+' IS NULL')]);sub.push([q+' IS NOT NULL',()=>addFilterClause(id,q+' IS NOT NULL')]);return sub;}
 const sv=String(val).trim();const isNum=/^-?\d+(\.\d+)?$/.test(sv);const isDate=/^\d{4}-\d{2}-\d{2}([ T]\d{2}:\d{2}(:\d{2})?)?$/.test(sv);
 const like=String(val);const ld=(like.length>16?like.slice(0,16)+'\u2026':like);
 // display value for =/!= labels: truncated for readability; the actual filter still uses the full value (lv)
 const lvd="'"+(sv.length>16?sv.slice(0,16)+'\u2026':sv)+"'";const dv=isNum?lv:lvd;
 sub.push([q+' = '+dv,cmp('=')]);sub.push([q+' != '+dv,cmp('<>')]);
 if(isNum||isDate){sub.push('-');sub.push([q+' > '+dv,cmp('>')]);sub.push([q+' >= '+dv,cmp('>=')]);sub.push([q+' < '+dv,cmp('<')]);sub.push([q+' <= '+dv,cmp('<=')]);}
 if(!isNum){sub.push('-');sub.push([q+" LIKE '%"+ld+"%'",()=>addFilterClause(id,q+" LIKE '%"+esc(like)+"%'")]);sub.push([q+" LIKE '"+ld+"%'",()=>addFilterClause(id,q+" LIKE '"+esc(like)+"%'")]);if(!isDate)sub.push([q+" LIKE '%"+ld+"'",()=>addFilterClause(id,q+" LIKE '%"+esc(like)+"'")]);}
 sub.push('-');sub.push([q+' IS NULL',()=>addFilterClause(id,q+' IS NULL')]);sub.push([q+' IS NOT NULL',()=>addFilterClause(id,q+' IS NOT NULL')]);return sub;}
// Adds one more ANDed condition to the table tab's active quick filter (does not replace the
// existing ones) - lets right-clicking two different cells build up a compound WHERE, matching
// how Heidi's quick-filter stacking works. Re-picking the exact same condition is a no-op.
async function addFilterClause(id,clause){const t=T(id);if(!t.filterClauses)t.filterClauses=[];if(t.filterClauses.includes(clause))return;t.filterClauses.push(clause);await openRun(id);log('Filter: '+t.filterClauses.join(' AND '));}
async function clearFilters(id){const t=T(id);t.filterClauses=[];await openRun(id);log('Filter cleared.');}
function combinedFilterWhere(t){return (t.filterClauses&&t.filterClauses.length)?t.filterClauses.join(' AND '):null;}
function updateFilterBar(id){const t=T(id);const st=$('st_'+id);if(!st)return;const w=combinedFilterWhere(t);st.title=w?('WHERE '+w):'';}
let _rf=null;
function rowForm(id,ri){const t=T(id);_rf={id:id,ri:ri};$('rfTitle').textContent='Edit row'+(t.table?(' - '+t.table):'');const box=$('rfFields');box.innerHTML='';
 t.cols.forEach((c,ci)=>{const key=ri+':'+ci;const cur=(t.pending&&(key in t.pending.upd))?t.pending.upd[key]:t.rows[ri][ci];
  const w=document.createElement('div');w.style.display='flex';w.style.alignItems='flex-start';w.style.gap='8px';w.style.margin='4px 0';
  const lb=document.createElement('label');lb.textContent=c+(t.pk&&t.pk.indexOf(c)>=0?' (PK)':'');lb.style.width='170px';lb.style.flex='0 0 170px';lb.style.fontSize='12px';lb.style.textAlign='right';lb.style.paddingTop='5px';lb.style.color='var(--muted)';lb.style.overflow='hidden';lb.style.textOverflow='ellipsis';
  const ta=document.createElement('textarea');ta.id='rf_'+ci;ta.value=(cur===null?'':cur);ta.rows=(cur!=null&&String(cur).length>60)?3:1;ta.style.flex='1';ta.style.fontFamily='"Cascadia Code",Consolas,"SF Mono",Menlo,"DejaVu Sans Mono",monospace';ta.style.fontSize='12px';ta.dataset.null=(cur===null)?'1':'';
  ta.oninput=()=>{ta.dataset.null='';};
  const nb=document.createElement('button');nb.className='sm';nb.textContent='NULL';nb.title='Set this field to NULL';nb.onclick=()=>{ta.value='';ta.dataset.null='1';};
  w.appendChild(lb);w.appendChild(ta);w.appendChild(nb);box.appendChild(w);});
 show('mRowForm');}
function rfSave(){if(!_rf)return;const t=T(_rf.id),ri=_rf.ri;if(!t.pending){hide('mRowForm');_rf=null;toast('This result is not editable (no primary key detected) - nothing was saved.',true);return;}t.cols.forEach((c,ci)=>{const ta=$('rf_'+ci);if(!ta)return;const v=(ta.dataset.null==='1')?null:ta.value;const orig=t.rows[ri][ci];const key=ri+':'+ci;if(v===orig){if(t.pending&&key in t.pending.upd)delete t.pending.upd[key];}else{if(v===null&&t.pk&&t.pk.indexOf(t.cols[ci])>=0){/* skip PK->null */}else if(t.pending){t.pending.upd[key]=v;}}});hide('mRowForm');renderGrid(_rf.id);_rf=null;}
function toggleDel(id,ri){const t=T(id);if(t.pending.del.has(ri))t.pending.del.delete(ri);else t.pending.del.add(ri);renderGrid(id);}
function deleteSel(id){const t=T(id);if(!t.pk){toast('This result is not editable (no primary key).',true);return;}const ids=[...(t.selected||[])];if(!ids.length){toast('No rows selected. Tick the checkboxes on the rows you want.',true);return;}ids.forEach(ri=>t.pending.del.add(ri));renderGrid(id);log(ids.length+' row(s) marked for deletion - click Apply to commit.');}
function addRow(id){const t=T(id);t.pending.ins.push({});renderGrid(id);}
function delIns(id,ii){const t=T(id);t.pending.ins.splice(ii,1);renderGrid(id);}
async function editIns(td,id,ii,col){clearTimeout(clickTimer);const t=T(id);const cur=t.pending.ins[ii][col];
 const ew=await editWidgetFor(id,col,cur);
 viewText('New row - '+col,(cur==null?'':cur),{onSave:v=>{t.pending.ins[ii][col]=v;renderGrid(id);},onNull:()=>{t.pending.ins[ii][col]=null;renderGrid(id);},...ew});}
function insCellMenu(e,id,ii,col){e.preventDefault();const t=T(id);const cur=t.pending.ins[ii][col];
 const items=[['Copy value',()=>{clipWrite(cellCopyValue(cur));log('Copied value.');}],
  ['Paste row into this new row',()=>pasteRowIntoIns(id,ii)],
  ['Edit value...',()=>editIns(null,id,ii,col)],'-',
  ['Set NULL',()=>{t.pending.ins[ii][col]=null;renderGrid(id);}],
  ['Set empty',()=>{t.pending.ins[ii][col]='';renderGrid(id);}],'-',
  ['Delete this new row',()=>delIns(id,ii)]];
 menu(e.clientX,e.clientY,items);}
function pasteRowIntoIns(id,ii){const t=T(id);const vals=singleRowClipboard();if(!vals||!vals.length){toast(noSingleRowMsg('new'),true);return;}if(vals.length!==t.cols.length){toast('Copied row has '+vals.length+' column(s) but this table has '+t.cols.length+'. Cannot paste.',true);return;}
 t.cols.forEach((c,ci)=>{t.pending.ins[ii][c]=vals[ci];});
 renderGrid(id);log('Pasted copied row into new row. Review and click Apply to commit.');}
function revertChanges(id){const t=T(id);t.pending={upd:{},del:new Set(),ins:[]};renderGrid(id);}
async function applyChanges(id){if(roBlock())return;const t=T(id);const S=[];const tbl=qid(t.db)+'.'+qid(t.table);
 const bc=await gridBinCols(id);
 // Screened before any SQL is built, so a bad paste writes nothing at all rather than part of a
 // batch. Covers inline cell edits and new rows alike - the grid is the other way into a binary
 // column, and the value editor's guard never sees it.
 if(!t.exact){
  const n=await tableNulTextCount(t.db,t.table);
  if(n!==0){
   toast(n==null?'Nothing was saved: could not check '+t.db+'.'+t.table+' for text values holding a NUL byte.'
    :'Nothing was saved. '+fmtCount(n)+' row(s) of '+t.db+'.'+t.table+' hold a NUL byte inside a text value, and this grid could not be read exactly, so a row could be mistaken for another. Run the table again from the tree and make the change there.',true);
   return;
  }
 }
 const badPaste=pastedHexColumns(t);
 if(badPaste.length){
  toast('Nothing was saved. A hex value is mixed into other content in: '+badPaste.join(', ')
   +'\n\nThat usually means a paste landed alongside what was already in the cell instead of replacing it.'
   +' Select the whole cell before pasting, or clear it first.',true);
  return;
 }
 // updates grouped by row
 const kt=await tableColTypes(t.db,t.table);let noKey=false;
 const byRow={};Object.keys(t.pending.upd).forEach(k=>{const[ri,ci]=k.split(':').map(Number);(byRow[ri]=byRow[ri]||{})[ci]=t.pending.upd[k];});
 Object.keys(byRow).forEach(ri=>{ri=+ri;const sets=Object.keys(byRow[ri]).map(ci=>qid(t.cols[ci])+'='+litAs(byRow[ri][ci],bc?bc[ci]:null));
   const wh=keyWhere(t,ri,bc,kt);if(wh==null){noKey=true;return;}S.push(oneRowGuard(tbl,wh));S.push('UPDATE '+tbl+' SET '+sets.join(',')+' WHERE '+wh+' LIMIT 1;');});
 t.pending.del.forEach(ri=>{const wh=keyWhere(t,ri,bc,kt);if(wh==null){noKey=true;return;}S.push(oneRowGuard(tbl,wh));S.push('DELETE FROM '+tbl+' WHERE '+wh+' LIMIT 1;');});
 if(noKey){toast('Nothing was saved: the result does not include every key column ('+t.pk.join(', ')+'), so the rows cannot be found exactly. Include the key in the query.',true);return;}
 t.pending.ins.forEach(row=>{const cols=Object.keys(row);if(!cols.length)return;S.push('INSERT INTO '+tbl+' ('+cols.map(qid).join(',')+') VALUES ('+cols.map(c=>litAs(row[c],bc?bc[t.cols.indexOf(c)]:null)).join(',')+');');});
 // A BIT or binary column round-trips as 0x..., and lit() passes that through unquoted. Anything
 // else is quoted, and MySQL then stores the BYTES of the text: typing 8 into a BIT(8) cell
 // stored 56 - the byte value of the character '8' - silently, with no error, because one byte
 // fits in eight bits. Refuse the batch instead of corrupting the column.
 const isHex=v=>/^0x[0-9A-Fa-f]*$/.test(String(v));
 // Two ways to know a column is binary. binaryCols comes from the server, which reads the real
 // column type - available in the Tauri build. Failing that, fall back to the value already in
 // the cell: both builds render a binary/BIT value as 0x..., so replacing one with something
 // else is the same mistake regardless of who reported the type.
 // With the column types known they decide; the value's shape is only the fallback.
 const binAt=(ci,ri)=>bc?bc[ci]:((t.binCols&&t.binCols[ci])||(ri!=null&&t.rows[ri]&&t.rows[ri][ci]!=null&&isHex(t.rows[ri][ci])));
 const badBin=[];
 Object.keys(t.pending.upd).forEach(k=>{const [ri,ci]=k.split(':').map(Number);
  if(!binAt(ci,ri))return;
  const v=t.pending.upd[k];
  if(v!==null&&v!==''&&!isHex(v)) badBin.push(t.cols[ci]+' = '+JSON.stringify(String(v)));
 });
 t.pending.ins.forEach(row=>{Object.keys(row).forEach(cn=>{const ci=t.cols.indexOf(cn);
  if(ci<0||!binAt(ci,null))return;
  const v=row[cn];
  if(v!==null&&v!==''&&!isHex(v)) badBin.push(cn+' = '+JSON.stringify(String(v)));
 });});
 if(badBin.length){
  toast('These are binary/BIT columns and only accept a 0x value:\n'+badBin.join('\n')
    +'\nUse 0x01 for 1, 0x00 for zero. A plain number would be stored as the bytes of its text '
    +'(8 becomes 56), which MySQL accepts without an error.',true);
  return;
 }
 // Reachable even though Apply is only enabled when something's pending: a +Row with every
 // column left blank produces no INSERT (a deliberate no-op, not a bug - see the ins.forEach
 // above), and if that's the ONLY thing pending, S ends up empty with nothing to tell the user
 // apply didn't silently do something - say so instead of just doing nothing visibly.
 if(!S.length){toast('Nothing to apply - new row(s) with no values are ignored. Fill in a column, or Revert to remove them.',true);return;}
 const changes=S.filter(s=>!s.startsWith('SELECT 1 FROM (SELECT 1 AS x')).length;
 log('APPLY:\n'+S.join('\n'));
 // Runs as one transaction, so a failure part-way leaves the table exactly as it was.
 // Foreign keys are NOT disabled here: they were, which let an edit point a row at a
 // parent that does not exist and silently break referential integrity the schema was
 // written to guarantee.
 const r=await api('/api/script',{sql:S.join('\n'),transaction:true});
 if(r.ok){log('Applied '+changes+' change(s).');toast('Applied '+changes+' change(s).','ok');invalidateTableCache(t.db,t.table);openRun(id).then(()=>refreshTabDirty(id));}else{log('APPLY error: '+r.error);toast(/Result consisted of more than one row/.test(String(r.error))?ONE_ROW_REFUSED:'Apply failed: '+r.error,true);}}

function ddlFailureNote(err, sql){
 const e = String(err || "");
 // Only worth saying when more than one statement could have run: a single failed statement
 // applied nothing, and adding the caveat there would be alarming and wrong.
 const stmts = String(sql || "").split(";").filter(s => s.trim().length).length;
 if (stmts < 2) return e;
 return e + "\n\nDDL is not transactional: any statements before this one have already been applied and cannot be rolled back. Check the object before re-running.";
}
// MySQL has no CREATE OR REPLACE for procedures, functions or triggers, so the editor recreates
// them as DROP then CREATE - and when the CREATE fails, the DROP has already happened. Measured on
// MySQL 8.0.46: a syntax error in an edited procedure left the procedure gone, with its code
// surviving only in the unsaved editor tab. (MariaDB's CREATE OR REPLACE is atomic and keeps the
// old version.)
//
// So the editor remembers the definition it was opened with, refreshes it after every successful
// apply, and after a failure checks whether the object still exists. If it does not, the previous
// definition is put back and the user is told; if even that fails, the definition is opened in a
// tab of its own and the message says plainly that the object is gone.
async function ddlExists(db,type,name){
 const q={procedure:"SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_TYPE='PROCEDURE' AND ROUTINE_SCHEMA="+lit(db)+" AND ROUTINE_NAME="+lit(name),
          function:"SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_TYPE='FUNCTION' AND ROUTINE_SCHEMA="+lit(db)+" AND ROUTINE_NAME="+lit(name),
          trigger:"SELECT COUNT(*) FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA="+lit(db)+" AND TRIGGER_NAME="+lit(name)}[type];
 if(!q)return null;
 const r=await api('/api/query',{sql:q});
 return r.ok&&r.rows[0]?String(r.rows[0][0])!=='0':null;
}
async function ddlRememberCurrent(d){
 if(!d||!/^(procedure|function|trigger)$/.test(d.type))return;
 const r=await api('/api/ddl',{db:d.db,type:d.type,name:d.name});
 if(r.ok&&r.ddl)d.orig=r.ddl;
}
async function ddlRestoreIfDropped(d){
 if(!d||!d.orig||!/^(procedure|function|trigger)$/.test(d.type))return '';
 if((await ddlExists(d.db,d.type,d.name))!==false)return '';
 const script='DELIMITER $$\n'+d.orig+'$$\nDELIMITER ;\n';
 const r=await api('/api/script',{sql:script,db:d.db});
 if(r.ok&&(await ddlExists(d.db,d.type,d.name))){
  loadObjects(d.db);
  return '\n\nThe '+d.type+' had already been dropped when this failed, so its previous version has been put back. Your edit is still here in the editor.';
 }
 openTab(d.type+': '+d.name+' (previous version)','-- '+d.type+' '+d.name+' could not be restored automatically: '+String(r.error||'unknown error').split('\n')[0]+'\n-- This is its definition from before your edit. Apply this tab to put it back.\n'+script,d.db,false,null,{type:d.type,db:d.db,name:d.name,orig:d.orig});
 return '\n\n'+d.type.toUpperCase()+' '+d.name+' IS GONE: it was dropped, the new version failed, and putting the old one back failed too. Its previous definition is open in a new tab.';
}
// "New procedure" with the name of one that already exists would replace it without a word - by
// DROP on MySQL, by CREATE OR REPLACE on MariaDB. Ask first.
async function ddlConfirmNew(db,type,name){
 if(!(await ddlExists(db,type,name)))return true;
 return await ask('A '+type+' named '+name+' already exists in '+db+'.\n\nApplying the new one will REPLACE it. Continue?');
}
async function applyDdl(id){if(roBlock())return;const t=T(id);const st=$('st_'+id);st.className='status';st.textContent='Applying...';const sql=$('ed_'+id).value;const r=await api('/api/script',{sql,db:(t.ddl&&t.ddl.db)||dbOf(t)});if(r.ok){st.textContent='Applied OK.';log('APPLY OK: '+t.title);if(t.ddl){await ddlRememberCurrent(t.ddl);loadObjects(t.ddl.db);}}else{st.className='status err';const _n=ddlFailureNote(r.error,sql)+(await ddlRestoreIfDropped(t.ddl));st.textContent=_n;log('APPLY ERROR: '+_n);}}

function bTSV(cols,rows){return cols.join('\t')+'\n'+rows.map(r=>r.map(v=>v===null?'NULL':v).join('\t')).join('\n');}
// How a NULL is written to CSV. A NULL and an empty string both used to come out as an empty
// field, so the two were indistinguishable in the file - and the CSV importer reads an empty
// cell as NULL, so an empty string did not survive a round trip. \N is the default because it
// is what LOAD DATA reads back and what HeidiSQL defaults to; the Export dialog can change it,
// including to blank for spreadsheets that would rather show nothing.
// Copying a grid as CSV writes NULLs as the marker, same as a file export, which is
// consistent but surprising when the clipboard is on its way to a spreadsheet. Say so once,
// and only when the copied rows actually contain a NULL - a hint nobody needs is just noise.
function csvNullHint(rows){
 const nm=csvNullMarker();
 if(!nm)return;
 if(!rows.some(r=>r.some(v=>v===null)))return;
 toast('NULLs were written as '+nm+'. Clear "NULL value" in the Export dialog to copy them as blanks instead.');
}
function csvNullMarker(){ const el=$('expNullVal'); return el?el.value:'\\N'; }
// A bare \r (no following \n) has to be quoted too, not just \n - both this app's own CSV
// importer and a spreadsheet's CSV rules treat a lone \r as ending the row, so an unquoted one
// silently splits one logical row into two and shifts every column after it.
function bCSV(cols,rows){const nm=csvNullMarker();const q=s=>s===null?nm:/[",\n\r]/.test(s)?'"'+String(s).replace(/"/g,'""')+'"':s;return cols.map(c=>c===null?'':q(c)).join(',')+'\n'+rows.map(r=>r.map(q).join(',')).join('\n');}
function bMD(cols,rows){
  const esc=s=>s===null?'':String(s).replace(/\|/g,'\\|').replace(/\n/g,' ');
  let h='| '+cols.map(esc).join(' | ')+' |\n';
  h+='| '+cols.map(()=>'---').join(' | ')+' |\n';
  rows.forEach(r=>{h+='| '+r.map(esc).join(' | ')+' |\n';});
  return h;
}
function selRows(id){const t=T(id);return viewIndices(id).filter(ri=>t.selected&&t.selected.has(ri)).map(ri=>t.rows[ri]);}
function copyGrid(id){const t=T(id);if(!t.cols)return;copyText(bTSV(t.cols,t.rows),'Copied '+t.rows.length+' rows (TSV).');}
function tsvGrid(id){const t=T(id);if(!t.cols)return;dl(bTSV(t.cols,t.rows),'result.tsv');}
function openUserTransfer(){$('utResult').value='';$('utStatus').textContent='';show('mUserTransfer');}
async function genUserTransfer(){
 $('utStatus').textContent='Generating\u2026';$('utResult').value='';
 const r=await api('/api/gen-user-transfer',{exclude:$('utExclude').value});
 if(!r.ok){$('utStatus').textContent='';toast(r.error||'Could not generate the script.',true);return;}
 $('utResult').value=r.sql;
 $('utStatus').textContent=r.userCount+' account(s)'+(r.errorCount?(' - '+r.errorCount+' could not be read, see the notes at the bottom of the script'):'')+'.';
}
function copyUserTransfer(){const v=$('utResult').value;if(!v){toast('Nothing to copy yet - click Generate first.',true);return;}copyText(v,'Copied user transfer script.');}
function saveUserTransferFile(){const v=$('utResult').value;if(!v){toast('Nothing to save yet - click Generate first.',true);return;}dl(v,'user_transfer.sql');}
async function copyCsv(id){const t=T(id);if(!t.cols)return;let cols=t.cols,rows=t.rows;
 copyText(bCSV(cols,rows),'Copied '+rows.length+' rows (CSV).').then(st=>{if(st!=='failed')csvNullHint(rows);});}
function copyMd(id){const t=T(id);if(!t.cols)return;copyText(bMD(t.cols,t.rows),'Copied '+t.rows.length+' rows (Markdown).');}
function copyMdSel(id){const t=T(id);if(!t.cols)return;const rows=selRows(id);if(!rows.length){toast('No rows selected. Tick the checkboxes on the rows you want.',true);return;}copyText(bMD(t.cols,rows),'Copied '+rows.length+' selected row(s) (Markdown).');}
function toggleSel(id,ri,ch){const t=T(id);if(!t.selected)t.selected=new Set();if(ch)t.selected.add(ri);else t.selected.delete(ri);updateEditBar(id);}
function selAll(id,ch){const t=T(id);if(!t.selected)t.selected=new Set();const view=viewIndices(id);view.forEach(ri=>{if(ch)t.selected.add(ri);else t.selected.delete(ri);});renderBody(id);updateEditBar(id);}
function copySel(id){const t=T(id);if(!t.cols)return;const rows=selRows(id);if(!rows.length){toast('No rows selected. Tick the checkboxes on the rows you want.',true);return;}copyText(bTSV(t.cols,rows),'Copied '+rows.length+' selected row(s) (TSV).');}
function copySelCsv(id){const t=T(id);if(!t.cols)return;const rows=selRows(id);if(!rows.length){toast('No rows selected. Tick the checkboxes on the rows you want.',true);return;}copyText(bCSV(t.cols,rows),'Copied '+rows.length+' selected row(s) (CSV).').then(st=>{if(st!=='failed')csvNullHint(rows);});}
function csvGrid(id){const t=T(id);if(!t.cols)return;if(t.table){exportFull(t.db,t.table,'csv');return;}dl(bCSV(t.cols,t.rows),'result.csv');}
async function insGrid(id){const t=T(id);if(!t.cols)return;if(t.table){exportFull(t.db,t.table,'inserts');return;}const bc=await gridBinCols(id);const s=t.rows.map(r=>insertSkipExisting('`table`',t.cols,'('+r.map((v,i)=>litAs(v,bc?bc[i]:null)).join(',')+')')).join('\n');dl(s,'result_inserts.sql');log('Exported '+t.rows.length+' row(s) as INSERTs.');}
async function csvSel(id){const t=T(id);if(!t.cols)return;const rows=selRows(id);if(!rows.length){toast('No rows selected. Tick the checkboxes on the rows you want.',true);return;}if(t.table&&!t.exact&&await refuseNulTextExport(t.db,t.table))return;dl(bCSV(t.cols,rows),(t.table||'result')+'_selected.csv');log('Exported '+rows.length+' selected row(s) to CSV.');}
async function insSel(id){const t=T(id);if(!t.cols)return;const rows=selRows(id);if(!rows.length){toast('No rows selected. Tick the checkboxes on the rows you want.',true);return;}if(t.table&&!t.exact&&await refuseNulTextExport(t.db,t.table))return;const tbl=t.table?(qid(t.db)+'.'+qid(t.table)):'`table`';const bc=await gridBinCols(id);
 // A generated column cannot be given a value, so it is left out.
 const info=t.table?await tableColumnsInfo(t.db,t.table):null;const gen=new Set((info||[]).filter(c=>c.generated).map(c=>c.name.toLowerCase()));
 const keep=t.cols.map((c,i)=>i).filter(i=>!gen.has(String(t.cols[i]).toLowerCase()));
 const s=rows.map(r=>insertSkipExisting(tbl,keep.map(i=>t.cols[i]),'('+keep.map(i=>litAs(r[i],bc?bc[i]:null)).join(',')+')')).join('\n');dl(s,(t.table||'result')+'_selected_inserts.sql');log('Exported '+rows.length+' selected row(s) as INSERTs.');}
async function dl(text,name){
 const ext=(name.split('.').pop()||'').toLowerCase();const filters=ext?[{name:ext.toUpperCase()+' file',extensions:[ext]}]:undefined;
 // Tauri: native Save As + backend write
 try{if(window.__TAURI__&&window.__TAURI__.dialog&&window.__TAURI__.dialog.save){const p=await window.__TAURI__.dialog.save({defaultPath:name,filters});if(!p)return;const r=await window.__TAURI__.core.invoke('save_text',{req:{path:p,content:text}});if(r&&r.ok===false){toast('Save failed: '+r.error,true);}else{log('Saved: '+p);toast('Saved: '+p,'ok');}return;}}catch(e){toast('Save failed: '+e,true);return;}
 // Chromium browsers (Edge/Chrome): File System Access "Save As"
 try{if(window.showSaveFilePicker){const opts={suggestedName:name};if(ext)opts.types=[{description:ext.toUpperCase()+' file',accept:{'text/plain':['.'+ext]}}];const h=await window.showSaveFilePicker(opts);const w=await h.createWritable();await w.write(text);await w.close();log('Saved: '+name);return;}}catch(e){if(e&&e.name==='AbortError')return;}
 // Fallback: classic download to the default folder
 const b=new Blob([text],{type:'text/plain'});const a=document.createElement('a');a.href=URL.createObjectURL(b);a.download=name;a.click();}
// Binary counterpart to dl() - same three-tier fallback (Tauri native dialog, then Chromium's
// File System Access API, then a classic <a download>), but for a Blob instead of a text
// string. Only Tauri's path needs special handling: it can't send a Blob through invoke()
// directly, so it's read into bytes and sent as a plain JSON array of numbers rather than
// base64 - decoding base64 correctly on the Rust side would need a new crate dependency, while
// a numeric array only needs the array/number extraction serde_json already provides. The other
// two paths (File System Access, classic download) already accept a Blob natively as-is.
async function dlBinary(blob,name){
 const ext=(name.split('.').pop()||'').toLowerCase();const filters=ext?[{name:ext.toUpperCase()+' file',extensions:[ext]}]:undefined;
 try{if(window.__TAURI__&&window.__TAURI__.dialog&&window.__TAURI__.dialog.save){const p=await window.__TAURI__.dialog.save({defaultPath:name,filters});if(!p)return;const buf=await blob.arrayBuffer();const bytes=Array.from(new Uint8Array(buf));const r=await window.__TAURI__.core.invoke('save_binary',{req:{path:p,bytes:bytes}});if(r&&r.ok===false){toast('Save failed: '+r.error,true);}else{log('Saved: '+p);toast('Saved: '+p,'ok');}return;}}catch(e){toast('Save failed: '+e,true);return;}
 try{if(window.showSaveFilePicker){const opts={suggestedName:name};if(ext)opts.types=[{description:ext.toUpperCase()+' file',accept:{'image/png':['.'+ext]}}];const h=await window.showSaveFilePicker(opts);const w=await h.createWritable();await w.write(blob);await w.close();log('Saved: '+name);return;}}catch(e){if(e&&e.name==='AbortError')return;}
 const a=document.createElement('a');a.href=URL.createObjectURL(blob);a.download=name;a.click();}

// ---- history ----
function hist(){try{return JSON.parse(localStorage.getItem('history')||'[]');}catch(e){return[];}}
function addHistory(sql){sql=sql.trim();if(!sql)return;let h=hist().filter(x=>x!==sql);h.unshift(sql);h=h.slice(0,200);localStorage.setItem('history',JSON.stringify(h));}
function codeBlockStartHeight(text){const lines=String(text||'').split('\n').length;return Math.min(140,Math.max(40,lines*17+13))+'px';}
// max-width:100% keeps a drag-resize from ever growing wider than the box it's already filling
// (effectively horizontal-only-if-there-was-room-to-begin-with, i.e. no overstretch past the
// window's own edge), and max-height clamps to the viewport itself so dragging can never grow the
// block past the visible window - without both, an unbounded resize:both could be dragged to an
// enormous size and made the whole window unresponsive while it repainted.
function codeBlockStyle(text){return "display:block;background:var(--log);color:var(--logfg);font-family:'Cascadia Code',Consolas,'SF Mono',Menlo,'DejaVu Sans Mono',monospace;font-size:11px;line-height:1.5;padding:6px 8px;border-radius:4px;white-space:pre-wrap;word-break:break-word;overflow-wrap:anywhere;overflow:auto;resize:both;max-width:100%;max-height:calc(100vh - 40px);height:"+codeBlockStartHeight(text);}
function openHistory(){const box=$('histList');const h=hist();box.innerHTML=h.length?'':'<div class="muted">No history yet.</div>';h.forEach(sql=>{const d=document.createElement('div');d.className='item';d.style.cssText='border-bottom:1px solid var(--bd2);padding:6px 4px';const code=document.createElement('code');code.style.cssText=codeBlockStyle(sql);code.textContent=sql;d.appendChild(code);d.onclick=()=>{hide('mHist');openTab('history',sql,curSchema,false,null);};box.appendChild(d);});show('mHist');}
async function clearHistory(){if(await ask('Clear query history?')){localStorage.removeItem('history');openHistory();}}
let _libCache=[];
function libAll(){return _libCache.slice();}
// --- Query library: saved queries, kept on the server so they survive restarts.
async function libLoad(){try{const r=await api('/api/lib-list');_libCache=(r.ok&&r.items)?r.items:[];}catch(e){_libCache=[];}}
function libExport(){const a=libAll();if(!a.length){toast('The library is empty - nothing to export.',true);return;}dl(JSON.stringify(a,null,2),'query-library.json');log('Exported '+a.length+' quer'+(a.length===1?'y':'ies')+' from the library.');}
function libImportFile(e){const f=e.target.files&&e.target.files[0];if(!f)return;const r=new FileReader();
 r.onload=()=>{try{const arr=JSON.parse(r.result);if(!Array.isArray(arr))throw 0;const map={};libAll().forEach(x=>map[x.name]=x);let n=0;
  arr.forEach(x=>{if(x&&x.name&&typeof x.sql==='string'){map[x.name]={name:x.name,sql:x.sql,schema:x.schema||'',ts:x.ts||Date.now()};n++;}});
  const merged=Object.keys(map).map(k=>map[k]).sort((a,b)=>(b.ts||0)-(a.ts||0));api('/api/lib-replace',{items:merged}).then(()=>libLoad()).then(()=>libRender());
  log('Imported '+n+' quer'+(n===1?'y':'ies')+' into the library.');}
  catch(err){toast('That file is not a valid query-library JSON export.',true);}
  e.target.value='';};
 r.readAsText(f);}
async function openLibrary(){$('libName').value='';$('libSearch').value='';show('mLib');await libLoad();libRender();}
async function libEdit(name){const cur=libAll().find(x=>x.name===name);if(!cur)return;const res=await inputBox({title:'Edit saved query',okText:'Save',fields:[{key:'name',label:'Name',value:cur.name},{key:'sql',label:'SQL',type:'textarea',value:cur.sql}]});if(!res||!res.name.trim())return;const nn=res.name.trim();if(nn!==name){await api('/api/lib-delete',{name:name});}await api('/api/lib-save',{name:nn,sql:res.sql,schema:cur.schema||'',ts:Date.now()});await libLoad();libRender();log('Updated saved query "'+nn+'".');}
async function libClearAll(){const a=libAll();if(!a.length){toast('The library is already empty.',true);return;}if(await ask('Delete ALL '+a.length+' saved quer'+(a.length===1?'y':'ies')+'? This cannot be undone.')){await api('/api/lib-clear');await libLoad();libRender();log('Cleared the query library.');}}
async function libSaveCurrent(){const name=$('libName').value.trim();if(!name){toast('Enter a name for the query.',true);return;}
 const t=activeTab?T(activeTab):null;const sql=t?$('ed_'+t.id).value:'';if(!sql.trim()){toast('The current query is empty.',true);return;}
 const r=await api('/api/lib-save',{name:name,sql:sql,schema:(t&&t.db)||curSchema||'',ts:Date.now()});if(!r.ok){toast(r.error||'Save failed',true);return;}await libLoad();$('libName').value='';libRender();log('Saved query "'+name+'" to library.');}
function libRender(){const box=$('libList');const q=($('libSearch').value||'').toLowerCase();
 const a=libAll().filter(x=>!q||x.name.toLowerCase().includes(q)||(x.sql||'').toLowerCase().includes(q));
 box.innerHTML='';if(!a.length){const e=document.createElement('div');e.className='muted';e.style.padding='10px';e.textContent=q?'No saved queries match.':'No saved queries yet. Type a name above and click Save current query.';box.appendChild(e);return;}
 a.forEach(x=>{const d=document.createElement('div');d.style.borderBottom='1px solid var(--bd2)';d.style.padding='6px 10px';
  const head=document.createElement('div');head.style.display='flex';head.style.justifyContent='space-between';head.style.alignItems='center';head.style.gap='8px';
  // A saved query's name is free text with no length limit at the point of use (only a maxlength
  // on #libName, as a soft cap) - min-width:0 + ellipsis keeps a long one from forcing this row
  // wider than the modal and shoving Open/Edit/Delete out past its (clipped, unscrollable) edge.
  const nm=document.createElement('div');nm.style.cssText='flex:1;min-width:0;overflow:hidden;white-space:nowrap;text-overflow:ellipsis';nm.title=x.name+(x.schema?' ('+x.schema+')':'');const b=document.createElement('b');b.textContent=x.name;nm.appendChild(b);if(x.schema){const sp=document.createElement('span');sp.className='muted';sp.textContent=' ('+x.schema+')';nm.appendChild(sp);}
  const btns=document.createElement('div');btns.style.flex='none';
  const op=document.createElement('button');op.className='sm';op.textContent='Open';op.onclick=()=>{hide('mLib');openTab(x.name,x.sql,x.schema||curSchema,false,null);};
  const ed=document.createElement('button');ed.className='sm';ed.textContent='Edit';ed.style.marginLeft='6px';ed.onclick=()=>libEdit(x.name);
  const dl=document.createElement('button');dl.className='sm warn';dl.textContent='Delete';dl.style.marginLeft='6px';dl.onclick=async()=>{if(await ask('Delete saved query "'+x.name+'"?')){await api('/api/lib-delete',{name:x.name});await libLoad();libRender();}};
  btns.appendChild(op);btns.appendChild(ed);btns.appendChild(dl);head.appendChild(nm);head.appendChild(btns);
  const pre=document.createElement('code');pre.style.cssText=codeBlockStyle(x.sql)+';margin-top:4px';pre.textContent=x.sql||'';
  d.appendChild(head);d.appendChild(pre);box.appendChild(d);});}

// ---- users ----
// Simple grid-layout ER diagram: not an auto-arranged, minimal-crossing-lines layout (that's a
// much bigger algorithmic problem), just a straightforward grid of table boxes with curved lines
// for each FK relationship - functional for getting an overview of a schema's relationships,
// especially for small-to-medium schemas.
function openErdForCurSchema(){
 if(!curSchema){toast('Select a schema in the tree first.',true);return;}
 openErd(curSchema);
}
// Reorders tables so that FK-related ones end up ADJACENT in the resulting list, rather than
// wherever their names happen to sort alphabetically - since the grid lays tables out in the
// order of this list, adjacent-in-list means adjacent-on-screen. This is a graph traversal
// (breadth-first, starting from each not-yet-visited table in alphabetical order, visiting
// directly-related tables before moving further away), not a full force-directed physics layout -
// much simpler to reason about and verify, and it directly targets the actual complaint (related
// tables ending up scattered far apart), even though it won't produce a mathematically optimal,
// minimal-crossing-lines arrangement the way a real graph-layout algorithm would.
// Crow's foot notation: a short perpendicular tick on the "one" side (the referenced table),
// a three-pronged fork on the "many" side (the table holding the FK column) - the standard
// visual convention for cardinality in ER diagrams. Both connector lines have purely horizontal
// tangents at their endpoints (a property of how the Bezier control points are set up below), so
// both symbols can be drawn as simple horizontal shapes rather than needing general tangent math.
// SIMPLIFICATION, stated plainly: this always assumes "many" on the FK side and "one" on the
// referenced side, which is correct for the overwhelming majority of foreign keys (a child row
// referencing a parent's primary key). It does not check whether the FK column is ALSO covered
// by a UNIQUE constraint, which would make it a genuine one-to-one relationship - that would need
// an extra query and is a reasonable follow-up, not something folded into this notation change.
function svgCrowsFoot(x,y,dir,spread,len,strokeW){
 strokeW=strokeW||1.3;
 const hx=x+dir*len;
 return '<line x1="'+hx+'" y1="'+y+'" x2="'+x+'" y2="'+(y-spread)+'" stroke="var(--erd-line,#7aa8d8)" stroke-width="'+strokeW+'"/>'
      +'<line x1="'+hx+'" y1="'+y+'" x2="'+x+'" y2="'+(y+spread)+'" stroke="var(--erd-line,#7aa8d8)" stroke-width="'+strokeW+'"/>'
      +'<line x1="'+hx+'" y1="'+y+'" x2="'+x+'" y2="'+y+'" stroke="var(--erd-line,#7aa8d8)" stroke-width="'+strokeW+'"/>';
}
function svgOneTick(x,y,dir,tickLen,gap,strokeW){
 strokeW=strokeW||1.3;
 const tx=x+dir*gap;
 return '<line x1="'+tx+'" y1="'+(y-tickLen)+'" x2="'+tx+'" y2="'+(y+tickLen)+'" stroke="var(--erd-line,#7aa8d8)" stroke-width="'+strokeW+'"/>';
}
function erdClusterOrder(sortedNames,fks,tables){
 const adj={};
 sortedNames.forEach(n=>adj[n]=new Set());
 fks.forEach(row=>{
  const tbl=row[0],refTbl=row[2];
  if(tables[tbl]&&tables[refTbl]&&tbl!==refTbl){adj[tbl].add(refTbl);adj[refTbl].add(tbl);}
 });
 const visited=new Set();const order=[];
 sortedNames.forEach(start=>{
  if(visited.has(start))return;
  const queue=[start];visited.add(start);
  while(queue.length){
   const cur=queue.shift();order.push(cur);
   const neighbors=[...adj[cur]].filter(x=>!visited.has(x)).sort();
   neighbors.forEach(nb=>{visited.add(nb);queue.push(nb);});
  }
 });
 return order;
}
function erdFindTable(){
 const q=($('erdFind').value||'').trim().toLowerCase();
 const box=$('erdBox');
 box.querySelectorAll('g[id^="erd_tbl_"] rect').forEach(r=>{r.setAttribute('stroke','var(--bd2,#444)');r.setAttribute('stroke-width','1.5');r.removeAttribute('stroke-dasharray');});
 if(!q||!window._erdTableNames)return;
 const names=window._erdTableNames;
 // exact match first, then substring, so typing a short/common fragment doesn't jump around
 // between matches as you keep typing toward the full name
 let idx=names.findIndex(n=>n.toLowerCase()===q);
 if(idx<0)idx=names.findIndex(n=>n.toLowerCase().includes(q));
 if(idx<0)return;
 const el=$('erd_tbl_'+idx);
 if(!el)return;
 el.scrollIntoView({block:'center',inline:'center'});
 const rect=el.querySelector('rect');
 if(rect){rect.setAttribute('stroke','#f5c518');rect.setAttribute('stroke-width','3');rect.setAttribute('stroke-dasharray','6,3');}
}
// The filter checkbox re-renders from cached data (no server round-trip) - toggling it just
// recomputes which tables to include and re-lays-out, using the SAME already-fetched columns/
// pks/fks. Since a table is only excluded when it appears in ZERO fk pairs, every relationship
// that survives filtering always has BOTH ends present - the filter can never itself cause the
// existing "relationship could not be drawn" diagnostic to misfire.
window._erdRawData=null;
window._erdPos={};
// Zoom applies a plain CSS transform to the already-rendered SVG - cheap and instant, no
// re-running the layout algorithm just to change scale. It's ALSO baked into the SVG string
// erdRender() builds (via window._erdZoom at render time), so the current zoom level survives
// correctly through any other re-render trigger (the filter checkbox, dragging a table) instead
// of silently resetting to 100% every time something else causes a re-render.
// Table dragging keeps working correctly at any zoom level with no changes needed: erdSvgPoint()
// already converts mouse coordinates via the SVG's actual accumulated screen transform matrix
// (getScreenCTM()), which inherently includes whatever CSS transform is currently applied.
window._erdZoom=1;
function erdApplyZoomStyle(){
 const svg=document.querySelector('#erdBox svg');
 if(svg)svg.style.transform='scale('+window._erdZoom+')';
 const lbl=$('erdZoomLabel');
 if(lbl)lbl.textContent=Math.round(window._erdZoom*100)+'%';
}
function erdSetZoom(newZoom){
 window._erdZoom=Math.max(0.25,Math.min(3,Math.round(newZoom*100)/100));
 erdApplyZoomStyle();
}
function erdZoomIn(){erdSetZoom(window._erdZoom+0.1);}
function erdZoomOut(){erdSetZoom(window._erdZoom-0.1);}
function erdZoomReset(){erdSetZoom(1);}
function erdExportPng(){
 const svg=document.querySelector('#erdBox svg');
 if(!svg){toast('Nothing to export yet - open a schema\'s ER diagram first.',true);return;}
 // Export at the diagram's full, natural size regardless of the current on-screen zoom level -
 // zoom is a viewing convenience, not something that should determine what actually ends up in
 // the file. Cloning (rather than reading the live element) means we can safely strip the zoom
 // transform without touching what's still on screen.
 const clone=svg.cloneNode(true);
 clone.removeAttribute('style');
 const svgStr=new XMLSerializer().serializeToString(clone);
 const svgBlob=new Blob([svgStr],{type:'image/svg+xml;charset=utf-8'});
 const url=URL.createObjectURL(svgBlob);
 const img=new Image();
 img.onload=function(){
  // PNG is a raster format - resolution is fixed at export time, not adjustable later. 2x the
  // diagram's native size gives a noticeably sharper result than a flat 1:1 copy without being
  // wastefully large.
  const scale=2;
  const w=svg.width.baseVal.value||img.width;
  const h=svg.height.baseVal.value||img.height;
  const canvas=document.createElement('canvas');
  canvas.width=w*scale;canvas.height=h*scale;
  const ctx=canvas.getContext('2d');
  // The diagram itself has no background rect - its table boxes are drawn directly on whatever
  // sits behind them on screen. Filling here first (matching the CURRENT theme's actual
  // background, not a fixed guess) prevents a transparent PNG from looking broken or illegible
  // when opened somewhere that doesn't itself show a dark background behind it.
  ctx.fillStyle=document.body.classList.contains('dark')?'#1e1e1e':'#fff';
  ctx.fillRect(0,0,canvas.width,canvas.height);
  ctx.scale(scale,scale);
  ctx.drawImage(img,0,0,w,h);
  URL.revokeObjectURL(url);
  canvas.toBlob(function(blob){
   if(!blob){toast('Could not export the diagram as PNG.',true);return;}
   const dbName=(window._erdRawData&&window._erdRawData.db)?window._erdRawData.db:'schema';
   dlBinary(blob,dbName+'_erd.png');
  },'image/png');
 };
 img.onerror=function(){URL.revokeObjectURL(url);toast('Could not export the diagram as PNG.',true);};
 img.src=url;
}
// Zooms toward wherever the mouse is (not the top-left) - without this, double-clicking a spot
// you actually want a closer look at would zoom in while the diagram shifts to keep the SAME
// top-left corner fixed, moving the very thing you clicked on out from under your cursor. The
// math: find the content-space point currently under the cursor, apply the new zoom, then set
// scroll so that identical content-space point lands back at the same on-screen position.
function erdZoomTowardPoint(newZoomRaw,clientX,clientY){
 const box=$('erdBox');
 if(!box)return;
 const oldZoom=window._erdZoom;
 const newZoom=Math.max(0.25,Math.min(3,Math.round(newZoomRaw*100)/100));
 if(newZoom===oldZoom)return;
 const rect=box.getBoundingClientRect();
 const contentX=box.scrollLeft+(clientX-rect.left);
 const contentY=box.scrollTop+(clientY-rect.top);
 const ratio=newZoom/oldZoom;
 window._erdZoom=newZoom;
 erdApplyZoomStyle();
 box.scrollLeft=contentX*ratio-(clientX-rect.left);
 box.scrollTop=contentY*ratio-(clientY-rect.top);
}
// Double-click to zoom in is the standard, widely-recognized convention (map viewers, image
// viewers). Shift+double-click zooms out instead - the common pairing for the opposite
// direction, since plain double-click alone only ever means "in". A double-click's own
// mousedown/mouseup pair also passes through erdPanStart/erdPanEnd on the way here, but since a
// real double-click's mouse position barely moves between the two clicks, that produces a
// harmless zero-distance pan that completes before this handler ever runs - not a real drag.
function erdDblClickZoom(e){
 erdZoomTowardPoint(window._erdZoom+(e.shiftKey?-0.25:0.25),e.clientX,e.clientY);
}
// Table boxes are draggable by their header (cursor:move affordance). Rather than selectively
// moving just the dragged box and its connector lines - which would need per-relationship DOM
// bookkeeping to keep lines correctly attached as they move - this re-runs the SAME rendering
// logic already used everywhere else (throttled to once per animation frame), so every line
// stays correctly, automatically attached to wherever its tables currently are, using code
// that's already been exercised and verified rather than a second, parallel code path.
let _erdDrag=null,_erdDragRaf=null;
function erdSvgPoint(e){
 const svg=document.querySelector('#erdBox svg');
 if(!svg)return null;
 const pt=svg.createSVGPoint();pt.x=e.clientX;pt.y=e.clientY;
 const ctm=svg.getScreenCTM();
 if(!ctm)return null;
 return pt.matrixTransform(ctm.inverse());
}
function erdStartDrag(e,ni){
 e.preventDefault();e.stopPropagation();
 const tbl=(window._erdTableNames||[])[ni];
 if(!tbl)return;
 const svgPt=erdSvgPoint(e);
 if(!svgPt)return;
 const cur=(window._erdCurPos||{})[tbl];
 if(!cur)return;
 _erdDrag={tbl,startMouseX:svgPt.x,startMouseY:svgPt.y,startTblX:cur.x,startTblY:cur.y};
 document.addEventListener('mousemove',erdDragMove);
 document.addEventListener('mouseup',erdDragEnd);
}
function erdDragMove(e){
 if(!_erdDrag)return;
 const svgPt=erdSvgPoint(e);
 if(!svgPt)return;
 const dx=svgPt.x-_erdDrag.startMouseX,dy=svgPt.y-_erdDrag.startMouseY;
 window._erdPos[_erdDrag.tbl]={x:_erdDrag.startTblX+dx,y:_erdDrag.startTblY+dy};
 if(_erdDragRaf)cancelAnimationFrame(_erdDragRaf);
 _erdDragRaf=requestAnimationFrame(()=>erdRender());
}
function erdDragEnd(){
 _erdDrag=null;
 document.removeEventListener('mousemove',erdDragMove);
 document.removeEventListener('mouseup',erdDragEnd);
}
// Click-and-drag on empty diagram space (anywhere that isn't a table's header, which stops
// propagation before this ever fires) pans the view by scrolling the erdBox container directly -
// far more natural than reaching for scrollbars once zoom makes the diagram larger than the
// visible area. A plain click with no actual movement naturally scrolls by zero, so this needs
// no separate "was this a click or a drag" distinction.
let _erdPan=null;
function erdPanStart(e){
 e.preventDefault();
 const box=$('erdBox');
 if(!box)return;
 _erdPan={startMouseX:e.clientX,startMouseY:e.clientY,startScrollLeft:box.scrollLeft,startScrollTop:box.scrollTop};
 box.style.cursor='grabbing';
 document.addEventListener('mousemove',erdPanMove);
 document.addEventListener('mouseup',erdPanEnd);
}
function erdPanMove(e){
 if(!_erdPan)return;
 const box=$('erdBox');
 if(!box)return;
 const dx=e.clientX-_erdPan.startMouseX,dy=e.clientY-_erdPan.startMouseY;
 box.scrollLeft=_erdPan.startScrollLeft-dx;
 box.scrollTop=_erdPan.startScrollTop-dy;
}
function erdPanEnd(){
 if(!_erdPan)return;
 _erdPan=null;
 const box=$('erdBox');
 if(box)box.style.cursor='grab';
 document.removeEventListener('mousemove',erdPanMove);
 document.removeEventListener('mouseup',erdPanEnd);
}
function erdRelatedNames(tables,fks){
 const related=new Set();
 fks.forEach(row=>{
  const tbl=row[0],refTbl=row[2];
  if(tables[tbl]&&tables[refTbl]){related.add(tbl);related.add(refTbl);}
 });
 return related;
}
function erdRender(){
 const data=window._erdRawData;
 if(!data)return;
 const r=data.r;
 const tables={};
 r.columns.forEach(row=>{
  const tbl=row[0],col=row[1];
  if(!tables[tbl])tables[tbl]={cols:[],pk:new Set()};
  tables[tbl].cols.push(col);
 });
 // PK flags come from a separate, precise CONSTRAINT_NAME='PRIMARY' query (matching how the
 // grid itself determines PK columns), not information_schema.COLUMNS.COLUMN_KEY - which has a
 // documented edge case where a table with no real primary key, but a UNIQUE NOT NULL index,
 // still shows that column as 'PRI'.
 (r.pks||[]).forEach(row=>{const tbl=row[0],col=row[1];if(tables[tbl])tables[tbl].pk.add(col);});
 let allNames=Object.keys(tables).sort();
 const onlyRelated=$('erdOnlyRelated')&&$('erdOnlyRelated').checked;
 if(onlyRelated){
  const related=erdRelatedNames(tables,r.fks||[]);
  allNames=allNames.filter(n=>related.has(n));
 }
 const names=erdClusterOrder(allNames,r.fks||[],tables);
 if(!names.length){$('erdBox').innerHTML='<div class="muted" style="padding:8px">'+(onlyRelated?'No tables have a foreign key relationship in this schema.':'No tables in this schema.')+'</div>';show('mErd');return;}

 // Measure the ACTUAL rendered width of each name (canvas text measurement, not a guessed
 // characters-times-average-width heuristic), so a box is always exactly as wide as its longest
 // name needs - long, heavily-prefixed table names (common in larger schemas) no longer get cut
 // off. Measured at BOLD weight for every string as a safe upper bound, since bold text (used for
 // headers and PK columns) is wider than regular text of the same characters.
 const measCanvas=document.createElement('canvas');const mctx=measCanvas.getContext('2d');
 function textW(text,font){mctx.font=font;return mctx.measureText(text).width;}
 const HEADER_FONT="700 12px sans-serif",COL_FONT="700 11px sans-serif";
 const rowH=18,headerH=24,padY=40,padX=40,gapX=70,gapY=90,boxPad=16,minW=140;
 // Per-table lookup of which columns are FKs and what they reference, so column rows can be
 // labeled "[PK]"/"[FK]" explicitly (a crow's foot at the table edge tells you A relationship
 // exists, but tracing exactly which ROW it touches gets hard once a table has more than a
 // handful of columns - an explicit label removes the guesswork).
 const fkByTable={};
 (r.fks||[]).forEach(row=>{
  const tbl=row[0],col=row[1],refTbl=row[2],refCol=row[3];
  if(tables[tbl]){if(!fkByTable[tbl])fkByTable[tbl]={};fkByTable[tbl][col]={refTbl,refCol};}
 });
 function erdRowLabel(tbl,col){
  const isPk=tables[tbl].pk.has(col);
  const isFk=!!(fkByTable[tbl]&&fkByTable[tbl][col]);
  let label=col;
  if(isPk)label+=' [PK]';
  if(isFk)label+=' [FK]';
  return {label,isPk,isFk,fkInfo:isFk?fkByTable[tbl][col]:null};
 }
 names.forEach(n=>{
  let maxW=textW(n,HEADER_FONT);
  tables[n].cols.forEach(c=>{maxW=Math.max(maxW,textW(erdRowLabel(n,c).label,COL_FONT));});
  tables[n].w=Math.max(minW,Math.ceil(maxW)+boxPad);
  tables[n].h=headerH+tables[n].cols.length*rowH+10;
 });

 const cols=Math.max(1,Math.ceil(Math.sqrt(names.length)));
 // Each grid COLUMN's width is the widest table assigned to that column position - tables no
 // longer share one uniform box width, but columns still line up neatly.
 const colWidths=new Array(cols).fill(0);
 names.forEach((n,i)=>{const cx=i%cols;colWidths[cx]=Math.max(colWidths[cx],tables[n].w);});
 const colX=[];let xAcc=padX;
 for(let c=0;c<cols;c++){colX[c]=xAcc;xAcc+=colWidths[c]+gapX;}
 let totalW=xAcc-gapX+padX;

 const pos={};
 names.forEach((n,i)=>{
  const cx=i%cols,cy=Math.floor(i/cols);
  pos[n]={x:colX[cx],cy,w:tables[n].w,h:tables[n].h};
 });
 const bandHeights={};
 names.forEach(n=>{const cy=pos[n].cy;bandHeights[cy]=Math.max(bandHeights[cy]||0,pos[n].h);});
 let yAcc=padY;const bandY={};const numBands=Math.ceil(names.length/cols);
 for(let b=0;b<numBands;b++){bandY[b]=yAcc;yAcc+=(bandHeights[b]||0)+gapY;}
 names.forEach(n=>{pos[n].y=bandY[pos[n].cy];});
 let totalH=yAcc;

 // Manually-dragged positions override the computed grid layout, and persist across re-renders
 // within the same schema view (toggling the filter checkbox, searching) - only a fresh
 // openErd() load resets them. If a drag moves a table outside the originally-computed bounds,
 // the diagram's own dimensions expand to keep it fully visible rather than clipping it off.
 names.forEach(n=>{
  if(window._erdPos[n]){pos[n].x=window._erdPos[n].x;pos[n].y=window._erdPos[n].y;}
  totalW=Math.max(totalW,pos[n].x+pos[n].w+padX);
  totalH=Math.max(totalH,pos[n].y+pos[n].h+padY);
 });
 window._erdCurPos=pos;

 let svg='<svg viewBox="0 0 '+totalW+' '+totalH+'" width="'+totalW+'" height="'+totalH+'" style="transform:scale('+window._erdZoom+');transform-origin:0 0" xmlns="http://www.w3.org/2000/svg">';
 let drawnCount=0,droppedCount=0;
 (r.fks||[]).forEach(row=>{
  const tbl=row[0],col=row[1],refTbl=row[2],refCol=row[3];
  const p1=pos[tbl],p2=pos[refTbl];
  if(!p1||!p2||!tables[tbl]||!tables[refTbl]){droppedCount++;return;}
  const srcColIdx=tables[tbl].cols.indexOf(col),dstColIdx=tables[refTbl].cols.indexOf(refCol);
  if(srcColIdx<0||dstColIdx<0){droppedCount++;return;}
  drawnCount++;
  const y1=p1.y+headerH+srcColIdx*rowH+rowH/2,y2=p2.y+headerH+dstColIdx*rowH+rowH/2;
  const x1=(p1.x<p2.x)?p1.x+p1.w:p1.x,x2=(p1.x<p2.x)?p2.x:p2.x+p2.w;
  const midX=(x1+x2)/2;
  const dir=(x1<x2)?1:-1;
  svg+='<path d="M'+x1+' '+y1+' C '+midX+' '+y1+', '+midX+' '+y2+', '+x2+' '+y2+'" stroke="var(--erd-line,#7aa8d8)" fill="none" stroke-width="1.5" opacity="0.75"/>';
  svg+=svgCrowsFoot(x1,y1,dir,5,16,1.6);
  svg+=svgOneTick(x2,y2,-dir,5,10,1.6);
 });
 // Report this instead of silently dropping lines - a table that failed to load for any reason
 // (permissions, a fetch error, a genuinely cross-schema FK pointing outside this diagram) would
 // otherwise just look like "the relationship isn't there" with zero indication why.
 $('erdStatus').textContent=names.length+' table(s), '+drawnCount+' relationship(s) drawn'+(droppedCount?(' - '+droppedCount+' relationship(s) could NOT be drawn (referenced table not found in this diagram - check for a cross-schema reference, or scroll/search if the table should be here).'):'.');
 // Each table gets a stable, findable id (erd_tbl_<index>, not the raw name - table names can
 // contain characters that aren't safe as HTML/SVG element ids) so erdFindTable() can scroll a
 // matched table into view and highlight it - useful once a schema has more tables than fit on
 // screen at once, where a real relationship can be easy to miss just because the two ends are
 // far apart in the grid.
 window._erdTableNames=names;
 names.forEach((n,ni)=>{
  const p=pos[n];
  svg+='<g id="erd_tbl_'+ni+'">';
  svg+='<rect x="'+p.x+'" y="'+p.y+'" width="'+p.w+'" height="'+p.h+'" fill="var(--panel,#1e1e1e)" stroke="var(--bd2,#444)" stroke-width="1.5" rx="4"/>';
  svg+='<rect x="'+p.x+'" y="'+p.y+'" width="'+p.w+'" height="'+headerH+'" fill="#2d4a6b" rx="4" style="cursor:move" onmousedown="erdStartDrag(event,'+ni+')" ondblclick="event.stopPropagation()"/>';
  svg+='<text x="'+(p.x+8)+'" y="'+(p.y+16)+'" fill="#fff" font-size="12" font-weight="600" style="cursor:move;user-select:none" onmousedown="erdStartDrag(event,'+ni+')" ondblclick="event.stopPropagation()">'+esc(n)+'</text>';
  tables[n].cols.forEach((c,ci)=>{
   const {label,isPk,isFk,fkInfo}=erdRowLabel(n,c);
   const rowY=p.y+headerH+ci*rowH;
   const yy=rowY+11;
   // Highlight the row background for FK columns - a crow's foot at the table edge tells you
   // A relationship exists, but which row it touches is easy to lose track of once a table has
   // more than a handful of columns. PK keeps its existing green/bold treatment (already
   // distinctive on its own); adding a background tint there too would be visual overkill.
   if(isFk)svg+='<rect x="'+p.x+'" y="'+rowY+'" width="3" height="'+rowH+'" fill="var(--erd-line,#7aa8d8)"/>';
   const color=isPk?'var(--erd-pk,#5dcaa5)':(isFk?'var(--erd-fk,#8fb8e8)':'var(--fg,#ccc)');
   const weight=isPk?'700':'400';
   const titleTag=fkInfo?('<title>References '+esc(fkInfo.refTbl)+'.'+esc(fkInfo.refCol)+'</title>'):'';
   svg+='<text x="'+(p.x+8)+'" y="'+yy+'" fill="'+color+'" font-size="11" font-weight="'+weight+'">'+esc(label)+titleTag+'</text>';
  });
  svg+='</g>';
 });
 svg+='</svg>';
 $('erdBox').innerHTML=svg;
 erdApplyZoomStyle();
 show('mErd');
}
async function openErd(db){
 $('erdFind').value='';
 window._erdPos={};
 const r=await api('/api/schema-erd',{db});
 if(!r.ok){toast(r.error||'Could not load schema.',true);return;}
 $('erdTitle').textContent='ER Diagram - '+db;
 window._erdRawData={db,r};
 erdRender();
}
// A global Escape-key handler elsewhere in the app closes the topmost open modal by directly
// toggling its 'show' class, bypassing any modal-specific close button entirely - so rather than
// trying to intercept every possible way this modal could close (Close button, Escape, any
// future addition), the timer checks on EVERY tick whether the modal is still actually visible,
// and stops itself the moment it isn't. This is what keeps the interval from silently running
// forever in the background after the dialog is gone by some path other than its own button.
let _plAutoRefreshTimer=null;
function plToggleAutoRefresh(){
 if(_plAutoRefreshTimer){clearInterval(_plAutoRefreshTimer);_plAutoRefreshTimer=null;}
 if($('plAutoRefresh')&&$('plAutoRefresh').checked){
  _plAutoRefreshTimer=setInterval(()=>{
   const m=$('mProcessList');
   if(!m||!m.classList.contains('show')){clearInterval(_plAutoRefreshTimer);_plAutoRefreshTimer=null;return;}
   refreshProcessList();
  },3000);
 }
}
async function openProcessList(){show('mProcessList');await refreshProcessList();plToggleAutoRefresh();}
async function refreshProcessList(){
 $('plStatus').textContent='Loading\u2026';
 const r=await api('/api/process-list',{});
 if(!r.ok){$('plStatus').textContent='';$('plGrid').innerHTML='<div class="muted" style="padding:8px">'+esc(r.error||'Could not load process list.')+'</div>';return;}
 const idIdx=r.columns.findIndex(c=>c.toLowerCase()==='id');
 const infoIdx=r.columns.findIndex(c=>c.toLowerCase()==='info');
 // SHOW FULL PROCESSLIST always includes ITSELF (the instant it runs, it IS a running process) -
 // as a fresh connection each refresh, so it's a different, ever-climbing id every time, is
 // always caught in its own brief "starting" state, and can never actually be killed (it's
 // already finished and disconnected by the time a Kill reaches the server). None of that is
 // useful information, so filter that one row out rather than confuse people with it.
 const showHidden=$('plShowHidden')&&$('plShowHidden').checked;
 const filteredRows=(infoIdx>=0&&!showHidden)?r.rows.filter(row=>{const info=String(row[infoIdx]||'').trim().toLowerCase();return info!=='show full processlist'&&info!=='show processlist';}):r.rows;
 const hiddenCount=r.rows.length-filteredRows.length;
 r.rows=filteredRows;
 $('plStatus').textContent=r.rows.length+' process(es)'+(hiddenCount?' (hid '+hiddenCount+' - this connection\'s own SHOW PROCESSLIST)':'')+'.';
 let h='<table style="width:100%;border-collapse:collapse;font-size:12px"><thead><tr>';
 r.columns.forEach((c,ci)=>{const wide=(ci===idIdx)?'min-width:70px;':'';h+='<th style="text-align:left;padding:4px 6px;border-bottom:1px solid var(--bd2);position:sticky;top:0;background:var(--bg);'+wide+'">'+esc(c)+'</th>';});
 h+='<th style="padding:4px 6px;border-bottom:1px solid var(--bd2)"></th></tr></thead><tbody>';
 r.rows.forEach(row=>{
  h+='<tr>';
  row.forEach(v=>{h+='<td style="padding:4px 6px;border-bottom:1px solid var(--bd2)">'+cellHtml(v)+'</td>';});
  const pid=idIdx>=0?row[idIdx]:null;
  // Same reasoning as the filtering above: this connection's own SHOW [FULL] PROCESSLIST row
  // can never actually be killed, so - when "Show hidden" reveals it anyway - it gets no Kill
  // button at all rather than one that would only ever fail.
  const info=infoIdx>=0?String(row[infoIdx]||'').trim().toLowerCase():'';
  const isSelf=(info==='show full processlist'||info==='show processlist');
  h+='<td style="padding:4px 6px;border-bottom:1px solid var(--bd2)">'+((pid!=null&&!isSelf)?'<button class="sm warn" onclick="killProcess(\''+esc(pid).replace(/\x27/g,'\\x27')+'\')">Kill</button>':'')+'</td>';
  h+='</tr>';
 });
 h+='</tbody></table>';
 $('plGrid').innerHTML=h;
}
async function killProcess(pid){
 if(!(await ask('Kill process '+pid+'? This immediately terminates its current query/connection.')))return;
 const r=await api('/api/kill-process',{pid});
 if(r.ok){log('Killed process '+pid+'.');refreshProcessList();}
 else{toast(r.error||('Could not kill process '+pid+'.'),true);}
}
async function openUsers(){const r=await api('/api/query',{sql:"SELECT User,Host FROM mysql.user ORDER BY User,Host"});const sel=$('userSel');sel.innerHTML='';$('grantsBox').textContent='';window._selUser='';
 if(!r.ok){toast(r.error,true);return;}r.rows.forEach(u=>{const d=document.createElement('div');d.className='uitem';d.textContent=u[0]+'@'+u[1];d.dataset.v=u[0]+'\x01'+u[1];d.onclick=()=>{[...sel.children].forEach(c=>c.classList.remove('sel'));d.classList.add('sel');window._selUser=d.dataset.v;showGrants();};sel.appendChild(d);});show('mUsers');}
async function showGrants(){const v=window._selUser;if(!v)return;const[u,h]=v.split('\x01');const r=await api('/api/query',{sql:"SHOW GRANTS FOR "+strLit(u)+"@"+strLit(h)});$('grantsBox').textContent=r.ok?r.rows.map(x=>x[0]).join('\n'):r.error;}
async function newUser(){const res=await inputBox({title:'New user',okText:'Create',fields:[{key:'user',label:'User name'},{key:'host',label:'Host',value:'%'},{key:'pw',label:'Password',type:'password'}]});if(!res||!res.user.trim())return;const h=res.host.trim()||'%';if(await exec("CREATE USER "+strLit(res.user.trim())+"@"+strLit(h)+" IDENTIFIED BY "+strLit(res.pw),'Created user'))openUsers();}
// Common privilege combos, similar to what Workbench's own privilege list offers - not exhaustive
// (there's dozens of individual MySQL privileges), just the handful actually reached for often. The
// free-text field underneath stays the source of truth: picking a preset/schema/table just (re)writes
// it for you, and it's still hand-editable for anything these pickers don't cover.
const GRANT_PRESETS=[
 {value:'__custom__',label:'Custom (type below)'},
 {value:'ALL PRIVILEGES',label:'ALL PRIVILEGES'},
 {value:'SELECT',label:'SELECT (read-only)'},
 {value:'SELECT, INSERT, UPDATE, DELETE',label:'SELECT, INSERT, UPDATE, DELETE'},
 {value:'SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, DROP, INDEX, REFERENCES',label:'SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, DROP, INDEX, REFERENCES'},
 {value:'EXECUTE',label:'EXECUTE (procedures/functions)'},
 {value:'PROCESS, RELOAD',label:'PROCESS, RELOAD'},
 {value:'REPLICATION SLAVE, REPLICATION CLIENT',label:'REPLICATION SLAVE, REPLICATION CLIENT'},
 {value:'USAGE',label:'USAGE (no privileges)'},
];
// Shared by grantUser()/revokeUser() - the dialog itself doesn't know or care which one it's for
// beyond the title/button text; the caller still does the actual GRANT/REVOKE + FLUSH PRIVILEGES.
async function grantRevokeDialog(mode){
 const isGrant=mode==='grant';
 const sr=await api('/api/schemas');const schemas=sr.ok?sr.schemas.map(s=>s.name):[];
 const fields=[
  {key:'preset',label:'Common privileges',type:'select',options:GRANT_PRESETS,value:'__custom__'},
  {key:'schema',label:'Schema',type:'select',options:[{value:'*',label:'* (all databases)'},...schemas.map(s=>({value:s,label:s}))],value:'*'},
  {key:'table',label:'Table',type:'select',options:[{value:'*',label:'* (all tables)'}],value:'*'},
 ];
 if(isGrant)fields.push({key:'wgo',label:'With grant option',type:'checkbox',value:false});
 fields.push({key:'g',label:'Privileges'+(isGrant?' to grant':' to revoke')+' (e.g. ALL PRIVILEGES ON db.*) - editable directly, or built from the pickers above',value:'ALL PRIVILEGES ON *.*'});
 const p=inputBox({title:isGrant?'Grant privileges':'Revoke privileges',okText:isGrant?'Grant':'Revoke',width:'560px',fields});
 const presetSel=$('inp_preset'),schemaSel=$('inp_schema'),tableSel=$('inp_table'),gInput=$('inp_g'),wgoCk=isGrant?$('inp_wgo'):null;
 // WITH GRANT OPTION is a suffix on the whole GRANT statement (after "TO user@host"), not part of
 // the privilege/target list this field holds - grantUser() appends it separately at exec time, in
 // the right place, based on the checkbox state rather than baking it into this text.
 function rebuild(){
  const on=(schemaSel.value==='*'?'*':qid(schemaSel.value))+'.'+(tableSel.value==='*'?'*':qid(tableSel.value));
  const priv=presetSel.value==='__custom__'?(gInput.value.replace(/\s+ON\s+\S+\.\S+.*$/i,'').trim()||'SELECT'):presetSel.value;
  gInput.value=priv+' ON '+on;
 }
 async function refreshTables(){
  if(schemaSel.value==='*'){tableSel.innerHTML='<option value="*">* (all tables)</option>';tableSel.disabled=true;return;}
  tableSel.disabled=false;tableSel.innerHTML='<option value="*">* (all tables)</option>';
  const tr=await api('/api/query',{sql:'SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA='+lit(schemaSel.value)+' ORDER BY TABLE_NAME'});
  if(tr.ok)tr.rows.forEach(r=>{const o=document.createElement('option');o.value=r[0];o.textContent=r[0];tableSel.appendChild(o);});
 }
 presetSel.onchange=rebuild;tableSel.onchange=rebuild;if(wgoCk)wgoCk.onchange=rebuild;
 schemaSel.onchange=async()=>{await refreshTables();rebuild();};
 await refreshTables();
 return await p;
}
async function revokeUser(){const v=window._selUser;if(!v){toast('Select a user first.',true);return;}const[u,h]=v.split('\x01');const res=await grantRevokeDialog('revoke');if(!res||!res.g.trim())return;if(await exec("REVOKE "+res.g.trim()+" FROM "+strLit(u)+"@"+strLit(h),'Revoked')){await exec('FLUSH PRIVILEGES','Flush');showGrants();}}
async function lockUser(lock){const v=window._selUser;if(!v){toast('Select a user first.',true);return;}const[u,h]=v.split('\x01');const verb=lock?'LOCK':'UNLOCK';if(await exec("ALTER USER "+strLit(u)+"@"+strLit(h)+" ACCOUNT "+verb,(lock?'Locked ':'Unlocked ')+u+'@'+h)){showGrants();}}
async function changePassword(){const v=window._selUser;if(!v){toast('Select a user first.',true);return;}const parts=v.split('\x01');const u=parts[0],h=parts[1];
 const res=await inputBox({title:'Change password for '+u+'@'+h,okText:'Change',fields:[{key:'pw',label:'New password',type:'password',value:''},{key:'pw2',label:'Confirm new password',type:'password',value:''}]});
 if(!res)return;if(!res.pw){toast('Password cannot be empty.',true);return;}if(res.pw!==res.pw2){toast('Passwords do not match.',true);return;}
 // lit() for user/host (matching lockUser()), but strLit() - always quoted - for the password:
 // lit()'s hex-literal passthrough is meant for cell values, not a password field, and a plain
 // quote-double (no backslash escaping first) let a value ending in a backslash close the literal
 // one character early.
 const sql="ALTER USER "+strLit(u)+"@"+strLit(h)+" IDENTIFIED BY "+strLit(res.pw)+";";
 const r=await api('/api/exec',{sql:sql});
 if(r.ok){log('Password changed for '+u+'@'+h+'.');toast('Password changed for '+u+'@'+h+'.','ok');}else{toast('Failed: '+(r.error||'unknown'),true);}}
async function dropUser(){const v=window._selUser;if(!v)return;const[u,h]=v.split('\x01');if(!(await ask('DROP USER '+u+'@'+h+' ?')))return;if(await exec("DROP USER "+strLit(u)+"@"+strLit(h),'Dropped user'))openUsers();}
async function grantUser(){const v=window._selUser;if(!v){toast('Select a user first.',true);return;}const[u,h]=v.split('\x01');const res=await grantRevokeDialog('grant');if(!res||!res.g.trim())return;
 const sql="GRANT "+res.g.trim()+" TO "+strLit(u)+"@"+strLit(h)+(res.wgo?' WITH GRANT OPTION':'');
 if(await exec(sql,'Granted')){await exec('FLUSH PRIVILEGES','Flush');showGrants();}}

// ---- table designer ----
const DTYPES=['INT','BIGINT','TINYINT','SMALLINT','MEDIUMINT','DECIMAL','FLOAT','DOUBLE','BIT','BOOLEAN','CHAR','VARCHAR','TEXT','MEDIUMTEXT','LONGTEXT','DATE','DATETIME','TIMESTAMP','TIME','YEAR','JSON','BLOB','LONGBLOB','ENUM','BINARY','VARBINARY'];
let dOrig=null,dEdited=false;
// The designer shows a column as name / type / length / flags / default / comment, but a real
// column carries more than that: UNSIGNED, a character set and collation, ON UPDATE, INVISIBLE, a
// fractional-seconds precision, a DECIMAL scale, an ENUM's value list, and a default that may be an
// expression rather than a literal. None of those used to survive a MODIFY. The length box was
// filled from CHARACTER_MAXIMUM_LENGTH or NUMERIC_PRECISION alone, so editing nothing but the
// comment on a column rewrote it - measured on MySQL 8.0.46, from a comment-only edit:
//
//   DECIMAL(10,2)   12.34                       ->  DECIMAL(10,0)  12
//   INT UNSIGNED                                ->  INT (signed)
//   DATETIME(6)     2024-01-01 12:34:56.123456  ->  DATETIME       2024-01-01 12:34:56
//   latin1 text                                 ->  utf8mb4, re-encoded
//   ENUM('alpha','beta')                        ->  ENUM(5), a syntax error
//
// dColFromInfo() reads everything from COLUMN_TYPE and friends instead. What the form cannot show
// is kept on the row (keep) and written back unchanged, and only dropped where the user's own edit
// makes it meaningless - UNSIGNED on a column changed to VARCHAR, a character set on one changed
// to INT. Top-level and DOM-free so tests can drive them with real information_schema rows.
const D_TEXTY=/^(CHAR|VARCHAR|TINYTEXT|TEXT|MEDIUMTEXT|LONGTEXT|ENUM|SET)$/;
const D_NUMERIC=/^(TINYINT|SMALLINT|MEDIUMINT|INT|INTEGER|BIGINT|DECIMAL|NUMERIC|FLOAT|DOUBLE|REAL)$/;
const D_TEMPORAL=/^(DATETIME|TIMESTAMP)$/;
// row: COLUMN_NAME, DATA_TYPE, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT, EXTRA, COLUMN_KEY,
//      COLUMN_COMMENT, CHARACTER_SET_NAME, COLLATION_NAME, GENERATION_EXPRESSION
// tableColl: the table's default collation. A column that merely inherits it gets no clause of its
// own, so SHOW CREATE TABLE - and Compare DB - still read it as inheriting after an edit.
function dColFromInfo(row,isMaria,tableColl){
 const [name,dataType,colType,nullable,rawDef,extraRaw,key,comment,cs,coll,genExpr]=row;
 const extra=extraRaw||'';
 const type=String(dataType).toUpperCase();
 // "decimal(10,2) unsigned zerofill", "enum('a)','b')", "bigint unsigned", "datetime(6)".
 // The greedy group runs to the LAST ')' that still leaves only modifiers after it, so a ')'
 // inside an ENUM value does not end the list early.
 const m=/^[a-z ]+?(?:\((.*)\))?((?:\s+(?:unsigned|signed|zerofill))*)\s*$/i.exec(String(colType||''));
 const len=m&&m[1]!=null?m[1]:'';
 const mods=m&&m[2]?m[2].trim().toUpperCase():'';
 // Defaults. MySQL gives a literal unquoted and marks an expression with DEFAULT_GENERATED;
 // MariaDB quotes a literal, spells an explicit NULL default as the word NULL, and gives an
 // expression bare. defShown is what the form displays; defSql is the exact SQL to write back
 // while the displayed value is left alone.
 let defShown='',defSql=null;
 if(rawDef!=null){
  const v=String(rawDef);
  if(isMaria){
   if(v==='NULL'){defShown='NULL';defSql='NULL';}
   else if(/^'[\s\S]*'$/.test(v)){defShown=v.slice(1,-1).replace(/''/g,"'").replace(/\\\\/g,'\\');defSql=v;}
   else{defShown=v;defSql=v;}
  } else {
   defShown=v;
   if(/DEFAULT_GENERATED/i.test(extra))defSql=/^current_timestamp(\(\d*\))?$/i.test(v)?v:'('+v+')';
   else if(/^b'[01]*'$/i.test(v)||/^0x[0-9a-f]*$/i.test(v))defSql=v;
   else defSql=strLit(v);
  }
 }
 const onUp=/on update\s+(\S+)/i.exec(extra);
 const generated=/GENERATED/i.test(extra.replace(/DEFAULT_GENERATED/ig,''));
 const col={name,type,len,nn:nullable==='NO',def:defShown,ai:/auto_increment/i.test(extra),pk:key==='PRI',comment:comment||''};
 const inherits=!!coll&&coll===tableColl;
 col.keep={origName:name,origType:type,origLen:len,mods,cs:inherits?'':(cs||''),coll:inherits?'':(coll||''),onUpdate:onUp?onUp[1]:'',
   invisible:/\bINVISIBLE\b/i.test(extra),defShown,defSql,generated,genExpr:genExpr||''};
 return col;
}
function colDef(c){
 const k=c.keep||{};
 let s=qid(c.name)+' '+c.type;if(c.len)s+='('+c.len+')';
 if(k.mods&&D_NUMERIC.test(c.type))s+=' '+k.mods;
 if(k.cs&&D_TEXTY.test(c.type))s+=' CHARACTER SET '+k.cs+(k.coll?' COLLATE '+k.coll:'');
 if(c.nn)s+=' NOT NULL';if(c.ai)s+=' AUTO_INCREMENT';
 // An untouched default is written back exactly as it was read - including an empty-string
 // default, which the form cannot tell apart from "no default" by looking at the box.
 if(k.defSql!=null&&c.def===k.defShown)s+=' DEFAULT '+k.defSql;
 else if(c.def!==''&&c.def!=null){s+=' DEFAULT '+(/^(CURRENT_TIMESTAMP(\(\d*\))?|NULL|TRUE|FALSE|-?\d+(\.\d+)?)$/i.test(c.def)?c.def:lit(c.def));}
 if(k.onUpdate&&D_TEMPORAL.test(c.type))s+=' ON UPDATE '+k.onUpdate;
 if(k.invisible)s+=' INVISIBLE';
 if(c.comment)s+=' COMMENT '+strLit(c.comment);return s;}
// The ALTER for a set of edited columns against what was read. A row keeps the name it was read
// with, so renaming one is a CHANGE COLUMN; it used to be DROP COLUMN old + ADD COLUMN new, which
// throws away every value in it.
function dAlterSql(orig,cols,tbl){
 const alt=[],notes=[];
 const seen=new Set();
 const same=(o,c)=>JSON.stringify({t:o.type,l:''+o.len,nn:o.nn,ai:o.ai,d:o.def,cm:o.comment})===JSON.stringify({t:c.type,l:''+c.len,nn:c.nn,ai:c.ai,d:c.def,cm:c.comment});
 cols.forEach(c=>{
  const on=c.keep&&c.keep.origName;
  const o=on!=null?orig.find(x=>x.name===on):null;
  if(!o){alt.push('ADD COLUMN '+colDef(c));return;}
  seen.add(o.name);
  const renamed=c.name!==o.name;
  if(!renamed&&same(o,c))return;
  // A generated column's expression comes back from information_schema with its quoting
  // mangled on some versions, so rewriting it is not safe. Leave it, and say so.
  if(o.keep&&o.keep.generated){notes.push('-- '+qid(o.name)+' is a generated column; change it with SQL, not the designer (left unchanged)');return;}
  alt.push((renamed?'CHANGE COLUMN '+qid(o.name)+' ':'MODIFY COLUMN ')+colDef(c));
 });
 orig.filter(o=>!seen.has(o.name)).forEach(o=>alt.push('DROP COLUMN '+qid(o.name)));
 const oldPk=orig.filter(c=>c.pk).map(c=>c.name).join(',');
 const newPk=cols.filter(c=>c.pk).map(c=>(c.keep&&c.keep.origName)||c.name).join(',');
 if(oldPk!==newPk){if(oldPk)alt.push('DROP PRIMARY KEY');const pk=cols.filter(c=>c.pk).map(c=>qid(c.name));if(pk.length)alt.push('ADD PRIMARY KEY ('+pk.join(',')+')');}
 const head=notes.length?notes.join('\n')+'\n':'';
 return alt.length?head+'ALTER TABLE '+tbl+'\n  '+alt.join(',\n  ')+';':head+'-- no changes detected';
}
async function designTable(name,db){dEdited=false;db=db||curSchema||'';$('dSchema').value=db;$('dName').value=name||'';$('dCols').innerHTML='';$('dLog').textContent='';dOrig=null;
 if(name){$('dTitle').textContent='Alter table';$('dMode').textContent='(existing - generates ALTER)';
   const r=await api('/api/query',{sql:"SELECT COLUMN_NAME,DATA_TYPE,COLUMN_TYPE,IS_NULLABLE,COLUMN_DEFAULT,EXTRA,COLUMN_KEY,COLUMN_COMMENT,CHARACTER_SET_NAME,COLLATION_NAME,GENERATION_EXPRESSION FROM information_schema.COLUMNS WHERE TABLE_SCHEMA="+lit(db)+" AND TABLE_NAME="+lit(name)+" ORDER BY ORDINAL_POSITION"});
   const tc=await api('/api/query',{sql:"SELECT TABLE_COLLATION FROM information_schema.TABLES WHERE TABLE_SCHEMA="+lit(db)+" AND TABLE_NAME="+lit(name)});
   const tableColl=tc.ok&&tc.rows[0]?tc.rows[0][0]:null;
   dOrig=[];if(r.ok)r.rows.forEach(row=>{const col=dColFromInfo(row,!!window.mariadb,tableColl);dOrig.push(col);dAddCol(col);});
   else{$('dLog').textContent='Could not read the table: '+r.error;}
 } else {$('dTitle').textContent='Create table';$('dMode').textContent='(new - generates CREATE)';dAddCol({name:'id',type:'INT',len:'',nn:true,ai:true,pk:true,def:null,comment:''});dAddCol({name:'',type:'VARCHAR',len:'255',nn:false,ai:false,pk:false,def:null,comment:''});}
 dGen();show('mDesign');}
function dAddCol(c){c=c||{name:'',type:'VARCHAR',len:'255',nn:false,ai:false,pk:false,def:null,comment:''};const tr=document.createElement('tr');
 // A type the list does not carry (SET, TINYTEXT, GEOMETRY...) must still be offered, or the
 // select falls back to its first entry and the column is silently read back as INT.
 const types=DTYPES.includes(c.type)?DTYPES:DTYPES.concat([c.type]);
 tr.innerHTML='<td><input class="dn" value="'+esc(c.name)+'"></td><td><select class="dt">'+types.map(t=>'<option'+(t===c.type?' selected':'')+'>'+esc(t)+'</option>').join('')+'</select></td>'+
  '<td><input class="dl" value="'+esc(c.len==null?'':c.len)+'" style="width:70px"></td><td><input type="checkbox" class="dnn"'+(c.nn?' checked':'')+'></td>'+
  '<td><input type="checkbox" class="dai"'+(c.ai?' checked':'')+'></td><td><input type="checkbox" class="dpk"'+(c.pk?' checked':'')+'></td>'+
  '<td><input class="dd" value="'+esc(c.def==null?'':c.def)+'" style="width:90px"></td><td><input class="dc" value="'+esc(c.comment||'')+'"></td>'+
  '<td><button class="sm" title="Remove this column" onclick="this.closest(\'tr\').remove();dGen()">x</button></td>';
 tr._keep=c.keep||null;
 if(c.keep){const hint=[c.keep.mods,c.keep.cs&&('CHARACTER SET '+c.keep.cs),c.keep.onUpdate&&('ON UPDATE '+c.keep.onUpdate),c.keep.invisible&&'INVISIBLE',c.keep.generated&&'GENERATED'].filter(Boolean).join(', ');if(hint)tr.title='Kept as is: '+hint;}
 $('dCols').appendChild(tr);tr.querySelectorAll('input,select').forEach(el=>el.addEventListener('change',dGen));}
function dMark(){dEdited=true;$('dEditNote').textContent='✎ manually edited - auto-update paused; use Regenerate to rebuild';}
function dReadCols(){return [...$('dCols').children].map(tr=>({name:tr.querySelector('.dn').value.trim(),type:tr.querySelector('.dt').value,len:tr.querySelector('.dl').value.trim(),nn:tr.querySelector('.dnn').checked,ai:tr.querySelector('.dai').checked,pk:tr.querySelector('.dpk').checked,def:tr.querySelector('.dd').value,comment:tr.querySelector('.dc').value.trim(),keep:tr._keep||null})).filter(c=>c.name);}
function dGen(force){if(dEdited&&!force)return;const db=$('dSchema').value.trim(),name=$('dName').value.trim();const cols=dReadCols();const pk=cols.filter(c=>c.pk).map(c=>qid(c.name));
 if(!name){$('dSql').value='-- enter a table name';return;}const tbl=qid(db)+'.'+qid(name);
 if(!dOrig){let s='CREATE TABLE '+tbl+' (\n  '+cols.map(colDef).join(',\n  ');if(pk.length)s+=',\n  PRIMARY KEY ('+pk.join(',')+')';s+='\n);';$('dSql').value=s;dEdited=false;$('dEditNote').textContent='';return;}
 $('dSql').value=dAlterSql(dOrig,cols,tbl);dEdited=false;$('dEditNote').textContent='';}
async function dApply(){if(roBlock())return;const sql=$('dSql').value;$('dLog').textContent='Applying...';const r=await api('/api/script',{sql,db:curSchema});if(r.ok){$('dLog').textContent='Applied OK.';log('DESIGN OK');if(curSchema)loadObjects(curSchema);}else{const _n=ddlFailureNote(r.error,sql);$('dLog').textContent=_n;log('DESIGN error: '+_n);}}

// ---- export/import ----
const EXPOPTS=[
 ['hexblob','hex-blob',1,'Dump binary/BLOB columns as hexadecimal (e.g. abc becomes 0x616263).','Content'],
 ['tzutc','tz-utc (UTC times)',1,'Add SET TIME_ZONE=UTC so TIMESTAMP values restore the same in any timezone.','Content'],
 ['routines','routines (procs & funcs)',1,'Include stored procedures and functions in the dump.','Content'],
 ['triggers','triggers',1,'Include table triggers in the dump.','Content'],
 ['events','events (scheduler)',1,'Include scheduled events in the dump.','Content'],
 ['singletx','single-transaction',1,'Take a consistent snapshot without locking tables (recommended for InnoDB).','Performance'],
 ['adddropdb','add-drop-database',1,'Write DROP DATABASE before CREATE so a re-import replaces it cleanly.','Content'],
 ['adddroptb','add-drop-table',1,'Write DROP TABLE before each CREATE so a re-import replaces it cleanly.','Content'],
 ['createdb','include CREATE DATABASE',1,'Include CREATE DATABASE and USE so the dump can rebuild the schema anywhere.','Content'],
 ['extinsert','extended-insert (compact)',1,'Pack many rows into each INSERT: smaller files, much faster import.','Performance'],
 ['complete','complete-insert',0,'Write column names in every INSERT: safer if column order differs, but larger files.','Compatibility'],
 ['diskeys','disable-keys',1,'Disable indexes during load and rebuild them after: faster import.','Performance'],
 ['notablespaces','no-tablespaces',1,'Skip TABLESPACE clauses: avoids errors when the target server lacks them.','Compatibility'],
 ['quick','quick',1,'Stream rows instead of buffering the whole table: needed for very large tables.','Performance'],
 ['compress','compress',0,'Compress the client/server connection during the dump (more CPU, less network).','Performance'],
 ['gtid','set-gtid-purged=OFF',0,'Do not write GTID replication info: avoids import errors on non-GTID servers.','Compatibility'],
 ['colstats','column-statistics=0',0,'Disable column statistics: fixes an error when a MySQL 8 client dumps MariaDB.','Compatibility'],
 ['nodefiner','remove DEFINER clauses',1,'Strip DEFINER=`user`@`host` from views/triggers/procedures/events: without this, restoring on a server where that exact account does not exist fails or warns on every one of them.','Compatibility']
];
// openExport() rebuilds the option checkboxes every time it runs, so each one came back at
// its EXPOPTS default and any choice the user had made was silently discarded the next time
// the dialog opened. Unchecking "routines" and "events" then exporting again quietly dumped
// them anyway - and the same applied to add-drop-table, which is a good deal worse to get
// wrong by surprise. Remember the choices and put them back after the rebuild.
function expOptsLoad(){ try{ const v=JSON.parse(localStorage.getItem('nobsExpOpts')||'{}'); return (v&&typeof v==='object')?v:{}; }catch(e){ return {}; } }
function expOptsSave(){ const o={}; EXPOPTS.forEach(([k])=>{const el=$('eo_'+k); if(el)o[k]=!!el.checked;}); try{ localStorage.setItem('nobsExpOpts',JSON.stringify(o)); }catch(e){} }
function expOptsRestore(){
 const saved=expOptsLoad();
 EXPOPTS.forEach(([k])=>{
  const el=$('eo_'+k); if(!el)return;
  if(Object.prototype.hasOwnProperty.call(saved,k)) el.checked=!!saved[k];
  el.addEventListener('change',expOptsSave);
 });
}
async function openExport(preselect){const r=await api('/api/schemas');const box=$('expDbs');box.innerHTML='';if(r.ok)r.schemas.forEach(s=>{const safe=s.name.replace(/[^A-Za-z0-9]/g,'_');const dbAttr=esc(s.name).replace(/\x27/g,'\\x27');box.innerHTML+='<div class="expdbrow"><span class="exptoggle" id="expx_'+safe+'" onclick="expTables(\''+dbAttr+'\',\''+safe+'\')" title="Show tables to exclude">\u25B8</span><label class="ck" style="display:inline-flex"><input type="checkbox" class="expdb" value="'+esc(s.name)+'" onchange="expDbToggle(\''+safe+'\',this.checked)"> '+esc(s.name)+'</label><div class="exptbls" id="expt_'+safe+'" style="display:none"></div></div>';});const ob=$('expOpts');ob.innerHTML='';
const grouped={};EXPOPTS.forEach(o=>{const g=o[4]||'Other';(grouped[g]=grouped[g]||[]).push(o);});
['Content','Performance','Compatibility'].forEach(g=>{
  if(!grouped[g])return;
  ob.innerHTML+='<div style="grid-column:1/-1;font-weight:600;font-size:11px;color:var(--muted);margin-top:6px">'+g+'</div>';
  grouped[g].forEach(([k,l,d,t])=>{ob.innerHTML+='<label class="ck" title="'+esc(t||'')+'"><input type="checkbox" id="eo_'+k+'" '+(d?'checked':'')+'> '+l+'</label>';});
});
expOptsRestore();
expSyncFilenameField();
expApplyDumpFlavor();
if(preselect&&preselect.db){
  document.querySelectorAll('.expdb').forEach(cb=>{cb.checked=(cb.value===preselect.db);});
  if(preselect.table){
    const safe=preselect.db.replace(/[^A-Za-z0-9]/g,'_');
    await expTables(preselect.db,safe);
    document.querySelectorAll('#expt_'+safe+' .exptbl').forEach(cb=>{cb.checked=(cb.value===preselect.table);});
    if($('eo_routines'))$('eo_routines').checked=false;
    if($('eo_events'))$('eo_events').checked=false;
  }
}
show('mExport');}
function expAll(v){[...document.querySelectorAll('.expdb')].forEach(c=>c.checked=v);}
function expSyncFilenameField(){const row=$('expFilenameRow');if(row)row.style.display=$('expSingle').checked?'flex':'none';expUpdateFilenamePreview();}
// Its own row (matching Folder's label/width/casing) instead of squeezed into the dense options
// row above at 120px wide - plus a live preview of the actual resulting file name, since
// "timestamp" silently changes what gets written and a plain text box alone doesn't show that.
function expUpdateFilenamePreview(){const el=$('expFilenamePreview');if(!el)return;const inp=$('expFilename');const base=(inp.value||'').trim()||'all_selected';const stamp=$('expStamp').checked?'_'+expTimestampSample():'';const text='\u2192 '+base+stamp+'.sql';el.textContent=text;el.title=text;
 // Quiet unless you're actually closing in on the limit - a short, everyday filename shouldn't
 // have to share the row with a running character count.
 const cnt=$('expFilenameCount');if(cnt){const len=inp.value.length,max=inp.maxLength;
  if(len>=max-20){cnt.style.display='';cnt.textContent=len+'/'+max;cnt.style.color=(len>=max)?'var(--log-warn)':'';}
  else{cnt.style.display='none';}
 }}
function expTimestampSample(){const d=new Date();const p=n=>String(n).padStart(2,'0');return d.getFullYear()+p(d.getMonth()+1)+p(d.getDate())+'_'+p(d.getHours())+p(d.getMinutes())+p(d.getSeconds());}
// A few export options only exist on one mysqldump flavor: --set-gtid-purged is MySQL 5.6+
// only, --column-statistics is MySQL 8+ only - MariaDB's mysqldump has neither, and checking
// either against it aborts the WHOLE export with "unknown variable". Grey them out up front
// (based on tools_status's one-time `--version` check) instead of letting that be a surprise
// mid-export - the backend also has a friendlier error message as a fallback for anything this
// doesn't catch (an unusual custom mysqldump path, a version too old for a flag, etc).
const MYSQL_ONLY_EXPOPTS={
 gtid:'set-gtid-purged is MySQL 5.6+ only - not supported by MariaDB\u2019s mysqldump.',
 colstats:'column-statistics is MySQL 8+ only - not supported by MariaDB\u2019s mysqldump.'
};
async function expApplyDumpFlavor(){
 // The dump tool depends on the server (MySQL's own for a MySQL server, when there is one), so
 // ask for the connected one; the global status is the fallback for a backend that cannot say.
 let r=null; try{ r=await api('/api/tools-for-conn'); }catch(e){}
 let isMariaDb;
 if(r&&r.ok&&r.mysqldumpIsMariadb!=null){ isMariaDb=r.mysqldumpIsMariadb===true; }
 else{ try{ r=await api('/api/tools-status'); }catch(e){ return; } isMariaDb=!!(r&&r.ok&&r.mysqldump_is_mariadb===true); }
 Object.keys(MYSQL_ONLY_EXPOPTS).forEach(k=>{
  const el=$('eo_'+k); if(!el)return;
  const lbl=el.closest('label');
  let note=lbl&&lbl.querySelector('.expoptsdis');
  if(isMariaDb){
   el.disabled=true; el.checked=false;
   if(lbl){ lbl.title='Not supported: '+MYSQL_ONLY_EXPOPTS[k]; lbl.style.opacity='.55';
    if(!note){ note=document.createElement('span'); note.className='expoptsdis'; note.style.cssText='font-size:10px;color:var(--del);margin-left:4px'; note.textContent='(unsupported by this mysqldump)'; lbl.appendChild(note); } }
  } else {
   el.disabled=false;
   if(lbl)lbl.style.opacity='';
   if(note)note.remove();
  }
 });
}
async function expTables(db,safe){const c=$('expt_'+safe);if(!c)return;const cx=$('expx_'+safe);if(c.style.display==='none'){c.style.display='block';if(cx)cx.textContent='\u25BE';if(!c.dataset.loaded){c.innerHTML='<span class="muted" style="font-size:11px">Loading\u2026</span>';const q=await api('/api/query',{sql:'SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA='+lit(db)+' ORDER BY TABLE_NAME'});if(!q.ok){c.innerHTML='<span class="muted" style="font-size:11px">'+esc(q.error||'Could not list tables')+'</span>';return;}if(!q.rows.length){c.innerHTML='<span class="muted" style="font-size:11px">(no tables)</span>';c.dataset.loaded='1';return;}const dbCk=document.querySelector('.expdb[value="'+db.replace(/"/g,'&quot;')+'"]');const on=dbCk?dbCk.checked:true;let h='<div class="muted" style="font-size:11px;margin:1px 0 3px">Untick a table to exclude it from the export:</div>';q.rows.forEach(r=>{const tn=r[0];h+='<label class="ck" style="font-size:12px"><input type="checkbox" class="exptbl" data-db="'+esc(db)+'" value="'+esc(tn)+'" '+(on?'checked':'')+'> '+esc(tn)+'</label>';});c.innerHTML=h;c.dataset.loaded='1';}}else{c.style.display='none';if(cx)cx.textContent='\u25B8';}}
function expDbToggle(safe,on){document.querySelectorAll('#expt_'+safe+' .exptbl').forEach(c=>{c.checked=on;});}
async function runExport(){const dbs=[...document.querySelectorAll('.expdb:checked')].map(c=>c.value);
const tables=[...document.querySelectorAll('.exptbl:checked')].map(c=>c.dataset.db+'.'+c.value);

// Allow either databases OR tables to be selected
if(!dbs.length && !tables.length){
    toast('Select at least one database or table.',true);
    return;
}

// If no databases selected but tables are selected, extract the unique databases from tables
if(!dbs.length && tables.length){
    // Extract unique database names from the selected tables
    const tableDbs = [...new Set(tables.map(t => t.split('.')[0]))];
    dbs.push(...tableDbs);
}const o={charset:$('expCharset').value};EXPOPTS.forEach(([k])=>o[k]=$('eo_'+k).checked);o.maxpacket=$('expMaxPacket').value.trim();let mode='table';if($('expPer').checked)mode='db';else if($('expSingle').checked)mode='single';const excludes=[...document.querySelectorAll('.exptbl:not(:checked)')].filter(c=>dbs.includes(c.dataset.db)).map(c=>c.dataset.db+'.'+c.value);
 if(!$('expStamp').checked){
   const chk=await api('/api/browse',{path:$('expFolder').value,filter:'*.sql',dirsOnly:false});
   if(chk.ok && chk.files && chk.files.length>0){
     if(!(await ask('The export folder already contains '+chk.files.length+' .sql file(s), and "timestamp" is unchecked. Matching filenames will be overwritten. Continue?')))return;
   }
 }
 $('expLog').textContent='';
 let label='Exporting '+dbs.length+' database'+(dbs.length===1?'':'s');
 if(mode==='table'){try{const cq=await api('/api/query',{sql:"SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_TYPE='BASE TABLE' AND TABLE_SCHEMA IN ("+dbs.map(lit).join(',')+")"});if(cq.ok&&cq.rows.length){label+=' (~'+fmtCount(cq.rows[0][0])+' tables)';}}catch(e){}}
 const jobId=(crypto.randomUUID?crypto.randomUUID():('j'+Date.now()+Math.random()));
 progStart('exp',label,jobId);
 const r=await api('/api/export',{dbs,options:o,folder:$('expFolder').value,mode:mode,filename:$('expFilename').value.trim(),stamp:$('expStamp').checked,excludes:excludes,jobId:jobId});
 progStop('exp');
 if(r.cancelled){log('Export cancelled.');}
 if(!r.ok){showToolError('expLog','mExport',r.error);log('Export error: '+r.error);return;}
 $('expLog').innerHTML=logLinesHtml(r.log);r.log.forEach(l=>log('EXPORT: '+l));}
let _cmpTables=null;
async function cmpFillConnSelect(sel){sel.innerHTML='';const r=await api('/api/conn-list');if(r.ok)r.items.forEach(c=>{const o=document.createElement('option');o.value=c.name;o.textContent=c.name;sel.appendChild(o);});}
function cmpResetTablePicker(){const box=$('cmpTablesBox');if(box){box.innerHTML='';box.style.display='none';}}
function cmpSrcDbChanged(){cmpResetTablePicker();const srcVal=$('cmpSrcDb').value;const tgtSel=$('cmpTgtDb');if(srcVal&&tgtSel){const has=[...tgtSel.options].some(o=>o.value===srcVal);if(has)tgtSel.value=srcVal;}}
async function cmpToggleTablePicker(){const box=$('cmpTablesBox');
 if(box.style.display==='none'){
   const sc=$('cmpSrcConn').value,tc=$('cmpTgtConn').value,sd=$('cmpSrcDb').value,td=$('cmpTgtDb').value;
   if(!sc||!tc||!sd||!td){toast('Pick a connection and database on both sides first.',true);return;}
   box.style.display='block';box.innerHTML='<div class="muted">Loading tables\u2026</div>';
   const r=await api('/api/compare-tables',{sourceConnName:sc,sourceDb:sd,targetConnName:tc,targetDb:td});
   if(!r.ok){box.innerHTML='';toast(r.error||'Could not list tables',true);return;}
   if(!r.tables.length){box.innerHTML='<div class="muted">No tables found on either side.</div>';return;}
   let h='<div style="display:flex;align-items:center;gap:8px;margin-bottom:4px"><a href="#" onclick="cmpSetAllTables(true);return false" style="font-size:11px;color:var(--accent)">All</a> / <a href="#" onclick="cmpSetAllTables(false);return false" style="font-size:11px;color:var(--accent)">None</a><input id="cmpTableSearch" type="text" placeholder="filter tables\u2026" oninput="cmpFilterTablePicker()" style="flex:1;font-size:11px;margin-left:6px"></div>';
   h+='<div id="cmpTableList">';
   r.tables.forEach(tn=>{h+='<label class="ck cmptblrow" data-name="'+esc(tn.toLowerCase())+'" style="font-size:12px;display:block"><input type="checkbox" class="cmptbl" value="'+esc(tn)+'" checked> '+esc(tn)+'</label>';});
   h+='</div>';
   box.innerHTML=h;
 } else { box.style.display='none'; }}
function cmpSetAllTables(on){document.querySelectorAll('.cmptbl').forEach(c=>c.checked=on);}
function cmpFilterTablePicker(){const q=($('cmpTableSearch').value||'').toLowerCase();document.querySelectorAll('.cmptblrow').forEach(el=>{el.style.display=(!q||el.dataset.name.includes(q))?'block':'none';});}
async function cmpLoadDbs(side){const connSel=$(side==='src'?'cmpSrcConn':'cmpTgtConn');const dbSel=$(side==='src'?'cmpSrcDb':'cmpTgtDb');dbSel.innerHTML='<option value="">(loading\u2026)</option>';cmpResetTablePicker();
 if(!connSel.value){dbSel.innerHTML='';return;}
 const r=await api('/api/compare-dbs',{connName:connSel.value});
 if(!r.ok){dbSel.innerHTML='<option value="">(could not load)</option>';toast(r.error||'Could not list databases',true);return;}
 dbSel.innerHTML='';
 r.databases.forEach(name=>{const o=document.createElement('option');o.value=name;o.textContent=name;dbSel.appendChild(o);});
 // When switching the TARGET connection to a different instance, if the SOURCE database is
 // already picked and a database with that same name exists here too, preselect it - saves
 // having to manually re-pick the obvious match every time you compare against a new instance.
 if(side==='tgt'){
   const srcDbVal=$('cmpSrcDb')?$('cmpSrcDb').value:'';
   if(srcDbVal&&r.databases.includes(srcDbVal))dbSel.value=srcDbVal;
   $('cmpRoNote').style.display=r.readonly?'inline':'none';
 }}
async function openCompare(){$('cmpResults').innerHTML='';$('cmpLog').textContent='';$('cmpSummary').textContent='';const tr=$('cmpTallyRow');if(tr)tr.style.display='none';const rsr=$('cmpRowScanRow');if(rsr)rsr.style.display='none';const rss=$('cmpRowScanStatus');if(rss)rss.textContent='';_cmpTables=null;cmpResetTablePicker();
 await cmpFillConnSelect($('cmpSrcConn'));await cmpFillConnSelect($('cmpTgtConn'));
 if(window._primaryConn){$('cmpSrcConn').value=window._primaryConn;}
 await cmpLoadDbs('src');await cmpLoadDbs('tgt');
 show('mCompare');}
function cmpBadge(status){const map={missing_target:['missing on target','#4a2626','#f0997b'],missing_source:['missing on source','#4a2626','#f0997b'],diff:['differs','#4a4526','#facb75'],same:['structure identical','#1d3a2a','#5dcaa5']};const m=map[status]||['?','#333','#ccc'];return '<span style="background:'+m[1]+';color:'+m[2]+';border-radius:10px;padding:2px 8px;font-size:11px;white-space:nowrap">'+m[0]+'</span>';}
// Row-level result of cmpScanRowDiffs(), separate from cmpBadge()'s structure-only status -
// a table can be "structure identical" and still have missing or changed rows, which is exactly
// what this column exists to surface instead of making you click "rows\u2026" on every single one.
function cmpRowBadge(t){const rs=t.rowStatus;
 if(!rs||rs==='pending')return '<span class="muted" style="font-size:11px">\u2014</span>';
 if(rs==='checking')return '<span class="muted" style="font-size:11px">checking\u2026</span>';
 if(rs==='no_pk')return '<span class="muted" style="font-size:11px" title="No primary key - row comparison needs one to match rows up.">no primary key</span>';
 if(rs==='error')return '<span style="color:var(--del);font-size:11px" title="'+esc(t.rowError||'')+'">error</span>';
 if(rs==='match')return '<span style="background:#1d3a2a;color:#5dcaa5;border-radius:10px;padding:2px 8px;font-size:11px;white-space:nowrap">rows match</span>';
 const bits=[];if(t.rowMissing)bits.push(t.rowMissing+' missing');if(t.rowDiffer)bits.push(t.rowDiffer+' differ'+(t.rowDiffer===1?'s':''));
 const title=t.rowTruncated?'Content check only covered the first 500 matching rows - more may differ beyond that.':'';
 return '<span style="background:#4a4526;color:#facb75;border-radius:10px;padding:2px 8px;font-size:11px;white-space:nowrap" title="'+esc(title)+'">'+esc(bits.join(', ')||'differs')+'</span>';}
// Results (structure diff, tally, row-scan badges) describe whichever source/target pair was
// selected when "Run comparison" was last clicked - switching either connection or database
// afterward, without re-running, previously left all of that fully visible and clickable even
// though it no longer matches what's selected. Wipe it back to the pre-comparison empty state so
// stale results are never mistaken for current ones; a running row scan is stopped first so it
// doesn't keep writing into rows that no longer correspond to anything on screen.
function cmpResetResults(){
 if(_cmpRowScanRunning){_cmpRowScanCancelled=true;cmprCancelCurrent();}
 _cmpTables=null;
 const box=$('cmpResults');if(box)box.innerHTML='';
 const tr0=$('cmpTallyRow');if(tr0)tr0.style.display='none';
 const rsr=$('cmpRowScanRow');if(rsr)rsr.style.display='none';
 const rss=$('cmpRowScanStatus');if(rss)rss.textContent='';
 const sr=$('cmpResultsSearchRow');if(sr)sr.style.display='none';
 const sum=$('cmpSummary');if(sum)sum.textContent='';
 const log=$('cmpLog');if(log)log.textContent='';
}
function cmpTally(){const tr=$('cmpTallyRow'),t=$('cmpTally');if(!tr||!t)return;
 if(!_cmpTables||!_cmpTables.length){tr.style.display='none';return;}
 const c={same:0,diff:0,missing_target:0,missing_source:0};
 _cmpTables.forEach(x=>{c[x.status]=(c[x.status]||0)+1;});
 const differing=c.diff+c.missing_target+c.missing_source;
 const parts=[differing+' of '+_cmpTables.length+' table(s) differ'];
 if(c.diff)parts.push(c.diff+' differ'+(c.diff===1?'s':'')+' in structure');
 if(c.missing_target)parts.push(c.missing_target+' missing on target');
 if(c.missing_source)parts.push(c.missing_source+' missing on source');
 t.textContent=parts.join(' \u2014 ')+(differing?'':' (structure identical)');
 tr.style.display='block';}
function cmpRenderResults(){const box=$('cmpResults');const sr=$('cmpResultsSearchRow');const rsr=$('cmpRowScanRow');
 if(!_cmpTables||!_cmpTables.length){box.innerHTML='<div class="muted">No tables found on either side.</div>';if(sr)sr.style.display='none';if(rsr)rsr.style.display='none';cmpTally();return;}
 if(sr)sr.style.display=_cmpTables.length>8?'block':'none';
 if(rsr)rsr.style.display=_cmpTables.some(t=>t.status==='same')?'block':'none';
 cmpTally();
 let h='<table style="width:100%;border-collapse:collapse;font-size:12px"><tr class="muted" style="text-align:left;font-size:11px"><th style="padding:4px 6px"></th><th style="padding:4px 6px">Table</th><th style="padding:4px 6px">Status</th><th style="padding:4px 6px">Rows</th></tr>';
 _cmpTables.forEach((t,ti)=>{const hasSql=t.sql&&t.sql.length;
  h+='<tr class="cmpresultrow" data-name="'+esc(t.name.toLowerCase())+'" style="border-top:1px solid var(--bd2)"><td style="padding:6px">'+(hasSql?('<input type="checkbox" '+(t.sql.some(s=>s.checked)?'checked':'')+' onclick="cmpToggleAllForTable('+ti+',this.checked)">'):'')+'</td><td style="padding:6px">'+esc(t.name)+(hasSql?' <a href="#" onclick="cmpToggleDetail('+ti+');return false" style="font-size:11px;color:var(--accent);margin-left:6px">details</a>':'')+' <a href="#" onclick="cmpCompareRows('+ti+');return false" style="font-size:11px;color:var(--accent);margin-left:6px">rows\u2026</a></td><td style="padding:6px">'+cmpBadge(t.status)+'</td><td id="cmpRowCell_'+ti+'" style="padding:6px">'+cmpRowBadge(t)+'</td></tr>';
  h+='<tr id="cmpDetail_'+ti+'" class="cmpresultrow" data-name="'+esc(t.name.toLowerCase())+'" style="display:none"><td colspan="4" style="padding:0 6px 8px 20px">';
  t.sql.forEach((st,si)=>{h+='<div style="font-family:\'Cascadia Code\',Consolas,monospace;font-size:11px;margin:2px 0"><label><input type="checkbox" '+(st.checked?'checked':'')+' onclick="_cmpTables['+ti+'].sql['+si+'].checked=this.checked;cmpUpdateSummary()"> '+esc(st.stmt)+'</label></div>';});
  h+='</td></tr>';});
 h+='</table>';box.innerHTML=h;cmpUpdateSummary();cmpFilterResults();}
function cmpFilterResults(){const q=($('cmpResultSearch').value||'').toLowerCase();
 document.querySelectorAll('#cmpResults tr.cmpresultrow').forEach(el=>{
   const match=!q||el.dataset.name.includes(q);
   // a detail row (id starts with cmpDetail_) stays hidden unless the user has it expanded AND it matches
   if(el.id&&el.id.indexOf('cmpDetail_')===0){ el.style.display=(match&&el.dataset.expanded==='1')?'table-row':'none'; }
   else { el.style.display=match?'table-row':'none'; }
 });}
function cmpToggleDetail(ti){const el=$('cmpDetail_'+ti);if(el){const show=el.style.display==='none';el.style.display=show?'table-row':'none';el.dataset.expanded=show?'1':'0';}}
function cmpToggleAllForTable(ti,on){_cmpTables[ti].sql.forEach(s=>s.checked=on);cmpRenderResults();const el=$('cmpDetail_'+ti);if(el){el.style.display='table-row';el.dataset.expanded='1';}}
function cmpUpdateSummary(){if(!_cmpTables){$('cmpSummary').textContent='';return;}let n=0;_cmpTables.forEach(t=>t.sql.forEach(s=>{if(s.checked)n++;}));$('cmpSummary').textContent=n+' change(s) selected \u2022 SQL preview shown before apply';}
let _cmpRequestId=null;
let _cmpAbortCtrl=null;
function _cmpNewRequestId(){return 'cmp'+Date.now()+Math.random().toString(36).slice(2);}
async function cmpCancelCurrent(){
 // Mirrors cancelQuery(): abort the CLIENT-side fetch immediately (this is what actually clears
 // the loading indicator right away, regardless of server timing), and separately ask the
 // server to kill whatever's actually running under this id.
 if(_cmpAbortCtrl){try{_cmpAbortCtrl.abort();}catch(e){}}
 if(!_cmpRequestId)return;
 try{await api('/api/compare-cancel',{requestId:_cmpRequestId});}catch(e){}
}
async function cmpCloseAndCancel(){
 // cmpCancelCurrent() only knows about runCompare()'s own single request (_cmpRequestId) - it
 // has no idea a "Check row differences" scan might be mid-flight, using its own separate
 // _cmprRequestId/_cmpRowScanRunning state. Without also stopping that here, closing this dialog
 // while a scan was running left it going in the background against a now-hidden UI.
 if(_cmpRowScanRunning){_cmpRowScanCancelled=true;await cmprCancelCurrent();}
 await cmpCancelCurrent();
 hide('mCompare');
}
async function runCompare(){
 if(_cmpRequestId){toast('A comparison is already running - wait for it to finish or click Cancel first.',true);return;}
 const sc=$('cmpSrcConn').value,tc=$('cmpTgtConn').value,sd=$('cmpSrcDb').value,td=$('cmpTgtDb').value;
 if(!sc||!tc||!sd||!td){toast('Pick a connection and database on both sides.',true);return;}
 if(sc===tc&&sd===td){if(!(await ask('Source and target are the SAME connection and database ('+sc+' / '+sd+').\n\nComparing them will always show no differences. Continue anyway?')))return;}
 const rid=_cmpNewRequestId();_cmpRequestId=rid;_cmpAbortCtrl=new AbortController();
 $('cmpResults').innerHTML='<div class="muted">Comparing\u2026 <a href="#" onclick="cmpCancelCurrent();return false" style="color:var(--accent)">Cancel</a></div>';$('cmpLog').textContent='';
 const payload={sourceConnName:sc,sourceDb:sd,targetConnName:tc,targetDb:td,requestId:rid};
 const tblEls=document.querySelectorAll('.cmptbl');
 if(tblEls.length){payload.tables=[...tblEls].filter(c=>c.checked).map(c=>c.value);}
 const r=await api('/api/compare-schemas',payload,_cmpAbortCtrl.signal);
 _cmpRequestId=null;_cmpAbortCtrl=null;
 if(!r.ok){$('cmpResults').innerHTML='<div class="muted">'+esc(r.error||'Compare failed')+' <a href="#" onclick="runCompare();return false" style="color:var(--accent)">Retry</a></div>';toast(r.error||'Compare failed',true);return;}
 _cmpTables=r.tables;$('cmpRoNote').style.display=r.targetReadonly?'inline':'none';const _sb=$('cmpResultSearch');if(_sb)_sb.value='';cmpRenderResults();
 if(r.cancelled)toast('Comparison cancelled - showing '+_cmpTables.length+' table(s) checked before you stopped it.',true);}
function cmpSelectedStatements(){const out=[];if(_cmpTables)_cmpTables.forEach(t=>t.sql.forEach(s=>{if(s.checked)out.push(s.stmt);}));return out;}
function previewCompareSql(){const stmts=cmpSelectedStatements();if(!stmts.length){toast('No changes selected.',true);return;}viewText('Preview - '+stmts.length+' statement(s)',stmts.join('\n\n'),{readonly:true});}
async function applyCompare(){const stmts=cmpSelectedStatements();if(!stmts.length){toast('No changes selected.',true);return;}
 if(!(await ask('Run '+stmts.length+' statement(s) against the TARGET database ('+$('cmpTgtDb').value+')?\n\nThis cannot be undone. Use Preview SQL first if you have not already.')))return;
 $('cmpLog').textContent='Applying\u2026';
 const r=await api('/api/compare-apply',{targetConnName:$('cmpTgtConn').value,targetDb:$('cmpTgtDb').value,statements:stmts});
 if(!r.ok){$('cmpLog').textContent='';toast(r.error||'Apply failed',true);return;}
 $('cmpLog').innerHTML=logLinesHtml(r.log);
 log('Compare: applied '+stmts.length+' statement(s) to '+$('cmpTgtConn').value+'.');
 await runCompare();}
let _cmprState=null;
let _cmprDiffState=null;
let _cmprRequestId=null;
let _cmprAbortCtrl=null;
function _cmpFindTableIndex(name){return _cmpTables?_cmpTables.findIndex(t=>t.name===name):-1;}
async function cmprCancelCurrent(){
 // Mirrors cancelQuery(): abort the CLIENT-side fetch immediately (clears the loading indicator
 // right away, regardless of server timing), and separately ask the server to kill whatever's
 // actually running under this id.
 if(_cmprAbortCtrl){try{_cmprAbortCtrl.abort();}catch(e){}}
 if(!_cmprRequestId)return;
 try{await api('/api/compare-cancel',{requestId:_cmprRequestId});}catch(e){}
}
async function cmprCloseAndCancel(){await cmprCancelCurrent();hide('mCompareRows');}
// Bulk row-differences scan: for every "structure identical" table, runs exactly the same two
// calls cmpCompareRows() makes for one table (missing rows, then content diffs on the rest) -
// just automatically, table by table, so you don't have to click "rows\u2026" on each one to find out
// which are worth opening. Shares _cmprRequestId/_cmprAbortCtrl with the single-table flow so
// the two can never run concurrently (that guard already existed; this just also checks it).
let _cmpRowScanRunning=false;
let _cmpRowScanCancelled=false;
function cmpRowScanSetStatus(checked,total,differ,done){
 const el=$('cmpRowScanStatus');if(!el)return;
 if(done){el.textContent=(_cmpRowScanCancelled?'Stopped after ':'Checked ')+checked+' of '+total+' table(s) \u2014 '+differ+' have row differences.';return;}
 // On fast tables, the loop can finish the table currently in flight and re-render this same
 // status (for the NEXT table) within milliseconds of Stop being clicked - overwriting the
 // "Stopping\u2026" message before it's even visible, so Stop looked like it silently did nothing
 // most of the time. Once cancellation has been requested, leave that message alone; the loop's
 // own done=true call right after will show the real "Stopped after N of M" result.
 if(_cmpRowScanCancelled)return;
 // Reuse the SAME <button> element across re-renders instead of rebuilding it via innerHTML on
 // every table (up to hundreds of times, often milliseconds apart). A click needs its mousedown
 // AND mouseup to land on the same DOM node - replacing that node mid-click (very possible given
 // how often this fires) makes the browser silently drop the click: no handler call, no error,
 // nothing. That's indistinguishable from "the button just doesn't work", which is exactly what
 // it looked like. querySelector (not a cached reference) so this self-heals if something else
 // ever wipes this element's content (openCompare/cmpResetResults/cmpRowScanCancel's own message).
 let btn=el.querySelector('button'),txt;
 if(!btn){
  el.innerHTML='';
  txt=document.createTextNode('');
  btn=document.createElement('button');
  btn.type='button';btn.className='sm';btn.style.marginLeft='4px';btn.textContent='Stop';
  btn.onclick=cmpRowScanCancel;
  el.appendChild(txt);el.appendChild(btn);
 } else {
  txt=el.firstChild;
 }
 txt.textContent='Checking table '+checked+' of '+total+'\u2026 '+differ+' so far have row differences. ';
}
function cmpRowScanCancel(){
 _cmpRowScanCancelled=true;
 // A toast, not just the status-line text: it's a completely separate floating element that
 // doesn't depend on cmpRowScanStatus's current state or position, so it's a clean, unmissable
 // signal that the click itself was received - useful for telling "the click never reached this
 // handler" apart from "it reached the handler but the scan didn't actually stop".
 toast('Stopping the row-diff scan\u2026');
 const el=$('cmpRowScanStatus');if(el)el.textContent='Stopping\u2026 (finishing the table currently being checked)';
 cmprCancelCurrent();
}
async function cmpScanRowDiffs(){
 if(_cmprRequestId||_cmpRowScanRunning){toast('An operation is already running - wait for it to finish or stop it first.',true);return;}
 if(!_cmpTables)return;
 const scanTables=_cmpTables; // if re-running the comparison swaps this out mid-scan, stop rather than write into stale/renumbered rows
 // Respects "Choose specific tables" the same way Run comparison itself does: if that picker
 // has ever been loaded, only its currently-checked tables are in scope - unchecking most of a
 // 465-table list to focus on a handful should also narrow what a row-diff scan bothers with,
 // not just what a future re-run would compare.
 const tblEls=document.querySelectorAll('.cmptbl');
 const pickerNames=tblEls.length?new Set([...tblEls].filter(c=>c.checked).map(c=>c.value)):null;
 const targets=_cmpTables.map((t,ti)=>({t,ti})).filter(x=>x.t.status==='same'&&(!pickerNames||pickerNames.has(x.t.name)));
 if(!targets.length){toast(pickerNames?'No checked table in "Choose specific tables" is structure-identical.':'No structure-identical tables to check.',true);return;}
 const sc=$('cmpSrcConn').value,tc=$('cmpTgtConn').value,sd=$('cmpSrcDb').value,td=$('cmpTgtDb').value;
 _cmpRowScanRunning=true;_cmpRowScanCancelled=false;
 const btn=$('cmpRowScanBtn');if(btn)btn.disabled=true;
 let checked=0,differ=0;
 cmpRowScanSetStatus(checked,targets.length,differ,false);
 for(const {t,ti} of targets){
  if(_cmpRowScanCancelled||_cmpTables!==scanTables)break;
  t.rowStatus='checking';
  const cell=document.getElementById('cmpRowCell_'+ti);if(cell)cell.innerHTML=cmpRowBadge(t);
  const rid1=_cmpNewRequestId();_cmprRequestId=rid1;_cmprAbortCtrl=new AbortController();
  const r=await api('/api/compare-rows',{sourceConnName:sc,sourceDb:sd,targetConnName:tc,targetDb:td,table:t.name,requestId:rid1},_cmprAbortCtrl.signal);
  _cmprRequestId=null;_cmprAbortCtrl=null;
  if(r.cancelled||_cmpRowScanCancelled||_cmpTables!==scanTables)break;
  if(!r.ok){
   t.rowStatus=(r.error||'').toLowerCase().includes('no primary key')?'no_pk':'error';t.rowError=r.error;
  } else {
   t.rowMissing=r.missingTotal;
   const rid2=_cmpNewRequestId();_cmprRequestId=rid2;_cmprAbortCtrl=new AbortController();
   const rd=await api('/api/compare-rows-diff',{sourceConnName:sc,sourceDb:sd,targetConnName:tc,targetDb:td,table:t.name,requestId:rid2},_cmprAbortCtrl.signal);
   _cmprRequestId=null;_cmprAbortCtrl=null;
   if(rd.cancelled||_cmpRowScanCancelled||_cmpTables!==scanTables)break;
   if(!rd.ok){t.rowStatus='error';t.rowError=rd.error;}
   else{t.rowDiffer=rd.diffs.length;t.rowTruncated=!!rd.truncated;t.rowStatus=(t.rowMissing>0||t.rowDiffer>0)?'differ':'match';}
  }
  if(t.rowStatus==='differ')differ++;
  checked++;
  const cell2=document.getElementById('cmpRowCell_'+ti);if(cell2)cell2.innerHTML=cmpRowBadge(t);
  cmpRowScanSetStatus(checked,targets.length,differ,false);
 }
 _cmpRowScanRunning=false;if(btn)btn.disabled=false;
 cmpRowScanSetStatus(checked,targets.length,differ,true);
}
async function cmpCompareRows(ti){
 if(_cmprRequestId||_cmpRowScanRunning){toast('A row comparison is already running - wait for it to finish or click Cancel/Stop first.',true);return;}
 const t=_cmpTables[ti];
 const sc=$('cmpSrcConn').value,tc=$('cmpTgtConn').value,sd=$('cmpSrcDb').value,td=$('cmpTgtDb').value;
 if(sc===tc&&sd===td){if(!(await ask('Source and target are the SAME connection and database ('+sc+' / '+sd+').\n\nComparing them will always show no differences. Continue anyway?')))return;}
 $('cmprTitle').textContent='Row comparison - '+t.name;
 $('cmprNote').innerHTML='Comparing\u2026 <a href="#" onclick="cmprCancelCurrent();return false" style="color:var(--accent)">Cancel</a>';$('cmprGrid').innerHTML='';$('cmprSummary').textContent='';$('cmprDiffNote').textContent='';$('cmprDiffGrid').innerHTML='';$('cmprDiffSummary').textContent='';$('cmprLog').textContent='';$('cmprRoNote').style.display='none';$('cmprDiffRoNote').style.display='none';
 // A table missing on the target side entirely (t.status==='missing_target') is still worth
 // showing here - the backend deliberately treats it as an empty table so every source row
 // correctly shows as "missing", which is genuinely useful information (here's what WOULD sync
 // once the table exists). What must NOT happen is silently letting Insert run against it: the
 // resulting INSERT would just fail at the database level with an easy-to-miss per-batch error
 // buried in the log, rather than a clear, upfront reason. cmprApply() below hard-blocks on this
 // flag before it ever makes the API call, the same way it already does for a read-only target.
 const targetTableMissing=(t.status==='missing_target');
 $('cmprMissingNote').style.display=targetTableMissing?'inline':'none';
 _cmprState=null;_cmprDiffState=null;
 show('mCompareRows');
 const rid1=_cmpNewRequestId();_cmprRequestId=rid1;_cmprAbortCtrl=new AbortController();
 const r=await api('/api/compare-rows',{sourceConnName:sc,sourceDb:sd,targetConnName:tc,targetDb:td,table:t.name,requestId:rid1},_cmprAbortCtrl.signal);
 _cmprRequestId=null;_cmprAbortCtrl=null;
 if(!r.ok){$('cmprNote').textContent='';$('cmprGrid').innerHTML='<div class="muted" style="padding:8px">'+esc(r.error||'Could not compare rows.')+' <a href="#" onclick="cmpCompareRows('+ti+');return false" style="color:var(--accent)">Retry</a></div>';return;}
 _cmprState={table:t.name,pkCols:r.pkCols,columns:r.columns,rows:r.rows.map(row=>({data:row,checked:true})),sourceConnName:sc,sourceDb:sd,targetConnName:tc,targetDb:td,missingTotal:r.missingTotal,truncated:r.truncated,allMissingPks:r.allMissingPks||[],extraTotal:r.extraTotal||0,extraPks:r.extraPks||[],targetTableMissing:targetTableMissing};
 var _cmprCancelNote1=r.cancelled?' (cancelled - only some tables/rows were checked before you stopped it)':'';
 $('cmprNote').innerHTML=r.missingTotal+' row(s) missing on target'+(r.truncated?(' (showing first '+r.rows.length+' for review - <a href="#" onclick="cmprInsertAll();return false" style="color:var(--accent)">insert all '+r.missingTotal+' without reviewing them</a>)'):'')+_cmprCancelNote1+'. Rows are inserted with the SAME '+r.pkCols.join('/')+ ' value(s) as the source (insert-only - existing target rows are never changed).'+cmprExtraNote(r.extraTotal,r.extraPks,r.pkCols);
 $('cmprRoNote').style.display=r.targetReadonly?'inline':'none';
 cmprRender();

 $('cmprDiffNote').innerHTML='Comparing content\u2026 <a href="#" onclick="cmprCancelCurrent();return false" style="color:var(--accent)">Cancel</a>';
 const rid2=_cmpNewRequestId();_cmprRequestId=rid2;_cmprAbortCtrl=new AbortController();
 const rd=await api('/api/compare-rows-diff',{sourceConnName:sc,sourceDb:sd,targetConnName:tc,targetDb:td,table:t.name,requestId:rid2},_cmprAbortCtrl.signal);
 _cmprRequestId=null;_cmprAbortCtrl=null;
 if(!rd.ok){$('cmprDiffNote').innerHTML=esc(rd.error||'Could not compare row content.')+' <a href="#" onclick="cmpCompareRows('+ti+');return false" style="color:var(--accent)">Retry</a>';return;}
 _cmprDiffState={table:t.name,pkCols:rd.pkCols,fkCols:rd.fkCols||[],targetConnName:tc,targetDb:td,rows:rd.diffs.map(d=>({pk:d.pk,colDiffs:d.colDiffs,checked:true}))};
 $('cmprDiffRoNote').style.display=rd.targetReadonly?'inline':'none';
 var _cmprTruncMsg = rd.truncated
  ? ('. IMPORTANT: only the first '+rd.comparedCount+' matching rows were checked - there are more, and real differences outside this batch will NOT show here. Narrow down to fewer tables/rows for a complete check.')
  : '.';
 var _cmprCancelNote2=rd.cancelled?' (cancelled early - not all matching rows were checked)':'';
 $('cmprDiffNote').textContent=rd.diffs.length+' row(s) differ, out of '+rd.comparedCount+' row(s) with a matching id that were checked'+_cmprCancelNote2+_cmprTruncMsg+' Updating OVERWRITES the target row with the source values shown below.';
 cmprDiffRender();
}
function cmprDiffRender(){
 const box=$('cmprDiffGrid');
 if(!_cmprDiffState||!_cmprDiffState.rows.length){box.innerHTML='<div class="muted" style="padding:8px">No column differences - every row that shares an id on both sides currently has matching content.</div>';$('cmprDiffSummary').textContent='';return;}
 // Rows are matched purely by having the SAME id (primary key) on both sides; for each matched
 // pair, every column is compared and only the columns that actually differ are outlined below.
 // Every row is tinted with the "changed" color (same var(--dirty) used elsewhere for edited
 // cells) so differing rows stand out at a glance, and the whole row is clickable to toggle its
 // checkbox (not just the tiny box itself) - selected rows switch to the hover-accent tint so
 // it's obvious which ones are queued for the update. The Column/Source/Target table itself is
 // collapsed behind "Show details" by default and only rendered on demand, so a long list of
 // differing rows stays scannable instead of every row unfolding into a full table at once.
 let h='';
 _cmprDiffState.rows.forEach((r,ri)=>{
  const expanded=!!r._expanded;
  h+='<div data-ri="'+ri+'" style="border-top:1px solid var(--bd2);padding:6px;cursor:pointer;background:'+(r.checked?'var(--hover)':'var(--dirty)')+'" onclick="cmprDiffToggleRow('+ri+')">';
  h+='<label onclick="event.stopPropagation()" style="display:flex;align-items:center;gap:6px;font-weight:600;cursor:pointer"><input type="checkbox" '+(r.checked?'checked':'')+' onclick="_cmprDiffState.rows['+ri+'].checked=this.checked;cmprDiffRowRestyle('+ri+');cmprDiffUpdateSummary()"> id = '+esc(r.pk.join(', '))+' <span class="muted" style="font-weight:400">('+r.colDiffs.length+' column'+(r.colDiffs.length===1?'':'s')+' differ)</span> <a href="#" onclick="event.preventDefault();event.stopPropagation();cmprDiffToggleDetails('+ri+')" style="font-size:11px;color:var(--accent);font-weight:400;margin-left:auto">'+(expanded?'Hide details \u25B4':'Show details \u25BE')+'</a></label>';
  if(expanded){
   h+='<table style="width:100%;border-collapse:collapse;font-size:11px;margin-top:4px"><tr class="muted" style="text-align:left"><th style="padding:2px 6px;width:25%">Column</th><th style="padding:2px 6px;width:37%">Source</th><th style="padding:2px 6px;width:37%">Target (current)</th></tr>';
   r.colDiffs.forEach((cd,ci)=>{
    const isPk=(_cmprDiffState.pkCols||[]).indexOf(cd.col)>=0;const isFk=(_cmprDiffState.fkCols||[]).indexOf(cd.col)>=0;
    const kb=(isPk?' <span class="muted" style="font-size:9px;font-weight:700;line-height:1;vertical-align:middle;color:var(--erd-pk,#5dcaa5)" title="Primary key">PK</span>':'')+(isFk?' <span class="muted" style="font-size:9px;font-weight:700;line-height:1;vertical-align:middle;color:var(--erd-line,#7aa8d8)" title="Foreign key">FK</span>':'');
    // Every cell here opens the viewer, not just the ones long enough to be visibly clipped -
    // consistent "click to inspect" affordance across the whole grid beats a mix of clickable and
    // non-clickable cells that looks identical until you try clicking one. stopPropagation keeps
    // the click from also toggling the row's checkbox via the row-level handler above.
    h+='<tr><td style="padding:2px 6px;font-weight:600;cursor:pointer" title="Click to view" onclick="event.stopPropagation();cmprDiffViewCell('+ri+','+ci+',\'col\')">'+esc(cd.col)+kb+'</td>'
     +'<td style="padding:2px 6px;color:var(--erd-pk,#5dcaa5);cursor:pointer" title="Click to view full value" onclick="event.stopPropagation();cmprDiffViewCell('+ri+','+ci+',\'src\')">'+(cd.src===null?'<span class="muted" style="font-style:italic">NULL</span>':esc(clip(String(cd.src),80)))+'</td>'
     +'<td style="padding:2px 6px;color:var(--diff-tgt,#f0997b);cursor:pointer" title="Click to view full value" onclick="event.stopPropagation();cmprDiffViewCell('+ri+','+ci+',\'tgt\')">'+(cd.tgt===null?'<span class="muted" style="font-style:italic">NULL</span>':esc(clip(String(cd.tgt),80)))+'</td></tr>';
   });
   h+='</table>';
  }
  h+='</div>';
 });
 box.innerHTML=h;cmprDiffUpdateSummary();
}
// Same reasoning as cmprViewCell below: reopens the shared read-only cell-viewer rather than a
// one-off for this grid.
function cmprDiffViewCell(ri,ci,which){const cd=_cmprDiffState.rows[ri].colDiffs[ci];
 if(which==='col'){viewText('Column name',cd.col,{readonly:true});return;}
 const v=which==='src'?cd.src:cd.tgt;viewText(cd.col+' ('+(which==='src'?'Source':'Target')+')',v,{readonly:true});}
function cmprDiffToggleDetails(ri){_cmprDiffState.rows[ri]._expanded=!_cmprDiffState.rows[ri]._expanded;cmprDiffRender();}
function cmprDiffToggleRow(ri){_cmprDiffState.rows[ri].checked=!_cmprDiffState.rows[ri].checked;cmprDiffRowRestyle(ri);cmprDiffUpdateSummary();}
function cmprDiffRowRestyle(ri){const r=_cmprDiffState.rows[ri];const el=$('cmprDiffGrid').querySelector('div[data-ri="'+ri+'"]');if(!el)return;el.style.background=r.checked?'var(--hover)':'var(--dirty)';const cb=el.querySelector('input[type=checkbox]');if(cb)cb.checked=r.checked;}
function cmprDiffUpdateSummary(){if(!_cmprDiffState){$('cmprDiffSummary').textContent='';return;}const n=_cmprDiffState.rows.filter(r=>r.checked).length;$('cmprDiffSummary').textContent=n+' of '+_cmprDiffState.rows.length+' selected';}
function cmprDiffSetAll(on){if(!_cmprDiffState)return;_cmprDiffState.rows.forEach(r=>r.checked=on);cmprDiffRender();}
async function cmprDiffApply(){
 if(!_cmprDiffState)return;
 const updates=_cmprDiffState.rows.filter(r=>r.checked).map(r=>({pk:r.pk,colDiffs:r.colDiffs}));
 if(!updates.length){toast('No rows selected.',true);return;}
 if(!(await ask('Update '+updates.length+' row(s) in '+_cmprDiffState.table+' on the TARGET database to match the source?\n\nThis OVERWRITES the differing columns on those target rows and cannot be undone.')))return;
 $('cmprLog').textContent='Updating\u2026';
 const r=await api('/api/compare-rows-apply-diff',{targetConnName:_cmprDiffState.targetConnName,targetDb:_cmprDiffState.targetDb,table:_cmprDiffState.table,pkCols:_cmprDiffState.pkCols,updates:updates});
 if(!r.ok){$('cmprLog').textContent='';toast(r.error||'Update failed',true);return;}
 log('Compare: updated rows in '+_cmprDiffState.table+' on '+_cmprDiffState.targetConnName+'.');
 const tableName=_cmprDiffState.table,ti=_cmpFindTableIndex(tableName);
 if(ti>=0){await cmpCompareRows(ti);}
 toast('Updated '+updates.length+' row(s) in '+tableName+'. Results refreshed.');
}
// Rows the TARGET holds that the source does not. Nothing in this dialog acts on them - the
// comparison is insert-only and never deletes from the target - but leaving them unreported let
// a target carrying extra rows read as "no row differences", which is the wrong answer to hand
// someone checking a production database against a copy. So: always stated, never acted on.
function cmprExtraNote(total,pks,pkCols){
 if(!total)return '';
 pks=pks||[];
 const shown=pks.slice(0,10).map(r=>esc(r.map(v=>v==null?'NULL':v).join('/'))).join(', ');
 const ellipsis=total>Math.min(pks.length,10)?' …':'';
 return '<div class="muted" style="margin-top:6px"><b>'+total+'</b> row(s) exist only on the target'
  +(shown?(' ['+esc((pkCols||[]).join('/'))+': '+shown+ellipsis+']'):'')
  +" - reported only; this comparison never deletes from the target.</div>";
}
function cmprRender(){
 const box=$('cmprGrid');
 if(!_cmprState||!_cmprState.rows.length){box.innerHTML='<div class="muted" style="padding:8px">No missing rows - target already has everything the source has.</div>';$('cmprSummary').textContent='';return;}
 let h='<table style="width:100%;border-collapse:collapse;font-size:11px"><tr class="muted" style="text-align:left"><th style="padding:3px 6px"></th>';
 _cmprState.columns.forEach(c=>{h+='<th style="padding:3px 6px">'+esc(c)+'</th>';});
 h+='</tr>';
 // Every row is tinted with the "missing" color (same var(--del) used elsewhere for deleted rows
 // and the missing-on-target schema badge) so they stand out as a block, and the whole row is
 // clickable to toggle its checkbox rather than just the small box itself - selected rows switch
 // to the hover-accent tint so it's clear which ones are queued for insert.
 _cmprState.rows.forEach((r,ri)=>{
  h+='<tr data-ri="'+ri+'" style="border-top:1px solid var(--bd2);cursor:pointer;background:'+(r.checked?'':'var(--del)')+'" onclick="cmprToggleRow('+ri+')"><td style="padding:3px 6px" onclick="event.stopPropagation()"><input type="checkbox" '+(r.checked?'checked':'')+' onclick="_cmprState.rows['+ri+'].checked=this.checked;cmprRowRestyle('+ri+');cmprUpdateSummary()"></td>';
  // Every non-NULL field opens the viewer, not just ones long enough to be visibly clipped - a
  // consistent click-to-inspect affordance across the whole grid, matching the column-diff table.
  // stopPropagation keeps a value click from also toggling the row's checkbox.
  r.data.forEach((v,ci)=>{h+='<td style="padding:3px 6px;white-space:nowrap;max-width:220px;overflow:hidden;text-overflow:ellipsis'+(v===null?'':';cursor:pointer')+'" title="'+esc(v===null?'NULL':'Click to view full value')+'"'+(v===null?'':' onclick="event.stopPropagation();cmprViewCell('+ri+','+ci+')"')+'>'+(v===null?'<span class="muted" style="font-style:italic">NULL</span>':esc(clip(v,120)))+'</td>';});
  h+='</tr>';
 });
 h+='</table>';box.innerHTML=h;cmprUpdateSummary();
}
// Only wired up on cells long enough to actually be clipped (see cmprRender above) - reopens the
// same read-only cell-viewer modal used throughout the app, rather than a bespoke one just for
// this grid, so it gets Copy/full-size/Ctrl+wheel zoom for free.
function cmprViewCell(ri,ci){const r=_cmprState.rows[ri];const v=r.data[ci];const col=_cmprState.columns[ci];viewText('Missing row - '+col,v,{readonly:true});}
function cmprToggleRow(ri){_cmprState.rows[ri].checked=!_cmprState.rows[ri].checked;cmprRowRestyle(ri);cmprUpdateSummary();}
function cmprRowRestyle(ri){const r=_cmprState.rows[ri];const tr=$('cmprGrid').querySelector('tr[data-ri="'+ri+'"]');if(!tr)return;tr.style.background=r.checked?'':'var(--del)';const cb=tr.querySelector('input[type=checkbox]');if(cb)cb.checked=r.checked;}
function cmprUpdateSummary(){if(!_cmprState){$('cmprSummary').textContent='';return;}const n=_cmprState.rows.filter(r=>r.checked).length;$('cmprSummary').textContent=n+' of '+_cmprState.rows.length+' selected';}
function cmprSetAll(on){if(!_cmprState)return;_cmprState.rows.forEach(r=>r.checked=on);cmprRender();}
async function cmprInsertAll(){
 if(!_cmprState)return;
 if(_cmprState.targetTableMissing){toast('The target table doesn\'t exist yet - create it first (via the schema comparison\'s "details"), then come back to insert rows.',true);return;}
 if(_cmprRequestId){toast('An operation is already running - wait for it to finish or click Cancel first.',true);return;}
 const total=_cmprState.missingTotal||0;
 if(!(await ask('Insert ALL '+total+' missing row(s) into '+_cmprState.table+' on the TARGET database, WITHOUT reviewing them individually first?\n\nThis uses the SAME '+_cmprState.pkCols.join('/')+' value(s) as the source (insert-only) and cannot be undone.')))return;
 const rid=_cmpNewRequestId();_cmprRequestId=rid;_cmprAbortCtrl=new AbortController();
 $('cmprLog').innerHTML='Inserting all '+total+' row(s)\u2026 <a href="#" onclick="cmprCancelCurrent();return false" style="color:var(--accent)">Cancel</a>';
 const r=await api('/api/compare-rows-insert-all',{sourceConnName:_cmprState.sourceConnName,sourceDb:_cmprState.sourceDb,targetConnName:_cmprState.targetConnName,targetDb:_cmprState.targetDb,table:_cmprState.table,requestId:rid},_cmprAbortCtrl.signal);
 _cmprRequestId=null;_cmprAbortCtrl=null;
 if(!r.ok){$('cmprLog').innerHTML=esc(r.error||'Insert failed')+' <a href="#" onclick="cmprInsertAll();return false" style="color:var(--accent)">Retry</a>';toast(r.error||'Insert failed',true);return;}
 if(r.cancelled){$('cmprLog').innerHTML='Cancelled ('+(r.inserted||0)+' row(s) inserted before the cancel are already in the target). <a href="#" onclick="cmprInsertAll();return false" style="color:var(--accent)">Retry</a>';return;}
 const tableName=_cmprState.table,ti=_cmpFindTableIndex(tableName);
 // Deliberately NOT auto-refreshing here: for a large table this just re-runs the same
 // expensive full-table scan (fetching every id from both sides) that a moment ago needed
 // Cancel in the first place. Offer it as a link instead of doing it automatically.
 $('cmprLog').innerHTML=(r.cancelled?'Cancelled - ':'')+'Inserted '+r.inserted+' of '+r.missingTotal+' row(s).\n'+esc(r.log.join('\n'))+(ti>=0?'\n<a href="#" onclick="cmpCompareRows('+ti+');return false" style="color:var(--accent)">Refresh comparison</a>':'');
 log('Compare: bulk-inserted '+r.inserted+' row(s) into '+_cmprState.table+' on '+_cmprState.targetConnName+' (no preview).');
}
function _cmprPkKey(pkArr){return pkArr.map(v=>String(v)).join('\u0001');}
async function cmprApply(){
 if(!_cmprState)return;
 if(_cmprState.targetTableMissing){toast('The target table doesn\'t exist yet - create it first (via the schema comparison\'s "details"), then come back to insert rows.',true);return;}
 const insertedRows=_cmprState.rows.filter(r=>r.checked);
 const rows=insertedRows.map(r=>r.data);
 if(!rows.length){toast('No rows selected.',true);return;}
 if(!(await ask('Insert '+rows.length+' row(s) into '+_cmprState.table+' on the TARGET database, using the same '+_cmprState.pkCols.join('/')+' value(s) as the source?\n\nThis cannot be undone.')))return;
 $('cmprLog').textContent='Inserting\u2026';
 const r=await api('/api/compare-rows-apply',{targetConnName:_cmprState.targetConnName,targetDb:_cmprState.targetDb,table:_cmprState.table,columns:_cmprState.columns,rows:rows});
 if(!r.ok){$('cmprLog').textContent='';toast(r.error||'Insert failed',true);return;}
 log('Compare: inserted rows into '+_cmprState.table+' on '+_cmprState.targetConnName+'.');
 await cmprTopUpAfterInsert(insertedRows);
 toast('Inserted '+rows.length+' row(s) into '+_cmprState.table+'.');
}
// After an insert, we already know EXACTLY which rows are no longer missing (the ones we just
// inserted) and we already know the FULL list of ids that were missing before (allMissingPks) -
// so instead of re-running the whole comparison (re-scanning the entire table again), we just
// remove the inserted ids from that known list and fetch full data for the next batch. No
// full-table rescan needed until the user explicitly asks for one.
async function cmprTopUpAfterInsert(insertedRows){
 if(!_cmprState||!_cmprState.allMissingPks)return;
 const pkIdx=_cmprState.pkCols.map(c=>_cmprState.columns.indexOf(c));
 const insertedKeys=new Set(insertedRows.map(r=>_cmprPkKey(pkIdx.map(i=>r.data[i]))));
 _cmprState.allMissingPks=_cmprState.allMissingPks.filter(pk=>!insertedKeys.has(_cmprPkKey(pk)));
 _cmprState.missingTotal=Math.max(0,(_cmprState.missingTotal||0)-insertedRows.length);
 const cap=2000;
 const nextBatch=_cmprState.allMissingPks.slice(0,cap);
 if(nextBatch.length){
   $('cmprLog').textContent='Loading next '+nextBatch.length+' row(s) to review\u2026';
   const rr=await api('/api/compare-rows-fetch-by-pk',{sourceConnName:_cmprState.sourceConnName,sourceDb:_cmprState.sourceDb,table:_cmprState.table,pkCols:_cmprState.pkCols,pks:nextBatch});
   if(!rr.ok){$('cmprLog').textContent='';toast(rr.error||'Could not load the next batch - try Refresh.',true);_cmprState.rows=[];cmprRender();return;}
   _cmprState.rows=rr.rows.map(row=>({data:row,checked:true}));
   $('cmprLog').textContent='';
 } else {
   _cmprState.rows=[];
 }
 const stillTruncated=_cmprState.allMissingPks.length>_cmprState.rows.length;
 $('cmprNote').innerHTML=_cmprState.missingTotal+' row(s) missing on target'+(stillTruncated?(' (showing next '+_cmprState.rows.length+' for review - <a href="#" onclick="cmprInsertAll();return false" style="color:var(--accent)">insert all '+_cmprState.missingTotal+' without reviewing them</a>)'):'')+'. Rows are inserted with the SAME '+_cmprState.pkCols.join('/')+' value(s) as the source (insert-only - existing target rows are never changed).'+cmprExtraNote(_cmprState.extraTotal,_cmprState.extraPks,_cmprState.pkCols);
 cmprRender();
}
// Reset every field to its fresh-open default here rather than on Close - Escape closes the
// topmost modal directly (see the plToggleAutoRefresh comment above for the same issue), which
// would bypass a close-time reset entirely. Resetting on open works regardless of how it was
// last closed.
async function openImport(){$('impFiles').value='';$('impLog').textContent='';$('impCreate').checked=false;$('impFk').checked=true;$('impForce').checked=false;$('impBinary').checked=false;$('impMaxPacket').value='1G';const dl=$('impDbList');dl.innerHTML='';const inp=$('impDb');inp.value=(typeof curSchema!=='undefined'&&curSchema)?curSchema:'';try{const r=await api('/api/schemas');if(r.ok)r.schemas.forEach(s=>{const o=document.createElement('option');o.value=s.name;dl.appendChild(o);});}catch(e){}show('mImport');}
async function runImport(){const files=$('impFiles').value.split(/\r?\n/).map(s=>s.trim()).filter(Boolean);if(!files.length){toast('Add at least one file path.',true);return;}
 $('impLog').textContent='';
 const jobId=(crypto.randomUUID?crypto.randomUUID():('j'+Date.now()+Math.random()));
 progStart('imp','Importing '+files.length+' file'+(files.length===1?'':'s'),jobId);
 const r=await api('/api/import',{files,targetDb:$('impDb').value.trim(),createDb:$('impCreate').checked,fkOff:$('impFk').checked,force:$('impForce').checked,binaryMode:$('impBinary').checked,maxpacket:$('impMaxPacket').value.trim(),jobId:jobId});
 progStop('imp');
 if(r.cancelled){log('Import cancelled.');}
 if(!r.ok){showToolError('impLog','mImport',r.error);log('Import error: '+r.error);return;}
 $('impLog').innerHTML=logLinesHtml(r.log);r.log.forEach(l=>log('IMPORT: '+l));}
async function quit(){
 const activeJobs=Object.keys(_progJobIds||{}).filter(k=>_progJobIds[k]);
 const runningQueryTabs=tabs.filter(t=>t.runningReqId);
 if(activeJobs.length || runningQueryTabs.length){
   const what=[];if(activeJobs.length)what.push(activeJobs.length+' export/import job(s)');if(runningQueryTabs.length)what.push(runningQueryTabs.length+' running quer'+(runningQueryTabs.length===1?'y':'ies'));
   if(!(await ask(what.join(' and ')+' still running. Quitting now will stop them abruptly and any partial files may be incomplete. Quit anyway?')))return;
 }
 disconnect();
 try{await api('/api/quit');}catch(e){}
 try{window.open('','_self');window.close();}catch(e){}
 setTimeout(()=>{document.body.innerHTML='<div style="padding:40px;font-size:16px">Server stopped. You can close this tab.<br><span style="color:#888;font-size:13px">(Your browser blocks pages from auto-closing tabs it didn\'t open.)</span></div>';},150);}

// ---- server-side file/folder picker ----
let brState={filter:'',mode:'file',cb:null,cur:'',parent:'ROOT'};
// A minimized floating modal still has the .show class on its outer element (only its inner
// .box is hidden), so it would otherwise get swept into this hide/restore cycle even though it's
// already out of the way and non-blocking. Excluding it here means hide()'s minimize-cleanup
// logic never runs on it during this temporary detour, so a deliberately-minimized modal (e.g.
// Export, left running in the background) stays minimized rather than silently popping back up
// fully expanded once the file browser closes.
function browse(opts){const open=[...document.querySelectorAll('.modal.show')].map(m=>m.id).filter(x=>x!=='mBrowse'&&!window._floatingMinimized[x]);brState={filter:opts.filter||'',mode:opts.mode||'file',cb:opts.onPick,cur:'',parent:'ROOT',hidden:open};open.forEach(id=>hide(id));$('brTitle').textContent=opts.title||'Browse';show('mBrowse');brNav(opts.start||'ROOT');}
async function brNav(path){const r=await api('/api/browse',{path,filter:brState.filter,dirsOnly:brState.mode==='folder'});
 if(!r.ok){if(path!=='ROOT'){brNav('ROOT');}else{toast(r.error,true);}return;}
 brState.cur=r.path;brState.parent=r.parent;$('brPath').textContent=r.path||'(drives)';
 const list=$('brList');list.innerHTML='';
 r.dirs.forEach(d=>{const el=document.createElement('div');el.className='item';el.innerHTML='&#128193; '+esc(d.name);el.onclick=()=>brNav(d.path);list.appendChild(el);});
 if(brState.mode!=='folder')r.files.forEach(f=>{const el=document.createElement('div');el.className='item';
   if(brState.mode==='files'){el.innerHTML='<label><input type="checkbox" class="brf" value="'+esc(f.path)+'"> &#128196; '+esc(f.name)+'</label>';}
   else{el.innerHTML='&#128196; '+esc(f.name);el.onclick=()=>{const c=brState.cb,pth=f.path;brClose();c(pth);};}
   list.appendChild(el);});
 const a=$('brActions');
 if(brState.mode==='folder')a.innerHTML='<button class="go" onclick="brPickFolder()">Select this folder</button>';
 else if(brState.mode==='files')a.innerHTML='<button class="go" onclick="brPickFiles()">Add selected</button>';
else a.innerHTML='<span class="muted">click a folder to open, click a file to choose</span>';}
function brUp(){brNav(brState.parent||'ROOT');}
function brClose(){hide('mBrowse');(brState.hidden||[]).forEach(id=>show(id));}
function brPickFolder(){const c=brState.cb,v=brState.cur;brClose();c(v);}
function brPickFiles(){const sel=[...document.querySelectorAll('.brf:checked')].map(c=>c.value);const c=brState.cb;brClose();c(sel);}
function impAppend(paths){const cur=$('impFiles').value.trim();const add=paths.filter(Boolean).join('\n');$('impFiles').value=(cur?cur+'\n':'')+add;}
function impAddFiles(){browse({title:'Select SQL files',filter:'*.sql',mode:'files',onPick:ps=>{impAppend(ps);log('Added '+ps.length+' file(s).');}});}
function impAddFolder(){browse({title:'Select a folder (imports all .sql inside)',mode:'folder',onPick:async folder=>{const r=await api('/api/browse',{path:folder,filter:'*.sql',dirsOnly:false});if(r.ok){const ps=r.files.map(f=>f.path);impAppend(ps);log('Added '+ps.length+' .sql file(s) from '+folder);}else toast(r.error,true);}});}
// ---- close tabs ----
async function closeAll(){const dirty=tabs.filter(t=>pendingCount(t)>0);if(dirty.length){if(!(await ask(dirty.length+' tab(s) have unsaved changes. Close all and discard them?')))return;}
 await Promise.all(tabs.filter(t=>t.runningReqId).map(t=>cancelQuery(t.id)));
 tabs.forEach(t=>closeCursorFor(t));
 [...tabs].forEach(t=>{$('tabbtn_'+t.id).remove();$('pane_'+t.id).remove();});tabs=[];activeTab=null;saveSession();toggleOverview();const _sb=$('schemaBadge');if(_sb){_sb.style.display='none';_sb.textContent='';}}
async function closeOthers(id){const dirty=tabs.filter(t=>t.id!==id&&pendingCount(t)>0);if(dirty.length){if(!(await ask(dirty.length+' other tab(s) have unsaved changes. Close them and discard the changes?')))return;}
 const others=tabs.filter(t=>t.id!==id);
 await Promise.all(others.filter(t=>t.runningReqId).map(t=>cancelQuery(t.id)));
 others.forEach(t=>closeCursorFor(t));
 others.forEach(t=>{$('tabbtn_'+t.id).remove();$('pane_'+t.id).remove();});tabs=tabs.filter(t=>t.id===id);activate(id);}

// ---- keyboard navigation for side lists ----
function focusList(box){box.focus();const items=[...box.querySelectorAll('.item')];if(items.length){items.forEach(x=>x.classList.remove('kbsel'));items[0].classList.add('kbsel');items[0].scrollIntoView({block:'nearest'});}}
function listNav(box,e){const items=[...box.querySelectorAll('.item')];if(!items.length)return;let i=items.findIndex(x=>x.classList.contains('kbsel'));
 if(e.key==='ArrowDown'){e.preventDefault();i=Math.min(items.length-1,i+1);}
 else if(e.key==='ArrowUp'){e.preventDefault();i=Math.max(0,i-1);}
 else if(e.key==='Enter'){e.preventDefault();if(i>=0)items[i].click();return;}
 else return;
 items.forEach(x=>x.classList.remove('kbsel'));if(i<0)i=0;items[i].classList.add('kbsel');items[i].scrollIntoView({block:'nearest'});}
document.addEventListener('DOMContentLoaded',()=>{});
$('schemas').addEventListener('keydown',e=>listNav($('schemas'),e));
$('objects').addEventListener('keydown',e=>listNav($('objects'),e));

// ---- lightweight SQL autocomplete ----
const AC_KW=['SELECT','FROM','WHERE','INSERT INTO','UPDATE','DELETE FROM','SET','VALUES','JOIN','LEFT JOIN','RIGHT JOIN','INNER JOIN','OUTER JOIN','ON','GROUP BY','ORDER BY','HAVING','LIMIT','OFFSET','DISTINCT','AS','AND','OR','NOT','NULL','IS NULL','IS NOT NULL','LIKE','IN','BETWEEN','EXISTS','COUNT','SUM','AVG','MIN','MAX','CREATE TABLE','ALTER TABLE','DROP TABLE','TRUNCATE TABLE','CREATE INDEX','PRIMARY KEY','FOREIGN KEY','REFERENCES','DEFAULT','AUTO_INCREMENT','UNIQUE','ASC','DESC','USE','SHOW','DESCRIBE','EXPLAIN','UNION','UNION ALL','CASE','WHEN','THEN','ELSE','END'];
let acItems=[],acIdx=0,acTa=null;
function acVisible(){return $('acx').style.display==='block';}
function acHide(){$('acx').style.display='none';acItems=[];}
function caretXY(ta){const div=document.createElement('div');const cs=getComputedStyle(ta);
 ['fontFamily','fontSize','fontWeight','lineHeight','paddingTop','paddingLeft','paddingRight','paddingBottom','letterSpacing','tabSize'].forEach(k=>div.style[k]=cs[k]);
 div.style.position='absolute';div.style.visibility='hidden';div.style.whiteSpace='pre';div.style.border='1px solid transparent';
 const before=ta.value.slice(0,ta.selectionStart);div.textContent=before;const span=document.createElement('span');span.textContent='\u200b';div.appendChild(span);
 document.body.appendChild(div);const r=ta.getBoundingClientRect();const x=r.left+span.offsetLeft-ta.scrollLeft;const y=r.top+span.offsetTop-ta.scrollTop;const lh=parseFloat(cs.lineHeight)||16;document.body.removeChild(div);return {x,y,lh};}
function acSuggest(word){const w=word.toLowerCase();const out=[],seen=new Set();
 const push=arr=>{(arr||[]).forEach(v=>{if(!v)return;const lv=String(v).toLowerCase();if(!seen.has(lv)&&lv.startsWith(w)){seen.add(lv);out.push(String(v));}});};
 if(objData){push(objData.r.tables);push(objData.r.views);push(objData.r.procedures);push(objData.r.functions);}
 push(window.acColumns||[]);push(window.allSchemas||[]);push(AC_KW);
 return out.slice(0,12);}
// --- Autocomplete: suggest table/column/keyword names as you type in the editor.
function acUpdate(id,force){const ta=$('ed_'+id);const pos=ta.selectionStart;const before=ta.value.slice(0,pos);const m=before.match(/[A-Za-z_][A-Za-z0-9_]*$/);
 if(!m||(!force&&m[0].length<2)){acHide();return;}
 const sug=acSuggest(m[0]);if(!sug.length){acHide();return;}
 acItems=sug;acIdx=0;acTa=ta;acRender();const c=caretXY(ta);const box=$('acx');box.style.left=Math.min(c.x,innerWidth-180)+'px';box.style.top=(c.y+c.lh+2)+'px';box.style.display='block';}
function acRender(){const box=$('acx');box.innerHTML='';acItems.forEach((v,i)=>{const d=document.createElement('div');d.className='ai'+(i===acIdx?' on':'');d.textContent=v;d.addEventListener('mousedown',e=>{e.preventDefault();acIdx=i;acAccept(activeTab);});box.appendChild(d);});}
function acMove(dir){acIdx=(acIdx+dir+acItems.length)%acItems.length;acRender();const on=$('acx').querySelector('.ai.on');if(on)on.scrollIntoView({block:'nearest'});}
// Accepting a suggestion replaces the partial word before the cursor (already handled) AND
// consumes any word-characters immediately after the cursor with no gap before them (the fix
// here) - otherwise accepting while the cursor sits right before leftover, un-separated text
// (e.g. from an earlier accepted suggestion that wasn't fully cleared first) mashes the new
// suggestion and that old text together with no separator between them.
function acAccept(id){const ta=acTa||$('ed_'+id);const pos=ta.selectionStart;const before=ta.value.slice(0,pos);const after=ta.value.slice(pos);const m=before.match(/[A-Za-z_][A-Za-z0-9_]*$/);const start=pos-(m?m[0].length:0);const mAfter=after.match(/^[A-Za-z0-9_]+/);const end=pos+(mAfter?mAfter[0].length:0);const val=acItems[acIdx]||'';
 ta.value=ta.value.slice(0,start)+val+ta.value.slice(end);const np=start+val.length;ta.selectionStart=ta.selectionEnd=np;acHide();syncHl(id);ta.focus();}

let csvTarget={db:null,table:null};
async function exportFull(db,name,fmt){fmt=fmt||'csv';const ext=(fmt==='inserts')?'sql':'csv';const defName=name+(fmt==='inserts'?'_inserts.sql':'.csv');
 if(window.__TAURI__&&window.__TAURI__.core){let path;try{path=await window.__TAURI__.dialog.save({defaultPath:defName,filters:[{name:ext.toUpperCase()+' file',extensions:[ext]}]});}catch(e){toast('Save dialog failed: '+e,true);return;}if(!path)return;log('Exporting all rows of '+db+'.'+name+'...');const r=await window.__TAURI__.core.invoke('export_table',{req:{conn:getConn(),db:db,table:name,file:path,format:fmt,nullValue:csvNullMarker()}});if(r&&r.ok){log(r.message);toast(r.message,'ok');}else toast('Export failed: '+(r?r.error:'unknown'),true);return;}
 try{
   const cq=await api('/api/query',{sql:"SELECT TABLE_ROWS FROM information_schema.TABLES WHERE TABLE_SCHEMA="+lit(db)+" AND TABLE_NAME="+lit(name)});
   const est=(cq.ok&&cq.rows.length&&cq.rows[0][0]!=null)?+cq.rows[0][0]:null;
   if(est!=null&&est>10000){
     if(await ask(db+'.'+name+' has approximately '+fmtCount(est)+' rows.\n\nThe dedicated Export tool (top toolbar) streams straight to disk and will be much faster for a table this size, instead of loading everything into memory first.\n\nOpen the Export tool instead?')){
       openExport({db,table:name});return;
     }
     if(!(await ask('Continue exporting '+db+'.'+name+' via the query engine anyway? This may take a while for a table this size.'))){return;}
   }
 }catch(e){}
 // Named columns: every one for CSV, invisible ones included (SELECT * leaves them out); INSERTs
 // leave out generated columns, which cannot be given a value (the CSV import skips them).
 const info=await tableColumnsInfo(db,name);if(!info){toast('Could not read the columns of '+db+'.'+name+'.',true);return;}
 const expCols=info.filter(c=>fmt!=='inserts'||!c.generated).map(c=>c.name);
 const q=await api('/api/query',{sql:'SELECT '+expCols.map(qid).join(',')+' FROM '+qid(db)+'.'+qid(name),db:db});if(!q.ok){toast(q.error,true);return;}
 if(await refuseNulTextExport(db,name))return;
 if(fmt==='inserts'){const tbl=qid(db)+'.'+qid(name);const bc=await tableBinCols(db,name,q.columns);const s=q.rows.map(r=>insertSkipExisting(tbl,q.columns,'('+r.map((v,i)=>litAs(v,bc?bc[i]:null)).join(',')+')')).join('\n');dl(s,defName);}
 else{dl(bCSV(q.columns,q.rows),defName);}}
function importCsv(db,table){csvTarget={db,table};$('csvTitle').textContent='Import CSV into '+db+'.'+table;$('csvFile').value='';$('csvLog').textContent='';show('mCsv');}
async function runCsvImport(){const f=$('csvFile').value.trim();if(!f){toast('Choose a CSV file.',true);return;}
 const doTrunc=$('csvReplace').checked;
 if(doTrunc && !(await ask('REPLACE mode: truncate '+csvTarget.db+'.'+csvTarget.table+' before import? All existing rows will be permanently deleted.')))return;
 $('csvLog').textContent='Importing...';
 const r=await api('/api/importcsv',{nullValue:($('csvNullVal')?$('csvNullVal').value:'\\N'),db:csvTarget.db,table:csvTarget.table,file:f,hasHeader:$('csvHeader').checked,truncate:doTrunc});
 if(!r.ok){$('csvLog').textContent=r.error;log('CSV import error: '+r.error);return;}
 $('csvLog').textContent=r.message;log('CSV import: '+r.message);invalidateTableCache(csvTarget.db,csvTarget.table);if(curSchema)loadObjects(curSchema);}

// Auto-reconnect on page load (Option 1)
refreshConns().then(async () => {
  const sel = $('connlist');
  // Explicitly select the PRIMARY connection if one is set - but either way, load whatever
  // ends up selected. Previously this only ever called pickConn() when a primary was
  // explicitly configured, but the browser's own <select> default behavior already lands on
  // the first real saved connection regardless (skipping the hidden placeholder option) - so
  // the dropdown could visually show a connection selected while the form's host/port/user/
  // pass silently stayed at their hardcoded HTML defaults, never actually loaded from that
  // connection at all. Gating on sel.value instead of window._primaryConn means the form (and
  // the password indicator) always reflect whatever's really selected, with at most one saved
  // connection, not just the specific one someone happened to mark primary.
  if (sel && window._primaryConn) {
    for (let i = 0; i < sel.options.length; i++) {
      if (sel.options[i].value === window._primaryConn) { sel.selectedIndex = i; break; }
    }
  }
  if (sel && sel.value) {
    await pickConn(); // loads host, port, user, password, ssl into the form
    connTitle();
  }
});

toggleOverview();
libLoad();
let _pingFails = 0;
function _ping(){ return fetch('/api/ping', { method:'POST', keepalive:true, headers:{'Content-Type':'application/json'}, body:JSON.stringify({token:TOKEN}) }).then(()=>{_pingFails=0;}).catch(()=>{_pingFails++; if(_pingFails>=2) showDead();}); }
setInterval(_ping, 5000);
document.addEventListener('visibilitychange', ()=>{ if(!document.hidden) _ping(); });
document.body.classList.add('disconnected');

// ---- update notice ----
// A fixed card in the bottom-left corner, not part of the top bar: at common window widths the
// bar has almost no room left, and a notice there pushed it onto a second line.
// Says when a newer release exists and links to it; nothing is downloaded or installed. Asked once
// per start unless switched off in Settings, and a version the user hid stays hidden.
let _update=null;
function updateCheckOn(){try{return localStorage.getItem('updateCheck')!=='off';}catch(e){return true;}}
function setUpdateCheck(on){try{localStorage.setItem('updateCheck',on?'on':'off');}catch(e){}if(!on){const el=$('updNote');if(el)el.style.display='none';}}
async function checkForUpdate(manual){
 if(!manual&&!updateCheckOn())return null;
 let r=null;try{r=await api('/api/update-check');}catch(e){}
 if(!r||!r.ok){if(manual)toast('Could not check for a new version'+(r&&r.error?': '+r.error:'.'),true);return r;}
 _update=r;
 let hidden='';try{hidden=localStorage.getItem('updateDismissed')||'';}catch(e){}
 const el=$('updNote'),a=$('updLink');
 if(el&&a){
  if(r.newer&&(manual||hidden!==r.latest)){a.textContent='Version '+r.latest+' available';a.title='You have '+r.current+'. Opens the release notes and download page.';el.style.display='';}
  else el.style.display='none';
 }
 if(manual)toast(r.newer?('Version '+r.latest+' is available - you have '+r.current+'.'):('You have the latest version ('+r.current+').'),'ok');
 return r;
}
async function openUpdatePage(){
 if(!_update||!_update.url)return;
 if(window.__TAURI__){const r=await api('/api/open-release-page',{url:_update.url});if(r&&!r.ok)toast(r.error||'Could not open the release page.',true);}
 else window.open(_update.url,'_blank','noopener');
}
function dismissUpdate(){if(!_update)return;try{localStorage.setItem('updateDismissed',_update.latest);}catch(e){}const el=$('updNote');if(el)el.style.display='none';}
setTimeout(()=>{checkForUpdate(false);},3000);
window.addEventListener('beforeunload',e=>{saveSession();if(anyPending()){e.preventDefault();e.returnValue='';return '';}});
(function(){function initSideResize(){const sd=$('side'),rz=$('sideResize'),mn=$('main');if(!sd||!rz||!mn){setTimeout(initSideResize,300);return;}const saved=parseInt(localStorage.getItem('sideW')||'',10);if(saved&&saved>=280)sd.style.width=saved+'px';let drag=false;rz.addEventListener('pointerdown',e=>{drag=true;rz.classList.add('drag');try{rz.setPointerCapture(e.pointerId);}catch(_){}document.body.style.userSelect='none';e.preventDefault();});rz.addEventListener('pointermove',e=>{if(!drag)return;const left=mn.getBoundingClientRect().left;let w=e.clientX-left;const max=Math.max(280,window.innerWidth-320);w=Math.max(280,Math.min(w,max));sd.style.width=w+'px';});const end=e=>{if(!drag)return;drag=false;rz.classList.remove('drag');try{rz.releasePointerCapture(e.pointerId);}catch(_){}document.body.style.userSelect='';localStorage.setItem('sideW',String(parseInt(sd.style.width,10)||280));};rz.addEventListener('pointerup',end);rz.addEventListener('pointercancel',end);rz.addEventListener('dblclick',()=>{sd.style.width='280px';localStorage.setItem('sideW','280');});}initSideResize();})();
</script></body></html>
'@
$Html = $Html.Replace('__TOKEN__', $Token).Replace('__APP_VERSION__', $script:AppVersion)

Resolve-Tools
# Probe the client's SSL flag dialect once here, so the answer is seeded into every runspace
# below rather than each of them shelling out to "mysql.exe --version" on its first connection.
[void](Test-ClientIsMariaDB)
# Use a STABLE port so the app origin stays constant across restarts.
# (Browser localStorage - favorites, accent colors, env labels, query library,
#  session tabs - is scoped per origin; a random port would wipe it every launch.)
$listener = $null; $port = 0
foreach ($try in @(17673,17674,17675,17676,17677,17678,17679,17680)) {
    try { $l = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, $try); $l.Start(); $listener = $l; $port = $try; break }
    catch { $listener = $null }
}
if (-not $listener) {
    $listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, 0)
    $listener.Start(); $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    Write-Host "  (Fixed ports busy - using random port $port; saved UI settings may not persist this run.)" -ForegroundColor Yellow
}
$url = "http://127.0.0.1:$port/"
Write-Host ""
Write-Host "  NOBS SQL Editor $script:AppVersion is running." -ForegroundColor Green
Write-Host "  Open:  $url"
if ($script:MysqlPath){ Write-Host "  mysql:     $script:MysqlPath" } else { Write-Host "  mysql.exe NOT found - open Settings in the app to select it, or to download the MariaDB client tools." -ForegroundColor Yellow }
if ($script:MysqldumpPath){ Write-Host "  mysqldump: $script:MysqldumpPath" }
Write-Host "  Close this window to stop the server." -ForegroundColor DarkGray
Write-Host ""
function Start-AppWindow {
    param([string]$Url)
    $cands = @(
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    )
    $exe = $cands | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($exe) {
        $profile = Join-Path $env:LOCALAPPDATA 'NOBSSQL\browser'
        if (-not (Test-Path $profile)) { New-Item -ItemType Directory -Path $profile -Force | Out-Null }
        Disable-BrowserAutofill $profile
        $w=1280; $h=860
        try { Add-Type -AssemblyName System.Windows.Forms; $wa=[System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea; $w=$wa.Width; $h=$wa.Height } catch {}
        # -PassThru + a dedicated --user-data-dir (not shared with any other Chrome/Edge instance)
        # means the process handle we get back here really is the app window's own browser process
        # - not a short-lived launcher stub that hands off to an existing instance and exits
        # immediately, which is what happens WITHOUT a dedicated profile. That's what lets the main
        # server loop below actually notice when the app window closes (see $script:BrowserProcess),
        # instead of only ever finding out via the 6-hour idle-ping timeout - otherwise, closing the
        # app window without clicking its own Quit button (the only other thing that stops the
        # server today) leaves the server - and the fixed port it's holding - alive for up to 6
        # hours, and enough of those in a row exhausts all 8 fallback ports and forces a random one,
        # silently resetting every localStorage-based setting (pinned tables, hidden columns, accent
        # colors, session tabs) the next time the app is opened.
        $script:BrowserProcess = Start-Process $exe -ArgumentList @("--app=$Url","--user-data-dir=`"$profile`"","--no-first-run","--no-default-browser-check","--disable-save-password-bubble","--disable-features=AutofillServerCommunication","--start-maximized","--window-position=0,0","--window-size=$w,$h") -PassThru
        return $true
    }
    return $false
}
# --disable-save-password-bubble (above) only hides the post-submit "save password?" popup - it
# doesn't stop Chrome/Edge from actually autofilling a PREVIOUSLY saved credential into a field
# (see the Chrome-autofill password-clobbering bug this fixed), and there's no single command-line
# flag that turns the password manager and form-autofill off outright. The real, documented way is
# this profile's own Preferences file - the same JSON file Chrome/Edge itself writes settings into,
# just pre-set here before the browser ever starts. Since $profile (above) is a dedicated, NOBSSQL-
# only browser profile - never the user's actual everyday Chrome/Edge profile - this can't affect
# their normal browsing; it only ever touches this one private, single-purpose profile.
# Runs on every launch (not just the first) so it keeps winning even if a browser update, an
# extension, or a stray "Save password?" click that slipped through ever re-enables either setting.
function Disable-BrowserAutofill {
    param([string]$ProfileDir)
    try {
        $prefsDir = Join-Path $ProfileDir 'Default'
        if (-not (Test-Path $prefsDir)) { New-Item -ItemType Directory -Path $prefsDir -Force | Out-Null }
        $prefsPath = Join-Path $prefsDir 'Preferences'
        $prefs = $null
        if (Test-Path $prefsPath) {
            try { $raw = [IO.File]::ReadAllText($prefsPath); if ($raw.Trim()) { $prefs = $raw | ConvertFrom-Json } } catch { $prefs = $null }
        }
        if (-not $prefs) { $prefs = [pscustomobject]@{} }
        # credentials_enable_service is the actual master switch (save prompts AND autofill of
        # already-saved passwords); autosignin and the legacy profile.password_manager_enabled key
        # are set alongside it since older/newer Chromium builds have looked in different places for
        # essentially the same setting. autofill.profile_enabled/credit_card_enabled cover the
        # separate address/payment-info autofill the user also asked to have off.
        $setPath = {
            param($obj, $path, $value)
            $parts = $path -split '\.'
            $cur = $obj
            for ($i = 0; $i -lt $parts.Length - 1; $i++) {
                $p = $parts[$i]
                if (-not ($cur.PSObject.Properties[$p])) { $cur | Add-Member -MemberType NoteProperty -Name $p -Value ([pscustomobject]@{}) }
                elseif ($cur.$p -isnot [System.Management.Automation.PSCustomObject]) { $cur.$p = [pscustomobject]@{} }
                $cur = $cur.$p
            }
            $last = $parts[-1]
            if ($cur.PSObject.Properties[$last]) { $cur.$last = $value } else { $cur | Add-Member -MemberType NoteProperty -Name $last -Value $value }
        }
        & $setPath $prefs 'credentials_enable_service' $false
        & $setPath $prefs 'credentials_enable_autosignin' $false
        & $setPath $prefs 'profile.password_manager_enabled' $false
        & $setPath $prefs 'autofill.profile_enabled' $false
        & $setPath $prefs 'autofill.credit_card_enabled' $false
        [IO.File]::WriteAllText($prefsPath, ($prefs | ConvertTo-Json -Depth 10 -Compress), (New-Object System.Text.UTF8Encoding($false)))
    } catch {}
}
if (-not $NoBrowser){ if (-not (Start-AppWindow $url)) { Start-Process $url | Out-Null } }

# ============================================================================
#  RUNSPACE POOL SETUP
#  Lets multiple requests (e.g. a slow query in one tab + ping from another)
#  run concurrently instead of one blocking the whole server.
# ============================================================================
$CustomFunctionNames = (Get-ChildItem function:).Name | Where-Object { $BuiltinFunctionNames -notcontains $_ }

$iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
foreach ($fn in $CustomFunctionNames) {
    $fsb = (Get-Item "function:$fn").ScriptBlock
    $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry($fn, $fsb)))
}
foreach ($vn in 'MysqlPath','MysqldumpPath','ServerIsMariaDB','ClientIsMariaDB','DumpIsMariaDB','DumpDbSource','CfgFile','ToolsDir','ConnFile','LibFile','ReservedSet','RunningQueries','RunningJobs','OpenCursors','CancelledCompares','NoHeadersNote','ServerFlavor','DefaultMariaDbUrlTemplate','ClientAuthPlugins','AppVersion','ReleasesRepo','RawEnc','StrictUtf8','JStrSpecialChars','PackedPayload') {
    $vv = Get-Variable -Scope Script -Name $vn -ValueOnly -ErrorAction SilentlyContinue
    $iss.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry($vn,$vv,'')))
}
$iss.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry('Token',$Token,'')))
$iss.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry('Html',$Html,'')))

# Shared, thread-safe heartbeat timestamp (regular $script: vars don't cross runspaces)
$SharedState = [hashtable]::Synchronized(@{ LastPing = Get-Date })
$iss.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry('SharedState',$SharedState,'')))

$Pool = [runspacefactory]::CreateRunspacePool(1, 8, $iss, $Host)   # max 8 concurrent requests - tune if needed
$Pool.Open()
$InFlight = New-Object System.Collections.Generic.List[object]

# The actual per-request work, run inside a pooled runspace so it doesn't block the accept loop.
$RequestHandler = {
    param($client, $Token, $Html)
    try {
        $req = Read-Request $client
        if ($req.path -eq '/api/ping') {
            # Token-checked like every other /api/* route. Ping refreshes LastPing, which is what
            # the idle-shutdown check below reads - so while this was unauthenticated, any web
            # page the user happened to have open could hold the server (and the live database
            # connections and credentials it holds) open indefinitely with a periodic cross-origin
            # POST to this fixed, predictable port. It could not read the reply, but it did not
            # need to: the side effect was the whole point. The real page already knows the token.
            $data=$null; try { if($req.body){ $data=$req.body | ConvertFrom-Json } } catch { }
            if (-not $data -or $data.token -ne $Token) { Send-Json $client '{"ok":false,"error":"bad token"}'; return }
            $SharedState.LastPing = Get-Date; Send-Json $client '{"ok":true}'; return
        }
        if ($req.path -eq '/' -or $req.path -eq '/index.html') { Send-Http $client '200 OK' 'text/html; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($Html)); return }
        if ($req.path -eq '/api/quit') {
            # Same token check every other /api/* route gets below - without it, any local
            # process (or script, or malicious page if this port were ever reachable another
            # way) could force-quit the server with a bare unauthenticated POST. The frontend's
            # own quit() already sends the token via api()'s p.token=TOKEN, so this costs nothing
            # for the legitimate caller.
            $data=$null; try { if($req.body){ $data=$req.body | ConvertFrom-Json } } catch { }
            if (-not $data -or $data.token -ne $Token) { Send-Json $client '{"ok":false,"error":"bad token"}'; return }
            Send-Json $client '{"ok":true}'; $SharedState.Quit = $true; return
        }
        if ($req.path -like '/api/*') {
            $data=$null; try { if($req.body){ $data=$req.body | ConvertFrom-Json } } catch { }
            if (-not $data -or $data.token -ne $Token) { Send-Json $client '{"ok":false,"error":"bad token"}'; return }
            $conn=$data.conn
            $roBlocked = $false
            if ([bool]$data.ro) {
                switch -Regex ($req.path) {
                    '/api/(rowop|import|importcsv|kill-process)$' { $roBlocked = $true }
                    '/api/(exec|script|script-results|query)$' { if (-not (Test-SqlReadOnly ([string]$data.sql))) { $roBlocked = $true } }
                }
            }
            if ($roBlocked) { Send-Json $client '{"ok":false,"error":"This connection is READ-ONLY (safe mode). The server blocked a write operation."}'; return }
            switch ($req.path) {
                '/api/connect' { Send-Json $client (Api-Connect $conn) }
                '/api/schemas' { Send-Json $client (Api-Schemas $conn) }
                '/api/objects' { Send-Json $client (Api-Objects $conn $data.db) }
                '/api/ddl'     { Send-Json $client (Api-Ddl $conn $data.db $data.type $data.name) }
                '/api/pk'      { Send-Json $client (Api-Pk $conn $data.db $data.table) }
                '/api/fk'      { Send-Json $client (Api-Fk $conn $data.db $data.table) }
                '/api/query'   { Send-Json $client (Api-Query $conn $data.sql $data.db $data.requestId $data.pageSize $data.exactText) }
                '/api/fetch-cursor-batch' { Send-Json $client (Api-FetchCursorBatch $data) }
                '/api/close-cursor' { Send-Json $client (Api-CloseCursor $data) }
                '/api/cancel-query' { Send-Json $client (Api-CancelQuery $data) }
                '/api/cancel-job'   { Send-Json $client (Api-CancelJob $data) }
                '/api/exec'    { Send-Json $client (Api-Exec $conn $data) }
                '/api/schema-erd' { Send-Json $client (Api-SchemaErd $conn $data.db) }
                '/api/process-list' { Send-Json $client (Api-ProcessList $conn) }
                '/api/kill-process' { Send-Json $client (Api-KillProcess $conn $data) }
                '/api/script'  { Send-Json $client (Api-Script $conn $data) }
                '/api/script-results' { Send-Json $client (Api-ScriptResults $conn $data) }
                '/api/rowop'   { Send-Json $client (Api-RowOp $conn $data) }
                '/api/export'  { Send-Json $client (Api-Export $conn $data) }
                '/api/import'  { Send-Json $client (Api-Import $conn $data) }
                '/api/importcsv'   { Send-Json $client (Api-ImportCsv $conn $data) }
				'/api/search-all-schemas' { Send-Json $client (Api-SearchAllSchemas $conn $data.term) }
                '/api/browse'      { Send-Json $client (Api-Browse $data) }
                '/api/tools-status'   { Send-Json $client (Api-ToolsStatus) }
                '/api/tools-for-conn' { Send-Json $client (Api-ToolsForConn $conn) }
                '/api/get-config'     { Send-Json $client (Api-GetConfig) }
                '/api/save-config'    { Send-Json $client (Api-SaveConfig $data) }
                '/api/download-tools' { Send-Json $client (Api-DownloadTools) }
                '/api/download-mysql-tools' { Send-Json $client (Api-DownloadMysqlTools) }
                '/api/update-check' { Send-Json $client (Api-UpdateCheck) }
                '/api/conn-list'   { Send-Json $client (Api-ConnList) }
                '/api/conn-get'    { Send-Json $client (Api-ConnGet $data) }
                '/api/conn-save'   { Send-Json $client (Api-ConnSave $data) }
                '/api/conn-delete' { Send-Json $client (Api-ConnDelete $data) }
                '/api/conn-clear'  { Send-Json $client (Api-ConnClear) }
                '/api/conn-primary'{ Send-Json $client (Api-ConnSetPrimary $data) }
                '/api/compare-dbs'     { Send-Json $client (Api-CompareDbs $data) }
                '/api/compare-tables'  { Send-Json $client (Api-CompareTables $data) }
                '/api/compare-cancel'  { Send-Json $client (Api-CompareCancel $data) }
                '/api/compare-rows'       { Send-Json $client (Api-CompareRows $data) }
                '/api/compare-rows-apply' { Send-Json $client (Api-CompareRowsApply $data) }
                '/api/compare-rows-fetch-by-pk' { Send-Json $client (Api-CompareRowsFetchByPk $data) }
                '/api/gen-user-transfer' { Send-Json $client (Api-GenUserTransfer $conn $data) }
                '/api/compare-rows-insert-all' { Send-Json $client (Api-CompareRowsInsertAll $data) }
                '/api/compare-rows-diff'        { Send-Json $client (Api-CompareRowsDiff $data) }
                '/api/compare-rows-apply-diff'  { Send-Json $client (Api-CompareRowsApplyDiff $data) }
                '/api/compare-schemas' { Send-Json $client (Api-CompareSchemas $data) }
                '/api/compare-apply'   { Send-Json $client (Api-CompareApply $data) }
                '/api/lib-list'    { Send-Json $client (Api-LibList) }
                '/api/lib-save'    { Send-Json $client (Api-LibSave $data) }
                '/api/lib-delete'  { Send-Json $client (Api-LibDelete $data) }
                '/api/lib-clear'   { Send-Json $client (Api-LibClear) }
                '/api/lib-replace' { Send-Json $client (Api-LibReplace $data) }
                default        { Send-Json $client '{"ok":false,"error":"unknown"}' }
            }
        } else {
            Send-Http $client '404 Not Found' 'text/plain' ([Text.Encoding]::UTF8.GetBytes('not found'))
        }
    } catch {
        try { Send-Http $client '500 Error' 'application/json' ([Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":'+(J-Str $_.Exception.Message)+'}')) } catch { }
    } finally {
        try { $client.Close() } catch {}
    }
}

# ============================================================================
#  MAIN SERVER LOOP
#  Accept one browser request at a time, handle it, respond, repeat.
#  Shuts itself down (freeing the fixed port for next launch) on any of: the
#  in-app Quit button, the app window's own browser process exiting (checked
#  every ~200ms - see $script:BrowserProcess), or - as a last-resort fallback
#  for anything that misses both of those - 6 hours with no /api/ping (the
#  browser pings every few seconds while any tab is open).
# ============================================================================
$run=$true
while ($run) {
    $pending = $false
    try { $pending = $listener.Server.Poll(200000, [System.Net.Sockets.SelectMode]::SelectRead) }
    catch { Start-Sleep -Milliseconds 50 }

    if ($pending) {
        $client=$null
        try { $client=$listener.AcceptTcpClient() }
        catch { $client=$null }
        if ($null -ne $client) {
            $ps = [powershell]::Create()
            $ps.RunspacePool = $Pool
            [void]$ps.AddScript($RequestHandler).AddArgument($client).AddArgument($Token).AddArgument($Html)
            $handle = $ps.BeginInvoke()
            $InFlight.Add([pscustomobject]@{ ps=$ps; handle=$handle })
        }
    }

    # Reap completed requests; surface any unexpected errors to the console log instead of losing them.
    $stillRunning = New-Object System.Collections.Generic.List[object]
    foreach ($item in $InFlight) {
        if ($item.handle.IsCompleted) {
            try { $item.ps.EndInvoke($item.handle) } catch { Write-Host ("Request error: " + $_.Exception.Message) -ForegroundColor Yellow }
            $item.ps.Dispose()
        } else { $stillRunning.Add($item) }
    }
    $InFlight = $stillRunning

    # Idle-cursor sweep: there's no per-cursor background thread here (unlike a real thread-per-
    # connection design), so a cursor the frontend opened but never finished reading (e.g. the tab
    # was left mid-result and closed via something other than closeTab/closeAll/closeOthers, or
    # the browser tab was simply killed) is reaped here instead, on the loop that already runs
    # every ~200ms. Kept cheap: normally $script:OpenCursors is empty.
    if ($script:OpenCursors.Count -gt 0) {
        $idleCutoff = [DateTime]::UtcNow.AddMinutes(-10)
        foreach ($kv in @($script:OpenCursors.GetEnumerator())) {
            if ($kv.Value.LastUsed -lt $idleCutoff) {
                $idleCursor = $null
                if ($script:OpenCursors.TryRemove($kv.Key, [ref]$idleCursor)) {
                    try { if (-not $idleCursor.Process.HasExited) { $idleCursor.Process.Kill() } } catch {}
                    $null = Close-QueryCursorProc $idleCursor
                }
            }
        }
    }

    if ($SharedState.Quit) { $run = $false }
    # Closing the app window itself (its own X, Alt+F4, etc.) doesn't call /api/quit - only the
    # in-app Quit button does - so without this, that's indistinguishable from a tab just sitting
    # idle, and the server would only ever notice via the 6-hour ping-timeout fallback below. This
    # notices the instant the window actually closes instead, freeing the fixed port right away.
    elseif ($script:BrowserProcess -and $script:BrowserProcess.HasExited) { $run = $false }
    elseif (((Get-Date) - $SharedState.LastPing).TotalSeconds -gt 21600) { $run = $false }
}

# Drain any in-flight requests before shutting down.
foreach ($item in $InFlight) {
    try { $item.handle.AsyncWaitHandle.WaitOne(2000) | Out-Null; $item.ps.EndInvoke($item.handle) } catch {}
    $item.ps.Dispose()
}
try { $Pool.Close(); $Pool.Dispose() } catch {}
try { $listener.Stop() } catch {}
Write-Host "Server stopped."
[Environment]::Exit(0)
