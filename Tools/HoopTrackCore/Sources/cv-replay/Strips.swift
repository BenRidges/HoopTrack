// Strips.swift
// Annotated PNG strips, to check by eye that the boxes sit on the ball and
// the hoop (coordinates, orientation, crop mapping) and to see why a shot
// was called the way it was.
//
// One strip per call the delegate received — frames at release, apex, rim
// and rim + 0.5 s — plus overview.png (four frames spread over the clip).
// Each panel: the whole 1280×720 frame the detector saw at half size, and
// below it a 1:1 close-up (640×360 px) around the shot ball and the hoop.
//
//   yellow   every ball candidate (with confidence in the close-up)
//   orange   the tracker's shot ball
//   cyan     the detector's most confident hoop (the log's `rb`)
//   blue     any other hoops the detector returned (the rest of `rs`)
//   green    the smoothed hoop the tracker was given, from the log replay;
//            dashed: the hoop the live pipeline last published (the two
//            agree when consistency.txt says the hoop rects do)
//   white    the rim the shot is judged against (held from release), dashed
//   magenta  the detection crop (DetectionRegion), dashed
//
// Frames are decoded again (same conversion as the live run) by PTS, so the
// picture is exactly the frame those boxes came from.

import CoreGraphics
import CoreImage
import CoreMedia
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import HoopTrack

@MainActor
struct StripWriter {

    let options: Options
    let live: LiveRun
    let report: Report

    private struct Moment {
        let label: String
        let entry: Int
    }

    private struct Plan {
        let file: String
        let header: [String]
        let moments: [Moment]
        let shotRim: CGRect?
    }

    func write(to directory: URL) async throws {
        let entries = report.entries
        guard !entries.isEmpty else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let times = entries.map(\.timestampSec)

        func nearest(_ t: Double) -> Int {
            var lo = 0, hi = times.count - 1
            while lo < hi {
                let mid = (lo + hi) / 2
                if times[mid] < t { lo = mid + 1 } else { hi = mid }
            }
            if lo > 0, abs(times[lo - 1] - t) <= abs(times[lo] - t) { return lo - 1 }
            return lo
        }

        var plans: [Plan] = []
        for pair in report.pairs {
            let number = (pair.liveIndex ?? pair.index) + 1
            var header: [String] = []
            var moments: [Moment] = []
            var shotRim: CGRect?
            let result = pair.live.map { name($0.shot.result) } ?? pair.replay.map { name($0.result) } ?? "?"
            if let l = pair.live {
                let s = l.shot
                header.append("Shot \(number)  \(result.uppercased())  conf \(f(s.confidence, 2))"
                              + (s.confidence < HoopTrack.CV.lowConfidence ? " (flagged)" : "")
                              + "  zone \(s.zone.displayName)  court \(f(s.courtX, 2)),\(f(s.courtY, 2))"
                              + "  dist \(s.distanceFt.map { f($0, 1) + " ft" } ?? "-")"
                              + "  published \(f(live.video(l.pts), 2)) s"
                              + (pair.matches ? "  [log replay agrees]" : "  [LIVE ≠ REPLAY: \(pair.problems.joined(separator: "; "))]"))
            } else {
                header.append("Replay-only call \(number)  \(result.uppercased())  (the delegate never received it): "
                              + pair.problems.joined(separator: "; "))
            }
            if let r = pair.replay {
                let release = r.outcome.release.time
                let rim = r.time
                // Apex: the shot ball's highest point between release and rim.
                var apex = (release + rim) / 2, best = -Double.infinity
                for frame in report.trace.frames where frame.t >= release && frame.t <= rim {
                    if let ball = frame.shotBall, Double(ball.maxY) > best { best = Double(ball.maxY); apex = frame.t }
                }
                let s = live.logZero
                moments = [Moment(label: "release \(f(release + s, 2)) s", entry: nearest(release)),
                           Moment(label: "apex \(f(apex + s, 2)) s", entry: nearest(apex)),
                           Moment(label: (r.outcome.rimArrivalTime != nil ? "rim " : "last seen ") + "\(f(rim + s, 2)) s",
                                  entry: nearest(rim)),
                           Moment(label: "+0.5 s \(f(rim + 0.5 + s, 2)) s", entry: nearest(rim + 0.5))]
                shotRim = r.outcome.hoop
            } else if let l = pair.live {
                let t = l.pts - live.sessionStart
                moments = [-1.5, -1, -0.5, 0].map { Moment(label: "published \(f($0, 1)) s", entry: nearest(t + $0)) }
            }
            let file = pair.live != nil ? String(format: "shot-%02d-%@.png", number, result)
                : String(format: "replay-only-%02d-%@.png", pair.index + 1, result)
            plans.append(Plan(file: file, header: header,
                              moments: moments, shotRim: shotRim))
        }
        let spread = [0.1, 0.37, 0.63, 0.9].map { Int(Double(entries.count - 1) * $0) }
        plans.append(Plan(file: "overview.png",
                          header: ["Overview: \(options.video.lastPathComponent), four frames across the run"],
                          moments: spread.map { Moment(label: "\(f(entries[$0].timestampSec + live.logZero, 2)) s", entry: $0) },
                          shotRim: nil))

        let wanted = Set(plans.flatMap { $0.moments.map { entries[$0.entry].timestampSec + live.sessionStart } })
        let images = try await decode(wanted)

        for plan in plans {
            let panels = plan.moments.map { moment -> StripRenderer.Panel in
                let entry = entries[moment.entry]
                let pts = entry.timestampSec + live.sessionStart
                return StripRenderer.Panel(title: moment.label,
                                           image: images.first { abs($0.key - pts) < 1e-6 }?.value,
                                           overlay: overlay(entry: moment.entry, pts: pts, shotRim: plan.shotRim))
            }
            guard let image = StripRenderer.render(header: plan.header + [StripRenderer.legend], panels: panels) else { continue }
            try StripRenderer.writePNG(image, to: directory.appendingPathComponent(plan.file))
        }
    }

