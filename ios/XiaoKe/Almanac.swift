import Foundation

/// 農民曆（離線計算，不需上網）— 由 Android 版 Almanac.java 移植。
///   年柱以農曆年為準；月柱以「節」交接（立春起寅月）；日柱由日期推算。
///   節氣日期用 21 世紀近似公式（少數年份可能差 1 天）。
///   宜忌採「建除十二神」簡易版，僅供參考。
struct Almanac {
    private static let GZ_STEM = ["甲", "乙", "丙", "丁", "戊", "己", "庚", "辛", "壬", "癸"]
    private static let GZ_BRANCH = ["子", "丑", "寅", "卯", "辰", "巳", "午", "未", "申", "酉", "戌", "亥"]
    private static let ZODIAC = ["鼠", "牛", "虎", "兔", "龍", "蛇", "馬", "羊", "猴", "雞", "狗", "豬"]
    private static let SOLAR_TERM = ["小寒", "大寒", "立春", "雨水", "驚蟄", "春分", "清明", "穀雨", "立夏", "小滿", "芒種", "夏至",
                                     "小暑", "大暑", "立秋", "處暑", "白露", "秋分", "寒露", "霜降", "立冬", "小雪", "大雪", "冬至"]
    private static let SOLAR_TERM_C: [Float] = [5.4055, 20.12, 3.87, 18.73, 5.63, 20.646, 4.81, 20.1, 5.52, 21.04, 5.678, 21.37,
                                                7.108, 22.83, 7.5, 23.13, 7.646, 23.042, 8.318, 23.438, 7.438, 22.36, 7.18, 21.94]
    private static let JIANCHU = ["建", "除", "滿", "平", "定", "執", "破", "危", "成", "收", "開", "閉"]
    private static let JIANCHU_YI = [
        "出行、上任、祈福", "掃舍、沐浴、求醫", "祭祀、祈福、開市", "修飾、塗泥、平治道路",
        "嫁娶、交易、納財、入學", "立約、捕捉、修補", "求醫、拆屋（大事勿用）", "安床、祭祀",
        "開市、嫁娶、入學、出行", "納財、收帳、捕捉", "開市、嫁娶、出行、求職", "築堤、補垣、安葬"]
    private static let JIANCHU_JI = [
        "動土、開倉、嫁娶", "嫁娶、遠行", "栽種、下葬、上任", "開渠、栽種",
        "訴訟、出行", "開市、移徙、出行", "嫁娶、開市、簽約", "登高、行船、出行",
        "訴訟", "出行、安葬", "安葬、動土", "開市、出行、求醫"]
    private static let SHA_DIR = ["南", "東", "北", "西", "南", "東", "北", "西", "南", "東", "北", "西"]

