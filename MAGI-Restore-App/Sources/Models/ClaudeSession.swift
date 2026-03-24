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
    var isActivated: Bool = false    // 활성화 플래그 (hide=유지, kill=해제)
    var isAssigned: Bool = true      // 어떤 윈도우 그룹에도 배정되지 않으면 false → 프로세스 미실행

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: ClaudeSession, rhs: ClaudeSession) -> Bool { lhs.id == rhs.id }
}
