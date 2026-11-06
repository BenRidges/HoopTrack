// Extensions.swift
// Small Foundation-only helpers. Kept free of UIKit/SwiftUI so the pure
// CV and stats code that uses them can be built and tested anywhere.

import Foundation

nonisolated extension Double {
    /// Clamps the value into `range`.
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.max(range.lowerBound, Swift.min(range.upperBound, self))
    }
}

nonisolated extension Date {
    /// "Today", "Yesterday", or an abbreviated date like "4 Nov".
    var relativeDayLabel: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self)     { return "Today" }
        if calendar.isDateInYesterday(self) { return "Yesterday" }
        return formatted(.dateTime.day().month(.abbreviated))
    }
}

nonisolated extension TimeInterval {
    /// "4:07" style clock text for durations.
    var clockText: String {
        let total = Int(self.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
