import SwiftUI

/// 小柯首頁：上方日期/農曆/時鐘/音量列 + 左側頭盔機器人 + 右側農民曆卡片；回答時改為精簡模式（小機器人 + 字幕）。
/// 版面沿用 Android 版 512x300 邏輯座標，等比例縮放置中（iPhone 比較寬，左右留黑邊）。
final class FaceModel {
    enum State { case idle, listening, thinking, speaking, sleepy, error }

    static let LW: CGFloat = 512, LH: CGFloat = 300

    var state = State.idle
    var emotion = "happy"
    var subtitle = ""
    var userText = ""
    var status = ""
    var ip = ""
    var volume = -1
    var level: Float = 0
    let start = Date()

    // 病房助理工作站
    var portal: Portal?
    var portalMode = false
    var portalCat = -1, portalPage = 0
    var portalSel: Portal.Tool?
    var portalSince = Date()

    var onOpenTool: ((Portal.Tool) -> Void)?
    var onDeck: (() -> Void)?

    func setEmotion(_ e: String?) { emotion = e ?? "happy" }
    func closePortal() { portalMode = false }

    /// 處理觸控（傳入邏輯座標）。回傳 true = 已被工作站選單吃掉，不要去啟動語音。
    func handleTouch(_ x: CGFloat, _ y: CGFloat) -> Bool {
        let LW = FaceModel.LW
        if !portalMode {
            if let p = portal, !p.isEmpty, hit(x, y, 354, 272, 150, 24) {     // 右下角標籤
                portalMode = true; portalCat = -1; portalPage = 0; portalSel = nil
                portalSince = Date()
                return true
            }
            if onDeck != nil && hit(x, y, 246, 272, 100, 24) {             // Stream Deck 標籤
                onDeck?()
                return true
            }
            return false
        }
        guard let portal else { return true }
        portalSince = Date()
        if hit(x, y, 410, 50, 96, 24) { portalMode = false; return true }   // 回主畫面
        if portalSel != nil {
            if hit(x, y, 8, 268, 120, 26) { portalSel = nil }               // 返回清單
            return true
        }
        let n = portal.cats.count + 1
        let w = (LW - 16) / CGFloat(n)
        for i in 0..<n where hit(x, y, 8 + CGFloat(i) * w, 80, w - 4, 24) { portalCat = i - 1; portalPage = 0 }
        let v = portal.filtered(portalCat)
        let pages = max(1, (v.count + 7) / 8)
        if pages > 1 && hit(x, y, 250, 50, 72, 24) && portalPage > 0 { portalPage -= 1 }
        if pages > 1 && hit(x, y, 328, 50, 72, 24) && portalPage < pages - 1 { portalPage += 1 }
        let pg = min(max(portalPage, 0), pages - 1)
        for k in 0..<8 where pg * 8 + k < v.count {
            if hit(x, y, 8 + CGFloat(k % 2) * 250, 110 + CGFloat(k / 2) * 46, 244, 42) {
                let t = v[pg * 8 + k]
                if let open = onOpenTool { open(t) } else { portalSel = t }   // 直接在螢幕上開啟網頁
            }
        }
        return true
    }

    private func hit(_ x: CGFloat, _ y: CGFloat, _ bx: CGFloat, _ by: CGFloat, _ bw: CGFloat, _ bh: CGFloat) -> Bool {
        x >= bx && x < bx + bw && y >= by && y < by + bh
    }
}

/// 邏輯座標 ↔ 螢幕座標。
struct FaceLayout {
    let scale: CGFloat, ox: CGFloat, oy: CGFloat
    init(_ size: CGSize) {
        scale = min(size.width / FaceModel.LW, size.height / FaceModel.LH)
        ox = (size.width - FaceModel.LW * scale) / 2
        oy = (size.height - FaceModel.LH * scale) / 2
    }
    func logical(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - ox) / scale, y: (p.y - oy) / scale) }
}

struct FaceCanvas: View {
    let face: FaceModel
    let renderer: FaceRenderer

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in
            Canvas { ctx, size in renderer.draw(ctx, size: size, face: face, now: tl.date) }
        }
    }
}

final class FaceRenderer {
    private typealias C = UInt32
    private static let BAR_H: CGFloat = 44, LINE_H: CGFloat = 18

