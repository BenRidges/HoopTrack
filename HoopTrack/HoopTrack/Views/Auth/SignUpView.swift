// HoopTrack/Views/Auth/SignUpView.swift
import SwiftUI

struct SignUpView: View {
    @EnvironmentObject var authViewModel: AuthViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var email    = ""
    @State private var password = ""
    @State private var confirm  = ""

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
                    SecureField("At least \(HoopTrack.Auth.minPasswordLength) characters",
                                text: $password)
                        .textContentType(.newPassword)
                    SecureField("Confirm", text: $confirm)
                        .textContentType(.newPassword)
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
                        Task {
                            await authViewModel.signUp(email: email,
                                                        password: password,
                                                        confirmPassword: confirm)
                        }
                    } label: {
                        Text("Create Account").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(email.isEmpty || password.isEmpty || confirm.isEmpty)
                }
            }
            .navigationTitle("Sign Up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onChange(of: authViewModel.state) { _, newState in
                if newState.user != nil { dismiss() }
            }
        }
    }
}
