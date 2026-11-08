// SetupCheck.swift
// Is the phone in a good spot? Judged from the rim alone, since that's the
// one thing the detector reliably finds before anyone shoots: how big it
// looks says how far away the phone is, and where it sits in the picture
// says whether the ball's flight will stay in view.
//
// The limits come from the real clips the tracker is measured on (rim
// ~0.047 of the frame wide, its top at ~0.82, every usable shot called
// right) and from the detector: a ball under ~12 px across is missed.

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

nonisolated enum SetupAdvice: String, Equatable, Sendable {
    case good
    /// Part of the rim is outside the picture.
    case rimCutOff
    /// The rim fills too much of the picture: shots leave the frame.
    case tooClose
    /// The rim (and so the ball) is too small to follow.
    case tooFar
    /// No room above the rim for the ball's arc: aim higher.
    case tiltUp
    /// The rim is low in the picture, so the release is cut off: aim lower.
    case tiltDown
    /// The rim is near the left edge of the picture.
    case turnLeft
    /// The rim is near the right edge of the picture.
    case turnRight

    var isGood: Bool { self == .good }

    /// Big line on the live screen.
    var title: String {
        switch self {
        case .good:      return "Good spot"
        case .rimCutOff: return "The rim's cut off"
        case .tooClose:  return "Too close"
        case .tooFar:    return "Too far away"
        case .tiltUp:    return "Tilt the phone up"
        case .tiltDown:  return "Tilt the phone down"
        case .turnLeft:  return "Turn the phone left"
        case .turnRight: return "Turn the phone right"
        }
    }

    /// What to do, in one line.
    var detail: String {
        switch self {
        case .good:      return "Start shooting."
        case .rimCutOff: return "Aim so the whole rim is in the picture."
        case .tooClose:  return "Step back a couple of metres so the ball's flight fits."
        case .tooFar:    return "Move a few metres closer. The ball's too small to follow."
        case .tiltUp:    return "Leave room above the rim for the ball's arc."
        case .tiltDown:  return "Your release needs to be in the picture too."
        case .turnLeft:  return "The rim's near the edge. Bring it towards the middle."
        case .turnRight: return "The rim's near the edge. Bring it towards the middle."
        }
    }

    /// Said out loud when voice calls are on.
    var spoken: String {
        switch self {
        case .good:      return "Good spot. Start shooting."
        case .rimCutOff: return "The rim's cut off. Aim at the whole hoop."
        case .tooClose:  return "Too close. Step back a couple of metres."
        case .tooFar:    return "Too far. Move a few metres closer."
        case .tiltUp:    return "Tilt the phone up a little."
        case .tiltDown:  return "Tilt the phone down a little."
        case .turnLeft:  return "Turn the phone a little to the left."
        case .turnRight: return "Turn the phone a little to the right."
        }
    }
}

nonisolated enum SetupCheck {

    enum Limits {
        /// Rim width as a fraction of the frame's width.
        static let maxRimWidth = 0.11      // ~2.5 m from the rim
        static let minRimWidth = 0.026     // ~15 m; the ball is ~12 px across
        /// Room above the rim, in rim widths (~0.55 m). The real clips have ~2.
        static let minHeadroomRims = 1.2
        /// Lowest the rim's centre may sit (Vision y, 0 = bottom).
        static let minRimCentreY = 0.3
        /// How close to a side the rim's centre may get.
        static let sideMargin = 0.12
        /// A box this close to an edge is taken to run off it.
        static let edge = 0.005
    }

    /// Advice for a rim box (Vision-normalised, origin bottom-left) in a
    /// frame `aspect` wide per unit of height. The most important problem
    /// wins: one that loses shots outright before one that loses some.
    static func advice(hoop: CGRect, aspect: Double = 16.0 / 9.0) -> SetupAdvice {
        let minX = Double(hoop.minX), maxX = Double(hoop.maxX)
        let minY = Double(hoop.minY), maxY = Double(hoop.maxY)
        let width = Double(hoop.width)
        guard width > 0, hoop.height > 0 else { return .rimCutOff }

        if minX <= Limits.edge || maxX >= 1 - Limits.edge
            || minY <= Limits.edge || maxY >= 1 - Limits.edge {
            return .rimCutOff
        }
        if width > Limits.maxRimWidth { return .tooClose }
        if width < Limits.minRimWidth { return .tooFar }

        // Heights are fractions of the frame's height; widths of its width.
        let headroom = (1 - maxY) / aspect / width
        if headroom < Limits.minHeadroomRims { return .tiltUp }
        if Double(hoop.midY) < Limits.minRimCentreY { return .tiltDown }
        if Double(hoop.midX) < Limits.sideMargin { return .turnLeft }
        if Double(hoop.midX) > 1 - Limits.sideMargin { return .turnRight }
        return .good
    }
}
