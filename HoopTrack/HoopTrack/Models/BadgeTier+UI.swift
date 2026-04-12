// BadgeTier+UI.swift
// UI extension kept separate to avoid importing SwiftUI in the core model layer.
import SwiftUI

extension BadgeTier {
    var color: Color {
        switch self {
        case .bronze:   return Color(red: 0.80, green: 0.50, blue: 0.20)
        case .silver:   return .gray
        case .gold:     return .yellow
        case .platinum: return Color(red: 0.60, green: 0.80, blue: 0.90)
        case .diamond:  return Color(red: 0.40, green: 0.60, blue: 1.00)
        case .champion: return .orange
        }
    }
}
