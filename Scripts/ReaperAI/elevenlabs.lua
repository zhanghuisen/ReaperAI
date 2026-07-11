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

local function normalize_provider(provider)
  provider = trim_text(provider):lower()
  if provider == "doubao" or provider == "volcengine" or provider == "volc" or provider == "byteplus" then
    return "doubao"
  end
  return "elevenlabs"
end

local function provider_label(provider)
  provider = normalize_provider(provider)
  if provider == "doubao" then
    return "火山引擎豆包"
  end
  return "ElevenLabs"
end

local FREE_VOICE_OPTIONS = {
  { id = "21m00Tcm4TlvDq8ikWAM", name = "Rachel", gender = "female", free = true, tags = { "standard", "default", "female", "broadcast" } },
  { id = "AZnzlk1XvdvUeBnXmlld", name = "Domi", gender = "female", free = true, tags = { "mature", "calm", "female" } },
  { id = "EXAVITQu4vr4xnSDxMaL", name = "Bella", gender = "female", free = true, tags = { "sweet", "cute", "gentle", "female" } },
  { id = "MF3mGyEYCl7XYWbV9V6O", name = "Elli", gender = "female", free = true, tags = { "young", "energetic", "female" } },
  { id = "piTKgcLEGmPE4e6mEKli", name = "Nicole", gender = "female", free = true, tags = { "soft", "whisper", "female" } },
  { id = "pFZP5JQG7iQjIQuC4Bku", name = "Lily", gender = "female", free = true, tags = { "gentle", "young", "female" } },
  { id = "TxGEqnHWrfWFTfGW9XjX", name = "Josh", gender = "male", free = true, tags = { "standard", "default", "male", "deep" } },
  { id = "ErXwobaYiN019PkySvjV", name = "Antoni", gender = "male", free = true, tags = { "standard", "clear", "male" } },
  { id = "VR6AewLTigWG4xSOukaG", name = "Arnold", gender = "male", free = true, tags = { "husky", "raspy", "powerful", "male" } },
  { id = "pNInz6obpgDQGcFmaJgB", name = "Adam", gender = "male", free = true, tags = { "anchor", "formal", "serious", "male" } },
  { id = "yoZ06aMxZJJ28mfd3POQ", name = "Sam", gender = "male", free = true, tags = { "old", "mature", "male" } },
  { id = "ZQe5CZNOzWyzPSCn5a3c", name = "James", gender = "male", free = true, tags = { "australian", "accent", "male" } },
  { id = "zrHiDhphv9ZnVXBqCLhn", name = "Mimi", gender = "female", free = true, tags = { "australian", "accent", "female" } },
}

