#Requires -Version 5.1
<#
.SYNOPSIS
    Scoop 开机/登录自动更新脚本（由计划任务 ScoopAutoUpdate 调用）
.DESCRIPTION
    完整流程：
      1) 原生 `scoop update`（无参数）——同步 scoop 自身 + 所有 bucket（git 同步）
      2) abgox `scoop-update -a`——所有应用经 gh-proxy 镜像加速更新
         （内置镜像 URL 替换，无需代理；跳过 scoop 自身，第 1 步已覆盖）
    健壮性：单个应用失败不阻塞其他应用；全程输出追加至 update.log（超过 10MB 自动轮转保留尾部）
    通知：有版本变更时发送 Windows 桌面通知（失败静默，不影响流程）
.NOTES
    兼容 Windows PowerShell 5.1 与 PowerShell 7+；计划任务使用 System32 的 powershell.exe（始终存在，不依赖 scoop）
#>

$ErrorActionPreference = 'Continue'   # 单个失败不中断整体流程
$scoopHome   = 'D:\PortableApps\Scoop'
$logFile     = Join-Path $scoopHome 'update.log'

# ---------- 日志轮转：超过 10MB 仅保留最后 2000 行 ----------
if ((Test-Path $logFile) -and ((Get-Item $logFile).Length -gt 10MB)) {
    $tail = Get-Content $logFile -Tail 2000
    Set-Content $logFile -Value $tail -Encoding UTF8
}

Start-Transcript -Path $logFile -Append | Out-Null
Write-Host ''
Write-Host ("==================== {0} 开始自动更新 ====================" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

# ---------- 1) 同步 scoop 自身 + 所有 bucket（原生；abgox 不覆盖这两项） ----------
Write-Host ''
Write-Host '>>> 步骤 1/2：scoop update（同步 scoop 自身与所有 bucket）'
& "$scoopHome\shims\scoop.cmd" update 2>&1 | Out-String | Write-Host

# ---------- 2) 所有应用经镜像加速更新（abgox.scoop-update，内置 gh-proxy URL 替换） ----------
Write-Host '>>> 步骤 2/2：scoop-update -a（所有应用，gh-proxy 镜像加速）'
$appOutput = & "$scoopHome\shims\scoop-update.cmd" -a 2>&1 | Out-String
Write-Host $appOutput

# ---------- 3) 汇总版本变更 ----------
$updated = [regex]::Matches($appOutput, "Updating '([^']+)' \(([^)]+)\)")
$summary = if ($updated.Count -gt 0) {
    ($updated | ForEach-Object { "$($_.Groups[1].Value) ($($_.Groups[2].Value))" }) -join '; '
} else { '所有应用均为最新版本' }
Write-Host ''
Write-Host ">>> 本次更新完成：$summary"

# ---------- 4) 桌面通知（有变更时；失败静默） ----------
if ($updated.Count -gt 0) {
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime]
        $template = @"
<toast>
  <visual>
    <binding template="ToastGeneric">
      <text>Scoop 自动更新完成</text>
      <text>已更新 {0} 个应用：{1}</text>
    </binding>
  </visual>
</toast>
"@ -f $updated.Count, [System.Security.SecurityElement]::Escape($summary)
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml($template)
        $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('Microsoft.Windows.PowerShell').Show($toast)
    } catch {
        Write-Host "（桌面通知发送失败，已忽略：$($_.Exception.Message)）"
    }
}

Write-Host ("==================== 结束 ====================")
Stop-Transcript | Out-Null
