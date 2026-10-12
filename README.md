# 小柯 for 小米小愛觸屏音箱 LX04

把小米小愛觸屏音箱（LX04，MediaTek、Android 8.1、800×480 觸控螢幕）改成 OpenAI 語音聊天機器人「小柯」。
對話流程與 ESP32 版小柯相同：語音偵測 → `gpt-4o-mini-transcribe` → Responses API（`gpt-4o-mini` + web_search）→ `gpt-4o-mini-tts`（串流 PCM 播放）。

## 功能
- 直接說話就開始聽（音量 VAD），或點一下螢幕說話
- 說話時點螢幕可打斷；長按顯示狀態並清除對話記憶
- 大眼睛表情（happy / love / surprise / sad / angry / wink / shy）＋字幕
- 可上網查天氣、新聞；開機自動啟動

## 為什麼要先改機
原廠系統沒有開發者選項／ADB，也不能裝第三方 App（USB 只露出一個空的 MTP 裝置）。
必須先讓音箱能用 ADB，才能安裝小柯。

## 步驟

### 1. 工具（筆電）
| 工具 | 用途 | 來源 |
|---|---|---|
| mtkclient | BROM 模式備份／解鎖／寫入分區 | https://github.com/bkerler/mtkclient |
| UsbDk | Windows 上 mtkclient 需要的 USB 驅動 | https://github.com/daynix/UsbDk/releases |
| Android platform-tools | adb | https://developer.android.com/tools/releases/platform-tools |
| JDK 17、Android build-tools 34 + platforms/android-34 | 編譯 APK | Android Studio 或 cmdline-tools |

### 2. 完整備份（一定要先做）
1. 音箱拔電。
2. **按住音量＋**，同時插上 USB 線到筆電，進入 BROM 模式後放開。
3. 執行：
   ```
   python mtk.py rl E:\小米觸控音箱\backup --noreconnect
   ```
   會把所有分區（preloader、boot、system、userdata…）讀到 `backup`。

### 3. 開啟 ADB
- 解鎖 bootloader：`python mtk.py da seccfg unlock --noreconnect`
- 修改 boot.img 的 ramdisk（`ro.adb.secure=0`、`ro.debuggable=1`、`persist.sys.usb.config=mtp,adb`），用 `python mtk.py w boot boot_adb.img` 寫回。
- 出問題時用 `python mtk.py wl E:\小米觸控音箱\backup` 還原原廠。

（另有社群「官改」韌體 SP5.5 可直接刷，但檔案來自論壇網盤，來源無法驗證，不建議。）

### 4. 編譯與安裝小柯
1. `src/com/achir/xiaoke/Config.example.java.txt` 複製成 `Config.java`，填入 OpenAI 金鑰（已 gitignore）。
2. 建立 `local.properties`：
   ```
   sdk.dir=C:\\Users\\<你>\\AppData\\Local\\Android\\Sdk
   jdk.dir=C:\\Program Files\\Microsoft\\jdk-17...
   ```
3. `python build.py install`
4. 若麥克風被小愛同學佔用：`adb shell pm list packages | findstr xiaomi` 找出語音服務後 `adb shell pm disable-user <套件名>`。

## 參數
在 `Config.java` 調整：模型、聲音、VAD 靈敏度（`VAD_MIN_RMS`、`VAD_RATIO`）、是否上網搜尋等。
