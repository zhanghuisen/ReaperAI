@echo off
setlocal EnableExtensions EnableDelayedExpansion
chcp 65001 >nul
title ReaperAI v1.0.4 - Install dependencies

set "PYTHON_VERSION=3.11.9"
set "SCRIPT_DIR=%~dp0"
cd /d "%SCRIPT_DIR%" || (
  echo [ERROR] Cannot enter MCP_Server directory.
  pause
  exit /b 1
)

set "RUNTIME_DIR=%SCRIPT_DIR%python_runtime"
set "INSTALLER_DIR=%SCRIPT_DIR%installers"
set "WHEELS_DIR=%SCRIPT_DIR%wheels"
set "BASE_PYTHON="
set "PYTHON_EXE="
set "PYTHONW_EXE="
set "PYTHON_SITE_PACKAGES="
set "CORE_FAILED=0"
set "WHEELS_EXPANDED=0"

echo ============================================
echo   ReaperAI v1.0.4 - Install dependencies
echo ============================================
echo.
echo This script will prepare a local Python runtime for ReaperAI.
echo It will not add Python to the system PATH.
echo.

call :find_python
if not defined BASE_PYTHON (
  echo [INFO] Python 3.10+ was not found on this computer.
  echo [INFO] Trying to install a private Python runtime under:
  echo        %RUNTIME_DIR%
  echo.
  call :bootstrap_python
  call :find_python
)

if not defined BASE_PYTHON (
  echo.
  echo [ERROR] ReaperAI still cannot find Python 3.10+.
  echo.
  echo Offline fallback:
  echo   1. Put python-%PYTHON_VERSION%-embed-amd64.zip into:
  echo      %INSTALLER_DIR%
  echo   2. Run this BAT again.
  echo.
  echo Online fallback:
  echo   Allow PowerShell to download from npmmirror or python.org, then run again.
  echo.
  pause
  exit /b 1
)

call :prepare_venv
if errorlevel 1 (
  pause
  exit /b 1
)

echo [OK] Python: %PYTHON_EXE%
if defined PYTHONW_EXE echo [OK] Pythonw: %PYTHONW_EXE%
echo.

echo [INFO] Installing core dependencies.
call :install_required requests requests
call :install_required flask flask
call :install_required flask-cors flask_cors

if "%CORE_FAILED%"=="1" (
  echo.
  echo [ERROR] Core dependency installation failed.
  echo ReaperAI cannot run until requests, flask and flask-cors are installed.
  echo.
  echo For offline installation, copy wheel files into:
  echo   %WHEELS_DIR%
  echo.
  echo Manual command:
  echo "%PYTHON_EXE%" -m pip install requests flask flask-cors -i https://pypi.tuna.tsinghua.edu.cn/simple
  echo.
  pause
  exit /b 1
)

echo.
if /i "%REAPERAI_SKIP_OPTIONAL%"=="1" (
  echo [INFO] Optional dependency installation skipped by REAPERAI_SKIP_OPTIONAL=1.
) else (
  echo [INFO] Installing optional dependencies.
  call :install_optional numpy numpy "audio loop analysis"
  call :install_optional soundfile soundfile "extra WAV format support"
)
call :check_ffmpeg

echo.
echo ============================================
echo   Install complete
echo ============================================
echo [OK] HTTP Worker: ready
echo [OK] MCP Server: ready
echo.
echo If REAPER is already open, restart ReaperAI before testing again.
echo.
pause
exit /b 0

:find_python
set "BASE_PYTHON="
call :try_python_file "%SCRIPT_DIR%.venv\Scripts\python.exe"
if defined BASE_PYTHON exit /b 0
call :try_python_file "%RUNTIME_DIR%\python.exe"
if defined BASE_PYTHON exit /b 0
call :try_python_file "%SCRIPT_DIR%.python\python.exe"
if defined BASE_PYTHON exit /b 0
call :try_python_command python
if defined BASE_PYTHON exit /b 0
call :try_python_command python3
if defined BASE_PYTHON exit /b 0
call :try_py_launcher
if defined BASE_PYTHON exit /b 0
call :scan_python_roots "%LOCALAPPDATA%\Programs\Python"
if defined BASE_PYTHON exit /b 0
call :scan_python_roots "%USERPROFILE%\AppData\Local\Programs\Python"
if defined BASE_PYTHON exit /b 0
call :scan_program_files "%ProgramFiles%"
if defined BASE_PYTHON exit /b 0
call :scan_program_files "%ProgramFiles(x86)%"
exit /b 0

:try_python_command
set "PY_CMD=%~1"
if "%PY_CMD%"=="" exit /b 0
%PY_CMD% -c "import sys; raise SystemExit(0 if sys.version_info >= (3,10) else 1)" >nul 2>nul
if errorlevel 1 exit /b 0
for /f "delims=" %%P in ('%PY_CMD% -c "import sys; print(sys.executable)" 2^>nul') do set "BASE_PYTHON=%%P"
exit /b 0

