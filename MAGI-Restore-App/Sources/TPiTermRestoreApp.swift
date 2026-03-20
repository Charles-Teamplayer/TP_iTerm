import SwiftUI

@main
struct TPiTermRestoreApp: App {
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
        let windowNames = await ShellService.runAsync("tmux list-windows -t claude-work -F '#{window_name}' 2>/dev/null")
        let windows = windowNames.components(separatedBy: "\n").filter { !$0.isEmpty }
        var count = 0
        for win in windows {
            let paneInfo = await ShellService.runAsync(
                "tmux display-message -t 'claude-work:\(win)' -p '#{pane_tty}' 2>/dev/null"
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            let ttyBase = paneInfo.replacingOccurrences(of: "/dev/", with: "")
            guard !ttyBase.isEmpty else { continue }
            let procs = await ShellService.runAsync("ps -o command -t '\(ttyBase)' 2>/dev/null | grep '[c]laude' | head -1")
            if !procs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                count += 1
            }
        }
        sessionCount = count

        let labels = ["com.claude.watchdog", "com.claude.tab-focus-monitor"]
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
        Text("\(allDaemonsRunning ? "🟢" : "🟠") \(sessionCount)")
            .font(.system(size: 12, weight: .medium, design: .monospaced))
    }
}

// MARK: - MenuBar Menu
struct MenuBarMenuView: View {
    @ObservedObject var state: MenuBarState

    var body: some View {
        Text("TP_iTerm Restore")
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
