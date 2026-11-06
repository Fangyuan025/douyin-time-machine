import Foundation
import CoreGraphics

struct Author: Codable, Hashable, Identifiable {
    var uid: String
    var secUid: String
    var nickname: String
    var avatarURL: URL?
    /// 粉丝数（接口不一定返回）
    var followerCount: Int?
    /// 机构 / 媒体 / 官方认证账号
    var isInstitution: Bool?

    var id: String { secUid.isEmpty ? uid : secUid }

    init(uid: String, secUid: String, nickname: String, avatarURL: URL? = nil) {
        self.uid = uid
        self.secUid = secUid
        self.nickname = nickname
        self.avatarURL = avatarURL
    }

    init?(_ j: J) {
        let sec = j["sec_uid"].string ?? ""
        let uid = j["uid"].string ?? ""
        guard !sec.isEmpty else { return nil }
        self.uid = uid
        self.secUid = sec
        self.nickname = j["nickname"].string.flatMap { $0.isEmpty ? nil : $0 } ?? "抖音用户"
        self.avatarURL = j["avatar_thumb"].urlList.first
            ?? j["avatar_168x168"].urlList.first
            ?? j["avatar_medium"].urlList.first
            ?? j["avatar_larger"].urlList.first
        if let f = j["follower_count"].int, f > 0 { self.followerCount = f }
        let enterprise = j["enterprise_verify_reason"].string ?? ""
        let custom = j["custom_verify"].string ?? ""
        let institutionWords = ["官方", "媒体", "机构", "政务", "新闻", "日报", "电视台", "广播", "融媒"]
        if !enterprise.isEmpty || institutionWords.contains(where: { custom.contains($0) || self.nickname.contains($0) }) {
            self.isInstitution = true
        } else if !custom.isEmpty || j["follower_count"].exists {
            self.isInstitution = false
        }
    }
}

struct Aweme: Codable, Hashable, Identifiable {
    var id: String
    var desc: String
    var createTime: Int
    var author: Author
    var coverURL: URL?
    var playURLs: [URL]
    var duration: Double
    var width: Int
    var height: Int
    var diggCount: Int
    var commentCount: Int
    var collectCount: Int
    var shareCount: Int
    var hashtags: [String]
    var mentions: [Author]
    var isTop: Bool
    var userDigged: Bool
    var userCollected: Bool
    var musicTitle: String?
    var isAd: Bool
    var isImagePost: Bool
    /// 抖音内容分类（video_tag，按层级 1→3），旧数据里没有这个字段
    var categories: [String]?
    /// 推荐理由（由推荐引擎在入队时填写）
    var reason: String?
    /// 话题名 → 话题 ID（用于翻话题页）
    var hashtagIDs: [String: String]?

    var cats: [String] { categories ?? [] }
    var primaryCategory: String? { categories?.first }
    var monthIndex: Int { YearMonth(timestamp: createTime).index }

    var date: Date { Date(timeIntervalSince1970: TimeInterval(createTime)) }
    var shareURL: URL { URL(string: "https://www.douyin.com/video/\(id)")! }
    var isPlayable: Bool { !playURLs.isEmpty && !isImagePost && !isAd }
    var aspect: CGFloat {
        guard width > 0, height > 0 else { return 9.0 / 16.0 }
        return CGFloat(width) / CGFloat(height)
    }

    /// 抖音作品 ID 的高 32 位就是发布时间戳（秒），create_time 缺失时用它兜底。
    static func timestamp(fromID id: String) -> Int? {
        guard let n = UInt64(id), n > (1 << 32) else { return nil }
        let ts = Int(n >> 32)
        return ts > 1_400_000_000 ? ts : nil
    }

    private static func bitRate(_ b: J) -> Int { b["bit_rate"].int ?? 0 }

