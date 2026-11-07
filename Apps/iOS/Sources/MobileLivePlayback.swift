import Foundation
import AVFoundation
import Observation

@MainActor @Observable final class LivePlaybackState {
    private(set) var player: AVPlayer?
    private(set) var preparing = false
    private(set) var notice = "正在连接直播…"
    private(set) var error: String?
    @ObservationIgnored private var sources: [URL] = []
    @ObservationIgnored private var sourceIndex = 0
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var itemObservation: NSKeyValueObservation?
    @ObservationIgnored private var timeObservation: NSKeyValueObservation?
    @ObservationIgnored private var failureNotification: NSObjectProtocol?
    @ObservationIgnored private var watchdog: Task<Void, Never>?

    func beginLoading() {
        error = nil
        preparing = true
        notice = "正在获取直播地址…"
    }
    func open(_ urls: [URL]) {
        stop()
        error = nil
        var seen = Set<URL>()
        sources = Array(urls.filter { seen.insert($0).inserted }.prefix(6))
        guard !sources.isEmpty else { fail("没有可用的直播播放源，请重试。"); return }
        let player = AVPlayer()
        player.isMuted = false
        player.volume = 1
        self.player = player
        installSource(at: 0)
    }
    func stop() {
        generation = UUID()
        watchdog?.cancel(); watchdog = nil
        itemObservation?.invalidate(); itemObservation = nil
        timeObservation?.invalidate(); timeObservation = nil
        if let failureNotification { NotificationCenter.default.removeObserver(failureNotification) }
        failureNotification = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        sources = []
        preparing = false
    }
    func fail(_ message: String) {
        stop()
        error = message
    }
    private func installSource(at index: Int) {
        guard let player, sources.indices.contains(index) else { return }
        generation = UUID()
        let token = generation
        sourceIndex = index
        watchdog?.cancel()
        itemObservation?.invalidate()
        timeObservation?.invalidate()
        if let failureNotification { NotificationCenter.default.removeObserver(failureNotification) }
        preparing = true
        notice = index == 0 ? "正在连接直播…" : "正在尝试备用播放源（\(index + 1)/\(sources.count)）…"
        let item = AVPlayerItem(url: sources[index])
        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let status = item.status.rawValue
            let failure = item.error.map { "\(($0 as NSError).domain) \(($0 as NSError).code)" } ?? "媒体加载失败"
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                if status == AVPlayerItem.Status.failed.rawValue { self.advance(after: failure, token: token) }
            }
        }
        timeObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let status = player.timeControlStatus.rawValue
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                if status == AVPlayer.TimeControlStatus.playing.rawValue {
                    self.preparing = false
                    self.watchdog?.cancel()
                } else if status == AVPlayer.TimeControlStatus.waitingToPlayAtSpecifiedRate.rawValue {
                    self.preparing = true
                    self.armWatchdog(token: token)
                } else if self.player?.currentItem?.status == .readyToPlay {
                    self.preparing = false
                    self.watchdog?.cancel()
                }
            }
        }
        failureNotification = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] notification in
            let failure = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
            let reason = failure.map { "\($0.domain) \($0.code)" } ?? "直播连接中断"
            Task { @MainActor [weak self] in self?.advance(after: reason, token: token) }
        }
        player.replaceCurrentItem(with: item)
        player.play()
        armWatchdog(token: token)
    }
    private func armWatchdog(token: UUID) {
        watchdog?.cancel()
        watchdog = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            guard let self, self.generation == token else { return }
            if self.player?.timeControlStatus == .waitingToPlayAtSpecifiedRate
                || self.player?.currentItem?.status == .unknown {
                self.advance(after: "播放源连接超时", token: token)
            }
        }
    }
    private func advance(after reason: String, token: UUID) {
        guard generation == token else { return }
        if sourceIndex + 1 < sources.count { installSource(at: sourceIndex + 1) }
        else { fail("直播播放失败（\(reason)）。已尝试可用播放源，请重试或换一个直播间。") }
    }
}
