import Foundation

public enum LyricsResult: Equatable, Sendable {
    case found(String)
    case instrumental
    case notFound
}

public enum LyricsError: LocalizedError, Equatable, Sendable {
    case invalidMetadata
    case unavailable(status: Int, retryAfter: TimeInterval?)
    case throttled(retryAfter: TimeInterval?)
    case challenge
    case httpStatus(Int)
    case invalidResponse
    case responseTooLarge
    case ambiguousMatch
    case transport(code: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidMetadata:
            return "Lyrics lookup needs a track title and artist (up to 512 characters each). Check this song's metadata."
        case .unavailable(let status, _):
            return "LRCLIB is temporarily unavailable (HTTP \(status)). Wait before retrying, or search LRCLIB in your browser."
        case .throttled:
            return "LRCLIB throttled this device (HTTP 429). Wait before retrying."
        case .challenge:
            return "LRCLIB returned a browser verification challenge, not lyrics. Open LRCLIB in your browser; browser verification may not unblock native requests."
        case .httpStatus(let status):
            return "LRCLIB rejected the lyrics request (HTTP \(status)). Try its browser search."
        case .invalidResponse:
            return "LRCLIB returned an unexpected lyrics response. Try again later or use its browser search."
        case .responseTooLarge:
            return "LRCLIB's response exceeded the lyrics safety limit."
        case .ambiguousMatch:
            return "LRCLIB has multiple matching lyrics versions. Check the song's album and duration, or choose a version in its browser search."
        case .transport(let code):
            return "Could not connect to LRCLIB (network error \(code)). Check your connection and try again."
        }
    }
}

