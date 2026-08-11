import Foundation
import LocalAuthentication
import Security

enum ProviderCredentialStoreError: LocalizedError, Equatable {
    case invalidCredential
    case notFound
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidCredential: "API Key 不能为空、包含控制字符或超过 4096 个字符。"
        case .notFound: "凭据尚未配置。"
        case .unavailable: "macOS 钥匙串当前不可用。"
        }
    }
}

protocol ProviderCredentialStoring: AnyObject {
    func contains(providerID: ProviderID, kind: ProviderCredentialKind) -> Bool
    func read(providerID: ProviderID, kind: ProviderCredentialKind) throws -> String
    func save(_ credential: String, providerID: ProviderID, kind: ProviderCredentialKind) throws
    func delete(providerID: ProviderID, kind: ProviderCredentialKind) throws
}

final class DisabledProviderCredentialStore: ProviderCredentialStoring {
    func contains(providerID: ProviderID, kind: ProviderCredentialKind) -> Bool { false }

    func read(providerID: ProviderID, kind: ProviderCredentialKind) throws -> String {
        throw ProviderCredentialStoreError.notFound
    }

    func save(_ credential: String, providerID: ProviderID, kind: ProviderCredentialKind) throws {
        throw ProviderCredentialStoreError.unavailable
    }

    func delete(providerID: ProviderID, kind: ProviderCredentialKind) throws {}
}

final class KeychainProviderCredentialStore: ProviderCredentialStoring {
    static let service = "com.codexbar.provider-credentials.v1"

    private let cacheLock = NSLock()
    private var cachedCredentials: [String: String] = [:]
    private var blockedReads: Set<String> = []

    static func accountName(providerID: ProviderID, kind: ProviderCredentialKind) -> String {
        "\(providerID.rawValue).\(kind.rawValue)"
    }

    func contains(providerID: ProviderID, kind: ProviderCredentialKind) -> Bool {
        let account = Self.accountName(providerID: providerID, kind: kind)
        if cachedCredential(for: account) != nil { return true }

        var result: CFTypeRef?
        var query = baseQuery(providerID: providerID, kind: kind)
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true
        query[kSecUseAuthenticationContext as String] = authenticationContext
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    func read(providerID: ProviderID, kind: ProviderCredentialKind) throws -> String {
        let account = Self.accountName(providerID: providerID, kind: kind)
        if let credential = cachedCredential(for: account) { return credential }
        guard !isReadBlocked(for: account) else {
            throw ProviderCredentialStoreError.unavailable
        }

        var result: CFTypeRef?
        var query = baseQuery(providerID: providerID, kind: kind)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { throw ProviderCredentialStoreError.notFound }
        guard status == errSecSuccess,
              let data = result as? Data,
              let credential = String(data: data, encoding: .utf8),
              !credential.isEmpty else {
            blockRead(for: account)
            throw ProviderCredentialStoreError.unavailable
        }
        cache(credential, for: account)
        return credential
    }

    func save(_ credential: String, providerID: ProviderID, kind: ProviderCredentialKind) throws {
        let value = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.count <= 4_096,
              !value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw ProviderCredentialStoreError.invalidCredential
        }
        let data = Data(value.utf8)
        let query = baseQuery(providerID: providerID, kind: kind)
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
                throw ProviderCredentialStoreError.unavailable
            }
        } else if updateStatus != errSecSuccess {
            throw ProviderCredentialStoreError.unavailable
        }
        cache(value, for: Self.accountName(providerID: providerID, kind: kind))
    }

    func delete(providerID: ProviderID, kind: ProviderCredentialKind) throws {
        let status = SecItemDelete(baseQuery(providerID: providerID, kind: kind) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ProviderCredentialStoreError.unavailable
        }
        removeCachedCredential(for: Self.accountName(providerID: providerID, kind: kind))
    }

    private func baseQuery(providerID: ProviderID, kind: ProviderCredentialKind) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.accountName(providerID: providerID, kind: kind),
            kSecAttrSynchronizable as String: false
        ]
    }

    private func cachedCredential(for account: String) -> String? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cachedCredentials[account]
    }

    private func isReadBlocked(for account: String) -> Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return blockedReads.contains(account)
    }

    private func cache(_ credential: String, for account: String) {
        cacheLock.lock()
        cachedCredentials[account] = credential
        blockedReads.remove(account)
        cacheLock.unlock()
    }

    private func blockRead(for account: String) {
        cacheLock.lock()
        blockedReads.insert(account)
        cacheLock.unlock()
    }

    private func removeCachedCredential(for account: String) {
        cacheLock.lock()
        cachedCredentials[account] = nil
        blockedReads.remove(account)
        cacheLock.unlock()
    }
}
