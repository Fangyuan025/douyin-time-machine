import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            BrandHeader()
            AccountCard()
            TimeTravelPanel()
            PresetPanel()
            VoyagePanel()
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .padding(.top, 6)
    }

    var body: some View {
        // 重要：侧边栏的 ScrollView 不能使用系统自动加的顶部安全区留白。
        // 在隐藏标题栏的窗口里，SwiftUI 渲染时会把内容下移一个工具栏高度（约 37pt），
        // 但点击判定不会跟着下移，结果整个侧边栏“看到的位置”和“能点中的位置”错开一行。
        // 所以这里忽略顶部安全区，再手动补上同样高度的间距。
        GeometryReader { geo in
            ScrollView { content.padding(.top, geo.safeAreaInsets.top) }
                .scrollIndicators(.never)
                .ignoresSafeArea(.container, edges: .top)
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Button { model.showHistory = true } label: {
                    Label("历史", systemImage: "clock")
                }
                Button { openWindow(id: "login") } label: {
                    Label("网页", systemImage: "globe")
                }
                SettingsLink {
                    Label("设置", systemImage: "gearshape")
                }
            }
            .buttonStyle(SubtleButtonStyle())
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }
}

private struct BrandHeader: View {
    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Theme.gradient)
                    .frame(width: 38, height: 38)
                    .shadow(color: Theme.accent.opacity(0.5), radius: 8, y: 2)
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("时光机")
                    .font(.system(size: 20, weight: .heavy))
                Text("按发布时间刷抖音")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

private struct AccountCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let p = model.profile {
                HStack(spacing: 11) {
                    Avatar(url: p.avatarURL, size: 42)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(p.nickname)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        Text("关注 \(Fmt.count(p.followingCount)) · 粉丝 \(Fmt.count(p.followerCount))")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Menu {
                        Button("刷新账号信息") { Task { await model.refreshAccount() } }
                        Button("打开抖音网页") { openWindow(id: "login") }
                        Divider()
                        Button("退出登录", role: .destructive) { model.logout() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 18))
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 32, height: 32)
                    .help("账号")
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "person.crop.circle.badge.questionmark")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.checkingAccount ? "正在检查登录状态…" : "未登录")
                                .font(.system(size: 14, weight: .semibold))
                            Text("登录后可回到任意月份，并支持点赞、收藏")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button { openWindow(id: "login") } label: {
                        Label("扫码登录抖音", systemImage: "qrcode.viewfinder")
                    }
                    .buttonStyle(GradientButtonStyle())
                }
            }
        }
        .panel()
    }
}

private struct TimeTravelPanel: View {
    @Environment(AppModel.self) private var model
    @State private var displayYear = YearMonth.current.year

    private var years: [Int] { Array(YearMonth.douyinEpoch.year...YearMonth.current.year) }

