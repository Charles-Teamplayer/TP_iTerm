import SwiftUI

struct BudgetSettingsView: View {
    @StateObject private var store = AgentBudgetStore()
    @State private var draftWeights: [String: Int] = [:]
    @State private var draftSlots: [String: Int] = [:]
    @State private var draftMode: BudgetMode = .soft
    @State private var modeTab: ModeTab = .easy
    @State private var preset: Preset = .balanced
    @State private var showManual: Bool = false

    private let categories = AgentBudget.categories

    enum ModeTab: String, CaseIterable {
        case easy = "Easy"
        case pro = "Pro"
    }

    enum Preset: String, CaseIterable, Identifiable {
        case devHeavy = "개발 위주"
        case balanced = "균형"
        case designHeavy = "디자인 위주"
        case docsHeavy = "문서 위주"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $modeTab) {
                    ForEach(ModeTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
                Spacer()
                Button {
                    showManual = true
                } label: {
                    Label("매뉴얼", systemImage: "questionmark.circle")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
            }
            .padding()

            Divider()

            if modeTab == .easy {
                easyTab
            } else {
                proTab
            }
        }
        .frame(minWidth: 540, minHeight: 600)
        .onAppear { loadDraft() }
        .sheet(isPresented: $showManual) {
            BudgetManualView { showManual = false }
        }
    }

    // MARK: - Easy Tab

