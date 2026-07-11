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
  local v = lower(value):gsub("%s+", "_")
  return v == "all" or v == "everything" or v == "entire" or v == "project" or
    v == "all_tracks" or v == "all_items" or v == "all_markers" or v == "all_regions" or
    v == "全部" or v == "所有" or v == "整个工程" or v == "所有轨道" or
    v == "所有素材" or v == "所有marker" or v == "所有region" or v == "所有区域"
end

local function is_selected(value)
  local v = lower(value):gsub("%s+", "_")
  return v == "selected" or v == "selection" or v == "current" or v == "selected_tracks" or
    v == "selected_items" or v == "selected_region" or v == "selected_regions" or
    v == "selected_marker" or v == "selected_markers" or v == "selected_envelope" or
    v == "current_region" or v == "current_marker" or v == "current_item" or
    v == "当前" or v == "选中" or v == "已选中" or v == "当前选中" or
    v == "选中的region" or v == "选中的_region" or v == "选中的区域" or
    v == "选中的marker" or v == "选中的_item" or v == "选中的素材"
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
  ["region.color.set"] = "region/set_color",
  ["region.set_color"] = "region/set_color",
  ["region.rename.batch"] = "region/batch_rename",
  ["region.batch_rename"] = "region/batch_rename",

  ["item.color.set"] = "item/set_color",
  ["item.set_color"] = "item/set_color",
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
  ["region.colour.set"] = "region.color.set",
  ["item.colour.set"] = "item.color.set",
  ["marker.delete_all"] = "marker.delete",
  ["region.delete_all"] = "region.delete",
}

local function canonical_action(action)
  action = lower(action):gsub("/", ".")
  return ACTION_ALIASES[action] or action
end

local DELETE_SELECTOR_KINDS = {
  ["track.delete"] = "track",
  ["item.delete"] = "item",
  ["region.delete"] = "region",
  ["marker.delete"] = "marker",
}

local function selector_token(value)
  local v = lower(value):gsub("%s+", "_")
  if v == "" then return "" end
  if is_all(v) then return "all" end
  if v == "current" or v == "cursor" or v == "edit_cursor" or v == "play_cursor" or
     v == "current_region" or v == "current_marker" or v == "current_item" then
    return "current"
  end
  if is_selected(v) then return "selected" end
  if v == "time_selection" or v == "time-selection" or v == "timerange" or v == "time_range" or
     v == "loop_selection" or v == "selection_time" then
    return "time_selection"
  end
  return ""
end

local function selector_scope(params)
  params = params or {}
  if truthy(params.all) then return "all" end
  if truthy(params.selected) then return "selected" end
  if truthy(params.time_selection) then return "time_selection" end
  return selector_token(params.scope or params.selector or params.target_scope or params.target)
end

local function selector_exclude(params)
  params = params or {}
  local explicit = params.exclude or params.except or params.preserve or params.keep or params.keep_scope
  local token = selector_token(explicit)
  if token ~= "" then return token end
  if truthy(params.exclude_selected) or truthy(params.except_selected) or truthy(params.preserve_selected) or truthy(params.keep_selected) then
    return "selected"
  end
  if truthy(params.exclude_time_selection) or truthy(params.except_time_selection) then
    return "time_selection"
  end
  if truthy(params.exclude_current) or truthy(params.except_current) then
    return "current"
  end
  return ""
end

