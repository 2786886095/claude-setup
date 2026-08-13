@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ClaudeSetup.ps1" -Action Diagnose
set "exit_code=%errorlevel%"
echo.
echo Diagnostic report was written to the reports folder.
pause
exit /b %exit_code%

