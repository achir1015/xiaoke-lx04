#!/bin/bash
# 產生 App 圖示：用 FaceView.swift 的 drawIcon() 畫 1024x1024 PNG 到 Assets.xcassets
set -e
cd "$(dirname "$0")"
T=$(mktemp -d)
cp tools/make_icon.swift "$T/main.swift"
swiftc -o "$T/mkicon" "$T/main.swift" XiaoKe/Config.swift XiaoKe/Almanac.swift XiaoKe/Portal.swift XiaoKe/FaceView.swift
"$T/mkicon" XiaoKe/Assets.xcassets/AppIcon.appiconset/icon-1024.png
rm -rf "$T"
