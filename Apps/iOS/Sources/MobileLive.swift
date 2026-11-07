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
    var body: some View {
        VStack {
            if let player { VideoPlayer(player: player).aspectRatio(16/9, contentMode: .fit) }
            else { ProgressView("正在加载直播") }
            if let error { Text(error).foregroundStyle(.red) }
            Text("直播间 \(room)").font(.caption)
            Spacer()
        }
        .navigationTitle("直播间")
        .task(id: room) {
            do {
                let url = try await LiveAPI.stream(room)
                guard !Task.isCancelled else { return }
                player = AVPlayer(url: url)
                player?.play()
            } catch { self.error = error.localizedDescription }
        }
        .onDisappear { player?.pause(); player = nil }
    }
}
