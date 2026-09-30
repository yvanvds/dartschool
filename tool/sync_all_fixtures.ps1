# Copies request fixtures from the Python reference project
# (smartschool\tests\requests) into test\fixtures\smartschool\requests.
#
# The upstream captures come from a live Smartschool: they hold real names of
# staff, parents and pupils, the school's name, profile-picture hashes and
# document metadata. The copies in this repository have been scrubbed (#29)
# and the target also holds Dart-only fixtures, so this script never deletes
# or overwrites a file that already exists in the target: it only adds files
# that are missing, and lists them.
#
# Before committing a file it added, replace all personal data with obvious
# fakes (see the existing fixtures: "Jan Janssens", "Springfield Academy",
# initials_XX picture hashes that match the fake name, a generated PDF).

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$sourceRoot = Join-Path $root 'smartschool\tests\requests'
$targetRoot = Join-Path $root 'test\fixtures\smartschool\requests'

if (-not (Test-Path $sourceRoot)) {
    throw "Source fixture directory not found: $sourceRoot"
}

New-Item -ItemType Directory -Force -Path $targetRoot | Out-Null

$sourceFull = (Resolve-Path $sourceRoot).Path
$added = @()
$skipped = 0

foreach ($file in Get-ChildItem -Recurse -File $sourceFull) {
    $relative = $file.FullName.Substring($sourceFull.Length).TrimStart('\', '/')
    $target = Join-Path $targetRoot $relative

    if (Test-Path -LiteralPath $target) {
        $skipped++
        continue
    }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
    Copy-Item -LiteralPath $file.FullName -Destination $target
    $added += $relative
}

Write-Host "Synced response fixtures from $sourceRoot"
Write-Host "  Kept (already present, not overwritten): $skipped"
Write-Host "  Added: $($added.Count)"

if ($added.Count -gt 0) {
    $added | ForEach-Object { Write-Host "    $_" }
    Write-Warning 'The added files are unscrubbed captures of a live Smartschool. Replace all personal data (names, school, picture hashes, document metadata) with fakes before committing them.'
}

Write-Host ''
Write-Host 'Run: dart test'
