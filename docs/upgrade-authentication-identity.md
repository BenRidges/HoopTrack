# Authentication & Identity Integration Plan
## HoopTrack — Phase 6 (Auth)

**Status:** Pre-implementation design  
**Date:** 2026-04-12  
**Min deployment target:** iOS 16.0  
**Frameworks added:** AuthenticationServices, Security, LocalAuthentication  
**External SDK added:** supabase-swift (Swift Package Manager)

---

## 1. Overview

HoopTrack currently stores all data locally in SwiftData with no concept of a user identity. Every `PlayerProfile`, `TrainingSession`, `ShotRecord`, and `GoalRecord` lives on-device only, tied to no external account.

Authentication unlocks the following roadmap capabilities:

| Capability | Requires Auth |
|---|---|
| Cloud sync — session data available across devices and on the web | Yes |
| Shared leaderboards / multiplayer drills | Yes |
| Web dashboard for coaches to review player stats | Yes |
| Restore data after device replacement / app deletion | Yes |
| Push personalisation (server-side notifications) | Yes |
| AI coaching feedback tied to a persistent identity | Yes |

The chosen stack is intentionally minimal and Apple-native where possible:

- **Sign in with Apple** — zero-friction, privacy-preserving, App Store required when any social login is offered
- **Supabase Auth** — wraps Sign in with Apple on the backend, issues JWTs, manages sessions
- **JWT storage in Keychain** — never `UserDefaults`, never in-memory across restarts
- **Face ID / Touch ID via LAContext** — re-auth gate after app backgrounding, layered on top of Keychain storage

Optional for a later sub-phase: Sign in with Google via the same Supabase Auth integration.

---

## 2. Sign in with Apple Integration

### 2.1 Xcode Entitlements

In Xcode → Target → Signing & Capabilities, add the **Sign In with Apple** capability. This writes the following to `HoopTrack.entitlements`:

```xml
<key>com.apple.developer.applesignin</key>
<array>
    <string>Default</string>
</array>
```

No manual entitlements file edits required — the Xcode toggle does this automatically.

### 2.2 AuthenticationServices Import

`AuthenticationServices` is an Apple system framework. No package dependency needed.

```swift
import AuthenticationServices
```

### 2.3 ASAuthorizationController Setup

Create a dedicated `SignInWithAppleCoordinator` class (not the `AuthViewModel` itself) to own the `ASAuthorizationController` delegate callbacks. This decouples the presentation layer from the view model.

```swift
// Phase 6 — Auth
import AuthenticationServices
import CryptoKit

@MainActor
final class SignInWithAppleCoordinator: NSObject,
    ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding {

    // Nonce used to prevent replay attacks. Generated per request.
    private var currentNonce: String?

    // Callback into AuthViewModel on success or failure
    var onCredential: ((ASAuthorizationAppleIDCredential) -> Void)?
    var onError: ((Error) -> Void)?

    // MARK: - Start sign-in flow

    func startSignIn() {
        let nonce = randomNonceString()
        currentNonce = nonce

        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = sha256(nonce)

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
    }

    // MARK: - ASAuthorizationControllerDelegate

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential
        else { return }
        Task { @MainActor in
            self.onCredential?(credential)
        }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        Task { @MainActor in
            self.onError?(error)
        }
    }

    // MARK: - ASAuthorizationControllerPresentationContextProviding

    nonisolated func presentationAnchor(
        for controller: ASAuthorizationController
    ) -> ASPresentationAnchor {
        // Safe: called on main thread by the framework
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }

    // MARK: - Crypto helpers

    private func randomNonceString(length: Int = 32) -> String {
        var randomBytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &randomBytes)
        return randomBytes.map { String(format: "%02x", $0) }.joined()
    }

    private func sha256(_ input: String) -> String {
        let data = Data(input.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}
```

**Why nonisolated on delegate callbacks?** The `ASAuthorizationControllerDelegate` protocol is not `@MainActor`-constrained. Since `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` is set project-wide, the delegate methods must be explicitly `nonisolated` to satisfy the protocol, then hop back to `@MainActor` via `Task { @MainActor in }` for any state mutations.

### 2.4 Handling the ASAuthorization Credential

Apple only returns the user's `fullName` and `email` on the **first** sign-in. On returning sign-ins, these fields will be `nil`. The backend (Supabase) is the source of truth for those values after the first sign-in.

