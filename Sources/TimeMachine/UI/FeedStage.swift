import SwiftUI

struct FeedStage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let e = model.engine
        ZStack {
            Color.black
            if let a = e.current {
                VideoCard(aweme: a)
                    .id(a.id)
                    .transition(.push(from: model.lastDirection >= 0 ? .bottom : .top))
            } else {
                EmptyStage()
                    .transition(.opacity)
            }
        }
        .background(ScrollPager(onNext: { model.next() }, onPrevious: { model.previous() }))
        .overlay(alignment: .topLeading) { WindowBadge().padding(.leading, 18).padding(.top, 14) }
        .overlay(alignment: .topTrailing) { TopControls().padding(.trailing, 18).padding(.top, 12) }
        .clipped()
        .animation(.easeInOut(duration: 0.3), value: e.current?.id)
        .ignoresSafeArea(.container, edges: .top)
    }
}

private struct WindowBadge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let e = model.engine
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(Theme.gradient)
            Text(e.window.description)
                .font(.system(size: 12.5, weight: .bold))
            if !e.items.isEmpty {
                Text("\(e.currentIndex + 1) / \(e.items.count)")
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if e.phase == .searching {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.1)))
    }
}

private struct TopControls: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        @Bindable var player = model.player
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Button { player.muted.toggle() } label: {
                    Image(systemName: player.muted || player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if hovering {
                    Slider(value: $player.volume, in: 0...1)
                        .frame(width: 90)
                        .controlSize(.mini)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }

            VStack(spacing: 0) {
                navButton("chevron.up", enabled: model.engine.currentIndex > 0) { model.previous() }
                Divider().frame(width: 20).opacity(0.4)
                navButton("chevron.down", enabled: true) { model.next() }
            }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func navButton(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .frame(width: 34, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }
}

// MARK: - 视频卡片

struct VideoCard: View {
    let aweme: Aweme
    @Environment(AppModel.self) private var model
    @State private var heartBurst = false
    @State private var expanded = false

    var body: some View {
        let player = model.player
        let isLive = player.current?.id == aweme.id
        let a = model.engine.current?.id == aweme.id ? (model.engine.current ?? aweme) : aweme
        GeometryReader { geo in
            ZStack {
                RemoteImage(url: aweme.coverURL)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .blur(radius: 60)
                    .opacity(0.5)
                    .clipped()
                    .allowsHitTesting(false)
                Color.black.opacity(0.35)
                    .allowsHitTesting(false)

                CoverLayer(aweme: aweme, isLive: isLive, size: geo.size)

                if isLive {
                    PlayerSurface(player: player.player)
                        .allowsHitTesting(false)
                }

                // 点击层：单击暂停/播放；双击点赞
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        player.resume()
                        if !a.userDigged { model.toggleLike() }
                        heartBurst = true
                        Task {
                            try? await Task.sleep(nanoseconds: 700_000_000)
                            heartBurst = false
                        }
                    }
                    .onTapGesture(count: 1) {
                        player.togglePlay()
                    }

                if isLive { PlaybackStatus() }

                if heartBurst {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 110))
                        .foregroundStyle(Theme.liked)
                        .shadow(color: Theme.liked.opacity(0.6), radius: 20)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .animation(.spring(duration: 0.35), value: heartBurst)
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 280)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomLeading) {
                InfoOverlay(aweme: a, expanded: $expanded)
                    .frame(maxWidth: min(600, max(260, geo.size.width - 170)), alignment: .leading)
                    .padding(.leading, 26)
                    .padding(.bottom, 30)
            }
            .overlay(alignment: .bottomTrailing) {
                ActionRail(aweme: a)
                    .padding(.trailing, 22)
                    .padding(.bottom, 44)
            }
            .overlay(alignment: .bottom) {
                if isLive { ProgressScrubber() }
            }
        }
    }
}

/// 封面：起播前显示，开始播放后隐藏（单独成视图，播放进度变化时只重绘这里）
private struct CoverLayer: View {
    let aweme: Aweme
    let isLive: Bool
    let size: CGSize
    @Environment(AppModel.self) private var model

    var body: some View {
        let started = isLive && model.player.position > 0.05
        RemoteImage(url: aweme.coverURL, contentMode: .fit)
            .frame(maxWidth: size.width, maxHeight: size.height)
            .opacity(started ? 0 : 1)
            .allowsHitTesting(false)
    }
}

/// 播放状态提示：失败 / 缓冲 / 暂停
private struct PlaybackStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        if player.failed {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 34))
                Text("视频无法播放").font(.headline)
                HStack {
                    Button("重试") { player.retry() }
                    Button("在浏览器中打开") { model.openInBrowser() }
                    Button("下一条") { model.next() }
                }
            }
            .padding(24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        } else if player.isBuffering && player.position < 0.05 {
            ProgressView().controlSize(.large)
                .allowsHitTesting(false)
        } else if !player.isPlaying && player.position > 0.05 {
            Image(systemName: "play.fill")
                .font(.system(size: 62))
                .foregroundStyle(.white.opacity(0.75))
                .shadow(radius: 10)
                .allowsHitTesting(false)
        }
    }
}

