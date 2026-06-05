import AppKit
import Carbon
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

fileprivate enum AppIdentity {
    static let appName = "Azpaste"
    static let bundleIdentifier = "com.azpaste"
    static let windowOwnerNamesToIgnore = Set(["Azpaste", appName])
}

enum CaptureResult {
    case success
    case failure(String)
}

enum ImageCaptureResult {
    case success(CGImage)
    case failure(String)
}

enum CaptureMode {
    case selection
    case window
    case fullScreen
}

enum SelectionCaptureAction {
    case copy
    case save
    case pin
}

enum InteractiveCaptureResult {
    case cancelled
    case selection(CGRect, SelectionCaptureAction)
    case window(CGPoint)
}

private struct CaptureFailure: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

final class CaptureOverlayWindow: NSWindow {
    init(mode: CaptureMode, completion: @escaping (InteractiveCaptureResult) -> Void) {
        let frame = NSScreen.screens.reduce(CGRect.null) { result, screen in
            result.union(screen.frame)
        }

        let overlayView = CaptureOverlayView(mode: mode, completion: completion)
        super.init(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        contentView = overlayView
        backgroundColor = .clear
        isOpaque = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool {
        true
    }
}

final class CaptureOverlayView: NSView {
    private enum SelectionState {
        case idle
        case dragging
        case editing
    }

    private enum DragOperation {
        case create
        case move(CGPoint)
        case resize(ResizeHandle)
    }

    private enum ResizeHandle {
        case topLeft
        case top
        case topRight
        case right
        case bottomRight
        case bottom
        case bottomLeft
        case left
    }

    private struct ToolbarButton {
        let action: SelectionCaptureAction
        let rect: CGRect
    }

    private struct ToolbarItem {
        let action: SelectionCaptureAction
        let iconName: String
    }

    private static let minSelectionSize: CGFloat = 4
    private static let dragThreshold: CGFloat = 3
    private static let handleHitSize: CGFloat = 8
    private static let snapThreshold: CGFloat = 10
    private static let toolbarHeight: CGFloat = 34
    private static let toolbarPadding: CGFloat = 8
    private static let toolbarButtonWidth: CGFloat = 34
    private static let toolbarButtonSpacing: CGFloat = 6
    private static let toolbarIconSize: CGFloat = 22
    private static let overlayDismissDelay: TimeInterval = 0.08

    private let mode: CaptureMode
    private let completion: (InteractiveCaptureResult) -> Void
    private var state: SelectionState = .idle
    private var dragOperation: DragOperation?
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?
    private var mouseLocation: CGPoint?
    private var selectionRect: CGRect?
    private var snapCandidateRect: CGRect?
    private var toolbarButtons: [ToolbarButton] = []
    private var toolbarIconCache: [String: NSImage] = [:]

    init(mode: CaptureMode, completion: @escaping (InteractiveCaptureResult) -> Void) {
        self.mode = mode
        self.completion = completion
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func viewDidMoveToWindow() {
        window?.makeFirstResponder(self)
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            complete(.cancelled)
            return
        }

        guard mode == .selection,
              state == .editing,
              var rect = selectionRect else {
            return
        }

        let step: CGFloat = event.modifierFlags.contains(.option) ? 10 : 1
        switch Int(event.keyCode) {
        case kVK_LeftArrow:
            rect.origin.x -= step
        case kVK_RightArrow:
            rect.origin.x += step
        case kVK_UpArrow:
            rect.origin.y += step
        case kVK_DownArrow:
            rect.origin.y -= step
        default:
            return
        }
        selectionRect = constrained(rect)
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        mouseLocation = event.locationInWindow
        if mode == .selection,
           state == .idle {
            snapCandidateRect = snapCandidate(at: event.locationInWindow)
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = event.locationInWindow
        mouseLocation = point
        switch mode {
        case .selection:
            dragStart = point
            dragCurrent = point

            if let action = toolbarAction(at: point),
               let selectionRect {
                complete(.selection(captureGlobalRect(from: selectionRect), action))
                return
            }

            if let selectionRect,
               state == .editing {
                let visibleSelectionRect = pixelAligned(selectionRect)
                self.selectionRect = visibleSelectionRect
                if let handle = resizeHandle(at: point, in: visibleSelectionRect) {
                    dragOperation = .resize(handle)
                } else if visibleSelectionRect.contains(point) {
                    dragOperation = .move(CGPoint(x: point.x - visibleSelectionRect.minX, y: point.y - visibleSelectionRect.minY))
                } else {
                    dragOperation = .create
                    state = .dragging
                    self.selectionRect = nil
                }
            } else {
                dragOperation = .create
            }
        case .window:
            complete(.window(globalPoint(from: point)))
        case .fullScreen:
            break
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .selection else { return }
        let point = event.locationInWindow
        mouseLocation = point
        dragCurrent = point

        switch dragOperation {
        case .create:
            state = .dragging
            snapCandidateRect = nil
            if let dragStart {
                selectionRect = normalizedRect(from: dragStart, to: point)
            }
        case .move(let offset):
            guard var rect = selectionRect else { break }
            rect.origin = CGPoint(x: point.x - offset.x, y: point.y - offset.y)
            selectionRect = constrained(rect)
        case .resize(let handle):
            guard let rect = selectionRect else { break }
            selectionRect = constrained(resizedRect(rect, handle: handle, to: point))
        case .none:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard mode == .selection else {
            return
        }

        let point = event.locationInWindow
        mouseLocation = point

        if let dragStart,
           distance(from: dragStart, to: point) < Self.dragThreshold,
           state == .idle,
           let snapCandidateRect {
            selectionRect = constrained(snapCandidateRect)
            state = .editing
            self.dragStart = nil
            dragCurrent = nil
            dragOperation = nil
            needsDisplay = true
            return
        }

        if let rect = selectionRect,
           rect.width >= Self.minSelectionSize,
           rect.height >= Self.minSelectionSize {
            selectionRect = constrained(rect)
            state = .editing
        } else if isCreatingSelection {
            selectionRect = nil
            state = .idle
            snapCandidateRect = snapCandidate(at: point)
        }

        dragStart = nil
        dragCurrent = nil
        dragOperation = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        drawMask()

        if mode == .window {
            let text = "点击要截取的窗口，按 Esc 取消"
            drawHint(text)
        }

        guard mode == .selection else {
            return
        }

        if let snapCandidateRect,
           state == .idle {
            let displayedCandidateRect = pixelAligned(snapCandidateRect)
            drawSelectionFrame(displayedCandidateRect, isCandidate: true)
            drawSizeLabel(for: displayedCandidateRect)
        }

        guard let selectionRect else {
            if mode == .selection {
                drawHint("拖拽选择截图区域，靠近窗口或屏幕边缘可吸附，按 Esc 取消")
            }
            return
        }

        let displayedSelectionRect = pixelAligned(selectionRect)
        drawSelectionFrame(displayedSelectionRect, isCandidate: false)
        drawSizeLabel(for: displayedSelectionRect)

        if state == .editing {
            drawToolbar(for: displayedSelectionRect)
        }
    }

    private func drawMask() {
        NSColor.black.withAlphaComponent(0.22).setFill()
        let visibleRect = (selectionRect ?? snapCandidateRect).map(pixelAligned)
        if let rect = visibleRect {
            let path = NSBezierPath(rect: bounds)
            path.append(NSBezierPath(rect: rect))
            path.windingRule = .evenOdd
            path.fill()
        } else {
            bounds.fill()
        }
    }

    private func drawSelectionFrame(_ rect: CGRect, isCandidate: Bool) {
        (isCandidate ? NSColor.systemYellow : NSColor.controlAccentColor).setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = isCandidate ? 2 : 2.5
        if isCandidate {
            path.setLineDash([6, 4], count: 2, phase: 0)
        }
        path.stroke()

        guard !isCandidate else { return }
        NSColor.controlAccentColor.setFill()
        for handleRect in handleRects(for: rect) {
            let handlePath = NSBezierPath(roundedRect: handleRect, xRadius: 2, yRadius: 2)
            handlePath.fill()
        }
    }

    private func drawSizeLabel(for rect: CGRect) {
        let size = pixelSize(for: rect)
        let text = "\(Int(size.width)) × \(Int(size.height))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let textSize = text.size(withAttributes: attributes)
        let labelRect = placedRect(
            preferred: CGRect(x: rect.minX, y: rect.maxY + 8, width: textSize.width + 14, height: 24),
            avoiding: nil
        )

        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 5, yRadius: 5).fill()
        text.draw(
            in: labelRect.insetBy(dx: 7, dy: 3),
            withAttributes: attributes
        )
    }

    private func drawToolbar(for rect: CGRect) {
        let items: [ToolbarItem] = [
            ToolbarItem(action: .copy, iconName: "toolbar-copy"),
            ToolbarItem(action: .save, iconName: "toolbar-save"),
            ToolbarItem(action: .pin, iconName: "toolbar-pin")
        ]
        var buttons: [ToolbarButton] = []
        let toolbarWidth = CGFloat(items.count) * Self.toolbarButtonWidth +
            CGFloat(items.count - 1) * Self.toolbarButtonSpacing +
            Self.toolbarPadding * 2
        let toolbarRect = placedRect(
            preferred: CGRect(
                x: rect.minX,
                y: rect.minY - Self.toolbarHeight - 10,
                width: toolbarWidth,
                height: Self.toolbarHeight
            ),
            avoiding: rect
        )

        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: toolbarRect, xRadius: 6, yRadius: 6).fill()

        var x = toolbarRect.minX + Self.toolbarPadding
        for item in items {
            let buttonRect = CGRect(
                x: x,
                y: toolbarRect.minY + 5,
                width: Self.toolbarButtonWidth,
                height: Self.toolbarHeight - 10
            )
            NSColor.white.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: buttonRect, xRadius: 5, yRadius: 5).fill()
            if let image = toolbarIcon(named: item.iconName) {
                drawToolbarIcon(image, in: buttonRect)
            }
            buttons.append(ToolbarButton(action: item.action, rect: buttonRect))
            x += Self.toolbarButtonWidth + Self.toolbarButtonSpacing
        }
        toolbarButtons = buttons
    }

    private func toolbarIcon(named name: String) -> NSImage? {
        if let icon = toolbarIconCache[name] {
            return icon
        }

        guard let url = Bundle.main.url(
            forResource: name,
            withExtension: "png",
            subdirectory: "ToolbarIcons"
        ),
              let icon = NSImage(contentsOf: url) else {
            return nil
        }

        toolbarIconCache[name] = icon
        return icon
    }

    private func drawToolbarIcon(_ image: NSImage, in buttonRect: CGRect) {
        let side = Self.toolbarIconSize
        let iconRect = CGRect(
            x: buttonRect.midX - side / 2,
            y: buttonRect.midY - side / 2,
            width: side,
            height: side
        )
        image.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
    }

    private func drawHint(_ text: String) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attributes)
        let rect = CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        text.draw(in: rect, withAttributes: attributes)
    }

