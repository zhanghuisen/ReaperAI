#!/usr/bin/env python3
"""
HTTP API Server for REAPER Lua scripts - MCP-First Architecture
作者：zhanghuisen
版本：v1.0
Run: python http_server_v2.py

- 所有 AI 操作通过 MCP 端点执行
- 支持 [MCP_CALL:endpoint?params] 格式解析
- 支持 config.json 配置文件
- 新增 sfx/generate_variants 端点
"""

import argparse
import sys
import os
import json
import time
import math
import re
from urllib.parse import parse_qs
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

# Add src to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'src'))

from flask import Flask, request, jsonify
from flask_cors import CORS
# LoopPointAnalyzer - 这个必须有！
try:
    from reaper_mcp_server.audio_loop_analyzer import LoopPointAnalyzer
    print("[OK] LoopPointAnalyzer loaded")
except ImportError as e:
    import traceback
    print(f"[ERROR] Failed to load LoopPointAnalyzer: {e}")
    print(traceback.format_exc())
    class LoopPointAnalyzer:
        def __init__(self, path): pass
        def analyze(self): return {"success": False, "error": "Module not available"}

app = Flask(__name__)
CORS(app)

# ============================================================
# 加载配置文件
# ============================================================
def load_config():
    """加载 config.json 配置文件"""
    config_path = Path(__file__).parent / "config.json"
    default_config = {
        "reaper_projects_dir": ".",
        "reaper_resource_path": "",
        "server": {
            "host": "127.0.0.1",
            "port": 8765
        }
    }
    
    if config_path.exists():
        try:
            with open(config_path, 'r', encoding='utf-8') as f:
                user_config = json.load(f)
                default_config.update(user_config)
                print(f"[OK] 已加载配置文件: {config_path}")
        except Exception as e:
            print(f"[WARN] 配置文件读取失败: {e}")
            print(f"  使用默认配置")
    else:
        print(f"[WARN] 未找到配置文件: {config_path}")
        print(f"  使用默认配置，建议创建 config.json")
    
    return default_config

# 全局配置
CONFIG = load_config()

# REAPER render formats use 4-byte sink identifiers for default sink settings.
# See ReaScript GetSetProjectInfo_String("RENDER_FORMAT") and PCM_Sink_Enum.
RENDER_FORMATS = {
    "wav": {
        "label": "WAV",
        "ext": "wav",
        "sink": "evaw",
        "aliases": ["wave"],
        "terms": ["wave", "wav"],
        "use_bits": True,
        "exact_ext": True,
    },
    "aiff": {
        "label": "AIFF",
        "ext": "aiff",
        "sink": "ffia",
        "aliases": ["aif", "aifc"],
        "terms": ["aiff", "aif"],
        "use_bits": True,
        "exact_ext": False,
    },
    "caf": {
        "label": "CAF",
        "ext": "caf",
        "sink": "ffac",
        "aliases": ["caff"],
        "terms": ["caf", "caff"],
        "use_bits": True,
        "exact_ext": False,
    },
    "flac": {
        "label": "FLAC",
        "ext": "flac",
        "sink": "calf",
        "aliases": [],
        "terms": ["flac"],
        "use_bits": False,
        "exact_ext": True,
    },
    "mp3": {
        "label": "MP3 (LAME)",
        "ext": "mp3",
        "sink": "l3pm",
        "aliases": ["lame"],
        "terms": ["mp3", "lame"],
        "use_bits": False,
        "exact_ext": True,
    },
    "ogg": {
        "label": "OGG Vorbis",
        "ext": "ogg",
        "sink": "vggo",
        "aliases": ["vorbis", "ogg_vorbis"],
        "terms": ["ogg", "vorbis"],
        "use_bits": False,
        "exact_ext": False,
    },
    "opus": {
        "label": "OGG Opus",
        "ext": "opus",
        "sink": "SggO",
        "aliases": ["ogg_opus"],
        "terms": ["opus"],
        "use_bits": False,
        "exact_ext": False,
    },
    "raw": {
        "label": "Raw PCM",
        "ext": "raw",
        "sink": "",
        "aliases": ["pcm", "raw_pcm"],
        "terms": ["raw", "pcm"],
        "use_bits": True,
        "exact_ext": True,
    },
    "cue": {
        "label": "Audio CD Image (CUE/BIN)",
        "ext": "cue",
        "sink": "",
        "aliases": ["bin", "cuebin", "audio_cd"],
        "terms": ["cue", "bin", "audio cd"],
        "use_bits": False,
        "exact_ext": True,
    },
    "ddp": {
        "label": "DDP",
        "ext": "ddp",
        "sink": "",
        "aliases": [],
        "terms": ["ddp"],
        "use_bits": False,
        "exact_ext": True,
    },
    "wavpack": {
        "label": "WavPack",
        "ext": "wv",
        "sink": "",
        "aliases": ["wv", "wavpack_lossless"],
        "terms": ["wavpack", "wv"],
        "use_bits": False,
        "exact_ext": True,
    },
    "mp4": {
        "label": "MP4 / MPEG-4 Video",
        "ext": "mp4",
        "sink": "",
        "aliases": ["m4v", "mpeg4", "mpeg-4", "video_mp4"],
        "terms": ["mp4", "mpeg-4", "mpeg4", "ffmpeg", "libav", "video"],
        "use_bits": False,
        "exact_ext": True,
    },
    "wmv": {
        "label": "Windows Media Video",
        "ext": "wmv",
        "sink": "",
        "aliases": ["windows_media", "wmf"],
        "terms": ["windows media", "wmv", "wmf"],
        "use_bits": False,
        "exact_ext": True,
    },
    "gif": {
        "label": "GIF Video",
        "ext": "gif",
        "sink": "",
        "aliases": [],
        "terms": ["gif"],
        "use_bits": False,
        "exact_ext": True,
    },
    "lcf": {
        "label": "LCF Video",
        "ext": "lcf",
        "sink": "",
        "aliases": [],
        "terms": ["lcf"],
        "use_bits": False,
        "exact_ext": True,
    },
}


def _render_format_token(value):
    value = str(value or "").strip().lower().lstrip(".")
    return re.sub(r"[\s_\-/()]+", "", value)


def normalize_render_format(value):
    raw = str(value or "").strip().lower().lstrip(".")
    token = _render_format_token(raw)
    for key, info in RENDER_FORMATS.items():
        candidates = [key] + info.get("aliases", [])
        for alias in candidates:
            if raw == str(alias).lower() or token == _render_format_token(alias):
                return key
    return raw


def render_format_supported_list():
    return ", ".join(f"{key} ({info['label']})" for key, info in RENDER_FORMATS.items())


def lua_quote(value):
    return json.dumps(str(value or ""), ensure_ascii=False)


def lua_bool(value):
    return "true" if value else "false"


def lua_array(values):
    return "{ " + ", ".join(lua_quote(v) for v in values or []) + " }"


def render_formats_lua_table():
    rows = []
    for key, info in RENDER_FORMATS.items():
        aliases = [key] + info.get("aliases", [])
        terms = list(dict.fromkeys(aliases + info.get("terms", [])))
        rows.append(
            "{ key = %s, label = %s, ext = %s, sink = %s, aliases = %s, terms = %s, use_bits = %s, exact_ext = %s }"
            % (
                lua_quote(key),
                lua_quote(info.get("label", key)),
                lua_quote(info.get("ext", key)),
                lua_quote(info.get("sink", "")),
                lua_array(aliases),
                lua_array(terms),
                lua_bool(info.get("use_bits", False)),
                lua_bool(info.get("exact_ext", False)),
            )
        )
    return "{\n        " + ",\n        ".join(rows) + "\n    }"

# ============================================================
# Command Queue for REAPER to poll
# ============================================================
command_queue = []
command_results = {}
command_id_counter = 0

REAPER_API_CALL_RE = re.compile(r"reaper\s*\.\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(")
REAPER_API_INDEX_CALL_RE = re.compile(r"reaper\s*\[\s*['\"]([A-Za-z_][A-Za-z0-9_]*)['\"]\s*\]\s*\(")
REAPER_API_REF_RE = re.compile(r"reaper\s*\.\s*([A-Za-z_][A-Za-z0-9_]*)")
REAPER_API_INDEX_REF_RE = re.compile(r"reaper\s*\[\s*['\"]([A-Za-z_][A-Za-z0-9_]*)['\"]\s*\]")
REAPER_API_KNOWN_MISSING = {
    "DeleteMediaItem": "REAPER does not expose reaper.DeleteMediaItem; use reaper.DeleteTrackMediaItem(track, item)",
    "MoveRegion": "REAPER does not expose reaper.MoveRegion; use SetProjectMarker / SetProjectMarker3",
}
REAPER_API_CORE_ALLOWLIST = {
    # Core API names used by current MCP generators. The local probe file upgrades this to a machine-verified list.
    "APIExists", "AddMediaItemToTrack", "AddProjectMarker", "AddProjectMarker2", "AddTakeToMediaItem",
    "ColorToNative", "CountMediaItems", "CountProjectMarkers", "CountSelectedMediaItems",
    "CountSelectedTracks", "CountTakeEnvelopes", "CountTrackMediaItems", "CountTracks",
    "CreateTakeAudioAccessor", "DeleteEnvelopePointRange", "DeleteExtState", "DeleteProjectMarker",
    "DeleteTrack", "DeleteTrackMediaItem", "DestroyAudioAccessor", "EnumProjectMarkers",
    "EnumProjectMarkers3", "EnumProjects", "EnumerateSubdirectories", "Envelope_SortPoints",
    "GetActiveTake", "GetAudioAccessorSamples", "GetCursorPosition", "GetEnvelopeName",
    "GetEnvelopeScalingMode", "GetEnvelopeStateChunk", "GetExtState", "GetMediaItem",
    "GetMediaItemInfo_Value", "GetMediaItemTakeInfo_Value", "GetMediaItemTake_Source",
    "GetMediaItemTrack", "GetMediaSourceFileName", "GetMediaSourceLength",
    "GetMediaSourceNumChannels", "GetMediaSourceParent", "GetMediaSourceSampleRate",
    "GetMediaSourceType", "GetMediaTrackInfo_Value", "GetNumTracks", "GetPlayState",
    "GetProjectPath", "GetProjectTimeSignature2", "GetResourcePath", "GetSelectedEnvelope",
    "GetSelectedMediaItem", "GetSelectedTrack", "GetSetMediaItemTakeInfo_String",
    "GetSetMediaTrackInfo_String", "GetSetProjectInfo", "GetSetProjectInfo_String",
    "GetSet_LoopTimeRange", "GetTakeEnvelope", "GetTakeEnvelopeByName", "GetTakeName",
    "GetTrack", "GetTrackEnvelopeByName", "GetTrackGUID", "GetTrackMediaItem",
    "GetTrackName", "GetTrackNumSends", "InsertEnvelopePoint", "InsertMedia",
    "InsertTrackAtIndex", "IsMediaItemSelected", "IsTrackSelected", "Main_OnCommand",
    "OnPlayButton", "OnStopButton", "PCM_Sink_Enum", "PCM_Sink_GetExtension",
    "PCM_Source_GetSectionInfo", "RecursiveCreateDirectory",
    "ReorderSelectedTracks", "ScaleToEnvelopeMode", "SelectAllMediaItems", "SetActiveTake",
    "SetEditCurPos", "SetEnvelopeStateChunk", "SetExtState", "SetMediaItemInfo_Value",
    "SetMediaItemSelected", "SetMediaItemTakeInfo_Value", "SetMediaItemTake_Source",
    "SetMediaTrackInfo_Value", "SetOnlyTrackSelected", "SetProjectMarker", "SetProjectMarker3",
    "SetTrackColor", "SetTrackSelected",
    "ShowConsoleMsg", "ShowMessageBox", "Sleep", "TrackFX_AddByName", "TrackFX_Delete",
    "TrackFX_GetCount", "TrackFX_GetFXName", "TrackList_AdjustWindows", "UpdateArrange",
    "UpdateItemInProject", "UpdateTimeline", "defer", "file_exists", "new_array", "time_precise",
}
_REAPER_API_WHITELIST_CACHE = None
_REAPER_API_WHITELIST_SOURCE = None
_REAPER_ACTION_INVENTORY_CACHE = None
_REAPER_ACTION_INVENTORY_SOURCE = None

def generate_cmd_id():
    global command_id_counter
    command_id_counter += 1
    return f"cmd_{int(time.time()*1000)}_{command_id_counter}"

def queue_command(cmd_type: str, **kwargs) -> str:
    """Queue a command for REAPER to execute"""
    cmd_id = generate_cmd_id()
    cmd = {
        "id": cmd_id,
        "type": cmd_type,
        "timestamp": time.time(),
        **kwargs
    }
    command_queue.append(cmd)
    print(f"[MCP] Command queued: {cmd_id}, type={cmd_type}, queue_size={len(command_queue)}")
    return cmd_id

def reaper_api_inventory_candidates():
    """Candidate local API inventory/probe outputs. First existing inventory wins; whitelist remains legacy fallback."""
    paths = []
    resource_path = CONFIG.get("reaper_resource_path") or ""
    if resource_path:
        paths.append(Path(resource_path) / "Scripts" / "ReaperAI" / "reaper_api_inventory.json")
        paths.append(Path(resource_path) / "Scripts" / "ReaperAI" / "reaper_api_whitelist.json")
    paths.extend([
        Path(__file__).resolve().parent.parent / "Scripts" / "ReaperAI" / "reaper_api_inventory.json",
        Path(__file__).resolve().parent.parent / "Scripts" / "ReaperAI" / "reaper_api_whitelist.json",
    ])
    return paths

def _api_names_from_inventory_payload(data):
    names = set()
    for item in data.get("apis") or []:
        if isinstance(item, str):
            name = item.strip()
            if name:
                names.add(name)
        elif isinstance(item, dict):
            if item.get("available", True) is False:
                continue
            name = str(item.get("name") or item.get("id") or item.get("api") or "").strip()
            if name:
                names.add(name)
    for key in ("available", "functions"):
        for item in data.get(key) or []:
            name = str(item).strip()
            if name:
                names.add(name)
    return names

def load_reaper_api_inventory():
    global _REAPER_API_WHITELIST_CACHE, _REAPER_API_WHITELIST_SOURCE
    if _REAPER_API_WHITELIST_CACHE is not None:
        return _REAPER_API_WHITELIST_CACHE, _REAPER_API_WHITELIST_SOURCE

    for path in reaper_api_inventory_candidates():
        try:
            if path.exists():
                data = json.loads(path.read_text(encoding="utf-8"))
                names = _api_names_from_inventory_payload(data)
                if names:
                    names.update(REAPER_API_CORE_ALLOWLIST)
                    _REAPER_API_WHITELIST_CACHE = names
                    _REAPER_API_WHITELIST_SOURCE = f"{path}+core_allowlist"
                    print(f"[API_GATE] Loaded {len(names)} REAPER APIs from inventory {path} + core allowlist")
                    return _REAPER_API_WHITELIST_CACHE, _REAPER_API_WHITELIST_SOURCE
        except Exception as exc:
            print(f"[API_GATE] Failed to load API inventory {path}: {exc}")

    _REAPER_API_WHITELIST_CACHE = set(REAPER_API_CORE_ALLOWLIST)
    _REAPER_API_WHITELIST_SOURCE = "core_inventory_allowlist"
    print(f"[API_GATE] Using core API inventory allowlist with {len(_REAPER_API_WHITELIST_CACHE)} REAPER APIs")
    return _REAPER_API_WHITELIST_CACHE, _REAPER_API_WHITELIST_SOURCE

def reaper_action_inventory_candidates():
    paths = []
    resource_path = CONFIG.get("reaper_resource_path") or ""
    if resource_path:
        paths.append(Path(resource_path) / "Scripts" / "ReaperAI" / "reaper_action_inventory.json")
    paths.extend([
        Path(__file__).resolve().parent.parent / "Scripts" / "ReaperAI" / "reaper_action_inventory.json",
    ])
    return paths

def load_reaper_action_inventory():
    global _REAPER_ACTION_INVENTORY_CACHE, _REAPER_ACTION_INVENTORY_SOURCE
    if _REAPER_ACTION_INVENTORY_CACHE is not None:
        return _REAPER_ACTION_INVENTORY_CACHE, _REAPER_ACTION_INVENTORY_SOURCE

    for path in reaper_action_inventory_candidates():
        try:
            if path.exists():
                data = json.loads(path.read_text(encoding="utf-8"))
                actions = data.get("actions") or []
                by_id = {}
                for item in actions:
                    action_id = str(item.get("id") or item.get("command_id") or "").strip()
                    if action_id:
                        by_id[action_id] = item
                if by_id:
                    _REAPER_ACTION_INVENTORY_CACHE = by_id
                    _REAPER_ACTION_INVENTORY_SOURCE = str(path)
                    print(f"[ACTION_GATE] Loaded {len(by_id)} REAPER actions from {path}")
                    return _REAPER_ACTION_INVENTORY_CACHE, _REAPER_ACTION_INVENTORY_SOURCE
        except Exception as exc:
            print(f"[ACTION_GATE] Failed to load action inventory {path}: {exc}")

    _REAPER_ACTION_INVENTORY_CACHE = {}
    _REAPER_ACTION_INVENTORY_SOURCE = ""
    return _REAPER_ACTION_INVENTORY_CACHE, _REAPER_ACTION_INVENTORY_SOURCE

def find_native_action(params):
    params = params or {}
    inventory, source = load_reaper_action_inventory()
    command_id = str(params.get("command_id") or params.get("id") or params.get("action_id") or "").strip()
    if command_id:
        return inventory.get(command_id), source

    query = str(params.get("query") or params.get("name") or params.get("description") or "").strip()
    action = str(params.get("action") or params.get("kind") or "").strip().lower()
    mode = str(params.get("mode") or "").strip().lower()
    if not query and action in ("freeze", "track/freeze"):
        query = f"Track: Freeze to {mode or 'stereo'}"
    elif not query and action in ("unfreeze", "track/unfreeze"):
        query = "Track: Unfreeze tracks"
    elif not query and action in ("glue", "item/glue"):
        query = "glue"
    elif not query and action:
        query = action

    if not query:
        return None, source
    tokens = [t for t in query.lower().split() if t]
    best = None
    best_score = -1
    for item in inventory.values():
        text = f"{item.get('name') or ''} {item.get('command_name') or ''} {item.get('id') or ''}".lower()
        score = 0
        if text == query.lower():
            score += 100
        if query.lower() in text:
            score += 50
        for token in tokens:
            if token in text:
                score += 5
        if action in ("freeze", "track/freeze") and ("freeze" in text or "冻结" in text):
            score += 20
        if mode and mode in text:
            score += 12
        if score > best_score:
            best = item
            best_score = score
    return (best if best_score > 0 else None), source

def lua_string(value):
    text = str(value or "")
    text = text.replace("\\", "\\\\").replace("'", "\\'").replace("\n", "\\n").replace("\r", "")
    return f"'{text}'"

def strip_lua_comments_and_strings_for_api_gate(src: str) -> str:
    src = str(src or "")
    out = []
    i = 0
    quote = None
    long_string = False
    while i < len(src):
        c = src[i]
        n = src[i:i + 2]
        four = src[i:i + 4]
        if long_string:
            if n == "]]":
                long_string = False
                out.append("  ")
                i += 2
            else:
                out.append("\n" if c == "\n" else " ")
                i += 1
        elif quote:
            if c == "\\":
                out.append("  ")
                i += 2
            elif c == quote:
                quote = None
                out.append(" ")
                i += 1
            else:
                out.append("\n" if c == "\n" else " ")
                i += 1
        elif four == "--[[":
            long_string = True
            out.append("    ")
            i += 4
        elif n == "--":
            while i < len(src) and src[i] != "\n":
                out.append(" ")
                i += 1
        elif n == "[[":
            long_string = True
            out.append("  ")
            i += 2
        elif c in ("'", '"'):
            quote = c
            out.append(" ")
            i += 1
        else:
            out.append(c)
            i += 1
    return "".join(out)

def collect_reaper_api_calls_from_lua(lua_code: str) -> list[str]:
    cleaned = strip_lua_comments_and_strings_for_api_gate(lua_code)
    names = set(REAPER_API_CALL_RE.findall(cleaned))
    names.update(REAPER_API_INDEX_CALL_RE.findall(cleaned))
    names.update(REAPER_API_REF_RE.findall(cleaned))
    names.update(REAPER_API_INDEX_REF_RE.findall(cleaned))
    return sorted(names)

def validate_reaper_api_compatibility(lua_code: str) -> tuple[bool, str | None, dict]:
    names = collect_reaper_api_calls_from_lua(lua_code)
    inventory, source = load_reaper_api_inventory()
    missing = []
    for name in names:
        if name in REAPER_API_KNOWN_MISSING:
            missing.append({"name": name, "reason": REAPER_API_KNOWN_MISSING[name]})
        elif name not in inventory:
            missing.append({"name": name, "reason": f"reaper.{name} is not in REAPER API inventory ({source})"})

    detail = {
        "api_count": len(names),
        "apis": names,
        "api_inventory_source": source,
        "whitelist_source": source,
        "missing": missing,
    }
    if missing:
        first = missing[0]
        return False, f"REAPER API Gate blocked nonexistent or unverified API: reaper.{first['name']} - {first['reason']}", detail
    return True, None, detail

# ============================================================
# Legacy Endpoints (保留向后兼容)
# ============================================================

@app.route('/')
def root():
    return jsonify({
        "status": "REAPER MCP HTTP API v1.0 (MCP-First)",
        "projects_dir": app.config.get("PROJECTS_DIR", "."),
        "version": "2.1",
        "features": ["command_queue", "mcp_parse", "auto_execute", "config_file"]
    })

@app.route('/ping')
def ping():
    return jsonify({"ok": True, "status": "REAPER MCP running"})

@app.route('/analyze_loop_points')
def analyze_loop_points():
    """
    分析音频文件的循环点（Python端处理，绕过REAPER API bug）
    
    参数:
        file: 音频文件的完整路径
        section_start: SECTION在父文件中的起始时间（秒，默认0）
        section_length: SECTION的长度（秒，默认整个文件）
        min_duration: 最小循环长度（秒，默认0.5）
        max_duration: 最大循环长度（秒，默认10.0）
    """
    import time
    start_time = time.time()
    
    file_path = request.args.get('file')
    section_start = float(request.args.get('section_start', '0'))
    section_length = float(request.args.get('section_length', '0'))
    min_duration = float(request.args.get('min_duration', '0.5'))
    max_duration = float(request.args.get('max_duration', '10.0'))
    
    print(f"[analyze_loop_points] 开始分析: {file_path}")
    print(f"[analyze_loop_points] SECTION: 起始={section_start}s, 长度={section_length}s")
    
    if not file_path:
        return jsonify({"success": False, "error": "Missing 'file' parameter"})
    
    # 路径映射：将REAPER路径映射到Python可访问的路径
    mapped_path = map_reaper_path_to_local(file_path)
    print(f"[analyze_loop_points] 映射路径: {mapped_path}")
    
    try:
        analyzer = LoopPointAnalyzer(mapped_path)
        print(f"[analyze_loop_points] 分析器创建完成，开始分析...")
        
        # 分析指定的section段
        result = analyzer.analyze(
            min_loop_duration=min_duration, 
            max_loop_duration=max_duration,
            section_start=section_start,
            section_length=section_length
        )
        
        elapsed = time.time() - start_time
        print(f"[analyze_loop_points] 分析完成，耗时: {elapsed:.2f}s")
        
        # 添加原始路径信息
        if result.get("success"):
            result["original_path"] = file_path
            result["analyzed_path"] = mapped_path
            result["section_start"] = section_start
            result["section_length"] = section_length
            result["analysis_time"] = elapsed
            
        return jsonify(result)
    except Exception as e:
        import traceback
        elapsed = time.time() - start_time
        print(f"[analyze_loop_points] 分析失败，耗时: {elapsed:.2f}s, 错误: {e}")
        return jsonify({
            "success": False, 
            "error": str(e),
            "traceback": traceback.format_exc(),
            "analysis_time": elapsed
        })

def map_reaper_path_to_local(reaper_path: str) -> str:
    """
    将REAPER路径映射到Python可访问的本地路径
    
    支持通过 config.json 配置路径映射规则
    """
    # 默认直接返回原路径
    mapped = reaper_path
    
    # 如果配置了路径映射，应用映射规则
    path_mappings = CONFIG.get("path_mappings", {})
    for reaper_prefix, local_prefix in path_mappings.items():
        if reaper_path.startswith(reaper_prefix):
            mapped = reaper_path.replace(reaper_prefix, local_prefix, 1)
            break
    
    return mapped

# ============================================================
# MCP Command Queue Endpoints
# ============================================================

@app.route('/command_queue')
def get_command_queue():
    """REAPER polls this to get pending commands"""
    global command_queue
    cmds = command_queue.copy()
    count = len(cmds)
    print(f"[MCP] Command queue requested, queue has {count} commands")
    if count > 0:
        print(f"[MCP] Commands in queue: {[c.get('id') for c in cmds]}")
        # 【修复】返回后清空队列，防止命令被重复执行
        command_queue = []
        print(f"[MCP] Queue cleared after read")
    return jsonify({"commands": cmds, "count": count})

@app.route('/command_result/<cmd_id>')
def get_command_result(cmd_id):
    """Get result of a command execution"""
    if cmd_id in command_results:
        return jsonify({"success": True, "result": command_results.pop(cmd_id)})
    return jsonify({"success": False, "status": "pending"})

@app.route('/submit_result', methods=['POST'])
def submit_result():
    """REAPER submits execution results here"""
    data = request.get_json() or {}
    cmd_id = data.get('id')
    result = data.get('result')
    error = data.get('error')
    
    if cmd_id:
        command_results[cmd_id] = {"result": result, "error": error}
        return jsonify({"success": True})
    return jsonify({"success": False, "error": "Missing command id"})

@app.route('/execute_lua', methods=['POST'])
def execute_lua():
    """Queue Lua code for REAPER to execute"""
    data = request.get_json() or {}
    code = data.get('code', '')
    cmd_id = data.get('id') or generate_cmd_id()
    
    if not code:
        return jsonify({"success": False, "error": "No code provided"})
    
    queue_command("lua", code=code, id=cmd_id)
    return jsonify({"success": True, "id": cmd_id, "status": "queued"})

@app.route('/list_endpoints')
def list_endpoints():
    """返回所有可用的 MCP endpoint 列表（用于动态更新 AI 的 system prompt）"""
    return jsonify({
        "success": True,
        "endpoints": MCP_ENDPOINTS,
        "count": len(MCP_ENDPOINTS),
        "version": "2.2"
    })

# ============================================================
# Shutdown Endpoint - 用于优雅关闭服务器
# ============================================================

@app.route('/shutdown', methods=['POST', 'GET'])
def shutdown():
    """优雅关闭 MCP 服务器"""
    import threading
    
    def delayed_shutdown():
        """延迟关闭，让响应先返回"""
        time.sleep(0.5)
        os._exit(0)
    
    # 启动延迟关闭线程
    threading.Thread(target=delayed_shutdown, daemon=True).start()
    
    return jsonify({
        "success": True,
        "message": "MCP 服务器正在关闭...",
        "status": "shutting_down"
    })

# ============================================================
# MCP-First Action Endpoints (AI 直接调用)
# ============================================================

@app.route('/mcp/parse', methods=['POST'])
def mcp_parse():
    """
    Parse [MCP_CALL:endpoint?params] format and queue the action
    REAPER Lua 调用这个端点来让服务器解析 MCP 调用指令
    """
    try:
        data = request.get_json() or {}
        mcp_calls = data.get('calls', [])
        print(f"[MCP] /mcp/parse received {len(mcp_calls)} calls: {mcp_calls}")
        
        results = []
        for call in mcp_calls:
            result = parse_mcp_call(call)
            results.append(result)
        
        print(f"[MCP] /mcp/parse returning {len(results)} results")
        return jsonify({"success": True, "results": results, "queued": len(results)})
    except Exception as e:
        print(f"[MCP] /mcp/parse ERROR: {e}")
        import traceback
        traceback.print_exc()
        return jsonify({"success": False, "error": str(e)}), 400

