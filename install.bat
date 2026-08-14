@echo off
setlocal EnableExtensions
chcp 65001 >nul 2>&1
title Claude Setup - Recommended installer - install.bat
cd /d "%~dp0"

set "CLAUDE_SETUP_PS1=%~dp0ClaudeSetup.ps1"
set "CLAUDE_SETUP_BAT=%~f0"
set "CLAUDE_SETUP_DIR=%~dp0"

if not exist "%CLAUDE_SETUP_PS1%" (
    echo [ERROR] ClaudeSetup.ps1 was not found next to install.bat.
    echo Please download and extract the complete claude-setup repository first.
    pause
    exit /b 2
)

fltmc.exe >nul 2>&1
if errorlevel 1 (
    echo Requesting administrator privileges...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
      "Start-Process -FilePath $env:CLAUDE_SETUP_BAT -WorkingDirectory $env:CLAUDE_SETUP_DIR -Verb RunAs"
    exit /b %errorlevel%
)

echo ============================================================
echo  Recommended entry: install.bat
echo  Installing or repairing Claude Desktop and Cowork...
echo ============================================================
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%CLAUDE_SETUP_PS1%" -Action Auto
set "CLAUDE_SETUP_EXIT=%errorlevel%"

echo.
if "%CLAUDE_SETUP_EXIT%"=="0" (
    echo Claude Desktop and Cowork setup completed.
) else if "%CLAUDE_SETUP_EXIT%"=="3010" (
    echo Windows restart is required. Restart the computer to continue setup.
) else if "%CLAUDE_SETUP_EXIT%"=="194" (
    echo Windows restart is required. Restart the computer to continue setup.
) else if "%CLAUDE_SETUP_EXIT%"=="4" (
    echo VM rebuild is waiting for Cowork to finish downloading.
    echo Open Cowork in Claude, wait for the download, then run install.bat again.
    echo The encrypted backup has NOT been deleted.
) else (
    echo Setup exited with code %CLAUDE_SETUP_EXIT%.
    echo Check the reports folder for diagnostics.
)

pause
exit /b %CLAUDE_SETUP_EXIT%
