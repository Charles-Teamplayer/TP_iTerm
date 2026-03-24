import Foundation

@MainActor
final class ProfileService: ObservableObject {
    @Published var profiles: [SmugProfile] = []

    private let ymlPath = NSHomeDirectory() + "/.config/smug/claude-work.yml"

    func load() {
        guard let contents = try? String(contentsOfFile: ymlPath, encoding: .utf8) else {
            profiles = []
            return
        }
        profiles = parseYml(contents)
    }

    func save(_ profiles: [SmugProfile]) {
        // 저장 시 delay를 position 기반으로 정규화 (0, 5, 10, 15...)
        let normalized = profiles.enumerated().map { idx, p in
            SmugProfile(id: p.id, name: p.name, root: p.root, delay: idx * 5, enabled: p.enabled)
        }
        let yml = generateYml(normalized)
        try? yml.write(toFile: ymlPath, atomically: true, encoding: .utf8)
        self.profiles = normalized
    }

    func add(_ profile: SmugProfile) {
        var updated = profiles
        updated.append(profile)
        save(updated)
    }

    func delete(_ profile: SmugProfile) {
        let updated = profiles.filter { $0.id != profile.id }
        save(updated)
    }

    private func stableID(for name: String) -> UUID {
        let data = Data(name.utf8)
        var bytes = [UInt8](repeating: 0, count: 16)
        for (i, byte) in data.enumerated() {
            bytes[i % 16] ^= byte
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private func parseYml(_ contents: String) -> [SmugProfile] {
        var result: [SmugProfile] = []
        let lines = contents.components(separatedBy: "\n")

        var currentName: String?
        var currentRoot: String?
        var currentDelay: Int = 0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("- name:") {
                if let name = currentName {
                    result.append(SmugProfile(
                        id: stableID(for: name),
                        name: name,
                        root: (currentRoot?.isEmpty == false) ? (currentRoot ?? "~/claude/\(name)") : "~/claude/\(name)",
                        delay: currentDelay,
                        enabled: true
                    ))
                }
                currentName = extractValue(from: trimmed, key: "- name:")
                currentRoot = nil
                currentDelay = 0
            } else if trimmed.hasPrefix("root:") {
                currentRoot = extractValue(from: trimmed, key: "root:")
            } else if trimmed.contains("sleep") {
                if let sleepRange = trimmed.range(of: "sleep ") {
                    let afterSleep = String(trimmed[sleepRange.upperBound...])
                    let sleepVal = afterSleep.components(separatedBy: " ").first ?? "0"
                    currentDelay = Int(sleepVal) ?? 0
                }
            }
        }

        if let name = currentName {
            result.append(SmugProfile(
                id: stableID(for: name),
                name: name,
                root: currentRoot ?? "",
                delay: currentDelay,
                enabled: true
            ))
        }

        return result
    }

    private func extractValue(from line: String, key: String) -> String {
        let value = line.replacingOccurrences(of: key, with: "")
            .trimmingCharacters(in: .whitespaces)
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    private func generateYml(_ profiles: [SmugProfile]) -> String {
        var lines = ["session: claude-work", "windows:"]
        for profile in profiles {
            let safeName = profile.name.contains(":") || profile.name.contains("\"") || profile.name.contains("'")
                ? "\"\(profile.name.replacingOccurrences(of: "\"", with: "\\\""))\""
                : profile.name
            lines.append("  - name: \(safeName)")
            let rootStr = profile.root.contains(" ") ? "\"\(profile.root)\"" : profile.root
            lines.append("    root: \(rootStr)")
            lines.append("    commands:")
            let name = profile.name
            let shellName = name.contains(" ") ? "'\(name)'" : name
            let delay = profile.delay
            let statusCmd = "bash ~/.claude/scripts/tab-status.sh starting \(shellName) && "
            let cmd = "sleep \(delay) && \(statusCmd)unset CLAUDECODE && claude --dangerously-skip-permissions --continue"
            lines.append("      - \(cmd)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
