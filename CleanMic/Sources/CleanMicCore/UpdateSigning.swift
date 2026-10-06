import CryptoKit
import Foundation

/// Potpis izdanja za automatsko ažuriranje (Ed25519).
///
/// Zašto: aplikacija nije potpisana Apple Developer ID-om, pa macOS ne može reći da je novi
/// DMG zaista naš. Bez ovoga bi svako ko dobije pristup GitHub nalogu mogao ubaciti kod koji se
/// sam pokrene na svakom Macu sa CleanMic-om. Sa potpisom aplikacija instalira samo ono što je
/// potpisano privatnim ključem koji postoji samo na Macu na kojem se prave izdanja.
///
/// Potpisuje se SHA-256 DMG-a zajedno sa verzijom, pa se stariji (ispravno potpisan) DMG ne može
/// podmetnuti kao novija verzija.
public enum UpdateSigning {
    /// Javni ključ (base64, 32 bajta). Ugrađen u aplikaciju; privatni ključ nikad nije u repou.
    public static let publicKeyBase64 = "6wtgl47o7QEXatuQapih1pX/rREbFSGBv1NYMgoL2Pk="

    public enum SigningError: Error, CustomStringConvertible {
        case badKey
        case badSignature
        case mismatch

        public var description: String {
            switch self {
            case .badKey: return "Neispravan ključ za potpis."
            case .badSignature: return "Potpis izdanja je neispravan."
            case .mismatch: return "Potpis izdanja se ne poklapa sa preuzetim fajlom — ne instaliram."
            }
        }
    }

    /// Gdje se čuva privatni ključ (samo na Macu koji pravi izdanja).
    public static var privateKeyURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cleanmic/update_signing_key")
    }

    public static func generateKeyPair() -> (privateBase64: String, publicBase64: String) {
        let key = Curve25519.Signing.PrivateKey()
        return (key.rawRepresentation.base64EncodedString(), key.publicKey.rawRepresentation.base64EncodedString())
    }

    static func message(version: String, sha256Hex: String) -> Data {
        Data("cleanmic-update-v1|\(version)|\(sha256Hex)".utf8)
    }

    /// SHA-256 fajla, bez učitavanja cijelog u memoriju.
    public static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func sign(dmg: URL, version: String, privateKeyBase64: String) throws -> String {
        guard let raw = Data(base64Encoded: privateKeyBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { throw SigningError.badKey }
        let digest = try sha256Hex(of: dmg)
        let signature = try key.signature(for: message(version: version, sha256Hex: digest))
        return signature.base64EncodedString()
    }

    public static func verify(dmg: URL, version: String, signatureBase64: String,
                              publicKeyBase64: String = UpdateSigning.publicKeyBase64) throws {
        guard let rawKey = Data(base64Encoded: publicKeyBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKey) else { throw SigningError.badKey }
        guard let signature = Data(base64Encoded: signatureBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
              signature.count == 64 else { throw SigningError.badSignature }
        let digest = try sha256Hex(of: dmg)
        guard key.isValidSignature(signature, for: message(version: version, sha256Hex: digest)) else {
            throw SigningError.mismatch
        }
    }
}
