import SwiftUI

struct BackupView: View {
    @StateObject private var service = BackupService()
    @State private var snapshotToRestore: ConfigSnapshot? = nil
    @State private var snapshotToDelete: ConfigSnapshot? = nil
    @State private var isRestoring = false
    @State private var restoreResult: Bool? = nil

    var body: some View {
        VStack(spacing: 0) {
            // 상단 헤더
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Config Snapshots")
                        .font(.headline)
                    Text("window-groups · active-sessions · activated-sessions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await service.runBackup() }
                } label: {
                    if service.isRunning {
                        Label("Saving...", systemImage: "arrow.clockwise")
                    } else {
                        Label("Save Now", systemImage: "externaldrive.badge.plus")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(service.isRunning)
            }
            .padding()

            Divider()

            // 스냅샷 목록
            if service.config.snapshots.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "externaldrive")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No snapshots yet")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("Save a snapshot to protect your session configuration.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(service.config.snapshots) { snapshot in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(snapshot.createdAt)
                                .font(.system(.body, design: .monospaced))
                            Text(snapshot.files.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Restore") {
                            snapshotToRestore = snapshot
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)

                        Button(role: .destructive) {
                            snapshotToDelete = snapshot
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                }
            }

            // 하단 상태 바
            Divider()
            HStack {
                if isRestoring {
                    ProgressView().scaleEffect(0.8)
                    Text("Restoring...").font(.caption).foregroundStyle(.secondary)
                } else if let result = restoreResult {
                    Image(systemName: result ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result ? .green : .red)
                    Text(result ? "Restored successfully" : "Restore failed")
                        .font(.caption)
                        .foregroundStyle(result ? .green : .red)
                } else {
                    Text("Snapshot path: \(service.config.path)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer()
                Button("Change") { selectSnapshotPath() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .onAppear { service.load() }
        .onChange(of: restoreResult) {
            // 3초 후 결과 메시지 제거
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                restoreResult = nil
            }
        }
        // confirmationDialog를 List 밖 (VStack 레벨)에서 단일 등록 — 다중 등록 방지
        .confirmationDialog(
            "Restore '\(snapshotToRestore?.createdAt ?? "")'?\n현재 설정 파일이 덮어써집니다.",
            isPresented: Binding(
                get: { snapshotToRestore != nil && !isRestoring },
                set: { if !$0 { snapshotToRestore = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Restore", role: .destructive) {
                if let snap = snapshotToRestore {
                    let captured = snap
                    snapshotToRestore = nil
                    Task {
                        isRestoring = true
                        restoreResult = await service.restoreSnapshot(captured)
                        isRestoring = false
                    }
                }
            }
            Button("Cancel", role: .cancel) { snapshotToRestore = nil }
        }
        .confirmationDialog(
            "Delete this snapshot?",
            isPresented: Binding(
                get: { snapshotToDelete != nil },
                set: { if !$0 { snapshotToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let snap = snapshotToDelete {
                    service.deleteSnapshot(snap)
                    snapshotToDelete = nil
                }
            }
            Button("Cancel", role: .cancel) { snapshotToDelete = nil }
        }
    }

    private func selectSnapshotPath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Select"
        if panel.runModal() == .OK, let url = panel.url {
            var updated = service.config
            updated.path = url.path
            service.save(updated)
        }
    }
}
