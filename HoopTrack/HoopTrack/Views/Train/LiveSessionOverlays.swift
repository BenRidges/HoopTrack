// LiveSessionOverlays.swift
// The live screen's session-option pieces, kept apart from LiveSessionView
// so they can be drawn on their own (ScreenSnapshotTests): the best to
// beat, the drill step, setup tips, the "move on" banner and the
// still-shooting question. Everything is sized to read from where you
// shoot, a few metres from the phone.

import SwiftUI

/// Your best (or goal) under the score.
struct SessionTargetPill: View {
    let target: SessionTarget
    let makes: Int
    let attempts: Int

    var body: some View {
        let met = target.isMet(makes: makes, attempts: attempts)
        HStack(spacing: 6) {
            Image(systemName: met ? "star.fill" : "flag.fill")
                .font(.caption.weight(.bold))
            Text(target.line(makes: makes, attempts: attempts))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
        }
        .foregroundStyle(met ? Color.make : .white)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.5), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// The drill step under the status: "SPOT 2 OF 5  Right wing  3 to go".
struct DrillStepPill: View {
    let progress: DrillProgress

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if progress.isFinished {
                Label("Drill done", systemImage: "checkmark.circle.fill")
                    .font(.title3.bold())
                    .foregroundStyle(Color.make)
            } else {
                Text(progress.stepLabel.uppercased())
                    .font(.label)
                    .foregroundStyle(.white.opacity(0.7))
                Text(progress.spot)
                    .font(.title3.bold())
                Text("\(progress.shotsToGo) to go")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.leather)
                    .monospacedDigit()
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.55), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(progress.line)
    }
}

/// A setup tip, big enough to read while you walk back from the phone.
struct SetupTipCard: View {
    let advice: SetupAdvice

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(advice.isGood ? Color.make : Color.leather)
            Text(advice.title)
                .font(.score(40))
                .foregroundStyle(advice.isGood ? Color.make : .white)
            Text(advice.detail)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 18)
        .frame(maxWidth: 400)
        .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch advice {
        case .good:      return "checkmark.circle.fill"
        case .rimCutOff: return "viewfinder"
        case .tooClose:  return "arrow.down.right.and.arrow.up.left"
        case .tooFar:    return "arrow.up.left.and.arrow.down.right"
        case .tiltUp:    return "arrow.up"
        case .tiltDown:  return "arrow.down"
        case .turnLeft:  return "arrow.left"
        case .turnRight: return "arrow.right"
        }
    }
}

/// "Move to the right wing" when a drill step is done.
struct DrillCueBanner: View {
    let cue: DrillCue

    var body: some View {
        Text(cue.text)
            .font(.score(44))
            .foregroundStyle(cue.isFinished ? Color.make : .white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
            .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .allowsHitTesting(false)
            .accessibilityHidden(true)    // the announcer says it
    }
}

/// Paused a long time: is the session over?
struct StillShootingCard: View {
    let onEnd: () -> Void
    let onKeepGoing: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 14) {
                Text("Still shooting?")
                    .font(.score(44))
                Text("Nobody's taken a shot for a while. The session ends and saves itself in a few minutes.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button("End session", action: onEnd)
                        .buttonStyle(.secondary)
                    Button("Keep going", action: onKeepGoing)
                        .buttonStyle(.primary)
                }
                .frame(maxWidth: 340)
                .padding(.top, 4)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: 440)
            .background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
    }
}

/// Under a timed drill's clock until the first shot.
struct ClockWaitingTag: View {
    var body: some View {
        Text("Starts on your first shot")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.5), in: Capsule())
    }
}
