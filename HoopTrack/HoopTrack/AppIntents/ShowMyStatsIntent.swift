// ShowMyStatsIntent.swift
// Opens HoopTrack and navigates to the Progress tab.

import AppIntents
import UIKit

struct ShowMyStatsIntent: AppIntent, ForegroundContinuableIntent {

    static let title: LocalizedStringResource = "Show my stats"
    static let description = IntentDescription(
        "Opens HoopTrack and shows your progress and stats.",
        categoryName: "Progress"
    )

    @MainActor
    func perform() async throws -> some IntentResult {
        try await requestToContinueInForeground()
        await UIApplication.shared.open(URL(string: "hooptrack://progress")!)
        return .result()
    }
}
