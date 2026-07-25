[CmdletBinding()]
param(
    [string]$ProjectRoot = "",
    [string]$FFmpegBinRoot = "",
    [string]$IsccPath = "",
    [switch]$SkipCompile
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if (-not $ProjectRoot) {
    $ProjectRoot = Split-Path -Parent $PSScriptRoot
}
$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
if (-not $FFmpegBinRoot) {
    $FFmpegBinRoot = Join-Path $ProjectRoot "MCP_Server\ffmpeg\bin"
}
$FFmpegBinRoot = [System.IO.Path]::GetFullPath($FFmpegBinRoot)
$BuildRoot = Join-Path $PSScriptRoot "build"
$PackageRoot = Join-Path $BuildRoot "package"
$OutputRoot = Join-Path $PSScriptRoot "output"

function Remove-SafeDirectory {
    param([Parameter(Mandatory)][string]$Path)

    $installerRoot = [System.IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
    $target = [System.IO.Path]::GetFullPath($Path)
    if (-not $target.StartsWith($installerRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove a directory outside Installer: $target"
    }
    if (Test-Path -LiteralPath $target) {
        Remove-Item -LiteralPath $target -Recurse -Force
    }
}

function Copy-RequiredFile {
    param([Parameter(Mandatory)][string]$RelativePath)

    $source = Join-Path $ProjectRoot $RelativePath
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Required file is missing: $source"
    }
    $destination = Join-Path $PackageRoot $RelativePath
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    Copy-Item -LiteralPath $source -Destination $destination -Force
}

function Copy-RequiredDirectory {
    param([Parameter(Mandatory)][string]$RelativePath)

    $source = Join-Path $ProjectRoot $RelativePath
    if (-not (Test-Path -LiteralPath $source -PathType Container)) {
        throw "Required directory is missing: $source"
    }
    $destination = Join-Path $PackageRoot $RelativePath
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    Copy-Item -LiteralPath $source -Destination $destination -Recurse -Force
}

function Resolve-IsccPath {
    param([string]$RequestedPath)

    $candidates = @(
        $RequestedPath,
        (Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6\ISCC.exe"),
        (Join-Path $env:ProgramFiles "Inno Setup 6\ISCC.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\Inno Setup 6\ISCC.exe")
    ) | Where-Object { $_ }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
    }

    $command = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }
    throw "Inno Setup 6 was not found. Install it with: winget install --id JRSoftware.InnoSetup -e"
}

Write-Host "[1/6] Preparing a clean staging area..."
Remove-SafeDirectory -Path $BuildRoot
Remove-SafeDirectory -Path $OutputRoot
New-Item -ItemType Directory -Path $PackageRoot, $OutputRoot -Force | Out-Null

Write-Host "[2/6] Copying ReaperAI files from the explicit package manifest..."
$requiredFiles = @(
    "Scripts\ReaperAI.lua",
    "Scripts\rai_async_pipe.lua",
    "Scripts\ReaperAI_mcp_config.json",
    "MCP_Server\config_wizard_helper.py",
    "MCP_Server\http_server_v2.py",
    "MCP_Server\launch_http_server.py",
    "MCP_Server\launch_rai_worker.py",
    "MCP_Server\mcp_http_bridge.py",
    "MCP_Server\probe_http_server.py",
    "MCP_Server\rai_http_worker_v2.py",
    "MCP_Server\shutdown_http_server.py"
)
foreach ($relativePath in $requiredFiles) {
    Copy-RequiredFile -RelativePath $relativePath
}

Copy-RequiredDirectory -RelativePath "Scripts\ReaperAI"
Copy-RequiredDirectory -RelativePath "MCP_Server\src"
Copy-RequiredDirectory -RelativePath "UserPlugins"

Get-ChildItem -LiteralPath $PackageRoot -Recurse -Directory -Filter "__pycache__" |
    Sort-Object FullName -Descending |
    ForEach-Object { Remove-SafeDirectory -Path $_.FullName }
Get-ChildItem -LiteralPath $PackageRoot -Recurse -File |
    Where-Object { $_.Extension -in @(".pyc", ".pyo") } |
    Remove-Item -Force

foreach ($optionalFile in @("README.md", "LICENSE", "EULA.txt")) {
    if (Test-Path -LiteralPath (Join-Path $ProjectRoot $optionalFile) -PathType Leaf) {
        Copy-RequiredFile -RelativePath $optionalFile
    }
}

foreach ($relativePath in $requiredFiles) {
    $stagedFile = Join-Path $PackageRoot $relativePath
    if (-not (Test-Path -LiteralPath $stagedFile -PathType Leaf)) {
        throw "Manifest copy failed to stage: $relativePath"
    }
}
foreach ($relativePath in @("Scripts\ReaperAI", "MCP_Server\src", "UserPlugins")) {
    $stagedDirectory = Join-Path $PackageRoot $relativePath
    if (@(Get-ChildItem -LiteralPath $stagedDirectory -Recurse -File).Count -eq 0) {
        throw "Manifest copy produced an empty directory: $relativePath"
    }
}

Write-Host "[3/6] Building the embedded Python 3.11 runtime..."
$pythonArchive = Join-Path $ProjectRoot "MCP_Server\installers\python-3.11.9-embed-amd64.zip"
$wheelsRoot = Join-Path $ProjectRoot "MCP_Server\wheels"
if (-not (Test-Path -LiteralPath $pythonArchive -PathType Leaf)) {
    throw "Bundled Python archive is missing: $pythonArchive"
}
if (-not (Test-Path -LiteralPath $wheelsRoot -PathType Container)) {
    throw "Offline wheels directory is missing: $wheelsRoot"
}

$runtimeRoot = Join-Path $PackageRoot "MCP_Server\python_runtime"
Expand-Archive -LiteralPath $pythonArchive -DestinationPath $runtimeRoot -Force
$sitePackages = Join-Path $runtimeRoot "Lib\site-packages"
New-Item -ItemType Directory -Path $sitePackages -Force | Out-Null

$pthContent = @("python311.zip", ".", "Lib\site-packages", "import site") -join "`r`n"
[System.IO.File]::WriteAllText(
    (Join-Path $runtimeRoot "python311._pth"),
    $pthContent + "`r`n",
    [System.Text.Encoding]::ASCII
)

$wheelFiles = @(Get-ChildItem -LiteralPath $wheelsRoot -Filter "*.whl" -File)
if ($wheelFiles.Count -eq 0) {
    throw "No offline wheel packages were found in: $wheelsRoot"
}

$pythonExe = Join-Path $runtimeRoot "python.exe"
$installWheelCode = @'
import pathlib
import shutil
import sys
import zipfile

wheel_root = pathlib.Path(sys.argv[1])
site_packages = pathlib.Path(sys.argv[2])
for wheel in sorted(wheel_root.glob('*.whl')):
    print(f'  extracting {wheel.name}')
    with zipfile.ZipFile(wheel) as archive:
        archive.extractall(site_packages)
    data_roots = list(site_packages.glob('*.data'))
    for data_root in data_roots:
        for category in ('purelib', 'platlib'):
            source = data_root / category
            if source.is_dir():
                shutil.copytree(source, site_packages, dirs_exist_ok=True)
        shutil.rmtree(data_root)
'@
& $pythonExe -c $installWheelCode $wheelsRoot $sitePackages
if ($LASTEXITCODE -ne 0) {
    throw "Failed to expand the bundled wheel packages."
}

Write-Host "[4/6] Adding the bundled FFmpeg executable..."
$ffmpegSource = Join-Path $FFmpegBinRoot "ffmpeg.exe"
$ffprobeSource = Join-Path $FFmpegBinRoot "ffprobe.exe"
if (-not (Test-Path -LiteralPath $ffmpegSource -PathType Leaf)) {
    throw "Bundled FFmpeg is missing: $ffmpegSource"
}
if (-not (Test-Path -LiteralPath $ffprobeSource -PathType Leaf)) {
    throw "Bundled FFprobe is missing: $ffprobeSource"
}
$ffmpegDestination = Join-Path $PackageRoot "MCP_Server\ffmpeg\bin\ffmpeg.exe"
$ffprobeDestination = Join-Path $PackageRoot "MCP_Server\ffmpeg\bin\ffprobe.exe"
New-Item -ItemType Directory -Path (Split-Path -Parent $ffmpegDestination) -Force | Out-Null
Copy-Item -LiteralPath $ffmpegSource -Destination $ffmpegDestination -Force
Copy-Item -LiteralPath $ffprobeSource -Destination $ffprobeDestination -Force

$siteCustomizePath = Join-Path $sitePackages "sitecustomize.py"
$siteCustomizeCode = @'
import os

_mcp_server = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(__file__))))
_ffmpeg_bin = os.path.join(_mcp_server, 'ffmpeg', 'bin')
if os.path.isfile(os.path.join(_ffmpeg_bin, 'ffmpeg.exe')):
    os.environ['PATH'] = _ffmpeg_bin + os.pathsep + os.environ.get('PATH', '')
