-- ============================================
-- REAPER AI 异步 HTTP 模块 - 文件信号版
-- 作者：zhanghuisen
-- 版本：v1.0
-- 解决 curl 阻塞问题
-- ============================================

-- v1.0 修改：支持多个并发请求
local AsyncPipe = {
  pending_requests = {},  -- 改为数组，支持多个并发请求
}

-- 生成唯一请求 ID
local function generate_request_id()
  return tostring(math.random(1000000, 9999999)) .. "_" .. tostring(reaper.time_precise()):gsub("%.", "")
end

-- 文件是否存在
local function file_exists(path)
  local f = io.open(path, "r")
  if f then
    f:close()
    return true
  end
  return false
end

local function read_pid_file(path)
  if not path or path == "" then return nil end
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a") or ""
  f:close()
  local pid = tostring(content):match("(%d+)")
  return pid
end

local function write_cancel_file(path)
  if not path or path == "" then return end
  local f = io.open(path, "w")
  if not f then return end
  f:write("cancelled")
  f:close()
end

local function ps_quote(value)
  return "'" .. tostring(value or ""):gsub("'", "''") .. "'"
end

local function kill_worker_by_request_id(request_id)
  request_id = tostring(request_id or "")
  if request_id == "" then return false end
  if not (os.getenv("OS") and tostring(os.getenv("OS")):lower():find("windows", 1, true)) then return false end
  local temp_dir = os.getenv("TEMP") or "C:\\Temp"
  local script_path = temp_dir .. "\\rai_kill_" .. request_id:gsub("[^%w_%-]", "_") .. ".ps1"
  local f = io.open(script_path, "w")
  if not f then return false end
  f:write("$needle = " .. ps_quote(request_id) .. "\n")
  f:write("Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($needle) -and $_.Name -like 'python*.exe' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }\n")
  f:close()
  local cmd = 'powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' .. script_path .. '" >NUL 2>NUL'
  local ok = pcall(os.execute, cmd)
  pcall(function() os.remove(script_path) end)
  return ok == true
end

local function wait_for_pid_file(path, timeout_ms)
  local pid = read_pid_file(path)
  if pid then return pid end
  local deadline = ((reaper.time_precise and reaper.time_precise()) or os.clock()) + ((tonumber(timeout_ms) or 0) / 1000)
  while (((reaper.time_precise and reaper.time_precise()) or os.clock()) < deadline) do
    if reaper.Sleep then reaper.Sleep(50) end
    pid = read_pid_file(path)
    if pid then return pid end
  end
  return nil
end

local function kill_worker_pid(pid)
  pid = tostring(pid or ""):match("(%d+)")
  if not pid or pid == "" then return false end
  if os.getenv("OS") and tostring(os.getenv("OS")):lower():find("windows", 1, true) then
    local cmd = "taskkill /PID " .. pid .. " /T /F >NUL 2>NUL"
    local ok = pcall(os.execute, cmd)
    return ok == true
  end
  return false
end

local function terminate_request_worker(req, wait_ms)
  if not req then return false end
  write_cancel_file(req.cancel_file)
  local pid = read_pid_file(req.pid_file)
  if not pid and wait_ms and wait_ms > 0 then
    pid = wait_for_pid_file(req.pid_file, wait_ms)
  end
  local killed = pid and kill_worker_pid(pid) or false
  local killed_by_scan = kill_worker_by_request_id(req.id)
  return killed or killed_by_scan
end

local function json_string_field(line, key)
  line = tostring(line or "")
  local _, pos = line:find('"' .. tostring(key or "") .. '"%s*:%s*"')
  if not pos then return nil end

  local out = {}
  local i = pos + 1
  while i <= #line do
    local ch = line:sub(i, i)
    if ch == '"' then
      return table.concat(out)
    elseif ch == "\\" then
      local esc = line:sub(i + 1, i + 1)
      if esc == '"' or esc == "\\" or esc == "/" then
        table.insert(out, esc)
        i = i + 2
      elseif esc == "n" then
        table.insert(out, "\n")
        i = i + 2
      elseif esc == "r" then
        table.insert(out, "\r")
        i = i + 2
      elseif esc == "t" then
        table.insert(out, "\t")
        i = i + 2
      elseif esc == "b" or esc == "f" then
        i = i + 2
      elseif esc == "u" then
        local hex = line:sub(i + 2, i + 5)
        local code = tonumber(hex, 16)
        if code and code < 128 then
          table.insert(out, string.char(code))
        else
          table.insert(out, "\\u" .. hex)
        end
        i = i + 6
      else
        table.insert(out, esc)
        i = i + 2
      end
    else
      table.insert(out, ch)
      i = i + 1
    end
  end

  return nil
