-- ReaperAI native Action probe.
-- Run inside REAPER to generate Scripts/ReaperAI/reaper_action_inventory.json.

local sep = package and package.config and package.config:sub(1, 1) or "/"
if sep == "" then sep = "/" end

local function join(a, b)
  if a:sub(-1) == "/" or a:sub(-1) == "\\" then return a .. b end
  return a .. sep .. b
end

local resource_path = reaper.GetResourcePath()
local out_dir = join(join(resource_path, "Scripts"), "ReaperAI")
local out_path = join(out_dir, "reaper_action_inventory.json")
local kb_path = join(resource_path, "reaper-kb.ini")

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

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

local actions = {}
local by_key = {}
local source_counts = {}

local function bump_source(source)
  source = tostring(source or "unknown")
  source_counts[source] = (source_counts[source] or 0) + 1
end

local function resolve_named_command(id)
  id = trim(id)
  if id:sub(1, 1) ~= "_" then return nil end
  if type(reaper.NamedCommandLookup) ~= "function" then return nil end
  local ok, resolved = pcall(reaper.NamedCommandLookup, id)
  resolved = tonumber(ok and resolved or nil)
  if resolved and resolved > 0 then return tostring(resolved) end
  return nil
end

local function classify(name)
  local lower = tostring(name or ""):lower()
  local effects = {}
  local risk = "unknown"

  if lower:find("delete", 1, true) or lower:find("remove", 1, true) then
    effects.destructive = true
    risk = "destructive"
  end
  if lower:find("render", 1, true) or lower:find("export", 1, true) or lower:find("save", 1, true) then
    effects.writes_disk = true
    if risk == "unknown" then risk = "writes_disk" end
  end
  if lower:find("record", 1, true) then
    effects.records_audio = true
    if risk == "unknown" then risk = "recording" end
  end
  if lower:find("select", 1, true) or lower:find("selected", 1, true) or lower:find("selection", 1, true) then
    effects.selection_dependent = true
  end
  if lower:find("toggle", 1, true) then
    effects.toggles_state = true
  end
  if lower:find("show", 1, true) or lower:find("open", 1, true) or lower:find("window", 1, true) then
    effects.opens_window = true
  end

  return risk, effects
end

local function add_action(entry)
  if type(entry) ~= "table" then return false end
  local id = trim(entry.id or entry.command_id or entry.command)
  if id == "" or id == "0" then return false end

  local command_name = trim(entry.command_name or entry.named_command or "")
  local resolved = resolve_named_command(id)
  if resolved then
    command_name = command_name ~= "" and command_name or id
    id = resolved
  end

  local name = trim(entry.name or entry.label or command_name or id)
  local risk, effects = classify(name)
  if type(entry.effects) == "table" then
    for k, v in pairs(entry.effects) do effects[k] = v == true end
  end
  if entry.risk and entry.risk ~= "" then risk = tostring(entry.risk) end

  local key = tostring(entry.section or "main") .. ":" .. id
  local existing = by_key[key]
  if existing then
    if command_name ~= "" and existing.command_name == "" then existing.command_name = command_name end
    if name ~= "" and existing.name == "" then existing.name = name end
    if not existing.source:find(tostring(entry.source or "unknown"), 1, true) then
      existing.source = existing.source .. "," .. tostring(entry.source or "unknown")
    end
    for k, v in pairs(effects) do existing.effects[k] = v end
    existing.allowed_in_script = existing.allowed_in_script == true or entry.allowed_in_script == true
    bump_source(entry.source)
    return true
  end

  local item = {
    id = id,
    command_id = id,
    command_name = command_name,
    name = name,
    section = tostring(entry.section or "main"),
    section_id = tostring(entry.section_id or ""),
    source = tostring(entry.source or "unknown"),
    allowed_in_script = entry.allowed_in_script == true,
    requires_selection = entry.requires_selection == true,
    risk = risk,
    verifier_strength = tostring(entry.verifier_strength or "observed"),
    effects = effects,
  }
  by_key[key] = item
  table.insert(actions, item)
  bump_source(item.source)
  return true
end

local function parse_reaper_kb()
  local content = read_file(kb_path)
  if not content or content == "" then return 0 end
  local before = #actions
  for line in content:gmatch("[^\r\n]+") do
    local cmd, section_id = line:match("^KEY%s+%S+%s+%S+%s+(%S+)%s+(%S+)")
    if cmd and cmd ~= "0" then
      local comment = line:match("#%s*(.*)$") or ""
      add_action({
        id = cmd,
        command_name = cmd:sub(1, 1) == "_" and cmd or "",
        name = comment,
        section = section_id == "0" and "main" or tostring(section_id or "main"),
        section_id = section_id,
        source = "reaper-kb.ini",
        allowed_in_script = false,
        verifier_strength = "observed_keymap",
      })
    else
      local script_cmd, label = line:match('^SCR%s+%S+%s+%S+%s+(RS%S+)%s+"([^"]+)"')
      if script_cmd then
        add_action({
          id = "_" .. script_cmd,
          command_name = "_" .. script_cmd,
          name = label,
          section = "main",
          section_id = "0",
          source = "reaper-kb.ini",
          allowed_in_script = false,
          verifier_strength = "observed_script",
        })
      end
    end
  end
  return #actions - before
end

