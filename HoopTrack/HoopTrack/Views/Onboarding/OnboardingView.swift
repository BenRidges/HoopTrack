// OnboardingView.swift
// 5-screen first-launch flow combining feature showcase with permission requests.
// Gated by @AppStorage("hasCompletedOnboarding") — shown only once.
// All page subviews are private to this file.

import SwiftUI
import AVFoundation
import UserNotifications

struct OnboardingView: View {
    @Binding var hasCompletedOnboarding: Bool
    @State private var currentPage = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $currentPage) {
                WelcomePage(currentPage: $currentPage)
                    .tag(0)
                CameraPage(currentPage: $currentPage)
                    .tag(1)
                NotificationsPage(currentPage: $currentPage)
                    .tag(2)
                GoalsPage(currentPage: $currentPage)
                    .tag(3)
                ProfileSetupPage(isComplete: $hasCompletedOnboarding)
                    .tag(4)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            HStack(spacing: 8) {
                ForEach(0..<5) { index in
                    Circle()
                        .fill(currentPage == index ? Color.orange : Color.white.opacity(0.3))
                        .frame(width: 8, height: 8)
                        .animation(.easeInOut(duration: 0.2), value: currentPage)
                }
            }
            .padding(.bottom, 16)
        }
        .background(Color(.systemBackground))
    }
}

// MARK: - Page 1: Welcome

private struct WelcomePage: View {
    @Binding var currentPage: Int

    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            VStack(spacing: 16) {
                Image(systemName: "basketball.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(.orange)
                Text("HoopTrack")
                    .font(.system(size: 42, weight: .black, design: .rounded))
                Text("Track every shot.\nOwn your game.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            Button {
                withAnimation { currentPage = 1 }
            } label: {
                Text("Get Started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.orange, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 48)
        }
        .padding(.horizontal, 24)
    }
}

// MARK: - Page 2: Camera + Shot Tracking

private struct CameraPage: View {
    @Binding var currentPage: Int
    @State private var permissionGranted = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            VStack(spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("FG%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("52%")
                            .font(.title2.bold())
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Shot auto-detected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: 0.52)
                    .tint(.orange)
            }
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 32)

            VStack(spacing: 12) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange)
                Text("Auto Shot Detection")
                    .font(.title2.bold())
                Text("Your camera tracks makes and misses automatically — no buttons needed during your session.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }

            Spacer()

            VStack(spacing: 12) {
                Button {
                    Task {
                        await AVCaptureDevice.requestAccess(for: .video)
                        permissionGranted = true
                        withAnimation { currentPage = 2 }
                    }
                } label: {
                    Text("Allow Camera")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.orange, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .foregroundStyle(.white)
                }
                if !permissionGranted {
                    Button("Continue without camera") {
                        withAnimation { currentPage = 2 }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 48)
        }
        .padding(.horizontal, 24)
    }
}

// MARK: - Page 3: Notifications + Badges

private struct NotificationsPage: View {
    @Binding var currentPage: Int

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            VStack(spacing: 10) {
                Text("🏅 Badge Earned!")
                    .font(.subheadline.bold())
                    .foregroundStyle(.orange)
                HStack(spacing: 8) {
                    Text("Deadeye · Gold I")
                        .font(.caption.bold())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.orange.opacity(0.2), in: Capsule())
                        .overlay(Capsule().stroke(Color.orange, lineWidth: 1))
                        .foregroundStyle(.orange)
                }
                Text("+120 MMR")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 32)

            VStack(spacing: 12) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange)
                Text("Badge Milestones")
                    .font(.title2.bold())
                Text("Get notified when you earn badges and hit milestones. You can turn this off anytime in Settings.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }

            Spacer()

            VStack(spacing: 12) {
                Button {
                    Task {
                        _ = try? await UNUserNotificationCenter.current()
                            .requestAuthorization(options: [.alert, .badge, .sound])
                        withAnimation { currentPage = 3 }
                    }
                } label: {
                    Text("Allow Notifications")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.orange, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .foregroundStyle(.white)
                }
                Button("Skip for now") {
                    withAnimation { currentPage = 3 }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 48)
        }
        .padding(.horizontal, 24)
    }
}

// MARK: - Page 4: Goals Showcase

private struct GoalsPage: View {
    @Binding var currentPage: Int

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            VStack(alignment: .leading, spacing: 12) {
                Text("ACTIVE GOALS")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Shoot 50% FG")
                        .font(.subheadline.bold())
                    ProgressView(value: 0.68)
                        .tint(.orange)
                    Text("48% → 50%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 32)

            VStack(spacing: 12) {
                Image(systemName: "target")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange)
                Text("Set Your Goals")
                    .font(.title2.bold())
                Text("Track progress toward your shooting and fitness targets. Set your first goal right from the Progress tab.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }

            Spacer()

            Button {
                withAnimation { currentPage = 4 }
            } label: {
                Text("Continue →")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.orange, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 48)
        }
        .padding(.horizontal, 24)
    }
}

// MARK: - Page 5: Profile Setup

private struct ProfileSetupPage: View {
    @Binding var isComplete: Bool
    @State private var playerName: String = ""

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            VStack(spacing: 16) {
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.orange)
                Text("What's your name?")
                    .font(.title2.bold())
                Text("Used on your profile and career stats.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            TextField("Your name", text: $playerName)
                .font(.title3)
                .multilineTextAlignment(.center)
                .padding(.vertical, 14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 48)
            Spacer()
            Button {
                // Phase 7 — Security: sanitise name before persisting
                if let sanitised = InputValidator.sanitisedProfileName(playerName) {
                    UserDefaults.standard.set(sanitised, forKey: "onboardingPlayerName")
                }
                isComplete = true
            } label: {
                Text("Start Training 🏀")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.orange, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 48)
        }
        .padding(.horizontal, 24)
    }
}
