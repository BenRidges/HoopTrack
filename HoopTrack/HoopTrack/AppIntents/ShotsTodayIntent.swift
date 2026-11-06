// ShotsTodayIntent.swift
// Background intent — queries today's shot count and returns a spoken response.
// Does NOT require the app to be in the foreground.

import AppIntents
import SwiftData

struct ShotsTodayIntent: AppIntent {

    static let title: LocalizedStringResource = "How many shots today?"
    static let description = IntentDescription(
        "Tells you how many shots you've taken today.",
        categoryName: "Stats"
    )

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let dataService = DataService(modelContext: HoopTrackStore.shared.mainContext)
        let count       = try dataService.fetchShotsTodayCount()

        let response: String
        switch count {
        case 0:  response = "You haven't taken any shots today. Time to get on the court!"
        case 1:  response = "You've taken 1 shot today."
        default: response = "You've taken \(count) shots today."
        }
        return .result(value: response)
    }
}
