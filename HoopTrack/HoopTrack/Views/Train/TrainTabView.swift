// TrainTabView.swift
// Home screen. One big way to start shooting, a playoff run in progress,
// a quiet look at the week, and the drill library. Everything here starts
// something.

import SwiftUI

struct TrainTabView: View {

    @EnvironmentObject private var dataService: DataService
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var hapticService: HapticService
    @StateObject private var viewModel = TrainViewModel()
    @State private var openedSession: TrainingSession?
    @State private var showingPlayoffSetup = false
    /// Set by the setup sheet; launched once the sheet has gone, since the
    /// session cover can't open over it.
    @State private var playoffToLaunch: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                header
                hero
                if let playoff = viewModel.playoff {
                    PlayoffCard(series: playoff.series, run: playoff.run,
                                onContinue: {
                                    hapticService.tap()
                                    appState.activeLaunch = .playoff(playoff.series.id)
                                },
                                onEnd: { dataService.retirePlayoff(playoff.series) })
                }
                if viewModel.hasHistory {
                    weekStrip
                } else {
                    setupTip
                }
                drills
                if let last = viewModel.lastSession {
                    lastSessionRow(last)
                }
            }
            .padding(.horizontal, Metrics.screenPadding)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .courtBackground()
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { viewModel.load(from: dataService) }
        .onChange(of: dataService.revision) { _, _ in viewModel.load(from: dataService) }
        .navigationDestination(item: $openedSession) { session in
            SessionDetailView(session: session)
        }
        .sheet(isPresented: $showingPlayoffSetup, onDismiss: {
            if let id = playoffToLaunch {
                playoffToLaunch = nil
                appState.activeLaunch = .playoff(id)
            }
        }) {
            PlayoffSetupSheet { spot in
                playoffToLaunch = try? dataService.startPlayoffSeries(spot: spot).id
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.greeting)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Train")
                    .font(.largeTitle.bold())
            }
            Spacer()
            if viewModel.streak > 0 {
                Label("\(viewModel.streak)-day streak", systemImage: "flame.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.leather)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.leather.opacity(0.14), in: Capsule())
            }
        }
    }

    // MARK: - Hero

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            // The key and arc come in from the top-right; the arc's left
            // edge stays clear of the headline.
            HalfCourtShape(sidelines: false)
                .stroke(Color.leather.opacity(0.28), lineWidth: 2)
                .aspectRatio(CourtGeometry.widthFt / CourtGeometry.depthFt, contentMode: .fit)
                .frame(width: 330)
                .offset(x: 145, y: -70)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text("SHOOT")
                    .font(.score(64))
                    .foregroundStyle(.primary)
                Text("Automatic make, miss and shot position.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    hapticService.tap()
                    appState.activeLaunch = .shooting(nil)
                } label: {
                    Label("Start shooting", systemImage: "play.fill")
                }
                .buttonStyle(.primary)
                .padding(.top, 14)
            }
            .padding(20)
        }
        .frame(height: 250)
        .background(Color.panel)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }

    // MARK: - This week

    private var weekStrip: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("This week")
            HStack(spacing: 0) {
                StatValue(value: "\(viewModel.week.shots)", caption: "shots")
                    .frame(maxWidth: .infinity, alignment: .leading)
                StatValue(value: viewModel.week.fgPercent.map { "\(Int($0.rounded()))%" } ?? "–",
                          caption: "field goal",
                          color: viewModel.week.fgPercent.map { Color.shooting($0) } ?? .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                StatValue(value: "\(viewModel.week.sessions)", caption: viewModel.week.sessions == 1 ? "session" : "sessions")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var setupTip: some View {
        Panel {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "iphone.gen3")
                    .font(.title2)
                    .foregroundStyle(Color.leather)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Set up in ten seconds")
                        .font(.headline)
                    Text("Stand the phone sideways at chest height, four big steps (3 m) behind where you shoot, with the whole rim in view. HoopTrack does the rest.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Drills

    private var drills: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Drills")
            VStack(spacing: 0) {
                ForEach(Array(NamedDrill.library.enumerated()), id: \.element) { index, drill in
                    if index > 0 { Hairline(inset: 64) }
                    DrillRow(icon: drill.drillType.systemImage,
                             title: drill.displayName,
                             detail: drill.summary) {
                        hapticService.tap()
                        appState.activeLaunch = .forDrill(drill)
                    }
                }
                if viewModel.playoff == nil {
                    Hairline(inset: 64)
                    DrillRow(icon: "trophy.fill",
                             title: "Playoffs",
                             detail: "Best of seven, four rounds. Knocked out? Earn your way back.") {
                        hapticService.tap()
                        showingPlayoffSetup = true
                    }
                }
                Hairline(inset: 64)
                DrillRow(icon: "person.2.fill",
                         title: "Pickup game",
                         detail: "Keep score from 1v1 to 3v3, with a box score at the end.") {
                    hapticService.tap()
                    appState.activeLaunch = .game
                }
            }
            .background(Color.panel, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        }
    }

    // MARK: - Last session

    private func lastSessionRow(_ session: TrainingSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Last session")
            Button {
                openedSession = session
            } label: {
                SessionRow(session: session)
                    .padding(Metrics.cardPadding)
                    .background(Color.panel, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
            }
            .buttonStyle(.pressable)
        }
    }
}

// MARK: - Rows

private struct DrillRow: View {
    let icon: String
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.leather)
                    .frame(width: 34, height: 34)
                    .background(Color.panelRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Metrics.cardPadding)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityHint("Starts this drill")
    }
}

/// One-line session summary used in lists: title, when, headline number.
struct SessionRow: View {
    let session: TrainingSession

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: session.drillType.systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("\(session.startedAt.relativeDayLabel) · \(session.formattedDuration)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text(headline)
                    .font(.score(26))
                    .foregroundStyle(headlineColor)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var headline: String {
        switch session.drillType {
        case .dribble:
            return "\(session.totalDribbles ?? 0)"
        case .agility:
            if let best = session.bestShuttleRunSeconds ?? session.bestLaneAgilitySeconds {
                return String(format: "%.2fs", best)
            }
            return "–"
        case .freeShoot, .fullWorkout:
            return session.shotsAttempted > 0 ? "\(Int(session.fgPercent.rounded()))%" : "–"
        }
    }

    private var caption: String {
        switch session.drillType {
        case .dribble:              return "dribbles"
        case .agility:              return "best"
        case .freeShoot, .fullWorkout: return "\(session.shotsMade)/\(session.shotsAttempted)"
        }
    }

    private var headlineColor: Color {
        let shooting = session.drillType == .freeShoot || session.drillType == .fullWorkout
        guard shooting, session.shotsAttempted > 0 else { return .primary }
        return .shooting(session.fgPercent)
    }
}
