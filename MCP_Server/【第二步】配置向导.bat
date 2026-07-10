@echo off
setlocal EnableExtensions EnableDelayedExpansion
title ReaperAI v1.0.3 - Config Wizard

set "PYTHON_VERSION=3.11.9"
set "SCRIPT_DIR=%~dp0"
cd /d "%SCRIPT_DIR%" || (
  echo [ERROR] Cannot enter MCP_Server directory.
  pause
  exit /b 1
)

set "RUNTIME_DIR=%SCRIPT_DIR%python_runtime"
set "INSTALLER_DIR=%SCRIPT_DIR%installers"
set "HELPER=%SCRIPT_DIR%config_wizard_helper.py"
set "CONFIG_FILE=%SCRIPT_DIR%config.json"
set "LOG_FILE=%SCRIPT_DIR%config_wizard_last_error.log"
set "PYTHON_EXE="
set "PYTHONW_EXE="
set "BASE_PYTHON="

if exist "%LOG_FILE%" del /f /q "%LOG_FILE%" >nul 2>nul

echo ============================================
echo   ReaperAI v1.0.3 - Config Wizard
echo ============================================
echo.
echo This wizard creates config.json for ReaperAI.
echo It uses the bundled portable Python first, so system Python is not required.
echo.

if not exist "%HELPER%" (
  echo [ERROR] Missing helper:
  echo        %HELPER%
  echo Please re-extract the full package or restore this file to MCP_Server.
  pause
  exit /b 1
)

if exist "%CONFIG_FILE%" (
  echo [INFO] Existing config file found:
  echo        %CONFIG_FILE%
  set /p overwrite="Overwrite it? (y/n): "
  if /i "!overwrite!"=="n" (
    echo [CANCEL] Config was not changed.
    pause
    exit /b 0
  )
  if /i "!overwrite!"=="y" (
    echo [OK] Existing config will be overwritten.
  ) else (
    echo [ERROR] Invalid input. Config was not changed.
    pause
    exit /b 0
  )
  echo.
)

echo [1/4] REAPER project scan directory
echo       ReaperAI searches .rpp project files under this directory.
echo       Example: E:/ or D:/MyProjects
echo.
set /p projects_dir="Scan directory (default E:/): "
if "%projects_dir%"=="" set "projects_dir=E:/"
call :normalize_input_path projects_dir
echo.

echo [2/4] REAPER resource path
echo       Leave blank to auto-detect, or enter a path like:
echo       C:/Users/YourName/AppData/Roaming/REAPER
echo.
set /p resource_path="Resource path (blank = auto detect): "
call :normalize_input_path resource_path
echo.

echo [3/4] Server port
echo       Default is 8765. Keep it unless there is a port conflict.
echo.
set /p port="Port (default 8765): "
if "%port%"=="" set "port=8765"
call :validate_port "%port%"
if errorlevel 1 (
  echo [WARN] Invalid port. Using default port 8765.
  set "port=8765"
)
echo.

call :ensure_python
if errorlevel 1 (
  echo.
  echo [ERROR] Failed to prepare Python runtime.
  echo.
  echo Offline fallback:
  echo   Make sure this file exists:
  echo   %INSTALLER_DIR%\python-%PYTHON_VERSION%-embed-amd64.zip
  echo.
  echo You can also run the Step 1 dependency installer first, then run this wizard again.
  echo.
  if exist "%LOG_FILE%" echo Detail log: %LOG_FILE%
  pause
  exit /b 1
)

echo [OK] Python: %PYTHON_EXE%
echo.

echo [WRITE] Creating config files...
echo.
set "REAPERAI_CW_PROJECTS_DIR=%projects_dir%"
set "REAPERAI_CW_RESOURCE_PATH=%resource_path%"
set "REAPERAI_CW_PORT=%port%"
"%PYTHON_EXE%" "%HELPER%" write_config_env "%CONFIG_FILE%" >>"%LOG_FILE%" 2>&1
if errorlevel 1 (
  echo [ERROR] Failed to create config.json.
  if exist "%LOG_FILE%" echo Detail log: %LOG_FILE%
  pause
  exit /b 1
)

