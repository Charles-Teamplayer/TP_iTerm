import Foundation
import Combine

@MainActor
final class CodexMonitorService: ObservableObject {
    @Published var agents: [AgentSession] = []
    @Published var lastUpdate: Date = Date()
    private var pollTask: Task<Void, Never>?

    func start() {
        NSLog("[CodexMon] start() called")
        appendStartupLog("start() called")
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            NSLog("[CodexMon] pollTask launched")
            await self?.appendStartupLogFromTask("pollTask launched")
            var iter = 0
            while !Task.isCancelled {
                iter += 1
                NSLog("[CodexMon] iter=\(iter) refresh begin")
                await self?.appendStartupLogFromTask("iter=\(iter) refresh begin")
                await self?.refresh()
                NSLog("[CodexMon] iter=\(iter) refresh done — sleep 10s")
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
            NSLog("[CodexMon] pollTask CANCELLED iter=\(iter)")
        }
    }

    private func appendStartupLog(_ msg: String) {
        let dir = (logFile as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] STARTUP: \(msg)\n"
        if let data = line.data(using: .utf8) {
            if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: logFile)) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: logFile))
            }
        }
    }
    private func appendStartupLogFromTask(_ msg: String) async {
        appendStartupLog(msg)
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    // FIX-V (2026-05-07): 자식 worker 프로세스(--agent-id, codex exec) 도 별도 row로 표시
    // 디버그 로그: ~/.claude/logs/codex-monitor.log
    private let logFile = NSHomeDirectory() + "/.claude/logs/codex-monitor.log"

    private func dlog(_ msg: String) {
        let dir = (logFile as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(msg)\n"
        if let data = line.data(using: .utf8) {
            if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: logFile)) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: logFile))
            }
        }
    }

    func refresh() async {
        dlog("STEP-1 refresh entry")
        let panes = await fetchTmuxPanes()
        dlog("STEP-2 fetchTmuxPanes done: \(panes.count) panes")
        let workers = await fetchActiveWorkers()
        dlog("STEP-3 fetchActiveWorkers done: \(workers.count) workers")
        for w in workers { dlog("  worker pid=\(w.pid) ppid=\(w.ppid) type=\(w.type) name=\(w.name)") }

        // 부모 process chain → tmux pane 매핑
        let panePids = Set(panes.map { $0.pid })
        var result: [AgentSession] = []
        dlog("STEP-4 entering pane loop")
        for (i, pane) in panes.enumerated() {
            dlog("  STEP-4.\(i) pane=\(pane.session):\(pane.windowName)#\(pane.paneIndex)")
            let fullText = await fetchPaneSummary(target: "\(pane.session):\(pane.windowIndex).\(pane.paneIndex)")
            let startTime = Date(timeIntervalSince1970: TimeInterval(pane.startTimeSec))

            // 1) 부모 row (pane index 0 — 부모 Claude)
            let parentInfo = await extractAgentInfo(panePid: pane.pid, paneTty: pane.tty)
            let parentStatus = determineStatus(summary: fullText, agentInfo: parentInfo)
            let summary = extractLastMeaningfulLine(fullText)
            result.append(AgentSession(
                id: pane.paneId,
                tmuxSession: pane.session,
                windowIndex: pane.windowIndex,
                windowName: pane.windowName,
                paneIndex: pane.paneIndex,
                panePid: pane.pid,
                paneTty: pane.tty,
                agentId: parentInfo.id,
                agentName: parentInfo.name,
                startTime: startTime,
                endTime: nil,
                status: parentStatus,
                summary: summary,
                isParent: pane.paneIndex == 0
            ))

            // 2) 그 pane의 자식 worker (codex exec / --agent-id) 별도 row
            let paneWorkers = workers.filter { isDescendantOf(parentPid: pane.pid, childPid: $0.pid, allPids: panePids) }
            for w in paneWorkers {
                result.append(AgentSession(
                    id: "worker-\(w.pid)",
                    tmuxSession: pane.session,
                    windowIndex: pane.windowIndex,
                    windowName: pane.windowName,
                    paneIndex: 100 + (paneWorkers.firstIndex(where: { $0.pid == w.pid }) ?? 0),
                    panePid: w.pid,
                    paneTty: pane.tty,
                    agentId: w.type == "codex" ? "codex-exec" : w.name,
                    agentName: w.name,
                    startTime: startTime,
                    endTime: nil,
                    status: .running,
                    summary: w.summary,
                    isParent: false
                ))
                dlog("  attached worker pid=\(w.pid) → \(pane.session):\(pane.windowName)")
            }
        }
        dlog("refresh result: \(result.count) total agents")
        agents = result
        lastUpdate = Date()
    }

    // FIX-X (2026-05-07): 성능 최적화 — ps 1번만, leaf-only, ppid map 캐시
    private var ppidCache: [Int: Int] = [:]

    private func fetchActiveWorkers() async -> [WorkerInfo] {
        // FIX-CC (2026-05-07): ps 출력 sandboxing — pipe buffer overflow 방지
        // ppidCache는 작은 ps -A -o pid=,ppid= 로, candidates는 grep으로 사전 필터
        ppidCache.removeAll()
        let ppidRaw = await ShellService.runAsync("ps -A -o pid=,ppid= 2>/dev/null")
        for line in ppidRaw.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let comps = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            if comps.count == 2, let pid = Int(comps[0]), let ppid = Int(comps[1]) {
                ppidCache[pid] = ppid
            }
        }
        dlog("  fetchActiveWorkers: ppidCache=\(ppidCache.count)")

        // worker candidates 만 grep으로 (출력 작음)
        let raw = await ShellService.runAsync("""
            ps -ax -o pid,ppid,command 2>/dev/null \
              | grep -E -- '--agent-id|codex exec' \
              | grep -v 'app-server' \
              | grep -v 'broker' \
              | grep -v ' grep ' \
              | head -50
        """)
        var candidates: [(pid: Int, ppid: Int, cmd: String)] = []
        for line in raw.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let comps = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard comps.count >= 3,
                  let pid = Int(comps[0]),
                  let ppid = Int(comps[1]) else { continue }
            candidates.append((pid, ppid, String(comps[2])))
        }
        dlog("  fetchActiveWorkers: candidates=\(candidates.count)")
        // leaf only — 다른 candidate의 ppid에 자기 pid가 안 보이면 leaf
        let allPpids = Set(candidates.map { $0.ppid })
        let leaves = candidates.filter { !allPpids.contains($0.pid) }

        return leaves.map { c -> WorkerInfo in
            let cmd = c.cmd
            let type: String
            let name: String
            if cmd.contains("--agent-id") {
                type = "agent"
                name = cmd.range(of: "--agent-name ").flatMap { r -> String? in
                    let rest = cmd[r.upperBound...]
                    return String(rest.split(separator: " ").first ?? "")
                } ?? "agent"
            } else {
                type = "codex"
                // prompt 안에서 "Agent X —" 또는 "Phase X" 패턴 추출
                let label = extractCodexLabel(cmd) ?? "codex"
                name = label
            }
            let summary = extractWorkerSummary(cmd)
            return WorkerInfo(pid: c.pid, ppid: c.ppid, type: type, name: name, summary: summary)
        }
    }

    private func extractCodexLabel(_ cmd: String) -> String? {
        // "Agent L —" / "Agent Q —" / "Phase X" 같은 라벨 추출
        let patterns = [#"Agent [A-Z]\b"#, #"Phase [A-Z]+"#, #"# [A-Z][\w가-힣 ]{3,40}"#]
        for p in patterns {
            if let r = cmd.range(of: p, options: .regularExpression) {
                return String(cmd[r])
            }
        }
        // fallback: prompt 첫 의미있는 단어
        if let r = cmd.range(of: "codex exec ")?.upperBound {
            let rest = cmd[r...]
            // " --" flag 이후 첫 따옴표 prompt
            if let q = rest.range(of: "\"") {
                let after = rest[q.upperBound...]
                let first40 = String(after.prefix(40)).replacingOccurrences(of: "\\", with: "")
                return "codex: " + first40
            }
        }
        return nil
    }

    private func extractWorkerSummary(_ cmd: String) -> String {
        // 첫 의미 있는 줄 (\012 = \n) — 너무 긴 export 등 제외
        let lines = cmd.components(separatedBy: "\\012")
        for l in lines {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.count > 10, !t.hasPrefix("export "), !t.hasPrefix(":"), !t.hasPrefix("source ") {
                return String(t.prefix(140))
            }
        }
        return String(cmd.prefix(140))
    }

    private func isDescendantOf(parentPid: Int, childPid: Int, allPids: Set<Int>) -> Bool {
        // 캐시된 ppid map만 사용 — ps 호출 X (성능)
        var cur = childPid
        for _ in 0..<15 {
            if cur == parentPid { return true }
            guard let ppid = ppidCache[cur], ppid > 1 else { return false }
            if ppid == parentPid { return true }
            cur = ppid
        }
        return false
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

    // FIX-T (2026-05-07): summary는 마지막 줄이 아닌 화면 전체 텍스트 (working 패턴 검사용)
    private func fetchPaneSummary(target: String) async -> String {
        let raw = await ShellService.runAsync(
            "tmux capture-pane -t '\(target)' -p 2>/dev/null | tail -15"
        )
        return raw  // 전체 텍스트 보존 (status 판별 + 마지막 의미줄 추출 둘 다 가능)
    }

    private func extractLastMeaningfulLine(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "❯" && !$0.hasPrefix("─") }
        return lines.last.map { String($0.prefix(120)) } ?? ""
    }

    private func determineStatus(summary: String, agentInfo: (id: String?, name: String?)) -> AgentStatus {
        let s = summary.lowercased()
        if s.contains("error") || s.contains("failed") || s.contains("traceback") {
            return .error
        }
        // FIX-T: Claude Code working indicator 패턴 감지
        // — "✻ Working" / "Cogitating" / "Bash(" / "Edit(" / "Read(" / "Running" / "esc to interrupt"
        let workingPatterns = ["✻", "cogitating", "esc to interrupt", "bash(", "edit(", "read(", "write(", "✺", "tokens"]
        for p in workingPatterns {
            if s.contains(p) { return .running }
        }
        if agentInfo.id != nil || agentInfo.name != nil {
            return .running
        }
        if s.contains("complete") || s.contains("✓") || s.contains("✅") {
            return .completed
        }
        return .idle
    }
}

private struct WorkerInfo {
    let pid: Int
    let ppid: Int
    let type: String     // "agent" | "codex"
    let name: String
    let summary: String
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
