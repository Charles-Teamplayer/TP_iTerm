import Foundation
import Combine

@MainActor
final class SessionMonitor: ObservableObject {
    @Published var sessions: [ClaudeSession] = []

    private var timer: Timer?
    private let tabStatesDir = NSHomeDirectory() + "/.claude/tab-states"

    private let excludePatterns = [
        "Claude.app", "Claude Helper", "watchdog", "auto-restore",
        "tab-focus", "session-registry", "MAGI", "xcodebuild", "xcodegen"
    ]

    func start() {
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() async {
        let output = await ShellService.runAsync("ps aux")
        let lines = output.components(separatedBy: "\n")

        // tmux 내 프로세스는 TTY가 "??" — pane pid → window name 맵으로 fallback
        let tmuxWindowMap = await buildTmuxWindowMap()

        var result: [ClaudeSession] = []
        for line in lines {
            guard line.contains("claude") else { continue }
            guard !excludePatterns.contains(where: { line.contains($0) }) else { continue }

            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 11 else { continue }
            guard let pid = Int(parts[1]) else { continue }

            let tty = String(parts[6])
            let startTime = String(parts[8])
            let projectName = resolveProjectName(tty: tty, pid: pid, tmuxWindowMap: tmuxWindowMap)
            result.append(ClaudeSession(pid: pid, tty: tty, projectName: projectName, startTime: startTime))
        }

        sessions = result
    }

    // tmux list-panes로 pane_pid → window_name 맵 구성
    private func buildTmuxWindowMap() async -> [Int: String] {
        let output = await ShellService.runAsync(
            "tmux list-panes -t claude-work -a -F '#{pane_pid} #{window_name}' 2>/dev/null"
        )
        var map: [Int: String] = [:]
        for line in output.components(separatedBy: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, let panePid = Int(parts[0]) else { continue }
            map[panePid] = String(parts[1])
        }
        return map
    }

    private func resolveProjectName(tty: String, pid: Int, tmuxWindowMap: [Int: String]) -> String {
        if tty == "??" {
            if let windowName = tmuxWindowMap[pid] { return windowName }
            return "tmux-session"
        }
        var ttyClean = tty.replacingOccurrences(of: "/dev/", with: "").replacingOccurrences(of: "/", with: "-")
        if ttyClean.hasPrefix("s") && !ttyClean.hasPrefix("tty") {
            ttyClean = "tty" + ttyClean
        }
        let stateFile = tabStatesDir + "/" + ttyClean
        if let content = try? String(contentsOfFile: stateFile, encoding: .utf8) {
            let parts = content.components(separatedBy: "|")
            if parts.count >= 2 { return parts[1] }
        }
        return ttyClean
    }
}
