// StartFreeShootSessionIntent.swift
// Opens HoopTrack and navigates to the Train tab.
// ForegroundContinuableIntent pauses execution in Siri until the app
// is in the foreground, then fires the deep link.

import AppIntents
import UIKit

struct StartFreeShootSessionIntent: AppIntent, ForegroundContinuableIntent {

    static let title: LocalizedStringResource = "Start a free shoot session"
    static let description = IntentDescription(
        "Opens HoopTrack and navigates to the Train tab.",
        categoryName: "Training"
    )

    @MainActor
    func perform() async throws -> some IntentResult {
        try await requestToContinueInForeground()
        guard let url = URL(string: "hooptrack://train") else { return .result() }
        await UIApplication.shared.open(url)
        return .result()
    }
}
