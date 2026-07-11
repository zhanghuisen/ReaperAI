@echo off
setlocal EnableExtensions DisableDelayedExpansion
chcp 65001 >nul 2>nul
title ReaperAI v1.0.5 - Install dependencies

set "PYTHON_VERSION=3.11.9"
set "SCRIPT_DIR=%~dp0"
set "SCRIPT_ROOT=%SCRIPT_DIR%"
if "%SCRIPT_ROOT:~-1%"=="\" set "SCRIPT_ROOT=%SCRIPT_ROOT:~0,-1%"
cd /d "%SCRIPT_DIR%" || (
  echo [ERROR] Cannot enter MCP_Server directory.
  pause
  exit /b 1
)

set "RUNTIME_DIR=%SCRIPT_DIR%python_runtime"
set "INSTALLER_DIR=%SCRIPT_DIR%installers"
set "HELPER=%SCRIPT_DIR%config_wizard_helper.py"
set "LOG_FILE=%TEMP%\ReaperAI_install_dependencies_last_error.log"
set "PYTHON_EXE="
set "PYTHONW_EXE="

set "PYTHONUTF8=1"
set "PYTHONIOENCODING=utf-8"
set "REAPERAI_CONFIG_WIZARD_LOG=%LOG_FILE%"

if /i "%~1"=="--self-test" (
  echo SELF_TEST_OK
  exit /b 0
)

if exist "%LOG_FILE%" del /f /q "%LOG_FILE%" >nul 2>nul

echo ============================================
echo   ReaperAI v1.0.5 - Dependency Launcher
echo ============================================
echo.
echo Preparing private Python runtime and dependency installer.
echo Chinese install messages will be printed by the Python helper.
echo.

if not exist "%HELPER%" (
  echo [ERROR] Missing helper:
  echo        %HELPER%
  echo Please restore the full ReaperAI package.
  pause
  exit /b 1
)

call :ensure_python
if errorlevel 1 (
  echo.
  echo [ERROR] Python runtime is not available.
  echo.
  echo Offline fallback:
  echo   1. Put python-%PYTHON_VERSION%-embed-amd64.zip under:
  echo      %INSTALLER_DIR%
  echo   2. Or put python-%PYTHON_VERSION%-amd64.exe in the same folder.
  echo   3. Run this BAT again.
  echo.
  if exist "%LOG_FILE%" echo Detail log: %LOG_FILE%
  pause
  exit /b 1
)

"%PYTHON_EXE%" "%HELPER%" install_dependencies "%SCRIPT_ROOT%"
set "INSTALL_EXIT=%ERRORLEVEL%"
echo.
if not "%INSTALL_EXIT%"=="0" (
  echo [ERROR] Dependency installation failed. Exit code: %INSTALL_EXIT%
  if exist "%LOG_FILE%" echo Detail log: %LOG_FILE%
  pause
  exit /b %INSTALL_EXIT%
)

pause
exit /b 0

:ensure_python
echo [CHECK] Preparing Python runtime...
call :find_python_local
if defined PYTHON_EXE exit /b 0

echo [INFO] Local Python was not found. Preparing bundled portable runtime.
call :bootstrap_python
call :find_python_local
if defined PYTHON_EXE exit /b 0

echo [INFO] Bundled runtime is not available. Trying system Python as final fallback.
call :find_python_system
if defined PYTHON_EXE exit /b 0
exit /b 1

:find_python_local
set "PYTHON_EXE="
set "PYTHONW_EXE="
if exist "%SCRIPT_DIR%python_path.txt" (
  for /f "usebackq delims=" %%P in ("%SCRIPT_DIR%python_path.txt") do (
    if not defined PYTHON_EXE call :try_python_file "%%P"
  )
)
if defined PYTHON_EXE exit /b 0
call :try_python_file "%SCRIPT_DIR%.venv\Scripts\python.exe"
if defined PYTHON_EXE exit /b 0
call :try_python_file "%RUNTIME_DIR%\python.exe"
if defined PYTHON_EXE exit /b 0
call :try_python_file "%SCRIPT_DIR%.python\python.exe"
exit /b 0

:find_python_system
call :try_python_command python
if defined PYTHON_EXE exit /b 0
call :try_python_command python3
if defined PYTHON_EXE exit /b 0
call :try_py_launcher
if defined PYTHON_EXE exit /b 0
call :scan_python_roots "%LOCALAPPDATA%\Programs\Python"
if defined PYTHON_EXE exit /b 0
call :scan_python_roots "%USERPROFILE%\AppData\Local\Programs\Python"
if defined PYTHON_EXE exit /b 0
call :scan_python_roots "%ProgramFiles%"
if defined PYTHON_EXE exit /b 0
call :scan_python_roots "%ProgramFiles(x86)%"
exit /b 0

