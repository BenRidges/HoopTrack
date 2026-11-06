// NotificationService.swift
// Local notifications: the optional daily training reminder (Profile →
// Training) and goal milestones. Permission is only asked for when the
// reminder is switched on.

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
        // Phase 7 — Security: @MainActor class must not use DispatchQueue.main.async
        center.getNotificationSettings { [weak self] settings in
            Task { @MainActor [weak self] in
                self?.authorizationStatus = settings.authorizationStatus
            }
        }
    }

    // MARK: - Training Reminder

    /// A nudge at `hour` on each of the next two weeks, skipping today if
    /// you've already trained. Re-run at launch and after every session so
    /// the window keeps rolling and a session silences that day's nudge.
    /// (The old repeating trigger went off even after you'd trained.)
    func scheduleTrainingReminders(hour: Int, trainedToday: Bool) {
        cancelTrainingReminder()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        for offset in 0..<14 where !(offset == 0 && trainedToday) {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let fire = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day),
                  fire > .now else { continue }
            let content = UNMutableNotificationContent()
            content.title = "Get some shots up"
            content.body = "Nothing logged today yet. Even ten minutes counts."
            content.sound = .default
            let when = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
            center.add(UNNotificationRequest(
                identifier: Self.reminderID(for: day, calendar: calendar),
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false)))
        }
    }

    /// Reschedules from the saved preference, if the reminder is on.
    func refreshTrainingReminders(trainedToday: Bool) {
        guard AppPreferences.trainingReminderEnabled else { return }
        scheduleTrainingReminders(hour: AppPreferences.trainingReminderHour, trainedToday: trainedToday)
    }

    func cancelTrainingReminder() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        // IDs are per date, so today's window covers everything still pending
        // from earlier windows. The bare ID is the old repeating reminder.
        let ids = (0..<14).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
            .map { Self.reminderID(for: $0, calendar: calendar) }
        center.removePendingNotificationRequests(withIdentifiers: ids + [NotificationID.trainingReminder])
    }

    private static func reminderID(for day: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: day)
        return "\(NotificationID.trainingReminder).\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    // MARK: - Milestone Alerts

    /// Fires an immediate notification for each newly crossed 50/75/100% milestone.
    /// Updates `goal.lastMilestoneNotified` in place (caller must save ModelContext).
    func checkMilestones(for goals: [GoalRecord]) {
        for goal in goals {
            for threshold in [50, 75, 100] where threshold > goal.lastMilestoneNotified {
                guard goal.progressPercent >= threshold else { continue }

                let content = UNMutableNotificationContent()
                if threshold == 100 {
                    content.title = "Goal Achieved!"
                    content.body  = "You've hit your goal: \(goal.title)"
                    content.sound = .defaultRingtone
                } else {
                    content.title = "\(threshold)% There!"
                    content.body  = "You're \(threshold)% of the way to: \(goal.title)"
                    content.sound = .default
                }

                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
                let id      = "\(NotificationID.goalMilestone).\(goal.id.uuidString).\(threshold)"
                center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
                goal.lastMilestoneNotified = threshold
            }
        }
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
    static let trainingReminder = "com.hooptrack.notification.training"
    static let goalMilestone    = "com.hooptrack.notification.milestone"
}
