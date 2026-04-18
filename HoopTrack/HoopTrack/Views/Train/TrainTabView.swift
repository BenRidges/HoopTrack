// TrainTabView.swift
// Drill picker — browse by category, then launch a live session.

import SwiftUI

struct TrainTabView: View {

    @EnvironmentObject private var hapticService: HapticService
    @StateObject private var viewModel = TrainViewModel()
    @State private var isShowingLiveSession = false
    @State private var drillToLaunch: NamedDrill? = nil
    @State private var isShowingPreSessionSheet = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {

                // MARK: Quick Start Banner
                quickStartBanner

                // MARK: Category Filter
                categoryFilter

                // MARK: Drill Grid
                drillGrid
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .navigationTitle("Train")
        .navigationBarTitleDisplayMode(.large)
        // Pre-session config sheet
        .sheet(isPresented: $isShowingPreSessionSheet) {
            PreSessionSheetView(drill: drillToLaunch, viewModel: viewModel) {
                isShowingPreSessionSheet = false
                // Determine if this is a shooting session (needs landscape)
                let needsLandscape = drillToLaunch == nil
                    || (drillToLaunch?.drillType != .dribble
                        && drillToLaunch?.drillType != .agility)
                if needsLandscape {
                    OrientationLock.allowLandscape = true
                }
                isShowingLiveSession = true
            }
        }
        // Full-screen live session — routes by drill type
        .fullScreenCover(isPresented: $isShowingLiveSession, onDismiss: {
            // Reset orientation to portrait when session ends
            OrientationLock.allowLandscape = false
            requestOrientationChange(to: .portrait)
        }) {
            if let drill = drillToLaunch, drill.drillType == .dribble {
                DribbleDrillView(namedDrill: drill) {
                    isShowingLiveSession = false
                    drillToLaunch        = nil
                }
            } else if let drill = drillToLaunch, drill.drillType == .agility {
                AgilitySessionView(namedDrill: drill) {
                    isShowingLiveSession = false
                    drillToLaunch        = nil
                }
            } else {
                LandscapeContainer {
                    LiveSessionView(
                        drillType: drillToLaunch?.drillType ?? .freeShoot,
                        namedDrill: drillToLaunch
                    ) {
                        isShowingLiveSession = false
                        drillToLaunch        = nil
                    }
                }
                .ignoresSafeArea()
                .onAppear {
                    requestOrientationChange(to: .landscapeRight)
                }
            }
        }
    }

    // MARK: - Orientation Helpers

    private func requestOrientationChange(to orientation: UIInterfaceOrientation) {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else { return }
        let mask: UIInterfaceOrientationMask = orientation.isLandscape ? .landscapeRight : .portrait
        windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
    }

    // MARK: - Quick Start

    private var quickStartBanner: some View {
        Button {
            hapticService.tap()
            drillToLaunch            = nil
            isShowingPreSessionSheet = true
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Free Shoot")
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                    Text("Open court — automatic shot tracking")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                }
                Spacer()
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.white)
            }
            .padding(20)
            .background(
                LinearGradient(colors: [.orange, .red], startPoint: .leading, endPoint: .trailing),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
        }
    }

    // MARK: - Category Filter

    private var categoryFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                // "All" chip
                FilterChip(
                    label: "All",
                    systemImage: "square.grid.2x2",
                    isSelected: viewModel.selectedDrillType == nil
                ) {
                    hapticService.tap()
                    viewModel.selectedDrillType = nil
                }

                ForEach(DrillType.allCases) { type in
                    FilterChip(
                        label: type.rawValue,
                        systemImage: type.systemImage,
                        isSelected: viewModel.selectedDrillType == type
                    ) {
                        hapticService.tap()
                        viewModel.selectedDrillType =
                            viewModel.selectedDrillType == type ? nil : type
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Drill Grid

    private var drillGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
            ForEach(viewModel.filteredDrills) { drill in
                DrillCard(drill: drill, description: viewModel.description(for: drill)) {
                    hapticService.tap()
                    drillToLaunch            = drill
                    isShowingPreSessionSheet = true
                }
            }
        }
    }
}

// MARK: - FilterChip
private struct FilterChip: View {
    let label: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    isSelected
                        ? AnyShapeStyle(Color.orange)
                        : AnyShapeStyle(.ultraThinMaterial),
                    in: Capsule()
                )
                .foregroundStyle(isSelected ? .white : .primary)
        }
    }
}

// MARK: - DrillCard
private struct DrillCard: View {
    let drill: NamedDrill
    let description: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: drill.drillType.systemImage)
                    .font(.title2)
                    .foregroundStyle(.orange)

                Text(drill.rawValue)
                    .font(.subheadline.bold())
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 0)

                Text(drill.drillType.rawValue)
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.orange.opacity(0.12), in: Capsule())
                    .foregroundStyle(.orange)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(14)
            .background(.ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Pre-Session Config Sheet
struct PreSessionSheetView: View {
    let drill: NamedDrill?
    @ObservedObject var viewModel: TrainViewModel
    let onLaunch: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Session Setup") {
                    if let drill {
                        LabeledContent("Drill", value: drill.rawValue)
                    } else {
                        LabeledContent("Mode", value: "Free Shoot")
                    }

                    Picker("Court Type", selection: $viewModel.selectedCourtType) {
                        ForEach(CourtType.allCases) { ct in
                            Text(ct.rawValue).tag(ct)
                        }
                    }

                    TextField("Location (optional)", text: $viewModel.locationTag)
                }

                Section {
                    Button("Start Session") {
                        onLaunch()
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .foregroundStyle(.orange)
                    .bold()
                }
            }
            .navigationTitle("Session Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
