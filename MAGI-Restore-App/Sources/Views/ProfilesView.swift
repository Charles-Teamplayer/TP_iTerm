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
                TextField("Search...", text: $searchText)
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
                TableColumn("Profile") { profile in
                    Text(profile.name)
                        .foregroundStyle(profile.enabled ? .primary : .secondary)
                }
                TableColumn("Path") { profile in
                    Text(profile.root).font(.caption).foregroundStyle(.secondary)
                }
                TableColumn("Group") { profile in
                    let pane = monitor.windowGroupService.group(for: profile.name)
                    Text(pane.name).font(.caption).foregroundStyle(.secondary)
                }
                .width(60)
                TableColumn("") { profile in
                    HStack(spacing: 8) {
                        Button("Edit") { editingProfile = profile }.buttonStyle(.link)
                        Button("Delete") {
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
            ProfileFormSheet(title: "Add Profile") { newProfile in
                monitor.profileService.add(newProfile)
                if let first = monitor.windowGroupService.groups.first {
                    monitor.windowGroupService.moveProfile(newProfile.name, to: first)
                }
            }
        }
        .sheet(item: $editingProfile) { profile in
            ProfileFormSheet(title: "Edit Profile", existing: profile) { updated in
                var list = monitor.profileService.profiles
                if let idx = list.firstIndex(where: { $0.id == profile.id }) {
                    // 이름이 바뀌면 windowGroupService에서도 업데이트
                    if list[idx].name != updated.name {
                        monitor.windowGroupService.renameProfile(oldName: list[idx].name, newName: updated.name)
                    }
                    list[idx] = updated
                    monitor.profileService.save(list)
                }
            }
        }
        .confirmationDialog(
            "Delete profile '\(profileToDelete?.name ?? "")'?",
            isPresented: $showDeleteConfirm, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let p = profileToDelete { monitor.profileService.delete(p) }
            }
            Button("Cancel", role: .cancel) {}
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
                    Image(systemName: "arrow.clockwise"); Text("Refresh")
                }
                Button {
                    let (added, removed) = monitor.syncProfilesWithDirectory()
                    monitor.profileService.load()
                    if added.isEmpty && removed.isEmpty {
                        syncResult = "Already in sync"
                    } else {
                        var parts: [String] = []
                        if !added.isEmpty { parts.append("\(added.count) added") }
                        if !removed.isEmpty { parts.append("\(removed.count) removed") }
                        syncResult = "Synced: " + parts.joined(separator: ", ")
                    }
                    Task { try? await Task.sleep(nanoseconds: 3_000_000_000); syncResult = nil }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath"); Text("Sync Directory")
                }
                Spacer()
                Text("\(monitor.profileService.profiles.count) profiles")
                    .font(.caption).foregroundStyle(.secondary)
                Button { showAddSheet = true } label: {
                    Image(systemName: "plus"); Text("Add")
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
        _root = State(initialValue: existing?.root ?? "~/")
    }

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
                    TextField("Path (root)", text: $root)
                    Button("Browse...") {
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
                TextField("Profile name (tmux window name)", text: $name)
                    .help("Leave blank to use the last folder name from the path")
                LabeledContent("Effective Name") {
                    Text(effectiveName.isEmpty ? "Select a path first" : effectiveName)
                        .foregroundStyle(effectiveName.isEmpty ? .secondary : .primary)
                }
            }
            .padding()
            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") {
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

