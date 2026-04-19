// GameEntryCard.swift
// Top-of-Train-tab promotional card for Game Mode. Kept as its own file so
// its layout can evolve without touching the drill grid below it.

import SwiftUI

struct GameEntryCard: View {
    let onStart: (GameFormat, GameType) -> Void
    @State private var showSheet = false
    @State private var selectedFormat: GameFormat = .twoOnTwo

    var body: some View {
        Button {
            showSheet = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(.orange, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pickup Game").font(.headline)
                    Text("2v2 or 3v3 with live scoring")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showSheet) {
            NavigationStack {
                Form {
                    Section("Format") {
                        Picker("", selection: $selectedFormat) {
                            ForEach(GameFormat.allCases) { f in
                                Text(f.displayName).tag(f)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                .navigationTitle("Start pickup game")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showSheet = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Continue") {
                            showSheet = false
                            onStart(selectedFormat, .pickup)
                        }.bold()
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }
}
