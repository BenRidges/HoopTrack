// HoopTrack/Views/Auth/VerifyEmailView.swift
import SwiftUI

struct VerifyEmailView: View {
    @EnvironmentObject var authViewModel: AuthViewModel
    let user: AuthUser

    @State private var isResending = false
    @State private var isChecking  = false
    @State private var resendMessage: String?

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "envelope.badge")
                .font(.system(size: 64))
                .foregroundStyle(.orange)
            Text("Confirm your email")
                .font(.title.bold())
            Text("We sent a verification link to:")
                .foregroundStyle(.secondary)
            Text(user.email).font(.headline)
            Text("Click the link in your inbox to finish setting up HoopTrack.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 40)

            if let resendMessage {
                Text(resendMessage).font(.footnote).foregroundStyle(.green)
            }

            VStack(spacing: 10) {
                Button(isChecking ? "Checking…" : "I've Confirmed — Continue") {
                    Task { await refresh() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isChecking)

                Button(isResending ? "Sending…" : "Resend Email") {
                    Task { await resend() }
                }
                .disabled(isResending)

                Button("Sign Out") {
                    Task { await authViewModel.signOut() }
                }
                .foregroundStyle(.red)
            }
        }
        .padding()
    }

    private func resend() async {
        isResending = true
        defer { isResending = false }
        resendMessage = "Email sent."
    }

    private func refresh() async {
        isChecking = true
        defer { isChecking = false }
        await authViewModel.refresh()
    }
}
