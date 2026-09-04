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
    交互补更：步骤 2 结束后，若确有应用检测到新版本却因进程占用被跳过，弹窗征询是否关闭程序补更
          （YesNo、限时自愈：无操作自动跳过＝维持原行为）——确认后关闭占用程序（先优雅、超时强制，
          未保存数据可能丢失）→ 单次 scoop update <占用应用> 补更 → 自动重开被关程序 → 主流程
          cleanup 循环自动清理补更产生的旧版本目录；scoop 管线忙或定位不到占用进程时维持原跳过
          行为。总开关 $InteractiveUpdateEnable；环境变量 SCOOP_AUTOUPDATE_INTERACTIVE=0 整体禁用。
    通知：每次运行结束必发一条汇总桌面通知（Toast）——无更新（全部最新）/ 已更新 N 个应用（含更新清单、
          进程占用跳过、旧版本清理、总耗时）/ 出现错误，标题三态；错误通知用 urgent 长停留（可穿透勿扰，
          老系统不识别该属性时自动回退普通样式，无兼容风险）。Toast 发送链：本进程直发（PS 5.1）→
          委托 powershell.exe 5.1 子进程（pwsh 7 无 WinRT 投影语法）→ 仅控制台可见（手动双击）时 MessageBox
          兑底，静默任务路径默认不弹阻塞对话框（唯一例外是交互补更征询弹窗，限时自愈）。维护分工：通知样式/停留时长只改 Show-ScoopToast；
          汇报项增减/措辞只改 ConvertTo-ToastText（单点维护）
    启动方式：计划任务经 wscript.exe 调用 auto-update.vbs 以窗口样式 0 启动本脚本，全程零窗口（无 conhost 闪现）；
          也可双击配套 auto-update.cmd 手动全量更新+清理（控制台窗口可见进度）
    任务自愈：本脚本每次运行开头检查计划任务 ScoopAutoUpdate——缺失时（新部署/重装/被删除）在交互模式
          （双击 .cmd）下询问是否重建，确认后按当前目录动态注册（Action 指向本文件夹的 vbs）；
          静默路径（任务触发）下任务必存在，恒不询问。无需单独的注册工具。
    部署：将本文件夹整套文件（本脚本 + auto-update.vbs + auto-update.cmd）拷到 Scoop 根目录
          （含 apps\ 与 shims\ 的那一层）下的子文件夹（约定名 AutoUpdate），
          双击 auto-update.cmd 即自动注册任务（交互确认）+ 执行一次完整更新；重装系统后同样只需双击一次。
          全程不硬编码路径。
.NOTES
    兼容 Windows PowerShell 5.1 与 PowerShell 7+（VBS 包装器两版本通用；Toast 直发仅 5.1 支持，
    pwsh 7 下自动委托 powershell.exe 5.1 子进程代发——WinRT 的 ContentType=WindowsRuntime 投影语法是 5.1 专有）
    本文件须保存为 UTF-8 with BOM（PS 5.1 按 ANSI 读无 BOM 文件会破坏中文并可能解析失败）
#>

$ErrorActionPreference = 'Continue'   # 单个失败不中断整体流程
$scriptStart = Get-Date               # 总耗时统计起点（汇总通知用）

# ---------- Scoop 根目录推导（不硬编码路径，可拷到任意 Scoop 机器） ----------
# 部署约定：本脚本位于 Scoop 根目录下的子文件夹（如 AutoUpdate\，与 apps\、shims\ 的父目录同级）
$candidate = $PSScriptRoot
if (-not $candidate) { $candidate = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not ((Test-Path (Join-Path $candidate 'apps')) -and (Test-Path (Join-Path $candidate 'shims')))) {
    $candidate = Split-Path -Parent $candidate
}
if (-not ((Test-Path (Join-Path $candidate 'apps')) -and (Test-Path (Join-Path $candidate 'shims')))) {
    Write-Host "错误：未找到 Scoop 根目录（本脚本须放在 Scoop 根目录下的子文件夹，如 AutoUpdate\）。当前：$PSScriptRoot"
    exit 1
}
$scoopHome   = $candidate
$logFile     = Join-Path $scoopHome 'update.log'

# ---------- 交互式补更开关与参数（占用跳过应用弹窗征询，编排见 Invoke-InteractiveSkippedUpdate） ----------
$InteractiveUpdateEnable = $true    # 总开关：$false 彻底关闭交互补更（维持纯静默行为）
$PopupTimeoutSec         = 90       # 征询弹窗限时秒数：无操作自动跳过（限时自愈）
$GracefulCloseWaitSec    = 25       # 关闭占用程序的优雅退出等待上限（CloseMainWindow 之后）
$AllowForceKill          = $true    # 优雅关闭超时后是否允许强制结束进程
# 环境变量 SCOOP_AUTOUPDATE_INTERACTIVE=0 时整体禁用交互（读取处见 Invoke-InteractiveSkippedUpdate）
# 交互补更结果占位（接缝块回填，4 个变量均被 ConvertTo-ToastText 消费；未触发交互时保持空数组）
$ixUpdatedNames  = @()
$ixRestarted     = @()
$ixRestartFailed = @()
$ixCloseFailed   = @()

