import AppKit
import SwiftUI

// MARK: - B안: 커스텀 토스트 (화면 우하단, 2.5초 후 자동 사라짐)

@MainActor
final class ToastService {
    static let shared = ToastService()
    private var window: NSPanel?
    private var hideTask: Task<Void, Never>?

    private init() {}

    func show(title: String, body: String, icon: String = "bell.fill") {
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

        let host = NSHostingView(rootView: ToastView(icon: icon, title: title, message: body) {
            self.dismiss()
        })
        host.frame = panel.contentView!.bounds
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        // 화면 우하단 배치
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

        hideTask = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
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
}

// MARK: - 토스트 뷰

private struct ToastView: View {
    let icon: String
    let title: String
    let message: String
    let onDismiss: () -> Void

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

            Spacer()

            Button { onDismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 320, height: 64)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.black.opacity(0.85))
                .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }
}
