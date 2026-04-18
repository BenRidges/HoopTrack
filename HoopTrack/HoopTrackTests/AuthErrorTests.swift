// HoopTrackTests/AuthErrorTests.swift
import XCTest
@testable import HoopTrack

final class AuthErrorTests: XCTestCase {
    func test_errorDescription_forEveryCase_isNotEmpty() {
        let cases: [AuthError] = [
            .invalidEmail,
            .passwordTooShort(minimum: 8),
            .passwordMismatch,
            .invalidCredentials,
            .emailNotConfirmed,
            .emailAlreadyRegistered,
            .networkUnavailable,
            .sessionExpired,
            .biometricUnavailable,
            .biometricFailed,
            .keychainFailure,
            .underlying("test"),
        ]
        for err in cases {
            XCTAssertFalse(err.errorDescription?.isEmpty ?? true,
                            "Missing description for \(err)")
        }
    }

    func test_passwordTooShort_includesMinimumInMessage() {
        let err = AuthError.passwordTooShort(minimum: 8)
        XCTAssertTrue(err.errorDescription?.contains("8") ?? false)
    }

    func test_underlying_passesThroughMessage() {
        let err = AuthError.underlying("custom error text")
        XCTAssertEqual(err.errorDescription, "custom error text")
    }

    func test_cases_equateByAssociatedValue() {
        XCTAssertEqual(AuthError.passwordTooShort(minimum: 8),
                        AuthError.passwordTooShort(minimum: 8))
        XCTAssertNotEqual(AuthError.passwordTooShort(minimum: 8),
                           AuthError.passwordTooShort(minimum: 12))
    }
}
