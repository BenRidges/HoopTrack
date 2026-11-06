// LockedView.swift
// Shown over everything while AppLock is engaged.

import SwiftUI

struct LockedView: View {
    @EnvironmentObject private var appLock: AppLock
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "lock.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Color.leather)
            Text("HoopTrack is locked")
                .font(.title2.bold())
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(Color.miss)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            Button("Unlock") { Task { await unlock() } }
                .buttonStyle(.primary)
        }
        .padding(Metrics.screenPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.court.ignoresSafeArea())
        .task { await unlock() }
    }

    private func unlock() async {
        errorMessage = await appLock.unlock()
    }
}
