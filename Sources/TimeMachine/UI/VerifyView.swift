import SwiftUI

/// 抖音人机验证窗口：把后台抖音网页临时放到这里，由你本人完成验证；完成后自动关闭
struct VerifyView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.gradient)
                VStack(alignment: .leading, spacing: 2) {
                    Text("抖音需要确认你不是机器人")
                        .font(.system(size: 14, weight: .bold))
                    Text("请在下方完成抖音的安全验证。完成后窗口会自动关闭、内容接着加载；如果紧接着又出现一个，说明之前有请求在排队，再完成一次即可。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("稍后再说") {
                    model.bridge.userDismissedVerification()
                    dismissWindow(id: "verify")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.bar)

            BridgeHost(bridge: model.bridge)
        }
        .preferredColorScheme(.dark)
        .onChange(of: model.bridge.verificationNeeded) { _, needed in
            if !needed { dismissWindow(id: "verify") }
        }
        .onDisappear {
            // 用窗口按钮关掉，也算“稍后再说”
            if model.bridge.verificationNeeded { model.bridge.userDismissedVerification() }
        }
    }
}

/// 承载后台网页的容器：出现时把网页挂进来，消失时还回后台
private struct BridgeHost: NSViewRepresentable {
    let bridge: DouyinBridge

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { bridge.attachForVerification(to: v) }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        MainActor.assumeIsolated { AppModel.shared.bridge.detachFromVerification() }
    }
}
