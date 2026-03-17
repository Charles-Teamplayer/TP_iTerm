import SwiftUI

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
        DaemonInfo(id: "com.claude.auto-restore",       displayName: "Auto Restore",      isRunning: false),
    ]
    @Published var sessionCount: Int = 0
    @Published var isInstalling: Bool = false
    @Published var isRestoring: Bool = false
    @Published var installLog: String = ""
    @Published var restoreLog: String = ""

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

        // claude-work tmux 세션이 이미 있으면 → attach만
        let sessionExists = await ShellService.runAsync("tmux has-session -t claude-work 2>/dev/null && echo YES || echo NO")
        if sessionExists.contains("YES") {
            // 클립보드에 attach 명령어 복사 + iTerm2 앞으로
            let cmd = "tmux -CC attach -t claude-work"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cmd, forType: .string)
            await ShellService.runAsync("open -a iTerm")
            restoreLog = "✅ claude-work 세션 있음\n\niTerm2에서 ⌘V 붙여넣기 하세요:\n\(cmd)"
        } else {
            // 세션 없음 → 전체 복원
            let scriptPath = NSHomeDirectory() + "/.claude/scripts/auto-restore.sh"
            restoreLog = await ShellService.runAsync("bash '\(scriptPath)' --force 2>&1")
            await ShellService.runAsync("open -a iTerm")
        }

        isRestoring = false
        await refresh()
    }

    func runInstall() async {
        guard !isInstalling else { return }
        isInstalling = true
        installLog = ""
        let scriptPath = NSHomeDirectory() + "/claude/autoRestart_ClaudeCode/install.sh"
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
                        Label("지금 복원", systemImage: "arrow.clockwise.circle.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(vm.isRestoring)

                if !vm.restoreLog.isEmpty {
                    Button("복원 로그 보기") { showRestoreLog.toggle() }
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
