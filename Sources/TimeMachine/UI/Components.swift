import AppKit
import AVFoundation
import SwiftUI

enum Theme {
    static let accent = Color(red: 1.0, green: 0.36, blue: 0.42)
    static let accent2 = Color(red: 1.0, green: 0.66, blue: 0.25)
    static let gradient = LinearGradient(colors: [accent2, accent], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let panel = Color.white.opacity(0.06)
    static let panelStroke = Color.white.opacity(0.09)
    static let liked = Color(red: 1.0, green: 0.17, blue: 0.33)
    static let collected = Color(red: 1.0, green: 0.78, blue: 0.2)
}

// MARK: - 图片缓存

@MainActor
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSURL, NSImage>()
    private var inflight: [URL: Task<NSImage?, Never>] = [:]

    init() { cache.countLimit = 400 }

    func cached(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    func load(_ url: URL) async -> NSImage? {
        if let img = cache.object(forKey: url as NSURL) { return img }
        if let t = inflight[url] { return await t.value }
        let t = Task<NSImage?, Never> {
            var req = URLRequest(url: url)
            req.setValue("https://www.douyin.com/", forHTTPHeaderField: "Referer")
            req.setValue(kDouyinUA, forHTTPHeaderField: "User-Agent")
            guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
            return NSImage(data: data)
        }
        inflight[url] = t
        let img = await t.value
        inflight[url] = nil
        if let img { cache.setObject(img, forKey: url as NSURL) }
        return img
    }
}

struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Rectangle().fill(Color.white.opacity(0.05))
            }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            if let c = ImageCache.shared.cached(url) { image = c; return }
            image = nil
            image = await ImageCache.shared.load(url)
        }
    }
}

struct Avatar: View {
    let url: URL?
    var size: CGFloat = 40

    var body: some View {
        RemoteImage(url: url)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: size > 36 ? 1.5 : 1))
    }
}

// MARK: - 视频图层

final class PlayerLayerNSView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer {
        let l = AVPlayerLayer()
        l.videoGravity = .resizeAspect
        l.backgroundColor = NSColor.clear.cgColor
        return l
    }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    /// 只负责显示画面，不接收任何鼠标事件（否则会挡住叠在上面的 SwiftUI 按钮）
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerNSView {
        let v = PlayerLayerNSView()
        v.playerLayer.player = player
        return v
    }

    func updateNSView(_ v: PlayerLayerNSView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
    }
}

// MARK: - 窗口 / 滚轮

/// 不接收鼠标事件的透明 NSView
final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = PassthroughView()
        DispatchQueue.main.async { if let w = v.window { onWindow(w) } }
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { if let w = v.window { onWindow(w) } }
    }
}

/// 监听落在本视图范围内的滚轮/触控板滑动，转换成「上一条/下一条」
struct ScrollPager: NSViewRepresentable {
    let onNext: () -> Void
    let onPrevious: () -> Void

    func makeNSView(context: Context) -> PagerView {
        let v = PagerView()
        v.onNext = onNext
        v.onPrevious = onPrevious
        return v
    }

    func updateNSView(_ v: PagerView, context: Context) {
        v.onNext = onNext
        v.onPrevious = onPrevious
    }

    final class PagerView: NSView {
        var onNext: (() -> Void)?
        var onPrevious: (() -> Void)?
        private var monitor: Any?
        private var accumulated: CGFloat = 0
        private var locked = false
        private var lastFire = Date.distantPast

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
                guard let self else { return e }
                return self.handle(e) ? nil : e
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        private func handle(_ e: NSEvent) -> Bool {
            guard let win = window, e.window === win else { return false }
            let p = convert(e.locationInWindow, from: nil)
            guard bounds.contains(p) else { return false }
            if abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) { return false }

            if e.phase == .began {
                locked = false
                accumulated = 0
            }
            if e.phase == .ended || e.phase == .cancelled {
                accumulated = 0
                locked = false
                return true
            }
            // 惯性滚动阶段一律吞掉，避免一次滑动翻过好几条
            if !e.momentumPhase.isEmpty { return true }
            if locked { return true }

            accumulated += e.scrollingDeltaY
            let precise = e.hasPreciseScrollingDeltas
            let threshold: CGFloat = precise ? 55 : 1
            let cooldown: TimeInterval = precise ? 0.3 : 0.5
            if abs(accumulated) >= threshold, Date().timeIntervalSince(lastFire) > cooldown {
                if accumulated < 0 { onNext?() } else { onPrevious?() }
                lastFire = Date()
                accumulated = 0
                locked = e.hasPreciseScrollingDeltas
            }
            return true
        }
    }
}

// MARK: - 通用小组件

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > width, x > 0 {
                x = 0
                y += rowH + spacing
                rowH = 0
            }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowH + spacing
                rowH = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}

struct Chip: View {
    let title: String
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(selected ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.white.opacity(0.07)), in: Capsule())
                .foregroundStyle(selected ? Color.white : Color.white.opacity(0.85))
        }
        .buttonStyle(.plain)
    }
}

struct PanelBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.panelStroke))
    }
}

extension View {
    func panel() -> some View { modifier(PanelBackground()) }
}

struct SectionTitle: View {
    let text: String
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon).font(.system(size: 11, weight: .semibold)) }
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(.secondary)
        .textCase(nil)
    }
}

/// 把描述中的 #话题 高亮
func styledDescription(_ text: String) -> AttributedString {
    var out = AttributedString()
    let parts = text.split(separator: " ", omittingEmptySubsequences: false)
    for (i, p) in parts.enumerated() {
        var seg = AttributedString(String(p))
        if p.hasPrefix("#") || p.hasPrefix("@") {
            seg.font = .system(size: 13.5, weight: .semibold)
            seg.foregroundColor = .white
        }
        out += seg
        if i < parts.count - 1 { out += AttributedString(" ") }
    }
    return out
}
