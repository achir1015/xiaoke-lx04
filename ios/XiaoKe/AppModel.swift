import AVFoundation
import SwiftUI
import WebKit

/// 主流程：麥克風 → 語音偵測 → STT → 對話 → TTS，加上工作站網頁、Stream Deck、內建 web server。
@MainActor
final class AppModel: ObservableObject {
    let face = FaceModel()
    let renderer = FaceRenderer()
    let web = WebController()

    @Published var webShown = false
    @Published var webBarTitle = "‹ 返回工作站"
    @Published var webBarAlpha = 1.0
    @Published var toast: String?

    private let ai = OpenAI()
    private let audio = AudioIO()
    private let listener = Listener()
    private let portal = Portal()
    private lazy var server = WebServer(portal: portal)
    private var chipTimer: Timer?
    private var deckBusy = false
    private var deckUrl: String?
    private var toastTask: Task<Void, Never>?

    init() {
        face.status = "嗨！我是\(Config.ROBOT_NAME)，有什麼想聊的嗎？"
        portal.load()
        face.portal = portal
        face.onOpenTool = { [weak self] t in self?.openTool(t.url, back: "‹ 返回工作站") }   // 點工具 → 直接在螢幕上開網頁
        face.onDeck = { [weak self] in self?.openDeck() }                                   // Stream Deck（Macro Deck 網頁用戶端）
        web.onFail = { [weak self] url in self?.webFailed(url) }

        let l = listener
        audio.onFrame = { l.feed($0) }
        listener.onListening = { [weak self] in
            Log.w("listening")
            guard let self else { return }
            self.face.state = .listening
            self.face.setEmotion("happy")
        }
        listener.onLevel = { [weak self] in self?.face.level = $0 }
        listener.onSleepy = { [weak self] sleepy in
            guard let self else { return }
            if sleepy && self.face.state == .idle { self.face.state = .sleepy }
            if !sleepy && self.face.state == .sleepy { self.face.state = .idle }
        }
        listener.onTooShort = { [weak self] manual in
            guard let self else { return }
            if manual { self.face.status = "沒聽到聲音耶，再說一次？" }
            self.face.state = .idle
        }
        listener.onSpeech = { [weak self] pcm in
            guard let self else { return }
            Task {
                await self.handleSpeech(pcm)
                self.face.state = .idle
                self.listener.finishedHandling()
            }
        }
    }

