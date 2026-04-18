// HoopTrack/Views/Auth/SignUpView.swift
import SwiftUI

struct SignUpView: View {
    @EnvironmentObject var authViewModel: AuthViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var email    = ""
    @State private var password = ""
    @State private var confirm  = ""
    @FocusState private var focus: Field?

    enum Field { case email, password, confirm }

    var body: some View {
        ZStack {
            AuthBackground()

            ScrollView {
                VStack(spacing: 32) {
                    Spacer(minLength: 40)

                    // MARK: Brand
                    VStack(spacing: 12) {
                        Image(systemName: "basketball.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(.orange)
                            .shadow(color: .orange.opacity(0.5), radius: 18, y: 4)
                        Text("Create Account")
                            .font(.system(size: 32, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                        Text("Track every shot. Own your game.")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.7))
                    }

                    // MARK: Form Card
                    VStack(spacing: 14) {
                        AuthField(icon: "envelope.fill",
                                  placeholder: "Email",
                                  text: $email,
                                  isSecure: false,
                                  contentType: .emailAddress,
                                  keyboard: .emailAddress)
                            .focused($focus, equals: .email)
                            .onSubmit { focus = .password }

                        AuthField(icon: "lock.fill",
                                  placeholder: "Password (min \(HoopTrack.Auth.minPasswordLength) chars)",
                                  text: $password,
                                  isSecure: true,
                                  contentType: .newPassword,
                                  keyboard: .default)
                            .focused($focus, equals: .password)
                            .onSubmit { focus = .confirm }

                        AuthField(icon: "lock.shield.fill",
                                  placeholder: "Confirm password",
                                  text: $confirm,
                                  isSecure: true,
                                  contentType: .newPassword,
                                  keyboard: .default)
                            .focused($focus, equals: .confirm)
                            .onSubmit { Task { await submit() } }

                        if case .error(let err) = authViewModel.state,
                           let message = err.errorDescription {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                Text(message).font(.footnote)
                            }
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 2)
                        }

                        AuthPrimaryButton(
                            title: "Create Account",
                            isLoading: isLoading,
                            isEnabled: !email.isEmpty && !password.isEmpty && !confirm.isEmpty
                        ) {
                            Task { await submit() }
                        }
                        .padding(.top, 6)
                    }
                    .padding(20)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .overlay(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .stroke(.white.opacity(0.08), lineWidth: 1)
                            )
                    )
                    .padding(.horizontal, 24)

                    Spacer(minLength: 20)
                }
            }
            .scrollDismissesKeyboard(.interactively)

            // Close button — top-left, floats over the background.
            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .frame(width: 36, height: 36)
                            .background(.white.opacity(0.08), in: Circle())
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .padding(.leading, 20)
                    .padding(.top, 10)
                    Spacer()
                }
                Spacer()
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: authViewModel.state) { _, newState in
            if newState.user != nil { dismiss() }
        }
    }

    private var isLoading: Bool {
        if case .authenticating = authViewModel.state { return true }
        return false
    }

    private func submit() async {
        focus = nil
        await authViewModel.signUp(email: email,
                                     password: password,
                                     confirmPassword: confirm)
    }
}