local function generic_delete_script(kind, scope, exclude)
  local template = [=[
local kind = "__KIND__"
local scope = "__SCOPE__"
local exclude = "__EXCLUDE__"
local EPS = 0.001

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

local function time_selection()
  if not reaper.GetSet_LoopTimeRange then return false, 0, 0 end
  local a, b = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  a = tonumber(a) or 0
  b = tonumber(b) or 0
  return b > a + EPS, a, b
end

local function delete_tracks()
  if scope == "" then return { ok=false, message="track delete requires scope=all/selected/current", changed={deleted=0} } end
  local targets = {}
  for i = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, i)
    local selected = track and reaper.IsTrackSelected and reaper.IsTrackSelected(track)
    local include = scope == "all" or ((scope == "selected" or scope == "current") and selected)
    local skip = (exclude == "selected" or exclude == "current") and selected
    if track and include and not skip then table.insert(targets, track) end
  end
  for i = #targets, 1, -1 do reaper.DeleteTrack(targets[i]) end
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
  return { ok=#targets > 0, message="Deleted " .. tostring(#targets) .. " track(s)", changed={deleted=#targets} }
end

local function delete_items()
  if scope == "" then return { ok=false, message="item delete requires scope=all/selected/current/time_selection", changed={deleted=0} } end
  local ts_active, ts_start, ts_end = time_selection()
  local targets = {}
  for i = 0, reaper.CountMediaItems(0) - 1 do
    local item = reaper.GetMediaItem(0, i)
    local selected = item and reaper.IsMediaItemSelected and reaper.IsMediaItemSelected(item)
    local pos = item and reaper.GetMediaItemInfo_Value(item, "D_POSITION") or 0
    local len = item and reaper.GetMediaItemInfo_Value(item, "D_LENGTH") or 0
    local in_time = ts_active and ranges_overlap(pos, pos + len, ts_start, ts_end)
    local include = scope == "all" or
      ((scope == "selected" or scope == "current") and selected) or
      (scope == "time_selection" and in_time)
    local skip = ((exclude == "selected" or exclude == "current") and selected) or
      (exclude == "time_selection" and in_time)
    if item and include and not skip then table.insert(targets, item) end
  end
  local deleted = 0
  for _, item in ipairs(targets) do
    local track = reaper.GetMediaItemTrack(item)
    if track then
      reaper.DeleteTrackMediaItem(track, item)
      deleted = deleted + 1
    end
  end
  reaper.UpdateArrange()
  return { ok=deleted > 0, message="Deleted " .. tostring(deleted) .. " item(s)", changed={deleted=deleted} }
end

local function enum_marker(index)
  if reaper.EnumProjectMarkers3 then return reaper.EnumProjectMarkers3(0, index) end
  return reaper.EnumProjectMarkers(index)
end

local function marker_region_selected(entry, ts_active, ts_start, ts_end, cursor)
  if entry.is_region then
    if not ts_active then return false end
    local exact = close_enough(entry.pos, ts_start) and close_enough(entry.rgnend, ts_end)
    local contained = entry.pos >= ts_start - EPS and entry.rgnend <= ts_end + EPS
    local overlap = ranges_overlap(entry.pos, entry.rgnend, ts_start, ts_end)
    return exact or contained or overlap
  end
  if ts_active then return entry.pos >= ts_start - EPS and entry.pos <= ts_end + EPS end
  return close_enough(entry.pos, cursor)
end

local function marker_region_current(entry, cursor)
  if entry.is_region then return cursor >= entry.pos - EPS and cursor <= entry.rgnend + EPS end
  return close_enough(entry.pos, cursor)
end

local function delete_marker_regions()
  if scope == "" then return { ok=false, message=kind .. " delete requires scope=all/selected/current/time_selection or explicit ids through MCP", changed={deleted=0} } end
  local ts_active, ts_start, ts_end = time_selection()
  local cursor = reaper.GetCursorPosition and (tonumber(reaper.GetCursorPosition()) or 0) or 0
  local _, marker_count, region_count = reaper.CountProjectMarkers(0)
  local total = (tonumber(marker_count) or 0) + (tonumber(region_count) or 0)
  local targets = {}
  for i = 0, total - 1 do
    local retval, is_region, pos, rgnend, name, id = enum_marker(i)
    if retval ~= 0 and ((kind == "region" and is_region) or (kind == "marker" and not is_region)) then
      local entry = { id=tonumber(id), is_region=is_region, pos=tonumber(pos) or 0, rgnend=tonumber(rgnend) or tonumber(pos) or 0, name=name or "" }
      local selected = marker_region_selected(entry, ts_active, ts_start, ts_end, cursor)
      local current = marker_region_current(entry, cursor)
      local in_time = entry.is_region and ts_active and ranges_overlap(entry.pos, entry.rgnend, ts_start, ts_end) or
        (ts_active and entry.pos >= ts_start - EPS and entry.pos <= ts_end + EPS)
      local include = scope == "all" or
        (scope == "selected" and selected) or
        (scope == "current" and current) or
        (scope == "time_selection" and in_time)
      local skip = (exclude == "selected" and selected) or
        (exclude == "current" and current) or
        (exclude == "time_selection" and in_time)
      if include and not skip and entry.id ~= nil then table.insert(targets, entry) end
    end
  end
  table.sort(targets, function(a, b) return (a.id or 0) > (b.id or 0) end)
  local deleted = 0
  local labels = {}
  for _, entry in ipairs(targets) do
    if reaper.DeleteProjectMarker(0, entry.id, entry.is_region) then
      deleted = deleted + 1
      if #labels < 8 then table.insert(labels, (entry.is_region and "R" or "M") .. tostring(entry.id)) end
    end
  end
  reaper.UpdateTimeline()
  reaper.UpdateArrange()
  local label = kind == "region" and "Region" or "Marker"
  return { ok=deleted > 0, message="Deleted " .. tostring(deleted) .. " " .. label .. "(s): " .. table.concat(labels, ", "), changed={deleted=deleted} }
end

reaper.Undo_BeginBlock()
local result
if kind == "track" then
  result = delete_tracks()
elseif kind == "item" then
  result = delete_items()
elseif kind == "region" or kind == "marker" then
  result = delete_marker_regions()
else
  result = { ok=false, message="unsupported delete selector kind: " .. tostring(kind), changed={deleted=0} }
end
reaper.Undo_EndBlock("ReaperAI delete " .. tostring(kind) .. " selector", -1)
return result
]=]
  return template
    :gsub("__KIND__", kind or "")
    :gsub("__SCOPE__", scope or "")
    :gsub("__EXCLUDE__", exclude or "")
