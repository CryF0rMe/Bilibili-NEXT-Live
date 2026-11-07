import Foundation

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
private struct LiveStreamPayload: Decodable, Sendable {
    struct Entry: Decodable, Sendable { let url: String }
    let durl: [Entry]
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
    private static func request<Payload: Decodable & Sendable>(
        _ path: String, host: String = "api.live.bilibili.com",
        parameters: [URLQueryItem] = [], as type: Payload.Type
    ) async throws -> Payload {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = parameters.isEmpty ? nil : parameters
        guard let url = components.url else { throw LiveError.invalidResponse }
        let (data, response) = try await session.data(for: makeRequest(url))
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw LiveError.invalidResponse }
        guard response.statusCode == 200 else { throw LiveError.http(response.statusCode) }
        return try decode(data, as: type)
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
            let payload = try await request("/x/web-interface/search/type", host: "api.bilibili.com", parameters: [
                .init(name: "search_type", value: "live_room"), .init(name: "keyword", value: keyword),
                .init(name: "page", value: String(page))
            ], as: LiveSearchPayload.self)
            let more = payload.numberOfPages.map { page < $0 } ?? (payload.rooms.rawCount > 0)
            return LiveRoomPage(rooms: payload.rooms.items, hasMore: more)
        }
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
        let payload = try await request("/room/v1/Room/playUrl", parameters: [
            .init(name: "cid", value: String(room)), .init(name: "platform", value: "h5"),
            .init(name: "quality", value: "10000")
        ], as: LiveStreamPayload.self)
        guard let raw = payload.durl.first?.url, let url = URL(string: raw),
              let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil
        else { throw LiveError.unavailableStream }
        return url
    }
}
