# cleanup-guoheview-assoc.ps1
# 完整撤销 set-guoheview-default.ps1 创建的 GuoheView 用户级文件关联配置。
# 清理范围（全部 HKCU，不影响其他程序）：
#   1. HKCU\Software\Classes\Applications\GuoheView.exe（应用入口）
#   2. HKCU\Software\GuoheView（Capabilities 分支）
#   3. HKCU\Software\RegisteredApplications 的 GuoheView 值
#   4. FileExts 各扩展名 OpenWithProgids 中的 Applications\GuoheView.exe 值
# UserChoice 说明：set 脚本从未写入 UserChoice（受 Deny ACL + Hash 保护），
#   因此本脚本也不删除任何 UserChoice；若某扩展名当前默认仍是 GuoheView
#   （由你通过 UI"始终"设置的），将在摘要中列出，请通过 UI 重设其他默认程序。
$ErrorActionPreference = 'Stop'

$appKey  = 'HKCU:\Software\Classes\Applications\GuoheView.exe'
$softKey = 'HKCU:\Software\GuoheView'
$regApps = 'HKCU:\Software\RegisteredApplications'
$fe      = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts'
$owValue = 'Applications\GuoheView.exe'

# ---------- 0) 环境检查 ----------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Host "[info] admin = $isAdmin (本脚本全部操作 HKCU 用户级分支，普通权限即可)"

# ---------- 1) 备份（仅备份已存在的分支；任一失败即中止） ----------
$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$bk = Join-Path $env:USERPROFILE "Desktop\guoheview-cleanup-$ts"
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

# ---------- 2) 删除应用入口与 Capabilities 分支 ----------
Write-Host '[2/5] 删除应用入口与 Capabilities ...'
foreach ($k in $appKey, $softKey) {
    if (Test-Path $k) { Remove-Item $k -Recurse -Confirm:$false; Write-Host "      deleted: $k" }
    else { Write-Host "      skip(不存在): $k" }
}

# ---------- 3) 删除 RegisteredApplications\GuoheView 值 ----------
Write-Host '[3/5] 清理 RegisteredApplications ...'
$props = Get-ItemProperty $regApps -ErrorAction SilentlyContinue
if ($props -and $props.PSObject.Properties.Name -contains 'GuoheView') {
    Remove-ItemProperty $regApps -Name 'GuoheView' -Confirm:$false
    Write-Host '      deleted value: GuoheView'
} else { Write-Host '      skip(值不存在)' }

# ---------- 4) 清理各扩展名 OpenWithProgids 中的 GuoheView 引用 ----------
Write-Host '[4/5] 清理 FileExts OpenWithProgids ...'
$removed = 0
Get-ChildItem $fe | ForEach-Object {
    $extName = $_.PSChildName
    $owp = Join-Path $_.PSPath 'OpenWithProgids'
    if (Test-Path $owp) {
        (Get-Item $owp).Property | Where-Object { $_ -eq $owValue } | ForEach-Object {
            Remove-ItemProperty $owp -Name $_ -Confirm:$false
            Write-Host "      [del] FileExts\$extName\OpenWithProgids"
            $script:removed++
        }
    }
}
Write-Host "      共删除 $removed 处引用"

# ---------- 5) 扫描仍指向 GuoheView 的 UserChoice（不删除，仅提示） ----------
Write-Host '[5/5] 扫描 UserChoice（受保护，不删除）...'
$ucLeft = @()
Get-ChildItem $fe | ForEach-Object {
    $ucPath = Join-Path $_.PSPath 'UserChoice'
    if (Test-Path $ucPath) {
        $pid2 = (Get-ItemProperty $ucPath -ErrorAction SilentlyContinue).ProgId
        if ($pid2 -eq $owValue) { $ucLeft += $_.PSChildName }
    }
}
Write-Host ''
Write-Host '[DONE] 清理摘要:'
Write-Host "  - 应用入口/Capabilities/RegisteredApplications/OpenWithProgids 已按上文逐项处理（备份: $bk）"
if ($ucLeft.Count -gt 0) {
    Write-Host "  - 以下扩展名的默认程序仍是 GuoheView（你曾用 UI 设置），如需改回请逐个右键 -> 打开方式 -> 选择其他应用 -> 勾选'始终':"
    $ucLeft | ForEach-Object { Write-Host "      $_" }
} else {
    Write-Host '  - 无扩展名的 UserChoice 指向 GuoheView，无需额外操作'
}
Write-Host '  验证方法: Stop-Process -Name explorer -Force（explorer 会自动重启）或注销后，'
Write-Host '  右键图片文件 -> 打开方式，确认 GuoheView 不再异常出现；默认程序按你的 UI 选择生效。'