def parse_mcp_call(call_string: str) -> dict:
    """Parse a single MCP call string and queue the command"""
    if '?' in call_string:
        endpoint, params_str = call_string.split('?', 1)
    else:
        endpoint, params_str = call_string, ""
    
    params = parse_qs(params_str)
    params = {k: v[0] if len(v) == 1 else v for k, v in params.items()}
    
    endpoint = endpoint.strip('/')
    params = normalize_selection_params(endpoint, params)
    
    lua_generators = {
        'transport/play': generate_transport_play_lua,
        'transport/stop': generate_transport_stop_lua,
        'track/create': generate_create_track_lua,
        'track/delete': generate_delete_track_lua,
        'track/rename': generate_rename_track_lua,
        'track/set_volume': generate_set_volume_lua,
        'track/set_pan': generate_set_pan_lua,
        'track/set_color': generate_set_color_lua,
        'track/clear_color': generate_clear_track_color_lua,
        'track/mute': generate_mute_track_lua,
        'track/solo': generate_solo_track_lua,
        'track/add_fx': generate_add_fx_lua,
        'track/remove_fx': generate_remove_fx_lua,
        'marker/add': generate_add_marker_lua,
        'marker/delete': generate_delete_marker_lua,
        'region/delete': generate_delete_region_lua,
        'region/set_color': generate_set_region_color_lua,
        'item/set_color': generate_set_item_color_lua,
        'item/fade': generate_item_fade_lua,
        'item/set_fade': generate_item_fade_lua,
        'item/fade_shape': generate_item_fade_shape_lua,
        'item/set_fade_shape': generate_item_fade_shape_lua,
        'native/action': generate_native_action_lua,
        'envelope/draw': generate_draw_envelope_lua,
        'envelope/clear': generate_clear_envelope_lua,
        'region/batch_rename': generate_batch_rename_regions_lua,
        'track/set_volume_by_name': generate_set_volume_by_name_lua,
        'track/group_into_folder': generate_group_tracks_into_folder_lua,
        'track/create_folder': generate_group_tracks_into_folder_lua,
        # === 游戏音效师专用功能 ===
        'sfx/generate_variants': generate_sfx_variants_lua,
        'analysis/detect_peaks': generate_detect_peaks_lua,
        'analysis/find_loop_points': generate_find_loop_points_lua,
        'export/batch_regions': generate_export_regions_lua,
        'export/tracks': generate_export_tracks_lua,
        'export/master': generate_export_master_lua,
        'endpoints': generate_list_endpoints_lua,
    }
    
    if endpoint in lua_generators:
        lua_code = lua_generators[endpoint](params)
        api_ok, api_error, api_detail = validate_reaper_api_compatibility(lua_code)
        if not api_ok:
            print(f"[API_GATE] Blocked endpoint={endpoint}: {api_error}")
            return {
                "success": False,
                "endpoint": endpoint,
                "error": api_error,
                "api_gate": api_detail,
                "params": params,
            }
        cmd_id = queue_command("lua", code=lua_code, endpoint=endpoint, params=params)
        return {
            "success": True,
            "endpoint": endpoint,
            "cmd_id": cmd_id,
            "params": params,
            "api_gate": {
                "api_count": api_detail.get("api_count", 0),
                "api_inventory_source": api_detail.get("api_inventory_source", ""),
                "whitelist_source": api_detail.get("whitelist_source", ""),
            },
            "lua_preview": lua_code[:200] + "..." if len(lua_code) > 200 else lua_code
        }
    else:
        return {
            "success": False,
            "endpoint": endpoint,
            "error": f"Unknown endpoint: {endpoint}",
            "available": list(lua_generators.keys())
        }

# ============================================================
# Lua Code Generators
# ============================================================

def lua_escape_string(s):
    if s is None:
        return ""
    s = str(s)
    s = s.replace('\\', '\\\\')
    s = s.replace('"', '\\"')
    s = s.replace('\n', '\\n')
    s = s.replace('\r', '')
    return s

def _is_int_string(value):
    try:
        int(str(value))
        return True
    except (TypeError, ValueError):
        return False

SELECTED_TOKENS = ('selected', 'selection', 'current', '当前', '选中', '已选中')

SELECTION_TARGET_ENDPOINTS = {
    'track/delete',
    'track/rename',
    'track/set_volume',
    'track/set_pan',
    'track/set_color',
    'track/clear_color',
    'region/set_color',
    'item/set_color',
    'track/mute',
    'track/solo',
    'track/add_fx',
    'track/remove_fx',
    'item/fade',
    'item/set_fade',
    'item/fade_shape',
    'item/set_fade_shape',
    'envelope/draw',
    'envelope/clear',
    'analysis/detect_peaks',
    'analysis/find_loop_points',
    'sfx/generate_variants',
}

def _selected_token(value):
    return str(value or '').strip().lower() in SELECTED_TOKENS

def _boolish(value):
    return str(value or '').strip().lower() in ('true', '1', 'yes', 'y', 'on')

def _all_token(value):
    return str(value or '').strip().lower() in (
        'all', 'everything', 'entire', 'project', 'all_tracks', 'all_items',
        'all_markers', 'all_regions', '全部', '所有', '整个工程', '所有轨道',
        '所有标记', '所有区域'
    )

def _targets_all(params):
    return (
        _boolish(params.get('all', ''))
        or _all_token(params.get('scope', ''))
        or _all_token(params.get('target', ''))
        or _all_token(params.get('tracks', ''))
    )

def normalize_selection_params(endpoint, params):
    """Normalize natural selected-target aliases before Lua generation."""
    if endpoint not in SELECTION_TARGET_ENDPOINTS:
        return params
    normalized = dict(params)
    selected_keys = ('target', 'scope', 'track', 'item', 'take', 'name', 'index')
    current_tokens = {'current', 'current_region', 'current_item', 'cursor', 'edit_cursor'}
    preserve_current = endpoint in ('region/set_color', 'item/set_color')
    def selected_alias(key):
        value = str(normalized.get(key, '') or '').strip().lower()
        if preserve_current and value in current_tokens:
            return False
        return _selected_token(value)
    if any(selected_alias(key) for key in selected_keys):
        normalized['selected'] = 'true'
        for key in selected_keys:
            if selected_alias(key):
                normalized.pop(key, None)
    return normalized

def generate_track_lookup_lua(params, index_key='index', default_index='0'):
    """Return Lua that resolves one track by index, track, or name."""
    selected = (
        str(params.get('selected', '')).lower() in ('true', '1', 'yes')
        or _selected_token(params.get('target', ''))
        or _selected_token(params.get(index_key, ''))
        or _selected_token(params.get('track', ''))
        or _selected_token(params.get('name', ''))
    )
    if selected:
        return '''
local track = reaper.GetSelectedTrack(0, 0)
local track_index = -1
local track_label = "selected track"
if track then
    track_index = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") - 1
    local _, selected_track_name = reaper.GetTrackName(track)
    if selected_track_name and selected_track_name ~= "" then
        track_label = selected_track_name
    end
end
'''

    raw_index = params.get(index_key, '')
    if raw_index == '' and index_key != 'index':
        raw_index = params.get('index', '')
    target_raw = str(params.get('target', '') or '').strip()
    if raw_index == '' and _is_int_string(target_raw):
        raw_index = target_raw
    if raw_index != '' and _is_int_string(raw_index):
        idx = raw_index
        return f'''
local track_index = tonumber("{lua_escape_string(idx)}") or {default_index}
local track = reaper.GetTrack(0, track_index)
local track_label = "#" .. tostring(track_index)
'''

    name = params.get('name', '')
    if not name and index_key == 'track':
        raw_track = params.get('track', '')
        if raw_track and not _is_int_string(raw_track):
            name = raw_track
    if not name:
        for key in ('target', 'track_name', 'old_name', 'from'):
            value = str(params.get(key, '') or '').strip()
            if value and not _selected_token(value) and not _is_int_string(value):
                name = value
                break

    if name:
        target = lua_escape_string(name)
        return f'''
local target_name = "{target}"
local track = nil
local track_index = -1
local exact_track = nil
local exact_index = -1
local partial_track = nil
local partial_index = -1
local needle = target_name:lower()
for i = 0, reaper.CountTracks(0) - 1 do
    local candidate = reaper.GetTrack(0, i)
    if candidate then
        local _, candidate_name = reaper.GetTrackName(candidate)
        if candidate_name == target_name then
            exact_track = candidate
            exact_index = i
            break
        elseif not partial_track and candidate_name:lower():find(needle, 1, true) then
            partial_track = candidate
            partial_index = i
        end
    end
end
track = exact_track or partial_track
track_index = exact_index >= 0 and exact_index or partial_index
local track_label = target_name
'''

    return '''
local track = nil
local track_index = -1
local track_label = "missing track target"
'''

def has_explicit_track_target(params, index_key='index', allow_name=True, extra_keys=()):
    selected = str(params.get('selected', '')).lower() in ('true', '1', 'yes')
    if selected or _targets_all(params):
        return True
    keys = ['target', 'track_name', index_key, 'track', 'index', *extra_keys]
    if allow_name:
        keys.append('name')
    seen = set()
    for key in keys:
        if key in seen:
            continue
        seen.add(key)
        value = str(params.get(key, '')).strip()
        if value:
            return True
    return False


def guard_track_target_lua(params, action, index_key='index', allow_name=True, extra_keys=()):
    if has_explicit_track_target(params, index_key=index_key, allow_name=allow_name, extra_keys=extra_keys):
        return ''
    action = lua_escape_string(action)
    return f'''
return "ERROR: Missing track target for {action}; refused to default to project first track. Use selected=true, index/track, target/name, or a created-track binding."
'''

def _looks_like_numeric_selector(value):
    text = str(value or '').strip()
    if not text:
        return False
    compact = re.sub(r'\s+', '', text)
    if re.fullmatch(r'-?\d+', compact):
        return True
    if re.search(r'[,;|~:\-]', compact) and re.fullmatch(r'[TtRr]?-?\d+([,;|~:\-][TtRr]?-?\d+)*', compact):
        return True
    if re.fullmatch(r'[TtRr]\d+', compact):
        return True
    return False

def _split_batch_target_and_name(params, object_keys, name_keys):
    """Separate index/range selectors from name-like target aliases."""
    params = params or {}
    target_value = first_nonempty_param(params, ('range', 'ids', 'index', 'id'))
    raw_object = first_nonempty_param(params, object_keys)
    name_value = first_nonempty_param(params, name_keys)
    if not target_value and _looks_like_numeric_selector(raw_object):
        target_value = raw_object
    elif not name_value and raw_object and not _selected_token(raw_object) and not _all_token(raw_object):
        name_value = raw_object
    return target_value, name_value

def _batch_order_values(params):
    return (
        first_nonempty_param(params, ('order_range', 'ordinal_range', 'sequence_range', 'order', 'ordinal', 'sequence', 'order_index', 'ordinal_index', 'sequence_index')),
        first_nonempty_param(params, ('order_start', 'ordinal_start', 'sequence_start')),
        first_nonempty_param(params, ('order_end', 'to_order', 'ordinal_end', 'sequence_end')),
    )

def parse_volume_to_lua_value(volume):
    if 'dB' in str(volume):
        db_val = float(str(volume).replace('dB', '').strip())
        return str(10 ** (db_val / 20))
    return str(volume)

def parse_color_value(color):
    """Return (r, g, b, label) for common color names, hex, or r,g,b."""
    raw = str(color or '').strip()
    colors = {
        'red': (255, 0, 0), '红': (255, 0, 0), '红色': (255, 0, 0),
        'green': (0, 180, 0), '绿': (0, 180, 0), '绿色': (0, 180, 0),
        'blue': (0, 96, 255), '蓝': (0, 96, 255), '蓝色': (0, 96, 255),
        'yellow': (255, 220, 0), '黄': (255, 220, 0), '黄色': (255, 220, 0),
        'orange': (255, 128, 0), '橙': (255, 128, 0), '橙色': (255, 128, 0),
        'purple': (160, 80, 255), '紫': (160, 80, 255), '紫色': (160, 80, 255),
        'pink': (255, 105, 180), '粉': (255, 105, 180), '粉色': (255, 105, 180),
        'cyan': (0, 200, 220), '青': (0, 200, 220), '青色': (0, 200, 220),
        'white': (255, 255, 255), '白': (255, 255, 255), '白色': (255, 255, 255),
        'gray': (128, 128, 128), 'grey': (128, 128, 128), '灰': (128, 128, 128), '灰色': (128, 128, 128),
        'black': (0, 0, 0), '黑': (0, 0, 0), '黑色': (0, 0, 0),
    }
    key = raw.lower()
    if key in colors:
        r, g, b = colors[key]
        return r, g, b, raw or key
    if raw.startswith('#') and len(raw) == 7:
        try:
            return int(raw[1:3], 16), int(raw[3:5], 16), int(raw[5:7], 16), raw
        except ValueError:
            pass
    if ',' in raw:
        parts = [p.strip() for p in raw.split(',')]
        if len(parts) >= 3:
            try:
                r, g, b = [max(0, min(255, int(float(p)))) for p in parts[:3]]
                return r, g, b, raw
            except ValueError:
                pass
    return 255, 0, 0, raw or 'red'

def generate_transport_play_lua(params):
    return '''
reaper.OnPlayButton()
return "✓ Transport play"
'''

def generate_transport_stop_lua(params):
    return '''
reaper.OnStopButton()
return "✓ Transport stop"
'''

def generate_create_track_lua(params):
    raw_name = str(params.get('name', 'New Track'))
    name = lua_escape_string(raw_name)
    names_raw = str(params.get('names', params.get('track_names', '')) or '').strip()
    explicit_names = []
    if names_raw:
        normalized_names = names_raw.replace('|', ',').replace(';', ',')
        normalized_names = normalized_names.replace('\uFF0C', ',')
        explicit_names = [part.strip() for part in normalized_names.split(',') if part.strip()]
    count = int(params.get('count', str(len(explicit_names) or 1)))
    if explicit_names and count < len(explicit_names):
        count = len(explicit_names)
    create_name = lua_escape_string(explicit_names[0] if explicit_names else raw_name)
    # 解析 volume 参数（支持 dB 格式如 -5dB）
    volume_lua = ""
    vol_str = params.get('volume', '')
    if vol_str:
        vol_val = str(vol_str)
        if 'dB' in vol_val:
            db_val = float(vol_val.replace('dB', '').strip())
            vol_linear = 10 ** (db_val / 20)
            volume_lua = f'reaper.SetMediaTrackInfo_Value(track, "D_VOL", {vol_linear})'
        else:
            volume_lua = f'reaper.SetMediaTrackInfo_Value(track, "D_VOL", {float(vol_val)})'
    if count <= 1:
        vol_line = f"    {volume_lua}\n" if volume_lua else ""
        return f'''
local idx = reaper.GetNumTracks()
reaper.InsertTrackAtIndex(idx, true)
local track = reaper.GetTrack(0, idx)
if track then
    reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "{create_name}", true)
{vol_line}    reaper.TrackList_AdjustWindows(false)
    reaper.UpdateArrange()
    return "✓ Created track: " .. "{create_name}" .. " (index " .. idx .. ")"
end
return "✗ Failed to create track"
'''
    else:
        names = []
        for i in range(count):
            track_name = explicit_names[i] if i < len(explicit_names) else (f"{raw_name} {i+1}" if count > 1 else raw_name)
            names.append(lua_escape_string(track_name))
        name_list = ', '.join([f'"{n}"' for n in names])
        vol_line = f"        {volume_lua}\n" if volume_lua else ""
        return f'''
local count = {count}
local names = {{{name_list}}}
local results = {{}}
for i = 1, count do
    local idx = reaper.GetNumTracks()
    reaper.InsertTrackAtIndex(idx, true)
    local track = reaper.GetTrack(0, idx)
    if track then
        reaper.GetSetMediaTrackInfo_String(track, "P_NAME", names[i], true)
{vol_line}        table.insert(results, names[i] .. " (index " .. idx .. ")")
    end
end
reaper.TrackList_AdjustWindows(false)
reaper.UpdateArrange()
return "✓ Created " .. #results .. " tracks: " .. table.concat(results, ", ")
'''

def generate_delete_track_lua(params):
    selected = params.get('selected', '').lower() in ('true', '1', 'yes')
    if selected:
        return '''
local count = reaper.CountSelectedTracks(0)
if count == 0 then
    return "✗ 没有选中的轨道"
end
local results = {}
for i = count - 1, 0, -1 do
    local track = reaper.GetSelectedTrack(0, i)
    if track then
        local _, name = reaper.GetTrackName(track)
        reaper.DeleteTrack(track)
        table.insert(results, name)
    end
end
reaper.UpdateArrange()
return "✓ Deleted " .. #results .. " selected tracks: " .. table.concat(results, ", ")
'''
    else:
        match_name = lua_escape_string(params.get('match', params.get('contains', params.get('keyword', ''))))
        name_param = lua_escape_string(params.get('name', ''))
        delete_all = _targets_all(params) or str(params.get('multiple', 'false')).lower() in ('true', '1', 'yes')
        if delete_all:
            return '''
local deleted = {}
for i = reaper.CountTracks(0) - 1, 0, -1 do
    local track = reaper.GetTrack(0, i)
    if track then
        local _, name = reaper.GetTrackName(track)
        table.insert(deleted, 1, name ~= "" and name or ("Track " .. tostring(i + 1)))
        reaper.DeleteTrack(track)
    end
end
reaper.UpdateArrange()
return "✓ Deleted " .. tostring(#deleted) .. " track(s): " .. table.concat(deleted, ", ")
'''
        if match_name or name_param:
            keyword = match_name or name_param
            return f'''
local keyword = "{keyword}"
if keyword == "" then
    return "✗ Please provide match/name for track delete"
end
local exact = {{}}
local partial = {{}}
local needle = keyword:lower()
for i = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, i)
    if track then
        local _, name = reaper.GetTrackName(track)
        if name == keyword then
            table.insert(exact, {{index = i, name = name}})
        elseif name:lower():find(needle, 1, true) then
            table.insert(partial, {{index = i, name = name}})
        end
    end
end
local targets = #exact > 0 and exact or partial
if #targets == 0 then
    return "✗ Track not found: " .. keyword
end
local deleted = {{}}
for i = #targets, 1, -1 do
    local track = reaper.GetTrack(0, targets[i].index)
    if track then
        table.insert(deleted, targets[i].name)
        reaper.DeleteTrack(track)
    end
end
reaper.UpdateArrange()
return "Deleted " .. #deleted .. " track(s): " .. table.concat(deleted, ", ")
'''

        lookup = generate_track_lookup_lua(params)
        return f'''
{lookup}
if track then
    local _, name = reaper.GetTrackName(track)
    reaper.DeleteTrack(track)
    reaper.UpdateArrange()
    return "✓ Deleted track: " .. name .. " (index " .. track_index .. ")"
end
return "✗ Track not found: " .. track_label
'''

def generate_rename_track_lua(params):
    guard = guard_track_target_lua(params, 'track/rename', allow_name=False, extra_keys=('old_name', 'from'))
    if guard:
        return guard
    new_name = lua_escape_string(params.get('new_name', params.get('to', params.get('name', 'Unnamed'))))
    if params.get('selected', '').lower() in ('true', '1', 'yes'):
        return f'''
local count = 0
local results = {{}}
for i = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, i)
    if track and reaper.IsTrackSelected(track) then
        local _, old_name = reaper.GetTrackName(track)
        reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "{new_name}", true)
        count = count + 1
        table.insert(results, old_name)
    end
end
reaper.UpdateArrange()
return "✓ Renamed " .. count .. " selected tracks to '{new_name}'"
'''

    lookup_params = dict(params)
    target_name = params.get('target') or params.get('old_name') or params.get('from') or params.get('track_name')
    if target_name:
        lookup_params['name'] = target_name
        lookup_params.pop('index', None)
    elif 'index' in lookup_params:
        lookup_params.pop('name', None)
    else:
        lookup_params.pop('name', None)
    lookup = generate_track_lookup_lua(lookup_params)
    return f'''
{lookup}
if track then
    local _, old_name = reaper.GetTrackName(track)
    reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "{new_name}", true)
    return "✓ Renamed track '" .. old_name .. "' to '" .. "{new_name}" .. "'"
end
return "✗ Track not found: " .. track_label
'''

def generate_set_volume_lua(params):
    guard = guard_track_target_lua(params, 'track/set_volume')
    if guard:
        return guard
    selected = params.get('selected', '').lower() in ('true', '1', 'yes')
    all_tracks = _targets_all(params)
    lookup = generate_track_lookup_lua(params)
    volume = params.get('volume', '0.7')
    volume = parse_volume_to_lua_value(volume)
    if all_tracks:
        return f'''
local count = 0
for i = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, i)
    if track then
        reaper.SetMediaTrackInfo_Value(track, "D_VOL", {volume})
        count = count + 1
    end
end
reaper.UpdateArrange()
local vol_db = 20 * (math.log({volume}) / math.log(10))
return string.format("✓ Set %d track(s) volume to %.1f dB", count, vol_db)
'''
    if selected:
        return f'''
local count = 0
for i = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, i)
    if track and reaper.IsTrackSelected(track) then
        reaper.SetMediaTrackInfo_Value(track, "D_VOL", {volume})
        count = count + 1
    end
end
reaper.UpdateArrange()
local vol_db = 20 * (math.log({volume}) / math.log(10))
return string.format("✓ Set %d selected tracks volume to %.1f dB", count, vol_db)
'''
    return f'''
{lookup}
if track then
    reaper.SetMediaTrackInfo_Value(track, "D_VOL", {volume})
    local vol_db = 20 * (math.log({volume}) / math.log(10))
    return string.format("✓ Set track %s volume to %.1f dB (%.2f)", track_label, vol_db, {volume})
end
return "✗ Track not found: " .. track_label
'''

def generate_set_pan_lua(params):
    guard = guard_track_target_lua(params, 'track/set_pan')
    if guard:
        return guard
    selected = params.get('selected', '').lower() in ('true', '1', 'yes')
    all_tracks = _targets_all(params)
    lookup = generate_track_lookup_lua(params)
    pan = params.get('pan', '0')
    if all_tracks:
        return f'''
local count = 0
for i = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, i)
    if track then
        reaper.SetMediaTrackInfo_Value(track, "D_PAN", {pan})
        count = count + 1
    end
end
reaper.UpdateArrange()
return string.format("✓ Set %d track(s) pan to %.0f%%", count, math.abs({pan}) * 100)
'''
    if selected:
        return f'''
local count = 0
for i = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, i)
    if track and reaper.IsTrackSelected(track) then
        reaper.SetMediaTrackInfo_Value(track, "D_PAN", {pan})
        count = count + 1
    end
end
reaper.UpdateArrange()
return string.format("✓ Set %d selected tracks pan to %.0f%%", count, math.abs({pan}) * 100)
'''
    return f'''
{lookup}
if track then
    reaper.SetMediaTrackInfo_Value(track, "D_PAN", {pan})
    local pan_str = "center"
    if {pan} < -0.1 then pan_str = "left" elseif {pan} > 0.1 then pan_str = "right" end
    return string.format("✓ Set track %s pan to %.0f%% %s", track_label, math.abs({pan}) * 100, pan_str)
end
return "✗ Track not found: " .. track_label
'''

def _generate_track_color_lua(params, color_expr, label, clear_custom=False):
    params = params or {}
    target_value, name_value = _split_batch_target_and_name(
        params,
        ('target', 'track', 'track_name'),
        ('name', 'match')
    )
    start_value = first_nonempty_param(params, ('start', 'from'))
    end_value = first_nonempty_param(params, ('end', 'to'))
    order_value, order_start_value, order_end_value = _batch_order_values(params)
    scope_value = first_nonempty_param(params, ('scope', 'selector', 'target_scope'))
    selected_tracks = (
        _boolish(params.get('selected'))
        or _selected_token(scope_value)
        or _selected_token(params.get('target'))
        or _selected_token(params.get('track'))
    )
    all_tracks = _targets_all(params)
    lua = r'''
local raw_target = "__TARGET__"
local raw_start = "__START__"
local raw_end = "__END__"
local raw_order_target = "__ORDER_TARGET__"
local raw_order_start = "__ORDER_START__"
local raw_order_end = "__ORDER_END__"
local raw_name = "__NAME__"
local set_all = __SET_ALL__
local selected_tracks = __SELECTED_TRACKS__
local color = __COLOR_EXPR__
local color_label = "__COLOR_LABEL__"
local color_mode = "__COLOR_MODE__"

local wanted = {}
local order_wanted = {}
local function trim(s) return tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "") end
local function add_index(n)
    n = tonumber(n)
    if n then wanted[math.floor(n)] = true end
end
local function add_order(n)
    n = tonumber(n)
    if n then order_wanted[math.floor(n)] = true end
end
local function add_range(a, b)
    a = tonumber(a)
    b = tonumber(b)
    if not a or not b then return end
    local lo = math.min(math.floor(a), math.floor(b))
    local hi = math.max(math.floor(a), math.floor(b))
    for idx = lo, hi do wanted[idx] = true end
end
local function add_order_range(a, b)
    a = tonumber(a)
    b = tonumber(b)
    if not a or not b then return end
    local lo = math.min(math.floor(a), math.floor(b))
    local hi = math.max(math.floor(a), math.floor(b))
    for order_idx = lo, hi do order_wanted[order_idx] = true end
end
local function normalize_token(s)
    s = trim(s):gsub("^[Tt]rack%s*", ""):gsub("^track%s*", ""):gsub("[Tt]", "")
    return trim(s)
end
local function parse_text(s, add_single, add_range_fn)
    s = normalize_token(s)
    local a, b = s:match("^(%-?%d+)%s*[%-%~:]%s*(%-?%d+)$")
    if a and b then add_range_fn(a, b); return end
    a, b = s:match("(%-?%d+)%s*[%-%~:]%s*(%-?%d+)")
    if a and b then add_range_fn(a, b) end
    for part in s:gmatch("[^,%s;|]+") do
        local token = normalize_token(part)
        local x, y = token:match("^(%-?%d+)%s*[%-%~:]%s*(%-?%d+)$")
        if x and y then add_range_fn(x, y) else add_single(token) end
    end
end

if trim(raw_start) ~= "" or trim(raw_end) ~= "" then add_range(raw_start, raw_end) end
parse_text(raw_target, add_index, add_range)
if trim(raw_order_start) ~= "" or trim(raw_order_end) ~= "" then add_order_range(raw_order_start, raw_order_end) end
parse_text(raw_order_target, add_order, add_order_range)
local has_indices = false
for _ in pairs(wanted) do has_indices = true; break end
local has_order = false
for _ in pairs(order_wanted) do has_order = true; break end
local name_filter = trim(raw_name)
if not set_all and not selected_tracks and not has_indices and not has_order and name_filter == "" then
    return { ok=false, message="track/set_color requires a track target: selected=true, index/range/ids, order_start/order_end, name/match, or all=true", changed={tracks=0} }
end

local exact_name_exists = false
if name_filter ~= "" then
    for i = 0, reaper.CountTracks(0) - 1 do
        local track = reaper.GetTrack(0, i)
        if track then
            local _, tname = reaper.GetTrackName(track)
            if tname == name_filter then exact_name_exists = true; break end
        end
    end
end

local targets = {}
local needle = name_filter:lower()
for i = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, i)
    if track then
        local _, tname = reaper.GetTrackName(track)
        local order_index = i + 1
        local selected = reaper.IsTrackSelected and reaper.IsTrackSelected(track)
        local by_index = wanted[i] == true
        local by_order = order_wanted[order_index] == true
        local by_name = false
        if name_filter ~= "" then
            if exact_name_exists then
                by_name = tname == name_filter
            else
                by_name = tostring(tname or ""):lower():find(needle, 1, true) ~= nil
            end
        end
        if set_all or by_index or by_order or by_name or (selected_tracks and selected) then
            table.insert(targets, { track=track, index=i, name=tname or "" })
        end
    end
end

local changed = 0
local labels = {}
for _, target in ipairs(targets) do
    if color_mode == "clear" then
        reaper.SetMediaTrackInfo_Value(target.track, "I_CUSTOMCOLOR", 0)
    else
        reaper.SetTrackColor(target.track, color)
    end
    changed = changed + 1
    if #labels < 8 then
        table.insert(labels, (target.name ~= "" and target.name or ("#" .. tostring(target.index))))
    end
end
reaper.TrackList_AdjustWindows(false)
reaper.UpdateArrange()
if changed == 0 then
    return { ok=false, message="No matching track found for track/set_color", changed={tracks=0} }
end
local action = color_mode == "clear" and "Cleared custom color on " or ("Set color to " .. color_label .. " on ")
return { ok=true, message=action .. tostring(changed) .. " track(s): " .. table.concat(labels, ", "), changed={tracks=changed} }
'''
    return (
        lua.replace("__TARGET__", lua_escape_string(target_value))
        .replace("__START__", lua_escape_string(start_value))
        .replace("__END__", lua_escape_string(end_value))
        .replace("__ORDER_TARGET__", lua_escape_string(order_value))
        .replace("__ORDER_START__", lua_escape_string(order_start_value))
        .replace("__ORDER_END__", lua_escape_string(order_end_value))
        .replace("__NAME__", lua_escape_string(name_value))
        .replace("__SET_ALL__", 'true' if all_tracks else 'false')
        .replace("__SELECTED_TRACKS__", 'true' if selected_tracks else 'false')
        .replace("__COLOR_EXPR__", color_expr)
        .replace("__COLOR_LABEL__", lua_escape_string(label or 'color'))
        .replace("__COLOR_MODE__", 'clear' if clear_custom else 'set')
    )

