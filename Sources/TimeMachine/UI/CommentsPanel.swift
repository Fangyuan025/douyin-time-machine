import SwiftUI

struct CommentsPanel: View {
    @Environment(AppModel.self) private var model
    @State private var comments: [Comment] = []
    @State private var cursor = 0
    @State private var hasMore = true
    @State private var loading = false
    @State private var total = 0
    @State private var error: String?

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
                        CommentRow(comment: c)
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
            await load(a, reset: true)
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
                    if comment.replyCount > 0 { Text("\(comment.replyCount) 条回复") }
                    Spacer()
                    Label(Fmt.count(comment.diggCount), systemImage: "heart")
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            }
        }
    }
}