# ---------- 任务自愈：注册 ScoopAutoUpdate 计划任务（动态 Action，可移植） ----------
# 函数内 Stop 语义仅限本函数作用域，不影响主管线的 Continue 容错模式
function Register-ScoopAutoUpdateTask {
    $ErrorActionPreference = 'Stop'
    $action = New-ScheduledTaskAction -Execute 'C:\Windows\System32\wscript.exe' `
        -Argument ('"{0}"' -f (Join-Path $PSScriptRoot 'auto-update.vbs')) `
        -WorkingDirectory $PSScriptRoot
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 2) -MultipleInstances IgnoreNew
    $logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $logonTrigger.Delay = 'PT3M'
    Register-ScheduledTask -TaskName 'ScoopAutoUpdate' -Action $action -Trigger $logonTrigger `
        -Principal $principal -Settings $settings `
        -Description 'Scoop logon auto-update + per-app old-version cleanup (see Scoop auto-update scripts).' | Out-Null
    Write-Host '>>> 已注册计划任务 ScoopAutoUpdate（登录延迟 3 分钟后自动更新）'
}

# ---------- 系统代理探测：scoop 未显式配置 proxy 时下载走 .NET 默认代理（=系统代理） ----------
# 开机自动更新时代理软件（如 FlClash）可能尚未启动，系统代理指向的端口无人监听，
# 导致步骤 2 全部下载失败退出码 1；此处探测不可达则临时置 scoop proxy=none 直连本轮
function Get-SystemProxy() {
    try {
        $ie = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
        if ($ie.ProxyEnable -eq 1 -and $ie.ProxyServer) { return $ie.ProxyServer }
    } catch { }
    return $null
}

function Test-ProxyAlive([string]$ProxyServer) {
    if (-not $ProxyServer) { return $true }   # 未启用系统代理 → 本就直连，无需降级
    try {
        $parts = ($ProxyServer -replace '^https?://', '') -split ':'
        $hostName = $parts[0]
        $port = 80
        if ($parts.Count -gt 1 -and $parts[1] -match '^\d+$') { $port = [int]$parts[1] }
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $task = $client.ConnectAsync($hostName, $port)
            return ($task.Wait(500) -and $client.Connected)
        } finally { $client.Dispose() }
    } catch { return $false }
}

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

# ---------- 交互补更 1/6：定位占用指定 Scoop 应用的运行进程（判据与 scoop test_running_process 一致） ----------
# 判据：ExecutablePath -like "<ScoopHome>\apps\<App>\*"（-like 大小写不敏感，current 与版本目录均可命中）。
# 守卫：排除自身进程与当前宿主（$PSHOME 下）进程防自杀；ExecutablePath 为空（提权/系统进程读不到路径）
# 的进程跳过——无法判归属，也不宜自动关闭。
function Get-AppRunningProcesses {
    param(
        [string]$AppName,
        [string]$ScoopHome
    )
    $result = New-Object System.Collections.Generic.List[pscustomobject]
    $pattern = (Join-Path $ScoopHome "apps\$AppName") + '\*'
    try {
        $procs = Get-CimInstance Win32_Process -Filter "Name != ''" -ErrorAction Stop
    } catch { return @() }
    foreach ($p in $procs) {
        if ($p.ProcessId -eq $PID) { continue }                    # 排除自身进程
        if (-not $p.ExecutablePath) { continue }                   # 读不到可执行路径（提权/系统进程）
        if ($p.ExecutablePath -like "$PSHOME\*") { continue }      # 排除当前宿主（pwsh/powershell 自身），防自杀
        if ($p.ExecutablePath -like $pattern) {
            $result.Add([pscustomobject]@{
                Id             = $p.ProcessId
                ExecutablePath = $p.ExecutablePath
                CommandLine    = $p.CommandLine
                Name           = $p.Name
            })
        }
    }
    return @($result)
}

# ---------- 交互补更 2/6：检测 scoop 管线是否正被其他 powershell/pwsh 进程占用 ----------
# 本脚本自身命令行含 Scoop 路径字样（必含 'scoop'），故必须排除自身与父进程，否则恒误判忙
function Test-ScoopBusy {
    $selfPid = $PID
    $parentPid = 0
    try {
        $me = Get-CimInstance Win32_Process -Filter "ProcessId = $selfPid" -ErrorAction Stop
        if ($me) { $parentPid = [int]$me.ParentProcessId }
    } catch { }
    try {
        $procs = Get-CimInstance Win32_Process -Filter "Name != ''" -ErrorAction Stop
    } catch { return $false }
    foreach ($p in $procs) {
        if ($p.ProcessId -eq $selfPid -or $p.ProcessId -eq $parentPid) { continue }
        if (-not $p.CommandLine) { continue }
        if ($p.Name -match '^(pwsh|powershell)(\.exe)?$' -and $p.CommandLine -match 'scoop') { return $true }
    }
    return $false
}

