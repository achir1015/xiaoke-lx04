import Foundation

/// 語音偵測（VAD）：與 Android 版 MainActivity.loop()/record() 同樣的邏輯，改成逐 frame 的狀態機。
/// 所有狀態都在自己的序列佇列上；回呼一律丟回主執行緒。
final class Listener {
    private enum Phase { case idle, recording, busy, draining }

    private static let FRAME_MS = 30
    private static let PREROLL_FRAMES = 10      // 說話前保留 300ms
    private static let DRAIN_MS = 300           // 回答完丟掉喇叭殘響

    private let q = DispatchQueue(label: "xiaoke.vad")
    private var phase = Phase.idle
    private var noise = 150.0
    private var preroll: [[Int16]] = []
    private var rec: [Int16] = []
    private var manual = false, manualReq = false, webShown = false
    private var thresh = 0.0
    private var speechMs = 0, silenceMs = 0, totalMs = 0, silenceLimit = 0, drainMs = 0
    private var lastActive = Date()
    private var sleepy = false

    // 主執行緒回呼
    var onListening: (() -> Void)?
    var onLevel: ((Float) -> Void)?
    var onSpeech: ((Data) -> Void)?          // 錄到一段話（16kHz 16-bit LE PCM）
    var onTooShort: ((Bool) -> Void)?        // 參數：是否為手動（點螢幕）
    var onSleepy: ((Bool) -> Void)?

    func feed(_ f: [Int16]) { q.async { self.process(f) } }
    func requestListen() { q.async { self.manualReq = true; self.lastActive = Date() } }
    func touched() { q.async { self.lastActive = Date() } }
    func setWebShown(_ b: Bool) { q.async { self.webShown = b } }
    /// 處理完一段話（含播放）後呼叫。
    func finishedHandling() { q.async { self.startDrain(); self.lastActive = Date() } }
    func reset() { q.async { self.phase = .idle; self.preroll.removeAll(); self.rec.removeAll() } }

    private func process(_ f: [Int16]) {
        let rms = Listener.rms(f)
        switch phase {
        case .busy:
            return
        case .draining:
            drainMs += Listener.FRAME_MS
            if drainMs >= Listener.DRAIN_MS { phase = .idle }
        case .idle:
            let loud = Config.VOICE_ACTIVATION && !webShown && rms > max(Config.VAD_MIN_RMS, noise * Config.VAD_RATIO)
            if !loud && !manualReq {
                noise = noise * 0.97 + rms * 0.03
                preroll.append(f)
                if preroll.count > Listener.PREROLL_FRAMES { preroll.removeFirst() }
                updateIdle()
                return
            }
            manual = manualReq
            manualReq = false
            rec = preroll.flatMap { $0 } + f
            preroll.removeAll()
            thresh = max(Config.VAD_MIN_RMS, noise * Config.VAD_RATIO) * 0.6
            speechMs = manual ? 0 : Listener.FRAME_MS
            silenceMs = 0
            totalMs = 0
            silenceLimit = Config.VAD_SILENCE_MS + (manual ? 600 : 0)
            phase = .recording
            sleepy = false
            DispatchQueue.main.async { self.onListening?() }
        case .recording:
            rec.append(contentsOf: f)
            let lv = Float(min(1.0, rms / 3000.0))
            DispatchQueue.main.async { self.onLevel?(lv) }
            totalMs += Listener.FRAME_MS
            if rms > thresh { speechMs += Listener.FRAME_MS; silenceMs = 0 } else { silenceMs += Listener.FRAME_MS }
            let timeUp = totalMs >= Config.MAX_RECORD_SEC * 1000
            // 手動模式一開始給 4 秒時間開口
            if !timeUp && manual && speechMs == 0 && totalMs < 4000 { return }
            if !timeUp && silenceMs < silenceLimit { return }

            let wasManual = manual
            if speechMs < Config.VAD_MIN_SPEECH_MS {
                rec.removeAll()
                startDrain()
                DispatchQueue.main.async { self.onTooShort?(wasManual) }
                return
            }
            let pcm = rec.withUnsafeBufferPointer { Data(buffer: $0) }   // iPhone 是 little-endian
            rec.removeAll()
            phase = .busy
            DispatchQueue.main.async { self.onSpeech?(pcm) }
        }
    }

    private func startDrain() {
        phase = .draining
        drainMs = 0
        preroll.removeAll()
    }

    private func updateIdle() {
        let s = Date().timeIntervalSince(lastActive) > Double(Config.SLEEPY_AFTER_SEC)
        if s != sleepy {
            sleepy = s
            DispatchQueue.main.async { self.onSleepy?(s) }
        }
    }

    private static func rms(_ b: [Int16]) -> Double {
        var s = 0.0
        for v in b { let d = Double(v); s += d * d }
        return (s / Double(max(1, b.count))).squareRoot()
    }
}
