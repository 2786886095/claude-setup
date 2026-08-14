@echo off
setlocal
chcp 65001 >nul 2>&1
title Claude Setup - Legacy compatibility entry
cd /d "%~dp0"
echo [提示] setup.cmd 是旧版兼容入口，不是推荐入口。
echo [提示] 正在自动转交给唯一推荐入口 install.bat，无需再次运行其他文件。
call "%~dp0install.bat"
exit /b %errorlevel%
