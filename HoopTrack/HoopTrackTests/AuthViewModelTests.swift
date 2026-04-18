// HoopTrackTests/AuthViewModelTests.swift
import XCTest
@testable import HoopTrack

@MainActor
final class AuthViewModelTests: XCTestCase {

    // MARK: - Initial state

    func test_initialState_isUnauthenticated_whenRestoreReturnsNil() async {
        let mock = MockAuthProvider()
        mock.scriptedRestoreResult = .success(nil)
        let vm = AuthViewModel(provider: mock)

        await vm.restore()

        XCTAssertEqual(vm.state, .unauthenticated)
    }

    func test_initialState_isAuthenticated_whenRestoreReturnsUser() async {
        let user = AuthUser(id: UUID(), email: "a@b.co", emailVerified: true, createdAt: Date())
        let mock = MockAuthProvider()
        mock.scriptedRestoreResult = .success(user)
        let vm = AuthViewModel(provider: mock)

        await vm.restore()

        XCTAssertEqual(vm.state, .authenticated(user))
    }

    // MARK: - Sign up validation (pure, no network)

    func test_signUp_rejectsInvalidEmail() async {
        let vm = AuthViewModel(provider: MockAuthProvider())
        await vm.signUp(email: "not-an-email", password: "password123", confirmPassword: "password123")
        XCTAssertEqual(vm.state, .error(.invalidEmail))
    }

    func test_signUp_rejectsShortPassword() async {
        let vm = AuthViewModel(provider: MockAuthProvider())
        await vm.signUp(email: "a@b.co", password: "short", confirmPassword: "short")
        XCTAssertEqual(vm.state, .error(.passwordTooShort(minimum: HoopTrack.Auth.minPasswordLength)))
    }

    func test_signUp_rejectsPasswordMismatch() async {
        let vm = AuthViewModel(provider: MockAuthProvider())
        await vm.signUp(email: "a@b.co", password: "password123", confirmPassword: "different123")
        XCTAssertEqual(vm.state, .error(.passwordMismatch))
    }

    // MARK: - Sign up happy path

    func test_signUp_success_landsInAuthenticatedState() async {
        let user = AuthUser(id: UUID(), email: "a@b.co", emailVerified: false, createdAt: Date())
        let mock = MockAuthProvider()
        mock.scriptedSignUpResult = .success(user)
        let vm = AuthViewModel(provider: mock)

        await vm.signUp(email: "a@b.co", password: "password123", confirmPassword: "password123")

        XCTAssertEqual(vm.state, .authenticated(user))
        XCTAssertEqual(mock.signUpCalls.count, 1)
        XCTAssertEqual(mock.signUpCalls.first?.email, "a@b.co")
    }

    // MARK: - Sign in

    func test_signIn_success_landsInAuthenticated() async {
        let user = AuthUser(id: UUID(), email: "a@b.co", emailVerified: true, createdAt: Date())
        let mock = MockAuthProvider()
        mock.scriptedSignInResult = .success(user)
        let vm = AuthViewModel(provider: mock)

        await vm.signIn(email: "a@b.co", password: "password123")
        XCTAssertEqual(vm.state, .authenticated(user))
    }

    func test_signIn_mapsServerError_toAuthError() async {
        let mock = MockAuthProvider()
        mock.scriptedSignInResult = .failure(AuthError.invalidCredentials)
        let vm = AuthViewModel(provider: mock)

        await vm.signIn(email: "a@b.co", password: "wrongpass")
        XCTAssertEqual(vm.state, .error(.invalidCredentials))
    }

    // MARK: - Sign out

    func test_signOut_returnsToUnauthenticated() async {
        let user = AuthUser(id: UUID(), email: "a@b.co", emailVerified: true, createdAt: Date())
        let mock = MockAuthProvider()
        mock.scriptedRestoreResult = .success(user)
        let vm = AuthViewModel(provider: mock)
        await vm.restore()

        await vm.signOut()

        XCTAssertEqual(vm.state, .unauthenticated)
        XCTAssertEqual(mock.signOutCount, 1)
    }

    // MARK: - Locking

    func test_lock_movesAuthenticatedUser_toLockedState() async {
        let user = AuthUser(id: UUID(), email: "a@b.co", emailVerified: true, createdAt: Date())
        let mock = MockAuthProvider()
        mock.scriptedRestoreResult = .success(user)
        let vm = AuthViewModel(provider: mock)
        await vm.restore()

        vm.lock()
        XCTAssertEqual(vm.state, .locked(user))
    }

    func test_lock_fromUnauthenticated_isNoop() async {
        let vm = AuthViewModel(provider: MockAuthProvider())
        vm.lock()
        XCTAssertEqual(vm.state, .unauthenticated)
    }

    func test_unlock_movesLockedUser_toAuthenticated() async {
        let user = AuthUser(id: UUID(), email: "a@b.co", emailVerified: true, createdAt: Date())
        let mock = MockAuthProvider()
        mock.scriptedRestoreResult = .success(user)
        let vm = AuthViewModel(provider: mock)
        await vm.restore()
        vm.lock()

        vm.unlock()

        XCTAssertEqual(vm.state, .authenticated(user))
    }
}
