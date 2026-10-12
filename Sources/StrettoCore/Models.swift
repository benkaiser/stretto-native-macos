import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var number: Double? { if case .number(let v) = self { return v }; return nil }
    public var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
}

public struct Song: Codable, Equatable, Identifiable, Sendable {
    public var fields: [String: JSONValue]
    public init(fields: [String: JSONValue]) { self.fields = fields }
    public init(id: String, title: String, artist: String, album: String = "", cover: String = "", url: String = "", duration: Double = 0) {
        let now = Date().timeIntervalSince1970 * 1000
        fields = [
            "id": .string(id), "title": .string(title), "artist": .string(artist),
            "album": .string(album), "cover": .string(cover), "url": .string(url),
            "duration": .number(duration), "createdAt": .number(now), "updatedAt": .number(now),
            "isYoutube": .bool(id.hasPrefix("y_")), "isSoundcloud": .bool(id.hasPrefix("s_")),
            "isAudius": .bool(id.hasPrefix("a_")), "explicit": .bool(false), "playInLibrary": .bool(true),
        ]
    }
    public init(from decoder: Decoder) throws {
        fields = try decoder.singleValueContainer().decode([String: JSONValue].self)
        guard let id = fields["id"]?.string, !id.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Song has no ID."))
        }
    }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(fields) }
    public var id: String { fields["id"]?.string ?? "" }
    public var originalID: String { String(id.dropFirst(2)) }
    public var title: String { get { fields["title"]?.string ?? "" } set { fields["title"] = .string(newValue) } }
    public var artist: String { get { fields["artist"]?.string ?? "" } set { fields["artist"] = .string(newValue) } }
    public var album: String { get { fields["album"]?.string ?? "" } set { fields["album"] = .string(newValue) } }
    public var cover: String { get { fields["cover"]?.string ?? "" } set { fields["cover"] = .string(newValue) } }
    public var url: String { fields["url"]?.string ?? "" }
    public var duration: Double { fields["duration"]?.number ?? 0 }
    public var supported: Bool { id.hasPrefix("y_") || id.hasPrefix("s_") }
    public var source: String { id.hasPrefix("y_") ? "YouTube" : id.hasPrefix("s_") ? "SoundCloud" : "Unsupported" }
    public var explicit: Bool { fields["explicit"]?.bool ?? false }
    public var playInLibrary: Bool { fields["playInLibrary"]?.bool ?? true }
    public var coverURL: URL? { URL(string: cover) }
    public var youtubeChannelID: String? { fields["youtubeChannelId"]?.string }
    public var youtubeViews: String { fields["youtubeViews"]?.string ?? "" }
    public var youtubePublished: String { fields["youtubePublished"]?.string ?? "" }
}

public struct Playlist: Codable, Equatable, Identifiable, Sendable {
    public var fields: [String: JSONValue]
    public init(title: String, songs: [String] = []) {
        let now = Date().timeIntervalSince1970 * 1000
        fields = ["title": .string(title), "songs": .array(songs.map(JSONValue.string)),
                  "createdAt": .number(now), "updatedAt": .number(now), "editable": .bool(title != "Library")]
    }
    public init(from decoder: Decoder) throws {
        fields = try decoder.singleValueContainer().decode([String: JSONValue].self)
        guard fields["title"]?.string != nil else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Playlist has no title."))
        }
    }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(fields) }
    public var id: String { title }
    public var title: String { get { fields["title"]?.string ?? "" } set { fields["title"] = .string(newValue) } }
    public var songs: [String] {
        get { if case .array(let ids) = fields["songs"] { return ids.compactMap(\.string) }; return [] }
        set { fields["songs"] = .array(newValue.map(JSONValue.string)); fields["updatedAt"] = .number(Date().timeIntervalSince1970 * 1000) }
    }
    public var editable: Bool { fields["editable"]?.bool ?? (title != "Library") }
}

