// ProgressTabView.swift
// Stats hub — FG% trend, shot heat map, zone efficiency,
// personal records, and goal tracking.

import SwiftUI
import SwiftData
import Charts

struct ProgressTabView: View {

    @Environment(\.modelContext) private var modelContext
    @StateObject private var viewModel: ProgressViewModel = {
        ProgressViewModel(dataService: DataService(modelContext: ModelContext(try! ModelContainer(for: PlayerProfile.self, TrainingSession.self, ShotRecord.self, GoalRecord.self))))
    }()

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {

                // MARK: Time Range Picker
                timeRangePicker

                // MARK: FG% Trend Chart
                if viewModel.sessions.isEmpty && !viewModel.isLoading {
                    ContentUnavailableView {
                        Label("No Data", systemImage: "chart.line.uptrend.xyaxis")
                    } description: {
                        Text("Complete your first session to see your \(viewModel.selectedTimeRange.rawValue) trend.")
                    }
                    .padding(.vertical, 20)
                } else {
                    fgTrendSection
                        .shimmer(isActive: viewModel.isLoading)
                }

                // MARK: Shot Heat Map
                heatMapSection

                // MARK: Zone Efficiency
                zoneEfficiencySection

                // MARK: Goal Progress
                goalSection

                // MARK: Personal Records
                personalRecordsSection
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .navigationTitle("Progress")
        .navigationBarTitleDisplayMode(.large)
        .task { viewModel.load() }
        .refreshable { viewModel.load() }
    }

    // MARK: - Time Range

    private var timeRangePicker: some View {
        Picker("Time Range", selection: $viewModel.selectedTimeRange) {
            ForEach(TimeRange.allCases) { range in
                Text(range.rawValue).tag(range)
            }
        }
        .pickerStyle(.segmented)
    }

    // MARK: - FG% Trend

    private var fgTrendSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("FG% Trend")
                .font(.headline)

            if viewModel.fgTrendData.isEmpty {
                emptyChart(message: "Complete sessions to see your FG% trend.")
            } else {
                Chart(viewModel.fgTrendData, id: \.date) { item in
                    LineMark(
                        x: .value("Date", item.date, unit: .day),
                        y: .value("FG%", item.fg)
                    )
                    .foregroundStyle(.orange)
                    .interpolationMethod(.catmullRom)

                    AreaMark(
                        x: .value("Date", item.date, unit: .day),
                        y: .value("FG%", item.fg)
                    )
                    .foregroundStyle(.orange.opacity(0.15).gradient)
                    .interpolationMethod(.catmullRom)

                    PointMark(
                        x: .value("Date", item.date, unit: .day),
                        y: .value("FG%", item.fg)
                    )
                    .foregroundStyle(.orange)
                    .symbolSize(30)
                }
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                        AxisValueLabel {
                            if let d = value.as(Double.self) {
                                Text("\(Int(d))%")
                            }
                        }
                        AxisGridLine()
                    }
                }
                .frame(height: 200)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Shot Heat Map

    private var heatMapSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Shot Heat Map")
                    .font(.headline)
                Spacer()
                Text("\(viewModel.heatMapShots.count) shots")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            CourtMapView(shots: viewModel.heatMapShots, showHeatMap: true)

            CourtMapLegend()
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Zone Efficiency

    private var zoneEfficiencySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Zone Efficiency")
                .font(.headline)

            if viewModel.zoneEfficiency.isEmpty {
                emptyChart(message: "No shot data yet.")
            } else {
                ForEach(viewModel.zoneEfficiency) { ze in
                    VStack(spacing: 4) {
                        HStack {
                            Text(ze.zone.rawValue)
                                .font(.subheadline)
                            Spacer()
                            Text(String(format: "%.0f%%", ze.fgPercent))
                                .font(.subheadline.bold())
                                .foregroundStyle(fgColor(ze.fgPercent))
                            Text("(\(ze.made)/\(ze.attempted))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.secondary.opacity(0.15))
                                Capsule()
                                    .fill(fgColor(ze.fgPercent).gradient)
                                    .frame(width: geo.size.width * (ze.fgPercent / 100))
                            }
                        }
                        .frame(height: 8)
                    }
                }
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Goal Progress

    private var goalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Goals")
                    .font(.headline)
                Spacer()
                if let profile = viewModel.profile {
                    NavigationLink {
                        GoalListView(viewModel: GoalListViewModel(
                            modelContext: modelContext,
                            profile: profile
                        ))
                    } label: {
                        Label("Manage", systemImage: "plus")
                            .font(.subheadline)
                            .tint(.orange)
                    }
                }
            }

            if viewModel.goals.isEmpty {
                Text("No active goals. Tap Manage to add one.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(viewModel.goals.filter { !$0.isAchieved }) { goal in
                    GoalProgressRow(goal: goal)
                }
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Personal Records

    private var personalRecordsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Session Records")
                .font(.headline)

            if let best = viewModel.bestSession {
                NavigationLink {
                    SessionSummaryView(session: best, onDone: {})
                } label: {
                    recordRow(
                        title: "Best FG% Session",
                        value: String(format: "%.0f%%", best.fgPercent),
                        subtitle: best.startedAt.formatted(date: .abbreviated, time: .omitted),
                        icon: "trophy.fill",
                        accent: .yellow
                    )
                }
            }
            if let active = viewModel.mostActiveSession {
                NavigationLink {
                    SessionSummaryView(session: active, onDone: {})
                } label: {
                    recordRow(
                        title: "Most Shots in a Session",
                        value: "\(active.shotsAttempted)",
                        subtitle: active.startedAt.formatted(date: .abbreviated, time: .omitted),
                        icon: "basketball.fill",
                        accent: .orange
                    )
                }
            }

            if viewModel.bestSession == nil && viewModel.mostActiveSession == nil {
                Text("Complete a session to see records.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Reusable Helpers

    private func emptyChart(message: String) -> some View {
        Text(message)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 30)
    }

    private func fgColor(_ percent: Double) -> Color {
        switch percent {
        case 50...: return .green
        case 35..<50: return .orange
        default: return .red
        }
    }

    private func recordRow(title: String, value: String, subtitle: String,
                           icon: String, accent: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(accent)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(value)
                .font(.title3.bold())
                .foregroundStyle(accent)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - GoalProgressRow
struct GoalProgressRow: View {
    let goal: GoalRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(goal.title)
                    .font(.subheadline.bold())
                Spacer()
                Text("\(goal.progressPercent)%")
                    .font(.subheadline.bold())
                    .foregroundStyle(.orange)
            }

            ProgressView(value: goal.progressFraction)
                .tint(.orange)

            HStack {
                Text("\(goal.metric.rawValue): \(String(format: "%.1f", goal.currentValue)) → \(String(format: "%.1f", goal.targetValue)) \(goal.metric.unit)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let days = goal.daysRemaining {
                    Text("\(max(0, days))d left")
                        .font(.caption)
                        .foregroundStyle(days < 7 ? .red : .secondary)
                }
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}
