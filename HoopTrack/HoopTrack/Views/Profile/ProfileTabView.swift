// ProfileTabView.swift
// You, your career numbers, and settings. Every control here does
// something — the old iCloud toggle and notification switches were stubs.

import SwiftUI
import UIKit
import SwiftData
import UserNotifications

struct ProfileTabView: View {

    @EnvironmentObject private var dataService: DataService
    @EnvironmentObject private var coordinator: SessionFinalizationCoordinator
    @EnvironmentObject private var notificationService: NotificationService
    @EnvironmentObject private var authViewModel: AuthViewModel
    @EnvironmentObject private var appLock: AppLock
    @Query(sort: \PlayerProfile.createdAt) private var profiles: [PlayerProfile]

    @AppStorage(AppPreferences.Key.healthKitEnabled) private var healthKitEnabled = false
    @AppStorage(AppPreferences.Key.appLockEnabled) private var appLockEnabled = false
    @AppStorage(AppPreferences.Key.shareTrainingData) private var shareTrainingData = false
    @AppStorage(AppPreferences.Key.showDetectionBoxes) private var showDetectionBoxes = false
    @AppStorage(AppPreferences.Key.trainingReminderEnabled) private var reminderEnabled = false
    @AppStorage(AppPreferences.Key.trainingReminderHour) private var reminderHour = 17

    @State private var editingName = false
    @State private var draftName = ""
    @State private var showAccount = false
    @State private var confirmDeleteAll = false
    @State private var confirmDeleteAccount = false
    @State private var isDeleting = false
    @State private var deleteError: String?
    @State private var exportURL: URL?
    @State private var exportError: String?
    @State private var isExporting = false

    private var profile: PlayerProfile? { profiles.first }

