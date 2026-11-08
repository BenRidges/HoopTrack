// LiveHUD.swift
// What the live shooting screen draws over the camera. The camera owns the
// screen: two readings (the score, the clock) sit straight on the picture
// over a soft fade, and the screen's own edge lights green or red with each
// call. Nothing else shows unless the setup or the session needs it, and
// every button waits for a tap on the picture.
//
// Two arrangements (Profile → Session options → Live screen):
//   Quiet   score bottom-left, clock bottom-right; one row of buttons on tap.
//   Centre  score bottom-centre; Pause and End always in the bottom corners;
//           Miss and Make either side of the score on tap.
// The top of the picture is left alone: with the phone behind the shooter,
// that's where the rim is.
//
// LiveHUD only draws a LiveReadout, so every state can be rendered without
// a camera or a session (ScreenSnapshotTests).

import SwiftUI

/// Everything the live screen shows, worked out from the session.
struct LiveReadout: Equatable {
    /// The line above the score: the call just made, or what the session's doing.
    struct Word: Equatable {
        var text: String
        var color: Color
        /// A call (MAKE, MISS) rather than a state (PAUSED…): set bigger.
        var isCall = true
    }

    /// The named drill's line.
    enum Drill: Equatable {
        /// "Left wing · 3 to go", or "Set 2 · 7 to go".
        case step(String, toGo: Int)
        /// A step just finished: "Move to the left corner".
        case cue(String)
        /// "Drill done · 18 of 25".
        case done(String)
    }

    /// Setup guidance, in place of the score until the first shot.
    struct Setup: Equatable {
        var title: String
        var detail: String
        var isGood = false
        /// The "Score by hand instead" way out, while the hoop is being found.
        var offersHandScoring = false
    }

    /// The line round the screen.
    struct Edge: Equatable {
        var color: Color
        /// Slowly fades in and out: something needs doing.
        var breathing = false
    }

    var layout: LiveLayout = .quiet
    var word: Word?
    var makes = 0
    var attempts = 0
    var percent: Double?
    var target: SessionTarget?
    var drill: Drill?
    var clock = "0:00"
    /// Under the clock: "Starts on your first shot".
    var clockNote: String?
    var playoff: PlayoffRun?
    var comebackZone: CourtZone?
    var setup: Setup?
    var edge: Edge?
    /// "Tap for controls", for a moment after tracking starts.
    var tapHint = false
}

/// The buttons, and whether they're up.
struct LiveControls: Equatable {
    var shown = false
    /// Scoring by hand: Make and Miss are the input, so they're bigger.
    var large = false
    var canUndo = false
    /// The call a tap of the other result would change, if any.
    var changes: ShotResult?
    var enabled = true
    var isEnding = false
}

struct LiveActions {
    var pause: () -> Void = {}
    var end: () -> Void = {}
    var undo: () -> Void = {}
    var log: (ShotResult) -> Void = { _ in }
    var scoreByHand: () -> Void = {}
}

struct LiveHUD: View {
    let readout: LiveReadout
    let controls: LiveControls
    var actions = LiveActions()

