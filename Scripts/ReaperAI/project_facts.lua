-- Deterministic project-fact preflight for operation cards.
-- This layer catches impossible or underspecified targets before execution or auto repair.

local ProjectFacts = {}

function ProjectFacts.create(deps)
  deps = deps or {}
  local Operation = deps.Operation
  local RuntimeState = deps.RuntimeState
  if not Operation then error("ProjectFacts requires Operation", 0) end
  if not RuntimeState then error("ProjectFacts requires RuntimeState", 0) end

  local M = {}

  local TRACK_ENDPOINTS = {
    ["track/delete"] = true,
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

  local ITEM_ENDPOINTS = {
    ["item/fade"] = true,
    ["item/set_fade"] = true,
    ["item/fade_shape"] = true,
    ["item/set_fade_shape"] = true,
    ["item/delete"] = true,
    ["item/property"] = true,
  }

  local function trim(value)
    return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
  end

  local function lower(value)
    return trim(value):lower()
  end

  local function truthy(value)
    value = lower(value)
    return value == "true" or value == "1" or value == "yes" or value == "on" or value == "selected"
  end

  local function has_value(params, keys)
    params = params or {}
    for _, key in ipairs(keys or {}) do
      local value = trim(params[key])
      if value ~= "" then return true, key, value end
    end
    return false, nil, nil
  end

  local function created_ref(value, plural)
    value = lower(value):gsub("%s+", "")
    plural = tostring(plural or "")
    if value == "" then return nil end
    local singular = plural:gsub("s$", "")
    local patterns = {
      "^created%." .. plural .. "%[(%d+)%]$",
      "^generated%." .. plural .. "%[(%d+)%]$",
      "^created:" .. plural .. ":(%d+)$",
      "^created:" .. singular .. ":(%d+)$",
      "^generated:" .. plural .. ":(%d+)$",
      "^generated:" .. singular .. ":(%d+)$",
    }
    for _, pattern in ipairs(patterns) do
      local index = value:match(pattern)
      if index then return tonumber(index) end
    end
    return nil
  end

  local function split_list(value)
    value = tostring(value or ""):gsub("\239\188\140", ","):gsub("，", ","):gsub("|", ","):gsub(";", ",")
    local result = {}
    for part in value:gmatch("[^,]+") do
      part = trim(part)
      if part ~= "" then table.insert(result, part) end
    end
    return result
  end

  local function add_range_ids(result, a, b)
    a = tonumber(a)
    b = tonumber(b)
    if not a or not b then return end
    a = math.floor(a)
    b = math.floor(b)
    local lo = math.min(a, b)
    local hi = math.max(a, b)
    for id = lo, hi do result[id] = true end
  end

  local function parse_id_set(value)
    local ids = {}
    value = tostring(value or "")
    value = value:gsub("[Rr]egion", ""):gsub("[Rr]", "")
    local a, b = value:match("(%-?%d+)%s*[%-%~:]%s*(%-?%d+)")
    if a and b then add_range_ids(ids, a, b) end
    for _, part in ipairs(split_list(value)) do
      local x, y = part:match("^(%-?%d+)%s*[%-%~:]%s*(%-?%d+)$")
      if x and y then
        add_range_ids(ids, x, y)
      else
        local n = tonumber(part)
        if n then ids[math.floor(n)] = true end
      end
    end
    return ids
  end

  local function id_set_count(ids)
    local count = 0
    for _ in pairs(ids or {}) do count = count + 1 end
    return count
  end

  local function list_has_number(list, number)
    number = tonumber(number)
    if not number then return false end
    for _, value in ipairs(list or {}) do
      if tonumber(value) == number then return true end
    end
    return false
  end

  local function name_count(snapshot, kind, name, partial)
    snapshot = snapshot or {}
    name = trim(name)
    if name == "" then return nil end
    local map = snapshot[tostring(kind or "") .. "_name_counts"] or {}
    if not partial then return tonumber(map[name] or 0) or 0 end
    local needle = name:lower()
    local count = 0
    for existing, existing_count in pairs(map) do
      existing = tostring(existing or "")
      if existing == name or existing:lower():find(needle, 1, true) then
        count = count + (tonumber(existing_count) or 0)
      end
    end
    return count
  end

  local function add_fact_question(op, question)
    if not op or not question then return end
    op.project_fact_questions = op.project_fact_questions or {}
    table.insert(op.project_fact_questions, question)
  end

  local function fact_question(step_index, endpoint, question, reason, opts)
    opts = opts or {}
    return {
      step_index = step_index,
      endpoint = endpoint,
      question = question,
      options = opts.options or {},
      notes = opts.notes or {},
      fields = opts.fields or { "target" },
      free_input = opts.free_input ~= false,
      placeholder = opts.placeholder or "",
      reason = reason or question,
      project_fact = true,
    }
  end

  local function first_track_target(endpoint, params)
    params = params or {}
    if truthy(params.selected) then return "selected", "selected" end
    if truthy(params.all) then return "all", "all" end
    local keys
    if endpoint == "track/rename" then
      keys = { "target", "old_name", "from", "track_name", "track", "index", "name" }
    elseif endpoint == "track/add_fx" or endpoint == "track/remove_fx" then
      keys = { "target", "track", "track_name", "index", "name" }
    else
      keys = { "target", "track", "track_name", "name", "index" }
    end
    local _, key, value = has_value(params, keys)
    return key, value
  end

  local function planned_track_names_from_create(params)
    params = params or {}
    local names = split_list(params.names or params.track_names or "")
    if #names > 0 then return names end
    local count = tonumber(params.count or "") or 1
    local base = trim(params.name or "")
    if base == "" then return names end
    for i = 1, math.max(1, count) do
      table.insert(names, count > 1 and (base .. " " .. tostring(i)) or base)
    end
    return names
  end

  local function planned_name_exists(planned_names, name)
    name = lower(name)
    if name == "" then return false end
    for _, planned in ipairs(planned_names or {}) do
      local p = lower(planned)
      if p == name or p:find(name, 1, true) then return true end
    end
    return false
  end

  local function validate_track_step(op, step, step_index, endpoint, params, snapshot, future_track_count, planned_track_names, planned_track_count)
    if endpoint == "track/create" then return end
    if not TRACK_ENDPOINTS[endpoint] then return end
    local key, value = first_track_target(endpoint, params)
    if key == "all" then
      if (snapshot.track_count or 0) <= 0 then
        add_fact_question(op, fact_question(step_index, endpoint, "当前工程没有轨道，不能执行这个轨道操作。", "no tracks in project", {
          fields = { "track_target" },
          placeholder = "请先创建轨道，或取消这次操作",
        }))
      end
      return
    end
    if key == "selected" then
      if (snapshot.selected_track_count or 0) <= 0 then
        add_fact_question(op, fact_question(step_index, endpoint, "当前没有选中的轨道，但计划要操作 selected 轨道。请先选择轨道，或说明具体轨道名。", "selected track target is empty", {
          fields = { "track_target" },
          placeholder = "输入轨道名，或先在 REAPER 里选中轨道",
        }))
      end
      return
    end
    if not value or value == "" then return end
    local ref_index = created_ref(value, "tracks")
    if ref_index then
      if ref_index > (planned_track_count or 0) then
        add_fact_question(op, fact_question(step_index, endpoint, "计划引用了 created.tracks[" .. tostring(ref_index) .. "]，但前面只计划创建 " .. tostring(planned_track_count or 0) .. " 条轨道。请确认目标轨道。", "created track reference out of range", {
          fields = { "track_target" },
          placeholder = "输入 created.tracks[N]、轨道名，或选择目标轨道",
        }))
      end
      return
    end
    local numeric = tonumber(value)
    if numeric then
      if numeric < 0 or numeric >= (future_track_count or snapshot.track_count or 0) then
        add_fact_question(op, fact_question(step_index, endpoint, "计划要操作的轨道索引不存在。当前工程只有 " .. tostring(snapshot.track_count or 0) .. " 条轨道。", "track index out of range", {
          fields = { "track_index" },
          placeholder = "输入存在的轨道编号或轨道名",
        }))
      end
      return
    end
    if name_count(snapshot, "track", value, true) <= 0 and not planned_name_exists(planned_track_names, value) then
      add_fact_question(op, fact_question(step_index, endpoint, "当前工程里没找到轨道：" .. tostring(value) .. "。请确认轨道名，或先创建这条轨道。", "track target not found", {
        fields = { "track_name" },
        placeholder = "输入真实存在的轨道名",
      }))
    end
  end

  local function validate_item_step(op, step_index, endpoint, params, snapshot, planned_item_count)
    if not ITEM_ENDPOINTS[endpoint] then return end
    local target = trim(params.target or params.item or params.index or "")
    if truthy(params.all) then
      if (snapshot.item_count or 0) <= 0 then
        add_fact_question(op, fact_question(step_index, endpoint, "当前工程没有 item，不能执行这个 item 操作。", "no items in project", {
          fields = { "item_target" },
          placeholder = "请先添加素材，或取消这次操作",
        }))
      end
      return
    end
    if truthy(params.selected) or lower(target) == "selected" or lower(target) == "selection" then
      if (snapshot.selected_item_count or 0) <= 0 then
        add_fact_question(op, fact_question(step_index, endpoint, "当前没有选中的 item，但计划要操作选中 item。请先选中素材，或说明具体 item。", "selected item target is empty", {
          fields = { "item_target" },
          placeholder = "选中素材，或输入 item 名称/编号",
        }))
      end
      return
    end
    if target == "" then return end
    local ref_index = created_ref(target, "items")
    if ref_index then
      if ref_index > (planned_item_count or 0) then
        add_fact_question(op, fact_question(step_index, endpoint, "计划引用了 created.items[" .. tostring(ref_index) .. "]，但前面没有足够的 item 生成步骤。请确认素材目标。", "created item reference out of range", {
          fields = { "item_target" },
          placeholder = "输入 created.items[N]、item 名称，或选中素材",
        }))
      end
      return
    end
    local numeric = tonumber(target)
    if numeric and (numeric < 0 or numeric >= (snapshot.item_count or 0)) then
      add_fact_question(op, fact_question(step_index, endpoint, "计划要操作的 item 索引不存在。当前工程只有 " .. tostring(snapshot.item_count or 0) .. " 个 item。", "item index out of range", {
        fields = { "item_index" },
        placeholder = "输入存在的 item 编号，或选中素材",
      }))
    elseif not numeric and name_count(snapshot, "item", target, true) <= 0 then
      add_fact_question(op, fact_question(step_index, endpoint, "当前工程里没找到 item：" .. tostring(target) .. "。请确认名称，或先选中要处理的素材。", "item target not found", {
        fields = { "item_target" },
        placeholder = "输入真实 item 名称，或选中素材",
      }))
    end
  end

  local function validate_marker_delete(op, step_index, endpoint, params, snapshot)
    if endpoint ~= "marker/delete" then return end
    if (snapshot.marker_count or 0) <= 0 then
      add_fact_question(op, fact_question(step_index, endpoint, "当前工程没有 Marker，不能删除 Marker。", "no markers in project", {
        fields = { "marker_target" },
        placeholder = "请先创建 Marker，或取消这次操作",
      }))
      return
    end
    local target = trim(params.index or params.marker or params.target or "")
    if target == "" then return end
    local id = tonumber(target)
    if id and not list_has_number(snapshot.marker_indices, id) then
      add_fact_question(op, fact_question(step_index, endpoint, "当前工程里没有 Marker " .. tostring(id) .. "。请确认 Marker 编号。", "marker id not found", {
        fields = { "marker_index" },
        placeholder = "输入存在的 Marker 编号",
      }))
    end
  end

  local function validate_region_step(op, step_index, endpoint, params, snapshot)
    if endpoint ~= "region/delete" and endpoint ~= "region/batch_rename" and endpoint ~= "export/batch_regions" then return end
    if (snapshot.region_count or 0) <= 0 then
      add_fact_question(op, fact_question(step_index, endpoint, "当前工程没有 Region，不能执行这个 Region 操作。", "no regions in project", {
        fields = { "region_target" },
        placeholder = "请先创建 Region，或取消这次操作",
      }))
      return
    end
    if endpoint ~= "region/delete" then return end

    local name = trim(params.name or params.match or "")
    if name ~= "" and name_count(snapshot, "region", name, true) <= 0 then
      add_fact_question(op, fact_question(step_index, endpoint, "当前工程里没找到名称匹配的 Region：" .. tostring(name) .. "。请确认 Region 名称。", "region name not found", {
        fields = { "region_name" },
        placeholder = "输入真实存在的 Region 名称",
      }))
      return
    end

    local order_ids = parse_id_set(params.order_range or params.ordinal_range or params.sequence_range or params.order or params.ordinal or params.sequence or "")
    if trim(params.order_start or params.ordinal_start or params.sequence_start) ~= "" or trim(params.order_end or params.ordinal_end or params.sequence_end) ~= "" then
      add_range_ids(order_ids, params.order_start or params.ordinal_start or params.sequence_start, params.order_end or params.ordinal_end or params.sequence_end)
    end
    for order_index in pairs(order_ids) do
      if order_index < 1 or order_index > (snapshot.region_count or 0) then
        add_fact_question(op, fact_question(step_index, endpoint, "当前只有 " .. tostring(snapshot.region_count or 0) .. " 个 Region，不能按时间线顺序操作第 " .. tostring(order_index) .. " 个 Region。", "region timeline order out of range", {
          fields = { "region_order" },
          placeholder = "输入 1-" .. tostring(snapshot.region_count or 0) .. " 范围内的顺序",
        }))
        return
      end
    end

    local ids = parse_id_set(params.range or params.ids or params.index or params.id or params.region or params.target or "")
    if trim(params.start or params.from) ~= "" or trim(params["end"] or params.to) ~= "" then
      add_range_ids(ids, params.start or params.from, params["end"] or params.to)
    end
    if id_set_count(ids) > 0 then
      for id in pairs(ids) do
        if not list_has_number(snapshot.region_indices, id) then
          add_fact_question(op, fact_question(step_index, endpoint, "当前工程里没有 R" .. tostring(id) .. "。请确认是按 Region 编号删除，还是按时间线顺序删除。", "region id not found", {
            options = { "按时间线顺序重新指定", "重新输入 Region 编号" },
            fields = { "region_target" },
            placeholder = "例如：按时间线第1-3个，或 R15-R20",
          }))
          return
        end
      end
    end
  end

  local function validate_analysis_step(op, step_index, endpoint, params, snapshot)
    if endpoint ~= "analysis/find_loop_points" then return end
    local has_file = trim(params.file or params.path or params.source or "") ~= ""
    local wants_selected = truthy(params.selected) or lower(params.item or params.target or "") == "selected"
    local has_named_target = trim(params.item or params.target or params.index or "") ~= "" and not wants_selected
    local selected_count = snapshot.selected_item_count or 0
    if wants_selected and selected_count <= 0 then
      add_fact_question(op, fact_question(step_index, endpoint, "当前没有选中的音频 item，无法直接分析 loop 点。请先选中一段音频，或说明要分析哪个素材。", "loop analysis selected item is empty", {
        fields = { "audio_item" },
        placeholder = "先选中音频素材，或输入素材名称/编号",
      }))
    elseif not has_file and not has_named_target and selected_count <= 0 then
      add_fact_question(op, fact_question(step_index, endpoint, "当前没有选中的音频 item，无法直接分析 loop 点。请先选中一段音频，或说明要分析哪个素材。", "loop analysis has no selected item", {
        fields = { "audio_item" },
        placeholder = "先选中音频素材，或输入素材名称/编号",
      }))
    end
  end

  local function validate_envelope_step(op, step_index, endpoint, params, snapshot)
    if endpoint ~= "envelope/draw" and endpoint ~= "envelope/clear" then return end
    local target = lower(params.target or params.scope or "")
    local item_target = lower(params.item or params.item_name or "")
    local track_target = trim(params.track or params.track_name or params.name or "")
    local wants_selected_envelope = target == "selected_envelope" or target == "selected envelope"
    if wants_selected_envelope then
      local env = reaper.GetSelectedEnvelope and reaper.GetSelectedEnvelope(0) or nil
      if not env then
        add_fact_question(op, fact_question(step_index, endpoint, "当前没有选中的 envelope，但计划要操作 selected envelope。请先选中包络，或说明轨道/素材目标。", "selected envelope target is empty", {
          fields = { "envelope_target" },
          placeholder = "选中 envelope，或输入轨道/素材目标",
        }))
      end
      return
    end
    if target == "selected" or target == "selection" or item_target == "selected" then
      if (snapshot.selected_item_count or 0) <= 0 and (snapshot.selected_track_count or 0) <= 0 then
        add_fact_question(op, fact_question(step_index, endpoint, "当前没有选中的轨道或 item，但计划要操作 selected envelope。请先选择目标，或说明具体轨道/素材。", "selected envelope owner is empty", {
          fields = { "envelope_target" },
          placeholder = "选中轨道/item，或输入目标名称",
        }))
      end
      return
    end
    if track_target ~= "" and tonumber(track_target) == nil and not created_ref(track_target, "tracks") and name_count(snapshot, "track", track_target, true) <= 0 then
      add_fact_question(op, fact_question(step_index, endpoint, "当前工程里没找到 envelope 所属轨道：" .. tostring(track_target) .. "。请确认轨道名。", "envelope track target not found", {
        fields = { "track_name" },
        placeholder = "输入真实存在的轨道名",
      }))
    end
  end

  local function validate_marker_region_contract(op, step_index, endpoint, params, snapshot)
    if endpoint ~= "marker_region/delete" and endpoint ~= "marker_region/edit" then return end
    if (snapshot.marker_count or 0) <= 0 and (snapshot.region_count or 0) <= 0 then
      add_fact_question(op, fact_question(step_index, endpoint, "当前工程没有 Marker 或 Region，不能执行这个 Marker/Region 操作。", "no markers or regions in project", {
        fields = { "marker_region_target" },
        placeholder = "请先创建 Marker/Region，或取消这次操作",
      }))
    end
  end

  local function script_fact_contract(step)
    if not step or step.kind ~= "script" then return nil end
    if type(step.script_fact_contract) == "table" then
      return step.script_fact_contract
    end
    if Operation and type(Operation.script_fact_contract) == "function" then
      local ok, contract = pcall(Operation.script_fact_contract, step.code or "")
      if ok and type(contract) == "table" then
        step.script_fact_contract = contract
        return contract
      end
    end
    return nil
  end

  local function validate_script_step(op, step, step_index, snapshot, future_track_count, planned_track_names, planned_track_count, planned_item_count)
    local contract = script_fact_contract(step)
    if not contract then return end
    local endpoint = tostring(contract.endpoint or "")
    local params = contract.params or {}
    if endpoint == "" or endpoint == "SCRIPT" then
      if contract.opaque_side_effect then
        op.risk_reasons = op.risk_reasons or {}
        Operation.add_unique(op.risk_reasons, "SCRIPT has opaque side effects; using confirmation plus before/after verification where possible")
      end
      return
    end

    validate_track_step(op, step, step_index, endpoint, params, snapshot, future_track_count, planned_track_names, planned_track_count)
    validate_item_step(op, step_index, endpoint, params, snapshot, planned_item_count)
    validate_marker_delete(op, step_index, endpoint, params, snapshot)
    validate_region_step(op, step_index, endpoint, params, snapshot)
    validate_analysis_step(op, step_index, endpoint, params, snapshot)
    validate_envelope_step(op, step_index, endpoint, params, snapshot)
    validate_marker_region_contract(op, step_index, endpoint, params, snapshot)
  end

  local function apply_questions(op)
    local questions = op.project_fact_questions or {}
    if #questions == 0 then return false end
    op.needs_clarification = true
    op.contract_status = "needs_clarification"
    op.risk = "needs_clarification"
    op.preflight_ok = false
    op.project_fact_blocked = true
    op.clarification_questions = op.clarification_questions or {}
    for i = #questions, 1, -1 do
      table.insert(op.clarification_questions, 1, questions[i])
    end
    local first = op.clarification_questions[1]
    op.clarification_prompt = first and first.question or op.clarification_prompt
    op.clarification_options = first and first.options or op.clarification_options or {}
    op.risk_reasons = op.risk_reasons or {}
    table.insert(op.risk_reasons, 1, "工程事实预检发现目标不存在或上下文不足")
    return true
  end

  local function registry_count(op, bucket)
    local registry = op and op.generated_registry or nil
    local list = registry and registry[bucket] or nil
    return type(list) == "table" and #list or 0
  end

  local function operation_has_blocked_steps(op)
    for _, step in ipairs((op and op.parts) or {}) do
      if step.status == "blocked" or step.precheck_error or step.blocked_reason then
        return true
      end
    end
    return false
  end

  local function remove_project_fact_reason(op)
    if type(op) ~= "table" or type(op.risk_reasons) ~= "table" then return end
    local kept = {}
    for _, reason in ipairs(op.risk_reasons) do
      if reason ~= "工程事实预检发现目标不存在或上下文不足" then
        table.insert(kept, reason)
      end
    end
    op.risk_reasons = kept
  end

  function M.apply_preflight(op)
    if type(op) ~= "table" or type(op.parts) ~= "table" then return op end
    op.project_fact_questions = {}
    local had_project_fact_block = op.project_fact_blocked == true
    if type(op.clarification_questions) == "table" then
      local kept = {}
      for _, question in ipairs(op.clarification_questions) do
        if not (type(question) == "table" and question.project_fact == true) then
          table.insert(kept, question)
        end
      end
      op.clarification_questions = kept
    end
    if had_project_fact_block then
      op.project_fact_blocked = false
      remove_project_fact_reason(op)
      if not op.clarification_questions or #op.clarification_questions == 0 then
        op.needs_clarification = false
        if not operation_has_blocked_steps(op) then
          op.preflight_ok = true
          op.contract_status = "executable"
          if op.risk == "needs_clarification" then
            op.risk = "medium"
          end
        end
      end
    end
    local snapshot = RuntimeState.capture_project_snapshot()
    op.project_fact_snapshot = {
      track_count = snapshot.track_count or 0,
      item_count = snapshot.item_count or 0,
      selected_track_count = snapshot.selected_track_count or 0,
      selected_item_count = snapshot.selected_item_count or 0,
      marker_count = snapshot.marker_count or 0,
      region_count = snapshot.region_count or 0,
    }
    local future_track_count = snapshot.track_count or 0
    local planned_track_count = registry_count(op, "tracks")
    local planned_item_count = registry_count(op, "items")
    local planned_track_names = {}
    for step_index, step in ipairs(op.parts or {}) do
      if step.kind == "mcp" then
        local endpoint, params = Operation.parse_call(step.call or "")
        if endpoint == "track/create" then
          local count = tonumber(params.count or "") or math.max(1, #split_list(params.names or params.track_names or ""))
          future_track_count = future_track_count + math.max(1, count)
          planned_track_count = planned_track_count + math.max(1, count)
          for _, name in ipairs(planned_track_names_from_create(params)) do
            table.insert(planned_track_names, name)
          end
        elseif endpoint == "sfx/generate_variants" then
          planned_item_count = planned_item_count + math.max(1, tonumber(params.variants or params.variant_count or params.count or "") or 1)
        end
        validate_track_step(op, step, step_index, endpoint, params, snapshot, future_track_count, planned_track_names, planned_track_count)
        validate_item_step(op, step_index, endpoint, params, snapshot, planned_item_count)
        validate_marker_delete(op, step_index, endpoint, params, snapshot)
        validate_region_step(op, step_index, endpoint, params, snapshot)
        validate_analysis_step(op, step_index, endpoint, params, snapshot)
        validate_envelope_step(op, step_index, endpoint, params, snapshot)
      elseif step.kind == "script" then
        local contract = script_fact_contract(step)
        if contract then
          local endpoint = tostring(contract.endpoint or "")
          local planned_count = math.max(1, tonumber(contract.planned_count or (contract.params or {}).count or "") or 1)
          if endpoint == "track/create" then
            future_track_count = future_track_count + planned_count
            planned_track_count = planned_track_count + planned_count
          elseif endpoint == "item/create" then
            planned_item_count = planned_item_count + planned_count
          end
        end
        validate_script_step(op, step, step_index, snapshot, future_track_count, planned_track_names, planned_track_count, planned_item_count)
      end
    end
    apply_questions(op)
    return op
  end

  return M
end

return ProjectFacts
