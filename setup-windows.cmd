@echo off
setlocal
pushd "%~dp0" || exit /b 1
where py.exe >nul 2>nul
if not errorlevel 1 (
    py -3 -c "import sys; sys.exit(sys.version_info < (3, 9))" >nul 2>nul
    if not errorlevel 1 goto launcher
)
if exist "%LOCALAPPDATA%\Programs\Python\Python312\python.exe" goto installed
for /f "delims=" %%P in ('where python.exe 2^>nul ^| findstr /i /v /l "WindowsApps"') do (
    "%%P" -c "import sys; sys.exit(sys.version_info < (3, 9))" >nul 2>nul
    if not errorlevel 1 (
        set "UNIVERSE_PYTHON=%%P"
        goto found
    )
)
where winget.exe >nul 2>nul || (
    echo Python 3.9+ or Microsoft App Installer with WinGet is required.
    exit /b 1
)
winget install --exact --id Python.Python.3.12 --source winget --scope user --accept-source-agreements --accept-package-agreements
if exist "%LOCALAPPDATA%\Programs\Python\Python312\python.exe" goto installed
echo Reopen the local Windows terminal after installing Python 3 and retry.
exit /b 1
:installed
set "UNIVERSE_PYTHON=%LOCALAPPDATA%\Programs\Python\Python312\python.exe"
:found
"%UNIVERSE_PYTHON%" tools\setup_windows.py
exit /b %errorlevel%
:launcher
py -3 tools\setup_windows.py
exit /b %errorlevel%
