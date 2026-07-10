local Waiting = {}

local WAIT_PHASES = {
  chat = {
    {0, "正在连接 LLM..."},
    {2, "正在理解你的问题..."},
    {6, "正在组织回复..."},
    {14, "正在等待完整回复..."},
  },
  exec_plan = {
    {0, "正在生成执行计划..."},
    {2, "正在同步工程状态..."},
    {5, "正在理解你的执行需求..."},
    {9, "正在检查风险和操作范围..."},
    {15, "正在准备确认卡..."},
    {24, "仍在等待完整计划..."},
  },
  audio_vox = {
    {0, "正在解析 VOX 语义..."},
    {3, "正在选择声音..."},
    {7, "正在等待 ElevenLabs 生成语音..."},
    {15, "正在准备导入 REAPER..."},
  },
  audio_sfx = {
    {0, "正在解析 SFX 描述..."},
    {3, "正在准备音效提示词..."},
    {7, "正在等待 ElevenLabs 生成音效..."},
    {18, "正在准备导入 REAPER..."},
  },
  generic = {
    {0, "请求中..."},
    {5, "仍在等待响应..."},
    {15, "请求耗时较长，请稍候..."},
  },
}

local function now_seconds()
  local r = _G.reaper
  if r and r.time_precise then
    local ok, value = pcall(r.time_precise)
    if ok and value then return value end
  end
  return os.clock()
end

function Waiting.phase_text(kind, elapsed)
  local phases = WAIT_PHASES[kind or ""] or WAIT_PHASES.generic
  elapsed = tonumber(elapsed or 0) or 0
  local text = phases[1] and phases[1][2] or "请求中..."
  for _, phase in ipairs(phases) do
    if elapsed >= (phase[1] or 0) then
      text = phase[2] or text
    else
      break
    end
  end
  return text
end

function Waiting.start(state, kind, user_request)
  if not state then return end
  state.waiting = true
  state.wait_kind = kind or "generic"
  state.wait_started_at = now_seconds()
  state.wait_user_request = tostring(user_request or "")
  state.status = Waiting.phase_text(state.wait_kind, 0)
end

function Waiting.clear(state)
  if not state then return end
  state.wait_started_at = 0
  state.wait_kind = ""
  state.wait_user_request = ""
end

function Waiting.update(state)
  if not state or not state.waiting then return end
  local elapsed = now_seconds() - (state.wait_started_at or now_seconds())
  local text = Waiting.phase_text(state.wait_kind, elapsed)
  state.status = text
  if state.audio_waiting then
    state.audio_status = text
  end
  if state.pending_operation and state.pending_operation.placeholder then
    state.pending_operation.summary = tostring(state.wait_user_request or state.pending_operation.summary or "")
    state.pending_operation.phase_text = text
    state.pending_operation.elapsed = elapsed
  end
end

function Waiting.operation_status(op, fallback_status)
  if op and op.placeholder then return op.phase_text or fallback_status or "正在生成执行计划" end
  if op and op.needs_clarification then return "Needs clarification" end
  if op and op.preflight_ok == false then return "Pending operation" end
  return "Pending operation"
end

function Waiting.show_operation_placeholder(state, user_request, opts)
  if not state then return end
  opts = opts or {}
  state.pending_operation = {
    id = "placeholder_" .. tostring(math.floor(now_seconds() * 1000)),
    placeholder = true,
    status = "generating",
    source = "LLM",
    risk = "pending",
    user_risk = "pending",
    user_risk_label = "生成中",
    placeholder_title = opts.title or "正在生成执行计划",
    summary = tostring(user_request or ""),
    phase_text = state.status or "正在生成执行计划...",
    elapsed = 0,
    parts = {},
    mcp_calls = {},
    script_count = 0,
    preflight_ok = nil,
    needs_clarification = false,
  }
  state.scroll = true
end

function Waiting.clear_operation_placeholder(state)
  if state and state.pending_operation and state.pending_operation.placeholder then
    state.pending_operation = nil
  end
end

function Waiting.begin_audio_request(state, mode)
  if not state then return end
  state.audio_pending_count = (state.audio_pending_count or 0) + 1
  state.audio_waiting = true
  state.audio_wait_kind = (mode == "vox") and "audio_vox" or "audio_sfx"
  state.audio_started_at = now_seconds()
  Waiting.start(state, state.audio_wait_kind, "")
  state.audio_status = state.status
end

function Waiting.finish_audio_request(state, text)
  if not state then return end
  state.audio_pending_count = math.max(0, (state.audio_pending_count or 1) - 1)
  state.audio_waiting = state.audio_pending_count > 0
  state.audio_status = tostring(text or state.audio_status or "")
  if not state.audio_waiting then
    state.audio_wait_kind = ""
    state.audio_started_at = 0
  end
end

return Waiting