end

local function emit_stream_event(req, event)
  if req and req.on_stream then
    pcall(req.on_stream, event)
  end
end

local function dispatch_stream_line(req, line)
  line = tostring(line or ""):gsub("\r$", "")
  if line == "" then return end

  local event_type = json_string_field(line, "type")
  if not event_type then return end

  if event_type == "delta" then
    local content = json_string_field(line, "content") or ""
    if content ~= "" then
      req.stream_text = tostring(req.stream_text or "") .. content
      emit_stream_event(req, { type = "delta", content = content, request_id = req.id })
    end
  elseif event_type == "reasoning_delta" then
    local content = json_string_field(line, "content") or ""
    if content ~= "" then
      req.stream_reasoning = tostring(req.stream_reasoning or "") .. content
      emit_stream_event(req, { type = "reasoning_delta", content = content, request_id = req.id })
    end
  elseif event_type == "tool_call" then
    local tool_event = {
      type = "tool_call",
      request_id = req.id,
      index = json_string_field(line, "index") or "",
      id = json_string_field(line, "id") or "",
      call_type = json_string_field(line, "call_type") or "tool",
      name = json_string_field(line, "name") or "",
      arguments = json_string_field(line, "arguments") or "",
    }
    req.stream_tool_call_count = (tonumber(req.stream_tool_call_count or 0) or 0) + 1
    emit_stream_event(req, tool_event)
  elseif event_type == "finish" then
    req.stream_finish_reason = json_string_field(line, "finish_reason") or ""
    emit_stream_event(req, { type = "finish", finish_reason = req.stream_finish_reason, request_id = req.id })
  elseif event_type == "done" then
    req.stream_final_content = json_string_field(line, "content") or tostring(req.stream_text or "")
    emit_stream_event(req, { type = "done", content = req.stream_final_content, request_id = req.id })
  elseif event_type == "error" then
    req.stream_error = json_string_field(line, "message") or "请求失败"
    emit_stream_event(req, { type = "error", message = req.stream_error, request_id = req.id })
  elseif event_type == "start" then
    emit_stream_event(req, { type = "start", request_id = req.id })
  end
end

local function process_stream_events(req, flush_remaining)
  if not req or not req.is_stream then return end

  local f = io.open(req.resp_file, "r")
  if f then
    if req.stream_pos and req.stream_pos > 0 then
      pcall(function() f:seek("set", req.stream_pos) end)
    end
    local chunk = f:read("*a") or ""
    req.stream_pos = f:seek() or req.stream_pos or 0
    f:close()

    if chunk ~= "" then
      req.stream_buffer = tostring(req.stream_buffer or "") .. chunk
    end
  end

  while req.stream_buffer and req.stream_buffer ~= "" do
    local newline = req.stream_buffer:find("\n", 1, true)
    if not newline then break end

    local line = req.stream_buffer:sub(1, newline - 1)
    req.stream_buffer = req.stream_buffer:sub(newline + 1)
    dispatch_stream_line(req, line)
  end

  if flush_remaining and req.stream_buffer and req.stream_buffer ~= "" then
    dispatch_stream_line(req, req.stream_buffer)
    req.stream_buffer = ""
  end
end

local function cmd_quote_arg(value)
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
    if file_exists(candidate) then return candidate end
  end
  return nil
end

local function shell_execute_hidden(exe, args, cwd, callsite)
  exe = tostring(exe or "")
  args = tostring(args or "")
  cwd = tostring(cwd or "")
  if exe == "" then return false, "空 executable" end

  log_external_launch(callsite, exe, args, cwd, "before", "wscript", nil, "request")

  local command = cmd_quote_arg(exe) .. (args ~= "" and (" " .. args) or "")
  local runner = write_hidden_runner(command, cwd)
  local wscript = find_wscript()
  if runner and wscript and reaper.BR_Win32_ShellExecute then
    local ok, result = pcall(reaper.BR_Win32_ShellExecute, "open", wscript, "//B //Nologo " .. cmd_quote_arg(runner), cwd, 0)
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

