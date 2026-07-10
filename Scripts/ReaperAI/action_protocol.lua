local ActionProtocol = {}

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function lower(value)
  return trim(value):lower()
end

local function truthy(value)
  local v = lower(value)
  return v == "true" or v == "1" or v == "yes" or v == "y" or v == "on"
end

local function is_all(value)
  local v = lower(value)
  return v == "all" or v == "everything" or v == "entire" or v == "project" or
    v == "all_tracks" or v == "all_items" or v == "all_markers" or v == "all_regions" or
    v == "全部" or v == "所有" or v == "整个工程" or v == "所有轨道" or v == "所有标记" or v == "所有区域"
end

local function is_selected(value)
  local v = lower(value)
  return v == "selected" or v == "selection" or v == "current" or v == "selected_tracks" or
    v == "selected_items" or v == "当前" or v == "选中" or v == "已选中" or v == "当前选中"
end

local function shallow_copy(src)
  local out = {}
  for k, v in pairs(src or {}) do out[k] = v end
  return out
end

local function add_param(params, key, value)
  key = trim(key)
  value = trim(value)
  if key ~= "" and value ~= "" then params[key] = value end
end

local function url_encode(value)
  value = tostring(value or "")
  value = value:gsub("\n", " "):gsub("\r", " ")
  value = value:gsub("([^%w%-%._~])", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
  return value
end

local function build_call(endpoint, params, build_call_fn)
  if build_call_fn then
    local ok, call = pcall(build_call_fn, endpoint, params)
    if ok and call and call ~= "" then return call end
  end
  local keys = {}
  for k, v in pairs(params or {}) do
    if v ~= nil and tostring(v) ~= "" then table.insert(keys, tostring(k)) end
  end
  table.sort(keys)
  if #keys == 0 then return endpoint end
  local parts = {}
  for _, key in ipairs(keys) do
    table.insert(parts, url_encode(key) .. "=" .. url_encode(params[key]))
  end
  return endpoint .. "?" .. table.concat(parts, "&")
end

local DIRECT_ACTIONS = {
  ["transport.play"] = "transport/play",
  ["transport.stop"] = "transport/stop",

  ["track.create"] = "track/create",
  ["track.delete"] = "track/delete",
  ["track.rename"] = "track/rename",
  ["track.volume.set"] = "track/set_volume",
  ["track.set_volume"] = "track/set_volume",
  ["track.pan.set"] = "track/set_pan",
  ["track.set_pan"] = "track/set_pan",
  ["track.color.set"] = "track/set_color",
  ["track.set_color"] = "track/set_color",
  ["track.color.clear"] = "track/clear_color",
  ["track.clear_color"] = "track/clear_color",
  ["track.mute"] = "track/mute",
  ["track.solo"] = "track/solo",
  ["track.fx.add"] = "track/add_fx",
  ["track.add_fx"] = "track/add_fx",
  ["track.fx.remove"] = "track/remove_fx",
  ["track.remove_fx"] = "track/remove_fx",
  ["track.folder.group"] = "track/group_into_folder",
  ["track.group_into_folder"] = "track/group_into_folder",
  ["track.folder.create"] = "track/create_folder",
  ["track.create_folder"] = "track/create_folder",

  ["marker.add"] = "marker/add",
  ["marker.delete"] = "marker/delete",
  ["marker.delete_all"] = "marker/delete",

  ["region.delete"] = "region/delete",
  ["region.delete_all"] = "region/delete",
  ["region.rename.batch"] = "region/batch_rename",
  ["region.batch_rename"] = "region/batch_rename",

  ["item.fade"] = "item/fade",
  ["item.set_fade"] = "item/set_fade",
  ["item.fade_shape"] = "item/fade_shape",
  ["item.set_fade_shape"] = "item/set_fade_shape",

  ["envelope.draw"] = "envelope/draw",
  ["envelope.clear"] = "envelope/clear",

  ["sfx.generate_variants"] = "sfx/generate_variants",
  ["analysis.detect_peaks"] = "analysis/detect_peaks",
  ["analysis.find_loop_points"] = "analysis/find_loop_points",

  ["export.batch_regions"] = "export/batch_regions",
  ["export.regions"] = "export/batch_regions",
  ["export.tracks"] = "export/tracks",
  ["export.master"] = "export/master",

  ["native.action"] = "native/action",
  ["capability.endpoints"] = "endpoints",
  ["endpoints"] = "endpoints",
}

local ACTION_ALIASES = {
  ["track.clear_color"] = "track.color.clear",
  ["track.color.clear"] = "track.color.clear",
  ["track.color.default"] = "track.color.clear",
  ["track.default_color"] = "track.color.clear",
  ["track.colour.clear"] = "track.color.clear",
  ["track.colour.set"] = "track.color.set",
  ["marker.delete_all"] = "marker.delete",
  ["region.delete_all"] = "region.delete",
}

local function canonical_action(action)
  action = lower(action):gsub("/", ".")
  return ACTION_ALIASES[action] or action
end

local function line_without_numbering(line)
  line = trim(line)
  line = line:gsub("^[-*]%s*", "")
  line = line:gsub("^%d+[%.)]%s*", "")
  line = line:gsub("^step%s*%d+[%:%.)-]*%s*", "")
  return trim(line)
end

local function parse_key_values(line)
  local params = {}
  local consumed = {}

  line = line:gsub("([%w_%-]+)%s*=%s*\"([^\"]*)\"", function(k, v)
    add_param(params, k, v)
    table.insert(consumed, k)
    return " "
  end)
  line = line:gsub("([%w_%-]+)%s*=%s*'([^']*)'", function(k, v)
    add_param(params, k, v)
    table.insert(consumed, k)
    return " "
  end)
  for k, v in line:gmatch("([%w_%-]+)%s*=%s*([^%s;]+)") do
    add_param(params, k, v)
  end
  return params
end

local function first_token(line)
  line = line_without_numbering(line)
  local token = line:match("^([^%s;]+)")
  if not token or token:find("=", 1, true) then return "" end
  return trim(token)
end

local function normalize_selector(params)
  params = shallow_copy(params)
  local scope = params.scope or params.target_scope or params.target
  if truthy(params.all) or is_all(scope) then
    params.all = "true"
    params.scope = nil
  elseif truthy(params.selected) or is_selected(scope) then
    params.selected = "true"
    if is_selected(params.target) then params.target = nil end
    params.scope = nil
  end
  if params.keep_regions ~= nil then
    local v = lower(params.keep_regions)
    if v == "true" or v == "1" or v == "yes" or v == "keep" then
      params.is_region = "false"
    end
  end
  return params
end

local function compile_action(action, params)
  action = canonical_action(action)
  params = normalize_selector(params or {})
  params.action = nil

  if action == "track.color.clear" then
    params.color = nil
    params.value = nil
    params.rgb = nil
    return "track/clear_color", params
  end

  local endpoint = params.endpoint or params.mcp or DIRECT_ACTIONS[action]
  params.endpoint = nil
  params.mcp = nil
  if not endpoint and action:find("%.") then
    local prefix, suffix = action:match("^([^%.]+)%.(.+)$")
    if prefix and suffix then
      endpoint = prefix .. "/" .. suffix:gsub("%.", "_")
    end
  end
  if not endpoint or endpoint == "" then
    return nil, nil, "unknown action: " .. tostring(action)
  end

  if action == "marker.delete" and (truthy(params.all) or is_all(params.scope)) then
    params.all = "true"
  elseif action == "region.delete" and (truthy(params.all) or is_all(params.scope)) then
    params.all = "true"
  end

  return endpoint, params
end

local function parse_turn_block(text)
  local block = tostring(text or ""):match("%[TURN%](.-)%[/TURN%]")
  if not block then return nil end
  local turn = { raw = block }
  for line in block:gmatch("[^\r\n]+") do
    local k, v = line:match("^%s*([%w_%-]+)%s*[:=]%s*(.-)%s*$")
    if k and v then
      k = lower(k)
      if k == "type" or k == "turn_type" then
        turn.type = trim(v)
      elseif k == "signals" or k == "signal" then
        turn.signals = trim(v)
      elseif k == "reply" or k == "assistant_reply" then
        turn.reply = trim(v)
      elseif k == "uses_context" or k == "context" then
        turn.uses_context = truthy(v)
      end
    end
  end
  return turn
end

local function parse_action_plan_block(text)
  local block = tostring(text or ""):match("%[ACTION_PLAN%](.-)%[/ACTION_PLAN%]")
  if not block then return nil end
  local actions = {}
  for line in block:gmatch("[^\r\n]+") do
    line = line_without_numbering(line)
    if line ~= "" and not line:match("^#") then
      local params = parse_key_values(line)
      local action = params.action or first_token(line)
      if action ~= "" then
        params.action = nil
        table.insert(actions, { action = action, params = params, raw = line })
      end
    end
  end
  return { raw = block, actions = actions }
end

function ActionProtocol.compile_response(text, opts)
  opts = opts or {}
  local turn = parse_turn_block(text)
  local plan = parse_action_plan_block(text)
  if not plan or not plan.actions or #plan.actions == 0 then
    return nil
  end
  local steps = {}
  local diagnostics = {}
  for index, item in ipairs(plan.actions) do
    local endpoint, params, err = compile_action(item.action, item.params or {})
    if endpoint then
      local call = build_call(endpoint, params, opts.build_call)
      table.insert(steps, {
        id = "step_" .. tostring(#steps + 1),
        kind = "mcp",
        type = "mcp",
        source = "action_protocol",
        call = call,
        raw = "[ACTION:" .. tostring(item.raw or item.action or endpoint) .. "]",
        status = "pending",
        risk = "low",
        action_protocol = {
          action = canonical_action(item.action),
          endpoint = endpoint,
          params = params,
          plan_index = index,
        },
      })
    else
      table.insert(diagnostics, tostring(err or ("could not compile action " .. tostring(index))))
    end
  end
  return {
    turn = turn,
    plan = plan,
    steps = steps,
    diagnostics = diagnostics,
  }
end

return ActionProtocol
