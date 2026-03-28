import Foundation

@MainActor
final class BackupService: ObservableObject {
    @Published var config: BackupConfig = .default
    @Published var isRunning: Bool = false
    @Published var restoreError: String? = nil

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

    // MARK: - Snapshot 생성 (핵심 3파일)

    func runBackup() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        let expandedBase = expandPath(config.path)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let snapshotId = formatter.string(from: Date())
        let snapshotDir = expandedBase + "/" + snapshotId

        let claudeDir = NSHomeDirectory() + "/.claude"
        var copiedFiles: [String] = []

        // 대상 파일 복사
        for filename in BackupConfig.targetFiles {
            let src = claudeDir + "/" + filename
            guard FileManager.default.fileExists(atPath: src) else { continue }
            let dest = snapshotDir + "/" + filename
            let result = await ShellService.runAsync(
                "mkdir -p \(ShellService.shellq(snapshotDir)) && cp \(ShellService.shellq(src)) \(ShellService.shellq(dest)) && echo ok"
            )
            if result.contains("ok") {
                copiedFiles.append(filename)
            }
        }

        guard !copiedFiles.isEmpty else { return }

        let displayFormatter = DateFormatter()
        displayFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let snapshot = ConfigSnapshot(
            id: snapshotId,
            createdAt: displayFormatter.string(from: Date()),
            files: copiedFiles
        )

        var updated = config
        updated.lastBackup = snapshot.createdAt
        updated.snapshots.insert(snapshot, at: 0)
        // 최대 20개 유지
        if updated.snapshots.count > 20 {
            let toRemove = updated.snapshots.suffix(from: 20)
            for old in toRemove {
                let oldDir = expandedBase + "/" + old.id
                try? FileManager.default.removeItem(atPath: oldDir)
            }
            updated.snapshots = Array(updated.snapshots.prefix(20))
        }
        save(updated)
    }

    // MARK: - Snapshot 복원

    func restoreSnapshot(_ snapshot: ConfigSnapshot) async -> Bool {
        let expandedBase = expandPath(config.path)
        let snapshotDir = expandedBase + "/" + snapshot.id
        let claudeDir = NSHomeDirectory() + "/.claude"

        for filename in snapshot.files {
            let src = snapshotDir + "/" + filename
            let dest = claudeDir + "/" + filename
            guard FileManager.default.fileExists(atPath: src) else { continue }
            let result = await ShellService.runAsync(
                "cp \(ShellService.shellq(src)) \(ShellService.shellq(dest)) && echo ok"
            )
            if !result.contains("ok") {
                return false
            }
        }
        return true
    }

    func deleteSnapshot(_ snapshot: ConfigSnapshot) {
        let expandedBase = expandPath(config.path)
        let snapshotDir = expandedBase + "/" + snapshot.id
        try? FileManager.default.removeItem(atPath: snapshotDir)
        var updated = config
        updated.snapshots.removeAll { $0.id == snapshot.id }
        save(updated)
    }

    private func expandPath(_ path: String) -> String {
        path.hasPrefix("~") ? NSHomeDirectory() + path.dropFirst() : path
    }
}