```swift
// Inside AuthViewModel, called from onCredential closure:
func handleAppleCredential(_ credential: ASAuthorizationAppleIDCredential) async {
    guard let identityToken = credential.identityToken,
          let tokenString   = String(data: identityToken, encoding: .utf8)
    else {
        state = .error("Apple credential did not include an identity token.")
        return
    }

    // First-time: capture name before it disappears
    let fullName = credential.fullName.flatMap {
        PersonNameComponentsFormatter().string(from: $0).nonEmpty
    }

    // Hand off to Supabase — see Section 4
    await supabaseSignIn(identityToken: tokenString, fullName: fullName)
}
```

---

## 3. JWT Token Management

### 3.1 Keychain Wrapper

Rather than a third-party library, use a thin `KeychainService` backed directly by the `Security` framework. This keeps the no-third-party-dependencies constraint intact for everything except `supabase-swift`.

```swift
// Phase 6 — Auth
import Security
import Foundation

enum KeychainKey: String {
    case accessToken  = "com.hooptrack.auth.access_token"
    case refreshToken = "com.hooptrack.auth.refresh_token"
    case userID       = "com.hooptrack.auth.user_id"
}

enum KeychainError: Error {
    case itemNotFound
    case unexpectedData
    case unhandledError(OSStatus)
}

struct KeychainService {

    // MARK: - Save

    static func save(_ value: String, for key: KeychainKey) throws {
        let data = Data(value.utf8)
        let query: [CFString: Any] = [
            kSecClass:           kSecClassGenericPassword,
            kSecAttrAccount:     key.rawValue,
            kSecValueData:       data,
            kSecAttrAccessible:  kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        // Delete old value first (upsert pattern)
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unhandledError(status)
        }
    }

    // MARK: - Read

    static func read(_ key: KeychainKey) throws -> String {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrAccount: key.rawValue,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            throw status == errSecItemNotFound
                ? KeychainError.itemNotFound
                : KeychainError.unhandledError(status)
        }
        guard let data = result as? Data,
              let string = String(data: data, encoding: .utf8)
        else { throw KeychainError.unexpectedData }
        return string
    }

    // MARK: - Delete

    static func delete(_ key: KeychainKey) {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrAccount: key.rawValue
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func deleteAll() {
        KeychainKey.allCases.forEach { delete($0) }
    }
}

extension KeychainKey: CaseIterable {}
```

**Accessibility choice:** `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` allows token reads when the app wakes in the background (e.g., for a silent push that triggers a token refresh), while still binding tokens to this device only (not migrated to a new device via iCloud Keychain). Tokens must be re-acquired on a new device via a fresh sign-in.

### 3.2 Token Refresh Strategy

The `supabase-swift` SDK manages token refresh automatically when using its built-in session handling (see Section 4). If you ever bypass the SDK for direct API calls, handle 401s in a `URLSession` delegate:

```swift
// Phase 6 — Auth: custom URLSession interceptor for any direct API calls
actor TokenRefresher {
    private var refreshTask: Task<String, Error>?

    func validAccessToken() async throws -> String {
        // Return cached token if it isn't expired
        if let token = try? KeychainService.read(.accessToken),
           !isTokenExpired(token) {
            return token
        }
        // Coalesce concurrent refresh calls into one
        if let task = refreshTask { return try await task.value }
        let task = Task<String, Error> {
            defer { refreshTask = nil }
            let newToken = try await SupabaseClient.shared.auth.refreshSession().accessToken
            try KeychainService.save(newToken, for: .accessToken)
            return newToken
        }
        refreshTask = task
        return try await task.value
    }

    private func isTokenExpired(_ jwt: String) -> Bool {
        // Decode the payload (second Base64url segment) to read `exp`
        let parts = jwt.split(separator: ".")
        guard parts.count == 3,
              let payloadData = Data(base64URLEncoded: String(parts[1])),
              let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let exp = json["exp"] as? TimeInterval
        else { return true }
        // Treat token as expired 30 s before actual expiry to avoid races
        return Date().timeIntervalSince1970 > (exp - 30)
    }
}
```

### 3.3 Handling 401s in URLSession

If you make direct `URLSession` calls to Supabase REST endpoints, wrap them with automatic retry on 401:

```swift
// Phase 6 — Auth
extension URLSession {
    func dataWithTokenRefresh(for request: URLRequest,
                               refresher: TokenRefresher) async throws -> (Data, URLResponse) {
        var req = request
        let token = try await refresher.validAccessToken()
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await data(for: req)
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            // Force a refresh and retry once
            let newToken = try await SupabaseClient.shared.auth.refreshSession().accessToken
            try KeychainService.save(newToken, for: .accessToken)
            req.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
            return try await data(for: req)
        }
        return (data, response)
    }
}
```

