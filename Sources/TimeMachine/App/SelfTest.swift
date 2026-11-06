import AppKit

/// `TimeMachine --selftest`：不打开界面，直接跑一遍数据链路并输出结果，便于排查接口变化。
@MainActor
enum SelfTest {
    static func run() {
        AppLog.shared.echoToStdout = true
        Task {
            let model = AppModel.shared
            // 自检刷到的视频不算“你看过 / 最近展示过”
            model.engine.persistFreshness = false
            let api = model.api
            var ok = true
            func check(_ name: String, _ body: () async throws -> String) async {
                do {
                    let r = try await body()
                    print("✅ \(name)：\(r)")
                } catch {
                    ok = false
                    print("❌ \(name)：\(error.localizedDescription)")
                }
                fflush(stdout)
            }

            model.bridge.load()
            await check("桥接层就绪") { try await model.bridge.ensureReady(); return "OK" }

            var feed: [Aweme] = []
            await check("推荐流") {
                feed = try await api.recommendFeed(refreshIndex: 1)
                for a in feed.prefix(3) { print("   内容分类：\(a.cats.joined(separator: " › "))") }
                let s = feed.prefix(3).map { "\($0.author.nickname)@\(Fmt.dayFormatter.string(from: $0.date)) urls=\($0.playURLs.count)" }
                return "\(feed.count) 条 · " + s.joined(separator: " | ")
            }
            var loggedIn = false
            await check("账号") {
                do {
                    let p = try await api.selfProfile()
                    loggedIn = p != nil
                    model.engine.account = p.map { AccountRef(uid: $0.uid, secUid: $0.secUid) }
                    return p.map { "已登录 \($0.nickname)" } ?? "无用户信息"
                } catch DouyinError.notLoggedIn { return "未登录（正常）" }
            }
            if let a = feed.first {
                await check("评论") {
                    let c = try await api.comments(awemeId: a.id, cursor: 0)
                    return "\(c.comments.count)/\(c.total) 条，首条：\(c.comments.first?.text.prefix(20) ?? "")"
                }
                await check("作者资料") {
                    let p = try await api.userProfile(secUid: a.author.secUid)
                    return "\(p?.nickname ?? "?") 作品 \(p?.awemeCount ?? 0)"
                }
                await check("作品详情") {
                    let d = try await api.awemeDetail(id: a.id)
                    return d.map { "\($0.id) urls=\($0.playURLs.count)" } ?? "无"
                }
                if !loggedIn {
                    print("⚠️ 创作者历史作品（时间跳转）：需要登录，已跳过——登录后再次运行自检即可验证")
                } else { await check("创作者历史作品（时间跳转）") {
                    let w = TimeWindow.single(YearMonth.current.adding(months: -12))
                    let page = try await api.userPosts(secUid: a.author.secUid, maxCursor: w.endTS * 1000)
                    let ds = page.awemes.prefix(5).map { Fmt.dayFormatter.string(from: $0.date) }
                    return "\(page.awemes.count) 条 hasMore=\(page.hasMore) timeList=\(page.timeList.prefix(6)) \(ds)"
                } }
                await check("播放地址可访问") {
                    guard let url = a.playURLs.first else { return "无地址" }
                    var req = URLRequest(url: url)
                    req.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
                    req.setValue("https://www.douyin.com/", forHTTPHeaderField: "Referer")
                    let (_, resp) = try await URLSession.shared.data(for: req)
                    return "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)"
                }
            }

            // 引擎：最近一个月（推荐流可直接命中），验证填充与排序
            let engine = model.engine
            engine.travel(to: .single(YearMonth.current))
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if engine.items.count >= 3 || engine.phase != .searching { break }
            }
            let items = engine.items.prefix(5).map { "\($0.author.nickname)@\(Fmt.dayFormatter.string(from: $0.date))" }
            print("\(engine.items.isEmpty ? "❌" : "✅") 引擎（本月）：队列 \(engine.items.count) 条，阶段 \(engine.phase)，请求 \(engine.stats.requests)，池 \(engine.poolSize) · \(items.joined(separator: " | "))")
            // 只看关注：需要登录
            if loggedIn {
                engine.setFollowOnly(true)
                engine.travel(to: .single(YearMonth.current.adding(months: -12)))
                for _ in 0..<90 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if engine.items.count >= 3 || (engine.phase != .searching && engine.phase != .idle) { break }
                }
                let followed = engine.items.filter { engine.pool.creators[$0.author.secUid]?.followed == true }.count
                let authors = Set(engine.items.map(\.author.secUid)).count
                let pass = !engine.items.isEmpty && followed == engine.items.count
                if !pass { ok = false }
                print("\(pass ? "✅" : "❌") 只看关注（\(engine.window)）：队列 \(engine.items.count) 条，全部来自关注 \(followed == engine.items.count)，作者 \(authors) 位，扫描 \(engine.stats.creatorsScanned)，阶段 \(engine.phase)")
                let order = engine.items.map(\.author.secUid)
                let consecutive = zip(order, order.dropFirst()).contains { $0 == $1 }
                print("\(consecutive ? "❌" : "✅") 作者打散：相邻同作者 = \(consecutive)")
                engine.setFollowOnly(false)
            }
            // Beta 抽样器：Beta(3,1) 的均值应为 0.75
            let mean = (0..<4000).map { _ in TimeMachineEngine.betaSample(3, 1) }.reduce(0, +) / 4000
            let betaOK = abs(mean - 0.75) < 0.03
            if !betaOK { ok = false }
            print("\(betaOK ? "✅" : "❌") Thompson 采样器：Beta(3,1) 均值 \(String(format: "%.3f", mean))（期望 0.75）")

