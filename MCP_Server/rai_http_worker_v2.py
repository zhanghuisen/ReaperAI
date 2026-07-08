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

RESPONSE_TIMEOUT = 90  # 秒
TEMP_DIR = os.environ.get('TEMP', 'C:\\Temp')
ELEVENLABS_TIMEOUT = 180  # 音频生成可能需要更长时间
SFX_DURATION_SECONDS = 4.0  # 固定短音效时长，避免 Sound Effects 长时间排队

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


def post_llm_payload(api_url, headers, payload):
    return requests.post(
        api_url,
        headers=headers,
        json=payload,
        timeout=RESPONSE_TIMEOUT
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
        clean_text = clean_text.strip()
        
        return preference, clean_text if clean_text else text
    
    # 没有任何偏好信息
    return "", text


def _voice_by_id(voice_id):
    for voice in FREE_VOICES:
        if voice["id"] == voice_id:
            return voice
    return None


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
  "voice_style": "short voice/performance description",
  "track_name": ""
}

Rules:
- Understand Chinese and English natural language.
- Do not include instruction words such as 男生, 女声, 大喊, say, read, 用...说 in spoken_text.
- Preserve the language of the words that should be spoken. Do not translate spoken_text unless the user explicitly asks for translation.
- Put acting directions such as 大喊, whispering, angry, urgent, calm into voice_style, not spoken_text.
- If the user clearly asks for a male voice, gender is male. If clearly female, gender is female. Otherwise use empty string.
- track_name should usually be empty unless the user explicitly names the track."""

    fallback_summary = {
        "source_text": fallback_req.get("source_text") or "",
        "spoken_text": fallback_req.get("spoken_text") or "",
        "gender": fallback_req.get("gender") or "",
        "voice_style": fallback_req.get("voice_style") or "",
    }
    user_prompt = f"""User 11vox request:
{user_text}

Current rough parse:
{json.dumps(fallback_summary, ensure_ascii=False)}

Examples:
Input: 11vox 男生大喊 fire in the hole
Output: {{"spoken_text":"fire in the hole","gender":"male","voice_style":"shouting, urgent","track_name":""}}

Input: 11vox 女声温柔说 欢迎回来
Output: {{"spoken_text":"欢迎回来","gender":"female","voice_style":"gentle, warm","track_name":""}}