local function probe_sws_enumerate()
  if type(reaper.CF_EnumerateActions) ~= "function" then return 0 end
  local before = #actions
  local sections = {
    { id = 0, name = "main" },
    { id = 32060, name = "midi_editor" },
    { id = 32061, name = "midi_event_list" },
  }

  for _, section in ipairs(sections) do
    local misses = 0
    for idx = 0, 20000 do
      local values = { pcall(reaper.CF_EnumerateActions, section.id, idx, "", 4096) }
      if not values[1] then break end
      local command_id = tonumber(values[2])
      local label = ""
      for i = 3, #values do
        if type(values[i]) == "string" and values[i] ~= "" then label = values[i] end
      end

      if command_id and command_id > 0 then
        misses = 0
        add_action({
          id = tostring(command_id),
          name = label ~= "" and label or tostring(command_id),
          section = section.name,
          section_id = tostring(section.id),
          source = "SWS_CF_EnumerateActions",
          allowed_in_script = false,
          verifier_strength = "enumerated_runtime",
        })
      else
        misses = misses + 1
        if idx > 0 or misses >= 4 then break end
      end
    end
  end

  return #actions - before
end

local function add_existing_reaperai_actions()
  local baseline = {
    { id = 40406, name = "Track: show volume envelope", effects = { selection_dependent = true } },
    { id = 40407, name = "Track: show pan envelope", effects = { selection_dependent = true } },
    { id = 40867, name = "Track: show mute envelope", effects = { selection_dependent = true } },
    { id = 40693, name = "Take: show volume envelope", effects = { selection_dependent = true } },
    { id = 40694, name = "Take: show pan envelope", effects = { selection_dependent = true } },
    { id = 40695, name = "Take: show mute envelope", effects = { selection_dependent = true } },
    { id = 42230, name = "File: render project to disk", effects = { writes_disk = true }, risk = "writes_disk" },
  }
  for _, entry in ipairs(baseline) do
    entry.source = "reaperai_existing_hardcoded"
    entry.allowed_in_script = false
    entry.verifier_strength = "existing_project_dependency"
    add_action(entry)
  end
end

parse_reaper_kb()
probe_sws_enumerate()
add_existing_reaperai_actions()

table.sort(actions, function(a, b)
  local sa = tostring(a.section or "")
  local sb = tostring(b.section or "")
  if sa ~= sb then return sa < sb end
  local na = tonumber(a.id)
  local nb = tonumber(b.id)
  if na and nb and na ~= nb then return na < nb end
  return tostring(a.id) < tostring(b.id)
end)

local function write_effects(f, effects, indent)
  local keys = {}
  for k, v in pairs(effects or {}) do
    table.insert(keys, k)
  end
  table.sort(keys)
  f:write("{")
  if #keys > 0 then f:write("\n") end
  for i, key in ipairs(keys) do
    f:write(indent .. '  "' .. json_escape(key) .. '": ' .. (effects[key] and "true" or "false") .. (i < #keys and "," or "") .. "\n")
  end
  if #keys > 0 then f:write(indent) end
  f:write("}")
end

local f = assert(io.open(out_path, "w"))
f:write('{\n')
f:write('  "schema": "reaperai.reaper_action_inventory.v1",\n')
f:write('  "generated_at": "' .. json_escape(os.date("%Y-%m-%d %H:%M:%S")) .. '",\n')
f:write('  "portable": true,\n')
f:write('  "reaper_resource_path": "' .. json_escape(resource_path) .. '",\n')
f:write('  "reaper_kb_path": "' .. json_escape(kb_path) .. '",\n')
f:write('  "action_count": ' .. tostring(#actions) .. ',\n')
f:write('  "sources": {\n')
local source_keys = {}
for source in pairs(source_counts) do table.insert(source_keys, source) end
table.sort(source_keys)
for i, source in ipairs(source_keys) do
  f:write('    "' .. json_escape(source) .. '": ' .. tostring(source_counts[source]) .. (i < #source_keys and "," or "") .. '\n')
end
f:write('  },\n')
f:write('  "actions": [\n')
for i, item in ipairs(actions) do
  f:write('    {\n')
  f:write('      "id": "' .. json_escape(item.id) .. '",\n')
  f:write('      "command_id": "' .. json_escape(item.command_id) .. '",\n')
  f:write('      "command_name": "' .. json_escape(item.command_name) .. '",\n')
  f:write('      "name": "' .. json_escape(item.name) .. '",\n')
  f:write('      "section": "' .. json_escape(item.section) .. '",\n')
  f:write('      "section_id": "' .. json_escape(item.section_id) .. '",\n')
  f:write('      "source": "' .. json_escape(item.source) .. '",\n')
  f:write('      "allowed_in_script": ' .. (item.allowed_in_script and "true" or "false") .. ',\n')
  f:write('      "requires_selection": ' .. (item.requires_selection and "true" or "false") .. ',\n')
  f:write('      "risk": "' .. json_escape(item.risk) .. '",\n')
  f:write('      "verifier_strength": "' .. json_escape(item.verifier_strength) .. '",\n')
  f:write('      "effects": ')
  write_effects(f, item.effects, "      ")
  f:write('\n')
  f:write('    }' .. (i < #actions and "," or "") .. '\n')
end
f:write('  ]\n')
f:write('}\n')
f:close()

local result = {
  ok = true,
  kind = "action",
  out_path = out_path,
  action_count = #actions,
  generated_at = os.date("%Y-%m-%d %H:%M:%S"),
}

_G.REAPERAI_LAST_ACTION_PROBE_RESULT = result

if not _G.REAPERAI_PROBE_SILENT then
  reaper.ShowMessageBox(
    "ReaperAI Action probe complete\n\nActions: " .. tostring(#actions) .. "\nOutput:\n" .. out_path,
    "ReaperAI Action Probe",
    0
  )
end

return result
