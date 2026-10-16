#Requires -Version 5.1
<#
============================================================================
 tools/check.ps1 —— 一条命令的验证闸门（工具链第 1 步）
----------------------------------------------------------------------------
 为什么需要它：
   每次改完代码，"哪里坏了"的信息散落在 5 个命令、几千行日志里。
   这个脚本把它们串成一条命令，并且**只输出结论**：
     · 每个步骤一行，通过 / 失败 / 跳过一目了然；
     · 全量输出写进 logs\check\*.log，需要细节时再去读那一个文件；
     · 任何一步失败 → 退出码 1（可直接接 CI）。

 用法：
   .\tools\check.ps1                  # 本地：自动重新生成索引/场景等产物
   .\tools\check.ps1 -Ci              # CI：产物只校验不重写，过期即失败
   .\tools\check.ps1 -Verbose         # 额外打印每一步的完整输出（调试闸门自身时用）
   .\tools\check.ps1 -Godot <exe路径> # 显式指定 Godot；找不到引擎时才需要

 引擎查找顺序：-Godot 参数 → 环境变量 GODOT_EXE → tools\godot_exe.txt（本脚本自动记忆）
                → PATH 里的 godot。
============================================================================
#>
[CmdletBinding()]
param(
    [switch]$Ci,
    [string]$Godot = "",
    [int]$SceneFrames = 300
)
# 注意：不要自己声明 $Verbose —— [CmdletBinding()] 已经提供通用参数 -Verbose，
# 重复声明会直接报 "A parameter with the name 'Verbose' was defined multiple times"，
# 想判断是否开了 -Verbose 就用 $VerbosePreference -eq 'Continue'。

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $root

$logDir = Join-Path $root 'logs\check'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$pathFile = Join-Path $PSScriptRoot 'godot_exe.txt'

function Resolve-GodotExe {
    param([string]$Explicit)
    if ($Explicit -and (Test-Path -LiteralPath $Explicit)) { return (Resolve-Path -LiteralPath $Explicit).Path }
    if ($env:GODOT_EXE -and (Test-Path -LiteralPath $env:GODOT_EXE)) { return $env:GODOT_EXE }
    if (Test-Path -LiteralPath $pathFile) {
        $stored = (Get-Content -LiteralPath $pathFile -First 1).Trim()
        if ($stored -and (Test-Path -LiteralPath $stored)) { return $stored }
    }
    $cmd = Get-Command godot -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return ""
}

$godotExe = Resolve-GodotExe -Explicit $Godot
if (-not $godotExe) {
    Write-Host "找不到 Godot 可执行文件。" -ForegroundColor Red
    Write-Host "请用 -Godot <路径> 指定，或设置环境变量 GODOT_EXE。"
    exit 2
}
if ($Godot) { Set-Content -LiteralPath $pathFile -Value $godotExe -Encoding ASCII }

# ---------------------------------------------------------------------------
# 步骤表：每一项 = 一次 Godot 无头调用
#   Kind: tool  = 脚本自己会打印 RESULT: 行（OK/CLEAN/PASS/FAIL/DRIFT/SKIP）
#         test  = 靠退出码判断，摘要行用 -SummaryPattern 抓
# ---------------------------------------------------------------------------
$mode = if ($Ci) { '--check' } else { '' }

