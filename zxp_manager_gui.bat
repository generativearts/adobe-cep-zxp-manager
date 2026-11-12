@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0zxp_tools\zxp_manager_start.ps1"
exit /b %errorlevel%
