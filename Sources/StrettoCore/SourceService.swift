import Foundation

/// Direct, unauthenticated discovery. Platform blocks are surfaced rather than interpreted as empty results.
public actor SourceService {
    private var configuration: PublicConfiguration
    private let session: URLSession
    private var discoveredClientID: String?
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"

    public init(configuration: PublicConfiguration = .init()) {
        self.configuration = configuration
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 90
        session = URLSession(configuration: config, delegate: SourceRedirectGuard(), delegateQueue: nil)
    }

    init(configuration: PublicConfiguration = .init(), session: URLSession) {
        self.configuration = configuration
        self.session = session
    }

    public func configure(_ config: PublicConfiguration) {
        configuration = config
        discoveredClientID = nil
    }

    public func search(query: String, source: String) async throws -> SearchPage {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StrettoError.message("Enter a search query.")
        }
        switch source.lowercased() {
        case "youtube":
            let html = try await text(Self.url("https://www.youtube.com/results", ["search_query": query, "hl": "en"]))
            let root = try Self.extractJSON(named: "ytInitialData", from: html)
            let context = Self.youtubeContext(html: html, kind: "search")
            return try Self.parseYouTube(root, context: context)
        case "soundcloud":
            let root = try await soundCloudJSON(path: "search/tracks", params: ["q": query, "limit": "50"])
            return try Self.parseSoundCloudSearch(root)
        default: throw StrettoError.message("Native discovery supports YouTube and SoundCloud only.")
        }
    }

    public func loadMore(continuation: String) async throws -> SearchPage {
        let context = try Self.decodeContinuation(continuation)
        guard context.page < Int.max, context.channelID != nil || context.page < 30 else {
            throw StrettoError.message("Source pagination limit reached. Refine your search.")
        }
        if context.kind == "soundcloud" {
            guard let url = URL(string: context.token), url.scheme == "https", url.host == "api-v2.soundcloud.com" else {
                throw StrettoError.message("Invalid SoundCloud continuation.")
            }
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            var items = components.queryItems ?? []
            items.removeAll { $0.name == "client_id" }
            items.append(URLQueryItem(name: "client_id", value: try await clientID()))
            components.queryItems = items
            let root = try await json(components.url!)
            return try Self.parseSoundCloudSearch(root, page: context.page + 1)
        }
        guard ["search", "browse"].contains(context.kind), !context.token.isEmpty else {
            throw StrettoError.message("Invalid YouTube continuation.")
        }
        let root = try await youtubeContinuation(context)
        var next = context
        next.page += 1
        let content: [String: Any]
        if context.channelID != nil {
            guard let scoped = Self.channelContinuationContents(root, targetID: context.channelTargetID) else {
                throw StrettoError.message("YouTube did not return the next channel video list.")
            }
            content = scoped
        } else { content = root }
        let page = try Self.parseYouTube(content, context: next)
        if let continuation = page.continuation,
           try Self.decodeContinuation(continuation).token == context.token {
            throw StrettoError.message("YouTube returned a repeated continuation.")
        }
        return page
    }

    public func playlist(url: URL) async throws -> (title: String, songs: [Song]) {
        let source = try Self.inputSource(url)
        if source == "soundcloud" {
            let root = try await soundCloudJSON(path: "resolve", params: ["url": url.absoluteString])
            guard root["kind"] as? String == "playlist", let tracks = root["tracks"] as? [[String: Any]] else {
                throw StrettoError.message("This SoundCloud URL is not an available playlist.")
            }
            guard tracks.count <= 5000 else { throw StrettoError.message("Playlist exceeds the 5,000 track import limit.") }
            var songs: [Song] = []
            for track in tracks {
                try Task.checkCancellation()
                if track["title"] == nil, let id = Self.identifier(track["id"]) {
                    songs.append(try Self.soundCloudSong(try await soundCloudJSON(path: "tracks/\(id)")))
                } else { songs.append(try Self.soundCloudSong(track)) }
            }
            return (root["title"] as? String ?? "SoundCloud Playlist", songs)
        }
        guard let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "list" })?.value,
              Self.validIdentifier(id, max: 150) else {
            throw StrettoError.message("The YouTube URL must contain a playlist list ID.")
        }
        let html = try await text(Self.url("https://www.youtube.com/playlist", ["list": id, "hl": "en"]))
        let root = try Self.extractJSON(named: "ytInitialData", from: html)
        let metadata = Self.objects(named: "playlistMetadataRenderer", in: root).first
        let title = metadata?["title"] as? String
            ?? Self.objects(named: "playlistHeaderRenderer", in: root).first.map { Self.label($0["title"]) }
            ?? "YouTube Playlist"
        var page = try Self.parseYouTube(root, context: Self.youtubeContext(html: html, kind: "browse"))
        var songs = page.songs
        var seenIDs = Set(songs.map(\.id))
        var seenTokens = Set<String>()
        var pages = 1
        while let continuation = page.continuation {
            try Task.checkCancellation()
            let token = try Self.decodeContinuation(continuation).token
            guard seenTokens.insert(token).inserted else { throw StrettoError.message("YouTube returned a repeated playlist continuation.") }
            guard pages < 30, songs.count < 5000 else {
                throw StrettoError.message("Playlist exceeds the import limit (30 pages / 5,000 tracks); no partial playlist was imported.")
            }
            page = try await loadMore(continuation: continuation)
            for song in page.songs where seenIDs.insert(song.id).inserted { songs.append(song) }
            pages += 1
        }
        guard songs.count <= 5000 else { throw StrettoError.message("Playlist exceeds the 5,000 track import limit.") }
        return (title, songs)
    }

    public func song(url: URL) async throws -> Song {
        if try Self.inputSource(url) == "soundcloud" {
            return try Self.soundCloudSong(try await soundCloudJSON(path: "resolve", params: ["url": url.absoluteString]))
        }
        let id = try Self.youtubeID(url)
        let html = try await text(Self.url("https://www.youtube.com/watch", ["v": id, "hl": "en"]))
        let root = try Self.extractJSON(named: "ytInitialPlayerResponse", from: html)
        if let status = root["playabilityStatus"] as? [String: Any], let value = status["status"] as? String, value != "OK" {
            throw StrettoError.message("YouTube: \(status["reason"] as? String ?? value).")
        }
        guard let details = root["videoDetails"] as? [String: Any], let title = details["title"] as? String else {
            throw StrettoError.message("YouTube track details are unavailable.")
        }
        var song = Song(id: "y_\(id)", title: title, artist: details["author"] as? String ?? "",
                        cover: Self.thumbnail(details), url: "https://www.youtube.com/watch?v=\(id)",
                        duration: Double(details["lengthSeconds"] as? String ?? "") ?? 0)
        if let channelID = details["channelId"] as? String, Self.validChannelID(channelID) {
            song.fields["youtubeChannelId"] = .string(channelID)
        }
        return song
    }

    public func youtubeChannelID(for song: Song) async throws -> String {
        guard song.id.hasPrefix("y_"), song.originalID.count == 11, Self.validIdentifier(song.originalID) else {
            throw StrettoError.message("Choose a YouTube video to browse its channel.")
        }
        if let id = song.youtubeChannelID, Self.validChannelID(id) { return id }
        let html = try await text(Self.url("https://www.youtube.com/watch", ["v": song.originalID, "hl": "en"]))
        let root = try Self.extractJSON(named: "ytInitialPlayerResponse", from: html)
        guard let details = root["videoDetails"] as? [String: Any],
              let id = details["channelId"] as? String, Self.validChannelID(id) else {
            let reason = (root["playabilityStatus"] as? [String: Any])?["reason"] as? String
            throw StrettoError.message(reason.map { "YouTube: \($0)" } ?? "YouTube did not identify this video's uploader.")
        }
        return id
    }

    public func channel(id: String, sort: YouTubeChannelSort = .latest) async throws -> YouTubeChannelPage {
        guard Self.validChannelID(id) else { throw StrettoError.message("Invalid YouTube channel ID.") }
        let html = try await text(Self.url("https://www.youtube.com/channel/\(id)/videos", ["hl": "en"]))
        let root = try Self.extractJSON(named: "ytInitialData", from: html)
        guard let metadata = Self.objects(named: "channelMetadataRenderer", in: root).first,
              metadata["externalId"] as? String == id, let title = metadata["title"] as? String, !title.isEmpty,
              let tab = Self.objects(named: "tabRenderer", in: root).first(where: {
                  $0["selected"] as? Bool == true && Self.label($0["title"]) == "Videos"
              }), let content = tab["content"] as? [String: Any] else {
            throw StrettoError.message("This channel's public Videos tab is unavailable, or YouTube changed its response.")
        }
        let channel = YouTubeChannel(id: id, title: title, avatar: Self.thumbnail(metadata["avatar"] as? [String: Any] ?? [:]))
        var context = Self.youtubeContext(html: html, kind: "browse")
        context.channelID = id
        context.channelTitle = title
        context.channelTargetID = Self.objects(named: "richGridRenderer", in: content).first?["targetId"] as? String
        let choices = Self.channelSortCommands(content)
        let available = YouTubeChannelSort.allCases.filter { choices[$0] != nil || $0 == .latest }
        let page: SearchPage
        if sort == .latest && choices[sort]?.selected != false {
            page = try Self.parseYouTube(content, context: context)
        } else {
            guard let command = choices[sort] else {
                throw StrettoError.message("YouTube does not offer \(sort.title.lowercased()) ordering for this channel.")
            }
            let sortedRoot: [String: Any]
            if let token = command.token {
                context.token = token
                sortedRoot = try await youtubeContinuation(context)
            } else if let browseID = command.browseID, browseID == id, let params = command.params {
                sortedRoot = try await youtubeBrowse(context, payload: ["browseId": browseID, "params": params])
            } else {
                throw StrettoError.message("YouTube returned an invalid channel sorting command.")
            }
            guard let items = Self.channelContinuationContents(sortedRoot, targetID: context.channelTargetID) else {
                throw StrettoError.message("YouTube did not return a sorted channel video list.")
            }
            page = try Self.parseYouTube(items, context: context)
        }
        return YouTubeChannelPage(channel: channel, sort: sort, availableSorts: available,
                                  songs: page.songs, continuation: page.continuation)
    }

    public func nextChannelPage(_ previous: YouTubeChannelPage) async throws -> YouTubeChannelPage {
        guard let continuation = previous.continuation else {
            throw StrettoError.message("All available channel videos have been loaded.")
        }
        let context = try Self.decodeContinuation(continuation)
        guard context.kind == "browse", context.channelID == previous.channel.id else {
            throw StrettoError.message("Invalid channel continuation.")
        }
        guard !previous.seenContinuationTokens.contains(context.token) else {
            throw StrettoError.message("YouTube returned a repeated channel continuation.")
        }
        let more = try await loadMore(continuation: continuation)
        if let next = more.continuation,
           previous.seenContinuationTokens.contains(try Self.decodeContinuation(next).token) {
            throw StrettoError.message("YouTube returned a repeated channel continuation.")
        }
        var result = previous
        var ids = Set(previous.songs.map(\.id))
        result.songs += more.songs.filter { ids.insert($0.id).inserted }
        result.continuation = more.continuation
        result.seenContinuationTokens.insert(context.token)
        return result
    }

    public func resolve(song: Song) async throws -> URL {
        try await resolveAudio(song: song).url
    }

    public func resolveAudio(song: Song) async throws -> ResolvedAudio {
        guard song.supported else { throw StrettoError.message("This source is preserved in your library but is not supported by the native player.") }
        if song.id.hasPrefix("y_") {
            guard song.originalID.count == 11, Self.validIdentifier(song.originalID),
                  let endpoint = URL(string: configuration.youtubeRedirectEndpoint),
                  Self.safeRemoteURL(endpoint), var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
                throw StrettoError.message("A valid public YouTube audio redirect endpoint has not been configured.")
            }
            // Preserve a server-provided format selector. Never invent an undocumented format parameter.
            var items = components.queryItems ?? []
            items.removeAll { $0.name == "id" }
            items.append(URLQueryItem(name: "id", value: song.originalID))
            components.queryItems = items
            guard let result = components.url else { throw StrettoError.message("Invalid YouTube audio endpoint.") }
            return ResolvedAudio(url: result, duration: nil)
        }
        let root: [String: Any]
        if Self.validIdentifier(song.originalID), song.originalID.allSatisfy(\.isNumber) {
            root = try await soundCloudJSON(path: "tracks/\(song.originalID)")
        } else {
            guard let url = URL(string: song.url), try Self.inputSource(url) == "soundcloud" else {
                throw StrettoError.message("Invalid SoundCloud track URL.")
            }
            root = try await soundCloudJSON(path: "resolve", params: ["url": url.absoluteString])
        }
        guard root["policy"] as? String != "BLOCK", root["policy"] as? String != "SNIP",
              root["streamable"] as? Bool != false,
              let media = root["media"] as? [String: Any],
              let transcodings = media["transcodings"] as? [[String: Any]] else {
            throw StrettoError.message("SoundCloud track is unavailable or requires Go+.")
        }
        let playable = transcodings.filter {
            guard let format = $0["format"] as? [String: Any] else { return false }
            let mime = format["mime_type"] as? String ?? ""
            let transport = format["protocol"] as? String ?? ""
            return ((mime == "audio/mpeg" && ["progressive", "hls"].contains(transport)) ||
                    (mime == "audio/mp4" && transport == "progressive")) &&
                $0["snipped"] as? Bool != true
        }.sorted {
            (($0["format"] as? [String: Any])?["protocol"] as? String == "progressive" ? 0 : 1) <
            (($1["format"] as? [String: Any])?["protocol"] as? String == "progressive" ? 0 : 1)
        }
        guard let stream = playable.first, let raw = stream["url"] as? String,
              let endpoint = URL(string: raw), endpoint.scheme == "https", endpoint.host == "api-v2.soundcloud.com" else {
            throw StrettoError.message("SoundCloud track has no supported full-length stream (Go+ or unavailable).")
        }
        let resolved = try await json(Self.addQuery(endpoint, ["client_id": try await clientID()]))
        guard let rawURL = resolved["url"] as? String, let url = URL(string: rawURL), Self.soundCloudAudioURL(url) else {
            throw StrettoError.message("SoundCloud did not return a supported HTTPS audio stream.")
        }
        let milliseconds = root["duration"] as? Double
        let duration = milliseconds.flatMap { $0.isFinite && $0 > 0 ? $0 / 1000 : nil }
        return ResolvedAudio(url: url, duration: duration)
    }

    private func youtubeContinuation(_ context: Continuation) async throws -> [String: Any] {
        try await youtubeBrowse(context, payload: ["continuation": context.token])
    }

    private func youtubeBrowse(_ context: Continuation, payload: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: Self.url("https://www.youtube.com/youtubei/v1/\(context.kind)", ["key": context.apiKey, "prettyPrint": "false"]))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("1", forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(context.clientVersion, forHTTPHeaderField: "X-Youtube-Client-Version")
        var body: [String: Any] = payload
        body["context"] = ["client": ["clientName": "WEB", "clientVersion": context.clientVersion, "hl": "en", "gl": "US"]]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try Self.dictionary(try await response(request))
    }

    private func soundCloudJSON(path: String, params: [String: String] = [:]) async throws -> [String: Any] {
        for attempt in 0...1 {
            var values = params
            values["client_id"] = try await clientID(refresh: attempt == 1)
            do { return try await json(Self.url("https://api-v2.soundcloud.com/\(path)", values)) }
            catch SourceHTTPError.status(let status) where (status == 401 || status == 403) && attempt == 0 { continue }
        }
        throw StrettoError.message("SoundCloud rejected its public client ID. Try again later.")
    }

    private func clientID(refresh: Bool = false) async throws -> String {
        if !refresh {
            if let discoveredClientID { return discoveredClientID }
            if configuration.soundcloudClientId.range(of: "^[a-zA-Z0-9]{32}$", options: .regularExpression) != nil {
                return configuration.soundcloudClientId
            }
        }
        let html = try await text(URL(string: "https://soundcloud.com")!)
        let regex = try NSRegularExpression(pattern: #"<script\b[^>]*\bsrc=["'](https://a-v2\.sndcdn\.com/assets/[^"']+\.js)["']"#, options: .caseInsensitive)
        let range = NSRange(html.startIndex..., in: html)
        let scripts = regex.matches(in: html, range: range).prefix(12).compactMap { match -> URL? in
            guard let range = Range(match.range(at: 1), in: html), let url = URL(string: String(html[range])),
                  url.scheme == "https", url.host == "a-v2.sndcdn.com", url.path.hasPrefix("/assets/"), url.path.hasSuffix(".js") else { return nil }
            return url
        }
        let matcher = try NSRegularExpression(pattern: #"client_id\s*:\s*["']([a-zA-Z0-9]{32})["']"#)
        for url in scripts {
            try Task.checkCancellation()
            let script = try await text(url)
            if let match = matcher.firstMatch(in: script, range: NSRange(script.startIndex..., in: script)),
               let range = Range(match.range(at: 1), in: script) {
                let id = String(script[range])
                discoveredClientID = id
                return id
            }
        }
        throw StrettoError.message("Could not discover SoundCloud's public client ID. Its website format may have changed.")
    }

    private func json(_ url: URL) async throws -> [String: Any] { try Self.dictionary(try await response(URLRequest(url: url))) }
    private func text(_ url: URL) async throws -> String {
        let data = try await response(URLRequest(url: url))
        guard let string = String(data: data, encoding: .utf8) else { throw StrettoError.message("Source returned invalid text.") }
        try Self.checkPage(string)
        return string
    }
    private func response(_ input: URLRequest) async throws -> Data {
        var request = input
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        let (data, rawResponse) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = rawResponse as? HTTPURLResponse, let finalURL = response.url, Self.safeRemoteURL(finalURL) else {
            throw StrettoError.message("Source returned an unsafe or invalid response.")
        }
        if finalURL.host == "consent.youtube.com" || finalURL.host == "consent.google.com" {
            throw StrettoError.message("YouTube requires browser consent. Open YouTube in your browser; native discovery cannot bypass consent.")
        }
        if response.statusCode == 429 { throw StrettoError.message("Source throttled this device. Wait before trying again.") }
        guard (200...299).contains(response.statusCode) else { throw SourceHTTPError.status(response.statusCode) }
        guard data.count <= 20_000_000 else { throw StrettoError.message("Source response exceeded the safety limit.") }
        return data
    }

    private struct Continuation: Codable {
        var kind: String
        var token: String = ""
        var apiKey: String = ""
        var clientVersion: String = "2.20241010.01.00"
        var page: Int = 0
        var channelID: String?
        var channelTitle: String?
        var channelTargetID: String?
    }
    private static func youtubeContext(html: String, kind: String) -> Continuation {
        let config = (try? extractJSON(named: "ytcfg.set", from: html)) ?? [:]
        let client = (config["INNERTUBE_CONTEXT"] as? [String: Any])?["client"] as? [String: Any]
        return Continuation(kind: kind, apiKey: config["INNERTUBE_API_KEY"] as? String ?? "",
                            clientVersion: client?["clientVersion"] as? String ?? "2.20241010.01.00")
    }
    private static func encodeContinuation(_ context: Continuation) throws -> String { try JSONEncoder().encode(context).base64EncodedString() }
    private static func decodeContinuation(_ value: String) throws -> Continuation {
        guard value.count < 50_000, let data = Data(base64Encoded: value),
              let context = try? JSONDecoder().decode(Continuation.self, from: data), context.page >= 0,
              context.channelID.map(validChannelID) ?? true else {
            throw StrettoError.message("Invalid source continuation.")
        }
        return context
    }

    static func parseYouTube(_ root: [String: Any]) throws -> SearchPage {
        try parseYouTube(root, context: Continuation(kind: "search"))
    }
    private static func parseYouTube(_ root: [String: Any], context: Continuation) throws -> SearchPage {
        if let error = root["error"] as? [String: Any] {
            throw StrettoError.message("YouTube: \(error["message"] as? String ?? "request failed").")
        }
        var songs: [Song] = []
        var playlists: [RemotePlaylist] = []
        var ids = Set<String>()
        var malformedVideos = 0
        let videos = ["videoRenderer", "compactVideoRenderer", "playlistVideoRenderer", "playlistPanelVideoRenderer"].flatMap { objects(named: $0, in: root) }
        for video in videos {
            let title = label(video["title"])
            if title == "[Deleted video]" || title == "[Private video]" || video["isPlayable"] as? Bool == false { continue }
            guard let id = video["videoId"] as? String, id.count == 11, validIdentifier(id), !title.isEmpty else {
                malformedVideos += 1
                continue
            }
            guard ids.insert("y_\(id)").inserted else { continue }
            let bylineValue = video["longBylineText"] ?? video["shortBylineText"] ?? video["ownerText"]
            var song = Song(id: "y_\(id)", title: title, artist: context.channelTitle ?? label(bylineValue), cover: thumbnail(video),
                            url: "https://www.youtube.com/watch?v=\(id)", duration: seconds(label(video["lengthText"])))
            let channelID = context.channelID ?? channelID(in: bylineValue ?? [:])
            if let channelID { song.fields["youtubeChannelId"] = .string(channelID) }
            let views = label(video["viewCountText"] ?? video["shortViewCountText"])
            let published = label(video["publishedTimeText"])
            if !views.isEmpty { song.fields["youtubeViews"] = .string(views) }
            if !published.isEmpty { song.fields["youtubePublished"] = .string(published) }
            songs.append(song)
        }
        for renderer in objects(named: "playlistRenderer", in: root) {
            guard let id = renderer["playlistId"] as? String, validIdentifier(id, max: 150), ids.insert("p_\(id)").inserted else { continue }
            playlists.append(RemotePlaylist(id: id, title: label(renderer["title"]), cover: thumbnail(renderer),
                                            url: url("https://www.youtube.com/playlist", ["list": id])))
        }
        for model in objects(named: "lockupViewModel", in: root) {
            guard let id = model["contentId"] as? String, validIdentifier(id, max: 150) else { continue }
            let metadata = (model["metadata"] as? [String: Any])?["lockupMetadataViewModel"] as? [String: Any] ?? [:]
            let title = label(metadata["title"])
            let rows = objects(named: "metadataRow", in: metadata) + objects(named: "contentMetadataViewModel", in: metadata)
            let parts = rows.flatMap { objects(named: "metadataParts", in: $0) }
                .flatMap { $0["__array"] as? [[String: Any]] ?? [] }
            let viewPart = parts.first { isViewsLabel(label($0["text"])) ||
                isViewsLabel($0["accessibilityLabel"] as? String ?? "") ||
                ($0["leadingIcon"] as? [String: Any])?["name"] as? String == "PLAY_ARROW_OUTLINED" }
            let publishedPart = parts.first { isPublishedLabel(label($0["text"])) ||
                isPublishedLabel($0["accessibilityLabel"] as? String ?? "") }
            let artistPart = parts.first(where: { channelID(in: $0) != nil }) ?? parts.first(where: {
                let text = label($0["text"])
                let accessible = $0["accessibilityLabel"] as? String ?? ""
                return !text.isEmpty && !isViewsLabel(text) && !isPublishedLabel(text) &&
                    !isViewsLabel(accessible) && !isPublishedLabel(accessible) && $0["leadingIcon"] == nil
            })
            let artist = context.channelTitle ?? artistPart.map { label($0["text"]) } ?? ""
            let type = model["contentType"] as? String ?? ""
            if type.contains("PLAYLIST"), ids.insert("p_\(id)").inserted {
                playlists.append(RemotePlaylist(id: id, title: title, cover: thumbnail(model), url: url("https://www.youtube.com/playlist", ["list": id])))
            } else if type.contains("VIDEO"), id.count == 11, !title.isEmpty, ids.insert("y_\(id)").inserted {
                let badges = objects(named: "thumbnailOverlayBadgeViewModel", in: model) +
                    objects(named: "thumbnailBadgeViewModel", in: model)
                let duration = badges.map { seconds(label($0["text"])) }.max() ?? 0
                var song = Song(id: "y_\(id)", title: title, artist: artist, cover: thumbnail(model),
                                url: "https://www.youtube.com/watch?v=\(id)", duration: duration)
                if let channelID = context.channelID ?? channelID(in: metadata) {
                    song.fields["youtubeChannelId"] = .string(channelID)
                }
                if let viewPart {
                    let text = label(viewPart["text"])
                    if !text.isEmpty { song.fields["youtubeViews"] = .string(text.lowercased().contains("view") ? text : "\(text) views") }
                }
                if let publishedPart { song.fields["youtubePublished"] = .string(label(publishedPart["text"])) }
                songs.append(song)
            }
        }
        let containers = ["sectionListRenderer", "playlistVideoListRenderer", "richGridRenderer",
                          "appendContinuationItemsAction", "reloadContinuationItemsCommand"]
        let recognized = !videos.isEmpty || !objects(named: "lockupViewModel", in: root).isEmpty || !playlists.isEmpty ||
            containers.contains { !objects(named: $0, in: root).isEmpty }
        guard recognized else { throw StrettoError.message("YouTube response format changed or this playlist is unavailable; no results were imported.") }
        if songs.isEmpty && playlists.isEmpty && malformedVideos > 0 {
            throw StrettoError.message("YouTube media fields could not be parsed; no results were imported.")
        }
        if songs.isEmpty && playlists.isEmpty && videos.isEmpty && !containers.contains(where: {
            objects(named: $0, in: root).contains { ($0["contents"] as? [Any])?.isEmpty == true || ($0["continuationItems"] as? [Any])?.isEmpty == true }
        }) && objects(named: "messageRenderer", in: root).isEmpty {
            throw StrettoError.message("YouTube returned no recognized media results; its response may have changed or the playlist is unavailable.")
        }
        if songs.isEmpty && playlists.isEmpty && videos.isEmpty &&
            objects(named: "messageRenderer", in: root).isEmpty &&
            !objects(named: "alertRenderer", in: root).isEmpty {
            throw StrettoError.message("YouTube playlist is private, removed, or unavailable.")
        }
        var next = context
        let continuationItems = objects(named: "continuationItemRenderer", in: root)
        next.token = continuationItems.flatMap { objects(named: "continuationCommand", in: $0) }.compactMap { $0["token"] as? String }.first ?? ""
        if context.channelID != nil {
            let byID = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var seen = Set<String>()
            songs = orderedVideoIDs(in: root).filter { seen.insert($0).inserted }.compactMap { byID[$0] }
        }
        return SearchPage(songs: songs, playlists: playlists, continuation: next.token.isEmpty ? nil : try encodeContinuation(next))
    }

    private struct ChannelSortCommand {
        let selected: Bool
        let token: String?
        let browseID: String?
        let params: String?
    }
    private static func channelSortCommands(_ content: [String: Any]) -> [YouTubeChannelSort: ChannelSortCommand] {
        var commands: [YouTubeChannelSort: ChannelSortCommand] = [:]
        let chips = objects(named: "chipViewModel", in: content) + objects(named: "chipCloudChipRenderer", in: content)
        for chip in chips {
            let text = label(chip["text"])
            guard let sort = YouTubeChannelSort.allCases.first(where: { $0.youtubeLabel == text }),
                  let endpoint = chip["tapCommand"] as? [String: Any] ?? chip["navigationEndpoint"] as? [String: Any] else { continue }
            let token = objects(named: "continuationCommand", in: endpoint).first?["token"] as? String
            let browse = objects(named: "browseEndpoint", in: endpoint).first
            commands[sort] = ChannelSortCommand(selected: chip["selected"] as? Bool ?? chip["isSelected"] as? Bool ?? false,
                                               token: token, browseID: browse?["browseId"] as? String, params: browse?["params"] as? String)
        }
        return commands
    }
    private static func channelContinuationContents(_ root: [String: Any], targetID: String?) -> [String: Any]? {
        for name in ["reloadContinuationItemsCommand", "appendContinuationItemsAction"] {
            let commands = objects(named: name, in: root).filter {
                $0["continuationItems"] is [Any] && $0["slot"] as? String != "RELOAD_CONTINUATION_SLOT_HEADER" &&
                    (targetID == nil || $0["targetId"] as? String == targetID)
            }
            if let command = commands.first(where: { !orderedVideoIDs(in: $0).isEmpty }) ??
                commands.first(where: {
                    guard let items = $0["continuationItems"] as? [[String: Any]] else { return false }
                    return items.isEmpty || items.allSatisfy { $0["continuationItemRenderer"] != nil }
                }) {
                return [name: command]
            }
        }
        return nil
    }
    private static func channelID(in value: Any) -> String? {
        objects(named: "browseEndpoint", in: value).compactMap { $0["browseId"] as? String }.first(where: validChannelID)
    }
    private static func validChannelID(_ value: String) -> Bool {
        value.count == 24 && value.hasPrefix("UC") && validIdentifier(value, max: 24)
    }
    private static func isViewsLabel(_ text: String) -> Bool {
        text.range(of: #"\bviews?\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
    private static func isPublishedLabel(_ text: String) -> Bool {
        text.range(of: #"\bago\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
    private static func orderedVideoIDs(in value: Any, depth: Int = 0) -> [String] {
        guard depth < 50 else { return [] }
        if let array = value as? [Any] { return array.flatMap { orderedVideoIDs(in: $0, depth: depth + 1) } }
        guard let object = value as? [String: Any] else { return [] }
        for key in ["videoRenderer", "compactVideoRenderer", "playlistVideoRenderer", "playlistPanelVideoRenderer"] {
            if let video = object[key] as? [String: Any], let id = video["videoId"] as? String { return ["y_\(id)"] }
        }
        if let model = object["lockupViewModel"] as? [String: Any],
           (model["contentType"] as? String)?.contains("VIDEO") == true, let id = model["contentId"] as? String { return ["y_\(id)"] }
        return object.values.flatMap { orderedVideoIDs(in: $0, depth: depth + 1) }
    }

    private static func parseSoundCloudSearch(_ root: [String: Any], page: Int = 0) throws -> SearchPage {
        guard let collection = root["collection"] as? [[String: Any]] else { throw StrettoError.message("SoundCloud search response is invalid.") }
        let songs = try collection.filter { $0["kind"] as? String == "track" }.map(soundCloudSong)
        var continuation: String?
        if let href = root["next_href"] as? String {
            guard let url = URL(string: href), url.scheme == "https", url.host == "api-v2.soundcloud.com" else {
                throw StrettoError.message("SoundCloud returned an unsafe continuation URL.")
            }
            continuation = try encodeContinuation(Continuation(kind: "soundcloud", token: href, page: page))
        }
        return SearchPage(songs: songs, continuation: continuation)
    }

    static func soundCloudSong(_ root: [String: Any]) throws -> Song {
        guard root["kind"] as? String == "track", let id = identifier(root["id"]), let title = root["title"] as? String else {
            throw StrettoError.message("SoundCloud track is unavailable.")
        }
        let user = root["user"] as? [String: Any]
        var song = Song(id: "s_\(id)", title: title, artist: user?["username"] as? String ?? "",
                        cover: root["artwork_url"] as? String ?? user?["avatar_url"] as? String ?? "",
                        url: root["permalink_url"] as? String ?? "", duration: (root["duration"] as? Double ?? 0) / 1000)
        song.fields["explicit"] = .bool((root["publisher_metadata"] as? [String: Any])?["explicit"] as? Bool ?? false)
        return song
    }

    /// Scans only a JSON object; braces inside quoted/escaped strings do not affect nesting.
    static func extractJSON(named name: String, from html: String) throws -> [String: Any] {
        try checkPage(html)
        var search = html.startIndex
        while let marker = html.range(of: name, range: search..<html.endIndex) {
            search = marker.upperBound
            guard let start = html[marker.upperBound...].firstIndex(of: "{") else { break }
            // Avoid accidentally treating unrelated later scripts as the requested assignment.
            guard html.distance(from: marker.upperBound, to: start) < 100 else { continue }
            var depth = 0
            var quoted = false
            var escaped = false
            var index = start
            while index < html.endIndex {
                let character = html[index]
                if quoted {
                    if escaped { escaped = false }
                    else if character == "\\" { escaped = true }
                    else if character == "\"" { quoted = false }
                } else if character == "\"" { quoted = true }
                else if character == "{" { depth += 1 }
                else if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        let end = html.index(after: index)
                        if let data = String(html[start..<end]).data(using: .utf8), let object = try? dictionary(data) { return object }
                        break
                    }
                }
                index = html.index(after: index)
            }
        }
        throw StrettoError.message("Could not parse \(name). YouTube may have changed its response or blocked this request.")
    }

    private static func checkPage(_ text: String) throws {
        let lower = text.lowercased()
        if lower.contains("before you continue to youtube") || lower.contains("<form") && lower.contains("consent.youtube.com") {
            throw StrettoError.message("YouTube requires browser consent; native discovery cannot bypass it.")
        }
        if lower.contains("sign in to confirm you’re not a bot") || lower.contains("sign in to confirm you're not a bot") ||
            lower.contains("our systems have detected unusual traffic") || lower.contains("g-recaptcha") {
            throw StrettoError.message("YouTube blocked this device with a bot challenge. Try again later; native discovery cannot bypass it.")
        }
    }
    static func inputSource(_ url: URL) throws -> String {
        guard safeRemoteURL(url), url.port == nil || url.port == 443, let host = url.host?.lowercased() else { throw StrettoError.message("Use a public HTTPS YouTube or SoundCloud URL.") }
        if ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be", "www.youtu.be"].contains(host) { return "youtube" }
        if ["soundcloud.com", "www.soundcloud.com", "m.soundcloud.com"].contains(host) { return "soundcloud" }
        throw StrettoError.message("Only HTTPS YouTube and SoundCloud track/playlist URLs are accepted.")
    }
    static func safeRemoteURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased(),
              host.contains("."), !host.hasSuffix(".local"), !host.hasSuffix(".localhost"),
              host != "localhost", !host.contains(":"), host.range(of: #"^[0-9.]+$"#, options: .regularExpression) == nil else { return false }
        return true
    }
    private static func soundCloudAudioURL(_ url: URL) -> Bool {
        guard safeRemoteURL(url), let host = url.host else { return false }
        return host.hasSuffix(".sndcdn.com") || host.hasSuffix(".soundcloud.com")
    }
    private static func youtubeID(_ url: URL) throws -> String {
        let host = url.host ?? ""
        let parts = url.path.split(separator: "/")
        let id: String?
        if host.hasSuffix("youtu.be") { id = parts.first.map(String.init) }
        else if let first = parts.first, ["shorts", "embed", "v"].contains(String(first)), parts.count == 2 { id = String(parts[1]) }
        else { id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value }
        guard let id, id.count == 11, validIdentifier(id) else { throw StrettoError.message("Invalid YouTube video URL.") }
        return id
    }
    private static func validIdentifier(_ value: String, max: Int = 100) -> Bool {
        !value.isEmpty && value.count <= max && value.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
    }
    private static func identifier(_ value: Any?) -> String? {
        if let number = value as? NSNumber { return number.stringValue }
        return value as? String
    }
    private static func dictionary(_ data: Data) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw StrettoError.message("Source returned invalid JSON.") }
        return root
    }
    private static func url(_ base: String, _ params: [String: String]) -> URL { addQuery(URL(string: base)!, params) }
    private static func addQuery(_ url: URL, _ params: [String: String]) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var items = components.queryItems ?? []
        items.removeAll { params[$0.name] != nil }
        items += params.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
        components.queryItems = items
        return components.url!
    }
    private static func seconds(_ string: String) -> Double {
        let parts = string.split(separator: ":")
        guard !parts.isEmpty, parts.allSatisfy({ Double($0) != nil }) else { return 0 }
        return parts.reduce(0) { $0 * 60 + (Double($1) ?? 0) }
    }
    private static func label(_ value: Any?) -> String {
        if let string = value as? String { return string }
        guard let object = value as? [String: Any] else { return "" }
        if let simple = object["simpleText"] as? String ?? object["content"] as? String { return simple }
        return (object["runs"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() ?? ""
    }
    private static func thumbnail(_ object: [String: Any]) -> String {
        let sources = objects(named: "thumbnails", in: object).flatMap { $0["__array"] as? [[String: Any]] ?? [] } +
            objects(named: "sources", in: object).flatMap { $0["__array"] as? [[String: Any]] ?? [] }
        return sources.last?["url"] as? String ?? ""
    }
    private static func objects(named key: String, in value: Any, depth: Int = 0) -> [[String: Any]] {
        guard depth < 50 else { return [] }
        if let array = value as? [Any] { return array.flatMap { objects(named: key, in: $0, depth: depth + 1) } }
        guard let object = value as? [String: Any] else { return [] }
        var found: [[String: Any]] = []
        if let match = object[key] as? [String: Any] { found.append(match) }
        else if let match = object[key] as? [Any] { found.append(["__array": match]) }
        for (name, child) in object where name != key { found += objects(named: key, in: child, depth: depth + 1) }
        return found
    }
}

private enum SourceHTTPError: LocalizedError {
    case status(Int)
    var errorDescription: String? {
        switch self {
        case .status(let code): return "Source request failed (HTTP \(code)); the track may be unavailable, premium-only, or blocked."
        }
    }
}

private final class SourceRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(SourceService.safeRemoteURL) == true ? request : nil)
    }
}
