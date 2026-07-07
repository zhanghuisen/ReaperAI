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
function AsyncPipe.send_request(api_url, api_key, model, messages, on_complete, mode)
  -- v1.0+ 新增 mode 参数：
  --   mode 省略或为 "llm": 调用 LLM API (默认)
  --   mode 为 "elevenlabs": 调用 ElevenLabs API 生成音频
  
  mode = mode or "llm"
  
  local request_id = generate_request_id()
  local temp_dir = os.getenv("TEMP") or "C:\\Temp"
  
  local msg_file = temp_dir .. "\\rai_msg_" .. request_id .. ".json"
  local resp_file = temp_dir .. "\\rai_resp_" .. request_id .. ".json"
  local signal_file = temp_dir .. "\\rai_signal_" .. request_id .. ".txt"
  local key_file = temp_dir .. "\\rai_key_" .. request_id .. ".txt"  -- 安全：key不放命令行
  
  -- 保存消息到临时文件
  local f = io.open(msg_file, "w")
  if not f then
    return nil, "无法创建消息文件"
  end
  
  if mode == "elevenlabs" then
    -- v1.0+ ElevenLabs 模式：messages 是字符串（文本内容）
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
    .. " --"
    .. " " .. cmd_quote_arg(request_id)
    .. " " .. cmd_quote_arg(api_url)
    .. " " .. cmd_quote_arg(key_file)
    .. " " .. cmd_quote_arg(model)
    .. " " .. cmd_quote_arg(msg_file)
    .. " " .. cmd_quote_arg(resp_file)
    .. " " .. cmd_quote_arg(signal_file)
    .. " " .. cmd_quote_arg(mode)

  local launch_log = io.open(log_file, "w")
  if launch_log then
    launch_log:write("Started worker launcher via hidden ShellExecute\n")
    launch_log:write("request_id=" .. tostring(request_id) .. "\n")
    launch_log:write("python=" .. tostring(python_cmd) .. "\n")
    launch_log:write("launcher=" .. tostring(launcher_path) .. "\n")
    launch_log:write("worker=" .. tostring(worker_path) .. "\n")
    launch_log:close()
  end

  local ok, result = shell_execute_hidden(python_cmd, args, worker_dir, mode == "elevenlabs" and "elevenlabs_worker" or "llm_worker")
  if not ok then
    pcall(function() os.remove(msg_file) end)
    pcall(function() os.remove(resp_file) end)
    pcall(function() os.remove(signal_file) end)
    pcall(function() os.remove(key_file) end)
    return nil, "启动 worker 失败: " .. tostring(result)
  end
  
  -- 记录请求状态（v1.0 支持多个并发请求）
  local req = {
    id = request_id,
    msg_file = msg_file,
    resp_file = resp_file,
    signal_file = signal_file,
    key_file = key_file,  -- 安全：记录密钥文件路径，完成后清理
    on_complete = on_complete,
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
    
    -- 检查信号文件是否存在
    if file_exists(req.signal_file) then
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
        
        -- 调用回调
        local callback = req.on_complete
        callback(content, nil)
        -- 不加入 remaining_requests，表示已完成
      else
        -- 信号存在但响应文件读不出，继续等待
        table.insert(remaining_requests, req)
      end
    else
      -- 超时检查（600秒）
      if req.poll_count > req.max_polls then
        -- 清理（包括密钥文件）
        pcall(function() os.remove(req.msg_file) end)
        pcall(function() os.remove(req.resp_file) end)
        pcall(function() os.remove(req.signal_file) end)
        pcall(function() os.remove(req.key_file) end)
        
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
    if reaper.Sleep then
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
    pcall(function() os.remove(req.msg_file) end)
    pcall(function() os.remove(req.resp_file) end)
    pcall(function() os.remove(req.signal_file) end)
    pcall(function() os.remove(req.key_file) end)
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
