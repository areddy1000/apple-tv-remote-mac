import CryptoKit
import Foundation

/// HKDF-SHA512 with string salt and info, as HAP uses it.
enum HAPKDF {
    /// Derives a key of `length` bytes from `secret`.
    static func derive(secret: Data, salt: String, info: String, length: Int = 32) -> SymmetricKey {
        HKDF<SHA512>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: Data(salt.utf8),
            info: Data(info.utf8),
            outputByteCount: length
        )
    }

    /// Returns the raw bytes of a symmetric key.
    static func bytes(of key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }
}
