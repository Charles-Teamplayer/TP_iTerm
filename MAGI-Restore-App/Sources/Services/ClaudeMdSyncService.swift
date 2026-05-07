import Foundation
import Combine

@MainActor
final class ClaudeMdSyncService: ObservableObject {
    static let shared = ClaudeMdSyncService()
    private let claudeMdPath = NSHomeDirectory() + "/.claude/CLAUDE.md"
    private let budgetPath = NSHomeDirectory() + "/.claude/agent-budget.json"
    private static let startMarker = "<!-- AGENT_BUDGET_START -->"
    private static let endMarker = "<!-- AGENT_BUDGET_END -->"

    private var debounceTask: Task<Void, Never>?
    private var bag: Set<AnyCancellable> = []

    private init() {}

    /// AgentBudgetStore를 관찰하여 변경 시 자동 sync
    func bind(store: AgentBudgetStore) {
        store.$budget
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.scheduleSync()
            }
            .store(in: &bag)
    }

    private func scheduleSync() {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if !Task.isCancelled {
                await syncNow()
            }
        }
    }

    func syncNow() async {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: budgetPath)),
              let budget = try? JSONDecoder().decode(AgentBudget.self, from: data)
        else { return }

        let block = renderBlock(budget: budget)
        guard let existing = try? String(contentsOfFile: claudeMdPath, encoding: .utf8) else {
            // CLAUDE.md 없으면 새로 만들지 않음 (안전)
            return
        }

        let updated: String
        if let startRange = existing.range(of: Self.startMarker),
           let endRange = existing.range(of: Self.endMarker),
           startRange.lowerBound < endRange.upperBound {
            // 기존 마커 영역 교체
            let prefix = existing[..<startRange.lowerBound]
            let suffix = existing[endRange.upperBound...]
            updated = String(prefix) + block + String(suffix)
        } else {
            // 마커 없음 — 파일 끝에 추가
            let separator = existing.hasSuffix("\n") ? "\n" : "\n\n"
            updated = existing + separator + block + "\n"
        }

        if updated != existing {
            try? updated.write(toFile: claudeMdPath, atomically: true, encoding: .utf8)
        }
    }

    private func renderBlock(budget: AgentBudget) -> String {
        var lines: [String] = []
        lines.append(Self.startMarker)
        lines.append("")
        lines.append("# Agent Budget (TP_iTerm_Restore Settings)")
        lines.append("")
        lines.append("> 이 영역은 TP_iTerm_Restore.app의 Budget Settings로 자동 갱신됨. 수동 편집 금지.")
        lines.append("")
        lines.append("**Mode**: \(budget.mode.rawValue)")
        lines.append("")
        let nonZeroWeights = budget.weights.filter { $0.value > 0 }.sorted { $0.key < $1.key }
        if !nonZeroWeights.isEmpty {
            lines.append("**Category Weights**:")
            for (k, v) in nonZeroWeights {
                lines.append("- `\(k)`: \(v)%")
            }
            lines.append("")
        }
        let nonZeroSlots = budget.slotsToday.filter { $0.value > 0 }.sorted { $0.key < $1.key }
        if !nonZeroSlots.isEmpty {
            lines.append("**Daily Slots**:")
            for (k, v) in nonZeroSlots {
                lines.append("- `\(k)`: \(v)")
            }
            lines.append("")
        }
        if budget.mode == .hard {
            lines.append("**Enforcement**: Hard — 위 weight/slot 따라 작업 분배. 카테고리 slot 0이면 spawn 거부.")
        } else {
            lines.append("**Enforcement**: Soft — 가이드. 가능하면 위 비율로 분배.")
        }
        lines.append("")
        let fmt = ISO8601DateFormatter()
        lines.append("> Last sync: \(fmt.string(from: budget.updated))")
        lines.append("")
        lines.append(Self.endMarker)
        return lines.joined(separator: "\n")
    }
}
