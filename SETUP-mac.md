# MacBook Pro 開箱即用設定

在 Mac 上從零到編出 APK 的完整指令。打開「終端機 Terminal」逐段貼上即可。
（Apple Silicon 與 Intel 都適用；路徑都用 `$(brew --prefix)` 自動帶出，不用自己分辨。）

## 1. 基本工具：git 與 Homebrew
```bash
# git（跳出視窗按「安裝」；已有就略過）
xcode-select --install

# Homebrew（已安裝就略過）：https://brew.sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

## 2. JDK 17 + Android SDK + segno
```bash
# JDK 17（Temurin）
brew install --cask temurin@17

# Android 命令列工具（含 sdkmanager）
brew install --cask android-commandlinetools

# 安裝需要的 SDK 套件並同意授權
sdkmanager "platform-tools" "build-tools;34.0.0" "platforms;android-34"
yes | sdkmanager --licenses

# 產 QR 用的 Python 套件
python3 -m pip install --user segno
#   若出現 externally-managed 錯誤，改用虛擬環境：
#   python3 -m venv ~/.venvs/xiaoke && source ~/.venvs/xiaoke/bin/activate && pip install segno
```

## 3. 取得專案
```bash
cd ~/Documents
git clone https://github.com/achir1015/xiaoke-lx04.git
cd xiaoke-lx04
```

## 4. 補兩個本機檔（不在 git 裡）
```bash
# (a) 金鑰：複製範本後填入 OPENAI_API_KEY
cp src/com/achir/xiaoke/Config.example.java.txt src/com/achir/xiaoke/Config.java
open -e src/com/achir/xiaoke/Config.java      # 用文字編輯把 sk-... 換成你的金鑰後存檔

# (b) 本機路徑：自動帶出 SDK / JDK 位置寫進 local.properties
cat > local.properties <<EOF
sdk.dir=$(brew --prefix)/share/android-commandlinetools
jdk.dir=$(/usr/libexec/java_home -v 17)
EOF
cat local.properties                          # 確認兩行路徑都有值
```

## 5. 產生工作站資產 + 編譯
```bash
python3 build_portal_assets.py    # 產生 assets/（QR + tools.json）
python3 build.py                  # 產出 build/xiaoke.apk
```

## 6. 裝到裝置（無線偵錯，不用線）
手機／平板：設定 → 開發人員選項 → 無線偵錯 → 開啟 →「使用配對碼配對裝置」。
```bash
ADB="$(brew --prefix)/share/android-commandlinetools/platform-tools/adb"
"$ADB" pair   手機顯示的配對IP:配對埠      # 貼上 6 位數配對碼
"$ADB" connect 手機顯示的連線IP:連線埠
"$ADB" install -r -g --no-incremental build/xiaoke.apk
"$ADB" shell am start -n com.achir.xiaoke/.MainActivity
```
找不到埠號時：`"$ADB" mdns services` 會列出裝置。
（三星要先關「開發人員選項 → 透過 USB 驗證應用程式」才能側載。）

## 7. 日常同步（Windows ⇄ Mac）
```bash
git pull            # 開始工作前，先拉最新
# ...改東西 / 編譯 / 測試...
git add -A
git -c user.name=achir1015 -c user.email=achir1015@gmail.com commit -m "說明這次改了什麼"
git push
```
> `Config.java`、`local.properties`、簽章 `*.jks` 每台各自保留，不進 git；`assets/` 由 `build_portal_assets.py` 重建。改 `portal_items.json`（工具清單）後記得重跑 `python3 build_portal_assets.py`。
