// HoopTrack/Views/Auth/LockedView.swift
import SwiftUI

struct LockedView: View {
    @EnvironmentObject var authViewModel: AuthViewModel
    @StateObject private var biometrics = BiometricService()

    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            AuthBackground()

            VStack(spacing: 28) {
                Spacer()

                VStack(spacing: 16) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.orange)
                        .shadow(color: .orange.opacity(0.5), radius: 18, y: 4)

                    Text("Locked")
                        .font(.system(size: 32, weight: .black, design: .rounded))
                        .foregroundStyle(.white)

                    Text("Unlock to continue")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 32)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 12) {
                    AuthPrimaryButton(
                        title: "Unlock",
                        isLoading: false,
                        isEnabled: true
                    ) {
                        Task { await unlock() }
                    }

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
        .task { await unlock() }
    }

    private func unlock() async {
        do {
            if try await biometrics.authenticate(reason: "Unlock HoopTrack") {
                authViewModel.unlock()
            }
        } catch let error as AuthError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
