import SwiftUI
import WebKit

/// 抖音网页窗口：用于扫码登录，以及在触发安全验证时由用户亲自完成验证。
/// 与后台桥接层共用 WKWebsiteDataStore.default()，登录后会话自动共享。
struct LoginView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var status = "等待登录"
    @State private var reloadToken = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Theme.gradient)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.isLoggedIn ? "已登录：\(model.profile?.nickname ?? "")" : "登录抖音")
                        .font(.system(size: 14, weight: .bold))
                    Text("点击页面右上角「登录」，用抖音 App 扫码即可；如果出现安全验证，也请在这里完成。登录成功后窗口会自动关闭。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Text(status)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(status.contains("成功") ? Color.green : Color.secondary)
                Button("刷新") { reloadToken += 1 }
                Button("完成") {
                    Task { await model.refreshAccount() }
                    dismissWindow(id: "login")
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.bar)

            DouyinWebView(reloadToken: reloadToken) {
                status = "登录成功，正在同步…"
                model.didLogin()
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    dismissWindow(id: "login")
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct DouyinWebView: NSViewRepresentable {
    var reloadToken: Int
    var onLogin: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onLogin: onLogin) }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.mediaTypesRequiringUserActionForPlayback = .all
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.customUserAgent = kDouyinUA
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        context.coordinator.webView = web
        context.coordinator.lastToken = reloadToken
        web.load(URLRequest(url: kDouyinHome))
        context.coordinator.startPolling()
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.onLogin = onLogin
        if context.coordinator.lastToken != reloadToken {
            context.coordinator.lastToken = reloadToken
            web.reload()
        }
    }

    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var onLogin: () -> Void
        weak var webView: WKWebView?
        var lastToken = 0
        private var pollTask: Task<Void, Never>?
        private var initiallyLoggedIn: Bool?
        private var fired = false
        private var autoClickTries = 0

        init(onLogin: @escaping () -> Void) { self.onLogin = onLogin }

        /// 只放行网页协议，避免系统弹出“没有可打开此链接的应用程序”
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            DouyinBridge.isWebScheme(navigationAction.request.url) ? .allow : .cancel
        }

        /// 网页里 target=_blank / window.open 的链接在当前窗口打开
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url, DouyinBridge.isWebScheme(url) {
                webView.load(URLRequest(url: url))
            }
            return nil
        }

        func startPolling() {
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    await self?.checkLogin()
                }
            }
        }

        func stop() { pollTask?.cancel() }

        private func checkLogin() async {
            let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
            let has = cookies.contains { $0.domain.contains("douyin.com") && ($0.name == "sessionid_ss" || $0.name == "sessionid") && !$0.value.isEmpty }
            if initiallyLoggedIn == nil {
                initiallyLoggedIn = has
                let names = cookies.filter { $0.domain.contains("douyin.com") && $0.name.lowercased().contains("session") }
                    .map { "\($0.name)=\($0.value.isEmpty ? "空" : "有值")" }
                log("登录窗口：初始登录状态 \(has)，会话 Cookie：\(names.joined(separator: ", "))")
                return
            }
            // 只在「未登录 → 已登录」时触发，打开窗口做验证时不会被自动关掉
            if has && initiallyLoggedIn == false && !fired {
                fired = true
                onLogin()
            }
        }

        // 抖音首页常驻长连接，didFinish 往往不会触发，所以在页面提交后就开始尝试
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            autoClickTries = 0
            Task { await autoOpenLoginPanel() }
        }

        /// 页面加载后自动点开登录面板（只是替用户点一下「登录」按钮）
        private func autoOpenLoginPanel() async {
            while autoClickTries < 20 {
                if initiallyLoggedIn == true { return }
                autoClickTries += 1
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let web = webView, initiallyLoggedIn != nil else { continue }
                let js = """
                (function () {
                  const text = document.body ? document.body.innerText : '';
                  if (text.includes('扫码登录') || text.includes('验证码登录')) return 'open';
                  const els = [...document.querySelectorAll('button, [role=button], a, div, span, p')]
                    .filter(e => e.textContent && e.textContent.trim() === '登录' && e.offsetParent !== null);
                  els.sort((a, b) => a.querySelectorAll('*').length - b.querySelectorAll('*').length);
                  const el = els[0];
                  if (!el) return 'none';
                  (el.closest('button') || el).click();
                  return 'clicked';
                })();
                """
                let r = try? await web.evaluateJavaScript(js) as? String
                if r == "open" {
                    log("登录窗口：登录面板已打开")
                    return
                }
                // 页面还没完成事件绑定时点击会无效：点完等一会儿，下一轮确认面板是否出现
                if r == "clicked" { try? await Task.sleep(nanoseconds: 2_000_000_000) }
            }
        }
    }
}