    // 配色（對應 XiaoKe_P4 的 C_*）
    private static let C_BG: C = 0xFF000000
    private static let C_WHITE: C = 0xFFFFFFFF
    private static let C_GLOW: C = 0xFF40E8FF
    private static let C_GLOW_DIM: C = 0xFF1E6E87
    private static let C_RED2: C = 0xFFFF4664
    private static let C_PANEL: C = 0xFF0E1626
    private static let C_BAR_LINE: C = 0xFF283448
    private static let C_ORANGE: C = 0xFFFFA600
    private static let C_YELLOW: C = 0xFFFFE000
    private static let C_GRAY: C = 0xFF8A94A2
    private static let C_GREEN: C = 0xFF2FD36A
    private static let C_PINK: C = 0xFFFF6F91
    private static let C_VISOR: C = 0xFF162A42
    private static let C_BLACK: C = 0xFF081018

    // 表情
    private enum Ex { case normal, happy, love, surprise, sad, angry, wink, shy, listen, think, sleepy }

    private var ctx: GraphicsContext!
    private var widthCache: [String: CGFloat] = [:]
    private var wrapCache: [String: [String]] = [:]

    // MARK: - 主繪圖
    func draw(_ context: GraphicsContext, size: CGSize, face f: FaceModel, now date: Date) {
        var c = context
        c.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
        let L = FaceLayout(size)
        c.translateBy(x: L.ox, y: L.oy)
        c.scaleBy(x: L.scale, y: L.scale)
        c.clip(to: Path(CGRect(x: 0, y: 0, width: FaceModel.LW, height: FaceModel.LH)))
        ctx = c

        let LW = FaceModel.LW, LH = FaceModel.LH
        let nowMs = date.timeIntervalSince1970 * 1000
        let t = date.timeIntervalSince(f.start)
        let ex = expression(f)
        let blink = ex != .sleepy && ex != .listen && t.truncatingRemainder(dividingBy: 4.2) < 0.13
        let lx: CGFloat = ex == .think ? CGFloat(sin(t * 3)) * 8 : 0
        let ly: CGFloat = ex == .think ? CGFloat(cos(t * 2.1)) * 4 : 0
        let mouth: CGFloat = f.state == .speaking ? 0.3 + abs(CGFloat(sin(t * 13))) * 0.7 : 0

        if f.portalMode && date.timeIntervalSince(f.portalSince) > Double(Config.PORTAL_TIMEOUT_SEC) { f.portalMode = false }

        let compact = (f.state == .thinking || f.state == .speaking || f.state == .error)
            && (!f.subtitle.isEmpty || !f.userText.isEmpty)

        if f.portalMode, let portal = f.portal {
            drawPortal(f, portal)
            drawTopBar(f, date)
        } else if !compact {
            drawRobot(f, 150, 168, 0.86, ex, lx, ly, blink, mouth, nowMs)
            drawAlmanac(date, 300, 52, 206, 220)
            drawTopBar(f, date)
            let hint = f.state == .listening ? "聆聽中…"
                : f.state == .sleepy ? "想睡…（說話或點我叫醒）"
                : !f.status.isEmpty ? f.status
                : Config.VOICE_ACTIVATION ? "待命中，直接跟我說話" : "點螢幕說話"
            text(clip(hint, 236, 16), 8, 280, 16, f.state == .listening ? Self.C_GREEN : Self.C_GRAY)
            if !f.ip.isEmpty { text(f.ip, 8, 297, 16, Self.C_GLOW_DIM) }
            if f.state == .listening { drawMicBars(f, 206, 293) } else { drawPageDots(208, 291) }
            drawWorkstationLabel()
            if f.onDeck != nil { drawDeckLabel() }
        } else {
            drawRobot(f, 96, 168, 0.6, ex, lx * 0.6, ly * 0.6, blink, mouth, nowMs)
            drawTopBar(f, date)
            let tx: CGFloat = 196, tw = LW - tx - 10
            var y: CGFloat = 66
            if !f.userText.isEmpty {
                let us = wrap("你：" + f.userText, tw, 15)
                for i in 0..<min(2, us.count) { text(us[i], tx, y, 15, Self.C_GRAY); y += Self.LINE_H - 2 }
                y += 6
            }
            let body = f.state == .thinking && f.subtitle.isEmpty ? "思考中…" : f.subtitle
            let color = f.state == .error ? Self.C_RED2 : Self.C_WHITE
            let lines = wrap(body, tw, 17)
            let per = max(1, Int((LH - y) / Self.LINE_H))
            let pages = max(1, (lines.count + per - 1) / per)
            let page = Int(t * 1000 / 4500) % pages
            for i in 0..<per where page * per + i < lines.count {
                text(lines[page * per + i], tx, y + CGFloat(i) * Self.LINE_H, 17, color)
            }
        }
    }

