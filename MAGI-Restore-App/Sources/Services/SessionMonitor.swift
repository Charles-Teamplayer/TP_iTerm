import Foundation
import Combine
import UserNotifications

@MainActor
final class SessionMonitor: ObservableObject {
    @Published var sessions: [ClaudeSession] = []
    @Published var selectedForRestore: Set<String> = []
    @Published var restoreProgress: (current: Int, total: Int)? = nil
    @Published var isBatchRestoring = false
    private var cancelRestoreFlag = false

    private var timer: Timer?
    private var isRefreshing = false
    private let activeSessionsPath = NSHomeDirectory() + "/.claude/active-sessions.json"
    let profileService = ProfileService()
    let windowGroupService = WindowGroupService()

    func start() {
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    // 프로필 목록과 window-groups 동기화 (미배정 프로필 → 첫 번째 창 자동 배정)
    func syncWindowGroupsWithProfiles() {
        guard !windowGroupService.groups.isEmpty else { return }
        let allAssigned = Set(windowGroupService.groups.flatMap { $0.profileNames })
        let unassigned = profileService.profiles.filter { !allAssigned.contains($0.name) }
        guard !unassigned.isEmpty else { return }
        let first = windowGroupService.groups[0]
        for profile in unassigned {
            windowGroupService.moveProfile(profile.name, to: first)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let tmuxWindows = await loadTmuxWindows()
        let activeSessions = await loadActiveSessions()

        // ps 한 번만 실행해서 전체 claude 프로세스 캐시 (pid,ppid,tty,command 포함)
        let claudeProcessSnapshot = await ShellService.runAsync(
            "ps -o pid,ppid,tty,command -ax 2>/dev/null | grep '[c]laude'"
        )

        var result: [ClaudeSession] = []
        var matchedProjects = Set<String>()

        for tw in tmuxWindows {
            let claudePid = findClaudePidFromSnapshot(claudeProcessSnapshot, panePid: tw.panePid, paneTty: tw.paneTty)
            let isRunning = claudePid != nil

            let activeInfo = activeSessions.first { info in
                info.project == tw.windowName
                || info.dir.hasSuffix("/\(tw.windowName)")
                || tw.windowName.contains(info.project.lowercased())
                || info.project.lowercased().contains(tw.windowName.lowercased())
            }

            if let info = activeInfo {
                matchedProjects.insert(info.project)
            }

            result.append(ClaudeSession(
                id: tw.windowName,
                pid: claudePid ?? tw.panePid,
                tty: tw.paneTty,
                projectName: activeInfo?.project ?? tw.windowName,
                startTime: activeInfo?.started ?? "",
                directory: activeInfo?.dir ?? tw.rootDir,
                windowName: tw.windowName,
                windowIndex: tw.windowIndex,
                isRunning: isRunning
            ))
        }

        for info in activeSessions where !matchedProjects.contains(info.project) {
            guard let pid = Int(info.pid) else { continue }
            let alive = await isProcessAlive(pid: pid)
            if alive {
                result.append(ClaudeSession(
                    id: "json-\(info.project)",
                    pid: pid,
                    tty: info.tty,
                    projectName: info.project,
                    startTime: info.started,
                    directory: info.dir,
                    windowName: info.project,
                    windowIndex: -1,
                    isRunning: true
                ))
            }
        }

        // 프로필 병합 — 세션 목록에 없는 프로필은 가상 정지 세션으로 추가
        profileService.load()
        let existingNames = Set(result.map { $0.projectName } + result.map { $0.windowName })
        for profile in profileService.profiles {
            guard !existingNames.contains(profile.name) else { continue }
            result.append(ClaudeSession(
                id: "profile-\(profile.id)",
                pid: 0,
                tty: "",
                projectName: profile.name,
                startTime: "",
                directory: profile.root,
                windowName: profile.name,
                windowIndex: Int.max,
                isRunning: false,
                profileRoot: profile.root,
                profileDelay: profile.delay
            ))
        }

        // 기존 세션 중 프로필과 이름 매칭되면 profileRoot 주입
        var profileMap: [String: SmugProfile] = [:]
        for p in profileService.profiles { profileMap[p.name] = p }
        let activatedRoots = ActivationService.shared.loadActivated()
        result = result.map { session in
            var s = session
            if s.profileRoot == nil, let p = profileMap[s.projectName] ?? profileMap[s.windowName] {
                s.profileRoot = p.root
                s.profileDelay = p.delay
            }
            // 활성화 플래그 주입
            let root = s.profileRoot ?? s.directory
            s.isActivated = activatedRoots.contains(
                root.hasPrefix("~")
                    ? root.replacingOccurrences(of: "~", with: NSHomeDirectory(), range: root.range(of: "~"))
                    : root
            )
            return s
        }

        let newSessions = result.sorted {
            if $0.windowIndex == $1.windowIndex { return $0.projectName < $1.projectName }
            return $0.windowIndex < $1.windowIndex
        }
        detectChanges(old: sessions, new: newSessions)
        sessions = newSessions
    }

    private func detectChanges(old: [ClaudeSession], new: [ClaudeSession]) {
        guard !old.isEmpty else { return }
        var oldMap: [String: Bool] = [:]
        for session in old { oldMap[session.id] = session.isRunning }
        for session in new {
            guard let wasRunning = oldMap[session.id] else { continue }
            if wasRunning && !session.isRunning {
                NotificationService.shared.notifySessionCrashed(name: session.projectName)
            }
        }
    }

    // MARK: - Restore

    func restoreSelected() async {
        let toRestore = sessions.filter {
            selectedForRestore.contains($0.id) && !$0.isRunning
        }
        guard !toRestore.isEmpty else { return }

        isRefreshing = true
        isBatchRestoring = true
        cancelRestoreFlag = false
        restoreProgress = (0, toRestore.count)
        defer {
            isRefreshing = false
            isBatchRestoring = false
            restoreProgress = nil
        }

        for (i, session) in toRestore.enumerated() {
            guard !cancelRestoreFlag else { break }
            let delay = session.profileDelay > 0 ? session.profileDelay : 0
            // profile-only 세션(windowIndex=Int.max)은 launchProfile로 위임
            if session.id.hasPrefix("profile-") || session.windowIndex == Int.max,
               let root = session.profileRoot {
                await launchProfile(name: session.projectName, root: root, delay: delay)
                restoreProgress = (i + 1, toRestore.count)
                continue
            }

            let winName = shellEscape(session.windowName)
            let dir = session.directory.isEmpty ? "~/claude/\(session.windowName)" : session.directory
            let safeDir = dir.hasPrefix("~")
                ? dir.replacingOccurrences(of: "~", with: NSHomeDirectory(), range: dir.range(of: "~"))
                : dir
            let escapedDir = shellEscape(safeDir)
            let claudeCmd = hasClaudeProject(at: safeDir)
                ? "claude --dangerously-skip-permissions --continue"
                : "claude --dangerously-skip-permissions"
            let escapedWindowName = shellEscape(session.windowName)
            let sleepPart = delay > 0 ? "sleep \(delay) && " : ""
            let claudeEntry = "\(sleepPart)bash ~/.claude/scripts/tab-status.sh starting '\(escapedWindowName)' && unset CLAUDECODE && \(claudeCmd)"

            // 창 존재 여부 먼저 확인 — windowIndex 기반 (이모지/특수문자 안전)
            let winIdx = session.windowIndex
            let paneCmd = await ShellService.runAsync(
                "tmux list-panes -t 'claude-work:\(winIdx)' -F '#{pane_current_command}' 2>/dev/null | head -1"
            )

            if paneCmd.isEmpty {
                // 창이 사라진 경우 — 새로 생성 후 claude 실행
                await ShellService.runAsync(
                    "tmux new-window -t claude-work -n '\(winName)' -c '\(escapedDir)'"
                )
                await ShellService.runAsync(
                    "tmux send-keys -t 'claude-work:\(winName)' '\(claudeEntry)' Enter 2>/dev/null"
                )
            } else {
                // 창이 있음 — windowIndex로 targeting (특수문자 무관)
                await ShellService.runAsync(
                    "tmux send-keys -t 'claude-work:\(winIdx)' '\(claudeEntry)' Enter 2>/dev/null"
                )
            }

            restoreProgress = (i + 1, toRestore.count)

            // 배치 5개마다 2초 대기 (tmux 부하 분산)
            if (i + 1) % 5 == 0 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }

        let restoredCount = cancelRestoreFlag
            ? (restoreProgress?.current ?? 0)
            : toRestore.count
        NotificationService.shared.notifyRestoreComplete(count: restoredCount)
        selectedForRestore.removeAll()
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await refresh()
    }

    func purgeSession(_ session: ClaudeSession) async {
        let projectDir = session.directory.isEmpty ? session.projectName : session.directory
        await ShellService.purgeSessionAsync(
            pid: session.pid,
            windowName: session.windowName,
            tty: session.tty,
            projectDir: projectDir
        )
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await refresh()
    }

    func toggleSelection(_ id: String) {
        if selectedForRestore.contains(id) {
            selectedForRestore.remove(id)
        } else {
            selectedForRestore.insert(id)
        }
    }

    // claude 실행 중 세션 중지 + tmux 창 닫기
    func stopAllRunning() async {
        let toStop = sessions.filter { $0.isRunning && !$0.id.hasPrefix("profile-") }
        for session in toStop {
            let dir = session.directory.isEmpty ? session.projectName : session.directory
            await ShellService.intentionalStopAsync(projectDir: dir)
            if session.pid > 0 {
                await ShellService.runAsync("kill -TERM \(session.pid) 2>/dev/null")
            }
            // windowIndex 기반 tmux kill-window (이름 특수문자 무관, json-* 세션 -1 방어)
            if session.windowIndex >= 0 {
                await ShellService.runAsync(
                    "tmux kill-window -t 'claude-work:\(session.windowIndex)' 2>/dev/null; true"
                )
            }
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await refresh()
    }

    // zsh만 있는 유휴 창 전체 닫기 (복원 실패 후 남은 zsh 정리용)
    func purgeIdleZshWindows() async {
        let idleZsh = sessions.filter {
            !$0.isRunning
            && !$0.id.hasPrefix("profile-")
            && $0.windowIndex != Int.max
        }
        for session in idleZsh {
            let winIdx = session.windowIndex
            let paneCmd = await ShellService.runAsync(
                "tmux list-panes -t 'claude-work:\(winIdx)' -F '#{pane_current_command}' 2>/dev/null | head -1"
            )
            guard paneCmd == "zsh" || paneCmd == "bash" || paneCmd.isEmpty else {
                continue
            }
            let dir = session.directory.isEmpty ? session.projectName : session.directory
            await ShellService.intentionalStopAsync(projectDir: dir)
            await ShellService.runAsync(
                "tmux kill-window -t 'claude-work:\(winIdx)' 2>/dev/null; true"
            )
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await refresh()
    }

    /// ~/claude/ 디렉토리 기준 smug YAML 동기화
    /// — 디렉토리에 있는데 프로필에 없으면 추가, 디렉토리가 삭제된 프로필은 제거
    @discardableResult
    func syncProfilesWithDirectory(baseDir: String = "~/claude") -> (added: [String], removed: [String]) {
        let safeBase = baseDir.hasPrefix("~")
            ? baseDir.replacingOccurrences(of: "~", with: NSHomeDirectory(), range: baseDir.range(of: "~"))
            : baseDir
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: safeBase) else { return ([], []) }

        let ignorePatterns = [
            "Claude_code_", "Claude-code_", "Claude-Code-",
            "_아카이빙", "_archived_", "_archive", "archive",
            "claude-squad", "claude_squad", "claude_gpt",
            "teamplean-github-pages", "teamplayer-github-pages",
            "TP_Infra_reduce_Project",
        ]

        let dirs = entries.filter { name in
            !name.hasPrefix(".") && !name.hasPrefix("_") &&
            !ignorePatterns.contains(where: { name.hasPrefix($0) || name.contains($0) }) &&
            (try? fm.attributesOfItem(atPath: safeBase + "/" + name)[.type] as? FileAttributeType) == .typeDirectory
        }

        profileService.load()
        let existingNames = Set(profileService.profiles.map { $0.name })
        let dirSet = Set(dirs)

        // 추가: 디렉토리에는 있는데 프로필에 없는 것
        var added: [String] = []
        for name in dirs.sorted() where !existingNames.contains(name) {
            let profile = SmugProfile(
                id: UUID(),
                name: name,
                root: baseDir + "/" + name,
                delay: 0,
                enabled: true
            )
            profileService.add(profile)
            added.append(name)
        }

        // 제거: 프로필에는 있는데 디렉토리가 없는 것 (순회 전 스냅샷으로 ConcurrentModification 방지)
        var removed: [String] = []
        let toRemove = profileService.profiles.filter { !dirSet.contains($0.name) }
        for profile in toRemove {
            profileService.delete(profile)
            removed.append(profile.name)
        }

        profileService.load()
        return (added, removed)
    }

    func selectAllStopped() {
        selectedForRestore.removeAll()
        for session in sessions where !session.isRunning
            && !session.id.hasPrefix("profile-")
            && session.windowIndex != Int.max {
            selectedForRestore.insert(session.id)
        }
    }

    func selectAllLaunchable() {
        selectedForRestore.removeAll()
        for session in sessions where !session.isRunning
            && (session.id.hasPrefix("profile-") || session.windowIndex == Int.max) {
            selectedForRestore.insert(session.id)
        }
    }

    func deselectAll() {
        selectedForRestore.removeAll()
    }

    func cancelRestore() {
        cancelRestoreFlag = true
    }

    func launchProfile(name: String, root: String, delay: Int, sessionName: String = "claude-work", createDir: Bool = false) async {
        let safeSession = sessionName.isEmpty ? "claude-work" : sessionName
        // tmux 세션 없으면 자동 생성
        let sessionExists = await ShellService.runAsync(
            "tmux has-session -t '\(safeSession)' 2>/dev/null && echo yes || echo no"
        )
        if sessionExists.trimmingCharacters(in: .whitespacesAndNewlines) == "no" {
            await ShellService.runAsync("tmux new-session -s '\(safeSession)' -d 2>/dev/null; true")
        }

        let safeRoot = root.hasPrefix("~")
            ? root.replacingOccurrences(of: "~", with: NSHomeDirectory(), range: root.range(of: "~"))
            : root

        // claude 프로젝트 데이터(.jsonl)가 있을 때만 --continue
        let hasPrior = !createDir && hasClaudeProject(at: safeRoot)
        let claudeCmd = hasPrior
            ? "claude --dangerously-skip-permissions --continue"
            : "claude --dangerously-skip-permissions"

        // 이미 동일 이름 창 존재하면 중복 생성 방지
        let existingNames = await ShellService.runAsync(
            "tmux list-windows -t '\(safeSession)' -F '#{window_name}' 2>/dev/null"
        )
        if existingNames.components(separatedBy: "\n").contains(name) {
            await refresh()
            return
        }

        let escapedName = shellEscape(name)
        let escapedRoot = shellEscape(safeRoot)
        let escapedSession = shellEscape(safeSession)
        let mkdirPart = createDir ? "mkdir -p '\(escapedRoot)' && " : ""
        let sleepPart = delay > 0 ? "sleep \(delay) && " : ""
        let winNameForStatus = name.replacingOccurrences(of: "\"", with: "\\\"")
                                   .replacingOccurrences(of: "'", with: "'\\''")
        let cmd = """
        tmux new-window -t '\(escapedSession)' -n '\(escapedName)' -c '\(escapedRoot)' \\; \
        send-keys "\(mkdirPart)\(sleepPart)bash ~/.claude/scripts/tab-status.sh starting '\(winNameForStatus)' && unset CLAUDECODE && \(claudeCmd)" Enter 2>/dev/null; \
        true
        """
        ActivationService.shared.activate(root: safeRoot)
        await ShellService.runAsync(cmd)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await refresh()
    }

    // 그룹(창) 전체 시작: tmux 세션 생성 + iTerm 새 창 attach + 프로필 순서대로 열기
    func startGroup(_ group: WindowPane) async {
        let sessionName = group.sessionName
        let escapedSession = shellEscape(sessionName)

        // tmux 세션 없으면 생성 (monitor 창 포함)
        let exists = await ShellService.runAsync(
            "tmux has-session -t '\(escapedSession)' 2>/dev/null && echo yes || echo no"
        )
        if exists.trimmingCharacters(in: .whitespacesAndNewlines) == "no" {
            await ShellService.runAsync(
                "tmux new-session -d -s '\(escapedSession)' -n monitor -c '\(NSHomeDirectory())/claude' 2>/dev/null; true"
            )
            await ShellService.runAsync(
                "tmux set-window-option -t '\(escapedSession):monitor' automatic-rename off 2>/dev/null; true"
            )
        }

        // iTerm2 새 창으로 attach (아직 연결 안 된 경우)
        let clientCount = await ShellService.runAsync(
            "tmux list-clients -t '\(escapedSession)' 2>/dev/null | wc -l | tr -d ' '"
        )
        if (Int(clientCount) ?? 0) == 0 {
            let script = """
            osascript -e 'tell application "iTerm2"
                set newWindow to (create window with default profile)
                tell current session of newWindow
                    write text "tmux -CC attach -t \(sessionName)"
                end tell
            end tell'
            """
            await ShellService.runAsync(script)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }

        // 프로필 순서대로 시작
        let allProfiles = profileService.profiles
        for (i, profileName) in group.profileNames.enumerated() {
            guard let profile = allProfiles.first(where: { $0.name == profileName }) else { continue }
            await launchProfile(name: profile.name, root: profile.root, delay: i * 5, sessionName: sessionName)
        }
    }

    func createSession(name: String, directory: String) async {
        let safeName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeDir = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safeName.isEmpty, !safeDir.isEmpty else { return }

        let escapedName = shellEscape(safeName)
        let escapedDir = shellEscape(safeDir)
        let nameForStatus = safeName.replacingOccurrences(of: "\"", with: "\\\"")
                                     .replacingOccurrences(of: "'", with: "'\\''")
        let cmd = """
        tmux new-window -t claude-work -n '\(escapedName)' -c '\(escapedDir)' \\; \
        send-keys "bash ~/.claude/scripts/tab-status.sh starting '\(nameForStatus)' && unset CLAUDECODE && claude --dangerously-skip-permissions" Enter 2>/dev/null; true
        """
        await ShellService.runAsync(cmd)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await refresh()
    }

    private func shellEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "'\\''")
    }

    // MARK: - Data Loading

    private struct TmuxWindow {
        let windowIndex: Int
        let windowName: String
        let panePid: Int
        let paneTty: String
        let rootDir: String
    }

    private struct ActiveSessionInfo {
        let project: String
        let dir: String
        let pid: String
        let tty: String
        let started: String
    }

    private func hasClaudeProject(at path: String) -> Bool {
        // /Users/foo/claude/proj → -Users-foo-claude-proj
        let encoded = path.unicodeScalars.map { c in
            CharacterSet.alphanumerics.contains(c) ? String(c) : "-"
        }.joined()
        let projectDir = NSHomeDirectory() + "/.claude/projects/" + encoded
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: projectDir) else { return false }
        return files.contains { $0.hasSuffix(".jsonl") }
    }

