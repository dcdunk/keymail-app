import Foundation

// MARK: Cache encryption

import CryptoKit

/// Files written by Email start with this so encrypted and old plain files can be told apart.
public let encryptedFileMagic = Data("EMC1".utf8)

/// AES-256-GCM: confidentiality plus tamper detection.
public func encryptFile(_ plain: Data, key: SymmetricKey) throws -> Data {
    guard let sealed = try AES.GCM.seal(plain, using: key).combined else { throw CocoaError(.coderInvalidValue) }
    return encryptedFileMagic + sealed
}

/// Decrypts Keymail's files. Anything without the encryption header is rejected, so a planted plain file
/// can't slip past the tamper check. (Old plain files are migrated once, in Disk.load.)
public func decryptFile(_ data: Data, key: SymmetricKey) throws -> Data {
    guard data.starts(with: encryptedFileMagic) else { throw CocoaError(.fileReadCorruptFile) }
    return try AES.GCM.open(AES.GCM.SealedBox(combined: data.dropFirst(encryptedFileMagic.count)), using: key)
}
