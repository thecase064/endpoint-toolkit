@echo off
rem Double-click launcher: pulls the latest Endpoint Toolkit from GitHub and opens the toolkit window.
rem Right-click > Run as administrator for the build tools. Contains no tools itself, so it never goes stale.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072; irm 'https://raw.githubusercontent.com/thecase064/endpoint-toolkit/main/install.ps1' | iex"
if errorlevel 1 pause
