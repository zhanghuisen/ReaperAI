# ReaperAI v1.0.5

ReaperAI 是一个运行在 REAPER 里的 AI 助手。它可以把自然语言指令转换成可确认、可执行的 REAPER 操作，帮助音效师、音乐制作人和游戏音频设计师更快地完成轨道整理、素材处理、Region/Marker 管理、批量操作和音频生成相关工作。

你可以像这样描述需求：

- 创建 10 条脚步声轨道，并按材质命名
- 把选中的素材全部加 80ms 淡入淡出
- 删除第 5 到第 10 个 Region
- 把所有 Region 按 SFX_001 的格式重命名
- 播放工程，或者停止播放
- 生成一段机械门打开的音效并导入工程

ReaperAI 会先生成操作计划，你确认后再执行。默认不会直接改动工程。

## v1.0.5 更新重点

- 接入火山引擎/豆包语音：生成音频页支持服务商下拉选择，ElevenLabs 与火山引擎配置收进独立配置面板，界面不再把所有 API 项堆在设置页。
- 重做豆包语音合成 UI：保留单人语音合成模式，支持按账号检测可用音色，并根据音色能力控制语言、口音、语速、音调、音量等参数，避免把不支持的选项误发给接口。
- 优化音频生成输入框：描述/文本输入改为可换行的大输入区，并跟随 ReaperAI 脚本窗口尺寸变化，长文本不再被右侧裁掉。
- 改进 AI 取消逻辑：取消按钮现在会写入取消标记、记录并终止对应 worker 进程，流式请求和后续写回也会检查取消状态，减少“UI 停了但后台还在跑”的情况。
- 引入通用选择器与工程快照 v2：统一捕获轨道、素材、Marker、Region、时间选区、光标位置、选中包络等上下文；“选中的/当前/时间选区内/除了选中的”这类范围请求走 scope/exclude 解析，不再给单个 Region 删除功能打补丁。
- 新增对象独立改色能力：`region/set_color` 只修改 Region，`item/set_color` 只修改 MediaItem，和既有 `track/set_color` 分离，颜色统一使用 REAPER 自定义颜色启用位，避免脚本显示成功但颜色没变。
- 清理生成音频长期维护点：取消快捷输入生成音频，降低多服务商并存后的快捷词维护成本。

## 功能特性

- 自然语言控制 REAPER：用中文或英文描述操作，不需要记 Action ID 或 ReaScript API。
- 执行前确认：AI 会生成操作卡片，用户确认后才执行。
- MCP 增强执行：连接本地 MCP 服务后，可使用更稳定的结构化能力端点。
- MCP 离线兜底：MCP 启动失败时仍可进入执行模式，常见操作会使用本地 Lua/SCRIPT 方式执行。
- 本机能力检测：检测当前 REAPER 环境里的 API、Action ID 和扩展能力。
- LLM 供应商配置：支持多家 OpenAI-Compatible API，并可刷新模型列表。
- ElevenLabs 集成：可选的语音和音效生成能力。
- 风险提示：批量修改、文件写入、删除等操作会被标记为更高风险。
- 本地运行：主要逻辑在本机 REAPER、Lua 和本地 Python 环境中运行。

## 支持的 LLM 供应商

设置页中可以选择：

- OpenAI
- DeepSeek
- Moonshot / Kimi
- MiniMax
- Qwen / DashScope
- SiliconFlow
- OpenRouter
- 自定义 OpenAI-Compatible

选择供应商后，ReaperAI 会自动填入推荐 Base URL、默认模型和推荐模型列表。模型名称变化较快，所以设置页也提供“刷新模型列表”，能请求供应商的 `/models` 接口时会拉取真实可用模型；不可用时会使用本地内置模型注册表。

## 运行要求

- Windows 10 / Windows 11
- REAPER 7.x
- 一个可用的 LLM API Key
- 网络可访问你选择的 LLM 服务

不要求用户提前安装 Python。项目自带安装脚本会优先准备 ReaperAI 私有 Python 环境，并使用随包 wheels 离线安装核心依赖。

## 项目结构

```text
ReaperV1.0/
├── MCP_Server/                 本地 MCP 服务、LLM Worker、安装脚本
├── Scripts/
│   ├── ReaperAI.lua            REAPER 入口脚本
│   ├── rai_async_pipe.lua      异步请求管道
│   └── ReaperAI/               ReaperAI 核心模块
├── UserPlugins/                ReaImGui、js_ReaScriptAPI、ReaPack、SWS 等扩展
├── README.md
├── LICENSE
└── 安装说明.txt
```

## 安装

1. 下载本项目。
2. 将 `MCP_Server`、`Scripts`、`UserPlugins` 三个文件夹复制到你的 REAPER 根目录，例如 `X:\REAPER`。
3. 进入 `MCP_Server` 文件夹，双击运行 `【第一步】安装依赖.bat`。
4. 继续双击运行 `【第二步】配置向导.bat`，按提示完成配置。
5. 打开 REAPER，按 `?` 打开 Action List。
6. 点击 `Load`，选择 `X:\REAPER\Scripts\ReaperAI.lua`。
7. 运行 `ReaperAI.lua`。