def generate_clear_track_color_lua(params):
    batch_keys = ('range', 'ids', 'id', 'start', 'from', 'end', 'to', 'order', 'order_index', 'order_range', 'order_start', 'order_end', 'match')
    guard = guard_track_target_lua(params, 'track/clear_color', index_key='track', extra_keys=batch_keys)
    if guard:
        return guard
    return _generate_track_color_lua(params, '0', 'default', clear_custom=True)
    selected = params.get('selected', '').lower() in ('true', '1', 'yes')
    all_tracks = _targets_all(params)
    lookup = generate_track_lookup_lua(params, index_key='track')
    if all_tracks:
        return '''
local count = 0
for i = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, i)
    if track then
        reaper.SetMediaTrackInfo_Value(track, "I_CUSTOMCOLOR", 0)
        count = count + 1
    end
end
reaper.TrackList_AdjustWindows(false)
reaper.UpdateArrange()
return "Cleared custom color on " .. count .. " track(s)"
'''
    if selected:
        return '''
local count = 0
for i = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, i)
    if track and reaper.IsTrackSelected(track) then
        reaper.SetMediaTrackInfo_Value(track, "I_CUSTOMCOLOR", 0)
        count = count + 1
    end
end
reaper.TrackList_AdjustWindows(false)
reaper.UpdateArrange()
return "Cleared custom color on " .. count .. " selected track(s)"
'''
    return f'''
{lookup}
if track then
    reaper.SetMediaTrackInfo_Value(track, "I_CUSTOMCOLOR", 0)
    reaper.TrackList_AdjustWindows(false)
    reaper.UpdateArrange()
    return "Cleared custom color on track " .. track_label
end
return "Track not found: " .. track_label
'''

def generate_set_color_lua(params):
    batch_keys = ('range', 'ids', 'id', 'start', 'from', 'end', 'to', 'order', 'order_index', 'order_range', 'order_start', 'order_end', 'match')
    guard = guard_track_target_lua(params, 'track/set_color', index_key='track', extra_keys=batch_keys)
    if guard:
        return guard
    selected = params.get('selected', '').lower() in ('true', '1', 'yes')
    all_tracks = _targets_all(params)
    lookup = generate_track_lookup_lua(params, index_key='track')
    color_raw = params.get('color', params.get('value', params.get('rgb', 'red')))
    color_key = str(color_raw or '').strip().lower()
    clear_color = color_key in ('default', 'clear', 'none', 'reset', 'native', '0', '默认', '默认色', '清除', '清空', '恢复默认')
    r, g, b, label = parse_color_value(color_raw)
    if clear_color:
        return generate_clear_track_color_lua(params)
    color_expr = f'reaper.ColorToNative({r}, {g}, {b}) + 16777216'
    return _generate_track_color_lua(params, color_expr, label, clear_custom=False)
    label = lua_escape_string(label)
    if all_tracks:
        return f'''
local count = 0
local color = {color_expr}
for i = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, i)
    if track then
        reaper.SetTrackColor(track, color)
        count = count + 1
    end
end
reaper.UpdateArrange()
return "✓ Set " .. count .. " track(s) color to {label}"
'''
    if selected:
        return f'''
local count = 0
local color = {color_expr}
for i = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, i)
    if track and reaper.IsTrackSelected(track) then
        reaper.SetTrackColor(track, color)
        count = count + 1
    end
end
reaper.UpdateArrange()
return "✓ Set " .. count .. " selected track(s) color to {label}"
'''
    return f'''
{lookup}
if track then
    local color = {color_expr}
    reaper.SetTrackColor(track, color)
    reaper.UpdateArrange()
    return "✓ Set track " .. track_label .. " color to {label}"
end
return "✗ Track not found: " .. track_label
'''

def generate_mute_track_lua(params):
    guard = guard_track_target_lua(params, 'track/mute')
    if guard:
        return guard
    selected = params.get('selected', '').lower() in ('true', '1', 'yes')
    all_tracks = _targets_all(params)
    lookup = generate_track_lookup_lua(params)
    mute = params.get('mute', 'true')
    value = '1' if mute.lower() in ('true', '1', 'yes') else '0'
    if all_tracks:
        return f'''
local count = 0
for i = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, i)
    if track then
        reaper.SetMediaTrackInfo_Value(track, "B_MUTE", {value})
        count = count + 1
    end
end
reaper.UpdateArrange()
local status = {value} == 1 and "muted" or "unmuted"
return "✓ " .. status .. " " .. count .. " track(s)"
'''
    if selected:
        return f'''
local count = 0
for i = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, i)
    if track and reaper.IsTrackSelected(track) then
        reaper.SetMediaTrackInfo_Value(track, "B_MUTE", {value})
        count = count + 1
    end
end
reaper.UpdateArrange()
local status = {value} == 1 and "muted" or "unmuted"
return "✓ " .. status .. " " .. count .. " selected tracks"
'''
    return f'''
{lookup}
if track then
    reaper.SetMediaTrackInfo_Value(track, "B_MUTE", {value})
    local status = {value} == 1 and "muted" or "unmuted"
    return "✓ Track " .. track_label .. " " .. status
end
return "✗ Track not found: " .. track_label
'''

def generate_solo_track_lua(params):
    guard = guard_track_target_lua(params, 'track/solo')
    if guard:
        return guard
    selected = params.get('selected', '').lower() in ('true', '1', 'yes')
    all_tracks = _targets_all(params)
    lookup = generate_track_lookup_lua(params)
    solo = params.get('solo', 'true')
    value = '1' if solo.lower() in ('true', '1', 'yes') else '0'
    if all_tracks:
        return f'''
local count = 0
for i = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, i)
    if track then
        reaper.SetMediaTrackInfo_Value(track, "I_SOLO", {value})
        count = count + 1
    end
end
reaper.UpdateArrange()
local status = {value} == 1 and "soloed" or "unsoloed"
return "✓ " .. status .. " " .. count .. " track(s)"
'''
    if selected:
        return f'''
local count = 0
for i = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, i)
    if track and reaper.IsTrackSelected(track) then
        reaper.SetMediaTrackInfo_Value(track, "I_SOLO", {value})
        count = count + 1
    end
end
reaper.UpdateArrange()
local status = {value} == 1 and "soloed" or "unsoloed"
return "✓ " .. status .. " " .. count .. " selected tracks"
'''
    return f'''
{lookup}
if track then
    reaper.SetMediaTrackInfo_Value(track, "I_SOLO", {value})
    local status = {value} == 1 and "soloed" or "unsoloed"
    return "✓ Track " .. track_label .. " " .. status
end
return "✗ Track not found: " .. track_label
'''

def generate_add_fx_lua(params):
    guard = guard_track_target_lua(params, 'track/add_fx', index_key='track', allow_name=False)
    if guard:
        return guard
    lookup = generate_track_lookup_lua(params, index_key='track')
    fx_name = lua_escape_string(
        params.get('fx')
        or params.get('fx_name')
        or params.get('name')
        or params.get('effect')
        or params.get('plugin')
        or ''
    )
    return f'''
{lookup}
if not track then return "✗ Track not found: " .. track_label end
if "{fx_name}" == "" then return "✗ FX name is empty" end
local fx = reaper.TrackFX_AddByName(track, "{fx_name}", false, -1)
if fx >= 0 then
    return "✓ Added FX: " .. "{fx_name}" .. " to track " .. track_label
end
return "✗ Failed to add FX: " .. "{fx_name}"
'''

def generate_remove_fx_lua(params):
    guard = guard_track_target_lua(params, 'track/remove_fx', index_key='track', allow_name=False)
    if guard:
        return guard
    lookup = generate_track_lookup_lua(params, index_key='track')
    fx_idx = params.get('fx_index', '0')
    return f'''
{lookup}
if not track then return "✗ Track not found: " .. track_label end
local _, fx_name = reaper.TrackFX_GetFXName(track, {fx_idx}, "")
if reaper.TrackFX_Delete(track, {fx_idx}) then
    return "✓ Removed FX: " .. fx_name .. " from track " .. track_label
end
return "✗ Failed to remove FX from track " .. track_label
'''

def generate_add_marker_lua(params):
    time = params.get('time', '')
    name = lua_escape_string(params.get('name', 'Marker'))
    if not time:
        return f'''
local pos = reaper.GetCursorPosition()
local idx = reaper.AddProjectMarker2(0, false, pos, 0, "{name}", -1, 0)
return "Added marker '" .. "{name}" .. "' at " .. pos .. "s"
'''
    else:
        return f'''
local idx = reaper.AddProjectMarker2(0, false, {time}, 0, "{name}", -1, 0)
return "Added marker '" .. "{name}" .. "' at {time}s"
'''

def generate_delete_marker_lua(params):
    params = params or {}
    idx = str(params.get('index', params.get('target', params.get('marker', params.get('id', '')))) or '').strip()
    ids = str(params.get('ids', '') or '').strip()
    range_value = str(params.get('range', '') or '').strip()
    start_value = str(params.get('start', params.get('from', '')) or '').strip()
    end_value = str(params.get('end', params.get('to', '')) or '').strip()
    name_value = lua_escape_string(params.get('name', params.get('match', '')))
    all_markers = _targets_all(params) or str(params.get('markers', '')).strip().lower() in ('all', '全部', '所有')
    if all_markers or idx or ids or range_value or start_value or end_value or name_value:
        return f'''
local raw_index = "{lua_escape_string(idx)}"
local raw_ids = "{lua_escape_string(ids)}"
local raw_range = "{lua_escape_string(range_value)}"
local raw_start = "{lua_escape_string(start_value)}"
local raw_end = "{lua_escape_string(end_value)}"
local raw_name = "{name_value}"
local delete_all = {str(all_markers).lower()}
local wanted = {{}}
local function trim(s) return tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "") end
local function add_id(n) n = tonumber(n); if n then wanted[math.floor(n)] = true end end
local function add_range(a, b)
    a = tonumber(a); b = tonumber(b)
    if not a or not b then return end
    local lo = math.min(math.floor(a), math.floor(b))
    local hi = math.max(math.floor(a), math.floor(b))
    for id = lo, hi do wanted[id] = true end
end
local function parse_ids(text)
    text = trim(text):gsub("^[Mm]arker%s*", ""):gsub("[Mm]", "")
    local a, b = text:match("^(%-?%d+)%s*[%-%~:]%s*(%-?%d+)$")
    if a and b then add_range(a, b); return end
    for part in text:gmatch("[^,%s;|]+") do
        local x, y = part:match("^(%-?%d+)%s*[%-%~:]%s*(%-?%d+)$")
        if x and y then add_range(x, y) else add_id(part) end
    end
end
if raw_index ~= "" then parse_ids(raw_index) end
if raw_ids ~= "" then parse_ids(raw_ids) end
if raw_range ~= "" then parse_ids(raw_range) end
if raw_start ~= "" or raw_end ~= "" then add_range(raw_start, raw_end) end
local has_wanted = false
for _ in pairs(wanted) do has_wanted = true; break end
local name_filter = trim(raw_name)
if not delete_all and not has_wanted and name_filter == "" then
    return "ERROR: marker/delete requires index, ids, range, name/match, or all=true."
end
local total = reaper.CountProjectMarkers(0)
local targets = {{}}
local needle = name_filter:lower()
for i = 0, total - 1 do
    local retval, isrgn, pos, rgnend, name, markrgnindex = reaper.EnumProjectMarkers3(0, i)
    if retval ~= 0 and not isrgn then
        local id = tonumber(markrgnindex)
        local by_id = id and wanted[id]
        local by_name = name_filter ~= "" and tostring(name or ""):lower():find(needle, 1, true) ~= nil
        if delete_all or by_id or by_name then
            table.insert(targets, {{ id = id, name = name or "" }})
        end
    end
end
table.sort(targets, function(a, b) return (a.id or 0) > (b.id or 0) end)
local deleted = 0
local labels = {{}}
for _, marker in ipairs(targets) do
    if marker.id and reaper.DeleteProjectMarker(0, marker.id, false) then
        deleted = deleted + 1
        if #labels < 8 then table.insert(labels, "M" .. tostring(marker.id)) end
    end
end
reaper.UpdateTimeline()
reaper.UpdateArrange()
if deleted == 0 then return "ERROR: No matching Marker found." end
return "Deleted " .. tostring(deleted) .. " Marker(s): " .. table.concat(labels, ", ")
'''
    return '''
return "ERROR: marker/delete requires explicit marker index, ids, range, name/match, or all=true."
'''

def first_nonempty_param(params, keys):
    params = params or {}
    for key in keys:
        value = params.get(key, '')
        if value is not None and str(value) != '':
            return value
    return ''

def generate_delete_region_lua(params):
    """Delete Region(s) by displayed Region id, id range, ids list, or name match."""
    params = params or {}
    target_value = first_nonempty_param(params, ('range', 'ids', 'index', 'id', 'region', 'target'))
    start_value = first_nonempty_param(params, ('start', 'from'))
    end_value = first_nonempty_param(params, ('end', 'to'))
    order_value = first_nonempty_param(params, ('order_range', 'ordinal_range', 'sequence_range', 'order', 'ordinal', 'sequence', 'order_index', 'ordinal_index', 'sequence_index'))
    order_start_value = first_nonempty_param(params, ('order_start', 'ordinal_start', 'sequence_start'))
    order_end_value = first_nonempty_param(params, ('order_end', 'ordinal_end', 'sequence_end'))
    name_value = first_nonempty_param(params, ('name', 'match'))
    all_regions = _targets_all(params) or str(params.get('regions', '')).strip().lower() in ('all', '全部', '所有')
    target = lua_escape_string(target_value)
    start_id = lua_escape_string(start_value)
    end_id = lua_escape_string(end_value)
    order_target = lua_escape_string(order_value)
    order_start = lua_escape_string(order_start_value)
    order_end = lua_escape_string(order_end_value)
    name = lua_escape_string(name_value)
    delete_all = 'true' if all_regions else 'false'
    lua = r'''
local raw_target = "__TARGET__"
local raw_start = "__START__"
local raw_end = "__END__"
local raw_order_target = "__ORDER_TARGET__"
local raw_order_start = "__ORDER_START__"
local raw_order_end = "__ORDER_END__"
local raw_name = "__NAME__"
local delete_all = __DELETE_ALL__
local wanted = {}
local order_wanted = {}
local function trim(s) return tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "") end
local function add_id(n)
    n = tonumber(n)
    if n then wanted[math.floor(n)] = true end
end
local function add_order(n)
    n = tonumber(n)
    if n then order_wanted[math.floor(n)] = true end
end
local function add_range(a, b)
    a = tonumber(a)
    b = tonumber(b)
    if not a or not b then return end
    a = math.floor(a)
    b = math.floor(b)
    local lo = math.min(a, b)
    local hi = math.max(a, b)
    for id = lo, hi do wanted[id] = true end
end
local function add_order_range(a, b)
    a = tonumber(a)
    b = tonumber(b)
    if not a or not b then return end
    a = math.floor(a)
    b = math.floor(b)
    local lo = math.min(a, b)
    local hi = math.max(a, b)
    for idx = lo, hi do order_wanted[idx] = true end
end
local function normalize_token(s)
    s = trim(s):gsub("^[Rr]egion%s*", ""):gsub("^region%s*", ""):gsub("[Rr]", "")
    return trim(s)
end
local function parse_text(s, add_single, add_range_fn)
    s = normalize_token(s)
    local a, b = s:match("^(%-?%d+)%s*[%-%~:]%s*(%-?%d+)$")
    if a and b then add_range_fn(a, b); return end
    a, b = s:match("(%-?%d+)%s*[%-%~:]%s*(%-?%d+)")
    if a and b then add_range_fn(a, b) end
    for part in s:gmatch("[^,%s;|]+") do
        local token = normalize_token(part)
        local x, y = token:match("^(%-?%d+)%s*[%-%~:]%s*(%-?%d+)$")
        if x and y then add_range_fn(x, y) else add_single(token) end
    end
end
if trim(raw_start) ~= "" or trim(raw_end) ~= "" then add_range(raw_start, raw_end) end
parse_text(raw_target, add_id, add_range)
if trim(raw_order_start) ~= "" or trim(raw_order_end) ~= "" then add_order_range(raw_order_start, raw_order_end) end
parse_text(raw_order_target, add_order, add_order_range)
local has_ids = false
for _ in pairs(wanted) do has_ids = true; break end
local has_order = false
for _ in pairs(order_wanted) do has_order = true; break end
local name_filter = trim(raw_name)
if not delete_all and not has_ids and not has_order and name_filter == "" then
    return { ok=false, message="region/delete requires index, range, ids, start/end, order_start/order_end, name, match, or all=true" }
end
local function enum_marker(i)
    if reaper.EnumProjectMarkers3 then return reaper.EnumProjectMarkers3(0, i) end
    return reaper.EnumProjectMarkers(i)
end
local marker_total = reaper.CountProjectMarkers(0)
local regions = {}
for i = 0, marker_total - 1 do
    local retval, isrgn, pos, rgnend, rname, markrgnindex = enum_marker(i)
    if retval ~= 0 and isrgn then
        table.insert(regions, { id=tonumber(markrgnindex), name=rname or "", pos=pos or 0, rgnend=rgnend or 0 })
    end
end
table.sort(regions, function(a, b)
    if (a.pos or 0) ~= (b.pos or 0) then return (a.pos or 0) < (b.pos or 0) end
    if (a.rgnend or 0) ~= (b.rgnend or 0) then return (a.rgnend or 0) < (b.rgnend or 0) end
    return (a.id or 0) < (b.id or 0)
end)
local targets = {}

local needle = name_filter:lower()
for order_index, region in ipairs(regions) do
    local id = tonumber(region.id)
    local by_id = id and wanted[id]
    local by_order = order_wanted[order_index] == true
    local by_name = name_filter ~= "" and tostring(region.name or ""):lower():find(needle, 1, true) ~= nil
    if delete_all or by_id or by_order or by_name then
        table.insert(targets, region)
    end
end
table.sort(targets, function(a, b) return (a.id or 0) > (b.id or 0) end)
local deleted = 0
local labels = {}
for _, region in ipairs(targets) do
    if region.id and reaper.DeleteProjectMarker(0, region.id, true) then
        deleted = deleted + 1
        if #labels < 8 then table.insert(labels, "R" .. tostring(region.id)) end
    end
end
reaper.UpdateTimeline()
reaper.UpdateArrange()
if deleted == 0 then
    return { ok=false, message="No matching Region found", changed={deleted=0} }
end
return { ok=true, message="Deleted " .. tostring(deleted) .. " Region(s): " .. table.concat(labels, ", "), changed={deleted=deleted} }
'''
    return (
        lua.replace("__TARGET__", target)
        .replace("__START__", start_id)
        .replace("__END__", end_id)
        .replace("__ORDER_TARGET__", order_target)
        .replace("__ORDER_START__", order_start)
        .replace("__ORDER_END__", order_end)
        .replace("__NAME__", name)
        .replace("__DELETE_ALL__", delete_all)
    )

def generate_set_region_color_lua(params):
    """Set Region color only. Markers are never targeted by this endpoint."""
    params = params or {}
    target_value = first_nonempty_param(params, ('range', 'ids', 'index', 'id', 'region', 'target'))
    start_value = first_nonempty_param(params, ('start', 'from'))
    end_value = first_nonempty_param(params, ('end', 'to'))
    order_value = first_nonempty_param(params, ('order_range', 'ordinal_range', 'sequence_range', 'order', 'ordinal', 'sequence', 'order_index', 'ordinal_index', 'sequence_index'))
    order_start_value = first_nonempty_param(params, ('order_start', 'ordinal_start', 'sequence_start'))
    order_end_value = first_nonempty_param(params, ('order_end', 'to_order', 'ordinal_end', 'sequence_end'))
    name_value = first_nonempty_param(params, ('name', 'match'))
    scope_value = first_nonempty_param(params, ('scope', 'selector', 'target_scope'))
    current_region = _boolish(params.get('current')) or str(scope_value).strip().lower() in ('current', 'cursor', 'edit_cursor', '光标', '当前')
    time_selection_regions = _boolish(params.get('time_selection')) or str(scope_value).strip().lower() in ('time_selection', 'time-selection', 'timerange', 'time_range', 'loop_selection', '时间选区')
    selected_regions = _boolish(params.get('selected')) or (str(scope_value).strip().lower() in ('selected', 'selection', 'current_selection', '选中', '已选中') and not current_region and not time_selection_regions)
    all_regions = _targets_all(params) or str(params.get('regions', '')).strip().lower() in ('all', '全部', '所有')
    color_raw = params.get('color', params.get('value', params.get('rgb', '')))
    color_key = str(color_raw or '').strip().lower()
    clear_color = color_key in ('default', 'clear', 'none', 'reset', 'native', '0',
                                '默认', '默认色', '清除', '清空', '恢复默认')
    r, g, b, label = parse_color_value(color_raw)
    color_expr = '0' if clear_color else f'reaper.ColorToNative({r}, {g}, {b}) + 16777216'
    if clear_color:
        label = 'default'
    target = lua_escape_string(target_value)
    start_id = lua_escape_string(start_value)
    end_id = lua_escape_string(end_value)
    order_target = lua_escape_string(order_value)
    order_start = lua_escape_string(order_start_value)
    order_end = lua_escape_string(order_end_value)
    name = lua_escape_string(name_value)
    scope = lua_escape_string(scope_value)
    label = lua_escape_string(label or color_raw or 'color')
    lua = r'''
local raw_target = "__TARGET__"
local raw_start = "__START__"
local raw_end = "__END__"
local raw_order_target = "__ORDER_TARGET__"
local raw_order_start = "__ORDER_START__"
local raw_order_end = "__ORDER_END__"
local raw_name = "__NAME__"
local raw_scope = "__SCOPE__"
local set_all = __SET_ALL__
local selected_regions = __SELECTED_REGIONS__
local current_region = __CURRENT_REGION__
local time_selection_regions = __TIME_SELECTION_REGIONS__
local color = __COLOR_EXPR__
local color_label = "__COLOR_LABEL__"
local EPS = 0.001

local wanted = {}
local order_wanted = {}
local function trim(s) return tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "") end
local function add_id(n)
    n = tonumber(n)
    if n then wanted[math.floor(n)] = true end
end
local function add_order(n)
    n = tonumber(n)
    if n then order_wanted[math.floor(n)] = true end
end
local function add_range(a, b)
    a = tonumber(a)
    b = tonumber(b)
    if not a or not b then return end
    a = math.floor(a)
    b = math.floor(b)
    local lo = math.min(a, b)
    local hi = math.max(a, b)
    for id = lo, hi do wanted[id] = true end
end
local function add_order_range(a, b)
    a = tonumber(a)
    b = tonumber(b)
    if not a or not b then return end
    a = math.floor(a)
    b = math.floor(b)
    local lo = math.min(a, b)
    local hi = math.max(a, b)
    for idx = lo, hi do order_wanted[idx] = true end
end
local function normalize_token(s)
    s = trim(s):gsub("^[Rr]egion%s*", ""):gsub("^region%s*", ""):gsub("[Rr]", "")
    return trim(s)
end
local function parse_text(s, add_single, add_range_fn)
    s = normalize_token(s)
    local a, b = s:match("^(%-?%d+)%s*[%-%~:]%s*(%-?%d+)$")
    if a and b then add_range_fn(a, b); return end
    a, b = s:match("(%-?%d+)%s*[%-%~:]%s*(%-?%d+)")
    if a and b then add_range_fn(a, b) end
    for part in s:gmatch("[^,%s;|]+") do
        local token = normalize_token(part)
        local x, y = token:match("^(%-?%d+)%s*[%-%~:]%s*(%-?%d+)$")
        if x and y then add_range_fn(x, y) else add_single(token) end
    end
end
local function close_enough(a, b)
    return math.abs((tonumber(a) or 0) - (tonumber(b) or 0)) <= EPS
end
local function ranges_overlap(a_start, a_end, b_start, b_end)
    a_start = tonumber(a_start) or 0
    a_end = tonumber(a_end) or 0
    b_start = tonumber(b_start) or 0
    b_end = tonumber(b_end) or 0
    return a_end > b_start + EPS and a_start < b_end - EPS
end
local function enum_region_source(i)
    if reaper.EnumProjectMarkers3 then return reaper.EnumProjectMarkers3(0, i) end
    return reaper.EnumProjectMarkers(i)
end
if not reaper.SetProjectMarker3 then
    return { ok=false, message="region/set_color requires reaper.SetProjectMarker3", changed={regions=0} }
end

if trim(raw_start) ~= "" or trim(raw_end) ~= "" then add_range(raw_start, raw_end) end
parse_text(raw_target, add_id, add_range)
if trim(raw_order_start) ~= "" or trim(raw_order_end) ~= "" then add_order_range(raw_order_start, raw_order_end) end
parse_text(raw_order_target, add_order, add_order_range)
local has_ids = false
for _ in pairs(wanted) do has_ids = true; break end
local has_order = false
for _ in pairs(order_wanted) do has_order = true; break end
local name_filter = trim(raw_name)
local contextual = selected_regions or current_region or time_selection_regions
if not set_all and not contextual and not has_ids and not has_order and name_filter == "" then
    return { ok=false, message="region/set_color requires color and a Region target: selected=true, scope=current/time_selection, index, range, ids, name, match, or all=true", changed={regions=0} }
end

local _, marker_count, region_count = reaper.CountProjectMarkers(0)
local total = (tonumber(marker_count) or 0) + (tonumber(region_count) or 0)
local regions = {}
for i = 0, total - 1 do
    local retval, isrgn, pos, rgnend, rname, markrgnindex = enum_region_source(i)
    if retval ~= 0 and isrgn then
        table.insert(regions, { id=tonumber(markrgnindex), name=rname or "", pos=pos or 0, rgnend=rgnend or 0 })
    end
end
table.sort(regions, function(a, b)
    if (a.pos or 0) ~= (b.pos or 0) then return (a.pos or 0) < (b.pos or 0) end
    if (a.rgnend or 0) ~= (b.rgnend or 0) then return (a.rgnend or 0) < (b.rgnend or 0) end
    return (a.id or 0) < (b.id or 0)
end)

local ts_active, ts_start, ts_end = false, 0, 0
if reaper.GetSet_LoopTimeRange then
    ts_start, ts_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
    ts_start = tonumber(ts_start) or 0
    ts_end = tonumber(ts_end) or 0
    ts_active = ts_end > ts_start + EPS
end
local cursor = reaper.GetCursorPosition and (tonumber(reaper.GetCursorPosition()) or 0) or 0
local targets = {}
local needle = name_filter:lower()
for order_index, region in ipairs(regions) do
    local id = tonumber(region.id)
    local by_id = id and wanted[id]
    local by_order = order_wanted[order_index] == true
    local by_name = name_filter ~= "" and tostring(region.name or ""):lower():find(needle, 1, true) ~= nil
    local in_time = ts_active and ranges_overlap(region.pos, region.rgnend, ts_start, ts_end)
    local inferred_selected = ts_active and (
        (close_enough(region.pos, ts_start) and close_enough(region.rgnend, ts_end)) or
        (region.pos >= ts_start - EPS and region.rgnend <= ts_end + EPS) or
        in_time
    )
    local at_cursor = cursor >= (region.pos or 0) - EPS and cursor <= (region.rgnend or 0) + EPS
    if set_all or by_id or by_order or by_name or
       (selected_regions and inferred_selected) or
       (time_selection_regions and in_time) or
       (current_region and at_cursor) then
        table.insert(targets, region)
    end
end

local changed = 0
local labels = {}
for _, region in ipairs(targets) do
    if region.id then
        local ok = reaper.SetProjectMarker3(0, region.id, true, region.pos, region.rgnend, region.name, color)
        if ok then
            changed = changed + 1
            if #labels < 8 then table.insert(labels, "R" .. tostring(region.id)) end
        end
    end
end
reaper.UpdateTimeline()
reaper.UpdateArrange()
if changed == 0 then
    return { ok=false, message="No matching Region found for region/set_color", changed={regions=0} }
end
return { ok=true, message="Set " .. tostring(changed) .. " Region(s) color to " .. color_label .. ": " .. table.concat(labels, ", "), changed={regions=changed} }
'''
    return (
        lua.replace("__TARGET__", target)
        .replace("__START__", start_id)
        .replace("__END__", end_id)
        .replace("__ORDER_TARGET__", order_target)
        .replace("__ORDER_START__", order_start)
        .replace("__ORDER_END__", order_end)
        .replace("__NAME__", name)
        .replace("__SCOPE__", scope)
        .replace("__SET_ALL__", 'true' if all_regions else 'false')
        .replace("__SELECTED_REGIONS__", 'true' if selected_regions else 'false')
        .replace("__CURRENT_REGION__", 'true' if current_region else 'false')
        .replace("__TIME_SELECTION_REGIONS__", 'true' if time_selection_regions else 'false')
        .replace("__COLOR_EXPR__", color_expr)
        .replace("__COLOR_LABEL__", label)
    )