    init?(_ j: J) {
        guard let id = j["aweme_id"].string, !id.isEmpty,
              let author = Author(j["author"]) else { return nil }
        self.id = id
        self.author = author
        self.desc = j["desc"].string ?? ""
        var ct = j["create_time"].int ?? 0
        if ct <= 0 { ct = Aweme.timestamp(fromID: id) ?? 0 }
        self.createTime = ct

        let v = j["video"]
        var urls: [URL] = []
        // 优先 H.264 mp4（兼容性最好）；720p 起播最快、清晰度也够，其次 1080p、540p
        func gearRank(_ b: J) -> Int {
            let g = b["gear_name"].string ?? ""
            if g.contains("720") { return 0 }
            if g.contains("1080") { return 1 }
            if g.contains("540") { return 2 }
            return 3
        }
        let h264 = v["bit_rate"].array
            .filter { ($0["format"].string ?? "mp4") == "mp4" && ($0["is_h265"].int ?? 0) == 0 }
            .sorted { a, b in
                let ra = gearRank(a), rb = gearRank(b)
                return ra != rb ? ra < rb : (Aweme.bitRate(a) > Aweme.bitRate(b))
            }
        for b in h264 { urls += b["play_addr"].urlList }
        urls += v["play_addr_h264"].urlList
        urls += v["play_addr"].urlList
        var seen = Set<String>()
        var unique: [URL] = []
        for u in urls {
            var s = u.absoluteString
            if s.hasPrefix("http://") { s = "https://" + s.dropFirst(7) }
            guard let fixed = URL(string: s), seen.insert(s).inserted else { continue }
            unique.append(fixed)
        }
        // 绑定网页会话的地址（tk=webid）放到最后，CDN 直链优先
        self.playURLs = unique.filter { !$0.absoluteString.contains("tk=webid") }
            + unique.filter { $0.absoluteString.contains("tk=webid") }

        self.coverURL = v["cover"].urlList.first ?? v["origin_cover"].urlList.first ?? v["dynamic_cover"].urlList.first
        let durMs = v["duration"].double ?? j["duration"].double ?? 0
        self.duration = durMs > 1000 ? durMs / 1000 : durMs
        self.width = v["width"].int ?? v["play_addr"]["width"].int ?? 0
        self.height = v["height"].int ?? v["play_addr"]["height"].int ?? 0

        let st = j["statistics"]
        self.diggCount = st["digg_count"].int ?? 0
        self.commentCount = st["comment_count"].int ?? 0
        self.collectCount = st["collect_count"].int ?? 0
        self.shareCount = st["share_count"].int ?? 0

        let extras = j["text_extra"].array
        self.hashtags = extras.compactMap { $0["hashtag_name"].string }.filter { !$0.isEmpty }
        var ids: [String: String] = [:]
        for te in extras {
            if let n = te["hashtag_name"].string, !n.isEmpty, let id = te["hashtag_id"].string, !id.isEmpty, id != "0" { ids[n] = id }
        }
        self.hashtagIDs = ids.isEmpty ? nil : ids
        let ns = (j["desc"].string ?? "") as NSString
        self.mentions = extras.compactMap { te -> Author? in
            guard let sec = te["sec_uid"].string, !sec.isEmpty, sec != author.secUid else { return nil }
            var name = ""
            if let s = te["start"].int, let e = te["end"].int, s >= 0, e > s, e <= ns.length {
                name = ns.substring(with: NSRange(location: s, length: e - s)).replacingOccurrences(of: "@", with: "")
            }
            return Author(uid: te["user_id"].string ?? "", secUid: sec, nickname: name.isEmpty ? "抖音用户" : name)
        }

        self.isTop = (j["is_top"].int ?? 0) == 1
        self.userDigged = (j["user_digged"].int ?? 0) == 1
        self.userCollected = (j["collect_stat"].int ?? 0) == 1
        self.musicTitle = j["music"]["title"].string
        self.isAd = j["is_ads"].bool == true
        let tags = j["video_tag"].array
            .compactMap { t -> (Int, String)? in
                guard let name = t["tag_name"].string, !name.isEmpty else { return nil }
                return (t["level"].int ?? 9, name)
            }
            .sorted { $0.0 < $1.0 }
            .map(\.1)
        self.categories = tags.isEmpty ? nil : tags
        let type = j["aweme_type"].int ?? 0
        self.isImagePost = !j["images"].array.isEmpty || type == 68 || type == 150
    }
}

struct Comment: Identifiable, Hashable {
    var id: String
    var text: String
    var createTime: Int
    var diggCount: Int
    var replyCount: Int
    var ipLabel: String?
    var nickname: String
    var avatarURL: URL?
    /// 回复里“回复给谁”（楼中楼）
    var replyTo: String?

    var date: Date { Date(timeIntervalSince1970: TimeInterval(createTime)) }

    init?(_ j: J) {
        guard let cid = j["cid"].string else { return nil }
        id = cid
        text = j["text"].string ?? ""
        createTime = j["create_time"].int ?? 0
        diggCount = j["digg_count"].int ?? 0
        replyCount = j["reply_comment_total"].int ?? 0
        let ip = j["ip_label"].string ?? ""
        ipLabel = ip.isEmpty ? nil : ip
        nickname = j["user"]["nickname"].string ?? "抖音用户"
        avatarURL = j["user"]["avatar_thumb"].urlList.first
        let to = j["reply_to_username"].string ?? ""
        replyTo = to.isEmpty ? nil : to
    }
}

struct UserProfile: Codable, Hashable {
    var uid: String
    var secUid: String
    var nickname: String
    var avatarURL: URL?
    var signature: String
    var followerCount: Int
    var followingCount: Int
    var awemeCount: Int
    var totalFavorited: Int
    var isFollowing: Bool

    init?(_ u: J) {
        guard let sec = u["sec_uid"].string, !sec.isEmpty else { return nil }
        uid = u["uid"].string ?? ""
        secUid = sec
        nickname = u["nickname"].string ?? "抖音用户"
        avatarURL = u["avatar_larger"].urlList.first ?? u["avatar_300x300"].urlList.first
            ?? u["avatar_168x168"].urlList.first ?? u["avatar_thumb"].urlList.first
        signature = u["signature"].string ?? ""
        followerCount = u["follower_count"].int ?? u["mplatform_followers_count"].int ?? 0
        followingCount = u["following_count"].int ?? 0
        awemeCount = u["aweme_count"].int ?? 0
        totalFavorited = u["total_favorited"].int ?? 0
        isFollowing = (u["follow_status"].int ?? 0) != 0
    }

    var asAuthor: Author { Author(uid: uid, secUid: secUid, nickname: nickname, avatarURL: avatarURL) }
}

struct PostPage {
    var awemes: [Aweme]
    var hasMore: Bool
    var maxCursor: Int
    /// need_time_list=1 时返回的“有作品的年份/月份”
    var timeList: [String]
}

struct CommentPage {
    var comments: [Comment]
    var hasMore: Bool
    var cursor: Int
    var total: Int
}