    // 農曆表：{ 正月初一距 2000-01-01 的天數, 各月大小 bit(i)=第 i 月(1=30天), 閏幾月(0=無) }（2000–2099）
    private static let FIRST_YEAR = 2000
    private static let L_CNY = [
        35, 389, 773, 1127, 1482, 1866, 2220, 2605, 2959, 3313, 3697, 4051, 4405, 4789, 5144, 5528, 5882, 6237, 6621, 6975,
        7329, 7713, 8067, 8422, 8806, 9160, 9544, 9898, 10252, 10636, 10991, 11345, 11729, 12084, 12468, 12822, 13176, 13560, 13914, 14268,
        14652, 15007, 15362, 15746, 16100, 16484, 16838, 17192, 17576, 17930, 18285, 18669, 19024, 19408, 19762, 20116, 20499, 20854, 21208, 21592,
        21947, 22301, 22685, 23039, 23423, 23777, 24132, 24516, 24870, 25225, 25609, 25963, 26347, 26701, 27055, 27439, 27794, 28148, 28532, 28887,
        29241, 29625, 29979, 30363, 30717, 31072, 31456, 31810, 32165, 32548, 32902, 33286, 33640, 33995, 34379, 34734, 35088, 35472, 35826, 36180]
    private static let L_BITS = [
        0x0693, 0x152B, 0x052B, 0x0A5B, 0x155A, 0x056A, 0x1B55, 0x0BA4, 0x0B49, 0x1A93, 0x0A95, 0x052D, 0x0AAD, 0x0AB5, 0x15AA, 0x05D2, 0x0DA5, 0x1D4A, 0x0D4A, 0x0C95,
        0x152E, 0x0556, 0x0AB5, 0x15B2, 0x06D2, 0x0EA5, 0x0725, 0x064B, 0x0C97, 0x0CAB, 0x055A, 0x0AD6, 0x0B69, 0x1752, 0x0B52, 0x0B25, 0x1A4B, 0x0A4B, 0x04AB, 0x055B,
        0x05AD, 0x0B6A, 0x1B52, 0x0D92, 0x1D25, 0x0D25, 0x0A55, 0x14AD, 0x04B6, 0x05B5, 0x0DAA, 0x0EC9, 0x1E92, 0x0E92, 0x0D26, 0x0A56, 0x0A57, 0x0556, 0x06D5, 0x0755,
        0x0749, 0x0E93, 0x0693, 0x152B, 0x052B, 0x0A5B, 0x155A, 0x056A, 0x0B65, 0x174A, 0x0B4A, 0x1A95, 0x0A95, 0x052D, 0x0AAD, 0x0AB5, 0x05AA, 0x0BA5, 0x0DA5, 0x0D4A,
        0x1C95, 0x0C96, 0x194E, 0x0556, 0x0AB5, 0x15B2, 0x06D2, 0x0EA5, 0x0E4A, 0x068B, 0x0C97, 0x04AB, 0x055B, 0x0AD6, 0x0B6A, 0x0752, 0x1725, 0x0B45, 0x0A8B, 0x0000]
    private static let L_LEAP = [
        0, 4, 0, 0, 2, 0, 7, 0, 0, 5, 0, 0, 4, 0, 9, 0, 0, 6, 0, 0,
        4, 0, 0, 2, 0, 6, 0, 0, 5, 0, 0, 3, 0, 11, 0, 0, 6, 0, 0, 5,
        0, 0, 2, 0, 7, 0, 0, 5, 0, 0, 3, 0, 8, 0, 0, 6, 0, 0, 4, 0,
        0, 3, 0, 7, 0, 0, 5, 0, 0, 4, 0, 8, 0, 0, 6, 0, 0, 4, 0, 0,
        3, 0, 7, 0, 0, 5, 0, 0, 4, 0, 8, 0, 0, 6, 0, 0, 4, 0, 0, 0]

    var ok = false
    var yearGZ = "", zodiac = "", monthGZ = "", dayGZ = ""
    var jianchu = "", yi = "", ji = "", chong = "", sha = ""
    var termToday = ""   // 今天是節氣就填
    var nextTerm = ""    // 下一個節氣與日期，例如「霜降 10/23」

    // 距 2000-01-01 的天數（Howard Hinnant 演算法）
    private static func daysSince2000(_ year: Int, _ m: Int, _ d: Int) -> Int {
        let y = year - (m <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468 - 10957
    }

    // 第 k 個節氣（0 = 小寒）在 year 年的日期（月 = k/2 + 1）
    private static func solarTermDay(_ year: Int, _ k: Int) -> Int {
        let y = year % 100
        let L = k < 4 ? (y - 1) / 4 : y / 4
        return Int(Float(y) * 0.2422 + SOLAR_TERM_C[k]) - L
    }

    private static func mod(_ a: Int, _ n: Int) -> Int { ((a % n) + n) % n }

    private static func ymd(_ date: Date, _ tz: TimeZone) -> (Int, Int, Int) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return (c.year!, c.month!, c.day!)
    }

