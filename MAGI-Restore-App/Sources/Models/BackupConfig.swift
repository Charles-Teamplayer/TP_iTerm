import Foundation

struct ConfigSnapshot: Codable, Identifiable {
    var id: String          // 타임스탬프 기반 (예: "2026-03-28_20-30-00")
    var createdAt: String   // 표시용 날짜
    var files: [String]     // 포함된 파일명 목록
}

struct BackupConfig: Codable {
    var enabled: Bool
    var path: String
    var lastBackup: String?
    var snapshots: [ConfigSnapshot]

    static let `default` = BackupConfig(
        enabled: true,
        path: "~/.claude/config-snapshots",
        lastBackup: nil,
        snapshots: []
    )

    // 백업 대상 파일 (SPOF 핵심 3개)
    static let targetFiles = [
        "window-groups.json",
        "active-sessions.json",
        "activated-sessions.json"
    ]
}
