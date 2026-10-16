# tools\snapshot.ps1 —— 里程碑快照与漂移清单（本机没有 git 时的兜底）
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\snapshot.ps1 -Note "M2 画面层"   # 打一份快照
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\snapshot.ps1 -Diff               # 对比上次快照，列出改了哪些文件
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\snapshot.ps1 -List               # 列出已有快照
# 约定：快照只装源码/数据/文档/工具（跳过 .godot、logs、.backups、.shots），产物在 .backups\ 下。
param(
    [string]$Note = "",
    [switch]$Diff,
    [switch]$List
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $root

$backupDir = Join-Path $root ".backups"
if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir | Out-Null }
$manifestPath = Join-Path $backupDir "last-manifest.txt"

$sourceDirs = @("scripts", "data", "tools", "tests", "docs", "scenes_src", "assets_src", "scenes", "theme", "assets")
$sourceFiles = @("project.godot", "README.md", "AGENTS.md")
$excludeDirs = @(".godot", "logs", ".backups", ".shots", ".tools")

function Get-TrackedFiles {
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($rel in $sourceDirs) {
        $dir = Join-Path $root $rel
        if (-not (Test-Path $dir)) { continue }
        Get-ChildItem -Path $dir -Recurse -File | ForEach-Object {
            $skip = $false
            foreach ($ex in $excludeDirs) { if ($_.FullName -like "*\$ex\*") { $skip = $true } }
            if ($_.Name -like "*.tmp") { $skip = $true }
            if (-not $skip) { $out.Add($_.FullName.Substring($root.Length + 1)) }
        }
    }
    foreach ($f in $sourceFiles) { if (Test-Path (Join-Path $root $f)) { $out.Add($f) } }
    return $out
}

function Get-HashMap {
    $map = @{}
    foreach ($rel in (Get-TrackedFiles)) {
        $map[$rel] = (Get-FileHash -Algorithm SHA256 -Path (Join-Path $root $rel)).Hash
    }
    return $map
}

if ($List) {
    $items = @(Get-ChildItem -Path $backupDir -Filter "snapshot-*.zip" | Sort-Object Name)
    if ($items.Count -eq 0) { "RESULT: OK 还没有快照"; exit 0 }
    foreach ($it in $items) { "{0}  {1:N0} KB" -f $it.Name, ($it.Length / 1KB) }
    "RESULT: OK 共 $($items.Count) 个快照"
    exit 0
}

if ($Diff) {
    if (-not (Test-Path $manifestPath)) { "RESULT: FAIL 没有上一个清单（先跑一次不带 -Diff 的快照）"; exit 1 }
    $old = @{}
    foreach ($line in [System.IO.File]::ReadAllLines($manifestPath, [System.Text.Encoding]::UTF8)) {
        if ($line -match "^([0-9A-Fa-f]{64})  (.+)$") { $old[$Matches[2]] = $Matches[1].ToUpper() }
    }
    $new = Get-HashMap
    $changed = New-Object System.Collections.Generic.List[string]
    $added = New-Object System.Collections.Generic.List[string]
    $removed = New-Object System.Collections.Generic.List[string]
    foreach ($k in $new.Keys) {
        if (-not $old.ContainsKey($k)) { $added.Add($k) }
        elseif ($old[$k] -ne $new[$k]) { $changed.Add($k) }
    }
    foreach ($k in $old.Keys) { if (-not $new.ContainsKey($k)) { $removed.Add($k) } }
    "相对上一个快照：改了 $($changed.Count) / 新增 $($added.Count) / 删除 $($removed.Count)（共 $($new.Count) 个受跟踪文件）"
    foreach ($k in ($changed | Sort-Object)) { "  改  $k" }
    foreach ($k in ($added | Sort-Object)) { "  新  $k" }
    foreach ($k in ($removed | Sort-Object)) { "  删  $k" }
    "RESULT: OK diff 完成"
    exit 0
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$slug = ""
if ($Note) { $slug = "-" + ($Note -replace "[^\w\u4e00-\u9fa5-]", "_") }
$zip = Join-Path $backupDir "snapshot-$stamp$slug.zip"
$tmp = Join-Path $env:TEMP "dsh_snapshot_$stamp"
if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
New-Item -ItemType Directory -Path $tmp | Out-Null

$map = Get-HashMap
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("snapshot: $stamp")
$lines.Add("note: $Note")
$lines.Add("root: $root")
$lines.Add("files: $($map.Count)")
$lines.Add("")
foreach ($k in ($map.Keys | Sort-Object)) { $lines.Add("$($map[$k])  $k") }
[System.IO.File]::WriteAllLines($manifestPath, $lines, (New-Object System.Text.UTF8Encoding($false)))

foreach ($rel in $sourceDirs) {
    $dir = Join-Path $root $rel
    if (Test-Path $dir) { robocopy $dir (Join-Path $tmp $rel) /E /NFL /NDL /NJH /NJS /NP | Out-Null }
}
foreach ($f in $sourceFiles) { if (Test-Path (Join-Path $root $f)) { Copy-Item (Join-Path $root $f) (Join-Path $tmp $f) } }
Copy-Item -Path $manifestPath -Destination (Join-Path $tmp "manifest.txt") -Force

Compress-Archive -Path (Join-Path $tmp "*") -DestinationPath $zip -Force
Remove-Item -Recurse -Force $tmp
$kb = [math]::Round((Get-Item $zip).Length / 1KB)
"RESULT: OK 快照 $zip（$($map.Count) 个文件，$kb KB）"
