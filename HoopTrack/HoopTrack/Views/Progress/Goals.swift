// Goals.swift
// Goals on the Progress tab, plus the sheet for adding one. A goal is a
// metric and a target; the title and starting point are worked out for you.

import SwiftUI

struct GoalsSection: View {
    let profile: PlayerProfile
    @EnvironmentObject private var dataService: DataService
    @State private var adding = false
    @State private var showAchieved = false

    private var active: [GoalRecord] {
        profile.goals.filter { !$0.isAchieved }.sorted { $0.createdAt < $1.createdAt }
    }
    private var achieved: [GoalRecord] {
        profile.goals.filter(\.isAchieved).sorted { ($0.achievedAt ?? .distantPast) > ($1.achievedAt ?? .distantPast) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel("Goals")
                Button {
                    adding = true
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                }
            }
            VStack(spacing: 0) {
                if active.isEmpty {
                    Text(achieved.isEmpty
                         ? "Set a target — say 45% from three — and it fills in as you train."
                         : "All goals reached. Set the next one.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Metrics.cardPadding)
                }
                ForEach(Array(active.enumerated()), id: \.element.id) { index, goal in
                    if index > 0 { Hairline(inset: Metrics.cardPadding) }
                    GoalRow(goal: goal)
                        .contextMenu {
                            Button("Delete goal", systemImage: "trash", role: .destructive) {
                                try? dataService.deleteGoal(goal)
                            }
                        }
                }
                if !achieved.isEmpty {
                    Hairline(inset: Metrics.cardPadding)
                    DisclosureGroup(isExpanded: $showAchieved) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(achieved) { goal in
                                Label(goal.title, systemImage: "checkmark.circle.fill")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        Text("Reached (\(achieved.count))")
                            .font(.subheadline.weight(.medium))
                    }
                    .padding(Metrics.cardPadding)
                }
            }
            .background(Color.panel, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        }
        .sheet(isPresented: $adding) {
            AddGoalSheet(profile: profile)
        }
    }
}

private struct GoalRow: View {
    let goal: GoalRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(goal.title)
                    .font(.body.weight(.semibold))
                Spacer()
                Text("\(goal.progressPercent)%")
                    .font(.score(22))
                    .foregroundStyle(Color.leather)
            }
            ProgressView(value: goal.progressFraction)
                .tint(Color.leather)
            HStack {
                Text("\(GoalFormat.value(goal.currentValue, goal.metric)) now · target \(GoalFormat.value(goal.targetValue, goal.metric))")
                Spacer()
                if let days = goal.daysRemaining {
                    Text(days < 0 ? "Past the deadline" : days == 0 ? "Due today"
                         : days == 1 ? "1 day left" : "\(days) days left")
                        .foregroundStyle(days < 7 ? Color.miss : .secondary)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(Metrics.cardPadding)
        .accessibilityElement(children: .combine)
    }
}

enum GoalFormat {
    static func value(_ v: Double, _ metric: GoalMetric) -> String {
        guard v.isFinite else { return "–" }
        switch metric {
        case .fgPercent, .threePointPercent, .freeThrowPercent:
            return "\(Int(v.rounded()))%"
        case .verticalJumpCm:
            return "\(Int(v.rounded())) cm"
        case .dribbleSpeedHz:
            return String(format: "%.1f/s", v)
        case .shuttleRunSeconds:
            return String(format: "%.2fs", v)
        case .overallRating, .shootingRating:
            return "\(Int(v.rounded()))"
        case .sessionsPerWeek:
            return "\(Int(v.rounded()))"
        }
    }

    static func title(metric: GoalMetric, target: Double) -> String {
        let t = value(target, metric)
        switch metric {
        case .fgPercent:         return "Shoot \(t) from the field"
        case .threePointPercent: return "Shoot \(t) from three"
        case .freeThrowPercent:  return "Make \(t) of free throws"
        case .verticalJumpCm:    return "Jump \(t)"
        case .dribbleSpeedHz:    return "Dribble at \(t)"
        case .shuttleRunSeconds: return "Shuttle run in \(t)"
        case .overallRating:     return "Reach \(t) overall"
        case .shootingRating:    return "Reach \(t) shooting"
        case .sessionsPerWeek:   return "Train \(t) times a week"
        }
    }