'@
[System.IO.File]::WriteAllText(
    $siteCustomizePath,
    $siteCustomizeCode + "`n",
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host "[5/6] Running dependency and package-integrity checks..."
$env:PYTHONDONTWRITEBYTECODE = "1"
& $pythonExe -c "import requests, flask, flask_cors, numpy, soundfile, pydub, cffi; from pydub.utils import which; assert which('ffmpeg') and which('ffprobe'); print('  Python dependency check OK')"
if ($LASTEXITCODE -ne 0) {
    throw "The staged Python runtime failed its dependency import check."
}
& $ffmpegDestination -version *> $null
if ($LASTEXITCODE -ne 0) {
    throw "The staged FFmpeg executable failed its version check."
}
Write-Host "  FFmpeg check OK"
& $ffprobeDestination -version *> $null
if ($LASTEXITCODE -ne 0) {
    throw "The staged FFprobe executable failed its version check."
}
Write-Host "  FFprobe check OK"

$forbiddenNames = @(
    ".venv", "config.json", "python_path.txt", "pythonw_path.txt",
    "ffmpeg_path.txt", "rai_worker_status.json", "__pycache__"
)
$forbiddenItems = @(Get-ChildItem -LiteralPath $PackageRoot -Recurse -Force | Where-Object {
    $forbiddenNames -contains $_.Name -or $_.Name -like "rai_worker_*.log"
})
if ($forbiddenItems.Count -gt 0) {
    throw "Runtime/user files leaked into staging:`n$($forbiddenItems.FullName -join [Environment]::NewLine)"
}

if ($SkipCompile) {
    Write-Host "[6/6] Compile skipped. Staged package: $PackageRoot"
    exit 0
}

Write-Host "[6/6] Compiling ReaperAI-Setup.exe..."
$compiler = Resolve-IsccPath -RequestedPath $IsccPath
$issPath = Join-Path $PSScriptRoot "ReaperAI.iss"
& $compiler "/DSourceRoot=$PackageRoot" "/DOutputDir=$OutputRoot" $issPath
if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup compilation failed with exit code $LASTEXITCODE."
}

$setupExe = Join-Path $OutputRoot "ReaperAI-Setup.exe"
if (-not (Test-Path -LiteralPath $setupExe -PathType Leaf)) {
    throw "The expected installer was not created: $setupExe"
}
Write-Host "Installer ready: $setupExe"