    static func compute(_ date: Date, _ tz: TimeZone = .current) -> Almanac {
        var a = Almanac()
        let (Y, M, D) = ymd(date, tz)
        let d = daysSince2000(Y, M, D)

        // 年柱 / 生肖：農曆年
        var lunarYear = -1
        for i in 0..<(L_CNY.count - 1) where d >= L_CNY[i] && d < L_CNY[i + 1] { lunarYear = FIRST_YEAR + i; break }
        if lunarYear < 0 { return a }
        let ygz = mod(lunarYear - 4, 60)
        a.yearGZ = GZ_STEM[ygz % 10] + GZ_BRANCH[ygz % 12]
        a.zodiac = ZODIAC[ygz % 12]

        // 月柱：以「節」交接
        let termIdx = M * 2 - 2
        var mBranch = mod(M, 12)
        if D < solarTermDay(Y, termIdx) { mBranch = mod(mBranch - 1, 12) }
        let solarYear = Y - ((M < 2 || (M == 2 && D < solarTermDay(Y, 2))) ? 1 : 0)
        let sStem = mod(solarYear - 4, 10)
        let firstStem = (sStem % 5) * 2 + 2
        let mStem = mod(firstStem + mod(mBranch - 2, 12), 10)
        a.monthGZ = GZ_STEM[mStem] + GZ_BRANCH[mBranch]

        // 日柱：2000-01-01 為戊午日（第 54）
        let dgz = mod(54 + d % 60, 60)
        let dStem = dgz % 10, dBranch = dgz % 12
        a.dayGZ = GZ_STEM[dStem] + GZ_BRANCH[dBranch]

        // 建除十二神、宜忌、沖煞
        let jc = mod(dBranch - mBranch, 12)
        a.jianchu = JIANCHU[jc]
        a.yi = JIANCHU_YI[jc]
        a.ji = JIANCHU_JI[jc]
        let cb = (dBranch + 6) % 12, cs = (dStem + 4) % 10
        a.chong = "沖" + ZODIAC[cb] + "（" + GZ_STEM[cs] + GZ_BRANCH[cb] + "）"
        a.sha = SHA_DIR[dBranch]

        // 節氣
        for k in 0..<24 where k / 2 + 1 == M && solarTermDay(Y, k) == D { a.termToday = SOLAR_TERM[k] }
        for i in 0..<25 {
            let k = (M * 2 - 2 + i) % 24, yy = Y + (M * 2 - 2 + i) / 24
            let tm = k / 2 + 1, td = solarTermDay(yy, k)
            if daysSince2000(yy, tm, td) > d { a.nextTerm = "\(SOLAR_TERM[k]) \(tm)/\(td)"; break }
        }
        a.ok = true
        return a
    }

    /// 上方列的農曆字串，例如「九月初二」（閏月前加「閏」）。
    static func lunarString(_ date: Date, _ tz: TimeZone = .current) -> String {
        let (Y, M, D) = ymd(date, tz)
        let d = daysSince2000(Y, M, D)
        var yi = -1
        for i in 0..<(L_CNY.count - 1) where d >= L_CNY[i] && d < L_CNY[i + 1] { yi = i; break }
        if yi < 0 { return "" }
        var off = d - L_CNY[yi]
        let leap = L_LEAP[yi], n = leap != 0 ? 13 : 12
        var month = 1, day = 1, isLeap = false
        for i in 0..<n {
            let len = ((L_BITS[yi] >> i) & 1) != 0 ? 30 : 29
            if off < len {
                if leap == 0 || i < leap { month = i + 1 }
                else if i == leap { month = leap; isLeap = true }
                else { month = i }
                day = off + 1
                break
            }
            off -= len
        }
        let MN = ["正", "二", "三", "四", "五", "六", "七", "八", "九", "十", "冬", "臘"]
        let DG = ["一", "二", "三", "四", "五", "六", "七", "八", "九"]
        let TP = ["初", "十", "廿"]
        let ds = day == 10 ? "初十" : day == 20 ? "二十" : day == 30 ? "三十" : TP[day / 10] + DG[day % 10 - 1]
        return (isLeap ? "閏" : "") + MN[month - 1] + "月" + ds
    }

    /// 給 AI 參考的一行文字。
    static func aiText(_ date: Date, _ tz: TimeZone) -> String {
        let a = compute(date, tz)
        if !a.ok { return "" }
        var s = "農民曆：\(a.yearGZ)年（\(a.zodiac)年）、\(a.monthGZ)月、\(a.dayGZ)日，"
            + "\(a.jianchu)日，宜\(a.yi)，忌\(a.ji)，\(a.chong)，煞\(a.sha)。"
        if !a.termToday.isEmpty { s += "今天是\(a.termToday)。" }
        s += "下一個節氣：\(a.nextTerm)。"
        return s
    }
}
