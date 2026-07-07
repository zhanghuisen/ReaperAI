#!/usr/bin/env python3
"""Start the ReaperAI MCP HTTP server without going through cmd.exe."""

from __future__ import annotations

import os
import json
import socket
import subprocess
import sys
import zipfile
from pathlib import Path


HOST = "127.0.0.1"
PORT = 8765
CORE_PACKAGES = (
    ("flask", "flask"),
    ("flask_cors", "flask-cors"),
)
PIP_INDEXES = (
    ("", ""),
    ("https://pypi.tuna.tsinghua.edu.cn/simple", "pypi.tuna.tsinghua.edu.cn"),
    ("https://mirrors.aliyun.com/pypi/simple", "mirrors.aliyun.com"),
    ("https://mirrors.cloud.tencent.com/pypi/simple", "mirrors.cloud.tencent.com"),
    ("https://pypi.mirrors.ustc.edu.cn/simple", "pypi.mirrors.ustc.edu.cn"),
    ("https://pypi.doubanio.com/simple", "pypi.doubanio.com"),
)


def is_port_open() -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.settimeout(0.35)
        return sock.connect_ex((HOST, PORT)) == 0


def popen_hidden(args: list[str | Path], cwd: Path) -> subprocess.Popen:
    kwargs = {
        "cwd": str(cwd),
        "stdin": subprocess.DEVNULL,
        "stdout": subprocess.DEVNULL,
        "stderr": subprocess.DEVNULL,
        "close_fds": True,
    }
    if os.name == "nt":
        kwargs["creationflags"] = (
            subprocess.CREATE_NEW_PROCESS_GROUP
            | subprocess.DETACHED_PROCESS
            | subprocess.CREATE_NO_WINDOW
        )
        startupinfo = subprocess.STARTUPINFO()
        startupinfo.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        startupinfo.wShowWindow = 0
        kwargs["startupinfo"] = startupinfo
    return subprocess.Popen([str(arg) for arg in args], **kwargs)


def write_status(server_dir: Path, state: str, detail: str) -> None:
    status_path = server_dir / "mcp_server_status.json"
    payload = {
        "ok": False,
        "ping_ok": False,
        "port_open": False,
        "endpoint_count": 0,
        "state": state,
        "detail": detail,
    }
    status_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")


def read_path_file(path: Path) -> Path | None:
    try:
        value = path.read_text(encoding="utf-8").strip().strip('"')
    except OSError:
        return None
    if not value:
        return None
    candidate = Path(value)
    return candidate if candidate.exists() else None


def python_candidates(server_dir: Path, *, windowless: bool) -> list[Path]:
    if os.name != "nt":
        return [Path(sys.executable)]
    current = Path(sys.executable)
    scripts_dir = server_dir / ".venv" / "Scripts"
    runtime_dir = server_dir / "python_runtime"
    legacy_runtime_dir = server_dir / ".python"
    candidates: list[Path | None]
    if windowless:
        candidates = [
            read_path_file(server_dir / "pythonw_path.txt"),
            scripts_dir / "pythonw.exe",
            runtime_dir / "pythonw.exe",
            legacy_runtime_dir / "pythonw.exe",
            read_path_file(server_dir / "python_path.txt"),
            scripts_dir / "python.exe",
            runtime_dir / "python.exe",
            legacy_runtime_dir / "python.exe",
        ]
        if current.name.lower() == "python.exe":
            candidates.append(current.with_name("pythonw.exe"))
        candidates.append(current)
    else:
        candidates = [
            read_path_file(server_dir / "python_path.txt"),
            scripts_dir / "python.exe",
            runtime_dir / "python.exe",
            legacy_runtime_dir / "python.exe",
            read_path_file(server_dir / "pythonw_path.txt"),
            scripts_dir / "pythonw.exe",
            runtime_dir / "pythonw.exe",
            legacy_runtime_dir / "pythonw.exe",
        ]
        if current.name.lower() == "pythonw.exe":
            candidates.append(current.with_name("python.exe"))
        candidates.append(current)
    result: list[Path] = []
    candidates.append(current)
    for candidate in candidates:
        if candidate and candidate.exists() and candidate not in result:
            result.append(candidate)
    return result


def run_python(args: list[str | Path], cwd: Path, timeout: int = 180) -> tuple[bool, str]:
    env = os.environ.copy()
    env["PYTHONIOENCODING"] = "utf-8"
    env["PYTHONUTF8"] = "1"
    try:
        kwargs = {
            "cwd": str(cwd),
            "stdin": subprocess.DEVNULL,
            "stdout": subprocess.PIPE,
            "stderr": subprocess.STDOUT,
            "text": True,
            "encoding": "utf-8",
            "errors": "replace",
            "timeout": timeout,
            "env": env,
        }
        if os.name == "nt":
            kwargs["creationflags"] = subprocess.CREATE_NO_WINDOW
            startupinfo = subprocess.STARTUPINFO()
            startupinfo.dwFlags |= subprocess.STARTF_USESHOWWINDOW
            startupinfo.wShowWindow = 0
            kwargs["startupinfo"] = startupinfo
        proc = subprocess.run([str(arg) for arg in args], **kwargs)
        return proc.returncode == 0, proc.stdout[-2000:]
    except Exception as exc:
        return False, str(exc)