    private func loadTmuxWindows() async -> [TmuxWindow] {
        let output = await ShellService.runAsync(
            "tmux list-windows -t claude-work -F '#{window_index}\u{01}#{window_name}\u{01}#{pane_pid}\u{01}#{pane_tty}\u{01}#{pane_current_path}' 2>/dev/null"
        )
        guard !output.isEmpty else { return [] }
        var result: [TmuxWindow] = []
        for line in output.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: "\u{01}")
            guard parts.count >= 4 else { continue }
            guard let idx = Int(parts[0]), let pid = Int(parts[2]) else { continue }
            result.append(TmuxWindow(
                windowIndex: idx,
                windowName: parts[1],
                panePid: pid,
                paneTty: parts[3],
                rootDir: parts.count >= 5 ? parts[4] : ""
            ))
        }
        return result
    }

    private func loadActiveSessions() async -> [ActiveSessionInfo] {
        guard let data = FileManager.default.contents(atPath: activeSessionsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessions = json["sessions"] as? [[String: Any]] else {
            return []
        }
        return sessions.compactMap { s in
            guard let project = s["project"] as? String else { return nil }
            return ActiveSessionInfo(
                project: project,
                dir: (s["dir"] as? String) ?? "",
                pid: (s["pid"] as? String) ?? "",
                tty: (s["tty"] as? String) ?? "??",
                started: (s["started"] as? String) ?? ""
            )
        }
    }

    // ps 스냅샷(pid,ppid,tty,command)에서 Claude PID 탐색 — ps 중복 실행 없음
    // 출력 형식: "  PID  PPID TTY  COMMAND..."
    private func findClaudePidFromSnapshot(_ snapshot: String, panePid: Int, paneTty: String) -> Int? {
        let ttyBase = paneTty.isEmpty ? "" : (paneTty as NSString).lastPathComponent
        for line in snapshot.components(separatedBy: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces)
                .components(separatedBy: .whitespaces)
            guard parts.count >= 3,
                  let pid = Int(parts[0]) else { continue }
            // 방법1: TTY 매칭
            if !ttyBase.isEmpty && parts[2] == ttyBase {
                return pid
            }
            // 방법2: PPID 매칭 (직계 자식)
            if let ppid = Int(parts[1]), ppid == panePid {
                return pid
            }
        }
        return nil
    }

    private func isProcessAlive(pid: Int) async -> Bool {
        let result = await ShellService.runAsync("kill -0 \(pid) 2>/dev/null && echo alive")
        return result == "alive"
    }
}
