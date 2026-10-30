#if canImport(CommonCrypto) && canImport(CryptoKit)
import CommonCrypto
import CryptoKit
import Foundation

/// sphinx-ios-v2's `SymmetricEncryptionManager`: RNCryptor v3 with the push
/// key as the password (PBKDF2-HMAC-SHA1 ×10,000, AES-256-CBC, HMAC-SHA256),
/// the sealed bytes as base64. The same scheme as PeelCore's `MediaCrypto`,
/// kept here so the notification extension needs no PeelCore.
public struct RNCryptorSealer: PushSealing {
    public enum Failure: Error, Equatable { case malformed, wrongKey, cipher(Int32) }

    private static let rounds: UInt32 = 10_000
    private static let headerSize = 2 + 8 + 8 + 16
    private static let macSize = 32

    public init() {}

    public func seal(_ text: String, key: String) throws -> String {
        let encryptionSalt = Self.randomBytes(8), macSalt = Self.randomBytes(8), iv = Self.randomBytes(16)
        var sealed = Data([3, 1])
        sealed.append(encryptionSalt)
        sealed.append(macSalt)
        sealed.append(iv)
        sealed.append(try Self.aes(CCOperation(kCCEncrypt), Data(text.utf8), key: Self.derive(key, salt: encryptionSalt), iv: iv))
        sealed.append(Data(HMAC<SHA256>.authenticationCode(for: sealed, using: Self.derive(key, salt: macSalt))))
        return sealed.base64EncodedString()
    }

    public func open(_ sealed: String, key: String) throws -> String {
        guard let data = Data(base64Encoded: sealed) else { throw Failure.malformed }
        let bytes = Data(data)
        guard bytes.count >= Self.headerSize + 16 + Self.macSize, bytes[0] == 3, bytes[1] == 1 else { throw Failure.malformed }
        let encryptionSalt = bytes[2..<10], macSalt = bytes[10..<18], iv = bytes[18..<34]
        let message = bytes[..<(bytes.count - Self.macSize)]
        let mac = bytes[(bytes.count - Self.macSize)...]
        guard HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: message, using: Self.derive(key, salt: Data(macSalt)))
        else { throw Failure.wrongKey }
        let plain = try Self.aes(
            CCOperation(kCCDecrypt), Data(bytes[Self.headerSize..<(bytes.count - Self.macSize)]),
            key: Self.derive(key, salt: Data(encryptionSalt)), iv: Data(iv))
        guard let text = String(data: plain, encoding: .utf8) else { throw Failure.malformed }
        return text
    }

    private static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    private static func derive(_ password: String, salt: Data) -> SymmetricKey {
        let passwordBytes = Array(password.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBuffer in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes.map { CChar(bitPattern: $0) }, passwordBytes.count,
                saltBuffer.bindMemory(to: UInt8.self).baseAddress, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), rounds, &derived, derived.count
            )
        }
        precondition(status == kCCSuccess, "PBKDF2 cannot fail with these parameters")
        return SymmetricKey(data: derived)
    }

    private static func aes(_ operation: CCOperation, _ input: Data, key: SymmetricKey, iv: Data) throws -> Data {
        var output = Data(count: input.count + kCCBlockSizeAES128)
        var written = 0
        let status = key.withUnsafeBytes { keyBuffer in
            iv.withUnsafeBytes { ivBuffer in
                input.withUnsafeBytes { inputBuffer in
                    output.withUnsafeMutableBytes { outputBuffer in
                        CCCrypt(
                            operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyBuffer.baseAddress, keyBuffer.count, ivBuffer.baseAddress,
                            inputBuffer.baseAddress, inputBuffer.count,
                            outputBuffer.baseAddress, outputBuffer.count, &written
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw operation == CCOperation(kCCDecrypt) ? Failure.wrongKey : Failure.cipher(status)
        }
        output.count = written
        return output
    }
}
#endif