def generate_set_item_color_lua(params):
    """Set MediaItem color only. This does not modify takes, tracks, Regions, or Markers."""
    params = params or {}
    scope_value = first_nonempty_param(params, ('scope', 'selector', 'target_scope'))
    target_value = first_nonempty_param(params, ('index', 'item', 'target'))
    name_value = first_nonempty_param(params, ('name', 'match', 'item_name'))
    current_item = _boolish(params.get('current')) or str(scope_value).strip().lower() in ('current', 'cursor', 'edit_cursor', '光标', '当前')
    time_selection_items = _boolish(params.get('time_selection')) or str(scope_value).strip().lower() in ('time_selection', 'time-selection', 'timerange', 'time_range', 'loop_selection', '时间选区')
    selected_items = _boolish(params.get('selected')) or ((_selected_token(scope_value) or _selected_token(params.get('target')) or _selected_token(params.get('item'))) and not current_item and not time_selection_items)
    all_items = _targets_all(params) or _all_token(params.get('items', ''))
    color_raw = params.get('color', params.get('value', params.get('rgb', '')))
    color_key = str(color_raw or '').strip().lower()
    clear_color = color_key in ('default', 'clear', 'none', 'reset', 'native', '0',
                                '默认', '默认色', '清除', '清空', '恢复默认')
    r, g, b, label = parse_color_value(color_raw)
    color_expr = '0' if clear_color else f'reaper.ColorToNative({r}, {g}, {b}) + 16777216'
    if clear_color:
        label = 'default'
    target = lua_escape_string(target_value)
    name = lua_escape_string(name_value)
    scope = lua_escape_string(scope_value)
    label = lua_escape_string(label or color_raw or 'color')
    lua = r'''
local raw_target = "__TARGET__"
local raw_name = "__NAME__"
local raw_scope = "__SCOPE__"
local set_all = __SET_ALL__
local selected_items = __SELECTED_ITEMS__
local current_item = __CURRENT_ITEM__
local time_selection_items = __TIME_SELECTION_ITEMS__
local color = __COLOR_EXPR__
local color_label = "__COLOR_LABEL__"
local EPS = 0.001

local function trim(s) return tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "") end
local function ranges_overlap(a_start, a_end, b_start, b_end)
    a_start = tonumber(a_start) or 0
    a_end = tonumber(a_end) or 0
    b_start = tonumber(b_start) or 0
    b_end = tonumber(b_end) or 0
    return a_end > b_start + EPS and a_start < b_end - EPS
end
local function item_name(item)
    local take = item and reaper.GetActiveTake(item)
    if take and reaper.GetTakeName then return reaper.GetTakeName(take) or "" end
    return ""
end
local function target_index(raw)
    raw = trim(raw):gsub("^[Ii]tem%s*", ""):gsub("[Ii]", "")
    local n = tonumber(raw)
    if not n then return nil end
    return math.floor(n)
end

local wanted_index = target_index(raw_target)
local name_filter = trim(raw_name)
local contextual = selected_items or current_item or time_selection_items
if not set_all and not contextual and wanted_index == nil and name_filter == "" then
    return { ok=false, message="item/set_color requires color and an item target: selected=true, scope=current/time_selection, index, name, match, or all=true", changed={items=0} }
end

local ts_active, ts_start, ts_end = false, 0, 0
if reaper.GetSet_LoopTimeRange then
    ts_start, ts_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
    ts_start = tonumber(ts_start) or 0
    ts_end = tonumber(ts_end) or 0
    ts_active = ts_end > ts_start + EPS
end
local cursor = reaper.GetCursorPosition and (tonumber(reaper.GetCursorPosition()) or 0) or 0
local needle = name_filter:lower()
local targets = {}
for i = 0, reaper.CountMediaItems(0) - 1 do
    local item = reaper.GetMediaItem(0, i)
    if item then
        local selected = reaper.IsMediaItemSelected and reaper.IsMediaItemSelected(item)
        local pos = tonumber(reaper.GetMediaItemInfo_Value(item, "D_POSITION")) or 0
        local len = tonumber(reaper.GetMediaItemInfo_Value(item, "D_LENGTH")) or 0
        local item_end = pos + len
        local in_time = ts_active and ranges_overlap(pos, item_end, ts_start, ts_end)
        local at_cursor = cursor >= pos - EPS and cursor <= item_end + EPS
        local by_name = name_filter ~= "" and item_name(item):lower():find(needle, 1, true) ~= nil
        if set_all or
           (wanted_index ~= nil and i == wanted_index) or
           (selected_items and selected) or
           (time_selection_items and in_time) or
           (current_item and at_cursor) or
           by_name then
            table.insert(targets, item)
        end
    end
end

local changed = 0
for _, item in ipairs(targets) do
    reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", color)
    if reaper.UpdateItemInProject then reaper.UpdateItemInProject(item) end
    changed = changed + 1
end
reaper.UpdateArrange()
if changed == 0 then
    return { ok=false, message="No matching item found for item/set_color", changed={items=0} }
end
return { ok=true, message="Set " .. tostring(changed) .. " item(s) color to " .. color_label, changed={items=changed} }
'''
    return (
        lua.replace("__TARGET__", target)
        .replace("__NAME__", name)
        .replace("__SCOPE__", scope)
        .replace("__SET_ALL__", 'true' if all_items else 'false')
        .replace("__SELECTED_ITEMS__", 'true' if selected_items else 'false')
        .replace("__CURRENT_ITEM__", 'true' if current_item else 'false')
        .replace("__TIME_SELECTION_ITEMS__", 'true' if time_selection_items else 'false')
        .replace("__COLOR_EXPR__", color_expr)
        .replace("__COLOR_LABEL__", label)
    )

def generate_set_item_color_lua(params):
    """Set MediaItem color only. Supports batch index/range/order selectors."""
    params = params or {}
    scope_value = first_nonempty_param(params, ('scope', 'selector', 'target_scope'))
    target_value, name_value = _split_batch_target_and_name(
        params,
        ('item', 'target'),
        ('name', 'match', 'item_name')
    )
    start_value = first_nonempty_param(params, ('start', 'from'))
    end_value = first_nonempty_param(params, ('end', 'to'))
    order_value, order_start_value, order_end_value = _batch_order_values(params)
    scope_norm = str(scope_value or '').strip().lower()
    current_item = _boolish(params.get('current')) or scope_norm in ('current', 'cursor', 'edit_cursor', '光标', '当前')
    time_selection_items = _boolish(params.get('time_selection')) or scope_norm in ('time_selection', 'time-selection', 'timerange', 'time_range', 'loop_selection', '时间选区')
    selected_items = _boolish(params.get('selected')) or ((_selected_token(scope_value) or _selected_token(params.get('target')) or _selected_token(params.get('item'))) and not current_item and not time_selection_items)
    all_items = _targets_all(params) or _all_token(params.get('items', ''))
    color_raw = params.get('color', params.get('value', params.get('rgb', '')))
    color_key = str(color_raw or '').strip().lower()
    clear_color = color_key in ('default', 'clear', 'none', 'reset', 'native', '0',
                                '默认', '默认色', '清除', '清空', '恢复默认')
    r, g, b, label = parse_color_value(color_raw)
    color_expr = '0' if clear_color else f'reaper.ColorToNative({r}, {g}, {b}) + 16777216'
    if clear_color:
        label = 'default'
    lua = r'''
local raw_target = "__TARGET__"
local raw_start = "__START__"
local raw_end = "__END__"
local raw_order_target = "__ORDER_TARGET__"
local raw_order_start = "__ORDER_START__"
local raw_order_end = "__ORDER_END__"
local raw_name = "__NAME__"
local raw_scope = "__SCOPE__"
local set_all = __SET_ALL__
local selected_items = __SELECTED_ITEMS__
local current_item = __CURRENT_ITEM__
local time_selection_items = __TIME_SELECTION_ITEMS__
local color = __COLOR_EXPR__
local color_label = "__COLOR_LABEL__"
local EPS = 0.001

local wanted = {}
local order_wanted = {}
local function trim(s) return tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "") end
local function add_index(n)
    n = tonumber(n)
    if n then wanted[math.floor(n)] = true end
end
local function add_order(n)
    n = tonumber(n)
    if n then order_wanted[math.floor(n)] = true end
end
local function add_range(a, b)
    a = tonumber(a)
    b = tonumber(b)
    if not a or not b then return end
    local lo = math.min(math.floor(a), math.floor(b))
    local hi = math.max(math.floor(a), math.floor(b))
    for idx = lo, hi do wanted[idx] = true end
end
local function add_order_range(a, b)
    a = tonumber(a)
    b = tonumber(b)
    if not a or not b then return end
    local lo = math.min(math.floor(a), math.floor(b))
    local hi = math.max(math.floor(a), math.floor(b))
    for order_idx = lo, hi do order_wanted[order_idx] = true end
end
local function normalize_token(s)
    s = trim(s):gsub("^[Ii]tem%s*", ""):gsub("^item%s*", ""):gsub("[Ii]", "")
    return trim(s)
end
local function parse_text(s, add_single, add_range_fn)
    s = normalize_token(s)
    local a, b = s:match("^(%-?%d+)%s*[%-%~:]%s*(%-?%d+)$")
    if a and b then add_range_fn(a, b); return end
    a, b = s:match("(%-?%d+)%s*[%-%~:]%s*(%-?%d+)")
    if a and b then add_range_fn(a, b) end
    for part in s:gmatch("[^,%s;|]+") do
        local token = normalize_token(part)
        local x, y = token:match("^(%-?%d+)%s*[%-%~:]%s*(%-?%d+)$")
        if x and y then add_range_fn(x, y) else add_single(token) end
    end
end
local function ranges_overlap(a_start, a_end, b_start, b_end)
    a_start = tonumber(a_start) or 0
    a_end = tonumber(a_end) or 0
    b_start = tonumber(b_start) or 0
    b_end = tonumber(b_end) or 0
    return a_end > b_start + EPS and a_start < b_end - EPS
end
local function item_name(item)
    local take = item and reaper.GetActiveTake(item)
    if take and reaper.GetTakeName then return reaper.GetTakeName(take) or "" end
    return ""
end

if trim(raw_start) ~= "" or trim(raw_end) ~= "" then add_range(raw_start, raw_end) end
parse_text(raw_target, add_index, add_range)
if trim(raw_order_start) ~= "" or trim(raw_order_end) ~= "" then add_order_range(raw_order_start, raw_order_end) end
parse_text(raw_order_target, add_order, add_order_range)
local has_indices = false
for _ in pairs(wanted) do has_indices = true; break end
local has_order = false
for _ in pairs(order_wanted) do has_order = true; break end
local name_filter = trim(raw_name)
local contextual = selected_items or current_item or time_selection_items
if not set_all and not contextual and not has_indices and not has_order and name_filter == "" then
    return { ok=false, message="item/set_color requires color and an item target: selected=true, scope=current/time_selection, index/range/ids, order_start/order_end, name, match, or all=true", changed={items=0} }
end

local ts_active, ts_start, ts_end = false, 0, 0
if reaper.GetSet_LoopTimeRange then
    ts_start, ts_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
    ts_start = tonumber(ts_start) or 0
    ts_end = tonumber(ts_end) or 0
    ts_active = ts_end > ts_start + EPS
end
local cursor = reaper.GetCursorPosition and (tonumber(reaper.GetCursorPosition()) or 0) or 0
local needle = name_filter:lower()
local targets = {}
for i = 0, reaper.CountMediaItems(0) - 1 do
    local item = reaper.GetMediaItem(0, i)
    if item then
        local selected = reaper.IsMediaItemSelected and reaper.IsMediaItemSelected(item)
        local pos = tonumber(reaper.GetMediaItemInfo_Value(item, "D_POSITION")) or 0
        local len = tonumber(reaper.GetMediaItemInfo_Value(item, "D_LENGTH")) or 0
        local item_end = pos + len
        local order_index = i + 1
        local in_time = ts_active and ranges_overlap(pos, item_end, ts_start, ts_end)
        local at_cursor = cursor >= pos - EPS and cursor <= item_end + EPS
        local by_name = name_filter ~= "" and item_name(item):lower():find(needle, 1, true) ~= nil
        if set_all or
           wanted[i] == true or
           order_wanted[order_index] == true or
           (selected_items and selected) or
           (time_selection_items and in_time) or
           (current_item and at_cursor) or
           by_name then
            table.insert(targets, item)
        end
    end
end

local changed = 0
for _, item in ipairs(targets) do
    reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", color)
    if reaper.UpdateItemInProject then reaper.UpdateItemInProject(item) end
    changed = changed + 1
end
reaper.UpdateArrange()
if changed == 0 then
    return { ok=false, message="No matching item found for item/set_color", changed={items=0} }
end
return { ok=true, message="Set " .. tostring(changed) .. " item(s) color to " .. color_label, changed={items=changed} }
'''
    return (
        lua.replace("__TARGET__", lua_escape_string(target_value))
        .replace("__START__", lua_escape_string(start_value))
        .replace("__END__", lua_escape_string(end_value))
        .replace("__ORDER_TARGET__", lua_escape_string(order_value))
        .replace("__ORDER_START__", lua_escape_string(order_start_value))
        .replace("__ORDER_END__", lua_escape_string(order_end_value))
        .replace("__NAME__", lua_escape_string(name_value))
        .replace("__SCOPE__", lua_escape_string(scope_value))
        .replace("__SET_ALL__", 'true' if all_items else 'false')
        .replace("__SELECTED_ITEMS__", 'true' if selected_items else 'false')
        .replace("__CURRENT_ITEM__", 'true' if current_item else 'false')
        .replace("__TIME_SELECTION_ITEMS__", 'true' if time_selection_items else 'false')
        .replace("__COLOR_EXPR__", color_expr)
        .replace("__COLOR_LABEL__", lua_escape_string(label or color_raw or 'color'))
    )

def _bool_param(value):
    return str(value).lower() in ('true', '1', 'yes', 'y', 'on')

def _float_param(params, keys, default):
    for key in keys:
        value = params.get(key, '')
        if value != '':
            try:
                return float(value)
            except (TypeError, ValueError):
                pass
    return default

def _int_param(params, keys, default):
    for key in keys:
        value = params.get(key, '')
        if value != '':
            try:
                return int(float(value))
            except (TypeError, ValueError):
                pass
    return default

def _time_param_seconds(params, keys):
    for key in keys:
        value = params.get(key, '')
        if value == '':
            continue
        text = str(value).strip().lower()
        assume_ms = key.endswith('_ms') or key in ('ms', 'in_ms', 'out_ms')
        try:
            if text.endswith('ms'):
                seconds = float(text[:-2].strip()) / 1000.0
            elif text.endswith('s'):
                seconds = float(text[:-1].strip())
            else:
                seconds = float(text)
                if assume_ms:
                    seconds = seconds / 1000.0
            return max(0.0, seconds)
        except (TypeError, ValueError):
            continue
    return None

def _fade_shape_param(params, keys, default=0):
    aliases = {
        'linear': 0,
        'line': 0,
        'straight': 0,
        'default': 0,
        '直线': 0,
        '线性': 0,
        'curve': 0,
        'curved': 0,
    }
    for key in keys:
        value = params.get(key, '')
        if value == '':
            continue
        text = str(value).strip().lower()
        if text in aliases:
            return aliases[text]
        try:
            return max(0, min(6, int(float(text))))
        except (TypeError, ValueError):
            continue
    return default

def generate_item_fade_lua(params):
    """Set media item fade-in/fade-out lengths without writing envelopes."""
    selected_tokens = ('selected', 'selection', 'current', '当前', '选中', '已选中')
    item_raw = str(params.get('item', params.get('target', ''))).strip()
    index_raw = str(params.get('index', '')).strip()
    name_raw = str(params.get('name', params.get('match', params.get('item_name', '')))).strip()

    if item_raw.lower() in selected_tokens:
        selected = True
        item_raw = ''
    else:
        selected = _bool_param(params.get('selected', 'false')) or str(params.get('target', '')).lower() in selected_tokens

    if not index_raw and item_raw and _is_int_string(item_raw):
        index_raw = item_raw
    elif not name_raw and item_raw and item_raw:
        name_raw = item_raw

    if not selected and not index_raw and not name_raw:
        return '''
return "ERROR: item/fade requires an explicit item target: selected=true, index, item, target, or name."
'''

    fade_in = _time_param_seconds(params, ('fade_in', 'in', 'fadein', 'fade_in_s', 'in_s', 'fade_in_sec', 'in_sec', 'fade_in_ms', 'in_ms'))
    fade_out = _time_param_seconds(params, ('fade_out', 'out', 'fadeout', 'fade_out_s', 'out_s', 'fade_out_sec', 'out_sec', 'fade_out_ms', 'out_ms'))

    selected_lua = 'true' if selected else 'false'
    fade_in_lua = 'nil' if fade_in is None else f'{fade_in:.9f}'
    fade_out_lua = 'nil' if fade_out is None else f'{fade_out:.9f}'
    index_lua = lua_escape_string(index_raw)
    name_lua = lua_escape_string(name_raw)

    return f'''
local selected = {selected_lua}
local target_index = "{index_lua}"
local target_name = "{name_lua}"
local fade_in = {fade_in_lua}
local fade_out = {fade_out_lua}

if fade_in == nil and fade_out == nil then
    return "✗ 请提供 fade_in/fade_out 或 fade_in_ms/fade_out_ms"
end

local function lower(s)
    return tostring(s or ""):lower()
end

local function take_name(item)
    local take = item and reaper.GetActiveTake(item)
    return take and (reaper.GetTakeName(take) or "") or ""
end

local function item_label(item, fallback)
    local name = take_name(item)
    if name ~= "" then return name end
    return fallback or "item"
end

local function collect_named_item(name)
    local exact, partial = nil, nil
    local needle = lower(name)
    for i = 0, reaper.CountMediaItems(0) - 1 do
        local item = reaper.GetMediaItem(0, i)
        local candidate = take_name(item)
        if candidate == name then
            exact = item
            break
        elseif not partial and lower(candidate):find(needle, 1, true) then
            partial = item
        end
    end
    return exact or partial
end

local targets = {{}}
if selected then
    local count = reaper.CountSelectedMediaItems(0)
    if count == 0 then
        return "✗ 没有选中的 item"
    end
    for i = 0, count - 1 do
        local item = reaper.GetSelectedMediaItem(0, i)
        if item then
            table.insert(targets, {{ item = item, label = item_label(item, "selected item " .. tostring(i + 1)) }})
        end
    end
elseif target_index ~= "" then
    local item = reaper.GetMediaItem(0, tonumber(target_index) or -1)
    if not item then
        return "✗ Item not found: #" .. target_index
    end
    table.insert(targets, {{ item = item, label = item_label(item, "#" .. target_index) }})
elseif target_name ~= "" then
    local item = collect_named_item(target_name)
    if not item then
        return "✗ Item not found: " .. target_name
    end
    table.insert(targets, {{ item = item, label = item_label(item, target_name) }})
else
    return "✗ 请提供 selected=true 或 index/name"
end

local changed = 0
local labels = {{}}
for _, target in ipairs(targets) do
    local item = target.item
    if item then
        if fade_in ~= nil then
            reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN", fade_in)
        end
        if fade_out ~= nil then
            reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", fade_out)
        end
        reaper.UpdateItemInProject(item)
        changed = changed + 1
        if #labels < 5 then
            table.insert(labels, target.label)
        end
    end
end

if changed == 0 then
    return "✗ 没有匹配到 item"
end

local parts = {{}}
if fade_in ~= nil then
    table.insert(parts, string.format("淡入 %.0fms", fade_in * 1000))
end
if fade_out ~= nil then
    table.insert(parts, string.format("淡出 %.0fms", fade_out * 1000))
end
reaper.UpdateArrange()

local suffix = ""
if #labels > 0 then
    suffix = ": " .. table.concat(labels, ", ")
    if changed > #labels then
        suffix = suffix .. " ..."
    end
end
return "✓ 已设置 " .. changed .. " 个 item 的 " .. table.concat(parts, "、") .. suffix
'''

def generate_item_fade_shape_lua(params):
    """Set media item fade shape and curvature with read-back verification."""
    item_raw = str(params.get('item', params.get('target', ''))).strip()
    index_raw = str(params.get('index', '')).strip()
    name_raw = str(params.get('name', params.get('match', params.get('item_name', '')))).strip()
    all_raw = str(params.get('all', params.get('all_items', params.get('target', '')))).strip().lower()
    all_items = _bool_param(params.get('all', params.get('all_items', 'false'))) or all_raw in ('all', 'everything', '全部', '所有')

    if _selected_token(item_raw):
        selected = True
        item_raw = ''
    else:
        selected = _bool_param(params.get('selected', 'false')) or _selected_token(params.get('target', ''))

    if not index_raw and item_raw and _is_int_string(item_raw):
        index_raw = item_raw
    elif not name_raw and item_raw and not _selected_token(item_raw) and item_raw.lower() not in ('all', 'everything', '全部', '所有'):
        name_raw = item_raw

    if not all_items and not selected and not index_raw and not name_raw:
        return '''
return "ERROR: item/fade_shape requires an explicit item target: selected=true, all=true, index, item, target, or name."
'''

    direction = str(params.get('direction', params.get('side', params.get('fade', 'both')))).strip().lower()
    apply_in = direction not in ('out', 'fade_out', 'fadeout', '尾', '淡出')
    apply_out = direction not in ('in', 'fade_in', 'fadein', '头', '淡入')
    shape_default = _fade_shape_param(params, ('shape', 'fade_shape'), 0)
    fade_in_shape = _fade_shape_param(params, ('fade_in_shape', 'in_shape', 'fadein_shape'), shape_default)
    fade_out_shape = _fade_shape_param(params, ('fade_out_shape', 'out_shape', 'fadeout_shape'), shape_default)
    reset_curve = not (str(params.get('reset_curve', 'true')).lower() in ('false', '0', 'no', 'off'))
    has_fade_only = not (str(params.get('has_fade', params.get('only_faded', 'true'))).lower() in ('false', '0', 'no', 'off'))

    selected_lua = 'true' if selected else 'false'
    all_lua = 'true' if all_items else 'false'
    apply_in_lua = 'true' if apply_in else 'false'
    apply_out_lua = 'true' if apply_out else 'false'
    reset_curve_lua = 'true' if reset_curve else 'false'
    has_fade_only_lua = 'true' if has_fade_only else 'false'
    index_lua = lua_escape_string(index_raw)
    name_lua = lua_escape_string(name_raw)

    return f'''
local selected = {selected_lua}
local all_items = {all_lua}
local target_index = "{index_lua}"
local target_name = "{name_lua}"
local apply_in = {apply_in_lua}
local apply_out = {apply_out_lua}
local fade_in_shape = {fade_in_shape}
local fade_out_shape = {fade_out_shape}
local reset_curve = {reset_curve_lua}
local has_fade_only = {has_fade_only_lua}
local eps = 0.000001

local function lower(s)
    return tostring(s or ""):lower()
end

local function take_name(item)
    local take = item and reaper.GetActiveTake(item)
    return take and (reaper.GetTakeName(take) or "") or ""
end

local function item_label(item, fallback)
    local name = take_name(item)
    if name ~= "" then return name end
    return fallback or "item"
end

local function collect_named_item(name)
    local exact, partial = nil, nil
    local needle = lower(name)
    for i = 0, reaper.CountMediaItems(0) - 1 do
        local item = reaper.GetMediaItem(0, i)
        local candidate = take_name(item)
        if candidate == name then
            exact = item
            break
        elseif not partial and lower(candidate):find(needle, 1, true) then
            partial = item
        end
    end
    return exact or partial
end

local targets = {{}}
if all_items then
    for i = 0, reaper.CountMediaItems(0) - 1 do
        local item = reaper.GetMediaItem(0, i)
        if item then
            table.insert(targets, {{ item = item, label = item_label(item, "#" .. tostring(i)) }})
        end
    end
elseif selected then
    local count = reaper.CountSelectedMediaItems(0)
    if count == 0 then
        return "✗ 没有选中的 item"
    end
    for i = 0, count - 1 do
        local item = reaper.GetSelectedMediaItem(0, i)
        if item then
            table.insert(targets, {{ item = item, label = item_label(item, "selected item " .. tostring(i + 1)) }})
        end
    end
elseif target_index ~= "" then
    local item = reaper.GetMediaItem(0, tonumber(target_index) or -1)
    if not item then
        return "✗ Item not found: #" .. target_index
    end
    table.insert(targets, {{ item = item, label = item_label(item, "#" .. target_index) }})
elseif target_name ~= "" then
    local item = collect_named_item(target_name)
    if not item then
        return "✗ Item not found: " .. target_name
    end
    table.insert(targets, {{ item = item, label = item_label(item, target_name) }})
else
    return "✗ 请提供 selected=true、all=true 或 index/name"
end

if #targets == 0 then
    return "✗ 没有匹配到 item"
end

local inspected = 0
local changed_items = 0
local changed_sides = 0
local failed = 0
local labels = {{}}

for _, target in ipairs(targets) do
    local item = target.item
    if item then
        inspected = inspected + 1
        local item_changed = false
        local fi = reaper.GetMediaItemInfo_Value(item, "D_FADEINLEN") or 0
        local fo = reaper.GetMediaItemInfo_Value(item, "D_FADEOUTLEN") or 0
        if apply_in and (not has_fade_only or fi > eps) then
            local ok_shape = reaper.SetMediaItemInfo_Value(item, "C_FADEINSHAPE", fade_in_shape)
            local ok_curve = true
            if reset_curve then
                ok_curve = reaper.SetMediaItemInfo_Value(item, "D_FADEINDIR", 0)
            end
            local shape_after = reaper.GetMediaItemInfo_Value(item, "C_FADEINSHAPE")
            local dir_after = reaper.GetMediaItemInfo_Value(item, "D_FADEINDIR") or 0
            if ok_shape and ok_curve and math.floor((shape_after or -1) + 0.5) == fade_in_shape and (not reset_curve or math.abs(dir_after) < 0.0001) then
                changed_sides = changed_sides + 1
                item_changed = true
            else
                failed = failed + 1
            end
        end
        if apply_out and (not has_fade_only or fo > eps) then
            local ok_shape = reaper.SetMediaItemInfo_Value(item, "C_FADEOUTSHAPE", fade_out_shape)
            local ok_curve = true
            if reset_curve then
                ok_curve = reaper.SetMediaItemInfo_Value(item, "D_FADEOUTDIR", 0)
            end
            local shape_after = reaper.GetMediaItemInfo_Value(item, "C_FADEOUTSHAPE")
            local dir_after = reaper.GetMediaItemInfo_Value(item, "D_FADEOUTDIR") or 0
            if ok_shape and ok_curve and math.floor((shape_after or -1) + 0.5) == fade_out_shape and (not reset_curve or math.abs(dir_after) < 0.0001) then
                changed_sides = changed_sides + 1
                item_changed = true
            else
                failed = failed + 1
            end
        end
        if item_changed then
            changed_items = changed_items + 1
            if #labels < 5 then
                table.insert(labels, target.label)
            end
            reaper.UpdateItemInProject(item)
        end
    end
end

reaper.UpdateArrange()

if changed_sides == 0 then
    return {{ ok=false, message="未修改任何 fade shape；可能没有匹配到带 fade 的 item", changed={{items=0, sides=0, inspected=inspected, failed=failed}} }}
end

local suffix = ""
if #labels > 0 then
    suffix = ": " .. table.concat(labels, ", ")
    if changed_items > #labels then
        suffix = suffix .. " ..."
    end
end
return {{ ok=true, message="已把 " .. changed_items .. " 个 item 的 " .. changed_sides .. " 个 fade 边改为直线" .. suffix, changed={{items=changed_items, sides=changed_sides, inspected=inspected, failed=failed}} }}
'''

