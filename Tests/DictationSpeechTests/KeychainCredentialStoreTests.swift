import Foundation
import Security
import Testing
@testable import DictationSpeech

@Suite(.serialized) struct KeychainCredentialStoreTests {
    /// An item another program left under the app's service and account keeps that program's access list and
    /// attributes when the app writes its key into it. Saving must replace the item, so the app's own access settings
    /// apply. The planted comment stands for everything the app does not write itself.
    @Test func savingReplacesAnExistingItemInsteadOfWritingIntoIt() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeychainCredentialStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // The user's login keychain refuses writes from a test process (errSecInteractionNotAllowed), so the test uses
        // its own unlocked keychain.
        let password = "test"
        var created: SecKeychain?
        let path = directory.appendingPathComponent("test.keychain-db").path
        #expect(SecKeychainCreate(path, UInt32(password.utf8.count), password, false, nil, &created) == errSecSuccess)
        let keychain = try #require(created)
        defer { SecKeychainDelete(keychain) }
        let service = "KeychainCredentialStoreTests-\(UUID().uuidString)"
        let planted: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: CredentialKind.soniox.rawValue,
            kSecAttrComment as String: "planted",
            kSecValueData as String: Data("planted-key".utf8),
            kSecUseKeychain as String: keychain,
        ]
        #expect(SecItemAdd(planted as CFDictionary, nil) == errSecSuccess)

        // The store gets its own reference to the same keychain file.
        var opened: SecKeychain?
        #expect(SecKeychainOpen(path, &opened) == errSecSuccess)
        let store = KeychainCredentialStore(service: service, keychain: opened)
        try await store.save("new-key", for: .soniox)

        #expect(try await store.load(.soniox) == "new-key")
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: CredentialKind.soniox.rawValue,
            kSecMatchSearchList as String: [keychain],
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        #expect(SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess)
        let items = try #require(result as? [[String: Any]])
        #expect(items.count == 1)
        #expect(items.first?[kSecAttrComment as String] as? String == nil)
        try await store.delete(.soniox)
        #expect(try await store.load(.soniox) == nil)
    }
}
