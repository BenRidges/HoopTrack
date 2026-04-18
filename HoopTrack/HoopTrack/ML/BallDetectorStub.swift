// HoopTrack/ML/BallDetectorStub.swift
// Simulates a basketball shot arc + a static hoop box so the CV pipeline
// can be built and tested before the real Core ML model is running.
// Used in the simulator and as a fallback during development.

import AVFoundation
import CoreGraphics

nonisolated final class BallDetectorStub: BallDetectorProtocol {

    nonisolated(unsafe) private var frameCount = 0

    // Static basket at roughly rim-height in a landscape frame.
    // Vision coords: origin bottom-left, so y = 0.73 is near the top.
    private let fakeBasket = CGRect(x: 0.45, y: 0.73, width: 0.10, height: 0.08)

    func detectScene(buffer: CMSampleBuffer) -> SceneDetection? {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(buffer)
        frameCount += 1

        // One shot arc every 180 frames (3 seconds at 60fps).
        // Ball appears at frame 30, peaks at frame 90, leaves at frame 150.
        let phase = frameCount % 180
        let ball: BallDetection?
        if phase > 30 && phase < 150 {
            let progress = Double(phase - 30) / 120.0
            let y        = 0.15 + sin(progress * .pi) * 0.55
            ball = BallDetection(
                boundingBox: CGRect(x: 0.45, y: y, width: 0.07, height: 0.07),
                confidence: 0.87,
                frameTimestamp: timestamp
            )
        } else {
            ball = nil
        }

        let basket = BallDetection(
            boundingBox: fakeBasket,
            confidence: 0.92,
            frameTimestamp: timestamp
        )

        return SceneDetection(ball: ball, basket: basket, frameTimestamp: timestamp)
    }
}
