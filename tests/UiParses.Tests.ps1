# Does the shipped UI actually parse?
#
# This exists because it once did not, and every other test still passed. A broken string literal
# in the embedded page - a message whose escaped newlines had turned into real ones - made the
# whole inline <script> block a syntax error. The app came up as an unstyled white page with no
# connections and nothing clickable, because none of the JavaScript ran at all.
#
# Nothing caught it. The other JavaScript tests here lift individual functions out of NOBSSQL.ps1
# by brace-matching and evaluate those in isolation, so they were quite happy to confirm that
# normalizeHexInput() behaved correctly inside a page the browser could not load. Per-function
# tests cannot see a file-level syntax error, and for a single-file app that is the most damaging
# thing that can happen.
#
#   pwsh -NoProfile -File tests/UiParses.Tests.ps1 ./NOBSSQL.ps1

param([Parameter(Mandatory)][string]$ScriptPath)

if (-not (Test-Path $ScriptPath)) { "  FAIL  script not found: $ScriptPath"; exit 1 }
$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) { "  FAIL  node not found on PATH - the UI is JavaScript and needs it to be checked"; exit 1 }

$harness = @'
import { readFileSync } from 'node:fs';
const src = readFileSync(process.argv[2], 'utf8');
const re = /<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/gi;
let m, n = 0, bad = 0;
while ((m = re.exec(src)) !== null) {
  n++;
  const line = src.slice(0, m.index).split('\n').length;
  try {
    new Function(m[1]);
    console.log(`  ok    inline <script> #${n} (line ${line}) parses`);
  } catch (e) {
    bad++;
    console.log(`  FAIL  inline <script> #${n} (line ${line}) is not valid JavaScript: ${e.message}`);
    console.log('        The whole page fails to run when this happens - no theme, no connections,');
    console.log('        nothing clickable.');
  }
}
// A guard on the guard: if the markup changes shape and the regex stops matching, this would
// otherwise pass by checking nothing at all.
if (n === 0) { console.log('  FAIL  no inline <script> found - has the page structure changed?'); bad++; }
process.exit(bad ? 1 : 0);
'@

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "uiparses-$PID.mjs"
try {
    Set-Content -LiteralPath $tmp -Value $harness -Encoding utf8
    & node $tmp (Resolve-Path $ScriptPath).Path
    $code = $LASTEXITCODE
} finally {
    Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
}
if ($code -ne 0) { "`n  FAILED"; exit 1 } else { "`n  all passed"; exit 0 }
