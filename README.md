# 小柯 for 小米小愛觸屏音箱 LX04（Android 版）

把小米小愛觸屏音箱 LX04（或任何 Android 7.0 以上、橫向 800×480 的裝置）變成 OpenAI 語音聊天機器人「小柯」，並內建「病房助理工作站」。由 ESP32 版 XiaoKe_P4 移植。

GitHub：<https://github.com/achir1015/xiaoke-lx04>

## 功能
- **語音對話**：語音偵測 → `gpt-4o-mini-transcribe`（STT）→ Responses API（`gpt-4o-mini` + web_search，可查天氣／新聞）→ `gpt-4o-mini-tts`（串流 PCM 播放）。直接說話或點螢幕都能開始；說話時點螢幕可打斷。
- **首頁**：上方日期／星期／農曆／24 小時時鐘／音量；左側頭盔機器人（眨眼、想睡、各種表情）；右側**農民曆卡片**。
- **離線農民曆**（`Almanac.java`）：干支、生肖、建除十二神宜忌、沖煞、節氣，全部本機計算，不需上網；也會附給 AI，可直接問「今天宜什麼」「今天農曆幾號」。
- **病房助理工作站**：點首頁右下角標籤 → 工具選單（分類、分頁）→ 點工具**直接在螢幕上開啟網頁操作**（App 內 WebView，可滑可點；已允許鏡頭／定位，QR 產生器、GPS 工具等可用）。工具詳細頁也會顯示 QR 碼讓手機掃描。
- **內建 web server**：同一個 Wi-Fi 下，用手機／電腦瀏覽器開 `http://裝置IP:8080`，就能看到全部工具並點開（首頁左下角會顯示這個網址）。
- 開機自動啟動、螢幕常亮。

## 關於 LX04 本機
LX04 是 MediaTek MT8167、Android 8.1、A/B 分區。原廠系統沒有 ADB、也不能裝第三方 App。
> ⚠️ 嘗試用 mtkclient 改系統分區開 ADB **會造成開機循環**（已用完整備份還原）。因此本專案不走改機路線，改為支援一般 Android 裝置（手機／平板），LX04 若有可行的安裝管道亦可用。

## 編譯（不需要 Android Studio / Gradle）
需求：Python 3.8+、JDK 17、Android SDK（`build-tools;34.0.0`、`platforms;android-34`、`platform-tools`）、`pip install segno`。

1. **金鑰**：把 `src/com/achir/xiaoke/Config.example.java.txt` 複製成 `src/com/achir/xiaoke/Config.java`，填入 `OPENAI_API_KEY`（已列入 `.gitignore`，不會上傳）。
2. **本機路徑**：建立 `local.properties`（已 gitignore）：
   ```properties
   # Windows
   sdk.dir=E:\\小米觸控音箱\\tools\\android-sdk
   jdk.dir=E:\\小米觸控音箱\\tools\\jdk-17.0.20.1+1
   # macOS 範例
   # sdk.dir=/Users/你的帳號/Library/Android/sdk
   # jdk.dir=/Library/Java/JavaVirtualMachines/jdk-17.jdk/Contents/Home
   ```
3. **產生工作站資產**：`python build_portal_assets.py`（讀 `portal_items.json`，用 segno 產生 `assets/qr/NN.png` 與 `assets/tools.json`）。
4. **編譯**：`python build.py` → `build/xiaoke.apk`
   - 流程：aapt2 → javac（`--release 8`）→ d8 → zipalign → apksigner（含 `-A assets` 打包工具資產）。
   - 跨平台：`build.py` 會自動處理 Windows 的 `.exe`/`.bat`，macOS／Linux 同樣可用。
   - 專案路徑含中文時 aapt2 打不開絕對路徑，腳本已改用相對路徑處理。

## 安裝到裝置
1. 裝置開「開發人員選項」→「USB 偵錯」（或「無線偵錯」）。小米機型另需開「USB 安裝」；三星需關「透過 USB 驗證應用程式」才能側載。
2. 連線：
   - USB：接上並允許偵錯。
   - 無線：手機「無線偵錯 → 使用配對碼配對」，電腦 `adb pair 手機IP:配對埠`、輸入配對碼，再 `adb connect 手機IP:連線埠`（可用 `adb mdns services` 找）。
3. 安裝並啟動：
   ```bash
   adb install -r -g --no-incremental build/xiaoke.apk
   adb shell am start -n com.achir.xiaoke/.MainActivity
   ```
   （`-g` 會授予執行權限；麥克風／鏡頭／定位也可用 `adb shell pm grant` 補。）

## 唱歌與 MV（Android / iPhone 共用）
- 歌單在 `songs.json`（Google 雲端 songs_mp3 的 mp3、songs_mp4 的 MV 檔案 ID，檔案需「知道連結的任何人都能檢視」）；`build_portal_assets.py` 會複製到 `assets/`。
- 說「唱首歌／來首歌／換一首」→ 隨機播；說歌名（前 4 個字即可）→ 播那首；「你會唱哪些歌」→ 列歌單；點螢幕停止。
- 說「看 MV」或「看〈歌名〉的 MV」→ 全螢幕播放，左上角「⏸ 暫停／▶︎ 繼續」「⏹ 停止」，點影片出現進度條。

## 修改工具清單
1. 編輯 `portal_items.json`（17 筆：`id 0` 是工作站入口，其餘是各工具；欄位 `name`／`short`／`cat`／`url`）。
2. `python build_portal_assets.py` 重新產生資產。
3. `python build.py` 重編、重裝。

## 跨機器（Windows 筆電 ⇄ MacBook Pro）
同一個 Claude 帳號只是讓你在兩台都能登入；**程式碼、工具鏈、Config.java 不會自動跨機同步**，要靠 git：
```bash
git clone https://github.com/achir1015/xiaoke-lx04.git
cd xiaoke-lx04
cp src/com/achir/xiaoke/Config.example.java.txt src/com/achir/xiaoke/Config.java   # 填金鑰
#   建立 local.properties 指向這台的 SDK/JDK
pip install segno
python build_portal_assets.py && python build.py
```
之後兩台用 `git pull` / `git push` 同步。`Config.java`、`local.properties`、簽章 `*.jks` 每台各自保留（不進 git）。

## 參數（`Config.java`）
模型與聲音（`CHAT_MODEL`／`TTS_VOICE`／`TTS_INSTRUCTIONS`）、是否上網搜尋（`ENABLE_WEB_SEARCH`）、語音偵測靈敏度（`VAD_MIN_RMS`／`VAD_RATIO`／`VAD_SILENCE_MS`，環境吵就調高）、多久沒互動變想睡（`SLEEPY_AFTER_SEC`）、工作站名稱與 web server 埠（`PORTAL_NAME`／`WEB_PORT`）等。

## 檔案結構
| 檔案 | 用途 |
|---|---|
| `src/.../MainActivity.java` | 主流程、觸控、WebView 疊層、啟動 web server |
| `src/.../FaceView.java` | 首頁與工作站選單繪圖（512×300 邏輯座標縮放填滿） |
| `src/.../Almanac.java` | 離線農民曆計算 |
| `src/.../OpenAI.java` | STT / 對話 / TTS |
| `src/.../Portal.java` | 讀 `assets/tools.json` 與 QR 圖 |
| `src/.../WebServer.java` | 內建工具啟動頁 |
| `portal_items.json` | 工具清單來源（改這裡） |
| `build_portal_assets.py` | 產生 `assets/`（QR + tools.json） |
| `build.py` | 無 Gradle 打包 APK |
