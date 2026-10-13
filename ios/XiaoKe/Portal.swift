import Foundation
import ImageIO

/// 病房助理工作站的工具清單（來自 assets/tools.json）與 QR 圖（assets/qr/NN.png）。
final class Portal {
    struct Tool {
        let id: Int
        let name, full, cat, url: String
    }

    private(set) var tools: [Tool] = []
    private(set) var cats: [String] = []   // 類別名稱，依出現順序（不含「入口」id 0）
    private var qrCache: [Int: CGImage] = [:]

    func load() {
        tools.removeAll()
        cats.removeAll()
        guard let url = Bundle.main.url(forResource: "tools", withExtension: "json", subdirectory: "assets"),
              let data = try? Data(contentsOf: url),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }
        for o in arr {
            let t = Tool(id: o["id"] as? Int ?? 0, name: o["name"] as? String ?? "", full: o["full"] as? String ?? "",
                         cat: o["cat"] as? String ?? "", url: o["url"] as? String ?? "")
            tools.append(t)
            if t.id != 0 && !t.cat.isEmpty && !cats.contains(t.cat) { cats.append(t.cat) }
        }
    }

    var isEmpty: Bool { tools.isEmpty }

    /// catIndex: -1 = 全部（不含 id 0 入口）；否則為 cats 的索引。
    func filtered(_ catIndex: Int) -> [Tool] {
        tools.filter { t in
            t.id != 0 && (catIndex < 0 || catIndex >= cats.count || t.cat == cats[catIndex])
        }
    }

    func qr(_ id: Int) -> CGImage? {
        if let b = qrCache[id] { return b }
        guard let url = Bundle.main.url(forResource: String(format: "%02d", id), withExtension: "png", subdirectory: "assets/qr"),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        qrCache[id] = img
        return img
    }
}
