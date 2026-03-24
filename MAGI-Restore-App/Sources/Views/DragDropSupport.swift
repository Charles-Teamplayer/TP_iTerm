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
    private var mouseDownPt: NSPoint?

    // Mechanism 1: NSEvent window-level monitors
    private var mouseDownMonitor: Any?
    private var dragMonitor: Any?

    // Mechanism 2: NSGestureRecognizers
    private var panGR: NSPanGestureRecognizer?
    private var clickGR: NSClickGestureRecognizer?

    private let dragThreshold: CGFloat = 3

    deinit {
        removeAllMonitors()
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - viewDidMoveToWindow

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeAllMonitors()
        removeAllGestures()
        badgeLog("viewDidMoveToWindow label=\(_label) window=\(window != nil ? "YES" : "nil")")
        guard window != nil else { return }

        // ── Mechanism 1a: mouseDown monitor ──
        // Window-level: fires before event dispatch, regardless of hitTest
        mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self = self, self.window != nil else { return event }
            let viewRect = self.convert(self.bounds, to: nil).insetBy(dx: 0, dy: -4)
            let hit = viewRect.contains(event.locationInWindow)
            badgeLog("monitor mouseDown label=\(self._label) viewRect=\(viewRect) hit=\(hit)")
            if hit {
                self.mouseDownPt = event.locationInWindow
                self.isMouseDown = true
                DispatchQueue.main.async { self.needsDisplay = true }
                self.installDragMonitor()
            }
            return event
        }

        // ── Mechanism 2a: NSPanGestureRecognizer ──
        // Works when hitTest returns this view (DragBadgeView on TOP of ZStack)
        let pan = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        pan.buttonMask = 0x1
        addGestureRecognizer(pan)
        panGR = pan

        // ── Mechanism 2b: NSClickGestureRecognizer ──
        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
        click.delegate = self
        click.numberOfClicksRequired = 1
        addGestureRecognizer(click)
        clickGR = click

        badgeLog("monitors+gestures installed label=\(_label)")
    }

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

    // MARK: - NSEvent Drag Monitor (Mechanism 1b)

    private func installDragMonitor() {
        removeDragMonitor()
        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self = self else { return event }
            self.handleMonitorEvent(event)
            return event
        }
        badgeLog("dragMonitor installed label=\(_label)")
    }

    private func handleMonitorEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDragged:
            let curPt = event.locationInWindow
            badgeLog("monitor dragged label=\(_label) pos=\(curPt) startPt=\(String(describing: mouseDownPt)) isDragging=\(isDragging)")
            guard let startPt = mouseDownPt else { return }
            let dist = hypot(curPt.x - startPt.x, curPt.y - startPt.y)
            guard dist >= dragThreshold else { return }
            if !isDragging {
                isDragging = true
                badgeLog("monitor DRAG STARTED label=\(_label)")
                DispatchQueue.main.async { self.needsDisplay = true }
            }
            let pos = toSwiftUIGlobal(curPt)
            DispatchQueue.main.async { self.onDragChanged?(pos) }

        case .leftMouseUp:
            removeDragMonitor()
            let pos = toSwiftUIGlobal(event.locationInWindow)
            let wasDragging = isDragging
            badgeLog("monitor mouseUp label=\(_label) wasDragging=\(wasDragging)")
            mouseDownPt = nil
            isDragging = false
            isMouseDown = false
            DispatchQueue.main.async {
                self.needsDisplay = true
                if wasDragging { self.onDragEnded?(pos) }
                // tap은 clickGR이 처리 (중복 방지)
            }
        default: break
        }
    }

    // MARK: - NSPanGestureRecognizer (Mechanism 2a)

    @objc private func handlePan(_ gr: NSPanGestureRecognizer) {
        let localPt = gr.location(in: self)
        let windowPt = convert(localPt, to: nil)
        let globalPt = toSwiftUIGlobal(windowPt)
        badgeLog("panGR state=\(gr.state.rawValue) label=\(_label) global=\(globalPt)")

        switch gr.state {
        case .began:
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
                let wasDragging = isDragging
                isDragging = false; isMouseDown = false; mouseDownPt = nil; needsDisplay = true
                removeDragMonitor()
                badgeLog("panGR DRAG ENDED label=\(_label)")
                DispatchQueue.main.async { if wasDragging { self.onDragEnded?(globalPt) } }
            }
        case .cancelled, .failed:
            if isDragging {
                isDragging = false; isMouseDown = false; mouseDownPt = nil; needsDisplay = true
                removeDragMonitor()
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

    // MARK: - Responder Chain (Mechanism 3)

    override func mouseDown(with event: NSEvent) {
        badgeLog("mouseDown(responder) label=\(_label)")
        if mouseDownPt == nil {
            mouseDownPt = event.locationInWindow
            isMouseDown = true
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let curPt = event.locationInWindow
        badgeLog("mouseDragged(responder) label=\(_label) pos=\(curPt) isDragging=\(isDragging)")
        guard let startPt = mouseDownPt else { return }
        let dist = hypot(curPt.x - startPt.x, curPt.y - startPt.y)
        guard dist >= dragThreshold else { return }
        if !isDragging {
            isDragging = true
            badgeLog("responder DRAG STARTED label=\(_label)")
            DispatchQueue.main.async { self.needsDisplay = true }
        }
        let pos = toSwiftUIGlobal(curPt)
        DispatchQueue.main.async { self.onDragChanged?(pos) }
    }

    override func mouseUp(with event: NSEvent) {
        let pos = toSwiftUIGlobal(event.locationInWindow)
        let wasDragging = isDragging
        badgeLog("mouseUp(responder) label=\(_label) wasDragging=\(wasDragging)")
        mouseDownPt = nil; isDragging = false; isMouseDown = false
        removeDragMonitor()
        DispatchQueue.main.async {
            self.needsDisplay = true
            if wasDragging { self.onDragEnded?(pos) }
        }
    }

    // MARK: - Draw

    override func draw(_ dirtyRect: NSRect) {
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
