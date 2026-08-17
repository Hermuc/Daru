' Scoop auto-update launcher (called by Task Scheduler task "ScoopAutoUpdate")
' Runs PowerShell with window style 0: console is hidden from creation, no conhost flash.
' Portable: resolves auto-update.ps1 next to THIS file (no hardcoded path).
' Engine: prefers pwsh 7+ (found on PATH, e.g. Scoop shim), falls back to 5.1.
' ASCII-only file on purpose - WScript reads .vbs as ANSI.
Set fso = CreateObject("Scripting.FileSystemObject")
Set ws = CreateObject("WScript.Shell")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
pathDirs = Split(ws.ExpandEnvironmentStrings("%PATH%"), ";")
psExe = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
For Each d In pathDirs
    If Len(d) > 0 And fso.FileExists(d & "\pwsh.exe") Then
        psExe = d & "\pwsh.exe"
        Exit For
    End If
Next
ws.Run """" & psExe & """ -NoProfile -ExecutionPolicy Bypass -File """ & dir & "\auto-update.ps1""", 0, False
