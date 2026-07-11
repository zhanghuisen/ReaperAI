-- ReaperAI context module
-- Owns project and selection context snapshots used for prompt injection and the project info dialog.

local Context = {}

function Context.create(opts)
  opts = opts or {}
  local Ctx = {}

  local function get_mcp_connection_diagnostics()
    if type(opts.get_mcp_connection_diagnostics) == "function" then
      return opts.get_mcp_connection_diagnostics()
    end
    return ""
  end

  function Ctx.get_project_context()
    local proj_path = ""
    local retval
    retval, proj_path = reaper.EnumProjects(-1, "")

    local ctx_lines = {"=== 当前 REAPER 工程信息 ==="}

    if proj_path and proj_path ~= "" then
      table.insert(ctx_lines, "工程文件: " .. proj_path)
    else
      table.insert(ctx_lines, "工程文件: 未保存")
    end

    local bpm, bpi = reaper.GetProjectTimeSignature2(0)
    table.insert(ctx_lines, string.format("BPM: %.1f | 拍号: %d/4", bpm, bpi))

    local track_count = reaper.CountTracks(0)
    table.insert(ctx_lines, "轨道数: " .. track_count)

    local item_count = reaper.CountMediaItems(0)
    table.insert(ctx_lines, "素材数: " .. item_count)

    local sel_items = reaper.CountSelectedMediaItems(0)
    if sel_items > 0 then
      table.insert(ctx_lines, "当前选中素材: " .. sel_items)
    end

    if track_count > 0 then
      table.insert(ctx_lines, "轨道列表:")
      for i = 0, math.min(track_count - 1, 15) do
        local track = reaper.GetTrack(0, i)
        local _, tname = reaper.GetTrackName(track)
        local fx_count = reaper.TrackFX_GetCount(track)
        local fx_info = fx_count > 0 and string.format(" [%d FX]", fx_count) or ""
        table.insert(ctx_lines, string.format("  [%d] %s%s", i, tname, fx_info))
      end
      if track_count > 16 then
        table.insert(ctx_lines, "  ... 更多轨道 ...")
      end
    end

    table.insert(ctx_lines, "===")
    return table.concat(ctx_lines, "\n")
  end

  function Ctx.get_selection_context()
    local lines = {get_mcp_connection_diagnostics(), "=== 实时抓取信息 ==="}

    local proj_path = ""
    local retval
    retval, proj_path = reaper.EnumProjects(-1, "")
    if proj_path and proj_path ~= "" then
      table.insert(lines, "工程: " .. proj_path:match("([^\\/]+)$") or proj_path)
    else
      table.insert(lines, "工程: 未保存")
    end

    local bpm, bpi = reaper.GetProjectTimeSignature2(0)
    table.insert(lines, string.format("BPM: %.1f | 拍号: %d/4", bpm, bpi))
    table.insert(lines, "")

    local selected_tracks = {}
    local track_count = reaper.CountTracks(0)
    for i = 0, track_count - 1 do
      local track = reaper.GetTrack(0, i)
      if track and reaper.IsTrackSelected(track) then
        local _, name = reaper.GetTrackName(track)
        local vol = reaper.GetMediaTrackInfo_Value(track, "D_VOL")
        local vol_db = 20 * math.log(vol, 10)
        local mute = reaper.GetMediaTrackInfo_Value(track, "B_MUTE") == 1
        local solo = reaper.GetMediaTrackInfo_Value(track, "I_SOLO") > 0

        local item_count = reaper.CountTrackMediaItems(track)
        local fx_count = reaper.TrackFX_GetCount(track)
        local send_count = reaper.GetTrackNumSends(track, 0)
        local receive_count = reaper.GetTrackNumSends(track, -1)

        local status = ""
        if mute then status = status .. "[静音]" end
        if solo then status = status .. "[独奏]" end

        local details = {}
        if item_count > 0 then table.insert(details, item_count .. "片段") end
        if fx_count > 0 then table.insert(details, fx_count .. "FX") end
        if send_count > 0 then table.insert(details, send_count .. "发送") end
        if receive_count > 0 then table.insert(details, receive_count .. "接收") end

        local detail_str = ""
        if #details > 0 then
          detail_str = " [" .. table.concat(details, ", ") .. "]"
        end

        table.insert(selected_tracks, string.format("  [%d] %s %s (%.1fdB)%s",
          i, name, status, vol_db, detail_str))
      end
    end

    if #selected_tracks > 0 then
      table.insert(lines, "选中轨道 (" .. #selected_tracks .. "个):")
      for _, info in ipairs(selected_tracks) do
        table.insert(lines, info)
      end
    else
      table.insert(lines, "选中轨道: 无")
    end

    table.insert(lines, "")

    local sel_items = {}
    local item_count = reaper.CountMediaItems(0)
    for i = 0, item_count - 1 do
      local item = reaper.GetMediaItem(0, i)
      if item and reaper.IsMediaItemSelected(item) then
        local track = reaper.GetMediaItemTrack(item)
        local _, track_name = reaper.GetTrackName(track)
        local take = reaper.GetActiveTake(item)
        local take_name = ""
        if take then
          _, take_name = reaper.GetTakeName(take)
        end
        local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        table.insert(sel_items, string.format("  [%d] %s @ %s | %.2fs (轨道: %s)",
          i, take_name, string.format("%.2f", pos), len, track_name))
      end
    end

    if #sel_items > 0 then
      table.insert(lines, "选中片段 (" .. #sel_items .. "个):")
      for _, info in ipairs(sel_items) do
        table.insert(lines, info)
      end
    else
      table.insert(lines, "选中片段: 无")
    end

    table.insert(lines, "")

    local play_state = reaper.GetPlayState()
    local state_text = "停止"
    if play_state == 1 then state_text = "播放中"
    elseif play_state == 2 then state_text = "暂停"
    elseif play_state == 4 then state_text = "录音中"
    elseif play_state == 5 then state_text = "播放+录音"
    end
    local cursor_pos = reaper.GetCursorPosition()
    table.insert(lines, string.format("播放状态: %s | 光标位置: %.3fs", state_text, cursor_pos))

    local time_sel_start, time_sel_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
    if time_sel_start ~= time_sel_end then
      table.insert(lines, string.format("时间选区: %.3fs - %.3fs (%.3fs)",
        time_sel_start, time_sel_end, time_sel_end - time_sel_start))
    end
    if reaper.GetSelectedEnvelope then
      local selected_env = reaper.GetSelectedEnvelope(0)
      table.insert(lines, "选中包络: " .. (selected_env and "有" or "无"))
    end

    local selector_current_items = 0
    local selector_time_items = 0
    for i = 0, reaper.CountMediaItems(0) - 1 do
      local item = reaper.GetMediaItem(0, i)
      if item then
        local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        if cursor_pos >= pos - 0.001 and cursor_pos <= pos + len + 0.001 then
          selector_current_items = selector_current_items + 1
        end
        if time_sel_start ~= time_sel_end and (pos + len) > time_sel_start + 0.001 and pos < time_sel_end - 0.001 then
          selector_time_items = selector_time_items + 1
        end
      end
    end
    table.insert(lines, string.format("Selector candidates: selected_tracks=%d, selected_items=%d, current_items=%d, time_selection_items=%d", #selected_tracks, #sel_items, selector_current_items, selector_time_items))

    table.insert(lines, "")
    local cursor_region_info = {}
    local marker_region_entries = {}
    local live_region_entries = {}
    local live_marker_entries = {}
    local marker_total, marker_num, region_num = reaper.CountProjectMarkers(0)
    marker_total = tonumber(marker_total) or ((tonumber(marker_num) or 0) + (tonumber(region_num) or 0))
    local function enum_project_marker(i)
      if reaper.EnumProjectMarkers3 then
        return reaper.EnumProjectMarkers3(0, i)
      end
      return reaper.EnumProjectMarkers(i)
    end
    for i = 0, marker_total - 1 do
      local retval, is_region, region_pos, region_end, region_name, region_idx = enum_project_marker(i)
      if retval ~= 0 then
        local entry = {
          is_region = is_region,
          pos = region_pos or 0,
          ["end"] = region_end or 0,
          name = region_name or "",
          index = region_idx,
        }
        table.insert(marker_region_entries, entry)
        if is_region then
          table.insert(live_region_entries, entry)
        else
          table.insert(live_marker_entries, entry)
        end
      end

      if retval ~= 0 and is_region then
        if cursor_pos >= (region_pos or 0) and cursor_pos <= (region_end or 0) then
          table.insert(cursor_region_info, string.format("  区域 [%d]: %s (%.3fs - %.3fs, 时长 %.3fs)",
            region_idx, region_name, region_pos, region_end, region_end - region_pos))
        end
      elseif retval ~= 0 then
        if math.abs(cursor_pos - (region_pos or 0)) < 0.001 then
          table.insert(cursor_region_info, string.format("  标记 [%d]: %s @ %.3fs",
            region_idx, region_name, region_pos))
        end
      end
    end

    local function ranges_overlap(a_start, a_end, b_start, b_end)
      return (a_end or 0) > (b_start or 0) + 0.001 and (a_start or 0) < (b_end or 0) - 0.001
    end

    local function close_enough(a, b)
      return math.abs((a or 0) - (b or 0)) <= 0.001
    end

    local function choose_region_selection_candidates()
      if time_sel_start == time_sel_end then return {}, "" end
      local exact = {}
      local contained = {}
      local overlap = {}
      for _, entry in ipairs(live_region_entries) do
        local pos = entry.pos or 0
        local rgnend = entry["end"] or 0
        if close_enough(pos, time_sel_start) and close_enough(rgnend, time_sel_end) then
          table.insert(exact, entry)
        elseif pos >= time_sel_start - 0.001 and rgnend <= time_sel_end + 0.001 then
          table.insert(contained, entry)
        elseif ranges_overlap(pos, rgnend, time_sel_start, time_sel_end) then
          table.insert(overlap, entry)
        end
      end
      if #exact > 0 then return exact, "时间选区精确匹配" end
      if #contained > 0 then return contained, "时间选区完全包含" end
      if #overlap > 0 then return overlap, "时间选区重叠" end
      return {}, ""
    end

    local inferred_regions, inferred_region_source = choose_region_selection_candidates()
    table.insert(lines, "")
    if #inferred_regions > 0 then
      table.insert(lines, "推断选中 Region (" .. #inferred_regions .. "个，来源: " .. inferred_region_source .. "):")
      for _, r in ipairs(inferred_regions) do
        table.insert(lines, string.format("  [R%d] %s (%.3fs - %.3fs)",
          r.index or 0, r.name or "", r.pos or 0, r["end"] or 0))
      end
      table.insert(lines, "Region selector hint: 用户说“选中的 Region/选中区域”时，使用 ACTION_PLAN 的 region.delete scope=selected；保留选中并删除其他时使用 region.delete scope=all exclude=selected。")
    else
      table.insert(lines, "推断选中 Region: 无（REAPER 未提供稳定的显式 Region 选择 API；当前只能由时间选区推断）")
    end

    table.insert(lines, "Generic selector hint: contextual selection candidates are resolved by ACTION_PLAN scope/exclude. Use region.delete scope=selected/current/time_selection or scope=all exclude=selected; do not use region/delete?selected=true or keep_selected=true.")
    table.insert(lines, "Color endpoint hint: track color uses track/set_color; item color uses item/set_color; Region color uses region/set_color. Region and Marker are separate objects; never use Marker operations for Region color.")

    if #cursor_region_info > 0 then
      table.insert(lines, "光标所在位置:")
      for _, info in ipairs(cursor_region_info) do
        table.insert(lines, info)
      end
    else
      table.insert(lines, "光标所在位置: 无标记/区域")
    end

    table.insert(lines, "")
    if time_sel_start ~= time_sel_end then
      local regions_in_selection = {}
      for _, entry in ipairs(live_region_entries) do
        local region_pos = entry.pos or 0
        local region_end = entry["end"] or 0
        local region_name = entry.name or ""
        local region_idx = entry.index or 0
          local overlap = not (region_end < time_sel_start or region_pos > time_sel_end)
          if overlap then
            local contained = ""
            if region_pos >= time_sel_start and region_end <= time_sel_end then
              contained = " [完全包含]"
            elseif region_pos < time_sel_start and region_end > time_sel_end then
              contained = " [包含选区]"
            elseif region_pos < time_sel_start then
              contained = " [起始在外]"
            else
              contained = " [结束在外]"
            end
            table.insert(regions_in_selection, string.format("  [%d] %s (%.3fs - %.3fs)%s",
              region_idx, region_name, region_pos, region_end, contained))
          end
      end

      if #regions_in_selection > 0 then
        table.insert(lines, "时间选区内的区域 (" .. #regions_in_selection .. "个):")
        for _, info in ipairs(regions_in_selection) do
          table.insert(lines, info)
        end
      else
        table.insert(lines, "时间选区内的区域: 无")
      end
    else
      table.insert(lines, "时间选区内的区域: 无（未设置时间选区）")
    end

    if #live_region_entries > 0 then
      table.insert(lines, "")
      table.insert(lines, "Live Region index table (" .. #live_region_entries .. " regions):")
      local max_regions = math.min(#live_region_entries, 80)
      for i = 1, max_regions do
        local r = live_region_entries[i]
        table.insert(lines, string.format("  [R%d] %s @ %.3fs-%.3fs",
          r.index or 0, r.name or "", r.pos or 0, r["end"] or 0))
      end
      if #live_region_entries > max_regions then
        table.insert(lines, "  ... " .. tostring(#live_region_entries - max_regions) .. " more regions omitted")
      end
      table.insert(lines, "Region delete hint: R ids use [MCP_CALL:region/delete?index=N] or [MCP_CALL:region/delete?start=A&end=B]. Timeline order uses [MCP_CALL:region/delete?order_start=A&order_end=B]. Ask when the user only says 5-10 or 第5到10个Region.")
    else
      table.insert(lines, "")
      table.insert(lines, "Live Region index table: none")
    end

    local region_count = #marker_region_entries
    if region_count > 0 and region_count <= 20 then
      table.insert(lines, "")
      table.insert(lines, "所有标记/区域 (" .. region_count .. "个):")
      for _, entry in ipairs(marker_region_entries) do
        local is_region = entry.is_region
        local region_pos = entry.pos or 0
        local region_end = entry["end"] or 0
        local region_name = entry.name or ""
        local region_idx = entry.index or 0

        if is_region then
          table.insert(lines, string.format("  [R%d] %s @ %.3fs-%.3fs",
            region_idx, region_name, region_pos, region_end))
        else
          table.insert(lines, string.format("  [M%d] %s @ %.3fs",
            region_idx, region_name, region_pos))
        end
      end
    end

    table.insert(lines, "")
    table.insert(lines, "提示: 以上信息已准备好，发送消息时将自动附加给AI")
    table.insert(lines, "===")

    return table.concat(lines, "\n")
  end

  return Ctx
end

return Context