def generate_native_action_lua(params):
    action_entry, source = find_native_action(params)
    if not action_entry:
        return "return { ok=false, message='native/action 未找到本机 Action；请提供 command_id，或先在设置页检测 Action' }"

    command_id = str(action_entry.get("id") or action_entry.get("command_id") or "").strip()
    if not re.fullmatch(r"-?\d+", command_id or ""):
        return "return { ok=false, message='native/action command_id 必须是本机数字 Action ID' }"

    label = str(action_entry.get("name") or action_entry.get("command_name") or f"Action {command_id}")
    target_track = str(params.get("target_track") or params.get("track_name") or params.get("track") or "")
    selected_raw = str(params.get("selected") or "").lower()
    use_selected = selected_raw in ("true", "1", "yes", "on") or target_track.lower() in ("selected", "selection", "current", "当前", "选中", "已选中")
    restore_raw = str(params.get("restore_selection") or "false").lower()
    restore_selection = restore_raw in ("true", "1", "yes", "on")
    lua_lines = [
        f"local command_id = {command_id}",
        f"local action_label = {lua_string(label)}",
        f"local target_track_name = {lua_string(target_track)}",
        f"local use_selected = {str(use_selected).lower()}",
        f"local restore_selection = {str(restore_selection).lower()}",
        "local old_selected = {}",
        "for i = 0, reaper.CountTracks(0) - 1 do",
        "  local tr = reaper.GetTrack(0, i)",
        "  if tr and reaper.IsTrackSelected(tr) then table.insert(old_selected, tr) end",
        "end",
        "if target_track_name ~= '' and not use_selected then",
        "  local target = nil",
        "  local needle = target_track_name:lower()",
        "  for i = 0, reaper.CountTracks(0) - 1 do",
        "    local tr = reaper.GetTrack(0, i)",
        "    if tr then",
        "      local _, nm = reaper.GetTrackName(tr)",
        "      if nm == target_track_name or nm:lower():find(needle, 1, true) then target = tr; break end",
        "    end",
        "  end",
        "  if not target then return { ok=false, message='native/action 未找到目标轨道: ' .. target_track_name } end",
        "  reaper.SetOnlyTrackSelected(target)",
        "elseif use_selected and reaper.CountSelectedTracks(0) <= 0 then",
        "  return { ok=false, message='native/action 需要选中轨道，但当前没有选中轨道' }",
        "end",
        "reaper.Main_OnCommand(command_id, 0)",
        "if restore_selection and #old_selected > 0 then",
        "  for i = 0, reaper.CountTracks(0) - 1 do",
        "    local tr = reaper.GetTrack(0, i)",
        "    if tr then reaper.SetMediaTrackInfo_Value(tr, 'I_SELECTED', 0) end",
        "  end",
        "  for _, tr in ipairs(old_selected) do if tr then reaper.SetMediaTrackInfo_Value(tr, 'I_SELECTED', 1) end end",
        "end",
        "reaper.UpdateArrange()",
        "return { ok=true, message='已执行本机 Action ' .. tostring(command_id) .. ': ' .. action_label, changed={native_action=1} }",
    ]
    return "\n".join(lua_lines)

def _lane_kind(lane):
    text = str(lane or 'volume').lower()
    if text in ('pan', '声像', 'p'):
        return 'pan'
    if text in ('mute', '静音'):
        return 'mute'
    return 'volume'

def _parse_envelope_value(value, lane='volume', default=0.0):
    if value is None or value == '':
        return default
    s = str(value).strip()
    lane = _lane_kind(lane)
    try:
        lower = s.lower()
        if lane == 'volume':
            if lower.endswith('db'):
                db_val = float(s[:-2].strip())
                return 10 ** (db_val / 20)
            if lower.endswith('%'):
                return max(0.0, float(s[:-1].strip()) / 100)
            return max(0.0, float(s))
        if lane == 'pan':
            if lower.endswith('%'):
                return max(-1.0, min(1.0, float(s[:-1].strip()) / 100))
            return max(-1.0, min(1.0, float(s)))
        if lane == 'mute':
            return 1.0 if lower in ('1', 'true', 'on', 'mute', 'muted', 'yes') else 0.0
        return float(s)
    except (TypeError, ValueError):
        return default

def _envelope_lua_helpers():
    return r'''
local function trim(s)
    return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function lower(s)
    return tostring(s or ""):lower()
end

local function track_name(track)
    local _, name = reaper.GetTrackName(track)
    return name or ""
end

local function take_name(take)
    if not take then return "" end
    local name = reaper.GetTakeName(take)
    return name or ""
end

local function item_name(item)
    if not item then return "" end
    local take = reaper.GetActiveTake(item)
    return take_name(take)
end

local function find_track(index, name, selected)
    if selected then
        local track = reaper.GetSelectedTrack(0, 0)
        if track then return track, "selected track" end
    end
    if index ~= "" then
        local track = reaper.GetTrack(0, tonumber(index) or 0)
        if track then return track, "#" .. tostring(index) end
    end
    if name ~= "" then
        local exact, partial = nil, nil
        local needle = lower(name)
        for i = 0, reaper.CountTracks(0) - 1 do
            local track = reaper.GetTrack(0, i)
            local candidate = track_name(track)
            if candidate == name then
                exact = track
                break
            elseif not partial and lower(candidate):find(needle, 1, true) then
                partial = track
            end
        end
        local track = exact or partial
        if track then return track, name end
    end
    return nil, name ~= "" and name or "#" .. tostring(index)
end

local function find_item(index, name, selected)
    if selected then
        local item = reaper.GetSelectedMediaItem(0, 0)
        if item then return item, "selected item" end
    end
    if index ~= "" then
        local item = reaper.GetMediaItem(0, tonumber(index) or 0)
        if item then return item, "#" .. tostring(index) end
    end
    if name ~= "" then
        local exact, partial = nil, nil
        local needle = lower(name)
        for i = 0, reaper.CountMediaItems(0) - 1 do
            local item = reaper.GetMediaItem(0, i)
            local candidate = item_name(item)
            if candidate == name then
                exact = item
                break
            elseif not partial and lower(candidate):find(needle, 1, true) then
                partial = item
            end
        end
        local item = exact or partial
        if item then return item, name end
    end
    return nil, name ~= "" and name or "#" .. tostring(index)
end

local function ensure_track_envelope(track, lane)
    local names = {}
    local action_id = 40406
    if lane == "pan" then
        names = {"Pan", "Pan Pre-FX"}
        action_id = 40407
    elseif lane == "mute" then
        names = {"Mute"}
        action_id = 40867
    else
        names = {"Volume", "Volume Pre-FX"}
        action_id = 40406
    end
    local function show_env(env)
        if not env or not reaper.GetEnvelopeStateChunk or not reaper.SetEnvelopeStateChunk then return end
        local ok, chunk = reaper.GetEnvelopeStateChunk(env, "", false)
        if not ok or not chunk or chunk == "" then return end
        if chunk:find("\nVIS%s+") then chunk = chunk:gsub("\nVIS%s+[%d%-]+", "\nVIS 1") else chunk = chunk:gsub("\n", "\nVIS 1\n", 1) end
        if chunk:find("\nACT%s+") then chunk = chunk:gsub("\nACT%s+[%d%-]+", "\nACT 1") else chunk = chunk:gsub("\n", "\nACT 1\n", 1) end
        reaper.SetEnvelopeStateChunk(env, chunk, false)
    end
    for _, env_name in ipairs(names) do
        local env = reaper.GetTrackEnvelopeByName(track, env_name)
        if env then show_env(env); return env, env_name end
    end
    reaper.SetOnlyTrackSelected(track)
    reaper.Main_OnCommand(action_id, 0)
    for _, env_name in ipairs(names) do
        local env = reaper.GetTrackEnvelopeByName(track, env_name)
        if env then show_env(env); return env, env_name end
    end
    return nil, table.concat(names, "/")
end

local function find_take_envelope(take, env_name)
    local env = reaper.GetTakeEnvelopeByName(take, env_name)
    if env then return env end
    if reaper.CountTakeEnvelopes and reaper.GetTakeEnvelope then
        for i = 0, reaper.CountTakeEnvelopes(take) - 1 do
            local candidate = reaper.GetTakeEnvelope(take, i)
            if candidate then
                local _, name = reaper.GetEnvelopeName(candidate)
                if name == env_name then return candidate end
            end
        end
    end
    return nil
end

local function force_envelope_visible(env)
    if not env or not reaper.GetEnvelopeStateChunk or not reaper.SetEnvelopeStateChunk then return end
    local ok, chunk = reaper.GetEnvelopeStateChunk(env, "", false)
    if not ok or not chunk or chunk == "" then return end
    if chunk:find("\nVIS%s+") then
        chunk = chunk:gsub("\nVIS%s+[%d%-]+", "\nVIS 1")
    else
        chunk = chunk:gsub("\n", "\nVIS 1\n", 1)
    end
    if chunk:find("\nACT%s+") then
        chunk = chunk:gsub("\nACT%s+[%d%-]+", "\nACT 1")
    else
        chunk = chunk:gsub("\n", "\nACT 1\n", 1)
    end
    reaper.SetEnvelopeStateChunk(env, chunk, false)
end

local function ensure_take_envelope(item, take, lane)
    local names = {}
    local action_id = 40693
    if lane == "pan" then
        names = {"Pan"}
        action_id = 40694
    elseif lane == "mute" then
        names = {"Mute"}
        action_id = 40695
    else
        names = {"Volume"}
        action_id = 40693
    end
    local env = find_take_envelope(take, names[1])
    if env then force_envelope_visible(env); return env, names[1] end
    reaper.SelectAllMediaItems(0, false)
    reaper.SetMediaItemSelected(item, true)
    reaper.SetActiveTake(take)
    reaper.Main_OnCommand(action_id, 0)
    env = find_take_envelope(take, names[1])
    if env then force_envelope_visible(env); return env, names[1] end
    return nil, names[1]
end

local function selected_envelope()
    if reaper.GetSelectedEnvelope then
        local env = reaper.GetSelectedEnvelope(0)
        if env then return env, "selected envelope" end
    end
    return nil, "selected envelope"
end

local function envelope_points(shape, start_pos, end_pos, from_value, to_value, steps)
    local points = {}
    steps = math.max(1, tonumber(steps) or 16)
    if end_pos < start_pos then start_pos, end_pos = end_pos, start_pos end
    local length = math.max(0.000001, end_pos - start_pos)
    local function add(t, v) table.insert(points, {time = t, value = v}) end
    if shape == "hold" or shape == "constant" then
        add(start_pos, from_value)
        add(end_pos, from_value)
    elseif shape == "fade_in" then
        add(start_pos, from_value)
        add(end_pos, to_value)
    elseif shape == "fade_out" then
        add(start_pos, from_value)
        add(end_pos, to_value)
    elseif shape == "pulse" or shape == "square" then
        for i = 0, steps do
            local t = start_pos + length * i / steps
            local v = (i % 2 == 0) and from_value or to_value
            add(t, v)
        end
    elseif shape == "sine" or shape == "sin" then
        for i = 0, steps do
            local phase = i / steps
            local t = start_pos + length * phase
            local amt = (1 - math.cos(phase * math.pi * 2)) / 2
            add(t, from_value + (to_value - from_value) * amt)
        end
    elseif shape == "triangle" then
        for i = 0, steps do
            local phase = i / steps
            local amt = phase <= 0.5 and phase * 2 or (1 - phase) * 2
            add(start_pos + length * phase, from_value + (to_value - from_value) * amt)
        end
    else
        add(start_pos, from_value)
        add(end_pos, to_value)
    end
    return points
end
'''

def _generate_envelope_lua(params, clear_only=False):
    target_raw = params.get('target', params.get('scope', ''))
    if target_raw:
        target = lua_escape_string(target_raw).lower()
    elif params.get('item') or params.get('item_name'):
        target = 'item'
    elif params.get('track') or params.get('track_name'):
        target = 'track'
    else:
        target = 'auto'
    target_aliases = {
        'selected': ('auto', True),
        'selection': ('auto', True),
        'current': ('auto', True),
        '当前': ('auto', True),
        '选中': ('auto', True),
        '已选中': ('auto', True),
        'selected_item': ('item', True),
        'selected_items': ('item', True),
        'selection_item': ('item', True),
        'selection_items': ('item', True),
        'selected_take': ('take', True),
        'selected_takes': ('take', True),
        'selected_track': ('track', True),
        'selected_tracks': ('track', True),
        'selected_track_envelope': ('selected_envelope', True),
        'selected_env': ('selected_envelope', True),
    }
    forced_selected = False
    if target in target_aliases:
        target, forced_selected = target_aliases[target]
    lane = _lane_kind(params.get('lane', params.get('type', params.get('envelope', 'volume'))))
    name_raw = params.get('name', params.get('match', params.get('track_name', params.get('item_name', ''))))
    index_raw = params.get('index', '')
    track_or_item_raw = params.get('track', params.get('item', ''))
    selected_tokens = ('selected', 'selection', 'current', '当前', '选中', '已选中')
    item_raw = str(params.get('item', '')).lower()
    track_raw = str(params.get('track', '')).lower()
    take_raw = str(params.get('take', '')).lower()
    name_token = str(name_raw).lower()
    if item_raw in selected_tokens:
        target = 'item'
        forced_selected = True
        track_or_item_raw = ''
        name_raw = ''
    elif take_raw in selected_tokens:
        target = 'take'
        forced_selected = True
        track_or_item_raw = ''
        name_raw = ''
    elif track_raw in selected_tokens:
        target = 'track'
        forced_selected = True
        track_or_item_raw = ''
        name_raw = ''
    elif name_token in selected_tokens and target in ('item', 'take', 'track', 'auto'):
        forced_selected = True
        name_raw = ''
    if not name_raw and track_or_item_raw and not _is_int_string(track_or_item_raw):
        name_raw = track_or_item_raw
    elif not index_raw and track_or_item_raw and _is_int_string(track_or_item_raw):
        index_raw = track_or_item_raw
    name = lua_escape_string(name_raw)
    index = lua_escape_string(index_raw)
    selected = forced_selected or _bool_param(params.get('selected', 'false'))
    shape = lua_escape_string(params.get('shape', 'line')).lower()
    start_given = any(params.get(key, '') != '' for key in ('start', 'time', 'from_time'))
    end_given = any(params.get(key, '') != '' for key in ('end', 'to_time'))
    duration_given = any(params.get(key, '') != '' for key in ('duration', 'length'))
    use_time_selection = _bool_param(params.get('time_selection', params.get('use_time_selection', params.get('selection', 'false'))))
    explicit_target_raw = str(target_raw or '').strip().lower()
    has_explicit_target = bool(
        selected
        or (explicit_target_raw and explicit_target_raw != 'auto')
        or str(params.get('item', '') or '').strip()
        or str(params.get('item_name', '') or '').strip()
        or str(params.get('track', '') or '').strip()
        or str(params.get('track_name', '') or '').strip()
        or str(params.get('take', '') or '').strip()
        or str(name_raw or '').strip()
        or str(index_raw or '').strip()
    )
    if not has_explicit_target:
        return '''
return "ERROR: envelope operation requires an explicit envelope target: selected=true, selected_envelope, track, item, take, name, index, or target."
'''
    if clear_only and not (use_time_selection or start_given or end_given or duration_given or target == 'selected_envelope'):
        return '''
return "ERROR: envelope/clear requires an explicit clear range: time_selection=true, start/end, duration, or selected_envelope."
'''
    start = _float_param(params, ('start', 'time', 'from_time'), 0.0)
    end = _float_param(params, ('end', 'to_time'), start + _float_param(params, ('duration', 'length'), 1.0))
    if end == start:
        end = start + _float_param(params, ('duration', 'length'), 1.0)
    steps = max(1, _int_param(params, ('steps', 'points'), 16))
    from_raw = params.get('from', params.get('from_value', params.get('value1', '')))
    to_raw = params.get('to', params.get('to_value', params.get('value2', params.get('value', ''))))
    if lane == 'volume' and shape in ('fade_in', 'fadein'):
        default_from, default_to = 0.001, 1.0
    elif lane == 'volume' and shape in ('fade_out', 'fadeout'):
        default_from, default_to = 1.0, 0.001
    elif lane == 'pan':
        default_from = default_to = 0.0
    else:
        default_from = default_to = 1.0
    from_value = _parse_envelope_value(from_raw, lane, default_from)
    to_value = _parse_envelope_value(to_raw, lane, default_to)
    replace = _bool_param(params.get('replace', 'true'))
    origin = str(params.get('origin', '')).lower()
    absolute = _bool_param(params.get('absolute', 'false')) or origin in ('project', 'absolute')
    relative = _bool_param(params.get('relative', params.get('item_relative', 'true'))) and not absolute
    clear = 'true' if (clear_only or replace) else 'false'
    selected_lua = 'true' if selected else 'false'
    relative_lua = 'true' if relative else 'false'
    absolute_lua = 'true' if absolute else 'false'
    start_given_lua = 'true' if start_given else 'false'
    end_given_lua = 'true' if end_given else 'false'
    duration_given_lua = 'true' if duration_given else 'false'
    use_time_selection_lua = 'true' if use_time_selection else 'false'
    mode_label = 'clear' if clear_only else 'draw'

    return f'''
{_envelope_lua_helpers()}

local target = "{target}"
local lane = "{lane}"
local target_name = "{name}"
local target_index = "{index}"
local selected = {selected_lua}
local start_pos = {start}
local end_pos = {end}
local clear_existing = {clear}
local item_relative = {relative_lua}
local absolute_time = {absolute_lua}
local start_given = {start_given_lua}
local end_given = {end_given_lua}
local duration_given = {duration_given_lua}
local use_time_selection = {use_time_selection_lua}
local shape = "{shape}"
local original_shape = "{shape}"
local from_value = {from_value}
local to_value = {to_value}
local steps = {steps}

local env = nil
local label = ""
local env_label = lane
local clear_start = nil
local clear_end = nil

if target == "auto" then
    if selected and reaper.CountSelectedMediaItems(0) > 0 then
        target = "item"
    else
        target = "track"
    end
end

if target == "selected_envelope" then
    env, label = selected_envelope()
    if not absolute_time then
        local ts_start, ts_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
        local cursor = reaper.GetCursorPosition()
        if start_pos == 0 and end_pos == 1 and ts_end > ts_start then
            start_pos = ts_start
            end_pos = ts_end
        else
            start_pos = cursor + start_pos
            end_pos = cursor + end_pos
        end
    end
elseif target == "item" or target == "take" then
    local item
    item, label = find_item(target_index, target_name, selected)
    if not item then return "✗ Item not found: " .. label end
    local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local item_end = item_start + item_len
    local ts_start, ts_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
    if use_time_selection and ts_end > ts_start then
        start_pos = math.max(item_start, ts_start) - item_start
        end_pos = math.min(item_end, ts_end) - item_start
        if end_pos <= start_pos then
            start_pos = 0
            end_pos = item_len
        end
    elseif absolute_time then
        start_pos = start_pos - item_start
        end_pos = end_pos - item_start
    elseif not start_given and not end_given and not duration_given then
        start_pos = 0
        end_pos = item_len
    elseif start_given and (end_given or duration_given) then
        local eps = 0.0001
        local looks_project_time =
            (start_pos >= item_start - eps and start_pos <= item_end + eps) or
            (end_pos >= item_start - eps and end_pos <= item_end + eps) or
            (start_pos > item_len and end_pos > item_len)
        if looks_project_time then
            start_pos = start_pos - item_start
            end_pos = end_pos - item_start
        end
    elseif item_relative then
        -- take envelopes use item-local time; keep start/end as supplied
    end
    start_pos = math.max(0, math.min(item_len, start_pos))
    end_pos = math.max(0, math.min(item_len, end_pos))
    clear_start = 0
    clear_end = item_len
    if original_shape == "fade_in" then
        shape = "fade_in_item"
    elseif original_shape == "fade_out" then
        shape = "fade_out_item"
    end
    local take = reaper.GetActiveTake(item)
    if not take then return "✗ Item has no active take: " .. label end
    env, env_label = ensure_take_envelope(item, take, lane)
else
    local track
    track, label = find_track(target_index, target_name, selected)
    if not track then return "✗ Track not found: " .. label end
    if not absolute_time then
        local ts_start, ts_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
        local cursor = reaper.GetCursorPosition()
        if start_pos == 0 and end_pos == 1 and ts_end > ts_start then
            start_pos = ts_start
            end_pos = ts_end
        else
            start_pos = cursor + start_pos
            end_pos = cursor + end_pos
        end
    end
    env, env_label = ensure_track_envelope(track, lane)
end

if not env then
    return "✗ Envelope not available: " .. env_label .. " (" .. label .. ")"
end

if start_pos > end_pos then start_pos, end_pos = end_pos, start_pos end
if clear_existing then
    reaper.DeleteEnvelopePointRange(env, clear_start or start_pos, clear_end or end_pos)
end

local points = envelope_points(shape, start_pos, end_pos, from_value, to_value, steps)
if target == "item" or target == "take" then
    if original_shape == "fade_in" then
        table.insert(points, {{time = clear_end or end_pos, value = to_value}})
    elseif original_shape == "fade_out" then
        table.insert(points, 1, {{time = clear_start or start_pos, value = from_value}})
    end
end
if {str(clear_only).lower()} then
    points = {{}}
end
local scaling_mode = reaper.GetEnvelopeScalingMode and reaper.GetEnvelopeScalingMode(env) or 0
local function point_value(v)
    if target == "item" or target == "take" then
        if lane == "volume" then
            if reaper.ScaleToEnvelopeMode then
                return reaper.ScaleToEnvelopeMode(1, v)
            end
        end
        return v
    end
    if reaper.ScaleToEnvelopeMode then
        return reaper.ScaleToEnvelopeMode(scaling_mode, v)
    end
    return v
end
for _, p in ipairs(points) do
    reaper.InsertEnvelopePoint(env, p.time, point_value(p.value), 0, 0, false, true)
end
reaper.Envelope_SortPoints(env)
reaper.UpdateArrange()

if {str(clear_only).lower()} then
    return "✓ 已清理 " .. label .. " 的 " .. env_label .. " 包络: " .. start_pos .. "s-" .. end_pos .. "s"
end
return "✓ 已绘制 " .. label .. " 的 " .. env_label .. " 包络 (" .. shape .. ", " .. #points .. " 点)"
'''

def generate_draw_envelope_lua(params):
    """Draw track/take/selected envelope points with stable templates."""
    return _generate_envelope_lua(params, clear_only=False)

def generate_clear_envelope_lua(params):
    """Clear envelope points in a time range."""
    return _generate_envelope_lua(params, clear_only=True)

def generate_batch_rename_regions_lua(params):
    """批量重命名Region前缀"""
    search = lua_escape_string(params.get('search', ''))
    replace = lua_escape_string(params.get('replace', ''))
    if search:
        return f'''
local search = "{search}"
local replace = "{replace}"
local changed = 0
local skipped = 0
local results = {{}}

local marker_total = reaper.CountProjectMarkers(0)
for i = 0, marker_total - 1 do
    local retval, isrgn, pos, rgnend, name, markrgnindex = reaper.EnumProjectMarkers(i)
    if retval ~= 0 and isrgn then
        local start_pos, end_pos = name:find(search, 1, true)
        if start_pos then
            local new_name = name:sub(1, start_pos - 1) .. replace .. name:sub(end_pos + 1)
            reaper.SetProjectMarker(markrgnindex, true, pos, rgnend, new_name)
            changed = changed + 1
            table.insert(results, "'" .. name .. "' -> '" .. new_name .. "'")
        else
            skipped = skipped + 1
        end
    end
end

reaper.UpdateArrange()
return "✓ 已替换 " .. changed .. " 个Region (跳过 " .. skipped .. " 个)\\n" .. table.concat(results, "\\n")
'''

    old_prefix = lua_escape_string(params.get('old_prefix', ''))
    new_prefix = lua_escape_string(params.get('new_prefix', params.get('prefix', '')))
    apply_prefix_with_index = str(params.get('apply_prefix_with_index', params.get('with_index', 'false'))).lower() in ('1', 'true', 'yes', 'on')
    separator = lua_escape_string(params.get('separator', '_'))
    if not new_prefix:
        return '''
return "✗ 请提供 search/replace 或 new_prefix 参数"
'''
    return f'''
local old_prefix = "{old_prefix}"
local new_prefix = "{new_prefix}"
local apply_prefix_with_index = {str(apply_prefix_with_index).lower()}
local separator = "{separator}"
local changed = 0
local skipped = 0
local results = {{}}

local marker_total = reaper.CountProjectMarkers(0)
local region_order = 0
local function has_target_prefix(name)
    if new_prefix == "" then return false end
    if name:sub(1, #new_prefix) ~= new_prefix then return false end
    local rest = name:sub(#new_prefix + 1)
    return rest == "" or rest:sub(1, #separator) == separator or rest:match("^_%d+_") ~= nil
end

local function join_prefix(prefix, body)
    if body == "" then return prefix end
    if separator ~= "" and body:sub(1, #separator) == separator then
        return prefix .. body
    end
    return prefix .. separator .. body
end

for i = 0, marker_total - 1 do
    local retval, isrgn, pos, rgnend, name, markrgnindex = reaper.EnumProjectMarkers(i)
    if retval ~= 0 and isrgn then
        region_order = region_order + 1
        local matches = old_prefix == "" or name:sub(1, #old_prefix) == old_prefix
        if matches and not has_target_prefix(name) then
            local body = old_prefix == "" and name or name:sub(#old_prefix + 1)
            local prefix = new_prefix
            if apply_prefix_with_index then
                prefix = new_prefix .. separator .. string.format("%02d", region_order)
            end
            local new_name = join_prefix(prefix, body)
            reaper.SetProjectMarker(markrgnindex, true, pos, rgnend, new_name)
            changed = changed + 1
            table.insert(results, "'" .. name .. "' -> '" .. new_name .. "'")
        else
            skipped = skipped + 1
        end
    end
end

reaper.UpdateArrange()
if old_prefix == "" then
    return "✓ 已添加前缀到 " .. changed .. " 个Region (跳过 " .. skipped .. " 个)\\n" .. table.concat(results, "\\n")
end
return "✓ 已重命名 " .. changed .. " 个Region (跳过 " .. skipped .. " 个)\\n" .. table.concat(results, "\\n")
'''

def generate_set_volume_by_name_lua(params):
    """按名称设置轨道音量"""
    name = lua_escape_string(params.get('name', ''))
    volume = params.get('volume', '0.7')
    if not name:
        return '''
return "✗ 请提供 name 参数"
'''
    if 'dB' in str(volume):
        db_val = float(volume.replace('dB', '').strip())
        volume = str(10 ** (db_val / 20))
    return f'''
local target_name = "{name}"
local found = false
for i = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, i)
    if track then
        local _, tname = reaper.GetTrackName(track)
        if tname == target_name then
            reaper.SetMediaTrackInfo_Value(track, "D_VOL", {volume})
            local vol_db = 20 * (math.log({volume}) / math.log(10))
            found = true
            return string.format("✓ Set track '%s' volume to %.1f dB", target_name, vol_db)
        end
    end
end
if not found then
    return "✗ Track not found: " .. target_name
end
'''