$steps = @(
    @{ Key = '索引+解析检查'; Script = 'res://tools/gen_index.gd'; Args = @(); Kind = 'tool'; Checkable = $true }
    @{ Key = '数据表校验'; Script = 'res://tools/cli.gd'; Args = @('validate'); Kind = 'tool' }
    @{ Key = '冒烟测试'; Script = 'res://tests/test_phase1_smoke.gd'; Args = @(); Kind = 'test'; Pattern = '结果：' }
    @{ Key = '场景运行 smoke'; Script = 'res://tools/cli.gd'; Args = @('smoke', '--scene', 'res://scenes/main.tscn', '--frames', "$SceneFrames"); Kind = 'tool' }
    @{ Key = '场景规格漂移'; Script = 'res://tools/gen_scene.gd'; Args = @('--spec', 'res://scenes_src/main.json'); Kind = 'tool'; Checkable = $true }
    @{ Key = '标题场景 smoke'; Script = 'res://tools/cli.gd'; Args = @('smoke', '--scene', 'res://scenes/title_scene.tscn', '--frames', "$SceneFrames", '--no-clock'); Kind = 'tool' }
    @{ Key = '标题场景漂移'; Script = 'res://tools/gen_scene.gd'; Args = @('--spec', 'res://scenes_src/title_scene.json'); Kind = 'tool'; Checkable = $true }
    @{ Key = '主题漂移'; Script = 'res://tools/gen_theme.gd'; Args = @(); Kind = 'tool'; Checkable = $true }
    @{ Key = '占位资产漂移'; Script = 'res://tools/gen_placeholders.gd'; Args = @(); Kind = 'tool'; Checkable = $true }
    @{ Key = '纵切片试玩'; Script = 'res://tests/test_slice_hud.gd'; Args = @(); Kind = 'test'; Pattern = '结果：' }
    @{ Key = '标题页与弹窗'; Script = 'res://tests/test_title_scene.gd'; Args = @(); Kind = 'test'; Pattern = '结果：' }
    @{ Key = '心灯与落盘'; Script = 'res://tests/test_heart_lamp.gd'; Args = @(); Kind = 'test'; Pattern = '结果：' }
    @{ Key = '案件装载器'; Script = 'res://tests/test_case_loader.gd'; Args = @(); Kind = 'test'; Pattern = '结果：' }
    @{ Key = '对话层'; Script = 'res://tests/test_dialogue.gd'; Args = @(); Kind = 'test'; Pattern = '结果：' }
    @{ Key = '走位耗时'; Script = 'res://tests/test_travel.gd'; Args = @(); Kind = 'test'; Pattern = 'RESULT:' }
    @{ Key = '跨轮记忆与世界状态'; Script = 'res://tests/test_npc_memory.gd'; Args = @(); Kind = 'test'; Pattern = '结果：' }
    @{ Key = '推演板与矛盾高亮'; Script = 'res://tests/test_deduction.gd'; Args = @(); Kind = 'test'; Pattern = '结果：' }
    @{ Key = '画符输入'; Script = 'res://tests/test_runes.gd'; Args = @(); Kind = 'test'; Pattern = '结果：' }
)

$results = @()
$failures = 0
$skips = 0
$totalStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$index = 0

Write-Host ""
Write-Host "=== 《茅山秘录·诡异录》检查闸门 $(if ($Ci) { '(CI 模式：只校验不重写)' } else { '(本地模式：自动重写产物)' }) ===" -ForegroundColor Cyan
Write-Host "引擎: $godotExe"

