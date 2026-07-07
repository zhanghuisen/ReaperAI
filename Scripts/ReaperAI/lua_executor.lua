local LuaExecutor = {}
local Capabilities = nil
local CapabilityRegistry = nil

local native_action_registry = {}

local function normalize_action_id(id)
  id = tostring(id or ""):gsub("^%s+", ""):gsub("%s+$", "")
  return id
end

local function register_native_action(entry)
  if Capabilities and type(Capabilities.register_action) == "function" then
    return Capabilities.register_action(entry)
  end
  if type(entry) ~= "table" then return false end
  local id = normalize_action_id(entry.id or entry.command_id or entry.command)
  if id == "" then return false end
  native_action_registry[id] = {
    id = id,
    name = tostring(entry.name or entry.label or ""),
    section = tostring(entry.section or "main"),
    source = tostring(entry.source or "user_confirmed"),
    allowed_in_script = entry.allowed_in_script == true,
    action = tostring(entry.action or "native_action"),
    target = tostring(entry.target or "native_action"),
    verifier = entry.verifier,
    verifier_strength = tostring(entry.verifier_strength or "observed"),
    effects = entry.effects or {},
  }
  return true
end

local function native_action_entry(id)
  if Capabilities and type(Capabilities.action_entry) == "function" then
    return Capabilities.action_entry(id)
  end
  if CapabilityRegistry and type(CapabilityRegistry.native_action_entry) == "function" then
    return CapabilityRegistry.native_action_entry(id)
  end
  return native_action_registry[normalize_action_id(id)]
end

local function set_capabilities(provider)
  Capabilities = provider
end

local function set_capability_registry(provider)
  CapabilityRegistry = provider
end

local function load_native_action_registry(entries)
  if Capabilities and type(Capabilities.load_action_inventory) == "function" then
    return Capabilities.load_action_inventory(entries)
  end
  native_action_registry = {}
  local count = 0
  for _, entry in ipairs(entries or {}) do
    if register_native_action(entry) then count = count + 1 end
  end
  return count
end

local function build_sandbox_math()
  local safe_math = {}
  for k, v in pairs(math) do
    safe_math[k] = v
  end
  safe_math.pow = safe_math.pow or function(a, b)
    return a ^ b
  end
  return safe_math
end

local function sandbox_print(...)
  local args = {...}
  for i = 1, #args do
    args[i] = tostring(args[i])
  end
  return table.concat(args, "\t")
end

local function build_sandbox_env()
  return {
    reaper = reaper,
    math = build_sandbox_math(),
    string = string,
    table = table,
    tonumber = tonumber,
    tostring = tostring,
    ipairs = ipairs,
    pairs = pairs,
    pcall = pcall,
    type = type,
    print = sandbox_print,
  }
end

local function compile_script(src, desc)
  return load(tostring(src or ""), desc or "AI_SCRIPT", "t", build_sandbox_env())
end

local function precheck_compile(src, desc)
  local func, compile_err = compile_script(src, desc or "AI_SCRIPT_PRECHECK")
  if not func then
    return false, "编译错误: " .. tostring(compile_err)
  end
  return true, nil
end

local function strip_lua_comments_and_strings(src)
  src = tostring(src or "")
  local out = {}
  local i = 1
  local len = #src
  local quote = nil
  local long_string = false
  while i <= len do
    local c = src:sub(i, i)
    local n = src:sub(i, i + 1)
    local four = src:sub(i, i + 3)
    if long_string then
      if n == "]]" then
        long_string = false
        table.insert(out, "  ")
        i = i + 2
      else
        table.insert(out, c == "\n" and "\n" or " ")
        i = i + 1
      end
    elseif quote then
      if c == "\\" then
        table.insert(out, "  ")
        i = i + 2
      elseif c == quote then
        quote = nil
        table.insert(out, " ")
        i = i + 1
      else
        table.insert(out, c == "\n" and "\n" or " ")
        i = i + 1
      end
    elseif four == "--[[" then
      long_string = true
      table.insert(out, "    ")
      i = i + 4
    elseif n == "--" then
      while i <= len and src:sub(i, i) ~= "\n" do
        table.insert(out, " ")
        i = i + 1
      end
    elseif n == "[[" then
      long_string = true
      table.insert(out, "  ")
      i = i + 2
    elseif c == "'" or c == '"' then
      quote = c
      table.insert(out, " ")
      i = i + 1
    else
      table.insert(out, c)
      i = i + 1
    end
  end
  return table.concat(out)
