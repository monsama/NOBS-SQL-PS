# Tests for colTypesBinCols, which decides what a result grid knows about its binary columns.
#
# This edition gets no per-column type with a result - it shells out to mysql.exe, which reports
# values and nothing about them - so a value arriving as "0x" could be a BLOB holding no bytes or
# a VARCHAR holding those two characters, and the grid drew what it was given. The table load path
# already asks information_schema for COLUMN_TYPE (for BIT, and for the cell editors); this reads
# the binary columns out of that same answer, so the grid is told for free.
#
# What it must not do is guess. A result whose columns are not all columns of the table - a query
# selecting an expression - gets null, and the caller falls back to the value's own shape exactly
# as before, because "not in the table" is not the same as "not binary".
#
# Like tests/ViewIndices.Tests.ps1, the function is NOT copied into this file: it is extracted from
# NOBSSQL.ps1 by brace-matching and run under node, so what is tested is what ships.
#
#   pwsh -NoProfile -File tests/GridBinCols.Tests.ps1 ./NOBSSQL.ps1

param([Parameter(Mandatory)][string]$ScriptPath)

if (-not (Test-Path $ScriptPath)) { "  FAIL  script not found: $ScriptPath"; exit 1 }

# No node means these tests cannot run. Say so and fail, rather than reporting success for work
# that never happened.
$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) { "  FAIL  node not found on PATH - this is JavaScript and needs it to run"; exit 1 }

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
// The regex itself, which is what says which types are binary - taken from the file rather than
// restated here, or this would test a second opinion instead of the shipped one.
function extractConst(src, name) {
  const start = src.indexOf(`const ${name}=`);
  if (start === -1) throw new Error(`const ${name} not found - was it renamed?`);
  return src.slice(start, src.indexOf(';', start) + 1);
}

const src = readFileSync(process.argv[2], 'utf8');
const bundle = extractConst(src, 'BIN_COL_TYPE') + extractFunction(src, 'colTypesBinCols');
const colTypesBinCols = new Function(`${bundle}; return colTypesBinCols;`)();

let fail = 0;
const eq = (got, want, label) => {
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g !== w) { console.log(`  FAIL  ${label} -> got ${g}, want ${w}`); fail++; }
  else console.log(`  ok    ${label}`);
};

// A table as information_schema describes one. COLUMN_TYPE, not DATA_TYPE: it carries the length
// too, which is the difference the regex has to tolerate.
const viewer = {
  id: 'int', txt: 'text', name: 'varchar(64)', code: 'char(36)',
  bin: 'varbinary(10)', fixed: 'binary(16)', body: 'blob', small: 'tinyblob',
  medium: 'mediumblob', large: 'longblob', flags: 'bit(8)', shape: 'geometry',
};

eq(colTypesBinCols(['id', 'txt', 'name', 'code'], viewer), [false, false, false, false],
   'a column that holds text is not binary, whatever its value looks like');

eq(colTypesBinCols(['bin', 'fixed', 'body', 'small', 'medium', 'large'], viewer),
   [true, true, true, true, true, true],
   'binary, varbinary and every blob are binary');

eq(colTypesBinCols(['flags'], viewer), [true],
   'BIT is binary here too - it arrives as hex, and the Editor flags it the same way');

eq(colTypesBinCols(['shape'], viewer), [true], 'geometry is binary');

eq(colTypesBinCols(['id', 'bin', 'txt'], viewer), [false, true, false],
   'the answer is per column, in the order the result has them');

// The whole point: this is what tells "(0 bytes)" from a value that reads 0x.
eq(colTypesBinCols(['nothing'], { nothing: 'varbinary(10)' }), [true],
   'a zero-byte binary column is still a binary column');

// MySQL labels a column as the query wrote it, not as the table declares it.
eq(colTypesBinCols(['BIN', 'Id'], viewer), [true, false],
   'a column named in another case is the same column');

eq(colTypesBinCols(['bin'], { bin: 'VARBINARY(10)' }), [true],
   'a type in capitals is the same type');

// null, not false: the caller then falls back to the value's own shape, which is what it did
// before any of this. Answering "not binary" for a column nothing knows about would be a guess,
// and the guess would go into SQL.
eq(colTypesBinCols(['id', 'UPPER(txt)'], viewer), null,
   'a result holding something that is not a column of the table is not answered at all');

eq(colTypesBinCols(['id'], null), null, 'no column types, no answer');
eq(colTypesBinCols([], viewer), null, 'no columns, no answer');
eq(colTypesBinCols(null, viewer), null, 'no columns at all, no answer');

process.exit(fail ? 1 : 0);
'@

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "gridbincols-harness-$PID.mjs"
try {
  Set-Content -LiteralPath $tmp -Value $harness -Encoding utf8
  & node $tmp (Resolve-Path $ScriptPath).Path
  $code = $LASTEXITCODE
} finally {
  Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
}
if ($code -ne 0) { "`n  FAILED"; exit 1 } else { "`n  all passed"; exit 0 }
