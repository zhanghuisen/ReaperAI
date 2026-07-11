#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import subprocess
import shutil
import sys
import tempfile
import traceback
import urllib.request
import zipfile
from pathlib import Path


FFMPEG_URLS = (
    "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip",
    "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip",
)

PYPI_INDEXES = (
    ("", ""),
    ("https://pypi.tuna.tsinghua.edu.cn/simple", "pypi.tuna.tsinghua.edu.cn"),
    ("https://mirrors.aliyun.com/pypi/simple", "mirrors.aliyun.com"),
    ("https://mirrors.cloud.tencent.com/pypi/simple", "mirrors.cloud.tencent.com"),
    ("https://pypi.mirrors.ustc.edu.cn/simple", "pypi.mirrors.ustc.edu.cn"),
    ("https://pypi.doubanio.com/simple", "pypi.doubanio.com"),
)

CORE_PACKAGES = (
    ("requests", "requests"),
    ("flask", "flask"),
    ("flask-cors", "flask_cors"),
)

OPTIONAL_PACKAGES = (
    ("numpy", "numpy", "音频分析"),
    ("soundfile", "soundfile", "额外 WAV 格式支持"),
)


def _configure_stdio() -> None:
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if reconfigure:
            try:
                reconfigure(encoding="utf-8", errors="replace")
            except Exception:
                pass


def _die(message: str, code: int = 1) -> int:
    print(message, file=sys.stderr)
    return code


def _log_exception(exc: BaseException) -> None:
    log_path = os.environ.get("REAPERAI_CONFIG_WIZARD_LOG")
    if not log_path:
        return
    try:
        Path(log_path).write_text(
            "".join(traceback.format_exception(type(exc), exc, exc.__traceback__)),
            encoding="utf-8",
        )
    except Exception:
        pass


def _write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def _clean_console_text(value: str) -> str:
    value = str(value or "")
    value = value.replace("\ufeff", "").replace("\ufffe", "")
    value = value.replace("ï»¿", "").replace("锘?", "")
    value = "".join(ch for ch in value if not 0xD800 <= ord(ch) <= 0xDFFF)
    if value.startswith("锘"):
        value = value[1:].lstrip("?")
    return value


def _strip_wrapping_quotes(value: str) -> str:
    value = _clean_console_text(value)
    value = str(value or "").strip()
    while len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
        value = value[1:-1].strip()
    value = value.strip().strip('"').strip("'")
    return value


def normalize_user_path(value: str) -> str:
    value = _strip_wrapping_quotes(value)
    if not value:
        return ""
    if os.name == "nt":
        value = value.replace("/", "\\")
        if len(value) > 3 and value.endswith("\\") and not value.startswith("\\\\"):
            value = value.rstrip("\\")
        if len(value) == 2 and value[1] == ":":
            value += "\\"
    return value


def ffmpeg_path_file(mcp_dir: Path) -> Path:
    return mcp_dir / "ffmpeg_path.txt"


def read_ffmpeg_path_file(mcp_dir: Path) -> str:
    path_file = ffmpeg_path_file(mcp_dir)
    try:
        value = normalize_user_path(path_file.read_text(encoding="utf-8").strip())
    except OSError:
        return ""
    return value


def validate_ffmpeg(ffmpeg_exe: str | Path) -> Path | None:
    raw = normalize_user_path(str(ffmpeg_exe or ""))
    if not raw:
        return None
    path = Path(raw)
    if path.name.lower() != "ffmpeg.exe" and os.name == "nt":
        path = path / "ffmpeg.exe"
    if not path.exists():
        return None

    kwargs = {
        "stdout": subprocess.DEVNULL,
        "stderr": subprocess.DEVNULL,
        "timeout": 8,
    }
    if os.name == "nt":
        kwargs["creationflags"] = subprocess.CREATE_NO_WINDOW
    try:
        result = subprocess.run([str(path), "-version"], **kwargs)
    except Exception:
        return None
    return path.resolve() if result.returncode == 0 else None


