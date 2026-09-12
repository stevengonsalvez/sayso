SHELL := /bin/bash
APK   := app/build/outputs/apk/debug/app-debug.apk

UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
  export JAVA_HOME ?= $(shell /usr/libexec/java_home -v 17 2>/dev/null || echo /opt/homebrew/opt/openjdk@17)
  export ANDROID_HOME ?= $(HOME)/Library/Android/sdk
else
  export JAVA_HOME ?= /usr/lib/jvm/java-17-openjdk-amd64
  export ANDROID_HOME ?= $(HOME)/android-sdk
endif

RELEASE_UNSIGNED := app/build/outputs/apk/release/app-release-unsigned.apk
RELEASE_SIGNED   := app/build/outputs/apk/release/sayso-release-signed.apk
APKSIGNER        := $(shell find $(ANDROID_HOME)/build-tools -name apksigner 2>/dev/null | sort -V | tail -n 1)

.PHONY: build test release install install-release clean lint

build:
	./gradlew assembleDebug
	@echo "APK: $(APK)"

test:
	./gradlew testDebugUnitTest

release:
	./gradlew assembleRelease
	@if [ -f "$(HOME)/.android/debug.keystore" ] && [ -n "$(APKSIGNER)" ]; then \
		PATH="$(JAVA_HOME)/bin:$$PATH" $(APKSIGNER) sign --ks $(HOME)/.android/debug.keystore --ks-pass pass:android --ks-key-alias androiddebugkey --key-pass pass:android --out $(RELEASE_SIGNED) $(RELEASE_UNSIGNED); \
		echo "Signed Release APK: $(RELEASE_SIGNED)"; \
	else \
		echo "Release APK (unsigned): $(RELEASE_UNSIGNED)"; \
	fi

install: build
	$(ANDROID_HOME)/platform-tools/adb install -r $(APK)

install-release: release
	$(ANDROID_HOME)/platform-tools/adb install -r $(RELEASE_SIGNED)

clean:
	./gradlew clean