:try_py_launcher
py -3 -c "import sys; raise SystemExit(0 if sys.version_info >= (3,10) else 1)" >nul 2>nul
if errorlevel 1 exit /b 0
for /f "delims=" %%P in ('py -3 -c "import sys; print(sys.executable)" 2^>nul') do set "BASE_PYTHON=%%P"
exit /b 0

:try_python_file
set "PY_CAND=%~1"
if "%PY_CAND%"=="" exit /b 0
if not exist "%PY_CAND%" exit /b 0
"%PY_CAND%" -c "import sys; raise SystemExit(0 if sys.version_info >= (3,10) else 1)" >nul 2>nul
if errorlevel 1 exit /b 0
set "BASE_PYTHON=%PY_CAND%"
exit /b 0

:scan_python_roots
set "PY_ROOT=%~1"
if "%PY_ROOT%"=="" exit /b 0
for %%V in (314 313 312 311 310) do (
  if not defined BASE_PYTHON call :try_python_file "%PY_ROOT%\Python%%V\python.exe"
)
exit /b 0

:scan_program_files
set "PY_ROOT=%~1"
if "%PY_ROOT%"=="" exit /b 0
for %%V in (314 313 312 311 310) do (
  if not defined BASE_PYTHON call :try_python_file "%PY_ROOT%\Python%%V\python.exe"
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
if not defined PY_INSTALLER exit /b 1
call :install_local_python "%PY_INSTALLER%"
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
echo [TRY] https://registry.npmmirror.com/-/binary/python/%PYTHON_VERSION%/
call :download_file "https://registry.npmmirror.com/-/binary/python/%PYTHON_VERSION%/python-%PYTHON_VERSION%-embed-amd64.zip" "%PY_EMBED_ZIP%"
if exist "%PY_EMBED_ZIP%" exit /b 0
echo [TRY] https://www.python.org/ftp/python/%PYTHON_VERSION%/
call :download_file "https://www.python.org/ftp/python/%PYTHON_VERSION%/python-%PYTHON_VERSION%-embed-amd64.zip" "%PY_EMBED_ZIP%"
if exist "%PY_EMBED_ZIP%" exit /b 0
set "PY_EMBED_ZIP="
exit /b 1

:extract_embed_python
set "EMBED_ZIP=%~1"
if "%EMBED_ZIP%"=="" exit /b 1
if not exist "%EMBED_ZIP%" exit /b 1
echo [INSTALL] Portable Python runtime
echo [INFO] Zip: %EMBED_ZIP%
echo [INFO] Target: %RUNTIME_DIR%
if exist "%RUNTIME_DIR%\python.exe" exit /b 0
if exist "%RUNTIME_DIR%" rmdir /s /q "%RUNTIME_DIR%" >nul 2>nul
mkdir "%RUNTIME_DIR%" 2>nul
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ProgressPreference='SilentlyContinue'; try { Expand-Archive -LiteralPath '%EMBED_ZIP%' -DestinationPath '%RUNTIME_DIR%' -Force; exit 0 } catch { exit 1 }"
if errorlevel 1 exit /b 1
call :configure_embed_runtime
if exist "%RUNTIME_DIR%\python.exe" (
  "%RUNTIME_DIR%\python.exe" -c "import sys; raise SystemExit(0 if sys.version_info >= (3,10) else 1)" >nul 2>nul
  if not errorlevel 1 (
    echo [OK] Portable Python runtime installed
    exit /b 0
  )
)
echo [ERROR] Portable Python runtime is not usable.
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
echo [DOWNLOAD] Python installer
echo [TRY] https://registry.npmmirror.com/-/binary/python/%PYTHON_VERSION%/
call :download_file "https://registry.npmmirror.com/-/binary/python/%PYTHON_VERSION%/python-%PYTHON_VERSION%-amd64.exe" "%PY_INSTALLER%"
if exist "%PY_INSTALLER%" exit /b 0
echo [TRY] https://www.python.org/ftp/python/%PYTHON_VERSION%/
call :download_file "https://www.python.org/ftp/python/%PYTHON_VERSION%/python-%PYTHON_VERSION%-amd64.exe" "%PY_INSTALLER%"
if exist "%PY_INSTALLER%" exit /b 0
set "PY_INSTALLER="
exit /b 1

:download_file
set "DL_URL=%~1"
set "DL_OUT=%~2"
if exist "%DL_OUT%" del /f /q "%DL_OUT%" >nul 2>nul
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ProgressPreference='SilentlyContinue'; [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; try { Invoke-WebRequest -UseBasicParsing -Uri '%DL_URL%' -OutFile '%DL_OUT%' -TimeoutSec 240; exit 0 } catch { exit 1 }"
if errorlevel 1 (
  if exist "%DL_OUT%" del /f /q "%DL_OUT%" >nul 2>nul
  exit /b 1
)
exit /b 0

:install_local_python
set "INSTALLER=%~1"
if "%INSTALLER%"=="" exit /b 1
if not exist "%INSTALLER%" exit /b 1
echo [INSTALL] Local Python runtime
echo [INFO] Installer: %INSTALLER%
echo [INFO] Target: %RUNTIME_DIR%
if not exist "%RUNTIME_DIR%" mkdir "%RUNTIME_DIR%" 2>nul
start /wait "" "%INSTALLER%" /quiet InstallAllUsers=0 TargetDir="%RUNTIME_DIR%" Include_launcher=0 InstallLauncherAllUsers=0 Include_pip=1 Include_tcltk=0 Include_test=0 Include_doc=0 PrependPath=0 Shortcuts=0
set "INSTALL_RC=%errorlevel%"
if exist "%RUNTIME_DIR%\python.exe" (
  echo [OK] Local Python runtime installed
  exit /b 0
)
echo [INFO] Waiting for Python installer to finish writing files.
for /l %%S in (1,1,60) do (
  if exist "%RUNTIME_DIR%\python.exe" (
    echo [OK] Local Python runtime installed
    exit /b 0
  )
  ping -n 2 127.0.0.1 >nul
)
echo [ERROR] Local Python installer did not create python.exe. Exit code: %INSTALL_RC%
exit /b 1

:prepare_venv
echo [INFO] Base Python: %BASE_PYTHON%
if /i "%BASE_PYTHON%"=="%RUNTIME_DIR%\python.exe" (
  call :prepare_portable_runtime
  exit /b %errorlevel%
)
if not exist "%SCRIPT_DIR%.venv\Scripts\python.exe" (
  echo [INFO] Creating local virtual environment.
  "%BASE_PYTHON%" -m venv "%SCRIPT_DIR%.venv"
)
if not exist "%SCRIPT_DIR%.venv\Scripts\python.exe" (
  echo [ERROR] Failed to create .venv under MCP_Server.
  echo Please rerun this BAT. If it still fails, delete MCP_Server\.venv and run again.
  exit /b 1
)
set "PYTHON_EXE=%SCRIPT_DIR%.venv\Scripts\python.exe"
set "PYTHON_SITE_PACKAGES=%SCRIPT_DIR%.venv\Lib\site-packages"
if exist "%SCRIPT_DIR%.venv\Scripts\pythonw.exe" (
  set "PYTHONW_EXE=%SCRIPT_DIR%.venv\Scripts\pythonw.exe"
) else (
  set "PYTHONW_EXE=%PYTHON_EXE%"
)
"%PYTHON_EXE%" -m ensurepip --upgrade >nul 2>nul
"%PYTHON_EXE%" -m pip --version >nul 2>nul
if errorlevel 1 (
  echo [ERROR] pip is not available in .venv.
  echo Please delete MCP_Server\.venv and run this BAT again.
  exit /b 1
)
>"%SCRIPT_DIR%python_path.txt" echo %PYTHON_EXE%
>"%SCRIPT_DIR%pythonw_path.txt" echo %PYTHONW_EXE%
exit /b 0

:prepare_portable_runtime
echo [INFO] Using portable Python runtime.
call :configure_embed_runtime
set "PYTHON_EXE=%RUNTIME_DIR%\python.exe"
if exist "%RUNTIME_DIR%\pythonw.exe" (
  set "PYTHONW_EXE=%RUNTIME_DIR%\pythonw.exe"
) else (
  set "PYTHONW_EXE=%PYTHON_EXE%"
)
set "PYTHON_SITE_PACKAGES=%RUNTIME_DIR%\Lib\site-packages"
>"%SCRIPT_DIR%python_path.txt" echo %PYTHON_EXE%
>"%SCRIPT_DIR%pythonw_path.txt" echo %PYTHONW_EXE%
exit /b 0

:check_import
set "MODULE_NAME=%~1"
"%PYTHON_EXE%" -c "import %MODULE_NAME%" >nul 2>nul
exit /b %errorlevel%

:install_required
set "PKG_NAME=%~1"
set "MODULE_NAME=%~2"
call :check_import "%MODULE_NAME%"
if not errorlevel 1 (
  echo [OK] %PKG_NAME% already installed
  exit /b 0
)
echo [INSTALL] %PKG_NAME%
call :install_package "%PKG_NAME%"
call :check_import "%MODULE_NAME%"
if errorlevel 1 (
  echo [ERROR] %PKG_NAME% install failed
  set "CORE_FAILED=1"
) else (
  echo [OK] %PKG_NAME% installed
)
exit /b 0

:install_optional
set "PKG_NAME=%~1"
set "MODULE_NAME=%~2"
set "FEATURE_NAME=%~3"
call :check_import "%MODULE_NAME%"
if not errorlevel 1 (
  echo [OK] %PKG_NAME% already installed
  exit /b 0
)
echo [OPTIONAL] %PKG_NAME% for %FEATURE_NAME%
call :install_package "%PKG_NAME%"
call :check_import "%MODULE_NAME%"
if errorlevel 1 (
  echo [WARN] %PKG_NAME% not installed. %FEATURE_NAME% may be limited.
) else (
  echo [OK] %PKG_NAME% installed
)
exit /b 0

:install_package
set "PKG_NAME=%~1"
if exist "%WHEELS_DIR%" (
  echo [TRY] local wheels
  call :expand_local_wheels
  if not errorlevel 1 exit /b 0
  "%PYTHON_EXE%" -m pip install "%PKG_NAME%" --no-index --find-links "%WHEELS_DIR%" --retries 1 --timeout 30
  if not errorlevel 1 exit /b 0
)

call :pip_install "%PKG_NAME%" ""
if not errorlevel 1 exit /b 0
call :pip_install "%PKG_NAME%" "https://pypi.tuna.tsinghua.edu.cn/simple" "pypi.tuna.tsinghua.edu.cn"
if not errorlevel 1 exit /b 0
call :pip_install "%PKG_NAME%" "https://mirrors.aliyun.com/pypi/simple" "mirrors.aliyun.com"
if not errorlevel 1 exit /b 0
call :pip_install "%PKG_NAME%" "https://mirrors.cloud.tencent.com/pypi/simple" "mirrors.cloud.tencent.com"
if not errorlevel 1 exit /b 0
call :pip_install "%PKG_NAME%" "https://pypi.mirrors.ustc.edu.cn/simple" "pypi.mirrors.ustc.edu.cn"
if not errorlevel 1 exit /b 0
call :pip_install "%PKG_NAME%" "https://pypi.doubanio.com/simple" "pypi.doubanio.com"
if not errorlevel 1 exit /b 0
exit /b 1

:expand_local_wheels
if "%WHEELS_EXPANDED%"=="1" exit /b 0
if not defined PYTHON_SITE_PACKAGES exit /b 1
dir /b "%WHEELS_DIR%\*.whl" >nul 2>nul
if errorlevel 1 exit /b 1
if not exist "%PYTHON_SITE_PACKAGES%" mkdir "%PYTHON_SITE_PACKAGES%" 2>nul
for %%W in ("%WHEELS_DIR%\*.whl") do (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "$ProgressPreference='SilentlyContinue'; try { Add-Type -AssemblyName System.IO.Compression.FileSystem; $dest='%PYTHON_SITE_PACKAGES%'; $zip=[System.IO.Compression.ZipFile]::OpenRead('%%~fW'); try { foreach ($entry in $zip.Entries) { if ($entry.FullName.EndsWith('/')) { continue }; $target=Join-Path $dest $entry.FullName; $dir=Split-Path -Parent $target; if ($dir) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }; [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true) } } finally { $zip.Dispose() }; exit 0 } catch { exit 1 }"
  if errorlevel 1 exit /b 1
)
set "WHEELS_EXPANDED=1"
exit /b 0

:pip_install
set "PKG_NAME=%~1"
set "INDEX_URL=%~2"
set "TRUST_HOST=%~3"
if "%INDEX_URL%"=="" (
  echo [TRY] PyPI official
  "%PYTHON_EXE%" -m pip install "%PKG_NAME%" --upgrade --retries 2 --timeout 45
  exit /b %errorlevel%
)
echo [TRY] %INDEX_URL%
"%PYTHON_EXE%" -m pip install "%PKG_NAME%" --upgrade -i "%INDEX_URL%" --trusted-host "%TRUST_HOST%" --retries 2 --timeout 45
exit /b %errorlevel%

:check_ffmpeg
echo.
echo [CHECK] FFmpeg
if exist "%SCRIPT_DIR%tools\ffmpeg\bin\ffmpeg.exe" (
  echo [OK] FFmpeg found in MCP_Server tools
  exit /b 0
)
ffmpeg -version >nul 2>nul
if not errorlevel 1 (
  echo [OK] FFmpeg found in system PATH
  exit /b 0
)
echo [WARN] FFmpeg not found.
echo ElevenLabs audio conversion may be limited.
echo To enable it offline, put ffmpeg.exe under:
echo %SCRIPT_DIR%tools\ffmpeg\bin\ffmpeg.exe
exit /b 0
