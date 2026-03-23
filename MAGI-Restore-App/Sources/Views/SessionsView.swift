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

                        // 액션 버튼
                        if session.isRunning {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("제어").font(.caption).foregroundStyle(.secondary)
                                HStack(spacing: 10) {
                                    Button("숨기기") { showHideConfirm = true }
                                        .help("iTerm2 창 최소화 — 프로세스는 계속 실행")
                                        .confirmationDialog(
                                            "iTerm2 창을 숨기시겠습니까?\n프로세스는 계속 실행됩니다",
                                            isPresented: $showHideConfirm,
                                            titleVisibility: .visible
                                        ) {
                                            Button("숨기기") { doHide(session) }
                                            Button("취소", role: .cancel) {}
                                        }

                                    Button("종료") { showStopConfirm = true }
                                        .help("SIGTERM — 정상 종료 요청 (나중에 복원 가능)")
                                        .confirmationDialog(
                                            "'\(session.projectName)' 세션을 종료하시겠습니까?\n정상 종료 후 나중에 복원할 수 있습니다",
                                            isPresented: $showStopConfirm,
                                            titleVisibility: .visible
                                        ) {
                                            Button("종료") { doStop(session) }
                                            Button("취소", role: .cancel) {}
                                        }

                                    Button("강제종료", role: .destructive) { showKillConfirm = true }
                                        .help("SIGKILL — 즉시 강제 종료 (응답 없을 때 사용)")
                                        .confirmationDialog(
                                            "'\(session.projectName)' 세션을 강제종료하시겠습니까?\n저장 없이 즉시 종료됩니다",
                                            isPresented: $showKillConfirm,
                                            titleVisibility: .visible
                                        ) {
                                            Button("강제종료", role: .destructive) { doKill(session) }
                                            Button("취소", role: .cancel) {}
                                        }

                                    Button("완전삭제", role: .destructive) { showPurgeConfirm = true }
                                        .help("강제종료 + tmux window 제거 + 레지스트리 + state 파일 삭제")
                                }
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("복원").font(.caption).foregroundStyle(.secondary)
                                HStack(spacing: 10) {
                                    Button {
                                        Task {
                                            monitor.selectedForRestore = [session.id]
                                            isRestoring = true
                                            await monitor.restoreSelected()
                                            isRestoring = false
                                        }
                                    } label: {
                                        if isRestoring {
                                            Label("복원 중...", systemImage: "arrow.clockwise")
                                        } else {
                                            Label("이 세션 복원", systemImage: "arrow.clockwise")
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(isRestoring)

                                    Button("완전 삭제", role: .destructive) { showPurgeConfirm = true }
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
                    "'\(session.projectName)' 세션을 완전히 삭제하시겠습니까?",
                    isPresented: $showPurgeConfirm,
                    titleVisibility: .visible
                ) {
                    Button("완전 삭제", role: .destructive) { doPurge(session) }
                    Button("취소", role: .cancel) {}
                }
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

    private func doStop(_ session: ClaudeSession) {
        Task {
            await ShellService.intentionalStopAsync(projectDir: session.projectName)
            await ShellService.runAsync("kill -TERM \(session.pid) 2>/dev/null")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
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
