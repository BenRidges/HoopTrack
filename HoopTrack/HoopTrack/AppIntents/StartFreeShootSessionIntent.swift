// StartFreeShootSessionIntent.swift
// Opens HoopTrack and navigates to a live free shoot session.
// ForegroundContinuableIntent pauses execution in Siri until the app
// is in the foreground, then fires the deep link.

import AppIntents
import UIKit

struct StartFreeShootSessionIntent: AppIntent, ForegroundContinuableIntent {

    static let title: LocalizedStringResource = "Start a free shoot session"
    static let description = IntentDescription(
        "Opens HoopTrack and starts a free shoot session.",
        categoryName: "Training"
    )

    @MainActor
    func perform() async throws -> some IntentResult {
        try await requestToContinueInForeground()
        await UIApplication.shared.open(URL(string: "hooptrack://train/freeshoot")!)
        return .result()
    }
}
