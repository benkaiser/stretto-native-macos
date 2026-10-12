import Foundation

public struct SpotifyPlaylist: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let image: String?
    public let trackCount: Int
    public init(id: String, name: String, image: String? = nil, trackCount: Int = 0) {
        self.id = id; self.name = name; self.image = image; self.trackCount = trackCount
    }
}

public struct SpotifyTrack: Sendable {
    public let id: String
    public let title: String
    public let artist: String
    public let album: String
    public let cover: String
    public let duration: Double
    public let explicit: Bool
    public init(id: String, title: String, artist: String, album: String, cover: String, duration: Double, explicit: Bool) {
        self.id = id; self.title = title; self.artist = artist; self.album = album; self.cover = cover; self.duration = duration; self.explicit = explicit
    }
}