local function find_pythonw(worker_dir)
  local candidates = {}
  local localapp = os.getenv("LOCALAPPDATA") or ""
  local userprofile = os.getenv("USERPROFILE") or ""
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

  if worker_dir and worker_dir ~= "" then
    add(worker_dir .. "\\.venv\\Scripts\\pythonw.exe")
    add(worker_dir .. "\\.venv\\Scripts\\python.exe")
    add(worker_dir .. "\\python_runtime\\pythonw.exe")
    add(worker_dir .. "\\python_runtime\\python.exe")
    add(worker_dir .. "\\.python\\pythonw.exe")
    add(worker_dir .. "\\.python\\python.exe")
    add_path_file(worker_dir .. "\\pythonw_path.txt")
    add_path_file(worker_dir .. "\\python_path.txt")
  end
  add_python_roots(localapp)
  if userprofile ~= "" then
    add_python_roots(userprofile .. "\\AppData\\Local")
  end
  add_program_files(os.getenv("ProgramFiles") or "")
  add_program_files(os.getenv("ProgramFiles(x86)") or "")

  for _, candidate in ipairs(candidates) do
    if candidate and candidate ~= "" and file_exists(candidate) then
      return candidate
    end
  end
  return nil
end

-- ============================================
-- 启动异步 HTTP 请求
-- ============================================
-- v1.0 修改：支持多个并发请求（允许多个 pending_request）
function AsyncPipe.send_request(api_url, api_key, model, messages, on_complete, mode, on_stream)
  -- v1.0+ 新增 mode 参数：
  --   mode 省略或为 "llm": 调用 LLM API (默认)
  --   mode 为 "elevenlabs" 或 "audio": 调用音频 worker 生成音频
  --   mode 为 "doubao_voices": 调用音频 worker 检测豆包账户音色
  
  mode = mode or "llm"
  local is_stream = mode == "llm_stream"
  
  local request_id = generate_request_id()
  local temp_dir = os.getenv("TEMP") or "C:\\Temp"
  
  local msg_file = temp_dir .. "\\rai_msg_" .. request_id .. ".json"
  local resp_file = temp_dir .. "\\rai_resp_" .. request_id .. ".json"
  local signal_file = temp_dir .. "\\rai_signal_" .. request_id .. ".txt"
  local key_file = temp_dir .. "\\rai_key_" .. request_id .. ".txt"  -- 安全：key不放命令行
  local pid_file = temp_dir .. "\\rai_pid_" .. request_id .. ".txt"
  local cancel_file = temp_dir .. "\\rai_cancel_" .. request_id .. ".flag"
  
  -- 保存消息到临时文件
  local f = io.open(msg_file, "w")
  if not f then
    return nil, "无法创建消息文件"
  end
  
  if mode == "elevenlabs" or mode == "audio" or mode == "doubao_voices" then
    -- 音频模式：messages 是 worker 需要的 JSON 字符串
    local text_content = messages
    if type(messages) == "table" and messages[1] then
      text_content = messages[1].content or ""
    end
    f:write(text_content)
  else
    -- 默认 LLM 模式：构建 JSON 数组
    local json_parts = {'['}
    for i, msg in ipairs(messages) do
      if i > 1 then table.insert(json_parts, ',') end
      table.insert(json_parts, '{"role":"')
      table.insert(json_parts, msg.role)
      table.insert(json_parts, '","content":"')
      local content = msg.content:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "")
      table.insert(json_parts, content)
      table.insert(json_parts, '"}')
    end
    table.insert(json_parts, ']')
    f:write(table.concat(json_parts))
  end
  f:close()
  
  -- 将 api_key 写入单独临时文件（避免裸露在命令行进程列表中）
  local kf = io.open(key_file, "w")
  if kf then
    kf:write(api_key)
    kf:close()
  end
  
  -- 自动查找 worker 路径
  local userprofile = os.getenv("USERPROFILE") or ""
  local worker_paths = {
    -- 常见安装位置
    "C:\\Program Files\\REAPER\\MCP_Server\\rai_http_worker_v2.py",
  }
  if userprofile ~= "" then
    table.insert(worker_paths, userprofile .. "\\Documents\\REAPER\\MCP_Server\\rai_http_worker_v2.py")
  end
  
  -- 也检查脚本所在目录的 MCP_Server 子目录
  local script_dir = reaper.GetResourcePath() .. "\\Scripts"
  table.insert(worker_paths, 1, script_dir .. "\\..\\MCP_Server\\rai_http_worker_v2.py")
  table.insert(worker_paths, 1, script_dir .. "\\MCP_Server\\rai_http_worker_v2.py")
  
  local worker_path = nil
  for _, path in ipairs(worker_paths) do
    local f = io.open(path, "r")
    if f then
      f:close()
      worker_path = path
      break
    end
  end
  
  if not worker_path then
    return nil, "找不到 rai_http_worker_v2.py，请确保 MCP_Server 文件夹已正确放置"
  end
  
  local worker_dir = worker_path:match("(.*)\\[^\\]+")
  
  -- 创建日志文件用于调试
  local log_file = temp_dir .. "\\rai_worker_" .. request_id .. ".log"
  
  -- 清理旧的信号文件（如果存在）
  os.remove(signal_file)
  os.remove(resp_file)
  os.remove(pid_file)
  os.remove(cancel_file)

  local python_cmd = find_pythonw(worker_dir)
  if not python_cmd then
    return nil, "找不到 Python/pythonw.exe，请确保 Python 已安装"
  end

  local launcher_path = worker_dir and (worker_dir .. "\\launch_rai_worker.py") or nil
  if not launcher_path or not file_exists(launcher_path) then
    return nil, "找不到 launch_rai_worker.py，请确保 MCP_Server 已更新"
  end

  local args = cmd_quote_arg(launcher_path)
    .. " --worker " .. cmd_quote_arg(worker_path)
    .. " --log " .. cmd_quote_arg(log_file)
    .. " --pid-file " .. cmd_quote_arg(pid_file)
    .. " --cancel-file " .. cmd_quote_arg(cancel_file)
    .. " --"
    .. " " .. cmd_quote_arg(request_id)
    .. " " .. cmd_quote_arg(api_url)
    .. " " .. cmd_quote_arg(key_file)
    .. " " .. cmd_quote_arg(model)
    .. " " .. cmd_quote_arg(msg_file)
    .. " " .. cmd_quote_arg(resp_file)
    .. " " .. cmd_quote_arg(signal_file)
    .. " " .. cmd_quote_arg(mode)
    .. " " .. cmd_quote_arg(cancel_file)

  local launch_log = io.open(log_file, "w")
  if launch_log then
    launch_log:write("Started worker launcher via hidden ShellExecute\n")
    launch_log:write("request_id=" .. tostring(request_id) .. "\n")
    launch_log:write("python=" .. tostring(python_cmd) .. "\n")
    launch_log:write("launcher=" .. tostring(launcher_path) .. "\n")
    launch_log:write("worker=" .. tostring(worker_path) .. "\n")
    launch_log:close()
  end

  local ok, result = shell_execute_hidden(
    python_cmd,
    args,
    worker_dir,
    (mode == "elevenlabs" or mode == "audio" or mode == "doubao_voices") and "audio_worker" or "llm_worker"
  )
  if not ok then
    pcall(function() os.remove(msg_file) end)
    pcall(function() os.remove(resp_file) end)
    pcall(function() os.remove(signal_file) end)
    pcall(function() os.remove(key_file) end)
    pcall(function() os.remove(pid_file) end)
    pcall(function() os.remove(cancel_file) end)
    return nil, "启动 worker 失败: " .. tostring(result)
  end
  
  -- 记录请求状态（v1.0 支持多个并发请求）
  local req = {
    id = request_id,
    msg_file = msg_file,
    resp_file = resp_file,
    signal_file = signal_file,
    key_file = key_file,  -- 安全：记录密钥文件路径，完成后清理
    pid_file = pid_file,
    cancel_file = cancel_file,
    on_complete = on_complete,
    on_stream = on_stream,
    is_stream = is_stream,
    stream_pos = 0,
    stream_buffer = "",
    stream_text = "",
    stream_final_content = nil,
    stream_error = nil,
    start_time = reaper.time_precise(),
    poll_count = 0,
    max_polls = 6000,  -- 600秒(10分钟) / 0.1秒 = 6000次
    last_check_time = 0,
  }
  table.insert(AsyncPipe.pending_requests, req)
  
  -- 开始轮询（如果还没有在轮询）
  if #AsyncPipe.pending_requests == 1 then
    reaper.defer(function()
      AsyncPipe._poll()
    end)
  end
  
  return request_id
