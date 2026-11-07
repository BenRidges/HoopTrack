// VideoFrames.swift
// Decodes a video file into the frames the app's camera would deliver:
// upright landscape, 1280×720, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
// (what CameraService asks AVCaptureVideoDataOutput for), with the file's
// own presentation timestamps.
//
//   decode (AVAssetReaderTrackOutput → 420f at the encoded size)
//   → undo the track's preferredTransform (vImage: mirror, quarter turns)
//   → fit into 1280×720 (vImage Lanczos on Y and on interleaved CbCr)
//
// A 16:9 source fills the frame exactly. Other shapes are letterboxed or
// pillarboxed with black by default (`.letterbox`, nothing is cut off and
// the tracker's 16:9 aspect stays true for the pixels), or scaled to fill
// and centre-cropped (`.crop`). A 1280×720 upright source is passed
// through untouched.

import AVFoundation
import Accelerate
import CoreMedia
import CoreVideo
import Foundation

enum FitMode: String {
    case letterbox, crop
}

/// The app's capture size and format (CameraService).
enum CaptureFormat {
    static let width = 1280
    static let height = 720
    static let pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
}

/// What the track's preferredTransform does to the encoded picture:
/// mirror left-right first (if `mirrored`), then turn clockwise.
struct SourceOrientation: CustomStringConvertible {
    var mirrored: Bool
    var quarterTurnsCW: Int

    var isUpright: Bool { !mirrored && quarterTurnsCW == 0 }

    init(mirrored: Bool, quarterTurnsCW: Int) {
        self.mirrored = mirrored
        self.quarterTurnsCW = ((quarterTurnsCW % 4) + 4) % 4
    }

    /// Nil for transforms that aren't a multiple of 90° (± a mirror).
    init?(transform t: CGAffineTransform) {
        let scale = (t.a * t.a + t.b * t.b).squareRoot()
        guard scale > 0 else { return nil }
        func unit(_ v: CGFloat) -> Int? {
            let n = v / scale
            if abs(n) < 0.01 { return 0 }
            if abs(abs(n) - 1) < 0.01 { return n > 0 ? 1 : -1 }
            return nil
        }
        guard let a = unit(t.a), let b = unit(t.b), let c = unit(t.c), let d = unit(t.d) else { return nil }
        let det = a * d - b * c
        guard det == 1 || det == -1 else { return nil }
        // CGAffineTransform maps the x unit vector to (a, b), in y-down
        // pixel space. With a mirror M first, T = R∘M, so R(1,0) = −(a, b).
        let mirrored = det < 0
        let (rx, ry) = mirrored ? (-a, -b) : (a, b)
        let turns: Int
        switch (rx, ry) {
        case (1, 0):  turns = 0
        case (0, 1):  turns = 1     // right → down: clockwise on screen
        case (-1, 0): turns = 2
        case (0, -1): turns = 3
        default:      return nil
        }
        self.init(mirrored: mirrored, quarterTurnsCW: turns)
    }

    var description: String {
        let turn = quarterTurnsCW == 0 ? "no rotation" : "rotate \(quarterTurnsCW * 90)° clockwise"
        return mirrored ? "mirror, then \(turn)" : turn
    }
}

struct VideoInfo {
    let url: URL
    let codec: String
    /// Encoded size, before the preferred transform.
    let naturalSize: CGSize
    let transform: CGAffineTransform
    let orientation: SourceOrientation
    /// Upright size, after the transform.
    let displaySize: CGSize
    let nominalFPS: Double
    let duration: Double
}

struct DecodedFrame {
    /// What the pipeline gets: the converted frame with the original PTS.
    let sampleBuffer: CMSampleBuffer
    let pts: CMTime
    var seconds: Double { CMTimeGetSeconds(pts) }
    /// 0-based index among the frames this reader produced.
    let index: Int
}

enum VideoFramesError: Error, CustomStringConvertible {
    case noVideoTrack(URL)
    case unsupportedTransform(CGAffineTransform)
    case reader(String)
    case conversion(String)

    var description: String {
        switch self {
        case .noVideoTrack(let url):         return "no video track in \(url.path)"
        case .unsupportedTransform(let t):   return "unsupported preferredTransform \(t) (only quarter turns and mirrors)"
        case .reader(let message):           return "video read failed: \(message)"
        case .conversion(let message):       return "frame conversion failed: \(message)"
        }
    }
}

/// Used from one queue at a time (the session queue, then the strip pass).
final class VideoFrames: @unchecked Sendable {

