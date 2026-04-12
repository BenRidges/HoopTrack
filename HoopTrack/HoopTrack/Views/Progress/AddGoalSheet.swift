// AddGoalSheet.swift
// Form for creating a new GoalRecord.
import SwiftUI

struct AddGoalSheet: View {

    @ObservedObject var viewModel: GoalListViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var title:          String         = ""
    @State private var selectedSkill:  SkillDimension = .shooting
    @State private var selectedMetric: GoalMetric     = SkillDimension.shooting.suggestedMetrics.first ?? .fgPercent
    @State private var targetText:     String         = ""
    @State private var baselineText:   String         = ""
    @State private var hasTargetDate:  Bool           = false
    @State private var targetDate:     Date           = Calendar.current.date(byAdding: .month, value: 1, to: .now) ?? .now
    @State private var validationError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Goal Details") {
                    TextField("Title (e.g. Shoot 50% FG)", text: $title)

                    Picker("Skill", selection: $selectedSkill) {
                        ForEach(SkillDimension.allCases) { dim in
                            Text(dim.rawValue).tag(dim)
                        }
                    }
                    .onChange(of: selectedSkill) { _, newSkill in
                        selectedMetric = newSkill.suggestedMetrics.first ?? .fgPercent
                        prefillBaseline()
                    }

                    Picker("Metric", selection: $selectedMetric) {
                        ForEach(selectedSkill.suggestedMetrics) { metric in
                            Text(metric.rawValue).tag(metric)
                        }
                    }
                    .onChange(of: selectedMetric) { _, _ in prefillBaseline() }
                }

                Section("Values (\(selectedMetric.unit))") {
                    TextField("Target", text: $targetText)
                        .keyboardType(.decimalPad)
                    TextField("Baseline (current)", text: $baselineText)
                        .keyboardType(.decimalPad)
                }

                Section("Target Date (optional)") {
                    Toggle("Set a deadline", isOn: $hasTargetDate)
                        .tint(.orange)
                    if hasTargetDate {
                        DatePicker("Deadline",
                                   selection: $targetDate,
                                   in: Date.now...,
                                   displayedComponents: .date)
                    }
                }

                if let error = validationError {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }

                Section {
                    Button("Save Goal") { save() }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .bold()
                        .foregroundStyle(.orange)
                        .disabled(!isValid)
                }
            }
            .navigationTitle("New Goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .onAppear { prefillBaseline() }
    }

    // MARK: - Validation

    private var isValid: Bool {
        !title.isEmpty &&
        (Double(targetText) ?? 0) > 0
    }

    // MARK: - Actions

    private func prefillBaseline() {
        let current = viewModel.currentValue(for: selectedMetric)
        if current > 0 {
            baselineText = String(format: "%.1f", current)
        }
    }

    private func save() {
        guard let target = Double(targetText), target > 0 else {
            validationError = "Target must be a positive number."
            return
        }
        let baseline = Double(baselineText) ?? 0
        viewModel.add(
            title:      title,
            skill:      selectedSkill,
            metric:     selectedMetric,
            target:     target,
            baseline:   baseline,
            targetDate: hasTargetDate ? targetDate : nil
        )
        dismiss()
    }
}
