import SwiftUI
import UIKit

/// 仓库管理：打开本地目录 / 导入 GitHub 仓库 / 分支配置
struct RepoManagerView: View {
    @ObservedObject var agent: CodingAgent

    @State private var platform: GitPlatform = .github
    @State private var repoURL = ""
    @State private var token = ""
    @State private var branch = "main"
    @State private var showDocumentPicker = false
    @State private var showImportProgress = false
    @State private var importError: String?
    @State private var branches: [String] = []

    private let github = GitHubAPIClient()

    var body: some View {
        Form {
            Section("当前连接") {
                connectionStatus
            }

            Section {
                Picker("平台", selection: $platform) {
                    ForEach(GitPlatform.allCases, id: \.self) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .onChange(of: platform) { newValue in
                    branch = newValue.defaultBranch
                    agent.repoConfig.platform = newValue
                }
            }

            Section("本地仓库") {
                Button {
                    showDocumentPicker = true
                } label: {
                    Label("打开本地目录作为工作区", systemImage: "folder")
                }
                if let root = agent.workspace.workspaceRoot {
                    Label(root.path, systemImage: "folder.badge.gearshape")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section(platform == .github ? "GitHub 仓库" : "Gitee 仓库") {
                TextField(platform.repoPlaceholder, text: $repoURL)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                SecureField(platform.tokenHint, text: $token)
                TextField("分支", text: $branch)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)

                Button {
                    Task { await importRepo() }
                } label: {
                    if showImportProgress {
                        HStack {
                            ProgressView()
                            Text("正在导入...")
                        }
                    } else {
                        Label("导入仓库", systemImage: "arrow.down.circle")
                    }
                }
                .disabled(repoURL.trimmingCharacters(in: .whitespaces).isEmpty || showImportProgress)

                if !branches.isEmpty {
                    Picker("分支", selection: $branch) {
                        ForEach(branches, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                }
            }

            Section("安全") {
                Toggle("允许 AI 修改代码并提交", isOn: $agent.allowMutating)
                    .tint(.blue)
                Text("开启后 AI 可以写文件、提交变更。关闭时仅允许只读操作。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let err = importError {
                Section {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
        }
        .navigationTitle("仓库")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            platform = agent.repoConfig.platform
            repoURL = agent.repoConfig.repo
            token = agent.repoConfig.token
            branch = agent.repoConfig.branch.isEmpty ? platform.defaultBranch : agent.repoConfig.branch
        }
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPicker(onPick: { url in
                agent.setWorkspace(url)
                try? agent.workspace.ensureWorkspaceExists()
                agent.resetConversation()
            })
        }
    }

    @ViewBuilder
    private var connectionStatus: some View {
        if agent.repoConfig.hasRemote {
            statusRow(title: "平台", value: agent.repoConfig.platform.displayName, icon: "checkmark.seal.fill", color: .green)
            statusRow(title: "仓库", value: agent.repoConfig.repo, icon: "link", color: .blue)
            statusRow(title: "分支", value: agent.repoConfig.branch, icon: "arrow.triangle.branch", color: .blue)
        } else {
            statusRow(title: "远端仓库", value: "未连接", icon: "exclamationmark.circle", color: .orange)
        }

        if let root = agent.workspace.workspaceRoot {
            statusRow(title: "本地工作区", value: root.path, icon: "folder", color: .secondary)
        }
    }

    private func statusRow(title: String, value: String, icon: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(value.isEmpty ? "未设置" : value)
                    .font(.footnote)
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
            }
        }
    }

    private func importRepo() async {
        let repo = repoURL.trimmingCharacters(in: .whitespaces)
        let tk = token.trimmingCharacters(in: .whitespaces)
        guard !repo.isEmpty else { return }
        importError = nil
        showImportProgress = true

        // 暂存配置以便 git 工具使用
        agent.repoConfig.repo = repo
        agent.repoConfig.token = tk
        agent.repoConfig.branch = branch
        agent.repoConfig.platform = platform
        github.platform = platform

        do {
            // 拉取分支列表
            let list = try await github.branches(repo: repo, token: tk)
            await MainActor.run {
                branches = list
                if !list.contains(branch) {
                    branch = list.first ?? "main"
                    agent.repoConfig.branch = branch
                }
            }
            // 递归下载仓库内容到工作区根目录
            let workspaceRoot = try ensureRepoDirectory(named: repo)
            let downloaded = try await github.downloadRepo(repo: repo, token: tk, branch: branch, into: workspaceRoot)
            agent.setWorkspace(workspaceRoot)

            // 建立提交基线快照
            let snapshot = agent.workspace.snapshot(branch: branch, remoteURL: repo, commitHash: "")
            let tracker = GitStatusTracker()
            tracker.bind(to: agent.workspace)
            try tracker.saveSnapshot(snapshot)

            await MainActor.run {
                repoURL = repo
                token = tk
                branch = agent.repoConfig.branch
                importError = "仓库导入成功，下载 \(downloaded) 个文本文件到工作区。可以开始与 AI 对话。"
            }
            agent.resetConversation()
        } catch {
            await MainActor.run {
                importError = "导入失败：\(error.localizedDescription)"
            }
        }
        await MainActor.run {
            showImportProgress = false
        }
    }

    /// 在 Documents/Workspace 下创建以仓库名命名的目录
    private func ensureRepoDirectory(named repo: String) throws -> URL {
        let fm = FileManager.default
        let base = try agent.workspace.ensureWorkspaceExistsAndReturnRoot()
        let name = repo
            .replacingOccurrences(of: "/", with: "__")
            .replacingOccurrences(of: ":", with: "_")
        let dir = base.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
