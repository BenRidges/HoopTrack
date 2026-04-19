// AppearanceExtraction.swift
// Pure static helpers used by AppearanceCaptureService. Kept separate so the
// math is unit-testable without Vision / CoreImage dependencies.

import Foundation
import CoreGraphics
import CoreImage

enum AppearanceExtraction {

    /// Normalises counts so the bins sum to 1.0. Returns a uniform distribution
    /// when the input is all-zero (pathological but safe fallback).
    static func normalizedHistogram(_ counts: [Float]) -> [Float] {
        let total = counts.reduce(0, +)
        guard total > 0 else {
            let uniform = Float(1.0) / Float(max(counts.count, 1))
            return Array(repeating: uniform, count: counts.count)
        }
        return counts.map { $0 / total }
    }

    /// Axis-aligned bounding rect covering shoulder-to-hip keypoints in
    /// the shared normalised coordinate space (0..1 on both axes).
    static func upperBodyBox(
        leftShoulder: CGPoint, rightShoulder: CGPoint,
        leftHip: CGPoint, rightHip: CGPoint
    ) -> CGRect {
        let minX = min(leftShoulder.x, rightShoulder.x, leftHip.x, rightHip.x)
        let maxX = max(leftShoulder.x, rightShoulder.x, leftHip.x, rightHip.x)
        let minY = min(leftShoulder.y, rightShoulder.y)
        let maxY = max(leftHip.y, rightHip.y)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Body height as fraction of frame height. Uses nose → ankle span.
    static func heightRatio(
        nose: CGPoint, leftAnkle: CGPoint, rightAnkle: CGPoint
    ) -> Float {
        let ankleY = max(leftAnkle.y, rightAnkle.y)
        return Float(ankleY - nose.y)
    }

    /// Build an 8-bin hue histogram + 4-bin value histogram from a rect of
    /// `image`. Coordinates in `rect` are in `image` pixel-space.
    /// Returns (hue8, value4) as normalised [Float] arrays.
    static func histograms(
        from image: CIImage,
        rect: CGRect,
        hueBins: Int = HoopTrack.Game.histogramHueBins,
        valueBins: Int = HoopTrack.Game.histogramValueBins
    ) -> (hue: [Float], value: [Float]) {
        var hueCounts = [Float](repeating: 0, count: hueBins)
        var valueCounts = [Float](repeating: 0, count: valueBins)

        let context = CIContext(options: [.useSoftwareRenderer: false])
        let clamped = image.cropped(to: rect)
        guard let cg = context.createCGImage(clamped, from: clamped.extent) else {
            return (normalizedHistogram(hueCounts), normalizedHistogram(valueCounts))
        }

        let width = cg.width
        let height = cg.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        let space = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: &pixels,
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: space,
            bitmapInfo: bitmapInfo
        ) else {
            return (normalizedHistogram(hueCounts), normalizedHistogram(valueCounts))
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Sub-sample every 4th pixel for speed — perceptually indistinguishable.
        let step = 4
        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                let i = (y * bytesPerRow) + (x * bytesPerPixel)
                let r = Float(pixels[i])     / 255.0
                let g = Float(pixels[i + 1]) / 255.0
                let b = Float(pixels[i + 2]) / 255.0

                let maxC = max(r, g, b)
                let minC = min(r, g, b)
                let v = maxC
                let delta = maxC - minC

                // Hue in 0..6; convert to 0..1 then bin.
                var h: Float = 0
                if delta > 0 {
                    if maxC == r      { h = (g - b) / delta }
                    else if maxC == g { h = 2 + (b - r) / delta }
                    else              { h = 4 + (r - g) / delta }
                }
                h = h / 6
                if h < 0 { h += 1 }

                let hueBin = min(Int(h * Float(hueBins)), hueBins - 1)
                let valueBin = min(Int(v * Float(valueBins)), valueBins - 1)
                hueCounts[hueBin] += 1
                valueCounts[valueBin] += 1
            }
        }

        return (normalizedHistogram(hueCounts), normalizedHistogram(valueCounts))
    }
}
