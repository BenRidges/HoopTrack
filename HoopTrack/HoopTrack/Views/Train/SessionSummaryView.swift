// SessionSummaryView.swift
// The report for one session — shown as a sheet right after training
// (SessionSummaryView) and pushed from history (SessionDetailView).
//
// Shooting reports lead with FG%, then where the shots came from, then the
// shot list. Any shot can be flipped make ↔ miss with one tap; calls the
// tracker wasn't sure about are flagged so they get checked first, on video
// when there is one (ShotCheckView).

import SwiftUI
import SwiftData

/// Post-session sheet.
struct SessionSummaryView: View {
    let result: SessionResult
    /// Starts the same session again; nil hides the button.
    var goAgain: (() -> Void)? = nil
    @EnvironmentObject private var dataService: DataService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SessionReport(session: result.session,
                          badgeChanges: result.badgeChanges,
                          badgeSkipReason: result.badgeSkipReason)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }.bold()
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    if let goAgain, canGoAgain {
                        Button(action: goAgain) {
                            Label(isPlayoff ? "Keep playing" : "Go again", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.primary)
                        .padding(.horizontal, Metrics.screenPadding)
                        .padding(.top, 10)
                        .padding(.bottom, 6)
                        .background(Color.court.opacity(0.94).ignoresSafeArea())
                    }
                }
        }
        .presentationDragIndicator(.visible)
    }

    private var isPlayoff: Bool { result.session.playoffSeriesID != nil }

    /// A playoff run that's been won (or ended) has nothing to go again to.
    private var canGoAgain: Bool {
        guard let id = result.session.playoffSeriesID else { return true }
        guard let series = dataService.playoffSeries(id: id) else { return false }
        return series.status != .champion && series.status != .retired
    }
}

/// History entry, pushed onto a navigation stack.
struct SessionDetailView: View {
    let session: TrainingSession
    @EnvironmentObject private var dataService: DataService
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    var body: some View {
        SessionReport(session: session)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Delete session", systemImage: "trash", role: .destructive) {
                            confirmDelete = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .confirmationDialog("Delete this session?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    // Pop first: a view still reading a deleted SwiftData
                    // object can crash, so delete once the transition is done.
                    dismiss()
                    Task {
                        try? await Task.sleep(for: .milliseconds(450))
                        try? dataService.deleteSession(session)
                    }
                }
            } message: {
                Text("Its shots and video are removed and your career stats are updated.")
            }
    }
}

// MARK: - Report

struct SessionReport: View {
    let session: TrainingSession
    var badgeChanges: [BadgeTierChange] = []
    var badgeSkipReason: String? = nil

    @EnvironmentObject private var dataService: DataService
    @EnvironmentObject private var hapticService: HapticService
    @State private var highlighted: ShotRecord.ID?
    @State private var showReplay = false
    @State private var checking: ShotCheckBatch?
    @AppStorage(AppPreferences.Key.reviewOnVideo) private var reviewOnVideo = true

