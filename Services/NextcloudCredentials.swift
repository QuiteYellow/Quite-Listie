//
//  NextcloudCredentials.swift
//  Listie.md
//
//  Nextcloud account credentials stored securely in the Keychain.
//  Also manages NextcloudKit session setup/teardown.
//

import Foundation
import Security
import NextcloudKit

// MARK: - Credentials

struct NextcloudCredentials: Codable {
    let serverURL: String    // https://cloud.example.com (no trailing slash)
    let username: String
    let appPassword: String

    /// Unique account identifier used as the NextcloudKit session key.
    var accountId: String { "\(username)@\(serverURL)" }

    /// URL with /remote.php/dav/files/<user>/ prefix used for all WebDAV calls.
    func davBase() -> String {
        "\(serverURL)/remote.php/dav/files/\(username)"
    }

    /// Full WebDAV URL for a given remote path (e.g. "/lists/groceries.listie").
    func davURL(for remotePath: String) -> String {
        let clean = remotePath.hasPrefix("/") ? remotePath : "/\(remotePath)"
        return "\(serverURL)/remote.php/dav/files/\(username)\(clean)"
    }
}

// MARK: - Keychain helpers

extension NextcloudCredentials {
    private static let keychainKey = "com.listie.nextcloud.credentials"
    static let isConnectedDefaultsKey = "com.listie.nextcloud.isConnected"

    // MARK: Save

    func save() throws {
        let data = try JSONEncoder().encode(self)
        let query: [CFString: Any] = [
            kSecClass:           kSecClassGenericPassword,
            kSecAttrAccount:     NextcloudCredentials.keychainKey,
            kSecValueData:       data,
            kSecAttrAccessible:  kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        // Remove any previous entry first
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
        UserDefaults.standard.set(true, forKey: NextcloudCredentials.isConnectedDefaultsKey)
    }

    // MARK: Load

    static func load() -> NextcloudCredentials? {
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrAccount:      keychainKey,
            kSecReturnData:       true,
            kSecMatchLimit:       kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let creds = try? JSONDecoder().decode(NextcloudCredentials.self, from: data) else {
            return nil
        }
        return creds
    }

    /// iOS can transiently refuse keychain access right after deep sleep or app prewarming,
    /// even with `kSecAttrAccessibleAfterFirstUnlock`. Bounded retry with backoff gives the
    /// keychain a moment to become available before we conclude the user isn't connected.
    static func loadWithRetry(attempts: Int = 3, baseDelayMs: UInt64 = 50) async -> NextcloudCredentials? {
        for attempt in 0..<attempts {
            if let creds = load() { return creds }
            if attempt < attempts - 1 {
                let delay = baseDelayMs << UInt64(attempt)  // 50ms, 100ms, 200ms
                try? await Task.sleep(nanoseconds: delay * 1_000_000)
            }
        }
        return nil
    }

    // MARK: Delete

    static func delete() {
        let query: [CFString: Any] = [
            kSecClass:        kSecClassGenericPassword,
            kSecAttrAccount:  keychainKey
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.set(false, forKey: NextcloudCredentials.isConnectedDefaultsKey)
    }

    // MARK: Error

    enum KeychainError: LocalizedError {
        case saveFailed(OSStatus)
        var errorDescription: String? {
            switch self {
            case .saveFailed(let s): return "Keychain save failed (OSStatus \(s))"
            }
        }
    }
}

// MARK: - NextcloudKit session management

extension NextcloudCredentials {
    /// Registers a session in NextcloudKit for these credentials.
    func setupSession(nk: NextcloudKit) {
        nk.setup(groupIdentifier: nil)
        nk.appendSession(
            account:      accountId,
            urlBase:      serverURL,
            user:         username,
            userId:       username,
            password:     appPassword,
            userAgent:    "QuiteListie/1.0",
            groupIdentifier: ""
        )
    }
}
