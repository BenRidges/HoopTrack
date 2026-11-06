// PlayoffHUD.swift
// The live session's playoff layer: the scoreboard that replaces the plain
// makes/attempts block, and the card that marks each result. Readable from
// the free-throw line: big numbers, pips for makes and misses.

import SwiftUI

/// Top-left of the live HUD during a playoff sitting.
struct PlayoffScoreboard: View {
    let run: PlayoffRun
    let comebackZone: CourtZone?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(caption)
                .font(.label)
                .foregroundStyle(.white.opacity(0.7))
            switch run.status {
            case .playing:
                HStack(alignment: .center, spacing: 14) {
                    count(run.gameMakes, of: run.makesToWin)
                    VStack(alignment: .leading, spacing: 6) {
                        Pips(filled: run.gameMakes, total: run.makesToWin, color: .make)
                        Pips(filled: run.gameMisses, total: run.missesToLose, color: .miss)
                    }
                }
                Text("Series \(run.wins)–\(run.losses)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
            case .comeback:
                count(run.comebackMakes, of: run.comebackTarget)
                Text(comebackZone.map { "Makes · \($0.displayName)" } ?? "Makes to earn the round back")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
            case .champion, .retired:
                Label(run.status == .champion ? "Champion" : "Run ended",
                      systemImage: run.status == .champion ? "trophy.fill" : "flag.checkered")
                    .font(.score(32))
                    .foregroundStyle(run.status == .champion ? Color.leather : .white)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    private var caption: String {
        switch run.status {
        case .playing:  return "\(run.roundName.uppercased()) · GAME \(run.gameNumber)"
        case .comeback: return "COMEBACK · \(run.roundName.uppercased())"
        case .champion, .retired: return "PLAYOFFS · \(run.spot.rawValue.uppercased())"
        }
    }

    private func count(_ value: Int, of total: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("\(value)")
                .font(.score(56))
                .contentTransition(.numericText())
            Text("/\(total)")
                .font(.score(30))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private var spoken: String {
        switch run.status {
        case .playing:
            return "\(run.roundName), game \(run.gameNumber). \(run.gameMakes) of \(run.makesToWin) makes, \(run.gameMisses) misses. Series \(run.wins) to \(run.losses)."
        case .comeback:
            return "Comeback: \(run.comebackMakes) of \(run.comebackTarget) makes."
        case .champion: return "Champion."
        case .retired:  return "Run ended."
        }
    }
}

/// A row of dots: `filled` of `total`.
struct Pips: View {
    let filled: Int
    let total: Int
    let color: Color
    var size: CGFloat = 10

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<max(total, 0), id: \.self) { index in
                Circle()
                    .fill(index < filled ? color : Color.white.opacity(0.18))
                    .frame(width: size, height: size)
            }
        }
        .animation(.snappy, value: filled)
    }
}

/// Marks a game or series result in the middle of the screen. Game results
/// clear themselves; the big moments wait for a tap.
struct PlayoffMomentCard: View {
    let moment: PlayoffMoment
    let run: PlayoffRun
    let comebackZone: CourtZone?
    let onDismiss: () -> Void
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(accent)
            }
            Text(title)
                .font(.score(46))
                .foregroundStyle(accent)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if waitsForTap {
                HStack(spacing: 12) {
                    if case .champion = moment.event {
                        Button("Keep shooting", action: onDismiss)
                            .buttonStyle(.secondary)
                        Button("Finish", action: onFinish)
                            .buttonStyle(.primary)
                    } else {
                        Button(buttonTitle, action: onDismiss)
                            .buttonStyle(.primary)
                    }
                }
                .frame(maxWidth: 320)
                .padding(.top, 6)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .frame(maxWidth: 420)
        .background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { if !waitsForTap { onDismiss() } }
        .task(id: moment.id) {
            guard !waitsForTap else { return }
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { onDismiss() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private var waitsForTap: Bool {
        switch moment.event {
        case .seriesWon, .eliminated, .champion: return true
        case .gameWon, .gameLost, .comebackComplete: return false
        }
    }

    private var icon: String? {
        switch moment.event {
        case .champion:         return "trophy.fill"
        case .seriesWon:        return "arrow.up.forward.circle.fill"
        case .eliminated:       return "arrow.uturn.backward.circle.fill"
        case .comebackComplete: return "bolt.circle.fill"
        case .gameWon, .gameLost: return nil
        }
    }

    private var accent: Color {
        switch moment.event {
        case .gameLost, .eliminated: return .miss
        case .gameWon:               return .make
        default:                     return .leather
        }
    }

    private var title: String {
        switch moment.event {
        case .gameWon(let game):  return "GAME \(game.number) · WIN"
        case .gameLost(let game): return "GAME \(game.number) · LOSS"
        case .seriesWon(let round, _): return "\(PlayoffRun.roundName(round).uppercased()) WON"
        case .eliminated:         return "ELIMINATED"
        case .champion:           return "CHAMPION"
        case .comebackComplete:   return "YOU'RE BACK IN"
        }
    }

    private var detail: String {
        switch moment.event {
        case .gameWon(let game), .gameLost(let game):
            return "\(game.makes) for \(game.makes + game.misses) · Series \(game.seriesWins)–\(game.seriesLosses)"
        case .seriesWon(_, let game):
            return "Took it \(game.seriesWins)–\(game.seriesLosses). Next: the \(run.roundName.lowercased()), \(run.makesToWin) makes a game."
        case .eliminated(let round, let game):
            let spot = comebackZone.map { ", ideally from \($0.displayName.lowercased())" } ?? ""
            return "Lost \(game.seriesWins)–\(game.seriesLosses) in the \(PlayoffRun.roundName(round).lowercased()). Make \(run.comebackTarget)\(spot) to earn another shot."
        case .champion:
            return "\(run.spot.rawValue) playoffs won in \(run.games.count) games."
        case .comebackComplete(let round):
            return "\(PlayoffRun.roundName(round)), from 0–0."
        }
    }

    private var buttonTitle: String {
        if case .eliminated = moment.event { return "Start the comeback" }
        return "Keep going"
    }
}
