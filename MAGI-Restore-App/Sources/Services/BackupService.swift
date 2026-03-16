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
            try? data.write(to: URL(fileURLWithPath: configPath))
        }
    }

    func runBackup() async {
        guard !isRunning else { return }
        isRunning = true

        let expandedPath = config.path.replacingOccurrences(of: "~", with: NSHomeDirectory())
        let sourceDir = NSHomeDirectory() + "/.claude"
        let result = await ShellService.runAsync(
            "rsync -a --delete '\(sourceDir)/' '\(expandedPath)/'"
        )

        var updated = config
        if result.isEmpty || !result.lowercased().contains("error") {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            updated.lastBackup = formatter.string(from: Date())
        }
        save(updated)
        isRunning = false
    }
}