def candidate_ffmpeg_paths(mcp_dir: Path, config_path: Path | None = None) -> list[str]:
    candidates: list[str] = []

    def add(value: str | Path | None) -> None:
        if value is None:
            return
        text = normalize_user_path(str(value))
        if text and text not in candidates:
            candidates.append(text)

    add(read_ffmpeg_path_file(mcp_dir))
    if config_path and config_path.exists():
        try:
            config = json.loads(config_path.read_text(encoding="utf-8-sig"))
            add(config.get("ffmpeg_path"))
        except Exception:
            pass

    add(os.environ.get("REAPERAI_FFMPEG_PATH"))
    add(os.environ.get("FFMPEG_PATH"))

    add(mcp_dir / "ffmpeg" / "bin" / "ffmpeg.exe")
    add(mcp_dir / "tools" / "ffmpeg" / "bin" / "ffmpeg.exe")
    add(mcp_dir / "ffmpeg.exe")
    add(mcp_dir / "tools" / "ffmpeg.exe")

    system_ffmpeg = shutil.which("ffmpeg")
    add(system_ffmpeg)

    if os.name == "nt":
        add(r"C:\ffmpeg\bin\ffmpeg.exe")
        add(r"C:\Program Files\ffmpeg\bin\ffmpeg.exe")
        add(r"C:\Program Files (x86)\ffmpeg\bin\ffmpeg.exe")
        local_appdata = os.environ.get("LOCALAPPDATA", "")
        if local_appdata:
            add(Path(local_appdata) / "Microsoft" / "WinGet" / "Packages")

    return candidates


def remember_ffmpeg_path(mcp_dir: Path, config_path: Path | None, ffmpeg_exe: str | Path) -> None:
    ffmpeg_path = str(Path(ffmpeg_exe).resolve())
    ffmpeg_path_file(mcp_dir).write_text(ffmpeg_path + "\n", encoding="utf-8")
    if config_path:
        data: dict = {}
        if config_path.exists():
            try:
                data = json.loads(config_path.read_text(encoding="utf-8-sig"))
            except Exception:
                data = {}
        if data:
            data["ffmpeg_path"] = ffmpeg_path
            _write_json(config_path, data)


def find_ffmpeg(mcp_dir: Path, config_path: Path | None = None) -> Path | None:
    for candidate in candidate_ffmpeg_paths(mcp_dir, config_path):
        ffmpeg = validate_ffmpeg(candidate)
        if ffmpeg:
            remember_ffmpeg_path(mcp_dir, config_path, ffmpeg)
            return ffmpeg
    return None


def detect_reaper_resource_value() -> str:
    if os.name == "nt":
        try:
            import winreg

            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\REAPER") as key:
                value, _kind = winreg.QueryValueEx(key, "REAPER_PREF_DIR")
                if value:
                    return str(value)
        except OSError:
            pass

    appdata = os.environ.get("APPDATA")
    if appdata:
        return str(Path(appdata) / "REAPER")
    return str(Path.home() / "AppData" / "Roaming" / "REAPER")


def detect_reaper_resource() -> int:
    print(detect_reaper_resource_value())
    return 0


def _parse_port(port_text: str, default: int = 8765) -> int:
    try:
        port = int(str(port_text or "").strip())
    except ValueError:
        print(f"[提示] 端口不是数字，已使用默认端口 {default}。")
        return default
    if not 1 <= port <= 65535:
        print(f"[提示] 端口超出范围，已使用默认端口 {default}。")
        return default
    return port


def write_config_data(config_path: Path, projects_dir: str, resource_path: str, port: int) -> None:
    old_data: dict = {}
    if config_path.exists():
        try:
            old_data = json.loads(config_path.read_text(encoding="utf-8-sig"))
        except Exception:
            old_data = {}

    data = {
        "_comment": "ReaperAI MCP Server 配置文件",
        "reaper_projects_dir": projects_dir,
        "reaper_resource_path": resource_path,
        "server": {"host": "127.0.0.1", "port": int(port)},
    }
    ffmpeg_path = old_data.get("ffmpeg_path") or read_ffmpeg_path_file(config_path.parent)
    if ffmpeg_path:
        data["ffmpeg_path"] = str(ffmpeg_path)
    _write_json(config_path, data)


def write_config(argv: list[str]) -> int:
    if len(argv) != 5:
        return _die("write_config requires: config_path projects_dir resource_path port")

    config_path = Path(argv[1])
    projects_dir = normalize_user_path(argv[2])
    resource_path = normalize_user_path(argv[3])
    port = _parse_port(argv[4])
    write_config_data(config_path, projects_dir, resource_path, port)
    return 0


