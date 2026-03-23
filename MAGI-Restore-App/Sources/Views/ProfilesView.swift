import SwiftUI

struct ProfilesView: View {
    @ObservedObject var monitor: SessionMonitor
    @StateObject private var service = ProfileService()
    @State private var selection: UUID? = nil
    @State private var searchText = ""
    @State private var showAddSheet = false
    @State private var editingProfile: SmugProfile?
    @State private var profileToDelete: SmugProfile?
    @State private var showDeleteConfirm = false

    var filtered: [SmugProfile] {
        searchText.isEmpty ? service.profiles
            : service.profiles.filter { $0.name.localizedCaseInsensitiveContains(searchText) || $0.root.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 검색바
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                TextField("검색...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.caption)
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
        .onAppear { service.load() }
        .sheet(isPresented: $showAddSheet) {
            ProfileFormSheet(title: "프로필 추가") { newProfile in
                service.add(newProfile)
            }
        }
        .sheet(item: $editingProfile) { profile in
            ProfileFormSheet(title: "프로필 편집", existing: profile) { updated in
                var list = service.profiles
                if let idx = list.firstIndex(where: { $0.id == profile.id }) {
                    list[idx] = updated
                    service.save(list)
                }
            }
        }
        .confirmationDialog(
            "'\(profileToDelete?.name ?? "")' 프로필을 삭제하시겠습니까?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("삭제", role: .destructive) {
                if let p = profileToDelete { service.delete(p) }
            }
            Button("취소", role: .cancel) {}
        }
    }

    private var profileTable: some View {
        Table(filtered, selection: $selection) {
            TableColumn("이름") { profile in
                Text(profile.name)
                    .foregroundStyle(profile.enabled ? .primary : .secondary)
            }
            TableColumn("경로") { profile in
                Text(profile.root)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TableColumn("딜레이") { profile in
                Text("\(profile.delay)초")
                    .monospacedDigit()
            }
            .width(60)
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

    private var bottomBar: some View {
        HStack {
            Button { service.load() } label: {
                Image(systemName: "arrow.clockwise")
                Text("새로고침")
            }
            Spacer()
            Text("\(service.profiles.count)개 프로필")
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

struct ProfileFormSheet: View {
    let title: String
    var existing: SmugProfile?
    let onSave: (SmugProfile) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var root: String
    @State private var delay: Int

    init(title: String, existing: SmugProfile? = nil, onSave: @escaping (SmugProfile) -> Void) {
        self.title = title
        self.existing = existing
        self.onSave = onSave
        _name = State(initialValue: existing?.name ?? "")
        _root = State(initialValue: existing?.root ?? "~/claude/")
        _delay = State(initialValue: existing?.delay ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.headline).padding()
            Divider()
            Form {
                TextField("이름", text: $name)
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
                            if name.isEmpty { name = url.lastPathComponent }
                        }
                    }
                }
                Stepper("딜레이: \(delay)초", value: $delay, in: 0...60, step: 5)
            }
            .padding()
            Divider()
            HStack {
                Button("취소") { dismiss() }
                Spacer()
                Button("저장") {
                    let profile = SmugProfile(
                        id: existing?.id ?? UUID(),
                        name: name, root: root, delay: delay,
                        enabled: existing?.enabled ?? true
                    )
                    onSave(profile)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || root.isEmpty)
            }
            .padding()
        }
        .frame(width: 420)
    }
}
