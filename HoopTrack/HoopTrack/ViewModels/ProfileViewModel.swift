// ProfileViewModel.swift
// Drives the Profile tab — player info editing, session history log,
// settings (iCloud, video retention), and data export.

import Foundation
import Combine

@MainActor
final class ProfileViewModel: ObservableObject {

    // MARK: - Published
    @Published var profile: PlayerProfile?
    @Published var sessions: [TrainingSession] = []

    // Editing state
    @Published var editingName: String = ""
    @Published var isEditingName: Bool = false

    // Filters
    @Published var historyFilter: DrillType? = nil
    @Published var historySortAscending: Bool = false

    // Settings
    @Published var isShowingDeleteConfirm: Bool = false
    @Published var errorMessage: String?

    // MARK: - Dependencies
    private let dataService: DataService

    init(dataService: DataService) {
        self.dataService = dataService
    }

    // MARK: - Load

    func load() {
        do {
            profile  = try dataService.fetchOrCreateProfile()
            sessions = try dataService.fetchSessions()
            // Apply name entered during onboarding if the profile has no name yet
            if let storedName = UserDefaults.standard.string(forKey: "onboardingPlayerName"),
               !storedName.isEmpty,
               (profile?.name ?? "").isEmpty {
                profile?.name = storedName
                UserDefaults.standard.removeObject(forKey: "onboardingPlayerName")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Name Editing

    func beginEditName() {
        editingName   = profile?.name ?? ""
        isEditingName = true
    }

    func saveName() {
        // Phase 7 — Security: sanitise before writing to SwiftData model
        if let sanitised = InputValidator.sanitisedProfileName(editingName) {
            profile?.name = sanitised
        }
        isEditingName = false
        // SwiftData persists automatically via @Model observation
    }

    // MARK: - Settings

    func toggleICloudSync(_ enabled: Bool) {
        profile?.iCloudSyncEnabled = enabled
        // Phase 6: trigger CloudKit sync initialisation / teardown
    }

    func setVideoRetentionDays(_ days: Int) {
        profile?.videosAutoDeleteDays = days
    }

    // MARK: - Session History (filtered view)

    var filteredSessions: [TrainingSession] {
        var result = sessions
        if let filter = historyFilter {
            result = result.filter { $0.drillType == filter }
        }
        return result.sorted {
            historySortAscending
                ? $0.startedAt < $1.startedAt
                : $0.startedAt > $1.startedAt
        }
    }

    func deleteSession(_ session: TrainingSession) {
        do {
            try dataService.deleteSession(session)
            sessions.removeAll { $0.id == session.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - GDPR / Right to Delete (Phase 7)

    /// Permanently erases all user data: SwiftData records, session videos,
    /// Keychain entries, and app UserDefaults keys.
    /// NOTE: HealthKit workout records written by HealthKitService are NOT
    /// deleted — users must remove those manually via the Health app.
    func deleteAllData() async {
        await dataService.deleteAllUserData()
        profile  = nil
        sessions = []
    }

    // MARK: - Stats Summary

    var totalSessions: Int    { profile?.totalSessionCount ?? 0 }
    var totalMinutes:  Double { profile?.totalTrainingMinutes ?? 0 }
    var careerFG:      String { String(format: "%.1f%%", profile?.careerFGPercent ?? 0) }
    var badgeCount: Int { profile?.earnedBadges.count ?? 0 }
}
