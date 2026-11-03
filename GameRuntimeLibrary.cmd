@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\Bootstrap-GameRuntimeLibrary.ps1" %*
set "GRL_EXIT=%ERRORLEVEL%"
if not "%GRL_EXIT%"=="0" (
    echo.
    echo 启动器退出码：%GRL_EXIT%
    pause
)
exit /b %GRL_EXIT%
