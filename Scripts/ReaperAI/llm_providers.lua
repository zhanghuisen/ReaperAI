local LlmProviders = {}

local PROVIDERS = {
  {
    id = "openai",
    label = "OpenAI",
    api_base = "https://api.openai.com/v1",
    base_url = "https://api.openai.com/v1/chat/completions",
    api_style = "openai_chat_completions",
    supports_models = true,
    default_model = "gpt-5.5",
    source = "OpenAI models docs, checked 2026-07-07",
    models = {
      { id = "gpt-5.5", label = "GPT-5.5", group = "Recommended", tags = { "flagship", "latest" }, recommended = true, source = "OpenAI models docs, checked 2026-07-07" },
      { id = "gpt-5.4", label = "GPT-5.4", group = "GPT-5", tags = { "strong" }, source = "OpenAI models docs, checked 2026-07-07" },
      { id = "gpt-5.4-mini", label = "GPT-5.4 mini", group = "Recommended", tags = { "fast", "cost-effective" }, recommended = true, source = "OpenAI models docs, checked 2026-07-07" },
      { id = "gpt-5.4-nano", label = "GPT-5.4 nano", group = "GPT-5", tags = { "low-latency" }, source = "OpenAI models docs, checked 2026-07-07" },
      { id = "gpt-4o-mini", label = "GPT-4o mini", group = "Legacy compatible", tags = { "stable", "fast" } },
      { id = "gpt-4o", label = "GPT-4o", group = "Legacy compatible", tags = { "stable" } },
    },
  },
  {
    id = "deepseek",
    label = "DeepSeek",
    api_base = "https://api.deepseek.com/v1",
    base_url = "https://api.deepseek.com/v1/chat/completions",
    api_style = "openai_chat_completions",
    supports_models = true,
    default_model = "deepseek-v4-pro",
    source = "DeepSeek pricing/docs, checked 2026-07-07",
    models = {
      { id = "deepseek-v4-pro", label = "DeepSeek V4 Pro", group = "Recommended", tags = { "latest", "chat" }, recommended = true, source = "DeepSeek docs, checked 2026-07-07" },
      { id = "deepseek-v4-flash", label = "DeepSeek V4 Flash", group = "Recommended", tags = { "latest", "fast" }, recommended = true, source = "DeepSeek docs, checked 2026-07-07" },
      { id = "deepseek-chat", label = "DeepSeek Chat", group = "Recommended", tags = { "stable", "legacy", "deprecated-2026-07-24" }, recommended = true, source = "DeepSeek docs, checked 2026-07-07" },
      { id = "deepseek-reasoner", label = "DeepSeek Reasoner", group = "Deprecated aliases", tags = { "reasoning", "deprecated-2026-07-24" }, source = "DeepSeek docs, checked 2026-07-07" },
    },
  },
  {
    id = "moonshot",
    label = "Moonshot / Kimi",
    api_base = "https://api.moonshot.cn/v1",
    base_url = "https://api.moonshot.cn/v1/chat/completions",
    api_style = "openai_chat_completions",
    supports_models = true,
    default_model = "kimi-k2.6",
    source = "Moonshot Kimi API docs, checked 2026-07-07",
    models = {
      { id = "kimi-k2.6", label = "Kimi K2.6", group = "Recommended", tags = { "latest", "chat" }, recommended = true, source = "Moonshot docs, checked 2026-07-07" },
      { id = "kimi-k2.7-code", label = "Kimi K2.7 Code", group = "Code", tags = { "code" }, source = "Moonshot docs, checked 2026-07-07" },
      { id = "kimi-k2.7-code-highspeed", label = "Kimi K2.7 Code Highspeed", group = "Code", tags = { "code", "fast" }, source = "Moonshot docs, checked 2026-07-07" },
      { id = "kimi-k2.5", label = "Kimi K2.5", group = "Kimi K2", tags = { "chat" }, source = "Moonshot docs, checked 2026-07-07" },
      { id = "moonshot-v1-128k", label = "Moonshot v1 128k", group = "Long context", tags = { "128k" }, source = "Moonshot docs, checked 2026-07-07" },
      { id = "moonshot-v1-32k", label = "Moonshot v1 32k", group = "Long context", tags = { "32k" }, source = "Moonshot docs, checked 2026-07-07" },
      { id = "moonshot-v1-8k", label = "Moonshot v1 8k", group = "Long context", tags = { "8k" }, source = "Moonshot docs, checked 2026-07-07" },
    },
  },
  {
    id = "qwen",
    label = "Qwen / DashScope",
    api_base = "https://dashscope.aliyuncs.com/compatible-mode/v1",
    base_url = "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
    api_style = "openai_chat_completions",
    supports_models = false,
    default_model = "qwen3.7-plus",
    source = "Alibaba Cloud Model Studio docs, checked 2026-07-07",
    models = {
      { id = "qwen3.7-plus", label = "Qwen 3.7 Plus", group = "Recommended", tags = { "latest", "chat" }, recommended = true, source = "DashScope docs, checked 2026-07-07" },
      { id = "qwen3.7-max", label = "Qwen 3.7 Max", group = "Recommended", tags = { "latest", "strong" }, recommended = true, source = "DashScope docs, checked 2026-07-07" },
      { id = "qwen3.7-plus-2026-05-26", label = "Qwen 3.7 Plus 2026-05-26", group = "Pinned versions", tags = { "pinned" }, source = "DashScope docs, checked 2026-07-07" },
      { id = "qwen3.7-max-2026-05-20", label = "Qwen 3.7 Max 2026-05-20", group = "Pinned versions", tags = { "pinned" }, source = "DashScope docs, checked 2026-07-07" },
      { id = "qwen3.6-flash", label = "Qwen 3.6 Flash", group = "Recommended", tags = { "fast" }, recommended = true, source = "DashScope docs, checked 2026-07-07" },
      { id = "qwen3.6-plus", label = "Qwen 3.6 Plus", group = "Qwen 3.6", tags = { "chat" }, source = "DashScope docs, checked 2026-07-07" },
      { id = "qwen-plus", label = "Qwen Plus", group = "Legacy compatible", tags = { "stable" } },
      { id = "qwen-max", label = "Qwen Max", group = "Legacy compatible", tags = { "stable" } },
      { id = "qwen-flash", label = "Qwen Flash", group = "Legacy compatible", tags = { "fast" } },
    },
  },
  {
    id = "openrouter",
    label = "OpenRouter",
    api_base = "https://openrouter.ai/api/v1",
    base_url = "https://openrouter.ai/api/v1/chat/completions",
    api_style = "openai_chat_completions",
    supports_models = true,
    default_model = "openai/gpt-5.5",
    source = "OpenRouter models API, checked 2026-07-07",
    models = {
      { id = "openai/gpt-5.5", label = "OpenAI GPT-5.5", group = "Recommended", tags = { "latest", "flagship" }, recommended = true, source = "OpenRouter models API, checked 2026-07-07" },
      { id = "openai/gpt-5.5-pro", label = "OpenAI GPT-5.5 Pro", group = "OpenAI", tags = { "strong" }, source = "OpenRouter models API, checked 2026-07-07" },
      { id = "openai/gpt-5.4-mini", label = "OpenAI GPT-5.4 Mini", group = "OpenAI", tags = { "fast" }, source = "OpenRouter models API, checked 2026-07-07" },
      { id = "deepseek/deepseek-v4-pro", label = "DeepSeek V4 Pro", group = "Recommended", tags = { "latest", "chat" }, recommended = true, source = "OpenRouter models API, checked 2026-07-07" },
      { id = "deepseek/deepseek-v4-flash", label = "DeepSeek V4 Flash", group = "Recommended", tags = { "fast" }, recommended = true, source = "OpenRouter models API, checked 2026-07-07" },
      { id = "moonshotai/kimi-k2.6", label = "Kimi K2.6", group = "Moonshot", tags = { "chat" }, source = "OpenRouter models API, checked 2026-07-07" },
      { id = "moonshotai/kimi-k2.7-code", label = "Kimi K2.7 Code", group = "Moonshot", tags = { "code" }, source = "OpenRouter models API, checked 2026-07-07" },
      { id = "qwen/qwen3.7-plus", label = "Qwen3.7 Plus", group = "Qwen", tags = { "chat" }, source = "OpenRouter models API, checked 2026-07-07" },
      { id = "qwen/qwen3.7-max", label = "Qwen3.7 Max", group = "Qwen", tags = { "strong" }, source = "OpenRouter models API, checked 2026-07-07" },
    },
  },
  {
    id = "siliconflow",
    label = "SiliconFlow",
    api_base = "https://api.siliconflow.cn/v1",
    base_url = "https://api.siliconflow.cn/v1/chat/completions",
    api_style = "openai_chat_completions",
    supports_models = true,
    default_model = "deepseek-ai/DeepSeek-V3.2",
    source = "SiliconFlow API docs, checked 2026-07-07",
    models = {
      { id = "deepseek-ai/DeepSeek-V3.2", label = "DeepSeek V3.2", group = "Recommended", tags = { "chat" }, recommended = true, source = "SiliconFlow docs, checked 2026-07-07" },
      { id = "deepseek-ai/DeepSeek-V3.1-Terminus", label = "DeepSeek V3.1 Terminus", group = "DeepSeek", tags = { "chat" }, source = "SiliconFlow docs, checked 2026-07-07" },
      { id = "Pro/deepseek-ai/DeepSeek-V3.2", label = "Pro DeepSeek V3.2", group = "Pro", tags = { "chat" }, source = "SiliconFlow docs, checked 2026-07-07" },
      { id = "Qwen/Qwen3.5-397B-A17B", label = "Qwen3.5 397B A17B", group = "Qwen", tags = { "chat" }, source = "SiliconFlow docs, checked 2026-07-07" },
      { id = "Qwen/Qwen3.5-122B-A10B", label = "Qwen3.5 122B A10B", group = "Qwen", tags = { "chat" }, source = "SiliconFlow docs, checked 2026-07-07" },
      { id = "zai-org/GLM-4.6", label = "GLM 4.6", group = "GLM", tags = { "chat" }, source = "SiliconFlow docs, checked 2026-07-07" },
      { id = "Pro/zai-org/GLM-5", label = "Pro GLM 5", group = "Pro", tags = { "chat" }, source = "SiliconFlow docs, checked 2026-07-07" },
    },
  },
  {
    id = "minimax",
    label = "MiniMax",
    api_base = "https://api.minimaxi.com/v1",
    base_url = "https://api.minimaxi.com/v1/chat/completions",
    api_style = "openai_chat_completions",
    supports_models = false,
    default_model = "MiniMax-M3",
    source = "MiniMax OpenAI SDK docs, checked 2026-07-07",
    models = {
      { id = "MiniMax-M3", label = "MiniMax M3", group = "Recommended", tags = { "latest" }, recommended = true, source = "MiniMax docs, checked 2026-07-07" },
      { id = "MiniMax-M2.7", label = "MiniMax M2.7", group = "MiniMax M2", tags = { "chat" }, source = "MiniMax docs, checked 2026-07-07" },
      { id = "MiniMax-M2.5", label = "MiniMax M2.5", group = "MiniMax M2", tags = { "chat" }, source = "MiniMax docs, checked 2026-07-07" },
      { id = "MiniMax-M2.1", label = "MiniMax M2.1", group = "MiniMax M2", tags = { "chat" }, source = "MiniMax docs, checked 2026-07-07" },
      { id = "MiniMax-M1", label = "MiniMax M1", group = "Legacy compatible", tags = { "chat" }, source = "MiniMax docs, checked 2026-07-07" },
    },
  },
  {
    id = "custom",
    label = "Custom OpenAI-Compatible",
    api_base = "",
    base_url = "",
    api_style = "openai_chat_completions",
    supports_models = true,
    default_model = "",
    models = {},
  },
}

