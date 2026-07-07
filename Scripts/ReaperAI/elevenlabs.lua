local ElevenLabs = {}

local function esc(s)
  if not s then return "" end
  s = tostring(s)
  s = s:gsub("\\", "\\\\")
  s = s:gsub('"', '\\"')
  s = s:gsub("\n", "\\n")
  s = s:gsub("\r", "")
  s = s:gsub("\t", "  ")
  return s
end

local function trim_text(s)
  return tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function json_string(s)
  return '"' .. esc(s) .. '"'
end

local function lua_string_literal(s)
  s = tostring(s or "")
  s = s:gsub("\\", "\\\\")
  s = s:gsub('"', '\\"')
  s = s:gsub("\r", "\\r")
  s = s:gsub("\n", "\\n")
  return '"' .. s .. '"'
end

local function utf8_safe_sub(s, max_chars)
  s = tostring(s or "")
  max_chars = tonumber(max_chars) or 0
  if max_chars <= 0 then return "" end

  local i = 1
  local chars = 0
  local len = #s
  while i <= len and chars < max_chars do
    local b = s:byte(i)
    if not b then break end
    local step = 1
    if b >= 240 then
      step = 4
    elseif b >= 224 then
      step = 3
    elseif b >= 192 then
      step = 2
    end
    if i + step - 1 > len then break end
    i = i + step
    chars = chars + 1
  end

  return s:sub(1, i - 1)
end

local function safe_track_name(name, fallback)
  name = trim_text(name)
  if name == "" then name = fallback or "11_Audio" end
  name = name:gsub("[\r\n\t]", " ")
  name = name:gsub("[\\/:*?\"<>|]", "_")
  name = trim_text(name):gsub("%s%s+", " ")
  if name == "" then name = fallback or "11_Audio" end
  return utf8_safe_sub(name, 36)
end

local function normalize_label_text(text)
  text = trim_text(text)
  text = text:gsub("^11[_%s%-]*[Ss][Ff][Xx][_%s%-]*", "")
  text = text:gsub("^11[_%s%-]*[Vv][Oo][Xx][_%s%-]*", "")
  text = text:gsub("^11[_%s%-]*", "")
  text = text:gsub("^[Ss][Ff][Xx][%s:：_-]*", "")
  text = text:gsub("^[Vv][Oo][Xx][%s:：_-]*", "")
  text = text:gsub("^[Vv]oice[%s:：_-]*", "")
  text = text:gsub("^生成一个%s*", "")
  text = text:gsub("^生成一段%s*", "")
  text = text:gsub("^生成%s*", "")
  text = text:gsub("^请帮我%s*", "")
  text = text:gsub("^帮我%s*", "")
  text = text:gsub("音效", "")
  text = text:gsub("声效", "")
  text = text:gsub("声音", "")
  text = text:gsub("%s+", "")
  text = text:gsub("[，。！？、,.!?;；:：]+", "_")
  text = trim_text(text):gsub("^_+", ""):gsub("_+$", "")
  return text
end

local function collect_keyword_label(text, maps, max_parts)
  local parts = {}
  local seen = {}
  local lower = tostring(text or ""):lower()
  for _, item in ipairs(maps or {}) do
    for _, word in ipairs(item.words or {}) do
      if lower:find(tostring(word):lower(), 1, true) then
        if not seen[item.label] then
          table.insert(parts, item.label)
          seen[item.label] = true
        end
        break
      end
    end
    if max_parts and #parts >= max_parts then break end
  end
  return table.concat(parts)
end

local SFX_LABEL_MAP = {
  {label = "Rock", words = {"石头", "岩石", "rock", "stone"}},
  {label = "Grass", words = {"草地", "草", "grass"}},
  {label = "Wood", words = {"木头", "木", "wood"}},
  {label = "Metal", words = {"金属", "铁", "metal"}},
  {label = "Glass", words = {"玻璃", "glass"}},
  {label = "Explosion", words = {"爆炸", "炸", "explosion", "explode"}},
  {label = "Footstep", words = {"脚步", "走路", "footstep", "steps"}},
  {label = "Impact", words = {"撞击", "碰撞", "砸", "hit", "impact", "crash"}},
  {label = "Whoosh", words = {"呼啸", "划过", "whoosh", "swoosh"}},
  {label = "Door", words = {"门", "door"}},
  {label = "Wind", words = {"风", "wind"}},
  {label = "Rain", words = {"雨", "rain"}},
  {label = "Thunder", words = {"雷", "thunder"}},
  {label = "Water", words = {"水", "water"}},
  {label = "Fire", words = {"火", "fire"}},
  {label = "Gun", words = {"枪", "gun", "shot"}},
  {label = "Scream", words = {"尖叫", "scream"}},
  {label = "Robot", words = {"机器人", "机械", "robot", "machine"}},
  {label = "Magic", words = {"魔法", "magic"}},
  {label = "UI", words = {"ui", "按钮", "提示音", "click", "beep"}},
}

