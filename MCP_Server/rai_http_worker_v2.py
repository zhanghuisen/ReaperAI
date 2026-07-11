#!/usr/bin/env python3
"""
REAPER AI 异步 HTTP Worker - 文件信号版
作者：zhanghuisen
版本：v1.0
由 Lua 调用，执行 HTTP 请求后通过信号文件通知 REAPER

用法: python rai_http_worker_v2.py <request_id> <api_url> <key_file> <model> <msg_file> <resp_file> <signal_file> [mode]

v1.0 新增 mode 参数:
  - mode 省略或为 "llm": 调用 LLM API (默认)
  - mode 为 "elevenlabs": 调用 ElevenLabs API 生成音频

v1.0 elevenlabs 模式参数:
  - api_url 参数变为 config.txt 路径（用于读取 LLM 配置和 voice_id）
  - key_file 仍存放 ElevenLabs API Key
  - 新增智能分流：根据关键词自动选择 TTS(语音) 或 Sound Effects(音效)
  - 中文提示词自动调用 LLM 翻译为英文
"""

import sys
import os
import json
import time
import traceback
import subprocess
import shutil
import re

RESPONSE_TIMEOUT = 90  # 秒
TEMP_DIR = os.environ.get('TEMP', 'C:\\Temp')
ELEVENLABS_TIMEOUT = 180  # 音频生成可能需要更长时间
SFX_DURATION_SECONDS = 4.0  # 固定短音效时长，避免 Sound Effects 长时间排队
VOICE_LIST_TIMEOUT = 30
VOICE_PROBE_TIMEOUT = 8  # 刷新声线时的可用性探针超时
VOICE_PROBE_TEXT = "test"
MAX_VOICE_PROBES = 40
ELEVENLABS_EXPRESSIVE_MODEL = "eleven_v3"
ELEVENLABS_STABLE_MODEL = "eleven_multilingual_v2"

# ============================================
# v1.0+ ElevenLabs 免费语音库（内置，用户无需手动配置）
# 每个 voice 带标签用于关键词匹配和 LLM 选择
# ============================================
FREE_VOICES = [
    # id, 性别, 中文标签, 英文标签
    {"id": "21m00Tcm4TlvDq8ikWAM", "gender": "female", "tags": ["标准", "默认", "女声", "女生", "标准女声", "播音", "新闻", "正式", "通用", "rachel", "standard", "default", "female"]},
    {"id": "AZnzlk1XvdvUeBnXmlld", "gender": "female", "tags": ["沉稳", "稳重", "成熟", "女声", "知性", "优雅", "domi", "mature", "calm", "elegant"]},
    {"id": "EXAVITQu4vr4xnSDxMaL", "gender": "female", "tags": ["甜蜜", "甜", "可爱", "温柔", "甜美", "女声", "女生", "少女", "bella", "sweet", "cute", "gentle", "soft"]},
    {"id": "MF3mGyEYCl7XYWbV9V6O", "gender": "female", "tags": ["年轻", "活泼", "青春", "女声", "女生", "少女", "elli", "young", "youthful", "energetic"]},
    {"id": "piTKgcLEGmPE4e6mEKli", "gender": "female", "tags": ["温柔", "轻声", "柔和", "女声", "nicole", "gentle", "soft", "whisper"]},
    {"id": "pFZP5JQG7iQjIQuC4Bku", "gender": "female", "tags": ["温柔", "年轻", "女声", "lily", "gentle", "young"]},
    {"id": "TxGEqnHWrfWFTfGW9XjX", "gender": "male", "tags": ["标准", "默认", "男声", "男生", "低沉", "稳重", "josh", "standard", "default", "male", "deep"]},
    {"id": "ErXwobaYiN019PkySvjV", "gender": "male", "tags": ["标准", "男声", "清晰", "antoni", "standard", "male", "clear"]},
    {"id": "VR6AewLTigWG4xSOukaG", "gender": "male", "tags": ["沙哑", "磁性", "粗犷", "沧桑", "有力", "男声", "低沉", "arnold", "husky", "raspy", "rough", "powerful"]},
    {"id": "pNInz6obpgDQGcFmaJgB", "gender": "male", "tags": ["播音", "新闻", "正式", "男声", "播报", "沉稳", "adam", "news", "anchor", "formal", "serious"]},
    {"id": "yoZ06aMxZJJ28mfd3POQ", "gender": "male", "tags": ["老年", "沧桑", "成熟", "男声", "老人", "sam", "old", "elder", "mature"]},
    {"id": "ZQe5CZNOzWyzPSCn5a3c", "gender": "male", "tags": ["澳大利亚", "澳洲", "口音", "男声", "james", "australian", "accent"]},
    {"id": "zrHiDhphv9ZnVXBqCLhn", "gender": "female", "tags": ["澳大利亚", "澳洲", "口音", "女声", "mimi", "australian", "accent"]},
]

FREE_VOICE_DISPLAY_NAMES = {
    "21m00Tcm4TlvDq8ikWAM": "Rachel",
    "AZnzlk1XvdvUeBnXmlld": "Domi",
    "EXAVITQu4vr4xnSDxMaL": "Bella",
    "MF3mGyEYCl7XYWbV9V6O": "Elli",
    "piTKgcLEGmPE4e6mEKli": "Nicole",
    "pFZP5JQG7iQjIQuC4Bku": "Lily",
    "TxGEqnHWrfWFTfGW9XjX": "Josh",
    "ErXwobaYiN019PkySvjV": "Antoni",
    "VR6AewLTigWG4xSOukaG": "Arnold",
    "pNInz6obpgDQGcFmaJgB": "Adam",
    "yoZ06aMxZJJ28mfd3POQ": "Sam",
    "ZQe5CZNOzWyzPSCn5a3c": "James",
    "zrHiDhphv9ZnVXBqCLhn": "Mimi",
}

FREE_VOICE_IDS = {voice["id"] for voice in FREE_VOICES}

# 日志函数（保留用于故障排查）
def log(msg):
    log_file = os.path.join(TEMP_DIR, 'rai_worker_startup.log')
    with open(log_file, 'a', encoding='utf-8') as f:
        f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} - {msg}\n")
        f.flush()

# 紧急调试日志（保留用于启动失败时排查）
EMERGENCY_LOG = os.path.join(TEMP_DIR, 'rai_worker_EMERGENCY.log')
def emergency_log(msg):
    with open(EMERGENCY_LOG, 'a', encoding='utf-8') as f:
        f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} - {msg}\n")

try:
    import requests
except Exception as e:
    emergency_log(f"导入 requests 失败: {e}")
    traceback.print_exc()
    sys.exit(1)


def read_text_file_smart(path, strip_bom=True):
    """Read text files written by REAPER/Lua across Windows encodings."""
    last_error = None
    encodings = ("utf-8-sig", "utf-8", "gb18030", "gbk", "mbcs")
    for encoding in encodings:
        try:
            with open(path, 'r', encoding=encoding) as f:
                text = f.read()
            if strip_bom:
                text = text.lstrip("\ufeff")
            if encoding not in ("utf-8-sig", "utf-8"):
                log(f"以 {encoding} 读取文本文件: {path}")
            return text
        except UnicodeDecodeError as e:
            last_error = e
        except LookupError as e:
            last_error = e
        except Exception:
            raise

    with open(path, 'r', encoding='utf-8', errors='replace') as f:
        text = f.read()
    if strip_bom:
        text = text.lstrip("\ufeff")
    log(f"文本文件使用 utf-8 replace 兜底读取: {path}; 原错误: {last_error}")
    return text


def read_messages(msg_file):
    """从文件读取消息列表"""
    try:
        content = read_text_file_smart(msg_file)
        return json.loads(content), None
    except Exception as e:
        return None, f"读取消息文件失败: {e}"


def extract_content_from_response(response_text):
    """从 API 响应中提取 content 字段
    
    支持多种格式：
    - 标准 OpenAI 格式: {"choices": [{"message": {"content": "..."}}]}
    - DeepSeek Reasoner 格式: {"choices": [{"message": {"content": "...", "reasoning_content": "..."}}]}
    """
    try:
        data = json.loads(response_text)
        
        # 获取 choices
        choices = data.get("choices", [])
        if not choices:
            # 检查是否有 error 字段
            if "error" in data:
                error_msg = data["error"].get("message") or data["error"].get("error") or str(data["error"])
                return None, f"API错误: {error_msg}"
            return None, "响应中没有 choices"
        
        first_choice = choices[0]
        
        # 检查 finish_reason 是否为 "length"（表示被截断）
        finish_reason = first_choice.get("finish_reason", "")
        if finish_reason == "length":
            content = first_choice.get("message", {}).get("content", "")
            # 添加截断标记
            return content + "\n\n[警告：响应被截断，内容可能不完整]", None
        
        # 尝试标准格式: choices[0].message.content
        content = first_choice.get("message", {}).get("content", "")
        if content:
            return content, None
        
        # 尝试从 data 字段获取（某些 API 可能包装了一层）
        if isinstance(data.get("data"), str):
            return extract_content_from_response(data["data"])
        
        # 检查是否有 error 字段
        if "error" in data:
            error_msg = data["error"].get("message") or data["error"].get("error") or str(data["error"])
            return None, f"API错误: {error_msg}"
        
        # 无法提取 content
        return None, "无法从响应中提取 content 字段"
        
    except json.JSONDecodeError as e:
        return None, f"JSON解析失败: {e}"
    except Exception as e:
        return None, f"提取 content 失败: {e}"


def llm_temperature_for_request(api_url):
    """Return a provider-compatible temperature value for OpenAI-compatible APIs."""
    api_url_lower = (api_url or "").lower()
    if "api.moonshot.cn" in api_url_lower:
        return 1
    return 0.7


def build_llm_payload(api_url, model, messages):
    """Build a conservative OpenAI-compatible chat completions payload."""
    return {
        "model": model,
        "messages": messages,
        "temperature": llm_temperature_for_request(api_url),
        "max_tokens": 4096  # 增加 token 限制避免截断
    }


def payload_signature(payload):
    return json.dumps(payload, sort_keys=True, ensure_ascii=False)


def llm_payload_fallbacks(payload, error_text):
    """Generate vendor-compatible fallback payloads when an OpenAI-compatible API rejects optional params."""
    text = (error_text or "").lower()
    candidates = []

    def add(candidate):
        if payload_signature(candidate) != payload_signature(payload):
            candidates.append(candidate)

    if "temperature" in text:
        if payload.get("temperature") != 1:
            candidate = dict(payload)
            candidate["temperature"] = 1
            add(candidate)
        if "temperature" in payload:
            candidate = dict(payload)
            candidate.pop("temperature", None)
            add(candidate)

    if "max_tokens" in text or "max token" in text:
        if "max_tokens" in payload:
            candidate = dict(payload)
            candidate.pop("max_tokens", None)
            add(candidate)

            candidate = dict(payload)
            max_tokens = candidate.pop("max_tokens", None)
            if max_tokens is not None:
                candidate["max_completion_tokens"] = max_tokens
                add(candidate)

    if ("unsupported" in text or "invalid" in text or "unrecognized" in text) and (
        "temperature" not in text and "max_tokens" not in text and "max token" not in text
    ):
        candidate = dict(payload)
        candidate.pop("temperature", None)
        add(candidate)

        candidate = dict(payload)
        candidate.pop("temperature", None)
        candidate.pop("max_tokens", None)
        add(candidate)

    return candidates


