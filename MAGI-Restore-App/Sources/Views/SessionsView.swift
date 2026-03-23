import SwiftUI

struct SessionsView: View {
    @ObservedObject var monitor: SessionMonitor
    @State private var selectedSession: ClaudeSession?
    @State private var sessionToPurge: ClaudeSession?
    @State private var sessionToKill: ClaudeSession?
    @State private var showKillConfirm = false
    @State private var showHideConfirm = false
    @State private var showPurgeConfirm = false
    @State private var isRestoring = false
    @State private var isPurging = false

    private var runningCount: Int { monitor.sessions.filter(\.isRunning).count }
    private var stoppedCount: Int { monitor.sessions.filter { !$0.isRunning }.count }

    var body: some View {
        HSplitView {
            sessionList
                .frame(minWidth: 280, idealWidth: 320)
            detailPanel
                .frame(minWidth: 300)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if stoppedCount > 0 {
                    Button(action: {
                        if monitor.selectedForRestore.isEmpty {
                            monitor.selectAllStopped()
                        } else {
                            monitor.deselectAll()
                        }
                    }) {
                        Image(systemName: monitor.selectedForRestore.isEmpty
                              ? "checkmark.circle" : "checkmark.circle.fill")
                    }
                    .help(monitor.selectedForRestore.isEmpty ? "중단된 세션 전체 선택" : "선택 해제")

                    Button(action: {
                        Task {
                            isRestoring = true
                            await monitor.restoreSelected()
                            isRestoring = false
                        }
                    }) {
                        if isRestoring {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise.circle.fill")
                        }
                    }
                    .disabled(monitor.selectedForRestore.isEmpty || isRestoring)
                    .help("선택한 세션 복원 (\(monitor.selectedForRestore.count)개)")
                }

                Button(action: { Task { await monitor.refresh() } }) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("새로고침")
            }
        }
    }

    // MARK: - Session List

    private var sessionList: some View {
        VStack(spacing: 0) {
            List {
                ForEach(monitor.sessions) { session in
                    SessionRowView(
                        session: session,
                        isSelectedForRestore: monitor.selectedForRestore.contains(session.id),
                        isSelectedDetail: selectedSession?.id == session.id,
                        onToggle: { monitor.toggleSelection(session.id) }
                    )
                    .listRowBackground(
                        selectedSession?.id == session.id
                            ? Color.accentColor.opacity(0.15)
                            : Color.clear
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { selectedSession = session }
                    .contextMenu {
                        if !session.isRunning {
                            Button {
                                Task {
                                    monitor.selectedForRestore = [session.id]
                                    isRestoring = true
                                    await monitor.restoreSelected()
                                    isRestoring = false
                                }
                            } label: {
                                Label("복원", systemImage: "arrow.clockwise")
                            }
                            .disabled(isRestoring)
                            Divider()
                        }
                        Button(role: .destructive) {
                            sessionToPurge = session
                            showPurgeConfirm = true
                        } label: {
                            Label("완전 삭제", systemImage: "trash")
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if monitor.sessions.isEmpty {
                    EmptyStateView(title: "tmux 세션 없음", systemImage: "terminal")
                }
            }
            .confirmationDialog(
                "'\(sessionToPurge?.projectName ?? "")' 세션을 완전히 삭제하시겠습니까?",
                isPresented: $showPurgeConfirm,
                titleVisibility: .visible
            ) {
                Button("완전 삭제", role: .destructive) {
                    if let s = sessionToPurge { purgeSession(s) }
                }
                Button("취소", role: .cancel) { sessionToPurge = nil }
            }

            HStack {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                Text("실행 \(runningCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                Text("중단 \(stoppedCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    // MARK: - Detail Panel

    private var detailPanel: some View {
        Group {
            if let session = selectedSession {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Circle()
                                .fill(session.isRunning ? .green : .red)
                                .frame(width: 12, height: 12)
                            Text(session.isRunning ? "실행 중" : "중단됨")
                                .font(.headline)
                                .foregroundStyle(session.isRunning ? Color.primary : Color.red)
                        }

                        GroupBox("세션 정보") {
                            VStack(alignment: .leading, spacing: 8) {
                                LabeledContent("프로젝트", value: session.projectName)
                                LabeledContent("tmux 윈도우", value: session.windowName)
                                if session.windowIndex >= 0 {
                                    LabeledContent("윈도우 #", value: "\(session.windowIndex)")
                                }
                                LabeledContent("PID", value: "\(session.pid)")
                                LabeledContent("TTY", value: session.tty)
                                if !session.startTime.isEmpty {
                                    LabeledContent("시작 시각", value: session.startTime)
                                }
                                if !session.directory.isEmpty {
                                    LabeledContent("경로", value: session.directory)
                                }
                            }
                            .padding(4)
                        }

                        HStack(spacing: 12) {
                            if session.isRunning {
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

                                Button("완전 삭제", role: .destructive) {
                                    sessionToPurge = session
                                    showPurgeConfirm = true
                                }
                                .help("프로세스 kill + tmux window 제거 + 레지스트리 삭제 + state 파일 제거")
                            } else {
                                Button {
                                    Task {
                                        monitor.selectedForRestore = [session.id]
                                        isRestoring = true
                                        await monitor.restoreSelected()
                                        isRestoring = false
                                    }
                                } label: {
                                    Label("이 세션 복원", systemImage: "arrow.clockwise")
                                }
                                .disabled(isRestoring)

                                Button("완전 삭제", role: .destructive) {
                                    sessionToPurge = session
                                    showPurgeConfirm = true
                                }
                                .help("tmux window + 레지스트리 + state 파일 완전 제거")
                                .disabled(isPurging)
                            }
                        }

                        Spacer()
                    }
                    .padding()
                }
            } else {
                EmptyStateView(title: "세션을 선택하세요", systemImage: "cursorarrow.click")
            }
        }
    }

    // MARK: - Actions

    private func hideSession(_ session: ClaudeSession) {
        let tty = session.tty
        let script = """
tell application "iTerm2"
  repeat with w in windows
    repeat with t in tabs of w
      repeat with s in sessions of t
        try
          if tty of s is "\(tty)" then set miniaturized of w to true
        end try
      end repeat
    end repeat
  end repeat
end tell
"""
        Task {
            let tmpScript = "/tmp/hide_session_\(Int.random(in: 1000...9999)).applescript"
            let writeCmd = "cat > '\(tmpScript)' << 'ASCRIPT'\n\(script)\nASCRIPT"
            await ShellService.runAsync(writeCmd)
            await ShellService.runAsync("osascript '\(tmpScript)'")
            await ShellService.runAsync("rm -f '\(tmpScript)'")
            await monitor.refresh()
        }
    }

    private func killSession(_ session: ClaudeSession) {
        Task {
            await ShellService.intentionalStopAsync(projectDir: session.projectName)
            await ShellService.killAsync(pid: session.pid)
            selectedSession = nil
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await monitor.refresh()
        }
    }

    private func purgeSession(_ session: ClaudeSession) {
        Task {
            isPurging = true
            await ShellService.purgeSessionAsync(
                pid: session.pid,
                windowName: session.windowName,
                tty: session.tty,
                projectDir: session.directory.isEmpty ? session.projectName : session.directory
            )
            selectedSession = nil
            sessionToPurge = nil
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await monitor.refresh()
            isPurging = false
        }
    }
}

// MARK: - Row View

struct SessionRowView: View {
    let session: ClaudeSession
    let isSelectedForRestore: Bool
    let isSelectedDetail: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if !session.isRunning {
                Image(systemName: isSelectedForRestore ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelectedForRestore ? .blue : .secondary)
                    .onTapGesture { onToggle() }
            } else {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(session.projectName)
                        .font(.headline)
                        .foregroundStyle(session.isRunning ? .primary : .secondary)
                    if !session.isRunning {
                        Text("중단")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.red.opacity(0.15))
                            .foregroundStyle(.red)
                            .clipShape(Capsule())
                    }
                }
                HStack {
                    Text("PID: \(session.pid)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if session.windowIndex >= 0 {
                        Text("W:\(session.windowIndex)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}
