import SwiftUI
import AppKit
import UniformTypeIdentifiers


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

    // 드래그 앤 드롭
    @State private var dragHighlightPane: UUID? = nil

    // 접이식 pane
    @State private var collapsedPanes: Set<UUID> = []

    // 창별 색상 팔레트
    static let paneColors: [Color] = [.blue, .purple, .orange, .green, .pink, .cyan, .indigo, .mint]
    func paneColor(for pane: WindowPane, at index: Int) -> Color {
        pane.isWaitingList ? .secondary : Self.paneColors[index % Self.paneColors.count]
    }

    enum Tab: String, CaseIterable {
        case sessions = "Sessions"
        case profiles = "Profiles"
        case system = "System"
        var icon: String {
            switch self {
            case .sessions: "terminal"
            case .profiles: "rectangle.3.group"
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
            ToastService.shared.startPolling()
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
            AddPaneSheet { name in
                monitor.windowGroupService.addGroup(name: name)
                monitor.profileService.savePerSession(groups: monitor.windowGroupService.groups)
            }
        }
        .sheet(item: $renamingPane) { pane in
            RenamePaneSheet(pane: pane) { newName, newSession in
                let oldSession = pane.sessionName
                monitor.windowGroupService.updateGroup(pane, name: newName, sessionName: newSession)
                monitor.profileService.savePerSession(groups: monitor.windowGroupService.groups)
                // tmux 세션 이름도 실제 rename (세션명이 바뀐 경우만)
                if oldSession != newSession && !pane.isWaitingList {
                    Task {
                        await ShellService.runAsync(
                            "tmux rename-session -t \(ShellService.shellq(oldSession)) \(ShellService.shellq(newSession)) 2>/dev/null; true"
                        )
                    }
                }
            }
        }
        .sheet(item: $importingToPane) { pane in
            ImportToPaneSheet(pane: pane, monitor: monitor)
        }
        .confirmationDialog(
            "Delete group '\(paneToDelete?.name ?? "")'?\nSessions will be moved to the first group.",
            isPresented: $showDeletePaneConfirm, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let p = paneToDelete {
                    monitor.windowGroupService.deleteGroup(p)
                    monitor.profileService.savePerSession(groups: monitor.windowGroupService.groups)
                }
            }
            Button("Cancel", role: .cancel) {}
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
                Button("") { selectedTab = .system  }.keyboardShortcut("3", modifiers: .command)
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
            !$0.isRunning && $0.isAssigned && !$0.id.hasPrefix("profile-") && $0.windowIndex != Int.max
        }.count
        let allLaunchable = profileSessions.filter {
            !$0.isRunning && $0.isAssigned && ($0.id.hasPrefix("profile-") || $0.windowIndex == Int.max)
        }.count
        let wgs = monitor.windowGroupService

        return VStack(spacing: 0) {
            // 검색바
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                TextField("Search...", text: $searchText)
                    .textFieldStyle(.plain).font(.caption).focused($searchFocused)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).font(.caption)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))

            // 동기화 배너 (사용자 액션 시만 표시)
            if monitor.isSyncing {
                HStack(spacing: 6) {
                    ProgressView().progressViewStyle(.circular).scaleEffect(0.55)
                    Text("Syncing...").font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.08))
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            Divider()

            if profileSessions.isEmpty {
                Spacer()
                Image(systemName: "rectangle.3.group").font(.system(size: 32)).foregroundStyle(.secondary)
                Text("No profiles configured").foregroundStyle(.secondary).font(.callout)
                Button { showAddPane = true } label: {
                    Label("Add Group", systemImage: "plus.rectangle")
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .padding(.top, 8)
                Spacer()
            } else {
                // 창(WindowPane)별 섹션 — ScrollView 기반 (List는 macOS에서 drag 이벤트 차단)
                let totalVisible = wgs.groups.flatMap { pane in
                    paneSessions(pane, all: profileSessions)
                        .filter { searchText.isEmpty || $0.projectName.localizedCaseInsensitiveContains(searchText) }
                }.count

                ScrollView {
                    VStack(spacing: 0) {

                        // 새 창 추가 버튼
                        Button { showAddPane = true } label: {
                            Label("Add Group", systemImage: "plus.rectangle")
                                .font(.caption)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.blue)
                        Divider()

                        ForEach(Array(wgs.groups.enumerated()), id: \.element.id) { paneIdx, pane in
                            let paneSess = paneSessions(pane, all: profileSessions)
                            let filtered = searchText.isEmpty ? paneSess
                                : paneSess.filter { $0.projectName.localizedCaseInsensitiveContains(searchText) }
                            let color = paneColor(for: pane, at: paneIdx)
                            let isCollapsed = collapsedPanes.contains(pane.id)
                            if !filtered.isEmpty || searchText.isEmpty {
                                // Pane 헤더 (drop target + 색상 구분)
                                paneHeader(pane, sessions: paneSess, color: color, isCollapsed: isCollapsed) {
                                        if isCollapsed { collapsedPanes.remove(pane.id) }
                                        else { collapsedPanes.insert(pane.id) }
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(color.opacity(dragHighlightPane == pane.id ? 0.30 : 0.08))
                                    .overlay(alignment: .leading) {
                                        Rectangle().fill(color).frame(width: 3)
                                    }
                                    .contentShape(Rectangle())
                                    .dropDestination(for: String.self) { payloads, _ in
                                        let payload = payloads.first ?? ""
                                        badgeLog("[drop] pane=\(pane.name) payload=\(payload)")
                                        guard !payload.isEmpty else { return false }
                                        let parts = payload.split(separator: "|", maxSplits: 1)
                                        guard let profileName = parts.first.map(String.init) else { return false }
                                        let srcPaneIdStr = parts.count > 1 ? String(parts[1]) : ""
                                        if pane.id.uuidString != srcPaneIdStr {
                                            monitor.windowGroupService.moveProfile(profileName, to: pane)
                                            monitor.profileService.savePerSession(groups: monitor.windowGroupService.groups)
                                        }
                                        badgeLog("[drop done] moved \(profileName) to \(pane.name)")
                                        return true
                                    } isTargeted: { targeted in
                                        badgeLog("[isTargeted] pane=\(pane.name) targeted=\(targeted)")
                                        dragHighlightPane = targeted ? pane.id : nil
                                    }

                                if !isCollapsed {
                                    ForEach(Array(filtered.enumerated()), id: \.element.id) { idx, session in
                                        sessionRow(session, order: idx + 1, pane: pane, total: filtered.count,
                                                   paneColor: color,
                                                   isSelected: selectedSession?.id == session.id,
                                                   onSelect: {
                                                       selectedSession = session
                                                       editingTabKey = nil
                                                   })
                                            .padding(.horizontal, 8)
                                            .padding(.leading, 3)
                                            .background(color.opacity(0.04))
                                            .overlay(alignment: .leading) {
                                                Rectangle().fill(color.opacity(0.3)).frame(width: 3)
                                            }
                                            .dropDestination(for: String.self) { payloads, _ in
                                                let payload = payloads.first ?? ""
                                                badgeLog("[row-drop] pane=\(pane.name) target=\(session.projectName) payload=\(payload)")
                                                guard !payload.isEmpty else { return false }
                                                let parts = payload.split(separator: "|", maxSplits: 1)
                                                guard let profileName = parts.first.map(String.init) else { return false }
                                                let srcPaneIdStr = parts.count > 1 ? String(parts[1]) : ""
                                                if pane.id.uuidString != srcPaneIdStr {
                                                    monitor.windowGroupService.moveProfile(profileName, to: pane)
                                                }
                                                if let destIdx = monitor.windowGroupService.groups
                                                    .first(where: { $0.id == pane.id })?
                                                    .profileNames.firstIndex(of: session.projectName) {
                                                    monitor.windowGroupService.moveProfileToIndex(profileName, groupId: pane.id, index: destIdx)
                                                }
                                                monitor.profileService.savePerSession(groups: monitor.windowGroupService.groups)
                                                return true
                                            } isTargeted: { targeted in
                                                dragHighlightPane = targeted ? pane.id : nil
                                            }
                                        Divider().padding(.leading, 11)
                                    }
                                }
                                Divider()
                            }
                        }

                    }
                }
                .overlay {
                    if !searchText.isEmpty && totalVisible == 0 {
                        VStack(spacing: 8) {
                            Image(systemName: "magnifyingglass").font(.system(size: 24)).foregroundStyle(.secondary)
                            Text("No results for '\(searchText)'").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Divider()
            VStack(spacing: 4) {
                if allRestorable > 0 || allRunning > 0 || allLaunchable > 0 {
                    HStack(spacing: 6) {
                        // 즉시 적용: 프로필 기반 미시작 세션만 (allLaunchable만, allRestorable은 Clean Up 대상)
                        if allLaunchable > 0 {
                            Button {
                                Task { await monitor.applyNow() }
                            } label: {
                                Label("Apply Now (\(allLaunchable))", systemImage: "bolt.circle.fill")
                                    .font(.caption).frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent).tint(.green)
                            .help("Start all profile-based idle sessions assigned to a group")
                        }
                        if allRunning > 0 {
                            Button { Task { await monitor.stopAllRunning() } } label: {
                                Label("Stop (\(allRunning))", systemImage: "stop.circle.fill")
                                    .font(.caption).frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered).tint(.orange)
                        }
                        if allRestorable > 0 {
                            Button { Task { await monitor.purgeIdleZshWindows() } } label: {
                                Label("Clean Up (\(allRestorable))", systemImage: "xmark.circle.fill")
                                    .font(.caption).frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered).tint(.red)
                            .help("Close empty tmux windows running only zsh without Claude (leftover cleanup after restore failure)")
                        }
                    }
                    .padding(.horizontal, 10).padding(.top, 6)
                }

                if monitor.isBatchRestoring, let progress = monitor.restoreProgress {
                    VStack(spacing: 3) {
                        ProgressView(value: Double(progress.current), total: Double(progress.total))
                            .progressViewStyle(.linear)
                        HStack {
                            Text("Restoring... \(progress.current)/\(progress.total)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Cancel") { monitor.cancelRestore() }
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
                    Text("Running \(allRunning)").font(.caption).foregroundStyle(.secondary)
                    if allRestorable > 0 {
                        Circle().fill(Color.orange).frame(width: 6, height: 6)
                        Text("Restorable \(allRestorable)").font(.caption).foregroundStyle(.secondary)
                    }
                    if allLaunchable > 0 {
                        Circle().fill(Color.secondary).frame(width: 6, height: 6)
                        Text("Idle \(allLaunchable)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { showNewSession = true } label: {
                        Image(systemName: "plus").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("Add new session")
                    Button {
                        selectedSession = nil
                        monitor.deselectAll()
                        Task { await monitor.refresh(showBanner: true) }
                    } label: {
                        Image(systemName: "xmark.circle").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("Clear selection")
                    Button { Task { await monitor.refresh(showBanner: true) } } label: {
                        Image(systemName: "arrow.clockwise").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("Refresh")
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
            }
            .background(.bar)
        }
        .animation(.easeInOut(duration: 0.2), value: monitor.isSyncing)
    }

    // MARK: - Session List Helpers

    private func paneSessions(_ pane: WindowPane, all: [ClaudeSession]) -> [ClaudeSession] {
        pane.profileNames.compactMap { name in
            // tmuxSession이 일치하는 세션 우선, 없으면 첫 번째 매칭
            all.first { $0.projectName == name && $0.tmuxSession == pane.sessionName }
            ?? all.first { $0.projectName == name }
        }
    }

    @ViewBuilder
    private func paneHeader(_ pane: WindowPane, sessions: [ClaudeSession], color: Color,
                            isCollapsed: Bool, onToggleCollapse: @escaping () -> Void) -> some View {
        let runCount = sessions.filter(\.isRunning).count
        HStack(spacing: 8) {
            // 좌측: 접이식 영역 (chevron + 아이콘 + 텍스트) — 탭 시 collapse
            HStack(spacing: 6) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(color.opacity(0.7))
                    .frame(width: 12)
                Image(systemName: pane.isWaitingList ? "tray.full.fill" : "macwindow")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(color)
                VStack(alignment: .leading, spacing: 1) {
                    Text(pane.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    HStack(spacing: 4) {
                        if pane.isWaitingList {
                            Text("Drag here to assign")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        } else {
                            Text(pane.sessionName)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            if sessions.count > 0 {
                                Text("·").font(.system(size: 10)).foregroundStyle(.tertiary)
                                Text(runCount > 0 ? "\(runCount) running" : "\(sessions.count) tabs")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(runCount > 0 ? Color.green : Color.secondary)
                            }
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) { onToggleCollapse() }
            }

            Spacer()

            // 우측: 버튼 그룹 (각 버튼이 독립 탭 처리)
            HStack(spacing: 4) {
                if pane.isWaitingList {
                    // 대기 목록: zsh 창 전체 닫기 + 이름 변경
                    let hasWindows = paneSessions(pane, all: monitor.sessions.filter { $0.profileRoot != nil })
                        .contains { !$0.id.hasPrefix("profile-") && $0.windowIndex >= 0 && $0.windowIndex != Int.max }
                    Button { Task { await monitor.killWaitingListWindows() } } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(hasWindows ? Color.red.opacity(0.8) : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!hasWindows)
                    .help("Close all open tmux windows in waiting list")

                    Button { renamingPane = pane } label: {
                        Image(systemName: "pencil.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.secondary)
                    }
                    .buttonStyle(.plain).help("Rename waiting list")
                } else {
                    // BUG#31 fix: startingGroups 체크로 중복 클릭 방지
                    let isStarting = monitor.startingGroups.contains(pane.sessionName)
                    Button { Task { await monitor.startGroup(pane) } } label: {
                        Image(systemName: isStarting ? "hourglass.circle.fill" : "play.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(sessions.isEmpty || isStarting ? Color.secondary : color)
                    }
                    .buttonStyle(.plain).help(isStarting ? "Starting..." : "Start all in group")
                    .disabled(sessions.isEmpty || isStarting)
                    .accessibilityIdentifier("startGroup_\(pane.sessionName)")

                    Button { Task { await monitor.stopGroup(pane) } } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(runCount == 0 ? Color.secondary : Color.orange)
                    }
                    .buttonStyle(.plain).help("Stop running sessions in group").disabled(runCount == 0)

                    // BUG#37 fix: Import 버튼 — importingToPane 설정 경로 없던 dead code 해소
                    Button { importingToPane = pane } label: {
                        Image(systemName: "tray.and.arrow.down.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.secondary)
                    }
                    .buttonStyle(.plain).help("Import profiles into this group")

                    Button { renamingPane = pane } label: {
                        Image(systemName: "pencil.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.secondary)
                    }
                    .buttonStyle(.plain).help("Rename group")

                    let nonWaitingCount = monitor.windowGroupService.groups.filter { !$0.isWaitingList }.count
                    Button {
                        paneToDelete = pane
                        showDeletePaneConfirm = true
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(nonWaitingCount <= 1 ? Color.secondary : Color.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .disabled(nonWaitingCount <= 1)
                    .help("Delete group (sessions move to waiting list)")
                }
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func sessionRow(_ session: ClaudeSession, order: Int?, pane: WindowPane?, total: Int,
                            paneColor: Color = .blue,
                            isSelected: Bool = false, onSelect: @escaping () -> Void = {}) -> some View {
        let payload = "\(session.projectName)|\(pane?.id.uuidString ?? "")"
        let dirName: String = {
            let d = session.directory
            if d.isEmpty { return "" }
            return URL(fileURLWithPath: d).lastPathComponent
        }()

        ZStack(alignment: .leading) {
            // 콘텐츠 레이어
            HStack(spacing: 8) {
                // 드래그 핸들 아이콘 (시각적 힌트)
                DragHandleIcon(color: paneColor)

                // 탭 번호
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
                        Text("\(order)")
                            .font(.system(size: 10, design: .monospaced))
                            .frame(width: 24, height: 18)
                            .background(paneColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(paneColor.opacity(0.9))
                    }
                } else {
                    Image(systemName: "tray")
                        .font(.system(size: 10))
                        .frame(width: 24, height: 18)
                        .foregroundStyle(Color.secondary.opacity(0.5))
                }

                // ── 상태 인디케이터 (7단계) ──
                SessionStatusIndicator(session: session)

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.projectName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(session.didCrash ? Color.red.opacity(0.85) : Color.primary)
                    HStack(spacing: 4) {
                        // 우선순위: 특수상태 → 실행상태 → 디렉토리 → 기본
                        if session.didCrash {
                            Text("Crashed").font(.system(size: 10, weight: .medium)).foregroundStyle(Color.red)
                        } else if session.isRunning && session.claudeStatus == .working {
                            Text("Working").font(.system(size: 10, weight: .medium)).foregroundStyle(Color.blue)
                        } else if session.isRunning && session.claudeStatus == .blocked {
                            Text("Needs Input!").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.orange)
                        } else if session.isRunning && session.claudeStatus == .starting {
                            Text("Starting").font(.system(size: 10, weight: .medium)).foregroundStyle(Color.yellow.opacity(0.9))
                        } else if session.isRunning && session.claudeStatus == .waiting {
                            Text("Waiting").font(.system(size: 10)).foregroundStyle(Color.blue.opacity(0.7))
                        } else if session.isRunning {
                            if !dirName.isEmpty {
                                Image(systemName: "folder").font(.system(size: 9)).foregroundStyle(.tertiary)
                                Text(dirName).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            } else {
                                Text("Running").font(.system(size: 10)).foregroundStyle(Color.green.opacity(0.8))
                            }
                        } else if !dirName.isEmpty {
                            Image(systemName: "folder").font(.system(size: 9)).foregroundStyle(.tertiary)
                            Text(dirName).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        } else if !session.isRunning && session.windowIndex != Int.max && session.windowIndex >= 0 {
                            Text("Restorable").font(.system(size: 10)).foregroundStyle(Color.secondary)
                        }
                    }
                }
                Spacer()

                // 재시작 / 강제복구 버튼 (crash 상태일 때만)
                if session.didCrash {
                    HStack(spacing: 4) {
                        Button {
                            Task { await monitor.restartSession(session) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.orange)
                        }
                        .buttonStyle(.plain)
                        .help("Restart (keep existing window)")

                        Button {
                            Task { await monitor.forceResetSession(session) }
                        } label: {
                            Image(systemName: "bolt.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.red)
                        }
                        .buttonStyle(.plain)
                        .help("Force reset (recreate window)")
                    }
                    .padding(.trailing, 2)
                }
            }
            .padding(.vertical, 4)
            .background(isSelected ? paneColor.opacity(0.12) : Color.clear)

            // 드래그 오버레이 레이어 (전체 row, 즉시 드래그 + tap→onSelect)
            // isEditing 시 hitTest nil → TextField가 직접 이벤트 수신
            let editKey = pane.map { "\($0.id)|\(session.projectName)" } ?? ""
            FullRowDragOverlay(payload: payload, onSelect: onSelect,
                               isEditing: editingTabKey == editKey && !editKey.isEmpty)
        }
        .contextMenu {
            if session.didCrash {
                Button {
                    Task { await monitor.restartSession(session) }
                } label: {
                    Label("Restart", systemImage: "arrow.clockwise")
                }
                Button(role: .destructive) {
                    Task { await monitor.forceResetSession(session) }
                } label: {
                    Label("Force Reset", systemImage: "bolt.circle.fill")
                }
                Divider()
            }
            if let pane {
                let others = monitor.windowGroupService.groups.filter { $0.id != pane.id }
                if !others.isEmpty {
                    Menu("Move to Group") {
                        ForEach(others) { target in
                            Button(target.name) {
                                monitor.windowGroupService.moveProfile(session.projectName, to: target)
                            }
                        }
                    }
                }
            } else {
                Menu("Add to Group") {
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
        case .system:   SystemView(monitor: monitor)
        default:        EmptyStateView(title: "Select an item", systemImage: "sidebar.left")
        }
    }
}

// MARK: - Session Status Indicator

struct SessionStatusIndicator: View {
    let session: ClaudeSession
    @State private var pulse = false

    var body: some View {
        Group {
            if session.didCrash {
                // 🔴 Crash: 빨강 도트 + pulse
                ZStack {
                    Circle().fill(Color.red.opacity(pulse ? 0.25 : 0))
                        .frame(width: 14, height: 14)
                    Circle().fill(Color.red)
                        .frame(width: 8, height: 8)
                        .shadow(color: .red.opacity(0.6), radius: 3)
                }
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                        pulse = true
                    }
                }
            } else if session.isRunning && session.claudeStatus == .working {
                // 🔵 작업 중: 파랑 스피너
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.5)
            } else if session.isRunning && session.claudeStatus == .blocked {
                // 🟠 확인 필요: 주황 ! (badge)
                ZStack {
                    Circle().fill(Color.orange.opacity(0.15))
                        .frame(width: 14, height: 14)
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 8, weight: .black))
                        .foregroundStyle(Color.orange)
                }
            } else if session.isRunning && session.claudeStatus == .starting {
                // 🟡 시작 중: 노랑 도트 + pulse
                Circle().fill(Color.yellow)
                    .frame(width: 8, height: 8)
                    .opacity(pulse ? 0.5 : 1.0)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                            pulse = true
                        }
                    }
            } else if session.isRunning && session.claudeStatus == .waiting {
                // 🔵 대기(waiting): 파랑-회색 도트 (idle과 구분)
                Circle().fill(Color.blue.opacity(0.5))
                    .frame(width: 8, height: 8)
            } else if session.isRunning {
                // 🟢 정상(idle/unknown): 초록 도트
                Circle().fill(Color.green)
                    .frame(width: 8, height: 8)
                    .shadow(color: .green.opacity(0.5), radius: 3)
            } else if !session.id.hasPrefix("profile-") && session.windowIndex >= 0 && session.windowIndex != Int.max {
                // ⚫ zsh 대기: 회색 도트 (tmux 창 있지만 claude 없음)
                Circle().fill(Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
            } else {
                // ▬ 꺼짐: 흐린 대시 (프로필만 있음, tmux 창 없음)
                Rectangle()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(width: 10, height: 2)
                    .cornerRadius(1)
            }
        }
        .frame(width: 14, height: 14)
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
            Text("Add Group").font(.headline).padding()
            Divider()
            Form { TextField("Group name (e.g. IMSMS, Tesla)", text: $name) }.padding()
            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add") { onSave(name); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
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

    // BUG#36 fix: 공백/특수문자 있는 session name → openITermTabs bash 파괴 방지
    private var isValidSessionName: Bool {
        let s = sessionName.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Edit Group").font(.headline).padding()
            Divider()
            Form {
                TextField("Group name (UI label)", text: $name)
                VStack(alignment: .leading, spacing: 4) {
                    TextField("tmux session name", text: $sessionName)
                        .help("e.g. claude-work, claude-imsms (alphanumeric + hyphens only)")
                    if !isValidSessionName && !sessionName.isEmpty {
                        Text("Only alphanumeric, hyphens, underscores allowed")
                            .font(.caption2).foregroundStyle(.red)
                    }
                }
            }.padding()
            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { onSave(name, sessionName.trimmingCharacters(in: .whitespaces)); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || !isValidSessionName)
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
            Text("Import sessions to '\(pane.name)'").font(.headline).padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    importRows
                }
            }
            .frame(minHeight: 150)
            Divider()
            HStack {
                Text("\(selected.count) selected").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import") {
                    for id in selected {
                        if let profile = monitor.profileService.profiles.first(where: { $0.id == id }) {
                            monitor.windowGroupService.moveProfile(profile.name, to: pane)
                        }
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
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
            ?? WindowPane(name: "Main", sessionName: "claude-work", profileNames: [])
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
            Text(isCurrentPane ? "Current" : currentPane.name)
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
    @State private var selectedGroupId: UUID? = nil

    var derivedName: String {
        (directory as NSString).lastPathComponent
    }

    var activeGroups: [WindowPane] {
        monitor.windowGroupService.groups.filter { !$0.isWaitingList }
    }

    var selectedGroup: WindowPane? {
        activeGroups.first { $0.id == selectedGroupId } ?? activeGroups.first
    }

    var canCreate: Bool {
        !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add New Session").font(.headline)

            GroupBox("Project Directory") {
                HStack {
                    Text(directory.isEmpty ? "Not selected" : directory)
                        .foregroundStyle(directory.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Browse...") {
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

            GroupBox("Session Name (tmux window name)") {
                LabeledContent("Name") {
                    Text(derivedName.isEmpty ? "Auto-filled after selecting a path" : derivedName)
                        .foregroundStyle(derivedName.isEmpty ? .secondary : .primary)
                }
                .padding(4)
            }

            if activeGroups.count > 1 {
                GroupBox("Group") {
                    Picker("Group", selection: $selectedGroupId) {
                        ForEach(activeGroups) { group in
                            Text("\(group.name) (\(group.sessionName))").tag(Optional(group.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
                .onAppear { selectedGroupId = activeGroups.first?.id }
            }

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.escape)
                Button("Create") {
                    Task {
                        isCreating = true
                        // window-groups.json 먼저 등록 (checkAutoSync가 새 창을 kill하지 않도록)
                        if let group = selectedGroup {
                            monitor.windowGroupService.moveProfile(derivedName, to: group)
                        }
                        let targetSession = selectedGroup?.sessionName
                        await monitor.createSession(name: derivedName, directory: directory,
                                                    sessionName: targetSession)
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
