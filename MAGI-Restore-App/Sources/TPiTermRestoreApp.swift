import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}

@main
struct TPiTermRestoreApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var menuBarState = MenuBarState()

    init() {
        WindowGroupService.bootstrapIfNeeded()
    }

    var body: some Scene {
        Window("TP iTerm Restore", id: "main") {
            ContentView()
                .frame(minWidth: 700, minHeight: 450)
        }
        .defaultSize(width: 900, height: 560)

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

    deinit {
        timer?.invalidate()
    }

    func refresh() async {
        // window-groups.json에서 active session 목록 읽기 (claude-work 하드코딩 제거)
        let groupsRaw = await ShellService.runAsync("""
            python3 -c "
import json, os
try:
    groups = json.load(open(os.path.expanduser('~/.claude/window-groups.json')))
    for g in groups:
        if not g.get('isWaitingList', False):
            print(g['sessionName'])
except: pass
" 2>/dev/null
""")
        let activeSessions = groupsRaw.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let checkSessions = activeSessions.isEmpty ? ["claude-work"] : activeSessions

        var count = 0
        for sessionName in checkSessions {
            // BUG#28 fix: window name 직접 -t 타겟 사용 금지 (dot 이름 tmux 오인 방지)
            // list-windows에서 index|name|pane_tty 한번에 수집 → index 기반으로 처리
            let windowInfo = await ShellService.runAsync(
                "tmux list-windows -t '\(sessionName)' -F '#{window_index}\u{01}#{window_name}\u{01}#{pane_tty}' 2>/dev/null"
            )
            for line in windowInfo.components(separatedBy: "\n").filter({ !$0.isEmpty }) {
                let parts = line.components(separatedBy: "\u{01}")
                guard parts.count >= 3 else { continue }
                let winName = parts[1]
                guard winName != "monitor" && winName != "_init_" else { continue }
                let paneTty = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
                let ttyBase = paneTty.replacingOccurrences(of: "/dev/", with: "")
                guard !ttyBase.isEmpty else { continue }
                let procs = await ShellService.runAsync("ps -o command -t \(ShellService.shellq(ttyBase)) 2>/dev/null | grep '[c]laude' | head -1")
                if !procs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { count += 1 }
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

        // linked view sessions(-vN) 제외한 실제 tmux 세션 목록
        let raw = await ShellService.runAsync(
            "tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -Ev '.*-v[0-9]+$'"
        )
        tmuxSessionNames = raw.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
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
        let safeSession = sessionName
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let script = """
        tell application "iTerm2"
            activate
            set newWin to (create window with default profile)
            tell current session of newWin
                write text "tmux -CC attach -t \(safeSession) 2>/dev/null || echo 'tmux: \(safeSession)'"
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
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // 상태
        Label("\(state.sessionCount) Claude session\(state.sessionCount == 1 ? "" : "s") running", systemImage: "terminal")
            .foregroundStyle(.secondary)
        Label(state.allDaemonsRunning ? "Daemons OK" : "Daemon issue",
              systemImage: state.allDaemonsRunning ? "checkmark.circle" : "exclamationmark.circle")
            .foregroundStyle(state.allDaemonsRunning ? Color.secondary : Color.orange)

        Divider()

        // iTerm2 연결 (세션 1개면 단순 버튼, 여러 개면 submenu)
        if state.tmuxSessionNames.count <= 1 {
            Button {
                state.openInITerm(sessionName: state.tmuxSessionNames.first ?? "claude-work")
            } label: {
                Label("Open in iTerm2 (\(state.tmuxSessionNames.first ?? "claude-work"))",
                      systemImage: "macwindow.badge.plus")
            }
        } else {
            Menu {
                ForEach(state.tmuxSessionNames, id: \.self) { session in
                    Button(session) { state.openInITerm(sessionName: session) }
                }
            } label: {
                Label("Open in iTerm2", systemImage: "macwindow.badge.plus")
            }
        }

        Divider()

        Button(state.isRestoring ? "Restoring..." : "Restore Now") {
            Task { await state.quickRestore() }
        }
        .disabled(state.isRestoring)

        Button("Refresh") {
            Task { await state.refresh() }
        }

        Divider()

        Button("Open Dashboard") {
            openWindow(id: "main")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows
                    .first { $0.canBecomeKey && $0.title.contains("TP") }?
                    .makeKeyAndOrderFront(nil)
                    ?? NSApp.windows.first { $0.canBecomeKey }?.makeKeyAndOrderFront(nil)
            }
        }

        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
    }
}
