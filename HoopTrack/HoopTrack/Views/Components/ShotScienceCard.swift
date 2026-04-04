// HoopTrack/Views/Components/ShotScienceCard.swift
// Reusable card displaying per-shot biomechanics.
// Used in SessionReplayView overlay and ShotReviewRow expansion.

import SwiftUI

struct ShotScienceCard: View {
    let shot: ShotRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: shot.isMake ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(shot.isMake ? .green : .red)
                Text("Shot #\(shot.sequenceIndex) · \(shot.zone.rawValue)")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
            }

            if hasAnyData {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    if let angle = shot.releaseAngleDeg {
                        scienceCell(
                            label: "Release Angle",
                            value: String(format: "%.1f°", angle),
                            isOptimal: angle >= HoopTrack.ShotScience.optimalReleaseAngleMin
                                    && angle <= HoopTrack.ShotScience.optimalReleaseAngleMax
                        )
                    }
                    if let time = shot.releaseTimeMs {
                        scienceCell(label: "Release Time",
                                    value: String(format: "%.0f ms", time))
                    }
                    if let jump = shot.verticalJumpCm {
                        scienceCell(label: "Vertical",
                                    value: String(format: "%.0f cm", jump))
                    }
                    if let leg = shot.legAngleDeg {
                        scienceCell(label: "Leg Angle",
                                    value: String(format: "%.1f°", leg))
                    }
                    if let speed = shot.shotSpeedMph {
                        scienceCell(label: "Ball Speed",
                                    value: String(format: "%.1f mph", speed))
                    }
                }
            } else {
                Text("No biomechanics data for this shot")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(16)
        .background(.ultraThinMaterial.opacity(0.88),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var hasAnyData: Bool {
        shot.releaseAngleDeg != nil || shot.releaseTimeMs  != nil
        || shot.verticalJumpCm  != nil || shot.legAngleDeg != nil
        || shot.shotSpeedMph    != nil
    }

    @ViewBuilder
    private func scienceCell(label: String, value: String, isOptimal: Bool? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.65))
            Text(value)
                .font(.subheadline.bold())
                .foregroundStyle(
                    isOptimal == true  ? .green  :
                    isOptimal == false ? .red    : .white
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.white.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
