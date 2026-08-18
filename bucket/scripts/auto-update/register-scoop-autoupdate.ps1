<#
.SYNOPSIS
    Register (or update) the ScoopAutoUpdate scheduled task. Run once after
    deploying the auto-update scripts, and again after any Windows reinstall.

.DESCRIPTION
    Portable - no hardcoded paths:
    - Scoop home = the PARENT of the folder containing this script (must be
      the Scoop root, i.e. the directory holding apps\ and shims\); the
      scripts themselves live in a subfolder (convention: AutoUpdate\).
    - The task ACTION is built dynamically:
          wscript.exe "<this folder>\auto-update.vbs"
      so the task keeps working even if the drive letter or folder moves.
    - No admin rights needed (task runs at logon with least privilege).

.DEPLOY
    1. Copy this whole folder into a subfolder (convention: AutoUpdate)
       under your Scoop root (auto-update.ps1, auto-update.vbs,
       register-scoop-autoupdate.ps1, plus the two .cmd double-click
       wrappers).
    2. Double-click register-scoop-autoupdate.cmd, or run:
       powershell -ExecutionPolicy Bypass -File .\register-scoop-autoupdate.ps1

.ROLLBACK
    Unregister-ScheduledTask -TaskName ScoopAutoUpdate -Confirm:$false
#>
$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot
$scoopHome = Split-Path -Parent $scriptDir

if (-not ((Test-Path (Join-Path $scoopHome 'apps')) -and (Test-Path (Join-Path $scoopHome 'shims')))) {
    Write-Host "[ERROR] $scoopHome does not look like a Scoop root (apps\ and shims\ required)." -ForegroundColor Red
    exit 1
}
foreach ($req in 'auto-update.ps1', 'auto-update.vbs') {
    if (-not (Test-Path (Join-Path $scriptDir $req))) {
        Write-Host "[ERROR] missing $req in $scriptDir" -ForegroundColor Red
        exit 1
    }
}

# --- logon trigger delay (inlined; the former ScoopAutoUpdate.xml template
#     was removed because this constant was the only field ever consumed) ---
$delay = 'PT3M'

# --- build the action dynamically (always points at THIS folder) ---
$action = New-ScheduledTaskAction -Execute 'C:\Windows\System32\wscript.exe' `
    -Argument ('"{0}"' -f (Join-Path $scriptDir 'auto-update.vbs')) `
    -WorkingDirectory $scriptDir

$taskName = 'ScoopAutoUpdate'
$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing) {
    Set-ScheduledTask -TaskName $taskName -Action $action | Out-Null
    Write-Host "Task '$taskName' UPDATED."
} else {
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 2) -MultipleInstances IgnoreNew
    $logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $logonTrigger.Delay = $delay
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $logonTrigger `
        -Principal $principal -Settings $settings `
        -Description 'Scoop logon auto-update + per-app old-version cleanup (see Scoop auto-update scripts).' | Out-Null
    Write-Host "Task '$taskName' REGISTERED."
}

# --- verify ---
$info = Get-ScheduledTask -TaskName $taskName
Write-Host ("State: {0}" -f $info.State)
Write-Host ("Action: {0} {1}" -f $info.Actions.Execute, $info.Actions.Arguments)
Write-Host ''
Write-Host 'Done. Test with:  Start-ScheduledTask -TaskName ScoopAutoUpdate'
Write-Host ('Then check:       Get-Content "{0}" -Tail 30' -f (Join-Path $scoopHome 'update.log'))
