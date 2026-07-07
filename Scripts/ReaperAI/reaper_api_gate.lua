-- Compatibility shim. New code should load reaper_capabilities.lua instead.

local ReaperApiGate = {}

function ReaperApiGate.create(options)
  local sep = package and package.config and package.config:sub(1, 1) or "/"
  if sep == "" then sep = "/" end
  local module_dir = options and options.module_dir
  if not module_dir or module_dir == "" then
    local info = debug and debug.getinfo and debug.getinfo(1, "S") or nil
    local source = info and tostring(info.source or ""):gsub("^@", "") or ""
    module_dir = source:match("^(.*[\\/])") or ""
  end
  local path = tostring(module_dir or "") .. "reaper_capabilities.lua"
  local ok, mod = pcall(dofile, path)
  if not ok or not mod then
    error("ReaperAI capability module load failed: " .. path .. "\n" .. tostring(mod), 0)
  end
  return mod.create(options)
end

return ReaperApiGate
