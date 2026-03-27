import Foundation

@MainActor
final class WindowGroupService: ObservableObject {
    @Published var groups: [WindowPane] = []

    private let jsonPath = NSHomeDirectory() + "/.claude/window-groups.json"
    static let defaultSessionName = "claude-work"

    func load() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: jsonPath)),
              var decoded = try? JSONDecoder().decode([WindowPane].self, from: data) else {
            if groups.isEmpty {
                groups = defaultGroups()
                save()  // 기본 그룹을 즉시 파일로 저장 (다음 로드 시 재생성 방지)
            }
            return
        }
        // Waiting List이 없으면 추가, 항상 최상단 고정
        if !decoded.contains(where: { $0.isWaitingList }) {
            let wl = WindowPane(name: "Waiting List", sessionName: "__waiting__",
                                profileNames: [], isWaitingList: true)
            decoded.insert(wl, at: 0)
        } else {
            // Waiting List을 항상 첫 번째로 이동
            if let idx = decoded.firstIndex(where: { $0.isWaitingList }), idx != 0 {
                let wl = decoded.remove(at: idx)
                decoded.insert(wl, at: 0)
            }
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
            ?? WindowPane(name: "Main", sessionName: Self.defaultSessionName, profileNames: [])
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

    // Waiting List pane (없으면 자동 생성)
    var waitingList: WindowPane {
        groups.first { $0.isWaitingList } ?? ensureWaitingList()
    }

    @discardableResult
    func ensureWaitingList() -> WindowPane {
        if let existing = groups.first(where: { $0.isWaitingList }) { return existing }
        let wl = WindowPane(name: "Waiting List", sessionName: "__waiting__",
                            profileNames: [], isWaitingList: true)
        groups.insert(wl, at: 0)  // 항상 최상단
        save()
        return wl
    }

    // 그룹 삭제 (프로필은 첫 번째 남은 활성 그룹으로 이동, Waiting List 자체는 삭제 불가)
    func deleteGroup(_ group: WindowPane) {
        guard !group.isWaitingList,
              groups.filter({ !$0.isWaitingList }).count > 1,
              let idx = groups.firstIndex(where: { $0.id == group.id }) else { return }
        let orphans = groups[idx].profileNames
        groups.remove(at: idx)
        // Waiting List이 아닌 첫 번째 그룹으로 이동 (checkAutoSync 오작동 방지)
        if let firstActive = groups.firstIndex(where: { !$0.isWaitingList }) {
            groups[firstActive].profileNames.append(contentsOf: orphans)
        }
        save()
    }


    // 그룹 내 프로필 순서 변경 (위/아래 이동)
    func moveProfileInGroup(_ profileName: String, groupId: UUID, up: Bool) {
        guard let gi = groups.firstIndex(where: { $0.id == groupId }),
              let pi = groups[gi].profileNames.firstIndex(of: profileName) else { return }
        let target = up ? pi - 1 : pi + 1
        guard target >= 0, target < groups[gi].profileNames.count else { return }
        groups[gi].profileNames.swapAt(pi, target)
        save()
    }

    // 그룹 내 프로필을 특정 인덱스로 이동 (탭 번호 직접 지정)
    func moveProfileToIndex(_ profileName: String, groupId: UUID, index: Int) {
        guard let gi = groups.firstIndex(where: { $0.id == groupId }),
              let pi = groups[gi].profileNames.firstIndex(of: profileName) else { return }
        let clamped = max(0, min(index, groups[gi].profileNames.count - 1))
        var names = groups[gi].profileNames
        names.remove(at: pi)
        names.insert(profileName, at: clamped)
        groups[gi].profileNames = names
        save()
    }

    // 그룹 이름 + 세션명 동시 업데이트
    func updateGroup(_ group: WindowPane, name: String, sessionName: String) {
        guard let idx = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[idx].name = name
        groups[idx].sessionName = sessionName
        save()
    }

    private func defaultGroups() -> [WindowPane] {
        [
            WindowPane(name: "Main", sessionName: "claude-work", profileNames: []),
            WindowPane(name: "Waiting List", sessionName: "__waiting__", profileNames: [], isWaitingList: true),
        ]
    }

    // 앱 시작 시 호출 — 파일이 없으면 기본 그룹 파일 생성 (@MainActor 불필요)
    static func bootstrapIfNeeded() {
        let path = NSHomeDirectory() + "/.claude/window-groups.json"
        guard !FileManager.default.fileExists(atPath: path) else { return }
        let defaults = [
            WindowPane(name: "Main", sessionName: "claude-work", profileNames: []),
            WindowPane(name: "Waiting List", sessionName: "__waiting__", profileNames: [], isWaitingList: true),
        ]
        guard let data = try? JSONEncoder().encode(defaults) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
