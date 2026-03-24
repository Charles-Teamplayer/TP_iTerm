import SwiftUI

struct ProfilesView: View {
    @ObservedObject var monitor: SessionMonitor
    var searchFocused: FocusState<Bool>.Binding
    @Binding var selection: UUID?
    @State private var searchText = ""
    @State private var showAddSheet = false
    @State private var showAddGroupSheet = false
    @State private var syncResult: String? = nil
    @State private var editingProfile: SmugProfile?
    @State private var profileToDelete: SmugProfile?
    @State private var showDeleteConfirm = false
    @State private var movingProfile: SmugProfile?
    @State private var groupToDelete: WindowPane?
    @State private var showDeleteGroupConfirm = false

    private var wgs: WindowGroupService { monitor.windowGroupService }

    var body: some View {
        VStack(spacing: 0) {
            // 검색바
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                TextField("검색...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .focused(searchFocused)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                    ForEach(wgs.groups) { group in
                        groupSection(group)
                    }
                    // 어떤 그룹에도 없는 프로필
                    let unassigned = unassignedProfiles
                    if !unassigned.isEmpty {
                        unassignedSection(unassigned)
                    }
                }
            }

            Divider()
            bottomBar
        }
        .onAppear {
            monitor.profileService.load()
            wgs.load()
        }
        .sheet(isPresented: $showAddSheet) {
            ProfileFormSheet(title: "프로필 추가") { newProfile in
                monitor.profileService.add(newProfile)
                // 첫 번째 그룹에 자동 추가
                if let first = wgs.groups.first {
                    wgs.moveProfile(newProfile.name, to: first)
                }
            }
        }
        .sheet(isPresented: $showAddGroupSheet) {
            AddGroupSheet { name in
                wgs.addGroup(name: name)
            }
        }
        .sheet(item: $editingProfile) { profile in
            ProfileFormSheet(title: "프로필 편집", existing: profile) { updated in
                var list = monitor.profileService.profiles
                if let idx = list.firstIndex(where: { $0.id == profile.id }) {
                    list[idx] = updated
                    monitor.profileService.save(list)
                }
            }
        }
        .confirmationDialog(
            "'\(profileToDelete?.name ?? "")' 프로필을 삭제하시겠습니까?",
            isPresented: $showDeleteConfirm, titleVisibility: .visible
        ) {
            Button("삭제", role: .destructive) {
                if let p = profileToDelete { monitor.profileService.delete(p) }
            }
            Button("취소", role: .cancel) {}
        }
        .confirmationDialog(
            "'\(groupToDelete?.name ?? "")' 창을 삭제하시겠습니까? (프로필은 메인으로 이동)",
            isPresented: $showDeleteGroupConfirm, titleVisibility: .visible
        ) {
            Button("삭제", role: .destructive) {
                if let g = groupToDelete { wgs.deleteGroup(g) }
            }
            Button("취소", role: .cancel) {}
        }
    }

    // MARK: - 그룹 섹션

    private func groupSection(_ group: WindowPane) -> some View {
        let profiles = groupProfiles(group)
        let filtered = searchText.isEmpty ? profiles
            : profiles.filter { $0.name.localizedCaseInsensitiveContains(searchText) || $0.root.localizedCaseInsensitiveContains(searchText) }

        return Section {
            ForEach(Array(filtered.enumerated()), id: \.element.id) { idx, profile in
                profileRow(profile, group: group, index: idx, total: filtered.count)
                Divider().padding(.leading, 12)
            }
        } header: {
            groupHeader(group, profileCount: profiles.count)
        }
    }

    private func groupHeader(_ group: WindowPane, profileCount: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "macwindow")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(group.name)
                .font(.caption.bold())
            Text("· \(group.sessionName)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(profileCount)개")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            Button {
                Task { await monitor.startGroup(group) }
            } label: {
                Label("창 시작", systemImage: "play.rectangle.fill")
                    .font(.caption2)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .disabled(profileCount == 0)

            Menu {
                Button("창 이름 변경") { /* TODO: inline rename */ }
                Divider()
                Button("삭제", role: .destructive) {
                    groupToDelete = group
                    showDeleteGroupConfirm = true
                }
                .disabled(wgs.groups.count <= 1)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.95))
    }

    private func profileRow(_ profile: SmugProfile, group: WindowPane, index: Int, total: Int) -> some View {
        HStack(spacing: 8) {
            // 순서
            Text("\(index + 1)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 18, alignment: .trailing)

            // 위아래 이동
            VStack(spacing: 0) {
                Button {
                    wgs.moveProfileInGroup(profile.name, groupId: group.id, up: true)
                } label: {
                    Image(systemName: "chevron.up").font(.system(size: 7))
                }
                .buttonStyle(.plain)
                .disabled(index == 0)
                Button {
                    wgs.moveProfileInGroup(profile.name, groupId: group.id, up: false)
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 7))
                }
                .buttonStyle(.plain)
                .disabled(index == total - 1)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name)
                    .font(.callout)
                Text(profile.root)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            // 창 이동 메뉴
            if wgs.groups.count > 1 {
                Menu {
                    ForEach(wgs.groups.filter { $0.id != group.id }) { target in
                        Button("\(target.name)으로 이동") {
                            wgs.moveProfile(profile.name, to: target)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.right.square")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Button("편집") { editingProfile = profile }
                .buttonStyle(.link)
                .font(.caption)
            Button("삭제") {
                profileToDelete = profile
                showDeleteConfirm = true
            }
            .buttonStyle(.link)
            .font(.caption)
            .foregroundStyle(.red)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(selection == profile.id ? Color.accentColor.opacity(0.1) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { selection = profile.id }
    }

    private func unassignedSection(_ profiles: [SmugProfile]) -> some View {
        Section {
            ForEach(profiles) { profile in
                HStack {
                    Text(profile.name).font(.callout)
                    Text(profile.root).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    if let first = wgs.groups.first {
                        Button("메인에 추가") { wgs.moveProfile(profile.name, to: first) }
                            .buttonStyle(.link).font(.caption)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                Divider().padding(.leading, 12)
            }
        } header: {
            HStack {
                Text("미배정").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.95))
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        VStack(spacing: 0) {
            if let result = syncResult {
                Text(result)
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.top, 4)
            }
            HStack {
                Button { monitor.profileService.load(); wgs.load() } label: {
                    Image(systemName: "arrow.clockwise")
                    Text("새로고침")
                }
                Button {
                    let (added, removed) = monitor.syncProfilesWithDirectory()
                    monitor.profileService.load()
                    if added.isEmpty && removed.isEmpty {
                        syncResult = "이미 동기화됨"
                    } else {
                        var parts: [String] = []
                        if !added.isEmpty { parts.append("추가 \(added.count)개") }
                        if !removed.isEmpty { parts.append("제거 \(removed.count)개") }
                        syncResult = "동기화 완료: " + parts.joined(separator: ", ")
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { syncResult = nil }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("디렉토리 동기화")
                }
                Spacer()
                Text("\(monitor.profileService.profiles.count)개 프로필")
                    .font(.caption).foregroundStyle(.secondary)
                Button { showAddGroupSheet = true } label: {
                    Image(systemName: "macwindow.badge.plus")
                    Text("창 추가")
                }
                Button { showAddSheet = true } label: {
                    Image(systemName: "plus")
                    Text("프로필 추가")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(8)
        }
    }

    // MARK: - Helpers

    private func groupProfiles(_ group: WindowPane) -> [SmugProfile] {
        let all = monitor.profileService.profiles
        return group.profileNames.compactMap { name in all.first { $0.name == name } }
    }

    private var unassignedProfiles: [SmugProfile] {
        let assigned = Set(wgs.groups.flatMap { $0.profileNames })
        return monitor.profileService.profiles.filter { !assigned.contains($0.name) }
    }
}

// MARK: - Add Group Sheet

struct AddGroupSheet: View {
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("새 창 추가").font(.headline).padding()
            Divider()
            Form {
                TextField("창 이름 (예: IMSMS, Tesla)", text: $name)
            }
            .padding()
            Divider()
            HStack {
                Button("취소") { dismiss() }
                Spacer()
                Button("추가") { onSave(name); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 320)
    }
}

// MARK: - Profile Form Sheet

struct ProfileFormSheet: View {
    let title: String
    var existing: SmugProfile?
    let onSave: (SmugProfile) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var root: String

    init(title: String, existing: SmugProfile? = nil, onSave: @escaping (SmugProfile) -> Void) {
        self.title = title
        self.existing = existing
        self.onSave = onSave
        _root = State(initialValue: existing?.root ?? "~/claude/")
    }

    var derivedName: String {
        let last = (root as NSString).lastPathComponent
        return last.isEmpty ? root : last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.headline).padding()
            Divider()
            Form {
                LabeledContent("이름") {
                    Text(derivedName.isEmpty ? "경로 선택 후 자동 입력" : derivedName)
                        .foregroundStyle(derivedName.isEmpty ? .secondary : .primary)
                }
                HStack {
                    TextField("경로 (root)", text: $root)
                    Button("선택...") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.allowsMultipleSelection = false
                        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/claude")
                        if panel.runModal() == .OK, let url = panel.url {
                            root = url.path
                        }
                    }
                }
            }
            .padding()
            Divider()
            HStack {
                Button("취소") { dismiss() }
                Spacer()
                Button("저장") {
                    let profile = SmugProfile(
                        id: existing?.id ?? UUID(),
                        name: derivedName, root: root, delay: existing?.delay ?? 0,
                        enabled: existing?.enabled ?? true
                    )
                    onSave(profile)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(derivedName.isEmpty || root.isEmpty)
            }
            .padding()
        }
        .frame(width: 420)
    }
}
