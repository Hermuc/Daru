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
    通知：正常成功且有版本变更 → 桌面通知；任一步骤出错 → 错误通知（Toast，失败降级为前台 MessageBox）；
          全部成功且无变更 → 完全静默
    启动方式：计划任务经 wscript.exe 调用 auto-update.vbs 以窗口样式 0 启动本脚本，全程零窗口（无 conhost 闪现）
.NOTES
    兼容 Windows PowerShell 5.1 与 PowerShell 7+（VBS 包装器与 WinRT Toast 均两版本通用）
#>

$ErrorActionPreference = 'Continue'   # 单个失败不中断整体流程
$scoopHome   = 'D:\PortableApps\Scoop'
$logFile     = Join-Path $scoopHome 'update.log'

# ---------- 错误行检测：从更新输出中提取错误信息（兼容中英文输出） ----------
function Get-ErrorLines([string]$Text) {
    $patterns = @(
        '(?im)^\s*ERROR\b', '(?i)hash check failed', '(?i)download failed',
        '错误', '哈希校验', '下载失败', 'Could not install'
    )
    $lines = ($Text -split "`r?`n") | Where-Object {
        $line = $_
        @($patterns | Where-Object { $line -match $_ }).Count -gt 0
    }
    if ($lines) { ($lines | Select-Object -First 4) -join '; ' } else { '' }
}

# ---------- 错误通知：优先桌面 Toast，失败时降级为前台 MessageBox（PS 5.1/7 通用） ----------
function Show-UpdateError([string]$Body) {
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime]
        $template = @"
<toast>
  <visual>
    <binding template="ToastGeneric">
      <text>Scoop 自动更新出现错误</text>
      <text>{0}</text>
    </binding>
  </visual>
</toast>
"@ -f [System.Security.SecurityElement]::Escape($Body)
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml($template)
        $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('Microsoft.Windows.PowerShell').Show($toast)
    } catch {
        try {
            Add-Type -AssemblyName System.Windows.Forms
            [System.Windows.Forms.MessageBox]::Show($Body, 'Scoop 自动更新出现错误', 'OK', 'Warning') | Out-Null
        } catch {
            Write-Host "（错误通知发送失败，详情见 update.log）"
        }
    }
}

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
$step1Output = & "$scoopHome\shims\scoop.cmd" update 2>&1 | Out-String
Write-Host $step1Output
$step1Code = $LASTEXITCODE

# ---------- 2) 所有应用经镜像加速更新（abgox.scoop-update，内置 gh-proxy URL 替换） ----------
Write-Host '>>> 步骤 2/2：scoop-update -a（所有应用，gh-proxy 镜像加速）'
$appOutput = & "$scoopHome\shims\scoop-update.cmd" -a 2>&1 | Out-String
Write-Host $appOutput
$step2Code = $LASTEXITCODE

# ---------- 3) 汇总版本变更 ----------
$updated = [regex]::Matches($appOutput, "Updating '([^']+)' \(([^)]+)\)")
$summary = if ($updated.Count -gt 0) {
    ($updated | ForEach-Object { "$($_.Groups[1].Value) ($($_.Groups[2].Value))" }) -join '; '
} else { '所有应用均为最新版本' }
Write-Host ""
Write-Host ">>> 本次更新完成：$summary"

# ---------- 4) 错误检测（退出码 + 输出中的错误标记，覆盖下载失败/哈希校验失败/命令异常） ----------
$failedSteps = New-Object System.Collections.Generic.List[string]
if ($step1Code -ne 0) { $failedSteps.Add("步骤 1 scoop update 退出码 $step1Code") }
if ($step2Code -ne 0) { $failedSteps.Add("步骤 2 scoop-update -a 退出码 $step2Code") }
$err1 = Get-ErrorLines $step1Output
if ($err1) { $failedSteps.Add("步骤 1 scoop update：$err1") }
$err2 = Get-ErrorLines $appOutput
if ($err2) { $failedSteps.Add("步骤 2 scoop-update -a：$err2") }
if ($failedSteps.Count -gt 0) {
    $errorSummary = ($failedSteps -join "`n")
    if ($errorSummary.Length -gt 300) { $errorSummary = $errorSummary.Substring(0, 300) + '…' }
    Write-Host ''
    Write-Host ">>> 检测到错误：`n$errorSummary"
}

# ---------- 5) 成功通知（有变更且无错误时；失败静默） ----------
if ($updated.Count -gt 0 -and $failedSteps.Count -eq 0) {
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

# ---------- 6) 错误通知（有错误时；无变更无错误则完全静默） ----------
if ($failedSteps.Count -gt 0) {
    Show-UpdateError -Body $errorSummary
}

Write-Host ("==================== 结束 ====================")
Stop-Transcript | Out-Null
