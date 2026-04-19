import XCTest
@testable import HoopTrack

@MainActor
final class GameRegistrationViewModelTests: XCTestCase {

    private func sampleBlob() throws -> Data {
        let desc = AppearanceDescriptor(
            torsoHueHistogram: Array(repeating: 0.125, count: 8),
            torsoValueHistogram: Array(repeating: 0.25, count: 4),
            heightRatio: 0.5, upperBodyAspect: 0.6, schemaVersion: 1
        )
        return try JSONEncoder().encode(desc)
    }

    func test_initialState_hasCurrentPlayerIndexZero() {
        let vm = GameRegistrationViewModel(format: .twoOnTwo)
        XCTAssertEqual(vm.currentPlayerIndex, 0)
        XCTAssertEqual(vm.totalPlayers, 4)
        XCTAssertFalse(vm.isComplete)
        XCTAssertEqual(vm.pendingPlayers.count, 0)
    }

    func test_confirmPlayer_advancesIndex() throws {
        let vm = GameRegistrationViewModel(format: .twoOnTwo)
        let blob = try sampleBlob()
        vm.confirmPlayer(name: "Ben", descriptor: blob)
        XCTAssertEqual(vm.currentPlayerIndex, 1)
        XCTAssertEqual(vm.pendingPlayers.count, 1)
        XCTAssertEqual(vm.pendingPlayers.first?.name, "Ben")
    }

    func test_confirmingAllPlayers_setsIsCompleteTrue() throws {
        let vm = GameRegistrationViewModel(format: .twoOnTwo)
        let blob = try sampleBlob()
        for i in 0..<vm.totalPlayers {
            vm.confirmPlayer(name: "P\(i)", descriptor: blob)
        }
        XCTAssertTrue(vm.isComplete)
        XCTAssertEqual(vm.pendingPlayers.count, 4)
    }

    func test_restart_resetsState() throws {
        let vm = GameRegistrationViewModel(format: .twoOnTwo)
        let blob = try sampleBlob()
        vm.confirmPlayer(name: "A", descriptor: blob)
        vm.restart()
        XCTAssertEqual(vm.currentPlayerIndex, 0)
        XCTAssertEqual(vm.pendingPlayers.count, 0)
        XCTAssertFalse(vm.isComplete)
    }

    func test_threeOnThree_requiresSixPlayers() {
        let vm = GameRegistrationViewModel(format: .threeOnThree)
        XCTAssertEqual(vm.totalPlayers, 6)
    }
}
