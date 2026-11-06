// ProgressTabView.swift
// How you're shooting over time: one headline number for the chosen
// range, the trend behind it, where your shots come from, and the
// longer-term things (skills, goals, badges, history).

import SwiftUI
import SwiftData
import Charts

struct ProgressTabView: View {

    @EnvironmentObject private var dataService: DataService
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = ProgressViewModel()
    @State private var range: TimeRange = .last30Days
    @State private var opened: TrainingSession?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                Picker("Range", selection: $range) {
                    ForEach(TimeRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if viewModel.hasAnySessions {
                    headline
                    if viewModel.trend.count >= 2 { trendChart }
                    if viewModel.chartShots.contains(where: { $0.zone != .unknown }) { shotChart }
                    if !viewModel.zones.isEmpty { zones }
                    if let profile = viewModel.profile { SkillsSection(profile: profile) }
                    if let profile = viewModel.profile { GoalsSection(profile: profile) }
                    if let profile = viewModel.profile { badgesRow(profile) }
                    history
                    PlayoffRunsSection()
                    RecentGamesSection()
                } else {
                    emptyState
                    // Pickup games still show before the first training session.
                    RecentGamesSection()
                }
            }
            .padding(.horizontal, Metrics.screenPadding)
            .padding(.bottom, 32)
        }
        .courtBackground()
        .navigationTitle("Progress")
        .onAppear { reload() }
        .onChange(of: range) { _, _ in reload() }
        .onChange(of: dataService.revision) { _, _ in reload() }
        .navigationDestination(item: $opened) { SessionDetailView(session: $0) }
    }

    private func reload() {
        viewModel.load(range: range, from: dataService)
    }

    // MARK: - Headline

    private var headline: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let fg = viewModel.fgPercent {
                HStack(alignment: .lastTextBaseline, spacing: 12) {
                    Text("\(Int(fg.rounded()))%")
                        .font(.score(88))
                        .foregroundStyle(Color.shooting(fg))
                        .contentTransition(.numericText())
                    if let change = viewModel.fgChange, abs(change) >= 0.5 {
                        Label("\(change > 0 ? "+" : "")\(Int(change.rounded())) pts",
                              systemImage: change > 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(change > 0 ? Color.make : Color.miss)
                            .padding(.bottom, 16)
                    }
                }
                Text("Field goal, \(viewModel.range.phrase) · \(viewModel.makes) of \(viewModel.shots)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("No shots \(viewModel.range.phrase)")
                    .font(.title3.weight(.semibold))
                Text("\(viewModel.sessionCount.counted("session")) · \(Int(viewModel.minutes)) min")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Trend

    private var trendChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Trend")
            Panel {
                Chart(viewModel.trend) { point in
                    AreaMark(x: .value("Date", point.date),
                             y: .value("FG%", point.fgPercent))
                        .foregroundStyle(LinearGradient(colors: [Color.leather.opacity(0.28), Color.leather.opacity(0)],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Date", point.date),
                             y: .value("FG%", point.fgPercent))
                        .foregroundStyle(Color.leather)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("Date", point.date),
                              y: .value("FG%", point.fgPercent))
                        .foregroundStyle(Color.leather)
                        .symbolSize(24)
                        .accessibilityLabel(point.date.formatted(date: .abbreviated, time: .omitted))
                        .accessibilityValue("\(Int(point.fgPercent.rounded())) percent from \(point.attempts) shots")
                }
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(position: .trailing, values: [0, 50, 100]) { value in
                        AxisGridLine().foregroundStyle(Color.white.opacity(0.08))
                        AxisValueLabel {
                            if let v = value.as(Int.self) { Text("\(v)%") }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    }
                }
                .frame(height: 170)
            }
        }
    }

    // MARK: - Shots

    private var shotChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Where you shoot from")
            Panel {
                VStack(spacing: 12) {
                    ShotChart(shots: viewModel.chartShots,
                              threePointFt: viewModel.profile?.preferredCourtType.threePointDistanceFt
                                ?? CourtType.nba.threePointDistanceFt)
                    if viewModel.chartShots.count <= 60 {
                        ShotChartKey()
                    } else {
                        Text("Bigger dots: more shots. Green: hot. Red: cold.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var zones: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("By zone")
            Panel {
                VStack(spacing: 14) {
                    ForEach(viewModel.zones) { line in
                        ZoneRow(name: line.zone.displayName, made: line.made,
                                attempted: line.attempted, percent: line.percent)
                    }
                }
            }
        }
    }

    // MARK: - Badges & history

    private func badgesRow(_ profile: PlayerProfile) -> some View {
        NavigationLink {
            BadgeBrowserView(viewModel: BadgeBrowserViewModel(profile: profile))
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "rosette")
                    .font(.title3)
                    .foregroundStyle(Color.leather)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Badges").font(.headline).foregroundStyle(.primary)
                    Text("\(profile.earnedBadges.count) of \(BadgeID.allCases.count) earned")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(Metrics.cardPadding)
            .background(Color.panel, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        }
        .buttonStyle(.pressable)
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel("Recent sessions")
                NavigationLink("See all") { HistoryView() }
                    .font(.subheadline.weight(.semibold))
            }
            VStack(spacing: 0) {
                ForEach(Array(viewModel.recentSessions.enumerated()), id: \.element.id) { index, session in
                    if index > 0 { Hairline(inset: 60) }
                    Button { opened = session } label: {
                        SessionRow(session: session)
                            .padding(.horizontal, Metrics.cardPadding)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                }
            }
            .background(Color.panel, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        }
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(Color.leather)
            Text("Your numbers live here")
                .font(.title3.bold())
            Text("Finish a session and you'll see your shooting trend, hot spots and records.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Start shooting") { appState.activeLaunch = .shooting(nil) }
                .buttonStyle(.primary)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}

// MARK: - Skills

private struct SkillsSection: View {
    let profile: PlayerProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Skills")
            Panel {
                HStack(alignment: .center, spacing: 20) {
                    VStack(spacing: 0) {
                        Text("\(Int(profile.ratingOverall.rounded()))")
                            .font(.score(56))
                        Text("overall")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 80)
                    VStack(spacing: 10) {
                        ForEach(SkillDimension.allCases) { skill in
                            SkillBar(name: skill.displayName, value: profile.skillRatings[skill] ?? 0)
                        }
                    }
                }
            }
        }
    }
}

private struct SkillBar: View {
    let name: String
    let value: Double

    var body: some View {
        HStack(spacing: 10) {
            Text(name)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.panelRaised)
                    Capsule().fill(Color.leather)
                        .frame(width: max(value > 0 ? 4 : 0, geo.size.width * value / 100))
                }
            }
            .frame(height: 6)
            Text(value > 0 ? "\(Int(value.rounded()))" : "–")
                .font(.footnote.monospacedDigit())
                .frame(width: 26, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) \(value > 0 ? "\(Int(value.rounded())) out of 100" : "not rated yet")")
    }
}

// MARK: - History

struct HistoryView: View {
    @Query(filter: #Predicate<TrainingSession> { $0.endedAt != nil },
           sort: \TrainingSession.startedAt, order: .reverse)
    private var sessions: [TrainingSession]

    var body: some View {
        List {
            ForEach(sessions) { session in
                NavigationLink {
                    SessionDetailView(session: session)
                } label: {
                    SessionRow(session: session)
                }
                .listRowBackground(Color.panel)
            }
        }
        .courtList()
        .navigationTitle("History")
        .overlay {
            if sessions.isEmpty {
                ContentUnavailableView("No sessions yet", systemImage: "basketball")
            }
        }
    }
}
