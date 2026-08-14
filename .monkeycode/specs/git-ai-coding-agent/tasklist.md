# Implementation Tasklist: git-ai-coding-agent

Date: 2026-08-14

## Phase 1: 基础设施（服务层）

- [x] 1.1 实现 WorkspaceManager：工作区根目录管理、防路径逃逸的 resolve、文件树枚举、文本读写、原子写入与备份、快照生成
- [x] 1.2 实现 GitStatusTracker：基于 WorkspaceSnapshot 对比计算 added/modified/deleted/untracked 状态
- [x] 1.3 实现 GitHubAPIClient：GitHub REST API 封装（Contents/Commits/Trees/Branches），支持 clone、push、pull、branch 列表
- [x] 1.4 实现 CodingTool 协议与 ToolRegistry：工具 name/description/parameters(JSON Schema)/execute

## Phase 2: 内置工具

- [x] 2.1 实现只读工具：read_file、list_dir、git_status、git_branch、git_log、repo_overview
- [x] 2.2 实现修改工具：write_file（含备份）、git_commit（GitHub API 顺序执行 blob→tree→commit→ref）
- [x] 2.3 扩展 ChatMessage 模型支持 role=tool、toolCallID、name 字段
- [x] 2.4 扩展 LLMClient 支持 tools + tool_calls 解析与回传

## Phase 3: 编排与界面

- [x] 3.1 实现 CodingAgent：对话编排器，解析 tool_calls、执行工具、回传结果，支持取消与流式状态
- [x] 3.2 实现 ToolCallCard 状态模型与 Markdown/代码块渲染组件（语法高亮、复制按钮）
- [x] 3.3 重构 ChatView 为「聊天 + 代码双栏」：左侧对话流 + 工具卡片 + 打字指示器，右侧工作区文件树/代码阅读
- [x] 3.4 仓库管理界面：打开本地目录（文件选择器）、GitHub 仓库导入（地址 + Token）、「允许修改」安全开关
- [x] 3.5 集成到 ContentView tab 与 AIReverseApp 环境注入

## Phase 4: 验证与交付

- [x] 4.1 触发 GitHub Actions 构建验证，修复编译错误直至成功
- [x] 4.2 下载新 IPA 更新 Release v1.0.0 与预览页
- [x] 4.3 更新项目文档（project-wiki sync）与 tasklist 收尾
