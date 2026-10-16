# Web Demo 导出：Godot Web (nothreads / release) → dist/web/index.html
#
# 前置：Web 导出模板必须在 %APPDATA%\Godot\export_templates\4.7.2.stable\
#   本机 github.com 不通，模板用 tools\fetch_web_templates.py 做 Range 选择性下载（只取 9.7MB 的 web_nothreads_release.zip）
#
# 用法： powershell -NoProfile -ExecutionPolicy Bypass -File tools\export_web.ps1
param(
    [string]$Preset = "Web",
    [string]$Out = "dist/web/index.html"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$godot = $env:GODOT_EXE
if (-not $godot) { $godot = "$env:TEMP\dsh_godot\Godot_v4.7.2-stable_win64_console.exe" }
if (-not (Test-Path $godot)) { Write-Host "RESULT: FAIL 找不到 Godot: $godot"; exit 1 }

$tpl = Join-Path $env:APPDATA "Godot\export_templates\4.7.2.stable\web_nothreads_release.zip"
if (-not (Test-Path $tpl)) {
    Write-Host "RESULT: FAIL 缺 Web 导出模板：$tpl"
    Write-Host "        先跑： python tools\fetch_web_templates.py"
    exit 1
}

$outPath = Join-Path $root $Out
$outDir = Split-Path -Parent $outPath
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

Push-Location $root
try {
    # 先跑一次导入：新加的素材（比如 assets/fonts/*.ttf）必须先被引擎导入成 .import + .godot/imported/*，
    # 否则 --export-release 会报 "No loader found for resource: res://assets/fonts/...ttf (expected type: unknown)"。
    # 这一步幂等，已导入过就秒过。
    & $godot --headless --path $root --import 2>&1 | Out-Null

    & $godot --headless --path $root --export-release $Preset $outPath 2>&1 | ForEach-Object { $_ }
    $code = $LASTEXITCODE
} finally {
    Pop-Location
}

$files = Get-ChildItem $outDir -File -ErrorAction SilentlyContinue
if (-not $files -or -not (Test-Path $outPath)) {
    Write-Host "RESULT: FAIL 导出没有产出 $outPath（Godot 退出码 $code；Godot 退出码不可信，按文件判断）"
    exit 1
}
$total = ($files | Measure-Object -Property Length -Sum).Sum
Write-Host ("RESULT: OK 导出 {0} 个文件 / {1:N1} MB → {2}" -f $files.Count, ($total / 1MB), $outDir)
$files | Sort-Object -Property Length -Descending | Select-Object -First 6 |
    ForEach-Object { Write-Host ("        {0,10:N0}  {1}" -f $_.Length, $_.Name) }