如果你的 REAPER 不在 `X:\REAPER`，请按自己的实际路径选择脚本。

## 首次配置

打开 ReaperAI 后，进入“设置”页签：

1. 在“LLM 配置”里选择 Provider。
2. 填入对应供应商的 API Key。
3. 选择或输入 Model Name。
4. 点击“测试连接”确认 API 可用。
5. 点击“刷新模型列表”更新可选模型。
6. 在“本机能力检测”区域点击“检测”。
7. 保存配置。

完成后即可回到“对话”页签使用。

## 使用方式

### 咨询模式

默认情况下，ReaperAI 只回答问题，不会执行任何 REAPER 操作。适合询问：

- 这个操作应该怎么做？
- 某个 REAPER 功能在哪里？
- 某个混音或音效设计思路是否合理？

### 执行模式

点击“执行模式”后，ReaperAI 会进入可执行状态。此时你发送自然语言指令，AI 会生成操作计划，等待你确认。

执行模式不再强依赖 MCP：

- MCP 成功启动：使用 MCP 增强能力。
- MCP 启动失败或超时：保留本地执行模式，常见操作使用 Lua/SCRIPT 兜底。
- 只有点击“退出执行”才会离开执行模式。

### 生成音频

如果配置了 ElevenLabs API Key，可以使用“生成音频”页签生成语音或音效，并导入 REAPER 工程。

ElevenLabs 是可选功能；不配置也不影响核心对话和 REAPER 操作。

## 常见可执行操作

ReaperAI 当前适合处理这些任务：

- 播放、停止等传输控制
- 创建、删除、重命名轨道
- 设置轨道音量、声像、静音、独奏
- 添加、删除 Marker
- 添加、删除、批量重命名 Region
- 处理选中素材的淡入淡出
- 批量整理素材或轨道
- 读取工程上下文并生成操作建议
- 通过 ElevenLabs 生成语音或音效

更复杂或高风险的操作会要求确认，信息不足时会先询问澄清问题。

## MCP 和本地执行的区别

ReaperAI 有两层执行能力：

| 模式 | 说明 |
| --- | --- |
| MCP 增强执行 | 本地 Python MCP 服务在线时使用，适合结构化、可验证的 REAPER 操作 |
| 本地执行模式 | MCP 离线时使用 Lua/SCRIPT 兜底，适合播放、轨道、Marker、Region 等常见操作 |

所以即使用户电脑上的 Python、网络或 MCP 服务出现问题，ReaperAI 也不会直接失去执行模式。只是部分高级能力，例如音频分析、复杂导出、音效生成等，仍可能需要 MCP 或外部 API 正常工作。

## 安全机制

ReaperAI 尽量把执行风险显式化：

- 非执行模式下不会输出可执行操作。
- 执行模式下先生成操作计划，不直接自动改工程。
- 删除、批量修改、文件写入等操作会显示风险提示。
- AI 生成脚本会经过本地执行器处理。
- 本机能力检测会生成当前环境可用 API 和 Action 清单，减少模型调用不存在 API 的概率。

建议在重要工程中使用前先保存工程，或在工程副本中测试复杂批量操作。

## 故障排查

### 测试连接超时

请检查：

- API Key 是否正确
- Provider 和 Base URL 是否匹配
- 当前网络是否能访问对应供应商
- 代理或防火墙是否拦截请求
- 模型名称是否真实存在

如果“刷新模型列表”失败，但本地推荐模型仍可选择，可以先使用内置模型列表。

### 点击执行模式后 MCP 启动失败

这是可接受的降级状态。ReaperAI 会保留本地执行模式，常见操作仍然可执行。

如果你需要 MCP 增强能力，请检查：

- 是否运行过 `【第一步】安装依赖.bat`
- `MCP_Server` 是否位于 REAPER 根目录
- 端口 `8765` 是否被其他程序占用
- 杀毒软件是否拦截本地 Python 或 bat 脚本

### 本机能力检测失败

请确认：

- `Scripts` 文件夹已复制到 REAPER 根目录
- `UserPlugins` 文件夹已复制到 REAPER 根目录
- REAPER 已重新启动
- 当前用户有权限在 REAPER 目录下写入 JSON 文件

检测成功后，ReaperAI 会使用本机生成的能力清单来提高执行兼容性。

## 隐私说明

ReaperAI 会把你的对话内容、当前工程上下文和必要的操作意图发送给你配置的 LLM 服务商，以便生成回复或操作计划。API Key 保存在本地配置中，请不要把自己的配置文件或密钥上传到公开仓库。

项目本身不内置任何用户的 LLM API Key。

## 许可证

本项目使用 MIT License。详见 [LICENSE](LICENSE)。

## 作者

zhanghuisen

GitHub: [Zhanghuisen](https://github.com/Zhanghuisen)
