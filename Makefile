SHELL := /bin/bash
APK   := app/build/outputs/apk/debug/app-debug.apk

export JAVA_HOME ?= /usr/lib/jvm/java-17-openjdk-amd64
export ANDROID_HOME ?= $(HOME)/android-sdk

.PHONY: build test install clean lint

build:
	./gradlew assembleDebug
	@echo "APK: $(APK)"

test:
	./gradlew testDebugUnitTest

install: build
	$(ANDROID_HOME)/platform-tools/adb install -r $(APK)

clean:
	./gradlew clean
