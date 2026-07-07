-- ReaperAI local REAPER capability layer.
-- Owns API existence checks, native Action inventory, and extension flags.

local ReaperCapabilities = {}

function ReaperCapabilities.create(options)
  options = options or {}
  local M = {}
  local api_inventory = {}
  local api_inventory_path = nil
  local api_inventory_loaded = false
  local api_inventory_count = 0
  local action_inventory = {}
  local action_inventory_loaded = false
  local action_inventory_path = nil
  local action_inventory_count = 0
  local extension_cache = {}

  local function trim(value)
    return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
  end

  local function path_join(a, b)
    a = tostring(a or "")
    b = tostring(b or "")
    local sep = package and package.config and package.config:sub(1, 1) or "/"
    if a:sub(-1) == "/" or a:sub(-1) == "\\" then
      return a .. b
    end
    return a .. sep .. b
  end

  local function read_file(path)
    if not io or type(io.open) ~= "function" then return nil end
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a") or ""
    f:close()
    return content
  end

  local function extract_json_string_array(content, key)
    local result = {}
    local block = tostring(content or ""):match('"' .. key .. '"%s*:%s*%[(.-)%]')
    if not block then return result end
    for raw in block:gmatch('"(.-)"') do
      raw = raw:gsub('\\"', '"'):gsub('\\\\', '\\')
      if raw ~= "" then table.insert(result, raw) end
    end
    return result
  end

  local function json_unescape(value)
    value = tostring(value or "")
    value = value:gsub("\\/", "/")
    value = value:gsub('\\"', '"')
    value = value:gsub("\\\\", "\\")
    value = value:gsub("\\n", "\n")
    value = value:gsub("\\r", "\r")
    value = value:gsub("\\t", "\t")
    return value
  end

  local function find_json_array(content, key)
    content = tostring(content or "")
    local _, open_pos = content:find('"' .. key .. '"%s*:%s*%[')
    if not open_pos then return nil end
    local depth = 1
    local quote = nil
    local escaped = false
    local i = open_pos + 1
    while i <= #content do
      local c = content:sub(i, i)
      if quote then
        if escaped then
          escaped = false
        elseif c == "\\" then
          escaped = true
        elseif c == quote then
          quote = nil
        end
      elseif c == '"' or c == "'" then
        quote = c
      elseif c == "[" then
        depth = depth + 1
      elseif c == "]" then
        depth = depth - 1
        if depth == 0 then return content:sub(open_pos + 1, i - 1) end
      end
      i = i + 1
    end
    return nil
  end

  local function find_json_object(content, key)
    content = tostring(content or "")
    local _, open_pos = content:find('"' .. key .. '"%s*:%s*{')
    if not open_pos then return nil end
    local depth = 1
    local quote = nil
    local escaped = false
    local i = open_pos + 1
    while i <= #content do
      local c = content:sub(i, i)
      if quote then
        if escaped then
          escaped = false
        elseif c == "\\" then
          escaped = true
        elseif c == quote then
          quote = nil
        end
      elseif c == '"' or c == "'" then
        quote = c
      elseif c == "{" then
        depth = depth + 1
      elseif c == "}" then
        depth = depth - 1
        if depth == 0 then return content:sub(open_pos + 1, i - 1) end
      end
      i = i + 1
    end
    return nil
  end

  local function json_objects_from_array(array_content)
    local result = {}
    local content = tostring(array_content or "")
    local depth = 0
    local quote = nil
    local escaped = false
    local start_pos = nil
    local i = 1
    while i <= #content do
      local c = content:sub(i, i)
      if quote then
        if escaped then
          escaped = false
        elseif c == "\\" then
          escaped = true
        elseif c == quote then
          quote = nil
        end
      elseif c == '"' or c == "'" then
        quote = c
      elseif c == "{" then
        depth = depth + 1
        if depth == 1 then start_pos = i end
      elseif c == "}" then
        if depth == 1 and start_pos then
          table.insert(result, content:sub(start_pos, i))
          start_pos = nil
        end
        depth = math.max(0, depth - 1)
      end
      i = i + 1
    end
    return result
  end

  local function json_string_field(obj, key)
    local _, quote_pos = tostring(obj or ""):find('"' .. key .. '"%s*:%s*"')
    if not quote_pos then return nil end
    local i = quote_pos + 1
    local escaped = false
    local out = {}
    while i <= #obj do
      local c = obj:sub(i, i)
      if escaped then
        table.insert(out, "\\" .. c)
        escaped = false
      elseif c == "\\" then
        escaped = true
      elseif c == '"' then
        return json_unescape(table.concat(out))
      else
        table.insert(out, c)
      end
      i = i + 1
    end
    return nil
  end

  local function json_number_or_string_field(obj, key)
    local as_string = json_string_field(obj, key)
    if as_string ~= nil then return as_string end
    return tostring(obj or ""):match('"' .. key .. '"%s*:%s*(-?%d+)')
  end

  local function normalize_resource_path(path)
    return tostring(path or ""):gsub("/", "\\"):gsub("\\+$", ""):lower()
  end

  local function content_is_portable_baseline(content)
    return tostring(content or ""):match('"portable"%s*:%s*true') ~= nil
  end

  local function content_matches_current_resource(content)
    if content_is_portable_baseline(content) then return true end
    local source_path = json_string_field(content, "reaper_resource_path")
    if not source_path or source_path == "" then return true end
    if not reaper or type(reaper.GetResourcePath) ~= "function" then return true end
    return normalize_resource_path(source_path) == normalize_resource_path(reaper.GetResourcePath())
  end

  local function json_bool_field(obj, key)
    local value = tostring(obj or ""):match('"' .. key .. '"%s*:%s*(true)')
    if value then return true end
    value = tostring(obj or ""):match('"' .. key .. '"%s*:%s*(false)')
    if value then return false end
    return nil
  end

  local function json_bool_object(obj, key)
    local block = find_json_object(obj, key)
    local result = {}
    if not block then return result end
    for k, v in block:gmatch('"([%w_%-]+)"%s*:%s*(true)') do
      result[k] = true
    end
    for k, v in block:gmatch('"([%w_%-]+)"%s*:%s*(false)') do
      result[k] = false
    end
    return result
  end

  local function register_api(entry)
    if type(entry) ~= "table" then entry = { name = entry } end
    local name = trim(entry.name or entry.id or entry.api)
    if name == "" then return false end
    if entry.available == false then return false end
    local existing = api_inventory[name]
    local normalized = {
      name = name,
      source = tostring(entry.source or "api_inventory"),
      available = entry.available ~= false,
      verifier_strength = tostring(entry.verifier_strength or "runtime_verified"),
      category = tostring(entry.category or ""),
    }
    if existing and existing.source and normalized.source ~= existing.source then
      normalized.source = existing.source .. "," .. normalized.source
    end
    if not existing then api_inventory_count = api_inventory_count + 1 end
    api_inventory[name] = normalized
    return true
  end

  local function add_api_default_names()
    register_api({ name = "APIExists", source = "reaperai_core", verifier_strength = "builtin" })
  end

  local function parse_api_inventory_content(content, source_path)
    local count = 0
    content = tostring(content or "")

    local apis = find_json_array(content, "apis")
    if apis then
      for _, obj in ipairs(json_objects_from_array(apis)) do
        local name = json_string_field(obj, "name") or json_string_field(obj, "id") or json_string_field(obj, "api")
        if name and name ~= "" then
          local ok = register_api({
            name = name,
            source = json_string_field(obj, "source") or source_path or "api_inventory_json",
            available = json_bool_field(obj, "available") ~= false,
            verifier_strength = json_string_field(obj, "verifier_strength") or "runtime_verified",
            category = json_string_field(obj, "category") or "",
          })
          if ok then count = count + 1 end
        end
      end
    end

    for _, name in ipairs(extract_json_string_array(content, "available")) do
      name = trim(name)
      if register_api({ name = name, source = source_path or "legacy_available", verifier_strength = "runtime_verified" }) then count = count + 1 end
    end

    for _, name in ipairs(extract_json_string_array(content, "functions")) do
      name = trim(name)
      if register_api({ name = name, source = source_path or "legacy_functions", verifier_strength = "runtime_verified" }) then count = count + 1 end
    end

    for line in content:gmatch("[^\r\n]+") do
      local name = trim(line)
      if name:match("^[%a_][%w_]*$") and register_api({ name = name, source = source_path or "legacy_text", verifier_strength = "runtime_verified" }) then count = count + 1 end
    end

    return count
  end

  local function api_inventory_paths()
    local paths = {}
    local explicit = options.api_inventory_path or options.whitelist_path or options.api_whitelist_path
    if explicit and explicit ~= "" then table.insert(paths, explicit) end

    local module_dir = tostring(options.module_dir or "")
    if module_dir ~= "" then
      table.insert(paths, path_join(module_dir, "reaper_api_inventory.json"))
      table.insert(paths, path_join(module_dir, "reaper_api_whitelist.json"))
      table.insert(paths, path_join(module_dir, "reaper_api_whitelist.txt"))
    end

    if reaper and reaper.GetResourcePath then
      local base = reaper.GetResourcePath()
      table.insert(paths, base .. "/Scripts/ReaperAI/reaper_api_inventory.json")
      table.insert(paths, base .. "/Scripts/ReaperAI/reaper_api_whitelist.json")
      table.insert(paths, base .. "/Scripts/ReaperAI/reaper_api_whitelist.txt")
    end

    return paths
  end

  local function load_api_inventory_once()
    if api_inventory_loaded then return end
    api_inventory_loaded = true
    add_api_default_names()
    for _, path in ipairs(api_inventory_paths()) do
      local content = read_file(path)
      if content and content ~= "" then
        if content_matches_current_resource(content) then
          local count = parse_api_inventory_content(content, path)
          if count > 0 then
            api_inventory_path = api_inventory_path or path
          end
        end
      end
    end
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
    for name in cleaned:gmatch("reaper%s*%.%s*([%a_][%w_]*)") do
      if not seen[name] then
        seen[name] = true
        table.insert(names, name)
      end
    end
    for quote, name in cleaned:gmatch("reaper%s*%[%s*([\"'])([%a_][%w_]*)%1%s*%]") do
      if not seen[name] then
        seen[name] = true
        table.insert(names, name)
      end
    end
    for name in cleaned:gmatch("reaper%s*%.%s*([%a_][%w_]*)%s*%(") do
      if not seen[name] then
        seen[name] = true
        table.insert(names, name)
      end
    end
    for quote, name in cleaned:gmatch("reaper%s*%[%s*([\"'])([%a_][%w_]*)%1%s*%]%s*%(") do
      if not seen[name] then
        seen[name] = true
        table.insert(names, name)
      end
    end
    table.sort(names)
    return names
  end

  local function api_exists_runtime(name)
    if not reaper then return nil end
    if type(reaper.APIExists) == "function" then
      local ok, exists = pcall(reaper.APIExists, name)
      if ok and exists ~= nil then return exists == true end
    end
    if type(reaper[name]) == "function" then return true end
    if reaper[name] ~= nil then return false end
    return nil
  end

  local function api_exists(name)
    name = trim(name)
    if name == "" then return nil end
    load_api_inventory_once()
    if api_inventory[name] then return true, api_inventory[name].source or "inventory" end
    local runtime_exists = api_exists_runtime(name)
    if runtime_exists ~= nil then
      if runtime_exists then
        register_api({ name = name, source = "runtime_APIExists", verifier_strength = "runtime_observed" })
      end
      return runtime_exists, "runtime"
    end
    if api_inventory_path then return false, "inventory" end
    return nil, "unknown"
  end

  local function validate_lua_api(src)
    local blacklist = {
      MoveRegion = "reaper.MoveRegion does not exist; use SetProjectMarker / SetProjectMarker3 instead.",
    }
    for _, name in ipairs(collect_reaper_api_calls(src)) do
      if blacklist[name] then
        return false, blacklist[name], { name = name, source = "blacklist" }
      end
      local exists, source = api_exists(name)
      if exists == false then
        return false, "REAPER API does not exist: reaper." .. tostring(name) .. "; use a real local REAPER API instead.", { name = name, source = source }
      end
    end
    return true, nil, nil
  end

  local function normalize_action_id(id)
    return tostring(id or ""):gsub("^%s+", ""):gsub("%s+$", "")
  end

  local function action_text(entry)
    entry = entry or {}
    return trim((entry.name or "") .. " " .. (entry.command_name or "") .. " " .. (entry.id or ""))
  end

  local function text_has_any(text, tokens)
    local lower = tostring(text or ""):lower()
    for _, token in ipairs(tokens or {}) do
      token = tostring(token or ""):lower()
      if token ~= "" and lower:find(token, 1, true) then return true, token end
    end
    return false, nil
  end

  local function classify_action_entry(entry)
    entry = entry or {}
    local text = action_text(entry)
    local effects = {}
    for k, v in pairs(entry.effects or {}) do
      if v then effects[k] = true end
    end

    local category = "unknown"
    local risk = tostring(entry.risk or "unknown")
    local action = tostring(entry.action or "native_action")
    local target = tostring(entry.target or "native_action")
    local requires_confirmation = true
    local is_freeze_action = text_has_any(text, { "freeze", "unfreeze", "冻结", "解冻" })
    local is_glue_action = text_has_any(text, { "glue", "胶合" })

    if is_freeze_action then
      category = "freeze"
      action = text_has_any(text, { "unfreeze", "解冻" }) and "unfreeze" or "freeze"
      target = text_has_any(text, { "track", "轨道" }) and "track" or target
      risk = "writes_disk"
      effects.modifies_project = true
      effects.writes_disk = true
      effects.freezes_track = true
      effects.selection_dependent = effects.selection_dependent or text_has_any(text, { "selected", "选定", "选中" }) == true
    elseif is_glue_action then
      category = "glue"
      action = "glue"
      target = text_has_any(text, { "item", "take", "素材", "对象" }) and "item" or target
      risk = "writes_disk"
      effects.modifies_project = true
      effects.writes_disk = true
      effects.selection_dependent = effects.selection_dependent or text_has_any(text, { "selected", "选定", "选中" }) == true
    elseif text_has_any(text, { "delete", "remove", "clear", "删除", "移除", "清除", "清空" }) then
      category = "delete"
      action = "delete"
      target = target ~= "native_action" and target or "project"
      risk = "destructive"
      effects.modifies_project = true
      effects.deletes_project = true
    elseif text_has_any(text, { "close project", "close current project", "close all projects", "关闭工程", "关闭当前工程" }) then
      category = "project_close"
      action = "close"
      target = "project"
      risk = "destructive"
      effects.modifies_project = true
      effects.saves_project = true
    elseif text_has_any(text, { "save", "render", "export", "bounce", "apply track/take fx", "保存", "渲染", "导出" }) then
      category = "write_or_render"
      action = "render"
      target = text_has_any(text, { "track", "轨道" }) and "track" or target
      risk = "writes_disk"
      effects.modifies_project = true
      effects.writes_disk = true
      effects.selection_dependent = effects.selection_dependent or text_has_any(text, { "selected", "选定", "选中" }) == true
    elseif text_has_any(text, { "toggle", "切换", "bypass", "enable", "disable", "on/off", "开关" }) then
      category = "toggle"
      action = "toggle"
      target = text_has_any(text, { "snap", "吸附" }) and "snap" or "state"
      risk = risk ~= "unknown" and risk or "toggle_state"
      effects.modifies_project = true
      effects.toggles_state = true
    elseif text_has_any(text, { "show", "hide", "view", "open", "window", "tab", "显示", "隐藏", "打开", "窗口", "选项卡" }) then
      category = "ui"
      action = "show"
      target = "ui"
      risk = risk ~= "unknown" and risk or "ui"
      effects.opens_window = true
      effects.changes_ui = true
      requires_confirmation = false
    elseif text_has_any(text, { "select", "selection", "cursor", "loop point", "time selection", "选中", "选择", "光标", "循环点", "时间选区" }) then
      category = "selection_or_cursor"
      action = "select"
      target = "selection"
      risk = risk ~= "unknown" and risk or "selection"
      effects.changes_selection = true
    elseif text_has_any(text, { "set", "insert", "move", "split", "trim", "normalize", "quantize", "设置", "插入", "移动", "切割", "修剪", "归一化", "量化" }) then
      category = "edit"
      action = "edit"
      target = target ~= "native_action" and target or "project"
      risk = risk ~= "unknown" and risk or "edit"
      effects.modifies_project = true
    end

    if effects.destructive then
      effects.deletes_project = true
      effects.modifies_project = true
      risk = "destructive"
    end
    if effects.writes_disk then
      risk = (risk == "unknown") and "writes_disk" or risk
    end
    if effects.toggles_state then
      risk = (risk == "unknown") and "toggle_state" or risk
    end

    return {
      category = category,
      risk = risk,
      action = action,
      target = target,
      effects = effects,
      requires_confirmation = requires_confirmation,
      label = text ~= "" and text or tostring(entry.id or "Native Action"),
    }
  end

  local function register_action(entry)
    if type(entry) ~= "table" then return false end
    local id = normalize_action_id(entry.id or entry.command_id or entry.command)
    if id == "" then return false end
    local existing = action_inventory[id]
    local normalized = {
      id = id,
      command_id = entry.command_id or entry.command or entry.id,
      command_name = tostring(entry.command_name or entry.named_command or entry.name or entry.label or ""),
      name = tostring(entry.name or entry.label or ""),
      section = tostring(entry.section or "main"),
      source = tostring(entry.source or "local_inventory"),
      allowed_in_script = (entry.allowed_in_script == true) or ((existing and existing.allowed_in_script == true) or false),
      action = tostring(entry.action or "native_action"),
      target = tostring(entry.target or "native_action"),
      verifier_strength = tostring(entry.verifier_strength or "observed"),
      risk = tostring(entry.risk or "unknown"),
      requires_selection = entry.requires_selection == true,
      verifier = entry.verifier,
      effects = entry.effects or {},
    }
    local classified = classify_action_entry(normalized)
    normalized.native_category = classified.category
    normalized.risk = classified.risk
    normalized.action = classified.action
    normalized.target = classified.target
    normalized.effects = classified.effects
    normalized.requires_confirmation = classified.requires_confirmation
    normalized.label = normalized.name ~= "" and normalized.name or classified.label
    if existing and existing.source and normalized.source ~= existing.source then
      normalized.source = existing.source .. "," .. normalized.source
    end
    if not existing then action_inventory_count = action_inventory_count + 1 end
    action_inventory[id] = normalized

    local command_name = normalize_action_id(normalized.command_name)
    if command_name ~= "" and command_name:sub(1, 1) == "_" then
      action_inventory[command_name] = normalized
    end
    return true
  end

  local function load_action_inventory(entries)
    action_inventory = {}
    action_inventory_loaded = true
    action_inventory_path = nil
    action_inventory_count = 0
    local count = 0
    for _, entry in ipairs(entries or {}) do
      if register_action(entry) then count = count + 1 end
    end
    return count
  end

  local function parse_action_inventory_json(content, source_path)
    local count = 0
    local actions = find_json_array(content, "actions")
    if not actions then return 0 end
    for _, obj in ipairs(json_objects_from_array(actions)) do
      local id = json_number_or_string_field(obj, "id") or json_number_or_string_field(obj, "command_id") or json_string_field(obj, "command")
      if id and id ~= "" then
        local ok = register_action({
          id = id,
          command_id = json_number_or_string_field(obj, "command_id") or id,
          command = json_number_or_string_field(obj, "command") or id,
          command_name = json_string_field(obj, "command_name") or json_string_field(obj, "named_command"),
          name = json_string_field(obj, "name") or json_string_field(obj, "label"),
          label = json_string_field(obj, "label"),
          section = json_string_field(obj, "section") or json_number_or_string_field(obj, "section_id") or "main",
          source = json_string_field(obj, "source") or source_path or "action_inventory_json",
          allowed_in_script = json_bool_field(obj, "allowed_in_script") == true,
          requires_selection = json_bool_field(obj, "requires_selection") == true,
          action = json_string_field(obj, "action") or "native_action",
          target = json_string_field(obj, "target") or "native_action",
          verifier_strength = json_string_field(obj, "verifier_strength") or "observed",
          risk = json_string_field(obj, "risk") or "unknown",
          effects = json_bool_object(obj, "effects"),
        })
        if ok then count = count + 1 end
      end
    end
    return count
  end

  local function parse_reaper_kb_content(content, source_path)
    local count = 0
    for line in tostring(content or ""):gmatch("[^\r\n]+") do
      local cmd, section_id = line:match("^KEY%s+%S+%s+%S+%s+(%S+)%s+(%S+)")
      if cmd and cmd ~= "0" then
        local comment = line:match("#%s*(.*)$") or ""
        local ok = register_action({
          id = cmd,
          command_id = cmd,
          command_name = cmd:sub(1, 1) == "_" and cmd or "",
          name = comment,
          section = section_id == "0" and "main" or tostring(section_id or "main"),
          source = source_path or "reaper-kb.ini",
          allowed_in_script = false,
          risk = comment:lower():find("delete", 1, true) and "destructive" or "unknown",
          verifier_strength = "observed_keymap",
        })
        if ok then count = count + 1 end
      else
        local script_cmd, label = line:match('^SCR%s+%S+%s+%S+%s+(RS%S+)%s+"([^"]+)"')
        if script_cmd then
          local id = "_" .. script_cmd
          local ok = register_action({
            id = id,
            command_id = id,
            command_name = id,
            name = label,
            section = "main",
            source = source_path or "reaper-kb.ini",
            allowed_in_script = false,
            risk = "unknown",
            verifier_strength = "observed_script",
          })
          if ok then count = count + 1 end
        end
      end
    end
    return count
  end

  local function action_inventory_paths()
    local paths = {}
    local explicit = options.action_inventory_path or options.native_action_inventory_path
    if explicit and explicit ~= "" then table.insert(paths, explicit) end

    local module_dir = tostring(options.module_dir or "")
    if module_dir ~= "" then
      table.insert(paths, path_join(module_dir, "reaper_action_inventory.json"))
    end

    if reaper and reaper.GetResourcePath then
      local base = reaper.GetResourcePath()
      table.insert(paths, base .. "/Scripts/ReaperAI/reaper_action_inventory.json")
    end

    return paths
  end

  local function reaper_kb_paths()
    local paths = {}
    local explicit = options.reaper_kb_path
    if explicit and explicit ~= "" then table.insert(paths, explicit) end

    if reaper and reaper.GetResourcePath then
      local base = reaper.GetResourcePath()
      table.insert(paths, base .. "/reaper-kb.ini")
    end

    return paths
  end

  local function load_action_inventory_once()
    if action_inventory_loaded then return end
    action_inventory_loaded = true

    for _, path in ipairs(reaper_kb_paths()) do
      local content = read_file(path)
      if content and content ~= "" then
        local count = parse_reaper_kb_content(content, path)
        if count > 0 and not action_inventory_path then
          action_inventory_path = path
        end
      end
    end

    for _, path in ipairs(action_inventory_paths()) do
      local content = read_file(path)
      if content and content ~= "" then
        if content_matches_current_resource(content) then
          local count = parse_action_inventory_json(content, path)
          if count > 0 then
            action_inventory_path = path
          end
        end
      end
    end
  end

  local function action_exists(id)
    load_action_inventory_once()
    id = normalize_action_id(id)
    if id == "" then return false, "empty" end
    if action_inventory[id] then return true, "inventory" end
    return nil, action_inventory_loaded and "inventory" or "unknown"
  end

  local function action_entry(id)
    load_action_inventory_once()
    id = normalize_action_id(id)
    if id == "" then return nil end
    if action_inventory[id] then return action_inventory[id] end
    if id:sub(1, 1) == "_" and reaper and type(reaper.NamedCommandLookup) == "function" then
      local ok, resolved = pcall(reaper.NamedCommandLookup, id)
      resolved = tonumber(ok and resolved or nil)
      if resolved and resolved > 0 then
        local resolved_id = tostring(resolved)
        if action_inventory[resolved_id] then
          action_inventory[id] = action_inventory[resolved_id]
          return action_inventory[resolved_id]
        end
        register_action({
          id = resolved_id,
          command_id = resolved_id,
          command_name = id,
          name = id,
          section = "main",
          source = "NamedCommandLookup",
          allowed_in_script = false,
          verifier_strength = "runtime_lookup",
        })
        return action_inventory[resolved_id]
      end
    end
    return nil
  end

  local function action_search(query, opts)
    load_action_inventory_once()
    opts = opts or {}
    query = trim(query)
    if query == "" then return nil end
    local query_lower = query:lower()
    local section = trim(opts.section or opts.section_id or "")
    local tokens = {}
    for token in query_lower:gmatch("[^%s]+") do
      if token ~= "" then table.insert(tokens, token) end
    end
    local best, best_score = nil, -1
    for _, entry in pairs(action_inventory) do
      if type(entry) == "table" and tostring(entry.id or "") ~= "" then
        local entry_section = tostring(entry.section or entry.section_id or "")
        if section == "" or entry_section == section or tostring(entry.section_id or "") == section then
          local text = action_text(entry):lower()
          local score = 0
          if text == query_lower then score = score + 100 end
          if text:find(query_lower, 1, true) then score = score + 50 end
          for _, token in ipairs(tokens) do
            if text:find(token, 1, true) then score = score + 5 end
          end
          if opts.category and entry.native_category == opts.category then score = score + 10 end
          if opts.target and entry.target == opts.target then score = score + 6 end
          if score > best_score then
            best, best_score = entry, score
          end
        end
      end
    end
    if best and best_score > 0 then return best, best_score end
    return nil, 0
  end

  local function native_action_for_request(params)
    params = params or {}
    local command_id = trim(params.command_id or params.id or params.action_id or "")
    if command_id ~= "" then
      return action_entry(command_id), "command_id"
    end
    local query = trim(params.query or params.name or params.description or "")
    local action = trim(params.action or params.kind or "")
    local mode = trim(params.mode or "")
    if query == "" and action ~= "" then
      if action == "freeze" or action == "track/freeze" then
        query = "Track: Freeze to " .. (mode ~= "" and mode or "stereo")
      elseif action == "unfreeze" or action == "track/unfreeze" then
        query = "Track: Unfreeze tracks"
      elseif action == "glue" or action == "item/glue" then
        query = "glue"
      else
        query = action
      end
    end
    if query == "" then return nil, "missing_query" end
    local entry = action_search(query, {
      section = params.section or params.section_id or "main",
      category = action == "freeze" and "freeze" or nil,
      target = (action == "freeze" or action == "track/freeze") and "track" or nil,
    })
    return entry, "query"
  end

  local function has_extension(name)
    name = trim(name)
    if name == "" then return nil end
    if extension_cache[name] ~= nil then return extension_cache[name] end
    local exists = nil
    if name == "SWS" then
      exists = api_exists("BR_GetMediaTrackByGUID") == true or api_exists("SNM_GetIntConfigVar") == true
    elseif name == "js_ReaScriptAPI" then
      exists = api_exists("JS_Window_Find") == true
    elseif name == "ReaImGui" then
      exists = api_exists("ImGui_CreateContext") == true
    else
      exists = nil
    end
    extension_cache[name] = exists
    return exists
  end

  function M.collect_reaper_api_calls(src)
    return collect_reaper_api_calls(src)
  end

  function M.validate_lua(src)
    return validate_lua_api(src)
  end

  function M.validate_lua_api(src)
    return validate_lua_api(src)
  end

  function M.api_exists(name)
    return api_exists(name)
  end

  function M.api_inventory_path()
    load_api_inventory_once()
    return api_inventory_path
  end

  function M.api_inventory_loaded()
    load_api_inventory_once()
    return api_inventory_count > 0
  end

  function M.api_inventory_count()
    load_api_inventory_once()
    return api_inventory_count
  end

  function M.api_whitelist_path()
    load_api_inventory_once()
    return api_inventory_path
  end

  function M.whitelist_path()
    load_api_inventory_once()
    return api_inventory_path
  end

  function M.whitelist_loaded()
    load_api_inventory_once()
    return api_inventory_path ~= nil
  end

  function M.register_action(entry)
    return register_action(entry)
  end

  function M.load_action_inventory(entries)
    return load_action_inventory(entries)
  end

  function M.load_action_inventory_json(content)
    action_inventory = {}
    action_inventory_loaded = true
    action_inventory_path = nil
    action_inventory_count = 0
    return parse_action_inventory_json(content, "inline_json")
  end

  function M.load_reaper_kb_inventory(content)
    action_inventory = {}
    action_inventory_loaded = true
    action_inventory_path = nil
    action_inventory_count = 0
    return parse_reaper_kb_content(content, "inline_reaper_kb")
  end

  function M.action_exists(id)
    return action_exists(id)
  end

  function M.action_entry(id)
    return action_entry(id)
  end

  function M.classify_action(entry)
    return classify_action_entry(entry)
  end

  function M.action_search(query, opts)
    return action_search(query, opts)
  end

  function M.native_action_for_request(params)
    return native_action_for_request(params)
  end

  function M.action_inventory_path()
    load_action_inventory_once()
    return action_inventory_path
  end

  function M.action_inventory_loaded()
    load_action_inventory_once()
    return action_inventory_count > 0
  end

  function M.action_inventory_count()
    load_action_inventory_once()
    return action_inventory_count
  end

  function M.has_extension(name)
    return has_extension(name)
  end

  function M.summary_for_prompt()
    load_api_inventory_once()
    local api_state = api_inventory_path and ("API inventory: " .. api_inventory_path .. " (" .. tostring(api_inventory_count) .. ")") or "API inventory: runtime/unknown"
    load_action_inventory_once()
    local action_state = action_inventory_path and ("Action inventory: " .. action_inventory_path .. " (" .. tostring(action_inventory_count) .. ")") or "Action inventory: unavailable"
    return api_state .. "\n" .. action_state
  end

  return M
end

return ReaperCapabilities
