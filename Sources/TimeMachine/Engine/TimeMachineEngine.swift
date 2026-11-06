import Foundation
import Observation

struct AccountRef: Equatable {
    var uid: String
    var secUid: String
}

/// 时光机推荐引擎。
///
/// 抖音没有“按发布时间刷推荐”的接口，这里的做法是：
/// 1. **创作者池**：推荐流作者、关注、喜欢、年代热梗搜索、相关推荐、视频中 @ 的人；
/// 2. **时间跳转 + 分层采样**：作品列表接口的 max_cursor 是毫秒时间戳。多月时间段里，
///    每次扫描挑一个“覆盖最少”的月份，从那个月月末往前翻，让结果均匀分布在整个时间段；
/// 3. **Thompson 采样挑创作者**：每位创作者“扫描后出片”的概率用 Beta 分布建模，
///    兼顾“已知高产的人”和“还没试过的新人”；
/// 4. **即时动态重排**：只提前排好 3 条，其余留在候选池里；每次切换视频都按最新的兴趣画像重新打分，
///    并对作者、内容分类、月份做打散；
/// 5. **反馈学习**：观看时长（含秒划）、点赞、收藏、不感兴趣都会实时更新兴趣画像。
///
/// 多个 worker 并发工作（请求节奏由桥接层统一控制），切换时间段时旧请求的结果会被丢弃。
@MainActor @Observable
final class TimeMachineEngine {
    enum Phase: Equatable {
        case idle
        case searching
        case waitingMore
        case exhausted
        case needsLogin
        case error(String)
    }

    struct Stats {
        var requests = 0
        var creatorsScanned = 0
        var hits = 0
        var feedPages = 0
    }

    private enum Action {
        case seedFollowing
        case seedLikes
        case feed
        case creator(Creator)
        case search(String)
        case related(String)
        case wait
    }

    private struct Candidate {
        var aweme: Aweme
        /// 与兴趣无关的静态分：热度 + 来源 + 同作者内排名
        var base: Double
        /// 固定的随机扰动（探索）
        var jitter: Double
        var source: CreatorSource?
        var keyword: String?
        /// true：翻创作者当年的作品找到的；false：直接从推荐流 / 搜索 / 相关推荐里刷到的
        var viaScan: Bool
    }

    private(set) var window: TimeWindow
    private(set) var items: [Aweme] = []
    private(set) var currentIndex = 0
    private(set) var phase: Phase = .idle
    private(set) var stats = Stats()
    private(set) var statusText = ""
    /// 正在做什么（给用户看的实时进度）
    private(set) var activity = ""
    private(set) var poolSize = 0
    private(set) var followingCount = 0
    /// 只看我关注的人
    private(set) var followOnly = false

    /// 未登录时抖音不提供创作者作品列表
    var postsBlocked: Bool { account == nil }
    var current: Aweme? { items.indices.contains(currentIndex) ? items[currentIndex] : nil }
    var aheadCount: Int { max(0, items.count - currentIndex - 1) }

    @ObservationIgnored let api: DouyinAPI
    @ObservationIgnored var account: AccountRef? {
        didSet {
            guard account != oldValue else { return }
            followDone = false
            likesDone = false
            followOffset = 0
            followMaxTime = 0
            likesCursor = 0
        }
    }
    @ObservationIgnored var hideSeen = true
    @ObservationIgnored var onItemsChanged: (() -> Void)?

    @ObservationIgnored private(set) var interest: InterestProfile
    @ObservationIgnored private(set) var pool: CreatorPool
    @ObservationIgnored private(set) var seen: SeenStore

