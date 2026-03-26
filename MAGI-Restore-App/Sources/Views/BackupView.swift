import SwiftUI

struct BackupView: View {
    @StateObject private var service = BackupService()

    var body: some View {
        Form {
            Section("Backup Settings") {
                Toggle("Enable Backup", isOn: Binding(
                    get: { service.config.enabled },
                    set: { val in
                        var updated = service.config
                        updated.enabled = val
                        service.save(updated)
                    }
                ))

                HStack {
                    Text("Backup Path")
                    Spacer()
                    Text(service.config.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Button("Change") { selectBackupPath() }
                        .buttonStyle(.link)
                }
            }

            Section("Status") {
                HStack {
                    Text("Last Backup")
                    Spacer()
                    Text(service.config.lastBackup ?? "Never")
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
                            Text("Backing up...")
                        }
                    } else {
                        Text("Backup Now")
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
        panel.prompt = "Select"
        if panel.runModal() == .OK, let url = panel.url {
            var updated = service.config
            updated.path = url.path
            service.save(updated)
        }
    }
}
