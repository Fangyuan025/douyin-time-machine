import Foundation

/// 本地兴趣画像：从观看时长、点赞、收藏、不感兴趣等行为中持续学习三类偏好：
/// - 作者：喜欢 / 不喜欢谁
/// - 话题：#hashtag
/// - 内容分类：抖音自带的三级分类（如 音乐 › 音乐演唱），比话题稠密得多，冷启动更快
struct InterestProfile: Codable {
    var authors: [String: Double] = [:]
    var tags: [String: Double] = [:]
    var categories: [String: Double] = [:]
    var events: Int = 0

    enum Signal {
        /// 观看结束：完成度（0~1）与实际观看秒数
        case watched(fraction: Double, seconds: Double)
        case liked, unliked, collected, uncollected, openedComments, openedAuthor, seed, notInterested

        /// 奖励值：正数加分，负数减分
        var reward: Double {
            switch self {
            case .watched(let f, let s):
                if s < 1.2 { return -1.0 }                 // 秒划：强烈的负反馈
                if f < 0.15 && s < 3 { return -0.6 }       // 很快跳过
                if f >= 0.95 { return 1.3 }                // 看完
                if s >= 45 { return 1.0 }                  // 长视频看了很久
                return -0.2 + f * 1.2                      // 线性：看得越多越喜欢
            case .liked: return 2.5
            case .unliked: return -2.0
            case .collected: return 3.0
            case .uncollected: return -2.0
            case .openedComments: return 0.6
            case .openedAuthor: return 0.8
            case .seed: return 0.5
            case .notInterested: return -4.0
            }
        }
    }

    init() {}

    /// 兼容旧版本保存的数据（旧数据没有 categories 字段）
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        authors = try c.decodeIfPresent([String: Double].self, forKey: .authors) ?? [:]
        tags = try c.decodeIfPresent([String: Double].self, forKey: .tags) ?? [:]
        categories = try c.decodeIfPresent([String: Double].self, forKey: .categories) ?? [:]
        events = try c.decodeIfPresent(Int.self, forKey: .events) ?? 0
    }

    mutating func record(_ signal: Signal, aweme: Aweme) {
        record(signal, authorSec: aweme.author.secUid, tags: aweme.hashtags, categories: aweme.cats)
    }

    mutating func record(_ signal: Signal, authorSec: String, tags newTags: [String], categories cats: [String] = []) {
        let w = signal.reward
        events += 1
        if events % 60 == 0 { decay(0.96) }
        authors[authorSec] = min(15, max(-8, (authors[authorSec] ?? 0) + w))
        for t in newTags.prefix(6) {
            tags[t] = min(10, max(-5, (tags[t] ?? 0) + w * 0.5))
        }
        // 一级分类权重最高，越细的分类越低
        for (i, cat) in cats.prefix(3).enumerated() {
            let lw = [0.5, 0.35, 0.25][i]
            categories[cat] = min(10, max(-6, (categories[cat] ?? 0) + w * lw))
        }
        if authors.count > 2000 { prune(&authors, keep: 1500) }
        if tags.count > 1500 { prune(&tags, keep: 1000) }
        if categories.count > 800 { prune(&categories, keep: 600) }
    }

    /// 兴趣分，约在 [-3, 3.5] 之间
    func score(_ a: Aweme) -> Double {
        let au = authors[a.author.secUid] ?? 0
        let tagScores = a.hashtags.compactMap { tags[$0] }.sorted(by: >).prefix(3)
        let t = tagScores.reduce(0, +)
        var c = 0.0
        for (i, cat) in a.cats.prefix(3).enumerated() {
            c += (categories[cat] ?? 0) * [1.0, 0.7, 0.5][i]
        }
        return squash(au) * 1.4 + squash(t) * 0.8 + squash(c) * 1.0
    }

    /// 这条视频最打动用户的兴趣点（用于推荐理由）
    func strongestMatch(_ a: Aweme) -> String? {
        var best: (String, Double)?
        for cat in a.cats.prefix(2) {
            if let v = categories[cat], v > 1.5, v > (best?.1 ?? 0) { best = ("「\(cat)」", v) }
        }
        for t in a.hashtags.prefix(4) {
            if let v = tags[t], v > 1.5, v > (best?.1 ?? 0) { best = ("#\(t)", v) }
        }
        return best?.0
    }

    func topTags(_ n: Int) -> [String] {
        tags.filter { $0.value > 0.5 }.sorted { $0.value > $1.value }.prefix(n).map(\.key)
    }

    func topCategories(_ n: Int) -> [String] {
        categories.filter { $0.value > 0.5 }.sorted { $0.value > $1.value }.prefix(n).map(\.key)
    }

    private func squash(_ x: Double) -> Double { x / (abs(x) + 4) * 2 }

    private mutating func decay(_ f: Double) {
        for k in authors.keys { authors[k]! *= f }
        for k in tags.keys { tags[k]! *= f }
        for k in categories.keys { categories[k]! *= f }
    }

    private func prune(_ d: inout [String: Double], keep: Int) {
        let kept = d.sorted { abs($0.value) > abs($1.value) }.prefix(keep)
        d = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }
}