def write_config_env(argv: list[str]) -> int:
    if len(argv) != 2:
        return _die("write_config_env requires: config_path")

    config_path = Path(argv[1])
    projects_dir = normalize_user_path(os.environ.get("REAPERAI_CW_PROJECTS_DIR", ""))
    resource_path = normalize_user_path(os.environ.get("REAPERAI_CW_RESOURCE_PATH", ""))
    port = _parse_port(os.environ.get("REAPERAI_CW_PORT", "8765"))
    write_config_data(config_path, projects_dir, resource_path, port)
    return 0


def write_lua_config(argv: list[str]) -> int:
    if len(argv) != 2:
        return _die("write_lua_config requires: lua_config_path")

    lua_config = Path(normalize_user_path(argv[1]))
    lua_config.parent.mkdir(parents=True, exist_ok=True)
    lua_config.write_text(
        "\n".join(
            [
                "# ReaperAI 配置文件",
                "# 由第二步配置向导生成",
                "",
                "LLM_API_KEY=在此填入你的 API Key",
                "LLM_API_URL=https://api.openai.com/v1/chat/completions",
                "LLM_MODEL=gpt-4o-mini",
                "",
                "# ELEVENLABS_API_KEY=在此填入 ElevenLabs API Key（可选）",
                "# 获取地址: https://elevenlabs.io/app/settings/api-keys",
                '# 使用方式: 在 ReaperAI 输入框输入 "11你的描述" 即可生成音频',
                "# 例如: 11爆炸音效，低沉有力",
                "# 例如: 11Hello world",
                "",
            ]
        ),
        encoding="utf-8",
    )
    return 0


def download_to(url: str, output_path: Path) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = output_path.with_name(output_path.name + ".tmp")
    if tmp_path.exists():
        tmp_path.unlink()

    request = urllib.request.Request(url, headers={"User-Agent": "ReaperAI-config-wizard/1.0"})
    with urllib.request.urlopen(request, timeout=180) as response, tmp_path.open("wb") as handle:
        total_header = response.headers.get("Content-Length", "")
        try:
            total = int(total_header)
        except (TypeError, ValueError):
            total = 0
        downloaded = 0
        last_percent = -1
        last_mb = -1
        print("[提示] 正在下载，网络慢时可能需要几分钟，请不要关闭窗口。")
        while True:
            chunk = response.read(1024 * 256)
            if not chunk:
                break
            handle.write(chunk)
            downloaded += len(chunk)
            if total > 0:
                percent = int(downloaded * 100 / total)
                if percent != last_percent and (percent % 5 == 0 or percent == 100):
                    print(f"[进度] {percent:3d}%  {downloaded / 1048576:.1f}/{total / 1048576:.1f} MB")
                    last_percent = percent
            else:
                mb = int(downloaded / 1048576)
                if mb != last_mb and mb > 0:
                    print(f"[进度] 已下载 {downloaded / 1048576:.1f} MB")
                    last_mb = mb
    tmp_path.replace(output_path)


def download(argv: list[str]) -> int:
    if len(argv) != 3:
        return _die("download requires: url output_path")

    output_path = Path(normalize_user_path(argv[2]))
    download_to(argv[1], output_path)
    print(str(output_path))
    return 0


def install_ffmpeg_zip(zip_path: Path, ffmpeg_dir: Path) -> Path:
    if not zip_path.exists():
        raise FileNotFoundError(f"FFmpeg zip not found: {zip_path}")

    ffmpeg_dir.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(zip_path) as archive:
        ffmpeg_entry = None
        for name in archive.namelist():
            normalized = name.replace("\\", "/")
            if normalized.lower().endswith("/bin/ffmpeg.exe"):
                ffmpeg_entry = normalized
                break
        if not ffmpeg_entry:
            raise RuntimeError("ffmpeg.exe was not found inside the downloaded zip.")

        root = ffmpeg_entry[: -len("/bin/ffmpeg.exe")]
        for info in archive.infolist():
            normalized = info.filename.replace("\\", "/")
            if not normalized.startswith(root + "/"):
                continue
            relative = normalized[len(root) + 1 :]
            if not relative:
                continue
            top = relative.split("/", 1)[0].lower()
            if top not in {"bin", "doc", "presets"}:
                continue

            target = ffmpeg_dir / Path(relative)
            if info.is_dir() or relative.endswith("/"):
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(info) as src, target.open("wb") as dst:
                shutil.copyfileobj(src, dst)

    ffmpeg_exe = ffmpeg_dir / "bin" / "ffmpeg.exe"
    if not ffmpeg_exe.exists():
        raise RuntimeError(f"FFmpeg install did not create: {ffmpeg_exe}")
    return ffmpeg_exe


