// HoopTrack/Views/Auth/AuthComponents.swift
// Shared building blocks for the auth views. Orange-on-dark glass aesthetic
// that matches the sidebar redesign and onboarding flow.

import SwiftUI

// MARK: - Background

struct AuthBackground: View {
    var body: some View {
        ZStack {
            // Base gradient — warm on top, dark at the bottom, no pure black.
            LinearGradient(
                colors: [
                    Color(red: 0.10, green: 0.08, blue: 0.15),
                    Color(red: 0.06, green: 0.05, blue: 0.10),
                    Color(red: 0.04, green: 0.04, blue: 0.07),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // Soft orange glow behind the hero.
            RadialGradient(
                colors: [Color.orange.opacity(0.28), .clear],
                center: .init(x: 0.5, y: 0.20),
                startRadius: 0,
                endRadius: 280
            )
            .blur(radius: 40)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Text field

struct AuthField: View {
    let icon: String
    let placeholder: String
    @Binding var text: String
    let isSecure: Bool
    let contentType: UITextContentType
    let keyboard: UIKeyboardType

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 22)

            if isSecure {
                SecureField("", text: $text, prompt: prompt)
                    .textContentType(contentType)
                    .submitLabel(.go)
            } else {
                TextField("", text: $text, prompt: prompt)
                    .textContentType(contentType)
                    .keyboardType(keyboard)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
            }
        }
        .foregroundStyle(.white)
        .tint(.orange)
        .padding(.vertical, 14)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private var prompt: Text {
        Text(placeholder).foregroundStyle(.white.opacity(0.4))
    }
}

// MARK: - Primary button

struct AuthPrimaryButton: View {
    let title: String
    let isLoading: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if isLoading {
                    ProgressView().tint(.white)
                } else {
                    Text(title)
                        .font(.system(size: 15, weight: .heavy))
                        .tracking(0.5)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: isEnabled
                                ? [Color(red: 1.0, green: 0.58, blue: 0.0),
                                   Color(red: 1.0, green: 0.40, blue: 0.0)]
                                : [Color.white.opacity(0.10), Color.white.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: isEnabled ? Color.orange.opacity(0.35) : .clear,
                             radius: 12, y: 4)
            )
        }
        .disabled(!isEnabled || isLoading)
        .animation(.easeInOut(duration: 0.15), value: isEnabled)
        .animation(.easeInOut(duration: 0.15), value: isLoading)
    }
}
