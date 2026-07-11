-- ReaperAI API probe.
-- Run inside REAPER to generate Scripts/ReaperAI/reaper_api_inventory.json.

local sep = package and package.config and package.config:sub(1, 1) or "/"
if sep == "" then sep = "/" end

local function join(a, b)
  if a:sub(-1) == "/" or a:sub(-1) == "\\" then return a .. b end
  return a .. sep .. b
end

local base = join(reaper.GetResourcePath(), "Scripts")
local out_dir = join(base, "ReaperAI")
local candidate_path = join(out_dir, "reaper_api_candidates.json")
local inventory_path = join(out_dir, "reaper_api_inventory.json")
local whitelist_path = join(out_dir, "reaper_api_whitelist.json")

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a") or ""
  f:close()
  return content
end

local function json_escape(s)
  s = tostring(s or "")
  s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "")
  return s
end

local function extract_json_array(content, key)
  local result = {}
  local block = tostring(content or ""):match('"' .. key .. '"%s*:%s*%[(.-)%]')
  if not block then return result end
  for raw in block:gmatch('"(.-)"') do
    local decoded = raw:gsub('\\"', '"'):gsub('\\\\', '\\')
    if decoded ~= "" then table.insert(result, decoded) end
  end
  return result
end

local candidate_content = read_file(candidate_path)
local candidates = extract_json_array(candidate_content or "", "candidates")
local candidate_source = "reaper_api_candidates.json"
local should_rewrite_candidates = candidate_content == nil or #candidates == 0
if #candidates == 0 then
  candidates = extract_json_array(read_file(inventory_path) or "", "available")
  candidate_source = "reaper_api_inventory.json"
end
if #candidates == 0 then
  candidates = extract_json_array(read_file(whitelist_path) or "", "available")
  candidate_source = "reaper_api_whitelist.json"
end
if #candidates == 0 then
  candidates = {
    "APIExists", "AddMediaItemToTrack", "AddProjectMarker", "AddProjectMarker2",
    "AddTakeToMediaItem", "CountMediaItems", "CountProjectMarkers", "CountTracks",
    "DeleteProjectMarker", "DeleteTrack", "DeleteTrackMediaItem", "EnumProjectMarkers",
    "GetActiveTake", "GetMediaItem", "GetMediaItemInfo_Value", "GetMediaItemTrack",
    "GetMediaSourceLength", "GetMediaSourceSampleRate", "GetMediaTrackInfo_Value",
    "GetResourcePath", "GetSelectedMediaItem", "GetSelectedTrack",
    "GetSetMediaItemTakeInfo_String", "GetSetMediaTrackInfo_String", "GetSet_LoopTimeRange",
    "GetTrack", "GetTrackGUID", "GetTrackMediaItem", "GetTrackName",
    "InsertMedia", "InsertTrackAtIndex", "Main_OnCommand", "SetEditCurPos",
    "PCM_Sink_Enum", "PCM_Sink_GetExtension", "PCM_Source_GetSectionInfo",
    "SetMediaItemInfo_Value", "SetMediaItemTake_Source", "SetProjectMarker", "SetProjectMarker3", "SetTrackSelected",
    "TrackFX_AddByName", "TrackFX_Delete", "TrackFX_GetCount", "TrackFX_GetFXName",
    "UpdateArrange", "UpdateTimeline", "time_precise",
  }
  candidate_source = "built_in_fallback"
end

local available, missing = {}, {}
for _, name in ipairs(candidates) do
  local exists = false
  if type(reaper.APIExists) == "function" then
    local ok, api_exists = pcall(reaper.APIExists, name)
    exists = ok and api_exists == true
  end
  if not exists and type(reaper[name]) == "function" then
    exists = true
  end
  if exists then
    table.insert(available, name)
  else
    table.insert(missing, name)
  end
end
table.sort(available)
table.sort(missing)

local generated_at = os.date("%Y-%m-%d %H:%M:%S")

