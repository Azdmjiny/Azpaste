import AppKit
import Carbon
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum CaptureResult {
    case success
    case failure(String)
}

enum CaptureMode {
    case selection
    case window
    case fullScreen
}

final class CaptureOverlayWindow: NSWindow {
    init(mode: CaptureMode, completion: @escaping (CGRect?) -> Void) {
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
    }

    override var canBecomeKey: Bool {
        true
    }
}

final class CaptureOverlayView: NSView {
    private let mode: CaptureMode
    private let completion: (CGRect?) -> Void
    private var dragStart: CGPoint?
    private var dragEnd: CGPoint?

    init(mode: CaptureMode, completion: @escaping (CGRect?) -> Void) {
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
            complete(nil)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = event.locationInWindow
        switch mode {
        case .selection:
            dragStart = point
            dragEnd = point
            needsDisplay = true
        case .window:
            complete(CGRect(origin: globalPoint(from: point), size: .zero))
        case .fullScreen:
            break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .selection else { return }
        dragEnd = event.locationInWindow
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard mode == .selection,
              let dragStart else {
            return
        }

        let rect = normalizedRect(from: dragStart, to: event.locationInWindow)
        if rect.width < 4 || rect.height < 4 {
            complete(nil)
            return
        }

        complete(globalRect(from: rect))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.22).setFill()
        dirtyRect.fill()

        if mode == .window {
            let text = "点击要截取的窗口，按 Esc 取消"
            drawHint(text)
        }

        guard mode == .selection,
              let dragStart,
              let dragEnd else {
            if mode == .selection {
                drawHint("拖拽选择截图区域，按 Esc 取消")
            }
            return
        }

        let rect = normalizedRect(from: dragStart, to: dragEnd)
        NSColor.clear.setFill()
        rect.fill(using: .clear)
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 2
        path.stroke()
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

    private func globalPoint(from point: CGPoint) -> CGPoint {
        guard let window else { return point }
        return CGPoint(x: window.frame.minX + point.x, y: window.frame.minY + point.y)
    }

    private func globalRect(from rect: CGRect) -> CGRect {
        guard let window else { return rect }
        return rect.offsetBy(dx: window.frame.minX, dy: window.frame.minY)
    }

    private func complete(_ rect: CGRect?) {
        let completion = completion
        window?.orderOut(nil)
        completion(rect)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let outputDirectoryKey = "outputDirectory"
    private static let hotKeyEnabledKey = "hotKeyEnabled"
    private static let hotKeyCodeKey = "hotKeyCode"
    private static let hotKeyModifiersKey = "hotKeyModifiers"
    private static let screenCapturePermissionRequestedKey = "screenCapturePermissionRequested"
    private static let hotKeyID = UInt32(1)
    private static let defaultHotKeyCode = UInt32(kVK_ANSI_A)
    private static let defaultHotKeyModifiers = UInt32(controlKey | optionKey | cmdKey)
    private static let hotKeySignature = OSType(
        UInt32(UInt8(ascii: "A")) << 24 |
        UInt32(UInt8(ascii: "Z")) << 16 |
        UInt32(UInt8(ascii: "P")) << 8 |
        UInt32(UInt8(ascii: "S"))
    )

    private var window: NSWindow!
    private var statusItem: NSStatusItem!
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var hotKeyCaptureMonitor: Any?
    private var captureOverlayWindow: CaptureOverlayWindow?
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
            if let savedPath = UserDefaults.standard.string(forKey: Self.outputDirectoryKey),
               !savedPath.isEmpty {
                return URL(fileURLWithPath: savedPath)
            }
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop")
                .appendingPathComponent("Azpaste Screenshots")
        }
        set {
            UserDefaults.standard.set(newValue.path, forKey: Self.outputDirectoryKey)
            updateFolderLabel()
        }
    }
    private var isHotKeyEnabled: Bool {
        get {
            UserDefaults.standard.bool(forKey: Self.hotKeyEnabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.hotKeyEnabledKey)
            hotKeyCheckbox.state = newValue ? .on : .off
            updateHotKeyRegistration()
            updateStatusMenu()
        }
    }
    private var hotKeyCode: UInt32 {
        get {
            let savedCode = UserDefaults.standard.integer(forKey: Self.hotKeyCodeKey)
            return savedCode == 0 ? Self.defaultHotKeyCode : UInt32(savedCode)
        }
        set {
            UserDefaults.standard.set(Int(newValue), forKey: Self.hotKeyCodeKey)
            updateHotKeyControls()
        }
    }
    private var hotKeyModifiers: UInt32 {
        get {
            let savedModifiers = UserDefaults.standard.integer(forKey: Self.hotKeyModifiersKey)
            return savedModifiers == 0 ? Self.defaultHotKeyModifiers : UInt32(savedModifiers)
        }
        set {
            UserDefaults.standard.set(Int(newValue), forKey: Self.hotKeyModifiersKey)
            updateHotKeyControls()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
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

    private func buildWindow() {
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 474))
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let title = NSTextField(labelWithString: "Azpaste 截屏")
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
        window.title = "Azpaste 截屏"
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
        menu.addItem(NSMenuItem(title: "显示窗口", action: #selector(showWindow), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "选区截屏", action: #selector(captureSelection), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "打开录屏权限设置", action: #selector(openScreenCapturePrivacySettings), keyEquivalent: ""))

        let hotKeyItem = NSMenuItem(
            title: isHotKeyEnabled ? "关闭快捷键截图（\(hotKeyDescription())）" : "开启快捷键截图（\(hotKeyDescription())）",
            action: #selector(toggleHotKeyFromMenu),
            keyEquivalent: ""
        )
        hotKeyItem.state = isHotKeyEnabled ? .on : .off
        menu.addItem(hotKeyItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q"))
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
            statusLabel.stringValue = "请在系统设置中允许 Azpaste Screenshot 录制屏幕"
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
        captureOverlayWindow = CaptureOverlayWindow(mode: mode) { [weak self] selection in
            guard let self else { return }
            self.captureOverlayWindow = nil

            guard let selection else {
                self.finishCapture(.failure("已取消截屏"), destination: destination)
                return
            }

            DispatchQueue.global(qos: .userInitiated).async {
                let result: CaptureResult
                switch mode {
                case .selection:
                    result = self.captureScreen(rect: selection, destination: destination)
                case .window:
                    result = self.captureWindowImage(at: selection.origin, destination: destination)
                case .fullScreen:
                    result = self.captureScreen(rect: nil, destination: destination)
                }

                DispatchQueue.main.async {
                    self.finishCapture(result, destination: destination)
                }
            }
        }
        captureOverlayWindow?.makeKeyAndOrderFront(nil)
    }

    private func captureScreen(rect: CGRect?, destination: URL) -> CaptureResult {
        let captureRect = rect ?? NSScreen.main?.frame ?? CGDisplayBounds(CGMainDisplayID())
        guard let displayID = displayID(containing: captureRect),
              let image = CGDisplayCreateImage(displayID) else {
            return .failure("截屏失败，请检查“系统设置 > 隐私与安全性 > 屏幕与系统音频录制”权限")
        }

        guard let rect else {
            return writePNG(image, to: destination)
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

        return writePNG(croppedImage, to: destination)
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
                  ownerName != "Azpaste Screenshot",
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

    private func finishCapture(_ result: CaptureResult, destination: URL) {
        if NSApp.isActive {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        switch result {
        case .success:
            copyImageToPasteboard(destination)
            statusLabel.stringValue = "已保存并复制：\(destination.lastPathComponent)"
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
            UserDefaults.standard.set(false, forKey: Self.screenCapturePermissionRequestedKey)
            return
        }

        statusLabel.stringValue = "首次使用前请允许 Azpaste Screenshot 录制屏幕"
    }

    private func requestScreenCaptureAccessIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.screenCapturePermissionRequestedKey) else { return }

        UserDefaults.standard.set(true, forKey: Self.screenCapturePermissionRequestedKey)
        CGRequestScreenCaptureAccess()
    }

    private func copyImageToPasteboard(_ url: URL) {
        guard let image = NSImage(contentsOf: url) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
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
            UserDefaults.standard.set(false, forKey: Self.hotKeyEnabledKey)
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
