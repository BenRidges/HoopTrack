// AgilitySessionSummaryView.swift
// Post-agility drill summary: best times, total attempts, duration, and badge updates.

import SwiftUI

struct AgilitySessionSummaryView: View {

    let session:         TrainingSession
    let shuttleAttempts: [Double]
    let laneAttempts:    [Double]
    var badgeChanges:    [BadgeTierChange] = []
    let onDone:          () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    heroSection
                    attemptsSection
                    BadgesUpdatedSection(changes: badgeChanges)
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .navigationTitle("Drill Complete")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDone() }
                }
            }
        }
    }

    // MARK: - Hero Stats

    private var heroSection: some View {
        HStack(spacing: 0) {
            statCell(
                title: "Best Shuttle",
                value: shuttleAttempts.min().map { String(format: "%.2fs", $0) } ?? "—"
            )
            Divider().frame(height: 50)
            statCell(
                title: "Best Lane Agility",
                value: laneAttempts.min().map { String(format: "%.2fs", $0) } ?? "—"
            )
            Divider().frame(height: 50)
            statCell(
                title: "Total Attempts",
                value: "\(shuttleAttempts.count + laneAttempts.count)"
            )
            Divider().frame(height: 50)
            statCell(
                title: "Duration",
                value: durationString
            )
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func statCell(title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title3.bold())
                .foregroundStyle(.orange)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var durationString: String {
        let d = Int(session.durationSeconds)
        return d >= 60
            ? String(format: "%d:%02d", d / 60, d % 60)
            : "\(d)s"
    }

    // MARK: - Attempt Log

    private var attemptsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !shuttleAttempts.isEmpty {
                attemptGroup(title: "Shuttle Run", attempts: shuttleAttempts)
            }
            if !laneAttempts.isEmpty {
                attemptGroup(title: "Lane Agility", attempts: laneAttempts)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func attemptGroup(title: String, attempts: [Double]) -> some View {
        let best = attempts.min()
        return VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.bold())
            ForEach(Array(attempts.enumerated()), id: \.offset) { idx, t in
                HStack {
                    Text("#\(idx + 1)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .leading)
                    Text(String(format: "%.2fs", t))
                        .font(.subheadline)
                    if t == best {
                        Image(systemName: "trophy.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    if let best, best < t {
                        Text(String(format: "+%.2fs", t - best))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
