import SwiftUI

struct CommentsPanel: View {
    @Environment(AppModel.self) private var model
    @State private var comments: [Comment] = []
    @State private var cursor = 0
    @State private var hasMore = true
    @State private var loading = false
    @State private var total = 0
    @State private var error: String?
    /// 每条评论的回复展开状态
    @State private var replies: [String: ReplyState] = [:]

    var body: some View {
        let a = model.engine.current
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("评论").font(.system(size: 16, weight: .bold))
                if total > 0 {
                    Text(Fmt.count(total)).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.showComments = false } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(Color.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if let a {
                HStack(spacing: 6) {
                    Image(systemName: "calendar.badge.clock")
                    Text("视频发布于 \(Fmt.dayFormatter.string(from: a.date))（\(Fmt.ago(a.date))）")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(comments) { c in
                        VStack(alignment: .leading, spacing: 8) {
                            CommentRow(comment: c)
                            if c.replyCount > 0, let a {
                                RepliesSection(comment: c, state: replies[c.id] ?? ReplyState(),
                                               onLoad: { Task { await loadReplies(a, c) } },
                                               onCollapse: { replies[c.id]?.expanded = false })
                            }
                        }
                    }
                    if let error {
                        VStack(spacing: 8) {
                            Text(error).font(.system(size: 12)).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Button("重试") { Task { await load(a, reset: comments.isEmpty) } }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    } else if hasMore {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .onAppear { Task { await load(a, reset: false) } }
                    } else if comments.isEmpty {
                        Text("还没有评论")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 30)
                    } else {
                        Text("— 没有更多了 —")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                }
                .padding(16)
            }
        }
        .task(id: a?.id) {
            comments = []
            cursor = 0
            hasMore = true
            total = 0
            error = nil
            replies = [:]
            await load(a, reset: true)
        }
    }

    /// 展开 / 加载更多回复。若抖音弹出人机验证，会自动打开验证窗口，完成后接着加载
    private func loadReplies(_ a: Aweme, _ c: Comment) async {
        var st = replies[c.id] ?? ReplyState()
        // 已经加载过、只是收起了：直接展开
        if !st.expanded && !st.items.isEmpty {
            st.expanded = true
            replies[c.id] = st
            return
        }
        guard !st.loading else { return }
        st.loading = true
        st.expanded = true
        st.error = nil
        replies[c.id] = st
        do {
            let page = try await model.api.commentReplies(awemeId: a.id, commentId: c.id, cursor: st.cursor)
            guard model.engine.current?.id == a.id else { return }
            var cur = replies[c.id] ?? st
            let existing = Set(cur.items.map(\.id))
            cur.items += page.comments.filter { !existing.contains($0.id) }
            cur.cursor = page.cursor
            cur.hasMore = page.hasMore && !page.comments.isEmpty
            cur.loading = false
            replies[c.id] = cur
        } catch {
            var cur = replies[c.id] ?? st
            cur.loading = false
            cur.error = "需要先完成抖音的安全验证才能查看回复"
            replies[c.id] = cur
        }
    }

    private func load(_ a: Aweme?, reset: Bool) async {
        guard let a, !loading, hasMore || reset else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await model.api.comments(awemeId: a.id, cursor: reset ? 0 : cursor)
            guard model.engine.current?.id == a.id else { return }
            let existing = Set(comments.map(\.id))
            comments += page.comments.filter { !existing.contains($0.id) }
            cursor = page.cursor
            hasMore = page.hasMore && !page.comments.isEmpty
            total = max(total, page.total)
            error = nil
        } catch {
            self.error = "评论加载失败：\(error.localizedDescription)"
            hasMore = false
        }
    }
}

private struct CommentRow: View {
    let comment: Comment

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(url: comment.avatarURL, size: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(comment.nickname)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(comment.text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Text(Fmt.ago(comment.date))
                    if let ip = comment.ipLabel { Text(ip) }
                    Spacer()
                    Label(Fmt.count(comment.diggCount), systemImage: "heart")
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            }
        }
    }
}


struct ReplyState {
    var items: [Comment] = []
    var cursor = 0
    var hasMore = true
    var loading = false
    var expanded = false
    var error: String?
}

/// 评论下面的回复区：展开 N 条回复 / 展开更多 / 收起
private struct RepliesSection: View {
    let comment: Comment
    let state: ReplyState
    let onLoad: () -> Void
    let onCollapse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if state.expanded {
                ForEach(state.items) { r in
                    ReplyRow(reply: r)
                }
            }
            if let err = state.error {
                HStack(spacing: 8) {
                    Text(err).font(.system(size: 11)).foregroundStyle(Theme.accent2)
                    Button("去验证") {
                        AppModel.shared.bridge.allowVerificationPopup()
                        onLoad()
                    }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                }
            }
            HStack(spacing: 14) {
                if state.loading {
                    ProgressView().controlSize(.mini)
                    Text("正在加载回复…").font(.system(size: 11)).foregroundStyle(.secondary)
                } else if !state.expanded {
                    replyButton("展开 \(comment.replyCount) 条回复", icon: "chevron.down", action: onLoad)
                } else {
                    if state.hasMore && state.error == nil {
                        replyButton("展开更多回复", icon: "chevron.down", action: onLoad)
                    }
                    replyButton("收起", icon: "chevron.up", action: onCollapse)
                }
            }
        }
        .padding(.leading, 42)
    }

    private func replyButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Rectangle().fill(Color.white.opacity(0.25)).frame(width: 16, height: 1)
                Text(title)
                Image(systemName: icon).font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ReplyRow: View {
    let reply: Comment

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Avatar(url: reply.avatarURL, size: 24)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(reply.nickname)
                    if let to = reply.replyTo {
                        Image(systemName: "arrowtriangle.right.fill").font(.system(size: 7))
                        Text(to)
                    }
                }
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                Text(reply.text)
                    .font(.system(size: 12.5))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Text(Fmt.ago(reply.date))
                    if let ip = reply.ipLabel { Text(ip) }
                    Spacer()
                    Label(Fmt.count(reply.diggCount), systemImage: "heart")
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }
        }
    }
}
