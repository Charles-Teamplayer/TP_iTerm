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
    @Published var installLog: String = ""

    func refresh() {
        for i in daemons.indices {
            let label = daemons[i].id
            let result = ShellService.run("launchctl print gui/\(getuid())/\(label) 2>/dev/null")
            daemons[i].isRunning = result.contains("state = running")
        }

        let output = ShellService.run("ps aux | grep '[c]laude' | grep -v 'MAGI\\|watchdog\\|auto-restore\\|tab-focus'")
        sessionCount = output.isEmpty ? 0 : output.components(separatedBy: "\n").filter { !$0.isEmpty }.count
    }

    func toggle(daemon: DaemonInfo) {
        let plistPath = NSHomeDirectory() + "/Library/LaunchAgents/\(daemon.id).plist"
        if daemon.isRunning {
            let _ = ShellService.run("launchctl bootout gui/\(getuid())/\(daemon.id)")
        } else {
            let _ = ShellService.run("launchctl bootstrap gui/\(getuid()) '\(plistPath)'")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.refresh() }
    }

    func runInstall() async {
        guard !isInstalling else { return }
        isInstalling = true
        installLog = ""
        let scriptPath = NSHomeDirectory() + "/claude/autoRestart_ClaudeCode/install.sh"
        let result = await ShellService.runAsync("bash '\(scriptPath)' 2>&1")
        installLog = result
        isInstalling = false
        refresh()
    }
}

struct SystemView: View {
    @StateObject private var vm = SystemViewModel()
    @State private var showInstallLog = false

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
        .onAppear { vm.refresh() }
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
