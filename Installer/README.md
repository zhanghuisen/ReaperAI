# ReaperAI Windows installer

The build produces a self-contained `ReaperAI-Setup.exe`. Python 3.11, all
Python packages, FFmpeg, ReaperAI scripts, and the required REAPER extensions
are embedded. The target computer does not need Python, PowerShell, a network
connection, or the old BAT launchers.

## Build

Install Inno Setup 6 and provide `ffmpeg.exe` plus `ffprobe.exe` in
`MCP_Server\ffmpeg\bin`, then run from the project root:

```powershell
powershell -ExecutionPolicy Bypass -File .\Installer\build_installer.ps1
```

The installer is written to `Installer\output\ReaperAI-Setup.exe`.

To use a separate dependency cache, pass
`-FFmpegBinRoot "D:\dependencies\ffmpeg\bin"`. FFmpeg is embedded in the
resulting setup but should not be committed to the source repository.

## Isolated test switches

- `/REAPERDIR="C:\path\to\REAPER"` selects the folder containing `reaper.exe`.
- `/RESOURCEDIR="C:\isolated\REAPER-resource"` overrides resource-path detection.
- `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART` performs an unattended install.

`/RESOURCEDIR` is intended for automated validation. Normal users only select
their REAPER installation folder in the setup wizard.
