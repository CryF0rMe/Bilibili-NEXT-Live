import SwiftUI
import AVKit

// Experimental public live viewer. Does not send login credentials.
private enum LiveAPI {
    static func request(_ endpoint: String) async throws -> [String: Any] {
        guard let url = URL(string: endpoint) else { throw LiveError.invalid }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("https://live.bilibili.com", forHTTPHeaderField: "Referer")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LiveError.invalid }
        return json
    }
    static func rooms() async throws -> [LiveRoom] {
        let root = try await request("https://api.live.bilibili.com/xlive/web-interface/v1/second/getList?platform=web&parent_area_id=0&area_id=0&page=1")
        let list = (root["data"] as? [String: Any])?["list"] as? [[String: Any]] ?? []
        return list.compactMap(LiveRoom.init)
    }
    static func stream(_ room: Int) async throws -> URL {
        let root = try await request("https://api.live.bilibili.com/room/v1/Room/playUrl?cid=\(room)&platform=h5&quality=10000")
        let list = (root["data"] as? [String: Any])?["durl"] as? [[String: Any]] ?? []
        guard let raw = list.first?["url"] as? String, let url = URL(string: raw) else { throw LiveError.invalid }
        return url
    }
}
private enum LiveError: LocalizedError {
    case invalid
    var errorDescription: String? { "无法获取直播内容，请稍后重试" }
}
private struct LiveRoom: Identifiable {
    let id: Int
    let title: String
    let username: String
    init?(_ json: [String: Any]) {
        let raw = json["roomid"] ?? json["room_id"]
        let id = (raw as? NSNumber)?.intValue ?? Int(raw as? String ?? "") ?? 0
        guard id > 0 else { return nil }
        self.id = id
        title = json["title"] as? String ?? "直播间 \(id)"
        username = json["uname"] as? String ?? "主播"
    }
}
struct MobileLiveHome: View {
    @State private var rooms: [LiveRoom] = []
    @State private var roomInput = ""
    @State private var selectedRoom: Int?
    @State private var error: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    TextField("输入直播间号", text: $roomInput).keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                    Button("进入") { selectedRoom = Int(roomInput) }
                }
                if let error { Text(error).foregroundStyle(.red) }
                ForEach(rooms) { room in
                    Button {
                        selectedRoom = room.id
                    } label: {
                        VStack(alignment: .leading) {
                            Text(room.title).font(.headline)
                            Text(room.username).font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.padding()
        }
        .navigationTitle("直播")
        .task { await reload() }
        .refreshable { await reload() }
        .navigationDestination(isPresented: Binding(
            get: { selectedRoom != nil },
            set: { if !$0 { selectedRoom = nil } }
        )) {
            if let selectedRoom { MobileLivePlayer(room: selectedRoom) }
        }
    }
    private func reload() async {
        do { rooms = try await LiveAPI.rooms(); error = nil }
        catch { self.error = error.localizedDescription }
    }
}
private struct MobileLivePlayer: View {
    let room: Int
    @State private var player: AVPlayer?
    @State private var error: String?
    @State private var loading = false
    @State private var retryRevision = 0
    @State private var fullscreen = false
    @State private var orientation = MobilePlayerOrientation()
    var body: some View {
        VStack(spacing: 16) {
            if let player {
                ZStack {
                    // Only one video surface owns the player at a time. Moving
                    // to fullscreen retains the live item and its playback state.
                    if fullscreen { Color.black }
                    else { VideoPlayer(player: player) }
                }.aspectRatio(16 / 9, contentMode: .fit)
                HStack {
                    Text("直播间 \(String(room))").font(.caption)
                    Spacer()
                    Button("全屏", systemImage: "arrow.up.left.and.arrow.down.right") {
                        orientation.remember()
                        fullscreen = true
                    }
                    .accessibilityIdentifier("live-enter-fullscreen")
                }.padding(.horizontal)
            } else if error == nil {
                ProgressView("正在加载直播")
                    .frame(maxWidth: .infinity, minHeight: 200)
            }
            if let error {
                VStack(spacing: 12) {
                    Text(error).foregroundStyle(.red)
                    Button("重试播放") { retryRevision += 1 }.disabled(loading)
                }.padding()
            }
            Spacer(minLength: 0)
        }
        .navigationTitle("直播间")
        .navigationBarTitleDisplayMode(.inline)
        .background(MobilePlayerWindowReader(orientation: orientation))
        .task(id: "\(room):\(retryRevision)") {
            // SwiftUI may restart this task after dismissing the cover. Keep
            // the same stream instead of resolving and opening it a second time.
            if player == nil { await load() }
        }
        .onDisappear {
            // Presenting fullscreen also hides the inline page; it is not a
            // navigation exit and must not stop or release the shared player.
            guard !fullscreen else { return }
            player?.pause()
            player = nil
            orientation.restore()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            orientation.resumePendingRequest()
        }
        .fullScreenCover(isPresented: $fullscreen, onDismiss: {
            orientation.restore()
        }) {
            if let player {
                fullscreenPlayer(player)
            }
        }
    }
    private func fullscreenPlayer(_ player: AVPlayer) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoPlayer(player: player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
        }
        .overlay(alignment: .topLeading) {
            Button {
                fullscreen = false
            } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.6), in: .circle)
            }
            .buttonStyle(.plain).foregroundStyle(.white).padding(12)
            .accessibilityLabel("退出全屏")
            .accessibilityIdentifier("live-exit-fullscreen")
        }
        .statusBarHidden()
        // The existing video player requests landscape only after UIKit has
        // completed presentation, and restores the actual window on dismissal.
        .background(MobilePlayerWindowReader(orientation: orientation, requestLandscape: true))
        .alert("无法调整屏幕方向", isPresented: Binding(
            get: { orientation.error != nil },
            set: { if !$0 { orientation.error = nil } }
        )) {
            Button("好") { orientation.error = nil }
        } message: {
            Text(orientation.error ?? "")
        }
    }
    private func load() async {
        guard !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            // Live playback must configure the same media audio session as
            // ordinary videos before play(), including when iOS is in silent mode.
            try await MobileAudioSession.shared.activate()
            try Task.checkCancellation()
            let url = try await LiveAPI.stream(room)
            try Task.checkCancellation()
            let nextPlayer = AVPlayer(url: url)
            nextPlayer.isMuted = false
            nextPlayer.volume = 1
            player = nextPlayer
            nextPlayer.play()
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}