end

function AsyncPipe.fetch_models(models_url, api_key, on_complete)
  return AsyncPipe.send_request(models_url, api_key or "", "", {}, on_complete, "models")
end

function AsyncPipe.fetch_elevenlabs_voices(api_key, on_complete)
  return AsyncPipe.send_request("https://api.elevenlabs.io/v1/voices", api_key or "", "", {}, on_complete, "elevenlabs_voices")
end

function AsyncPipe.fetch_doubao_voices(api_key, on_complete)
  return AsyncPipe.send_request("doubao_voices", api_key or "", "", "{}", on_complete, "doubao_voices")
end

-- ============================================
-- 轮询检查信号文件（v1.0 支持多个并发请求）
-- ============================================
function AsyncPipe._poll()
  if #AsyncPipe.pending_requests == 0 then
    return
  end
  
  local remaining_requests = {}
  
  -- 遍历所有 pending 请求
  for _, req in ipairs(AsyncPipe.pending_requests) do
    req.poll_count = req.poll_count + 1
    process_stream_events(req, false)
    
    -- 检查信号文件是否存在
    if file_exists(req.signal_file) then
      if req.is_stream then
        process_stream_events(req, true)
        
        -- 清理文件（包括密钥文件）
        pcall(function() os.remove(req.msg_file) end)
        pcall(function() os.remove(req.resp_file) end)
        pcall(function() os.remove(req.signal_file) end)
        pcall(function() os.remove(req.key_file) end)
        pcall(function() os.remove(req.pid_file) end)
        pcall(function() os.remove(req.cancel_file) end)
        
        -- 调用回调
        local callback = req.on_complete
        if req.stream_error then
          callback(nil, req.stream_error)
        else
          callback(req.stream_final_content or req.stream_text or "", nil)
        end
        -- 不加入 remaining_requests，表示已完成
      else
        -- 信号文件存在，读取响应
        local resp_f = io.open(req.resp_file, "r")
        if resp_f then
          local content = resp_f:read("*a")
          resp_f:close()

          -- 清理文件（包括密钥文件）
          pcall(function() os.remove(req.msg_file) end)
          pcall(function() os.remove(req.resp_file) end)
          pcall(function() os.remove(req.signal_file) end)
          pcall(function() os.remove(req.key_file) end)
          pcall(function() os.remove(req.pid_file) end)
          pcall(function() os.remove(req.cancel_file) end)

          -- 调用回调
          local callback = req.on_complete
          callback(content, nil)
          -- 不加入 remaining_requests，表示已完成
        else
          -- 信号存在但响应文件读不出，继续等待
          table.insert(remaining_requests, req)
        end
      end
    else
      -- 超时检查（600秒）
      if req.poll_count > req.max_polls then
        terminate_request_worker(req, 0)
        -- 清理（包括密钥文件）
        pcall(function() os.remove(req.msg_file) end)
        pcall(function() os.remove(req.resp_file) end)
        pcall(function() os.remove(req.signal_file) end)
        pcall(function() os.remove(req.key_file) end)
        pcall(function() os.remove(req.pid_file) end)
        pcall(function() os.remove(req.cancel_file) end)

        local callback = req.on_complete
        callback(nil, "请求超时（600秒）")
        -- 不加入 remaining_requests
      else
        -- 继续等待
        table.insert(remaining_requests, req)
      end
    end
  end
  
  -- 更新 pending_requests
  AsyncPipe.pending_requests = remaining_requests
  
  -- 如果还有未完成的请求，继续轮询
  if #remaining_requests > 0 then
    local has_stream = false
    for _, req in ipairs(remaining_requests) do
      if req.is_stream then
        has_stream = true
        break
      end
    end
    if reaper.Sleep and not has_stream then
      reaper.Sleep(100)  -- 100ms
    end
    reaper.defer(function()
      AsyncPipe._poll()
    end)
  end
