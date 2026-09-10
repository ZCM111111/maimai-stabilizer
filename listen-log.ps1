<#
    listen-log.ps1  ——  接收手机推来的实时日志

    用法（在电脑上，PowerShell 里跑）：
        cd C:\Users\93543\Desktop\FisheyeGimbal
        .\listen-log.ps1

    参数：
        -Port 9876          监听端口（要和 App 里填的一致）
        -Filter "draw|tex"  只看含这些关键词的行（正则，可选）
        -ShowAll            不过滤，全打

    Ctrl+C 停止。
#>

param(
    [int]$Port = 9876,
    [string]$Filter = "",
    [switch]$ShowAll
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "=====================================================================" -ForegroundColor Cyan
Write-Host "  FisheyeGimbal 实时日志接收器" -ForegroundColor Cyan
Write-Host "=====================================================================" -ForegroundColor Cyan
Write-Host ""

# 打印本机所有 IPv4 地址，方便确认手机该往哪发
Write-Host "本机 IPv4 地址（把对应网段的地址填进 App）:" -ForegroundColor Yellow
Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
    ForEach-Object {
        $tag = if ($_.InterfaceAlias -match 'Wi-?Fi|无线') { "  <== 优先用这个" } else { "" }
        Write-Host ("   {0,-18} {1}{2}" -f $_.IPAddress, $_.InterfaceAlias, $tag)
    }
Write-Host ""

Write-Host "监听 UDP 端口 $Port ..." -ForegroundColor Green
if ($Filter) { Write-Host "过滤规则: $Filter" -ForegroundColor DarkGray }
else { Write-Host "显示全部日志" -ForegroundColor DarkGray }
Write-Host "（手机 App 里：高级 -> 诊断 -> 打开实时日志，填上面的 IP 和端口 $Port）" -ForegroundColor DarkGray
Write-Host ""

$client = New-Object System.Net.Sockets.UdpClient($Port)
$client.Client.ReceiveTimeout = 0

$count = 0
$startTime = Get-Date

try {
    while ($true) {
        $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $bytes = $client.Receive([ref]$ep)
        $text = [System.Text.Encoding]::UTF8.GetString($bytes)

        foreach ($line in ($text -split "`r?`n")) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $count++

            if ($Filter -and -not $ShowAll) {
                if ($line -notmatch $Filter) { continue }
            }

            # 关键行高亮，一眼能看到出问题的点
            $isFail = $line -match 'noDrawable|noRPD|noCmdBuf|encoderNil|noTexture|FAIL|nil[1-9]|tex N|lost[1-9]'
            $isOk   = $line -match 'tex Y|why=ok|BUILD|已启动'
            $isMark = $line -match '==='

            $color = "Gray"
            if ($isFail) { $color = "Red" }
            elseif ($isOk) { $color = "Green" }
            elseif ($isMark) { $color = "Cyan" }

            $prefix = "[{0}] " -f (Get-Date -Format 'HH:mm:ss')
            Write-Host ($prefix + $line) -ForegroundColor $color
        }
    }
} catch [System.Management.Automation.MethodInvocationException] {
    Write-Host "`n接收出错（可能是端口被占用）: $($_.Exception.InnerException.Message)" -ForegroundColor Red
    Write-Host "换个端口：.\listen-log.ps1 -Port 9877" -ForegroundColor Yellow
} finally {
    $client.Close()
    $dur = (Get-Date) - $startTime
    Write-Host ""
    Write-Host ("停止。共收到 {0} 行，历时 {1:N1} 分钟" -f $count, $dur.TotalMinutes) -ForegroundColor Cyan
    if ($count -eq 0) {
        Write-Host ""
        Write-Host "一行都没收到？逐项检查：" -ForegroundColor Yellow
        Write-Host "  1. 手机和电脑在同一 WiFi？手机 WiFi 设置里看 IP 网段是否一致" -ForegroundColor Yellow
        Write-Host "  2. App 里『实时日志』开关打开了吗？IP 填对了吗？" -ForegroundColor Yellow
        Write-Host "  3. 电脑防火墙：控制面板 -> Windows Defender 防火墙 -> 允许应用 -> 放行 PowerShell" -ForegroundColor Yellow
        Write-Host "  4. 路由器的『AP 隔离 / 客户端隔离』会挡住手机到电脑的直连，需要关掉" -ForegroundColor Yellow
    }
}
