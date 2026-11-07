import SwiftUI
import AVKit

struct MobileLiveHome: View {
    @State private var feed = LiveBrowseModel()
    @State private var searchText = ""
    @State private var roomInput = ""
    @State private var selectedRoom: Int?
    @State private var showingRoomInput = false
    @State private var showingAreas = false
    @Environment(\.dynamicTypeSize) private var textSize

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: textSize.isAccessibilitySize ? 280 : 160), spacing: 16)]
    }
    private var enteredRoom: Int? {
        guard let id = Int(roomInput.trimmingCharacters(in: .whitespacesAndNewlines)), id > 0 else { return nil }
        return id
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                categoryBar
                HStack {
                    Text(feed.query.title).font(.headline)
                    Spacer()
                    if feed.loading && !feed.rooms.isEmpty { ProgressView() }
                }
                if let error = feed.error {
                    MobileError(text: error) { Task { await feed.retry() } }
                        .accessibilityIdentifier("live-list-error")
                }
                roomContent
                pagination
            }.padding(16)
        }
        .navigationTitle("直播")
        .searchable(text: $searchText, prompt: "主播、直播标题或房间号")
        .onSubmit(of: .search, submitSearch)
        .onChange(of: searchText) { _, value in
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               case .search = feed.query { feed.select(.recommendations) }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("分区", systemImage: "square.grid.2x2") { showingAreas = true }
                    .accessibilityIdentifier("live-browse-areas")
                Button("房间号", systemImage: "number") {
                    roomInput = ""
                    showingRoomInput = true
                }.accessibilityIdentifier("live-open-room-number")
            }
        }
        .alert("前往直播间", isPresented: $showingRoomInput) {
            TextField("输入房间号", text: $roomInput).keyboardType(.numberPad)
            Button("进入") { selectedRoom = enteredRoom }.disabled(enteredRoom == nil)
            Button("取消", role: .cancel) {}
        } message: {
            Text("也可以直接搜索主播或直播标题，或点击下方直播封面进入。")
        }
        .sheet(isPresented: $showingAreas) {
            LiveAreaPicker(groups: feed.groups, error: feed.areasError, selection: feed.query,
                retry: { Task { await feed.loadAreasIfNeeded() } }) { query in
                select(query)
                showingAreas = false
            }
        }
        .task(id: feed.query) { await feed.loadInitialIfNeeded() }
        .task { await feed.loadAreasIfNeeded() }
        .refreshable {
            await feed.refresh()
            await feed.loadAreasIfNeeded()
        }
        .navigationDestination(isPresented: Binding(
            get: { selectedRoom != nil },
            set: { if !$0 { selectedRoom = nil } }
        )) {
            if let selectedRoom { MobileLivePlayer(room: selectedRoom) }
        }
    }
    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                categoryButton("推荐", selected: feed.query == .recommendations) { select(.recommendations) }
                ForEach(feed.groups) { group in
                    categoryButton(group.name, selected: feed.query.parentID == group.id) {
                        select(.category(parentID: group.id, areaID: 0, title: group.name))
                    }
                }
            }
        }.accessibilityIdentifier("live-category-bar")
    }
    private func categoryButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 14).padding(.vertical, 9)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(selected ? biliPink : Color(uiColor: .secondarySystemGroupedBackground), in: .capsule)
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
    @ViewBuilder private var roomContent: some View {
        if feed.loading && feed.rooms.isEmpty {
            ProgressView("正在发现直播…").frame(maxWidth: .infinity, minHeight: 220)
                .accessibilityIdentifier("live-list-loading")
        } else if feed.rooms.isEmpty && feed.error == nil {
            ContentUnavailableView {
                Label("暂无正在直播的房间", systemImage: "dot.radiowaves.left.and.right")
            } description: {
                Text("试试其他关键词或分区，也可以下拉刷新。")
            }.frame(minHeight: 220).accessibilityIdentifier("live-list-empty")
        } else {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(feed.rooms) { room in
                    Button { selectedRoom = room.id } label: { LiveRoomCard(room: room) }
                        .buttonStyle(.plain).foregroundStyle(.primary)
                        .accessibilityIdentifier("live-room-\(room.id)")
                }
            }.accessibilityIdentifier("live-room-grid")
        }
    }
    @ViewBuilder private var pagination: some View {
        if !feed.loading && !feed.rooms.isEmpty {
            if feed.loadingMore {
                ProgressView("正在加载更多…").frame(maxWidth: .infinity).padding(.vertical)
            } else if feed.hasMore && feed.error == nil {
                Button("加载更多直播") { Task { await feed.loadMore() } }
                    .buttonStyle(.glass).frame(maxWidth: .infinity).padding(.vertical)
                    .accessibilityIdentifier("live-load-more")
            } else if !feed.hasMore {
                Text("已显示全部结果").font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical)
            }
        } else if !feed.loading && feed.rooms.isEmpty && feed.hasMore && feed.error == nil {
            Button("继续查找直播") { Task { await feed.loadMore() } }.frame(maxWidth: .infinity)
        }
    }
    private func select(_ query: LiveBrowseQuery) {
        searchText = ""
        feed.select(query)
    }
    private func submitSearch() {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = Int(keyword), id > 0 { selectedRoom = id }
        else if keyword.isEmpty { feed.select(.recommendations) }
        else { feed.select(.search(keyword)) }
    }
}

