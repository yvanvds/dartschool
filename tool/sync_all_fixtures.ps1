$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$sourceRoot = Join-Path $root 'smartschool\tests\requests'
$targetRoot = Join-Path $root 'test\fixtures\smartschool\requests'

if (-not (Test-Path $sourceRoot)) {
    throw "Source fixture directory not found: $sourceRoot"
}

New-Item -ItemType Directory -Force -Path $targetRoot | Out-Null

# Replace target with an exact mirror of source
if (Test-Path $targetRoot) {
    Get-ChildItem -Force $targetRoot | Remove-Item -Recurse -Force
}

Copy-Item -Recurse -Force (Join-Path $sourceRoot '*') $targetRoot

$sourceCount = (Get-ChildItem -Recurse -File $sourceRoot).Count
$targetCount = (Get-ChildItem -Recurse -File $targetRoot).Count

Write-Host "Synced all response fixtures"
Write-Host "  Source: $sourceRoot ($sourceCount files)"
Write-Host "  Target: $targetRoot ($targetCount files)"
Write-Host "\nRun: dart test test/message_fixtures_test.dart test/auth_fixtures_test.dart"