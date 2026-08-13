# set-guoheview-default.ps1
# 将 GuoheView（Scoop 便携版，current junction 稳定路径）注册进当前用户的
# "打开方式"列表与"设置-默认应用"候选（全部 HKCU 写入，不需要管理员权限）。
# 重要限制：FileExts\<ext>\UserChoice 受 Deny ACL + Hash 校验保护，
#   脚本【不会】写入 UserChoice（无法安全伪造有效 Hash，写无效 Hash 会被系统判为损坏）。
#   运行后请对需要的格式执行：右键文件 -> 打开方式 -> 选择其他应用 -> GuoheView -> 勾选"始终"。
$ErrorActionPreference = 'Stop'

# ---------- 0) 配置区：目标程序与扩展名清单（可自行增删） ----------
$exe = 'D:\PortableApps\Scoop\apps\GuoheView\current\GuoheView.exe'
$exts = @('.jpg','.jpeg','.png','.bmp','.gif','.webp','.tif','.tiff','.ico',
          '.heic','.avif','.svg','.psd','.ai','.eps',
          '.raw','.arw','.cr2','.cr3','.nef','.dng','.raf')

$appKey   = 'HKCU:\Software\Classes\Applications\GuoheView.exe'
$capKey   = 'HKCU:\Software\GuoheView\Capabilities'
$regApps  = 'HKCU:\Software\RegisteredApplications'
$fe       = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts'
$owValue  = 'Applications\GuoheView.exe'

# ---------- 1) 环境检查 ----------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Host "[info] admin = $isAdmin (本脚本全部写 HKCU 用户级分支，普通权限即可)"
if (-not (Test-Path $exe)) { Write-Host "[ABORT] 目标程序不存在: $exe"; exit 1 }

# ---------- 2) 备份（仅备份已存在的分支；任一失败即中止） ----------
$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$bk = Join-Path $env:USERPROFILE "Desktop\guoheview-assoc-$ts"
New-Item -ItemType Directory -Path $bk | Out-Null
Write-Host "[1/5] 备份到 $bk ..."
function Backup-Key([string]$regPath, [string]$file) {
    if (-not (Test-Path $regPath)) { Write-Host "      skip(不存在): $regPath"; return $true }
    & reg export $regPath (Join-Path $bk $file) /y 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "[ABORT] 备份失败: $regPath"; return $false }
    Write-Host "      ok: $file"
    return $true
}
if (-not (Backup-Key 'HKCU\Software\Classes\Applications\GuoheView.exe' 'Applications-GuoheView.reg')) { exit 1 }
if (-not (Backup-Key 'HKCU\Software\GuoheView' 'Software-GuoheView.reg')) { exit 1 }
if (-not (Backup-Key 'HKCU\Software\RegisteredApplications' 'RegisteredApplications.reg')) { exit 1 }
if (-not (Backup-Key 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts' 'FileExts.reg')) { exit 1 }

# ---------- 3) 注册应用入口（打开方式列表来源） ----------
Write-Host '[2/5] 注册 HKCU Classes\Applications\GuoheView.exe ...'
$cmdPath = Join-Path $appKey 'shell\open\command'
$wantCmd = "`"$exe`" `"%1`""
if ((Test-Path $cmdPath) -and ((Get-ItemProperty $cmdPath).'(default)' -eq $wantCmd)) {
    Write-Host '      command 已正确，跳过'
} else {
    New-Item -Path $appKey -Force | Out-Null
    Set-ItemProperty $appKey -Name 'FriendlyAppName' -Value 'GuoheView'
    New-Item -Path $cmdPath -Force | Out-Null
    Set-ItemProperty $cmdPath -Name '(default)' -Value $wantCmd
    Write-Host "      command = $wantCmd"
}

# ---------- 4) Capabilities + RegisteredApplications（设置-默认应用候选） ----------
Write-Host '[3/5] 写入 Capabilities 与 RegisteredApplications ...'
New-Item -Path $capKey -Force | Out-Null
Set-ItemProperty $capKey -Name 'ApplicationName' -Value 'GuoheView'
Set-ItemProperty $capKey -Name 'ApplicationDescription' -Value 'GuoheView image viewer (portable)'
$faPath = Join-Path $capKey 'FileAssociations'
New-Item -Path $faPath -Force | Out-Null
foreach ($e in $exts) { Set-ItemProperty $faPath -Name $e -Value $owValue }
Set-ItemProperty $regApps -Name 'GuoheView' -Value 'Software\GuoheView\Capabilities'
Write-Host "      完成 ($($exts.Count) 个 FileAssociations)"

# ---------- 5) 每个扩展名加入 OpenWithProgids，并读取当前 UserChoice ----------
Write-Host '[4/5] 逐扩展名注册 OpenWithProgids ...'
$results = @()
foreach ($e in $exts) {
    $uc = $null
    $ucPath = Join-Path $fe "$e\UserChoice"
    if (Test-Path $ucPath) { $uc = (Get-ItemProperty $ucPath -ErrorAction SilentlyContinue).ProgId }

    $owp = Join-Path $fe "$e\OpenWithProgids"
    New-Item -Path $owp -Force | Out-Null
    $existed = (Get-Item $owp).Property -contains $owValue
    if (-not $existed) {
        New-ItemProperty -Path $owp -Name $owValue -PropertyType None -Value ([byte[]]@()) -Force | Out-Null
    }

    if ($uc -eq $owValue) {
        $results += [pscustomobject]@{ Ext = $e; Status = 'OK 已是默认'; Note = 'UserChoice 已指向 GuoheView' }
    } elseif ($null -eq $uc) {
        $results += [pscustomobject]@{ Ext = $e; Status = 'ADD 已入列表'; Note = '无当前默认，需 UI 勾选"始终"' }
    } else {
        $results += [pscustomobject]@{ Ext = $e; Status = 'ADD 已入列表'; Note = "当前默认=$uc，需 UI 改选 GuoheView" }
    }
}

# ---------- 6) 摘要 ----------
Write-Host '[5/5] 执行摘要:'
$results | Format-Table -AutoSize | Out-String | Write-Host
Write-Host '[DONE] 注册完成。UserChoice 受系统保护未写入（无法安全伪造 Hash）。'
Write-Host '  对需要设为默认的格式：右键文件 -> 打开方式 -> 选择其他应用 -> GuoheView -> 勾选"始终"。'
Write-Host '  若列表中暂无 GuoheView，重启 explorer（Stop-Process -Name explorer -Force）后再试。'
