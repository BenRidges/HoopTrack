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
        profile?.name = editingName
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

    // MARK: - Export
    // Phase 6: generate CSV from all sessions + shots and present UIActivityViewController.
    func exportData() -> String {
        var csv = "session_id,date,drill,fg_percent,shots_made,shots_attempted,duration_s\n"
        for s in sessions {
            let dateStr = ISO8601DateFormatter().string(from: s.startedAt)
            csv += "\(s.id),\(dateStr),\(s.drillType.rawValue),\(s.fgPercent),\(s.shotsMade),\(s.shotsAttempted),\(s.durationSeconds)\n"
        }
        return csv
    }

    // MARK: - Stats Summary

    var totalSessions: Int    { profile?.totalSessionCount ?? 0 }
    var totalMinutes:  Double { profile?.totalTrainingMinutes ?? 0 }
    var careerFG:      String { String(format: "%.1f%%", profile?.careerFGPercent ?? 0) }
    var badgeCount: Int { profile?.earnedBadges.count ?? 0 }
}
