--[[
  ReaperAI v1.0.3 - 智能助手
  
  作者：zhanghuisen
  
  前置要求：ReaImGui（通过 ReaPack 安装）
  
  版本：1.0.3 (2026-07-09)
  核心特性：
  - 异步 HTTP：使用后台 worker，不阻塞 REAPER UI
  - 智能助手：支持咨询与操作双模式
  - 执行模式开关：用户手动控制是否执行操作
  - 纯脚本模式：统一使用 [SCRIPT] 格式执行 Lua
  - 工程状态快照校验：执行前对比工程状态变化
  - MCP 手动触发：避免自动轮询卡顿
  - 完整的 Unicode 支持：正确处理中文字符
  - 代码自动修复：处理 AI 生成的常见语法错误
--]]

-- ============================================
-- ReaperAI 模块加载
-- ============================================
local function reaperai_path_sep()
  local sep = package and package.config and package.config:sub(1, 1) or "/"
  if sep == "" then return "/" end
  return sep
end

local RAI_PATH_SEP = reaperai_path_sep()

local function reaperai_dirname(path)
  path = tostring(path or "")
  local dir = path:match("^(.*[\\/])")
  if dir and dir ~= "" then
    return dir
  end
  return nil
end

local function reaperai_script_dir()
  if reaper and reaper.get_action_context then
    local ok, _, filename = pcall(reaper.get_action_context)
    if ok and filename and filename ~= "" then
      local dir = reaperai_dirname(filename)
      if dir then return dir end
    end
  end
  return reaper.GetResourcePath() .. RAI_PATH_SEP .. "Scripts" .. RAI_PATH_SEP
end

local RAI_SCRIPT_DIR = reaperai_script_dir()
local RAI_MODULE_DIR = RAI_SCRIPT_DIR .. "ReaperAI" .. RAI_PATH_SEP

local function reaperai_load_module(name)
  local path = RAI_MODULE_DIR .. tostring(name) .. ".lua"
  local ok, result = pcall(dofile, path)
  if ok and result then
    return result
  end
  error("ReaperAI module load failed: " .. path .. "\n" .. tostring(result), 0)
end

local Prompt = reaperai_load_module("prompt")
local Operation = reaperai_load_module("operation")
local PlanContract = reaperai_load_module("plan_contract").create({
  parse_call = Operation.parse_call,
  build_call = Operation.build_call,
})
if type(Operation.set_plan_contract) == "function" then
  Operation.set_plan_contract(PlanContract)
end
local ClarificationResolver = reaperai_load_module("clarification_resolver").create({
  Operation = Operation,
})
local LuaExecutor = reaperai_load_module("lua_executor")
local McpClient = reaperai_load_module("mcp_client")
local ReaperCapabilities = reaperai_load_module("reaper_capabilities")
local McpFallback = reaperai_load_module("mcp_fallback").create()
local ContextModule = reaperai_load_module("context")
local UI = reaperai_load_module("ui")
local Waiting = reaperai_load_module("waiting")
local ElevenLabs = reaperai_load_module("elevenlabs")
local LlmProviders = reaperai_load_module("llm_providers")
local CapabilityRegistry = reaperai_load_module("capability_registry")
local Capabilities = ReaperCapabilities.create({
  module_dir = RAI_MODULE_DIR,
})
LuaExecutor.set_capabilities(Capabilities)
Operation.native_action_entry = LuaExecutor.native_action_entry
_G.reaperai_capabilities = Capabilities
local RuntimeModel = reaperai_load_module("runtime_model").create({
  Operation = Operation,
})
local RuntimeState = RuntimeModel.RuntimeState
local GeneratedRegistry = RuntimeModel.GeneratedRegistry
local ObjectBinding = RuntimeModel.ObjectBinding
local ProjectFacts = reaperai_load_module("project_facts").create({
  Operation = Operation,
  RuntimeState = RuntimeState,
})
local CuratedCapabilityRegistry = CapabilityRegistry.create({
  Operation = Operation,
  ReaperCapabilities = Capabilities,
  GeneratedRegistry = GeneratedRegistry,
})
_G.reaperai_capability_registry = CuratedCapabilityRegistry
LuaExecutor.set_capability_registry(CuratedCapabilityRegistry)
if type(Prompt.set_capability_registry) == "function" then
  Prompt.set_capability_registry(CuratedCapabilityRegistry)
end
if type(Operation.set_capability_registry) == "function" then
  Operation.set_capability_registry(CuratedCapabilityRegistry)
end

-- ============================================
-- 加载异步 HTTP 模块
-- ============================================
local AsyncPipe = nil
local async_module_path = RAI_SCRIPT_DIR .. "rai_async_pipe.lua"
local f = io.open(async_module_path, "r")
if not f then
  async_module_path = reaper.GetResourcePath() .. RAI_PATH_SEP .. "Scripts" .. RAI_PATH_SEP .. "rai_async_pipe.lua"
  f = io.open(async_module_path, "r")
end
if f then
  f:close()
  local ok, result = pcall(function() return dofile(async_module_path) end)
  if ok and result then
    AsyncPipe = result
    -- reaper.ShowConsoleMsg("✓ 异步 HTTP 模块已加载\\n")
  else
    reaper.ShowConsoleMsg("⚠️ 异步 HTTP 模块加载失败: " .. tostring(result) .. "\\n")
    reaper.ShowConsoleMsg("   回退到同步模式\\n")
  end
else
  reaper.ShowConsoleMsg("⚠️ 未找到异步 HTTP 模块，回退到同步模式\\n")
end

-- ============================================
-- MCP 客户端模块
-- ============================================
local MCP = McpClient.create({
  prompt = Prompt,
  script_dir = RAI_SCRIPT_DIR,
})

local function exec_process_capture(cmd, timeout_ms)
  return MCP.exec_process_capture(cmd, timeout_ms)
end

local function exec_process_ok(cmd, timeout_ms)
  return MCP.exec_process_ok(cmd, timeout_ms)
end

local function read_mcp_server_file(filename, max_chars)
  return MCP.read_server_file(filename, max_chars)
end

local function read_mcp_status_snapshot()
  return MCP.read_status_snapshot()
end

local function read_mcp_launch_log()
  return MCP.read_launch_log()
end

local function read_mcp_shutdown_log()
  return MCP.read_shutdown_log()
end

-- ============================================
-- 配置
-- ============================================
local CONFIG = {
  llm_url       = "https://api.openai.com/v1/chat/completions",
  llm_key       = "",
  llm_model     = "gpt-5.5",
  elevenlabs_key = "",
  mcp_url       = "http://127.0.0.1:8765",
  mcp_enabled   = true,
  inject_context = true,
  operation_repair_max_attempts = 1,
  script_preflight_repair_max_attempts = 1,
  operation_runtime_repair_max_attempts = 1,
  -- v1.0+：ElevenLabs Voice 由 worker 智能选择，无需手动配置
  -- v1.0+：始终使用异步 HTTP

  system_prompt = Prompt.system_prompt
}

-- ============================================
-- 状态
-- ============================================
local state = {
  ctx            = nil,
  messages       = {},
  input_text     = "",
  waiting        = false,
  status         = "就绪",
  scroll         = false,
  http           = nil,
  show_settings  = false,
  show_audio     = false,
  audio_mode     = "sfx",
  audio_waiting  = false,
  audio_pending_count = 0,
  audio_status   = "就绪",
  audio_wait_kind = "",
  audio_started_at = 0,
  chat_stream_active = false,
  stream_typewriter_update = nil,
  audio_sfx_track_name = "",
  audio_sfx_prompt = "",
  audio_vox_gender = "female",
  audio_vox_voice_id = "",
  audio_vox_voice_filter = "",
  audio_vox_voice_picker_open = false,
  audio_vox_dynamic_voices = {},
  audio_vox_voices_refreshing = false,
  audio_vox_voice_refresh_message = "",
  audio_vox_performance = "",
  audio_vox_text = "",
  local_capability_status = nil,
  capability_probe_running = false,
  capability_probe_last_message = "",
  mcp_status     = "未检测",
  last_proj_ctx  = nil,
  last_check     = 0,
  exec_log       = {},
  exec_mode      = false,
  show_llm_key   = false,
  show_elevenlabs_key = false,
  llm_provider_id = "openai",
  llm_model_filter = "",
  llm_model_menu_filter = "",
  llm_model_picker_open = true,
  llm_recent_models = {},
  llm_dynamic_models_by_provider = {},
  llm_models_refreshing = false,
  llm_model_refresh_message = "",
  llm_test_running = false,
  llm_test_message = "",
  mcp_running    = false,
  async_response = nil,  -- v1.0 新增：存储异步响应
  last_selection_context = nil, -- 新增：实时抓取的选中信息
  mcp_capabilities = nil, -- 新增：MCP 服务器功能列表（动态获取）
  mcp_endpoint_count = 0,
  mcp_real_connected = false,
  mcp_real_endpoint_count = 0,
  mcp_real_pid = nil,
  mcp_last_check_text = "未检测",
  mcp_status_detail = "",
  mcp_start_pending = false,
  mcp_start_started_at = 0,
  mcp_shutdown_pending = false,
  mcp_shutdown_started_at = 0,
  mcp_last_probe_at = 0,
  mcp_last_status_read_at = 0,
  mcp_capabilities_signature = nil,
  mcp_server_base_path = nil,
  pending_operation = nil, -- Operation Model 阶段1：待确认操作
  clarification_input_text = "",
  last_user_request = nil,
  last_retry_request = nil,
  last_retry_effective_request = nil,
  active_generation_message_ref = nil,
  active_generation_request = nil,
  active_generation_effective_request = nil,
  last_ai_operation = nil, -- 最近一次已执行的 AI 操作
  runtime_generated_registry = nil,
  conversation_epoch = 0,
  wait_started_at = 0,
  wait_kind = "",
  wait_user_request = "",
}

local RAI_INSTANCE_SECTION = "ReaperAI"
local RAI_INSTANCE_KEY = "active_instance"
local RAI_INSTANCE_TOKEN = tostring(math.floor(((reaper.time_precise and reaper.time_precise()) or os.clock()) * 1000000)) .. "_" .. tostring(math.random(100000, 999999))

local function claim_reaperai_instance()
  if reaper.SetExtState then
    reaper.SetExtState(RAI_INSTANCE_SECTION, RAI_INSTANCE_KEY, RAI_INSTANCE_TOKEN, false)
  end
end

local function is_current_reaperai_instance()
  if not reaper.GetExtState then return true end
  return reaper.GetExtState(RAI_INSTANCE_SECTION, RAI_INSTANCE_KEY) == RAI_INSTANCE_TOKEN
end

local function release_reaperai_instance()
  if reaper.DeleteExtState and is_current_reaperai_instance() then
    reaper.DeleteExtState(RAI_INSTANCE_SECTION, RAI_INSTANCE_KEY, false)
  end
end

local function current_conversation_epoch()
  return tonumber(state.conversation_epoch or 0) or 0
end

local function bump_conversation_epoch()
  state.conversation_epoch = current_conversation_epoch() + 1
  return state.conversation_epoch
end

local function is_current_conversation_epoch(epoch)
  return tonumber(epoch or -1) == current_conversation_epoch()
end

local function async_pipe_busy()
  if AsyncPipe and AsyncPipe.is_busy then
    local ok, busy = pcall(AsyncPipe.is_busy)
    return ok and busy == true
  end
  return false
end

local function cancel_async_requests()
  if AsyncPipe and AsyncPipe.cancel and (state.waiting or async_pipe_busy()) then
    pcall(AsyncPipe.cancel)
  end
end

local function reset_conversation_state(reason, opts)
  opts = opts or {}
  if opts.cancel_async ~= false then
    cancel_async_requests()
  end
  bump_conversation_epoch()
  state.messages = {}
  state.input_text = ""
  state.waiting = false
  Waiting.clear(state)
  state.async_response = nil
  state.pending_operation = nil
  state.last_ai_operation = nil
  state.last_user_request = nil
  state.last_retry_request = nil
  state.last_retry_effective_request = nil
  state.active_generation_message_ref = nil
  state.active_generation_request = nil
  state.active_generation_effective_request = nil
  state.clarification_input_text = ""
  state.runtime_generated_registry = nil
  state.audio_waiting = false
  state.audio_pending_count = 0
  state.audio_status = "就绪"
  state.audio_wait_kind = ""
  state.audio_started_at = 0
  state.chat_stream_active = false
  state.stream_typewriter_update = nil
  state.scroll = true
  if opts.status then
    state.status = opts.status
  elseif reason == "window_close" then
    state.status = "窗口已关闭"
  elseif reason == "exit_execution" then
    state.status = "已退出执行"
  else
    state.status = state.exec_mode and "对话已清除（执行模式）" or "对话已清除"
  end
  return true
end

local function stop_stale_reaperai_instance()
  reset_conversation_state("stale_instance", { status = "旧会话已停止" })
  state.ctx = nil
end

local function apply_mcp_status_snapshot(snapshot)
  if not snapshot then return end

  state.mcp_real_connected = snapshot.ok == true
  state.mcp_real_pid = snapshot.pid
  state.mcp_real_endpoint_count = snapshot.ok and (snapshot.endpoint_count or 0) or 0
  state.mcp_last_check_text = snapshot.ok and "已连接" or (snapshot.port_open and "端口占用但 ping 失败" or "未连接")
  state.mcp_status_detail = snapshot.detail or ""

  if snapshot.ok then
    local caps_signature = tostring(snapshot.pid or "") .. "|" .. tostring(snapshot.endpoint_count or 0)
    if state.mcp_capabilities and state.mcp_capabilities_signature == caps_signature then
      return
    end

    local endpoints_resp = read_mcp_server_file("mcp_server_endpoints.json")
    if endpoints_resp then
      local caps_text, endpoint_count = MCP.build_capabilities_text(endpoints_resp)
      local real_count = tonumber(snapshot.endpoint_count or 0) or 0
      if real_count <= 0 then real_count = tonumber(endpoint_count or 0) or 0 end
      state.mcp_endpoint_count = real_count
      state.mcp_real_endpoint_count = real_count
      if caps_text then
        state.mcp_capabilities = caps_text
      end
      state.mcp_capabilities_signature = caps_signature
    else
      state.mcp_endpoint_count = snapshot.endpoint_count or state.mcp_endpoint_count or 0
    end
  elseif not state.mcp_start_pending then
    state.mcp_capabilities_signature = nil
    state.mcp_endpoint_count = 0
  end
end

local function get_mcp_connection_diagnostics()
  apply_mcp_status_snapshot(read_mcp_status_snapshot())

  local lines = {"=== MCP 真实连接诊断 ==="}
  table.insert(lines, "UI状态: exec_mode=" .. tostring(state.exec_mode) .. ", mcp_running=" .. tostring(state.mcp_running) .. ", mcp_status=" .. tostring(state.mcp_status))
  table.insert(lines, "MCP地址: " .. tostring(MCP.base_url or CONFIG.mcp_url or ""))
  table.insert(lines, "真实 /ping: " .. (state.mcp_real_connected and "已连接" or "未连接"))
  table.insert(lines, "真实 endpoint: " .. tostring(state.mcp_real_endpoint_count or 0) .. " 个")
  table.insert(lines, "8765监听PID: " .. tostring(state.mcp_real_pid or "无"))
  table.insert(lines, "最近检测: " .. tostring(state.mcp_last_check_text or "未检测"))
  if state.mcp_status_detail and state.mcp_status_detail ~= "" then
    table.insert(lines, "最近详情: " .. tostring(state.mcp_status_detail))
  end
  table.insert(lines, "状态文件: " .. tostring((read_mcp_status_snapshot() or {}).path or "未找到"))
  table.insert(lines, "后台启动日志: " .. tostring(read_mcp_launch_log()))
  local shutdown_log = read_mcp_shutdown_log()
  if shutdown_log then
    table.insert(lines, "后台关闭日志: " .. shutdown_log:gsub("[\r\n]+", " "))
  end
  table.insert(lines, "说明: 真实连接来自后台探针状态文件；UI状态只是界面模式，不作为连接证明。")
  table.insert(lines, "")
  return table.concat(lines, "\n")
end

local ProjectContext = ContextModule.create({
  get_mcp_connection_diagnostics = get_mcp_connection_diagnostics,
})

local function read_text_file(path, max_chars)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a") or ""
  f:close()
  if max_chars and #content > max_chars then
    return content:sub(1, max_chars)
  end
  return content
end

local function file_exists(path)
  local f = io.open(path, "r")
  if not f then return false end
  f:close()
  return true
end

local function json_number_field(content, key)
  return tonumber(tostring(content or ""):match('"' .. tostring(key) .. '"%s*:%s*(%d+)'))
end

local function json_string_field(content, key)
  local value = tostring(content or ""):match('"' .. tostring(key) .. '"%s*:%s*"([^"]*)"')
  if not value then return nil end
  return value
    :gsub("\\n", "\n")
    :gsub("\\r", "\r")
    :gsub("\\t", "\t")
    :gsub('\\"', '"')
    :gsub("\\\\", "\\")
end

local function json_bool_field(content, key)
  local value = tostring(content or ""):match('"' .. tostring(key) .. '"%s*:%s*(true)')
  if value then return true end
  value = tostring(content or ""):match('"' .. tostring(key) .. '"%s*:%s*(false)')
  if value then return false end
  return nil
end

local function normalize_resource_path(path)
  path = tostring(path or ""):gsub("/", "\\"):gsub("\\+$", ""):lower()
  return path
end

local function capability_file_status(kind)
  local filenames = kind == "api"
    and { "reaper_api_inventory.json", "reaper_api_whitelist.json" }
    or { "reaper_action_inventory.json" }
  local path = RAI_MODULE_DIR .. filenames[1]
  local content = nil
  for _, filename in ipairs(filenames) do
    local candidate = RAI_MODULE_DIR .. filename
    content = read_text_file(candidate, 65536)
    if content ~= nil then
      path = candidate
      break
    end
  end
  local exists = content ~= nil
  local count = 0
  local resource_path = ""
  local local_match = true
  local portable = false
  if exists then
    if kind == "api" then
      count = json_number_field(content, "api_count") or json_number_field(content, "available_count") or 0
    else
      count = json_number_field(content, "action_count") or 0
    end
    portable = json_bool_field(content, "portable") == true
    resource_path = json_string_field(content, "reaper_resource_path") or ""
    if resource_path ~= "" and not portable and reaper and reaper.GetResourcePath then
      local_match = normalize_resource_path(resource_path) == normalize_resource_path(reaper.GetResourcePath())
    end
  end
  return {
    exists = exists,
    valid = exists and local_match,
    path = path,
    count = count,
    resource_path = resource_path,
    portable = portable,
    local_match = local_match,
    needs_refresh = exists and not local_match,
    generated_at = exists and (json_string_field(content, "generated_at") or "") or "",
  }
end

local function get_local_capability_status(refresh)
  if refresh or not state.local_capability_status then
    local api = capability_file_status("api")
    local action = capability_file_status("action")
    state.local_capability_status = {
      api = api,
      action = action,
      ready = api.valid and action.valid,
      message = (api.valid and action.valid)
        and "本机能力已检测"
        or "建议检测本机 REAPER API 和 Action ID",
    }
  end
  return state.local_capability_status
end

local function run_probe_script(script_name, global_result_name)
  local path = RAI_MODULE_DIR .. "tools" .. RAI_PATH_SEP .. script_name
  if not file_exists(path) then
    return false, "未找到探测脚本: " .. tostring(path)
  end
  local old_silent = _G.REAPERAI_PROBE_SILENT
  _G.REAPERAI_PROBE_SILENT = true
  local ok, result = pcall(dofile, path)
  _G.REAPERAI_PROBE_SILENT = old_silent
  if not ok then
    return false, tostring(result)
  end
  if type(result) ~= "table" and global_result_name then
    result = _G[global_result_name]
  end
  if type(result) ~= "table" then
    return false, "探测脚本未返回结果"
  end
  return true, result
end

local function refresh_capability_state_message()
  local status = get_local_capability_status(true)
  local api_text = status.api.valid and ("API " .. tostring(status.api.count)) or "API 未检测"
  local action_text = status.action.valid and ("Action " .. tostring(status.action.count)) or "Action 未检测"
  return api_text .. " / " .. action_text
end

local function run_api_probe_from_ui()
  state.capability_probe_running = true
  state.status = "正在检测本机 REAPER API"
  local ok, result = run_probe_script("probe_reaper_api.lua", "REAPERAI_LAST_API_PROBE_RESULT")
  state.capability_probe_running = false
  if ok then
    local message = "API 检测完成: " .. tostring(result.api_count or result.available_count or 0) .. " 个可用 API"
    state.capability_probe_last_message = message
    state.status = message
    get_local_capability_status(true)
    return true, message
  end
  state.capability_probe_last_message = "API 检测失败: " .. tostring(result)
  state.status = state.capability_probe_last_message
  return false, state.capability_probe_last_message
end

local function run_action_probe_from_ui()
  state.capability_probe_running = true
  state.status = "正在检测本机 Action ID"
  local ok, result = run_probe_script("probe_reaper_actions.lua", "REAPERAI_LAST_ACTION_PROBE_RESULT")
  state.capability_probe_running = false
  if ok then
    local message = "Action 检测完成: " .. tostring(result.action_count or 0) .. " 个 Action"
    state.capability_probe_last_message = message
    state.status = message
    get_local_capability_status(true)
    return true, message
  end
  state.capability_probe_last_message = "Action 检测失败: " .. tostring(result)
  state.status = state.capability_probe_last_message
  return false, state.capability_probe_last_message
end

local function run_all_capability_probes_from_ui()
  local api_ok, api_msg = run_api_probe_from_ui()
  local action_ok, action_msg = run_action_probe_from_ui()
  local summary = refresh_capability_state_message()
  local ok = api_ok and action_ok
  state.capability_probe_last_message = ok and ("本机能力检测完成: " .. summary) or ("本机能力检测未完全完成: " .. tostring(api_msg) .. " / " .. tostring(action_msg))
  state.status = state.capability_probe_last_message
  return ok, state.capability_probe_last_message
end

-- ============================================
-- 意图映射表（L1/L2 层级）
-- ============================================
local INTENT_ACTIONS = {
  ["CREATE_TRACK"] = {cmd = 40001, desc = "创建新轨道"},
  ["DELETE_TRACK"] = {cmd = 40006, desc = "删除选中轨道"},
  ["MUTE_TRACK"] = {cmd = 40705, desc = "静音选中轨道"},
  ["SOLO_TRACK"] = {cmd = 40706, desc = "独奏选中轨道"},
  ["PLAY"] = {cmd = 1007, desc = "播放"},
  ["STOP"] = {cmd = 1016, desc = "停止"},
  ["PAUSE"] = {cmd = 1008, desc = "暂停"},
  ["RECORD"] = {cmd = 1013, desc = "录音"},
}

-- ============================================
-- 前向声明 (解决局部函数调用顺序问题)
-- ============================================
local parse_response_content
local execute_intent
local execute_intent_chain
local execute_script
local execute_lua_sandbox
local execute_mcp_lua
local queue_operation_for_confirmation
local submit_script_preflight_repair_request
local submit_operation_repair_request
local execute_pending_operation
local cancel_pending_operation
local operation_has_internal_endpoint_error
local send_request

local function set_audio_status(text)
  state.audio_status = tostring(text or "")
  state.audio_waiting = (state.audio_pending_count or 0) > 0
end
local render_operation_cards
local parse_executable_steps
local execute_operation_parts
local preflight_operation_steps
local user_request_mentions_generated_reference
local submit_pending_clarification_answer

-- ============================================
-- 配置管理
-- ============================================
local function config_file()
  return reaper.GetResourcePath() .. "/ReaperAI_config.txt"
end

local function path_join(a, b)
  a = tostring(a or ""):gsub("/", "\\"):gsub("\\+$", "")
  b = tostring(b or ""):gsub("^[/\\]+", "")
  if a == "" then return b end
  if b == "" then return a end
  return a .. "\\" .. b
end

local function path_dirname(path)
  path = tostring(path or ""):gsub("/", "\\")
  return path:match("^(.*)\\[^\\]+$") or ""
end

