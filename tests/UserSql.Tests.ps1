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


// --- binary cell editing: hex in, hex out ---------------------------------------------------
// A blob in a real database was found holding 307 bytes of hex-dump TEXT where a 102-byte hash
// belonged. The editor opens a binary cell in Text mode when the bytes decode as UTF-8, and Text
// mode runs textToHex() over the box - so hex pasted there stores the characters, not the bytes.
const hexSrc = ['normalizeHexInput', 'looksLikePastedHex'].map(n => extractFunction(src, n)).join('\n');
const H = new Function(hexSrc + '\nreturn {normalizeHexInput,looksLikePastedHex};')();

eq(H.normalizeHexInput('0x00FF10'), '0x00ff10', 'hex copied from this app is accepted');
// Workbench separates bytes and wraps long values; neither should matter, nor the missing 0x.
eq(H.normalizeHexInput('24 37 24 43'), '0x24372443', 'Workbench-style spaced hex is accepted');
eq(H.normalizeHexInput('2437\n2443'), '0x24372443', 'hex split across lines is accepted');
eq(H.normalizeHexInput('24372443'), '0x24372443', 'hex without the 0x prefix is accepted');
// hexToBytes() parseInts each pair, so 'zz' used to become byte 0 - a hole in the data.
eq(H.normalizeHexInput('0xzz'), null, 'non-hex input is rejected, not mangled into zero bytes');
eq(H.normalizeHexInput('0x123'), null, 'an odd number of digits is half a byte, so rejected');
eq(H.normalizeHexInput(''), '0x', 'an empty box means an empty value, not an error');
eq(H.looksLikePastedHex('0x24372443362e2e2e'), true, 'hex pasted into the Text tab is recognised');
eq(H.looksLikePastedHex('$7$C6..../....RYngpNxf'), false, 'the decoded value itself is not flagged');
eq(H.looksLikePastedHex('d41d8cd98f00b204e9800998ecf8427e'), false, 'a bare MD5-looking value is not flagged');


// An empty binary cell must store nothing, not the two characters "0x".
// textToHex('') and normalizeHexInput('') both yield "0x" - zero digits. That is not valid SQL,
// and lit()'s hex passthrough requires at least one digit, so it used to fall through to being
// quoted: clearing a BLOB stored the literal characters 0 and x. Found by round-tripping every
// kind of input through a live server and comparing HEX(col) to the bytes that went in.
const litFn = new Function(extractFunction(src, 'strLit') + '\n' + extractFunction(src, 'lit') + '\nreturn lit;')();
const t2h = new Function(extractFunction(src, 'bytesToHex') + '\n' + extractFunction(src, 'textToHex') + '\nreturn textToHex;')();
const forEmpty = (h) => (h === null || h === '0x') ? '' : h;

eq(t2h(''), '0x', 'an empty Text box converts to a digit-less 0x');
eq(H.normalizeHexInput(''), '0x', 'an empty Hex box normalises to a digit-less 0x');
eq(litFn('0x'), "'0x'", 'lit() quotes a digit-less 0x, which is why getVal maps it to empty first');
eq(litFn(forEmpty(t2h(''))), "''", 'an empty Text box stores an empty value, not the characters 0x');
eq(litFn(forEmpty(H.normalizeHexInput(''))), "''", 'an empty Hex box stores an empty value');
eq(litFn(forEmpty(H.normalizeHexInput('0x00'))), '0x00', 'a real one-byte value is untouched by that mapping');

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
