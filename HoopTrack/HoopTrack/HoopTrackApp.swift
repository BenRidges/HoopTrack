// HoopTrackApp.swift
// HoopTrack — Personal Basketball Progress Tracker
// SwiftUI + SwiftData | MVVM + Combine
//
// Entry point. Builds AppServices once, injects it, and routes deep links.
// No account is needed to use the app: signing in only adds cloud backup.

import SwiftUI
import UIKit
import SwiftData

// MARK: - Orientation Lock
/// Which interface orientations the app allows right now. The app is
/// portrait except for the live shooting session, which forces landscape
/// via LandscapeHostingController.
///
/// Landscape means landscape-right only: the capture connection is fixed
/// at 0° (sensor-native), so in the other landscape the picture — and the
/// shot tracker's idea of "up" — would be upside down.
enum OrientationLock {
    enum Mode {
        case portraitOnly
        case landscapeRight
    }

    @MainActor static var mode: Mode = .portraitOnly
}

// MARK: - App Delegate (Orientation Gate)
final class HoopTrackAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        switch OrientationLock.mode {
        case .portraitOnly:   return .portrait
        case .landscapeRight: return .landscapeRight
        }
    }
}

@main
struct HoopTrackApp: App {
    @UIApplicationDelegateAdaptor(HoopTrackAppDelegate.self) var appDelegate

    @StateObject private var services = AppServices()
    @StateObject private var authViewModel = AuthViewModel(provider: SupabaseAuthProvider())
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .appEnvironment(services, auth: authViewModel)
                .task {
                    services.appLock.lockAtLaunchIfEnabled()
                    services.onLaunch()
                    await authViewModel.restore()
                }
                .onChange(of: scenePhase) { _, phase in
                    services.appLock.sceneChanged(to: phase)
                }
                .onChange(of: authViewModel.state) { old, new in
                    if case .authenticated(let user) = new, user.emailVerified {
                        try? services.dataService.linkSupabaseUser(id: user.id.uuidString)
                    } else if case .unauthenticated = new, case .authenticated = old {
                        // Explicit sign-out only — a failed offline restore keeps the link.
                        services.dataService.unlinkSupabaseUser()
                    }
                }
                .onOpenURL { url in
                    // Supabase email confirmation lands here first; anything
                    // else is an in-app deep link (Siri, notifications).
                    if url.scheme?.lowercased() == "hooptrack", url.host?.lowercased() == "auth" {
                        Task { await authViewModel.handleDeepLink(url) }
                    } else {
                        services.appState.handleDeepLink(url)
                    }
                }
        }
    }
}
