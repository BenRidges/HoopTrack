# Phase 5B — Plan D: Agility Drill

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the full agility drill flow: volume-button detection service, session view model with start/stop state machine, full-screen session view, post-session summary view, and routing from `TrainTabView`.

**Architecture:** `AgilityDetectionServiceProtocol` defines the detection seam — `VolumeButtonAgilityDetectionService` is the concrete impl (KVO on `AVAudioSession.outputVolume`). `AgilitySessionViewModel` owns the state machine and timer; it never references the concrete service type. `AgilitySessionView` and `AgilitySessionSummaryView` follow the same patterns as `LiveSessionView` and `DribbleSessionSummaryView`. The coordinator's `finaliseAgilitySession` method already exists from Phase 5A.

**Tech Stack:** SwiftUI, AVFoundation (KVO), Combine, Foundation

**Prerequisite:** Plans A, B, C complete (especially `BadgesUpdatedSection` for the summary view)

**Build command (run from worktree root):**
```
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```

---

### Task 1: Create `AgilityDetectionServiceProtocol` + `VolumeButtonAgilityDetectionService`

**Files:**
- Create: `HoopTrack/HoopTrack/Services/AgilityDetectionServiceProtocol.swift`

- [ ] **Step 1: Create the file**

```swift
// AgilityDetectionServiceProtocol.swift
// Abstraction for agility start/stop trigger detection.
// VolumeButtonAgilityDetectionService is the production impl.
// Tests inject a mock that fires onTrigger programmatically.

import AVFoundation

@MainActor protocol AgilityDetectionServiceProtocol: AnyObject {
    /// Called on the main actor each time the user signals start/stop (e.g., presses Vol+).
    var onTrigger: (() -> Void)? { get set }
    func startListening()
    func stopListening()
}

// MARK: - Volume Button Implementation

@MainActor final class VolumeButtonAgilityDetectionService: NSObject, AgilityDetectionServiceProtocol {

    var onTrigger: (() -> Void)?

    private let session = AVAudioSession.sharedInstance()
    private var observation: NSKeyValueObservation?

    func startListening() {
        try? session.setCategory(.ambient)
        try? session.setActive(true)

        observation = session.observe(\.outputVolume, options: [.new]) { [weak self] audioSession, _ in
            guard let self else { return }
            // Reset to 0.5 to prevent volume drift; fire trigger
            DispatchQueue.main.async {
                try? audioSession.setActive(false)
                try? audioSession.setActive(true)
                self.onTrigger?()
            }
        }
    }

    func stopListening() {
        observation?.invalidate()
        observation = nil
        try? session.setActive(false)
    }
}
```

- [ ] **Step 2: Build to verify**

```
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add HoopTrack/HoopTrack/Services/AgilityDetectionServiceProtocol.swift
git commit -m "feat: add AgilityDetectionServiceProtocol and VolumeButtonAgilityDetectionService"
```

---

### Task 2: Create `AgilitySessionViewModel`

**Files:**
- Create: `HoopTrack/HoopTrack/ViewModels/AgilitySessionViewModel.swift`

- [ ] **Step 1: Create the file**

```swift
// AgilitySessionViewModel.swift
// Owns the agility drill state machine: idle → running → recorded (auto-reset after 1.5s).

import Foundation
import Combine

@MainActor final class AgilitySessionViewModel: ObservableObject {

    enum TimerState { case idle, running, recorded }
    enum AgilityMetric: String, CaseIterable { case shuttleRun = "Shuttle Run", laneAgility = "Lane Agility" }

    // MARK: - Published state

    @Published var timerState: TimerState = .idle
    @Published var selectedMetric: AgilityMetric = .shuttleRun
    @Published var elapsedSeconds: Double = 0
    @Published var shuttleAttempts: [Double] = []
    @Published var laneAttempts:    [Double] = []
    @Published var isFinished:  Bool = false
    @Published var isSaving:    Bool = false
    @Published var errorMessage: String?
    @Published var sessionResult: SessionResult?

    // MARK: - Computed

    var bestShuttleSeconds: Double? { shuttleAttempts.min() }
    var bestLaneSeconds:    Double? { laneAttempts.min() }
    var currentAttempts:    [Double] { selectedMetric == .shuttleRun ? shuttleAttempts : laneAttempts }

    // MARK: - Dependencies

    private var detectionService: AgilityDetectionServiceProtocol!
    private var coordinator:      SessionFinalizationCoordinator!
    private var dataService:      DataService!
    private var session:          TrainingSession?
    private var timerCancellable: AnyCancellable?
    private var resetTask:        Task<Void, Never>?

    // MARK: - Configuration

    func configure(dataService: DataService,
                   coordinator: SessionFinalizationCoordinator,
                   detectionService: AgilityDetectionServiceProtocol) {
        self.dataService      = dataService
        self.coordinator      = coordinator
        self.detectionService = detectionService
        self.detectionService.onTrigger = { [weak self] in self?.handleTrigger() }
    }

    // MARK: - Lifecycle

    func start(namedDrill: NamedDrill?) throws {
        session = try dataService.startSession(drillType: .agility, namedDrill: namedDrill)
        detectionService.startListening()
    }

    func endSession() async {
        detectionService.stopListening()
        guard let session else { return }
        isSaving = true
        let attempts = AgilityAttempts(
            bestShuttleRunSeconds:  bestShuttleSeconds,
            bestLaneAgilitySeconds: bestLaneSeconds
        )
        do {
            sessionResult = try await coordinator.finaliseAgilitySession(session, attempts: attempts)
            isFinished    = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }

    // MARK: - State Machine

    private func handleTrigger() {
        switch timerState {
        case .idle:
            // Start timing
            timerState = .running
            startTimer()
        case .running:
            // Stop timing, record result
            let elapsed = elapsedSeconds
            stopTimer()
            timerState = .recorded
            if selectedMetric == .shuttleRun {
                shuttleAttempts.append(elapsed)
            } else {
                laneAttempts.append(elapsed)
            }
            elapsedSeconds = 0
            // Auto-reset to idle after 1.5s
            resetTask?.cancel()
            resetTask = Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                timerState = .idle
            }
        case .recorded:
            break
        }
    }

    private func startTimer() {
        timerCancellable = Timer.publish(every: 0.01, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.elapsedSeconds += 0.01
            }
    }

    private func stopTimer() {
        timerCancellable?.cancel()
        timerCancellable = nil
    }
}
```