# ---------- 交互补更 3/6：征询弹窗（WScript.Shell.Popup：YesNo + 问号 + 默认第二按钮 + 置顶） ----------
# 返回值 6=Yes、7=No、-1=超时；仅显式点「是」返回 $true；COM 失败按超时处理（自动跳过，安全兜底）
function Show-UpdateConsentPopup {
    param(
        [string]$Message,
        [string]$Title,
        [int]$TimeoutSec = $PopupTimeoutSec
    )
    $choice = -1
    $ws = $null
    try {
        $ws = New-Object -ComObject WScript.Shell
        $choice = $ws.Popup($Message, $TimeoutSec, $Title, 4 + 32 + 256 + 65536 + 262144)
    } catch { $choice = -1 }
    if ($ws) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($ws) }
    return ($choice -eq 6)
}

# ---------- 交互补更 4/6：批量关闭占用进程（先优雅 CloseMainWindow，超时且允许时强制结束） ----------
# 返回 @{ Closed = 成功关闭列表（含 App/ExecutablePath/CommandLine，供重开用）; Failed = 失败列表（提权进程等）;
#        ExitedNaturally = 关闭前已消失列表（自然退出/PID 复用防护，仅补更不重开，供日志） }
function Close-AppProcesses {
    param([object[]]$Processes)
    $closed = New-Object System.Collections.Generic.List[pscustomobject]
    $failed = New-Object System.Collections.Generic.List[pscustomobject]
    $exited = New-Object System.Collections.Generic.List[pscustomobject]
    foreach ($proc in @($Processes)) {
        if (-not $proc) { continue }
        # 重查补抓 CommandLine（重开保真）并校验 PID 身份：ExecutablePath 不符＝PID 已被复用，
        # 原进程视为已退出——绝不能误杀复用 PID 的无关新进程
        $cmdline = $proc.CommandLine
        $pidReused = $false
        try {
            $fresh = Get-CimInstance Win32_Process -Filter "ProcessId = $($proc.Id)" -ErrorAction Stop
            if ($fresh) {
                if ($fresh.ExecutablePath -and $proc.ExecutablePath -and ($fresh.ExecutablePath -ne $proc.ExecutablePath)) {
                    $pidReused = $true
                } elseif ($fresh.CommandLine) {
                    $cmdline = $fresh.CommandLine
                }
            }
        } catch { }
        if ($pidReused) {
            $exited.Add([pscustomobject]@{ App = $proc.App; Id = $proc.Id; Name = $proc.Name })
            continue
        }
        $ok = $false
        try {
            $gp = Get-Process -Id $proc.Id -ErrorAction Stop
            [void]$gp.CloseMainWindow()
            $deadline = (Get-Date).AddSeconds($GracefulCloseWaitSec)
            while (-not $gp.HasExited -and (Get-Date) -lt $deadline) {
                Start-Sleep -Milliseconds 500
                $gp.Refresh()
            }
            if (-not $gp.HasExited -and $AllowForceKill) {
                $gp.Kill()    # 绑定对象强杀（替代 Stop-Process -Id，消除强杀瞬间 PID 复用误杀窗口）
                $killDeadline = (Get-Date).AddSeconds(5)
                while (-not $gp.HasExited -and (Get-Date) -lt $killDeadline) {
                    Start-Sleep -Milliseconds 500
                    $gp.Refresh()
                }
            }
            $ok = $gp.HasExited
        } catch {
            # 抛错（进程消失/句柄失效/强杀被拒等）：复查确认——确已消失按自然退出处理（不计 Failed），
            # 仍存在（如提权进程强杀被拒）才记入 Failed
            $stillThere = $false
            try {
                $again = Get-CimInstance Win32_Process -Filter "ProcessId = $($proc.Id)" -ErrorAction Stop
                if ($again -and (-not $again.ExecutablePath -or -not $proc.ExecutablePath -or
                        $again.ExecutablePath -eq $proc.ExecutablePath)) {
                    $stillThere = $true
                }
            } catch { }
            if (-not $stillThere) {
                $exited.Add([pscustomobject]@{ App = $proc.App; Id = $proc.Id; Name = $proc.Name })
                continue
            }
            $ok = $false
        }
        if ($ok) {
            $closed.Add([pscustomobject]@{
                App            = $proc.App
                Id             = $proc.Id
                ExecutablePath = $proc.ExecutablePath
                CommandLine    = $cmdline
                Name           = $proc.Name
            })
        } else {
            $failed.Add([pscustomobject]@{ App = $proc.App; Id = $proc.Id; Name = $proc.Name })
        }
    }
    return @{ Closed = @($closed); Failed = @($failed); ExitedNaturally = @($exited) }
}

