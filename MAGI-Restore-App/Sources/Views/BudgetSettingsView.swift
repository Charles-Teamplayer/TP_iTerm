import SwiftUI

struct BudgetSettingsView: View {
    @StateObject private var store = AgentBudgetStore()
    @State private var draftWeights: [String: Int] = [:]
    @State private var draftSlots: [String: Int] = [:]
    @State private var draftMode: BudgetMode = .soft

    private let categories = AgentBudget.categories

    var body: some View {
        Form {
            Section(header: Text("Mode")) {
                Picker("Enforcement", selection: $draftMode) {
                    ForEach(BudgetMode.allCases, id: \.self) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section(header: HStack {
                Text("Category Weights (총 \(weightsSum)%)")
                Spacer()
                if weightsSum != 100 {
                    Text("⚠️ 100 권장")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }) {
                ForEach(categories, id: \.self) { cat in
                    HStack {
                        Text(cat).frame(width: 80, alignment: .leading)
                        Slider(value: Binding(
                            get: { Double(draftWeights[cat] ?? 0) },
                            set: { draftWeights[cat] = Int($0) }
                        ), in: 0...100, step: 5)
                        Text("\(draftWeights[cat] ?? 0)%")
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }

            Section(header: Text("Daily Slots")) {
                ForEach(categories, id: \.self) { cat in
                    HStack {
                        Text(cat).frame(width: 80, alignment: .leading)
                        Stepper(value: Binding(
                            get: { draftSlots[cat] ?? 0 },
                            set: { draftSlots[cat] = $0 }
                        ), in: 0...50) {
                            Text("\(draftSlots[cat] ?? 0)")
                                .font(.system(.body, design: .monospaced))
                                .frame(width: 30, alignment: .trailing)
                        }
                    }
                }
            }

            Section {
                HStack {
                    Button("Reset to Default") {
                        let d = AgentBudget.defaultBudget
                        draftWeights = d.weights
                        draftSlots = d.slotsToday
                        draftMode = d.mode
                    }
                    Spacer()
                    Button("Save") {
                        store.update(weights: draftWeights, slots: draftSlots, mode: draftMode)
                        // CLAUDE.md sync는 S4 Service가 처리 (변경 감시)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isDirty)
                }
            }

            Section(header: Text("Status")) {
                Text("Last updated: \(store.budget.updated.formatted(date: .abbreviated, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { loadDraft() }
    }

    private var weightsSum: Int { draftWeights.values.reduce(0, +) }

    private var isDirty: Bool {
        draftWeights != store.budget.weights ||
            draftSlots != store.budget.slotsToday ||
            draftMode != store.budget.mode
    }

    private func loadDraft() {
        // 누락 카테고리는 0으로 채움
        var w = store.budget.weights
        var s = store.budget.slotsToday
        for cat in categories {
            if w[cat] == nil { w[cat] = 0 }
            if s[cat] == nil { s[cat] = 0 }
        }
        draftWeights = w
        draftSlots = s
        draftMode = store.budget.mode
    }
}
