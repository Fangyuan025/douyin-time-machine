import Foundation

/// 抖音网页接口的类型化封装。所有请求都经由 DouyinBridge 在网页上下文中发出。
@MainActor
final class DouyinAPI {
    let bridge: DouyinBridge

    init(bridge: DouyinBridge) { self.bridge = bridge }

    private func awemes(_ list: J) -> [Aweme] {
        list.array.compactMap { Aweme($0) }
    }

    // MARK: 推荐流

    func recommendFeed(refreshIndex: Int) async throws -> [Aweme] {
        let j = try await bridge.get("/aweme/v1/web/tab/feed/", [
            "count": "10",
            "video_type_select": "1",
            "refresh_index": String(refreshIndex),
            "aweme_pc_rec_raw_data": #"{"is_client":false}"#,
            "refer_type": "10",
            "use_lite_type": "0",
            "xigua_user": "0",
        ])
        return awemes(j["aweme_list"])
    }

    // MARK: 用户作品（时光机核心：max_cursor 是毫秒时间戳，可以直接跳到任意时间点往前翻）

    func userPosts(secUid: String, maxCursor: Int, count: Int = 25) async throws -> PostPage {
        let j = try await bridge.get("/aweme/v1/web/aweme/post/", [
            "sec_user_id": secUid,
            "max_cursor": String(maxCursor),
            "count": String(count),
            "locate_query": "false",
            "show_live_replay_strategy": "1",
            "need_time_list": "1",
            "time_list_query": "0",
            "whale_cut_token": "",
            "cut_version": "1",
            "publish_video_strategy_type": "2",
            "from_user_page": "1",
        ])
        return PostPage(
            awemes: awemes(j["aweme_list"]),
            hasMore: j["has_more"].bool ?? false,
            maxCursor: j["max_cursor"].int ?? 0,
            timeList: j["time_list"].array.compactMap { $0.string })
    }

    /// 用户喜欢的作品（自己的喜欢列表用于冷启动兴趣画像）
    func likedPosts(secUid: String, maxCursor: Int = 0) async throws -> PostPage {
        let j = try await bridge.get("/aweme/v1/web/aweme/favorite/", [
            "sec_user_id": secUid,
            "max_cursor": String(maxCursor),
            "min_cursor": "0",
            "count": "18",
            "whale_cut_token": "",
            "cut_version": "1",
            "publish_video_strategy_type": "2",
        ])
        return PostPage(awemes: awemes(j["aweme_list"]), hasMore: j["has_more"].bool ?? false,
                        maxCursor: j["max_cursor"].int ?? 0, timeList: [])
    }

    /// 相关推荐（未登录也可用），用于扩充创作者池
    func related(awemeId: String) async throws -> [Aweme] {
        let j = try await bridge.get("/aweme/v1/web/aweme/related/", [
            "aweme_id": awemeId,
            "count": "20",
            "filterGids": "",
            "awemePcRecRawData": #"{"is_client":false}"#,
            "sub_channel_id": "3",
        ])
        return awemes(j["aweme_list"])
    }

    func awemeDetail(id: String) async throws -> Aweme? {
        let j = try await bridge.get("/aweme/v1/web/aweme/detail/", ["aweme_id": id])
        return Aweme(j["aweme_detail"])
    }

    // MARK: 搜索

    /// sortType：0 综合，1 最多点赞（适合找老视频），2 最新发布
    func searchVideos(keyword: String, offset: Int = 0, sortType: Int = 0) async throws -> [Aweme] {
        let j = try await bridge.get("/aweme/v1/web/search/item/", [
            "sort_type": String(sortType),
            "publish_time": "0",
            "search_channel": "aweme_video_web",
            "enable_history": "1",
            "keyword": keyword,
            "search_source": "normal_search",
            "query_correct_type": "1",
            "is_filter_search": "0",
            "from_group_id": "",
            "offset": String(offset),
            "count": "15",
            "need_filter_settings": "1",
            "list_type": "single",
        ])
        return j["data"].array.compactMap { Aweme($0["aweme_info"]) }
    }

    // MARK: 话题

