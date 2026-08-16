@echo off
rem Double-click wrapper for register-scoop-autoupdate.ps1 (register/rebuild
rem the ScoopAutoUpdate scheduled task; run once after deploying, and again
rem after any Windows reinstall).
rem
rem DEPLOY FIRST: copy the whole auto-update folder into your Scoop root
rem (the folder containing apps\ and shims\), then double-click this file.
rem Running it from the repository location will fail by design.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0register-scoop-autoupdate.ps1"
echo.
pause