private struct InfoOverlay: View {
    let aweme: Aweme
    @Binding var expanded: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "calendar.badge.clock")
                Text(Fmt.dateTimeFormatter.string(from: aweme.date))
                Text("·").opacity(0.6)
                Text(Fmt.ago(aweme.date))
            }
            .font(.system(size: 12.5, weight: .semibold))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(Theme.gradient, lineWidth: 1))

            if let reason = aweme.reason {
                HStack(spacing: 8) {
                    Label(reason, systemImage: "sparkles")
                    if let cat = aweme.primaryCategory {
                        Text(aweme.cats.prefix(2).joined(separator: " › "))
                            .foregroundStyle(.white.opacity(0.6))
                            .help(cat)
                    }
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.accent2)
            }

            Button { model.openAuthor(aweme.author) } label: {
                Text("@\(aweme.author.nickname)")
                    .font(.system(size: 17, weight: .bold))
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !aweme.desc.isEmpty {
                Text(styledDescription(aweme.desc))
                    .font(.system(size: 13.5))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(expanded ? 12 : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .onTapGesture { expanded.toggle() }
            }

            HStack(spacing: 14) {
                if let m = aweme.musicTitle, !m.isEmpty {
                    Label(m, systemImage: "music.note")
                        .lineLimit(1)
                }
                Label(Fmt.duration(aweme.duration), systemImage: "timer")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.white.opacity(0.7))
        }
        .shadow(color: .black.opacity(0.55), radius: 6, y: 1)
    }
}

private struct ActionRail: View {
    let aweme: Aweme
    @Environment(AppModel.self) private var model
    @State private var showShare = false

    var body: some View {
        VStack(spacing: 13) {
            Button { model.openAuthor(aweme.author) } label: {
                Avatar(url: aweme.author.avatarURL, size: 48)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 4)
            .help("作者主页（F）")

            RailButton(icon: aweme.userDigged ? "heart.fill" : "heart.fill",
                       tint: aweme.userDigged ? Theme.liked : .white,
                       label: Fmt.count(aweme.diggCount), help: "点赞（Z）") { model.toggleLike() }
            RailButton(icon: "ellipsis.bubble.fill", tint: .white,
                       label: Fmt.count(aweme.commentCount), help: "评论（X）") { model.toggleComments() }
            RailButton(icon: "star.fill", tint: aweme.userCollected ? Theme.collected : .white,
                       label: Fmt.count(aweme.collectCount), help: "收藏（C）") { model.toggleCollect() }
            RailButton(icon: "hand.thumbsdown.fill", tint: .white,
                       label: "不感兴趣", help: "不感兴趣（N）：减少这位作者和同类内容") { model.notInterested() }
            RailButton(icon: "arrowshape.turn.up.right.fill", tint: .white,
                       label: Fmt.count(aweme.shareCount), help: "分享") { showShare = true }
                .popover(isPresented: $showShare, arrowEdge: .leading) {
                    VStack(alignment: .leading, spacing: 4) {
                        Button { model.copyLink(); showShare = false } label: { Label("复制视频链接", systemImage: "link") }
                        Button { model.openInBrowser(); showShare = false } label: { Label("在浏览器中打开", systemImage: "safari") }
                    }
                    .buttonStyle(.plain)
                    .padding(12)
                }
        }
    }
}

private struct RailButton: View {
    let icon: String
    let tint: Color
    let label: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(Color.black.opacity(hover ? 0.45 : 0.28)))
                    .scaleEffect(hover ? 1.08 : 1)
                Text(label)
                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
            }
            .shadow(color: .black.opacity(0.5), radius: 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .help(help)
        .animation(.spring(duration: 0.25), value: tint)
    }
}

private struct ProgressScrubber: View {
    @Environment(AppModel.self) private var model
    @State private var hover = false
    @State private var dragValue: Double?

    var body: some View {
        let p = model.player
        let dur = max(p.duration, 0.1)
        let frac = (dragValue ?? p.position) / dur
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                Rectangle().fill(Color.white.opacity(0.18))
                Rectangle().fill(Theme.gradient)
                    .frame(width: max(0, min(1, frac)) * geo.size.width)
            }
            .frame(height: hover ? 5 : 2.5)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in dragValue = max(0, min(1, v.location.x / geo.size.width)) * dur }
                    .onEnded { v in
                        p.seek(to: max(0, min(1, v.location.x / geo.size.width)) * dur)
                        dragValue = nil
                    }
            )
            .overlay(alignment: .bottomTrailing) {
                if hover {
                    Text("\(Fmt.duration(dragValue ?? p.position)) / \(Fmt.duration(p.duration))")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.trailing, 14)
                        .padding(.bottom, 12)
                }
            }
        }
        .frame(height: 22)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
}

// MARK: - 空状态

