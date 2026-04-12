// Phase 7 — Security (wired to URLSession in Phase 9)
import Foundation
import CryptoKit
import Security

/// URLSessionDelegate that performs SPKI SHA-256 certificate pinning.
/// Pin the Supabase/Cloudflare root CA public key, not the leaf cert.
///
/// How to obtain the SPKI hash for a host:
///   openssl s_client -connect <host>:443 | openssl x509 -pubkey -noout \
///     | openssl pkey -pubin -outform DER \
///     | openssl dgst -sha256 -binary | base64
///
/// The placeholder value below MUST be replaced with the real hash before Phase 9 ships.
final class PinningURLSessionDelegate: NSObject, URLSessionDelegate {

    // MARK: - Configuration

    /// Base64-encoded SHA-256 hashes of acceptable SPKI DER public keys.
    /// Replace with real hashes before Phase 9.
    static let pinnedHashes: Set<String> = [
        "PLACEHOLDER_REPLACE_BEFORE_PHASE9_supabase_spki_sha256"
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
            let leafCert = SecTrustGetCertificateAtIndex(serverTrust, 0),
            let publicKey = SecCertificateCopyKey(leafCert),
            let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // SHA-256 hash the raw SPKI DER bytes
        let hash = SHA256.hash(data: publicKeyData)
        let base64Hash = Data(hash).base64EncodedString()

        if Self.pinnedHashes.contains(base64Hash) {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
