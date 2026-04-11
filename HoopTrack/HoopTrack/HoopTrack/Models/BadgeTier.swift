// BadgeTier.swift
import Foundation

enum BadgeTier: Int, Comparable, Codable, CaseIterable {
    case bronze = 1, silver = 2, gold = 3, platinum = 4, diamond = 5, champion = 6

    static func < (lhs: BadgeTier, rhs: BadgeTier) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .bronze:   return "Bronze"
        case .silver:   return "Silver"
        case .gold:     return "Gold"
        case .platinum: return "Platinum"
        case .diamond:  return "Diamond"
        case .champion: return "Champion"
        }
    }
}

struct BadgeRank: Equatable {
    let tier: BadgeTier
    let division: Int?  // 1, 2, 3 for Bronze–Diamond; nil for Champion
    let mmr: Double     // 0–1800

    init(mmr: Double) {
        let clamped = max(0, min(1800, mmr))
        self.mmr = clamped
        switch clamped {
        case 1500...:     self.tier = .champion; self.division = nil
        case 1200..<1500: self.tier = .diamond;  self.division = BadgeRank.div(base: 1200, mmr: clamped)
        case 900..<1200:  self.tier = .platinum; self.division = BadgeRank.div(base: 900,  mmr: clamped)
        case 600..<900:   self.tier = .gold;     self.division = BadgeRank.div(base: 600,  mmr: clamped)
        case 300..<600:   self.tier = .silver;   self.division = BadgeRank.div(base: 300,  mmr: clamped)
        default:          self.tier = .bronze;   self.division = BadgeRank.div(base: 0,    mmr: clamped)
        }
    }

    // Returns 1, 2, or 3 based on position within the 300-point tier band.
    private static func div(base: Double, mmr: Double) -> Int {
        min(3, Int((mmr - base) / 100) + 1)
    }

    var displayName: String {
        guard let d = division else { return tier.label }
        return "\(tier.label) \(["I","II","III"][d - 1])"
    }
}