# ---------- 交互补更 5/6：从 apps\<App>\current 重启被关闭的程序（补更成败均可重开：旧 current 仍指向可用版本） ----------
# 重开路径必须走 current（旧版本目录随后被 cleanup 删除，直接用记录的旧路径会失效）；解析原 CommandLine
# 保留启动参数（原进程工作目录未采集，重开 WorkingDirectory 固定为 current 目录——有意取舍）；启动报提升
# 类错误时改用 RunAs 重试；3 秒后用本次启动实例（-PassThru）验活，任何失败返回 $false 不抛出
function Restart-App {
    param(
        [string]$App,
        [object]$ProcessInfo
    )
    try {
        if (-not $ProcessInfo -or -not $ProcessInfo.ExecutablePath) { return $false }
        $leaf = [System.IO.Path]::GetFileName($ProcessInfo.ExecutablePath)
        if (-not $leaf) { return $false }
        $newPath = Join-Path $ScoopHome "apps\$App\current\$leaf"
        if (-not (Test-Path -LiteralPath $newPath)) { return $false }
        # 解析 CommandLine 中 exe 路径之后的参数余段（兼容带引号/不带引号两种首段写法）
        $argsRest = ''
        $cl = $ProcessInfo.CommandLine
        if ($cl) {
            if ($cl.StartsWith('"')) {
                $endQuote = $cl.IndexOf('"', 1)
                if ($endQuote -gt 0) { $argsRest = $cl.Substring($endQuote + 1).Trim() }
            } else {
                $firstSpace = $cl.IndexOf(' ')
                if ($firstSpace -gt 0) {
                    $candidate = $cl.Substring($firstSpace + 1).Trim()
                    # 守卫：余段形似路径片段（盘符 X:\ 或以 \ 开头）＝首段切分落在含空格路径中间（Scoop 根
                    # 含空格的机器上），参数不可信——丢弃仅裸启动，避免把半截路径当参数传给应用
                    if ($candidate -match '^[A-Za-z]:\\' -or $candidate.StartsWith('\')) { $argsRest = '' }
                    else { $argsRest = $candidate }
                }
            }
        }
        $startArgs = @{
            FilePath         = $newPath
            WorkingDirectory = Split-Path -Parent $newPath
            ErrorAction      = 'Stop'
        }
        if ($argsRest) { $startArgs['ArgumentList'] = $argsRest }
        $started = $null
        try {
            $started = Start-Process @startArgs -PassThru
        } catch {
            if ($_.Exception.Message -match '(?i)提升|elevat|admin') {
                $startArgs['Verb'] = 'RunAs'
                $started = Start-Process @startArgs -PassThru
            } else { throw }
        }
        Start-Sleep -Seconds 3
        # 用本次启动实例对象验活（替代 Get-Process -Name 全系统同名匹配，消除同名假阳性）；仅判断不杀进程
        if (-not $started) { return $false }
        $started.Refresh()
        return (-not $started.HasExited)
    } catch {
        return $false
    }
}

# ---------- 交互补更 6/6：编排——征询 → 关闭 → 单次补更 → 重开（不 cleanup，主流程循环随后自动清旧版） ----------
# 守卫链：总开关 → 环境变量未禁用 → 有被跳过应用 → scoop 管线空闲；任一不满足或用户未确认（No/超时）
# → 原样返回（全部留在 StillSkipped）＝维持原静默跳过行为。补更输出解析复用主流程同款函数与正则。
function Invoke-InteractiveSkippedUpdate {
    param(
        [string[]]$SkippedApps,
        [string]$ScoopHome,
        [string]$UpdateRegex
    )

    $result = [pscustomobject]@{
        Updated       = @()
        StillSkipped  = @($SkippedApps)
        Restarted     = @()
        RestartFailed = @()
        CloseFailed   = @()
        Output        = ''
        ErrorLines    = ''
    }

    # 1) 守卫：总开关 / 环境变量显式禁用 / 无被跳过应用 / scoop 管线忙
    if (-not $InteractiveUpdateEnable) { return $result }
    $envSwitch = Get-ChildItem env:SCOOP_AUTOUPDATE_INTERACTIVE -ErrorAction SilentlyContinue
    if ($envSwitch -and $envSwitch.Value -eq '0') { return $result }
    if (@($SkippedApps).Count -eq 0) { return $result }
    if (Test-ScoopBusy) { return $result }

    # 2) 逐应用定位占用进程（定位不到进程的应用无法交互，保持跳过）
    $interactive = New-Object System.Collections.Generic.List[pscustomobject]
    foreach ($app in @($SkippedApps)) {
        $procs = @(Get-AppRunningProcesses -AppName $app -ScoopHome $ScoopHome)
        if ($procs.Count -gt 0) {
            $interactive.Add([pscustomobject]@{ App = $app; Procs = $procs })
        }
    }
    if ($interactive.Count -eq 0) { return $result }

    # 3) 弹窗征询：列应用与占用进程，明示后果与超时行为
    $appLines = New-Object System.Collections.Generic.List[string]
    foreach ($item in $interactive) {
        $procNames = @($item.Procs | ForEach-Object { $_.Name } | Select-Object -Unique)
        $appLines.Add(('· {0}（占用：{1}）' -f $item.App, ($procNames -join '、')))
    }
    $msg = '以下应用检测到新版本，但正被运行中的程序占用：' + "`n`n" + ($appLines -join "`n") + "`n`n" +
        '点「是」将关闭这些程序（未保存的数据可能丢失），完成更新后自动重新打开；' +
        "点「否」或 $PopupTimeoutSec 秒无操作将自动跳过，维持本次不更新。"
    if (-not (Show-UpdateConsentPopup -Message $msg -Title 'Scoop 自动更新：占用应用补更征询')) { return $result }

    # 4) 确认后复查一次（弹窗期间用户可能手动启动了 scoop 操作）
    if (Test-ScoopBusy) { return $result }

    # 5) 批量关闭占用进程（CloseFailed 的应用留在 StillSkipped）
    $toClose = @()
    foreach ($item in $interactive) {
        foreach ($p in $item.Procs) {
            $toClose += [pscustomobject]@{
                App            = $item.App
                Id             = $p.Id
                ExecutablePath = $p.ExecutablePath
                CommandLine    = $p.CommandLine
                Name           = $p.Name
            }
        }
    }
    $closeResult = Close-AppProcesses -Processes $toClose
    # 关闭成功 → 补更并重开；关闭前已消失（ExitedNaturally）→ 仍补更但不重开；关闭失败 → 留 StillSkipped
    $closedApps = @($closeResult.Closed | ForEach-Object { $_.App } | Select-Object -Unique)
    $naturalApps = @($closeResult.ExitedNaturally | ForEach-Object { $_.App } | Select-Object -Unique)
    $closeFailedApps = @($closeResult.Failed | ForEach-Object { $_.App } | Select-Object -Unique)
    $result.CloseFailed = $closeFailedApps
    $updateApps = @($closedApps + $naturalApps | Select-Object -Unique)
    if ($naturalApps.Count -gt 0) {
        Write-Host ('>>> {0} 个占用进程在关闭前已自行消失（自然退出/PID 复用），仅补更不重开：{1}' -f $naturalApps.Count, ($naturalApps -join ', '))
    }
    if ($updateApps.Count -eq 0) { return $result }

    try {
        # 6) 单次补更：scoop update <app1> <app2> ...（与主流程同款调用方式）
        Write-Host ''
        Write-Host ('>>> 交互补更：scoop update {0}' -f ($updateApps -join ' '))
        $extraOutput = & "$ScoopHome\shims\scoop.cmd" update @updateApps 2>&1 | Out-String
        $extraCode = $LASTEXITCODE
        Write-Host $extraOutput
        $result.Output = $extraOutput

        # 7) 解析补更输出：成功更新（复用主流程正则）/ 错误行 / 仍被跳过的应用（复用主流程函数）
        $result.Updated = @([regex]::Matches($extraOutput, $UpdateRegex) | ForEach-Object {
            [pscustomobject]@{ Name = $_.Groups[1].Value; Version = $_.Groups[2].Value }
        })
        $result.ErrorLines = Get-ErrorLines (Remove-SkipNoise $extraOutput)
        # 退出码兑底：非 0 且未提取到错误行时，以退出码本身作为错误线索
        if ($extraCode -ne 0 -and -not $result.ErrorLines) {
            $result.ErrorLines = "scoop update 退出码 $extraCode"
        }
        $stillSkipped = New-Object System.Collections.Generic.List[string]
        foreach ($app in @($SkippedApps)) {
            if ($updateApps -contains $app) { continue }    # 已尝试补更的不算跳过
            if (-not $stillSkipped.Contains($app)) { $stillSkipped.Add($app) }
        }
        foreach ($app in @(Get-SkippedApps $extraOutput)) {
            if (-not $stillSkipped.Contains($app)) { $stillSkipped.Add($app) }
        }
        $result.StillSkipped = @($stillSkipped)
        # 宽松正则会把“输出过 Updating 行但随后被占用跳过”的应用误计为已更新——按 StillSkipped 剔除
        $skipNames = @($stillSkipped)
        $result.Updated = @($result.Updated | Where-Object { $skipNames -notcontains $_.Name })
    } catch {
        # 补更/解析异常不中断：记录错误行；重开循环在 finally 中照常执行，已关闭者必被尝试重开
        $exLine = ('补更调用/解析异常：{0}' -f $_.Exception.Message)
        if ($result.ErrorLines) { $result.ErrorLines = "$($result.ErrorLines); $exLine" } else { $result.ErrorLines = $exLine }
        Write-Host ('>>> 交互补更环节内部异常（已关闭的程序仍将尝试重开）：{0}' -f $_.Exception.Message)
    } finally {
        # 8) 自动重开：仅对“成功关闭”的应用尽力重启（自然消失者本就无进程可重开）；补更失败时
        # current 仍指向旧版本，可从旧版复活；本块在任何路径（含上方异常）下都执行
        $restarted = New-Object System.Collections.Generic.List[string]
        $restartFailed = New-Object System.Collections.Generic.List[string]
        foreach ($item in $interactive) {
            if ($closeFailedApps -contains $item.App) { continue }
            if ($naturalApps -contains $item.App) { continue }
            # 同应用多实例（crashpad_helper 类辅助子进程）只取首个记录重开主实例——有意取舍，避免拉起重复辅助进程
            $procInfo = @($closeResult.Closed | Where-Object { $_.App -eq $item.App } | Select-Object -First 1)[0]
            if (Restart-App -App $item.App -ProcessInfo $procInfo) {
                [void]$restarted.Add($item.App)
            } else {
                [void]$restartFailed.Add($item.App)
            }
        }
        $result.Restarted = @($restarted)
        $result.RestartFailed = @($restartFailed)
    }

    return $result
}

# ---------- 通知发送（唯一出口）：本进程直发 Toast（5.1）→ 委托 5.1 子进程（pwsh 7）→ 可见控制台时 MessageBox 兑底 ----------
# -Urgent 加 scenario="urgent"：停留更久、可穿透勿扰；不识别该属性的老系统会静默按普通样式显示（无报错路径）。
# pwsh 7 不支持 WinRT 投影语法（ContentType=WindowsRuntime 为 5.1 专有），委托系统自带 powershell.exe 5.1
# 代发（零外部依赖，保证可移植）；Toast XML 只在本函数构建一处，子进程仅负责显示。MessageBox 兑底仅在
# 控制台窗口可见（手动双击 .cmd）时弹出——静默任务路径（vbs 隐藏窗口）永不弹阻塞对话框。样式调整只改本函数。
# AUMID 用 Microsoft.Windows.Explorer：'Microsoft.Windows.PowerShell' 在 Win11 24H2 上未注册（开始菜单无对应
# 快捷方式），其 Toast 会被系统静默丢弃（发送不报错但永不显示，实测）；Explorer 为系统必备组件、通知权限恒开。
function Show-ScoopToast {
    param(
        [string]$Title,
        [string[]]$Body,
        [switch]$Urgent
    )

    # Toast XML 单一构建点
    $scenarioAttr = ''
    if ($Urgent) { $scenarioAttr = ' scenario="urgent"' }
    $bodyXml = (@($Body) | Where-Object { $_ }) | ForEach-Object {
        '      <text>{0}</text>' -f [System.Security.SecurityElement]::Escape($_)
    }
    $template = @"
<toast$scenarioAttr>
  <visual>
    <binding template="ToastGeneric">
      <text>$([System.Security.SecurityElement]::Escape($Title))</text>
$bodyXml
    </binding>
  </visual>
</toast>
"@

    $shown = $false
    # 路径 1：本进程直发（Windows PowerShell 5.1 原生支持 WinRT 投影）
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime]
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml($template)
        $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('Microsoft.Windows.Explorer').Show($toast)
        $shown = $true
    } catch { }

    # 路径 2：pwsh 7 直发失败时委托 powershell.exe 5.1 子进程代发（XML 经环境变量传递，避免引号问题）
    if (-not $shown) {
        try {
            $env:ScoopToastXml = $template
            $child = @'
try {
    [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime]
    $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
    $xml.LoadXml($env:ScoopToastXml)
    $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('Microsoft.Windows.Explorer').Show($toast)
    exit 0
} catch { exit 1 }
'@
            $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($child))
            & "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -EncodedCommand $encoded
            $shown = ($LASTEXITCODE -eq 0)
        } catch { } finally {
            Remove-Item Env:\ScoopToastXml -ErrorAction SilentlyContinue
        }
    }

    # 兑底：仅控制台窗口可见（手动双击）时弹 MessageBox；静默路径默认不弹阻塞对话框（只写日志，不阻塞）——唯一例外是交互补更征询弹窗（限时自愈）
    if (-not $shown) {
        try {
            Add-Type -AssemblyName System.Windows.Forms
            Add-Type -Namespace Win32 -Name NativeMethods -MemberDefinition '[DllImport("user32.dll")] public static extern IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);'
            if ([Win32.NativeMethods]::IsWindowVisible([Win32.NativeMethods]::GetConsoleWindow())) {
                [System.Windows.Forms.MessageBox]::Show((@($Body) -join "`r`n"), $Title, 'OK', 'Warning') | Out-Null
            } else {
                Write-Host "（桌面通知发送失败，详情见 update.log）"
            }
        } catch {
            Write-Host "（桌面通知发送失败，详情见 update.log）"
        }
    }
}

