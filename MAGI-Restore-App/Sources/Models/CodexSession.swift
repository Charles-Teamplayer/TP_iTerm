import Foundation

struct AgentSession: Identifiable, Hashable {
    let id: String              // pane_id (%N) - unique
    let tmuxSession: String     // claude-work
    let windowIndex: Int        // tmux window index
    let windowName: String      // TP_newIMSMS
    let paneIndex: Int          // 0=parent, 1+=sub-agent
    let panePid: Int
    let paneTty: String
    let agentId: String?        // --agent-id value, e.g. "VERDANDI@team-name"
    let agentName: String?      // --agent-name value, e.g. "VERDANDI"
    let startTime: Date
    let endTime: Date?
    let status: AgentStatus
    let summary: String         // latest output line
    let isParent: Bool          // pane index == 0

    var elapsedSeconds: Int {
        Int((endTime ?? Date()).timeIntervalSince(startTime))
    }

    var elapsedFormatted: String {
        let s = elapsedSeconds
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \(s % 3600 / 60)m"
    }
}

enum AgentStatus: String, Hashable {
    case running = "Running"
    case idle = "Idle"
    case completed = "Completed"
    case error = "Error"

    var color: String {
        switch self {
        case .running: return "green"
        case .idle: return "gray"
        case .completed: return "blue"
        case .error: return "red"
        }
    }
}
