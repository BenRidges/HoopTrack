// HoopTrack/Views/Auth/LockedView.swift
import SwiftUI

struct LockedView: View {
    @EnvironmentObject var authViewModel: AuthViewModel
    @StateObject private var biometrics = BiometricService()

    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.fill")
                .font(.system(size: 64))
                .foregroundStyle(.orange)
            Text("Locked").font(.title.bold())
            Text("Unlock to continue")
                .foregroundStyle(.secondary)

            if let errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(.red)
            }

            Button("Unlock") {
                Task { await unlock() }
            }
            .buttonStyle(.borderedProminent)

            Button("Sign Out") {
                Task { await authViewModel.signOut() }
            }
            .foregroundStyle(.red)
        }
        .padding()
        .task { await unlock() }   // prompt biometrics on appear
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
