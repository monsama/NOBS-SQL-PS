# Checks every test in this directory that carries a copy of a test from the Tauri edition against
# the file it was copied from.
#
# Both editions ship the same UI, so they share its tests: the JavaScript lives in nobs-sql-editor
# under tests/ui/, and the tests here embed a copy of it to run against NOBSSQL.ps1. Keeping a copy
# in step was a comment asking politely, and a stale copy fails nothing - it goes on passing
# against whatever it last knew about, so this edition reports a tested UI while testing an older
# version of it. That is the failure this catches.
#
# Nothing has to be registered here. A test is checked when it holds a $test = @'...'@ block and
# names its source somewhere in its header as tests/ui/<name>.test.mjs, which every one of them
# already does - so a test file added later is covered the day it is written.
#
#   pwsh -NoProfile -File tests/SharedUiTests.Tests.ps1 ../nobs-sql-editor
#   pwsh -NoProfile -File tests/SharedUiTests.Tests.ps1 ../nobs-sql-editor -Update   fix the copies
#
# -Update rewrites each drifted copy from its source, which is the fix when this fails; review what
# it changed before committing, since it is the shared test that decides what this edition tests.

param([Parameter(Mandatory)][string]$EditorRepo, [switch]$Update)

if (-not (Test-Path $EditorRepo)) { "  FAIL  editor repository not found: $EditorRepo"; exit 1 }
$editor = (Resolve-Path $EditorRepo).Path

$here = Split-Path -Parent $PSCommandPath
$checked = 0; $fixed = 0; $fail = 0

foreach ($file in Get-ChildItem (Join-Path $here '*.Tests.ps1') | Sort-Object Name) {
    if ($file.Name -eq (Split-Path -Leaf $PSCommandPath)) { continue }
    $text = [IO.File]::ReadAllText($file.FullName) -replace "`r`n", "`n"
    $m = [regex]::Match($text, '(?s)\$test = @''\n(.*?)\n''@\n')
    if (-not $m.Success) { continue }   # not a shared test - nothing to compare
    $checked++

    # The source is whatever the file's own header says it was generated from.
    $header = ($text -split "`n" | Select-Object -First 15) -join "`n"
    $named = [regex]::Match($header, 'tests/ui/[a-z0-9-]+\.test\.mjs')
    if (-not $named.Success) {
        "  FAIL  $($file.Name) embeds a copy but its header does not name the tests/ui file it came from"
        $fail++; continue
    }
    $source = Join-Path $editor ($named.Value -replace '/', [IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path $source)) {
        "  FAIL  $($file.Name) names $($named.Value), which is not in $editor"
        $fail++; continue
    }

    $want = (([IO.File]::ReadAllText($source) -replace "`r`n", "`n")).TrimEnd()
    $have = $m.Groups[1].Value
    if ($have -ceq $want) { "  ok    $($file.Name) matches $($named.Value)"; continue }

    if ($Update) {
        $new = $text.Substring(0, $m.Groups[1].Index) + $want + $text.Substring($m.Groups[1].Index + $m.Groups[1].Length)
        [IO.File]::WriteAllText($file.FullName, $new, (New-Object System.Text.UTF8Encoding($false)))
        "  ok    $($file.Name) regenerated from $($named.Value)"
        $fixed++; continue
    }

    "  FAIL  $($file.Name) has drifted from $($named.Value)"
    $a = $have -split "`n"; $b = $want -split "`n"
    for ($i = 0; $i -lt [Math]::Max($a.Count, $b.Count); $i++) {
        if ($i -ge $a.Count) { "          line $($i+1) is missing here -> $($b[$i])"; break }
        if ($i -ge $b.Count) { "          line $($i+1) is only here    -> $($a[$i])"; break }
        if ($a[$i] -cne $b[$i]) { "          first difference at line $($i+1):"; "            here:  $($a[$i])"; "            there: $($b[$i])"; break }
    }
    $fail++
}

if ($checked -eq 0 -and $fail -eq 0) { "  FAIL  no shared tests were found - has the embedding changed shape?"; exit 1 }
if ($fail) { "FAILED: $fail of $checked shared tests are out of step. Fix with -Update."; exit 1 }
if ($fixed) { "Regenerated $fixed of $checked - review the changes before committing."; exit 0 }
"All $checked shared tests are in step with the editor repository."