- [ ] **Step 2: Build to verify**

```
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add HoopTrack/HoopTrack/ViewModels/AgilitySessionViewModel.swift
git commit -m "feat: add AgilitySessionViewModel with idle/running/recorded state machine"
```

---

### Task 3: Create `AgilitySessionView`

**Files:**
- Create: `HoopTrack/HoopTrack/Views/Train/AgilitySessionView.swift`

- [ ] **Step 1: Create the file**

```swift
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
                    .font(.system(size: 72, weight: .black, design: .monospaced))
                    .foregroundStyle(viewModel.timerState == .running ? Color.orange : .white)
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
                    .scaleEffect(isRunning ? 1.1 : 1.0)
                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                               value: isRunning)
                Image(systemName: "speaker.wave.2.fill")
                    .font(.title2)
                    .foregroundStyle(isRunning ? .orange : .white.opacity(0.7))
            }
            Text(isRunning ? "Vol+ to Stop" : "Vol+ to Start")
                .font(.headline)
                .foregroundStyle(isRunning ? .orange : .white.opacity(0.8))
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
                                .foregroundStyle(.orange)
                                .font(.caption)
                        }
                        Text(String(format: "%.2fs", attempt))
                            .font(.subheadline.bold())
                            .foregroundStyle(attempt == best ? .orange : .white)
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
                        .foregroundStyle(.orange)
                }
            }
            if let lane = viewModel.bestLaneSeconds {
                VStack(spacing: 2) {
                    Text("Best Lane Agility")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                    Text(String(format: "%.2fs", lane))
                        .font(.subheadline.bold())
                        .foregroundStyle(.orange)
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
    }
}
```

- [ ] **Step 2: Build to verify**

```
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add HoopTrack/HoopTrack/Views/Train/AgilitySessionView.swift
git commit -m "feat: add AgilitySessionView with timer, trigger cue, attempt history"
```

---

### Task 4: Create `AgilitySessionSummaryView`

**Files:**
- Create: `HoopTrack/HoopTrack/Views/Train/AgilitySessionSummaryView.swift`

- [ ] **Step 1: Create the file**

```swift
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
```

- [ ] **Step 2: Build to verify**

```
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add HoopTrack/HoopTrack/Views/Train/AgilitySessionSummaryView.swift
git commit -m "feat: add AgilitySessionSummaryView with best times, attempt log, badge section"
```

---

### Task 5: Add `.agility` routing to `TrainTabView`

**Files:**
- Modify: `HoopTrack/HoopTrack/Views/Train/TrainTabView.swift`

- [ ] **Step 1: Update the `fullScreenCover` routing switch to add agility**

Find:
```swift
        // Full-screen live session — routes by drill type
        .fullScreenCover(isPresented: $isShowingLiveSession) {
            if let drill = drillToLaunch, drill.drillType == .dribble {
                DribbleDrillView(namedDrill: drill) {
                    isShowingLiveSession = false
                    drillToLaunch        = nil
                }
            } else {
                LiveSessionView(
                    drillType: drillToLaunch?.drillType ?? .freeShoot,
                    namedDrill: drillToLaunch
                ) {
                    isShowingLiveSession = false
                    drillToLaunch        = nil
                }
            }
        }
```

Replace with:
```swift
        // Full-screen live session — routes by drill type
        .fullScreenCover(isPresented: $isShowingLiveSession) {
            if let drill = drillToLaunch, drill.drillType == .dribble {
                DribbleDrillView(namedDrill: drill) {
                    isShowingLiveSession = false
                    drillToLaunch        = nil
                }
            } else if let drill = drillToLaunch, drill.drillType == .agility {
                AgilitySessionView(namedDrill: drill) {
                    isShowingLiveSession = false
                    drillToLaunch        = nil
                }
            } else {
                LiveSessionView(
                    drillType: drillToLaunch?.drillType ?? .freeShoot,
                    namedDrill: drillToLaunch
                ) {
                    isShowingLiveSession = false
                    drillToLaunch        = nil
                }
            }
        }
```

- [ ] **Step 2: Build to verify**

```
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add HoopTrack/HoopTrack/Views/Train/TrainTabView.swift
git commit -m "feat: add .agility routing to TrainTabView fullScreenCover"
```
