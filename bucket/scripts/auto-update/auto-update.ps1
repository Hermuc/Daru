#Requires -Version 5.1
<#
.SYNOPSIS
    Scoop 开机/登录自动更新脚本（由计划任务 ScoopAutoUpdate 调用）
.DESCRIPTION
    完整流程：
      1) 原生 `scoop update`（无参数）——同步 scoop 自身 + 所有 bucket（git 同步；main/extras 为南大镜像源）
      2) 原生 `scoop update *`——所有应用直连官方源更新（跳过 scoop 自身，第 1 步已覆盖）
      3) `scoop cleanup <各应用> -k`——无条件逐应用执行（cleanup 只删非 current 版本目录，persist 不受影响；
         更新失败的应用 current 仍指向旧版本，同样不会被误删；逐应用隔离：单个应用被进程占用
         仅该应用本轮跳过，不阻断其余应用——`scoop cleanup *` 遇文件锁会报错中断，故不采用）
    健壮性：单个应用失败不阻塞其他应用；全程输出追加至 update.log（超过 10MB 自动轮转保留尾部）
    通知：正常成功且有版本变更 → 桌面通知；检测到新版本但进程占用被跳过 → 跳过提示通知（不计为错误）；
          任一步骤出错 → 错误通知（Toast，失败降级为前台 MessageBox）；全部成功且无变更 → 完全静默
    启动方式：计划任务经 wscript.exe 调用 auto-update.vbs 以窗口样式 0 启动本脚本，全程零窗口（无 conhost 闪现）；
          也可双击配套 auto-update.cmd 手动全量更新+清理（控制台窗口可见进度）
    部署：将本目录整套文件（本脚本 + auto-update.vbs + ScoopAutoUpdate.xml + register-scoop-autoupdate.ps1
          + 两个 .cmd 双击包装器）拷到 Scoop 根目录（含 apps\ 与 shims\ 的那一层），
          然后双击 register-scoop-autoupdate.cmd（或命令行运行对应 .ps1）注册计划任务；
          重装系统后只需重跑 register。全程不硬编码路径。
.NOTES
    兼容 Windows PowerShell 5.1 与 PowerShell 7+（VBS 包装器与 WinRT Toast 均两版本通用）
    本文件须保存为 UTF-8 with BOM（PS 5.1 按 ANSI 读无 BOM 文件会破坏中文并可能解析失败）
#>

$ErrorActionPreference = 'Continue'   # 单个失败不中断整体流程

# ---------- Scoop 根目录推导（不硬编码路径，可拷到任意 Scoop 机器） ----------
# 部署约定：本脚本位于 Scoop 根目录（与 apps\、shims\ 同级）
$candidate = $PSScriptRoot
if (-not $candidate) { $candidate = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not ((Test-Path (Join-Path $candidate 'apps')) -and (Test-Path (Join-Path $candidate 'shims')))) {
    Write-Host "错误：未找到 Scoop 根目录（本脚本须放在 Scoop 根目录，与 apps\、shims\ 同级）。当前：$candidate"
    exit 1
}
$scoopHome   = $candidate
$logFile     = Join-Path $scoopHome 'update.log'

# ---------- 错误行检测：从更新输出中提取错误信息（兼容中英文输出） ----------
function Get-ErrorLines([string]$Text) {
    $patterns = @(
        '(?im)^\s*ERROR\b', '(?i)hash check failed', '(?i)download failed',
        '错误', '哈希校验', '下载失败', 'Could not install'
    )
    $lines = ($Text -split "`r?`n") | Where-Object {
        $line = $_
        # 排除本脚本自身的回显/汇总行（以 >>> 开头），避免历史错误信息被二次误判
        if ($line -match '^\s*>>>') { return $false }
        @($patterns | Where-Object { $line -match $_ }).Count -gt 0
    }
    if ($lines) { ($lines | Select-Object -First 4) -join '; ' } else { '' }
}

# ---------- 进程占用跳过检测：提取“检测到新版本但因进程占用跳过更新”的应用 ----------
# scoop update 对每个应用先输出 Updating 'app' (old -> new)（i18n 中文：更新 app (old -> new)），
# 若检测到进程占用则输出 Running process detected, skip updating.（i18n 中文：检测到正在运行的进程，已跳过更新）
function Get-SkippedApps([string]$Text) {
    $names = New-Object System.Collections.Generic.List[string]
    $current = $null
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match "(?:Updating|更新)\s+'?([^'\s(]+)'?\s+\(") {
            $current = $matches[1]
        } elseif ($current -and ($line -match '(?i)Running process detected|跳过更新')) {
            $names.Add($current)
            $current = $null
        }
    }
    return @($names)
}

