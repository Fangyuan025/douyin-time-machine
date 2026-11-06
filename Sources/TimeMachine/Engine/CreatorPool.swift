import Foundation

enum CreatorSource: String, Codable, CaseIterable {
    case following, liked, feed, search, mention, manual, related
}

struct Creator: Codable, Identifiable {
    var secUid: String
    var uid: String
    var nickname: String
    var avatarURL: URL?
    var sources: Set<CreatorSource>
    var followed: Bool
    var addedAt: Date
    /// 从 time_list 推断出的有作品的年份
    var activeYears: [Int]?
    /// time_list 给出的有作品的月份（YearMonth.index），比年份更精确
    var activeMonths: [Int]?
    /// 已知最早一条作品的时间（翻到底时记录），早于它的时间段不必再查
    var firstPostTS: Int?
    var hits: Int = 0
    var queries: Int = 0
    /// 扫描后至少命中一条的次数（Thompson 采样的成功次数）
    var goodScans: Int?
    /// 作品热度（log10 互动量的滑动平均），用来优先挑“作品更火”的创作者
    var hotScore: Double?
    var followerCount: Int?
    var isInstitution: Bool?

    /// 普通人（素人）创作者：非机构、粉丝不过百万（未知时按作品热度判断）
    var isAmateur: Bool {
        if isInstitution == true { return false }
        if let f = followerCount { return f < 1_000_000 }
        if let h = hotScore { return h < 4.8 }
        return true
    }

    var id: String { secUid }

    /// 最能说明“为什么会翻到这个人”的来源
    var primarySource: CreatorSource {
        for s in [CreatorSource.following, .liked, .search, .mention, .related, .feed, .manual] where sources.contains(s) {
            return s
        }
        return .feed
    }
}

struct WindowProgress: Codable {
    var cursorMs: Int?
    var exhausted = false
    var pages = 0
    var hits = 0
    /// 已经翻过的月份（YearMonth.index）——多月时间段按月分层采样，避免结果全挤在时间段末尾
    var coveredMonths: [Int]?
    /// 某个月还没翻完时，下次从这里继续（月份 → max_cursor 毫秒）
    var monthCursor: [String: Int]?
}

/// 创作者池：时光机通过“创作者 + 时间游标”回到过去。
/// 推荐流、关注列表、喜欢列表、搜索结果、视频里 @ 到的人都会被收进池子。
struct CreatorPool: Codable {
    var creators: [String: Creator] = [:]
    /// windowKey → secUid → 翻页进度
    var progress: [String: [String: WindowProgress]] = [:]
    var windowLRU: [String] = []
    /// uid → 上次导入关注/喜欢的时间
    var seededAt: [String: Date] = [:]

    var count: Int { creators.count }

    @discardableResult
    mutating func add(_ a: Author, source: CreatorSource, followed: Bool = false) -> Bool {
        guard !a.secUid.isEmpty else { return false }
        if var c = creators[a.secUid] {
            c.sources.insert(source)
            if followed { c.followed = true }
            if let f = a.followerCount { c.followerCount = f }
            if let i = a.isInstitution { c.isInstitution = i }
            if a.nickname != "抖音用户" { c.nickname = a.nickname }
            if let av = a.avatarURL { c.avatarURL = av }
            if c.uid.isEmpty { c.uid = a.uid }
            creators[a.secUid] = c
            return false
        }
        var c = Creator(secUid: a.secUid, uid: a.uid, nickname: a.nickname, avatarURL: a.avatarURL,
                        sources: [source], followed: followed, addedAt: Date())
        c.followerCount = a.followerCount
        c.isInstitution = a.isInstitution
        creators[a.secUid] = c
        if creators.count > 4000 { pruneCreators() }
        return true
    }

    func progress(_ window: TimeWindow, _ sec: String) -> WindowProgress? {
        progress[window.key]?[sec]
    }