def generate_group_tracks_into_folder_lua(params):
    """创建文件夹轨道并把指定轨道移动进去。"""
    folder_name = lua_escape_string(params.get('folder_name', params.get('name', 'Folder')))
    tracks_raw = lua_escape_string(params.get('tracks', params.get('track_names', params.get('names', ''))))
    match_raw = lua_escape_string(params.get('match', params.get('contains', params.get('keyword', ''))))
    if not tracks_raw and not match_raw:
        return '''
return "✗ 请提供 tracks=轨道名/索引列表 或 match=关键词"
'''

    return f'''
local folder_name = "{folder_name}"
local tracks_raw = "{tracks_raw}"
local match_raw = "{match_raw}"

local function trim(s)
    return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function split_list(s)
    local list = {{}}
    s = (s or ""):gsub("，", ","):gsub("、", ","):gsub("|", ","):gsub(";", ",")
    for part in s:gmatch("[^,]+") do
        part = trim(part)
        if part ~= "" then table.insert(list, part) end
    end
    return list
end

local function track_name(track)
    local _, name = reaper.GetTrackName(track)
    return name
end

local selected = {{}}
local seen = {{}}
local wanted = split_list(tracks_raw)
local keywords = split_list(match_raw)

for i = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, i)
    local name = track_name(track)
    local lower_name = name:lower()
    local hit = false

    for _, token in ipairs(wanted) do
        local num = tonumber(token)
        if num and num == i then
            hit = true
        elseif name == token or lower_name:find(token:lower(), 1, true) then
            hit = true
        end
    end

    for _, token in ipairs(keywords) do
        if lower_name:find(token:lower(), 1, true) then
            hit = true
        end
    end

    if hit and not seen[track] then
        local guid = reaper.GetTrackGUID(track)
        table.insert(selected, {{index = i, name = name, guid = guid}})
        seen[track] = true
    end
end

if #selected == 0 then
    return "✗ 没找到要放入文件夹的轨道"
end

table.sort(selected, function(a, b) return a.index < b.index end)
local insert_index = selected[1].index
reaper.InsertTrackAtIndex(insert_index, true)
local folder = reaper.GetTrack(0, insert_index)
if not folder then return "✗ 文件夹轨道创建失败" end
reaper.GetSetMediaTrackInfo_String(folder, "P_NAME", folder_name, true)

local function find_track_by_guid(guid)
    for i = 0, reaper.CountTracks(0) - 1 do
        local track = reaper.GetTrack(0, i)
        if track then
            local current_guid = reaper.GetTrackGUID(track)
            if current_guid == guid then
                return track, i
            end
        end
    end
    return nil, -1
end

local moved_names = {{}}
for i = #selected, 1, -1 do
    local track = find_track_by_guid(selected[i].guid)
    if track then
        reaper.SetOnlyTrackSelected(track)
        reaper.ReorderSelectedTracks(insert_index + 1, 0)
        table.insert(moved_names, 1, selected[i].name)
    end
end

reaper.SetMediaTrackInfo_Value(folder, "I_FOLDERDEPTH", 1)
for i = 1, #moved_names do
    local child = reaper.GetTrack(0, insert_index + i)
    if child then
        reaper.SetMediaTrackInfo_Value(child, "I_FOLDERDEPTH", 0)
    end
end
local last_child = reaper.GetTrack(0, insert_index + #moved_names)
if last_child then
    reaper.SetMediaTrackInfo_Value(last_child, "I_FOLDERDEPTH", -1)
end

reaper.TrackList_AdjustWindows(false)
reaper.UpdateArrange()
return "✓ 已创建文件夹 '" .. folder_name .. "' 并放入 " .. #moved_names .. " 个轨道: " .. table.concat(moved_names, ", ")
'''

def generate_list_endpoints_lua(params):
    """生成返回可用 MCP 端点列表的 Lua 代码"""
    # 从 MCP_ENDPOINTS 提取端点名称和描述，并进行 Lua 字符串转义
    endpoint_lines = []
    for key, info in MCP_ENDPOINTS.items():
        desc = info.get('description', '无描述')
        # Lua 字符串转义：\ 和 " 需要转义
        desc_escaped = desc.replace('\\', '\\\\').replace('"', '\\"')
        endpoint_lines.append(f'  • {key} - {desc_escaped}')
    
    # 构建 Lua 代码，每行单独拼接避免长字符串问题
    lua_lines = ['local result = "=== MCP 服务器可用端点 ===\\n"']
    for line in endpoint_lines:
        lua_lines.append(f'result = result .. "{line}\\n"')
    lua_lines.append('result = result .. "\\n使用格式: [MCP_CALL:endpoint?param=value]\\n"')
    lua_lines.append('result = result .. "示例: [MCP_CALL:track/create?name=Vocal]"')
    lua_lines.append(f'return result .. "\\n共 {len(endpoint_lines)} 个端点"')
    
    return '\n'.join(lua_lines)

def generate_sfx_variants_lua(params):
    """生成音效变体的Lua代码 - 基于选中item创建多个变体"""
    # 支持 count / variant_count / variants 多种参数名
    count = int(params.get('count') or params.get('variant_count') or params.get('variants') or 5)
    
    # 支持多种参数风格，兼容AI的不同叫法
    # 音高参数: pitch_variation / pitch_min+pitch_max
    if 'pitch_variation' in params:
        pv = float(params['pitch_variation'])
        pitch_min, pitch_max = -pv, pv
    else:
        pitch_min = float(params.get('pitch_min', -3))
        pitch_max = float(params.get('pitch_max', 3))
    
    # 音量参数: volume_variation / gain_variation / volume_min+volume_max
    if 'volume_variation' in params:
        vv = float(params['volume_variation'])
        volume_min, volume_max = -vv, vv
    elif 'gain_variation' in params:
        vv = float(params['gain_variation'])
        volume_min, volume_max = -vv, vv
    else:
        volume_min = float(params.get('volume_min', -3))
        volume_max = float(params.get('volume_max', 3))
    
    # 声像参数: pan_variation / spectral_variation / pan_min+pan_max
    # spectral_variation 映射为声像变化（频谱立体声效果）
    if 'pan_variation' in params:
        pv = float(params['pan_variation'])
        pan_min, pan_max = -pv, pv
    elif 'spectral_variation' in params:
        # spectral_variation 百分比转声像值 (0-100 -> 0-1)
        sv = float(params['spectral_variation'])
        pan_min, pan_max = -sv / 100, sv / 100
    else:
        pan_min = float(params.get('pan_min', -0.3))
        pan_max = float(params.get('pan_max', 0.3))
    
    # 时间偏移参数 - 控制变体之间的间隔
    time_offset = float(params.get('time_offset', 0.1))
    
    # 位置随机化参数 - 控制item在轨道上的位置偏移（不是音频波形位移！）
    # 限制最大偏移量，防止item跑太远或重叠混乱
    position_jitter = float(params.get('position_jitter', 0.0))  # 默认不启用位置抖动
    position_jitter = min(position_jitter, 0.5)  # 最大0.5秒，防止太离谱（用内置min，不是math.min）
    
    name_pattern = lua_escape_string(params.get('name_pattern', '{original}_{nn}'))
    
    lua_code = f'''
-- 音效变体生成器 - 延续原item纵列逻辑，向右排列变体
-- 重要: 只改变item的播放属性，绝不修改音频波形内容！
local function generate_variants()
    -- 获取选中的items数量
    local selected_count = reaper.CountSelectedMediaItems(0)
    if selected_count == 0 then
        return "✗ 错误: 请先选中至少一个音频item"
    end
    
    -- 使用 reaper.time_precise() 作为随机种子
    math.randomseed(reaper.time_precise() * 1000)
    
    local total_created = 0
    local all_variants_info = {{}}
    local tracks_created = 0
    
    -- 收集所有选中item的信息（轨道、位置、长度）
    local items_info = {{}}
    for item_idx = 0, selected_count - 1 do
        local item = reaper.GetSelectedMediaItem(0, item_idx)
        if item then
            local take = reaper.GetActiveTake(item)
            if take then
                local source = reaper.GetMediaItemTake_Source(take)
                if source then
                    local track = reaper.GetMediaItemTrack(item)
                    local track_idx = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") - 1
                    local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
                    local length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
                    local _, name = reaper.GetTakeName(take)
                    
                    table.insert(items_info, {{
                        item = item,
                        take = take,
                        source = source,
                        track = track,
                        track_idx = track_idx,
                        pos = pos,
                        length = length,
                        name = name or "Untitled",
                        pitch = reaper.GetMediaItemTakeInfo_Value(take, "D_PITCH"),
                        vol = reaper.GetMediaItemTakeInfo_Value(take, "D_VOL"),
                        pan = reaper.GetMediaItemTakeInfo_Value(take, "D_PAN")
                    }})
                end
            end
        end
    end
    
    if #items_info == 0 then
        return "✗ 错误: 没有有效的选中音频"
    end
    
    -- 【读取Region信息】获取第一个选中item所在的Region名称
    local base_region_name = nil
    local region_start, region_end = 0, 0
    local first_item = items_info[1].item
    local first_pos = items_info[1].pos
    local first_end = first_pos + items_info[1].length
    
    -- 查找包含第一个item的Region
    local region_count = reaper.CountProjectMarkers(0)
    for idx = 0, region_count - 1 do
        local _, is_region, pos, rgn_end, name, mark_id = reaper.EnumProjectMarkers(idx)
        if is_region then
            -- 检查item是否在region内（允许一点误差）
            if first_pos >= pos - 0.001 and first_end <= rgn_end + 0.001 then
                base_region_name = name
                region_start = pos
                region_end = rgn_end
                break
            end
        end
    end
    
    -- 解析基础名称和起始编号
    local region_base = base_region_name or "Variant"
    local start_num = 1
    
    -- 如果原region名有_01、_02等尾缀，提取基础名和起始编号
    if base_region_name then
        local base, num = base_region_name:match("^(.-)_(%d+)$")
        if base and num then
            region_base = base
            start_num = tonumber(num) + 1
        end
    end
    
    -- 【在同一轨道创建变体】保持原item的相对时间，向右排列
    -- 例如：原音效有3个item（音头@0s、叠加层@0.2s、音尾@0.5s）在轨道1、2、3
    -- 变体1也在轨道1、2、3，时间向右偏移（音头@0.5s、叠加层@0.7s、音尾@1.0s）
    
    -- 计算间距和变体总时长
    local max_length = 0
    local earliest_pos = items_info[1].pos
    local latest_end = items_info[1].pos + items_info[1].length
    
    for _, item_info in ipairs(items_info) do
        max_length = math.max(max_length, item_info.length)
        earliest_pos = math.min(earliest_pos, item_info.pos)
        latest_end = math.max(latest_end, item_info.pos + item_info.length)
    end
    local variant_total_duration = latest_end - earliest_pos
    local spacing = max_length + 0.5
    
    -- 为每个变体在原轨道上创建item
    for i = 1, {count} do
        -- 计算变体的整体时间范围（基于最早开始和最晚结束）
        local variant_start = earliest_pos + i * spacing
        local variant_end = variant_start + variant_total_duration
        
        -- 为这个变体创建Region
        local region_name = region_base .. "_" .. string.format("%02d", start_num + i - 1)
        reaper.AddProjectMarker(0, true, variant_start, variant_end, region_name, -1)
        
        for item_idx, info in ipairs(items_info) do
            -- 【关键】使用原轨道，不创建新轨道
            local target_track = info.track
            
            -- 在原轨道创建item
            local new_item = reaper.AddMediaItemToTrack(target_track)
            if not new_item then
                goto next_variant
            end
            
            -- 【关键】保持相对时间，但整体向右偏移
            local offset = i * spacing  -- 变体i向右偏移i个间距
            reaper.SetMediaItemInfo_Value(new_item, "D_POSITION", info.pos + offset)
            reaper.SetMediaItemInfo_Value(new_item, "D_LENGTH", info.length)
            reaper.SetMediaItemInfo_Value(new_item, "D_FADEINLEN", reaper.GetMediaItemInfo_Value(info.item, "D_FADEINLEN"))
            reaper.SetMediaItemInfo_Value(new_item, "D_FADEOUTLEN", reaper.GetMediaItemInfo_Value(info.item, "D_FADEOUTLEN"))
            
            -- 创建take
            local new_take = reaper.AddTakeToMediaItem(new_item)
            if not new_take then
                reaper.DeleteTrackMediaItem(new_track, new_item)
                goto next_variant
            end
            
            reaper.SetMediaItemTake_Source(new_take, info.source)
            reaper.SetMediaItemTakeInfo_Value(new_take, "D_STARTOFFS", reaper.GetMediaItemTakeInfo_Value(info.take, "D_STARTOFFS"))
            
            -- 随机音高
            local pitch_range = {pitch_max} - {pitch_min}
            local pitch_offset = {pitch_min} + math.random() * pitch_range
            reaper.SetMediaItemTakeInfo_Value(new_take, "D_PITCH", info.pitch + pitch_offset)
            
            -- 随机音量
            local vol_range = {volume_max} - {volume_min}
            local vol_offset_db = {volume_min} + math.random() * vol_range
            local vol_mult = 10 ^ (vol_offset_db / 20)
            reaper.SetMediaItemTakeInfo_Value(new_take, "D_VOL", info.vol * vol_mult)
            
            -- 随机声像
            local pan_range = {pan_max} - {pan_min}
            local pan_offset = {pan_min} + math.random() * pan_range
            local new_pan = info.pan + pan_offset
            new_pan = math.max(-1, math.min(1, new_pan))
            reaper.SetMediaItemTakeInfo_Value(new_take, "D_PAN", new_pan)
            
            -- 名称
            local filename = reaper.GetMediaSourceFileName(info.source, "")
            local basename = info.name
            if filename and filename ~= "" then
                local backslash = string.char(92)
                local extracted = filename:match("[^/" .. backslash .. "]+$")
                if extracted then
                    basename = extracted:gsub("%.[^%.]+$", "")
                end
            end
            
            local variant_name = "{name_pattern}"
            variant_name = variant_name:gsub("{{original}}", info.name)
            variant_name = variant_name:gsub("{{basename}}", basename)
            variant_name = variant_name:gsub("{{nn}}", string.format("%02d", i))
            variant_name = variant_name:gsub("{{n}}", tostring(i))
            reaper.GetSetMediaItemTakeInfo_String(new_take, "P_NAME", variant_name, true)
            
            total_created = total_created + 1
            
            ::next_variant::
        end
    end
    
    reaper.UpdateArrange()
    reaper.TrackList_AdjustWindows(false)
    
    local result = "✓ 已为 " .. #items_info .. " 个音频创建 " .. total_created .. " 个变体\\n"
    result = result .. "✓ 新建 " .. tracks_created .. " 个轨道\\n\\n"
    result = result .. "布局: 网格排列（纵向多轨道，向右延伸）\\n"
    result = result .. "参数范围:\\n"
    result = result .. "  音高: {pitch_min} 到 {pitch_max} 半音\\n"
    result = result .. "  音量: {volume_min} 到 {volume_max} dB\\n"
    result = result .. "  声像: {pan_min} 到 {pan_max}\\n\\n"
    result = result .. "变体列表:\\n"
    for _, info in ipairs(all_variants_info) do
        result = result .. "  " .. info .. "\\n"
    end
    
    return result
end

return generate_variants()
'''
    return lua_code


def generate_detect_peaks_lua(params):
    """生成峰值检测的Lua代码"""
    threshold_db = float(params.get('threshold', -3))
    # dB转线性幅度
    threshold_linear = 10 ** (threshold_db / 20)
    
    lua_code = f'''
-- 峰值检测器
local function detect_peaks()
    local item = reaper.GetSelectedMediaItem(0, 0)
    if not item then
        return "✗ 错误: 请先选中一个音频item"
    end
    
    local take = reaper.GetActiveTake(item)
    if not take then
        return "✗ 错误: 选中的item没有有效的take"
    end
    
    local source = reaper.GetMediaItemTake_Source(take)
    if not source then
        return "✗ 错误: 无法获取音频源"
    end
    
    local accessor = reaper.CreateTakeAudioAccessor(take)
    if not accessor then
        return "✗ 错误: 无法创建音频访问器"
    end
    
    local source_length = reaper.GetMediaSourceLength(source)
    local num_channels = reaper.GetMediaSourceNumChannels(source)
    local source_sample_rate = reaper.GetMediaSourceSampleRate(source)
    local proj_sample_rate = reaper.GetSetProjectInfo(0, "PROJECT_SRATE", 0, false)
    
    -- 使用工程采样率进行读取
    local sample_rate = proj_sample_rate
    if sample_rate == 0 then
        sample_rate = source_sample_rate
    end
    
    if sample_rate == 0 then
        reaper.DestroyAudioAccessor(accessor)
        return "ERROR: cannot get sample_rate"
    end
    
    -- 分析参数
    local block_size = 4096
    local threshold = {threshold_linear}
    local threshold_db = {threshold_db}
    local peaks_found = {{}}
    local max_peak = 0
    local max_peak_pos = 0
    
    -- 采样缓冲区
    local buffer = reaper.new_array(block_size * num_channels)
    
    -- 遍历音频块（按采样点索引）
    local total_samples = math.floor(source_length * sample_rate)
    local sample_pos = 0
    local loop_count = 0
    local total_samples_got = 0
    while sample_pos < total_samples do
        loop_count = loop_count + 1
        local samples_to_get = math.min(block_size, total_samples - sample_pos)
        if samples_to_get <= 0 then break end
        
        -- GetAudioAccessorSamples 第4个参数是开始时间（秒），不是采样点索引！
        local start_time_sec = sample_pos / sample_rate
        local samples_got = reaper.GetAudioAccessorSamples(accessor, sample_rate, num_channels, start_time_sec, samples_to_get, buffer)
        total_samples_got = total_samples_got + samples_got
        
        if samples_got > 0 then
            for i = 1, samples_got * num_channels do
                local sample = buffer[i]
                local abs_sample = math.abs(sample)
                -- 计算当前采样点对应的时间（秒）
                local current_time = (sample_pos + math.floor((i - 1) / num_channels)) / sample_rate
                
                if abs_sample > max_peak then
                    max_peak = abs_sample
                    max_peak_pos = current_time
                end
                
                if abs_sample > threshold then
                    local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
                    table.insert(peaks_found, {{
                        time = current_time,
                        abs_time = item_pos + current_time,
                        level = abs_sample,
                        level_db = 20 * (math.log(abs_sample) / math.log(10))
                    }})
                end
            end
        end
        
        sample_pos = sample_pos + samples_to_get
        if loop_count > 1000 then break end
    end
    
    reaper.DestroyAudioAccessor(accessor)
    
    -- 合并接近的峰值（去重）
    local merged_peaks = {{}}
    local last_peak_time = -1
    for _, peak in ipairs(peaks_found) do
        if peak.time - last_peak_time > 0.01 then  -- 10ms 最小间隔
            table.insert(merged_peaks, peak)
            last_peak_time = peak.time
        end
    end
    
    -- 生成报告
    local result = "=== 峰值检测报告 ===\\n\\n"
    result = result .. string.format("调试: loops=%d total_got=%d\\n", loop_count, total_samples_got)
    result = result .. string.format("阈值: %.1f dB (%.4f)\\n", threshold_db, threshold)
    result = result .. string.format("最大峰值: %.1f dB @ %.3fs\\n", 
        20 * (math.log(max_peak) / math.log(10)), max_peak_pos)
    result = result .. string.format("超标峰值数量: %d\\n\\n", #merged_peaks)
    
    if #merged_peaks > 0 then
        result = result .. "峰值列表 (前10个):\\n"
        for i = 1, math.min(10, #merged_peaks) do
            local p = merged_peaks[i]
            result = result .. string.format("  %d. %.3fs (%.1f dB)\\n", i, p.abs_time, p.level_db)
        end
        if #merged_peaks > 10 then
            result = result .. string.format("  ... 还有 %d 个峰值\\n", #merged_peaks - 10)
        end
    else
        result = result .. "✓ 没有检测到超过阈值的峰值\\n"
    end
    
    return result
end

return detect_peaks()
'''
    return lua_code


def generate_find_loop_points_lua(params):
    """生成循环点检测的Lua代码 - 方案3：只返回文件路径，由AI脚本调用API分析"""
    track_idx = params.get('track', '')
    item_idx = params.get('item', '')
    
    # 确保 track_idx 和 item_idx 是有效的数字字符串
    track_idx_str = track_idx if track_idx and str(track_idx).strip() else ''
    item_idx_str = item_idx if item_idx and str(item_idx).strip() else ''
    
    # 检查是否为有效数字
    has_track = track_idx_str and track_idx_str.isdigit()
    has_item = item_idx_str and item_idx_str.isdigit()
    
    # 生成 Lua 布尔值
    lua_has_track = 'true' if has_track else 'false'
    lua_has_item = 'true' if has_item else 'false'
    lua_track_idx = track_idx_str if has_track else '0'
    lua_item_idx = item_idx_str if has_item else '0'
    
    # 使用普通字符串拼接，避免f-string与Lua代码冲突
    lua_code = '''
-- 循环点检测器 - 方案3：返回文件路径，由AI脚本调用API分析
local function find_loop_points()
    local item
    local use_selected = true
    
    -- 获取目标item
    if ''' + lua_has_track + ''' and ''' + lua_has_item + ''' then
        local track = reaper.GetTrack(0, ''' + lua_track_idx + ''')
        if track then
            item = reaper.GetTrackMediaItem(track, ''' + lua_item_idx + ''')
            use_selected = false
        end
    end
    
    if use_selected or not item then
        item = reaper.GetSelectedMediaItem(0, 0)
    end
    
    if not item then
        return "[MCP_ERROR] 未找到item，请先选中或指定track和item索引"
    end
    
    local take = reaper.GetActiveTake(item)
    if not take then
        return "[MCP_ERROR] item没有有效的take"
    end
    
    -- 获取音频文件路径
    local source = reaper.GetMediaItemTake_Source(take)
    if not source then
        return "[MCP_ERROR] 无法获取音频源"
    end
    
    -- 检查源类型
    local source_type = reaper.GetMediaSourceType(source)
    
    local filename = reaper.GetMediaSourceFileName(source)
    
    -- 如果是 SECTION 类型，获取父源的文件路径
    if source_type == "SECTION" or not filename or filename == "" then
        local parent_source = reaper.GetMediaSourceParent(source)
        if parent_source then
            filename = reaper.GetMediaSourceFileName(parent_source)
        end
    end
    
    if not filename or filename == "" then
        return "[MCP_ERROR] 无法获取音频文件路径（源类型: " .. tostring(source_type) .. ", 可能是MIDI、内嵌音频或未保存的录音）"
    end
    
    -- 获取item在工程中的位置
    local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    
    -- 如果是SECTION类型，获取截取的起始时间（相对于父文件）
    local section_start = 0
    if source_type == "SECTION" then
        local is_section, start_time, section_len, is_reversed = reaper.PCM_Source_GetSectionInfo(source)
        if is_section then
            section_start = start_time
        end
    end
    
    -- 返回文件路径和位置信息，由AI脚本调用API分析
    -- 格式: [MCP_LOOP_ANALYSIS] 文件路径|item位置|item长度|section起始时间
    return "[MCP_LOOP_ANALYSIS] " .. filename .. "|" .. tostring(item_pos) .. "|" .. tostring(item_length) .. "|" .. tostring(section_start)
end

return find_loop_points()
'''
    return lua_code