    // MARK: - 前景 / 背景
    func scene(_ phase: ScenePhase) {
        switch phase {
        case .active:
            UIApplication.shared.isIdleTimerDisabled = true      // 螢幕常亮
            server.start()
            updateChips()
            chipTimer?.invalidate()
            chipTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updateChips() }
            }
            startAudio()
        case .background:
            ai.stopSpeaking()
            audio.stop()
            listener.reset()
            server.stop()
            chipTimer?.invalidate()
        default:
            break
        }
    }

    private func startAudio() {
        if audio.isRunning { return }
        AVAudioApplication.requestRecordPermission { ok in
            Task { @MainActor in
                guard ok else { self.face.status = "需要麥克風權限才能聊天喔（設定 → 小柯 → 麥克風）"; return }
                do {
                    try self.audio.start()
                    Log.w("audio started")
                    self.face.state = .idle
                } catch {
                    Log.w("audio start failed \(error)")
                    self.face.state = .error
                    self.face.status = "打不開麥克風"
                }
            }
        }
    }

    // 上方音量％與左下網址（首頁用）
    private func updateChips() {
        face.volume = audio.volumePercent
        face.ip = Net.wifiIP().map { "http://\($0):\(Config.WEB_PORT)" } ?? ""
    }

    // MARK: - 觸控
    func tap(_ p: CGPoint, in size: CGSize) {
        let q = FaceLayout(size).logical(p)
        listener.touched()
        if face.handleTouch(q.x, q.y) { return }          // 工作站選單吃掉這一下
        switch face.state {
        case .speaking: ai.stopSpeaking()                  // 打斷
        case .thinking, .listening: break
        default: listener.requestListen()                  // 點一下開始聽
        }
    }

    func showInfo() {
        let err = ai.lastError.isEmpty ? "無" : ai.lastError
        ai.clearHistory()
        showToast("\(Config.ROBOT_NAME) v1.0（iPhone）\n模型：\(Config.CHAT_MODEL)\n最近錯誤：\(err)\n（對話記憶已清除）")
    }

    private func showToast(_ s: String) {
        toast = s
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { self.toast = nil }
        }
    }

    // MARK: - 對話
    private func handleSpeech(_ pcm: Data) async {
        face.state = .thinking
        face.subtitle = ""
        face.userText = ""
        Log.w("speech bytes=\(pcm.count)")
        let text = await ai.transcribe(pcm)
        Log.w("stt=\(text) err=\(ai.lastError)")
        if text.isEmpty {
            await showError(ai.lastError.isEmpty ? "沒聽清楚，再說一次好嗎？" : ai.lastError)
            return
        }
        face.userText = text
        if text.lowercased().contains("deck") || text.contains("快捷面板") || text.contains("按鍵面板") {   // 語音開 Stream Deck
            face.state = .idle
            openDeck()
            return
        }
        let reply = await ai.chat(text)
        Log.w("chat=\(reply.prefix(60)) err=\(ai.lastError)")
        if reply.isEmpty {
            await showError("連線失敗：" + ai.lastError)
            return
        }
        face.setEmotion(ai.lastEmotion)
        face.subtitle = reply
        face.state = .speaking
        let ok = await ai.speak(reply, audio: audio)
        Log.w("speak ok=\(ok) err=\(ai.lastError)")
        if !ok { await showError("語音播放失敗：" + ai.lastError) }
    }

    private func showError(_ msg: String) async {
        face.state = .error
        face.setEmotion("sad")
        face.subtitle = msg
        try? await Task.sleep(for: .milliseconds(2500))
        face.setEmotion("happy")
    }

    // MARK: - 網頁
    private func openTool(_ url: String, back: String) {
        guard let u = URL(string: url) else { return }
        ai.stopSpeaking()
        webBarTitle = back
        webBarAlpha = 1
        webShown = true
        listener.setWebShown(true)                         // 網頁開著時不偵測語音
        web.load(u)
    }

    func webBack() {
        if web.view.canGoBack { web.view.goBack() } else { closeWeb() }
    }

    private func closeWeb() {
        webShown = false
        deckUrl = nil
        listener.setWebShown(false)
        web.load(URL(string: "about:blank")!)
    }

    private func webFailed(_ url: URL?) {
        guard let deckUrl, let url, url.absoluteString.hasPrefix(deckUrl) else { return }   // 電腦的 Macro Deck 關了或換 IP
        UserDefaults.standard.removeObject(forKey: "deck")
        closeWeb()
        face.status = "連不上 Macro Deck，再點一次 Stream Deck 重新尋找"
    }

    // MARK: - Stream Deck
    // 電腦裝 Macro Deck 2（免費開源），它內建網頁用戶端 http://電腦IP:8191；這裡全螢幕開它當按鍵面板。
    private func openDeck() {
        if deckBusy { return }
        deckBusy = true
        face.status = "尋找電腦上的 Macro Deck…"
        Task {
            let url = await findDeck()
            deckBusy = false
            guard let url else { face.status = "找不到 Macro Deck（電腦要開 Macro Deck 2，同一個 Wi-Fi）"; return }
            face.status = ""
            UserDefaults.standard.set(url, forKey: "deck")
            deckUrl = url
            openTool(url, back: "‹ 小柯")
            webBarAlpha = 0.55                              // 半透明，少擋按鍵
        }
    }

    /// 依序試：Config 指定 → 上次找到的 → 掃描同網段 /24 的 8191 埠。
    private func findDeck() async -> String? {
        if !Config.MACRO_DECK_URL.isEmpty { return Config.MACRO_DECK_URL }
        if let last = UserDefaults.standard.string(forKey: "deck"), let host = URL(string: last)?.host,
           await Net.reachable(host, Config.MACRO_DECK_PORT, timeout: 0.6) { return last }
        guard let h = await Net.scan(port: Config.MACRO_DECK_PORT, timeout: 0.4) else { return nil }
        return "http://\(h):\(Config.MACRO_DECK_PORT)"
    }
}

/// App 內開工具網頁用的 WKWebView（允許鏡頭／麥克風／定位）。
@MainActor
final class WebController: NSObject, WKNavigationDelegate, WKUIDelegate {
    let view: WKWebView
    var onFail: ((URL?) -> Void)?

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        view = WKWebView(frame: .zero, configuration: cfg)
        view.allowsBackForwardNavigationGestures = true
        view.backgroundColor = .black
        super.init()
        view.navigationDelegate = self
        view.uiDelegate = self
    }

    func load(_ url: URL) { view.load(URLRequest(url: url)) }

    // 允許網頁用鏡頭/麥克風（QR 掃描等）
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.grant)
    }

    // target=_blank 的連結在同一個畫面開
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onFail?((error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? webView.url)
    }
}

struct WebViewRep: UIViewRepresentable {
    let web: WebController
    func makeUIView(context: Context) -> WKWebView { web.view }
    func updateUIView(_ v: WKWebView, context: Context) {}
}
