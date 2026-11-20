@echo off
setlocal
set "ACTION=%~1"
if "%ACTION%"=="" set "ACTION=start"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\dev-engine.ps1" -Action %ACTION%
exit /b %errorlevel%
