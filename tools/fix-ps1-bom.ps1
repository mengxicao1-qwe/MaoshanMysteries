# tools/fix-ps1-bom.ps1 -- ensure .ps1 files are UTF-8 with BOM.
#
# WHY: Windows PowerShell 5.1 (the only PowerShell on this machine; pwsh/PS7 is NOT
# installed) decodes a .ps1 that has no BOM using the system ANSI codepage. Any
# non-ASCII text (e.g. Chinese log labels) then turns into mojibake, which corrupts
# string literals and produces bogus parse errors such as
#   "The '<' operator is reserved for future use."
# This script is deliberately pure ASCII so that it can always run, even when the
# file it needs to repair is broken.
#
# USAGE:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\fix-ps1-bom.ps1 tools\check.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\fix-ps1-bom.ps1 -All
#
# It works at the BYTE level ([System.IO.File]::ReadAllBytes/WriteAllBytes) and never
# decodes the text, so it cannot itself corrupt the content it repairs.

[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Path,
    [switch]$All
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$bom = [byte[]](0xEF, 0xBB, 0xBF)

$targets = @()
if ($All) {
    $targets = @(Get-ChildItem -LiteralPath $root -Recurse -Filter *.ps1 -File |
        Where-Object { $_.FullName -notlike '*\.godot\*' -and $_.FullName -notlike '*\.tools\*' -and
            $_.FullName -notlike '*\node_modules\*' -and $_.FullName -notlike '*\.backups\*' } |
        ForEach-Object { $_.FullName })
}
foreach ($p in @($Path)) {
    if (-not $p) { continue }
    $resolved = if ([System.IO.Path]::IsPathRooted($p)) { $p } else { Join-Path $root $p }
    if (Test-Path -LiteralPath $resolved) { $targets += (Resolve-Path -LiteralPath $resolved).Path }
    else { Write-Host "SKIP (not found): $p" -ForegroundColor DarkGray }
}
if ($targets.Count -eq 0) {
    Write-Host "Nothing to do. Pass one or more .ps1 paths, or -All."
    exit 0
}

$fixed = 0
$already = 0
foreach ($t in ($targets | Select-Object -Unique)) {
    if ([System.IO.Path]::GetExtension($t) -ne '.ps1') { continue }
    $bytes = [System.IO.File]::ReadAllBytes($t)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    if ($hasBom) { $already++; continue }
    [System.IO.File]::WriteAllBytes($t, $bom + $bytes)
    $fixed++
    Write-Host "BOM added: $t"
}
Write-Host "OK: $fixed file(s) repaired, $already already had a BOM."
exit 0
