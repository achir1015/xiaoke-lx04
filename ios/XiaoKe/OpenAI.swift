import Foundation

/// STT → Responses API（含 web_search）→ TTS，與 Android 版 OpenAI.java 同一套流程。
@MainActor
final class OpenAI {
    private static let HOST = "https://api.openai.com"

    var lastError = ""
    var lastEmotion = "happy"
    var lastSearched = false

    private var history: [(role: String, content: String)] = []
    private var stopFlag = false
    private weak var audio: AudioIO?

    // ---------- 語音轉文字 ----------
    func transcribe(_ pcm16k: Data) async -> String {
        let boundary = "----xiaoke\(Int(Date().timeIntervalSince1970 * 1000))"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("model", Config.STT_MODEL)
        field("language", "zh")
        field("prompt", "以下是台灣繁體中文的日常對話。")
        body.append(("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\n"
                     + "Content-Type: audio/wav\r\n\r\n").data(using: .utf8)!)
        body.append(OpenAI.wavHeader(pcm16k.count, 16000))
        body.append(pcm16k)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = request("/v1/audio/transcriptions", timeout: 30)
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        do {
            guard let json = try await send(req) else { return "" }
            return ((json["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            lastError = "STT \(error.localizedDescription)"
            return ""
        }
    }

    // ---------- 對話 ----------
    func chat(_ userText: String) async -> String {
        var doc: [String: Any] = [
            "model": Config.CHAT_MODEL,
            "max_output_tokens": Config.CHAT_MAX_TOKENS,
            "instructions": systemPrompt(),
        ]
        if Config.ENABLE_WEB_SEARCH {
            doc["tools"] = [[
                "type": "web_search",
                "search_context_size": "low",
                "user_location": ["type": "approximate", "country": "TW", "city": Config.SEARCH_CITY],
            ]]
        }
        var input: [[String: String]] = history.map { ["role": $0.role, "content": $0.content] }
        input.append(["role": "user", "content": userText])
        doc["input"] = input

        var req = request("/v1/responses", timeout: 45)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: doc)
            guard let json = try await send(req) else { return "" }

            // output 可能是 [web_search_call, message]，取 message 的文字
            var reply = ""
            lastSearched = false
            for o in (json["output"] as? [[String: Any]]) ?? [] {
                let type = o["type"] as? String
                if type == "web_search_call" { lastSearched = true }
                if type == "message" {
                    for c in (o["content"] as? [[String: Any]]) ?? [] { reply += (c["text"] as? String) ?? "" }
                }
            }
            let text = parseEmotion(OpenAI.cleanup(reply))
            pushHistory("user", userText)
            pushHistory("assistant", text)
            return text
        } catch {
            lastError = "Chat \(error.localizedDescription)"
            return ""
        }
    }

    func clearHistory() { history.removeAll() }

    // ---------- 文字轉語音（串流播放） ----------
    /// 邊下載邊播放；回傳 false 表示失敗。可用 stopSpeaking() 打斷。
    func speak(_ text: String, audio: AudioIO) async -> Bool {
        if text.isEmpty { return false }
        stopFlag = false
        self.audio = audio
        do {
            // 主要模型被拒（403/404，例如專案權限還沒生效）時，改用 tts-1 再試一次
            var (bytes, code) = try await speechRequest(text, model: Config.TTS_MODEL, instructions: Config.TTS_INSTRUCTIONS)
            if (code == 403 || code == 404) && Config.TTS_MODEL != "tts-1" {
                Log.w("tts \(Config.TTS_MODEL) \(code) -> fallback tts-1")
                (bytes, code) = try await speechRequest(text, model: "tts-1", instructions: nil)
            }
            if code != 200 {
                var d = Data()
                for try await b in bytes { d.append(b); if d.count >= 4000 { break } }
                lastError = OpenAI.errorText("speech", code, d)
                return false
            }
            if stopFlag { return true }
            audio.beginPlayback()
            var chunk = Data()
            chunk.reserveCapacity(9600)
            var written = 0
            for try await b in bytes {
                if stopFlag { break }
                chunk.append(b)
                if chunk.count >= 9600 {        // 200ms 一段，偶數長度
                    audio.enqueue(chunk)
                    written += chunk.count
                    chunk.removeAll(keepingCapacity: true)
                }
            }
            if !stopFlag {
                if !chunk.isEmpty { audio.enqueue(chunk); written += chunk.count }
                // 等緩衝播完
                await audio.waitUntilPlayed(timeout: 3 + Double(written / 2) / AudioIO.TTS_RATE)
            }
            return true
        } catch {
            if stopFlag { return true }
            lastError = "TTS \(error.localizedDescription)"
            return false
        }
    }

    private func speechRequest(_ text: String, model: String, instructions: String?) async throws -> (URLSession.AsyncBytes, Int) {
        var req = request("/v1/audio/speech", timeout: 30)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["model": model, "voice": Config.TTS_VOICE, "input": text, "response_format": "pcm"]
        if let instructions { body["instructions"] = instructions }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        return (bytes, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    func stopSpeaking() {
        stopFlag = true
        audio?.stopPlayback()
    }

    // ---------- 內部 ----------
    private func systemPrompt() -> String {
        let tz = TimeZone(identifier: "Asia/Taipei") ?? .current
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_TW")
        f.timeZone = tz
        f.dateFormat = "yyyy年M月d日 EEEE HH:mm"
        let now = Date()
        var p = "你是一台可愛的 AI 語音機器人，名字叫「\(Config.ROBOT_NAME)」，個性活潑、貼心又有點俏皮。"
            + "你住在一支 iPhone 裡。"
            + "一律使用台灣繁體中文回答，口語化、簡短（100 字以內），因為回答會用語音播放，"
            + "不要使用 Markdown、條列符號、表情符號或網址。"
            + "你沒有鏡頭，看不到東西；被要求看東西時，請可愛地說明你只能用聽的。"
        if Config.ENABLE_WEB_SEARCH {
            p += "遇到天氣、新聞、股價、比賽結果等需要即時資訊的問題，請先上網搜尋，再用口語簡短摘要重點，"
                + "不要唸出網址或來源網站名稱；沒指定地點時以\(Config.SEARCH_CITY_ZH)為準。"
        }
        p += "語音辨識偶爾會聽錯字，請依上下文推測使用者的意思。"
            + "你的創意開發者是吳玉柱先生，他與 Claude AI 共同開發了你；"
            + "被問到是誰做的、開發者、作者或設計者時，要熱情地介紹吳玉柱先生，"
            + "並說有任何意見可以寫信到 achir1015@gmail.com。"
            + "每次回答的最開頭，加上一個代表你當下心情的標籤，只能是以下其中一個："
            + "[happy] [love] [surprise] [sad] [angry] [wink] [shy]，標籤後面直接接回答內容。"
            + "現在時間：\(f.string(from: now))。"
        let alm = Almanac.aiText(now, tz)
        if !alm.isEmpty {
            p += alm + "被問到今天農曆、宜忌、生肖、節氣等農民曆問題時，用上面的資料口語簡短回答，不用上網查。"
        }
        return p
    }

    private func parseEmotion(_ t: String) -> String {
        lastEmotion = "happy"
        var s = t
        if let r = s.range(of: #"^\s*\[(\w+)\]\s*"#, options: .regularExpression) {
            lastEmotion = s[r].trimmingCharacters(in: CharacterSet(charactersIn: "[] \n\t")).lowercased()
            s.removeSubrange(r)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanup(_ t: String) -> String {
        var s = t.replacingOccurrences(of: #"\(\[[^\]]*\]\([^)]*\)\)"#, with: "", options: .regularExpression)   // ([來源](網址))
        s = s.replacingOccurrences(of: #"\[([^\]]*)\]\(https?://[^)]*\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        return s.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "#", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func pushHistory(_ role: String, _ text: String) {
        history.append((role, text))
        while history.count > Config.MAX_HISTORY_MSGS { history.removeFirst() }
    }

    private func request(_ path: String, timeout: TimeInterval) -> URLRequest {
        var r = URLRequest(url: URL(string: OpenAI.HOST + path)!, timeoutInterval: timeout)
        r.httpMethod = "POST"
        r.setValue("Bearer \(Config.OPENAI_API_KEY)", forHTTPHeaderField: "Authorization")
        return r
    }

    /// 送出並解析 JSON；非 200 時記錄 lastError 並回傳 nil。
    private func send(_ req: URLRequest) async throws -> [String: Any]? {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code != 200 {
            lastError = OpenAI.errorText(req.url?.lastPathComponent ?? "", code, data)
            return nil
        }
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// 把 OpenAI 的錯誤 JSON 轉成畫面上看得懂的一句話。
    static func errorText(_ api: String, _ code: Int, _ data: Data) -> String {
        let err = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? [String: Any]
        let msg = err?["message"] as? String ?? String(decoding: data.prefix(160), as: UTF8.self)
        let ecode = err?["code"] as? String ?? ""
        if ecode == "model_not_found", let r = msg.range(of: #"model `[^`]+`"#, options: .regularExpression) {
            let model = msg[r].replacingOccurrences(of: "model ", with: "").replacingOccurrences(of: "`", with: "")
            return "OpenAI 專案沒有開放模型 \(model)，請到 platform.openai.com 專案設定的 Limits 開放"
        }
        switch code {
        case 401: return "OpenAI 金鑰無效（401），請檢查 Config.swift 的金鑰"
        case 429: return "OpenAI 額度不足或太頻繁（429）：\(msg.prefix(80))"
        default: return "\(api) \(code)：\(msg.prefix(120))"
        }
    }

    static func wavHeader(_ dataLen: Int, _ rate: Int) -> Data {
        var h = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; h.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; h.append(Data(bytes: &x, count: 2)) }
        h.append("RIFF".data(using: .ascii)!); u32(36 + dataLen); h.append("WAVE".data(using: .ascii)!)
        h.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1)
        u32(rate); u32(rate * 2); u16(2); u16(16)
        h.append("data".data(using: .ascii)!); u32(dataLen)
        return h
    }
}
