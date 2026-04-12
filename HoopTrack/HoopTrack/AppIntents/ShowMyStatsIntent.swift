// ShowMyStatsIntent.swift
// Opens HoopTrack and navigates to the Progress tab.
// ForegroundContinuableIntent pauses execution in Siri until the app
// is in the foreground, then fires the deep link.

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
        guard let url = URL(string: "hooptrack://progress") else { return .result() }
        await UIApplication.shared.open(url)
        return .result()
    }
}
