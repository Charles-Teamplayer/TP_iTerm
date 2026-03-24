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
            : monitor.profileService.profiles.filter { $0.name.localizedCaseInsensitiveContains(searchText) || $0.root.localizedCaseInsensitiveContains(searchText) }
    }

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
            profileTable
            Divider()
            bottomBar
        }
        .onAppear { monitor.profileService.load() }
        .sheet(isPresented: $showAddSheet) {
            ProfileFormSheet(title: "프로필 추가") { newProfile in
                monitor.profileService.add(newProfile)
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
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("삭제", role: .destructive) {
                if let p = profileToDelete { monitor.profileService.delete(p) }
            }
            Button("취소", role: .cancel) {}
        }
    }

    private var profileTable: some View {
        Table(filtered, selection: $selection) {
            TableColumn("순서") { profile in
                if let idx = filtered.firstIndex(where: { $0.id == profile.id }) {
                    HStack(spacing: 2) {
                        Text("\(idx + 1)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        VStack(spacing: 0) {
                            Button { moveProfile(profile, up: true) } label: {
                                Image(systemName: "chevron.up").font(.system(size: 8))
                            }
                            .buttonStyle(.plain)
                            .disabled(idx == 0)
                            Button { moveProfile(profile, up: false) } label: {
                                Image(systemName: "chevron.down").font(.system(size: 8))
                            }
                            .buttonStyle(.plain)
                            .disabled(idx == filtered.count - 1)
                        }
                    }
                }
            }
            .width(50)
            TableColumn("이름") { profile in
                Text(profile.name)
                    .foregroundStyle(profile.enabled ? .primary : .secondary)
            }
            TableColumn("경로") { profile in
                Text(profile.root)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TableColumn("") { profile in
                HStack(spacing: 8) {
                    Button("편집") { editingProfile = profile }
                        .buttonStyle(.link)
                    Button("삭제") {
                        profileToDelete = profile
                        showDeleteConfirm = true
                    }
                    .buttonStyle(.link)
                    .foregroundStyle(.red)
                }
            }
            .width(80)
        }
    }

    private func syncOrderWithTmux() {
        let output = ShellService.run(
            "tmux list-windows -t claude-work -F '#{window_name}' 2>/dev/null"
        )
        let windowNames = output.components(separatedBy: "\n").filter { !$0.isEmpty && $0 != "monitor" }
        var list = monitor.profileService.profiles
        var reordered: [SmugProfile] = []
        var remaining = list
        for name in windowNames {
            if let idx = remaining.firstIndex(where: { $0.name == name }) {
                reordered.append(remaining.remove(at: idx))
            }
        }
        reordered.append(contentsOf: remaining)
        monitor.profileService.save(reordered)
        syncResult = "탭 순서 동기화 완료 (\(windowNames.count)개)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { syncResult = nil }
    }

    private func moveProfile(_ profile: SmugProfile, up: Bool) {
        var list = monitor.profileService.profiles
        guard let from = list.firstIndex(where: { $0.id == profile.id }) else { return }
        let to = up ? from - 1 : from + 1
        guard to >= 0, to < list.count else { return }
        list.swapAt(from, to)
        monitor.profileService.save(list)
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            if let result = syncResult {
                Text(result)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
            }
            HStack {
                Button { monitor.profileService.load() } label: {
                    Image(systemName: "arrow.clockwise")
                    Text("새로고침")
                }
                Button {
                    syncOrderWithTmux()
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                    Text("탭 순서로")
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button { showAddSheet = true } label: {
                    Image(systemName: "plus")
                    Text("추가")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(8)
        }
    }
}

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

    // 이름은 항상 디렉토리명 (lastPathComponent)
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
