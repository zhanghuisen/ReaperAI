local CapabilityRegistry = {}

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function shallow_copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for k, v in pairs(value) do
    if type(v) ~= "table" then
      out[k] = v
    end
  end
  return out
end

function CapabilityRegistry.create(deps)
  deps = deps or {}
  local Operation = deps.Operation
  local ReaperCapabilities = deps.ReaperCapabilities
  local GeneratedRegistry = deps.GeneratedRegistry
  if not Operation then error("CapabilityRegistry requires Operation", 0) end
  if not ReaperCapabilities then error("CapabilityRegistry requires ReaperCapabilities", 0) end
  if not GeneratedRegistry then error("CapabilityRegistry requires GeneratedRegistry", 0) end

  local M = {}
  local endpoint_cache = {}
  local native_cache = {}
  local endpoint_meta
  local capability_card
  local cards_summary

  local CAPABILITY_CARD_ORDER = {
    "transport/play",
    "transport/stop",
    "track/create",
    "track/delete",
    "track/rename",
    "track/set_volume",
    "track/set_volume_by_name",
    "track/set_pan",
    "track/set_color",
    "track/clear_color",
    "track/mute",
    "track/solo",
    "track/add_fx",
    "track/remove_fx",
    "track/group_into_folder",
    "track/create_folder",
    "marker/add",
    "marker/delete",
    "region/delete",
    "item/fade",
    "item/set_fade",
    "item/fade_shape",
    "item/set_fade_shape",
    "envelope/draw",
    "envelope/clear",
    "region/batch_rename",
    "sfx/generate_variants",
    "analysis/detect_peaks",
    "analysis/find_loop_points",
    "export/batch_regions",
    "export/tracks",
    "export/master",
    "native/action",
    "endpoints",
  }

  local CAPABILITY_CARDS = {
    ["transport/play"] = { intent = "start project playback", target_binding = "transport", params = {}, prefer_mcp_when = "playback control", allow_script = false, risk = "read_only", verifier = "transport/state", repair = "retry or use transport/stop" },
    ["transport/stop"] = { intent = "stop project playback", target_binding = "transport", params = {}, prefer_mcp_when = "playback control", allow_script = false, risk = "read_only", verifier = "transport/state", repair = "retry once" },
    ["track/create"] = { intent = "create one or more tracks", target_binding = "created.tracks", params = { "name", "names", "count", "volume" }, prefer_mcp_when = "creating tracks or named track sets", allow_script = false, risk = "modify", verifier = "track/create", repair = "use names instead of create plus rename" },
    ["track/delete"] = { intent = "delete tracks", target_binding = "index/name/match/selected/all", params = { "index", "name", "match", "selected", "all" }, prefer_mcp_when = "deleting tracks by stable target or all=true", allow_script = false, risk = "destructive", verifier = "track/delete", repair = "require explicit target; all=true is explicit" },
    ["track/rename"] = { intent = "rename a track", target_binding = "index/target/selected", params = { "index", "target", "name" }, prefer_mcp_when = "renaming tracks", allow_script = false, risk = "modify", verifier = "track/rename", repair = "bind created.tracks or require index/target" },
    ["track/set_volume"] = { intent = "set track volume", target_binding = "index/name/track/selected/all/created.tracks", params = { "index", "name", "track", "target", "selected", "all", "volume" }, prefer_mcp_when = "track gain changes", allow_script = false, risk = "modify", verifier = "track/property", repair = "require volume and stable track target; all=true is explicit" },
    ["track/set_volume_by_name"] = { intent = "set track volume by exact name", target_binding = "name", params = { "name", "volume" }, prefer_mcp_when = "name is known", allow_script = false, risk = "modify", verifier = "track/property", repair = "fall back to track/set_volume with index" },
    ["track/set_pan"] = { intent = "set track pan", target_binding = "index/name/track/selected/all/created.tracks", params = { "index", "name", "track", "target", "selected", "all", "pan" }, prefer_mcp_when = "track pan changes", allow_script = false, risk = "modify", verifier = "track/property", repair = "require pan and stable track target; all=true is explicit" },
    ["track/set_color"] = { intent = "set or clear track color", target_binding = "index/name/track/selected/all/created.tracks", params = { "index", "name", "track", "target", "selected", "all", "color" }, prefer_mcp_when = "static track colors or clearing custom/default color", allow_script = false, risk = "modify", verifier = "track/property", repair = "use color name, #RRGGBB, r,g,b, or color=default/clear with stable target" },
    ["track/clear_color"] = { intent = "clear custom track color and restore default/theme color", target_binding = "index/name/track/selected/all/created.tracks", params = { "index", "name", "track", "target", "selected", "all" }, prefer_mcp_when = "clearing custom/default track color", allow_script = false, risk = "modify", verifier = "track/property", repair = "use all=true, selected=true, index, name, track, or target" },
    ["track/mute"] = { intent = "mute or unmute tracks", target_binding = "index/name/track/selected/all/created.tracks", params = { "index", "name", "track", "target", "selected", "all", "mute" }, prefer_mcp_when = "mute toggles", allow_script = false, risk = "modify", verifier = "track/property", repair = "require mute=true/false and stable target; all=true is explicit" },
    ["track/solo"] = { intent = "solo or unsolo tracks", target_binding = "index/name/track/selected/all/created.tracks", params = { "index", "name", "track", "target", "selected", "all", "solo" }, prefer_mcp_when = "solo toggles", allow_script = false, risk = "modify", verifier = "track/property", repair = "require solo=true/false and stable target; all=true is explicit" },
    ["track/add_fx"] = { intent = "add FX to a track", target_binding = "track/target/selected/created.tracks", params = { "track", "target", "selected", "fx" }, prefer_mcp_when = "adding plugins by name", allow_script = false, risk = "modify", verifier = "fx/add", repair = "require fx name and stable track target" },
    ["track/remove_fx"] = { intent = "remove FX from a track", target_binding = "track/target/selected/created.tracks", params = { "track", "target", "selected", "fx_index", "fx" }, prefer_mcp_when = "removing known FX slot", allow_script = false, risk = "destructive", verifier = "fx/remove", repair = "require fx_index/fx and stable track target" },
    ["track/group_into_folder"] = { intent = "group tracks into a folder", target_binding = "tracks/match", params = { "folder_name", "tracks", "match" }, prefer_mcp_when = "folder organization", allow_script = false, risk = "batch_modify", verifier = "track/create", repair = "require tracks or match" },
    ["track/create_folder"] = { intent = "alias for folder grouping", alias_of = "track/group_into_folder", target_binding = "tracks/match", params = { "folder_name", "tracks", "match" }, prefer_mcp_when = "folder organization", allow_script = false, risk = "batch_modify", verifier = "track/create", repair = "prefer track/group_into_folder" },
    ["marker/add"] = { intent = "add marker", target_binding = "timeline", params = { "time", "name" }, prefer_mcp_when = "marker creation", allow_script = false, risk = "modify", verifier = "marker/add", repair = "default time to cursor" },
    ["marker/delete"] = { intent = "delete marker(s)", target_binding = "index/ids/range/name/all/created.markers", params = { "index", "ids", "range", "start", "end", "name", "match", "target", "marker", "all" }, prefer_mcp_when = "Marker deletion by id, range, name, or all=true while preserving Regions", allow_script = false, risk = "destructive", verifier = "marker/delete", repair = "require marker selector; all=true is explicit; never delete Regions" },
    ["item/fade"] = { intent = "set item fade length", target_binding = "created.items/index/name/selected", params = { "fade_in_ms", "fade_out_ms", "index", "name", "target", "item", "selected" }, prefer_mcp_when = "item fades, especially after generated variants", allow_script = false, risk = "modify", verifier = "item/property", repair = "bind created.items[1] after sfx/generate_variants or require explicit item target" },
    ["item/set_fade"] = { intent = "alias for item/fade", alias_of = "item/fade", target_binding = "created.items/index/name/selected", params = { "in", "out", "in_ms", "out_ms", "item", "target", "selected" }, prefer_mcp_when = "legacy fade syntax appears", allow_script = false, risk = "modify", verifier = "item/property", repair = "prefer item/fade with explicit item target" },
    ["item/fade_shape"] = { intent = "set item fade curve shape", target_binding = "index/name/selected/all", params = { "shape", "direction", "selected", "all" }, prefer_mcp_when = "fade curve normalization", allow_script = false, risk = "modify", verifier = "item/property", repair = "default shape=linear" },
    ["item/set_fade_shape"] = { intent = "alias for item/fade_shape", alias_of = "item/fade_shape", target_binding = "index/name/selected/all", params = { "shape", "direction" }, prefer_mcp_when = "legacy fade shape syntax appears", allow_script = false, risk = "modify", verifier = "item/property", repair = "prefer item/fade_shape" },
    ["envelope/draw"] = { intent = "draw track, item, take, or selected envelope points", target_binding = "target/index/name/selected/selected_envelope", params = { "target", "lane", "start", "end", "from", "to", "shape" }, prefer_mcp_when = "automation drawing", allow_script = false, risk = "modify", verifier = "observed", repair = "use selected_envelope or explicit target; do not use target=selected" },
    ["envelope/clear"] = { intent = "clear envelope points in a time range", target_binding = "target/index/name/selected/selected_envelope", params = { "target", "lane", "start", "end", "time_selection" }, prefer_mcp_when = "automation cleanup", allow_script = false, risk = "destructive", verifier = "observed", repair = "require lane, explicit envelope target, and range or selected_envelope" },
    ["region/batch_rename"] = { intent = "batch rename regions", target_binding = "regions", params = { "search", "replace", "old_prefix", "new_prefix" }, prefer_mcp_when = "region naming batches", allow_script = false, risk = "batch_modify", verifier = "region/rename", repair = "require search/replace or prefix pair" },
    ["sfx/generate_variants"] = { intent = "generate game audio variants", target_binding = "created.items/created.tracks", params = { "count", "pitch_variation", "volume_variation", "name_pattern" }, prefer_mcp_when = "variant generation", allow_script = false, risk = "batch_modify", verifier = "item/create", repair = "bind later item edits to created.items" },
    ["analysis/detect_peaks"] = { intent = "detect audio peaks", target_binding = "selected item or target", params = { "threshold" }, prefer_mcp_when = "analysis request", allow_script = false, risk = "read_only", verifier = "observed", repair = "default threshold if omitted" },
    ["analysis/find_loop_points"] = { intent = "find loop points", target_binding = "selected item or target", params = { "track", "item", "search_start", "search_end" }, prefer_mcp_when = "loop analysis", allow_script = false, risk = "analysis_state", verifier = "observed", repair = "use selected item by default" },
    ["export/batch_regions"] = { intent = "export all regions", target_binding = "regions/filesystem", params = { "format(required, registry-backed)", "bitdepth(default 24)", "samplerate(default 48000)", "output_dir", "tail_ms" }, prefer_mcp_when = "batch render/export", allow_script = false, risk = "file_write", verifier = "file/export", repair = "confirm format; samplerate defaults to 48000 and bitdepth defaults to 24; output_dir defaults to next Mixdown_###" },
    ["export/tracks"] = { intent = "export tracks as stem files", target_binding = "tracks/filesystem", params = { "format(required, registry-backed)", "selected", "all", "bounds(auto time_selection/project)", "bitdepth(default 24)", "samplerate(default 48000)", "name_pattern", "output_dir" }, prefer_mcp_when = "track stem render/export", allow_script = false, risk = "file_write", verifier = "file/export", repair = "confirm format; selected=true for selected tracks, all=true for all tracks; samplerate defaults to 48000 and bitdepth defaults to 24; omit bounds to auto-use time selection when present, otherwise project; output_dir defaults to next Mixdown_###" },
    ["export/master"] = { intent = "export master mix", target_binding = "master/filesystem", params = { "format(required, registry-backed)", "bounds(auto time_selection/project)", "bitdepth(default 24)", "samplerate(default 48000)", "name_pattern", "output_dir" }, prefer_mcp_when = "master mix render/export", allow_script = false, risk = "file_write", verifier = "file/export", repair = "confirm format; samplerate defaults to 48000 and bitdepth defaults to 24; omit bounds to auto-use time selection when present, otherwise project; output_dir defaults to next Mixdown_###" },
    ["native/action"] = { intent = "run allowed native REAPER action", target_binding = "command_id/action/target_track/selected", params = { "command_id", "action", "mode", "target_track", "selected" }, prefer_mcp_when = "freeze, unfreeze, glue, or whitelisted action", allow_script = false, risk = "native_modify", verifier = "observed", repair = "resolve from native action inventory" },
    ["endpoints"] = { intent = "list MCP endpoints", target_binding = "system", params = {}, prefer_mcp_when = "capability discovery", allow_script = false, risk = "read_only", verifier = "observed", repair = "refresh endpoint snapshot" },
  }

  CAPABILITY_CARDS["region/delete"] = {
    intent = "delete regions",
    target_binding = "region id/range/name/all",
    params = { "index", "id", "region", "target", "range", "ids", "start", "end", "order_start", "order_end", "order_range", "name", "match", "all" },
    prefer_mcp_when = "Region deletion by displayed R id, id range, timeline order range, or name match",
    allow_script = false,
    risk = "destructive",
    verifier = "region/delete",
    repair = "ask when numeric range is ambiguous between R id and timeline order; never route Region deletion to marker/delete",
  }

  local function sorted_keys(map)
    local keys = {}
    for key, value in pairs(map or {}) do
      if type(value) == "table" then
        table.insert(keys, tostring(key))
      end
    end
    table.sort(keys)
    return keys
  end

  local function compact_effects(effects)
    if type(effects) ~= "table" then return nil end
    local ordered = {
      "read_only",
      "modifies_project",
      "deletes_project",
      "clears_project",
      "exports_file",
      "writes_disk",
      "batch",
      "changes_time_selection",
      "moves_cursor",
      "analysis_side_effect",
    }
    local flags = {}
    for _, key in ipairs(ordered) do
      if effects[key] then
        table.insert(flags, key)
      end
    end
    if #flags == 0 then return nil end
    return table.concat(flags, ",")
  end

  local function endpoint_line(endpoint, meta)
    meta = meta or {}
    local action = tostring(meta.kind or meta.action or "custom")
    local target = tostring(meta.target or "unknown")
    local label = trim(meta.label or meta.description or "")
    local parts = { "- " .. endpoint, "[" .. action .. "/" .. target .. "]" }
    if label ~= "" and label ~= endpoint then
      table.insert(parts, label)
    end
    local flags = {}
    if meta.allowed_in_script ~= nil then
      table.insert(flags, "script=" .. (meta.allowed_in_script and "yes" or "no"))
    end
    local effects = compact_effects(meta.effects)
    if effects then
      table.insert(flags, "effects=" .. effects)
    end
    if meta.verifier and meta.verifier ~= "" then
      local strength = tostring(meta.verifier_strength or "observed")
      table.insert(flags, "verifier=" .. tostring(meta.verifier) .. "(" .. strength .. ")")
    end
    if meta.source and meta.source ~= "" then
      table.insert(flags, "source=" .. tostring(meta.source))
    end
    if #flags > 0 then
      table.insert(parts, "{" .. table.concat(flags, ", ") .. "}")
    end
    return table.concat(parts, " ")
  end

  local function endpoint_directory(limit)
    local registry = type(Operation.action_registry_table) == "table" and Operation.action_registry_table or {}
    local keys = sorted_keys(registry)
    local total = #keys
    limit = tonumber(limit or 16) or 16
    local lines = { "mcp_endpoints (" .. tostring(total) .. "):" }
    for i = 1, math.min(total, limit) do
      local endpoint = keys[i]
      local meta = endpoint_meta(endpoint)
      if meta then
        table.insert(lines, endpoint_line(endpoint, meta))
      end
    end
    if total > limit then
      table.insert(lines, "- ... +" .. tostring(total - limit) .. " more")
    end
    return table.concat(lines, "\n")
  end

  local function card_line(card)
    card = card or {}
    local parts = { "- " .. tostring(card.endpoint or "") }
    if card.intent and card.intent ~= "" then table.insert(parts, "intent=" .. tostring(card.intent)) end
    if card.target_binding and card.target_binding ~= "" then table.insert(parts, "target=" .. tostring(card.target_binding)) end
    if type(card.params) == "table" and #card.params > 0 then table.insert(parts, "params=" .. table.concat(card.params, "/")) end
    if card.prefer_mcp_when and card.prefer_mcp_when ~= "" then table.insert(parts, "prefer=" .. tostring(card.prefer_mcp_when)) end
    if card.verifier and card.verifier ~= "" then table.insert(parts, "verify=" .. tostring(card.verifier)) end
    if card.repair and card.repair ~= "" then table.insert(parts, "repair=" .. tostring(card.repair)) end
    return table.concat(parts, "; ")
  end

  capability_card = function(endpoint)
    endpoint = trim(endpoint)
    if endpoint == "" then return nil end
    local card = CAPABILITY_CARDS[endpoint]
    local meta = endpoint_meta(endpoint)
    if not card and not meta then return nil end
    local out = {}
    if type(card) == "table" then
      for key, value in pairs(card) do out[key] = shallow_copy(value) end
    end
    out.endpoint = endpoint
    if meta then
      out.kind = out.kind or meta.kind
      out.target = out.target or meta.target
      out.verifier = out.verifier or meta.verifier
      out.risk = out.risk or compact_effects(meta.effects) or "unknown"
      out.allow_script = out.allow_script == true or meta.allowed_in_script == true
    end
    return out
  end

  cards_summary = function(limit)
    local registry = type(Operation.action_registry_table) == "table" and Operation.action_registry_table or {}
    limit = tonumber(limit or 18) or 18
    local lines = {}
    local seen = {}
    for _, endpoint in ipairs(CAPABILITY_CARD_ORDER) do
      if registry[endpoint] then
        local card = capability_card(endpoint)
        if card then
          table.insert(lines, card_line(card))
          seen[endpoint] = true
        end
        if #lines >= limit then break end
      end
    end
    if #lines < limit then
      local keys = sorted_keys(registry)
      for _, endpoint in ipairs(keys) do
        if not seen[endpoint] then
          local card = capability_card(endpoint)
          if card then
            table.insert(lines, card_line(card))
          end
          if #lines >= limit then break end
        end
      end
    end
    local total = #sorted_keys(registry)
    if total > #lines then
      table.insert(lines, "- ... +" .. tostring(total - #lines) .. " more capability cards")
    end
    return table.concat(lines, "\n")
  end

  local function build_endpoint_meta(endpoint, meta)
    meta = meta or {}
    local contract = meta.contract
    local kind = tostring(meta.kind or (contract and contract.action) or "custom")
    local target = tostring(meta.target or (contract and contract.target) or "unknown")
    return {
      endpoint = endpoint,
      kind = kind,
      target = target,
      label = meta.label or (contract and contract.label) or endpoint,
      description = meta.description or meta.desc or meta.label or endpoint,
      params = shallow_copy(meta.params or {}),
      example = meta.example,
      effects = shallow_copy(meta.effects or (contract and contract.effects) or {}),
      verifier = meta.verifier or (contract and contract.verifier),
      verifier_strength = meta.verifier_strength or (contract and contract.verifier_strength) or "observed",
      source = meta.source or "mcp_server_endpoints",
      allowed_in_script = meta.allowed_in_script == true or (contract and contract.allowed_in_script == true) or false,
      capability_card = CAPABILITY_CARDS[endpoint],
      operation = contract,
    }
  end

  endpoint_meta = function(endpoint)
    endpoint = trim(endpoint)
    if endpoint == "" then return nil end
    if endpoint_cache[endpoint] then return endpoint_cache[endpoint] end
    local meta = nil
    if Operation and type(Operation.action_registry_table) == "table" then
      local entry = Operation.action_registry_table[endpoint]
      if entry then
        meta = {
          endpoint = endpoint,
          kind = entry.action,
          target = entry.target,
          label = entry.label,
          description = entry.label,
          params = {},
          example = nil,
          effects = entry.effects or {},
          verifier = entry.verifier,
          verifier_strength = entry.verifier_strength,
          source = entry.source or "operation_action_registry",
          allowed_in_script = entry.allowed_in_script == true,
          contract = {
            endpoint = endpoint,
            action = entry.action,
            target = entry.target,
            label = entry.label,
            effects = entry.effects or {},
            verifier = entry.verifier,
            verifier_strength = entry.verifier_strength,
            allowed_in_script = entry.allowed_in_script == true,
            source = entry.source or "operation_action_registry",
          },
        }
      end
    end
    if not meta then return nil end
    endpoint_cache[endpoint] = build_endpoint_meta(endpoint, meta)
    return endpoint_cache[endpoint]
  end

  local function known_mcp_endpoint(endpoint)
    endpoint = trim(endpoint)
    if endpoint == "" then return nil end
    if Operation and type(Operation.action_registry_table) == "table" then
      return Operation.action_registry_table[endpoint] ~= nil
    end
    return false
  end

  local function native_action_entry(id)
    id = trim(id)
    if id == "" then return nil end
    if native_cache[id] then return native_cache[id] end
    local entry = nil
    if ReaperCapabilities and type(ReaperCapabilities.action_entry) == "function" then
      entry = ReaperCapabilities.action_entry(id)
    end
    if entry then
      native_cache[id] = shallow_copy(entry)
    end
    return native_cache[id]
  end

  local function generated_reference(registry, ref_name)
    if not GeneratedRegistry or type(GeneratedRegistry.resolve_reference) ~= "function" then
      return nil
    end
    return GeneratedRegistry.resolve_reference(registry, ref_name)
  end

  local function registry_summary(op, limit)
    local lines = {}
    local card_text = cards_summary(limit or 18)
    if card_text and card_text ~= "" then
      table.insert(lines, "capability_cards:")
      table.insert(lines, card_text)
    end
    local directory_text = endpoint_directory(limit or 16)
    if directory_text and directory_text ~= "" then
      table.insert(lines, directory_text)
    end
    local generated = op and op.generated_registry or nil
    if GeneratedRegistry and type(GeneratedRegistry.summary) == "function" then
      local generated_text = GeneratedRegistry.summary(generated, limit or 12)
      if generated_text and generated_text ~= "" and generated_text ~= "none" then
        table.insert(lines, "generated_objects:")
        table.insert(lines, generated_text)
      end
    end
    if ReaperCapabilities and type(ReaperCapabilities.summary_for_prompt) == "function" then
      local capability_text = ReaperCapabilities.summary_for_prompt()
      if capability_text and capability_text ~= "" then
        table.insert(lines, "runtime_capabilities:")
        table.insert(lines, capability_text)
      end
    end
    return table.concat(lines, "\n")
  end

  function M.endpoint_meta(endpoint)
    return endpoint_meta(endpoint)
  end

  function M.known_mcp_endpoint(endpoint)
    return known_mcp_endpoint(endpoint)
  end

  function M.native_action_entry(id)
    return native_action_entry(id)
  end

  function M.generated_reference(registry, ref_name)
    return generated_reference(registry, ref_name)
  end

  function M.capability_card(endpoint)
    return capability_card(endpoint)
  end

  function M.cards_summary(limit)
    return cards_summary(limit)
  end

  function M.registry_summary(op, limit)
    return registry_summary(op, limit)
  end

  function M.action_contract(endpoint)
    return Operation and type(Operation.action_contract) == "function" and Operation.action_contract(endpoint) or nil
  end

  return M
end

return CapabilityRegistry