local function current_project_file_path()
  if not (reaper and reaper.EnumProjects) then return "" end
  local ok, first, second = pcall(reaper.EnumProjects, -1, "")
  if not ok then return "" end
  if type(second) == "string" and second ~= "" then return second end
  if type(first) == "string" and first ~= "" then return first end
  return ""
end

local function elevenlabs_output_dir()
  local project_file = current_project_file_path()
  local project_dir = path_dirname(project_file)
  if project_dir ~= "" then
    return path_join(project_dir, "ReaperAI Media")
  end
  local resource_path = (reaper and reaper.GetResourcePath and reaper.GetResourcePath()) or ""
  return path_join(path_join(resource_path, "ReaperAI"), "GeneratedAudio")
end

local function config_one_line(value)
  value = tostring(value or "")
  value = value:gsub("[\r\n]", "")
  return value
end

local LlmSettings = {}
local ElevenVoiceSettings = {}

function LlmSettings.split_config_list(value)
  local items = {}
  for raw_item in tostring(value or ""):gmatch("[^,]+") do
    local item = raw_item:gsub("^%s+", ""):gsub("%s+$", "")
    if item ~= "" then table.insert(items, item) end
  end
  return items
end

function LlmSettings.encode_recent_models()
  local parts = {}
  for _, item in ipairs(state.llm_recent_models or {}) do
    local provider_id = config_one_line(item.provider_id or "")
    local model_id = config_one_line(item.id or "")
    if provider_id ~= "" and model_id ~= "" then
      table.insert(parts, provider_id .. "|" .. model_id)
    end
  end
  return table.concat(parts, ",")
end

function LlmSettings.decode_recent_models(value)
  local recent = {}
  for _, item in ipairs(LlmSettings.split_config_list(value)) do
    local provider_id, model_id = item:match("^([^|]+)|(.+)$")
    if provider_id and model_id and model_id ~= "" then
      table.insert(recent, { provider_id = provider_id, id = model_id })
    end
  end
  state.llm_recent_models = recent
end

