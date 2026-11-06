// SetNewPasswordView.swift
// Shown over the app when a password-reset link opens it. The link has
// already signed the user in; this just sets the new password.

import SwiftUI
import UIKit

struct SetNewPasswordView: View {
    @EnvironmentObject private var authViewModel: AuthViewModel

    @State private var password = ""
    @State private var confirm = ""
    @State private var error: String?
    @State private var saving = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "key.fill")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(Color.leather)
            VStack(alignment: .leading, spacing: 6) {
                Text("Choose a new password")
                    .font(.largeTitle.bold())
                if let email = authViewModel.state.user?.email, !email.isEmpty {
                    Text("For \(email).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 12) {
                SecureField("New password", text: $password)
                    .textContentType(.newPassword)
                    .focused($focused)
                    .padding(14)
                    .background(Color.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                SecureField("Confirm new password", text: $confirm)
                    .textContentType(.newPassword)
                    .padding(14)
                    .background(Color.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Color.miss)
            }
            Button {
                saving = true
                Task {
                    error = await authViewModel.setNewPassword(password, confirm: confirm)?.errorDescription
                    saving = false
                }
            } label: {
                if saving {
                    ProgressView().tint(Color.onLeather)
                } else {
                    Text("Save password")
                }
            }
            .buttonStyle(.primary)
            .disabled(password.isEmpty || saving)

            Button("Not now") { authViewModel.isSettingNewPassword = false }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
            Spacer()
        }
        .padding(Metrics.screenPadding)
        .padding(.top, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .courtBackground()
        .onAppear { focused = true }
    }
}
