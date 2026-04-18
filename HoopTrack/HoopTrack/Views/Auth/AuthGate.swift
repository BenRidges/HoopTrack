// HoopTrack/Views/Auth/AuthGate.swift
import SwiftUI

/// Top-level auth router. Replaces what used to be the direct CoordinatorHost
/// presentation in HoopTrackApp — now CoordinatorHost only renders when the
/// user is authenticated and their email is verified.
struct AuthGate<Authenticated: View>: View {
    @EnvironmentObject var authViewModel: AuthViewModel
    let authenticatedContent: () -> Authenticated

    var body: some View {
        switch authViewModel.state {
        case .unauthenticated, .error:
            SignInView()
        case .authenticating:
            VStack { ProgressView().progressViewStyle(.circular) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .authenticated(let user) where !user.emailVerified:
            VerifyEmailView(user: user)
        case .authenticated:
            authenticatedContent()
        case .locked:
            LockedView()
        }
    }
}
