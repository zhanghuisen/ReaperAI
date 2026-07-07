#!/usr/bin/env python3
"""Launch a ReaperAI HTTP worker without opening a console window."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import zipfile
from pathlib import Path


CORE_PACKAGES = (("requests", "requests"),)
PIP_INDEXES = (
    ("", ""),
    ("https://pypi.tuna.tsinghua.edu.cn/simple", "pypi.tuna.tsinghua.edu.cn"),
    ("https://mirrors.aliyun.com/pypi/simple", "mirrors.aliyun.com"),
    ("https://mirrors.cloud.tencent.com/pypi/simple", "mirrors.cloud.tencent.com"),
    ("https://pypi.mirrors.ustc.edu.cn/simple", "pypi.mirrors.ustc.edu.cn"),
    ("https://pypi.doubanio.com/simple", "pypi.doubanio.com"),
)


def write_log(path: Path | None, message: str) -> None:
    if not path:
        return
    try:
        with path.open("a", encoding="utf-8") as handle:
            handle.write(message.rstrip() + "\n")
    except Exception:
        pass


def write_worker_failure(worker_args: list[str], message: str) -> None:
    if len(worker_args) < 7:
        return
    resp_file = Path(worker_args[5])
    signal_file = Path(worker_args[6])
    try:
        resp_file.write_text(
            json.dumps({"success": False, "error": message}, ensure_ascii=False),
            encoding="utf-8",
        )
        signal_file.write_text("done", encoding="utf-8")
    except Exception:
        pass


def popen_hidden(args: list[str], cwd: Path, log_path: Path | None) -> subprocess.Popen:
    env = os.environ.copy()
    env["PYTHONIOENCODING"] = "utf-8"
    env["PYTHONUTF8"] = "1"

    stdout_target = subprocess.DEVNULL
    stderr_target = subprocess.DEVNULL
    log_handle = None
    if log_path:
        try:
            log_handle = log_path.open("ab")
            stdout_target = log_handle
            stderr_target = subprocess.STDOUT
        except Exception:
            log_handle = None

    kwargs = {
        "cwd": str(cwd),
        "stdin": subprocess.DEVNULL,
        "stdout": stdout_target,
        "stderr": stderr_target,
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

    try:
        return subprocess.Popen(args, **kwargs)
    finally:
        if log_handle:
            log_handle.close()


def read_path_file(path: Path) -> Path | None:
    try:
        value = path.read_text(encoding="utf-8").strip().strip('"')
    except OSError:
        return None
    if not value:
        return None
    candidate = Path(value)
    return candidate if candidate.exists() else None


def python_candidates(base_dir: Path, *, windowless: bool) -> list[Path]:
    if os.name != "nt":
        return [Path(sys.executable)]
    current = Path(sys.executable)
    scripts_dir = base_dir / ".venv" / "Scripts"
    runtime_dir = base_dir / "python_runtime"
    legacy_runtime_dir = base_dir / ".python"
    candidates: list[Path | None]
    if windowless:
        candidates = [
            read_path_file(base_dir / "pythonw_path.txt"),
            scripts_dir / "pythonw.exe",
            runtime_dir / "pythonw.exe",
            legacy_runtime_dir / "pythonw.exe",
            read_path_file(base_dir / "python_path.txt"),
            scripts_dir / "python.exe",
            runtime_dir / "python.exe",
            legacy_runtime_dir / "python.exe",
        ]
        if current.name.lower() == "python.exe":
            candidates.append(current.with_name("pythonw.exe"))
        candidates.append(current)
    else:
        candidates = [
            read_path_file(base_dir / "python_path.txt"),
            scripts_dir / "python.exe",
            runtime_dir / "python.exe",
            legacy_runtime_dir / "python.exe",
            read_path_file(base_dir / "pythonw_path.txt"),
            scripts_dir / "pythonw.exe",
            runtime_dir / "pythonw.exe",
            legacy_runtime_dir / "pythonw.exe",
        ]
        if current.name.lower() == "pythonw.exe":
            candidates.append(current.with_name("python.exe"))
        candidates.append(current)
    result: list[Path] = []
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


def is_portable_runtime(python_exe: Path, base_dir: Path) -> bool:
    try:
        parent = python_exe.resolve().parent
        return parent in {
            (base_dir / "python_runtime").resolve(),
            (base_dir / ".python").resolve(),
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


def expand_local_wheels(base_dir: Path, site_packages: Path) -> bool:
    wheels_dir = base_dir / "wheels"
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


def write_python_paths(base_dir: Path, python_exe: Path, pythonw_exe: Path | None) -> None:
    (base_dir / "python_path.txt").write_text(str(python_exe), encoding="utf-8")
    if pythonw_exe and pythonw_exe.exists():
        (base_dir / "pythonw_path.txt").write_text(str(pythonw_exe), encoding="utf-8")


def ensure_runtime(base_dir: Path, log_path: Path | None) -> tuple[Path | None, str | None]:
    install_python = next(iter(python_candidates(base_dir, windowless=False)), None)
    if not install_python:
        return None, "未找到 Python 3.10+，请先安装 Python"

    if os.name == "nt" and is_portable_runtime(install_python, base_dir):
        runtime_dir = install_python.parent
        configure_portable_runtime(runtime_dir)
        site_packages = runtime_dir / "Lib" / "site-packages"
        ok, missing = imports_ok(install_python, CORE_PACKAGES)
        if not ok:
            write_log(log_path, "Preparing portable Python dependencies from local wheels: " + ", ".join(missing))
            if expand_local_wheels(base_dir, site_packages):
                ok, missing = imports_ok(install_python, CORE_PACKAGES)
        if ok:
            pythonw = runtime_dir / "pythonw.exe"
            runtime_python = pythonw if pythonw.exists() else install_python
            write_python_paths(base_dir, install_python, runtime_python)
            return runtime_python, None
        return None, "便携 Python 核心依赖缺失: " + ", ".join(missing) + "。请重新运行【第一步】安装依赖.bat"

    venv_dir = base_dir / ".venv"
    venv_python = venv_dir / "Scripts" / "python.exe" if os.name == "nt" else venv_dir / "bin" / "python"
    venv_pythonw = venv_dir / "Scripts" / "pythonw.exe" if os.name == "nt" else venv_python

    if not venv_python.exists():
        ok, out = run_python([install_python, "-m", "venv", venv_dir], base_dir, timeout=180)
        if not ok or not venv_python.exists():
            write_log(log_path, f"Failed to create .venv with {install_python}\n{out}")
            return None, "创建 .venv 失败，请重新运行【第一步】安装依赖.bat"

    write_python_paths(base_dir, venv_python, venv_pythonw)

    ok, missing = imports_ok(venv_python, CORE_PACKAGES)
    if ok:
        return venv_pythonw if venv_pythonw.exists() else venv_python, None

    wheels_dir = base_dir / "wheels"
    if wheels_dir.exists():
        cmd: list[str | Path] = [venv_python, "-m", "pip", "install", *missing, "--no-index", "--find-links", wheels_dir]
        ok, out = run_python(cmd, base_dir, timeout=240)
        if ok:
            ok2, missing2 = imports_ok(venv_python, CORE_PACKAGES)
            if ok2:
                return venv_pythonw if venv_pythonw.exists() else venv_python, None
            missing = missing2
        write_log(log_path, f"Failed to install worker dependencies from local wheels: missing={missing}\n{out}")

    for index_url, trusted_host in PIP_INDEXES:
        cmd: list[str | Path] = [venv_python, "-m", "pip", "install", *missing]
        if index_url:
            cmd.extend(["-i", index_url, "--trusted-host", trusted_host])
        cmd.extend(["--retries", "2", "--timeout", "45"])
        ok, out = run_python(cmd, base_dir, timeout=240)
        if ok:
            ok2, missing2 = imports_ok(venv_python, CORE_PACKAGES)
            if ok2:
                return venv_pythonw if venv_pythonw.exists() else venv_python, None
            missing = missing2
        write_log(log_path, f"Failed to install worker dependencies: missing={missing}\n{out}")

    return None, "HTTP Worker 核心依赖安装失败: " + ", ".join(missing) + "。请重新运行【第一步】安装依赖.bat"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--worker", required=True)
    parser.add_argument("--log", default="")
    parser.add_argument("worker_args", nargs=argparse.REMAINDER)
    ns = parser.parse_args()

    worker = Path(ns.worker).resolve()
    log_path = Path(ns.log).resolve() if ns.log else None
    worker_args = list(ns.worker_args)
    if worker_args and worker_args[0] == "--":
        worker_args = worker_args[1:]

    if not worker.exists():
        write_log(log_path, f"Missing worker: {worker}")
        write_worker_failure(worker_args, f"Missing worker: {worker}")
        return 2

    try:
        python_exe, runtime_error = ensure_runtime(worker.parent, log_path)
        if runtime_error or not python_exe:
            message = runtime_error or "Python 运行环境不可用"
            write_log(log_path, message)
            write_worker_failure(worker_args, message)
            return 1
        proc = popen_hidden([str(python_exe), str(worker), *worker_args], worker.parent, log_path)
        write_log(log_path, f"Started worker pid={proc.pid} python={python_exe}")
        try:
            code = proc.wait(timeout=1.5)
        except subprocess.TimeoutExpired:
            return 0
        if code != 0:
            message = f"HTTP Worker 启动后立即退出，退出码 {code}。请查看日志: {log_path}"
            write_log(log_path, message)
            write_worker_failure(worker_args, message)
            return code
        return 0
    except Exception as exc:
        write_log(log_path, f"Failed to start worker: {exc}")
        write_worker_failure(worker_args, f"Failed to start worker: {exc}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
