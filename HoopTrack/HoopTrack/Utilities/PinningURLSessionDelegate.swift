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
/// **Deliberately not wired in** (Nov 2026). `*.supabase.co` is served
/// through Cloudflare, whose certificates renew about every 90 days and may
/// switch CA (Let's Encrypt, Google Trust Services, SSL.com) without
/// notice. Any pin set short of every possible root would eventually lock
/// every user out until an app update. iOS already enforces TLS and a valid
/// chain (App Transport Security). If this is ever enabled, every client in
/// `SupabaseContainer` takes a `fetch:` handler; pass
/// `{ try await pinnedSession.data(for: $0) }`. See
/// `docs/production-readiness.md`.
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
        // Only server trust is ours to judge; anything else gets the default.
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard
            let serverTrust = challenge.protectionSpace.serverTrust,
            SecTrustEvaluateWithError(serverTrust, nil)
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Any certificate in the chain may carry the pin: the primary pin
        // is the intermediate, which the leaf-only check this replaced never
        // looked at (so the pins failed as soon as the leaf renewed).
        guard let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate] else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        if chain.contains(where: { Self.spkiHash(of: $0).map(Self.pinnedHashes.contains) ?? false }) {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    // MARK: - SPKI

    /// Base64 SHA-256 of the certificate's SubjectPublicKeyInfo, matching
    /// `openssl x509 -pubkey | openssl pkey -pubin -outform der | sha256`.
    /// Security.framework returns the bare key, so the ASN.1 header for its
    /// type and size goes back on first. Nil for key types not listed.
    static func spkiHash(of certificate: SecCertificate) -> String? {
        guard let key = SecCertificateCopyKey(certificate),
              let attributes = SecKeyCopyAttributes(key) as? [CFString: Any],
              let type = attributes[kSecAttrKeyType] as? String,
              let bits = attributes[kSecAttrKeySizeInBits] as? Int,
              let header = spkiHeader(type: type, bits: bits),
              let raw = SecKeyCopyExternalRepresentation(key, nil) as Data? else { return nil }
        return Data(SHA256.hash(data: header + raw)).base64EncodedString()
    }

    private static func spkiHeader(type: String, bits: Int) -> Data? {
        switch (type, bits) {
        case (kSecAttrKeyTypeECSECPrimeRandom as String, 256):
            return Data([0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
                         0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00])
        case (kSecAttrKeyTypeECSECPrimeRandom as String, 384):
            return Data([0x30, 0x76, 0x30, 0x10, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
                         0x06, 0x05, 0x2B, 0x81, 0x04, 0x00, 0x22, 0x03, 0x62, 0x00])
        case (kSecAttrKeyTypeRSA as String, 2048):
            return Data([0x30, 0x82, 0x01, 0x22, 0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7,
                         0x0D, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x01, 0x0F, 0x00])
        case (kSecAttrKeyTypeRSA as String, 4096):
            return Data([0x30, 0x82, 0x02, 0x22, 0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7,
                         0x0D, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x02, 0x0F, 0x00])
        default:
            return nil
        }
    }
}
