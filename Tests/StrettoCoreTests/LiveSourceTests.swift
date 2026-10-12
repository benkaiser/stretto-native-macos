import XCTest
@testable import StrettoCore

/// Opt-in integration tests use SourceService's production direct-client session, never a fixture/proxy session.
final class LiveSourceTests: XCTestCase {
    func testDirectYouTubeUploaderAndChannelGlobalSorting() async throws {
        try optIn()
        let service = SourceService()
        do {
            let channelID = try await service.youtubeChannelID(for: Song(id: "y_dQw4w9WgXcQ", title: "Edited", artist: "Not the uploader"))
            XCTAssertEqual(channelID, "UCuAXFkgsw1L7xaCfnd5JJOw")
            var orderBySort: [YouTubeChannelSort: [String]] = [:]
            for sort in YouTubeChannelSort.allCases {
                let page = try await service.channel(id: channelID, sort: sort)
                XCTAssertEqual(page.channel.title, "Rick Astley")
                XCTAssertFalse(page.songs.isEmpty)
                XCTAssertEqual(page.sort, sort)
                XCTAssertEqual(page.availableSorts, YouTubeChannelSort.allCases)
                XCTAssertTrue(page.songs.allSatisfy { $0.artist == "Rick Astley" && $0.youtubeChannelID == channelID })
                XCTAssertGreaterThan(page.songs.first?.duration ?? 0, 0)
                XCTAssertFalse(page.songs.first?.youtubeViews.isEmpty ?? true)
                XCTAssertFalse(page.songs.first?.youtubePublished.isEmpty ?? true)
                orderBySort[sort] = page.songs.map(\.originalID)
                log("Channel \(sort.title) VERIFIED: \(page.songs.count) videos, first=\(page.songs.first?.originalID ?? ""), views=\(page.songs.first?.youtubeViews ?? ""), uploaded=\(page.songs.first?.youtubePublished ?? "")")
                if sort == .popular {
                    XCTAssertEqual(page.songs.first?.originalID, "dQw4w9WgXcQ", "The known most-viewed upload must be first globally.")
                    XCTAssertNotNil(page.continuation)
                    let next = try await service.nextChannelPage(page)
                    XCTAssertGreaterThan(next.songs.count, page.songs.count)
                    XCTAssertEqual(next.songs.prefix(page.songs.count).map(\.id), page.songs.map(\.id))
                    XCTAssertEqual(Set(next.songs.map(\.id)).count, next.songs.count)
                    log("Channel popularity continuation VERIFIED: \(next.songs.count) total videos")
                }
            }
            XCTAssertNotEqual(orderBySort[.latest]?.first, orderBySort[.popular]?.first)
            XCTAssertNotEqual(orderBySort[.popular], orderBySort[.oldest],
                              "The most popular upload can also be the oldest; the complete server order must still differ.")
        } catch { try platformBlockOrThrow(error, platform: "YouTube channel browsing") }
    }

    func testDirectYouTubeSongAndPlaylistDiscovery() async throws {
        try optIn()
        let service = SourceService()
        let began = Date()
        log("YouTube direct search: song query")
        let songs: SearchPage
        do { songs = try await service.search(query: "Rick Astley Never Gonna Give You Up", source: "YouTube") }
        catch { try platformBlockOrThrow(error, platform: "YouTube song search"); return }
        XCTAssertFalse(songs.songs.isEmpty, "A successful live song search must contain parsed songs.")
        XCTAssertTrue(songs.songs.allSatisfy { $0.id.hasPrefix("y_") && $0.url.hasPrefix("https://www.youtube.com/watch?v=") })
        log("YouTube song search: \(songs.songs.count) songs, \(songs.playlists.count) playlists, continuation=\(songs.continuation != nil)")
        log("YouTube direct search: playlist query")
        let playlists: SearchPage
        do { playlists = try await service.search(query: "Rick Astley playlist", source: "youtube") }
        catch { try platformBlockOrThrow(error, platform: "YouTube playlist search"); return }
        XCTAssertFalse(playlists.playlists.isEmpty, "A successful live playlist search must contain parsed playlists.")
        XCTAssertTrue(playlists.playlists.allSatisfy { $0.url.host == "www.youtube.com" && $0.url.path == "/playlist" })
        log(String(format: "YouTube direct search VERIFIED: songs=%d playlists=%d elapsed=%.3fs",
                   songs.songs.count, playlists.playlists.count, Date().timeIntervalSince(began)))
        if let continuation = songs.continuation {
            log("YouTube direct Innertube search continuation: start (one page only)")
            do {
                let more = try await service.loadMore(continuation: continuation)
                XCTAssertFalse(more.songs.isEmpty && more.playlists.isEmpty, "Continuation unexpectedly returned no parsed media.")
                log("YouTube direct continuation VERIFIED: \(more.songs.count) songs, \(more.playlists.count) playlists")
            } catch { try platformBlockOrThrow(error, platform: "YouTube continuation"); return }
        }
    }

