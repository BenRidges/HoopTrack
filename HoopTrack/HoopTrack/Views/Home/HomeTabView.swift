// HomeTabView.swift
// Dashboard — the first screen users see.
// Shows overall skill rating, streak, quick-start buttons,
// daily mission, personal records, and last session summary.

import SwiftUI
import SwiftData
import Charts

struct HomeTabView: View {

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var hapticService: HapticService
    @EnvironmentObject private var appState: AppState

    @StateObject private var viewModel: DashboardViewModel = {
        // ViewModel is constructed with modelContext in .task
        DashboardViewModel(dataService: DataService(modelContext: ModelContext(try! ModelContainer(for: PlayerProfile.self, TrainingSession.self, ShotRecord.self, GoalRecord.self))))
    }()

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {

                // MARK: Header
                headerSection

                // MARK: Overall Rating + Radar
                ratingSection
                    .shimmer(isActive: viewModel.isLoading)

                // MARK: Shooting %
                shootingSection
                    .shimmer(isActive: viewModel.isLoading)

                // MARK: Streaks & Records
                streakSection

                // MARK: Weekly Volume Chart
                if viewModel.weeklyVolume.isEmpty && !viewModel.isLoading {
                    ContentUnavailableView {
                        Label("No Sessions Yet", systemImage: "basketball.fill")
                    } description: {
                        Text("Complete your first session to start tracking progress.")
                    } actions: {
                        Text("Tap **Train** to get started")
                    }
                    .padding(.vertical, 20)
                } else {
                    volumeSection
                }

                // MARK: Daily Mission
                missionSection

                // MARK: Last Session
                if let last = viewModel.lastSessionSummary {
                    lastSessionSection(last)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .navigationTitle("HoopTrack")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    hapticService.tap()
                    appState.selectedTab = .train
                } label: {
                    Label("Quick Start", systemImage: "play.fill")
                }
                .tint(.orange)
            }
        }
        .task {
            // Rebuild ViewModel with the injected context (workaround for @StateObject init)
            await viewModel.load()
        }
        .refreshable {
            await viewModel.load()
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Good \(timeOfDayGreeting),")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(viewModel.profile?.name ?? "Player")
                    .font(.title.bold())
            }
            Spacer()
            streakBadge
        }
        .padding(.top, 8)
    }

    private var streakBadge: some View {
        VStack(spacing: 0) {
            Text("\(viewModel.currentStreak)")
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(.orange)
            Text("day streak")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.12), in: Capsule())
    }

    private var ratingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Skill Ratings")
                .font(.headline)

            HStack(alignment: .center, spacing: 16) {
                // Overall rating ring
                ZStack {
                    Circle()
                        .stroke(Color.orange.opacity(0.2), lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: viewModel.overallRating / 100)
                        .stroke(Color.orange, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text("\(Int(viewModel.overallRating))")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                        Text("Overall")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 90, height: 90)

                SkillRadarView(ratings: Dictionary(uniqueKeysWithValues:
                    viewModel.skillRatings.map { ($0.skill, $0.value) }
                ))
                .frame(width: 160, height: 160)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var shootingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Shooting")
                .font(.headline)
            StatCardGrid {
                StatCard(title: "FG% Last 7 Days",
                         value: String(format: "%.1f%%", viewModel.shootingFGLast7))
                StatCard(title: "FG% Last 30 Days",
                         value: String(format: "%.1f%%", viewModel.shootingFGLast30),
                         accent: .blue)
            }
        }
    }

    private var streakSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Streaks & Records")
                .font(.headline)
            StatCardGrid {
                StatCard(title: "Current Streak",
                         value: "\(viewModel.currentStreak) days",
                         subtitle: "Best: \(viewModel.longestStreak) days",
                         accent: .yellow)
                StatCard(title: "Best FG% Session",
                         value: viewModel.prBestFG,
                         accent: .green)
                StatCard(title: "Most Makes",
                         value: "\(viewModel.prMostMakes)",
                         subtitle: "in a single session",
                         accent: .purple)
                StatCard(title: "Best Consistency",
                         value: viewModel.prConsistency,
                         subtitle: "release angle variance",
                         accent: .cyan)
            }
        }
    }

    private var volumeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Weekly Volume")
                .font(.headline)

            Chart(viewModel.weeklyVolume, id: \.date) { item in
                BarMark(
                    x: .value("Day", item.date, unit: .day),
                    y: .value("Shots", item.attempts)
                )
                .foregroundStyle(.orange.gradient)
                .cornerRadius(4)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) {
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated))
                }
            }
            .frame(height: 120)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var missionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Today's Mission")
                .font(.headline)

            HStack(spacing: 12) {
                Image(systemName: "target")
                    .font(.title2)
                    .foregroundStyle(.orange)
                    .frame(width: 44, height: 44)
                    .background(.orange.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.dailyMissionDrill.rawValue)
                        .font(.subheadline.bold())
                    Text("Focus on \(viewModel.dailyMissionSkill.rawValue.lowercased())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func lastSessionSection(_ session: TrainingSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Last Session")
                .font(.headline)

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.drillType.rawValue)
                        .font(.subheadline.bold())
                    Text(session.startedAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(String(format: "%.0f%%", session.fgPercent))
                        .font(.title3.bold())
                        .foregroundStyle(.orange)
                    Text("\(session.shotsMade)/\(session.shotsAttempted)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    // MARK: - Helpers

    private var timeOfDayGreeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        switch hour {
        case 0..<12:  return "Morning"
        case 12..<17: return "Afternoon"
        default:      return "Evening"
        }
    }
}
