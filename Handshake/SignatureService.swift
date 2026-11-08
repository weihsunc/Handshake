import Foundation
import CryptoKit
import LocalAuthentication
import UIKit

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - SignatureService
//
// iOS never exposes biometric data — LocalAuthentication returns pass/fail and
// nothing else. So a "face signature" here is two things together:
//
//     Face ID authentication success
//   + SHA256(signer name + contract id + timestamp + device id)
//
// That gives authentication and tamper-evidence. It does NOT give an
// independent chain of custody, so it is not a compliance-grade signature —
// see HANDOFF §8, and keep "legally binding" out of any UI copy.
// ─────────────────────────────────────────────────────────────────────────────

enum SignatureError: LocalizedError {
    case biometricsUnavailable(String)
    case authenticationFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .biometricsUnavailable(let why): return why
        case .authenticationFailed(let why):  return why
        case .cancelled:                      return nil   // user backed out; say nothing
        }
    }
}

/// The record produced by a successful signing.
struct SignatureStamp {
    let signerName: String
    let signedAt:   Date
    let hash:       String
    /// What confirmed it, for the badge. nil reads "Face ID" (older records).
    var method:     String? = nil

    /// First 12 hex characters, grouped — enough to eyeball, short enough to fit.
    var fingerprint: String {
        let short = String(hash.prefix(12)).uppercased()
        return stride(from: 0, to: short.count, by: 4)
            .map { i -> String in
                let start = short.index(short.startIndex, offsetBy: i)
                let end   = short.index(start, offsetBy: min(4, short.count - i))
                return String(short[start..<end])
            }
            .joined(separator: " ")
    }

    var isoTimestamp: String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: signedAt)
    }
}

enum SignatureService {

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Face ID
    // ─────────────────────────────────────────────────────────────────────────

    /// "Face ID", "Touch ID" or "Optic ID" — whatever this device has, so the
    /// button and the confirmation don't promise Face ID on a Touch ID phone.
    static var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .touchID: return String(localized: "Touch ID")
        case .opticID: return String(localized: "Optic ID")
        default:       return String(localized: "Face ID")
        }
    }

    /// Prompts for Face ID (or Touch ID) and returns only on success.
    static func authenticate(reason: String) async throws {
        let context = LAContext()
        context.localizedCancelTitle = String(localized: "Cancel")

        var probeError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                        error: &probeError) else {
            throw SignatureError.biometricsUnavailable(
                probeError?.localizedDescription
                ?? String(localized: "Face ID isn't set up on this device.")
            )
        }

        do {
            let ok = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )
            guard ok else { throw SignatureError.authenticationFailed(String(localized: "Face ID didn't match.")) }
        } catch let err as LAError {
            switch err.code {
            case .userCancel, .appCancel, .systemCancel:
                throw SignatureError.cancelled
            default:
                throw SignatureError.authenticationFailed(err.localizedDescription)
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Cryptographic stamp
    // ─────────────────────────────────────────────────────────────────────────

    /// SHA256 over signer name + contract id + timestamp + device id.
    /// Call only after `authenticate` has succeeded.
    static func stamp(signerName: String,
                      contractID: UUID,
                      signedAt: Date = .now) -> SignatureStamp {

        let deviceID = UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device"
        let iso      = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        // Field separator keeps the components unambiguous — without it,
        // ("ab", "c") and ("a", "bc") would hash identically.
        let payload = [
            signerName,
            contractID.uuidString,
            iso.string(from: signedAt),
            deviceID
        ].joined(separator: "\u{001F}")

        let digest = SHA256.hash(data: Data(payload.utf8))
        let hex    = digest.map { String(format: "%02x", $0) }.joined()

        return SignatureStamp(signerName: signerName, signedAt: signedAt, hash: hex)
    }
}
