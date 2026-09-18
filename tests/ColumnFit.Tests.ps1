# Tests for which values a column fit measures, run against the UI inline in NOBSSQL.ps1.
#
# The JavaScript below is the same test file the Tauri edition (nobs-sql-editor,
# tests/ui/column-fit.test.mjs) runs against its ui/index.html - both editions share the UI, so they share
# the test. Generated from that file; keep the two in step.
#
# That the copy below still matches that file is checked by tests/SharedUiTests.Tests.ps1, which
# does the same for every shared test here and can regenerate them.
#
#   pwsh -NoProfile -File tests/ColumnFit.Tests.ps1 ./NOBSSQL.ps1

param([Parameter(Mandatory)][string]$ScriptPath)

if (-not (Test-Path $ScriptPath)) { "  FAIL  script not found: $ScriptPath"; exit 1 }
$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) { "  FAIL  node not found on PATH - this UI is JavaScript and needs it to run"; exit 1 }

$test = @'
// Which values a double-click on a column edge measures.
//
// Fitting a column used to measure the cells the DOM held, and above 300 rows the grid only builds
// the screenful around where you are scrolled (renderBody, VIRT_THRESHOLD) - so the same column
// fitted to two different widths from two scroll positions, and a long value further down was
// never measured at all. The values are all in memory, so the fit reads them from there.
//
// What it must not do is read all of them: a grid can hold a hundred thousand rows, and a
// double-click should not cost a second. widestCandidates picks the few that could be the widest,
// and these pin the two things that makes it worth trusting - the longest value is always among
// them, and the limit is honoured however many rows there are.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

// NOBS_UI_SOURCE lets the PowerShell edition run this same file against NOBSSQL.ps1, which carries
// the identical UI inline.
const src = readFileSync(process.env.NOBS_UI_SOURCE ||
  join(dirname(fileURLToPath(import.meta.url)), '../../ui/index.html'), 'utf8').replace(/\r\n/g, '\n');

function extractFunction(name) {
  const start = src.indexOf(`function ${name}(`);
  assert.notEqual(start, -1, `function ${name} not found - was it renamed?`);
  let depth = 0;
  for (let j = src.indexOf('{', start); j < src.length; j++) {
    if (src[j] === '{') depth++;
    else if (src[j] === '}' && --depth === 0) return src.slice(start, j + 1);
  }
  throw new Error(`unbalanced braces while extracting ${name}`);
}

const widestCandidates = new Function(`${extractFunction('widestCandidates')}\nreturn widestCandidates;`)();
const rep = (s, n) => Array.from({ length: n }, () => s);

test('nothing to measure, nothing measured', () => {
  assert.deepEqual(widestCandidates([], 200), []);
  assert.deepEqual(widestCandidates(null, 200), []);
});

test('one value is measured whatever it is', () => {
  assert.deepEqual(widestCandidates(['abc'], 200), [0]);
  assert.deepEqual(widestCandidates([null], 200), [0]);
});

// The point of the whole exercise: the value that decides the width is usually the one nobody has
// scrolled to.
test('the longest value is measured even when it is the last row and the limit is small', () => {
  const vals = [...rep('ab', 5000), 'a value long enough to decide the width of this column'];
  const got = widestCandidates(vals, 5);
  assert.ok(got.includes(5000), `the longest row was not measured: ${got}`);
});

test('the limit is what it says, however many rows there are', () => {
  const got = widestCandidates(rep('same length', 10000), 200);
  assert.equal(got.length, 200);
  // All the same length, so any of them answers - but they must be distinct rows.
  assert.equal(new Set(got).size, 200);
});

// A proportional font is why this is a shortlist and not an answer: WWWWWW is wider than iiiiiiii,
// so a value a little shorter than the longest still has to be measured.
test('a value within a quarter of the longest is measured too', () => {
  const got = widestCandidates(['12345678901234567890', 'WWWWWWWWWWWWWWWW', 'short'], 200);
  assert.ok(got.includes(0) && got.includes(1), `near-longest was dropped: ${got}`);
  assert.ok(!got.includes(2), `a much shorter value was measured: ${got}`);
});

// The grid draws these as words, and the words are what takes the width.
test('a column of values nobody typed is measured as what it draws', () => {
  assert.deepEqual(widestCandidates([null, ''], 200), [1, 0]);
  assert.deepEqual(widestCandidates(['', 'abcdefgh'], 200), [1, 0]);
  assert.deepEqual(widestCandidates([null, 'ab'], 200), [0]);
});

test('a value that is not a string is measured as it prints', () => {
  assert.deepEqual(widestCandidates([1, 1234567890], 200), [1]);
});
'@
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("ColumnFit-" + [Guid]::NewGuid().ToString('N') + ".test.mjs")
$code = 1
try {
    [IO.File]::WriteAllText($tmp, $test, (New-Object System.Text.UTF8Encoding($false)))
    $env:NOBS_UI_SOURCE = (Resolve-Path $ScriptPath).Path
    & $node.Source --test $tmp
    $code = $LASTEXITCODE
} finally {
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    Remove-Item Env:NOBS_UI_SOURCE -ErrorAction SilentlyContinue
}
if ($code -ne 0) { "`n  FAILED"; exit 1 } else { "`n  all passed"; exit 0 }
