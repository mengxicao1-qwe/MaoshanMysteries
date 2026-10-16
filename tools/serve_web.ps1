# Web Demo 本地服务器（Windows 包装）：真正干活的是 tools\serve_web.py
# 为什么要有这层：PATH 上的 `python` 是应用商店占位符（跑起来什么都不干），
# 所以这里逐个探测"真能执行"的解释器，再把参数转给 serve_web.py。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\serve_web.ps1                 # http://localhost:8000/ 并自动开浏览器
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\serve_web.ps1 -Port 8123 -NoOpen
param(
    [int]$Port = 8000,
    [string]$Dir = "",
    [switch]$NoOpen
)

$ErrorActionPreference = "Stop"
# 让 Python 的中文输出在本机 GBK 控制台里不乱码
$env:PYTHONIOENCODING = "utf-8"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$pyScript = Join-Path $PSScriptRoot "serve_web.py"
if (-not (Test-Path $pyScript)) {
    Write-Host "RESULT: FAIL 找不到 tools\serve_web.py"
    exit 1
}

function Test-RealPython([string]$exe) {
    if (-not (Test-Path $exe)) { return $false }
    try {
        $out = & $exe -c "import sys;sys.stdout.write('OK')" 2>$null
    } catch {
        return $false
    }
    return (($out -join "") -eq "OK")
}

$candidates = @()
$cmd = Get-Command python -ErrorAction SilentlyContinue
if ($cmd) { $candidates += $cmd.Source }
$candidates += "C:\Users\Thoma\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe"
$candidates += (Join-Path $env:LOCALAPPDATA "Programs\Python\Python313\python.exe")
$candidates += (Join-Path $env:LOCALAPPDATA "Programs\Python\Python312\python.exe")
$candidates += "C:\Python313\python.exe"
$candidates += "C:\Python312\python.exe"

$py = $null
foreach ($c in $candidates) {
    if (Test-RealPython $c) { $py = $c; break }
}
if (-not $py) {
    Write-Host "RESULT: FAIL 找不到可用的 Python（PATH 上的 python 可能是应用商店占位符）"
    exit 1
}

$argv = @($pyScript, "--port", "$Port")
if ($Dir) { $argv += @("--dir", $Dir) }
if ($NoOpen) { $argv += "--no-open" }

& $py @argv
