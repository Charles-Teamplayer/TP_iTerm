import SwiftUI

struct SessionsView: View {
    @ObservedObject var monitor: SessionMonitor
    @State private var selectedSession: ClaudeSession?
    @State private var showKillConfirm = false
    @State private var showHideConfirm = false

    var body: some View {
        HSplitView {
            sessionList
                .frame(minWidth: 260, idealWidth: 300)
            detailPanel
                .frame(minWidth: 300)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { Task { await monitor.refresh() } }) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("새로고침")
            }
        }
    }

    private var sessionList: some View {
        List(monitor.sessions, selection: $selectedSession) { session in
            SessionRowView(session: session)
                .tag(session as ClaudeSession?)
        }
        .listStyle(.sidebar)
        .overlay {
            if monitor.sessions.isEmpty {
                EmptyStateView(title: "실행 중인 세션 없음", systemImage: "terminal")
            }
        }
    }

    private var detailPanel: some View {
        Group {
            if let session = selectedSession {
                VStack(alignment: .leading, spacing: 16) {
                    GroupBox("세션 정보") {
                        VStack(alignment: .leading, spacing: 8) {
                            LabeledContent("프로젝트", value: session.projectName)
                            LabeledContent("PID", value: "\(session.pid)")
                            LabeledContent("TTY", value: session.tty)
                            LabeledContent("시작 시각", value: session.startTime)
                        }
                        .padding(4)
                    }

                    HStack(spacing: 12) {
                        Button("Hide") {
                            showHideConfirm = true
                        }
                        .confirmationDialog(
                            "iTerm2 창을 최소화하시겠습니까?",
                            isPresented: $showHideConfirm,
                            titleVisibility: .visible
                        ) {
                            Button("최소화") { hideSession(session) }
                            Button("취소", role: .cancel) {}
                        }

                        Button("Kill", role: .destructive) {
                            showKillConfirm = true
                        }
                        .confirmationDialog(
                            "PID \(session.pid) 세션을 종료하시겠습니까?",
                            isPresented: $showKillConfirm,
                            titleVisibility: .visible
                        ) {
                            Button("종료", role: .destructive) { killSession(session) }
                            Button("취소", role: .cancel) {}
                        }
                    }

                    Spacer()
                }
                .padding()
            } else {
                EmptyStateView(title: "세션을 선택하세요", systemImage: "cursorarrow.click")
            }
        }
    }

    private func hideSession(_ session: ClaudeSession) {
        let tty = session.tty
        let script = "tell application \"iTerm2\" to repeat with w in windows\nrepeat with t in tabs of w\nrepeat with s in sessions of t\nif tty of s is \"\(tty)\" then set miniaturized of w to true\nend repeat\nend repeat\nend repeat\nend tell"
        Task {
            await ShellService.runAsync("osascript <<'APPLESCRIPT'\n\(script)\nAPPLESCRIPT")
            await monitor.refresh()
        }
    }

    private func killSession(_ session: ClaudeSession) {
        ShellService.intentionalStop(projectDir: session.projectName)
        ShellService.kill(pid: session.pid)
        selectedSession = nil
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await monitor.refresh()
        }
    }
}

struct SessionRowView: View {
    let session: ClaudeSession

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(session.projectName)
                .font(.headline)
            HStack {
                Text("PID: \(session.pid)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.secondary)
                Text(session.tty)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
