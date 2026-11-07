import Foundation
import Observation

@MainActor @Observable final class LiveBrowseModel {
    private(set) var query: LiveBrowseQuery = .recommendations
    private(set) var rooms: [LiveRoom] = []
    private(set) var groups: [LiveAreaGroup] = []
    private(set) var loading = false
    private(set) var loadingMore = false
    private(set) var hasMore = true
    private(set) var error: String?
    private(set) var areasError: String?
    private let service: any LiveListingService
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var nextPage = 1
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var loadingAreas = false
    @ObservationIgnored private var failedOnRefresh = true

    init(service: any LiveListingService = LivePublicService()) { self.service = service }

    func select(_ query: LiveBrowseQuery) {
        guard self.query != query else { return }
        generation = UUID()
        self.query = query
        rooms = []
        error = nil
        failedOnRefresh = true
        loaded = false
        loading = false
        loadingMore = false
        nextPage = 1
        hasMore = true
    }
    func loadInitialIfNeeded() async {
        guard !loaded, !loading else { return }
        await refresh()
    }
    func refresh() async {
        let token = UUID()
        generation = token
        let requestedQuery = query
        loading = true
        loadingMore = false
        error = nil
        failedOnRefresh = true
        defer { if generation == token { loading = false } }
        do {
            let page = try await service.rooms(for: requestedQuery, page: 1)
            try Task.checkCancellation()
            guard generation == token else { return }
            rooms = Self.unique(page.rooms)
            nextPage = 2
            hasMore = page.hasMore
            loaded = true
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
    func loadMore() async {
        guard loaded, hasMore, !loading, !loadingMore else { return }
        let token = generation
        let requestedPage = nextPage
        let requestedQuery = query
        loadingMore = true
        error = nil
        failedOnRefresh = false
        defer { if generation == token { loadingMore = false } }
        do {
            let page = try await service.rooms(for: requestedQuery, page: requestedPage)
            try Task.checkCancellation()
            guard generation == token else { return }
            let existing = Set(rooms.map(\.id))
            let additions = Self.unique(page.rooms).filter { !existing.contains($0.id) }
            rooms.append(contentsOf: additions)
            nextPage = requestedPage + 1
            // Recommendation pages can overlap. An entirely repeated page must
            // not leave an endless "load more" loop or duplicate SwiftUI IDs.
            hasMore = page.hasMore && !additions.isEmpty
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
    func loadAreasIfNeeded() async {
        guard groups.isEmpty, !loadingAreas else { return }
        loadingAreas = true
        areasError = nil
        defer { loadingAreas = false }
        do {
            let groups = try await service.areas()
            try Task.checkCancellation()
            self.groups = groups
        } catch {
            if !Task.isCancelled { areasError = error.localizedDescription }
        }
    }
    func retry() async {
        if failedOnRefresh { await refresh() }
        else { await loadMore() }
    }
    private static func unique(_ rooms: [LiveRoom]) -> [LiveRoom] {
        var seen = Set<Int>()
        return rooms.filter { seen.insert($0.id).inserted }
    }
}