    private func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(start.x - end.x),
            height: abs(start.y - end.y)
        )
    }

    private func resizedRect(_ rect: CGRect, handle: ResizeHandle, to point: CGPoint) -> CGRect {
        var minX = rect.minX
        var minY = rect.minY
        var maxX = rect.maxX
        var maxY = rect.maxY

        switch handle {
        case .topLeft:
            minX = point.x
            maxY = point.y
        case .top:
            maxY = point.y
        case .topRight:
            maxX = point.x
            maxY = point.y
        case .right:
            maxX = point.x
        case .bottomRight:
            maxX = point.x
            minY = point.y
        case .bottom:
            minY = point.y
        case .bottomLeft:
            minX = point.x
            minY = point.y
        case .left:
            minX = point.x
        }

        return normalizedRect(from: CGPoint(x: minX, y: minY), to: CGPoint(x: maxX, y: maxY))
    }

    private func constrained(_ rect: CGRect) -> CGRect {
        var result = rect
        if result.width < Self.minSelectionSize {
            result.size.width = Self.minSelectionSize
        }
        if result.height < Self.minSelectionSize {
            result.size.height = Self.minSelectionSize
        }
        result.origin.x = min(max(result.minX, bounds.minX), bounds.maxX - result.width)
        result.origin.y = min(max(result.minY, bounds.minY), bounds.maxY - result.height)
        return result
    }

    private func snapCandidate(at point: CGPoint) -> CGRect? {
        let global = globalPoint(from: point)
        var candidates = NSScreen.screens.map(\.frame)
        candidates.append(contentsOf: visibleWindowRects())

        let matching = candidates
            .filter { rect in
                rect.width >= Self.minSelectionSize &&
                    rect.height >= Self.minSelectionSize &&
                    distanceToEdge(of: rect, from: global) <= Self.snapThreshold
            }
            .sorted { lhs, rhs in
                distanceToEdge(of: lhs, from: global) < distanceToEdge(of: rhs, from: global)
            }

        guard let rect = matching.first else { return nil }
        return localRect(fromGlobal: rect)
    }

    private func visibleWindowRects() -> [CGRect] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return windowInfo.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let ownerName = info[kCGWindowOwnerName as String] as? String,
                  !AppIdentity.windowOwnerNamesToIgnore.contains(ownerName),
                  let boundsDictionary = info[kCGWindowBounds as String] as? [String: Any] else {
                return nil
            }
            let quartzRect = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) ?? .zero
            guard let rect = ScreenCoordinates.appKitRect(fromQuartzRect: quartzRect) else { return nil }
            guard rect.width > 20, rect.height > 20 else { return nil }
            return rect
        }
    }

    private func distanceToEdge(of rect: CGRect, from point: CGPoint) -> CGFloat {
        guard rect.insetBy(dx: -Self.snapThreshold, dy: -Self.snapThreshold).contains(point) else {
            return .greatestFiniteMagnitude
        }

        return min(
            abs(point.x - rect.minX),
            abs(point.x - rect.maxX),
            abs(point.y - rect.minY),
            abs(point.y - rect.maxY)
        )
    }

    private func resizeHandle(at point: CGPoint, in rect: CGRect) -> ResizeHandle? {
        let handles: [(ResizeHandle, CGRect)] = [
            (.topLeft, handleRect(center: CGPoint(x: rect.minX, y: rect.maxY))),
            (.top, handleRect(center: CGPoint(x: rect.midX, y: rect.maxY))),
            (.topRight, handleRect(center: CGPoint(x: rect.maxX, y: rect.maxY))),
            (.right, handleRect(center: CGPoint(x: rect.maxX, y: rect.midY))),
            (.bottomRight, handleRect(center: CGPoint(x: rect.maxX, y: rect.minY))),
            (.bottom, handleRect(center: CGPoint(x: rect.midX, y: rect.minY))),
            (.bottomLeft, handleRect(center: CGPoint(x: rect.minX, y: rect.minY))),
            (.left, handleRect(center: CGPoint(x: rect.minX, y: rect.midY)))
        ]
        return handles.first { $0.1.insetBy(dx: -4, dy: -4).contains(point) }?.0
    }

    private func handleRects(for rect: CGRect) -> [CGRect] {
        [
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.midX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.midY)
        ].map(handleRect(center:))
    }

    private func handleRect(center: CGPoint) -> CGRect {
        CGRect(
            x: center.x - Self.handleHitSize / 2,
            y: center.y - Self.handleHitSize / 2,
            width: Self.handleHitSize,
            height: Self.handleHitSize
        )
    }

    private func toolbarAction(at point: CGPoint) -> SelectionCaptureAction? {
        toolbarButtons.first { $0.rect.contains(point) }?.action
    }

    private func pixelSize(for rect: CGRect) -> CGSize {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(globalRect(from: rect).center) }) else {
            return rect.size
        }
        return CGSize(width: rect.width * screen.backingScaleFactor, height: rect.height * screen.backingScaleFactor)
    }

    private func placedRect(preferred: CGRect, avoiding avoidRect: CGRect?) -> CGRect {
        var rect = preferred
        if rect.maxX > bounds.maxX - 8 {
            rect.origin.x = bounds.maxX - rect.width - 8
        }
        if rect.minX < bounds.minX + 8 {
            rect.origin.x = bounds.minX + 8
        }
        if rect.maxY > bounds.maxY - 8 {
            rect.origin.y = bounds.maxY - rect.height - 8
        }
        if rect.minY < bounds.minY + 8 {
            rect.origin.y = bounds.minY + 8
        }
        if let avoidRect,
           rect.intersects(avoidRect) {
            let above = CGRect(x: avoidRect.minX, y: avoidRect.maxY + 10, width: rect.width, height: rect.height)
            let below = CGRect(x: avoidRect.minX, y: avoidRect.minY - rect.height - 10, width: rect.width, height: rect.height)
            rect = above.maxY <= bounds.maxY ? above : below
            if rect.maxX > bounds.maxX - 8 {
                rect.origin.x = bounds.maxX - rect.width - 8
            }
            if rect.minY < bounds.minY + 8 {
                rect.origin.y = bounds.minY + 8
            }
        }
        return rect
    }

    private func distance(from start: CGPoint, to end: CGPoint) -> CGFloat {
        hypot(start.x - end.x, start.y - end.y)
    }

    private var isCreatingSelection: Bool {
        if case .create = dragOperation {
            return true
        }
        return false
    }

    private func globalPoint(from point: CGPoint) -> CGPoint {
        guard let window else { return point }
        return CGPoint(x: window.frame.minX + point.x, y: window.frame.minY + point.y)
    }

    private func globalRect(from rect: CGRect) -> CGRect {
        guard let window else { return rect }
        return rect.offsetBy(dx: window.frame.minX, dy: window.frame.minY)
    }

    private func captureGlobalRect(from rect: CGRect) -> CGRect {
        ScreenCoordinates.pixelAlignedAppKitRect(globalRect(from: rect))
    }

    private func localRect(fromGlobal rect: CGRect) -> CGRect {
        guard let window else { return rect }
        return rect.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
    }

    private func pixelAligned(_ rect: CGRect) -> CGRect {
        localRect(fromGlobal: captureGlobalRect(from: rect))
    }

    private func complete(_ result: InteractiveCaptureResult) {
        let completion = self.completion
        window?.ignoresMouseEvents = true
        window?.alphaValue = 0
        window?.orderOut(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.overlayDismissDelay) {
            completion(result)
        }
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

private enum ScreenCoordinates {
    static func screen(containingAppKitPoint point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? nearestAppKitScreen(to: point)
    }

    static func screen(containingAppKitRect rect: CGRect) -> NSScreen? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return screen(containingAppKitPoint: center)
    }

    static func screen(containingQuartzPoint point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let displayID = screen.displayID else { return false }
            return CGDisplayBounds(displayID).contains(point)
        } ?? nearestQuartzScreen(to: point)
    }

    static func appKitRect(fromQuartzRect rect: CGRect) -> CGRect? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        guard let screen = screen(containingQuartzPoint: center),
              let displayID = screen.displayID else {
            return nil
        }

        let displayBounds = CGDisplayBounds(displayID)
        return CGRect(
            x: screen.frame.minX + rect.minX - displayBounds.minX,
            y: screen.frame.maxY - (rect.maxY - displayBounds.minY),
            width: rect.width,
            height: rect.height
        )
    }

    static func quartzPoint(fromAppKitPoint point: CGPoint) -> CGPoint? {
        guard let screen = screen(containingAppKitPoint: point),
              let displayID = screen.displayID else {
            return nil
        }

        let displayBounds = CGDisplayBounds(displayID)
        return CGPoint(
            x: displayBounds.minX + point.x - screen.frame.minX,
            y: displayBounds.minY + screen.frame.maxY - point.y
        )
    }

    static func quartzRect(fromAppKitRect rect: CGRect) -> CGRect? {
        guard let screen = screen(containingAppKitRect: rect),
              let displayID = screen.displayID else {
            return nil
        }

        let displayBounds = CGDisplayBounds(displayID)
        return CGRect(
            x: displayBounds.minX + rect.minX - screen.frame.minX,
            y: displayBounds.minY + screen.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    static func screenCaptureSourceRect(fromAppKitRect rect: CGRect) -> CGRect? {
        guard let screen = screen(containingAppKitRect: rect),
              let displayID = screen.displayID,
              let quartzRect = quartzRect(fromAppKitRect: rect) else {
            return nil
        }

        let displayBounds = CGDisplayBounds(displayID)
        return quartzRect.offsetBy(dx: -displayBounds.minX, dy: -displayBounds.minY)
    }

    static func pixelAlignedAppKitRect(_ rect: CGRect) -> CGRect {
        guard let screen = screen(containingAppKitRect: rect) else {
            return rect.integral
        }

        let scale = max(screen.backingScaleFactor, 1)
        let minX = (rect.minX * scale).rounded(.toNearestOrAwayFromZero) / scale
        let minY = (rect.minY * scale).rounded(.toNearestOrAwayFromZero) / scale
        let maxX = (rect.maxX * scale).rounded(.toNearestOrAwayFromZero) / scale
        let maxY = (rect.maxY * scale).rounded(.toNearestOrAwayFromZero) / scale
        let minSize = 1 / scale
        return CGRect(
            x: min(minX, maxX),
            y: min(minY, maxY),
            width: max(abs(maxX - minX), minSize),
            height: max(abs(maxY - minY), minSize)
        )
    }

    private static func nearestAppKitScreen(to point: CGPoint) -> NSScreen? {
        NSScreen.screens.min { lhs, rhs in
            distance(from: point, to: lhs.frame) < distance(from: point, to: rhs.frame)
        }
    }

    private static func nearestQuartzScreen(to point: CGPoint) -> NSScreen? {
        NSScreen.screens.min { lhs, rhs in
            guard let lhsDisplayID = lhs.displayID,
                  let rhsDisplayID = rhs.displayID else {
                return lhs.displayID != nil
            }
            return distance(from: point, to: CGDisplayBounds(lhsDisplayID)) <
                distance(from: point, to: CGDisplayBounds(rhsDisplayID))
        }
    }

    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let clampedX = min(max(point.x, rect.minX), rect.maxX)
        let clampedY = min(max(point.y, rect.minY), rect.maxY)
        return hypot(point.x - clampedX, point.y - clampedY)
    }
}

