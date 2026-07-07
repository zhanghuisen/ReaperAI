local Operation = {}
local PlanContract = nil

local function operation_new_id()
  return "op_" .. tostring(math.floor((reaper.time_precise() or os.clock()) * 1000)) .. "_" .. tostring(math.random(1000, 9999))
end

local function count_script_blocks(text)
  local count = 0
  local pos = 1
  while pos <= #text do
    local start = text:find("[SCRIPT]", pos, true)
    if not start then break end
    count = count + 1
    local finish = text:find("[/SCRIPT]", start, true)
    pos = finish and (finish + 9) or (#text + 1)
  end
  return count
end

local function operation_trim_script_block(block)
  block = tostring(block or "")
  block = block:gsub("^%s*\n", ""):gsub("\n%s*$", "")
  return block
end

local function operation_repair_mcp_orphan_params(text)
  text = tostring(text or "")
  local changed = true
  while changed do
    local count = 0
    text = text:gsub("(%[MCP_CALL:[^%]\r\n]-)%](&[%w_]+=[^%]%[\r\n]+)%]", function(prefix, suffix)
      count = count + 1
      return prefix .. suffix .. "]"
    end)
    changed = count > 0
  end
  return text
end

local function operation_parse_executable_steps(text, validate_script_step)
  local steps = {}
  local pos = 1
  text = tostring(text or "")
  text = operation_repair_mcp_orphan_params(text)
  
  while pos <= #text do
    local mcp_start = text:find("[MCP_CALL:", pos, true)
    local script_start = text:find("[SCRIPT]", pos, true)
    
    if not mcp_start and not script_start then
      break
    end
    
    if mcp_start and (not script_start or mcp_start < script_start) then
      local mcp_end = text:find("]", mcp_start + 10, true)
      if not mcp_end then
        break
      end
      local call_str = text:sub(mcp_start + 10, mcp_end - 1)
      call_str = call_str:gsub("^%s+", ""):gsub("%s+$", "")
      if call_str ~= "" then
        table.insert(steps, {
          id = "step_" .. tostring(#steps + 1),
          kind = "mcp",
          type = "mcp",
          source = "ai",
          call = call_str,
          raw = text:sub(mcp_start, mcp_end),
          status = "pending",
          risk = "low",
          blocked_reason = nil,
          precheck_error = nil,
          runtime_error = nil,
        })
      end
      pos = mcp_end + 1
    else
      local finish = text:find("[/SCRIPT]", script_start, true)
      local block
      local raw_end
      local parse_warning = nil
      if finish then
        block = operation_trim_script_block(text:sub(script_start + 8, finish - 1))
        raw_end = finish + 8
        pos = finish + 9
      else
        block = operation_trim_script_block(text:sub(script_start + 8))
        raw_end = #text
        pos = #text + 1
        parse_warning = "SCRIPT 未闭合，已阻断执行"
      end
      
      if block and #block > 0 then
        local valid, validation_error = true, nil
        if parse_warning then
          valid, validation_error = false, parse_warning .. "：缺少 [/SCRIPT]"
        elseif validate_script_step then
          valid, validation_error = validate_script_step(block)
        end
        table.insert(steps, {
          id = "step_" .. tostring(#steps + 1),
          kind = "script",
          type = "script",
          source = "ai",
          code = block,
          raw = text:sub(script_start, raw_end or #text),
          parse_warning = parse_warning,
          valid = valid,
          validation_error = validation_error,
          status = valid and "pending" or "blocked",
          risk = "medium",
          blocked_reason = valid and nil or validation_error,
          precheck_error = valid and nil or validation_error,
          runtime_error = nil,
        })
      elseif parse_warning then
        table.insert(steps, {
          id = "step_" .. tostring(#steps + 1),
          kind = "script",
          type = "script",
          source = "ai",
          code = "",
          raw = text:sub(script_start, raw_end or #text),
          parse_warning = parse_warning,
          valid = false,
          validation_error = parse_warning .. "：缺少 [/SCRIPT]",
          status = "blocked",
          risk = "medium",
          blocked_reason = parse_warning .. "：缺少 [/SCRIPT]",
          precheck_error = parse_warning .. "：缺少 [/SCRIPT]",
          runtime_error = nil,
        })
      end
    end
  end
  
  return steps
end

local function operation_count_steps_by_kind(steps, kind)
  local count = 0
  for _, step in ipairs(steps or {}) do
    if step.kind == kind then
      count = count + 1
    end
  end
  return count
end

local function operation_preflight_execution_steps(steps)
  local total_script = operation_count_steps_by_kind(steps, "script")
  local script_index = 0
  
  for step_index, step in ipairs(steps or {}) do
    if step.kind == "script" then
      script_index = script_index + 1
      if step.valid == false then
        step.status = "blocked"
        step.error = tostring(step.validation_error or "SCRIPT 校验失败")
        step.precheck_error = step.error
        step.blocked_reason = step.error
        return false, "✗ [预检 Step " .. step_index .. " SCRIPT " .. script_index .. "/" .. total_script .. "] " .. step.error
      end
    elseif step.kind ~= "mcp" then
      step.status = "blocked"
      step.error = "未知 step 类型: " .. tostring(step.kind)
      step.precheck_error = step.error
      step.blocked_reason = step.error
      return false, "⚠️ [预检 Step " .. step_index .. "] " .. step.error
    end
  end
  
  return true, nil
end

local function operation_endpoint(call)
  local endpoint = tostring(call or ""):match("^([^%?]+)") or tostring(call or "")
  return endpoint:gsub("^%s+", ""):gsub("%s+$", "")
end

local function operation_url_decode(s)
  s = tostring(s or "")
  s = s:gsub("+", " ")
  s = s:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16) or 0)
  end)
  return s
end

local function operation_parse_call(call)
  local endpoint, param_str = tostring(call or ""):match("^([^%?]+)%?(.+)$")
  if not endpoint then
    endpoint = tostring(call or "")
    param_str = ""
  end
  endpoint = operation_endpoint(endpoint)
  local params = {}
  for k, v in tostring(param_str or ""):gmatch("([^&=]+)=([^&]*)") do
    params[operation_url_decode(k)] = operation_url_decode(v)
  end
  return endpoint, params
end

local function operation_bool_param(value)
  local v = tostring(value or ""):lower()
  return v == "true" or v == "1" or v == "yes" or v == "on"
end

local function operation_has_value(params, keys)
  params = params or {}
  for _, key in ipairs(keys or {}) do
    local value = params[key]
    if value ~= nil and tostring(value) ~= "" then
      return true, key
    end
  end
  return false, nil
end

local function operation_split_lua_args(args)
  args = tostring(args or "")
  local result = {}
  local current = {}
  local depth = 0
  local quote = nil
  local i = 1
  while i <= #args do
    local c = args:sub(i, i)
    if quote then
      table.insert(current, c)
      if c == "\\" then
        i = i + 1
        if i <= #args then table.insert(current, args:sub(i, i)) end
      elseif c == quote then
        quote = nil
      end
    elseif c == "'" or c == '"' then
      quote = c
      table.insert(current, c)
    elseif c == "(" or c == "{" or c == "[" then
      depth = depth + 1
      table.insert(current, c)
    elseif c == ")" or c == "}" or c == "]" then
      depth = math.max(0, depth - 1)
      table.insert(current, c)
    elseif c == "," and depth == 0 then
      local value = table.concat(current):gsub("^%s+", ""):gsub("%s+$", "")
      table.insert(result, value)
      current = {}
    else
      table.insert(current, c)
    end
    i = i + 1
  end
  local last = table.concat(current):gsub("^%s+", ""):gsub("%s+$", "")
  if last ~= "" or #result > 0 then table.insert(result, last) end
  return result
end

local function operation_main_on_command_ids(code)
  code = tostring(code or "")
  local found = {}
  local patterns = {
    "reaper%s*%.%s*Main_OnCommand%s*%(",
    "%f[%w_]Main_OnCommand%s*%(",
  }
  local search_pos = 1
  while search_pos <= #code do
    local best_s, best_e = nil, nil
    for _, pattern in ipairs(patterns) do
      local s, e = code:find(pattern, search_pos)
      if s and (not best_s or s < best_s) then
        best_s, best_e = s, e
      end
    end
    if not best_s then break end
    local i = best_e + 1
    local depth = 1
    local args = {}
    while i <= #code and depth > 0 do
      local c = code:sub(i, i)
      if c == "(" then
        depth = depth + 1
        table.insert(args, c)
      elseif c == ")" then
        depth = depth - 1
        if depth > 0 then table.insert(args, c) end
      else
        table.insert(args, c)
      end
      i = i + 1
    end
    local parsed = operation_split_lua_args(table.concat(args))
    local first = (#parsed > 0) and parsed[1] or ""
    local action_id = tostring(first or ""):match("^%-?%d+$") and tostring(first) or nil
    table.insert(found, { raw = first, id = action_id })
    search_pos = math.max(i, best_e + 1)
  end
  return found
end

local function operation_native_action_meta(action_id)
  if Operation.native_action_entry and action_id then
    return Operation.native_action_entry(action_id)
  end
  return nil
end

local function operation_merge_native_action_effects(script_effects, native)
  if not native then return script_effects end
  script_effects = script_effects or {}
  for key, value in pairs(native.effects or {}) do
    if value then script_effects[key] = true end
  end
  local risk = tostring(native.risk or "")
  if risk == "destructive" then
    script_effects.modifies_project = true
    script_effects.deletes_project = true
  elseif risk == "writes_disk" or risk == "recording" then
    script_effects.modifies_project = true
    script_effects.writes_disk = true
  elseif risk == "toggle_state" or risk == "edit" then
    script_effects.modifies_project = true
  elseif risk == "selection" then
    script_effects.changes_selection = true
  elseif risk == "ui" then
    script_effects.changes_ui = true
  end
  return script_effects
end

local function operation_text_has_any(text, tokens)
  local haystack = tostring(text or ""):lower()
  for _, token in ipairs(tokens or {}) do
    token = tostring(token or "")
    if token ~= "" and haystack:find(token:lower(), 1, true) then
      return true, token
    end
  end
  return false, nil
end

local function operation_strip_script_blocks(text)
  text = tostring(text or "")
  local result = {}
  local pos = 1
  while pos <= #text do
    local start = text:find("[SCRIPT]", pos, true)
    if not start then
      table.insert(result, text:sub(pos))
      break
    end
    table.insert(result, text:sub(pos, start - 1))
    local finish = text:find("[/SCRIPT]", start, true)
    if not finish then
      break
    end
    pos = finish + 9
  end
  return table.concat(result)
end

local function operation_sanitize_user_goal_text(text)
  text = tostring(text or "")
  text = operation_strip_script_blocks(text)
  text = text:gsub("```.-```", " ")
  text = text:gsub("%[MCP_CALL:[^%]]*%]", " ")
  text = text:gsub("%f[%w_][%w_]+/[%%w_%-]+%?[^%s，。；;、]*", " ")
  text = text:gsub("%f[%w_]reaper%.[%w_]+%s*%b()", " ")
  return text
end

local function operation_detect_forbidden_actions(raw_text, goal_text)
  raw_text = tostring(raw_text or "")
  goal_text = tostring(goal_text or "")
  local lower = raw_text:lower()
  local clean_lower = goal_text:lower()
  local forbidden = {
    delete_project = false,
    clear_project = false,
    delete_disk = false,
    overwrite = false,
    export_file = false,
    write_file = false,
  }

  local function has_any(text, tokens)
    for _, token in ipairs(tokens or {}) do
      token = tostring(token or ""):lower()
      if token ~= "" and text:find(token, 1, true) then return true end
    end
    return false
  end

  local neg_delete = {
    "不要删除", "别删除", "不能删除", "不删除", "不要删", "别删", "不能删", "不删",
    "不要移除", "别移除", "不能移除", "不移除", "不要清空", "别清空", "不能清空", "不清空",
    "不要清除", "别清除", "不能清除", "不清除", "不要清理", "别清理", "不能清理", "不清理",
    "do not delete", "don't delete", "dont delete", "no delete", "without deleting",
    "do not remove", "don't remove", "dont remove", "no remove", "without removing",
    "do not clear", "don't clear", "dont clear", "no clear", "without clearing",
  }
  local neg_disk_delete = {
    "不要删除文件", "别删除文件", "不能删除文件", "不要删文件", "别删文件",
    "不要删除硬盘", "不要删除磁盘", "不要删原始音频", "不要删除原始音频",
    "do not delete files", "don't delete files", "dont delete files", "without deleting files",
  }
  local neg_overwrite = {
    "不要覆盖", "别覆盖", "不能覆盖", "不覆盖",
    "do not overwrite", "don't overwrite", "dont overwrite", "no overwrite", "without overwriting",
  }
  local neg_export = {
    "不要导出", "别导出", "不能导出", "不导出", "不要渲染", "别渲染", "不能渲染", "不渲染",
    "do not export", "don't export", "dont export", "no export",
    "do not render", "don't render", "dont render", "no render",
  }
  local neg_write = {
    "不要写文件", "别写文件", "不能写文件", "不要保存", "别保存", "不能保存", "不保存",
    "do not write", "don't write", "dont write", "do not save", "don't save", "dont save",
  }

  if has_any(lower, neg_delete) or has_any(clean_lower, neg_delete) then
    forbidden.delete_project = true
    forbidden.clear_project = true
  end
  if has_any(lower, neg_disk_delete) or has_any(clean_lower, neg_disk_delete) then
    forbidden.delete_disk = true
  end
  if has_any(lower, neg_overwrite) or has_any(clean_lower, neg_overwrite) then
    forbidden.overwrite = true
    forbidden.write_file = true
  end
  if has_any(lower, neg_export) or has_any(clean_lower, neg_export) then
    forbidden.export_file = true
  end
  if has_any(lower, neg_write) or has_any(clean_lower, neg_write) then
    forbidden.write_file = true
  end

  return forbidden
end

local function operation_build_intent_contract(user_text)
  local raw_text = tostring(user_text or "")
  local goal_text = operation_sanitize_user_goal_text(raw_text)
  local forbidden = operation_detect_forbidden_actions(raw_text, goal_text)
  return {
    raw_text = raw_text,
    goal_text = goal_text,
    forbidden = forbidden,
  }
end

local ACTION_REGISTRY = {
  ["transport/play"] = { action = "play", target = "transport", label = "播放工程", effects = { read_only = true }, verifier_strength = "observed" },
  ["transport/stop"] = { action = "stop", target = "transport", label = "停止播放", effects = { read_only = true }, verifier_strength = "observed" },
  ["track/create"] = { action = "create", target = "track", label = "创建轨道", effects = { modifies_project = true }, verifier = "track/create", verifier_strength = "strong" },
  ["track/delete"] = { action = "delete", target = "track", label = "删除轨道", effects = { modifies_project = true, deletes_project = true }, verifier = "track/delete", verifier_strength = "strong" },
  ["track/rename"] = { action = "rename", target = "track", label = "重命名轨道", effects = { modifies_project = true }, verifier = "track/rename", verifier_strength = "strong" },
  ["track/set_volume"] = { action = "edit", target = "track", label = "设置轨道音量", effects = { modifies_project = true }, verifier = "track/property", verifier_strength = "weak" },
  ["track/set_volume_by_name"] = { action = "edit", target = "track", label = "按名称设置轨道音量", effects = { modifies_project = true }, verifier = "track/property", verifier_strength = "weak" },
  ["track/set_pan"] = { action = "edit", target = "track", label = "设置轨道声像", effects = { modifies_project = true }, verifier = "track/property", verifier_strength = "weak" },
  ["track/set_color"] = { action = "edit", target = "track", label = "设置轨道颜色", effects = { modifies_project = true }, verifier = "track/property", verifier_strength = "weak" },
  ["track/mute"] = { action = "edit", target = "track", label = "设置轨道静音", effects = { modifies_project = true }, verifier = "track/property", verifier_strength = "weak" },
  ["track/solo"] = { action = "edit", target = "track", label = "设置轨道独奏", effects = { modifies_project = true }, verifier = "track/property", verifier_strength = "weak" },
  ["track/add_fx"] = { action = "edit", target = "fx", label = "添加 FX", effects = { modifies_project = true }, verifier = "fx/add", verifier_strength = "strong" },
  ["track/remove_fx"] = { action = "delete", target = "fx", label = "移除 FX", effects = { modifies_project = true, deletes_project = true }, verifier = "fx/remove", verifier_strength = "strong" },
  ["track/group_into_folder"] = { action = "edit", target = "track", label = "轨道归入文件夹", effects = { modifies_project = true, batch = true }, verifier = "track/create", verifier_strength = "weak" },
  ["track/create_folder"] = { action = "edit", target = "track", label = "轨道归入文件夹", effects = { modifies_project = true, batch = true }, verifier = "track/create", verifier_strength = "weak" },
  ["marker/add"] = { action = "create", target = "marker", label = "添加 Marker", effects = { modifies_project = true }, verifier = "marker/add", verifier_strength = "strong" },
  ["marker/delete"] = { action = "delete", target = "marker", label = "删除 Marker", effects = { modifies_project = true, deletes_project = true }, verifier = "marker/delete", verifier_strength = "strong" },
  ["item/fade"] = { action = "edit", target = "item", label = "设置素材 Fade", effects = { modifies_project = true }, verifier = "item/property", verifier_strength = "weak" },
  ["item/set_fade"] = { action = "edit", target = "item", label = "设置素材 Fade", effects = { modifies_project = true }, verifier = "item/property", verifier_strength = "weak" },
  ["item/fade_shape"] = { action = "edit", target = "item", label = "设置素材 Fade 曲线", effects = { modifies_project = true }, verifier = "item/property", verifier_strength = "weak" },
  ["item/set_fade_shape"] = { action = "edit", target = "item", label = "设置素材 Fade 曲线", effects = { modifies_project = true }, verifier = "item/property", verifier_strength = "weak" },
  ["envelope/draw"] = { action = "edit", target = "envelope", label = "绘制包络", effects = { modifies_project = true }, verifier_strength = "observed" },
  ["envelope/clear"] = { action = "delete", target = "envelope", label = "清理包络点", effects = { modifies_project = true, clears_project = true }, verifier_strength = "observed" },
  ["region/batch_rename"] = { action = "rename", target = "region", label = "批量重命名 Region", effects = { modifies_project = true, batch = true }, verifier = "region/rename", verifier_strength = "weak" },
  ["sfx/generate_variants"] = { action = "create", target = "item", label = "生成音效变体", effects = { modifies_project = true, batch = true }, verifier = "item/create", verifier_strength = "weak" },
  ["analysis/detect_peaks"] = { action = "query", target = "analysis", label = "检测峰值", effects = { read_only = true }, verifier_strength = "observed" },
  ["analysis/find_loop_points"] = { action = "analyze", target = "analysis", label = "分析循环点", effects = { read_only = true, changes_time_selection = true, moves_cursor = true, analysis_side_effect = true }, verifier_strength = "observed" },
  ["export/batch_regions"] = { action = "export", target = "file", label = "批量导出 Region", effects = { exports_file = true, writes_disk = true, batch = true }, verifier = "file/export", verifier_strength = "observed" },
  ["export/tracks"] = { action = "export", target = "file", label = "导出轨道 Stems", effects = { exports_file = true, writes_disk = true, batch = true }, verifier = "file/export", verifier_strength = "observed" },
  ["export/master"] = { action = "export", target = "file", label = "导出主控混音", effects = { exports_file = true, writes_disk = true }, verifier = "file/export", verifier_strength = "observed" },
  ["native/action"] = { action = "native_action", target = "native_action", label = "执行本机 REAPER Action", effects = { modifies_project = true }, verifier_strength = "observed", source = "native_action_gate" },
  ["endpoints"] = { action = "query", target = "system", label = "查询可用 MCP 能力", effects = { read_only = true }, verifier_strength = "observed" },
}

ACTION_REGISTRY["region/delete"] = { action = "delete", target = "region", label = "Delete Region", effects = { modifies_project = true, deletes_project = true }, verifier = "region/delete", verifier_strength = "strong" }

local function operation_action_registry(endpoint)
  local registry = rawget(_G, "reaperai_capability_registry")
  if registry and type(registry.endpoint_meta) == "function" then
    local meta = registry.endpoint_meta(endpoint)
    if meta then return meta end
  end
  return ACTION_REGISTRY[endpoint]
end

local function operation_set_capability_registry(registry)
  rawset(_G, "reaperai_capability_registry", registry)
end

local function operation_action_contract(endpoint)
  local meta = operation_action_registry(endpoint)
  if not meta then return nil end
  return {
    endpoint = endpoint,
    action = meta.action or "custom",
    target = meta.target or "unknown",
    label = meta.label or endpoint,
    effects = meta.effects or {},
    verifier = meta.verifier,
    verifier_strength = meta.verifier_strength or (meta.verifier and "strong" or "observed"),
    allowed_in_script = meta.allowed_in_script == true,
    source = meta.source or "mcp_registry",
  }
end

local function operation_known_mcp_endpoint(endpoint)
  local registry = rawget(_G, "reaperai_capability_registry")
  if registry and type(registry.known_mcp_endpoint) == "function" then
    local known = registry.known_mcp_endpoint(endpoint)
    if known ~= nil then return known end
  end
  return ACTION_REGISTRY[endpoint] ~= nil
end

local function operation_add_unique(list, text)
  text = tostring(text or "")
  if text == "" then return end
  for _, item in ipairs(list or {}) do
    if item == text then return end
  end
  table.insert(list, text)
end

local function operation_raise_risk(current, level)
  local rank = {low = 1, medium = 2, high = 3, blocked = 4}
  current = current or "low"
  level = level or "low"
  return (rank[level] or 1) > (rank[current] or 1) and level or current
end

local function operation_target_text(params)
  local p = params or {}
  if tostring(p.selected or ""):lower() == "true" then return "selected=true" end
  if p.name and p.name ~= "" then return "name=" .. p.name end
  if p.track_name and p.track_name ~= "" then return "track_name=" .. p.track_name end
  if p.target and p.target ~= "" then return "target=" .. p.target end
  if p.track and p.track ~= "" then return "track=" .. p.track end
  if p.item and p.item ~= "" then return "item=" .. p.item end
  if p.match and p.match ~= "" then return "match=" .. p.match end
  if p.contains and p.contains ~= "" then return "contains=" .. p.contains end
  if p.keyword and p.keyword ~= "" then return "keyword=" .. p.keyword end
  if p.region and p.region ~= "" then return "region=" .. p.region end
  if p.range and p.range ~= "" then return "range=" .. p.range end
  if p.ids and p.ids ~= "" then return "ids=" .. p.ids end
  if p.order_range and p.order_range ~= "" then return "timeline_order=" .. p.order_range end
  if p.ordinal_range and p.ordinal_range ~= "" then return "timeline_order=" .. p.ordinal_range end
  if p.sequence_range and p.sequence_range ~= "" then return "timeline_order=" .. p.sequence_range end
  if p.order_start and p.order_start ~= "" and p.order_end and p.order_end ~= "" then return "timeline_order=" .. p.order_start .. "-" .. p.order_end end
  if p.ordinal_start and p.ordinal_start ~= "" and p.ordinal_end and p.ordinal_end ~= "" then return "timeline_order=" .. p.ordinal_start .. "-" .. p.ordinal_end end
  if p.sequence_start and p.sequence_start ~= "" and p.sequence_end and p.sequence_end ~= "" then return "timeline_order=" .. p.sequence_start .. "-" .. p.sequence_end end
  if p.start and p.start ~= "" and p["end"] and p["end"] ~= "" then return "range=" .. p.start .. "-" .. p["end"] end
  if p.index and p.index ~= "" then return "index=" .. p.index end
  if p.count and p.count ~= "" then return "count=" .. p.count end
  return nil
end

local function operation_context_scope_lines()
  local lines = {}
  if reaper and reaper.CountSelectedTracks then
    local selected_tracks = reaper.CountSelectedTracks(0) or 0
    if selected_tracks > 0 then
      table.insert(lines, "当前选中轨道: " .. tostring(selected_tracks))
    end
  end
  if reaper and reaper.CountSelectedMediaItems then
    local selected_items = reaper.CountSelectedMediaItems(0) or 0
    if selected_items > 0 then
      table.insert(lines, "当前选中素材: " .. tostring(selected_items))
    end
  end
  if reaper and reaper.GetSet_LoopTimeRange then
    local a, b = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
    if b and a and b > a then
      table.insert(lines, string.format("当前时间选区: %.3fs - %.3fs", a, b))
    end
  end
  return lines
end

local function operation_mcp_risk(endpoint, params, reasons, scopes)
  local risk = "low"
  local high = {
    ["track/delete"] = "删除轨道",
    ["marker/delete"] = "删除 Marker",
    ["envelope/clear"] = "清理包络点",
    ["region/batch_rename"] = "批量重命名 Region",
    ["export/batch_regions"] = "批量导出外部文件",
    ["export/tracks"] = "导出轨道外部文件",
    ["export/master"] = "导出主控外部文件",
  }
  high["region/delete"] = "Delete Region"
  local medium = {
    ["track/create"] = "创建轨道",
    ["track/rename"] = "重命名轨道",
    ["track/add_fx"] = "添加 FX",
    ["track/remove_fx"] = "移除 FX",
    ["track/group_into_folder"] = "移动轨道到文件夹",
    ["track/create_folder"] = "移动轨道到文件夹",
    ["item/fade"] = "修改素材 fade 属性",
    ["item/set_fade"] = "修改素材 fade 属性",
    ["item/fade_shape"] = "修改素材 fade 曲线形状",
    ["item/set_fade_shape"] = "修改素材 fade 曲线形状",
    ["envelope/draw"] = "写入包络点",
    ["sfx/generate_variants"] = "生成音效变体",
    ["analysis/find_loop_points"] = "分析并设置循环区间",
  }
  
  if high[endpoint] then
    risk = "high"
    operation_add_unique(reasons, high[endpoint])
  elseif medium[endpoint] then
    risk = "medium"
    operation_add_unique(reasons, medium[endpoint])
  end
  
  local p = params or {}
  local target = operation_target_text(p)
  if target then
    table.insert(scopes, endpoint .. " -> " .. target)
  else
    table.insert(scopes, endpoint)
  end
  
  local count = tonumber(p.count or p.variants or p.variant_count or "")
  if count and count > 5 then
    risk = operation_raise_risk(risk, "medium")
    operation_add_unique(reasons, "操作数量较多: " .. tostring(count))
  end
  if p.match or p.contains or p.keyword or tostring(p.all or ""):lower() == "true" then
    risk = operation_raise_risk(risk, "medium")
    operation_add_unique(reasons, "使用批量/模糊匹配目标")
  end
  if tostring(p.selected or ""):lower() == "true" then
    operation_add_unique(reasons, "目标依赖当前选中对象")
  end
  
  return risk
end

local function operation_script_risk(code, reasons, scopes)
  code = tostring(code or "")
  local risk = "medium"
  table.insert(scopes, "SCRIPT -> 运行时校验")
  local native_found = false

  for _, command in ipairs(operation_main_on_command_ids(code)) do
    native_found = true
    if command.id then
      local native = operation_native_action_meta(command.id)
      local label = native and (native.name or native.label or native.command_name) or ("Action ID " .. tostring(command.id))
      local native_risk = native and tostring(native.risk or "") or "unknown"
      operation_add_unique(reasons, "本机 Action: " .. tostring(label))
      table.insert(scopes, "Native Action " .. tostring(command.id) .. " -> " .. tostring(label))
      if native_risk == "destructive" then
        risk = operation_raise_risk(risk, "high")
      elseif native_risk == "writes_disk" or native_risk == "recording" or native_risk == "toggle_state" then
        risk = operation_raise_risk(risk, "medium")
      end
    else
      risk = operation_raise_risk(risk, "blocked")
      operation_add_unique(reasons, "Native Action 参数无法静态验证")
      table.insert(scopes, "Native Action -> " .. tostring(command.raw or "dynamic"))
    end
  end
  
  if code:match("DeleteTrackMediaItem") or code:match("DeleteTrack%s*%(") or code:match("DeleteProjectMarker") or
     code:match("TrackFX_Delete%s*%(") or code:match("DeleteEnvelopePoint") then
    risk = "high"
    operation_add_unique(reasons, "SCRIPT 包含删除/清理 API")
  elseif code:match("RenderProject") or code:match("Main_SaveProject") or code:match("io%s*%.") or code:match("os%s*%.") then
    risk = "high"
    operation_add_unique(reasons, "SCRIPT 可能写文件或触发渲染/保存")
  elseif code:match("SetProjectMarker") then
    risk = "high"
    operation_add_unique(reasons, "SCRIPT 修改 Marker/Region")
  elseif code:match("InsertTrackAtIndex%s*%(") or code:match("AddProjectMarker2%s*%(") or code:match("AddProjectMarker%s*%(") or
         code:match("InsertMedia%s*%(") or code:match("InsertMediaSection%s*%(") or code:match("AddMediaItemToTrack%s*%(") or
         code:match("TrackFX_AddByName%s*%(") then
    risk = "medium"
    operation_add_unique(reasons, "SCRIPT creates/adds project objects and will be runtime-verified")
  elseif code:match("SetMediaItemInfo_Value") or code:match("SplitMediaItem") then
    risk = "medium"
    operation_add_unique(reasons, "SCRIPT 修改素材")
  elseif code:match("SetMediaTrackInfo_Value") or code:match("GetSetMediaTrackInfo_String") then
    risk = "medium"
    operation_add_unique(reasons, "SCRIPT 修改轨道属性")
  elseif code:match("SetOnlyTrackSelected") or code:match("SetTrackSelected") or code:match("SetMediaItemSelected") then
    risk = "low"
    operation_add_unique(reasons, "SCRIPT 主要改变选择状态")
  else
    operation_add_unique(reasons, native_found and "包含本机 Action，需通过 Action Gate 确认" or "包含 Stable SCRIPT，需运行时验证")
  end
  
  if code:match("CountTracks%s*%(") or code:match("CountMediaItems%s*%(") or code:match("CountProjectMarkers%s*%(") then
    risk = operation_raise_risk(risk, "medium")
    operation_add_unique(reasons, "SCRIPT 扫描工程对象")
  end
  if code:match("GetTrack%s*%(%s*0%s*,%s*%d+") then
    risk = operation_raise_risk(risk, "medium")
    operation_add_unique(reasons, "SCRIPT 使用固定轨道索引")
  end
  
  return risk
end


local function operation_normalize_llm_intent(value)
  local v = tostring(value or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  if v == "" then return "" end
  if v == "delete" or v == "remove" or v == "clear" then return "delete" end
  if v == "rename" or v == "name" or v == "prefix" or v == "suffix" then return "rename" end
  if v == "export" or v == "render" or v == "bounce" or v == "save" or v == "save_file" then return "export" end
  if v == "query" or v == "read" or v == "view" or v == "inspect" or v == "info" or v == "analyze" or v == "analyse" then return "query" end
  if v == "create" or v == "add" or v == "generate" or v == "insert" or v == "duplicate" or v == "copy" then return "create" end
  if v == "edit" or v == "set" or v == "adjust" or v == "process" or v == "move" or v == "trim" or v == "split" or v == "fade" or v == "route" or v == "mute" or v == "solo" or v == "volume" or v == "pan" or v == "color" then return "edit" end
  if v == "freeze" or v == "unfreeze" or v == "glue" then return "freeze" end
  if v == "unknown" or v == "uncertain" or v == "clarify" then return "unknown" end
  return "unknown"
end

local function operation_normalize_confidence(value)
  local v = tostring(value or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  if v == "high" or v == "medium" or v == "low" then return v end
  local n = tonumber(v)
  if n then
    if n >= 0.75 then return "high" end
    if n >= 0.45 then return "medium" end
    return "low"
  end
  return "low"
end

local function operation_parse_bool_text(value)
  local v = tostring(value or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  return v == "true" or v == "1" or v == "yes" or v == "y" or v == "on"
end

local function operation_split_options(value)
  value = tostring(value or "")
  local result = {}
  value = value:gsub("\239\188\140", ","):gsub("|", ","):gsub(";", ",")
  for part in value:gmatch("[^,]+") do
    part = part:gsub("^%s+", ""):gsub("%s+$", "")
    if part ~= "" then table.insert(result, part) end
  end
  return result
end

local function operation_is_export_format_context(question, fields, intent_name)
  local text = tostring(question or ""):lower()
  local intent = tostring(intent_name or ""):lower()
  if intent == "export" then return true end
  if text:find("export", 1, true) or text:find("render", 1, true) or text:find("format", 1, true) then return true end
  if tostring(question or ""):find("导出", 1, true) or tostring(question or ""):find("渲染", 1, true) or tostring(question or ""):find("格式", 1, true) then return true end
  for _, field in ipairs(fields or {}) do
    local f = tostring(field or ""):lower()
    if f == "format" or f == "export_format" or f == "file_format" then return true end
  end
  return false
end

local function operation_supported_export_options()
  return {
    "WAV",
    "MP3",
    "FLAC",
    "OGG"
  }
end

local EXPORT_RENDER_FORMATS = {
  wav = { label = "WAV", aliases = {"wave"} },
  aiff = { label = "AIFF", aliases = {"aif", "aifc"} },
  caf = { label = "CAF", aliases = {"caff"} },
  flac = { label = "FLAC", aliases = {} },
  mp3 = { label = "MP3", aliases = {"lame"} },
  ogg = { label = "OGG Vorbis", aliases = {"vorbis", "ogg_vorbis"} },
  opus = { label = "OGG Opus", aliases = {"ogg_opus"} },
  raw = { label = "Raw PCM", aliases = {"pcm", "raw_pcm"} },
  cue = { label = "CUE/BIN", aliases = {"bin", "cuebin", "audio_cd"} },
  ddp = { label = "DDP", aliases = {} },
  wavpack = { label = "WavPack", aliases = {"wv"} },
  mp4 = { label = "MP4 / MPEG-4", aliases = {"m4v", "mpeg4", "mpeg-4", "video_mp4"} },
  wmv = { label = "Windows Media", aliases = {"windows_media", "wmf"} },
  gif = { label = "GIF", aliases = {} },
  lcf = { label = "LCF", aliases = {} },
}

local function operation_export_format_token(value)
  value = tostring(value or ""):lower():gsub("^%.", "")
  value = value:gsub("[%s_%-%/%(%)]", "")
  return value
end

local function operation_export_format_key(value)
  local token = operation_export_format_token(value)
  if token == "" then return "" end
  for key, info in pairs(EXPORT_RENDER_FORMATS) do
    local key_token = operation_export_format_token(key)
    if token == key_token or token:find(key_token, 1, true) then return key end
    for _, alias in ipairs(info.aliases or {}) do
      local alias_token = operation_export_format_token(alias)
      if alias_token ~= "" and (token == alias_token or token:find(alias_token, 1, true)) then return key end
    end
  end
  return ""
end

local function operation_export_format_supported(value)
  return operation_export_format_key(value) ~= ""
end

local function operation_option_mentions_export_format(option)
  local text = tostring(option or "")
  local lower = text:lower()
  if text == "" then return false, "" end
  for key, info in pairs(EXPORT_RENDER_FORMATS) do
    if lower:find(key, 1, true) then return true, key end
    if info.label and lower:find(tostring(info.label):lower(), 1, true) then return true, key end
    for _, alias in ipairs(info.aliases or {}) do
      if alias ~= "" and lower:find(tostring(alias):lower(), 1, true) then
        return true, key
      end
    end
  end
  return false, ""
end

local function operation_split_notes(value)
  value = tostring(value or "")
  local result = {}
  value = value:gsub("\239\188\155", "|")
  for part in value:gmatch("[^|]+") do
    part = part:gsub("^%s+", ""):gsub("%s+$", "")
    if part ~= "" then table.insert(result, part) end
  end
  return result
end

local function operation_option_is_explanatory(option)
  local text = tostring(option or "")
  local lower = text:lower()
  if text == "" then return false end
  if text:find("例如", 1, true) or text:find("比如", 1, true) or text:find("举例", 1, true) or text:find("示例", 1, true) then return true end
  if text:find("如 ", 1, true) or text:find("如：", 1, true) or text:find("如:", 1, true) then return true end
  if text:find("请提供", 1, true) or text:find("请说明", 1, true) or text:find("请描述", 1, true) or text:find("请具体", 1, true) then return true end
  if text:find("类似", 1, true) or text:find("等）", 1, true) or text:find("等等", 1, true) then return true end
  if lower:find("for example", 1, true) or lower:find("e.g.", 1, true) or lower:find("such as", 1, true) then return true end
  if lower:find("please provide", 1, true) or lower:find("please specify", 1, true) or lower:find("describe", 1, true) then return true end
  if #text > 54 and (text:find("（", 1, true) or text:find("(", 1, true) or text:find("，", 1, true) or text:find(",", 1, true)) then return true end
  return false
end

local function operation_option_is_discardable(option)
  local text = tostring(option or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local compact = text:gsub("%s+", "")
  local lower = compact:lower()
  if compact == "" then return true end
  if compact:match("^[%.]+$") or compact:match("^[…]+$") then return true end
  if compact == "……" or compact == "..." or compact == ".." then return true end
  if lower == "etc" or lower == "etc." then return true end
  return false
end

local function operation_merge_notes(...)
  local result = {}
  for i = 1, select("#", ...) do
    local notes = select(i, ...)
    if type(notes) == "table" then
      for _, note in ipairs(notes) do
        note = tostring(note or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if note ~= "" then table.insert(result, note) end
      end
    elseif notes ~= nil then
      local note = tostring(notes or ""):gsub("^%s+", ""):gsub("%s+$", "")
      if note ~= "" then table.insert(result, note) end
    end
  end
  return result
end

local function operation_filter_clarification_choices_and_notes(question, options, notes, fields, intent_name)
  options = options or {}
  local note_list = operation_merge_notes(notes or {})
  local export_context = operation_is_export_format_context(question, fields, intent_name)
  local filtered = {}
  for _, option in ipairs(options) do
    local text = tostring(option or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local mentions_format, format_key = operation_option_mentions_export_format(text)
    if operation_option_is_discardable(text) then
    elseif operation_option_is_explanatory(text) then
      table.insert(note_list, text)
    elseif export_context and mentions_format and not operation_export_format_supported(format_key) then
      table.insert(note_list, text)
    else
      table.insert(filtered, text)
    end
  end
  return filtered, note_list
end

local function operation_filter_clarification_options(question, options, fields, intent_name)
  local filtered = operation_filter_clarification_choices_and_notes(question, options, {}, fields, intent_name)
  return filtered
end

local function operation_parse_llm_intent(text)
  text = tostring(text or "")
  local block = text:match("%[INTENT%](.-)%[/INTENT%]")
  if not block then return nil end
  local data = { source = "llm", raw = block }
  for line in block:gmatch("[^\r\n]+") do
    local key, value = line:match("^%s*([%w_]+)%s*[:=]%s*(.-)%s*$")
    if key and value then
      key = key:lower()
      if key == "intent" or key == "primary" or key == "action" then
        data.intent = operation_normalize_llm_intent(value)
      elseif key == "confidence" then
        data.confidence = operation_normalize_confidence(value)
      elseif key == "target" or key == "scope" then
        data.target = value
      elseif key == "destructive" then
        data.destructive = operation_parse_bool_text(value)
      elseif key == "writes_disk" then
        data.writes_disk = operation_parse_bool_text(value)
      elseif key == "needs_clarification" or key == "clarify" then
        data.needs_clarification = operation_parse_bool_text(value)
      elseif key == "question" or key == "clarification_question" then
        data.clarification_question = value
      elseif key == "options" or key == "choices" or key == "clarification_options" or key == "clarification_choices" then
        data.options = operation_split_options(value)
      elseif key == "notes" or key == "examples" or key == "clarification_notes" then
        data.notes = operation_split_notes(value)
      elseif key == "free_input" or key == "allow_input" then
        data.free_input = operation_parse_bool_text(value)
      elseif key == "placeholder" or key == "input_placeholder" then
        data.placeholder = value
      elseif key == "fields" or key == "missing_fields" or key == "slots" then
        data.fields = operation_split_options(value)
      elseif key == "reason" then
        data.reason = value
      end
    end
  end
  data.intent = operation_normalize_llm_intent(data.intent or "")
  data.confidence = operation_normalize_confidence(data.confidence or "")
  if data.intent == "unknown" then data.needs_clarification = true end
  if data.confidence == "low" and data.intent ~= "query" then data.needs_clarification = true end
  data.options, data.notes = operation_filter_clarification_choices_and_notes(data.clarification_question or data.reason or "", data.options or {}, data.notes or {}, data.fields or {}, data.intent)
  if data.free_input == nil then data.free_input = true end
  return data
end

local function operation_apply_llm_intent(user_text, contract, llm_intent)
  local intent = {
    raw = tostring(user_text or ""),
    goal_text = tostring((contract or {}).goal_text or user_text or ""),
    contract = contract,
    source = "llm",
    primary = operation_normalize_llm_intent(llm_intent and llm_intent.intent or ""),
    wants_read_only = false,
    wants_delete = false,
    wants_clear = false,
    wants_overwrite = false,
    wants_export = false,
    wants_freeze = false,
    wants_rename = false,
    wants_create = false,
    wants_edit = false,
    confidence = operation_normalize_confidence(llm_intent and llm_intent.confidence or "medium"),
    needs_clarification = llm_intent and llm_intent.needs_clarification == true or false,
    llm_intent = llm_intent or {},
  }
  local primary = intent.primary
  if primary == "query" then
    intent.wants_read_only = true
  elseif primary == "delete" then
    intent.wants_delete = true
    intent.wants_clear = true
  elseif primary == "export" then
    intent.wants_export = true
  elseif primary == "rename" then
    intent.wants_rename = true
  elseif primary == "create" then
    intent.wants_create = true
  elseif primary == "edit" then
    intent.wants_edit = true
  elseif primary == "freeze" then
    intent.wants_freeze = true
    intent.wants_edit = true
  elseif primary == "unknown" or primary == "" then
    intent.primary = "unknown"
    intent.needs_clarification = true
  end
  if intent.confidence == "low" and intent.primary ~= "query" then
    intent.needs_clarification = true
  end
  return intent
end

local function operation_infer_user_intent(user_text, contract, llm_intent)
  contract = contract or operation_build_intent_contract(user_text)
  local text = tostring(contract.goal_text or user_text or "")
  local intent = {
    raw = tostring(user_text or ""),
    goal_text = text,
    contract = contract,
    primary = "custom",
    wants_read_only = false,
    wants_delete = false,
    wants_clear = false,
    wants_overwrite = false,
    wants_export = false,
    wants_freeze = false,
    wants_rename = false,
    wants_create = false,
    wants_edit = false,
    confidence = "low",
  }
  if llm_intent then
    return operation_apply_llm_intent(user_text, contract, llm_intent)
  end

  intent.source = "heuristic"
  intent.llm_missing = true

  if text == "" then
    return intent
  end

  local query_hit = operation_text_has_any(text, {
    "查询", "查看", "看一下", "检查", "统计", "列出", "显示", "告诉我", "有没有", "多少", "数量", "当前信息",
    "query", "list", "show", "check", "inspect", "count"
  })
  local delete_hit = operation_text_has_any(text, {
    "删除", "删掉", "移除", "去掉", "清空", "清除", "清理", "干掉", "抹掉", "delete", "remove", "clear"
  })
  local overwrite_hit = operation_text_has_any(text, {
    "覆盖", "替换文件", "覆盖文件", "overwrite", "replace file"
  })
  local export_hit = operation_text_has_any(text, {
    "导出", "渲染", "输出", "保存到", "保存", "export", "render", "bounce", "save"
  })
  local freeze_hit = operation_text_has_any(text, {
    "冻结", "解冻", "胶合", "freeze", "unfreeze", "glue"
  })
  local rename_hit = operation_text_has_any(text, {
    "重命名", "改名", "命名", "前缀", "后缀", "替换名字", "rename", "prefix", "suffix"
  })
  local create_hit = operation_text_has_any(text, {
    "创建", "新建", "添加", "生成", "插入", "打标记", "加标记", "打 marker", "create", "add", "generate", "insert", "add marker"
  })
  local edit_hit = operation_text_has_any(text, {
    "设置", "调整", "移动", "对齐", "淡入", "淡出", "颜色", "音量", "声像", "包络", "路由", "量化",
    "修复", "处理", "整理", "优化", "归一化", "冻结", "解冻", "胶合",
    "set", "adjust", "move", "align", "fade", "color", "volume", "pan", "route", "quantize",
    "fix", "repair", "process", "normalize", "organize", "clean up", "freeze", "unfreeze", "glue"
  })

  local write_phrase_hit = operation_text_has_any(text, {
    "给", "把", "将", "加上", "添加前缀", "添加后缀", "名字前面", "名字后面", "名称前面", "名称后面",
    "前面加", "后面加", "改成", "改为", "设为", "设置为", "批量改", "批量重命名", "rename all", "add prefix", "add suffix"
  })
  if write_phrase_hit then
    edit_hit = true
    if operation_text_has_any(text, {"名字", "名称", "region", "Region", "marker", "Marker", "轨道", "track", "Track"}) then
      rename_hit = true
    end
  end

  intent.has_write_phrase = write_phrase_hit == true
  intent.wants_read_only = query_hit and not delete_hit and not export_hit and not rename_hit and not create_hit and not edit_hit and not write_phrase_hit
  intent.wants_delete = delete_hit == true and not ((contract.forbidden or {}).delete_project or (contract.forbidden or {}).clear_project)
  intent.wants_clear = delete_hit == true and not ((contract.forbidden or {}).delete_project or (contract.forbidden or {}).clear_project)
  intent.wants_overwrite = overwrite_hit == true
  intent.wants_export = export_hit == true
  intent.wants_freeze = freeze_hit == true
  intent.wants_rename = rename_hit == true
  intent.wants_create = create_hit == true
  intent.wants_edit = edit_hit == true

  if intent.wants_read_only then
    intent.primary = "query"
    intent.confidence = "medium"
  elseif intent.wants_delete then
    intent.primary = "delete"
    intent.confidence = "medium"
  elseif intent.wants_overwrite then
    intent.primary = "overwrite"
    intent.confidence = "medium"
  elseif intent.wants_export then
    intent.primary = "export"
    intent.confidence = "medium"
  elseif intent.wants_rename then
    intent.primary = "rename"
    intent.confidence = "medium"
  elseif intent.wants_create then
    intent.primary = "create"
    intent.confidence = "low"
  elseif intent.wants_edit then
    intent.primary = "edit"
    intent.confidence = "low"
  end

  return intent
end

local function operation_merge_effects(target, effects)
  target = target or {}
  for key, value in pairs(effects or {}) do
    if value then target[key] = true end
  end
  return target
end

local function operation_read_only_conflict_effects(effects)
  effects = effects or {}
  return effects.modifies_project or effects.deletes_project or effects.clears_project or effects.exports_file or effects.writes_disk
end

local function operation_script_effects(code)
  code = tostring(code or "")
  local effects = {
    modifies_project = false,
    deletes_project = false,
    clears_project = false,
    exports_file = false,
    writes_disk = false,
    deletes_disk = false,
    saves_project = false,
    batch = false,
    read_only = false,
    changes_selection = false,
    changes_time_selection = false,
    moves_cursor = false,
    analysis_side_effect = false,
    custom_script = true,
  }
  local action = "custom_script"
  local label = "自定义 SCRIPT"
  local native_labels = {}

  for _, command in ipairs(operation_main_on_command_ids(code)) do
    if command.id then
      local native = operation_native_action_meta(command.id)
      if native then
        operation_merge_native_action_effects(effects, native)
        action = native.action or action
        local native_label = native.name or native.label or ("Native Action " .. tostring(command.id))
        table.insert(native_labels, native_label)
        label = "Native Action: " .. tostring(native_label)
      else
        effects.modifies_project = true
        label = "Native Action: " .. tostring(command.id)
      end
    end
  end

  if code:match("DeleteTrackMediaItem") or code:match("DeleteTrack%s*%(") or code:match("DeleteProjectMarker") or
     code:match("TrackFX_Delete%s*%(") or code:match("DeleteEnvelopePoint") then
    effects.modifies_project = true
    effects.deletes_project = true
    action = "delete"
    label = "SCRIPT 删除工程对象"
  end
  if code:match("DeleteEnvelopePoint") or code:match("DeleteEnvelopePointRange") then
    effects.clears_project = true
  end
  if code:match("os%s*%.%s*remove") or code:match("DeleteFile") then
    effects.deletes_disk = true
    effects.writes_disk = true
  end
  if code:match("RenderProject") then
    effects.exports_file = true
    effects.writes_disk = true
    action = (action == "custom_script") and "export" or action
  end
  if code:match("Main_SaveProject") then
    effects.saves_project = true
    effects.writes_disk = true
  end
  if code:match("io%s*%.") or code:match("os%s*%.") then
    effects.writes_disk = true
  end
  if code:match("SetMediaItemInfo_Value") or code:match("SetMediaTrackInfo_Value") or code:match("GetSetMediaTrackInfo_String") or
     code:match("SetProjectMarker") or code:match("AddProjectMarker2%s*%(") or code:match("AddProjectMarker%s*%(") or
     code:match("InsertTrackAtIndex%s*%(") or code:match("InsertMedia%s*%(") or code:match("InsertMediaSection%s*%(") or
     code:match("AddMediaItemToTrack%s*%(") or code:match("TrackFX_AddByName%s*%(") or code:match("TrackFX_Delete%s*%(") or
     code:match("SplitMediaItem") or code:match("InsertEnvelopePoint") then
    effects.modifies_project = true
    if action == "custom_script" then action = "edit" end
  end
  if code:match("SetOnlyTrackSelected%s*%(") or code:match("SetTrackSelected%s*%(") or code:match("SetMediaItemSelected%s*%(") then
    effects.changes_selection = true
  end
  if code:match("GetSet_LoopTimeRange%s*%(%s*true") then
    effects.changes_time_selection = true
    effects.analysis_side_effect = true
  end
  if code:match("SetEditCurPos%s*%(") or code:match("SetPlayPosition%s*%(") then
    effects.moves_cursor = true
    effects.analysis_side_effect = true
  end
  if action == "custom_script" or action == "edit" or code:match("TrackFX_Delete%s*%(") then
    if code:match("InsertTrackAtIndex%s*%(") then
      action = "create"
      label = "SCRIPT create track"
    elseif code:match("AddProjectMarker2%s*%(") or code:match("AddProjectMarker%s*%(") then
      action = "create"
      label = "SCRIPT add marker/region"
    elseif code:match("InsertMedia%s*%(") or code:match("InsertMediaSection%s*%(") or code:match("AddMediaItemToTrack%s*%(") then
      action = "create"
      label = "SCRIPT create/import item"
    elseif code:match("TrackFX_AddByName%s*%(") then
      action = "edit"
      label = "SCRIPT add FX"
    elseif code:match("TrackFX_Delete%s*%(") then
      action = "delete"
      label = "SCRIPT remove FX"
      effects.deletes_project = true
    end
  end
  if code:match("CountTracks%s*%(") or code:match("CountMediaItems%s*%(") or code:match("CountProjectMarkers%s*%(") or
     code:match("for%s+[%w_]+%s*=%s*0%s*,") then
    effects.batch = true
  end
  if not effects.modifies_project and not effects.writes_disk and not effects.deletes_project and not effects.exports_file then
    effects.read_only = true
    if #native_labels == 0 then
      action = "query"
      label = "SCRIPT 查询/分析"
    end
  end

  return {
    action = action,
    label = label,
    native_actions = native_labels,
    effects = effects,
  }
end

local function operation_mark_blocked(step, message)
  if not step then return end
  step.status = "blocked"
  step.error = message
  step.precheck_error = message
  step.blocked_reason = message
end

local function operation_mcp_param_encode(value)
  value = tostring(value or "")
  value = value:gsub("\n", " "):gsub("\r", " ")
  value = value:gsub("([^%w%-%._~ ])", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
  return value:gsub(" ", "+")
end

local function operation_build_call(endpoint, params)
  endpoint = tostring(endpoint or "")
  params = params or {}
  local keys = {}
  for key, _ in pairs(params) do table.insert(keys, key) end
  table.sort(keys)
  local parts = {}
  for _, key in ipairs(keys) do
    local value = params[key]
    if value ~= nil and tostring(value) ~= "" then
      table.insert(parts, operation_mcp_param_encode(key) .. "=" .. operation_mcp_param_encode(value))
    end
  end
  if #parts == 0 then return endpoint end
  return endpoint .. "?" .. table.concat(parts, "&")
end

local function operation_script_looks_like_generated_item_selection(code)
  code = tostring(code or "")
  local lower = code:lower()
  if not (lower:find("setmediaitemselected", 1, true) or lower:find("selectallmediaitems", 1, true)) then
    return false
  end
  if lower:find("variant", 1, true) or code:find("变体", 1, true) then
    return true
  end
  if lower:find("gettrackmediaitem", 1, true) and lower:find("setmediaitemselected", 1, true) then
    return true
  end
  return false
end

local function operation_number_arg_for_media_item_value(code, key)
  code = tostring(code or "")
  key = tostring(key or "")
  if key == "" then return nil end
  local pattern = "SetMediaItemInfo_Value%s*%([^%)]-[\"']" .. key .. "[\"']%s*,%s*([%d%.]+)"
  local found = code:match(pattern)
  return found and tonumber(found) or nil
end

local function operation_script_generated_item_fade_params(code)
  code = tostring(code or "")
  local lower = code:lower()
  if not lower:find("setmediaiteminfo_value", 1, true) then return nil end
  if not (code:find("D_FADEINLEN", 1, true) or code:find("D_FADEOUTLEN", 1, true)) then return nil end
  if not (lower:find("gettrackmediaitem", 1, true) or lower:find("variant", 1, true) or code:find("变体", 1, true)) then
    return nil
  end
  local params = { item = "created.items[1]" }
  local fade_in = operation_number_arg_for_media_item_value(code, "D_FADEINLEN")
  local fade_out = operation_number_arg_for_media_item_value(code, "D_FADEOUTLEN")
  if fade_in ~= nil then params.fade_in_ms = tostring(math.floor(fade_in * 1000 + 0.5)) end
  if fade_out ~= nil then params.fade_out_ms = tostring(math.floor(fade_out * 1000 + 0.5)) end
  if not params.fade_in_ms and not params.fade_out_ms then return nil end
  return params
end

local function operation_trim_value(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function operation_unquote_lua_string(value)
  value = operation_trim_value(value)
  local quote = value:sub(1, 1)
  if (quote ~= "'" and quote ~= '"') or value:sub(-1) ~= quote then return nil end
  local inner = value:sub(2, -2)
  inner = inner:gsub("\\n", "\n"):gsub("\\r", "\r"):gsub("\\t", "\t")
  inner = inner:gsub("\\" .. quote, quote):gsub("\\\\", "\\")
  return inner
end

local function operation_lua_number_literal(value)
  value = operation_trim_value(value)
  if value:match("^%-?%d+%.?%d*$") or value:match("^%-?%.%d+$") then
    return value
  end
  return nil
end

local function operation_lua_integer_literal(value)
  value = operation_trim_value(value)
  if value:match("^%-?%d+$") then return value end
  return nil
end

local function operation_lua_track_index_expr(expr)
  expr = operation_trim_value(expr)
  local index = expr:match("GetTrack%s*%(%s*0%s*,%s*(%-?%d+)%s*%)")
  if index then return index end
  index = expr:match("reaper%s*%.%s*GetTrack%s*%(%s*0%s*,%s*(%-?%d+)%s*%)")
  if index then return index end
  return nil
end

local function operation_first_call_args(code, fn_name)
  code = tostring(code or "")
  fn_name = tostring(fn_name or "")
  if fn_name == "" then return nil end
  local escaped = fn_name:gsub("([^%w])", "%%%1")
  local patterns = {
    "reaper%s*%.%s*" .. escaped .. "%s*%(",
    "%f[%w_]" .. escaped .. "%s*%(",
  }
  local best_s, best_e = nil, nil
  for _, pattern in ipairs(patterns) do
    local s, e = code:find(pattern)
    if s and (not best_s or s < best_s) then
      best_s, best_e = s, e
    end
  end
  if not best_s then return nil end
  local i = best_e + 1
  local depth = 1
  local quote = nil
  local args = {}
  while i <= #code and depth > 0 do
    local c = code:sub(i, i)
    if quote then
      table.insert(args, c)
      if c == "\\" then
        i = i + 1
        if i <= #code then table.insert(args, code:sub(i, i)) end
      elseif c == quote then
        quote = nil
      end
    elseif c == "'" or c == '"' then
      quote = c
      table.insert(args, c)
    elseif c == "(" then
      depth = depth + 1
      table.insert(args, c)
    elseif c == ")" then
      depth = depth - 1
      if depth > 0 then table.insert(args, c) end
    else
      table.insert(args, c)
    end
    i = i + 1
  end
  if depth ~= 0 then return nil end
  return operation_split_lua_args(table.concat(args))
end

local function operation_track_index_from_script(code, expr)
  local index = operation_lua_track_index_expr(expr or "")
  if index then return index end
  code = tostring(code or "")
  local var = operation_trim_value(expr):match("^([%a_][%w_]*)$")
  if not var then return nil end
  local escaped = var:gsub("([^%w_])", "%%%1")
  return code:match("local%s+" .. escaped .. "%s*=%s*reaper%s*%.%s*GetTrack%s*%(%s*0%s*,%s*(%-?%d+)%s*%)")
    or code:match("local%s+" .. escaped .. "%s*=%s*GetTrack%s*%(%s*0%s*,%s*(%-?%d+)%s*%)")
end

local function operation_constant_lua_arg(value)
  return operation_unquote_lua_string(value) or operation_lua_number_literal(value)
end

local function operation_script_to_mcp_equivalent(code)
  code = tostring(code or "")
  local lower = code:lower()

  local args = operation_first_call_args(code, "GetSetMediaTrackInfo_String")
  if args and #args >= 4 and operation_unquote_lua_string(args[2]) == "P_NAME" then
    local index = operation_track_index_from_script(code, args[1])
    local name = operation_unquote_lua_string(args[3])
    local commit = operation_trim_value(args[4]):lower()
    if index and name and (commit == "true" or commit == "1") then
      return "track/rename", { index = index, name = name }, "MCP-first: replaced track rename SCRIPT with track/rename"
    end
  end

  args = operation_first_call_args(code, "SetMediaTrackInfo_Value")
  if args and #args >= 3 then
    local key = operation_unquote_lua_string(args[2])
    local index = operation_track_index_from_script(code, args[1])
    local value = operation_lua_number_literal(args[3])
    if index and value and key == "D_VOL" then
      return "track/set_volume", { index = index, volume = value }, "MCP-first: replaced track volume SCRIPT with track/set_volume"
    end
  end

  args = operation_first_call_args(code, "SetTrackColor")
  if args and #args >= 2 then
    local index = operation_track_index_from_script(code, args[1])
    local r, g, b = code:match("ColorToNative%s*%(%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*%)")
    if not r then
      r, g, b = code:match("reaper%s*%.%s*ColorToNative%s*%(%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*%)")
    end
    if index and r and g and b then
      return "track/set_color", { index = index, color = "#" .. string.format("%02X%02X%02X", tonumber(r) or 0, tonumber(g) or 0, tonumber(b) or 0) }, "MCP-first: replaced track color SCRIPT with track/set_color"
    end
  end

  args = operation_first_call_args(code, "TrackFX_AddByName")
  if args and #args >= 2 then
    local index = operation_track_index_from_script(code, args[1])
    local fx = operation_unquote_lua_string(args[2])
    if index and fx then
      return "track/add_fx", { track = index, fx = fx }, "MCP-first: replaced add FX SCRIPT with track/add_fx"
    end
  end

  args = operation_first_call_args(code, "TrackFX_Delete")
  if args and #args >= 2 then
    local index = operation_track_index_from_script(code, args[1])
    local fx_index = operation_lua_integer_literal(args[2])
    if index and fx_index then
      return "track/remove_fx", { track = index, fx_index = fx_index }, "MCP-first: replaced remove FX SCRIPT with track/remove_fx"
    end
  end

  args = operation_first_call_args(code, "AddProjectMarker2") or operation_first_call_args(code, "AddProjectMarker")
  if args and #args >= 5 then
    local is_region = operation_trim_value(args[2]):lower()
    local time = operation_lua_number_literal(args[3])
    local name = operation_unquote_lua_string(args[5]) or "Marker"
    if time and (is_region == "false" or is_region == "0") then
      return "marker/add", { time = time, name = name }, "MCP-first: replaced marker add SCRIPT with marker/add"
    end
  end

  args = operation_first_call_args(code, "DeleteProjectMarker")
  if args and #args >= 3 then
    local index = operation_lua_integer_literal(args[2])
    local is_region = operation_trim_value(args[3]):lower()
    if index and (is_region == "false" or is_region == "0") then
      return "marker/delete", { index = index }, "MCP-first: replaced marker delete SCRIPT with marker/delete"
    elseif index and (is_region == "true" or is_region == "1") then
      return "region/delete", { index = index }, "MCP-first: replaced region delete SCRIPT with region/delete"
    end
  end

  if lower:find("getselectedenvelope", 1, true) then
    args = operation_first_call_args(code, "DeleteEnvelopePointRange")
    if args and #args >= 3 then
      local start_pos = operation_lua_number_literal(args[2])
      local end_pos = operation_lua_number_literal(args[3])
      if start_pos and end_pos then
        return "envelope/clear", { target = "selected_envelope", lane = "volume", start = start_pos, ["end"] = end_pos }, "MCP-first: replaced selected envelope clear SCRIPT with envelope/clear"
      end
    end

    args = operation_first_call_args(code, "InsertEnvelopePoint")
    if args and #args >= 3 then
      local time = operation_lua_number_literal(args[2])
      local value = operation_lua_number_literal(args[3])
      if time and value then
        return "envelope/draw", { target = "selected_envelope", lane = "volume", start = time, ["end"] = time, from = value, to = value, steps = "1" }, "MCP-first: replaced selected envelope point SCRIPT with envelope/draw"
      end
    end
  end

  if lower:find("main_oncommand", 1, true) then
    local commands = operation_main_on_command_ids(code)
    if #commands == 1 and commands[1].id then
      local native = operation_native_action_meta(commands[1].id)
      local params = { command_id = commands[1].id }
      if code:find("SetOnlyTrackSelected", 1, true) or code:find("I_SELECTED", 1, true) then
        params.selected = "true"
      end
      if native and tostring(native.action or "") == "freeze" then
        params.action = "freeze"
        params.mode = tostring(native.mode or "stereo")
      end
      return "native/action", params, "MCP-first: replaced Main_OnCommand SCRIPT with native/action"
    end
  end

  return nil
end

local function operation_trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function operation_track_name_list(raw)
  raw = tostring(raw or ""):gsub("\239\188\140", ","):gsub("|", ","):gsub(";", ",")
  local names = {}
  for part in raw:gmatch("[^,]+") do
    part = operation_trim(part)
    if part ~= "" then table.insert(names, part) end
  end
  return names
end

local function operation_track_create_count(params)
  params = params or {}
  local names = operation_track_name_list(params.names or params.track_names or "")
  local explicit_count = operation_trim(params.count or "") ~= ""
  local count = tonumber(params.count or "") or (#names > 0 and #names or 1)
  count = math.max(1, math.floor(count))
  if #names > count then count = #names end
  return count, names, explicit_count
end

local function operation_track_rename_new_name(params)
  params = params or {}
  return operation_trim(params.name or params.new_name or params.to or "")
end

local function operation_created_track_ref(value)
  value = operation_trim(value):lower():gsub("%s+", "")
  return value:match("^created%.tracks%[%d+%]$") ~= nil or value:match("^generated%.tracks%[%d+%]$") ~= nil
end

local function operation_truthy(value)
  value = tostring(value or ""):lower()
  return value == "true" or value == "1" or value == "yes" or value == "on"
end

local function operation_track_rename_has_external_target(params)
  params = params or {}
  if operation_truthy(params.selected) or operation_truthy(params.all) then return true end
  for _, key in ipairs({"target", "old_name", "from", "track_name", "track", "index"}) do
    local value = operation_trim(params[key])
    if value ~= "" and not operation_created_track_ref(value) and tonumber(value) == nil then
      return true
    end
  end
  return false
end

local TRACK_TARGET_CONTRACTS = {
  ["track/rename"] = { name_param = "target", index_param = "index", aliases = { "target", "old_name", "from", "track_name" } },
  ["track/set_volume"] = { name_param = "name", index_param = "index", aliases = { "target", "track", "track_name", "name" } },
  ["track/set_pan"] = { name_param = "name", index_param = "index", aliases = { "target", "track", "track_name", "name" } },
  ["track/set_color"] = { name_param = "name", index_param = "index", aliases = { "target", "track", "track_name", "name" } },
  ["track/mute"] = { name_param = "name", index_param = "index", aliases = { "target", "track", "track_name", "name" } },
  ["track/solo"] = { name_param = "name", index_param = "index", aliases = { "target", "track", "track_name", "name" } },
  ["track/add_fx"] = { name_param = "track", index_param = "track", aliases = { "target", "track", "track_name", "index" } },
  ["track/remove_fx"] = { name_param = "track", index_param = "track", aliases = { "target", "track", "track_name", "index", "name" } },
}

local function operation_is_selected_target(value)
  value = operation_trim(value):lower()
  return value == "selected" or value == "selection" or value == "current" or value == "当前" or value == "选中" or value == "已选中"
end

local function operation_first_param(params, keys)
  params = params or {}
  for _, key in ipairs(keys or {}) do
    local value = operation_trim(params[key])
    if value ~= "" then return key, value end
  end
  return nil, nil
end

local function operation_normalize_track_target(endpoint, params)
  local contract = TRACK_TARGET_CONTRACTS[endpoint]
  if not contract then return false end
  params = params or {}
  if operation_truthy(params.selected) then return false end
  local key, value = operation_first_param(params, contract.aliases)
  if not key or not value then return false end
  if operation_is_selected_target(value) then
    params.selected = "true"
    params.target = nil
    params.track = nil
    params.index = nil
    return true
  end
  if operation_created_track_ref(value) then
    return false
  end

  local changed = false
  if tonumber(value) then
    local index_param = contract.index_param or "index"
    if params[index_param] ~= value then
      params[index_param] = value
      changed = true
    end
    if index_param ~= "index" then params.index = nil end
  else
    local name_param = contract.name_param or "name"
    if params[name_param] ~= value then
      params[name_param] = value
      changed = true
    end
    if name_param ~= "target" then params.target = nil end
    if name_param ~= "track" then params.track = nil end
    if name_param ~= "index" then params.index = nil end
  end
  return changed
end

local function operation_created_track_names_from_create(params)
  local count, names = operation_track_create_count(params)
  if #names > 0 then return names end
  local base_name = operation_trim((params or {}).name or "")
  local result = {}
  if base_name ~= "" then
    for i = 1, count do
      table.insert(result, count > 1 and (base_name .. " " .. tostring(i)) or base_name)
    end
  end
  return result
end

local function operation_track_target_candidate(endpoint, params)
  local contract = TRACK_TARGET_CONTRACTS[endpoint]
  if not contract then return nil, nil end
  return operation_first_param(params, contract.aliases)
end

local function operation_bind_recent_created_track_targets(steps)
  local rewrites = {}
  local recent_names = nil
  for _, step in ipairs(steps or {}) do
    if step and step.kind == "mcp" then
      local endpoint, params = operation_parse_call(step.call or "")
      if endpoint == "track/create" then
        recent_names = operation_created_track_names_from_create(params)
      elseif recent_names and TRACK_TARGET_CONTRACTS[endpoint] then
        local key, value = operation_track_target_candidate(endpoint, params)
        local matched_index = nil
        if value and value ~= "" then
          local needle = value:lower()
          for i, name in ipairs(recent_names) do
            local lower_name = tostring(name or ""):lower()
            if lower_name == needle or (needle ~= "" and lower_name:find(needle, 1, true)) then
              matched_index = i
              break
            end
          end
        elseif #recent_names == 1 then
          matched_index = 1
        end
        if matched_index then
          local old_call = step.call
          params.target = "created.tracks[" .. tostring(matched_index) .. "]"
          params.track = nil
          params.track_name = nil
          params.index = nil
          if endpoint == "track/remove_fx" and key == "name" then params.name = nil end
          step.call = operation_build_call(endpoint, params)
          step.raw = "[MCP_CALL:" .. step.call .. "]"
          if step.call ~= old_call then
            table.insert(rewrites, "Target Contract: bound " .. endpoint .. " to created.tracks[" .. tostring(matched_index) .. "]")
          end
        end
      elseif endpoint ~= "" and endpoint ~= "track/add_fx" and endpoint ~= "track/set_volume" and endpoint ~= "track/set_pan" and endpoint ~= "track/set_color" and endpoint ~= "track/mute" and endpoint ~= "track/solo" and endpoint ~= "track/remove_fx" then
        recent_names = nil
      end
    end
  end
  return rewrites
end

local function operation_normalize_target_contracts(steps)
  local rewrites = {}
  for _, step in ipairs(steps or {}) do
    if step and step.kind == "mcp" then
      local endpoint, params = operation_parse_call(step.call or "")
      if operation_normalize_track_target(endpoint, params) then
        step.call = operation_build_call(endpoint, params)
        step.raw = "[MCP_CALL:" .. step.call .. "]"
        table.insert(rewrites, "Target Contract: normalized " .. endpoint .. " target parameters")
      end
    end
  end
  return rewrites
end

local function operation_has_track_contract_target(endpoint, params)
  params = params or {}
  if operation_truthy(params.selected) or operation_truthy(params.all) then return true end
  local contract = TRACK_TARGET_CONTRACTS[endpoint]
  if not contract then return true end
  local _, value = operation_track_target_candidate(endpoint, params)
  return value ~= nil and value ~= ""
end

local function operation_has_item_contract_target(params, allow_all)
  params = params or {}
  if operation_truthy(params.selected) then return true end
  if allow_all and operation_truthy(params.all or params.all_items) then return true end
  return operation_has_value(params, {"index", "item", "target", "name", "match", "item_name"})
end

local function operation_has_envelope_contract_target(params)
  params = params or {}
  if operation_truthy(params.selected) then return true end
  return operation_has_value(params, {"target", "scope", "track", "track_name", "item", "item_name", "take", "index", "name"})
end

local function operation_has_time_range(params)
  params = params or {}
  if operation_truthy(params.time_selection) then return true end
  return operation_has_value(params, {"start", "end", "time", "from_time", "to_time", "duration", "length"})
end

local function operation_rewrite_track_create_renames(steps)
  local rewrites = {}
  local i = 1
  while i <= #(steps or {}) do
    local step = steps[i]
    local endpoint, create_params = "", {}
    if step and step.kind == "mcp" then
      endpoint, create_params = operation_parse_call(step.call or "")
    end
    if endpoint == "track/create" then
      local count, existing_names, explicit_count = operation_track_create_count(create_params)
      local rename_steps = {}
      local rename_names = {}
      local j = i + 1
      while j <= #steps do
        local rename_step = steps[j]
        local rename_endpoint, rename_params = "", {}
        if rename_step and rename_step.kind == "mcp" then
          rename_endpoint, rename_params = operation_parse_call(rename_step.call or "")
        end
        if rename_endpoint ~= "track/rename" then break end
        local new_name = operation_track_rename_new_name(rename_params)
        if new_name == "" or operation_track_rename_has_external_target(rename_params) then break end
        table.insert(rename_steps, rename_step)
        table.insert(rename_names, new_name)
        j = j + 1
      end

      if #rename_names > 0 then
        if not explicit_count and #rename_names > count then count = #rename_names end
        if #existing_names == 0 and #rename_names == count then
          create_params.count = tostring(count)
          create_params.names = table.concat(rename_names, ",")
          create_params.track_names = nil
          create_params.name = nil
          step.call = operation_build_call("track/create", create_params)
          step.raw = "[MCP_CALL:" .. step.call .. "]"
          step.rewrite_note = "MCP-first: folded track/create plus rename steps into track/create names"
          for _ = 1, #rename_steps do
            table.remove(steps, i + 1)
          end
          table.insert(rewrites, step.rewrite_note)
        else
          for rename_index, rename_step in ipairs(rename_steps) do
            local rename_endpoint, rename_params = operation_parse_call(rename_step.call or "")
            rename_params.target = "created.tracks[" .. tostring(rename_index) .. "]"
            rename_params.index = nil
            rename_params.track = nil
            rename_step.call = operation_build_call(rename_endpoint, rename_params)
            rename_step.raw = "[MCP_CALL:" .. rename_step.call .. "]"
          end
          table.insert(rewrites, "MCP-first: bound post-create track edits to created.tracks[N]")
        end
      end
    end
    i = i + 1
  end
  return rewrites
end

local function operation_rewrite_mcp_first(steps)
  local rewrites = {}
  for _, note in ipairs(operation_rewrite_track_create_renames(steps) or {}) do
    table.insert(rewrites, note)
  end
  if PlanContract and type(PlanContract.apply_bindings) == "function" then
    for _, note in ipairs(PlanContract.apply_bindings(steps) or {}) do
      table.insert(rewrites, note)
    end
  end
  for _, note in ipairs(operation_bind_recent_created_track_targets(steps) or {}) do
    table.insert(rewrites, note)
  end
  for _, note in ipairs(operation_normalize_target_contracts(steps) or {}) do
    table.insert(rewrites, note)
  end
  local generated_items_available = false
  local i = 1
  while i <= #(steps or {}) do
    local step = steps[i]
    if step and step.kind == "mcp" then
      local endpoint = operation_parse_call(step.call or "")
      if endpoint == "sfx/generate_variants" then
        generated_items_available = true
      end
    end

    local next_step = steps and steps[i + 1] or nil
    if generated_items_available and step and next_step
      and step.kind == "script"
      and next_step.kind == "mcp"
      and operation_script_looks_like_generated_item_selection(step.code or "") then
      local endpoint, params = operation_parse_call(next_step.call or "")
      if endpoint == "item/fade" or endpoint == "item/set_fade" or endpoint == "item/fade_shape" or endpoint == "item/set_fade_shape" then
        params.item = params.item or params.target or "created.items[1]"
        params.target = nil
        params.selected = nil
        next_step.call = operation_build_call(endpoint, params)
        next_step.raw = "[MCP_CALL:" .. next_step.call .. "]"
        next_step.rewritten_from_script = true
        next_step.rewrite_note = "MCP-first: removed generated item selection SCRIPT and bound item endpoint to created.items[1]"
        table.remove(steps, i)
        table.insert(rewrites, next_step.rewrite_note)
        i = math.max(i - 1, 1)
      end
    end
    if generated_items_available and step and step.kind == "script" then
      local fade_params = operation_script_generated_item_fade_params(step.code or "")
      if fade_params then
        step.kind = "mcp"
        step.type = "mcp"
        step.source = "mcp_first_rewriter"
        step.call = operation_build_call("item/fade", fade_params)
        step.raw = "[MCP_CALL:" .. step.call .. "]"
        step.code = nil
        step.valid = true
        step.validation_error = nil
        step.status = "pending"
        step.rewritten_from_script = true
        step.rewrite_note = "MCP-first: replaced generated item fade SCRIPT with item/fade bound to created.items[1]"
        table.insert(rewrites, step.rewrite_note)
      end
    end
    if step and step.kind == "script" then
      local endpoint, params, note = operation_script_to_mcp_equivalent(step.code or "")
      if endpoint then
        step.kind = "mcp"
        step.type = "mcp"
        step.source = "mcp_first_rewriter"
        step.call = operation_build_call(endpoint, params)
        step.raw = "[MCP_CALL:" .. step.call .. "]"
        step.code = nil
        step.valid = true
        step.validation_error = nil
        step.status = "pending"
        step.rewritten_from_script = true
        step.rewrite_note = note
        table.insert(rewrites, step.rewrite_note)
      end
    end
    i = i + 1
  end
  return rewrites
end

local function operation_validate_mcp_params(endpoint, params)
  local p = params or {}
  local issues = {}

  if endpoint == "track/delete" then
    local has_target = operation_bool_param(p.selected) or operation_bool_param(p.all) or operation_has_value(p, {"index", "name", "match", "contains", "keyword"})
    if not has_target then
      table.insert(issues, "track/delete 缺少删除目标，需要 selected/index/name/match/contains/keyword")
    end
  elseif endpoint == "track/create" then
    local count = tonumber(p.count or "") or 1
    local names = tostring(p.names or p.track_names or "")
    local names_count = 0
    names = names:gsub("\239\188\140", ","):gsub("|", ","):gsub(";", ",")
    for part in names:gmatch("[^,]+") do
      part = part:gsub("^%s+", ""):gsub("%s+$", "")
      if part ~= "" then names_count = names_count + 1 end
    end
    if names_count > 0 and count > 1 and names_count ~= count then
      table.insert(issues, "track/create names count does not match count; omit count or make it equal to names")
    end
  elseif endpoint == "track/rename" then
    local has_target = operation_bool_param(p.selected) or operation_has_value(p, {"index", "target", "old_name", "from", "track_name"})
    local has_name = operation_has_value(p, {"name", "new_name", "to"})
    if not has_target then
      table.insert(issues, "track/rename 缺少要重命名的轨道目标")
    end
    if not has_name then
      table.insert(issues, "track/rename 缺少新轨道名")
    end
  elseif endpoint == "track/set_volume" or endpoint == "track/set_volume_by_name" then
    if not operation_has_value(p, {"volume"}) then
      table.insert(issues, endpoint .. " 缺少 volume 参数")
    end
    if endpoint == "track/set_volume" and not operation_has_track_contract_target(endpoint, p) then
      table.insert(issues, "track/set_volume 缺少轨道目标，需要 selected/index/name/track/target")
    elseif endpoint == "track/set_volume_by_name" and not operation_has_value(p, {"name"}) then
      table.insert(issues, "track/set_volume_by_name 缺少 name 轨道名")
    end
  elseif endpoint == "track/set_pan" then
    if not operation_has_value(p, {"pan"}) then
      table.insert(issues, "track/set_pan 缺少 pan 参数")
    end
    if not operation_has_track_contract_target(endpoint, p) then
      table.insert(issues, "track/set_pan 缺少轨道目标，需要 selected/index/name/track/target")
    end
  elseif endpoint == "track/set_color" then
    if not operation_has_value(p, {"color"}) then
      table.insert(issues, "track/set_color 缺少 color 参数")
    end
    if not operation_has_track_contract_target(endpoint, p) then
      table.insert(issues, "track/set_color 缺少轨道目标，需要 selected/index/name/track/target")
    end
  elseif endpoint == "track/mute" then
    if not operation_has_track_contract_target(endpoint, p) then
      table.insert(issues, "track/mute 缺少轨道目标，需要 selected/index/name/track/target")
    end
  elseif endpoint == "track/solo" then
    if not operation_has_track_contract_target(endpoint, p) then
      table.insert(issues, "track/solo 缺少轨道目标，需要 selected/index/name/track/target")
    end
  elseif endpoint == "track/add_fx" then
    if not operation_has_value(p, {"fx", "fx_name", "effect", "plugin"}) then
      table.insert(issues, "track/add_fx 缺少 fx/fx_name 参数")
    end
    if not operation_has_track_contract_target(endpoint, p) then
      table.insert(issues, "track/add_fx 缺少轨道目标，需要 selected/track/target/index")
    end
  elseif endpoint == "track/remove_fx" then
    if not operation_has_value(p, {"fx_index", "fx", "fx_name"}) then
      table.insert(issues, "track/remove_fx 缺少 fx_index/fx/fx_name 参数")
    end
    if not operation_has_track_contract_target(endpoint, p) then
      table.insert(issues, "track/remove_fx 缺少轨道目标，需要 selected/track/name/target/index")
    end
  elseif endpoint == "region/delete" then
    if not operation_has_value(p, {
      "index", "id", "region", "target", "range", "ids", "start", "from", "name", "match",
      "order", "order_index", "order_start", "order_range",
      "ordinal", "ordinal_index", "ordinal_start", "ordinal_range",
      "sequence", "sequence_index", "sequence_start", "sequence_range"
    }) then
      table.insert(issues, "region/delete missing Region index/range/name target")
    end
    local has_start = operation_has_value(p, {"start", "from"})
    local has_end = operation_has_value(p, {"end", "to"})
    if has_start ~= has_end and not operation_has_value(p, {"range", "ids", "index", "id", "region", "target", "name", "match"}) then
      table.insert(issues, "region/delete range requires both start and end")
    end
    local has_order_start = operation_has_value(p, {"order_start", "ordinal_start", "sequence_start"})
    local has_order_end = operation_has_value(p, {"order_end", "ordinal_end", "sequence_end"})
    if has_order_start ~= has_order_end and not operation_has_value(p, {"order", "order_index", "order_range", "ordinal", "ordinal_index", "ordinal_range", "sequence", "sequence_index", "sequence_range"}) then
      table.insert(issues, "region/delete timeline order range requires both order_start and order_end")
    end
  elseif endpoint == "marker/delete" then
    if not operation_has_value(p, {"index", "target", "marker"}) then
      table.insert(issues, "marker/delete 缺少 index/target/marker 参数")
    end
  elseif endpoint == "item/fade" or endpoint == "item/set_fade" then
    if not operation_has_value(p, {
      "fade_in", "in", "fadein", "fade_in_s", "in_s", "fade_in_sec", "in_sec", "fade_in_ms", "in_ms",
      "fade_out", "out", "fadeout", "fade_out_s", "out_s", "fade_out_sec", "out_sec", "fade_out_ms", "out_ms"
    }) then
      table.insert(issues, endpoint .. " 缺少 fade_in/fade_out 参数")
    end
    if not operation_has_item_contract_target(p, false) then
      table.insert(issues, endpoint .. " 缺少素材目标，需要 selected/index/name/item/target")
    end
  elseif endpoint == "item/fade_shape" or endpoint == "item/set_fade_shape" then
    if not operation_has_item_contract_target(p, true) then
      table.insert(issues, endpoint .. " 缺少素材目标，需要 selected/all/index/name/item/target")
    end
  elseif endpoint == "envelope/draw" then
    if not operation_has_value(p, {"lane", "type", "envelope"}) then
      table.insert(issues, "envelope/draw 缺少 lane/type/envelope 参数")
    end
    if not operation_has_envelope_contract_target(p) then
      table.insert(issues, "envelope/draw 缺少包络目标，需要 selected/track/item/take/name/index/target")
    end
  elseif endpoint == "envelope/clear" then
    if not operation_has_value(p, {"lane", "type", "envelope"}) then
      table.insert(issues, "envelope/clear 缺少 lane/type/envelope 参数")
    end
    if not operation_has_envelope_contract_target(p) then
      table.insert(issues, "envelope/clear 缺少包络目标，需要 selected/track/item/take/name/index/target")
    end
    if not operation_has_time_range(p) and operation_trim(p.target) ~= "selected_envelope" then
      table.insert(issues, "envelope/clear 缺少清理范围，需要 time_selection/start/end/duration 或 selected_envelope")
    end
  elseif endpoint == "region/batch_rename" then
    if operation_has_value(p, {"search"}) then
      if not operation_has_value(p, {"replace"}) then
        table.insert(issues, "region/batch_rename 使用 search 时缺少 replace 参数")
      end
    elseif not operation_has_value(p, {"new_prefix", "prefix"}) then
      table.insert(issues, "region/batch_rename 需要 search/replace 或 new_prefix/prefix；old_prefix 允许为空")
    end
  elseif endpoint == "native/action" then
    if not operation_has_value(p, {"command_id", "id", "action_id", "query", "action", "kind", "name", "description"}) then
      table.insert(issues, "native/action 需要 command_id，或 action/query/name 用于查询本机 Action")
    end
  end

  return issues
end

local TRACK_CONTRACT_ENDPOINTS = {
  ["track/rename"] = true,
  ["track/set_volume"] = true,
  ["track/set_volume_by_name"] = true,
  ["track/set_pan"] = true,
  ["track/set_color"] = true,
  ["track/mute"] = true,
  ["track/solo"] = true,
  ["track/add_fx"] = true,
  ["track/remove_fx"] = true,
}

local function operation_param_string(params, key)
  local value = (params or {})[key]
  if value == nil then return "" end
  return tostring(value):gsub("^%s+", ""):gsub("%s+$", "")
end

local function operation_param_is_created_ref(value, kind)
  value = tostring(value or "")
  if kind == "track" then
    return value:match("^created%.tracks%[%d+%]$") ~= nil
  elseif kind == "item" then
    return value:match("^created%.items%[%d+%]$") ~= nil
  elseif kind == "marker" then
    return value:match("^created%.markers%[%d+%]$") ~= nil
  end
  return value:match("^created%.") ~= nil
end

local function operation_has_explicit_track_target(endpoint, params)
  params = params or {}
  if operation_bool_param(params.selected) then return true, "selected" end
  if operation_bool_param(params.all) then return true, "all" end

  local keys
  if endpoint == "track/rename" then
    keys = {"target", "old_name", "from", "track_name", "index"}
  elseif endpoint == "track/add_fx" or endpoint == "track/remove_fx" then
    keys = {"target", "track", "track_name", "index"}
  else
    keys = {"target", "track", "track_name", "name", "index"}
  end

  for _, key in ipairs(keys) do
    local value = operation_param_string(params, key)
    if value ~= "" then return true, key, value end
  end
  return false, nil, nil
end

local function operation_user_mentions_generated_reference(text)
  return operation_text_has_any(text, {
    "刚生成", "新生成", "生成的", "AI生成", "AI 生成", "刚才", "上一步", "上一条", "它", "它们", "这些", "这几个", "这批",
    "created.tracks", "created.items", "created.markers", "generated", "created", "newly created"
  })
end

local function operation_user_explicitly_first_track(text)
  return operation_text_has_any(text, {
    "第一轨", "第1轨", "第 1 轨", "1号轨", "一号轨", "轨道1", "轨道 1", "第一条轨", "第一个轨道",
    "index=0", "index 0", "track 1", "track #1", "first track"
  })
end

local function operation_region_delete_has_order_param(params)
  return operation_has_value(params, {
    "order", "order_index", "order_start", "order_end", "order_range",
    "ordinal", "ordinal_index", "ordinal_start", "ordinal_end", "ordinal_range",
    "sequence", "sequence_index", "sequence_start", "sequence_end", "sequence_range"
  })
end

local function operation_region_delete_explicit_id_text(text)
  local raw = tostring(text or "")
  local lower = raw:lower()
  return lower:match("[Rr]%s*%d+") ~= nil
    or lower:find("region id", 1, true) ~= nil
    or lower:find("region编号", 1, true) ~= nil
    or lower:find("region 编号", 1, true) ~= nil
    or lower:find("编号", 1, true) ~= nil
    or lower:find("id", 1, true) ~= nil
end

local function operation_region_delete_mentions_region(text)
  local raw = tostring(text or "")
  local lower = raw:lower()
  return lower:find("region", 1, true) ~= nil
    or raw:find("区域", 1, true) ~= nil
    or raw:find("区间", 1, true) ~= nil
end

local function operation_region_delete_has_numeric_range(text)
  local raw = tostring(text or "")
  return raw:match("%d+%s*%-%s*%d+") ~= nil
    or raw:match("%d+%s*~%s*%d+") ~= nil
    or raw:match("%d+%s*到%s*%d+") ~= nil
    or raw:match("%d+%s*至%s*%d+") ~= nil
end

local function operation_region_delete_order_ambiguous(user_text, params)
  params = params or {}
  if operation_region_delete_has_order_param(params) then return false end
  if operation_region_delete_explicit_id_text(user_text) then return false end
  if not operation_region_delete_mentions_region(user_text) then return false end
  if not operation_has_value(params, {"index", "id", "region", "target", "range", "ids", "start", "from"}) then return false end
  local raw = tostring(user_text or "")
  return raw:match("第%s*%d+") ~= nil or operation_region_delete_has_numeric_range(raw)
end

local function operation_user_mentions_export_format(text)
  text = tostring(text or "")
  local answer = text:match("%[USER_CLARIFICATION%]%s*(.-)%s*$") or text
  return operation_export_format_key(answer) ~= "" or operation_option_mentions_export_format(answer)
end

local function operation_implicit_first_track(endpoint, params, user_text)
  if not TRACK_CONTRACT_ENDPOINTS[endpoint] then return false end
  params = params or {}
  local value = operation_param_string(params, "index")
  if value == "" and (endpoint == "track/set_color" or endpoint == "track/add_fx" or endpoint == "track/remove_fx") then
    value = operation_param_string(params, "track")
  end
  if value ~= "0" then return false end
  if operation_user_explicitly_first_track(user_text) then return false end
  return true
end

local function operation_clarification(step, step_index, question, options, reason, protocol)
  protocol = protocol or {}
  step.needs_clarification = true
  step.status = "needs_clarification"
  step.clarification_reason = reason or question
  local choices, notes = operation_filter_clarification_choices_and_notes(question, protocol.choices or options or {}, protocol.notes or {}, protocol.fields or {}, protocol.intent or "")
  return {
    step_index = step_index,
    endpoint = step.endpoint or operation_endpoint(step.call or ""),
    question = question,
    options = choices,
    notes = notes,
    fields = protocol.fields or {},
    free_input = protocol.free_input ~= false,
    placeholder = protocol.placeholder or "",
    reason = reason or question,
  }
end

local function operation_collect_contract_clarifications(steps, user_text, intent)
  local clarifications = {}
  for i, step in ipairs(steps or {}) do
    if step.kind == "mcp" then
      local endpoint = step.endpoint or operation_endpoint(step.call or "")
      local params = step.params or select(2, operation_parse_call(step.call or "")) or {}

      if TRACK_CONTRACT_ENDPOINTS[endpoint] then
        local has_target = operation_has_explicit_track_target(endpoint, params)
        if not has_target then
          table.insert(clarifications, operation_clarification(
            step,
            i,
            "这一步会修改轨道，但计划里没有明确轨道目标。请确认要作用到哪里？",
            {},
            "track mutation without explicit target"
          ))
        elseif operation_implicit_first_track(endpoint, params, user_text) then
          table.insert(clarifications, operation_clarification(
            step,
            i,
            "这一步会修改轨道，但没有说清楚是本次计划中新建的轨道、当前选中轨道，还是工程里已有的某条轨道。请确认目标。",
            {"本次计划中新建的轨道", "当前选中轨道", "自定义轨道名"},
            "implicit first track target",
            { fields = {"target_track"}, free_input = true, placeholder = "输入已有轨道名，或点击上方目标" }
          ))
        elseif operation_user_mentions_generated_reference(user_text) then
          local _, key, value = operation_has_explicit_track_target(endpoint, params)
          local created_ref = operation_param_is_created_ref(value, "track")
          if not created_ref and (key == "index" or key == "track") and not operation_user_explicitly_first_track(user_text) then
            table.insert(clarifications, operation_clarification(
              step,
              i,
              "你的话像是在指本次计划中新建的轨道，但计划没有稳定绑定到它。请确认目标。",
              {"本次计划中新建的轨道", "当前选中轨道", "自定义轨道名"},
              "generated-reference wording with fixed track index",
              { fields = {"target_track"}, free_input = true, placeholder = "输入已有轨道名，或点击上方目标" }
            ))
          end
        end
        if endpoint == "track/add_fx" and not operation_has_value(params, {"fx", "fx_name", "effect", "plugin"}) then
          table.insert(clarifications, operation_clarification(
            step,
            i,
            "要添加哪个效果器？请填写效果器名称。",
            {},
            "track/add_fx missing FX name",
            { fields = {"fx_name"}, free_input = true, placeholder = "例如 ReaVerbate, ReaDelay, ReaPitch" }
          ))
        end
      elseif endpoint == "export/batch_regions" or endpoint == "export/tracks" or endpoint == "export/master" then
        local format = operation_param_string(params, "format"):lower()
        local format_key = operation_export_format_key(format)
        local user_named_format = operation_user_mentions_export_format(user_text)
        local export_target_label = "导出"
        if endpoint == "export/batch_regions" then
          export_target_label = "Region 导出"
        elseif endpoint == "export/tracks" then
          export_target_label = "轨道导出"
        elseif endpoint == "export/master" then
          export_target_label = "主控导出"
        end
        if format == "" or not user_named_format then
          table.insert(clarifications, operation_clarification(
            step,
            i,
            "你想把" .. export_target_label .. "为什么格式？请明确一个 REAPER 渲染格式。",
            operation_supported_export_options(),
            format == "" and "export format missing" or "export format inferred without user request",
            { fields = {"format"}, free_input = true }
          ))
          clarifications[#clarifications].fields = {"format"}
        elseif format_key == "" then
          table.insert(clarifications, operation_clarification(
            step,
            i,
            "当前格式不在 REAPER 渲染格式注册表中，不能靠改扩展名伪装 " .. format .. "。请选择或输入真实格式。",
            operation_supported_export_options(),
            "unsupported export format: " .. format,
            { fields = {"format"}, free_input = true }
          ))
          clarifications[#clarifications].fields = {"format"}
        end
      elseif endpoint == "region/delete" then
        if operation_region_delete_order_ambiguous(user_text, params) then
          table.insert(clarifications, operation_clarification(
            step,
            i,
            "你说的 Region 范围有两种理解：按 REAPER 编号 R5-R10 删除，还是按时间线排序删除第 5 到第 10 个 Region？",
            {"按编号删除", "按时间线顺序删除"},
            "region/delete ambiguous id range vs timeline order",
            {
              fields = {"region_delete_interpretation"},
              free_input = true,
              placeholder = "按编号 / 按时间线顺序",
              notes = {
                "按编号删除会使用 REAPER 的 R 编号，例如 R5-R10。",
                "按时间线顺序删除会按当前工程里 Region 从左到右的真实排序，例如第 5 到第 10 个。"
              }
            }
          ))
        elseif not operation_has_value(params, {
          "index", "id", "region", "target", "range", "ids", "start", "from", "name", "match",
          "order", "order_index", "order_start", "order_range",
          "ordinal", "ordinal_index", "ordinal_start", "ordinal_range",
          "sequence", "sequence_index", "sequence_start", "sequence_range"
        }) then
          table.insert(clarifications, operation_clarification(
            step,
            i,
            "要删除哪些 Region？请输入 Region 编号或范围，例如 15-20。",
            {},
            "region/delete missing region target",
            { fields = {"region_range"}, free_input = true, placeholder = "R15-R20 或按时间线第5-10个" }
          ))
        end
      elseif endpoint == "marker/delete" then
        if not operation_has_value(params, {"index", "target", "marker"}) then
          table.insert(clarifications, operation_clarification(
            step,
            i,
            "要删除哪个 Marker？请填写明确的 Marker 编号。",
            {},
            "marker/delete missing marker index",
            { fields = {"index"}, free_input = true, placeholder = "输入 Marker 编号" }
          ))
        end
      elseif endpoint == "item/fade" or endpoint == "item/set_fade" then
        if not operation_has_item_contract_target(params, false) then
          table.insert(clarifications, operation_clarification(
            step,
            i,
            "要给哪些素材设置淡入淡出？请说明素材目标。",
            {},
            "item/fade missing item target",
            { fields = {"target_item"}, free_input = true, placeholder = "描述要处理的素材目标" }
          ))
        end
        if not operation_has_value(params, {
          "fade_in", "in", "fadein", "fade_in_s", "in_s", "fade_in_sec", "in_sec", "fade_in_ms", "in_ms",
          "fade_out", "out", "fadeout", "fade_out_s", "out_s", "fade_out_sec", "out_sec", "fade_out_ms", "out_ms"
        }) then
          table.insert(clarifications, operation_clarification(
            step,
            i,
            "淡入或淡出要设置多久？请填写时间。",
            {},
            "item/fade missing fade duration",
            { fields = {"fade_duration"}, free_input = true, placeholder = "输入淡入/淡出时长" }
          ))
        end
      elseif endpoint == "item/fade_shape" or endpoint == "item/set_fade_shape" then
        if not operation_has_item_contract_target(params, true) then
          table.insert(clarifications, operation_clarification(
            step,
            i,
            "要修改哪些素材的 fade 曲线？请说明素材目标。",
            {},
            "item/fade_shape missing item target",
            { fields = {"target_item"}, free_input = true, placeholder = "描述要处理的素材目标" }
          ))
        end
      elseif endpoint == "envelope/draw" or endpoint == "envelope/clear" then
        if not operation_has_envelope_contract_target(params) then
          table.insert(clarifications, operation_clarification(
            step,
            i,
            "要处理哪条包络？请说明轨道、素材、Take 或当前选中的包络。",
            {},
            endpoint .. " missing envelope target",
            { fields = {"envelope_target"}, free_input = true, placeholder = "描述要处理的包络目标" }
          ))
        end
        if endpoint == "envelope/clear" and not operation_has_time_range(params) and operation_param_string(params, "target") ~= "selected_envelope" then
          table.insert(clarifications, operation_clarification(
            step,
            i,
            "要清理包络的哪个时间范围？请说明范围。",
            {},
            "envelope/clear missing range",
            { fields = {"time_range"}, free_input = true, placeholder = "输入要清理的时间范围" }
          ))
        end
      end
    end
  end
  return clarifications
end

local function operation_plan_clarification(question, options, reason, fields, protocol)
  protocol = protocol or {}
  local choices, notes = operation_filter_clarification_choices_and_notes(question, protocol.choices or options or {}, protocol.notes or {}, fields or {}, protocol.intent or "")
  return {
    step_index = 0,
    endpoint = "intent",
    question = question,
    options = choices,
    notes = notes,
    fields = fields or {},
    free_input = protocol.free_input ~= false,
    placeholder = protocol.placeholder or "",
    reason = reason or question,
  }
end

local function operation_filter_clarification_fields(fields, intent_name)
  local intent = tostring(intent_name or ""):lower()
  local result = {}
  for _, field in ipairs(fields or {}) do
    local f = tostring(field or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local lower = f:lower()
    local optional_export_dir = intent == "export" and (
      lower == "output_dir" or lower == "output_path" or lower == "save_dir" or
      lower == "save_path" or lower == "path" or lower == "directory"
    )
    if f ~= "" and not optional_export_dir then
      table.insert(result, f)
    end
  end
  return result
end

local function operation_default_intent_question(intent, effects)
  return "AI 未提供澄清问题，请取消后重新生成。", {}
end

local function operation_compile_plan(steps, user_text, llm_intent)
  local contract = operation_build_intent_contract(user_text)
  local intent = operation_infer_user_intent(user_text, contract, llm_intent)
  local effects = {}
  local issues = {}
  local clarifications = {}
  local user_risk = "normal"
  local risk_label = "普通操作"
  local action_labels = {}

  for step_index, step in ipairs(steps or {}) do
    local meta
    if step.kind == "mcp" then
      local endpoint, params = operation_parse_call(step.call or "")
      meta = operation_action_registry(endpoint) or { action = "custom", label = endpoint, effects = { modifies_project = true } }
      step.endpoint = endpoint
      step.params = params
      step.action = meta.action
      step.action_label = meta.label or endpoint
      step.effects = meta.effects or {}
      for _, issue in ipairs(operation_validate_mcp_params(endpoint, params)) do
        operation_mark_blocked(step, issue)
        table.insert(issues, "Step " .. tostring(step_index) .. " MCP: " .. issue)
      end
    elseif step.kind == "script" then
      meta = operation_script_effects(step.code or "")
      step.action = meta.action
      step.action_label = meta.label
      step.effects = meta.effects or {}
    else
      meta = { action = "custom", label = tostring(step.kind or "unknown"), effects = {} }
      step.action = meta.action
      step.action_label = meta.label
      step.effects = meta.effects
    end

    operation_merge_effects(effects, step.effects)
    operation_add_unique(action_labels, step.action_label or step.action or tostring(step.kind))
  end

  for _, clarification in ipairs(operation_collect_contract_clarifications(steps, user_text, intent)) do
    table.insert(clarifications, clarification)
  end

  if intent.needs_clarification then
    local q = ((llm_intent or {}).clarification_question) or ((llm_intent or {}).reason)
    local opts = ((llm_intent or {}).options) or {}
    local fields = operation_filter_clarification_fields((llm_intent or {}).fields or {}, intent.primary)
    if not q or q == "" then
      q, opts = operation_default_intent_question(intent, effects)
    end
    table.insert(clarifications, operation_plan_clarification(q, opts, "llm intent needs clarification", fields, {
      notes = (llm_intent or {}).notes or {},
      free_input = (llm_intent or {}).free_input,
      placeholder = (llm_intent or {}).placeholder or "",
      intent = (llm_intent or {}).intent or intent.primary,
    }))
  end
  if PlanContract and type(PlanContract.merge_clarifications) == "function" then
    clarifications = PlanContract.merge_clarifications(clarifications, steps, user_text, intent) or clarifications
  end
  if effects.deletes_project or effects.clears_project or effects.deletes_disk or effects.saves_project then
    user_risk = "destructive"
    risk_label = "删除/覆盖操作"
  elseif effects.exports_file or effects.writes_disk then
    user_risk = "file_write"
    risk_label = "导出/写入文件"
  elseif effects.batch then
    user_risk = "batch"
    risk_label = "批量操作"
  elseif effects.modifies_project then
    user_risk = "normal"
    risk_label = "普通操作"
  elseif effects.analysis_side_effect or effects.changes_time_selection or effects.moves_cursor or effects.changes_selection then
    user_risk = "analysis_state"
    risk_label = "Analysis/Locate"
  else
    user_risk = "read_only"
    risk_label = "查询/分析"
  end

  local function block_step(step, index, reason)
    operation_mark_blocked(step, reason)
    table.insert(issues, "Step " .. tostring(index) .. ": " .. reason)
  end

  local function clarify_step(step, index, question, options, reason)
    table.insert(clarifications, operation_clarification(step, index, question, options, reason))
  end

  if not intent.needs_clarification and intent.wants_read_only and operation_read_only_conflict_effects(effects) then
    for i, step in ipairs(steps or {}) do
      if step.effects and operation_read_only_conflict_effects(step.effects) then
        clarify_step(step, i, "AI 识别为查询/查看，但生成的计划会修改工程或写入文件。请重新说明你要查看还是要执行修改。", {}, "query intent conflicts with write plan")
      end
    end
  end

  if not intent.needs_clarification and not intent.wants_delete and not intent.wants_freeze and (effects.deletes_project or effects.clears_project) then
    for i, step in ipairs(steps or {}) do
      if step.effects and (step.effects.deletes_project or step.effects.clears_project) then
        clarify_step(step, i, "AI 生成的计划会删除/清空工程对象，但识别到的意图不是删除。请重新说明是否要删除。", {}, "delete plan conflicts with recognized intent")
      end
    end
  end

  if not intent.needs_clarification and not intent.wants_delete and effects.deletes_disk then
    for i, step in ipairs(steps or {}) do
      if step.effects and step.effects.deletes_disk then
        clarify_step(step, i, "AI 生成的计划会删除磁盘文件，但识别到的意图不是文件删除。请重新说明是否要删除文件。", {}, "disk delete plan conflicts with recognized intent")
      end
    end
  end

  if not intent.needs_clarification and not intent.wants_export and not intent.wants_overwrite and not intent.wants_freeze and (effects.saves_project or effects.exports_file) then
    for i, step in ipairs(steps or {}) do
      if step.effects and (step.effects.saves_project or step.effects.exports_file) then
        clarify_step(step, i, "AI 生成的计划会导出或保存文件，但识别到的意图不是导出/保存。请重新说明是否要写入文件。", {}, "export plan conflicts with recognized intent")
      end
    end
  end

  if not intent.needs_clarification and intent.wants_rename and not intent.wants_delete and (effects.deletes_project or effects.clears_project) then
    for i, step in ipairs(steps or {}) do
      if step.effects and (step.effects.deletes_project or step.effects.clears_project) then
        clarify_step(step, i, "AI 识别为改名/命名，但生成的计划会删除/清空对象。请重新说明你要改名还是删除。", {}, "rename intent conflicts with delete plan")
      end
    end
  end

  local forbidden = contract.forbidden or {}
  if forbidden.delete_project and (effects.deletes_project or effects.clears_project) then
    for i, step in ipairs(steps or {}) do
      if step.effects and (step.effects.deletes_project or step.effects.clears_project) then
        block_step(step, i, "用户明确禁止删除/清空工程对象")
      end
    end
  end

  if forbidden.delete_disk and effects.deletes_disk then
    for i, step in ipairs(steps or {}) do
      if step.effects and step.effects.deletes_disk then
        block_step(step, i, "用户明确禁止删除磁盘文件")
      end
    end
  end

  if forbidden.export_file and effects.exports_file then
    for i, step in ipairs(steps or {}) do
      if step.effects and step.effects.exports_file then
        block_step(step, i, "用户明确禁止导出/渲染文件")
      end
    end
  end

  if (forbidden.write_file or forbidden.overwrite) and (effects.writes_disk or effects.saves_project) then
    for i, step in ipairs(steps or {}) do
      if step.effects and (step.effects.writes_disk or step.effects.saves_project) then
        block_step(step, i, forbidden.overwrite and "用户明确禁止覆盖/写入文件" or "用户明确禁止写入或保存文件")
      end
    end
  end

  if PlanContract and type(PlanContract.merge_clarifications) == "function" then
    clarifications = PlanContract.merge_clarifications(clarifications, steps, user_text, intent) or clarifications
  end

  return {
    contract = contract,
    intent = intent,
    effects = effects,
    issues = issues,
    clarifications = clarifications,
    needs_clarification = #clarifications > 0,
    user_risk = user_risk,
    risk_label = risk_label,
    action_labels = action_labels,
  }
end

local function operation_preflight_steps(steps)
  local issues = {}
  local total_script = 0
  for _, step in ipairs(steps or {}) do
    if step.kind == "script" then total_script = total_script + 1 end
  end
  
  local script_index = 0
  for step_index, step in ipairs(steps or {}) do
    if step.kind == "script" then
      script_index = script_index + 1
      if step.valid == false then
        step.status = "blocked"
        step.error = tostring(step.validation_error or "SCRIPT 校验失败")
        step.precheck_error = step.error
        step.blocked_reason = step.error
        table.insert(issues, "Step " .. step_index .. " SCRIPT " .. script_index .. "/" .. total_script .. ": " .. step.error)
      end
    elseif step.kind == "mcp" then
      local endpoint = operation_parse_call(step.call or "")
      if not operation_known_mcp_endpoint(endpoint) then
        step.status = "blocked"
        step.error = "未知 MCP endpoint: " .. tostring(endpoint)
        step.precheck_error = step.error
        step.blocked_reason = step.error
        table.insert(issues, "Step " .. step_index .. " MCP: " .. step.error)
      end
    else
      step.status = "blocked"
      step.error = "未知 step 类型: " .. tostring(step.kind)
      step.precheck_error = step.error
      step.blocked_reason = step.error
      table.insert(issues, "Step " .. step_index .. ": " .. step.error)
    end
  end
  
  return #issues == 0, issues
end

local function operation_analyze_steps(steps)
  local risk = "low"
  local reasons = {}
  local scopes = operation_context_scope_lines()
  local mcp_count = 0
  local script_count = 0
  
  for _, step in ipairs(steps or {}) do
    if step.kind == "mcp" then
      mcp_count = mcp_count + 1
      local endpoint, params = operation_parse_call(step.call or "")
      risk = operation_raise_risk(risk, operation_mcp_risk(endpoint, params, reasons, scopes))
    elseif step.kind == "script" then
      script_count = script_count + 1
      risk = operation_raise_risk(risk, operation_script_risk(step.code, reasons, scopes))
    end
  end
  
  if mcp_count + script_count > 8 then
    risk = operation_raise_risk(risk, "medium")
    operation_add_unique(reasons, "步骤较多: " .. tostring(mcp_count + script_count))
  end
  if #reasons == 0 then
    operation_add_unique(reasons, "低风险参数/状态操作")
  end
  
  return {
    risk = risk,
    reasons = reasons,
    scopes = scopes,
  }
end

local function operation_risk_label(risk)
  if risk == "blocked" then return "不可执行" end
  if risk == "high" then return "高风险" end
  if risk == "medium" then return "中风险" end
  return "低风险"
end

local function operation_build_summary(mcp_calls, script_count)
  local parts = {}
  local endpoints = {}
  local counts = {}
  for _, call in ipairs(mcp_calls or {}) do
    local ep = operation_endpoint(call)
    if ep ~= "" then
      if not counts[ep] then
        counts[ep] = 0
        table.insert(endpoints, ep)
      end
      counts[ep] = counts[ep] + 1
    end
  end
  
  if #endpoints > 0 then
    local labels = {}
    for _, ep in ipairs(endpoints) do
      local count = counts[ep] or 0
      table.insert(labels, count > 1 and (ep .. " x" .. tostring(count)) or ep)
    end
    table.insert(parts, "MCP: " .. table.concat(labels, ", "))
  end
  if script_count and script_count > 0 then
    table.insert(parts, "SCRIPT 块: " .. tostring(script_count))
  end
  if #parts == 0 then
    return "无可执行内容"
  end
  return table.concat(parts, " | ")
end

local function operation_step_label(step, index)
  if not step then return "Step " .. tostring(index) .. ": unknown" end
  if step.kind == "mcp" then
    return "Step " .. tostring(index) .. " MCP: " .. operation_endpoint(step.call or "")
  elseif step.kind == "script" then
    return "Step " .. tostring(index) .. " SCRIPT"
  end
  return "Step " .. tostring(index) .. ": " .. tostring(step.kind or "unknown")
end

local function create_operation_from_response(text, parse_executable_steps, user_text)
  local llm_intent = operation_parse_llm_intent(text)
  local parts = parse_executable_steps and parse_executable_steps(text) or {}
  if #parts == 0 then
    if llm_intent and llm_intent.needs_clarification then
      local q = llm_intent.clarification_question or llm_intent.reason or "AI 未提供澄清问题，请取消后重新生成。"
      local opts = llm_intent.options or {}
      return {
        id = operation_new_id(),
        source = "intent",
        status = "pending",
        user_request = tostring(user_text or ""),
        raw_text = text,
        mcp_calls = {},
        script_count = 0,
        parts = {},
        summary = "Intent clarification",
        risk = "needs_clarification",
        user_risk = "normal",
        user_risk_label = "Needs clarification",
        intent_contract = operation_build_intent_contract(user_text),
        plan_intent = operation_apply_llm_intent(user_text, operation_build_intent_contract(user_text), llm_intent),
        llm_intent = llm_intent,
        plan_effects = {},
        plan_actions = {},
        contract_status = "needs_clarification",
        needs_clarification = true,
        clarification_questions = { operation_plan_clarification(q, opts, "llm requested clarification", operation_filter_clarification_fields(llm_intent.fields or {}, llm_intent.intent), {
          notes = llm_intent.notes or {},
          free_input = llm_intent.free_input,
          placeholder = llm_intent.placeholder or "",
          intent = llm_intent.intent,
        }) },
        clarification_prompt = q,
        clarification_options = opts,
        risk_reasons = {},
        scope_lines = {},
        rewrite_notes = {},
        preflight_ok = false,
        preflight_issues = {},
        created_at = reaper.time_precise(),
      }
    end
    return nil
  end
  local rewrite_notes = operation_rewrite_mcp_first(parts)
  
  local mcp_calls = {}
  local script_count = 0
  for _, part in ipairs(parts) do
    part.status = "pending"
    if part.kind == "mcp" then
      local endpoint, params = operation_parse_call(part.call or "")
      if endpoint ~= "" then
        part.endpoint = endpoint
        part.params = params
        part.call = operation_build_call(endpoint, params)
      end
      table.insert(mcp_calls, part.call or "")
    elseif part.kind == "script" then
      script_count = script_count + 1
    end
  end
  
  local preflight_ok, preflight_issues = operation_preflight_steps(parts)
  local plan = operation_compile_plan(parts, user_text, llm_intent)
  for _, issue in ipairs(plan.issues or {}) do
    table.insert(preflight_issues, issue)
  end
  local needs_clarification = plan.needs_clarification == true
  preflight_ok = preflight_ok and #(plan.issues or {}) == 0 and not needs_clarification
  local analysis = operation_analyze_steps(parts)
  for _, note in ipairs(rewrite_notes or {}) do
    operation_add_unique(analysis.reasons, note)
  end
  local risk = needs_clarification and "needs_clarification" or (preflight_ok and analysis.risk or "blocked")
  local first_clarification = (plan.clarifications or {})[1]
  local clarification_prompt = first_clarification and first_clarification.question or nil
  local clarification_options = first_clarification and first_clarification.options or {}
  return {
    id = operation_new_id(),
    source = (#mcp_calls > 0 and script_count > 0) and "mixed" or (#mcp_calls > 0 and "mcp" or "script"),
    status = "pending",
    user_request = tostring(user_text or ""),
    raw_text = text,
    mcp_calls = mcp_calls,
    script_count = script_count,
    parts = parts,
    summary = operation_build_summary(mcp_calls, script_count),
    risk = risk,
    user_risk = plan.user_risk or "normal",
    user_risk_label = plan.risk_label or "普通操作",
    intent_contract = plan.contract or {},
    plan_intent = plan.intent or {},
    llm_intent = llm_intent or {},
    plan_effects = plan.effects or {},
    plan_actions = plan.action_labels or {},
    contract_status = needs_clarification and "needs_clarification" or (preflight_ok and "executable" or "blocked"),
    needs_clarification = needs_clarification,
    clarification_questions = plan.clarifications or {},
    clarification_prompt = clarification_prompt,
    clarification_options = clarification_options,
    risk_reasons = analysis.reasons or {},
    scope_lines = analysis.scopes or {},
    rewrite_notes = rewrite_notes or {},
    preflight_ok = preflight_ok,
    preflight_issues = preflight_issues or {},
    created_at = reaper.time_precise(),
  }
end

local function operation_set_plan_contract(plan_contract)
  PlanContract = plan_contract
end

Operation.new_id = operation_new_id
Operation.count_script_blocks = count_script_blocks
Operation.parse_executable_steps = operation_parse_executable_steps
Operation.count_steps_by_kind = operation_count_steps_by_kind
Operation.preflight_execution_steps = operation_preflight_execution_steps
Operation.endpoint = operation_endpoint
Operation.parse_call = operation_parse_call
Operation.build_call = operation_build_call
Operation.action_registry = operation_action_registry
Operation.action_registry_table = ACTION_REGISTRY
Operation.action_contract = operation_action_contract
Operation.known_mcp_endpoint = operation_known_mcp_endpoint
Operation.set_capability_registry = operation_set_capability_registry
Operation.set_plan_contract = operation_set_plan_contract
Operation.add_unique = operation_add_unique
Operation.raise_risk = operation_raise_risk
Operation.target_text = operation_target_text
Operation.context_scope_lines = operation_context_scope_lines
Operation.mcp_risk = operation_mcp_risk
Operation.script_risk = operation_script_risk
Operation.parse_llm_intent = operation_parse_llm_intent
Operation.infer_user_intent = operation_infer_user_intent
Operation.script_effects = operation_script_effects
Operation.compile_plan = operation_compile_plan
Operation.preflight_steps = operation_preflight_steps
Operation.analyze_steps = operation_analyze_steps
Operation.risk_label = operation_risk_label
Operation.build_summary = operation_build_summary
Operation.step_label = operation_step_label
Operation.create_from_response = create_operation_from_response

return Operation
