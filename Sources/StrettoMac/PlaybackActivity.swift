import Combine
import StrettoMedia

@MainActor
final class PlaybackActivity: ObservableObject {
    struct Selection: Equatable {
        var songID: String?
        var isPlaying: Bool
    }

    @Published private(set) var selection: Selection
    private var subscription: AnyCancellable?

    init(player: PlaybackController) {
        selection = Selection(songID: player.currentSong?.id, isPlaying: player.isPlaying)
        subscription = player.$currentSong.map { $0?.id }
            .combineLatest(player.$isPlaying)
            .map { Selection(songID: $0, isPlaying: $1) }
            .removeDuplicates()
            .sink { [weak self] value in
                guard let self, self.selection != value else { return }
                self.selection = value
            }
    }
}
