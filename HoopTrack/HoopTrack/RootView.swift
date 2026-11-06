// RootView.swift
// Onboarding → three tabs (Train, Progress, Profile). Live sessions are
// presented from here so any screen — or Siri — can start one by setting
// `AppState.activeLaunch`.

import SwiftUI
import UIKit

struct RootView: View {

    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var appLock: AppLock
    @EnvironmentObject private var authViewModel: AuthViewModel
    @AppStorage(AppPreferences.Key.hasCompletedOnboarding) private var hasCompletedOnboarding = false

    var body: some View {
        ZStack {
            if hasCompletedOnboarding {
                tabs
            } else {
                OnboardingView { hasCompletedOnboarding = true }
                    .transition(.opacity)
            }

            if appLock.isLocked {
                LockedView()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: appLock.isLocked)
        .animation(.easeInOut(duration: 0.3), value: hasCompletedOnboarding)
        .fullScreenCover(item: $appState.activeLaunch, onDismiss: {
            Orientation.restorePortrait()
            appState.sessionCoverDismissed()
        }) { launch in
            session(for: launch)
        }
        .sheet(item: $appState.presentedSummary) { completed in
            SessionSummaryView(result: completed.result)
        }
    }

    private var tabs: some View {
        TabView(selection: $appState.selectedTab) {
            NavigationStack { TrainTabView() }
                .tabItem { Label("Train", systemImage: "basketball.fill") }
                .tag(AppTab.train)

            NavigationStack { ProgressTabView() }
                .tabItem { Label("Progress", systemImage: "chart.xyaxis.line") }
                .tag(AppTab.progress)

            NavigationStack { ProfileTabView() }
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
                .tag(AppTab.profile)
        }
    }

    @ViewBuilder
    private func session(for launch: TrainingLaunch) -> some View {
        let finish: (SessionResult?) -> Void = { appState.finishSession(with: $0) }
        switch launch {
        case .shooting(let drill):
            LandscapeContainer {
                LiveSessionView(namedDrill: drill, onFinish: finish)
                    .appEnvironment(services, auth: authViewModel)
            }
            .ignoresSafeArea()
        case .dribble(let drill):
            DribbleDrillView(namedDrill: drill, onFinish: finish)
        case .agility(let drill):
            AgilitySessionView(namedDrill: drill, onFinish: finish)
        case .game:
            GameFlowView(onFinish: { appState.finishSession(with: nil) })
        case .playoff(let id):
            LandscapeContainer {
                LiveSessionView(namedDrill: nil, playoffSeriesID: id, onFinish: finish)
                    .appEnvironment(services, auth: authViewModel)
            }
            .ignoresSafeArea()
        }
    }
}

// MARK: - Orientation helpers

@MainActor
enum Orientation {
    /// Puts the app back to portrait after a landscape session.
    static func restorePortrait() {
        OrientationLock.mode = .portraitOnly
        request(.portrait, from: nil)
    }

    /// Asks the scene to rotate. The app delegate's mask (OrientationLock)
    /// must already allow `mask`, and UIKit must re-read it first.
    static func request(_ mask: UIInterfaceOrientationMask, from scene: UIWindowScene?) {
        guard let scene = scene ?? UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else { return }
        for window in scene.windows {
            var controller = window.rootViewController
            while let current = controller {
                current.setNeedsUpdateOfSupportedInterfaceOrientations()
                controller = current.presentedViewController
            }
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in
            // Non-fatal: the system can decline (e.g. iPad multitasking).
        }
    }
}