    let info: VideoInfo
    let converter: FrameConverter
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private var produced = 0
    private let ptsOffset: CMTime?

    /// - Parameter timeRange: seconds into the video; nil = all of it.
    /// - Parameter ptsOffset: seconds added to every timestamp (0 = the
    ///   file's own), on a nanosecond timescale like the camera's clock.
    init(url: URL, fit: FitMode, timeRange: ClosedRange<Double>? = nil, ptsOffset: Double = 0) async throws {
        self.ptsOffset = ptsOffset == 0 ? nil : CMTime(value: Int64((ptsOffset * 1e9).rounded()), timescale: 1_000_000_000)
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoFramesError.noVideoTrack(url)
        }
        let (naturalSize, transform, fps, formats) = try await track.load(.naturalSize, .preferredTransform,
                                                                         .nominalFrameRate, .formatDescriptions)
        let duration = try await asset.load(.duration)
        guard let orientation = SourceOrientation(transform: transform) else {
            throw VideoFramesError.unsupportedTransform(transform)
        }
        let display = orientation.quarterTurnsCW % 2 == 1
            ? CGSize(width: naturalSize.height, height: naturalSize.width) : naturalSize
        let codec = formats.first.map { Self.fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "?"
        info = VideoInfo(url: url, codec: codec, naturalSize: naturalSize, transform: transform,
                         orientation: orientation, displaySize: display,
                         nominalFPS: Double(fps), duration: CMTimeGetSeconds(duration))

        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw VideoFramesError.reader(error.localizedDescription)
        }
        // Let the decoder hand over 420f directly (it converts video range
        // to full range when the file is video range).
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: CaptureFormat.pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw VideoFramesError.reader("can't add track output") }
        reader.add(output)
        if let timeRange {
            let start = CMTime(seconds: max(0, timeRange.lowerBound), preferredTimescale: 600)
            let end = CMTime(seconds: timeRange.upperBound, preferredTimescale: 600)
            reader.timeRange = CMTimeRange(start: start, end: end)
        }
        converter = try FrameConverter(orientation: orientation,
                                       sourceSize: (Int(naturalSize.width), Int(naturalSize.height)),
                                       fit: fit)
        guard reader.startReading() else {
            throw VideoFramesError.reader(reader.error?.localizedDescription ?? "startReading failed")
        }
    }

    /// The next frame, or nil at the end of the video.
    func next() throws -> DecodedFrame? {
        while let sample = output.copyNextSampleBuffer() {
            // Some containers emit empty marker samples; skip them.
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            var pts = CMSampleBufferGetPresentationTimeStamp(sample)
            if let ptsOffset {
                pts = CMTimeAdd(CMTimeConvertScale(pts, timescale: 1_000_000_000, method: .roundHalfAwayFromZero), ptsOffset)
            }
            let converted = try converter.convert(pixels)
            let buffer = try Self.sampleBuffer(converted, pts: pts,
                                               duration: CMSampleBufferGetDuration(sample))
            defer { produced += 1 }
            return DecodedFrame(sampleBuffer: buffer, pts: pts, index: produced)
        }
        if reader.status == .failed {
            throw VideoFramesError.reader(reader.error?.localizedDescription ?? "unknown error")
        }
        return nil
    }

    func cancel() {
        reader.cancelReading()
    }

    /// A ready sample buffer around `pixels`, timed like the source frame.
    private static func sampleBuffer(_ pixels: CVPixelBuffer, pts: CMTime, duration: CMTime) throws -> CMSampleBuffer {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels,
                                                           formatDescriptionOut: &format) == noErr,
              let format else { throw VideoFramesError.conversion("format description") }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixels,
                                                       formatDescription: format, sampleTiming: &timing,
                                                       sampleBufferOut: &buffer) == noErr,
              let buffer else { throw VideoFramesError.conversion("sample buffer") }
        return buffer
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        let text = String(bytes: bytes, encoding: .ascii) ?? "\(code)"
        return text.trimmingCharacters(in: .whitespaces)
    }
}

/// Turns decoded 420f buffers upright and fits them into 1280×720 420f.
final class FrameConverter {

    let orientation: SourceOrientation
    let fit: FitMode
    /// Upright source size.
    let uprightSize: (width: Int, height: Int)
    /// Where the picture sits in the 1280×720 frame (pixels, y down).
    let contentRect: CGRect
    /// Output pixels per upright source pixel.
    let scale: Double
    /// True when frames go to the pipeline exactly as decoded.
    var passesThrough: Bool {
        orientation.isUpright && uprightSize.width == CaptureFormat.width && uprightSize.height == CaptureFormat.height
    }

