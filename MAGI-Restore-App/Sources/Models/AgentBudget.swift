import Foundation

struct AgentBudget: Codable, Equatable {
    var weights: [String: Int]       // 카테고리 → 0-100% (총합 100 권장, 강제 X)
    var slotsToday: [String: Int]    // 카테고리 → 일일 잔여 slot
    var mode: BudgetMode
    var updated: Date

    static let defaultBudget = AgentBudget(
        weights: ["dev": 50, "design": 25, "qa": 15, "docs": 10],
        slotsToday: ["dev": 5, "design": 3, "qa": 2, "docs": 2],
        mode: .soft,
        updated: Date()
    )

    static let categories = ["dev", "design", "qa", "docs", "planning"]
}

enum BudgetMode: String, Codable, CaseIterable {
    case soft = "Soft (가이드)"
    case hard = "Hard (강제)"
}

@MainActor
final class AgentBudgetStore: ObservableObject {
    @Published var budget: AgentBudget
    private let path = NSHomeDirectory() + "/.claude/agent-budget.json"

    init() {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let decoded = try? JSONDecoder().decode(AgentBudget.self, from: data) {
            self.budget = decoded
        } else {
            self.budget = AgentBudget.defaultBudget
        }
    }

    func save() {
        var b = budget
        b.updated = Date()
        budget = b
        guard let data = try? JSONEncoder().encode(b) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    func update(weights: [String: Int]? = nil, slots: [String: Int]? = nil, mode: BudgetMode? = nil) {
        if let w = weights { budget.weights = w }
        if let s = slots { budget.slotsToday = s }
        if let m = mode { budget.mode = m }
        save()
    }
}