def local_ffmpeg_zips(mcp_dir: Path) -> list[Path]:
    installers = mcp_dir / "installers"
    candidates: list[Path] = []
    for base in (installers, mcp_dir):
        if not base.exists():
            continue
        for pattern in (
            "ffmpeg-release-essentials.zip",
            "ffmpeg-master-latest-win64-gpl.zip",
            "ffmpeg*.zip",
        ):
            for path in sorted(base.glob(pattern)):
                if path.is_file() and path not in candidates:
                    candidates.append(path)
    return candidates


def ffmpeg_download_urls() -> list[str]:
    urls: list[str] = []
    custom = os.environ.get("REAPERAI_FFMPEG_URLS", "")
    for part in custom.replace(";", "\n").splitlines():
        url = part.strip()
        if url and url not in urls:
            urls.append(url)
    for url in FFMPEG_URLS:
        if url not in urls:
            urls.append(url)
    return urls


def install_ffmpeg(argv: list[str]) -> int:
    if len(argv) != 3:
        return _die("install_ffmpeg requires: zip_path ffmpeg_dir")

    ffmpeg_exe = install_ffmpeg_zip(Path(normalize_user_path(argv[1])), Path(normalize_user_path(argv[2])))
    print(str(ffmpeg_exe))
    return 0


def set_ffmpeg_path_data(config_path: Path, ffmpeg_exe: str) -> None:
    data: dict = {}
    if config_path.exists():
        data = json.loads(config_path.read_text(encoding="utf-8-sig"))
    data["ffmpeg_path"] = str(Path(normalize_user_path(ffmpeg_exe)).resolve())
    _write_json(config_path, data)


def set_ffmpeg_path(argv: list[str]) -> int:
    if len(argv) != 3:
        return _die("set_ffmpeg_path requires: config_path ffmpeg_exe")

    set_ffmpeg_path_data(Path(normalize_user_path(argv[1])), argv[2])
    return 0


def ensure_ffmpeg(argv: list[str]) -> int:
    mcp_dir = Path(normalize_user_path(argv[1])) if len(argv) >= 2 else Path(__file__).resolve().parent
    mcp_dir = mcp_dir.resolve()
    config_path = Path(normalize_user_path(argv[2])) if len(argv) >= 3 and argv[2] else mcp_dir / "config.json"
    ffmpeg_dir = mcp_dir / "ffmpeg"

    existing = find_ffmpeg(mcp_dir, config_path)
    if existing:
        print(f"[OK] FFmpeg 已就绪：{existing}")
        return 0

    print("[提示] 未找到可用 FFmpeg，开始强兜底安装。")
    print("       会先使用本地 installers\\ffmpeg*.zip，再尝试网络下载。")

    for zip_path in local_ffmpeg_zips(mcp_dir):
        try:
            print(f"[安装] 使用本地压缩包：{zip_path}")
            ffmpeg = install_ffmpeg_zip(zip_path, ffmpeg_dir)
            remember_ffmpeg_path(mcp_dir, config_path, ffmpeg)
            print(f"[OK] FFmpeg 已安装：{ffmpeg}")
            return 0
        except Exception as exc:
            print(f"[提示] 本地压缩包不可用：{exc}")

    if _is_truthy_env("REAPERAI_FFMPEG_NO_DOWNLOAD"):
        print("[提示] 已设置 REAPERAI_FFMPEG_NO_DOWNLOAD=1，跳过网络下载。")
        print("[ERROR] 未找到可用 FFmpeg。")
        print("手动兜底：")
        print("  1. 下载 ffmpeg-release-essentials.zip 或 ffmpeg-master-latest-win64-gpl.zip")
        print(f"  2. 放到：{mcp_dir / 'installers'}")
        print("  3. 重新运行【第一步】安装依赖.bat")
        return 1

    zip_path = Path(tempfile.gettempdir()) / "reaperai_ffmpeg_essentials.zip"
    for index, url in enumerate(ffmpeg_download_urls(), start=1):
        try:
            if zip_path.exists():
                zip_path.unlink()
            print(f"[下载] 来源 {index}: {url}")
            download_to(url, zip_path)
            ffmpeg = install_ffmpeg_zip(zip_path, ffmpeg_dir)
            remember_ffmpeg_path(mcp_dir, config_path, ffmpeg)
            print(f"[OK] FFmpeg 已安装：{ffmpeg}")
            return 0
        except Exception as exc:
            print(f"[提示] 下载或安装失败：{exc}")
        finally:
            try:
                if zip_path.exists():
                    zip_path.unlink()
            except OSError:
                pass

    print("[ERROR] FFmpeg 自动安装失败。")
    print("手动兜底：")
    print("  1. 下载 ffmpeg-release-essentials.zip 或 ffmpeg-master-latest-win64-gpl.zip")
    print(f"  2. 放到：{mcp_dir / 'installers'}")
    print("  3. 重新运行【第一步】安装依赖.bat")
    print("也可以把已有 ffmpeg.exe 路径写入：")
    print(f"  {ffmpeg_path_file(mcp_dir)}")
    return 1