local PROVIDER_ORDER = {
  "openai",
  "deepseek",
  "moonshot",
  "minimax",
  "qwen",
  "siliconflow",
  "openrouter",
  "custom",
}

local function lower(value)
  return tostring(value or ""):lower()
end

local function copy_model(model, provider)
  local item = {}
  for k, v in pairs(model or {}) do item[k] = v end
  item.provider_id = provider and provider.id or item.provider_id
  item.provider_label = provider and provider.label or item.provider_label
  if item.supported == nil then
    item.supported = provider and provider.api_style == "openai_chat_completions"
  end
  return item
end

local function provider_by_id_raw(id)
  id = tostring(id or "")
  for _, provider in ipairs(PROVIDERS) do
    if provider.id == id then return provider end
  end
  return nil
end

local function trim_trailing_slashes(value)
  value = tostring(value or "")
  return (value:gsub("/+$", ""))
end

function LlmProviders.providers()
  local ordered = {}
  for _, id in ipairs(PROVIDER_ORDER) do
    local provider = provider_by_id_raw(id)
    if provider then table.insert(ordered, provider) end
  end
  return ordered
end

function LlmProviders.provider_by_id(id)
  return provider_by_id_raw(id) or provider_by_id_raw("custom") or PROVIDERS[#PROVIDERS]
end

function LlmProviders.api_base_from_url(url)
  local base = trim_trailing_slashes(url)
  base = base:gsub("/chat/completions$", "")
  base = base:gsub("/models$", "")
  return trim_trailing_slashes(base)
end

function LlmProviders.chat_url_from_base(base_url)
  local base = LlmProviders.api_base_from_url(base_url)
  if base == "" then return "" end
  if base:match("/chat/completions$") then return base end
  return base .. "/chat/completions"
end

function LlmProviders.provider_api_base(provider)
  if not provider then return "" end
  if provider.api_base and provider.api_base ~= "" then return trim_trailing_slashes(provider.api_base) end
  return LlmProviders.api_base_from_url(provider.base_url)
end

function LlmProviders.provider_chat_url(provider)
  if not provider then return "" end
  if provider.base_url and provider.base_url ~= "" then return provider.base_url end
  return LlmProviders.chat_url_from_base(provider.api_base)
end

function LlmProviders.models_url_from_base(base_url)
  local base = LlmProviders.api_base_from_url(base_url)
  if base == "" then return "" end
  return base .. "/models"
end

function LlmProviders.models_for_provider(provider_id, include_unsupported)
  local provider = LlmProviders.provider_by_id(provider_id)
  local models = {}
  for _, model in ipairs((provider and provider.models) or {}) do
    if include_unsupported or model.supported ~= false then
      table.insert(models, copy_model(model, provider))
    end
  end
  return models
end

function LlmProviders.all_models(include_unsupported)
  local models = {}
  for _, provider in ipairs(PROVIDERS) do
    for _, model in ipairs(provider.models or {}) do
      if include_unsupported or model.supported ~= false then
        table.insert(models, copy_model(model, provider))
      end
    end
  end
  return models
end

function LlmProviders.find_model(model_id)
  model_id = tostring(model_id or "")
  if model_id == "" then return nil end
  for _, provider in ipairs(PROVIDERS) do
    for _, model in ipairs(provider.models or {}) do
      if model.id == model_id then return copy_model(model, provider), provider end
    end
  end
  return nil
end

function LlmProviders.detect_provider(api_url, model_id)
  local url = lower(api_url)
  if url:find("deepseek", 1, true) then return LlmProviders.provider_by_id("deepseek") end
  if url:find("moonshot", 1, true) or url:find("kimi", 1, true) then return LlmProviders.provider_by_id("moonshot") end
  if url:find("dashscope", 1, true) or url:find("aliyun", 1, true) then return LlmProviders.provider_by_id("qwen") end
  if url:find("openrouter", 1, true) then return LlmProviders.provider_by_id("openrouter") end
  if url:find("siliconflow", 1, true) then return LlmProviders.provider_by_id("siliconflow") end
  if url:find("minimax", 1, true) then return LlmProviders.provider_by_id("minimax") end
  if url:find("openai", 1, true) then return LlmProviders.provider_by_id("openai") end
  local _, provider = LlmProviders.find_model(model_id)
  return provider or LlmProviders.provider_by_id("custom")
end

function LlmProviders.model_matches_filter(model, filter)
  filter = lower(filter):gsub("^%s+", ""):gsub("%s+$", "")
  if filter == "" then return true end
  local parts = { model.id, model.label, model.group, model.provider_label, table.concat(model.tags or {}, " ") }
  local haystack = lower(table.concat(parts, " "))
  return haystack:find(filter, 1, true) ~= nil
end

function LlmProviders.tags_text(model)
  local tags = model and model.tags or nil
  if not tags or #tags == 0 then return "" end
  return table.concat(tags, " / ")
end

return LlmProviders