local function write_string_array(f, key, values, indent)
  indent = indent or "  "
  f:write(indent .. '"' .. key .. '": [\n')
  for i, value in ipairs(values) do
    f:write(indent .. '  "' .. json_escape(value) .. '"' .. (i < #values and "," or "") .. '\n')
  end
  f:write(indent .. ']')
end

local function write_api_inventory(path)
  local f = assert(io.open(path, "w"))
  f:write('{\n')
  f:write('  "schema": "reaperai.reaper_api_inventory.v1",\n')
  f:write('  "generated_at": "' .. json_escape(generated_at) .. '",\n')
  f:write('  "portable": true,\n')
  f:write('  "reaper_resource_path": "' .. json_escape(reaper.GetResourcePath()) .. '",\n')
  f:write('  "api_count": ' .. tostring(#available) .. ',\n')
  f:write('  "available_count": ' .. tostring(#available) .. ',\n')
  f:write('  "missing_count": ' .. tostring(#missing) .. ',\n')
  f:write('  "sources": {\n')
  f:write('    "reaper_api_candidates.json": ' .. tostring(#candidates) .. ',\n')
  f:write('    "runtime_APIExists": ' .. tostring(#available) .. '\n')
  f:write('  },\n')
  f:write('  "apis": [\n')
  for i, name in ipairs(available) do
    f:write('    { "name": "' .. json_escape(name) .. '", "source": "runtime_APIExists", "available": true, "verifier_strength": "runtime_verified" }' .. (i < #available and "," or "") .. '\n')
  end
  f:write('  ],\n')
  write_string_array(f, "available", available, "  ")
  f:write(',\n')
  write_string_array(f, "missing", missing, "  ")
  f:write('\n}\n')
  f:close()
end

local function write_api_candidates(path)
  local f = assert(io.open(path, "w"))
  f:write('{\n')
  f:write('  "schema": "reaperai.reaper_api_candidates.v1",\n')
  f:write('  "count": ' .. tostring(#candidates) .. ',\n')
  write_string_array(f, "candidates", candidates, "  ")
  f:write(',\n')
  f:write('  "by_file": {\n')
  f:write('    "${REAPER_RESOURCE_PATH}/Scripts/ReaperAI/' .. json_escape(candidate_source) .. '": [\n')
  for i, name in ipairs(candidates) do
    f:write('      "' .. json_escape(name) .. '"' .. (i < #candidates and "," or "") .. '\n')
  end
  f:write('    ]\n')
  f:write('  }\n')
  f:write('}\n')
  f:close()
end

local function write_legacy_whitelist(path)
  local f = assert(io.open(path, "w"))
  f:write('{\n')
  f:write('  "schema": "reaperai.reaper_api_whitelist.v1",\n')
  f:write('  "generated_at": "' .. json_escape(generated_at) .. '",\n')
  f:write('  "portable": true,\n')
  f:write('  "reaper_resource_path": "' .. json_escape(reaper.GetResourcePath()) .. '",\n')
  f:write('  "available_count": ' .. tostring(#available) .. ',\n')
  f:write('  "missing_count": ' .. tostring(#missing) .. ',\n')
  write_string_array(f, "available", available, "  ")
  f:write(',\n')
  write_string_array(f, "missing", missing, "  ")
  f:write('\n}\n')
  f:close()
end

if should_rewrite_candidates then
  table.sort(candidates)
  write_api_candidates(candidate_path)
end

write_api_inventory(inventory_path)
write_legacy_whitelist(whitelist_path)

local result = {
  ok = true,
  kind = "api",
  out_path = inventory_path,
  inventory_path = inventory_path,
  whitelist_path = whitelist_path,
  api_count = #available,
  available_count = #available,
  missing_count = #missing,
  generated_at = generated_at,
}

_G.REAPERAI_LAST_API_PROBE_RESULT = result

if not _G.REAPERAI_PROBE_SILENT then
  reaper.ShowMessageBox(
    "ReaperAI API probe 完成\n\n可用 API: " .. tostring(#available) .. "\n缺失 API: " .. tostring(#missing) .. "\n\n输出:\n" .. inventory_path,
    "ReaperAI API Probe",
    0
  )
end

return result
