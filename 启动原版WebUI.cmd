@echo off
setlocal
cd /d "%~dp0"
"%~dp0.venv-win\Scripts\python.exe" "%~dp0scripts\launch_original_webui.py" %*
if errorlevel 1 pause