end

local function collect_reaper_api_calls(src)
  local cleaned = strip_lua_comments_and_strings(src)
  local names = {}
  local seen = {}
  for name in cleaned:gmatch("reaper%s*%.%s*([%a_][%w_]*)%s*%(") do
    if not seen[name] then
      seen[name] = true
      table.insert(names, name)
    end
  end
  return names
end

local function precheck_reaper_api(src)
  if Capabilities and type(Capabilities.validate_lua) == "function" then
    return Capabilities.validate_lua(src)
  end
  local blacklist = {
    MoveRegion = "reaper.MoveRegion 不存在，请改用 SetProjectMarker / SetProjectMarker3",
  }
  for _, name in ipairs(collect_reaper_api_calls(src)) do
    if blacklist[name] then return false, blacklist[name] end
    if reaper and type(reaper.APIExists) == "function" then
      local ok, exists = pcall(reaper.APIExists, name)
      if ok and exists == false then
        return false, "REAPER API 不存在: reaper." .. tostring(name) .. "；请改用本机 REAPER 真实存在的 API"
      end
    elseif reaper and reaper[name] ~= nil and type(reaper[name]) ~= "function" then
      return false, "REAPER API 不存在: reaper." .. tostring(name) .. "；请改用本机 REAPER 真实存在的 API"
    end
  end
  return true, nil
end

local function split_lua_args(args)
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
      local value = table.concat(current)
      value = value:gsub("^%s+", "")
      value = value:gsub("%s+$", "")
      table.insert(result, value)
      current = {}
    else
      table.insert(current, c)
    end
    i = i + 1
  end
  local last = table.concat(current)
  last = last:gsub("^%s+", "")
  last = last:gsub("%s+$", "")
  if last ~= "" or #result > 0 then table.insert(result, last) end
  return result
end

