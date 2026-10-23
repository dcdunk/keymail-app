import os
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
    /// Running under XCTest: data, cache key and Keychain entries go to throwaway places, never the real app's.
    static let isTesting = NSClassFromString("XCTestCase") != nil
}

// MARK: Disk

enum Disk {
    static let dir: URL = {
        let d = AppFlavor.isTesting ? FileManager.default.temporaryDirectory.appendingPathComponent("Keymail-Tests-\(ProcessInfo.processInfo.processIdentifier)")
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppFlavor.isDemo ? "Email-Demo" : "Email")
        if AppFlavor.isDemo { try? FileManager.default.removeItem(at: d) } // the demo starts over at the welcome screen every launch
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        // Mail cache and settings: readable by you only.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: d.path)
        return d
    }()
    static func load<T: Decodable>(_ name: String, as: T.Type) -> T? {
        _ = recovered
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
/// Nil only if the Keychain refuses access; a new key is made only when none exists under either Keychain name.
enum CacheKey {
    static let account = "cache-encryption-key"
    /// True only on the first launch after installing (or upgrading from a build without encryption).
    private(set) static var createdThisLaunch = false
    static let key: SymmetricKey? = {
        if AppFlavor.isTesting { return SymmetricKey(size: .bits256) }
        switch lookup(Keychain.service) {
        case .found(let k): return k
        case .refused: return nil
        case .missing: break
        }
        // Written before the Keychain entries were renamed: carry it over instead of making a new one.
        switch lookup(Keychain.legacyService) {
        case .found(let k):
            Keychain.set(k.withUnsafeBytes { Data($0) }.base64EncodedString(), for: account)
            return k
        case .refused: return nil
        case .missing:
            createdThisLaunch = true
            let k = SymmetricKey(size: .bits256)
            Keychain.set(k.withUnsafeBytes { Data($0) }.base64EncodedString(), for: account)
            return k
        }
    }()
    /// The key under the old Keychain name, if one is there (used to recover files it encrypted).
    static var legacyKey: SymmetricKey? { if case .found(let k) = lookup(Keychain.legacyService) { return k }; return nil }

    enum Lookup { case found(SymmetricKey), missing, refused }
    static func lookup(_ service: String) -> Lookup {
        var out: AnyObject?
        let q = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account, kSecReturnData: true] as CFDictionary
        switch SecItemCopyMatching(q, &out) {
        case errSecSuccess:
            guard let d = out as? Data, let b = Data(base64Encoded: d), b.count == 32 else { return .refused }
            return .found(SymmetricKey(data: b))
        case errSecItemNotFound: return .missing
        default: return .refused
        }
    }
}

extension Disk {
    /// One-time repair for files set aside as unreadable because a new key was made while the old one still existed
    /// (Oct 2026, Keychain rename). Any set-aside file the old key opens is re-encrypted with the current key and put
    /// back; the set-aside copy is renamed ".restored" so this never runs twice for it.
    static let recovered: Void = {
        guard let current = CacheKey.key, let old = CacheKey.legacyKey,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for (aside, original) in setAsideToRestore(names) {
            let asideURL = dir.appendingPathComponent(aside), url = dir.appendingPathComponent(original)
            guard let raw = try? Data(contentsOf: asideURL), let plain = try? decryptFile(raw, key: old),
                  let sealed = try? encryptFile(plain, key: current) else { continue }
            do {
                try sealed.write(to: url, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                try FileManager.default.moveItem(at: asideURL, to: dir.appendingPathComponent(aside.replacingOccurrences(of: ".unreadable-", with: ".restored-")))
                AuthLog.log.notice("restored \(original, privacy: .public) from \(aside, privacy: .public)")
            } catch { AuthLog.log.error("restore of \(original, privacy: .public) failed: \(error.localizedDescription, privacy: .public)") }
        }
    }()
}

/// For each file name, the newest "name.unreadable-<time>" copy set aside, as (set-aside name, original name).
func setAsideToRestore(_ names: [String]) -> [(String, String)] {
    var newest: [String: (time: Int, name: String)] = [:]
    for n in names {
        guard let r = n.range(of: ".unreadable-"), let t = Int(n[r.upperBound...]) else { continue }
        let original = String(n[..<r.lowerBound])
        if (newest[original]?.time ?? Int.min) < t { newest[original] = (t, n) }
    }
    return newest.map { ($0.value.name, $0.key) }.sorted { $0.1 < $1.1 }
}

// MARK: Keychain (refresh tokens only)

enum Keychain {
    /// Entries written by this and later builds. The older name stays readable: entries some earlier builds
    /// created can't be replaced by a differently signed build, which silently kept stale sign-ins.
    static let service = AppFlavor.isTesting ? "Keymail-Tests.token" : AppFlavor.isDemo ? "Email-Demo.google-refresh-token.v2" : "Email.google-refresh-token.v2"
    static let legacyService = AppFlavor.isDemo ? "Email-Demo.google-refresh-token" : "Email.google-refresh-token"

    static func set(_ value: String, for account: String) {
        let q = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as CFDictionary
        var status = SecItemUpdate(q, [kSecValueData: Data(value.utf8)] as CFDictionary)
        // Not found, or an entry this build may not change (made by a differently signed build): replace it outright.
        // Keeping the old one left a revoked sign-in in place, so re-signing in "expired" again an hour later.
        if status != errSecSuccess {
            SecItemDelete(q)
            status = SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                                 kSecValueData: Data(value.utf8)] as CFDictionary, nil)
        }
        if status == errSecSuccess { SecItemDelete(query(legacyService, account)) } // best effort; reads prefer the new entry anyway
        AuthLog.log.notice("keychain save \(account, privacy: .public): status=\(status) readback=\(get(account) == value)")
    }
    static func get(_ account: String) -> String? { read(service, account) ?? read(legacyService, account) }
    static func delete(_ account: String) {
        SecItemDelete(query(service, account)); SecItemDelete(query(legacyService, account))
    }

    private static func query(_ svc: String, _ account: String) -> CFDictionary {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: svc, kSecAttrAccount: account] as CFDictionary
    }
    private static func read(_ svc: String, _ account: String) -> String? {
        var out: AnyObject?
        let q = [kSecClass: kSecClassGenericPassword, kSecAttrService: svc, kSecAttrAccount: account, kSecReturnData: true] as CFDictionary
        guard SecItemCopyMatching(q, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}

/// Sign-in diagnostics: account names, permission names and status codes only, never tokens.
enum AuthLog { static let log = Logger(subsystem: "app.keymail", category: "auth") }
