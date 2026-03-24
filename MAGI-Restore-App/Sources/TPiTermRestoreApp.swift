import SwiftUI
import AppKit

@main
struct TPiTermRestoreApp: App {
    @StateObject private var menuBarState = MenuBarState()

    init() {
        WindowGroupService.bootstrapIfNeeded()
    }

    var body: some Scene {
        // 전체 UI는 Settings(Cmd+,)로 접근
        Settings {
            ContentView()
                .frame(minWidth: 700, minHeight: 450)
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
    @Published var tmuxSessionNames: [String] = []

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

        // tmux 세션 목록 갱신
        let raw = await ShellService.runAsync("tmux list-sessions -F '#{session_name}' 2>/dev/null")
        tmuxSessionNames = raw.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    private lazy var systemVM = SystemViewModel()

    func quickRestore() async {
        guard !isRestoring else { return }
        isRestoring = true
        await systemVM.runRestore()
        isRestoring = false
        await refresh()
    }

    // iTerm2를 열고 tmux -CC attach 실행 (작업탭 표시)
    func openInITerm(sessionName: String = "claude-work") {
        let script = """
        tell application "iTerm2"
            activate
            set newWin to (create window with default profile)
            tell current session of newWin
                write text "tmux -CC attach -t \(sessionName) 2>/dev/null || echo 'tmux 세션 없음: \(sessionName)'"
            end tell
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }

    // tmux 세션 목록
    func tmuxSessions() async -> [String] {
        let raw = await ShellService.runAsync("tmux list-sessions -F '#{session_name}' 2>/dev/null")
        return raw.components(separatedBy: "\n").filter { !$0.isEmpty }
    }
}

// MARK: - MenuBar Icon
struct MenuBarIconView: View {
    let sessionCount: Int
    let allDaemonsRunning: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: allDaemonsRunning ? "terminal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(allDaemonsRunning ? Color.primary : Color.orange)
            if sessionCount > 0 {
                Text("\(sessionCount)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
        }
    }
}

// MARK: - MenuBar Menu
struct MenuBarMenuView: View {
    @ObservedObject var state: MenuBarState

    var body: some View {
        // 상태
        Label("Claude \(state.sessionCount)개 실행 중", systemImage: "terminal")
            .foregroundStyle(.secondary)
        Label(state.allDaemonsRunning ? "데몬 정상" : "데몬 이상",
              systemImage: state.allDaemonsRunning ? "checkmark.circle" : "exclamationmark.circle")
            .foregroundStyle(state.allDaemonsRunning ? Color.secondary : Color.orange)

        Divider()

        // iTerm2 연결 (세션 1개면 단순 버튼, 여러 개면 submenu)
        if state.tmuxSessionNames.count <= 1 {
            Button {
                state.openInITerm(sessionName: state.tmuxSessionNames.first ?? "claude-work")
            } label: {
                Label("iTerm2에서 열기 (\(state.tmuxSessionNames.first ?? "claude-work"))",
                      systemImage: "macwindow.badge.plus")
            }
        } else {
            Menu {
                ForEach(state.tmuxSessionNames, id: \.self) { session in
                    Button(session) { state.openInITerm(sessionName: session) }
                }
            } label: {
                Label("iTerm2에서 열기", systemImage: "macwindow.badge.plus")
            }
        }

        Divider()

        // 복원
        Button(state.isRestoring ? "복원 중..." : "지금 복원") {
            Task { await state.quickRestore() }
        }
        .disabled(state.isRestoring)

        Button("새로고침") {
            Task { await state.refresh() }
        }

        Divider()

        // 설정
        Button("MAGI 설정 열기") {
            NSApp.activate(ignoringOtherApps: true)
            // macOS 14 이상에서는 showSettingsWindow:, 이전 버전은 showPreferencesWindow:
            let selector = Selector(("showSettingsWindow:"))
            if NSApp.responds(to: selector) {
                NSApp.sendAction(selector, to: nil, from: nil)
            } else {
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            }
        }

        Divider()

        Button("종료") {
            NSApplication.shared.terminate(nil)
        }
    }
}
