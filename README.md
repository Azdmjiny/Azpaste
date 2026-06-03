# Azpaste

一个轻量的 macOS 截屏小工具。
A screenshot app for macOS.

需要 macOS 14 或更高版本。

## 功能

- 选区截屏
- 窗口截屏
- 全屏截屏
- 可以选择截图保存目录，并自动记住
- 默认保存到桌面的 `Azpaste Screenshots` 文件夹
- 截图完成后自动复制到剪贴板
- 可以自定义全局快捷键截图，默认快捷键是 `Control + Option + Command + A`
- 关闭窗口后应用会继续在后台运行，可从菜单栏重新打开或退出

## 构建

```sh
make app
```

生成的应用在：

```text
build/Azpaste.app
```

## 运行

```sh
make run
```

`make run` 会复用已经构建好的应用，并通过 `open -n` 启动实例；只有源码、`Info.plist` 或 `Makefile` 变化后才会重新构建并签名。正式版 bundle id 是 `com.azpaste`。

默认使用固定的本地签名身份 `AzpasteLocalCodeSigning`，不会回退到 ad-hoc 签名。如果 `.codex/AzpasteSigning.keychain` 存在，构建会优先从这个 keychain 查找该身份；否则会从系统可用 keychain 查找。若你有自己的 Apple 开发者代码签名证书，可以这样构建：

```sh
make app CODE_SIGN_IDENTITY="Developer ID Application: Your Name"
```

第一次截屏时，macOS 可能会要求授予屏幕录制权限。如果截屏失败，请到：

```text
系统设置 > 隐私与安全性 > 屏幕录制
```

给 `Azpaste` 打开权限。

截图内容通过 ScreenCaptureKit 捕获；权限缺失或系统保护的窗口可能无法截图。
