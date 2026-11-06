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
        case search(String, offset: Int)
        case topic(name: String, id: String, cursor: Int, sort: Int)
        case related(String)
        case wait
    }

    private struct Candidate {
        var aweme: Aweme
        /// 热度：log10(点赞 + 2×评论 + 2×分享 + 1)
        var heat: Double
        /// 来源加分（很小，热度才是主角）
        var sourceBonus: Double
        /// 固定的随机扰动（探索）
        var jitter: Double
        var source: CreatorSource?
        var keyword: String?
        /// true：翻创作者当年的作品找到的；false：直接从推荐流 / 搜索 / 相关推荐里刷到的
        var viaScan: Bool
        /// 入池时就命中的时间线热点词（用于平衡候选池里热点内容的占比）
        var curatedEra: String? = nil
        /// 普通人的日常内容（非机构、粉丝不过百万、互动适中、偏生活类）
        var amateur: Bool = false
    }

    /// 推荐页里的三类“位置”：当时的热点 / 当时的热门 / 可能感兴趣的普通人
    private enum Slot: String { case era, hot, amateur }

    /// 偏生活日常、普通人常拍的内容分类
    private static let everydayCategories: Set<String> = [
        "舞蹈", "随拍", "生活记录", "日常vlog", "萌宠", "宠物", "动物", "美食", "颜值", "搞笑", "情感", "运动", "健身",
        "穿搭", "时尚", "校园", "旅行", "旅游", "亲子", "音乐", "才艺", "手工", "三农", "家居", "美妆", "彩妆",
    ]

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
    /// 是否保存“最近出现过”的记录（自检时关闭，避免测试刷到的视频影响真实使用）
    @ObservationIgnored var persistFreshness = true
    @ObservationIgnored var onItemsChanged: (() -> Void)?

    @ObservationIgnored private(set) var interest: InterestProfile
    @ObservationIgnored private(set) var pool: CreatorPool
    @ObservationIgnored private(set) var seen: SeenStore
    @ObservationIgnored private var topicDirectory: [String: String]
    /// 最近出现过的作者 / 视频（跨会话保存），让每次刷新都有新鲜感
    @ObservationIgnored private var recentAuthors: [String: Date]
    @ObservationIgnored private var recentVideos: [String: Date]

    @ObservationIgnored private var candidates: [Candidate] = []
    @ObservationIgnored private var knownIDs = Set<String>()
    /// 本次航程中每位作者已进入队列的视频数（用于打散）
    @ObservationIgnored private var authorCount: [String: Int] = [:]
    /// 本次航程中每个月份已有的视频数（队列 + 候选），用于分层采样
    @ObservationIgnored private var monthCount: [Int: Int] = [:]
    /// 本次航程里被标记“不感兴趣”的作者
    @ObservationIgnored private var mutedAuthors = Set<String>()
    /// 本次航程每位作者进入候选池的视频数（每人最多 3 条，保证广度）
    @ObservationIgnored private var authorFound: [String: Int] = [:]
    /// 本次航程所有候选的热度（已排序），用来算“在这个时间段里有多火”的百分位
    @ObservationIgnored private var heatSamples: [Double] = []
    /// 因为“符合偏好”而入队的视频（用来限制连续投喂同类）
    @ObservationIgnored private var prefDrivenIDs = Set<String>()
    /// 个性化程度：0 = 只看热度与多样性，1 = 更多按偏好推荐（默认 0.35：热门多元为主）
    @ObservationIgnored var prefWeight: Double = 0.35
    @ObservationIgnored private var fillTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var feedRefreshIndex = Int.random(in: 1...5)
    @ObservationIgnored private var feedPagesThisWindow = 0
    @ObservationIgnored private var searchesThisWindow = 0
    @ObservationIgnored private var searchDisabled = false
    /// 待搜索的关键词：当月热点 → 话题滚雪球发现的热门话题 → 季节性话题
    @ObservationIgnored private var searchQueue: [(kw: String, offset: Int)] = []
    @ObservationIgnored private var searchedKeywords = Set<String>()
    /// 话题滚雪球：本次航程命中视频里的话题热度
    @ObservationIgnored private var topicWeights: [String: Double] = [:]
    @ObservationIgnored private var topicCounts: [String: Int] = [:]
    @ObservationIgnored private var topicIDs: [String: String] = [:]
    @ObservationIgnored private var topicQueue: [(name: String, id: String, cursor: Int, sort: Int)] = []
    @ObservationIgnored private var topicAuthors: [String: Set<String>] = [:]
    /// 每个话题本次航程已经翻过的页数（每个话题最多 2 页，避免一个热门话题灌满候选池）
    @ObservationIgnored private var topicPages: [String: Int] = [:]
    /// 本时间段值得翻话题页的热点词；还没拿到话题 ID 的先挂着，一旦在任何视频里见到就立刻加入
    @ObservationIgnored private var pendingEraTopics = Set<String>()
    /// 话题目录（话题名 → ID），从刷到的每一条视频里收集，长期保存
    @ObservationIgnored private var exploredTopics = Set<String>()
    @ObservationIgnored private var topicsThisWindow = 0
    @ObservationIgnored private var eraTermCache: [Int: [String]] = [:]
    /// 已入队视频命中的时代热点（用于避免连续几条都是同一个热点）
    @ObservationIgnored private var itemEraTerm: [String: String] = [:]
    /// 已入队视频占的推荐页位置
    @ObservationIgnored private var itemSlot: [String: Slot] = [:]
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
    private static let useSearch = false
    /// 提前排进播放队列的条数（其余留在候选池里，切换时按最新兴趣重排）
    private let aheadTarget = 3

    init(api: DouyinAPI, window: TimeWindow) {
        self.api = api
        self.window = window
        self.interest = Store.load(InterestProfile.self, "interest.json") ?? InterestProfile()
        self.pool = Store.load(CreatorPool.self, "creators.json") ?? CreatorPool()
        self.seen = Store.load(SeenStore.self, "seen.json") ?? SeenStore()
        self.topicDirectory = Store.load([String: String].self, "topics.json") ?? [:]
        let weekAgo = Date().addingTimeInterval(-7 * 86400)
        self.recentAuthors = (Store.load([String: Date].self, "recent_authors.json") ?? [:]).filter { $0.value > weekAgo }
        self.recentVideos = (Store.load([String: Date].self, "recent_videos.json") ?? [:]).filter { $0.value > weekAgo }
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
        authorFound = [:]
        heatSamples = []
        prefDrivenIDs = []
        stats = Stats()
        feedPagesThisWindow = 0
        searchesThisWindow = 0
        searchDisabled = false
        searchQueue = EraKeywords.keywords(for: w).map { (kw: $0, offset: 0) }
        searchedKeywords = []
        topicWeights = [:]
        topicCounts = [:]
        topicIDs = [:]
        topicQueue = []
        topicAuthors = [:]
        topicPages = [:]
        exploredTopics = []
        topicsThisWindow = 0
        itemEraTerm = [:]
        itemSlot = [:]
        pendingEraTopics = Set(EraKeywords.topicTerms(for: w))
        queueEraTopics()
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
        markShown(items[target])
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

    /// 记录“真正展示过”的作者与视频（用于跨会话的新鲜度）
    func markShown(_ a: Aweme) {
        let now = Date()
        recentAuthors[a.author.secUid] = now
        recentVideos[a.id] = now
        if recentVideos.count > 6000 {
            for (k, _) in recentVideos.sorted(by: { $0.value < $1.value }).prefix(1000) { recentVideos[k] = nil }
        }
        if recentAuthors.count > 4000 {
            for (k, _) in recentAuthors.sorted(by: { $0.value < $1.value }).prefix(800) { recentAuthors[k] = nil }
        }
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
        // 热点内容很多时，至少还要有几条“当时的其他热门”可选，否则会清一色
        if candidates.contains(where: { $0.curatedEra != nil }) && candidates.filter({ $0.curatedEra == nil }).count < 4 { return false }
        return Set(candidates.lazy.map(\.aweme.author.secUid)).count >= 8
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
            // 用户正在完成抖音验证时，后台完全暂停，避免继续累积风控
            if api.bridge.verificationNeeded {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }
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
        case .topic:
            topicQueue.removeAll()
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
            if !eligible.isEmpty { return .creator(pickCreator(eligible, amateur: false)) }
            return (seedBusy || inflight > 0) ? .wait : nil
        }

        let r = Double.random(in: 0..<1)
        // 开局提速：前几次扫描优先挑“已知在这个时间段发过作品”的创作者，几乎一扫一个准。
        // 但热点话题页先翻两页（时代感的主要来源），两者由不同的并发请求同时进行
        let topicsFirst = !window.touchesRecent && topicsThisWindow < 2 && !topicQueue.isEmpty
        if !topicsFirst && stats.creatorsScanned < 6 && r < 0.8 {
            let range = window.monthIndices
            let known = eligible.filter { c in c.activeMonths?.contains(where: { range.contains($0) }) ?? false }
            let fresh = known.filter { recentAuthors[$0.secUid] == nil }
            if let pick = (fresh.isEmpty ? known : fresh).randomElement() { return .creator(pick) }
        }
        // 搜索与话题页是找“当时大家在看什么”最有效的途径；搜索最容易触发安全验证，所以限频：
        // 每个时间段最多 12 次，两次之间至少隔 8 秒
        // 后台不再使用搜索：抖音搜索极易触发人机验证，而且会在后台页面里留下待完成的验证码，
        // 导致用户查看评论回复时连续弹验证。找时代内容改用更稳定的话题页。
        let canSearch = Self.useSearch && !searchDisabled && searchesThisWindow < 12 && !searchQueue.isEmpty
            && Date().timeIntervalSince(lastSearchAt) > 8
        // 候选池里热点已经过半时先不翻话题页，去补充当时的其他热门内容
        let eraHeavy = candidates.count >= 6 && eraShare > 0.45
        // 普通人的日常内容不足时，优先去扫普通创作者（推荐页里本来就有大量这类视频）
        let amateurShare = candidates.isEmpty ? 0 : Double(candidates.filter(\.amateur).count) / Double(candidates.count)
        if !eligible.isEmpty && candidates.count >= 4 && amateurShare < 0.3 && r < 0.6 {
            return .creator(pickCreator(eligible, amateur: true))
        }
        let canTopic = !topicQueue.isEmpty && topicsThisWindow < 20 && (!eraHeavy || topicsThisWindow < 2)
        // 较早的时间段：话题页是找“当时大家在看什么”最稳的入口（搜索很容易被风控挂住）
        if canTopic && !window.touchesRecent && (topicsThisWindow < 4 || r < 0.5) { return nextTopic() }
        // 还没有可翻的热点话题时，先试一次搜索：搜索结果里会带出这些话题的 ID
        if canSearch && !window.touchesRecent && searchesThisWindow < 2 && topicQueue.isEmpty { return nextSearch() }
        if canTopic && r < 0.3 { return nextTopic() }
        if !relatedQueue.isEmpty && r >= 0.3 && r < 0.37 { return .related(relatedQueue.removeFirst()) }
        let searchChance = window.touchesRecent ? 0.08 : 0.35
        if canSearch && r >= 0.37 && r < 0.37 + searchChance { return nextSearch() }
        let wantFeed = eligible.count < 15 || (window.touchesRecent && r > 0.6) || r > 0.96
        if wantFeed && feedPagesThisWindow < 30 { return .feed }
        if !eligible.isEmpty {
            // 候选池里普通人的日常内容不足三成时，多去找普通创作者
            let wantAmateur = amateurShare < 0.3 && Double.random(in: 0..<1) < 0.65
            return .creator(pickCreator(eligible, amateur: wantAmateur))
        }
        if canSearch { return nextSearch() }
        if canTopic { return nextTopic() }
        if !relatedQueue.isEmpty { return .related(relatedQueue.removeFirst()) }
        if feedPagesThisWindow < 30 { return .feed }
        if seedBusy || inflight > 0 || (Self.useSearch && !searchQueue.isEmpty && !searchDisabled && searchesThisWindow < 12) { return .wait }
        return nil
    }

    private func nextSearch() -> Action {
        let q = searchQueue.removeFirst()
        return .search(q.kw, offset: q.offset)
    }

    private func nextTopic() -> Action {
        // 已经翻够 2 页的话题，队列里剩下的同名条目直接跳过
        while let first = topicQueue.first, (topicPages[first.name] ?? 0) >= 2 { topicQueue.removeFirst() }
        guard !topicQueue.isEmpty else { return .wait }
        let t = topicQueue.removeFirst()
        return .topic(name: t.name, id: t.id, cursor: t.cursor, sort: t.sort)
    }

    /// Thompson 采样：每位创作者“扫描一次能出片”的概率 θ ~ Beta(α, β)，再乘以“作品热度”系数，取最大者。
    /// 目标是广度：多扫不同的、作品火的创作者，而不是反复翻你已经喜欢的那几个人。
    private func pickCreator(_ list: [Creator], amateur: Bool) -> Creator {
        var choices = list
        if amateur {
            let amateurs = list.filter(\.isAmateur)
            if amateurs.count >= 20 { choices = amateurs }
        }
        let sample = choices.count > 400 ? Array(choices.shuffled().prefix(400)) : choices
        // 20% 的概率纯随机挑一位（探索），让每次出发都有意外的发现
        if Double.random(in: 0..<1) < 0.2, let any = sample.randomElement() { return any }
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
                if ms.contains(where: { range.contains($0) }) { alpha += 3 }
            } else if let ys = c.activeYears, ys.contains(where: { window.years.contains($0) }) {
                alpha += 1.5
            }
            // 探索：池子里还没扫过的人加一点分，避免总是翻那几个“已知高产”的人
            if c.queries == 0 { alpha += 1 }
            if c.sources.contains(.search) { alpha += 1.5 }   // 年代热梗按点赞搜出来的：当年的热门创作者
            if c.sources.contains(.mention) { alpha += 0.5 }
            if c.followed { alpha += 0.3 }
            if c.sources.contains(.liked) { alpha += 0.3 }
            // 偏好只轻微影响“挑谁来扫”，避免总在喜欢的几个人里打转；但讨厌的人明显降权
            let affinity = interest.authors[c.secUid] ?? 0
            if affinity > 0 { alpha += min(1, affinity * 0.1) } else { beta += min(4, -affinity * 0.5) }

            if amateur && affinity > 0 { alpha += min(2, affinity * 0.3) }   // 找普通人时，更看“你可能感兴趣”
            var value = Self.betaSample(alpha, beta)
            if amateur {
                // 找普通人：作品热度一般的人反而优先
                let modest = min(2, max(-2, 3.8 - (c.hotScore ?? 3.6)))
                value *= 1 + 0.2 * modest
            } else {
                // 作品越火的创作者越优先（没有数据时按中性处理）
                let hot = min(2.5, max(-2, (c.hotScore ?? 3.2) - 3.2))
                value *= 1 + 0.25 * hot
            }
            if (authorFound[c.secUid] ?? 0) >= 2 { value *= 0.1 }
            if let last = recentAuthors[c.secUid], Date().timeIntervalSince(last) < 3 * 86400 { value *= 0.5 }
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
            learnTopics(page.awemes)
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
            learnTopics(list)
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
        case .search(let kw, let offset):
            searchesThisWindow += 1
            lastSearchAt = Date()
            searchedKeywords.insert(kw)
            activity = "正在搜索「\(kw)」的当时爆款…"
            // 较早的时间段按“最多点赞”排序，更容易搜到当时的爆款
            let list = try await api.searchVideos(keyword: kw, offset: offset, sortType: w.touchesRecent ? 0 : 1)
            learnTopics(list)
            for a in list { pool.add(a.author, source: .search) }
            guard generation == gen else { return }
            let hits = addHits(list.filter { w.contains($0.createTime) }, source: .search, keyword: kw)
            // 命中率高的关键词继续翻页
            if hits >= 4 && offset < 30 { searchQueue.insert((kw: kw, offset: offset + 15), at: 0) }
            log("搜索「\(kw)」\(offset > 0 ? "第 \(offset / 15 + 1) 页" : "")：\(list.count) 条，命中 \(hits)")
        case .topic(let name, let id, let cursor, let sort):
            topicsThisWindow += 1
            activity = "正在翻看当时的热门话题 #\(name)…"
            let r = try await api.challengeVideos(chId: id, cursor: cursor, sortType: sort)
            learnTopics(r.awemes)
            for a in r.awemes { pool.add(a.author, source: .search) }
            guard generation == gen else { return }
            let hits = addHits(r.awemes.filter { w.contains($0.createTime) }, source: .search, keyword: "#\(name)")
            topicPages[name, default: 0] += 1
            // 命中多就继续往下翻，但每个话题最多 2 页
            if hits >= 3 && r.hasMore && r.cursor > cursor && (topicPages[name] ?? 0) < 2 {
                topicQueue.insert((name: name, id: id, cursor: r.cursor, sort: sort), at: 0)
            }
            log("话题 #\(name)（\(sort == 1 ? "排序1" : "排序0")\(cursor > 0 ? "，续" : "")）：\(r.awemes.count) 条，命中 \(hits)")
        case .related(let id):
            activity = "正在顺藤摸瓜找相似创作者…"
            let list = try await api.related(awemeId: id)
            learnTopics(list)
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
        learnTopics(page.awemes)

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
            if !dated.isEmpty {
                let mean = dated.map { Self.heat($0) }.reduce(0, +) / Double(dated.count)
                cr.hotScore = cr.hotScore.map { $0 * 0.6 + mean * 0.4 } ?? mean
            }
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
        // 广度优先：每位创作者在一个时间段里最多贡献 3 条、最多翻 3 页
        if covered.count >= w.monthCount || prog.pages >= 3 || (authorFound[c.secUid] ?? 0) >= 3 { prog.exhausted = true }
        if !prog.exhausted, chooseMonth(for: pool.creators[c.secUid] ?? c, w, prog) == nil { prog.exhausted = true }
        pool.setProgress(prog, w, c.secUid)
        log("扫描 @\(c.nickname)（\(monthYM.short)）：\(page.awemes.count) 条，命中 \(hits)")
    }

    static func heat(_ a: Aweme) -> Double {
        log10(Double(a.diggCount) + 2 * Double(a.commentCount) + 2 * Double(a.shareCount) + 1)
    }

    /// 这条视频在本次航程所有候选里的热度百分位（0~1），不同年代之间也可比
    private func hotPercentile(_ heat: Double) -> Double {
        guard heatSamples.count >= 8 else { return min(1, max(0, (heat - 2.5) / 3.5)) }
        var lo = 0, hi = heatSamples.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if heatSamples[mid] < heat { lo = mid + 1 } else { hi = mid }
        }
        return Double(lo) / Double(heatSamples.count)
    }

    /// 把一批命中的视频加入候选池。每位作者每批最多取最火的 2 条、整个航程最多 3 条——宁可多扫几个人，也不让一个人刷屏
    @discardableResult
    private func addHits(_ list: [Aweme], source: CreatorSource?, keyword: String? = nil, viaScan: Bool = false) -> Int {
        var added = 0
        // 按热度加权随机排序（Gumbel 技巧）：热的更容易被选上，但不总是同几条
        let ranked = list.filter(\.isPlayable)
            .map { a -> (Aweme, Double) in
                let g = -log(-log(Double.random(in: 0.0001..<0.9999)))
                return (a, Self.heat(a) * 1.5 + g)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
        var perBatch: [String: Int] = [:]
        for a in ranked {
            let sec = a.author.secUid
            guard !knownIDs.contains(a.id), !mutedAuthors.contains(sec) else { continue }
            if hideSeen && seen.contains(a.id) { continue }
            if recentVideos[a.id] != nil { continue }   // 最近 7 天已经展示过
            if followOnly && pool.creators[sec]?.followed != true { continue }
            if perBatch[sec, default: 0] >= 2 || authorFound[sec, default: 0] >= 3 { continue }
            knownIDs.insert(a.id)
            perBatch[sec, default: 0] += 1
            authorFound[sec, default: 0] += 1
            stats.hits += 1

            let h = Self.heat(a)
            var bonus = 0.0
            switch source {
            case .following?: bonus = 0.06
            case .liked?: bonus = 0.05
            case .search?: bonus = 0.05
            default: break
            }
            if source != .following && pool.creators[sec]?.followed == true { bonus += 0.04 }
            let creator = pool.creators[sec]
            let institution = a.author.isInstitution ?? creator?.isInstitution ?? false
            let followers = a.author.followerCount ?? creator?.followerCount
            // 普通人：非机构、粉丝不过百万、互动适中；新闻时政类不算
            let newsLike = a.primaryCategory.map { $0.contains("时政") || $0.contains("新闻") } ?? false
            let amateur = !institution && !newsLike && (followers.map { $0 < 1_000_000 } ?? true) && h >= 2.0 && h <= 5.3
            candidates.append(Candidate(aweme: a, heat: h, sourceBonus: bonus, jitter: Double.random(in: 0...0.45),
                                        source: source, keyword: keyword, viaScan: viaScan, curatedEra: curatedEraTerm(a),
                                        amateur: amateur))
            let pos = heatSamples.firstIndex(where: { $0 >= h }) ?? heatSamples.count
            heatSamples.insert(h, at: pos)
            monthCount[a.monthIndex, default: 0] += 1
            added += 1
            // 话题滚雪球：统计命中视频里的话题，越火的视频权重越高
            let w = 0.5 + hotPercentile(h)
            for tag in a.hashtags.prefix(6) where !EraKeywords.genericTags.contains(tag) && tag.count <= 16 {
                // 话题就是作者名字（如 #某某某）的不算时代话题
                if tag.contains(a.author.nickname) || a.author.nickname.contains(tag) { continue }
                topicCounts[tag, default: 0] += 1
                topicWeights[tag, default: 0] += w
                topicAuthors[tag, default: []].insert(sec)
                if let id = a.hashtagIDs?[tag] { topicIDs[tag] = id }
            }
        }
        if added > 0 { refreshTopicFrontier() }
        return added
    }

    /// 把当前最热的几个话题加入搜索 / 话题页队列（只在登录后有效）
    private func refreshTopicFrontier() {
        guard account != nil else { return }
        // 至少 3 位不同作者都在用的话题，才算得上“当时的热门话题”
        let top = topicWeights
            .filter { (topicCounts[$0.key] ?? 0) >= 3 && (topicAuthors[$0.key]?.count ?? 0) >= 3 }
            .sorted { $0.value > $1.value }
            .prefix(4)
        for (tag, _) in top {
            if let id = topicIDs[tag] ?? topicDirectory[tag], !exploredTopics.contains(tag) {
                exploredTopics.insert(tag)
                topicQueue.append((name: tag, id: id, cursor: 0, sort: 1))
            } else if !searchedKeywords.contains(tag) && !searchQueue.contains(where: { $0.kw == tag }) {
                searchQueue.insert((kw: tag, offset: 0), at: min(1, searchQueue.count))
            }
        }
    }

    /// 从任意一批视频里收集“话题名 → ID”，并把本时间段挂起的热点话题加入话题页队列
    private func learnTopics(_ list: [Aweme]) {
        var learned = false
        for a in list {
            for (name, id) in a.hashtagIDs ?? [:] where topicDirectory[name] == nil {
                topicDirectory[name] = id
                if pendingEraTopics.contains(name) { learned = true }
            }
        }
        if topicDirectory.count > 30000 {
            for k in topicDirectory.keys.shuffled().prefix(5000) { topicDirectory[k] = nil }
        }
        if learned { queueEraTopics() }
    }

    /// 本时间段的热点词里，已经知道话题 ID 的直接排进话题页队列（两种排序各翻一页）
    private func queueEraTopics() {
        guard account != nil else { return }
        for term in pendingEraTopics {
            guard let id = topicDirectory[term], !exploredTopics.contains(term) else { continue }
            exploredTopics.insert(term)
            pendingEraTopics.remove(term)
            let first = Bool.random() ? 1 : 0
            topicQueue.insert((name: term, id: id, cursor: 0, sort: first), at: Int.random(in: 0...min(2, topicQueue.count)))
            topicQueue.append((name: term, id: id, cursor: 0, sort: 1 - first))
        }
    }

    /// 只看时间线（不含滚雪球）的热点命中
    private func curatedEraTerm(_ a: Aweme) -> String? {
        let idx = a.monthIndex
        let terms: [String]
        if let cached = eraTermCache[idx] {
            terms = cached
        } else {
            terms = EraKeywords.terms(forMonth: idx)
            eraTermCache[idx] = terms
        }
        let text = a.desc + " " + a.hashtags.joined(separator: " ")
        return terms.first { !EraKeywords.weakTerms.contains($0) && EraKeywords.matches($0, in: text) }
    }

    /// 候选池里热点内容的占比
    private var eraShare: Double {
        guard !candidates.isEmpty else { return 0 }
        return Double(candidates.filter { $0.curatedEra != nil }.count) / Double(candidates.count)
    }

    /// 时代感：标题 / 话题命中当月热点 → 1；命中本次航程滚雪球出来的热门话题 → 按热度 0~0.8
    private func eraMatch(_ a: Aweme) -> (score: Double, term: String?) {
        let idx = a.monthIndex
        let terms: [String]
        if let cached = eraTermCache[idx] {
            terms = cached
        } else {
            terms = EraKeywords.terms(forMonth: idx)
            eraTermCache[idx] = terms
        }
        let text = a.desc + " " + a.hashtags.joined(separator: " ")
        var weak: String?
        for t in terms where EraKeywords.matches(t, in: text) {
            if EraKeywords.weakTerms.contains(t) { weak = weak ?? t } else { return (1.0, t) }
        }
        if let weak { return (0.5, weak) }
        guard let maxW = topicWeights.values.max(), maxW > 0 else { return (0, nil) }
        var best: (Double, String)?
        for tag in a.hashtags where (topicCounts[tag] ?? 0) >= 3 {
            let v = (topicWeights[tag] ?? 0) / maxW
            if v > (best?.0 ?? 0) { best = (v, tag) }
        }
        if let best { return (best.0 * 0.8, "#\(best.1)") }
        return (0, nil)
    }

    private struct ScoreParts {
        var total: Double
        var hot: Double
        var absolute: Double
        var pref: Double
        var novel: Bool
        var era: Double
        var eraTerm: String?
    }

    /// 即时打分 = 热度百分位（主）+ 偏好（辅，可调）+ 新鲜分类加分 + 打散惩罚
    private func liveScore(_ c: Candidate) -> ScoreParts {
        let a = c.aweme
        // 热度 = 一半看「在本次候选里的排名」，一半看「绝对互动量」（1 千 → 0，100 万 → 1），让真正的全网爆款排前面
        let absolute = min(1, max(0, (c.heat - 3) / 3))
        let hot = 0.5 * hotPercentile(c.heat) + 0.5 * absolute
        let pref = max(-1, min(1, interest.score(a) / 3))
        let era = eraMatch(a)
        // 时代感加分随“最近 3 条里已有几条时代热点”递减：热点占大头，但给当时的其他热门留位置
        let recentEra = items.suffix(3).filter { itemEraTerm[$0.id] != nil }.count
        let eraWeight = 0.5 * (1 - 0.3 * Double(recentEra))
        var s = hot + eraWeight * era.score + prefWeight * pref + c.sourceBonus + c.jitter
        // 热点不刷屏：
        // - 主题饱和：最近 10 条里同主题（如“疫情”）越多，扣得越多；
        // - 单个热点限量：同一个热点词（如“狂飙”）本次航程每出现一次，后面同类再降一档
        if let term = era.term {
            let theme = EraKeywords.theme(of: term)
            let recentThemes = items.suffix(10).compactMap { itemEraTerm[$0.id].map(EraKeywords.theme(of:)) }
            s -= Double(recentThemes.filter { $0 == theme }.count) * 0.2
            let plain = term.hasPrefix("#") ? String(term.dropFirst()) : term
            s -= Double(itemEraTerm.values.filter { ($0.hasPrefix("#") ? String($0.dropFirst()) : $0) == plain }.count) * 0.35
        }

        // 新鲜度：最近 10 条里没出现过的内容大类加分，鼓励多元
        var novel = false
        if let cat = a.primaryCategory {
            let recentCats = items.suffix(10).compactMap(\.primaryCategory)
            let n = recentCats.filter { $0 == cat }.count
            novel = n == 0
            s += n == 0 ? 0.25 : (n == 1 ? 0.1 : 0)
            if items.last?.primaryCategory == cat { s -= 0.25 }
            if items.suffix(5).filter({ $0.primaryCategory == cat }).count >= 2 { s -= 0.35 }
        } else {
            s += 0.1
        }
        // 不连续投喂“同口味”：最近两条都是因偏好入队的，这条若又主要靠偏好就降权
        if pref > 0.4 {
            let lastTwo = items.suffix(2).map(\.id)
            if lastTwo.count == 2 && lastTwo.allSatisfy({ prefDrivenIDs.contains($0) }) { s -= 0.4 }
        }
        // 跨会话新鲜度：最近几天出现过的作者降权（1 天内最多，7 天后恢复）
        if let last = recentAuthors[a.author.secUid] {
            let days = Date().timeIntervalSince(last) / 86400
            s -= max(0, 0.7 - 0.1 * days)
        }
        // 明确讨厌的作者无论滑块怎么调都压下去
        if (interest.authors[a.author.secUid] ?? 0) <= -3 { s -= 1 }
        s -= Double(authorCount[a.author.secUid, default: 0]) * 0.5
        if window.monthCount > 1 {
            let m = a.monthIndex
            s -= Double(items.suffix(4).filter { $0.monthIndex == m }.count) * 0.15
        }
        return ScoreParts(total: s, hot: hot, absolute: absolute, pref: pref, novel: novel, era: era.score, eraTerm: era.term)
    }

    private func reason(for c: Candidate, _ parts: ScoreParts, slot: Slot?) -> String {
        let a = c.aweme
        let followed = c.source == .following || pool.creators[a.author.secUid]?.followed == true
        if slot == .amateur, parts.era >= 0.6, let term = parts.eraTerm {
            return "当时的日常：\(term.hasPrefix("#") ? String(term.dropFirst()) : term)"
        }
        if parts.era >= 0.6, let term = parts.eraTerm { return "当时的热点：\(term)" }
        if slot == .amateur {
            let cat = a.cats.dropFirst().first ?? a.primaryCategory
            if followed { return "你关注的人" }
            if parts.pref > 0.2 { return "可能感兴趣 · \(cat ?? "日常")" }
            return "当时的日常\(cat.map { " · \($0)" } ?? "")"
        }
        if parts.hot >= 0.8 { return "当时的热门 · \(Fmt.count(a.diggCount))赞\(followed ? " · 你关注的" : "")" }
        if followed { return "你关注的人" }
        // 主要靠偏好入队
        if parts.pref > 0.4 && prefWeight * parts.pref >= parts.hot * 0.5 {
            if (interest.authors[a.author.secUid] ?? 0) > 2 { return "你常看 TA 的视频" }
            if let m = interest.strongestMatch(a) { return "因为你爱看\(m)" }
        }
        if parts.hot >= 0.8 { return "当时的热门 · \(Fmt.count(a.diggCount))赞" }
        if let kw = c.keyword, c.source == .search { return "当年热梗：\(kw)" }
        if parts.novel, let cat = a.primaryCategory, items.count >= 3 { return "换换口味 · \(cat)" }
        if c.viaScan {
            switch c.source {
            case .liked?: return "你点赞过 TA 的作品"
            case .search?: return "当年的热门创作者"
            case .mention?: return "被当年的视频 @ 过"
            case .related?: return "相似创作者"
            case .feed?: return "抖音给你推荐过 TA"
            default: return "时光机为你发现"
            }
        }
        switch c.source {
        case .liked?: return "你点赞过的视频"
        case .related?: return "相关推荐"
        case .feed?: return "来自你的推荐流"
        default: return "时光机为你发现"
        }
    }

    /// 推荐页配比：有时代热点时 热点 35% / 热门 30% / 普通人 35%，否则 热门 45% / 普通人 55%
    private func slotTargets() -> [Slot: Double] {
        let hasEra = !itemEraTerm.isEmpty || candidates.contains { $0.curatedEra != nil }
        return hasEra ? [.era: 0.35, .hot: 0.30, .amateur: 0.35] : [.hot: 0.45, .amateur: 0.55]
    }

    /// 按“最近 12 条里哪类最欠缺”排出这一条优先放哪一类
    private func slotOrder() -> [Slot] {
        let targets = slotTargets()
        let recent = items.suffix(12).compactMap { itemSlot[$0.id] }
        let n = Double(max(1, recent.count))
        let deficit = targets.mapValues { _ in 0.0 }.keys.map { slot -> (Slot, Double) in
            (slot, targets[slot]! - Double(recent.filter { $0 == slot }.count) / n + Double.random(in: 0...0.2))
        }
        return deficit.sorted { $0.1 > $1.1 }.map(\.0)
    }

    private func fits(_ c: Candidate, _ parts: ScoreParts, _ slot: Slot) -> Bool {
        switch slot {
        case .era: return parts.era >= 0.6
        case .hot: return parts.era < 0.6 && parts.absolute >= 0.45
        case .amateur: return c.amateur
        }
    }

    /// 各类位置内部的打分侧重：普通人位置更看“你可能感兴趣”，不比谁更火
    private func slotScore(_ parts: ScoreParts, _ slot: Slot?) -> Double {
        guard slot == .amateur else { return parts.total }
        return parts.total + 0.6 * parts.pref - 0.5 * parts.absolute
    }

    private func inferSlot(_ c: Candidate, _ parts: ScoreParts) -> Slot {
        if c.amateur && parts.absolute < 0.45 { return .amateur }
        if parts.era >= 0.6 { return .era }
        return .hot
    }

    /// 把候选挪进播放队列（只提前排 aheadTarget 条）：
    /// - 先按推荐页配比决定这一条放哪一类，再在这一类里挑分数最高的；
    /// - 同一作者 20 条内最多出现一次，一次航程最多 2 条；
    /// - 只有用户马上没得看、且引擎已经找不到新作者时，才逐级放宽（6 条内不重复 → 3 条内不重复）。
    private func promote(force final: Bool) {
        var changed = false
        while aheadCount < aheadTarget, !candidates.isEmpty {
            let urgent = aheadCount == 0
            if !urgent && !final && candidates.count < 3 { break }

            // 同一个热点词最近 10 条里最多 2 次（硬限制）
            let recentTerms = items.suffix(10).compactMap { itemEraTerm[$0.id].map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 } }
            func termFull(_ parts: ScoreParts) -> Bool {
                guard parts.era >= 0.6, let t = parts.eraTerm else { return false }
                let plain = t.hasPrefix("#") ? String(t.dropFirst()) : t
                return recentTerms.filter { $0 == plain }.count >= 2
            }

            func best(spacing: Int, cap: Int, slot: Slot?, strict: Bool = true) -> (Int, ScoreParts)? {
                let recent = Set(items.suffix(spacing).map(\.author.secUid))
                var bestIdx: Int?
                var bestParts: ScoreParts?
                var bestScore = -Double.infinity
                for (i, c) in candidates.enumerated() {
                    let sec = c.aweme.author.secUid
                    if recent.contains(sec) || authorCount[sec, default: 0] >= cap { continue }
                    let parts = liveScore(c)
                    if let slot, !fits(c, parts, slot) { continue }
                    if strict && termFull(parts) { continue }
                    let score = slotScore(parts, slot)
                    if score > bestScore { bestScore = score; bestIdx = i; bestParts = parts }
                }
                guard let bestIdx, let bestParts else { return nil }
                return (bestIdx, bestParts)
            }

            var choice: (Int, ScoreParts)?
            var chosenSlot: Slot?
            // 热点硬上限：最近 10 条里已有 5 条热点，就先不放热点
            let recentEra = items.suffix(10).filter { itemSlot[$0.id] == .era }.count
            for slot in slotOrder() where !(slot == .era && recentEra >= 5) {
                if let c = best(spacing: 20, cap: 2, slot: slot) { choice = c; chosenSlot = slot; break }
            }
            if choice == nil {
                // 想要的类型暂时没有：引擎还在找、用户也还有得看，就等一等；否则让所有候选统一比分
                if !urgent && fillTask != nil { break }
                choice = best(spacing: 20, cap: 2, slot: nil)
            }
            // 作者间隔、热点上限都只在引擎已经找不到新内容时（搜寻结束）才逐级放宽；
            // 还在搜寻时，宁可让用户等一两秒，也不重复同一个人或同一个热点
            let canRelax = urgent && (final || fillTask == nil)
            if choice == nil && canRelax { choice = best(spacing: 20, cap: 2, slot: nil, strict: false) }
            if choice == nil && canRelax { choice = best(spacing: 6, cap: 2, slot: nil, strict: false) }
            if choice == nil && canRelax { choice = best(spacing: 3, cap: 3, slot: nil, strict: false) }
            guard let (idx, parts) = choice else { break }

            let c = candidates.remove(at: idx)
            let slot = chosenSlot ?? inferSlot(c, parts)
            var a = c.aweme
            a.reason = reason(for: c, parts, slot: slot)
            if parts.pref > 0.4 && prefWeight * parts.pref >= parts.hot * 0.5 { prefDrivenIDs.insert(a.id) }
            authorCount[a.author.secUid, default: 0] += 1
            if let term = parts.eraTerm, parts.era >= 0.6 { itemEraTerm[a.id] = term }
            itemSlot[a.id] = slot
            items.append(a)
            if items.count == 1 { markShown(a) }   // 第一条会立刻展示
            log("入队 #\(items.count) [\(slot.rawValue)]：@\(a.author.nickname)（\(Fmt.dayFormatter.string(from: a.date))\(a.primaryCategory.map { " · \($0)" } ?? "")）热度 \(Int(parts.hot * 100))% 时代 \(Int(parts.era * 100))% 偏好 \(String(format: "%+.2f", parts.pref)) · \(a.reason ?? "")")
            changed = true
        }
        if changed { onItemsChanged?() }
    }

    /// 自检用：候选池构成
    var poolMix: String {
        let era = candidates.filter { $0.curatedEra != nil }.count
        let amateur = candidates.filter(\.amateur).count
        return "候选池 \(candidates.count) 条（热点 \(era)、普通人 \(amateur)）"
    }

    /// 自检用：已入队视频各类位置的数量
    var slotMix: [String: Int] {
        var out: [String: Int] = [:]
        for a in items { if let s = itemSlot[a.id] { out[s.rawValue, default: 0] += 1 } }
        return out
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
        Store.save(topicDirectory, "topics.json")
        if persistFreshness {
            Store.save(recentAuthors, "recent_authors.json")
            Store.save(recentVideos, "recent_videos.json")
        }
    }
}