---

## 4. Supabase Auth Integration

### 4.1 Adding the supabase-swift Package

In Xcode: File → Add Package Dependencies  
URL: `https://github.com/supabase/supabase-swift`  
Version rule: Up to Next Major from `2.0.0`  
Products to add: `Supabase` (includes Auth)

This is the only third-party dependency introduced by this phase. All other capabilities remain Apple-native.

### 4.2 SupabaseClient Singleton

```swift
// Phase 6 — Auth
// SupabaseClient.swift

import Supabase
import Foundation

extension SupabaseClient {
    /// Shared instance. Configure via `HoopTrack.Backend` constants.
    static let shared = SupabaseClient(
        supabaseURL: URL(string: HoopTrack.Backend.supabaseURL)!,
        supabaseKey: HoopTrack.Backend.supabaseAnonKey
    )
}
```

Add to `Constants.swift`:

```swift
// Inside enum HoopTrack — Phase 6 (Auth)
enum Backend {
    static let supabaseURL     = "https://YOUR_PROJECT_REF.supabase.co"
    static let supabaseAnonKey = "YOUR_ANON_KEY"   // safe to include in binary
}
```

The anon key is the public client key, not the service role key. It is safe to embed in the app binary. Never embed the service role key.

### 4.3 Sign In with Apple via Supabase

```swift
// Inside AuthViewModel.supabaseSignIn(identityToken:fullName:)
func supabaseSignIn(identityToken: String, fullName: String?) async {
    state = .authenticating
    do {
        let session = try await SupabaseClient.shared.auth.signInWithIdToken(
            credentials: .init(
                provider: .apple,
                idToken: identityToken
            )
        )
        // Persist tokens
        try KeychainService.save(session.accessToken,  for: .accessToken)
        try KeychainService.save(session.refreshToken, for: .refreshToken)
        try KeychainService.save(session.user.id.uuidString, for: .userID)

        // Link Supabase user ID to local PlayerProfile
        await linkUserIDToProfile(userID: session.user.id.uuidString,
                                   displayName: fullName)
        state = .authenticated(userID: session.user.id.uuidString)
    } catch {
        state = .error(error.localizedDescription)
    }
}
```

### 4.4 Session Persistence

The `supabase-swift` SDK stores its own session in `UserDefaults` by default. For HoopTrack, override this to use Keychain only by supplying a custom `AuthLocalStorage` implementation:

```swift
// Phase 6 — Auth
import Supabase

struct KeychainAuthStorage: AuthLocalStorage {
    func store(key: String, value: Data) throws {
        let string = value.base64EncodedString()
        try KeychainService.save(string, for: .init(rawValue: key)!)
    }
    func retrieve(key: String) throws -> Data {
        let string = try KeychainService.read(.init(rawValue: key)!)
        guard let data = Data(base64Encoded: string)
        else { throw KeychainError.unexpectedData }
        return data
    }
    func remove(key: String) throws {
        KeychainService.delete(.init(rawValue: key)!)
    }
}

// Then configure SupabaseClient:
static let shared = SupabaseClient(
    supabaseURL: URL(string: HoopTrack.Backend.supabaseURL)!,
    supabaseKey: HoopTrack.Backend.supabaseAnonKey,
    options: .init(
        auth: .init(storage: KeychainAuthStorage())
    )
)
```

This ensures no auth material ever lands in `UserDefaults`.

---

## 5. PlayerProfile Linkage

### 5.1 Adding `supabaseUserID` to PlayerProfile

The existing `PlayerProfile` SwiftData model needs a `supabaseUserID: String?` field that stores the Supabase UUID for the authenticated user. This is `Optional` because existing profiles — and profiles created before sign-in — will not have one.

```swift
// PlayerProfile.swift — Phase 6 (Auth) addition
// MARK: - Cloud Identity (Phase 6)
var supabaseUserID: String?   // nil until user signs in
```

### 5.2 Migration Strategy

The migration from V2 → V3 is a **lightweight migration** because `supabaseUserID` is an optional property with a `nil` default. SwiftData handles this automatically.

Add `HoopTrackSchemaV3` to `HoopTrackSchemaV1.swift`:

