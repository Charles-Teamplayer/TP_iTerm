import SwiftUI

@main
struct MAGIRestoreApp: App {
    @StateObject private var menuBarState = MenuBarState()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra {
            MenuBarMenuView(state: menuBarState)
        } label: {
            MenuBarIconView(sessionCount: menuBarState.sessionCount, allDaemonsRunning: menuBarState.allDaemonsRunning)
        }
        .menuBarExtraStyle(.menu)
    }
}

// MARK: - MenuBar State
@MainActor
final class MenuBarState: ObservableObject {
    @Published var sessionCount: Int = 0
    @Published var allDaemonsRunning: Bool = false
    @Published var isRestoring: Bool = false

    private var timer: Timer?

    init() {
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func refresh() async {
        let output = await ShellService.runAsync("ps aux | grep '[c]laude' | grep -v 'MAGI\\|watchdog\\|auto-restore\\|tab-focus'")
        sessionCount = output.isEmpty ? 0 : output.components(separatedBy: "\n").filter { !$0.isEmpty }.count

        let labels = ["com.claude.watchdog", "com.claude.tab-focus-monitor", "com.claude.auto-restore"]
        var allRunning = true
        for label in labels {
            let result = await ShellService.runAsync("launchctl print gui/\(getuid())/\(label) 2>/dev/null")
            if !result.contains("state = running") { allRunning = false; break }
        }
        allDaemonsRunning = allRunning
    }

    private lazy var systemVM = SystemViewModel()

    func quickRestore() async {
        guard !isRestoring else { return }
        isRestoring = true
        await systemVM.runRestore()
        isRestoring = false
        await refresh()
    }
}

// MARK: - MenuBar Icon
struct MenuBarIconView: View {
    let sessionCount: Int
    let allDaemonsRunning: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: allDaemonsRunning ? "circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(allDaemonsRunning ? .green : .orange)
                .font(.system(size: 10))
            Text("\(sessionCount)")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
        }
    }
}

// MARK: - MenuBar Menu
struct MenuBarMenuView: View {
    @ObservedObject var state: MenuBarState

    var body: some View {
        Text("MAGI Restore")
            .font(.headline)
        Divider()
        Text("Claude 세션: \(state.sessionCount)개")
        Text("데몬: \(state.allDaemonsRunning ? "✅ 정상" : "⚠️ 일부 중단")")
        Divider()
        Button(state.isRestoring ? "복원 중..." : "지금 복원") {
            Task { await state.quickRestore() }
        }
        .disabled(state.isRestoring)
        Divider()
        Button("앱 열기") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
        Button("종료") {
            NSApplication.shared.terminate(nil)
        }
    }
}