    /// App 圖示：深藍漸層底 + 光暈 + 頭頂小心芽的笑臉小柯 + 雙手捧紅心（ios/make_icon.sh 輸出 1024x1024 PNG）。
    func drawIcon(_ context: GraphicsContext, size: CGSize) {
        var c = context
        let full = Path(CGRect(origin: .zero, size: size))
        c.fill(full, with: .linearGradient(Gradient(colors: [col(0xFF12345A), col(0xFF040A14)]),
                                           startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        c.scaleBy(x: size.width / 300, y: size.height / 300)
        c.fill(Path(ellipseIn: CGRect(x: 10, y: 0, width: 280, height: 280)),
               with: .radialGradient(Gradient(colors: [col(0x6640E8FF), col(0x0040E8FF)]),
                                     center: CGPoint(x: 150, y: 130), startRadius: 0, endRadius: 140))
        ctx = c

        // 小心芽（頭盔頂）
        var stem = Path()
        stem.move(to: CGPoint(x: 150, y: 52))
        stem.addQuadCurve(to: CGPoint(x: 152, y: 26), control: CGPoint(x: 146, y: 40))
        ctx.stroke(stem, with: .color(col(0xFF3FBF5A)), style: StrokeStyle(lineWidth: 5, lineCap: .round))
        leaf(152, 28, -1, 0xFF5FE07A, 0xFF2E9E4A)
        leaf(152, 28, 1, 0xFF7CF08F, 0xFF34A852)

        drawRobot(FaceModel(), 150, 122, 0.8, .happy, 0, 0, false, 0, 0)

        // 紅心 + 捧著它的雙手
        let hx: CGFloat = 150, hy: CGFloat = 244, hr: CGFloat = 30
        glow(8) { $0.fill(self.heartPath(hx, hy, hr), with: .color(self.col(0xCCFF2D55))) }
        ctx.fill(heartPath(hx, hy, hr), with: .linearGradient(Gradient(colors: [col(0xFFFF5A78), col(0xFFD90F3C)]),
                                                             startPoint: CGPoint(x: hx, y: hy - hr), endPoint: CGPoint(x: hx, y: hy + hr)))
        ellipse(hx - 12, hy - 14, 6, 4, 0x99FFFFFF)                // 高光
        for side in [-1.0, 1.0] as [CGFloat] {
            let cx = hx + side * 30, cy = hy + 26
            let rot = CGAffineTransform(translationX: cx, y: cy).rotated(by: side * -0.55)
            let palm = Path(roundedRect: CGRect(x: -34, y: -15, width: 68, height: 30), cornerRadius: 15).applying(rot)
            ctx.fill(palm.applying(CGAffineTransform(translationX: 0, y: 2)), with: .color(col(0xFF808A9A)))
            ctx.fill(palm, with: .linearGradient(Gradient(colors: [col(0xFFFCFDFF), col(0xFFC4CBD6)]),
                                                 startPoint: CGPoint(x: cx, y: cy - 18), endPoint: CGPoint(x: cx, y: cy + 18)))
        }
    }

    private func leaf(_ x: CGFloat, _ y: CGFloat, _ side: CGFloat, _ c1: C, _ c2: C) {
        var p = Path()
        p.move(to: CGPoint(x: x, y: y))
        p.addQuadCurve(to: CGPoint(x: x + side * 30, y: y - 14), control: CGPoint(x: x + side * 10, y: y - 22))
        p.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: x + side * 22, y: y + 4))
        ctx.fill(p, with: .linearGradient(Gradient(colors: [col(c1), col(c2)]),
                                          startPoint: CGPoint(x: x, y: y - 20), endPoint: CGPoint(x: x, y: y + 4)))
    }