```swift
enum HoopTrackSchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)
    static var models: [any PersistentModel.Type] {
        [PlayerProfile.self, TrainingSession.self,
         ShotRecord.self, GoalRecord.self, EarnedBadge.self]
    }
}
```

Update `HoopTrackMigrationPlan.swift`:

```swift
enum HoopTrackMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [HoopTrackSchemaV1.self, HoopTrackSchemaV2.self, HoopTrackSchemaV3.self]
    }

    static var stages: [MigrationStage] {
        [migrateV1toV2, migrateV2toV3]
    }

    static let migrateV1toV2 = MigrationStage.lightweight(
        fromVersion: HoopTrackSchemaV1.self,
        toVersion:   HoopTrackSchemaV2.self
    )

    // Adding supabaseUserID: String? — lightweight (no mapping needed)
    static let migrateV2toV3 = MigrationStage.lightweight(
        fromVersion: HoopTrackSchemaV2.self,
        toVersion:   HoopTrackSchemaV3.self
    )
}
```

### 5.3 Linking at Sign-In

After a successful Supabase sign-in, write the Supabase user ID back to the `PlayerProfile`:

```swift
// Inside AuthViewModel
private func linkUserIDToProfile(userID: String, displayName: String?) async {
    do {
        let profile = try dataService.fetchOrCreateProfile()
        profile.supabaseUserID = userID
        // Capture display name from Apple on first sign-in
        if let name = displayName, profile.name == "Player" || profile.name.isEmpty {
            profile.name = name
        }
        // DataService saves automatically via SwiftData's @Model observation
    } catch {
        // Non-fatal: profile link will retry next launch
        print("HoopTrack Auth: failed to link userID to profile — \(error)")
    }
}
```

---

## 6. AuthViewModel

### 6.1 Auth State Enum

```swift
// Phase 6 — Auth
enum AuthState: Equatable {
    case unauthenticated
    case authenticating
    case authenticated(userID: String)
    case error(String)

    var isAuthenticated: Bool {
        if case .authenticated = self { return true }
        return false
    }
}
```

### 6.2 AuthViewModel Design

```swift
// Phase 6 — Auth
// AuthViewModel.swift

import Foundation
import Combine
import AuthenticationServices
import Supabase

@MainActor
final class AuthViewModel: ObservableObject {

    // MARK: - Published
    @Published private(set) var state: AuthState = .unauthenticated
    @Published private(set) var currentUserID: String?

    // MARK: - Dependencies
    private let dataService: DataService
    private let appleCoordinator = SignInWithAppleCoordinator()

    init(dataService: DataService) {
        self.dataService = dataService
        appleCoordinator.onCredential = { [weak self] credential in
            Task { await self?.handleAppleCredential(credential) }
        }
        appleCoordinator.onError = { [weak self] error in
            self?.state = .error(error.localizedDescription)
        }
    }

    // MARK: - Public API

    /// Call on app launch to restore session from Keychain.
    func restoreSession() async {
        guard let userID = try? KeychainService.read(.userID) else {
            state = .unauthenticated
            return
        }
        // Validate via Supabase — this will use the stored session / refresh if needed
        do {
            let session = try await SupabaseClient.shared.auth.session
            currentUserID = session.user.id.uuidString
            state = .authenticated(userID: session.user.id.uuidString)
        } catch {
            // Tokens invalid/expired — treat as unauthenticated
            KeychainService.deleteAll()
            state = .unauthenticated
        }
        _ = userID // suppress unused warning until above is wired
    }

    /// Triggers the Sign in with Apple sheet.
    func signInWithApple() {
        state = .authenticating
        appleCoordinator.startSignIn()
    }

    /// Signs out: clears Keychain tokens, optionally clears remote session.
    func signOut(clearLocalData: Bool = false) async {
        do {
            try await SupabaseClient.shared.auth.signOut()
        } catch {
            // Best-effort — clear local tokens regardless
        }
        KeychainService.deleteAll()
        currentUserID = nil
        state = .unauthenticated

        if clearLocalData {
            await clearLocalSwiftDataStore()
        }
    }

    // MARK: - Internal

    private func handleAppleCredential(_ credential: ASAuthorizationAppleIDCredential) async {
        guard let identityToken = credential.identityToken,
              let tokenString   = String(data: identityToken, encoding: .utf8)
        else {
            state = .error("Sign in with Apple did not return a valid identity token.")
            return
        }
        let fullName = credential.fullName.flatMap { components -> String? in
            let name = [components.givenName, components.familyName]
                .compactMap { $0 }
                .joined(separator: " ")
            return name.isEmpty ? nil : name
        }
        await supabaseSignIn(identityToken: tokenString, fullName: fullName)
    }

    private func supabaseSignIn(identityToken: String, fullName: String?) async {
        do {
            let session = try await SupabaseClient.shared.auth.signInWithIdToken(
                credentials: .init(provider: .apple, idToken: identityToken)
            )
            try KeychainService.save(session.accessToken,  for: .accessToken)
            try KeychainService.save(session.refreshToken, for: .refreshToken)
            try KeychainService.save(session.user.id.uuidString, for: .userID)

            currentUserID = session.user.id.uuidString
            await linkUserIDToProfile(userID: session.user.id.uuidString,
                                       displayName: fullName)
            state = .authenticated(userID: session.user.id.uuidString)
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    private func linkUserIDToProfile(userID: String, displayName: String?) async {
        do {
            let profile = try dataService.fetchOrCreateProfile()
            profile.supabaseUserID = userID
            if let name = displayName,
               profile.name == "Player" || profile.name.isEmpty {
                profile.name = name
            }
        } catch {
            print("HoopTrack Auth: profile linkage failed — \(error)")
        }
    }

    private func clearLocalSwiftDataStore() async {
        // Phase 6: call DataService.deleteAllUserData() (to be implemented)
        // This is a destructive operation — only triggered by explicit user action.
    }
}
```