    func testDirectSoundCloudDiscoveryAndStreamResolution() async throws {
        try optIn()
        let service = SourceService(configuration: .init(soundcloudClientId: "3c2fb8cfc81c40dcfb99bb9f786f561c"))
        log("SoundCloud direct search: public instrumental query")
        let page: SearchPage
        do { page = try await service.search(query: "lofi instrumental", source: "SoundCloud") }
        catch { try platformBlockOrThrow(error, platform: "SoundCloud search"); return }
        XCTAssertFalse(page.songs.isEmpty, "A successful SoundCloud query must return parsed songs.")
        XCTAssertTrue(page.songs.allSatisfy { $0.id.hasPrefix("s_") })
        log("SoundCloud direct search VERIFIED: \(page.songs.count) public songs")
        var unavailable = 0
        for song in page.songs.prefix(5) {
            do {
                let stream = try await service.resolve(song: song)
                XCTAssertEqual(stream.scheme, "https")
                XCTAssertTrue(stream.host?.hasSuffix(".sndcdn.com") == true || stream.host?.hasSuffix(".soundcloud.com") == true)
                log("SoundCloud direct stream resolution VERIFIED: public track \(song.id), HTTPS host \(stream.host ?? "")")
                return
            } catch {
                let message = error.localizedDescription
                if message.contains("Go+") || message.contains("full-length") || message.contains("unavailable") {
                    unavailable += 1
                    log("SoundCloud track \(song.id) unavailable: \(message)")
                    continue
                }
                try platformBlockOrThrow(error, platform: "SoundCloud stream resolution")
                return
            }
        }
        throw XCTSkip("SoundCloud search succeeded, but all \(unavailable) bounded public samples were premium/unavailable; stream support is not live-verified.")
    }

    func testDirectSmallPublicYouTubePlaylistWhenExplicitlyConfigured() async throws {
        try optIn()
        guard let raw = ProcessInfo.processInfo.environment["STRETTO_LIVE_PLAYLIST_URL"], let url = URL(string: raw) else {
            throw XCTSkip("Set STRETTO_LIVE_PLAYLIST_URL to a verified small public YouTube playlist; no potentially huge search result is imported automatically.")
        }
        XCTAssertEqual(try SourceService.inputSource(url), "youtube")
        log("YouTube explicitly configured small public playlist: start")
        let service = SourceService()
        do {
            let playlist = try await service.playlist(url: url)
            XCTAssertFalse(playlist.songs.isEmpty)
            XCTAssertLessThanOrEqual(playlist.songs.count, 20, "The configured live playlist must be a known-small public test fixture.")
            XCTAssertTrue(playlist.songs.allSatisfy { $0.id.hasPrefix("y_") })
            log("YouTube direct playlist VERIFIED: \(playlist.songs.count) songs")
        } catch { try platformBlockOrThrow(error, platform: "YouTube playlist"); return }
    }

    private func optIn() throws {
        guard ProcessInfo.processInfo.environment["STRETTO_LIVE_SOURCE_TEST"] == "1" else {
            throw XCTSkip("Set STRETTO_LIVE_SOURCE_TEST=1 to make bounded direct public source requests.")
        }
    }

    private func platformBlockOrThrow(_ error: Error, platform: String) throws {
        let message = error.localizedDescription
        log("\(platform) live error: \(message)")
        let lower = message.lowercased()
        if lower.contains("bot challenge") || lower.contains("requires browser consent") ||
            lower.contains("throttled") || lower.contains("http 403") || lower.contains("http 401") ||
            lower.contains("public client id") && lower.contains("rejected") {
            throw XCTSkip("\(platform) blocked this unauthenticated client: \(message). This is not verified source success.")
        }
        throw error
    }

    private func log(_ text: String) {
        try? FileHandle.standardError.write(contentsOf: Data("[StrettoSource] \(text)\n".utf8))
    }
}
