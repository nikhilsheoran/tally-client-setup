@echo off
setlocal
set "SCRIPT_URL=https://raw.githubusercontent.com/nikhilsheoran/tally-client-setup/main/install.ps1"

echo Downloading latest Tally setup script...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "irm '%SCRIPT_URL%' | iex"

echo.
echo Setup window closed. You can close this window now.
pause