# ---------- 汇总数据 → 通知文案：汇报项的增减/改措辞只动本函数（数据在脚本尾部组装） ----------
function ConvertTo-ToastText {
    param([pscustomobject]$R)
    $lines = New-Object System.Collections.Generic.List[string]

    if ($R.HasError) {
        $title = 'Scoop 自动更新出现错误'
        $lines.Add(('错误详情：{0}' -f $R.ErrorSummary))
        if ($R.UpdatedCount -gt 0) {
            $lines.Add(('本轮已更新 {0} 个：{1}' -f $R.UpdatedCount, $R.UpdatedSummary))
        }
    } elseif ($R.UpdatedCount -gt 0) {
        $title = ('Scoop 自动更新：已更新 {0} 个应用' -f $R.UpdatedCount)
        $lines.Add(('已更新：{0}' -f $R.UpdatedSummary))
    } else {
        $title = 'Scoop 自动更新：所有应用均为最新'
        $lines.Add('无应用需要更新')
    }

    if (@($R.Skipped).Count -gt 0) {
        $lines.Add(('进程占用跳过：{0}（关闭程序后可手动补更）' -f ($R.Skipped -join '、')))
    }
    # 交互补更结果行（数据来自脚本作用域 ix* 变量，接缝块回填；未触发交互时为空，不显示）
    if (@($script:ixUpdatedNames).Count -gt 0) {
        $lines.Add(('已关闭并补更 {0} 个：{1}' -f @($script:ixUpdatedNames).Count, ($script:ixUpdatedNames -join '、')))
    }
    if (@($script:ixRestarted).Count -gt 0) {
        $lines.Add(('已自动重开 {0} 个：{1}' -f @($script:ixRestarted).Count, ($script:ixRestarted -join '、')))
    }
    if (@($script:ixRestartFailed).Count -gt 0) {
        $lines.Add(('重开失败：{0}' -f ($script:ixRestartFailed -join '、')))
    }
    if (@($script:ixCloseFailed).Count -gt 0) {
        $lines.Add(('未能关闭：{0}' -f ($script:ixCloseFailed -join '、')))
    }
    if ($R.CleanedCount -gt 0 -or @($R.CleanupFailed).Count -gt 0) {
        $line = ('旧版本清理：{0} 个应用' -f $R.CleanedCount)
        if (@($R.CleanupFailed).Count -gt 0) {
            $line += ('；{0} 个占用下轮补清：{1}' -f @($R.CleanupFailed).Count, ($R.CleanupFailed -join '、'))
        }
        $lines.Add($line)
    } else {
        $lines.Add('旧版本清理：无旧版本需清理')
    }

    if ($R.Elapsed.TotalMinutes -ge 1) {
        $lines.Add(('耗时 {0} 分 {1} 秒' -f [int][Math]::Floor($R.Elapsed.TotalMinutes), $R.Elapsed.Seconds))
    } else {
        $lines.Add(('耗时 {0} 秒' -f [int][Math]::Floor($R.Elapsed.TotalSeconds)))
    }

    return @{ Title = $title; Lines = @($lines) }
}

