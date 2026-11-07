// Environment.swift
// What a run depends on besides the code: the Mac it ran on (OS, chip,
// where Core ML put the model) and how the source video differs from what
// the app's camera delivers. Both go into summary.txt, so a reader can see
// which differences from a phone were in play.

import CoreGraphics
import CoreML
import CoreVideo
import Foundation
@testable import HoopTrack

struct RunEnvironment {
    let os: String
    let chip: String
    let memoryGB: Double
    /// Where Core ML's compute plan puts the model's operations, e.g.
    /// "Neural Engine 112, CPU 3", or why that's unknown.
    let computePlan: String

    /// `compiled`: the .mlmodelc the run loads, configured as
    /// CoreMLBallDetector configures it (all compute units).
    static func current(model compiled: URL) async -> RunEnvironment {
        // "Version 15.7.4 (Build 24G517)" → "macOS 15.7.4 (Build 24G517)"
        RunEnvironment(os: "macOS " + ProcessInfo.processInfo.operatingSystemVersionString
                           .replacingOccurrences(of: "Version ", with: ""),
                       chip: sysctl("machdep.cpu.brand_string") ?? "unknown chip",
                       memoryGB: Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824,
                       computePlan: await computePlan(compiled))
    }

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func computePlan(_ url: URL) async -> String {
        guard #available(macOS 14.4, *) else { return "unknown (MLComputePlan needs macOS 14.4)" }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let plan: MLComputePlan
        do {
            plan = try await MLComputePlan.load(contentsOf: url, configuration: configuration)
        } catch {
            return "unknown (\(error.localizedDescription))"
        }
        var counts: [String: Int] = [:]
        func note(_ usage: MLComputePlan.DeviceUsage?) {
            guard let device = usage?.preferred else { return }
            counts[name(device), default: 0] += 1
        }
        func walk(_ block: MLModelStructure.Program.Block) {
            for operation in block.operations {
                note(plan.deviceUsage(for: operation))
                operation.blocks.forEach(walk)
            }
        }
        func walk(_ structure: MLModelStructure) {
            switch structure {
            case .neuralNetwork(let network):
                network.layers.forEach { note(plan.deviceUsage(for: $0)) }
            case .program(let program):
                program.functions.values.forEach { walk($0.block) }
            case .pipeline(let pipeline):
                pipeline.subModels.forEach(walk)
            case .unsupported:
                break
            @unknown default:
                break
            }
        }
        walk(plan.modelStructure)
        guard !counts.isEmpty else { return "unknown (no operations in the compute plan)" }
        return counts.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            + " operations (Core ML's compute plan, all compute units)"
    }

    @available(macOS 14.0, *)
    private static func name(_ device: MLComputeDevice) -> String {
        switch device {
        case .cpu:          return "CPU"
        case .gpu:          return "GPU"
        case .neuralEngine: return "Neural Engine"
        @unknown default:   return "other"
        }
    }
}

/// How the source differs from what the app's camera hands the pipeline:
/// 1280×720 8-bit SDR 420f, tagged BT.709, at a steady 60 fps
/// (CameraService, HoopTrack.Camera.targetFPS).
enum SourceCheck {

    /// The app's capture rate, and how far from it still counts as the same.
    static let appFPS = HoopTrack.Camera.targetFPS
    static let fpsTolerance = 1.0

    static func warnings(info: VideoInfo, converter: FrameConverter, fit: FitMode,
                         decodedPTS: [Double], stride: Int) -> [String] {
        var out: [String] = []
        let intervals = zip(decodedPTS.dropFirst(), decodedPTS).map { $0 - $1 }.filter { $0 > 0 }
        let median = percentile(intervals, 0.5)
        if median > 0 {
            let fps = 1 / median
            if abs(fps - appFPS) > fpsTolerance {
                out.append("\(f(fps, 2)) fps, not the app's \(Int(appFPS)): NetWatch's per-frame net activity "
                           + "(judged against an absolute floor) and ShotTracker's gates (which scale with dt × 30) "
                           + "behave as on a \(Int(fps.rounded())) fps camera")
            }
            // A steady camera's frame intervals are all the same, give or
            // take the container's timescale.
            let off = intervals.filter { abs($0 - median) > 0.1 * median }.count
            if Double(off) > 0.01 * Double(intervals.count) {
                out.append("variable frame rate: \(off) of \(intervals.count) frame intervals differ from the median "
                           + "\(f(median * 1000, 1)) ms by over 10% (\(f(intervals.min()! * 1000, 1))–\(f(intervals.max()! * 1000, 1)) ms); "
                           + "the app's camera runs at a fixed rate")
            }
        }
        if stride > 1 {
            out.append("--stride \(stride): every \(stride)th frame fed, an effective \(f((median > 0 ? 1 / median : 0) / Double(stride), 1)) fps camera")
        }
        if let hdr = info.hdrDescription {
            out.append("HDR source (\(hdr)): decoded to 8-bit as is, so it looks flat to the model; "
                       + "the app's camera delivers 8-bit SDR")
        }
        let missing = [("colour primaries", info.colorPrimaries), ("transfer function", info.transferFunction),
                       ("YCbCr matrix", info.yCbCrMatrix)].filter { $0.1 == nil }.map(\.0)
        if !missing.isEmpty {
            out.append("no \(missing.joined(separator: " / ")) tag: Vision has to guess how to turn YCbCr into RGB "
                       + "(the camera's buffers are tagged BT.709)")
        } else if let matrix = info.yCbCrMatrix, matrix != (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String), info.hdrDescription == nil {
            out.append("YCbCr matrix \(matrix), not the camera's BT.709")
        }
        let content = converter.contentRect
        if content.width < CGFloat(CaptureFormat.width) || content.height < CGFloat(CaptureFormat.height) {
            out.append("not 16:9 (\(converter.uprightSize.width)x\(converter.uprightSize.height) upright): letterboxed with "
                       + "black bars into 1280x720, so the scene gets fewer pixels than a phone's frame would")
        } else if fit == .crop, !converter.passesThrough,
                  abs(Double(converter.uprightSize.width) / Double(converter.uprightSize.height) - 16.0 / 9) > 0.01 {
            out.append("not 16:9 (\(converter.uprightSize.width)x\(converter.uprightSize.height) upright): "
                       + "centre-cropped (--fit crop), so part of the picture is cut off")
        }
        return out
    }
}
