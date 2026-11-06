import AppKit
import WebKit
import Observation

let kDouyinUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
let kDouyinHome = URL(string: "https://www.douyin.com/")!

enum DouyinError: LocalizedError, Equatable {
    case notReady
    case notLoggedIn
    case empty(String)
    case api(Int, String)
    case http(Int, String)
    case script(String)
    case timeout(String)
    case parse

    var errorDescription: String? {
        switch self {
        case .notReady: return "抖音网页环境尚未就绪"
        case .notLoggedIn: return "需要登录抖音账号"
        case .empty(let p): return "接口返回空内容（可能需要登录或触发了安全验证）：\(p)"
        case .api(let c, let m): return "抖音接口错误 \(c)\(m.isEmpty ? "" : "：\(m)")"
        case .http(let s, let p): return "HTTP 错误 \(s)：\(p)"
        case .script(let s): return "网页脚本错误：\(s)"
        case .timeout(let p): return "请求超时：\(p)"
        case .parse: return "无法解析接口返回"
        }
    }

    var isEmpty: Bool {
        if case .empty = self { return true }
        return false
    }
}

/// 一次性开关：保证 continuation 只被 resume 一次
@MainActor
private final class Once {
    private(set) var fired = false
    func fire() -> Bool {
        if fired { return false }
        fired = true
        return true
    }
}

/// 抖音网页桥接层。
///
/// 在一个不可见的 WKWebView 里加载 douyin.com，借用官方网页自身的安全 SDK 完成请求签名，
/// 所有接口请求都在页面上下文里通过 fetch 发出——客户端本身不实现任何签名/风控算法。
/// 登录态与「登录窗口」共享同一个 WKWebsiteDataStore.default()。
///
/// 注意两个坑：
/// - 抖音首页有反爬首屏，会先下发一个小页面再整页刷新；页面刷新时正在执行的脚本会永远挂起。
/// - 安全 SDK 会把部分接口的 fetch 挂起不返回。
/// 所以每个请求都有 JS 侧和原生侧两层超时，页面刷新后会自动重新等待就绪。
@MainActor @Observable
final class DouyinBridge: NSObject, WKNavigationDelegate, WKUIDelegate {
    enum State: Equatable { case idle, loading, ready, failed(String) }

    private(set) var state: State = .idle
    private(set) var requestCount = 0
    /// 抖音弹出了人机验证，需要用户本人完成（例如查看评论回复时）
    private(set) var verificationNeeded = false
    @ObservationIgnored var onVerificationNeeded: (() -> Void)?
    @ObservationIgnored private var verificationWatch: Task<Void, Never>?
    /// 用户手动关掉验证窗口的时间：之后 1 分钟内不再自动弹出
    @ObservationIgnored private var dismissedAt = Date.distantPast

    /// 两次请求之间的最小间隔（秒）
    @ObservationIgnored var minInterval: TimeInterval = 0.45