foreach ($step in $steps) {
    $index++
    $label = "[{0}/{1}] {2}" -f $index, $steps.Count, $step.Key
    $scriptPath = Join-Path $root ($step.Script -replace '^res://', '' -replace '/', '\')

    if (-not (Test-Path -LiteralPath $scriptPath)) {
        $skips++
        Write-Host ("{0,-28} SKIP  未实现" -f $label) -ForegroundColor DarkGray
        $results += [pscustomobject]@{ Key = $step.Key; Status = 'SKIP' }
        continue
    }

    $callArgs = @('--headless', '--path', $root, '--script', $step.Script)
    $stepArgs = @($step.Args)
    if ($step.Checkable) { if ($Ci) { $stepArgs += '--check' } }
    if ($stepArgs.Count -gt 0) { $callArgs += '--'; $callArgs += $stepArgs }

    $logFile = Join-Path $logDir (($step.Key -replace '[\\/:*?"<>|]', '_') + '.log')
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $output = & $godotExe @callArgs 2>&1 | Out-String
    $exitCode = $LASTEXITCODE
    $stopwatch.Stop()
    Set-Content -LiteralPath $logFile -Value $output -Encoding UTF8

    # --- 判定 ---
    # 坑（实测踩过）：GDScript 编译/运行错误**不会**改变 Godot 的退出码 ——
    # 脚本根本没编译成功，进程照样退出 0。所以必须自己扫描输出文本，
    # 否则闸门会给出"假绿"，那比没有闸门更危险。
    $scriptErrors = @()
    foreach ($line in ($output -split "`r?`n")) {
        if ($line -match 'SCRIPT ERROR|Parse Error|Failed to load script|Failed to compile|Compilation failed|Failed to load resource|Cannot open file') {
            $scriptErrors += $line.Trim()
        }
    }

    $status = if ($exitCode -eq 0) { 'OK' } else { 'FAIL' }
    $summary = ''
    $foundResult = $false
    foreach ($line in ($output -split "`r?`n")) {
        $trimmed = $line.Trim()
        # 不要锚定行首 ^ —— Godot 把结论写到 stderr 时，PowerShell 会在行首加
        # "Godot_...exe : " 前缀，锚定后会把有结论的步骤误判成"没有结论"。
        if ($trimmed -match 'RESULT:\s*(\S.*)$') {
            $payload = $Matches[1].Trim()
            # Godot 往 stderr 写结论时，PowerShell 会把 ErrorRecord 的尾巴（":String) [],
            # RemoteException"、"+ CategoryInfo" 等）粘在行尾，读起来像乱码 —— 切掉它。
            foreach ($noise in @(':String) [],', ' [], RemoteException', '    + CategoryInfo', ' + FullyQualifiedErrorId')) {
                $idx = $payload.IndexOf($noise)
                if ($idx -ge 0) { $payload = $payload.Substring(0, $idx).TrimEnd() }
            }
            $summary = "RESULT: $payload"
            $foundResult = $true
            if ($payload -match '^(FAIL|DRIFT)') { $status = 'FAIL' }
            elseif ($payload -match '^SKIP') { $status = 'SKIP' }
            continue
        }
        if ($step.ContainsKey('Pattern') -and $trimmed -like "*$($step.Pattern)*" -and -not $summary) {
            $summary = $trimmed
        }
    }
    # 工具类步骤必须给出 RESULT 行：没有结论 = 脚本没跑到结尾，不算通过
    if (-not $foundResult -and $step.Kind -eq 'tool' -and $status -ne 'SKIP') {
        $status = 'FAIL'
        $summary = '未输出 RESULT 行（脚本可能未运行或未编译）'
    }
    if ($scriptErrors.Count -gt 0) {
        $status = 'FAIL'
        $summary = "脚本错误: $($scriptErrors[0])"
    }
    if (-not $summary) {
        $summary = if ($exitCode -eq 0) { '退出码 0' } else { "退出码 $exitCode" }
    }
    if ($status -eq 'FAIL' -and $exitCode -eq 0) { $exitCode = 1 }
    if ($status -eq 'FAIL') { $failures++ }
    if ($status -eq 'SKIP') { $skips++ }

    $color = switch ($status) {
        'OK'   { 'Green' }
        'FAIL' { 'Red' }
        default { 'DarkGray' }
    }
    if ($summary.Length -gt 96) { $summary = $summary.Substring(0, 93) + '...' }
    Write-Host ("{0,-28} {1,-6} {2} ({3}ms)" -f $label, $status, $summary, [int]$stopwatch.Elapsed.TotalMilliseconds) -ForegroundColor $color

    if ($VerbosePreference -eq 'Continue') { Write-Host $output -ForegroundColor DarkGray }

    $results += [pscustomobject]@{ Key = $step.Key; Status = $status; Summary = $summary; Log = $logFile }
}

$totalStopwatch.Stop()
$executed = $results.Count - $skips
Write-Host ""
if ($failures -eq 0) {
    Write-Host ("结论: 全部通过 ({0}/{1} 执行, {2} 跳过)  用时 {3:N1}s" -f $executed, $results.Count, $skips, $totalStopwatch.Elapsed.TotalSeconds) -ForegroundColor Green
} else {
    Write-Host ("结论: {0} 项失败 ({1}/{2} 执行)  用时 {3:N1}s" -f $failures, $executed, $results.Count, $totalStopwatch.Elapsed.TotalSeconds) -ForegroundColor Red
}
Write-Host "全量日志: logs\check\   提示: 加 -Verbose 可直接看到失败细节"
exit $(if ($failures -eq 0) { 0 } else { 1 })
