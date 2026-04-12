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
