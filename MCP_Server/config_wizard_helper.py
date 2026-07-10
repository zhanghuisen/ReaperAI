#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile
import traceback
import urllib.request
import zipfile
from pathlib import Path


FFMPEG_URLS = (
    "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip",
    "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip",
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
    data = {
        "_comment": "ReaperAI MCP Server 配置文件",
        "reaper_projects_dir": projects_dir,
        "reaper_resource_path": resource_path,
        "server": {"host": "127.0.0.1", "port": int(port)},
    }
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
        shutil.copyfileobj(response, handle)
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
    data["ffmpeg_path"] = str(Path(normalize_user_path(ffmpeg_exe)))
    _write_json(config_path, data)


def set_ffmpeg_path(argv: list[str]) -> int:
    if len(argv) != 3:
        return _die("set_ffmpeg_path requires: config_path ffmpeg_exe")

    set_ffmpeg_path_data(Path(normalize_user_path(argv[1])), argv[2])
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

    ffmpeg_dir = mcp_dir / "tools" / "ffmpeg"
    bundled = ffmpeg_dir / "bin" / "ffmpeg.exe"
    if bundled.exists():
        set_ffmpeg_path_data(config_path, str(bundled))
        print(f"[OK] 已找到内置 FFmpeg：{bundled}")
        return

    system_ffmpeg = shutil.which("ffmpeg")
    if system_ffmpeg:
        set_ffmpeg_path_data(config_path, system_ffmpeg)
        print(f"[OK] 已找到系统 FFmpeg：{system_ffmpeg}")
        return

    print("[提示] 未找到 FFmpeg，正在尝试自动下载。")
    print("       FFmpeg 用于音频格式转换，例如 MP3 转 WAV。")
    zip_path = Path(tempfile.gettempdir()) / "reaperai_ffmpeg_essentials.zip"
    if zip_path.exists():
        zip_path.unlink()

    for index, url in enumerate(FFMPEG_URLS, start=1):
        try:
            print(f"[下载] 来源 {index}: {url}")
            download_to(url, zip_path)
            break
        except Exception as exc:
            print(f"[提示] 下载失败：{exc}")

    if not zip_path.exists():
        print("[提示] FFmpeg 自动下载失败。以后也可以手动安装，不影响基础配置。")
        print(f"       手动解压到：{ffmpeg_dir}")
        return

    try:
        ffmpeg_exe = install_ffmpeg_zip(zip_path, ffmpeg_dir)
        set_ffmpeg_path_data(config_path, str(ffmpeg_exe))
        print(f"[OK] FFmpeg 已安装：{ffmpeg_exe}")
    except Exception as exc:
        print(f"[提示] FFmpeg 解压失败：{exc}")
        print("       以后也可以手动安装，不影响基础配置。")
    finally:
        try:
            zip_path.unlink()
        except OSError:
            pass


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
        return _die(f"Unknown command: {command}")
    except Exception as exc:
        _log_exception(exc)
        return _die(f"发生错误：{exc}")


if __name__ == "__main__":
    raise SystemExit(main())
