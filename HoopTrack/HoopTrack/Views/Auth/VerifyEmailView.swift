// HoopTrack/Views/Auth/VerifyEmailView.swift
import SwiftUI

struct VerifyEmailView: View {
    @EnvironmentObject var authViewModel: AuthViewModel
    let user: AuthUser

    @State private var isResending = false
    @State private var isChecking  = false
    @State private var resendMessage: String?

    var body: some View {
        ZStack {
            AuthBackground()

            VStack(spacing: 28) {
                Spacer()

                VStack(spacing: 16) {
                    Image(systemName: "envelope.badge.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.orange)
                        .shadow(color: .orange.opacity(0.5), radius: 18, y: 4)

                    Text("Confirm your email")
                        .font(.system(size: 28, weight: .black, design: .rounded))
                        .foregroundStyle(.white)

                    VStack(spacing: 6) {
                        Text("We sent a verification link to")
                            .foregroundStyle(.white.opacity(0.7))
                        Text(user.email)
                            .font(.headline)
                            .foregroundStyle(.white)
                    }

                    Text("Click the link in your inbox, then tap below.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.top, 4)
                }

                if let resendMessage {
                    Label(resendMessage, systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.green)
                }

                VStack(spacing: 12) {
                    AuthPrimaryButton(
                        title: "I've Confirmed — Continue",
                        isLoading: isChecking,
                        isEnabled: true
                    ) {
                        Task { await refresh() }
                    }

                    Button {
                        Task { await resend() }
                    } label: {
                        Text(isResending ? "Sending…" : "Resend Email")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(.white.opacity(0.06))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .stroke(.white.opacity(0.1), lineWidth: 1)
                                    )
                            )
                    }
                    .disabled(isResending)

                    Button {
                        Task { await authViewModel.signOut() }
                    } label: {
                        Text("Sign Out")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.red.opacity(0.85))
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 32)

                Spacer()
            }
        }
        .preferredColorScheme(.dark)
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