    private var pool: CVPixelBufferPool?
    // Scratch planes for the mirror / rotation steps, reused every frame.
    private var scratch: [UnsafeMutableRawPointer] = []

    init(orientation: SourceOrientation, sourceSize: (Int, Int), fit: FitMode) throws {
        self.orientation = orientation
        self.fit = fit
        let upright = orientation.quarterTurnsCW % 2 == 1 ? (sourceSize.1, sourceSize.0) : sourceSize
        uprightSize = upright
        let W = Double(CaptureFormat.width), H = Double(CaptureFormat.height)
        let w = Double(upright.0), h = Double(upright.1)
        guard w > 0, h > 0 else { throw VideoFramesError.conversion("empty video") }
        switch fit {
        case .letterbox:
            let s = min(W / w, H / h)
            let cw = Self.even(min(W, (w * s).rounded())), ch = Self.even(min(H, (h * s).rounded()))
            contentRect = CGRect(x: Self.even((W - cw) / 2), y: Self.even((H - ch) / 2), width: cw, height: ch)
            scale = s
        case .crop:
            scale = max(W / w, H / h)
            contentRect = CGRect(x: 0, y: 0, width: W, height: H)
        }
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: CaptureFormat.pixelFormat,
            kCVPixelBufferWidthKey as String: CaptureFormat.width,
            kCVPixelBufferHeightKey as String: CaptureFormat.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess else {
            throw VideoFramesError.conversion("pixel buffer pool")
        }
    }

    deinit {
        scratch.forEach { free($0) }
    }

    private static func even(_ v: Double) -> Double { Double(Int(v) & ~1) }

    func convert(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        guard CVPixelBufferGetPixelFormatType(source) == CaptureFormat.pixelFormat,
              CVPixelBufferGetPlaneCount(source) == 2 else {
            throw VideoFramesError.conversion("decoder didn't return 420f")
        }
        if passesThrough,
           CVPixelBufferGetWidth(source) == CaptureFormat.width,
           CVPixelBufferGetHeight(source) == CaptureFormat.height {
            return source
        }
        guard let pool else { throw VideoFramesError.conversion("no pool") }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out else {
            throw VideoFramesError.conversion("pool exhausted")
        }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(out, [])
        defer {
            CVPixelBufferUnlockBaseAddress(out, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        var luma = Self.plane(source, 0)
        var chroma = Self.plane(source, 1)

        // 1. Upright: mirror, then quarter turns (each 2-byte CbCr pair is
        //    moved as one 16-bit pixel).
        var slot = 0
        if orientation.mirrored {
            let y = scratchPlane(slot, width: luma.width, height: luma.height, bytesPerPixel: 1)
            let c = scratchPlane(slot + 1, width: chroma.width, height: chroma.height, bytesPerPixel: 2)
            slot += 2
            var dy = y, dc = c
            try check(vImageHorizontalReflect_Planar8(&luma, &dy, vImage_Flags(kvImageNoFlags)), "mirror Y")
            try check(vImageHorizontalReflect_Planar16U(&chroma, &dc, vImage_Flags(kvImageNoFlags)), "mirror CbCr")
            luma = dy; chroma = dc
        }
        if orientation.quarterTurnsCW != 0 {
            let odd = orientation.quarterTurnsCW % 2 == 1
            let y = scratchPlane(slot, width: odd ? luma.height : luma.width,
                                 height: odd ? luma.width : luma.height, bytesPerPixel: 1)
            let c = scratchPlane(slot + 1, width: odd ? chroma.height : chroma.width,
                                 height: odd ? chroma.width : chroma.height, bytesPerPixel: 2)
            let constant: UInt8
            switch orientation.quarterTurnsCW {
            case 1:  constant = UInt8(kRotate90DegreesClockwise)
            case 2:  constant = UInt8(kRotate180DegreesClockwise)
            default: constant = UInt8(kRotate90DegreesCounterClockwise)
            }
            var dy = y, dc = c
            try check(vImageRotate90_Planar8(&luma, &dy, constant, 0, vImage_Flags(kvImageNoFlags)), "rotate Y")
            try check(vImageRotate90_Planar16U(&chroma, &dc, constant, 0x8080, vImage_Flags(kvImageNoFlags)), "rotate CbCr")
            luma = dy; chroma = dc
        }

        // 2. Fit into 1280×720.
        let outLuma = Self.plane(out, 0)
        let outChroma = Self.plane(out, 1)
        let content = contentRect
        if content.width < CGFloat(CaptureFormat.width) || content.height < CGFloat(CaptureFormat.height) {
            // Black bars: Y 0 (full range), Cb = Cr = 128.
            Self.fill(outLuma, value: 0)
            Self.fill(outChroma, value: 128)
        }
        var srcLuma = luma, srcChroma = chroma
        if fit == .crop {
            let sw = Int(Self.even(min(Double(luma.width), (Double(CaptureFormat.width) / scale).rounded())))
            let sh = Int(Self.even(min(Double(luma.height), (Double(CaptureFormat.height) / scale).rounded())))
            let sx = (Int(luma.width) - sw) / 2 & ~1, sy = (Int(luma.height) - sh) / 2 & ~1
            srcLuma = Self.sub(luma, x: sx, y: sy, width: sw, height: sh, bytesPerPixel: 1)
            srcChroma = Self.sub(chroma, x: sx / 2, y: sy / 2, width: sw / 2, height: sh / 2, bytesPerPixel: 2)
        }
        var dstLuma = Self.sub(outLuma, x: Int(content.minX), y: Int(content.minY),
                               width: Int(content.width), height: Int(content.height), bytesPerPixel: 1)
        var dstChroma = Self.sub(outChroma, x: Int(content.minX) / 2, y: Int(content.minY) / 2,
                                 width: Int(content.width) / 2, height: Int(content.height) / 2, bytesPerPixel: 2)
        if srcLuma.width == dstLuma.width && srcLuma.height == dstLuma.height {
            try check(vImageCopyBuffer(&srcLuma, &dstLuma, 1, vImage_Flags(kvImageNoFlags)), "copy Y")
            try check(vImageCopyBuffer(&srcChroma, &dstChroma, 2, vImage_Flags(kvImageNoFlags)), "copy CbCr")
        } else {
            try check(vImageScale_Planar8(&srcLuma, &dstLuma, nil, vImage_Flags(kvImageNoFlags)), "scale Y")
            try check(vImageScale_CbCr8(&srcChroma, &dstChroma, nil, vImage_Flags(kvImageNoFlags)), "scale CbCr")
        }

        // Keep the source's colour description (matrix, primaries,
        // transfer function) so Vision converts to RGB the same way.
        for key in [kCVImageBufferYCbCrMatrixKey, kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey] {
            if let value = CVBufferCopyAttachment(source, key, nil) {
                CVBufferSetAttachment(out, key, value, .shouldPropagate)
            }
        }
        return out
    }

    // MARK: Planes

    private static func plane(_ buffer: CVPixelBuffer, _ index: Int) -> vImage_Buffer {
        vImage_Buffer(data: CVPixelBufferGetBaseAddressOfPlane(buffer, index),
                      height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(buffer, index)),
                      width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(buffer, index)),
                      rowBytes: CVPixelBufferGetBytesPerRowOfPlane(buffer, index))
    }

