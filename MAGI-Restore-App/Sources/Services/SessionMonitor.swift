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
        // tmux 내 프로세스: TTY == "??" → tmux pane pid로 window name 조회
        if tty == "??" {
            if let windowName = tmuxWindowMap[pid] { return windowName }
            // 직접 pane pid가 아닌 경우 — PPID 체인 최대 5단계 탐색
            if let name = findTmuxWindowByPPID(pid: pid, tmuxWindowMap: tmuxWindowMap) { return name }
            return "tmux-session"
        }

        var ttyClean = tty.replacingOccurrences(of: "/dev/", with: "").replacingOccurrences(of: "/", with: "-")
        // ps aux TTY는 "s007" 형태, tab-states 파일명은 "ttys007" 형태 — 접두사 보정
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

    // PPID 체인 탐색 — claude 프로세스가 pane의 자식인 경우
    private func findTmuxWindowByPPID(pid: Int, tmuxWindowMap: [Int: String]) -> String? {
        var current = pid
        for _ in 0..<5 {
            let ppidOutput = ShellService.run("ps -o ppid= -p \(current) 2>/dev/null")
            guard let ppid = Int(ppidOutput.trimmingCharacters(in: .whitespacesAndNewlines)), ppid > 1 else { break }
            if let name = tmuxWindowMap[ppid] { return name }
            current = ppid
        }
        return nil
    }
}
