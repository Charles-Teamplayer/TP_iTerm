import Foundation

/// ~/.claude/activated-sessions.json 관리
/// 활성화된 세션 목록을 경로(root) 기준으로 저장
final class ActivationService {
    static let shared = ActivationService()
    private let filePath = NSHomeDirectory() + "/.claude/activated-sessions.json"

    private init() {}

    // MARK: - Read

    func loadActivated() -> Set<String> {
        guard let data = FileManager.default.contents(atPath: filePath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["activated"] as? [String] else {
            return []
        }
        return Set(list)
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
        root.hasPrefix("~")
            ? root.replacingOccurrences(of: "~", with: NSHomeDirectory(),
                                        range: root.range(of: "~"))
            : root
    }

    private func persist(_ set: Set<String>) {
        let obj: [String: Any] = [
            "activated": Array(set).sorted(),
            "last_updated": ISO8601DateFormatter().string(from: Date())
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted) else { return }
        try? data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
    }
}
