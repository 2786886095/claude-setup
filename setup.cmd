@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ClaudeSetup.ps1" -Action Auto
set "exit_code=%errorlevel%"
echo.
if not "%exit_code%"=="0" echo Claude Setup exited with code %exit_code%.
pause
exit /b %exit_code%

