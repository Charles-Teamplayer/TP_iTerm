import SwiftUI
import AppKit

struct DaemonInfo: Identifiable {
    let id: String        // launchctl label
    let displayName: String
    var isRunning: Bool
}

@MainActor
final class SystemViewModel: ObservableObject {
    @Published var daemons: [DaemonInfo] = [
        DaemonInfo(id: "com.claude.watchdog",           displayName: "Watchdog",          isRunning: false),
        DaemonInfo(id: "com.claude.tab-focus-monitor",  displayName: "Tab Focus Monitor", isRunning: false),
        DaemonInfo(id: "com.claude.auto-restore",       displayName: "Auto Restore (일회성)", isRunning: false),
    ]
    @Published var sessionCount: Int = 0
    @Published var isInstalling: Bool = false
    @Published var isRestoring: Bool = false
    @Published var installLog: String = ""
    @Published var restoreLog: String = ""
    @Published var tmuxSessionExists: Bool = false

    func refresh() async {
        var updated = daemons
        for i in updated.indices {
            let label = updated[i].id
            let result = await ShellService.runAsync("launchctl print gui/\(getuid())/\(label) 2>/dev/null")
            updated[i].isRunning = result.contains("state = running")
        }
        daemons = updated

        let output = await ShellService.runAsync("ps aux | grep '[c]laude' | grep -v 'TP.iTerm.Restore\\|TP_iTerm_Restore\\|watchdog\\|auto-restore\\|tab-focus'")
        sessionCount = output.isEmpty ? 0 : output.components(separatedBy: "\n").filter { !$0.isEmpty }.count

        let tmuxCheck = await ShellService.runAsync("tmux has-session -t claude-work 2>/dev/null && echo YES || echo NO")
        tmuxSessionExists = tmuxCheck.contains("YES")
    }

