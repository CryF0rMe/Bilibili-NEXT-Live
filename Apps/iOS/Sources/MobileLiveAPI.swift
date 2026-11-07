import Foundation
import CryptoKit

enum LiveBrowseQuery: Hashable, Sendable {
    case recommendations
    case category(parentID: Int, areaID: Int, title: String)
    case search(String)

    var title: String {
        switch self {
        case .recommendations: "直播推荐"
        case .category(_, _, let title): title
        case .search(let keyword): "搜索：\(keyword)"
        }
    }
    var parentID: Int? {
        if case .category(let parentID, _, _) = self { return parentID }
        return nil
    }
}

enum LiveError: LocalizedError, Sendable {
    case http(Int)
    case service(Int, String)
    case invalidResponse
    case unavailableStream
    case roomOffline

    var errorDescription: String? {
        switch self {
        case .http(let status):
            "直播请求失败（HTTP \(status)），请稍后重试。"
        case .service(let code, _) where [-352, -412, -509].contains(code):
            "直播服务暂时限制了请求（\(code)），请稍后刷新或选择其他分区。"
        case .service(let code, let message):
            "直播服务返回错误（\(code)）：\(message)"
        case .invalidResponse:
            "直播数据格式异常，请稍后重试。"
        case .unavailableStream:
            "暂时无法获取播放地址，直播间可能已下播，请稍后重试。"
        case .roomOffline:
            "这个直播间当前未开播，可以返回选择其他直播。"
        }
    }
}

private extension KeyedDecodingContainer {
    func integer(_ keys: Key...) -> Int? {
        for key in keys {
            if let value = try? decode(Int.self, forKey: key) { return value }
            if let value = try? decode(String.self, forKey: key), let number = Int(value) { return number }
        }
        return nil
    }
    func text(_ keys: Key...) -> String {
        for key in keys {
            if let value = try? decode(String.self, forKey: key), !value.isEmpty { return value }
        }
        return ""
    }
}

struct LiveRoom: Identifiable, Decodable, Sendable {
    let id: Int
    let title: String
    let username: String
    let cover: String
    let category: String
    let parentCategory: String
    let popularity: Int?
    let liveStatus: Int?

    private enum CodingKeys: String, CodingKey {
        case roomid, room_id, id, title, uname, cover, user_cover, system_cover, keyframe, pic
        case area_v2_name, area_name, cate_name, area_v2_parent_name, parent_name, online, live_status
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.integer(.roomid, .room_id, .id), id > 0 else {
            throw LiveError.invalidResponse
        }
        self.id = id
        let title = Self.plainText(c.text(.title))
        self.title = title.isEmpty ? "直播间 \(id)" : title
        let username = Self.plainText(c.text(.uname))
        self.username = username.isEmpty ? "主播" : username
        cover = Self.imageURL(c.text(.cover, .user_cover, .system_cover, .keyframe, .pic))
        category = Self.plainText(c.text(.area_v2_name, .area_name, .cate_name))
        parentCategory = Self.plainText(c.text(.area_v2_parent_name, .parent_name))
        popularity = c.integer(.online).flatMap { $0 >= 0 ? $0 : nil }
        liveStatus = c.integer(.live_status)
    }
    var isLive: Bool { liveStatus == nil || liveStatus == 1 }
    var categoryLabel: String {
        if category.isEmpty { return parentCategory }
        if parentCategory.isEmpty || parentCategory == category { return category }
        return parentCategory + " · " + category
    }
    static func imageURL(_ raw: String) -> String {
        if raw.hasPrefix("//") { return "https:" + raw }
        if raw.hasPrefix("http://") { return "https://" + String(raw.dropFirst(7)) }
        return raw
    }
    static func plainText(_ raw: String) -> String {
        var value = raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, replacement) in [
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&amp;", "&")
        ] {
            value = value.replacingOccurrences(of: entity, with: replacement)
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct LiveRoomCollection: Decodable, Sendable {
    let items: [LiveRoom]
    let rawCount: Int
    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var rooms: [LiveRoom] = []
        var count = 0
        while !container.isAtEnd {
            let row = try container.superDecoder()
            count += 1
            if let room = try? LiveRoom(from: row), room.isLive { rooms.append(room) }
        }
        items = rooms
        rawCount = count
    }
}

struct LiveArea: Identifiable, Hashable, Decodable, Sendable {
    let id: Int
    let name: String
    private enum CodingKeys: String, CodingKey { case id, name }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.integer(.id), id > 0 else { throw LiveError.invalidResponse }
        self.id = id
        name = c.text(.name)
    }
}

