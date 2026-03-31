// NotificationService.swift
// Manages UNUserNotificationCenter for streak reminders, goal milestones,
// and daily mission suggestions.

import UserNotifications
import Combine

@MainActor
final class NotificationService: NSObject, ObservableObject {

    @Published var authorizationStatus: UNAuthorizationStatus = .notDetermined

    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
        refreshStatus()
    }

    // MARK: - Permission

    func requestPermission() async {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            authorizationStatus = granted ? .authorized : .denied
        } catch {
            authorizationStatus = .denied
        }
    }

    private func refreshStatus() {
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                self?.authorizationStatus = settings.authorizationStatus
            }
        }
    }

    // MARK: - Streak Reminder

    /// Schedules a daily streak reminder at the given hour (24h, default 18 = 6pm).
    func scheduleStreakReminder(hour: Int = 18) {
        center.removePendingNotificationRequests(withIdentifiers: [NotificationID.streakReminder])

        let content          = UNMutableNotificationContent()
        content.title        = "Keep Your Streak Alive 🏀"
        content.body         = "You haven't trained today. Lace up and log a session!"
        content.sound        = .default
        content.categoryIdentifier = NotificationID.streakReminder

        var components       = DateComponents()
        components.hour      = hour
        components.minute    = 0
        let trigger          = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)

        let request = UNNotificationRequest(identifier: NotificationID.streakReminder,
                                            content: content,
                                            trigger: trigger)
        center.add(request)
    }

    func cancelStreakReminder() {
        center.removePendingNotificationRequests(withIdentifiers: [NotificationID.streakReminder])
    }

    // MARK: - Goal Milestone

    func sendGoalAchievedNotification(goalTitle: String) {
        let content      = UNMutableNotificationContent()
        content.title    = "Goal Achieved! 🎯"
        content.body     = "You've hit your goal: \(goalTitle)"
        content.sound    = .defaultRingtone

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let id      = "\(NotificationID.goalAchieved).\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        center.add(request)
    }

    // MARK: - Daily Mission

    /// Schedules a morning mission push at 8am with the suggested drill name.
    func scheduleDailyMission(drillName: String, weakestSkill: SkillDimension) {
        center.removePendingNotificationRequests(withIdentifiers: [NotificationID.dailyMission])

        let content      = UNMutableNotificationContent()
        content.title    = "Today's Mission 💪"
        content.body     = "Focus on your \(weakestSkill.rawValue.lowercased()). Try: \(drillName)"
        content.sound    = .default

        var components   = DateComponents()
        components.hour  = 8
        components.minute = 0
        let trigger      = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)

        let request = UNNotificationRequest(identifier: NotificationID.dailyMission,
                                            content: content,
                                            trigger: trigger)
        center.add(request)
    }

    // MARK: - Cancel All

    func cancelAll() {
        center.removeAllPendingNotificationRequests()
    }
}

// MARK: - UNUserNotificationCenterDelegate
extension NotificationService: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                 willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        // Show banner even if app is in foreground
        return [.banner, .sound]
    }
}

// MARK: - Notification Identifiers
private enum NotificationID {
    static let streakReminder = "com.hooptrack.notification.streak"
    static let goalAchieved   = "com.hooptrack.notification.goal"
    static let dailyMission   = "com.hooptrack.notification.mission"
}
