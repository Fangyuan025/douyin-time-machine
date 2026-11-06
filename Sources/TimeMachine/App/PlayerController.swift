import AVFoundation
import AppKit
import Observation

/// 原生 AVPlayer 播放控制：多地址回退、过期地址刷新、预缓冲、观看时长统计。
///
/// 预缓冲用两个播放器轮换：一个在前台播放，另一个静音挂着下一条视频提前缓冲；
/// 切到下一条时直接交换两者的角色（AVPlayerItem 一生只能挂在一个 AVPlayer 上，不能“搬”过去）。
@MainActor @Observable
final class PlayerController {
    /// 前台播放器（交换后会变，界面需要跟着它）
    private(set) var player = AVPlayer()

    private(set) var current: Aweme?
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var failed = false
    private(set) var position: Double = 0
    private(set) var duration: Double = 0

    var volume: Float = UserDefaults.standard.object(forKey: "volume") as? Float ?? 0.8 {
        didSet {
            player.volume = volume
            UserDefaults.standard.set(volume, forKey: "volume")
        }
    }
    var muted = false {
        didSet { player.isMuted = muted }
    }

    @ObservationIgnored var autoAdvance = true
    @ObservationIgnored var onEnded: (() -> Void)?
    /// 所有地址都失败时调用，用详情接口拿新的播放地址
    @ObservationIgnored var refresher: ((Aweme) async -> Aweme?)?

    @ObservationIgnored private var standby = AVPlayer()
    @ObservationIgnored private var standbyID: String?

    @ObservationIgnored private var urlIndex = 0
    @ObservationIgnored private var refreshed = Set<String>()
    @ObservationIgnored private var maxWatched: Double = 0
    @ObservationIgnored private var userPaused = false
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var timeObserverOwner: AVPlayer?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var controlObservation: NSKeyValueObservation?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var stallTask: Task<Void, Never>?

    init() {
        for p in [player, standby] { p.automaticallyWaitsToMinimizeStalling = true }
        standby.isMuted = true
        player.volume = volume
        bind(player)
    }

    // MARK: - 播放器观察

