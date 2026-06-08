# Azpaste 项目说明

## 注
每次完整的完成一个命令后，如果对该改动的说明对未来的项目维护有帮助，请在此文件中简要添加对此改动的说明

## 项目概览

Azpaste 是一个轻量的 macOS 截屏应用。项目使用 Swift 编写，直接基于 AppKit 构建桌面窗口和菜单栏交互，使用 ScreenCaptureKit 执行截图，并使用 Carbon 注册全局快捷键。

应用以菜单栏常驻模式运行：启动后会自动显示主窗口，但不会出现在 Dock 或 Cmd-Tab 中；关闭主窗口后进程继续运行，并保留右上角菜单栏入口。用户可以通过菜单栏重新显示窗口，或使用 `Cmd+Q` / 菜单栏“退出”真正退出应用。

应用当前支持：

- 选区截屏
- 窗口截屏
- 全屏截屏
- 将截图保存为 PNG 文件
- 截图完成后自动复制图片到系统剪贴板
- 选区截图后可选择复制、保存或创建悬浮贴图
- 自定义全局快捷键触发选区截屏
- 关闭主窗口后继续在后台运行，并可从菜单栏重新打开或退出

默认截图目录是 `~/Desktop/Azpaste Screenshots`。用户选择的保存目录、快捷键启用状态、快捷键键码和修饰键会保存在 `UserDefaults` 中。

## 目录结构

```text
.
├── Sources/
│   └── Azpaste/
│       └── main.swift
├── Resources/
│   ├── app.png
│   └── ToolbarIcons/
│       ├── toolbar-copy.png
│       ├── toolbar-save.png
│       └── toolbar-pin.png
├── Scripts/
│   └── make_icns.swift
├── Info.plist
├── Makefile
├── README.md
├── AGENTS.md
├── LICENSE
├── .gitignore
└── build/
```

主要文件说明：

- `Sources/Azpaste/main.swift`：应用的全部 Swift 源码，包含窗口 UI、菜单栏、截屏流程、快捷键、权限提示、保存目录、悬浮贴图和自测参数逻辑。
- `Resources/app.png`：应用图标源图，构建时会由 `Scripts/make_icns.swift` 转为 `Azpaste.icns` 并写入 `.app` 资源目录。
- `Resources/ToolbarIcons/`：选区截图工具栏使用的复制、保存和贴图图标，构建时会复制到 `.app` 的 `Contents/Resources/ToolbarIcons/`。
- `Scripts/make_icns.swift`：构建辅助脚本，用系统 Swift/AppKit 从 `Resources/app.png` 生成 macOS `.icns` 应用图标，并按缩放后的原图矩形做圆角裁剪。
- `Makefile`：项目的构建入口，直接调用 `swiftc` 编译应用并完成 `.app` 打包和代码签名。
- `Info.plist`：macOS 应用包信息，定义 bundle id、可执行文件名、版本、最低系统版本等元数据。
- `README.md`：面向用户的简介、构建运行说明和屏幕录制权限提示。
- `.gitignore`：忽略 `build/` 和 `.DS_Store`。
- `build/`：本地构建输出目录，不应提交到仓库。

## 构建与运行

项目没有 Swift Package、Xcode 工程或外部依赖清单，构建由 `Makefile` 驱动。

常用命令：

```sh
make app
```

构建 macOS 应用包，产物路径为：

```text
build/Azpaste.app
```

```sh
make run
```

构建并启动应用。`make run` 依赖 `app` 目标，只有 `Sources/Azpaste/main.swift`、`Info.plist`、`Makefile` 或工具栏图标资源更新后才会重新构建。

```sh
make clean
```

删除整个 `build/` 目录。

编译命令的关键点：

- 使用 `swiftc` 直接编译 `Sources/Azpaste/main.swift`。
- 输出可执行文件为 `build/Azpaste.app/Contents/MacOS/Azpaste`。
- 目标平台为 `arm64-apple-macos14.0`，`Info.plist` 中最低系统版本也是 macOS 14.0。
- 链接 `AppKit` 和 `ScreenCaptureKit` framework。
- 通过 linker 的 `-sectcreate __TEXT __info_plist Info.plist` 将 `Info.plist` 写入可执行文件相关段。
- 同时复制 `Info.plist` 到应用包的 `Contents/Info.plist`。
- 同时复制 `Resources/ToolbarIcons/` 中的工具栏图标到应用包资源目录。
- 同时将 `Resources/app.png` 转换为 `Contents/Resources/Azpaste.icns`，`Info.plist` 通过 `CFBundleIconFile` 将其声明为应用图标。

