# AIReverse（AI 逆向 / 编码助手）

一个可安装在 iOS 设备（越狱 / TrollStore）上的 **AI 编码与逆向分析助手**。

通过对话驱动：AI 可以直接读写设备上的任意文件、执行 shell 命令、搜索代码、发起 HTTP 请求，
并通过 GitHub / Gitee REST API 拉取远程仓库、修改代码并提交推送——把整台越狱设备变成 AI 的工作机。

> 版本 v1.2.1 起，项目重心从 Mach-O 静态分析转向 **Git AI 编码助手**（详见 `.monkeycode/specs/git-ai-coding-agent/`）。

## 功能

### AI 编码助手（核心）
- **工具调用循环**：OpenAI function calling 驱动，最多 100 轮迭代，自动防死循环
- **shell 执行**：`shell_execute` 基于 posix_spawn，支持任意命令与超时控制
- **文件读写**：`read_file` / `write_file` 支持任意绝对路径（越狱环境无沙盒限制）
- **搜索**：`find_files` 递归查找文件、`grep` 正则搜索文本内容
- **HTTP 请求**：`http_request` 任意方法 + 文件下载
- **Git 提交**：`git_commit` 通过 GitHub / Gitee Git Data API 完成 blob → tree → commit → ref 全流程
- **流式输出**：回复逐字实时渲染（SSE），429/5xx 指数退避自动重试
- **图片理解**：相册选图随消息发送给多模态模型（自动压缩到长边 1600px）
- **防失控**：重复调用检测、连续失败熔断、后台任务超时保护、断点恢复

### MCP 支持
- 支持在设置中添加 MCP Server（**Streamable HTTP / SSE** 传输），自动拉取远程工具并注册进对话
- iOS 无法运行本地 stdio 进程，stdio 类型服务会被跳过

### 模型管理
- **双协议**：OpenAI 兼容（DeepSeek / OpenAI / Kimi / Ollama 等）+ Anthropic Claude
- 多套模型配置保存与快速切换，支持在线拉取模型列表
- **API Key 存储在 iOS Keychain**（`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`），不再明文落盘
- 上下文自动截断，长会话不爆 token

### 辅助能力
- **包扫描**：导入 `.ipa` / `.tipa` / `.apk` 等文件，提取可读字符串、URL Scheme、权限、entitlements，生成扫描报告注入 AI 上下文
- **应用管理**：列出已安装应用（图标 / Bundle ID / 路径），一键设定为目标应用
- **工作区**：本地沙盒目录作为 Git 仓库工作区，防路径逃逸
- **运行日志**：RuntimeLogger 全量记录，输出前自动脱敏（Bearer / x-api-key / GitHub token 等）

## 构建（方式一：本地 Mac + Xcode）

1. 用 Xcode 打开 `AIReverse.xcodeproj`（建议 Xcode 16+）
2. 选择签名 Team（任何 Apple ID 即可，TrollStore 安装不校验签名有效性）
3. 选择 **iOS Device** 作为目标，`Product → Archive` 或 Build

```bash
xcodebuild -project AIReverse.xcodeproj -scheme AIReverse \
  -configuration Release -derivedDataPath build \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

或直接运行 `./build_ipa.sh` 一键构建并打包 `AIReverse.ipa`。

## 构建（方式二：GitHub Actions 云端，无需 Mac）

1. Fork / 推送本仓库
2. 进入 **Actions** 页，运行 **Build IPA** workflow（push 到 main/master 或打 `v*` tag 自动触发）
3. 在运行详情页 **Artifacts** 下载 `AIReverse.ipa`
4. 用 TrollStore 打开安装

> workflow 使用 `maxim-lobanov/setup-xcode@v1` 自动选择最新 Xcode，
> 构建时关闭代码签名（`CODE_SIGNING_ALLOWED=NO`），
> 产物为未签名 `.ipa`，适用于 TrollStore / 越狱环境。

## 使用

1. 首次使用：打开「模型设置」→ 添加模型（Base URL / API Key / 模型名）
2. 在仓库管理中导入本地目录或填写 GitHub / Gitee 仓库 + Token 拉取远程仓库
3. 「AI 对话」中直接下达任务：改代码、跑命令、查资料、提交推送……
4. 「允许 AI 修改代码并提交」开关默认关闭，按需打开

## 项目结构

```
AIReverse/
└── AIReverse/
    ├── AIReverseApp.swift        # App 入口
    ├── Models/
    │   ├── AIModelConfig.swift   # 模型配置（Keychain 存 apiKey）
    │   ├── ChatMessage.swift     # 会话消息（含图片附件）
    │   └── MCPServerConfig.swift # MCP Server 配置与导入
    ├── Services/
    │   ├── LLMClient.swift       # OpenAI / Anthropic 双协议 + 流式 SSE
    │   ├── CodingAgent.swift     # 工具调用循环编排
    │   ├── CodingTool.swift      # 工具协议 / 注册表 / 仓库配置
    │   ├── BuiltinTools.swift    # list_dir / git_status / git_log 等
    │   ├── AppTool.swift         # shell / 任意读写 / grep / http
    │   ├── MutatingTools.swift   # git_commit（修改类）
    │   ├── MCPClient.swift       # MCP Streamable HTTP / SSE 客户端
    │   ├── GitHubAPIClient.swift # GitHub / Gitee REST API
    │   ├── GitStatusTracker.swift# 轻量 Git 状态计算
    │   ├── WorkspaceManager.swift# 工作区管理（防路径逃逸）
    │   ├── PackageScanner.swift  # 安装包扫描
    │   ├── InstalledApps.swift   # 已安装应用
    │   ├── KeychainStore.swift   # Keychain 封装
    │   └── RuntimeLogger.swift   # 运行日志（自动脱敏）
    └── Views/                    # 聊天 / 设置 / 仓库管理等界面
```

## 说明

- 本工具仅用于合规的安全研究、CTF、自身 App 的调试分析等正当用途
- AI 分析内容由你自己配置的模型服务提供，数据经你自己的 API 发送
- 私有 entitlements（no-sandbox 等）仅在 TrollStore / 越狱环境生效
- License: [MIT](LICENSE)
