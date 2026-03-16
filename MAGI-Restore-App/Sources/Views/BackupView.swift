import SwiftUI

struct BackupView: View {
    @StateObject private var service = BackupService()

    var body: some View {
        Form {
            Section("백업 설정") {
                Toggle("백업 활성화", isOn: Binding(
                    get: { service.config.enabled },
                    set: { val in
                        var updated = service.config
                        updated.enabled = val
                        service.save(updated)
                    }
                ))

                HStack {
                    Text("백업 경로")
                    Spacer()
                    Text(service.config.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Button("변경") { selectBackupPath() }
                        .buttonStyle(.link)
                }
            }

            Section("상태") {
                HStack {
                    Text("마지막 백업")
                    Spacer()
                    Text(service.config.lastBackup ?? "없음")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }

                Button(action: {
                    Task { await service.runBackup() }
                }) {
                    if service.isRunning {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("백업 중...")
                        }
                    } else {
                        Text("지금 백업")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!service.config.enabled || service.isRunning)
            }
        }
        .formStyle(.grouped)
        .onAppear { service.load() }
    }

    private func selectBackupPath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "선택"
        if panel.runModal() == .OK, let url = panel.url {
            var updated = service.config
            updated.path = url.path
            service.save(updated)
        }
    }
}
