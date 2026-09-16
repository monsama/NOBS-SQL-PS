# Tests for viewIndices, the grid's row filtering and sorting. It decides the order every result
# grid is displayed in, and it is JavaScript embedded in NOBSSQL.ps1 rather than a PowerShell
# function - so unlike the other tests here it cannot be lifted out with the PowerShell AST and
# run in-process. It is extracted by brace-matching and run under node instead, which
# windows-latest (this repo's CI image) already ships.
#
# The function is NOT copied into this file: a copy would happily keep passing while the real one
# regressed. Everything below runs the code that actually ships.
#
#   pwsh -NoProfile -File tests/ViewIndices.Tests.ps1 ./NOBSSQL.ps1

param([Parameter(Mandatory)][string]$ScriptPath)

if (-not (Test-Path $ScriptPath)) { "  FAIL  script not found: $ScriptPath"; exit 1 }

# No node means these tests cannot run. Say so and fail, rather than reporting success for work
# that never happened - a test that silently passes when it did not execute is worse than no test.
$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) { "  FAIL  node not found on PATH - viewIndices is JavaScript and needs it to run"; exit 1 }

$harness = @'
import { readFileSync } from 'node:fs';

function extractFunction(src, name) {
  const start = src.indexOf(`function ${name}(`);
  if (start === -1) throw new Error(`function ${name} not found - was it renamed?`);
  let depth = 0;
  for (let j = src.indexOf('{', start); j < src.length; j++) {
    if (src[j] === '{') depth++;
    else if (src[j] === '}' && --depth === 0) return src.slice(start, j + 1);
  }
  throw new Error('unbalanced braces while extracting ' + name);
}

const src = readFileSync(process.argv[2], 'utf8');
const viewIndicesSrc = extractFunction(src, 'viewIndices');

function sortColumn(values, { dir = 1, filters = {} } = {}) {
  const tab = { rows: values.map(v => [v]), filters, sortCol: 0, sortDir: dir };
  const viewIndices = new Function('T', `${viewIndicesSrc}\nreturn viewIndices;`)(() => tab);
  return viewIndices('t1').map(ri => tab.rows[ri][0]);
}

let fail = 0;
const eq = (got, want, label) => {
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g !== w) { console.log(`  FAIL  ${label} -> got ${g}, want ${w}`); fail++; }
  else console.log(`  ok    ${label}`);
};

// The regression: parseFloat("1000.10") is 1000.1, so a per-pair "does it round-trip?" test fails
// for that value and falls back to string comparison, while "1.37" and "2.74" pass and compare
// numerically. Mixing both rules in one sort is an inconsistent comparator, and "1000.10" came
// back between "1.37" and "2.74".
eq(sortColumn(['0.00','1.37','1000.10','2.74','20.00','999.90']),
   ['0.00','1.37','2.74','20.00','999.90','1000.10'],
   'DECIMAL column with trailing zeros sorts numerically');

const vals = ['0.00','1.37','1000.10','2.74','20.00','999.90'];
eq(sortColumn(vals, { dir: -1 }), [...sortColumn(vals)].reverse(),
   'descending is exactly the reverse of ascending');

const mono = sortColumn(['9.50','10.00','100.10','2','0.30','1000','99.99','3.00']).map(Number);
eq(mono.every((v,i) => i === 0 || mono[i-1] <= v), true,
   'sorted output is monotonic - one consistent order');

eq(sortColumn(['1','2','10','20','100']), ['1','2','10','20','100'],
   'integers sort numerically, not as text');

eq(sortColumn(['banana','apple','cherry']), ['apple','banana','cherry'],
   'a genuinely textual column still sorts as text');

// parseFloat("1abc") is 1, which is why the numeric test matches the WHOLE string. One
// non-numeric value puts the whole column on the text path, so the order stays defined.
eq(sortColumn(['10','9','1abc']), ['10','1abc','9'],
   'a column that only looks numeric is not treated as numeric');

eq(sortColumn(['10.00', null, '2.00']), ['2.00','10.00',null],
   'NULLs sort last and do not make the column non-numeric');

eq(sortColumn(['alpha','beta','alphabet'], { filters: { 0: 'alpha' } }), ['alpha','alphabet'],
   'filtering still narrows the view');

process.exit(fail ? 1 : 0);
'@

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "viewindices-harness-$PID.mjs"
try {
  Set-Content -LiteralPath $tmp -Value $harness -Encoding utf8
  & node $tmp (Resolve-Path $ScriptPath).Path
  $code = $LASTEXITCODE
} finally {
  Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
}
if ($code -ne 0) { "`n  FAILED"; exit 1 } else { "`n  all passed"; exit 0 }
