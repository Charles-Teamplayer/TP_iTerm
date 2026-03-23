import SwiftUI

// MARK: - Session Detail View (NavigationSplitView detail 컬럼)

struct SessionDetailView: View {
    let session: ClaudeSession?
    @ObservedObject var monitor: SessionMonitor
    @State private var showKillConfirm = false
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
                            Text(session.isRunning ? "실행 중" : "중단됨")
                                .font(.headline)
                                .foregroundStyle(session.isRunning ? .primary : Color.red)
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
                                Button("Hide") { showHideConfirm = true }
                                    .confirmationDialog(
                                        "iTerm2 창을 최소화하시겠습니까?",
                                        isPresented: $showHideConfirm,
                                        titleVisibility: .visible
                                    ) {
                                        Button("최소화") { doHide(session) }
                                        Button("취소", role: .cancel) {}
                                    }

                                Button("Kill", role: .destructive) { showKillConfirm = true }
                                    .confirmationDialog(
                                        "PID \(session.pid) 세션을 종료하시겠습니까?",
                                        isPresented: $showKillConfirm,
                                        titleVisibility: .visible
                                    ) {
                                        Button("종료", role: .destructive) { doKill(session) }
                                        Button("취소", role: .cancel) {}
                                    }

                                Button("완전 삭제", role: .destructive) { showPurgeConfirm = true }
                                    .help("프로세스 kill + tmux window + 레지스트리 + state 파일")

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

                                Button("완전 삭제", role: .destructive) { showPurgeConfirm = true }
                                    .disabled(isPurging)
                            }
                        }
                        .confirmationDialog(
                            "'\(session.projectName)' 세션을 완전히 삭제하시겠습니까?",
                            isPresented: $showPurgeConfirm,
                            titleVisibility: .visible
                        ) {
                            Button("완전 삭제", role: .destructive) { doPurge(session) }
                            Button("취소", role: .cancel) {}
                        }

                        Spacer()
                    }
                    .padding()
                }
                .navigationTitle(session.projectName)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "cursorarrow.click")
                        .font(.system(size: 48)).foregroundStyle(.secondary)
                    Text("세션을 선택하세요").font(.title3).foregroundStyle(.secondary)
                    Text("← 왼쪽 목록에서 세션을 클릭하세요").font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func doHide(_ session: ClaudeSession) {
        let tty = session.tty
        Task {
            let tmp = "/tmp/hide_\(Int.random(in: 1000...9999)).scpt"
            let script = "tell application \"iTerm2\"\nrepeat with w in windows\nrepeat with t in tabs of w\nrepeat with s in sessions of t\ntry\nif tty of s is \"\(tty)\" then set miniaturized of w to true\nend try\nend repeat\nend repeat\nend repeat\nend tell"
            try? script.write(toFile: tmp, atomically: true, encoding: .utf8)
            await ShellService.runAsync("osascript '\(tmp)'")
            await ShellService.runAsync("rm -f '\(tmp)'")
            await monitor.refresh()
        }
    }

    private func doKill(_ session: ClaudeSession) {
        Task {
            await ShellService.intentionalStopAsync(projectDir: session.projectName)
            await ShellService.killAsync(pid: session.pid)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await monitor.refresh()
        }
    }

    private func doPurge(_ session: ClaudeSession) {
        Task {
            isPurging = true
            await ShellService.purgeSessionAsync(
                pid: session.pid,
                windowName: session.windowName,
                tty: session.tty,
                projectDir: session.directory.isEmpty ? session.projectName : session.directory
            )
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await monitor.refresh()
            isPurging = false
        }
    }
}