def is_portable_runtime(python_exe: Path, server_dir: Path) -> bool:
    try:
        parent = python_exe.resolve().parent
        return parent in {
            (server_dir / "python_runtime").resolve(),
            (server_dir / ".python").resolve(),
        }
    except OSError:
        return False


def configure_portable_runtime(runtime_dir: Path) -> None:
    site_packages = runtime_dir / "Lib" / "site-packages"
    site_packages.mkdir(parents=True, exist_ok=True)
    zip_name = next((p.name for p in runtime_dir.glob("python*.zip")), "python311.zip")
    for pth in runtime_dir.glob("python*._pth"):
        pth.write_text(
            "\n".join([zip_name, ".", r"Lib\site-packages", "import site", ""]),
            encoding="utf-8",
        )


def expand_local_wheels(server_dir: Path, site_packages: Path) -> bool:
    wheels_dir = server_dir / "wheels"
    wheels = sorted(wheels_dir.glob("*.whl")) if wheels_dir.exists() else []
    if not wheels:
        return False
    site_packages.mkdir(parents=True, exist_ok=True)
    try:
        for wheel in wheels:
            with zipfile.ZipFile(wheel) as archive:
                archive.extractall(site_packages)
        return True
    except Exception:
        return False


def imports_ok(python_exe: Path, packages: tuple[tuple[str, str], ...]) -> tuple[bool, list[str]]:
    missing: list[str] = []
    for module_name, package_name in packages:
        ok, _out = run_python([python_exe, "-c", f"import {module_name}"], python_exe.parent, timeout=20)
        if not ok:
            missing.append(package_name)
    return not missing, missing


def write_python_paths(server_dir: Path, python_exe: Path, pythonw_exe: Path | None) -> None:
    (server_dir / "python_path.txt").write_text(str(python_exe), encoding="utf-8")
    if pythonw_exe and pythonw_exe.exists():
        (server_dir / "pythonw_path.txt").write_text(str(pythonw_exe), encoding="utf-8")


def ensure_runtime(server_dir: Path, log_path: Path) -> tuple[Path | None, Path | None, str | None]:
    install_python = next(iter(python_candidates(server_dir, windowless=False)), None)
    if not install_python:
        return None, None, "未找到 Python 3.10+，请先安装 Python"

    if os.name == "nt" and is_portable_runtime(install_python, server_dir):
        runtime_dir = install_python.parent
        configure_portable_runtime(runtime_dir)
        site_packages = runtime_dir / "Lib" / "site-packages"
        ok, missing = imports_ok(install_python, CORE_PACKAGES)
        if not ok:
            write_status(server_dir, "installing", "正在从本地 wheels 准备便携 Python 依赖: " + ", ".join(missing))
            if expand_local_wheels(server_dir, site_packages):
                ok, missing = imports_ok(install_python, CORE_PACKAGES)
        if ok:
            pythonw = runtime_dir / "pythonw.exe"
            hidden_python = pythonw if pythonw.exists() else install_python
            write_python_paths(server_dir, install_python, hidden_python)
            return install_python, hidden_python, None
        return None, None, "便携 Python 核心依赖缺失: " + ", ".join(missing) + "。请重新运行【第一步】安装依赖.bat"

    venv_dir = server_dir / ".venv"
    venv_python = venv_dir / "Scripts" / "python.exe" if os.name == "nt" else venv_dir / "bin" / "python"
    venv_pythonw = venv_dir / "Scripts" / "pythonw.exe" if os.name == "nt" else venv_python

    if not venv_python.exists():
        write_status(server_dir, "installing", "正在创建 ReaperAI 本地 Python 环境")
        ok, out = run_python([install_python, "-m", "venv", venv_dir], server_dir, timeout=180)
        if not ok or not venv_python.exists():
            log_path.write_text(f"Failed to create .venv with {install_python}\n{out}\n", encoding="utf-8")
            return None, None, "创建 .venv 失败，请重新运行【第一步】安装依赖.bat"

    write_python_paths(server_dir, venv_python, venv_pythonw)

    ok, missing = imports_ok(venv_python, CORE_PACKAGES)
    if ok:
        return venv_python, venv_pythonw if venv_pythonw.exists() else venv_python, None

    write_status(server_dir, "installing", "正在安装 MCP 核心依赖: " + ", ".join(missing))
    wheels_dir = server_dir / "wheels"
    if wheels_dir.exists():
        cmd: list[str | Path] = [venv_python, "-m", "pip", "install", *missing, "--no-index", "--find-links", wheels_dir]
        ok, out = run_python(cmd, server_dir, timeout=240)
        if ok:
            ok2, missing2 = imports_ok(venv_python, CORE_PACKAGES)
            if ok2:
                return venv_python, venv_pythonw if venv_pythonw.exists() else venv_python, None
            missing = missing2
        log_path.write_text(
            f"Failed to install MCP dependencies from local wheels\nmissing={missing}\n{out}\n",
            encoding="utf-8",
        )

    for index_url, trusted_host in PIP_INDEXES:
        cmd: list[str | Path] = [venv_python, "-m", "pip", "install", *missing]
        if index_url:
            cmd.extend(["-i", index_url, "--trusted-host", trusted_host])
        cmd.extend(["--retries", "2", "--timeout", "45"])
        ok, out = run_python(cmd, server_dir, timeout=240)
        if ok:
            ok2, missing2 = imports_ok(venv_python, CORE_PACKAGES)
            if ok2:
                return venv_python, venv_pythonw if venv_pythonw.exists() else venv_python, None
            missing = missing2
        log_path.write_text(
            f"Failed to install MCP dependencies with {venv_python}\nmissing={missing}\n{out}\n",
            encoding="utf-8",
        )

    return None, None, "MCP 核心依赖安装失败: " + ", ".join(missing) + "。请重新运行【第一步】安装依赖.bat"