local function normalize_gender_value(gender)
  gender = tostring(gender or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  if gender == "m" or gender == "man" or gender == "male" then return "male" end
  if gender == "f" or gender == "woman" or gender == "female" then return "female" end
  return ""
end

local function copy_tags(tags)
  local out = {}
  if type(tags) == "table" then
    for _, tag in ipairs(tags) do
      tag = trim_text(tag)
      if tag ~= "" then table.insert(out, tag) end
    end
  elseif tags and tags ~= "" then
    for tag in tostring(tags):gmatch("[^,;|]+") do
      tag = trim_text(tag)
      if tag ~= "" then table.insert(out, tag) end
    end
  end
  return out
end

local function copy_voice(voice)
  if type(voice) ~= "table" then return nil end
  local id = trim_text(voice.id or voice.voice_id or "")
  if id == "" then return nil end
  local free_value = voice.free
  if type(free_value) == "string" then
    local lower = free_value:lower()
    free_value = lower == "1" or lower == "true" or lower == "yes" or lower == "free"
  end
  local available_value = voice.available
  if type(available_value) == "string" then
    local lower = available_value:lower()
    available_value = lower == "1" or lower == "true" or lower == "yes" or lower == "available" or lower == "verified"
  end
  return {
    id = id,
    name = trim_text(voice.name or voice.label or id),
    gender = normalize_gender_value(voice.gender),
    free = free_value == true,
    available = available_value == true,
    source = trim_text(voice.source or (free_value == true and "free" or "account")),
    tags = copy_tags(voice.tags),
  }
end

local function free_voices()
  local out = {}
  for _, voice in ipairs(FREE_VOICE_OPTIONS) do
    table.insert(out, copy_voice(voice))
  end
  return out
end

local function voice_by_id(voice_id, dynamic_voices)
  voice_id = trim_text(voice_id)
  if voice_id == "" then return nil end
  if dynamic_voices ~= nil then
    for _, voice in ipairs(dynamic_voices or {}) do
      if tostring(voice.id or voice.voice_id or "") == voice_id then
        return copy_voice(voice)
      end
    end
    return nil
  end
  for _, voice in ipairs(FREE_VOICE_OPTIONS) do
    if tostring(voice.id or voice.voice_id or "") == voice_id then
      return copy_voice(voice)
    end
  end
  return nil
end

local function voice_matches_gender(voice, gender)
  gender = normalize_gender_value(gender)
  if gender == "" then return true end
  return normalize_gender_value(voice and voice.gender) == gender
end

local function merged_voice_options(dynamic_voices)
  local out, index = {}, {}
  local function add(voice)
    voice = copy_voice(voice)
    if not voice then return end
    local existing_at = index[voice.id]
    if existing_at then
      out[existing_at] = voice
      return
    end
    index[voice.id] = #out + 1
    table.insert(out, voice)
  end
  for _, voice in ipairs(dynamic_voices or {}) do add(voice) end
  return out
end

local function voice_options_for_gender(gender, dynamic_voices)
  gender = normalize_gender_value(gender)
  local out = {}
  for _, voice in ipairs(merged_voice_options(dynamic_voices)) do
    if voice_matches_gender(voice, gender) then
      table.insert(out, voice)
    end
  end
  return out
end

local function default_voice_id(gender)
  gender = normalize_gender_value(gender)
  for _, voice in ipairs(FREE_VOICE_OPTIONS) do
    if voice_matches_gender(voice, gender) then
      return voice.id
    end
  end
  return "21m00Tcm4TlvDq8ikWAM"
end

local function voice_label(voice)
  voice = copy_voice(voice)
  if not voice then return "自动选择" end
  local gender_label = voice.gender == "male" and "男声" or (voice.gender == "female" and "女声" or "未标性别")
  return string.format("%s · %s", voice.name ~= "" and voice.name or voice.id, gender_label)
end

local function voice_menu_label(voice)
  voice = copy_voice(voice)
  if not voice then return "自动选择" end
  return voice_label(voice) .. "##audio_voice_" .. voice.id
end

local function voice_matches_filter(voice, filter)
  filter = trim_text(filter):lower()
  if filter == "" then return true end
  voice = copy_voice(voice)
  if not voice then return false end
  local haystack = {
    voice.id or "",
    voice.name or "",
    voice.gender or "",
    table.concat(voice.tags or {}, " "),
  }
  return table.concat(haystack, " "):lower():find(filter, 1, true) ~= nil
end

local function parse_voice_lines(content)
  local voices = {}
  for line in tostring(content or ""):gmatch("[^\r\n]+") do
    line = trim_text(line)
    if line ~= "" and not line:match("^#") then
      local fields = {}
      for field in (line .. "\t"):gmatch("([^\t]*)\t") do
        table.insert(fields, field)
      end
      local voice = copy_voice({
        id = fields[1] or "",
        name = fields[2] or "",
        gender = fields[3] or "",
        free = fields[4] or "",
        source = fields[5] or "",
        tags = fields[6] or "",
        available = fields[7] or "",
      })
      if voice then table.insert(voices, voice) end
    end
  end
  return voices
end

local DOUBAO_LANGUAGE_OPTIONS = {
  { id = "zh_mix", label = "中英混" },
  { id = "ja", label = "日语" },
  { id = "id", label = "印尼语" },
  { id = "es", label = "西班牙语" },
}

local DOUBAO_ACCENT_OPTIONS = {
  zh_mix = {
    { id = "default", label = "默认" },
    { id = "dongbei", label = "东北" },
    { id = "shaanxi", label = "陕西" },
    { id = "sichuan", label = "四川" },
  },
  ja = {
    { id = "default", label = "默认" },
  },
  id = {
    { id = "default", label = "默认" },
  },
  es = {
    { id = "default", label = "默认" },
  },
}

local function doubao_language_options()
  local out = {}
  for _, item in ipairs(DOUBAO_LANGUAGE_OPTIONS) do
    table.insert(out, { id = item.id, label = item.label })
  end
  return out
end

local function doubao_language_label(language)
  language = trim_text(language)
  if language == "" then language = "zh_mix" end
  for _, item in ipairs(DOUBAO_LANGUAGE_OPTIONS) do
    if item.id == language then return item.label end
  end
  return language
end

local function doubao_accent_options(language)
  language = trim_text(language)
  if language == "" then language = "zh_mix" end
  local source = DOUBAO_ACCENT_OPTIONS[language] or DOUBAO_ACCENT_OPTIONS.zh_mix
  local out = {}
  for _, item in ipairs(source) do
    table.insert(out, { id = item.id, label = item.label })
  end
  return out
end

local function doubao_default_accent(language)
  local options = doubao_accent_options(language)
  return (options[1] and options[1].id) or "default"
end

local function doubao_accent_label(language, accent)
  accent = trim_text(accent)
  if accent == "" then accent = doubao_default_accent(language) end
  for _, item in ipairs(doubao_accent_options(language)) do
    if item.id == accent then return item.label end
  end
  return accent
end

local function normalize_doubao_language(language)
  language = trim_text(language)
  language = language:lower()
  if language == "" or language == "zh" or language == "zh-cn" or language == "cn" or language == "zh_cn" then
    return "zh_mix"
  end
  if language == "japanese" or language == "jp" then return "ja" end
  if language == "indonesian" or language == "in" then return "id" end
  if language == "spanish" or language == "spa" then return "es" end
  for _, item in ipairs(DOUBAO_LANGUAGE_OPTIONS) do
    if item.id == language then return item.id end
  end
  return "zh_mix"
end

local function normalize_doubao_accent(language, accent)
  language = normalize_doubao_language(language)
  accent = trim_text(accent):lower()
  if language ~= "zh_mix" then return "default" end
  if accent == "" or accent == "standard" or accent == "mandarin" or accent == "普通话" then return "default" end
  if accent == "northeast" or accent == "东北话" then return "dongbei" end
  if accent == "shanxi" or accent == "陕西话" or accent == "陕北" then return "shaanxi" end
  if accent == "sichuanese" or accent == "四川话" or accent == "川普" then return "sichuan" end
  for _, item in ipairs(doubao_accent_options(language)) do
    if item.id == accent then return item.id end
  end
  return "default"
end

local function append_unique(list, value)
  value = trim_text(value)
  if value == "" then return end
  for _, item in ipairs(list) do
    if item == value then return end
  end
  table.insert(list, value)
end

local function list_contains(list, value)
  value = trim_text(value)
  for _, item in ipairs(list or {}) do
    if item == value then return true end
  end
  return false
end

local function capability_values_from_tags(tags, prefix, normalizer)
  local out = {}
  prefix = tostring(prefix or "")
  for _, tag in ipairs(tags or {}) do
    tag = trim_text(tag)
    if tag:sub(1, #prefix) == prefix then
      local value = trim_text(tag:sub(#prefix + 1))
      if normalizer then value = normalizer(value) end
      append_unique(out, value)
    end
  end
  return out
end

local function copy_capability_values(value, normalizer)
  local out = {}
  if type(value) == "table" then
    for _, item in ipairs(value) do
      item = normalizer and normalizer(item) or trim_text(item)
      append_unique(out, item)
    end
  elseif value and tostring(value) ~= "" then
    for item in tostring(value):gmatch("[^,;|]+") do
      item = normalizer and normalizer(item) or trim_text(item)
      append_unique(out, item)
    end
  end
  return out
end

local function normalize_doubao_control(control)
  control = trim_text(control):lower()
  if control == "speech" or control == "speech_rate" then return "speed" end
  if control == "loudness" or control == "loudness_rate" then return "volume" end
  if control == "pitch_rate" then return "pitch" end
  if control == "speed" or control == "pitch" or control == "volume" then return control end
  return ""
end

local function first_tag_value(tags, prefix)
  prefix = tostring(prefix or "")
  for _, tag in ipairs(tags or {}) do
    tag = trim_text(tag)
    if tag:sub(1, #prefix) == prefix then
      return trim_text(tag:sub(#prefix + 1))
    end
  end
  return ""
end

local function copy_doubao_voice(voice)
  if type(voice) ~= "table" then return nil end
  local id = trim_text(voice.id or voice.voice_id or voice.speaker or voice.speaker_id or "")
  if id == "" then return nil end
  local tags = copy_tags(voice.tags)
  local language = trim_text(voice.language or voice.lang or "")
  if language ~= "" then language = normalize_doubao_language(language) end
  local accent = trim_text(voice.accent or voice.dialect or "")
  if accent ~= "" then accent = normalize_doubao_accent(language ~= "" and language or "zh_mix", accent) end
  local languages = copy_capability_values(voice.languages or voice.langs or voice.supported_languages, normalize_doubao_language)
  for _, item in ipairs(capability_values_from_tags(tags, "lang:", normalize_doubao_language)) do append_unique(languages, item) end
  if #languages == 0 and language ~= "" then append_unique(languages, language) end
  if #languages == 0 then append_unique(languages, "zh_mix") end
  local accents = copy_capability_values(voice.accents or voice.dialects or voice.supported_dialects, function(item)
    return normalize_doubao_accent("zh_mix", item)
  end)
  for _, item in ipairs(capability_values_from_tags(tags, "accent:", function(value)
    return normalize_doubao_accent("zh_mix", value)
  end)) do append_unique(accents, item) end
  if #accents == 0 and accent ~= "" then append_unique(accents, accent) end
  if #accents == 0 then append_unique(accents, "default") end
  local controls = { speed = true, pitch = true, volume = true }
  local tagged_controls = capability_values_from_tags(tags, "control:", normalize_doubao_control)
  if #tagged_controls > 0 then
    controls = { speed = false, pitch = false, volume = false }
    for _, control in ipairs(tagged_controls) do
      if control ~= "" then controls[control] = true end
    end
  end
  local resource_id = trim_text(voice.resource_id or voice.resource or first_tag_value(tags, "resource:"))
  local known = true
  for _, tag in ipairs(tags) do
    if tag == "cap:unknown" then known = false end
  end
  local available_value = voice.available
  if type(available_value) == "string" then
    local lower = available_value:lower()
    available_value = lower == "1" or lower == "true" or lower == "yes" or lower == "available" or lower == "verified" or lower == "ready" or lower == "success"
  elseif type(available_value) == "number" then
    available_value = available_value ~= 0
  end
  return {
    id = id,
    name = trim_text(voice.name or voice.label or voice.alias or id),
    language = language,
    accent = accent,
    source = trim_text(voice.source or "account"),
    tags = tags,
    languages = languages,
    accents = accents,
    controls = controls,
    resource_id = resource_id,
    capabilities_known = known,
    available = available_value ~= false,
  }
end

local function parse_doubao_voice_lines(content)
  local voices = {}
  for line in tostring(content or ""):gmatch("[^\r\n]+") do
    line = trim_text(line)
    if line ~= "" and not line:match("^#") then
      local fields = {}
      for field in (line .. "\t"):gmatch("([^\t]*)\t") do
        table.insert(fields, field)
      end
      local voice = copy_doubao_voice({
        id = fields[1] or "",
        name = fields[2] or "",
        language = fields[3] or "",
        accent = fields[4] or "",
        source = fields[5] or "",
        tags = fields[6] or "",
        available = fields[7] or "",
      })
      if voice then table.insert(voices, voice) end
    end
  end
  return voices
end

local function doubao_voice_by_id(voice_id, dynamic_voices)
  voice_id = trim_text(voice_id)
  if voice_id == "" then return nil end
  for _, voice in ipairs(dynamic_voices or {}) do
    if tostring(voice.id or voice.voice_id or voice.speaker or "") == voice_id then
      return copy_doubao_voice(voice)
    end
  end
  return nil
end

local function doubao_voice_matches(language, accent, voice)
  voice = copy_doubao_voice(voice)
  if not voice then return false end
  language = normalize_doubao_language(language)
  accent = normalize_doubao_accent(language, accent)
  if not list_contains(voice.languages, language) then return false end
  if language == "zh_mix" and not list_contains(voice.accents, accent) then return false end
  return voice.available ~= false
end

local function doubao_voice_options(language, accent, dynamic_voices)
  local out, seen = {}, {}
  for _, voice in ipairs(dynamic_voices or {}) do
    voice = copy_doubao_voice(voice)
    if voice and not seen[voice.id] and doubao_voice_matches(language, accent, voice) then
      seen[voice.id] = true
      table.insert(out, voice)
    end
  end
  return out
end

local function doubao_voice_all_options(dynamic_voices)
  local out, seen = {}, {}
  for _, voice in ipairs(dynamic_voices or {}) do
    voice = copy_doubao_voice(voice)
    if voice and voice.available ~= false and not seen[voice.id] then
      seen[voice.id] = true
      table.insert(out, voice)
    end
  end
  return out
end

local function doubao_voice_language_options(voice)
  voice = copy_doubao_voice(voice)
  local out = {}
  if not voice then return doubao_language_options() end
  for _, language in ipairs(voice.languages or {}) do
    table.insert(out, { id = language, label = doubao_language_label(language) })
  end
  if #out == 0 then table.insert(out, { id = "zh_mix", label = doubao_language_label("zh_mix") }) end
  return out
end

local function doubao_voice_accent_options(voice, language)
  voice = copy_doubao_voice(voice)
  language = normalize_doubao_language(language)
  if not voice or language ~= "zh_mix" then return { { id = "default", label = doubao_accent_label(language, "default") } } end
  local out = {}
  for _, accent in ipairs(voice.accents or {}) do
    table.insert(out, { id = accent, label = doubao_accent_label(language, accent) })
  end
  if #out == 0 then table.insert(out, { id = "default", label = doubao_accent_label(language, "default") }) end
  return out
end

local function doubao_voice_default_language(voice)
  voice = copy_doubao_voice(voice)
  if not voice or not voice.languages or not voice.languages[1] then return "zh_mix" end
  return voice.languages[1]
end

local function doubao_voice_default_accent(voice, language)
  language = normalize_doubao_language(language)
  local options = doubao_voice_accent_options(voice, language)
  for _, item in ipairs(options) do
    if item.id == "default" then return "default" end
  end
  return (options[1] and options[1].id) or "default"
end

local function doubao_voice_supports_language(voice, language)
  voice = copy_doubao_voice(voice)
  if not voice then return false end
  return list_contains(voice.languages, normalize_doubao_language(language))
end

local function doubao_voice_supports_accent(voice, language, accent)
  voice = copy_doubao_voice(voice)
  if not voice then return false end
  language = normalize_doubao_language(language)
  accent = normalize_doubao_accent(language, accent)
  if language ~= "zh_mix" then return true end
  return list_contains(voice.accents, accent)
end

local function doubao_voice_label(voice)
  voice = copy_doubao_voice(voice)
  if not voice then return "手动音色ID" end
  local parts = { voice.name ~= "" and voice.name or voice.id }
  if #voice.languages > 1 then
    table.insert(parts, "多语种")
  elseif voice.languages[1] then
    table.insert(parts, doubao_language_label(voice.languages[1]))
  end
  if list_contains(voice.accents, "dongbei") or list_contains(voice.accents, "shaanxi") or list_contains(voice.accents, "sichuan") then
    table.insert(parts, "多口音")
  elseif voice.accents[1] and voice.accents[1] ~= "default" then
    table.insert(parts, doubao_accent_label("zh_mix", voice.accents[1]))
  end
  if voice.capabilities_known == false then table.insert(parts, "能力未知") end
  return table.concat(parts, " · ")
end

local function doubao_voice_menu_label(voice)
  voice = copy_doubao_voice(voice)
  if not voice then return "手动音色ID" end
  return doubao_voice_label(voice) .. "##doubao_voice_" .. voice.id
end

local function doubao_voice_matches_filter(voice, filter)
  filter = trim_text(filter):lower()
  if filter == "" then return true end
  voice = copy_doubao_voice(voice)
  if not voice then return false end
  local haystack = {
    voice.id or "",
    voice.name or "",
    voice.language or "",
    voice.accent or "",
    table.concat(voice.languages or {}, " "),
    table.concat(voice.accents or {}, " "),
    table.concat(voice.tags or {}, " "),
  }
  for _, language in ipairs(voice.languages or {}) do
    table.insert(haystack, doubao_language_label(language))
  end
  for _, accent in ipairs(voice.accents or {}) do
    table.insert(haystack, doubao_accent_label("zh_mix", accent))
  end
  return table.concat(haystack, " "):lower():find(filter, 1, true) ~= nil
end

local function doubao_voice_supports(language, accent, voice)
  return doubao_voice_matches(language, accent, voice)
end

local function doubao_voice_supports_control(voice, control)
  voice = copy_doubao_voice(voice)
  if not voice then return true end
  control = normalize_doubao_control(control)
  if control == "" then return true end
  return voice.controls and voice.controls[control] ~= false
end

local function doubao_voice_resource_id(voice)
  voice = copy_doubao_voice(voice)
  if not voice then return "" end
  return voice.resource_id or ""
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
  {label = "Shout", words = {"大喊", "喊叫", "喊", "吼", "shout", "shouting", "yell", "yelling", "loud"}},
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
  name = name:gsub("^Doubao[_%s%-]*", "")
  name = name:gsub("^豆包[_%s%-]*", "")
  return trim_text(name)
end

local function audio_track_name(provider, mode, candidate, req)
  provider = normalize_provider(provider)
  mode = (mode == "vox") and "vox" or "sfx"
  local base = strip_audio_track_prefix(candidate or "")
  local provider_name = (provider == "doubao") and "Doubao" or "ElevenLabs"
  if base ~= "" then
    return safe_track_name(base, provider_name .. " " .. ((mode == "vox") and "VOX" or "SFX"))
  end
  return provider_name .. " " .. ((mode == "vox") and "VOX" or "SFX")
end

local function elevenlabs_track_name(mode, candidate, req)
  return audio_track_name("elevenlabs", mode, candidate, req)
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
    performance = "",
    performance_prompt = "",
    spoken_text = "",
    gender = "",
    track_name = "",
    semantic_parse = false,
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
    req.performance = ""
    req.performance_prompt = ""
    req.spoken_text = spoken
    req.gender = infer_audio_gender(style) or ""
    req.semantic_parse = true
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

  req.provider = normalize_provider(req.provider or req.service or req.vendor or "")
  req.mode = tostring(req.mode or ""):lower()
  if req.mode ~= "vox" and req.mode ~= "sfx" then
    req.mode = "sfx"
  end

  if req.provider == "doubao" then
    req.language = normalize_doubao_language(req.language or req.lang or "")
    req.accent = normalize_doubao_accent(req.language, req.accent or req.dialect or "")
    req.speed_ratio = tonumber(req.speed_ratio or req.speed or req.speech_rate) or 1.0
    req.pitch_ratio = tonumber(req.pitch_ratio or req.pitch) or 1.0
    req.volume_ratio = tonumber(req.volume_ratio or req.volume) or 1.0
    if req.mode == "vox" then
      req.speaker = trim_text(req.speaker or req.voice_id or req.voice or "")
      req.speaker_name = trim_text(req.speaker_name or req.voice_name or "")
      req.voice_style = trim_text(req.voice_style or req.style or "")
      req.performance_prompt = trim_text(req.performance_prompt or req.performance or req.tone or "")
      req.performance = req.performance_prompt
      req.spoken_text = trim_text(req.spoken_text or req.text or req.prompt or req.description or "")
      req.text_prompt = trim_text(req.text_prompt or req.prompt or req.text or "")
      if req.text_prompt == "" and req.spoken_text ~= "" then
        if req.performance_prompt ~= "" then
          req.text_prompt = req.performance_prompt .. "：" .. req.spoken_text
        else
          req.text_prompt = req.spoken_text
        end
      end
      req.track_name = audio_track_name("doubao", "vox", req.track_name, req)
    else
      req.prompt = trim_text(req.prompt or req.description or req.text or req.source_text or "")
      req.text_prompt = trim_text(req.text_prompt or req.prompt)
      req.track_name = audio_track_name("doubao", "sfx", req.track_name, req)
    end
    req.format = trim_text(req.format or "wav"):lower()
    if req.format == "" then req.format = "wav" end
    req.resource_id = trim_text(req.resource_id or "")
  elseif req.mode == "vox" then
    req.voice_style = trim_text(req.voice_style or req.style or "")
    req.performance_prompt = trim_text(req.performance_prompt or req.performance or req.tone or req.emotion or "")
    req.performance = req.performance_prompt
    req.spoken_text = trim_text(req.spoken_text or req.text or req.prompt or "")
    req.voice_id = trim_text(req.voice_id or req.voice or "")
    req.gender = tostring(req.gender or infer_audio_gender(req.voice_style) or ""):lower()
    if req.semantic_parse and req.gender ~= "male" and req.gender ~= "female" then
      req.gender = ""
    elseif req.gender ~= "male" and req.gender ~= "female" then
      req.gender = infer_audio_gender(req.voice_style) or "female"
    end
    req.track_name = elevenlabs_track_name("vox", req.track_name, req)
  else
    req.prompt = trim_text(req.prompt or req.description or req.text or "")
    req.track_name = elevenlabs_track_name("sfx", req.track_name, req)
  end

  req.source_text = trim_text(req.source_text or "")
  req.output_dir = trim_text(req.output_dir or "")
  return req
end

function ElevenLabs.request_json(req)
  local provider = normalize_provider(req.provider or req.service or req.vendor or "")
  local parts = {
    "{",
    '"provider":', json_string(provider),
    ',"mode":', json_string(req.mode),
    ',"track_name":', json_string(req.track_name),
    ',"prompt":', json_string(req.prompt or ""),
    ',"text_prompt":', json_string(req.text_prompt or req.prompt or ""),
    ',"speaker":', json_string(req.speaker or ""),
    ',"speaker_name":', json_string(req.speaker_name or ""),
    ',"language":', json_string(req.language or ""),
    ',"accent":', json_string(req.accent or ""),
    ',"speed_ratio":', tostring(tonumber(req.speed_ratio) or 1.0),
    ',"pitch_ratio":', tostring(tonumber(req.pitch_ratio) or 1.0),
    ',"volume_ratio":', tostring(tonumber(req.volume_ratio) or 1.0),
    ',"gender":', json_string(req.gender or ""),
    ',"voice_style":', json_string(req.voice_style or ""),
    ',"performance":', json_string(req.performance or ""),
    ',"performance_prompt":', json_string(req.performance_prompt or req.performance or ""),
    ',"voice_id":', json_string(req.voice_id or ""),
    ',"spoken_text":', json_string(req.spoken_text or ""),
    ',"source_text":', json_string(req.source_text or ""),
    ',"output_dir":', json_string(req.output_dir or ""),
    ',"format":', json_string(req.format or ""),
    ',"resource_id":', json_string(req.resource_id or ""),
    ',"semantic_parse":', (req.semantic_parse and "true" or "false"),
    "}"
  }
  return table.concat(parts)
end

function ElevenLabs.start_message(req)
  local provider = provider_label(req.provider)
  if req.mode == "vox" then
    if req.semantic_parse then
      return "正在用 " .. provider .. " 解析并生成 VOX: " .. tostring(req.source_text or req.spoken_text or "")
    end
    local style = trim_text(((req.gender == "male") and "男声" or "女声") .. " " .. tostring(req.voice_style or "") .. " " .. tostring(req.performance_prompt or req.performance or ""))
    if normalize_provider(req.provider) == "doubao" then
      local speaker = trim_text(req.speaker or "")
      local speaker_name = trim_text(req.speaker_name or "")
      local speaker_label = speaker_name ~= "" and speaker_name or speaker
      local speaker_text = speaker_label ~= "" and ("声线: " .. speaker_label .. "\n") or ""
      local language_text = "语言: " .. doubao_language_label(req.language) .. " / " .. doubao_accent_label(req.language, req.accent) .. "\n"
      return "正在用 " .. provider .. " 生成 VOX: " .. tostring(req.spoken_text or "") .. "\n" .. speaker_text .. language_text .. "提示: " .. tostring(req.text_prompt or "")
    end
    return "正在用 " .. provider .. " 生成 VOX: " .. tostring(req.spoken_text or "") .. "\n声音: " .. style
  end
  if normalize_provider(req.provider) == "doubao" then
    return "正在用 " .. provider .. " 生成 SFX: " .. tostring(req.text_prompt or req.prompt or "")
  end
  return "正在用 " .. provider .. " 生成 SFX: " .. tostring(req.prompt or "")
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
    local track_name = %s
    local wav_path = %s

    local function import_result(ok, message, extra)
      extra = extra or {}
      extra.ok = ok and true or false
      extra.message = tostring(message or "")
      extra.path = wav_path
      extra.track = track_name
      return extra
    end

    local track = nil
    local peak_action_ran = false
    local function reaper_false(value)
      return value == false or value == nil or value == 0
    end

    local function fail_import(message, extra)
      if track and reaper.CountTrackMediaItems and reaper.DeleteTrack and reaper.CountTrackMediaItems(track) == 0 then
        reaper.DeleteTrack(track)
      end
      return import_result(false, message, extra)
    end

    local function select_item_for_peaks(target_item)
      if not target_item then return end
      if reaper.SelectAllMediaItems then reaper.SelectAllMediaItems(0, false) end
      if reaper.SetMediaItemSelected then
        reaper.SetMediaItemSelected(target_item, true)
      elseif reaper.SetMediaItemInfo_Value then
        reaper.SetMediaItemInfo_Value(target_item, "B_UISEL", 1)
      end
      if reaper.GetActiveTake and reaper.SetActiveTake then
        local active_take = reaper.GetActiveTake(target_item)
        if active_take then reaper.SetActiveTake(active_take) end
      end
    end

    local function refresh_item_peaks(target_item)
      if target_item then
        select_item_for_peaks(target_item)
        if reaper.UpdateItemInProject then reaper.UpdateItemInProject(target_item) end
      end
      if reaper.TrackList_AdjustWindows then reaper.TrackList_AdjustWindows(false) end
      if reaper.UpdateTimeline then reaper.UpdateTimeline() end
      if reaper.UpdateArrange then reaper.UpdateArrange() end
      if target_item and reaper.Main_OnCommand then
        reaper.Main_OnCommand(40245, 0) -- Peaks: Build any missing peaks for selected items
        peak_action_ran = true
      end
      if target_item and reaper.UpdateItemInProject then reaper.UpdateItemInProject(target_item) end
      if reaper.UpdateTimeline then reaper.UpdateTimeline() end
      if reaper.UpdateArrange then reaper.UpdateArrange() end
    end

    local before_items = reaper.CountMediaItems(0)
    local insert_index = reaper.CountTracks(0)
    reaper.InsertTrackAtIndex(insert_index, true)
    track = reaper.GetTrack(0, insert_index)
    if not track then
      return fail_import("无法创建导入轨道")
    end

    reaper.GetSetMediaTrackInfo_String(track, "P_NAME", track_name, true)
    reaper.SetOnlyTrackSelected(track)
    if reaper.SetMediaTrackInfo_Value then
      reaper.SetMediaTrackInfo_Value(track, "I_SELECTED", 1)
    end

    local item = nil
    local source = nil
    if reaper.PCM_Source_CreateFromFile then
      source = reaper.PCM_Source_CreateFromFile(wav_path)
    end

    if source then
      local source_len = 0
      if reaper.GetMediaSourceLength then
        local length_value = reaper.GetMediaSourceLength(source)
        source_len = tonumber(length_value) or 0
      end
      if source_len <= 0 then source_len = 1.0 end

      item = reaper.AddMediaItemToTrack(track)
      if not item then
        if source and reaper.PCM_Source_Destroy then reaper.PCM_Source_Destroy(source) end
        return fail_import("无法创建媒体 item")
      end

      local take = reaper.AddTakeToMediaItem(item)
      if not take then
        if source and reaper.PCM_Source_Destroy then reaper.PCM_Source_Destroy(source) end
        if reaper.DeleteTrackMediaItem then reaper.DeleteTrackMediaItem(track, item) end
        return fail_import("无法创建媒体 take")
      end

      reaper.SetMediaItemTake_Source(take, source)
      source = nil
      reaper.SetActiveTake(take)
      reaper.SetMediaItemInfo_Value(item, "D_POSITION", reaper.GetCursorPosition())
      reaper.SetMediaItemInfo_Value(item, "D_LENGTH", source_len)
      reaper.SetMediaItemInfo_Value(item, "B_UISEL", 1)
      if reaper.UpdateItemInProject then reaper.UpdateItemInProject(item) end
    else
      local inserted = reaper.InsertMedia(wav_path, 0)
      if reaper_false(inserted) then
        return fail_import("PCM_Source_CreateFromFile 失败，InsertMedia 也未导入媒体")
      end
      if reaper.GetSelectedMediaItem then
        item = reaper.GetSelectedMediaItem(0, 0)
      end
      if not item and track and reaper.CountTrackMediaItems and reaper.GetTrackMediaItem then
        local track_item_count = reaper.CountTrackMediaItems(track)
        if track_item_count > 0 then
          item = reaper.GetTrackMediaItem(track, track_item_count - 1)
        end
      end
    end

    refresh_item_peaks(item)
    if reaper.UpdateArrange then reaper.UpdateArrange() end

    local after_items = reaper.CountMediaItems(0)
    local track_items = reaper.CountTrackMediaItems(track)
    local added = after_items - before_items
    if added <= 0 then
      return fail_import("导入命令完成，但工程里没有新增 item", {
        items_added = added,
        track_items = track_items,
      })
    end

    local message = "已导入音频"
    if track_items <= 0 then
      message = "已导入音频，但未落在新建轨道"
    end

    return import_result(true, message, {
      items_added = added,
      track_items = track_items,
      track_index = insert_index + 1,
      peaks_built = peak_action_ran,
    })
  ]], lua_string_literal(track_name), lua_string_literal(wav_path))
end

ElevenLabs.trim_text = trim_text
ElevenLabs.normalize_provider = normalize_provider
ElevenLabs.provider_label = provider_label
ElevenLabs.audio_track_name = audio_track_name
ElevenLabs.safe_track_name = safe_track_name
ElevenLabs.elevenlabs_track_name = elevenlabs_track_name
ElevenLabs.utf8_safe_sub = utf8_safe_sub
ElevenLabs.infer_audio_gender = infer_audio_gender
ElevenLabs.free_voices = free_voices
ElevenLabs.voice_by_id = voice_by_id
ElevenLabs.voice_matches_gender = voice_matches_gender
ElevenLabs.voice_options_for_gender = voice_options_for_gender
ElevenLabs.default_voice_id = default_voice_id
ElevenLabs.voice_label = voice_label
ElevenLabs.voice_menu_label = voice_menu_label
ElevenLabs.voice_matches_filter = voice_matches_filter
ElevenLabs.parse_voice_lines = parse_voice_lines
ElevenLabs.doubao_language_options = doubao_language_options
ElevenLabs.doubao_language_label = doubao_language_label
ElevenLabs.doubao_accent_options = doubao_accent_options
ElevenLabs.doubao_default_accent = doubao_default_accent
ElevenLabs.doubao_accent_label = doubao_accent_label
ElevenLabs.normalize_doubao_language = normalize_doubao_language
ElevenLabs.normalize_doubao_accent = normalize_doubao_accent
ElevenLabs.parse_doubao_voice_lines = parse_doubao_voice_lines
ElevenLabs.doubao_voice_by_id = doubao_voice_by_id
ElevenLabs.doubao_voice_options = doubao_voice_options
ElevenLabs.doubao_voice_all_options = doubao_voice_all_options
ElevenLabs.doubao_voice_language_options = doubao_voice_language_options
ElevenLabs.doubao_voice_accent_options = doubao_voice_accent_options
ElevenLabs.doubao_voice_default_language = doubao_voice_default_language
ElevenLabs.doubao_voice_default_accent = doubao_voice_default_accent
ElevenLabs.doubao_voice_supports_language = doubao_voice_supports_language
ElevenLabs.doubao_voice_supports_accent = doubao_voice_supports_accent
ElevenLabs.doubao_voice_label = doubao_voice_label
ElevenLabs.doubao_voice_menu_label = doubao_voice_menu_label
ElevenLabs.doubao_voice_matches_filter = doubao_voice_matches_filter
ElevenLabs.doubao_voice_supports = doubao_voice_supports
ElevenLabs.doubao_voice_supports_control = doubao_voice_supports_control
ElevenLabs.doubao_voice_resource_id = doubao_voice_resource_id

return ElevenLabs
