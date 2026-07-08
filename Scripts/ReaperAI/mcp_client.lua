-- ReaperAI MCP client module
-- Owns MCP HTTP calls, process execution helpers, and MCP server status-file reads.

local McpClient = {}

local function parse_mcp_server_config(content)
  content = tostring(content or "")
  local server_block = content:match('"server"%s*:%s*{(.-)}')
  local scope = server_block or content
  local host = scope:match('"host"%s*:%s*"([^"]+)"') or "127.0.0.1"
  local port = scope:match('"port"%s*:%s*"?([%d]+)"?') or "8765"
  return host, port
end

local function cmd_quote_arg(value)
  value = tostring(value or "")
  return '"' .. value:gsub('"', '""') .. '"'
end

local function vbs_quote(value)
  return '"' .. tostring(value or ""):gsub('"', '""') .. '"'
end

local function dirname(path)
  return tostring(path or ""):match("^(.*)[\\/][^\\/]+$") or ""
end

local function launch_path_exists(path)
  local f = io.open(path, "r")
  if f then
    f:close()
    return true
  end
  return false
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
    if launch_path_exists(candidate) then return candidate end
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

local function path_exists(path)
  local f = io.open(path, "r")
  if f then
    f:close()
    return true
  end
  return false
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a") or ""
  f:close()
  return content
end

local function write_file(path, content)
  local f = io.open(path, "w")
  if not f then return false end
  f:write(content or "")
  f:close()
  return true
end

local function find_pythonw(server_dir)
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

  if server_dir and server_dir ~= "" then
    add(server_dir .. "\\.venv\\Scripts\\pythonw.exe")
    add(server_dir .. "\\.venv\\Scripts\\python.exe")
    add(server_dir .. "\\python_runtime\\pythonw.exe")
    add(server_dir .. "\\python_runtime\\python.exe")
    add(server_dir .. "\\.python\\pythonw.exe")
    add(server_dir .. "\\.python\\python.exe")
    add_path_file(server_dir .. "\\pythonw_path.txt")
    add_path_file(server_dir .. "\\python_path.txt")
  end
  add_python_roots(os.getenv("LOCALAPPDATA") or "")
  add_python_roots((os.getenv("USERPROFILE") or "") .. "\\AppData\\Local")
  add_program_files(os.getenv("ProgramFiles") or "")
  add_program_files(os.getenv("ProgramFiles(x86)") or "")

  for _, candidate in ipairs(candidates) do
    if candidate and candidate ~= "" and path_exists(candidate) then
      return candidate
    end
  end
  return nil
end

local function exec_process_capture(cmd, timeout_ms)
  return nil, "ExecProcess 已禁用，避免 Windows Terminal 弹窗"
end

local function exec_process_ok(cmd, timeout_ms)
  local output, err = exec_process_capture(cmd, timeout_ms or 5000)
  if output then
    return true, output
  end
  return false, err
end

local function json_encode_string(s)
  if not s then return '""' end
  s = tostring(s)
  s = s:gsub('\\', '\\\\')
  s = s:gsub('"', '\\"')
  s = s:gsub('\n', '\\n')
  s = s:gsub('\r', '')
  return '"' .. s .. '"'
end

