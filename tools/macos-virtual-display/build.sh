#!/bin/bash
# Build build/VirtualDisplay.app. Accessibility (TCC) keys an app bundle by its
# identifier and signature; a bare swiftc binary's linker-only signature never
# matched. Any rebuild changes the ad-hoc signature, so afterwards run
# `tccutil reset Accessibility com.yuutatsubasa.virtual-display` and allow the
# app again.
set -euo pipefail
cd "$(dirname "$0")"
app=build/VirtualDisplay.app
mkdir -p "$app/Contents/MacOS"
cp Info.plist "$app/Contents/Info.plist"
swiftc -O -import-objc-header CGVirtualDisplay.h main.swift Dashboard.swift Music.swift DesktopVideo.swift RemoteControl.swift -o "$app/Contents/MacOS/virtual-display"
codesign -s - -f "$app"