    /// Where you are today on a metric — the goal's starting point.
    @MainActor
    static func currentValue(_ metric: GoalMetric, profile: PlayerProfile) -> Double {
        let recent = profile.sessions.filter(\.isComplete).sorted { $0.startedAt > $1.startedAt }.prefix(10)
        func percent(_ shots: [ShotRecord]) -> Double {
            let done = shots.filter { $0.result != .pending }
            return done.isEmpty ? 0 : Double(done.filter(\.isMake).count) / Double(done.count) * 100
        }
        let recentShots = recent.flatMap(\.shots)
        switch metric {
        case .fgPercent:         return percent(recentShots)
        case .threePointPercent: return percent(recentShots.filter { $0.zone.isThree })
        case .freeThrowPercent:  return percent(recentShots.filter { $0.zone == .freeThrow })
        case .verticalJumpCm:    return profile.prVerticalJumpCm
        case .dribbleSpeedHz:    return recent.compactMap(\.avgDribblesPerSec).first ?? 0
        case .shuttleRunSeconds: return profile.sessions.compactMap(\.bestShuttleRunSeconds).min() ?? 0
        case .overallRating:     return profile.ratingOverall
        case .shootingRating:    return profile.ratingShooting
        case .sessionsPerWeek:
            let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .distantPast
            return Double(profile.sessions.filter { $0.isComplete && $0.startedAt >= cutoff }.count)
        }
    }
}

struct AddGoalSheet: View {
    let profile: PlayerProfile
    @EnvironmentObject private var dataService: DataService
    @Environment(\.dismiss) private var dismiss

    @State private var metric: GoalMetric = .fgPercent
    @State private var target: Double = 50
    @State private var hasDeadline = false
    @State private var deadline = Calendar.current.date(byAdding: .month, value: 1, to: .now) ?? .now

    private static let metrics: [GoalMetric] = [
        .fgPercent, .threePointPercent, .freeThrowPercent,
        .sessionsPerWeek, .dribbleSpeedHz, .shuttleRunSeconds, .overallRating,
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Improve", selection: $metric) {
                        ForEach(Self.metrics) { Text($0.displayName).tag($0) }
                    }
                    Stepper(value: $target, in: bounds, step: step) {
                        HStack {
                            Text("Target")
                            Spacer()
                            Text(GoalFormat.value(target, metric))
                                .font(.score(24))
                                .foregroundStyle(Color.leather)
                        }
                    }
                } footer: {
                    Text("You're at \(GoalFormat.value(current, metric)) right now.")
                }
                .listRowBackground(Color.panel)

                Section {
                    Toggle("Deadline", isOn: $hasDeadline)
                    if hasDeadline {
                        DatePicker("By", selection: $deadline, in: Date.now..., displayedComponents: .date)
                    }
                }
                .listRowBackground(Color.panel)
            }
            .courtList()
            .navigationTitle(GoalFormat.title(metric: metric, target: target))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.bold()
                }
            }
            .onChange(of: metric) { _, newMetric in target = suggestedTarget(for: newMetric) }
            .onAppear { target = suggestedTarget(for: metric) }
        }
        .presentationDetents([.medium])
    }

    private var current: Double { GoalFormat.currentValue(metric, profile: profile) }

    private var bounds: ClosedRange<Double> {
        switch metric {
        case .fgPercent, .threePointPercent, .freeThrowPercent: return 5...100
        case .sessionsPerWeek:   return 1...14
        case .dribbleSpeedHz:    return 1...12
        case .shuttleRunSeconds: return 4...20
        case .overallRating, .shootingRating: return 5...100
        case .verticalJumpCm:    return 10...120
        }
    }

    private var step: Double {
        switch metric {
        case .dribbleSpeedHz:    return 0.5
        case .shuttleRunSeconds: return 0.1
        default:                 return 1
        }
    }

    private func suggestedTarget(for metric: GoalMetric) -> Double {
        let now = GoalFormat.currentValue(metric, profile: profile)
        let range = bounds
        let proposal: Double
        switch metric {
        case .shuttleRunSeconds: proposal = now > 0 ? now - 0.5 : 8
        case .sessionsPerWeek:   proposal = max(3, now + 1)
        case .dribbleSpeedHz:    proposal = max(4, (now + 0.5).rounded())
        default:                 proposal = now > 0 ? (now + 5).rounded() : 50
        }
        return proposal.clamped(to: range)
    }

    private func save() {
        let goal = GoalRecord(title: GoalFormat.title(metric: metric, target: target),
                              skill: skill(for: metric),
                              metric: metric,
                              targetValue: target,
                              baselineValue: current,
                              targetDate: hasDeadline ? deadline : nil)
        try? dataService.addGoal(goal, to: profile)
        dismiss()
    }

    private func skill(for metric: GoalMetric) -> SkillDimension {
        switch metric {
        case .fgPercent, .threePointPercent, .freeThrowPercent, .shootingRating: return .shooting
        case .dribbleSpeedHz:    return .ballHandling
        case .shuttleRunSeconds, .verticalJumpCm: return .athleticism
        case .sessionsPerWeek:   return .volume
        case .overallRating:     return .consistency
        }
    }
}
