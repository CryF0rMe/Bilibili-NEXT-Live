import Foundation

private struct ContractFailure: Error, CustomStringConvertible {
    let description: String
}

@main @MainActor struct LiveContractTests {
    private static var checks = 0
    private static func expect(_ condition: @autoclosure () -> Bool, _ description: String) throws {
        guard condition() else { throw ContractFailure(description: description) }
        checks += 1
    }
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw ContractFailure(description: "Fixture directory required") }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        func fixture(_ name: String) throws -> Data { try Data(contentsOf: directory.appendingPathComponent(name + ".json")) }

        let first = try LiveAPI.decode(fixture("recommend-page-1"), as: LiveRecommendationPayload.self)
        let second = try LiveAPI.decode(fixture("recommend-page-2"), as: LiveRecommendationPayload.self)
        try expect(first.rooms.items.count == 12 && second.rooms.items.count == 12, "Decode real recommendation pages")
        try expect(Set(first.rooms.items.map(\.id)) != Set(second.rooms.items.map(\.id)), "Real recommendation pages differ")
        let room = first.rooms.items[0]
        try expect(!room.title.isEmpty && !room.username.isEmpty && room.cover.hasPrefix("https://"), "Recommendation card metadata")
        try expect(room.popularity != nil && !room.categoryLabel.isEmpty, "Category and popularity metadata")

        do {
            _ = try LiveAPI.decode(fixture("original-service-error"), as: LiveRecommendationPayload.self)
            throw ContractFailure(description: "HTTP-200 service error must not become an empty list")
        } catch LiveError.service(let code, _) {
            try expect(code == -352, "Preserve original service error code")
        }
        for malformed in [Data("{}".utf8), Data("{\"code\":0,\"data\":{}}".utf8), Data("not JSON".utf8)] {
            do {
                _ = try LiveAPI.decode(malformed, as: LiveRecommendationPayload.self)
                throw ContractFailure(description: "Malformed success response must not become an empty list")
            } catch LiveError.invalidResponse { checks += 1 }
        }
        let empty = try LiveAPI.decode(Data("{\"code\":0,\"data\":{\"recommend_room_list\":[]}}".utf8), as: LiveRecommendationPayload.self)
        try expect(empty.rooms.items.isEmpty && empty.rooms.rawCount == 0, "A genuine empty success is valid")

        let groups = try LiveAPI.decode(fixture("areas"), as: [LiveAreaGroup].self)
        try expect(groups.count == 12 && groups[0].children[0].id > 0, "Decode numeric parent IDs and string child IDs")
        let category = try LiveAPI.decode(fixture("category"), as: LiveCategoryPayload.self)
        try expect(category.rooms.items.count == 30 && (category.count ?? 0) > 30, "Decode real category page and total")
        let search = try LiveAPI.decode(fixture("search-rooms"), as: LiveSearchPayload.self)
        try expect(search.rooms.items.count == 40 && (search.numberOfPages ?? 0) > 1, "Decode real search pagination")
        try expect(search.rooms.items.allSatisfy { $0.isLive && !$0.category.contains("<em") && $0.cover.hasPrefix("https://") }, "Normalize highlighted search labels and protocol-relative images")

        var row = try JSONSerialization.jsonObject(with: fixture("recommend-page-1")) as! [String: Any]
        let data = row["data"] as! [String: Any]
        let rows = data["recommend_room_list"] as! [[String: Any]]
        var stringID = rows[0]
        stringID["roomid"] = String(room.id)
        var offline = rows[1]
        offline["live_status"] = 0
        row = ["roomid": 0]
        let mixed = try JSONSerialization.data(withJSONObject: [row, offline, stringID])
        let collection = try JSONDecoder().decode(LiveRoomCollection.self, from: mixed)
        try expect(collection.rawCount == 3 && collection.items.map(\.id) == [room.id], "Skip invalid and offline rows while accepting string IDs")

        let request = LiveAPI.makeRequest(URL(string: "https://api.live.bilibili.com/room/v1/Area/getList")!)
        try expect(!request.httpShouldHandleCookies && request.value(forHTTPHeaderField: "Cookie") == nil, "Public requests carry no Cookie header")
        try expect(!LiveAPI.session.configuration.httpShouldSetCookies && LiveAPI.session.configuration.httpCookieStorage == nil, "Public session does not inherit login cookies")

        let examples = first.rooms.items
        let page1 = LiveRoomPage(rooms: [examples[0], examples[0], examples[1]], hasMore: true)
        let page2 = LiveRoomPage(rooms: [examples[1], examples[2]], hasMore: true)
        let repeated = LiveRoomPage(rooms: [examples[2]], hasMore: true)
        let pages = ScriptedService([.page(page1), .page(page2), .page(repeated)])
        let model = LiveBrowseModel(service: pages)
        await model.refresh()
        try expect(model.rooms.count == 2, "Initial page has unique SwiftUI IDs")
        await model.loadMore()
        try expect(model.rooms.map(\.id) == Array(examples.prefix(3)).map(\.id), "Overlapping pages merge in order")
        await model.loadMore()
        try expect(!model.hasMore && model.rooms.count == 3, "Entirely repeated page terminates pagination")
        let requestedPages = await pages.requests
        try expect(requestedPages == [1, 2, 3], "Pagination advances one page at a time")

        let retryService = ScriptedService([.page(page1), .failure, .page(page2)])
        let retryModel = LiveBrowseModel(service: retryService)
        await retryModel.refresh()
        await retryModel.loadMore()
        try expect(retryModel.rooms.count == 2 && retryModel.error != nil, "Pagination error retains loaded rooms")
        await retryModel.retry()
        let retryPages = await retryService.requests
        try expect(retryPages == [1, 2, 2] && retryModel.error == nil, "Retry repeats the failed page")

        let refreshService = ScriptedService([.page(page1), .failure, .page(page1)])
        let refreshModel = LiveBrowseModel(service: refreshService)
        await refreshModel.refresh()
        await refreshModel.refresh()
        try expect(refreshModel.rooms.count == 2 && refreshModel.error != nil, "Refresh error keeps existing results")
        await refreshModel.retry()
        let refreshPages = await refreshService.requests
        try expect(refreshPages == [1, 1, 1], "Failed refresh retries the first page")

        let replacement = LiveRoomPage(rooms: [examples[3]], hasMore: false)
        let heldInitial = HoldingService(mode: .initial, first: page1, replacement: replacement)
        let switching = LiveBrowseModel(service: heldInitial)
        let stale = Task { await switching.refresh() }
        await heldInitial.waitUntilHeld()
        switching.select(.search("replacement"))
        await switching.refresh()
        await heldInitial.complete(with: page1)
        await stale.value
        try expect(switching.rooms.map(\.id) == [examples[3].id], "Old category response cannot replace a new search")

        let heldMore = HoldingService(mode: .pagination, first: page1, replacement: replacement)
        let refreshing = LiveBrowseModel(service: heldMore)
        await refreshing.refresh()
        let staleMore = Task { await refreshing.loadMore() }
        await heldMore.waitUntilHeld()
        await refreshing.refresh()
        await heldMore.complete(with: page2)
        await staleMore.value
        try expect(refreshing.rooms.map(\.id) == [examples[3].id], "Old pagination cannot append after refresh")

        print("PASS: \(checks) live API, cookie isolation, pagination, retry, and stale-response checks")
    }
}