    @ObservationIgnored private var webView: WKWebView!
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Error>] = []
    @ObservationIgnored private var lastSend = Date.distantPast
    @ObservationIgnored private var currentGap: TimeInterval = 0
    /// 敏感接口（搜索、评论回复）单独限速：它们最容易触发人机验证
    @ObservationIgnored private var lastSensitiveSend = Date.distantPast
    @ObservationIgnored private static let sensitivePaths: Set<String> = [
        "/aweme/v1/web/search/item/", "/aweme/v1/web/general/search/single/", "/aweme/v1/web/comment/list/reply/",
    ]
    /// 出现超时 / 异常返回后，自动放慢一段时间
    @ObservationIgnored private var slowUntil = Date.distantPast
    /// 作品列表接口调用最频繁、也最容易被限流：单独保证彼此间隔
    @ObservationIgnored private var lastPostSend = Date.distantPast
    /// 作品列表接口最近一小时的调用时间（每小时最多 360 次，避免再次触发风控）
    @ObservationIgnored private var postSends: [Date] = []
    @ObservationIgnored private static let postHourlyLimit = 360
    @ObservationIgnored private static let postPath = "/aweme/v1/web/aweme/post/"
    @ObservationIgnored private var loadGeneration = 0

    override init() {
        super.init()
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.mediaTypesRequiringUserActionForPlayback = .all
        cfg.userContentController.addUserScript(
            WKUserScript(source: Self.silenceMediaJS, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1440, height: 900), configuration: cfg)
        webView.customUserAgent = kDouyinUA
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    // MARK: - 拦截唤起 App 的链接

    /// 抖音网页会不断尝试用 snssdk1128:// 等协议唤起抖音 App，交给系统就会弹出
    /// “没有可打开此链接的应用程序”。这里只放行网页协议，其余一律静默取消。
    static func isWebScheme(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return true }
        return ["http", "https", "about", "blob", "data", "javascript"].contains(scheme)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        Self.isWebScheme(navigationAction.request.url) ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil   // 后台网页不允许弹出新窗口
    }

    // MARK: - 生命周期

    func load() {
        loadGeneration += 1
        state = .loading
        log("桥接层：加载 douyin.com …")
        webView.load(URLRequest(url: kDouyinHome))
        startPolling()
    }

    /// 登录 / 退出后调用，让网页 SDK 以新的会话重新初始化
    func reload() {
        load()
    }

    private func startPolling() {
        let gen = loadGeneration
        Task { [weak self] in await self?.pollReady(gen) }
    }

    func ensureReady() async throws {
        if state == .ready { return }
        if state != .loading { load() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            waiters.append(c)
        }
    }

    private func finishLoading(_ result: Result<Void, Error>, message: String? = nil) {
        switch result {
        case .success:
            state = .ready
            log("桥接层：就绪")
        case .failure(let e):
            state = .failed(message ?? e.localizedDescription)
            logError("桥接层失败：\(message ?? e.localizedDescription)")
        }
        let ws = waiters
        waiters = []
        for w in ws { w.resume(with: result) }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        log("桥接层：页面已提交 \(webView.url?.path ?? "")")
        // 页面被整页刷新（反爬首屏、跳转到精选页等）：重新等待 SDK 就绪
        if state == .ready {
            loadGeneration += 1
            state = .loading
            startPolling()
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let ns = error as NSError
        guard state == .loading, ns.code != NSURLErrorCancelled else { return }
        logWarn("桥接层：页面打开失败 \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        logWarn("桥接层：网页进程退出，重新加载")
        load()
    }

    private func pollReady(_ gen: Int) async {
        let started = Date()
        var lastInfo = ""
        while gen == loadGeneration, state == .loading {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard gen == loadGeneration, state == .loading else { return }
            let elapsed = Date().timeIntervalSince(started)
            let raw = try? await evaluate("""
                return {
                  sdk: performance.getEntriesByType('resource').some(e => e.name.includes('/aweme/v1/web/') && e.name.includes('webid=')),
                  rs: document.readyState,
                  host: location.host
                };
                """, timeout: 3)
            let info = raw as? [String: Any] ?? [:]
            let sdk = (info["sdk"] as? NSNumber)?.boolValue ?? false
            let rs = info["rs"] as? String ?? "?"
            let host = info["host"] as? String ?? ""
            let desc = "\(host) \(rs) sdk=\(sdk)"
            if desc != lastInfo { log("桥接层：\(desc)"); lastInfo = desc }
            if sdk && host.contains("douyin.com") {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard gen == loadGeneration, state == .loading else { return }
                finishLoading(.success(()))
                return
            }
            if elapsed > 14, host.contains("douyin.com"), rs != "loading" {
                logWarn("桥接层：未检测到 SDK 请求，使用默认参数继续")
                finishLoading(.success(()))
                return
            }
            if elapsed > 45 {
                finishLoading(.failure(DouyinError.notReady), message: "加载抖音网页超时，请检查网络")
                return
            }
        }
    }

    // MARK: - 人机验证（交给用户本人完成）

    /// 把后台网页临时放进验证窗口里，让用户亲自完成抖音的验证
    func attachForVerification(to container: NSView) {
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }

    func detachFromVerification() {
        guard webView.superview != nil else { return }
        webView.removeFromSuperview()
        webView.autoresizingMask = []
        webView.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    /// 页面上是否正显示着抖音的验证框
    private func captchaVisible() async -> Bool {
        let r = try? await evaluate("""
            const f = [...document.querySelectorAll('iframe')].find(x => /verifycenter\\/captcha|rmc-nocaptcha|captcha/.test(x.src || '') && x.offsetParent !== null && x.getBoundingClientRect().height > 50);
            return !!f;
            """, timeout: 3)
        return (r as? Bool) == true || (r as? NSNumber)?.boolValue == true
    }

    /// 用户手动关闭验证窗口
    func userDismissedVerification() {
        dismissedAt = Date()
        verificationNeeded = false
    }

    /// 用户主动重试（如点「去验证」）：解除冷却，需要时允许立即弹出验证窗口
    func allowVerificationPopup() {
        dismissedAt = .distantPast
    }

    /// 交互式请求挂起时，检查是否弹出了验证；弹出就通知界面打开验证窗口。
    /// 验证框消失后再等 2.5 秒确认没有新的验证接踵而来，才收起窗口（避免窗口反复开关）
    private func watchForVerification(initialDelay: Double = 2.5) {
        verificationWatch?.cancel()
        verificationWatch = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(initialDelay * 1_000_000_000))
            var goneSince: Date?
            while let self, !Task.isCancelled {
                let visible = await self.captchaVisible()
                if visible {
                    goneSince = nil
                    if !self.verificationNeeded && Date().timeIntervalSince(self.dismissedAt) > 60 {
                        self.verificationNeeded = true
                        log("抖音弹出了人机验证，请在弹出的窗口里完成")
                        self.onVerificationNeeded?()
                    }
                } else if self.verificationNeeded {
                    if goneSince == nil { goneSince = Date() }
                    if let g = goneSince, Date().timeIntervalSince(g) > 2.5 {
                        self.verificationNeeded = false
                        log("验证已完成")
                    }
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
    }

    // MARK: - 脚本执行（带超时）

    /// callAsyncJavaScript 在页面刷新时可能永远不返回，这里用超时兜底
    private func evaluate(_ js: String, arguments: [String: Any] = [:], timeout: TimeInterval) async throws -> Any? {
        let web = webView!
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Any?, Error>) in
            let once = Once()
            Task { @MainActor in
                do {
                    let r = try await web.callAsyncJavaScript(js, arguments: arguments, in: nil, contentWorld: .page)
                    if once.fire() { cont.resume(returning: r) }
                } catch {
                    if once.fire() { cont.resume(throwing: error) }
                }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if once.fire() { cont.resume(throwing: DouyinError.timeout("脚本无响应")) }
            }
        }
    }

    // MARK: - 请求

    /// 节流：只有真正发出请求时才占用时间槽；已取消的任务（比如切换了时间段）立即退出排队，
    /// 不会让新请求排在一堆作废请求后面。
    /// 普通接口按 minInterval；敏感接口额外保证彼此间隔至少 1.5 秒；出过异常的 2 分钟内整体放慢。
    private func pace(sensitive: Bool, posts: Bool = false) async throws {
        while true {
            try Task.checkCancellation()
            var wait = lastSend.addingTimeInterval(currentGap).timeIntervalSinceNow
            if sensitive {
                wait = max(wait, lastSensitiveSend.addingTimeInterval(max(1.5, minInterval * 3)).timeIntervalSinceNow)
            }
            if posts {
                wait = max(wait, lastPostSend.addingTimeInterval(max(0.9, minInterval * 2) + Double.random(in: 0...0.3)).timeIntervalSinceNow)
            }
            if wait <= 0 {
                lastSend = Date()
                if sensitive { lastSensitiveSend = lastSend }
                if posts { lastPostSend = lastSend }
                let factor = Date() < slowUntil ? 2.5 : 1
                currentGap = (minInterval + Double.random(in: 0...(minInterval * 0.5))) * factor
                return
            }
            try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
    }

    private func noteTrouble(_ e: DouyinError, path: String) {
        // 作品列表接口的限流由引擎单独冷却处理，不连带放慢其他接口
        if path == Self.postPath { return }
        switch e {
        case .timeout, .empty, .http:
            if Date() >= slowUntil { logWarn("请求出现异常，接下来 2 分钟放慢请求节奏") }
            slowUntil = Date().addingTimeInterval(120)
        default:
            break
        }
    }

    func get(_ path: String, _ query: [String: String] = [:], interactive: Bool = false) async throws -> J {
        try await request("GET", path, query: query, form: nil, interactive: interactive)
    }

    func post(_ path: String, query: [String: String] = [:], form: [String: String]) async throws -> J {
        try await request("POST", path, query: query, form: form)
    }

    private func request(_ method: String, _ path: String, query: [String: String], form: [String: String]?, interactive: Bool = false) async throws -> J {
        var lastError: Error = DouyinError.notReady
        for attempt in 0..<2 {
            try await ensureReady()
            if path == Self.postPath {
                let hourAgo = Date().addingTimeInterval(-3600)
                postSends.removeAll { $0 < hourAgo }
                if postSends.count >= Self.postHourlyLimit {
                    // 不发请求，按限流处理（引擎会进入冷却，期间改用话题页）
                    throw DouyinError.http(429, path)
                }
            }
            try await pace(sensitive: Self.sensitivePaths.contains(path), posts: path == Self.postPath)
            if path == Self.postPath { postSends.append(Date()) }
            if state != .ready { try await ensureReady() }
            requestCount += 1
            do {
                // 交互式请求（如查看评论回复）可能触发人机验证：给用户留出完成验证的时间
                let jsTimeout = interactive ? 120_000 : 15_000
                var args: [String: Any] = ["method": method, "path": path, "query": query, "timeoutMs": jsTimeout]
                args["form"] = form ?? [:]
                if interactive { watchForVerification() }
                defer {
                    if interactive {
                        verificationWatch?.cancel()
                        verificationNeeded = false
                    }
                }
                let raw = try await evaluate(Self.requestJS, arguments: args, timeout: Double(jsTimeout) / 1000 + 5)
                return try parse(raw, path: path)
            } catch is CancellationError {
                throw CancellationError()
            } catch let e as DouyinError {
                noteTrouble(e, path: path)
                switch e {
                case .timeout(let why) where why == "脚本无响应":
                    // 原生侧超时：多半是页面刷新导致脚本上下文丢失，等页面重新就绪后再试
                    lastError = DouyinError.timeout(path)
                    logWarn("请求 \(path) 无响应（第 \(attempt + 1) 次），等待页面恢复")
                    if state == .ready {
                        loadGeneration += 1
                        state = .loading
                        startPolling()
                    }
                default:
                    throw e
                }
            } catch {
                lastError = DouyinError.script(error.localizedDescription)
                logWarn("请求 \(path) 脚本异常（第 \(attempt + 1) 次）：\(error.localizedDescription)")
                if state == .ready {
                    loadGeneration += 1
                    state = .loading
                    startPolling()
                }
            }
        }
        throw lastError
    }

    private func parse(_ raw: Any?, path: String) throws -> J {
        guard let dict = raw as? [String: Any] else { throw DouyinError.parse }
        if let err = dict["error"] as? String {
            if err == "TM_TIMEOUT" { throw DouyinError.timeout(path) }
            throw DouyinError.script(err)
        }
        let status = (dict["status"] as? NSNumber)?.intValue ?? 0
        let text = dict["text"] as? String ?? ""
        guard status == 200 else { throw DouyinError.http(status, path) }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DouyinError.empty(path) }
        guard let j = J.parse(text) else { throw DouyinError.parse }
        let code = j["status_code"].int ?? 0
        if code == 8 { throw DouyinError.notLoggedIn }
        if code != 0 { throw DouyinError.api(code, j["status_msg"].string ?? "") }
        return j
    }

    // MARK: - 会话

    func cookies() async -> [HTTPCookie] {
        await WKWebsiteDataStore.default().httpCookieStore.allCookies()
    }

    func hasSessionCookie() async -> Bool {
        let all = await cookies()
        return all.contains { c in
            c.domain.contains("douyin.com") && (c.name == "sessionid_ss" || c.name == "sessionid") && !c.value.isEmpty
        }
    }

    func clearSession() async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        let keys = ["douyin", "amemv", "bytedance", "snssdk", "byteimg", "douyinpic", "zjcdn", "douyinvod", "bytescm", "toutiao"]
        let targets = records.filter { r in keys.contains { r.displayName.contains($0) } }
        await store.removeData(ofTypes: types, for: targets)
        log("已清除抖音登录数据（\(targets.count) 个站点记录）")
        reload()
    }

    // MARK: - 脚本

    private static let silenceMediaJS = """
    (function () {
      try {
        const quiet = function () { try { this.muted = true; this.pause(); } catch (e) {} return Promise.resolve(); };
        HTMLMediaElement.prototype.play = quiet;
      } catch (e) {}
    })();
    """

    /// 在页面上下文中执行；fetch 已被抖音安全 SDK 接管，会自动附加签名参数。
    private static let requestJS = """
    const withTimeout = (p, ms) => Promise.race([p, new Promise((_, rej) => setTimeout(() => rej(new Error('TM_TIMEOUT')), ms))]);
    try {
      const skip = new Set(['msToken','a_bogus','X-Bogus','verifyFp','fp','source','spot_keys','app_id','detail_list',
        'main_billboard_count','tab_id','os','client_type','scene','publish_video_strategy_type','aweme_id','sec_user_id',
        'count','cursor','max_cursor','keyword','offset','user_id']);
      let base = window.__tmBase;
      if (!base) {
        const u = performance.getEntriesByType('resource').map(e => e.name).reverse()
          .find(x => x.includes('/aweme/v1/web/') && x.includes('webid='));
        if (u) {
          base = {};
          for (const [k, v] of new URL(u).searchParams) if (!skip.has(k)) base[k] = v;
          window.__tmBase = base;
        }
      }
      const defaults = {
        device_platform: 'webapp', aid: '6383', channel: 'channel_pc_web', pc_client_type: '1',
        version_code: '170400', version_name: '17.4.0', update_version_code: '170400', cookie_enabled: 'true',
        screen_width: String(screen.width), screen_height: String(screen.height),
        browser_language: navigator.language || 'zh-CN', browser_platform: navigator.platform || 'MacIntel',
        browser_name: 'Safari', browser_version: '18.0', browser_online: 'true', engine_name: 'WebKit',
        engine_version: '605.1.15', os_name: 'Mac OS', os_version: '10.15.7',
        cpu_core_num: String(navigator.hardwareConcurrency || 8), device_memory: '', platform: 'PC',
        pc_libra_divert: 'Mac', support_h265: '1', support_dash: '0'
      };
      const qs = new URLSearchParams(Object.assign({}, defaults, base || {}, query || {}));
      const url = 'https://www.douyin.com' + path + '?' + qs.toString();
      const init = { method, credentials: 'include', headers: { 'Accept': 'application/json, text/plain, */*' } };
      if (method === 'POST') {
        try {
          const h = await withTimeout(fetch('https://www.douyin.com' + path, { method: 'HEAD', credentials: 'include',
            headers: { 'x-secsdk-csrf-request': '1', 'x-secsdk-csrf-version': '1.2.22' } }), 6000);
          const w = h.headers.get('x-ware-csrf-token');
          if (w) { const parts = w.split(','); if (parts[1]) init.headers['x-secsdk-csrf-token'] = parts[1]; }
        } catch (e) {}
        init.headers['Content-Type'] = 'application/x-www-form-urlencoded; charset=UTF-8';
        init.body = new URLSearchParams(form || {}).toString();
      }
      const limit = timeoutMs || 15000;
      const r = await withTimeout(fetch(url, init), limit);
      const text = await withTimeout(r.text(), limit);
      return { status: r.status, text };
    } catch (e) {
      return { status: 0, text: '', error: String(e && e.message || e) };
    }
    """
}