struct LiveAreaGroup: Identifiable, Hashable, Decodable, Sendable {
    let id: Int
    let name: String
    let children: [LiveArea]
    private enum CodingKeys: String, CodingKey { case id, name, list }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.integer(.id), id > 0 else { throw LiveError.invalidResponse }
        self.id = id
        name = c.text(.name)
        children = try c.decode([LiveArea].self, forKey: .list)
    }
}

struct LiveEnvelope<Payload: Decodable & Sendable>: Decodable, Sendable {
    let code: Int
    let message: String
    let data: Payload?
    private enum CodingKeys: String, CodingKey { case code, message, msg, data }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let code = c.integer(.code) else { throw LiveError.invalidResponse }
        self.code = code
        message = c.text(.message, .msg)
        // Error envelopes often have no data (or a different data type).
        // Check the service code before attempting to interpret the payload.
        if code == 0 { data = try c.decodeIfPresent(Payload.self, forKey: .data) }
        else { data = nil }
    }
}

struct LiveRecommendationPayload: Decodable, Sendable {
    let rooms: LiveRoomCollection
    private enum CodingKeys: String, CodingKey { case rooms = "recommend_room_list" }
}
struct LiveCategoryPayload: Decodable, Sendable {
    let rooms: LiveRoomCollection
    let count: Int?
    private enum CodingKeys: String, CodingKey { case list, count }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rooms = try c.decode(LiveRoomCollection.self, forKey: .list)
        count = c.integer(.count)
    }
}
struct LiveSearchPayload: Decodable, Sendable {
    let rooms: LiveRoomCollection
    let numberOfPages: Int?
    private enum CodingKeys: String, CodingKey { case result, numPages }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rooms = try c.decode(LiveRoomCollection.self, forKey: .result)
        numberOfPages = c.integer(.numPages)
    }
}
struct LiveStreamPayload: Decodable, Sendable {
    struct Entry: Decodable, Sendable { let url: String }
    let durl: [Entry]
}

struct LiveRoomPlayPayload: Decodable, Sendable {
    struct PlayURLInfo: Decodable, Sendable { let playurl: PlayURL? }
    struct PlayURL: Decodable, Sendable { let stream: [Stream] }
    struct Stream: Decodable, Sendable {
        let protocol_name: String
        let format: [Format]
    }
    struct Format: Decodable, Sendable {
        let format_name: String
        let codec: [Codec]
    }
    struct Codec: Decodable, Sendable {
        let codec_name: String
        let base_url: String
        let url_info: [CDN]
    }
    struct CDN: Decodable, Sendable {
        let host: String
        let extra: String?
    }
    let live_status: Int?
    let playurl_info: PlayURLInfo?

    func compatibleURLs() -> [URL] {
        let streams = playurl_info?.playurl?.stream ?? []
        var ranked: [(Int, URL)] = []
        for stream in streams where stream.protocol_name == "http_hls" {
            for format in stream.format where ["fmp4", "ts"].contains(format.format_name) {
                for codec in format.codec where codec.codec_name == "avc" {
                    for cdn in codec.url_info {
                        let raw = cdn.host + codec.base_url + (cdn.extra ?? "")
                        guard let url = URL(string: raw), url.scheme == "https",
                              url.host != nil, url.pathExtension.lowercased() == "m3u8" else { continue }
                        // The sampled legacy/TS sources timed out while fMP4 was
                        // reachable. Keep every CDN as a fallback, fMP4 first.
                        ranked.append((format.format_name == "fmp4" ? 0 : 1, url))
                    }
                }
            }
        }
        var seen = Set<URL>()
        return ranked.enumerated().sorted {
            $0.element.0 == $1.element.0 ? $0.offset < $1.offset : $0.element.0 < $1.element.0
        }.map { $0.element.1 }.filter { seen.insert($0).inserted }
    }
}

enum LiveWBISigner {
    static func mixin(image: String, sub: String) throws -> String {
        guard let imageURL = URL(string: image), let subURL = URL(string: sub) else { throw LiveError.invalidResponse }
        let source = Array(imageURL.deletingPathExtension().lastPathComponent + subURL.deletingPathExtension().lastPathComponent)
        let table = [46,47,18,2,53,8,23,32,15,50,10,31,58,3,45,35,27,43,5,49,33,9,42,19,29,28,14,39,12,38,41,13,37,48,7,16,24,55,40,61,26,17,0,1,60,51,30,4,22,25,54,21,56,59,6,63,57,62,11,36,20,34,44,52]
        guard source.count >= 64 else { throw LiveError.invalidResponse }
        return String(table.prefix(32).map { source[$0] })
    }
    static func encoded(_ parameters: [String: String]) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return parameters.sorted { $0.key < $1.key }.map {
            let key = $0.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            let value = $0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return key + "=" + value
        }.joined(separator: "&")
    }
    static func sign(_ parameters: [String: String], key: String, timestamp: Int = Int(Date().timeIntervalSince1970)) -> [String: String] {
        var query = parameters.mapValues { $0.filter { !"!'()*".contains($0) } }
        query["wts"] = String(timestamp)
        let digest = Insecure.MD5.hash(data: Data((encoded(query) + key).utf8))
        query["w_rid"] = digest.map { String(format: "%02x", $0) }.joined()
        return query
    }
}

