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

        let output = await ShellService.runAsync("ps aux | grep '[c]laude' | grep -v 'MAGI\\|watchdog\\|auto-restore\\|tab-focus'")
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
        }

        isRestoring = false
        await refresh()
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
        for proj in projects {
            guard !windowSet.contains(proj.name) else { continue }
            let expandedPath = proj.path.replacingOccurrences(of: "~", with: NSHomeDirectory())
            let dirExists = await ShellService.runAsync("[ -d '\(expandedPath)' ] && echo YES || echo NO")
            guard dirExists.contains("YES") else { continue }

            await ShellService.runAsync("tmux new-window -t claude-work -n '\(proj.name)' -c '\(expandedPath)'")
            await ShellService.runAsync("tmux send-keys -t 'claude-work:\(proj.name)' 'bash ~/.claude/scripts/tab-status.sh starting \(proj.name) && unset CLAUDECODE && (claude --dangerously-skip-permissions --continue 2>/dev/null || claude --dangerously-skip-permissions)' Enter")
            restored += 1
        }

        if restored > 0 {
            return "🔧 죽은 윈도우 \(restored)개 복구 + intentional-stops 초기화"
        }
        return "✅ 모든 윈도우 정상"
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
