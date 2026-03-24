import Foundation

@MainActor
final class BackupService: ObservableObject {
    @Published var config: BackupConfig = .default
    @Published var isRunning: Bool = false

    private let configPath = NSHomeDirectory() + "/.claude/backup-config.json"

    func load() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let decoded = try? JSONDecoder().decode(BackupConfig.self, from: data) else {
            config = .default
            return
        }
        config = decoded
    }

    func save(_ updated: BackupConfig) {
        config = updated
        if let data = try? JSONEncoder().encode(updated) {
            try? data.write(to: URL(fileURLWithPath: configPath), options: .atomic)
        }
    }

    func runBackup() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        let expandedPath = config.path.hasPrefix("~") ? NSHomeDirectory() + config.path.dropFirst() : config.path
        let sourceDir = NSHomeDirectory() + "/.claude"
        let result = await ShellService.runAsync(
            "mkdir -p '\(expandedPath)' && rsync -av --exclude='logs/' --exclude='*.tmp' --exclude='backups/' '\(sourceDir)/' '\(expandedPath)/' && echo '__RSYNC_OK__'"
        )

        var updated = config
        if result.contains("__RSYNC_OK__") {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            updated.lastBackup = formatter.string(from: Date())
        }
        save(updated)
    }
}
