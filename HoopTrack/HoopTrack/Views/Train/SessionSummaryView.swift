// SessionSummaryView.swift
// Post-session summary — FG%, shot chart, zone breakdown,
// and Shot Science highlights (Phase 3 fields shown if available).

import SwiftUI
import SwiftData

struct SessionSummaryView: View {

    let session: TrainingSession
    var badgeChanges: [BadgeTierChange] = []
    var badgeSkipReason: String? = nil
    let onDone: () -> Void

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var hapticService: HapticService
    @Query private var profiles: [PlayerProfile]
    @State private var showShareSheet = false
    @State private var selectedShotForReview: ShotRecord? = nil
    @State private var showReplay = false
    @State private var animatedFG: Double = 0
    @State private var isPinned: Bool = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {

                    // MARK: Hero stats
                    heroSection

                    // MARK: Video retention (Phase 10)
                    if session.videoFileName != nil {
                        videoSection
                    }

                    // MARK: Shot chart
                    shotChartSection

                    // MARK: Zone breakdown
                    zoneSection

                    // MARK: Shot Science (Phase 3 — shown when data is available)
                    if hasShotScienceData {
                        shotScienceSection
                    }

                    // MARK: Shot-by-shot review
                    shotListSection

                    // MARK: Badges Updated (Phase 5B)
                    BadgesUpdatedSection(changes: badgeChanges, skipReason: badgeSkipReason)
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .navigationTitle("Session Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        hapticService.tap()
                        showShareSheet = true
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
                if session.videoFileName != nil {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            hapticService.tap()
                            showReplay = true
                        } label: {
                            Label("Replay", systemImage: "play.rectangle.fill")
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        hapticService.tap()
                        onDone()
                    }
                    .bold()
                    .tint(.orange)
                }
            }
            .onAppear {
                hapticService.milestone()
            }
            .fullScreenCover(isPresented: $showReplay) {
                SessionReplayView(session: session)
            }
        }
    }

    // MARK: - Sections

    private var heroSection: some View {
        VStack(spacing: 8) {
            EmptyView()
                .modifier(AnimatedCounterModifier(currentValue: animatedFG, format: "%.0f%%"))
                .font(.system(size: 72, weight: .black, design: .rounded))
                .foregroundStyle(.orange)
                .animation(.easeOut(duration: 0.6), value: animatedFG)

            Text("\(session.shotsMade) makes / \(session.shotsAttempted) attempts")
                .font(.title3)
                .foregroundStyle(.secondary)

            HStack(spacing: 20) {
                Label(session.formattedDuration, systemImage: "clock")
                Label(session.drillType.rawValue,  systemImage: session.drillType.systemImage)
                if !session.locationTag.isEmpty {
                    Label(session.locationTag, systemImage: "location")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
        .onAppear {
            animatedFG = session.fgPercent
            isPinned = session.videoPinnedByUser
        }
    }

    private var retentionDays: Int {
        profiles.first?.videosAutoDeleteDays ?? HoopTrack.Storage.defaultVideoRetainDays
    }

    private var expiryText: String {
        retentionDays == 0 ? "Never auto-deletes." : "Auto-deletes in \(retentionDays) days."
    }

    private var videoSection: some View {
        HStack(spacing: 12) {
            Image(systemName: isPinned ? "bookmark.fill" : "bookmark")
                .font(.title3)
                .foregroundStyle(isPinned ? Color.orange : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Save video")
                    .font(.subheadline.bold())
                Text(isPinned ? "Kept on this device until you unpin." : expiryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: $isPinned)
                .labelsHidden()
                .tint(.orange)
                .onChange(of: isPinned) { _, newValue in
                    session.videoPinnedByUser = newValue
                    try? modelContext.save()
                    hapticService.tap()
                }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isPinned ? "Video saved" : "Video \(expiryText.lowercased())")
        .accessibilityHint("Toggle to keep or auto-delete this session's video")
    }

    private var shotChartSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Shot Chart")
                .font(.headline)

            CourtMapView(shots: session.shots,
                         highlightedShot: selectedShotForReview)
            CourtMapLegend()
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var zoneSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Zone Breakdown")
                .font(.headline)

            ForEach(session.zoneStats, id: \.zone.rawValue) { stat in
                HStack {
                    Text(stat.zone.rawValue)
                        .font(.subheadline)
                        .frame(width: 120, alignment: .leading)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.secondary.opacity(0.2))
                            Capsule()
                                .fill(Color.orange.gradient)
                                .frame(width: geo.size.width * (stat.fgPercent / 100))
                        }
                    }
                    .frame(height: 8)

                    Text(String(format: "%.0f%%", stat.fgPercent))
                        .font(.subheadline.bold())
                        .frame(width: 48, alignment: .trailing)
                        .foregroundStyle(.orange)

                    Text("\(stat.made)/\(stat.attempted)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }

            if session.zoneStats.isEmpty {
                Text("No zone data (shot positions not mapped)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var shotScienceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Shot Science", systemImage: "waveform.path.ecg")
                .font(.headline)

            StatCardGrid {
                if let angle = session.avgReleaseAngleDeg {
                    StatCard(title: "Release Angle",
                             value: String(format: "%.1f°", angle),
                             subtitle: "Optimal: 43–57°",
                             accent: angle >= HoopTrack.ShotScience.optimalReleaseAngleMin
                                 && angle <= HoopTrack.ShotScience.optimalReleaseAngleMax ? .green : .red)
                }
                if let time = session.avgReleaseTimeMs {
                    StatCard(title: "Release Time",
                             value: String(format: "%.0f ms", time),
                             accent: .blue)
                }
                if let jump = session.avgVerticalJumpCm {
                    StatCard(title: "Avg Vertical",
                             value: String(format: "%.0f cm", jump),
                             accent: .purple)
                }
                if let consistency = session.consistencyScore {
                    StatCard(title: "Consistency",
                             value: String(format: "%.1f°", consistency),
                             subtitle: "Lower = more consistent",
                             accent: consistency < 3 ? .green : .orange)
                }
            }
        }
    }

    private var shotListSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Shot Review")
                .font(.headline)

            LazyVStack(spacing: 8) {
                ForEach(session.shots.sorted { $0.sequenceIndex < $1.sequenceIndex }) { shot in
                    ShotReviewRow(shot: shot, isSelected: shot.id == selectedShotForReview?.id)
                        .onTapGesture {
                            hapticService.tap()
                            selectedShotForReview = selectedShotForReview?.id == shot.id
                                ? nil : shot
                        }
                }
            }
        }
    }

    // MARK: - Helpers

    private var hasShotScienceData: Bool {
        session.avgReleaseAngleDeg != nil
        || session.avgReleaseTimeMs != nil
        || session.avgVerticalJumpCm != nil
    }
}

// MARK: - ShotReviewRow
private struct ShotReviewRow: View {
    let shot: ShotRecord
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Shot number
            Text("#\(shot.sequenceIndex)")
                .font(.caption.bold().monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 30)

            // Make/miss indicator
            Image(systemName: shot.isMake ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(shot.isMake ? .green : .red)
                .font(.title3)

            // Zone + type
            VStack(alignment: .leading, spacing: 2) {
                Text(shot.zone.rawValue)
                    .font(.subheadline)
                Text(shot.shotType.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let angle = shot.releaseAngleDeg {
                Text(String(format: "%.0f°", angle))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(
                        angle >= HoopTrack.ShotScience.optimalReleaseAngleMin
                        && angle <= HoopTrack.ShotScience.optimalReleaseAngleMax
                            ? .green : .orange
                    )
            }

            // Correction badge
            if shot.isUserCorrected {
                Image(systemName: "pencil.circle")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(
            isSelected
                ? AnyShapeStyle(Color.orange.opacity(0.12))
                : AnyShapeStyle(Color(.systemBackground).opacity(0.01)),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.orange.opacity(0.4) : .clear, lineWidth: 1)
        )
    }
}