## 签名策略

`Makefile` 会在构建完成后对 `.app` 进行代码签名。

默认行为：

- 默认使用固定的本地签名身份 `AzpasteLocalCodeSigning`，不会回退到 ad-hoc 签名。
- 如果存在 `.codex/AzpasteSigning.keychain`，优先从这个 keychain 查找 `AzpasteLocalCodeSigning`。
- 如果不存在 `.codex/AzpasteSigning.keychain`，从系统可用 keychain 查找 `AzpasteLocalCodeSigning`。
- 如果找不到 `AzpasteLocalCodeSigning`，构建会在签名步骤失败。
- 签名 keychain 不放在 `build/` 下，因为 `make clean` 会删除整个 `build/` 目录，导致后续 `make app` 找不到签名身份。
- 不要在每次 `make app` 时新建签名 keychain、证书或私钥；应该复用同一个 `.codex/AzpasteSigning.keychain` 和同一个 `AzpasteLocalCodeSigning` 身份。
- 如果每次 `make app` 都生成新的签名文件/证书，即使 bundle id 仍然是 `com.azpaste`，证书指纹也会变化，macOS TCC 可能会把它视为新的应用代码身份，屏幕录制权限大概率需要重新授权。
- 如果需要使用自己的 Apple 开发者证书，可以在构建时传入 `CODE_SIGN_IDENTITY`：

```sh
make app CODE_SIGN_IDENTITY="Developer ID Application: Your Name"
```

macOS 会按应用的代码身份记录屏幕录制权限。普通源码修改后重新 `make app`，只要继续复用同一个签名身份，通常不需要重新授权；更换 bundle id、签名证书、证书指纹或运行另一个 `.app` 副本时，可能需要重新授予屏幕录制权限。

### 本地签名创建经验

如果需要为当前项目重新创建稳定可用的本地签名，不要只生成一个自签名的叶子 Code Signing 证书后直接导入项目 keychain。那种证书可能能被 `security find-identity` 列出，但 `codesign --verify --strict` 仍可能报 `CSSMERR_TP_NOT_TRUSTED`，签名详情里也可能显示 `Authority=(unavailable)`。

这次验证通过的做法是：

1. 在 `.codex/AzpasteSigning.keychain` 中保存私钥和签名身份。
2. 创建一个本地 Root CA，例如 `AzpasteLocalCodeSigning Root`。
3. 用这个 Root CA 签发叶子证书 `AzpasteLocalCodeSigning`，叶子证书需要包含 `extendedKeyUsage=codeSigning`。
4. 将叶子证书和私钥以 macOS 兼容的 PKCS#12 格式导入 `.codex/AzpasteSigning.keychain`。使用 OpenSSL 3 时要加 `-legacy`，否则 `security import` 可能报 `MAC verification failed during PKCS12 import`。
5. 对项目 keychain 执行 `security set-key-partition-list -S apple-tool:,apple:,codesign:`，让 `codesign` 可以非交互访问私钥。
6. 将 Root CA 和叶子公钥证书作为用户级 code signing 信任项加入 login keychain。私钥仍只保留在 `.codex/AzpasteSigning.keychain`。
7. 将 `.codex/AzpasteSigning.keychain` 加入当前用户 keychain 搜索列表，保留 login keychain。

签名时优先从 `.codex/AzpasteSigning.keychain` 查找 `AzpasteLocalCodeSigning`，并把查到的 SHA 传给 `codesign`。不要直接把名称 `AzpasteLocalCodeSigning` 传给 `codesign`：如果 login keychain 或其他 keychain 里已经有同名证书，会出现 `ambiguous`，甚至可能签到错误身份。

成功状态应满足：

```sh
make -B app
codesign --verify --verbose=4 --strict build/Azpaste.app
codesign -dvvv build/Azpaste.app
```

严格验证应输出：

```text
build/Azpaste.app: valid on disk
build/Azpaste.app: satisfies its Designated Requirement
```

签名详情中应能看到类似：