    var body: some View {
        List {
            if let profile {
                Section { header(profile) }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())

                Section("Career") { career(profile) }
                    .listRowBackground(Color.panel)

                Section {
                    training(profile)
                } header: {
                    Text("Training")
                }
                .listRowBackground(Color.panel)
            }

            Section {
                account
            } header: {
                Text("Cloud backup")
            } footer: {
                Text("Optional. Your sessions are always saved on this phone.")
            }
            .listRowBackground(Color.panel)

            Section {
                privacy
            } header: {
                Text("Privacy & data")
            } footer: {
                Text("When on, a sample of frames from your session videos (not the full videos) is uploaded so the shot detector can be retrained. Needs a cloud account. Off by default.")
            }
            .listRowBackground(Color.panel)

            Section {
                Toggle("Show detection boxes", isOn: $showDetectionBoxes)
            } header: {
                Text("Developer")
            } footer: {
                Text(versionText)
            }
            .listRowBackground(Color.panel)
        }
        .courtList()
        .navigationTitle("Profile")
        .tint(.leather)
        .onAppear { _ = try? dataService.fetchOrCreateProfile() }
        .sheet(isPresented: $showAccount) { AccountSheet() }
        .sheet(item: $exportURL) { url in
            ShareSheet(items: [url]).presentationDetents([.medium, .large])
        }
        .alert("Your name", isPresented: $editingName) {
            TextField("Name", text: $draftName)
            Button("Save") { dataService.setPlayerName(draftName) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Export failed", isPresented: Binding(get: { exportError != nil },
                                                    set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
        .confirmationDialog("Delete everything?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Delete all my data", role: .destructive) { deleteEverything() }
        } message: {
            Text(isSignedIn
                 ? "Every session, shot, goal, badge, game and video on this phone is erased, and your account and cloud backup are deleted. Workouts already saved to Apple Health stay there. This can't be undone."
                 : "Every session, shot, goal, badge, game and video on this phone is erased. Workouts already saved to Apple Health stay there. This can't be undone.")
        }
        .confirmationDialog("Delete your account?", isPresented: $confirmDeleteAccount, titleVisibility: .visible) {
            Button("Delete account", role: .destructive) {
                isDeleting = true
                Task {
                    deleteError = await authViewModel.deleteAccount()?.errorDescription
                    isDeleting = false
                }
            }
        } message: {
            Text("Your HoopTrack account and everything backed up to it are deleted. Sessions on this phone stay. This can't be undone.")
        }
        .alert("Couldn't delete", isPresented: Binding(get: { deleteError != nil },
                                                      set: { if !$0 { deleteError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("\(deleteError ?? "") Nothing was deleted; try again when you're online.")
        }
    }

    private var isSignedIn: Bool { authViewModel.state.isAuthenticated }

    /// The account goes first: if the server can't be reached, stop before
    /// wiping the phone, so the cloud copy isn't left behind unnoticed.
    private func deleteEverything() {
        isDeleting = true
        Task {
            if isSignedIn, let error = await authViewModel.deleteAccount() {
                deleteError = error.errorDescription
                isDeleting = false
                return
            }
            await dataService.deleteAllUserData()
            await authViewModel.signOut()
            notificationService.cancelAll()
            _ = try? dataService.fetchOrCreateProfile()
            isDeleting = false
        }
    }

    // MARK: - Header

    private func header(_ profile: PlayerProfile) -> some View {
        HStack(spacing: 16) {
            Text(initials(profile.name))
                .font(.system(size: 26, weight: .heavy).width(.compressed))
                .foregroundStyle(Color.onLeather)
                .frame(width: 64, height: 64)
                .background(Color.leather, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    draftName = profile.name == "Player" ? "" : profile.name
                    editingName = true
                } label: {
                    HStack(spacing: 6) {
                        Text(profile.name)
                            .font(.title2.bold())
                            .foregroundStyle(.primary)
                        Image(systemName: "pencil")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("Edit your name")
                Text("Training since \(profile.createdAt.formatted(.dateTime.month(.wide).year()))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }

    private func initials(_ name: String) -> String {
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    // MARK: - Career

    @ViewBuilder
    private func career(_ profile: PlayerProfile) -> some View {
        LabeledContent("Field goal", value: profile.careerShotsAttempted > 0
                       ? "\(Int(profile.careerFGPercent.rounded()))%  ·  \(profile.careerShotsMade)/\(profile.careerShotsAttempted)"
                       : "–")
        LabeledContent("Sessions", value: "\(profile.totalSessionCount)")
        LabeledContent("Time trained", value: hoursText(profile.totalTrainingMinutes))
        LabeledContent("Best session", value: profile.prBestFGPercentSession > 0
                       ? "\(Int(profile.prBestFGPercentSession.rounded()))%" : "–")
        LabeledContent("Most makes", value: "\(profile.prMostMakesSession)")
        LabeledContent("Longest streak", value: "\(profile.longestStreakDays) days")
    }

    private func hoursText(_ minutes: Double) -> String {
        minutes < 60 ? "\(Int(minutes)) min" : String(format: "%.1f h", minutes / 60)
    }

    // MARK: - Training settings

    @ViewBuilder
    private func training(_ profile: PlayerProfile) -> some View {
        Picker("Three-point line", selection: Binding(
            get: { profile.preferredCourtType },
            set: { profile.preferredCourtType = $0; try? dataService.modelContext.save() }
        )) {
            ForEach(CourtType.allCases) { Text($0.displayName).tag($0) }
        }
        Picker("Keep videos", selection: Binding(
            get: { profile.videosAutoDeleteDays },
            set: { profile.videosAutoDeleteDays = $0; try? dataService.modelContext.save() }
        )) {
            Text("7 days").tag(7)
            Text("14 days").tag(14)
            Text("30 days").tag(30)
            Text("Forever").tag(0)
        }
        Toggle("Daily reminder", isOn: $reminderEnabled)
            .onChange(of: reminderEnabled) { _, on in
                Task {
                    if on {
                        if notificationService.authorizationStatus == .notDetermined {
                            await notificationService.requestPermission()
                        }
                        guard notificationService.authorizationStatus == .authorized else {
                            reminderEnabled = false
                            return
                        }
                        notificationService.scheduleTrainingReminders(hour: reminderHour,
                                                                      trainedToday: dataService.hasTrainedToday)
                    } else {
                        notificationService.cancelTrainingReminder()
                    }
                }
            }
        if reminderEnabled {
            Picker("Remind me at", selection: $reminderHour) {
                ForEach(6..<23) { hour in
                    Text(hourLabel(hour)).tag(hour)
                }
            }
            .onChange(of: reminderHour) { _, hour in
                notificationService.scheduleTrainingReminders(hour: hour,
                                                              trainedToday: dataService.hasTrainedToday)
            }
        }
        Toggle("Save workouts to Apple Health", isOn: $healthKitEnabled)
            .onChange(of: healthKitEnabled) { _, on in
                if on { Task { await coordinator.requestHealthKitPermission() } }
            }
    }

    private func hourLabel(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        let date = Calendar.current.date(from: components) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }

    // MARK: - Account

    @ViewBuilder
    private var account: some View {
        switch authViewModel.state {
        case .authenticated(let user) where user.emailVerified:
            LabeledContent("Signed in", value: user.email)
            Button("Sign out") {
                Task { await authViewModel.signOut() }
            }
            Button(role: .destructive) {
                confirmDeleteAccount = true
            } label: {
                HStack {
                    Text("Delete account")
                    Spacer()
                    if isDeleting { ProgressView() }
                }
            }
            .disabled(isDeleting)
        case .authenticated:
            Button("Confirm your email") { showAccount = true }
        case .authenticating:
            HStack {
                Text("Checking…")
                Spacer()
                ProgressView()
            }
        case .unauthenticated, .error:
            Button("Sign in or create an account") { showAccount = true }
        }
    }

    // MARK: - Privacy

    @ViewBuilder
    private var privacy: some View {
        Toggle("Lock with Face ID", isOn: Binding(
            get: { appLockEnabled },
            set: { on in
                if on {
                    Task { appLockEnabled = await appLock.confirmEnable() }
                } else {
                    appLockEnabled = false
                }
            }
        ))
        Toggle("Help improve shot tracking", isOn: $shareTrainingData)
        Button {
            export()
        } label: {
            HStack {
                Text("Export my data")
                Spacer()
                if isExporting { ProgressView() }
            }
        }
        .disabled(isExporting || profile == nil)
        Button("Delete all my data", role: .destructive) { confirmDeleteAll = true }
            .disabled(isDeleting)
    }

    private func export() {
        guard let profile, !isExporting else { return }
        isExporting = true
        Task {
            do {
                exportURL = try await ExportService().exportJSON(for: profile)
            } catch {
                exportError = error.localizedDescription
            }
            isExporting = false
        }
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String ?? "–"
        return "HoopTrack \(version) (\(build)) · \(HoopTrack.MLModel.modelVersion)"
    }
}

// MARK: - UIActivityViewController wrapper
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
