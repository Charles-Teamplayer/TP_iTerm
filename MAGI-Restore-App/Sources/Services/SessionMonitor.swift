import Foundation
import Combine

@MainActor
final class SessionMonitor: ObservableObject {
    @Published var sessions: [ClaudeSession] = []
    @Published var selectedForRestore: Set<String> = []

    private var timer: Timer?
    private let activeSessionsPath = NSHomeDirectory() + "/.claude/active-sessions.json"

    func start() {
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() async {
        let tmuxWindows = await loadTmuxWindows()
        let activeSessions = await loadActiveSessions()

        var result: [ClaudeSession] = []
        var matchedProjects = Set<String>()

        for tw in tmuxWindows {
            let claudePid = await findClaudePid(panePid: tw.panePid, paneTty: tw.paneTty)
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

        sessions = result.sorted { $0.windowIndex < $1.windowIndex }
    }

    // MARK: - Restore

    func restoreSelected() async {
        let toRestore = sessions.filter { selectedForRestore.contains($0.id) && !$0.isRunning }
        for (i, session) in toRestore.enumerated() {
            let delay = i * 5
            let windowName = session.windowName
            let dir = session.directory.isEmpty
                ? "~/claude/\(windowName)"
                : session.directory

            let cmd = """
            tmux send-keys -t claude-work:\(windowName) \
            "sleep \(delay) && bash ~/.claude/scripts/tab-status.sh starting \(windowName) && unset CLAUDECODE && claude --dangerously-skip-permissions --continue" Enter \
            2>/dev/null || \
            tmux new-window -t claude-work -n '\(windowName)' -c '\(dir)' \\; \
            send-keys "sleep \(delay) && bash ~/.claude/scripts/tab-status.sh starting \(windowName) && unset CLAUDECODE && claude --dangerously-skip-permissions --continue" Enter
            """
            await ShellService.runAsync(cmd)
        }
        selectedForRestore.removeAll()
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await refresh()
    }

    func toggleSelection(_ id: String) {
        if selectedForRestore.contains(id) {
            selectedForRestore.remove(id)
        } else {
            selectedForRestore.insert(id)
        }
    }

    func selectAllStopped() {
        for session in sessions where !session.isRunning {
            selectedForRestore.insert(session.id)
        }
    }

    func deselectAll() {
        selectedForRestore.removeAll()
    }

    func createSession(name: String, directory: String) async {
        let safeName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeDir = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safeName.isEmpty, !safeDir.isEmpty else { return }

        let cmd = """
        tmux new-window -t claude-work -n '\(safeName)' -c '\(safeDir)' \\; \
        send-keys "bash ~/.claude/scripts/tab-status.sh starting '\(safeName)' && unset CLAUDECODE && claude --dangerously-skip-permissions" Enter 2>/dev/null; true
        """
        await ShellService.runAsync(cmd)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await refresh()
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

    private func findClaudePid(panePid: Int, paneTty: String = "") async -> Int? {
        // 방법1: TTY 기반 (손자 프로세스도 탐지)
        if !paneTty.isEmpty {
            let ttyBase = (paneTty as NSString).lastPathComponent
            if !ttyBase.isEmpty {
                let ttyResult = await ShellService.runAsync(
                    "ps -o pid,tty,command -ax 2>/dev/null | grep '\(ttyBase)' | grep '[c]laude' | grep -v grep | awk '{print $1}'"
                )
                let ttyPid = ttyResult.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces) ?? ""
                if let pid = Int(ttyPid) { return pid }
            }
        }
        // 방법2: pgrep fallback (직계 자식)
        let output = await ShellService.runAsync(
            "pgrep -P \(panePid) -f claude 2>/dev/null"
        )
        let firstLine = output.components(separatedBy: "\n").first ?? ""
        return Int(firstLine.trimmingCharacters(in: .whitespaces))
    }

    private func isProcessAlive(pid: Int) async -> Bool {
        let result = await ShellService.runAsync("kill -0 \(pid) 2>/dev/null && echo alive")
        return result == "alive"
    }
}
