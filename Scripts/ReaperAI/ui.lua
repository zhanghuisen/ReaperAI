local UI = {}

local function callbacks(ctx)
  return (ctx and ctx.callbacks) or {}
end

local function invoke(ctx, name, ...)
  local cb = callbacks(ctx)
  local fn = cb[name]
  if type(fn) == "function" then
    return fn(...)
  end
  return nil, "UI callback missing: " .. tostring(name)
end

local input_text_mode = nil
local input_text_multiline_mode = nil

local function input_text(ctx, label, value, flags)
  value = tostring(value or "")
  flags = flags or 0

  if input_text_mode == "flags4" then
    return reaper.ImGui_InputText(ctx, label, value, flags)
  elseif input_text_mode == "plain3" then
    return reaper.ImGui_InputText(ctx, label, value)
  end

  local ok, changed, new_value = pcall(reaper.ImGui_InputText, ctx, label, value, flags)
  if ok then
    input_text_mode = "flags4"
    return changed, new_value
  end

  local ok_plain, changed_plain, new_plain = pcall(reaper.ImGui_InputText, ctx, label, value)
  if ok_plain then
    input_text_mode = "plain3"
    return changed_plain, new_plain
  end

  error(changed, 0)
end

local function input_text_multiline(ctx, label, value, width, height, flags)
  value = tostring(value or "")
  width = tonumber(width) or 0
  height = tonumber(height) or 0
  flags = flags or 0

  if not reaper.ImGui_InputTextMultiline then
    reaper.ImGui_PushItemWidth(ctx, width)
    local changed, new_value = input_text(ctx, label, value, flags)
    reaper.ImGui_PopItemWidth(ctx)
    return changed, new_value
  end

  if input_text_multiline_mode == "flags6" then
    return reaper.ImGui_InputTextMultiline(ctx, label, value, width, height, flags)
  elseif input_text_multiline_mode == "plain5" then
    return reaper.ImGui_InputTextMultiline(ctx, label, value, width, height)
  end

  local ok, changed, new_value = pcall(reaper.ImGui_InputTextMultiline, ctx, label, value, width, height, flags)
  if ok then
    input_text_multiline_mode = "flags6"
    return changed, new_value
  end

  local ok_plain, changed_plain, new_plain = pcall(reaper.ImGui_InputTextMultiline, ctx, label, value, width, height)
  if ok_plain then
    input_text_multiline_mode = "plain5"
    return changed_plain, new_plain
  end

  error(changed, 0)
end

local function begin_combo(ctx, label, preview)
  if not reaper.ImGui_BeginCombo then return false end
  local ok, result = pcall(reaper.ImGui_BeginCombo, ctx, label, preview or "")
  return ok and result == true
end

local function end_combo(ctx)
  if reaper.ImGui_EndCombo then pcall(reaper.ImGui_EndCombo, ctx) end
end

local function selectable(ctx, label, selected)
  if not reaper.ImGui_Selectable then return false end
  local ok, result = pcall(reaper.ImGui_Selectable, ctx, label, selected == true)
  return ok and result == true
end

local function open_popup(ctx, name)
  if reaper.ImGui_OpenPopup then
    pcall(reaper.ImGui_OpenPopup, ctx, name)
  end
end

local function begin_popup(ctx, name)
  if not reaper.ImGui_BeginPopup then return false end
  local ok, result = pcall(reaper.ImGui_BeginPopup, ctx, name)
  return ok and result == true
end

local function end_popup(ctx)
  if reaper.ImGui_EndPopup then pcall(reaper.ImGui_EndPopup, ctx) end
end

local function close_current_popup(ctx)
  if reaper.ImGui_CloseCurrentPopup then pcall(reaper.ImGui_CloseCurrentPopup, ctx) end
end

local function clarification_option_needs_text(option)
  local text = tostring(option or "")
  local lower = text:lower()
  return text:find("其他", 1, true) ~= nil
    or text:find("自定义", 1, true) ~= nil
    or text:find("具体说明", 1, true) ~= nil
    or text:find("请说明", 1, true) ~= nil
    or lower:find("other", 1, true) ~= nil
    or lower:find("custom", 1, true) ~= nil
    or lower:find("specify", 1, true) ~= nil
    or lower:find("describe", 1, true) ~= nil
    or lower:find("freeform", 1, true) ~= nil
end

local function clarification_option_is_hint(option)
  local text = tostring(option or "")
  local lower = text:lower()
  if text:find("你可以", 1, true) or text:find("例如", 1, true) or text:find("比如", 1, true) then return true end
  if text:find("举例", 1, true) or text:find("示例", 1, true) or text:find("类似", 1, true) then return true end
  if text:find("如 ", 1, true) or text:find("如：", 1, true) or text:find("如:", 1, true) then return true end
  if text:find("请说明", 1, true) or text:find("请描述", 1, true) or text:find("请具体", 1, true) then return true end
  if text:find("请提供", 1, true) or text:find("等）", 1, true) or text:find("等等", 1, true) then return true end
  if lower:find("for example", 1, true) or lower:find("e.g.", 1, true) or lower:find("such as", 1, true) then return true end
  if lower:find("please provide", 1, true) or lower:find("please specify", 1, true) then return true end
  if #text > 72 then return true end
  if #text > 54 and (text:find("（", 1, true) or text:find("(", 1, true) or text:find("，", 1, true) or text:find(",", 1, true) or text:find(" or ", 1, true)) then return true end
  return false
end