---

## 7. App Entry Flow

### 7.1 HoopTrackApp Changes

`AuthViewModel` is created as a `@StateObject` alongside the existing services, then injected into the environment. Auth state is checked in `CoordinatorHost` before the main content is shown.

```swift
// HoopTrackApp.swift — Phase 6 additions
@main
struct HoopTrackApp: App {

    let modelContainer: ModelContainer = { /* unchanged */ }()

    @StateObject private var hapticService       = HapticService()
    @StateObject private var notificationService = NotificationService()
    @StateObject private var cameraService       = CameraService()
    // Phase 6 — Auth
    @StateObject private var authViewModel       = AuthViewModel(
        dataService: DataService(modelContext: /* see note */ )
    )

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some Scene {
        WindowGroup {
            CoordinatorHost()
                .modelContainer(modelContainer)
                .environmentObject(hapticService)
                .environmentObject(notificationService)
                .environmentObject(cameraService)
                .environmentObject(authViewModel)           // Phase 6
                .fullScreenCover(isPresented: .init(
                    get: { !hasCompletedOnboarding },
                    set: { if !$0 { hasCompletedOnboarding = true } }
                )) {
                    OnboardingView(hasCompletedOnboarding: $hasCompletedOnboarding)
                }
        }
    }
}
```

**Note on DataService construction:** `AuthViewModel` needs a `DataService`, which needs a `ModelContext`. `ModelContext` is only available inside `WindowGroup` via the environment. The cleanest solution is the same lazy `Box` pattern already used in `CoordinatorHost`:

```swift
// AuthBox.swift — mirrors CoordinatorBox pattern
@MainActor final class AuthBox: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    private(set) var viewModel: AuthViewModel? {
        willSet { objectWillChange.send() }
    }

    func build(modelContext: ModelContext) {
        guard viewModel == nil else { return }
        viewModel = AuthViewModel(dataService: DataService(modelContext: modelContext))
    }
}
```

Then in `CoordinatorHost` (or a new `AuthGate` view), build both the auth and coordinator ViewModels from the same `ModelContext`.

### 7.2 Auth Gate Routing

Introduce a thin `AuthGate` view that sits between `CoordinatorHost` and the main content:

```swift
// Phase 6 — Auth
// AuthGate.swift

import SwiftUI

struct AuthGate: View {
    @EnvironmentObject private var authViewModel: AuthViewModel

    var body: some View {
        switch authViewModel.state {
        case .unauthenticated, .error:
            SignInView()
        case .authenticating:
            AuthLoadingView()
        case .authenticated:
            CoordinatorHost()
        }
    }
}
```

In `HoopTrackApp.body`, replace `CoordinatorHost()` with `AuthGate()`.

On launch, `CoordinatorHost` (or the entry view) calls `authViewModel.restoreSession()` via `.task`:

```swift
AuthGate()
    .task { await authViewModel.restoreSession() }
```

### 7.3 Sign In View