def post_llm_payload(api_url, headers, payload, stream=False):
    return requests.post(
        api_url,
        headers=headers,
        json=payload,
        timeout=RESPONSE_TIMEOUT,
        stream=stream,
    )


def make_api_request(api_url, api_key, model, messages):
    """调用 LLM API 并提取 content"""
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {api_key}"
    }

    try:
        payload = build_llm_payload(api_url, model, messages)
        response = post_llm_payload(api_url, headers, payload)

        # 如果是错误响应，记录详情
        if response.status_code != 200:
            error_detail = response.text[:500] if len(response.text) > 500 else response.text
            for fallback_payload in llm_payload_fallbacks(payload, error_detail):
                fallback_response = post_llm_payload(api_url, headers, fallback_payload)
                if fallback_response.status_code == 200:
                    response = fallback_response
                    break
                error_detail = fallback_response.text[:500] if len(fallback_response.text) > 500 else fallback_response.text
            else:
                return {"success": False, "error": f"API 错误 {response.status_code}: {error_detail}"}

        if response.status_code != 200:
            error_detail = response.text[:500] if len(response.text) > 500 else response.text
            return {"success": False, "error": f"API 错误 {response.status_code}: {error_detail}"}

        # 解析并提取 content
        content, error = extract_content_from_response(response.text)
        if error:
            return {"success": False, "error": error}
        
        return {"success": True, "content": content}
        
    except requests.exceptions.Timeout:
        return {"success": False, "error": "请求超时（90秒）"}
    except requests.exceptions.RequestException as e:
        return {"success": False, "error": f"网络错误: {str(e)}"}
    except Exception as e:
        return {"success": False, "error": f"未知错误: {str(e)}"}


def write_signal_file(signal_file):
    with open(signal_file, 'w') as f:
        f.write("done")


def write_stream_event(resp_file, event):
    os.makedirs(os.path.dirname(resp_file) or ".", exist_ok=True)
    with open(resp_file, 'a', encoding='utf-8', newline='\n') as f:
        f.write(json.dumps(event, ensure_ascii=False) + "\n")
        f.flush()


def finish_stream(resp_file, signal_file, content):
    write_stream_event(resp_file, {"type": "done", "content": content or ""})
    write_signal_file(signal_file)
    return {"success": True, "content": content or ""}


def fail_stream(resp_file, signal_file, error):
    message = str(error or "未知错误")
    write_stream_event(resp_file, {"type": "error", "message": message})
    write_signal_file(signal_file)
    return {"success": False, "error": message}


def stream_content_delta(data):
    if not isinstance(data, dict):
        return ""
    choices = data.get("choices")
    if not isinstance(choices, list):
        return ""

    parts = []
    for choice in choices:
        if not isinstance(choice, dict):
            continue
        delta = choice.get("delta")
        if isinstance(delta, dict):
            content = delta.get("content")
            if content:
                parts.append(str(content))
            continue

        message = choice.get("message")
        if isinstance(message, dict) and message.get("content"):
            parts.append(str(message.get("content")))

    return "".join(parts)


def stream_reasoning_delta(data):
    if not isinstance(data, dict):
        return ""
    choices = data.get("choices")
    if not isinstance(choices, list):
        return ""

    parts = []
    reasoning_keys = ("reasoning_content", "reasoning", "thinking", "thinking_content")
    for choice in choices:
        if not isinstance(choice, dict):
            continue
        for holder_key in ("delta", "message"):
            holder = choice.get(holder_key)
            if not isinstance(holder, dict):
                continue
            for key in reasoning_keys:
                value = holder.get(key)
                if isinstance(value, str) and value:
                    parts.append(value)
            content = holder.get("content")
            if isinstance(content, list):
                for item in content:
                    if not isinstance(item, dict):
                        continue
                    item_type = str(item.get("type") or "").lower()
                    if item_type in ("reasoning", "reasoning_text", "thinking", "thinking_text"):
                        text = item.get("text") or item.get("content") or item.get("reasoning")
                        if isinstance(text, str) and text:
                            parts.append(text)

    return "".join(parts)


def stream_tool_call_events(data):
    if not isinstance(data, dict):
        return []
    choices = data.get("choices")
    if not isinstance(choices, list):
        return []

    events = []
    for choice in choices:
        if not isinstance(choice, dict):
            continue
        for holder_key in ("delta", "message"):
            holder = choice.get(holder_key)
            if not isinstance(holder, dict):
                continue

            calls = holder.get("tool_calls")
            if isinstance(calls, list):
                for call in calls:
                    if not isinstance(call, dict):
                        continue
                    fn = call.get("function")
                    if not isinstance(fn, dict):
                        fn = {}
                    name = fn.get("name") or call.get("name") or ""
                    arguments = fn.get("arguments") or call.get("arguments") or ""
                    call_id = call.get("id") or ""
                    call_type = call.get("type") or "tool"
                    index = call.get("index")
                    if name or arguments or call_id:
                        events.append({
                            "type": "tool_call",
                            "index": "" if index is None else str(index),
                            "id": str(call_id or ""),
                            "call_type": str(call_type or "tool"),
                            "name": str(name or ""),
                            "arguments": str(arguments or ""),
                        })

            function_call = holder.get("function_call")
            if isinstance(function_call, dict):
                name = function_call.get("name") or ""
                arguments = function_call.get("arguments") or ""
                if name or arguments:
                    events.append({
                        "type": "tool_call",
                        "index": "function_call",
                        "id": "",
                        "call_type": "function",
                        "name": str(name or ""),
                        "arguments": str(arguments or ""),
                    })

    return events


def stream_finish_reasons(data):
    choices = data.get("choices") if isinstance(data, dict) else None
    if not isinstance(choices, list):
        return []
    reasons = []
    for choice in choices:
        if isinstance(choice, dict) and choice.get("finish_reason"):
            reasons.append(str(choice.get("finish_reason")))
    return reasons


def stream_has_length_finish(data):
    choices = data.get("choices") if isinstance(data, dict) else None
    if not isinstance(choices, list):
        return False
    return any(isinstance(choice, dict) and choice.get("finish_reason") == "length" for choice in choices)


def make_api_stream_request(api_url, api_key, model, messages, resp_file, signal_file):
    """调用 OpenAI-compatible Chat Completions streaming API and write JSONL events."""
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {api_key}"
    }

    try:
        payload = build_llm_payload(api_url, model, messages)
        payload["stream"] = True
        response = post_llm_payload(api_url, headers, payload, stream=True)

        if response.status_code != 200:
            error_detail = response.text[:500] if len(response.text) > 500 else response.text
            for fallback_payload in llm_payload_fallbacks(payload, error_detail):
                fallback_payload = dict(fallback_payload)
                fallback_payload["stream"] = True
                fallback_response = post_llm_payload(api_url, headers, fallback_payload, stream=True)
                if fallback_response.status_code == 200:
                    response = fallback_response
                    break
                error_detail = fallback_response.text[:500] if len(fallback_response.text) > 500 else fallback_response.text
            else:
                # If a provider rejects stream outright, degrade gracefully to one-shot output.
                if "stream" in (error_detail or "").lower():
                    fallback = make_api_request(api_url, api_key, model, messages)
                    if fallback.get("success"):
                        content = fallback.get("content", "")
                        write_stream_event(resp_file, {"type": "start"})
                        if content:
                            write_stream_event(resp_file, {"type": "delta", "content": content})
                        return finish_stream(resp_file, signal_file, content)
                    return fail_stream(resp_file, signal_file, fallback.get("error"))
                return fail_stream(resp_file, signal_file, f"API 错误 {response.status_code}: {error_detail}")

        write_stream_event(resp_file, {"type": "start"})
        content_parts = []
        truncated = False

        for raw_line in response.iter_lines(decode_unicode=False):
            if isinstance(raw_line, bytes):
                raw_line = raw_line.decode("utf-8", errors="replace")
            if not raw_line:
                continue
            line = raw_line.strip()
            if not line or line.startswith(":"):
                continue
            if line.startswith("data:"):
                line = line[5:].strip()
            if not line:
                continue
            if line == "[DONE]":
                break

            try:
                data = json.loads(line)
            except json.JSONDecodeError:
                log(f"跳过无法解析的 streaming 行: {line[:200]}")
                continue

            if isinstance(data, dict) and data.get("error"):
                err = data["error"]
                if isinstance(err, dict):
                    err = err.get("message") or err.get("error") or str(err)
                return fail_stream(resp_file, signal_file, f"API错误: {err}")

            reasoning_delta = stream_reasoning_delta(data)
            if reasoning_delta:
                write_stream_event(resp_file, {"type": "reasoning_delta", "content": reasoning_delta})

            for tool_event in stream_tool_call_events(data):
                write_stream_event(resp_file, tool_event)

            for finish_reason in stream_finish_reasons(data):
                write_stream_event(resp_file, {"type": "finish", "finish_reason": finish_reason})

            delta = stream_content_delta(data)
            if delta:
                content_parts.append(delta)
                write_stream_event(resp_file, {"type": "delta", "content": delta})
            if stream_has_length_finish(data):
                truncated = True

        content = "".join(content_parts)
        if truncated:
            warning = "\n\n[警告：响应被截断，内容可能不完整]"
            content += warning
            write_stream_event(resp_file, {"type": "delta", "content": warning})

        return finish_stream(resp_file, signal_file, content)

    except requests.exceptions.Timeout:
        return fail_stream(resp_file, signal_file, "请求超时（90秒）")
    except requests.exceptions.RequestException as e:
        return fail_stream(resp_file, signal_file, f"网络错误: {str(e)}")
    except Exception as e:
        return fail_stream(resp_file, signal_file, f"未知错误: {str(e)}")