private struct LiveRoomCard: View {
    let room: LiveRoom
    @ScaledMetric(relativeTo: .subheadline) private var titleHeight = 40
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Thumbnail(url: room.cover, placeholder: "dot.radiowaves.left.and.right")
                .aspectRatio(16 / 9, contentMode: .fit)
                .accessibilityHidden(true)
                .overlay(alignment: .topLeading) {
                    Text("直播中").font(.caption2.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(biliPink, in: .capsule).padding(7)
                }
                .overlay(alignment: .bottomTrailing) {
                    if let popularity = room.popularity {
                        Label(compactCount(popularity), systemImage: "flame.fill")
                            .font(.caption2).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 4)
                            .background(.black.opacity(0.65), in: .capsule).padding(7)
                            .accessibilityLabel("人气 \(compactCount(popularity))")
                    }
                }.clipShape(.rect(cornerRadius: 14))
            Text(room.title).font(.subheadline.weight(.medium)).lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: titleHeight, alignment: .topLeading)
            Label(room.username, systemImage: "person.crop.circle")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if !room.categoryLabel.isEmpty {
                Text(room.categoryLabel).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(UIDevice.current.userInterfaceIdiom == .pad ? 12 : 0)
        .background {
            if UIDevice.current.userInterfaceIdiom == .pad {
                RoundedRectangle(cornerRadius: 22).fill(.regularMaterial)
            }
        }
        .contentShape(Rectangle()).accessibilityElement(children: .combine)
    }
}

private struct LiveAreaPicker: View {
    let groups: [LiveAreaGroup]
    let error: String?
    let selection: LiveBrowseQuery
    let retry: () -> Void
    let select: (LiveBrowseQuery) -> Void
    @State private var filter = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Button("全部推荐") { select(.recommendations) }
                if let error { MobileError(text: error, retry: retry) }
                if groups.isEmpty && error == nil { ProgressView("正在加载分区…") }
                ForEach(groups.filter(matches)) { group in
                    Section(group.name) {
                        areaButton("全部" + group.name, query: .category(parentID: group.id, areaID: 0, title: group.name))
                        ForEach(children(in: group)) { area in
                            areaButton(area.name, query: .category(parentID: group.id, areaID: area.id, title: area.name))
                        }
                    }
                }
            }
            .navigationTitle("直播分区").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $filter, prompt: "查找游戏或直播分区")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
        }
    }
    private func areaButton(_ title: String, query: LiveBrowseQuery) -> some View {
        Button { select(query) } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if selection == query { Image(systemName: "checkmark").foregroundStyle(biliPink) }
            }
        }
    }
    private func matches(_ group: LiveAreaGroup) -> Bool {
        filter.isEmpty || group.name.localizedCaseInsensitiveContains(filter)
            || group.children.contains { $0.name.localizedCaseInsensitiveContains(filter) }
    }
    private func children(in group: LiveAreaGroup) -> [LiveArea] {
        if filter.isEmpty || group.name.localizedCaseInsensitiveContains(filter) { return group.children }
        return group.children.filter { $0.name.localizedCaseInsensitiveContains(filter) }
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
