// ContentView.swift
// Root view — four-tab navigation shell.
//
// Tabs: Home (Dashboard) | Train | Progress | Profile
// Each tab owns its own NavigationStack so back-stacks are independent.

import SwiftUI

struct ContentView: View {

    @EnvironmentObject private var appState: AppState

    var body: some View {
        TabView(selection: $appState.selectedTab) {

            // MARK: Home — Dashboard
            NavigationStack {
                HomeTabView()
            }
            .tabItem {
                Label("Home", systemImage: "house.fill")
            }
            .tag(AppTab.home)

            // MARK: Train — Drill Picker / Live Session
            NavigationStack {
                TrainTabView()
            }
            .tabItem {
                Label("Train", systemImage: "basketball.fill")
            }
            .tag(AppTab.train)

            // MARK: Progress — Analytics & Charts
            NavigationStack {
                ProgressTabView()
            }
            .tabItem {
                Label("Progress", systemImage: "chart.line.uptrend.xyaxis")
            }
            .tag(AppTab.progress)

            // MARK: Profile — History & Settings
            NavigationStack {
                ProfileTabView()
            }
            .tabItem {
                Label("Profile", systemImage: "person.fill")
            }
            .tag(AppTab.profile)
        }
        .tint(.orange)   // Brand accent colour
    }
}

// MARK: - AppTab
enum AppTab: Hashable {
    case home, train, progress, profile
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
