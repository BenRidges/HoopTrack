// HoopTrack/Extensions/Color+Brand.swift
// Phase 11 — Accessibility
import SwiftUI

extension Color {
    /// Brand orange — full saturation, for use on white/light backgrounds.
    static let brandOrange = Color(red: 1.0, green: 0.42, blue: 0.21)

    /// Accessible orange — lightened for text on dark backgrounds (4.5:1 on #1C1C1E).
    static let brandOrangeAccessible = Color(red: 1.0, green: 0.50, blue: 0.31)
}