private final class CoordinateSelfTestView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let halfWidth = bounds.width / 2
        let halfHeight = bounds.height / 2

        NSColor(calibratedRed: 1, green: 0, blue: 0, alpha: 1).setFill()
        CGRect(x: bounds.minX, y: bounds.midY, width: halfWidth, height: halfHeight).fill()

        NSColor(calibratedRed: 0, green: 1, blue: 0, alpha: 1).setFill()
        CGRect(x: bounds.midX, y: bounds.midY, width: halfWidth, height: halfHeight).fill()

        NSColor(calibratedRed: 0, green: 0, blue: 1, alpha: 1).setFill()
        CGRect(x: bounds.minX, y: bounds.minY, width: halfWidth, height: halfHeight).fill()

        NSColor(calibratedRed: 1, green: 1, blue: 0, alpha: 1).setFill()
        CGRect(x: bounds.midX, y: bounds.minY, width: halfWidth, height: halfHeight).fill()
    }
}

final class FloatingPinWindow: NSWindow {
    private static let minPinSideLength: CGFloat = 96
    private static let maxVisibleFrameScale: CGFloat = 0.92

    private let pinAspectRatio: CGFloat
    private let maximumPinSize: CGSize

    init(image: CGImage) {
        let imageSize = CGSize(width: image.width, height: image.height)
        pinAspectRatio = imageSize.width / imageSize.height

        let screen = NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 900, height: 700)
        let maxSize = CGSize(width: visibleFrame.width * 0.72, height: visibleFrame.height * 0.72)
        maximumPinSize = CGSize(
            width: visibleFrame.width * Self.maxVisibleFrameScale,
            height: visibleFrame.height * Self.maxVisibleFrameScale
        )
        let scale = min(1, maxSize.width / imageSize.width, maxSize.height / imageSize.height)
        let windowSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let frame = CGRect(
            x: visibleFrame.midX - windowSize.width / 2,
            y: visibleFrame.midY - windowSize.height / 2,
            width: windowSize.width,
            height: windowSize.height
        )

        let imageView = FloatingPinImageView(
            frame: CGRect(origin: .zero, size: windowSize),
            aspectRatio: pinAspectRatio,
            minSize: Self.minimumSize(forAspectRatio: pinAspectRatio),
            maxSize: maximumPinSize
        )
        imageView.image = NSImage(cgImage: image, size: imageSize)
        imageView.imageScaling = .scaleProportionallyUpOrDown

        super.init(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        contentView = imageView
        backgroundColor = .clear
        isOpaque = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        hasShadow = true
        minSize = Self.minimumSize(forAspectRatio: pinAspectRatio)
        self.maxSize = maximumPinSize
        imageView.closeHandler = { [weak self] in
            self?.close()
        }
    }

    override var canBecomeKey: Bool {
        true
    }

    private static func minimumSize(forAspectRatio aspectRatio: CGFloat) -> CGSize {
        if aspectRatio >= 1 {
            return CGSize(width: minPinSideLength, height: minPinSideLength / aspectRatio)
        }
        return CGSize(width: minPinSideLength * aspectRatio, height: minPinSideLength)
    }
}

final class FloatingPinImageView: NSImageView {
    private enum ResizeEdge {
        case topLeft
        case topRight
        case bottomRight
        case bottomLeft
    }

    private struct ResizeState {
        let edge: ResizeEdge
        let originalFrame: CGRect
        let oppositeAnchor: CGPoint
    }

    private static let resizeHitThickness: CGFloat = 10

    var closeHandler: (() -> Void)?
    private let aspectRatio: CGFloat
    private let minSize: CGSize
    private let maxSize: CGSize
    private var resizeState: ResizeState?

