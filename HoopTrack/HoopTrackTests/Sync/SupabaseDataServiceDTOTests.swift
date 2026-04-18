// HoopTrackTests/Sync/SupabaseDataServiceDTOTests.swift
import XCTest
@testable import HoopTrack

@MainActor
final class SupabaseDataServiceDTOTests: XCTestCase {

    // MARK: - PlayerProfileDTO

    func test_playerProfileDTO_encodesSnakeCaseKeys() throws {
        let profile = PlayerProfile(name: "Test")
        profile.ratingShooting = 72
        let dto = PlayerProfileDTO(from: profile, userID: UUID())

        let data = try JSONEncoder().encode(dto)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(dict["name"] as? String, "Test")
        XCTAssertEqual(dict["rating_shooting"] as? Double, 72)
        XCTAssertNotNil(dict["user_id"])
        XCTAssertNil(dict["userId"])   // camelCase key should NOT appear
    }

    func test_playerProfileDTO_translatesInfiniteConsistencyScore_toNil() {
        let profile = PlayerProfile()
        profile.prBestConsistencyScore = .infinity
        let dto = PlayerProfileDTO(from: profile, userID: UUID())
        XCTAssertNil(dto.prBestConsistencyScore)
    }

    // MARK: - TrainingSessionDTO

    func test_trainingSessionDTO_roundTripsCore() throws {
        let session = TrainingSession(drillType: .freeShoot)
        session.shotsAttempted = 10
        session.shotsMade = 7
        session.fgPercent = 70
        let dto = TrainingSessionDTO(from: session, userID: UUID())

        let data = try JSONEncoder().encode(dto)
        let round = try JSONDecoder().decode(TrainingSessionDTO.self, from: data)

        XCTAssertEqual(round.id, session.id)
        XCTAssertEqual(round.shotsAttempted, 10)
        XCTAssertEqual(round.shotsMade, 7)
        XCTAssertEqual(round.fgPercent, 70)
        XCTAssertEqual(round.drillType, DrillType.freeShoot.rawValue)
    }

    func test_trainingSessionDTO_nullOptionalsStayNull() {
        let session = TrainingSession(drillType: .freeShoot)
        // No Shot Science data populated.
        let dto = TrainingSessionDTO(from: session, userID: UUID())
        XCTAssertNil(dto.avgReleaseAngleDeg)
        XCTAssertNil(dto.avgVerticalJumpCm)
        XCTAssertNil(dto.totalDribbles)
    }

    // MARK: - ShotRecordDTO

    func test_shotRecordDTO_carriesSessionId() {
        let sessionID = UUID()
        let shot = ShotRecord(sequenceIndex: 1,
                               result: .make,
                               zone: .midRange,
                               shotType: .catchAndShoot,
                               courtX: 0.5,
                               courtY: 0.5)
        let dto = ShotRecordDTO(from: shot, userID: UUID(), sessionID: sessionID)
        XCTAssertEqual(dto.sessionId, sessionID)
        XCTAssertEqual(dto.result, ShotResult.make.rawValue)
        XCTAssertEqual(dto.zone, CourtZone.midRange.rawValue)
    }

    // MARK: - GoalRecordDTO

    func test_goalRecordDTO_encodesEnumsAsRawValues() throws {
        let goal = GoalRecord(title: "Hit 40% from 3",
                               skill: .shooting,
                               metric: .fgPercent,
                               targetValue: 40,
                               baselineValue: 20)
        let dto = GoalRecordDTO(from: goal, userID: UUID())
        let data = try JSONEncoder().encode(dto)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(dict["skill"] as? String, SkillDimension.shooting.rawValue)
        XCTAssertEqual(dict["metric"] as? String, GoalMetric.fgPercent.rawValue)
        XCTAssertEqual(dict["target_value"] as? Double, 40)
        XCTAssertEqual(dict["baseline_value"] as? Double, 20)
    }

    // MARK: - EarnedBadgeDTO

    func test_earnedBadgeDTO_exposesBadgeIdAndDisplayRank() {
        let badge = EarnedBadge(badgeID: .deadeye, initialMMR: 650)
        let dto = EarnedBadgeDTO(from: badge, userID: UUID())
        XCTAssertEqual(dto.badgeId, "deadeye")
        // 650 MMR → gold tier (600–900 band) → "Gold I"
        XCTAssertTrue(dto.rank.contains("Gold"),
                      "Expected rank containing 'Gold', got '\(dto.rank)'")
    }
}
