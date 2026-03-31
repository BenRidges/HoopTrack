// Extensions.swift
// Convenience extensions on standard library and Apple framework types.

import Foundation
import SwiftUI
import AVFoundation

// MARK: - Double

extension Double {
    /// Clamps the value between `min` and `max`.
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.max(range.lowerBound, Swift.min(range.upperBound, self))
    }

    /// Rounds to `places` decimal places.
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }

    /// Returns a percentage string e.g. "47.3%"
    var fgPercentString: String { String(format: "%.1f%%", self) }
}

// MARK: - Date

extension Date {
    /// True if the date falls on the same calendar day as `other`.
    func isSameDay(as other: Date, calendar: Calendar = .current) -> Bool {
        calendar.isDate(self, inSameDayAs: other)
    }

    /// Returns a "Today", "Yesterday", or abbreviated date string.
    var relativeShortLabel: String {
        let cal = Calendar.current
        if cal.isDateInToday(self)     { return "Today" }
        if cal.isDateInYesterday(self) { return "Yesterday" }
        return self.formatted(.dateTime.month(.abbreviated).day())
    }
}

// MARK: - Array

extension Array {
    /// Returns the element at `index` if in bounds, otherwise nil.
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - SwiftUI Color

extension Color {
    /// HoopTrack brand orange.
    static let hoopOrange = Color.orange

    /// Returns green/orange/red based on a 0–100 FG% value.
    static func fgPercentColor(_ percent: Double) -> Color {
        switch percent {
        case 50...:     return .green
        case 35..<50:   return .orange
        default:        return .red
        }
    }
}

// MARK: - View

extension View {
    /// Adds a standard HoopTrack card background.
    func hoopCard() -> some View {
        self
            .padding(HoopTrack.UI.cardPadding)
            .background(.ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: HoopTrack.UI.cornerRadius,
                                             style: .continuous))
    }

    /// Conditionally applies a modifier.
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool,
                              transform: (Self) -> Content) -> some View {
        if condition { transform(self) } else { self }
    }
}

// MARK: - AVCaptureDevice

extension AVCaptureDevice {
    /// Checks whether the device supports a given frame rate.
    func supports(fps: Double) -> Bool {
        activeFormat.videoSupportedFrameRateRanges
            .contains { $0.maxFrameRate >= fps }
    }
}

// MARK: - CGPoint

extension CGPoint {
    /// Returns the Euclidean distance to another point.
    func distance(to other: CGPoint) -> CGFloat {
        sqrt(pow(x - other.x, 2) + pow(y - other.y, 2))
    }
}
