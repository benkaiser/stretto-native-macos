import XCTest
@testable import StrettoCore

final class SourceServiceTests: XCTestCase {
    private func object(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testBalancedJSONHandlesQuotedBracesAndEscapes() throws {
        let html = #"<script>window["ytInitialData"] = {"title":"brace } and \"quote\" {","nested":{"value":1}}; unwanted();</script>"#
        let result = try SourceService.extractJSON(named: "ytInitialData", from: html)
        XCTAssertEqual(result["title"] as? String, #"brace } and "quote" {"#)
        XCTAssertEqual((result["nested"] as? [String: Any])?["value"] as? Int, 1)
        XCTAssertThrowsError(try SourceService.extractJSON(named: "missing", from: html))
        XCTAssertThrowsError(try SourceService.extractJSON(named: "ytInitialData", from: "var ytInitialData = {bad};"))
    }

    func testLegacySearchVideosPlaylistsAndContinuation() throws {
        let root = try object(Self.legacy)
        let result = try SourceService.parseYouTube(root)
        XCTAssertEqual(result.songs.count, 1)
        XCTAssertEqual(result.songs.first?.id, "y_abcdefghijk")
        XCTAssertEqual(result.songs.first?.title, "Track")
        XCTAssertEqual(result.songs.first?.artist, "Artist")
        XCTAssertEqual(result.songs.first?.duration, 183)
        XCTAssertEqual(result.songs.first?.cover, "https://i.ytimg.com/vi/abcdefghijk/hqdefault.jpg")
        XCTAssertEqual(result.playlists.map(\.title), ["Collection"])
        XCTAssertNotNil(result.continuation)
    }

    func testLockupViewModelsSupportVideoAndPlaylist() throws {
        let root = try object(Self.modern)
        let result = try SourceService.parseYouTube(root)
        XCTAssertEqual(result.songs.map(\.id), ["y_lmnopqrstuv"])
        XCTAssertEqual(result.songs.first?.title, "Modern Track")
        XCTAssertEqual(result.songs.first?.artist, "Modern Artist")
        XCTAssertEqual(result.songs.first?.duration, 245)
        XCTAssertEqual(result.songs.first?.cover, "https://i.ytimg.com/vi/lmnopqrstuv/hqdefault.jpg")
        XCTAssertEqual(result.playlists.first?.id, "PLmodern")
        XCTAssertEqual(result.playlists.first?.title, "Modern Playlist")
    }

    func testPrivateAndDeletedVideosAreNotImported() throws {
        let root = try object(#"{"playlistVideoListRenderer":{"contents":[{"playlistVideoRenderer":{"videoId":"abcdefghijk","title":{"simpleText":"[Private video]"},"isPlayable":false}}]}}"#)
        let result = try SourceService.parseYouTube(root)
        XCTAssertTrue(result.songs.isEmpty)
    }

    func testMalformedAndBlockedResultsThrow() throws {
        XCTAssertThrowsError(try SourceService.parseYouTube(["unrecognized": ["items": []]]))
        XCTAssertThrowsError(try SourceService.parseYouTube(["error": ["message": "Request blocked"]]))
        XCTAssertThrowsError(try SourceService.extractJSON(named: "ytInitialData", from: "Before you continue to YouTube"))
        XCTAssertThrowsError(try SourceService.extractJSON(named: "ytInitialData", from: "Sign in to confirm you’re not a bot"))
        XCTAssertThrowsError(try SourceService.parseYouTube(["sectionListRenderer": ["contents": [["unknownRenderer": ["title": "new shape"]]]]]))
    }

    func testInputAllowlistRejectsFilesLocalhostLookalikesAndCredentials() throws {
        let invalid = ["file:///etc/passwd", "http://youtube.com/watch?v=abcdefghijk",
                       "https://localhost/watch?v=abcdefghijk", "https://127.0.0.1",
                       "https://youtube.com.attacker.example/watch?v=abcdefghijk",
                       "https://youtube.com:444/watch?v=abcdefghijk", "https://user:pass@youtube.com"]
        for string in invalid { XCTAssertThrowsError(try SourceService.inputSource(URL(string: string)!)) }
        XCTAssertEqual(try SourceService.inputSource(URL(string: "https://youtu.be/abcdefghijk")!), "youtube")
        XCTAssertEqual(try SourceService.inputSource(URL(string: "https://soundcloud.com/artist/song")!), "soundcloud")
    }

    func testPlaylistPaginationUsesDirectInnertubeAndPreservesOrder() async throws {
        let transport = FixtureTransport()
        transport.handler = { request in
            if request.url?.path == "/playlist" {
                return (200, "text/html", Data(#"<script>ytcfg.set({"INNERTUBE_API_KEY":"fixture-key","INNERTUBE_CONTEXT":{"client":{"clientVersion":"fixture-version"}}});var ytInitialData = {"metadata":{"playlistMetadataRenderer":{"title":"Paginated Collection"}},"playlistVideoListRenderer":{"contents":[{"playlistVideoRenderer":{"videoId":"abcdefghijk","title":{"simpleText":"First"},"shortBylineText":{"simpleText":"Artist"}}},{"continuationItemRenderer":{"continuationEndpoint":{"continuationCommand":{"token":"page-two"}}}}]}};</script>"#.utf8))
            }
            XCTAssertEqual(request.url?.host, "www.youtube.com")
            XCTAssertEqual(request.url?.path, "/youtubei/v1/browse")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Youtube-Client-Version"), "fixture-version")
            let body = try self.requestJSON(request)
            XCTAssertEqual(body["continuation"] as? String, "page-two")
            return (200, "application/json", Data(#"{"onResponseReceivedActions":[{"appendContinuationItemsAction":{"continuationItems":[{"playlistVideoRenderer":{"videoId":"lmnopqrstuv","title":{"simpleText":"Second"}}}]}}]}"#.utf8))
        }
        let service = SourceService(session: transport.session)
        let result = try await service.playlist(url: URL(string: "https://www.youtube.com/playlist?list=PLfixture")!)
        XCTAssertEqual(result.title, "Paginated Collection")
        XCTAssertEqual(result.songs.map(\.id), ["y_abcdefghijk", "y_lmnopqrstuv"])
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testPlaylistRepeatedContinuationIsAnErrorNotPartialSuccess() async throws {
        let transport = FixtureTransport()
        let page = #"{"playlistVideoListRenderer":{"contents":[{"playlistVideoRenderer":{"videoId":"abcdefghijk","title":{"simpleText":"First"}}},{"continuationItemRenderer":{"continuationEndpoint":{"continuationCommand":{"token":"repeat"}}}}]}}"#
        transport.handler = { request in
            if request.httpMethod == "POST" { return (200, "application/json", Data(page.utf8)) }
            return (200, "text/html", Data("var ytInitialData = \(page);".utf8))
        }
        let service = SourceService(session: transport.session)
        do {
            _ = try await service.playlist(url: URL(string: "https://www.youtube.com/playlist?list=PLfixture")!)
            XCTFail("Repeated continuation must not report a successful partial playlist.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("repeated")) }
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testYouTubeResolutionPreservesConfiguredFormatAndCustomHTTPSPort() async throws {
        let service = SourceService(configuration: PublicConfiguration(youtubeRedirectEndpoint: "https://home.example.com:59436/youtuberedirect?format=m4a"))
        let song = Song(id: "y_abcdefghijk", title: "Track", artist: "Artist")
        let url = try await service.resolve(song: song)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first(where: { $0.name == "id" })?.value, "abcdefghijk")
        XCTAssertEqual(query.first(where: { $0.name == "format" })?.value, "m4a")
        XCTAssertEqual(url.port, 59436)
        do { _ = try await service.resolve(song: Song(id: "a_kept", title: "Preserved", artist: "")); XCTFail("Audius must remain unsupported.") }
        catch { XCTAssertTrue(error.localizedDescription.contains("preserved")) }
    }

    func testSoundCloudPrefersProgressiveAndRejectsGoPlus() async throws {
        let transport = FixtureTransport()
        transport.handler = { request in
            if request.url?.path == "/tracks/123" {
                return (200, "application/json", Data(#"{"kind":"track","streamable":true,"media":{"transcodings":[{"url":"https://api-v2.soundcloud.com/hls","format":{"mime_type":"audio/mpeg","protocol":"hls"}},{"url":"https://api-v2.soundcloud.com/progressive","format":{"mime_type":"audio/mpeg","protocol":"progressive"}}]}}"#.utf8))
            }
            XCTAssertEqual(request.url?.path, "/progressive")
            return (200, "application/json", Data(#"{"url":"https://cf-media.sndcdn.com/audio.mp3"}"#.utf8))
        }
        let service = SourceService(configuration: .init(soundcloudClientId: String(repeating: "a", count: 32)), session: transport.session)
        let url = try await service.resolve(song: Song(id: "s_123", title: "Track", artist: "Artist"))
        XCTAssertEqual(url.absoluteString, "https://cf-media.sndcdn.com/audio.mp3")
        transport.handler = { _ in (200, "application/json", Data(#"{"policy":"SNIP","media":{"transcodings":[]}}"#.utf8)) }
        do { _ = try await service.resolve(song: Song(id: "s_124", title: "Go+", artist: "")); XCTFail("Premium preview must not play.") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Go+")) }
    }

    func testSoundCloudStaleClientIDRefreshFetchesOnlyValidatedScripts() async throws {
        let transport = FixtureTransport()
        let fresh = String(repeating: "b", count: 32)
        transport.handler = { request in
            switch request.url?.host {
            case "soundcloud.com":
                return (200, "text/html", Data(#"<script src="https://attacker.example/steal.js"></script><script src="https://a-v2.sndcdn.com/assets/app.js"></script>"#.utf8))
            case "a-v2.sndcdn.com":
                return (200, "text/javascript", Data("var config={client_id:\"\(fresh)\"}".utf8))
            case "api-v2.soundcloud.com":
                let client = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "client_id" })?.value
                if client != fresh { return (401, "application/json", Data("{}".utf8)) }
                return (200, "application/json", Data(#"{"collection":[{"kind":"track","id":42,"title":"SC Track","duration":3000,"user":{"username":"SC Artist"}}]}"#.utf8))
            default: XCTFail("Unexpected host"); return (500, "text/plain", Data())
            }

        }
        let service = SourceService(configuration: .init(soundcloudClientId: String(repeating: "a", count: 32)), session: transport.session)
        let page = try await service.search(query: "track", source: "soundcloud")
        XCTAssertEqual(page.songs.first?.id, "s_42")
        XCTAssertEqual(page.songs.first?.duration, 3)
        XCTAssertFalse(transport.requests.contains(where: { $0.url?.host == "attacker.example" }))
    }

    func testSoundCloudSelectsMP3HLSInsteadOfUnsupportedAACPlaylist() async throws {
        let transport = FixtureTransport()
        transport.handler = { request in
            if request.url?.path == "/tracks/123" {
                return (200, "application/json", Data(#"{"streamable":true,"media":{"transcodings":[{"url":"https://api-v2.soundcloud.com/aac","format":{"mime_type":"audio/mp4","protocol":"hls"}},{"url":"https://api-v2.soundcloud.com/mp3","format":{"mime_type":"audio/mpeg","protocol":"hls"}}]}}"#.utf8))
            }
            XCTAssertEqual(request.url?.path, "/mp3")
            return (200, "application/json", Data(#"{"url":"https://cf-media.sndcdn.com/audio.m3u8"}"#.utf8))
        }
        let service = SourceService(configuration: .init(soundcloudClientId: String(repeating: "a", count: 32)), session: transport.session)
        let url = try await service.resolve(song: Song(id: "s_123", title: "Track", artist: ""))
        XCTAssertEqual(url.pathExtension, "m3u8")
    }

    func testSoundCloudResolutionCarriesFreshDurationInSeconds() async throws {
        let transport = FixtureTransport()
        transport.handler = { request in
            if request.url?.path == "/tracks/42" {
                return (200, "application/json", Data(#"{"duration":3714502,"streamable":true,"media":{"transcodings":[{"url":"https://api-v2.soundcloud.com/audio","format":{"mime_type":"audio/mpeg","protocol":"progressive"}}]}}"#.utf8))
            }
            return (200, "application/json", Data(#"{"url":"https://cf-media.sndcdn.com/audio.mp3"}"#.utf8))
        }
        let service = SourceService(configuration: .init(soundcloudClientId: String(repeating: "a", count: 32)), session: transport.session)
        let resource = try await service.resolveAudio(song: Song(id: "s_42", title: "Mix", artist: "Uploader", duration: 0))
        XCTAssertEqual(try XCTUnwrap(resource.duration), 3714.502, accuracy: 0.001)
        XCTAssertEqual(resource.url.host, "cf-media.sndcdn.com")
    }

    func testThrottlingAndInvalidContinuationsHaveExplicitErrors() async throws {
        let transport = FixtureTransport()
        transport.handler = { _ in (429, "text/plain", Data("slow down".utf8)) }
        let service = SourceService(session: transport.session)
        do { _ = try await service.search(query: "track", source: "youtube"); XCTFail("Throttled response must throw.") }
        catch { XCTAssertTrue(error.localizedDescription.contains("throttled")) }
        do { _ = try await service.loadMore(continuation: "not-base64"); XCTFail("Invalid continuation must throw.") }
        catch { XCTAssertTrue(error.localizedDescription.contains("continuation")) }
    }

    func testChannelResolutionUsesActualUploaderNotEditableArtist() async throws {
        let transport = FixtureTransport()
        transport.handler = { request in
            XCTAssertEqual(request.url?.path, "/watch")
            return (200, "text/html", Data(#"var ytInitialPlayerResponse = {"videoDetails":{"channelId":"UCabcdefghijklmnopqrstuv","author":"Actual uploader","title":"Track","lengthSeconds":"123"}};"#.utf8))
        }
        let service = SourceService(session: transport.session)
        var song = Song(id: "y_abcdefghijk", title: "Edited title", artist: "Not the uploader")
        let channelID = try await service.youtubeChannelID(for: song)
        XCTAssertEqual(channelID, Self.channelID)
        let imported = try await service.song(url: URL(string: "https://youtu.be/abcdefghijk")!)
        XCTAssertEqual(imported.youtubeChannelID, Self.channelID)
        song.fields["youtubeChannelId"] = .string(Self.channelID)
        let cachedID = try await service.youtubeChannelID(for: song)
        XCTAssertEqual(cachedID, Self.channelID)
        XCTAssertEqual(transport.requests.count, 2, "Retained uploader metadata must avoid another watch request.")
        do {
            _ = try await service.youtubeChannelID(for: Song(id: "s_42", title: "Track", artist: "Artist"))
            XCTFail("Other sources must not resolve a YouTube uploader.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("YouTube video")) }
    }

    func testChannelNewestScopesVideosTabAndPreservesMixedRendererOrderAndMetadata() async throws {
        let transport = FixtureTransport()
        transport.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/channel/\(Self.channelID)/videos")
            return (200, "text/html", try self.channelHTML())
        }
        let page = try await SourceService(session: transport.session).channel(id: Self.channelID)
        XCTAssertEqual(page.channel.title, "Real uploader")
        XCTAssertEqual(page.channel.url.absoluteString, "https://www.youtube.com/channel/\(Self.channelID)")
        XCTAssertEqual(page.songs.map(\.id), ["y_abcdefghijk", "y_lmnopqrstuv"])
        XCTAssertTrue(page.songs.allSatisfy { $0.artist == "Real uploader" && $0.youtubeChannelID == Self.channelID })
        XCTAssertEqual(page.songs.first?.duration, 231, "Current thumbnailBadgeViewModel durations must parse.")
        XCTAssertEqual(page.songs.first?.youtubeViews, "105K views")
        XCTAssertEqual(page.songs.first?.youtubePublished, "3mo ago")
        XCTAssertEqual(page.songs.last?.youtubeViews, "1,234 views")
        XCTAssertEqual(page.songs.last?.youtubePublished, "2 years ago")
        XCTAssertEqual(page.availableSorts, [.latest, .popular, .oldest])
        XCTAssertEqual(page.sort, .latest)
        XCTAssertNotNil(page.continuation)
    }

    func testChannelPopularAndOldestUseServerSortCommandsNotLoadedPageSorting() async throws {
        for sort in [YouTubeChannelSort.popular, .oldest] {
            let transport = FixtureTransport()
            transport.handler = { request in
                if request.httpMethod == "GET" { return (200, "text/html", try self.channelHTML()) }
                XCTAssertEqual(request.url?.path, "/youtubei/v1/browse")
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Youtube-Client-Version"), "channel-fixture-version")
                let body = try self.requestJSON(request)
                XCTAssertEqual(body["continuation"] as? String, "sort-\(sort.rawValue)")
                let id = sort == .popular ? "ppppppppppp" : "ooooooooooo"
                return (200, "application/json", try self.channelResponse(ids: [id], continuation: "sorted-page-two"))
            }
            let service = SourceService(session: transport.session)
            let page = try await service.channel(id: Self.channelID, sort: sort)
            XCTAssertEqual(page.sort, sort)
            XCTAssertEqual(page.songs.map(\.originalID), [sort == .popular ? "ppppppppppp" : "ooooooooooo"],
                           "The globally first video is not present in the original loaded page.")
            transport.handler = { request in
                XCTAssertEqual(try self.requestJSON(request)["continuation"] as? String, "sorted-page-two")
                return (200, "application/json", try self.channelResponse(ids: ["qqqqqqqqqqq"]))
            }
            let more = try await service.nextChannelPage(page)
            XCTAssertEqual(more.sort, sort)
            XCTAssertEqual(more.songs.last?.originalID, "qqqqqqqqqqq")
            XCTAssertTrue(more.songs.allSatisfy { $0.artist == "Real uploader" && $0.youtubeChannelID == Self.channelID })
        }
    }

    func testChannelSupportsLegacyBrowseSortEndpoints() async throws {
        let transport = FixtureTransport()
        transport.handler = { request in
            if request.httpMethod == "GET" { return (200, "text/html", try self.channelHTML(legacyChips: true)) }
            let body = try self.requestJSON(request)
            XCTAssertEqual(body["browseId"] as? String, Self.channelID)
            XCTAssertEqual(body["params"] as? String, "params-popular")
            XCTAssertNil(body["continuation"])
            return (200, "application/json", try self.channelResponse(ids: ["ppppppppppp"]))
        }
        let page = try await SourceService(session: transport.session).channel(id: Self.channelID, sort: .popular)
        XCTAssertEqual(page.songs.first?.originalID, "ppppppppppp")
    }

    func testChannelPaginationDeduplicatesAndIsNotLimitedToThirtyPages() async throws {
        let transport = FixtureTransport()
        transport.handler = { request in
            if request.httpMethod == "GET" { return (200, "text/html", try self.channelHTML()) }
            XCTAssertEqual(try self.requestJSON(request)["continuation"] as? String, "channel-page-two")
            return (200, "application/json", try self.channelResponse(ids: ["abcdefghijk", "qqqqqqqqqqq"]))
        }
        let service = SourceService(session: transport.session)
        var page = try await service.channel(id: Self.channelID)
        var context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(base64Encoded: try XCTUnwrap(page.continuation))!) as? [String: Any])
        context["page"] = 30
        page.continuation = try JSONSerialization.data(withJSONObject: context).base64EncodedString()
        let more = try await service.nextChannelPage(page)
        XCTAssertEqual(more.songs.map(\.id), ["y_abcdefghijk", "y_lmnopqrstuv", "y_qqqqqqqqqqq"])
        XCTAssertNil(more.continuation)
        do { _ = try await service.nextChannelPage(more); XCTFail("A completed channel has no next page.") }
        catch { XCTAssertTrue(error.localizedDescription.contains("All available")) }
    }

    func testChannelRejectsAdjacentAndCyclicContinuationsWithoutAppendingPartialResults() async throws {
        for repeated in [true, false] {
            let transport = FixtureTransport()
            var posts = 0
            transport.handler = { request in
                if request.httpMethod == "GET" { return (200, "text/html", try self.channelHTML()) }
                posts += 1
                let token = repeated || posts == 2 ? "channel-page-two" : "channel-page-three"
                return (200, "application/json", try self.channelResponse(ids: ["qqqqqqqqqqq"], continuation: token))
            }
            let service = SourceService(session: transport.session)
            var page = try await service.channel(id: Self.channelID)
            do {
                page = try await service.nextChannelPage(page)
                if !repeated { page = try await service.nextChannelPage(page) }
                XCTFail("Repeated channel continuation must fail.")
            } catch { XCTAssertTrue(error.localizedDescription.contains("repeated")) }
            XCTAssertEqual(page.songs.count, repeated ? 2 : 3)
        }
    }

    func testChannelUnavailableSortEmptyMalformedAndBlockedResponsesAreDistinct() async throws {
        let transport = FixtureTransport()
        let service = SourceService(session: transport.session)
        transport.handler = { _ in (200, "text/html", try self.channelHTML(includeChips: false, empty: true)) }
        let empty = try await service.channel(id: Self.channelID)
        XCTAssertTrue(empty.songs.isEmpty)
        XCTAssertNil(empty.continuation)
        XCTAssertEqual(empty.availableSorts, [.latest])
        do { _ = try await service.channel(id: Self.channelID, sort: .popular); XCTFail("Unavailable sort must not fall back to latest.") }
        catch { XCTAssertTrue(error.localizedDescription.contains("does not offer")) }
        for response in ["var ytInitialData = {\"unexpected\":{}};", "Sign in to confirm you're not a bot"] {
            transport.handler = { _ in (200, "text/html", Data(response.utf8)) }
            do { _ = try await service.channel(id: Self.channelID); XCTFail("Unavailable channel must throw.") }
            catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        }
        let beforeInvalid = transport.requests.count
        for id in ["../../bad", "UCshort", "https://evil.example", String(repeating: "a", count: 24)] {
            do { _ = try await service.channel(id: id); XCTFail("Invalid channel ID must not be fetched.") }
            catch { XCTAssertTrue(error.localizedDescription.contains("Invalid")) }
        }
        XCTAssertEqual(transport.requests.count, beforeInvalid)
    }

    private static let channelID = "UCabcdefghijklmnopqrstuv"

    private func channelHTML(legacyChips: Bool = false, includeChips: Bool = true, empty: Bool = false) throws -> Data {
        let chips: [[String: Any]] = includeChips ? YouTubeChannelSort.allCases.map { sort in
            if legacyChips {
                return ["chipCloudChipRenderer": ["text": ["simpleText": sort.youtubeLabel], "isSelected": sort == .latest,
                    "navigationEndpoint": ["browseEndpoint": ["browseId": Self.channelID, "params": "params-\(sort.rawValue)"]]]]
            }
            return ["chipViewModel": ["text": sort.youtubeLabel, "selected": sort == .latest,
                "tapCommand": ["innertubeCommand": ["continuationCommand": ["token": "sort-\(sort.rawValue)"]]]]]
        } : []
        let modern = try object(Self.modern)["sectionListRenderer"] as! [String: Any]
        var video = ((modern["contents"] as! [[String: Any]])[0]["lockupViewModel"] as! [String: Any])
        video["contentId"] = "abcdefghijk"
        video["metadata"] = ["lockupMetadataViewModel": ["title": ["content": "Modern channel video"],
            "metadata": ["contentMetadataViewModel": ["metadataRows": [["metadataParts": [
                ["text": ["content": "105K"], "accessibilityLabel": "105 thousand views", "leadingIcon": ["name": "PLAY_ARROW_OUTLINED"]],
                ["text": ["content": "3mo ago"], "accessibilityLabel": "3 months ago"],
            ]]]]]]]
        video["contentImage"] = ["thumbnailViewModel": ["overlays": [
            ["thumbnailBottomOverlayViewModel": ["badges": [["thumbnailBadgeViewModel": ["text": "3:51"]]]]],
        ]]]
        let items: [[String: Any]] = empty ? [] : [
            ["richItemRenderer": ["content": ["lockupViewModel": video]]],
            channelVideo("lmnopqrstuv"), continuationItem("channel-page-two"),
        ]
        let root: [String: Any] = [
            "metadata": ["channelMetadataRenderer": ["title": "Real uploader", "externalId": Self.channelID]],
            "contents": ["twoColumnBrowseResultsRenderer": ["tabs": [
                ["tabRenderer": ["title": "Home", "selected": false, "content": ["richGridRenderer": ["contents": [channelVideo("zzzzzzzzzzz")]]]]],
                ["tabRenderer": ["title": "Videos", "selected": true, "content": ["richGridRenderer": [
                    "header": ["chipBarViewModel": ["chips": chips]], "contents": items,
                ]]]],
            ]]],
        ]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: root), as: UTF8.self)
        return Data(("ytcfg.set({\"INNERTUBE_CONTEXT\":{\"client\":{\"clientVersion\":\"channel-fixture-version\"}}});var ytInitialData = \(json);").utf8)
    }

    private func channelVideo(_ id: String) -> [String: Any] {
        ["richItemRenderer": ["content": ["videoRenderer": [
            "videoId": id, "title": ["simpleText": "Channel video \(id)"], "viewCountText": ["simpleText": "1,234 views"],
            "publishedTimeText": ["simpleText": "2 years ago"], "lengthText": ["simpleText": "3:03"],
        ]]]]
    }

    private func continuationItem(_ token: String) -> [String: Any] {
        ["continuationItemRenderer": ["continuationEndpoint": ["continuationCommand": ["token": token]]]]
    }

    private func channelResponse(ids: [String], continuation: String? = nil) throws -> Data {
        var items = ids.map(channelVideo)
        if let continuation { items.append(continuationItem(continuation)) }
        return try JSONSerialization.data(withJSONObject: ["onResponseReceivedActions": [
            ["reloadContinuationItemsCommand": ["targetId": "browse-feed", "slot": "RELOAD_CONTINUATION_SLOT_HEADER",
                                               "continuationItems": [["chipBarViewModel": ["chips": []]]]]],
            ["reloadContinuationItemsCommand": ["targetId": "browse-feed", "continuationItems": items]],
        ]])
    }

    private func requestJSON(_ request: URLRequest) throws -> [String: Any] {
        if let data = request.httpBody { return try object(String(decoding: data, as: UTF8.self)) }
        guard let stream = request.httpBodyStream else { return [:] }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return try object(String(decoding: data, as: UTF8.self))
    }

    private static let legacy = #"{"contents":{"twoColumnSearchResultsRenderer":{"primaryContents":{"sectionListRenderer":{"contents":[{"itemSectionRenderer":{"contents":[{"videoRenderer":{"videoId":"abcdefghijk","title":{"runs":[{"text":"Track"}]},"longBylineText":{"runs":[{"text":"Artist"}]},"thumbnail":{"thumbnails":[{"url":"https://i.ytimg.com/vi/abcdefghijk/hqdefault.jpg"}]},"lengthText":{"simpleText":"3:03"}}},{"playlistRenderer":{"playlistId":"PLfixture","title":{"simpleText":"Collection"}}}]}},{"continuationItemRenderer":{"continuationEndpoint":{"continuationCommand":{"token":"next-page"}}}}]}}}}}"#
    private static let modern = #"{"sectionListRenderer":{"contents":[{"lockupViewModel":{"contentId":"lmnopqrstuv","contentType":"LOCKUP_CONTENT_TYPE_VIDEO","metadata":{"lockupMetadataViewModel":{"title":{"content":"Modern Track"},"metadata":{"contentMetadataViewModel":{"metadataRows":[{"metadataParts":[{"text":{"content":"Modern Artist"}}]}]}}}},"contentImage":{"thumbnailViewModel":{"image":{"sources":[{"url":"https://i.ytimg.com/vi/lmnopqrstuv/hqdefault.jpg"}]},"overlays":[{"thumbnailOverlayBadgeViewModel":{"text":"4:05"}}]}}}},{"lockupViewModel":{"contentId":"PLmodern","contentType":"LOCKUP_CONTENT_TYPE_PLAYLIST","metadata":{"lockupMetadataViewModel":{"title":{"content":"Modern Playlist"}}}}}]}}"#
}

/// Each fixture session owns its handler through a unique HTTP header; parallel tests cannot steal another test's responses.
private final class FixtureTransport {
    typealias Handler = (URLRequest) throws -> (Int, String, Data)
    private let id = UUID().uuidString
    private let lock = NSLock()
    private var captured: [URLRequest] = []
    var handler: Handler = { _ in (500, "text/plain", Data()) }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return captured }
    lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        config.httpAdditionalHeaders = ["X-Fixture-ID": id]
        FixtureProtocol.register(id: id) { [weak self] request in
            guard let self else { throw URLError(.cancelled) }
            self.lock.lock()
            self.captured.append(request)
            self.lock.unlock()
            return try self.handler(request)
        }
        return URLSession(configuration: config)
    }()
    deinit { FixtureProtocol.unregister(id: id) }
}

private final class FixtureProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handlers: [String: FixtureTransport.Handler] = [:]
    static func register(id: String, handler: @escaping FixtureTransport.Handler) { lock.lock(); defer { lock.unlock() }; handlers[id] = handler }
    static func unregister(id: String) { lock.lock(); defer { lock.unlock() }; handlers[id] = nil }
    override class func canInit(with request: URLRequest) -> Bool { request.value(forHTTPHeaderField: "X-Fixture-ID") != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handlers[request.value(forHTTPHeaderField: "X-Fixture-ID") ?? ""]
        Self.lock.unlock()
        do {
            let (status, mime, data) = try XCTUnwrap(handler)(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
