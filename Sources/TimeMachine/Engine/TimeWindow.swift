import Foundation

let kChinaTZ = TimeZone(identifier: "Asia/Shanghai")!

var chinaCalendar: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = kChinaTZ
    c.locale = Locale(identifier: "zh_CN")
    return c
}

struct YearMonth: Hashable, Codable, Comparable, CustomStringConvertible {
    var year: Int
    var month: Int

    /// 抖音上线时间：2016 年 9 月
    static let douyinEpoch = YearMonth(year: 2016, month: 9)

    static var current: YearMonth {
        let c = chinaCalendar.dateComponents([.year, .month], from: Date())
        return YearMonth(year: c.year!, month: c.month!)
    }

    var index: Int { year * 12 + (month - 1) }

    init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    init(index: Int) {
        year = index / 12
        month = index % 12 + 1
    }

    /// 发布时间戳（秒）所在的月份（北京时间）
    init(timestamp: Int) {
        let c = chinaCalendar.dateComponents([.year, .month], from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
        year = c.year ?? 2016
        month = c.month ?? 1
    }

    /// 本月月末（下个月月初）的毫秒时间戳，用作作品列表的 max_cursor
    var endCursorMs: Int { adding(months: 1).startTimestamp * 1000 }

    func adding(months: Int) -> YearMonth { YearMonth(index: index + months) }

    var startDate: Date {
        chinaCalendar.date(from: DateComponents(year: year, month: month, day: 1))!
    }

    var startTimestamp: Int { Int(startDate.timeIntervalSince1970) }

    var description: String { "\(year)年\(month)月" }
    var short: String { String(format: "%d.%02d", year, month) }

    static func < (l: YearMonth, r: YearMonth) -> Bool { l.index < r.index }

    func clamped() -> YearMonth {
        min(max(self, .douyinEpoch), .current)
    }
}

/// 时光机的目标时间段：[from 月初, to 月末]，精确到月
struct TimeWindow: Hashable, Codable, CustomStringConvertible {
    var from: YearMonth
    var to: YearMonth

    init(from: YearMonth, to: YearMonth) {
        let a = from.clamped(), b = to.clamped()
        self.from = min(a, b)
        self.to = max(a, b)
    }

    static func single(_ ym: YearMonth) -> TimeWindow { TimeWindow(from: ym, to: ym) }

    /// 闭区间起点（秒）
    var startTS: Int { from.startTimestamp }
    /// 开区间终点（秒）：to 的下一个月月初
    var endTS: Int { to.adding(months: 1).startTimestamp }

    var monthCount: Int { to.index - from.index + 1 }

    var key: String { "\(from.short)-\(to.short)" }

    func contains(_ ts: Int) -> Bool { ts >= startTS && ts < endTS }

    func contains(_ ym: YearMonth) -> Bool { ym >= from && ym <= to }

    var years: ClosedRange<Int> { from.year...to.year }

    var monthIndices: ClosedRange<Int> { from.index...to.index }

    /// 是否覆盖最近半年（这种时候推荐流本身也能直接命中）
    var touchesRecent: Bool { to.index >= YearMonth.current.index - 6 }

    var description: String {
        if from == to { return from.description }
        if from.year == to.year { return "\(from.year)年\(from.month)–\(to.month)月" }
        return "\(from.description) – \(to.description)"
    }

    struct Preset: Identifiable {
        let id: String
        let title: String
        let window: TimeWindow
    }

    static var presets: [Preset] {
        let now = YearMonth.current
        var list: [Preset] = [
            Preset(id: "1y", title: "一年前的这个月", window: .single(now.adding(months: -12))),
            Preset(id: "3y", title: "三年前", window: .single(now.adding(months: -36))),
            Preset(id: "5y", title: "五年前", window: .single(now.adding(months: -60))),
        ]
        for y in stride(from: now.year - 1, through: 2017, by: -1) {
            list.append(Preset(id: "y\(y)", title: "\(y) 全年",
                               window: TimeWindow(from: YearMonth(year: y, month: 1), to: YearMonth(year: y, month: 12))))
        }
        list.append(Preset(id: "origin", title: "抖音元年 2016", window: TimeWindow(from: .douyinEpoch, to: YearMonth(year: 2016, month: 12))))
        return list
    }

    static func random() -> TimeWindow {
        let lo = YearMonth.douyinEpoch.adding(months: 3).index
        let hi = YearMonth.current.adding(months: -2).index
        return .single(YearMonth(index: Int.random(in: lo...max(lo, hi))))
    }
}

enum Fmt {
    static func count(_ n: Int) -> String {
        if n >= 100_000_000 { return String(format: "%.1f亿", Double(n) / 100_000_000) }
        if n >= 10_000 { return String(format: "%.1f万", Double(n) / 10_000) }
        return "\(n)"
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = kChinaTZ
        f.dateFormat = "yyyy年M月d日"
        return f
    }()

    static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = kChinaTZ
        f.dateFormat = "yyyy年M月d日 HH:mm"
        return f
    }()

    static func ago(_ date: Date) -> String {
        let c = chinaCalendar.dateComponents([.year, .month, .day, .hour, .minute], from: date, to: Date())
        if let y = c.year, y > 0 { return "\(y) 年前" }
        if let m = c.month, m > 0 { return "\(m) 个月前" }
        if let d = c.day, d > 0 { return "\(d) 天前" }
        if let h = c.hour, h > 0 { return "\(h) 小时前" }
        if let mi = c.minute, mi > 0 { return "\(mi) 分钟前" }
        return "刚刚"
    }

    static func duration(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let t = Int(s.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}
