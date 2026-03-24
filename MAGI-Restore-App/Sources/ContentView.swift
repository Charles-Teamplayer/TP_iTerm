import SwiftUI
import AppKit


struct ContentView: View {
    @StateObject private var monitor = SessionMonitor()
    @State private var selectedTab: Tab = .sessions
    @State private var selectedSession: ClaudeSession?
    @State private var profileSelection: UUID? = nil
    @State private var showNewSession = false
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    @FocusState private var profileSearchFocused: Bool

    // 창 관리
    @State private var showAddPane = false
    @State private var renamingPane: WindowPane? = nil
    @State private var importingToPane: WindowPane? = nil
    @State private var paneToDelete: WindowPane? = nil
    @State private var showDeletePaneConfirm = false

    // 탭 번호 인라인 편집
    @State private var editingTabKey: String? = nil   // "paneId|profileName"
    @State private var tabNumberInput: String = ""

    // 드래그 앤 드롭 (DragGesture + GeometryReader 방식)
    @State private var rowFrames: [String: CGRect] = [:]   // hoverKey → globalFrame
    @State private var paneFrames: [UUID: CGRect] = [:]    // paneId → globalFrame
    @State private var dragHighlightRow: String? = nil
    @State private var dragHighlightPane: UUID? = nil

    enum Tab: String, CaseIterable {
        case sessions = "세션"
        case profiles = "프로필"
        case backup = "백업"
        case system = "시스템"
        var icon: String {
            switch self {
            case .sessions: "terminal"
            case .profiles: "rectangle.3.group"
            case .backup: "externaldrive"
            case .system: "gearshape"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // ── 탭 사이드바 (80px) ──
            tabSidebar

            Divider()

            if selectedTab == .sessions {
                // ── 세션 목록 (260px) ──
                sessionListPanel
                    .frame(width: 260)

                Divider()

                // ── 세션 상세 (나머지) ──
                sessionDetailPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                otherTabContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 700, minHeight: 450)
        .onAppear {
            NotificationService.shared.requestPermission()
            monitor.start()
            monitor.profileService.load()
            monitor.windowGroupService.load()
            monitor.syncWindowGroupsWithProfiles()
            // 대시보드 열릴 때 Cmd+Tab + Dock에 나타나도록 정책 전환
            NSApp.setActivationPolicy(.regular)
            DispatchQueue.main.async {
                if let window = NSApp.windows.first(where: { $0.canBecomeKey }) {
                    window.hidesOnDeactivate = false
                    window.collectionBehavior = [.managed, .participatesInCycle, .moveToActiveSpace]
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
        .onChange(of: monitor.sessions) { _, sessions in
            if let current = selectedSession {
                selectedSession = sessions.first { $0.id == current.id }
            }
        }
        .onDisappear {
            monitor.stop()
            // 대시보드 닫히면 메뉴바 전용으로 복귀 (Dock/Cmd+Tab에서 숨김)
            NSApp.setActivationPolicy(.accessory)
        }
        .sheet(isPresented: $showAddPane) {
            AddPaneSheet { name in monitor.windowGroupService.addGroup(name: name) }
        }
        .sheet(item: $renamingPane) { pane in
            RenamePaneSheet(pane: pane) { newName, newSession in
                monitor.windowGroupService.updateGroup(pane, name: newName, sessionName: newSession)
            }
        }
        .sheet(item: $importingToPane) { pane in
            ImportToPaneSheet(pane: pane, monitor: monitor)
        }
        .confirmationDialog(
            "'\(paneToDelete?.name ?? "")' 창을 삭제하시겠습니까?\n세션은 첫 번째 창으로 이동합니다.",
            isPresented: $showDeletePaneConfirm, titleVisibility: .visible
        ) {
            Button("삭제", role: .destructive) {
                if let p = paneToDelete { monitor.windowGroupService.deleteGroup(p) }
            }
            Button("취소", role: .cancel) {}
        }
        .background {
            Group {
                Button("") {
                    selectedTab = .sessions
                    let ps = monitor.sessions.filter { $0.profileRoot != nil }
                    if selectedSession == nil { selectedSession = ps.first }
                }.keyboardShortcut("1", modifiers: .command)
                Button("") {
                    selectedTab = .profiles
                    if profileSelection == nil { profileSelection = monitor.profileService.profiles.first?.id }
                }.keyboardShortcut("2", modifiers: .command)
                Button("") { selectedTab = .backup  }.keyboardShortcut("3", modifiers: .command)
                Button("") { selectedTab = .system  }.keyboardShortcut("4", modifiers: .command)
                Button("") {
                    switch selectedTab {
                    case .sessions: searchFocused = true
                    case .profiles: profileSearchFocused = true
                    default: break
                    }
                }.keyboardShortcut("f", modifiers: .command)
            }
            .opacity(0)
        }
        .sheet(isPresented: $showNewSession) {
            NewSessionSheet(monitor: monitor, isPresented: $showNewSession)
        }
    }

    // MARK: - Tab Sidebar

    private var tabSidebar: some View {
        VStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.rawValue) { tab in
                Button {
                    selectedTab = tab
                    if tab != .sessions { selectedSession = nil }
                } label: {
                    VStack(spacing: 4) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 18))
                            if tab == .sessions {
                                let running = monitor.sessions.filter { $0.isRunning && $0.profileRoot != nil }.count
                                if running > 0 {
                                    Text("\(running)")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 4)
                                        .background(Color.green, in: Capsule())
                                        .offset(x: 10, y: -6)
                                }
                            } else if tab == .profiles {
                                let count = monitor.profileService.profiles.count
                                if count > 0 {
                                    Text("\(count)")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 4)
                                        .background(Color.accentColor, in: Capsule())
                                        .offset(x: 10, y: -6)
                                }
                            }
                        }
                        Text(tab.rawValue)
                            .font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(selectedTab == tab
                        ? Color.accentColor.opacity(0.2) : Color.clear)
                    .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
            Spacer()
        }
        .frame(width: 80)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Session List Panel