def main() -> int:
    server_dir = Path(__file__).resolve().parent
    server_script = server_dir / "http_server_v2.py"
    shutdown_script = server_dir / "shutdown_http_server.py"
    probe_script = server_dir / "probe_http_server.py"
    log_path = server_dir / "mcp_server_launch.log"
    status_path = server_dir / "mcp_server_status.json"
    server_log_path = server_dir / "mcp_server_stdout.log"
    hidden_python = next(iter(python_candidates(server_dir, windowless=True)), Path(sys.executable))

    if len(sys.argv) > 1 and sys.argv[1] == "--shutdown":
        if not shutdown_script.exists():
            log_path.write_text(f"Missing shutdown script: {shutdown_script}\n", encoding="utf-8")
            return 2
        try:
            proc = popen_hidden([hidden_python, shutdown_script], server_dir)
            log_path.write_text(
                f"Started MCP shutdown pid={proc.pid} python={hidden_python}\n",
                encoding="utf-8",
            )
        except Exception as exc:
            log_path.write_text(f"Failed to start MCP shutdown: {exc}\n", encoding="utf-8")
            return 1
        return 0

    if len(sys.argv) > 1 and sys.argv[1] == "--probe":
        if not probe_script.exists():
            log_path.write_text(f"Missing probe script: {probe_script}\n", encoding="utf-8")
            return 2
        wait_seconds = sys.argv[2] if len(sys.argv) > 2 else "0"
        try:
            proc = popen_hidden([hidden_python, probe_script, "--wait", wait_seconds], server_dir)
            log_path.write_text(
                f"Started MCP probe pid={proc.pid} wait={wait_seconds}s python={hidden_python}\n",
                encoding="utf-8",
            )
        except Exception as exc:
            log_path.write_text(f"Failed to start MCP probe: {exc}\n", encoding="utf-8")
            return 1
        return 0

    if not server_script.exists():
        log_path.write_text(f"Missing server script: {server_script}\n", encoding="utf-8")
        return 2

    python_exe, hidden_runtime_python, runtime_error = ensure_runtime(server_dir, log_path)
    if runtime_error or not python_exe:
        detail = runtime_error or "Python 运行环境不可用"
        write_status(server_dir, "failed", detail)
        log_path.write_text(detail + "\n", encoding="utf-8")
        return 1
    hidden_python = hidden_runtime_python or python_exe

    try:
        if is_port_open():
            log_path.write_text(f"MCP server already listening on {HOST}:{PORT}\n", encoding="utf-8")
            if probe_script.exists():
                popen_hidden([hidden_python, probe_script, "--wait", "1"], server_dir)
            return 0

        status_path.write_text(
            '{"ok": false, "ping_ok": false, "port_open": false, "endpoint_count": 0, '
            '"state": "starting", "detail": "server launch requested"}\n',
            encoding="utf-8",
        )

        env = os.environ.copy()
        env["PYTHONIOENCODING"] = "utf-8"
        env["PYTHONUTF8"] = "1"
        with server_log_path.open("ab") as server_log:
            kwargs = {
                "cwd": str(server_dir),
                "stdin": subprocess.DEVNULL,
                "stdout": server_log,
                "stderr": subprocess.STDOUT,
                "close_fds": True,
                "env": env,
            }
            if os.name == "nt":
                kwargs["creationflags"] = (
                    subprocess.CREATE_NEW_PROCESS_GROUP
                    | subprocess.DETACHED_PROCESS
                    | subprocess.CREATE_NO_WINDOW
                )
                startupinfo = subprocess.STARTUPINFO()
                startupinfo.dwFlags |= subprocess.STARTF_USESHOWWINDOW
                startupinfo.wShowWindow = 0
                kwargs["startupinfo"] = startupinfo
            proc = subprocess.Popen([str(hidden_python), str(server_script)], **kwargs)
        log_path.write_text(
            f"Started MCP server pid={proc.pid} python={hidden_python} log={server_log_path}\n",
            encoding="utf-8",
        )
        if probe_script.exists():
            popen_hidden([hidden_python, probe_script, "--wait", "10"], server_dir)
    except Exception as exc:
        log_path.write_text(f"Failed to start MCP server: {exc}\n", encoding="utf-8")
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