```swift
// Phase 6 — Auth
// SignInView.swift

import SwiftUI
import AuthenticationServices

struct SignInView: View {
    @EnvironmentObject private var authViewModel: AuthViewModel

    var body: some View {
        VStack(spacing: 24) {
            // App logo / branding
            Image("AppIconLarge")
                .resizable()
                .frame(width: 96, height: 96)
                .cornerRadius(22)

            Text("Welcome to HoopTrack")
                .font(.title2.bold())

            Text("Sign in to sync your training across devices and unlock cloud features.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.fullName, .email]
            } onCompletion: { _ in
                // Handled inside AuthViewModel via coordinator
                authViewModel.signInWithApple()
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 54)
            .padding(.horizontal)

            if case .error(let message) = authViewModel.state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            // Phase 6 optional: "Continue without account" for offline-only use
            Button("Continue without signing in") {
                // Set a local-only flag; features requiring auth will prompt later
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding()
    }
}
```

---

## 8. Face ID / Touch ID Re-Authentication

### 8.1 Strategy

Biometric re-auth is a **second layer** on top of primary auth, not a replacement. The flow:

1. User signs in with Apple → tokens stored in Keychain
2. App is backgrounded and returns to foreground after `HoopTrack.Auth.biometricTimeoutSeconds` (default: 60)
3. App presents biometric prompt
4. On success: restore the existing authenticated session (no new network call needed)
5. On failure / cancel: show a locked screen with a "Try Again" button

### 8.2 BiometricService

```swift
// Phase 6 — Auth
// BiometricService.swift

import LocalAuthentication
import Foundation

@MainActor
final class BiometricService: ObservableObject {

    @Published private(set) var isLocked: Bool = false

    private var backgroundedAt: Date?

    // MARK: - Lifecycle hooks (call from App/SceneDelegate)

    func appDidBackground() {
        backgroundedAt = Date()
    }

    func appWillForeground() {
        guard let backgroundedAt else { return }
        let elapsed = Date().timeIntervalSince(backgroundedAt)
        if elapsed > HoopTrack.Auth.biometricTimeoutSeconds {
            isLocked = true
        }
        self.backgroundedAt = nil
    }

    // MARK: - Evaluate

    func evaluateBiometric() async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                        error: &error) else {
            // Device has no biometrics — fall back to passcode
            return await evaluatePasscode(context: context)
        }
        do {
            let result = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "Unlock HoopTrack to continue"
            )
            if result { isLocked = false }
            return result
        } catch {
            return false
        }
    }

    private func evaluatePasscode(context: LAContext) async -> Bool {
        do {
            let result = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Unlock HoopTrack to continue"
            )
            if result { isLocked = false }
            return result
        } catch {
            return false
        }
    }
}
```

Add to `Constants.swift`:

```swift
// Inside enum HoopTrack — Phase 6 (Auth)
enum Auth {
    /// Seconds of backgrounding before biometric re-auth is required.
    static let biometricTimeoutSeconds: TimeInterval = 60
}
```

### 8.3 Scene Phase Observation

Observe scene phase changes in `HoopTrackApp` or via `onChange` in `AuthGate`:

```swift
// In AuthGate or a top-level view modifier
.onChange(of: scenePhase) { _, newPhase in
    switch newPhase {
    case .background:  biometricService.appDidBackground()
    case .active:      biometricService.appWillForeground()
    default:           break
    }
}
```

### 8.4 Lock Screen

```swift
// Phase 6 — Auth
struct LockedView: View {
    @EnvironmentObject private var biometricService: BiometricService

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.fill")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text("HoopTrack is locked")
                .font(.title3.bold())
            Button("Unlock with Face ID / Touch ID") {
                Task { await biometricService.evaluateBiometric() }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
```

Show `LockedView` as an overlay inside `AuthGate` when `biometricService.isLocked && authViewModel.state.isAuthenticated`.

---

## 9. Sign Out and Data Handling

### 9.1 Policy Decision

When the user signs out, **local SwiftData is kept by default**. Rationale:

- The user's training data is their own regardless of account state
- Clearing data on sign-out would be a surprising and destructive default
- On next sign-in (same or new account), the `supabaseUserID` on `PlayerProfile` is updated and cloud sync re-established

The "Clear local data on sign out" option is provided as an explicit, destructive action behind a confirmation dialog — not the default path.

### 9.2 Sign-Out Flow

