import Foundation
import Combine

@MainActor
final class CodexMonitorService: ObservableObject {
    @Published var agents: [AgentSession] = []
    @Published var lastUpdate: Date = Date()
    private var pollTask: Task<Void, Never>?

    func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        let panes = await fetchTmuxPanes()
        var result: [AgentSession] = []
        for pane in panes {
            let agentInfo = await extractAgentInfo(panePid: pane.pid, paneTty: pane.tty)
            let summary = await fetchPaneSummary(target: "\(pane.session):\(pane.windowIndex).\(pane.paneIndex)")
            let startTime = Date(timeIntervalSince1970: TimeInterval(pane.startTimeSec))
            let status = determineStatus(summary: summary, agentInfo: agentInfo)
            result.append(AgentSession(
                id: pane.paneId,
                tmuxSession: pane.session,
                windowIndex: pane.windowIndex,
                windowName: pane.windowName,
                paneIndex: pane.paneIndex,
                panePid: pane.pid,
                paneTty: pane.tty,
                agentId: agentInfo.id,
                agentName: agentInfo.name,
                startTime: startTime,
                endTime: nil,
                status: status,
                summary: summary,
                isParent: pane.paneIndex == 0
            ))
        }
        agents = result
        lastUpdate = Date()
    }

    private func fetchTmuxPanes() async -> [TmuxPaneInfo] {
        let raw = await ShellService.runAsync(
            "tmux list-panes -a -F '#{session_name}|#{window_index}|#{window_name}|#{pane_index}|#{pane_id}|#{pane_pid}|#{pane_tty}|#{pane_start_time}|#{pane_command}' 2>/dev/null"
        )
        var result: [TmuxPaneInfo] = []
        for line in raw.components(separatedBy: "\n") where !line.isEmpty {
            let parts = line.components(separatedBy: "|")
            // FIX-Q (2026-05-07): tmux 3.6+에서 pane_start_time 빈 문자열 반환 → fallback 현재 시각
            guard parts.count >= 9,
                  let widx = Int(parts[1]),
                  let pidx = Int(parts[3]),
                  let pid = Int(parts[5])
            else { continue }
            let startSec = Int(parts[7]) ?? Int(Date().timeIntervalSince1970)
            if parts[2] == "monitor" { continue }
            result.append(TmuxPaneInfo(
                session: parts[0],
                windowIndex: widx,
                windowName: parts[2],
                paneIndex: pidx,
                paneId: parts[4],
                pid: pid,
                tty: parts[6],
                startTimeSec: startSec,
                command: parts[8]
            ))
        }
        return result
    }

    private func extractAgentInfo(panePid: Int, paneTty: String) async -> (id: String?, name: String?) {
        let ttyName = (paneTty as NSString).lastPathComponent
        let raw = await ShellService.runAsync("ps -t '\(ttyName)' -o command 2>/dev/null")
        var agentId: String?
        var agentName: String?
        for line in raw.components(separatedBy: "\n") {
            if let r = line.range(of: "--agent-id ") {
                let rest = line[r.upperBound...]
                agentId = String(rest.split(separator: " ").first ?? "")
            }
            if let r = line.range(of: "--agent-name ") {
                let rest = line[r.upperBound...]
                agentName = String(rest.split(separator: " ").first ?? "")
            }
        }
        return (agentId, agentName)
    }

    private func fetchPaneSummary(target: String) async -> String {
        let raw = await ShellService.runAsync(
            "tmux capture-pane -t '\(target)' -p 2>/dev/null | tail -5"
        )
        let lines = raw.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.last.map { String($0.prefix(120)) } ?? ""
    }

    private func determineStatus(summary: String, agentInfo: (id: String?, name: String?)) -> AgentStatus {
        let s = summary.lowercased()
        if s.contains("error") || s.contains("failed") || s.contains("traceback") {
            return .error
        }
        if s.contains("complete") || s.contains("✓") || s.contains("✅") {
            return .completed
        }
        if agentInfo.id != nil || agentInfo.name != nil {
            return .running
        }
        return .idle
    }
}

private struct TmuxPaneInfo {
    let session: String
    let windowIndex: Int
    let windowName: String
    let paneIndex: Int
    let paneId: String
    let pid: Int
    let tty: String
    let startTimeSec: Int
    let command: String
}
