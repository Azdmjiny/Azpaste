APP_NAME := Azpaste
BUILD_DIR := build
APP_DIR := $(BUILD_DIR)/$(APP_NAME).app
MACOS_DIR := $(APP_DIR)/Contents/MacOS
RESOURCES_DIR := $(APP_DIR)/Contents/Resources
BINARY := $(MACOS_DIR)/Azpaste
BUILD_STAMP := $(BUILD_DIR)/.app-built
RESOURCE_FILES := \
	Resources/ToolbarIcons/toolbar-copy-transparent.png \
	Resources/ToolbarIcons/toolbar-save-transparent.png \
	Resources/ToolbarIcons/toolbar-pin-transparent.png
CODE_SIGN_KEYCHAIN := $(abspath .codex/AzpasteSigning.keychain)
CODE_SIGN_KEYCHAIN_PASSWORD ?= azpaste-local-signing-password
CODE_SIGN_IDENTITY ?= AzpasteLocalCodeSigning

.PHONY: app run clean

app: $(BUILD_STAMP)

$(BUILD_STAMP): Sources/Azpaste/main.swift Info.plist Makefile $(RESOURCE_FILES)
	mkdir -p "$(MACOS_DIR)" "$(RESOURCES_DIR)" "$(BUILD_DIR)/ModuleCache"
	rm -rf "$(APP_DIR)/Contents/_CodeSignature"
	swiftc Sources/Azpaste/main.swift \
		-o "$(BINARY)" \
		-target arm64-apple-macos14.0 \
		-module-cache-path "$(BUILD_DIR)/ModuleCache" \
		-framework AppKit \
		-framework ScreenCaptureKit \
		-Xlinker -sectcreate \
		-Xlinker __TEXT \
		-Xlinker __info_plist \
		-Xlinker Info.plist
	cp Info.plist "$(APP_DIR)/Contents/Info.plist"
	rm -rf "$(RESOURCES_DIR)/ToolbarIcons"
	mkdir -p "$(RESOURCES_DIR)/ToolbarIcons"
	cp $(RESOURCE_FILES) "$(RESOURCES_DIR)/ToolbarIcons/"
	printf "APPL????" > "$(APP_DIR)/Contents/PkgInfo"
	if [ -f "$(CODE_SIGN_KEYCHAIN)" ]; then \
		security unlock-keychain -p "$(CODE_SIGN_KEYCHAIN_PASSWORD)" "$(CODE_SIGN_KEYCHAIN)"; \
		CODE_SIGN_CERTIFICATE=$$(security find-identity -v -p codesigning "$(CODE_SIGN_KEYCHAIN)" | awk -v identity="$(CODE_SIGN_IDENTITY)" '$$0 ~ "\"" identity "\"" { print $$2; exit }'); \
		if [ -z "$$CODE_SIGN_CERTIFICATE" ]; then echo "Missing code signing identity: $(CODE_SIGN_IDENTITY)"; exit 1; fi; \
		codesign --force --timestamp=none --keychain "$(CODE_SIGN_KEYCHAIN)" --sign "$$CODE_SIGN_CERTIFICATE" "$(APP_DIR)"; \
	else \
		CODE_SIGN_CERTIFICATE=$$(security find-identity -v -p codesigning | awk -v identity="$(CODE_SIGN_IDENTITY)" '$$0 ~ "\"" identity "\"" { print $$2; exit }'); \
		if [ -z "$$CODE_SIGN_CERTIFICATE" ]; then echo "Missing code signing identity: $(CODE_SIGN_IDENTITY)"; exit 1; fi; \
		codesign --force --timestamp=none --sign "$$CODE_SIGN_CERTIFICATE" "$(APP_DIR)"; \
	fi
	touch "$(BUILD_STAMP)"

run: app
	open -n "$(APP_DIR)"

clean:
	rm -rf "$(BUILD_DIR)"
