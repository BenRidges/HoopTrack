# HoopTrack — Security Hardening Plan

**Date:** 2026-04-12  
**Priority:** HIGH  
**Phase context:** Pre-backend introduction; all security foundations must be in place before the first network request is made.

---

## Table of Contents

1. [Security Audit — Current Attack Surface](#1-security-audit--current-attack-surface)
2. [Keychain Implementation](#2-keychain-implementation)
3. [App Transport Security](#3-app-transport-security)
4. [Certificate Pinning](#4-certificate-pinning)
5. [Data Encryption at Rest](#5-data-encryption-at-rest)
6. [Privacy Manifest (PrivacyInfo.xcprivacy)](#6-privacy-manifest-privacyinfoxcprivacy)
7. [Privacy Nutrition Labels](#7-privacy-nutrition-labels)
8. [Input Validation and API Security](#8-input-validation-and-api-security)
9. [GDPR and Privacy Compliance](#9-gdpr-and-privacy-compliance)
10. [Security Testing Checklist](#10-security-testing-checklist)
11. [Incident Response](#11-incident-response)

---

## 1. Security Audit — Current Attack Surface

### 1.1 Data Inventory

| Asset | Location | Sensitivity | Current Protection |
|---|---|---|---|
| `PlayerProfile` (name, skill ratings, career stats, PRs) | SwiftData store (`default.store`) in app sandbox | Medium | iOS sandboxing + default Data Protection class |
| `TrainingSession` records (timestamps, location tags, court type, notes) | SwiftData store | Medium | iOS sandboxing + default Data Protection class |
| `ShotRecord` records (coordinates, release angle, biomechanics) | SwiftData store | Medium–High (health/fitness data) | iOS sandboxing + default Data Protection class |
| `GoalRecord` records | SwiftData store | Low | iOS sandboxing |
| Session videos | `Documents/Sessions/<uuid>.mov` | High (contains video of user's body) | **None beyond sandboxing — no explicit file protection class set** |
| Player name | `PlayerProfile.name` in SwiftData | Low–Medium | iOS sandboxing |
| `locationTag` (freeform strings like "Home Gym") | `TrainingSession.locationTag` | Medium (reveals frequented locations) | iOS sandboxing |

### 1.2 Current State Assessment

**What is currently safe:**
- All data is local-only; no network requests means no in-transit interception risk today.
- The iOS sandbox prevents other apps from reading HoopTrack data.
- SwiftData uses the default file protection class (`NSFileProtectionCompleteUntilFirstUserAuthentication`), which protects data while the device is off but leaves it accessible after first unlock — adequate for background app refresh, but not the strongest available.

**Critical gaps — must be fixed before backend introduction:**

1. **Session videos have no explicit file protection class.** A file written to `Documents/Sessions/` via `VideoRecordingService` inherits the directory's protection class (default: `.completeUntilFirstUserAuthentication`). Videos containing the user's body and face should be protected at `.complete`, which requires a lock to access.

2. **No `KeychainService` exists.** Once auth tokens are needed (Supabase JWT, refresh token, user ID), there is nowhere safe to store them. This must be built before the first auth flow.

3. **No `Info.plist` ATS configuration is explicit.** The default ATS policy allows HTTPS and blocks HTTP, but does not actively prevent accidental `NSAllowsArbitraryLoads` inclusion by a future developer or third-party SDK.

4. **No Privacy manifest (`PrivacyInfo.xcprivacy`) exists.** Required since iOS 17 for App Store submission. The app uses `AVCaptureSession`, Vision framework pose detection, and file system APIs — all of which require declared reasons.

5. **No certificate pinning infrastructure.** Once `URLSession` is used for Supabase calls, there is no defense against MITM attacks by default. Pinning must be implemented from the first network call.

6. **`locationTag` is a freeform string.** When synced to a backend, this leaks frequented location names unless sanitised or treated as sensitive.

### 1.3 Post-Backend Expanded Attack Surface

When Supabase is introduced, the attack surface expands to include:

- **Auth tokens (JWT + refresh token):** Stolen tokens allow full account takeover. Must live in Keychain only.
- **Supabase project URL + anon key:** The anon key is not secret (Row Level Security enforces access), but the project URL should not be hardcoded in plain text — use a configuration file excluded from source control.
- **Network traffic:** Shot records, session data, and potentially video upload URLs transmitted over the network. All traffic must be HTTPS. Certificate pinning prevents MITM on jailbroken devices.
- **Server-side injection:** `locationTag`, `notes`, and player name will become API payloads. They require input validation and length limits to prevent injection attacks.
- **Video upload presigned URLs:** Time-limited, but must be served over HTTPS and generated server-side, not client-side.

---

## 2. Keychain Implementation

### 2.1 Design

Create a `KeychainService` singleton backed by the iOS `Security` framework. It must be:
- Framework-independent (no third-party libraries — consistent with the no-dependency policy).
- Typed: separate methods for `String`, `Data`, and `Codable` payloads.
- Actor-safe: since `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, Keychain operations (which are synchronous and fast) can safely run on `@MainActor`.

**What goes in the Keychain:**

| Key | Value | Access control |
|---|---|---|
| `hooptrack.auth.accessToken` | Supabase JWT string | `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` |
| `hooptrack.auth.refreshToken` | Supabase refresh token string | `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` |
| `hooptrack.auth.userID` | Supabase user UUID string | `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` |
| `hooptrack.biometric.localAuthToken` | Short-lived re-auth token for biometric unlock | `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` + `biometricAny` ACL |

**What must NEVER go in `UserDefaults`:** auth tokens, user ID, refresh tokens.

**What may stay in `UserDefaults`/SwiftData:** UI preferences, feature flags, non-credential settings.

### 2.2 Implementation

Create `HoopTrack/Services/KeychainService.swift`:

```swift
// KeychainService.swift
// Secure storage for credentials and sensitive preferences.
// Uses the Security framework directly — no third-party dependencies.

import Foundation
import Security

enum KeychainError: LocalizedError {
    case encodingFailed
    case itemNotFound
    case duplicateItem
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:         return "Keychain: failed to encode value."
        case .itemNotFound:           return "Keychain: item not found."
        case .duplicateItem:          return "Keychain: item already exists."
        case .unexpectedStatus(let s): return "Keychain: unexpected OSStatus \(s)."
        }
    }
}

@MainActor
final class KeychainService {

    static let shared = KeychainService()
    private init() {}

    // MARK: - String API

    func save(_ value: String, forKey key: String) throws {
        guard let data = value.data(using: .utf8) else { throw KeychainError.encodingFailed }
        try save(data, forKey: key)
    }

    func string(forKey key: String) throws -> String {
        let data = try data(forKey: key)
        guard let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.encodingFailed
        }
        return string
    }

    // MARK: - Data API

    func save(_ data: Data, forKey key: String) throws {
        let query: [CFString: Any] = [
            kSecClass:                 kSecClassGenericPassword,
            kSecAttrService:           HoopTrack.bundleID,
            kSecAttrAccount:           key,
            kSecValueData:             data,
            // Accessible after first device unlock — allows background token refresh.
            // ThisDeviceOnly prevents backup extraction to a different device.
            kSecAttrAccessible:        kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)

        if status == errSecDuplicateItem {
            // Update existing item
            let updateQuery: [CFString: Any] = [
                kSecClass:       kSecClassGenericPassword,
                kSecAttrService: HoopTrack.bundleID,
                kSecAttrAccount: key
            ]
            let attributes: [CFString: Any] = [kSecValueData: data]
            let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(updateStatus)
            }
        } else if status != errSecSuccess {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func data(forKey key: String) throws -> Data {
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      HoopTrack.bundleID,
            kSecAttrAccount:      key,
            kSecReturnData:       true,
            kSecMatchLimit:       kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status != errSecItemNotFound else { throw KeychainError.itemNotFound }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = item as? Data else { throw KeychainError.encodingFailed }
        return data
    }

    func delete(forKey key: String) throws {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: HoopTrack.bundleID,
            kSecAttrAccount: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func deleteAll() throws {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: HoopTrack.bundleID
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: - Biometric-protected item (for local re-authentication)

    /// Saves a value protected by both device passcode AND biometrics.
    /// Only use for high-sensitivity items that should require Face ID / Touch ID to read.
    func saveBiometricProtected(_ value: String, forKey key: String) throws {
        guard let data = value.data(using: .utf8) else { throw KeychainError.encodingFailed }

        var error: Unmanaged<CFError>?
        // kSecAccessControlBiometryAny: any enrolled biometric can unlock.
        // kSecAccessControlAnd: BOTH passcode AND biometry are required.
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            [.biometryAny, .or, .devicePasscode],
            &error
        ) else {
            throw error!.takeRetainedValue() as Error
        }

        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      HoopTrack.bundleID,
            kSecAttrAccount:      key,
            kSecValueData:        data,
            kSecAttrAccessControl: access
        ]

        // Delete first to avoid duplicate errors (access control items can't be updated)
        try? delete(forKey: key)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }
}
```

**Typed key constants** — add to `Constants.swift`:

```swift
// MARK: - Keychain Keys
enum KeychainKey {
    static let accessToken      = "hooptrack.auth.accessToken"
    static let refreshToken     = "hooptrack.auth.refreshToken"
    static let userID           = "hooptrack.auth.userID"
    static let biometricToken   = "hooptrack.biometric.localAuthToken"
}
```

### 2.3 Auth Service Integration Pattern

When `AuthService` is created for Supabase:

```swift
func signIn(email: String, password: String) async throws {
    let session = try await supabaseClient.auth.signIn(email: email, password: password)
    // Store in Keychain — NEVER in UserDefaults
    try KeychainService.shared.save(session.accessToken,  forKey: KeychainKey.accessToken)
    try KeychainService.shared.save(session.refreshToken, forKey: KeychainKey.refreshToken)
    try KeychainService.shared.save(session.user.id.uuidString, forKey: KeychainKey.userID)
}

func signOut() throws {
    try KeychainService.shared.deleteAll()
    // Also clear any cached profile data from memory
}
```

---

## 3. App Transport Security

### 3.1 Info.plist Configuration

ATS is enforced by default in iOS, but explicit configuration makes the policy auditable and prevents accidental weakening. Add the following to `Info.plist`:

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <!-- Explicitly forbid arbitrary loads — this is already the default
         but stating it explicitly prevents future accidental overrides. -->
    <key>NSAllowsArbitraryLoads</key>
    <false/>

    <!-- No exceptions for local networking unless specifically needed for
         development tooling (remove before production). -->

    <!-- All Supabase domains must use TLS 1.2+ (enforced by ATS default).
         No per-domain exceptions needed for Supabase. -->
</dict>
```

In the **production build**, confirm:
- `NSAllowsArbitraryLoads` is `false` (or absent — absent defaults to `false`)
- `NSAllowsArbitraryLoadsInWebContent` is absent or `false`
- `NSAllowsLocalNetworking` is absent (set only if a local development server is used during debugging)
- No `NSExceptionDomains` entries with `NSExceptionAllowsInsecureHTTPLoads: true`

### 3.2 ATS Exception Audit Process

Before each release:

1. Run `plutil -p HoopTrack/Info.plist | grep -A 20 NSAppTransportSecurity` and verify no `NSAllowsArbitraryLoads: true` entries exist.
2. If a new SDK or dependency is added in the future, audit its `Info.plist` for ATS exceptions — third-party frameworks can inject exceptions into the merged `Info.plist`.
3. Use Charles Proxy (see Section 10) to verify all traffic is HTTPS before shipping.

### 3.3 Required Domains

When Supabase is the backend, the following domains will be used:
- `<project-ref>.supabase.co` — REST API, Auth, Realtime
- `<project-ref>.supabase.in` — Storage (if using Supabase Storage for videos)

Both are served over HTTPS only. No ATS exceptions are needed or should be added.

---

## 4. Certificate Pinning

### 4.1 Why Pinning Matters for HoopTrack

On jailbroken devices, an attacker can install a custom root CA and perform a MITM attack against any HTTPS connection that trusts the system root store. Certificate pinning rejects connections where the server's certificate or public key does not match a pre-approved value, defeating this attack even on jailbroken hardware. Given that HoopTrack transmits health/fitness biometric data (release angles, vertical jump, body pose), pinning is warranted.

### 4.2 Pinning Strategy: SPKI Hash

Pin the **Subject Public Key Info (SPKI) hash** rather than the leaf certificate. Reasons:
- Leaf cert pinning breaks every time the cert is renewed (typically annually).
- SPKI hash remains stable as long as the same private key is used (controlled by the CA or CDN).
- Supabase uses AWS CloudFront for its API endpoints; the SPKI hash of the CloudFront intermediary CA is stable over longer periods.
- Always pin **two hashes**: the current key and a backup (the next planned key or the parent CA key). This enables zero-downtime key rotation.

### 4.3 Computing SPKI Hashes

```bash
# Extract SPKI hash from a live Supabase endpoint (run from Terminal)
# Replace <project-ref> with your actual Supabase project reference
openssl s_client -connect <project-ref>.supabase.co:443 2>/dev/null \
  | openssl x509 -noout -pubkey \
  | openssl pkey -pubin -outform DER \
  | openssl dgst -sha256 -binary \
  | base64
```

Run this command for each Supabase subdomain you will contact (`supabase.co`, `supabase.in`) and record the hashes. Also run it against the intermediate CA certificate.

### 4.4 URLSession Pinning Implementation

Create `HoopTrack/Services/PinningURLSessionDelegate.swift`:

```swift
// PinningURLSessionDelegate.swift
// Implements SPKI hash-based certificate pinning for all Supabase endpoints.
// A failed pin challenge causes the request to fail — the app should surface
// a generic "connection error" to the user (not the pinning detail).

import Foundation
import CryptoKit

final class PinningURLSessionDelegate: NSObject, URLSessionDelegate {

    // MARK: - Configuration

    /// Trusted SPKI SHA-256 hashes (base64-encoded).
    /// Always include at least 2: the current key and one backup key.
    /// Update these when rotating keys — ship a new app version at least
    /// 30 days before the old hash expires.
    private let trustedHashes: Set<String> = [
        // TODO: replace with actual hashes extracted from your Supabase project
        "PLACEHOLDER_PRIMARY_SPKI_HASH=",
        "PLACEHOLDER_BACKUP_SPKI_HASH="
    ]

    /// Domains to pin. Connections to other domains pass through without pinning.
    private let pinnedHosts: Set<String> = [
        // TODO: replace with your actual Supabase project reference
        "YOUR_PROJECT_REF.supabase.co",
        "YOUR_PROJECT_REF.supabase.in"
    ]

    // MARK: - URLSessionDelegate

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard
            challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let serverTrust = challenge.protectionSpace.serverTrust,
            pinnedHosts.contains(challenge.protectionSpace.host)
        else {
            // Not a server trust challenge or not a pinned host — use default handling.
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Evaluate the standard trust chain first. Reject if the chain itself is invalid.
        var error: CFError?
        guard SecTrustEvaluateWithError(serverTrust, &error) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Extract all certificates in the chain and check SPKI hashes.
        let certCount = SecTrustGetCertificateCount(serverTrust)
        var matchFound = false

        for index in 0..<certCount {
            guard
                let cert = SecTrustGetCertificateAtIndex(serverTrust, index),
                let spkiHash = spkiSHA256(for: cert)
            else { continue }

            if trustedHashes.contains(spkiHash) {
                matchFound = true
                break
            }
        }

        if matchFound {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            // Pinning failure — log to crash reporter (Sentry) but do NOT
            // expose pinning details to the user or in plain-text logs.
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    // MARK: - SPKI Hash Extraction

    /// Extracts the DER-encoded SubjectPublicKeyInfo from a certificate and
    /// returns its SHA-256 hash as a base64 string.
    private func spkiSHA256(for certificate: SecCertificate) -> String? {
        // SecCertificateCopyKey is iOS 14+, well within our iOS 16 minimum.
        guard let publicKey = SecCertificateCopyKey(certificate) else { return nil }

        var error: Unmanaged<CFError>?
        guard
            let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?
        else { return nil }

        // Prepend the ASN.1 SubjectPublicKeyInfo header for RSA-2048.
        // For EC keys the header differs — detect key type and prepend accordingly.
        let spkiData = prependSPKIHeader(to: publicKeyData, for: publicKey)
        let hash = SHA256.hash(data: spkiData)
        return Data(hash).base64EncodedString()
    }

    /// Prepends the correct ASN.1 SPKI header based on key type and size.
    private func prependSPKIHeader(to keyData: Data, for key: SecKey) -> Data {
        // RSA-2048 header (most common for HTTPS certificates)
        let rsa2048Header: [UInt8] = [
            0x30, 0x82, 0x01, 0x22, 0x30, 0x0d, 0x06, 0x09,
            0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01,
            0x01, 0x05, 0x00, 0x03, 0x82, 0x01, 0x0f, 0x00
        ]
        // EC P-256 header
        let ecP256Header: [UInt8] = [
            0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86,
            0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a,
            0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03,
            0x42, 0x00
        ]

        guard let attributes = SecKeyCopyAttributes(key) as? [CFString: Any],
              let keyType = attributes[kSecAttrKeyType] as? String else {
            return Data(rsa2048Header) + keyData
        }

        if keyType == (kSecAttrKeyTypeECSECPrimeRandom as String) {
            return Data(ecP256Header) + keyData
        } else {
            return Data(rsa2048Header) + keyData
        }
    }
}
```

### 4.5 Creating a Pinned URLSession

In the future `NetworkService` or `SupabaseClientFactory`:

```swift
// NetworkService.swift (to be created when backend is introduced)

import Foundation

@MainActor
final class NetworkService {

    static let shared = NetworkService()

    private let pinningDelegate = PinningURLSessionDelegate()

    /// All Supabase requests must use this session — never URLSession.shared.
    let pinnedSession: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest  = 30
        config.timeoutIntervalForResource = 60
        // Disable local caching for auth endpoints
        config.urlCache = nil
        self.pinnedSession = URLSession(
            configuration: config,
            delegate: pinningDelegate,
            delegateQueue: nil
        )
    }
}
```

### 4.6 Pin Rotation Process

1. **30 days before certificate renewal:** Compute the new SPKI hash and add it as the second entry in `trustedHashes`. Ship an app update.
2. **After the app update reaches the majority of users:** Rotate the certificate on the server. Both old and new hashes are trusted during the transition window.
3. **After the old cert has expired:** Remove the old hash from `trustedHashes`. Ship another app update.

For Supabase specifically: Supabase manages TLS certificates automatically via AWS Certificate Manager. If you need to pin, the more stable target is the **intermediate CA** (Amazon Root CA 1 or 3). Compute that hash and pin it — it is valid for the lifetime of Amazon's CA (years, not months).

If a forced migration is needed immediately (e.g. compromised key), use the server-side `min_app_version` enforcement pattern to force users onto the new pinned version.

---

## 5. Data Encryption at Rest

### 5.1 iOS File Data Protection Overview

iOS Data Protection encrypts files using per-file keys derived from the device passcode and the device's hardware key. The protection class determines when those keys are accessible:

| Class | Accessible when | Appropriate for |
|---|---|---|
| `.complete` | Device unlocked only | Session videos, exported data |
| `.completeUnlessOpen` | Device unlocked, OR file was open before lock | Files that must survive a lock during active use |
| `.completeUntilFirstUserAuthentication` | After first unlock after boot (default) | SwiftData store, background-accessible data |
| `.none` | Always | System files only — never use in apps |

### 5.2 Session Video Protection

`VideoRecordingService` writes to `Documents/Sessions/<uuid>.mov`. Apply `.complete` to the entire `Sessions/` directory so all new files inherit it:

```swift
// In VideoRecordingService.init() or a one-time setup call in HoopTrackApp

func configureSessionsDirectoryProtection() throws {
    let docs  = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let sessionsURL = docs.appendingPathComponent(HoopTrack.Storage.sessionVideoDirectory)

    // Create directory if needed
    try FileManager.default.createDirectory(
        at: sessionsURL,
        withIntermediateDirectories: true,
        attributes: [
            .protectionKey: FileProtectionType.complete
        ]
    )

    // If the directory already exists, update its protection class
    try (sessionsURL as NSURL).setResourceValue(
        URLFileProtection.complete,
        forKey: .fileProtectionKey
    )
}
```

> **Note:** Setting the protection class on a directory sets the *default* for new files created inside it. Existing files must be migrated individually if the directory's class is being upgraded. On first launch after adding this code, enumerate `Documents/Sessions/` and set `.complete` on each existing `.mov` file.

```swift
func migrateExistingVideosToCompleteProtection() throws {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let sessionsURL = docs.appendingPathComponent(HoopTrack.Storage.sessionVideoDirectory)

    guard FileManager.default.fileExists(atPath: sessionsURL.path) else { return }

    let files = try FileManager.default.contentsOfDirectory(
        at: sessionsURL,
        includingPropertiesForKeys: [.fileProtectionKey],
        options: .skipsHiddenFiles
    )

    for fileURL in files where fileURL.pathExtension == "mov" {
        try (fileURL as NSURL).setResourceValue(
            URLFileProtection.complete,
            forKey: .fileProtectionKey
        )
    }
}
```

Call both during `HoopTrackApp.init()` or `AppDelegate.applicationDidFinishLaunching`.

### 5.3 SwiftData Store Encryption

SwiftData (`ModelContainer`) uses the default SQLite store located in the app's Application Support directory. iOS automatically applies `NSFileProtectionCompleteUntilFirstUserAuthentication` to files in Application Support. This means the store is encrypted at rest but accessible after the first unlock.

**This is acceptable** for the SwiftData store because:
- The app legitimately needs to read training data during background operations (e.g., notification scheduling, widget updates).
- Upgrading to `.complete` would break background access entirely.
- The store does not contain highly sensitive secrets (those go in the Keychain).

**Action:** Verify the actual protection class of the SwiftData store in a debug build:

```swift
// Debug only — log to console, never ship
let appSupport = FileManager.default.urls(
    for: .applicationSupportDirectory, in: .userDomainMask)[0]
let storeURL = appSupport.appendingPathComponent("default.store")
if let protection = try? (storeURL as NSURL).resourceValues(forKeys: [.fileProtectionKey])
                                              .fileProtection {
    print("SwiftData store protection: \(protection)")
    // Expected: .completeUntilFirstUserAuthentication
}
```

### 5.4 Exported Data Files

When a future export feature writes a JSON or CSV file to the user's Documents folder:

```swift
func writeExportFile(data: Data, filename: String) throws -> URL {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let exportURL = docs.appendingPathComponent(filename)

    try data.write(to: exportURL, options: [.atomic, .completeFileProtection])
    //                                              ^^^^^^^^^^^^^^^^^^^^^^^^
    // .completeFileProtection sets FileProtectionType.complete on the written file.
    return exportURL
}
```

---

## 6. Privacy Manifest (PrivacyInfo.xcprivacy)

### 6.1 Background

Apple requires a Privacy Manifest (`PrivacyInfo.xcprivacy`) for all apps submitted to the App Store since iOS 17. It must declare:
- All privacy-sensitive APIs used and the reason codes for each.
- All data types collected and whether they are linked to identity.
- Third-party SDKs that require their own manifest entries (none currently, but Supabase Swift SDK will need auditing).

### 6.2 APIs Used in HoopTrack

| API Category | Framework / API | Reason | Required reason code |
|---|---|---|---|
| Camera access | `AVCaptureSession` | Real-time ball and body tracking for training analysis | `NSCameraUsageDescription` |
| File timestamp APIs | `FileManager`, `NSFileManager` | `creationDate`, `modificationDate` on session video files | `NSPrivacyAccessedAPICategoryFileTimestamp` — Reason `C617.1` (file the app created) |
| System boot time | Not used directly — audit CV pipeline for `ProcessInfo.processInfo.systemUptime` usage | N/A | None currently |
| User defaults | `UserDefaults` | App preferences only; no tracking | `NSPrivacyAccessedAPICategoryUserDefaults` — Reason `CA92.1` (user-facing app functionality) |
| Disk space | Not used — audit if added | N/A | None currently |

### 6.3 Complete PrivacyInfo.xcprivacy Template

Create `HoopTrack/PrivacyInfo.xcprivacy` (XML property list):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>

    <!-- ============================================================
         PRIVACY NUTRITION LABEL DATA
         Mirrors the App Store Connect declarations below.
         ============================================================ -->
    <key>NSPrivacyCollectedDataTypes</key>
    <array>

        <!-- Health and Fitness — body pose biomechanics, training stats -->
        <dict>
            <key>NSPrivacyCollectedDataType</key>
            <string>NSPrivacyCollectedDataTypeFitness</string>
            <key>NSPrivacyCollectedDataTypeLinked</key>
            <false/>
            <!-- Not linked to identity in Phase 1 (local-only).
                 Set to true when Supabase account sync is introduced. -->
            <key>NSPrivacyCollectedDataTypeTracking</key>
            <false/>
            <key>NSPrivacyCollectedDataTypePurposes</key>
            <array>
                <string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
            </array>
        </dict>

        <!-- User Content — session videos containing the user's body -->
        <dict>
            <key>NSPrivacyCollectedDataType</key>
            <string>NSPrivacyCollectedDataTypeOtherUserContent</string>
            <key>NSPrivacyCollectedDataTypeLinked</key>
            <false/>
            <key>NSPrivacyCollectedDataTypeTracking</key>
            <false/>
            <key>NSPrivacyCollectedDataTypePurposes</key>
            <array>
                <string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
            </array>
        </dict>

        <!-- Usage Data — session statistics, drill metrics -->
        <dict>
            <key>NSPrivacyCollectedDataType</key>
            <string>NSPrivacyCollectedDataTypeProductInteraction</string>
            <key>NSPrivacyCollectedDataTypeLinked</key>
            <false/>
            <key>NSPrivacyCollectedDataTypeTracking</key>
            <false/>
            <key>NSPrivacyCollectedDataTypePurposes</key>
            <array>
                <string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
                <string>NSPrivacyCollectedDataTypePurposeAnalytics</string>
            </array>
        </dict>

        <!-- Name — PlayerProfile.name (local only) -->
        <dict>
            <key>NSPrivacyCollectedDataType</key>
            <string>NSPrivacyCollectedDataTypeName</string>
            <key>NSPrivacyCollectedDataTypeLinked</key>
            <false/>
            <key>NSPrivacyCollectedDataTypeTracking</key>
            <false/>
            <key>NSPrivacyCollectedDataTypePurposes</key>
            <array>
                <string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
            </array>
        </dict>

    </array>

    <!-- ============================================================
         REQUIRED REASON API DECLARATIONS
         Every API in this list must have at least one approved reason.
         Full list: https://developer.apple.com/documentation/bundleresources/privacy_manifest_files/describing_use_of_required_reason_api
         ============================================================ -->
    <key>NSPrivacyAccessedAPITypes</key>
    <array>

        <!-- File timestamp APIs (FileManager date attributes) -->
        <dict>
            <key>NSPrivacyAccessedAPIType</key>
            <string>NSPrivacyAccessedAPICategoryFileTimestamp</string>
            <key>NSPrivacyAccessedAPITypeReasons</key>
            <array>
                <!-- C617.1: Access the timestamps of files that your app itself created -->
                <string>C617.1</string>
            </array>
        </dict>

        <!-- UserDefaults -->
        <dict>
            <key>NSPrivacyAccessedAPIType</key>
            <string>NSPrivacyAccessedAPICategoryUserDefaults</string>
            <key>NSPrivacyAccessedAPITypeReasons</key>
            <array>
                <!-- CA92.1: Access info from user-facing app functionality that the user can see and update -->
                <string>CA92.1</string>
            </array>
        </dict>

    </array>

    <!-- ============================================================
         TRACKING
         HoopTrack does not track users across apps.
         ============================================================ -->
    <key>NSPrivacyTracking</key>
    <false/>

    <!-- No tracking domains -->
    <key>NSPrivacyTrackingDomains</key>
    <array/>

</dict>
</plist>
```

**Add to Xcode project:** In Xcode, File > New > File > iOS > Property List, name it `PrivacyInfo.xcprivacy`, and place it at the root of the HoopTrack target. Ensure it appears in the target's "Copy Bundle Resources" build phase.

### 6.4 Manifest Maintenance

When new APIs are introduced, update the manifest immediately:
- Adding Sentry crash reporting → add `NSPrivacyCollectedDataTypeCrashData` entry.
- Adding PostHog analytics → add `NSPrivacyCollectedDataTypeProductInteraction` with `NSPrivacyCollectedDataTypePurposeAnalytics`.
- Adding Supabase sync → change `NSPrivacyCollectedDataTypeLinked` from `false` to `true` for all data types that sync.
- Adding `ProcessInfo.systemUptime` for performance measurement → add `NSPrivacyAccessedAPICategorySystemBootTime` with reason `35F9.1`.

---

## 7. Privacy Nutrition Labels

App Store Connect data practice declarations. Complete this checklist before first public submission.

### 7.1 Data Linked to Identity

After Supabase authentication is introduced, the following data is linked to the user's account (and therefore their identity):

| Data type | App Store category | Linked? | Used for tracking? | Purpose |
|---|---|---|---|---|
| Email address | Contact Info | Yes | No | Account authentication |
| Supabase user ID | Identifiers | Yes | No | Syncing data across devices |
| Player name | Contact Info | Yes | No | App functionality |
| Training session records | Fitness | Yes | No | App functionality, progress tracking |
| Shot biomechanics (release angle, vertical jump) | Health & Fitness | Yes | No | App functionality |
| Device token (APNs) | Identifiers | Yes | No | Push notifications (future) |

### 7.2 Data NOT Linked to Identity

| Data type | Category | Notes |
|---|---|---|
| Session videos | User Content | Stored locally only; never uploaded unless user explicitly shares |
| Crash reports (Sentry) | Diagnostics | Linked to device, not user identity; can be configured as anonymous |
| Product analytics (PostHog) | Usage Data | Use anonymous/pseudonymous user IDs — do not send the Supabase user UUID |
| `locationTag` freeform strings | Location | NOT precise location — freeform text like "Home Gym"; declare as Usage Data, not Location |

### 7.3 Data NOT Collected

- Precise location (GPS coordinates)
- Contacts
- Browsing history
- Purchases (before in-app purchases are added)
- Financial information
- Sensitive information beyond health/fitness

### 7.4 App Store Connect Checklist

In App Store Connect under your app's Privacy section, complete these declarations:

- [ ] **Health & Fitness** → Used for app functionality → Linked to identity (after backend launch)
- [ ] **User Content (Other)** → Used for app functionality → NOT linked to identity (videos stay on device)
- [ ] **Identifiers (User ID)** → Used for app functionality → Linked to identity
- [ ] **Contact Info (Email)** → Used for app functionality → Linked to identity
- [ ] **Contact Info (Name)** → Used for app functionality → Linked to identity (PlayerProfile.name)
- [ ] **Usage Data (Product Interaction)** → App functionality + Analytics → NOT linked to identity (pseudonymous analytics)
- [ ] **Diagnostics (Crash Data)** → App functionality → NOT linked to identity

---

## 8. Input Validation and API Security

### 8.1 Fields That Will Become API Payloads

When data syncs to Supabase, these user-provided strings become untrusted payloads:

| Field | Model | Max length | Validation rule |
|---|---|---|---|
| `PlayerProfile.name` | `PlayerProfile` | 50 chars | Printable characters only; strip leading/trailing whitespace |
| `TrainingSession.locationTag` | `TrainingSession` | 100 chars | Printable characters; no SQL metacharacters needed (Supabase uses parameterised queries) |
| `TrainingSession.notes` | `TrainingSession` | 500 chars | Free text; strip null bytes; truncate at limit |
| `GoalRecord` title/description | `GoalRecord` | 100/200 chars | Printable characters |

### 8.2 Input Validator

Create `HoopTrack/Utilities/InputValidator.swift`:

```swift
// InputValidator.swift
// Sanitises user-provided strings before persistence and API transmission.

import Foundation

enum InputValidator {

    /// Sanitises a name or label field: trims whitespace, enforces max length,
    /// removes null bytes and control characters.
    static func sanitiseName(_ input: String, maxLength: Int = 50) -> String {
        input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { !$0.isWhitespace || $0 == " " } // collapse non-space whitespace
            .filter { $0.asciiValue != 0 }            // strip null bytes
            .prefix(maxLength)
            .description
    }

    /// Sanitises free-text notes: trims, strips control chars, enforces length.
    static func sanitiseNotes(_ input: String, maxLength: Int = 500) -> String {
        input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { $0.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } }
            .prefix(maxLength)
            .description
    }

    /// Returns true if the string is a plausible email address.
    static func isValidEmail(_ email: String) -> Bool {
        let pattern = #"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#
        return email.range(of: pattern, options: .regularExpression) != nil
    }

    /// Validates numeric values are within expected sensor ranges.
    /// Rejects obviously corrupt ML output before it reaches the database.
    static func isValidReleaseAngle(_ degrees: Double) -> Bool {
        return degrees >= 0 && degrees <= 90
    }

    static func isValidVerticalJump(_ cm: Double) -> Bool {
        return cm >= 0 && cm <= 150  // 150cm vertical is physically impossible; catches bad ML
    }

    static func isValidCourtCoordinate(_ value: Double) -> Bool {
        return value >= 0 && value <= 1  // Normalised 0–1 court space
    }
}
```

Apply `InputValidator.sanitiseName` before saving `PlayerProfile.name` from any user-facing text field, and before sending it to the API.

### 8.3 Parameterised Queries

Supabase's Swift SDK uses parameterised queries internally for all CRUD operations. **Never** construct raw SQL or PostgREST filter strings using string interpolation from user input:

```swift
// WRONG — injectable
let filter = "name=eq.\(userInput)"

// CORRECT — use the typed SDK methods
let sessions = try await supabase
    .from("training_sessions")
    .select()
    .eq("profile_id", value: userID)
    .execute()
    .value as [TrainingSession]
```

### 8.4 Rate Limiting Awareness

Supabase enforces rate limits on Auth endpoints (sign-in, sign-up, password reset). On the client side:
- Debounce sign-in button taps with a 1-second minimum interval.
- Display a cooldown message when receiving HTTP 429 responses.
- Do not retry automatically on 429 — wait for the `Retry-After` header value.

```swift
// In AuthViewModel
private var lastSignInAttempt: Date = .distantPast
private let signInCooldown: TimeInterval = 1.0

func signIn(email: String, password: String) async {
    guard Date.now.timeIntervalSince(lastSignInAttempt) >= signInCooldown else { return }
    lastSignInAttempt = .now
    // proceed with auth call
}
```

### 8.5 API Response Validation

Never trust data returned from the API without validation — the server could be compromised, or a cache could serve stale data. Validate numeric ranges on deserialization:

```swift
// In a Supabase response decoder
struct RemoteShotRecord: Decodable {
    let releaseAngleDeg: Double?
    let courtX: Double
    let courtY: Double

    enum CodingKeys: String, CodingKey { /* ... */ }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let angle = try c.decodeIfPresent(Double.self, forKey: .releaseAngleDeg)
        let x = try c.decode(Double.self, forKey: .courtX)
        let y = try c.decode(Double.self, forKey: .courtY)

        // Reject implausible values — treat as corrupt data, not an app crash
        guard InputValidator.isValidCourtCoordinate(x),
              InputValidator.isValidCourtCoordinate(y) else {
            throw DecodingError.dataCorruptedError(
                forKey: .courtX,
                in: c,
                debugDescription: "Court coordinate out of valid 0–1 range"
            )
        }
        if let angle = angle {
            guard InputValidator.isValidReleaseAngle(angle) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .releaseAngleDeg, in: c,
                    debugDescription: "Release angle out of valid 0–90 range"
                )
            }
        }
        self.releaseAngleDeg = angle
        self.courtX = x
        self.courtY = y
    }
}
```

---

## 9. GDPR and Privacy Compliance

### 9.1 Applicability

GDPR applies to any EU/EEA resident who uses HoopTrack, regardless of where the developer is based. Once a backend is introduced (even for personal use), the app becomes a data processor and must comply with GDPR's data subject rights.

### 9.2 Right to Delete (Cascade Delete)

The `PlayerProfile` cascade delete already handles local data:

```swift
// In DataService (already implemented via SwiftData cascade rules):
// @Relationship(deleteRule: .cascade) var sessions: [TrainingSession]
// @Relationship(deleteRule: .cascade) var goals: [GoalRecord]
// TrainingSession → @Relationship(deleteRule: .cascade) var shots: [ShotRecord]
```

Add a `deleteAccount` method that handles both local and remote deletion:

```swift
// In DataService or a new AccountDeletionService

func deleteAccount(profile: PlayerProfile) async throws {
    // 1. Delete session videos from disk
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let sessionsDir = docs.appendingPathComponent(HoopTrack.Storage.sessionVideoDirectory)
    if FileManager.default.fileExists(atPath: sessionsDir.path) {
        try FileManager.default.removeItem(at: sessionsDir)
    }

    // 2. Delete SwiftData records (cascade handles children)
    modelContext.delete(profile)
    try modelContext.save()

    // 3. Delete Supabase account data (implement when backend is live)
    // try await supabaseClient.rpc("delete_user_data").execute()
    // try await supabaseClient.auth.signOut()

    // 4. Revoke credentials from Keychain
    try KeychainService.shared.deleteAll()

    // 5. Clear UserDefaults app-specific keys
    let domain = Bundle.main.bundleIdentifier!
    UserDefaults.standard.removePersistentDomain(forName: domain)
}
```

**Supabase server-side deletion:** Create a Postgres function `delete_user_data(user_id uuid)` that deletes all rows for the user in all tables. Trigger it via `supabaseClient.rpc("delete_user_data")` before deleting the Auth user. Supabase Auth user deletion is done via `supabaseClient.auth.admin.deleteUser(id:)` from a server-side function (requires the service role key, which must never be embedded in the app).

**Deletion timeline:** GDPR requires deletion "without undue delay" — typically interpreted as within 30 days of request. For a simple case with no backups, immediate deletion is ideal. If Supabase backups are enabled, inform users in the privacy policy that backup purge occurs within 30 days.

### 9.3 Right to Export (Data Portability)

Export must be machine-readable (JSON is appropriate). When building the export feature:

```swift
// ExportService.swift (to be created)

struct UserDataExport: Codable {
    let exportDate: Date
    let profile: PlayerProfileExport
    let sessions: [SessionExport]
    // Do NOT include: auth tokens, Keychain contents, internal UUIDs
}
```

Deliver the export as a JSON file via iOS Share Sheet. Apply `.completeFileProtection` to the file during write (see Section 5.4). Delete the temporary file after the share sheet is dismissed.

### 9.4 Data Residency

Supabase region selection determines where personal data is stored at rest. For GDPR compliance:
- Select an EU region (`eu-west-1` / Ireland, or `eu-central-1` / Frankfurt) if the primary user base is EU.
- This is a one-time setup decision — Supabase does not support live region migration.
- Document the selected region in the app's privacy policy ("Data is stored on servers located in [Region]").
- If targeting both EU and non-EU users at scale, evaluate Supabase's multi-region capabilities or a data residency tier.

### 9.5 Privacy Policy Requirements

The privacy policy must state:
- What data is collected and why.
- Where data is stored (Supabase region).
- Retention periods (session videos: 60 days default; account data: retained until deletion).
- How users can request deletion (in-app "Delete Account" button is sufficient).
- How users can request a data export.
- Contact information for privacy requests.
- Date of last update.

---

## 10. Security Testing Checklist

### 10.1 Keychain Verification

- [ ] **Write a test** in `HoopTrackTests/KeychainServiceTests.swift` that saves, retrieves, updates, and deletes a value. Assert no crashes and correct round-trip.
- [ ] **Verify no tokens in UserDefaults:** After sign-in, check `UserDefaults.standard.dictionaryRepresentation()` in a debug print — assert no JWT strings are present.
- [ ] **Verify Keychain is cleared on sign-out:** Call `deleteAll()`, then attempt to read `KeychainKey.accessToken` and assert `KeychainError.itemNotFound` is thrown.
- [ ] **Simulator Keychain note:** Keychain items in Simulator persist across app installs. Use a dedicated test bundle ID in the unit test target to avoid contamination.

### 10.2 ATS Testing with Charles Proxy

1. Install Charles Proxy on Mac. Configure iOS Simulator to route traffic through Charles.
2. Install the Charles root certificate on the Simulator (using Charles > Help > SSL Proxying > Install on iOS Simulator).
3. Launch HoopTrack and trigger all network actions (sign-in, data sync, video upload).
4. **Assertion:** All traffic should appear in Charles as HTTPS. Any plain HTTP request is a failure.
5. **Certificate pinning assertion:** With pinning enabled, Charles's interception should cause all Supabase requests to fail with "connection error." This confirms pinning is working — Charles's certificate does not match the pinned hash.
6. **Without pinning:** temporarily disable `PinningURLSessionDelegate` (use a `#if DEBUG` flag) to confirm the baseline traffic is correct before re-enabling pinning.

### 10.3 Data Protection Verification

1. Run the app on a physical device (Data Protection is meaningless in Simulator — it does not enforce file encryption classes).
2. Record a training session to create a video file in `Documents/Sessions/`.
3. Use a debug snippet to print the protection class of the created file (see Section 5.2).
4. **Assertion:** Video files should report `NSFileProtectionComplete` (`.complete`).
5. **Assertion:** SwiftData store should report `NSFileProtectionCompleteUntilFirstUserAuthentication`.

### 10.4 Privacy Manifest Validation

- [ ] Run `xcrun agvtool` and check that Xcode includes `PrivacyInfo.xcprivacy` in the bundle (visible in `.ipa` contents under `Payload/HoopTrack.app/PrivacyInfo.xcprivacy`).
- [ ] Use Xcode's Privacy Report (Product > Generate Privacy Report in Xcode 15+) to auto-detect APIs used and compare against manifest declarations. Any detected API not in the manifest is a failure.
- [ ] Submit a TestFlight build — Apple's TestFlight processing now includes a privacy manifest validation step. Review the result before submitting to App Review.

### 10.5 Input Validation Testing

Add to `HoopTrackTests/InputValidatorTests.swift`:

```swift
func testSanitiseNameStripsNullBytes() {
    let input = "Player\0Name"
    let result = InputValidator.sanitiseName(input)
    XCTAssertFalse(result.contains("\0"))
}

func testSanitiseNameEnforcesMaxLength() {
    let longName = String(repeating: "A", count: 200)
    let result = InputValidator.sanitiseName(longName, maxLength: 50)
    XCTAssertEqual(result.count, 50)
}

func testInvalidCourtCoordinatesRejected() {
    XCTAssertFalse(InputValidator.isValidCourtCoordinate(-0.1))
    XCTAssertFalse(InputValidator.isValidCourtCoordinate(1.1))
    XCTAssertTrue(InputValidator.isValidCourtCoordinate(0.5))
}

func testInvalidReleaseAngleRejected() {
    XCTAssertFalse(InputValidator.isValidReleaseAngle(-1))
    XCTAssertFalse(InputValidator.isValidReleaseAngle(91))
    XCTAssertTrue(InputValidator.isValidReleaseAngle(45))
}
```

### 10.6 Certificate Pinning Test

Create a unit test that mocks a `URLAuthenticationChallenge` with a certificate whose SPKI hash does NOT match the trusted set:

```swift
func testPinningRejectsUnknownCertificate() {
    // Generate a self-signed test cert and compute its SPKI hash
    // Assert that PinningURLSessionDelegate calls completionHandler(.cancelAuthenticationChallenge, nil)
    // This is an integration-level test — run it against a local HTTPS server with a test cert
}
```

For a simpler smoke test: in a debug build, temporarily add an obviously wrong hash to `trustedHashes` and a correct one absent, then verify Supabase calls fail with a network error (not a crash).

### 10.7 GDPR Delete Test

```swift
func testDeleteAccountRemovesAllLocalData() async throws {
    // Setup: create a profile with sessions, shots, goals, and a mock video file
    // Act: call DataService.deleteAccount(profile:)
    // Assert:
    //   - No PlayerProfile in SwiftData store
    //   - No TrainingSession, ShotRecord, GoalRecord in store
    //   - Documents/Sessions/ directory does not exist (or is empty)
    //   - KeychainService.shared.string(forKey:) throws .itemNotFound for all keys
}
```

---

## 11. Incident Response

### 11.1 Scenario: Auth Tokens Compromised

If a user's device is stolen (unlocked) or a Keychain extraction technique is used on a compromised device:

**Server-side response (Supabase):**
1. Revoke the user's session via the Supabase Dashboard (Authentication > Users > select user > Invalidate All Sessions), or via the Admin API: `POST /auth/v1/admin/users/{user_id}/logout`.
2. This invalidates the refresh token server-side. The stolen access token will continue to work until it expires (Supabase default: 1 hour). Set the JWT expiry to 15 minutes in Supabase Auth settings to reduce this window.
3. If the compromise is broad (server-side breach of the JWT signing key): rotate the JWT secret in Supabase settings. This invalidates ALL active sessions for all users.

**Client-side response:**
4. On the next app launch after token revocation, the access token refresh call to Supabase will return 401. The app must handle this by clearing the Keychain and presenting the sign-in screen.

```swift
// In NetworkService error handling
func handleAuthError(_ error: Error, response: HTTPURLResponse?) {
    guard response?.statusCode == 401 else { return }
    // Token is invalid or revoked — force sign-out
    Task { @MainActor in
        try? KeychainService.shared.deleteAll()
        NotificationCenter.default.post(name: .hooptrackSessionExpired, object: nil)
    }
}
```

```swift
extension Notification.Name {
    static let hooptrackSessionExpired = Notification.Name("com.hooptrack.app.sessionExpired")
}
```

In the root `ContentView` or `HoopTrackApp`:

```swift
.onReceive(NotificationCenter.default.publisher(for: .hooptrackSessionExpired)) { _ in
    // Navigate to sign-in screen, clear any in-memory auth state
    authState = .signedOut
}
```

### 11.2 Scenario: Backend API Key Exposed in Source Code

If the Supabase `anon` key is accidentally committed to source control:
1. **Immediately** rotate the API key in the Supabase Dashboard (Settings > API > Regenerate).
2. Remove the key from the git history using `git filter-repo` or BFG Repo Cleaner. Force-push to all remotes.
3. Update `Secrets.xcconfig` (see below) with the new key and rebuild.
4. Review Row Level Security policies — the `anon` key is not secret by design (RLS enforces access), but rotation is still prudent.

**Never hardcode the Supabase URL or keys in Swift source files.** Use a gitignored config file:

```
# Secrets.xcconfig — gitignored, never committed
SUPABASE_URL = https://YOUR_PROJECT_REF.supabase.co
SUPABASE_ANON_KEY = your-anon-key-here
```

Reference these in `Info.plist`:
```xml
<key>SupabaseURL</key>
<string>$(SUPABASE_URL)</string>
<key>SupabaseAnonKey</key>
<string>$(SUPABASE_ANON_KEY)</string>
```

Read at runtime:
```swift
enum Config {
    static var supabaseURL: URL {
        let string = Bundle.main.infoDictionary?["SupabaseURL"] as! String
        return URL(string: string)!
    }
    static var supabaseAnonKey: String {
        Bundle.main.infoDictionary?["SupabaseAnonKey"] as! String
    }
}
```

Add `Secrets.xcconfig` to `.gitignore` and document the setup in `CLAUDE.md`.

### 11.3 Scenario: Certificate Pinning Failure in Production

If a Supabase infrastructure change causes cert rotation that breaks pinning before a pin rotation app update is shipped:
1. **Immediate mitigation:** Ship an emergency app update with the new hash added and expedited App Review requested (24-hour turnaround is common for security fixes).
2. **Server-side kill switch (implement proactively):** Add a `min_pinned_version` field to a publicly accessible configuration endpoint (or Supabase remote config). Before enforcing pinning, check if the current app version meets the minimum. If not, fall back to standard TLS validation. This requires the config endpoint itself to be trusted — use a static JSON file on Cloudflare R2 with a known fixed hash for that endpoint.
3. **Monitoring:** Instrument pinning failures (count of `cancelAuthenticationChallenge` events) in crash reporting (Sentry). A spike in pinning failures is an early warning of either a MITM attack or a server-side certificate change.

### 11.4 Forced Sign-Out Mechanism

For incidents requiring immediate invalidation of all client sessions (e.g., data breach):
1. In Supabase Auth settings, rotate the JWT signing secret. This invalidates all active tokens globally.
2. Optionally, publish a flag in a Supabase remote config table (`forced_signout_version: N`) that the app polls on launch. If the stored `signed_in_version` in the Keychain is less than `N`, force sign-out.

```swift
// AuthService.swift
func checkForcedSignOut() async throws {
    let config = try await supabase
        .from("app_config")
        .select("forced_signout_version")
        .single()
        .execute()
        .value as AppConfig

    let storedVersion = (try? KeychainService.shared.string(forKey: "signedInVersion"))
                            .flatMap(Int.init) ?? 0

    if storedVersion < config.forcedSignoutVersion {
        try KeychainService.shared.deleteAll()
        throw AuthError.forcedSignOut
    }
}
```

---

## Implementation Sequence

Complete in this order to maximise safety before the backend is live:

1. **`PrivacyInfo.xcprivacy`** — Required for any App Store submission; zero risk; do this first.
2. **File protection on `Documents/Sessions/`** — Pure local change; no dependencies; do before any more sessions are recorded.
3. **`KeychainService`** — Must exist before any auth token is handled; pure framework code with no backend dependency.
4. **`InputValidator`** — Pure logic; write the tests alongside implementation.
5. **`Info.plist` ATS configuration** — Explicit lockdown of existing defaults.
6. **Privacy nutrition labels** — Required for App Store Connect; complete alongside manifest.
7. **`PinningURLSessionDelegate`** — Implement and test against a dev Supabase project before production launch.
8. **`NetworkService` with pinned session** — Wire `PinningURLSessionDelegate` into the Supabase client.
9. **Account deletion and GDPR export** — Required before public launch; can be implemented in parallel with backend work.
10. **Incident response plumbing** — `hooptrackSessionExpired` notification, `Secrets.xcconfig` setup, forced sign-out mechanism.