    @ObservationIgnored private var candidates: [Candidate] = []
    @ObservationIgnored private var knownIDs = Set<String>()
    /// 本次航程中每位作者已进入队列的视频数（用于打散）
    @ObservationIgnored private var authorCount: [String: Int] = [:]
    /// 本次航程中每个月份已有的视频数（队列 + 候选），用于分层采样
    @ObservationIgnored private var monthCount: [Int: Int] = [:]
    /// 本次航程里被标记“不感兴趣”的作者
    @ObservationIgnored private var mutedAuthors = Set<String>()
    @ObservationIgnored private var fillTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var feedRefreshIndex = Int.random(in: 1...5)
    @ObservationIgnored private var feedPagesThisWindow = 0
    @ObservationIgnored private var searchesThisWindow = 0
    @ObservationIgnored private var searchDisabled = false
    @ObservationIgnored private var keywordQueue: [String] = []
    @ObservationIgnored private var relatedQueue: [String] = []
    @ObservationIgnored private var errorsInRow = 0
    /// 出错后的退避截止时间
    @ObservationIgnored private var backoffUntil = Date.distantPast
    @ObservationIgnored private var lastSearchAt = Date.distantPast
    @ObservationIgnored private var budget = 0
    @ObservationIgnored private var inflight = 0
    @ObservationIgnored private var inflightCreators = Set<String>()
    @ObservationIgnored private var stopFlag = false
    @ObservationIgnored private var exhaustedFlag = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    // 关注 / 喜欢导入进度
    @ObservationIgnored private var seedBusy = false
    @ObservationIgnored private var followDone = false
    @ObservationIgnored private var likesDone = false
    @ObservationIgnored private var followOffset = 0
    @ObservationIgnored private var followMaxTime = 0
    @ObservationIgnored private var likesCursor = 0

    private let workerCount = 3
    /// 提前排进播放队列的条数（其余留在候选池里，切换时按最新兴趣重排）
    private let aheadTarget = 3

    init(api: DouyinAPI, window: TimeWindow) {
        self.api = api
        self.window = window
        self.interest = Store.load(InterestProfile.self, "interest.json") ?? InterestProfile()
        self.pool = Store.load(CreatorPool.self, "creators.json") ?? CreatorPool()
        self.seen = Store.load(SeenStore.self, "seen.json") ?? SeenStore()
        self.poolSize = pool.count
        self.followingCount = pool.creators.values.filter(\.followed).count
    }

    // MARK: - 对外操作

    func travel(to w: TimeWindow) {
        generation += 1
        fillTask?.cancel()
        fillTask = nil
        window = w
        items = []
        currentIndex = 0
        candidates = []
        knownIDs = []
        authorCount = [:]
        monthCount = [:]
        mutedAuthors = []
        stats = Stats()
        feedPagesThisWindow = 0
        searchesThisWindow = 0
        searchDisabled = false
        keywordQueue = EraKeywords.keywords(for: w).shuffled()
        relatedQueue = []
        errorsInRow = 0
        backoffUntil = .distantPast
        inflight = 0
        inflightCreators = []
        activity = ""
        // 每次出发都重新扫描本时间段（已看过的会被去掉）；长期保留的只有创作者的活跃月份等信息
        pool.resetProgress(w)
        pool.touch(w)
        phase = .searching
        log("时光机出发：\(w)（创作者池 \(pool.count) 位\(followOnly ? "，只看关注" : "")）")
        onItemsChanged?()
        updateStatus()
        ensureBuffer(force: true)
    }

    func setFollowOnly(_ on: Bool) {
        guard on != followOnly else { return }
        followOnly = on
        travel(to: window)
    }

    func rescan() {
        travel(to: window)
    }

    @discardableResult
    func move(by delta: Int) -> Bool {
        let target = currentIndex + delta
        guard items.indices.contains(target) else {
            if delta > 0 { ensureBuffer(force: true) }
            return false
        }
        currentIndex = target
        // 用最新的兴趣画像补齐队列
        promote(force: false)
        ensureBuffer()
        return true
    }

    func insertNext(_ a: Aweme, andPlay: Bool) {
        if let existing = items.firstIndex(where: { $0.id == a.id }) {
            if andPlay { currentIndex = existing }
            onItemsChanged?()
            return
        }
        knownIDs.insert(a.id)
        authorCount[a.author.secUid, default: 0] += 1
        let pos = items.isEmpty ? 0 : min(items.count, currentIndex + 1)
        items.insert(a, at: pos)
        if andPlay { currentIndex = pos }
        onItemsChanged?()
    }

    func updateItem(_ a: Aweme) {
        if let i = items.firstIndex(where: { $0.id == a.id }) { items[i] = a }
    }

    func continueSearching() {
        if phase != .searching { phase = .idle }
        errorsInRow = 0
        backoffUntil = .distantPast
        searchDisabled = false
        ensureBuffer(force: true)
    }