function LlmSettings.remember_model(model_id, provider_id)
  model_id = tostring(model_id or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if model_id == "" then return end
  provider_id = tostring(provider_id or state.llm_provider_id or "")
  if provider_id == "" then provider_id = "custom" end

  local recent = {}
  table.insert(recent, { provider_id = provider_id, id = model_id })
  for _, item in ipairs(state.llm_recent_models or {}) do
    if not (item.provider_id == provider_id and item.id == model_id) then
      table.insert(recent, item)
    end
    if #recent >= 10 then break end
  end
  state.llm_recent_models = recent
end

local function sync_llm_provider_from_config()
  local provider = LlmProviders.detect_provider(CONFIG.llm_url, CONFIG.llm_model)
  state.llm_provider_id = (provider and provider.id) or "custom"
end

local function save_config()
  LlmSettings.remember_model(CONFIG.llm_model, state.llm_provider_id)
  local path = config_file()
  local f = io.open(path, "w")
  if not f then
    return false, "无法写入配置文件: " .. tostring(path)
  end

  f:write(table.concat({
    "# ReaperAI v1.0.3 配置文件",
    "# 格式: KEY=VALUE",
    "# 现在推荐在 ReaperAI 设置面板中编辑，文件仅作为本地存储。",
    "# 支持配置项: LLM_PROVIDER, LLM_API_KEY, LLM_API_URL, LLM_MODEL, LLM_RECENT_MODELS, ELEVENLABS_API_KEY",
    "",
    "LLM_API_URL=" .. config_one_line(CONFIG.llm_url),
    "LLM_API_KEY=" .. config_one_line(CONFIG.llm_key),
    "LLM_MODEL=" .. config_one_line(CONFIG.llm_model),
    "LLM_PROVIDER=" .. config_one_line(state.llm_provider_id),
    "LLM_RECENT_MODELS=" .. LlmSettings.encode_recent_models(),
    "",
    "# ElevenLabs 语音/音效生成 (可选)",
    "# 推荐使用生成音频页；快捷方式: 11vox 语气说 台词 / 11sfx 音效描述",
    "ELEVENLABS_API_KEY=" .. config_one_line(CONFIG.elevenlabs_key),
    "",
  }, "\n"))
  f:close()
  return true, "配置已保存"
end

local function load_config()
  local f = io.open(config_file(), "r")
  if not f then return end
  
  local content = f:read("*a") or ""
  f:close()
  
  -- 检测是否是旧版三行格式（第一行是URL）
  local first_line = content:match("^([^\n]*)")
  local is_old_format = first_line and first_line:match("^https?://")
  
  if is_old_format then
    -- 旧版格式：第1行URL，第2行Key，第3行模型
    local lines = {}
    for line in content:gmatch("([^\n]*)\n?") do
      table.insert(lines, line)
    end
    CONFIG.llm_url   = lines[1] or CONFIG.llm_url
    CONFIG.llm_key   = lines[2] or CONFIG.llm_key
    CONFIG.llm_model = lines[3] or CONFIG.llm_model
    CONFIG.elevenlabs_key = ""
    
    -- 自动迁移到新版键值对格式
    save_config()
  else
    -- 新版键值对格式
    for line in content:gmatch("([^\n]*)\n?") do
      local key, value = line:match("^([A-Za-z_]+)=(.*)$")
      if key and value then
        if key == "LLM_API_URL" then
          CONFIG.llm_url = value
        elseif key == "LLM_API_KEY" then
          CONFIG.llm_key = value
        elseif key == "LLM_MODEL" then
          CONFIG.llm_model = value
        elseif key == "LLM_PROVIDER" then
          state.llm_provider_id = value
        elseif key == "LLM_RECENT_MODELS" then
          LlmSettings.decode_recent_models(value)
        elseif key == "ELEVENLABS_API_KEY" then
          CONFIG.elevenlabs_key = value
        -- v1.0+ ELEVENLABS_VOICE_ID 已移除，Voice 由 worker 智能选择
        end
      end
    end
  end
  sync_llm_provider_from_config()
  LlmSettings.remember_model(CONFIG.llm_model, state.llm_provider_id)
end

local function open_config_editor()
  state.show_settings = true
  state.show_audio = false
  state.status = "请在设置面板编辑配置"
end

function LlmSettings.parse_models_worker_response(response)
  if not response or response == "" then
    return nil, "空响应"
  end
  if tostring(response):match("^%[ERROR%]") then
    return nil, tostring(response):gsub("^%[ERROR%]%s*", "")
  end
  if json_bool_field(response, "success") == false then
    return nil, json_string_field(response, "error") or "刷新模型列表失败"
  end

  local content = json_string_field(response, "content")
  if not content or content == "" then
    content = tostring(response or "")
  end

  local models, seen = {}, {}
  for line in content:gmatch("[^\r\n]+") do
    local id = line:gsub("^%s+", ""):gsub("%s+$", "")
    if id ~= "" and not seen[id] then
      seen[id] = true
      table.insert(models, { id = id, label = id, group = "刷新结果", tags = { "remote" }, recommended = false })
    end
  end
  if #models == 0 then
    return nil, "Models API 响应中没有 model id"
  end
  return models
end

function LlmSettings.refresh_models()
  local provider = LlmProviders.provider_by_id(state.llm_provider_id)
  if not provider then
    state.llm_model_refresh_message = "未选择 Provider"
    return false, state.llm_model_refresh_message
  end

  if provider.supports_models == false then
    state.llm_dynamic_models_by_provider[provider.id] = nil
    state.llm_model_refresh_message = "当前 Provider 未标记支持 /models，已使用内置模型注册表"
    state.status = state.llm_model_refresh_message
    return true, state.llm_model_refresh_message
  end

  if not AsyncPipe or type(AsyncPipe.fetch_models) ~= "function" then
    state.llm_model_refresh_message = "异步模块未加载，无法刷新模型列表"
    state.status = state.llm_model_refresh_message
    return false, state.llm_model_refresh_message
  end

  local models_url = LlmProviders.models_url_from_base(CONFIG.llm_url)
  if models_url == "" then
    state.llm_model_refresh_message = "Base URL 为空，无法刷新模型列表"
    state.status = state.llm_model_refresh_message
    return false, state.llm_model_refresh_message
  end

  local provider_id = provider.id
  state.llm_models_refreshing = true
  state.llm_model_refresh_message = "正在刷新模型列表: " .. models_url
  state.status = state.llm_model_refresh_message

  local req_id, err = AsyncPipe.fetch_models(models_url, CONFIG.llm_key or "", function(response, error)
    state.llm_models_refreshing = false
    if error then
      state.llm_dynamic_models_by_provider[provider_id] = nil
      state.llm_model_refresh_message = "远程模型列表不可用，已使用内置模型注册表: " .. tostring(error)
      state.status = state.llm_model_refresh_message
      return
    end

    local models, parse_err = LlmSettings.parse_models_worker_response(response)
    if not models then
      state.llm_dynamic_models_by_provider[provider_id] = nil
      state.llm_model_refresh_message = "远程模型列表不可用，已使用内置模型注册表: " .. tostring(parse_err)
      state.status = state.llm_model_refresh_message
      return
    end

    state.llm_dynamic_models_by_provider[provider_id] = models
    state.llm_model_refresh_message = "已刷新 " .. tostring(#models) .. " 个模型"
    state.status = state.llm_model_refresh_message
  end)

  if not req_id then
    state.llm_models_refreshing = false
    state.llm_dynamic_models_by_provider[provider_id] = nil
    state.llm_model_refresh_message = "远程模型列表不可用，已使用内置模型注册表: " .. tostring(err)
    state.status = state.llm_model_refresh_message
    return false, state.llm_model_refresh_message
  end

  return true, state.llm_model_refresh_message
end

function ElevenVoiceSettings.parse_worker_response(response)
  if not response or response == "" then
    return nil, "空响应"
  end
  if tostring(response):match("^%[ERROR%]") then
    return nil, tostring(response):gsub("^%[ERROR%]%s*", "")
  end
  if json_bool_field(response, "success") == false then
    return nil, json_string_field(response, "error") or "刷新 ElevenLabs 声线失败"
  end

  local content = json_string_field(response, "content")
  if not content or content == "" then
    content = tostring(response or "")
  end

  local voices = ElevenLabs.parse_voice_lines(content)
  if #voices == 0 then
    return nil, "ElevenLabs 声线响应中没有可用声线"
  end
  return voices, {
    message = json_string_field(response, "message") or "",
    fallback = json_bool_field(response, "fallback") == true,
  }
end

function ElevenVoiceSettings.refresh_voices()
  local elevenlabs_key = CONFIG.elevenlabs_key or ""
  if elevenlabs_key == "" or elevenlabs_key == "在此填入 ElevenLabs API Key" then
    state.audio_vox_dynamic_voices = {}
    state.audio_vox_voice_id = ""
    state.audio_vox_voice_refresh_message = "请先填写 ElevenLabs Key"
    state.status = state.audio_vox_voice_refresh_message
    return false, state.audio_vox_voice_refresh_message
  end

  if not AsyncPipe or type(AsyncPipe.fetch_elevenlabs_voices) ~= "function" then
    state.audio_vox_dynamic_voices = {}
    state.audio_vox_voice_id = ""
    state.audio_vox_voice_refresh_message = "异步模块未更新，无法检测声线"
    state.status = state.audio_vox_voice_refresh_message
    return false, state.audio_vox_voice_refresh_message
  end

  state.audio_vox_voices_refreshing = true
  state.audio_vox_voice_refresh_message = "正在检测 ElevenLabs 可用声线"
  state.status = state.audio_vox_voice_refresh_message

  local req_id, err = AsyncPipe.fetch_elevenlabs_voices(elevenlabs_key, function(response, error)
    state.audio_vox_voices_refreshing = false
    if error then
      state.audio_vox_dynamic_voices = {}
      state.audio_vox_voice_id = ""
      state.audio_vox_voice_refresh_message = "声线检测失败: " .. tostring(error)
      state.status = state.audio_vox_voice_refresh_message
      return
    end

    local voices, meta = ElevenVoiceSettings.parse_worker_response(response)
    if not voices then
      state.audio_vox_dynamic_voices = {}
      state.audio_vox_voice_id = ""
      state.audio_vox_voice_refresh_message = "没有检测到可用声线: " .. tostring(meta)
      state.status = state.audio_vox_voice_refresh_message
      return
    end

    state.audio_vox_dynamic_voices = voices
    local selected = ElevenLabs.voice_by_id(state.audio_vox_voice_id, voices)
    if state.audio_vox_voice_id ~= "" and (not selected or not ElevenLabs.voice_matches_gender(selected, state.audio_vox_gender)) then
      state.audio_vox_voice_id = ""
    end

    local message = "已检测到 " .. tostring(#voices) .. " 条可用声线"
    if meta and meta.message ~= "" then message = meta.message end
    state.audio_vox_voice_refresh_message = message
    state.status = state.audio_vox_voice_refresh_message
  end)

  if not req_id then
    state.audio_vox_voices_refreshing = false
    state.audio_vox_dynamic_voices = {}
    state.audio_vox_voice_id = ""
    state.audio_vox_voice_refresh_message = "声线检测启动失败: " .. tostring(err)
    state.status = state.audio_vox_voice_refresh_message
    return false, state.audio_vox_voice_refresh_message
  end

  return true, state.audio_vox_voice_refresh_message
end

function LlmSettings.test_connection()
  if CONFIG.llm_key == "" or CONFIG.llm_key == "在此填入你的 API Key" then
    state.llm_test_message = "请先填写 API Key"
    state.status = state.llm_test_message
    return false, state.llm_test_message
  end

  if CONFIG.llm_model == "" then
    state.llm_test_message = "请先填写 Model Name"
    state.status = state.llm_test_message
    return false, state.llm_test_message
  end

  if not AsyncPipe or type(AsyncPipe.send_request) ~= "function" then
    state.llm_test_message = "异步模块未加载，无法测试连接"
    state.status = state.llm_test_message
    return false, state.llm_test_message
  end

  local messages = {
    { role = "system", content = "Reply with OK." },
    { role = "user", content = "ping" },
  }

  state.llm_test_running = true
  state.llm_test_message = "正在测试连接..."
  state.status = state.llm_test_message

  local req_id, err = AsyncPipe.send_request(CONFIG.llm_url, CONFIG.llm_key, CONFIG.llm_model, messages, function(response, error)
    state.llm_test_running = false
    if error then
      state.llm_test_message = "测试连接失败: " .. tostring(error)
      state.status = state.llm_test_message
      return
    end
    if tostring(response or ""):match("^%[ERROR%]") then
      state.llm_test_message = "测试连接失败: " .. tostring(response):gsub("^%[ERROR%]%s*", "")
      state.status = state.llm_test_message
      return
    end
    if json_bool_field(response, "success") == false then
      state.llm_test_message = "测试连接失败: " .. tostring(json_string_field(response, "error") or "未知错误")
      state.status = state.llm_test_message
      return
    end
    state.llm_test_message = "测试连接成功"
    state.status = state.llm_test_message
    LlmSettings.remember_model(CONFIG.llm_model, state.llm_provider_id)
  end)

  if not req_id then
    state.llm_test_running = false
    state.llm_test_message = "测试连接失败: " .. tostring(err)
    state.status = state.llm_test_message
    return false, state.llm_test_message
  end

  return true, state.llm_test_message
end

-- ============================================
-- 获取工程上下文
-- ============================================
local function get_project_context()
  return ProjectContext.get_project_context()
end

-- ============================================
-- 获取选中信息（工程信息按钮与 prompt 注入）
-- ============================================
local function get_selection_context()
  return ProjectContext.get_selection_context()
end

-- ============================================
-- 初始化
-- ============================================
local function init()
  if state.ctx then return true end
  if not reaper.ImGui_CreateContext then
    reaper.ShowMessageBox("请安装 ReaImGui\\n（ReaPack → 搜索 ReaImGui → 安装）", "ReaperAI v1.0.3", 0)
    return false
  end
  state.ctx = reaper.ImGui_CreateContext("ReaperAI")
  return state.ctx ~= nil
end

-- ============================================
-- JSON 构建
-- ============================================
local function esc(s)
  if not s then return "" end
  s = tostring(s)
  s = s:gsub("\\", "\\\\")
  s = s:gsub('"', '\\"')
  s = s:gsub("\n", "\\n")
  s = s:gsub("\r", "")
  s = s:gsub("\t", "  ")
  return s
end

local function strip_intent_block_for_display(text)
  text = tostring(text or "")
  text = text:gsub("%s*%[INTENT%].-%[/INTENT%]%s*", "\n")
  text = Operation.strip_mcp_call_blocks(text, "\n")
  text = text:gsub("%s*%[SCRIPT%].-%[/SCRIPT%]%s*", "\n")
  text = text:gsub("^\n+", ""):gsub("\n+$", "")
  if text == "" then
    return "已生成操作卡，请在下方确认或澄清。"
  end
  return text
end

function reaperai_stream_take_utf8_chars(text, max_chars)
  text = tostring(text or "")
  max_chars = math.max(0, math.floor(tonumber(max_chars or 0) or 0))
  if max_chars <= 0 or text == "" then return "", text, 0 end

  local i = 1
  local taken = 0
  local len = #text
  while i <= len and taken < max_chars do
    local b = text:byte(i) or 0
    local step = 1
    if b >= 0xF0 then
      step = 4
    elseif b >= 0xE0 then
      step = 3
    elseif b >= 0xC0 then
      step = 2
    end
    if i + step - 1 > len then break end
    i = i + step
    taken = taken + 1
  end

  if taken <= 0 then return "", text, 0 end
  return text:sub(1, i - 1), text:sub(i), taken
end

function reaperai_mark_retryable_message(msg, request_text, effective_request)
  if not msg then return nil end
  local request = tostring(request_text or effective_request or state.last_user_request or "")
  local effective = tostring(effective_request or request or "")
  if request == "" then return msg end
  msg.retryable = true
  msg.request_text = request
  msg.effective_user_request = effective ~= "" and effective or request
  state.last_retry_request = request
  state.last_retry_effective_request = msg.effective_user_request
  return msg
end

function reaperai_message_index_by_ref(ref)
  if not ref then return nil end
  for i, msg in ipairs(state.messages or {}) do
    if msg == ref then return i end
  end
  return nil
end

function reaperai_apply_tool_call_event(msg, event)
  if not msg or not event then return end
  msg.tool_calls = msg.tool_calls or {}
  local key = tostring(event.index or "")
  if key == "" then key = tostring(event.id or "") end
  if key == "" then key = tostring(#msg.tool_calls + 1) end

  local tool = nil
  for _, item in ipairs(msg.tool_calls) do
    if tostring(item.key or "") == key then
      tool = item
      break
    end
  end
  if not tool then
    tool = { key = key, name = "", arguments = "", call_type = tostring(event.call_type or "tool") }
    table.insert(msg.tool_calls, tool)
  end

  local name = tostring(event.name or "")
  local arguments = tostring(event.arguments or "")
  if name ~= "" then tool.name = name end
  if arguments ~= "" then tool.arguments = tostring(tool.arguments or "") .. arguments end
  tool.id = tostring(event.id or tool.id or "")
  tool.call_type = tostring(event.call_type or tool.call_type or "tool")
  msg.advanced_status = "工具调用: " .. ((tool.name and tool.name ~= "") and tool.name or tool.call_type)
end

function reaperai_finish_reason_label(reason)
  reason = tostring(reason or "")
  if reason == "" then return "" end
  if reason == "stop" then return "生成完成" end
  if reason == "length" then return "达到长度上限" end
  if reason == "tool_calls" then return "等待工具调用" end
  if reason == "function_call" then return "等待函数调用" end
  if reason == "content_filter" then return "内容被过滤" end
  return "结束原因: " .. reason
end

function reaperai_cancel_generation()
  local request_text = tostring(state.active_generation_request or state.last_retry_request or state.last_user_request or "")
  local effective_request = tostring(state.active_generation_effective_request or state.last_retry_effective_request or request_text)
  local msg = state.active_generation_message_ref

  bump_conversation_epoch()
  cancel_async_requests()

  if msg and reaperai_message_index_by_ref(msg) then
    msg.streaming = false
    msg.reasoning_streaming = false
    msg.cancelled = true
    msg.stream_status = "已取消"
    if tostring(msg.content or "") == "" then
      msg.content = "已取消生成"
    end
    reaperai_mark_retryable_message(msg, request_text, effective_request)
  else
    table.insert(state.messages, {
      role = "assistant",
      content = "已取消生成",
      is_system = true
    })
  end

  state.waiting = false
  Waiting.clear(state)
  if state.pending_operation and state.pending_operation.placeholder then
    state.pending_operation = nil
  end
  if state.audio_waiting then
    state.audio_pending_count = 0
    state.audio_waiting = false
    state.audio_status = "已取消请求"
  end
  state.chat_stream_active = false
  state.stream_typewriter_update = nil
  state.active_generation_message_ref = nil
  state.active_generation_request = nil
  state.active_generation_effective_request = nil
  state.status = "已取消生成"
  state.scroll = true
  return true
end

function reaperai_retry_message(message_index)
  if state.waiting or async_pipe_busy() then
    state.status = "请等待当前请求完成"
    return false
  end

  local idx = tonumber(message_index or 0)
  local msg = idx and idx > 0 and state.messages[idx] or nil
  local request_text = tostring((msg and msg.request_text) or state.last_retry_request or state.last_user_request or "")
  local effective_request = tostring((msg and msg.effective_user_request) or state.last_retry_effective_request or request_text)

  if request_text == "" then
    state.status = "没有可重试的请求"
    return false
  end

  if state.pending_operation and not state.pending_operation.needs_clarification then
    table.insert(state.messages, {
      role = "assistant",
      content = "请先确认或取消当前待执行操作，再重试请求。",
      is_system = true
    })
    state.status = "已有待确认操作"
    state.scroll = true
    return false
  end

  if msg and msg.role == "assistant" then
    table.remove(state.messages, idx)
  end
  table.insert(state.messages, { role = "user", content = request_text })
  state.scroll = true
  return send_request(request_text, { effective_user_request = effective_request })
end

function reaperai_begin_llm_stream_display(opts)
  opts = opts or {}
  local request_epoch = opts.request_epoch
  local status_text = tostring(opts.status_text or "正在显示执行计划...")
  local request_text = tostring(opts.request_text or state.last_user_request or "")
  local effective_request = tostring(opts.effective_user_request or request_text)
  local stream = {
    msg_index = nil,
    msg_ref = nil,
    after_finish = opts.after_finish,
    raw_text = "",
    visible_text = "",
    pending_text = "",
    final_text = nil,
    done = false,
    error_seen = false,
    reasoning_pending_text = "",
    reasoning_visible_text = "",
    reasoning_reveal_credit = 0,
    reasoning_done_requested = false,
    reveal_credit = 0,
    last_update = (reaper.time_precise and reaper.time_precise()) or os.clock(),
  }

  function stream:is_current()
    return request_epoch == nil or is_current_conversation_epoch(request_epoch)
  end

  function stream:current_message()
    if self.msg_ref then
      for i, msg in ipairs(state.messages) do
        if msg == self.msg_ref then
          self.msg_index = i
          return msg
        end
      end
      return nil
    end
    if self.msg_index and state.messages[self.msg_index] then
      self.msg_ref = state.messages[self.msg_index]
      return state.messages[self.msg_index]
    end
    return nil
  end

  function stream:message()
    local existing = self:current_message()
    if existing then return existing end
    table.insert(state.messages, {
      role = "assistant",
      content = "",
      streaming = true,
      stream_status = "正在连接",
      request_text = request_text,
      effective_user_request = effective_request,
    })
    self.msg_index = #state.messages
    self.msg_ref = state.messages[self.msg_index]
    state.active_generation_message_ref = self.msg_ref
    state.active_generation_request = request_text
    state.active_generation_effective_request = effective_request
    state.scroll = true
    return state.messages[self.msg_index]
  end

  function stream:stop()
    local msg = self:current_message()
    if msg then
      msg.streaming = false
    end
    if state.active_generation_message_ref == self.msg_ref then
      state.active_generation_message_ref = nil
      state.active_generation_request = nil
      state.active_generation_effective_request = nil
    end
    if state.stream_typewriter_update == self.update_callback then
      state.chat_stream_active = false
      state.stream_typewriter_update = nil
    end
  end

  function stream:remove()
    if self.msg_ref then
      for i, msg in ipairs(state.messages) do
        if msg == self.msg_ref then
          table.remove(state.messages, i)
          break
        end
      end
    elseif self.msg_index and state.messages[self.msg_index] then
      table.remove(state.messages, self.msg_index)
    end
    self.msg_index = nil
    self.msg_ref = nil
    self:stop()
  end

  function stream:finish_display()
    local msg = self:message()
    msg.content = self.final_text or self.visible_text or msg.content or ""
    msg.streaming = false
    msg.reasoning_streaming = false
    if tostring(msg.reasoning_content or "") ~= "" then
      msg.reasoning_collapsed = true
    end
    msg.stream_status = reaperai_finish_reason_label(msg.finish_reason)
    reaperai_mark_retryable_message(msg, request_text, effective_request)
    if state.active_generation_message_ref == self.msg_ref then
      state.active_generation_message_ref = nil
      state.active_generation_request = nil
      state.active_generation_effective_request = nil
    end
    if state.stream_typewriter_update == self.update_callback then
      state.chat_stream_active = false
      state.stream_typewriter_update = nil
    end
    local after_finish = self.after_finish
    self.after_finish = nil
    if type(after_finish) == "function" then
      pcall(after_finish, msg, self)
    end
    state.scroll = true

    if AsyncPipe and not AsyncPipe.is_busy() then
      state.waiting = false
      Waiting.clear(state)
      if state.pending_operation then
        state.status = Waiting.operation_status(state.pending_operation, state.status)
      else
        state.status = state.exec_mode and "就绪" or "就绪（咨询模式）"
      end
    end
  end

  function stream:update()
    if not self:is_current() then
      self:stop()
      return
    end
    local active_msg = self:current_message()
    if not active_msg then return end

    local now = (reaper.time_precise and reaper.time_precise()) or os.clock()
    local dt = math.max(0, now - (self.last_update or now))
    self.last_update = now

    local had_reasoning = self.reasoning_pending_text ~= ""
      or self.reasoning_visible_text ~= ""
      or tostring(active_msg.reasoning_content or "") ~= ""
    if self.reasoning_pending_text ~= "" then
      self.reveal_credit = self.reveal_credit or 0
      self.reasoning_reveal_credit = math.min(80, (self.reasoning_reveal_credit or 0) + dt * 42)
      local want_reasoning = math.min(5, math.floor(self.reasoning_reveal_credit))
      if want_reasoning > 0 then
        local piece, rest, count = reaperai_stream_take_utf8_chars(self.reasoning_pending_text, want_reasoning)
        if count > 0 then
          self.reasoning_pending_text = rest
          self.reasoning_visible_text = self.reasoning_visible_text .. piece
          self.reasoning_reveal_credit = self.reasoning_reveal_credit - count
          local msg = self:current_message() or self:message()
          msg.reasoning_content = self.reasoning_visible_text
          msg.reasoning_streaming = true
          msg.reasoning_collapsed = false
          msg.stream_status = "正在思考..."
          state.status = "正在思考..."
          state.scroll = true
        end
      end
      if had_reasoning then
        return
      end
    elseif self.reasoning_done_requested and had_reasoning then
      local msg = self:current_message()
      if msg and tostring(msg.reasoning_content or "") ~= "" then
        msg.reasoning_streaming = false
        msg.reasoning_collapsed = true
      end
      self.reasoning_done_requested = false
      return
    end

    if self.pending_text ~= "" then
      local backlog = #self.pending_text
      local cps = 34
      local max_per_frame = 4
      if backlog > 1200 then
        cps = 180
        max_per_frame = 18
      elseif backlog > 500 then
        cps = 120
        max_per_frame = 12
      elseif backlog > 180 then
        cps = 72
        max_per_frame = 8
      end

      self.reveal_credit = math.min(80, (self.reveal_credit or 0) + dt * cps)
      local want = math.min(max_per_frame, math.floor(self.reveal_credit))
      if want > 0 then
        local piece, rest, count = reaperai_stream_take_utf8_chars(self.pending_text, want)
        if count > 0 then
          self.pending_text = rest
          self.visible_text = self.visible_text .. piece
          self.reveal_credit = self.reveal_credit - count
          local msg = self:current_message() or self:message()
          msg.content = self.visible_text
          msg.streaming = true
          msg.stream_status = status_text
          state.status = status_text
          state.scroll = true
        end
      end
    end

    if self.done and self.pending_text == "" and self.reasoning_pending_text == "" then
      self:finish_display()
    end
  end

  function stream:set_final(text)
    self.final_text = strip_intent_block_for_display(text)
    self.done = true
    if self.final_text:sub(1, #self.visible_text) == self.visible_text then
      self.pending_text = self.final_text:sub(#self.visible_text + 1)
    else
      self.visible_text = ""
      self.pending_text = self.final_text
      local msg = self:current_message()
      if msg then
        msg.content = ""
      end
    end
    self:update()
  end

  function stream:fail(message)
    self.error_seen = true
    self.pending_text = ""
    self.done = true
    self.final_text = nil
    local msg = self:message()
    msg.streaming = false
    msg.reasoning_streaming = false
    if tostring(msg.content or "") == "" then
      msg.content = "⚠️ " .. tostring(message or "请求失败")
    else
      msg.content = tostring(msg.content) .. "\n\n⚠️ " .. tostring(message or "请求失败")
    end
    msg.stream_status = "请求失败"
    reaperai_mark_retryable_message(msg, request_text, effective_request)
    self:stop()
    state.scroll = true
  end

  function stream:on_event(event)
    if not self:is_current() then return end
    event = event or {}
    local event_type = tostring(event.type or "")
    if event_type == "start" then
      local msg = self:message()
      msg.stream_status = "已连接"
    elseif event_type == "delta" then
      local delta = tostring(event.content or "")
      if delta ~= "" then
        self.reasoning_done_requested = true
        self.raw_text = self.raw_text .. delta
        self.pending_text = self.pending_text .. delta
        self:update()
      end
    elseif event_type == "reasoning_delta" then
      local delta = tostring(event.content or "")
      if delta ~= "" then
        local msg = self:message()
        self.reasoning_pending_text = self.reasoning_pending_text .. delta
        msg.reasoning_streaming = true
        msg.reasoning_collapsed = false
        msg.stream_status = "正在思考..."
        state.status = "正在思考..."
        self:update()
        state.scroll = true
      end
    elseif event_type == "tool_call" then
      local msg = self:message()
      reaperai_apply_tool_call_event(msg, event)
      state.status = msg.advanced_status or "正在处理工具调用..."
      state.scroll = true
    elseif event_type == "finish" then
      local msg = self:message()
      msg.finish_reason = tostring(event.finish_reason or "")
      msg.stream_status = reaperai_finish_reason_label(msg.finish_reason)
      self.reasoning_done_requested = true
      self:update()
      state.scroll = true
    elseif event_type == "done" then
      self.reasoning_done_requested = true
      self.raw_text = tostring(event.content or self.raw_text or "")
      self:set_final(self.raw_text)
    elseif event_type == "error" then
      self:fail(event.message or "请求失败")
    end
  end

  stream.update_callback = function()
    stream:update()
  end

  state.chat_stream_active = true
  state.stream_typewriter_update = stream.update_callback
  stream:message()
  return stream
end

local function append_stable_script_prompt(sys)
  return Prompt.append_stable_script_prompt(sys)
end

local function append_intent_contract_prompt(sys)
  if Prompt and type(Prompt.append_intent_contract_prompt) == "function" then
    return Prompt.append_intent_contract_prompt(sys)
  end
  return sys
end

local function append_capability_snapshot(sys, op, limit)
  local text = nil
  if CuratedCapabilityRegistry and type(CuratedCapabilityRegistry.registry_summary) == "function" then
    text = CuratedCapabilityRegistry.registry_summary(op or state.pending_operation or state.last_ai_operation, limit or 14)
  end
  if (not text or text == "") and state.mcp_capabilities and state.mcp_capabilities ~= "" then
    text = state.mcp_capabilities
  end
  if text and text ~= "" then
    return sys .. "\n\n[统一能力目录]\n" .. text
  end
  return sys
end

local function user_request_allows_history(user_msg)
  local text = tostring(user_msg or "")
  local lower = text:lower()
  local markers = {
    "继续", "接着", "沿用", "刚才", "上一步", "上一条", "上次", "之前", "这个", "这些", "它", "它们",
    "continue", "previous", "last step", "same", "again", "those", "that"
  }
  for _, marker in ipairs(markers) do
    if text:find(marker, 1, true) or lower:find(marker, 1, true) then return true end
  end
  return false
end

local function include_chat_history_for_request(user_msg)
  if not (state.exec_mode or state.mcp_running) then return true end
  return user_request_allows_history(user_msg)
end

local function append_turn_isolation_prompt(sys, include_history)
  if not (state.exec_mode or state.mcp_running) then return sys end
  sys = sys .. "\n\n[Turn Isolation]\n"
  if include_history then
    sys = sys .. "The user explicitly referenced previous context. You may use recent history only to resolve that reference, but the latest user message is still the command to execute.\n"
  else
    sys = sys .. "Treat the latest user message as a fresh execution request. Do not carry over, repeat, or combine previous operations unless the latest user message explicitly asks to continue or modify them.\n"
  end
  return sys
end

local function build_json(user_msg)
  local sys = CONFIG.system_prompt
  local include_history = include_chat_history_for_request(user_msg)
  
  -- 根据当前模式追加特定的执行指令
  if state.mcp_running then
    sys = sys .. "\n\n[当前模式: MCP服务器已连接]"
    -- 追加 MCP 功能列表（动态获取）
    sys = append_capability_snapshot(sys, state.pending_operation or state.last_ai_operation, 14)
    sys = sys .. "\n\n当 MCP 可用时，优先使用 [MCP_CALL:...] 格式调用上述操作。"
    sys = sys .. "不在 MCP 列表中的操作（如设置颜色、条件判断、复杂逻辑等），请使用 [SCRIPT]...[/SCRIPT] 格式包装 Lua 代码。两者可以混合使用。"
    sys = sys .. "播放/停止工程必须使用 [MCP_CALL:transport/play] 或 [MCP_CALL:transport/stop]，不要创建轨道或裸写 SCRIPT 代替。"
  elseif state.exec_mode then
    sys = sys .. "\n\n[当前模式: 本地执行模式 - MCP服务器未连接]"
    sys = sys .. "\n\n当前 MCP 服务器未连接，以下操作支持本地 Lua 执行: transport/play, transport/stop, track/create, track/delete, track/rename, track/set_volume, track/mute, track/solo, marker/add, marker/delete, region/delete。"
    sys = sys .. "系统会自动将上述 MCP 调用转换为本地 Lua 执行。其他操作（如音频分析、音效生成、批量导出等）需要连接 MCP 服务器。"
    sys = sys .. "不在本地支持列表中的操作，请使用 [SCRIPT]...[/SCRIPT] 格式包装 Lua 代码直接执行。"
    sys = sys .. "播放/停止工程必须使用 [MCP_CALL:transport/play] 或 [MCP_CALL:transport/stop]，不要创建轨道或裸写 SCRIPT 代替。"
  else
    sys = sys .. "\n\n[当前模式: 咨询模式]"
    sys = sys .. "\n只回答用户问题，不要输出 [SCRIPT]、[/SCRIPT]、[MCP_CALL:...] 或任何可执行标记。"
  end
  
  if state.exec_mode or state.mcp_running then
    sys = append_stable_script_prompt(sys)
    sys = append_intent_contract_prompt(sys)
    sys = append_turn_isolation_prompt(sys, include_history)
  end
  
  if CONFIG.inject_context then
    local ctx = get_project_context()
    state.last_proj_ctx = ctx
    sys = sys .. "\n\n" .. ctx

    -- v1.0 合并刷新功能：每次发送自动注入实时选中信息
    local sel_ctx = get_selection_context()
    state.last_selection_context = sel_ctx
    sys = sys .. "\n\n" .. sel_ctx
  end

  local p = {}
  table.insert(p, '{"model":"')
  table.insert(p, CONFIG.llm_model)
  table.insert(p, '","messages":[')
  table.insert(p, '{"role":"system","content":"')
  table.insert(p, esc(sys))
  table.insert(p, '"}')

  if include_history then
    local start = math.max(1, #state.messages - 19)
    for i = start, #state.messages do
      local m = state.messages[i]
      table.insert(p, ',{"role":"')
      table.insert(p, m.role)
      table.insert(p, '","content":"')
      table.insert(p, esc(m.content))
      table.insert(p, '"}')
    end
  end

  table.insert(p, ',{"role":"user","content":"')
  table.insert(p, esc(user_msg))
  table.insert(p, '"}]}')

  return table.concat(p)
end

-- ============================================
-- 发送 ElevenLabs 音频生成请求 (v1.0 新增)
-- ============================================
-- 复用 AsyncPipe.send_request()，传入 mode="elevenlabs"
local function send_elevenlabs_request(audio_input)
  if not AsyncPipe then
    state.status = "异步模块未加载，无法生成音频"
    set_audio_status(state.status)
    return false
  end
  
  local elevenlabs_key = CONFIG.elevenlabs_key or ""
  
  if elevenlabs_key == "" or elevenlabs_key == "在此填入 ElevenLabs API Key" then
    state.status = "请先设置 ElevenLabs API Key"
    set_audio_status(state.status)
    state.show_settings = true
    state.show_audio = false
    return false
  end

  local audio_req = ElevenLabs.normalize_request(audio_input)
  if audio_req.mode == "vox" and ElevenLabs.trim_text(audio_req.spoken_text) == "" then
    state.status = "请填写 VOX 台词"
    set_audio_status(state.status)
    return false
  elseif audio_req.mode == "sfx" and ElevenLabs.trim_text(audio_req.prompt) == "" then
    state.status = "请填写 SFX 描述"
    set_audio_status(state.status)
    return false
  end

  -- Worker 会从 config_file() 读取 LLM 配置；这里确保 UI 中的配置已落盘。
  pcall(save_config)
  audio_req.output_dir = elevenlabs_output_dir()
  
  local payload = ElevenLabs.request_json(audio_req)
  table.insert(state.messages, {
    role = "assistant",
    content = ElevenLabs.start_message(audio_req),
    is_system = true
  })
  
  -- v1.0+ api_url 参数在 elevenlabs 模式下承载 config.txt 路径（worker 读取 LLM 配置和 voice_id）
  local request_epoch = current_conversation_epoch()
  local req_id, err = AsyncPipe.send_request(
    config_file(),  -- config.txt 路径，worker 用它解析 LLM 配置和 voice_id
    elevenlabs_key,
    "elevenlabs",  -- model 占位
    payload,
    function(response, error)
      if not is_current_conversation_epoch(request_epoch) then return end
      local audio_done_status = "音频生成完成"
      if error then
        audio_done_status = "音频生成失败"
        table.insert(state.messages, {
          role = "assistant",
          content = "⚠️ 音频生成失败: " .. error,
          is_system = true
        })
      else
        -- v1.0+ response 格式：可能是 "提示\n路径" 或单纯 "路径"
        if response and response ~= "" and not response:match("^%[ERROR%]") then
          -- 按行分割，最后一行是实际路径
          local wav_path, hint = ElevenLabs.parse_worker_response(response)
          
          -- 在 REAPER 中新建轨道并导入音频
          local track_name = ElevenLabs.elevenlabs_track_name(audio_req.mode, audio_req.track_name, audio_req)
          
          -- 先验证文件存在
          local file_exists = false
          local f = io.open(wav_path, "rb")
          if f then
            f:close()
            file_exists = true
          end
          
          local msg
          if not file_exists then
            audio_done_status = "音频生成失败"
            msg = "⚠️ 音频文件不存在: " .. tostring(wav_path)
          else
            local import_script = ElevenLabs.build_import_script(track_name, wav_path)
            
            local ok, result = pcall(function()
              local import_env = {
                reaper = reaper,
                tostring = tostring,
                tonumber = tonumber,
                type = type,
                string = string,
                math = math,
                table = table,
              }
              local func, err = load(import_script, "elevenlabs_import", "t", import_env)
              if func then
                return func()
              else
                return { ok = false, message = "导入脚本编译错误: " .. tostring(err), path = wav_path, track = track_name }
              end
            end)
            
            local import_ok = false
            local import_message = ""
            local import_detail = ""
            if not ok then
              audio_done_status = "音频导入失败"
              import_message = tostring(result)
            elseif type(result) == "table" then
              import_ok = result.ok == true
              import_message = tostring(result.message or "")
              if result.items_added ~= nil then
                import_detail = import_detail .. "\n新增 item: " .. tostring(result.items_added)
              end
              if result.track_items ~= nil then
                import_detail = import_detail .. "\n目标轨道 item: " .. tostring(result.track_items)
              end
              if result.track_index ~= nil then
                import_detail = import_detail .. "\n轨道编号: " .. tostring(result.track_index)
              end
              if result.peaks_built ~= nil then
                import_detail = import_detail .. "\n波形峰值: " .. (result.peaks_built and "已请求构建" or "未触发")
              end
            else
              import_message = tostring(result)
              import_ok = not import_message:match("返回 false")
            end

            if not import_ok then
              audio_done_status = "音频导入失败"
            else
              audio_done_status = "音频已导入工程"
            end
            if import_ok then
              msg = "🎵 " .. import_message .. "\n轨道: " .. track_name .. import_detail
            else
              msg = "⚠️ 音频已生成，但导入工程失败: " .. import_message .. "\n文件: " .. tostring(wav_path) .. import_detail
            end
            if hint and import_ok then
              msg = msg .. "\n" .. hint
            end
          end
          
          table.insert(state.messages, {
            role = "assistant",
            content = msg,
            is_system = true
          })
        else
          audio_done_status = "音频生成失败"
          table.insert(state.messages, {
            role = "assistant",
            content = "⚠️ 音频生成失败: " .. tostring(response),
            is_system = true
          })
        end
      end
      Waiting.finish_audio_request(state, audio_done_status)
      state.scroll = true
      if AsyncPipe and not AsyncPipe.is_busy() then
        state.waiting = false
        Waiting.clear(state)
        if state.pending_operation then
          state.status = Waiting.operation_status(state.pending_operation, state.status)
        else
          state.status = audio_done_status
        end
      end
    end,
    "elevenlabs"  -- v1.0+ 传入 mode 参数
  )
  
  if not req_id then
    state.status = "启动音频生成失败: " .. tostring(err)
    set_audio_status(state.status)
    return false
  end
  
  Waiting.begin_audio_request(state, audio_req.mode)
  state.scroll = true
  return true
end

-- ============================================
-- 发送 LLM 请求 (v1.0)
-- ============================================
send_request = function(user_msg, request_opts)
  request_opts = request_opts or {}
  if CONFIG.llm_key == "" or CONFIG.llm_key == "在此填入你的 API Key" then
    state.show_settings = true
    state.show_audio = false
    state.status = "请先设置 API Key"
    return false
  end

  if state.pending_operation and state.pending_operation.needs_clarification then
    return submit_pending_clarification_answer(user_msg, nil, "chat")
  end

  local effective_user_request = tostring(request_opts.effective_user_request or user_msg or "")
  state.last_user_request = effective_user_request
  state.last_retry_request = tostring(user_msg or "")
  state.last_retry_effective_request = effective_user_request
  state.active_generation_request = tostring(user_msg or "")
  state.active_generation_effective_request = effective_user_request

  -- v1.0+：始终使用异步方式
  if AsyncPipe then
    local messages = {}
    local include_history = include_chat_history_for_request(effective_user_request)
    
    -- 添加 system 消息
    local sys = CONFIG.system_prompt
    
    -- 根据当前模式追加特定的执行指令（和 build_json 保持一致）
    if state.mcp_running then
      sys = sys .. "\n\n[当前模式: MCP服务器已连接]"
      -- 追加 MCP 功能列表（动态获取）
      sys = append_capability_snapshot(sys, state.pending_operation or state.last_ai_operation, 14)
    elseif state.exec_mode then
      sys = sys .. "\n\n[当前模式: 本地执行模式 - MCP fallback + Stable SCRIPT]"
    else
      sys = sys .. "\n\n[当前模式: 咨询模式]"
      sys = sys .. "\n只回答用户问题，不要输出 [SCRIPT]、[/SCRIPT]、[MCP_CALL:...] 或任何可执行标记。"
    end
    
    if state.exec_mode or state.mcp_running then
      sys = append_stable_script_prompt(sys)
      sys = append_intent_contract_prompt(sys)
      sys = append_turn_isolation_prompt(sys, include_history)
    end
    
    if CONFIG.inject_context then
      local ctx = get_project_context()
      state.last_proj_ctx = ctx
      sys = sys .. "\n\n" .. ctx

      -- v1.0 合并刷新功能：每次发送自动注入实时选中信息
      local sel_ctx = get_selection_context()
      state.last_selection_context = sel_ctx
      sys = sys .. "\n\n" .. sel_ctx
    end

    table.insert(messages, {role = "system", content = sys})
    
    -- 添加历史消息。执行模式下默认隔离新请求，避免上一轮操作污染当前计划。
    if include_history then
      local start = math.max(1, #state.messages - 19)
      for i = start, #state.messages do
        local m = state.messages[i]
        if not m.is_system then
          table.insert(messages, {role = m.role, content = m.content})
        end
      end
    end
    
    -- 添加用户消息
    table.insert(messages, {role = "user", content = user_msg})
    
    -- 启动异步请求（v1.0 支持多个并发）
    local request_epoch = current_conversation_epoch()
    local stream_enabled = request_opts.stream ~= false
    local stream_msg_index = nil
    local stream_text = ""
    local stream_visible_text = ""
    local stream_pending_text = ""
    local stream_final_text = nil
    local stream_done = false
    local stream_reveal_credit = 0
    local stream_last_update = (reaper.time_precise and reaper.time_precise()) or os.clock()
    local stream_error_seen = false
    local stream_reasoning = { pending = "", visible = "", credit = 0, done_requested = false }
    local stream_after_finish = nil

    local function take_utf8_chars(text, max_chars)
      text = tostring(text or "")
      max_chars = math.max(0, math.floor(tonumber(max_chars or 0) or 0))
      if max_chars <= 0 or text == "" then return "", text, 0 end

      local i = 1
      local taken = 0
      local len = #text
      while i <= len and taken < max_chars do
        local b = text:byte(i) or 0
        local step = 1
        if b >= 0xF0 then
          step = 4
        elseif b >= 0xE0 then
          step = 3
        elseif b >= 0xC0 then
          step = 2
        end
        if i + step - 1 > len then break end
        i = i + step
        taken = taken + 1
      end

      if taken <= 0 then return "", text, 0 end
      return text:sub(1, i - 1), text:sub(i), taken
    end

    local function finish_stream_display()
      if not stream_msg_index or not state.messages[stream_msg_index] then return end
      local msg = state.messages[stream_msg_index]
      msg.content = stream_final_text or stream_visible_text or msg.content or ""
      msg.streaming = false
      msg.reasoning_streaming = false
      if tostring(msg.reasoning_content or "") ~= "" then
        msg.reasoning_collapsed = true
      end
      msg.stream_status = reaperai_finish_reason_label(msg.finish_reason)
      reaperai_mark_retryable_message(msg, user_msg, effective_user_request)
      state.chat_stream_active = false
      state.stream_typewriter_update = nil
      if state.active_generation_message_ref == msg then
        state.active_generation_message_ref = nil
        state.active_generation_request = nil
        state.active_generation_effective_request = nil
      end
      local after_finish = stream_after_finish
      stream_after_finish = nil
      if type(after_finish) == "function" then
        pcall(after_finish, msg)
      end
      state.scroll = true

      if AsyncPipe and not AsyncPipe.is_busy() then
        state.waiting = false
        Waiting.clear(state)
        if state.pending_operation then
          state.status = Waiting.operation_status(state.pending_operation, state.status)
        else
          state.status = state.exec_mode and "就绪" or "就绪（咨询模式）"
        end
      end
    end

    local function update_stream_typewriter()
      if not stream_enabled then return end
      if not stream_msg_index or not state.messages[stream_msg_index] then return end

      local now = (reaper.time_precise and reaper.time_precise()) or os.clock()
      local dt = math.max(0, now - (stream_last_update or now))
      stream_last_update = now

      local active_msg = state.messages[stream_msg_index]
      local had_reasoning = stream_reasoning.pending ~= ""
        or stream_reasoning.visible ~= ""
        or tostring(active_msg.reasoning_content or "") ~= ""
      if stream_reasoning.pending ~= "" then
        stream_reasoning.credit = math.min(80, (stream_reasoning.credit or 0) + dt * 42)
        local want_reasoning = math.min(5, math.floor(stream_reasoning.credit))
        if want_reasoning > 0 then
          local piece, rest, count = take_utf8_chars(stream_reasoning.pending, want_reasoning)
          if count > 0 then
            stream_reasoning.pending = rest
            stream_reasoning.visible = stream_reasoning.visible .. piece
            stream_reasoning.credit = stream_reasoning.credit - count
            local msg = state.messages[stream_msg_index]
            msg.reasoning_content = stream_reasoning.visible
            msg.reasoning_streaming = true
            msg.reasoning_collapsed = false
            msg.stream_status = "正在思考..."
            state.status = "正在思考..."
            state.scroll = true
          end
        end
        if had_reasoning then
          return
        end
      elseif stream_reasoning.done_requested and had_reasoning then
        local msg = state.messages[stream_msg_index]
        if msg and tostring(msg.reasoning_content or "") ~= "" then
          msg.reasoning_streaming = false
          msg.reasoning_collapsed = true
        end
        stream_reasoning.done_requested = false
        return
      end

      if stream_pending_text ~= "" then
        local backlog = #stream_pending_text
        local cps = 34
        local max_per_frame = 4
        if backlog > 1200 then
          cps = 180
          max_per_frame = 18
        elseif backlog > 500 then
          cps = 120
          max_per_frame = 12
        elseif backlog > 180 then
          cps = 72
          max_per_frame = 8
        end

        stream_reveal_credit = math.min(80, (stream_reveal_credit or 0) + dt * cps)
        local want = math.min(max_per_frame, math.floor(stream_reveal_credit))
        if want > 0 then
          local piece, rest, count = take_utf8_chars(stream_pending_text, want)
          if count > 0 then
            stream_pending_text = rest
            stream_visible_text = stream_visible_text .. piece
            stream_reveal_credit = stream_reveal_credit - count
            state.messages[stream_msg_index].content = stream_visible_text
            state.messages[stream_msg_index].streaming = true
            state.messages[stream_msg_index].stream_status = (state.exec_mode or state.mcp_running) and "正在显示执行计划..." or "正在显示回复..."
            state.status = (state.exec_mode or state.mcp_running) and "正在显示执行计划..." or "正在显示回复..."
            state.scroll = true
          end
        end
      end

      if stream_done and stream_pending_text == "" and stream_reasoning.pending == "" then
        finish_stream_display()
      end
    end

    local function ensure_stream_message()
      if stream_msg_index and state.messages[stream_msg_index] then
        return state.messages[stream_msg_index]
      end

      table.insert(state.messages, {
        role = "assistant",
        content = "",
        streaming = true,
        stream_status = "正在连接",
        request_text = tostring(user_msg or ""),
        effective_user_request = effective_user_request,
      })
      stream_msg_index = #state.messages
      state.active_generation_message_ref = state.messages[stream_msg_index]
      state.scroll = true
      return state.messages[stream_msg_index]
    end

    local function set_stream_message(content, streaming)
      local msg = ensure_stream_message()
      msg.content = tostring(content or "")
      msg.streaming = streaming == true
      state.scroll = true
      return msg
    end

    local function handle_stream_event(event)
      if not is_current_conversation_epoch(request_epoch) then return end
      event = event or {}
      local event_type = tostring(event.type or "")

      if event_type == "start" then
        local msg = ensure_stream_message()
        msg.stream_status = "已连接"
      elseif event_type == "delta" then
        local delta = tostring(event.content or "")
        if delta ~= "" then
          stream_reasoning.done_requested = true
          stream_text = stream_text .. delta
          stream_pending_text = stream_pending_text .. delta
          update_stream_typewriter()
        end
      elseif event_type == "reasoning_delta" then
        local delta = tostring(event.content or "")
        if delta ~= "" then
          local msg = ensure_stream_message()
          stream_reasoning.pending = stream_reasoning.pending .. delta
          msg.reasoning_streaming = true
          msg.reasoning_collapsed = false
          msg.stream_status = "正在思考..."
          state.status = "正在思考..."
          update_stream_typewriter()
          state.scroll = true
        end
      elseif event_type == "tool_call" then
        local msg = ensure_stream_message()
        reaperai_apply_tool_call_event(msg, event)
        state.status = msg.advanced_status or "正在处理工具调用..."
        state.scroll = true
      elseif event_type == "finish" then
        local msg = ensure_stream_message()
        msg.finish_reason = tostring(event.finish_reason or "")
        msg.stream_status = reaperai_finish_reason_label(msg.finish_reason)
        stream_reasoning.done_requested = true
        update_stream_typewriter()
        state.scroll = true
      elseif event_type == "done" then
        stream_reasoning.done_requested = true
        stream_text = tostring(event.content or stream_text or "")
        stream_final_text = strip_intent_block_for_display(stream_text)
        stream_done = true
        if stream_final_text:sub(1, #stream_visible_text) == stream_visible_text then
          stream_pending_text = stream_final_text:sub(#stream_visible_text + 1)
        else
          stream_visible_text = ""
          stream_pending_text = stream_final_text
          if stream_msg_index and state.messages[stream_msg_index] then
            state.messages[stream_msg_index].content = ""
          end
        end
        update_stream_typewriter()
      elseif event_type == "error" then
        local message = tostring(event.message or "请求失败")
        stream_error_seen = true
        stream_pending_text = ""
        stream_done = true
        stream_final_text = nil
        local msg = ensure_stream_message()
        msg.streaming = false
        msg.reasoning_streaming = false
        if tostring(msg.content or "") == "" then
          msg.content = "⚠️ 请求失败: " .. message
        else
          msg.content = tostring(msg.content) .. "\n\n⚠️ 请求失败: " .. message
        end
        msg.stream_status = "请求失败"
        reaperai_mark_retryable_message(msg, user_msg, effective_user_request)
        state.chat_stream_active = false
        state.stream_typewriter_update = nil
        if state.active_generation_message_ref == msg then
          state.active_generation_message_ref = nil
          state.active_generation_request = nil
          state.active_generation_effective_request = nil
        end
        state.scroll = true
      end
    end

    local req_id, err = AsyncPipe.send_request(
      CONFIG.llm_url,
      CONFIG.llm_key,
      CONFIG.llm_model,
      messages,
      function(response, error)
        if not is_current_conversation_epoch(request_epoch) then return end
        -- 回调函数：响应完成时直接处理
        if error then
          Waiting.clear_operation_placeholder(state)
          if stream_enabled and stream_msg_index and state.messages[stream_msg_index] then
            local msg = state.messages[stream_msg_index]
            msg.streaming = false
            msg.reasoning_streaming = false
            if (not stream_error_seen) and tostring(error or "") ~= "请求已取消" then
              if tostring(msg.content or "") == "" then
                msg.content = "⚠️ 请求失败: " .. tostring(error)
              else
                msg.content = tostring(msg.content) .. "\n\n⚠️ 请求失败: " .. tostring(error)
              end
            end
            msg.stream_status = tostring(error or "") == "请求已取消" and "已取消" or "请求失败"
            reaperai_mark_retryable_message(msg, user_msg, effective_user_request)
            state.chat_stream_active = false
            state.stream_typewriter_update = nil
            if state.active_generation_message_ref == msg then
              state.active_generation_message_ref = nil
              state.active_generation_request = nil
              state.active_generation_effective_request = nil
            end
          else
            local msg = {
              role = "assistant",
              content = "⚠️ 请求失败: " .. error,
              stream_status = "请求失败"
            }
            reaperai_mark_retryable_message(msg, user_msg, effective_user_request)
            table.insert(state.messages, msg)
          end
        else
          local r, parse_err = parse_response_content(response)
          if r then
            -- 执行模式下，先生成待确认 Operation，不再自动执行
            if state.exec_mode then
              local display_text = strip_intent_block_for_display(r)
              local ai_msg_index = nil
              if stream_enabled and stream_msg_index and state.messages[stream_msg_index] then
                stream_final_text = display_text
                stream_done = true
                ai_msg_index = stream_msg_index
                stream_after_finish = function(msg)
                  local queued = queue_operation_for_confirmation(r, effective_user_request)
                  if queued == "repairing" then
                    local idx = reaperai_message_index_by_ref(msg)
                    if idx then
                      table.remove(state.messages, idx)
                    elseif ai_msg_index and state.messages[ai_msg_index] then
                      table.remove(state.messages, ai_msg_index)
                    end
                  elseif not queued then
                    Waiting.clear_operation_placeholder(state)
                  end
                end
                update_stream_typewriter()
              else
                local msg = {role = "assistant", content = display_text}
                reaperai_mark_retryable_message(msg, user_msg, effective_user_request)
                table.insert(state.messages, msg)
                ai_msg_index = #state.messages
                local queued = queue_operation_for_confirmation(r, effective_user_request)
                if queued == "repairing" then
                  if ai_msg_index and state.messages[ai_msg_index] then
                    table.remove(state.messages, ai_msg_index)
                  end
                  if state.stream_typewriter_update == update_stream_typewriter then
                    state.chat_stream_active = false
                    state.stream_typewriter_update = nil
                  end
                elseif not queued then
                  Waiting.clear_operation_placeholder(state)
                end
              end
            else
              local display_text = strip_intent_block_for_display(r)
              if stream_enabled and stream_msg_index and state.messages[stream_msg_index] then
                stream_final_text = display_text
                stream_done = true
                update_stream_typewriter()
              else
                local msg = {role = "assistant", content = display_text}
                reaperai_mark_retryable_message(msg, user_msg, effective_user_request)
                table.insert(state.messages, msg)
              end
            end
          else
            Waiting.clear_operation_placeholder(state)
            if stream_enabled and stream_msg_index and state.messages[stream_msg_index] then
              local msg = state.messages[stream_msg_index]
              msg.streaming = false
              msg.reasoning_streaming = false
              if msg.tool_calls and #msg.tool_calls > 0 then
                msg.content = "⚠️ 模型请求了工具调用，当前版本已记录调用信息，但未自动执行 OpenAI tool call。"
                msg.stream_status = "等待工具调用"
              else
                msg.content = "⚠️ 解析响应失败: " .. tostring(parse_err or "未知错误")
                msg.stream_status = "解析失败"
              end
              reaperai_mark_retryable_message(msg, user_msg, effective_user_request)
            else
              local msg = {
                role = "assistant",
                content = "⚠️ 解析响应失败: " .. tostring(parse_err or "未知错误"),
                stream_status = "解析失败"
              }
              reaperai_mark_retryable_message(msg, user_msg, effective_user_request)
              table.insert(state.messages, msg)
            end
          end
        end
        state.scroll = true
        -- 检查是否还有正在进行的请求
        if AsyncPipe and not AsyncPipe.is_busy() then
          if stream_enabled and state.chat_stream_active then
            return
          end
          state.waiting = false
          Waiting.clear(state)
          if state.pending_operation then
            state.status = Waiting.operation_status(state.pending_operation, state.status)
          else
            state.status = state.exec_mode and "就绪" or "就绪（咨询模式）"
          end
        end
      end,
      stream_enabled and "llm_stream" or nil,
      stream_enabled and handle_stream_event or nil
    )
    
    if not req_id then
      state.status = "启动异步请求失败: " .. tostring(err)
      state.active_generation_message_ref = nil
      state.active_generation_request = nil
      state.active_generation_effective_request = nil
      return false
    end
    
    state.waiting = true
    if stream_enabled then
      state.chat_stream_active = true
      state.stream_typewriter_update = update_stream_typewriter
      ensure_stream_message()
    end
    if state.exec_mode then
      Waiting.start(state, "exec_plan", effective_user_request)
      Waiting.show_operation_placeholder(state, effective_user_request)
    else
      Waiting.start(state, "chat", effective_user_request)
    end
    state.scroll = true
    return true
  else
    -- 回退到同步方式（v1.0 原始代码）
    return send_request_sync(user_msg)
  end
end

-- ============================================
-- 同步 HTTP 请求 (v1.0 兼容)
-- ============================================
function send_request_sync(user_msg)
  state.status = "异步模块未加载，已禁用同步 curl 回退以避免弹出 Windows Terminal"
  return false
end

-- ============================================
-- 检查 LLM 响应 (v1.0+ 异步响应直接在回调中处理)
-- ============================================
local function check_resp()
  if state.stream_typewriter_update then
    pcall(state.stream_typewriter_update)
  end

  -- v1.0+：异步响应直接在回调中处理，这里只更新状态
  if AsyncPipe and AsyncPipe.is_busy() then
    Waiting.update(state)
    return nil  -- 继续等待
  end

  if state.waiting and state.chat_stream_active then
    return nil
  end
  
  -- 如果没有正在进行的异步请求，检查是否所有请求已完成
  if state.waiting and AsyncPipe and not AsyncPipe.is_busy() then
    state.waiting = false
    Waiting.clear(state)
    if state.pending_operation then
      state.status = Waiting.operation_status(state.pending_operation, state.status)
    else
      state.status = state.exec_mode and "就绪" or "就绪（咨询模式）"
    end
  end
  
  return nil
end

-- ============================================
-- 解析响应内容
-- ============================================
parse_response_content = function(r)
  if r == nil then return nil, "空响应" end
  if r == "" then return nil, "空响应" end
  
  -- 检查是否是错误标记
  if r:match("^%[ERROR%]") then
    local err_msg = r:gsub("^%[ERROR%]%s*", "")
    return nil, err_msg
  end
  
  -- 【截断检测】如果内容以 \ 或 (, [, { 结尾，说明被截断了
  if r:match("[%(%%[%{,\\]%s*$") then
    return r .. "\n\n💡 **提示**：AI 响应被截断，此操作较复杂。\n建议点击【执行模式】按钮连接 MCP，支持更长的代码和更复杂的操作。"
  end
  
  return r
end

-- ============================================
-- Operation Model 阶段1：待确认操作壳
-- ============================================
local function create_operation_from_response(text, user_msg)
  return Operation.create_from_response(text, parse_executable_steps, user_msg)
end

local function operation_risk_label(risk)
  return Operation.risk_label(risk)
end

local function operation_step_label(step, index)
  return Operation.step_label(step, index)
end

local function operation_issue_text(op)
  local issues = op and op.preflight_issues or {}
  if not issues or #issues == 0 then
    return "计划预检未通过，但没有返回详细原因"
  end
  local lines = {}
  local max_items = math.min(#issues, 8)
  for i = 1, max_items do
    table.insert(lines, tostring(issues[i]))
  end
  if #issues > max_items then
    table.insert(lines, "... 还有 " .. tostring(#issues - max_items) .. " 条")
  end
  return table.concat(lines, "\n")
end

local function operation_contract_text(op, user_msg)
  local contract = op and op.intent_contract or nil
  local lines = {}
  local goal = contract and contract.goal_text or user_msg
  table.insert(lines, "净化后的用户目标:")
  table.insert(lines, tostring(goal or ""))

  local forbidden = contract and contract.forbidden or {}
  local forbidden_lines = {}
  if forbidden.delete_project or forbidden.clear_project then table.insert(forbidden_lines, "禁止删除/清空工程对象") end
  if forbidden.delete_disk then table.insert(forbidden_lines, "禁止删除磁盘文件") end
  if forbidden.export_file then table.insert(forbidden_lines, "禁止导出/渲染文件") end
  if forbidden.write_file or forbidden.overwrite then table.insert(forbidden_lines, "禁止写入/覆盖/保存文件") end

  table.insert(lines, "")
  table.insert(lines, "用户明确禁止:")
  table.insert(lines, (#forbidden_lines > 0) and table.concat(forbidden_lines, "\n") or "无")
  return table.concat(lines, "\n")
end

local function operation_script_preflight_failure_only(op)
  local has_script_error = false
  local has_native_action_gate_error = false
  for _, step in ipairs((op and op.parts) or {}) do
    if step.kind == "script" then
      if step.valid == false or step.validation_error or step.precheck_error then
        has_script_error = true
      end
    elseif step.status == "blocked" or step.precheck_error or step.blocked_reason then
      return false
    end
  end

  if not has_script_error then return false end
  for _, issue in ipairs((op and op.preflight_issues) or {}) do
    local text = tostring(issue or "")
    if text:find("Native Action", 1, true) or text:find("Main_OnCommand", 1, true) or text:find("REAPER Action ID", 1, true) then
      has_native_action_gate_error = true
    end
    if not (text:find("SCRIPT", 1, true) or text:find("[/SCRIPT]", 1, true)) then
      return false
    end
  end
  if has_native_action_gate_error then return false end
  return true
end

local function operation_script_preflight_errors_text(op)
  local lines = {}
  for i, step in ipairs((op and op.parts) or {}) do
    if step.kind == "script" and (step.valid == false or step.validation_error or step.precheck_error) then
      table.insert(lines, "Step " .. tostring(i) .. ": " .. tostring(step.validation_error or step.precheck_error or "SCRIPT 预检失败"))
    end
  end
  if #lines == 0 then
    return operation_issue_text(op)
  end
  return table.concat(lines, "\n")
end

local function operation_has_native_action_gate_error(op)
  for _, issue in ipairs((op and op.preflight_issues) or {}) do
    local text = tostring(issue or "")
    if text:find("Native Action", 1, true)
      or text:find("Main_OnCommand", 1, true)
      or text:find("REAPER Action ID", 1, true) then
      return true
    end
  end
  return false
end

local function build_script_preflight_repair_messages(user_msg, bad_text, op, attempt)
  local sys = CONFIG.system_prompt
  sys = sys .. "\n\n[当前模式: 自动修复 SCRIPT 预检错误]"
  if state.mcp_running then
    sys = append_capability_snapshot(sys, op or state.pending_operation or state.last_ai_operation, 14)
  end
  sys = append_stable_script_prompt(sys)
  sys = sys .. "\n\n你正在修复 AI 生成的 REAPER Lua SCRIPT。"
  sys = sys .. "\n只修复 SCRIPT 语法/API/闭合/参数等预检错误，不要改变用户目标。"
  sys = sys .. "\n只输出新的可执行计划，不要解释，不要 Markdown。"
  sys = sys .. "\n如果原计划包含 MCP_CALL，可保留；如果只需要 SCRIPT，就只输出 [SCRIPT]...[/SCRIPT]。"
  sys = sys .. "\n修复后的 SCRIPT 必须完整闭合，避免不存在的 REAPER API、危险循环、裸 Main_OnCommand 数字 ID。"

  if CONFIG.inject_context then
    local ctx = get_project_context()
    state.last_proj_ctx = ctx
    sys = sys .. "\n\n" .. ctx

    local sel_ctx = get_selection_context()
    state.last_selection_context = sel_ctx
    sys = sys .. "\n\n" .. sel_ctx
  end

  local repair_user = table.concat({
    "用户原始需求:",
    tostring(user_msg or ""),
    "",
    operation_contract_text(op, user_msg),
    "",
    "预检失败的旧计划:",
    tostring(bad_text or ""),
    "",
    "SCRIPT 预检错误:",
    operation_script_preflight_errors_text(op),
    "",
    "请修复 SCRIPT 并重新输出完整计划。只输出 [MCP_CALL:...] 或 [SCRIPT]...[/SCRIPT]，不要解释。",
    "SCRIPT 预检修复尝试次数: " .. tostring(attempt or 1),
  }, "\n")

  return {
    {role = "system", content = sys},
    {role = "user", content = repair_user},
  }
end

local function build_operation_repair_messages(user_msg, bad_text, op, attempt)
  local sys = CONFIG.system_prompt
  sys = sys .. "\n\n[当前模式: 自动修复被阻断的执行计划]"
  if state.mcp_running then
    sys = append_capability_snapshot(sys, op or state.pending_operation or state.last_ai_operation, 14)
  end
  sys = append_stable_script_prompt(sys)
  sys = sys .. "\n\n你正在修复一个被 Operation Plan Compiler 阻断的计划。"
  sys = sys .. "\n只输出新的可执行计划，不要解释，不要 Markdown。"
  sys = sys .. "\n允许输出一个或多个 [MCP_CALL:...]，也允许输出 [SCRIPT]...[/SCRIPT]。"
  sys = sys .. "\n必须严格满足用户原始需求，不要重复生成被阻断的删除、清空、覆盖、导出或无关动作。"
  sys = sys .. "\n如果 MCP 能完整覆盖，优先 MCP；MCP 覆盖不了时用开放式 Stable SCRIPT。"

  if CONFIG.inject_context then
    local ctx = get_project_context()
    state.last_proj_ctx = ctx
    sys = sys .. "\n\n" .. ctx

    local sel_ctx = get_selection_context()
    state.last_selection_context = sel_ctx
    sys = sys .. "\n\n" .. sel_ctx
  end

  local repair_user = table.concat({
    "用户原始需求:",
    tostring(user_msg or ""),
    "",
    operation_contract_text(op, user_msg),
    "",
    "被阻断的旧计划:",
    tostring(bad_text or ""),
    "",
    "阻断原因:",
    operation_issue_text(op),
    "",
    "请重新生成正确计划。只输出 [MCP_CALL:...] 或 [SCRIPT]...[/SCRIPT]，不要解释。",
    "修复尝试次数: " .. tostring(attempt or 1),
  }, "\n")

  return {
    {role = "system", content = sys},
    {role = "user", content = repair_user},
  }
end

local function operation_failed_step_info(op)
  for i, step in ipairs((op and op.parts) or {}) do
    if step.status == "failed" or step.runtime_error or step.error then
      return i, step
    end
  end
  return nil, nil
end

local function operation_step_source_text(step)
  if not step then return "" end
  if step.kind == "mcp" then
    return "[MCP_CALL:" .. tostring(step.call or "") .. "]"
  elseif step.kind == "script" then
    return "[SCRIPT]\n" .. tostring(step.code or "") .. "\n[/SCRIPT]"
  end
  return tostring(step.raw or step.kind or "")
end

local RUNTIME_REPAIR_PRODUCER_ENDPOINTS = {
  ["track/create"] = true,
  ["sfx/generate_variants"] = true,
  ["marker/add"] = true,
  ["export/batch_regions"] = true,
  ["export/tracks"] = true,
  ["export/master"] = true,
}

local function operation_step_endpoint(step)
  if not step or step.kind ~= "mcp" then return "" end
  return Operation.endpoint(step.call or "")
end

local function append_preflight_issue(op, issue)
  if not op or not issue or issue == "" then return end
  op.preflight_issues = op.preflight_issues or {}
  table.insert(op.preflight_issues, issue)
  op.preflight_ok = false
  op.needs_clarification = false
  op.contract_status = "blocked"
  op.risk = "blocked"
  op.status = "pending"
end

local function apply_project_fact_preflight(op)
  if ProjectFacts and type(ProjectFacts.apply_preflight) == "function" then
    ProjectFacts.apply_preflight(op)
  end
  return op
end

local function apply_runtime_repair_replay_guard(repair_op, parent_op)
  if not repair_op or not parent_op then return false end
  local successful_calls = {}
  local successful_scripts = {}
  local successful_producers = {}

  for i, step in ipairs(parent_op.parts or {}) do
    if step.status == "executed" then
      if step.kind == "mcp" then
        local call = tostring(step.call or "")
        local endpoint = operation_step_endpoint(step)
        if call ~= "" then successful_calls[call] = i end
        if RUNTIME_REPAIR_PRODUCER_ENDPOINTS[endpoint] then
          successful_producers[endpoint] = i
        end
      elseif step.kind == "script" then
        local code = tostring(step.code or step.raw or "")
        if code ~= "" then successful_scripts[code] = i end
      end
    end
  end

  local blocked = false
  for i, step in ipairs(repair_op.parts or {}) do
    local issue = nil
    if step.kind == "mcp" then
      local call = tostring(step.call or "")
      local endpoint = operation_step_endpoint(step)
      local source_index = successful_calls[call]
      if source_index then
        issue = "Runtime repair replay blocked: Step " .. tostring(i) .. " repeats already executed Step " .. tostring(source_index) .. " " .. operation_step_source_text(step)
      elseif RUNTIME_REPAIR_PRODUCER_ENDPOINTS[endpoint] and successful_producers[endpoint] then
        issue = "Runtime repair replay blocked: Step " .. tostring(i) .. " repeats producer endpoint " .. tostring(endpoint) .. " already executed at Step " .. tostring(successful_producers[endpoint])
      end
    elseif step.kind == "script" then
      local code = tostring(step.code or step.raw or "")
      local source_index = successful_scripts[code]
      if source_index then
        issue = "Runtime repair replay blocked: Step " .. tostring(i) .. " repeats already executed SCRIPT Step " .. tostring(source_index)
      end
    end

    if issue then
      blocked = true
      step.status = "blocked"
      step.blocked_reason = issue
      step.precheck_error = issue
      append_preflight_issue(repair_op, issue)
    end
  end

  if blocked then
    repair_op.runtime_replay_blocked = true
    repair_op.summary = tostring(repair_op.summary or "") .. " | replay blocked"
  end
  return blocked
end

local function mcp_call_has_unresolved_generated_reference(call)
  local endpoint, params = Operation.parse_call(call or "")
  if tostring(endpoint or ""):find("created%.") or tostring(endpoint or ""):find("generated%.") then
    return true
  end
  for _, value in pairs(params or {}) do
    value = tostring(value or "")
    if value:find("created%.") or value:find("generated%.") or value:find("added%.fx") then
      return true
    end
  end
  return false
end

local function refresh_operation_mcp_calls(op)
  if not op then return end
  local calls = {}
  for _, step in ipairs(op.parts or {}) do
    if step.kind == "mcp" and step.call and tostring(step.call) ~= "" then
      table.insert(calls, step.call)
    end
  end
  op.mcp_calls = calls
end

local function materialize_repair_generated_references(op, parent_op)
  if not op or not op.parts then return false end
  if (not GeneratedRegistry.has_any(op.generated_registry)) and parent_op and GeneratedRegistry.has_any(parent_op.generated_registry) then
    op.generated_registry = GeneratedRegistry.clone(parent_op.generated_registry)
  end
  if (not GeneratedRegistry.has_any(op.generated_registry)) and GeneratedRegistry.has_any(state.runtime_generated_registry) then
    op.generated_registry = GeneratedRegistry.clone(state.runtime_generated_registry)
  end

  local registry = GeneratedRegistry.ensure_op(op)
  if (not registry.last_created_tracks or not registry.last_created_tracks.tracks or #registry.last_created_tracks.tracks == 0)
    and registry.tracks and #registry.tracks > 0 then
    local rebuilt = { kind = "track", base_count = tonumber(registry.tracks[1].index or 0) or 0, count = 0, tracks = {} }
    for _, entry in ipairs(registry.tracks or {}) do
      table.insert(rebuilt.tracks, {
        index = entry.index,
        name = entry.name or "",
        guid = entry.guid or "",
      })
    end
    rebuilt.count = #rebuilt.tracks
    registry.last_created_tracks = rebuilt
  end

  if (not registry.last_created_tracks or not registry.last_created_tracks.tracks or #registry.last_created_tracks.tracks == 0) and parent_op then
    for step_index, step in ipairs(parent_op.parts or {}) do
      if step.status == "executed" and operation_step_endpoint(step) == "track/create" then
        local group = { kind = "track", base_count = nil, count = 0, tracks = {} }
        for raw_name, raw_index in tostring(step.result or ""):gmatch("([^,%\n]-)%s*%(%s*index%s+(%d+)%)") do
          local index = tonumber(raw_index)
          local name = tostring(raw_name or ""):gsub("^.*:%s*", ""):gsub("^%s+", ""):gsub("%s+$", "")
          if index and name ~= "" then
            local guid = ""
            if reaper.GetTrack and reaper.GetTrackGUID then
              local track = reaper.GetTrack(0, index)
              guid = track and reaper.GetTrackGUID(track) or ""
            end
            table.insert(group.tracks, { index = index, name = name, guid = guid })
            group.base_count = group.base_count and math.min(group.base_count, index) or index
          end
        end
        group.count = #group.tracks
        if group.count > 0 then
          GeneratedRegistry.record_created_tracks(registry, group, step_index, step)
          state.runtime_generated_registry = GeneratedRegistry.ensure(state.runtime_generated_registry)
          GeneratedRegistry.record_created_tracks(state.runtime_generated_registry, group, step_index, step)
          break
        end
      end
    end
  end

  local execution_context = {
    last_created_tracks = GeneratedRegistry.latest_created_tracks(registry),
    last_created_items = GeneratedRegistry.latest_created_items(registry),
    last_created_markers = GeneratedRegistry.latest_created_markers(registry),
    last_added_fx = GeneratedRegistry.latest_added_fx(registry),
    generated_registry = registry,
    prefer_generated_item_for_selected = true,
    steps = op.parts,
  }

  local changed = false
  for i, step in ipairs(op.parts or {}) do
    if step.kind == "mcp" and mcp_call_has_unresolved_generated_reference(step.call or "") then
      local before = tostring(step.call or "")
      local note = ObjectBinding.bind_mcp_step_to_created_objects(step, execution_context, i)
      if note and tostring(step.call or "") ~= before then
        changed = true
        step.materialized_binding_note = note
      end
      if mcp_call_has_unresolved_generated_reference(step.call or "") then
        local issue = "Runtime repair unresolved generated reference: Step " .. tostring(i) .. " " .. operation_step_source_text(step)
        step.status = "blocked"
        step.blocked_reason = issue
        step.precheck_error = issue
        append_preflight_issue(op, issue)
      end
    end
  end

  if changed then
    refresh_operation_mcp_calls(op)
  end
  return changed
end

local function submit_clarification_to_llm(op, answer, q, mode)
  state.pending_operation = nil
  state.clarification_input_text = ""
  local msg, effective = ClarificationResolver.build_llm_message(op, answer, q, mode, state.last_user_request)
  return send_request(msg, { effective_user_request = effective })
end

submit_pending_clarification_answer = function(answer, question_index, source)
  local op = state.pending_operation
  if not op or not op.needs_clarification then return false end
  answer = ClarificationResolver.trim(answer)
  if answer == "" then
    state.status = "请先填写澄清内容"
    return "clarification_handled"
  end

  if source ~= "chat" then
    table.insert(state.messages, { role = "user", content = answer })
  end

  local questions = op.clarification_questions or {}
  local q = questions[tonumber(question_index or 1) or 1] or questions[1] or {
    question = op.clarification_prompt,
    options = op.clarification_options or {},
    fields = {},
  }

  if ClarificationResolver.answer_requests_rewrite(answer) then
    return submit_clarification_to_llm(op, answer, q, "rewrite")
  end

  local changed = ClarificationResolver.apply_answer_to_plan(op, q, answer)

  local new_text = nil
  if changed then
    new_text = ClarificationResolver.parts_source_text(op.parts)
  else
    new_text = ClarificationResolver.synthesize_operation(op, answer, state.last_user_request)
  end

  if new_text and new_text ~= "" then
    state.pending_operation = nil
    state.clarification_input_text = ""
    state.status = "澄清已写入计划"
    local clarified_user_request = tostring(op.user_request or state.last_user_request or "")
      .. "\n\n[USER_CLARIFICATION]\n" .. tostring(answer or "")
    local queued = queue_operation_for_confirmation(new_text, clarified_user_request, 0)
    if queued and state.pending_operation then
      state.pending_operation.parent_operation_id = op.id
      state.pending_operation.generated_registry = GeneratedRegistry.clone(op.generated_registry)
      state.pending_operation.inherited_generated_registry = GeneratedRegistry.has_any(op.generated_registry)
      state.pending_operation.repair_prefers_generated_references = user_request_mentions_generated_reference(clarified_user_request)
    end
    return queued and "clarification_handled" or false
  end

  return submit_clarification_to_llm(op, answer, q)
end

local function operation_successful_steps_text(op)
  local lines = {}
  for i, step in ipairs((op and op.parts) or {}) do
    if step.status == "executed" then
      table.insert(lines, "Step " .. tostring(i) .. ": " .. operation_step_source_text(step))
      if step.result and step.result ~= "" then
        table.insert(lines, "结果: " .. tostring(step.result))
      end
    end
  end
  return (#lines > 0) and table.concat(lines, "\n") or "无"
end

local function operation_generated_objects_text(op)
  return GeneratedRegistry.summary((op and op.generated_registry) or nil, 12)
end

local function build_runtime_repair_messages(op, results, attempt)
  local user_msg = tostring((op and op.user_request) or state.last_user_request or "")
  local failed_index, failed_step = operation_failed_step_info(op)
  local sys = CONFIG.system_prompt
  sys = sys .. "\n\n[当前模式: 自动修复运行失败的执行计划]"
  if state.mcp_running then
    sys = append_capability_snapshot(sys, op or state.pending_operation or state.last_ai_operation, 14)
  end
  sys = append_stable_script_prompt(sys)
  sys = sys .. "\n\n你正在修复一个运行时失败的 REAPER 执行计划。"
  sys = sys .. "\n只输出新的可执行计划，不要解释，不要 Markdown。"
  sys = sys .. "\n只修复失败 step 或尚未执行的后续工作，不要重复已经成功执行的 step。"
  sys = sys .. "\n修复计划仍必须严格满足用户原始需求，并遵守用户明确禁止的动作。"
  sys = sys .. "\n如果 MCP 目标不存在、fallback 失败或 endpoint 不适合，优先改用更稳的 MCP 参数或 Stable SCRIPT。"

  if CONFIG.inject_context then
    local ctx = get_project_context()
    state.last_proj_ctx = ctx
    sys = sys .. "\n\n" .. ctx

    local sel_ctx = get_selection_context()
    state.last_selection_context = sel_ctx
    sys = sys .. "\n\n" .. sel_ctx
  end

  local repair_user = table.concat({
    "用户原始需求:",
    user_msg,
    "",
    operation_contract_text(op, user_msg),
    "",
    "已成功执行的 step（不要重复执行）:",
    operation_successful_steps_text(op),
    "",
    "已登记执行产物（修复后续步骤必须优先引用这些对象，不要猜轨道号/item号，也不要用 selected=true 代替刚生成对象）:",
    operation_generated_objects_text(op),
    "",
    "产物引用格式: created.items[1] / created.tracks[1] / created.markers[1] / added.fx[1]。例如: [MCP_CALL:item/fade?target=created.items[1]&fade_in_ms=50&fade_out_ms=80]",
    "",
    "失败 step:",
    failed_index and ("Step " .. tostring(failed_index) .. ": " .. operation_step_source_text(failed_step)) or "未知",
    "",
    "运行错误:",
    tostring((failed_step and (failed_step.runtime_error or failed_step.error)) or (op and op.error_text) or table.concat(results or {}, "\n") or "未知错误"),
    "",
    "旧计划全文:",
    tostring((op and op.raw_text) or ""),
    "",
    "请重新生成用于修复失败部分的新计划。只输出 [MCP_CALL:...] 或 [SCRIPT]...[/SCRIPT]，不要解释。",
    "运行修复尝试次数: " .. tostring(attempt or 1),
  }, "\n")

  return {
    {role = "system", content = sys},
    {role = "user", content = repair_user},
  }
end

local function show_operation_card(op, repaired)
  apply_project_fact_preflight(op)
  state.pending_operation = op
  state.status = Waiting.operation_status(op, state.status)
  local content
  if op.needs_clarification then
    content = "AI 需要先确认你的意图，请查看下方澄清卡。"
  elseif op.preflight_ok == false then
    content = "已生成操作卡，但预检发现阻断项，请查看下方卡片。"
  elseif repaired then
    content = "执行计划已修复，请确认下方卡片后再运行。"
  else
    content = "已生成操作卡，请确认后执行。"
  end
  table.insert(state.messages, {
    role = "assistant",
    content = content,
    is_system = true
  })
  state.scroll = true
  return true
end

queue_operation_for_confirmation = function(text, user_msg, repair_attempt)
  user_msg = user_msg or state.last_user_request or ""
  local op = create_operation_from_response(text, user_msg)
  if not op then
    return false
  end
  apply_project_fact_preflight(op)
  repair_attempt = tonumber(repair_attempt or 0) or 0
  local script_can_repair = state.exec_mode and AsyncPipe and op.preflight_ok == false and not op.needs_clarification and
    operation_script_preflight_failure_only(op) and repair_attempt < (CONFIG.script_preflight_repair_max_attempts or 1)
  if script_can_repair then
    local started = submit_script_preflight_repair_request(user_msg, text, op, repair_attempt + 1)
    return started and "repairing" or false
  end
  local can_repair = state.exec_mode and AsyncPipe and op.preflight_ok == false and not op.needs_clarification
    and not operation_has_native_action_gate_error(op)
    and repair_attempt < (CONFIG.operation_repair_max_attempts or 1)
  if can_repair then
    local started = submit_operation_repair_request(user_msg, text, op, repair_attempt + 1)
    return started and "repairing" or false
  end
  return show_operation_card(op, repair_attempt > 0 and op.preflight_ok ~= false)
end

submit_script_preflight_repair_request = function(user_msg, bad_text, op, attempt)
  if not AsyncPipe then
    return show_operation_card(op, false)
  end

  attempt = tonumber(attempt or 1) or 1
  state.pending_operation = nil
  Waiting.start(state, "script_repair", user_msg)
  Waiting.show_operation_placeholder(state, user_msg, { title = "正在自动修复脚本" })
  table.insert(state.messages, {
    role = "assistant",
    content = "🧩 SCRIPT 预检失败，正在自动修复脚本。",
    is_system = true
  })
  state.scroll = true

  local messages = build_script_preflight_repair_messages(user_msg, bad_text, op, attempt)
  local request_epoch = current_conversation_epoch()
  local stream = reaperai_begin_llm_stream_display({
    request_epoch = request_epoch,
    request_text = user_msg,
    effective_user_request = user_msg,
    status_text = "正在显示脚本修复计划..."
  })
  local req_id, err = AsyncPipe.send_request(
    CONFIG.llm_url,
    CONFIG.llm_key,
    CONFIG.llm_model,
    messages,
    function(response, error)
      if not is_current_conversation_epoch(request_epoch) then return end
      if error then
        stream:fail("SCRIPT 自动修复请求失败: " .. tostring(error))
        show_operation_card(op, false)
      else
        local r, parse_err = parse_response_content(response)
        if r then
          stream.after_finish = function()
            queue_operation_for_confirmation(r, user_msg, attempt)
          end
          stream:set_final(r)
        else
          stream:fail("SCRIPT 自动修复响应解析失败: " .. tostring(parse_err or "未知错误"))
          show_operation_card(op, false)
        end
      end

      state.scroll = true
      if AsyncPipe and not AsyncPipe.is_busy() then
        if state.chat_stream_active then
          return
        end
        state.waiting = false
        Waiting.clear(state)
        if state.pending_operation then
          state.status = Waiting.operation_status(state.pending_operation, state.status)
        else
          state.status = state.exec_mode and "就绪" or "就绪（咨询模式）"
        end
      end
    end,
    "llm_stream",
    function(event)
      stream:on_event(event)
    end
  )

  if not req_id then
    stream:remove()
    table.insert(state.messages, {
      role = "assistant",
      content = "⚠️ SCRIPT 自动修复启动失败: " .. tostring(err),
      is_system = true
    })
    state.waiting = false
    Waiting.clear(state)
    return show_operation_card(op, false)
  end

  return true
end

submit_operation_repair_request = function(user_msg, bad_text, op, attempt)
  if not AsyncPipe then
    return show_operation_card(op, false)
  end

  attempt = tonumber(attempt or 1) or 1
  state.pending_operation = nil
  Waiting.start(state, "operation_repair", user_msg)
  Waiting.show_operation_placeholder(state, user_msg, { title = "正在自动修复计划" })
  table.insert(state.messages, {
    role = "assistant",
    content = "🛡 已阻止一个不符合用户需求的执行计划，正在自动修复。",
    is_system = true
  })
  state.scroll = true

  local messages = build_operation_repair_messages(user_msg, bad_text, op, attempt)
  local request_epoch = current_conversation_epoch()
  local stream = reaperai_begin_llm_stream_display({
    request_epoch = request_epoch,
    request_text = user_msg,
    effective_user_request = user_msg,
    status_text = "正在显示修复计划..."
  })
  local req_id, err = AsyncPipe.send_request(
    CONFIG.llm_url,
    CONFIG.llm_key,
    CONFIG.llm_model,
    messages,
    function(response, error)
      if not is_current_conversation_epoch(request_epoch) then return end
      if error then
        stream:fail("自动修复请求失败: " .. tostring(error))
        show_operation_card(op, false)
      else
        local r, parse_err = parse_response_content(response)
        if r then
          stream.after_finish = function()
            queue_operation_for_confirmation(r, user_msg, attempt)
          end
          stream:set_final(r)
        else
          stream:fail("自动修复响应解析失败: " .. tostring(parse_err or "未知错误"))
          show_operation_card(op, false)
        end
      end

      state.scroll = true
      if AsyncPipe and not AsyncPipe.is_busy() then
        if state.chat_stream_active then
          return
        end
        state.waiting = false
        Waiting.clear(state)
        if state.pending_operation then
          state.status = Waiting.operation_status(state.pending_operation, state.status)
        else
          state.status = state.exec_mode and "就绪" or "就绪（咨询模式）"
        end
      end
    end,
    "llm_stream",
    function(event)
      stream:on_event(event)
    end
  )

  if not req_id then
    stream:remove()
    table.insert(state.messages, {
      role = "assistant",
      content = "⚠️ 自动修复启动失败: " .. tostring(err),
      is_system = true
    })
    state.waiting = false
    Waiting.clear(state)
    return show_operation_card(op, false)
  end

  return true
end

local function submit_runtime_repair_request(op, results)
  if not AsyncPipe or not op then
    return false
  end

  local attempt = tonumber(op.runtime_repair_attempt or 0) + 1
  if attempt > (CONFIG.operation_runtime_repair_max_attempts or 1) then
    return false
  end
  op.runtime_repair_attempt = attempt

  state.pending_operation = nil
  Waiting.start(state, "runtime_repair", op.user_request or state.last_user_request or "")
  Waiting.show_operation_placeholder(state, op.user_request or state.last_user_request or "", { title = "正在修复执行失败" })
  table.insert(state.messages, {
    role = "assistant",
    content = "🔧 执行失败，正在自动生成修复计划。修复后仍会先进入确认卡。",
    is_system = true
  })
  state.scroll = true

  local messages = build_runtime_repair_messages(op, results, attempt)
  local request_epoch = current_conversation_epoch()
  local stream = reaperai_begin_llm_stream_display({
    request_epoch = request_epoch,
    request_text = op.user_request or state.last_user_request or "",
    effective_user_request = op.user_request or state.last_user_request or "",
    status_text = "正在显示运行修复计划..."
  })
  local req_id, err = AsyncPipe.send_request(
    CONFIG.llm_url,
    CONFIG.llm_key,
    CONFIG.llm_model,
    messages,
    function(response, error)
      if not is_current_conversation_epoch(request_epoch) then return end
      if error then
        stream:fail("运行修复请求失败: " .. tostring(error))
      else
        local r, parse_err = parse_response_content(response)
        if r then
          local repair_user_request = op.user_request or state.last_user_request or ""
          local repair_op = create_operation_from_response(r, repair_user_request)
          if repair_op then
            repair_op.parent_operation_id = op.id
            repair_op.runtime_repair_from = op.id
            repair_op.runtime_repair_attempt = attempt
            repair_op.generated_registry = GeneratedRegistry.clone(op.generated_registry)
            repair_op.inherited_generated_registry = GeneratedRegistry.has_any(op.generated_registry)
            repair_op.repair_prefers_generated_references = user_request_mentions_generated_reference(repair_user_request)
            materialize_repair_generated_references(repair_op, op)
            apply_runtime_repair_replay_guard(repair_op, op)
            stream.after_finish = function()
              show_operation_card(repair_op, true)
            end
            stream:set_final(r)
          else
            stream:set_final(r)
            table.insert(state.messages, {
              role = "assistant",
              content = "⚠️ 运行修复响应没有生成可确认操作卡。",
              is_system = true
            })
          end
        else
          stream:fail("运行修复响应解析失败: " .. tostring(parse_err or "未知错误"))
        end
      end

      state.scroll = true
      if AsyncPipe and not AsyncPipe.is_busy() then
        if state.chat_stream_active then
          return
        end
        state.waiting = false
        Waiting.clear(state)
        if state.pending_operation then
          state.status = Waiting.operation_status(state.pending_operation, state.status)
        else
          state.status = "操作失败"
        end
      end
    end,
    "llm_stream",
    function(event)
      stream:on_event(event)
    end
  )

  if not req_id then
    stream:remove()
    table.insert(state.messages, {
      role = "assistant",
      content = "⚠️ 运行修复启动失败: " .. tostring(err),
      is_system = true
    })
    state.waiting = false
    Waiting.clear(state)
    return false
  end

  return true
end

execute_pending_operation = function()
  local op = state.pending_operation
  if not op then return nil end
  if op.placeholder then
    state.status = "执行计划仍在生成中"
    return op
  end

  apply_project_fact_preflight(op)

  if op.needs_clarification then
    state.status = "Needs clarification"
    table.insert(state.messages, {
      role = "assistant",
      content = "This card still needs clarification. Please answer the clarification question first.",
      is_system = true
    })
    state.scroll = true
    return op
  end
  if op.preflight_ok == false then
    state.status = "操作不可执行"
    table.insert(state.messages, {
      role = "assistant",
      content = "⚠️ 操作不可执行，请取消后重新生成:\n" .. table.concat(op.preflight_issues or {}, "\n"),
      is_system = true
    })
    state.scroll = true
    return op
  end

  apply_project_fact_preflight(op)
  if op.needs_clarification then
    state.status = "Needs clarification"
    table.insert(state.messages, {
      role = "assistant",
      content = "工程状态刚刚发生变化，执行前需要重新确认目标。请查看下方澄清卡。",
      is_system = true
    })
    state.scroll = true
    return op
  elseif op.preflight_ok == false then
    state.status = "操作不可执行"
    table.insert(state.messages, {
      role = "assistant",
      content = "⚠️ 工程事实预检未通过，请取消后重新生成:\n" .. table.concat(op.preflight_issues or {}, "\n"),
      is_system = true
    })
    state.scroll = true
    return op
  end
  
  op.status = "executing"
  state.status = "正在执行已确认操作..."
  
  local results = execute_operation_parts(op)
  
  if results then
    op.result_text = table.concat(results, "\n")
    state.pending_operation = nil
    if op.execution_failed then
      op.status = "failed"
      op.error_text = op.result_text
      state.last_ai_operation = op
      if operation_has_internal_endpoint_error(op, results) then
        op.internal_endpoint_error = true
        table.insert(state.messages, {
          role = "assistant",
          content = "⚠️ 内部端点错误，已停止自动修复:\n" .. op.result_text,
          is_system = true
        })
        state.status = "内部端点错误"
      else
        table.insert(state.messages, {
          role = "assistant",
          content = "⚠️ 操作失败:\n" .. op.result_text,
          is_system = true
        })
        state.status = "操作失败"
        submit_runtime_repair_request(op, results)
      end
    else
      op.status = "executed"
      state.last_ai_operation = op
      table.insert(state.messages, {
        role = "assistant",
        content = "🔧 执行结果:\n" .. op.result_text,
        is_system = true
      })
      state.status = "执行完成"
    end
  else
    op.status = "failed"
    op.error_text = "未找到可执行内容或执行无结果"
    state.pending_operation = nil
    table.insert(state.messages, {
      role = "assistant",
      content = "⚠️ 操作未执行: " .. op.error_text,
      is_system = true
    })
    state.status = "操作未执行"
  end
  state.scroll = true
  return op
end

cancel_pending_operation = function()
  if not state.pending_operation then return end
  local op = state.pending_operation
  op.status = "cancelled"
  state.pending_operation = nil
  state.clarification_input_text = ""
  if op.placeholder then
    cancel_async_requests()
    state.waiting = false
    Waiting.clear(state)
    table.insert(state.messages, {
      role = "assistant",
      content = "已取消正在生成的执行计划。",
      is_system = true
    })
    state.status = "已取消请求"
    state.scroll = true
    return
  end
  table.insert(state.messages, {
    role = "assistant",
    content = "已取消待确认操作。",
    is_system = true
  })
  state.status = "已取消操作"
  state.scroll = true
end

-- ============================================
-- MCP → Lua 本地 Fallback 执行
-- 当 MCP 未连接时，将常见 MCP 调用转换为本地 Lua 执行
-- ============================================
local function mcp_to_lua_fallback(call_str)
  return McpFallback.mcp_to_lua_fallback(call_str)
end
-- ============================================
-- ReaperAI v1.0 执行处理
-- ============================================

local function validate_script_step(block)
  return LuaExecutor.validate_script_step(block)
end

parse_executable_steps = function(text)
  return Operation.parse_executable_steps(text, validate_script_step)
end

local function count_steps_by_kind(steps, kind)
  return Operation.count_steps_by_kind(steps, kind)
end

local function is_failure_result_text(text)
  return LuaExecutor.is_failure_result_text(text)
end

operation_has_internal_endpoint_error = function(op, results)
  local text = table.concat(results or {}, "\n")
  if text == "" then return false end
  local has_mcp_error = text:find("[MCP ERROR]", 1, true) ~= nil
    or text:find("MCP]", 1, true) ~= nil
    or text:find("MCP提交", 1, true) ~= nil
  if not has_mcp_error then return false end
  return text:find("编译错误", 1, true) ~= nil
    or text:find("unfinished string", 1, true) ~= nil
    or text:find("syntax error", 1, true) ~= nil
    or text:find("attempt to call", 1, true) ~= nil
    or text:find("attempt to index", 1, true) ~= nil
    or text:find("API_GATE", 1, true) ~= nil
end

local capture_project_snapshot = RuntimeState.capture_project_snapshot
local snapshot_track_name_at = RuntimeState.snapshot_track_name_at
local count_tracks_by_name_or_keyword = RuntimeState.count_tracks_by_name_or_keyword
local count_markers_by_name = RuntimeState.count_markers_by_name
local count_delta = RuntimeState.count_delta
local exact_count_delta = RuntimeState.exact_count_delta
local total_delta = RuntimeState.total_delta
local split_param_list = RuntimeState.split_param_list
local capture_created_tracks = RuntimeState.capture_created_tracks
local capture_created_items = RuntimeState.capture_created_items
local capture_created_markers = RuntimeState.capture_created_markers
local capture_added_fx = RuntimeState.capture_added_fx
local bind_mcp_step_to_created_objects = ObjectBinding.bind_mcp_step_to_created_objects

user_request_mentions_generated_reference = function(text)
  text = tostring(text or ""):lower()
  local tokens = {
    "刚生成", "新生成", "生成的", "刚创建", "新创建", "创建的",
    "刚添加", "新添加", "添加的", "created", "generated",
    "第一个", "第1个", "第 1 个", "first",
  }
  for _, token in ipairs(tokens) do
    if text:find(token, 1, true) then return true end
  end
  return false
end

local function record_created_group(registry, bucket, group, step_index, step)
  if not registry or not group then return nil end
  if bucket == "tracks" then
    GeneratedRegistry.record_created_tracks(registry, group, step_index, step)
  elseif bucket == "items" then
    GeneratedRegistry.record_created_items(registry, group, step_index, step)
  elseif bucket == "markers" then
    GeneratedRegistry.record_created_markers(registry, group, step_index, step)
  elseif bucket == "fx" then
    GeneratedRegistry.record_added_fx(registry, group, step_index, step)
  end
  state.runtime_generated_registry = GeneratedRegistry.ensure(state.runtime_generated_registry)
  if bucket == "tracks" then
    GeneratedRegistry.record_created_tracks(state.runtime_generated_registry, group, step_index, step)
  elseif bucket == "items" then
    GeneratedRegistry.record_created_items(state.runtime_generated_registry, group, step_index, step)
  elseif bucket == "markers" then
    GeneratedRegistry.record_created_markers(state.runtime_generated_registry, group, step_index, step)
  elseif bucket == "fx" then
    GeneratedRegistry.record_added_fx(state.runtime_generated_registry, group, step_index, step)
  end
  return group
end

local function param_is_true(value)
  value = tostring(value or ""):lower()
  return value == "true" or value == "1" or value == "yes" or value == "y"
end

local function strip_lua_strings_and_comments_for_verify(src)
  local stripper = LuaExecutor.strip_comments_and_strings
  if stripper then
    return stripper(src)
  end
  return tostring(src or "")
end

local function split_lua_args_for_verify(args)
  args = tostring(args or "")
  local result = {}
  local current = {}
  local depth = 0
  local i = 1
  while i <= #args do
    local c = args:sub(i, i)
    if c == "(" or c == "{" or c == "[" then
      depth = depth + 1
      table.insert(current, c)
    elseif c == ")" or c == "}" or c == "]" then
      depth = math.max(0, depth - 1)
      table.insert(current, c)
    elseif c == "," and depth == 0 then
      local value = table.concat(current):gsub("^%s+", ""):gsub("%s+$", "")
      table.insert(result, value)
      current = {}
    else
      table.insert(current, c)
    end
    i = i + 1
  end
  local last = table.concat(current):gsub("^%s+", ""):gsub("%s+$", "")
  if last ~= "" or #result > 0 then table.insert(result, last) end
  return result
end

local function main_on_command_args_for_verify(code)
  code = tostring(code or "")
  local patterns = {
    "reaper%s*%.%s*Main_OnCommand%s*%(",
    "%f[%w_]Main_OnCommand%s*%(",
  }
  local found = {}
  local search_pos = 1
  while search_pos <= #code do
    local best_s, best_e = nil, nil
    for _, pattern in ipairs(patterns) do
      local s, e = code:find(pattern, search_pos)
      if s and (not best_s or s < best_s) then
        best_s, best_e = s, e
      end
    end
    if not best_s then break end
    local i = best_e + 1
    local depth = 1
    local args = {}
    while i <= #code and depth > 0 do
      local c = code:sub(i, i)
      if c == "(" then
        depth = depth + 1
        table.insert(args, c)
      elseif c == ")" then
        depth = depth - 1
        if depth > 0 then table.insert(args, c) end
      else
        table.insert(args, c)
      end
      i = i + 1
    end
    local parsed = split_lua_args_for_verify(table.concat(args))
    table.insert(found, (#parsed > 0) and parsed[1] or "")
    search_pos = math.max(i, best_e + 1)
  end
  return found
end

local function infer_script_contract(step, op)
  local raw_code = tostring((step and step.code) or "")
  local code = strip_lua_strings_and_comments_for_verify(raw_code)
  local user_intent = (op and op.intent) or {}
  local effects = (step and step.effects) or {}
  local action = (step and step.action) or "custom_script"
  local verifier = nil
  local strength = "observed"
  local target = "script"

  for _, action_arg in ipairs(main_on_command_args_for_verify(code)) do
    if action_arg and tostring(action_arg):match("^%-?%d+$") and LuaExecutor.native_action_entry then
      local native = LuaExecutor.native_action_entry(action_arg)
      if native then
        return {
          action = native.action or action,
          target = native.target or "native_action",
          verifier = native.verifier,
          verifier_strength = native.verifier_strength or "observed",
          effects = native.effects or effects,
          label = native.name or native.label,
          source = "native_action_registry",
        }
      end
    end
  end

  local fact_contract = step and step.script_fact_contract or nil
  if not fact_contract and Operation and type(Operation.script_fact_contract) == "function" then
    local ok, inferred = pcall(Operation.script_fact_contract, raw_code, effects)
    if ok and type(inferred) == "table" then
      fact_contract = inferred
      if step then step.script_fact_contract = inferred end
    end
  end
  if fact_contract and fact_contract.endpoint and fact_contract.endpoint ~= "SCRIPT" then
    local endpoint = tostring(fact_contract.endpoint or "")
    local contract = Operation.action_contract and Operation.action_contract(endpoint) or nil
    local fallback = {
      ["item/create"] = { action = "create", target = "item", verifier = "item/create", verifier_strength = "strong", label = "SCRIPT create/import item" },
      ["item/delete"] = { action = "delete", target = "item", verifier = "item/delete", verifier_strength = "weak", label = "SCRIPT delete item" },
      ["item/property"] = { action = "edit", target = "item", verifier = "item/property", verifier_strength = "weak", label = "SCRIPT edit item" },
      ["marker_region/delete"] = { action = "delete", target = "marker_region", verifier = "marker/delete", verifier_strength = "weak", label = "SCRIPT delete Marker/Region" },
      ["marker_region/edit"] = { action = "edit", target = "marker_region", verifier = nil, verifier_strength = "observed", label = "SCRIPT edit Marker/Region" },
    }
    contract = contract or fallback[endpoint]
    if contract then
      return {
        action = contract.action or action,
        target = contract.target or fact_contract.target_kind or target,
        verifier = contract.verifier,
        verifier_strength = contract.verifier_strength or "observed",
        effects = effects,
        label = contract.label or endpoint,
        source = "script_fact_contract",
      }
    end
  end

  if code:match("InsertTrackAtIndex%s*%(") then
    verifier, strength, target, action = "track/create", "strong", "track", "create"
  elseif code:match("DeleteTrack%s*%(") then
    verifier, strength, target, action = "track/delete", "strong", "track", "delete"
  elseif code:match("GetSetMediaTrackInfo_String%s*%(") and raw_code:match("[\"']P_NAME[\"']") then
    local rename_args = Operation and Operation.first_call_args and Operation.first_call_args(raw_code, "GetSetMediaTrackInfo_String") or nil
    local commit_arg = rename_args and tostring(rename_args[4] or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower() or ""
    if commit_arg == "true" or commit_arg == "1" then
      verifier, strength, target, action = "track/rename", "weak", "track", "rename"
    end
  elseif code:match("AddProjectMarker2%s*%(") or code:match("AddProjectMarker%s*%(") then
    verifier, strength, target, action = "marker/add", "strong", "marker", "create"
  elseif code:match("DeleteProjectMarker") then
    local deletes_region = code:match("DeleteProjectMarker%s*%([^%)]-,%s*[^,]+,%s*true") or code:match("DeleteProjectMarker%s*%([^%)]-,%s*[^,]+,%s*1%s*%)")
    if deletes_region then
      verifier, strength, target, action = "region/delete", "weak", "region", "delete"
    else
      verifier, strength, target, action = "marker/delete", "weak", "marker", "delete"
    end
  elseif code:match("SetProjectMarker") and (user_intent.wants_rename or action == "rename") then
    verifier, strength, target, action = "region/rename", "weak", "region", "rename"
  elseif code:match("InsertMedia%s*%(") or code:match("AddMediaItemToTrack%s*%(") or code:match("InsertMediaSection%s*%(") then
    verifier, strength, target, action = "item/create", "strong", "item", "create"
  elseif code:match("DeleteTrackMediaItem%s*%(") then
    verifier, strength, target, action = "item/delete", "weak", "item", "delete"
  elseif code:match("TrackFX_AddByName%s*%(") then
    verifier, strength, target, action = "fx/add", "strong", "fx", "edit"
  elseif code:match("TrackFX_Delete%s*%(") then
    verifier, strength, target, action = "fx/remove", "strong", "fx", "delete"
  elseif code:match("RenderProject%s*%(") or code:match("Main_OnCommand%s*%(") and (effects.exports_file or effects.writes_disk) then
    verifier, strength, target, action = "file/export", "observed", "file", "export"
  elseif effects.read_only or user_intent.wants_read_only then
    verifier, strength, target, action = nil, "observed", "query", "query"
  end

  return {
    action = action,
    target = target,
    verifier = verifier,
    verifier_strength = strength,
    effects = effects,
    source = "script_inference",
  }
end

local function contract_for_step(step, op)
  if not step then return nil end
  if step.kind == "mcp" then
    local endpoint, params = Operation.parse_call(step.call or "")
    local contract = Operation.action_contract and Operation.action_contract(endpoint) or Operation.action_registry(endpoint)
    if not contract then return nil, endpoint, params end
    return contract, endpoint, params
  elseif step.kind == "script" then
    return infer_script_contract(step, op), "SCRIPT", {}
  end
  return nil, tostring(step.kind or "unknown"), {}
end

local function verify_action_step_result(step, before_snapshot, after_snapshot, op)
  local contract, endpoint, params = contract_for_step(step, op)
  if not contract then
    return true, nil
  end
  local verifier = contract.verifier
  local strength = contract.verifier_strength or (verifier and "strong" or "observed")
  if not verifier or strength == "observed" then
    return true, "结果校验观察: " .. tostring(contract.label or endpoint or contract.target or "未知动作")
  end
  local p = params or {}

  if (verifier == "fx/add" or verifier == "fx/remove") and before_snapshot and after_snapshot and before_snapshot.track_fx_counts and after_snapshot.track_fx_counts then
    local track_index = tonumber(p.track or p.index or "")
    if track_index then
      local before_track_fx = tonumber(before_snapshot.track_fx_counts[track_index + 1] or 0) or 0
      local after_track_fx = tonumber(after_snapshot.track_fx_counts[track_index + 1] or 0) or 0
      if verifier == "fx/add" and after_track_fx <= before_track_fx then
        return false, "Result verification failed: target track FX count did not increase; track index " .. tostring(track_index) .. ", before " .. tostring(before_track_fx) .. ", after " .. tostring(after_track_fx)
      elseif verifier == "fx/remove" and after_track_fx >= before_track_fx then
        return false, "Result verification failed: target track FX count did not decrease; track index " .. tostring(track_index) .. ", before " .. tostring(before_track_fx) .. ", after " .. tostring(after_track_fx)
      end
    end
  end

  if verifier == "track/create" then
    local explicit_names = split_param_list(p.names or p.track_names or "")
    local expected_count = math.max(tonumber(p.count or "") or #explicit_names or 1, 1)
    local name = tostring(p.name or p.track_name or "")
    if #explicit_names > expected_count then expected_count = #explicit_names end
    local track_delta, before_tracks, after_tracks = total_delta(before_snapshot, after_snapshot, "track_count")
    if track_delta and track_delta < expected_count then
      return false, "结果校验失败: 轨道数量没有按预期增加，执行前 " .. tostring(before_tracks) .. "，执行后 " .. tostring(after_tracks) .. "，期望增加至少 " .. tostring(expected_count)
    end
    if #explicit_names > 0 then
      for _, explicit_name in ipairs(explicit_names) do
        local exact_delta, before_named, after_named = exact_count_delta(before_snapshot, after_snapshot, "track", explicit_name)
        if exact_delta and exact_delta <= 0 then
          return false, "Result verification failed: named created track did not appear: " .. tostring(explicit_name) .. "; before " .. tostring(before_named) .. ", after " .. tostring(after_named)
        end
        if not exact_delta and count_tracks_by_name_or_keyword(explicit_name) <= 0 then
          return false, "Result verification failed: created track name not found: " .. tostring(explicit_name)
        end
      end
    elseif name ~= "" then
      local name_delta, before_named, after_named = count_delta(before_snapshot, after_snapshot, "track", name)
      if name_delta and name_delta < expected_count then
        return false, "结果校验失败: 名称匹配轨道没有按预期增加 '" .. name .. "'，执行前 " .. tostring(before_named) .. "，执行后 " .. tostring(after_named)
      end
      if not name_delta and count_tracks_by_name_or_keyword(name) <= 0 then
        return false, "结果校验失败: 未找到新建轨道 '" .. name .. "'"
      end
    elseif track_delta == nil and reaper.CountTracks(0) <= 0 then
      return false, "结果校验失败: 创建轨道后工程中仍没有轨道"
    end
    return true, "结果校验通过: 轨道数量已增加"
  elseif verifier == "track/delete" then
    local track_delta, before_tracks, after_tracks = total_delta(before_snapshot, after_snapshot, "track_count")
    if param_is_true(p.selected) or param_is_true(p.all) or param_is_true(p.multiple) or (p.index and tostring(p.index) ~= "") then
      if track_delta and track_delta >= 0 then
        return false, "结果校验失败: 删除轨道后轨道数量没有减少，执行前 " .. tostring(before_tracks) .. "，执行后 " .. tostring(after_tracks)
      end
      return true, track_delta and "结果校验通过: 轨道数量已减少" or "结果校验跳过: 缺少执行前后快照"
    end
    local keyword = p.match or p.contains or p.keyword or p.name
    if keyword and tostring(keyword) ~= "" then
      local name_delta, before_named, after_named = count_delta(before_snapshot, after_snapshot, "track", keyword)
      if name_delta and before_named and before_named <= 0 then
        return false, "结果校验失败: 执行前没有匹配轨道 '" .. tostring(keyword) .. "'，删除目标不存在"
      end
      if name_delta and before_named and before_named > 0 and after_named >= before_named then
        return false, "结果校验失败: 匹配轨道没有减少 '" .. tostring(keyword) .. "'，执行前 " .. tostring(before_named) .. "，执行后 " .. tostring(after_named)
      end
      if not name_delta and count_tracks_by_name_or_keyword(keyword) > 0 then
        return false, "结果校验失败: 删除后仍找到匹配轨道 '" .. tostring(keyword) .. "'"
      end
      return true, "结果校验通过: 匹配轨道数量已减少"
    end
    if step.kind == "script" and strength == "strong" and track_delta and track_delta >= 0 then
      return false, "结果校验失败: SCRIPT 像是在删除轨道，但轨道数量没有减少，执行前 " .. tostring(before_tracks) .. "，执行后 " .. tostring(after_tracks)
    end
    return true, track_delta and "结果校验通过: 删除执行后轨道数量变化已记录" or "结果校验跳过: 删除目标不够明确"
  elseif verifier == "track/rename" then
    local new_name = p.new_name or p.to or p.name
    if (not new_name or tostring(new_name) == "") and step.kind == "script" then
      local changed = false
      local before_names = before_snapshot and before_snapshot.track_names or {}
      local after_names = after_snapshot and after_snapshot.track_names or {}
      for i = 1, math.max(#before_names, #after_names) do
        if before_names[i] ~= after_names[i] then
          changed = true
          break
        end
      end
      if not changed then
        return false, "结果校验失败: SCRIPT 像是在重命名轨道，但执行后轨道名称没有变化"
      end
      return true, "结果校验通过: 轨道名称已变化"
    elseif not new_name or tostring(new_name) == "" then
      return true, "结果校验跳过: 未提供新轨道名"
    end
    local name_delta, before_named, after_named = count_delta(before_snapshot, after_snapshot, "track", new_name)
    if name_delta and after_named <= before_named then
      local index_name = p.index and snapshot_track_name_at(after_snapshot, p.index) or nil
      if index_name and index_name == tostring(new_name) then
        return true, "结果校验通过: 指定索引轨道已是新名称"
      end
      return false, "结果校验失败: 新轨道名数量没有增加 '" .. tostring(new_name) .. "'，执行前 " .. tostring(before_named) .. "，执行后 " .. tostring(after_named)
    end
    if not name_delta and count_tracks_by_name_or_keyword(new_name) <= 0 then
      return false, "结果校验失败: 未找到重命名后的轨道 '" .. tostring(new_name) .. "'"
    end
    return true, "结果校验通过: 新轨道名数量已增加"
  elseif verifier == "marker/add" then
    local name = tostring(p.name or "")
    local marker_delta, before_markers, after_markers = total_delta(before_snapshot, after_snapshot, "marker_count")
    if step.kind == "script" then
      local region_delta = total_delta(before_snapshot, after_snapshot, "region_count")
      if marker_delta and region_delta and marker_delta <= 0 and region_delta <= 0 then
        return false, "结果校验失败: SCRIPT 像是在添加 Marker/Region，但 Marker 和 Region 数量都没有增加"
      end
      if marker_delta and marker_delta > 0 then
        return true, "结果校验通过: Marker 数量已增加"
      end
      if region_delta and region_delta > 0 then
        return true, "结果校验通过: Region 数量已增加"
      end
    elseif marker_delta and marker_delta <= 0 then
      return false, "结果校验失败: Marker 数量没有增加，执行前 " .. tostring(before_markers) .. "，执行后 " .. tostring(after_markers)
    end
    if name ~= "" then
      local exact_delta, before_named, after_named = exact_count_delta(before_snapshot, after_snapshot, "marker", name)
      if exact_delta and exact_delta <= 0 then
        return false, "结果校验失败: 指定 Marker 名称数量没有增加 '" .. name .. "'，执行前 " .. tostring(before_named) .. "，执行后 " .. tostring(after_named)
      end
      if not exact_delta and count_markers_by_name(name) <= 0 then
        return false, "结果校验失败: 未找到新建 Marker '" .. name .. "'"
      end
      return true, "结果校验通过: Marker 名称数量已增加"
    end
    return true, marker_delta and "结果校验通过: Marker 数量已增加" or "结果校验跳过: 未提供 Marker 名称"
  elseif verifier == "marker/delete" then
    local marker_delta, before_markers, after_markers = total_delta(before_snapshot, after_snapshot, "marker_count")
    if step and step.kind == "script" then
      local region_delta, before_regions, after_regions = total_delta(before_snapshot, after_snapshot, "region_count")
      if marker_delta and region_delta and marker_delta >= 0 and region_delta >= 0 then
        return false, "Result verification failed: SCRIPT deleted Marker/Region but neither count decreased; Marker " .. tostring(before_markers) .. " -> " .. tostring(after_markers) .. ", Region " .. tostring(before_regions) .. " -> " .. tostring(after_regions)
      end
      if (marker_delta and marker_delta < 0) or (region_delta and region_delta < 0) then
        return true, "Result verification passed: Marker/Region count decreased"
      end
    end
    if marker_delta and marker_delta >= 0 then
      return false, "Result verification failed: marker count did not decrease after delete; before " .. tostring(before_markers) .. ", after " .. tostring(after_markers)
    end
    return true, marker_delta and "Result verification passed: marker count decreased" or "Result verification observed: marker delete has no snapshot"
  elseif verifier == "region/delete" then
    local region_delta, before_regions, after_regions = total_delta(before_snapshot, after_snapshot, "region_count")
    if region_delta and region_delta >= 0 then
      return false, "Result verification failed: region count did not decrease after delete; before " .. tostring(before_regions) .. ", after " .. tostring(after_regions)
    end
    return true, region_delta and "Result verification passed: region count decreased" or "Result verification observed: region delete has no snapshot"
  elseif verifier == "region/rename" then
    local changed = false
    local before_regions = before_snapshot and before_snapshot.region_name_counts or {}
    local after_regions = after_snapshot and after_snapshot.region_name_counts or {}
    for name, count in pairs(before_regions) do
      if (after_regions[name] or 0) ~= count then changed = true break end
    end
    if not changed then
      for name, count in pairs(after_regions) do
        if (before_regions[name] or 0) ~= count then changed = true break end
      end
    end
    if not changed then
      return false, "结果校验失败: Region 名称没有变化"
    end
    return true, "结果校验通过: Region 名称已变化"
  elseif verifier == "item/create" then
    local item_delta, before_items, after_items = total_delta(before_snapshot, after_snapshot, "item_count")
    if item_delta and item_delta <= 0 and strength == "strong" then
      return false, "结果校验失败: Item 数量没有增加，执行前 " .. tostring(before_items) .. "，执行后 " .. tostring(after_items)
    end
    if item_delta and item_delta < 0 then
      return false, "结果校验失败: 创建/导入 Item 后数量反而减少，执行前 " .. tostring(before_items) .. "，执行后 " .. tostring(after_items)
    end
    return true, item_delta and "结果校验通过: Item 数量变化已记录" or "结果校验观察: Item 创建缺少快照"
  elseif verifier == "item/delete" then
    local item_delta, before_items, after_items = total_delta(before_snapshot, after_snapshot, "item_count")
    if item_delta and item_delta >= 0 and strength ~= "observed" then
      return false, "结果校验失败: 删除 Item 后 Item 数量没有减少，执行前 " .. tostring(before_items) .. "，执行后 " .. tostring(after_items)
    end
    return true, item_delta and "结果校验通过: Item 数量已减少" or "结果校验观察: Item 删除缺少快照"
  elseif verifier == "item/property" then
    local item_delta, before_items, after_items = total_delta(before_snapshot, after_snapshot, "item_count")
    if item_delta and item_delta < 0 then
      return false, "结果校验失败: 编辑 Item 后 Item 数量异常减少，执行前 " .. tostring(before_items) .. "，执行后 " .. tostring(after_items)
    end
    return true, "结果校验通过: Item 弱校验未发现异常"
  elseif verifier == "fx/add" then
    local fx_delta, before_fx, after_fx = total_delta(before_snapshot, after_snapshot, "track_fx_total")
    if fx_delta and fx_delta <= 0 then
      return false, "结果校验失败: 添加 FX 后 FX 总数没有增加，执行前 " .. tostring(before_fx) .. "，执行后 " .. tostring(after_fx)
    end
    return true, fx_delta and "结果校验通过: FX 总数已增加" or "结果校验观察: FX 添加缺少快照"
  elseif verifier == "fx/remove" then
    local fx_delta, before_fx, after_fx = total_delta(before_snapshot, after_snapshot, "track_fx_total")
    if fx_delta and fx_delta >= 0 then
      return false, "结果校验失败: 移除 FX 后 FX 总数没有减少，执行前 " .. tostring(before_fx) .. "，执行后 " .. tostring(after_fx)
    end
    return true, fx_delta and "结果校验通过: FX 总数已减少" or "结果校验观察: FX 移除缺少快照"
  elseif verifier == "track/property" then
    local track_delta, before_tracks, after_tracks = total_delta(before_snapshot, after_snapshot, "track_count")
    if track_delta and track_delta < 0 then
      return false, "结果校验失败: 编辑轨道属性后轨道数量异常减少，执行前 " .. tostring(before_tracks) .. "，执行后 " .. tostring(after_tracks)
    end
    return true, "结果校验通过: 轨道弱校验未发现异常"
  elseif verifier == "file/export" then
    return true, "结果校验观察: 文件导出暂只记录执行结果"
  end

  return true, nil
end

preflight_operation_steps = function(steps)
  return Operation.preflight_execution_steps(steps)
end

local function execute_mcp_step(call_str, step_index)
  call_str = tostring(call_str or ""):gsub("%]$", "")

  local function execute_local_fallback(label)
    local lua_code, desc = mcp_to_lua_fallback(call_str)
    if lua_code then
      local fb_result, fb_err = execute_lua_sandbox(lua_code, desc)
      if fb_result then
        if is_failure_result_text(fb_result) then
          return "✗ [Step " .. step_index .. " " .. label .. "] " .. desc .. " -> " .. fb_result
        end
        return "✓ [Step " .. step_index .. " " .. label .. "] " .. desc .. " -> " .. fb_result
      end
      return "✗ [Step " .. step_index .. " " .. label .. "] " .. desc .. " -> " .. (fb_err or "执行失败")
    end
    return nil
  end
  
  if state.mcp_running and MCP and MCP.ping() then
    local submit_result, submit_err = MCP.execute_command(call_str)
    if submit_result then
      local exec_result, exec_err = execute_mcp_commands()
      if exec_result then
        return "✓ [Step " .. step_index .. " MCP] " .. call_str .. "\n" .. exec_result
      end
      local fallback_result = execute_local_fallback("本地Fallback")
      if fallback_result then
        return fallback_result .. "\n提示: MCP 已提交但读取队列失败，已改用本地 fallback；原因: " .. tostring(exec_err or "未知")
      end
      return "✗ [Step " .. step_index .. " MCP] " .. call_str .. " -> " .. (exec_err or "执行失败")
    end
    
    local fallback_result = execute_local_fallback("本地Fallback")
    if fallback_result then
      return fallback_result
    end
    return "✗ [Step " .. step_index .. " MCP提交] " .. call_str .. " -> " .. (submit_err or "提交失败")
  end
  
  local fallback_result = execute_local_fallback("本地执行")
  if fallback_result then
    return fallback_result
  end
  
  return "⚠️ [Step " .. step_index .. " MCP] 需要 MCP 服务器，未执行: [MCP_CALL:" .. call_str .. "]\n提示: 如需使用这些功能，请点击【执行模式】按钮连接服务器。"
end

execute_operation_parts = function(op)
  local steps = (op and op.parts) or {}
  if #steps == 0 then
    return nil
  end
  
  if op then
    op.execution_failed = false
  end
  
  local results = {}
  local registry = op and GeneratedRegistry.ensure_op(op) or GeneratedRegistry.ensure(nil)
  local execution_context = {
    last_created_tracks = GeneratedRegistry.latest_created_tracks(registry),
    last_created_items = GeneratedRegistry.latest_created_items(registry),
    last_created_markers = GeneratedRegistry.latest_created_markers(registry),
    last_added_fx = GeneratedRegistry.latest_added_fx(registry),
    generated_registry = registry,
    prefer_generated_item_for_selected = (op and op.repair_prefers_generated_references == true)
      or user_request_mentions_generated_reference(op and op.user_request or state.last_user_request or ""),
    steps = steps,
  }
  local total_script = count_steps_by_kind(steps, "script")
  local script_index = 0
  local preflight_ok, preflight_error = preflight_operation_steps(steps)
  if not preflight_ok then
    if op then op.execution_failed = true end
    table.insert(results, preflight_error)
    return results
  end
  
  for step_index, step in ipairs(steps) do
    step.status = "executing"
    if step.kind == "mcp" then
      local binding_note = bind_mcp_step_to_created_objects(step, execution_context, step_index)
      local unresolved_call = tostring(step.call or "")
      if mcp_call_has_unresolved_generated_reference(unresolved_call) then
        local result_text = "X [Step " .. step_index .. " MCP] unresolved generated reference before MCP: [MCP_CALL:" .. unresolved_call .. "]"
        step.status = "failed"
        step.error = result_text
        step.runtime_error = result_text
        table.insert(results, result_text)
        if op then op.execution_failed = true end
        return results
      end
      step.snapshot_before = capture_project_snapshot()
      local result_text = execute_mcp_step(step.call, step_index)
      step.result = result_text
      if result_text:match("^✗") or result_text:match("^⚠️") then
        step.status = "failed"
        step.error = result_text
        step.runtime_error = result_text
        table.insert(results, result_text)
        if op then op.execution_failed = true end
        return results
      else
        step.snapshot_after = capture_project_snapshot()
        local verify_ok, verify_msg = verify_action_step_result(step, step.snapshot_before, step.snapshot_after, op)
        if not verify_ok then
          local verify_text = "✗ [Step " .. step_index .. " VERIFY] " .. tostring(verify_msg or "结果校验失败")
          step.status = "failed"
          step.error = verify_text
          step.runtime_error = verify_text
          step.verify_result = verify_text
          table.insert(results, result_text)
          table.insert(results, verify_text)
          if op then op.execution_failed = true end
          return results
        end
        step.status = "executed"
        step.verify_result = verify_msg
        local endpoint = Operation.parse_call(step.call or "")
        if endpoint == "track/create" then
          local group = capture_created_tracks(step.snapshot_before, step.snapshot_after)
          execution_context.last_created_tracks = record_created_group(registry, "tracks", group, step_index, step) or execution_context.last_created_tracks
        end
        if endpoint == "sfx/generate_variants" then
          local group = capture_created_items(step.snapshot_before, step.snapshot_after)
          execution_context.last_created_items = record_created_group(registry, "items", group, step_index, step) or execution_context.last_created_items
        end
        if endpoint == "marker/add" then
          local group = capture_created_markers(step.snapshot_before, step.snapshot_after)
          execution_context.last_created_markers = record_created_group(registry, "markers", group, step_index, step) or execution_context.last_created_markers
        end
        if endpoint == "track/add_fx" then
          local group = capture_added_fx(step.snapshot_before, step.snapshot_after)
          execution_context.last_added_fx = record_created_group(registry, "fx", group, step_index, step) or execution_context.last_added_fx
        end
      end
      table.insert(results, result_text)
      if binding_note then
        table.insert(results, "[Bind] " .. binding_note)
      end
    elseif step.kind == "script" then
      script_index = script_index + 1
      if step.valid == false then
        local result_text = "✗ [Step " .. step_index .. " SCRIPT " .. script_index .. "/" .. total_script .. "] " .. tostring(step.validation_error or "SCRIPT 校验失败")
        step.status = "failed"
        step.error = result_text
        step.precheck_error = tostring(step.validation_error or "SCRIPT 校验失败")
        table.insert(results, result_text)
        if op then op.execution_failed = true end
        return results
      end
      step.snapshot_before = capture_project_snapshot()
      local result, err = execute_lua_sandbox(step.code, "AI_SCRIPT_" .. script_index, false)
      if result then
        local result_text = "✓ [Step " .. step_index .. " SCRIPT " .. script_index .. "/" .. total_script .. "] " .. result
        step.snapshot_after = capture_project_snapshot()
        local verify_ok, verify_msg = verify_action_step_result(step, step.snapshot_before, step.snapshot_after, op)
        if not verify_ok then
          local verify_text = "✗ [Step " .. step_index .. " VERIFY] " .. tostring(verify_msg or "SCRIPT 结果校验失败")
          step.status = "failed"
          step.error = verify_text
          step.runtime_error = verify_text
          step.verify_result = verify_text
          step.result = result_text
          table.insert(results, result_text)
          table.insert(results, verify_text)
          if op then op.execution_failed = true end
          return results
        end
        step.status = "executed"
        step.result = result_text
        step.verify_result = verify_msg
        local contract = infer_script_contract(step, op)
        if contract and contract.verifier == "track/create" then
          local group = capture_created_tracks(step.snapshot_before, step.snapshot_after)
          execution_context.last_created_tracks = record_created_group(registry, "tracks", group, step_index, step) or execution_context.last_created_tracks
        elseif contract and contract.verifier == "item/create" then
          local group = capture_created_items(step.snapshot_before, step.snapshot_after)
          execution_context.last_created_items = record_created_group(registry, "items", group, step_index, step) or execution_context.last_created_items
        elseif contract and contract.verifier == "marker/add" then
          local group = capture_created_markers(step.snapshot_before, step.snapshot_after)
          execution_context.last_created_markers = record_created_group(registry, "markers", group, step_index, step) or execution_context.last_created_markers
        elseif contract and contract.verifier == "fx/add" then
          local group = capture_added_fx(step.snapshot_before, step.snapshot_after)
          execution_context.last_added_fx = record_created_group(registry, "fx", group, step_index, step) or execution_context.last_added_fx
        end
        table.insert(results, result_text)
      elseif err then
        local result_text = "✗ [Step " .. step_index .. " SCRIPT " .. script_index .. "/" .. total_script .. "] " .. err
        step.status = "failed"
        step.error = result_text
        step.runtime_error = err
        table.insert(results, result_text)
        if op then op.execution_failed = true end
        return results
      else
        local result_text = "✓ [Step " .. step_index .. " SCRIPT " .. script_index .. "/" .. total_script .. "] 脚本已执行"
        step.status = "executed"
        step.result = result_text
        table.insert(results, result_text)
      end
    else
      local result_text = "⚠️ [Step " .. step_index .. "] 未知 step 类型: " .. tostring(step.kind)
      step.status = "failed"
      step.error = result_text
      step.runtime_error = result_text
      table.insert(results, result_text)
      if op then op.execution_failed = true end
      return results
    end
  end
  
  return #results > 0 and results or nil
end

execute_lua_sandbox = function(code, description, require_result)
  return LuaExecutor.execute_sandbox(code, description, require_result)
end

execute_mcp_lua = function(code, description)
  return LuaExecutor.execute_mcp_lua(code, description)
end

-- ============================================
-- 手动执行 MCP 命令队列
-- ============================================
execute_mcp_commands = function()
  if not MCP.ping() then
    return nil, "MCP 服务器离线"
  end
  
  local data, err = MCP.get_commands()
  if not data then
    return nil, "获取命令队列失败: " .. tostring(err)
  end
  
  local count = tonumber(data:match('"count"%s*:%s*(%d+)')) or 0
  if count == 0 then
    return "没有待执行的 MCP 命令", nil
  end
  
  local results = {}
  local cmd_index = 1
  local has_error = false
  
  local commands_start = data:find('"commands"')
  if not commands_start then
    return nil, "响应中找不到 commands 字段"
  end
  
  local arr_start = data:find('%[', commands_start)
  if not arr_start then
    return nil, "响应中找不到 commands 数组"
  end
  
  local arr_end = nil
  local depth = 1
  local pos = arr_start + 1
  local in_string = false
  local escape_next = false
  
  while pos <= #data and depth > 0 do
    local char = data:sub(pos, pos)
    
    if escape_next then
      escape_next = false
    elseif char == '\\' then
      escape_next = true
    elseif char == '"' and not in_string then
      in_string = true
    elseif char == '"' and in_string then
      in_string = false
    elseif not in_string then
      if char == '[' then
        depth = depth + 1
      elseif char == ']' then
        depth = depth - 1
        if depth == 0 then
          arr_end = pos
          break
        end
      end
    end
    pos = pos + 1
  end
  
  if not arr_end then
    return nil, "无法找到 commands 数组结束位置"
  end
  
  local arr_content = data:sub(arr_start + 1, arr_end - 1)
  
  local search_pos = 1
  while search_pos < #arr_content do
    local code_key_pos = arr_content:find('"code"', search_pos)
    if not code_key_pos then break end
    
    local val_pos = code_key_pos + 6
    while val_pos <= #arr_content do
      local c = arr_content:sub(val_pos, val_pos)
      if c == ':' or c == ' ' or c == '\t' or c == '\n' or c == '\r' then
        val_pos = val_pos + 1
      else
        break
      end
    end
    
    if val_pos > #arr_content or arr_content:sub(val_pos, val_pos) ~= '"' then
      break
    end
    
    val_pos = val_pos + 1
    local code_chars = {}
    local string_ended = false
    
    while val_pos <= #arr_content and not string_ended do
      local char = arr_content:sub(val_pos, val_pos)
      
      if char == '"' then
        local bs_count = 0
        local check_pos = val_pos - 1
        while check_pos >= 1 and arr_content:sub(check_pos, check_pos) == '\\' do
          bs_count = bs_count + 1
          check_pos = check_pos - 1
        end
        
        if bs_count % 2 == 0 then
          string_ended = true
          break
        else
          table.insert(code_chars, '"')
          val_pos = val_pos + 1
        end
      elseif char == '\\' then
        if val_pos < #arr_content then
          local next_char = arr_content:sub(val_pos + 1, val_pos + 1)
          if next_char == 'n' then
            table.insert(code_chars, '\n')
            val_pos = val_pos + 2
          elseif next_char == 't' then
            table.insert(code_chars, '\t')
            val_pos = val_pos + 2
          elseif next_char == 'r' then
            val_pos = val_pos + 2
          elseif next_char == '"' then
            table.insert(code_chars, '"')
            val_pos = val_pos + 2
          elseif next_char == '\\' then
            table.insert(code_chars, '\\')
            val_pos = val_pos + 2
          elseif next_char == 'u' and val_pos + 5 <= #arr_content then
            local hex = arr_content:sub(val_pos + 2, val_pos + 5)
            local ok, unicode_val = pcall(function() return tonumber(hex, 16) end)
            if ok and unicode_val then
              if unicode_val <= 0x7F then
                table.insert(code_chars, string.char(unicode_val))
              elseif unicode_val <= 0x7FF then
                table.insert(code_chars, string.char(0xC0 + math.floor(unicode_val / 0x40), 0x80 + (unicode_val % 0x40)))
              else
                table.insert(code_chars, string.char(0xE0 + math.floor(unicode_val / 0x1000), 0x80 + math.floor((unicode_val % 0x1000) / 0x40), 0x80 + (unicode_val % 0x40)))
              end
            else
              table.insert(code_chars, '?')
            end
            val_pos = val_pos + 6
          else
            table.insert(code_chars, char)
            val_pos = val_pos + 1
          end
        else
          table.insert(code_chars, char)
          val_pos = val_pos + 1
        end
      else
        table.insert(code_chars, char)
        val_pos = val_pos + 1
      end
    end
    
    local code = table.concat(code_chars)
    
    local result, exec_err = execute_mcp_lua(code, "MCP_" .. cmd_index)
    
    -- 【循环点检测特殊处理】检查结果是否是 [MCP_LOOP_ANALYSIS] 标记
    if result and result:match("^%[MCP_LOOP_ANALYSIS%]") then
      -- 提取文件路径和位置信息（支持可选的section起始时间）
      -- 格式: [MCP_LOOP_ANALYSIS] 文件路径|item位置|item长度|section起始时间
      local file_path, item_pos, item_length, section_start = result:match("^%[MCP_LOOP_ANALYSIS%]%s*([^|]+)|([%d%.]+)|([%d%.]+)|([%d%.]+)$")
      -- 如果没有section_start，尝试匹配没有section的格式
      if not file_path then
          file_path, item_pos, item_length = result:match("^%[MCP_LOOP_ANALYSIS%]%s*([^|]+)|([%d%.]+)|([%d%.]+)$")
          section_start = 0
      end
      section_start = tonumber(section_start) or 0  -- 默认为0
      if file_path then
        -- URL 编码文件路径（处理中文和特殊字符）
        local function url_encode(str)
          if str then
            -- 先处理百分号，避免双重编码
            str = string.gsub(str, "%%", "%%25")
            -- 再处理其他特殊字符
            str = string.gsub(str, " ", "%%20")
            str = string.gsub(str, "&", "%%26")
            str = string.gsub(str, "+", "%%2B")
            str = string.gsub(str, "=", "%%3D")
            str = string.gsub(str, "%?", "%%3F")
            str = string.gsub(str, "#", "%%23")
            -- 处理非ASCII字符（中文等）- 排除已编码的%%xx
            str = string.gsub(str, "([^%w%%%-%.%_/\\:])", function(c)
              if string.match(c, "^%%[0-9A-Fa-f][0-9A-Fa-f]$") then
                return c  -- 已编码的不处理
              end
              return string.format("%%%02X", string.byte(c))
            end)
          end
          return str
        end
        local encoded_path = url_encode(file_path)
        -- 调用 MCP Server 的 analyze_loop_points API
        -- 传递section起始时间和长度，让服务器只分析用户截取的那段
        local api_url = "/analyze_loop_points?file=" .. encoded_path .. "&section_start=" .. tostring(section_start) .. "&section_length=" .. tostring(item_length)
        local analysis_result, analysis_err = MCP.http_get(api_url)
        if analysis_result and analysis_result ~= "" then
          -- 解析 JSON 结果
          local success = analysis_result:find('"success"%s*:%s*true') ~= nil
          if success then
            -- 提取关键字段
            local loop_start = analysis_result:match('"loop_start_time"%s*:%s*([%d%.]+)')
            local loop_end = analysis_result:match('"loop_end_time"%s*:%s*([%d%.]+)')
            local score = analysis_result:match('"correlation_score"%s*:%s*([%d%.]+)')
            local quality = analysis_result:match('"quality"%s*:%s*"([^"]+)"')
            local duration = analysis_result:match('"duration"%s*:%s*([%d%.]+)')
            local sample_rate = analysis_result:match('"sample_rate"%s*:%s*(%d+)')
            local num_channels = analysis_result:match('"num_channels"%s*:%s*(%d+)')
            local zero_crossings = analysis_result:match('"zero_crossings_count"%s*:%s*(%d+)')
            
            -- 转换为工程时间
            local item_pos_num = tonumber(item_pos) or 0
            local loop_start_proj = item_pos_num + (tonumber(loop_start) or 0)
            local loop_end_proj = item_pos_num + (tonumber(loop_end) or tonumber(duration) or 0)
            local loop_dur = loop_end_proj - loop_start_proj
            local score_num = tonumber(score) or 0
            
            -- 设置光标和时间选区
            reaper.SetEditCurPos(loop_start_proj, true, true)
            reaper.GetSet_LoopTimeRange(true, false, loop_start_proj, loop_end_proj, false)
            reaper.UpdateArrange()
            reaper.UpdateTimeline()
            
            -- 生成报告
            local report = "=== 循环区间检测完成 ===\n\n"
            report = report .. "✓ 已自动创建时间选区（蓝色区域）\n"
            report = report .. "✓ 按 Shift+Space 可循环播放测试\n\n"
            report = report .. "=== 音频信息 ===\n"
            report = report .. "文件: " .. file_path .. "\n"
            report = report .. string.format("音频总长度: %.3fs\n", tonumber(duration) or 0)
            report = report .. string.format("采样率: %s Hz\n", sample_rate or "未知")
            report = report .. string.format("声道数: %s\n", num_channels or "未知")
            report = report .. string.format("零交叉点数量: %s\n\n", zero_crossings or "未知")
            report = report .. "=== 建议循环区间 ===\n"
            report = report .. string.format("开始时间: %.4fs\n", loop_start_proj)
            report = report .. string.format("结束时间: %.4fs\n", loop_end_proj)
            report = report .. string.format("循环长度: %.4fs\n", loop_dur)
            report = report .. string.format("相似度评分: %.2f%%\n\n", score_num * 100)
            
            local q = quality or "unknown"
            if q == "excellent" or score_num > 0.9 then
              report = report .. "✓ 优秀: 波形匹配度很高，循环应该很平滑\n"
            elseif q == "good" or score_num > 0.7 then
              report = report .. "○ 良好: 波形匹配度较好，可能有轻微跳变\n"
            elseif q == "fair" or score_num > 0.5 then
              report = report .. "△ 一般: 波形匹配度一般，可能有明显跳变\n"
            else
              report = report .. "✗ 较差: 波形匹配度低，建议手动调整或使用交叉淡化\n"
            end
            
            report = report .. "\n下一步操作:\n"
            report = report .. "• 按 Shift+Space 循环播放测试\n"
            report = report .. "• File → Render 导出循环片段\n"
            report = report .. "• 游戏引擎里直接循环播放此片段\n"
            
            table.insert(results, "[MCP] 命令" .. cmd_index .. " -> " .. report)
          else
            local error_msg = analysis_result:match('"error"%s*:%s*"([^"]+)"') or "分析失败"
            local raw_preview = analysis_result:sub(1, 200)
            has_error = true
            table.insert(results, "[MCP ERROR] 命令" .. cmd_index .. " -> 循环点分析失败: " .. error_msg .. "\n原始响应: " .. raw_preview)
            break
          end
        else
          has_error = true
          table.insert(results, "[MCP ERROR] 命令" .. cmd_index .. " -> 无法获取分析结果: " .. tostring(analysis_err or "空响应"))
          break
        end
      else
        has_error = true
        table.insert(results, "[MCP ERROR] 命令" .. cmd_index .. " -> 无法解析文件路径")
        break
      end
    elseif result then
      table.insert(results, "[MCP] 命令" .. cmd_index .. ": " .. result)
    elseif exec_err then
      has_error = true
      table.insert(results, "[MCP ERROR] 命令" .. cmd_index .. ": " .. exec_err)
      break
    else
      has_error = true
      table.insert(results, "[MCP WARN] 命令" .. cmd_index .. ": 无返回值")
      break
    end
    
    cmd_index = cmd_index + 1
    search_pos = val_pos + 1
  end
  
  if #results == 0 then
    return "MCP 命令解析失败，未找到可执行的命令", nil
  end
  
  if has_error then
    return nil, table.concat(results, "\n")
  end
  
  return table.concat(results, "\n"), nil
end

-- ============================================
-- 启动 MCP 服务器
-- ============================================
local function path_exists(path)
  local f = io.open(path, "r")
  if f then
    f:close()
    return true
  end
  return false
end

local function shell_quote_arg(value)
  value = tostring(value or "")
  return '"' .. value:gsub('"', '""') .. '"'
end

local function vbs_quote(value)
  return '"' .. tostring(value or ""):gsub('"', '""') .. '"'
end

local function launch_log_path()
  local temp_dir = os.getenv("TEMP") or "C:\\Temp"
  return temp_dir .. "\\reaperai_external_launch.log"
end

local function count_process_by_name(name)
  local count = 0
  if reaper.EnumProcesses then
    local i = 0
    while true do
      local ok, proc = pcall(reaper.EnumProcesses, i)
      if not ok or not proc then break end
      if tostring(proc):lower():find(tostring(name or ""):lower(), 1, true) then
        count = count + 1
      end
      i = i + 1
      if i > 10000 then break end
    end
  end
  return count
end

local function log_external_launch(callsite, exe, args, cwd, phase, method, ok, detail)
  local f = io.open(launch_log_path(), "a")
  if not f then return end
  local now = os.date and os.date("%Y-%m-%d %H:%M:%S") or tostring(reaper.time_precise and reaper.time_precise() or os.clock())
  f:write(table.concat({
    now,
    "phase=" .. tostring(phase or ""),
    "callsite=" .. tostring(callsite or ""),
    "method=" .. tostring(method or ""),
    "ok=" .. tostring(ok),
    "exe=" .. tostring(exe or ""),
    "args=" .. tostring(args or ""),
    "cwd=" .. tostring(cwd or ""),
    "WindowsTerminal=" .. tostring(count_process_by_name("WindowsTerminal.exe")),
    "OpenConsole=" .. tostring(count_process_by_name("OpenConsole.exe")),
    "detail=" .. tostring(detail or "")
  }, "\t") .. "\n")
  f:close()
end

local function write_hidden_runner(command, cwd)
  local temp_dir = os.getenv("TEMP") or "C:\\Temp"
  local stamp = tostring(math.floor(((reaper.time_precise and reaper.time_precise()) or os.clock()) * 1000000))
  local path = temp_dir .. "\\rai_hidden_run_" .. stamp .. ".vbs"
  local f = io.open(path, "w")
  if not f then return nil end
  f:write('On Error Resume Next\n')
  f:write('Set sh = CreateObject("WScript.Shell")\n')
  if cwd and cwd ~= "" then
    f:write("sh.CurrentDirectory = " .. vbs_quote(cwd) .. "\n")
  end
  f:write('Set svc = GetObject("winmgmts:{impersonationLevel=impersonate}!\\\\.\\root\\cimv2")\n')
  f:write('Set startup = svc.Get("Win32_ProcessStartup").SpawnInstance_\n')
  f:write('startup.ShowWindow = 0\n')
  f:write('Set proc = svc.Get("Win32_Process")\n')
  if cwd and cwd ~= "" then
    f:write("workdir = " .. vbs_quote(cwd) .. "\n")
  else
    f:write("workdir = Null\n")
  end
  f:write("result = proc.Create(" .. vbs_quote(command) .. ", workdir, startup, pid)\n")
  f:write("If Err.Number <> 0 Or result <> 0 Then\n")
  f:write("  Err.Clear\n")
  f:write("  sh.Run " .. vbs_quote(command) .. ", 0, False\n")
  f:write("End If\n")
  f:write('CreateObject("Scripting.FileSystemObject").DeleteFile WScript.ScriptFullName, True\n')
  f:close()
  return path
end

local function find_wscript()
  local windir = os.getenv("WINDIR") or "C:\\Windows"
  local candidates = {
    windir .. "\\System32\\wscript.exe",
    windir .. "\\SysWOW64\\wscript.exe",
  }
  for _, candidate in ipairs(candidates) do
    if path_exists(candidate) then return candidate end
  end
  return nil
end

local function shell_execute_hidden(exe, args, cwd, callsite)
  exe = tostring(exe or "")
  args = tostring(args or "")
  cwd = tostring(cwd or "")
  if exe == "" then return false, "空 executable" end

  log_external_launch(callsite, exe, args, cwd, "before", "wscript", nil, "request")

  local command = shell_quote_arg(exe) .. (args ~= "" and (" " .. args) or "")
  local runner = write_hidden_runner(command, cwd)
  local wscript = find_wscript()
  if runner and wscript and reaper.BR_Win32_ShellExecute then
    local ok, result = pcall(reaper.BR_Win32_ShellExecute, "open", wscript, "//B //Nologo " .. shell_quote_arg(runner), cwd, 0)
    local success = ok and tonumber(result or 0) and tonumber(result or 0) > 32
    log_external_launch(callsite, wscript, "//B //Nologo " .. runner, cwd, "after", "wscript+BR", success, result)
    if success then
      return true, "wscript+BR_Win32_ShellExecute"
    end
  end

  if runner and wscript and reaper.CF_ShellExecute then
    local ok = pcall(reaper.CF_ShellExecute, runner)
    log_external_launch(callsite, runner, "", cwd, "after", "vbs+CF", ok, "")
    if ok then
      return true, "vbs+CF_ShellExecute"
    end
  end

  log_external_launch(callsite, exe, args, cwd, "after", "none", false, "缺少隐藏启动能力")
  return false, "缺少隐藏启动能力（需要 wscript.exe + SWS BR_Win32_ShellExecute 或 CF_ShellExecute）"
end

local function find_mcp_server_script(base_path)
  local server_script = base_path .. "\\http_server_v2.py"
  if path_exists(server_script) then
    return server_script
  end
  return nil
end

local function find_mcp_launcher(base_path)
  local launcher = base_path .. "\\launch_http_server.py"
  if path_exists(launcher) then
    return launcher
  end
  return nil
end

local function find_python_launcher(base_path)
  local candidates = {}
  local function add(path)
    if path and path ~= "" then table.insert(candidates, path) end
  end
  local function add_prefer_windowless(path)
    if not path or path == "" then return end
    path = tostring(path):gsub("/", "\\")
    local dir = path:match("^(.*\\)[^\\]+$")
    local name = path:match("[^\\]+$")
    if dir and name and name:lower() == "python.exe" then
      add(dir .. "pythonw.exe")
    end
    add(path)
  end
  local function add_path_file(path)
    local f = io.open(path, "r")
    if not f then return end
    local line = f:read("*l")
    f:close()
    add_prefer_windowless(line)
  end
  local function add_python_roots(root)
    if not root or root == "" then return end
    for _, version in ipairs({"314", "313", "312", "311", "310"}) do
      add(root .. "\\Programs\\Python\\Python" .. version .. "\\pythonw.exe")
      add(root .. "\\Programs\\Python\\Python" .. version .. "\\python.exe")
    end
  end
  local function add_program_files(root)
    if not root or root == "" then return end
    for _, version in ipairs({"314", "313", "312", "311", "310"}) do
      add(root .. "\\Python" .. version .. "\\pythonw.exe")
      add(root .. "\\Python" .. version .. "\\python.exe")
    end
  end

  add(base_path .. "\\.venv\\Scripts\\pythonw.exe")
  add(base_path .. "\\.venv\\Scripts\\python.exe")
  add(base_path .. "\\python_runtime\\pythonw.exe")
  add(base_path .. "\\python_runtime\\python.exe")
  add(base_path .. "\\.python\\pythonw.exe")
  add(base_path .. "\\.python\\python.exe")
  add_path_file(base_path .. "\\pythonw_path.txt")
  add_path_file(base_path .. "\\python_path.txt")
  add_python_roots(os.getenv("LOCALAPPDATA") or "")
  add_program_files(os.getenv("ProgramFiles") or "")
  add_program_files(os.getenv("ProgramFiles(x86)") or "")

  for _, candidate in ipairs(candidates) do
    if candidate and candidate ~= "" and path_exists(candidate) then
      return candidate
    end
  end
  return nil
end

local function launch_mcp_server_direct(base_path)
  if not find_mcp_server_script(base_path) then
    return false, "未找到 http_server_v2.py"
  end

  local launcher = find_mcp_launcher(base_path)
  if not launcher then
    return false, "未找到 launch_http_server.py"
  end

  local python_cmd = find_python_launcher(base_path)
  if not python_cmd then
    return false, "未找到 Python/pythonw.exe"
  end

  local ok, result = shell_execute_hidden(python_cmd, shell_quote_arg(launcher), base_path, "launch_mcp_server")
  if ok then
    return true, "MCP 服务器已启动 (" .. tostring(result) .. ")"
  end
  return false, tostring(result or "隐藏启动失败")
end

local function launch_mcp_shutdown_direct(base_path)
  local launcher = find_mcp_launcher(base_path)
  if not launcher then
    return false, "未找到 launch_http_server.py"
  end

  local python_cmd = find_python_launcher(base_path)
  if not python_cmd then
    return false, "未找到 Python/pythonw.exe"
  end

  local ok, result = shell_execute_hidden(python_cmd, shell_quote_arg(launcher) .. " --shutdown", base_path, "launch_mcp_shutdown")
  if ok then
    return true, "MCP 后台关闭任务已启动"
  end
  return false, tostring(result or "关闭任务启动失败")
end

local function launch_mcp_probe_direct(base_path, wait_seconds)
  local launcher = find_mcp_launcher(base_path)
  if not launcher then
    return false, "未找到 launch_http_server.py"
  end

  local python_cmd = find_python_launcher(base_path)
  if not python_cmd then
    return false, "未找到 Python/pythonw.exe"
  end

  local wait_arg = tostring(wait_seconds or 0)
  local ok, result = shell_execute_hidden(python_cmd, shell_quote_arg(launcher) .. " --probe " .. wait_arg, base_path, "launch_mcp_probe")
  if ok then
    return true, "MCP 后台探针已启动"
  end
  return false, tostring(result or "探针任务启动失败")
end

local function write_mcp_status_hint(base_path, state_name, detail)
  local path = tostring(base_path or "") .. "\\mcp_server_status.json"
  local f = io.open(path, "w")
  if not f then return end
  f:write(
    '{"ok": false, "ping_ok": false, "port_open": false, "endpoint_count": 0, ' ..
    '"state": "' .. tostring(state_name or "unknown") .. '", ' ..
    '"detail": "' .. tostring(detail or ""):gsub('"', '\\"') .. '"}\n'
  )
  f:close()
end

local function write_mcp_shutdown_hint(base_path)
  local path = tostring(base_path or "") .. "\\mcp_server_shutdown.log"
  local f = io.open(path, "w")
  if f then
    f:write('{"ok": false, "method": "pending"}\n')
    f:close()
  end
end

-- 从 config.json 读取 REAPER 资源路径
local function get_reaper_path_from_config()
  local config_paths = {
    RAI_SCRIPT_DIR .. "..\\MCP_Server\\config.json",
    reaper.GetResourcePath() .. "\\MCP_Server\\config.json",
    reaper.GetResourcePath() .. "\\Scripts\\MCP_Server\\config.json",
    os.getenv("USERPROFILE") .. "\\Documents\\REAPER\\MCP_Server\\config.json",
  }
  
  for _, config_path in ipairs(config_paths) do
    local f = io.open(config_path, "r")
    if f then
      local content = f:read("*a")
      f:close()
      if content then
        -- 简单解析 JSON 中的 reaper_resource_path
        local path = content:match('"reaper_resource_path"%s*:%s*"([^"]+)"')
        if path then
          -- 转换正斜杠为反斜杠
          path = path:gsub("/", "\\")
          return path
        end
      end
    end
  end
  return nil
end

local function build_mcp_search_paths()
  local config_path = get_reaper_path_from_config()
  local search_paths = {}
  
  if config_path then
    -- 使用 config.json 中的路径优先
    table.insert(search_paths, config_path .. "\\MCP_Server")
    table.insert(search_paths, config_path .. "\\Scripts\\reaper-mcp-server")
    table.insert(search_paths, config_path .. "\\reaper-mcp-server")
  end
  
  -- 添加默认搜索路径
  local default_paths = {
    RAI_SCRIPT_DIR .. "..\\MCP_Server",
    RAI_SCRIPT_DIR .. "MCP_Server",
    reaper.GetResourcePath() .. "\\MCP_Server",
    reaper.GetResourcePath() .. "\\Scripts\\MCP_Server",
    reaper.GetResourcePath() .. "\\Scripts\\reaper-mcp-server",
    reaper.GetResourcePath() .. "\\reaper-mcp-server",
    os.getenv("USERPROFILE") .. "\\Documents\\reaper-mcp-server",
  }
  
  for _, path in ipairs(default_paths) do
    table.insert(search_paths, path)
  end

  return search_paths
end

local function build_mcp_action_paths()
  local result, seen = {}, {}
  if state.mcp_server_base_path and state.mcp_server_base_path ~= "" then
    table.insert(result, state.mcp_server_base_path)
    seen[state.mcp_server_base_path] = true
  end
  for _, path in ipairs(build_mcp_search_paths()) do
    if path and path ~= "" and not seen[path] then
      seen[path] = true
      table.insert(result, path)
    end
  end
  return result
end

local function request_mcp_probe_async(wait_seconds)
  local now = reaper.time_precise() or 0
  if now - (state.mcp_last_probe_at or 0) < 0.4 then
    return true, "探针已在后台运行"
  end

  for _, base_path in ipairs(build_mcp_action_paths()) do
    if find_mcp_launcher(base_path) then
      state.mcp_last_probe_at = now
      state.mcp_server_base_path = base_path
      return launch_mcp_probe_direct(base_path, wait_seconds or 0)
    end
  end

  return false, "未找到 MCP 后台探针入口"
end

local function launch_mcp_server()
  state.exec_mode = true
  state.mcp_running = false
  state.mcp_status = "启动中"
  state.mcp_capabilities = nil
  state.mcp_endpoint_count = 0
  state.mcp_real_connected = false
  state.mcp_real_endpoint_count = 0
  state.status = "执行模式已开启，正在尝试连接 MCP；MCP 离线时将使用本地执行"
  state.mcp_status_detail = "本地执行模式已可用，MCP 正在后台连接"

  local search_paths = build_mcp_search_paths()

  for _, base_path in ipairs(search_paths) do
    if find_mcp_server_script(base_path) then
      write_mcp_status_hint(base_path, "starting", "server launch requested")
      local direct_ok, direct_msg = launch_mcp_server_direct(base_path)
      if direct_ok then
        state.mcp_server_base_path = base_path
        state.mcp_start_pending = true
        state.mcp_start_started_at = reaper.time_precise() or 0
        state.mcp_shutdown_pending = false
        state.mcp_running = false
        state.exec_mode = true
        state.mcp_status = "启动中"
        state.status = "执行模式已开启，MCP 启动中（本地执行可用）"
        state.mcp_status_detail = direct_msg
        return true, "执行模式已开启，MCP 启动中（本地执行可用）"
      end
      state.mcp_start_pending = false
      state.mcp_shutdown_pending = false
      state.mcp_running = false
      state.exec_mode = true
      state.mcp_status = "离线"
      state.mcp_capabilities = nil
      state.mcp_endpoint_count = 0
      state.mcp_real_connected = false
      state.mcp_real_endpoint_count = 0
      state.mcp_status_detail = "MCP 启动失败，已进入本地执行模式: " .. tostring(direct_msg)
      state.status = "执行模式已开启（MCP 离线，本地执行）"
      return true, "执行模式已开启；MCP 启动失败，已使用本地执行"
    end
  end
  
  state.mcp_start_pending = false
  state.mcp_shutdown_pending = false
  state.mcp_running = false
  state.exec_mode = true
  state.mcp_status = "离线"
  state.mcp_capabilities = nil
  state.mcp_endpoint_count = 0
  state.mcp_real_connected = false
  state.mcp_real_endpoint_count = 0
  state.mcp_status_detail = "找不到 MCP 服务器启动入口，已进入本地执行模式"
  state.status = "执行模式已开启（MCP 离线，本地执行）"
  return true, "执行模式已开启；找不到 MCP 启动入口，已使用本地执行"
end

local function enable_mcp_execution_mode(snapshot)
  apply_mcp_status_snapshot(snapshot or read_mcp_status_snapshot())
  state.mcp_running = true
  state.mcp_status = "正常"
  state.exec_mode = true
  state.mcp_start_pending = false
  state.mcp_shutdown_pending = false
  state.status = "MCP 已连接"
end

local function finalize_mcp_shutdown()
  state.mcp_shutdown_pending = false
  state.mcp_start_pending = false
  state.mcp_running = false
  state.exec_mode = false
  state.mcp_status = "离线"
  state.mcp_capabilities = nil
  state.mcp_endpoint_count = 0
  state.mcp_real_connected = false
  state.mcp_real_endpoint_count = 0
  state.mcp_real_pid = nil
  state.mcp_last_check_text = "未连接"
  state.status = "MCP 已关闭"
  state.mcp_status_detail = "后台确认关闭"
end

local function request_mcp_shutdown_async()
  state.mcp_shutdown_pending = true
  state.mcp_shutdown_started_at = reaper.time_precise() or 0
  state.mcp_start_pending = false
  state.mcp_running = false
  state.exec_mode = false
  state.mcp_status = "关闭中"
  state.status = "MCP 关闭中"
  state.mcp_status_detail = "后台关闭任务已请求"

  for _, base_path in ipairs(build_mcp_action_paths()) do
    if find_mcp_launcher(base_path) then
      state.mcp_server_base_path = base_path
      write_mcp_shutdown_hint(base_path)
      local ok, msg = launch_mcp_shutdown_direct(base_path)
      state.mcp_status_detail = msg
      if ok then
        return true, msg
      end
      state.mcp_shutdown_pending = false
      state.status = "MCP 关闭失败"
      return false, msg
    end
  end

  state.mcp_shutdown_pending = false
  state.status = "MCP 关闭失败"
  state.mcp_status_detail = "未找到 MCP 后台关闭入口"
  return false, state.mcp_status_detail
end

local function clear_conversation_from_ui()
  return reset_conversation_state("clear")
end

local function exit_execution_mode()
  reset_conversation_state("exit_execution", { status = "正在退出执行..." })
  if state.mcp_running or state.mcp_start_pending or state.mcp_shutdown_pending then
    return request_mcp_shutdown_async()
  end
  if state.exec_mode then
    state.exec_mode = false
    state.mcp_running = false
    state.mcp_start_pending = false
    state.mcp_shutdown_pending = false
    state.mcp_status = "离线"
    state.mcp_status_detail = "已退出本地执行模式"
    state.status = "已退出执行"
    return true, "已退出执行"
  end
  return true, "已退出执行"
end

local function process_mcp_background_tasks()
  local now = reaper.time_precise() or 0
  local snapshot = nil
  if now - (state.mcp_last_status_read_at or 0) >= 0.25 then
    snapshot = read_mcp_status_snapshot()
    if snapshot then
      apply_mcp_status_snapshot(snapshot)
    end
    state.mcp_last_status_read_at = now
  end

  if state.mcp_start_pending then
    if snapshot and snapshot.ok then
      enable_mcp_execution_mode(snapshot)
      return
    end

    local elapsed = now - (state.mcp_start_started_at or 0)
    local installing_runtime = snapshot and snapshot.state == "installing"
    local startup_timeout = installing_runtime and 180 or 25
    if elapsed > startup_timeout then
      state.mcp_start_pending = false
      state.mcp_running = false
      state.mcp_status = "离线"
      state.exec_mode = true
      state.mcp_capabilities = nil
      state.mcp_endpoint_count = 0
      state.mcp_real_connected = false
      state.mcp_real_endpoint_count = 0
      state.status = "执行模式已开启（MCP 启动超时，本地执行）"
      state.mcp_status_detail = (snapshot and snapshot.detail and snapshot.detail ~= "" and snapshot.detail)
        or "后台探针未确认连接，已保留本地执行模式；请查看 mcp_server_launch.log"
      return
    end

    if installing_runtime then
      state.status = "执行模式已开启，MCP 安装依赖中（本地执行可用）"
      state.mcp_status_detail = snapshot.detail or state.mcp_status_detail
    else
      state.status = "执行模式已开启，MCP 启动中（本地执行可用）"
    end
    if not installing_runtime and now - (state.mcp_last_probe_at or 0) > 1.5 then
      request_mcp_probe_async(3)
    end
  end

  if state.mcp_shutdown_pending then
    local shutdown_log = read_mcp_shutdown_log()
    local closed_by_log = shutdown_log and shutdown_log:find('"ok"%s*:%s*true') ~= nil
    local closed_by_snapshot = snapshot and snapshot.ok == false and snapshot.port_open == false and snapshot.state == "offline"

    if closed_by_log or closed_by_snapshot then
      finalize_mcp_shutdown()
      return
    end

    local elapsed = now - (state.mcp_shutdown_started_at or 0)
    if elapsed > 8 then
      state.mcp_shutdown_pending = false
      state.mcp_running = false
      state.exec_mode = false
      state.mcp_status = "未知"
      state.status = "MCP 关闭待确认"
      state.mcp_status_detail = "后台关闭任务超时，请查看工程信息"
      request_mcp_probe_async(0)
      return
    end

    state.status = "MCP 关闭中"
    if now - (state.mcp_last_probe_at or 0) > 1.8 then
      request_mcp_probe_async(0)
    end
  end
end

-- ============================================
-- UI 模块入口
-- ============================================
local function make_ui_context()
  return {
    state = state,
    config = CONFIG,
    llm_providers = LlmProviders,
    elevenlabs = ElevenLabs,
    async_pipe = AsyncPipe,
    callbacks = {
      open_config_editor = open_config_editor,
      load_config = load_config,
      save_config = save_config,
      remember_llm_model = LlmSettings.remember_model,
      refresh_llm_models = LlmSettings.refresh_models,
      refresh_elevenlabs_voices = ElevenVoiceSettings.refresh_voices,
      test_llm_connection = LlmSettings.test_connection,
      get_local_capability_status = get_local_capability_status,
      run_api_probe = run_api_probe_from_ui,
      run_action_probe = run_action_probe_from_ui,
      run_all_capability_probes = run_all_capability_probes_from_ui,
      launch_mcp_server = launch_mcp_server,
      request_mcp_shutdown_async = request_mcp_shutdown_async,
      exit_execution_mode = exit_execution_mode,
      clear_conversation = clear_conversation_from_ui,
      request_mcp_probe_async = request_mcp_probe_async,
      get_selection_context = get_selection_context,
      execute_pending_operation = execute_pending_operation,
      cancel_pending_operation = cancel_pending_operation,
      submit_clarification_answer = submit_pending_clarification_answer,
      cancel_generation = reaperai_cancel_generation,
      retry_message = reaperai_retry_message,
      send_elevenlabs_request = send_elevenlabs_request,
      send_request = send_request,
      operation_risk_label = operation_risk_label,
      operation_step_label = operation_step_label,
    }
  }
end

render_operation_cards = function()
  return UI.render_operation_cards(make_ui_context())
end

function reaperai_render()
  return UI.render(make_ui_context())
end

function reaperai_cleanup_on_window_close()
  reset_conversation_state("window_close", { status = "窗口关闭中..." })
  release_reaperai_instance()

  if not (state.mcp_running or state.mcp_start_pending or state.mcp_shutdown_pending) then
    return true, "无需关闭"
  end

  local async_ok, async_started, async_msg = pcall(request_mcp_shutdown_async)
  if async_ok and async_started then
    return true, async_msg or "MCP 已在窗口关闭时请求后台关闭"
  end

  return false, "MCP 窗口关闭清理失败"
end

-- ============================================
-- 主循环 (v1.0 异步响应直接在回调中处理)
-- ============================================
function reaperai_main()
  if not is_current_reaperai_instance() then
    stop_stale_reaperai_instance()
    return
  end

  if not init() then return end

  -- v1.0 修改：异步响应直接在回调中处理
  -- 这里只检查同步响应或更新状态
  if state.waiting then
    local r, e = check_resp()
    -- 同步模式下处理响应
    if r then
      table.insert(state.messages, {role = "assistant", content = strip_intent_block_for_display(r)})
      
      -- 执行模式下先生成待确认 Operation，不再自动执行
      if state.exec_mode then
        queue_operation_for_confirmation(r, state.last_user_request)
      end
      
      state.waiting = false
      state.scroll = true
    elseif e then
      table.insert(state.messages, {
        role = "assistant",
        content = "⚠️ 请求失败: " .. e
      })
      state.waiting = false
      state.status = e
    end
  end

  process_mcp_background_tasks()

  local cont = reaperai_render()
  if cont then
    reaper.defer(reaperai_main)
  else
    reaperai_cleanup_on_window_close()
    state.ctx = nil
  end
end

-- ============================================
-- 启动
-- ============================================
claim_reaperai_instance()
load_config()
state.show_settings = false
state.show_audio = false

if CONFIG.llm_key == "" or CONFIG.llm_key == "在此填入你的 API Key" then
  state.status = "请先在设置面板填写 LLM API Key"
end

reaperai_main()

