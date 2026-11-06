// AgilitySessionView.swift
// One giant button: tap to start a 3-2-1 countdown, tap again as you
// cross the line. Big enough to hit on the run.

import SwiftUI
import UIKit
import Combine

struct AgilitySessionView: View {

    let namedDrill: NamedDrill?
    let onFinish: (SessionEnd?) -> Void

    @EnvironmentObject private var dataService: DataService
    @EnvironmentObject private var coordinator: SessionFinalizationCoordinator
    @EnvironmentObject private var hapticService: HapticService
    @StateObject private var holder = Holder()

    final class Holder: ObservableObject {
        @Published var viewModel: AgilitySessionViewModel?
    }

    var body: some View {
        ZStack {
            Color.court.ignoresSafeArea()
            if let viewModel = holder.viewModel {
                AgilityContent(viewModel: viewModel, onFinish: onFinish)
            }
        }
        .onAppear {
            if holder.viewModel == nil {
                holder.viewModel = AgilitySessionViewModel(namedDrill: namedDrill, dataService: dataService,
                                                           coordinator: coordinator, haptics: hapticService)
            }
            holder.viewModel?.start()
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            holder.viewModel?.tearDown()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
}

private struct AgilityContent: View {
    @ObservedObject var viewModel: AgilitySessionViewModel
    let onFinish: (SessionEnd?) -> Void
    @State private var saveFailed = false

    var body: some View {
        VStack(spacing: 20) {
            Picker("Drill", selection: $viewModel.metric) {
                ForEach(AgilitySessionViewModel.Metric.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(isBusy)

            Button { viewModel.tap() } label: {
                VStack(spacing: 8) {
                    display
                    Text(prompt)
                        .font(.headline)
                        .foregroundStyle(promptColor)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(buttonBackground, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(prompt)

            attemptsList

            HoldToEndButton(isBusy: viewModel.isEnding, onConfirm: finish)
        }
        .padding(Metrics.screenPadding)
        .sessionErrorAlert($viewModel.errorMessage, saveFailed: $saveFailed,
                           retry: finish, close: { onFinish(nil) })
    }

    private func finish() {
        Task {
            guard let end = await viewModel.end() else { return }
            if case .failed = end { saveFailed = true } else { onFinish(end) }
        }
    }

    private var isBusy: Bool {
        switch viewModel.state {
        case .countdown, .running: return true
        default: return false
        }
    }

    @ViewBuilder
    private var display: some View {
        switch viewModel.state {
        case .ready:
            Text(viewModel.best.map { String(format: "%.2f", $0) } ?? "0.00")
                .font(.score(96))
                .foregroundStyle(.secondary)
        case .countdown(let n):
            Text("\(n)")
                .font(.score(160))
                .foregroundStyle(Color.leather)
                .contentTransition(.numericText())
        case .running(let since):
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                Text(String(format: "%.2f", context.date.timeIntervalSince(since)))
                    .font(.score(110))
                    .foregroundStyle(Color.onLeather)
            }
        case .recorded(let time):
            Text(String(format: "%.2f", time))
                .font(.score(110))
                .foregroundStyle(time <= (viewModel.best ?? time) ? Color.make : .primary)
        }
    }

    private var prompt: String {
        switch viewModel.state {
        case .ready:     return viewModel.attempts.isEmpty ? "Tap to start" : "Tap for the next run"
        case .countdown: return "Get set… tap to cancel"
        case .running:   return "Tap when you finish"
        case .recorded(let time):
            return time <= (viewModel.best ?? time) ? "Best run" : "Run \(viewModel.attempts.count)"
        }
    }

    private var promptColor: Color {
        if case .running = viewModel.state { return Color.onLeather }
        return .secondary
    }

    private var buttonBackground: Color {
        if case .running = viewModel.state { return .leather }
        return .panel
    }

    private var attemptsList: some View {
        ScrollView(.horizontal, showsIndicators: false) { attemptChips }
            .frame(height: 32)
    }

    private var attemptChips: some View {
        HStack(spacing: 8) {
            if viewModel.attempts.isEmpty {
                Text("Best of three is a good start.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(viewModel.attempts.enumerated()), id: \.offset) { _, time in
                Text(String(format: "%.2f", time))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(time == viewModel.best ? Color.make : .primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.panel, in: Capsule())
            }
        }
    }
}