```swift
// Triggered from ProfileTabView settings
func signOutTapped(clearLocalData: Bool) async {
    // Confirm destructive action before proceeding
    await authViewModel.signOut(clearLocalData: clearLocalData)

    // Reset onboarding gate so user can set a new name for a fresh account
    if clearLocalData {
        UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
    }
}
```

### 9.3 DataService.deleteAllUserData()

Add to `DataService` for the destructive clear-on-sign-out path:

```swift
// DataService.swift — Phase 6 (Auth)
func deleteAllUserData() throws {
    // Order matters: delete children before parents to avoid orphan references
    let shots    = try modelContext.fetch(FetchDescriptor<ShotRecord>())
    let badges   = try modelContext.fetch(FetchDescriptor<EarnedBadge>())
    let goals    = try modelContext.fetch(FetchDescriptor<GoalRecord>())
    let sessions = try modelContext.fetch(FetchDescriptor<TrainingSession>())
    let profiles = try modelContext.fetch(FetchDescriptor<PlayerProfile>())

    (shots + badges + goals + sessions + profiles).forEach {
        modelContext.delete($0)
    }
    try modelContext.save()
}
```

---

## 10. Testing Approach

### 10.1 Protocol-Based Injection

The existing architecture uses concrete classes. For testability of `AuthViewModel`, introduce an `AuthProviding` protocol:

```swift
// Phase 6 — Auth
protocol AuthProviding {
    func signInWithApple() async throws -> AuthSession
    func signOut() async throws
    func restoreSession() async throws -> AuthSession?
}

struct AuthSession {
    let userID: String
    let accessToken: String
    let refreshToken: String
}
```

`AuthViewModel` depends on `any AuthProviding` rather than `SupabaseClient` directly. `SupabaseAuthProvider` wraps the real Supabase calls; `MockAuthProvider` is used in tests.

### 10.2 MockAuthProvider

```swift
// HoopTrackTests/Mocks/MockAuthProvider.swift
import Foundation
@testable import HoopTrack

final class MockAuthProvider: AuthProviding {

    var shouldSucceed = true
    var stubbedUserID = "test-user-123"
    var signInCallCount = 0
    var signOutCallCount = 0

    func signInWithApple() async throws -> AuthSession {
        signInCallCount += 1
        if shouldSucceed {
            return AuthSession(
                userID: stubbedUserID,
                accessToken: "mock-access",
                refreshToken: "mock-refresh"
            )
        }
        throw URLError(.userAuthenticationRequired)
    }

    func signOut() async throws {
        signOutCallCount += 1
        if !shouldSucceed {
            throw URLError(.networkConnectionLost)
        }
    }

    func restoreSession() async throws -> AuthSession? {
        return shouldSucceed
            ? AuthSession(userID: stubbedUserID,
                          accessToken: "mock-access",
                          refreshToken: "mock-refresh")
            : nil
    }
}
```

### 10.3 AuthViewModel Unit Tests

```swift
// HoopTrackTests/AuthViewModelTests.swift
import XCTest
@testable import HoopTrack

@MainActor
final class AuthViewModelTests: XCTestCase {

    private func makeViewModel(succeed: Bool = true) -> (AuthViewModel, MockAuthProvider) {
        let mock = MockAuthProvider()
        mock.shouldSucceed = succeed
        // Inject mock into AuthViewModel via protocol dependency
        let vm = AuthViewModel(authProvider: mock, dataService: makeMockDataService())
        return (vm, mock)
    }

    func test_initialState_isUnauthenticated() {
        let (vm, _) = makeViewModel()
        XCTAssertEqual(vm.state, .unauthenticated)
    }

    func test_signInSuccess_transitionsToAuthenticated() async {
        let (vm, mock) = makeViewModel(succeed: true)
        await vm.signInWithApple()
        XCTAssertEqual(vm.state, .authenticated(userID: mock.stubbedUserID))
        XCTAssertEqual(mock.signInCallCount, 1)
    }

    func test_signInFailure_transitionsToError() async {
        let (vm, _) = makeViewModel(succeed: false)
        await vm.signInWithApple()
        if case .error = vm.state { /* pass */ }
        else { XCTFail("Expected error state, got \(vm.state)") }
    }

    func test_signOut_transitionsToUnauthenticated() async {
        let (vm, _) = makeViewModel(succeed: true)
        await vm.signInWithApple()
        await vm.signOut()
        XCTAssertEqual(vm.state, .unauthenticated)
        XCTAssertNil(vm.currentUserID)
    }

    func test_restoreSession_whenTokensPresent_transitionsToAuthenticated() async {
        let (vm, mock) = makeViewModel(succeed: true)
        await vm.restoreSession()
        XCTAssertEqual(vm.state, .authenticated(userID: mock.stubbedUserID))
    }

    func test_restoreSession_whenTokensAbsent_remainsUnauthenticated() async {
        let (vm, _) = makeViewModel(succeed: false)
        await vm.restoreSession()
        XCTAssertEqual(vm.state, .unauthenticated)
    }
}
```

