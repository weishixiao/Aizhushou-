import Foundation

/// Git 托管平台
enum GitPlatform: String, CaseIterable, Codable {
    case github
    case gitee

    var displayName: String {
        switch self {
        case .github: return "GitHub"
        case .gitee: return "Gitee"
        }
    }

    var defaultBranch: String {
        switch self {
        case .github: return "main"
        case .gitee: return "master"
        }
    }

    var tokenHint: String {
        switch self {
        case .github: return "访问 Token（需 repo 权限）"
        case .gitee: return "访问 Token（需 projects 权限）"
        }
    }

    var repoPlaceholder: String {
        switch self {
        case .github: return "仓库地址（如 owner/repo 或 github.com/owner/repo）"
        case .gitee: return "仓库地址（如 owner/repo 或 gitee.com/owner/repo）"
        }
    }

    var apiBase: String {
        switch self {
        case .github: return "https://api.github.com"
        case .gitee: return "https://gitee.com/api/v5"
        }
    }
}

enum GitHubError: Error, LocalizedError {
    case emptyRepo
    case emptyToken
    case badURL(String)
    case network(Error)
    case badStatus(Int, String)
    case unauthorized
    case conflict(String)
    case notFound
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .emptyRepo:
            return "仓库地址不能为空"
        case .emptyToken:
            return "访问 Token 不能为空"
        case .badURL(let s):
            return "仓库地址无效：\(s)"
        case .network(let e):
            return "网络错误：\(e.localizedDescription)"
        case .badStatus(let code, let msg):
            return "Git 平台 API 返回 \(code)：\(msg)"
        case .unauthorized:
            return "Token 无效或已过期"
        case .conflict(let msg):
            return "远端已有更新，需先同步：\(msg)"
        case .notFound:
            return "仓库或文件不存在"
        case .decodeFailed:
            return "Git 平台 API 响应解析失败"
        }
    }
}

/// 文件在 GitHub 仓库中的条目
struct GHContentItem: Codable {
    let name: String
    let path: String
    let type: String
    let size: Int?
    let sha: String?
    let download_url: String?
}

/// 提交信息
struct GHCommitInfo: Codable {
    let sha: String
    let commit: GHCommit
    struct GHCommit: Codable {
        let message: String
        let author: GHAuthor
    }
    struct GHAuthor: Codable {
        let name: String
        let date: String
    }
}

/// GitHub REST API 客户端：负责远程仓库的拉取、浏览与提交。
/// 提交流程：blob -> tree -> commit -> ref（Git Data API）。
final class GitHubAPIClient {