private enum ScriptedReply: Sendable { case page(LiveRoomPage), failure }
private actor ScriptedService: LiveListingService {
    private var replies: [ScriptedReply]
    private(set) var requests: [Int] = []
    init(_ replies: [ScriptedReply]) { self.replies = replies }
    func rooms(for query: LiveBrowseQuery, page: Int) async throws -> LiveRoomPage {
        requests.append(page)
        guard !replies.isEmpty else { throw LiveError.invalidResponse }
        switch replies.removeFirst() {
        case .page(let result): return result
        case .failure: throw LiveError.http(503)
        }
    }
    func areas() async throws -> [LiveAreaGroup] { [] }
}

private actor HoldingService: LiveListingService {
    enum Mode: Sendable, Equatable { case initial, pagination }
    private let mode: Mode
    private let first: LiveRoomPage
    private let replacement: LiveRoomPage
    private var firstPageCalls = 0
    private var pending: CheckedContinuation<LiveRoomPage, any Error>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(mode: Mode, first: LiveRoomPage, replacement: LiveRoomPage) {
        self.mode = mode; self.first = first; self.replacement = replacement
    }
    func rooms(for query: LiveBrowseQuery, page: Int) async throws -> LiveRoomPage {
        if case .search = query { return replacement }
        if page == 1 {
            firstPageCalls += 1
            if mode == .pagination { return firstPageCalls == 1 ? first : replacement }
        }
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            for waiter in waiters { waiter.resume() }
            waiters = []
        }
    }
    func waitUntilHeld() async {
        if pending != nil { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func complete(with page: LiveRoomPage) {
        pending?.resume(returning: page)
        pending = nil
    }
    func areas() async throws -> [LiveAreaGroup] { [] }
}