    private func bind(_ p: AVPlayer) {
        if let timeObserver, let owner = timeObserverOwner { owner.removeTimeObserver(timeObserver) }
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, self.player === p else { return }
                let s = t.seconds
                if s.isFinite {
                    self.position = s
                    self.maxWatched = max(self.maxWatched, s)
                }
                if let d = p.currentItem?.duration.seconds, d.isFinite, d > 0 { self.duration = d }
            }
        }
        timeObserverOwner = p
        controlObservation = p.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] obs, _ in
            let status = obs.timeControlStatus
            Task { @MainActor in
                guard let self, self.player === obs else { return }
                self.isPlaying = status == .playing
                self.isBuffering = status == .waitingToPlayAtSpecifiedRate
            }
        }
    }

    // MARK: - 加载

    struct WatchReport {
        let aweme: Aweme
        let seconds: Double
        let fraction: Double
    }

    /// 当前视频的观看情况（切换前调用）
    func watchReport() -> WatchReport? {
        guard let a = current else { return nil }
        let d = duration > 0 ? duration : max(a.duration, 1)
        return WatchReport(aweme: a, seconds: maxWatched, fraction: min(1, maxWatched / d))
    }

    func load(_ aweme: Aweme?) {
        stallTask?.cancel()
        current = aweme
        failed = false
        position = 0
        duration = aweme?.duration ?? 0
        maxWatched = 0
        userPaused = false
        urlIndex = 0
        guard let aweme else {
            player.replaceCurrentItem(with: nil)
            return
        }
        if standbyID == aweme.id, let item = standby.currentItem, item.status != .failed {
            swapToStandby()
            observe(item, for: aweme)
            player.play()
            watchForStall(aweme)
        } else {
            playURL(at: 0, for: aweme)
        }
    }

    /// 让已经缓冲好的待命播放器上台
    private func swapToStandby() {
        let old = player
        old.pause()
        old.replaceCurrentItem(with: nil)
        player = standby
        standby = old
        standby.isMuted = true
        standbyID = nil
        player.isMuted = muted
        player.volume = volume
        bind(player)
    }

    func preload(_ aweme: Aweme?) {
        guard let aweme, aweme.id != current?.id, standbyID != aweme.id, let url = aweme.playURLs.first else { return }
        let item = makeItem(url)
        item.preferredForwardBufferDuration = 6
        standbyID = aweme.id
        standby.replaceCurrentItem(with: item)
        standby.pause()
    }

    private func makeItem(_ url: URL) -> AVPlayerItem {
        let headers = ["Referer": "https://www.douyin.com/", "User-Agent": kDouyinUA]
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        return AVPlayerItem(asset: asset)
    }

    private func playURL(at index: Int, for aweme: Aweme) {
        guard index < aweme.playURLs.count else {
            tryRefresh(aweme)
            return
        }
        urlIndex = index
        let item = makeItem(aweme.playURLs[index])
        observe(item, for: aweme)
        player.replaceCurrentItem(with: item)
        player.play()
        watchForStall(aweme)
    }

    private func observe(_ item: AVPlayerItem, for aweme: Aweme) {
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] it, _ in
            let status = it.status
            let err = it.error?.localizedDescription
            Task { @MainActor in
                guard let self, self.current?.id == aweme.id, self.player.currentItem === it else { return }
                if status == .failed {
                    logWarn("播放地址 #\(self.urlIndex + 1) 失败：\(err ?? "未知错误")")
                    self.playURL(at: self.urlIndex + 1, for: aweme)
                }
            }
        }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.player.currentItem === item else { return }
                self.maxWatched = max(self.maxWatched, self.duration)
                if self.autoAdvance, let onEnded = self.onEnded {
                    onEnded()
                } else {
                    self.player.seek(to: .zero)
                    self.player.play()
                }
            }
        }
    }

    /// 某个地址长时间没有起播时，换下一个地址
    private func watchForStall(_ aweme: Aweme) {
        stallTask?.cancel()
        let idx = urlIndex
        stallTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 9_000_000_000)
            guard let self, !Task.isCancelled, self.current?.id == aweme.id, self.urlIndex == idx else { return }
            if self.position < 0.1 && !self.userPaused && self.player.timeControlStatus != .playing {
                logWarn("起播超时，切换下一个地址")
                self.playURL(at: idx + 1, for: aweme)
            }
        }
    }

    private func tryRefresh(_ aweme: Aweme) {
        guard !refreshed.contains(aweme.id), let refresher else {
            failed = true
            return
        }
        refreshed.insert(aweme.id)
        Task { [weak self] in
            let fresh = await refresher(aweme)
            guard let self, self.current?.id == aweme.id else { return }
            if let fresh, !fresh.playURLs.isEmpty {
                log("已刷新播放地址")
                self.current = fresh
                self.playURL(at: 0, for: fresh)
            } else {
                self.failed = true
            }
        }
    }

    func retry() {
        guard let a = current else { return }
        refreshed.remove(a.id)
        failed = false
        playURL(at: 0, for: a)
    }

    // MARK: - 控制

    func togglePlay() {
        if player.timeControlStatus == .playing || player.rate > 0 {
            player.pause()
            userPaused = true
        } else {
            player.play()
            userPaused = false
        }
    }

    func pause() {
        player.pause()
        userPaused = true
    }

    func resume() {
        player.play()
        userPaused = false
    }

    func seek(to seconds: Double) {
        let t = max(0, min(seconds, duration > 0 ? duration - 0.2 : seconds))
        position = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func skip(_ delta: Double) { seek(to: position + delta) }

    func replaceCurrentMetadata(_ a: Aweme) {
        if current?.id == a.id { current = a }
    }
}
