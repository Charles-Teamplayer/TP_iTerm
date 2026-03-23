import Foundation

struct ClaudeSession: Identifiable, Hashable {
    let id: String
    let pid: Int
    let tty: String
    let projectName: String
    let startTime: String
    let directory: String
    let windowName: String
    let windowIndex: Int
    let isRunning: Bool
    var profileRoot: String? = nil   // 프로필 기반 세션이면 설정
    var profileDelay: Int = 0

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: ClaudeSession, rhs: ClaudeSession) -> Bool { lhs.id == rhs.id }
}
