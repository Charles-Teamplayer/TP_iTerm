import SwiftUI

// MARK: - Session Detail View (NavigationSplitView detail 컬럼)

struct SessionDetailView: View {
    let session: ClaudeSession?
    @ObservedObject var monitor: SessionMonitor
    @State private var showKillConfirm = false
    @State private var showStopConfirm = false
    @State private var showHideConfirm = false
    @State private var showPurgeConfirm = false
    @State private var isRestoring = false
    @State private var isPurging = false

    var body: some View {
        Group {
            if let session = session {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Circle()
                                .fill(session.isRunning ? Color.green : Color.red)
                                .frame(width: 12, height: 12)
                            Text(session.isRunning ? "Running" : "Stopped")
                                .font(.headline)
                                .foregroundStyle(session.isRunning ? .primary : Color.red)
                        }

                        GroupBox("Session Info") {
                            VStack(alignment: .leading, spacing: 8) {
                                LabeledContent("Project", value: session.projectName)
                                LabeledContent("tmux Window", value: session.windowName)
                                if session.windowIndex >= 0 && session.windowIndex != Int.max {
                                    LabeledContent("Window #", value: "\(session.windowIndex)")
                                }
                                if session.pid > 0 {
                                    LabeledContent("PID", value: "\(session.pid)")
                                }
                                if !session.tty.isEmpty {
                                    LabeledContent("TTY", value: session.tty)
                                }
                                if !session.startTime.isEmpty {
                                    LabeledContent("Started", value: session.startTime)
                                }
                                let displayDir = session.profileRoot ?? session.directory
                                if !displayDir.isEmpty {
                                    LabeledContent("Path", value: displayDir)
                                }
                            }
                            .padding(4)
                        }

                        // 액션 버튼
                        if session.isRunning {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Control").font(.caption).foregroundStyle(.secondary)
                                HStack(spacing: 10) {
                                    Button("Hide") { showHideConfirm = true }
                                        .help("Minimize iTerm2 window — process keeps running")
                                        .confirmationDialog(
                                            "Hide iTerm2 window?\nThe process will keep running.",
                                            isPresented: $showHideConfirm,
                                            titleVisibility: .visible
                                        ) {
                                            Button("Hide") { doHide(session) }
                                            Button("Cancel", role: .cancel) {}
                                        }

                                    Button("Stop") { showStopConfirm = true }
                                        .help("SIGTERM — graceful stop (restorable)")
                                        .confirmationDialog(
                                            "Stop '\(session.projectName)'?\nYou can restore it later.",
                                            isPresented: $showStopConfirm,
                                            titleVisibility: .visible
                                        ) {
                                            Button("Stop") { doStop(session) }
                                            Button("Cancel", role: .cancel) {}
                                        }

                                    Button("Force Kill", role: .destructive) { showKillConfirm = true }
                                        .help("SIGKILL — immediate force quit (use when unresponsive)")
                                        .confirmationDialog(
                                            "Force kill '\(session.projectName)'?\nThe process will be terminated immediately without saving.",
                                            isPresented: $showKillConfirm,
                                            titleVisibility: .visible
                                        ) {
                                            Button("Force Kill", role: .destructive) { doKill(session) }
                                            Button("Cancel", role: .cancel) {}
                                        }

                                    Button("Purge", role: .destructive) { showPurgeConfirm = true }
                                        .help("Force kill + remove tmux window + registry + state files")
                                }
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(session.profileRoot != nil ? "Start" : "Restore")
                                    .font(.caption).foregroundStyle(.secondary)
                                if !session.isAssigned {
                                    Label("Assign to a group first — drag to add to a group", systemImage: "tray.and.arrow.down")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .padding(.vertical, 4)
                                }
                                HStack(spacing: 10) {
                                    if let root = session.profileRoot {
                                        // 프로필 기반 세션 → 디렉토리 존재 여부로 생성/시작 분기
                                        let safeRoot = root.hasPrefix("~") ? NSHomeDirectory() + root.dropFirst() : root
                                        let dirExists = FileManager.default.fileExists(atPath: safeRoot)
                                        Button {
                                            Task {
                                                isRestoring = true
                                                await monitor.launchProfile(
                                                    name: session.projectName,
                                                    root: root,
                                                    delay: session.profileDelay,
                                                    sessionName: session.tmuxSession,
                                                    createDir: !dirExists
                                                )
                                                isRestoring = false
                                            }
                                        } label: {
                                            if isRestoring {
                                                Label(dirExists ? "Starting..." : "Creating...",
                                                      systemImage: dirExists ? "play.fill" : "folder.badge.plus")
                                            } else {
                                                Label(dirExists ? "Start" : "Create",
                                                      systemImage: dirExists ? "play.fill" : "folder.badge.plus")
                                            }
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .disabled(isRestoring || !session.isAssigned)
                                    } else {
                                        // 일반 중단 세션 → 복원
                                        Button {
                                            Task {
                                                monitor.selectedForRestore = [session.id]
                                                isRestoring = true
                                                await monitor.restoreSelected()
                                                isRestoring = false
                                            }
                                        } label: {
                                            if isRestoring {
                                                Label("Restoring...", systemImage: "arrow.clockwise")
                                            } else {
                                                Label("Restore", systemImage: "arrow.clockwise")
                                            }
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .disabled(isRestoring)
                                    }

                                    Button("Purge", role: .destructive) { showPurgeConfirm = true }
                                        .disabled(isPurging)
                                }
                            }
                        }

                        Spacer()
                    }
                    .padding()
                }
                .navigationTitle(session.projectName)
                .confirmationDialog(
                    "Permanently delete '\(session.projectName)'?",
                    isPresented: $showPurgeConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Purge", role: .destructive) { doPurge(session) }
                    Button("Cancel", role: .cancel) {}
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "cursorarrow.click")
                        .font(.system(size: 48)).foregroundStyle(.secondary)
                    Text("Select a session").font(.title3).foregroundStyle(.secondary)
                    Text("← Click a session in the list on the left").font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func doHide(_ session: ClaudeSession) {
        let tty = session.tty
        Task {
            let tmp = NSTemporaryDirectory() + "hide_\(UUID().uuidString).scpt"
            let safeTty = tty
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\r", with: "")
            let script = "tell application \"iTerm2\"\nrepeat with w in windows\nrepeat with t in tabs of w\nrepeat with s in sessions of t\ntry\nif tty of s is \"\(safeTty)\" then set miniaturized of w to true\nend try\nend repeat\nend repeat\nend repeat\nend tell"
            try? script.write(toFile: tmp, atomically: true, encoding: .utf8)
            let escapedTmp = tmp.replacingOccurrences(of: "'", with: "'\\''")
            await ShellService.runAsync("osascript '\(escapedTmp)'")
            await ShellService.runAsync("rm -f '\(escapedTmp)'")
            await monitor.refresh()
        }
    }

    private func doStop(_ session: ClaudeSession) {
        Task {
            let dir = session.directory.isEmpty ? session.projectName : session.directory
            await ShellService.intentionalStopAsync(projectDir: dir)
            await ShellService.runAsync("kill -TERM \(session.pid) 2>/dev/null")
            // 의도적 종료 → 활성화 해제
            let root = session.profileRoot ?? session.directory
            ActivationService.shared.deactivate(root: root)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await monitor.refresh()
        }
    }

    private func doKill(_ session: ClaudeSession) {
        Task {
            await ShellService.intentionalStopAsync(projectDir: session.projectName)
            await ShellService.killAsync(pid: session.pid)
            // 강제종료 → 활성화 해제
            let root = session.profileRoot ?? session.directory
            ActivationService.shared.deactivate(root: root)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await monitor.refresh()
        }
    }

    private func doPurge(_ session: ClaudeSession) {
        Task {
            isPurging = true
            let root = session.profileRoot ?? session.directory
            ActivationService.shared.deactivate(root: root)
            await monitor.purgeSession(session)
            isPurging = false
        }
    }
}
