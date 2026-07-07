local ClarificationResolver = {}

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function lower(value)
  return trim(value):lower()
end

local function contains_any(text, phrases)
  text = lower(text)
  for _, phrase in ipairs(phrases or {}) do
    phrase = lower(phrase)
    if phrase ~= "" and text:find(phrase, 1, true) then
      return true
    end
  end
  return false
end

local function asks_ai_to_choose(answer)
  return contains_any(answer, {
    "随便", "你随便", "你看着", "你决定", "你自己", "自己加", "自己选", "你来",
    "根据你的知识", "按你的知识", "都行", "任选", "随意", "看情况",
    "your choice", "you choose", "anything", "whatever",
  })
end

local function split_values(answer)
  local text = trim(answer)
  local result = {}
  text = text:gsub("，", ","):gsub("、", ","):gsub("|", ","):gsub(";", ",")
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  for line in text:gmatch("[^\n]+") do
    for part in line:gmatch("[^,]+") do
      part = trim(part)
      part = part:gsub("^%d+[%.)、]%s*", "")
      if part ~= "" then table.insert(result, part) end
    end
  end
  if #result == 0 and text ~= "" then table.insert(result, text) end
  return result
end

local function format_value(answer)
  local text = lower(answer)
  local compact = text:gsub("^%.", ""):gsub("[%s_%-%/%(%)]", "")
  local formats = {
    wav = {"wav", "wave"},
    mp3 = {"mp3", "lame"},
    flac = {"flac"},
    ogg = {"ogg", "vorbis", "oggvorbis"},
    opus = {"opus", "oggopus"},
    aiff = {"aiff", "aif", "aifc"},
    caf = {"caf", "caff"},
    raw = {"raw", "pcm", "rawpcm"},
    cue = {"cue", "bin", "cuebin"},
    ddp = {"ddp"},
    wavpack = {"wavpack", "wv"},
    mp4 = {"mp4", "m4v", "mpeg4"},
    wmv = {"wmv", "windowsmedia", "wmf"},
    gif = {"gif"},
    lcf = {"lcf"},
  }
  for key, aliases in pairs(formats) do
    for _, alias in ipairs(aliases) do
      local alias_compact = tostring(alias or ""):gsub("^%.", ""):gsub("[%s_%-%/%(%)]", "")
      if compact == alias_compact or compact:find(alias_compact, 1, true) or text:find(alias, 1, true) then
        return key
      end
    end
  end
  return nil
end

local function is_default_output_dir(answer)
  local text = lower(answer)
  return text == "" or text:find("工程所在", 1, true) or text:find("项目所在", 1, true)
    or text:find("project", 1, true) or text:find("default", 1, true)
end

local function fields(q)
  local result = {}
  for _, field in ipairs((q and q.fields) or {}) do
    local value = lower(field)
    if value ~= "" then table.insert(result, value) end
  end
  return result
end

local function has_field(field_list, names)
  for _, field in ipairs(field_list or {}) do
    for _, name in ipairs(names or {}) do
      if field == name then return true end
    end
  end
  return false
end

local function step_index_set(q)
  local set = {}
  for _, value in ipairs((q and q.step_indices) or {}) do
    local n = tonumber(value)
    if n and n > 0 then set[n] = true end
  end
  return set
end

local function targets_step(Operation, q, step, step_index)
  if not step or step.kind ~= "mcp" then return false end
  local set = step_index_set(q)
  local has_set = false
  for _ in pairs(set) do has_set = true break end
  if has_set then
    return set[step_index] == true
  end

  local explicit_step_index = tonumber((q and q.step_index) or 0) or 0
  if explicit_step_index > 0 then
    return explicit_step_index == step_index
  end

  local target_endpoint = tostring((q and q.endpoint) or "")
  if target_endpoint == "" or target_endpoint == "intent" or target_endpoint == "plan" then
    return step.needs_clarification == true
  end
  local endpoint = step.endpoint or Operation.endpoint(step.call or "")
  return endpoint == target_endpoint
end

