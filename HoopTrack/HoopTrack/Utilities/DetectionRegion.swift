// DetectionRegion.swift
// Where to point the detector during a shot. The model takes a 640 px
// square; a full 1280×720 frame is letterboxed into it at half scale, so a
// ball near a hoop 6–7 m away is only ~10 px across. While a shot is in
// flight the only things that matter are the hoop and the shot ball, so
// CVPipeline crops a square around both — up to ~2× more pixels on the
// ball for the moments that decide make or miss.
//
// Vision's `regionOfInterest` takes and returns rects normalised to the
// region, so boxes have to be mapped back to full-frame coordinates.
// Both directions live here so they can be unit tested.

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

nonisolated enum DetectionRegion {

    /// A square crop around the hoop and the ball (Vision-normalised, origin
    /// bottom-left), or nil when the full frame is the better choice: no
    /// shot in flight, or a crop that wouldn't fit in the frame.
    ///
    /// - Parameters:
    ///   - hoop: smoothed rim box.
    ///   - ball: the shot ball's last box.
    ///   - frameWidth/frameHeight: pixel size of the camera frame.
    ///   - marginRims: padding around hoop + ball, in rim widths, so a fast
    ///     ball is still inside the crop next frame.
    ///   - minSidePx: never crop tighter than this — upsampling beyond the
    ///     model's input adds nothing.
    static func around(hoop: CGRect, ball: CGRect?,
                       frameWidth: Double, frameHeight: Double,
                       marginRims: Double = 2.5,
                       minSidePx: Double = 448) -> CGRect? {
        guard let ball, frameWidth > 0, frameHeight > 0,
              hoop.width > 0, hoop.height > 0 else { return nil }

        func px(_ r: CGRect) -> (minX: Double, minY: Double, maxX: Double, maxY: Double) {
            (Double(r.minX) * frameWidth, Double(r.minY) * frameHeight,
             Double(r.maxX) * frameWidth, Double(r.maxY) * frameHeight)
        }
        let h = px(hoop), b = px(ball)
        let margin = marginRims * Double(hoop.width) * frameWidth
        // The net hangs below the rim; keep it in.
        let netDrop = 1.5 * Double(hoop.width) * frameWidth
        let minX = min(h.minX, b.minX) - margin
        let maxX = max(h.maxX, b.maxX) + margin
        let minY = min(h.minY - netDrop, b.minY) - margin
        let maxY = max(h.maxY, b.maxY) + margin

        let side = max(maxX - minX, maxY - minY, minSidePx)
        // A square taller than the frame can't be cropped; the full frame
        // then loses little anyway.
        guard side <= frameHeight else { return nil }

        let centreX = (minX + maxX) / 2, centreY = (minY + maxY) / 2
        let originX = min(max(0, centreX - side / 2), frameWidth - side)
        let originY = min(max(0, centreY - side / 2), frameHeight - side)
        return CGRect(x: originX / frameWidth, y: originY / frameHeight,
                      width: side / frameWidth, height: side / frameHeight)
    }

    /// Maps a box Vision returned for `region` back to full-frame coordinates.
    static func toFullFrame(_ rect: CGRect, from region: CGRect) -> CGRect {
        CGRect(x: region.minX + rect.minX * region.width,
               y: region.minY + rect.minY * region.height,
               width: rect.width * region.width,
               height: rect.height * region.height)
    }
}
