local PlanContract = {}

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function truthy(value)
  value = trim(value):lower()
  return value == "true" or value == "1" or value == "yes" or value == "on"
end

local function selected_token(value)
  value = trim(value):lower()
  return value == "selected" or value == "selection" or value == "current"
    or value == "当前" or value == "选中" or value == "已选中"
end

local function split_names(raw)
  raw = tostring(raw or ""):gsub("，", ","):gsub("、", ","):gsub("|", ","):gsub(";", ",")
  local result = {}
  for part in raw:gmatch("[^,]+") do
    part = trim(part)
    if part ~= "" then table.insert(result, part) end
  end
  return result
end

local function int_value(value)
  value = trim(value)
  if value == "" then return nil end
  local n = tonumber(value)
  if not n then return nil end
  return math.max(1, math.floor(n))
end

local function created_ref_kind(value)
  value = trim(value):lower():gsub("%s+", "")
  local kind = value:match("^created%.([%w_]+)%[%d+%]$")
  if kind then return kind end
  kind = value:match("^generated%.([%w_]+)%[%d+%]$")
  if kind then return kind end
  return nil
end

local TRACK_CONSUMERS = {
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

local ITEM_CONSUMERS = {
  ["item/fade"] = true,
  ["item/set_fade"] = true,
  ["item/fade_shape"] = true,
  ["item/set_fade_shape"] = true,
}

local function track_create_group(params)
  params = params or {}
  local names = split_names(params.names or params.track_names or "")
  local count = int_value(params.count) or (#names > 0 and #names or 1)
  if #names > count then count = #names end
  local refs = {}
  for i = 1, count do
    refs[i] = "created.tracks[" .. tostring(i) .. "]"
  end
  return { kind = "track", count = count, refs = refs, names = names }
end

local function generated_item_group(params)
  params = params or {}
  local count = int_value(params.count) or 1
  local refs = {}
  for i = 1, count do
    refs[i] = "created.items[" .. tostring(i) .. "]"
  end
  return { kind = "item", count = count, refs = refs }
end

local function marker_group()
  return { kind = "marker", count = 1, refs = { "created.markers[1]" } }
end

local function has_track_target(endpoint, params)
  params = params or {}
  if truthy(params.selected) or truthy(params.all) then return true end
  local keys
  if endpoint == "track/rename" then
    keys = { "target", "old_name", "from", "track_name", "index" }
  elseif endpoint == "track/add_fx" or endpoint == "track/remove_fx" then
    keys = { "target", "track", "track_name", "index" }
  else
    keys = { "target", "track", "track_name", "name", "index" }
  end
  for _, key in ipairs(keys) do
    local value = trim(params[key])
    if value ~= "" then
      local kind = created_ref_kind(value)
      if not kind or kind == "tracks" then return true end
    end
  end
  return false
end

local function has_implicit_first_track_target(endpoint, params)
  params = params or {}
  if not TRACK_CONSUMERS[endpoint] then return false end
  if truthy(params.selected) or truthy(params.all) then return false end
  if trim(params.target) ~= "" or trim(params.track_name) ~= "" then return false end
  if endpoint == "track/rename" and (trim(params.old_name) ~= "" or trim(params.from) ~= "") then return false end

  local value = trim(params.index)
  if value == "" then value = trim(params.track) end
  return value == "0"
end

local function has_item_target(params)
  params = params or {}
  if truthy(params.selected) or truthy(params.all) or truthy(params.all_items) then return true end
  for _, key in ipairs({ "item", "target", "index", "name", "match", "item_name" }) do
    local value = trim(params[key])
    if value ~= "" and not selected_token(value) then return true end
    if selected_token(value) then return true end
  end
  return false
end

local function has_marker_target(params)
  params = params or {}
  for _, key in ipairs({ "index", "target", "marker" }) do
    local value = trim(params[key])
    if value ~= "" then return true end
  end
  return false
end

local function rebuild_step(step, endpoint, params, build_call)
  local old_call = step.call
  step.call = build_call(endpoint, params)
  step.raw = "[MCP_CALL:" .. step.call .. "]"
  step.endpoint = endpoint
  step.params = params
  return old_call ~= step.call
end

local function bind_track_to_group(step, endpoint, params, group, build_call)
  if not group or group.kind ~= "track" or group.count ~= 1 then return nil end
  params.target = group.refs[1]
  params.track = nil
  params.track_name = nil
  params.index = nil
  if endpoint == "track/rename" then
    params.old_name = nil
    params.from = nil
  end
  if rebuild_step(step, endpoint, params, build_call) then
    return "Plan Contract: bound " .. endpoint .. " to " .. group.refs[1]
  end
  return nil
end

local BATCH_TRACK_CONSUMERS = {
  ["track/set_volume"] = true,
  ["track/set_volume_by_name"] = true,
  ["track/set_pan"] = true,
  ["track/set_color"] = true,
  ["track/mute"] = true,
  ["track/solo"] = true,
  ["track/add_fx"] = true,
}

local function bind_track_to_group_ref(step, endpoint, params, ref, build_call)
  params.target = ref
  params.track = nil
  params.track_name = nil
  params.index = nil
  params.name = nil
  if endpoint == "track/rename" then
    params.old_name = nil
    params.from = nil
  end
  return rebuild_step(step, endpoint, params, build_call)
end

local function expand_track_to_group(steps, index, step, endpoint, params, group, build_call)
  if not group or group.kind ~= "track" or group.count <= 1 then return nil end
  if not BATCH_TRACK_CONSUMERS[endpoint] then return nil end
  local refs = group.refs or {}
  if #refs == 0 then return nil end
  table.remove(steps, index)
  for offset, ref in ipairs(refs) do
    local copy_params = {}
    for key, value in pairs(params or {}) do copy_params[key] = value end
    local new_step = {}
    for key, value in pairs(step or {}) do new_step[key] = value end
    bind_track_to_group_ref(new_step, endpoint, copy_params, ref, build_call)
    table.insert(steps, index + offset - 1, new_step)
  end
  return "Plan Contract: expanded " .. endpoint .. " to " .. tostring(#refs) .. " created tracks"
end

local function bind_item_to_group(step, endpoint, params, group, build_call)
  if not group or group.kind ~= "item" or group.count ~= 1 then return nil end
  params.item = group.refs[1]
  params.target = nil
  params.index = nil
  params.selected = nil
  if rebuild_step(step, endpoint, params, build_call) then
    return "Plan Contract: bound " .. endpoint .. " to " .. group.refs[1]
  end
  return nil
end

local function bind_marker_to_group(step, endpoint, params, group, build_call)
  if not group or group.kind ~= "marker" or group.count ~= 1 then return nil end
  params.target = group.refs[1]
  params.marker = nil
  params.index = nil
  if rebuild_step(step, endpoint, params, build_call) then
    return "Plan Contract: bound " .. endpoint .. " to " .. group.refs[1]
  end
  return nil
end

local function clarification_key(item)
  local fields = item.fields or {}
  local normalized = {}
  for _, field in ipairs(fields) do
    local value = trim(field):lower()
    if value ~= "" then table.insert(normalized, value) end
  end
  table.sort(normalized)
  if #normalized > 0 then
    return "fields:" .. table.concat(normalized, ",")
  end
  return "question:" .. trim(item.question or item.reason)
end

local function append_unique(list, value)
  value = trim(value)
  if value == "" then return end
  for _, existing in ipairs(list) do
    if existing == value then return end
  end
  table.insert(list, value)
end

local function append_unique_number(list, value)
  local n = tonumber(value)
  if not n or n <= 0 then return end
  for _, existing in ipairs(list) do
    if tonumber(existing) == n then return end
  end
  table.insert(list, n)
end

function PlanContract.create(deps)
  deps = deps or {}
  local parse_call = deps.parse_call
  local build_call = deps.build_call
  if type(parse_call) ~= "function" then error("PlanContract requires parse_call", 0) end
  if type(build_call) ~= "function" then error("PlanContract requires build_call", 0) end

  local M = {}

  function M.apply_bindings(steps)
    local notes = {}
    local last_track_group = nil
    local last_item_group = nil
    local last_marker_group = nil

    local i = 1
    while i <= #(steps or {}) do
      local step = steps[i]
      if step and step.kind == "mcp" then
        local endpoint, params = parse_call(step.call or "")
        if endpoint == "track/create" then
          last_track_group = track_create_group(params)
          i = i + 1
        elseif endpoint == "sfx/generate_variants" then
          last_item_group = generated_item_group(params)
          i = i + 1
        elseif endpoint == "marker/add" then
          last_marker_group = marker_group()
          i = i + 1
        elseif TRACK_CONSUMERS[endpoint] then
          if not has_track_target(endpoint, params) or has_implicit_first_track_target(endpoint, params) then
            local note = expand_track_to_group(steps, i, step, endpoint, params, last_track_group, build_call)
            if note then
              table.insert(notes, note)
              i = i + last_track_group.count
            else
              note = bind_track_to_group(step, endpoint, params, last_track_group, build_call)
              if note then table.insert(notes, note) end
              i = i + 1
            end
          else
            i = i + 1
          end
        elseif ITEM_CONSUMERS[endpoint] then
          if not has_item_target(params) then
            local note = bind_item_to_group(step, endpoint, params, last_item_group, build_call)
            if note then table.insert(notes, note) end
          end
          i = i + 1
        elseif endpoint == "marker/delete" then
          if not has_marker_target(params) then
            local note = bind_marker_to_group(step, endpoint, params, last_marker_group, build_call)
            if note then table.insert(notes, note) end
          end
          i = i + 1
        else
          i = i + 1
        end
      else
        i = i + 1
      end
    end

    return notes
  end

  function M.merge_clarifications(clarifications)
    local merged = {}
    local by_key = {}
    for _, item in ipairs(clarifications or {}) do
      local key = clarification_key(item)
      local existing = by_key[key]
      if existing then
        existing.merged_count = (existing.merged_count or 1) + 1
        existing.step_index = 0
        existing.endpoint = "plan"
        append_unique_number(existing.step_indices, item.step_index)
        for _, option in ipairs(item.options or {}) do append_unique(existing.options, option) end
        for _, note in ipairs(item.notes or {}) do append_unique(existing.notes, note) end
      else
        local copy = {
          step_index = item.step_index,
          endpoint = item.endpoint,
          question = item.question,
          options = {},
          notes = {},
          fields = item.fields or {},
          free_input = item.free_input ~= false,
          placeholder = item.placeholder or "",
          reason = item.reason,
          merged_count = 1,
          step_indices = {},
        }
        append_unique_number(copy.step_indices, item.step_index)
        for _, option in ipairs(item.options or {}) do append_unique(copy.options, option) end
        for _, note in ipairs(item.notes or {}) do append_unique(copy.notes, note) end
        table.insert(merged, copy)
        by_key[key] = copy
      end
    end
    return merged
  end

  return M
end

return PlanContract