Input: 11vox 用老人大声喊 Run!
Output: {{"spoken_text":"Run!","gender":"male","voice_style":"elderly, loud, shouting","track_name":""}}

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
    performance = _trim_audio_text(data.get("performance") or "")
    if performance and performance.lower() not in voice_style.lower():
        voice_style = (voice_style + ", " + performance).strip(" ,")

    return {
        "spoken_text": spoken_text,
        "gender": gender,
        "voice_style": voice_style,
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
                gender = str(data.get("gender") or "").strip().lower()
                if gender not in ("male", "female"):
                    gender = _infer_gender_from_text(voice_style)

                return {
                    "structured": True,
                    "mode": mode,
                    "track_name": _trim_audio_text(data.get("track_name") or ""),
                    "prompt": _trim_audio_text(data.get("prompt") or data.get("description") or ""),
                    "gender": gender,
                    "voice_style": voice_style,
                    "spoken_text": _trim_audio_text(data.get("spoken_text") or data.get("text") or ""),
                    "source_text": _trim_audio_text(data.get("source_text") or ""),
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
            "spoken_text": spoken_text,
            "source_text": text,
            "semantic_parse": bool(explicit_vox),
        }

    return {
        "structured": False,
        "mode": "sfx",
        "track_name": "",
        "prompt": text,
        "gender": "",
        "voice_style": "",
        "spoken_text": "",
        "source_text": text,
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


def _do_tts_request(api_key, text, voice_id):
    """内部：执行单次 TTS 请求，返回 response 对象"""
    headers = {
        "Accept": "audio/mpeg",
        "Content-Type": "application/json",
        "xi-api-key": api_key
    }
    payload = {
        "text": text,
        "model_id": "eleven_multilingual_v2",
        "voice_settings": {
            "stability": 0.5,
            "similarity_boost": 0.75
        }
    }
    response = requests.post(
        f"https://api.elevenlabs.io/v1/text-to-speech/{voice_id}",
        headers=headers,
        json=payload,
        timeout=ELEVENLABS_TIMEOUT
    )
    return response


def make_elevenlabs_tts_request(api_key, text, voice_id, output_dir=None, preferred_gender=""):
    """调用 ElevenLabs TTS API 生成语音
    
    v1.0+ 新增：
    - 支持传入 voice_id 参数
    - 402 自动 fallback：遇到付费限制时尝试同一性别的其他免费 voice
    - 显式选择男/女后不跨性别降级，避免男声请求生成女声
    """
    if not output_dir:
        output_dir = TEMP_DIR
    
    os.makedirs(output_dir, exist_ok=True)
    timestamp = int(time.time())
    temp_mp3 = os.path.join(output_dir, f"elevenlabs_tts_{timestamp}.mp3")
    output_wav = os.path.join(output_dir, f"elevenlabs_tts_{timestamp}.wav")
    
    # 构建尝试列表：首选 voice 放第一个；显式性别只在同一性别池内兜底。
    voices_to_try = _build_voice_try_list(voice_id, preferred_gender)
    if not voices_to_try:
        return {"success": False, "error": f"没有可用的{_gender_label(preferred_gender)}免费声线"}
    
    last_error = None
    tried_voices = []
    
    for vid in voices_to_try:
        tried_voices.append(vid)
        try:
            response = _do_tts_request(api_key, text, vid)
            
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
                    return {"success": True, "content": f"[所选语音不可用，已自动改用{_gender_label(preferred_gender)}免费相似声线]\n{output_wav}"}
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
    return {"success": False, "error": f"所有{_gender_label(preferred_gender)}免费声线均不可用。最后一次错误: {last_error}"}


def make_elevenlabs_sound_request(api_key, text, output_dir=None):
    """调用 ElevenLabs Sound Effects API 生成音效
    
    v1.0+ 新增：根据文本描述生成音效（爆炸声、脚步声等）
    """
    if not output_dir:
        output_dir = TEMP_DIR
    
    os.makedirs(output_dir, exist_ok=True)
    timestamp = int(time.time())
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


def get_ffmpeg_path():
    """获取 FFmpeg 可执行文件路径"""
    # 1. 检查 config.json 中配置的路径
    config_paths = [
        os.path.join(os.path.dirname(__file__), "config.json"),
        os.path.join(os.path.dirname(__file__), "..", "config.json"),
    ]
    for config_path in config_paths:
        if os.path.exists(config_path):
            try:
                config = json.loads(read_text_file_smart(config_path))
                ffmpeg_path = config.get("ffmpeg_path", "")
                if ffmpeg_path and os.path.exists(ffmpeg_path):
                    return ffmpeg_path
            except:
                pass
    
    # 2. 检查项目目录下的 tools/ffmpeg
    local_ffmpeg = os.path.join(os.path.dirname(__file__), "tools", "ffmpeg", "bin", "ffmpeg.exe")
    if os.path.exists(local_ffmpeg):
        return local_ffmpeg
    
    # 3. 检查系统 PATH
    ffmpeg_cmd = shutil.which("ffmpeg")
    if ffmpeg_cmd:
        return ffmpeg_cmd
    
    # 4. 常见安装位置
    common_paths = [
        r"C:\ffmpeg\bin\ffmpeg.exe",
        r"C:\Program Files\ffmpeg\bin\ffmpeg.exe",
        r"C:\Program Files (x86)\ffmpeg\bin\ffmpeg.exe",
    ]
    for path in common_paths:
        if os.path.exists(path):
            return path
    
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


def make_elevenlabs_request(api_key, text, output_dir=None):
    """[已废弃] v1.0 旧版 ElevenLabs API 调用
    
    v1.0+ 请直接使用 make_elevenlabs_tts_request 或 make_elevenlabs_sound_request
    为兼容保留，默认使用免费语音 Rachel
    """
    return make_elevenlabs_tts_request(api_key, text, "21m00Tcm4TlvDq8ikWAM", output_dir)


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
    
    if mode == "models":
        result = make_models_request(api_url, api_key)
        write_response(resp_file, signal_file, result)
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

            if audio_req.get("semantic_parse"):
                source_for_parse = audio_req.get("source_text") or audio_req.get("spoken_text") or ""
                parsed_vox = parse_vox_request_by_llm(llm_url, llm_key, llm_model, source_for_parse, audio_req)
                if parsed_vox:
                    audio_req["spoken_text"] = parsed_vox.get("spoken_text") or audio_req.get("spoken_text") or ""
                    audio_req["gender"] = parsed_vox.get("gender") or audio_req.get("gender") or ""
                    audio_req["voice_style"] = parsed_vox.get("voice_style") or audio_req.get("voice_style") or ""
                    if parsed_vox.get("track_name") and not audio_req.get("track_name"):
                        audio_req["track_name"] = parsed_vox.get("track_name")
                    log(
                        "VOX 语义抽取: "
                        f"source='{source_for_parse}', spoken='{audio_req.get('spoken_text')}', "
                        f"gender='{audio_req.get('gender')}', style='{audio_req.get('voice_style')}'"
                    )
                else:
                    # Lightweight fallback for offline or unavailable LLM. The main path above is LLM-based.
                    fallback_pref, fallback_text = extract_voice_preference(source_for_parse)
                    if fallback_text and fallback_text != source_for_parse:
                        audio_req["spoken_text"] = fallback_text
                    if fallback_pref and not audio_req.get("voice_style"):
                        audio_req["voice_style"] = fallback_pref
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
            preference = " ".join(preference_parts).strip()
            
            if not clean_text:
                write_response(resp_file, signal_file, {"success": False, "error": "VOX 台词为空，请填写要朗读的内容"})
                sys.exit(1)
            
            preferred_gender = audio_req.get("gender") if audio_req.get("gender") in ("male", "female") else ""
            
            # 1. 先尝试关键词匹配。显式性别会作为硬约束传入，避免男声请求落到女声。
            voice_id = select_voice_by_preference(preference, preferred_gender)
            
            # 2. 关键词匹配不到，且 LLM 配置可用 → 调用 LLM 兜底
            if not voice_id:
                if llm_key and llm_key != "在此填入你的 API Key" and preference:
                    voice_id = select_voice_by_llm(llm_url, llm_key, llm_model, preference, preferred_gender)
            
            # 3. 仍无匹配，使用同一性别的默认免费语音
            if not voice_id:
                voice_id = _default_voice_id(preferred_gender)
            
            log(f"Voice 选择: 偏好='{preference}', 纯文本='{clean_text}', 选中 voice_id={voice_id}")
            result = make_elevenlabs_tts_request(elevenlabs_key, clean_text, voice_id, preferred_gender=preferred_gender)
            result = prepend_audio_lines(result, [
                "类型: VOX",
                f"声音: {preference or '默认'}",
                f"台词: {clean_text}",
            ])
        else:
            # 音效模式：Sound Effects（生成爆炸声等）
            sfx_prompt = audio_req.get("prompt") or audio_req.get("source_text") or ""
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
                result = make_elevenlabs_sound_request(elevenlabs_key, translated)
                result = prepend_audio_lines(result, [
                    "类型: SFX",
                    f"描述: {sfx_prompt}",
                    f"英文提示词: {translated}",
                ])
            else:
                # 英文直接调用 Sound Effects API
                result = make_elevenlabs_sound_request(elevenlabs_key, sfx_prompt)
                result = prepend_audio_lines(result, [
                    "类型: SFX",
                    f"描述: {sfx_prompt}",
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
