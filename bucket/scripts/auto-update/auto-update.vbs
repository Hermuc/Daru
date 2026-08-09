' Scoop auto-update launcher (called by Task Scheduler task "ScoopAutoUpdate")
' Runs PowerShell with window style 0: console is hidden from creation, no conhost flash.
' ASCII-only file on purpose - WScript reads .vbs as ANSI.
Set ws = CreateObject("WScript.Shell")
ws.Run """C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"" -NoProfile -ExecutionPolicy Bypass -File ""D:\PortableApps\Scoop\auto-update.ps1""", 0, False
