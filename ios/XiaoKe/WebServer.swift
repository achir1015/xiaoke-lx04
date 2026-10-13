import Foundation
import Network

/// 極簡內建 web server：手機／電腦連同一個 Wi-Fi，開 http://iPhone的IP:WEB_PORT
/// 就能看到病房助理工作站的所有工具並點擊開啟（首頁左下角顯示的網址）。
/// iOS 限制：App 在前景時才會回應。
final class WebServer {
    private let portal: Portal
    private let q = DispatchQueue(label: "xiaoke.web")
    private var listener: NWListener?

    init(portal: Portal) { self.portal = portal }

    func start() {
        guard listener == nil, let port = NWEndpoint.Port(rawValue: UInt16(Config.WEB_PORT)),
              let l = try? NWListener(using: .tcp, on: port) else { return }
        let body = Data(page().utf8)
        var resp = Data(("HTTP/1.0 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
                         + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n").utf8)
        resp.append(body)
        l.newConnectionHandler = { [q] conn in
            conn.start(queue: q)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { _, _, _, _ in   // 只回同一頁，忽略請求內容
                conn.send(content: resp, completion: .contentProcessed { _ in conn.cancel() })
            }
        }
        l.stateUpdateHandler = { [weak self] st in
            if case .failed = st { self?.q.async { self?.listener?.cancel(); self?.listener = nil } }
        }
        l.start(queue: q)
        listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func page() -> String {
        var h = "<!doctype html><html lang=zh-Hant><head><meta charset=utf-8>"
            + "<meta name=viewport content='width=device-width,initial-scale=1'>"
            + "<title>\(Config.PORTAL_NAME)</title><style>"
            + "body{margin:0;background:#0b1020;color:#e8eef7;font-family:system-ui,'Noto Sans TC',sans-serif;padding:16px}"
            + "h1{font-size:20px;color:#40e8ff;margin:4px 0 16px}"
            + "h2{font-size:15px;color:#ffb020;border-bottom:1px solid #283448;padding-bottom:4px;margin:20px 0 8px}"
            + "a{display:block;background:#0e1626;border:1px solid #283448;border-radius:10px;"
            + "padding:12px 14px;margin:8px 0;color:#e8eef7;text-decoration:none;font-size:16px}"
            + "a:active{background:#16233a}.u{color:#5b7;font-size:12px;word-break:break-all}"
            + "</style></head><body><h1>\(Config.PORTAL_NAME)</h1>"
        if portal.isEmpty {
            h += "<p>工具清單尚未載入。</p>"
        } else {
            for (idx, cat) in portal.cats.enumerated() {
                h += "<h2>\(esc(cat))</h2>"
                for t in portal.filtered(idx) {
                    h += "<a href='\(esc(t.url))' target=_blank>\(esc(t.full))<div class=u>\(esc(t.url))</div></a>"
                }
            }
        }
        return h + "</body></html>"
    }

    private func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "'", with: "&#39;")
    }
}

enum Net {
    /// Wi-Fi（en0）的 IPv4 位址。
    static func wifiIP() -> String? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return nil }
        defer { freeifaddrs(addrs) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  String(cString: ifa.ifa_name) == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }

    /// TCP 連得上就算有。
    static func reachable(_ host: String, _ port: Int, timeout: TimeInterval) async -> Bool {
        guard let p = NWEndpoint.Port(rawValue: UInt16(port)) else { return false }
        return await withCheckedContinuation { cont in
            let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
            let lock = NSLock()
            var done = false
            let finish: (Bool) -> Void = { ok in
                lock.lock()
                let first = !done
                done = true
                lock.unlock()
                guard first else { return }
                conn.cancel()
                cont.resume(returning: ok)
            }
            conn.stateUpdateHandler = { st in
                switch st {
                case .ready: finish(true)
                case .failed, .waiting: finish(false)
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    /// 掃描同網段 /24 找第一台開著 port 的主機。
    static func scan(port: Int, timeout: TimeInterval) async -> String? {
        guard let ip = wifiIP() else { return nil }
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return nil }
        let prefix = parts[0..<3].joined(separator: ".") + "."
        let hosts = (1..<255).map { prefix + String($0) }.filter { $0 != ip }
        for batch in stride(from: 0, to: hosts.count, by: 64) {
            let slice = hosts[batch..<min(batch + 64, hosts.count)]
            let found = await withTaskGroup(of: String?.self) { g -> String? in
                for h in slice { g.addTask { await reachable(h, port, timeout: timeout) ? h : nil } }
                for await r in g { if let r { g.cancelAll(); return r } }
                return nil
            }
            if let found { return found }
        }
        return nil
    }
}
