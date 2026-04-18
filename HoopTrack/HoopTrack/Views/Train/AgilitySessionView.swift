// AgilitySessionView.swift
// Full-screen agility drill UI — metric selector, timer display,
// trigger cue, attempt history, end-session long press.

import SwiftUI
import SwiftData

struct AgilitySessionView: View {

    let namedDrill: NamedDrill?
    let onFinish: () -> Void

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var coordinator: SessionFinalizationCoordinator

    @StateObject private var viewModel = AgilitySessionViewModel()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var timerFontSize: CGFloat = 72

    @State private var isLongPressingEnd      = false
    @State private var endLongPressProgress: Double = 0
    @State private var endSessionTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // MARK: Metric Selector
                Picker("Metric", selection: $viewModel.selectedMetric) {
                    ForEach(AgilitySessionViewModel.AgilityMetric.allCases, id: \.self) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .padding()

                Spacer()

                // MARK: Timer Display
                Text(timerString)
                    .font(.system(size: timerFontSize, weight: .black, design: .monospaced))
                    .foregroundStyle(viewModel.timerState == .running ? Color.brandOrangeAccessible : .white)
                    .shadow(radius: 6)
                    .padding(.bottom, 8)

                // MARK: Trigger Cue
                triggerCue
                    .padding(.bottom, 32)

                // MARK: Attempt History (last 3)
                attemptHistory
                    .padding(.horizontal)

                // MARK: Best Time Banner
                if viewModel.bestShuttleSeconds != nil || viewModel.bestLaneSeconds != nil {
                    bestTimeBanner.padding(.horizontal).padding(.top, 8)
                }

                Spacer()

                // MARK: End Session Long Press
                endSessionButton
                    .padding(.horizontal)
                    .padding(.bottom, 40)
            }
        }
        .task {
            viewModel.configure(
                dataService:      DataService(modelContext: modelContext),
                coordinator:      coordinator,
                detectionService: VolumeButtonAgilityDetectionService()
            )
            try? viewModel.start(namedDrill: namedDrill)
        }
        .fullScreenCover(isPresented: $viewModel.isFinished) {
            if let result = viewModel.sessionResult {
                AgilitySessionSummaryView(
                    session:       result.session,
                    shuttleAttempts: viewModel.shuttleAttempts,
                    laneAttempts:    viewModel.laneAttempts,
                    badgeChanges:    result.badgeChanges
                ) {
                    viewModel.isFinished = false
                    onFinish()
                }
            }
        }
        .statusBarHidden(true)
    }

    // MARK: - Timer String

    private var timerString: String {
        let t = viewModel.elapsedSeconds
        let mins    = Int(t) / 60
        let secs    = Int(t) % 60
        let hundredths = Int((t - Double(Int(t))) * 100)
        return String(format: "%02d:%02d.%02d", mins, secs, hundredths)
    }

    // MARK: - Trigger Cue

    private var triggerCue: some View {
        let isRunning = viewModel.timerState == .running
        return VStack(spacing: 12) {
            ZStack {
                Circle()
                    .strokeBorder(isRunning ? Color.orange : Color.white.opacity(0.4), lineWidth: 3)
                    .frame(width: 80, height: 80)
                    .scaleEffect(isRunning ? (reduceMotion ? 1.0 : 1.1) : 1.0)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                               value: isRunning)
                Image(systemName: "speaker.wave.2.fill")
                    .font(.title2)
                    .foregroundStyle(isRunning ? Color.brandOrangeAccessible : .white.opacity(0.7))
            }
            Text(isRunning ? "Vol+ to Stop" : "Vol+ to Start")
                .font(.headline)
                .foregroundStyle(isRunning ? Color.brandOrangeAccessible : .white.opacity(0.8))
        }
    }

    // MARK: - Attempt History

    private var attemptHistory: some View {
        let attempts = viewModel.currentAttempts
        let best     = attempts.min()
        let last3    = attempts.suffix(3).reversed()

        return VStack(alignment: .leading, spacing: 6) {
            if attempts.isEmpty {
                Text("No attempts yet")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                ForEach(Array(last3.enumerated()), id: \.offset) { _, attempt in
                    HStack {
                        if attempt == best {
                            Image(systemName: "trophy.fill")
                                .foregroundStyle(Color.brandOrangeAccessible)
                                .font(.caption)
                        }
                        Text(String(format: "%.2fs", attempt))
                            .font(.subheadline.bold())
                            .foregroundStyle(attempt == best ? Color.brandOrangeAccessible : .white)
                        Spacer()
                    }
                }
            }
        }
        .padding(12)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Best Time Banner

    private var bestTimeBanner: some View {
        HStack(spacing: 16) {
            if let shuttle = viewModel.bestShuttleSeconds {
                VStack(spacing: 2) {
                    Text("Best Shuttle")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                    Text(String(format: "%.2fs", shuttle))
                        .font(.subheadline.bold())
                        .foregroundStyle(Color.brandOrangeAccessible)
                }
            }
            if let lane = viewModel.bestLaneSeconds {
                VStack(spacing: 2) {
                    Text("Best Lane Agility")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                    Text(String(format: "%.2fs", lane))
                        .font(.subheadline.bold())
                        .foregroundStyle(Color.brandOrangeAccessible)
                }
            }
        }
        .padding(10)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - End Session Button (long press, same pattern as LiveSessionView)

    private var endSessionButton: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.white.opacity(0.12))
                .frame(height: 54)

            Capsule()
                .fill(Color.orange.opacity(0.8))
                .frame(width: max(0, endLongPressProgress) * UIScreen.main.bounds.width * 0.9,
                       height: 54)
                .animation(.linear(duration: 0.05), value: endLongPressProgress)

            Text(isLongPressingEnd ? "Hold to finish…" : "Hold to End Session")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isLongPressingEnd {
                        isLongPressingEnd = true
                        endSessionTask = Task {
                            let steps = 30
                            for i in 1...steps {
                                try? await Task.sleep(for: .milliseconds(50))
                                endLongPressProgress = Double(i) / Double(steps)
                            }
                            await viewModel.endSession()
                        }
                    }
                }
                .onEnded { _ in
                    isLongPressingEnd = false
                    endLongPressProgress = 0
                    endSessionTask?.cancel()
                    endSessionTask = nil
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("End Session")
        .accessibilityHint("Double-tap to end the agility session and save results")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            Task { await viewModel.endSession() }
        }
    }
}