    init(frame frameRect: NSRect, aspectRatio: CGFloat, minSize: CGSize, maxSize: CGSize) {
        self.aspectRatio = aspectRatio
        self.minSize = minSize
        self.maxSize = maxSize
        super.init(frame: frameRect)
        postsFrameChangedNotifications = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            closeHandler?()
        } else if let window,
                  let edge = resizeEdge(at: convert(event.locationInWindow, from: nil)) {
            resizeState = ResizeState(
                edge: edge,
                originalFrame: window.frame,
                oppositeAnchor: oppositeAnchor(for: edge, in: window.frame)
            )
        } else {
            window?.performDrag(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window,
              let resizeState else {
            super.mouseDragged(with: event)
            return
        }

        let pointer = window.convertPoint(toScreen: event.locationInWindow)
        window.setFrame(
            resizedFrame(from: resizeState.originalFrame, edge: resizeState.edge, anchor: resizeState.oppositeAnchor, pointer: pointer),
            display: true
        )
    }

    override func mouseUp(with event: NSEvent) {
        resizeState = nil
        super.mouseUp(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRects(for: bounds)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            closeHandler?()
        } else {
            super.keyDown(with: event)
        }
    }

    private func resizeEdge(at point: CGPoint) -> ResizeEdge? {
        guard bounds.contains(point) else { return nil }

        let nearLeft = point.x <= bounds.minX + Self.resizeHitThickness
        let nearRight = point.x >= bounds.maxX - Self.resizeHitThickness
        let nearBottom = point.y <= bounds.minY + Self.resizeHitThickness
        let nearTop = point.y >= bounds.maxY - Self.resizeHitThickness

        switch (nearLeft, nearRight, nearTop, nearBottom) {
        case (true, _, true, _):
            return .topLeft
        case (_, true, true, _):
            return .topRight
        case (_, true, _, true):
            return .bottomRight
        case (true, _, _, true):
            return .bottomLeft
        default:
            return nil
        }
    }

    private func oppositeAnchor(for edge: ResizeEdge, in frame: CGRect) -> CGPoint {
        switch edge {
        case .topLeft:
            return CGPoint(x: frame.maxX, y: frame.minY)
        case .topRight:
            return CGPoint(x: frame.minX, y: frame.minY)
        case .bottomRight:
            return CGPoint(x: frame.minX, y: frame.maxY)
        case .bottomLeft:
            return CGPoint(x: frame.maxX, y: frame.maxY)
        }
    }

    private func resizedFrame(from originalFrame: CGRect, edge: ResizeEdge, anchor: CGPoint, pointer: CGPoint) -> CGRect {
        let size = constrainedSize(proposedSize(for: edge, anchor: anchor, pointer: pointer))

        switch edge {
        case .topLeft:
            return CGRect(x: anchor.x - size.width, y: anchor.y, width: size.width, height: size.height)
        case .topRight:
            return CGRect(x: anchor.x, y: anchor.y, width: size.width, height: size.height)
        case .bottomRight:
            return CGRect(x: anchor.x, y: anchor.y - size.height, width: size.width, height: size.height)
        case .bottomLeft:
            return CGRect(x: anchor.x - size.width, y: anchor.y - size.height, width: size.width, height: size.height)
        }
    }

    private func proposedSize(for edge: ResizeEdge, anchor: CGPoint, pointer: CGPoint) -> CGSize {
        switch edge {
        case .topLeft, .topRight, .bottomRight, .bottomLeft:
            let width = abs(pointer.x - anchor.x)
            let height = abs(pointer.y - anchor.y)
            if width / max(height, 1) > aspectRatio {
                return size(forWidth: width)
            }
            return size(forHeight: height)
        }
    }

    private func size(forWidth width: CGFloat) -> CGSize {
        let constrainedWidth = max(width, 1)
        return CGSize(width: constrainedWidth, height: constrainedWidth / aspectRatio)
    }

    private func size(forHeight height: CGFloat) -> CGSize {
        let constrainedHeight = max(height, 1)
        return CGSize(width: constrainedHeight * aspectRatio, height: constrainedHeight)
    }

    private func constrainedSize(_ proposed: CGSize) -> CGSize {
        let minScale = max(minSize.width / proposed.width, minSize.height / proposed.height, 1)
        let maxScale = min(maxSize.width / proposed.width, maxSize.height / proposed.height, 1)
        let scale = minScale > 1 ? minScale : maxScale
        return CGSize(width: proposed.width * scale, height: proposed.height * scale)
    }

    private func addCursorRects(for rect: CGRect) {
        let thickness = Self.resizeHitThickness
        let cursor = NSCursor.resizeLeftRight

        addCursorRect(CGRect(x: rect.minX, y: rect.maxY - thickness, width: thickness, height: thickness), cursor: cursor)
        addCursorRect(CGRect(x: rect.maxX - thickness, y: rect.maxY - thickness, width: thickness, height: thickness), cursor: cursor)
        addCursorRect(CGRect(x: rect.maxX - thickness, y: rect.minY, width: thickness, height: thickness), cursor: cursor)
        addCursorRect(CGRect(x: rect.minX, y: rect.minY, width: thickness, height: thickness), cursor: cursor)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let outputDirectoryKey = "outputDirectory"
    private static let hotKeyEnabledKey = "hotKeyEnabled"
    private static let hotKeyCodeKey = "hotKeyCode"
    private static let hotKeyModifiersKey = "hotKeyModifiers"
    private static let screenCapturePermissionRequestedKey = "screenCapturePermissionRequested"
    private static let screenshotDefaultsMigrationKey = "didMigrateDefaultsFromAzpasteScreenshot"
    private static let devDefaultsMigrationKey = "didMigrateDefaultsFromAzpasteDev"
    private static let screenshotDefaultsSuiteName = "com.azpaste.screenshot"
    private static let devDefaultsSuiteName = "com.azpaste.dev"
    private static let hotKeyID = UInt32(1)
    private static let defaultHotKeyCode = UInt32(kVK_ANSI_A)
    private static let defaultHotKeyModifiers = UInt32(controlKey | optionKey | cmdKey)
    private static let migratedDefaultsKeys = [
        outputDirectoryKey,
        hotKeyEnabledKey,
        hotKeyCodeKey,
        hotKeyModifiersKey,
        screenCapturePermissionRequestedKey
    ]
    private static let hotKeySignature = OSType(
        UInt32(UInt8(ascii: "A")) << 24 |
        UInt32(UInt8(ascii: "Z")) << 16 |
        UInt32(UInt8(ascii: "P")) << 8 |
        UInt32(UInt8(ascii: "S"))
    )
    private let defaults = UserDefaults(suiteName: AppIdentity.bundleIdentifier) ?? .standard

    private var window: NSWindow!
    private var statusItem: NSStatusItem!
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var hotKeyCaptureMonitor: Any?
    private var captureOverlayWindow: CaptureOverlayWindow?
    private var pinnedWindows: [FloatingPinWindow] = []
    private let shouldCaptureFullScreenOnLaunch = CommandLine.arguments.contains("--capture-fullscreen-on-launch")
    private let shouldQuitAfterCapture = CommandLine.arguments.contains("--quit-after-capture")
    private let shouldRunCoordinateSelfTest = CommandLine.arguments.contains("--self-test-coordinates")
    private let selfTestResultURL: URL? = {
        guard let index = CommandLine.arguments.firstIndex(of: "--self-test-result"),
              CommandLine.arguments.indices.contains(index + 1) else {
            return nil
        }
        return URL(fileURLWithPath: CommandLine.arguments[index + 1])
    }()
    private let statusLabel = NSTextField(labelWithString: "准备截屏")
    private let folderLabel = NSTextField(labelWithString: "")
    private let hotKeyCheckbox = NSButton(checkboxWithTitle: "启用快捷键截图", target: nil, action: nil)
    private lazy var hotKeyButton = makeWideButton(title: "设置快捷键", action: #selector(beginHotKeyCapture))
    private var outputDirectory: URL {
        get {
            if let savedPath = defaults.string(forKey: Self.outputDirectoryKey),
               !savedPath.isEmpty {
                return URL(fileURLWithPath: savedPath)
            }
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop")
                .appendingPathComponent("Azpaste Screenshots")
        }
        set {
            defaults.set(newValue.path, forKey: Self.outputDirectoryKey)
            updateFolderLabel()
        }
    }
    private var isHotKeyEnabled: Bool {
        get {
            defaults.bool(forKey: Self.hotKeyEnabledKey)
        }
        set {
            defaults.set(newValue, forKey: Self.hotKeyEnabledKey)
            hotKeyCheckbox.state = newValue ? .on : .off
            updateHotKeyRegistration()
            updateStatusMenu()
        }
    }
    private var hotKeyCode: UInt32 {
        get {
            let savedCode = defaults.integer(forKey: Self.hotKeyCodeKey)
            return savedCode == 0 ? Self.defaultHotKeyCode : UInt32(savedCode)
        }
        set {
            defaults.set(Int(newValue), forKey: Self.hotKeyCodeKey)
            updateHotKeyControls()
        }
    }
    private var hotKeyModifiers: UInt32 {
        get {
            let savedModifiers = defaults.integer(forKey: Self.hotKeyModifiersKey)
            return savedModifiers == 0 ? Self.defaultHotKeyModifiers : UInt32(savedModifiers)
        }
        set {
            defaults.set(Int(newValue), forKey: Self.hotKeyModifiersKey)
            updateHotKeyControls()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        migrateDefaultsIfNeeded()
        NSApp.setActivationPolicy(.accessory)

        if shouldRunCoordinateSelfTest {
            runCoordinateSelfTest()
            exit(EXIT_SUCCESS)
        }

        buildApplicationMenu()
        createOutputDirectory()
        buildWindow()
        buildStatusItem()
        installHotKeyHandler()
        updateHotKeyControls()
        updateHotKeyRegistration()
        updateScreenCapturePermissionStatus()
        NSApp.activate(ignoringOtherApps: true)

        if shouldCaptureFullScreenOnLaunch {
            writeSelfTestResult("launching-capture")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.captureFullScreen()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopHotKeyCapture()
        unregisterHotKey()
        if let hotKeyHandler {
            RemoveEventHandler(hotKeyHandler)
        }
    }

    private func buildApplicationMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        let quitItem = NSMenuItem(title: "退出 \(AppIdentity.appName)", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)

        appMenuItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    private func buildWindow() {
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 474))
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let title = NSTextField(labelWithString: AppIdentity.appName)
        title.font = .systemFont(ofSize: 26, weight: .semibold)
        title.textColor = .labelColor

        let subtitle = NSTextField(labelWithString: "截图会保存到你选择的文件夹，并自动复制到剪贴板。")
        subtitle.font = .systemFont(ofSize: 13, weight: .regular)
        subtitle.textColor = .secondaryLabelColor

        let selectionButton = makePrimaryButton(title: "选区截屏", action: #selector(captureSelection))
        let windowButton = makeButton(title: "窗口截屏", action: #selector(captureWindow))
        let fullButton = makeButton(title: "全屏截屏", action: #selector(captureFullScreen))
        let folderButton = makeButton(title: "打开保存目录", action: #selector(openOutputDirectory))
        let chooseFolderButton = makeWideButton(title: "选择保存目录", action: #selector(chooseOutputDirectory))
        let permissionButton = makeWideButton(title: "打开录屏权限设置", action: #selector(openScreenCapturePrivacySettings))

        hotKeyCheckbox.target = self
        hotKeyCheckbox.action = #selector(toggleHotKey)
        hotKeyCheckbox.font = .systemFont(ofSize: 13, weight: .medium)
        hotKeyCheckbox.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.textColor = .labelColor
        folderLabel.font = .systemFont(ofSize: 11)
        folderLabel.textColor = .tertiaryLabelColor
        folderLabel.lineBreakMode = .byTruncatingMiddle
        updateFolderLabel()

        let buttonGrid = NSGridView(views: [
            [selectionButton, windowButton],
            [fullButton, folderButton]
        ])
        buttonGrid.columnSpacing = 10
        buttonGrid.rowSpacing = 10
        buttonGrid.translatesAutoresizingMaskIntoConstraints = false
        for rowIndex in 0..<buttonGrid.numberOfRows {
            buttonGrid.row(at: rowIndex).height = 44
        }
        for columnIndex in 0..<buttonGrid.numberOfColumns {
            buttonGrid.column(at: columnIndex).width = 178
        }

        let stack = NSStackView(views: [title, subtitle, buttonGrid, chooseFolderButton, permissionButton, hotKeyCheckbox, hotKeyButton, statusLabel, folderLabel])
        stack.orientation = NSUserInterfaceLayoutOrientation.vertical
        stack.alignment = NSLayoutConstraint.Attribute.leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            chooseFolderButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
            permissionButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
            hotKeyCheckbox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            hotKeyButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
            folderLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        window = NSWindow(
            contentRect: contentView.frame,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = AppIdentity.appName
        window.center()
        window.contentView = contentView
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "截屏"
        updateStatusMenu()
    }

    private func updateStatusMenu() {
        guard statusItem != nil else { return }

        let menu = NSMenu()
        let showWindowItem = NSMenuItem(title: "显示窗口", action: #selector(showWindow), keyEquivalent: "")
        showWindowItem.target = self
        menu.addItem(showWindowItem)

        let captureSelectionItem = NSMenuItem(title: "选区截屏", action: #selector(captureSelection), keyEquivalent: "")
        captureSelectionItem.target = self
        menu.addItem(captureSelectionItem)

        let permissionItem = NSMenuItem(title: "打开录屏权限设置", action: #selector(openScreenCapturePrivacySettings), keyEquivalent: "")
        permissionItem.target = self
        menu.addItem(permissionItem)

        let hotKeyItem = NSMenuItem(
            title: isHotKeyEnabled ? "关闭快捷键截图（\(hotKeyDescription())）" : "开启快捷键截图（\(hotKeyDescription())）",
            action: #selector(toggleHotKeyFromMenu),
            keyEquivalent: ""
        )
        hotKeyItem.target = self
        hotKeyItem.state = isHotKeyEnabled ? .on : .off
        menu.addItem(hotKeyItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    private func makePrimaryButton(title: String, action: Selector) -> NSButton {
        let button = makeButton(title: title, action: action)
        button.keyEquivalent = "\r"
        button.bezelColor = .controlAccentColor
        return button
    }

    private func makeButton(title: String, action: Selector) -> NSButton {
        let button = makeBaseButton(title: title, action: action)
        button.widthAnchor.constraint(equalToConstant: 178).isActive = true
        return button
    }

    private func makeWideButton(title: String, action: Selector) -> NSButton {
        let button = makeBaseButton(title: title, action: action)
        button.widthAnchor.constraint(equalToConstant: 372).isActive = true
        return button
    }

    private func makeBaseButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.font = .systemFont(ofSize: 14, weight: .medium)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        return button
    }

    @objc private func captureSelection() {
        runCapture(mode: .selection, description: "选区截屏")
    }

    @objc private func captureWindow() {
        runCapture(mode: .window, description: "窗口截屏")
    }

    @objc private func captureFullScreen() {
        runCapture(mode: .fullScreen, description: "全屏截屏")
    }

    @objc private func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    @objc private func toggleHotKey() {
        isHotKeyEnabled = hotKeyCheckbox.state == .on
        statusLabel.stringValue = isHotKeyEnabled ? "快捷键截图已开启：\(hotKeyDescription())" : "快捷键截图已关闭"
    }

    @objc private func toggleHotKeyFromMenu() {
        isHotKeyEnabled.toggle()
        statusLabel.stringValue = isHotKeyEnabled ? "快捷键截图已开启：\(hotKeyDescription())" : "快捷键截图已关闭"
    }

    @objc private func beginHotKeyCapture() {
        stopHotKeyCapture()
        showWindow()
        statusLabel.stringValue = "请按新的快捷键，按 Esc 取消"
        hotKeyButton.title = "等待按键..."

        hotKeyCaptureMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleHotKeyCapture(event)
            return nil
        }
    }

    @objc private func openOutputDirectory() {
        createOutputDirectory()
        NSWorkspace.shared.open(outputDirectory)
    }

    @objc private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择截图保存目录"
        panel.prompt = "使用此目录"
        panel.message = "之后的截图会保存到这个文件夹。"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = outputDirectory

        if panel.runModal() == .OK,
           let selectedDirectory = panel.url {
            outputDirectory = selectedDirectory
            createOutputDirectory()
            statusLabel.stringValue = "保存目录已更新"
        }
    }

    @objc private func openScreenCapturePrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func runCapture(mode: CaptureMode, description: String) {
        guard hasScreenCaptureAccess() else {
            statusLabel.stringValue = "请在系统设置中允许 \(AppIdentity.appName)（\(AppIdentity.bundleIdentifier)）录制屏幕"
            writeSelfTestResult("missing-permission")
            requestScreenCaptureAccessIfNeeded()
            if shouldQuitAfterCapture {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    NSApp.terminate(nil)
                }
            }
            return
        }

        createOutputDirectory()
        let destination = outputDirectory.appendingPathComponent(fileName())
        statusLabel.stringValue = "\(description)中..."
        window.orderOut(nil)

        switch mode {
        case .selection, .window:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.beginInteractiveCapture(mode: mode, destination: destination)
            }
        case .fullScreen:
            Task {
                self.writeSelfTestResult("capture-started")
                let result = await self.captureScreen(rect: nil, destination: destination)
                await MainActor.run {
                    self.finishCapture(result, destination: destination)
                }
            }
        }
    }

    private func beginInteractiveCapture(mode: CaptureMode, destination: URL) {
        captureOverlayWindow = CaptureOverlayWindow(mode: mode) { [weak self] captureResult in
            guard let self else { return }
            self.captureOverlayWindow = nil

            switch captureResult {
            case .cancelled:
                self.finishCapture(.failure("已取消截屏"), destination: destination)
            case .selection(let rect, let action):
                Task {
                    let imageResult = await self.captureScreenImage(rect: rect)
                    await MainActor.run {
                        self.finishSelectionCapture(imageResult, action: action, destination: destination)
                    }
                }
            case .window(let point):
                Task {
                    let result = await self.captureWindowImage(at: point, destination: destination)
                    await MainActor.run {
                        self.finishCapture(result, destination: destination)
                    }
                }
            }
        }
        captureOverlayWindow?.makeKeyAndOrderFront(nil)
    }

    private func captureScreenImage(rect: CGRect?) async -> ImageCaptureResult {
        do {
            return .success(try await screenCaptureImage(rect: rect))
        } catch {
            requestScreenCaptureAccessIfNeeded(after: error)
            return .failure(screenCaptureErrorMessage(error, fallback: rect == nil ? "全屏截图失败" : "选区截图失败"))
        }
    }

    private func captureScreen(rect: CGRect?, destination: URL) async -> CaptureResult {
        switch await captureScreenImage(rect: rect) {
        case .success(let image):
            return writePNG(image, to: destination)
        case .failure(let message):
            return .failure(message)
        }
    }

    private func captureWindowImage(at point: CGPoint, destination: URL) async -> CaptureResult {
        do {
            let image = try await screenCaptureWindowImage(at: point)
            return writePNG(image, to: destination)
        } catch {
            requestScreenCaptureAccessIfNeeded(after: error)
            return .failure(screenCaptureErrorMessage(error, fallback: "没有找到可截图的窗口"))
        }
    }

    private func screenCaptureImage(rect: CGRect?) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let screen = screenForCapture(rect: rect),
              let displayID = screen.displayID,
              let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureFailure(message: "没有找到可截图的显示器")
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false

        if let rect {
            let alignedRect = ScreenCoordinates.pixelAlignedAppKitRect(rect)
            guard let sourceRect = ScreenCoordinates.screenCaptureSourceRect(fromAppKitRect: alignedRect) else {
                throw CaptureFailure(message: "选区坐标转换失败")
            }
            let scale = max(screen.backingScaleFactor, 1)
            configuration.sourceRect = sourceRect
            configuration.width = max(1, Int((alignedRect.width * scale).rounded()))
            configuration.height = max(1, Int((alignedRect.height * scale).rounded()))
        } else {
            configuration.width = display.width
            configuration.height = display.height
        }

        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    private func screenForCapture(rect: CGRect?) -> NSScreen? {
        if let rect,
           let screen = ScreenCoordinates.screen(containingAppKitRect: rect) {
            return screen
        }

        return NSScreen.main ?? NSScreen.screens.first
    }

    private func screenCaptureWindowImage(at point: CGPoint) async throws -> CGImage {
        guard let quartzPoint = ScreenCoordinates.quartzPoint(fromAppKitPoint: point) else {
            throw CaptureFailure(message: "窗口坐标转换失败")
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { window in
            window.windowLayer == 0 &&
                !AppIdentity.windowOwnerNamesToIgnore.contains(window.owningApplication?.applicationName ?? "") &&
                window.frame.contains(quartzPoint)
        }) else {
            throw CaptureFailure(message: "没有找到可截图的窗口")
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = ScreenCoordinates.screen(containingQuartzPoint: window.frame.center)?.backingScaleFactor ?? 1
        configuration.showsCursor = false
        configuration.width = max(1, Int((window.frame.width * scale).rounded()))
        configuration.height = max(1, Int((window.frame.height * scale).rounded()))

        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    private func screenCaptureErrorMessage(_ error: Error, fallback: String) -> String {
        if let captureFailure = error as? CaptureFailure {
            return captureFailure.message
        }

        let message = error.localizedDescription
        if isScreenCaptureDenied(error) {
            return "请在系统设置中允许 \(AppIdentity.appName)（\(AppIdentity.bundleIdentifier)）录制屏幕"
        }

        guard !message.isEmpty else { return fallback }
        return "\(fallback)：\(message)"
    }

    private func isScreenCaptureDenied(_ error: Error) -> Bool {
        let message = error.localizedDescription
        return message.localizedCaseInsensitiveContains("TCC") ||
            message.localizedCaseInsensitiveContains("denied") ||
            message.localizedCaseInsensitiveContains("拒绝")
    }

    private func writePNG(_ image: CGImage, to destination: URL) -> CaptureResult {
        guard let destinationRef = CGImageDestinationCreateWithURL(
            destination as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return .failure("无法创建截图文件")
        }

        CGImageDestinationAddImage(destinationRef, image, nil)
        guard CGImageDestinationFinalize(destinationRef),
              FileManager.default.fileExists(atPath: destination.path) else {
            try? FileManager.default.removeItem(at: destination)
            return .failure("保存截图失败")
        }

        return .success
    }

    private func finishSelectionCapture(
        _ imageResult: ImageCaptureResult,
        action: SelectionCaptureAction,
        destination: URL
    ) {
        switch imageResult {
        case .failure(let message):
            finishCapture(.failure(message), destination: destination)
        case .success(let image):
            switch action {
            case .copy:
                copyImageToPasteboard(image)
                finishCapture(
                    .success,
                    destination: destination,
                    successMessage: "已复制选区截图到粘贴板",
                    copiesSavedImageOnSuccess: false
                )
            case .save:
                let result = writePNG(image, to: destination)
                finishCapture(
                    result,
                    destination: destination,
                    successMessage: "已保存：\(destination.lastPathComponent)",
                    copiesSavedImageOnSuccess: false
                )
            case .pin:
                pinImage(image)
                finishCapture(
                    .success,
                    destination: destination,
                    successMessage: "已创建悬浮贴图，双击贴图可关闭",
                    copiesSavedImageOnSuccess: false
                )
            }
        }
    }

    private func finishCapture(
        _ result: CaptureResult,
        destination: URL,
        successMessage: String? = nil,
        copiesSavedImageOnSuccess: Bool = true
    ) {
        if NSApp.isActive {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        switch result {
        case .success:
            if copiesSavedImageOnSuccess {
                copyImageToPasteboard(destination)
            }
            statusLabel.stringValue = successMessage ?? "已保存并复制：\(destination.lastPathComponent)"
            writeSelfTestResult("success \(destination.path)")
        case .failure(let message):
            statusLabel.stringValue = message
            writeSelfTestResult("failure \(message)")
        }

        if shouldQuitAfterCapture {
            NSApp.terminate(nil)
        }
    }

    private func writeSelfTestResult(_ message: String) {
        guard let selfTestResultURL else { return }
        try? message.write(to: selfTestResultURL, atomically: true, encoding: .utf8)
    }

    private func runCoordinateSelfTest() {
        performCoordinateSelfTest(resultURL: selfTestResultURL)
    }

    private func updateScreenCapturePermissionStatus() {
        guard !hasScreenCaptureAccess() else {
            defaults.set(false, forKey: Self.screenCapturePermissionRequestedKey)
            return
        }

        statusLabel.stringValue = "首次使用前请允许 \(AppIdentity.appName)（\(AppIdentity.bundleIdentifier)）录制屏幕"
    }

    private func requestScreenCaptureAccessIfNeeded() {
        guard !defaults.bool(forKey: Self.screenCapturePermissionRequestedKey) else { return }

        defaults.set(true, forKey: Self.screenCapturePermissionRequestedKey)
        CGRequestScreenCaptureAccess()
    }

    private func requestScreenCaptureAccessIfNeeded(after error: Error) {
        guard isScreenCaptureDenied(error) else { return }

        defaults.set(true, forKey: Self.screenCapturePermissionRequestedKey)
        statusLabel.stringValue = "请在系统设置中允许 \(AppIdentity.appName)（\(AppIdentity.bundleIdentifier)）录制屏幕"
    }

    private func hasScreenCaptureAccess() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    private func migrateDefaultsIfNeeded() {
        migrateDefaults(
            fromSuiteName: Self.screenshotDefaultsSuiteName,
            migrationKey: Self.screenshotDefaultsMigrationKey
        )
        migrateDefaults(
            fromSuiteName: Self.devDefaultsSuiteName,
            migrationKey: Self.devDefaultsMigrationKey
        )
    }

    private func migrateDefaults(fromSuiteName suiteName: String, migrationKey: String) {
        guard !defaults.bool(forKey: migrationKey),
              let oldDefaults = UserDefaults(suiteName: suiteName) else {
            return
        }

        Self.migratedDefaultsKeys.forEach { key in
            guard defaults.object(forKey: key) == nil,
                  let oldValue = oldDefaults.object(forKey: key) else {
                return
            }
            defaults.set(oldValue, forKey: key)
        }

        defaults.set(true, forKey: migrationKey)
    }

    private func copyImageToPasteboard(_ url: URL) {
        guard let image = NSImage(contentsOf: url) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    private func copyImageToPasteboard(_ image: CGImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))])
    }

    private func pinImage(_ image: CGImage) {
        let pinWindow = FloatingPinWindow(image: image)
        pinnedWindows.append(pinWindow)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: pinWindow,
            queue: .main
        ) { [weak self, weak pinWindow] _ in
            guard let pinWindow else { return }
            self?.pinnedWindows.removeAll { $0 === pinWindow }
        }
        pinWindow.makeKeyAndOrderFront(nil)
    }

    private func createOutputDirectory() {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }

    private func updateFolderLabel() {
        folderLabel.stringValue = outputDirectory.path
    }

    private func handleHotKeyCapture(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            stopHotKeyCapture()
            statusLabel.stringValue = "已取消设置快捷键"
            return
        }

        let modifiers = carbonModifiers(from: event.modifierFlags)
        guard modifiers != 0 else {
            statusLabel.stringValue = "快捷键需要包含 Command、Control、Option 或 Shift"
            return
        }

        hotKeyCode = UInt32(event.keyCode)
        hotKeyModifiers = modifiers
        stopHotKeyCapture()

        if isHotKeyEnabled {
            updateHotKeyRegistration()
        }
        updateStatusMenu()
        statusLabel.stringValue = "快捷键已更新：\(hotKeyDescription())"
    }

    private func stopHotKeyCapture() {
        if let hotKeyCaptureMonitor {
            NSEvent.removeMonitor(hotKeyCaptureMonitor)
            self.hotKeyCaptureMonitor = nil
        }
        hotKeyButton.title = "设置快捷键：\(hotKeyDescription())"
    }

    private func installHotKeyHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let userData,
                  let event else {
                return noErr
            }

            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )

            if status == noErr,
               hotKeyID.signature == AppDelegate.hotKeySignature,
               hotKeyID.id == AppDelegate.hotKeyID {
                let appDelegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    appDelegate.captureSelection()
                }
            }
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &hotKeyHandler
        )
    }

    private func updateHotKeyRegistration() {
        unregisterHotKey()
        guard isHotKeyEnabled else { return }

        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: Self.hotKeyID)
        let status = RegisterEventHotKey(
            hotKeyCode,
            hotKeyModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status != noErr {
            hotKeyRef = nil
            hotKeyCheckbox.state = .off
            defaults.set(false, forKey: Self.hotKeyEnabledKey)
            statusLabel.stringValue = "快捷键注册失败，可能被其他应用占用"
        }
    }

    private func updateHotKeyControls() {
        hotKeyCheckbox.title = "启用快捷键截图：\(hotKeyDescription())"
        hotKeyCheckbox.state = isHotKeyEnabled ? .on : .off
        hotKeyButton.title = "设置快捷键：\(hotKeyDescription())"
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        let activeFlags = flags.intersection(.deviceIndependentFlagsMask)
        if activeFlags.contains(.control) {
            modifiers |= UInt32(controlKey)
        }
        if activeFlags.contains(.option) {
            modifiers |= UInt32(optionKey)
        }
        if activeFlags.contains(.command) {
            modifiers |= UInt32(cmdKey)
        }
        if activeFlags.contains(.shift) {
            modifiers |= UInt32(shiftKey)
        }
        return modifiers
    }

    private func hotKeyDescription() -> String {
        "\(modifierDescription(hotKeyModifiers))\(keyDescription(hotKeyCode))"
    }

    private func modifierDescription(_ modifiers: UInt32) -> String {
        var description = ""
        if modifiers & UInt32(controlKey) != 0 {
            description += "⌃"
        }
        if modifiers & UInt32(optionKey) != 0 {
            description += "⌥"
        }
        if modifiers & UInt32(shiftKey) != 0 {
            description += "⇧"
        }
        if modifiers & UInt32(cmdKey) != 0 {
            description += "⌘"
        }
        return description
    }

    private func keyDescription(_ keyCode: UInt32) -> String {
        let keyNames: [UInt32: String] = [
            UInt32(kVK_Space): "Space",
            UInt32(kVK_Return): "Return",
            UInt32(kVK_Tab): "Tab",
            UInt32(kVK_Delete): "Delete",
            UInt32(kVK_ForwardDelete): "Forward Delete",
            UInt32(kVK_Escape): "Esc",
            UInt32(kVK_LeftArrow): "←",
            UInt32(kVK_RightArrow): "→",
            UInt32(kVK_UpArrow): "↑",
            UInt32(kVK_DownArrow): "↓",
            UInt32(kVK_F1): "F1",
            UInt32(kVK_F2): "F2",
            UInt32(kVK_F3): "F3",
            UInt32(kVK_F4): "F4",
            UInt32(kVK_F5): "F5",
            UInt32(kVK_F6): "F6",
            UInt32(kVK_F7): "F7",
            UInt32(kVK_F8): "F8",
            UInt32(kVK_F9): "F9",
            UInt32(kVK_F10): "F10",
            UInt32(kVK_F11): "F11",
            UInt32(kVK_F12): "F12",
            UInt32(kVK_ANSI_A): "A",
            UInt32(kVK_ANSI_B): "B",
            UInt32(kVK_ANSI_C): "C",
            UInt32(kVK_ANSI_D): "D",
            UInt32(kVK_ANSI_E): "E",
            UInt32(kVK_ANSI_F): "F",
            UInt32(kVK_ANSI_G): "G",
            UInt32(kVK_ANSI_H): "H",
            UInt32(kVK_ANSI_I): "I",
            UInt32(kVK_ANSI_J): "J",
            UInt32(kVK_ANSI_K): "K",
            UInt32(kVK_ANSI_L): "L",
            UInt32(kVK_ANSI_M): "M",
            UInt32(kVK_ANSI_N): "N",
            UInt32(kVK_ANSI_O): "O",
            UInt32(kVK_ANSI_P): "P",
            UInt32(kVK_ANSI_Q): "Q",
            UInt32(kVK_ANSI_R): "R",
            UInt32(kVK_ANSI_S): "S",
            UInt32(kVK_ANSI_T): "T",
            UInt32(kVK_ANSI_U): "U",
            UInt32(kVK_ANSI_V): "V",
            UInt32(kVK_ANSI_W): "W",
            UInt32(kVK_ANSI_X): "X",
            UInt32(kVK_ANSI_Y): "Y",
            UInt32(kVK_ANSI_Z): "Z",
            UInt32(kVK_ANSI_0): "0",
            UInt32(kVK_ANSI_1): "1",
            UInt32(kVK_ANSI_2): "2",
            UInt32(kVK_ANSI_3): "3",
            UInt32(kVK_ANSI_4): "4",
            UInt32(kVK_ANSI_5): "5",
            UInt32(kVK_ANSI_6): "6",
            UInt32(kVK_ANSI_7): "7",
            UInt32(kVK_ANSI_8): "8",
            UInt32(kVK_ANSI_9): "9"
        ]
        return keyNames[keyCode] ?? "Key \(keyCode)"
    }

    private func unregisterHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func fileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Screenshot \(formatter.string(from: Date())).png"
    }
}

private func writeSelfTestResult(_ message: String, to resultURL: URL?) {
    guard let resultURL else { return }
    try? message.write(to: resultURL, atomically: true, encoding: .utf8)
}

private func commandLineSelfTestResultURL() -> URL? {
    guard let index = CommandLine.arguments.firstIndex(of: "--self-test-result"),
          CommandLine.arguments.indices.contains(index + 1) else {
        return nil
    }
    return URL(fileURLWithPath: CommandLine.arguments[index + 1])
}

private func hasScreenCaptureAccessForSelfTest() -> Bool {
    CGPreflightScreenCaptureAccess()
}

private final class SyncScreenCaptureBox: @unchecked Sendable {
    var result: Result<CGImage, Error>?
}

private func screenCaptureKitDisplayImage(
    displayID: CGDirectDisplayID,
    sourceRect: CGRect?,
    width: Int,
    height: Int
) -> Result<CGImage, Error> {
    let box = SyncScreenCaptureBox()
    let semaphore = DispatchSemaphore(value: 0)

    Task.detached {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw CaptureFailure(message: "self-test missing-display \(displayID)")
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.showsCursor = false
            configuration.width = max(1, width)
            configuration.height = max(1, height)
            if let sourceRect {
                configuration.sourceRect = sourceRect
            }

            box.result = .success(try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration))
        } catch {
            box.result = .failure(error)
        }
        semaphore.signal()
    }

    while semaphore.wait(timeout: .now() + 0.05) == .timedOut {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }

    return box.result ?? .failure(CaptureFailure(message: "self-test capture timed out"))
}

private func performCoordinateSelfTest(resultURL: URL?, includeContentCapture: Bool = true) {
    var lines: [String] = []
    let tolerance: CGFloat = 0.5
    let screenCaptureAccess = hasScreenCaptureAccessForSelfTest()
    writeSelfTestResult("running coordinate-self-test", to: resultURL)
    lines.append("screen-capture-access=\(screenCaptureAccess)")

    guard !NSScreen.screens.isEmpty else {
        writeSelfTestResult("failure no-screens", to: resultURL)
        return
    }

    for screen in NSScreen.screens {
        guard let displayID = screen.displayID else {
            writeSelfTestResult("failure missing-display-id \(screen.frame)", to: resultURL)
            return
        }

        let displayBounds = CGDisplayBounds(displayID)
        lines.append("screen id=\(displayID) appkit=\(screen.frame) quartz=\(displayBounds) scale=\(screen.backingScaleFactor)")

        let sizes = [
            CGSize(width: min(240, screen.frame.width / 3), height: min(180, screen.frame.height / 3)),
            CGSize(width: min(64, screen.frame.width / 4), height: min(64, screen.frame.height / 4))
        ]
        let origins = [
            CGPoint(x: screen.frame.minX + 8, y: screen.frame.minY + 8),
            CGPoint(x: screen.frame.midX - sizes[0].width / 2, y: screen.frame.midY - sizes[0].height / 2),
            CGPoint(x: screen.frame.maxX - sizes[1].width - 8, y: screen.frame.maxY - sizes[1].height - 8)
        ]

        for (index, origin) in origins.enumerated() {
            let size = sizes[min(index, sizes.count - 1)]
            let appKitRect = CGRect(origin: origin, size: size)

            let alignedAppKitRect = ScreenCoordinates.pixelAlignedAppKitRect(appKitRect)
            guard let quartzRect = ScreenCoordinates.quartzRect(fromAppKitRect: alignedAppKitRect),
                  let sourceRect = ScreenCoordinates.screenCaptureSourceRect(fromAppKitRect: alignedAppKitRect),
                  let roundTripRect = ScreenCoordinates.appKitRect(fromQuartzRect: quartzRect) else {
                writeSelfTestResult("failure conversion-nil \(appKitRect)", to: resultURL)
                return
            }

            let delta = max(
                abs(alignedAppKitRect.minX - roundTripRect.minX),
                abs(alignedAppKitRect.minY - roundTripRect.minY),
                abs(alignedAppKitRect.width - roundTripRect.width),
                abs(alignedAppKitRect.height - roundTripRect.height)
            )
            lines.append("rect \(appKitRect) aligned=\(alignedAppKitRect) quartz=\(quartzRect) roundTrip=\(roundTripRect) delta=\(delta)")

            if delta > tolerance {
                writeSelfTestResult("failure coordinate-roundtrip \(lines.joined(separator: "\n"))", to: resultURL)
                return
            }

            guard includeContentCapture,
                  screenCaptureAccess else {
                continue
            }

            let expectedWidth = alignedAppKitRect.width * screen.backingScaleFactor
            let expectedHeight = alignedAppKitRect.height * screen.backingScaleFactor
            let captureResult = screenCaptureKitDisplayImage(
                displayID: displayID,
                sourceRect: sourceRect,
                width: Int(expectedWidth.rounded()),
                height: Int(expectedHeight.rounded())
            )
            let image: CGImage
            switch captureResult {
            case .success(let capturedImage):
                image = capturedImage
            case .failure(let error):
                lines.append("capture-error \(error.localizedDescription)")
                writeSelfTestResult("failure capture-nil \(lines.joined(separator: "\n"))", to: resultURL)
                return
            }

            let imageDelta = max(
                abs(CGFloat(image.width) - expectedWidth),
                abs(CGFloat(image.height) - expectedHeight)
            )
            lines.append("capture source=\(sourceRect) image=\(image.width)x\(image.height) expected=\(expectedWidth)x\(expectedHeight) delta=\(imageDelta)")

            if imageDelta > screen.backingScaleFactor {
                writeSelfTestResult("failure capture-size \(lines.joined(separator: "\n"))", to: resultURL)
                return
            }
        }
    }

    guard includeContentCapture else {
        writeSelfTestResult("success coordinate-roundtrip\n\(lines.joined(separator: "\n"))", to: resultURL)
        return
    }

    guard screenCaptureAccess else {
        writeSelfTestResult("failure missing-permission\n\(lines.joined(separator: "\n"))", to: resultURL)
        return
    }

    guard runSelectionContentSelfTest(lines: &lines) else {
        writeSelfTestResult("failure selection-content \(lines.joined(separator: "\n"))", to: resultURL)
        return
    }

    writeSelfTestResult("success coordinate-roundtrip\n\(lines.joined(separator: "\n"))", to: resultURL)
}

private func runSelectionContentSelfTest(lines: inout [String]) -> Bool {
    guard let screen = NSScreen.main ?? NSScreen.screens.first else {
        lines.append("content-test missing-screen")
        return false
    }

    let windowSize = CGSize(width: 160, height: 120)
    let windowFrame = CGRect(
        x: screen.frame.midX - windowSize.width / 2,
        y: screen.frame.midY - windowSize.height / 2,
        width: windowSize.width,
        height: windowSize.height
    )
    let window = NSWindow(
        contentRect: windowFrame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.contentView = CoordinateSelfTestView(frame: CGRect(origin: .zero, size: windowSize))
    window.backgroundColor = .black
    window.isOpaque = true
    window.level = .floating
    window.orderFrontRegardless()
    window.displayIfNeeded()

    RunLoop.current.run(until: Date().addingTimeInterval(0.25))

    defer {
        window.orderOut(nil)
        window.close()
    }

    let selectionRect = CGRect(
        x: windowFrame.minX + 20,
        y: windowFrame.maxY - 42,
        width: 36,
        height: 28
    )

    let alignedSelectionRect = ScreenCoordinates.pixelAlignedAppKitRect(selectionRect)
    guard let displayID = screen.displayID,
          let quartzRect = ScreenCoordinates.quartzRect(fromAppKitRect: alignedSelectionRect),
          let sourceRect = ScreenCoordinates.screenCaptureSourceRect(fromAppKitRect: alignedSelectionRect) else {
        lines.append("content-test capture-nil selection=\(selectionRect) aligned=\(alignedSelectionRect)")
        return false
    }

    let scale = max(screen.backingScaleFactor, 1)
    let captureResult = screenCaptureKitDisplayImage(
        displayID: displayID,
        sourceRect: sourceRect,
        width: Int((alignedSelectionRect.width * scale).rounded()),
        height: Int((alignedSelectionRect.height * scale).rounded())
    )
    let image: CGImage
    switch captureResult {
    case .success(let capturedImage):
        image = capturedImage
    case .failure(let error):
        lines.append("content-test capture-error \(error.localizedDescription) selection=\(selectionRect) aligned=\(alignedSelectionRect)")
        return false
    }

    guard let color = centerPixelRGBA(in: image) else {
        lines.append("content-test missing-pixel image=\(image.width)x\(image.height)")
        return false
    }

    lines.append("content-test selection=\(selectionRect) aligned=\(alignedSelectionRect) quartz=\(quartzRect) image=\(image.width)x\(image.height) centerRGBA=\(color)")
    return color.red > 200 && color.green < 80 && color.blue < 80 && color.alpha > 200
}

private func centerPixelRGBA(in image: CGImage) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8)? {
    guard let data = CFDataCreateMutable(nil, 4),
          let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
        return nil
    }

    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination),
          let bitmap = NSBitmapImageRep(data: data as Data) else {
        return nil
    }

    let x = max(0, min(bitmap.pixelsWide - 1, bitmap.pixelsWide / 2))
    let y = max(0, min(bitmap.pixelsHigh - 1, bitmap.pixelsHigh / 2))
    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
        return nil
    }

    return (
        red: UInt8(max(0, min(255, round(color.redComponent * 255)))),
        green: UInt8(max(0, min(255, round(color.greenComponent * 255)))),
        blue: UInt8(max(0, min(255, round(color.blueComponent * 255)))),
        alpha: UInt8(max(0, min(255, round(color.alphaComponent * 255))))
    )
}

if CommandLine.arguments.contains("--self-test-coordinates"),
   Bundle.main.bundleURL.pathExtension != "app" {
    _ = NSApplication.shared
    performCoordinateSelfTest(resultURL: commandLineSelfTestResultURL(), includeContentCapture: false)
    exit(EXIT_SUCCESS)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
