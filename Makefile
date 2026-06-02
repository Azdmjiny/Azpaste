APP_NAME := Azpaste Dev
BUILD_DIR := build
APP_DIR := $(BUILD_DIR)/$(APP_NAME).app
MACOS_DIR := $(APP_DIR)/Contents/MacOS
RESOURCES_DIR := $(APP_DIR)/Contents/Resources
BINARY := $(MACOS_DIR)/AzpasteDev
BUILD_STAMP := $(BUILD_DIR)/.app-built
CODE_SIGN_KEYCHAIN := $(abspath $(BUILD_DIR)/AzpasteSigning.keychain)
CODE_SIGN_KEYCHAIN_PASSWORD ?= azpaste-local-signing-password
CODE_SIGN_IDENTITY ?= AzpasteLocalCodeSigning

.PHONY: app run clean

app: $(BUILD_STAMP)

$(BUILD_STAMP): Sources/Azpaste/main.swift Info.plist Makefile
	mkdir -p "$(MACOS_DIR)" "$(RESOURCES_DIR)" "$(BUILD_DIR)/ModuleCache"
	rm -rf "$(APP_DIR)/Contents/_CodeSignature"
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
