@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "SCRIPT_PATH=%SCRIPT_DIR%stardew-save-bridge.ps1"

if not exist "%SCRIPT_PATH%" (
    echo Could not find stardew-save-bridge.ps1 next to this launcher.
    pause
    exit /b 1
)

pushd "%SCRIPT_DIR%"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_PATH%"
set "EXIT_CODE=%ERRORLEVEL%"
popd

echo.
if "%EXIT_CODE%"=="0" (
    echo Stardew Save Bridge completed with exit code 0.
) else (
    echo Stardew Save Bridge exited with code %EXIT_CODE%.
)

pause

exit /b %EXIT_CODE%
