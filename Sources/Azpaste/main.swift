import AppKit
import Carbon
import Foundation
import ImageIO
import UniformTypeIdentifiers

fileprivate enum AppIdentity {
    static let appName = "Azpaste Dev"
    static let bundleIdentifier = "com.azpaste.dev"
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
        let title: String
        let action: SelectionCaptureAction
        let rect: CGRect
    }

    private static let minSelectionSize: CGFloat = 4
    private static let dragThreshold: CGFloat = 3
    private static let handleHitSize: CGFloat = 8
    private static let snapThreshold: CGFloat = 10
    private static let toolbarHeight: CGFloat = 34
    private static let toolbarPadding: CGFloat = 8

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
                complete(.selection(globalRect(from: selectionRect), action))
                return
            }

            if let selectionRect,
               state == .editing {
                if let handle = resizeHandle(at: point, in: selectionRect) {
                    dragOperation = .resize(handle)
                } else if selectionRect.contains(point) {
                    dragOperation = .move(CGPoint(x: point.x - selectionRect.minX, y: point.y - selectionRect.minY))
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
            drawSelectionFrame(snapCandidateRect, isCandidate: true)
            drawSizeLabel(for: snapCandidateRect)
        }

        guard let selectionRect else {
            if mode == .selection {
                drawHint("拖拽选择截图区域，靠近窗口或屏幕边缘可吸附，按 Esc 取消")
            }
            drawMagnifierIfNeeded()
            return
        }

        drawSelectionFrame(selectionRect, isCandidate: false)
        drawSizeLabel(for: selectionRect)

        if state == .editing {
            drawToolbar(for: selectionRect)
        }

        drawMagnifierIfNeeded()
    }

    private func drawMask() {
        NSColor.black.withAlphaComponent(0.22).setFill()
        if let rect = selectionRect ?? snapCandidateRect {
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
        let titles: [(String, SelectionCaptureAction)] = [
            ("复制到粘贴板", .copy),
            ("保存到本地", .save),
            ("悬浮贴图", .pin)
        ]
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        var x: CGFloat = 0
        var buttons: [ToolbarButton] = []
        let widths = titles.map { title, _ in
            title.size(withAttributes: attributes).width + 22
        }
        let toolbarWidth = widths.reduce(0, +) + CGFloat(widths.count - 1) * 6 + Self.toolbarPadding * 2
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

        x = toolbarRect.minX + Self.toolbarPadding
        for (index, item) in titles.enumerated() {
            let buttonRect = CGRect(x: x, y: toolbarRect.minY + 5, width: widths[index], height: Self.toolbarHeight - 10)
            NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: buttonRect, xRadius: 5, yRadius: 5).fill()
            item.0.draw(in: buttonRect.insetBy(dx: 11, dy: 3), withAttributes: attributes)
            buttons.append(ToolbarButton(title: item.0, action: item.1, rect: buttonRect))
            x += widths[index] + 6
        }
        toolbarButtons = buttons
    }

    private func drawMagnifierIfNeeded() {
        guard mode == .selection,
              let mouseLocation,
              let displayID = displayID(containing: globalPoint(from: mouseLocation)),
              let image = CGDisplayCreateImage(displayID) else {
            return
        }

        let displayBounds = CGDisplayBounds(displayID)
        let scaleX = CGFloat(image.width) / displayBounds.width
        let scaleY = CGFloat(image.height) / displayBounds.height
        let global = globalPoint(from: mouseLocation)
        let sampleSize: CGFloat = 28
        let cropRect = CGRect(
            x: (global.x - displayBounds.minX - sampleSize / 2) * scaleX,
            y: (global.y - displayBounds.minY - sampleSize / 2) * scaleY,
            width: sampleSize * scaleX,
            height: sampleSize * scaleY
        ).integral

        guard let cropped = image.cropping(to: cropRect) else { return }

        let magnifierSize: CGFloat = 116
        let targetRect = placedRect(
            preferred: CGRect(
                x: mouseLocation.x + 18,
                y: mouseLocation.y - magnifierSize - 18,
                width: magnifierSize,
                height: magnifierSize
            ),
            avoiding: selectionRect
        )

        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        let clipPath = NSBezierPath(roundedRect: targetRect, xRadius: 8, yRadius: 8)
        clipPath.addClip()
        context.draw(cropped, in: targetRect)
        context.restoreGState()

        NSColor.white.withAlphaComponent(0.9).setStroke()
        NSBezierPath(roundedRect: targetRect, xRadius: 8, yRadius: 8).stroke()

        let crosshair = NSBezierPath()
        crosshair.move(to: CGPoint(x: targetRect.midX, y: targetRect.minY))
        crosshair.line(to: CGPoint(x: targetRect.midX, y: targetRect.maxY))
        crosshair.move(to: CGPoint(x: targetRect.minX, y: targetRect.midY))
        crosshair.line(to: CGPoint(x: targetRect.maxX, y: targetRect.midY))
        crosshair.lineWidth = 1
        NSColor.systemRed.withAlphaComponent(0.9).setStroke()
        crosshair.stroke()
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
            let rect = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) ?? .zero
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

    private func localRect(fromGlobal rect: CGRect) -> CGRect {
        guard let window else { return rect }
        return rect.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
    }

    private func displayID(containing point: CGPoint) -> CGDirectDisplayID? {
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &displays, &displayCount)

        return displays.first { CGDisplayBounds($0).contains(point) } ?? displays.first
    }

    private func complete(_ result: InteractiveCaptureResult) {
        let completion = self.completion
        window?.orderOut(nil)
        completion(result)
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

final class FloatingPinWindow: NSWindow {
    init(image: CGImage) {
        let imageSize = CGSize(width: image.width, height: image.height)
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 900, height: 700)
        let maxSize = CGSize(width: visibleFrame.width * 0.72, height: visibleFrame.height * 0.72)
        let scale = min(1, maxSize.width / imageSize.width, maxSize.height / imageSize.height)
        let windowSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let frame = CGRect(
            x: visibleFrame.midX - windowSize.width / 2,
            y: visibleFrame.midY - windowSize.height / 2,
            width: windowSize.width,
            height: windowSize.height
        )

        let imageView = DoubleClickImageView(frame: CGRect(origin: .zero, size: windowSize))
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
        imageView.closeHandler = { [weak self] in
            self?.close()
        }
    }

    override var canBecomeKey: Bool {
        true
    }
}

