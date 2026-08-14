@echo off
setlocal EnableExtensions
chcp 65001 >nul 2>&1
title Claude Setup - Recommended installer - install.bat
cd /d "%~dp0"

set "CLAUDE_SETUP_PS1=%~dp0ClaudeSetup.ps1"
set "CLAUDE_SETUP_ELEVATOR=%~dp0ElevateInstall.ps1"
set "CLAUDE_SETUP_DIR=%~dp0"
set "CLAUDE_SETUP_REPORTS=%~dp0reports"
set "CLAUDE_SETUP_BOOTSTRAP_LOG=%CLAUDE_SETUP_REPORTS%\install-bootstrap.log"

if not exist "%CLAUDE_SETUP_REPORTS%" mkdir "%CLAUDE_SETUP_REPORTS%" >nul 2>&1
>>"%CLAUDE_SETUP_BOOTSTRAP_LOG%" echo [%date% %time%] install.bat started from "%CLAUDE_SETUP_DIR%"

if not exist "%CLAUDE_SETUP_PS1%" (
    echo [ERROR] ClaudeSetup.ps1 was not found next to install.bat.
    echo Please download and extract the complete claude-setup repository first.
    pause
    exit /b 2
)
if not exist "%CLAUDE_SETUP_ELEVATOR%" (
    echo [ERROR] ElevateInstall.ps1 was not found next to install.bat.
    >>"%CLAUDE_SETUP_BOOTSTRAP_LOG%" echo [%date% %time%] ERROR ElevateInstall.ps1 missing
    echo Please download and extract the complete claude-setup package first.
    pause
    exit /b 2
)

fltmc.exe >nul 2>&1
if errorlevel 1 goto request_administrator
goto administrator_confirmed

:request_administrator
echo Requesting administrator privileges...
>>"%CLAUDE_SETUP_BOOTSTRAP_LOG%" echo [%date% %time%] requesting UAC through cmd.exe helper
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%CLAUDE_SETUP_ELEVATOR%"
set "CLAUDE_SETUP_ELEVATION_EXIT=%errorlevel%"
>>"%CLAUDE_SETUP_BOOTSTRAP_LOG%" echo [%date% %time%] elevated child exited with code %CLAUDE_SETUP_ELEVATION_EXIT%
if "%CLAUDE_SETUP_ELEVATION_EXIT%"=="0" exit /b 0
if "%CLAUDE_SETUP_ELEVATION_EXIT%"=="194" exit /b 194
if "%CLAUDE_SETUP_ELEVATION_EXIT%"=="4" exit /b 4
echo [ERROR] Elevated installer exited with code %CLAUDE_SETUP_ELEVATION_EXIT%.
echo Check reports\install-bootstrap.log.
pause
exit /b %CLAUDE_SETUP_ELEVATION_EXIT%

:administrator_confirmed

>>"%CLAUDE_SETUP_BOOTSTRAP_LOG%" echo [%date% %time%] administrator token confirmed; starting ClaudeSetup.ps1

echo ============================================================
echo  Recommended entry: install.bat
echo  Installing or repairing Claude Desktop and Cowork...
echo ============================================================
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%CLAUDE_SETUP_PS1%" -Action Auto
set "CLAUDE_SETUP_EXIT=%errorlevel%"
>>"%CLAUDE_SETUP_BOOTSTRAP_LOG%" echo [%date% %time%] ClaudeSetup.ps1 exited with code %CLAUDE_SETUP_EXIT%

echo.
if "%CLAUDE_SETUP_EXIT%"=="0" (
    echo Claude Desktop and Cowork setup completed.
    echo Desktop shortcut: Claude.lnk was created or updated on the current user's desktop.
    echo Any encrypted VM backup is still retained and was NOT automatically deleted.
) else if "%CLAUDE_SETUP_EXIT%"=="3010" (
    echo ============================================================
    echo  NEXT STEPS / 下一步：重启后继续完成
    echo ============================================================
    echo  1. Do NOT move or delete this extracted setup folder.
    echo     不要移动或删除当前解压目录。
    echo  2. Restart Windows now.
    echo     现在重启 Windows。
    echo  3. After sign-in, accept the UAC prompt so setup can resume.
    echo     登录后接受 UAC，脚本会自动续跑。
    echo  4. When Claude opens, enter Cowork and keep this window open.
    echo     Claude 启动后进入 Cowork，并保持本窗口开启。
    echo  5. If setup does not resume automatically, run install.bat again.
    echo     如果没有自动续跑，再次运行同一目录的 install.bat。
) else if "%CLAUDE_SETUP_EXIT%"=="194" (
    echo ============================================================
    echo  NEXT STEPS / 下一步：重启后继续完成
    echo ============================================================
    echo  1. Do NOT move or delete this extracted setup folder.
    echo     不要移动或删除当前解压目录。
    echo  2. Restart Windows now.
    echo     现在重启 Windows。
    echo  3. After sign-in, accept the UAC prompt so setup can resume.
    echo     登录后接受 UAC，脚本会自动续跑。
    echo  4. When Claude opens, enter Cowork and keep this window open.
    echo     Claude 启动后进入 Cowork，并保持本窗口开启。
    echo  5. If setup does not resume automatically, run install.bat again.
    echo     如果没有自动续跑，再次运行同一目录的 install.bat。
) else if "%CLAUDE_SETUP_EXIT%"=="4" (
    echo ============================================================
    echo  NEXT STEPS / 下一步：等待 Cowork 重建完成
    echo ============================================================
    echo  1. Open Claude and enter Cowork to start or continue the VM download.
    echo     打开 Claude 并进入 Cowork，让 VM 开始或继续下载。
    echo  2. Wait for the Cowork download to finish.
    echo     等待 Cowork 下载完成。
    echo  3. Run install.bat again to perform final verification.
    echo     再次运行 install.bat，完成最终验证。
    echo  4. The encrypted backup has NOT been deleted.
    echo     加密备份仍然保留，没有被删除。
) else (
    echo Setup exited with code %CLAUDE_SETUP_EXIT%.
    echo Check the reports folder for diagnostics.
)

pause
exit /b %CLAUDE_SETUP_EXIT%
