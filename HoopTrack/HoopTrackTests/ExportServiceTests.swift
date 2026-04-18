// HoopTrackTests/ExportServiceTests.swift
import XCTest
import SwiftData
@testable import HoopTrack

@MainActor
final class ExportServiceTests: XCTestCase {

    private var container: ModelContainer!
    private var dataService: DataService!

    override func setUp() async throws {
        let schema = Schema([
            PlayerProfile.self, TrainingSession.self,
            ShotRecord.self, GoalRecord.self, EarnedBadge.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: config)
        dataService = DataService(modelContext: container.mainContext)
    }

    override func tearDown() async throws {
        container = nil
        dataService = nil
    }

    func test_exportJSON_producesValidJSONWithCorrectShape() async throws {
        // Arrange
        let profile = try dataService.fetchOrCreateProfile()
        profile.name = "Test Player"
        let session = try dataService.startSession(drillType: .freeShoot)
        _ = try dataService.addShot(to: session, result: .make,
                                    zone: .midRange, shotType: .catchAndShoot,
                                    courtX: 0.5, courtY: 0.5)
        _ = try dataService.addShot(to: session, result: .miss,
                                    zone: .cornerThree, shotType: .catchAndShoot,
                                    courtX: 0.1, courtY: 0.1)
        try dataService.finaliseSession(session)

        let sut = ExportService()

        // Act
        let url = try await sut.exportJSON(for: profile)

        // Assert — valid JSON file was written
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["profileName"] as? String, "Test Player")
        XCTAssertNotNil(json["exportedAt"])

        let sessions = json["sessions"] as? [[String: Any]]
        XCTAssertEqual(sessions?.count, 1)

        let shots = sessions?.first?["shots"] as? [[String: Any]]
        XCTAssertEqual(shots?.count, 2)

        let firstShot = shots?.first
        XCTAssertNotNil(firstShot?["id"])
        XCTAssertEqual(firstShot?["zone"] as? String, "midRange")
        XCTAssertEqual(firstShot?["made"] as? Bool, true)
    }

    func test_exportJSON_emptySessionListProducesValidJSON() async throws {
        let profile = try dataService.fetchOrCreateProfile()
        profile.name = "Empty Player"
        let sut = ExportService()

        let url = try await sut.exportJSON(for: profile)
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["profileName"] as? String, "Empty Player")
        let sessions = json["sessions"] as? [[String: Any]]
        XCTAssertEqual(sessions?.count, 0)
    }

    // Phase 7 — Security: exported JSON must have FileProtectionType.complete applied.
    // Note: the iOS Simulator does not enforce file protection attributes; this test
    // verifies the attribute is set correctly on a physical device.  On the simulator
    // the setAttributes call succeeds but attributesOfItem returns nil for .protectionKey,
    // so we skip the assertion there to keep CI green.
    func test_exportJSON_fileHasCompleteFileProtection() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("File protection attributes are not enforced on the iOS Simulator")
        #else
        let profile = try dataService.fetchOrCreateProfile()
        profile.name = "Protected Player"
        let sut = ExportService()

        let url = try await sut.exportJSON(for: profile)

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let protection = attrs[.protectionKey] as? FileProtectionType
        XCTAssertEqual(protection, .complete,
                       "Exported JSON must be protected with FileProtectionType.complete")
        #endif
    }
}
