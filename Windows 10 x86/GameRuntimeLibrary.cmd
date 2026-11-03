@echo off
call "%~dp0..\GameRuntimeLibrary.cmd" -NoUpdate %*
exit /b %ERRORLEVEL%
