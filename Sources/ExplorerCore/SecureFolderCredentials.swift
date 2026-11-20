// SPDX-License-Identifier: Apache-2.0
import CommonCrypto
import CryptoKit
import Foundation

public enum SecureFolderCredentialError: Error {
    case emptyPassword
    case keyDerivationFailed
}

/// Password envelopes persist independently of the encrypted filesystem.
/// The master password wraps a stable recovery key so rotation works for offline folders.
struct SecureFolderPasswordEnvelope: Codable {
    private static let rounds: UInt32 = 600_000
    private let salt: Data
    private let ciphertext: Data

    init(sealing secret: Data, password: String, context: Data) throws {
        var generator = SystemRandomNumberGenerator()
        let salt = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        let key = try Self.derive(password: password, salt: salt)
        guard let combined = try AES.GCM.seal(secret, using: key, authenticating: context).combined else {
            throw SecureFolderCredentialError.keyDerivationFailed
        }
        self.salt = salt
        self.ciphertext = combined
    }

    func open(password: String, context: Data) throws -> Data {
        let key = try Self.derive(password: password, salt: salt)
        return try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext), using: key, authenticating: context)
    }

    private static func derive(password: String, salt: Data) throws -> SymmetricKey {
        guard !password.isEmpty else { throw SecureFolderCredentialError.emptyPassword }
        let bytes = Array(password.utf8)
        var derived = Data(count: 32)
        let status = derived.withUnsafeMutableBytes { output in
            salt.withUnsafeBytes { saltBuffer in
                bytes.withUnsafeBytes { input in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        input.bindMemory(to: Int8.self).baseAddress, input.count,
                        saltBuffer.bindMemory(to: UInt8.self).baseAddress, saltBuffer.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds,
                        output.bindMemory(to: UInt8.self).baseAddress, output.count
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw SecureFolderCredentialError.keyDerivationFailed }
        return SymmetricKey(data: derived)
    }
}

struct SecureFolderMasterCredential: Codable {
    private static let context = Data("MyExplorer secure folder master v1".utf8)
    private let envelope: SecureFolderPasswordEnvelope

    init(password: String) throws {
        try self.init(key: SymmetricKey(size: .bits256), password: password)
    }

    private init(key: SymmetricKey, password: String) throws {
        envelope = try SecureFolderPasswordEnvelope(
            sealing: key.withUnsafeBytes { Data($0) }, password: password, context: Self.context
        )
    }

    func recoveryKey(password: String) throws -> SymmetricKey {
        SymmetricKey(data: try envelope.open(password: password, context: Self.context))
    }

    func changingPassword(from oldPassword: String, to newPassword: String) throws -> Self {
        try Self(key: recoveryKey(password: oldPassword), password: newPassword)
    }
}

struct SecureFolderCredentials: Codable {
    let id: UUID
    private let folder: SecureFolderPasswordEnvelope
    private let recovery: Data

    init(id: UUID, secret: Data, password: String, recoveryKey: SymmetricKey) throws {
        self.id = id
        folder = try SecureFolderPasswordEnvelope(
            sealing: secret, password: password, context: Self.context(id, slot: "folder")
        )
        guard let combined = try AES.GCM.seal(
            secret, using: recoveryKey, authenticating: Self.context(id, slot: "recovery")
        ).combined else {
            throw SecureFolderCredentialError.keyDerivationFailed
        }
        recovery = combined
    }

    func secret(password: String) throws -> Data {
        try folder.open(password: password, context: Self.context(id, slot: "folder"))
    }

    func secret(recoveryKey: SymmetricKey) throws -> Data {
        try AES.GCM.open(
            AES.GCM.SealedBox(combined: recovery), using: recoveryKey,
            authenticating: Self.context(id, slot: "recovery")
        )
    }

    func resettingPassword(to newPassword: String, recoveryKey: SymmetricKey) throws -> Self {
        try Self(id: id, secret: secret(recoveryKey: recoveryKey), password: newPassword, recoveryKey: recoveryKey)
    }

    private static func context(_ id: UUID, slot: String) -> Data {
        Data("MyExplorer secure folder v1/\(id.uuidString)/\(slot)".utf8)
    }
}