local function main_on_command_args(src)
  local code = strip_lua_comments_and_strings(src)
  local patterns = {
    "reaper%s*%.%s*Main_OnCommand%s*%(" ,
    "%f[%w_]Main_OnCommand%s*%(" ,
  }
  local found = {}
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
    local parsed = split_lua_args(table.concat(args))
    table.insert(found, (#parsed > 0) and parsed[1] or "")
    search_pos = math.max(i, best_e + 1)
  end
  return found
end

local function precheck_reaper_api_args(src)
  local code = strip_lua_comments_and_strings(src)
  for args in code:gmatch("reaper%s*%.%s*SetProjectMarker3%s*%(([^%)]*)%)") do
    if #split_lua_args(args) < 7 then
      return false, "reaper.SetProjectMarker3 需要 7 个参数：proj, markrgnindexnumber, isrgn, pos, rgnend, name, color；请补 color 或 0"
    end
  end
  return true, nil
end

local function precheck_dangerous_loops(src)
  local code = strip_lua_comments_and_strings(src)
  local has_math_huge_loop = code:match("for%s+[%w_]+%s*=%s*[^,\n]+,%s*math%s*%.%s*huge%s+do") ~= nil
  local has_while_true = code:match("while%s+true%s+do") ~= nil
  if has_math_huge_loop then
    return false, "SCRIPT 使用 math.huge 作为循环上限，可能卡死 REAPER；遍历 marker/region 请先用 CountProjectMarkers() 取得有限数量"
  end
  if has_while_true then
    return false, "SCRIPT 包含 while true do，可能卡死 REAPER；请改为有限循环并设置明确上限"
  end
  if (code:match("EnumProjectMarkers3%s*%(") or code:match("EnumProjectMarkers%s*%(")) and code:match("not%s+ret%f[^%w_]") then
    return false, "SCRIPT 错误使用 EnumProjectMarkers 返回值：ret=0 不会触发 not ret，遍历 marker/region 请使用 CountProjectMarkers() 的有限循环"
  end
  return true, nil
end

local function validate_script_step(block)
  block = tostring(block or "")
  if block:find("[MCP_CALL:", 1, true) then
    return false, "SCRIPT 边界污染：脚本内包含 [MCP_CALL:] 标记"
  end
  if block:find("[SCRIPT]", 1, true) then
    return false, "SCRIPT 边界污染：脚本内包含 [SCRIPT] 标记"
  end
  if block:find("[/SCRIPT]", 1, true) then
    return false, "SCRIPT 边界污染：脚本内包含 [/SCRIPT] 标记"
  end
  for _, action_arg in ipairs(main_on_command_args(block)) do
    local action_id = tostring(action_arg or ""):match("^%-?%d+$") and action_arg or nil
    if not action_id then
      return false, "SCRIPT uses an unverified reaper.Main_OnCommand argument; Native Action must be registered as a trusted numeric ID first"
    end
    local entry = native_action_entry(action_id)
    if not entry then
      return false, "SCRIPT uses unregistered REAPER Action ID " .. tostring(action_id) .. "; import and confirm it from the local Action List/config first"
    end
  end
  if block:match("D_FADEINSHAPE") or block:match("D_FADEOUTSHAPE") then
    return false, "SCRIPT 使用了错误的 fade shape 属性名：请用 item/fade_shape endpoint，或使用 C_FADEINSHAPE/C_FADEOUTSHAPE 并读回校验"
  end
  local compile_ok, compile_err = precheck_compile(block, "AI_SCRIPT_PRECHECK")
  if not compile_ok then
    return false, compile_err
  end
  local api_ok, api_err = precheck_reaper_api(block)
  if not api_ok then
    return false, api_err
  end
  local api_args_ok, api_args_err = precheck_reaper_api_args(block)
  if not api_args_ok then
    return false, api_args_err
  end
  local loop_ok, loop_err = precheck_dangerous_loops(block)
  if not loop_ok then
    return false, loop_err
  end
  return true, nil
end

local function is_failure_result_text(text)
  text = tostring(text or "")
  text = text:gsub("^%s+", ""):gsub("%s+$", "")
  local lower = text:lower()
  return text == ""
    or text:match("^✗")
    or text:match("^❌")
    or text:match("^⚠️")
    or text:match("^⚠")
    or lower:match("^false")
    or lower:match("^nil")
    or lower:match("^error")
    or text:match("^Track not found")
    or text:match("^Please provide")
    or lower:match("^failed")
    or lower:match("^failure")
    or lower:match("^cannot")
    or lower:match("^unable")
    or lower:match("not found")
    or lower:match("^missing")
    or text:match("^轨道不存在")
    or text:match("^请提供")
    or text:match("^请先")
    or text:match("^错误")
    or text:match("^失败")
    or text:match("^无法")
    or text:match("^不能")
    or text:match("^未能")
    or text:match("^没有")
    or text:match("^未找到")
    or text:match("^找不到")
    or text:match("不存在")
end

local function stable_value_to_text(value, depth)
  depth = depth or 0
  local value_type = type(value)
  if value == nil then
    return ""
  elseif value_type == "string" then
    return value
  elseif value_type == "number" or value_type == "boolean" then
    return tostring(value)
  elseif value_type ~= "table" then
    return tostring(value)
  end
  
  if depth >= 2 then
    return "{...}"
  end
  
  local parts = {}
  local array_count = #value
  for i = 1, array_count do
    table.insert(parts, stable_value_to_text(value[i], depth + 1))
  end
  
  local keyed_count = 0
  for k, v in pairs(value) do
    local is_array_key = type(k) == "number" and k >= 1 and k <= array_count and math.floor(k) == k
    if not is_array_key then
      keyed_count = keyed_count + 1
      if keyed_count <= 6 then
        table.insert(parts, tostring(k) .. "=" .. stable_value_to_text(v, depth + 1))
      end
    end
  end
  if keyed_count > 6 then
    table.insert(parts, "...")
  end
  
  return "{" .. table.concat(parts, ", ") .. "}"
end

local function stable_changed_summary(changed)
  if changed == nil then return nil end
  if type(changed) == "table" then
    return stable_value_to_text(changed)
  end
  return stable_value_to_text(changed)
end

local function stable_table_result_text(result)
  local message = result.message or result.msg or result.summary or result.result
  if message == nil and result.error ~= nil then message = result.error end
  if message == nil and result.reason ~= nil then message = result.reason end
  if message == nil and result[1] ~= nil then message = result[1] end
  
  local text = stable_value_to_text(message)
  local detail = stable_changed_summary(result.stats or result.data or result.counts)
  if text == "" then
    local parts = {}
    if result.ok ~= nil then table.insert(parts, "ok=" .. tostring(result.ok)) end
    if result.success ~= nil then table.insert(parts, "success=" .. tostring(result.success)) end
    local changed = stable_changed_summary(result.changed or result.changes)
    if changed then table.insert(parts, "changed=" .. changed) end
    if detail then table.insert(parts, "stats=" .. detail) end
    if result.count ~= nil then table.insert(parts, "count=" .. stable_value_to_text(result.count)) end
    text = #parts > 0 and table.concat(parts, "；") or stable_value_to_text(result)
  else
    local changed = stable_changed_summary(result.changed or result.changes)
    if changed and not text:lower():match("changed") and not text:match("修改") then
      text = text .. "；changed=" .. changed
    end
    if detail and not text:lower():match("stats") and not text:match("统计") then
      text = text .. "；stats=" .. detail
    end
  end
  
  return text
end

local function normalize_lua_return(result, detail, require_result)
  if result == nil then
    if detail ~= nil and tostring(detail) ~= "" then
      return nil, tostring(detail)
    end
    if require_result then
      return nil, "SCRIPT 返回 nil，判定为失败；请 return 明确成功 table/string 或失败原因"
    end
    return "执行成功", nil
  end
  
  if result == false then
    local reason = detail ~= nil and tostring(detail) or "SCRIPT 返回 false，判定为失败"
    return nil, reason
  end
  
  if type(result) == "table" then
    local explicit_ok = result.ok
    if explicit_ok == nil then explicit_ok = result.success end
    local text = stable_table_result_text(result)
    if explicit_ok == false then
      return nil, text ~= "" and text or "SCRIPT 返回 ok=false，判定为失败"
    end
    if explicit_ok == nil and (result.error ~= nil or result.reason ~= nil) then
      return nil, text ~= "" and text or "SCRIPT 返回错误信息，判定为失败"
    end
    if is_failure_result_text(text) then
      return nil, text
    end
    return text ~= "" and text or "SCRIPT 返回 table", nil
  end
  
  local text = stable_value_to_text(result)
  if is_failure_result_text(text) then
    return nil, text ~= "" and text or "SCRIPT 返回空字符串，判定为失败"
  end
  return text, nil
end

local function fix_common_errors(src)
  src = tostring(src or "")
  src = src:gsub("\nreturn%s*\\%s*\n", "\nreturn '完成'\n")
  src = src:gsub("\nreturn%s*\\%s*$", "\nreturn '完成'")
  
  src = src:gsub("local%s+(%w+)%s*=%s*reaper%.InsertTrackAtIndex%(([^%)]+)%)%s*\n", function(var, args)
    return "reaper.InsertTrackAtIndex(" .. args .. ")\nlocal " .. var .. " = reaper.GetTrack(0, reaper.CountTracks(0) - 1)\n"
  end)
  src = src:gsub("local%s+(%w+)%s*=%s*reaper%.InsertTrackAtIndex%(([^%)]+)%)%s*$", function(var, args)
    return "reaper.InsertTrackAtIndex(" .. args .. ")\nlocal " .. var .. " = reaper.GetTrack(0, reaper.CountTracks(0) - 1)"
  end)
  return src
end

local function compile_and_exec(src, desc, require_result)
  local func, compile_err = compile_script(src, desc or "AI_SCRIPT")
  if not func then
    return nil, compile_err, "compile"
  end
  local undo_open = false
  if reaper and reaper.Undo_BeginBlock then
    undo_open = pcall(reaper.Undo_BeginBlock)
  end
  local success, result, detail = pcall(func)
  if reaper and reaper.UpdateArrange then pcall(reaper.UpdateArrange) end
  if undo_open and reaper and reaper.Undo_EndBlock then
    pcall(reaper.Undo_EndBlock, desc or "ReaperAI SCRIPT", -1)
  end
  if not success then
    return nil, "运行时错误: " .. tostring(result), "runtime"
  end
  local normalized, result_error = normalize_lua_return(result, detail, require_result)
  if not normalized then
    return nil, result_error, "result"
  end
  return normalized, nil, "ok"
end

local function is_truncation_error(err_msg, src)
  err_msg = tostring(err_msg)
  if err_msg:match("unexpected symbol near") or
     err_msg:match("'%)' expected") or
     err_msg:match("'%]' expected") or
     err_msg:match("'end' expected") or
     err_msg:match("<eof> expected") or
     tostring(src or ""):match("\\%s*$") then
    return true
  end
  return false
end

local function execute_lua_sandbox(code, description, require_result)
  code = fix_common_errors(code)
  local compile_ok, compile_err = precheck_compile(code, description or "AI_SCRIPT_PRECHECK")
  if not compile_ok then
    if is_truncation_error(compile_err, code) then
      return nil, "代码不完整（可能被截断），已停止执行；请重新生成操作卡后再确认: " .. tostring(compile_err)
    end
    return nil, compile_err
  end
  local api_ok, api_err = precheck_reaper_api(code)
  if not api_ok then
    return nil, api_err
  end
  local api_args_ok, api_args_err = precheck_reaper_api_args(code)
  if not api_args_ok then
    return nil, api_args_err
  end
  local loop_ok, loop_err = precheck_dangerous_loops(code)
  if not loop_ok then
    return nil, loop_err
  end
  local result, err, err_kind = compile_and_exec(code, description, require_result)
  if result then
    return result, nil
  end
  
  if err_kind ~= "compile" then
    return nil, tostring(err)
  end
  
  if not is_truncation_error(err, code) then
    return nil, "编译错误: " .. tostring(err)
  end
  
  return nil, "代码不完整（可能被截断），已停止执行；请重新生成操作卡后再确认: " .. tostring(err)
end

local function execute_mcp_lua(code, description)
  code = fix_common_errors(code)
  local compile_ok, compile_err = precheck_compile(code, description or "MCP_LUA_PRECHECK")
  if not compile_ok then
    return nil, compile_err
  end
  local api_ok, api_err = precheck_reaper_api(code)
  if not api_ok then
    return nil, api_err
  end
  local api_args_ok, api_args_err = precheck_reaper_api_args(code)
  if not api_args_ok then
    return nil, api_args_err
  end
  local loop_ok, loop_err = precheck_dangerous_loops(code)
  if not loop_ok then
    return nil, loop_err
  end
  local result, err, err_kind = compile_and_exec(code, description or "MCP_LUA", false)
  if result then
    return result, nil
  end
  if err_kind == "compile" then
    return nil, "编译错误: " .. tostring(err)
  end
  return nil, tostring(err)
end

LuaExecutor.validate_script_step = validate_script_step
LuaExecutor.set_api_gate = set_capabilities
LuaExecutor.set_capabilities = set_capabilities
LuaExecutor.set_capability_registry = set_capability_registry
LuaExecutor.register_native_action = register_native_action
LuaExecutor.load_native_action_registry = load_native_action_registry
LuaExecutor.native_action_entry = native_action_entry
LuaExecutor.precheck_compile = precheck_compile
LuaExecutor.strip_comments_and_strings = strip_lua_comments_and_strings
LuaExecutor.precheck_reaper_api = precheck_reaper_api
LuaExecutor.precheck_reaper_api_args = precheck_reaper_api_args
LuaExecutor.precheck_dangerous_loops = precheck_dangerous_loops
LuaExecutor.is_failure_result_text = is_failure_result_text
LuaExecutor.value_to_text = stable_value_to_text
LuaExecutor.normalize_return = normalize_lua_return
LuaExecutor.execute_sandbox = execute_lua_sandbox
LuaExecutor.execute_mcp_lua = execute_mcp_lua

return LuaExecutor