def _subprocess_env() -> dict[str, str]:
    env = os.environ.copy()
    env.setdefault("PYTHONUTF8", "1")
    env.setdefault("PYTHONIOENCODING", "utf-8")
    env.setdefault("PIP_DISABLE_PIP_VERSION_CHECK", "1")
    return env


def _subprocess_flags() -> dict:
    if os.name == "nt":
        return {"creationflags": subprocess.CREATE_NO_WINDOW}
    return {}


def run_command(args: list[str], cwd: Path | None = None, quiet: bool = False, timeout: int | None = None) -> int:
    kwargs = {
        "cwd": str(cwd) if cwd else None,
        "env": _subprocess_env(),
        "timeout": timeout,
    }
    kwargs.update(_subprocess_flags())
    if quiet:
        kwargs["stdout"] = subprocess.DEVNULL
        kwargs["stderr"] = subprocess.DEVNULL
    result = subprocess.run(args, **kwargs)
    return int(result.returncode)


def command_output(args: list[str], timeout: int = 20) -> str:
    kwargs = {
        "stdout": subprocess.PIPE,
        "stderr": subprocess.DEVNULL,
        "text": True,
        "encoding": "utf-8",
        "errors": "replace",
        "env": _subprocess_env(),
        "timeout": timeout,
    }
    kwargs.update(_subprocess_flags())
    try:
        result = subprocess.run(args, **kwargs)
    except Exception:
        return ""
    if result.returncode != 0:
        return ""
    return (result.stdout or "").strip()


