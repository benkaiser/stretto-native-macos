import Combine
import Foundation
import StrettoCore

@MainActor
final class YouTubeChannelBrowser: ObservableObject {
    @Published var sort: YouTubeChannelSort = .latest
    @Published private(set) var page: YouTubeChannelPage?
    @Published private(set) var channel: YouTubeChannel?
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var availableSorts = YouTubeChannelSort.allCases
    private let sources: SourceService
    private let song: Song
    private var channelID: String?
    private var revision = UUID()
    private var moreTask: Task<Void, Never>?

    init(sources: SourceService, song: Song) {
        self.sources = sources
        self.song = song
    }

    func load() async {
        cancel()
        let request = revision
        let requestedSort = sort
        page = nil
        errorMessage = nil
        isLoading = true
        defer { if request == revision { isLoading = false } }
        do {
            let id: String
            if let channelID { id = channelID }
            else { id = try await sources.youtubeChannelID(for: song) }
            try Task.checkCancellation()
            guard request == revision, requestedSort == sort else { return }
            channelID = id
            let result = try await sources.channel(id: id, sort: requestedSort)
            try Task.checkCancellation()
            guard request == revision, requestedSort == sort else { return }
            page = result
            channel = result.channel
            availableSorts = result.availableSorts
        } catch {
            if !Task.isCancelled && request == revision && requestedSort == sort {
                errorMessage = error.localizedDescription
            }
        }
    }

    func loadMore() {
        guard let page, page.continuation != nil, page.sort == sort, !isLoading, !isLoadingMore else { return }
        let request = revision
        isLoadingMore = true
        errorMessage = nil
        moreTask = Task {
            defer { if request == revision { isLoadingMore = false } }
            do {
                let result = try await sources.nextChannelPage(page)
                try Task.checkCancellation()
                guard request == revision, result.sort == sort else { return }
                self.page = result
            } catch {
                if !Task.isCancelled && request == revision && page.sort == sort {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    func cancel() {
        revision = UUID()
        moreTask?.cancel()
        moreTask = nil
        isLoading = false
        isLoadingMore = false
    }
}
