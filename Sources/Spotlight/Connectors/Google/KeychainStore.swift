import Foundation
import Security

// Keeps credentials in the macOS Keychain, the system's encrypted password
// store, rather than in a file anyone could read. The Keychain API is old C,
// so it speaks in dictionaries of "kSec..." keys and numeric status codes.
struct KeychainStore: CredentialStore {
    // A Keychain item is found by two labels, like a folder and a file name:
    // `service` (whose items: this app's Google logins) and `account` (which
    // one: we use the Google account's email). The bundle ID keeps other builds
    // or apps from colliding with ours.
    var service = (Bundle.main.bundleIdentifier ?? "com.ivanleomk.spotlight") + ".google"

    // The Keychain treats the program that created an item as its owner: other
    // programs (including older builds of this app) must ask you to allow each
    // read, and can't delete it at all.
    struct KeychainError: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String {
            if status == errSecInvalidOwnerEdit {
                return "This login was saved by an older build of Spotlight, so macOS won't let this one remove it. Delete \"com.ivanleomk.spotlight.google\" in Keychain Access, then sign in again."
            }
            return (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
        }
    }

    // All of this app's Google items, or just the one for `account`.
    private func query(account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    func emails() throws -> [String] {
        // Ask for every item's labels (not its data: macOS won't return the
        // data of several items in one call).
        var search = query()
        search[kSecMatchLimit as String] = kSecMatchLimitAll
        search[kSecReturnAttributes as String] = true
        var result: AnyObject?
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw KeychainError(status: status)
        }
        return Set(items.compactMap { $0[kSecAttrAccount as String] as? String }).sorted()
    }

    func load(_ email: String) throws -> GoogleCredentials? {
        try read(account: email)
    }

    func save(_ credentials: GoogleCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let item = query(account: credentials.email)
        // Update if it exists, otherwise add.
        var status = SecItemUpdate(item as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var new = item
            new[kSecValueData as String] = data
            status = SecItemAdd(new as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func delete(_ email: String) throws {
        let status = SecItemDelete(query(account: email) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    private func read(account: String) throws -> GoogleCredentials? {
        var search = query(account: account)
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return try JSONDecoder().decode(GoogleCredentials.self, from: data)
    }
}
