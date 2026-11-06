import SwiftUI

struct AuthorSheet: View {
    let author: Author
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    enum Scope: String, CaseIterable { case window, all }

    @State private var profile: UserProfile?
    @State private var scope: Scope = .window
    @State private var posts: [Aweme] = []
    @State private var cursor: Int?
    @State private var hasMore = true
    @State private var loading = false
    @State private var error: String?
    @State private var following = false

    private var window: TimeWindow { model.engine.window }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("", selection: $scope) {
                Text("\(window.description) 的作品").tag(Scope.window)
                Text("全部作品").tag(Scope.all)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 10)], spacing: 10) {
                    ForEach(posts) { p in
                        PostTile(aweme: p)
                            .onTapGesture {
                                model.playNow(p)
                                dismiss()
                            }
                    }
                }
                .padding(.horizontal, 20)

                Group {
                    if let error {
                        VStack(spacing: 8) {
                            Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button("重试") { Task { await loadMore() } }
                        }
                    } else if loading {
                        ProgressView().controlSize(.small)
                    } else if hasMore {
                        Button("加载更多") { Task { await loadMore() } }
                            .onAppear { Task { await loadMore() } }
                    } else if posts.isEmpty {
                        Text(scope == .window ? "TA 在 \(window.description) 没有发布作品" : "没有作品")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 12))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            }
        }
        .frame(width: 780, height: 640)
        .preferredColorScheme(.dark)
        .task {
            await loadProfile()
        }
        .task(id: scope) {
            posts = []
            cursor = nil
            hasMore = true
            error = nil
            await loadMore()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Avatar(url: profile?.avatarURL ?? author.avatarURL, size: 72)
            VStack(alignment: .leading, spacing: 6) {
                Text(profile?.nickname ?? author.nickname)
                    .font(.system(size: 20, weight: .bold))
                if let s = profile?.signature, !s.isEmpty {
                    Text(s)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                if let p = profile {
                    HStack(spacing: 16) {
                        stat("粉丝", p.followerCount)
                        stat("获赞", p.totalFavorited)
                        stat("关注", p.followingCount)
                        stat("作品", p.awemeCount)
                    }
                    .padding(.top, 2)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 10) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                        .frame(width: 24, height: 24)
                        .background(Color.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                if model.isLoggedIn, profile != nil {
                    Button(following ? "已关注" : "关注") { toggleFollow() }
                        .buttonStyle(.borderedProminent)
                        .tint(following ? .gray : Theme.accent)
                }
                Button("在浏览器中打开") {
                    NSWorkspace.shared.open(URL(string: "https://www.douyin.com/user/\(author.secUid)")!)
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }
        }
        .padding(20)
    }

    private func stat(_ t: String, _ v: Int) -> some View {
        HStack(spacing: 3) {
            Text(Fmt.count(v)).font(.system(size: 13, weight: .bold))
            Text(t).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func loadProfile() async {
        do {
            profile = try await model.api.userProfile(secUid: author.secUid)
            following = profile?.isFollowing ?? false
        } catch {
            logWarn("作者资料加载失败：\(error.localizedDescription)")
        }
    }

    private func loadMore() async {
        guard !loading, hasMore else { return }
        loading = true
        defer { loading = false }
        let currentScope = scope
        let start = cursor ?? (currentScope == .window ? window.endTS * 1000 : 0)
        do {
            let page = try await model.api.userPosts(secUid: author.secUid, maxCursor: start)
            guard currentScope == scope else { return }
            let playable = page.awemes.filter(\.isPlayable)
            let existing = Set(posts.map(\.id))
            if currentScope == .window {
                posts += playable.filter { window.contains($0.createTime) && !existing.contains($0.id) }
                let oldest = page.awemes.filter { !$0.isTop }.map(\.createTime).min() ?? 0
                hasMore = page.hasMore && oldest >= window.startTS && page.maxCursor > 0 && page.maxCursor != start
            } else {
                posts += playable.filter { !existing.contains($0.id) }
                hasMore = page.hasMore && page.maxCursor > 0 && page.maxCursor != start
            }
            cursor = page.maxCursor
            error = nil
        } catch {
            hasMore = false
            self.error = model.isLoggedIn
                ? "加载失败：\(error.localizedDescription)"
                : "查看创作者作品需要先登录抖音账号"
        }
    }

    private func toggleFollow() {
        guard let p = profile else { return }
        let on = !following
        following = on
        Task {
            do {
                try await model.api.follow(userId: p.uid, secUid: p.secUid, on: on)
                model.showToast(on ? "已关注 \(p.nickname)" : "已取消关注")
            } catch {
                following = !on
                model.showToast("操作失败：\(error.localizedDescription)")
            }
        }
    }
}

struct PostTile: View {
    let aweme: Aweme
    @State private var hover = false

    var body: some View {
        RemoteImage(url: aweme.coverURL)
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Fmt.dayFormatter.string(from: aweme.date))
                        .font(.system(size: 11, weight: .semibold))
                    Label(Fmt.count(aweme.diggCount), systemImage: "heart.fill")
                        .font(.system(size: 10.5))
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(hover ? Theme.accent : Color.white.opacity(0.08), lineWidth: hover ? 2 : 1)
            )
            .scaleEffect(hover ? 1.02 : 1)
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
            .help(aweme.desc)
            .contentShape(Rectangle())
    }
}
