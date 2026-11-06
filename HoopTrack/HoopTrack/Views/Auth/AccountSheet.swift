// AccountSheet.swift
// Optional cloud backup account. Opened from Profile — the app never
// blocks on it. Sign in / create account / confirm email in one sheet.

import SwiftUI
import UIKit

struct AccountSheet: View {
    @EnvironmentObject private var authViewModel: AuthViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var creating = false
    @State private var email = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var resendNote: String?
    @FocusState private var focused: Field?

    private enum Field { case email, password, confirm }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if case .authenticated(let user) = authViewModel.state, !user.emailVerified {
                        verify(user)
                    } else {
                        form
                    }
                }
                .padding(Metrics.screenPadding)
            }
            .courtBackground()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onChange(of: authViewModel.state) { _, state in
                if case .authenticated(let user) = state, user.emailVerified { dismiss() }
            }
        }
        .presentationDragIndicator(.visible)
    }

    // MARK: - Sign in / create

    private var form: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(creating ? "Create an account" : "Sign in")
                    .font(.largeTitle.bold())
                Text("Back up your sessions to the cloud. Everything works without an account.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                field("Email", text: $email, field: .email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                secure("Password", text: $password, field: .password)
                    .textContentType(creating ? UITextContentType.newPassword : .password)
                if creating {
                    secure("Confirm password", text: $confirm, field: .confirm)
                        .textContentType(.newPassword)
                }
            }

            if case .error(let error) = authViewModel.state {
                Label(error.errorDescription ?? "Something went wrong.", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Color.miss)
            }

            Button {
                submit()
            } label: {
                if authViewModel.state == .authenticating {
                    ProgressView().tint(Color.onLeather)
                } else {
                    Text(creating ? "Create account" : "Sign in")
                }
            }
            .buttonStyle(.primary)
            .disabled(email.isEmpty || password.isEmpty || authViewModel.state == .authenticating)

            Button(creating ? "I already have an account" : "New here? Create an account") {
                creating.toggle()
                authViewModel.dismissError()
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
        }
    }

    private func submit() {
        focused = nil
        Task {
            if creating {
                await authViewModel.signUp(email: email, password: password, confirmPassword: confirm)
            } else {
                await authViewModel.signIn(email: email, password: password)
            }
        }
    }

    private func field(_ title: String, text: Binding<String>, field: Field) -> some View {
        TextField(title, text: text)
            .focused($focused, equals: field)
            .padding(14)
            .background(Color.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func secure(_ title: String, text: Binding<String>, field: Field) -> some View {
        SecureField(title, text: text)
            .focused($focused, equals: field)
            .padding(14)
            .background(Color.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Confirm email

    private func verify(_ user: AuthUser) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "envelope.badge")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(Color.leather)
            VStack(alignment: .leading, spacing: 6) {
                Text("Check your inbox")
                    .font(.largeTitle.bold())
                Text("We sent a confirmation link to \(user.email). Open it on this phone and you're done.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Button("I've confirmed it") {
                Task { await authViewModel.refresh() }
            }
            .buttonStyle(.primary)
            HStack {
                Button("Resend email") {
                    Task {
                        resendNote = await authViewModel.resendConfirmation()
                            ? "Sent. It can take a minute."
                            : "Couldn't send. Try again shortly."
                    }
                }
                Spacer()
                Button("Use a different email", role: .destructive) {
                    Task { await authViewModel.signOut() }
                }
            }
            .font(.subheadline.weight(.semibold))
            if let resendNote {
                Text(resendNote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