private struct EmptyStage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if case .failed(let msg) = model.bridge.state {
                ConnectFailedView(message: msg)
            } else if !model.accountResolved {
                ConnectingView()
            } else if model.engine.phase == .needsLogin {
                LoginOnboarding()
            } else {
                SearchingView()
            }
        }
        .padding(40)
    }
}

private struct TunnelIcon: View {
    var icon: String
    var spinning: Bool
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(AngularGradient(colors: [Theme.accent2, Theme.accent, .clear, Theme.accent2], center: .center), lineWidth: 4)
                .frame(width: 120, height: 120)
                .rotationEffect(.degrees(spin ? -360 : 0))
                .opacity(spinning ? 1 : 0.35)
            Image(systemName: icon)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Theme.gradient)
        }
        .onAppear {
            withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) { spin = true }
        }
    }
}

private struct ConnectingView: View {
    var body: some View {
        VStack(spacing: 16) {
            TunnelIcon(icon: "antenna.radiowaves.left.and.right", spinning: true)
            Text("正在连接抖音…").font(.system(size: 22, weight: .bold))
            Text("首次启动需要加载抖音网页环境，大约需要几秒钟")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }
}

private struct ConnectFailedView: View {
    let message: String
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            TunnelIcon(icon: "wifi.exclamationmark", spinning: false)
            Text("连接抖音失败").font(.system(size: 22, weight: .bold))
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("重新连接") { model.reconnect() }
                .buttonStyle(GradientButtonStyle())
                .frame(width: 200)
        }
    }
}

private struct LoginOnboarding: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 18) {
            TunnelIcon(icon: "lock.open.rotation", spinning: false)
            Text("登录抖音，开启时光穿越")
                .font(.system(size: 24, weight: .bold))
            Text("抖音只向登录用户提供创作者的历史作品。登录后，时光机会从你的关注、你的喜欢和当年的热门话题出发，带你回到 \(model.engine.window)。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            HStack(spacing: 22) {
                step("1", "点下方按钮")
                step("2", "用抖音 App 扫码")
                step("3", "自动返回开始穿越")
            }
            .padding(.vertical, 6)

            Button { openWindow(id: "login") } label: {
                Label("扫码登录抖音", systemImage: "qrcode.viewfinder")
            }
            .buttonStyle(GradientButtonStyle(prominent: true))
            .frame(width: 300)

            Button {
                model.travel(.single(.current))
            } label: {
                Text("先看看这个月的视频（无需登录）")
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Theme.accent2)
        }
    }

    private func step(_ n: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Text(n)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 20, height: 20)
                .background(Theme.gradient, in: Circle())
            Text(text).font(.system(size: 12))
        }
    }
}

private struct SearchingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let e = model.engine
        VStack(spacing: 16) {
            TunnelIcon(icon: icon(e.phase), spinning: e.phase == .searching)

            Text(title(e))
                .font(.system(size: 22, weight: .bold))
            Text(e.statusText.isEmpty ? "在左侧选择年份和月份，时光机就会出发" : e.statusText)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)

            if e.phase == .searching {
                if !e.activity.isEmpty {
                    Text(e.activity)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.accent2)
                        .lineLimit(1)
                        .frame(maxWidth: 440)
                        .transition(.opacity)
                        .id(e.activity)
                }
                HStack(spacing: 26) {
                    miniStat("扫描创作者", e.stats.creatorsScanned)
                    miniStat("找到视频", e.stats.hits)
                    miniStat("创作者池", e.poolSize)
                }
                .padding(.top, 4)
            }

            switch e.phase {
            case .waitingMore, .exhausted, .error:
                HStack(spacing: 10) {
                    Button("继续寻找") { e.continueSearching() }
                    Button("随机换个月") { model.randomTravel() }
                    if e.followOnly {
                        Button("切换到全站探索") { e.setFollowOnly(false) }
                    }
                    if case .error = e.phase {
                        Button("打开抖音网页验证") { openWindow(id: "login") }
                    }
                }
                .buttonStyle(SubtleButtonStyle())
                .frame(maxWidth: 520)
            default:
                EmptyView()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: e.activity)
    }

    private func icon(_ p: TimeMachineEngine.Phase) -> String {
        switch p {
        case .searching: return "hourglass"
        case .error: return "exclamationmark.shield"
        case .exhausted: return "checkmark.seal"
        default: return "clock.arrow.circlepath"
        }
    }

    private func title(_ e: TimeMachineEngine) -> String {
        switch e.phase {
        case .searching: return "正在穿越到 \(e.window)"
        case .waitingMore: return "这里有点冷清"
        case .exhausted: return "这个时间段已经看完了"
        case .error: return "被抖音拦下来了"
        case .needsLogin: return "需要登录"
        case .idle: return "时光机待命中"
        }
    }

    private func miniStat(_ t: String, _ v: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(v)").font(.system(size: 20, weight: .bold, design: .rounded)).monospacedDigit()
                .contentTransition(.numericText())
            Text(t).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .animation(.default, value: v)
    }
}