local function read_text_file(path, max_chars)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a") or ""
  f:close()
  if max_chars and #content > max_chars then
    content = content:sub(#content - max_chars + 1)
  end
  return content
end

local function json_extract_bool(text, key)
  local value = tostring(text or ""):match('"' .. key .. '"%s*:%s*(true)')
    or tostring(text or ""):match('"' .. key .. '"%s*:%s*(false)')
  if value == "true" then return true end
  if value == "false" then return false end
  return nil
end

local function json_extract_number(text, key)
  local value = tostring(text or ""):match('"' .. key .. '"%s*:%s*(-?%d+%.?%d*)')
  return tonumber(value or "")
end

local function json_unescape(value)
  value = tostring(value or "")
  local out = {}
  local i = 1
  while i <= #value do
    local ch = value:sub(i, i)
    if ch == "\\" and i < #value then
      local next_ch = value:sub(i + 1, i + 1)
      if next_ch == "n" then
        table.insert(out, "\n")
        i = i + 2
      elseif next_ch == "r" then
        table.insert(out, "\r")
        i = i + 2
      elseif next_ch == "t" then
        table.insert(out, "\t")
        i = i + 2
      elseif next_ch == '"' then
        table.insert(out, '"')
        i = i + 2
      elseif next_ch == "\\" then
        table.insert(out, "\\")
        i = i + 2
      elseif next_ch == "u" and i + 5 <= #value then
        table.insert(out, "\\u" .. value:sub(i + 2, i + 5))
        i = i + 6
      else
        table.insert(out, next_ch)
        i = i + 2
      end
    else
      table.insert(out, ch)
      i = i + 1
    end
  end
  return table.concat(out)
end

local function json_extract_string(text, key)
  text = tostring(text or "")
  local key_pos = text:find('"' .. key .. '"', 1, true)
  if not key_pos then return nil end
  local colon_pos = text:find(":", key_pos, true)
  if not colon_pos then return nil end
  local quote_pos = text:find('"', colon_pos + 1, true)
  if not quote_pos then return nil end
  local out = {}
  local i = quote_pos + 1
  local escaped = false
  while i <= #text do
    local ch = text:sub(i, i)
    if escaped then
      table.insert(out, "\\" .. ch)
      escaped = false
    elseif ch == "\\" then
      escaped = true
    elseif ch == '"' then
      return json_unescape(table.concat(out))
    else
      table.insert(out, ch)
    end
    i = i + 1
  end
  return nil
end

function McpClient.create(options)
  options = options or {}
  local prompt = options.prompt or {}
  local script_dir = tostring(options.script_dir or "")

  local MCP = {
    enabled = true,
    timeout = 30,  -- 循环分析可能需要较长时间，增加到30秒
  }

  function MCP.load_config()
    local config_path = reaper.GetResourcePath() .. "/Scripts/ReaperAI_mcp_config.json"
    local f = io.open(config_path, "r")
    if f then
      local content = f:read("*a")
      f:close()
      local ok, config = false, nil
      if type(json) == "table" and type(json.decode) == "function" then
        ok, config = pcall(function() return json.decode(content) end)
      end
      if ok and config and config.server then
        local host = config.server.host or "127.0.0.1"
        local port = config.server.port or 8765
        return "http://" .. host .. ":" .. port
      end
      local host, port = parse_mcp_server_config(content)
      return "http://" .. host .. ":" .. port
    end
    -- 默认回退
    return "http://127.0.0.1:8765"
  end

  MCP.base_url = MCP.load_config()

  function MCP.find_bridge_script()
    for _, path in ipairs(MCP.server_file_candidates("mcp_http_bridge.py")) do
      if path_exists(path) then
        return path
      end
    end
    return nil
  end

  function MCP.http_bridge(method, endpoint, payload, timeout_sec)
    local bridge = MCP.find_bridge_script()
    local pythonw = find_pythonw(bridge and dirname(bridge))
    if not bridge or not pythonw then
      return nil, "缺少 mcp_http_bridge.py 或 Python/pythonw"
    end

    local tmp_dir = os.getenv("TEMP") or "C:\\Temp"
    local stamp = tostring(math.floor((reaper.time_precise() or os.clock()) * 1000000))
    local out_file = tmp_dir .. "\\reaai_mcp_http_" .. stamp .. ".json"
    local payload_file = tmp_dir .. "\\reaai_mcp_payload_" .. stamp .. ".json"
    local timeout = tonumber(timeout_sec or MCP.timeout) or MCP.timeout
    local args = cmd_quote_arg(bridge)
      .. " --method " .. cmd_quote_arg(method)
      .. " --url " .. cmd_quote_arg(MCP.base_url .. endpoint)
      .. " --timeout " .. cmd_quote_arg(tostring(timeout))
      .. " --out " .. cmd_quote_arg(out_file)

    if payload ~= nil then
      if not write_file(payload_file, payload) then
        return nil, "无法写入 MCP POST 临时文件"
      end
      args = args .. " --payload-file " .. cmd_quote_arg(payload_file)
    end

    local ok, launch_msg = shell_execute_hidden(pythonw, args, dirname(bridge), "mcp_http_bridge")
    if not ok then
      if payload ~= nil then os.remove(payload_file) end
      os.remove(out_file)
      return nil, launch_msg or "MCP bridge 启动失败"
    end

    local deadline = ((reaper.time_precise and reaper.time_precise()) or os.clock()) + math.max(1, timeout) + 0.5
    while not path_exists(out_file) and (((reaper.time_precise and reaper.time_precise()) or os.clock()) < deadline) do
      if reaper.Sleep then reaper.Sleep(30) end
    end

    if payload ~= nil then os.remove(payload_file) end
    local result_text = read_file(out_file)
    os.remove(out_file)
    if not result_text or result_text == "" then
      return nil, "MCP bridge 无输出"
    end
    local body = json_extract_string(result_text, "body")
    if body then
      return body, nil
    end
    local err = json_extract_string(result_text, "error")
    return nil, err or "MCP bridge 响应解析失败"
  end

  function MCP.exec_process_capture(cmd, timeout_ms)
    return exec_process_capture(cmd, timeout_ms)
  end

  function MCP.exec_process_ok(cmd, timeout_ms)
    return exec_process_ok(cmd, timeout_ms)
  end

  function MCP.http_get(endpoint, timeout_sec)
    local timeout = tonumber(timeout_sec or MCP.timeout) or MCP.timeout
    local bridge_body, bridge_err = MCP.http_bridge("GET", endpoint, nil, timeout)
    if bridge_body then
      return bridge_body, nil
    end
    return nil, bridge_err or "MCP bridge GET 失败"
  end

  function MCP.http_post(endpoint, payload, timeout_sec)
    local timeout = tonumber(timeout_sec or MCP.timeout) or MCP.timeout
    local bridge_body, bridge_err = MCP.http_bridge("POST", endpoint, payload, timeout)
    if bridge_body then
      return bridge_body, nil
    end
    return nil, bridge_err or "MCP bridge POST 失败"
  end

  function MCP.ping()
    local data, err = MCP.http_get("/ping", 1)
    if data then
      return data:find('"ok"%s*:%s*true') ~= nil
    end
    return false, err
  end

  function MCP.get_commands()
    return MCP.http_get("/command_queue")
  end

  function MCP.submit_result(cmd_id, result, error_msg)
    local payload = '{"id":"' .. cmd_id .. '"'
    if result then
      payload = payload .. ',"result":' .. json_encode_string(result)
    end
    if error_msg then
      payload = payload .. ',"error":' .. json_encode_string(error_msg)
    end
    payload = payload .. '}'

    return MCP.http_post("/submit_result", payload)
  end

  function MCP.execute_command(call_str)
    if not MCP.ping() then
      return nil, "MCP 服务器离线"
    end

    local payload = '{"calls":[' .. json_encode_string(call_str) .. ']}'
    local resp, err = MCP.http_post("/mcp/parse", payload)

    if not resp then
      return nil, "MCP 请求失败: " .. tostring(err)
    end

    -- 解析 results 数组中的第一个结果的 cmd_id
    -- 格式: {"success": true, "results": [{"cmd_id": "...", ...}], "queued": 1}
    local results_start = resp:find('"results"')
    if results_start then
      local cmd_id = resp:match('"cmd_id"%s*:%s*"([^"]+)"', results_start)
      if cmd_id then
        return "命令已提交到 MCP 服务器", nil
      end
    end

    -- 检查是否有错误
    local error_msg = json_extract_string(resp, "error") or resp:match('"error"%s*:%s*"([^"]+)"')
    if error_msg then
      return nil, "MCP 错误: " .. error_msg
    end

    -- 未知响应格式
    return nil, "无法解析 MCP 响应: " .. resp:sub(1, 100)
  end

  function MCP.get_endpoints()
    local resp, err = MCP.http_get("/list_endpoints", 3)
    if not resp then
      return nil, "获取端点列表失败: " .. tostring(err)
    end

    return resp, nil
  end

  function MCP.build_capabilities_text(json_resp)
    if prompt and type(prompt.build_capabilities_text) == "function" then
      return prompt.build_capabilities_text(json_resp)
    end
    return nil, 0
  end

  function MCP.server_file_candidates(filename)
    local userprofile = os.getenv("USERPROFILE") or ""
    local candidates = {
      script_dir .. "..\\..\\MCP_Server\\" .. filename,
      script_dir .. "..\\MCP_Server\\" .. filename,
      reaper.GetResourcePath() .. "\\MCP_Server\\" .. filename,
      reaper.GetResourcePath() .. "\\Scripts\\MCP_Server\\" .. filename,
      userprofile .. "\\Documents\\REAPER\\MCP_Server\\" .. filename,
    }

    local result, seen = {}, {}
    for _, path in ipairs(candidates) do
      if path and path ~= "" and not seen[path] then
        seen[path] = true
        table.insert(result, path)
      end
    end
    return result
  end

  function MCP.read_server_file(filename, max_chars)
    for _, path in ipairs(MCP.server_file_candidates(filename)) do
      local content = read_text_file(path, max_chars)
      if content and content ~= "" then
        return content, path
      end
    end
    return nil, nil
  end

  function MCP.read_last_server_log_line(filename)
    local content = MCP.read_server_file(filename, 1000)
    if not content then return "未找到日志" end

    local last_line = nil
    for line in content:gmatch("[^\r\n]+") do
      last_line = line
    end
    return last_line or "日志为空"
  end

  function MCP.read_status_snapshot()
    local content, path = MCP.read_server_file("mcp_server_status.json", 4000)
    if not content then return nil end

    local pid = json_extract_string(content, "pid")
    if not pid then
      local pid_num = json_extract_number(content, "pid")
      if pid_num then pid = tostring(math.floor(pid_num)) end
    end

    return {
      path = path,
      ok = json_extract_bool(content, "ok") == true,
      ping_ok = json_extract_bool(content, "ping_ok") == true,
      port_open = json_extract_bool(content, "port_open") == true,
      pid = pid,
      endpoint_count = json_extract_number(content, "endpoint_count") or 0,
      state = json_extract_string(content, "state") or "unknown",
      detail = json_extract_string(content, "detail") or "",
      checked_at = json_extract_number(content, "checked_at") or json_extract_number(content, "requested_at"),
    }
  end

  function MCP.read_launch_log()
    return MCP.read_last_server_log_line("mcp_server_launch.log")
  end

  function MCP.read_shutdown_log()
    return MCP.read_server_file("mcp_server_shutdown.log", 1000)
  end

  return MCP
end

return McpClient