if not "%resource_path%"=="" (
  set "LUA_CONFIG=%resource_path%\ReaperAI_config.txt"
) else (
  for /f "delims=" %%A in ('""%PYTHON_EXE%" "%HELPER%" detect_reaper_resource" 2^>nul') do set "REAPER_RES_PATH=%%A"
  if "!REAPER_RES_PATH!"=="" set "REAPER_RES_PATH=%APPDATA%\REAPER"
  set "LUA_CONFIG=!REAPER_RES_PATH!\ReaperAI_config.txt"
)

"%PYTHON_EXE%" "%HELPER%" write_lua_config "%LUA_CONFIG%" >>"%LOG_FILE%" 2>&1
if errorlevel 1 (
  echo [ERROR] Failed to create Lua config:
  echo        %LUA_CONFIG%
  if exist "%LOG_FILE%" echo Detail log: %LOG_FILE%
  pause
  exit /b 1
)

echo [OK] Config file: %CONFIG_FILE%
echo [OK] Lua config: %LUA_CONFIG%
echo.

echo [4/4] Checking FFmpeg...
echo.
set "FFMPEG_DIR=%SCRIPT_DIR%tools\ffmpeg"
set "FFMPEG_EXE=%FFMPEG_DIR%\bin\ffmpeg.exe"

if exist "%FFMPEG_EXE%" (
  echo [OK] Bundled FFmpeg found:
  echo      %FFMPEG_EXE%
  call :update_ffmpeg_path "%FFMPEG_EXE%"
  goto :ffmpeg_done
)

call :find_system_ffmpeg
if defined SYSTEM_FFMPEG (
  echo [OK] System FFmpeg found:
  echo      %SYSTEM_FFMPEG%
  call :update_ffmpeg_path "%SYSTEM_FFMPEG%"
  goto :ffmpeg_done
)

echo [INFO] FFmpeg was not found. Downloading automatically...
echo       FFmpeg is used for audio conversion, for example MP3 to WAV.
echo.

set "FFMPEG_ZIP=%TEMP%\reaperai_ffmpeg_essentials.zip"
if exist "%FFMPEG_ZIP%" del /f /q "%FFMPEG_ZIP%" >nul 2>nul

call :download_ffmpeg "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip"
if errorlevel 1 (
  echo [WARN] Primary FFmpeg source failed. Trying backup source.
  call :download_ffmpeg "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip"
)

if not exist "%FFMPEG_ZIP%" (
  echo [WARN] FFmpeg download failed. You can install it manually later.
  echo       1. Download ffmpeg-release-essentials.zip
  echo       2. Extract it to: %FFMPEG_DIR%
  echo       3. Make sure this file exists: %FFMPEG_EXE%
  echo.
  goto :ffmpeg_done
)

echo [INSTALL] Extracting FFmpeg...
"%PYTHON_EXE%" "%HELPER%" install_ffmpeg "%FFMPEG_ZIP%" "%FFMPEG_DIR%" >>"%LOG_FILE%" 2>&1
if errorlevel 1 (
  echo [WARN] FFmpeg extraction failed. You can install it manually later.
  if exist "%LOG_FILE%" echo Detail log: %LOG_FILE%
  goto :ffmpeg_done
)

if exist "%FFMPEG_EXE%" (
  echo [OK] FFmpeg installed:
  echo      %FFMPEG_EXE%
  call :update_ffmpeg_path "%FFMPEG_EXE%"
)

del /f /q "%FFMPEG_ZIP%" >nul 2>nul

:ffmpeg_done
echo.
echo ============================================
echo   Config complete
echo ============================================
echo.
echo Config summary:
echo   Projects dir: %projects_dir%
echo   Resource path: %resource_path%
echo   Port: %port%
echo.
pause
exit /b 0

:ensure_python
echo [CHECK] Preparing local Python runtime...
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
for /f "delims=" %%P in ('%PY_CMD% -c "import sys; print(sys.executable)" 2^>nul') do set "PYTHON_EXE=%%P"
exit /b 0

:try_py_launcher
py -3 -c "import sys; raise SystemExit(0 if sys.version_info >= (3,10) else 1)" >nul 2>>"%LOG_FILE%"
if errorlevel 1 exit /b 0
for /f "delims=" %%P in ('py -3 -c "import sys; print(sys.executable)" 2^>nul') do set "PYTHON_EXE=%%P"
exit /b 0

