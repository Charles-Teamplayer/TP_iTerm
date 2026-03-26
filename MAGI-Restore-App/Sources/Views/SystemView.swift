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

        // TTY 기반: tmux 각 윈도우의 pane에서 claude 프로세스 카운트
        let windowNames = await ShellService.runAsync("tmux list-windows -t claude-work -F '#{window_name}' 2>/dev/null")
        let windows = windowNames.components(separatedBy: "\n").filter { !$0.isEmpty }
        var count = 0
        for win in windows {
            let paneInfo = await ShellService.runAsync(
                "tmux display-message -t \(shellq("claude-work:\(win)")) -p '#{pane_tty}' 2>/dev/null"
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            let ttyBase = paneInfo.replacingOccurrences(of: "/dev/", with: "")
            guard !ttyBase.isEmpty else { continue }
            let procs = await ShellService.runAsync("ps -o command -t \(shellq(ttyBase)) 2>/dev/null | grep '[c]laude' | head -1")
            if !procs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                count += 1
            }
        }
        sessionCount = count

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
        restoreLog = "⏳ 세션 상태 확인 중..."

        let sessionExists = await ShellService.runAsync("tmux has-session -t claude-work 2>/dev/null && echo YES || echo NO")

        if sessionExists.contains("YES") {
            restoreLog = "⏳ 죽은 세션 점검 중..."
            let repairResult = await repairDeadWindows()
            restoreLog = repairResult
        } else {
            restoreLog = "⏳ 전체 세션 새로 생성 중... (약 10초 소요)"
            let scriptPath = NSHomeDirectory() + "/.claude/scripts/auto-restore.sh"
            let result = await ShellService.runAsync("bash '\(scriptPath)' --force 2>&1")
            restoreLog = result.isEmpty ? "⚠️ auto-restore 출력 없음" : result
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }

        // tmux 복원 후 iTerm2 현재 창에 attach 명령 전송
        await attachTmuxToITerm()

        // attach 후 4초 대기 → 탭 색상 복원
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
            restoreLog += "\n🎨 탭 색상 복원 완료"
        }

        isRestoring = false
        await refresh()
    }

    private func attachTmuxToITerm() async {
        let alreadyAttached = await ShellService.runAsync(
            "tmux list-clients -t claude-work -F '#{client_flags}' 2>/dev/null | grep -q 'control-mode' && echo YES || echo NO"
        )

        if alreadyAttached.contains("YES") {
            restoreLog += "\n✅ iTerm2 이미 연결됨"
            return
        }

        restoreLog += "\n🔗 iTerm2 새 탭으로 연결 중..."

        let script = """
        osascript -e 'tell application "iTerm2"
            tell current window
                create tab with default profile
                tell current session of current tab
                    write text "tmux -CC attach -t claude-work"
                end tell
            end tell
        end tell' 2>&1
        """
        let result = await ShellService.runAsync(script)
        if result.lowercased().contains("error") {
            restoreLog += "\n⚠️ iTerm2 연결 실패: \(String(result.prefix(120)))"
        }
    }

    private func repairDeadWindows() async -> String {
        // activated-sessions.json 기반으로 프로젝트 목록 동적 로드 (하드코딩 제거)
        let raw = await ShellService.runAsync("""
            python3 -c "
            import json, os
            path = os.path.expanduser('~/.claude/activated-sessions.json')
            try:
                data = json.load(open(path))
                for p in data.get('activated', []):
                    name = os.path.basename(p)
                    print(name + '|' + p)
            except: pass
            " 2>/dev/null
            """)
        let projects: [(name: String, path: String)] = raw
            .components(separatedBy: "\n")
            .filter { $0.contains("|") }
            .compactMap { line in
                guard let pipeIdx = line.firstIndex(of: "|") else { return nil }
                let name = String(line[line.startIndex..<pipeIdx])
                let path = String(line[line.index(after: pipeIdx)...])
                guard !name.isEmpty, !path.isEmpty else { return nil }
                return (name: name, path: path)
            }

        let existingWindows = await ShellService.runAsync("tmux list-windows -t claude-work -F '#{window_name}' 2>/dev/null")
        let windowSet = Set(existingWindows.components(separatedBy: "\n").filter { !$0.isEmpty })

        // "지금 복원" 버튼은 사용자의 명시적 의도이므로 intentional-stops를 초기화
        let stopsFile = NSHomeDirectory() + "/.claude/intentional-stops.json"
        let resetJson = "{\"stops\":[],\"last_updated\":\"\(ISO8601DateFormatter().string(from: Date()))\"}"
        try? resetJson.write(toFile: stopsFile, atomically: true, encoding: .utf8)

        var restored = 0
        var alreadyRunning = 0
        for proj in projects {
            let expandedPath = proj.path.hasPrefix("~")
                ? NSHomeDirectory() + proj.path.dropFirst()
                : proj.path
            let dirExists = await ShellService.runAsync("[ -d \(shellq(expandedPath)) ] && echo YES || echo NO")
            guard dirExists.contains("YES") else { continue }

            if windowSet.contains(proj.name) {
                // 창은 있지만 claude가 실행 중인지 확인 (TTY 기반 + pgrep fallback)
                let paneInfo = await ShellService.runAsync(
                    "tmux display-message -t \(shellq("claude-work:\(proj.name)")) -p '#{pane_tty}|#{pane_pid}' 2>/dev/null"
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                let infoParts = paneInfo.components(separatedBy: "|")
                let paneTty = infoParts.count > 0 ? infoParts[0] : ""
                let panePid = infoParts.count > 1 ? infoParts[1] : ""

                // 방법1: TTY 기반 (손자 프로세스도 탐지)
                let ttyBase = paneTty.replacingOccurrences(of: "/dev/", with: "")
                var claudeRunning = ttyBase.isEmpty ? "" : await ShellService.runAsync(
                    "ps -o pid,command -t \(shellq(ttyBase)) 2>/dev/null | grep '[c]laude' | head -1"
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
                let cmd = "bash ~/.claude/scripts/tab-status.sh starting \(shellq(proj.name)) && unset CLAUDECODE && (claude --dangerously-skip-permissions --continue 2>/dev/null || claude --dangerously-skip-permissions)"
                await ShellService.runAsync(
                    "tmux send-keys -t \(shellq("claude-work:\(proj.name)")) \(shellq(cmd)) Enter"
                )
                restored += 1
            } else {
                // 창 없음 → 새로 생성
                await ShellService.runAsync("tmux new-window -t claude-work -n \(shellq(proj.name)) -c \(shellq(expandedPath))")
                await ShellService.runAsync("tmux set-window-option -t \(shellq("claude-work:\(proj.name)")) automatic-rename off 2>/dev/null")
                let cmd = "bash ~/.claude/scripts/tab-status.sh starting \(shellq(proj.name)) && unset CLAUDECODE && (claude --dangerously-skip-permissions --continue 2>/dev/null || claude --dangerously-skip-permissions)"
                await ShellService.runAsync(
                    "tmux send-keys -t \(shellq("claude-work:\(proj.name)")) \(shellq(cmd)) Enter"
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
    @ObservedObject var monitor: SessionMonitor
    @StateObject private var vm = SystemViewModel()
    @State private var showInstallLog = false
    @State private var showRestoreLog = false
    // 직접 입력 토글
    @State private var useCustomDelay = false
    @State private var useCustomAttempts = false
    @State private var customDelayInput = ""
    @State private var customAttemptsInput = ""
    @State private var useCustomSyncInterval = false
    @State private var customSyncIntervalInput = ""
    @State private var syncIntervalUnit: SyncUnit = .seconds

    enum SyncUnit: String, CaseIterable, Identifiable {
        case seconds = "초"
        case minutes = "분"
        var id: String { rawValue }
        func toSeconds(_ v: Int) -> Int { self == .minutes ? v * 60 : v }
        func fromSeconds(_ s: Int) -> Int { self == .minutes ? s / 60 : s }
    }

    var body: some View {
        Form {
            // ── 자동 재시작 설정 ──
            Section("자동 재시작 설정") {
                Toggle("크래시 감지 시 자동 재시작", isOn: $monitor.restoreSettings.autoRestore)
                    .onChange(of: monitor.restoreSettings.autoRestore) { _, _ in monitor.restoreSettings.save() }

                if monitor.restoreSettings.autoRestore {
                    // 대기 시간
                    HStack {
                        Text("재시작까지 대기").foregroundStyle(.secondary)
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
                                TextField("초", text: $customDelayInput)
                                    .frame(width: 60).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                                    .onSubmit {
                                        if let v = Int(customDelayInput), v > 0 {
                                            monitor.restoreSettings.delaySeconds = v
                                            monitor.restoreSettings.save()
                                        }
                                    }
                                Text("초").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Button(useCustomDelay ? "프리셋" : "직접 입력") {
                            useCustomDelay.toggle()
                            if useCustomDelay { customDelayInput = "\(monitor.restoreSettings.delaySeconds)" }
                        }
                        .buttonStyle(.link).font(.caption)
                    }

                    // 최대 시도 횟수
                    HStack {
                        Text("최대 재시작 시도").foregroundStyle(.secondary)
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
                                TextField("횟수", text: $customAttemptsInput)
                                    .frame(width: 60).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                                    .onSubmit {
                                        if let v = Int(customAttemptsInput), v > 0 {
                                            monitor.restoreSettings.maxAttempts = v
                                            monitor.restoreSettings.save()
                                        }
                                    }
                                Text("회").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Button(useCustomAttempts ? "프리셋" : "직접 입력") {
                            useCustomAttempts.toggle()
                            if useCustomAttempts { customAttemptsInput = "\(monitor.restoreSettings.maxAttempts)" }
                        }
                        .buttonStyle(.link).font(.caption)
                    }

                    Text("최대 \(monitor.restoreSettings.maxAttempts)회 연속 실패 시 자동 재시작 중단")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            // ── 자동 동기화 설정 ──
            Section("자동 동기화 설정") {
                Toggle("자동 동기화", isOn: $monitor.restoreSettings.autoSync)
                    .onChange(of: monitor.restoreSettings.autoSync) { _, _ in
                        monitor.restoreSettings.save()
                        monitor.restartSyncTimer()
                    }

                if monitor.restoreSettings.autoSync {
                    HStack {
                        Text("동기화 간격").foregroundStyle(.secondary)
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
                                TextField("값", text: $customSyncIntervalInput)
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
                        Button(useCustomSyncInterval ? "프리셋" : "직접 입력") {
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
                    let label = interval < 60 ? "\(interval)초" : "\(interval / 60)분\(interval % 60 > 0 ? " \(interval % 60)초" : "")"
                    Text("window-groups.json 변경 시 \(label)마다 탭 자동 동기화. 작업 중인 탭은 영향 없음.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }

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
        .onAppear {
            Task { await vm.refresh() }
            vm.startAutoRefresh()
        }
        .onDisappear { vm.stopAutoRefresh() }
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
