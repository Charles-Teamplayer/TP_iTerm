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

        var result: [ClaudeSession] = []
        for line in lines {
            guard line.contains("claude") else { continue }
            guard !excludePatterns.contains(where: { line.contains($0) }) else { continue }

            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 11 else { continue }
            guard let pid = Int(parts[1]) else { continue }

            let tty = String(parts[6])
            let startTime = String(parts[8])
            let projectName = resolveProjectName(tty: tty)
            result.append(ClaudeSession(pid: pid, tty: tty, projectName: projectName, startTime: startTime))
        }

        sessions = result
    }

    private func resolveProjectName(tty: String) -> String {
        let ttyClean = tty.replacingOccurrences(of: "/dev/", with: "").replacingOccurrences(of: "/", with: "-")
        let stateFile = tabStatesDir + "/" + ttyClean
        if let content = try? String(contentsOfFile: stateFile, encoding: .utf8) {
            let parts = content.components(separatedBy: "|")
            if parts.count >= 2 { return parts[1] }
        }
        return ttyClean
    }
}
