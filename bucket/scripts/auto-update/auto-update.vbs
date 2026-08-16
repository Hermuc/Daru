' Scoop auto-update launcher (called by Task Scheduler task "ScoopAutoUpdate")
' Runs PowerShell with window style 0: console is hidden from creation, no conhost flash.
' Portable: resolves auto-update.ps1 next to THIS file (no hardcoded path).
' ASCII-only file on purpose - WScript reads .vbs as ANSI.
Set fso = CreateObject("Scripting.FileSystemObject")
Set ws = CreateObject("WScript.Shell")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
ws.Run """C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"" -NoProfile -ExecutionPolicy Bypass -File """ & dir & "\auto-update.ps1""", 0, False
