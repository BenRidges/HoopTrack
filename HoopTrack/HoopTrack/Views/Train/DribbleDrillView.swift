// DribbleDrillView.swift
// Full-screen ARKit session for dribble drills.
// Phone is placed on the floor facing up; player stands above.
//
// ARView (RealityKit) handles camera display, horizontal plane detection,
// and AR floor target anchors.
// DribblePipeline processes ARKit frames via Vision hand tracking.

import SwiftUI
import RealityKit
import ARKit
import SwiftData

struct DribbleDrillView: View {

    let namedDrill: NamedDrill?
    let onFinish: () -> Void

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var coordinator: SessionFinalizationCoordinator

    @StateObject private var viewModel = DribbleSessionViewModel()

    @State private var arCoordinator: DribbleARCoordinator?
    @State private var pipeline      = DribblePipeline()

    @State private var isLongPressingEnd      = false
    @State private var endLongPressProgress: Double = 0
    @State private var endSessionTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            // MARK: ARView (replaces CameraPreviewView for dribble sessions)
            DribbleARViewContainer(coordinator: $arCoordinator)
                .ignoresSafeArea()

            // MARK: HUD
            VStack {
                topHUD
                Spacer()
                bottomControls
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .task {
            viewModel.configure(dataService: DataService(modelContext: modelContext),
                                coordinator: coordinator)
            viewModel.start(namedDrill: namedDrill)

            // Wire pipeline → viewModel
            pipeline.delegate = viewModel

            // Give pipeline session start time
            pipeline.startSession(at: Date().timeIntervalSinceReferenceDate)
        }
        // Wire pipeline to coordinator when it becomes non-nil.
        // Using onChange rather than .task avoids a race: makeUIView sets the coordinator
        // via DispatchQueue.main.async, which may settle after .task starts executing.
        .onChange(of: arCoordinator) { _, coordinator in
            coordinator?.pipeline = pipeline
        }
        .onDisappear {
            arCoordinator?.stopSession()
        }
        .fullScreenCover(isPresented: $viewModel.isFinished) {
            if let session = viewModel.session {
                DribbleSessionSummaryView(session: session) {
                    viewModel.isFinished = false
                    onFinish()
                }
            }
        }
        .statusBarHidden(true)
    }

    // MARK: - Top HUD

    private var topHUD: some View {
        HStack(alignment: .top) {
            // Dribble count
            VStack(alignment: .leading, spacing: 2) {
                Text("\(viewModel.totalDribbles)")
                    .font(.system(size: 36, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
                Text("dribbles")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(16)
            .background(.ultraThinMaterial.opacity(0.7),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            Spacer()

            // BPS + timer
            VStack(alignment: .trailing, spacing: 2) {
                Text(viewModel.elapsedFormatted)
                    .font(.system(size: 36, weight: .black, design: .monospaced))
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
                Text(String(format: "%.1f BPS", viewModel.currentBPS))
                    .font(.caption.bold())
                    .foregroundStyle(.yellow)
            }
            .padding(16)
            .background(.ultraThinMaterial.opacity(0.7),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(.horizontal)
        .padding(.top, 12)
    }

    // MARK: - Bottom Controls

    private var bottomControls: some View {
        HStack(spacing: 16) {
            // Combo badge
            if viewModel.combosDetected > 0 {
                Label("\(viewModel.combosDetected) combos", systemImage: "arrow.triangle.swap")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.orange.opacity(0.85), in: Capsule())
                    .foregroundStyle(.white)
            }

            Spacer()

            // End Session (long press)
            Text(isLongPressingEnd ? "Hold…" : "End Session")
                .font(.subheadline.bold())
                .padding(.horizontal, 20)
                .frame(height: 52)
                .background(
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 26).fill(Color.red)
                        RoundedRectangle(cornerRadius: 26)
                            .fill(Color.white.opacity(0.25))
                            .frame(width: max(0, endLongPressProgress) * 160)
                            .animation(.linear(duration: 0.05), value: endLongPressProgress)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 26))
                )
                .foregroundStyle(.white)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            guard !isLongPressingEnd else { return }
                            isLongPressingEnd = true
                            endLongPressProgress = 0
                            withAnimation(.linear(duration: 1.5)) {
                                endLongPressProgress = 1
                            }
                            endSessionTask = Task {
                                try? await Task.sleep(nanoseconds: 1_500_000_000)
                                guard !Task.isCancelled else { return }
                                await viewModel.endSession()
                            }
                        }
                        .onEnded { _ in
                            endSessionTask?.cancel()
                            endSessionTask = nil
                            isLongPressingEnd = false
                            withAnimation(.easeOut(duration: 0.2)) {
                                endLongPressProgress = 0
                            }
                        }
                )
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(.black.opacity(0.4))
    }
}

// MARK: - ARView Container

struct DribbleARViewContainer: UIViewRepresentable {

    @Binding var coordinator: DribbleARCoordinator?

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        if let format = ARWorldTrackingConfiguration
            .supportedVideoFormats
            .first(where: { $0.framesPerSecond >= 60 }) {
            config.videoFormat = format
        }

        let c = DribbleARCoordinator(arView: arView)
        arView.session.delegate = c
        arView.session.run(config)
        DispatchQueue.main.async { self.coordinator = c }
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}

// MARK: - AR Session Coordinator

final class DribbleARCoordinator: NSObject, ARSessionDelegate {

    private let arView: ARView
    nonisolated(unsafe) var pipeline: DribblePipeline?

    /// Tracks whether we have placed the floor targets yet.
    private var targetsPlaced = false

    init(arView: ARView) {
        self.arView = arView
    }

    // Called from .onDisappear which runs on main — @MainActor isolation is correct here.
    func stopSession() {
        arView.session.pause()
    }

    // MARK: ARSessionDelegate — frame processing

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard let pipeline else { return }
        pipeline.processFrame(pixelBuffer: frame.capturedImage,
                              timestamp: frame.timestamp)
    }

    // MARK: ARSessionDelegate — plane detection

    nonisolated func session(_ session: ARSession,
                             didAdd anchors: [ARAnchor]) {
        DispatchQueue.main.async { [weak self] in
            self?.placeTargetsIfNeeded(anchors: anchors)
        }
    }

    @MainActor
    private func placeTargetsIfNeeded(anchors: [ARAnchor]) {
        guard !targetsPlaced else { return }
        guard let planeAnchor = anchors.compactMap({ $0 as? ARPlaneAnchor })
                                       .first(where: { $0.alignment == .horizontal }) else { return }
        targetsPlaced = true
        placeARTargets(on: planeAnchor)
    }

    @MainActor
    private func placeARTargets(on planeAnchor: ARPlaneAnchor) {
        guard #available(iOS 18.0, *) else { return }
        let count  = HoopTrack.Dribble.arTargetCount
        let radius = HoopTrack.Dribble.arTargetRadiusM
        for i in 0 ..< count {
            let offsetX = Float(i - count / 2) * (radius * 3)
            let mesh     = MeshResource.generateCylinder(height: 0.005, radius: radius)
            let material = SimpleMaterial(color: .orange.withAlphaComponent(0.75),
                                          isMetallic: false)
            let entity   = ModelEntity(mesh: mesh, materials: [material])
            entity.position = SIMD3<Float>(planeAnchor.center.x + offsetX,
                                           0,
                                           planeAnchor.center.z)
            let anchor = AnchorEntity(anchor: planeAnchor)
            anchor.addChild(entity)
            arView.scene.addAnchor(anchor)
        }
    }
}
