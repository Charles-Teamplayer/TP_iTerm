import Foundation

/// ~/.claude/activated-sessions.json 관리
/// 활성화된 세션 목록을 경로(root) 기준으로 저장
@MainActor
final class ActivationService {
    static let shared = ActivationService()
    private let filePath = NSHomeDirectory() + "/.claude/activated-sessions.json"

    private init() {}

    // MARK: - Read

    func loadActivated() -> Set<String> {
        for path in [filePath, filePath + ".bak"] {
            guard let data = FileManager.default.contents(atPath: path),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = obj["activated"] as? [String] else { continue }
            return Set(list)
        }
        return []
    }

    func isActivated(root: String) -> Bool {
        loadActivated().contains(normalizedRoot(root))
    }

    // MARK: - Write

    func activate(root: String) {
        var set = loadActivated()
        set.insert(normalizedRoot(root))
        persist(set)
    }

    func deactivate(root: String) {
        var set = loadActivated()
        set.remove(normalizedRoot(root))
        persist(set)
    }

    // MARK: - Private

    private func normalizedRoot(_ root: String) -> String {
        guard root.hasPrefix("~") else { return root }
        return NSHomeDirectory() + root.dropFirst()
    }

    private func persist(_ set: Set<String>) {
        let obj: [String: Any] = [
            "activated": Array(set).sorted(),
            "last_updated": ISO8601DateFormatter().string(from: Date())
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted) else { return }
        // 쓰기 전 .bak 백업 (SPOF 방어: 손상 시 복구 가능)
        let bakPath = filePath + ".bak"
        if FileManager.default.fileExists(atPath: filePath) {
            try? FileManager.default.removeItem(atPath: bakPath)
            try? FileManager.default.copyItem(atPath: filePath, toPath: bakPath)
        }
        try? data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
    }
}
