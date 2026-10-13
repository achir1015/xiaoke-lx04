import AVFoundation

/// 自創歌曲：清單來自 assets/songs.json（Google 雲端公開分享的 mp3），用 AVPlayer 串流播放。
@MainActor
final class Music {
    struct Song { let name, mp3: String; let mp4: String? }

    private(set) var songs: [Song] = []
    private var player: AVPlayer?
    private var waiter: CheckedContinuation<Bool, Never>?
    private var observers: [NSObjectProtocol] = []
    private var lastIndex = -1

    var isPlaying: Bool { player != nil }

    func load() {
        guard let url = Bundle.main.url(forResource: "songs", withExtension: "json", subdirectory: "assets"),
              let data = try? Data(contentsOf: url),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }
        songs = arr.compactMap { o in
            guard let n = o["name"] as? String, let id = o["mp3"] as? String else { return nil }
            return Song(name: n, mp3: id, mp4: o["mp4"] as? String)
        }
    }

    enum Request { case none, list, play(Song?), mv(Song?) }

    /// 判斷這句話是不是要聽歌：點名歌名 → 那首；「唱歌／放歌」→ 隨機；「有哪些歌」→ 列歌單。
    func parse(_ text: String) -> Request {
        if songs.isEmpty { return .none }
        let t = text.replacingOccurrences(of: " ", with: "")
        let wantsMV = ["MV", "mv", "Mv", "ＭＶ", "影片", "音樂錄影帶"].contains(where: t.contains)
        if let s = match(t) { return wantsMV ? .mv(s) : .play(s) }
        if wantsMV { return .mv(nil) }
        if ["哪些歌", "什麼歌", "歌單", "幾首歌", "會唱什麼"].contains(where: t.contains) { return .list }
        if ["唱歌", "唱首", "唱一首", "唱個", "首歌", "放歌", "放音樂", "播歌", "播放歌", "聽歌", "來首", "再一首", "下一首", "換一首"].contains(where: t.contains) {
            return .play(nil)
        }
        return .none
    }

    /// 歌名比對（容忍語音辨識錯字，例如「花間謠」聽成「花間搖」）：
    /// 句子與歌名的「最長連續相同字數」≥ 2，且佔歌名 ≥ 60%（或連續 ≥ 4 字）才算點到；多首都像時取比例最高的。
    private func match(_ t: String) -> Song? {
        let clean = { (s: String) in Array(s.filter { !"，。、：:,. 　".contains($0) }) }
        let ct = clean(t)
        var best: Song?
        var bestScore = 0.0
        for s in songs {
            let n = clean(s.name)
            if n.isEmpty { continue }
            let l = Music.longestCommon(ct, n)
            if l == n.count { return s }
            let score = Double(l) / Double(n.count)
            if l >= 2 && (score >= 0.6 || l >= 4) && score > bestScore { best = s; bestScore = score }
        }
        return best
    }

    private static func longestCommon(_ a: [Character], _ b: [Character]) -> Int {
        var best = 0
        var prev = [Int](repeating: 0, count: b.count + 1)
        for i in 1...max(1, a.count) where i <= a.count {
            var cur = [Int](repeating: 0, count: b.count + 1)
            for j in 1...b.count where a[i - 1] == b[j - 1] {
                cur[j] = prev[j - 1] + 1
                best = max(best, cur[j])
            }
            prev = cur
        }
        return best
    }

    /// MV 的串流網址（Google 雲端大檔案要加 confirm=t 跳過病毒掃描提示頁）。
    static func mvURL(_ s: Song) -> URL? {
        guard let id = s.mp4 else { return nil }
        return URL(string: "https://drive.usercontent.google.com/download?id=\(id)&export=download&confirm=t")
    }

    func random(withMV: Bool = false) -> Song {
        let pool = withMV ? songs.filter { $0.mp4 != nil } : songs
        if withMV, let s = pool.randomElement() { return s }
        var i = Int.random(in: 0..<songs.count)
        if songs.count > 1 && i == lastIndex { i = (i + 1) % songs.count }
        lastIndex = i
        return songs[i]
    }

    /// 播放到結束（回傳 true）或被 stop()／失敗（回傳 false）。
    func play(_ s: Song) async -> Bool {
        stop()
        guard let url = URL(string: "https://drive.google.com/uc?export=download&id=\(s.mp3)") else { return false }
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        player = p
        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.finish(true) }
            },
            nc.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] n in
                Log.w("song failed \(String(describing: n.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey]))")
                Task { @MainActor in self?.finish(false) }
            },
        ]
        p.play()
        Log.w("song play \(s.name)")
        return await withCheckedContinuation { waiter = $0 }
    }

    func stop() { finish(false) }

    private func finish(_ ok: Bool) {
        player?.pause()
        player = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        let w = waiter
        waiter = nil
        w?.resume(returning: ok)
    }
}