    private func heartPath(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: cx, y: cy + r * 0.9))
        p.addCurve(to: CGPoint(x: cx, y: cy - r * 0.3),
                   control1: CGPoint(x: cx - r * 1.3, y: cy - r * 0.1), control2: CGPoint(x: cx - r * 0.7, y: cy - r))
        p.addCurve(to: CGPoint(x: cx, y: cy + r * 0.9),
                   control1: CGPoint(x: cx + r * 0.7, y: cy - r), control2: CGPoint(x: cx + r * 1.3, y: cy - r * 0.1))
        return p
    }

    private func expression(_ f: FaceModel) -> Ex {
        switch f.state {
        case .sleepy: return .sleepy
        case .listening: return .listen
        case .thinking: return .think
        case .error: return .sad
        default:
            switch f.emotion {
            case "love": return .love
            case "surprise": return .surprise
            case "sad": return .sad
            case "angry": return .angry
            case "wink": return .wink
            case "shy": return .shy
            case "happy": return .happy
            default: return .normal
            }
        }
    }

    // MARK: - 上方列
    private func drawTopBar(_ f: FaceModel, _ date: Date) {
        let LW = FaceModel.LW
        let cal = Calendar(identifier: .gregorian)
        let c = cal.dateComponents([.year, .month, .day, .weekday, .hour, .minute, .second], from: date)
        let WD = ["週日", "週一", "週二", "週三", "週四", "週五", "週六"]
        let ds = String(format: "%d/%02d/%02d ", c.year!, c.month!, c.day!) + WD[c.weekday! - 1]
        var lunar = Almanac.lunarString(date)
        if !lunar.isEmpty && !lunar.hasPrefix("閏") { lunar = "農曆" + lunar }
        let time = String(format: "%02d:%02d:%02d", c.hour!, c.minute!, c.second!)

        rect(0, 0, LW, Self.BAR_H, Self.C_BG)
        rect(0, Self.BAR_H - 1, LW, 1, Self.C_BAR_LINE)
        text(ds, 6, 19, 16, Self.C_GLOW)
        text(lunar, 6, 39, 16, Self.C_ORANGE)
        let cw = measure(time, 34, mono: true)
        text(time, (LW - cw) / 2 + 8, 36, 34, Self.C_WHITE, bold: true, mono: true)
        text("音量", 470, 19, 15, Self.C_YELLOW)
        if f.volume >= 0 { text("\(f.volume)%", 470, 39, 15, Self.C_YELLOW) }
        ellipse(458, 13, 4, 4, Self.C_GLOW)
    }

    // MARK: - 農民曆卡片
    private func drawAlmanac(_ date: Date, _ x0: CGFloat, _ y0: CGFloat, _ w: CGFloat, _ h: CGFloat) {
        let a = Almanac.compute(date)
        let card = Path(roundedRect: CGRect(x: x0, y: y0, width: w, height: h), cornerRadius: 8)
        ctx.fill(card, with: .color(col(Self.C_PANEL)))
        ctx.stroke(card, with: .color(col(Self.C_BAR_LINE)), lineWidth: 1)

        let x = x0 + 10, tw = w - 20
        var y = y0 + 22
        text("農民曆", x, y, 16, Self.C_YELLOW)
        if !a.ok {
            text("等待校時…", x, y + 26, 16, Self.C_GRAY)
            return
        }
        let yz = a.yearGZ + "年【" + a.zodiac + "】"
        text(yz, x0 + w - 10 - measure(yz, 16), y, 16, Self.C_ORANGE)
        rect(x, y + 6, tw, 1, Self.C_BAR_LINE)

        y += 26
        text(a.monthGZ + "月　" + a.dayGZ + "日　" + a.jianchu + "日", x, y, 16, Self.C_WHITE)
        y += Self.LINE_H + 2
        text(a.chong + "　煞" + a.sha, x, y, 16, Self.C_GLOW)
        y += Self.LINE_H + 6
        y = drawYiJi("宜", Self.C_GREEN, a.yi, x, y, tw)
        y = drawYiJi("忌", Self.C_RED2, a.ji, x, y, tw)
        if !a.termToday.isEmpty { text("今日節氣：" + a.termToday, x, y + 2, 16, Self.C_ORANGE) }
        else { text("下個節氣：" + a.nextTerm, x, y + 2, 16, Self.C_ORANGE) }
    }

    private func drawYiJi(_ label: String, _ lc: C, _ txt: String, _ x: CGFloat, _ y: CGFloat, _ tw: CGFloat) -> CGFloat {
        rr(x, y - 14, 20, 18, 4, lc)
        text(label, x + 2.5, y, 15, Self.C_BLACK)
        let ls = wrap(txt, tw - 26, 16)
        let n = min(ls.count, 3)
        for i in 0..<n { text(ls[i], x + 26, y + CGFloat(i) * Self.LINE_H, 16, Self.C_WHITE) }
        return y + CGFloat(max(1, n)) * Self.LINE_H + 6
    }

    // MARK: - 機器人（頭盔 + 面罩 + 眼睛 + 嘴巴 + Zzz）
    private func drawRobot(_ f: FaceModel, _ vx: CGFloat, _ vy: CGFloat, _ s: CGFloat, _ ex: Ex, _ lx: CGFloat, _ ly: CGFloat,
                           _ blink: Bool, _ mouthOpen: CGFloat, _ now: Double) {
        let X = vx, Y = vy
        func S(_ v: CGFloat) -> CGFloat { v * s }
        let g = ex == .angry ? Self.C_RED2 : Self.C_GLOW

        // 耳罩
        for side in [-1.0, 1.0] as [CGFloat] {
            let cx = X + side * S(121)
            rrGrad(cx - S(19), Y - S(44), S(38), S(92), S(16), 0xFFB0BED2, 0xFF687892)
            rr(cx - S(5) + side * S(6), Y - S(30), S(9), S(56), S(5), 0xFFCED8E8)
        }
        // 頭盔
        rr(X - S(125), Y - S(96), S(250), S(198), S(90), 0xFF808A9A)
        rrGrad(X - S(124), Y - S(99), S(248), S(194), S(88), 0xFFFCFDFF, 0xFFC4CBD6)
        ellipse(X - S(62), Y - S(80), S(34), S(9), Self.C_WHITE)
        // 面罩
        rr(X - S(102), Y - S(71), S(204), S(142), S(56), 0xFF344660)
        rrGrad(X - S(98), Y - S(67), S(196), S(134), S(52), 0xFF1E3450, 0xFF091220)
        ellipse(X - S(50), Y - S(52), S(32), S(7), 0xFF2C4666)

        let ey = Y - S(10), dx = S(44), my = Y + S(34)
        let th = max(2, S(5))
        let talking = mouthOpen > 0.05
        let smiley = ex == .normal || ex == .happy || ex == .wink || ex == .love || ex == .shy

        if ex == .shy || ex == .love {
            for side in [-1.0, 1.0] as [CGFloat] {
                ellipse(X + side * S(68), Y + S(20), S(15), S(6), blend(Self.C_VISOR, Self.C_PINK, 0.55))
            }
        }

        // 嘴巴
        if talking {
            let rx = S(15), ry = max(S(4), S(4 + 13 * mouthOpen))
            ellipse(X, my - S(4), rx, ry, g)
            if ry > S(7) { ellipse(X, my - S(4), rx - S(5), ry - S(5), 0xFF0E3C52) }
        } else if smiley {
            arc(X, my - S(18), S(18), 35, 110, th, g)
        } else if ex == .surprise || ex == .listen {
            let r = S(ex == .surprise ? 9 : 7) + (ex == .listen ? min(S(6), CGFloat(f.level) * S(10)) : 0)
            ellipse(X, my - S(2), r, r, g)
            if ex == .listen { ellipse(X, my - S(2), max(1, r - th), max(1, r - th), Self.C_VISOR) }
        } else if ex == .sad || ex == .angry {
            arc(X, my + S(12), S(16), 215, 110, th, g)
        } else if ex == .think {
            for i in 0..<3 {
                let on = Int(now / 250) % 3 == i
                ellipse(X + CGFloat(i - 1) * S(14), my - S(2), S(4), S(4), on ? g : Self.C_GLOW_DIM)
            }
        } else if ex == .sleepy {
            arc(X, my + S(4), S(8), 200, 140, th, g)
        } else {
            line(X - S(13), my - S(2), X + S(13), my - S(2), th, g)
        }

        // 眼睛
        let ew = S(22), eh = S(32)
        for side in [-1.0, 1.0] as [CGFloat] {
            let cx = X + side * dx, x = cx + lx, y = ey + ly
            switch ex {
            case .happy, .shy:
                arc(cx, ey + S(8), S(12), 200, 140, th + 1, g)
            case .wink:
                if side < 0 { line(cx - S(11), ey, cx + S(11), ey, th + 1, g) } else { eye(x, y, ew, eh, g) }
            case .love:
                let r = S(15) + S(2) * CGFloat(sin(now / 150))
                heart(cx, ey - S(2), r, Self.C_PINK)
            case .surprise:
                ellipse(cx, ey, S(10), S(10), g)
            case .sleepy:
                arc(cx, ey - S(6), S(11), 20, 140, th, g)
            case .think:
                eye(cx + S(6), ey - S(8), ew, S(20), g)
            default:
                let w = ex == .listen ? S(25) : ew
                let hh = ex == .listen ? S(36) : ex == .angry ? S(24) : ex == .sad ? S(26) : eh
                if blink && ex != .listen { line(x - w / 2, y, x + w / 2, y, th + 1, g) } else { eye(x, y, w, hh, g) }
                if ex == .sad {
                    line(x - S(13), y - hh / 2 - S(7) + S(5) * side, x + S(13), y - hh / 2 - S(7) - S(5) * side, th, g)
                }
                if ex == .angry {
                    line(x - S(13), y - hh / 2 - S(9) - S(6) * side, x + S(13), y - hh / 2 - S(9) + S(6) * side, th, g)
                }
            }
        }

        // 想睡 Zzz
        if ex == .sleepy {
            let kz = CGFloat(Int(now / 500) % 3)
            text("z", vx + 100 * s, vy - 78 * s - kz * 3, 14 * s + 8, Self.C_GLOW, bold: true)
            text("Z", vx + 114 * s, vy - 96 * s - kz * 3, 20 * s + 10, Self.C_GLOW, bold: true)
        }
    }

    // 眼睛（圓角矩形 + 外發光）
    private func eye(_ cx: CGFloat, _ cy: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: C) {
        let p = Path(roundedRect: CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h), cornerRadius: min(w, h) / 2)
        glow(3) { $0.fill(p, with: .color(self.col(color))) }
        ctx.fill(p, with: .color(col(color)))
    }

    // MARK: - 低階繪圖
    private func col(_ v: C) -> Color {
        Color(.sRGB, red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255,
              blue: Double(v & 0xff) / 255, opacity: Double((v >> 24) & 0xff) / 255)
    }

    private func glow(_ radius: CGFloat, _ body: (inout GraphicsContext) -> Void) {
        ctx.drawLayer { l in
            l.addFilter(.blur(radius: radius))
            body(&l)
        }
    }

    private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: C) {
        ctx.fill(Path(CGRect(x: x, y: y, width: w, height: h)), with: .color(col(color)))
    }

    private func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat, _ color: C) {
        ctx.fill(Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: min(r, w / 2, h / 2)),
                 with: .color(col(color)))
    }

    private func rrGrad(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat, _ c1: C, _ c2: C) {
        ctx.fill(Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: min(r, w / 2, h / 2)),
                 with: .linearGradient(Gradient(colors: [col(c1), col(c2)]),
                                       startPoint: CGPoint(x: x, y: y), endPoint: CGPoint(x: x, y: y + h)))
    }

    private func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat, _ color: C) {
        ctx.fill(Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2)), with: .color(col(color)))
    }

    /// 與 Android drawArc 相同：角度從 3 點鐘方向起算、順時針。
    private func arc(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ startDeg: CGFloat, _ sweepDeg: CGFloat, _ th: CGFloat, _ color: C) {
        var p = Path()
        let steps = 24
        for i in 0...steps {
            let a = (startDeg + sweepDeg * CGFloat(i) / CGFloat(steps)) * .pi / 180
            let pt = CGPoint(x: cx + r * cos(a), y: cy + r * sin(a))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        strokeGlow(p, th, color)
    }

    private func line(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat, _ th: CGFloat, _ color: C) {
        var p = Path()
        p.move(to: CGPoint(x: x0, y: y0))
        p.addLine(to: CGPoint(x: x1, y: y1))
        strokeGlow(p, th, color)
    }

    private func strokeGlow(_ p: Path, _ th: CGFloat, _ color: C) {
        let style = StrokeStyle(lineWidth: th, lineCap: .round, lineJoin: .round)
        glow(2.5) { $0.stroke(p, with: .color(self.col(color)), style: style) }
        ctx.stroke(p, with: .color(col(color)), style: style)
    }

    private func heart(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ color: C) {
        var p = Path()
        p.move(to: CGPoint(x: cx, y: cy + r * 0.9))
        p.addCurve(to: CGPoint(x: cx, y: cy - r * 0.3),
                   control1: CGPoint(x: cx - r * 1.3, y: cy - r * 0.1), control2: CGPoint(x: cx - r * 0.7, y: cy - r))
        p.addCurve(to: CGPoint(x: cx, y: cy + r * 0.9),
                   control1: CGPoint(x: cx + r * 0.7, y: cy - r), control2: CGPoint(x: cx + r * 1.3, y: cy - r * 0.1))
        glow(2.5) { $0.fill(p, with: .color(self.col(color))) }
        ctx.fill(p, with: .color(col(color)))
    }

    private func drawMicBars(_ f: FaceModel, _ x: CGFloat, _ y: CGFloat) {
        let lv = min(1, f.level * 1.4)
        for i in 0..<4 {
            let on = lv * 4 > Float(i)
            let bh = CGFloat(4 + i * 3)
            rect(x + CGFloat(i) * 6, y - bh, 4, bh, on ? Self.C_GREEN : Self.C_GLOW_DIM)
        }
    }

    private func drawPageDots(_ x: CGFloat, _ y: CGFloat) {
        for i in 0..<4 { ellipse(x + CGFloat(i) * 7, y, 1.6, 1.6, Self.C_GLOW_DIM) }
    }

    private func drawWorkstationLabel() {
        let w: CGFloat = 150, h: CGFloat = 24, x = FaceModel.LW - w - 8, y = FaceModel.LH - h - 4
        rr(x, y, w, h, 10, Self.C_GLOW_DIM)
        let s = "病房助理工作站"
        text(s, x + (w - measure(s, 16, bold: true)) / 2, y + 17, 16, Self.C_WHITE, bold: true)
    }

    private func drawDeckLabel() {
        let w: CGFloat = 100, h: CGFloat = 24, x: CGFloat = 246, y = FaceModel.LH - h - 4
        rr(x, y, w, h, 10, Self.C_ORANGE)
        let s = "Stream Deck"
        text(s, x + (w - measure(s, 15, bold: true)) / 2, y + 17, 15, Self.C_BG, bold: true)
    }

    // MARK: - 病房助理工作站選單
    private func drawPortal(_ f: FaceModel, _ portal: Portal) {
        let LW = FaceModel.LW
        text(Config.PORTAL_NAME, 8, 68, 16, Self.C_ORANGE)
        drawBtn(410, 50, 96, 24, "回主畫面", Self.C_BAR_LINE, Self.C_WHITE)

        if portal.isEmpty {
            text("工具清單讀取失敗", 8, 120, 16, Self.C_GRAY)
            return
        }

        if let sel = f.portalSel {                                     // ---- 詳細頁 ----
            text(clip(sel.full, 276, 16), 8, 104, 16, Self.C_GLOW)
            text("類別：" + sel.cat, 8, 126, 16, Self.C_GRAY)
            let ls = wrap("用手機掃描右邊的 QR 碼開啟；或在同一個 Wi-Fi 下，用手機瀏覽器開啟首頁左下角的網址來點選。", 276, 16)
            for i in 0..<min(4, ls.count) { text(ls[i], 8, 150 + CGFloat(i) * Self.LINE_H, 16, Self.C_WHITE) }
            let us = wrap(sel.url, 276, 13)
            for i in 0..<min(2, us.count) { text(us[i], 8, 232 + CGFloat(i) * 16, 13, Self.C_GLOW_DIM) }

            let qx: CGFloat = 296, qy: CGFloat = 84, qw: CGFloat = 200
            rr(qx, qy, qw, qw, 6, Self.C_WHITE)
            if let img = portal.qr(sel.id) {
                ctx.draw(Image(decorative: img, scale: 1).interpolation(.none),
                         in: CGRect(x: qx + 10, y: qy + 10, width: qw - 20, height: qw - 20))
            }
            let cap = "手機掃描開啟"
            text(cap, qx + (qw - measure(cap, 14)) / 2, qy + qw + 14, 14, Self.C_GRAY)
            drawBtn(8, 268, 120, 26, "返回清單", Self.C_BAR_LINE, Self.C_WHITE)
            return
        }

        // ---- 清單頁 ----
        let n = portal.cats.count + 1
        let w = (LW - 16) / CGFloat(n)
        for i in 0..<n {
            let on = (i == 0 && f.portalCat < 0) || (i > 0 && f.portalCat == i - 1)
            drawBtn(8 + CGFloat(i) * w, 80, w - 4, 24, i == 0 ? "全部" : portal.cats[i - 1],
                    on ? Self.C_GLOW_DIM : Self.C_PANEL, on ? Self.C_WHITE : Self.C_GRAY)
        }
        let v = portal.filtered(f.portalCat)
        let pages = max(1, (v.count + 7) / 8)
        let pg = min(max(f.portalPage, 0), pages - 1)
        if pages > 1 {
            drawBtn(250, 50, 72, 24, "上一頁", pg > 0 ? Self.C_BAR_LINE : Self.C_PANEL, pg > 0 ? Self.C_WHITE : Self.C_GRAY)
            drawBtn(328, 50, 72, 24, "下一頁", pg < pages - 1 ? Self.C_BAR_LINE : Self.C_PANEL, pg < pages - 1 ? Self.C_WHITE : Self.C_GRAY)
            text("\(pg + 1)/\(pages)", 200, 68, 15, Self.C_GRAY)
        }
        for k in 0..<8 where pg * 8 + k < v.count {
            let t = v[pg * 8 + k]
            let bx = 8 + CGFloat(k % 2) * 250, by = 110 + CGFloat(k / 2) * 46
            let box = Path(roundedRect: CGRect(x: bx, y: by, width: 244, height: 42), cornerRadius: 6)
            ctx.fill(box, with: .color(col(Self.C_PANEL)))
            ctx.stroke(box, with: .color(col(Self.C_BAR_LINE)), lineWidth: 1)
            text(clip(t.name, 228, 16), bx + 8, by + 18, 16, Self.C_WHITE)
            text(clip(t.url, 228, 13), bx + 8, by + 36, 13, Self.C_GRAY)
        }
        if v.isEmpty { text("這個類別沒有工具", 8, 140, 16, Self.C_GLOW_DIM) }
    }

    private func drawBtn(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ label: String, _ bg: C, _ fg: C) {
        rr(x, y, w, h, 6, bg)
        let l = clip(label, w - 4, 15)
        text(l, x + (w - measure(l, 15)) / 2, y + h / 2 + 6, 15, fg)
    }

    // MARK: - 文字（y 為基線，與 Android drawText 相同）
    private func font(_ size: CGFloat, bold: Bool, mono: Bool) -> Font {
        .system(size: size, weight: bold ? .bold : .regular, design: mono ? .monospaced : .default)
    }

    private func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ color: C, bold: Bool = false, mono: Bool = false) {
        guard !s.isEmpty else { return }
        let r = ctx.resolve(Text(s).font(font(size, bold: bold, mono: mono)).foregroundColor(col(color)))
        let sz = r.measure(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        let base = r.firstBaseline(in: sz)
        ctx.draw(r, in: CGRect(x: x, y: y - base, width: sz.width + 1, height: sz.height))
    }

    private func measure(_ s: String, _ size: CGFloat, bold: Bool = false, mono: Bool = false) -> CGFloat {
        let key = "\(size)|\(bold)|\(mono)|\(s)"
        if let w = widthCache[key] { return w }
        let w = ctx.resolve(Text(s).font(font(size, bold: bold, mono: mono)))
            .measure(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)).width
        if widthCache.count > 4000 { widthCache.removeAll() }
        widthCache[key] = w
        return w
    }

    private func clip(_ s: String, _ maxW: CGFloat, _ size: CGFloat) -> String {
        if measure(s, size) <= maxW { return s }
        var b = ""
        for ch in s {
            if measure(b + String(ch) + "…", size) > maxW { break }
            b.append(ch)
        }
        return b + "…"
    }

    // 以邏輯寬度斷行（中英混排，逐字量測）
    private func wrap(_ text: String, _ maxW: CGFloat, _ size: CGFloat) -> [String] {
        let key = "\(maxW)|\(size)|\(text)"
        if let c = wrapCache[key] { return c }
        var out: [String] = []
        var cur = ""
        for ch in text {
            if ch == "\n" { out.append(cur); cur = ""; continue }
            cur.append(ch)
            if measure(cur, size) > maxW {
                cur.removeLast()
                out.append(cur)
                cur = String(ch)
            }
        }
        if !cur.isEmpty { out.append(cur) }
        if wrapCache.count > 200 { wrapCache.removeAll() }
        wrapCache[key] = out
        return out
    }

    private func blend(_ a: C, _ b: C, _ t: CGFloat) -> C {
        func ch(_ v: C, _ s: C) -> CGFloat { CGFloat((v >> s) & 0xff) }
        func mix(_ s: C) -> C { C(ch(a, s) + (ch(b, s) - ch(a, s)) * t) & 0xff }
        return 0xFF000000 | (mix(16) << 16) | (mix(8) << 8) | mix(0)
    }
}
