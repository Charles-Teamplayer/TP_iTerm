import Foundation

struct ClaudeSession: Identifiable, Hashable {
    var id: Int { pid }
    let pid: Int
    let tty: String
    let projectName: String
    let startTime: String

    func hash(into hasher: inout Hasher) { hasher.combine(pid) }
    static func == (lhs: ClaudeSession, rhs: ClaudeSession) -> Bool { lhs.pid == rhs.pid }
}