local function clarification_option_is_discardable(option)
  local text = tostring(option or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local compact = text:gsub("%s+", "")
  local lower = compact:lower()
  if compact == "" then return true end
  if compact:match("^[%.]+$") or compact:match("^[…]+$") then return true end
  if compact == "..." or compact == "……" or lower == "etc" or lower == "etc." then return true end
  return false
end

local function clarification_input_hint(question, fields, hint_option)
  if hint_option and hint_option ~= "" then return tostring(hint_option) end
  return ""
end

local function clarification_confirm_label(fields, question)
  local q = tostring(question or "")
  for _, field in ipairs(fields or {}) do
    local f = tostring(field or ""):lower()
    if f == "format" or f == "export_format" or f == "file_format" then return "使用此格式" end
    if f == "new_name" or f == "name" or f == "target_name" then return "使用此名称" end
    if f == "action_type" or f == "operation_type" then return "确认这个处理" end
  end
  if q:find("item", 1, true) or q:find("素材", 1, true) or q:find("处理", 1, true) then return "确认这个处理" end
  if q:find("导出", 1, true) or q:find("格式", 1, true) then return "使用此格式" end
  if q:find("名字", 1, true) or q:find("命名", 1, true) then return "使用此名称" end
  return "确认说明"
end

local function clarification_control_width(ctx)
  local available = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  return math.max(156, math.min(260, available - 8))
end

local function clarification_button_label(option)
  local text = tostring(option or "")
  local label = text:gsub("%s*（.*$", ""):gsub("%s*%(.+$", ""):gsub("^%s+", ""):gsub("%s+$", "")
  if label == "" then label = text end
  return label
end

function UI.render_settings(ctx)
  local state = ctx.state
  local config = ctx.config

  reaper.ImGui_Text(state.ctx, "配置")
  reaper.ImGui_Separator(state.ctx)

  local available_w = select(1, reaper.ImGui_GetContentRegionAvail(state.ctx))
  local field_w = math.max(260, math.min(560, available_w - 20))
  local key_field_w = math.max(200, field_w - 76)
  local label_color = 0x9AA7B7FF
  local status_muted = 0x888888FF
  local password_flags = 0
  if reaper.ImGui_InputTextFlags_Password then
    password_flags = reaper.ImGui_InputTextFlags_Password()
  end

  local function section_title(text)
    reaper.ImGui_Spacing(state.ctx)
    reaper.ImGui_Text(state.ctx, text)
    reaper.ImGui_Separator(state.ctx)
    reaper.ImGui_Spacing(state.ctx)
  end

  local function field_label(text)
    reaper.ImGui_TextColored(state.ctx, label_color, text)
  end

  local function text_field(label, id, value)
    field_label(label)
    reaper.ImGui_PushItemWidth(state.ctx, field_w)
    local changed, new_value = input_text(state.ctx, "##" .. id, value or "", 0)
    reaper.ImGui_PopItemWidth(state.ctx)
    return changed, new_value
  end

  local function key_field(label, id, value, visible_state_name)
    field_label(label)
    reaper.ImGui_PushItemWidth(state.ctx, key_field_w)
    local flags = state[visible_state_name] and 0 or password_flags
    local changed, new_value = input_text(state.ctx, "##" .. id, value or "", flags)
    reaper.ImGui_PopItemWidth(state.ctx)
    reaper.ImGui_SameLine(state.ctx)
    if reaper.ImGui_Button(state.ctx, state[visible_state_name] and ("隐藏##" .. id .. "_toggle") or ("显示##" .. id .. "_toggle"), 68, 22) then
      state[visible_state_name] = not state[visible_state_name]
    end
    return changed, new_value
  end

  local function model_button_label(model, selected)
    local label = tostring(model.label or model.id or "")
    local id = tostring(model.id or "")
    if id ~= "" and id ~= label then
      label = label .. "  |  " .. id
    end
    local tags = ctx.llm_providers and ctx.llm_providers.tags_text(model) or ""
    if tags ~= "" then
      label = label .. "  [" .. tags .. "]"
    end
    if selected then
      label = "* " .. label
    end
    return label
  end

  section_title("LLM 配置")

  local providers = ctx.llm_providers
  if providers then
    local provider = providers.provider_by_id(state.llm_provider_id)
    local detected = providers.detect_provider(config.llm_url, config.llm_model)
    if not state.llm_provider_id or state.llm_provider_id == "" then
      state.llm_provider_id = (detected and detected.id) or (provider and provider.id) or "custom"
      provider = providers.provider_by_id(state.llm_provider_id)
    end

    local function remember_model(model_id)
      invoke(ctx, "remember_llm_model", model_id, state.llm_provider_id)
    end

    local function apply_provider(item)
      state.llm_provider_id = item.id
      provider = item
      local chat_url = providers.provider_chat_url(item)
      if chat_url ~= "" then
        config.llm_url = chat_url
      end
      if item.default_model and item.default_model ~= "" then
        config.llm_model = item.default_model
        remember_model(item.default_model)
      end
      state.llm_model_menu_filter = ""
      state.llm_model_filter = ""
    end

    local function apply_base_url(base_url)
      config.llm_url = providers.chat_url_from_base(base_url)
    end

    local function apply_model(model_id)
      model_id = tostring(model_id or ""):gsub("^%s+", ""):gsub("%s+$", "")
      if model_id == "" then return end
      config.llm_model = model_id
      remember_model(model_id)
    end

    local function recommended_models_text(models)
      local names = {}
      for _, model in ipairs(models or {}) do
        if model.recommended then table.insert(names, model.id) end
        if #names >= 3 then break end
      end
      if #names == 0 and provider.default_model and provider.default_model ~= "" then
        table.insert(names, provider.default_model)
      end
      return #names > 0 and table.concat(names, " / ") or "手动输入"
    end

    field_label("供应商 Provider")
    local provider_items = providers.providers()
    reaper.ImGui_PushItemWidth(state.ctx, field_w)
    if begin_combo(state.ctx, "##llm_provider_combo", tostring(provider.label or provider.id or "")) then
      for _, item in ipairs(provider_items) do
        if selectable(state.ctx, tostring(item.label or item.id), item.id == state.llm_provider_id) then
          apply_provider(item)
        end
      end
      end_combo(state.ctx)
    end
    reaper.ImGui_PopItemWidth(state.ctx)

    provider = providers.provider_by_id(state.llm_provider_id)
    local provider_models = providers.models_for_provider(provider and provider.id or "", true)
    local api_base = providers.api_base_from_url(config.llm_url)
    if api_base == "" then api_base = providers.provider_api_base(provider) end

    field_label("Base URL")
    reaper.ImGui_PushItemWidth(state.ctx, field_w)
    local changed_base, new_base = input_text(state.ctx, "##llm_api_base", api_base, 0)
    reaper.ImGui_PopItemWidth(state.ctx)
    if changed_base then apply_base_url(new_base) end

    local models_support_text = "支持 /models 查询"
    if provider and provider.supports_models == false then
      models_support_text = "不支持 /models 查询，使用内置模型注册表"
    elseif provider and provider.id == "custom" then
      models_support_text = "可尝试 /models 查询"
    end

    reaper.ImGui_TextColored(state.ctx, 0x888888FF, "默认模型: " .. tostring(provider.default_model or ""))
    reaper.ImGui_TextColored(state.ctx, 0x888888FF, "推荐模型: " .. recommended_models_text(provider_models))
    reaper.ImGui_TextColored(state.ctx, 0x888888FF, models_support_text)
    if provider and provider.api_style ~= "openai_chat_completions" then
      reaper.ImGui_TextColored(state.ctx, 0xFFAA00FF, "此 Provider 尚未标记为 OpenAI Chat Completions 兼容")
    end

    reaper.ImGui_Spacing(state.ctx)

    field_label("Model Name")
    local model_button_w = 30
    local model_input_w = math.max(160, field_w - model_button_w - 6)
    reaper.ImGui_PushItemWidth(state.ctx, model_input_w)
    local changed_model, new_model = input_text(state.ctx, "##llm_model", config.llm_model, 0)
    reaper.ImGui_PopItemWidth(state.ctx)
    if changed_model then
      config.llm_model = new_model
      local model_detected = providers.detect_provider(config.llm_url, config.llm_model)
      if model_detected then state.llm_provider_id = model_detected.id end
    end
    reaper.ImGui_SameLine(state.ctx)
    if reaper.ImGui_Button(state.ctx, "▼##llm_model_menu_button", model_button_w, 22) then
      state.llm_model_picker_open = true
      open_popup(state.ctx, "llm_model_menu")
    end

    local function render_model_picker_body()
      reaper.ImGui_PushItemWidth(state.ctx, field_w - 18)
      local changed_filter, new_filter = input_text(state.ctx, "##llm_model_menu_filter", state.llm_model_menu_filter or "", 0)
      reaper.ImGui_PopItemWidth(state.ctx)
      if changed_filter then state.llm_model_menu_filter = new_filter end

      local filter = state.llm_model_menu_filter or ""
      local seen = {}
      local visible = 0

      local function should_show(model)
        return providers.model_matches_filter(model, filter)
      end

      local function render_item(model)
        if not model or not model.id or model.id == "" or seen[model.id] then return false end
        if not should_show(model) then return false end
        seen[model.id] = true
        visible = visible + 1
        if selectable(state.ctx, model_button_label(model, tostring(config.llm_model or "") == tostring(model.id)), tostring(config.llm_model or "") == tostring(model.id)) then
          apply_model(model.id)
          state.llm_model_picker_open = false
          close_current_popup(state.ctx)
        end
        return true
      end

      local function render_group(title, models, skip_recommended)
        local candidates = {}
        for _, model in ipairs(models or {}) do
          if not (skip_recommended and model.recommended == true) and model.id and not seen[model.id] and should_show(model) then
            table.insert(candidates, model)
          end
        end
        if #candidates == 0 then return false end
        reaper.ImGui_Separator(state.ctx)
        reaper.ImGui_TextColored(state.ctx, label_color, title)
        for _, model in ipairs(candidates) do render_item(model) end
        return true
      end

      local recommended = {}
      for _, model in ipairs(provider_models) do
        if model.recommended then table.insert(recommended, model) end
      end
      render_group("推荐模型", recommended, false)

      local dynamic_models = (state.llm_dynamic_models_by_provider or {})[provider.id] or {}
      if #dynamic_models > 0 then
        render_group("刷新模型列表结果", dynamic_models, false)
      end

      local groups, group_order = {}, {}
      for _, model in ipairs(provider_models) do
        local group = tostring(model.group or "Models")
        if not groups[group] then
          groups[group] = {}
          table.insert(group_order, group)
        end
        table.insert(groups[group], model)
      end
      for _, group in ipairs(group_order) do
        render_group(group, groups[group], true)
      end

      local recent = {}
      for _, item in ipairs(state.llm_recent_models or {}) do
        if item.provider_id == provider.id then
          table.insert(recent, { id = item.id, label = item.id, group = "最近使用模型", tags = { "recent" } })
        end
      end
      if #recent > 0 then
        render_group("最近使用模型", recent, false)
      end

      local custom_models = {}
      local current_model = tostring(config.llm_model or ""):gsub("^%s+", ""):gsub("%s+$", "")
      if current_model ~= "" then
        table.insert(custom_models, { id = current_model, label = current_model, group = "自定义模型", tags = { "current" } })
      end
      local custom_from_filter = tostring(filter or ""):gsub("^%s+", ""):gsub("%s+$", "")
      if custom_from_filter ~= "" and custom_from_filter ~= current_model then
        table.insert(custom_models, { id = custom_from_filter, label = custom_from_filter, group = "自定义模型", tags = { "custom" } })
      end
      if #custom_models > 0 then
        render_group("自定义模型", custom_models, false)
      end

      if visible == 0 then
        reaper.ImGui_TextColored(state.ctx, 0x888888FF, "没有匹配的模型")
      end
    end

    if begin_popup(state.ctx, "llm_model_menu") then
      if reaper.ImGui_BeginChild(state.ctx, "llm_model_menu_child", field_w, 320) then
        render_model_picker_body()
        reaper.ImGui_EndChild(state.ctx)
      end
      end_popup(state.ctx)
    elseif state.llm_model_picker_open and not reaper.ImGui_BeginPopup then
      if reaper.ImGui_BeginChild(state.ctx, "llm_model_menu_fallback", field_w, 260) then
        render_model_picker_body()
        reaper.ImGui_EndChild(state.ctx)
      end
    end

  else
    local changed_url, new_url = text_field("API URL", "llm_url", config.llm_url)
    if changed_url then config.llm_url = new_url end

    local changed_model, new_model = text_field("模型", "llm_model", config.llm_model)
    if changed_model then config.llm_model = new_model end
  end

  local changed_key, new_key = key_field("API Key", "llm_key", config.llm_key, "show_llm_key")
  if changed_key then config.llm_key = new_key end

  local settings_btn_w = 120
  local settings_btn_h = 28
  local settings_result_x = settings_btn_w + 18

  reaper.ImGui_Spacing(state.ctx)
  local test_disabled = state.llm_test_running == true or state.llm_models_refreshing == true
  if test_disabled and reaper.ImGui_BeginDisabled then reaper.ImGui_BeginDisabled(state.ctx, true) end
  if reaper.ImGui_Button(state.ctx, test_disabled and "测试中##test_llm" or "测试连接##test_llm", settings_btn_w, settings_btn_h) then
    invoke(ctx, "test_llm_connection")
  end
  if test_disabled and reaper.ImGui_EndDisabled then reaper.ImGui_EndDisabled(state.ctx) end
  if state.llm_test_message and state.llm_test_message ~= "" then
    reaper.ImGui_SameLine(state.ctx, settings_result_x)
    reaper.ImGui_TextColored(state.ctx, 0x888888FF, state.llm_test_message)
  end

  local refresh_disabled = state.llm_models_refreshing == true or state.llm_test_running == true
  if refresh_disabled and reaper.ImGui_BeginDisabled then reaper.ImGui_BeginDisabled(state.ctx, true) end
  if reaper.ImGui_Button(state.ctx, refresh_disabled and "刷新中##refresh_llm_models" or "刷新模型列表##refresh_llm_models", settings_btn_w, settings_btn_h) then
    invoke(ctx, "refresh_llm_models")
  end
  if refresh_disabled and reaper.ImGui_EndDisabled then reaper.ImGui_EndDisabled(state.ctx) end
  if state.llm_model_refresh_message and state.llm_model_refresh_message ~= "" then
    reaper.ImGui_SameLine(state.ctx, settings_result_x)
    reaper.ImGui_TextColored(state.ctx, 0x888888FF, state.llm_model_refresh_message)
  end

  section_title("ElevenLabs")

  local changed_eleven, new_eleven = key_field("API Key", "elevenlabs_key", config.elevenlabs_key, "show_elevenlabs_key")
  if changed_eleven then config.elevenlabs_key = new_eleven end

  section_title("本机能力检测")

  local capability = invoke(ctx, "get_local_capability_status", false) or {}
  local api = capability.api or {}
  local action = capability.action or {}
  local api_valid = api.valid == true
  local action_valid = action.valid == true

  if not capability.ready then
    reaper.ImGui_TextColored(state.ctx, 0xFFAA00FF, "建议检测当前这台 REAPER 的 API 和 Action ID")
  else
    reaper.ImGui_TextColored(state.ctx, 0x44CC44FF, "本机能力已检测")
  end

  local api_text = api_valid and ("已检测 " .. tostring(api.count or 0) .. " 个") or (api.needs_refresh and "需重新检测" or "未检测")
  local action_text = action_valid and ("已检测 " .. tostring(action.count or 0) .. " 个") or (action.needs_refresh and "需重新检测" or "未检测")

  reaper.ImGui_Text(state.ctx, "REAPER API")
  reaper.ImGui_SameLine(state.ctx, 118)
  reaper.ImGui_Text(state.ctx, api_text)
  if api_valid and api.generated_at and api.generated_at ~= "" then
    reaper.ImGui_SameLine(state.ctx, 270)
    reaper.ImGui_TextColored(state.ctx, status_muted, tostring(api.generated_at))
  end
  if api.needs_refresh then
    reaper.ImGui_TextColored(state.ctx, 0xFFAA00FF, "API 清单来自其他 REAPER 路径，建议重新检测")
  end

  reaper.ImGui_Text(state.ctx, "Action ID")
  reaper.ImGui_SameLine(state.ctx, 118)
  reaper.ImGui_Text(state.ctx, action_text)
  if action_valid and action.generated_at and action.generated_at ~= "" then
    reaper.ImGui_SameLine(state.ctx, 270)
    reaper.ImGui_TextColored(state.ctx, status_muted, tostring(action.generated_at))
  end
  if action.needs_refresh then
    reaper.ImGui_TextColored(state.ctx, 0xFFAA00FF, "Action 清单来自其他 REAPER 路径，建议重新检测")
  end

  if state.capability_probe_last_message and state.capability_probe_last_message ~= "" then
    reaper.ImGui_TextWrapped(state.ctx, state.capability_probe_last_message)
  end

  local disabled = state.capability_probe_running == true
  if disabled and reaper.ImGui_BeginDisabled then reaper.ImGui_BeginDisabled(state.ctx, true) end
  if reaper.ImGui_Button(state.ctx, disabled and "检测中##probe_all" or "检测##probe_all", settings_btn_w, settings_btn_h) then
    invoke(ctx, "run_all_capability_probes")
  end
  if disabled and reaper.ImGui_EndDisabled then reaper.ImGui_EndDisabled(state.ctx) end

  reaper.ImGui_Spacing(state.ctx)
  reaper.ImGui_Separator(state.ctx)
  reaper.ImGui_Spacing(state.ctx)

  if reaper.ImGui_Button(state.ctx, "保存", settings_btn_w, settings_btn_h) then
    local ok, msg = invoke(ctx, "save_config")
    if ok then
      invoke(ctx, "load_config")
      state.status = "配置已保存并重新加载"
    else
      state.status = msg or "配置保存失败"
    end
  end
  reaper.ImGui_SameLine(state.ctx)
  if reaper.ImGui_Button(state.ctx, "返回对话", settings_btn_w, settings_btn_h) then
    state.show_settings = false
    state.show_audio = false
  end

  reaper.ImGui_Spacing(state.ctx)
  reaper.ImGui_Spacing(state.ctx)
  reaper.ImGui_Separator(state.ctx)
  reaper.ImGui_Spacing(state.ctx)
  reaper.ImGui_TextColored(state.ctx, 0x666666FF, "作者：zhanghuisen")
end

function UI.render_audio(ctx)
  local state = ctx.state
  state.audio_mode = (state.audio_mode == "vox") and "vox" or "sfx"

  reaper.ImGui_Text(state.ctx, "生成音频")
  reaper.ImGui_SameLine(state.ctx)
  if reaper.ImGui_Button(state.ctx, "?##audio_shortcut_help", 22, 22) then
    reaper.ShowMessageBox(
      "11 快捷生成说明：\n\n" ..
      "在对话输入框里，以 11 开头即可跳过普通 AI 对话，直接调用生成音频。\n\n" ..
      "音效示例：\n" ..
      "11 爆炸冲击音效\n" ..
      "11sfx 金属按钮点击声\n\n" ..
      "配音示例：\n" ..
      "11vox 女声温柔说 欢迎回来\n" ..
      "11vox 男声低沉说 任务开始\n\n" ..
      "也可以在本页签里手动填写 SFX 或 VOX 参数后点击生成。",
      "ReaperAI - 11 快捷生成音频",
      0
    )
  end
  reaper.ImGui_Separator(state.ctx)

  local available_w = select(1, reaper.ImGui_GetContentRegionAvail(state.ctx))
  local available_h = select(2, reaper.ImGui_GetContentRegionAvail(state.ctx))
  local panel_w = math.max(260, math.min(680, available_w - 20))
  local text_area_h = math.max(150, math.min(320, available_h - 355))
  local accent = 0x2E6EA6FF
  local soft_button = 0x234160FF
  local muted = 0x9AA7B7FF
  local status_muted = 0x888888FF

  local function colored_button(label, width, height, color)
    reaper.ImGui_PushStyleColor(state.ctx, reaper.ImGui_Col_Button(), color)
    local clicked = reaper.ImGui_Button(state.ctx, label, width, height)
    reaper.ImGui_PopStyleColor(state.ctx)
    return clicked
  end

  local function mode_button(label, mode)
    local active = state.audio_mode == mode
    if colored_button(label, 104, 30, active and accent or soft_button) then
      state.audio_mode = mode
    end
  end

  local function label_text(label)
    reaper.ImGui_TextColored(state.ctx, muted, label)
  end

  local function section_separator(extra_top_spacing)
    reaper.ImGui_Spacing(state.ctx)
    if extra_top_spacing then
      reaper.ImGui_Spacing(state.ctx)
    end
    reaper.ImGui_Separator(state.ctx)
    reaper.ImGui_Spacing(state.ctx)
  end

  local function audio_line(label, id, value)
    label_text(label)
    reaper.ImGui_PushItemWidth(state.ctx, panel_w)
    local changed, new_value = input_text(state.ctx, "##" .. id, value, 0)
    reaper.ImGui_PopItemWidth(state.ctx)
    return changed, new_value
  end

  local function audio_area(label, id, value)
    label_text(label)
    return input_text_multiline(state.ctx, "##" .. id, value, panel_w, text_area_h, 0)
  end

  local function audio_request_status_text()
    local now = (reaper.time_precise and reaper.time_precise()) or os.clock()
    local dots = math.floor(now * 3) % 4
    local base = tostring(state.audio_status or state.status or "请求中")
    return base .. string.rep(".", dots) .. string.rep(" ", 3 - dots)
  end

  local function render_audio_status()
    local text = tostring(state.audio_status or state.status or "就绪")
    local color = status_muted
    if state.audio_waiting then
      text = audio_request_status_text()
      color = 0xFFAA00FF
    end
    if text ~= "" then
      reaper.ImGui_Spacing(state.ctx)
      reaper.ImGui_TextColored(state.ctx, color, text)
    end
  end

  local function reset_audio_fields()
    state.audio_sfx_track_name = ""
    state.audio_sfx_prompt = ""
    state.audio_vox_performance = ""
    state.audio_vox_text = ""
    state.status = "音频输入已重置"
    state.audio_status = state.status
  end

  local function render_primary_buttons(on_generate)
    local btn_w = 104
    local btn_h = 30
    if colored_button("生成", btn_w, btn_h, accent) then
      on_generate()
    end
    reaper.ImGui_SameLine(state.ctx)
    if colored_button("重置", btn_w, btn_h, soft_button) then
      reset_audio_fields()
    end
    render_audio_status()
  end

  local eleven = ctx.elevenlabs or {}

  local function selected_vox_voice()
    if type(eleven.voice_by_id) ~= "function" then return nil end
    return eleven.voice_by_id(state.audio_vox_voice_id or "", state.audio_vox_dynamic_voices or {})
  end

  local function vox_voice_options()
    if type(eleven.voice_options_for_gender) ~= "function" then return {} end
    return eleven.voice_options_for_gender(state.audio_vox_gender or "female", state.audio_vox_dynamic_voices or {})
  end

  local function resolved_vox_voice_id()
    local selected_id = tostring(state.audio_vox_voice_id or "")
    if selected_id ~= "" then return selected_id end
    local voices = vox_voice_options()
    local first = voices[1]
    return first and tostring(first.id or "") or ""
  end

  local function set_vox_gender(gender)
    state.audio_vox_gender = gender
    local selected = selected_vox_voice()
    if selected and type(eleven.voice_matches_gender) == "function" and not eleven.voice_matches_gender(selected, gender) then
      state.audio_vox_voice_id = ""
    end
  end

  local function render_vox_voice_picker()
    label_text("11Labs 声线")
    local voices = vox_voice_options()

    local selected = selected_vox_voice()
    if selected and type(eleven.voice_matches_gender) == "function" and not eleven.voice_matches_gender(selected, state.audio_vox_gender or "female") then
      state.audio_vox_voice_id = ""
      selected = nil
    end

    local preview = (#voices > 0) and "自动选择" or "请先刷新声线"
    if selected and type(eleven.voice_label) == "function" then
      preview = eleven.voice_label(selected)
    end

    local refresh_w = 84
    local combo_w = math.max(160, panel_w - refresh_w - 8)
    reaper.ImGui_PushItemWidth(state.ctx, combo_w)
    if begin_combo(state.ctx, "##audio_vox_voice_combo", preview) then
      reaper.ImGui_PushItemWidth(state.ctx, math.max(140, combo_w - 18))
      local changed_filter, new_filter = input_text(state.ctx, "##audio_vox_voice_filter", state.audio_vox_voice_filter or "", 0)
      reaper.ImGui_PopItemWidth(state.ctx)
      if changed_filter then state.audio_vox_voice_filter = new_filter end

      if #voices > 0 then
        if selectable(state.ctx, "自动选择##audio_vox_voice_auto", state.audio_vox_voice_id == nil or state.audio_vox_voice_id == "") then
          state.audio_vox_voice_id = ""
        end
        reaper.ImGui_Separator(state.ctx)
      else
        reaper.ImGui_TextColored(state.ctx, status_muted, "点击刷新检测可用声线")
      end

      local visible = 0
      for _, voice in ipairs(voices) do
        if type(eleven.voice_matches_filter) ~= "function" or eleven.voice_matches_filter(voice, state.audio_vox_voice_filter or "") then
          visible = visible + 1
          local label = (type(eleven.voice_menu_label) == "function") and eleven.voice_menu_label(voice) or tostring(voice.name or voice.id or "Voice")
          local selected_voice = tostring(state.audio_vox_voice_id or "") == tostring(voice.id or "")
          if selectable(state.ctx, label, selected_voice) then
            state.audio_vox_voice_id = tostring(voice.id or "")
            close_current_popup(state.ctx)
          end
        end
      end

      if visible == 0 then
        local empty_text = (#voices == 0) and "刷新后只显示可用声线" or "当前性别没有检测通过的声线"
        reaper.ImGui_TextColored(state.ctx, status_muted, empty_text)
      end
      end_combo(state.ctx)
    end
    reaper.ImGui_PopItemWidth(state.ctx)

    reaper.ImGui_SameLine(state.ctx)
    local refresh_disabled = state.audio_vox_voices_refreshing == true
    if refresh_disabled and reaper.ImGui_BeginDisabled then reaper.ImGui_BeginDisabled(state.ctx, true) end
    if reaper.ImGui_Button(state.ctx, refresh_disabled and "刷新中##audio_voice_refresh" or "刷新##audio_voice_refresh", refresh_w, 22) then
      invoke(ctx, "refresh_elevenlabs_voices")
    end
    if refresh_disabled and reaper.ImGui_EndDisabled then reaper.ImGui_EndDisabled(state.ctx) end

    if state.audio_vox_voice_refresh_message and state.audio_vox_voice_refresh_message ~= "" then
      reaper.ImGui_TextColored(state.ctx, status_muted, state.audio_vox_voice_refresh_message)
    else
      reaper.ImGui_TextColored(state.ctx, status_muted, "点击刷新检测当前 API 可用声线")
    end
  end

  mode_button("SFX 模式##audio_top_sfx", "sfx")
  reaper.ImGui_SameLine(state.ctx)
  mode_button("VOX 模式##audio_top_vox", "vox")
  section_separator(false)

  if state.audio_mode == "vox" then
    reaper.ImGui_Text(state.ctx, "VOX 配音")
    reaper.ImGui_Spacing(state.ctx)

    label_text("性别")
    if colored_button("男##audio_vox_male", 56, 26, (state.audio_vox_gender == "male") and accent or soft_button) then
      set_vox_gender("male")
    end
    reaper.ImGui_SameLine(state.ctx)
    if colored_button("女##audio_vox_female", 56, 26, (state.audio_vox_gender ~= "male") and accent or soft_button) then
      set_vox_gender("female")
    end

    reaper.ImGui_Spacing(state.ctx)
    render_vox_voice_picker()
    reaper.ImGui_Spacing(state.ctx)
    local changed_performance, new_performance = audio_line("语气/表演", "audio_vox_performance", state.audio_vox_performance or "")
    if changed_performance then state.audio_vox_performance = new_performance end
    section_separator(false)
    local changed_text, new_text = audio_area("台词", "audio_vox_text", state.audio_vox_text or "")
    if changed_text then state.audio_vox_text = new_text end

    section_separator(true)
    render_primary_buttons(function()
      invoke(ctx, "send_elevenlabs_request", {
        mode = "vox",
        gender = state.audio_vox_gender or "female",
        voice_id = resolved_vox_voice_id(),
        performance = state.audio_vox_performance or "",
        performance_prompt = state.audio_vox_performance or "",
        spoken_text = state.audio_vox_text or "",
      })
    end)
  else
    reaper.ImGui_Text(state.ctx, "SFX 音效")
    reaper.ImGui_Spacing(state.ctx)

    local changed_track, new_track = audio_line("轨道名", "audio_sfx_track", state.audio_sfx_track_name or "")
    if changed_track then state.audio_sfx_track_name = new_track end
    section_separator(false)
    local changed_prompt, new_prompt = audio_area("描述", "audio_sfx_prompt", state.audio_sfx_prompt or "")
    if changed_prompt then state.audio_sfx_prompt = new_prompt end

    section_separator(true)
    render_primary_buttons(function()
      invoke(ctx, "send_elevenlabs_request", {
        mode = "sfx",
        track_name = state.audio_sfx_track_name or "",
        prompt = state.audio_sfx_prompt or "",
      })
    end)
  end
end

function UI.render_operation_cards(ctx)
  local state = ctx.state
  local op = state.pending_operation
  if not op then return end

  reaper.ImGui_Separator(state.ctx)
  if op.placeholder then
    local now = (reaper.time_precise and reaper.time_precise()) or os.clock()
    local dots = math.floor(now * 3) % 4
    local phase = tostring(op.phase_text or state.status or "正在生成执行计划")
    local elapsed = tonumber(op.elapsed or 0) or 0
    local title = tostring(op.placeholder_title or "正在生成执行计划")
    reaper.ImGui_TextColored(state.ctx, 0xFFAA00FF, title .. string.rep(".", dots))
    reaper.ImGui_TextWrapped(state.ctx, "阶段: " .. phase)
    if elapsed >= 1 then
      reaper.ImGui_TextColored(state.ctx, 0x888888FF, "已等待: " .. tostring(math.floor(elapsed)) .. " 秒")
    end
    local summary = tostring(op.summary or "")
    if summary ~= "" then
      reaper.ImGui_TextWrapped(state.ctx, "需求: " .. summary)
    end
    reaper.ImGui_TextColored(state.ctx, 0x888888FF, "完成后会自动替换为确认卡；不会自动执行。")
    if reaper.ImGui_Button(state.ctx, "取消", 70, 28) then
      invoke(ctx, "cancel_pending_operation")
    end
    reaper.ImGui_Separator(state.ctx)
    return
  end

  local user_risk = tostring(op.user_risk or "")
  local needs_clarification = op.needs_clarification == true or op.contract_status == "needs_clarification"
  local clarification_button_count = 0
  local clicked_clarification_answer = nil
  local clicked_clarification_question_index = nil
  local needs_clarification_text = false
  local submit_clarification_text = false
  local clarification_hint = nil
  local clarification_placeholder = nil
  local clarification_submit_label = "确认说明"
  local risk_color = 0x44CC44FF
  if needs_clarification then
    risk_color = 0xFFAA44FF
  elseif op.risk == "blocked" or op.preflight_ok == false then
    risk_color = 0xFF3333FF
  elseif user_risk == "destructive" then
    risk_color = 0xFF5555FF
  elseif user_risk == "file_write" then
    risk_color = 0xFFAA44FF
  elseif user_risk == "batch" then
    risk_color = 0xDDAA33FF
  elseif user_risk == "analysis_state" then
    risk_color = 0x66AADDFF
  elseif user_risk == "read_only" then
    risk_color = 0x66AADDFF
  end

  local risk_label = tostring(op.user_risk_label or invoke(ctx, "operation_risk_label", op.risk) or op.risk or "unknown")
  local title = needs_clarification and "需要澄清" or "待确认操作"
  reaper.ImGui_TextColored(state.ctx, risk_color, title .. " (" .. risk_label .. ")")

  if needs_clarification then
    reaper.ImGui_TextWrapped(state.ctx, "状态: 需要确认")
  elseif op.preflight_ok == false then
    reaper.ImGui_TextWrapped(state.ctx, "状态: 不可执行，请取消后重新生成")
  else
    reaper.ImGui_TextWrapped(state.ctx, "状态: 可执行")
  end

  reaper.ImGui_TextWrapped(state.ctx, "摘要: " .. tostring(op.summary or ""))
  if op.plan_actions and #op.plan_actions > 0 then
    reaper.ImGui_TextWrapped(state.ctx, "动作内容: " .. table.concat(op.plan_actions, " / "))
  end

  if needs_clarification then
    local questions = op.clarification_questions or {}
    if #questions == 0 and op.clarification_prompt and op.clarification_prompt ~= "" then
      questions = {{ question = op.clarification_prompt, options = op.clarification_options or {}, notes = op.clarification_notes or {}, free_input = true }}
    end
    local max_questions = math.min(#questions, 3)
    for i = 1, max_questions do
      local q = questions[i] or {}
      local question = tostring(q.question or "")
      if question == "" then question = tostring(q.reason or "") end
      if question == "" then question = "AI 未提供澄清问题，请取消后重新生成。" end
      reaper.ImGui_TextColored(state.ctx, 0xFFAA44FF, "澄清: " .. question)
      if q.fields and #q.fields > 0 then
        reaper.ImGui_TextColored(state.ctx, 0x888888FF, "缺少信息: " .. table.concat(q.fields, " / "))
      end
      if q.notes and #q.notes > 0 then
        for _, note in ipairs(q.notes) do
          note = tostring(note or "")
          if note ~= "" then reaper.ImGui_TextWrapped(state.ctx, note) end
        end
      end
      local fields = q.fields or {}
      clarification_submit_label = clarification_confirm_label(fields, question)
      if q.placeholder and tostring(q.placeholder) ~= "" then
        clarification_placeholder = tostring(q.placeholder)
      end
      if q.free_input ~= false and fields and #fields > 0 then
        needs_clarification_text = true
        clarification_hint = clarification_placeholder or clarification_input_hint(question, fields, nil)
      end
      if q.options and #q.options > 0 then
        local max_options = math.min(#q.options, 6)
        for option_index = 1, max_options do
          local answer = tostring(q.options[option_index] or "")
          if answer ~= "" then
            if clarification_option_is_discardable(answer) then
            elseif clarification_option_is_hint(answer) then
              needs_clarification_text = true
              reaper.ImGui_TextWrapped(state.ctx, answer)
            elseif clarification_option_needs_text(answer) then
              needs_clarification_text = true
              clarification_hint = clarification_placeholder or clarification_input_hint(question, fields, nil)
            else
              clarification_button_count = clarification_button_count + 1
              local button_w = clarification_control_width(state.ctx)
              local label = clarification_button_label(answer)
              if reaper.ImGui_Button(state.ctx, label .. "##clarify_" .. tostring(i) .. "_" .. tostring(option_index), button_w, 26) then
                clicked_clarification_answer = answer
                clicked_clarification_question_index = i
              end
            end
          end
        end
        if #q.options > max_options then
          needs_clarification_text = true
          reaper.ImGui_TextColored(state.ctx, 0x888888FF, "... 还有 " .. tostring(#q.options - max_options) .. " 个选项")
        end
      else
        if q.free_input ~= false then
          needs_clarification_text = true
          clarification_hint = clarification_placeholder or clarification_input_hint(question, q.fields or {}, nil)
        end
      end
    end
    if max_questions == 0 then
      needs_clarification_text = true
      clarification_hint = ""
      reaper.ImGui_TextColored(state.ctx, 0xFFAA44FF, "澄清: AI 未提供澄清问题，请补充你的具体要求，或取消后重新生成。")
    end
    if needs_clarification_text or clarification_button_count == 0 then
      state.clarification_input_text = tostring(state.clarification_input_text or "")
      local hint = tostring(clarification_placeholder or clarification_hint or "")
      if hint ~= "" and state.clarification_input_text == "" then
        reaper.ImGui_TextColored(state.ctx, 0x666666FF, hint)
      end
      local input_w = clarification_control_width(state.ctx)
      reaper.ImGui_PushItemWidth(state.ctx, input_w)
      local changed, new_value = input_text(state.ctx, "##clarification_input", state.clarification_input_text, 0)
      if changed then state.clarification_input_text = new_value end
      reaper.ImGui_PopItemWidth(state.ctx)
      local has_text = state.clarification_input_text and state.clarification_input_text:gsub("^%s+", ""):gsub("%s+$", "") ~= ""
      if not has_text and reaper.ImGui_BeginDisabled then reaper.ImGui_BeginDisabled(state.ctx, true) end
      if reaper.ImGui_Button(state.ctx, clarification_submit_label, input_w, 26) and has_text then
        submit_clarification_text = true
      end
      if not has_text and reaper.ImGui_EndDisabled then reaper.ImGui_EndDisabled(state.ctx) end
    end
  else
    local effects = op.plan_effects or {}
    local destructive_text = (effects.deletes_project or effects.clears_project or effects.deletes_disk or effects.saves_project) and "有" or "无"
    reaper.ImGui_TextWrapped(state.ctx, "删除/覆盖: " .. destructive_text)
    local state_effects = {}
    if effects.changes_selection then table.insert(state_effects, "selection") end
    if effects.changes_time_selection then table.insert(state_effects, "time selection") end
    if effects.moves_cursor then table.insert(state_effects, "cursor") end
    if #state_effects > 0 then
      reaper.ImGui_TextWrapped(state.ctx, "State changes: " .. table.concat(state_effects, " / "))
    end
  end

  reaper.ImGui_TextWrapped(state.ctx, "来源: " .. tostring(op.source or "unknown") .. " | Step: " .. tostring(#(op.parts or {})) .. " | MCP: " .. tostring(#(op.mcp_calls or {})) .. " | SCRIPT: " .. tostring(op.script_count or 0))

  if not needs_clarification and op.preflight_ok == false and op.preflight_issues and #op.preflight_issues > 0 then
    local max_issues = math.min(#op.preflight_issues, 3)
    for i = 1, max_issues do
      reaper.ImGui_TextColored(state.ctx, 0xFF7777FF, "阻断: " .. tostring(op.preflight_issues[i]))
    end
    if #op.preflight_issues > max_issues then
      reaper.ImGui_TextColored(state.ctx, 0xFF7777FF, "... 还有 " .. tostring(#op.preflight_issues - max_issues) .. " 个阻断项")
    end
  elseif not needs_clarification and op.risk_reasons and #op.risk_reasons > 0 then
    local max_reasons = math.min(#op.risk_reasons, 2)
    for i = 1, max_reasons do
      reaper.ImGui_TextColored(state.ctx, 0xAAAAAAFF, "原因: " .. tostring(op.risk_reasons[i]))
    end
  end

  if op.parts and #op.parts > 0 then
    local max_preview = math.min(#op.parts, 4)
    for i = 1, max_preview do
      local part = op.parts[i]
      local label = invoke(ctx, "operation_step_label", part, i) or ("Step " .. tostring(i))
      local status = part.status or "pending"
      local suffix = ""
      if part.needs_clarification then
        suffix = " | 需要澄清"
      elseif part.blocked_reason then
        suffix = " | " .. tostring(part.blocked_reason)
      end
      reaper.ImGui_TextWrapped(state.ctx, label .. " | " .. status .. suffix)
    end
    if #op.parts > max_preview then
      reaper.ImGui_TextColored(state.ctx, 0x888888FF, "... 还有 " .. tostring(#op.parts - max_preview) .. " 个 step")
    end
  end

  if not needs_clarification then
    if user_risk == "destructive" and op.preflight_ok ~= false then
      reaper.ImGui_TextColored(state.ctx, 0xFF7777FF, "请确认这是你想要的删除/覆盖操作。")
    elseif user_risk == "file_write" and op.preflight_ok ~= false then
      reaper.ImGui_TextColored(state.ctx, 0xFFAA44FF, "此操作会导出或写入文件，请确认输出目标。")
    elseif user_risk == "batch" and op.preflight_ok ~= false then
      reaper.ImGui_TextColored(state.ctx, 0xDDAA33FF, "此操作会批量影响多个对象，请确认范围。")
    elseif user_risk == "analysis_state" and op.preflight_ok ~= false then
      reaper.ImGui_TextColored(state.ctx, 0x66AADDFF, "This analysis may move the cursor or set the time selection; it will not edit project objects.")
    end
  end

  local has_bottom_primary_button = false
  if needs_clarification then
  elseif op.preflight_ok == false then
    reaper.ImGui_PushStyleColor(state.ctx, reaper.ImGui_Col_Button(), 0x666666FF)
    reaper.ImGui_Button(state.ctx, "不可执行", 100, 28)
    reaper.ImGui_PopStyleColor(state.ctx)
    has_bottom_primary_button = true
  else
    reaper.ImGui_PushStyleColor(state.ctx, reaper.ImGui_Col_Button(), user_risk == "destructive" and 0xCC3333FF or 0x2E8B57FF)
    if reaper.ImGui_Button(state.ctx, "确认执行", 100, 28) then
      invoke(ctx, "execute_pending_operation")
    end
    reaper.ImGui_PopStyleColor(state.ctx)
    has_bottom_primary_button = true
  end

  if has_bottom_primary_button then
    reaper.ImGui_SameLine(state.ctx)
  end
  if reaper.ImGui_Button(state.ctx, "取消", 70, 28) then
    invoke(ctx, "cancel_pending_operation")
  end
  if submit_clarification_text then
    clicked_clarification_answer = tostring(state.clarification_input_text or "")
    clicked_clarification_question_index = clicked_clarification_question_index or 1
    state.clarification_input_text = ""
  end
  if clicked_clarification_answer then
    local submit_source = submit_clarification_text and "card_text" or "option"
    local result = invoke(ctx, "submit_clarification_answer", clicked_clarification_answer, clicked_clarification_question_index, submit_source)
    if result == "clarification_handled" then
      state.waiting = false
      state.scroll = true
    elseif result then
      state.waiting = true
      state.status = state.status or "等待 AI 响应..."
      state.scroll = true
    end
  end
  reaper.ImGui_Separator(state.ctx)
end

function UI.render_chat(ctx)
  local state = ctx.state
  local config = ctx.config
  local async_pipe = ctx.async_pipe

  local status_color = 0xCCCCCCFF
  if state.waiting then status_color = 0xFFAA00FF end
  local top_w = select(1, reaper.ImGui_GetContentRegionAvail(state.ctx))
  local clear_btn_w = 80
  local info_btn_w = 80
  local status_text = tostring(state.status or "")
  if #status_text > 90 then
    status_text = status_text:sub(1, 87) .. "..."
  end
  reaper.ImGui_PushTextWrapPos(state.ctx, reaper.ImGui_GetCursorPosX(state.ctx) + math.max(120, top_w - 8))
  reaper.ImGui_TextColored(state.ctx, status_color, status_text)
  reaper.ImGui_PopTextWrapPos(state.ctx)
  if config.llm_key == "" or config.llm_key == "在此填入你的 API Key" then
    reaper.ImGui_TextColored(state.ctx, 0xFF4444FF, "未设置 API Key")
  end
  local capability = invoke(ctx, "get_local_capability_status", false) or {}
  if not capability.ready then
    reaper.ImGui_TextColored(state.ctx, 0xFFAA00FF, "建议在设置页检测本机 REAPER 能力")
    reaper.ImGui_SameLine(state.ctx)
    if reaper.ImGui_Button(state.ctx, "去检测##open_capability_settings", 76, 22) then
      invoke(ctx, "open_config_editor")
    end
  end

  local exec_btn_w = 90
  local help_btn_w = 22
  local toolbar_spacing = 8
  if state.mcp_start_pending then
    reaper.ImGui_PushStyleColor(state.ctx, reaper.ImGui_Col_Button(), 0xFF4444FF)
    if reaper.ImGui_Button(state.ctx, "退出执行", exec_btn_w, 22) then
      invoke(ctx, "exit_execution_mode")
    end
    reaper.ImGui_PopStyleColor(state.ctx)
  elseif state.mcp_shutdown_pending then
    if reaper.ImGui_Button(state.ctx, "关闭中", exec_btn_w, 22) then
      state.status = "MCP 关闭中"
    end
  elseif not state.exec_mode then
    reaper.ImGui_PushStyleColor(state.ctx, reaper.ImGui_Col_Button(), 0x44CC44FF)
    if reaper.ImGui_Button(state.ctx, "执行模式", exec_btn_w, 22) then
      local ok, msg = invoke(ctx, "launch_mcp_server")
      state.status = msg or (ok and "执行模式已开启" or "执行模式开启失败")
    end
    reaper.ImGui_PopStyleColor(state.ctx)
  else
    reaper.ImGui_PushStyleColor(state.ctx, reaper.ImGui_Col_Button(), 0xFF4444FF)
    if reaper.ImGui_Button(state.ctx, "退出执行", exec_btn_w, 22) then
      invoke(ctx, "exit_execution_mode")
    end
    reaper.ImGui_PopStyleColor(state.ctx)
  end

  reaper.ImGui_SameLine(state.ctx)
  if reaper.ImGui_Button(state.ctx, "?", help_btn_w, 22) then
    reaper.ShowMessageBox(
      "「执行模式」说明：\n\n" ..
      "• 点击后会立即进入执行模式，并在后台尝试启动/连接 MCP 服务器\n" ..
      "• MCP 成功连接后使用 MCP 增强能力；MCP 离线时仍可用本地 Lua/SCRIPT 执行\n" ..
      "• 点击「退出执行」会退出执行模式；如 MCP 已启动，会同时后台关闭 MCP\n\n" ..
      "咨询模式：AI 只回答问题，不执行操作\n" ..
      "执行模式：AI 可以生成创建轨道、改 Region、加 FX 等待确认操作",
      "ReaperAI - 执行模式说明",
      0
    )
  end

  local right_buttons_w = clear_btn_w + toolbar_spacing + info_btn_w
  local left_buttons_w = exec_btn_w + toolbar_spacing + help_btn_w
  if top_w >= left_buttons_w + toolbar_spacing + right_buttons_w then
    reaper.ImGui_SameLine(state.ctx, math.max(0, top_w - right_buttons_w))
  else
    reaper.ImGui_SameLine(state.ctx)
  end
  if reaper.ImGui_Button(state.ctx, "清除对话", clear_btn_w, 22) then
    invoke(ctx, "clear_conversation")
  end
  reaper.ImGui_SameLine(state.ctx)
  if reaper.ImGui_Button(state.ctx, "工程信息", info_btn_w, 22) then
    invoke(ctx, "request_mcp_probe_async", 0)
    local ctx_info = invoke(ctx, "get_selection_context")
    reaper.ShowMessageBox(ctx_info or "", "ReaperAI - 当前工程状态", 0)
    state.status = "已查看工程信息"
  end

  reaper.ImGui_Separator(state.ctx)

  local w, h = reaper.ImGui_GetContentRegionAvail(state.ctx)
  local input_panel_h = 58
  local operation_panel_h = 0
  if state.pending_operation then
    if state.pending_operation.placeholder then
      operation_panel_h = 150
    else
      operation_panel_h = (state.pending_operation.needs_clarification and 380) or 235
    end
  end
  local bottom_panel_h = input_panel_h + operation_panel_h + (state.pending_operation and 8 or 0)
  if h < bottom_panel_h + 90 then
    bottom_panel_h = math.max(input_panel_h, h - 90)
    operation_panel_h = state.pending_operation and math.max(0, bottom_panel_h - input_panel_h - 8) or 0
  end
  local ch = math.max(20, h - bottom_panel_h)

  if reaper.ImGui_BeginChild(state.ctx, "chat", w, ch) then
    for _, m in ipairs(state.messages) do
      if m.is_system then
        reaper.ImGui_PushStyleColor(state.ctx, reaper.ImGui_Col_Text(), 0xAAAAAAFF)
        reaper.ImGui_TextWrapped(state.ctx, m.content)
        reaper.ImGui_PopStyleColor(state.ctx)
      elseif m.role == "user" then
        reaper.ImGui_PushStyleColor(state.ctx, reaper.ImGui_Col_Text(), 0xFFAA44FF)
        reaper.ImGui_Text(state.ctx, "▶ 你")
        reaper.ImGui_PopStyleColor(state.ctx)
        reaper.ImGui_Indent(state.ctx, 16)
        reaper.ImGui_TextWrapped(state.ctx, m.content)
        reaper.ImGui_Unindent(state.ctx, 16)
      else
        reaper.ImGui_PushStyleColor(state.ctx, reaper.ImGui_Col_Text(), 0x44DD88FF)
        reaper.ImGui_Text(state.ctx, "◆ AI")
        reaper.ImGui_PopStyleColor(state.ctx)
        reaper.ImGui_Indent(state.ctx, 16)
        reaper.ImGui_TextWrapped(state.ctx, m.content)
        reaper.ImGui_Unindent(state.ctx, 16)
      end
      reaper.ImGui_Spacing(state.ctx)
    end

    if state.scroll then
      reaper.ImGui_SetScrollHereY(state.ctx, 1.0)
      state.scroll = false
    end

    reaper.ImGui_EndChild(state.ctx)
  end

  local btn_clicked = false
  local enter_pressed = false
  local has_input = false

  if reaper.ImGui_BeginChild(state.ctx, "bottom_panel", w, bottom_panel_h) then
    if state.pending_operation and operation_panel_h > 20 then
      if reaper.ImGui_BeginChild(state.ctx, "operation_card_panel", w, operation_panel_h) then
        UI.render_operation_cards(ctx)
        reaper.ImGui_EndChild(state.ctx)
      end
      reaper.ImGui_Spacing(state.ctx)
    end

    local btn_h = 28
    local btn2_w = 80
    local spacing = 8

    local input_w = reaper.ImGui_GetContentRegionAvail(state.ctx) - btn2_w - spacing
    reaper.ImGui_PushItemWidth(state.ctx, input_w)
    local changed, new_text = input_text(state.ctx, "##input", state.input_text, 0)
    if changed then state.input_text = new_text end
    reaper.ImGui_PopItemWidth(state.ctx)

    reaper.ImGui_SameLine(state.ctx)

    enter_pressed = reaper.ImGui_IsKeyPressed(state.ctx, reaper.ImGui_Key_Enter())
    has_input = state.input_text and state.input_text ~= ""

    if state.waiting then
      reaper.ImGui_PushStyleColor(state.ctx, reaper.ImGui_Col_Button(), 0xFF4444FF)
      reaper.ImGui_PushStyleColor(state.ctx, reaper.ImGui_Col_ButtonHovered(), 0xFF6666FF)
      reaper.ImGui_PushStyleColor(state.ctx, reaper.ImGui_Col_ButtonActive(), 0xCC3333FF)
      if reaper.ImGui_Button(state.ctx, "⏹ 停止", btn2_w, btn_h) then
        if async_pipe and async_pipe.cancel then
          async_pipe.cancel()
          table.insert(state.messages, {
            role = "assistant",
            content = "⏹ 已取消请求",
            is_system = true
          })
        end
        state.waiting = false
        state.status = "就绪"
        if state.pending_operation and state.pending_operation.placeholder then
          state.pending_operation = nil
        end
        if state.audio_waiting then
          state.audio_pending_count = 0
          state.audio_waiting = false
          state.audio_status = "已取消请求"
        end
      end
      reaper.ImGui_PopStyleColor(state.ctx, 3)
    elseif state.mcp_running then
      if not has_input then
        reaper.ImGui_BeginDisabled(state.ctx)
      end
      btn_clicked = reaper.ImGui_Button(state.ctx, "🌐 发送", btn2_w, btn_h)
      if not has_input then
        reaper.ImGui_EndDisabled(state.ctx)
      end
    else
      btn_clicked = reaper.ImGui_Button(state.ctx, "发送", btn2_w, btn_h)
    end

    local hint_text
    if state.waiting then
      hint_text = "等待 AI 响应..."
    elseif state.pending_operation and state.pending_operation.needs_clarification then
      hint_text = "请在上方澄清卡填写具体说明，或在这里直接回复。"
    else
      hint_text = state.exec_mode and "按 Enter 发送（生成待确认操作）" or "按 Enter 发送（仅咨询）"
    end
    reaper.ImGui_TextColored(state.ctx, 0x666666FF, hint_text)

    reaper.ImGui_EndChild(state.ctx)
  else
    has_input = state.input_text and state.input_text ~= ""
  end

  if (btn_clicked or (has_input and enter_pressed)) and has_input then
    local msg = state.input_text
    local is_elevenlabs = msg:match("^%s*11") ~= nil
    local skip_send = false

    if state.pending_operation and not state.pending_operation.needs_clarification and not is_elevenlabs then
      table.insert(state.messages, {
        role = "assistant",
        content = "请先确认或取消当前待执行操作，再发送新的执行请求。",
        is_system = true
      })
      state.status = "已有待确认操作"
      state.scroll = true
      skip_send = true
    end

    if not skip_send then
      state.input_text = ""
      table.insert(state.messages, { role = "user", content = msg })

      if is_elevenlabs then
        if not invoke(ctx, "send_elevenlabs_request", msg) then
          state.status = state.status or "音频生成启动失败"
        end
      else
        local result = invoke(ctx, "send_request", msg)
        if result == "clarification_handled" then
          state.waiting = false
          state.scroll = true
        elseif result then
          state.waiting = true
          state.status = state.status or "等待 AI 响应..."
          state.scroll = true
        else
          state.status = "发送失败"
        end
      end
    end
  end
end

function UI.render(ctx)
  local state = ctx.state

  reaper.ImGui_SetNextWindowSize(state.ctx, 640, 720, reaper.ImGui_Cond_FirstUseEver())

  local flags = reaper.ImGui_WindowFlags_MenuBar()
  local visible, open = reaper.ImGui_Begin(state.ctx, "ReaperAI v1.0.2 智能助手", true, flags)

  if visible then
    if reaper.ImGui_BeginMenuBar(state.ctx) then
      if reaper.ImGui_MenuItem(state.ctx, "设置") then
        if state.show_settings then
          state.show_settings = false
        else
          invoke(ctx, "open_config_editor")
        end
      end
      if reaper.ImGui_MenuItem(state.ctx, "对话") then
        state.show_settings = false
        state.show_audio = false
      end
      if reaper.ImGui_MenuItem(state.ctx, "生成音频") then
        state.show_settings = false
        state.show_audio = true
        state.audio_mode = "sfx"
      end
      reaper.ImGui_EndMenuBar(state.ctx)
    end

    if state.show_settings then
      UI.render_settings(ctx)
    elseif state.show_audio then
      UI.render_audio(ctx)
    else
      UI.render_chat(ctx)
    end

    reaper.ImGui_End(state.ctx)
  end

  return open
end

return UI
