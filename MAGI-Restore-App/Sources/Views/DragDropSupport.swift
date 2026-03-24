import SwiftUI
import AppKit

// MARK: - 프레임 추적 PreferenceKey

struct RowFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

struct PaneFrameKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

extension View {
    func reportRowFrame(key: String) -> some View {
        background(GeometryReader { geo in
            Color.clear.preference(key: RowFrameKey.self,
                                   value: [key: geo.frame(in: .global)])
        })
    }

    func reportPaneFrame(id: UUID) -> some View {
        background(GeometryReader { geo in
            Color.clear.preference(key: PaneFrameKey.self,
                                   value: [id: geo.frame(in: .global)])
        })
    }
}

// MARK: - AppKit Badge
// viewDidMoveToWindow에서 영구 mouseDown 모니터를 설치 →
// SwiftUI가 이벤트를 먹어도 우리 badge 위치에 클릭이면 드래그 추적 시작.

struct DragBadgeView: NSViewRepresentable {
    let label: String
    let isTabNumber: Bool
    let onTap: () -> Void
    let onDragChanged: (CGPoint) -> Void
    let onDragEnded: (CGPoint) -> Void
    let onDragCancelled: () -> Void

    func makeNSView(context: Context) -> BadgeNSView {
        let v = BadgeNSView()
        v.configure(label: label, isTabNumber: isTabNumber,
                    onTap: onTap, onDragChanged: onDragChanged,
                    onDragEnded: onDragEnded, onDragCancelled: onDragCancelled)
        return v
    }

    func updateNSView(_ v: BadgeNSView, context: Context) {
        v.configure(label: label, isTabNumber: isTabNumber,
                    onTap: onTap, onDragChanged: onDragChanged,
                    onDragEnded: onDragEnded, onDragCancelled: onDragCancelled)
    }
}

class BadgeNSView: NSView {
    private var _label = ""
    private var _isTabNumber = false
    private var onTap: (() -> Void)?
    private var onDragChanged: ((CGPoint) -> Void)?
    private var onDragEnded: ((CGPoint) -> Void)?
    private var onDragCancelled: (() -> Void)?

    private var mouseDownPt: NSPoint?
    private var isDragging = false
    private var isMouseDown = false
    private var mouseDownMonitor: Any?   // 영구 monitor: mouseDown 감지
    private var dragMonitor: Any?        // 드래그 시작 후 installed
    private let dragThreshold: CGFloat = 4

    deinit { removeAllMonitors() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - viewDidMoveToWindow: 영구 mouseDown 모니터 설치
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeAllMonitors()
        guard window != nil else { return }

        // leftMouseDown을 앱 전역에서 감시 → 우리 뷰 위에 클릭이면 추적 시작
        mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self = self else { return event }
            // window base coords → 이 뷰의 로컬 coords 변환
            let localPt = self.convert(event.locationInWindow, from: nil)
            if self.bounds.contains(localPt) {
                NSLog("[Badge] persistent mouseDown hit label=\(self._label) localPt=\(localPt)")
                self.startTracking(at: event.locationInWindow)
            }
            return event  // 이벤트 소비하지 않고 그대로 전달
        }
        NSLog("[Badge] mouseDownMonitor installed label=\(_label)")
    }

    func configure(label: String, isTabNumber: Bool,
                   onTap: @escaping () -> Void,
                   onDragChanged: @escaping (CGPoint) -> Void,
                   onDragEnded: @escaping (CGPoint) -> Void,
                   onDragCancelled: @escaping () -> Void) {
        _label = label
        _isTabNumber = isTabNumber
        self.onTap = onTap
        self.onDragChanged = onDragChanged
        self.onDragEnded = onDragEnded
        self.onDragCancelled = onDragCancelled
        toolTip = isTabNumber ? "클릭: 번호 편집 | 드래그: 창 이동" : "드래그하여 창 이동"
        needsDisplay = true
    }

    // MARK: - 드래그 추적 시작
    private func startTracking(at windowPt: NSPoint) {
        // 이미 추적 중이면 무시 (mouseDownMonitor가 중복 fire될 수 있음)
        guard mouseDownPt == nil else { return }
        mouseDownPt = windowPt
        isDragging = false
        isMouseDown = true
        DispatchQueue.main.async { self.needsDisplay = true }
        removeDragMonitor()

        dragMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDragged, .leftMouseUp]
        ) { [weak self] e in
            self?.handleDragEvent(e)
            return e
        }
    }

    private func handleDragEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDragged:
            guard let startPt = mouseDownPt else { return }
            let curPt = event.locationInWindow
            let dist = hypot(curPt.x - startPt.x, curPt.y - startPt.y)
            guard dist >= dragThreshold else { return }
            if !isDragging {
                isDragging = true
                NSLog("[Badge] drag started label=\(_label)")
                DispatchQueue.main.async { self.needsDisplay = true }
            }
            let pos = toSwiftUIGlobal(curPt)
            NSLog("[Badge] dragging pos=\(pos)")
            DispatchQueue.main.async { self.onDragChanged?(pos) }

        case .leftMouseUp:
            NSLog("[Badge] mouseUp isDragging=\(isDragging)")
            removeDragMonitor()
            let pos = toSwiftUIGlobal(event.locationInWindow)
            let wasDragging = isDragging
            mouseDownPt = nil
            isDragging = false
            isMouseDown = false
            DispatchQueue.main.async {
                self.needsDisplay = true
                if wasDragging {
                    self.onDragEnded?(pos)
                } else {
                    self.onTap?()
                }
            }
        default:
            break
        }
    }

    // 일반 responder chain으로도 오면 처리 (중복 방지)
    override func mouseDown(with event: NSEvent) {
        NSLog("[Badge] mouseDown via responder label=\(_label)")
        if mouseDownPt == nil {
            startTracking(at: event.locationInWindow)
        }
    }
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}

    // MARK: - Draw

    override func draw(_ dirtyRect: NSRect) {
        let str = _label as NSString
        if _isTabNumber {
            let alpha: CGFloat = isDragging ? 0.35 : (isMouseDown ? 0.2 : 0.1)
            NSColor.systemBlue.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3).fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor.systemBlue.withAlphaComponent(0.8)
            ]
            let sz = str.size(withAttributes: attrs)
            str.draw(at: NSPoint(x: (bounds.width - sz.width) / 2,
                                 y: (bounds.height - sz.height) / 2),
                     withAttributes: attrs)
        } else {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.tertiaryLabelColor
            ]
            let sz = str.size(withAttributes: attrs)
            str.draw(at: NSPoint(x: (bounds.width - sz.width) / 2,
                                 y: (bounds.height - sz.height) / 2),
                     withAttributes: attrs)
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    // MARK: - Helpers

    private func removeDragMonitor() {
        if let m = dragMonitor { NSEvent.removeMonitor(m); dragMonitor = nil }
    }

    private func removeAllMonitors() {
        if let m = mouseDownMonitor { NSEvent.removeMonitor(m); mouseDownMonitor = nil }
        removeDragMonitor()
    }

    // AppKit 창 좌표(좌하단 원점) → SwiftUI global 좌표(좌상단 원점)
    private func toSwiftUIGlobal(_ windowPt: NSPoint) -> CGPoint {
        guard let contentView = window?.contentView else {
            return CGPoint(x: windowPt.x, y: windowPt.y)
        }
        let h = contentView.bounds.height
        return CGPoint(x: windowPt.x, y: h - windowPt.y)
    }
}
