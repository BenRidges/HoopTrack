import XCTest
@testable import HoopTrack

@MainActor
final class KeychainServiceTests: XCTestCase {

    private let service = KeychainService()
    private let testKey = "com.hooptrack.test.ephemeral"

    override func tearDown() {
        super.tearDown()
        service.delete(forKey: testKey)
        // Clean up any production-adjacent slots written by tests
        [HoopTrack.KeychainKey.accessToken,
         HoopTrack.KeychainKey.refreshToken,
         HoopTrack.KeychainKey.userID,
         HoopTrack.KeychainKey.biometricToken].forEach { service.delete(forKey: $0) }
    }

    // MARK: - String round-trip

    func test_saveAndRetrieveString() {
        service.save("hello-world", forKey: testKey)
        XCTAssertEqual(service.string(forKey: testKey), "hello-world")
    }

    func test_overwriteString() {
        service.save("first", forKey: testKey)
        service.save("second", forKey: testKey)
        XCTAssertEqual(service.string(forKey: testKey), "second")
    }

    func test_deleteRemovesString() {
        service.save("value", forKey: testKey)
        service.delete(forKey: testKey)
        XCTAssertNil(service.string(forKey: testKey))
    }

    // MARK: - Data round-trip

    func test_saveAndRetrieveData() {
        let data = Data([0x01, 0x02, 0x03])
        service.save(data, forKey: testKey)
        XCTAssertEqual(service.data(forKey: testKey), data)
    }

    // MARK: - deleteAll

    func test_deleteAllClearsAllKeys() {
        let keys = [HoopTrack.KeychainKey.accessToken,
                    HoopTrack.KeychainKey.refreshToken,
                    HoopTrack.KeychainKey.userID,
                    HoopTrack.KeychainKey.biometricToken]
        keys.forEach { service.save("token", forKey: $0) }

        service.deleteAll()

        keys.forEach {
            XCTAssertNil(service.string(forKey: $0),
                         "Expected nil for \($0) after deleteAll")
        }
    }
}