local VOX_STYLE_MAP = {
  {label = "Deep", words = {"深沉", "低沉", "deep", "low"}},
  {label = "Sweet", words = {"甜蜜", "甜美", "sweet"}},
  {label = "Soft", words = {"温柔", "柔和", "soft", "gentle"}},
  {label = "Husky", words = {"沙哑", "husky", "raspy"}},
  {label = "Cute", words = {"可爱", "cute"}},
  {label = "Calm", words = {"冷静", "平静", "calm"}},
  {label = "Angry", words = {"愤怒", "生气", "angry"}},
  {label = "Happy", words = {"开心", "快乐", "happy"}},
  {label = "Sad", words = {"悲伤", "sad"}},
  {label = "Old", words = {"老人", "老年", "old", "elder"}},
  {label = "Young", words = {"年轻", "少女", "young"}},
}

local function strip_audio_track_prefix(name)
  name = trim_text(name)
  name = name:gsub("^11[_%s%-]*[Ss][Ff][Xx][_%s%-]*", "")
  name = name:gsub("^11[_%s%-]*[Vv][Oo][Xx][_%s%-]*", "")
  name = name:gsub("^11[_%s%-]*", "")
  return trim_text(name)
end

local function infer_sfx_track_label(text)
  text = normalize_label_text(text)
  local keyword_label = collect_keyword_label(text, SFX_LABEL_MAP, 2)
  if keyword_label ~= "" then return keyword_label end
  text = text:gsub("把.-$", "")
  text = text:gsub("需要", "")
  text = text:gsub("短促", "")
  text = text:gsub("一点", "")
  text = trim_text(text)
  if text == "" then return "SFX" end
  return utf8_safe_sub(text, 10)
end

local function infer_vox_track_label(req)
  local style = normalize_label_text(req.voice_style or "")
  local style_label = collect_keyword_label(style, VOX_STYLE_MAP, 1)
  local gender_label = (req.gender == "male") and "Male" or "Female"
  if style_label == "" and style ~= "" then
    style_label = utf8_safe_sub(style:gsub("男声", ""):gsub("男生", ""):gsub("女声", ""):gsub("女生", ""), 8)
  end
  if style_label == "" then style_label = "Voice" end
  return style_label .. gender_label
end

local function elevenlabs_track_name(mode, candidate, req)
  mode = (mode == "vox") and "vox" or "sfx"
  local prefix = (mode == "vox") and "11_VOX_" or "11_SFX_"
  local base = strip_audio_track_prefix(candidate or "")
  if base == "" then
    base = (mode == "vox") and infer_vox_track_label(req) or infer_sfx_track_label(req.prompt or req.source_text or "")
  end
  base = normalize_label_text(base)
  if base == "" then base = (mode == "vox") and "Voice" or "SFX" end
  return safe_track_name(prefix .. base, prefix .. ((mode == "vox") and "Voice" or "SFX"))
end

local function contains_any(text, words)
  text = tostring(text or "")
  local lower = text:lower()
  for _, word in ipairs(words or {}) do
    if lower:find(tostring(word):lower(), 1, true) then
      return true
    end
  end
  return false
end

local function strip_audio_shortcut_prefix(text)
  text = trim_text(text)
  text = text:gsub("^11[_%s%-]*", "")
  return trim_text(text)
end

local function split_vox_style_and_text(text)
  text = trim_text(text)
  local patterns = {
    "^生成一个%s*(.-)%s*说%s*(.+)$",
    "^生成一段%s*(.-)%s*说%s*(.+)$",
    "^生成%s*(.-)%s*说%s*(.+)$",
    "^用%s*(.-)%s*语音%s*说%s*(.+)$",
    "^用%s*(.-)%s*声音%s*说%s*(.+)$",
    "^用%s*(.-)%s*声%s*说%s*(.+)$",
    "^用%s*(.-)%s*说%s*(.+)$",
    "^让%s*(.-)%s*说%s*(.+)$",
    "^让%s*(.-)%s*读%s*(.+)$",
    "^让%s*(.-)%s*念%s*(.+)$",
    "^(.+)%s*说%s*(.+)$",
    "^(.+)%s*读%s*(.+)$",
    "^(.+)%s*念%s*(.+)$",
  }

  for _, pattern in ipairs(patterns) do
    local style, spoken = text:match(pattern)
    style = trim_text(style)
    spoken = trim_text(spoken)
    if spoken ~= "" then
      style = style:gsub("^一个%s*", ""):gsub("^一段%s*", "")
      return trim_text(style), spoken
    end
  end

  return "", text
end

local function infer_audio_gender(style)
  style = tostring(style or "")
  if contains_any(style, {"女声", "女生", "女性", "女孩", "少女", "female", "woman", "girl", "lady"}) then
    return "female"
  end
  if contains_any(style, {"男声", "男生", "男性", "男孩", "大叔", "male", "man", "boy"}) then
    return "male"
  end
  return nil
end

