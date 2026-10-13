# 小柯 iPhone 版（Swift / SwiftUI）

由 Android 版移植，功能相同：語音對話 + 機器人臉、首頁農民曆、病房助理工作站（App 內開網頁 / QR）、內建 web server、Stream Deck（Macro Deck）。
需求：iOS 17 以上、橫向使用。

## 第一次設定（Mac）
1. App Store 安裝 **Xcode**，打開一次同意授權；Xcode → Settings → Accounts 登入 Apple ID。
2. 工具與資產：
   ```bash
   brew install xcodegen
   cd ~/Documents/xiaoke-lx04
   python3 build_portal_assets.py                                    # 產生 assets/（iOS 也用同一份）
   cp ios/XiaoKe/Config.example.swift.txt ios/XiaoKe/Config.swift    # 填入 OPENAI_API_KEY
   cd ios && xcodegen generate                                        # 產生 XiaoKe.xcodeproj
   open XiaoKe.xcodeproj
   ```
3. Xcode 左側點 XiaoKe 專案 → Signing & Capabilities → Team 選你的 Apple ID（Personal Team）。
   若提示 Bundle Identifier 已被使用，把 `com.achir.xiaoke` 改成別的（例如 `com.achir.xiaoke.你的名字`）。

## 裝到 iPhone
1. iPhone 用線接 Mac（第一次要在 iPhone 上按「信任這部電腦」），iPhone 開「設定 → 隱私權與安全性 → 開發者模式」。
2. Xcode 上方選你的 iPhone → 按 ▶︎ Run。
3. 第一次執行：iPhone「設定 → 一般 → VPN 與裝置管理」信任你的開發者憑證。
4. 允許麥克風（必要）、區域網路（web server / Stream Deck 用）。

> 免費 Apple ID 簽的 App **7 天後會失效**，要再接上 Mac 按一次 Run；付費開發者帳號（US$99/年）可用一年，也能上 TestFlight。

## 用指令編譯安裝（不開 Xcode）
```bash
cd ~/Documents/xiaoke-lx04/ios
xattr -cr ../assets XiaoKe      # 專案在 iCloud「文件」裡會帶附加屬性，不清會簽章失敗（detritus not allowed）
xcodebuild -project XiaoKe.xcodeproj -scheme XiaoKe -destination 'platform=iOS,name=吳玉柱 的 iPhone' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/XiaoKe -allowProvisioningUpdates build
xcrun devicectl device install app --device '吳玉柱 的 iPhone' \
  ~/Library/Developer/Xcode/DerivedData/XiaoKe/Build/Products/Debug-iphoneos/XiaoKe.app
```
- 裝好後**在 iPhone 上點圖示開啟**；用 `devicectl ... process launch` 從 Mac 啟動時麥克風只收到靜音。
- 診斷記錄：App 會寫 `Documents/xiaoke.log`，可用
  `xcrun devicectl device copy from --device '吳玉柱 的 iPhone' --domain-type appDataContainer --domain-identifier com.achir.xiaoke --source Documents/xiaoke.log --destination xiaoke.log` 抓回來。
- 需要的環境：Xcode 26.6（Intel Mac 用 Universal 版）＋ iOS 26.5 平台元件（`xcodebuild -downloadPlatform iOS`）。

## OpenAI 專案權限
專案設定（platform.openai.com → Settings → Project → Limits）要允許 `gpt-4o-mini-transcribe`、`gpt-4o-mini-tts`（或 Allow all models）。
語音模型被拒時 App 會自動改用 `tts-1`（聲音較普通、沒有語氣設定）。

## 使用
- 直接說話或點螢幕開始聽；小柯說話時點螢幕可打斷；**長按**顯示資訊並清除對話記憶。
- 右下「病房助理工作站」→ 點工具直接在 App 內開網頁，左上「‹ 返回工作站」返回。
- 左下網址 `http://iPhone的IP:8080`：同 Wi-Fi 的電腦／手機開它就能看到全部工具（**App 要在前景**，iOS 不允許背景伺服器）。
- 螢幕常亮；切到背景會停止聆聽，回到前景自動恢復。

## 唱歌與 MV
- 歌單在 repo 根目錄的 `songs.json`（每首：`name`、`mp3`＝Google 雲端 songs_mp3 的檔案 ID、`mp4`＝songs_mp4 的 MV 檔案 ID）。
  檔案要設成「知道連結的任何人都能檢視」。改完跑 `python3 build_portal_assets.py` 再重新編譯。
- 說「唱首歌／來首歌／換一首」→ 隨機播；說歌名（前 4 個字即可）→ 播那首；「你會唱哪些歌」→ 列歌單；點螢幕停止。
- 說「看 MV」或「看〈歌名〉的 MV」→ 全螢幕播放，左上角有「⏸ 暫停／▶︎ 繼續」「⏹ 停止」。
- 雲端 songs_mv 的 `.xkv` 是 ESP32 版自訂格式（JPEG 幀＋MP3），iPhone 不使用。

## 改工具清單
改 `portal_items.json` → `python3 build_portal_assets.py` → Xcode 重新 Run（Android 與 iOS 共用）。

## 檔案
| 檔案 | 用途 |
|---|---|
| `XiaoKe/XiaoKeApp.swift` | App 入口、畫面組合（臉 + 網頁疊層 + 提示） |
| `XiaoKe/AppModel.swift` | 主流程、觸控、網頁、Stream Deck、前景/背景 |
| `XiaoKe/FaceView.swift` | 首頁 / 機器人 / 工作站選單繪圖（512×300 邏輯座標等比縮放） |
| `XiaoKe/Listener.swift` | 語音偵測（VAD） |
| `XiaoKe/AudioIO.swift` | 麥克風 16kHz 擷取、TTS 24kHz 串流播放 |
| `XiaoKe/OpenAI.swift` | STT / 對話（含 web_search）/ TTS |
| `XiaoKe/Almanac.swift` | 離線農民曆（與 Java 版逐日比對結果相同） |
| `XiaoKe/Portal.swift`、`WebServer.swift` | 工具清單 / QR、內建 web server |
| `project.yml` | XcodeGen 專案設定（`.xcodeproj` 由它產生，不進 git） |
