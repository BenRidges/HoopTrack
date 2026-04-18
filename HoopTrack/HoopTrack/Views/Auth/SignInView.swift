// HoopTrack/Views/Auth/SignInView.swift
import SwiftUI

struct SignInView: View {
    @EnvironmentObject var authViewModel: AuthViewModel

    @State private var email    = ""
    @State private var password = ""
    @State private var isShowingSignUp = false
    @FocusState private var focus: Field?

    enum Field { case email, password }

    var body: some View {
        ZStack {
            AuthBackground()

            ScrollView {
                VStack(spacing: 32) {
                    Spacer(minLength: 60)

                    // MARK: Brand
                    VStack(spacing: 12) {
                        Image(systemName: "basketball.fill")
                            .font(.system(size: 72))
                            .foregroundStyle(.orange)
                            .shadow(color: .orange.opacity(0.5), radius: 18, y: 4)
                        Text("HoopTrack")
                            .font(.system(size: 40, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                        Text("Welcome back.")
                            .font(.title3)
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
                                  placeholder: "Password",
                                  text: $password,
                                  isSecure: true,
                                  contentType: .password,
                                  keyboard: .default)
                            .focused($focus, equals: .password)
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
                            title: "Sign In",
                            isLoading: isLoading,
                            isEnabled: !email.isEmpty && !password.isEmpty
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

                    // MARK: Sign-Up link
                    HStack(spacing: 4) {
                        Text("New here?")
                            .foregroundStyle(.white.opacity(0.6))
                        Button("Create an Account") { isShowingSignUp = true }
                            .foregroundStyle(.orange)
                            .fontWeight(.semibold)
                    }
                    .font(.subheadline)

                    Spacer(minLength: 40)
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $isShowingSignUp) {
            SignUpView()
        }
    }

    private var isLoading: Bool {
        if case .authenticating = authViewModel.state { return true }
        return false
    }

    private func submit() async {
        focus = nil
        await authViewModel.signIn(email: email, password: password)
    }
}