final class DoubleClickImageView: NSImageView {
    var closeHandler: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            closeHandler?()
        } else {
            window?.performDrag(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            closeHandler?()
        } else {
            super.keyDown(with: event)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let outputDirectoryKey = "outputDirectory"
    private static let hotKeyEnabledKey = "hotKeyEnabled"
    private static let hotKeyCodeKey = "hotKeyCode"
    private static let hotKeyModifiersKey = "hotKeyModifiers"
    private static let screenCapturePermissionRequestedKey = "screenCapturePermissionRequested"
    private static let defaultsMigrationKey = "didMigrateDefaultsFromAzpasteScreenshot"
    private static let oldDefaultsSuiteName = "com.azpaste.screenshot"
    private static let hotKeyID = UInt32(1)
    private static let defaultHotKeyCode = UInt32(kVK_ANSI_A)
    private static let defaultHotKeyModifiers = UInt32(controlKey | optionKey | cmdKey)
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
                .appendingPathComponent("Azpaste Dev Screenshots")
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
        guard CGPreflightScreenCaptureAccess() else {
            statusLabel.stringValue = "请在系统设置中允许 \(AppIdentity.appName) 录制屏幕"
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
            DispatchQueue.global(qos: .userInitiated).async {
                self.writeSelfTestResult("capture-started")
                let result = self.captureScreen(rect: nil, destination: destination)
                DispatchQueue.main.async {
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
                DispatchQueue.global(qos: .userInitiated).async {
                    let imageResult = self.captureScreenImage(rect: rect)
                    DispatchQueue.main.async {
                        self.finishSelectionCapture(imageResult, action: action, destination: destination)
                    }
                }
            case .window(let point):
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = self.captureWindowImage(at: point, destination: destination)
                    DispatchQueue.main.async {
                        self.finishCapture(result, destination: destination)
                    }
                }
            }
        }
        captureOverlayWindow?.makeKeyAndOrderFront(nil)
    }

    private func captureScreenImage(rect: CGRect?) -> ImageCaptureResult {
        let captureRect = rect ?? NSScreen.main?.frame ?? CGDisplayBounds(CGMainDisplayID())
        guard let displayID = displayID(containing: captureRect),
              let image = CGDisplayCreateImage(displayID) else {
            return .failure("截屏失败，请检查“系统设置 > 隐私与安全性 > 屏幕与系统音频录制”权限")
        }

        guard let rect else {
            return .success(image)
        }

        let displayBounds = CGDisplayBounds(displayID)
        let scaleX = CGFloat(image.width) / displayBounds.width
        let scaleY = CGFloat(image.height) / displayBounds.height
        let cropRect = CGRect(
            x: (rect.minX - displayBounds.minX) * scaleX,
            y: (rect.minY - displayBounds.minY) * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        ).integral

        guard let croppedImage = image.cropping(to: cropRect) else {
            return .failure("选区截图失败")
        }

        return .success(croppedImage)
    }

    private func captureScreen(rect: CGRect?, destination: URL) -> CaptureResult {
        switch captureScreenImage(rect: rect) {
        case .success(let image):
            return writePNG(image, to: destination)
        case .failure(let message):
            return .failure(message)
        }
    }

    private func displayID(containing rect: CGRect) -> CGDirectDisplayID? {
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &displays, &displayCount)

        let center = CGPoint(x: rect.midX, y: rect.midY)
        return displays.first { CGDisplayBounds($0).contains(center) } ?? displays.first
    }

    private func captureWindowImage(at point: CGPoint, destination: URL) -> CaptureResult {
        guard let windowID = windowID(at: point),
              let image = CGWindowListCreateImage(
                .null,
                .optionIncludingWindow,
                windowID,
                [.bestResolution, .boundsIgnoreFraming]
              ) else {
            return .failure("没有找到可截图的窗口")
        }

        return writePNG(image, to: destination)
    }

    private func windowID(at point: CGPoint) -> CGWindowID? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for info in windowInfo {
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let ownerName = info[kCGWindowOwnerName as String] as? String,
                  !AppIdentity.windowOwnerNamesToIgnore.contains(ownerName),
                  let boundsDictionary = info[kCGWindowBounds as String] as? [String: Any],
                  let windowNumber = info[kCGWindowNumber as String] as? UInt32 else {
                continue
            }

            let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) ?? .zero
            if bounds.contains(point) {
                return CGWindowID(windowNumber)
            }
        }

        return nil
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

    private func updateScreenCapturePermissionStatus() {
        guard !CGPreflightScreenCaptureAccess() else {
            defaults.set(false, forKey: Self.screenCapturePermissionRequestedKey)
            return
        }

        statusLabel.stringValue = "首次使用前请允许 \(AppIdentity.appName) 录制屏幕"
    }

    private func requestScreenCaptureAccessIfNeeded() {
        guard !defaults.bool(forKey: Self.screenCapturePermissionRequestedKey) else { return }

        defaults.set(true, forKey: Self.screenCapturePermissionRequestedKey)
        CGRequestScreenCaptureAccess()
    }

    private func migrateDefaultsIfNeeded() {
        guard !defaults.bool(forKey: Self.defaultsMigrationKey),
              let oldDefaults = UserDefaults(suiteName: Self.oldDefaultsSuiteName) else {
            return
        }

        [
            Self.outputDirectoryKey,
            Self.hotKeyEnabledKey,
            Self.hotKeyCodeKey,
            Self.hotKeyModifiersKey,
            Self.screenCapturePermissionRequestedKey
        ].forEach { key in
            guard defaults.object(forKey: key) == nil,
                  let oldValue = oldDefaults.object(forKey: key) else {
                return
            }
            defaults.set(oldValue, forKey: key)
        }

        defaults.set(true, forKey: Self.defaultsMigrationKey)
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
