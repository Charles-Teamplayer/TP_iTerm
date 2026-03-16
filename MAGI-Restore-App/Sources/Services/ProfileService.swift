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
        let yml = generateYml(profiles)
        try? yml.write(toFile: ymlPath, atomically: true, encoding: .utf8)
        self.profiles = profiles
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
                    let profile = SmugProfile(
                        name: name,
                        root: currentRoot ?? "",
                        delay: currentDelay,
                        enabled: true
                    )
                    result.append(profile)
                }
                currentName = extractValue(from: trimmed, key: "- name:")
                currentRoot = nil
                currentDelay = 0
            } else if trimmed.hasPrefix("root:") {
                currentRoot = extractValue(from: trimmed, key: "root:")
            } else if trimmed.contains("sleep") {
                // sleep 0 && bash ... 패턴에서 delay 추출
                if let sleepRange = trimmed.range(of: "sleep ") {
                    let afterSleep = String(trimmed[sleepRange.upperBound...])
                    let sleepVal = afterSleep.components(separatedBy: " ").first ?? "0"
                    currentDelay = Int(sleepVal) ?? 0
                }
            }
        }

        if let name = currentName {
            let profile = SmugProfile(
                name: name,
                root: currentRoot ?? "",
                delay: currentDelay,
                enabled: true
            )
            result.append(profile)
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
            lines.append("  - name: \(profile.name)")
            lines.append("    root: \(profile.root)")
            lines.append("    commands:")
            lines.append("      - sleep \(profile.delay) && claude --dangerously-skip-permissions")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
