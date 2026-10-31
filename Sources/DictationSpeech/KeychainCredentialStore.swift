import Foundation
import os
import Security

actor KeychainCredentialStore: CredentialStoring {
    private let service: String
    /// The keychain to use instead of the user's default keychains; tests pass a temporary keychain.
    private let keychain: SecKeychain?
    init() { self.init(service: "com.speech2text.credentials") }
    init(service: String, keychain: sending SecKeychain? = nil) {
        self.service = service
        self.keychain = keychain
    }
    private func item(_ kind: CredentialKind) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: kind.rawValue,
         kSecAttrSynchronizable as String: false]
    }
    private func query(_ kind: CredentialKind) -> [String: Any] {
        var query = item(kind)
        if let keychain { query[kSecMatchSearchList as String] = [keychain] }
        return query
    }
    func load(_ kind: CredentialKind) throws -> String? {
        var attributes = query(kind)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw AppError.invalidResponse("Keychain credential encoding")
        }
        return value
    }
    func save(_ value: String, for kind: CredentialKind) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError.missingCredential(kind)
        }
        // Replaced, never updated in place: an item another program created under this service keeps its own access
        // list when only its data changes, so that program could read the key.
        try delete(kind)
        var attributes = item(kind)
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        if let keychain { attributes[kSecUseKeychain as String] = keychain }
        try check(SecItemAdd(attributes as CFDictionary, nil))
    }
    func delete(_ kind: CredentialKind) throws {
        let status = SecItemDelete(query(kind) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
    private static let log = Logger(subsystem: "local.speech2text.app", category: "keychain")
    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            // The status code is for diagnosis only; the user sees a plain sentence.
            Self.log.error("Keychain operation failed: OSStatus \(status, privacy: .public)")
            throw Self.error(for: status)
        }
    }
    /// Only a refused access prompt is a denial; locked keychains and storage failures are not permissions.
    static func error(for status: OSStatus) -> AppError {
        status == errSecUserCanceled || status == errSecAuthFailed ? .keychainDenied : .keychain(status)
    }
}
