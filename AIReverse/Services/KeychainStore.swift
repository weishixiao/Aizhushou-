import Foundation
import Security

/// 轻量 Keychain 封装：用于安全保存模型 API Key、GitHub/Gitee token 等敏感凭证，
/// 替代原来明文写入 UserDefaults / JSON 文件的做法。
///
/// 注意：这是 App 沙盒内最安全的免外部依赖方案。越狱环境下密钥仍可能被同进程
/// 的恶意注入读取，但相比明文落盘已是质的提升（非 root 进程无法访问其他 App 沙盒）。
final class KeychainStore {

    static let shared = KeychainStore()

    private let serviceName = "com.ai.reverser.credentials"

    private init() {}

    /// 读取隐私条目。返回 nil 表示未存储或读取失败。
    func read(_ account: String) -> String? {
        var query = queryDict(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    /// 写入或更新隐私条目。
    @discardableResult
    func write(_ value: String, account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        // 先尝试更新
        let updateQuery = queryDict(account: account)
        let attributes: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(updateQuery as CFDictionary, attributes as CFDictionary)

        if status == errSecItemNotFound {
            // 不存在则新增
            var addQuery = queryDict(account: account)
            addQuery[kSecValueData as String] = data
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    /// 删除条目。
    @discardableResult
    func delete(_ account: String) -> Bool {
        let query = queryDict(account: account)
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - 构造 query

    private func queryDict(account: String) -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            // 仅在当前设备当前 App 内可读，杜绝同步到 iCloud
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
    }
}