    func toggle(daemon: DaemonInfo) {
        let plistPath = NSHomeDirectory() + "/Library/LaunchAgents/\(daemon.id).plist"
        Task {
            if daemon.isRunning {
                await ShellService.runAsync("launchctl bootout gui/\(getuid())/\(daemon.id)")
            } else {
                await ShellService.runAsync("launchctl bootstrap gui/\(getuid()) '\(plistPath)'")
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            await refresh()
        }
    }

    func runRestore() async {
        guard !isRestoring else { return }
        isRestoring = true
        restoreLog = ""

        let sessionExists = await ShellService.runAsync("tmux has-session -t claude-work 2>/dev/null && echo YES || echo NO")

        if sessionExists.contains("YES") {
            let repairResult = await repairDeadWindows()
            restoreLog = repairResult
        } else {
            let scriptPath = NSHomeDirectory() + "/.claude/scripts/auto-restore.sh"
            restoreLog = await ShellService.runAsync("bash '\(scriptPath)' --force 2>&1")
            // 세션 새로 생성됐으니 iTerm2에 attach 명령 전송 (딜레이 후)
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }

        // tmux 복원 후 iTerm2 현재 창에 attach 명령 전송
        await attachTmuxToITerm()

        // attach 후 4초 대기 → 탭 색상 복원
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        let restoreColorScript = NSHomeDirectory() + "/.claude/scripts/restore-tab-colors.sh"
        await ShellService.runAsync("bash '\(restoreColorScript)'")

        isRestoring = false
        await refresh()
    }

    private func attachTmuxToITerm() async {
        // 새 탭을 열어서 attach — 현재 탭(Claude Code 등)에 명령이 섞이는 것 방지
        let script = """
        osascript -e 'tell application "iTerm2"
            tell current window
                create tab with default profile
                tell current session of current tab
                    write text "tmux -CC attach -t claude-work"
                end tell
            end tell
        end tell'
        """
        await ShellService.runAsync(script)
    }

    private func repairDeadWindows() async -> String {
        let projects: [(name: String, path: String)] = [
            ("imsms", "~/claude/TP_newIMSMS"),
            ("imsms-agent", "~/claude/TP_newIMSMS_Agent"),
            ("mdm", "~/claude/TP_MDM"),
            ("tesla-lvds", "~/claude/TP_TESLA_LVDS"),
            ("tesla-dashboard", "~/ralph-claude-code/TESLA_Status_Dashboard"),
            ("mindmap", "~/claude/TP_MindMap_AutoCC"),
            ("sj-mindmap", "~/SJ_MindMap"),
            ("imessage", "~/claude/TP_A.iMessage_standalone_01067051080"),
            ("btt", "~/claude/TP_BTT"),
            ("infra", "~/claude/TP_Infra_reduce_Project"),
            ("skills", "~/claude/TP_skills"),
            ("appletv", "~/claude/AppleTV_ScreenSaver.app"),
            ("imsms-web", "~/claude/imsms.im-website"),
            ("auto-restart", "~/claude/TP_iTerm"),
        ]

        let existingWindows = await ShellService.runAsync("tmux list-windows -t claude-work -F '#{window_name}' 2>/dev/null")
        let windowSet = Set(existingWindows.components(separatedBy: "\n").filter { !$0.isEmpty })

        // "지금 복원" 버튼은 사용자의 명시적 의도이므로 intentional-stops를 초기화
        let stopsFile = NSHomeDirectory() + "/.claude/intentional-stops.json"
        let resetJson = "{\"stops\":[],\"last_updated\":\"\(ISO8601DateFormatter().string(from: Date()))\"}"
        try? resetJson.write(toFile: stopsFile, atomically: true, encoding: .utf8)

        var restored = 0
        var alreadyRunning = 0
        for proj in projects {
            let expandedPath = proj.path.replacingOccurrences(of: "~", with: NSHomeDirectory())
            let dirExists = await ShellService.runAsync("[ -d '\(expandedPath)' ] && echo YES || echo NO")
            guard dirExists.contains("YES") else { continue }

            if windowSet.contains(proj.name) {
                // 창은 있지만 claude가 실행 중인지 확인 (TTY 기반 + pgrep fallback)
                let paneInfo = await ShellService.runAsync(
                    "tmux display-message -t 'claude-work:\(proj.name)' -p '#{pane_tty}|#{pane_pid}' 2>/dev/null"
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                let infoParts = paneInfo.components(separatedBy: "|")
                let paneTty = infoParts.count > 0 ? infoParts[0] : ""
                let panePid = infoParts.count > 1 ? infoParts[1] : ""

                // 방법1: TTY 기반 (손자 프로세스도 탐지)
                let ttyBase = paneTty.replacingOccurrences(of: "/dev/", with: "")
                var claudeRunning = ttyBase.isEmpty ? "" : await ShellService.runAsync(
                    "ps -o pid,command -t '\(ttyBase)' 2>/dev/null | grep '[c]laude' | head -1"
                ).trimmingCharacters(in: .whitespacesAndNewlines)

                // 방법2: pgrep fallback (TTY 실패 시)
                if claudeRunning.isEmpty && !panePid.isEmpty {
                    claudeRunning = await ShellService.runAsync(
                        "pgrep -P \(panePid) -f claude 2>/dev/null"
                    ).trimmingCharacters(in: .whitespacesAndNewlines)
                }

                if !claudeRunning.isEmpty {
                    alreadyRunning += 1
                    continue  // claude 실행 중 → 건너뜀
                }

                // claude 죽어있음 → 재시작 명령 전송
                await ShellService.runAsync(
                    "tmux send-keys -t 'claude-work:\(proj.name)' 'bash ~/.claude/scripts/tab-status.sh starting \(proj.name) && unset CLAUDECODE && (claude --dangerously-skip-permissions --continue 2>/dev/null || claude --dangerously-skip-permissions)' Enter"
                )
                restored += 1
            } else {
                // 창 없음 → 새로 생성
                await ShellService.runAsync("tmux new-window -t claude-work -n '\(proj.name)' -c '\(expandedPath)'")
                await ShellService.runAsync("tmux set-window-option -t 'claude-work:\(proj.name)' automatic-rename off 2>/dev/null")
                await ShellService.runAsync(
                    "tmux send-keys -t 'claude-work:\(proj.name)' 'bash ~/.claude/scripts/tab-status.sh starting \(proj.name) && unset CLAUDECODE && (claude --dangerously-skip-permissions --continue 2>/dev/null || claude --dangerously-skip-permissions)' Enter"
                )
                restored += 1
            }
        }

        if restored > 0 {
            return "🔧 \(restored)개 복구, \(alreadyRunning)개 실행 중 → attach + 탭 색상 자동 복원"
        }
        return "✅ 모든 세션 정상 (\(alreadyRunning)개) → attach + 탭 색상 자동 복원"
    }

    func runInstall() async {
        guard !isInstalling else { return }
        isInstalling = true
        installLog = ""
        let scriptPath = NSHomeDirectory() + "/claude/TP_iTerm/install.sh"
        let result = await ShellService.runAsync("bash '\(scriptPath)' 2>&1")
        installLog = result
        isInstalling = false
        await refresh()
    }
}

struct SystemView: View {
    @StateObject private var vm = SystemViewModel()
    @State private var showInstallLog = false
    @State private var showRestoreLog = false
    var body: some View {
        Form {
            Section("Claude 세션") {
                HStack {
                    Text("실행 중인 세션")
                    Spacer()
                    Text("\(vm.sessionCount)개")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            Section("데몬 상태") {
                ForEach($vm.daemons) { $daemon in
                    HStack {
                        Circle()
                            .fill(daemon.isRunning ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(daemon.displayName)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { daemon.isRunning },
                            set: { _ in vm.toggle(daemon: daemon) }
                        ))
                        .labelsHidden()
                    }
                }
            }

            Section("세션 복원") {
                Button(action: {
                    Task { await vm.runRestore() }
                }) {
                    if vm.isRestoring {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.8)
                            Text("복원 중...")
                        }
                    } else {
                        Label("세션 복원", systemImage: "arrow.clockwise.circle.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(vm.isRestoring)

                if !vm.restoreLog.isEmpty {
                    Text(vm.restoreLog)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                    Button("전체 로그 보기") { showRestoreLog = true }
                        .buttonStyle(.link)
                }
            }

            Section("업데이트") {
                Button(action: {
                    Task { await vm.runInstall() }
                }) {
                    if vm.isInstalling {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.8)
                            Text("설치 중...")
                        }
                    } else {
                        Text("업데이트 설치")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.isInstalling)

                if !vm.installLog.isEmpty {
                    Button("설치 로그 보기") { showInstallLog.toggle() }
                        .buttonStyle(.link)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { Task { await vm.refresh() } }
        .sheet(isPresented: $showRestoreLog) {
            VStack(alignment: .leading) {
                HStack {
                    Text("복원 로그")
                        .font(.headline)
                    Spacer()
                    Button("닫기") { showRestoreLog = false }
                }
                .padding()
                Divider()
                ScrollView {
                    Text(vm.restoreLog)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
            .frame(width: 500, height: 400)
        }
        .sheet(isPresented: $showInstallLog) {
            VStack(alignment: .leading) {
                HStack {
                    Text("설치 로그")
                        .font(.headline)
                    Spacer()
                    Button("닫기") { showInstallLog = false }
                }
                .padding()
                Divider()
                ScrollView {
                    Text(vm.installLog)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
            .frame(width: 500, height: 400)
        }
    }
}
