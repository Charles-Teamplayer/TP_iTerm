import SwiftUI
import AppKit

// MARK: - Debug Logger

func badgeLog(_ msg: String) {
    let line = "[\(Date())] \(msg)\n"
    let path = "/tmp/badge_debug.log"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: path) {
            if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
                h.seekToEndOfFile(); h.write(data); h.closeFile()
            }
        } else {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}

// MARK: - Full-Row Native Drag Overlay
// 전체 row 위에 투명 NSView 오버레이 — 드래그는 즉시 시작, tap은 onSelect 콜백으로 전달

struct FullRowDragOverlay: NSViewRepresentable {
    let payload: String
    let onSelect: () -> Void
    var isEditing: Bool = false  // TextField 편집 중이면 이벤트 pass-through

    func makeNSView(context: Context) -> RowDragNSView {
        let v = RowDragNSView()
        v.payload = payload
        v.onSelect = onSelect
        v.isEditing = isEditing
        return v
    }

    func updateNSView(_ v: RowDragNSView, context: Context) {
        v.payload = payload
        v.onSelect = onSelect
        v.isEditing = isEditing
    }
}

class RowDragNSView: NSView, NSDraggingSource {
    var payload: String = ""
    var onSelect: (() -> Void)?
    var isEditing: Bool = false   // true면 hitTest nil → 이벤트 하위 뷰로 통과
    private var mouseDownEvent: NSEvent?
    private var didDrag = false

    // 편집 중일 때 hit test 통과 → TextField가 직접 이벤트 수신
    override func hitTest(_ point: NSPoint) -> NSView? {
        return isEditing ? nil : super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent, !didDrag else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x
        let dy = event.locationInWindow.y - down.locationInWindow.y
        guard sqrt(dx*dx + dy*dy) > 4 else { return }
        didDrag = true
        mouseDownEvent = nil

        badgeLog("[RowDrag] start payload=\(payload)")
        let item = NSDraggingItem(pasteboardWriter: payload as NSString)
        let previewName = payload.split(separator: "|").first.map(String.init) ?? payload
        item.setDraggingFrame(CGRect(x: 0, y: 0, width: 180, height: 30),
                              contents: makeDragImage(previewName))
        beginDraggingSession(with: [item], event: down, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if !didDrag {
            // tap — SwiftUI onSelect 전달
            DispatchQueue.main.async { self.onSelect?() }
        }
        mouseDownEvent = nil
        didDrag = false
    }

    private func makeDragImage(_ name: String) -> NSImage {
        let img = NSImage(size: NSSize(width: 180, height: 30))
        img.lockFocus()
        NSColor.windowBackgroundColor.withAlphaComponent(0.95).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 180, height: 30), xRadius: 6, yRadius: 6).fill()
        let para = NSMutableParagraphStyle(); para.alignment = .left
        (name as NSString).draw(in: NSRect(x: 10, y: 8, width: 160, height: 16), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para
        ])
        img.unlockFocus()
        return img
    }

    // NSDraggingSource
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }
    func draggingSession(_ session: NSDraggingSession,
                         endedAt point: NSPoint, operation: NSDragOperation) {
        badgeLog("[RowDrag] ended op=\(operation.rawValue)")
    }

    // 마우스 이벤트 수신 활성화
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // hover cursor
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}

// MARK: - Drag Handle Icon (좌측 핸들 아이콘만 표시용)
struct DragHandleIcon: View {
    var color: Color = .secondary
    var body: some View {
        VStack(spacing: 2) {
            ForEach(0..<3) { _ in
                HStack(spacing: 2) {
                    ForEach(0..<2) { _ in
                        Circle().fill(color.opacity(0.45)).frame(width: 2, height: 2)
                    }
                }
            }
        }
        .frame(width: 10, height: 22)
    }
}

// MARK: - Drop highlight overlay
extension View {
    func dragHighlightOverlay(isTargeted: Bool, color: Color) -> some View {
        self.overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(color, lineWidth: isTargeted ? 2 : 0)
                .animation(.easeInOut(duration: 0.15), value: isTargeted)
        )
    }
}
