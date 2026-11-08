// CameraPreview.swift
// Live camera preview plus the overlays drawn on top of it. Vision boxes
// are mapped through the preview's aspect-fill crop, so they sit on the
// real hoop and ball whatever the screen shape.

import SwiftUI
import AVFoundation
import CoreGraphics

struct CameraPreviewView: UIViewRepresentable {

    let captureSession: AVCaptureSession
    var orientation: CameraOrientation = .landscape
    /// Observed so updateUIView re-fires once the session runs — the preview
    /// layer has no connection (so no rotation) until then.
    var isSessionRunning: Bool = false

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = captureSession
        view.previewLayer.videoGravity = .resizeAspectFill
        view.backgroundColor = .black
        applyRotation(to: view.previewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        applyRotation(to: uiView.previewLayer)
    }

    private func applyRotation(to layer: AVCaptureVideoPreviewLayer) {
        guard let connection = layer.connection else { return }
        let angle = orientation.videoRotationAngle
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }

    final class PreviewUIView: UIView {
        deinit {} // Keep: see "Explicit deinit" in CLAUDE.md

        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

/// Maps Vision-normalised rects (origin bottom-left) into an aspect-filled view.
enum VideoGeometry {
    static func viewRect(for vision: CGRect, in size: CGSize, videoAspect: CGFloat = 16.0 / 9.0) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let viewAspect = size.width / size.height
        // Size of the full video frame once aspect-filled into the view.
        let shown = viewAspect > videoAspect
            ? CGSize(width: size.width, height: size.width / videoAspect)
            : CGSize(width: size.height * videoAspect, height: size.height)
        let origin = CGPoint(x: (size.width - shown.width) / 2, y: (size.height - shown.height) / 2)
        return CGRect(x: origin.x + vision.minX * shown.width,
                      y: origin.y + (1 - vision.maxY) * shown.height,
                      width: vision.width * shown.width,
                      height: vision.height * shown.height)
    }
}

/// Corner brackets around the tracked hoop.
struct HoopBracket: View {
    let rect: CGRect?
    let isTracking: Bool

    var body: some View {
        GeometryReader { geo in
            if let rect {
                let r = VideoGeometry.viewRect(for: rect, in: geo.size).insetBy(dx: -10, dy: -10)
                BracketShape()
                    .stroke(isTracking ? Color.make : Color.white.opacity(0.5),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
                    .animation(.easeOut(duration: 0.12), value: r)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private struct BracketShape: Shape {
        func path(in rect: CGRect) -> Path {
            let arm = min(rect.width, rect.height) * 0.28
            let corners: [(CGPoint, CGFloat, CGFloat)] = [
                (CGPoint(x: rect.minX, y: rect.minY), 1, 1),
                (CGPoint(x: rect.maxX, y: rect.minY), -1, 1),
                (CGPoint(x: rect.minX, y: rect.maxY), 1, -1),
                (CGPoint(x: rect.maxX, y: rect.maxY), -1, -1),
            ]
            var p = Path()
            for (corner, dx, dy) in corners {
                p.move(to: CGPoint(x: corner.x + arm * dx, y: corner.y))
                p.addLine(to: corner)
                p.addLine(to: CGPoint(x: corner.x, y: corner.y + arm * dy))
            }
            return p
        }
    }
}

/// Debug aid: the detector's current ball box (Profile → Developer).
struct BallBoxOverlay: View {
    let box: CGRect?

    var body: some View {
        GeometryReader { geo in
            if let box {
                let r = VideoGeometry.viewRect(for: box, in: geo.size)
                Rectangle()
                    .stroke(Color.leather, lineWidth: 2)
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