def generate_export_regions_lua(params):
    """生成批量导出Regions的Lua代码 - v1.0 音效师专用版"""
    requested_format = str(params.get('format', 'wav')).strip().lower() or 'wav'
    format_type = normalize_render_format(requested_format)
    bitdepth = parse_int_param(params.get('bitdepth'), 24)
    samplerate = parse_samplerate_param(params.get('samplerate'), 48000)
    name_pattern = lua_escape_string(params.get('name_pattern', '{region_name}'))
    output_dir = lua_escape_string(params.get('output_dir', ''))
    tail_ms = float(params.get('tail_ms', 200))

    if format_type not in RENDER_FORMATS:
        safe_format = lua_escape_string(requested_format)
        supported_formats = lua_escape_string(render_format_supported_list())
        return f'''
return "ERROR: Unsupported export format: {safe_format}. Supported render formats: {supported_formats}. Refused fake extension export."
'''
    format_info = RENDER_FORMATS[format_type]
    render_formats = render_formats_lua_table()
    preferred_ext = lua_escape_string(format_info.get("ext", format_type))

    lua_code = f'''
-- 批量导出Regions - v1.0 音效师专用版
-- 特性: 48kHz/立体声/24bit/尾部+200ms/自动检测loop命名
local function export_regions()
    local requested_format = "{lua_escape_string(requested_format)}"
    local format_key = "{format_type}"
    local preferred_ext = "{preferred_ext}"
    local render_formats = {render_formats}

    local function normalize_text(value)
        value = tostring(value or ""):lower()
        value = value:gsub("^%.", "")
        value = value:gsub("[%s_%-%/%(%)]", "")
        return value
    end

    local function sink_to_id(sink)
        sink = tostring(sink or "")
        if #sink < 4 then return nil end
        return sink:byte(1) + sink:byte(2) * 256 + sink:byte(3) * 65536 + sink:byte(4) * 16777216
    end

    local function id_to_sink(id)
        id = tonumber(id or 0) or 0
        if id <= 0 then return "" end
        local chars = {{}}
        for i = 1, 4 do
            local byte = id % 256
            chars[#chars + 1] = string.char(byte)
            id = math.floor(id / 256)
        end
        return table.concat(chars)
    end

    local function clean_ext(ext)
        ext = tostring(ext or ""):lower():gsub("^%.", "")
        ext = ext:match("^[%w]+") or ext
        return ext
    end

    local function sink_extension(sink, fallback_ext)
        local ext = ""
        if reaper.PCM_Sink_GetExtension then
            local value = reaper.PCM_Sink_GetExtension(sink)
            if value then
                ext = clean_ext(value)
            end
        end
        if ext == "" then ext = clean_ext(fallback_ext) end
        return ext
    end

    local function find_format_record(key)
        local wanted = normalize_text(key)
        for _, info in ipairs(render_formats) do
            if normalize_text(info.key) == wanted then return info end
            for _, alias in ipairs(info.aliases or {{}}) do
                if normalize_text(alias) == wanted then return info end
            end
        end
        return nil
    end

    local function sink_desc_matches(desc, ext, info)
        desc = tostring(desc or ""):lower()
        ext = clean_ext(ext)
        for _, term in ipairs(info.terms or {{}}) do
            local t = tostring(term or ""):lower()
            if t ~= "" and (desc:find(t, 1, true) or ext == clean_ext(t)) then
                return true
            end
        end
        return false
    end

    local function enumerate_sink(info)
        if not reaper.PCM_Sink_Enum then return nil end
        local wanted_id = sink_to_id(info.sink or "")
        local idx = 0
        while idx < 256 do
            local sink_id, desc = reaper.PCM_Sink_Enum(idx)
            if not sink_id or tonumber(sink_id) == 0 then break end
            local sink = id_to_sink(sink_id)
            local ext = sink_extension(sink, info.ext)
            if wanted_id and tonumber(sink_id) == wanted_id then
                return sink, ext, desc
            end
            if sink_desc_matches(desc, ext, info) then
                if not info.exact_ext or ext == clean_ext(info.ext) then
                    return sink, ext, desc
                end
            end
            idx = idx + 1
        end
        return nil
    end

    local function resolve_render_format(key)
        local info = find_format_record(key)
        if not info then
            return nil, "Unsupported export format: " .. tostring(requested_format)
        end

        local sink, ext, desc = enumerate_sink(info)
        if sink and sink ~= "" then
            return {{
                key = info.key,
                label = info.label,
                sink = sink,
                ext = ext ~= "" and ext or info.ext,
                use_bits = info.use_bits,
                desc = desc or info.label
            }}
        end

        if tostring(info.sink or "") ~= "" then
            local fallback_ext = sink_extension(info.sink, info.ext)
            return {{
                key = info.key,
                label = info.label,
                sink = info.sink,
                ext = fallback_ext ~= "" and fallback_ext or info.ext,
                use_bits = info.use_bits,
                desc = info.label
            }}
        end

        return nil, "The requested render format '" .. tostring(requested_format) .. "' is not available as a direct REAPER sink on this machine. Open REAPER render settings once or install/configure the matching encoder, then retry. Fake extension export is blocked."
    end

    local render_format, format_error = resolve_render_format(format_key)
    if not render_format then
        return "ERROR: " .. tostring(format_error)
    end

    local region_count = reaper.CountProjectMarkers(0)
    if region_count == 0 then
        return "✗ 错误: 工程中没有Regions"
    end
    
    -- 收集所有Regions
    local regions = {{}}
    local idx = 0
    while idx < region_count do
        local retval, isrgn, pos, rgnend, name, markrgnindexnumber, color = reaper.EnumProjectMarkers3(0, idx)
        if retval and isrgn then
            table.insert(regions, {{
                idx = idx,
                pos = pos,
                end_pos = rgnend,
                name = name,
                number = markrgnindexnumber,
                color = color
            }})
        end
        idx = idx + 1
    end
    
    if #regions == 0 then
        return "✗ 错误: 工程中没有Regions (只有Markers)"
    end
    
    -- 生成时间戳 Mixdown_序号 (os.date 在 REAPER Lua 沙箱中不可用)
    -- 方法：枚举工程目录下所有子目录，找到最大的 Mixdown_序号
    local function normalize_path(path)
        path = tostring(path or ""):gsub("/", "\\\\")
        path = path:gsub("\\\\+$", "")
        return path
    end

    local function path_join(left, right)
        left = normalize_path(left)
        right = tostring(right or ""):gsub("^[/\\\\]+", "")
        if left == "" then return right end
        return left .. "\\\\" .. right
    end

    local function directory_exists(path)
        path = normalize_path(path)
        local parent, leaf = path:match("^(.*)\\\\([^\\\\]+)$")
        if parent and leaf and reaper.EnumerateSubdirectories then
            local idx = 0
            while idx < 10000 do
                local name = reaper.EnumerateSubdirectories(parent, idx)
                if not name or name == "" then break end
                if name == leaf then return true end
                idx = idx + 1
            end
        end
        if reaper.file_exists then
            return reaper.file_exists(path)
        end
        return false
    end

    local function next_mixdown_dir(base_dir)
        local idx = 1
        while idx <= 9999 do
            local candidate = path_join(base_dir, string.format("Mixdown_%03d", idx))
            if not directory_exists(candidate) then
                return candidate
            end
            idx = idx + 1
        end
        local suffix = "overflow"
        if reaper.time_precise then
            suffix = tostring(math.floor(reaper.time_precise()))
        end
        return path_join(base_dir, "Mixdown_" .. suffix)
    end

    local function resolve_project_dir()
        local _, proj_path = reaper.EnumProjects(-1)
        proj_path = tostring(proj_path or "")
        if proj_path ~= "" then
            local dir = proj_path:match("^(.*)[/\\\\][^/\\\\]+$")
            if dir and dir ~= "" then return normalize_path(dir) end
        end

        local fallback = reaper.GetProjectPath("")
        fallback = tostring(fallback or "")
        if fallback ~= "" then
            fallback = normalize_path(fallback)
            local parent, leaf = fallback:match("^(.*)\\\\([^\\\\]+)$")
            if parent and leaf and leaf:lower() == "media" then
                return normalize_path(parent)
            end
            return fallback
        end
        return ""
    end

    local proj_dir = resolve_project_dir()
    if proj_dir == "" then
        return "ERROR: Cannot resolve project directory."
    end

    local configured_output_dir = "{output_dir}"
    local output_path = configured_output_dir
    if output_path == "" then
        output_path = next_mixdown_dir(proj_dir)
    end
    output_path = normalize_path(output_path)
    reaper.RecursiveCreateDirectory(output_path, 0)

    local bitdepth = {bitdepth}
    local samplerate = {samplerate}
    local tail_seconds = {tail_ms / 1000}  -- 尾部延长秒数
    
    local export_results = {{}}
    local success_count = 0

    local function sanitize_export_filename(value)
        value = tostring(value or "")
        local out = {{}}
        for i = 1, #value do
            local byte = value:byte(i)
            local ch = value:sub(i, i)
            if byte == 13 or byte == 10 or byte == 9 then
                ch = " "
            elseif byte == 47 or byte == 92 or byte == 58 or byte == 42 or byte == 63 or byte == 34 or byte == 60 or byte == 62 or byte == 124 then
                ch = "_"
            end
            out[#out + 1] = ch
        end
        value = table.concat(out)
        value = value:gsub("^%s+", ""):gsub("%s+$", "")
        return value
    end
    
    -- 保存当前时间选择
    local orig_start, orig_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
    local _, orig_render_file = reaper.GetSetProjectInfo_String(0, "RENDER_FILE", "", false)
    local _, orig_render_pattern = reaper.GetSetProjectInfo_String(0, "RENDER_PATTERN", "", false)
    local _, orig_render_format = reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT", "", false)
    local orig_render_settings = reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", 0, false)
    local orig_boundsflag = reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", 0, false)
    local orig_srate = reaper.GetSetProjectInfo(0, "RENDER_SRATE", 0, false)
    local orig_resample = reaper.GetSetProjectInfo(0, "RENDER_RESAMPLE", 0, false)
    local orig_channels = reaper.GetSetProjectInfo(0, "RENDER_CHANNELS", 0, false)
    local orig_bits = reaper.GetSetProjectInfo(0, "RENDER_BITS", 0, false)

    local function restore_state()
        reaper.GetSet_LoopTimeRange(true, false, orig_start, orig_end, false)
        reaper.GetSetProjectInfo_String(0, "RENDER_FILE", orig_render_file or "", true)
        reaper.GetSetProjectInfo_String(0, "RENDER_PATTERN", orig_render_pattern or "", true)
        if orig_render_format and orig_render_format ~= "" then
            reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT", orig_render_format, true)
        end
        reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", orig_render_settings or 0, true)
        reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", orig_boundsflag or 1, true)
        reaper.GetSetProjectInfo(0, "RENDER_SRATE", orig_srate or 0, true)
        reaper.GetSetProjectInfo(0, "RENDER_RESAMPLE", orig_resample or 3, true)
        reaper.GetSetProjectInfo(0, "RENDER_CHANNELS", orig_channels or 2, true)
        reaper.GetSetProjectInfo(0, "RENDER_BITS", orig_bits or 24, true)
    end

    local ok, err = pcall(function()

    for i, region in ipairs(regions) do
        -- 检测region名是否包含loop（大小写不敏感）
        local region_name_lower = region.name:lower()
        local is_loop = region_name_lower:match("loop") ~= nil
        
        -- 计算导出结束时间（非loop才加尾部）
        local export_end = region.end_pos
        if not is_loop then
            export_end = export_end + tail_seconds
        end
        
        -- 生成文件名（使用region原名，不添加序号）
        local filename = "{name_pattern}"
        filename = filename:gsub("{{region_name}}", tostring(region.name or ""))
        filename = filename:gsub("{{number}}", tostring(region.number or i))
        if filename == "" or filename == "{{region_name}}" then
            filename = tostring(region.name or "")
        end
        filename = sanitize_export_filename(filename)
        if filename == "" then
            filename = "Region_" .. tostring(region.number or i)
        end

        local ext = clean_ext(render_format.ext)
        if ext == "" then ext = preferred_ext end

        local render_pattern = filename
        if render_pattern:lower():sub(-(#ext + 1)) == "." .. ext then
            render_pattern = render_pattern:sub(1, #render_pattern - #ext - 1)
        end
        if render_pattern == "" then
            render_pattern = "Region_" .. tostring(region.number or i)
        end
        local filename = render_pattern .. "." .. ext

        local full_path = path_join(output_path, filename)

        local file_idx = 1
        local base_filename = render_pattern
        local max_name_attempts = 1000
        while reaper.file_exists(full_path) and file_idx <= max_name_attempts do
            render_pattern = base_filename .. "_" .. string.format("%02d", file_idx)
            filename = render_pattern .. "." .. ext
            full_path = path_join(output_path, filename)
            file_idx = file_idx + 1
        end
        if reaper.file_exists(full_path) then
            table.insert(export_results, string.format("✗ %s - 同名文件过多，已跳过", base_filename))
        else
            -- 设置时间范围（带尾部延长）
            reaper.GetSet_LoopTimeRange(true, false, region.pos, export_end, false)
            
            -- 设置渲染配置
            reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", 0, true)  -- 全工程
            reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", 2, true)  -- 时间选择
            reaper.GetSetProjectInfo(0, "RENDER_SRATE", samplerate, true)
            reaper.GetSetProjectInfo(0, "RENDER_RESAMPLE", 3, true)  -- 高质量重采样
            reaper.GetSetProjectInfo(0, "RENDER_CHANNELS", 2, true)  -- 立体声
            
            -- 设置格式
            reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT", render_format.sink, true)
            if render_format.use_bits then
                reaper.GetSetProjectInfo(0, "RENDER_BITS", bitdepth, true)
            end
            
            -- 设置输出路径
            reaper.GetSetProjectInfo_String(0, "RENDER_FILE", output_path, true)
            reaper.GetSetProjectInfo_String(0, "RENDER_PATTERN", render_pattern, true)
            
            -- 执行渲染
            local render_result = reaper.Main_OnCommand(42230, 0)  -- File: Render project to disk
            
            if reaper.file_exists(full_path) then
                local tail_info = ""
                if not is_loop then
                    tail_info = string.format(" +%.0fms尾部", tail_seconds * 1000)
                else
                    tail_info = " (loop无尾部)"
                end
                table.insert(export_results, string.format("✓ %s (%.3fs - %.3fs)%s", filename, region.pos, export_end, tail_info))
                success_count = success_count + 1
            else
                table.insert(export_results, string.format("✗ %s - 渲染失败", filename))
            end
        end
    end
    
    -- 恢复时间选择
    end)

    restore_state()
    if not ok then
        return "ERROR: Region export failed, render state restored: " .. tostring(err)
    end
    
    -- 生成报告
    local result = "=== 批量导出报告 ===\\n\\n"
    result = result .. string.format("输出目录: %s\\n", output_path)
    result = result .. string.format("格式: %s (%s)\\n", render_format.key, render_format.label or "")
    result = result .. string.format("位深: {bitdepth} bit\\n")
    result = result .. string.format("采样率: {samplerate} Hz\\n\\n")
    result = result .. string.format("成功: %d / %d\\n\\n", success_count, #regions)
    
    result = result .. "导出列表:\\n"
    for _, info in ipairs(export_results) do
        result = result .. "  " .. info .. "\\n"
    end
    
    return result
end

return export_regions()
'''
    return lua_code


def _bool_param(params, key, default=False):
    value = params.get(key, default)
    if isinstance(value, bool):
        return value
    return str(value or "").strip().lower() in ("1", "true", "yes", "y", "on")


def parse_int_param(value, default):
    text = str(value or "").strip().lower()
    if not text:
        return default
    match = re.search(r'\d+', text)
    if not match:
        return default
    try:
        return int(match.group(0))
    except ValueError:
        return default


def parse_samplerate_param(value, default=48000):
    text = str(value or "").strip().lower()
    if not text:
        return default
    match = re.search(r'(\d+(?:\.\d+)?)', text)
    if not match:
        return default
    try:
        rate = float(match.group(1))
    except ValueError:
        return default
    if 'k' in text and rate < 1000:
        rate *= 1000
    elif rate < 1000:
        rate *= 1000
    return int(round(rate))


def generate_export_mixdown_lua(params, source_type):
    """Generate Lua for track/master exports using the same Mixdown_### flow."""
    requested_format = str(params.get('format', '')).strip().lower() or 'wav'
    format_type = normalize_render_format(requested_format)
    bitdepth = parse_int_param(params.get('bitdepth'), 24)
    samplerate = parse_samplerate_param(params.get('samplerate'), 48000)
    output_dir = lua_escape_string(params.get('output_dir', ''))
    name_pattern = lua_escape_string(params.get('name_pattern', ''))
    selected = _bool_param(params, 'selected', False)
    all_tracks = _bool_param(params, 'all', False)
    tracks_scope = str(params.get('tracks', '')).strip().lower()
    if tracks_scope in ('selected', 'selection', 'current', 'selected_tracks', '选中', '当前选中'):
        selected = True
    elif tracks_scope in ('all', 'true', '1', 'yes', 'y', '全部', '所有', '所有轨道'):
        all_tracks = True
        selected = False
    bounds = str(params.get('bounds', '')).strip().lower()

    if format_type not in RENDER_FORMATS:
        safe_format = lua_escape_string(requested_format)
        supported_formats = lua_escape_string(render_format_supported_list())
        return f'''
return "ERROR: Unsupported export format: {safe_format}. Supported render formats: {supported_formats}. Refused fake extension export."
'''

    format_info = RENDER_FORMATS[format_type]
    render_formats = render_formats_lua_table()
    preferred_ext = lua_escape_string(format_info.get("ext", format_type))
    source_type = "tracks" if source_type == "tracks" else "master"
    if not name_pattern:
        name_pattern = "{track_name}" if source_type == "tracks" else "Master"

    lua_code = f'''
local function export_mixdown()
    local source_type = "{source_type}"
    local requested_format = "{lua_escape_string(requested_format)}"
    local format_key = "{format_type}"
    local preferred_ext = "{preferred_ext}"
    local render_formats = {render_formats}
    local configured_output_dir = "{output_dir}"
    local name_pattern = "{name_pattern}"
    local selected_only = {lua_bool(selected)}
    local all_tracks = {lua_bool(all_tracks)}
    local bounds = "{lua_escape_string(bounds)}"
    local bitdepth = {bitdepth}
    local samplerate = {samplerate}

    local function normalize_text(value)
        value = tostring(value or ""):lower():gsub("^%.", "")
        value = value:gsub("[%s_%-%/%(%)]", "")
        return value
    end

    local function sink_to_id(sink)
        sink = tostring(sink or "")
        if #sink < 4 then return nil end
        return sink:byte(1) + sink:byte(2) * 256 + sink:byte(3) * 65536 + sink:byte(4) * 16777216
    end

    local function id_to_sink(id)
        id = tonumber(id or 0) or 0
        if id <= 0 then return "" end
        local chars = {{}}
        for i = 1, 4 do
            local byte = id % 256
            chars[#chars + 1] = string.char(byte)
            id = math.floor(id / 256)
        end
        return table.concat(chars)
    end

    local function clean_ext(ext)
        ext = tostring(ext or ""):lower():gsub("^%.", "")
        ext = ext:match("^[%w]+") or ext
        return ext
    end

    local function sink_extension(sink, fallback_ext)
        local ext = ""
        if reaper.PCM_Sink_GetExtension then
            local value = reaper.PCM_Sink_GetExtension(sink)
            if value then ext = clean_ext(value) end
        end
        if ext == "" then ext = clean_ext(fallback_ext) end
        return ext
    end

    local function find_format_record(key)
        local wanted = normalize_text(key)
        for _, info in ipairs(render_formats) do
            if normalize_text(info.key) == wanted then return info end
            for _, alias in ipairs(info.aliases or {{}}) do
                if normalize_text(alias) == wanted then return info end
            end
        end
        return nil
    end

    local function sink_desc_matches(desc, ext, info)
        desc = tostring(desc or ""):lower()
        ext = clean_ext(ext)
        for _, term in ipairs(info.terms or {{}}) do
            local t = tostring(term or ""):lower()
            if t ~= "" and (desc:find(t, 1, true) or ext == clean_ext(t)) then return true end
        end
        return false
    end

    local function enumerate_sink(info)
        if not reaper.PCM_Sink_Enum then return nil end
        local wanted_id = sink_to_id(info.sink or "")
        local idx = 0
        while idx < 256 do
            local sink_id, desc = reaper.PCM_Sink_Enum(idx)
            if not sink_id or tonumber(sink_id) == 0 then break end
            local sink = id_to_sink(sink_id)
            local ext = sink_extension(sink, info.ext)
            if wanted_id and tonumber(sink_id) == wanted_id then return sink, ext, desc end
            if sink_desc_matches(desc, ext, info) then
                if not info.exact_ext or ext == clean_ext(info.ext) then return sink, ext, desc end
            end
            idx = idx + 1
        end
        return nil
    end

    local function resolve_render_format(key)
        local info = find_format_record(key)
        if not info then return nil, "Unsupported export format: " .. tostring(requested_format) end
        local sink, ext, desc = enumerate_sink(info)
        if sink and sink ~= "" then
            return {{ key = info.key, label = info.label, sink = sink, ext = ext ~= "" and ext or info.ext, use_bits = info.use_bits, desc = desc or info.label }}
        end
        if tostring(info.sink or "") ~= "" then
            local fallback_ext = sink_extension(info.sink, info.ext)
            return {{ key = info.key, label = info.label, sink = info.sink, ext = fallback_ext ~= "" and fallback_ext or info.ext, use_bits = info.use_bits, desc = info.label }}
        end
        return nil, "The requested render format '" .. tostring(requested_format) .. "' is not available as a direct REAPER sink on this machine. Fake extension export is blocked."
    end

    local render_format, format_error = resolve_render_format(format_key)
    if not render_format then return "ERROR: " .. tostring(format_error) end

    local function normalize_path(path)
        path = tostring(path or ""):gsub("/", "\\\\"):gsub("\\\\+$", "")
        return path
    end

    local function path_join(left, right)
        left = normalize_path(left)
        right = tostring(right or ""):gsub("^[/\\\\]+", "")
        if left == "" then return right end
        return left .. "\\\\" .. right
    end

    local function directory_exists(path)
        path = normalize_path(path)
        local parent, leaf = path:match("^(.*)\\\\([^\\\\]+)$")
        if parent and leaf and reaper.EnumerateSubdirectories then
            local idx = 0
            while idx < 10000 do
                local name = reaper.EnumerateSubdirectories(parent, idx)
                if not name or name == "" then break end
                if name == leaf then return true end
                idx = idx + 1
            end
        end
        if reaper.file_exists then return reaper.file_exists(path) end
        return false
    end

    local function next_mixdown_dir(base_dir)
        local idx = 1
        while idx <= 9999 do
            local candidate = path_join(base_dir, string.format("Mixdown_%03d", idx))
            if not directory_exists(candidate) then return candidate end
            idx = idx + 1
        end
        local suffix = reaper.time_precise and tostring(math.floor(reaper.time_precise())) or "overflow"
        return path_join(base_dir, "Mixdown_" .. suffix)
    end

    local function resolve_project_dir()
        local _, proj_path = reaper.EnumProjects(-1)
        proj_path = tostring(proj_path or "")
        if proj_path ~= "" then
            local dir = proj_path:match("^(.*)[/\\\\][^/\\\\]+$")
            if dir and dir ~= "" then return normalize_path(dir) end
        end

        local fallback = reaper.GetProjectPath("")
        fallback = tostring(fallback or "")
        if fallback ~= "" then
            fallback = normalize_path(fallback)
            local parent, leaf = fallback:match("^(.*)\\\\([^\\\\]+)$")
            if parent and leaf and leaf:lower() == "media" then
                return normalize_path(parent)
            end
            return fallback
        end
        return ""
    end

    local function sanitize_export_filename(value)
        value = tostring(value or "")
        local out = {{}}
        for i = 1, #value do
            local byte = value:byte(i)
            local ch = value:sub(i, i)
            if byte == 13 or byte == 10 or byte == 9 then
                ch = " "
            elseif byte == 47 or byte == 92 or byte == 58 or byte == 42 or byte == 63 or byte == 34 or byte == 60 or byte == 62 or byte == 124 then
                ch = "_"
            end
            out[#out + 1] = ch
        end
        value = table.concat(out):gsub("^%s+", ""):gsub("%s+$", "")
        if value == "" then value = "Export" end
        return value
    end

    local proj_dir = resolve_project_dir()
    if proj_dir == "" then return "ERROR: Cannot resolve project directory." end

    local output_path = configured_output_dir
    if output_path == "" then output_path = next_mixdown_dir(proj_dir) end
    output_path = normalize_path(output_path)
    reaper.RecursiveCreateDirectory(output_path, 0)

    local ext = clean_ext(render_format.ext)
    if ext == "" then ext = preferred_ext end

    local function unique_render_pattern(base_pattern)
        base_pattern = sanitize_export_filename(base_pattern)
        if base_pattern:lower():sub(-(#ext + 1)) == "." .. ext then
            base_pattern = base_pattern:sub(1, #base_pattern - #ext - 1)
        end
        local render_pattern = base_pattern
        local full_path = path_join(output_path, render_pattern .. "." .. ext)
        local idx = 1
        while reaper.file_exists(full_path) and idx <= 1000 do
            render_pattern = base_pattern .. "_" .. string.format("%02d", idx)
            full_path = path_join(output_path, render_pattern .. "." .. ext)
            idx = idx + 1
        end
        return render_pattern, full_path
    end

    local function get_track_name(track, fallback)
        local ok, name = reaper.GetTrackName(track)
        name = ok and name or ""
        if name == "" then name = fallback end
        return name
    end

    local function resolve_boundsflag(start_pos, end_pos)
        local normalized = tostring(bounds or ""):lower():gsub("%s+", "_"):gsub("-", "_")
        if normalized == "time_selection" or normalized == "selection" or normalized == "time" or normalized == "选区" or normalized == "时间选区" then
            return 2, "时间选区"
        end
        if normalized == "project" or normalized == "entire_project" or normalized == "all" or normalized == "whole_project" or normalized == "工程" or normalized == "整个工程" then
            return 1, "整个工程"
        end
        if end_pos and start_pos and end_pos > start_pos + 0.000001 then
            return 2, "时间选区(自动)"
        end
        return 1, "整个工程(自动)"
    end

    local targets = {{}}
    if source_type == "tracks" then
        if selected_only then
            local count = reaper.CountSelectedTracks(0)
            if count <= 0 then return "ERROR: No selected tracks to export." end
            for i = 0, count - 1 do
                local track = reaper.GetSelectedTrack(0, i)
                if track then targets[#targets + 1] = {{ track = track, index = i, name = get_track_name(track, "Track_" .. tostring(i + 1)) }} end
            end
        else
            local count = reaper.CountTracks(0)
            if count <= 0 then return "ERROR: No tracks to export." end
            for i = 0, count - 1 do
                local track = reaper.GetTrack(0, i)
                if track then targets[#targets + 1] = {{ track = track, index = i, name = get_track_name(track, "Track_" .. tostring(i + 1)) }} end
            end
        end
    else
        targets[#targets + 1] = {{ name = "Master", index = 0 }}
    end

    local orig_start, orig_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
    local _, orig_render_file = reaper.GetSetProjectInfo_String(0, "RENDER_FILE", "", false)
    local _, orig_render_pattern = reaper.GetSetProjectInfo_String(0, "RENDER_PATTERN", "", false)
    local _, orig_render_format = reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT", "", false)
    local orig_render_settings = reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", 0, false)
    local orig_boundsflag = reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", 0, false)
    local orig_srate = reaper.GetSetProjectInfo(0, "RENDER_SRATE", 0, false)
    local orig_resample = reaper.GetSetProjectInfo(0, "RENDER_RESAMPLE", 0, false)
    local orig_channels = reaper.GetSetProjectInfo(0, "RENDER_CHANNELS", 0, false)
    local orig_bits = reaper.GetSetProjectInfo(0, "RENDER_BITS", 0, false)

    local selected_states = {{}}
    local track_count = reaper.CountTracks(0)
    for i = 0, track_count - 1 do
        local track = reaper.GetTrack(0, i)
        selected_states[i + 1] = track and reaper.IsTrackSelected(track) or false
    end

    local function restore_state()
        reaper.GetSet_LoopTimeRange(true, false, orig_start, orig_end, false)
        reaper.GetSetProjectInfo_String(0, "RENDER_FILE", orig_render_file or "", true)
        reaper.GetSetProjectInfo_String(0, "RENDER_PATTERN", orig_render_pattern or "", true)
        if orig_render_format and orig_render_format ~= "" then reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT", orig_render_format, true) end
        reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", orig_render_settings or 0, true)
        reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", orig_boundsflag or 1, true)
        reaper.GetSetProjectInfo(0, "RENDER_SRATE", orig_srate or 0, true)
        reaper.GetSetProjectInfo(0, "RENDER_RESAMPLE", orig_resample or 3, true)
        reaper.GetSetProjectInfo(0, "RENDER_CHANNELS", orig_channels or 2, true)
        reaper.GetSetProjectInfo(0, "RENDER_BITS", orig_bits or 24, true)
        for i = 0, track_count - 1 do
            local track = reaper.GetTrack(0, i)
            if track then reaper.SetTrackSelected(track, selected_states[i + 1] and true or false) end
        end
        reaper.TrackList_AdjustWindows(false)
        reaper.UpdateArrange()
    end

    local render_results = {{}}
    local success_count = 0
    local boundsflag, bounds_label = resolve_boundsflag(orig_start, orig_end)

    local function set_common_render_settings(render_settings, render_pattern)
        reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", render_settings, true)
        reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", boundsflag, true)
        reaper.GetSetProjectInfo(0, "RENDER_SRATE", samplerate, true)
        reaper.GetSetProjectInfo(0, "RENDER_RESAMPLE", 3, true)
        reaper.GetSetProjectInfo(0, "RENDER_CHANNELS", 2, true)
        reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT", render_format.sink, true)
        if render_format.use_bits then reaper.GetSetProjectInfo(0, "RENDER_BITS", bitdepth, true) end
        reaper.GetSetProjectInfo_String(0, "RENDER_FILE", output_path, true)
        reaper.GetSetProjectInfo_String(0, "RENDER_PATTERN", render_pattern, true)
    end

    local function strip_render_extension(pattern)
        pattern = tostring(pattern or "")
        if pattern:lower():sub(-(#ext + 1)) == "." .. ext then
            pattern = pattern:sub(1, #pattern - #ext - 1)
        end
        return pattern
    end

    local function native_track_render_pattern()
        local pattern = name_pattern
        pattern = pattern:gsub("{{track_name}}", "$track")
        pattern = pattern:gsub("{{track_index}}", "$tracknumber")
        pattern = pattern:gsub("{{source}}", "tracks")
        pattern = strip_render_extension(pattern)
        pattern = sanitize_export_filename(pattern)
        if pattern == "" or pattern == "{{track_name}}" then pattern = "$track" end
        if not pattern:find("$track", 1, true) and not pattern:find("$tracknumber", 1, true) then
            pattern = pattern .. "_$track"
        end
        return pattern
    end

    local function split_render_targets(value)
        local paths = {{}}
        value = tostring(value or "")
        for part in value:gmatch("[^;]+") do
            part = normalize_path(part:gsub("^%s+", ""):gsub("%s+$", ""))
            if part ~= "" then paths[#paths + 1] = part end
        end
        return paths
    end

    local function render_target_basename(path)
        path = tostring(path or ""):gsub("/", "\\\\")
        return path:match("[^\\\\]+$") or path
    end

    local function render_targets_are_track_files(paths)
        if #paths < #targets then
            return false, string.format("RENDER_TARGETS returned %d files for %d tracks", #paths, #targets)
        end
        if #paths == 1 then
            local one = render_target_basename(paths[1]):lower()
            if one == "master." .. ext or one:match("^master%.") then
                return false, "RENDER_TARGETS is Master only"
            end
        end
        local master_count = 0
        for _, path in ipairs(paths) do
            local name = render_target_basename(path):lower()
            if name == "master." .. ext or name:match("^master%.") then
                master_count = master_count + 1
            end
        end
        if master_count > 0 and #paths <= #targets then
            return false, "RENDER_TARGETS contains Master instead of track stems"
        end
        return true, ""
    end

    local function current_render_targets()
        local _, target_text = reaper.GetSetProjectInfo_String(0, "RENDER_TARGETS", "", false)
        return split_render_targets(target_text)
    end

    local function choose_track_render_source(render_pattern)
        local candidates = {{
            {{ settings = 2, label = "selected tracks stems" }},
            {{ settings = 128, label = "selected tracks via master" }}
        }}
        local last_reason = ""
        for _, candidate in ipairs(candidates) do
            set_common_render_settings(candidate.settings, render_pattern)
            local paths = current_render_targets()
            local ok_targets, reason = render_targets_are_track_files(paths)
            if ok_targets then
                return candidate, paths
            end
            last_reason = candidate.label .. ": " .. tostring(reason)
        end
        return nil, {{}}, last_reason
    end

    local fatal_error = nil

    local ok, err = pcall(function()
        if source_type == "tracks" then
            for i = 0, track_count - 1 do
                local track = reaper.GetTrack(0, i)
                if track then reaper.SetTrackSelected(track, false) end
            end
            for _, target in ipairs(targets) do
                if target.track then reaper.SetTrackSelected(target.track, true) end
            end
            reaper.TrackList_AdjustWindows(false)
            reaper.UpdateArrange()

            local render_pattern = native_track_render_pattern()
            local source_choice, render_paths, source_error = choose_track_render_source(render_pattern)
            if not source_choice then
                fatal_error = "Track export refused before rendering because REAPER would not target track stem files. Last check: " .. tostring(source_error)
                return
            end
            reaper.Main_OnCommand(42230, 0)

            for _, full_path in ipairs(render_paths) do
                if reaper.file_exists(full_path) then
                    success_count = success_count + 1
                    table.insert(render_results, string.format("OK %s", full_path))
                else
                    table.insert(render_results, string.format("MISSING %s", full_path))
                end
            end
            if success_count < #targets then
                fatal_error = string.format("Track export rendered %d / %d expected stem files. Source used: %s. No success report was issued.", success_count, #targets, source_choice.label)
            else
                table.insert(render_results, 1, string.format("Source used: %s (RENDER_SETTINGS=%d)", source_choice.label, source_choice.settings))
            end
        else
            local target = targets[1]
            local pattern = name_pattern
            pattern = pattern:gsub("{{track_name}}", tostring(target.name or ""))
            pattern = pattern:gsub("{{track_index}}", tostring((target.index or 0) + 1))
            pattern = pattern:gsub("{{source}}", source_type)
            if pattern == "" or pattern == "{{track_name}}" then pattern = tostring(target.name or "Export") end
            local render_pattern, full_path = unique_render_pattern(pattern)

            set_common_render_settings(0, render_pattern)
            reaper.Main_OnCommand(42230, 0)

            if reaper.file_exists(full_path) then
                success_count = success_count + 1
                table.insert(render_results, string.format("OK %s", full_path))
            else
                table.insert(render_results, string.format("FAILED %s", full_path))
            end
        end
    end)

    restore_state()
    if not ok then
        return "ERROR: Export failed, render state restored: " .. tostring(err)
    end
    if fatal_error then
        local result = "ERROR: " .. fatal_error .. "\\n\\n"
        result = result .. string.format("Output dir: %s\\n", output_path)
        result = result .. string.format("Render source requested: %s\\n", source_type == "tracks" and "track stems" or "master mix")
        result = result .. string.format("Format: %s (%s)\\n", render_format.key, render_format.label or "")
        result = result .. string.format("Bounds: %s\\n\\n", bounds_label)
        for _, info in ipairs(render_results) do
            result = result .. "  " .. info .. "\\n"
        end
        return result
    end

    local label = source_type == "tracks" and "Tracks" or "Master"
    local result = "=== Export " .. label .. " Report ===\\n\\n"
    result = result .. string.format("Output dir: %s\\n", output_path)
    result = result .. string.format("Render source: %s\\n", source_type == "tracks" and "verified track stem render targets (one native render, $track pattern)" or "master mix")
    result = result .. string.format("Format: %s (%s)\\n", render_format.key, render_format.label or "")
    result = result .. string.format("Bounds: %s\\n", bounds_label)
    result = result .. string.format("Sample rate: %d Hz\\n", samplerate)
    result = result .. string.format("Bit depth: %d bit\\n", bitdepth)
    result = result .. string.format("Success: %d / %d\\n\\n", success_count, #targets)
    for _, info in ipairs(render_results) do
        result = result .. "  " .. info .. "\\n"
    end
    return result
end

return export_mixdown()
'''
    return lua_code