    private func overlay(entry index: Int, pts: Double, shotRim: CGRect?) -> StripRenderer.Overlay {
        let entry = report.entries[index]
        var overlay = StripRenderer.Overlay()
        if let list = entry.balls {
            overlay.balls = list.compactMap { v in
                v.count >= 4 ? (CGRect(x: v[0], y: v[1], width: v[2], height: v[3]), v.count > 4 ? v[4] : nil) : nil
            }
        } else if let b = entry.ballBox, b.count >= 4 {
            overlay.balls = [(CGRect(x: b[0], y: b[1], width: b[2], height: b[3]), entry.ballConfidence)]
        }
        if let r = entry.rimBox, r.count >= 4 { overlay.rim = CGRect(x: r[0], y: r[1], width: r[2], height: r[3]) }
        if let r = entry.region, r.count >= 4 { overlay.region = CGRect(x: r[0], y: r[1], width: r[2], height: r[3]) }
        if index < report.trace.frames.count {
            overlay.hoop = report.trace.frames[index].hoop
            overlay.shotBall = report.trace.frames[index].shotBall
        }
        if index < report.entryFed.count, let fed = report.entryFed[index] {
            overlay.liveHoop = live.hoopChanges.last { $0.frame <= fed }?.state.hoopRect
        }
        if entry.baskets != nil {
            overlay.otherBaskets = Array(ShotReplay.hoops(in: entry).dropFirst())
        } else if let stat = live.probe.first(where: { abs($0.pts - pts) < 1e-6 }) {
            overlay.otherBaskets = stat.baskets.dropFirst().map(\.box)
        }
        overlay.shotRim = shotRim
        return overlay
    }

