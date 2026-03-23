import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var monitor = SessionMonitor()
    @State private var selectedTab: Tab = .sessions
    @State private var selectedSession: ClaudeSession?
    @State private var showNewSession = false
    @State private var searchText = ""

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
            let msg = "APP_V8_LAUNCHED \(Date())\n"
            FileManager.default.createFile(atPath: "/tmp/restore_debug.log",
                                           contents: msg.data(using: .utf8))
        }
        .onDisappear { monitor.stop() }
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
                        Image(systemName: tab.icon)
                            .font(.system(size: 18))
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
        let filtered = searchText.isEmpty
            ? monitor.sessions
            : monitor.sessions.filter { $0.projectName.localizedCaseInsensitiveContains(searchText) }
        let runningCount = monitor.sessions.filter(\.isRunning).count
        let stoppedCount = monitor.sessions.filter { !$0.isRunning }.count

        return VStack(spacing: 0) {
            // 검색바
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                TextField("검색...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.caption)
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
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { session in
                            Button {
                                selectedSession = session
                                let msg = "CLICKED:\(session.projectName) \(Date())\n"
                                if let fh = FileHandle(forWritingAtPath: "/tmp/restore_debug.log") {
                                    fh.seekToEndOfFile()
                                    fh.write(msg.data(using: .utf8) ?? Data())
                                    fh.closeFile()
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(session.isRunning ? Color.green : Color.red)
                                        .frame(width: 8, height: 8)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(session.projectName)
                                            .font(.headline)
                                            .foregroundStyle(session.isRunning ? Color.primary : Color.secondary)
                                            .lineLimit(1)
                                        Text("PID: \(session.pid)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    selectedSession?.id == session.id
                                        ? Color.accentColor.opacity(0.15) : Color.clear
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
            }

            Divider()
            VStack(spacing: 4) {
                // 전체 복원 버튼 (중단 세션 있을 때만)
                if stoppedCount > 0 {
                    Button {
                        Task {
                            monitor.selectAllStopped()
                            await monitor.restoreSelected()
                        }
                    } label: {
                        Label("중단 세션 전체 복원 (\(stoppedCount)개)", systemImage: "arrow.clockwise.circle.fill")
                            .font(.caption)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                }

                HStack(spacing: 6) {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                    Text("실행 \(runningCount)").font(.caption).foregroundStyle(.secondary)
                    Circle().fill(Color.red).frame(width: 6, height: 6)
                    Text("중단 \(stoppedCount)").font(.caption).foregroundStyle(.secondary)
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
