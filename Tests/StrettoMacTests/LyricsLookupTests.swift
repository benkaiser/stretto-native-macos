import XCTest
@testable import StrettoCore
@testable import StrettoMac

final class LyricsLookupTests: XCTestCase {
    @MainActor
    func testServiceFailureIsNotDisplayedAsMissingAndReloadClearsTheError() async throws {
        let transport = ChannelTransport()
        transport.handler = { _ in throw URLError(.timedOut) }
        let lookup = LyricsLookup(service: LyricsService(session: transport.session))
        await lookup.load(song: Self.song)
        XCTAssertTrue(lookup.text.isEmpty)
        XCTAssertTrue(lookup.errorMessage?.contains("network error") == true)
        XCTAssertEqual(lookup.browserURL?.host, "lrclib.net")
        XCTAssertFalse(lookup.isLoading)
        transport.handler = { _ in Data(Self.record.utf8) }
        await lookup.load(song: Self.song)
        XCTAssertEqual(lookup.text, "Owned fixture text")
        XCTAssertNil(lookup.errorMessage)
        XCTAssertFalse(lookup.isLoading)
        lookup.reset()
        XCTAssertTrue(lookup.text.isEmpty)
        XCTAssertNil(lookup.errorMessage)
        XCTAssertNil(lookup.browserURL)
    }

    @MainActor
    func testLateFailureFromSameTrackCannotReplaceSuccessfulReload() async throws {
        let transport = ChannelTransport()
        let held = expectation(description: "First lyrics request started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let lock = NSLock()
        var count = 0
        transport.handler = { _ in
            lock.lock(); count += 1; let first = count == 1; lock.unlock()
            if first {
                held.fulfill()
                _ = release.wait(timeout: .now() + 10)
                throw URLError(.timedOut)
            }
            return Data(Self.record.utf8)
        }
        let lookup = LyricsLookup(service: LyricsService(session: transport.session))
        let old = Task { await lookup.load(song: Self.song) }
        await fulfillment(of: [held], timeout: 3)
        await lookup.load(song: Self.song)
        release.signal()
        await old.value
        XCTAssertEqual(lookup.text, "Owned fixture text")
        XCTAssertNil(lookup.errorMessage)
        XCTAssertFalse(lookup.isLoading)
    }

    @MainActor
    func testTrackChangeInvalidatesInFlightLyricsAndBrowserLink() async throws {
        let transport = ChannelTransport()
        let held = expectation(description: "Lyrics request started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        transport.handler = { _ in
            held.fulfill()
            _ = release.wait(timeout: .now() + 10)
            return Data(Self.record.utf8)
        }
        let lookup = LyricsLookup(service: LyricsService(session: transport.session))
        let old = Task { await lookup.load(song: Self.song) }
        await fulfillment(of: [held], timeout: 3)
        lookup.reset()
        release.signal()
        await old.value
        XCTAssertTrue(lookup.text.isEmpty)
        XCTAssertNil(lookup.browserURL)
        XCTAssertNil(lookup.errorMessage)
        XCTAssertFalse(lookup.isLoading)
    }

    private static let song = Song(id: "y_abcdefghijk", title: "Fixture Track", artist: "Fixture Artist", duration: 180)
    private static let record = #"{"id":1,"trackName":"Fixture Track","artistName":"Fixture Artist","albumName":"","duration":180,"plainLyrics":"Owned fixture text","instrumental":false}"#
}