    private let session: URLSession
    var platform: GitPlatform = .github

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        session = URLSession(configuration: config)
    }

    /// 解析 "https://github.com/owner/repo"、"https://gitee.com/owner/repo" 或 "owner/repo"
    func parseRepo(_ input: String) throws -> (owner: String, repo: String) {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw GitHubError.emptyRepo }
        if let range = s.range(of: "github.com/") {
            s = String(s[range.upperBound...])
        } else if let range = s.range(of: "gitee.com/") {
            s = String(s[range.upperBound...])
        }
        s = s.replacingOccurrences(of: ".git", with: "")
        let parts = s.split(separator: "/").map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            throw GitHubError.badURL(input)
        }
        return (parts[0], parts[1])
    }

    /// 列出仓库根目录或子目录内容
    func listContents(repo: String, token: String, path: String = "") async throws -> [GHContentItem] {
        let (owner, repoName) = try parseRepo(repo)
        var urlStr = "\(platform.apiBase)/repos/\(owner)/\(repoName)/contents"
        if !path.isEmpty {
            urlStr += "/" + path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
        }
        let items: [GHContentItem] = try await get(urlStr, token: token)
        return items
    }

    /// 下载远程文件内容（文本）
    func fetchFileContent(repo: String, token: String, path: String) async throws -> String {
        let (owner, repoName) = try parseRepo(repo)
        let urlStr = "\(platform.apiBase)/repos/\(owner)/\(repoName)/contents/"
            + path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
        let dict: [String: Any] = try await getDict(urlStr, token: token)
        if let downloadURL = dict["download_url"] as? String, let url = URL(string: downloadURL) {
            var request = URLRequest(url: url)
            if !token.isEmpty {
                switch platform {
                case .github:
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                case .gitee:
                    request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
                }
            }
            let (data, _) = try await session.data(for: request)
            if let text = String(data: data, encoding: .utf8) {
                return text
            }
        }
        if let content = dict["content"] as? String,
           let decoded = Data(base64Encoded: content.replacingOccurrences(of: "\n", with: "")),
           let text = String(data: decoded, encoding: .utf8) {
            return text
        }
        throw GitHubError.decodeFailed
    }

    /// 获取最新提交（默认分支 HEAD）
    func latestCommit(repo: String, token: String, branch: String = "main") async throws -> String {
        let (owner, repoName) = try parseRepo(repo)
        let urlStr = "\(platform.apiBase)/repos/\(owner)/\(repoName)/commits/\(branch)"
        let dict: [String: Any] = try await getDict(urlStr, token: token)
        guard let sha = dict["sha"] as? String else { throw GitHubError.decodeFailed }
        return sha
    }

    /// 列出分支
    func branches(repo: String, token: String) async throws -> [String] {
        let (owner, repoName) = try parseRepo(repo)
        let urlStr = "\(platform.apiBase)/repos/\(owner)/\(repoName)/branches?per_page=100"
        let items: [[String: Any]] = try await getArrayDict(urlStr, token: token)
        return items.compactMap { $0["name"] as? String }
    }

    /// 提交文件变更到指定分支。
    /// files: [相对路径: 新内容]。deleted: 需删除的文件相对路径。
    /// GitHub：blob -> tree -> commit -> ref（Git Data API）。
    /// Gitee：Contents API 逐文件提交。
    func commitFiles(
        repo: String,
        token: String,
        branch: String,
        message: String,
        files: [String: String],
        deletedPaths: [String] = []
    ) async throws -> String {
        let (owner, repoName) = try parseRepo(repo)
        guard !token.isEmpty else { throw GitHubError.emptyToken }
        if platform == .gitee {
            return try await giteeCommitFiles(
                owner: owner, repoName: repoName, token: token, branch: branch,
                message: message, files: files, deletedPaths: deletedPaths
            )
        }
        // 1. 获取当前分支的 base tree
        let branchInfo: [String: Any] = try await getDict(
            "\(platform.apiBase)/repos/\(owner)/\(repoName)/branches/\(branch)", token: token
        )
        guard let baseSHA = branchInfo["commit"] as? [String: Any],
              let commitSHA = baseSHA["sha"] as? String else {
            throw GitHubError.decodeFailed
        }
        let commitDetail: [String: Any] = try await getDict(
            "\(platform.apiBase)/repos/\(owner)/\(repoName)/git/commits/\(commitSHA)", token: token
        )
        guard let baseTree = commitDetail["tree"] as? [String: Any],
              let baseTreeSHA = baseTree["sha"] as? String else {
            throw GitHubError.decodeFailed
        }

        // 2. 创建 blobs
        var treeItems: [[String: Any]] = []
        for (path, content) in files {
            let blob: [String: Any] = try await postDict(
                "\(platform.apiBase)/repos/\(owner)/\(repoName)/git/blobs",
                token: token,
                body: ["content": content, "encoding": "utf-8"]
            )
            guard let blobSHA = blob["sha"] as? String else { throw GitHubError.decodeFailed }
            treeItems.append([
                "path": path,
                "mode": "100644",
                "type": "blob",
                "sha": blobSHA
            ])
        }
        for path in deletedPaths {
            treeItems.append([
                "path": path,
                "mode": "100644",
                "type": "blob",
                "sha": NSNull()
            ])
        }
        guard !treeItems.isEmpty else {
            throw GitHubError.badStatus(0, "没有需要提交的变更")
        }

        // 3. 创建 tree
        let tree: [String: Any] = try await postDict(
            "\(platform.apiBase)/repos/\(owner)/\(repoName)/git/trees",
            token: token,
            body: ["base_tree": baseTreeSHA, "tree": treeItems]
        )
        guard let newTreeSHA = tree["sha"] as? String else { throw GitHubError.decodeFailed }

        // 4. 创建 commit
        let committer = await gitIdentity()
        var commitBody: [String: Any] = [
            "message": message,
            "tree": newTreeSHA,
            "parents": [commitSHA]
        ]
        if !committer.name.isEmpty {
            commitBody["author"] = ["name": committer.name, "email": committer.email, "date": ISO8601DateFormatter().string(from: Date())]
            commitBody["committer"] = ["name": committer.name, "email": committer.email, "date": ISO8601DateFormatter().string(from: Date())]
        }
        let commit: [String: Any] = try await postDict(
            "\(platform.apiBase)/repos/\(owner)/\(repoName)/git/commits",
            token: token,
            body: commitBody
        )
        guard let newCommitSHA = commit["sha"] as? String else { throw GitHubError.decodeFailed }

        // 5. 更新 ref
        _ = try await postDict(
            "\(platform.apiBase)/repos/\(owner)/\(repoName)/git/refs/heads/\(branch)",
            token: token,
            body: ["sha": newCommitSHA]
        )
        return newCommitSHA
    }

    /// Gitee 提交：通过 Contents API 逐文件提交。
    /// 每次提交一个文件（Gitee 无 GitHub 式多文件 Git Data 提交流程），删除走 DELETE。
    private func giteeCommitFiles(
        owner: String,
        repoName: String,
        token: String,
        branch: String,
        message: String,
        files: [String: String],
        deletedPaths: [String]
    ) async throws -> String {
        guard !files.isEmpty || !deletedPaths.isEmpty else {
            throw GitHubError.badStatus(0, "没有需要提交的变更")
        }
        var lastSHA = ""
        // 逐文件提交写入/修改
        for (path, content) in files {
            let encoded = content.data(using: .utf8)?.base64EncodedString() ?? ""
            let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
            let urlStr = "\(platform.apiBase)/repos/\(owner)/\(repoName)/contents/\(encodedPath)"
            var body: [String: Any] = [
                "message": message,
                "content": encoded,
                "branch": branch
            ]
            // 更新已有文件时需携带当前 sha
            if let info = try? await getDict("\(urlStr)?ref=\(branch)", token: token),
               let sha = info["sha"] as? String {
                body["sha"] = sha
            }
            let result: [String: Any] = try await postDict(urlStr, token: token, body: body)
            if let commit = result["commit"] as? [String: Any],
               let sha = commit["sha"] as? String {
                lastSHA = sha
            }
        }
        // 删除文件
        for path in deletedPaths {
            let urlStr = "\(platform.apiBase)/repos/\(owner)/\(repoName)/contents/"
                + path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
            var request = try makeRequest(urlStr, token: token)
            request.httpMethod = "DELETE"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = ["message": message, "branch": branch]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            _ = try await send(request)
        }
        if lastSHA.isEmpty {
            lastSHA = "gitee-\(Int(Date().timeIntervalSince1970))"
        }
        return lastSHA
    }

    /// 创建分支（基于某 commit）
    func createBranch(repo: String, token: String, name: String, from commitSHA: String) async throws {
        let (owner, repoName) = try parseRepo(repo)
        let ref = "refs/heads/\(name)"
        let body: [String: Any] = ["ref": ref, "sha": commitSHA]
        _ = try await postDict(
            "\(platform.apiBase)/repos/\(owner)/\(repoName)/git/refs",
            token: token,
            body: body
        )
    }

    /// 获取提交历史
    func commitLog(repo: String, token: String, branch: String = "main", count: Int = 20) async throws -> [GHCommitInfo] {
        let (owner, repoName) = try parseRepo(repo)
        let urlStr = "\(platform.apiBase)/repos/\(owner)/\(repoName)/commits?sha=\(branch)&per_page=\(count)"
        return try await get(urlStr, token: token)
    }

    /// 递归下载仓库内容到本地目录（用于导入）。
    /// 返回下载的文件数。跳过二进制大文件（>1MB）。
    @discardableResult
    func downloadRepo(repo: String, token: String, branch: String, into root: URL) async throws -> Int {
        let (owner, repoName) = try parseRepo(repo)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        var count = 0

        func walk(_ path: String) async throws {
            let items = try await listContents(repo: repo, token: token, path: path)
            for item in items {
                let localURL = root.appendingPathComponent(item.path)
                if item.type == "dir" {
                    try fileManager.createDirectory(at: localURL, withIntermediateDirectories: true)
                    try await walk(item.path)
                } else if item.type == "file" {
                    guard let size = item.size, size <= 1_048_576 else { continue }
                    do {
                        let content = try await fetchFileContent(repo: repo, token: token, path: item.path)
                        try fileManager.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        if let data = content.data(using: .utf8) {
                            try data.write(to: localURL, options: .atomic)
                            count += 1
                        }
                    } catch {
                        // 二进制或大文件跳过
                        continue
                    }
                }
            }
        }

        try await walk("")
        return count
    }

    private func gitIdentity() async -> (name: String, email: String) {
        ("AIReverse", "aistudio@local")
    }

    // MARK: - HTTP helpers

    private func makeRequest(_ urlStr: String, token: String) throws -> URLRequest {
        guard var url = URL(string: urlStr) else { throw GitHubError.badURL(urlStr) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !token.isEmpty {
            switch platform {
            case .github:
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            case .gitee:
                // Gitee 支持 Authorization: token 头或 access_token 查询参数
                request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
                var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
                var items = comps?.queryItems ?? []
                items.append(URLQueryItem(name: "access_token", value: token))
                comps?.queryItems = items
                if let u = comps?.url { url = u }
                request.url = url
            }
        }
        request.setValue("AIReverse/1.0", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GitHubError.network(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw GitHubError.network(URLError(.badServerResponse))
        }
        switch http.statusCode {
        case 200..<300:
            return (data, http)
        case 401:
            throw GitHubError.unauthorized
        case 404:
            throw GitHubError.notFound
        case 409:
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw GitHubError.conflict(String(msg.prefix(300)))
        default:
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw GitHubError.badStatus(http.statusCode, String(msg.prefix(500)))
        }
    }

    private func get<T: Decodable>(_ urlStr: String, token: String) async throws -> T {
        let (data, _) = try await send(makeRequest(urlStr, token: token))
        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else {
            throw GitHubError.decodeFailed
        }
        return decoded
    }

    private func getDict(_ urlStr: String, token: String) async throws -> [String: Any] {
        let (data, _) = try await send(makeRequest(urlStr, token: token))
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GitHubError.decodeFailed
        }
        return dict
    }

    private func getArrayDict(_ urlStr: String, token: String) async throws -> [[String: Any]] {
        let (data, _) = try await send(makeRequest(urlStr, token: token))
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw GitHubError.decodeFailed
        }
        return arr
    }

    private func postDict(_ urlStr: String, token: String, body: [String: Any]) async throws -> [String: Any] {
        var request = try makeRequest(urlStr, token: token)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await send(request)
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GitHubError.decodeFailed
        }
        return dict
    }
}
