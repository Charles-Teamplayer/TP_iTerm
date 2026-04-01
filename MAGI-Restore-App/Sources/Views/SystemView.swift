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
        DaemonInfo(id: "com.claude.auto-restore",       displayName: "Auto Restore (one-shot)", isRunning: false),
    ]
    @Published var sessionCount: Int = 0
    @Published var isInstalling: Bool = false
    @Published var isRestoring: Bool = false
    @Published var installLog: String = ""
    @Published var restoreLog: String = ""
    @Published var tmuxSessionExists: Bool = false

    private var refreshTimer: Timer?

    private func shellq(_ s: String) -> String { ShellService.shellq(s) }

    func startAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func refresh() async {
        var updated = daemons
        for i in updated.indices {
            let label = updated[i].id
            // launchctl list: 등록(loaded)되어 있으면 표시됨 — 일회성 데몬도 정상 감지
            let result = await ShellService.runAsync("launchctl list 2>/dev/null | grep -c \(shellq(label))")
            updated[i].isRunning = (Int(result.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0
        }
        daemons = updated

        // 모든 active 세션에서 claude 프로세스 카운트
        let groupsRaw = await ShellService.runAsync("""
            python3 -c "
import json, os
try:
    groups = json.load(open(os.path.expanduser('~/.claude/window-groups.json')))
    for g in groups:
        sn = g.get('sessionName','')
        if not g.get('isWaitingList', False) and sn and sn != '__waiting__':
            print(sn)
except: pass
" 2>/dev/null
""")
        let activeSessions = groupsRaw.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let checkSessions = activeSessions.isEmpty ? ["claude-work"] : activeSessions

        var count = 0
        var anySessionExists = false
        for sname in checkSessions {
            let escaped = sname.replacingOccurrences(of: "'", with: "'\\''")
            let hasSession = await ShellService.runAsync("tmux has-session -t '\(escaped)' 2>/dev/null && echo YES || echo NO")
            if hasSession.contains("YES") { anySessionExists = true }
            // BUG#32 fix: display-message -t session:window.name → tmux parses '.' as pane sep
            // → list-windows combined query (index|name|pane_tty) — same fix as BUG#28 in TPiTermRestoreApp
            let windowInfo = await ShellService.runAsync(
                "tmux list-windows -t '\(escaped)' -F '#{window_index}\u{01}#{window_name}\u{01}#{pane_tty}' 2>/dev/null"
            )
            for line in windowInfo.components(separatedBy: "\n").filter({ !$0.isEmpty }) {
                let parts = line.components(separatedBy: "\u{01}")
                guard parts.count >= 3 else { continue }
                let winName = parts[1]
                guard winName != "monitor" && winName != "_init_" else { continue }
                let paneTty = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
                let ttyBase = paneTty.replacingOccurrences(of: "/dev/", with: "")
                guard !ttyBase.isEmpty else { continue }
                let procs = await ShellService.runAsync("ps -o command -t \(shellq(ttyBase)) 2>/dev/null | grep '[c]laude' | head -1")
                if !procs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { count += 1 }
            }
        }
        sessionCount = count
        tmuxSessionExists = anySessionExists
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
        restoreLog = "🔴 모든 세션 종료 중..."

        // 1. 모든 tmux linked sessions (-vN) 제거
        let linkedKill = await ShellService.runAsync("""
            tmux list-sessions -F '#{session_name}' 2>/dev/null \
            | grep -E '.*-v[0-9]+' \
            | while read s; do tmux kill-session -t "$s" 2>/dev/null; echo "killed: $s"; done
        """)
        restoreLog += linkedKill.isEmpty ? "\n  linked sessions: 없음" : "\n" + linkedKill.prefix(300)

        // 2. 메인 tmux 세션 제거 (window-groups.json 기반)
        let mainKill = await ShellService.runAsync(
            "python3 -c \"\nimport json,os,subprocess\ntry:\n  gs=json.load(open(os.path.expanduser('~/.claude/window-groups.json')))\n  [subprocess.run(['tmux','kill-session','-t',g['sessionName']]) for g in gs if not g.get('isWaitingList') and g.get('sessionName','')]\nexcept: pass\n\" 2>/dev/null"
        )
        restoreLog += mainKill.isEmpty ? "\n  main sessions: 없음" : "\n" + mainKill.prefix(200)

        // 3. orphan claude 프로세스 정리 (현재 앱 PID + protected-claude-pids 제외)
        let myPid = ProcessInfo.processInfo.processIdentifier
        let claudeKill = await ShellService.runAsync("""
            PROTECTED=$(cat "$HOME/.claude/protected-claude-pids" 2>/dev/null | tr '\\n' ' ')
            ps -A -o pid=,comm= 2>/dev/null | awk '/[c]laude$/{print $1}' | while read pid; do
                if [ "$pid" = "\(myPid)" ]; then continue; fi
                if echo " $PROTECTED " | grep -qF " $pid "; then
                    echo "protected: $pid (skip)"
                    continue
                fi
                kill -TERM "$pid" 2>/dev/null && echo "term: $pid" || true
            done
        """)
        restoreLog += "\n🔪 Claude 프로세스 종료: " + (claudeKill.isEmpty ? "없음" : claudeKill.prefix(200))

        // 4. cooldown 파일 삭제 (30분 제한 우회)
        await ShellService.runAsync("rm -f '$HOME/.claude/logs/.auto-restore-lastrun' 2>/dev/null; true")
        restoreLog += "\n🗑️ 쿨다운 초기화"

        // 5. 2초 대기 후 --force 복원
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        restoreLog += "\n⏳ auto-restore.sh --force 실행 중..."
        let scriptPath = NSHomeDirectory() + "/.claude/scripts/auto-restore.sh"
        let result = await ShellService.runAsync("bash '\(scriptPath)' --force 2>&1")
        restoreLog += "\n" + (result.isEmpty ? "⚠️ 출력 없음" : String(result.prefix(500)))
        try? await Task.sleep(nanoseconds: 5_000_000_000)

        // 6. iTerm2 연결
        await attachTmuxToITerm()

        // 7. 탭 색상 복원
        restoreLog += "\n⏳ 탭 색상 복원 중..."
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        let restoreColorScript = NSHomeDirectory() + "/.claude/scripts/restore-tab-colors.sh"
        let colorResult = await ShellService.runAsync("bash '\(restoreColorScript)' 2>&1")
        if colorResult.lowercased().contains("error") {
            restoreLog += "\n⚠️ 색상 복원 일부 실패"
        } else if let range = colorResult.range(of: #"(\d+)"#, options: .regularExpression) {
            let count = colorResult[range]
            restoreLog += "\n🎨 탭 색상 \(count)개 복원"
        } else {
            restoreLog += "\n✅ 복원 완료"
        }

        isRestoring = false
        await refresh()
    }

    private func attachTmuxToITerm() async {
        // BUG-CC-MODE fix: control-mode 검사 제거 → plain attach(linked session) 방식에서 항상 미감지 문제 수정
        // linked sessions(-vN)에 non-monitor 클라이언트가 있으면 이미 연결됨으로 판단
        let alreadyAttached = await ShellService.runAsync("""
            python3 -c "
import json, os, subprocess
try:
    groups = json.load(open(os.path.expanduser('~/.claude/window-groups.json')))
    for g in groups:
        sn = g.get('sessionName','')
        if not g.get('isWaitingList', False) and sn and sn != '__waiting__':
            sessions_to_check = [sn]
            ls_r = subprocess.run(['tmux','list-sessions','-F','#{session_name}'], capture_output=True, text=True)
            for s in ls_r.stdout.strip().split('\\n'):
                if s.startswith(sn + '-v'):
                    sessions_to_check.append(s)
            for sess in sessions_to_check:
                r = subprocess.run(['tmux','list-clients','-t',sess,'-F','#{window_name}'], capture_output=True, text=True)
                for line in r.stdout.strip().split('\\n'):
                    wname = line.strip()
                    if wname and wname != 'monitor':
                        print('YES')
                        exit(0)
except: pass
" 2>/dev/null
""")

        if alreadyAttached.contains("YES") {
            restoreLog += "\n✅ iTerm2 이미 연결됨 (비-monitor 탭 확인)"
            return
        }

        restoreLog += "\n🔗 iTerm2 새 탭으로 연결 중..."

        // BUG-CC-MODE fix: tmux -CC attach 대신 linked session 방식 사용 (현재 시스템 표준)
        // 첫 번째 active 세션의 첫 번째 non-monitor 창에 linked session 생성 후 attach
        let firstSession = await ShellService.runAsync("""
            python3 -c "
import json, os
try:
    groups = json.load(open(os.path.expanduser('~/.claude/window-groups.json')))
    for g in groups:
        sn = g.get('sessionName','')
        if not g.get('isWaitingList', False) and sn and sn != '__waiting__':
            import subprocess
            r = subprocess.run(['tmux','has-session','-t',sn], capture_output=True)
            if r.returncode == 0:
                print(sn)
                break
except: pass
" 2>/dev/null
""").trimmingCharacters(in: .whitespacesAndNewlines)
        let targetSession = firstSession.isEmpty ? "claude-work" : firstSession
        let esc = ShellService.shellq(targetSession)

        // 첫 번째 non-monitor 창 인덱스 조회 → linked session 생성 후 attach
        let firstWinIdx = await ShellService.runAsync(
            "tmux list-windows -t \(esc) -F '#{window_index}|#{window_name}' 2>/dev/null | awk -F'|' '$2!=\"monitor\" && $2!=\"_init_\"{print $1; exit}'"
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let winIdx = firstWinIdx.isEmpty ? "0" : firstWinIdx
        let linkedName = "\(targetSession)-v\(winIdx)"
        let cmd = "/bin/bash -lc 'tmux has-session -t \(linkedName) 2>/dev/null || tmux new-session -d -s \(linkedName) -t \(targetSession) 2>/dev/null; tmux select-window -t \(linkedName):\(winIdx) 2>/dev/null; tmux attach-session -t \(linkedName); exec /bin/zsh -l'"

        let script = "osascript << '__APPLES__'\ntell application \"iTerm2\"\n    activate\n    create window with default profile command \"\(cmd)\"\nend tell\n__APPLES__"
        let result = await ShellService.runAsync(script)
        if result.lowercased().contains("error") {
            restoreLog += "\n⚠️ iTerm2 연결 실패: \(String(result.prefix(120)))"
        }
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
    @ObservedObject var monitor: SessionMonitor
    @StateObject private var vm = SystemViewModel()
    @State private var showInstallLog = false
    @State private var showRestoreLog = false
    @State private var showForceRestoreConfirm = false
    // 직접 입력 토글
    @State private var useCustomDelay = false
    @State private var useCustomAttempts = false
    @State private var customDelayInput = ""
    @State private var customAttemptsInput = ""
    @State private var useCustomSyncInterval = false
    @State private var customSyncIntervalInput = ""
    @State private var syncIntervalUnit: SyncUnit = .seconds

    enum SyncUnit: String, CaseIterable, Identifiable {
        case seconds = "sec"
        case minutes = "min"
        var id: String { rawValue }
        func toSeconds(_ v: Int) -> Int { self == .minutes ? v * 60 : v }
        func fromSeconds(_ s: Int) -> Int { self == .minutes ? s / 60 : s }
    }

    var body: some View {
        Form {
            // ── Auto-Restart ──
            Section("Auto-Restart") {
                Toggle("Auto-restart on crash", isOn: $monitor.restoreSettings.autoRestore)
                    .onChange(of: monitor.restoreSettings.autoRestore) { _, _ in monitor.restoreSettings.save() }

                if monitor.restoreSettings.autoRestore {
                    HStack {
                        Text("Restart delay").foregroundStyle(.secondary)
                        Spacer()
                        if !useCustomDelay {
                            Picker("", selection: $monitor.restoreSettings.delaySeconds) {
                                ForEach(RestoreSettings.delayPresets, id: \.seconds) { p in
                                    Text(p.label).tag(p.seconds)
                                }
                            }
                            .pickerStyle(.menu).labelsHidden().frame(width: 80)
                            .onChange(of: monitor.restoreSettings.delaySeconds) { _, _ in monitor.restoreSettings.save() }
                        } else {
                            HStack(spacing: 4) {
                                TextField("s", text: $customDelayInput)
                                    .frame(width: 60).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                                    .onSubmit {
                                        if let v = Int(customDelayInput), v > 0 {
                                            monitor.restoreSettings.delaySeconds = v
                                            monitor.restoreSettings.save()
                                        }
                                    }
                                Text("s").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Button(useCustomDelay ? "Presets" : "Custom") {
                            useCustomDelay.toggle()
                            if useCustomDelay { customDelayInput = "\(monitor.restoreSettings.delaySeconds)" }
                        }
                        .buttonStyle(.link).font(.caption)
                    }

                    HStack {
                        Text("Max restart attempts").foregroundStyle(.secondary)
                        Spacer()
                        if !useCustomAttempts {
                            Picker("", selection: $monitor.restoreSettings.maxAttempts) {
                                ForEach(RestoreSettings.attemptPresets, id: \.count) { p in
                                    Text(p.label).tag(p.count)
                                }
                            }
                            .pickerStyle(.menu).labelsHidden().frame(width: 80)
                            .onChange(of: monitor.restoreSettings.maxAttempts) { _, _ in monitor.restoreSettings.save() }
                        } else {
                            HStack(spacing: 4) {
                                TextField("×", text: $customAttemptsInput)
                                    .frame(width: 60).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                                    .onSubmit {
                                        if let v = Int(customAttemptsInput), v > 0 {
                                            monitor.restoreSettings.maxAttempts = v
                                            monitor.restoreSettings.save()
                                        }
                                    }
                                Text("×").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Button(useCustomAttempts ? "Presets" : "Custom") {
                            useCustomAttempts.toggle()
                            if useCustomAttempts { customAttemptsInput = "\(monitor.restoreSettings.maxAttempts)" }
                        }
                        .buttonStyle(.link).font(.caption)
                    }

                    Text("Auto-restart stops after \(monitor.restoreSettings.maxAttempts) consecutive failures")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            // ── Auto-Sync ──
            Section("Auto-Sync") {
                Toggle("Auto Sync", isOn: $monitor.restoreSettings.autoSync)
                    .onChange(of: monitor.restoreSettings.autoSync) { _, _ in
                        monitor.restoreSettings.save()
                        monitor.restartSyncTimer()
                    }

                if monitor.restoreSettings.autoSync {
                    HStack {
                        Text("Sync Interval").foregroundStyle(.secondary)
                        Spacer()
                        if !useCustomSyncInterval {
                            Picker("", selection: $monitor.restoreSettings.syncIntervalSeconds) {
                                ForEach(RestoreSettings.syncIntervalPresets, id: \.seconds) { p in
                                    Text(p.label).tag(p.seconds)
                                }
                            }
                            .pickerStyle(.menu).labelsHidden().frame(width: 80)
                            .onChange(of: monitor.restoreSettings.syncIntervalSeconds) { _, _ in
                                monitor.restoreSettings.save()
                                monitor.restartSyncTimer()
                            }
                        } else {
                            HStack(spacing: 4) {
                                TextField("Value", text: $customSyncIntervalInput)
                                    .frame(width: 60).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                                    .onSubmit {
                                        if let v = Int(customSyncIntervalInput), v > 0 {
                                            monitor.restoreSettings.syncIntervalSeconds = syncIntervalUnit.toSeconds(v)
                                            monitor.restoreSettings.save()
                                            monitor.restartSyncTimer()
                                        }
                                    }
                                Picker("", selection: $syncIntervalUnit) {
                                    ForEach(SyncUnit.allCases) { u in Text(u.rawValue).tag(u) }
                                }
                                .pickerStyle(.segmented).frame(width: 60)
                                .onChange(of: syncIntervalUnit) { _, newUnit in
                                    if let v = Int(customSyncIntervalInput), v > 0 {
                                        monitor.restoreSettings.syncIntervalSeconds = newUnit.toSeconds(v)
                                        monitor.restoreSettings.save()
                                        monitor.restartSyncTimer()
                                    }
                                }
                            }
                        }
                        Button(useCustomSyncInterval ? "Presets" : "Custom") {
                            useCustomSyncInterval.toggle()
                            if useCustomSyncInterval {
                                let secs = monitor.restoreSettings.syncIntervalSeconds
                                if secs % 60 == 0 {
                                    syncIntervalUnit = .minutes
                                    customSyncIntervalInput = "\(secs / 60)"
                                } else {
                                    syncIntervalUnit = .seconds
                                    customSyncIntervalInput = "\(secs)"
                                }
                            }
                        }
                        .buttonStyle(.link).font(.caption)
                    }

                    let interval = monitor.restoreSettings.syncIntervalSeconds
                    let label = interval < 60 ? "\(interval)s" : "\(interval / 60)m\(interval % 60 > 0 ? " \(interval % 60)s" : "")"
                    Text("Syncs tabs every \(label) when window-groups.json changes. Active tabs are not affected.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }

            Section("Claude Sessions") {
                HStack {
                    Text("Active Sessions")
                    Spacer()
                    Text("\(vm.sessionCount)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            Section("Daemons") {
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

            Section("Session Restore") {
                Button(action: {
                    showForceRestoreConfirm = true
                }) {
                    if vm.isRestoring {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.8)
                            Text("Restoring...")
                        }
                    } else {
                        Label("Force Restore", systemImage: "exclamationmark.arrow.circlepath")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(vm.isRestoring)
                .confirmationDialog(
                    "모든 Claude 세션을 종료하고 완전히 새로 시작합니까?",
                    isPresented: $showForceRestoreConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Force Restore", role: .destructive) {
                        Task { await vm.runRestore() }
                    }
                    Button("취소", role: .cancel) {}
                } message: {
                    Text("실행 중인 모든 tmux 세션과 Claude 프로세스를 종료하고 auto-restore.sh --force로 초기화합니다.")
                }

                if !vm.restoreLog.isEmpty {
                    Text(vm.restoreLog)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                    Button("View Full Log") { showRestoreLog = true }
                        .buttonStyle(.link)
                }
            }

            Section("Updates") {
                Button(action: {
                    Task { await vm.runInstall() }
                }) {
                    if vm.isInstalling {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.8)
                            Text("Installing...")
                        }
                    } else {
                        Text("Install Update")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.isInstalling)

                if !vm.installLog.isEmpty {
                    Button("View Install Log") { showInstallLog.toggle() }
                        .buttonStyle(.link)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            Task { await vm.refresh() }
            vm.startAutoRefresh()
        }
        .onDisappear { vm.stopAutoRefresh() }
        .sheet(isPresented: $showRestoreLog) {
            VStack(alignment: .leading) {
                HStack {
                    Text("Restore Log")
                        .font(.headline)
                    Spacer()
                    Button("Close") { showRestoreLog = false }
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
                    Text("Install Log")
                        .font(.headline)
                    Spacer()
                    Button("Close") { showInstallLog = false }
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