end

local function compile_selector_delete_step(action, params, plan_index, step_index)
  action = canonical_action(action)
  local kind = DELETE_SELECTOR_KINDS[action]
  if not kind then return nil end

  local scope = selector_scope(params)
  local exclude = selector_exclude(params)
  if scope == "" and exclude ~= "" then scope = "all" end

  local needs_script = exclude ~= ""
  if kind == "region" or kind == "marker" then
    needs_script = needs_script or scope == "selected" or scope == "current" or scope == "time_selection"
  end
  if kind == "item" and scope ~= "" then
    needs_script = true
  end
  if not needs_script then return nil end

  local code = generic_delete_script(kind, scope, exclude)
  return {
    id = "step_" .. tostring(step_index or 1),
    kind = "script",
    type = "script",
    source = "action_protocol",
    code = code,
    raw = "[ACTION:" .. tostring(action) .. " scope=" .. tostring(scope) .. " exclude=" .. tostring(exclude) .. "]",
    valid = true,
    validation_error = nil,
    status = "pending",
    risk = "medium",
    action_protocol = {
      action = action,
      selector_kind = kind,
      scope = scope,
      exclude = exclude,
      plan_index = plan_index,
    },
  }
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
  local scope_token = selector_token(scope)
  if truthy(params.all) or is_all(scope) then
    params.all = "true"
    params.scope = nil
  elseif scope_token == "current" or scope_token == "time_selection" then
    params.scope = scope_token
    if params.target == scope then params.target = nil end
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
    local selector_step = compile_selector_delete_step(item.action, item.params or {}, index, #steps + 1)
    if selector_step then
      selector_step.raw = "[ACTION:" .. tostring(item.raw or item.action or "") .. "]"
      table.insert(steps, selector_step)
    else
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
  end
  return {
    turn = turn,
    plan = plan,
    steps = steps,
    diagnostics = diagnostics,
  }
end

return ActionProtocol
