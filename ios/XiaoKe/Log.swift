import Foundation

/// 診斷記錄：同時印到主控台並寫進 App 的 Documents/xiaoke.log（devicectl 可以抓回 Mac）。
enum Log {
    private static let q = DispatchQueue(label: "xiaoke.log")
    private static let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("xiaoke.log")
    private static var started = false

    static func w(_ s: String) {
        let line = "\(Date().formatted(.dateTime.hour().minute().second())) \(s)\n"
        print("XK " + s)
        q.async {
            if !started { started = true; try? Data().write(to: url) }   // 每次啟動重新開始
            guard let h = try? FileHandle(forWritingTo: url) else { return }
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        }
    }
}
