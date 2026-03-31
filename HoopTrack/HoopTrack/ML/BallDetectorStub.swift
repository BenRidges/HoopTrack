// HoopTrack/ML/BallDetectorStub.swift
// Simulates a basketball shot arc so the CV pipeline can be built and tested
// before the real Core ML model is trained.
// Compiled only in DEBUG builds — not shipped.

#if DEBUG
import AVFoundation
import CoreGraphics

final class BallDetectorStub: BallDetectorProtocol {

    private var frameCount = 0

    // One shot arc every 180 frames (3 seconds at 60fps).
    // Ball appears at frame 30, peaks at frame 90, leaves at frame 150.
    func detect(buffer: CMSampleBuffer) -> BallDetection? {
        frameCount += 1
        let phase = frameCount % 180
        guard phase > 30 && phase < 150 else { return nil }

        let progress = Double(phase - 30) / 120.0          // 0 → 1 over the arc
        let y        = 0.15 + sin(progress * .pi) * 0.55   // rises 0.15 → 0.70, then falls

        return BallDetection(
            boundingBox: CGRect(x: 0.45, y: y, width: 0.07, height: 0.07),
            confidence: 0.87,
            frameTimestamp: CMSampleBufferGetPresentationTimeStamp(buffer)
        )
    }
}
#endif
