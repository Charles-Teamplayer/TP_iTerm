import Foundation

@MainActor
final class WindowGroupService: ObservableObject {
    @Published var groups: [WindowPane] = []

    private let jsonPath = NSHomeDirectory() + "/.claude/window-groups.json"
    static let defaultSessionName = "claude-work"

    func load() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: jsonPath)),
              let decoded = try? JSONDecoder().decode([WindowPane].self, from: data) else {
            if groups.isEmpty {
                groups = defaultGroups()
                save()  // 기본 그룹을 즉시 파일로 저장 (다음 로드 시 재생성 방지)
            }
            return
        }
        groups = decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(groups) else { return }
        try? data.write(to: URL(fileURLWithPath: jsonPath), options: .atomic)
    }

    // 프로필이 속한 그룹 반환 (없으면 첫 번째 그룹, 그것도 없으면 기본값)
    func group(for profileName: String) -> WindowPane {
        return groups.first { $0.profileNames.contains(profileName) }
            ?? groups.first
            ?? WindowPane(name: "메인", sessionName: Self.defaultSessionName, profileNames: [])
    }

    // 프로필 이름 변경 (windowGroup 내 이름도 동기화)
    func renameProfile(oldName: String, newName: String) {
        for i in groups.indices {
            if let pi = groups[i].profileNames.firstIndex(of: oldName) {
                groups[i].profileNames[pi] = newName
            }
        }
        save()
    }

    // 프로필을 다른 그룹으로 이동
    func moveProfile(_ profileName: String, to target: WindowPane) {
        for i in groups.indices {
            groups[i].profileNames.removeAll { $0 == profileName }
        }
        if let idx = groups.firstIndex(where: { $0.id == target.id }) {
            groups[idx].profileNames.append(profileName)
        }
        save()
    }

    // 새 창(그룹) 추가
    func addGroup(name: String) {
        let sessionName = "claude-" + name
            .lowercased()
            .components(separatedBy: .whitespaces).joined(separator: "-")
        groups.append(WindowPane(name: name, sessionName: sessionName, profileNames: []))
        save()
    }

    // 그룹 삭제 (프로필은 첫 번째 그룹으로 이동)
    func deleteGroup(_ group: WindowPane) {
        guard groups.count > 1, let idx = groups.firstIndex(where: { $0.id == group.id }) else { return }
        let orphans = groups[idx].profileNames
        groups.remove(at: idx)
        groups[0].profileNames.append(contentsOf: orphans)
        save()
    }

    // 그룹 이름/세션명 업데이트
    func updateGroup(_ group: WindowPane, name: String) {
        guard let idx = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[idx].name = name
        save()
    }

    // 그룹 내 프로필 순서 변경
    func moveProfileInGroup(_ profileName: String, groupId: UUID, up: Bool) {
        guard let gi = groups.firstIndex(where: { $0.id == groupId }),
              let pi = groups[gi].profileNames.firstIndex(of: profileName) else { return }
        let target = up ? pi - 1 : pi + 1
        guard target >= 0, target < groups[gi].profileNames.count else { return }
        groups[gi].profileNames.swapAt(pi, target)
        save()
    }

    private func defaultGroups() -> [WindowPane] {
        [WindowPane(name: "메인", sessionName: "claude-work", profileNames: [])]
    }

    // 앱 시작 시 호출 — 파일이 없으면 기본 그룹 파일 생성 (@MainActor 불필요)
    static func bootstrapIfNeeded() {
        let path = NSHomeDirectory() + "/.claude/window-groups.json"
        guard !FileManager.default.fileExists(atPath: path) else { return }
        let defaults = [WindowPane(name: "메인", sessionName: "claude-work", profileNames: [])]
        guard let data = try? JSONEncoder().encode(defaults) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}