public struct Library: Codable, Equatable, Sendable {
    public var songs: [Song]
    public var playlists: [Playlist]
    public var version: Double
    public var metadata: [String: JSONValue]
    public init(songs: [Song] = [], playlists: [Playlist] = [], version: Double = -1, metadata: [String: JSONValue] = [:]) {
        self.songs = songs; self.playlists = playlists; self.version = version; self.metadata = metadata
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.singleValueContainer().decode([String: JSONValue].self)
        guard let songValue = values["songs"], let playlistValue = values["playlists"], let version = values["version"]?.number else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Library requires songs, playlists and numeric version."))
        }
        songs = try JSONDecoder().decode([Song].self, from: JSONEncoder().encode(songValue))
        playlists = try JSONDecoder().decode([Playlist].self, from: JSONEncoder().encode(playlistValue))
        self.version = version
        metadata = values.filter { !["songs", "playlists", "version"].contains($0.key) }
    }
    public func encode(to encoder: Encoder) throws {
        var values = metadata
        values["songs"] = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(songs))
        values["playlists"] = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(playlists))
        values["version"] = .number(version)
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }
    public var supportedSongs: [Song] { songs.filter(\.supported) }
    public func songs(in playlist: Playlist) -> [Song] {
        let byID = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return playlist.songs.compactMap { byID[$0] }
    }
    public mutating func add(_ song: Song, playlist title: String? = nil) {
        if !songs.contains(where: { $0.id == song.id }) { songs.append(song) }
        if let index = playlists.firstIndex(where: { $0.title == "Library" }), !playlists[index].songs.contains(song.id) {
            playlists[index].songs.append(song.id)
        }
        if let title {
            if let index = playlists.firstIndex(where: { $0.title == title }) {
                if !playlists[index].songs.contains(song.id) { playlists[index].songs.append(song.id) }
            } else { playlists.append(Playlist(title: title, songs: [song.id])) }
        }
    }
}

public struct RemotePlaylist: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let cover: String
    public let url: URL
    public init(id: String, title: String, cover: String = "", url: URL) {
        self.id = id; self.title = title; self.cover = cover; self.url = url
    }
}

public struct SearchPage: Sendable {
    public var songs: [Song]
    public var playlists: [RemotePlaylist]
    public var continuation: String?
    public init(songs: [Song] = [], playlists: [RemotePlaylist] = [], continuation: String? = nil) {
        self.songs = songs; self.playlists = playlists; self.continuation = continuation
    }
}

public enum YouTubeChannelSort: String, CaseIterable, Identifiable, Sendable {
    case latest, popular, oldest
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .latest: return "Newest"
        case .popular: return "Most viewed"
        case .oldest: return "Oldest"
        }
    }
    var youtubeLabel: String {
        switch self {
        case .latest: return "Latest"
        case .popular: return "Popular"
        case .oldest: return "Oldest"
        }
    }
}

public struct YouTubeChannel: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let avatar: String
    public var url: URL { URL(string: "https://www.youtube.com/channel/\(id)")! }
}

public struct YouTubeChannelPage: Sendable {
    public let channel: YouTubeChannel
    public let sort: YouTubeChannelSort
    public let availableSorts: [YouTubeChannelSort]
    public internal(set) var songs: [Song]
    public internal(set) var continuation: String?
    var seenContinuationTokens: Set<String> = []
}

public struct PublicConfiguration: Codable, Sendable {
    public var youtubeRedirectEndpoint: String
    public var soundcloudClientId: String
    public var spotifyClientId: String
    public init(youtubeRedirectEndpoint: String = "", soundcloudClientId: String = "", spotifyClientId: String = "") {
        self.youtubeRedirectEndpoint = youtubeRedirectEndpoint; self.soundcloudClientId = soundcloudClientId; self.spotifyClientId = spotifyClientId
    }
}

public struct ResolvedAudio: Sendable {
    public let url: URL
    public let duration: Double?
}

public struct Artist: Codable, Identifiable, Sendable {
    public var artistId: Int
    public var artistName: String
    public var artistCover: String?
    public var artistLinkUrl: String?
    public var amgArtistId: Int?
    public var id: Int { artistId }
    public init(artistId: Int, artistName: String, artistCover: String? = nil, artistLinkUrl: String? = nil, amgArtistId: Int? = nil) {
        self.artistId = artistId; self.artistName = artistName; self.artistCover = artistCover; self.artistLinkUrl = artistLinkUrl; self.amgArtistId = amgArtistId
    }
}

public enum StrettoError: LocalizedError, Equatable {
    case message(String), unauthenticated, conflict
    public var errorDescription: String? {
        switch self {
        case .message(let value): return value
        case .unauthenticated: return "Your Stretto session has expired. Sign in again; local changes are safe."
        case .conflict: return "Your library changed elsewhere. Review the two versions before syncing."
        }
    }
}
