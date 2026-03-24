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
            }
        .onChange(of: monitor.sessions) { sessions in
            if let current = selectedSession {
                selectedSession = sessions.first { $0.id == current.id }
            }
        }
        .onDisappear { monitor.stop() }
        .sheet(isPresented: $showAddPane) {
            AddPaneSheet { name in monitor.windowGroupService.addGroup(name: name) }
        }
        .sheet(item: $renamingPane) { pane in
            RenamePaneSheet(pane: pane) { newName in
                monitor.windowGroupService.updateGroup(pane, name: newName)
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
                Spacer()
            } else {
                // 창(WindowPane)별 섹션
                List(selection: $selectedSession) {
                    ForEach(wgs.groups) { pane in
                        let paneSessions = paneSessions(pane, all: profileSessions)
                        let filtered = searchText.isEmpty ? paneSessions
                            : paneSessions.filter { $0.projectName.localizedCaseInsensitiveContains(searchText) }
                        if !filtered.isEmpty || searchText.isEmpty {
                            Section {
                                ForEach(Array(filtered.enumerated()), id: \.element.id) { idx, session in
                                    sessionRow(session, order: idx + 1, pane: pane, total: filtered.count)
                                        .tag(session)
                                }
                            } header: {
                                paneHeader(pane, sessions: paneSessions)
                            }
                        }
                    }
                    // 어떤 창에도 없는 세션
                    let assigned = Set(wgs.groups.flatMap { $0.profileNames })
                    let unassigned = profileSessions.filter { !assigned.contains($0.projectName) }
                    let filteredUnassigned = searchText.isEmpty ? unassigned
                        : unassigned.filter { $0.projectName.localizedCaseInsensitiveContains(searchText) }
                    if !filteredUnassigned.isEmpty {
                        Section("미배정") {
                            ForEach(filteredUnassigned) { session in
                                sessionRow(session, order: nil, pane: nil, total: 0).tag(session)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .focusable(false)
                .focusEffectDisabled()
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
                    Button { showAddPane = true } label: {
                        Image(systemName: "plus.rectangle").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("새 창 추가")
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

    @ViewBuilder
    private func paneHeader(_ pane: WindowPane, sessions: [ClaudeSession]) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "macwindow").font(.caption2).foregroundStyle(.secondary)
            Text(pane.name).font(.caption.bold())
            Text("· \(pane.sessionName)").font(.caption2).foregroundStyle(.secondary)
            Spacer()
            // 임포트
            Button { importingToPane = pane } label: {
                Image(systemName: "arrow.down.doc").font(.caption2)
            }
            .buttonStyle(.plain).help("세션 가져오기")
            // 창 시작
            Button { Task { await monitor.startGroup(pane) } } label: {
                Image(systemName: "play.rectangle.fill").font(.caption2)
            }
            .buttonStyle(.plain).foregroundStyle(.blue).help("이 창 시작")
            .disabled(sessions.isEmpty)
            // 더보기 메뉴
            Menu {
                Button { renamingPane = pane } label: {
                    Label("이름 변경", systemImage: "pencil")
                }
                Button { importingToPane = pane } label: {
                    Label("세션 가져오기", systemImage: "arrow.down.doc")
                }
                Divider()
                Button(role: .destructive) {
                    paneToDelete = pane
                    showDeletePaneConfirm = true
                } label: {
                    Label("창 삭제", systemImage: "trash")
                }
                .disabled(monitor.windowGroupService.groups.count <= 1)
            } label: {
                Image(systemName: "ellipsis").font(.caption2).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func sessionRow(_ session: ClaudeSession, order: Int?, pane: WindowPane?, total: Int) -> some View {
        HStack(spacing: 6) {
            // 실행순서 + 이동 버튼
            if let order, let pane {
                HStack(spacing: 2) {
                    Text("\(order)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 16, alignment: .trailing)
                    VStack(spacing: 0) {
                        Button { monitor.windowGroupService.moveProfileInGroup(session.projectName, groupId: pane.id, up: true) } label: {
                            Image(systemName: "chevron.up").font(.system(size: 7))
                        }.buttonStyle(.plain).disabled(order == 1)
                        Button { monitor.windowGroupService.moveProfileInGroup(session.projectName, groupId: pane.id, up: false) } label: {
                            Image(systemName: "chevron.down").font(.system(size: 7))
                        }.buttonStyle(.plain).disabled(order == total)
                    }
                }
            }
            // 상태 dot
            let dotColor: Color = session.isRunning ? .green
                : (!session.id.hasPrefix("profile-") && session.windowIndex != Int.max) ? .orange
                : .secondary
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
        .padding(.vertical, 2)
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
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(pane: WindowPane, onSave: @escaping (String) -> Void) {
        self.pane = pane
        self.onSave = onSave
        _name = State(initialValue: pane.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("창 이름 변경").font(.headline).padding()
            Divider()
            Form { TextField("창 이름", text: $name) }.padding()
            Divider()
            HStack {
                Button("취소") { dismiss() }
                Spacer()
                Button("저장") { onSave(name); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }.padding()
        }
        .frame(width: 320)
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
