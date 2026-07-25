# ReaperAI 手动安装（高级）

普通用户应优先使用 GitHub Releases 中的 `ReaperAI-Setup-v1.0.6.exe`。本页仅用于开发、安装器调试或特殊环境排障。

## 手动安装

1. 将仓库中的 `MCP_Server`、`Scripts`、`UserPlugins` 复制到 REAPER 资源目录。
2. 进入 `MCP_Server`，运行 `【第一步】安装依赖.bat`。
3. 运行 `【第二步】配置向导.bat` 并完成配置。
4. 启动 REAPER，按 `?` 打开 Action List。
5. 点击 `Load`，选择资源目录下的 `Scripts\ReaperAI.lua`。
6. 搜索并运行 `ReaperAI`。

可以在 REAPER 的 `Options` 菜单中打开资源目录。普通安装与便携安装的资源目录可能不同，不要仅根据 `reaper.exe` 所在位置猜测。

## 适用场景

- 调试安装器未覆盖的特殊环境。
- 修改源码后进行开发测试。
- 查看依赖安装过程的详细输出。

手动安装不再作为正式用户安装流程。提交问题时，请说明使用的是 EXE 安装还是手动安装。