local function answer_params(q, answer)
  local params = {}
  local field_list = fields(q)
  local question = lower((q and q.question) or (q and q.reason) or "")
  local fmt = format_value(answer)

  if has_field(field_list, {"format", "export_format", "file_format"}) or
     (#field_list == 0 and fmt and (question:find("format", 1, true) or question:find("格式", 1, true))) then
    params.format = fmt or trim(answer)
  end

  if has_field(field_list, {"output_dir", "output_path", "save_dir", "save_path", "path", "directory"}) then
    if is_default_output_dir(answer) then
      params.output_dir = false
    else
      params.output_dir = trim(answer)
    end
  end

  if has_field(field_list, {"new_name", "name", "target_name"}) then
    params.name = trim(answer)
  end

  if has_field(field_list, {"fx", "fx_name", "effect", "plugin"}) then
    if not asks_ai_to_choose(answer) then
      params.fx = trim(answer)
      params.fx_name = false
    end
  end

  if has_field(field_list, {"target_track", "track", "target_item", "item", "scope", "target"}) then
    local answer_text = trim(answer)
    local answer_lower = lower(answer)
    if answer_lower:find("刚创建", 1, true) or answer_lower:find("新建", 1, true)
      or answer_lower:find("created", 1, true) or answer_lower:find("generated", 1, true) then
      params.target = "created.tracks[1]"
      params.index = false
      params.track = false
    elseif answer_lower:find("选中", 1, true) or answer_lower:find("selected", 1, true) then
      params.selected = "true"
      params.target = false
      params.index = false
      params.track = false
    else
      params.target = answer_text
      params.index = false
    end
  end

  if has_field(field_list, {"action_type", "operation_type"}) then
    params.action_type = trim(answer)
  end

  return params
end

local function apply_params_to_step(Operation, step, q, answer)
  if not step or step.kind ~= "mcp" then return false end
  local endpoint, params = Operation.parse_call(step.call or "")
  if endpoint == "" then return false end
  local patch = answer_params(q, answer)
  local changed = false
  for key, value in pairs(patch) do
    if value == false then
      if params[key] ~= nil then
        params[key] = nil
        changed = true
      end
    elseif value ~= nil and tostring(value) ~= "" then
      params[key] = tostring(value)
      changed = true
    end
  end
  if not changed then return false end
  step.call = Operation.build_call(endpoint, params)
  step.endpoint = endpoint
  step.params = params
  step.status = "pending"
  step.needs_clarification = false
  step.blocked_reason = nil
  step.error = nil
  step.precheck_error = nil
  return true
end

local function step_source_text(step)
  if not step then return "" end
  if step.kind == "mcp" then
    return "[MCP_CALL:" .. tostring(step.call or "") .. "]"
  elseif step.kind == "script" then
    return "[SCRIPT]\n" .. tostring(step.code or "") .. "\n[/SCRIPT]"
  end
  return tostring(step.raw or step.kind or "")
end

local function parts_source_text(parts)
  local lines = {}
  for _, step in ipairs(parts or {}) do
    local text = step_source_text(step)
    if text ~= "" then table.insert(lines, text) end
  end
  return table.concat(lines, "\n")
end

local function looks_like_region_export(text)
  local value = lower(text)
  return (value:find("export", 1, true) or value:find("render", 1, true) or value:find("导出", 1, true) or value:find("渲染", 1, true))
    and (value:find("region", 1, true) or value:find("regions", 1, true))
end

function ClarificationResolver.create(deps)
  deps = deps or {}
  local Operation = deps.Operation
  if not Operation then error("ClarificationResolver requires Operation", 0) end

  local M = {}

  function M.trim(value)
    return trim(value)
  end

  function M.answer_requests_rewrite(answer)
    return asks_ai_to_choose(answer) or contains_any(answer, {
      "重新", "重来", "重做", "重新建", "重新创建", "重新生成",
      "删了", "删除了", "没了", "不存在", "已经不在", "刚才错",
      "不对", "错了", "不是这个", "不要这个", "换成", "改成",
      "redo", "start over", "wrong", "deleted", "missing", "no longer",
    })
  end

  function M.apply_answer_to_plan(op, q, answer)
    local targets = {}
    for i, step in ipairs((op and op.parts) or {}) do
      if targets_step(Operation, q, step, i) then
        table.insert(targets, { index = i, step = step })
      end
    end
    if #targets == 0 then return false end

    local field_list = fields(q)
    local values = split_values(answer)
    local distribute = #values > 1 and #values == #targets and (
      has_field(field_list, {"fx", "fx_name", "effect", "plugin"})
        or has_field(field_list, {"new_name", "name", "target_name"})
    )

    local changed = false
    for target_index, target in ipairs(targets) do
      local value = distribute and values[target_index] or answer
      changed = apply_params_to_step(Operation, target.step, q, value) or changed
    end
    return changed
  end

  function M.parts_source_text(parts)
    return parts_source_text(parts)
  end

  function M.synthesize_operation(op, answer, last_user_request)
    local original = tostring((op and op.user_request) or last_user_request or "")
    local fmt = format_value(answer)
    if fmt and looks_like_region_export(original) then
      local call = Operation.build_call("export/batch_regions", { format = fmt })
      return "[MCP_CALL:" .. call .. "]"
    end
    return nil
  end

  function M.build_llm_message(op, answer, q, mode, last_user_request)
    local original = tostring((op and op.user_request) or last_user_request or "")
    local prompt = tostring((q and q.question) or (op and op.clarification_prompt) or "")
    local options = ""
    if q and q.options and #q.options > 0 then
      options = table.concat(q.options, " / ")
    elseif op and op.clarification_options and #op.clarification_options > 0 then
      options = table.concat(op.clarification_options, " / ")
    end
    local label = mode == "rewrite" and "[REWRITE_PENDING_OPERATION]" or "[USER_CLARIFICATION]"
    local rewrite_note = ""
    if mode == "rewrite" then
      rewrite_note = "\nDiscard the current pending operation card. Regenerate a fresh plan from the current project state and the user's clarification. Do not keep stale targets from the old card unless the user explicitly repeats them.\n"
    end
    local msg = original .. "\n\n[CLARIFICATION_QUESTION]\n" .. prompt .. "\n" .. options .. rewrite_note .. "\n\n" .. label .. "\n" .. tostring(answer or "")
    local effective = trim(original .. "\n" .. tostring(answer or ""))
    return msg, effective
  end

  return M
end

return ClarificationResolver