    private var sessionListPanel: some View {
        let profileSessions = monitor.sessions.filter { $0.profileRoot != nil }
        let allRunning = profileSessions.filter(\.isRunning).count
        let allRestorable = profileSessions.filter {
            !$0.isRunning && !$0.id.hasPrefix("profile-") && $0.windowIndex != Int.max
        }.count
        let allLaunchable = profileSessions.filter {
            !$0.isRunning && ($0.id.hasPrefix("profile-") || $0.windowIndex == Int.max)
        }.count
        let wgs = monitor.windowGroupService

        return VStack(spacing: 0) {
            // 검색바
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                TextField("검색...", text: $searchText)
                    .textFieldStyle(.plain).font(.caption).focused($searchFocused)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).font(.caption)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            if profileSessions.isEmpty {
                Spacer()
                Image(systemName: "rectangle.3.group").font(.system(size: 32)).foregroundStyle(.secondary)
                Text("프로필 설정 없음").foregroundStyle(.secondary).font(.callout)
                Button { showAddPane = true } label: {
                    Label("새 창 추가", systemImage: "plus.rectangle")
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .padding(.top, 8)
                Spacer()
            } else {
                // 창(WindowPane)별 섹션 — ScrollView 기반 (List는 macOS에서 drag 이벤트 차단)
                let assigned = Set(wgs.groups.flatMap { $0.profileNames })
                let unassigned = profileSessions.filter { !assigned.contains($0.projectName) }
                let filteredUnassigned = searchText.isEmpty ? unassigned
                    : unassigned.filter { $0.projectName.localizedCaseInsensitiveContains(searchText) }

                let totalVisible = wgs.groups.flatMap { pane in
                    paneSessions(pane, all: profileSessions)
                        .filter { searchText.isEmpty || $0.projectName.localizedCaseInsensitiveContains(searchText) }
                }.count + filteredUnassigned.count

                ScrollView {
                    VStack(spacing: 0) {

                        // 새 창 추가 버튼
                        Button { showAddPane = true } label: {
                            Label("새 창 추가", systemImage: "plus.rectangle")
                                .font(.caption)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.blue)
                        Divider()

                        ForEach(wgs.groups) { pane in
                            let paneSess = paneSessions(pane, all: profileSessions)
                            let filtered = searchText.isEmpty ? paneSess
                                : paneSess.filter { $0.projectName.localizedCaseInsensitiveContains(searchText) }
                            if !filtered.isEmpty || searchText.isEmpty {
                                // 섹션 헤더 (pane) — reportPaneFrame은 padding 바깥에 위치
                                paneHeader(pane, sessions: paneSess)
                                    .padding(.horizontal, 10)
                                    .background(Color(nsColor: .controlBackgroundColor))
                                    .reportPaneFrame(id: pane.id)
                                Divider()
                                // 섹션 행들 — reportRowFrame은 padding 바깥에 위치
                                ForEach(Array(filtered.enumerated()), id: \.element.id) { idx, session in
                                    let rk = "\(pane.id)|\(session.projectName)"
                                    sessionRow(session, order: idx + 1, pane: pane, total: filtered.count,
                                               isSelected: selectedSession?.id == session.id,
                                               onSelect: {
                                                   selectedSession = session
                                                   editingTabKey = nil
                                               })
                                        .padding(.horizontal, 10)
                                        .reportRowFrame(key: rk)
                                    Divider().padding(.leading, 10)
                                }
                            }
                        }

                        if !filteredUnassigned.isEmpty {
                            Text("미배정")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(Color(nsColor: .controlBackgroundColor))
                            Divider()
                            ForEach(filteredUnassigned) { session in
                                sessionRow(session, order: nil, pane: nil, total: 0,
                                           isSelected: selectedSession?.id == session.id,
                                           onSelect: { selectedSession = session })
                                    .padding(.horizontal, 10)
                                Divider().padding(.leading, 10)
                            }
                        }
                    }
                }
                .overlay {
                    if !searchText.isEmpty && totalVisible == 0 {
                        VStack(spacing: 8) {
                            Image(systemName: "magnifyingglass").font(.system(size: 24)).foregroundStyle(.secondary)
                            Text("'\(searchText)' 결과 없음").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                .onPreferenceChange(RowFrameKey.self) { rowFrames = $0 }
                .onPreferenceChange(PaneFrameKey.self) { paneFrames = $0 }
            }

            Divider()
            VStack(spacing: 4) {
                if allRestorable > 0 || allRunning > 0 || allLaunchable > 0 {
                    HStack(spacing: 6) {
                        if allLaunchable > 0 {
                            Button {
                                Task { monitor.selectAllLaunchable(); await monitor.restoreSelected() }
                            } label: {
                                Label("전체 시작 (\(allLaunchable))", systemImage: "play.circle.fill")
                                    .font(.caption).frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent).tint(.blue)
                        }
                        if allRestorable > 0 {
                            Button {
                                Task { monitor.selectAllStopped(); await monitor.restoreSelected() }
                            } label: {
                                Label("전체 복원 (\(allRestorable))", systemImage: "arrow.clockwise.circle.fill")
                                    .font(.caption).frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        if allRunning > 0 {
                            Button { Task { await monitor.stopAllRunning() } } label: {
                                Label("중지 (\(allRunning))", systemImage: "stop.circle.fill")
                                    .font(.caption).frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered).tint(.orange)
                        }
                        if allRestorable > 0 {
                            Button { Task { await monitor.purgeIdleZshWindows() } } label: {
                                Label("zsh 정리 (\(allRestorable))", systemImage: "xmark.circle.fill")
                                    .font(.caption).frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered).tint(.red)
                        }
                    }
                    .padding(.horizontal, 10).padding(.top, 6)
                }

                if monitor.isBatchRestoring, let progress = monitor.restoreProgress {
                    VStack(spacing: 3) {
                        ProgressView(value: Double(progress.current), total: Double(progress.total))
                            .progressViewStyle(.linear)
                        HStack {
                            Text("복원 중... \(progress.current)/\(progress.total)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("취소") { monitor.cancelRestore() }
                                .font(.caption2)
                                .buttonStyle(.bordered)
                                .tint(.red)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                }

                HStack(spacing: 6) {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                    Text("실행 \(allRunning)").font(.caption).foregroundStyle(.secondary)
                    if allRestorable > 0 {
                        Circle().fill(Color.orange).frame(width: 6, height: 6)
                        Text("복원 \(allRestorable)").font(.caption).foregroundStyle(.secondary)
                    }
                    if allLaunchable > 0 {
                        Circle().fill(Color.secondary).frame(width: 6, height: 6)
                        Text("대기 \(allLaunchable)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { showNewSession = true } label: {
                        Image(systemName: "plus").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("새 세션 추가")
                    Button {
                        selectedSession = nil
                        monitor.deselectAll()
                        Task { await monitor.refresh() }
                    } label: {
                        Image(systemName: "xmark.circle").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("선택 초기화")
                    Button { Task { await monitor.refresh() } } label: {
                        Image(systemName: "arrow.clockwise").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("새로고침")
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
            }
            .background(.bar)
        }
    }

    // MARK: - Session List Helpers

    private func paneSessions(_ pane: WindowPane, all: [ClaudeSession]) -> [ClaudeSession] {
        pane.profileNames.compactMap { name in all.first { $0.projectName == name } }
    }

    // payload = "profileName|srcPaneId", location = global coords
    private func handleDrop(payload: String, at location: CGPoint) {
        let parts = payload.split(separator: "|", maxSplits: 1)
        guard let profileName = parts.first.map(String.init) else { return }
        let srcPaneIdStr = parts.count > 1 ? String(parts[1]) : ""
        let wgs = monitor.windowGroupService

        // 창 헤더로 드롭 → 해당 창으로 이동
        if let (paneId, _) = paneFrames.first(where: { $0.value.contains(location) }),
           let pane = wgs.groups.first(where: { $0.id == paneId }) {
            if paneId.uuidString != srcPaneIdStr {
                wgs.moveProfile(profileName, to: pane)
            }
            return
        }

        // 행으로 드롭 → 해당 창 + 해당 위치로 이동
        // rowKey = "paneId|profileName"
        if let (rowKey, _) = rowFrames.first(where: { $0.value.contains(location) }) {
            let rp = rowKey.split(separator: "|", maxSplits: 1)
            guard rp.count == 2,
                  let tPaneId = UUID(uuidString: String(rp[0])),
                  let pane = wgs.groups.first(where: { $0.id == tPaneId }) else { return }
            let tProfileName = String(rp[1])
            if tPaneId.uuidString != srcPaneIdStr {
                wgs.moveProfile(profileName, to: pane)
            }
            if let gi = wgs.groups.firstIndex(where: { $0.id == tPaneId }),
               let destIdx = wgs.groups[gi].profileNames.firstIndex(of: tProfileName) {
                wgs.moveProfileToIndex(profileName, groupId: tPaneId, index: destIdx)
            }
        }
    }

    @ViewBuilder
    private func paneHeader(_ pane: WindowPane, sessions: [ClaudeSession]) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "macwindow").font(.caption).foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text(pane.name).font(.caption.bold())
                Text(pane.sessionName).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            let runCount = sessions.filter(\.isRunning).count
            if runCount > 0 {
                Text("\(runCount)/\(sessions.count)")
                    .font(.caption2).foregroundStyle(.green)
            } else {
                Text("\(sessions.count)개")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            // 시작
            Button { Task { await monitor.startGroup(pane) } } label: {
                Image(systemName: "play.fill").font(.caption2).foregroundStyle(.blue)
            }
            .buttonStyle(.plain).help("이 창 전체 시작").disabled(sessions.isEmpty)
            // 수정
            Button { renamingPane = pane } label: {
                Image(systemName: "pencil").font(.caption2).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).help("창 이름/세션명 변경")
            // 삭제
            Button {
                paneToDelete = pane
                showDeletePaneConfirm = true
            } label: {
                Image(systemName: "trash").font(.caption2)
                    .foregroundStyle(monitor.windowGroupService.groups.count <= 1 ? Color.secondary : Color.red.opacity(0.8))
            }
            .buttonStyle(.plain)
            .disabled(monitor.windowGroupService.groups.count <= 1)
            .help("창 삭제 (세션은 첫 번째 창으로 이동)")
        }
        .padding(.vertical, 4)
        .background(dragHighlightPane == pane.id ? Color.blue.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder
    private func sessionRow(_ session: ClaudeSession, order: Int?, pane: WindowPane?, total: Int,
                            isSelected: Bool = false, onSelect: @escaping () -> Void = {}) -> some View {
        let payload = "\(session.projectName)|\(pane?.id.uuidString ?? "")"
        let dotColor: Color = session.isRunning ? .green
            : (!session.id.hasPrefix("profile-") && session.windowIndex != Int.max) ? .orange
            : .secondary
        let hoverKey = "\(pane?.id.uuidString ?? "")|\(session.projectName)"
        HStack(spacing: 6) {
            // ── 드래그 핸들 (DragGesture + GeometryReader 방식) ──
            if let order, let pane {
                let editKey = "\(pane.id)|\(session.projectName)"
                if editingTabKey == editKey {
                    TextField("", text: $tabNumberInput)
                        .frame(width: 26)
                        .font(.caption2.monospacedDigit())
                        .multilineTextAlignment(.center)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            if let num = Int(tabNumberInput), num >= 1 {
                                monitor.windowGroupService.moveProfileToIndex(
                                    session.projectName, groupId: pane.id, index: num - 1)
                            }
                            editingTabKey = nil
                        }
                        .onExitCommand { editingTabKey = nil }
                } else {
                    DragBadgeView(
                        label: "\(order)",
                        isTabNumber: true,
                        onTap: {
                            tabNumberInput = "\(order)"
                            editingTabKey = editKey
                        },
                        onDragChanged: { loc in
                            dragHighlightPane = paneFrames.first { $0.value.contains(loc) }?.key
                            dragHighlightRow = rowFrames.first { $0.value.contains(loc) }?.key
                        },
                        onDragEnded: { loc in
                            handleDrop(payload: payload, at: loc)
                            dragHighlightRow = nil
                            dragHighlightPane = nil
                        },
                        onDragCancelled: {
                            dragHighlightRow = nil
                            dragHighlightPane = nil
                        }
                    )
                    .frame(width: 26, height: 18)
                }
            } else {
                DragBadgeView(
                    label: "≡",
                    isTabNumber: false,
                    onTap: {},
                    onDragChanged: { loc in
                        dragHighlightPane = paneFrames.first { $0.value.contains(loc) }?.key
                        dragHighlightRow = rowFrames.first { $0.value.contains(loc) }?.key
                    },
                    onDragEnded: { loc in
                        handleDrop(payload: payload, at: loc)
                        dragHighlightRow = nil
                        dragHighlightPane = nil
                    },
                    onDragCancelled: {
                        dragHighlightRow = nil
                        dragHighlightPane = nil
                    }
                )
                .frame(width: 26, height: 18)
            }

            // row body: Button으로 선택 처리
            Button(action: onSelect) {
                HStack(spacing: 6) {
                    Circle().fill(dotColor).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.projectName).font(.callout).lineLimit(1)
                        Group {
                            if session.isRunning { Text("PID: \(session.pid)") }
                            else if session.id.hasPrefix("profile-") || session.windowIndex == Int.max { Text("시작 가능") }
                            else { Text("복원 가능") }
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
        .background(isSelected ? Color.accentColor.opacity(0.15) :
                    dragHighlightRow == hoverKey ? Color.accentColor.opacity(0.2) : Color.clear)
        .contentShape(Rectangle())
        .contextMenu {
            if let pane {
                let others = monitor.windowGroupService.groups.filter { $0.id != pane.id }
                if !others.isEmpty {
                    Menu("다른 창으로 이동") {
                        ForEach(others) { target in
                            Button(target.name) {
                                monitor.windowGroupService.moveProfile(session.projectName, to: target)
                            }
                        }
                    }
                }
            } else {
                Menu("창에 추가") {
                    ForEach(monitor.windowGroupService.groups) { target in
                        Button(target.name) {
                            monitor.windowGroupService.moveProfile(session.projectName, to: target)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Session Detail Panel

    @ViewBuilder
    private var sessionDetailPanel: some View {
        SessionDetailView(session: selectedSession, monitor: monitor)
    }

    // MARK: - Other Tab Content

    @ViewBuilder
    private var otherTabContent: some View {
        switch selectedTab {
        case .profiles: ProfilesView(monitor: monitor, searchFocused: $profileSearchFocused, selection: $profileSelection)
        case .backup:   BackupView()
        case .system:   SystemView()
        default:        EmptyStateView(title: "항목을 선택하세요", systemImage: "sidebar.left")
        }
    }
}

struct EmptyStateView: View {
    let title: String
    let systemImage: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage).font(.system(size: 48)).foregroundStyle(.secondary)
            Text(title).font(.title3).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - New Session Sheet

// MARK: - Pane Management Sheets

struct AddPaneSheet: View {
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("새 창 추가").font(.headline).padding()
            Divider()
            Form { TextField("창 이름 (예: IMSMS, Tesla)", text: $name) }.padding()
            Divider()
            HStack {
                Button("취소") { dismiss() }
                Spacer()
                Button("추가") { onSave(name); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }.padding()
        }
        .frame(width: 320)
    }
}

struct RenamePaneSheet: View {
    let pane: WindowPane
    let onSave: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var sessionName: String

    init(pane: WindowPane, onSave: @escaping (String, String) -> Void) {
        self.pane = pane
        self.onSave = onSave
        _name = State(initialValue: pane.name)
        _sessionName = State(initialValue: pane.sessionName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("창 수정").font(.headline).padding()
            Divider()
            Form {
                TextField("창 이름 (UI 표시)", text: $name)
                TextField("tmux 세션명", text: $sessionName)
                    .help("예: claude-work, claude-imsms")
            }.padding()
            Divider()
            HStack {
                Button("취소") { dismiss() }
                Spacer()
                Button("저장") { onSave(name, sessionName); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty ||
                              sessionName.trimmingCharacters(in: .whitespaces).isEmpty)
            }.padding()
        }
        .frame(width: 360)
    }
}

struct ImportToPaneSheet: View {
    let pane: WindowPane
    @ObservedObject var monitor: SessionMonitor
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("'\(pane.name)' 창에 세션 가져오기").font(.headline).padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    importRows
                }
            }
            .frame(minHeight: 150)
            Divider()
            HStack {
                Text("\(selected.count)개 선택됨").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("취소") { dismiss() }
                Button("가져오기") {
                    for id in selected {
                        if let profile = monitor.profileService.profiles.first(where: { $0.id == id }) {
                            monitor.windowGroupService.moveProfile(profile.name, to: pane)
                        }
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty)
            }.padding()
        }
        .frame(width: 420, height: 360)
    }

    @ViewBuilder
    private var importRows: some View {
        let profiles = monitor.profileService.profiles
        let groups = monitor.windowGroupService.groups
        ForEach(profiles, id: \.id) { profile in
            ImportProfileRow(
                profile: profile,
                targetPane: pane,
                groups: groups,
                selected: $selected
            )
            Divider()
        }
    }
}

private struct ImportProfileRow: View {
    let profile: SmugProfile
    let targetPane: WindowPane
    let groups: [WindowPane]
    @Binding var selected: Set<UUID>

    var currentPane: WindowPane {
        groups.first { $0.profileNames.contains(profile.name) }
            ?? groups.first
            ?? WindowPane(name: "메인", sessionName: "claude-work", profileNames: [])
    }
    var isCurrentPane: Bool { currentPane.id == targetPane.id }

    var body: some View {
        HStack {
            Toggle(isOn: Binding(
                get: { selected.contains(profile.id) || isCurrentPane },
                set: { on in
                    guard !isCurrentPane else { return }
                    if on { selected.insert(profile.id) } else { selected.remove(profile.id) }
                }
            )) { EmptyView() }
            .toggleStyle(.checkbox)
            .disabled(isCurrentPane)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name).font(.callout)
                Text(profile.root).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text(isCurrentPane ? "현재" : currentPane.name)
                .font(.caption)
                .foregroundStyle(isCurrentPane ? Color.secondary : Color.blue)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}

// MARK: - New Session Sheet

struct NewSessionSheet: View {
    @ObservedObject var monitor: SessionMonitor
    @Binding var isPresented: Bool
    @State private var directory = ""
    @State private var isCreating = false

    var derivedName: String {
        (directory as NSString).lastPathComponent
    }

    var canCreate: Bool {
        !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("새 세션 추가").font(.headline)

            GroupBox("프로젝트 디렉토리") {
                HStack {
                    Text(directory.isEmpty ? "선택하지 않음" : directory)
                        .foregroundStyle(directory.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("선택...") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.allowsMultipleSelection = false
                        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/claude")
                        if panel.runModal() == .OK, let url = panel.url {
                            directory = url.path
                        }
                    }
                }
                .padding(4)
            }

            GroupBox("세션 이름 (tmux 윈도우명)") {
                LabeledContent("이름") {
                    Text(derivedName.isEmpty ? "경로 선택 후 자동 입력" : derivedName)
                        .foregroundStyle(derivedName.isEmpty ? .secondary : .primary)
                }
                .padding(4)
            }

            HStack {
                Spacer()
                Button("취소") { isPresented = false }
                    .keyboardShortcut(.escape)
                Button("생성") {
                    Task {
                        isCreating = true
                        await monitor.createSession(name: derivedName, directory: directory)
                        isCreating = false
                        isPresented = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canCreate || isCreating)
                .keyboardShortcut(.return)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
