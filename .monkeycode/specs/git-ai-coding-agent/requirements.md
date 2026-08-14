# Requirements Document

Feature: git-ai-coding-agent
Date: 2026-08-14

## Introduction

在 AIReverse（iOS 逆向助手）中新增「Git 仓库 AI 编码助手」能力：App 内置一个可浏览、可编辑本地 Git 仓库的界面，并通过聊天式 AI 驱动直接修改项目代码、提交变更。AI 聊天界面升级为与 opencode 风格一致的现代编程助手界面。

## Glossary

- **系统（The system）**：AIReverse iOS App。
- **AI 助手**：App 内接入的 LLM（OpenAI 兼容接口，用户自配）。
- **Git 仓库入口**：App 内的 Git 仓库视图，可查看分支、文件、改动、提交。
- **本地仓库**：存储在 App 沙盒 Documents 下的 Git 工作副本。
- **工作区（The workspace）**：用户当前浏览的 Git 仓库根目录。
- **工具调用（Tool call）**：AI 助手在对话中触发的一次具体操作，如读文件、写文件、执行 git 命令。

## Requirements

### Requirement 1: Git 仓库导入与浏览

**User Story:** AS 逆向工程师，I want 在 App 内导入并浏览一个 Git 仓库，so that 我可以直观看到项目结构。

#### Acceptance Criteria

1. WHEN 用户点击「打开仓库」并选择本地目录，系统 SHALL 将该目录识别为 Git 仓库并显示在工作区。
2. WHEN 用户输入 GitHub 仓库地址与访问 Token，系统 SHALL 通过 GitHub API 克隆/下载该仓库到本地沙盒并显示在工作区。
3. WHEN 用户打开仓库后，系统 SHALL 展示文件树、当前分支、工作区改动数量与最近提交。
4. WHEN 用户浏览文件树并点击文本文件，系统 SHALL 在代码阅读器中显示文件内容并支持行号与语法高亮。
5. WHILE 用户浏览仓库，系统 SHALL 在顶部显示当前分支名与远端地址（若有）。

### Requirement 2: Git 操作接口

**User Story:** AS 用户，I want 在 App 内直接执行常用 Git 操作，so that 我可以完成提交、分支与同步。

#### Acceptance Criteria

1. WHEN 用户在工作区执行 `git status`，系统 SHALL 列出已修改、未跟踪与暂存文件。
2. WHEN 用户执行 `git add` 与 `git commit`，系统 SHALL 将选定改动提交到当前分支。
3. WHEN 用户执行 `git branch`，系统 SHALL 创建/切换分支。
4. WHEN 用户执行 `git log`，系统 SHALL 显示提交历史（哈希、作者、时间、消息）。
5. IF 远端仓库存在，WHEN 用户执行 `git push` / `git pull`，系统 SHALL 通过 GitHub API 与远端同步并报告结果。
6. WHEN 系统对本地仓库执行 git 操作，系统 SHALL 使用本地沙盒目录内的文件状态计算（文件本地），并通过 GitHub API 完成远端提交（API 提交）。

### Requirement 3: AI 驱动的代码修改

**User Story:** AS 用户，I want 用聊天方式让 AI 直接修改仓库代码，so that 我不需要手动逐个文件编辑。

#### Acceptance Criteria

1. WHEN 用户向 AI 发送修改指令，系统 SHALL 将指令连同仓库文件清单与相关文件内容发送给 AI 助手。
2. WHEN AI 助手输出「读文件」工具调用，系统 SHALL 读取对应文件内容并回传给 AI 继续推理。
3. WHEN AI 助手输出「写文件」工具调用，系统 SHALL 将内容写入工作区对应路径并保留原文件备份。
4. WHEN AI 助手输出「执行 git 命令」工具调用，系统 SHALL 在工作区执行该命令并返回输出。
5. WHEN 任一工具调用执行完毕，系统 SHALL 将执行结果回传给 AI，由 AI 生成面向用户的总结。
6. WHILE AI 执行工具调用，系统 SHALL 在聊天界面展示工具名、参数与执行状态的实时卡片。
7. IF 写文件或 git 操作失败，系统 SHALL 将错误信息回传给 AI 并在界面提示用户。

### Requirement 4: opencode 风格聊天界面

**User Story:** AS 用户，I want 一个与 opencode 一致的专业编程聊天界面，so that 我可以高效阅读代码与工具调用过程。

#### Acceptance Criteria

1. WHEN 助手消息包含代码块，系统 SHALL 以等宽字体渲染并支持语法高亮与复制按钮。
2. WHEN 助手消息包含工具调用，系统 SHALL 以独立卡片展示工具图标、名称、参数摘要与展开详情。
3. WHEN 助手正在生成回复，系统 SHALL 显示打字指示器（闪烁光标或流式文本）。
4. WHEN 用户输入消息，系统 SHALL 提供多行输入框、发送按钮与 Ctrl/Enter 发送快捷键。
5. WHILE 聊天进行中，系统 SHALL 在顶部展示当前工作区仓库名与分支徽标。
6. WHILE 用户使用编程助手，系统 SHALL 采用「聊天 + 代码双栏」布局：左侧为对话流，右侧为当前工作区代码/文件浏览。

### Requirement 5: 权限与安全

**User Story:** AS 用户，I want 明确控制 AI 对仓库的写入能力，so that 我避免意外破坏代码。

#### Acceptance Criteria

1. WHILE 未开启「允许 AI 修改」开关，系统 SHALL 仅允许 AI 执行只读工具（读文件、status、log、branch 列表）。
2. WHEN 用户开启「允许 AI 修改」开关，系统 SHALL 允许 AI 执行写文件、git add/commit/push。
3. WHEN AI 执行写文件或 git push，系统 SHALL 在界面显著位置展示待执行改动并在执行前提示。
4. WHILE 系统执行任何 git 命令，系统 SHALL 将输出限制在工作区目录内，拒绝路径逃逸（`..`、绝对路径）。
5. IF 检测到疑似恶意指令（如删除整个仓库、执行未授权脚本），系统 SHALL 拒绝执行并告知用户。
