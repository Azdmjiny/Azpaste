APP_NAME := Azpaste
BUILD_DIR := build
APP_DIR := $(BUILD_DIR)/$(APP_NAME).app
MACOS_DIR := $(APP_DIR)/Contents/MacOS
RESOURCES_DIR := $(APP_DIR)/Contents/Resources
BINARY := $(MACOS_DIR)/Azpaste
BUILD_STAMP := $(BUILD_DIR)/.app-built
CODE_SIGN_KEYCHAIN := $(abspath $(BUILD_DIR)/AzpasteSigning.keychain)
CODE_SIGN_IDENTITY ?= $(shell if [ -f "$(CODE_SIGN_KEYCHAIN)" ]; then echo AzpasteLocalCodeSigning; else echo -; fi)

.PHONY: app run clean

app: $(BUILD_STAMP)

$(BUILD_STAMP): Sources/Azpaste/main.swift Info.plist Makefile
	mkdir -p "$(MACOS_DIR)" "$(RESOURCES_DIR)" "$(BUILD_DIR)/ModuleCache"
	swiftc Sources/Azpaste/main.swift \
		-o "$(BINARY)" \
		-target arm64-apple-macos13.0 \
		-module-cache-path "$(BUILD_DIR)/ModuleCache" \
		-framework AppKit \
		-Xlinker -sectcreate \
		-Xlinker __TEXT \
		-Xlinker __info_plist \
		-Xlinker Info.plist
	cp Info.plist "$(APP_DIR)/Contents/Info.plist"
	printf "APPL????" > "$(APP_DIR)/Contents/PkgInfo"
	if [ "$(CODE_SIGN_IDENTITY)" = "-" ]; then \
		codesign --force --sign - "$(APP_DIR)"; \
	elif [ -f "$(CODE_SIGN_KEYCHAIN)" ]; then \
		codesign --force --timestamp=none --keychain "$(CODE_SIGN_KEYCHAIN)" --sign "$(CODE_SIGN_IDENTITY)" "$(APP_DIR)"; \
	else \
		codesign --force --timestamp=none --sign "$(CODE_SIGN_IDENTITY)" "$(APP_DIR)"; \
	fi
	touch "$(BUILD_STAMP)"

run: app
	open "$(APP_DIR)"

clean:
	rm -rf "$(BUILD_DIR)"
