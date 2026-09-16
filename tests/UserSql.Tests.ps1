# Tests for the SQL the Users dialog builds. Like viewIndices, these are JavaScript embedded in
# NOBSSQL.ps1 rather than PowerShell functions, so they are extracted by brace-matching and run
# under node instead of through the PowerShell AST.
#
# The Users dialog is the only place in the app that writes GRANT, CREATE USER and DROP USER, and
# it builds every one of them client-side as text - so the quoting done there is all there is. The
# real functions are driven with the dialogs and exec() stubbed; nothing is copied into this file.
#
#   pwsh -NoProfile -File tests/UserSql.Tests.ps1 ./NOBSSQL.ps1

param([Parameter(Mandatory)][string]$ScriptPath)

if (-not (Test-Path $ScriptPath)) { "  FAIL  script not found: $ScriptPath"; exit 1 }
$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) { "  FAIL  node not found on PATH - this SQL is JavaScript and needs it to run"; exit 1 }

$harness = @'
import { readFileSync } from 'node:fs';

function extractFunction(src, name) {
  let start = src.indexOf(`async function ${name}(`);
  if (start === -1) start = src.indexOf(`function ${name}(`);
  if (start === -1) throw new Error(`function ${name} not found - was it renamed?`);
  let depth = 0;
  for (let j = src.indexOf('{', start); j < src.length; j++) {
    if (src[j] === '{') depth++;
    else if (src[j] === '}' && --depth === 0) return src.slice(start, j + 1);
  }
  throw new Error('unbalanced braces while extracting ' + name);
}

const src = readFileSync(process.argv[2], 'utf8');
const NAMES = ['strLit', 'lit', 'newUser', 'dropUser', 'grantUser', 'revokeUser', 'lockUser'];
const bundle = NAMES.map(n => extractFunction(src, n)).join('\n');

function harness({ dialog = {}, selected = null } = {}) {
  const sql = [];
  const env = {
    inputBox: async () => dialog,
    grantRevokeDialog: async () => dialog,
    ask: async () => true,
    toast: () => {},
    openUsers: () => {},
    showGrants: () => {},
    exec: async (s) => { sql.push(s); return true; },
    window: { _selUser: selected },
  };
  const keys = Object.keys(env);
  const fns = new Function(...keys, `${bundle}\nreturn {newUser,dropUser,grantUser,revokeUser,lockUser};`)(
    ...keys.map(k => env[k]));
  return { sql, fns };
}

let fail = 0;
const eq = (got, want, label) => {
  if (got !== want) { console.log(`  FAIL  ${label}`); console.log(`        got  ${got}`); console.log(`        want ${want}`); fail++; }
  else console.log(`  ok    ${label}`);
};

const SEP = '\x01'; // how the Users list packs user+host into _selUser

let h = harness({ dialog: { user: "o'brien", host: 'localhost', pw: 'pw' } });
await h.fns.newUser();
eq(h.sql[0], "CREATE USER 'o''brien'@'localhost' IDENTIFIED BY 'pw'", 'a quoted user name is escaped, not broken');

// lit() passes 0x.. through UNQUOTED - right for a BIT/BINARY column value, wrong for a name.
// "CREATE USER 0xAB@'%'" is a syntax error, so an account called 0xAB could not be created at all.
h = harness({ dialog: { user: '0xAB', host: '%', pw: 'pw' } });
await h.fns.newUser();
eq(h.sql[0], "CREATE USER '0xAB'@'%' IDENTIFIED BY 'pw'", 'a name that looks like a hex literal is still quoted');

h = harness({ dialog: { user: 'alice', host: '0xff', pw: 'pw' } });
await h.fns.newUser();
eq(h.sql[0], "CREATE USER 'alice'@'0xff' IDENTIFIED BY 'pw'", 'a host that looks like a hex literal is quoted too');

h = harness({ selected: `0xAB${SEP}%` });
await h.fns.dropUser();
eq(h.sql[0], "DROP USER '0xAB'@'%'", 'DROP USER targets exactly the selected account');

h = harness({ selected: `o'brien${SEP}localhost` });
await h.fns.dropUser();
eq(h.sql[0], "DROP USER 'o''brien'@'localhost'", 'DROP USER escapes rather than truncating at a quote');

h = harness({ selected: `0xAB${SEP}%`, dialog: { g: 'SELECT ON d.*', wgo: true } });
await h.fns.grantUser();
eq(h.sql[0], "GRANT SELECT ON d.* TO '0xAB'@'%' WITH GRANT OPTION", 'GRANT names the account correctly');
eq(h.sql[1], 'FLUSH PRIVILEGES', 'GRANT is followed by FLUSH PRIVILEGES');

h = harness({ selected: `o'brien${SEP}%`, dialog: { g: 'SELECT ON d.*' } });
await h.fns.revokeUser();
eq(h.sql[0], "REVOKE SELECT ON d.* FROM 'o''brien'@'%'", 'REVOKE names the account correctly');

h = harness({ selected: `0xAB${SEP}%` });
await h.fns.lockUser(true);
eq(h.sql[0], "ALTER USER '0xAB'@'%' ACCOUNT LOCK", 'ACCOUNT LOCK names the account correctly');

h = harness({ selected: null });
await h.fns.dropUser(); await h.fns.grantUser(); await h.fns.revokeUser(); await h.fns.lockUser(true);
eq(h.sql.length, 0, 'nothing is sent when no user is selected');

process.exit(fail ? 1 : 0);
'@

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "usersql-harness-$PID.mjs"
try {
    Set-Content -LiteralPath $tmp -Value $harness -Encoding utf8
    & node $tmp (Resolve-Path $ScriptPath).Path
    $code = $LASTEXITCODE
} finally {
    Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
}
if ($code -ne 0) { "`n  FAILED"; exit 1 } else { "`n  all passed"; exit 0 }
