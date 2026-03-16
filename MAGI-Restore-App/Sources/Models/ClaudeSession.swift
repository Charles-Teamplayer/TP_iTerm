import Foundation

struct ClaudeSession: Identifiable, Hashable {
    let id = UUID()
    let pid: Int
    let tty: String
    let projectName: String
    let startTime: String
}