    var body: some View {
        let w = model.draftWindow
        VStack(alignment: .leading, spacing: 11) {
            SectionTitle(text: "目标时间（精确到月）", icon: "calendar")

            HStack {
                yearButton("chevron.left", enabled: displayYear > years.first!) { displayYear -= 1 }
                Spacer()
                Menu {
                    ForEach(years.reversed(), id: \.self) { y in
                        Button("\(String(y)) 年") { displayYear = y }
                    }
                } label: {
                    Text("\(String(displayYear)) 年")
                        .font(.system(size: 15, weight: .bold))
                        .frame(minWidth: 80, minHeight: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
                yearButton("chevron.right", enabled: displayYear < years.last!) { displayYear += 1 }
            }

            // 注意：这里不能用 LazyVGrid——懒加载网格放在侧边栏 ScrollView 里时，
            // 点击判定用的高度会比实际显示少一行，导致它下面所有按钮的点击区域整体错位。
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(0..<3, id: \.self) { row in
                    GridRow {
                        ForEach(1...4, id: \.self) { col in
                            monthCell(YearMonth(year: displayYear, month: row * 4 + col), window: w)
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    model.travel(TimeWindow(from: YearMonth(year: displayYear, month: 1).clamped(),
                                            to: YearMonth(year: displayYear, month: 12).clamped()))
                } label: {
                    Text("\(String(displayYear)) 整年")
                        .font(.system(size: 11.5, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.08), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 4)
                Text("点月份即出发 · 按住 ⇧ 点可选多个月")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Divider().opacity(0.4)

            VStack(alignment: .leading, spacing: 3) {
                Text(w.description)
                    .font(.system(size: 18, weight: .bold))
                Text("共 \(w.monthCount) 个月 · \(Fmt.dayFormatter.string(from: w.from.startDate)) 至 \(Fmt.dayFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(w.endTS - 1))))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Picker("", selection: Binding(get: { model.followOnly }, set: { model.followOnly = $0 })) {
                Text("全站探索").tag(false)
                Text("只看我关注的").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("「只看我关注的」：看看你关注的人在这个时间段发了什么（需登录）")

            HStack(spacing: 8) {
                Button { model.travel() } label: {
                    Label("重新出发", systemImage: "arrow.clockwise")
                }
                .buttonStyle(SubtleButtonStyle())
                Button { model.randomTravel() } label: {
                    Label("随机穿越", systemImage: "dice")
                }
                .buttonStyle(SubtleButtonStyle())
            }
        }
        .panel()
        .onAppear { displayYear = model.draftTo.year }
        .onChange(of: model.draftTo) { _, new in displayYear = new.year }
    }

    private func yearButton(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 30, height: 30)
                .background(Color.white.opacity(0.07), in: Circle())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
    }

    private func monthCell(_ ym: YearMonth, window w: TimeWindow) -> some View {
        let disabled = ym < .douyinEpoch || ym > .current
        let inRange = w.contains(ym)
        let isEdge = ym == w.from || ym == w.to
        let fill: AnyShapeStyle = isEdge ? AnyShapeStyle(Theme.gradient)
            : inRange ? AnyShapeStyle(Theme.accent.opacity(0.28))
            : AnyShapeStyle(Color.white.opacity(0.05))
        return Button {
            tap(ym)
        } label: {
            Text("\(ym.month)月")
                .font(.system(size: 12, weight: isEdge ? .bold : .medium))
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(fill))
                .foregroundStyle(disabled ? Color.white.opacity(0.22) : Color.white)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(disabled ? "抖音在 2016 年 9 月上线，且不能选择未来" : "穿越到 \(ym)（按住 ⇧ 点击可扩展为区间）")
    }

    /// 单击：立即出发去这个月；按住 ⇧ 单击：把当前区间扩展到这个月并出发
    private func tap(_ ym: YearMonth) {
        var from = ym, to = ym
        if NSEvent.modifierFlags.contains(.shift) {
            from = model.draftFrom
            to = model.draftTo
            if ym < from { from = ym } else if ym > to { to = ym } else { to = ym }
        }
        model.travel(TimeWindow(from: from, to: to))
    }
}

private struct PresetPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionTitle(text: "快速穿越", icon: "sparkles")
            FlowLayout(spacing: 6) {
                ForEach(TimeWindow.presets) { p in
                    Chip(title: p.title, selected: model.engine.window == p.window) {
                        model.travel(p.window)
                    }
                }
            }
        }
        .panel()
    }
}

private struct VoyagePanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let e = model.engine
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                SectionTitle(text: "当前航程", icon: "location.north.line")
                Spacer()
                if e.phase == .searching {
                    ProgressView().controlSize(.mini)
                }
            }
            Text(e.window.description)
                .font(.system(size: 16, weight: .bold))

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    stat("扫描创作者", e.stats.creatorsScanned)
                    stat("命中视频", e.stats.hits)
                }
                GridRow {
                    stat("创作者池", e.poolSize)
                    stat("接口请求", e.stats.requests)
                }
            }

            if !e.statusText.isEmpty {
                Text(e.statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if e.postsBlocked {
                VStack(alignment: .leading, spacing: 6) {
                    Label("未登录时只能从推荐流里筛选（基本只有近期内容）。登录后才能回到更早的月份。", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.accent2)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("去登录") { openWindow(id: "login") }
                        .buttonStyle(SubtleButtonStyle())
                }
            }

            switch e.phase {
            case .waitingMore, .exhausted, .error:
                HStack(spacing: 8) {
                    Button("继续寻找") { e.continueSearching() }
                    if case .error = e.phase {
                        Button("打开网页验证") { openWindow(id: "login") }
                    }
                }
                .buttonStyle(SubtleButtonStyle())
            default:
                EmptyView()
            }

            let tags = e.topCategories.map { "「\($0)」" } + e.topTags.prefix(6).map { "#\($0)" }
            if !tags.isEmpty {
                Divider().opacity(0.4)
                SectionTitle(text: "你的兴趣画像（实时学习）", icon: "brain.head.profile")
                FlowLayout(spacing: 5) {
                    ForEach(tags, id: \.self) { t in
                        Text(t)
                            .font(.system(size: 11))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.white.opacity(0.06), in: Capsule())
                    }
                }
            }
        }
        .panel()
    }

    private func stat(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
