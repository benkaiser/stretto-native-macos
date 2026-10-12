import Combine
import Foundation
import StrettoCore

@MainActor
final class LyricsLookup: ObservableObject {
    @Published private(set) var text = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = false
    @Published private(set) var browserURL: URL?
    private let service: LyricsService
    private var revision = UUID()
    private var request: Task<LyricsResult, Error>?

    init(service: LyricsService = LyricsService()) { self.service = service }

    func reset() {
        revision = UUID()
        request?.cancel()
        request = nil
        text = ""
        errorMessage = nil
        browserURL = nil
        isLoading = false
    }

    func load(song: Song?) async {
        reset()
        guard let song else { text = "Choose a song first."; return }
        let current = revision
        let service = service
        browserURL = LyricsService.browserSearchURL(for: song)
        isLoading = true
        let task = Task { try await service.lookup(song: song) }
        request = task
        defer {
            if current == revision { isLoading = false; request = nil }
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard current == revision else { return }
            switch result {
            case .found(let text): self.text = text
            case .instrumental: text = "Instrumental"
            case .notFound: text = "No matching lyrics found for this track. Try LRCLIB's browser search."
            }
        } catch {
            if !(error is CancellationError) && !Task.isCancelled && current == revision {
                errorMessage = error.localizedDescription
            }
        }
    }
}
