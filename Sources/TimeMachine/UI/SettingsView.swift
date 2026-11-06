import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("通用", systemImage: "gearshape") }
            AlgorithmSettings()
                .tabItem { Label("推荐", systemImage: "wand.and.stars") }
            DiagnosticsView()
                .tabItem { Label("诊断", systemImage: "stethoscope") }
            AboutView()
                .tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(width: 620, height: 480)
        .preferredColorScheme(.dark)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        @Bindable var player = model.player
        Form {
            Section("播放") {
                Toggle("播放结束后自动进入下一条", isOn: $model.autoAdvance)
                LabeledContent("音量") {
                    Slider(value: $player.volume, in: 0...1)
                }
            }
            Section("推荐") {
                Toggle("隐藏已经看过的视频", isOn: $model.hideSeen)
            }
            Section {
                LabeledContent("请求间隔") {
                    HStack {
                        Slider(value: $model.requestInterval, in: 0.2...3.0, step: 0.05)
                        Text(String(format: "%.2f 秒", model.requestInterval))
                            .monospacedDigit()
                            .frame(width: 60, alignment: .trailing)
                    }
                }
            } header: {
                Text("网络")
            } footer: {
                Text("两次接口请求之间的最小间隔。间隔越大越不容易触发抖音的安全验证，但寻找视频会更慢。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AlgorithmSettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirm: String?

    var body: some View {
        let e = model.engine
        Form {
            Section("本地数据") {
                LabeledContent("创作者池", value: "\(e.poolSize) 位")
                LabeledContent("已看过", value: "\(e.seenCount) 条")
                LabeledContent("观看历史", value: "\(model.history.count) 条")
                if !e.topCategories.isEmpty {
                    LabeledContent("偏好分类", value: e.topCategories.prefix(6).joined(separator: "、"))
                }
                if !e.topTags.isEmpty {
                    LabeledContent("偏好话题", value: e.topTags.prefix(6).map { "#\($0)" }.joined(separator: " "))
                }
            }
            Section {
                Button("重置兴趣画像与已看记录") { confirm = "interest" }
                Button("清空创作者池") { confirm = "pool" }
                Button("清空观看历史") { confirm = "history" }
                Button("在访达中显示数据目录") { NSWorkspace.shared.activateFileViewerSelecting([Store.directory]) }
            } footer: {
                Text("时光机会根据观看时长（秒划算强烈负反馈）、点赞、收藏、不感兴趣，实时学习你对作者、话题和抖音内容分类的偏好，并在每次切换视频时按最新偏好重排；多月时间段会按月份均匀取样。所有数据只保存在本机。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("确定要清除吗？", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button("清除", role: .destructive) {
                switch confirm {
                case "interest": e.resetLearning()
                case "pool": e.resetPool()
                case "history": model.clearHistory()
                default: break
                }
                confirm = nil
            }
        }
    }
}

private struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(stateText, systemImage: "network")
                Text("· 已发出 \(model.bridge.requestCount) 次请求").foregroundStyle(.secondary)
                Spacer()
                Button("重新加载网页环境") { model.bridge.reload() }
                Button("复制日志") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.log.exportText, forType: .string)
                }
            }
            .font(.system(size: 12))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.log.lines) { l in
                            Text("\(Self.timeFmt.string(from: l.date)) \(l.level) \(l.text)")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(l.level.hasPrefix("ERR") ? Color.red : l.level.hasPrefix("WARN") ? Color.orange : Color.primary.opacity(0.8))
                                .textSelection(.enabled)
                                .id(l.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                .onAppear { if let last = model.log.lines.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
        .padding(16)
    }

    private var stateText: String {
        switch model.bridge.state {
        case .idle: return "网页环境：未启动"
        case .loading: return "网页环境：加载中"
        case .ready: return "网页环境：就绪"
        case .failed(let m): return "网页环境：失败（\(m)）"
        }
    }

    static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

private struct AboutView: View {
    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.gradient).frame(width: 72, height: 72)
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 36, weight: .bold)).foregroundStyle(.white)
            }
            Text("时光机").font(.system(size: 22, weight: .heavy))
            Text("第三方抖音 macOS 客户端 · 按发布时间刷视频")
                .foregroundStyle(.secondary)
            Text("本应用与抖音 / 字节跳动无关。所有请求都通过内嵌的抖音官方网页完成，使用你自己的账号与会话；请合理使用，遵守抖音用户协议。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
