import Foundation

@MainActor
final class ProfileService: ObservableObject {
    @Published var profiles: [SmugProfile] = []

    private let smugDir = NSHomeDirectory() + "/.config/smug"
    private let defaultYmlPath = NSHomeDirectory() + "/.config/smug/claude-work.yml"

    func load() {
        // 1. 모든 smug YAML에서 로드 (세션별 YAML 통합)
        var fromYml: [SmugProfile] = []
        var seenNames = Set<String>()
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(atPath: smugDir) {
            for file in files.sorted() where file.hasPrefix("claude-") && file.hasSuffix(".yml") {
                let path = smugDir + "/" + file
                if let contents = try? String(contentsOfFile: path, encoding: .utf8) {
                    for profile in parseYml(contents) {
                        guard !seenNames.contains(profile.name) else { continue }
                        seenNames.insert(profile.name)
                        fromYml.append(profile)
                    }
                }
            }
        }

        // 2. activated-sessions.json에서 merge (YAML에 없는 경로만 추가)
        let ymlNames = Set(fromYml.map { $0.name })
        let activatedPaths = loadActivatedPaths()
        var merged = fromYml
        for path in activatedPaths {
            let name = (path as NSString).lastPathComponent
            guard !name.isEmpty, !ymlNames.contains(name) else { continue }
            merged.append(SmugProfile(
                id: stableID(for: name),
                name: name,
                root: path,
                delay: 0,
                enabled: true
            ))
        }
        profiles = merged
    }

    private func loadActivatedPaths() -> [String] {
        let path = NSHomeDirectory() + "/.claude/activated-sessions.json"
        for candidate in [path, path + ".bak"] {
            guard let data = FileManager.default.contents(atPath: candidate),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = obj["activated"] as? [String] else { continue }
            return list
        }
        return []
    }

    func save(_ profiles: [SmugProfile]) {
        let normalized = profiles.enumerated().map { idx, p in
            SmugProfile(id: p.id, name: p.name, root: p.root, delay: idx * 5, enabled: p.enabled)
        }
        let yml = generateYml(normalized, sessionName: "claude-work")
        try? yml.write(toFile: defaultYmlPath, atomically: true, encoding: .utf8)
        self.profiles = normalized
    }

    /// window-groups.json 기반으로 세션별 YAML 파일 생성
    func savePerSession(groups: [WindowPane]) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: smugDir) {
            try? fm.createDirectory(atPath: smugDir, withIntermediateDirectories: true)
        }

        let profileMap = Dictionary(uniqueKeysWithValues: profiles.map { ($0.name, $0) })

        for group in groups where !group.isWaitingList {
            let sessionName = group.sessionName
            guard !sessionName.isEmpty, sessionName != "__waiting__" else { continue }
            let ymlPath = smugDir + "/\(sessionName).yml"

            // 이 그룹에 속한 프로필만 추출
            let groupProfiles = group.profileNames.enumerated().compactMap { idx, name -> SmugProfile? in
                guard var p = profileMap[name] else { return nil }
                p.delay = idx * 5
                return p
            }
            let yml = generateYml(groupProfiles, sessionName: sessionName)
            try? yml.write(toFile: ymlPath, atomically: true, encoding: .utf8)
        }
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

    private func generateYml(_ profiles: [SmugProfile], sessionName: String) -> String {
        var lines = ["session: \(sessionName)", "windows:"]
        for profile in profiles {
            let safeName = profile.name.contains(":") || profile.name.contains("\"") || profile.name.contains("'")
                ? "\"\(profile.name.replacingOccurrences(of: "\"", with: "\\\""))\""
                : profile.name
            lines.append("  - name: \(safeName)")
            let needsQuote = profile.root.contains(" ") || profile.root.contains("\"") ||
                profile.root.contains("#") || profile.root.contains("{") || profile.root.contains("}")
            let safeRoot = profile.root.replacingOccurrences(of: "\"", with: "\\\"")
            let rootStr = needsQuote ? "\"\(safeRoot)\"" : profile.root
            lines.append("    root: \(rootStr)")
            lines.append("    commands:")
            let name = profile.name
            let shellName = "'" + name.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let delay = profile.delay
            let statusCmd = "bash ~/.claude/scripts/tab-status.sh starting \(shellName) && "
            let cmd = "sleep \(delay) && \(statusCmd)unset CLAUDECODE && claude --dangerously-skip-permissions --continue"
            lines.append("      - \(cmd)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
