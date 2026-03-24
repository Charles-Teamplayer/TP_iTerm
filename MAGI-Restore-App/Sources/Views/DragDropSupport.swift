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

// MARK: - Debug Logger (/tmp/badge_debug.log)

private func badgeLog(_ msg: String) {
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

// MARK: - AppKit Badge View

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

class BadgeNSView: NSView, NSGestureRecognizerDelegate {
    private var _label = ""
    private var _isTabNumber = false
    private var onTap: (() -> Void)?
    private var onDragChanged: ((CGPoint) -> Void)?
    private var onDragEnded: ((CGPoint) -> Void)?
    private var onDragCancelled: (() -> Void)?

    private var isDragging = false
    private var isMouseDown = false

    // Monitor 방식 (SwiftUI가 responder chain 차단해도 작동)
    private var mouseDownMonitor: Any?
    private var dragMonitor: Any?
    private var mouseDownPt: NSPoint?

    // GestureRecognizer 방식 (동시 실행, 보조)
    private var panGR: NSPanGestureRecognizer?
    private var clickGR: NSClickGestureRecognizer?

    private let dragThreshold: CGFloat = 3

    deinit { removeAllMonitors() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // label이 비어있을 때(투명 오버레이)는 NSView hitTest pass-through → 아래 SwiftUI Button 클릭 살아있음
    override func hitTest(_ point: NSPoint) -> NSView? {
        return _label.isEmpty ? nil : super.hitTest(point)
    }

    // MARK: - viewDidMoveToWindow

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeAllMonitors()
        removeAllGestures()
        badgeLog("viewDidMoveToWindow label=\(_label) window=\(window != nil ? "YES" : "nil")")
        guard window != nil else { return }

        // ── Approach 1: Persistent local monitor ──
        mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self = self, self.window != nil else { return event }
            // 뷰 bounds를 window base 좌표로 변환 후 히트 체크 (4px 확장 → Divider/padding 경계 흡수)
            let viewRect = self.convert(self.bounds, to: nil).insetBy(dx: 0, dy: -4)
            let hit = viewRect.contains(event.locationInWindow)
            badgeLog("monitor mouseDown label=\(self._label) viewRect=\(viewRect) click=\(event.locationInWindow) hit=\(hit)")
            if hit { self.monitorStartTracking(at: event.locationInWindow) }
            return event
        }

        // ── Approach 2: NSPanGestureRecognizer (동시 실행 허용) ──
        let pan = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        pan.buttonMask = 0x1  // left mouse button only
        addGestureRecognizer(pan)
        panGR = pan

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
        click.delegate = self
        click.numberOfClicksRequired = 1
        addGestureRecognizer(click)
        clickGR = click

        badgeLog("monitors+gestures installed label=\(_label)")
    }

    // NSGestureRecognizerDelegate: ScrollView와 동시 실행 허용
    func gestureRecognizer(_ gr: NSGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: NSGestureRecognizer) -> Bool {
        return true
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

    // MARK: - NSPanGestureRecognizer handler

    @objc private func handlePan(_ gr: NSPanGestureRecognizer) {
        // locationInView → convert to window base → toSwiftUIGlobal
        let localPt = gr.location(in: self)
        let windowPt = convert(localPt, to: nil)
        let globalPt = toSwiftUIGlobal(windowPt)
        badgeLog("panGR state=\(gr.state.rawValue) label=\(_label) global=\(globalPt)")

        switch gr.state {
        case .began:
            // monitor도 이미 시작했을 수 있으므로 중복 체크
            if !isDragging {
                isDragging = true
                isMouseDown = true
                needsDisplay = true
                badgeLog("panGR DRAG STARTED label=\(_label)")
                DispatchQueue.main.async { self.onDragChanged?(globalPt) }
            }
        case .changed:
            if isDragging {
                DispatchQueue.main.async { self.onDragChanged?(globalPt) }
            }
        case .ended:
            if isDragging {
                badgeLog("panGR DRAG ENDED label=\(_label)")
                let wasDragging = isDragging
                isDragging = false
                isMouseDown = false
                needsDisplay = true
                // monitor 기반 드래그도 종료
                monitorCancelTracking()
                DispatchQueue.main.async {
                    if wasDragging { self.onDragEnded?(globalPt) }
                }
            }
        case .cancelled, .failed:
            if isDragging {
                isDragging = false; isMouseDown = false; needsDisplay = true
                monitorCancelTracking()
                DispatchQueue.main.async { self.onDragCancelled?() }
            }
        default: break
        }
    }

    @objc private func handleClick(_ gr: NSClickGestureRecognizer) {
        guard gr.state == .ended, !isDragging else { return }
        badgeLog("clickGR tap label=\(_label)")
        DispatchQueue.main.async { self.onTap?() }
    }

    // MARK: - Monitor-based tracking

    private func monitorStartTracking(at windowPt: NSPoint) {
        guard mouseDownPt == nil else { return }
        mouseDownPt = windowPt
        isMouseDown = true
        DispatchQueue.main.async { self.needsDisplay = true }
        removeDragMonitor()

        dragMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDragged, .leftMouseUp]
        ) { [weak self] e in
            self?.handleMonitorDragEvent(e)
            return e
        }
        badgeLog("dragMonitor installed label=\(_label)")
    }

    private func monitorCancelTracking() {
        mouseDownPt = nil
        removeDragMonitor()
    }

    private func handleMonitorDragEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDragged:
            guard let startPt = mouseDownPt else { return }
            let curPt = event.locationInWindow
            let dist = hypot(curPt.x - startPt.x, curPt.y - startPt.y)
            guard dist >= dragThreshold else { return }
            if !isDragging {
                isDragging = true
                badgeLog("monitor DRAG STARTED label=\(_label)")
                DispatchQueue.main.async { self.needsDisplay = true }
            }
            let pos = toSwiftUIGlobal(curPt)
            badgeLog("monitor dragging label=\(_label) pos=\(pos)")
            DispatchQueue.main.async { self.onDragChanged?(pos) }

        case .leftMouseUp:
            removeDragMonitor()
            let pos = toSwiftUIGlobal(event.locationInWindow)
            let wasDragging = isDragging
            badgeLog("monitor mouseUp label=\(_label) wasDragging=\(wasDragging) pos=\(pos)")
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
        default: break
        }
    }

    // MARK: - Responder chain fallback

    override func mouseDown(with event: NSEvent) {
        badgeLog("mouseDown via responder label=\(_label)")
        if mouseDownPt == nil { monitorStartTracking(at: event.locationInWindow) }
    }
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}

    // MARK: - Draw

    override func draw(_ dirtyRect: NSRect) {
        // _label이 비어있으면 시각적 표시 없음 (투명 드래그 오버레이)
        guard !_label.isEmpty else { return }
        let str = _label as NSString
        if _isTabNumber {
            let alpha: CGFloat = isDragging ? 0.6 : (isMouseDown ? 0.35 : 0.15)
            NSColor.systemBlue.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3).fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor.systemBlue.withAlphaComponent(0.9)
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
        mouseDownPt = nil
    }

    private func removeAllGestures() {
        gestureRecognizers.forEach { removeGestureRecognizer($0) }
        panGR = nil; clickGR = nil
    }

    // AppKit window base(좌하단 원점) → SwiftUI .global(창 좌상단, y 아래 증가)
    private func toSwiftUIGlobal(_ windowPt: NSPoint) -> CGPoint {
        guard let cv = window?.contentView else { return CGPoint(x: windowPt.x, y: windowPt.y) }
        return CGPoint(x: windowPt.x, y: cv.bounds.height - windowPt.y)
    }
}