    /// 话题页视频列表。sortType：0 热门，1 最新
    func challengeVideos(chId: String, cursor: Int = 0, sortType: Int = 0) async throws -> (awemes: [Aweme], hasMore: Bool, cursor: Int) {
        let j = try await bridge.get("/aweme/v1/web/challenge/aweme/", [
            "ch_id": chId,
            "cursor": String(cursor),
            "count": "20",
            "sort_type": String(sortType),
        ])
        return (j["aweme_list"].array.compactMap { Aweme($0) }, j["has_more"].bool ?? false, j["cursor"].int ?? 0)
    }

    // MARK: 用户

    func selfProfile() async throws -> UserProfile? {
        let j = try await bridge.get("/aweme/v1/web/user/profile/self/", [
            "publish_video_strategy_type": "2",
            "personal_center_strategy": "1",
        ])
        return UserProfile(j["user"])
    }

    func userProfile(secUid: String) async throws -> UserProfile? {
        let j = try await bridge.get("/aweme/v1/web/user/profile/other/", [
            "sec_user_id": secUid,
            "publish_video_strategy_type": "2",
            "personal_center_strategy": "1",
        ])
        return UserProfile(j["user"])
    }

    func following(userId: String, secUid: String, offset: Int, maxTime: Int = 0, count: Int = 20) async throws -> (users: [Author], hasMore: Bool, minTime: Int) {
        let j = try await bridge.get("/aweme/v1/web/user/following/list/", [
            "user_id": userId,
            "sec_user_id": secUid,
            "offset": String(offset),
            "min_time": "0",
            "max_time": String(maxTime),
            "count": String(count),
            "source_type": "4",
            "gps_access": "0",
            "address_book_access": "0",
            "is_top": "1",
        ])
        let users = j["followings"].array.compactMap { Author($0) }
        return (users, j["has_more"].bool ?? false, j["min_time"].int ?? 0)
    }

    // MARK: 评论

    func comments(awemeId: String, cursor: Int) async throws -> CommentPage {
        let j = try await bridge.get("/aweme/v1/web/comment/list/", [
            "aweme_id": awemeId,
            "cursor": String(cursor),
            "count": "20",
            "item_type": "0",
            "insert_ids": "",
            "whale_cut_token": "",
            "cut_version": "1",
            "rcFT": "",
        ])
        return CommentPage(
            comments: j["comments"].array.compactMap { Comment($0) },
            hasMore: j["has_more"].bool ?? false,
            cursor: j["cursor"].int ?? 0,
            total: j["total"].int ?? 0)
    }

    /// 某条评论下的回复
    func commentReplies(awemeId: String, commentId: String, cursor: Int, count: Int = 10) async throws -> CommentPage {
        // 查看回复常会触发抖音的人机验证，按交互式请求处理（会把验证交给用户完成）
        let j = try await bridge.get("/aweme/v1/web/comment/list/reply/", [
            "item_id": awemeId,
            "comment_id": commentId,
            "cut_version": "1",
            "cursor": String(cursor),
            "count": String(count),
            "item_type": "0",
        ], interactive: true)
        return CommentPage(
            comments: j["comments"].array.compactMap { Comment($0) },
            hasMore: j["has_more"].bool ?? false,
            cursor: j["cursor"].int ?? 0,
            total: j["total"].int ?? 0)
    }

    // MARK: 互动

    func digg(awemeId: String, on: Bool) async throws {
        _ = try await bridge.post("/aweme/v1/web/commit/item/digg/", form: [
            "aweme_id": awemeId, "item_type": "0", "type": on ? "1" : "0",
        ])
    }

    func collect(awemeId: String, on: Bool) async throws {
        _ = try await bridge.post("/aweme/v1/web/aweme/collect/", form: [
            "aweme_id": awemeId, "action": on ? "1" : "0", "aweme_type": "0",
        ])
    }

    func follow(userId: String, secUid: String, on: Bool) async throws {
        _ = try await bridge.post("/aweme/v1/web/commit/follow/user/", form: [
            "type": on ? "1" : "0", "user_id": userId, "sec_user_id": secUid,
        ])
    }
}
