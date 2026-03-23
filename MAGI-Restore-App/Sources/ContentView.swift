import SwiftUI

struct ContentView: View {
    @StateObject private var monitor = SessionMonitor()
    @State private var selectedSidebar: SidebarItem? = .sessions
    @State private var selectedSession: ClaudeSession?

    enum SidebarItem: String, CaseIterable, Identifiable {
        case sessions = "세션"
        case profiles = "Smug 프로필"
        case backup = "백업"
        case system = "시스템"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .sessions: return "terminal"
            case .profiles: return "rectangle.3.group"
            case .backup: return "externaldrive"
            case .system: return "gearshape"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebarContent
                .navigationTitle("TP_iTerm")
        } detail: {
            detailContent
        }
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }

    // MARK: - Sidebar (세션 목록 포함)

    private var sidebarContent: some View {
        VStack(spacing: 0) {
            // 탭 선택
            Picker("", selection: $selectedSidebar) {
                ForEach(SidebarItem.allCases) { item in
                    Label(item.rawValue, systemImage: item.icon).tag(Optional(item))
                }
            }
            .pickerStyle(.segmented)
            .padding(8)
            .labelsHidden()

            Divider()

            if selectedSidebar == .sessions {
                // 세션 목록 — List(selection:) canonical pattern
                List(monitor.sessions, selection: $selectedSession) { session in
                    sessionRow(session)
                        .tag(session)
                }
                .listStyle(.plain)
                .overlay {
                    if monitor.sessions.isEmpty {
                        EmptyStateView(title: "tmux 세션 없음", systemImage: "terminal")
                    }
                }

                Divider()
                statusBar
            } else {
                Spacer()
                Text(selectedSidebar?.rawValue ?? "")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if selectedSidebar == .sessions {
                    sessionToolbar
                }
            }
        }
    }

    private func sessionRow(_ session: ClaudeSession) -> some View {
        HStack(spacing: 8) {
            if session.isRunning {
                Circle().fill(Color.green).frame(width: 8, height: 8)
            } else {
                Circle().fill(Color.red).frame(width: 8, height: 8)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(session.projectName)
                        .font(.headline)
                        .foregroundStyle(session.isRunning ? .primary : .secondary)
                    if !session.isRunning {
                        Text("중단").font(.caption2)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.red.opacity(0.15)).foregroundStyle(.red)
                            .clipShape(Capsule())
                    }
                }
                Text("PID: \(session.pid)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var statusBar: some View {
        let runningCount = monitor.sessions.filter(\.isRunning).count
        let stoppedCount = monitor.sessions.filter { !$0.isRunning }.count
        return HStack(spacing: 8) {
            Circle().fill(Color.green).frame(width: 8, height: 8)
            Text("실행 \(runningCount)").font(.caption).foregroundStyle(.secondary)
            Circle().fill(Color.red).frame(width: 8, height: 8)
            Text("중단 \(stoppedCount)").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 6).background(.bar)
    }

    @ViewBuilder
    private var sessionToolbar: some View {
        let stoppedCount = monitor.sessions.filter { !$0.isRunning }.count
        if stoppedCount > 0 {
            Button { Task { await monitor.restoreSelected() } } label: {
                Image(systemName: "arrow.clockwise.circle.fill")
            }
            .disabled(monitor.selectedForRestore.isEmpty)
            .help("선택한 세션 복원")
        }
        Button { Task { await monitor.refresh() } } label: {
            Image(systemName: "arrow.clockwise")
        }
        .help("새로고침")
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailContent: some View {
        switch selectedSidebar {
        case .sessions:
            SessionDetailView(session: selectedSession, monitor: monitor)
                .id(selectedSession?.id)
        case .profiles:
            ProfilesView().navigationTitle("Smug 프로필")
        case .backup:
            BackupView().navigationTitle("백업")
        case .system:
            SystemView().navigationTitle("시스템")
        case nil:
            EmptyStateView(title: "항목을 선택하세요", systemImage: "sidebar.left")
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
