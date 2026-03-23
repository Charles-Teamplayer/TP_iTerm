import Foundation
import Combine
import UserNotifications

@MainActor
final class SessionMonitor: ObservableObject {
    @Published var sessions: [ClaudeSession] = []
    @Published var selectedForRestore: Set<String> = []

    private var timer: Timer?
    private var isRefreshing = false
    private let activeSessionsPath = NSHomeDirectory() + "/.claude/active-sessions.json"
    private let profileService = ProfileService()

    func start() {
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
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
        result = result.map { session in
            var s = session
            if s.profileRoot == nil, let p = profileMap[s.projectName] ?? profileMap[s.windowName] {
                s.profileRoot = p.root
                s.profileDelay = p.delay
            }
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
            selectedForRestore.contains($0.id)
            && !$0.isRunning
            && !$0.id.hasPrefix("profile-")
            && $0.windowIndex != Int.max
        }
        for (i, session) in toRestore.enumerated() {
            let delay = session.profileDelay > 0 ? session.profileDelay : i * 5
            let windowName = shellEscape(session.windowName)
            let dir = session.directory.isEmpty ? "~/claude/\(session.windowName)" : session.directory
            let safeDir = dir.hasPrefix("~")
                ? dir.replacingOccurrences(of: "~", with: NSHomeDirectory(), range: dir.range(of: "~"))
                : dir
            let escapedDir = shellEscape(safeDir)
            let claudeCmd = hasClaudeProject(at: safeDir)
                ? "claude --dangerously-skip-permissions --continue"
                : "claude --dangerously-skip-permissions"
            let cmd = """
            tmux send-keys -t 'claude-work:\(windowName)' \
            "sleep \(delay) && bash ~/.claude/scripts/tab-status.sh starting '\(windowName)' && unset CLAUDECODE && \(claudeCmd)" Enter \
            2>/dev/null || \
            tmux new-window -t claude-work -n '\(windowName)' -c '\(escapedDir)' \\; \
            send-keys "sleep \(delay) && bash ~/.claude/scripts/tab-status.sh starting '\(windowName)' && unset CLAUDECODE && \(claudeCmd)" Enter
            """
            await ShellService.runAsync(cmd)
        }
        if !toRestore.isEmpty {
            NotificationService.shared.notifyRestoreComplete(count: toRestore.count)
        }
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

    func stopAllRunning() async {
        let running = sessions.filter { $0.isRunning && $0.pid > 0 }
        for session in running {
            let dir = session.directory.isEmpty ? session.projectName : session.directory
            await ShellService.intentionalStopAsync(projectDir: dir)
            await ShellService.runAsync("kill -TERM \(session.pid) 2>/dev/null")
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await refresh()
    }

    func selectAllStopped() {
        for session in sessions where !session.isRunning
            && !session.id.hasPrefix("profile-")
            && session.windowIndex != Int.max {
            selectedForRestore.insert(session.id)
        }
    }

    func deselectAll() {
        selectedForRestore.removeAll()
    }

    func launchProfile(name: String, root: String, delay: Int, createDir: Bool = false) async {
        let safeRoot = root.hasPrefix("~")
            ? root.replacingOccurrences(of: "~", with: NSHomeDirectory(), range: root.range(of: "~"))
            : root

        // claude 프로젝트 데이터(.jsonl)가 있을 때만 --continue
        let hasPrior = !createDir && hasClaudeProject(at: safeRoot)
        let claudeCmd = hasPrior
            ? "claude --dangerously-skip-permissions --continue"
            : "claude --dangerously-skip-permissions"

        let escapedName = shellEscape(name)
        let escapedRoot = shellEscape(safeRoot)
        let mkdirPart = createDir ? "mkdir -p '\(escapedRoot)' && " : ""
        let cmd = """
        tmux new-window -t claude-work -n '\(escapedName)' -c '\(escapedRoot)' \\; \
        send-keys "\(mkdirPart)sleep \(delay) && bash ~/.claude/scripts/tab-status.sh starting '\(escapedName)' && unset CLAUDECODE && \(claudeCmd)" Enter 2>/dev/null; \
        true
        """
        await ShellService.runAsync(cmd)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await refresh()
    }

    func createSession(name: String, directory: String) async {
        let safeName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeDir = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safeName.isEmpty, !safeDir.isEmpty else { return }

        let escapedName = shellEscape(safeName)
        let escapedDir = shellEscape(safeDir)
        let cmd = """
        tmux new-window -t claude-work -n '\(escapedName)' -c '\(escapedDir)' \\; \
        send-keys "bash ~/.claude/scripts/tab-status.sh starting '\(escapedName)' && unset CLAUDECODE && claude --dangerously-skip-permissions" Enter 2>/dev/null; true
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
            "tmux list-windows -t claude-work -F '#{window_index}|#{window_name}|#{pane_pid}|#{pane_tty}|#{pane_current_path}' 2>/dev/null"
        )
        guard !output.isEmpty else { return [] }
        var result: [TmuxWindow] = []
        for line in output.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: "|")
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
