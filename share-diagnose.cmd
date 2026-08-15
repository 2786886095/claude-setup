@echo off
setlocal
cd /d "%~dp0"
set "CLAUDE_SETUP_WINDOWS_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "PSModulePath=%SystemRoot%\System32\WindowsPowerShell\v1.0\Modules;%ProgramFiles%\WindowsPowerShell\Modules"
"%CLAUDE_SETUP_WINDOWS_POWERSHELL%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0ClaudeSetup.ps1" -Action Diagnose -Redact
set "exit_code=%errorlevel%"
echo.
echo Redacted share reports were written to the reports folder.
echo Files are named claude-diagnostic-share-*.txt and *.json.
pause
exit /b %exit_code%
