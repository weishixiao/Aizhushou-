# AI逆向助手（AI Reverse Assistant）

一个可安装在 iOS 设备（越狱 / TrollStore）上的 **AI 聊天式逆向分析工具**。

通过对话驱动对 `.tipa` / `.ipa` / `.app` / 裸 Mach-O 二进制的静态分析：
本地解析 Mach-O 头、Load Commands、ObjC 类与方法、符号表、字符串，并把分析结果注入 AI 上下文，用自然语言提问即可获得反汇编解读、逻辑梳理等。

## 功能

- **本地静态分析**（纯 Swift 实现，无需 Ghidra/IDA）：
  - Mach-O fat/64 头、架构信息、Load Commands、segments
  - ObjC 类列表、方法列表（selector / imp / type encoding）、父类关系
  - 符号表（nlist_64）、可读字符串提取（含 URL / key 等可疑串）
  - ARM64 轻量反汇编（RET/BL/ADRP/LDR/STR/CBZ/STP 等常用指令）
- **AI 聊天**：OpenAI 兼容 `chat/completions` 协议，分析结果自动注入系统提示
- **自定义模型**：Base URL / API Key / 模型名全部可配置，支持多套模型保存切换
  （兼容 DeepSeek、OpenAI、Kimi、Ollama 等任何 OpenAI 兼容接口）
- **文件导入**：通过系统文件选择器导入 `.tipa` / `.ipa` / `.app` / 裸 Mach-O

## 构建（方式一：本地 Mac + Xcode）

1. 将 `AIReverse` 文件夹拷贝到 Mac
2. 用 Xcode 打开 `AIReverse.xcodeproj`（建议 Xcode 16+）
3. 选择签名 Team（任何 Apple ID 即可，TrollStore 安装不校验签名有效性）
4. 选择 **iOS Device** 作为目标，`Product → Archive` 或 `Build`
5. 在 `Products` 目录找到 `AIReverse.app`，压缩为 `.ipa`
   （或用 `xcodebuild` 命令行导出）

```bash
xcodebuild -project AIReverse.xcodeproj -scheme AIReverse \
  -configuration Release -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

## 构建（方式二：GitHub Actions 云端，无需 Mac）

没有 Mac 时，用 GitHub 免费托管的 macOS runner 远程编译：

1. 在 GitHub 新建仓库，把本项目 `AIReverse/` 目录内容推送上去
2. 仓库里已带 `.github/workflows/build-ipa.yml`
3. 进入仓库 **Actions** 页，手动运行 **Build IPA** workflow
   （或在推送 `v*` tag 时自动触发）
4. 运行完成后，在运行详情页的 **Artifacts** 下载 `AIReverse.ipa`
5. 用 TrollStore 打开安装

> workflow 使用 `maxim-lobanov/setup-xcode@v1` 自动选择最新 Xcode，
> 构建时关闭代码签名（`CODE_SIGNING_ALLOWED=NO`），
> 产物为未签名 `.ipa`，适用于 TrollStore / 越狱环境。

## 安装（TrollStore）

1. 把生成的 `.ipa` 用 TrollStore 打开并安装
2. 首次使用：
   - 打开「模型设置」，添加你的模型（Base URL / API Key / 模型名）
   - 打开「分析」，选择要分析的目标文件
   - 切到「AI 对话」，开始提问

## 项目结构

```
AIReverse/
├── AIReverse.xcodeproj        # Xcode 工程（同步文件组，自动包含源码）
└── AIReverse/
    ├── AIReverseApp.swift     # App 入口
    ├── Models/                # 数据模型（模型配置/聊天/分析结果）
    ├── Services/              # 核心引擎
    │   ├── MachOParser.swift      # Mach-O 解析
    │   ├── ObjCParser.swift       # ObjC 元数据解析
    │   ├── ARM64Disassembler.swift # ARM64 反汇编
    │   ├── StringExtractor.swift  # 字符串提取
    │   ├── ZipReader.swift        # 纯 Swift ZIP 解压
    │   ├── AppAnalyzer.swift      # 分析协调器
    │   └── LLMClient.swift        # OpenAI 兼容聊天客户端
    └── Views/                 # 聊天 / 分析 / 模型设置界面
```

## 说明

- 本工具仅用于合规的安全研究、CTF、自身 App 的调试分析等正当用途
- AI 分析内容由你自己配置的模型服务提供，数据经你自己的 API 发送
