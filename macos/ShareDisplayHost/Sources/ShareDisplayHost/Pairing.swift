import CryptoKit
import Foundation

enum Pairing {
    static func generateToken() -> String {
        let raw = (0..<6).map { _ in Int.random(in: 0...9) }
        return raw.map(String.init).joined()
    }

    static func hashToken(_ token: String) -> String {
        let data = Data(token.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
