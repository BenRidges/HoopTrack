// HoopTrackShortcuts.swift
// Single registration point for all Siri Shortcuts.
// To add a new shortcut: create a new AppIntent file, then add one
// AppShortcut entry here. No other files need to change.

import AppIntents

struct HoopTrackShortcuts: AppShortcutsProvider {

    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {

        AppShortcut(
            intent: StartFreeShootSessionIntent(),
            phrases: [
                "Start a free shoot session in \(.applicationName)",
                "Start shooting in \(.applicationName)",
                "Begin a shooting session in \(.applicationName)"
            ],
            shortTitle: "Free Shoot",
            systemImageName: "basketball.fill"
        )

        AppShortcut(
            intent: ShowMyStatsIntent(),
            phrases: [
                "Show my stats in \(.applicationName)",
                "Open my progress in \(.applicationName)",
                "My basketball stats in \(.applicationName)"
            ],
            shortTitle: "My Stats",
            systemImageName: "chart.line.uptrend.xyaxis"
        )

        AppShortcut(
            intent: ShotsTodayIntent(),
            phrases: [
                "How many shots today in \(.applicationName)",
                "Shots today in \(.applicationName)",
                "How many shots have I taken in \(.applicationName)"
            ],
            shortTitle: "Shots Today",
            systemImageName: "basketball"
        )
    }
}
