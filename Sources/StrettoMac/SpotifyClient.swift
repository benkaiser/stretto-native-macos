import Foundation
import CryptoKit
import StrettoCore

actor SpotifyClient {
    private struct Tokens: Codable {
        let access: String
        let refresh: String?
        let expiresAt: Date
    }
    private var tokens: Tokens?
    private var accountKey = "spotify.guest"
    private let api: StrettoAPI
    private let session = URLSession(configuration: .ephemeral)
    init(api: StrettoAPI) { self.api = api }

    func setAccount(_ account: String) throws -> Bool {
        accountKey = "spotify." + Data(SHA256.hash(data: Data(account.utf8))).base64URLEncoded
        if let data = try SecretStore.read(accountKey) { tokens = try JSONDecoder().decode(Tokens.self, from: data) }
        else { tokens = nil }
        return tokens != nil
    }
    func accept(_ response: JSONValue) throws {
        guard case .object(let values) = response, let access = values["access_token"]?.string,
              let expiry = values["expires_in"]?.number, !access.isEmpty else {
            throw StrettoError.message("Spotify did not return valid access credentials.")
        }
        tokens = Tokens(access: access, refresh: values["refresh_token"]?.string ?? tokens?.refresh, expiresAt: Date().addingTimeInterval(expiry))
        try SecretStore.save(JSONEncoder().encode(tokens), account: accountKey)
    }
    func disconnect() throws { tokens = nil; try SecretStore.delete(accountKey) }
    private func authorization() async throws -> String {
        guard let tokens else { throw StrettoError.message("Connect Spotify first.") }
        if tokens.expiresAt.timeIntervalSinceNow > 30 { return tokens.access }
        guard let refresh = tokens.refresh else { throw StrettoError.message("Your Spotify connection expired. Connect again.") }
        try accept(await api.json(path: "/native/spotify/refresh", method: "POST", body: ["refresh_token": .string(refresh)]))
        guard let access = self.tokens?.access else { throw StrettoError.message("Spotify refresh returned no access token.") }
        return access
    }
    private func fetch(_ url: URL) async throws -> [String: JSONValue] {
        guard url.scheme == "https", url.host == "api.spotify.com" else { throw StrettoError.message("Invalid Spotify API URL.") }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(try await authorization())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw StrettoError.message("Invalid Spotify response.") }
        if http.statusCode == 429 { throw StrettoError.message("Spotify rate-limited this request. Wait and retry.") }
        if http.statusCode == 403 { throw StrettoError.message("Spotify denied access. Your account may need permission for this Spotify developer app.") }
        guard (200..<300).contains(http.statusCode) else { throw StrettoError.message("Spotify request failed (HTTP \(http.statusCode)). Reconnect if the session expired.") }
        return try JSONDecoder().decode([String: JSONValue].self, from: data)
    }
    private func all(_ path: String) async throws -> [[String: JSONValue]] {
        var next = URL(string: "https://api.spotify.com/v1/\(path)")
        var result: [[String: JSONValue]] = []
        var pages = 0
        while let url = next {
            guard pages < 200 else { throw StrettoError.message("Spotify pagination exceeded the safe limit. Import a smaller selection.") }
            let page = try await fetch(url)
            guard case .array(let items) = page["items"] else { throw StrettoError.message("Spotify returned an unsupported list format.") }
            result += items.compactMap { if case .object(let item) = $0 { return item }; return nil }
            next = page["next"]?.string.flatMap(URL.init(string:))
            pages += 1
        }
        return result
    }
    func playlists() async throws -> [SpotifyPlaylist] {
        try await all("me/playlists?limit=50").compactMap { item in
            guard let id = item["id"]?.string, let name = item["name"]?.string else { return nil }
            let images: [JSONValue]
            if case .array(let value) = item["images"] { images = value } else { images = [] }
            let image = images.first.flatMap { if case .object(let v) = $0 { return v["url"]?.string }; return nil }
            let count: Int
            if case .object(let tracks) = item["tracks"] { count = Int(tracks["total"]?.number ?? 0) } else { count = 0 }
            return SpotifyPlaylist(id: id, name: name, image: image, trackCount: count)
        }
    }
    func tracks(in playlist: SpotifyPlaylist) async throws -> [SpotifyTrack] {
        guard playlist.id.range(of: "^[A-Za-z0-9]+$", options: .regularExpression) != nil else { throw StrettoError.message("Invalid Spotify playlist ID.") }
        let items = try await all("playlists/\(playlist.id)/tracks?limit=100")
        return items.compactMap { item in
            guard case .object(let track) = item["track"], track["type"]?.string != "episode",
                  let id = track["id"]?.string, let title = track["name"]?.string,
                  case .array(let artists) = track["artists"], case .object(let album) = track["album"] else { return nil }
            let artist = artists.compactMap { if case .object(let v) = $0 { return v["name"]?.string }; return nil }.joined(separator: ", ")
            let cover: String
            if case .array(let images) = album["images"], case .object(let image) = images.first { cover = image["url"]?.string ?? "" } else { cover = "" }
            return SpotifyTrack(id: id, title: title, artist: artist, album: album["name"]?.string ?? "", cover: cover,
                                duration: (track["duration_ms"]?.number ?? 0) / 1000, explicit: track["explicit"]?.bool ?? false)
        }
    }
}