            // 多月时间段的月份分布 + 推荐理由
            if loggedIn {
                let year = YearMonth.current.year - 3
                engine.travel(to: TimeWindow(from: YearMonth(year: year, month: 1), to: YearMonth(year: year, month: 12)))
                for _ in 0..<80 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if engine.monthSpread.values.reduce(0, +) >= 40 || (engine.phase != .searching && engine.phase != .idle) { break }
                }
                let spread = engine.monthSpread
                let line = (1...12).map { m in "\(m)月:\(spread[YearMonth(year: year, month: m).index] ?? 0)" }.joined(separator: " ")
                let monthsHit = (1...12).filter { (spread[YearMonth(year: year, month: $0).index] ?? 0) > 0 }.count
                let spreadOK = monthsHit >= 6
                if !spreadOK { ok = false }
                print("\(spreadOK ? "✅" : "❌") 月份分层采样（\(year) 全年）：覆盖 \(monthsHit)/12 个月 · \(line)")
                let withReason = engine.items.filter { $0.reason != nil }.count
                print("\(withReason == engine.items.count && !engine.items.isEmpty ? "✅" : "❌") 推荐理由：\(engine.items.prefix(4).map { "\($0.author.nickname)「\($0.reason ?? "-")」\($0.primaryCategory ?? "")" }.joined(separator: " | "))")
                let order = engine.items.map(\.author.secUid)
                let consecutive = zip(order, order.dropFirst()).contains { $0 == $1 }
                print("\(consecutive ? "❌" : "✅") 作者打散（全年）：相邻同作者 = \(consecutive)")

                // 模拟连刷 15 条：看实际刷到的内容有多元
                // 模拟一个刷得很快的人：每 1.5 秒划一条
                var consumed = 0, ticks = 0
                while consumed < 15 && ticks < 160 {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    ticks += 1
                    if engine.aheadCount > 0 { engine.move(by: 1); consumed += 1 }
                }
                let shown = Array(engine.items.prefix(engine.currentIndex + 1))
                let authors = Set(shown.map(\.author.secUid)).count
                let cats = Set(shown.compactMap(\.primaryCategory))
                var reasons: [String: Int] = [:]
                for a in shown { reasons[(a.reason ?? "-").components(separatedBy: " ·").first ?? "-", default: 0] += 1 }
                var minGap = Int.max
                var lastSeen: [String: Int] = [:]
                for (i, a) in shown.enumerated() {
                    if let j = lastSeen[a.author.secUid] { minGap = min(minGap, i - j) }
                    lastSeen[a.author.secUid] = i
                }
                let diverse = shown.count >= 10 && Double(authors) >= Double(shown.count) * 0.85 && minGap >= 12
                let followedShare = shown.filter { engine.pool.creators[$0.author.secUid]?.followed == true }.count
                if !diverse { ok = false }
                print("\(diverse ? "✅" : "❌") 连刷 \(shown.count) 条：\(authors) 位不同作者，\(cats.count) 个内容大类（\(cats.prefix(8).joined(separator: "、"))）")
                print("   同一作者最小间隔：\(minGap == Int.max ? "无重复" : "\(minGap) 条")；其中来自关注的人：\(followedShare) 条")
                print("   推荐理由分布：\(reasons.sorted { $0.value > $1.value }.map { "\($0.key)×\($0.value)" }.joined(separator: "  "))")
                let topReason = reasons.filter { $0.key.hasPrefix("当时的热点") }.values.max() ?? 0
                let notFlooded = topReason <= max(4, shown.count / 3)
                if !notFlooded { ok = false }
                print("\(notFlooded ? "✅" : "❌") 热点不刷屏：单个热点最多 \(topReason) 条")
                let mix = engine.slotMix
                let amateurN = mix["amateur"] ?? 0
                let mixOK = amateurN * 100 / max(1, mix.values.reduce(0, +)) >= 20
                if !mixOK { ok = false }
                print("\(mixOK ? "✅" : "❌") 推荐页配比（全年）：热点 \(mix["era"] ?? 0) · 热门 \(mix["hot"] ?? 0) · 普通人 \(amateurN) · \(engine.poolMix)")

