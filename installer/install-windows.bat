@echo off
rem Double-click to install / set up the EX6150v2 VLESS access point.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
if errorlevel 1 pause
