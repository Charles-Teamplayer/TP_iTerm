import Foundation

enum ClaudeStatus: String {
    case idle     = "active"    // 입력 대기 (초록)
    case working  = "working"   // 작업 중 (스피너)
    case starting = "starting"  // 시작 중
    case blocked  = "block"     // 권한 요청 대기
    case waiting  = "waiting"   // 기타 대기
    case unknown  = ""

    var label: String {
        switch self {
        case .idle:     return "대기 중"
        case .working:  return "작업 중"
        case .starting: return "시작 중"
        case .blocked:  return "확인 필요"
        case .waiting:  return "대기"
        case .unknown:  return ""
        }
    }
}

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
    var profileRoot: String? = nil
    var profileDelay: Int = 0
    var isActivated: Bool = false
    var isAssigned: Bool = true
    var claudeStatus: ClaudeStatus = .unknown  // tab-color/states 기반 실시간 상태
    var didCrash: Bool = false                 // running→false 비정상 종료 감지 시 true

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: ClaudeSession, rhs: ClaudeSession) -> Bool { lhs.id == rhs.id }
}
