// AppState.swift
// Shared navigation state. Injected at root; lets HoopTrackApp route deep
// links to the correct tab without coupling ContentView to URL parsing.

import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {

    @Published var selectedTab: AppTab = .home

    // MARK: - Deep Link Routing

    /// Handles `hooptrack://` URLs from Siri Shortcuts and notification taps.
    /// Add new routes here as the app grows — no other file needs to change.
    func handleDeepLink(_ url: URL) {
        guard url.scheme?.lowercased() == "hooptrack" else { return }
        switch url.host?.lowercased() {
        case "train":    selectedTab = .train
        case "progress": selectedTab = .progress
        case "profile":  selectedTab = .profile
        default:         break   // unknown host — stay on current tab
        }
    }
}
