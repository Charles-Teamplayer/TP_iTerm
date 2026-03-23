import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var monitor = SessionMonitor()
    @StateObject private var profileService = ProfileService()
    @State private var selectedTab: Tab = .sessions
    @State private var selectedSession: ClaudeSession?
    @State private var showNewSession = false
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

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
            monitor.start()
            profileService.load()
            let msg = "APP_V8_LAUNCHED \(Date())\n"
            FileManager.default.createFile(atPath: "/tmp/restore_debug.log",
                                           contents: msg.data(using: .utf8))
        }
        .onDisappear { monitor.stop() }
        .background {
            Group {
                Button("") { selectedTab = .sessions }.keyboardShortcut("1", modifiers: .command)
                Button("") { selectedTab = .profiles }.keyboardShortcut("2", modifiers: .command)
                Button("") { selectedTab = .backup   }.keyboardShortcut("3", modifiers: .command)
                Button("") { selectedTab = .system   }.keyboardShortcut("4", modifiers: .command)
                Button("") {
                    selectedTab = .sessions
                    searchFocused = true
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
                                let count = profileService.profiles.count
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
            }
            Spacer()
        }
        .frame(width: 80)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Session List Panel

    private var sessionListPanel: some View {
        // 1:1 — 프로필 기반 세션만 표시
        let profileSessions = monitor.sessions.filter { $0.profileRoot != nil }
        let filtered = searchText.isEmpty
            ? profileSessions
            : profileSessions.filter { $0.projectName.localizedCaseInsensitiveContains(searchText) }
        let runningCount = profileSessions.filter(\.isRunning).count
        // 복원 대상 = 실제 tmux window가 있었던 중단 세션 (프로필 가상 세션 제외)
        let restorableCount = profileSessions.filter {
            !$0.isRunning && !$0.id.hasPrefix("profile-") && $0.windowIndex != Int.max
        }.count
        let stoppedCount = profileSessions.filter { !$0.isRunning }.count

        return VStack(spacing: 0) {
            // 검색바
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                TextField("검색...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .focused($searchFocused)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            if monitor.sessions.isEmpty {
                Spacer()
                Image(systemName: "terminal")
                    .font(.system(size: 32)).foregroundStyle(.secondary)
                Text("tmux 세션 없음").foregroundStyle(.secondary)
                Spacer()
            } else if filtered.isEmpty {
                Spacer()
                Text("검색 결과 없음").foregroundStyle(.secondary).font(.caption)
                Spacer()
            } else {
                List(filtered, selection: $selectedSession) { session in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(session.isRunning ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.projectName)
                                .font(.headline)
                                .lineLimit(1)
                            Text(session.isRunning ? "PID: \(session.pid)" : "대기 중")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 2)
                    .tag(session)
                }
                .listStyle(.plain)
                .focusable(false)
            }

            Divider()
            VStack(spacing: 4) {
                if restorableCount > 0 || runningCount > 0 {
                    HStack(spacing: 6) {
                        if restorableCount > 0 {
                            Button {
                                Task {
                                    monitor.selectAllStopped()
                                    await monitor.restoreSelected()
                                }
                            } label: {
                                Label("전체 복원 (\(restorableCount))", systemImage: "arrow.clockwise.circle.fill")
                                    .font(.caption)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        if runningCount > 0 {
                            Button {
                                Task { await monitor.stopAllRunning() }
                            } label: {
                                Label("전체 중지 (\(runningCount))", systemImage: "stop.circle.fill")
                                    .font(.caption)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .tint(.orange)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                }

                HStack(spacing: 6) {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                    Text("실행 \(runningCount)").font(.caption).foregroundStyle(.secondary)
                    Circle().fill(Color.red).frame(width: 6, height: 6)
                    Text("대기 \(stoppedCount)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { showNewSession = true } label: {
                        Image(systemName: "plus").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("새 세션 추가")
                    Button { Task { await monitor.refresh() } } label: {
                        Image(systemName: "arrow.clockwise").font(.caption)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
            }
            .background(.bar)
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
        case .profiles: ProfilesView(monitor: monitor)
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

struct NewSessionSheet: View {
    @ObservedObject var monitor: SessionMonitor
    @Binding var isPresented: Bool
    @State private var sessionName = ""
    @State private var directory = ""
    @State private var isCreating = false
    @StateObject private var profileService = ProfileService()
    @State private var selectedProfile: SmugProfile? = nil

    var canCreate: Bool {
        !sessionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("새 세션 추가").font(.headline)

            // 프로필에서 선택
            if !profileService.profiles.isEmpty {
                GroupBox("저장된 프로필에서 선택") {
                    Picker("프로필", selection: $selectedProfile) {
                        Text("직접 입력").tag(Optional<SmugProfile>.none)
                        ForEach(profileService.profiles) { p in
                            Text(p.name).tag(Optional(p))
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: selectedProfile) { profile in
                        if let p = profile {
                            sessionName = p.name
                            directory = p.root.hasPrefix("~")
                                ? p.root.replacingOccurrences(of: "~", with: NSHomeDirectory(),
                                    range: p.root.range(of: "~"))
                                : p.root
                        }
                    }
                    .padding(4)
                }
            }

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
                            if sessionName.isEmpty {
                                sessionName = url.lastPathComponent
                            }
                            selectedProfile = nil
                        }
                    }
                }
                .padding(4)
            }

            GroupBox("세션 이름 (tmux 윈도우명)") {
                TextField("예: my-project", text: $sessionName)
                    .textFieldStyle(.plain)
                    .padding(4)
                    .onChange(of: sessionName) { _ in selectedProfile = nil }
            }

            HStack {
                Spacer()
                Button("취소") { isPresented = false }
                    .keyboardShortcut(.escape)
                Button("생성") {
                    Task {
                        isCreating = true
                        await monitor.createSession(name: sessionName, directory: directory)
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
        .onAppear { profileService.load() }
    }
}
