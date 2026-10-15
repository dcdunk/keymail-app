import AppKit
import Foundation
import Network
import Security
import EmailCore
import CryptoKit

/// The demo build ("Email Demo", bundle id ending in .demo) keeps its own data and Keychain entries,
/// so it starts fresh like a new user and never touches the real app's accounts.
enum AppFlavor {
    static let isDemo = Bundle.main.bundleIdentifier?.hasSuffix(".demo") == true
}

// MARK: Disk

enum Disk {
    static let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppFlavor.isDemo ? "Email-Demo" : "Email")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        // Mail cache and settings: readable by you only.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: d.path)
        return d
    }()
    static func load<T: Decodable>(_ name: String, as: T.Type) -> T? {
        let url = dir.appendingPathComponent(name)
        guard let raw = try? Data(contentsOf: url) else { return nil }
        let data: Data
        if raw.starts(with: encryptedFileMagic) {
            guard let key = CacheKey.key else { return nil } // Keychain unavailable: don't touch the file
            guard let d = try? decryptFile(raw, key: key) else {
                // Never delete what can't be read; set it aside so nothing is overwritten.
                try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970))"))
                return nil
            }
            data = d
        } else {
            // Plain files exist only from before encryption, and are accepted just once: on the launch that
            // created the key. After that a plain file was planted (it would skip the tamper check), so it's set aside.
            _ = CacheKey.key // make sure the Keychain check has run
            guard CacheKey.createdThisLaunch else {
                try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("unencrypted-\(Int(Date().timeIntervalSince1970))"))
                return nil
            }
            data = raw
        }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        return try? dec.decode(T.self, from: data)
    }
    /// Encrypted with AES-256-GCM; the key lives in the Keychain. Readable by you only on disk too.
    static func save<T: Encodable>(_ value: T, _ name: String) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        // No key (Keychain refused): skip saving rather than write something unreadable or unencrypted.
        guard let key = CacheKey.key, let json = try? enc.encode(value), let sealed = try? encryptFile(json, key: key) else { return }
        let url = dir.appendingPathComponent(name)
        try? sealed.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Attachment previews must stay plain files for Quick Look, so they're cleared at every launch.
    static func clearPreviewCache() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(AppFlavor.isDemo ? "Email-Demo" : "Email")
        try? FileManager.default.removeItem(at: dir)
    }
}

/// The 256-bit key for Email's files: created once, kept in the Keychain, read once per launch.
/// Nil only if the Keychain refuses access; a new key is made only when none exists at all.
enum CacheKey {
    /// True only on the first launch after installing (or upgrading from a build without encryption).
    private(set) static var createdThisLaunch = false
    static let key: SymmetricKey? = {
        let account = "cache-encryption-key"
        var out: AnyObject?
        let q = [kSecClass: kSecClassGenericPassword, kSecAttrService: Keychain.service, kSecAttrAccount: account,
                 kSecReturnData: true] as CFDictionary
        switch SecItemCopyMatching(q, &out) {
        case errSecSuccess:
            guard let d = out as? Data, let b = Data(base64Encoded: d), b.count == 32 else { return nil }
            return SymmetricKey(data: b)
        case errSecItemNotFound:
            createdThisLaunch = true
            let k = SymmetricKey(size: .bits256)
            Keychain.set(k.withUnsafeBytes { Data($0) }.base64EncodedString(), for: account)
            return k
        default:
            return nil
        }
    }()
}

// MARK: Keychain (refresh tokens only)

enum Keychain {
    static let service = AppFlavor.isDemo ? "Email-Demo.google-refresh-token" : "Email.google-refresh-token"
    static func set(_ value: String, for account: String) {
        delete(account)
        SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                    kSecValueData: Data(value.utf8)] as CFDictionary, nil)
    }
    static func get(_ account: String) -> String? {
        var out: AnyObject?
        let q = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                 kSecReturnData: true] as CFDictionary
        guard SecItemCopyMatching(q, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func delete(_ account: String) {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as CFDictionary)
    }
}
