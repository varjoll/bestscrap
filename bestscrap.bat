@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0bestscrap.ps1" %*
exit /b %errorlevel%
