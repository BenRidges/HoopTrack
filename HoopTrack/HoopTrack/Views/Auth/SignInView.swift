// HoopTrack/Views/Auth/SignInView.swift
import SwiftUI

struct SignInView: View {
    @EnvironmentObject var authViewModel: AuthViewModel

    @State private var email    = ""
    @State private var password = ""
    @State private var isShowingSignUp = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Email") {
                    TextField("you@example.com", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Password") {
                    SecureField("••••••••", text: $password)
                        .textContentType(.password)
                }
                if case .error(let err) = authViewModel.state {
                    Section {
                        Text(err.errorDescription ?? "")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
                Section {
                    Button {
                        Task { await authViewModel.signIn(email: email, password: password) }
                    } label: {
                        Text("Sign In").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(email.isEmpty || password.isEmpty)
                }
                Section {
                    Button("Create an Account") { isShowingSignUp = true }
                        .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("HoopTrack")
            .sheet(isPresented: $isShowingSignUp) {
                SignUpView()
            }
        }
    }
}