def generate_export_tracks_lua(params):
    """Export all or selected tracks as individual stem files."""
    return generate_export_mixdown_lua(params, "tracks")


def generate_export_master_lua(params):
    """Export the master mix as one file."""
    return generate_export_mixdown_lua(params, "master")


# ============================================================
# MCP Endpoint Registry - 动态功能列表
# ============================================================

MCP_ENDPOINTS = {
    "transport/play": {
        "description": "播放工程",
        "params": {},
        "example": "[MCP_CALL:transport/play]"
    },
    "transport/stop": {
        "description": "停止播放工程",
        "params": {},
        "example": "[MCP_CALL:transport/stop]"
    },
    "track/create": {
        "description": "Create tracks. For multiple exact names, prefer one call with names=A,B,C instead of create plus rename steps.",
        "params": {
            "name": "base track name; with count>1 creates name 1, name 2...",
            "names": "comma/semicolon/pipe separated exact names for newly created tracks",
            "count": "number of tracks to create; if names has more entries, names count wins",
            "volume": "initial volume, supports dB like -5dB"
        },
        "example": "[MCP_CALL:track/create?names=Guitar,Bass,Drums]"
    },
    "track/delete": {
        "description": "删除轨道；name 用于名字目标，match/contains/keyword 用于“名字里包含xxx”的批量删除",
        "params": {
            "index": "轨道索引(从0开始)",
            "selected": "true 表示删除选中轨道",
            "name": "轨道名称；无精确匹配时会按包含匹配",
            "match": "关键词；删除所有精确或包含匹配的轨道",
            "contains": "同 match，用于名字里包含关键词的批量删除",
            "keyword": "同 match",
            "all": "true 表示删除全部轨道"
        },
        "example": "[MCP_CALL:track/delete?match=打击乐]"
    },
    "track/rename": {
        "description": "重命名轨道（支持 index 或 target/old_name/from/track_name 查找）",
        "params": {"index": "轨道索引", "target": "原轨道名称或关键词", "name": "新名称"},
        "example": "[MCP_CALL:track/rename?target=打击乐&name=Drums]"
    },
    "track/set_volume": {
        "description": "设置轨道音量（支持 index、name、selected=true 或 all=true）",
        "params": {"index": "轨道索引", "name": "轨道名称或关键词", "selected": "true表示选中轨道", "all": "true表示全部轨道", "volume": "音量值(0-1或dB值如-12dB)"},
        "example": "[MCP_CALL:track/set_volume?name=打击乐&volume=-10dB]"
    },
    "track/set_pan": {
        "description": "设置轨道声像（支持 index、name、selected=true 或 all=true）",
        "params": {"index": "轨道索引", "name": "轨道名称或关键词", "selected": "true表示选中轨道", "all": "true表示全部轨道", "pan": "声像值(-1左到1右)"},
        "example": "[MCP_CALL:track/set_pan?name=吉他&pan=-0.5]"
    },
    "track/set_color": {
        "description": "设置轨道颜色（支持 index、name、selected=true 或 all=true；color 支持中文/英文颜色名、#RRGGBB、r,g,b，或 default/clear 清除自定义颜色）",
        "params": {"index": "轨道索引", "name": "轨道名称或关键词", "selected": "true表示选中轨道", "all": "true表示全部轨道", "color": "颜色，如 红色/red/#FF0000/255,0,0；default/clear 表示恢复默认色"},
        "example": "[MCP_CALL:track/set_color?name=bass&color=红色]"
    },
    "track/clear_color": {
        "description": "Clear track custom color and restore theme/default track color. Supports index, name, selected=true, or all=true.",
        "params": {"index": "track index", "name": "track name or keyword", "selected": "true targets selected tracks", "all": "true targets all tracks"},
        "example": "[MCP_CALL:track/clear_color?all=true]"
    },
    "item/set_color": {
        "description": "Set MediaItem color only. Supports selected=true, all=true, index, name/match, or time_selection=true; color supports Chinese/English color names, #RRGGBB, r,g,b, or default/clear.",
        "params": {"index": "0-based item index", "name": "active take name or keyword", "match": "alias of name", "selected": "true targets selected items", "all": "true targets all items", "time_selection": "true targets items overlapping the time selection", "scope": "selected/current/time_selection", "color": "color name, #RRGGBB, r,g,b, or default/clear"},
        "example": "[MCP_CALL:item/set_color?selected=true&color=黄色]"
    },
    "track/mute": {
        "description": "静音/取消静音轨道（支持 index、name、selected=true 或 all=true）",
        "params": {"index": "轨道索引", "name": "轨道名称或关键词", "selected": "true表示选中轨道", "all": "true表示全部轨道", "mute": "true/false"},
        "example": "[MCP_CALL:track/mute?name=参考&mute=true]"
    },
    "track/solo": {
        "description": "独奏/取消独奏轨道（支持 index、name、selected=true 或 all=true）",
        "params": {"index": "轨道索引", "name": "轨道名称或关键词", "selected": "true表示选中轨道", "all": "true表示全部轨道", "solo": "true/false"},
        "example": "[MCP_CALL:track/solo?name=人声&solo=true]"
    },
    "track/add_fx": {
        "description": "添加效果器到轨道（支持 track 索引/名称、name 或 selected=true）",
        "params": {"track": "轨道索引或名称", "name": "轨道名称或关键词", "selected": "true表示选中轨道", "fx": "效果器名称", "fx_name": "效果器名称别名"},
        "example": "[MCP_CALL:track/add_fx?selected=true&fx=ReaEQ]"
    },
    "track/remove_fx": {
        "description": "移除轨道上的效果器（track 可传索引或轨道名，也支持 name）",
        "params": {"track": "轨道索引或名称", "name": "轨道名称或关键词", "fx_index": "效果器索引"},
        "example": "[MCP_CALL:track/remove_fx?track=人声&fx_index=0]"
    },
    "track/set_volume_by_name": {
        "description": "按名称设置轨道音量（无需知道索引）",
        "params": {
            "name": "轨道名称",
            "volume": "音量值(0-1或dB值如-12dB)"
        },
        "example": "[MCP_CALL:track/set_volume_by_name?name=打击乐 3&volume=-10dB]"
    },
    "track/group_into_folder": {
        "description": "创建文件夹轨道，并把匹配到的轨道移动进去（用于鼓组、脚步组、UI组等）",
        "params": {
            "folder_name": "文件夹轨道名称",
            "tracks": "轨道名称/关键词/索引列表，用逗号分隔",
            "match": "按关键词匹配多个轨道，如 鼓 或 Drum"
        },
        "example": "[MCP_CALL:track/group_into_folder?folder_name=鼓&match=鼓]"
    },
    "track/create_folder": {
        "description": "track/group_into_folder 的别名",
        "params": {
            "folder_name": "文件夹轨道名称",
            "tracks": "轨道名称/关键词/索引列表，用逗号分隔",
            "match": "按关键词匹配多个轨道"
        },
        "example": "[MCP_CALL:track/create_folder?folder_name=Drums&tracks=Kick,Snare,Hat]"
    },
    "marker/add": {
        "description": "添加标记",
        "params": {"time": "时间(可选,默认光标位置)", "name": "标记名称"},
        "example": "[MCP_CALL:marker/add?name=Verse]"
    },
    "marker/delete": {
        "description": "删除 Marker；永远只删除 isrgn=false 的 Marker，保留所有 Region。删除 Region 必须使用 region/delete。",
        "params": {"index": "单个 Marker id", "ids": "逗号/空格分隔的 Marker id 列表", "range": "Marker id 范围，如 1-5", "start": "Marker id 范围起点", "end": "Marker id 范围终点", "name": "按 Marker 名称包含匹配", "match": "name 的别名", "all": "true 表示删除所有 Marker，但保留 Region"},
        "example": "[MCP_CALL:marker/delete?all=true]"
    },
    "region/delete": {
        "description": "Delete Region(s) by displayed Region id, id range, ids list, name match, timeline order, or all=true. Selection and exclusion scopes are compiled by the generic Action Protocol selector layer. Do not use marker/delete for Region deletion.",
        "params": {
            "index": "Single Region id, for example 15 or R15",
            "start": "First Region id in a numeric range",
            "end": "Last Region id in a numeric range",
            "range": "Region id range such as 15-20 or R15-R20",
            "ids": "Comma/space separated Region ids",
            "order_start": "Timeline order start, 1-based after sorting Regions by position",
            "order_end": "Timeline order end, 1-based after sorting Regions by position",
            "order_range": "Timeline order range such as 5-10",
            "name": "Substring match for Region name",
            "match": "Alias of name",
            "all": "true deletes all Regions"
        },
        "example": "[MCP_CALL:region/delete?start=15&end=20]"
    },
    "region/set_color": {
        "description": "Set Region color only. Supports displayed Region id/range/ids/name/all and contextual selected/current/time_selection Region scopes. This endpoint never targets Markers.",
        "params": {"index": "Single Region id, for example 15 or R15", "range": "Region id range such as 15-20 or R15-R20", "ids": "Comma/space separated Region ids", "start": "First Region id in a numeric range", "end": "Last Region id in a numeric range", "order_start": "Timeline order start, 1-based after sorting Regions by position", "order_end": "Timeline order end, 1-based after sorting Regions by position", "name": "Substring match for Region name", "match": "Alias of name", "selected": "true uses ReaperAI's inferred selected Region from the time selection", "scope": "selected/current/time_selection", "all": "true sets all Regions", "color": "Color name, #RRGGBB, r,g,b, or default/clear"},
        "example": "[MCP_CALL:region/set_color?selected=true&color=黄色]"
    },
    "item/fade": {
        "description": "设置素材自身淡入/淡出长度，只修改 item 的 D_FADEINLEN/D_FADEOUTLEN，不写包络；默认作用于选中素材",
        "params": {
            "selected": "true 表示所有选中素材；省略目标时默认选中素材",
            "index": "素材索引，从0开始",
            "name": "按 active take 名称精确或包含匹配一个素材",
            "fade_in": "淡入长度，单位秒",
            "fade_out": "淡出长度，单位秒",
            "fade_in_ms": "淡入长度，单位毫秒",
            "fade_out_ms": "淡出长度，单位毫秒"
        },
        "example": "[MCP_CALL:item/fade?selected=true&fade_in_ms=80&fade_out_ms=120]"
    },
    "item/set_fade": {
        "description": "item/fade 的别名，用于设置素材自身 fade 属性",
        "params": {
            "selected": "true 表示所有选中素材；省略目标时默认选中素材",
            "index": "素材索引，从0开始",
            "in": "淡入长度，单位秒",
            "out": "淡出长度，单位秒",
            "in_ms": "淡入长度，单位毫秒",
            "out_ms": "淡出长度，单位毫秒"
        },
        "example": "[MCP_CALL:item/set_fade?selected=true&in=0.08&out=0.12]"
    },
    "item/fade_shape": {
        "description": "设置素材 fade 曲线形状并读回校验；用于把 fade in/out 曲线改为直线/线性。shape=linear 会设置 C_FADEINSHAPE/C_FADEOUTSHAPE=0，并默认把 D_FADEINDIR/D_FADEOUTDIR 归零",
        "params": {
            "selected": "true 表示所有选中素材；省略目标时默认选中素材",
            "all": "true 表示扫描所有素材",
            "index": "素材索引，从0开始",
            "name": "按 active take 名称精确或包含匹配一个素材",
            "shape": "形状；linear/直线/线性 或 0-6 数字，默认 linear",
            "direction": "in/out/both，默认 both",
            "has_fade": "true 时只处理已有淡入/淡出的边，默认 true",
            "reset_curve": "true 时同时把 D_FADEINDIR/D_FADEOUTDIR 设为0，默认 true"
        },
        "example": "[MCP_CALL:item/fade_shape?all=true&shape=linear]"
    },
    "item/set_fade_shape": {
        "description": "item/fade_shape 的别名，用于设置素材 fade 曲线形状",
        "params": {
            "selected": "true 表示所有选中素材；省略目标时默认选中素材",
            "all": "true 表示扫描所有素材",
            "shape": "linear/直线/线性 或 0-6 数字，默认 linear",
            "direction": "in/out/both，默认 both"
        },
        "example": "[MCP_CALL:item/set_fade_shape?selected=true&shape=linear]"
    },
    "native/action": {
        "description": "执行本机 REAPER Action；用于冻结/解冻/胶合等 MCP 未覆盖的原生命令。系统会从本机 Action Inventory 查真实命令，不要在 SCRIPT 里裸写 Main_OnCommand",
        "params": {
            "command_id": "本机数字 Action ID；如果已知可直接传",
            "action": "高层动作，例如 freeze/unfreeze/glue",
            "mode": "freeze 模式：stereo/mono/multichannel，默认 stereo",
            "selected": "true 表示作用于当前选中轨道",
            "target_track": "按轨道名定位并临时选中后执行",
            "restore_selection": "true 时执行后恢复原轨道选择"
        },
        "example": "[MCP_CALL:native/action?action=freeze&mode=stereo&target_track=混响轨]"
    },
    "envelope/draw": {
        "description": "绘制轨道或Item/Take包络，支持按name/关键词/index/selected定位，支持音量/声像/静音和常用形状；item/take不写start/end时默认覆盖整个素材",
        "params": {
            "target": "track/item/take/selected_envelope；不要用 target=selected，选中素材请用 target=item&selected=true，选中包络请用 selected_envelope；省略时有选中item则自动用item，否则用track",
            "name": "轨道名或Item Take名关键词",
            "index": "轨道或Item索引，从0开始",
            "selected": "true表示使用选中轨道/Item",
            "lane": "volume/pan/mute",
            "start": "开始时间秒；可省略。item按item内部相对时间理解，也会自动识别落在item范围内的工程绝对时间",
            "end": "结束时间秒；item默认可省略，省略时覆盖整个item",
            "time_selection": "true时才使用当前时间选区；item会自动取时间选区和item的交集",
            "relative": "item时间是否按item内部相对时间计算，默认true",
            "absolute": "true时才按工程绝对时间",
            "shape": "line/fade_in/fade_out/hold/sine/pulse/triangle",
            "from": "起点值，volume支持-12dB或0.25，pan支持-1到1或百分比",
            "to": "终点值",
            "steps": "曲线点数量，默认16",
            "replace": "true清掉范围内旧点后再画，默认true"
        },
        "example": "[MCP_CALL:envelope/draw?target=item&selected=true&lane=volume&shape=line&from=-60dB&to=0dB]"
    },
    "envelope/clear": {
        "description": "清理轨道或Item/Take在指定时间范围内的包络点，定位参数同envelope/draw",
        "params": {
            "target": "track/item/take/selected_envelope；不要用 target=selected，选中素材请用 target=item&selected=true",
            "name": "轨道名或Item Take名关键词",
            "index": "轨道或Item索引",
            "selected": "true表示使用选中轨道/Item",
            "lane": "volume/pan/mute",
            "start": "开始时间秒；可省略",
            "end": "结束时间秒",
            "time_selection": "true时使用当前时间选区；item会自动取时间选区和item的交集",
            "relative": "item时间是否按item内部相对时间计算，默认true",
            "absolute": "true时才按工程绝对时间"
        },
        "example": "[MCP_CALL:envelope/clear?target=item&selected=true&lane=volume&time_selection=true]"
    },
    "region/batch_rename": {
        "description": "【批量重命名】支持 search/replace 子串替换；old_prefix/new_prefix 前缀替换；old_prefix 为空时给所有 Region 添加前缀，可选编号",
        "params": {
            "search": "要查找的子串，如 IG",
            "replace": "替换成的文本，如 OG",
            "old_prefix": "原前缀；可为空，表示匹配所有 Region",
            "new_prefix": "新前缀；添加前缀时必填",
            "apply_prefix_with_index": "true 时按 Region 顺序添加编号，如 SFX_01_原名",
            "separator": "前缀/编号/原名之间的分隔符，默认 _"
        },
        "example": "[MCP_CALL:region/batch_rename?old_prefix=&new_prefix=SFX&apply_prefix_with_index=true]"
    },
    # === 游戏音效师专用功能 ===
    "sfx/generate_variants": {
        "description": "【游戏音效】基于选中音频生成多个变体，网格布局（每个变体在新轨道，向右排列）",
        "params": {
            "count": "生成数量(默认5)",
            "pitch_variation": "音高变化范围±半音(替代pitch_min/max)",
            "pitch_min": "音高最小值(半音,默认-3)",
            "pitch_max": "音高最大值(半音,默认+3)",
            "volume_variation": "音量变化范围±dB(替代volume_min/max)",
            "gain_variation": "同volume_variation,别名兼容",
            "volume_min": "音量最小值(dB,默认-3)",
            "volume_max": "音量最大值(dB,默认+3)",
            "pan_variation": "声像变化范围±(-1到1,替代pan_min/max)",
            "spectral_variation": "频谱变化0-100(映射为声像变化,别名兼容)",
            "pan_min": "声像最小值(-1到1,默认-0.3)",
            "pan_max": "声像最大值(-1到1,默认0.3)",
            "name_pattern": "命名模式(默认{original}_{nn})"
        },
        "example": "[MCP_CALL:sfx/generate_variants?count=8&pitch_variation=3&gain_variation=6&name_pattern=Footstep_Grass_{nn}]"
    },
    "analysis/detect_peaks": {
        "description": "【音频分析】检测音频中的峰值(削波检测)",
        "params": {
            "threshold": "峰值阈值(dB,默认-3)"
        },
        "example": "[MCP_CALL:analysis/detect_peaks?threshold=-6]"
    },
    "analysis/find_loop_points": {
        "description": "【音频分析】自动检测最佳循环点(基于零交叉和波形相似度)",
        "params": {
            "track": "轨道索引(可选,默认选中item)",
            "item": "item索引(可选,默认选中item)",
            "search_start": "搜索开始时间(秒,默认0)",
            "search_end": "搜索结束时间(秒,默认音频结尾)"
        },
        "example": "[MCP_CALL:analysis/find_loop_points]"
    },
    "export/batch_regions": {
        "description": "【批量导出】批量导出所有Regions为真实REAPER渲染格式文件(自动创建递增Mixdown_###目录)",
        "params": {
            "format": "必填渲染格式: wav/aiff/caf/flac/mp3/ogg/opus/raw/cue/ddp/wavpack/mp4/wmv/gif/lcf；不明确时必须先澄清，不能默认wav",
            "bitdepth": "位深(16/24/32,默认24；用户未指定时使用24)",
            "samplerate": "采样率(44100/48000/48k等,默认48000；用户未指定时使用48000)",
            "tail_ms": "尾部延长毫秒(默认200,region名含loop则自动取消)",
            "output_dir": "输出目录(可选；为空时默认工程根目录/Mixdown_001、Mixdown_002递增)"
        },
        "example": "[MCP_CALL:export/batch_regions?format=wav] 导出所有Regions到递增Mixdown文件夹"
    },
    "export/tracks": {
        "description": "Export all or selected tracks as separate stem files in an auto-incrementing Mixdown_### folder.",
        "params": {
            "format": "Required render format: wav/aiff/caf/flac/mp3/ogg/opus/raw/cue/ddp/wavpack/mp4/wmv/gif/lcf",
            "selected": "true exports selected tracks only",
            "all": "true exports all tracks",
            "tracks": "Optional alias: all or selected",
            "bounds": "Optional: time_selection or project. Omit to auto-use current time selection when present, otherwise project.",
            "bitdepth": "Bit depth, default 24 when omitted",
            "samplerate": "Sample rate, default 48000 when omitted; accepts values like 44100, 48000, 48k",
            "name_pattern": "Filename pattern, default {track_name}; supports {track_name}/{track_index}",
            "output_dir": "Optional output directory; empty means project/Mixdown_###"
        },
        "example": "[MCP_CALL:export/tracks?format=wav&all=true]"
    },
    "export/master": {
        "description": "Export the master mix as one real REAPER render-format file in an auto-incrementing Mixdown_### folder.",
        "params": {
            "format": "Required render format: wav/aiff/caf/flac/mp3/ogg/opus/raw/cue/ddp/wavpack/mp4/wmv/gif/lcf",
            "bounds": "Optional: time_selection or project. Omit to auto-use current time selection when present, otherwise project.",
            "bitdepth": "Bit depth, default 24 when omitted",
            "samplerate": "Sample rate, default 48000 when omitted; accepts values like 44100, 48000, 48k",
            "name_pattern": "Filename pattern, default Master",
            "output_dir": "Optional output directory; empty means project/Mixdown_###"
        },
        "example": "[MCP_CALL:export/master?format=wav]"
    }
}

MCP_ENDPOINTS.update({
    "track/set_color": {
        "description": "Set track color. Supports single and batch targets: index/range/ids/order_start/order_end/name/selected/all; color supports Chinese/English names, #RRGGBB, r,g,b, or default/clear.",
        "params": {
            "index": "0-based track index",
            "range": "0-based track index range such as 2-6",
            "ids": "Comma/space separated 0-based track indexes",
            "start": "0-based range start",
            "end": "0-based range end",
            "order_start": "1-based track order start",
            "order_end": "1-based track order end",
            "name": "track name or keyword",
            "match": "alias of name",
            "selected": "true targets selected tracks",
            "all": "true targets all tracks",
            "color": "color, for example red/#FF0000/255,0,0/default/clear"
        },
        "example": "[MCP_CALL:track/set_color?range=2-6&color=yellow]"
    },
    "track/clear_color": {
        "description": "Clear track custom color and restore theme/default track color. Supports index/range/ids/order_start/order_end/name/selected/all.",
        "params": {
            "index": "0-based track index",
            "range": "0-based track index range such as 2-6",
            "ids": "Comma/space separated 0-based track indexes",
            "order_start": "1-based track order start",
            "order_end": "1-based track order end",
            "name": "track name or keyword",
            "selected": "true targets selected tracks",
            "all": "true targets all tracks"
        },
        "example": "[MCP_CALL:track/clear_color?ids=0,2,4]"
    },
    "item/set_color": {
        "description": "Set MediaItem color only. Supports selected=true, all=true, index/range/ids/order_start/order_end, name/match, current, or time_selection=true; color supports Chinese/English color names, #RRGGBB, r,g,b, or default/clear.",
        "params": {
            "index": "0-based item index",
            "range": "0-based item index range such as 2-6",
            "ids": "Comma/space separated 0-based item indexes",
            "start": "0-based range start",
            "end": "0-based range end",
            "order_start": "1-based item order start",
            "order_end": "1-based item order end",
            "name": "active take name or keyword",
            "match": "alias of name",
            "selected": "true targets selected items",
            "all": "true targets all items",
            "time_selection": "true targets items overlapping the time selection",
            "scope": "selected/current/time_selection",
            "color": "color name, #RRGGBB, r,g,b, or default/clear"
        },
        "example": "[MCP_CALL:item/set_color?order_start=1&order_end=3&color=yellow]"
    }
})

# ============================================================
# Main
# ============================================================

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument('--reaper-projects-dir', 
                       default=CONFIG.get("reaper_projects_dir", "."),
                       help="Base directory for REAPER projects")
    parser.add_argument('--reaper-resource-path', 
                       default=CONFIG.get("reaper_resource_path") or None,
                       help="REAPER resource path")
    parser.add_argument('--port', type=int, 
                       default=CONFIG.get("server", {}).get("port", 8765),
                       help="HTTP server port (default: 8765)")
    parser.add_argument('--host', 
                       default=CONFIG.get("server", {}).get("host", "127.0.0.1"),
                       help="HTTP server host (default: 127.0.0.1)")
    args = parser.parse_args()

    app.config["PROJECTS_DIR"] = args.reaper_projects_dir
    app.config["REAPER_RESOURCE_PATH"] = args.reaper_resource_path

    print(f"Starting REAPER MCP HTTP API v1.0 (MCP-First)...")
    print(f"Projects directory: {args.reaper_projects_dir}")
    print(f"REAPER resource path: {args.reaper_resource_path}")
    print(f"API endpoint: http://{args.host}:{args.port}")
    print(f"\nMCP Endpoints available:")
    print(f"  POST /mcp/parse - Parse [MCP_CALL:...] format")
    print(f"  GET  /command_queue - Poll for commands")
    print(f"  POST /submit_result - Submit execution results")
    print(f"\nQuick Actions:")
    print(f"  POST /track/create, /track/add_fx")
    print(f"  POST /marker/add, /marker/delete, /region/delete, /region/set_color, /item/set_color")
    print(f"\nPress Ctrl+C to stop\n")

    app.run(host=args.host, port=args.port, debug=False)