                // 时代感：疫情暴发（2020-02）与动态清零高峰（2022-04）都应该刷到大量相关内容
                let pandemicWords = ["武汉", "疫情", "口罩", "抗疫", "隔离", "宅家", "火神山", "雷神山", "钟南山", "复工", "肺炎",
                                     "防疫", "医护", "白衣", "病毒", "在家", "中国加油", "加油中国", "云监工", "居家", "抗击", "逆行",
                                     "核酸", "大白", "团购", "方舱", "抗原", "健康码", "封控", "静默", "物资", "志愿者", "上海加油", "解封"]
                for ym in [YearMonth(year: 2020, month: 2), YearMonth(year: 2022, month: 4)] {
                    engine.travel(to: .single(ym))
                    var n = 0, t = 0
                    while n < 12 && t < 160 {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        t += 1
                        if engine.aheadCount > 0 { engine.move(by: 1); n += 1 }
                    }
                    let shown = Array(engine.items.prefix(engine.currentIndex + 1))
                    if let dump = ProcessInfo.processInfo.environment["TM_SELFTEST_DUMP"] {
                        let line = "\(ym.short)\t" + shown.map(\.author.secUid).joined(separator: ",") + "\t" + shown.map(\.id).joined(separator: ",") + "\n"
                        if let h = FileHandle(forWritingAtPath: dump) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
                        else { try? line.write(toFile: dump, atomically: true, encoding: .utf8) }
                    }
                    let related = shown.filter { a in
                        let text = a.desc + " " + a.hashtags.joined(separator: " ")
                        return pandemicWords.contains { text.contains($0) }
                    }
                    let share = shown.isEmpty ? 0 : related.count * 100 / shown.count
                    let eraOK = shown.count >= 8 && share >= 30 && share <= 90
                    if !eraOK { ok = false }
                    print("\(eraOK ? "✅" : "❌") 时代感（\(ym)）：刷到 \(shown.count) 条，疫情相关 \(related.count) 条（\(share)%），作者 \(Set(shown.map(\.author.secUid)).count) 位")
                    var termCounts: [String: Int] = [:]
                    for a in shown { if let r = a.reason, let t = r.components(separatedBy: "：").dropFirst().first { termCounts[t, default: 0] += 1 } }
                    let maxTerm = termCounts.values.max() ?? 0
                    if maxTerm > 4 { ok = false }
                    print("\(maxTerm > 4 ? "❌" : "✅") 同一热点词最多 \(maxTerm) 条")
                    let m = engine.slotMix
                    print("   配比：热点 \(m["era"] ?? 0) · 热门 \(m["hot"] ?? 0) · 普通人 \(m["amateur"] ?? 0) · \(engine.poolMix)")
                    for a in shown.prefix(12) {
                        print("   · \(Fmt.dayFormatter.string(from: a.date)) @\(a.author.nickname)「\(a.reason ?? "-")」\(a.desc.prefix(26))")
                    }
                }
            }
            print(ok ? "SELFTEST PASS" : "SELFTEST DONE WITH FAILURES")
            fflush(stdout)
            engine.saveNow()
            exit(0)
        }
    }
}