private struct LiveWBINav: Decodable, Sendable {
    struct Payload: Decodable, Sendable {
        struct Images: Decodable, Sendable { let img_url: String; let sub_url: String }
        let wbi_img: Images?
    }
    let code: Int
    let message: String?
    let data: Payload?
}
private actor LiveWBIKeyCache {
    static let shared = LiveWBIKeyCache()
    private var cached: (key: String, expires: Date)?
    func key() async throws -> String {
        if let cached, cached.expires > Date() { return cached.key }
        let key = try await LiveAPI.fetchWBIKey()
        cached = (key, Date().addingTimeInterval(1800))
        return key
    }
}

struct LiveRoomPage: Sendable {
    let rooms: [LiveRoom]
    let hasMore: Bool
}

protocol LiveListingService: Sendable {
    func rooms(for query: LiveBrowseQuery, page: Int) async throws -> LiveRoomPage
    func areas() async throws -> [LiveAreaGroup]
}
struct LivePublicService: LiveListingService {
    func rooms(for query: LiveBrowseQuery, page: Int) async throws -> LiveRoomPage {
        try await LiveAPI.rooms(for: query, page: page)
    }
    func areas() async throws -> [LiveAreaGroup] { try await LiveAPI.areas() }
}

// A separate, cookie-free session keeps public discovery independent of login.
enum LiveAPI {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()
    static func makeRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.httpShouldHandleCookies = false
        request.setValue("https://live.bilibili.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
    static func decode<Payload: Decodable & Sendable>(_ data: Data, as type: Payload.Type) throws -> Payload {
        let envelope: LiveEnvelope<Payload>
        do { envelope = try JSONDecoder().decode(LiveEnvelope<Payload>.self, from: data) }
        catch { throw LiveError.invalidResponse }
        guard envelope.code == 0 else { throw LiveError.service(envelope.code, envelope.message) }
        guard let payload = envelope.data else { throw LiveError.invalidResponse }
        return payload
    }
    private static func responseData(
        _ path: String, host: String = "api.live.bilibili.com",
        parameters: [URLQueryItem] = []
    ) async throws -> Data {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        if !parameters.isEmpty {
            let query = Dictionary(parameters.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, new in new })
            components.percentEncodedQuery = LiveWBISigner.encoded(query)
        }
        guard let url = components.url else { throw LiveError.invalidResponse }
        let (data, response) = try await session.data(for: makeRequest(url))
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw LiveError.invalidResponse }
        guard response.statusCode == 200 else { throw LiveError.http(response.statusCode) }
        return data
    }
    private static func request<Payload: Decodable & Sendable>(
        _ path: String, host: String = "api.live.bilibili.com",
        parameters: [URLQueryItem] = [], as type: Payload.Type
    ) async throws -> Payload {
        let data = try await responseData(path, host: host, parameters: parameters)
        return try decode(data, as: type)
    }
    static func decodeWBIKey(_ data: Data) throws -> String {
        let nav = try JSONDecoder().decode(LiveWBINav.self, from: data)
        guard nav.code == 0 || nav.code == -101 else { throw LiveError.service(nav.code, nav.message ?? "") }
        guard let images = nav.data?.wbi_img else { throw LiveError.invalidResponse }
        return try LiveWBISigner.mixin(image: images.img_url, sub: images.sub_url)
    }
    fileprivate static func fetchWBIKey() async throws -> String {
        let data = try await responseData("/x/web-interface/nav", host: "api.bilibili.com")
        return try decodeWBIKey(data)
    }
    static func rooms(for query: LiveBrowseQuery, page: Int) async throws -> LiveRoomPage {
        switch query {
        case .recommendations:
            return try await recommendations(page: page)
        case .category(let parentID, let areaID, _):
            let payload = try await request("/room/v3/area/getRoomList", parameters: [
                .init(name: "platform", value: "web"), .init(name: "parent_area_id", value: String(parentID)),
                .init(name: "area_id", value: String(areaID)), .init(name: "sort_type", value: "online"),
                .init(name: "page", value: String(page)), .init(name: "page_size", value: "30")
            ], as: LiveCategoryPayload.self)
            let more = payload.count.map { page * 30 < $0 } ?? (payload.rooms.rawCount >= 30)
            return LiveRoomPage(rooms: payload.rooms.items, hasMore: more)
        case .search(let keyword):
            let key = try await LiveWBIKeyCache.shared.key()
            let signed = LiveWBISigner.sign(["search_type": "live_room", "keyword": keyword, "page": String(page)], key: key)
            let payload = try await request("/x/web-interface/wbi/search/type", host: "api.bilibili.com",
                parameters: signed.sorted { $0.key < $1.key }.map { .init(name: $0.key, value: $0.value) },
                as: LiveSearchPayload.self)
            var alternative: LiveSearchPayload?
            if payload.rooms.items.isEmpty {
                // Both endpoints returned real but inconsistent successful
                // results during verification. Check the compatible endpoint
                // only after an empty success, never after a service challenge.
                do {
                    alternative = try await request("/x/web-interface/search/type", host: "api.bilibili.com", parameters: [
                        .init(name: "search_type", value: "live_room"), .init(name: "keyword", value: keyword),
                        .init(name: "page", value: String(page))
                    ], as: LiveSearchPayload.self)
                } catch { try Task.checkCancellation() }
            }
            return searchPage(primary: payload, alternative: alternative, page: page)
        }
    }
    static func searchPage(primary: LiveSearchPayload, alternative: LiveSearchPayload? = nil, page: Int) -> LiveRoomPage {
        let selected: LiveSearchPayload
        if primary.rooms.items.isEmpty, let alternative, !alternative.rooms.items.isEmpty { selected = alternative }
        else { selected = primary }
        let more = selected.numberOfPages.map { page < $0 } ?? (selected.rooms.rawCount > 0)
        return LiveRoomPage(rooms: selected.rooms.items, hasMore: more)
    }
    private static func recommendations(page: Int) async throws -> LiveRoomPage {
        do {
            let payload = try await request("/xlive/web-interface/v1/webMain/getMoreRecList", parameters: [
                .init(name: "platform", value: "web"), .init(name: "page", value: String(page))
            ], as: LiveRecommendationPayload.self)
            return LiveRoomPage(rooms: payload.rooms.items, hasMore: payload.rooms.rawCount > 0)
        } catch {
            try Task.checkCancellation()
            // This independently verified public homepage endpoint has no page
            // parameter. Never repeat its first page to fake pagination.
            guard page == 1 else { throw error }
            let payload = try await request("/xlive/web-interface/v1/webMain/getList", parameters: [
                .init(name: "platform", value: "web")
            ], as: LiveRecommendationPayload.self)
            return LiveRoomPage(rooms: payload.rooms.items, hasMore: false)
        }
    }
    static func areas() async throws -> [LiveAreaGroup] {
        try await request("/room/v1/Area/getList", as: [LiveAreaGroup].self)
    }
    static func stream(_ room: Int) async throws -> URL {
        guard let url = try await streams(room).first else { throw LiveError.unavailableStream }
        return url
    }
    static func streams(_ room: Int) async throws -> [URL] {
        do {
            let payload = try await request("/xlive/web-room/v2/index/getRoomPlayInfo", parameters: [
                .init(name: "room_id", value: String(room)), .init(name: "protocol", value: "1"),
                .init(name: "format", value: "1,2"), .init(name: "codec", value: "0"),
                .init(name: "qn", value: "400"), .init(name: "platform", value: "h5"),
                .init(name: "ptype", value: "8")
            ], as: LiveRoomPlayPayload.self)
            if let status = payload.live_status, status != 1 { throw LiveError.roomOffline }
            let urls = payload.compatibleURLs()
            if !urls.isEmpty { return urls }
        } catch LiveError.roomOffline { throw LiveError.roomOffline }
        catch { try Task.checkCancellation() }
        // Retain the old H5 source only when no compatible modern source exists.
        // It is not used as the first CDN for every room anymore.
        let payload = try await request("/room/v1/Room/playUrl", parameters: [
            .init(name: "cid", value: String(room)), .init(name: "platform", value: "h5"),
            .init(name: "quality", value: "10000")
        ], as: LiveStreamPayload.self)
        let urls = payload.durl.compactMap { entry -> URL? in
            guard let url = URL(string: entry.url), url.scheme == "https", url.host != nil,
                  url.pathExtension.lowercased() == "m3u8" else { return nil }
            return url
        }
        guard !urls.isEmpty else { throw LiveError.unavailableStream }
        return urls
    }
}
