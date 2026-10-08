import CommonCrypto
import CryptoKit
import Foundation

/// The official apps' attachment encryption: RNCryptor v3 with a password.
/// The password is the media key, 64 hex characters.
enum MediaCrypto {
    enum Failure: Error, CustomStringConvertible {
        case malformed
        case wrongKey
        case cipher(Int32)

        var description: String {
            switch self {
            case .malformed: "the attachment is not in the expected encrypted format"
            case .wrongKey: "the attachment could not be decrypted with its key"
            case .cipher(let status): "the attachment cipher failed (\(status))"
            }
        }
    }

    private static let rounds: UInt32 = 10_000
    private static let headerSize = 2 + 8 + 8 + 16
    private static let macSize = 32

    /// 32 random letters and digits, hex-encoded, as the Mac app's `Nonce(length: 32).hexString`.
    static func newKey() -> String {
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in alphabet.randomElement(using: &generator)! }.hex
    }

    static func encrypt(_ plain: Data, key: String) throws -> Data {
        let encryptionSalt = randomBytes(8), macSalt = randomBytes(8), iv = randomBytes(16)
        var sealed = Data(capacity: headerSize + plain.count + kCCBlockSizeAES128 + macSize)
        sealed.append(contentsOf: [3, 1])
        sealed.append(encryptionSalt)
        sealed.append(macSalt)
        sealed.append(iv)
        sealed.append(try aes(CCOperation(kCCEncrypt), plain, key: derive(key, salt: encryptionSalt), iv: iv))
        sealed.append(Data(HMAC<SHA256>.authenticationCode(for: sealed, using: derive(key, salt: macSalt))))
        return sealed
    }

    static func decrypt(_ sealed: Data, key: String) throws -> Data {
        // Indexes below count from zero; only a slice needs rebasing.
        let bytes = sealed.startIndex == 0 ? sealed : Data(sealed)
        guard bytes.count >= headerSize + 16 + macSize, bytes[0] == 3, bytes[1] == 1 else { throw Failure.malformed }
        let encryptionSalt = bytes[2..<10], macSalt = bytes[10..<18], iv = bytes[18..<34]
        let message = bytes[..<(bytes.count - macSize)]
        let mac = bytes[(bytes.count - macSize)...]
        guard HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: message, using: derive(key, salt: macSalt))
        else { throw Failure.wrongKey }
        return try aes(CCOperation(kCCDecrypt), bytes[headerSize..<(bytes.count - macSize)],
                       key: derive(key, salt: encryptionSalt), iv: iv)
    }

    private static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    /// PBKDF2-HMAC-SHA1 over the password's UTF-8 bytes, 32 bytes out.
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

    /// AES-256-CBC with PKCS#7 padding.
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
