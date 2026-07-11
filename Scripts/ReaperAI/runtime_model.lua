-- ReaperAI runtime model.
-- Consolidates runtime state, generated object registry, and object binding.

-- ============================================
-- RuntimeState
-- ============================================
-- ReaperAI runtime state helpers.
-- Owns project snapshots, snapshot deltas, and created-object capture.

local RuntimeState = {}

function RuntimeState.create()
  local M = {}

  local function track_name_at(index)
    index = tonumber(index)
    if not index then return nil end
    local track = reaper.GetTrack(0, index)
    if not track then return nil end
    local _, name = reaper.GetTrackName(track)
    return name or ""
  end

  local function take_name_for_item(item)
    if not item or not reaper.GetActiveTake then return "" end
    local take = reaper.GetActiveTake(item)
    if not take or not reaper.GetSetMediaItemTakeInfo_String then return "" end
    local _, name = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
    return name or ""
  end

  local function track_fx_count_at(index)
    if not reaper.GetTrack or not reaper.TrackFX_GetCount then return 0 end
    index = tonumber(index)
    if not index then return 0 end
    local track = reaper.GetTrack(0, index)
    if not track then return 0 end
    local ok, count = pcall(reaper.TrackFX_GetCount, track)
    return ok and (tonumber(count) or 0) or 0
  end

  local function increment_count(map, key)
    key = tostring(key or "")
    map[key] = (map[key] or 0) + 1
  end

  local function close_enough(a, b)
    return math.abs((tonumber(a) or 0) - (tonumber(b) or 0)) <= 0.001
  end

  local function ranges_overlap(a_start, a_end, b_start, b_end)
    a_start = tonumber(a_start) or 0
    a_end = tonumber(a_end) or 0
    b_start = tonumber(b_start) or 0
    b_end = tonumber(b_end) or 0
    return a_end > b_start + 0.001 and a_start < b_end - 0.001
  end

  local function append_region_ref(list, snapshot, i)
    table.insert(list, {
      index = snapshot.region_indices[i],
      name = snapshot.region_names[i] or "",
      position = snapshot.region_positions[i] or 0,
      ["end"] = snapshot.region_ends[i] or 0,
    })
  end

  local function apply_region_selection_candidates(snapshot)
    if not snapshot or not snapshot.time_selection_active then return end

    local exact = {}
    local contained = {}
    local overlap = {}
    for i = 1, #(snapshot.region_indices or {}) do
      local pos = snapshot.region_positions[i] or 0
      local rgnend = snapshot.region_ends[i] or 0
      if close_enough(pos, snapshot.time_selection_start) and close_enough(rgnend, snapshot.time_selection_end) then
        append_region_ref(exact, snapshot, i)
      elseif pos >= (snapshot.time_selection_start or 0) - 0.001 and rgnend <= (snapshot.time_selection_end or 0) + 0.001 then
        append_region_ref(contained, snapshot, i)
      elseif ranges_overlap(pos, rgnend, snapshot.time_selection_start, snapshot.time_selection_end) then
        append_region_ref(overlap, snapshot, i)
      end
    end

    local selected = exact
    local source = "time_selection_exact"
    if #selected == 0 then
      selected = contained
      source = "time_selection_contained"
    end
    if #selected == 0 then
      selected = overlap
      source = "time_selection_overlap"
    end

    snapshot.selected_region_source = #selected > 0 and source or ""
    snapshot.selected_region_count = #selected
    for _, region in ipairs(selected) do
      table.insert(snapshot.selected_region_indices, region.index)
      table.insert(snapshot.selected_region_names, region.name)
      table.insert(snapshot.selected_region_positions, region.position)
      table.insert(snapshot.selected_region_ends, region["end"])
    end
  end

  local function capture_project_snapshot()
    local snapshot = {
      track_count = 0,
      track_names = {},
      track_guids = {},
      track_name_counts = {},
      selected_track_indices = {},
      selected_track_names = {},
      track_fx_total = 0,
      track_fx_counts = {},
      track_fx_names = {},
      item_count = 0,
      item_refs = {},
      item_names = {},
      item_positions = {},
      item_lengths = {},
      item_track_indices = {},
      item_track_guids = {},
      item_name_counts = {},
      selected_track_count = 0,
      selected_item_count = 0,
      selected_item_indices = {},
      selected_item_names = {},
      selected_item_positions = {},
      selected_item_lengths = {},
      current_item_indices = {},
      current_item_names = {},
      time_selection_item_indices = {},
      time_selection_item_names = {},
      marker_count = 0,
      marker_indices = {},
      marker_names = {},
      marker_positions = {},
      marker_name_counts = {},
      current_marker_indices = {},
      current_marker_names = {},
      time_selection_marker_indices = {},
      time_selection_marker_names = {},
      region_count = 0,
      region_indices = {},
      region_names = {},
      region_positions = {},
      region_ends = {},
      region_name_counts = {},
      current_region_indices = {},
      current_region_names = {},
      time_selection_region_indices = {},
      time_selection_region_names = {},
      selected_region_count = 0,
      selected_region_indices = {},
      selected_region_names = {},
      selected_region_positions = {},
      selected_region_ends = {},
      selected_region_source = "",
      cursor_position = 0,
      play_state = 0,
      time_selection_start = 0,
      time_selection_end = 0,
      time_selection_length = 0,
      time_selection_active = false,
      loop_start = 0,
      loop_end = 0,
      loop_length = 0,
      loop_active = false,
      selected_envelope = false,
    }

    if reaper.GetCursorPosition then
      local ok, value = pcall(reaper.GetCursorPosition)
      if ok then snapshot.cursor_position = tonumber(value) or 0 end
    end

    if reaper.GetPlayState then
      local ok, value = pcall(reaper.GetPlayState)
      if ok then snapshot.play_state = tonumber(value) or 0 end
    end

    if reaper.GetSet_LoopTimeRange then
      local ok, start_pos, end_pos = pcall(reaper.GetSet_LoopTimeRange, false, false, 0, 0, false)
      if ok then
        snapshot.time_selection_start = tonumber(start_pos) or 0
        snapshot.time_selection_end = tonumber(end_pos) or 0
        snapshot.time_selection_length = math.max(0, snapshot.time_selection_end - snapshot.time_selection_start)
        snapshot.time_selection_active = snapshot.time_selection_length > 0.001
      end
      local loop_ok, loop_start, loop_end = pcall(reaper.GetSet_LoopTimeRange, false, true, 0, 0, false)
      if loop_ok then
        snapshot.loop_start = tonumber(loop_start) or 0
        snapshot.loop_end = tonumber(loop_end) or 0
        snapshot.loop_length = math.max(0, snapshot.loop_end - snapshot.loop_start)
        snapshot.loop_active = snapshot.loop_length > 0.001
      end
    end

    if reaper.GetSelectedEnvelope then
      local ok, env = pcall(reaper.GetSelectedEnvelope, 0)
      snapshot.selected_envelope = ok and env ~= nil
    end

    if reaper.CountTracks then
      local ok, count = pcall(reaper.CountTracks, 0)
      if ok and count then
        snapshot.track_count = tonumber(count) or 0
        for i = 0, snapshot.track_count - 1 do
          local name = track_name_at(i) or ""
          snapshot.track_names[i + 1] = name
          local track = reaper.GetTrack and reaper.GetTrack(0, i) or nil
          if reaper.GetTrackGUID then
            snapshot.track_guids[i + 1] = track and reaper.GetTrackGUID(track) or ""
          end
          if track and reaper.IsTrackSelected and reaper.IsTrackSelected(track) then
            table.insert(snapshot.selected_track_indices, i)
            table.insert(snapshot.selected_track_names, name)
          end
          increment_count(snapshot.track_name_counts, name)
          local fx_count = track_fx_count_at(i)
          snapshot.track_fx_counts[i + 1] = fx_count
          snapshot.track_fx_names[i + 1] = {}
          if track and reaper.TrackFX_GetFXName then
            for fx_index = 0, fx_count - 1 do
              local _, fx_name = reaper.TrackFX_GetFXName(track, fx_index, "")
              snapshot.track_fx_names[i + 1][fx_index + 1] = fx_name or ""
            end
          end
          snapshot.track_fx_total = snapshot.track_fx_total + fx_count
        end
      end
    end

    if reaper.CountSelectedTracks then
      local ok, count = pcall(reaper.CountSelectedTracks, 0)
      if ok and count then
        snapshot.selected_track_count = tonumber(count) or 0
      end
    else
      snapshot.selected_track_count = #snapshot.selected_track_indices
    end

    if reaper.CountMediaItems then
      local ok, count = pcall(reaper.CountMediaItems, 0)
      if ok and count then
        snapshot.item_count = tonumber(count) or 0
        if reaper.GetMediaItem then
          for i = 0, snapshot.item_count - 1 do
            local item = reaper.GetMediaItem(0, i)
            local item_name = take_name_for_item(item)
            snapshot.item_refs[i + 1] = item
            snapshot.item_names[i + 1] = item_name
            if item and reaper.GetMediaItemInfo_Value then
              snapshot.item_positions[i + 1] = reaper.GetMediaItemInfo_Value(item, "D_POSITION") or 0
              snapshot.item_lengths[i + 1] = reaper.GetMediaItemInfo_Value(item, "D_LENGTH") or 0
            end
            if item and reaper.IsMediaItemSelected and reaper.IsMediaItemSelected(item) then
              table.insert(snapshot.selected_item_indices, i)
              table.insert(snapshot.selected_item_names, item_name)
              table.insert(snapshot.selected_item_positions, snapshot.item_positions[i + 1] or 0)
              table.insert(snapshot.selected_item_lengths, snapshot.item_lengths[i + 1] or 0)
            end
            local item_pos = snapshot.item_positions[i + 1] or 0
            local item_len = snapshot.item_lengths[i + 1] or 0
            if item and snapshot.cursor_position >= item_pos - 0.001 and snapshot.cursor_position <= item_pos + item_len + 0.001 then
              table.insert(snapshot.current_item_indices, i)
              table.insert(snapshot.current_item_names, item_name)
            end
            if item and snapshot.time_selection_active and ranges_overlap(item_pos, item_pos + item_len, snapshot.time_selection_start, snapshot.time_selection_end) then
              table.insert(snapshot.time_selection_item_indices, i)
              table.insert(snapshot.time_selection_item_names, item_name)
            end
            if item and reaper.GetMediaItemTrack then
              local track = reaper.GetMediaItemTrack(item)
              if track and reaper.GetMediaTrackInfo_Value then
                snapshot.item_track_indices[i + 1] = (reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") or 0) - 1
              end
              if track and reaper.GetTrackGUID then
                snapshot.item_track_guids[i + 1] = reaper.GetTrackGUID(track) or ""
              end
            end
            increment_count(snapshot.item_name_counts, item_name)
          end
        end
      end
    end

    if reaper.CountProjectMarkers and reaper.EnumProjectMarkers then
      local ok, _, marker_count, region_count = pcall(reaper.CountProjectMarkers, 0)
      if ok then
        snapshot.marker_count = tonumber(marker_count) or 0
        snapshot.region_count = tonumber(region_count) or 0
        local total = snapshot.marker_count + snapshot.region_count
        for i = 0, total - 1 do
          local enum_ok, retval, is_region, pos, rgnend, name, markrgnindex = pcall(reaper.EnumProjectMarkers, i)
          if enum_ok and retval ~= 0 then
            if is_region then
              table.insert(snapshot.region_indices, markrgnindex)
              table.insert(snapshot.region_names, name or "")
              table.insert(snapshot.region_positions, pos or 0)
              table.insert(snapshot.region_ends, rgnend or 0)
              if snapshot.cursor_position >= (pos or 0) - 0.001 and snapshot.cursor_position <= (rgnend or 0) + 0.001 then
                table.insert(snapshot.current_region_indices, markrgnindex)
                table.insert(snapshot.current_region_names, name or "")
              end
              if snapshot.time_selection_active and ranges_overlap(pos or 0, rgnend or 0, snapshot.time_selection_start, snapshot.time_selection_end) then
                table.insert(snapshot.time_selection_region_indices, markrgnindex)
                table.insert(snapshot.time_selection_region_names, name or "")
              end
              increment_count(snapshot.region_name_counts, name or "")
            else
              table.insert(snapshot.marker_indices, markrgnindex)
              table.insert(snapshot.marker_names, name or "")
              table.insert(snapshot.marker_positions, pos or 0)
              if close_enough(pos or 0, snapshot.cursor_position) then
                table.insert(snapshot.current_marker_indices, markrgnindex)
                table.insert(snapshot.current_marker_names, name or "")
              end
              if snapshot.time_selection_active and (pos or 0) >= snapshot.time_selection_start - 0.001 and (pos or 0) <= snapshot.time_selection_end + 0.001 then
                table.insert(snapshot.time_selection_marker_indices, markrgnindex)
                table.insert(snapshot.time_selection_marker_names, name or "")
              end
              increment_count(snapshot.marker_name_counts, name or "")
            end
          end
        end
      end
    end

    apply_region_selection_candidates(snapshot)

    if reaper.CountSelectedMediaItems then
      local ok, count = pcall(reaper.CountSelectedMediaItems, 0)
      if ok and count then
        snapshot.selected_item_count = tonumber(count) or 0
      end
    else
      snapshot.selected_item_count = #snapshot.selected_item_indices
    end

    return snapshot
  end

  local function snapshot_count_by_name_or_keyword(snapshot, kind, keyword)
    if not snapshot then return nil end
    keyword = tostring(keyword or "")
    if keyword == "" then return 0 end
    local map = snapshot[tostring(kind or "") .. "_name_counts"]
    if not map then return nil end
    local needle = keyword:lower()
    local count = 0
    for name, name_count in pairs(map) do
      name = tostring(name or "")
      if name == keyword or name:lower():find(needle, 1, true) then
        count = count + (tonumber(name_count) or 0)
      end
    end
    return count
  end

  local function snapshot_exact_count(snapshot, kind, name)
    if not snapshot then return nil end
    name = tostring(name or "")
    local map = snapshot[tostring(kind or "") .. "_name_counts"]
    if not map then return nil end
    return tonumber(map[name] or 0) or 0
  end

  local function snapshot_total(snapshot, key)
    if not snapshot then return nil end
    return tonumber(snapshot[key] or 0)
  end

  local function snapshot_track_name_at(snapshot, index)
    if not snapshot or not snapshot.track_names then return nil end
    index = tonumber(index)
    if not index then return nil end
    return snapshot.track_names[index + 1]
  end

  local function count_tracks_by_name_or_keyword(keyword)
    return snapshot_count_by_name_or_keyword(capture_project_snapshot(), "track", keyword) or 0
  end

  local function count_markers_by_name(name)
    return snapshot_exact_count(capture_project_snapshot(), "marker", name) or 0
  end

  local function count_delta(before_snapshot, after_snapshot, kind, keyword)
    local before_count = snapshot_count_by_name_or_keyword(before_snapshot, kind, keyword)
    local after_count = snapshot_count_by_name_or_keyword(after_snapshot, kind, keyword)
    if before_count == nil or after_count == nil then
      return nil, before_count, after_count
    end
    return after_count - before_count, before_count, after_count
  end

  local function exact_count_delta(before_snapshot, after_snapshot, kind, name)
    local before_count = snapshot_exact_count(before_snapshot, kind, name)
    local after_count = snapshot_exact_count(after_snapshot, kind, name)
    if before_count == nil or after_count == nil then
      return nil, before_count, after_count
    end
    return after_count - before_count, before_count, after_count
  end

  local function total_delta(before_snapshot, after_snapshot, key)
    local before_count = snapshot_total(before_snapshot, key)
    local after_count = snapshot_total(after_snapshot, key)
    if before_count == nil or after_count == nil then
      return nil, before_count, after_count
    end
    return after_count - before_count, before_count, after_count
  end

  local function split_param_list(value)
    value = tostring(value or "")
    value = value:gsub("\239\188\140", ","):gsub("|", ","):gsub(";", ",")
    local result = {}
    for part in value:gmatch("[^,]+") do
      part = part:gsub("^%s+", ""):gsub("%s+$", "")
      if part ~= "" then table.insert(result, part) end
    end
    return result
  end

  local function find_track_index_by_guid(guid)
    if not guid or guid == "" or not reaper.GetTrack or not reaper.GetTrackGUID or not reaper.CountTracks then return nil end
    for i = 0, reaper.CountTracks(0) - 1 do
      local track = reaper.GetTrack(0, i)
      if track and reaper.GetTrackGUID(track) == guid then return i end
    end
    return nil
  end

  local function capture_created_tracks(before_snapshot, after_snapshot)
    local before_count = snapshot_total(before_snapshot, "track_count")
    local after_count = snapshot_total(after_snapshot, "track_count")
    if not before_count or not after_count or after_count <= before_count then return nil end
    local created = { kind = "track", base_count = before_count, count = after_count - before_count, tracks = {} }
    for index = before_count, after_count - 1 do
      table.insert(created.tracks, {
        index = index,
        name = after_snapshot and after_snapshot.track_names and after_snapshot.track_names[index + 1] or "",
        guid = after_snapshot and after_snapshot.track_guids and after_snapshot.track_guids[index + 1] or "",
      })
    end
    return created
  end

  local function snapshot_ref_set(list)
    local refs = {}
    for _, value in ipairs(list or {}) do
      if value ~= nil then refs[value] = true end
    end
    return refs
  end

  local function capture_created_items(before_snapshot, after_snapshot)
    local before_count = snapshot_total(before_snapshot, "item_count")
    local after_count = snapshot_total(after_snapshot, "item_count")
    if not before_count or not after_count or after_count <= before_count then return nil end
    local before_refs = snapshot_ref_set(before_snapshot and before_snapshot.item_refs)
    local created = { kind = "item", base_count = before_count, count = 0, objects = {} }
    for i = 0, after_count - 1 do
      local ref = after_snapshot and after_snapshot.item_refs and after_snapshot.item_refs[i + 1] or nil
      local is_new = ref ~= nil and not before_refs[ref]
      if not is_new and i >= before_count and not ref then
        is_new = true
      end
      if is_new then
        table.insert(created.objects, {
          index = i,
          ref = ref,
          name = after_snapshot.item_names and after_snapshot.item_names[i + 1] or "",
          position = after_snapshot.item_positions and after_snapshot.item_positions[i + 1] or 0,
          length = after_snapshot.item_lengths and after_snapshot.item_lengths[i + 1] or 0,
          track_index = after_snapshot.item_track_indices and after_snapshot.item_track_indices[i + 1] or nil,
          track_guid = after_snapshot.item_track_guids and after_snapshot.item_track_guids[i + 1] or "",
        })
      end
    end
    if #created.objects == 0 then
      for i = before_count, after_count - 1 do
        table.insert(created.objects, {
          index = i,
          ref = after_snapshot and after_snapshot.item_refs and after_snapshot.item_refs[i + 1] or nil,
          name = after_snapshot and after_snapshot.item_names and after_snapshot.item_names[i + 1] or "",
          position = after_snapshot and after_snapshot.item_positions and after_snapshot.item_positions[i + 1] or 0,
          length = after_snapshot and after_snapshot.item_lengths and after_snapshot.item_lengths[i + 1] or 0,
          track_index = after_snapshot and after_snapshot.item_track_indices and after_snapshot.item_track_indices[i + 1] or nil,
          track_guid = after_snapshot and after_snapshot.item_track_guids and after_snapshot.item_track_guids[i + 1] or "",
        })
      end
    end
    created.count = #created.objects
    if created.count <= 0 then return nil end
    return created
  end

  local function capture_created_markers(before_snapshot, after_snapshot)
    local before_count = snapshot_total(before_snapshot, "marker_count")
    local after_count = snapshot_total(after_snapshot, "marker_count")
    if not before_count or not after_count or after_count <= before_count then return nil end
    local before_indices = {}
    for _, index in ipairs(before_snapshot and before_snapshot.marker_indices or {}) do
      before_indices[tostring(index)] = true
    end
    local created = { kind = "marker", base_count = before_count, count = 0, objects = {} }
    for i, index in ipairs(after_snapshot and after_snapshot.marker_indices or {}) do
      if not before_indices[tostring(index)] then
        table.insert(created.objects, {
          index = index,
          name = after_snapshot.marker_names and after_snapshot.marker_names[i] or "",
          position = after_snapshot.marker_positions and after_snapshot.marker_positions[i] or 0,
        })
      end
    end
    if #created.objects == 0 then
      for i = before_count + 1, after_count do
        table.insert(created.objects, {
          index = after_snapshot and after_snapshot.marker_indices and after_snapshot.marker_indices[i] or (i - 1),
          name = after_snapshot and after_snapshot.marker_names and after_snapshot.marker_names[i] or "",
          position = after_snapshot and after_snapshot.marker_positions and after_snapshot.marker_positions[i] or 0,
        })
      end
    end
    created.count = #created.objects
    if created.count <= 0 then return nil end
    return created
  end

  local function capture_added_fx(before_snapshot, after_snapshot)
    if not before_snapshot or not after_snapshot then return nil end
    local created = { kind = "fx", count = 0, objects = {} }
    local track_count = math.max(#(after_snapshot.track_fx_counts or {}), #(before_snapshot.track_fx_counts or {}))
    for track_i = 1, track_count do
      local before_fx = tonumber(before_snapshot.track_fx_counts and before_snapshot.track_fx_counts[track_i] or 0) or 0
      local after_fx = tonumber(after_snapshot.track_fx_counts and after_snapshot.track_fx_counts[track_i] or 0) or 0
      if after_fx > before_fx then
        for fx_index = before_fx, after_fx - 1 do
          table.insert(created.objects, {
            index = fx_index,
            fx_index = fx_index,
            name = after_snapshot.track_fx_names and after_snapshot.track_fx_names[track_i] and after_snapshot.track_fx_names[track_i][fx_index + 1] or "",
            track_index = track_i - 1,
            track_name = after_snapshot.track_names and after_snapshot.track_names[track_i] or "",
            track_guid = after_snapshot.track_guids and after_snapshot.track_guids[track_i] or "",
          })
        end
      end
    end
    created.count = #created.objects
    if created.count <= 0 then return nil end
    return created
  end

  local function find_item_index_by_ref(item_ref)
    if not item_ref or not reaper.CountMediaItems or not reaper.GetMediaItem then return nil end
    for i = 0, reaper.CountMediaItems(0) - 1 do
      if reaper.GetMediaItem(0, i) == item_ref then return i end
    end
    return nil
  end

  M.capture_project_snapshot = capture_project_snapshot
  M.snapshot_count_by_name_or_keyword = snapshot_count_by_name_or_keyword
  M.snapshot_exact_count = snapshot_exact_count
  M.snapshot_total = snapshot_total
  M.snapshot_track_name_at = snapshot_track_name_at
  M.count_tracks_by_name_or_keyword = count_tracks_by_name_or_keyword
  M.count_markers_by_name = count_markers_by_name
  M.count_delta = count_delta
  M.exact_count_delta = exact_count_delta
  M.total_delta = total_delta
  M.split_param_list = split_param_list
  M.find_track_index_by_guid = find_track_index_by_guid
  M.capture_created_tracks = capture_created_tracks
  M.capture_created_items = capture_created_items
  M.capture_created_markers = capture_created_markers
  M.capture_added_fx = capture_added_fx
  M.find_item_index_by_ref = find_item_index_by_ref

  return M
end

-- ============================================
-- GeneratedRegistry
-- ============================================
-- ReaperAI generated object registry.
-- Keeps objects produced by earlier steps available to later steps and runtime repair.

local GeneratedRegistry = {}

function GeneratedRegistry.create()
  local M = {}

  local LAST_FIELD = {
    tracks = "last_created_tracks",
    items = "last_created_items",
    markers = "last_created_markers",
    fx = "last_added_fx",
  }

  local GROUP_OBJECTS_FIELD = {
    tracks = "tracks",
    items = "objects",
    markers = "objects",
    fx = "objects",
  }

  local CREATED_REF_PREFIX = {
    tracks = "created.tracks",
    items = "created.items",
    markers = "created.markers",
    fx = "added.fx",
  }

  local function shallow_copy(value)
    if type(value) ~= "table" then return value end
    local copied = {}
    for k, v in pairs(value) do
      if type(v) ~= "table" then
        copied[k] = v
      end
    end
    return copied
  end

  local function ensure(registry)
    if type(registry) ~= "table" then registry = {} end
    registry.tracks = registry.tracks or {}
    registry.items = registry.items or {}
    registry.markers = registry.markers or {}
    registry.fx = registry.fx or {}
    registry.sequence = registry.sequence or {}
    return registry
  end

  local function group_count(group, bucket)
    if type(group) ~= "table" then return 0 end
    local field = GROUP_OBJECTS_FIELD[bucket]
    local list = field and group[field] or nil
    if type(list) == "table" then return #list end
    return tonumber(group.count or 0) or 0
  end

  local function record_group(registry, bucket, group, step_index, step)
    if type(group) ~= "table" or not bucket then return ensure(registry), 0 end
    registry = ensure(registry)
    local last_field = LAST_FIELD[bucket]
    if last_field then registry[last_field] = group end

    local field = GROUP_OBJECTS_FIELD[bucket]
    local list = field and group[field] or nil
    local count = 0
    if type(list) == "table" then
      for i, object in ipairs(list) do
        local entry = shallow_copy(object)
        local registry_index = #registry[bucket] + 1
        entry.kind = bucket
        entry.local_index = i
        entry.registry_index = registry_index
        entry.step_index = step_index
        entry.source = step and (step.call or step.kind or step.raw) or nil
        entry.ref_name = (CREATED_REF_PREFIX[bucket] or bucket) .. "[" .. tostring(registry_index) .. "]"
        table.insert(registry[bucket], entry)
        table.insert(registry.sequence, {
          kind = bucket,
          bucket_index = registry_index,
          local_index = i,
          step_index = step_index,
          ref_name = entry.ref_name,
        })
        count = count + 1
      end
    end

    return registry, count
  end

  local function latest(registry, bucket)
    registry = ensure(registry)
    local last_field = LAST_FIELD[bucket]
    return last_field and registry[last_field] or nil
  end

  local function has_any(registry)
    if type(registry) ~= "table" then return false end
    return #(registry.tracks or {}) > 0
      or #(registry.items or {}) > 0
      or #(registry.markers or {}) > 0
      or #(registry.fx or {}) > 0
      or group_count(registry.last_created_tracks, "tracks") > 0
      or group_count(registry.last_created_items, "items") > 0
      or group_count(registry.last_created_markers, "markers") > 0
      or group_count(registry.last_added_fx, "fx") > 0
  end

  local function format_number(value)
    if value == nil then return nil end
    local n = tonumber(value)
    if not n then return tostring(value) end
    return string.format("%.3f", n):gsub("0+$", ""):gsub("%.$", "")
  end

  local function summarize_entry(bucket, entry)
    if type(entry) ~= "table" then return nil end
    local parts = { tostring(entry.ref_name or "") }
    if entry.name and tostring(entry.name) ~= "" then
      table.insert(parts, "name=" .. tostring(entry.name))
    end
    if entry.index ~= nil then
      table.insert(parts, "index=" .. tostring(entry.index))
    end
    if entry.track_index ~= nil then
      table.insert(parts, "track=" .. tostring(entry.track_index))
    end
    if entry.position ~= nil then
      table.insert(parts, "pos=" .. tostring(format_number(entry.position)))
    end
    if entry.length ~= nil then
      table.insert(parts, "len=" .. tostring(format_number(entry.length)))
    end
    if bucket == "fx" and entry.fx_index ~= nil then
      table.insert(parts, "fx_index=" .. tostring(entry.fx_index))
    end
    return table.concat(parts, " | ")
  end

  local function append_summary(lines, registry, bucket, label, limit)
    local list = registry and registry[bucket] or nil
    if type(list) ~= "table" or #list == 0 then return end
    table.insert(lines, label .. ":")
    for i, entry in ipairs(list) do
      if i > limit then
        table.insert(lines, "  ... " .. tostring(#list - limit) .. " more")
        break
      end
      table.insert(lines, "  " .. tostring(summarize_entry(bucket, entry)))
    end
  end

  local function parse_reference_name(ref_name)
    ref_name = tostring(ref_name or ""):lower():gsub("%s+", "")
    if ref_name == "" then return nil, nil end
    local patterns = {
      { bucket = "tracks", pattern = "^created%.tracks%[(%d+)%]$" },
      { bucket = "tracks", pattern = "^generated%.tracks%[(%d+)%]$" },
      { bucket = "tracks", pattern = "^created:tracks:(%d+)$" },
      { bucket = "tracks", pattern = "^created:track:(%d+)$" },
      { bucket = "items", pattern = "^created%.items%[(%d+)%]$" },
      { bucket = "items", pattern = "^generated%.items%[(%d+)%]$" },
      { bucket = "items", pattern = "^created:items:(%d+)$" },
      { bucket = "items", pattern = "^created:item:(%d+)$" },
      { bucket = "markers", pattern = "^created%.markers%[(%d+)%]$" },
      { bucket = "markers", pattern = "^generated%.markers%[(%d+)%]$" },
      { bucket = "markers", pattern = "^created:markers:(%d+)$" },
      { bucket = "markers", pattern = "^created:marker:(%d+)$" },
      { bucket = "fx", pattern = "^added%.fx%[(%d+)%]$" },
      { bucket = "fx", pattern = "^generated%.fx%[(%d+)%]$" },
      { bucket = "fx", pattern = "^added:fx:(%d+)$" },
      { bucket = "fx", pattern = "^created:fx:(%d+)$" },
    }
    for _, item in ipairs(patterns) do
      local index = ref_name:match(item.pattern)
      if index then return item.bucket, tonumber(index) end
    end
    return nil, nil
  end

  function M.ensure(registry)
    return ensure(registry)
  end

  function M.ensure_op(op)
    if type(op) ~= "table" then return ensure(nil) end
    op.generated_registry = ensure(op.generated_registry)
    return op.generated_registry
  end

  function M.record_created_tracks(registry, group, step_index, step)
    return record_group(registry, "tracks", group, step_index, step)
  end

  function M.record_created_items(registry, group, step_index, step)
    return record_group(registry, "items", group, step_index, step)
  end

  function M.record_created_markers(registry, group, step_index, step)
    return record_group(registry, "markers", group, step_index, step)
  end

  function M.record_added_fx(registry, group, step_index, step)
    return record_group(registry, "fx", group, step_index, step)
  end

  function M.latest_created_tracks(registry)
    return latest(registry, "tracks")
  end

  function M.latest_created_items(registry)
    return latest(registry, "items")
  end

  function M.latest_created_markers(registry)
    return latest(registry, "markers")
  end

  function M.latest_added_fx(registry)
    return latest(registry, "fx")
  end

  function M.has_any(registry)
    return has_any(registry)
  end

  function M.summary(registry, limit)
    registry = ensure(registry)
    if not has_any(registry) then return "none" end
    limit = tonumber(limit or 12) or 12
    local lines = {}
    append_summary(lines, registry, "tracks", "created.tracks", limit)
    append_summary(lines, registry, "items", "created.items", limit)
    append_summary(lines, registry, "markers", "created.markers", limit)
    append_summary(lines, registry, "fx", "added.fx", limit)
    return (#lines > 0) and table.concat(lines, "\n") or "none"
  end

  function M.resolve_reference(registry, ref_name)
    registry = ensure(registry)
    local bucket, index = parse_reference_name(ref_name)
    if not bucket or not index then return nil, nil, nil end
    local entry = registry[bucket] and registry[bucket][index] or nil
    return entry, bucket, index
  end

  function M.references(registry)
    registry = ensure(registry)
    local refs = {}
    for _, bucket in ipairs({ "tracks", "items", "markers", "fx" }) do
      for _, entry in ipairs(registry[bucket] or {}) do
        if entry.ref_name and tostring(entry.ref_name) ~= "" then
          table.insert(refs, entry.ref_name)
        end
      end
    end
    return refs
  end

  function M.clone(registry)
    registry = ensure(registry)
    local cloned = ensure(nil)
    cloned.last_created_tracks = registry.last_created_tracks
    cloned.last_created_items = registry.last_created_items
    cloned.last_created_markers = registry.last_created_markers
    cloned.last_added_fx = registry.last_added_fx
    for _, bucket in ipairs({ "tracks", "items", "markers", "fx", "sequence" }) do
      for _, entry in ipairs(registry[bucket] or {}) do
        table.insert(cloned[bucket], shallow_copy(entry))
      end
    end
    return cloned
  end

  return M
end

-- ============================================
-- ObjectBinding
-- ============================================
-- ReaperAI object binding helpers.
-- Binds follow-up MCP steps to tracks/items/markers/FX created by earlier steps.

local ObjectBinding = {}

function ObjectBinding.create(deps)
  deps = deps or {}
  local Operation = deps.Operation
  local RuntimeState = deps.RuntimeState
  if not Operation then error("ObjectBinding requires Operation", 0) end
  if not RuntimeState then error("ObjectBinding requires RuntimeState", 0) end

  local M = {}

  local CREATED_TRACK_BIND_ENDPOINTS = {
    ["track/rename"] = { target_param = "index", numeric_params = { "index" }, explicit_target_keys = { "selected", "target", "old_name", "from", "track_name" }, default_first = false },
    ["track/set_volume"] = { target_param = "index", numeric_params = { "index" }, explicit_target_keys = { "selected", "name" }, default_first = false },
    ["track/set_volume_by_name"] = { target_param = "index", numeric_params = { "index" }, explicit_target_keys = { "selected", "name" }, default_first = false },
    ["track/set_pan"] = { target_param = "index", numeric_params = { "index" }, explicit_target_keys = { "selected", "name" }, default_first = false },
    ["track/set_color"] = { target_param = "index", numeric_params = { "index" }, explicit_target_keys = { "selected", "name" }, default_first = false },
    ["track/mute"] = { target_param = "index", numeric_params = { "index" }, explicit_target_keys = { "selected", "name" }, default_first = false },
    ["track/solo"] = { target_param = "index", numeric_params = { "index" }, explicit_target_keys = { "selected", "name" }, default_first = false },
    ["track/add_fx"] = { target_param = "track", numeric_params = { "track", "index" }, explicit_target_keys = { "selected", "target" }, default_first = false },
    ["track/remove_fx"] = { target_param = "track", numeric_params = { "track", "index" }, explicit_target_keys = { "selected", "target", "name" }, default_first = false },
  }

  local ITEM_BIND_ENDPOINTS = {
    ["item/set_color"] = true,
    ["item/fade"] = true,
    ["item/set_fade"] = true,
    ["item/fade_shape"] = true,
    ["item/set_fade_shape"] = true,
  }

  local function mcp_param_encode(value)
    value = tostring(value or "")
    value = value:gsub("\n", " "):gsub("\r", " ")
    value = value:gsub("([^%w%-%._~ ])", function(c)
      return string.format("%%%02X", string.byte(c))
    end)
    return value:gsub(" ", "+")
  end

  local function build_mcp_call(endpoint, params)
    endpoint = tostring(endpoint or "")
    params = params or {}
    local keys = {}
    for key, _ in pairs(params) do table.insert(keys, key) end
    table.sort(keys)
    local parts = {}
    for _, key in ipairs(keys) do
      local value = params[key]
      if value ~= nil and tostring(value) ~= "" then
        table.insert(parts, mcp_param_encode(key) .. "=" .. mcp_param_encode(value))
      end
    end
    if #parts == 0 then return endpoint end
    return endpoint .. "?" .. table.concat(parts, "&")
  end

  local function param_has_value(params, key)
    local value = params and params[key]
    return value ~= nil and tostring(value) ~= ""
  end

  local function param_is_truthy(value)
    value = tostring(value or ""):lower()
    return value == "true" or value == "1" or value == "yes" or value == "y" or value == "on"
  end

  local function created_ref_index(value, plural)
    value = tostring(value or ""):lower():gsub("%s+", "")
    if value == "" then return nil end
    plural = tostring(plural or "")
    local singular = plural:gsub("s$", "")
    local patterns = {
      "created%." .. plural .. "%[(%d+)%]",
      "created%." .. plural .. "%[(%d+)$",
      "created:" .. plural .. ":(%d+)",
      "created:" .. singular .. ":(%d+)",
      "generated%." .. plural .. "%[(%d+)%]",
      "generated%." .. plural .. "%[(%d+)$",
      "generated:" .. plural .. ":(%d+)",
      "generated:" .. singular .. ":(%d+)",
    }
    for _, pattern in ipairs(patterns) do
      local found = value:match(pattern)
      if found then return tonumber(found) end
    end
    if plural == "fx" then
      local found = value:match("added%.fx%[(%d+)%]") or value:match("added%.fx%[(%d+)$") or value:match("added:fx:(%d+)")
      if found then return tonumber(found) end
    end
    return nil
  end

  local function created_ref_sequence_index(value, plural)
    value = tostring(value or ""):lower():gsub("%s+", "")
    if value == "" then return nil end
    plural = tostring(plural or "")
    local patterns = {
      "created%." .. plural .. "%[(%d+)%]",
      "created%." .. plural .. "%[(%d+)$",
      "generated%." .. plural .. "%[(%d+)%]",
      "generated%." .. plural .. "%[(%d+)$",
    }
    if plural == "fx" then
      table.insert(patterns, "added%.fx%[(%d+)%]")
      table.insert(patterns, "added%.fx%[(%d+)$")
    end
    for _, pattern in ipairs(patterns) do
      local found = value:match(pattern)
      if found then return tonumber(found) end
    end
    if value:match("^created:" .. plural .. ":%d+$") or value:match("^generated:" .. plural .. ":%d+$") then
      return tonumber(value:match(":(%d+)$"))
    end
    if plural == "fx" and (value:match("^added:fx:%d+$") or value:match("^added%.fx%[%d+%]$")) then
      return tonumber(value:match("(%d+)$"))
    end
    return nil
  end

  local function endpoint_has_explicit_track_target(endpoint, params, config)
    params = params or {}
    config = config or {}
    for _, key in ipairs(config.explicit_target_keys or {}) do
      if key == "selected" then
        if param_is_truthy(params[key]) then return true end
      elseif param_has_value(params, key) then
        if created_ref_index(params[key], "tracks") then
          -- created.tracks[N] is not an external explicit target; it should be resolved below.
        else
          return true
        end
      end
    end
    if endpoint == "track/add_fx"
      and param_has_value(params, "name")
      and not created_ref_index(params.name, "tracks")
      and (param_has_value(params, "fx") or param_has_value(params, "fx_name") or param_has_value(params, "effect") or param_has_value(params, "plugin")) then
      return true
    end
    return false
  end

  local function append_unique_key(keys, key)
    key = tostring(key or "")
    if key == "" then return end
    for _, existing in ipairs(keys) do
      if existing == key then return end
    end
    table.insert(keys, key)
  end

  local function created_track_ref_param(params, config)
    params = params or {}
    local keys = {}
    for _, key in ipairs((config and config.explicit_target_keys) or {}) do
      if key ~= "selected" then append_unique_key(keys, key) end
    end
    for _, key in ipairs((config and config.numeric_params) or {}) do
      append_unique_key(keys, key)
    end
    for _, key in ipairs({ "target", "track", "index", "name", "track_name", "old_name", "from" }) do
      append_unique_key(keys, key)
    end
    for _, key in ipairs(keys) do
      local ref_index = created_ref_sequence_index(params[key], "tracks")
      if ref_index then return ref_index, key end
    end
    return nil, nil
  end

  local function parse_created_track_target_step(step)
    if not step or step.kind ~= "mcp" then return nil end
    local endpoint, params = Operation.parse_call(step.call or "")
    local config = CREATED_TRACK_BIND_ENDPOINTS[endpoint]
    if not config then return nil end
    local ref_index, ref_key = created_track_ref_param(params, config)
    if ref_index then
      return endpoint, params, ref_index, ref_key or "target", config, "created-ref"
    end
    if endpoint_has_explicit_track_target(endpoint, params, config) then return nil end
    for _, key in ipairs(config.numeric_params or {}) do
      local numeric_index = tonumber(params[key] or "")
      if numeric_index then
        return endpoint, params, numeric_index, key, config, "numeric"
      end
    end
    return endpoint, params, nil, config.target_param, config, "default"
  end

  local function collect_created_track_target_indices(steps, start_index)
    local indices = {}
    if not steps or not start_index then return indices end
    for i = start_index, #steps do
      local endpoint, _, numeric_index, _, _, source_kind = parse_created_track_target_step(steps[i])
      if endpoint and numeric_index ~= nil then
        if source_kind ~= "created-ref" then
          table.insert(indices, numeric_index)
        end
      elseif #indices > 0 then
        break
      end
    end
    return indices
  end

  local function infer_created_group_index_base(group, indices)
    if not group or not group.count or group.count <= 0 then return nil end
    local count = group.count
    local has_zero = false
    local has_group_count = false
    local min_index = nil
    local max_index = nil
    for _, index in ipairs(indices or {}) do
      if index == 0 then has_zero = true end
      if index == count then has_group_count = true end
      min_index = min_index and math.min(min_index, index) or index
      max_index = max_index and math.max(max_index, index) or index
    end
    if has_zero then return 0 end
    if has_group_count then return 1 end
    if count == 1 and min_index == 1 then return 1 end
    if min_index == 0 and max_index and max_index < count then return 0 end
    if min_index == 1 and max_index and max_index <= count then return 1 end
    return nil
  end

  local function infer_created_track_index_base(group, steps, step_index)
    if not group or not group.tracks or #group.tracks == 0 then return nil end
    if group.relative_index_base ~= nil then return group.relative_index_base end
    return infer_created_group_index_base(group, collect_created_track_target_indices(steps, step_index))
  end

  local function resolve_created_object_relative_index(group, numeric_index, indices)
    if not group or not group.objects or #group.objects == 0 or numeric_index == nil then return nil, nil end
    for object_i, object in ipairs(group.objects) do
      if tonumber(object.index) == numeric_index then
        return object_i, "absolute"
      end
    end
    local relative_base = group.relative_index_base
    if relative_base == nil then
      relative_base = infer_created_group_index_base(group, indices)
      group.relative_index_base = relative_base
    end
    if relative_base == nil then return nil, nil end
    local relative_index = numeric_index - relative_base + 1
    if relative_index < 1 or relative_index > #group.objects then return nil, nil end
    return relative_index, "relative-" .. tostring(relative_base) .. "-based"
  end

  local function bind_mcp_step_to_created_tracks(step, execution_context, step_index)
    if not step or step.kind ~= "mcp" or not execution_context then return nil end
    local endpoint, params, numeric_index, source_param, config, source_kind = parse_created_track_target_step(step)
    if not endpoint then return nil end
    local group = execution_context.last_created_tracks
    if not group or not group.tracks or #group.tracks == 0 then return nil end
    local relative_index = nil
    local binding_kind = nil
    local created = nil
    if numeric_index == nil then
      if config and config.default_first and #group.tracks == 1 then
        relative_index = 1
        binding_kind = "default-created"
      else
        return nil
      end
    elseif source_kind == "created-ref" then
      local registry_tracks = execution_context.generated_registry and execution_context.generated_registry.tracks or nil
      created = registry_tracks and registry_tracks[numeric_index] or nil
      binding_kind = "created-ref"
      if not created and group and group.tracks then
        created = group.tracks[numeric_index]
        binding_kind = "created-ref-latest-group"
      end
    else
      local relative_base = infer_created_track_index_base(group, execution_context.steps, step_index)
      local batch_mode = group.batch_index_mode
      if group.base_count and group.base_count > 0 then
        if not batch_mode then
          local indices = collect_created_track_target_indices(execution_context.steps, step_index)
          local has_internal_start = false
          local has_visible_end = false
          for _, index in ipairs(indices) do
            if index == group.base_count then has_internal_start = true end
            if index == group.base_count + #group.tracks then has_visible_end = true end
          end
          if has_visible_end and not has_internal_start then
            batch_mode = "visible"
          elseif has_internal_start and not has_visible_end then
            batch_mode = "absolute"
          end
          group.batch_index_mode = batch_mode
        end
      end
      if group.base_count == 0 and relative_base ~= nil then
        relative_index = numeric_index - relative_base + 1
        binding_kind = "relative-" .. tostring(relative_base) .. "-based"
        group.relative_index_base = relative_base
      elseif batch_mode == "visible" then
        relative_index = numeric_index - group.base_count
        binding_kind = "visible"
      elseif batch_mode == "absolute" then
        relative_index = numeric_index - group.base_count + 1
        binding_kind = "absolute"
      elseif numeric_index >= group.base_count and numeric_index < group.base_count + #group.tracks then
        relative_index = numeric_index - group.base_count + 1
        binding_kind = "absolute"
      elseif numeric_index >= group.base_count + 1 and numeric_index <= group.base_count + #group.tracks then
        relative_index = numeric_index - group.base_count
        binding_kind = "visible"
      else
        if relative_base == nil then return nil end
        group.relative_index_base = relative_base
        relative_index = numeric_index - relative_base + 1
        binding_kind = "relative-" .. tostring(relative_base) .. "-based"
      end
    end
    if not created then
      if not relative_index or relative_index < 1 or relative_index > #group.tracks then return nil end
      created = group.tracks[relative_index]
    end
    if not created then return nil end
    local actual_index = RuntimeState.find_track_index_by_guid(created.guid) or created.index
    if not actual_index then return nil end
    local old_call = step.call
    params[(config and config.target_param) or source_param or "index"] = tostring(actual_index)
    params.target = nil
    params.track_name = nil
    params.old_name = nil
    params.from = nil
    if source_param == "name" or created_ref_index(params.name, "tracks") then
      params.name = nil
    end
    if config and config.target_param == "track" then
      params.index = nil
    end
    step.call = build_mcp_call(endpoint, params)
    step.bound_from_call = old_call
    step.bound_to_call = step.call
    step.binding_note = "Bound " .. tostring(endpoint) .. " target " .. tostring(numeric_index or "default") .. " (" .. binding_kind .. ") to created track index " .. tostring(actual_index)
    return step.binding_note
  end

  local function parse_created_item_target_step(step, execution_context)
    if not step or step.kind ~= "mcp" then return nil end
    local endpoint, params = Operation.parse_call(step.call or "")
    if not ITEM_BIND_ENDPOINTS[endpoint] then return nil end
    if param_has_value(params, "name") or param_has_value(params, "match") or param_has_value(params, "item_name") then
      return nil
    end
    local scope = tostring(params.scope or params.selector or params.target_scope or ""):lower():gsub("%s+", "_")
    if param_is_truthy(params.all) or param_is_truthy(params.all_items) or param_is_truthy(params.time_selection) or param_is_truthy(params.current) then
      return nil
    end
    if scope == "all" or scope == "time_selection" or scope == "time-selection" or scope == "current" or scope == "cursor" then
      return nil
    end
    local item_value = params.item or params.target or params.index
    local ref_index = created_ref_sequence_index(item_value, "items")
    if ref_index then
      return endpoint, params, ref_index, "created-ref"
    end
    if param_is_truthy(params.selected) then
      if execution_context and execution_context.prefer_generated_item_for_selected then
        return endpoint, params, 1, "selected-generated"
      end
      return nil
    end
    if item_value ~= nil and tostring(item_value) ~= "" then
      local numeric_index = tonumber(item_value)
      if not numeric_index then return nil end
      return endpoint, params, numeric_index, "numeric"
    end
    return endpoint, params, nil, "default"
  end

  local function collect_created_item_target_indices(steps, start_index)
    local indices = {}
    if not steps or not start_index then return indices end
    for i = start_index, #steps do
      local endpoint, _, numeric_index, source_kind = parse_created_item_target_step(steps[i])
      if endpoint and numeric_index ~= nil then
        if source_kind ~= "created-ref" and source_kind ~= "selected-generated" then
          table.insert(indices, numeric_index)
        end
      elseif #indices > 0 then
        break
      end
    end
    return indices
  end

  local function bind_mcp_step_to_created_items(step, execution_context, step_index)
    if not step or step.kind ~= "mcp" or not execution_context then return nil end
    local endpoint, params, numeric_index, source_kind = parse_created_item_target_step(step, execution_context)
    if not endpoint then return nil end
    local group = execution_context.last_created_items
    if not group or not group.objects or #group.objects == 0 then return nil end
    local relative_index, binding_kind
    local created = nil
    if numeric_index == nil then
      if #group.objects ~= 1 then return nil end
      relative_index, binding_kind = 1, "default-created"
    elseif source_kind == "created-ref" then
      local registry_items = execution_context.generated_registry and execution_context.generated_registry.items or nil
      created = registry_items and registry_items[numeric_index] or nil
      binding_kind = "created-ref"
    elseif source_kind == "selected-generated" then
      relative_index = numeric_index
      binding_kind = source_kind
    else
      relative_index, binding_kind = resolve_created_object_relative_index(group, numeric_index, collect_created_item_target_indices(execution_context.steps, step_index))
    end
    if not created then
      if not relative_index then return nil end
      created = group.objects[relative_index]
    end
    if not created then return nil end
    local actual_index = RuntimeState.find_item_index_by_ref(created.ref) or created.index
    if not actual_index then return nil end
    local old_call = step.call
    params.index = tostring(actual_index)
    params.item = nil
    params.target = nil
    params.selected = nil
    step.call = build_mcp_call(endpoint, params)
    step.bound_from_call = old_call
    step.bound_to_call = step.call
    step.binding_note = "Bound " .. tostring(endpoint) .. " target " .. tostring(numeric_index or "default") .. " (" .. tostring(source_kind or binding_kind) .. "/" .. tostring(binding_kind) .. ") to created item index " .. tostring(actual_index)
    return step.binding_note
  end

  local function bind_mcp_step_to_created_markers(step, execution_context)
    if not step or step.kind ~= "mcp" or not execution_context then return nil end
    local endpoint, params = Operation.parse_call(step.call or "")
    if endpoint ~= "marker/delete" then return nil end
    local group = execution_context.last_created_markers
    if not group or not group.objects or #group.objects == 0 then return nil end
    local numeric_index = created_ref_sequence_index(params.target or params.marker or params.index, "markers") or tonumber(params.index or "")
    local relative_index, binding_kind
    if numeric_index == nil then
      if #group.objects ~= 1 then return nil end
      relative_index, binding_kind = 1, "default-created"
    elseif created_ref_sequence_index(params.target or params.marker or params.index, "markers") then
      relative_index, binding_kind = numeric_index, "created-ref"
    else
      relative_index, binding_kind = resolve_created_object_relative_index(group, numeric_index, { numeric_index })
    end
    if not relative_index then return nil end
    local created = group.objects[relative_index]
    if not created or created.index == nil then return nil end
    local old_call = step.call
    params.index = tostring(created.index)
    params.target = nil
    params.marker = nil
    step.call = build_mcp_call(endpoint, params)
    step.bound_from_call = old_call
    step.bound_to_call = step.call
    step.binding_note = "Bound marker/delete target " .. tostring(numeric_index or "default") .. " (" .. tostring(binding_kind) .. ") to created marker index " .. tostring(created.index)
    return step.binding_note
  end

  local function bind_mcp_step_to_added_fx(step, execution_context)
    if not step or step.kind ~= "mcp" or not execution_context then return nil end
    local endpoint, params = Operation.parse_call(step.call or "")
    if endpoint ~= "track/remove_fx" then return nil end
    local ref_index = created_ref_sequence_index(params.target or params.fx or params.fx_index or params.index, "fx")
    if param_is_truthy(params.selected) or (param_has_value(params, "target") and not ref_index) then return nil end
    local group = execution_context.last_added_fx
    if not group or not group.objects or #group.objects == 0 then return nil end
    local numeric_index = ref_index or tonumber(params.fx_index or "")
    local relative_index, binding_kind
    if numeric_index == nil then
      if #group.objects ~= 1 then return nil end
      relative_index, binding_kind = 1, "default-created"
    elseif ref_index then
      relative_index, binding_kind = numeric_index, "created-ref"
    else
      relative_index, binding_kind = resolve_created_object_relative_index(group, numeric_index, { numeric_index })
    end
    if not relative_index then return nil end
    local created = group.objects[relative_index]
    if not created then return nil end
    local track_index = RuntimeState.find_track_index_by_guid(created.track_guid) or created.track_index
    if track_index == nil then return nil end
    local old_call = step.call
    params.track = tostring(track_index)
    params.index = nil
    params.name = nil
    params.target = nil
    params.fx = nil
    params.fx_index = tostring(created.fx_index or created.index or 0)
    step.call = build_mcp_call(endpoint, params)
    step.bound_from_call = old_call
    step.bound_to_call = step.call
    step.binding_note = "Bound track/remove_fx target " .. tostring(numeric_index or "default") .. " (" .. tostring(binding_kind) .. ") to added FX index " .. tostring(params.fx_index) .. " on track index " .. tostring(track_index)
    return step.binding_note
  end

  function M.bind_mcp_step_to_created_objects(step, execution_context, step_index)
    return bind_mcp_step_to_created_tracks(step, execution_context, step_index)
      or bind_mcp_step_to_created_items(step, execution_context, step_index)
      or bind_mcp_step_to_created_markers(step, execution_context)
      or bind_mcp_step_to_added_fx(step, execution_context)
  end

  return M
end

-- ============================================
-- RuntimeModel facade
-- ============================================
local RuntimeModel = {}

function RuntimeModel.create(deps)
  deps = deps or {}
  local runtime_state = RuntimeState.create()
  local generated_registry = GeneratedRegistry.create()
  local object_binding = ObjectBinding.create({
    Operation = deps.Operation,
    RuntimeState = runtime_state,
  })

  return {
    RuntimeState = runtime_state,
    GeneratedRegistry = generated_registry,
    ObjectBinding = object_binding,
    runtime_state = runtime_state,
    generated_registry = generated_registry,
    object_binding = object_binding,
  }
end

RuntimeModel.RuntimeState = RuntimeState
RuntimeModel.GeneratedRegistry = GeneratedRegistry
RuntimeModel.ObjectBinding = ObjectBinding

return RuntimeModel
