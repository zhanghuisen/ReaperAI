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

local function imgui_cond_always()
  if reaper.ImGui_Cond_Always then
    return reaper.ImGui_Cond_Always()
  end
  return 0
end

local function safe_window_size(ctx)
  if not reaper.ImGui_GetWindowSize then return nil, nil end
  local ok, w, h = pcall(reaper.ImGui_GetWindowSize, ctx)
  if ok then return tonumber(w), tonumber(h) end
  return nil, nil
end

local function safe_window_collapsed(ctx)
  if not reaper.ImGui_IsWindowCollapsed then return false end
  local ok, collapsed = pcall(reaper.ImGui_IsWindowCollapsed, ctx)
  return ok and collapsed == true
end

local function request_window_restore(state, width)
  state.ui_force_window_restore = true
  state.ui_restore_width = math.max(tonumber(width) or 640, 640)
end

local function compact_single_line(text, limit)
  text = tostring(text or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  limit = tonumber(limit or 180) or 180
  if #text > limit then
    return text:sub(1, limit) .. "..."
  end
  return text
end

local function render_ai_advanced_state(ctx, message, index)
  local state = ctx.state
  local status = tostring(message.stream_status or message.advanced_status or "")
  if message.cancelled then status = "已取消" end
  if status ~= "" then
    reaper.ImGui_TextColored(state.ctx, 0x888888FF, status)
  end

  local reasoning = tostring(message.reasoning_content or "")
  if reasoning ~= "" then
    if message.reasoning_streaming then
      reaper.ImGui_TextColored(state.ctx, 0x8FA7C8FF, "思考中...")
      reaper.ImGui_Indent(state.ctx, 12)
      reaper.ImGui_TextWrapped(state.ctx, reasoning .. " ▌")
      reaper.ImGui_Unindent(state.ctx, 12)
    else
      local expanded = message.reasoning_expanded == true
      if reaper.ImGui_Button(state.ctx, (expanded and "v" or ">") .. "##reasoning_toggle_" .. tostring(index), 22, 22) then
        message.reasoning_expanded = not expanded
        expanded = message.reasoning_expanded == true
      end
      if expanded then
        reaper.ImGui_SameLine(state.ctx)
        reaper.ImGui_TextColored(state.ctx, 0x8FA7C8FF, "思考")
        reaper.ImGui_Indent(state.ctx, 12)
        reaper.ImGui_TextWrapped(state.ctx, reasoning)
        reaper.ImGui_Unindent(state.ctx, 12)
      end
    end
  end

  if message.tool_calls and #message.tool_calls > 0 then
    reaper.ImGui_TextColored(state.ctx, 0xC8A96AFF, "工具调用")
    reaper.ImGui_Indent(state.ctx, 12)
    for tool_index, tool in ipairs(message.tool_calls) do
      local name = tostring(tool.name or tool.call_type or "tool")
      local args = compact_single_line(tool.arguments or "", 240)
      local line = tostring(tool_index) .. ". " .. name
      if args ~= "" then line = line .. "  " .. args end
      reaper.ImGui_TextWrapped(state.ctx, line)
    end
    reaper.ImGui_Unindent(state.ctx, 12)
  end

  if message.retryable and not state.waiting then
    if reaper.ImGui_Button(state.ctx, "重试##retry_ai_" .. tostring(index), 58, 22) then
      invoke(ctx, "retry_message", index)
    end
  end
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
  local config = ctx.config
  local eleven = ctx.elevenlabs or {}
  state.audio_mode = (state.audio_mode == "vox") and "vox" or "sfx"

  reaper.ImGui_Text(state.ctx, "生成音频")
  reaper.ImGui_SameLine(state.ctx)
  if reaper.ImGui_Button(state.ctx, "?##audio_shortcut_help", 22, 22) then
    reaper.ShowMessageBox(
      "生成音频说明：\n\n" ..
      "本页可以选择 ElevenLabs 或 火山引擎豆包，并分别使用音频生成 / 语音合成。\n\n" ..
      "生成音频现在只通过本页签提交，避免不同服务商共用快捷词造成混乱。\n\n" ..
      "ElevenLabs 可检测账户声线；豆包可刷新可用音色，并缓存下拉选择。\n\n" ..
      "填写音频生成或语音合成参数后点击生成即可。",
      "ReaperAI - 生成音频",
      0
    )
  end
  reaper.ImGui_Separator(state.ctx)

  local available_w = select(1, reaper.ImGui_GetContentRegionAvail(state.ctx))
  local available_h = select(2, reaper.ImGui_GetContentRegionAvail(state.ctx))
  local panel_w = math.max(260, available_w - 20)
  local text_area_h = math.max(150, available_h - 360)
  local accent = 0x2E6EA6FF
  local soft_button = 0x234160FF
  local muted = 0x9AA7B7FF
  local status_muted = 0x888888FF
  local password_flags = 0
  if reaper.ImGui_InputTextFlags_Password then
    password_flags = reaper.ImGui_InputTextFlags_Password()
  end
  local multiline_flags = 0
  if reaper.ImGui_InputTextFlags_NoHorizontalScroll then
    multiline_flags = multiline_flags + reaper.ImGui_InputTextFlags_NoHorizontalScroll()
  end

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

  local function audio_ratio_slider(label, id, value, min_value, max_value, default_value)
    label_text(label)
    value = tonumber(value) or tonumber(default_value) or 1.0
    min_value = tonumber(min_value) or 0.5
    max_value = tonumber(max_value) or 2.0
    default_value = tonumber(default_value) or 1.0

    local changed = false
    local new_value = value
    local used_slider = false
    reaper.ImGui_PushItemWidth(state.ctx, math.max(160, panel_w - 76))
    if reaper.ImGui_SliderDouble then
      local ok, c, v = pcall(reaper.ImGui_SliderDouble, state.ctx, "##" .. id, value, min_value, max_value, "%.2f")
      if ok then
        used_slider = true
        changed = c == true
        new_value = tonumber(v) or value
      end
    end
    if not used_slider and reaper.ImGui_SliderFloat then
      local ok, c, v = pcall(reaper.ImGui_SliderFloat, state.ctx, "##" .. id, value, min_value, max_value, "%.2f")
      if ok then
        used_slider = true
        changed = c == true
        new_value = tonumber(v) or value
      end
    end
    if not used_slider then
      local c, text_value = input_text(state.ctx, "##" .. id, string.format("%.2f", value), 0)
      if c and tonumber(text_value) then
        changed = true
        new_value = tonumber(text_value)
      end
    end
    reaper.ImGui_PopItemWidth(state.ctx)
    reaper.ImGui_SameLine(state.ctx)
    if reaper.ImGui_Button(state.ctx, "默认##" .. id .. "_reset", 68, 22) then
      changed = true
      new_value = default_value
    end
    new_value = math.max(min_value, math.min(max_value, new_value))
    return changed, new_value
  end

  local function audio_char_units(ch)
    if not ch or ch == "" then return 0 end
    if #ch == 1 then
      if ch:match("%s") then return 0.5 end
      return 1
    end
    return 2
  end

  local function audio_wrap_line(line, max_units)
    line = tostring(line or "")
    if line == "" then return { "" } end
    max_units = math.max(16, tonumber(max_units) or 60)
    local out = {}
    local current = ""
    local units = 0
    for ch in line:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
      local unit = audio_char_units(ch)
      if units + unit > max_units and current ~= "" then
        table.insert(out, current)
        current = ""
        units = 0
        if ch:match("%s") then
          ch = ""
          unit = 0
        end
      end
      current = current .. ch
      units = units + unit
    end
    if current ~= "" or #out == 0 then table.insert(out, current) end
    return out
  end

  local function audio_wrap_text_for_editor(text, width)
    text = tostring(text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    if text == "" then return "" end
    local max_units = math.max(18, math.floor(math.max(160, tonumber(width) or panel_w) / 7.2))
    local out = {}
    local index = 1
    while true do
      local next_break = text:find("\n", index, true)
      local line
      if next_break then
        line = text:sub(index, next_break - 1)
        index = next_break + 1
      else
        line = text:sub(index)
      end
      local wrapped = audio_wrap_line(line, max_units)
      for _, part in ipairs(wrapped) do table.insert(out, part) end
      if not next_break then break end
      if index > #text then
        table.insert(out, "")
        break
      end
    end
    return table.concat(out, "\n")
  end

  local function audio_visual_units(line)
    local units = 0
    for ch in tostring(line or ""):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
      units = units + audio_char_units(ch)
    end
    return units
  end

  local audio_block_endings = { "。", "！", "？", "!", "?", ".", ")", "]", "】", "」", "”", "\"", "'" }

  local function audio_ends_with_any(text, endings)
    text = tostring(text or "")
    for _, suffix in ipairs(endings) do
      if suffix ~= "" and text:sub(-#suffix) == suffix then return true end
    end
    return false
  end

  local function audio_line_ends_block(line)
    line = tostring(line or ""):gsub("%s+$", "")
    if line == "" then return true end
    if audio_ends_with_any(line, { "：", ":" }) and audio_visual_units(line) <= 24 then return true end
    return audio_ends_with_any(line, audio_block_endings)
  end

  local function audio_line_starts_block(line)
    line = tostring(line or ""):gsub("^%s+", "")
    if line == "" then return true end
    local half_colon = line:find(":", 1, true)
    local full_colon = line:find("：", 1, true)
    local colon = half_colon
    if full_colon and (not colon or full_colon < colon) then colon = full_colon end
    if not colon then return false end
    local label = line:sub(1, colon - 1)
    return label ~= "" and audio_visual_units(label) <= 24
  end

  local function audio_should_collapse_editor_break(prev, next_line, width)
    local left = tostring(prev or ""):gsub("%s+$", "")
    local right = tostring(next_line or ""):gsub("^%s+", "")
    if left == "" or right == "" then return false end
    if audio_line_ends_block(left) or audio_line_starts_block(right) then return false end
    local left_units = audio_visual_units(left)
    local right_units = audio_visual_units(right)
    local max_units = math.max(18, math.floor(math.max(160, tonumber(width) or panel_w) / 7.2))
    if left_units <= 3 or right_units <= 3 then return true end
    if right_units <= 18 and left_units >= 18 then return true end
    return left_units >= (max_units - 6)
  end

  local function audio_normalize_editor_text(text, width)
    text = tostring(text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    if text == "" then return "" end

    local out = {}
    local pending = nil
    for line in (text .. "\n"):gmatch("(.-)\n") do
      if pending == nil then
        pending = line
      elseif audio_should_collapse_editor_break(pending, line, width) then
        local left = pending:gsub("%s+$", "")
        local right = line:gsub("^%s+", "")
        local joiner = ""
        if left:match("[%w%)%]]$") and right:match("^[%w%(]") then joiner = " " end
        pending = left .. joiner .. right
      else
        table.insert(out, pending)
        pending = line
      end
    end
    if pending ~= nil then table.insert(out, pending) end
    return table.concat(out, "\n")
  end

  local function audio_area(label, id, value)
    label_text(label)
    local area_w = math.max(260, (select(1, reaper.ImGui_GetContentRegionAvail(state.ctx)) or panel_w) - 4)
    local area_h = math.max(150, (select(2, reaper.ImGui_GetContentRegionAvail(state.ctx)) or text_area_h) - 96)
    local original = tostring(value or "")
    local raw_value = audio_normalize_editor_text(original, area_w)
    local width_key = math.floor(area_w / 8)
    state.audio_editor_cache = state.audio_editor_cache or {}
    local cache = state.audio_editor_cache[id]
    if not cache or cache.raw ~= raw_value or cache.width_key ~= width_key then
      cache = {
        raw = raw_value,
        width_key = width_key,
        display = audio_wrap_text_for_editor(raw_value, area_w),
      }
      state.audio_editor_cache[id] = cache
    end
    local changed, new_value = input_text_multiline(state.ctx, "##" .. id, cache.display or "", area_w, area_h, multiline_flags)
    if changed then
      local next_raw = audio_normalize_editor_text(new_value, area_w)
      cache.raw = next_raw
      cache.width_key = width_key
      cache.display = audio_wrap_text_for_editor(next_raw, area_w)
      return true, next_raw
    end
    if raw_value ~= original then
      return true, raw_value
    end
    return false, raw_value
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

  local function normalize_provider(provider)
    if type(eleven.normalize_provider) == "function" then
      return eleven.normalize_provider(provider)
    end
    provider = tostring(provider or ""):lower()
    return (provider == "doubao" or provider == "volcengine" or provider == "volc") and "doubao" or "elevenlabs"
  end

  local function provider_label(provider)
    if type(eleven.provider_label) == "function" then
      return eleven.provider_label(provider)
    end
    return normalize_provider(provider) == "doubao" and "火山引擎豆包" or "ElevenLabs"
  end

  local provider = normalize_provider(config.audio_provider or "elevenlabs")
  config.audio_provider = provider

  local function audio_key_field(label, id, value, visible_state_name)
    label_text(label)
    local key_field_w = math.max(190, panel_w - 76)
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

  local function render_elevenlabs_voice_refresh()
    label_text("声线检测")
    local refresh_disabled = state.audio_vox_voices_refreshing == true
    if refresh_disabled and reaper.ImGui_BeginDisabled then reaper.ImGui_BeginDisabled(state.ctx, true) end
    if reaper.ImGui_Button(state.ctx, refresh_disabled and "刷新中##audio_voice_refresh_config" or "刷新声线##audio_voice_refresh_config", 104, 24) then
      invoke(ctx, "refresh_elevenlabs_voices")
    end
    if refresh_disabled and reaper.ImGui_EndDisabled then reaper.ImGui_EndDisabled(state.ctx) end
    reaper.ImGui_SameLine(state.ctx)
    local message = state.audio_vox_voice_refresh_message
    if not message or message == "" then
      message = "刷新后会缓存可用声线"
    end
    reaper.ImGui_TextColored(state.ctx, status_muted, message)
  end

  local function render_doubao_voice_refresh()
    label_text("音色检测")
    local refresh_disabled = state.audio_doubao_voices_refreshing == true
    if refresh_disabled and reaper.ImGui_BeginDisabled then reaper.ImGui_BeginDisabled(state.ctx, true) end
    if reaper.ImGui_Button(state.ctx, refresh_disabled and "刷新中##doubao_voice_refresh_config" or "刷新音色##doubao_voice_refresh_config", 104, 24) then
      invoke(ctx, "refresh_doubao_voices")
    end
    if refresh_disabled and reaper.ImGui_EndDisabled then reaper.ImGui_EndDisabled(state.ctx) end
    reaper.ImGui_SameLine(state.ctx)
    local message = state.audio_doubao_voice_refresh_message
    if not message or message == "" then
      message = "刷新后会缓存可用音色"
    end
    reaper.ImGui_TextColored(state.ctx, status_muted, message)
  end

  local function render_audio_provider_config()
    if provider == "doubao" then
      label_text("基础配置")
      local changed_key, new_key = audio_key_field("豆包 API Key", "doubao_api_key", config.doubao_api_key or "", "show_doubao_key")
      if changed_key then config.doubao_api_key = new_key end
      render_doubao_voice_refresh()
    else
      label_text("基础配置")
      local changed_key, new_key = audio_key_field("ElevenLabs API Key", "elevenlabs_key_audio", config.elevenlabs_key or "", "show_elevenlabs_key")
      if changed_key then config.elevenlabs_key = new_key end
      render_elevenlabs_voice_refresh()
    end

    if reaper.ImGui_Button(state.ctx, "保存音频配置##audio_save_config", 120, 26) then
      local ok, msg = invoke(ctx, "save_config")
      if ok then
        state.status = "音频配置已保存"
      else
        state.status = msg or "音频配置保存失败"
      end
      state.audio_status = state.status
    end
    reaper.ImGui_SameLine(state.ctx)
    reaper.ImGui_TextColored(state.ctx, status_muted, "配置保存在本地")
  end

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

    local preview = (#voices > 0) and "自动选择" or "请先在服务商配置中刷新声线"
    if selected and type(eleven.voice_label) == "function" then
      preview = eleven.voice_label(selected)
    end

    local combo_w = panel_w
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
        reaper.ImGui_TextColored(state.ctx, status_muted, "请在服务商配置中刷新可用声线")
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
  end

  local function doubao_language_options()
    if type(eleven.doubao_language_options) == "function" then
      return eleven.doubao_language_options()
    end
    return {
      { id = "zh_mix", label = "中英混" },
      { id = "ja", label = "日语" },
      { id = "id", label = "印尼语" },
      { id = "es", label = "西班牙语" },
    }
  end

  local function doubao_language_label(language)
    if type(eleven.doubao_language_label) == "function" then
      return eleven.doubao_language_label(language)
    end
    language = tostring(language or "")
    if language == "ja" then return "日语" end
    if language == "id" then return "印尼语" end
    if language == "es" then return "西班牙语" end
    return "中英混"
  end

  local function doubao_accent_options(language)
    if type(eleven.doubao_accent_options) == "function" then
      return eleven.doubao_accent_options(language)
    end
    return {
      { id = "default", label = "默认" },
      { id = "dongbei", label = "东北" },
      { id = "shaanxi", label = "陕西" },
      { id = "sichuan", label = "四川" },
    }
  end

  local function normalize_doubao_language(language)
    if type(eleven.normalize_doubao_language) == "function" then
      return eleven.normalize_doubao_language(language)
    end
    language = tostring(language or "")
    if language == "ja" or language == "id" or language == "es" then return language end
    return "zh_mix"
  end

  local function normalize_doubao_accent(language, accent)
    if type(eleven.normalize_doubao_accent) == "function" then
      return eleven.normalize_doubao_accent(language, accent)
    end
    accent = tostring(accent or "")
    if language ~= "zh_mix" then return "default" end
    if accent == "dongbei" or accent == "shaanxi" or accent == "sichuan" then return accent end
    return "default"
  end

  local function set_doubao_language(language)
    language = normalize_doubao_language(language)
    config.doubao_language = language
    state.audio_doubao_language = language
    if language ~= "zh_mix" then
      config.doubao_accent = "default"
      state.audio_doubao_accent = "default"
    else
      config.doubao_accent = normalize_doubao_accent(language, config.doubao_accent or state.audio_doubao_accent or "default")
      state.audio_doubao_accent = config.doubao_accent
    end
  end

  local function set_doubao_accent(accent)
    local language = normalize_doubao_language(config.doubao_language or state.audio_doubao_language)
    accent = normalize_doubao_accent(language, accent)
    config.doubao_accent = accent
    state.audio_doubao_accent = accent
  end

  local function selected_doubao_voice()
    if type(eleven.doubao_voice_by_id) ~= "function" then return nil end
    local voice_id = tostring(state.audio_doubao_voice_id or config.doubao_speaker or "")
    if voice_id == "" then voice_id = tostring(config.doubao_speaker or "") end
    return eleven.doubao_voice_by_id(voice_id, state.audio_doubao_dynamic_voices or {})
  end

  local function doubao_voice_options()
    if type(eleven.doubao_voice_all_options) == "function" then
      return eleven.doubao_voice_all_options(state.audio_doubao_dynamic_voices or {})
    end
    if type(eleven.doubao_voice_options) ~= "function" then return {} end
    return eleven.doubao_voice_options("zh_mix", "default", state.audio_doubao_dynamic_voices or {})
  end

  local function doubao_voice_display_name(voice)
    if voice and type(eleven.doubao_voice_label) == "function" then
      return eleven.doubao_voice_label(voice)
    end
    if voice then return tostring(voice.name or voice.id or "") end
    return ""
  end

  local function doubao_voice_language_options(voice)
    if voice and type(eleven.doubao_voice_language_options) == "function" then
      return eleven.doubao_voice_language_options(voice)
    end
    return doubao_language_options()
  end

  local function doubao_voice_accent_options_for_voice(voice, language)
    if voice and type(eleven.doubao_voice_accent_options) == "function" then
      return eleven.doubao_voice_accent_options(voice, language)
    end
    return doubao_accent_options(language)
  end

  local function doubao_voice_default_language(voice)
    if voice and type(eleven.doubao_voice_default_language) == "function" then
      return eleven.doubao_voice_default_language(voice)
    end
    return "zh_mix"
  end

  local function doubao_voice_default_accent(voice, language)
    if voice and type(eleven.doubao_voice_default_accent) == "function" then
      return eleven.doubao_voice_default_accent(voice, language)
    end
    return "default"
  end

  local function doubao_voice_supports_language(voice, language)
    if not voice then return false end
    if type(eleven.doubao_voice_supports_language) == "function" then
      return eleven.doubao_voice_supports_language(voice, language)
    end
    return true
  end

  local function doubao_voice_supports_accent(voice, language, accent_value)
    if not voice then return false end
    if type(eleven.doubao_voice_supports_accent) == "function" then
      return eleven.doubao_voice_supports_accent(voice, language, accent_value)
    end
    return true
  end

  local function current_doubao_language()
    return normalize_doubao_language(config.doubao_language or state.audio_doubao_language or "zh_mix")
  end

  local function current_doubao_accent()
    return normalize_doubao_accent(current_doubao_language(), config.doubao_accent or state.audio_doubao_accent or "default")
  end

  local function doubao_voice_supports_current(voice)
    if not voice then return false end
    if type(eleven.doubao_voice_supports) == "function" then
      return eleven.doubao_voice_supports(current_doubao_language(), current_doubao_accent(), voice)
    end
    return true
  end

  local function sync_doubao_settings_to_voice(voice)
    if not voice then return end
    local language = current_doubao_language()
    if not doubao_voice_supports_language(voice, language) then
      language = normalize_doubao_language(doubao_voice_default_language(voice))
    end
    local accent_value = current_doubao_accent()
    if not doubao_voice_supports_accent(voice, language, accent_value) then
      accent_value = normalize_doubao_accent(language, doubao_voice_default_accent(voice, language))
    end
    config.doubao_language = language
    state.audio_doubao_language = language
    config.doubao_accent = accent_value
    state.audio_doubao_accent = accent_value
  end

  local function doubao_voice_resource_id(voice)
    if voice and type(eleven.doubao_voice_resource_id) == "function" then
      return eleven.doubao_voice_resource_id(voice)
    end
    return ""
  end

  local function doubao_control_supported(voice, control)
    if not voice or type(eleven.doubao_voice_supports_control) ~= "function" then return true end
    return eleven.doubao_voice_supports_control(voice, control)
  end

  local function render_doubao_ratio_slider(label, id, value, min_value, max_value, default_value, control, voice)
    local disabled = voice and not doubao_control_supported(voice, control)
    if disabled and reaper.ImGui_BeginDisabled then reaper.ImGui_BeginDisabled(state.ctx, true) end
    local changed, new_value = audio_ratio_slider(label, id, value, min_value, max_value, default_value)
    if disabled and reaper.ImGui_EndDisabled then reaper.ImGui_EndDisabled(state.ctx) end
    if disabled then
      reaper.ImGui_TextColored(state.ctx, status_muted, "当前音色不支持" .. tostring(label))
    end
    return changed and not disabled, new_value
  end

  local function render_doubao_language_controls()
    local selected = selected_doubao_voice()
    if not selected then
      reaper.ImGui_TextColored(state.ctx, status_muted, "选择音色后显示语言")
      return
    end
    sync_doubao_settings_to_voice(selected)
    config.doubao_language = normalize_doubao_language(config.doubao_language or state.audio_doubao_language)
    config.doubao_accent = normalize_doubao_accent(config.doubao_language, config.doubao_accent or state.audio_doubao_accent)
    state.audio_doubao_language = config.doubao_language
    state.audio_doubao_accent = config.doubao_accent

    label_text("语言")
    local language_options = doubao_voice_language_options(selected)
    reaper.ImGui_PushItemWidth(state.ctx, panel_w)
    if begin_combo(state.ctx, "##doubao_language_combo", doubao_language_label(config.doubao_language)) then
      for _, item in ipairs(language_options) do
        if selectable(state.ctx, tostring(item.label or item.id), tostring(item.id) == tostring(config.doubao_language)) then
          set_doubao_language(item.id)
          sync_doubao_settings_to_voice(selected)
          close_current_popup(state.ctx)
        end
      end
      end_combo(state.ctx)
    end
    reaper.ImGui_PopItemWidth(state.ctx)

    local accent_options = doubao_voice_accent_options_for_voice(selected, config.doubao_language)
    local show_accent = config.doubao_language == "zh_mix" and #accent_options > 1
    if not show_accent then
      set_doubao_accent(doubao_voice_default_accent(selected, config.doubao_language))
      return
    end

    reaper.ImGui_Spacing(state.ctx)
    label_text("口音")
    local button_w = math.max(56, math.floor((panel_w - (#accent_options - 1) * 8) / math.max(1, #accent_options)))
    for i, item in ipairs(accent_options) do
      if i > 1 then reaper.ImGui_SameLine(state.ctx) end
      local active = tostring(config.doubao_accent or "default") == tostring(item.id)
      if colored_button(tostring(item.label or item.id) .. "##doubao_accent_" .. tostring(item.id), button_w, 26, active and accent or soft_button) then
        set_doubao_accent(item.id)
      end
    end
  end

  local function render_doubao_voice_picker()
    label_text("音色")
    local voices = doubao_voice_options()
    local selected = selected_doubao_voice()
    local saved_id = tostring(config.doubao_speaker or state.audio_doubao_speaker or "")
    local preview = "请先在服务商配置中刷新音色"
    if selected then
      sync_doubao_settings_to_voice(selected)
      preview = doubao_voice_display_name(selected)
    elseif saved_id ~= "" then
      preview = "已保存音色"
    elseif #voices > 0 then
      preview = "请选择音色"
    end

    local combo_w = panel_w
    reaper.ImGui_PushItemWidth(state.ctx, combo_w)
    if begin_combo(state.ctx, "##doubao_voice_combo", preview) then
      reaper.ImGui_PushItemWidth(state.ctx, math.max(140, combo_w - 18))
      local changed_filter, new_filter = input_text(state.ctx, "##doubao_voice_filter", state.audio_doubao_voice_filter or "", 0)
      reaper.ImGui_PopItemWidth(state.ctx)
      if changed_filter then state.audio_doubao_voice_filter = new_filter end

      if #voices == 0 then
        reaper.ImGui_TextColored(state.ctx, status_muted, "请在服务商配置中刷新可用音色")
      end

      local visible = 0
      for _, voice in ipairs(voices) do
        local matches = type(eleven.doubao_voice_matches_filter) ~= "function" or eleven.doubao_voice_matches_filter(voice, state.audio_doubao_voice_filter or "")
        if matches then
          visible = visible + 1
          local label = (type(eleven.doubao_voice_menu_label) == "function") and eleven.doubao_voice_menu_label(voice) or tostring(voice.name or voice.id or "Voice")
          local selected_voice = tostring(config.doubao_speaker or "") == tostring(voice.id or "")
          if selectable(state.ctx, label, selected_voice) then
            config.doubao_speaker = tostring(voice.id or "")
            state.audio_doubao_speaker = config.doubao_speaker
            state.audio_doubao_voice_id = config.doubao_speaker
            sync_doubao_settings_to_voice(voice)
            close_current_popup(state.ctx)
          end
        end
      end

      if visible == 0 and #voices > 0 then
        reaper.ImGui_TextColored(state.ctx, status_muted, "当前筛选下没有匹配音色")
      end
      end_combo(state.ctx)
    end
    reaper.ImGui_PopItemWidth(state.ctx)
    if saved_id ~= "" and not selected then
      reaper.ImGui_TextColored(state.ctx, 0xFFAA00FF, "已保存音色不在当前列表，请刷新或重新选择")
    end
  end

  local function render_doubao_advanced_controls()
    local selected = selected_doubao_voice()
    if not selected then return end
    reaper.ImGui_Spacing(state.ctx)
    local label = state.audio_doubao_advanced_open and "高级调节 v##doubao_advanced_toggle" or "高级调节 >##doubao_advanced_toggle"
    if reaper.ImGui_Button(state.ctx, label, 104, 24) then
      state.audio_doubao_advanced_open = not state.audio_doubao_advanced_open
    end
    if not state.audio_doubao_advanced_open then return end

    reaper.ImGui_Spacing(state.ctx)
    local changed_speed, new_speed = render_doubao_ratio_slider("语速", "doubao_speed_ratio", config.doubao_speed_ratio or state.audio_doubao_speed_ratio or 1.0, 0.5, 2.0, 1.0, "speed", selected)
    if changed_speed then
      config.doubao_speed_ratio = new_speed
      state.audio_doubao_speed_ratio = new_speed
    end
    local changed_pitch, new_pitch = render_doubao_ratio_slider("音调", "doubao_pitch_ratio", config.doubao_pitch_ratio or state.audio_doubao_pitch_ratio or 1.0, 0.5, 2.0, 1.0, "pitch", selected)
    if changed_pitch then
      config.doubao_pitch_ratio = new_pitch
      state.audio_doubao_pitch_ratio = new_pitch
    end
    local changed_volume, new_volume = render_doubao_ratio_slider("音量", "doubao_volume_ratio", config.doubao_volume_ratio or state.audio_doubao_volume_ratio or 1.0, 0.5, 2.0, 1.0, "volume", selected)
    if changed_volume then
      config.doubao_volume_ratio = new_volume
      state.audio_doubao_volume_ratio = new_volume
    end
  end

  label_text("服务商")
  local provider_combo_w = math.max(160, math.min(260, panel_w - 70))
  reaper.ImGui_PushItemWidth(state.ctx, provider_combo_w)
  if begin_combo(state.ctx, "##audio_provider_combo", provider_label(provider)) then
    if selectable(state.ctx, "ElevenLabs##audio_provider_select_elevenlabs", provider == "elevenlabs") then
      provider = "elevenlabs"
      config.audio_provider = provider
      close_current_popup(state.ctx)
    end
    if selectable(state.ctx, "火山引擎豆包##audio_provider_select_doubao", provider == "doubao") then
      provider = "doubao"
      config.audio_provider = provider
      close_current_popup(state.ctx)
    end
    end_combo(state.ctx)
  end
  reaper.ImGui_PopItemWidth(state.ctx)
  reaper.ImGui_SameLine(state.ctx)
  if reaper.ImGui_Button(state.ctx, state.audio_provider_config_open and "收起##audio_provider_config_toggle" or "配置##audio_provider_config_toggle", 58, 22) then
    state.audio_provider_config_open = not state.audio_provider_config_open
  end
  if state.audio_provider_config_open then
    reaper.ImGui_Spacing(state.ctx)
    render_audio_provider_config()
  end
  section_separator(false)

  mode_button("音频生成##audio_top_sfx", "sfx")
  reaper.ImGui_SameLine(state.ctx)
  mode_button("语音合成##audio_top_vox", "vox")
  section_separator(false)

  if state.audio_mode == "vox" then
    reaper.ImGui_Text(state.ctx, "语音合成 - " .. provider_label(provider))
    reaper.ImGui_Spacing(state.ctx)

    if provider == "doubao" then
      render_doubao_voice_picker()
      reaper.ImGui_Spacing(state.ctx)
      render_doubao_language_controls()
      render_doubao_advanced_controls()
    else
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
    end

    section_separator(false)
    local changed_text, new_text = audio_area("台词", "audio_vox_text", state.audio_vox_text or "")
    if changed_text then state.audio_vox_text = new_text end

    section_separator(true)
    render_primary_buttons(function()
      if provider == "doubao" then
        local selected = selected_doubao_voice()
        local language = current_doubao_language()
        local accent_value = current_doubao_accent()
        if not selected then
          state.status = "请先选择豆包语音合成音色"
          return
        end
        if not doubao_voice_supports_current(selected) then
          state.status = "当前豆包音色不支持所选语言/口音"
          return
        end
        invoke(ctx, "send_audio_request", {
          provider = provider,
          mode = "vox",
          speaker = config.doubao_speaker or "",
          speaker_name = doubao_voice_display_name(selected),
          language = language,
          accent = accent_value,
          speed_ratio = config.doubao_speed_ratio or state.audio_doubao_speed_ratio or 1.0,
          pitch_ratio = config.doubao_pitch_ratio or state.audio_doubao_pitch_ratio or 1.0,
          volume_ratio = config.doubao_volume_ratio or state.audio_doubao_volume_ratio or 1.0,
          resource_id = doubao_voice_resource_id(selected),
          performance = "",
          performance_prompt = "",
          spoken_text = state.audio_vox_text or "",
          format = "wav",
        })
      else
        invoke(ctx, "send_audio_request", {
          provider = provider,
          mode = "vox",
          gender = state.audio_vox_gender or "female",
          voice_id = resolved_vox_voice_id(),
          performance = state.audio_vox_performance or "",
          performance_prompt = state.audio_vox_performance or "",
          spoken_text = state.audio_vox_text or "",
        })
      end
    end)
  else
    reaper.ImGui_Text(state.ctx, "音频生成 - " .. provider_label(provider))
    reaper.ImGui_Spacing(state.ctx)

    local changed_track, new_track = audio_line("轨道名", "audio_sfx_track", state.audio_sfx_track_name or "")
    if changed_track then state.audio_sfx_track_name = new_track end
    section_separator(false)
    local changed_prompt, new_prompt = audio_area("描述", "audio_sfx_prompt", state.audio_sfx_prompt or "")
    if changed_prompt then state.audio_sfx_prompt = new_prompt end

    section_separator(true)
    render_primary_buttons(function()
      invoke(ctx, "send_audio_request", {
        provider = provider,
        mode = "sfx",
        track_name = state.audio_sfx_track_name or "",
        prompt = state.audio_sfx_prompt or "",
        text_prompt = state.audio_sfx_prompt or "",
        format = "wav",
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

  if op.needs_clarification == true or op.contract_status == "needs_clarification" then
    return
  end

  local user_risk = tostring(op.user_risk or "")
  local risk_color = 0x44CC44FF
  if user_risk == "destructive" then
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
  reaper.ImGui_TextColored(state.ctx, risk_color, "待确认操作 (" .. risk_label .. ")")

  if op.preflight_ok == false then
    reaper.ImGui_TextWrapped(state.ctx, "状态: 可确认（有预检提示）")
  else
    reaper.ImGui_TextWrapped(state.ctx, "状态: 可执行")
  end

  reaper.ImGui_TextWrapped(state.ctx, "摘要: " .. tostring(op.summary or ""))
  if op.plan_actions and #op.plan_actions > 0 then
    reaper.ImGui_TextWrapped(state.ctx, "动作内容: " .. table.concat(op.plan_actions, " / "))
  end

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

  reaper.ImGui_TextWrapped(state.ctx, "来源: " .. tostring(op.source or "unknown") .. " | Step: " .. tostring(#(op.parts or {})) .. " | MCP: " .. tostring(#(op.mcp_calls or {})) .. " | SCRIPT: " .. tostring(op.script_count or 0))

  if op.preflight_ok == false and op.preflight_issues and #op.preflight_issues > 0 then
    local max_issues = math.min(#op.preflight_issues, 3)
    for i = 1, max_issues do
      reaper.ImGui_TextColored(state.ctx, 0xFFAA44FF, "提示: " .. tostring(op.preflight_issues[i]))
    end
    if #op.preflight_issues > max_issues then
      reaper.ImGui_TextColored(state.ctx, 0xFFAA44FF, "... 还有 " .. tostring(#op.preflight_issues - max_issues) .. " 条提示")
    end
  elseif op.risk_reasons and #op.risk_reasons > 0 then
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
        suffix = " | 需补充"
      elseif part.warning_reason then
        suffix = " | 提示: " .. tostring(part.warning_reason)
      end
      reaper.ImGui_TextWrapped(state.ctx, label .. " | " .. status .. suffix)
    end
    if #op.parts > max_preview then
      reaper.ImGui_TextColored(state.ctx, 0x888888FF, "... 还有 " .. tostring(#op.parts - max_preview) .. " 个 step")
    end
  end

  if user_risk == "destructive" and op.preflight_ok ~= false then
    reaper.ImGui_TextColored(state.ctx, 0xFF7777FF, "请确认这是你想要的删除/覆盖操作。")
  elseif user_risk == "file_write" and op.preflight_ok ~= false then
    reaper.ImGui_TextColored(state.ctx, 0xFFAA44FF, "此操作会导出或写入文件，请确认输出目标。")
  elseif user_risk == "batch" and op.preflight_ok ~= false then
    reaper.ImGui_TextColored(state.ctx, 0xDDAA33FF, "此操作会批量影响多个对象，请确认范围。")
  elseif user_risk == "analysis_state" and op.preflight_ok ~= false then
    reaper.ImGui_TextColored(state.ctx, 0x66AADDFF, "This analysis may move the cursor or set the time selection; it will not edit project objects.")
  end

  local has_bottom_primary_button = false
  reaper.ImGui_PushStyleColor(state.ctx, reaper.ImGui_Col_Button(), user_risk == "destructive" and 0xCC3333FF or 0x2E8B57FF)
  if reaper.ImGui_Button(state.ctx, "确认执行", 100, 28) then
    invoke(ctx, "execute_pending_operation")
  end
  reaper.ImGui_PopStyleColor(state.ctx)
  has_bottom_primary_button = true

  if has_bottom_primary_button then
    reaper.ImGui_SameLine(state.ctx)
  end
  if reaper.ImGui_Button(state.ctx, "取消", 70, 28) then
    invoke(ctx, "cancel_pending_operation")
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
      operation_panel_h = 235
    end
  end
  local bottom_panel_h = input_panel_h + operation_panel_h + (state.pending_operation and 8 or 0)
  if h < bottom_panel_h + 90 then
    bottom_panel_h = math.max(input_panel_h, h - 90)
    operation_panel_h = state.pending_operation and math.max(0, bottom_panel_h - input_panel_h - 8) or 0
  end
  local ch = math.max(20, h - bottom_panel_h)

  if reaper.ImGui_BeginChild(state.ctx, "chat", w, ch) then
    for i, m in ipairs(state.messages) do
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
        local ai_content = tostring(m.content or "")
        if m.streaming and ai_content ~= "" then
          ai_content = ai_content .. " ▌"
        end
        if ai_content ~= "" then
          reaper.ImGui_TextWrapped(state.ctx, ai_content)
        end
        render_ai_advanced_state(ctx, m, i)
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
        invoke(ctx, "cancel_generation")
      end
      reaper.ImGui_PopStyleColor(state.ctx, 3)
    else
      if state.mcp_running then
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
    end

    local hint_text
    if state.waiting then
      hint_text = "等待 AI 响应..."
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
    local skip_send = false

    if state.pending_operation then
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

function UI.render(ctx)
  local state = ctx.state

  if state.ui_force_window_restore then
    reaper.ImGui_SetNextWindowSize(state.ctx, tonumber(state.ui_restore_width) or 640, 720, imgui_cond_always())
    state.ui_force_window_restore = false
  else
    reaper.ImGui_SetNextWindowSize(state.ctx, 640, 720, reaper.ImGui_Cond_FirstUseEver())
  end

  local flags = reaper.ImGui_WindowFlags_MenuBar()
  local visible, open = reaper.ImGui_Begin(state.ctx, "ReaperAI v1.0.5 智能助手", true, flags)

  local win_w, win_h = safe_window_size(state.ctx)
  local collapsed = safe_window_collapsed(state.ctx)
  local tiny_restored_window = visible and not collapsed and win_h and win_h < 220
  if collapsed then
    state.ui_window_was_collapsed = true
  elseif tiny_restored_window then
    request_window_restore(state, win_w)
    state.ui_window_was_collapsed = false
  elseif visible and win_h and win_h >= 220 then
    state.ui_window_was_collapsed = false
  end

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