def make_models_request(models_url, api_key):
    """Fetch OpenAI-compatible model ids from a /models endpoint."""
    headers = {"Accept": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"

    try:
        response = requests.get(models_url, headers=headers, timeout=RESPONSE_TIMEOUT)
        if response.status_code != 200:
            error_detail = response.text[:500] if len(response.text) > 500 else response.text
            return {"success": False, "error": f"Models API 错误 {response.status_code}: {error_detail}"}

        data = response.json()
        raw_models = []
        if isinstance(data, dict):
            if isinstance(data.get("data"), list):
                raw_models = data.get("data")
            elif isinstance(data.get("models"), list):
                raw_models = data.get("models")
            elif isinstance(data.get("model"), list):
                raw_models = data.get("model")
        elif isinstance(data, list):
            raw_models = data

        ids = []
        seen = set()
        for item in raw_models:
            model_id = None
            if isinstance(item, dict):
                model_id = item.get("id") or item.get("name") or item.get("model")
            elif isinstance(item, str):
                model_id = item
            if not model_id:
                continue
            model_id = str(model_id).strip()
            if not model_id or model_id in seen:
                continue
            seen.add(model_id)
            ids.append(model_id)

        if not ids:
            return {"success": False, "error": "Models API 响应中没有可用 model id"}

        return {"success": True, "content": "\n".join(ids), "count": len(ids)}

    except requests.exceptions.Timeout:
        return {"success": False, "error": "Models API 请求超时"}
    except requests.exceptions.RequestException as e:
        return {"success": False, "error": f"Models API 网络错误: {str(e)}"}
    except Exception as e:
        return {"success": False, "error": f"Models API 未知错误: {str(e)}"}


def parse_config_file(config_path):
    """解析 ReaperAI_config.txt 配置文件（键值对格式）
    
    v1.0+ 新增：为 ElevenLabs 智能分流提供完整配置
    """
    config = {
        "llm_url": "https://api.openai.com/v1/chat/completions",
        "llm_key": "",
        "llm_model": "gpt-5.5",
        "elevenlabs_key": "",
    }
    if not config_path or not os.path.exists(config_path):
        return config
    
    try:
        for line in read_text_file_smart(config_path).splitlines():
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            if '=' not in line:
                continue
            key, value = line.split('=', 1)
            key = key.strip()
            value = value.strip()
            if key == "LLM_API_URL":
                config["llm_url"] = value
            elif key == "LLM_API_KEY":
                config["llm_key"] = value
            elif key == "LLM_MODEL":
                config["llm_model"] = value
            elif key == "ELEVENLABS_API_KEY":
                config["elevenlabs_key"] = value
            # v1.0+ ELEVENLABS_VOICE_ID 已废弃，Voice 由 worker 智能选择
    except Exception as e:
        log(f"解析配置文件失败: {e}")
    
    return config


def extract_voice_preference(text):
    """从用户输入中提取 Voice 偏好和纯文本内容
    
    v1.0+ 新增：解析 "11用甜蜜女生语音说你好" → ("甜蜜女生语音", "你好")
    返回: (preference_str, clean_text)  preference_str 可能为空
    """
    text_lower = text.lower()
    
    # 常见 voice 引导词模式（中英文）
    patterns = [
        # 中文模式
        r"生成一个(.+?)说(.+)",
        r"生成一段(.+?)说(.+)",
        r"生成(.+?)说(.+)",
        r"用(.+?)语音(.+)",
        r"用(.+?)声(.+)",
        r"用(.+?)音(.+)",
        r"让(.+?)说(.+)",
        r"让(.+?)读(.+)",
        r"让(.+?)念(.+)",
        r"用(.+?)说(.+)",
        r"用(.+?)读(.+)",
        r"用(.+?)念(.+)",
        r"(.+?)说(.+)",
        r"(.+?)读(.+)",
        r"(.+?)念(.+)",
        # 英文模式
        r"in a (.+?) voice (.+)",
        r"with (.+?) voice (.+)",
        r"using (.+?) voice (.+)",
        r"say (.+?) with (.+?) voice",
        r"read (.+?) with (.+?) voice",
    ]
    
    import re
    for pattern in patterns:
        m = re.search(pattern, text, re.IGNORECASE)
        if m:
            groups = m.groups()
            if len(groups) == 2:
                # 判断哪个是纯文本（通常更长的那个是文本）
                g1, g2 = groups[0].strip(), groups[1].strip()
                # 偏好通常更短，且包含 voice/声/音 相关词
                if any(kw in g1 for kw in ["声", "音", "voice", "tone", "accent"]):
                    return g1, g2
                if any(kw in g2 for kw in ["声", "音", "voice", "tone", "accent"]):
                    return g2, g1
                # 默认取第一个为偏好
                return g1, g2
    
    # 没有明确引导词，检查是否包含 voice 偏好关键词
    # 提取可能是 voice 偏好的形容词 + 性别词
    voice_hint_keywords = [
        "甜蜜", "甜", "温柔", "可爱", "甜美", "少女",
        "沉稳", "稳重", "成熟", "知性", "优雅",
        "年轻", "活泼", "青春",
        "沙哑", "磁性", "粗犷", "沧桑", "有力",
        "播音", "新闻", "正式", "播报",
        "老年", "老人",
        "低沉", "轻声", "柔和", "大喊", "喊叫", "喊", "吼",
        "愤怒", "生气", "怒吼", "紧急", "急促",
        "澳大利亚", "澳洲",
        "sweet", "gentle", "cute", "soft",
        "husky", "raspy", "rough", "powerful",
        "mature", "calm", "elegant",
        "young", "youthful", "energetic",
        "news", "anchor", "formal", "serious",
        "old", "elder", "shout", "shouting", "yell", "yelling", "scream",
        "deep", "standard", "default",
        "australian", "accent",
    ]
    
    # 检查是否包含 voice 偏好关键词
    found_prefs = []
    for kw in voice_hint_keywords:
        if kw in text_lower:
            found_prefs.append(kw)
    
    if found_prefs:
        # 构建偏好描述，移除纯文本内容
        # 简单策略：找到第一个明显不是内容的关键词
        preference = found_prefs[0]
        # 尝试根据关键词推断性别
        gender_hint = ""
        if any(w in text_lower for w in ["女声", "女生", "female", "woman", "girl", "lady"]):
            gender_hint = "女声"
        elif any(w in text_lower for w in ["男声", "男生", "male", "man", "boy"]):
            gender_hint = "男声"
        
        if gender_hint:
            preference = preference + gender_hint
        
        # 移除偏好关键词得到纯文本（近似）
        clean_text = text
        for kw in found_prefs:
            clean_text = clean_text.replace(kw, "")
        # 移除常见引导词
        clean_text = re.sub(
            r"用|让|语音|声音|声|说|读|念|男生|男声|男性|女生|女声|女性|voice|say|read|speak|male|female|man|woman|boy|girl",
            "",
            clean_text,
            flags=re.IGNORECASE,
        )
        clean_text = re.sub(r"^\s*[地得的]\s*", "", clean_text)
        clean_text = clean_text.strip()
        
        return preference, clean_text if clean_text else text
    
    # 没有任何偏好信息
    return "", text


def _voice_by_id(voice_id):
    for voice in FREE_VOICES:
        if voice["id"] == voice_id:
            return voice
    return None


def _voice_display_name(voice_id):
    voice_id = str(voice_id or "").strip()
    if not voice_id:
        return ""
    name = FREE_VOICE_DISPLAY_NAMES.get(voice_id)
    if name:
        return f"{name} ({voice_id})"
    return voice_id


def _voice_matches_gender(voice, gender):
    gender = (gender or "").strip().lower()
    return not gender or gender not in ("male", "female") or voice.get("gender") == gender


def _voice_candidates(preferred_gender=""):
    preferred_gender = (preferred_gender or "").strip().lower()
    candidates = [voice for voice in FREE_VOICES if _voice_matches_gender(voice, preferred_gender)]
    return candidates or list(FREE_VOICES)


def _default_voice_id(preferred_gender=""):
    candidates = _voice_candidates(preferred_gender)
    return candidates[0]["id"] if candidates else "21m00Tcm4TlvDq8ikWAM"


def _gender_label(preferred_gender=""):
    if preferred_gender == "male":
        return "男声"
    if preferred_gender == "female":
        return "女声"
    return "语音"


def _build_voice_try_list(voice_id, preferred_gender=""):
    preferred_gender = (preferred_gender or "").strip().lower()
    result = []
    seen = set()

    def add_voice(vid):
        if not vid or vid in seen:
            return
        voice = _voice_by_id(vid)
        if preferred_gender in ("male", "female") and voice and voice.get("gender") != preferred_gender:
            return
        seen.add(vid)
        result.append(vid)

    add_voice(voice_id)
    for voice in _voice_candidates(preferred_gender):
        add_voice(voice["id"])
    return result


def _expanded_voice_preference(preference):
    pref_lower = (preference or "").lower()
    synonyms = {
        "深沉": "低沉 deep",
        "深厚": "低沉 deep",
        "磁性": "低沉 deep husky",
        "粗糙": "粗犷 rough",
        "甜美": "甜蜜 sweet",
        "柔": "温柔 gentle soft",
        "大喊": "喊叫 shout shouting loud powerful urgent",
        "喊叫": "shout shouting loud powerful urgent",
        "喊": "shout shouting loud powerful urgent",
        "吼": "yell shouting loud powerful angry",
        "shout": "shouting loud powerful urgent",
        "yell": "shouting loud powerful urgent",
        "scream": "shouting loud powerful intense",
    }
    expanded = [pref_lower]
    for word, extra in synonyms.items():
        if word in pref_lower:
            expanded.append(extra)
    return " ".join(expanded)


VOICE_GENERIC_TAGS = {
    "男声", "男生", "男性", "女声", "女生", "女性",
    "male", "female", "man", "woman", "boy", "girl",
}


def select_voice_by_preference(preference, preferred_gender=""):
    """根据用户偏好关键词从 FREE_VOICES 中匹配最合适的 voice
    
    v1.0+ 新增：关键词匹配，返回 voice_id 或 None
    """
    if not preference:
        return _default_voice_id(preferred_gender) if preferred_gender in ("male", "female") else None
    
    pref_lower = _expanded_voice_preference(preference)
    candidates = _voice_candidates(preferred_gender)
    
    # 1. 先匹配风格标签。泛性别标签只用于兜底，避免“男声 沙哑”被默认男声提前吃掉。
    for voice in candidates:
        for tag in voice["tags"]:
            if tag.lower() in VOICE_GENERIC_TAGS:
                continue
            if tag.lower() in pref_lower or pref_lower in tag.lower():
                return voice["id"]
    
    # 2. 性别匹配（如果偏好里提到男/女）
    if any(w in pref_lower for w in ["女", "female", "woman", "girl", "lady"]):
        # 返回第一个女声（Rachel 作为默认）
        for voice in _voice_candidates("female"):
            if voice["gender"] == "female":
                return voice["id"]
    
    if any(w in pref_lower for w in ["男", "male", "man", "boy"]):
        # 返回第一个男声（Josh 作为默认）
        for voice in _voice_candidates("male"):
            if voice["gender"] == "male":
                return voice["id"]
    
    return None


def select_voice_by_llm(api_url, api_key, model, user_description, preferred_gender=""):
    """调用 LLM 从 FREE_VOICES 中选择最合适的 voice
    
    v1.0+ 新增：LLM 兜底，关键词匹配不到时使用
    返回: voice_id 或 None
    """
    if not api_key or api_key == "在此填入你的 API Key":
        return None
    
    # 构建 voice 列表文本
    voice_list = []
    candidates = _voice_candidates(preferred_gender)
    for i, voice in enumerate(candidates, 1):
        tags_str = ", ".join(voice["tags"])
        voice_list.append(f"{i}. ID: {voice['id']}, 性别: {voice['gender']}, 标签: {tags_str}")
    
    system_prompt = """You are a voice selection assistant. Given a user's voice preference description, select the most suitable voice ID from the provided list.
Only output the voice ID, nothing else. No quotes, no explanations."""

    user_prompt = f"""Available voices:
{chr(10).join(voice_list)}

User wants: "{user_description}"

Which voice ID is the best match? Output only the voice ID."""

    messages = [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": user_prompt}
    ]
    
    result = make_api_request(api_url, api_key, model, messages)
    if result.get("success"):
        voice_id = result.get("content", "").strip().strip('"').strip("'")
        # 验证返回的 ID 是否在 FREE_VOICES 中
        for voice in candidates:
            if voice["id"] == voice_id:
                return voice_id
        # 如果 LLM 返回了无效的 ID，fallback
        log(f"LLM 返回了无效 voice_id: {voice_id}")
    
    return None


def detect_voice_intent(text):
    """检测用户意图：语音(TTS) 还是 音效(Sound Effects)
    
    v1.0+ 新增：智能分流，根据关键词判断用户想要语音还是音效
    返回 True = 语音/TTS，False = 音效
    """
    text_lower = text.lower()
    
    # 语音关键词（中英文）
    voice_keywords = [
        "语音", "说话", "朗读", "播报", "旁白", "配音", "读出来", "念",
        "voice", "speak", "narration", "narrate", "read aloud", 
        "tts", "text to speech", "text-to-speech",
        "说", "讲话", "播报员", "播音"
    ]
    
    for kw in voice_keywords:
        if kw in text_lower:
            return True
    
    return False


def _trim_audio_text(text):
    return (text or "").strip()


def _strip_audio_shortcut_prefix(text):
    text = _trim_audio_text(text)
    if text.startswith("11"):
        text = text[2:].strip()
    lower = text.lower()
    for prefix in ("vox", "voice", "tts", "sfx", "sound"):
        if lower.startswith(prefix):
            return text[len(prefix):].lstrip(" :：_-")
    return text


def _infer_gender_from_text(text):
    lower = (text or "").lower()
    if any(w in lower for w in ["女声", "女生", "女性", "女孩", "少女", "female", "woman", "girl", "lady"]):
        return "female"
    if any(w in lower for w in ["男声", "男生", "男性", "男孩", "大叔", "male", "man", "boy"]):
        return "male"
    return ""


def _safe_voice_field(value):
    return str(value or "").replace("\t", " ").replace("\r", " ").replace("\n", " ").strip()


def _safe_output_dir(output_dir):
    output_dir = str(output_dir or "").strip().strip('"').strip("'")
    if not output_dir:
        return TEMP_DIR
    return os.path.abspath(output_dir)


def _audio_timestamp():
    return time.strftime("%Y%m%d_%H%M%S") + f"_{int((time.time() % 1) * 1000):03d}"


def _free_voice_record(voice, available=False):
    voice_id = voice.get("id") or ""
    return {
        "id": voice_id,
        "name": FREE_VOICE_DISPLAY_NAMES.get(voice_id, voice_id),
        "gender": voice.get("gender") or "",
        "free": True,
        "source": "free",
        "available": bool(available),
        "tags": list(voice.get("tags") or []),
    }


def _voice_record_line(record):
    tags = ",".join(_safe_voice_field(tag) for tag in record.get("tags") or [])
    return "\t".join([
        _safe_voice_field(record.get("id")),
        _safe_voice_field(record.get("name")),
        _safe_voice_field(record.get("gender")),
        "1" if record.get("free") else "0",
        _safe_voice_field(record.get("source") or ("free" if record.get("free") else "account")),
        tags,
        "1" if record.get("available") else "0",
    ])


def _labels_text(labels):
    if isinstance(labels, dict):
        return " ".join(str(v) for v in labels.values() if v is not None)
    if isinstance(labels, list):
        return " ".join(str(v) for v in labels if v is not None)
    return str(labels or "")


def _infer_voice_gender_from_record(raw):
    labels = raw.get("labels") if isinstance(raw, dict) else None
    pieces = [
        raw.get("name", "") if isinstance(raw, dict) else "",
        raw.get("category", "") if isinstance(raw, dict) else "",
        raw.get("description", "") if isinstance(raw, dict) else "",
        _labels_text(labels),
    ]
    gender = _infer_gender_from_text(" ".join(pieces))
    if gender:
        return gender
    if isinstance(labels, dict):
        for key in ("gender", "Gender", "sex", "voice_gender"):
            label_value = str(labels.get(key) or "").lower()
            if label_value in ("male", "man", "m"):
                return "male"
            if label_value in ("female", "woman", "f"):
                return "female"
    return "unknown"


def _account_voice_record(raw):
    if not isinstance(raw, dict):
        return None
    voice_id = str(raw.get("voice_id") or raw.get("id") or "").strip()
    if not voice_id:
        return None
    name = str(raw.get("name") or FREE_VOICE_DISPLAY_NAMES.get(voice_id) or voice_id).strip()
    labels = raw.get("labels") if isinstance(raw.get("labels"), dict) else {}
    tags = []
    for value in labels.values():
        value = str(value or "").strip()
        if value:
            tags.append(value)
    category = str(raw.get("category") or "").strip()
    if category:
        tags.append(category)
    return {
        "id": voice_id,
        "name": name,
        "gender": _infer_voice_gender_from_record(raw),
        "free": voice_id in FREE_VOICE_IDS,
        "source": "free" if voice_id in FREE_VOICE_IDS else "account",
        "available": True,
        "tags": tags,
    }


def _probe_voice_available(api_key, voice_id):
    headers = {
        "Accept": "audio/mpeg",
        "Content-Type": "application/json",
        "xi-api-key": api_key,
    }
    payload = {
        "text": VOICE_PROBE_TEXT,
        "model_id": "eleven_multilingual_v2",
        "voice_settings": {
            "stability": 0.5,
            "similarity_boost": 0.75,
        },
    }
    try:
        response = requests.post(
            f"https://api.elevenlabs.io/v1/text-to-speech/{voice_id}",
            headers=headers,
            json=payload,
            timeout=VOICE_PROBE_TIMEOUT,
        )
        if response.status_code == 200:
            return True, ""
        detail = response.text[:200] if len(response.text) > 200 else response.text
        return False, f"{response.status_code}: {detail}"
    except requests.exceptions.Timeout:
        return False, f"timeout {VOICE_PROBE_TIMEOUT}s"
    except requests.exceptions.RequestException as e:
        return False, str(e)
    except Exception as e:
        return False, str(e)


def make_elevenlabs_voices_request(api_key):
    if not api_key:
        return {"success": False, "error": "请先填写 ElevenLabs Key"}

    candidates = [_free_voice_record(voice, available=False) for voice in FREE_VOICES]
    record_by_id = {record["id"]: record for record in candidates}
    seen = set(record_by_id.keys())

    headers = {"Accept": "application/json", "xi-api-key": api_key}
    try:
        response = requests.get("https://api.elevenlabs.io/v1/voices", headers=headers, timeout=VOICE_LIST_TIMEOUT)
        if response.status_code != 200:
            detail = response.text[:300] if len(response.text) > 300 else response.text
            return {"success": False, "error": f"ElevenLabs Key 或声线接口不可用 ({response.status_code}): {detail}"}

        data = response.json()
        raw_voices = data.get("voices") if isinstance(data, dict) else data
        if not isinstance(raw_voices, list):
            return {"success": False, "error": "ElevenLabs 声线接口响应格式异常"}

        skipped_unknown_gender = 0
        for raw in raw_voices:
            record = _account_voice_record(raw)
            if not record:
                continue
            if record["id"] in seen:
                existing = record_by_id.get(record["id"])
                if existing:
                    existing["available"] = True
                    existing["name"] = record.get("name") or existing.get("name")
                    existing["source"] = record.get("source") or existing.get("source")
                    if record.get("tags"):
                        existing["tags"] = record.get("tags")
                continue
            if record.get("gender") not in ("male", "female"):
                skipped_unknown_gender += 1
                continue
            seen.add(record["id"])
            record_by_id[record["id"]] = record
            candidates.append(record)

        usable = []
        last_error = ""
        for record in candidates[:MAX_VOICE_PROBES]:
            ok, probe_error = _probe_voice_available(api_key, record["id"])
            if ok:
                record["available"] = True
                usable.append(record)
            else:
                last_error = probe_error
                log(f"Voice probe failed {record['id']}: {probe_error}")

        skipped_by_limit = max(0, len(candidates) - MAX_VOICE_PROBES)
        if not usable:
            suffix = f" 最后错误: {last_error}" if last_error else ""
            return {"success": False, "error": "没有检测到可用声线。" + suffix}

        message = f"已检测到 {len(usable)} 条可用声线"
        if skipped_unknown_gender:
            message += f"，忽略 {skipped_unknown_gender} 条未标性别声线"
        if skipped_by_limit:
            message += f"，还有 {skipped_by_limit} 条未检测"
        return {
            "success": True,
            "content": "\n".join(_voice_record_line(record) for record in usable),
            "count": len(usable),
            "fallback": False,
            "message": message,
        }

    except requests.exceptions.Timeout:
        return {"success": False, "error": "ElevenLabs 声线接口超时"}
    except requests.exceptions.RequestException as e:
        return {"success": False, "error": f"ElevenLabs 声线接口网络错误: {e}"}
    except Exception as e:
        return {"success": False, "error": f"ElevenLabs 声线检测失败: {e}"}


def _has_chinese(text):
    for c in text or "":
        if '\u4e00' <= c <= '\u9fff':
            return True
    return False


def _json_object_from_text(text):
    text = (text or "").strip()
    if not text:
        return None
    if text.startswith("```"):
        text = re.sub(r"^```(?:json)?\s*", "", text, flags=re.IGNORECASE)
        text = re.sub(r"\s*```$", "", text)
    start = text.find("{")
    end = text.rfind("}")
    if start >= 0 and end > start:
        text = text[start:end + 1]
    try:
        data = json.loads(text)
        return data if isinstance(data, dict) else None
    except Exception as e:
        log(f"解析 VOX LLM JSON 失败: {e}; content={text[:300]}")
        return None


def parse_vox_request_by_llm(api_url, api_key, model, user_text, fallback_req=None):
    """Use the configured LLM to extract a natural-language 11vox request."""
    if not api_key or api_key == "在此填入你的 API Key":
        return None

    fallback_req = fallback_req or {}
    user_text = _trim_audio_text(user_text)
    if not user_text:
        return None

    system_prompt = """You extract parameters for ElevenLabs text-to-speech.
Return only one compact JSON object. Do not explain.

Schema:
{
  "spoken_text": "the exact words ElevenLabs should speak",
  "gender": "male|female|",
  "voice_style": "voice identity/timbre/accent only, such as deep, young, old, husky",
  "performance_prompt": "open acting direction, preserving nuanced user intent",
  "emotion": "optional primary emotion",
  "intensity": 0.0,
  "pace": "slow|normal|fast|",
  "volume": "soft|normal|loud|",
  "delivery": "optional delivery style",
  "audio_tags": ["optional short ElevenLabs-style tags"],
  "track_name": ""
}

Rules:
- Understand Chinese and English natural language.
- Do not include instruction words such as 男生, 女声, 大喊, say, read, 用...说 in spoken_text.
- Preserve the language of the words that should be spoken. Do not translate spoken_text unless the user explicitly asks for translation.
- Put acting directions such as 大喊, whispering, angry, urgent, calm, seductive, near tears, sarcastic, terrified into performance_prompt, not spoken_text.
- Keep voice_style for voice selection only. Do not flatten performance_prompt into a small enum.
- performance_prompt may be detailed, e.g. "terrified battlefield shout, loud projection, urgent, panicked, short and explosive".
- audio_tags should be short natural tags like "shouting", "whispering", "laughing", "sighing", "crying", "sarcastic", "seductive" when useful.
- intensity is a number from 0 to 1. Use 0.5 when unclear.
- If the user clearly asks for a male voice, gender is male. If clearly female, gender is female. Otherwise use empty string.
- track_name should usually be empty unless the user explicitly names the track."""

    fallback_summary = {
        "source_text": fallback_req.get("source_text") or "",
        "spoken_text": fallback_req.get("spoken_text") or "",
        "gender": fallback_req.get("gender") or "",
        "voice_style": fallback_req.get("voice_style") or "",
        "performance_prompt": fallback_req.get("performance_prompt") or fallback_req.get("performance") or "",
    }
    user_prompt = f"""User 11vox request:
{user_text}

Current rough parse:
{json.dumps(fallback_summary, ensure_ascii=False)}

Examples:
Input: 11vox 男生大喊 fire in the hole
Output: {{"spoken_text":"fire in the hole","gender":"male","voice_style":"","performance_prompt":"terrified battlefield shout, loud projection, urgent, high intensity","emotion":"panic","intensity":0.95,"pace":"fast","volume":"loud","delivery":"shouted","audio_tags":["shouting","panicked"],"track_name":""}}

Input: 11vox 女声温柔说 欢迎回来
Output: {{"spoken_text":"欢迎回来","gender":"female","voice_style":"","performance_prompt":"gentle, warm, intimate, soft delivery","emotion":"warm","intensity":0.35,"pace":"slow","volume":"soft","delivery":"gentle","audio_tags":["gentle"],"track_name":""}}

Input: 11vox 用老人大声喊 Run!
Output: {{"spoken_text":"Run!","gender":"male","voice_style":"elderly","performance_prompt":"loud urgent shout, forceful projection","emotion":"urgent","intensity":0.9,"pace":"fast","volume":"loud","delivery":"shouted","audio_tags":["shouting"],"track_name":""}}

Now output JSON for the user request."""

    result = make_api_request(api_url, api_key, model, [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": user_prompt},
    ])
    if not result.get("success"):
        log(f"VOX 语义抽取 LLM 失败: {result.get('error')}")
        return None

    data = _json_object_from_text(result.get("content", ""))
    if not data:
        return None

    spoken_text = _trim_audio_text(data.get("spoken_text") or data.get("text") or "")
    if not spoken_text:
        return None

    gender = str(data.get("gender") or "").strip().lower()
    if gender not in ("male", "female"):
        gender = ""

    voice_style = _trim_audio_text(data.get("voice_style") or data.get("style") or "")
    performance_prompt = _trim_audio_text(
        data.get("performance_prompt")
        or data.get("performance")
        or data.get("tone")
        or data.get("emotion")
        or ""
    )

    return {
        "spoken_text": spoken_text,
        "gender": gender,
        "voice_style": voice_style,
        "performance_prompt": performance_prompt,
        "emotion": _trim_audio_text(data.get("emotion") or ""),
        "intensity": data.get("intensity"),
        "pace": _trim_audio_text(data.get("pace") or ""),
        "volume": _trim_audio_text(data.get("volume") or ""),
        "delivery": _trim_audio_text(data.get("delivery") or ""),
        "audio_tags": data.get("audio_tags") if isinstance(data.get("audio_tags"), list) else [],
        "track_name": _trim_audio_text(data.get("track_name") or ""),
    }


def parse_audio_request_payload(raw_text):
    """解析 Lua 传入的 11Lab 请求。

    新版 Lua 会传 JSON，旧版/手工调用仍可传裸文本。返回结构化 dict。
    """
    raw_text = _trim_audio_text(raw_text)
    if raw_text.startswith("{"):
        try:
            data = json.loads(raw_text)
            if isinstance(data, dict):
                mode = str(data.get("mode") or "").strip().lower()
                if mode in ("voice", "tts"):
                    mode = "vox"
                elif mode in ("sound", "sound_effect", "sound-effects"):
                    mode = "sfx"
                if mode not in ("vox", "sfx"):
                    mode = "sfx"

                voice_style = _trim_audio_text(data.get("voice_style") or data.get("style") or "")
                performance = _trim_audio_text(data.get("performance") or data.get("tone") or data.get("emotion") or "")
                performance_prompt = _trim_audio_text(data.get("performance_prompt") or performance)
                gender = str(data.get("gender") or "").strip().lower()
                if gender not in ("male", "female"):
                    gender = _infer_gender_from_text(" ".join([voice_style, performance_prompt]))

                return {
                    "structured": True,
                    "mode": mode,
                    "track_name": _trim_audio_text(data.get("track_name") or ""),
                    "prompt": _trim_audio_text(data.get("prompt") or data.get("description") or ""),
                    "gender": gender,
                    "voice_style": voice_style,
                    "performance": performance,
                    "performance_prompt": performance_prompt,
                    "emotion": _trim_audio_text(data.get("emotion") or ""),
                    "intensity": data.get("intensity"),
                    "pace": _trim_audio_text(data.get("pace") or ""),
                    "volume": _trim_audio_text(data.get("volume") or ""),
                    "delivery": _trim_audio_text(data.get("delivery") or ""),
                    "audio_tags": data.get("audio_tags") if isinstance(data.get("audio_tags"), list) else [],
                    "voice_id": _trim_audio_text(data.get("voice_id") or data.get("voice") or ""),
                    "spoken_text": _trim_audio_text(data.get("spoken_text") or data.get("text") or ""),
                    "source_text": _trim_audio_text(data.get("source_text") or ""),
                    "output_dir": _trim_audio_text(data.get("output_dir") or ""),
                    "semantic_parse": bool(data.get("semantic_parse")),
                }
        except Exception as e:
            log(f"解析 11Lab JSON 请求失败，将按旧文本处理: {e}")

    text = _strip_audio_shortcut_prefix(raw_text)
    lower = raw_text.lower()
    explicit_vox = lower.startswith("11vox") or lower.startswith("vox") or lower.startswith("voice")
    explicit_sfx = lower.startswith("11sfx") or lower.startswith("sfx") or lower.startswith("sound")

    if explicit_vox:
        mode = "vox"
    elif explicit_sfx:
        mode = "sfx"
    else:
        mode = "vox" if detect_voice_intent(text) else "sfx"

    if mode == "vox":
        voice_style, spoken_text = extract_voice_preference(text)
        gender = _infer_gender_from_text(voice_style)
        return {
            "structured": False,
            "mode": "vox",
            "track_name": "",
            "prompt": "",
            "gender": gender,
            "voice_style": voice_style,
            "performance": "",
            "performance_prompt": voice_style,
            "emotion": "",
            "intensity": None,
            "pace": "",
            "volume": "",
            "delivery": "",
            "audio_tags": [],
            "voice_id": "",
            "spoken_text": spoken_text,
            "source_text": text,
            "output_dir": "",
            "semantic_parse": bool(explicit_vox),
        }

    return {
        "structured": False,
        "mode": "sfx",
        "track_name": "",
        "prompt": text,
        "gender": "",
        "voice_style": "",
        "performance": "",
        "performance_prompt": "",
        "emotion": "",
        "intensity": None,
        "pace": "",
        "volume": "",
        "delivery": "",
        "audio_tags": [],
        "voice_id": "",
        "spoken_text": "",
        "source_text": text,
        "output_dir": "",
        "semantic_parse": False,
    }


def prepend_audio_lines(result, lines):
    if not result.get("success"):
        return result
    content = str(result.get("content") or "")
    clean_lines = [line for line in lines if line]
    if clean_lines:
        result["content"] = "\n".join(clean_lines + [content])
    return result


def translate_to_english(api_url, api_key, model, chinese_text):
    """调用 LLM 将中文音效描述翻译成英文提示词
    
    v1.0+ 新增：ElevenLabs Sound Effects API 需要英文提示词
    """
    if not api_key or api_key == "在此填入你的 API Key":
        return None, "LLM API Key 未配置，无法翻译中文提示词"
    
    system_prompt = """You are a professional sound effects prompt engineer for ElevenLabs Sound Effects API.
Your task is to translate Chinese sound effect descriptions into concise, high-quality English prompts.
The prompt should be 1-2 sentences, descriptive but concise, optimized for AI sound generation.
Only output the English prompt, nothing else. No quotes, no explanations."""

    messages = [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": f'Translate this sound effect description to English: "{chinese_text}"'}
    ]
    
    result = make_api_request(api_url, api_key, model, messages)
    if result.get("success"):
        translated = result.get("content", "").strip()
        # 清理可能的引号
        translated = translated.strip('"').strip("'").strip()
        if translated:
            return translated, None
        return None, "翻译结果为空"
    else:
        return None, result.get("error", "翻译失败")


def _infer_tts_performance(style_text):
    lower = (style_text or "").lower()
    if any(w in lower for w in ["大喊", "喊叫", "吼", "怒吼", "shout", "shouting", "yell", "yelling", "scream", "loud"]):
        return "loud urgent shouting"
    if any(w in lower for w in ["愤怒", "生气", "angry", "furious", "rage"]):
        return "angry"
    if any(w in lower for w in ["紧急", "急促", "urgent", "panic", "panicked"]):
        return "urgent panicked"
    if any(w in lower for w in ["轻声", "耳语", "悄声", "whisper", "whispering"]):
        return "whispering"
    if any(w in lower for w in ["温柔", "柔和", "gentle", "soft", "warm"]):
        return "gentle warm"
    return ""


def _is_plain_latin_text(text):
    return bool(re.match(r"^[A-Za-z0-9\s\-_,.'!?]+$", text or ""))


def _clamp_float(value, default=0.5, low=0.0, high=1.0):
    try:
        value = float(value)
    except Exception:
        value = default
    return max(low, min(high, value))


def _contains_any(text, words):
    text = (text or "").lower()
    return any(word in text for word in words)


def _sanitize_audio_tag(tag):
    tag = str(tag or "").strip()
    tag = re.sub(r"[\[\]\r\n]+", " ", tag)
    tag = re.sub(r"\s+", " ", tag).strip(" ,.;:，。；：")
    return tag[:48] if tag else ""


def _dedupe_tags(tags, limit=5):
    out = []
    seen = set()
    for tag in tags:
        clean = _sanitize_audio_tag(tag)
        key = clean.lower()
        if clean and key not in seen:
            seen.add(key)
            out.append(clean)
        if len(out) >= limit:
            break
    return out


PERFORMANCE_CUE_SPECS = [
    ("shouting", ["大喊", "喊叫", "喊", "吼", "怒吼", "咆哮", "shout", "shouting", "yell", "yelling", "scream", "loud"], "loud", "fast", 0.88),
    ("whispering", ["低语", "耳语", "轻声", "悄声", "小声", "whisper", "whispering", "hushed"], "soft", "slow", 0.42),
    ("panicked", ["恐慌", "惊慌", "慌张", "害怕", "恐惧", "快崩溃", "panic", "panicked", "terrified", "fearful", "scared"], "", "fast", 0.82),
    ("angry", ["愤怒", "生气", "压着火", "火气", "怒", "暴怒", "angry", "furious", "rage", "irritated"], "", "", 0.78),
    ("urgent", ["紧急", "急促", "着急", "赶时间", "urgent", "rushed", "hurry", "fast"], "", "fast", 0.75),
    ("gentle", ["温柔", "柔和", "柔软", "暖", "gentle", "soft", "warm", "tender"], "soft", "slow", 0.34),
    ("sad", ["悲伤", "难过", "哀伤", "失落", "sad", "sorrow", "grief", "heartbroken"], "", "slow", 0.52),
    ("crying", ["哭", "哭腔", "哽咽", "快哭", "泪", "cry", "crying", "tearful", "sobbing", "near tears"], "", "slow", 0.68),
    ("excited", ["兴奋", "激动", "亢奋", "excited", "thrilled", "hyped"], "", "fast", 0.76),
    ("happy", ["开心", "快乐", "高兴", "愉快", "happy", "joyful", "cheerful"], "", "", 0.55),
    ("laughing", ["笑", "嘲笑", "冷笑", "轻笑", "laugh", "laughing", "giggle", "chuckle"], "", "", 0.55),
    ("sarcastic", ["讽刺", "阴阳怪气", "嘲讽", "挖苦", "sarcastic", "mocking", "snarky"], "", "", 0.58),
    ("seductive", ["性感", "暧昧", "挑逗", "撩", "色情", "情欲", "欲望", "亲密", "诱惑", "seductive", "sensual", "flirty", "intimate", "erotic", "breathy"], "soft", "slow", 0.62),
    ("breathy", ["气声", "呼吸感", "喘息", "breathy", "breathless"], "soft", "", 0.55),
    ("tired", ["疲惫", "累", "虚弱", "tired", "exhausted", "weary", "weak"], "soft", "slow", 0.36),
    ("cold", ["冷漠", "冰冷", "冷淡", "cold", "detached", "emotionless"], "", "", 0.32),
    ("serious", ["严肃", "认真", "庄重", "serious", "stern", "grave"], "", "", 0.45),
    ("commanding", ["命令", "压迫", "威严", "commanding", "authoritative", "dominant"], "loud", "", 0.72),
    ("surprised", ["惊讶", "震惊", "吓一跳", "surprised", "shocked", "startled"], "", "", 0.68),
    ("nervous", ["紧张", "不安", "结巴", "nervous", "anxious", "hesitant"], "", "fast", 0.58),
    ("ominous", ["阴森", "恐怖", "诡异", "邪恶", "ominous", "creepy", "sinister", "evil"], "", "slow", 0.62),
    ("unhinged", ["疯狂", "疯批", "癫狂", "疯", "mad", "crazy", "unhinged", "manic"], "", "", 0.82),
    ("announcer", ["播报", "播音", "新闻", "旁白", "announcer", "narrator", "newsreader"], "", "", 0.38),
]


def _compile_tts_performance(text, performance_prompt="", voice_style="", data=None):
    data = data or {}
    prompt_parts = [
        performance_prompt,
        data.get("performance_prompt"),
        data.get("performance"),
        data.get("emotion"),
        data.get("delivery"),
        data.get("pace"),
        data.get("volume"),
    ]
    clean_prompt_parts = []
    seen_prompt_parts = set()
    for part in prompt_parts:
        clean_part = _trim_audio_text(part)
        key = clean_part.lower()
        if clean_part and key not in seen_prompt_parts:
            seen_prompt_parts.add(key)
            clean_prompt_parts.append(clean_part)
    prompt = " ".join(clean_prompt_parts)
    voice_style = _trim_audio_text(voice_style)
    blob = " ".join([prompt, voice_style]).lower()

    tags = list(data.get("audio_tags") or [])
    inferred_intensity = 0.5
    pace = _trim_audio_text(data.get("pace") or "")
    volume = _trim_audio_text(data.get("volume") or "")

    for tag, words, cue_volume, cue_pace, cue_intensity in PERFORMANCE_CUE_SPECS:
        if _contains_any(blob, words):
            tags.append(tag)
            inferred_intensity = max(inferred_intensity, cue_intensity)
            volume = volume or cue_volume
            pace = pace or cue_pace

    if prompt and not tags:
        tags.append(prompt if len(prompt) <= 48 else prompt[:48].rsplit(" ", 1)[0])

    tags = _dedupe_tags(tags)
    intensity = _clamp_float(data.get("intensity"), inferred_intensity)
    pace_l = pace.lower()
    volume_l = volume.lower()
    loud = volume_l in ("loud", "high", "大声") or any(t in ("shouting", "commanding") for t in tags)
    soft = volume_l in ("soft", "quiet", "低声", "小声") or any(t in ("whispering", "gentle", "seductive", "breathy", "tired") for t in tags)
    fast = pace_l in ("fast", "quick", "急促", "快速") or any(t in ("urgent", "panicked", "excited", "nervous") for t in tags)
    slow = pace_l in ("slow", "慢", "缓慢") or any(t in ("whispering", "gentle", "sad", "crying", "seductive", "ominous", "tired") for t in tags)

    settings = {"stability": 0.5, "similarity_boost": 0.75}
    if tags:
        settings["stability"] = round(max(0.18, min(0.72, 0.62 - intensity * 0.38)), 2)
        settings["style"] = round(max(0.25, min(0.95, 0.25 + intensity * 0.72)), 2)
        settings["use_speaker_boost"] = not soft
    if loud:
        settings["stability"] = min(settings.get("stability", 0.5), 0.28)
        settings["style"] = max(settings.get("style", 0.6), 0.82)
        settings["use_speaker_boost"] = True
    if soft:
        settings["stability"] = min(settings.get("stability", 0.5), 0.42)
        settings["style"] = max(settings.get("style", 0.35), 0.55)
        settings["use_speaker_boost"] = False
    if fast and not slow:
        settings["speed"] = 1.12
    elif slow and not fast:
        settings["speed"] = 0.86

    stable_text = (text or "").strip()
    if loud or any(t in ("angry", "urgent", "panicked", "excited", "commanding", "unhinged") for t in tags):
        if _is_plain_latin_text(stable_text):
            stable_text = stable_text.upper()
        if stable_text and not stable_text.endswith(("!", "！", "?")):
            stable_text = stable_text.rstrip(".。") + ("!!" if intensity >= 0.85 else "!")
    elif any(t in ("sad", "crying", "tired", "ominous") for t in tags):
        if stable_text and not stable_text.endswith(("...", "…", ".", "。", "!", "！", "?")):
            stable_text = stable_text + "..."
    elif soft:
        stable_text = stable_text.rstrip("!！")

    expressive_text = stable_text
    if tags:
        expressive_text = " ".join(f"[{tag}]" for tag in tags) + " " + stable_text

    return {
        "prompt": prompt,
        "tags": tags,
        "intensity": intensity,
        "pace": pace,
        "volume": volume,
        "text": expressive_text,
        "stable_text": stable_text,
        "voice_settings": settings,
        "model_id": ELEVENLABS_EXPRESSIVE_MODEL if tags else ELEVENLABS_STABLE_MODEL,
        "summary": ", ".join(tags) if tags else (prompt or "默认"),
    }


def _performance_text_for_tts(text, performance):
    return _compile_tts_performance(text, performance)["text"]


def _voice_settings_for_performance(performance):
    return _compile_tts_performance("", performance)["voice_settings"]


def _tts_payload(compiled, stable_model=False):
    return {
        "text": compiled["stable_text"] if stable_model else compiled["text"],
        "model_id": ELEVENLABS_STABLE_MODEL if stable_model else compiled["model_id"],
        "voice_settings": compiled["voice_settings"],
    }


def _post_tts_request(api_key, voice_id, payload):
    headers = {
        "Accept": "audio/mpeg",
        "Content-Type": "application/json",
        "xi-api-key": api_key
    }
    return requests.post(
        f"https://api.elevenlabs.io/v1/text-to-speech/{voice_id}",
        headers=headers,
        json=payload,
        timeout=ELEVENLABS_TIMEOUT
    )


def _do_tts_request(api_key, text, voice_id, performance=""):
    """内部：执行单次 TTS 请求。开放表演走 v3；模型/权限不支持时回落 v2。"""
    compiled = performance if isinstance(performance, dict) else _compile_tts_performance(text, performance)
    response = _post_tts_request(api_key, voice_id, _tts_payload(compiled, stable_model=False))
    if response.status_code == 200:
        return response
    if compiled.get("model_id") != ELEVENLABS_STABLE_MODEL and response.status_code in (400, 401, 402, 403, 422):
        detail = response.text[:200] if len(response.text) > 200 else response.text
        log(f"Expressive TTS model fallback for voice {voice_id}: {response.status_code} {detail}")
        fallback_response = _post_tts_request(api_key, voice_id, _tts_payload(compiled, stable_model=True))
        if fallback_response.status_code == 200:
            return fallback_response
        return fallback_response
    return response


def make_elevenlabs_tts_request(api_key, text, voice_id, output_dir=None, preferred_gender="", performance="", voice_style="", performance_data=None):
    """调用 ElevenLabs TTS API 生成语音
    
    v1.0+ 新增：
    - 支持传入 voice_id 参数
    - 402 自动 fallback：遇到付费限制时尝试同一性别的其他免费 voice
    - 显式选择男/女后不跨性别降级，避免男声请求生成女声
    """
    output_dir = _safe_output_dir(output_dir)
    
    os.makedirs(output_dir, exist_ok=True)
    timestamp = _audio_timestamp()
    temp_mp3 = os.path.join(output_dir, f"elevenlabs_tts_{timestamp}.mp3")
    output_wav = os.path.join(output_dir, f"elevenlabs_tts_{timestamp}.wav")
    
    # 构建尝试列表：首选 voice 放第一个；显式性别只在同一性别池内兜底。
    voices_to_try = _build_voice_try_list(voice_id, preferred_gender)
    if not voices_to_try:
        return {"success": False, "error": f"没有可用的{_gender_label(preferred_gender)}声线"}
    
    compiled_performance = _compile_tts_performance(text, performance, voice_style, performance_data)
    last_error = None
    tried_voices = []
    
    for vid in voices_to_try:
        tried_voices.append(vid)
        try:
            response = _do_tts_request(api_key, text, vid, compiled_performance)
            
            if response.status_code == 200:
                # 成功
                with open(temp_mp3, 'wb') as f:
                    f.write(response.content)
                
                success, error = convert_to_wav(temp_mp3, output_wav)
                try:
                    os.remove(temp_mp3)
                except:
                    pass
                
                if not success:
                    return {"success": False, "error": f"音频转换失败: {error}"}
                
                # 如果被降级了，在结果中备注（第一行提示，第二行路径）
                if vid != voice_id:
                    fallback_label = _voice_display_name(vid)
                    selected_label = _voice_display_name(voice_id)
                    return {"success": True, "content": f"[所选声线暂时不可用: {selected_label}；已改用: {fallback_label}]\n{output_wav}"}
                return {"success": True, "content": output_wav}
            
            elif response.status_code == 402:
                # 付费限制，继续尝试下一个 voice
                error_detail = response.text[:200] if len(response.text) > 200 else response.text
                log(f"Voice {vid} 返回 402 (付费限制)，尝试下一个...")
                last_error = f"Voice {vid} 需要付费订阅"
                continue
            
            else:
                # 其他错误，记录但继续尝试
                error_detail = response.text[:200] if len(response.text) > 200 else response.text
                log(f"Voice {vid} 错误 {response.status_code}: {error_detail}")
                last_error = f"API 错误 {response.status_code}: {error_detail}"
                # 如果是 4xx 错误（除了 402），可能是请求本身问题，继续尝试
                if 400 <= response.status_code < 500 and response.status_code != 402:
                    continue
                # 5xx 错误也继续尝试
                if response.status_code >= 500:
                    continue
                # 其他情况也继续
                continue
                
        except requests.exceptions.Timeout:
            last_error = f"ElevenLabs TTS 请求超时（{ELEVENLABS_TIMEOUT}秒）"
            continue
        except requests.exceptions.RequestException as e:
            last_error = f"网络错误: {str(e)}"
            continue
        except Exception as e:
            last_error = f"未知错误: {str(e)}"
            continue
    
    # 所有 voice 都试过了
    return {"success": False, "error": f"所有{_gender_label(preferred_gender)}声线均不可用。最后一次错误: {last_error}"}


def make_elevenlabs_sound_request(api_key, text, output_dir=None):
    """调用 ElevenLabs Sound Effects API 生成音效
    
    v1.0+ 新增：根据文本描述生成音效（爆炸声、脚步声等）
    """
    output_dir = _safe_output_dir(output_dir)
    
    os.makedirs(output_dir, exist_ok=True)
    timestamp = _audio_timestamp()
    temp_mp3 = os.path.join(output_dir, f"elevenlabs_sfx_{timestamp}.mp3")
    output_wav = os.path.join(output_dir, f"elevenlabs_sfx_{timestamp}.wav")
    
    headers = {
        "Accept": "audio/mpeg",
        "Content-Type": "application/json",
        "xi-api-key": api_key
    }
    
    payload = {
        "text": text,
        "duration_seconds": SFX_DURATION_SECONDS,
        "prompt_influence": 0.35
    }
    
    try:
        response = requests.post(
            "https://api.elevenlabs.io/v1/sound-generation",
            headers=headers,
            json=payload,
            timeout=ELEVENLABS_TIMEOUT
        )
        
        if response.status_code != 200:
            error_detail = response.text[:500] if len(response.text) > 500 else response.text
            return {"success": False, "error": f"ElevenLabs Sound Effects 错误 {response.status_code}: {error_detail}"}
        
        with open(temp_mp3, 'wb') as f:
            f.write(response.content)
        
        success, error = convert_to_wav(temp_mp3, output_wav)
        try:
            os.remove(temp_mp3)
        except:
            pass
        
        if not success:
            return {"success": False, "error": f"音频转换失败: {error}"}
        
        return {"success": True, "content": output_wav}
        
    except requests.exceptions.Timeout:
        return {"success": False, "error": f"ElevenLabs Sound Effects 请求超时（{ELEVENLABS_TIMEOUT}秒）。这通常是外部生成服务排队或提示词过长导致，可稍后重试或缩短描述。"}
    except requests.exceptions.RequestException as e:
        return {"success": False, "error": f"网络错误: {str(e)}"}
    except Exception as e:
        return {"success": False, "error": f"未知错误: {str(e)}"}


def _validate_ffmpeg_path(path):
    if not path:
        return None
    path = str(path).strip().strip('"').strip("'")
    if not path:
        return None
    if os.name == "nt":
        path = path.replace("/", "\\")
    if os.path.isdir(path):
        path = os.path.join(path, "ffmpeg.exe")
    if not os.path.exists(path):
        return None

    run_kwargs = {
        "stdout": subprocess.DEVNULL,
        "stderr": subprocess.DEVNULL,
        "timeout": 8,
    }
    if os.name == "nt":
        run_kwargs["creationflags"] = subprocess.CREATE_NO_WINDOW
    try:
        result = subprocess.run([path, "-version"], **run_kwargs)
    except Exception:
        return None
    return os.path.abspath(path) if result.returncode == 0 else None


def _remember_ffmpeg_path(server_dir, config_path, ffmpeg_path):
    try:
        with open(os.path.join(server_dir, "ffmpeg_path.txt"), "w", encoding="utf-8") as handle:
            handle.write(os.path.abspath(ffmpeg_path) + "\n")
    except Exception:
        pass
    if config_path and os.path.exists(config_path):
        try:
            config = json.loads(read_text_file_smart(config_path))
            if isinstance(config, dict):
                config["ffmpeg_path"] = os.path.abspath(ffmpeg_path)
                with open(config_path, "w", encoding="utf-8") as handle:
                    json.dump(config, handle, ensure_ascii=False, indent=2)
                    handle.write("\n")
        except Exception:
            pass


def get_ffmpeg_path():
    """获取 FFmpeg 可执行文件路径，兼容第一步安装、旧路径和系统 PATH。"""
    server_dir = os.path.dirname(__file__)
    config_path = os.path.join(server_dir, "config.json")
    candidates = []

    def add(value):
        if not value:
            return
        text = str(value).strip().strip('"').strip("'")
        if text and text not in candidates:
            candidates.append(text)

    path_file = os.path.join(server_dir, "ffmpeg_path.txt")
    try:
        if os.path.exists(path_file):
            add(read_text_file_smart(path_file).strip())
    except Exception:
        pass

    if os.path.exists(config_path):
        try:
            config = json.loads(read_text_file_smart(config_path))
            add(config.get("ffmpeg_path", ""))
        except Exception:
            pass

    add(os.environ.get("REAPERAI_FFMPEG_PATH"))
    add(os.environ.get("FFMPEG_PATH"))
    add(os.path.join(server_dir, "ffmpeg", "bin", "ffmpeg.exe"))
    add(os.path.join(server_dir, "tools", "ffmpeg", "bin", "ffmpeg.exe"))
    add(os.path.join(server_dir, "ffmpeg.exe"))
    add(os.path.join(server_dir, "tools", "ffmpeg.exe"))
    add(shutil.which("ffmpeg"))
    add(r"C:\ffmpeg\bin\ffmpeg.exe")
    add(r"C:\Program Files\ffmpeg\bin\ffmpeg.exe")
    add(r"C:\Program Files (x86)\ffmpeg\bin\ffmpeg.exe")

    for candidate in candidates:
        ffmpeg_path = _validate_ffmpeg_path(candidate)
        if ffmpeg_path:
            _remember_ffmpeg_path(server_dir, config_path, ffmpeg_path)
            return ffmpeg_path

    return None


def convert_to_wav(input_path, output_path, ffmpeg_path=None):
    """使用 FFmpeg 将音频转换为 WAV 格式"""
    if not ffmpeg_path:
        ffmpeg_path = get_ffmpeg_path()
    
    if not ffmpeg_path or not os.path.exists(ffmpeg_path):
        return False, "找不到 FFmpeg，请确保 FFmpeg 已安装"
    
    try:
        # 使用 FFmpeg 转换为 WAV，采样率跟随输入或默认 48kHz
        cmd = [
            ffmpeg_path,
            "-y",  # 覆盖输出文件
            "-i", input_path,
            "-ar", "48000",  # 采样率 48kHz（游戏音效标准）
            "-ac", "2",      # 立体声
            "-sample_fmt", "s16",  # 16bit
            output_path
        ]
        
        run_kwargs = {
            "capture_output": True,
            "text": True,
            "timeout": 30,
        }
        if os.name == "nt":
            run_kwargs["creationflags"] = subprocess.CREATE_NO_WINDOW

        result = subprocess.run(cmd, **run_kwargs)
        
        if result.returncode == 0 and os.path.exists(output_path):
            return True, None
        else:
            return False, f"FFmpeg 转换失败: {result.stderr[:200]}"
            
    except subprocess.TimeoutExpired:
        return False, "FFmpeg 转换超时"
    except Exception as e:
        return False, f"FFmpeg 转换异常: {str(e)}"


def write_response(resp_file, signal_file, result):
    """写入响应文件并创建信号
    
    result 格式: {"success": bool, "content": str} 或 {"success": bool, "error": str}
    v1.0+: 成功时直接写入提取后的 content（纯文本），Lua 不再需要解析 JSON
    v1.0+: 支持音频文件路径返回
    """
    try:
        if result.get("success"):
            # 成功：直接写入提取后的 content（纯文本）
            content = result.get("content", "")
        else:
            # 失败：写入错误信息
            content = f"[ERROR] {result.get('error', '未知错误')}"
        
        # 先写入响应文件
        with open(resp_file, 'w', encoding='utf-8') as f:
            f.write(content)
        
        # 再创建信号文件（原子操作，Lua 检测到信号时响应文件一定已写入）
        with open(signal_file, 'w') as f:
            f.write("done")
        
        return True
    except Exception as e:
        # 尝试写入错误信息
        try:
            with open(resp_file, 'w', encoding='utf-8') as f:
                f.write(f"[ERROR] 写入响应失败: {e}")
            with open(signal_file, 'w') as f:
                f.write("done")
        except:
            pass
        return False


def main():
    if len(sys.argv) < 8:
        emergency_log(f"参数不足: 需要 7 个，实际 {len(sys.argv)-1}")
        print("用法: rai_http_worker_v2.py <request_id> <api_url> <key_file> <model> <msg_file> <resp_file> <signal_file> [mode]", file=sys.stderr)
        sys.exit(1)
    
    request_id = sys.argv[1]
    api_url = sys.argv[2]
    key_file = sys.argv[3]  # 这是 key 文件路径
    model = sys.argv[4]
    msg_file = sys.argv[5]
    resp_file = sys.argv[6]
    signal_file = sys.argv[7]
    mode = sys.argv[8] if len(sys.argv) > 8 else "llm"  # v1.0+ 新增 mode 参数
    
    # 读取 API Key 文件内容
    try:
        api_key = read_text_file_smart(key_file).strip()
    except Exception as e:
        emergency_log(f"读取 API Key 文件失败: {e}")
        write_response(resp_file, signal_file, {"success": False, "error": f"读取 API Key 失败: {e}"})
        sys.exit(1)
    
    # 确保临时目录存在
    try:
        os.makedirs(os.path.dirname(resp_file) or ".", exist_ok=True)
    except Exception as e:
        emergency_log(f"创建临时目录失败: {e}")
    
    if mode == "elevenlabs_voices":
        result = make_elevenlabs_voices_request(api_key)
        write_response(resp_file, signal_file, result)
        return

    if mode == "models":
        result = make_models_request(api_url, api_key)
        write_response(resp_file, signal_file, result)
        return

    if mode == "llm_stream":
        messages, error = read_messages(msg_file)
        if error:
            fail_stream(resp_file, signal_file, error)
            return

        make_api_stream_request(api_url, api_key, model, messages, resp_file, signal_file)
        return

    if mode == "elevenlabs":
        # v1.0+ ElevenLabs 智能分流模式
        # api_url 参数在 elevenlabs 模式下是 config.txt 路径
        config_path = api_url
        
        # 读取完整配置（用于翻译和 voice_id）
        config = parse_config_file(config_path)
        
        # 从 key_file 读取 ElevenLabs API Key（Lua 写入的临时文件）
        try:
            elevenlabs_key = read_text_file_smart(key_file).strip()
        except Exception as e:
            emergency_log(f"读取 API Key 文件失败: {e}")
            write_response(resp_file, signal_file, {"success": False, "error": f"读取 API Key 失败: {e}"})
            sys.exit(1)
        
        if not elevenlabs_key:
            write_response(resp_file, signal_file, {"success": False, "error": "ElevenLabs API Key 为空"})
            sys.exit(1)
        
        # 读取文本内容
        try:
            text_content = read_text_file_smart(msg_file).strip()
        except Exception as e:
            write_response(resp_file, signal_file, {"success": False, "error": f"读取文本文件失败: {e}"})
            sys.exit(1)
        
        if not text_content:
            write_response(resp_file, signal_file, {"success": False, "error": "文本内容为空"})
            sys.exit(1)
        
        audio_req = parse_audio_request_payload(text_content)
        
        if audio_req["mode"] == "vox":
            llm_url = config.get("llm_url")
            llm_key = config.get("llm_key")
            llm_model = config.get("llm_model")
            output_dir = _safe_output_dir(audio_req.get("output_dir"))

            if audio_req.get("semantic_parse"):
                source_for_parse = audio_req.get("source_text") or audio_req.get("spoken_text") or ""
                parsed_vox = parse_vox_request_by_llm(llm_url, llm_key, llm_model, source_for_parse, audio_req)
                if parsed_vox:
                    audio_req["spoken_text"] = parsed_vox.get("spoken_text") or audio_req.get("spoken_text") or ""
                    audio_req["gender"] = parsed_vox.get("gender") or audio_req.get("gender") or ""
                    audio_req["voice_style"] = parsed_vox.get("voice_style") or audio_req.get("voice_style") or ""
                    audio_req["performance_prompt"] = parsed_vox.get("performance_prompt") or audio_req.get("performance_prompt") or audio_req.get("performance") or ""
                    audio_req["performance"] = audio_req.get("performance_prompt") or audio_req.get("performance") or ""
                    for key in ("emotion", "intensity", "pace", "volume", "delivery", "audio_tags"):
                        if parsed_vox.get(key) not in (None, "", []):
                            audio_req[key] = parsed_vox.get(key)
                    if parsed_vox.get("track_name") and not audio_req.get("track_name"):
                        audio_req["track_name"] = parsed_vox.get("track_name")
                    log(
                        "VOX 语义抽取: "
                        f"source='{source_for_parse}', spoken='{audio_req.get('spoken_text')}', "
                        f"gender='{audio_req.get('gender')}', style='{audio_req.get('voice_style')}', "
                        f"performance='{audio_req.get('performance_prompt')}'"
                    )
                else:
                    # Lightweight fallback for offline or unavailable LLM. The main path above is LLM-based.
                    fallback_pref, fallback_text = extract_voice_preference(source_for_parse)
                    if fallback_text and fallback_text != source_for_parse:
                        audio_req["spoken_text"] = fallback_text
                    if fallback_pref and not audio_req.get("voice_style"):
                        audio_req["voice_style"] = fallback_pref
                    if fallback_pref and not audio_req.get("performance_prompt"):
                        audio_req["performance_prompt"] = fallback_pref
                    if not audio_req.get("gender"):
                        audio_req["gender"] = _infer_gender_from_text(fallback_pref or source_for_parse)

            # 语音模式：TTS（把文字读出来）
            # v1.0+ 智能 Voice 选择
            clean_text = audio_req.get("spoken_text") or ""
            preference_parts = []
            if audio_req.get("gender") == "male":
                preference_parts.append("男声")
            elif audio_req.get("gender") == "female":
                preference_parts.append("女声")
            if audio_req.get("voice_style"):
                preference_parts.append(audio_req.get("voice_style"))
            if audio_req.get("performance_prompt") or audio_req.get("performance"):
                preference_parts.append(audio_req.get("performance_prompt") or audio_req.get("performance"))
            preference = " ".join(preference_parts).strip()
            performance = audio_req.get("performance_prompt") or audio_req.get("performance") or _infer_tts_performance(preference)
            performance_data = {
                "performance_prompt": performance,
                "performance": audio_req.get("performance") or "",
                "emotion": audio_req.get("emotion") or "",
                "intensity": audio_req.get("intensity"),
                "pace": audio_req.get("pace") or "",
                "volume": audio_req.get("volume") or "",
                "delivery": audio_req.get("delivery") or "",
                "audio_tags": audio_req.get("audio_tags") if isinstance(audio_req.get("audio_tags"), list) else [],
            }
            
            if not clean_text:
                write_response(resp_file, signal_file, {"success": False, "error": "VOX 台词为空，请填写要朗读的内容"})
                sys.exit(1)
            
            preferred_gender = audio_req.get("gender") if audio_req.get("gender") in ("male", "female") else ""
            
            selected_voice_id = (audio_req.get("voice_id") or "").strip()

            # 1. 用户在生成音频页签显式选择的声线优先。若该声线需要高级订阅，
            # make_elevenlabs_tts_request 会继续尝试同一性别的内置免费声线。
            voice_id = selected_voice_id

            # 2. 未显式选择时，先尝试关键词匹配。显式性别会作为硬约束传入，避免男声请求落到女声。
            if not voice_id:
                voice_id = select_voice_by_preference(preference, preferred_gender)
            
            # 3. 关键词匹配不到，且 LLM 配置可用 → 调用 LLM 兜底
            if not voice_id:
                if llm_key and llm_key != "在此填入你的 API Key" and preference:
                    voice_id = select_voice_by_llm(llm_url, llm_key, llm_model, preference, preferred_gender)
            
            # 4. 仍无匹配，使用同一性别的默认免费语音
            if not voice_id:
                voice_id = _default_voice_id(preferred_gender)
            
            compiled_preview = _compile_tts_performance(clean_text, performance, audio_req.get("voice_style") or "", performance_data)
            log(f"Voice 选择: 偏好='{preference}', 表演='{compiled_preview.get('summary')}', 纯文本='{clean_text}', 选中 voice_id={voice_id}")
            result = make_elevenlabs_tts_request(
                elevenlabs_key,
                clean_text,
                voice_id,
                output_dir=output_dir,
                preferred_gender=preferred_gender,
                performance=performance,
                voice_style=audio_req.get("voice_style") or "",
                performance_data=performance_data,
            )
            result = prepend_audio_lines(result, [
                "类型: VOX",
                f"声线ID: {voice_id}",
                f"声音: {preference or '默认'}",
                f"语气: {performance or '默认'}",
                f"表演编译: {compiled_preview.get('summary') or '默认'}",
                f"台词: {clean_text}",
                f"保存目录: {output_dir}",
            ])
        else:
            # 音效模式：Sound Effects（生成爆炸声等）
            sfx_prompt = audio_req.get("prompt") or audio_req.get("source_text") or ""
            output_dir = _safe_output_dir(audio_req.get("output_dir"))
            if not sfx_prompt:
                write_response(resp_file, signal_file, {"success": False, "error": "SFX 描述为空，请填写要生成的音效"})
                sys.exit(1)
            
            if _has_chinese(sfx_prompt):
                # 需要翻译：调用 LLM 把中文翻译成英文提示词
                llm_url = config.get("llm_url")
                llm_key = config.get("llm_key")
                llm_model = config.get("llm_model")
                
                if not llm_key or llm_key == "在此填入你的 API Key":
                    write_response(resp_file, signal_file, {"success": False, "error": "检测到中文提示词，但 LLM API Key 未配置，无法翻译。请在配置文件中设置 LLM_API_KEY，或使用英文描述。"})
                    sys.exit(1)
                
                translated, error = translate_to_english(llm_url, llm_key, llm_model, sfx_prompt)
                if error:
                    write_response(resp_file, signal_file, {"success": False, "error": f"翻译失败: {error}"})
                    sys.exit(1)
                
                log(f"中文提示词 '{sfx_prompt}' 翻译为: '{translated}'")
                result = make_elevenlabs_sound_request(elevenlabs_key, translated, output_dir=output_dir)
                result = prepend_audio_lines(result, [
                    "类型: SFX",
                    f"描述: {sfx_prompt}",
                    f"英文提示词: {translated}",
                    f"保存目录: {output_dir}",
                ])
            else:
                # 英文直接调用 Sound Effects API
                result = make_elevenlabs_sound_request(elevenlabs_key, sfx_prompt, output_dir=output_dir)
                result = prepend_audio_lines(result, [
                    "类型: SFX",
                    f"描述: {sfx_prompt}",
                    f"保存目录: {output_dir}",
                ])
        
    else:
        # 默认 LLM 模式
        # 读取消息
        messages, error = read_messages(msg_file)
        if error:
            write_response(resp_file, signal_file, {"success": False, "error": error})
            sys.exit(1)
        
        # 执行 API 请求
        result = make_api_request(api_url, api_key, model, messages)
    
    # 写入响应并发送信号
    write_response(resp_file, signal_file, result)


if __name__ == "__main__":
    main()
