import XCTest
import AVFoundation
import CryptoKit
import MediaPlayer
import Combine
@testable import StrettoCore
@testable import StrettoMedia

final class MediaTests: XCTestCase {
    @MainActor
    func testWebMOpusIsDecodedDirectly() async throws {
        log("direct Opus/WebM: start")
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let webm = root.appendingPathComponent("silence.webm")
        try WebMFixture.audio(seconds: 4).write(to: webm)
        let duration = try await MPVEngine.inspectFile(webm)
        XCTAssertEqual(duration, 4, accuracy: 0.05)
        XCTAssertEqual(try Data(contentsOf: webm).prefix(4), Data([0x1a, 0x45, 0xdf, 0xa3]))
        log("direct Opus/WebM: passed without conversion")
    }

    @MainActor
    func testStreamingStartsBeforeWholeTransferAndCompletedCacheCanBePinned() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        GatedAudioProtocol.reset(audio: WebMFixture.audio(seconds: 4))
        let source = try ProgressiveAudioSource(remote: GatedAudioProtocol.url, makeTransfer: {
            AudioTransfer(protocolClasses: [GatedAudioProtocol.self])
        })
        defer { source.cancel() }
        let streamURL = try await source.prepare()
        var position = 0.0
        var ended = false
        var playbackError: String?
        let engine = try MPVEngine(volume: 0, silentOutput: true, source: source) { event in
            Task { @MainActor in
                if case .position(let seconds) = event { position = seconds }
                if case .ended = event { ended = true }
                if case .failed(let message) = event { playbackError = message }
            }
        }
        defer { engine.shutdown() }
        try engine.load(streamURL, paused: false)
        let startupDeadline = Date().addingTimeInterval(10)
        while position < 0.2 && playbackError == nil && Date() < startupDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNil(playbackError)
        XCTAssertGreaterThan(position, 0.2, "Audio must advance while the server is withholding the rest of the track.")
        XCTAssertLessThan(GatedAudioProtocol.sentBytes, GatedAudioProtocol.totalBytes, "Startup must not require a complete transfer.")
        XCTAssertFalse(source.isComplete)
        let sources = SourceService()
        let downloads = DownloadManager(sources: sources, root: root.appendingPathComponent("downloads"))
        try downloads.setAccount("streaming-fixture")
        let song = Song(id: "y_abcdefghijk", title: "Streaming silence", artist: "Stretto tests", duration: 4)
        XCTAssertNil(downloads.localURL(for: song))
        GatedAudioProtocol.releaseRemainder()
        let completionDeadline = Date().addingTimeInterval(10)
        while !ended && playbackError == nil && Date() < completionDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNil(playbackError)
        XCTAssertTrue(ended)
        engine.shutdown()
        XCTAssertTrue(source.isComplete)
        let original = try XCTUnwrap(source.fileURL)
        XCTAssertEqual(try Data(contentsOf: original), WebMFixture.audio(seconds: 4), "Cache input must be the exact original encoded bytes.")
        try await downloads.cacheCompletedPlayback(song, from: original, expectedDuration: 4, token: downloads.accountToken)
        let local = try XCTUnwrap(downloads.localURL(for: song))
        XCTAssertEqual(local.pathExtension, "webm")
        XCTAssertFalse(downloads.isPinned(song))
        let bytes = downloads.totalBytes
        await sources.configure(.init())
        try await downloads.download(song)
        XCTAssertTrue(downloads.isPinned(song), "Keep Offline must pin cached bytes without another network request.")
        XCTAssertEqual(downloads.totalBytes, bytes)
        let playback = PlaybackController(sources: sources, downloads: downloads)
        playback.volume = 0
        defer { playback.stop() }
        await playback.play(song)
        try await wait("original Opus cache playback", playback: playback) { playback.isPlaying && playback.position > 0.2 }
        log("STREAMING_VERIFIED played-before-complete=true opus-reencoded=false cache-pinned-without-network=true")
    }

    @MainActor
    func testControllerCachesOnlyNaturalCompleteListeningAndReportsNetworkFailure() async throws {
        for outcome in ["skip", "seek", "complete", "failure", "truncated", "hls"] {
            let root = try scratch()
            defer { try? FileManager.default.removeItem(at: root) }
            let mp3Frame = Data([0xff, 0xfb, 0x90, 0x64]) + Data(repeating: 0, count: 413)
            let webm = WebMFixture.audio(seconds: 4)
            let audio = outcome == "hls" ? (0..<154).reduce(into: Data()) { data, _ in data.append(mp3Frame) }
                : outcome == "truncated" ? Data(webm.prefix(webm.count / 2)) : webm
            GatedAudioProtocol.reset(audio: audio, hls: outcome == "hls")
            let sources = SourceService(configuration: .init(youtubeRedirectEndpoint: GatedAudioProtocol.url.absoluteString))
            let downloads = DownloadManager(sources: sources, root: root)
            let playback = PlaybackController(sources: sources, downloads: downloads, makeStream: {
                try ProgressiveAudioSource(remote: $0, makeTransfer: { AudioTransfer(protocolClasses: [GatedAudioProtocol.self]) })
            })
            playback.volume = 0
            defer { playback.stop() }
            let song = Song(id: "y_abcdefghijk", title: "Silent controller fixture", artist: "Stretto tests", duration: 4)
            let releaseTruncated: Task<Void, Error>? = outcome == "truncated" ? Task {
                while GatedAudioProtocol.sentBytes == 0 { try await Task.sleep(for: .milliseconds(10)) }
                GatedAudioProtocol.releaseRemainder()
            } : nil
            defer { releaseTruncated?.cancel() }
            await playback.play(song)
            try await wait("controller prefix playback", playback: playback) { playback.isPlaying && playback.position > 0.2 }
            XCTAssertTrue(downloads.entries.isEmpty)
            playback.resume()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertGreaterThan(playback.position, 0.2, "Activating the current row must not restart it.")
            switch outcome {
            case "skip":
                let began = Date()
                playback.stop()
                XCTAssertLessThan(Date().timeIntervalSince(began), 2, "Stopping must unblock a stalled demux read.")
            case "failure":
                GatedAudioProtocol.failTransfer()
                try await wait("visible transport failure", playback: playback, allowError: true) { playback.errorMessage != nil }
                XCTAssertFalse(playback.isPlaying)
            case "truncated":
                GatedAudioProtocol.releaseRemainder()
                try await wait("visible truncated audio failure", playback: playback, allowError: true) { playback.errorMessage != nil }
                XCTAssertFalse(playback.isPlaying)
            default:
                if outcome == "seek" { playback.seek(to: 1) }
                GatedAudioProtocol.releaseRemainder()
                try await wait("controller natural end", playback: playback) { !playback.isPlaying && playback.position > 3.8 }
                if outcome == "complete" || outcome == "hls" {
                    try await wait("controller completed-listen cache", playback: playback) { downloads.localURL(for: song) != nil }
                    let file = try XCTUnwrap(downloads.localURL(for: song))
                    XCTAssertEqual(try Data(contentsOf: file), audio)
                    XCTAssertFalse(downloads.isPinned(song))
                }
            }
            if outcome != "complete" && outcome != "hls" {
                try await Task.sleep(for: .milliseconds(150))
                XCTAssertTrue(downloads.entries.isEmpty, "\(outcome) must never become a completed-listen cache.")
            }
        }
    }

    @MainActor
    func testCacheAccountTokenRejectsAccountSwitchAndAcceptsDownloadCancellation() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("silence.webm")
        try WebMFixture.audio(seconds: 4).write(to: file)
        let downloads = DownloadManager(sources: SourceService(), root: root.appendingPathComponent("downloads"))
        let song = Song(id: "y_abcdefghijk", title: "Account fixture", artist: "", duration: 4)
        let oldToken = downloads.accountToken
        try downloads.setAccount("other-account")
        do {
            try await downloads.cacheCompletedPlayback(song, from: file, expectedDuration: 4, token: oldToken)
            XCTFail("A previous account's audio must not be adopted.")
        } catch is CancellationError {}
        XCTAssertTrue(downloads.entries.isEmpty)
        let token = downloads.accountToken
        downloads.cancelDownloads()
        try await downloads.cacheCompletedPlayback(song, from: file, expectedDuration: 4, token: token)
        XCTAssertNotNil(downloads.localURL(for: song))
    }

    @MainActor
    func testPlaybackCacheEvictionPreservesPinnedDownloads() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = SourceService()
        let downloads = DownloadManager(sources: sources, root: root)
        let directory = root.appendingPathComponent(hash("guest"), isDirectory: true)
        let pinnedSong = Song(id: "y_abcdefghijk", title: "Pinned fixture", artist: "")
        let cacheSong = Song(id: "y_lmnopqrstuv", title: "Eviction fixture", artist: "")
        let sizes: [Int64] = [2 * 1024 * 1024 * 1024 - 4096, 4096]
        var entries: [DownloadEntry] = []
        for (index, song) in [pinnedSong, cacheSong].enumerated() {
            let file = directory.appendingPathComponent("\(song.id).webm")
            XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
            let handle = try FileHandle(forWritingTo: file)
            try handle.truncate(atOffset: UInt64(sizes[index])) // Sparse files exercise the real quota without allocating 2 GB.
            try handle.close()
            var entry = DownloadEntry(id: song.id, song: song, bytes: sizes[index], status: "available", progress: 1, filename: file.lastPathComponent)
            entry.pinned = index == 0
            entry.cachedAt = .distantPast
            entries.append(entry)
        }
        try JSONEncoder().encode(entries).write(to: directory.appendingPathComponent("manifest.json"))
        try downloads.setAccount("guest")
        let newSong = Song(id: "y_12345678901", title: "New cache", artist: "", duration: 4)
        let incoming = root.appendingPathComponent("incoming.webm")
        try WebMFixture.audio(seconds: 4).write(to: incoming)
        try await downloads.cacheCompletedPlayback(newSong, from: incoming, expectedDuration: 4, token: downloads.accountToken)
        XCTAssertNotNil(downloads.localURL(for: pinnedSong))
        XCTAssertTrue(downloads.isPinned(pinnedSong))
        XCTAssertNil(downloads.localURL(for: cacheSong))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(cacheSong.id).webm").path))
        XCTAssertNotNil(downloads.localURL(for: newSong))
        XCTAssertLessThanOrEqual(downloads.totalBytes, 2 * 1024 * 1024 * 1024)
    }

    func testShortCompletedTransferIsReadyAndInvalidBodiesFail() async throws {
        let frame = Data([0xff, 0xfb, 0x90, 0x64]) + Data(repeating: 0, count: 413)
        for data in [frame, Data(), Data("<html>Blocked</html>".utf8)] {
            GatedAudioProtocol.reset(audio: data)
            let source = try ProgressiveAudioSource(remote: GatedAudioProtocol.url, makeTransfer: {
                AudioTransfer(protocolClasses: [GatedAudioProtocol.self])
            })
            defer { source.cancel() }
            let release = Task {
                try await Task.sleep(for: .milliseconds(100))
                GatedAudioProtocol.releaseRemainder()
            }
            do {
                let url = try await source.prepare()
                XCTAssertEqual(data, frame)
                XCTAssertEqual(url.pathExtension, "mp3")
                XCTAssertTrue(source.isComplete)
                let reader = try source.openReader()
                defer { reader.close() }
                var byte: CChar = 0
                XCTAssertEqual(withUnsafeMutablePointer(to: &byte) { reader.read(buffer: $0, count: 0) }, 0)
            } catch {
                XCTAssertNotEqual(data, frame, "A valid header in a sub-512-byte completed transfer must not wait forever.")
                XCTAssertTrue(error.localizedDescription.contains("empty") || error.localizedDescription.contains("unsupported"))
            }
            try await release.value
        }
    }

    @MainActor
    func testLocalFixturePlaybackSeekIsolationRecoveryAndRemoval() async throws {
        log("local fixture: start")
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = "media-fixture-account"
        let directory = root.appendingPathComponent(hash(account), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let song = Song(id: "y_abcdefghijk", title: "Silent fixture", artist: "Stretto tests", duration: 4)
        let audio = directory.appendingPathComponent("fixture.m4a")
        try writeSilentM4A(to: audio, seconds: 4)
        let bytes = Int64(try audio.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let entry = DownloadEntry(id: song.id, song: song, bytes: bytes, status: "available", progress: 1, filename: audio.lastPathComponent)
        try JSONEncoder().encode([entry]).write(to: directory.appendingPathComponent("manifest.json"))
        let sources = SourceService() // An empty endpoint makes any accidental network-resolution fallback fail.
        let downloads = DownloadManager(sources: sources, root: root)
        try downloads.setAccount(account)
        XCTAssertEqual(downloads.totalBytes, bytes)
        XCTAssertEqual(downloads.localURL(for: song), audio)
        let playback = PlaybackController(sources: sources, downloads: downloads)
        playback.volume = 0
        defer { playback.stop() }
        try await bounded("local fixture play", playback: playback, downloads: downloads) { await playback.play(song, in: [song]) }
        try await wait("local native playback", playback: playback) { playback.isPlaying && playback.position > 0.3 }
        var playingUpdates = 0
        var loadingUpdates = 0
        let playingSubscription = playback.$isPlaying.dropFirst().sink { _ in playingUpdates += 1 }
        let loadingSubscription = playback.$isLoading.dropFirst().sink { _ in loadingUpdates += 1 }
        let position = playback.position
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertGreaterThan(playback.position, position)
        XCTAssertEqual(playingUpdates, 0, "Position ticks must not republish unchanged playback activity.")
        XCTAssertEqual(loadingUpdates, 0, "Position ticks must not republish unchanged loading state.")
        playingSubscription.cancel()
        loadingSubscription.cancel()
        XCTAssertEqual(playback.duration, 4, accuracy: 0.15)
        XCTAssertNil(playback.errorMessage)
        playback.toggle()
        try await wait("pause", playback: playback) { !playback.isPlaying }
        playback.seek(to: 2)
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(playback.position, 2, accuracy: 0.2)
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, song.title)
        playback.toggle()
        try await wait("resume", playback: playback) { playback.isPlaying }
        playback.stop()
        XCTAssertNil(playback.currentSong)
        XCTAssertFalse(playback.isPlaying)
        try downloads.setAccount("different-account")
        XCTAssertNil(downloads.localURL(for: song))
        XCTAssertEqual(downloads.totalBytes, 0)
        try downloads.setAccount(account)
        XCTAssertNotNil(downloads.localURL(for: song))
        try downloads.remove(song)
        XCTAssertNil(downloads.localURL(for: song))
        XCTAssertEqual(downloads.totalBytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        // Recovery rejects a manifest entry whose audio has disappeared.
        try JSONEncoder().encode([entry]).write(to: directory.appendingPathComponent("manifest.json"))
        try downloads.setAccount(account)
        XCTAssertTrue(downloads.entries.isEmpty)
        log("local fixture: playback/pause/seek/isolation/recovery/removal passed")
    }

    @MainActor
    func testUnsupportedCurrentTrackKeepsErrorAndNextCanAdvance() async throws {
        log("source errors and Next: start")
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = SourceService()
        let downloads = DownloadManager(sources: sources, root: root)
        let playback = PlaybackController(sources: sources, downloads: downloads)
        playback.volume = 0
        defer { playback.stop() }
        let unsupported = Song(id: "a_preserved", title: "Unsupported source", artist: "")
        let supported = Song(id: "y_abcdefghijk", title: "Supported but unconfigured", artist: "")
        try await bounded("unsupported source play", playback: playback, downloads: downloads) { await playback.play(unsupported, in: [unsupported, supported]) }
        XCTAssertEqual(playback.currentSong?.id, unsupported.id)
        XCTAssertTrue(playback.errorMessage?.contains("preserved") == true)
        XCTAssertFalse(playback.isPlaying)
        playback.next()
        try await wait("advance from unsupported source", playback: playback, allowError: true) { playback.currentSong?.id == supported.id && playback.errorMessage != nil }
        XCTAssertTrue(playback.errorMessage?.contains("configured") == true)
        playback.volume = 3
        XCTAssertEqual(playback.volume, 1)
        playback.volume = -2
        XCTAssertEqual(playback.volume, 0)
        playback.repeatMode = "invalid"
        XCTAssertEqual(playback.repeatMode, "off")
        log("source errors and Next: passed")
    }

    @MainActor
    func testSoundCloudUsesFreshTotalDurationInsteadOfGrowingMP3ReadAhead() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let frame = Data([0xff, 0xfb, 0x90, 0x64]) + Data(repeating: 0, count: 413)
        let audio = (0..<154).reduce(into: Data()) { data, _ in data.append(frame) }
        GatedAudioProtocol.reset(audio: audio, hls: true)
        let transport = ChannelTransport()
        transport.handler = { request in
            if request.url?.path == "/tracks/42" {
                return Data(#"{"duration":3714502,"streamable":true,"media":{"transcodings":[{"url":"https://api-v2.soundcloud.com/audio","format":{"mime_type":"audio/mpeg","protocol":"hls"}}]}}"#.utf8)
            }
            return try JSONSerialization.data(withJSONObject: ["url": GatedAudioProtocol.url.absoluteString])
        }
        let sources = SourceService(configuration: .init(soundcloudClientId: String(repeating: "a", count: 32)), session: transport.session)
        let downloads = DownloadManager(sources: sources, root: root)
        let playback = PlaybackController(sources: sources, downloads: downloads, makeStream: {
            try ProgressiveAudioSource(remote: $0, makeTransfer: { AudioTransfer(protocolClasses: [GatedAudioProtocol.self]) })
        })
        playback.volume = 0
        defer { playback.stop() }
        let song = Song(id: "s_42", title: "Duration fixture", artist: "", duration: 12)
        await playback.play(song)
        try await wait("MP3 prefix with source duration", playback: playback) { playback.isPlaying && playback.position > 0.3 }
        XCTAssertEqual(playback.duration, 3714.502, accuracy: 0.001,
                       "Fresh full-track metadata must replace stale library duration and resist short demux read-ahead estimates.")
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyPlaybackDuration] as? Double,
                       3714.502, "macOS controls must use the same stable full-track duration.")
        XCTAssertTrue(downloads.entries.isEmpty)
        XCTAssertLessThan(GatedAudioProtocol.sentBytes, GatedAudioProtocol.totalBytes)
    }

    @MainActor
    func testLiveReportedSoundCloudMixDurationWithoutAudioOutput() async throws {
        guard ProcessInfo.processInfo.environment["STRETTO_LIVE_SOUNDCLOUD_MEDIA_TEST"] == "1" else {
            throw XCTSkip("Opt in with STRETTO_LIVE_SOUNDCLOUD_MEDIA_TEST=1 for the reported public SoundCloud mix.")
        }
        let sources = SourceService(configuration: .init(soundcloudClientId: "3c2fb8cfc81c40dcfb99bb9f786f561c"))
        let song = try await sources.song(url: URL(string: "https://soundcloud.com/shortroundd/hiddenforestpodcast-shortround")!)
        let resource = try await sources.resolveAudio(song: song)
        XCTAssertEqual(try XCTUnwrap(resource.duration), song.duration, accuracy: 0.01)
        let source = try ProgressiveAudioSource(remote: resource.url)
        defer { source.cancel() }
        let began = Date()
        let streamURL = try await source.prepare()
        var position = 0.0
        var durations: [Double] = []
        var failure: String?
        var ended = false
        let engine = try MPVEngine(volume: 0, silentOutput: true, source: source) { event in
            Task { @MainActor in
                if case .position(let seconds) = event { position = seconds }
                if case .duration(let seconds) = event, seconds > 0 { durations.append(seconds) }
                if case .failed(let message) = event { failure = message }
                if case .ended = event { ended = true }
            }
        }
        defer { engine.shutdown() }
        try engine.load(streamURL, paused: false)
        while Date().timeIntervalSince(began) < 15 && failure == nil {
            try await Task.sleep(for: .seconds(1))
            log(String(format: "SOUNDCLOUD_DIAGNOSTIC elapsed=%.2fs position=%.2fs decoderDuration=%.2fs sourceDuration=%.2fs bytes=%lld complete=%@",
                       Date().timeIntervalSince(began), position, durations.last ?? 0, song.duration,
                       source.receivedBytes, source.isComplete.description))
        }
        XCTAssertNil(failure)
        XCTAssertGreaterThan(position, 1)
        XCTAssertGreaterThan(song.duration, 1800)
        XCTAssertLessThanOrEqual(position, Date().timeIntervalSince(began) + 1,
                                 "Decoded playback must run at real time, regardless of estimated duration.")
        log("SOUNDCLOUD_DIAGNOSTIC format=\(streamURL.pathExtension) decoderDurationMin=\(durations.min() ?? 0) decoderDurationMax=\(durations.max() ?? 0) sourceDuration=\(song.duration)")
        if source.isComplete {
            let fileDuration = try await MPVEngine.inspectFile(try XCTUnwrap(source.fileURL))
            XCTAssertEqual(fileDuration, song.duration, accuracy: 1)
            try engine.seek(120)
            let seekDeadline = Date().addingTimeInterval(5)
            while position < 119.8 && failure == nil && Date() < seekDeadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertNil(failure)
            XCTAssertGreaterThanOrEqual(position, 119.8, "Seeking must use the real audio timeline, not the short read-ahead estimate.")
            try engine.seek(song.duration - 2)
            let endDeadline = Date().addingTimeInterval(8)
            while !ended && failure == nil && Date() < endDeadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertNil(failure)
            XCTAssertTrue(ended)
            XCTAssertEqual(position, song.duration, accuracy: 1, "Allow the same final-position tolerance used by playback completion.")
            log(String(format: "SOUNDCLOUD_DIAGNOSTIC seek=120s nearEndNaturalEOF=%.3fs fileDuration=%.3fs sourceDuration=%.3fs",
                       position, fileDuration, song.duration))
        } else {
            log("SOUNDCLOUD_DIAGNOSTIC bounded stream sample passed; near-end seeking was not checked because transfer is incomplete.")
        }
        source.cancel()
    }

    @MainActor
    func testLiveYouTubeStreamingAndOriginalOfflineReuse() async throws {
        guard ProcessInfo.processInfo.environment["STRETTO_LIVE_MEDIA_TEST"] == "1" else {
            throw XCTSkip("Opt in with STRETTO_LIVE_MEDIA_TEST=1 to use the public deployed audio resolver.")
        }
        log("live resolver: start (muted)")
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = ProcessInfo.processInfo.environment["STRETTO_MEDIA_ENDPOINT"] ?? "https://home.kaiser.lol:59436/youtuberedirect"
        let id = ProcessInfo.processInfo.environment["STRETTO_MEDIA_ID"] ?? "dQw4w9WgXcQ"
        let sources = SourceService(configuration: .init(youtubeRedirectEndpoint: endpoint))
        let downloads = DownloadManager(sources: sources, root: root)
        try downloads.setAccount("live-media-verification")
        let playback = PlaybackController(sources: sources, downloads: downloads)
        playback.volume = 0
        defer { playback.stop() }
        let song = Song(id: "y_\(id)", title: "Public YouTube playback verification", artist: "Muted verification", url: "https://www.youtube.com/watch?v=\(id)")
        let began = Date()
        try await bounded("live streaming startup", timeout: 30, playback: playback, downloads: downloads) { await playback.play(song, in: [song]) }
        try await wait("live WebM playback/time advancing", playback: playback, timeout: 30) { playback.isPlaying && playback.position > 0.5 }
        let startupSeconds = Date().timeIntervalSince(began)
        XCTAssertNil(playback.errorMessage)
        XCTAssertGreaterThan(playback.duration, 30)
        XCTAssertNil(downloads.localURL(for: song), "Starting playback must not download/pin the whole track.")
        XCTAssertTrue(downloads.entries.isEmpty)
        log(String(format: "live direct WebM playback ready: startup=%.3fs duration=%.3fs", startupSeconds, playback.duration))
        playback.toggle()
        try await wait("live pause", playback: playback) { !playback.isPlaying }
        playback.seek(to: 10)
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(playback.position, 10, accuracy: 0.25)
        log("live pause and 10-second seek: passed")
        playback.toggle()
        try await wait("live resume after seek", playback: playback) { playback.isPlaying && playback.position > 10.3 }
        playback.stop()
        XCTAssertTrue(downloads.entries.isEmpty, "A skipped or seeked track must not become a completed-listen cache.")
        try await bounded("explicit original-format download", timeout: 90, playback: playback, downloads: downloads) {
            try await downloads.download(song)
        }
        let local = try XCTUnwrap(downloads.localURL(for: song))
        XCTAssertEqual(local.pathExtension, "webm")
        XCTAssertTrue(downloads.isPinned(song))
        let downloadedBytes = downloads.totalBytes
        let audioDuration = try await MPVEngine.inspectFile(local)
        // Disable every remote resolution path. A new manager must recover and play only persisted local bytes.
        await sources.configure(.init())
        let recovered = DownloadManager(sources: sources, root: root)
        try recovered.setAccount("live-media-verification")
        let offline = PlaybackController(sources: sources, downloads: recovered)
        offline.volume = 0
        defer { offline.stop() }
        let offlineBegan = Date()
        try await bounded("offline recovery play", playback: offline, downloads: recovered) { await offline.play(song) }
        try await wait("offline playback without configured endpoint", playback: offline) { offline.isPlaying && offline.position > 0.3 }
        let offlineSeconds = Date().timeIntervalSince(offlineBegan)
        XCTAssertNil(offline.errorMessage)
        XCTAssertEqual(recovered.totalBytes, downloadedBytes)
        offline.stop()
        try recovered.remove(song)
        XCTAssertNil(recovered.localURL(for: song))
        XCTAssertFalse(FileManager.default.fileExists(atPath: local.path))
        log(String(format: "STRETTO_MEDIA_VERIFIED startup=%.3fs duration=%.3fs seek=10s bytes=%lld offlineStartup=%.3fs muted=true removed=true",
                   startupSeconds, audioDuration, downloadedBytes, offlineSeconds))
    }

    @MainActor
    private func wait(_ description: String, playback: PlaybackController, timeout: Double = 15, allowError: Bool = false,
                      condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            if !allowError, let error = playback.errorMessage { throw StrettoError.message("\(description): \(error)") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw StrettoError.message("Timed out waiting for \(description). playing=\(playback.isPlaying) loading=\(playback.isLoading) position=\(playback.position)")
    }

    @MainActor
    private func bounded(_ name: String, timeout: Double = 15, playback: PlaybackController, downloads: DownloadManager,
                         operation: @escaping @MainActor () async throws -> Void) async throws {
        log("\(name): start")
        try await withCheckedThrowingContinuation { continuation in
            let stage = MediaStage(continuation: continuation)
            stage.operation = Task {
                do { try await operation(); stage.finish(.success(())) }
                catch { stage.finish(.failure(error)) }
            }
            stage.timer = Task {
                do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) } catch { return }
                playback.stop()
                downloads.cancel()
                stage.operation?.cancel()
                stage.finish(.failure(StrettoError.message("Media stage timed out after \(timeout)s: \(name)")))
            }
        }
        log("\(name): finished")
    }

    private func log(_ text: String) {
        try? FileHandle.standardError.write(contentsOf: Data("[StrettoMedia] \(text)\n".utf8))
    }

    private func scratch() throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".local/media-verification-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @MainActor
    private final class MediaStage {
        var operation: Task<Void, Never>?
        var timer: Task<Void, Never>?
        private var continuation: CheckedContinuation<Void, Error>?
        init(continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
        func finish(_ result: Result<Void, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            timer?.cancel()
            timer = nil
            operation = nil
            continuation.resume(with: result)
        }
    }
    private func hash(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func writeSilentM4A(to url: URL, seconds: Double) throws {
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * 44100)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        buffer.frameLength = frames
        try XCTUnwrap(buffer.floatChannelData)[0].initialize(repeating: 0, count: Int(frames))
        try file.write(from: buffer)
    }
}