:try_python_file
set "PY_CAND=%~1"
if "%PY_CAND%"=="" exit /b 0
if not exist "%PY_CAND%" exit /b 0
"%PY_CAND%" -c "import sys; raise SystemExit(0 if sys.version_info >= (3,10) else 1)" >nul 2>>"%LOG_FILE%"
if errorlevel 1 exit /b 0
set "PYTHON_EXE=%PY_CAND%"
if /i "%PY_CAND:~-10%"=="python.exe" (
  set "PYTHONW_EXE=%PY_CAND:~0,-10%pythonw.exe"
) else (
  set "PYTHONW_EXE=%PY_CAND%"
)
>"%SCRIPT_DIR%python_path.txt" echo %PYTHON_EXE%
if exist "%PYTHONW_EXE%" >"%SCRIPT_DIR%pythonw_path.txt" echo %PYTHONW_EXE%
exit /b 0

:try_python_command
set "PY_CMD=%~1"
if "%PY_CMD%"=="" exit /b 0
%PY_CMD% -c "import sys; raise SystemExit(0 if sys.version_info >= (3,10) else 1)" >nul 2>>"%LOG_FILE%"
if errorlevel 1 exit /b 0
for /f "delims=" %%P in ('%PY_CMD% -c "import sys; print(sys.executable)" 2^>nul') do call :try_python_file "%%P"
exit /b 0

:try_py_launcher
py -3 -c "import sys; raise SystemExit(0 if sys.version_info >= (3,10) else 1)" >nul 2>>"%LOG_FILE%"
if errorlevel 1 exit /b 0
for /f "delims=" %%P in ('py -3 -c "import sys; print(sys.executable)" 2^>nul') do call :try_python_file "%%P"
exit /b 0

:scan_python_roots
set "PY_ROOT=%~1"
if "%PY_ROOT%"=="" exit /b 0
for %%V in (314 313 312 311 310) do (
  if not defined PYTHON_EXE call :try_python_file "%PY_ROOT%\Python%%V\python.exe"
)
exit /b 0

:bootstrap_python
if exist "%RUNTIME_DIR%\python.exe" exit /b 0
if not exist "%INSTALLER_DIR%" mkdir "%INSTALLER_DIR%" 2>nul
call :find_bundled_embed
if not defined PY_EMBED_ZIP call :download_embed_python
if defined PY_EMBED_ZIP (
  call :extract_embed_python "%PY_EMBED_ZIP%"
  if not errorlevel 1 exit /b 0
)

call :find_bundled_installer
if not defined PY_INSTALLER call :download_python_installer
if defined PY_INSTALLER (
  call :install_local_python "%PY_INSTALLER%"
  if not errorlevel 1 exit /b 0
)
exit /b 1

:find_bundled_embed
set "PY_EMBED_ZIP="
if exist "%INSTALLER_DIR%\python-%PYTHON_VERSION%-embed-amd64.zip" (
  set "PY_EMBED_ZIP=%INSTALLER_DIR%\python-%PYTHON_VERSION%-embed-amd64.zip"
  exit /b 0
)
for /f "delims=" %%I in ('dir /b /a-d "%INSTALLER_DIR%\python-*-embed-amd64.zip" 2^>nul') do (
  if not defined PY_EMBED_ZIP set "PY_EMBED_ZIP=%INSTALLER_DIR%\%%I"
)
exit /b 0

:download_embed_python
set "PY_EMBED_ZIP=%INSTALLER_DIR%\python-%PYTHON_VERSION%-embed-amd64.zip"
echo [DOWNLOAD] Python embeddable runtime
call :download_file "https://registry.npmmirror.com/-/binary/python/%PYTHON_VERSION%/python-%PYTHON_VERSION%-embed-amd64.zip" "%PY_EMBED_ZIP%"
if exist "%PY_EMBED_ZIP%" exit /b 0
call :download_file "https://www.python.org/ftp/python/%PYTHON_VERSION%/python-%PYTHON_VERSION%-embed-amd64.zip" "%PY_EMBED_ZIP%"
if exist "%PY_EMBED_ZIP%" exit /b 0
set "PY_EMBED_ZIP="
exit /b 1

:extract_embed_python
set "EMBED_ZIP=%~1"
if "%EMBED_ZIP%"=="" exit /b 1
if not exist "%EMBED_ZIP%" exit /b 1
echo [INSTALL] Extracting portable Python:
echo           %EMBED_ZIP%
if exist "%RUNTIME_DIR%" rmdir /s /q "%RUNTIME_DIR%" >nul 2>nul
mkdir "%RUNTIME_DIR%" 2>nul
call :extract_zip "%EMBED_ZIP%" "%RUNTIME_DIR%"
if errorlevel 1 exit /b 1
call :configure_embed_runtime
if exist "%RUNTIME_DIR%\python.exe" (
  "%RUNTIME_DIR%\python.exe" -c "import sys, json, zipfile, urllib.request; raise SystemExit(0 if sys.version_info >= (3,10) else 1)" >nul 2>>"%LOG_FILE%"
  if not errorlevel 1 exit /b 0
)
exit /b 1

:configure_embed_runtime
set "PY_ZIP=python311.zip"
for %%Z in ("%RUNTIME_DIR%\python*.zip") do set "PY_ZIP=%%~nxZ"
for %%P in ("%RUNTIME_DIR%\python*._pth") do call :write_pth "%%~fP"
if not exist "%RUNTIME_DIR%\Lib\site-packages" mkdir "%RUNTIME_DIR%\Lib\site-packages" 2>nul
exit /b 0

