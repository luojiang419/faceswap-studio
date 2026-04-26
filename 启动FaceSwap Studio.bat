@echo off
setlocal
set ROOT=%~dp0
set PYTHON=%ROOT%..\.venv-win\Scripts\python.exe

if exist "%PYTHON%" (
    "%PYTHON%" "%ROOT%launch_faceswap_studio.py"
) else (
    python "%ROOT%launch_faceswap_studio.py"
)