# ---------- 从输出中剔除“进程占用跳过”相关行，避免该场景被误判为更新错误 ----------
function Remove-SkipNoise([string]$Text) {
    (($Text -split "`r?`n") | Where-Object {
        $_ -notmatch '(?i)Running process detected|still running|仍在运行|正在运行中|跳过更新'
    }) -join "`r`n"
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
Write-Host '>>> 步骤 1/3：scoop update（同步 scoop 自身与所有 bucket）'
$step1Output = & "$scoopHome\shims\scoop.cmd" update 2>&1 | Out-String
Write-Host $step1Output
$step1Code = $LASTEXITCODE

# ---------- 2) 所有应用直连官方源更新（原生 scoop update *；bucket 同步见步骤 1） ----------
Write-Host '>>> 步骤 2/3：scoop update *（所有应用，直连官方源）'
$appOutput = & "$scoopHome\shims\scoop.cmd" update * 2>&1 | Out-String
Write-Host $appOutput
$step2Code = $LASTEXITCODE

# ---------- 3) 汇总版本变更（兼容英文原生输出 Updating 'app' (a -> b) 与 i18n 中文输出 更新 app (a -> b)） ----------
$updateRegex = "(?:Updating|更新)\s+'?([^'\s(]+)'?\s+\(([^)]+)\)"
$updated = @([regex]::Matches($appOutput, $updateRegex) | ForEach-Object {
    [pscustomobject]@{ Name = $_.Groups[1].Value; Version = $_.Groups[2].Value }
})
$summary = if ($updated.Count -gt 0) {
    ($updated | ForEach-Object { "$($_.Name) ($($_.Version))" }) -join '; '
} else { '所有应用均为最新版本' }
$skipped = @(Get-SkippedApps $appOutput)
Write-Host ""
Write-Host ">>> 本次更新完成：$summary"
if ($skipped.Count -gt 0) {
    Write-Host ">>> 以下应用检测到新版本但进程占用被跳过：$($skipped -join ', ')"
}

# ---------- 4) 错误检测（退出码 + 输出中的错误标记，覆盖下载失败/哈希校验失败/命令异常） ----------
$failedSteps = New-Object System.Collections.Generic.List[string]
if ($step1Code -ne 0) { $failedSteps.Add("步骤 1 scoop update 退出码 $step1Code") }
if ($step2Code -ne 0) { $failedSteps.Add("步骤 2 scoop update * 退出码 $step2Code") }
$err1 = Get-ErrorLines $step1Output
if ($err1) { $failedSteps.Add("步骤 1 scoop update：$err1") }
$err2 = Get-ErrorLines (Remove-SkipNoise $appOutput)
if ($err2) { $failedSteps.Add("步骤 2 scoop update *：$err2") }
if ($failedSteps.Count -gt 0) {
    $errorSummary = ($failedSteps -join "`n")
    if ($errorSummary.Length -gt 300) { $errorSummary = $errorSummary.Substring(0, 300) + '…' }
    Write-Host ''
    Write-Host ">>> 检测到错误：`n$errorSummary"
}

# ---------- 4.5) 清理旧版本：无条件逐应用执行 ----------
# 安全性依据：scoop cleanup 仅移除非 current 的版本目录，persist 与 current 链接不受影响；
# 即使某应用本轮更新失败，其 current 仍指向旧版本，cleanup 不会删除它。
# 逐应用而非 `cleanup *`：后者遇到被进程占用的文件会报错并中断，导致后续应用都不被清理；
# 逐应用隔离后，单个应用失败不影响其余应用（下轮自动补清）。
$runningPwsh = @(Get-Process pwsh -ErrorAction SilentlyContinue)
if ($runningPwsh.Count -gt 0) {
    Write-Host ("检测到 {0} 个存活 pwsh 进程，旧版 pwsh 目录可能清理不完全（下次运行自动补清）" -f $runningPwsh.Count)
}
Write-Host ''
Write-Host '>>> 步骤 3/3：scoop cleanup 逐应用清理旧版本目录与过期下载缓存'
$cleanupFailed = New-Object System.Collections.Generic.List[string]
$appNames = Get-ChildItem (Join-Path $scoopHome 'apps') -Directory | Select-Object -ExpandProperty Name
foreach ($appName in $appNames) {
    $oneOutput = & "$scoopHome\shims\scoop.cmd" cleanup $appName -k 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        $cleanupFailed.Add($appName)
        Write-Host ("[{0}] 清理未完成（可能被进程占用，下轮补清）" -f $appName)
    } elseif ($oneOutput.Trim()) {
        Write-Host $oneOutput.TrimEnd()
    }
}
if ($cleanupFailed.Count -gt 0) {
    Write-Host ("（{0} 个应用本轮清理不完全：{1}；不影响更新结果）" -f $cleanupFailed.Count, ($cleanupFailed -join ', '))
} else {
    Write-Host '（全部应用清理完成）'
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

# ---------- 5.5) 进程占用跳过通知（检测到新版本但因进程占用被跳过，提醒关闭程序后手动补更） ----------
if ($skipped.Count -gt 0) {
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime]
        $skipList = [System.Security.SecurityElement]::Escape(($skipped -join ', '))
        $template = @"
<toast>
  <visual>
    <binding template="ToastGeneric">
      <text>Scoop 自动更新：{0} 个应用因进程占用跳过</text>
      <text>检测到新版本但相关程序正在运行：{1}。关闭程序后运行 scoop update {1} 完成更新。</text>
    </binding>
  </visual>
</toast>
"@ -f $skipped.Count, $skipList
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml($template)
        $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('Microsoft.Windows.PowerShell').Show($toast)
    } catch {
        Write-Host "（跳过提示通知发送失败，已忽略：$($_.Exception.Message)）"
    }
}

# ---------- 6) 错误通知（有错误时；无变更无错误则完全静默） ----------
if ($failedSteps.Count -gt 0) {
    Show-UpdateError -Body $errorSummary
}

Write-Host ("==================== 结束 ====================")
Stop-Transcript | Out-Null
