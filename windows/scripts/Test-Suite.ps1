$ErrorActionPreference = 'Stop'
$manifestPath = Join-Path $PSScriptRoot 'manifest.json'
if (-not (Test-Path $manifestPath)) { throw '请先完整解压测试包，再运行本脚本。' }
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$results = @()
foreach ($artifact in $manifest.artifacts) {
    if ([System.IO.Path]::GetFileName($artifact.name) -ne $artifact.name) { throw '清单含非法相对路径' }
    $file = Join-Path $PSScriptRoot $artifact.name
    $valid = (Test-Path -LiteralPath $file -PathType Leaf) -and ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLower() -eq $artifact.sha256)
    $results += [pscustomobject]@{ name = $artifact.name; checksumPassed = $valid }
}
$webviewVersion = $null
$registryPaths = @(
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
    'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
    'HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
)
foreach ($key in $registryPaths) {
    if (Test-Path $key) { $webviewVersion = (Get-ItemProperty $key -Name pv -ErrorAction SilentlyContinue).pv }
    if ($webviewVersion) { break }
}
$report = [ordered]@{
    checkedAt = (Get-Date).ToString('o')
    windowsVersion = [System.Environment]::OSVersion.VersionString
    architecture = $env:PROCESSOR_ARCHITECTURE
    webView2Version = $webviewVersion
    artifacts = $results
    windowsRuntimeVerified = $false
    note = '本脚本只检查包完整性与环境；真实启动、媒体、文件操作和联动按验收说明测试。'
}
$report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'environment-report.json') -Encoding UTF8
$results | Format-Table -AutoSize
if ($results | Where-Object { -not $_.checksumPassed }) { throw '文件校验失败，请重新取得完整测试包。' }
if (-not $webviewVersion) { Write-Warning '没有找到 WebView2 版本；安装器会按其配置检查/安装运行时。' }
Write-Host '文件校验通过。请按 Windows验收说明.md 手动安装两端并测试。'
