import Foundation

struct WindowPane: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String           // UI 표시명 (e.g. "메인", "IMSMS")
    var sessionName: String    // tmux 세션명 (e.g. "claude-work", "claude-imsms")
    var profileNames: [String] // SmugProfile.name 순서대로
}
