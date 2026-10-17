import AppKit
import QuartzCore

/// Transparent view above the map that turns mouse drags into shapes.
/// It only claims left-mouse events, so scrolling, pinching and (with the pan tool or
/// Space held) dragging still reach the map underneath.
final class DrawingOverlayView: NSView {
    var tool: Tool = .freehand {
        didSet { if tool != oldValue { cancel() } }
    }
    var isInteractive = true {
        didSet {
            if !isInteractive { cancel() }
            if isInteractive != oldValue { window?.invalidateCursorRects(for: self) }
        }
    }

    /// Screen path of the committed shape, used to start a move when clicking inside it.
    var shapePath: (() -> CGPath?)?
    var onCommit: (([CGPoint]) -> Void)?
    var onMoveBegan: (() -> Void)?
    var onMoveEnded: ((CGSize) -> Void)?

    private let fillLayer = CAShapeLayer()
    private let strokeLayer = CAShapeLayer()
    private var points: [CGPoint] = []
    private var dragStart: CGPoint?
    private var polygon: [CGPoint] = []
    private var moveStart: CGPoint?
    private var movePath: CGPath?

    var isBusy: Bool { dragStart != nil || !polygon.isEmpty || moveStart != nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true

        fillLayer.fillColor = NSColor.white.withAlphaComponent(0.14).cgColor
        fillLayer.strokeColor = nil
        fillLayer.fillRule = .evenOdd

        strokeLayer.fillColor = nil
        strokeLayer.strokeColor = NSColor.white.cgColor
        strokeLayer.lineWidth = 2.5
        strokeLayer.lineJoin = .round
        strokeLayer.lineCap = .round
        strokeLayer.lineDashPattern = [9, 6]
        strokeLayer.shadowColor = Palette.shape.cgColor
        strokeLayer.shadowRadius = 6
        strokeLayer.shadowOpacity = 1
        strokeLayer.shadowOffset = .zero

        let ants = CABasicAnimation(keyPath: "lineDashPhase")
        ants.fromValue = 0
        ants.toValue = -15
        ants.duration = 0.6
        ants.repeatCount = .infinity
        strokeLayer.add(ants, forKey: "ants")

        layer?.addSublayer(fillLayer)
        layer?.addSublayer(strokeLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isInteractive, let event = NSApp.currentEvent else { return nil }
        switch event.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp: return super.hitTest(point)
        default: return nil
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        if isInteractive { addCursorRect(bounds, cursor: .crosshair) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if tool == .polygon {
            if event.clickCount >= 2 || (polygon.count >= 3 && hypot(p.x - polygon[0].x, p.y - polygon[0].y) < 10) {
                finishPolygon()
                return
            }
            if polygon.isEmpty, let path = shapePath?(), path.contains(p) {
                beginMove(at: p, path: path)
                return
            }
            polygon.append(p)
            showPolygon(hover: p)
            return
        }
        if let path = shapePath?(), path.contains(p) {
            beginMove(at: p, path: path)
            return
        }
        dragStart = p
        points = [p]
        resetLayers()
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let m = moveStart, let path = movePath {
            var t = CGAffineTransform(translationX: p.x - m.x, y: p.y - m.y)
            if let moved = path.copy(using: &t) { show(moved, closed: true) }
            return
        }
        guard let start = dragStart else { return }
        if tool == .freehand {
            if let last = points.last, hypot(p.x - last.x, p.y - last.y) >= 2 { points.append(p) }
            show(ShapeTools.path(points, closed: false), closed: false)
        } else {
            points = ShapeTools.shape(tool, from: start, to: p,
                                      shift: event.modifierFlags.contains(.shift),
                                      alt: event.modifierFlags.contains(.option))
            show(ShapeTools.path(points, closed: true), closed: true)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let m = moveStart {
            moveStart = nil
            movePath = nil
            onMoveEnded?(CGSize(width: p.x - m.x, height: p.y - m.y))
            fadeOut()
            return
        }
        guard dragStart != nil else { return }
        dragStart = nil
        let final = tool == .freehand ? ShapeTools.smoothFreehand(points) : points
        points = []
        guard ShapeTools.isUsable(final) else {
            resetLayers()
            return
        }
        show(ShapeTools.path(final, closed: true), closed: true)
        onCommit?(final)
        fadeOut()
    }

    override func mouseMoved(with event: NSEvent) {
        guard tool == .polygon, !polygon.isEmpty, isInteractive else { return }
        showPolygon(hover: convert(event.locationInWindow, from: nil))
    }

    // MARK: Keys forwarded by the map coordinator

    /// Returns true when Return was used to close a polygon.
    func handleReturn() -> Bool {
        guard tool == .polygon, polygon.count >= 3 else { return false }
        finishPolygon()
        return true
    }

    func cancel() {
        dragStart = nil
        points = []
        polygon = []
        if moveStart != nil {
            moveStart = nil
            movePath = nil
            onMoveEnded?(.zero)
        }
        resetLayers()
    }

    // MARK: Private

    private func beginMove(at p: CGPoint, path: CGPath) {
        moveStart = p
        movePath = path
        onMoveBegan?()
        resetLayers()
        show(path, closed: true)
    }

    private func finishPolygon() {
        let pts = polygon
        polygon = []
        guard pts.count >= 3, ShapeTools.isUsable(pts) else {
            resetLayers()
            return
        }
        let ring = ShapeTools.densify(pts)
        show(ShapeTools.path(ring, closed: true), closed: true)
        onCommit?(ring)
        fadeOut()
    }

    private func showPolygon(hover: CGPoint) {
        let path = CGMutablePath()
        path.addLines(between: polygon + [hover])
        if polygon.count >= 2 { path.closeSubpath() }
        for v in polygon {
            path.addEllipse(in: CGRect(x: v.x - 3, y: v.y - 3, width: 6, height: 6))
        }
        show(path, closed: polygon.count >= 2)
    }

    private func show(_ path: CGPath, closed: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strokeLayer.path = path
        fillLayer.path = closed ? path : nil
        CATransaction.commit()
    }

    private func resetLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strokeLayer.removeAnimation(forKey: "fade")
        fillLayer.removeAnimation(forKey: "fade")
        strokeLayer.path = nil
        fillLayer.path = nil
        strokeLayer.opacity = 1
        fillLayer.opacity = 1
        CATransaction.commit()
    }

    /// Lets the committed map overlay take over smoothly from the live stroke.
    private func fadeOut() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.35)
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, !self.isBusy else { return }
            self.resetLayers()
        }
        strokeLayer.opacity = 0
        fillLayer.opacity = 0
        CATransaction.commit()
    }
}

enum Palette {
    static let shape = NSColor(calibratedRed: 1.0, green: 0.82, blue: 0.32, alpha: 1)
}