    private var shots: [ShotRecord] { session.orderedShots.filter { $0.result != .pending } }
    private var flagged: [ShotRecord] { shots.filter(\.needsReview) }
    private var isShooting: Bool { session.drillType == .freeShoot || session.drillType == .fullWorkout }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                header
                hero
                if isShooting {
                    if !flagged.isEmpty { reviewBanner }
                    if shots.contains(where: { $0.zone != .unknown }) { chart }
                    if !session.zoneStats.isEmpty { zones }
                    if session.avgReleaseAngleDeg != nil { arc }
                    if !shots.isEmpty { shotList }
                }
                if session.drillType == .dribble { dribbleDetails }
                if session.drillType == .agility { agilityDetails }
                if !badgeChanges.isEmpty || badgeSkipReason != nil { badges }
                if hasVideo { video }
            }
            .padding(.horizontal, Metrics.screenPadding)
            .padding(.bottom, 32)
        }
        .courtBackground()
        .fullScreenCover(isPresented: $showReplay) {
            SessionReplayView(session: session)
        }
        .fullScreenCover(item: $checking) { batch in
            ShotCheckView(session: session, shots: batch.shots)
        }
    }

    // MARK: Header & hero

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.title)
                .font(.title2.bold())
            Text("\(session.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(session.formattedDuration)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var hero: some View {
        switch session.drillType {
        case .dribble:
            heroNumber("\(session.totalDribbles ?? 0)", caption: "dribbles", color: .primary)
        case .agility:
            if let best = session.bestShuttleRunSeconds ?? session.bestLaneAgilitySeconds {
                heroNumber(String(format: "%.2f", best) + "s", caption: "best time", color: .primary)
            } else {
                heroNumber("–", caption: "no timed runs", color: .secondary)
            }
        case .freeShoot, .fullWorkout:
            if session.shotsAttempted > 0 {
                HStack(alignment: .lastTextBaseline, spacing: 18) {
                    heroNumber("\(Int(session.fgPercent.rounded()))%", caption: "field goal",
                               color: .shooting(session.fgPercent))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(session.shotsMade) of \(session.shotsAttempted)")
                            .font(.title3.weight(.semibold))
                        if session.longestMakeStreak >= 3 {
                            Text("\(session.longestMakeStreak) in a row at best")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.bottom, 22)
                }
            } else {
                heroNumber("–", caption: "no shots logged", color: .secondary)
            }
        }
    }

    private func heroNumber(_ value: String, caption: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.score(96))
                .foregroundStyle(color)
                .contentTransition(.numericText())
            Text(caption)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Review

    private var reviewBanner: some View {
        let onVideo = reviewOnVideo ? ShotCheckView.checkable(in: session) : []
        return Panel {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.leather)
                VStack(alignment: .leading, spacing: 4) {
                    Text(flagged.count == 1 ? "1 call to check" : "\(flagged.count) calls to check")
                        .font(.headline)
                    Text(onVideo.isEmpty
                         ? "The tracker wasn't sure about these. Tap a shot below to flip it."
                         : "The tracker wasn't sure about these. Watch each one and tap Make or Miss.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 18) {
                        if !onVideo.isEmpty {
                            Button {
                                checking = ShotCheckBatch(shots: onVideo)
                            } label: {
                                Label("Watch them", systemImage: "play.fill")
                            }
                            .foregroundStyle(Color.leather)
                        }
                        Button("They're all right") {
                            hapticService.tap()
                            flagged.forEach { dataService.updateShot($0, result: $0.result) }
                        }
                        .foregroundStyle(onVideo.isEmpty ? Color.leather : .secondary)
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, 4)
                }
            }
        }
    }

    // MARK: Chart & zones

    private var chart: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Shot chart")
            Panel {
                VStack(spacing: 12) {
                    ShotChart(shots: shots,
                              threePointFt: session.courtType.threePointDistanceFt,
                              highlighted: highlighted)
                    ShotChartKey()
                }
            }
        }
    }

    private var zones: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("By zone")
            Panel {
                VStack(spacing: 14) {
                    ForEach(session.zoneStats) { stat in
                        ZoneRow(name: stat.zone.displayName, made: stat.made,
                                attempted: stat.attempted, percent: stat.fgPercent)
                    }
                }
            }
        }
    }

    private var arc: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Arc")
            Panel {
                VStack(alignment: .leading, spacing: 14) {
                    if let angle = session.avgReleaseAngleDeg {
                        HStack(alignment: .firstTextBaseline) {
                            StatValue(value: "\(Int(angle.rounded()))°", caption: "average launch angle")
                            Spacer()
                            if let spread = session.consistencyScore {
                                StatValue(value: "±\(String(format: "%.1f", spread))°", caption: "shot to shot", size: 26)
                            }
                        }
                        ArcGauge(angle: angle)
                        Text(arcAdvice(angle))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func arcAdvice(_ angle: Double) -> String {
        if angle < HoopTrack.ShotScience.optimalReleaseAngleMin {
            return "On the flat side. A little more arc gives the ball a bigger target."
        }
        if angle > HoopTrack.ShotScience.optimalReleaseAngleMax {
            return "Very high arc. Good for touch, but it costs range."
        }
        return "Right in the 43–57° window most shooters aim for."
    }

    // MARK: Shot list

    private var shotList: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Shots", trailing: "Tap to flip")
            VStack(spacing: 0) {
                ForEach(Array(shots.enumerated()), id: \.element.id) { index, shot in
                    if index > 0 { Hairline(inset: 56) }
                    ShotListRow(shot: shot, number: index + 1, isHighlighted: shot.id == highlighted) {
                        hapticService.tap()
                        highlighted = shot.id
                        dataService.updateShot(shot, result: shot.isMake ? .miss : .make)
                    }
                    .contextMenu {
                        Button("Remove shot", systemImage: "trash", role: .destructive) {
                            dataService.deleteShot(shot)
                        }
                    }
                }
            }
            .background(Color.panel, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        }
    }

    // MARK: Other drill types

    private var dribbleDetails: some View {
        Panel {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    StatValue(value: String(format: "%.1f", session.avgDribblesPerSec ?? 0), caption: "per second")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    StatValue(value: String(format: "%.1f", session.maxDribblesPerSec ?? 0), caption: "fastest")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    StatValue(value: "\(session.dribbleCombosDetected ?? 0)", caption: "hand switches")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let balance = session.handBalanceFraction {
                    HandBalanceBar(leftFraction: balance)
                }
            }
        }
    }

    private var agilityDetails: some View {
        Panel {
            HStack {
                StatValue(value: session.bestShuttleRunSeconds.map { String(format: "%.2fs", $0) } ?? "–",
                          caption: "best shuttle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                StatValue(value: session.bestLaneAgilitySeconds.map { String(format: "%.2fs", $0) } ?? "–",
                          caption: "best lane agility")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Badges

    private var badges: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Badges")
            Panel {
                if badgeChanges.isEmpty, let reason = badgeSkipReason {
                    Text(reason)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 12) {
                        ForEach(badgeChanges, id: \.badgeID) { change in
                            HStack(spacing: 12) {
                                Image(systemName: change.badgeID.skillDimension.systemImage)
                                    .foregroundStyle(Color.leather)
                                    .frame(width: 24)
                                Text(change.badgeID.displayName)
                                    .font(.body.weight(.medium))
                                Spacer()
                                Text(change.previousRank == nil ? "New" : "Up")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                BadgeRankPill(rank: change.newRank)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Video

    private var hasVideo: Bool {
        guard let name = session.videoFileName else { return false }
        return FileManager.default.fileExists(atPath: SessionRecorder.directory.appendingPathComponent(name).path)
    }

    private var video: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Video")
            Panel {
                VStack(spacing: 14) {
                    Button {
                        showReplay = true
                    } label: {
                        Label("Watch replay", systemImage: "play.rectangle.fill")
                    }
                    .buttonStyle(.secondary)
                    Toggle(isOn: Binding(
                        get: { session.videoPinnedByUser },
                        set: { pinned in
                            session.videoPinnedByUser = pinned
                            try? dataService.modelContext.save()
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Keep this video")
                            Text("Otherwise it's deleted automatically after a while.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Pieces

/// The flagged shots to watch, fixed when checking starts: answering one
/// unflags it, which would otherwise reshuffle the list mid-check.
struct ShotCheckBatch: Identifiable {
    let id = UUID()
    let shots: [ShotRecord]
}

struct ZoneRow: View {
    let name: String
    let made: Int
    let attempted: Int
    let percent: Double

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(name).font(.subheadline.weight(.medium))
                Spacer()
                Text("\(made)/\(attempted)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("\(Int(percent.rounded()))%")
                    .font(.score(20))
                    .foregroundStyle(Color.shooting(percent))
                    .frame(width: 52, alignment: .trailing)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.panelRaised)
                    Capsule()
                        .fill(Color.shooting(percent))
                        .frame(width: max(4, geo.size.width * percent / 100))
                }
            }
            .frame(height: 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name): \(made) of \(attempted), \(Int(percent.rounded())) percent")
    }
}

private struct ShotListRow: View {
    let shot: ShotRecord
    let number: Int
    let isHighlighted: Bool
    let onFlip: () -> Void

    var body: some View {
        Button(action: onFlip) {
            HStack(spacing: 14) {
                Image(systemName: shot.isMake ? "checkmark" : "xmark")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(Color.onLeather)
                    .frame(width: 28, height: 28)
                    .background(shot.result.color, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text("Shot \(number)")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if shot.needsReview {
                    Text("Check")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.leather)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.leather.opacity(0.15), in: Capsule())
                } else if shot.isUserCorrected {
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, Metrics.cardPadding)
            .padding(.vertical, 10)
            .background(isHighlighted ? Color.white.opacity(0.04) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Shot \(number), \(shot.isMake ? "make" : "miss"), \(detail)")
        .accessibilityHint("Double-tap to change to \(shot.isMake ? "miss" : "make")")
    }

    private var detail: String {
        var parts = [shot.zone.displayName]
        if let angle = shot.releaseAngleDeg { parts.append("\(Int(angle.rounded()))° arc") }
        return parts.joined(separator: " · ")
    }
}

/// Horizontal gauge from 25° to 75° with the 43–57° window shaded.
struct ArcGauge: View {
    let angle: Double
    private let range = 25.0...75.0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x = { (a: Double) -> CGFloat in
                CGFloat((a.clamped(to: range) - range.lowerBound) / (range.upperBound - range.lowerBound)) * w
            }
            ZStack(alignment: .leading) {
                Capsule().fill(Color.panelRaised).frame(height: 6)
                Capsule()
                    .fill(Color.make.opacity(0.35))
                    .frame(width: x(HoopTrack.ShotScience.optimalReleaseAngleMax) - x(HoopTrack.ShotScience.optimalReleaseAngleMin),
                           height: 6)
                    .offset(x: x(HoopTrack.ShotScience.optimalReleaseAngleMin))
                Circle()
                    .fill(Color.white)
                    .frame(width: 14, height: 14)
                    .offset(x: x(angle) - 7)
            }
            .frame(height: 14)
        }
        .frame(height: 14)
        .accessibilityHidden(true)
    }
}

/// Left / right split bar for dribble sessions.
struct HandBalanceBar: View {
    let leftFraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Left \(Int((leftFraction * 100).rounded()))%")
                Spacer()
                Text("Right \(Int(((1 - leftFraction) * 100).rounded()))%")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            GeometryReader { geo in
                HStack(spacing: 2) {
                    Capsule().fill(Color.leather)
                        .frame(width: max(4, geo.size.width * leftFraction))
                    Capsule().fill(Color.panelRaised)
                }
            }
            .frame(height: 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Left hand \(Int((leftFraction * 100).rounded())) percent")
    }
}
