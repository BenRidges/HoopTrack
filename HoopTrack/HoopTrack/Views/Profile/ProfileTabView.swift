// ProfileTabView.swift
// Player profile, session history log, settings, and data export.

import SwiftUI
import SwiftData

struct ProfileTabView: View {

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var notificationService: NotificationService
    @EnvironmentObject private var hapticService: HapticService

    @StateObject private var viewModel: ProfileViewModel = {
        ProfileViewModel(dataService: DataService(modelContext: ModelContext(try! ModelContainer(for: PlayerProfile.self, TrainingSession.self, ShotRecord.self, GoalRecord.self))))
    }()

    @State private var isShowingExportSheet = false
    @State private var exportCSV: String = ""
    @State private var reminderEnabled: Bool = UserDefaults.standard.bool(forKey: "trainingReminderEnabled")
    @State private var reminderHour: Int     = UserDefaults.standard.integer(forKey: "trainingReminderHour") == 0
                                                ? 9
                                                : UserDefaults.standard.integer(forKey: "trainingReminderHour")

    private var reminderTimeBinding: Binding<Date> {
        Binding(
            get: {
                var components = DateComponents()
                components.hour = reminderHour
                components.minute = 0
                return Calendar.current.date(from: components) ?? .now
            },
            set: { date in
                reminderHour = Calendar.current.component(.hour, from: date)
            }
        )
    }

