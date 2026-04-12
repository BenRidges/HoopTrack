// BadgeID.swift
import Foundation

enum BadgeID: String, CaseIterable, Codable {
    // Shooting (7)
    case deadeye, sniper, quickTrigger, beyondTheArc, charityStripe, threeLevelScorer, hotHand
    // Ball Handling (5)
    case handles, ambidextrous, comboKing, floorGeneral, ballWizard
    // Athleticism (4)
    case posterizer, lightning, explosive, highFlyer
    // Consistency (4)
    case automatic, metronome, iceVeins, reliable
    // Volume & Grind (5)
    case ironMan, gymRat, workhorse, specialist, completePlayer

    var displayName: String {
        switch self {
        case .deadeye:          return "Deadeye"
        case .sniper:           return "Sniper"
        case .quickTrigger:     return "Quick Trigger"
        case .beyondTheArc:     return "Beyond the Arc"
        case .charityStripe:    return "Charity Stripe"
        case .threeLevelScorer: return "Three-Level Scorer"
        case .hotHand:          return "Hot Hand"
        case .handles:          return "Handles"
        case .ambidextrous:     return "Ambidextrous"
        case .comboKing:        return "Combo King"
        case .floorGeneral:     return "Floor General"
        case .ballWizard:       return "Ball Wizard"
        case .posterizer:       return "Posterizer"
        case .lightning:        return "Lightning"
        case .explosive:        return "Explosive"
        case .highFlyer:        return "High Flyer"
        case .automatic:        return "Automatic"
        case .metronome:        return "Metronome"
        case .iceVeins:         return "Ice Veins"
        case .reliable:         return "Reliable"
        case .ironMan:          return "Iron Man"
        case .gymRat:           return "Gym Rat"
        case .workhorse:        return "Workhorse"
        case .specialist:       return "Specialist"
        case .completePlayer:   return "Complete Player"
        }
    }
}

extension BadgeID {
    /// The skill dimension this badge belongs to — single source of truth for badge grouping.
    var skillDimension: SkillDimension {
        switch self {
        case .deadeye, .sniper, .quickTrigger, .beyondTheArc,
             .charityStripe, .threeLevelScorer, .hotHand:      return .shooting
        case .handles, .ambidextrous, .comboKing,
             .floorGeneral, .ballWizard:                        return .ballHandling
        case .posterizer, .lightning, .explosive, .highFlyer:  return .athleticism
        case .automatic, .metronome, .iceVeins, .reliable:     return .consistency
        case .ironMan, .gymRat, .workhorse,
             .specialist, .completePlayer:                      return .volume
        }
    }

    /// One-line description of what this badge measures — shown when badge is not yet earned.
    var scoringDescription: String {
        switch self {
        case .deadeye:          return "Score high based on your field goal percentage."
        case .sniper:           return "Reward low release-angle standard deviation — consistency wins."
        case .quickTrigger:     return "Measures how fast you release the ball after catching."
        case .beyondTheArc:     return "Track your effectiveness from beyond the three-point line."
        case .charityStripe:    return "Convert free throws at a high rate (10+ attempts required)."
        case .threeLevelScorer: return "Demonstrate scoring from paint, mid-range, and three-point range."
        case .hotHand:          return "Captures your longest consecutive make streak in a session."
        case .handles:          return "Average dribbles per second across your drill session."
        case .ambidextrous:     return "How evenly you distribute dribbles between both hands."
        case .comboKing:        return "Ratio of dribble combo moves to total dribbles."
        case .floorGeneral:     return "Sustained dribble speed — how close avg BPS is to your peak."
        case .ballWizard:       return "Career total dribbles accumulated across all sessions."
        case .posterizer:       return "Your average vertical jump height per agility session."
        case .lightning:        return "Your best shuttle run time — lower is better."
        case .explosive:        return "Overall athleticism rating combining jump and agility scores."
        case .highFlyer:        return "Your all-time personal record vertical jump height."
        case .automatic:        return "How consistent your FG% is across recent sessions."
        case .metronome:        return "How consistent your release angle is across 10+ sessions."
        case .iceVeins:         return "Career free throw percentage with at least 50 attempts."
        case .reliable:         return "Consecutive sessions where you shot at least 40% from the field."
        case .ironMan:          return "Your longest consecutive daily training streak."
        case .gymRat:           return "Sessions completed in the last 7 days."
        case .workhorse:        return "Career total shots attempted across all sessions."
        case .specialist:       return "Most sessions completed in any single drill type."
        case .completePlayer:   return "Your weakest skill dimension score — build everything up."
        }
    }
}
