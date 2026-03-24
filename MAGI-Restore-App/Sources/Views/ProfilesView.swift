import SwiftUI

struct ProfilesView: View {
    @ObservedObject var monitor: SessionMonitor
    var searchFocused: FocusState<Bool>.Binding
    @Binding var selection: UUID?
    @State private var searchText = ""
    @State private var showAddSheet = false
    @State private var syncResult: String? = nil
    @State private var editingProfile: SmugProfile?
    @State private var profileToDelete: SmugProfile?
    @State private var showDeleteConfirm = false

    var filtered: [SmugProfile] {
        searchText.isEmpty ? monitor.profileService.profiles
            : monitor.profileService.profiles.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.root.localizedCaseInsensitiveContains(searchText)
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                TextField("검색...", text: $searchText)
                    .textFieldStyle(.plain).font(.caption).focused(searchFocused)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).font(.caption)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            Table(filtered, selection: $selection) {
                TableColumn("에이전트명") { profile in
                    Text(profile.name)
                        .foregroundStyle(profile.enabled ? .primary : .secondary)
                }
                TableColumn("경로") { profile in
                    Text(profile.root).font(.caption).foregroundStyle(.secondary)
                }
                TableColumn("창") { profile in
                    let pane = monitor.windowGroupService.group(for: profile.name)
                    Text(pane.name).font(.caption).foregroundStyle(.secondary)
                }
                .width(60)
                TableColumn("") { profile in
                    HStack(spacing: 8) {
                        Button("편집") { editingProfile = profile }.buttonStyle(.link)
                        Button("삭제") {
                            profileToDelete = profile
                            showDeleteConfirm = true
                        }.buttonStyle(.link).foregroundStyle(.red)
                    }
                }
                .width(80)
            }

            Divider()
            bottomBar
        }
        .onAppear {
            monitor.profileService.load()
            monitor.windowGroupService.load()
        }
        .sheet(isPresented: $showAddSheet) {
            ProfileFormSheet(title: "프로필 추가") { newProfile in
                monitor.profileService.add(newProfile)
                if let first = monitor.windowGroupService.groups.first {
                    monitor.windowGroupService.moveProfile(newProfile.name, to: first)
                }
            }
        }
        .sheet(item: $editingProfile) { profile in
            ProfileFormSheet(title: "프로필 편집", existing: profile) { updated in
                var list = monitor.profileService.profiles
                if let idx = list.firstIndex(where: { $0.id == profile.id }) {
                    // 이름이 바뀌면 windowGroupService에서도 업데이트
                    if list[idx].name != updated.name {
                        let pane = monitor.windowGroupService.group(for: list[idx].name)
                        monitor.windowGroupService.moveProfile(list[idx].name, to: pane)
                    }
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
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            if let result = syncResult {
                Text(result).font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.top, 4)
            }
            HStack {
                Button { monitor.profileService.load() } label: {
                    Image(systemName: "arrow.clockwise"); Text("새로고침")
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
                    Image(systemName: "arrow.triangle.2.circlepath"); Text("디렉토리 동기화")
                }
                Spacer()
                Text("\(monitor.profileService.profiles.count)개 프로필")
                    .font(.caption).foregroundStyle(.secondary)
                Button { showAddSheet = true } label: {
                    Image(systemName: "plus"); Text("추가")
                }.buttonStyle(.borderedProminent)
            }
            .padding(8)
        }
    }
}

// MARK: - Profile Form Sheet

struct ProfileFormSheet: View {
    let title: String
    var existing: SmugProfile?
    let onSave: (SmugProfile) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var root: String

    init(title: String, existing: SmugProfile? = nil, onSave: @escaping (SmugProfile) -> Void) {
        self.title = title
        self.existing = existing
        self.onSave = onSave
        _name = State(initialValue: existing?.name ?? "")
        _root = State(initialValue: existing?.root ?? "~/claude/")
    }

    // 이름 미입력 시 경로에서 자동 도출
    var effectiveName: String {
        name.trimmingCharacters(in: .whitespaces).isEmpty
            ? (root as NSString).lastPathComponent
            : name.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.headline).padding()
            Divider()
            Form {
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
                            if name.trimmingCharacters(in: .whitespaces).isEmpty {
                                name = url.lastPathComponent
                            }
                        }
                    }
                }
                TextField("에이전트명 (tmux 창 이름)", text: $name)
                    .help("비워두면 경로 마지막 폴더명 자동 사용")
                LabeledContent("최종 이름") {
                    Text(effectiveName.isEmpty ? "경로를 먼저 선택하세요" : effectiveName)
                        .foregroundStyle(effectiveName.isEmpty ? .secondary : .primary)
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
                        name: effectiveName, root: root,
                        delay: existing?.delay ?? 0,
                        enabled: existing?.enabled ?? true
                    )
                    onSave(profile)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(effectiveName.isEmpty || root.isEmpty)
            }
            .padding()
        }
        .frame(width: 420)
    }
}

// MARK: - Add Group Sheet (창 추가)

struct AddGroupSheet: View {
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("새 창 추가").font(.headline).padding()
            Divider()
            Form { TextField("창 이름 (예: IMSMS, Tesla)", text: $name) }
                .padding()
            Divider()
            HStack {
                Button("취소") { dismiss() }
                Spacer()
                Button("추가") { onSave(name); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }.padding()
        }
        .frame(width: 320)
    }
}