    func ensureBuffer(force: Bool = false) {
        guard fillTask == nil else { return }
        guard force || aheadCount < aheadTarget || !poolHealthy else { return }
        if !force {
            switch phase {
            case .error, .exhausted, .needsLogin: return
            default: break
            }
        }
        let gen = generation
        fillTask = Task { [weak self] in
            await self?.fillLoop(gen)
            guard let self, self.generation == gen else { return }
            self.fillTask = nil
        }
    }

    /// 候选池是否足够支撑接下来的推荐（数量够、作者够分散）
    private var poolHealthy: Bool {
        guard candidates.count >= 10 else { return false }
        return Set(candidates.lazy.map(\.aweme.author.secUid)).count >= 5
    }

    // MARK: - 学习

    func recordWatch(_ a: Aweme, fraction: Double, seconds: Double) {
        interest.record(.watched(fraction: fraction, seconds: seconds), aweme: a)
        seen.insert(a.id)
        scheduleSave()
    }

    func record(_ signal: InterestProfile.Signal, _ a: Aweme) {
        interest.record(signal, aweme: a)
        scheduleSave()
    }

    /// 不感兴趣：强烈降低这个作者 / 话题 / 分类的权重，并把这位作者排在队列里的视频撤掉
    func notInterested(_ a: Aweme) {
        interest.record(.notInterested, aweme: a)
        seen.insert(a.id)
        mutedAuthors.insert(a.author.secUid)
        candidates.removeAll { $0.aweme.author.secUid == a.author.secUid }
        let keep = items.prefix(currentIndex + 1)
        let ahead = items.dropFirst(currentIndex + 1).filter { $0.author.secUid != a.author.secUid }
        items = Array(keep) + ahead
        promote(force: false)
        scheduleSave()
        onItemsChanged?()
        ensureBuffer()
    }

    func resetLearning() {
        interest = InterestProfile()
        seen = SeenStore()
        saveNow()
    }

    func resetPool() {
        pool = CreatorPool()
        poolSize = 0
        followingCount = 0
        followDone = false
        likesDone = false
        saveNow()
    }

    var seenCount: Int { seen.count }
    /// 调试 / 自检用：本次航程各月份已找到的视频数
    var monthSpread: [Int: Int] { monthCount }
    var topTags: [String] { interest.topTags(8) }
    var topCategories: [String] { interest.topCategories(6) }

    // MARK: - 填充循环

    private func fillLoop(_ gen: Int) async {
        phase = .searching
        budget = items.isEmpty ? 160 : 40
        stopFlag = false
        exhaustedFlag = false
        updateStatus()
        await withTaskGroup(of: Void.self) { group in
            for w in 0..<workerCount {
                group.addTask { [weak self] in await self?.worker(w, gen) }
            }
        }
        guard generation == gen else { return }
        promote(force: true)
        activity = ""
        if phase == .searching {
            if items.isEmpty {
                if postsBlocked && !window.touchesRecent {
                    phase = .needsLogin
                } else {
                    phase = exhaustedFlag ? .exhausted : .waitingMore
                }
            } else if aheadCount < 1 && candidates.isEmpty {
                phase = exhaustedFlag ? .exhausted : .waitingMore
            } else {
                phase = .idle
            }
        }
        updateStatus()
        scheduleSave()
    }

    private func worker(_ id: Int, _ gen: Int) async {
        if id > 0 { try? await Task.sleep(nanoseconds: UInt64(id) * 250_000_000) }
        var idleSpins = 0
        while generation == gen, !stopFlag, budget > 0, !Task.isCancelled {
            promote(force: false)
            if aheadCount >= aheadTarget && poolHealthy { return }
            let backoff = backoffUntil.timeIntervalSinceNow
            if backoff > 0 {
                try? await Task.sleep(nanoseconds: UInt64(min(backoff, 30) * 1_000_000_000))
                continue
            }
            guard let action = nextAction() else {
                if inflight > 0 && idleSpins < 40 {
                    idleSpins += 1
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    continue
                }
                exhaustedFlag = true
                return
            }
            if case .wait = action {
                try? await Task.sleep(nanoseconds: 500_000_000)
                continue
            }
            idleSpins = 0
            budget -= 1
            inflight += 1
            let before = knownIDs.count
            do {
                try await perform(action, gen)
                if generation == gen { errorsInRow = 0 }
            } catch is CancellationError {
                // 切换了时间段，忽略
            } catch {
                if generation == gen { handle(error, action) }
            }
            inflight -= 1
            guard generation == gen else { return }
            if knownIDs.count > before { promote(force: false) }
            updateStatus()
        }
    }

