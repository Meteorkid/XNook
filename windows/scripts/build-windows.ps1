$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)
if ($env:OS -ne 'Windows_NT') { throw '请在 Windows PowerShell 中执行此脚本。' }
foreach ($tool in @('node', 'npm', 'cargo')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "缺少 $tool，请先阅读 windows/README.md 的构建要求。" }
}
npm ci
if ($LASTEXITCODE -ne 0) { throw '依赖安装失败' }
npm run check
if ($LASTEXITCODE -ne 0) { throw '前端类型检查失败' }
npm test
if ($LASTEXITCODE -ne 0) { throw '业务回归测试失败' }
cargo test --manifest-path src-tauri/Cargo.toml --no-default-features
if ($LASTEXITCODE -ne 0) { throw '原生业务测试失败' }
cargo test --manifest-path crates/island-link/Cargo.toml
if ($LASTEXITCODE -ne 0) { throw '双应用通信测试失败' }
npm run tauri -- build --bundles nsis
if ($LASTEXITCODE -ne 0) { throw '安装包构建失败' }
Get-ChildItem src-tauri/target/release/bundle/nsis/*.exe | ForEach-Object { Get-FileHash $_.FullName -Algorithm SHA256 }
