#!/bin/bash
# 產生 App 圖示（iPhone + Android 共用同一個圖案）：用 FaceView.swift 的 drawIcon() 畫
#   iPhone：ios/XiaoKe/Assets.xcassets/AppIcon.appiconset/icon-1024.png
#   Android：res/mipmap-*/ic_launcher.png（一般圖示）、ic_launcher_fg.png（自適應圖示，圖案縮小留安全區）
set -e
cd "$(dirname "$0")"
T=$(mktemp -d)
cp tools/make_icon.swift "$T/main.swift"
swiftc -o "$T/mkicon" "$T/main.swift" XiaoKe/Config.swift XiaoKe/Almanac.swift XiaoKe/Portal.swift XiaoKe/FaceView.swift
"$T/mkicon" XiaoKe/Assets.xcassets/AppIcon.appiconset/icon-1024.png 1024 1
RES=../res
for d in mdpi:48:108 hdpi:72:162 xhdpi:96:216 xxhdpi:144:324 xxxhdpi:192:432; do
  IFS=: read name legacy adaptive <<< "$d"
  mkdir -p "$RES/mipmap-$name"
  "$T/mkicon" "$RES/mipmap-$name/ic_launcher.png" "$legacy" 1
  "$T/mkicon" "$RES/mipmap-$name/ic_launcher_fg.png" "$adaptive" 0.6
done
rm -rf "$T"