    private func handle(_ error: Error, _ action: Action) {
        let e = error as? DouyinError
        switch action {
        case .creator(let c):
            var p = pool.progress(window, c.secUid) ?? WindowProgress()
            p.exhausted = true
            pool.setProgress(p, window, c.secUid)
        case .seedFollowing:
            followDone = true
            seedBusy = false
        case .seedLikes:
            likesDone = true
            seedBusy = false
        case .search:
            searchDisabled = true
        case .feed, .related, .wait:
            break
        }
        errorsInRow += 1
        if errorsInRow >= 2 {
            backoffUntil = Date().addingTimeInterval(min(30, pow(2, Double(errorsInRow - 1))))
        }
        logWarn("请求失败：\(error.localizedDescription)")
        if errorsInRow >= 6 {
            stopFlag = true
            let blocked = (e?.isEmpty ?? false) || e == .notLoggedIn
            phase = .error(blocked
                ? "抖音暂时拒绝了请求，可能触发了安全验证。请打开「抖音网页」完成验证后点「继续寻找」。"
                : "网络请求连续失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 行动选择

    private func nextAction() -> Action? {
        guard let acct = account else {
            if window.touchesRecent && feedPagesThisWindow < 80 { return .feed }
            return nil
        }

        let seededRecently = pool.seededAt[acct.uid].map { Date().timeIntervalSince($0) < 86400 } ?? false
        if !seededRecently && !seedBusy {
            if !followDone { return .seedFollowing }
            if !likesDone { return .seedLikes }
        }

        var eligible = pool.eligible(for: window).filter {
            !inflightCreators.contains($0.secUid) && !mutedAuthors.contains($0.secUid)
        }
        if followOnly {
            eligible = eligible.filter(\.followed)
            if !eligible.isEmpty { return .creator(pickCreator(eligible)) }
            return (seedBusy || inflight > 0) ? .wait : nil
        }

        let r = Double.random(in: 0..<1)
        if !relatedQueue.isEmpty && r < 0.1 {
            return .related(relatedQueue.removeFirst())
        }
        // 搜索是最容易触发安全验证的接口：每个时间段最多 6 次，两次之间至少隔 15 秒
        let canSearch = !searchDisabled && searchesThisWindow < 6 && !keywordQueue.isEmpty
            && Date().timeIntervalSince(lastSearchAt) > 15
        let searchChance = window.touchesRecent ? 0.05 : (stats.hits < 6 ? 0.3 : 0.1)
        if canSearch && r >= 0.1 && r < 0.1 + searchChance {
            return .search(keywordQueue.removeFirst())
        }
        let wantFeed = eligible.count < 15 || (window.touchesRecent && r > 0.6) || r > 0.96
        if wantFeed && feedPagesThisWindow < 30 { return .feed }
        if !eligible.isEmpty { return .creator(pickCreator(eligible)) }
        if canSearch { return .search(keywordQueue.removeFirst()) }
        if !relatedQueue.isEmpty { return .related(relatedQueue.removeFirst()) }
        if feedPagesThisWindow < 30 { return .feed }
        if seedBusy || inflight > 0 { return .wait }
        return nil
    }

    /// Thompson 采样：每位创作者“扫描一次能出片”的概率 θ ~ Beta(α, β)，
    /// 抽样后取最大者。高产的人更常被选中，没试过的新人也有机会。
    private func pickCreator(_ list: [Creator]) -> Creator {
        let sample = list.count > 400 ? Array(list.shuffled().prefix(400)) : list
        var backlog: [String: Int] = [:]
        for c in candidates { backlog[c.aweme.author.secUid, default: 0] += 1 }
        let range = window.monthIndices

        var best = sample[0]
        var bestValue = -Double.infinity
        for c in sample {
            let good = Double(c.goodScans ?? (c.hits > 0 ? 1 : 0))
            let bad = Double(max(0, c.queries - (c.goodScans ?? (c.hits > 0 ? 1 : 0))))
            var alpha = 1 + good
            var beta = 1 + bad * 0.7
            // 先验：已知在这个时间段发过作品 → 几乎必中
            if let ms = c.activeMonths {
                if ms.contains(where: { range.contains($0) }) { alpha += 6 }
            } else if let ys = c.activeYears, ys.contains(where: { window.years.contains($0) }) {
                alpha += 2
            }
            if c.followed { alpha += 1 }
            if c.sources.contains(.liked) { alpha += 1 }
            if c.sources.contains(.search) { alpha += 1 }      // 年代热梗搜出来的，多半是当年活跃的
            if c.sources.contains(.mention) { alpha += 0.5 }
            let affinity = interest.authors[c.secUid] ?? 0
            if affinity > 0 { alpha += min(3, affinity * 0.4) } else { beta += min(4, -affinity * 0.5) }

            var value = Self.betaSample(alpha, beta)
            // 已经积压了好几条候选的创作者先别继续翻，把请求留给新的创作者
            let pending = backlog[c.secUid, default: 0] + (authorCount[c.secUid] ?? 0)
            if pending >= 3 { value *= 0.15 }
            if value > bestValue { bestValue = value; best = c }
        }
        return best
    }

    // MARK: - 执行（每个分支在 await 之后都要检查 generation，避免把旧时间段的结果写进来）

    private func perform(_ action: Action, _ gen: Int) async throws {
        let w = window
        stats.requests += 1
        switch action {
        case .wait:
            return
        case .seedFollowing:
            guard let acct = account else { return }
            seedBusy = true
            defer { seedBusy = false }
            activity = "正在导入你的关注列表…"
            let r = try await api.following(userId: acct.uid, secUid: acct.secUid, offset: followOffset, maxTime: followMaxTime)
            var fresh = 0
            for u in r.users {
                if pool.creators[u.secUid]?.followed != true { fresh += 1 }
                pool.add(u, source: .following, followed: true)
                interest.record(.seed, authorSec: u.secUid, tags: [])
            }
            followingCount = pool.creators.values.filter(\.followed).count
            log("导入关注：+\(r.users.count)")
            followOffset += r.users.count
            if r.minTime > 0 { followMaxTime = r.minTime }
            if !r.hasMore || r.users.isEmpty || fresh == 0 || followOffset >= 600 { followDone = true }
        case .seedLikes:
            guard let acct = account else { return }
            seedBusy = true
            defer { seedBusy = false }
            activity = "正在学习你喜欢的视频…"
            let page = try await api.likedPosts(secUid: acct.secUid, maxCursor: likesCursor)
            for a in page.awemes {
                pool.add(a.author, source: .liked)
                interest.record(.seed, aweme: a)
            }
            if generation == gen { addHits(page.awemes.filter { w.contains($0.createTime) }, source: .liked) }
            log("导入喜欢：+\(page.awemes.count)")
            if page.hasMore && page.maxCursor > 0 && likesCursor == 0 {
                likesCursor = page.maxCursor
            } else {
                likesDone = true
                if followDone { pool.seededAt[acct.uid] = Date() }
            }
        case .feed:
            activity = "正在浏览推荐流…"
            let idx = feedRefreshIndex
            feedRefreshIndex += 1
            let list = try await api.recommendFeed(refreshIndex: idx)
            for a in list where !a.isAd {
                pool.add(a.author, source: .feed)
                for m in a.mentions { pool.add(m, source: .mention) }
            }
            guard generation == gen else { return }
            feedPagesThisWindow += 1
            stats.feedPages += 1
            let hits = addHits(list.filter { w.contains($0.createTime) }, source: .feed)
            log("推荐流 #\(idx)：\(list.count) 条，命中 \(hits)")
        case .creator(let c):
            try await scanCreator(c, w, gen)
        case .search(let kw):
            searchesThisWindow += 1
            lastSearchAt = Date()
            activity = "正在搜索「\(kw)」的当年爆款…"
            let list = try await api.searchVideos(keyword: kw, sortType: w.touchesRecent ? 0 : 1)
            for a in list { pool.add(a.author, source: .search) }
            guard generation == gen else { return }
            let hits = addHits(list.filter { w.contains($0.createTime) }, source: .search, keyword: kw)
            log("搜索「\(kw)」：\(list.count) 条，命中 \(hits)")
        case .related(let id):
            activity = "正在顺藤摸瓜找相似创作者…"
            let list = try await api.related(awemeId: id)
            for a in list { pool.add(a.author, source: .related) }
            guard generation == gen else { return }
            let hits = addHits(list.filter { w.contains($0.createTime) }, source: .related)
            log("相关推荐：\(list.count) 条，命中 \(hits)")
        }
        poolSize = pool.count
    }

    /// 在时间段里为这位创作者挑一个月份：优先“全局覆盖最少”的月份，且这位创作者还没翻过、并且（若已知）当月发过作品
    private func chooseMonth(for c: Creator, _ w: TimeWindow, _ prog: WindowProgress) -> Int? {
        let covered = Set(prog.coveredMonths ?? [])
        var months = Array(w.monthIndices).filter { !covered.contains($0) }
        if let active = c.activeMonths {
            let set = Set(active)
            months = months.filter { set.contains($0) }
        }
        if let first = c.firstPostTS {
            let firstMonth = YearMonth(timestamp: first).index
            months = months.filter { $0 >= firstMonth }
        }
        guard !months.isEmpty else { return nil }
        if months.count == 1 { return months[0] }
        let weights = months.map { 1.0 / Double(1 + monthCount[$0, default: 0]) }
        var r = Double.random(in: 0..<weights.reduce(0, +))
        for (i, wt) in weights.enumerated() {
            r -= wt
            if r <= 0 { return months[i] }
        }
        return months.last
    }

    private func scanCreator(_ c: Creator, _ w: TimeWindow, _ gen: Int) async throws {
        inflightCreators.insert(c.secUid)
        defer { inflightCreators.remove(c.secUid) }
        var prog = pool.progress(w, c.secUid) ?? WindowProgress()
        guard let month = chooseMonth(for: c, w, prog) else {
            prog.exhausted = true
            pool.setProgress(prog, w, c.secUid)
            return
        }
        let monthYM = YearMonth(index: month)
        let cursor = prog.monthCursor?[String(month)] ?? monthYM.endCursorMs
        activity = "正在翻阅 @\(c.nickname) 在 \(monthYM) 前后的作品…"
        let page = try await api.userPosts(secUid: c.secUid, maxCursor: cursor)

        // 创作者本身的信息与时间段无关，任何时候都可以更新
        let years = CreatorPool.years(from: page.timeList)
        let months = CreatorPool.months(from: page.timeList)
        if let first = page.awemes.first?.author {
            pool.add(first, source: c.primarySource)
        }
        let dated = page.awemes.filter { !$0.isTop }
        let inWindow = page.awemes.filter { w.contains($0.createTime) }
        pool.update(c.secUid) { cr in
            cr.queries += 1
            if let years { cr.activeYears = years }
            if let months { cr.activeMonths = months }
            if !inWindow.isEmpty { cr.goodScans = (cr.goodScans ?? 0) + 1 }
            if let oldest = dated.map(\.createTime).min(), !page.hasMore {
                cr.firstPostTS = oldest
            } else if dated.isEmpty && !page.hasMore {
                // 这个月月末之前一条作品都没有 → 第一条作品在这之后
                cr.firstPostTS = max(cr.firstPostTS ?? 0, monthYM.adding(months: 1).startTimestamp)
            }
        }
        guard generation == gen else { return }

        if prog.pages == 0 { stats.creatorsScanned += 1 }
        prog.pages += 1
        let hits = addHits(inWindow, source: c.followed ? .following : c.primarySource, viaScan: true)
        for a in inWindow {
            for m in a.mentions { pool.add(m, source: .mention) }
        }
        if hits > 0, relatedQueue.count < 20, let pick = inWindow.max(by: { $0.diggCount < $1.diggCount }) {
            relatedQueue.append(pick.id)
        }
        prog.hits += hits
        if hits > 0 { pool.update(c.secUid) { $0.hits += hits } }

        // 记录这一页覆盖了哪些月份
        var covered = Set(prog.coveredMonths ?? [])
        var cursors = prog.monthCursor ?? [:]
        if let oldest = dated.map(\.createTime).min() {
            let oldestMonth = YearMonth(timestamp: oldest).index
            if page.hasMore && oldestMonth >= month {
                // 这个月一页没翻完：下次接着翻
                let next = page.maxCursor > 0 ? min(page.maxCursor, oldest * 1000) : oldest * 1000
                if next < cursor { cursors[String(month)] = next } else { covered.insert(month) }
            } else {
                let low = page.hasMore ? oldestMonth + 1 : w.from.index
                for m in max(low, w.from.index)...month { covered.insert(m) }
                cursors[String(month)] = nil
            }
        } else {
            // 这个月月末之前没有作品了
            for m in w.from.index...month { covered.insert(m) }
        }
        // time_list 告诉我们这个时间段一个月都没发过：直接结束
        if let months, !months.contains(where: { w.monthIndices.contains($0) }) {
            prog.exhausted = true
        }
        prog.coveredMonths = covered.sorted()
        prog.monthCursor = cursors.isEmpty ? nil : cursors
        if covered.count >= w.monthCount || prog.pages >= 10 { prog.exhausted = true }
        if !prog.exhausted, chooseMonth(for: pool.creators[c.secUid] ?? c, w, prog) == nil { prog.exhausted = true }
        pool.setProgress(prog, w, c.secUid)
        log("扫描 @\(c.nickname)（\(monthYM.short)）：\(page.awemes.count) 条，命中 \(hits)")
    }

    /// 把一批命中的视频加入候选池。同一批里按点赞数排名，排名靠后的降权（同一个人的作品优先推最好的）
    @discardableResult
    private func addHits(_ list: [Aweme], source: CreatorSource?, keyword: String? = nil, viaScan: Bool = false) -> Int {
        var added = 0
        let ranked = list.filter(\.isPlayable).sorted { $0.diggCount > $1.diggCount }
        var rankByAuthor: [String: Int] = [:]
        for a in ranked {
            let sec = a.author.secUid
            guard !knownIDs.contains(a.id), !mutedAuthors.contains(sec) else { continue }
            if hideSeen && seen.contains(a.id) { continue }
            if followOnly && pool.creators[sec]?.followed != true { continue }
            knownIDs.insert(a.id)
            stats.hits += 1
            let rank = rankByAuthor[sec, default: 0]
            rankByAuthor[sec] = rank + 1

            var base = log10(Double(a.diggCount) + 10) * 0.5
            switch source {
            case .following?: base += 1.2
            case .liked?: base += 0.9
            case .feed?: base += 0.5
            case .search?: base += 0.5
            case .mention?: base += 0.3
            case .related?: base += 0.3
            default: break
            }
            if source != .following && pool.creators[sec]?.followed == true { base += 0.8 }
            base -= min(2, Double(rank) * 0.25)
            candidates.append(Candidate(aweme: a, base: base, jitter: Double.random(in: 0...0.8),
                                        source: source, keyword: keyword, viaScan: viaScan))
            monthCount[a.monthIndex, default: 0] += 1
            added += 1
        }
        return added
    }

    /// 即时动态打分：静态分 + 当前兴趣画像 + 打散惩罚
    private func liveScore(_ c: Candidate) -> Double {
        let a = c.aweme
        var s = c.base + c.jitter + interest.score(a) * 1.3
        s -= Double(authorCount[a.author.secUid, default: 0]) * 0.9
        // 内容分类打散：和最近两条同一大类就降权
        if let cat = a.primaryCategory {
            let lastCats = items.suffix(2).compactMap(\.primaryCategory)
            s -= Double(lastCats.filter { $0 == cat }.count) * 0.6
        }
        // 多月时间段：最近几条都在同一个月就降权，让时间分布更均匀
        if window.monthCount > 1 {
            let m = a.monthIndex
            s -= Double(items.suffix(4).filter { $0.monthIndex == m }.count) * 0.4
        }
        return s
    }

    private func reason(for c: Candidate) -> String {
        let a = c.aweme
        if c.source == .following || pool.creators[a.author.secUid]?.followed == true { return "你关注的人" }
        if (interest.authors[a.author.secUid] ?? 0) > 2 { return "你常看 TA 的视频" }
        if let m = interest.strongestMatch(a) { return "因为你爱看\(m)" }
        if a.diggCount >= 1_000_000 { return "当年爆款 · \(Fmt.count(a.diggCount))赞" }
        if c.viaScan {
            switch c.source {
            case .liked?: return "你点赞过 TA 的作品"
            case .search?: return "当年的热门创作者"
            case .mention?: return "被当年的视频 @ 过"
            case .related?: return "和你看过的内容相似"
            case .feed?: return "抖音给你推荐过 TA"
            default: return "时光机为你发现"
            }
        }
        switch c.source {
        case .liked?: return "你点赞过的视频"
        case .search?: return c.keyword.map { "当年热梗：\($0)" } ?? "当年热门"
        case .related?: return "相似内容"
        case .feed?: return "来自你的推荐流"
        default: return "时光机为你发现"
        }
    }

    /// 把候选挪进播放队列（只提前排 aheadTarget 条），并严格打散作者：
    /// - 硬规则：相邻两条绝不是同一个作者；
    /// - 软规则：最近 5 条里同一作者最多一次，除非用户马上没得看了。
    private func promote(force final: Bool) {
        var changed = false
        while aheadCount < aheadTarget, !candidates.isEmpty {
            let urgent = aheadCount == 0
            if !urgent && !final && candidates.count < 3 { break }
            let last = items.last?.author.secUid
            let recent = items.suffix(5).map(\.author.secUid)
            var bestIdx: Int?
            var bestScore = -Double.infinity
            var bestRecent = false
            for (i, c) in candidates.enumerated() {
                let a = c.aweme.author.secUid
                if a == last { continue }
                let inRecent = recent.contains(a)
                var s = liveScore(c)
                if inRecent { s -= 4 }
                if s > bestScore { bestScore = s; bestIdx = i; bestRecent = inRecent }
            }
            guard let idx = bestIdx else { break }
            if bestRecent && !urgent { break }
            let c = candidates.remove(at: idx)
            var a = c.aweme
            a.reason = reason(for: c)
            authorCount[a.author.secUid, default: 0] += 1
            items.append(a)
            log("入队 #\(items.count)：@\(a.author.nickname)（\(Fmt.dayFormatter.string(from: a.date))\(a.primaryCategory.map { " · \($0)" } ?? "")）\(a.reason ?? "")")
            changed = true
        }
        if changed { onItemsChanged?() }
    }

    private func updateStatus() {
        switch phase {
        case .searching:
            if postsBlocked {
                statusText = "未登录 · 正在推荐流里筛选 \(window) 的视频（已翻 \(stats.feedPages) 页）"
            } else {
                statusText = "已扫描 \(stats.creatorsScanned) 位创作者，找到 \(stats.hits) 条视频"
            }
        case .idle:
            statusText = "候选池里还有 \(candidates.count) 条"
        case .waitingMore:
            statusText = items.isEmpty ? "这个时间段暂时没找到视频，可以继续寻找或换个时间" : "暂时找不到更多，可以继续寻找"
        case .exhausted:
            statusText = followOnly
                ? "你关注的人在 \(window) 的作品都看完了"
                : "已经翻遍创作者池，这个时间段的内容都看完啦"
        case .needsLogin:
            statusText = "登录后才能回到 \(window)"
        case .error(let m):
            statusText = m
        }
    }

    // MARK: - 工具

    /// Beta(α, β) 抽样（两次 Gamma 抽样）
    static func betaSample(_ a: Double, _ b: Double) -> Double {
        let x = gammaSample(a), y = gammaSample(b)
        return x / max(x + y, 1e-12)
    }

    /// Marsaglia–Tsang Gamma 抽样（shape ≥ 1；shape < 1 时用提升法）
    static func gammaSample(_ shape: Double) -> Double {
        if shape < 1 {
            return gammaSample(shape + 1) * pow(Double.random(in: Double.ulpOfOne..<1), 1 / shape)
        }
        let d = shape - 1.0 / 3.0
        let c = 1.0 / sqrt(9 * d)
        while true {
            var x = 0.0, v = 0.0
            repeat {
                // Box–Muller 标准正态
                let u1 = Double.random(in: Double.ulpOfOne..<1), u2 = Double.random(in: 0..<1)
                x = sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
                v = 1 + c * x
            } while v <= 0
            v = v * v * v
            let u = Double.random(in: Double.ulpOfOne..<1)
            if u < 1 - 0.0331 * x * x * x * x { return d * v }
            if log(u) < 0.5 * x * x + d * (1 - v + log(v)) { return d * v }
        }
    }

    // MARK: - 持久化

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        Store.save(interest, "interest.json")
        Store.save(pool, "creators.json")
        Store.save(seen, "seen.json")
    }
}
