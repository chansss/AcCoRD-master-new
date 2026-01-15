@echo off
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_all_samples.ps1"
echo.
echo Done. Press any key to exit...
pause >nul

