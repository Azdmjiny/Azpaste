# Azpaste Dev

一个轻量的 macOS 截屏小工具。
A screenshot app for macOS.

## 功能

- 选区截屏
- 窗口截屏
- 全屏截屏
- 可以选择截图保存目录，并自动记住
- 默认保存到桌面的 `Azpaste Dev Screenshots` 文件夹
- 截图完成后自动复制到剪贴板
- 可以自定义全局快捷键截图，默认快捷键是 `Control + Option + Command + A`
- 关闭窗口后应用会继续在后台运行，可从菜单栏重新打开或退出

## 构建

```sh
make app
```

生成的应用在：

```text
build/Azpaste Dev.app
```

## 运行

```sh
make run
```

`make run` 会复用已经构建好的应用，并通过 `open -n` 启动开发版实例；只有源码、`Info.plist` 或 `Makefile` 变化后才会重新构建并签名。开发版 bundle id 是 `com.azpaste.dev`，屏幕录制权限和正式版 `com.azpaste` 分开记录。

默认使用 ad-hoc 签名；如果 `build/AzpasteSigning.keychain` 存在，则会优先使用其中的 `AzpasteLocalCodeSigning` 本地签名身份。若你有自己的 Apple 开发者代码签名证书，可以这样构建：

```sh
make app CODE_SIGN_IDENTITY="Developer ID Application: Your Name"
```

第一次截屏时，macOS 可能会要求授予屏幕录制权限。如果截屏失败，请到：

```text
系统设置 > 隐私与安全性 > 屏幕录制
```

给 `Azpaste Dev` 打开权限。
