import AVFoundation

/// 麥克風（轉成 16kHz 16-bit mono、每 30ms 一個 frame）+ TTS 串流播放（24kHz 16-bit mono PCM）。
final class AudioIO {
    static let RATE = 16000.0
    static let FRAME = 480                 // 30ms
    static let TTS_RATE = 24000.0

    /// 每 30ms 呼叫一次（音訊執行緒）。
    var onFrame: (([Int16]) -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let ttsFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: TTS_RATE, channels: 1, interleaved: false)!
    private var pending: [Int16] = []
    private var resamplePos = 0.0
    private var zeroBufs = 0
    private var attached = false
    private var observers: [NSObjectProtocol] = []

    // 播放進度（lock 保護）
    private let lock = NSLock()
    private var scheduled = 0
    private var waiter: CheckedContinuation<Void, Never>?

    var isRunning: Bool { engine.isRunning }

    func start() throws {
        if engine.isRunning { return }
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try s.setActive(true)

        let input = engine.inputNode
        let inFmt = input.outputFormat(forBus: 0)
        guard inFmt.sampleRate > 0, inFmt.channelCount > 0 else { throw NSError(domain: "xiaoke", code: 1) }
        resamplePos = 0
        pending.removeAll()
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inFmt) { [weak self] buf, _ in self?.handleInput(buf) }

        if !attached {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: ttsFormat)
            attached = true
            // 接耳機、來電等造成設定變動 → 重開
            observers.append(NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                    self?.restart()
                })
            observers.append(NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
                    let type = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
                    if type == .ended { self?.restart() }
                })
        }
        engine.prepare()
        try engine.start()
        player.play()
        Log.w("session perm=\(AVAudioApplication.shared.recordPermission.rawValue) muted=\(AVAudioApplication.shared.isInputMuted) inputAvail=\(s.isInputAvailable) in=\(s.currentRoute.inputs.map { $0.portType.rawValue }) out=\(s.currentRoute.outputs.map { $0.portType.rawValue }) gain=\(s.inputGain) fmt=\(engine.inputNode.outputFormat(forBus: 0))")
    }

    func stop() {
        stopPlayback()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func restart() {
        zeroBufs = 0
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
        try? start()
    }

    /// 0–100，系統媒體音量。
    var volumePercent: Int { Int((AVAudioSession.sharedInstance().outputVolume * 100).rounded()) }

    // ---------- 麥克風 ----------
    /// 麥克風 float（通常 48kHz）→ 16kHz Int16：每個輸出樣本取對應區間的平均（簡單低通 + 降頻）。
    private func handleInput(_ buf: AVAudioPCMBuffer) {
        guard let src = buf.floatChannelData?[0], buf.frameLength > 0 else { return }
        let n = Int(buf.frameLength)
        let step = buf.format.sampleRate / AudioIO.RATE
        var raw: Float = 0
        while resamplePos < Double(n) {
            let a = Int(resamplePos), b = min(n, max(a + 1, Int(resamplePos + step)))
            var sum: Float = 0
            for k in a..<b { sum += src[k] }
            let v = sum / Float(b - a)
            raw = max(raw, abs(v))
            pending.append(Int16(max(-32768, min(32767, v * 32767))))
            resamplePos += step
        }
        resamplePos -= Double(n)
        // 看門狗：連續約 3 秒完全無聲（不是安靜，是 0）代表麥克風卡住 → 重開音訊
        zeroBufs = raw == 0 ? zeroBufs + 1 : 0
        if zeroBufs == 30 {
            Log.w("mic silent 3s -> restart")
            DispatchQueue.main.async { [weak self] in self?.restart() }
        }
        var i = 0
        while pending.count - i >= AudioIO.FRAME {
            onFrame?(Array(pending[i..<(i + AudioIO.FRAME)]))
            i += AudioIO.FRAME
        }
        if i > 0 { pending.removeFirst(i) }
    }

    // ---------- 播放 ----------
    func beginPlayback() {
        if !engine.isRunning { try? start() }
        if !player.isPlaying { player.play() }
    }

    /// 排入一段 16-bit little-endian PCM（奇數位元組最後一個會被丟掉）。
    func enqueue(_ pcm: Data) {
        let n = pcm.count / 2
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: ttsFormat, frameCapacity: AVAudioFrameCount(n)),
              let dst = buf.floatChannelData?[0] else { return }
        pcm.withUnsafeBytes { raw in
            for i in 0..<n {
                let v = Int16(bitPattern: UInt16(raw[2 * i]) | (UInt16(raw[2 * i + 1]) << 8))
                dst[i] = Float(v) / 32768
            }
        }
        buf.frameLength = AVAudioFrameCount(n)
        lock.lock(); scheduled += 1; lock.unlock()
        player.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.scheduled -= 1
            let w = self.scheduled <= 0 ? self.takeWaiter() : nil
            self.lock.unlock()
            w?.resume()
        }
    }

    /// 等排入的聲音都播完（或被 stopPlayback 打斷、或逾時）。
    func waitUntilPlayed(timeout: TimeInterval) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if scheduled <= 0 { lock.unlock(); c.resume(); return }
            waiter = c
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                self.lock.lock(); let w = self.takeWaiter(); self.lock.unlock()
                w?.resume()
            }
        }
    }

    func stopPlayback() {
        player.stop()
        lock.lock(); scheduled = 0; let w = takeWaiter(); lock.unlock()
        w?.resume()
    }

    private func takeWaiter() -> CheckedContinuation<Void, Never>? {
        let w = waiter
        waiter = nil
        return w
    }
}
