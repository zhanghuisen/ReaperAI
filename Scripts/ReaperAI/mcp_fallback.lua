-- ReaperAI MCP fallback module
-- Owns local MCP -> Lua fallback generation and parameter normalization helpers.

local McpFallback = {}

local function lua_quote(s)
  s = tostring(s or "")
  s = s:gsub("\\", "\\\\"):gsub("'", "\\'"):gsub("\n", "\\n"):gsub("\r", "")
  return "'" .. s .. "'"
end

local function selected_token(v)
  v = tostring(v or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower():gsub("%s+", "_")
  return v == "selected" or v == "selection" or v == "current" or
    v == "selected_region" or v == "selected_regions" or v == "current_region" or
    v == "当前" or v == "选中" or v == "已选中" or v == "当前选中" or
    v == "选中的region" or v == "选中的_region" or v == "选中的区域"
end

local function boolish(v)
  v = tostring(v or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
  return v == "true" or v == "1" or v == "yes" or v == "y" or v == "on"
end

local function all_token(v)
  v = tostring(v or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
  return v == "all" or v == "everything" or v == "entire" or v == "project" or
    v == "all_tracks" or v == "all_items" or v == "all_markers" or v == "all_regions" or
    v == "全部" or v == "所有" or v == "整个工程" or v == "所有轨道" or v == "所有标记" or v == "所有区域"
end

local function targets_all(params)
  params = params or {}
  return boolish(params.all) or all_token(params.scope) or all_token(params.target) or all_token(params.tracks)
end

local function split_lua_list_code(raw_var, list_var)
  return "local function trim(s) return (s or ''):gsub('^%s+', ''):gsub('%s+$', '') end\n" ..
    "local function split_list(s)\n" ..
    "  local list = {}\n" ..
    "  s = (s or ''):gsub('，', ','):gsub('、', ','):gsub('|', ','):gsub(';', ',')\n" ..
    "  for part in s:gmatch('[^,]+') do\n" ..
    "    part = trim(part)\n" ..
    "    if part ~= '' then table.insert(list, part) end\n" ..
    "  end\n" ..
    "  return list\n" ..
    "end\n" ..
    "local " .. list_var .. " = split_list(" .. raw_var .. ")\n"
end

local function first_nonempty_param(params, keys)
  params = params or {}
  for _, key in ipairs(keys or {}) do
    local value = params[key]
    if value ~= nil and tostring(value) ~= "" then
      return value
    end
  end
  return ""
end

local function looks_like_numeric_selector(value)
  local text = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then return false end
  text = text:gsub("%s+", "")
  if text:match("^%-?%d+$") then return true end
  if text:match("^[TtRr]?%-?%d+([,;|~:%-][TtRr]?%-?%d+)+$") then return true end
  if text:match("^[TtRr]%d+$") then return true end
  return false
end

local function split_batch_target_and_name(params, object_keys, name_keys)
  params = params or {}
  local target = first_nonempty_param(params, {"range", "ids", "index", "id"})
  local raw_object = first_nonempty_param(params, object_keys)
  local name = first_nonempty_param(params, name_keys)
  if target == "" and looks_like_numeric_selector(raw_object) then
    target = raw_object
  elseif name == "" and raw_object ~= "" and not selected_token(raw_object) and not all_token(raw_object) then
    name = raw_object
  end
  return target, name
end

local function batch_order_values(params)
  return
    first_nonempty_param(params, {"order_range", "ordinal_range", "sequence_range", "order", "ordinal", "sequence", "order_index", "ordinal_index", "sequence_index"}),
    first_nonempty_param(params, {"order_start", "ordinal_start", "sequence_start"}),
    first_nonempty_param(params, {"order_end", "to_order", "ordinal_end", "sequence_end"})
end

local function region_delete_fallback_code(params)
  params = params or {}
  local target = first_nonempty_param(params, {"range", "ids", "index", "id", "region", "target"})
  local start_id = first_nonempty_param(params, {"start", "from"})
  local end_id = first_nonempty_param(params, {"end", "to"})
  local order_target = first_nonempty_param(params, {"order_range", "ordinal_range", "sequence_range", "order", "ordinal", "sequence", "order_index", "ordinal_index", "sequence_index"})
  local order_start = first_nonempty_param(params, {"order_start", "ordinal_start", "sequence_start"})
  local order_end = first_nonempty_param(params, {"order_end", "ordinal_end", "sequence_end"})
  local name = first_nonempty_param(params, {"name", "match"})
  local delete_all = targets_all(params) or all_token(params.regions)
  local selected_regions = false
  local keep_selected = false
  return
    "local raw_target = " .. lua_quote(target) .. "\n" ..
    "local raw_start = " .. lua_quote(start_id) .. "\n" ..
    "local raw_end = " .. lua_quote(end_id) .. "\n" ..
    "local raw_order_target = " .. lua_quote(order_target) .. "\n" ..
    "local raw_order_start = " .. lua_quote(order_start) .. "\n" ..
    "local raw_order_end = " .. lua_quote(order_end) .. "\n" ..
    "local raw_name = " .. lua_quote(name) .. "\n" ..
    "local delete_all = " .. tostring(delete_all) .. "\n" ..
    "local selected_regions = false\n" ..
    "local keep_selected = false\n" ..
    "local wanted = {}\n" ..
    "local order_wanted = {}\n" ..
    "local function trim(s) return tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', '') end\n" ..
    "local function add_id(n) n = tonumber(n); if n then wanted[math.floor(n)] = true end end\n" ..
    "local function add_order(n) n = tonumber(n); if n then order_wanted[math.floor(n)] = true end end\n" ..
    "local function add_range(a, b) a = tonumber(a); b = tonumber(b); if not a or not b then return end; a = math.floor(a); b = math.floor(b); local lo = math.min(a, b); local hi = math.max(a, b); for id = lo, hi do wanted[id] = true end end\n" ..
    "local function add_order_range(a, b) a = tonumber(a); b = tonumber(b); if not a or not b then return end; a = math.floor(a); b = math.floor(b); local lo = math.min(a, b); local hi = math.max(a, b); for idx = lo, hi do order_wanted[idx] = true end end\n" ..
    "local function normalize_token(s) s = trim(s):gsub('^[Rr]egion%s*', ''):gsub('^region%s*', ''):gsub('[Rr]', ''); return trim(s) end\n" ..
    "local function parse_text(s, add_single, add_range_fn)\n" ..
    "  s = normalize_token(s)\n" ..
    "  local a, b = s:match('^(%-?%d+)%s*[%-%~:]%s*(%-?%d+)$')\n" ..
    "  if a and b then add_range_fn(a, b); return end\n" ..
    "  a, b = s:match('(%-?%d+)%s*[%-%~:]%s*(%-?%d+)')\n" ..
    "  if a and b then add_range_fn(a, b) end\n" ..
    "  for part in s:gmatch('[^,%s;|]+') do\n" ..
    "    local token = normalize_token(part)\n" ..
    "    local x, y = token:match('^(%-?%d+)%s*[%-%~:]%s*(%-?%d+)$')\n" ..
    "    if x and y then add_range_fn(x, y) else add_single(token) end\n" ..
    "  end\n" ..
    "end\n" ..
    "if trim(raw_start) ~= '' or trim(raw_end) ~= '' then add_range(raw_start, raw_end) end\n" ..
    "parse_text(raw_target, add_id, add_range)\n" ..
    "if trim(raw_order_start) ~= '' or trim(raw_order_end) ~= '' then add_order_range(raw_order_start, raw_order_end) end\n" ..
    "parse_text(raw_order_target, add_order, add_order_range)\n" ..
    "local has_ids = false; for _ in pairs(wanted) do has_ids = true; break end\n" ..
    "local has_order = false; for _ in pairs(order_wanted) do has_order = true; break end\n" ..
    "local name_filter = trim(raw_name)\n" ..
    "if not delete_all and not has_ids and not has_order and name_filter == '' then return { ok=false, message='region/delete requires index, range, ids, start/end, order_start/order_end, name, match, or all=true' } end\n" ..
    "local function enum_marker(i) if reaper.EnumProjectMarkers3 then return reaper.EnumProjectMarkers3(0, i) end; return reaper.EnumProjectMarkers(i) end\n" ..
    "local marker_total = reaper.CountProjectMarkers(0)\n" ..
    "local regions = {}\n" ..
    "for i = 0, marker_total - 1 do\n" ..
    "  local retval, isrgn, pos, rgnend, rname, markrgnindex = enum_marker(i)\n" ..
    "  if retval ~= 0 and isrgn then table.insert(regions, { id = tonumber(markrgnindex), name = rname or '', pos = pos or 0, rgnend = rgnend or 0 }) end\n" ..
    "end\n" ..
    "table.sort(regions, function(a, b) if (a.pos or 0) ~= (b.pos or 0) then return (a.pos or 0) < (b.pos or 0) end; if (a.rgnend or 0) ~= (b.rgnend or 0) then return (a.rgnend or 0) < (b.rgnend or 0) end; return (a.id or 0) < (b.id or 0) end)\n" ..
    "local targets = {}\n" ..
    "local function close_enough(a, b) return math.abs((tonumber(a) or 0) - (tonumber(b) or 0)) <= 0.001 end\n" ..
    "local function ranges_overlap(a_start, a_end, b_start, b_end) return (a_end or 0) > (b_start or 0) + 0.001 and (a_start or 0) < (b_end or 0) - 0.001 end\n" ..
    "local function selected_region_targets()\n" ..
    "  local ts_start, ts_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)\n" ..
    "  if not ts_start or not ts_end or ts_end <= ts_start then return {}, '当前没有时间选区，无法推断选中的 Region' end\n" ..
    "  local exact, contained, overlap = {}, {}, {}\n" ..
    "  for _, region in ipairs(regions) do\n" ..
    "    local pos = region.pos or 0; local rgnend = region.rgnend or 0\n" ..
    "    if close_enough(pos, ts_start) and close_enough(rgnend, ts_end) then table.insert(exact, region)\n" ..
    "    elseif pos >= ts_start - 0.001 and rgnend <= ts_end + 0.001 then table.insert(contained, region)\n" ..
    "    elseif ranges_overlap(pos, rgnend, ts_start, ts_end) then table.insert(overlap, region) end\n" ..
    "  end\n" ..
    "  if #exact > 0 then return exact, '' end; if #contained > 0 then return contained, '' end; if #overlap > 0 then return overlap, '' end\n" ..
    "  return {}, '时间选区内没有匹配 Region'\n" ..
    "end\n" ..
    "local keep_ids = {}\n" ..
    "if keep_selected then\n" ..
    "  local keep_targets, keep_error = selected_region_targets(); if #keep_targets == 0 then return { ok=false, message=keep_error or 'No selected Region inferred to keep', changed={deleted=0} } end\n" ..
    "  for _, region in ipairs(keep_targets) do if region.id then keep_ids[tonumber(region.id)] = true end end\n" ..
    "end\n" ..
    "if selected_regions and not keep_selected then\n" ..
    "  local selected_targets, selected_error = selected_region_targets(); if #selected_targets == 0 then return { ok=false, message=selected_error or 'No selected Region inferred', changed={deleted=0} } end; targets = selected_targets\n" ..
    "else\n" ..
    "  local needle = name_filter:lower()\n" ..
    "  for order_index, region in ipairs(regions) do\n" ..
    "    local id = tonumber(region.id)\n" ..
    "    local by_id = id and wanted[id]\n" ..
    "    local by_order = order_wanted[order_index] == true\n" ..
    "    local by_name = name_filter ~= '' and tostring(region.name or ''):lower():find(needle, 1, true) ~= nil\n" ..
    "    if delete_all or by_id or by_order or by_name then table.insert(targets, region) end\n" ..
    "  end\n" ..
    "end\n" ..
    "table.sort(targets, function(a, b) return (a.id or 0) > (b.id or 0) end)\n" ..
    "local deleted = 0\n" ..
    "local labels = {}\n" ..
    "for _, region in ipairs(targets) do\n" ..
    "  if region.id and reaper.DeleteProjectMarker(0, region.id, true) then\n" ..
    "    deleted = deleted + 1\n" ..
    "    if #labels < 8 then table.insert(labels, 'R' .. tostring(region.id)) end\n" ..
    "  end\n" ..
    "end\n" ..
    "reaper.UpdateTimeline(); reaper.UpdateArrange()\n" ..
    "if deleted == 0 then return { ok=false, message='No matching Region found', changed={deleted=0} } end\n" ..
    "return { ok=true, message='Deleted ' .. tostring(deleted) .. ' Region(s): ' .. table.concat(labels, ', '), changed={deleted=deleted} }\n"
end

local function track_lookup_code(index, name)
  if name and name ~= "" then
    local q = lua_quote(name)
    return "local target_name = " .. q .. "\n" ..
      "local t = nil\n" ..
      "local track_index = -1\n" ..
      "local exact_track, exact_index = nil, -1\n" ..
      "local partial_track, partial_index = nil, -1\n" ..
      "local needle = target_name:lower()\n" ..
      "for i = 0, reaper.CountTracks(0) - 1 do\n" ..
      "  local candidate = reaper.GetTrack(0, i)\n" ..
      "  if candidate then\n" ..
      "    local _, candidate_name = reaper.GetTrackName(candidate)\n" ..
      "    if candidate_name == target_name then exact_track = candidate; exact_index = i; break\n" ..
      "    elseif not partial_track and candidate_name:lower():find(needle, 1, true) then partial_track = candidate; partial_index = i end\n" ..
      "  end\n" ..
      "end\n" ..
      "t = exact_track or partial_track\n" ..
      "track_index = exact_index >= 0 and exact_index or partial_index\n" ..
      "local track_label = target_name\n"
  end
  if index == nil or tostring(index) == "" then
    return "local track_index = -1\n" ..
      "local t = nil\n" ..
      "local track_label = 'missing track target'\n"
  end
  local idx = tonumber(index)
  if not idx then
    local q = lua_quote(index)
    return "local track_index = -1\n" ..
      "local t = nil\n" ..
      "local track_label = " .. q .. "\n"
  end
  return "local track_index = " .. idx .. "\n" ..
    "local t = reaper.GetTrack(0, track_index)\n" ..
    "local track_label = '#' .. tostring(track_index)\n"
end

local function track_target_index_name(params, allow_name)
  params = params or {}
  local index = tostring(params.index or "")
  local name = allow_name == false and "" or tostring(params.name or "")
  local raw = tostring(params.track or params.target or params.track_name or "")
  if index == "" and tonumber(raw) then
    index = raw
  elseif name == "" and raw ~= "" and not tonumber(raw) and not selected_token(raw) then
    name = raw
  end
  return index, name
end

local function track_color_code(params, color_expr, label, clear_custom)
  params = params or {}
  local target, name = split_batch_target_and_name(params, {"target", "track", "track_name"}, {"name", "match"})
  local start_id = first_nonempty_param(params, {"start", "from"})
  local end_id = first_nonempty_param(params, {"end", "to"})
  local order_target, order_start, order_end = batch_order_values(params)
  local scope = tostring(params.scope or params.selector or params.target_scope or "")
  local selected_tracks = boolish(params.selected) or selected_token(scope) or selected_token(params.target) or selected_token(params.track)
  local set_all = targets_all(params)
  local mode = clear_custom and "clear" or "set"
  return
    "local raw_target = " .. lua_quote(target) .. "\n" ..
    "local raw_start = " .. lua_quote(start_id) .. "\n" ..
    "local raw_end = " .. lua_quote(end_id) .. "\n" ..
    "local raw_order_target = " .. lua_quote(order_target) .. "\n" ..
    "local raw_order_start = " .. lua_quote(order_start) .. "\n" ..
    "local raw_order_end = " .. lua_quote(order_end) .. "\n" ..
    "local raw_name = " .. lua_quote(name) .. "\n" ..
    "local set_all = " .. tostring(set_all) .. "\n" ..
    "local selected_tracks = " .. tostring(selected_tracks) .. "\n" ..
    "local color = " .. color_expr .. "\n" ..
    "local color_label = " .. lua_quote(label) .. "\n" ..
    "local color_mode = " .. lua_quote(mode) .. "\n" ..
    "local wanted, order_wanted = {}, {}\n" ..
    "local function trim(s) return tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', '') end\n" ..
    "local function add_index(n) n=tonumber(n); if n then wanted[math.floor(n)] = true end end\n" ..
    "local function add_order(n) n=tonumber(n); if n then order_wanted[math.floor(n)] = true end end\n" ..
    "local function add_range(a,b) a=tonumber(a); b=tonumber(b); if not a or not b then return end; local lo=math.min(math.floor(a), math.floor(b)); local hi=math.max(math.floor(a), math.floor(b)); for idx=lo,hi do wanted[idx]=true end end\n" ..
    "local function add_order_range(a,b) a=tonumber(a); b=tonumber(b); if not a or not b then return end; local lo=math.min(math.floor(a), math.floor(b)); local hi=math.max(math.floor(a), math.floor(b)); for idx=lo,hi do order_wanted[idx]=true end end\n" ..
    "local function normalize_token(s) s=trim(s):gsub('^[Tt]rack%s*',''):gsub('^track%s*',''):gsub('[Tt]',''); return trim(s) end\n" ..
    "local function parse_text(s, add_single, add_range_fn) s=normalize_token(s); local a,b=s:match('^(%-?%d+)%s*[%-%~:]%s*(%-?%d+)$'); if a and b then add_range_fn(a,b); return end; a,b=s:match('(%-?%d+)%s*[%-%~:]%s*(%-?%d+)'); if a and b then add_range_fn(a,b) end; for part in s:gmatch('[^,%s;|]+') do local token=normalize_token(part); local x,y=token:match('^(%-?%d+)%s*[%-%~:]%s*(%-?%d+)$'); if x and y then add_range_fn(x,y) else add_single(token) end end end\n" ..
    "if trim(raw_start) ~= '' or trim(raw_end) ~= '' then add_range(raw_start, raw_end) end; parse_text(raw_target, add_index, add_range)\n" ..
    "if trim(raw_order_start) ~= '' or trim(raw_order_end) ~= '' then add_order_range(raw_order_start, raw_order_end) end; parse_text(raw_order_target, add_order, add_order_range)\n" ..
    "local has_indices=false; for _ in pairs(wanted) do has_indices=true; break end; local has_order=false; for _ in pairs(order_wanted) do has_order=true; break end\n" ..
    "local name_filter=trim(raw_name); if not set_all and not selected_tracks and not has_indices and not has_order and name_filter == '' then return { ok=false, message='track/set_color requires a track target', changed={tracks=0} } end\n" ..
    "local exact_name_exists=false; if name_filter ~= '' then for i=0,reaper.CountTracks(0)-1 do local tr=reaper.GetTrack(0,i); if tr then local _,tn=reaper.GetTrackName(tr); if tn == name_filter then exact_name_exists=true; break end end end end\n" ..
    "local targets={}; local needle=name_filter:lower(); for i=0,reaper.CountTracks(0)-1 do local tr=reaper.GetTrack(0,i); if tr then local _,tn=reaper.GetTrackName(tr); local order_index=i+1; local selected=reaper.IsTrackSelected and reaper.IsTrackSelected(tr); local by_index=wanted[i] == true; local by_order=order_wanted[order_index] == true; local by_name=false; if name_filter ~= '' then if exact_name_exists then by_name=tn == name_filter else by_name=tostring(tn or ''):lower():find(needle,1,true) ~= nil end end; if set_all or by_index or by_order or by_name or (selected_tracks and selected) then table.insert(targets,{track=tr,index=i,name=tn or ''}) end end end\n" ..
    "local changed=0; local labels={}; for _,target in ipairs(targets) do if color_mode == 'clear' then reaper.SetMediaTrackInfo_Value(target.track,'I_CUSTOMCOLOR',0) else reaper.SetTrackColor(target.track,color) end; changed=changed+1; if #labels < 8 then table.insert(labels, target.name ~= '' and target.name or ('#' .. tostring(target.index))) end end\n" ..
    "reaper.TrackList_AdjustWindows(false); reaper.UpdateArrange(); if changed == 0 then return { ok=false, message='No matching track found for track/set_color', changed={tracks=0} } end\n" ..
    "local action=color_mode == 'clear' and 'Cleared custom color on ' or ('Set color to ' .. color_label .. ' on '); return { ok=true, message=action .. tostring(changed) .. ' track(s): ' .. table.concat(labels, ', '), changed={tracks=changed} }\n"
end

local function track_clear_color_code(params)
  params = params or {}
  return track_color_code(params, "0", "default", true)
end

local function env_value(raw, lane, default)
  raw = tostring(raw or "")
  lane = tostring(lane or "volume"):lower()
  if raw == "" then return default end
  if lane == "volume" then
    local db = raw:lower():match("^%s*([%-%.%d]+)%s*db%s*$")
    if db then return 10 ^ ((tonumber(db) or 0) / 20) end
    local pct = raw:match("^%s*([%-%.%d]+)%s*%%%s*$")
    if pct then return math.max(0, (tonumber(pct) or 0) / 100) end
    return math.max(0, tonumber(raw) or default)
  elseif lane == "pan" then
    local pct = raw:match("^%s*([%-%.%d]+)%s*%%%s*$")
    if pct then return math.max(-1, math.min(1, (tonumber(pct) or 0) / 100)) end
    return math.max(-1, math.min(1, tonumber(raw) or default))
  elseif lane == "mute" then
    raw = raw:lower()
    return (raw == "1" or raw == "true" or raw == "on" or raw == "yes") and 1 or 0
  end
  return tonumber(raw) or default
end

local function time_to_seconds(raw, assume_ms)
  raw = tostring(raw or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if raw == "" then return nil end
  local lower = raw:lower()
  local ms = lower:match("^([%-%.%d]+)%s*ms$")
  if ms then return math.max(0, (tonumber(ms) or 0) / 1000) end
  local sec = lower:match("^([%-%.%d]+)%s*s$")
  if sec then return math.max(0, tonumber(sec) or 0) end
  local num = tonumber(lower)
  if not num then return nil end
  if assume_ms then num = num / 1000 end
  return math.max(0, num)
end

local function first_time_seconds(params, keys)
  for _, key in ipairs(keys or {}) do
    local raw = params[key]
    if raw and raw ~= "" then
      local value = time_to_seconds(raw, key:match("_ms$") or key == "ms" or key == "in_ms" or key == "out_ms")
      if value ~= nil then return value end
    end
  end
  return nil
end

local function color_to_rgb(raw)
  raw = tostring(raw or "red")
  local key = raw:lower()
  local colors = {
    red = {255, 0, 0}, ["红"] = {255, 0, 0}, ["红色"] = {255, 0, 0},
    green = {0, 180, 0}, ["绿"] = {0, 180, 0}, ["绿色"] = {0, 180, 0},
    blue = {0, 96, 255}, ["蓝"] = {0, 96, 255}, ["蓝色"] = {0, 96, 255},
    yellow = {255, 220, 0}, ["黄"] = {255, 220, 0}, ["黄色"] = {255, 220, 0},
    orange = {255, 128, 0}, ["橙"] = {255, 128, 0}, ["橙色"] = {255, 128, 0},
    purple = {160, 80, 255}, ["紫"] = {160, 80, 255}, ["紫色"] = {160, 80, 255},
    pink = {255, 105, 180}, ["粉"] = {255, 105, 180}, ["粉色"] = {255, 105, 180},
    cyan = {0, 200, 220}, ["青"] = {0, 200, 220}, ["青色"] = {0, 200, 220},
    white = {255, 255, 255}, ["白"] = {255, 255, 255}, ["白色"] = {255, 255, 255},
    gray = {128, 128, 128}, grey = {128, 128, 128}, ["灰"] = {128, 128, 128}, ["灰色"] = {128, 128, 128},
    black = {0, 0, 0}, ["黑"] = {0, 0, 0}, ["黑色"] = {0, 0, 0},
  }
  local rgb = colors[key]
  if rgb then return rgb[1], rgb[2], rgb[3], raw end
  local hex = raw:match("^#?(%x%x%x%x%x%x)$")
  if hex then
    return tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16), raw
  end
  local r, g, b = raw:match("^%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*$")
  if r and g and b then
    return math.max(0, math.min(255, tonumber(r) or 0)),
      math.max(0, math.min(255, tonumber(g) or 0)),
      math.max(0, math.min(255, tonumber(b) or 0)),
      raw
  end
  return 255, 0, 0, raw
end

local function custom_color_expr(params)
  local color_raw = params.color or params.value or params.rgb or "red"
  local r, g, b, label = color_to_rgb(color_raw)
  local color_key = tostring(color_raw or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
  local clear_color = color_key == "default" or color_key == "clear" or color_key == "none" or color_key == "reset" or color_key == "native" or color_key == "0" or color_key == "默认" or color_key == "默认色" or color_key == "清除" or color_key == "清空" or color_key == "恢复默认"
  if clear_color then
    return "0", "default"
  end
  return "reaper.ColorToNative(" .. r .. ", " .. g .. ", " .. b .. ") + 16777216", label
end

local function region_set_color_fallback_code(params)
  params = params or {}
  local color_expr, label = custom_color_expr(params)
  local target = first_nonempty_param(params, {"range", "ids", "index", "id", "region", "target"})
  local start_id = first_nonempty_param(params, {"start", "from"})
  local end_id = first_nonempty_param(params, {"end", "to"})
  local order_target = first_nonempty_param(params, {"order_range", "ordinal_range", "sequence_range", "order", "ordinal", "sequence", "order_index", "ordinal_index", "sequence_index"})
  local order_start = first_nonempty_param(params, {"order_start", "ordinal_start", "sequence_start"})
  local order_end = first_nonempty_param(params, {"order_end", "ordinal_end", "sequence_end"})
  local name = first_nonempty_param(params, {"name", "match"})
  local scope = tostring(params.scope or params.selector or params.target_scope or ""):lower()
  local current_region = boolish(params.current) or scope == "current" or scope == "cursor" or scope == "edit_cursor"
  local time_selection_regions = boolish(params.time_selection) or scope == "time_selection" or scope == "time-selection" or scope == "timerange" or scope == "time_range" or scope == "loop_selection"
  local selected_regions = boolish(params.selected) or (selected_token(scope) and not current_region and not time_selection_regions)
  local set_all = targets_all(params) or all_token(params.regions)
  return
    "local raw_target = " .. lua_quote(target) .. "\n" ..
    "local raw_start = " .. lua_quote(start_id) .. "\n" ..
    "local raw_end = " .. lua_quote(end_id) .. "\n" ..
    "local raw_order_target = " .. lua_quote(order_target) .. "\n" ..
    "local raw_order_start = " .. lua_quote(order_start) .. "\n" ..
    "local raw_order_end = " .. lua_quote(order_end) .. "\n" ..
    "local raw_name = " .. lua_quote(name) .. "\n" ..
    "local color = " .. color_expr .. "\n" ..
    "local color_label = " .. lua_quote(label) .. "\n" ..
    "local set_all = " .. tostring(set_all) .. "\n" ..
    "local selected_regions = " .. tostring(selected_regions) .. "\n" ..
    "local current_region = " .. tostring(current_region) .. "\n" ..
    "local time_selection_regions = " .. tostring(time_selection_regions) .. "\n" ..
    "local EPS = 0.001\n" ..
    "if not reaper.SetProjectMarker3 then return { ok=false, message='region/set_color requires reaper.SetProjectMarker3', changed={regions=0} } end\n" ..
    "local wanted, order_wanted = {}, {}\n" ..
    "local function trim(s) return tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', '') end\n" ..
    "local function add_id(n) n=tonumber(n); if n then wanted[math.floor(n)] = true end end\n" ..
    "local function add_order(n) n=tonumber(n); if n then order_wanted[math.floor(n)] = true end end\n" ..
    "local function add_range(a,b) a=tonumber(a); b=tonumber(b); if not a or not b then return end; local lo=math.min(math.floor(a), math.floor(b)); local hi=math.max(math.floor(a), math.floor(b)); for id=lo,hi do wanted[id]=true end end\n" ..
    "local function add_order_range(a,b) a=tonumber(a); b=tonumber(b); if not a or not b then return end; local lo=math.min(math.floor(a), math.floor(b)); local hi=math.max(math.floor(a), math.floor(b)); for idx=lo,hi do order_wanted[idx]=true end end\n" ..
    "local function normalize_token(s) s=trim(s):gsub('^[Rr]egion%s*',''):gsub('^region%s*',''):gsub('[Rr]',''); return trim(s) end\n" ..
    "local function parse_text(s, add_single, add_range_fn) s=normalize_token(s); local a,b=s:match('^(%-?%d+)%s*[%-%~:]%s*(%-?%d+)$'); if a and b then add_range_fn(a,b); return end; a,b=s:match('(%-?%d+)%s*[%-%~:]%s*(%-?%d+)'); if a and b then add_range_fn(a,b) end; for part in s:gmatch('[^,%s;|]+') do local token=normalize_token(part); local x,y=token:match('^(%-?%d+)%s*[%-%~:]%s*(%-?%d+)$'); if x and y then add_range_fn(x,y) else add_single(token) end end end\n" ..
    "local function close_enough(a,b) return math.abs((tonumber(a) or 0)-(tonumber(b) or 0)) <= EPS end\n" ..
    "local function ranges_overlap(a_start,a_end,b_start,b_end) return (tonumber(a_end) or 0) > (tonumber(b_start) or 0) + EPS and (tonumber(a_start) or 0) < (tonumber(b_end) or 0) - EPS end\n" ..
    "if trim(raw_start) ~= '' or trim(raw_end) ~= '' then add_range(raw_start, raw_end) end; parse_text(raw_target, add_id, add_range)\n" ..
    "if trim(raw_order_start) ~= '' or trim(raw_order_end) ~= '' then add_order_range(raw_order_start, raw_order_end) end; parse_text(raw_order_target, add_order, add_order_range)\n" ..
    "local has_ids=false; for _ in pairs(wanted) do has_ids=true; break end; local has_order=false; for _ in pairs(order_wanted) do has_order=true; break end\n" ..
    "local name_filter=trim(raw_name); local contextual=selected_regions or current_region or time_selection_regions\n" ..
    "if not set_all and not contextual and not has_ids and not has_order and name_filter == '' then return { ok=false, message='region/set_color requires a Region target', changed={regions=0} } end\n" ..
    "local function enum_region_source(i) if reaper.EnumProjectMarkers3 then return reaper.EnumProjectMarkers3(0, i) end; return reaper.EnumProjectMarkers(i) end\n" ..
    "local _, marker_count, region_count = reaper.CountProjectMarkers(0); local total=(tonumber(marker_count) or 0)+(tonumber(region_count) or 0); local regions={}\n" ..
    "for i=0,total-1 do local retval,isrgn,pos,rgnend,rname,markrgnindex=enum_region_source(i); if retval ~= 0 and isrgn then table.insert(regions,{id=tonumber(markrgnindex), name=rname or '', pos=pos or 0, rgnend=rgnend or 0}) end end\n" ..
    "table.sort(regions, function(a,b) if (a.pos or 0) ~= (b.pos or 0) then return (a.pos or 0) < (b.pos or 0) end; if (a.rgnend or 0) ~= (b.rgnend or 0) then return (a.rgnend or 0) < (b.rgnend or 0) end; return (a.id or 0) < (b.id or 0) end)\n" ..
    "local ts_active, ts_start, ts_end=false,0,0; if reaper.GetSet_LoopTimeRange then ts_start,ts_end=reaper.GetSet_LoopTimeRange(false,false,0,0,false); ts_start=tonumber(ts_start) or 0; ts_end=tonumber(ts_end) or 0; ts_active=ts_end > ts_start + EPS end\n" ..
    "local cursor=reaper.GetCursorPosition and (tonumber(reaper.GetCursorPosition()) or 0) or 0; local targets={}; local needle=name_filter:lower()\n" ..
    "for order_index,region in ipairs(regions) do local id=tonumber(region.id); local by_id=id and wanted[id]; local by_order=order_wanted[order_index] == true; local by_name=name_filter ~= '' and tostring(region.name or ''):lower():find(needle,1,true) ~= nil; local in_time=ts_active and ranges_overlap(region.pos, region.rgnend, ts_start, ts_end); local inferred_selected=ts_active and ((close_enough(region.pos,ts_start) and close_enough(region.rgnend,ts_end)) or (region.pos >= ts_start - EPS and region.rgnend <= ts_end + EPS) or in_time); local at_cursor=cursor >= (region.pos or 0) - EPS and cursor <= (region.rgnend or 0) + EPS; if set_all or by_id or by_order or by_name or (selected_regions and inferred_selected) or (time_selection_regions and in_time) or (current_region and at_cursor) then table.insert(targets, region) end end\n" ..
    "local changed=0; local labels={}; for _,region in ipairs(targets) do if region.id then local ok=reaper.SetProjectMarker3(0, region.id, true, region.pos, region.rgnend, region.name, color); if ok then changed=changed+1; if #labels < 8 then table.insert(labels, 'R' .. tostring(region.id)) end end end end\n" ..
    "reaper.UpdateTimeline(); reaper.UpdateArrange(); if changed == 0 then return { ok=false, message='No matching Region found for region/set_color', changed={regions=0} } end\n" ..
    "return { ok=true, message='Set ' .. tostring(changed) .. ' Region(s) color to ' .. color_label .. ': ' .. table.concat(labels, ', '), changed={regions=changed} }\n"
end

local function item_set_color_fallback_code(params)
  params = params or {}
  local color_expr, label = custom_color_expr(params)
  local target = first_nonempty_param(params, {"index", "item", "target"})
  local name = first_nonempty_param(params, {"name", "match", "item_name"})
  local scope = tostring(params.scope or params.selector or params.target_scope or ""):lower()
  local current_item = boolish(params.current) or scope == "current" or scope == "cursor" or scope == "edit_cursor"
  local time_selection_items = boolish(params.time_selection) or scope == "time_selection" or scope == "time-selection" or scope == "timerange" or scope == "time_range" or scope == "loop_selection"
  local selected_items = boolish(params.selected) or ((selected_token(scope) or selected_token(params.target) or selected_token(params.item)) and not current_item and not time_selection_items)
  local set_all = targets_all(params) or all_token(params.items)
  return
    "local raw_target = " .. lua_quote(target) .. "\n" ..
    "local raw_name = " .. lua_quote(name) .. "\n" ..
    "local color = " .. color_expr .. "\n" ..
    "local color_label = " .. lua_quote(label) .. "\n" ..
    "local set_all = " .. tostring(set_all) .. "\n" ..
    "local selected_items = " .. tostring(selected_items) .. "\n" ..
    "local current_item = " .. tostring(current_item) .. "\n" ..
    "local time_selection_items = " .. tostring(time_selection_items) .. "\n" ..
    "local EPS = 0.001\n" ..
    "local function trim(s) return tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', '') end\n" ..
    "local function ranges_overlap(a_start,a_end,b_start,b_end) return (tonumber(a_end) or 0) > (tonumber(b_start) or 0) + EPS and (tonumber(a_start) or 0) < (tonumber(b_end) or 0) - EPS end\n" ..
    "local function item_name(item) local take=item and reaper.GetActiveTake(item); if take and reaper.GetTakeName then return reaper.GetTakeName(take) or '' end; return '' end\n" ..
    "local function target_index(raw) raw=trim(raw):gsub('^[Ii]tem%s*',''):gsub('[Ii]',''); local n=tonumber(raw); if not n then return nil end; return math.floor(n) end\n" ..
    "local wanted_index=target_index(raw_target); local name_filter=trim(raw_name); local contextual=selected_items or current_item or time_selection_items\n" ..
    "if not set_all and not contextual and wanted_index == nil and name_filter == '' then return { ok=false, message='item/set_color requires an item target', changed={items=0} } end\n" ..
    "local ts_active, ts_start, ts_end=false,0,0; if reaper.GetSet_LoopTimeRange then ts_start,ts_end=reaper.GetSet_LoopTimeRange(false,false,0,0,false); ts_start=tonumber(ts_start) or 0; ts_end=tonumber(ts_end) or 0; ts_active=ts_end > ts_start + EPS end\n" ..
    "local cursor=reaper.GetCursorPosition and (tonumber(reaper.GetCursorPosition()) or 0) or 0; local needle=name_filter:lower(); local targets={}\n" ..
    "for i=0,reaper.CountMediaItems(0)-1 do local item=reaper.GetMediaItem(0,i); if item then local selected=reaper.IsMediaItemSelected and reaper.IsMediaItemSelected(item); local pos=tonumber(reaper.GetMediaItemInfo_Value(item,'D_POSITION')) or 0; local len=tonumber(reaper.GetMediaItemInfo_Value(item,'D_LENGTH')) or 0; local item_end=pos+len; local in_time=ts_active and ranges_overlap(pos,item_end,ts_start,ts_end); local at_cursor=cursor >= pos - EPS and cursor <= item_end + EPS; local by_name=name_filter ~= '' and item_name(item):lower():find(needle,1,true) ~= nil; if set_all or (wanted_index ~= nil and i == wanted_index) or (selected_items and selected) or (time_selection_items and in_time) or (current_item and at_cursor) or by_name then table.insert(targets,item) end end end\n" ..
    "local changed=0; for _,item in ipairs(targets) do reaper.SetMediaItemInfo_Value(item, 'I_CUSTOMCOLOR', color); if reaper.UpdateItemInProject then reaper.UpdateItemInProject(item) end; changed=changed+1 end\n" ..
    "reaper.UpdateArrange(); if changed == 0 then return { ok=false, message='No matching item found for item/set_color', changed={items=0} } end\n" ..
    "return { ok=true, message='Set ' .. tostring(changed) .. ' item(s) color to ' .. color_label, changed={items=changed} }\n"
end

local function item_set_color_fallback_code(params)
  params = params or {}
  local color_expr, label = custom_color_expr(params)
  local target, name = split_batch_target_and_name(params, {"item", "target"}, {"name", "match", "item_name"})
  local start_id = first_nonempty_param(params, {"start", "from"})
  local end_id = first_nonempty_param(params, {"end", "to"})
  local order_target, order_start, order_end = batch_order_values(params)
  local scope = tostring(params.scope or params.selector or params.target_scope or ""):lower()
  local current_item = boolish(params.current) or scope == "current" or scope == "cursor" or scope == "edit_cursor"
  local time_selection_items = boolish(params.time_selection) or scope == "time_selection" or scope == "time-selection" or scope == "timerange" or scope == "time_range" or scope == "loop_selection"
  local selected_items = boolish(params.selected) or ((selected_token(scope) or selected_token(params.target) or selected_token(params.item)) and not current_item and not time_selection_items)
  local set_all = targets_all(params) or all_token(params.items)
  return
    "local raw_target = " .. lua_quote(target) .. "\n" ..
    "local raw_start = " .. lua_quote(start_id) .. "\n" ..
    "local raw_end = " .. lua_quote(end_id) .. "\n" ..
    "local raw_order_target = " .. lua_quote(order_target) .. "\n" ..
    "local raw_order_start = " .. lua_quote(order_start) .. "\n" ..
    "local raw_order_end = " .. lua_quote(order_end) .. "\n" ..
    "local raw_name = " .. lua_quote(name) .. "\n" ..
    "local color = " .. color_expr .. "\n" ..
    "local color_label = " .. lua_quote(label) .. "\n" ..
    "local set_all = " .. tostring(set_all) .. "\n" ..
    "local selected_items = " .. tostring(selected_items) .. "\n" ..
    "local current_item = " .. tostring(current_item) .. "\n" ..
    "local time_selection_items = " .. tostring(time_selection_items) .. "\n" ..
    "local EPS = 0.001\n" ..
    "local wanted, order_wanted = {}, {}\n" ..
    "local function trim(s) return tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', '') end\n" ..
    "local function add_index(n) n=tonumber(n); if n then wanted[math.floor(n)] = true end end\n" ..
    "local function add_order(n) n=tonumber(n); if n then order_wanted[math.floor(n)] = true end end\n" ..
    "local function add_range(a,b) a=tonumber(a); b=tonumber(b); if not a or not b then return end; local lo=math.min(math.floor(a), math.floor(b)); local hi=math.max(math.floor(a), math.floor(b)); for idx=lo,hi do wanted[idx]=true end end\n" ..
    "local function add_order_range(a,b) a=tonumber(a); b=tonumber(b); if not a or not b then return end; local lo=math.min(math.floor(a), math.floor(b)); local hi=math.max(math.floor(a), math.floor(b)); for idx=lo,hi do order_wanted[idx]=true end end\n" ..
    "local function normalize_token(s) s=trim(s):gsub('^[Ii]tem%s*',''):gsub('^item%s*',''):gsub('[Ii]',''); return trim(s) end\n" ..
    "local function parse_text(s, add_single, add_range_fn) s=normalize_token(s); local a,b=s:match('^(%-?%d+)%s*[%-%~:]%s*(%-?%d+)$'); if a and b then add_range_fn(a,b); return end; a,b=s:match('(%-?%d+)%s*[%-%~:]%s*(%-?%d+)'); if a and b then add_range_fn(a,b) end; for part in s:gmatch('[^,%s;|]+') do local token=normalize_token(part); local x,y=token:match('^(%-?%d+)%s*[%-%~:]%s*(%-?%d+)$'); if x and y then add_range_fn(x,y) else add_single(token) end end end\n" ..
    "local function ranges_overlap(a_start,a_end,b_start,b_end) return (tonumber(a_end) or 0) > (tonumber(b_start) or 0) + EPS and (tonumber(a_start) or 0) < (tonumber(b_end) or 0) - EPS end\n" ..
    "local function item_name(item) local take=item and reaper.GetActiveTake(item); if take and reaper.GetTakeName then return reaper.GetTakeName(take) or '' end; return '' end\n" ..
    "if trim(raw_start) ~= '' or trim(raw_end) ~= '' then add_range(raw_start, raw_end) end; parse_text(raw_target, add_index, add_range)\n" ..
    "if trim(raw_order_start) ~= '' or trim(raw_order_end) ~= '' then add_order_range(raw_order_start, raw_order_end) end; parse_text(raw_order_target, add_order, add_order_range)\n" ..
    "local has_indices=false; for _ in pairs(wanted) do has_indices=true; break end; local has_order=false; for _ in pairs(order_wanted) do has_order=true; break end\n" ..
    "local name_filter=trim(raw_name); local contextual=selected_items or current_item or time_selection_items\n" ..
    "if not set_all and not contextual and not has_indices and not has_order and name_filter == '' then return { ok=false, message='item/set_color requires an item target', changed={items=0} } end\n" ..
    "local ts_active, ts_start, ts_end=false,0,0; if reaper.GetSet_LoopTimeRange then ts_start,ts_end=reaper.GetSet_LoopTimeRange(false,false,0,0,false); ts_start=tonumber(ts_start) or 0; ts_end=tonumber(ts_end) or 0; ts_active=ts_end > ts_start + EPS end\n" ..
    "local cursor=reaper.GetCursorPosition and (tonumber(reaper.GetCursorPosition()) or 0) or 0; local needle=name_filter:lower(); local targets={}\n" ..
    "for i=0,reaper.CountMediaItems(0)-1 do local item=reaper.GetMediaItem(0,i); if item then local selected=reaper.IsMediaItemSelected and reaper.IsMediaItemSelected(item); local pos=tonumber(reaper.GetMediaItemInfo_Value(item,'D_POSITION')) or 0; local len=tonumber(reaper.GetMediaItemInfo_Value(item,'D_LENGTH')) or 0; local item_end=pos+len; local order_index=i+1; local in_time=ts_active and ranges_overlap(pos,item_end,ts_start,ts_end); local at_cursor=cursor >= pos - EPS and cursor <= item_end + EPS; local by_name=name_filter ~= '' and item_name(item):lower():find(needle,1,true) ~= nil; if set_all or wanted[i] == true or order_wanted[order_index] == true or (selected_items and selected) or (time_selection_items and in_time) or (current_item and at_cursor) or by_name then table.insert(targets,item) end end end\n" ..
    "local changed=0; for _,item in ipairs(targets) do reaper.SetMediaItemInfo_Value(item, 'I_CUSTOMCOLOR', color); if reaper.UpdateItemInProject then reaper.UpdateItemInProject(item) end; changed=changed+1 end\n" ..
    "reaper.UpdateArrange(); if changed == 0 then return { ok=false, message='No matching item found for item/set_color', changed={items=0} } end\n" ..
    "return { ok=true, message='Set ' .. tostring(changed) .. ' item(s) color to ' .. color_label, changed={items=changed} }\n"
end

local function envelope_fallback_code(params, clear_only)
  local target
  if params.target or params.scope then
    target = (params.target or params.scope):lower()
  elseif params.item or params.item_name then
    target = "item"
  elseif params.track or params.track_name then
    target = "track"
  else
    target = "auto"
  end
  local forced_selected = false
  local target_aliases = {
    selected = "auto",
    selection = "auto",
    current = "auto",
    ["当前"] = "auto",
    ["选中"] = "auto",
    ["已选中"] = "auto",
    selected_item = "item",
    selected_items = "item",
    selection_item = "item",
    selection_items = "item",
    selected_take = "take",
    selected_takes = "take",
    selected_track = "track",
    selected_tracks = "track",
    selected_track_envelope = "selected_envelope",
    selected_env = "selected_envelope",
  }
  if target_aliases[target] then
    target = target_aliases[target]
    forced_selected = true
  end
  local lane = (params.lane or params.type or params.envelope or "volume"):lower()
  if lane == "声像" then lane = "pan" elseif lane == "静音" then lane = "mute" else lane = (lane == "pan" or lane == "mute") and lane or "volume" end
  local name = params.name or params.match or params.track_name or params.item_name or ""
  local index = params.index or ""
  local track_or_item = params.track or params.item or ""
  local function is_selected_token(v)
    v = tostring(v or ""):lower()
    return v == "selected" or v == "selection" or v == "current" or v == "当前" or v == "选中" or v == "已选中"
  end
  if is_selected_token(params.item) then
    target = "item"
    forced_selected = true
    track_or_item = ""
    name = ""
  elseif is_selected_token(params.take) then
    target = "take"
    forced_selected = true
    track_or_item = ""
    name = ""
  elseif is_selected_token(params.track) then
    target = "track"
    forced_selected = true
    track_or_item = ""
    name = ""
  elseif is_selected_token(name) and (target == "item" or target == "take" or target == "track" or target == "auto") then
    forced_selected = true
    name = ""
  end
  if name == "" and track_or_item ~= "" and not tonumber(track_or_item) then
    name = track_or_item
  elseif index == "" and tonumber(track_or_item) then
    index = track_or_item
  end
  local selected = (forced_selected or params.selected == "true" or params.selected == "1") and "true" or "false"
  local shape = (params.shape or "line"):lower()
  local start_given = (params.start or params.time or params.from_time) ~= nil
  local end_given = (params["end"] or params.to_time) ~= nil
  local duration_given = (params.duration or params.length) ~= nil
  local use_time_selection = (params.time_selection == "true" or params.use_time_selection == "true" or params.selection == "true")
  local explicit_target_raw = tostring(params.target or params.scope or ""):lower()
  local has_explicit_target = selected == "true"
    or (explicit_target_raw ~= "" and explicit_target_raw ~= "auto")
    or tostring(params.item or "") ~= ""
    or tostring(params.item_name or "") ~= ""
    or tostring(params.track or "") ~= ""
    or tostring(params.track_name or "") ~= ""
    or tostring(params.take or "") ~= ""
    or tostring(name or "") ~= ""
    or tostring(index or "") ~= ""
  if not has_explicit_target then
    return "return '✗ envelope 操作需要明确包络目标，不能自动猜测轨道或素材'"
  end
  if clear_only and not use_time_selection and not start_given and not end_given and not duration_given and target ~= "selected_envelope" then
    return "return '✗ envelope/clear 需要明确清理范围，不能默认清理未知范围'"
  end
  local start_pos = tonumber(params.start or params.time or params.from_time) or 0
  local end_pos = tonumber(params["end"] or params.to_time)
  if not end_pos then end_pos = start_pos + (tonumber(params.duration or params.length) or 1) end
  local origin = (params.origin or ""):lower()
  local absolute = (params.absolute == "true" or origin == "project" or origin == "absolute")
  local relative = (not absolute and params.relative ~= "false" and params.item_relative ~= "false") and "true" or "false"
  local steps = math.max(1, tonumber(params.steps or params.points) or 16)
  local default_from, default_to
  if lane == "volume" and (shape == "fade_in" or shape == "fadein") then
    default_from, default_to = 0.001, 1
  elseif lane == "volume" and (shape == "fade_out" or shape == "fadeout") then
    default_from, default_to = 1, 0.001
  elseif lane == "pan" then
    default_from, default_to = 0, 0
  else
    default_from, default_to = 1, 1
  end
  local from_value = env_value(params["from"] or params.from_value or params.value1, lane, default_from)
  local to_value = env_value(params["to"] or params.to_value or params.value2 or params.value, lane, default_to)
  local clear = (clear_only or params.replace ~= "false") and "true" or "false"
  local action_track = lane == "pan" and 40407 or (lane == "mute" and 40867 or 40406)
  local action_take = lane == "pan" and 40694 or (lane == "mute" and 40695 or 40693)
  local env_name = lane == "pan" and "Pan" or (lane == "mute" and "Mute" or "Volume")

  return "local target=" .. lua_quote(target) .. "\n" ..
    "local lane=" .. lua_quote(lane) .. "\n" ..
    "local target_name=" .. lua_quote(name) .. "\n" ..
    "local target_index=" .. lua_quote(index) .. "\n" ..
    "local selected=" .. selected .. "\n" ..
    "local start_pos=" .. start_pos .. "\n" ..
    "local end_pos=" .. end_pos .. "\n" ..
    "local item_relative=" .. relative .. "\n" ..
    "local absolute_time=" .. (absolute and "true" or "false") .. "\n" ..
    "local start_given=" .. (start_given and "true" or "false") .. "\n" ..
    "local end_given=" .. (end_given and "true" or "false") .. "\n" ..
    "local duration_given=" .. (duration_given and "true" or "false") .. "\n" ..
    "local use_time_selection=" .. (use_time_selection and "true" or "false") .. "\n" ..
    "local clear_existing=" .. clear .. "\n" ..
    "local clear_only=" .. (clear_only and "true" or "false") .. "\n" ..
    "local shape=" .. lua_quote(shape) .. "\n" ..
    "local original_shape=" .. lua_quote(shape) .. "\n" ..
    "local from_value=" .. tostring(from_value) .. "\n" ..
    "local to_value=" .. tostring(to_value) .. "\n" ..
    "local steps=" .. tostring(steps) .. "\n" ..
    "local env_name=" .. lua_quote(env_name) .. "\n" ..
    "local action_track=" .. tostring(action_track) .. "\n" ..
    "local action_take=" .. tostring(action_take) .. "\n" ..
    "local clear_start=nil\nlocal clear_end=nil\n" ..
    "if target=='auto' then if selected and reaper.CountSelectedMediaItems(0)>0 then target='item' else target='track' end end\n" ..
    "local function lname(s) return tostring(s or ''):lower() end\n" ..
    "local function get_track_name(t) local _, n = reaper.GetTrackName(t); return n or '' end\n" ..
    "local function get_take_name(take) return take and (reaper.GetTakeName(take) or '') or '' end\n" ..
    "local function find_track()\n" ..
    "  if selected then local t = reaper.GetSelectedTrack(0,0); if t then return t, 'selected track' end end\n" ..
    "  if target_index ~= '' then local t = reaper.GetTrack(0, tonumber(target_index) or 0); if t then return t, '#'..target_index end end\n" ..
    "  if target_name ~= '' then local exact,partial=nil,nil; local needle=lname(target_name); for i=0,reaper.CountTracks(0)-1 do local t=reaper.GetTrack(0,i); local n=get_track_name(t); if n==target_name then exact=t break elseif not partial and lname(n):find(needle,1,true) then partial=t end end; if exact or partial then return exact or partial, target_name end end\n" ..
    "  return nil, target_name ~= '' and target_name or '#'..target_index\n" ..
    "end\n" ..
    "local function find_item()\n" ..
    "  if selected then local it = reaper.GetSelectedMediaItem(0,0); if it then return it, 'selected item' end end\n" ..
    "  if target_index ~= '' then local it = reaper.GetMediaItem(0, tonumber(target_index) or 0); if it then return it, '#'..target_index end end\n" ..
    "  if target_name ~= '' then local exact,partial=nil,nil; local needle=lname(target_name); for i=0,reaper.CountMediaItems(0)-1 do local it=reaper.GetMediaItem(0,i); local tk=reaper.GetActiveTake(it); local n=get_take_name(tk); if n==target_name then exact=it break elseif not partial and lname(n):find(needle,1,true) then partial=it end end; if exact or partial then return exact or partial, target_name end end\n" ..
    "  return nil, target_name ~= '' and target_name or '#'..target_index\n" ..
    "end\n" ..
    "local function force_env(env) if not env or not reaper.GetEnvelopeStateChunk or not reaper.SetEnvelopeStateChunk then return env end; local ok,chunk=reaper.GetEnvelopeStateChunk(env,'',false); if ok and chunk and chunk~='' then if chunk:find('\\nVIS%s+') then chunk=chunk:gsub('\\nVIS%s+[%d%-]+','\\nVIS 1') else chunk=chunk:gsub('\\n','\\nVIS 1\\n',1) end; if chunk:find('\\nACT%s+') then chunk=chunk:gsub('\\nACT%s+[%d%-]+','\\nACT 1') else chunk=chunk:gsub('\\n','\\nACT 1\\n',1) end; reaper.SetEnvelopeStateChunk(env,chunk,false) end; return env end\n" ..
    "local function ensure_track_env(track) local env=reaper.GetTrackEnvelopeByName(track, env_name); if env then return force_env(env) end; reaper.SetOnlyTrackSelected(track); reaper.Main_OnCommand(action_track,0); return force_env(reaper.GetTrackEnvelopeByName(track, env_name)) end\n" ..
    "local function ensure_take_env(item,take) local env=reaper.GetTakeEnvelopeByName(take, env_name); if env then return force_env(env) end; reaper.SelectAllMediaItems(0,false); reaper.SetMediaItemSelected(item,true); reaper.SetActiveTake(take); reaper.Main_OnCommand(action_take,0); return force_env(reaper.GetTakeEnvelopeByName(take, env_name)) end\n" ..
    "local function points() local pts={}; local function add(t,v) pts[#pts+1]={t=t,v=v} end; if end_pos < start_pos then start_pos,end_pos=end_pos,start_pos end; local len=math.max(0.000001,end_pos-start_pos); if shape=='hold' or shape=='constant' then add(start_pos,from_value); add(end_pos,from_value) elseif shape=='sine' or shape=='sin' then for i=0,steps do local ph=i/steps; local a=(1-math.cos(ph*math.pi*2))/2; add(start_pos+len*ph, from_value+(to_value-from_value)*a) end elseif shape=='pulse' or shape=='square' then for i=0,steps do add(start_pos+len*i/steps, (i%2==0) and from_value or to_value) end elseif shape=='triangle' then for i=0,steps do local ph=i/steps; local a=ph<=0.5 and ph*2 or (1-ph)*2; add(start_pos+len*ph, from_value+(to_value-from_value)*a) end else add(start_pos,from_value); add(end_pos,to_value) end; return pts end\n" ..
    "local env,label=nil,''\n" ..
    "if target=='selected_envelope' then env=reaper.GetSelectedEnvelope and reaper.GetSelectedEnvelope(0); label='selected envelope'; if not absolute_time then local a,b=reaper.GetSet_LoopTimeRange(false,false,0,0,false); local c=reaper.GetCursorPosition(); if (use_time_selection or (start_pos==0 and end_pos==1)) and b>a then start_pos=a; end_pos=b else start_pos=c+start_pos; end_pos=c+end_pos end end elseif target=='item' or target=='take' then local item; item,label=find_item(); if not item then return '✗ Item not found: '..label end; local item_start=reaper.GetMediaItemInfo_Value(item,'D_POSITION'); local item_len=reaper.GetMediaItemInfo_Value(item,'D_LENGTH'); local item_end=item_start+item_len; local ts_start,ts_end=reaper.GetSet_LoopTimeRange(false,false,0,0,false); if use_time_selection and ts_end>ts_start then start_pos=math.max(item_start,ts_start)-item_start; end_pos=math.min(item_end,ts_end)-item_start; if end_pos<=start_pos then start_pos=0; end_pos=item_len end elseif absolute_time then start_pos=start_pos-item_start; end_pos=end_pos-item_start elseif not start_given and not end_given and not duration_given then start_pos=0; end_pos=item_len elseif start_given and (end_given or duration_given) then local eps=0.0001; local looks_project_time=(start_pos>=item_start-eps and start_pos<=item_end+eps) or (end_pos>=item_start-eps and end_pos<=item_end+eps) or (start_pos>item_len and end_pos>item_len); if looks_project_time then start_pos=start_pos-item_start; end_pos=end_pos-item_start end elseif item_relative then end; start_pos=math.max(0,math.min(item_len,start_pos)); end_pos=math.max(0,math.min(item_len,end_pos)); clear_start=0; clear_end=item_len; local take=reaper.GetActiveTake(item); if not take then return '✗ Item has no active take: '..label end; env=ensure_take_env(item,take) else local track; track,label=find_track(); if not track then return '✗ Track not found: '..label end; if not absolute_time then local a,b=reaper.GetSet_LoopTimeRange(false,false,0,0,false); local c=reaper.GetCursorPosition(); if (use_time_selection or (start_pos==0 and end_pos==1)) and b>a then start_pos=a; end_pos=b else start_pos=c+start_pos; end_pos=c+end_pos end end; env=ensure_track_env(track) end\n" ..
    "if not env then return '✗ Envelope not available: '..env_name..' ('..label..')' end\n" ..
    "if clear_existing then reaper.DeleteEnvelopePointRange(env,clear_start or start_pos,clear_end or end_pos) end; local pts=clear_only and {} or points(); if target=='item' or target=='take' then if original_shape=='fade_in' then pts[#pts+1]={t=clear_end or end_pos,v=to_value} elseif original_shape=='fade_out' then table.insert(pts,1,{t=clear_start or start_pos,v=from_value}) end end; local sm=reaper.GetEnvelopeScalingMode and reaper.GetEnvelopeScalingMode(env) or 0; local function pv(v) if target=='item' or target=='take' then if lane=='volume' and reaper.ScaleToEnvelopeMode then return reaper.ScaleToEnvelopeMode(1,v) end; return v end; return reaper.ScaleToEnvelopeMode and reaper.ScaleToEnvelopeMode(sm,v) or v end; for _,p in ipairs(pts) do reaper.InsertEnvelopePoint(env,p.t,pv(p.v),0,0,false,true) end; reaper.Envelope_SortPoints(env); reaper.UpdateArrange()\n" ..
    "if clear_only then return '已清理 '..label..' 的 '..env_name..' 包络' end; return '已绘制 '..label..' 的 '..env_name..' 包络 ('..shape..', '..#pts..' 点)'"
end

function McpFallback.create()
  local Fallback = {}

  function Fallback.mcp_to_lua_fallback(call_str)
    local endpoint, param_str = call_str:match("^([^%?]+)%?(.+)$")
    if not endpoint then
      endpoint = call_str
      param_str = ""
    end

    local params = {}
    if param_str and param_str ~= "" then
      for k, v in param_str:gmatch("([^&=]+)=([^&]+)") do
        local function url_decode(s)
          s = tostring(s or "")
          s = s:gsub("+", " ")
          s = s:gsub("%%(%x%x)", function(hex)
            return string.char(tonumber(hex, 16))
          end)
          return s
        end
        params[url_decode(k)] = url_decode(v)
      end
    end

    local selection_target_endpoints = {
      ["track/delete"] = true,
      ["track/rename"] = true,
      ["track/set_volume"] = true,
      ["track/set_pan"] = true,
      ["track/set_color"] = true,
      ["track/clear_color"] = true,
      ["region/set_color"] = true,
      ["item/set_color"] = true,
      ["track/mute"] = true,
      ["track/solo"] = true,
      ["item/fade"] = true,
      ["item/set_fade"] = true,
      ["item/fade_shape"] = true,
      ["item/set_fade_shape"] = true,
      ["envelope/draw"] = true,
      ["envelope/clear"] = true,
    }
    if selection_target_endpoints[endpoint] then
      local selected_keys = {"target", "scope", "track", "item", "take", "name", "index"}
      local preserve_current = endpoint == "region/set_color" or endpoint == "item/set_color"
      local function is_current_alias(value)
        value = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower():gsub("%s+", "_")
        return value == "current" or value == "current_region" or value == "current_item" or value == "cursor" or value == "edit_cursor"
      end
      local has_selected_alias = false
      for _, key in ipairs(selected_keys) do
        if selected_token(params[key]) and not (preserve_current and is_current_alias(params[key])) then
          has_selected_alias = true
          params[key] = nil
        end
      end
      if has_selected_alias then
        params.selected = "true"
      end
    end

    local lua_code = nil
    local desc = nil

    local function bool_param(v)
      v = tostring(v or ""):lower()
      return v == "true" or v == "1" or v == "yes" or v == "on"
    end

    if endpoint == "transport/play" then
      lua_code = "reaper.OnPlayButton()\nreturn '开始播放'"
      desc = "transport/play (本地fallback)"

    elseif endpoint == "transport/stop" then
      lua_code = "reaper.OnStopButton()\nreturn '停止播放'"
      desc = "transport/stop (本地fallback)"

    elseif endpoint == "track/create" then
      local raw_names = params.names or params.track_names or ""
      local explicit_names = {}
      if raw_names ~= "" then
        local normalized = tostring(raw_names):gsub("\239\188\140", ","):gsub("|", ","):gsub(";", ",")
        for part in normalized:gmatch("[^,]+") do
          local token = part:gsub("^%s+", ""):gsub("%s+$", "")
          if token ~= "" then table.insert(explicit_names, token) end
        end
      end
      local count = tonumber(params.count) or (#explicit_names > 0 and #explicit_names or 1)
      if #explicit_names > count then count = #explicit_names end
      local name = params.name or ""
      local vol_db = params.volume or ""
      lua_code = "local count = " .. count .. "\n"
      lua_code = lua_code .. "local explicit_names = {}\n"
      for i, explicit_name in ipairs(explicit_names) do
        lua_code = lua_code .. "explicit_names[" .. tostring(i) .. "] = " .. lua_quote(explicit_name) .. "\n"
      end
      lua_code = lua_code .. "local base_name = " .. lua_quote(name) .. "\n"
      lua_code = lua_code .. "local tracks = {}\n"
      lua_code = lua_code .. "for i = 1, count do\n"
      lua_code = lua_code .. "  reaper.InsertTrackAtIndex(reaper.CountTracks(0), true)\n"
      lua_code = lua_code .. "  local t = reaper.GetTrack(0, reaper.CountTracks(0) - 1)\n"
      lua_code = lua_code .. "  local new_name = explicit_names[i] or (count > 1 and base_name ~= '' and (base_name .. ' ' .. tostring(i)) or base_name)\n"
      lua_code = lua_code .. "  if t and new_name ~= '' then reaper.GetSetMediaTrackInfo_String(t, 'P_NAME', new_name, true) end\n"
      if vol_db ~= "" then
        local vol_lin = 10 ^ (tonumber(vol_db:gsub("dB", "")) / 20)
        lua_code = lua_code .. "  if t then reaper.SetMediaTrackInfo_Value(t, 'D_VOL', " .. tostring(vol_lin) .. ") end\n"
      end
      lua_code = lua_code .. "end\n"
      lua_code = lua_code .. "reaper.UpdateArrange()\n"
      lua_code = lua_code .. "return '已创建 " .. count .. " 个轨道'"
      desc = "track/create (本地fallback)"

    elseif endpoint == "track/delete" then
      if params.selected == "true" then
        lua_code = "local count = 0\n"
        lua_code = lua_code .. "for i = reaper.CountTracks(0) - 1, 0, -1 do\n"
        lua_code = lua_code .. "  local t = reaper.GetTrack(0, i)\n"
        lua_code = lua_code .. "  if reaper.IsTrackSelected(t) then\n"
        lua_code = lua_code .. "    reaper.DeleteTrack(t)\n"
        lua_code = lua_code .. "    count = count + 1\n"
        lua_code = lua_code .. "  end\n"
        lua_code = lua_code .. "end\n"
        lua_code = lua_code .. "reaper.UpdateArrange()\n"
        lua_code = lua_code .. "return '已删除 ' .. count .. ' 个选中轨道'"
      else
        local keyword = params.match or params.contains or params.keyword or params.name or ""
        if targets_all(params) then
          lua_code = "local deleted = {}\n"
          lua_code = lua_code .. "for i = reaper.CountTracks(0) - 1, 0, -1 do\n"
          lua_code = lua_code .. "  local t = reaper.GetTrack(0, i)\n"
          lua_code = lua_code .. "  if t then\n"
          lua_code = lua_code .. "    local _, n = reaper.GetTrackName(t)\n"
          lua_code = lua_code .. "    table.insert(deleted, 1, n ~= '' and n or ('Track ' .. tostring(i + 1)))\n"
          lua_code = lua_code .. "    reaper.DeleteTrack(t)\n"
          lua_code = lua_code .. "  end\n"
          lua_code = lua_code .. "end\n"
          lua_code = lua_code .. "reaper.UpdateArrange()\n"
          lua_code = lua_code .. "return 'Deleted ' .. #deleted .. ' track(s): ' .. table.concat(deleted, ', ')"
        elseif keyword ~= "" then
          lua_code = "local keyword = " .. lua_quote(keyword) .. "\n"
          lua_code = lua_code .. "local exact = {}\n"
          lua_code = lua_code .. "local partial = {}\n"
          lua_code = lua_code .. "local needle = keyword:lower()\n"
          lua_code = lua_code .. "for i = 0, reaper.CountTracks(0) - 1 do\n"
          lua_code = lua_code .. "  local t = reaper.GetTrack(0, i)\n"
          lua_code = lua_code .. "  if t then\n"
          lua_code = lua_code .. "    local _, n = reaper.GetTrackName(t)\n"
          lua_code = lua_code .. "    if n == keyword then table.insert(exact, {index=i, name=n}) elseif n:lower():find(needle, 1, true) then table.insert(partial, {index=i, name=n}) end\n"
          lua_code = lua_code .. "  end\n"
          lua_code = lua_code .. "end\n"
          lua_code = lua_code .. "local targets = #exact > 0 and exact or partial\n"
          lua_code = lua_code .. "if #targets == 0 then return '✗ 轨道不存在: ' .. keyword end\n"
          lua_code = lua_code .. "local deleted = {}\n"
          lua_code = lua_code .. "for i = #targets, 1, -1 do\n"
          lua_code = lua_code .. "  local t = reaper.GetTrack(0, targets[i].index)\n"
          lua_code = lua_code .. "  if t then table.insert(deleted, targets[i].name); reaper.DeleteTrack(t) end\n"
          lua_code = lua_code .. "end\n"
          lua_code = lua_code .. "reaper.UpdateArrange()\n"
          lua_code = lua_code .. "return '已删除 ' .. #deleted .. ' 个匹配轨道: ' .. table.concat(deleted, ', ')"
        else
          local track_index, track_name = track_target_index_name(params, true)
          lua_code = track_lookup_code(track_index, track_name)
          lua_code = lua_code .. "if t then\n"
          lua_code = lua_code .. "  reaper.DeleteTrack(t)\n"
          lua_code = lua_code .. "  reaper.UpdateArrange()\n"
          lua_code = lua_code .. "  return '已删除轨道 ' .. track_label\n"
          lua_code = lua_code .. "else\n"
          lua_code = lua_code .. "  return '✗ 轨道不存在: ' .. track_label\n"
          lua_code = lua_code .. "end"
        end
      end
      desc = "track/delete (本地fallback)"

    elseif endpoint == "track/rename" then
      local name = params.new_name or params.to or params.name or "未命名"
      if params.selected == "true" then
        lua_code = "local count = 0\n"
        lua_code = lua_code .. "for i = 0, reaper.CountTracks(0) - 1 do\n"
        lua_code = lua_code .. "  local t = reaper.GetTrack(0, i)\n"
        lua_code = lua_code .. "  if reaper.IsTrackSelected(t) then\n"
        lua_code = lua_code .. "    reaper.GetSetMediaTrackInfo_String(t, 'P_NAME', " .. lua_quote(name) .. ", true)\n"
        lua_code = lua_code .. "    count = count + 1\n"
        lua_code = lua_code .. "  end\n"
        lua_code = lua_code .. "end\n"
        lua_code = lua_code .. "return '已重命名 ' .. count .. ' 个轨道为 ' .. " .. lua_quote(name)
      else
        local target_name = params.target or params.old_name or params.from or params.track_name
        local lookup_name = params.index and nil or target_name
        lua_code = track_lookup_code(params.index, lookup_name)
        lua_code = lua_code .. "if t then\n"
        lua_code = lua_code .. "  reaper.GetSetMediaTrackInfo_String(t, 'P_NAME', " .. lua_quote(name) .. ", true)\n"
        lua_code = lua_code .. "  return '已重命名轨道 ' .. track_label .. ' 为 ' .. " .. lua_quote(name) .. "\n"
        lua_code = lua_code .. "else\n"
        lua_code = lua_code .. "  return '✗ 轨道不存在: ' .. track_label\n"
        lua_code = lua_code .. "end"
      end
      desc = "track/rename (本地fallback)"

    elseif endpoint == "track/set_volume" then
      local vol_db = params.volume or "0"
      local vol_lin = 10 ^ (tonumber(vol_db:gsub("dB", "")) / 20)
      if targets_all(params) then
        lua_code = "local vol = " .. tostring(vol_lin) .. "\n"
        lua_code = lua_code .. "local count = 0\n"
        lua_code = lua_code .. "for i = 0, reaper.CountTracks(0) - 1 do\n"
        lua_code = lua_code .. "  local t = reaper.GetTrack(0, i)\n"
        lua_code = lua_code .. "  if t then reaper.SetMediaTrackInfo_Value(t, 'D_VOL', vol); count = count + 1 end\n"
        lua_code = lua_code .. "end\n"
        lua_code = lua_code .. "reaper.UpdateArrange()\n"
        lua_code = lua_code .. "return 'Set ' .. count .. ' track(s) volume to " .. vol_db .. "'"
      elseif params.selected == "true" then
        lua_code = "local vol = " .. tostring(vol_lin) .. "\n"
        lua_code = lua_code .. "local count = 0\n"
        lua_code = lua_code .. "for i = 0, reaper.CountTracks(0) - 1 do\n"
        lua_code = lua_code .. "  local t = reaper.GetTrack(0, i)\n"
        lua_code = lua_code .. "  if reaper.IsTrackSelected(t) then\n"
        lua_code = lua_code .. "    reaper.SetMediaTrackInfo_Value(t, 'D_VOL', vol)\n"
        lua_code = lua_code .. "    count = count + 1\n"
        lua_code = lua_code .. "  end\n"
        lua_code = lua_code .. "end\n"
        lua_code = lua_code .. "return '已设置 ' .. count .. ' 个轨道的音量为 " .. vol_db .. "'"
      else
        local track_index, track_name = track_target_index_name(params, true)
        lua_code = track_lookup_code(track_index, track_name)
        lua_code = lua_code .. "if t then\n"
        lua_code = lua_code .. "  reaper.SetMediaTrackInfo_Value(t, 'D_VOL', " .. tostring(vol_lin) .. ")\n"
        lua_code = lua_code .. "  return '已设置轨道 ' .. track_label .. ' 音量为 " .. vol_db .. "'\n"
        lua_code = lua_code .. "else\n"
        lua_code = lua_code .. "  return '✗ 轨道不存在: ' .. track_label\n"
        lua_code = lua_code .. "end"
      end
      desc = "track/set_volume (本地fallback)"

    elseif endpoint == "track/set_pan" then
      local pan = tonumber(params.pan) or 0
      if targets_all(params) then
        lua_code = "local pan = " .. tostring(pan) .. "\n"
        lua_code = lua_code .. "local count = 0\n"
        lua_code = lua_code .. "for i = 0, reaper.CountTracks(0) - 1 do\n"
        lua_code = lua_code .. "  local t = reaper.GetTrack(0, i)\n"
        lua_code = lua_code .. "  if t then reaper.SetMediaTrackInfo_Value(t, 'D_PAN', pan); count = count + 1 end\n"
        lua_code = lua_code .. "end\n"
        lua_code = lua_code .. "reaper.UpdateArrange()\n"
        lua_code = lua_code .. "return 'Set ' .. count .. ' track(s) pan to " .. tostring(pan) .. "'"
      elseif params.selected == "true" then
        lua_code = "local pan = " .. tostring(pan) .. "\n"
        lua_code = lua_code .. "local count = 0\n"
        lua_code = lua_code .. "for i = 0, reaper.CountTracks(0) - 1 do\n"
        lua_code = lua_code .. "  local t = reaper.GetTrack(0, i)\n"
        lua_code = lua_code .. "  if reaper.IsTrackSelected(t) then\n"
        lua_code = lua_code .. "    reaper.SetMediaTrackInfo_Value(t, 'D_PAN', pan)\n"
        lua_code = lua_code .. "    count = count + 1\n"
        lua_code = lua_code .. "  end\n"
        lua_code = lua_code .. "end\n"
        lua_code = lua_code .. "return '已设置 ' .. count .. ' 个轨道的声像为 " .. tostring(pan) .. "'"
      else
        local track_index, track_name = track_target_index_name(params, true)
        lua_code = track_lookup_code(track_index, track_name)
        lua_code = lua_code .. "if t then\n"
        lua_code = lua_code .. "  reaper.SetMediaTrackInfo_Value(t, 'D_PAN', " .. tostring(pan) .. ")\n"
        lua_code = lua_code .. "  return '已设置轨道 ' .. track_label .. ' 声像为 " .. tostring(pan) .. "'\n"
        lua_code = lua_code .. "else\n"
        lua_code = lua_code .. "  return '✗ 轨道不存在: ' .. track_label\n"
        lua_code = lua_code .. "end"
      end
      desc = "track/set_pan (本地fallback)"

    elseif endpoint == "track/clear_color" then
      lua_code = track_clear_color_code(params)
      desc = "track/clear_color (local fallback)"

    elseif endpoint == "track/set_color" then
      local color_raw = params.color or params.value or params.rgb or "red"
      local r, g, b, label = color_to_rgb(color_raw)
      local color_key = tostring(color_raw or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
      local clear_color = color_key == "default" or color_key == "clear" or color_key == "none" or color_key == "reset" or color_key == "native" or color_key == "0" or color_key == "默认" or color_key == "默认色" or color_key == "清除" or color_key == "清空" or color_key == "恢复默认"
      if clear_color then
        lua_code = track_clear_color_code(params)
        desc = "track/set_color default -> track/clear_color (local fallback)"
      else
      if clear_color then label = "default" end
      local label_q = lua_quote(label)
      local color_expr = clear_color and "0" or ("reaper.ColorToNative(" .. r .. ", " .. g .. ", " .. b .. ") + 16777216")
      lua_code = track_color_code(params, color_expr, label, false)
      desc = "track/set_color (local fallback)"
      if false then
      if targets_all(params) then
        lua_code = "local color = " .. color_expr .. "\n"
        lua_code = lua_code .. "local count = 0\n"
        lua_code = lua_code .. "for i = 0, reaper.CountTracks(0) - 1 do\n"
        lua_code = lua_code .. "  local t = reaper.GetTrack(0, i)\n"
        lua_code = lua_code .. "  if t then reaper.SetTrackColor(t, color); count = count + 1 end\n"
        lua_code = lua_code .. "end\n"
        lua_code = lua_code .. "reaper.UpdateArrange()\n"
        lua_code = lua_code .. "return 'Set ' .. count .. ' track(s) color to ' .. " .. label_q
      elseif params.selected == "true" then
        lua_code = "local color = " .. color_expr .. "\n"
        lua_code = lua_code .. "local count = 0\n"
        lua_code = lua_code .. "for i = 0, reaper.CountTracks(0) - 1 do\n"
        lua_code = lua_code .. "  local t = reaper.GetTrack(0, i)\n"
        lua_code = lua_code .. "  if t and reaper.IsTrackSelected(t) then\n"
        lua_code = lua_code .. "    reaper.SetTrackColor(t, color)\n"
        lua_code = lua_code .. "    count = count + 1\n"
        lua_code = lua_code .. "  end\n"
        lua_code = lua_code .. "end\n"
        lua_code = lua_code .. "reaper.UpdateArrange()\n"
        lua_code = lua_code .. "return '已设置 ' .. count .. ' 个选中轨道颜色为 ' .. " .. label_q
      else
        local track_name = params.name
        local track_index = params.index
        if (not track_name or track_name == "") and (not track_index or track_index == "") then
          track_index, track_name = track_target_index_name(params, true)
        elseif (not track_name or track_name == "") and params.track and not tonumber(params.track) then
          track_name = params.track
        elseif (not track_index or track_index == "") and params.track and tonumber(params.track) then
          track_index = params.track
        end
        lua_code = track_lookup_code(track_index, track_name)
        lua_code = lua_code .. "if t then\n"
        lua_code = lua_code .. "  local color = " .. color_expr .. "\n"
        lua_code = lua_code .. "  reaper.SetTrackColor(t, color)\n"
        lua_code = lua_code .. "  reaper.UpdateArrange()\n"
        lua_code = lua_code .. "  return '已设置轨道 ' .. track_label .. ' 颜色为 ' .. " .. label_q .. "\n"
        lua_code = lua_code .. "else\n"
        lua_code = lua_code .. "  return '✗ 轨道不存在: ' .. track_label\n"
        lua_code = lua_code .. "end"
      end
      desc = "track/set_color (本地fallback)"

      end

      end

    elseif endpoint == "region/set_color" then
      lua_code = region_set_color_fallback_code(params)
      desc = "region/set_color (local fallback)"

    elseif endpoint == "item/set_color" then
      lua_code = item_set_color_fallback_code(params)
      desc = "item/set_color (local fallback)"

    elseif endpoint == "track/mute" then
      local mute_val = (params.mute == "true" or params.mute == "1") and "1" or "0"
      if targets_all(params) then
        lua_code = "local mute = " .. mute_val .. "\n"
        lua_code = lua_code .. "local count = 0\n"
        lua_code = lua_code .. "for i = 0, reaper.CountTracks(0) - 1 do\n"
        lua_code = lua_code .. "  local t = reaper.GetTrack(0, i)\n"
        lua_code = lua_code .. "  if t then reaper.SetMediaTrackInfo_Value(t, 'B_MUTE', mute); count = count + 1 end\n"
        lua_code = lua_code .. "end\n"
        lua_code = lua_code .. "reaper.UpdateArrange()\n"
        lua_code = lua_code .. "return 'Updated mute on ' .. count .. ' track(s)'"
      elseif params.selected == "true" then
        lua_code = "local mute = " .. mute_val .. "\n"
        lua_code = lua_code .. "local count = 0\n"
        lua_code = lua_code .. "for i = 0, reaper.CountTracks(0) - 1 do\n"
        lua_code = lua_code .. "  local t = reaper.GetTrack(0, i)\n"
        lua_code = lua_code .. "  if reaper.IsTrackSelected(t) then\n"
        lua_code = lua_code .. "    reaper.SetMediaTrackInfo_Value(t, 'B_MUTE', mute)\n"
        lua_code = lua_code .. "    count = count + 1\n"
        lua_code = lua_code .. "  end\n"
        lua_code = lua_code .. "end\n"
        lua_code = lua_code .. "return '已' .. (mute == 1 and '静音' or '取消静音') .. ' ' .. count .. ' 个轨道'"
      else
        local track_index, track_name = track_target_index_name(params, true)
        lua_code = track_lookup_code(track_index, track_name)
        lua_code = lua_code .. "if t then\n"
        lua_code = lua_code .. "  reaper.SetMediaTrackInfo_Value(t, 'B_MUTE', " .. mute_val .. ")\n"
        lua_code = lua_code .. "  return '已' .. (" .. mute_val .. " == 1 and '静音' or '取消静音') .. '轨道 ' .. track_label\n"
        lua_code = lua_code .. "else\n"
        lua_code = lua_code .. "  return '✗ 轨道不存在: ' .. track_label\n"
        lua_code = lua_code .. "end"
      end
      desc = "track/mute (本地fallback)"

    elseif endpoint == "track/solo" then
      local solo_val = (params.solo == "true" or params.solo == "1") and "1" or "0"
      if targets_all(params) then
        lua_code = "local solo = " .. solo_val .. "\n"
        lua_code = lua_code .. "local count = 0\n"
        lua_code = lua_code .. "for i = 0, reaper.CountTracks(0) - 1 do\n"
        lua_code = lua_code .. "  local t = reaper.GetTrack(0, i)\n"
        lua_code = lua_code .. "  if t then reaper.SetMediaTrackInfo_Value(t, 'I_SOLO', solo); count = count + 1 end\n"
        lua_code = lua_code .. "end\n"
        lua_code = lua_code .. "reaper.UpdateArrange()\n"
        lua_code = lua_code .. "return 'Updated solo on ' .. count .. ' track(s)'"
      elseif params.selected == "true" then
        lua_code = "local solo = " .. solo_val .. "\n"
        lua_code = lua_code .. "local count = 0\n"
        lua_code = lua_code .. "for i = 0, reaper.CountTracks(0) - 1 do\n"
        lua_code = lua_code .. "  local t = reaper.GetTrack(0, i)\n"
        lua_code = lua_code .. "  if reaper.IsTrackSelected(t) then\n"
        lua_code = lua_code .. "    reaper.SetMediaTrackInfo_Value(t, 'I_SOLO', solo)\n"
        lua_code = lua_code .. "    count = count + 1\n"
        lua_code = lua_code .. "  end\n"
        lua_code = lua_code .. "end\n"
        lua_code = lua_code .. "return '已' .. (solo == 1 and '独奏' or '取消独奏') .. ' ' .. count .. ' 个轨道'"
      else
        local track_index, track_name = track_target_index_name(params, true)
        lua_code = track_lookup_code(track_index, track_name)
        lua_code = lua_code .. "if t then\n"
        lua_code = lua_code .. "  reaper.SetMediaTrackInfo_Value(t, 'I_SOLO', " .. solo_val .. ")\n"
        lua_code = lua_code .. "  return '已' .. (" .. solo_val .. " == 1 and '独奏' or '取消独奏') .. '轨道 ' .. track_label\n"
        lua_code = lua_code .. "else\n"
        lua_code = lua_code .. "  return '✗ 轨道不存在: ' .. track_label\n"
        lua_code = lua_code .. "end"
      end
      desc = "track/solo (本地fallback)"

    elseif endpoint == "track/group_into_folder" or endpoint == "track/create_folder" then
      local folder_name = params.folder_name or params.name or "Folder"
      local tracks_raw = params.tracks or params.track_names or params.names or ""
      local match_raw = params.match or params.contains or params.keyword or ""
      if tracks_raw == "" and match_raw == "" then
        lua_code = "return '✗ 请提供 tracks=轨道名/索引列表 或 match=关键词'"
      else
        lua_code = "local folder_name = " .. lua_quote(folder_name) .. "\n"
        lua_code = lua_code .. "local tracks_raw = " .. lua_quote(tracks_raw) .. "\n"
        lua_code = lua_code .. "local match_raw = " .. lua_quote(match_raw) .. "\n"
        lua_code = lua_code .. split_lua_list_code("tracks_raw", "wanted")
        lua_code = lua_code .. split_lua_list_code("match_raw", "keywords")
        lua_code = lua_code .. "local selected = {}\n"
        lua_code = lua_code .. "local seen = {}\n"
        lua_code = lua_code .. "for i = 0, reaper.CountTracks(0) - 1 do\n"
        lua_code = lua_code .. "  local track = reaper.GetTrack(0, i)\n"
        lua_code = lua_code .. "  local _, name = reaper.GetTrackName(track)\n"
        lua_code = lua_code .. "  local lower_name = name:lower()\n"
        lua_code = lua_code .. "  local hit = false\n"
        lua_code = lua_code .. "  for _, token in ipairs(wanted) do\n"
        lua_code = lua_code .. "    local num = tonumber(token)\n"
        lua_code = lua_code .. "    if num and num == i then hit = true elseif name == token or lower_name:find(token:lower(), 1, true) then hit = true end\n"
        lua_code = lua_code .. "  end\n"
        lua_code = lua_code .. "  for _, token in ipairs(keywords) do\n"
        lua_code = lua_code .. "    if lower_name:find(token:lower(), 1, true) then hit = true end\n"
        lua_code = lua_code .. "  end\n"
        lua_code = lua_code .. "  if hit and not seen[track] then local guid = reaper.GetTrackGUID(track); table.insert(selected, {index = i, name = name, guid = guid}); seen[track] = true end\n"
        lua_code = lua_code .. "end\n"
        lua_code = lua_code .. "if #selected == 0 then return '✗ 没找到要放入文件夹的轨道' end\n"
        lua_code = lua_code .. "table.sort(selected, function(a, b) return a.index < b.index end)\n"
        lua_code = lua_code .. "local insert_index = selected[1].index\n"
        lua_code = lua_code .. "reaper.InsertTrackAtIndex(insert_index, true)\n"
        lua_code = lua_code .. "local folder = reaper.GetTrack(0, insert_index)\n"
        lua_code = lua_code .. "if not folder then return '✗ 文件夹轨道创建失败' end\n"
        lua_code = lua_code .. "reaper.GetSetMediaTrackInfo_String(folder, 'P_NAME', folder_name, true)\n"
        lua_code = lua_code .. "local function find_track_by_guid(guid)\n"
        lua_code = lua_code .. "  for i = 0, reaper.CountTracks(0) - 1 do\n"
        lua_code = lua_code .. "    local track = reaper.GetTrack(0, i)\n"
        lua_code = lua_code .. "    if track then local current_guid = reaper.GetTrackGUID(track); if current_guid == guid then return track, i end end\n"
        lua_code = lua_code .. "  end\n"
        lua_code = lua_code .. "  return nil, -1\n"
        lua_code = lua_code .. "end\n"
        lua_code = lua_code .. "local moved_names = {}\n"
        lua_code = lua_code .. "for i = #selected, 1, -1 do\n"
        lua_code = lua_code .. "  local track = find_track_by_guid(selected[i].guid)\n"
        lua_code = lua_code .. "  if track then\n"
        lua_code = lua_code .. "    reaper.SetOnlyTrackSelected(track)\n"
        lua_code = lua_code .. "    reaper.ReorderSelectedTracks(insert_index + 1, 0)\n"
        lua_code = lua_code .. "    table.insert(moved_names, 1, selected[i].name)\n"
        lua_code = lua_code .. "  end\n"
        lua_code = lua_code .. "end\n"
        lua_code = lua_code .. "reaper.SetMediaTrackInfo_Value(folder, 'I_FOLDERDEPTH', 1)\n"
        lua_code = lua_code .. "for i = 1, #moved_names do\n"
        lua_code = lua_code .. "  local child = reaper.GetTrack(0, insert_index + i)\n"
        lua_code = lua_code .. "  if child then reaper.SetMediaTrackInfo_Value(child, 'I_FOLDERDEPTH', 0) end\n"
        lua_code = lua_code .. "end\n"
        lua_code = lua_code .. "local last_child = reaper.GetTrack(0, insert_index + #moved_names)\n"
        lua_code = lua_code .. "if last_child then reaper.SetMediaTrackInfo_Value(last_child, 'I_FOLDERDEPTH', -1) end\n"
        lua_code = lua_code .. "reaper.TrackList_AdjustWindows(false)\n"
        lua_code = lua_code .. "reaper.UpdateArrange()\n"
        lua_code = lua_code .. "return '已创建文件夹 \"' .. folder_name .. '\" 并放入 ' .. #moved_names .. ' 个轨道: ' .. table.concat(moved_names, ', ')\n"
      end
      desc = endpoint .. " (本地fallback)"

    elseif endpoint == "item/fade" or endpoint == "item/set_fade" then
      local item_raw = params.item or params.target or ""
      local index = params.index or ""
      local name = params.name or params.match or params.item_name or ""
      local function is_selected_token(v)
        v = tostring(v or ""):lower()
        return v == "selected" or v == "selection" or v == "current" or v == "当前" or v == "选中" or v == "已选中"
      end
      local selected = params.selected == "true" or params.selected == "1" or is_selected_token(item_raw)
      if index == "" and tonumber(item_raw) then
        index = item_raw
      elseif name == "" and item_raw ~= "" and not is_selected_token(item_raw) then
        name = item_raw
      end
      local fade_in = first_time_seconds(params, {"fade_in", "in", "fadein", "fade_in_s", "in_s", "fade_in_sec", "in_sec", "fade_in_ms", "in_ms"})
      local fade_out = first_time_seconds(params, {"fade_out", "out", "fadeout", "fade_out_s", "out_s", "fade_out_sec", "out_sec", "fade_out_ms", "out_ms"})
      local fade_in_code = fade_in ~= nil and tostring(fade_in) or "nil"
      local fade_out_code = fade_out ~= nil and tostring(fade_out) or "nil"
      lua_code = "local selected = " .. tostring(selected) .. "\n" ..
        "local target_index = " .. lua_quote(index) .. "\n" ..
        "local target_name = " .. lua_quote(name) .. "\n" ..
        "local fade_in = " .. fade_in_code .. "\n" ..
        "local fade_out = " .. fade_out_code .. "\n" ..
        "if fade_in == nil and fade_out == nil then return '✗ 请提供 fade_in/fade_out 或 fade_in_ms/fade_out_ms' end\n" ..
        "local function lower(s) return tostring(s or ''):lower() end\n" ..
        "local function take_name(item) local take = item and reaper.GetActiveTake(item); return take and (reaper.GetTakeName(take) or '') or '' end\n" ..
        "local function item_label(item, fallback) local name = take_name(item); if name ~= '' then return name end; return fallback or 'item' end\n" ..
        "local function collect_named_item(name) local exact, partial = nil, nil; local needle = lower(name); for i = 0, reaper.CountMediaItems(0) - 1 do local item = reaper.GetMediaItem(0, i); local candidate = take_name(item); if candidate == name then exact = item; break elseif not partial and lower(candidate):find(needle, 1, true) then partial = item end end; return exact or partial end\n" ..
        "local targets = {}\n" ..
        "if selected then local count = reaper.CountSelectedMediaItems(0); if count == 0 then return '✗ 没有选中的 item' end; for i = 0, count - 1 do local item = reaper.GetSelectedMediaItem(0, i); if item then table.insert(targets, { item = item, label = item_label(item, 'selected item ' .. tostring(i + 1)) }) end end\n" ..
        "elseif target_index ~= '' then local item = reaper.GetMediaItem(0, tonumber(target_index) or -1); if not item then return '✗ Item not found: #' .. target_index end; table.insert(targets, { item = item, label = item_label(item, '#' .. target_index) })\n" ..
        "elseif target_name ~= '' then local item = collect_named_item(target_name); if not item then return '✗ Item not found: ' .. target_name end; table.insert(targets, { item = item, label = item_label(item, target_name) })\n" ..
        "else return '✗ 请提供 selected=true 或 index/name' end\n" ..
        "local changed = 0\nlocal labels = {}\n" ..
        "for _, target in ipairs(targets) do local item = target.item; if item then if fade_in ~= nil then reaper.SetMediaItemInfo_Value(item, 'D_FADEINLEN', fade_in) end; if fade_out ~= nil then reaper.SetMediaItemInfo_Value(item, 'D_FADEOUTLEN', fade_out) end; reaper.UpdateItemInProject(item); changed = changed + 1; if #labels < 5 then table.insert(labels, target.label) end end end\n" ..
        "if changed == 0 then return '✗ 没有匹配到 item' end\n" ..
        "local parts = {}\n" ..
        "if fade_in ~= nil then table.insert(parts, string.format('淡入 %.0fms', fade_in * 1000)) end\n" ..
        "if fade_out ~= nil then table.insert(parts, string.format('淡出 %.0fms', fade_out * 1000)) end\n" ..
        "reaper.UpdateArrange()\n" ..
        "local suffix = ''\n" ..
        "if #labels > 0 then suffix = ': ' .. table.concat(labels, ', '); if changed > #labels then suffix = suffix .. ' ...' end end\n" ..
        "return '已设置 ' .. changed .. ' 个 item 的 ' .. table.concat(parts, '、') .. suffix"
      desc = endpoint .. " (本地fallback)"

    elseif endpoint == "item/fade_shape" or endpoint == "item/set_fade_shape" then
      local item_raw = params.item or params.target or ""
      local index = params.index or ""
      local name = params.name or params.match or params.item_name or ""
      local function is_all_token(v)
        v = tostring(v or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
        return v == "all" or v == "everything" or v == "全部" or v == "所有"
      end
      local function bool_param(v)
        v = tostring(v or ""):lower()
        return v == "true" or v == "1" or v == "yes" or v == "on"
      end
      local function fade_shape_value(v, default)
        v = tostring(v or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
        if v == "" then return default or 0 end
        if v == "linear" or v == "line" or v == "straight" or v == "直线" or v == "线性" then return 0 end
        local n = tonumber(v)
        if not n then return default or 0 end
        return math.max(0, math.min(6, math.floor(n + 0.5)))
      end
      local all_items = bool_param(params.all or params.all_items) or is_all_token(item_raw) or is_all_token(params.target)
      local selected = (not all_items) and (params.selected == "true" or params.selected == "1" or selected_token(item_raw))
      if index == "" and tonumber(item_raw) then
        index = item_raw
      elseif name == "" and item_raw ~= "" and not selected_token(item_raw) and not is_all_token(item_raw) then
        name = item_raw
      end
      local direction = tostring(params.direction or params.side or params.fade or "both"):lower()
      local apply_in = not (direction == "out" or direction == "fade_out" or direction == "fadeout" or direction == "尾" or direction == "淡出")
      local apply_out = not (direction == "in" or direction == "fade_in" or direction == "fadein" or direction == "头" or direction == "淡入")
      local shape_default = fade_shape_value(params.shape or params.fade_shape or "linear", 0)
      local fade_in_shape = fade_shape_value(params.fade_in_shape or params.in_shape or params.fadein_shape, shape_default)
      local fade_out_shape = fade_shape_value(params.fade_out_shape or params.out_shape or params.fadeout_shape, shape_default)
      local reset_curve = params.reset_curve ~= "false" and params.reset_curve ~= "0"
      local has_fade_only = params.has_fade ~= "false" and params.only_faded ~= "false"
      lua_code = "local selected = " .. tostring(selected) .. "\n" ..
        "local all_items = " .. tostring(all_items) .. "\n" ..
        "local target_index = " .. lua_quote(index) .. "\n" ..
        "local target_name = " .. lua_quote(name) .. "\n" ..
        "local apply_in = " .. tostring(apply_in) .. "\n" ..
        "local apply_out = " .. tostring(apply_out) .. "\n" ..
        "local fade_in_shape = " .. tostring(fade_in_shape) .. "\n" ..
        "local fade_out_shape = " .. tostring(fade_out_shape) .. "\n" ..
        "local reset_curve = " .. tostring(reset_curve) .. "\n" ..
        "local has_fade_only = " .. tostring(has_fade_only) .. "\n" ..
        "local eps = 0.000001\n" ..
        "local function lower(s) return tostring(s or ''):lower() end\n" ..
        "local function take_name(item) local take = item and reaper.GetActiveTake(item); return take and (reaper.GetTakeName(take) or '') or '' end\n" ..
        "local function item_label(item, fallback) local name = take_name(item); if name ~= '' then return name end; return fallback or 'item' end\n" ..
        "local function collect_named_item(name) local exact, partial = nil, nil; local needle = lower(name); for i = 0, reaper.CountMediaItems(0) - 1 do local item = reaper.GetMediaItem(0, i); local candidate = take_name(item); if candidate == name then exact = item; break elseif not partial and lower(candidate):find(needle, 1, true) then partial = item end end; return exact or partial end\n" ..
        "local targets = {}\n" ..
        "if all_items then for i = 0, reaper.CountMediaItems(0) - 1 do local item = reaper.GetMediaItem(0, i); if item then table.insert(targets, { item = item, label = item_label(item, '#' .. tostring(i)) }) end end\n" ..
        "elseif selected then local count = reaper.CountSelectedMediaItems(0); if count == 0 then return '✗ 没有选中的 item' end; for i = 0, count - 1 do local item = reaper.GetSelectedMediaItem(0, i); if item then table.insert(targets, { item = item, label = item_label(item, 'selected item ' .. tostring(i + 1)) }) end end\n" ..
        "elseif target_index ~= '' then local item = reaper.GetMediaItem(0, tonumber(target_index) or -1); if not item then return '✗ Item not found: #' .. target_index end; table.insert(targets, { item = item, label = item_label(item, '#' .. target_index) })\n" ..
        "elseif target_name ~= '' then local item = collect_named_item(target_name); if not item then return '✗ Item not found: ' .. target_name end; table.insert(targets, { item = item, label = item_label(item, target_name) })\n" ..
        "else return '✗ 请提供 selected=true、all=true 或 index/name' end\n" ..
        "if #targets == 0 then return '✗ 没有匹配到 item' end\n" ..
        "local inspected, changed_items, changed_sides, failed = 0, 0, 0, 0\nlocal labels = {}\n" ..
        "for _, target in ipairs(targets) do local item = target.item; if item then inspected = inspected + 1; local item_changed = false; local fi = reaper.GetMediaItemInfo_Value(item, 'D_FADEINLEN') or 0; local fo = reaper.GetMediaItemInfo_Value(item, 'D_FADEOUTLEN') or 0; if apply_in and (not has_fade_only or fi > eps) then local ok_shape = reaper.SetMediaItemInfo_Value(item, 'C_FADEINSHAPE', fade_in_shape); local ok_curve = true; if reset_curve then ok_curve = reaper.SetMediaItemInfo_Value(item, 'D_FADEINDIR', 0) end; local shape_after = reaper.GetMediaItemInfo_Value(item, 'C_FADEINSHAPE'); local dir_after = reaper.GetMediaItemInfo_Value(item, 'D_FADEINDIR') or 0; if ok_shape and ok_curve and math.floor((shape_after or -1) + 0.5) == fade_in_shape and (not reset_curve or math.abs(dir_after) < 0.0001) then changed_sides = changed_sides + 1; item_changed = true else failed = failed + 1 end end; if apply_out and (not has_fade_only or fo > eps) then local ok_shape = reaper.SetMediaItemInfo_Value(item, 'C_FADEOUTSHAPE', fade_out_shape); local ok_curve = true; if reset_curve then ok_curve = reaper.SetMediaItemInfo_Value(item, 'D_FADEOUTDIR', 0) end; local shape_after = reaper.GetMediaItemInfo_Value(item, 'C_FADEOUTSHAPE'); local dir_after = reaper.GetMediaItemInfo_Value(item, 'D_FADEOUTDIR') or 0; if ok_shape and ok_curve and math.floor((shape_after or -1) + 0.5) == fade_out_shape and (not reset_curve or math.abs(dir_after) < 0.0001) then changed_sides = changed_sides + 1; item_changed = true else failed = failed + 1 end end; if item_changed then changed_items = changed_items + 1; if #labels < 5 then table.insert(labels, target.label) end; reaper.UpdateItemInProject(item) end end end\n" ..
        "reaper.UpdateArrange()\n" ..
        "if changed_sides == 0 then return { ok=false, message='未修改任何 fade shape；可能没有匹配到带 fade 的 item', changed={items=0, sides=0, inspected=inspected, failed=failed} } end\n" ..
        "local suffix = ''; if #labels > 0 then suffix = ': ' .. table.concat(labels, ', '); if changed_items > #labels then suffix = suffix .. ' ...' end end\n" ..
        "return { ok=true, message='已把 ' .. changed_items .. ' 个 item 的 ' .. changed_sides .. ' 个 fade 边改为直线' .. suffix, changed={items=changed_items, sides=changed_sides, inspected=inspected, failed=failed} }"
      desc = endpoint .. " (本地fallback)"

    elseif endpoint == "envelope/draw" then
      lua_code = envelope_fallback_code(params, false)
      desc = "envelope/draw (本地fallback)"

    elseif endpoint == "envelope/clear" then
      lua_code = envelope_fallback_code(params, true)
      desc = "envelope/clear (本地fallback)"

    elseif endpoint == "region/batch_rename" then
      if params.search and params.search ~= "" then
        lua_code = "local search = " .. lua_quote(params.search) .. "\n"
        lua_code = lua_code .. "local replace = " .. lua_quote(params.replace or "") .. "\n"
        lua_code = lua_code .. "local changed, skipped = 0, 0\n"
        lua_code = lua_code .. "local results = {}\n"
        lua_code = lua_code .. "local marker_total = reaper.CountProjectMarkers(0)\n"
        lua_code = lua_code .. "for i = 0, marker_total - 1 do\n"
        lua_code = lua_code .. "  local retval, isrgn, pos, rgnend, name, markrgnindex = reaper.EnumProjectMarkers(i)\n"
        lua_code = lua_code .. "  if retval ~= 0 and isrgn then\n"
        lua_code = lua_code .. "    local start_pos, end_pos = name:find(search, 1, true)\n"
        lua_code = lua_code .. "    if start_pos then local new_name = name:sub(1, start_pos - 1) .. replace .. name:sub(end_pos + 1); reaper.SetProjectMarker(markrgnindex, true, pos, rgnend, new_name); changed = changed + 1; table.insert(results, '\\'' .. name .. '\\' -> \\'' .. new_name .. '\\'') else skipped = skipped + 1 end\n"
        lua_code = lua_code .. "  end\n"
        lua_code = lua_code .. "end\n"
        lua_code = lua_code .. "reaper.UpdateArrange()\n"
        lua_code = lua_code .. "return '已替换 ' .. changed .. ' 个Region (跳过 ' .. skipped .. ' 个)\\n' .. table.concat(results, '\\n')"
      else
        local old_prefix = params.old_prefix or ""
        local new_prefix = params.new_prefix or params.prefix or ""
        local with_index_raw = tostring(params.apply_prefix_with_index or params.with_index or "false"):lower()
        local apply_prefix_with_index = with_index_raw == "1" or with_index_raw == "true" or with_index_raw == "yes" or with_index_raw == "on"
        local separator = params.separator or "_"
        lua_code = "local old_prefix = " .. lua_quote(old_prefix) .. "\n"
        lua_code = lua_code .. "local new_prefix = " .. lua_quote(new_prefix) .. "\n"
        lua_code = lua_code .. "local apply_prefix_with_index = " .. tostring(apply_prefix_with_index) .. "\n"
        lua_code = lua_code .. "local separator = " .. lua_quote(separator) .. "\n"
        lua_code = lua_code .. "if new_prefix == '' then return '✗ 请提供 search/replace 或 new_prefix 参数' end\n"
        lua_code = lua_code .. "local changed, skipped = 0, 0\n"
        lua_code = lua_code .. "local results = {}\n"
        lua_code = lua_code .. "local marker_total = reaper.CountProjectMarkers(0)\n"
        lua_code = lua_code .. "local region_order = 0\n"
        lua_code = lua_code .. "local function has_target_prefix(name)\n"
        lua_code = lua_code .. "  if new_prefix == '' then return false end\n"
        lua_code = lua_code .. "  if name:sub(1, #new_prefix) ~= new_prefix then return false end\n"
        lua_code = lua_code .. "  local rest = name:sub(#new_prefix + 1)\n"
        lua_code = lua_code .. "  return rest == '' or rest:sub(1, #separator) == separator or rest:match('^_%d+_') ~= nil\n"
        lua_code = lua_code .. "end\n"
        lua_code = lua_code .. "local function join_prefix(prefix, body)\n"
        lua_code = lua_code .. "  if body == '' then return prefix end\n"
        lua_code = lua_code .. "  if separator ~= '' and body:sub(1, #separator) == separator then return prefix .. body end\n"
        lua_code = lua_code .. "  return prefix .. separator .. body\n"
        lua_code = lua_code .. "end\n"
        lua_code = lua_code .. "for i = 0, marker_total - 1 do\n"
        lua_code = lua_code .. "  local retval, isrgn, pos, rgnend, name, markrgnindex = reaper.EnumProjectMarkers(i)\n"
        lua_code = lua_code .. "  if retval ~= 0 and isrgn then\n"
        lua_code = lua_code .. "    region_order = region_order + 1\n"
        lua_code = lua_code .. "    local matches = old_prefix == '' or name:sub(1, #old_prefix) == old_prefix\n"
        lua_code = lua_code .. "    if matches and not has_target_prefix(name) then local body = old_prefix == '' and name or name:sub(#old_prefix + 1); local prefix = new_prefix; if apply_prefix_with_index then prefix = new_prefix .. separator .. string.format('%02d', region_order) end; local new_name = join_prefix(prefix, body); reaper.SetProjectMarker(markrgnindex, true, pos, rgnend, new_name); changed = changed + 1; table.insert(results, '\\'' .. name .. '\\' -> \\'' .. new_name .. '\\'') else skipped = skipped + 1 end\n"
        lua_code = lua_code .. "  end\n"
        lua_code = lua_code .. "end\n"
        lua_code = lua_code .. "reaper.UpdateArrange()\n"
        lua_code = lua_code .. "if old_prefix == '' then return '已添加前缀到 ' .. changed .. ' 个Region (跳过 ' .. skipped .. ' 个)\\n' .. table.concat(results, '\\n') end\n"
        lua_code = lua_code .. "return '已重命名 ' .. changed .. ' 个Region (跳过 ' .. skipped .. ' 个)\\n' .. table.concat(results, '\\n')"
      end
      desc = "region/batch_rename (本地fallback)"

    elseif endpoint == "marker/add" then
      local pos = tonumber(params.time or params.position) or 0
      local mname = params.name or "Marker"
      lua_code = "reaper.AddProjectMarker(0, false, " .. pos .. ", 0, " .. lua_quote(mname) .. ", -1)\n"
      lua_code = lua_code .. "reaper.UpdateTimeline()\n"
      lua_code = lua_code .. "return '已在 " .. pos .. "s 处添加标记: " .. mname .. "'"
      desc = "marker/add (本地fallback)"

    elseif endpoint == "region/delete" then
      lua_code = region_delete_fallback_code(params)
      desc = "region/delete (local fallback)"

    elseif endpoint == "marker/delete" then
      local idx = params.index or params.target or params.marker or params.id or ""
      local ids = params.ids or ""
      local range = params.range or ""
      local start_id = params.start or params.from or ""
      local end_id = params["end"] or params.to or ""
      local name = params.name or params.match or ""
      if targets_all(params) or all_token(params.markers) or idx ~= "" or ids ~= "" or range ~= "" or start_id ~= "" or end_id ~= "" or name ~= "" then
        lua_code = "local raw_index = " .. lua_quote(idx) .. "\n"
        lua_code = lua_code .. "local raw_ids = " .. lua_quote(ids) .. "\n"
        lua_code = lua_code .. "local raw_range = " .. lua_quote(range) .. "\n"
        lua_code = lua_code .. "local raw_start = " .. lua_quote(start_id) .. "\n"
        lua_code = lua_code .. "local raw_end = " .. lua_quote(end_id) .. "\n"
        lua_code = lua_code .. "local raw_name = " .. lua_quote(name) .. "\n"
        lua_code = lua_code .. "local delete_all = " .. tostring(targets_all(params) or all_token(params.markers)) .. "\n"
        lua_code = lua_code .. "local wanted = {}\n"
        lua_code = lua_code .. "local function trim(s) return tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', '') end\n"
        lua_code = lua_code .. "local function add_id(n) n = tonumber(n); if n then wanted[math.floor(n)] = true end end\n"
        lua_code = lua_code .. "local function add_range(a,b) a=tonumber(a); b=tonumber(b); if not a or not b then return end; local lo=math.min(math.floor(a),math.floor(b)); local hi=math.max(math.floor(a),math.floor(b)); for id=lo,hi do wanted[id]=true end end\n"
        lua_code = lua_code .. "local function parse_ids(s) s=trim(s):gsub('^[Mm]arker%s*',''):gsub('[Mm]',''); local a,b=s:match('^(%-?%d+)%s*[%-%~:]%s*(%-?%d+)$'); if a and b then add_range(a,b); return end; for part in s:gmatch('[^,%s;|]+') do local x,y=part:match('^(%-?%d+)%s*[%-%~:]%s*(%-?%d+)$'); if x and y then add_range(x,y) else add_id(part) end end end\n"
        lua_code = lua_code .. "if raw_index ~= '' then parse_ids(raw_index) end\n"
        lua_code = lua_code .. "if raw_ids ~= '' then parse_ids(raw_ids) end\n"
        lua_code = lua_code .. "if raw_range ~= '' then parse_ids(raw_range) end\n"
        lua_code = lua_code .. "if raw_start ~= '' or raw_end ~= '' then add_range(raw_start, raw_end) end\n"
        lua_code = lua_code .. "local has_wanted=false; for _ in pairs(wanted) do has_wanted=true; break end\n"
        lua_code = lua_code .. "local name_filter=trim(raw_name); if not delete_all and not has_wanted and name_filter=='' then return 'ERROR: marker/delete requires index, ids, range, name/match, or all=true' end\n"
        lua_code = lua_code .. "local total=reaper.CountProjectMarkers(0); local targets={}; local needle=name_filter:lower()\n"
        lua_code = lua_code .. "for i=0,total-1 do local retval,isrgn,pos,rgnend,mname,markrgnindex=reaper.EnumProjectMarkers3(0,i); if retval ~= 0 and not isrgn then local id=tonumber(markrgnindex); local by_id=id and wanted[id]; local by_name=name_filter ~= '' and tostring(mname or ''):lower():find(needle,1,true) ~= nil; if delete_all or by_id or by_name then table.insert(targets,{id=id,name=mname or ''}) end end end\n"
        lua_code = lua_code .. "table.sort(targets,function(a,b) return (a.id or 0) > (b.id or 0) end)\n"
        lua_code = lua_code .. "local deleted=0; local labels={}; for _,marker in ipairs(targets) do if marker.id and reaper.DeleteProjectMarker(0, marker.id, false) then deleted=deleted+1; if #labels < 8 then table.insert(labels,'M'..tostring(marker.id)) end end end\n"
        lua_code = lua_code .. "reaper.UpdateTimeline(); reaper.UpdateArrange(); if deleted == 0 then return 'ERROR: No matching Marker found' end; return 'Deleted ' .. deleted .. ' Marker(s): ' .. table.concat(labels, ', ')"
      else
        lua_code = "return '✗ marker/delete 需要明确 index/ids/range/name/all 参数'"
      end
      desc = "marker/delete (本地fallback)"

    elseif endpoint == "native/action" then
      local command_id = params.command_id or params.id or params.action_id or ""
      local action = params.action or params.kind or ""
      local mode = params.mode or ""
      local query = params.query or params.name or params.description or ""
      local target_track = params.target_track or params.track_name or params.track or ""
      local selected = params.selected == "true" or params.selected == "1" or selected_token(target_track)
      local restore_selection = params.restore_selection == "true" or params.restore_selection == "1"
      if command_id == "" and reaperai_capabilities and type(reaperai_capabilities.native_action_for_request) == "function" then
        local entry = reaperai_capabilities.native_action_for_request(params)
        if entry then command_id = tostring(entry.id or entry.command_id or "") end
      end
      if command_id == "" then
        lua_code = "return { ok=false, message='native/action 未找到本机 Action；请提供 command_id，或先在设置页检测 Action' }"
      elseif not tostring(command_id):match("^%-?%d+$") then
        lua_code = "return { ok=false, message='native/action command_id 必须是本机数字 Action ID' }"
      else
        lua_code = "local command_id = " .. tostring(command_id) .. "\n"
        lua_code = lua_code .. "local target_track_name = " .. lua_quote(target_track) .. "\n"
        lua_code = lua_code .. "local use_selected = " .. tostring(selected) .. "\n"
        lua_code = lua_code .. "local restore_selection = " .. tostring(restore_selection) .. "\n"
        lua_code = lua_code .. "local action_label = " .. lua_quote(query ~= "" and query or (action ~= "" and (action .. (mode ~= "" and (':' .. mode) or "")) or ("Action " .. tostring(command_id)))) .. "\n"
        lua_code = lua_code .. "local old_selected = {}\n"
        lua_code = lua_code .. "for i = 0, reaper.CountTracks(0) - 1 do local tr = reaper.GetTrack(0, i); if tr and reaper.IsTrackSelected(tr) then table.insert(old_selected, tr) end end\n"
        lua_code = lua_code .. "local target = nil\n"
        lua_code = lua_code .. "if target_track_name ~= '' and not use_selected then\n"
        lua_code = lua_code .. "  local needle = target_track_name:lower()\n"
        lua_code = lua_code .. "  for i = 0, reaper.CountTracks(0) - 1 do local tr = reaper.GetTrack(0, i); if tr then local _, nm = reaper.GetTrackName(tr); if nm == target_track_name or nm:lower():find(needle, 1, true) then target = tr; break end end end\n"
        lua_code = lua_code .. "  if not target then return { ok=false, message='native/action 未找到目标轨道: ' .. target_track_name } end\n"
        lua_code = lua_code .. "  reaper.SetOnlyTrackSelected(target)\n"
        lua_code = lua_code .. "elseif use_selected and reaper.CountSelectedTracks(0) <= 0 then\n"
        lua_code = lua_code .. "  return { ok=false, message='native/action 需要选中轨道，但当前没有选中轨道' }\n"
        lua_code = lua_code .. "end\n"
        lua_code = lua_code .. "reaper.Main_OnCommand(command_id, 0)\n"
        lua_code = lua_code .. "if restore_selection and #old_selected > 0 then\n"
        lua_code = lua_code .. "  for i = 0, reaper.CountTracks(0) - 1 do local tr = reaper.GetTrack(0, i); if tr then reaper.SetMediaTrackInfo_Value(tr, 'I_SELECTED', 0) end end\n"
        lua_code = lua_code .. "  for _, tr in ipairs(old_selected) do if tr then reaper.SetMediaTrackInfo_Value(tr, 'I_SELECTED', 1) end end\n"
        lua_code = lua_code .. "end\n"
        lua_code = lua_code .. "reaper.UpdateArrange()\n"
        lua_code = lua_code .. "return { ok=true, message='已执行本机 Action ' .. tostring(command_id) .. ': ' .. action_label, changed={native_action=1} }\n"
      end
      desc = "native/action (本地fallback)"
    end

    return lua_code, desc
  end

  return Fallback
end

return McpFallback
