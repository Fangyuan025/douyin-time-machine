import AppKit
import Observation
import SwiftUI

struct HistoryEntry: Codable, Identifiable, Hashable {
    var aweme: Aweme
    var watchedAt: Date
    var id: String { aweme.id }
}

@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    let bridge: DouyinBridge
    let api: DouyinAPI
    let engine: TimeMachineEngine
    let player = PlayerController()
    let log = AppLog.shared

    private(set) var profile: UserProfile?
    private(set) var checkingAccount = false
    /// 启动后第一次账号检查是否已完成（完成前界面显示“正在连接抖音”）
    private(set) var accountResolved = false
    var isLoggedIn: Bool { profile != nil }

    // UI 状态
    var showComments = false
    var authorSheet: Author?
    var showHistory = false
    var toast: String?
    private(set) var lastDirection = 1
    var draftFrom: YearMonth { didSet { saveDraft() } }
    var draftTo: YearMonth { didSet { saveDraft() } }
    private(set) var history: [HistoryEntry]

    // 设置
    var autoAdvance: Bool { didSet { player.autoAdvance = autoAdvance; UserDefaults.standard.set(autoAdvance, forKey: "autoAdvance") } }
    var hideSeen: Bool { didSet { engine.hideSeen = hideSeen; UserDefaults.standard.set(hideSeen, forKey: "hideSeen") } }
    /// 推荐风格：0 = 热门多元，1 = 更懂我（偏好权重）
    var personalization: Double { didSet { engine.prefWeight = personalization; UserDefaults.standard.set(personalization, forKey: "personalization") } }
    var requestInterval: Double { didSet { bridge.minInterval = requestInterval; UserDefaults.standard.set(requestInterval, forKey: "requestInterval5") } }

    @ObservationIgnored weak var mainWindow: NSWindow?
    /// 用户在队列末尾按了“下一条”，新视频一到就自动切过去
    @ObservationIgnored private var pendingAdvance = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    private init() {
        let d = UserDefaults.standard
        let bridge = DouyinBridge()
        self.bridge = bridge
        self.api = DouyinAPI(bridge: bridge)
        let lastYear = YearMonth.current.adding(months: -12)
        let from = YearMonth(year: d.object(forKey: "fromY") as? Int ?? lastYear.year, month: d.object(forKey: "fromM") as? Int ?? lastYear.month)
        let to = YearMonth(year: d.object(forKey: "toY") as? Int ?? lastYear.year, month: d.object(forKey: "toM") as? Int ?? lastYear.month)
        self.draftFrom = from
        self.draftTo = to
        self.engine = TimeMachineEngine(api: api, window: TimeWindow(from: from, to: to))
        self.autoAdvance = d.object(forKey: "autoAdvance") as? Bool ?? true
        self.hideSeen = d.object(forKey: "hideSeen") as? Bool ?? true
        self.requestInterval = d.object(forKey: "requestInterval5") as? Double ?? 0.4
        self.history = Store.load([HistoryEntry].self, "history.json") ?? []
        self.personalization = d.object(forKey: "personalization") as? Double ?? 0.35

        bridge.minInterval = requestInterval
        engine.hideSeen = hideSeen
        engine.prefWeight = personalization
        player.autoAdvance = autoAdvance
        player.onEnded = { [weak self] in self?.next() }
        player.refresher = { [weak self] a in
            guard let self else { return nil }
            let fresh = try? await self.api.awemeDetail(id: a.id)
            if let fresh { self.engine.updateItem(fresh) }
            return fresh
        }
        engine.onItemsChanged = { [weak self] in self?.syncPlayer() }
        bridge.onVerificationNeeded = {
            NotificationCenter.default.post(name: .openVerifyWindow, object: nil)
        }
    }

    // MARK: - 启动

    func start() {
        guard !started else { return }
        started = true
        installKeyMonitor()
        bridge.load()
        Task {
            await refreshAccount()
            engine.travel(to: TimeWindow(from: draftFrom, to: draftTo))
        }
    }

    func refreshAccount() async {
        checkingAccount = true
        defer {
            checkingAccount = false
            accountResolved = true
        }
        do {
            profile = try await api.selfProfile()
            if let p = profile { log.info("已登录：\(p.nickname)") }
        } catch DouyinError.notLoggedIn {
            profile = nil
            log.info("当前未登录")
        } catch {
            log.warn("获取账号信息失败：\(error.localizedDescription)")
            if await bridge.hasSessionCookie() == false { profile = nil }
        }
        engine.account = profile.map { AccountRef(uid: $0.uid, secUid: $0.secUid) }
    }

    func didLogin() {
        Task {
            bridge.reload()
            try? await bridge.ensureReady()
            await refreshAccount()
            if isLoggedIn {
                showToast("登录成功，欢迎 \(profile?.nickname ?? "")")
                // 登录后能力完全不同（可以读创作者历史作品），按用户选择的时间重新出发
                travel(draftWindow)
            }
        }
    }

    /// 网页环境加载失败后重试
    func reconnect() {
        accountResolved = false
        bridge.load()
        Task {
            await refreshAccount()
            engine.travel(to: engine.window)
        }
    }

    var followOnly: Bool {
        get { engine.followOnly }
        set {
            if newValue && !isLoggedIn {
                showToast("登录后才能只看关注的人")
                openLogin()
                return
            }
            reportWatch()
            player.load(nil)
            engine.setFollowOnly(newValue)
        }
    }

    func logout() {
        Task {
            await bridge.clearSession()
            profile = nil
            engine.account = nil
            if engine.followOnly { engine.setFollowOnly(false) }
            showToast("已退出登录")
            travel(engine.window)
        }
    }

    // MARK: - 时光机

    var draftWindow: TimeWindow { TimeWindow(from: draftFrom, to: draftTo) }

    func travel(_ w: TimeWindow? = nil) {
        pendingAdvance = false
        let target = w ?? draftWindow
        if let w {
            draftFrom = w.from
            draftTo = w.to
        }
        reportWatch()
        player.load(nil)
        engine.travel(to: target)
    }

    func randomTravel() {
        travel(TimeWindow.random())
    }

    private func saveDraft() {
        let d = UserDefaults.standard
        d.set(draftFrom.year, forKey: "fromY"); d.set(draftFrom.month, forKey: "fromM")
        d.set(draftTo.year, forKey: "toY"); d.set(draftTo.month, forKey: "toM")
    }

    // MARK: - 播放队列

    private func syncPlayer() {
        if pendingAdvance, engine.aheadCount > 0 {
            pendingAdvance = false
            lastDirection = 1
            reportWatch()
            engine.move(by: 1)
        }
        let cur = engine.current
        if cur?.id != player.current?.id {
            player.load(cur)
        }
        if engine.items.indices.contains(engine.currentIndex + 1) {
            player.preload(engine.items[engine.currentIndex + 1])
        }
    }

    func next() {
        lastDirection = 1
        if engine.aheadCount > 0 {
            reportWatch()
            engine.move(by: 1)
            pendingAdvance = false
            syncPlayer()
        } else {
            engine.ensureBuffer(force: true)
            if engine.current != nil {
                pendingAdvance = true
                showToast("正在为你寻找下一条（换个创作者）…")
            }
        }
    }

    func previous() {
        lastDirection = -1
        pendingAdvance = false
        reportWatch()
        if engine.move(by: -1) { syncPlayer() }
    }

    func playNow(_ a: Aweme) {
        lastDirection = 1
        reportWatch()
        engine.insertNext(a, andPlay: true)
        syncPlayer()
    }

    private func reportWatch() {
        guard let r = player.watchReport() else { return }
        if r.seconds >= 1 {
            engine.recordWatch(r.aweme, fraction: r.fraction, seconds: r.seconds)
            addHistory(r.aweme)
        }
    }

    private func addHistory(_ a: Aweme) {
        history.removeAll { $0.id == a.id }
        history.insert(HistoryEntry(aweme: a, watchedAt: Date()), at: 0)
        if history.count > 500 { history.removeLast(history.count - 500) }
        Store.save(history, "history.json")
    }

    func clearHistory() {
        history = []
        Store.save(history, "history.json")
    }

    // MARK: - 互动

    private func requireLogin() -> Bool {
        if isLoggedIn { return true }
        showToast("请先登录抖音账号")
        openLogin()
        return false
    }

    func toggleLike() {
        guard var a = engine.current, requireLogin() else { return }
        let on = !a.userDigged
        a.userDigged = on
        a.diggCount += on ? 1 : -1
        apply(a)
        engine.record(on ? .liked : .unliked, a)
        Task {
            do {
                try await api.digg(awemeId: a.id, on: on)
            } catch {
                var b = a
                b.userDigged = !on
                b.diggCount += on ? -1 : 1
                apply(b)
                showToast("点赞失败：\(error.localizedDescription)")
            }
        }
    }

    func toggleCollect() {
        guard var a = engine.current, requireLogin() else { return }
        let on = !a.userCollected
        a.userCollected = on
        a.collectCount += on ? 1 : -1
        apply(a)
        engine.record(on ? .collected : .uncollected, a)
        Task {
            do {
                try await api.collect(awemeId: a.id, on: on)
                showToast(on ? "已收藏" : "已取消收藏")
            } catch {
                var b = a
                b.userCollected = !on
                b.collectCount += on ? -1 : 1
                apply(b)
                showToast("收藏失败：\(error.localizedDescription)")
            }
        }
    }

    private func apply(_ a: Aweme) {
        engine.updateItem(a)
        player.replaceCurrentMetadata(a)
    }

    /// 不感兴趣：降低这个作者 / 话题 / 分类的权重，撤掉这位作者排队中的视频，并跳到下一条
    func notInterested() {
        guard let a = engine.current else { return }
        engine.notInterested(a)
        showToast("将减少「\(a.author.nickname)」\(a.primaryCategory.map { "和「\($0)」类" } ?? "")的推荐")
        lastDirection = 1
        if engine.aheadCount > 0 {
            engine.move(by: 1)
            syncPlayer()
        } else {
            pendingAdvance = true
            engine.ensureBuffer(force: true)
        }
    }

    func toggleComments() {
        showComments.toggle()
        if showComments, let a = engine.current { engine.record(.openedComments, a) }
    }

    func openAuthor(_ author: Author? = nil) {
        guard let a = author ?? engine.current?.author else { return }
        if author == nil, let cur = engine.current { engine.record(.openedAuthor, cur) }
        authorSheet = a
    }

    func copyLink() {
        guard let a = engine.current else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(a.shareURL.absoluteString, forType: .string)
        showToast("链接已复制")
    }

    func openInBrowser() {
        guard let a = engine.current else { return }
        NSWorkspace.shared.open(a.shareURL)
    }

    // MARK: - 窗口

    func openLogin() {
        NotificationCenter.default.post(name: .openLoginWindow, object: nil)
    }

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { self?.toast = nil }
        }
    }

    // MARK: - 键盘

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // 本地事件监听总是在主线程回调
            nonisolated(unsafe) let e = event
            let handled = MainActor.assumeIsolated { self?.handleKey(e) ?? false }
            return handled ? nil : event
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let win = event.window, win === mainWindow, authorSheet == nil, !showHistory else { return false }
        if win.firstResponder is NSText { return false }
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        guard mods.isEmpty else { return false }
        switch event.keyCode {
        case 125: next(); return true                  // ↓
        case 126: previous(); return true              // ↑
        case 123: player.skip(-5); return true         // ←
        case 124: player.skip(5); return true          // →
        case 49: player.togglePlay(); return true      // 空格
        default: break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "j": next()
        case "k": previous()
        case "z": toggleLike()
        case "x": toggleComments()
        case "c": toggleCollect()
        case "f": openAuthor()
        case "m": player.muted.toggle()
        case "n": notInterested()
        default: return false
        }
        return true
    }
}

extension Notification.Name {
    static let openLoginWindow = Notification.Name("TimeMachine.openLoginWindow")
    static let openVerifyWindow = Notification.Name("TimeMachine.openVerifyWindow")
}