    private static func sub(_ b: vImage_Buffer, x: Int, y: Int, width: Int, height: Int,
                            bytesPerPixel: Int) -> vImage_Buffer {
        vImage_Buffer(data: b.data.advanced(by: y * b.rowBytes + x * bytesPerPixel),
                      height: vImagePixelCount(max(0, height)), width: vImagePixelCount(max(0, width)),
                      rowBytes: b.rowBytes)
    }

    private static func fill(_ b: vImage_Buffer, value: Int32) {
        // rowBytes covers the whole row (both bytes of each CbCr pair).
        for row in 0..<Int(b.height) {
            memset(b.data.advanced(by: row * b.rowBytes), value, b.rowBytes)
        }
    }

    private func scratchPlane(_ slot: Int, width: vImagePixelCount, height: vImagePixelCount,
                              bytesPerPixel: Int) -> vImage_Buffer {
        // Sized for the largest plane this converter can see; the source
        // never changes size mid-video.
        let rowBytes = Int(width) * bytesPerPixel
        let needed = rowBytes * Int(height)
        while scratch.count <= slot {
            scratch.append(malloc(max(needed, 1))!)
            scratchSizes.append(max(needed, 1))
        }
        if scratchSizes[slot] < needed {
            free(scratch[slot])
            scratch[slot] = malloc(needed)!
            scratchSizes[slot] = needed
        }
        return vImage_Buffer(data: scratch[slot], height: height, width: width, rowBytes: rowBytes)
    }
    private var scratchSizes: [Int] = []

    private func check(_ error: vImage_Error, _ step: String) throws {
        guard error == kvImageNoError else { throw VideoFramesError.conversion("\(step): vImage error \(error)") }
    }
}