```text
Authority=AzpasteLocalCodeSigning
Authority=AzpasteLocalCodeSigning Root
TeamIdentifier=not set
```

`TeamIdentifier=not set` 对本地自建代码签名身份是正常的。关键是不要出现 ad-hoc 签名，也不要出现 `CSSMERR_TP_NOT_TRUSTED`。

## 核心实现

### 应用入口

`main.swift` 文件末尾创建并运行 AppKit 应用：

```swift
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
```

`AppDelegate` 是应用主体，负责启动流程、窗口、菜单栏、截屏、快捷键、权限和退出清理。

启动时会调用 `NSApp.setActivationPolicy(.accessory)`，并由 `Info.plist` 中的 `LSUIElement = true` 声明为菜单栏/agent 类型应用，因此运行后不显示 Dock 图标。代码还会构建一个最小 `NSApp.mainMenu`，用于保证主窗口聚焦时 `Cmd+Q` 可以退出应用。

### 截屏模式

源码中通过 `CaptureMode` 表示三种截图模式：

- `selection`：选区截屏。
- `window`：窗口截屏。
- `fullScreen`：全屏截屏。

截图结果使用 `CaptureResult` 表示：

- `success`
- `failure(String)`

### 交互覆盖层

`CaptureOverlayWindow` 是无边框透明覆盖窗口，用于覆盖所有屏幕并接收用户交互。它的窗口级别为 `.screenSaver`，并设置了 `canJoinAllSpaces`、`fullScreenAuxiliary`、`stationary`，以便在多空间和全屏场景中作为截图交互层。

`CaptureOverlayView` 负责实际交互：

- 选区模式下，鼠标按下记录起点，拖拽更新终点，松开后进入编辑状态。
- 选区编辑状态支持拖动选区、拖拽八个控制点调整大小、用方向键微调位置，并通过工具栏选择复制、保存或创建悬浮贴图。
- 鼠标靠近窗口或屏幕边缘时会显示可吸附候选区域，单击可快速选中。
- 窗口模式下，点击位置会转换为全局坐标点，用于查找被点击的窗口。
- 按 `Esc` 会取消交互。
- 绘制半透明遮罩、提示文字、选区边框、尺寸标签、控制点和选区工具栏。

### 截图流程

截图入口包括：

- `captureSelection()`
- `captureWindow()`
- `captureFullScreen()`

这些入口都会调用 `runCapture(mode:description:)`。

主要流程：

1. 使用 `CGPreflightScreenCaptureAccess()` 检查屏幕录制权限。
2. 权限缺失时更新状态文字，必要时调用 `CGRequestScreenCaptureAccess()` 请求权限。
3. 创建输出目录。
4. 根据当前时间生成 PNG 文件名，格式为 `Screenshot yyyy-MM-dd HH.mm.ss.png`。
5. 选区和窗口截图会先显示覆盖层，再在后台线程执行截图。
6. 全屏截图直接在后台线程调用截图逻辑。
7. 全屏和窗口截图成功后保存 PNG，并通过 `NSPasteboard` 写入剪贴板。
8. 选区截图成功后按用户在工具栏选择的动作复制到剪贴板、保存 PNG 或创建悬浮贴图。

### 全屏与选区截图

`captureScreenImage(rect:)` / `captureScreen(rect:destination:)` 使用 ScreenCaptureKit 的 `SCScreenshotManager.captureImage` 获取显示器图像。

如果传入 `rect`：

- 先通过选区中心点找到包含该区域的显示器。
- 通过 `ScreenCoordinates` 将 AppKit 坐标转换为 ScreenCaptureKit 使用的 Quartz 坐标。
- 将转换后的矩形作为 `SCStreamConfiguration.sourceRect`。
- 根据屏幕 backing scale 设置输出宽高。

如果没有传入 `rect`，则保存当前显示器整张截图。

### 窗口截图

`captureWindowImage(at:destination:)` 先用点击位置查找 ScreenCaptureKit 的 `SCWindow`，再用 `SCScreenshotManager.captureImage` 截取该窗口。

窗口查找逻辑在 `screenCaptureWindow(at:)` 中：

- 使用 `SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)` 获取屏幕上的窗口。
- 排除 owner name 为 `Azpaste` 的自身窗口。
- 根据窗口 bounds 是否包含点击点来确定目标窗口。