/// Uses LRCLIB's public API without cookies, proxies, or automatic retries.
public actor LyricsService {
    private let session: URLSession
    private var cooldown: (until: Date, error: LyricsError)?
    private static let maximumBytes = 2_000_000
    private static let userAgent = "StrettoNative/0.1 (https://next.kaiserapps.com)"

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: LyricsRedirectGuard(), delegateQueue: nil)
    }

    init(session: URLSession) { self.session = session }

    public nonisolated static func browserSearchURL(for song: Song) -> URL {
        let query = "\(song.artist.prefix(512)) \(song.title.prefix(512))"
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        var components = URLComponents(string: "https://lrclib.net")!
        components.percentEncodedPath = query.isEmpty ? "/" : "/search/" + query.addingPercentEncoding(withAllowedCharacters: allowed)!
        return components.url!
    }

    public func lookup(song: Song) async throws -> LyricsResult {
        try Task.checkCancellation()
        if let cooldown, cooldown.until > Date() { throw cooldown.error }
        let title = song.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = song.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = song.album.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validMetadata(title), Self.validMetadata(artist), album.count <= 512,
              !album.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw LyricsError.invalidMetadata
        }
        // LRCLIB only accepts durations in seconds between 1 and 3600. Unknown or longer video durations are omitted.
        let duration = song.duration.isFinite && (1...3600).contains(song.duration) ? song.duration : nil
        var parameters = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]
        if !album.isEmpty { parameters.append(URLQueryItem(name: "album_name", value: album)) }
        if let duration { parameters.append(URLQueryItem(name: "duration", value: String(duration))) }
        if let data = try await response(path: "/api/get", parameters: parameters, allowNotFound: true) {
            let record: Record = try Self.decode(data)
            try record.validate()
            // Without a duration, /get may choose an arbitrary recording. Confirm with search instead.
            if duration != nil, Self.matches(record, title: title, artist: artist, duration: duration),
               album.isEmpty || Self.normalized(record.albumName ?? "") == Self.normalized(album),
               let result = record.result {
                return result
            }
        }
        try Task.checkCancellation()
        // One bounded fallback for genuine misses only; an outage or challenge must never become "not found".
        try await Task.sleep(nanoseconds: 250_000_000)
        let data = try await response(path: "/api/search", parameters: [
            URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)
        ], allowNotFound: false)!
        let records: [Record] = try Self.decode(data)
        guard records.count <= 20 else { throw LyricsError.invalidResponse }
        try records.forEach { try $0.validate() }
        var matches = records.filter { Self.matches($0, title: title, artist: artist, duration: duration) }
        if !album.isEmpty {
            let albumMatches = matches.filter { Self.normalized($0.albumName ?? "") == Self.normalized(album) }
            if !albumMatches.isEmpty { matches = albumMatches }
        }
        // Duplicate releases with identical text are safe; differing versions need human disambiguation.
        let results = matches.compactMap(\.result)
        guard let first = results.first else { return .notFound }
        guard results.allSatisfy({ $0 == first }) else { throw LyricsError.ambiguousMatch }
        try Task.checkCancellation()
        return first
    }

    private struct Record: Decodable {
        let id: Int
        let trackName: String?
        let artistName: String?
        let albumName: String?
        let duration: Double?
        let instrumental: Bool
        let plainLyrics: String?

        func validate() throws {
            guard id > 0, trackName.map(LyricsService.validMetadata) ?? false,
                  artistName.map(LyricsService.validMetadata) ?? false,
                  (albumName?.count ?? 0) <= 512,
                  duration.map({ $0.isFinite && $0 >= 0 && $0 <= 86_400 }) ?? true else {
                throw LyricsError.invalidResponse
            }
        }

        var result: LyricsResult? {
            if instrumental { return .instrumental }
            guard let plainLyrics, !plainLyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return .found(plainLyrics)
        }
    }

    private static func validMetadata(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= 512 &&
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func normalized(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func matches(_ record: Record, title: String, artist: String, duration: Double?) -> Bool {
        guard normalized(record.trackName ?? "") == normalized(title),
              normalized(record.artistName ?? "") == normalized(artist) else { return false }
        if let duration {
            guard let actual = record.duration, abs(actual - duration) <= 2 else { return false }
        }
        return true
    }

    private static func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw LyricsError.invalidResponse }
    }

    private func response(path: String, parameters: [URLQueryItem], allowNotFound: Bool) async throws -> Data? {
        var components = URLComponents(string: "https://lrclib.net")!
        components.path = path
        components.queryItems = parameters
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.userAgent, forHTTPHeaderField: "X-User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            try Task.checkCancellation()
            let (bytes, rawResponse) = try await session.bytes(for: request)
            try Task.checkCancellation()
            guard let response = rawResponse as? HTTPURLResponse, let url = response.url, Self.trustedURL(url),
                  url.path == path else { throw LyricsError.invalidResponse }
            guard response.expectedContentLength <= Int64(Self.maximumBytes) else { throw LyricsError.responseTooLarge }
            var data = Data()
            for try await byte in bytes {
                guard data.count < Self.maximumBytes else { throw LyricsError.responseTooLarge }
                data.append(byte)
                if data.count.isMultiple(of: 4096) { try Task.checkCancellation() }
            }
            try Task.checkCancellation()
            let mime = response.mimeType?.lowercased()
            let preview = String(decoding: data.prefix(65_536), as: UTF8.self).lowercased()
            let isHTML = mime == "text/html" || preview.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<")
            if response.value(forHTTPHeaderField: "cf-mitigated")?.lowercased() == "challenge" ||
                isHTML && ["cf-chl-", "challenge-platform", "g-recaptcha", "hcaptcha", "just a moment",
                           "verify you are human", "checking your browser"].contains(where: preview.contains) {
                throw LyricsError.challenge
            }
            let retryAfter = Self.retryAfter(response.value(forHTTPHeaderField: "Retry-After"))
            switch response.statusCode {
            case 429:
                let error = LyricsError.throttled(retryAfter: retryAfter)
                rememberCooldown(error, seconds: retryAfter)
                throw error
            case 500...599:
                let error = LyricsError.unavailable(status: response.statusCode, retryAfter: retryAfter)
                rememberCooldown(error, seconds: retryAfter)
                throw error
            case 404 where allowNotFound:
                struct APIError: Decodable { let name: String; let statusCode: Int }
                guard mime == "application/json" else { throw LyricsError.invalidResponse }
                let error: APIError = try Self.decode(data)
                guard error.name == "TrackNotFound", error.statusCode == 404 else { throw LyricsError.invalidResponse }
                return nil
            case 200: break
            default: throw LyricsError.httpStatus(response.statusCode)
            }
            guard mime == "application/json", !isHTML else { throw LyricsError.invalidResponse }
            return data
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            if Task.isCancelled || error.code == .cancelled { throw CancellationError() }
            throw LyricsError.transport(code: error.code.rawValue)
        }
    }

    private func rememberCooldown(_ error: LyricsError, seconds: TimeInterval?) {
        if let seconds, seconds > 0 { cooldown = (Date().addingTimeInterval(seconds), error) }
    }

    private static func retryAfter(_ value: String?) -> TimeInterval? {
        guard let value, value.count <= 128 else { return nil }
        if let seconds = Double(value), seconds.isFinite, seconds >= 0 { return min(seconds, 86_400) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter.date(from: value).map { min(max(0, $0.timeIntervalSinceNow), 86_400) }
    }

    fileprivate nonisolated static func trustedURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "lrclib.net" && url.user == nil && url.password == nil &&
            (url.port == nil || url.port == 443)
    }
}

private final class LyricsRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(LyricsService.trustedURL) == true ? request : nil)
    }
}