def path_is_under(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except ValueError:
        return False


def python_version_text(python_exe: Path) -> str:
    output = command_output([str(python_exe), "-c", "import sys; print('.'.join(map(str, sys.version_info[:3])))"])
    return output or "unknown"


def python_version_tuple(python_exe: Path) -> tuple[int, int]:
    output = command_output([str(python_exe), "-c", "import sys; print(f'{sys.version_info[0]}.{sys.version_info[1]}')"])
    try:
        major, minor = output.split(".", 1)
        return int(major), int(minor)
    except Exception:
        return 0, 0


def python_site_packages(python_exe: Path) -> Path | None:
    code = (
        "import site, sysconfig; "
        "paths=site.getsitepackages() if hasattr(site,'getsitepackages') else []; "
        "print((paths+[sysconfig.get_paths().get('purelib','')])[0])"
    )
    output = command_output([str(python_exe), "-c", code])
    return Path(normalize_user_path(output)) if output else None


def pythonw_for(python_exe: Path) -> Path:
    if os.name == "nt" and python_exe.name.lower() == "python.exe":
        candidate = python_exe.with_name("pythonw.exe")
        if candidate.exists():
            return candidate
    return python_exe


def write_python_path_files(mcp_dir: Path, python_exe: Path) -> None:
    python_exe = python_exe.resolve()
    (mcp_dir / "python_path.txt").write_text(str(python_exe) + "\n", encoding="utf-8")
    (mcp_dir / "pythonw_path.txt").write_text(str(pythonw_for(python_exe).resolve()) + "\n", encoding="utf-8")


def prepare_install_python(mcp_dir: Path) -> Path:
    current = Path(sys.executable).resolve()
    if path_is_under(current, mcp_dir):
        write_python_path_files(mcp_dir, current)
        return current

    venv_python = mcp_dir / ".venv" / "Scripts" / "python.exe"
    if not venv_python.exists():
        print(f"[安装] 正在创建本地 Python 环境：{mcp_dir / '.venv'}")
        rc = run_command([str(current), "-m", "venv", str(mcp_dir / ".venv")], cwd=mcp_dir)
        if rc != 0:
            raise RuntimeError("无法创建 MCP_Server\\.venv。请确认当前 Python 可用，或删除损坏的 .venv 后重试。")
    if not venv_python.exists():
        raise RuntimeError("本地 Python 环境创建失败，没有生成 .venv\\Scripts\\python.exe。")
    write_python_path_files(mcp_dir, venv_python)
    return venv_python.resolve()


def module_import_ok(python_exe: Path, module_name: str) -> bool:
    return run_command([str(python_exe), "-c", f"import {module_name}"], quiet=True, timeout=20) == 0


def pip_available(python_exe: Path) -> bool:
    return run_command([str(python_exe), "-m", "pip", "--version"], quiet=True, timeout=30) == 0


def ensure_pip(python_exe: Path) -> bool:
    if pip_available(python_exe):
        return True
    print("[提示] 当前 Python 没有 pip，正在尝试启用 pip。")
    run_command([str(python_exe), "-m", "ensurepip", "--upgrade"], quiet=True, timeout=120)
    return pip_available(python_exe)


def local_wheel_files(mcp_dir: Path) -> list[Path]:
    wheels_dir = mcp_dir / "wheels"
    if not wheels_dir.exists():
        return []
    return sorted(path for path in wheels_dir.glob("*.whl") if path.is_file())


def expand_local_wheels(mcp_dir: Path, python_exe: Path) -> bool:
    wheels = local_wheel_files(mcp_dir)
    if not wheels:
        return False
    if python_version_tuple(python_exe) != (3, 11):
        print("[提示] 本地 wheels 是 Python 3.11 版本，当前 Python 版本不同，跳过直接解包。")
        return False
    site_packages = python_site_packages(python_exe)
    if not site_packages:
        return False
    print("[安装] 正在使用随包 wheels 离线安装核心依赖。")
    site_packages.mkdir(parents=True, exist_ok=True)
    for wheel in wheels:
        try:
            with zipfile.ZipFile(wheel) as archive:
                archive.extractall(site_packages)
        except Exception as exc:
            print(f"[提示] wheel 解包失败：{wheel.name} - {exc}")
            return False
    return True


def pip_install_package(python_exe: Path, mcp_dir: Path, package_name: str) -> bool:
    wheels_dir = mcp_dir / "wheels"
    if local_wheel_files(mcp_dir) and pip_available(python_exe):
        print(f"[尝试] 本地 wheels：{package_name}")
        rc = run_command(
            [
                str(python_exe),
                "-m",
                "pip",
                "install",
                package_name,
                "--no-index",
                "--find-links",
                str(wheels_dir),
                "--retries",
                "1",
                "--timeout",
                "30",
            ],
            cwd=mcp_dir,
        )
        if rc == 0:
            return True

    if not ensure_pip(python_exe):
        return False

    for index_url, trusted_host in PYPI_INDEXES:
        if index_url:
            print(f"[尝试] 镜像源 {index_url}：{package_name}")
            args = [
                str(python_exe),
                "-m",
                "pip",
                "install",
                package_name,
                "--upgrade",
                "-i",
                index_url,
                "--trusted-host",
                trusted_host,
                "--retries",
                "2",
                "--timeout",
                "45",
            ]
        else:
            print(f"[尝试] PyPI 官方源：{package_name}")
            args = [
                str(python_exe),
                "-m",
                "pip",
                "install",
                package_name,
                "--upgrade",
                "--retries",
                "2",
                "--timeout",
                "45",
            ]
        if run_command(args, cwd=mcp_dir) == 0:
            return True
    return False


def install_package_set(python_exe: Path, mcp_dir: Path, packages: tuple, required: bool) -> bool:
    ok = True
    for item in packages:
        package_name, module_name = item[0], item[1]
        feature = item[2] if len(item) > 2 else ""
        if module_import_ok(python_exe, module_name):
            print(f"[OK] {package_name} 已可用")
            continue

        label = "[安装]" if required else "[可选]"
        suffix = f"（{feature}）" if feature else ""
        print(f"{label} {package_name}{suffix}")
        installed = pip_install_package(python_exe, mcp_dir, package_name)
        if installed and module_import_ok(python_exe, module_name):
            print(f"[OK] {package_name} 安装完成")
            continue

        if required:
            print(f"[ERROR] 核心依赖安装失败：{package_name}")
            ok = False
        else:
            print(f"[提示] 可选依赖未安装：{package_name}，相关功能可能受限。")
    return ok


def install_dependencies(argv: list[str]) -> int:
    mcp_dir = Path(normalize_user_path(argv[1])) if len(argv) >= 2 else Path(__file__).resolve().parent
    mcp_dir = mcp_dir.resolve()
    config_path = mcp_dir / "config.json"

    print("============================================")
    print("  ReaperAI v1.0.4 - 中文依赖安装器")
    print("============================================")
    print()
    print("本步骤会准备 ReaperAI 私有 Python 环境、核心依赖和 FFmpeg。")
    print("不会把 Python 写入系统 PATH，也不会修改系统全局环境。")
    print()

    python_exe = prepare_install_python(mcp_dir)
    print(f"[OK] Python：{python_exe}")
    print(f"[OK] Python 版本：{python_version_text(python_exe)}")
    print()

    expand_local_wheels(mcp_dir, python_exe)
    print("[检查] 核心依赖")
    core_ok = install_package_set(python_exe, mcp_dir, CORE_PACKAGES, required=True)
    if not core_ok:
        print()
        print("[ERROR] 核心依赖没有安装完整，ReaperAI 暂时无法启动 MCP 服务。")
        print("离线兜底：请把 requests、flask、flask-cors 及其依赖的 .whl 文件放入：")
        print(f"  {mcp_dir / 'wheels'}")
        print("然后重新运行【第一步】安装依赖.bat。")
        return 1

    print()
    if _is_truthy_env("REAPERAI_SKIP_OPTIONAL"):
        print("[跳过] 已设置 REAPERAI_SKIP_OPTIONAL=1，不安装可选依赖。")
    else:
        print("[检查] 可选依赖")
        install_package_set(python_exe, mcp_dir, OPTIONAL_PACKAGES, required=False)

    print()
    if _is_truthy_env("REAPERAI_SKIP_FFMPEG"):
        print("[跳过] 已设置 REAPERAI_SKIP_FFMPEG=1，不检查 FFmpeg。")
    else:
        print("[检查] FFmpeg")
        if ensure_ffmpeg(["ensure_ffmpeg", str(mcp_dir), str(config_path)]) != 0:
            print()
            print("[ERROR] FFmpeg 未就绪。ElevenLabs 音频生成后的转换/导入会失败。")
            return 1

    print()
    print("============================================")
    print("  安装完成")
    print("============================================")
    print("[OK] HTTP Worker：ready")
    print("[OK] MCP Server：ready")
    print("如果 REAPER 已经打开，请重新启动 ReaperAI 后再测试。")
    return 0


def _ask(prompt: str, default: str = "") -> str:
    suffix = f"（默认：{default}）" if default else ""
    try:
        value = input(f"{prompt}{suffix}: ").strip()
    except (EOFError, KeyboardInterrupt):
        print()
        return default
    return value if value else default


def _ask_yes_no(prompt: str, default_yes: bool = False) -> bool:
    default_text = "Y/n" if default_yes else "y/N"
    try:
        value = input(f"{prompt}（{default_text}）: ").strip().lower()
    except (EOFError, KeyboardInterrupt):
        print()
        return default_yes
    if not value:
        return default_yes
    return value in {"y", "yes", "1", "true", "ok", "是", "好", "确认", "覆盖"}


def _is_truthy_env(name: str) -> bool:
    return os.environ.get(name, "").strip().lower() in {"1", "true", "yes", "y", "on"}


def configure_ffmpeg(mcp_dir: Path, config_path: Path) -> None:
    print()
    print("[4/4] 检查 FFmpeg")
    if _is_truthy_env("REAPERAI_CW_SKIP_FFMPEG"):
        print("[跳过] 当前设置了 REAPERAI_CW_SKIP_FFMPEG=1。")
        return

    ffmpeg = find_ffmpeg(mcp_dir, config_path)
    if ffmpeg:
        print(f"[OK] FFmpeg 已就绪：{ffmpeg}")
        return

    print("[提示] 未找到 FFmpeg。音频生成后的转换/导入需要 FFmpeg。")
    print("       请重新运行【第一步】安装依赖.bat，或手动把 ffmpeg zip 放到 installers 后再运行第一步。")


def run_wizard(argv: list[str]) -> int:
    mcp_dir = Path(normalize_user_path(argv[1])) if len(argv) >= 2 else Path(__file__).resolve().parent
    mcp_dir = mcp_dir.resolve()
    config_path = mcp_dir / "config.json"

    print("============================================")
    print("  ReaperAI v1.0.4 - 中文配置向导")
    print("============================================")
    print()
    print("这个向导会生成 ReaperAI 的 MCP 配置文件。")
    print("路径支持正斜杠、反斜杠、带双引号或不带双引号。")
    print()

    if config_path.exists():
        print(f"[提示] 已存在配置文件：{config_path}")
        if not _ask_yes_no("是否覆盖它", default_yes=False):
            print("[取消] 配置没有修改。")
            return 0
        print()

    print("[1/4] 工程扫描目录")
    print("ReaperAI 会在这个目录下面搜索 .rpp 工程文件。")
    projects_dir = normalize_user_path(_ask("请输入扫描目录", "E:/"))
    if not projects_dir:
        projects_dir = normalize_user_path("E:/")
    print(f"[OK] 扫描目录：{projects_dir}")
    print()

    print("[2/4] REAPER 资源目录")
    print("如果不确定，可以直接回车，向导会自动检测。")
    resource_path = normalize_user_path(_ask("请输入资源目录，留空表示自动检测", ""))
    detected_resource = normalize_user_path(resource_path or detect_reaper_resource_value())
    if resource_path:
        print(f"[OK] 资源目录：{resource_path}")
    else:
        print(f"[OK] 自动检测到：{detected_resource}")
    print()

    print("[3/4] MCP 服务端口")
    print("默认端口是 8765。除非端口冲突，否则建议保持默认。")
    port = _parse_port(_ask("请输入端口", "8765"))
    print(f"[OK] 端口：{port}")
    print()

    print("[写入] 正在创建配置文件...")
    write_config_data(config_path, projects_dir, resource_path, port)
    print(f"[OK] MCP 配置：{config_path}")

    lua_config = Path(detected_resource) / "ReaperAI_config.txt"
    write_lua_config(["write_lua_config", str(lua_config)])
    print(f"[OK] Lua 配置：{lua_config}")

    configure_ffmpeg(mcp_dir, config_path)

    print()
    print("============================================")
    print("  配置完成")
    print("============================================")
    print(f"工程扫描目录：{projects_dir}")
    print(f"REAPER 资源目录：{resource_path or detected_resource}")
    print(f"MCP 服务端口：{port}")
    print()
    print("如果 REAPER 已经打开，请重新启动 ReaperAI 后再测试。")
    return 0


def main() -> int:
    _configure_stdio()
    if len(sys.argv) < 2:
        return _die("Missing command.")

    command = sys.argv[1]
    argv = sys.argv[1:]
    try:
        if command == "wizard":
            return run_wizard(argv)
        if command == "detect_reaper_resource":
            return detect_reaper_resource()
        if command == "write_config":
            return write_config(argv)
        if command == "write_config_env":
            return write_config_env(argv)
        if command == "write_lua_config":
            return write_lua_config(argv)
        if command == "download":
            return download(argv)
        if command == "install_ffmpeg":
            return install_ffmpeg(argv)
        if command == "set_ffmpeg_path":
            return set_ffmpeg_path(argv)
        if command == "ensure_ffmpeg":
            return ensure_ffmpeg(argv)
        if command == "install_dependencies":
            return install_dependencies(argv)
        return _die(f"Unknown command: {command}")
    except Exception as exc:
        _log_exception(exc)
        return _die(f"发生错误：{exc}")


if __name__ == "__main__":
    raise SystemExit(main())