### 悬浮贴图

`FloatingPinWindow` 是无边框透明悬浮窗口，用于显示选区截图生成的贴图：

- 创建时按主屏幕可见区域自动缩放到最多约 `72%`，避免贴图过大。
- 窗口级别为 `.floating`，并设置 `canJoinAllSpaces` 和 `fullScreenAuxiliary`。
- 支持拖动移动、双击关闭、按 `Esc` 关闭。
- 支持在四个角拖拽等比调整大小；四条边不触发缩放，仍按普通区域拖动窗口。
- 支持触控板双指捏合围绕贴图中心等比放大或缩小。

### 保存与剪贴板

`writePNG(_:to:)` 使用 `CGImageDestinationCreateWithURL` 和 `UTType.png.identifier` 写入 PNG 文件。保存失败时会尽量删除不完整文件。

`copyImageToPasteboard(_:)` 使用 `NSImage(contentsOf:)` 读取已保存的 PNG，并写入 `NSPasteboard.general`。

### 主窗口与菜单栏

应用启动后会自动创建并显示主窗口，但由于 `LSUIElement = true` 和 `.accessory` 激活策略，应用不会显示在 Dock 或 Cmd-Tab 中。

`buildWindow()` 创建主窗口，包含：

- 标题和说明文字
- 选区截屏、窗口截屏、全屏截屏、打开保存目录按钮
- 选择保存目录按钮
- 打开录屏权限设置按钮
- 快捷键启用复选框
- 快捷键设置按钮
- 状态文字和当前保存目录

`buildStatusItem()` 创建菜单栏项目，标题为 `截屏`。

菜单栏菜单包含：

- 显示窗口
- 选区截屏
- 打开录屏权限设置
- 开启或关闭快捷键截图
- 退出

关闭主窗口不会退出应用，`applicationShouldTerminateAfterLastWindowClosed` 返回 `false`。

退出行为由两个入口提供：

- 主菜单中的 `Cmd+Q`，通过最小 `NSApp.mainMenu` 绑定到 `quitApp()`。
- 菜单栏“截屏”菜单中的“退出”项，同样调用 `quitApp()`。

### 全局快捷键

全局快捷键使用 Carbon API 实现：

- `InstallEventHandler` 安装热键事件处理器。
- `RegisterEventHotKey` 注册快捷键。
- `UnregisterEventHotKey` 取消注册。

默认快捷键是：

```text
Control + Option + Command + A
```

对应 Carbon 修饰键为 `controlKey | optionKey | cmdKey`，默认键码为 `kVK_ANSI_A`。

用户可以通过主窗口的快捷键设置按钮重新录入快捷键。录入时要求至少包含 `Command`、`Control`、`Option` 或 `Shift` 中的一个修饰键；按 `Esc` 取消录入。

快捷键触发后当前行为是执行选区截屏。

### 自测参数

`AppDelegate` 读取了几个命令行参数，便于自动化或本地验证：

- `--capture-fullscreen-on-launch`：启动后延迟触发全屏截图。
- `--quit-after-capture`：截图流程结束后退出应用。
- `--self-test-result <path>`：将关键状态写入指定文件，例如 `launching-capture`、`capture-started`、`success <path>`、`missing-permission` 或 `failure <message>`。
- `--self-test-coordinates`：执行坐标转换自测。直接从源码可执行文件启动时只做坐标 round-trip；在 `.app` 正常启动路径中会由 `AppDelegate` 运行包含 ScreenCaptureKit 内容捕获的坐标自测。
- `--self-test-floating-pin-resize`：创建测试悬浮贴图窗口，验证内容视图成为 first responder、接收 indirect touch，并验证中心缩放保持窗口中心和宽高比。

这些参数没有在 README 中详细展开，但源码已经支持。

## 用户数据与默认行为

`UserDefaults` 键：

- `outputDirectory`：截图保存目录。
- `hotKeyEnabled`：是否启用全局快捷键。
- `hotKeyCode`：快捷键键码。
- `hotKeyModifiers`：快捷键修饰键。
- `screenCapturePermissionRequested`：是否已经请求过屏幕录制权限。

如果没有保存过目录，应用默认使用：

```text
~/Desktop/Azpaste Screenshots
```

如果没有保存过快捷键，应用默认使用：

