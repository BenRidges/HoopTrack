// GoalListView.swift
// Full goal management list — replaces Phase 5 stub.
import SwiftUI

struct GoalListView: View {
    @StateObject var viewModel: GoalListViewModel

    var body: some View {
        List {
            // MARK: Active Goals
            if !viewModel.activeGoals.isEmpty {
                Section("Active") {
                    ForEach(viewModel.activeGoals) { goal in
                        GoalProgressRow(goal: goal)
                    }
                    .onDelete { indexSet in
                        indexSet.map { viewModel.activeGoals[$0] }.forEach { viewModel.delete($0) }
                    }
                }
            }

            // MARK: Achieved Goals (collapsible)
            if !viewModel.achievedGoals.isEmpty {
                Section {
                    DisclosureGroup(
                        "Achieved (\(viewModel.achievedGoals.count))",
                        isExpanded: $viewModel.showAchieved
                    ) {
                        ForEach(viewModel.achievedGoals) { goal in
                            AchievedGoalRow(goal: goal)
                        }
                    }
                }
            }

            // MARK: Empty State
            if viewModel.activeGoals.isEmpty && viewModel.achievedGoals.isEmpty {
                ContentUnavailableView(
                    "No Goals Yet",
                    systemImage: "target",
                    description: Text("Tap + to set your first goal.")
                )
            }
        }
        .navigationTitle("Goals")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    viewModel.showingAddGoal = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $viewModel.showingAddGoal) {
            AddGoalSheet(viewModel: viewModel)
        }
    }
}

// MARK: - AchievedGoalRow

private struct AchievedGoalRow: View {
    let goal: GoalRecord

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(goal.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let date = goal.achievedAt {
                    Text("Achieved \(date.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }
}