local function parse_audio_shortcut(text)
  local body = strip_audio_shortcut_prefix(text)
  local lower = body:lower()
  local req = {
    source_text = body,
    mode = "",
    prompt = "",
    voice_style = "",
    spoken_text = "",
    gender = "",
    track_name = "",
  }

  local explicit_vox = lower:match("^vox[%s:：_-]*(.*)$") or lower:match("^voice[%s:：_-]*(.*)$")
  local explicit_sfx = lower:match("^sfx[%s:：_-]*(.*)$") or lower:match("^sound[%s:：_-]*(.*)$")

  if explicit_vox then
    req.mode = "vox"
    body = trim_text(body:gsub("^[Vv][Oo][Xx][%s:：_-]*", ""):gsub("^[Vv]oice[%s:：_-]*", ""))
  elseif explicit_sfx then
    req.mode = "sfx"
    body = trim_text(body:gsub("^[Ss][Ff][Xx][%s:：_-]*", ""):gsub("^[Ss]ound[%s:：_-]*", ""))
  end

  if req.mode == "" then
    local has_speech = body:match("说%s*%S+") or body:match("读%s*%S+") or body:match("念%s*%S+")
    local has_sfx = contains_any(body, {
      "音效", "声效", "环境音", "爆炸", "脚步", "撞击", "风声", "门响", "尖叫声",
      "sound effect", "sfx", "ambience", "explosion", "footstep", "impact", "hit"
    })
    req.mode = has_speech and "vox" or (has_sfx and "sfx" or "sfx")
  end

  if req.mode == "vox" then
    local style, spoken = split_vox_style_and_text(body)
    req.voice_style = style
    req.spoken_text = spoken
    req.gender = infer_audio_gender(style) or ""
  else
    req.prompt = body
  end

  return req
end

function ElevenLabs.normalize_request(input)
  local req
  if type(input) == "table" then
    req = {}
    for k, v in pairs(input) do req[k] = v end
  else
    req = parse_audio_shortcut(input)
  end

  req.mode = tostring(req.mode or ""):lower()
  if req.mode ~= "vox" and req.mode ~= "sfx" then
    req.mode = "sfx"
  end

  if req.mode == "vox" then
    req.voice_style = trim_text(req.voice_style or req.style or "")
    req.spoken_text = trim_text(req.spoken_text or req.text or req.prompt or "")
    req.gender = tostring(req.gender or infer_audio_gender(req.voice_style) or ""):lower()
    if req.gender ~= "male" and req.gender ~= "female" then
      req.gender = infer_audio_gender(req.voice_style) or "female"
    end
    req.track_name = elevenlabs_track_name("vox", req.track_name, req)
  else
    req.prompt = trim_text(req.prompt or req.description or req.text or "")
    req.track_name = elevenlabs_track_name("sfx", req.track_name, req)
  end

  req.source_text = trim_text(req.source_text or "")
  return req
end

function ElevenLabs.request_json(req)
  local parts = {
    "{",
    '"mode":', json_string(req.mode),
    ',"track_name":', json_string(req.track_name),
    ',"prompt":', json_string(req.prompt or ""),
    ',"gender":', json_string(req.gender or ""),
    ',"voice_style":', json_string(req.voice_style or ""),
    ',"spoken_text":', json_string(req.spoken_text or ""),
    ',"source_text":', json_string(req.source_text or ""),
    "}"
  }
  return table.concat(parts)
end

function ElevenLabs.start_message(req)
  if req.mode == "vox" then
    local style = trim_text(((req.gender == "male") and "男声" or "女声") .. " " .. tostring(req.voice_style or ""))
    return "正在生成 VOX: " .. tostring(req.spoken_text or "") .. "\n声音: " .. style
  end
  return "正在生成 SFX: " .. tostring(req.prompt or "")
end

function ElevenLabs.parse_worker_response(response)
  local lines = {}
  for line in tostring(response or ""):gmatch("[^\r\n]+") do
    table.insert(lines, line)
  end
  return lines[#lines] or tostring(response or ""), (#lines > 1) and table.concat(lines, "\n", 1, #lines - 1) or nil
end

function ElevenLabs.build_import_script(track_name, wav_path)
  return string.format([[
    reaper.InsertTrackAtIndex(reaper.CountTracks(0), true)
    local track = reaper.GetTrack(0, reaper.CountTracks(0) - 1)
    reaper.GetSetMediaTrackInfo_String(track, "P_NAME", %s, true)
    reaper.SetOnlyTrackSelected(track)
    local ok = reaper.InsertMedia(%s, 0)
    return ok and "已导入音频" or "InsertMedia 返回 false"
  ]], lua_string_literal(track_name), lua_string_literal(wav_path))
end

ElevenLabs.trim_text = trim_text
ElevenLabs.safe_track_name = safe_track_name
ElevenLabs.elevenlabs_track_name = elevenlabs_track_name
ElevenLabs.utf8_safe_sub = utf8_safe_sub
ElevenLabs.infer_audio_gender = infer_audio_gender

return ElevenLabs
