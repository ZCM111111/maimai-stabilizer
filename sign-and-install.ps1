# Windows 上把 CI 产出的未签名 ipa 装进 iPhone
#
# 前置：
#   1. 装 AltServer for Windows   https://altstore.io
#   2. 装 Apple 官方 iTunes + iCloud（必须官方版，不能是 Microsoft Store 版）
#   3. 用 USB 连上 iPhone，信任这台电脑
#   4. iPhone 上开：设置 -> 隐私与安全性 -> 开发者模式 -> 打开，然后重启
#   5. 免费 Apple ID 必须先在一台真机/或者 AltStore 里激活过开发者证书
#
# 用法：
#   .\sign-and-install.ps1 -Ipa .\FisheyeGimbal-unsigned.ipa
#
# 注意：免费 Apple ID 签出来的证书 7 天过期，到期重跑这个脚本即可。

param(
    [Parameter(Mandatory = $true)][string]$Ipa,
    [string]$AltServer = "C:\Program Files (x86)\AltServer\AltServer.exe"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $Ipa)) { throw "找不到 ipa: $Ipa" }
$Ipa = (Resolve-Path $Ipa).Path

Write-Host "=== ipa 信息 ===" -ForegroundColor Cyan
Get-Item $Ipa | Select-Object Name, Length, LastWriteTime | Format-List
(Get-FileHash $Ipa -Algorithm SHA256).Hash

Write-Host "`n=== 检查依赖 ===" -ForegroundColor Cyan

$itunes = Get-ItemProperty "HKLM:\SOFTWARE\Apple Inc.\Apple Mobile Device Support" -ErrorAction SilentlyContinue
if ($null -eq $itunes) {
    Write-Warning "没检测到 Apple Mobile Device Support。先装官方 iTunes。"
}

Write-Host "`n=== 连着的 iOS 设备 ===" -ForegroundColor Cyan
$devices = Get-PnpDevice -Class 'Apple Mobile Device' -ErrorAction SilentlyContinue |
           Where-Object { $_.Status -eq 'OK' }
if ($devices) { $devices | Select-Object FriendlyName, Status | Format-Table -AutoSize }
else { Write-Warning "没看到已连接的 iPhone。检查数据线 / 是否点了『信任』。" }

if (-not (Test-Path $AltServer)) {
    Write-Host "`n没找到 AltServer，请手动操作：" -ForegroundColor Yellow
    Write-Host "  1. 打开 AltServer（托盘图标）"
    Write-Host "  2. 托盘右键 -> Install AltStore -> 选你的 iPhone -> 输入 Apple ID"
    Write-Host "  3. 之后在 iPhone 上用 AltStore 打开这个 ipa"
    Write-Host "`nipa 路径：$Ipa"
    exit 0
}

Write-Host "`n=== 用 AltServer 安装 ===" -ForegroundColor Cyan
Write-Host "提示：接下来会弹出 Apple ID 登录窗口，填你的 Apple ID。"
& $AltServer --install $Ipa

Write-Host "`n完成。在 iPhone 上：" -ForegroundColor Green
Write-Host "  设置 -> 通用 -> VPN与设备管理 -> 信任你的开发者证书"
Write-Host "如果提示『不受信任的开发者』，就是这个原因。"