:bootstrap_python
if exist "%RUNTIME_DIR%\python.exe" exit /b 0
if not exist "%INSTALLER_DIR%" mkdir "%INSTALLER_DIR%" 2>nul
call :find_bundled_embed
if not defined PY_EMBED_ZIP call :download_embed_python
if not defined PY_EMBED_ZIP exit /b 1
call :extract_embed_python "%PY_EMBED_ZIP%"
exit /b %errorlevel%

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
for %%P in ("%RUNTIME_DIR%\python*._pth") do (
  >"%%~fP" echo !PY_ZIP!
  >>"%%~fP" echo .
  >>"%%~fP" echo Lib\site-packages
  >>"%%~fP" echo import site
)
if not exist "%RUNTIME_DIR%\Lib\site-packages" mkdir "%RUNTIME_DIR%\Lib\site-packages" 2>nul
exit /b 0

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
call :command_exists powershell
if not errorlevel 1 (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "$ProgressPreference='SilentlyContinue'; [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; try { Invoke-WebRequest -UseBasicParsing -Uri '%DL_URL%' -OutFile '%DL_OUT%' -TimeoutSec 240; exit 0 } catch { exit 1 }" >>"%LOG_FILE%" 2>&1
  if exist "%DL_OUT%" exit /b 0
)
call :command_exists curl
if not errorlevel 1 (
  curl.exe -L --fail --connect-timeout 30 --max-time 240 -o "%DL_OUT%" "%DL_URL%" >>"%LOG_FILE%" 2>&1
  if exist "%DL_OUT%" exit /b 0
)
call :command_exists certutil
if not errorlevel 1 (
  certutil -urlcache -split -f "%DL_URL%" "%DL_OUT%" >>"%LOG_FILE%" 2>&1
  if exist "%DL_OUT%" exit /b 0
)
exit /b 1

:download_ffmpeg
set "DL_URL=%~1"
"%PYTHON_EXE%" "%HELPER%" download "%DL_URL%" "%FFMPEG_ZIP%" >>"%LOG_FILE%" 2>&1
if exist "%FFMPEG_ZIP%" exit /b 0
call :download_file "%DL_URL%" "%FFMPEG_ZIP%"
if exist "%FFMPEG_ZIP%" exit /b 0
exit /b 1

:find_system_ffmpeg
set "SYSTEM_FFMPEG="
for /f "delims=" %%F in ('where ffmpeg 2^>nul') do (
  if not defined SYSTEM_FFMPEG set "SYSTEM_FFMPEG=%%F"
)
exit /b 0

:update_ffmpeg_path
set "FFMPEG_PATH_TO_SAVE=%~1"
if "%FFMPEG_PATH_TO_SAVE%"=="" exit /b 0
"%PYTHON_EXE%" "%HELPER%" set_ffmpeg_path "%CONFIG_FILE%" "%FFMPEG_PATH_TO_SAVE%" >>"%LOG_FILE%" 2>&1
if errorlevel 1 (
  echo [WARN] Failed to write ffmpeg_path. You can fill it manually later.
  if exist "%LOG_FILE%" echo Detail log: %LOG_FILE%
)
exit /b 0

:validate_port
set "PORT_TO_CHECK=%~1"
if "%PORT_TO_CHECK%"=="" exit /b 1
for /f "delims=0123456789" %%N in ("%PORT_TO_CHECK%") do exit /b 1
set /a PORT_NUM=%PORT_TO_CHECK% >nul 2>nul
if errorlevel 1 exit /b 1
if %PORT_NUM% LSS 1 exit /b 1
if %PORT_NUM% GTR 65535 exit /b 1
exit /b 0

:command_exists
where "%~1" >nul 2>nul
exit /b %errorlevel%

:normalize_input_path
set "VAR_NAME=%~1"
if "%VAR_NAME%"=="" exit /b 0
set "RAW_PATH="
call set "RAW_PATH=%%%VAR_NAME%%%"
if not defined RAW_PATH exit /b 0
set "RAW_PATH=!RAW_PATH:"=!"
set "RAW_PATH=!RAW_PATH:/=\!"
if not "!RAW_PATH!"=="" if "!RAW_PATH:~-1!"=="\" if not "!RAW_PATH:~1,2!"==":\" set "RAW_PATH=!RAW_PATH:~0,-1!"
set "%VAR_NAME%=!RAW_PATH!"
exit /b 0
