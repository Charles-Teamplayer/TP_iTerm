import Foundation

struct BackupConfig: Codable {
    var enabled: Bool
    var path: String
    var lastBackup: String?

    static let `default` = BackupConfig(
        enabled: true,
        path: "~/.claude/backups",
        lastBackup: nil
    )
}