    var body: some View {
        ZStack {
            BottomFade()
            CallEdge(edge: readout.edge)
            Group {
                switch readout.layout {
                case .quiet:  quiet
                case .centre: centre
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
        .animation(.easeInOut(duration: 0.2), value: controls.shown)
        .animation(.easeInOut(duration: 0.25), value: readout.setup)
    }

    /// Setup guidance gives way to the buttons while you're at the phone.
    private var setup: LiveReadout.Setup? { controls.shown ? nil : readout.setup }

    // MARK: - Quiet

    private var quiet: some View {
        ZStack(alignment: .bottom) {
            HStack(alignment: .bottom, spacing: 16) {
                if setup == nil {
                    ScoreReadout(readout: readout, alignment: .leading)
                        .transition(.opacity)
                }
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    VStack(alignment: .trailing, spacing: 5) {
                        Text(readout.clock)
                            .font(.score(36))
                            .foregroundStyle(.white.opacity(0.9))
                            .accessibilityLabel("Time \(readout.clock)")
                        if let note = readout.clockNote {
                            Text(note).font(.footnote.weight(.semibold))
                        } else if readout.tapHint, !controls.shown {
                            Text("Tap for controls")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.75))
                                .transition(.opacity)
                        }
                    }
                    .liveShadow()
                    if controls.shown {
                        Group {
                            PauseButton(action: actions.pause)
                            HoldToEndButton(width: 132, height: 44, isBusy: controls.isEnding, onConfirm: actions.end)
                                .padding(.trailing, 8)
                            UndoButton(enabled: controls.canUndo, action: actions.undo)
                            ShotButton(result: .miss, large: controls.large, changes: controls.changes, action: actions.log)
                            ShotButton(result: .make, large: controls.large, changes: controls.changes, action: actions.log)
                        }
                        .disabled(!controls.enabled)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                    }
                }
                // Its natural width: squeezed, the clock is what would give.
                .fixedSize()
            }
            if let setup {
                SetupMessage(setup: setup, onScoreByHand: actions.scoreByHand)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    // MARK: - Centre

    private var centre: some View {
        ZStack(alignment: .bottom) {
            HStack(alignment: .bottom) {
                PauseButton(action: actions.pause)
                Spacer()
                HoldToEndButton(width: 132, height: 44, isBusy: controls.isEnding, onConfirm: actions.end)
            }
            .disabled(controls.isEnding)
            if let setup {
                SetupMessage(setup: setup, onScoreByHand: actions.scoreByHand)
                    .padding(.bottom, 52)
                    .transition(.opacity)
            } else {
                HStack(alignment: .center, spacing: 18) {
                    HStack(spacing: 12) {
                        if controls.shown {
                            UndoButton(enabled: controls.canUndo, action: actions.undo)
                            ShotButton(result: .miss, large: controls.large, changes: controls.changes, action: actions.log)
                        }
                    }
                    .frame(width: 150, alignment: .trailing)
                    ScoreReadout(readout: readout, alignment: .center)
                    HStack {
                        if controls.shown {
                            ShotButton(result: .make, large: controls.large, changes: controls.changes, action: actions.log)
                        }
                    }
                    .frame(width: 150, alignment: .leading)
                }
                .disabled(!controls.enabled)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}

// MARK: - The readings

/// The call word, the score and its lines, straight on the picture.
struct ScoreReadout: View {
    let readout: LiveReadout
    let alignment: HorizontalAlignment

    var body: some View {
        VStack(alignment: alignment, spacing: 4) {
            // Always takes its line, so the score doesn't jump when a call lands.
            Text(readout.word?.text ?? " ")
                .font(.score(readout.word?.isCall == false ? 22 : 28))
                .tracking(1.4)
                .foregroundStyle(readout.word?.color ?? .clear)
                .lineLimit(1)
                .contentTransition(.opacity)
            if let run = readout.playoff {
                PlayoffScoreboard(run: run, comebackZone: readout.comebackZone, alignment: alignment)
            } else {
                score
                if alignment == .leading { leadingLines } else { centreLine }
            }
        }
        .multilineTextAlignment(alignment == .leading ? .leading : .center)
        .liveShadow()
        .accessibilityElement(children: .combine)
    }

    private var score: some View {
        HStack(alignment: .lastTextBaseline, spacing: 3) {
            Text("\(readout.makes)")
                .font(.score(118))
                .contentTransition(.numericText(value: Double(readout.makes)))
            Text("/\(readout.attempts)")
                .font(.score(48))
                .foregroundStyle(.white.opacity(0.72))
                .contentTransition(.numericText(value: Double(readout.attempts)))
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .animation(.snappy(duration: 0.25), value: readout.makes)
        .animation(.snappy(duration: 0.25), value: readout.attempts)
        .accessibilityLabel("\(readout.makes.counted("make")) from \(readout.attempts.counted("shot"))")
    }

    @ViewBuilder
    private var leadingLines: some View {
        if readout.percent != nil || readout.target != nil {
            HStack(spacing: 10) {
                percent
                if let target = readout.target { targetText(target) }
            }
            .font(.system(size: 17, weight: .semibold))
        }
        if let drill = readout.drill {
            drillText(drill).padding(.top, 1)
        }
    }

    /// Centre: one line under the score: %, the drill (or the best), clock.
    private var centreLine: some View {
        HStack(spacing: 9) {
            percent
            if let drill = readout.drill {
                dot
                drillText(drill)
            } else if let target = readout.target {
                dot
                targetText(target)
            }
            dot
            Text(readout.clock)
                .font(.score(24))
                .accessibilityLabel("Time \(readout.clock)")
            if let note = readout.clockNote {
                Text(note).foregroundStyle(.white.opacity(0.8))
            }
        }
        .font(.system(size: 17, weight: .semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    @ViewBuilder
    private var percent: some View {
        if let pct = readout.percent {
            Text("\(Int(pct.rounded()))%")
                .foregroundStyle(Color.shooting(pct))
        } else {
            Text("–%").foregroundStyle(.white.opacity(0.6))
        }
    }

    private func targetText(_ target: SessionTarget) -> some View {
        let met = target.isMet(makes: readout.makes, attempts: readout.attempts)
        return Text(target.line(makes: readout.makes, attempts: readout.attempts))
            .foregroundStyle(met ? Color.make : .white.opacity(0.8))
    }

    @ViewBuilder
    private func drillText(_ drill: LiveReadout.Drill) -> some View {
        switch drill {
        case .step(let name, let toGo):
            Text("\(name)  \(Text("\(toGo) to go").foregroundStyle(Color.leather))")
                .font(.system(size: 17, weight: .semibold))
        case .cue(let text):
            Text(text)
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(Color.leather)
                .transition(.opacity)
        case .done(let text):
            Label(text, systemImage: "checkmark.circle.fill")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(Color.make)
        }
    }

    private var dot: some View {
        Text("·").foregroundStyle(.white.opacity(0.45))
    }
}

/// Setup guidance on the picture, bottom-centre: big enough to read while
/// walking back from the phone.
struct SetupMessage: View {
    let setup: LiveReadout.Setup
    var onScoreByHand: () -> Void = {}

    var body: some View {
        VStack(spacing: 6) {
            Text(setup.title)
                .font(.score(40))
                .foregroundStyle(setup.isGood ? Color.make : .white)
            Text(setup.detail)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)
            if setup.offersHandScoring {
                Button("Score by hand instead", action: onScoreByHand)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.leather)
                    .frame(minHeight: 44)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 440)
        .liveShadow()
        .accessibilityElement(children: .contain)
    }
}

// MARK: - The edge

/// A line round the screen's own corners: green or red for a moment with
/// each call, orange and breathing while something needs fixing, dim white
/// while paused, nothing otherwise.
struct CallEdge: View {
    let edge: LiveReadout.Edge?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    var body: some View {
        RoundedRectangle(cornerRadius: 42, style: .continuous)
            .strokeBorder(edge?.color ?? .clear, lineWidth: 4)
            .padding(5)
            .opacity(opacity)
            // In quickly with a call, out slowly after it.
            .animation(edge == nil ? .easeOut(duration: 0.6) : .easeOut(duration: 0.12), value: edge)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { breathe = true }
            }
    }

    private var opacity: Double {
        guard let edge else { return 0 }
        return edge.breathing && breathe && !reduceMotion ? 0.3 : 1
    }
}

/// Darkens the bottom of the picture just enough for white numbers.
struct BottomFade: View {
    var body: some View {
        LinearGradient(stops: [.init(color: .black.opacity(0.58), location: 0),
                               .init(color: .black.opacity(0.26), location: 0.45),
                               .init(color: .clear, location: 1)],
                       startPoint: .bottom, endPoint: .top)
            .frame(height: 180)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}

// MARK: - Buttons

struct PauseButton: View {
    var isPaused = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isPaused ? "play.fill" : "pause.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.black.opacity(0.62), in: Circle())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(isPaused ? "Resume" : "Pause")
    }
}

struct UndoButton: View {
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.black.opacity(0.62), in: Circle())
        }
        .buttonStyle(.pressable)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel("Undo last shot")
    }
}

/// Make or Miss. Right after a call, the other result changes it; the
/// button says so.
struct ShotButton: View {
    let result: ShotResult
    let large: Bool
    /// The call a tap would change, if any.
    let changes: ShotResult?
    let action: (ShotResult) -> Void

    private var isMake: Bool { result == .make }
    private var changesCall: Bool { changes != nil && changes != result }

    var body: some View {
        let size: CGFloat = large ? 72 : 58
        Button { action(result) } label: {
            Image(systemName: isMake ? "checkmark" : "xmark")
                .font(.system(size: size * 0.36, weight: .heavy))
                .foregroundStyle(Color.onLeather)
                .frame(width: size, height: size)
                .background(result.color, in: Circle())
                .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        }
        .buttonStyle(.pressable)
        .overlay(alignment: .top) {
            if changesCall {
                Text(isMake ? "Change to make" : "Change to miss")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(0.78), in: Capsule())
                    .fixedSize()
                    .offset(y: -34)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .accessibilityLabel(isMake ? "Make" : "Miss")
        .accessibilityHint(changesCall ? "Changes the last call to a \(isMake ? "make" : "miss")" : "")
        .accessibilityInputLabels([isMake ? "Make" : "Miss", isMake ? "Score" : "Missed"])
    }
}

extension View {
    /// Keeps text readable straight on the camera picture.
    func liveShadow() -> some View {
        shadow(color: .black.opacity(0.5), radius: 9, y: 2)
    }
}
