@echo off
setlocal
set "APP_DIR=%~dp0faceswap studio\runtime\windows_app\current"
if not exist "%APP_DIR%\faceswap_studio.exe" (
  echo FaceSwap Studio GUI not found:
  echo %APP_DIR%\faceswap_studio.exe
  exit /b 1
)
pushd "%APP_DIR%"
start "" ".\faceswap_studio.exe"
popd
exit /b 0