end

-- ============================================
-- 检查是否有进行中的请求（v1.0 支持多个并发）
-- ============================================
function AsyncPipe.is_busy()
  return #AsyncPipe.pending_requests > 0
end

-- ============================================
-- 获取当前请求状态（v1.0 显示最早请求的进度）
-- ============================================
function AsyncPipe.get_status()
  if #AsyncPipe.pending_requests == 0 then
    return "空闲"
  end
  -- 显示动态"..."效果（循环 0-3 个点）
  local req = AsyncPipe.pending_requests[1]
  local dots = math.floor(req.poll_count / 10) % 4  -- 每 10 次轮询循环一次
  return "请求中" .. string.rep(".", dots) .. string.rep(" ", 3 - dots)
end

-- ============================================
-- 取消所有进行中的请求（v1.0 修复：改为处理 pending_requests 数组）
-- ============================================
function AsyncPipe.cancel()
  if #AsyncPipe.pending_requests == 0 then
    return false
  end
  
  for _, req in ipairs(AsyncPipe.pending_requests) do
    local terminated = terminate_request_worker(req, 600)
    pcall(function() os.remove(req.msg_file) end)
    pcall(function() os.remove(req.resp_file) end)
    pcall(function() os.remove(req.signal_file) end)
    pcall(function() os.remove(req.key_file) end)
    pcall(function() os.remove(req.pid_file) end)
    if terminated then
      pcall(function() os.remove(req.cancel_file) end)
    end
    -- 通知回调：已取消
    if req.on_complete then
      pcall(req.on_complete, nil, "请求已取消")
    end
  end
  
  AsyncPipe.pending_requests = {}
  return true
end

-- 导出模块
return AsyncPipe
