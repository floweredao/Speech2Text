// Adapted from Speech-to-action; speech-only module, no command execution.
import Foundation
import Security

actor KeychainCredentialStore: CredentialStoring {
    private let service: String
    init() { service = "com.speech2text.credentials" }
    init(service: String) { self.service = service }
    private func query(_ kind: CredentialKind) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: kind.rawValue,
         kSecAttrSynchronizable as String: false]
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
        let update = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(query(kind) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query(kind).merging(update) { _, new in new }
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            try check(SecItemAdd(attributes as CFDictionary, nil))
        } else { try check(status) }
    }
    func delete(_ kind: CredentialKind) throws {
        let status = SecItemDelete(query(kind) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw AppError.permissionDenied("Keychain (OSStatus \(status))")
        }
    }
}