    /// Decodes the frames at `wanted` PTS, converted exactly as in the run.
    private func decode(_ wanted: Set<Double>) async throws -> [Double: CGImage] {
        let sorted = wanted.sorted()
        var windows: [[Double]] = []
        for t in sorted {
            if let last = windows.last?.last, t - last < 3 { windows[windows.count - 1].append(t) } else { windows.append([t]) }
        }
        let context = CIContext()
        var images: [Double: CGImage] = [:]
        for window in windows {
            guard let lo = window.first, let hi = window.last else { continue }
            let offset = options.ptsOffset
            let frames = try await VideoFrames(url: options.video, fit: options.fit,
                                               timeRange: max(0, lo - offset - 0.1)...(hi - offset + 0.1),
                                               ptsOffset: offset)
            while let frame = try frames.next() {
                let t = frame.seconds
                if let match = window.first(where: { abs($0 - t) < 1e-6 }),
                   let pixels = CMSampleBufferGetImageBuffer(frame.sampleBuffer) {
                    let image = CIImage(cvPixelBuffer: pixels)
                    images[match] = context.createCGImage(image, from: image.extent)
                }
                if t > hi + 0.01 { break }
            }
            frames.cancel()
        }
        return images
    }
}

enum StripRenderer {

    struct Overlay {
        var balls: [(box: CGRect, confidence: Double?)] = []
        var shotBall: CGRect?
        var rim: CGRect?
        var otherBaskets: [CGRect] = []
        var hoop: CGRect?
        var liveHoop: CGRect?
        var shotRim: CGRect?
        var region: CGRect?
    }

    struct Panel {
        let title: String
        let image: CGImage?
        let overlay: Overlay
    }

    static let legend = "yellow ball candidates · orange shot ball · cyan detector's top hoop · blue other hoops · "
        + "green smoothed hoop (replay; dashed: live) · white dashed shot rim · magenta dashed detection crop"

    static let frameW: CGFloat = 1280, frameH: CGFloat = 720
    static let panelW: CGFloat = 640, thumbH: CGFloat = 360, zoomH: CGFloat = 360
    static let titleH: CGFloat = 24, gap: CGFloat = 6, lineH: CGFloat = 20

    static func render(header: [String], panels: [Panel]) -> CGImage? {
        let headerH = CGFloat(header.count) * lineH + 8
        let width = CGFloat(panels.count) * panelW + CGFloat(panels.count + 1) * gap
        let height = gap + zoomH + thumbH + titleH + headerH
        guard let ctx = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        for (i, line) in header.enumerated() {
            text(line, at: CGPoint(x: gap, y: height - CGFloat(i + 1) * lineH), size: i == header.count - 1 ? 12 : 15,
                 color: CGColor(gray: i == header.count - 1 ? 0.7 : 1, alpha: 1), in: ctx)
        }

        for (i, panel) in panels.enumerated() {
            let x = gap + CGFloat(i) * (panelW + gap)
            let zoomRect = CGRect(x: x, y: gap, width: panelW, height: zoomH)
            let thumbRect = CGRect(x: x, y: gap + zoomH, width: panelW, height: thumbH)
            text(panel.title + (panel.image == nil ? "  (frame not decoded)" : ""),
                 at: CGPoint(x: x + 4, y: gap + zoomH + thumbH + 6), size: 14, color: CGColor(gray: 1, alpha: 1), in: ctx)

            // Whole frame at half size.
            let crop = zoomOrigin(panel.overlay)
            ctx.saveGState()
            ctx.clip(to: thumbRect)
            ctx.translateBy(x: thumbRect.minX, y: thumbRect.minY)
            ctx.scaleBy(x: panelW / frameW, y: thumbH / frameH)
            draw(panel, in: ctx, lineScale: frameW / panelW, labels: false)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.6))
            ctx.setLineWidth(2)
            ctx.setLineDash(phase: 0, lengths: [8, 8])
            ctx.stroke(CGRect(x: crop.x, y: crop.y, width: panelW, height: zoomH))
            ctx.restoreGState()

