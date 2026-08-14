@echo off
setlocal
cd /d "%~dp0"
echo setup.cmd is kept for compatibility. Redirecting to install.bat...
call "%~dp0install.bat"
exit /b %errorlevel%
