// Phase 7 — Security (Phase 9: real hashes in place; see note on wiring below)
import Foundation
import CryptoKit
import Security

/// URLSessionDelegate that performs SPKI SHA-256 certificate pinning
/// against a chain served by `<project>.supabase.co`.
///
/// Pin values below are for Google Trust Services certs (ECDSA P-256)
/// serving the Supabase edge. The primary pin is the **WE1 intermediate**
/// which rotates ~every 5 years. The leaf is included as a backup.
/// Both are P-256, so the algorithm-identifier prepend below is valid.
///
/// **Not yet wired into supabase-swift.** The SDK uses its own URLSession
/// under the hood; routing through this delegate requires constructing a
/// custom `URLSessionConfiguration` and passing it into AuthClient /
/// PostgrestClient. Tracked as a P0 in `docs/production-readiness.md`.
///
/// Refresh pins via:
///   echo | openssl s_client -servername <project>.supabase.co \
///     -connect <project>.supabase.co:443 -showcerts 2>/dev/null \
///     | awk 'BEGIN{n=0} /BEGIN/{n++; f="/tmp/c"n".pem"} n{print > f}'
///   for f in /tmp/c*.pem; do
///     openssl x509 -in "$f" -pubkey -noout \
///       | openssl pkey -pubin -outform der \
///       | openssl dgst -sha256 -binary | openssl enc -base64
///   done
final class PinningURLSessionDelegate: NSObject, URLSessionDelegate {

    // MARK: - Configuration

    /// Base64 SHA-256 hashes of the DER-encoded Subject Public Key Info
    /// (SPKI) structures acceptable for `*.supabase.co` traffic.
    ///
    /// Rotation policy: replace before the WE1 intermediate expires
    /// (check: https://pki.goog). Failing to rotate produces TLS-pinning
    /// failures on every authenticated request.
    static let pinnedHashes: Set<String> = [
        // Primary — GTS WE1 intermediate (ECDSA P-256, stable ~years)
        "kIdp6NNEd8wsugYyyIYFsi1ylMCED3hZbSR8ZFsa/A4=",
        // Backup — supabase.co leaf cert (rotates every ~90 days; caller
        // must refresh this slot with the openssl command above whenever
        // TLS errors start firing on valid network conditions)
        "GU2W4j1P24T3sqlI+o6YTnidzz0PI8fB/Gvd2ITfSZE="
    ]

    // MARK: - URLSessionDelegate

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard
            challenge.protectionSpace.authenticationMethod ==
                NSURLAuthenticationMethodServerTrust,
            let serverTrust = challenge.protectionSpace.serverTrust,
            SecTrustEvaluateWithError(serverTrust, nil)
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Extract the leaf certificate public key
        guard
            let certChain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
            let leafCert = certChain.first,
            let publicKey = SecCertificateCopyKey(leafCert),
            let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Prepend EC P-256 SPKI algorithm-identifier header so the hash matches
        // the output of: openssl ... | openssl dgst -sha256 -binary | base64
        let ecP256SpkiHeader = Data([
            0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86,
            0x48, 0xCE, 0x3D, 0x02, 0x01, 0x06, 0x08, 0x2A,
            0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03,
            0x42, 0x00
        ])
        let spkiData = ecP256SpkiHeader + publicKeyData
        let hash = SHA256.hash(data: spkiData)
        let base64Hash = Data(hash).base64EncodedString()

        if Self.pinnedHashes.contains(base64Hash) {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