            // 1:1 close-up.
            ctx.saveGState()
            ctx.clip(to: zoomRect)
            ctx.translateBy(x: zoomRect.minX - crop.x, y: zoomRect.minY - crop.y)
            draw(panel, in: ctx, lineScale: 1, labels: true)
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }

    /// Bottom-left of the 640×360 close-up, in frame pixels (y up): on the
    /// shot ball and hoop together if they fit, else the ball, else the hoop.
    private static func zoomOrigin(_ o: Overlay) -> CGPoint {
        func px(_ r: CGRect) -> CGRect { CGRect(x: r.minX * frameW, y: r.minY * frameH, width: r.width * frameW, height: r.height * frameH) }
        let ball = (o.shotBall ?? o.balls.first?.box).map(px)
        let hoop = (o.hoop ?? o.rim).map(px)
        var focus: CGRect
        switch (ball, hoop) {
        case let (b?, h?):
            let both = b.union(h).insetBy(dx: -30, dy: -30)
            focus = both.width <= panelW && both.height <= zoomH ? both : b
        case let (b?, nil): focus = b
        case let (nil, h?): focus = h.offsetBy(dx: 0, dy: -h.height)   // keep the net in view
        case (nil, nil):    focus = CGRect(x: frameW / 2, y: frameH / 2, width: 0, height: 0)
        }
        let x = min(max(0, focus.midX - panelW / 2), frameW - panelW)
        let y = min(max(0, focus.midY - zoomH / 2), frameH - zoomH)
        return CGPoint(x: x, y: y)
    }

    /// Draws the frame at (0, 0, 1280, 720) and the boxes over it; Vision's
    /// bottom-left origin is Core Graphics' own, so boxes map straight on.
    private static func draw(_ panel: Panel, in ctx: CGContext, lineScale: CGFloat, labels: Bool) {
        if let image = panel.image {
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: frameW, height: frameH))
        }
        let o = panel.overlay
        func px(_ r: CGRect) -> CGRect { CGRect(x: r.minX * frameW, y: r.minY * frameH, width: r.width * frameW, height: r.height * frameH) }
        func box(_ r: CGRect, _ color: CGColor, _ width: CGFloat, dashed: Bool = false) {
            ctx.setStrokeColor(color)
            ctx.setLineWidth(width * lineScale)
            ctx.setLineDash(phase: 0, lengths: dashed ? [6 * lineScale, 4 * lineScale] : [])
            ctx.stroke(px(r).insetBy(dx: -width * lineScale / 2, dy: -width * lineScale / 2))
        }
        if let region = o.region { box(region, CGColor(red: 1, green: 0, blue: 1, alpha: 1), 2, dashed: true) }
        for other in o.otherBaskets { box(other, CGColor(red: 0.3, green: 0.5, blue: 1, alpha: 1), 1.5) }
        if let rim = o.rim { box(rim, CGColor(red: 0, green: 0.9, blue: 1, alpha: 1), 1.5) }
        if let hoop = o.hoop { box(hoop, CGColor(red: 0.2, green: 1, blue: 0.2, alpha: 1), 1) }
        if let liveHoop = o.liveHoop { box(liveHoop, CGColor(red: 0.2, green: 1, blue: 0.2, alpha: 0.8), 2.5, dashed: true) }
        if let shotRim = o.shotRim { box(shotRim, CGColor(gray: 1, alpha: 1), 1, dashed: true) }
        for ball in o.balls {
            box(ball.box, CGColor(red: 1, green: 0.9, blue: 0, alpha: 1), 1)
            if labels, let confidence = ball.confidence {
                let r = px(ball.box)
                text(f(confidence, 2), at: CGPoint(x: r.minX, y: r.maxY + 3), size: 11,
                     color: CGColor(red: 1, green: 0.9, blue: 0, alpha: 1), in: ctx)
            }
        }
        if let shotBall = o.shotBall { box(shotBall, CGColor(red: 1, green: 0.4, blue: 0, alpha: 1), 2.5) }
    }

    private static func text(_ string: String, at point: CGPoint, size: CGFloat, color: CGColor, in ctx: CGContext) {
        let font = CTFontCreateWithName("Menlo" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.textPosition = point
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw RunnerError("can't write \(url.path)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw RunnerError("can't write \(url.path)") }
    }
}