    var body: some View {
        List {

            // MARK: Profile Header
            Section {
                profileHeader
            }

            // MARK: Career Stats
            Section("Career Stats") {
                LabeledContent("Total Sessions",  value: "\(viewModel.totalSessions)")
                LabeledContent("Total Minutes",   value: String(format: "%.0f min", viewModel.totalMinutes))
                LabeledContent("Career FG%",      value: viewModel.careerFG)
            }

            // MARK: Session History
            Section {
                // Filter chips
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        historyFilterChip(label: "All", filter: nil)
                        ForEach(DrillType.allCases) { type in
                            historyFilterChip(label: type.rawValue, filter: type)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))

                ForEach(viewModel.filteredSessions) { session in
                    NavigationLink {
                        SessionSummaryView(session: session, onDone: {})
                    } label: {
                        SessionHistoryRow(session: session)
                    }
                }
                .onDelete { indexSet in
                    indexSet.map { viewModel.filteredSessions[$0] }
                            .forEach { viewModel.deleteSession($0) }
                }
            } header: {
                HStack {
                    Text("Session History")
                    Spacer()
                    Button {
                        hapticService.tap()
                        viewModel.historySortAscending.toggle()
                    } label: {
                        Label(viewModel.historySortAscending ? "Oldest first" : "Newest first",
                              systemImage: viewModel.historySortAscending
                                ? "arrow.up" : "arrow.down")
                        .font(.caption)
                        .tint(.orange)
                    }
                }
            }

            // MARK: Badges
            Section("Badges") {
                if let profile = viewModel.profile {
                    NavigationLink {
                        BadgeBrowserView(viewModel: BadgeBrowserViewModel(profile: profile))
                    } label: {
                        LabeledContent("Earned", value: "\(viewModel.badgeCount) / 25")
                    }
                }
            }

            // MARK: Settings
            Section("Settings") {
                // Notifications
                NavigationLink {
                    NotificationSettingsView()
                } label: {
                    Label("Notifications", systemImage: "bell")
                }

                // iCloud
                if let profile = viewModel.profile {
                    Toggle(isOn: Binding(
                        get: { profile.iCloudSyncEnabled },
                        set: { viewModel.toggleICloudSync($0) }
                    )) {
                        Label("iCloud Sync", systemImage: "icloud")
                    }
                    .tint(.orange)

                    Picker(selection: Binding(
                        get: { profile.videosAutoDeleteDays },
                        set: { viewModel.setVideoRetentionDays($0) }
                    )) {
                        Text("Never").tag(0)
                        Text("30 days").tag(30)
                        Text("60 days").tag(60)
                        Text("90 days").tag(90)
                    } label: {
                        Label("Delete Videos After", systemImage: "film")
                    }
                }

                // Preferred court
                if let profile = viewModel.profile {
                    Picker(selection: Binding(
                        get: { profile.preferredCourtType },
                        set: { profile.preferredCourtType = $0 }
                    )) {
                        ForEach(CourtType.allCases) { ct in
                            Text(ct.rawValue).tag(ct)
                        }
                    } label: {
                        Label("Default Court", systemImage: "mappin.circle")
                    }
                }

                // Training Reminder
                Toggle("Daily Training Reminder", isOn: $reminderEnabled)
                    .tint(.orange)
                    .onChange(of: reminderEnabled) { _, on in
                        if on {
                            notificationService.scheduleTrainingReminder(hour: reminderHour)
                        } else {
                            notificationService.cancelTrainingReminder()
                        }
                        UserDefaults.standard.set(on, forKey: "trainingReminderEnabled")
                    }

                if reminderEnabled {
                    DatePicker("Reminder Time",
                               selection: reminderTimeBinding,
                               displayedComponents: .hourAndMinute)
                        .onChange(of: reminderHour) { _, hour in
                            notificationService.scheduleTrainingReminder(hour: hour)
                            UserDefaults.standard.set(hour, forKey: "trainingReminderHour")
                        }
                }
            }

            // MARK: Data & Export
            Section("Data") {
                Button {
                    exportCSV       = viewModel.exportData()
                    isShowingExportSheet = true
                } label: {
                    Label("Export Session Data (CSV)", systemImage: "square.and.arrow.up")
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.large)
        .task { viewModel.load() }
        .sheet(isPresented: $isShowingExportSheet) {
            ShareSheet(items: [exportCSV])
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: - Profile Header

    private var profileHeader: some View {
        HStack(spacing: 16) {
            // Avatar placeholder
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.15))
                    .frame(width: 64, height: 64)
                Image(systemName: "person.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 4) {
                if viewModel.isEditingName {
                    TextField("Your name", text: $viewModel.editingName)
                        .font(.title2.bold())
                        .onSubmit { viewModel.saveName() }
                } else {
                    Text(viewModel.profile?.name ?? "Player")
                        .font(.title2.bold())
                }

                Text("Member since \(viewModel.profile?.createdAt.formatted(.dateTime.month().year()) ?? "—")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                hapticService.tap()
                viewModel.isEditingName
                    ? viewModel.saveName()
                    : viewModel.beginEditName()
            } label: {
                Image(systemName: viewModel.isEditingName ? "checkmark.circle.fill" : "pencil")
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - History Filter Chip

    private func historyFilterChip(label: String, filter: DrillType?) -> some View {
        Button {
            hapticService.tap()
            viewModel.historyFilter = filter
        } label: {
            Text(label)
                .font(.caption.weight(viewModel.historyFilter == filter ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    viewModel.historyFilter == filter
                        ? AnyShapeStyle(Color.orange)
                        : AnyShapeStyle(Color.secondary.opacity(0.15)),
                    in: Capsule()
                )
                .foregroundStyle(viewModel.historyFilter == filter ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - SessionHistoryRow
private struct SessionHistoryRow: View {
    let session: TrainingSession

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: session.drillType.systemImage)
                .font(.title3)
                .foregroundStyle(.orange)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.namedDrill?.rawValue ?? session.drillType.rawValue)
                    .font(.subheadline.bold())
                Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "%.0f%%", session.fgPercent))
                    .font(.subheadline.bold())
                    .foregroundStyle(.orange)
                Text(session.formattedDuration)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - NotificationSettingsView (stub)
private struct NotificationSettingsView: View {
    @EnvironmentObject private var notificationService: NotificationService

    var body: some View {
        Form {
            Section("Streak Reminder") {
                Toggle("Daily Reminder", isOn: .constant(true))
                    .tint(.orange)
                    .disabled(notificationService.authorizationStatus != .authorized)
            }
            Section("Goal Milestones") {
                Toggle("Goal Achieved", isOn: .constant(true))
                    .tint(.orange)
            }
            if notificationService.authorizationStatus == .denied {
                Section {
                    Button("Open Settings to Allow Notifications") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("Notifications")
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
