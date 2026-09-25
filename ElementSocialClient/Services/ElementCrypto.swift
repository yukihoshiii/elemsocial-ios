import Foundation
import Security
import CommonCrypto
import CryptoKit

enum CryptoError: LocalizedError {
    case keyGeneration
    case keyExport
    case invalidPEM
    case rsaEncrypt
    case rsaDecrypt
    case aesEncrypt
    case aesDecrypt
    case random

    var errorDescription: String? {
        switch self {
        case .keyGeneration: return "Ошибка генерации RSA ключей"
        case .keyExport: return "Ошибка экспорта RSA ключа"
        case .invalidPEM: return "Некорректный PEM ключ"
        case .rsaEncrypt: return "Ошибка RSA шифрования"
        case .rsaDecrypt: return "Ошибка RSA расшифровки"
        case .aesEncrypt: return "Ошибка AES шифрования"
        case .aesDecrypt: return "Ошибка AES расшифровки"
        case .random: return "Ошибка генерации случайных байтов"
        }
    }
}

struct RSAKeyMaterial {
    let publicKeyPEM: String
    let privateKey: SecKey
}

enum ElementCrypto {
    static func generateRSAKeyMaterial() throws -> RSAKeyMaterial {
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048
        ]

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attrs as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw CryptoError.keyGeneration
        }

        guard let publicRaw = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw CryptoError.keyExport
        }

        let spki = wrapRSAPublicKeyToSPKI(publicRaw)
        let pem = pemString(from: spki, type: "PUBLIC KEY")

        return RSAKeyMaterial(publicKeyPEM: pem, privateKey: privateKey)
    }

    static func generateAESKeyBase64() throws -> String {
        var key = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, key.count, &key)
        guard status == errSecSuccess else { throw CryptoError.random }
        return Data(key).base64EncodedString()
    }

    static func rsaEncrypt(_ data: Data, publicKeyPEM: String) throws -> Data {
        let keyData = try derData(fromPEM: publicKeyPEM)
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 2048
        ]

        var error: Unmanaged<CFError>?
        guard let publicKey = SecKeyCreateWithData(keyData as CFData, attrs as CFDictionary, &error) else {
            throw CryptoError.invalidPEM
        }

        guard let encrypted = SecKeyCreateEncryptedData(publicKey, .rsaEncryptionOAEPSHA256, data as CFData, &error) as Data? else {
            throw CryptoError.rsaEncrypt
        }
        return encrypted
    }

    static func rsaDecrypt(_ data: Data, privateKey: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let decrypted = SecKeyCreateDecryptedData(privateKey, .rsaEncryptionOAEPSHA256, data as CFData, &error) as Data? else {
            throw CryptoError.rsaDecrypt
        }
        return decrypted
    }

    static func aesEncryptCBC(_ plain: Data, keyBase64: String) throws -> Data {
        let key = try decodeKey(base64: keyBase64)
        var iv = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
        guard SecRandomCopyBytes(kSecRandomDefault, iv.count, &iv) == errSecSuccess else {
            throw CryptoError.random
        }

        let encrypted = try crypt(operation: CCOperation(kCCEncrypt), input: plain, key: key, iv: Data(iv))
        return Data(iv) + encrypted
    }

    static func aesDecryptCBC(_ encryptedWithIV: Data, keyBase64: String) throws -> Data {
        guard encryptedWithIV.count >= kCCBlockSizeAES128 else { throw CryptoError.aesDecrypt }
        let key = try decodeKey(base64: keyBase64)
        let iv = encryptedWithIV.prefix(kCCBlockSizeAES128)
        let encrypted = encryptedWithIV.dropFirst(kCCBlockSizeAES128)
        return try crypt(operation: CCOperation(kCCDecrypt), input: Data(encrypted), key: key, iv: Data(iv))
    }

    /// Same as web `aesCreateKeyFromWord` — SHA-256 hex, first 32 chars.
    static func aesKeyFromWord(_ word: String) -> String {
        let digest = SHA256.hash(data: Data(word.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(32))
    }

    /// Decrypt messenger message blob using server keyword (32 UTF-8 bytes).
    static func aesDecryptMessengerPayload(_ encryptedWithIV: Data, keyword: String) throws -> Data {
        // Replicate Javascript's `Uint8Array.from(keyword)` bug:
        // Any character that cannot be parsed as a base-10 digit (NaN) becomes 0.
        var keyBytes = [UInt8]()
        for char in keyword {
            if let digit = Int(String(char)) {
                keyBytes.append(UInt8(digit))
            } else {
                keyBytes.append(0)
            }
        }
        let key = Data(keyBytes)

        guard key.count == 32, encryptedWithIV.count >= kCCBlockSizeAES128 else {
            throw CryptoError.aesDecrypt
        }
        let iv = encryptedWithIV.prefix(kCCBlockSizeAES128)
        let encrypted = encryptedWithIV.dropFirst(kCCBlockSizeAES128)
        return try crypt(operation: CCOperation(kCCDecrypt), input: Data(encrypted), key: key, iv: Data(iv))
    }

    static func aesDecryptFile(_ encrypted: Data, keyBase64: String, ivBase64: String) throws -> Data {
        guard let key = Data(base64Encoded: keyBase64),
              let iv = Data(base64Encoded: ivBase64),
              key.count == 32,
              iv.count == kCCBlockSizeAES128 else {
            throw CryptoError.aesDecrypt
        }
        return try crypt(operation: CCOperation(kCCDecrypt), input: encrypted, key: key, iv: iv)
    }

    private static func decodeKey(base64: String) throws -> Data {
        guard let key = Data(base64Encoded: base64), key.count == 32 else {
            throw CryptoError.aesDecrypt
        }
        return key
    }

    private static func crypt(operation: CCOperation, input: Data, key: Data, iv: Data) throws -> Data {
        var outLength: size_t = 0
        var outData = Data(count: input.count + kCCBlockSizeAES128)
        let outCapacity = outData.count

        let status = outData.withUnsafeMutableBytes { outBytes in
            input.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            inBytes.baseAddress,
                            input.count,
                            outBytes.baseAddress,
                            outCapacity,
                            &outLength
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else {
            throw operation == CCOperation(kCCEncrypt) ? CryptoError.aesEncrypt : CryptoError.aesDecrypt
        }

        outData.removeSubrange(outLength..<outData.count)
        return outData
    }

    private static func pemString(from der: Data, type: String) -> String {
        let base64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN \(type)-----\n\(base64)-----END \(type)-----"
    }

    private static func derData(fromPEM pem: String) throws -> Data {
        let base64 = pem
            .replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = Data(base64Encoded: base64) else {
            throw CryptoError.invalidPEM
        }
        return data
    }

    // Wrap PKCS#1 RSA public key into SPKI sequence, same format as WebCrypto exportKey('spki').
    private static func wrapRSAPublicKeyToSPKI(_ pkcs1Key: Data) -> Data {
        let algorithmIdentifier: [UInt8] = [
            0x30, 0x0d,
            0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01,
            0x05, 0x00
        ]

        let bitStringPrefix: [UInt8] = [0x03] + derLength(pkcs1Key.count + 1) + [0x00]
        let bitString = Data(bitStringPrefix) + pkcs1Key

        let sequenceContent = Data(algorithmIdentifier) + bitString
        let sequencePrefix: [UInt8] = [0x30] + derLength(sequenceContent.count)
        return Data(sequencePrefix) + sequenceContent
    }

    private static func derLength(_ length: Int) -> [UInt8] {
        if length < 0x80 {
            return [UInt8(length)]
        }

        var value = length
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xff), at: 0)
            value >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }
}