### 10.4 KeychainService Tests

`KeychainService` uses the real Keychain in tests (the simulator has a Keychain). Test the round-trip:

```swift
// HoopTrackTests/KeychainServiceTests.swift
import XCTest
@testable import HoopTrack

final class KeychainServiceTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
        KeychainService.deleteAll()
    }

    func test_saveAndRead_roundTrip() throws {
        try KeychainService.save("token-abc", for: .accessToken)
        let retrieved = try KeychainService.read(.accessToken)
        XCTAssertEqual(retrieved, "token-abc")
    }

    func test_readMissingKey_throwsItemNotFound() {
        XCTAssertThrowsError(try KeychainService.read(.accessToken)) { error in
            XCTAssertEqual(error as? KeychainError, .itemNotFound)
        }
    }

    func test_overwrite_replacesValue() throws {
        try KeychainService.save("old",  for: .accessToken)
        try KeychainService.save("new",  for: .accessToken)
        XCTAssertEqual(try KeychainService.read(.accessToken), "new")
    }

    func test_delete_removesItem() throws {
        try KeychainService.save("token", for: .accessToken)
        KeychainService.delete(.accessToken)
        XCTAssertThrowsError(try KeychainService.read(.accessToken))
    }
}
```

### 10.5 What Not to Test Here

- The `ASAuthorizationController` flow is system UI — test manually on device
- `LAContext` biometric evaluation — mock `BiometricService.evaluateBiometric()` at the call site in integration tests
- Supabase network calls — covered by `MockAuthProvider` above; no real network calls in unit tests

---

## File Locations Summary

| New file | Path |
|---|---|
| `SignInWithAppleCoordinator.swift` | `HoopTrack/Auth/SignInWithAppleCoordinator.swift` |
| `AuthViewModel.swift` | `HoopTrack/Auth/AuthViewModel.swift` |
| `AuthState.swift` | `HoopTrack/Auth/AuthState.swift` |
| `AuthProviding.swift` (protocol) | `HoopTrack/Auth/AuthProviding.swift` |
| `SupabaseAuthProvider.swift` | `HoopTrack/Auth/SupabaseAuthProvider.swift` |
| `KeychainService.swift` | `HoopTrack/Auth/KeychainService.swift` |
| `BiometricService.swift` | `HoopTrack/Auth/BiometricService.swift` |
| `AuthGate.swift` | `HoopTrack/Views/Auth/AuthGate.swift` |
| `SignInView.swift` | `HoopTrack/Views/Auth/SignInView.swift` |
| `LockedView.swift` | `HoopTrack/Views/Auth/LockedView.swift` |
| `SupabaseClient+Shared.swift` | `HoopTrack/Auth/SupabaseClient+Shared.swift` |
| `HoopTrackSchemaV3.swift` (add to existing migration file) | `HoopTrack/Models/Migrations/HoopTrackSchemaV1.swift` |
| `MockAuthProvider.swift` | `HoopTrackTests/Mocks/MockAuthProvider.swift` |
| `AuthViewModelTests.swift` | `HoopTrackTests/AuthViewModelTests.swift` |
| `KeychainServiceTests.swift` | `HoopTrackTests/KeychainServiceTests.swift` |

## Modified Files

| Modified file | Changes |
|---|---|
| `PlayerProfile.swift` | Add `var supabaseUserID: String?` |
| `HoopTrackApp.swift` | Add `AuthViewModel` StateObject, `AuthBox`, replace root view with `AuthGate` |
| `CoordinatorHost.swift` | Accept `AuthViewModel` environment object if needed for sign-out nav |
| `HoopTrackMigrationPlan.swift` | Add V3 schema and lightweight stage |
| `HoopTrackSchemaV1.swift` | Add `HoopTrackSchemaV3` |
| `DataService.swift` | Add `deleteAllUserData()` |
| `Constants.swift` | Add `HoopTrack.Backend` and `HoopTrack.Auth` namespaces |
