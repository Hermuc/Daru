@echo off
rem Double-click wrapper for auto-update.ps1: manual full Scoop update
rem (scoop update + native scoop update * app update + per-app old-version
rem cleanup). Same pipeline as the scheduled task, but interactive:
rem progress is shown in this console window, results also go to
rem <Scoop root>\update.log.
rem
rem DEPLOY FIRST: copy the whole auto-update folder into your Scoop root
rem (the folder containing apps\ and shims\), then double-click this file.
rem Running it from the repository location will fail by design.
rem Engine: prefers pwsh 7+ (on PATH), falls back to 5.1 - same pattern as scoop.cmd.
where /q pwsh.exe
if %errorlevel% equ 0 (
    pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0auto-update.ps1"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0auto-update.ps1"
)
echo.
pause
