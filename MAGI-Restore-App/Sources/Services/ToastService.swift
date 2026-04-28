import AppKit
import SwiftUI

// MARK: - Toast Schema (v1.1 — 2026-04-28)

struct ToastEntry: Codable {
    var title: String
    var message: String
    var icon: String
    var duration: Double?       // 옵셔널, 기본 5.0초
    var action: ToastAction?    // 옵셔널, 있으면 Open 버튼 표시
}

struct ToastAction: Codable {
    var type: String     // "open_path" | "focus_tab"  (보안 보강: shell 제외)
    var target: String   // 타입별 인자
}

@MainActor
final class ToastService {
    static let shared = ToastService()
    private var window: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    static let queueFile = "/tmp/magi-toast.json"
    static let actionLogFile = NSHomeDirectory() + "/.claude/logs/toast-action.log"
    static let defaultDuration: Double = 5.0   // CEO 결정: B (5초)

    private init() {}

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await drainQueue()
            }
        }
    }

    private func drainQueue() async {
        let path = ToastService.queueFile
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let entries = try? JSONDecoder().decode([ToastEntry].self, from: data),
              !entries.isEmpty else { return }
        try? FileManager.default.removeItem(atPath: path)
        for entry in entries {
            showEntry(entry)
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
    }

    // 하위호환 진입점 (기존 NotificationService에서 호출)
    func show(title: String, body: String, icon: String = "bell.fill") {
        let entry = ToastEntry(title: title, message: body, icon: icon, duration: nil, action: nil)
        showEntry(entry)
    }

    func showEntry(_ entry: ToastEntry) {
        hideTask?.cancel()
        window?.close()

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let host = NSHostingView(rootView: ToastView(
            icon: entry.icon,
            title: entry.title,
            message: entry.message,
            hasAction: entry.action != nil,
            onOpen: { [weak self] in
                if let action = entry.action {
                    self?.executeAction(action)
                }
                self?.dismiss()
            },
            onDismiss: { [weak self] in
                self?.dismiss()
            }
        ))
        host.frame = panel.contentView!.bounds
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        if let screen = NSScreen.main {
            let x = screen.visibleFrame.maxX - 340
            let y = screen.visibleFrame.minY + 20
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.alphaValue = 0
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 1
        }
        self.window = panel

        let duration = entry.duration ?? ToastService.defaultDuration
        let nanos = UInt64(duration * 1_000_000_000)
        hideTask = Task {
            try? await Task.sleep(nanoseconds: nanos)
            if !Task.isCancelled { self.dismiss() }
        }
    }

    func dismiss() {
        guard let panel = window else { return }
        self.window = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.close()
        })
    }

    // MARK: - Action Execution (보안 보강: open_path / focus_tab만)

    private func executeAction(_ action: ToastAction) {
        switch action.type {
        case "open_path":
            let url = URL(fileURLWithPath: action.target)
            let ok = NSWorkspace.shared.open(url)
            logAction(type: action.type, target: action.target, success: ok)
        case "focus_tab":
            // target 형식: "<tty_path>|<project_name>"
            let parts = action.target.components(separatedBy: "|")
            let tty = parts.first ?? ""
            let project = parts.count > 1 ? parts[1] : ""
            let scriptPath = NSHomeDirectory() + "/.claude/scripts/focus-iterm-tab.sh"
            guard FileManager.default.isExecutableFile(atPath: scriptPath) else {
                logAction(type: action.type, target: action.target, success: false, note: "script missing")
                return
            }
            let proc = Process()
            proc.launchPath = scriptPath
            proc.arguments = [tty, project]
            do {
                try proc.run()
                logAction(type: action.type, target: action.target, success: true)
            } catch {
                logAction(type: action.type, target: action.target, success: false, note: error.localizedDescription)
            }
        default:
            // 알 수 없는 type은 조용히 무시 (보안: shell 등 차단)
            logAction(type: action.type, target: action.target, success: false, note: "unsupported type")
        }
    }

    private func logAction(type: String, target: String, success: Bool, note: String = "") {
        let dir = (ToastService.actionLogFile as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let ts = ISO8601DateFormatter().string(from: Date())
        let status = success ? "OK" : "FAIL"
        let line = "[\(ts)] \(status) type=\(type) target=\(target)\(note.isEmpty ? "" : " note=\(note)")\n"
        if let data = line.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: ToastService.actionLogFile)) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: ToastService.actionLogFile))
            }
        }
    }
}

// MARK: - 토스트 뷰

private struct ToastView: View {
    let icon: String
    let title: String
    let message: String
    let hasAction: Bool
    let onOpen: () -> Void
    let onDismiss: () -> Void

    @State private var openHover = false
    @State private var closeHover = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !message.isEmpty {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if hasAction {
                Button { onOpen() } label: {
                    Text("Open")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.white.opacity(openHover ? 0.30 : 0.18))
                        )
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    openHover = hovering
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }

            Button { onDismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(closeHover ? 0.95 : 0.6))
                    .padding(4)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                closeHover = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 320, height: 64)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.08, green: 0.55, blue: 0.25).opacity(0.95))
                .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }
}