# ---------- 日志轮转：超过 10MB 仅保留最后 2000 行 ----------
if ((Test-Path $logFile) -and ((Get-Item $logFile).Length -gt 10MB)) {
    $tail = Get-Content $logFile -Tail 2000
    Set-Content $logFile -Value $tail -Encoding UTF8
}

Start-Transcript -Path $logFile -Append | Out-Null
Write-Host ''
Write-Host ("==================== {0} 开始自动更新 ====================" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

# ---------- 任务自愈（交互确认式）：任务缺失时询问是否重建 ----------
# 仅交互（双击 .cmd）场景可达此处询问：静默路径（计划任务→vbs）任务必存在，恒跳过；
# 任务存在但被禁用同样跳过（用户显式停用意图不被推翻）
if (-not (Get-ScheduledTask -TaskName 'ScoopAutoUpdate' -ErrorAction SilentlyContinue)) {
    Write-Host ''
    Write-Host '>>> 检测到计划任务 ScoopAutoUpdate 不存在（新部署 / 任务被删除）'
    $answer = Read-Host '是否重建自动更新任务（每次登录延迟 3 分钟后自动运行）？输入 Y 重建 / N 跳过（仅本次手动更新）'
    if ($answer -match '^[Yy]') {
        try { Register-ScoopAutoUpdateTask } catch {
            Write-Host (">>> 任务注册失败（{0}）——本次更新不受影响，可稍后重试" -f $_.Exception.Message)
        }
    } else {
        Write-Host '>>> 已跳过任务重建，本次仅执行手动更新'
    }
}

# ---------- 代理配置残留自愈：上次运行异常中断可能残留 proxy=none，本次恢复为未配置 ----------
$staleProxy = (& "$scoopHome\shims\scoop.cmd" config proxy 2>$null | Out-String).Trim()
if ($staleProxy -eq 'none') {
    & "$scoopHome\shims\scoop.cmd" config rm proxy | Out-Null
    Write-Host '>>> 已清理上次中断残留的 scoop proxy=none 配置'
}

# ---------- 1) 同步 scoop 自身 + 所有 bucket（原生；abgox 不覆盖这两项） ----------
Write-Host ''
Write-Host '>>> 步骤 1/3：scoop update（同步 scoop 自身与所有 bucket）'
$step1Output = & "$scoopHome\shims\scoop.cmd" update 2>&1 | Out-String
Write-Host $step1Output
$step1Code = $LASTEXITCODE

# ---------- 2) 所有应用直连官方源更新（原生 scoop update *；bucket 同步见步骤 1） ----------
# 系统代理不可达（代理软件未就绪）时临时置 scoop proxy=none 直连本轮，
# 用 try/finally 保证恢复；异常中断残留由上方自愈逻辑兑底
Write-Host '>>> 步骤 2/3：scoop update *（所有应用，直连官方源）'
$sysProxy = Get-SystemProxy
$proxyToggled = $false
if ($sysProxy -and -not (Test-ProxyAlive $sysProxy)) {
    Write-Host (">>> 系统代理 $sysProxy 不可达（代理软件未就绪），本轮更新临时直连")
    & "$scoopHome\shims\scoop.cmd" config proxy none | Out-Null
    $proxyToggled = $true
}
try {
    $appOutput = & "$scoopHome\shims\scoop.cmd" update * 2>&1 | Out-String
    $step2Code = $LASTEXITCODE
} finally {
    if ($proxyToggled) {
        & "$scoopHome\shims\scoop.cmd" config rm proxy | Out-Null
        Write-Host '>>> 已恢复 scoop 代理配置（直连仅限本轮）'
    }
}
Write-Host $appOutput

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

# ---------- 4.2) 交互式补更：被占用跳过的应用弹窗征询，确认后关闭程序补更并自动重开 ----------
# 下游 $report/Toast 与 cleanup 循环零改动：$updated/$summary/$skipped/$failedSteps 就地合并重建；
# 随后的 cleanup 循环遍历所有应用，自动清理补更产生的旧版本目录。
$interactive = $null
try {
    $interactive = Invoke-InteractiveSkippedUpdate -SkippedApps $skipped -ScoopHome $scoopHome -UpdateRegex $updateRegex
} catch {
    Write-Host ">>> 交互补更环节异常，本轮降级为仅跳过：$($_.Exception.Message)"
    # 降级空壳：StillSkipped 回填原值，其余为空 → 下游合并逻辑得到与“未触发交互”完全等价的结果
    $interactive = [pscustomobject]@{ Updated = @(); StillSkipped = @($skipped); Restarted = @(); RestartFailed = @(); CloseFailed = @(); Output = ''; ErrorLines = '' }
}
# 按应用名去重并集（排除主流程已计入者，防同名重复计数）
$existingNames = @($updated | ForEach-Object { $_.Name })
$updated = @($updated) + @($interactive.Updated | Where-Object { $existingNames -notcontains $_.Name })
$summary = if ($updated.Count -gt 0) {
    ($updated | ForEach-Object { "$($_.Name) ($($_.Version))" }) -join '; '
} else { '所有应用均为最新版本' }
$skipped = @($interactive.StillSkipped)
if ($interactive.ErrorLines) {
    $failedSteps.Add("交互补更：$($interactive.ErrorLines)")
    $errorSummary = ($failedSteps -join "`n")
    if ($errorSummary.Length -gt 300) { $errorSummary = $errorSummary.Substring(0, 300) + '…' }
}
$ixUpdatedNames  = @($interactive.Updated | ForEach-Object { $_.Name } | Select-Object -Unique)
$ixRestarted     = @($interactive.Restarted)
$ixRestartFailed = @($interactive.RestartFailed)
$ixCloseFailed   = @($interactive.CloseFailed)
Write-Host ('>>> 交互补更结果：更新 {0} 个；仍跳过 {1} 个；重开 {2} 个；重开失败 {3} 个；未能关闭 {4} 个' -f @($interactive.Updated).Count, @($interactive.StillSkipped).Count, @($interactive.Restarted).Count, @($interactive.RestartFailed).Count, @($interactive.CloseFailed).Count)

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
$cleanedCount = 0
$appNames = Get-ChildItem (Join-Path $scoopHome 'apps') -Directory | Select-Object -ExpandProperty Name
foreach ($appName in $appNames) {
    $oneOutput = & "$scoopHome\shims\scoop.cmd" cleanup $appName -k 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        $cleanupFailed.Add($appName)
        Write-Host ("[{0}] 清理未完成（可能被进程占用，下轮补清）" -f $appName)
    } elseif ($oneOutput.Trim()) {
        $cleanedCount++
        Write-Host $oneOutput.TrimEnd()
    }
}
if ($cleanupFailed.Count -gt 0) {
    Write-Host ("（{0} 个应用本轮清理不完全：{1}；不影响更新结果）" -f $cleanupFailed.Count, ($cleanupFailed -join ', '))
} else {
    Write-Host '（全部应用清理完成）'
}

# ---------- 5) 汇总通知（每次运行必发一条；此处只组装结果数据，文案与样式分属上方两个函数，单点维护） ----------
$report = [pscustomobject]@{
    HasError       = ($failedSteps.Count -gt 0)
    ErrorSummary   = $(if ($failedSteps.Count -gt 0) { $errorSummary } else { '' })
    UpdatedCount   = @($updated).Count
    UpdatedSummary = $summary
    Skipped        = @($skipped)
    CleanedCount   = $cleanedCount
    CleanupFailed  = @($cleanupFailed)
    Elapsed        = ((Get-Date) - $scriptStart)
}
$toast = ConvertTo-ToastText -R $report
Write-Host ''
Write-Host ('>>> {0}' -f $toast.Title)
foreach ($line in $toast.Lines) { Write-Host ('>>> {0}' -f $line) }
Show-ScoopToast -Title $toast.Title -Body $toast.Lines -Urgent:$report.HasError

Write-Host ("==================== 结束 ====================")
Stop-Transcript | Out-Null