    mutating func setProgress(_ p: WindowProgress, _ window: TimeWindow, _ sec: String) {
        progress[window.key, default: [:]][sec] = p
    }

    mutating func touch(_ window: TimeWindow) {
        windowLRU.removeAll { $0 == window.key }
        windowLRU.append(window.key)
        while windowLRU.count > 16 {
            let old = windowLRU.removeFirst()
            progress[old] = nil
        }
    }

    mutating func resetProgress(_ window: TimeWindow) {
        progress[window.key] = nil
    }

    func isEligible(_ c: Creator, for window: TimeWindow) -> Bool {
        if progress[window.key]?[c.secUid]?.exhausted == true { return false }
        if let first = c.firstPostTS, first >= window.endTS { return false }
        if let months = c.activeMonths, !months.isEmpty {
            let range = window.from.index...window.to.index
            return months.contains { range.contains($0) }
        }
        if let years = c.activeYears, !years.isEmpty, !years.contains(where: { window.years.contains($0) }) { return false }
        return true
    }

    func eligible(for window: TimeWindow) -> [Creator] {
        creators.values.filter { isEligible($0, for: window) }
    }

    mutating func update(_ sec: String, _ body: (inout Creator) -> Void) {
        guard var c = creators[sec] else { return }
        body(&c)
        creators[sec] = c
    }

    private mutating func pruneCreators() {
        // 优先淘汰：非关注、非喜欢、查询过但从未命中的创作者
        let ranked = creators.values.sorted { a, b in
            func keep(_ c: Creator) -> Double {
                var s = Double(c.hits) * 2
                if c.followed { s += 100 }
                if c.sources.contains(.liked) { s += 50 }
                if c.queries > 0 && c.hits == 0 { s -= 5 }
                return s + c.addedAt.timeIntervalSince1970 / 1e9
            }
            return keep(a) > keep(b)
        }
        creators = Dictionary(uniqueKeysWithValues: ranked.prefix(3200).map { ($0.secUid, $0) })
    }

    /// 解析 time_list：形如 "2026·11"、"2026-11"、"202611"；只有年份时视为全年
    static func months(from timeList: [String]) -> [Int]? {
        var out = Set<Int>()
        for s in timeList {
            let digits = s.split(whereSeparator: { !$0.isNumber }).map(String.init)
            if digits.count >= 2, let y = Int(digits[0]), let m = Int(digits[1]), (2016...2100).contains(y), (1...12).contains(m) {
                out.insert(YearMonth(year: y, month: m).index)
            } else if let d = digits.first, d.count == 6, let y = Int(d.prefix(4)), let m = Int(d.suffix(2)), (1...12).contains(m) {
                out.insert(YearMonth(year: y, month: m).index)
            } else if let d = digits.first, d.count == 4, let y = Int(d), (2016...2100).contains(y) {
                for m in 1...12 { out.insert(YearMonth(year: y, month: m).index) }
            }
        }
        return out.isEmpty ? nil : out.sorted()
    }

    static func years(from timeList: [String]) -> [Int]? {
        let ys = timeList.compactMap { s -> Int? in
            guard s.count >= 4, let y = Int(s.prefix(4)), (2016...2100).contains(y) else { return nil }
            return y
        }
        return ys.isEmpty ? nil : Array(Set(ys)).sorted()
    }
}

/// 已看过的作品 ID（用于“去除已看”）
struct SeenStore: Codable {
    private(set) var order: [String] = []
    private var set: Set<String> = []

    enum CodingKeys: String, CodingKey { case order }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        order = try c.decode([String].self, forKey: .order)
        set = Set(order)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(order, forKey: .order)
    }

    func contains(_ id: String) -> Bool { set.contains(id) }

    mutating func insert(_ id: String) {
        guard set.insert(id).inserted else { return }
        order.append(id)
        if order.count > 30000 {
            let drop = order.prefix(5000)
            order.removeFirst(5000)
            for d in drop { set.remove(d) }
        }
    }

    var count: Int { order.count }
}