```text
Control + Option + Command + A
```

## 权限与限制

应用依赖 macOS 屏幕录制权限。首次截屏或权限缺失时，应用会提示用户到系统设置中允许 `Azpaste`（`com.azpaste`）录制屏幕，并调用系统 API 请求权限。

权限设置入口：

```text
系统设置 > 隐私与安全性 > 屏幕录制
```

代码中打开权限设置使用的 URL 是：

```text
x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture
```

当前实现需要注意：

- 目标平台固定为 Apple Silicon 的 macOS 14 或更高版本。
- 选区截图使用选区中心点确定显示器，因此跨显示器选区可能只按其中一个显示器裁剪。
- 窗口截图通过点击点匹配窗口 bounds，且会排除应用自身窗口。
- 窗口截图依赖系统返回的窗口列表和窗口图像能力，某些受保护窗口可能无法正常截取。
- 悬浮贴图支持拖动移动、双击关闭、按 `Esc` 关闭，支持在四个角拖拽等比调整大小，也支持触控板双指捏合围绕中心等比缩放。
- `make run` 会打开 `.app`，这可能触发系统权限弹窗或要求重新授权。

## 维护提示

- 当前项目是单文件 Swift 应用，没有 Swift Package、Xcode 工程、单元测试目标或第三方依赖。
- 如果要新增模块或测试，优先评估是否需要引入 Swift Package 或 Xcode 工程；否则保持 `Makefile` 的简单直接风格。
- 修改 `Sources/Azpaste/main.swift`、`Info.plist`、`Makefile` 或 `Resources/ToolbarIcons/` 中的工具栏图标后，下一次 `make app` 会重新构建并签名。
- 修改菜单栏常驻行为时，需要同时检查 `Info.plist` 的 `LSUIElement`、`main.swift` 中的 `.accessory` 激活策略和最小 `NSApp.mainMenu`，避免应用重新出现在 Dock 中或丢失 `Cmd+Q` 退出能力。
- 不要提交 `build/`、`.DS_Store`、本地 keychain 或其他机器相关产物。
- UI 文案目前主要是中文，新增用户可见文案时应保持一致。
- 涉及屏幕录制权限、签名身份或 bundle id 的变更，可能影响 macOS 权限记录，需要手动回归验证。
- 全局快捷键注册失败通常表示快捷键被系统或其他应用占用，代码会关闭快捷键启用状态并显示提示。
- 悬浮贴图保持无边框窗口，缩放交互由内容视图处理；四角拖拽和触控板双指捏合都会保持截图原始宽高比，双指捏合围绕贴图中心缩放，内容视图需要接收 indirect touch 并成为 first responder 才能可靠收到 `magnify(with:)`，四角拖拽使用自绘对角双向箭头光标提示缩放方向，不新增可见手柄。
- 工具栏图标资源使用 `toolbar-copy.png`、`toolbar-save.png` 和 `toolbar-pin.png`，`Makefile` 和源码中的图标名需要与这些文件名保持一致。
- 应用图标源文件是 `Resources/app.png`，`Makefile` 会调用 `Scripts/make_icns.swift` 生成 `Azpaste.icns`；脚本会沿缩放后的原图矩形裁剪透明圆角，更换应用图标时通常只需要替换这个 PNG 并重新 `make app`。

## 验证建议

文档或代码变更后，建议至少执行：

```sh
make app
```

用于确认项目仍可编译并完成签名。

需要验证运行行为时执行：

```sh
make run
```

手动检查：

- 启动后主窗口能正常打开，但应用不显示在 Dock 或 Cmd-Tab 中。
- 关闭主窗口后应用继续运行，右上角菜单栏仍显示“截屏”入口。
- 从菜单栏点击“显示窗口”可以重新打开主窗口。
- 主窗口聚焦时 `Cmd+Q` 可以退出应用，菜单栏“退出”也可以退出应用。
- 选区截屏可以拖拽选择区域并生成 PNG。
- 窗口截屏可以点击目标窗口并生成 PNG。
- 全屏截屏可以生成 PNG。
- 截图成功后图片会复制到剪贴板。
- 保存目录选择和打开保存目录功能正常。
- 快捷键启用、录入、触发和取消逻辑正常。
- 权限缺失时提示清晰，并能打开系统屏幕录制权限设置。
