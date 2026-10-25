import Foundation
import SlopeSendCore
import Security

/// The shared access key lives only in the login Keychain (never UserDefaults or files).
enum Keychain {
    static let service = "com.slopecycle.send"
    static let account = "queue-access-key"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read() -> String {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    @discardableResult
    static func write(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(trimmed.utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

enum SettingsKeys {
    static let interviewer = "interviewerName"
    static let repository = "queueRepository"
}

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    /// Read fresh each time so a change in Settings applies to the next send.
    static let currentSettings: @Sendable () -> QueueSettings = {
        QueueSettings(
            interviewer: UserDefaults.standard.string(forKey: SettingsKeys.interviewer) ?? "",
            repository: UserDefaults.standard.string(forKey: SettingsKeys.repository) ?? "",
            token: Keychain.read())
    }
}