    private var easyTab: some View {
        Form {
            Section(header: Text("작업 분배 — 누가 더 많이?")) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Claude Code", systemImage: "person.crop.circle.badge.checkmark")
                            .foregroundStyle(.blue)
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text("\(globalClaude)%")
                            .font(.system(.body, design: .monospaced).bold())
                            .foregroundStyle(.blue)
                        Text("vs")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(100 - globalClaude)%")
                            .font(.system(.body, design: .monospaced).bold())
                            .foregroundStyle(.purple)
                        Label("Codex", systemImage: "cpu")
                            .foregroundStyle(.purple)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    Slider(value: Binding(
                        get: { Double(globalClaude) },
                        set: { applyGlobalClaude(Int($0)) }
                    ), in: 0...100, step: 5)
                    Text("왼쪽으로 갈수록 Claude Code가 직접 처리, 오른쪽으로 갈수록 Codex 위임 비율 증가.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
            }

            Section(header: Text("프리셋")) {
                Picker("스타일", selection: $preset) {
                    ForEach(Preset.allCases) { p in
                        Text(p.rawValue).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: preset) { _, new in applyPreset(new) }
                Text("선택한 프리셋이 카테고리 비중을 자동 조정합니다 (Pro 탭에서 미세 조정 가능).")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section(header: Text("엄격도")) {
                Picker("Mode", selection: $draftMode) {
                    Text("가이드 (권고만)").tag(BudgetMode.soft)
                    Text("강제 (한도 초과 시 거부)").tag(BudgetMode.hard)
                }
                .pickerStyle(.radioGroup)
                Text(draftMode == .soft
                    ? "가이드: 분배 비율을 system prompt에 알려만 줌. Claude가 무시할 수 있음."
                    : "강제: TeamCreate 시 카테고리 slot 검사. 0이면 spawn 거부 (Pro 탭의 Daily Slot 적용)."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("기본값으로") {
                        let d = AgentBudget.defaultBudget
                        draftWeights = d.weights
                        draftSlots = d.slotsToday
                        draftMode = d.mode
                    }
                    Spacer()
                    Button("저장") { saveAll() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isDirty)
                }
            }

            Section(header: Text("상태")) {
                Text("Last update: \(store.budget.updated.formatted(date: .abbreviated, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Pro Tab

    private var proTab: some View {
        Form {
            Section(header: Text("Mode (엄격도)")) {
                Picker("Enforcement", selection: $draftMode) {
                    Text("Soft 가이드").tag(BudgetMode.soft)
                    Text("Hard 강제").tag(BudgetMode.hard)
                }
                .pickerStyle(.segmented)
                Group {
                    if draftMode == .soft {
                        Text("Soft = SessionStart hook이 system prompt에 budget 정보를 주입. Claude가 자율적으로 따르거나 무시.")
                    } else {
                        Text("Hard = TeamCreate wrapper가 카테고리 slot 검사. 0이면 spawn 거부. Daily Slot 값 직접 영향.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section(header: HStack {
                Text("카테고리별 Claude/Codex 분배")
                Spacer()
                Text("좌=Claude / 우=Codex")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }) {
                ForEach(categories, id: \.self) { cat in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(displayCategory(cat))
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: 100, alignment: .leading)
                            Text("\(draftWeights[cat] ?? 0)%")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.blue)
                                .frame(width: 40, alignment: .trailing)
                            Slider(value: Binding(
                                get: { Double(draftWeights[cat] ?? 0) },
                                set: { draftWeights[cat] = Int($0) }
                            ), in: 0...100, step: 5)
                            Text("\(100 - (draftWeights[cat] ?? 0))%")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.purple)
                                .frame(width: 40, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Section(header: HStack {
                Text("Daily Slots")
                Spacer()
                Text("Hard 모드 전용")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }) {
                Text("하루 동안 그 카테고리로 spawn 가능한 sub-agent 개수. Hard 모드에서 0이면 spawn 거부. Soft 모드에서는 무시.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(categories, id: \.self) { cat in
                    HStack {
                        Text(displayCategory(cat))
                            .frame(width: 100, alignment: .leading)
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
                    Button("기본값으로") {
                        let d = AgentBudget.defaultBudget
                        draftWeights = d.weights
                        draftSlots = d.slotsToday
                        draftMode = d.mode
                    }
                    Spacer()
                    Button("저장") { saveAll() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isDirty)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Helpers

    private var globalClaude: Int {
        let vals = categories.compactMap { draftWeights[$0] }
        guard !vals.isEmpty else { return 50 }
        return vals.reduce(0, +) / vals.count
    }

    private func applyGlobalClaude(_ pct: Int) {
        for cat in categories { draftWeights[cat] = pct }
    }

    private func applyPreset(_ p: Preset) {
        // 프리셋 = 카테고리 슬롯 (활성 카테고리)
        switch p {
        case .devHeavy:
            draftSlots = ["dev": 8, "qa": 4, "design": 1, "docs": 1, "planning": 1]
        case .balanced:
            draftSlots = ["dev": 4, "design": 3, "qa": 3, "docs": 2, "planning": 2]
        case .designHeavy:
            draftSlots = ["design": 8, "dev": 3, "qa": 2, "docs": 2, "planning": 1]
        case .docsHeavy:
            draftSlots = ["docs": 6, "planning": 4, "dev": 2, "qa": 2, "design": 1]
        }
    }

    private func displayCategory(_ cat: String) -> String {
        switch cat {
        case "dev": return "개발"
        case "design": return "디자인"
        case "qa": return "QA"
        case "docs": return "문서"
        case "planning": return "기획"
        default: return cat
        }
    }

    private var isDirty: Bool {
        draftWeights != store.budget.weights ||
        draftSlots != store.budget.slotsToday ||
        draftMode != store.budget.mode
    }

    private func saveAll() {
        store.update(weights: draftWeights, slots: draftSlots, mode: draftMode)
    }

    private func loadDraft() {
        var w = store.budget.weights
        var s = store.budget.slotsToday
        for cat in categories {
            if w[cat] == nil { w[cat] = 50 }
            if s[cat] == nil { s[cat] = 0 }
        }
        draftWeights = w
        draftSlots = s
        draftMode = store.budget.mode
    }
}

// MARK: - 매뉴얼 (도움말)

private struct BudgetManualView: View {
    let onClose: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Agent Budget 매뉴얼").font(.title2).bold()
                Spacer()
                Button("닫기") { onClose() }
            }
            .padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    section("Agent Budget이란?",
                        "Claude Code(클코)와 Codex 사이의 작업 분배를 TP_iTerm_Restore가 거꾸로 결정하는 시스템. " +
                        "슬라이더 값이 ~/.claude/agent-budget.json에 저장되고, SessionStart hook이 system prompt에 주입 + CLAUDE.md 마커 영역 자동 갱신.")
                    section("Easy 탭",
                        "• 큰 슬라이더 한 개로 전체 Claude vs Codex 비율 설정 (왼쪽=Claude, 오른쪽=Codex).\n" +
                        "• 프리셋: 자주 쓰는 분배 패턴 (개발 위주 / 균형 / 디자인 위주 / 문서 위주).\n" +
                        "• 엄격도: 가이드 vs 강제.")
                    section("Pro 탭",
                        "• 카테고리(개발/디자인/QA/문서/기획)별 Claude:Codex 비율 미세 조정.\n" +
                        "• Daily Slot: Hard 모드 전용 — 각 카테고리당 하루 spawn 가능 횟수.\n" +
                        "• Mode: Soft (가이드) / Hard (강제) segmented picker.")
                    section("슬라이더 읽는 법",
                        "• 슬라이더 값 = 그 카테고리에서 Claude가 직접 처리할 비율.\n" +
                        "• 예: 개발 70% → 개발 작업 70%는 Claude / 30%는 Codex.\n" +
                        "• 좌측 파란색 = Claude / 우측 보라색 = Codex.")
                    section("Soft vs Hard",
                        "• Soft (가이드): SessionStart hook이 system prompt에 'budget 비율 따라 분배' 메시지 주입. Claude가 자율 판단. 무시 가능.\n" +
                        "• Hard (강제): TeamCreate/Agent spawn 직전 budget 검사. 카테고리 slot 0이면 spawn 거부. CLAUDE.md 마커 영역에도 'Hard' 표기.")
                    section("Daily Slot 의미",
                        "• 하루 동안 그 카테고리로 sub-agent를 몇 번 spawn 가능한지 한도.\n" +
                        "• 예: dev=5 → 오늘 개발 sub-agent 5번까지 OK, 6번째부터 Hard 모드면 거부.\n" +
                        "• Soft 모드면 무시 (참고용 표시만).")
                    section("프리셋 의미",
                        "• 개발 위주: dev/qa 슬롯 강화 — 코딩 위주 작업 일일.\n" +
                        "• 균형: 모든 카테고리 비슷하게 — 다목적.\n" +
                        "• 디자인 위주: design 슬롯 강화 — UI/UX 작업.\n" +
                        "• 문서 위주: docs/planning 강화 — 스펙/리포트 작업.")
                    section("저장 후 흐름",
                        "1. 저장 클릭 → ~/.claude/agent-budget.json 갱신.\n" +
                        "2. 500ms 후 ~/.claude/CLAUDE.md 의 <!-- AGENT_BUDGET_START --> 마커 영역 자동 rewrite.\n" +
                        "3. 다음 Claude 세션 시작 시 SessionStart hook이 budget을 system message로 주입.\n" +
                        "4. Hard 모드면 sub-agent spawn 시 slot 차감 (TeamCreate wrapper 적용 필요 — v2).")
                    section("실전 팁",
                        "• 처음엔 Easy 탭 + 균형 프리셋 + Soft로 시작.\n" +
                        "• 작업 패턴 익숙해지면 Pro 탭에서 카테고리 미세 조정.\n" +
                        "• Codex가 막히는 작업 (정책/문서) 비율은 Claude 높임.\n" +
                        "• 코드 양산 작업 (테스트/리팩토링) 비율은 Codex 높임.")
                }
                .padding()
            }
        }
        .frame(minWidth: 560, minHeight: 640)
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(body)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