:write_pth
>"%~1" echo %PY_ZIP%
>>"%~1" echo .
>>"%~1" echo Lib\site-packages
>>"%~1" echo import site
exit /b 0

:find_bundled_installer
set "PY_INSTALLER="
if exist "%INSTALLER_DIR%\python-%PYTHON_VERSION%-amd64.exe" (
  set "PY_INSTALLER=%INSTALLER_DIR%\python-%PYTHON_VERSION%-amd64.exe"
  exit /b 0
)
for /f "delims=" %%I in ('dir /b /a-d "%INSTALLER_DIR%\python-*-amd64.exe" 2^>nul') do (
  if not defined PY_INSTALLER set "PY_INSTALLER=%INSTALLER_DIR%\%%I"
)
exit /b 0

:download_python_installer
set "PY_INSTALLER=%INSTALLER_DIR%\python-%PYTHON_VERSION%-amd64.exe"
echo [DOWNLOAD] Python installer fallback
call :download_file "https://registry.npmmirror.com/-/binary/python/%PYTHON_VERSION%/python-%PYTHON_VERSION%-amd64.exe" "%PY_INSTALLER%"
if exist "%PY_INSTALLER%" exit /b 0
call :download_file "https://www.python.org/ftp/python/%PYTHON_VERSION%/python-%PYTHON_VERSION%-amd64.exe" "%PY_INSTALLER%"
if exist "%PY_INSTALLER%" exit /b 0
set "PY_INSTALLER="
exit /b 1

:install_local_python
set "INSTALLER=%~1"
if "%INSTALLER%"=="" exit /b 1
if not exist "%INSTALLER%" exit /b 1
echo [INSTALL] Installing private Python:
echo           %RUNTIME_DIR%
if not exist "%RUNTIME_DIR%" mkdir "%RUNTIME_DIR%" 2>nul
start /wait "" "%INSTALLER%" /quiet InstallAllUsers=0 TargetDir="%RUNTIME_DIR%" Include_launcher=0 InstallLauncherAllUsers=0 Include_pip=1 Include_tcltk=0 Include_test=0 Include_doc=0 PrependPath=0 Shortcuts=0
if exist "%RUNTIME_DIR%\python.exe" exit /b 0
echo [INFO] Waiting for Python installer to finish writing files.
for /l %%S in (1,1,60) do (
  if exist "%RUNTIME_DIR%\python.exe" exit /b 0
  ping -n 2 127.0.0.1 >nul
)
exit /b 1

:extract_zip
set "ZIP_IN=%~1"
set "ZIP_OUT=%~2"
call :command_exists powershell
if not errorlevel 1 (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "$ProgressPreference='SilentlyContinue'; try { Expand-Archive -LiteralPath '%ZIP_IN%' -DestinationPath '%ZIP_OUT%' -Force; exit 0 } catch { exit 1 }" >>"%LOG_FILE%" 2>&1
  if not errorlevel 1 exit /b 0
)
call :command_exists tar
if not errorlevel 1 (
  tar -xf "%ZIP_IN%" -C "%ZIP_OUT%" >>"%LOG_FILE%" 2>&1
  if not errorlevel 1 exit /b 0
)
exit /b 1

:download_file
set "DL_URL=%~1"
set "DL_OUT=%~2"
if exist "%DL_OUT%" del /f /q "%DL_OUT%" >nul 2>nul
echo [INFO] Downloading. This may take several minutes on slow or restricted networks.
echo [URL] %DL_URL%
echo [OUT] %DL_OUT%
call :command_exists powershell
if not errorlevel 1 (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; $ProgressPreference='Continue'; try { Invoke-WebRequest -UseBasicParsing -Uri '%DL_URL%' -OutFile '%DL_OUT%' -TimeoutSec 240; if (Test-Path -LiteralPath '%DL_OUT%') { $size=(Get-Item -LiteralPath '%DL_OUT%').Length; Write-Host ('[OK] Downloaded {0:N2} MB' -f ($size/1MB)); exit 0 }; exit 1 } catch { Write-Host ('[WARN] Download failed: ' + $_.Exception.Message); exit 1 }" >>"%LOG_FILE%" 2>&1
  if exist "%DL_OUT%" exit /b 0
)
call :command_exists curl
if not errorlevel 1 (
  curl.exe -L --fail --connect-timeout 30 --max-time 240 --progress-bar -o "%DL_OUT%" "%DL_URL%" >>"%LOG_FILE%" 2>&1
  if exist "%DL_OUT%" exit /b 0
)
call :command_exists certutil
if not errorlevel 1 (
  certutil -urlcache -split -f "%DL_URL%" "%DL_OUT%" >>"%LOG_FILE%" 2>&1
  if exist "%DL_OUT%" exit /b 0
)
if exist "%DL_OUT%" del /f /q "%DL_OUT%" >nul 2>nul
exit /b 1

:command_exists
where "%~1" >nul 2>nul
exit /b %errorlevel%
