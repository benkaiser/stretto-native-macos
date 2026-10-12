import XCTest
@testable import StrettoCore
@testable import StrettoMac

final class ChannelBrowserTests: XCTestCase {
    @MainActor
    func testLateOldSortCannotReplaceTheNewSort() async throws {
        let transport = ChannelTransport()
        let held = expectation(description: "Original channel request started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let lock = NSLock()
        var gets = 0
        transport.handler = { request in
            if request.httpMethod == "GET" {
                lock.lock(); gets += 1; let first = gets == 1; lock.unlock()
                if first { held.fulfill(); _ = release.wait(timeout: .now() + 10) }
                return Data(Self.channelHTML.utf8)
            }
            return Data(Self.popularResponse.utf8)
        }
        let browser = YouTubeChannelBrowser(sources: SourceService(session: transport.session), song: Self.song)
        let original = Task { await browser.load() }
        await fulfillment(of: [held], timeout: 3)
        browser.sort = .popular
        await browser.load()
        XCTAssertEqual(browser.page?.sort, .popular)
        XCTAssertEqual(browser.page?.songs.first?.originalID, "ppppppppppp")
        release.signal()
        await original.value
        XCTAssertEqual(browser.page?.sort, .popular)
        XCTAssertEqual(browser.page?.songs.first?.originalID, "ppppppppppp")
        XCTAssertFalse(browser.isLoading)
        XCTAssertNil(browser.errorMessage)
    }

    @MainActor
    func testClosingBrowserInvalidatesInFlightResults() async throws {
        let transport = ChannelTransport()
        let held = expectation(description: "Channel request started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        transport.handler = { _ in
            held.fulfill()
            _ = release.wait(timeout: .now() + 10)
            return Data(Self.channelHTML.utf8)
        }
        let browser = YouTubeChannelBrowser(sources: SourceService(session: transport.session), song: Self.song)
        let pending = Task { await browser.load() }
        await fulfillment(of: [held], timeout: 3)
        browser.cancel()
        release.signal()
        await pending.value
        XCTAssertNil(browser.page)
        XCTAssertNil(browser.errorMessage)
        XCTAssertFalse(browser.isLoading)
    }

    @MainActor
    func testChangingSortCancelsOldPaginationAndKeepsChannelHeader() async throws {
        let transport = ChannelTransport()
        let held = expectation(description: "Old pagination request started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        transport.handler = { request in
            if request.httpMethod == "GET" { return Data(Self.channelHTML.utf8) }
            let data: Data
            if let body = request.httpBody { data = body }
            else {
                let stream = try XCTUnwrap(request.httpBodyStream)
                stream.open(); defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096)
                var result = Data()
                while stream.hasBytesAvailable {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    if count <= 0 { break }
                    result.append(contentsOf: bytes.prefix(count))
                }
                data = result
            }
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            if body["continuation"] as? String == "page-more" {
                held.fulfill()
                _ = release.wait(timeout: .now() + 10)
                return Data(Self.moreResponse.utf8)
            }
            return Data(Self.popularResponse.utf8)
        }
        let browser = YouTubeChannelBrowser(sources: SourceService(session: transport.session), song: Self.song)
        await browser.load()
        browser.loadMore()
        await fulfillment(of: [held], timeout: 3)
        XCTAssertTrue(browser.isLoadingMore)
        browser.sort = .popular
        await browser.load()
        release.signal()
        await Task.yield()
        XCTAssertEqual(browser.channel?.title, "Uploader")
        XCTAssertEqual(browser.page?.songs.map(\.originalID), ["ppppppppppp"])
        XCTAssertFalse(browser.isLoadingMore)
        XCTAssertNil(browser.errorMessage)
    }

    private static var song: Song {
        var song = Song(id: "y_abcdefghijk", title: "Video", artist: "Edited artist")
        song.fields["youtubeChannelId"] = .string("UCabcdefghijklmnopqrstuv")
        return song
    }
    private static let channelHTML = #"var ytInitialData = {"metadata":{"channelMetadataRenderer":{"title":"Uploader","externalId":"UCabcdefghijklmnopqrstuv"}},"contents":{"twoColumnBrowseResultsRenderer":{"tabs":[{"tabRenderer":{"title":"Videos","selected":true,"content":{"richGridRenderer":{"header":{"chipBarViewModel":{"chips":[{"chipViewModel":{"text":"Latest","selected":true,"tapCommand":{"innertubeCommand":{"continuationCommand":{"token":"sort-latest"}}}}},{"chipViewModel":{"text":"Popular","tapCommand":{"innertubeCommand":{"continuationCommand":{"token":"sort-popular"}}}}}]}},"contents":[{"videoRenderer":{"videoId":"abcdefghijk","title":{"simpleText":"Newest"}}},{"continuationItemRenderer":{"continuationEndpoint":{"continuationCommand":{"token":"page-more"}}}}]}}}}]}}};"#
    private static let popularResponse = #"{"onResponseReceivedActions":[{"reloadContinuationItemsCommand":{"continuationItems":[{"videoRenderer":{"videoId":"ppppppppppp","title":{"simpleText":"Popular"}}}]}}]}"#
    private static let moreResponse = #"{"onResponseReceivedActions":[{"appendContinuationItemsAction":{"continuationItems":[{"videoRenderer":{"videoId":"qqqqqqqqqqq","title":{"simpleText":"Old pagination"}}}]}}]}"#
}

final class ChannelTransport {
    private let id = UUID().uuidString
    var handler: (URLRequest) throws -> Data = { _ in Data() }
    lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ChannelProtocol.self]
        config.httpAdditionalHeaders = ["X-Channel-Fixture": id]
        ChannelProtocol.register(id: id) { [weak self] request in
            guard let self else { throw URLError(.cancelled) }
            return try self.handler(request)
        }
        return URLSession(configuration: config)
    }()
    deinit { ChannelProtocol.unregister(id: id) }
}

private final class ChannelProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var handlers: [String: (URLRequest) throws -> Data] = [:]
    private let stateLock = NSLock()
    private var stopped = false
    static func register(id: String, handler: @escaping (URLRequest) throws -> Data) {
        lock.lock(); defer { lock.unlock() }; handlers[id] = handler
    }
    static func unregister(id: String) { lock.lock(); defer { lock.unlock() }; handlers[id] = nil }
    override class func canInit(with request: URLRequest) -> Bool { request.value(forHTTPHeaderField: "X-Channel-Fixture") != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        DispatchQueue.global().async {
            Self.lock.lock()
            let handler = Self.handlers[self.request.value(forHTTPHeaderField: "X-Channel-Fixture") ?? ""]
            Self.lock.unlock()
            do {
                let data = try XCTUnwrap(handler)(self.request)
                self.stateLock.lock(); defer { self.stateLock.unlock() }
                guard !self.stopped else { return }
                let response = HTTPURLResponse(url: self.request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                               headerFields: ["Content-Type": "application/json"])!
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: data)
                self.client?.urlProtocolDidFinishLoading(self)
            } catch {
                self.stateLock.lock(); defer { self.stateLock.unlock() }
                if !self.stopped { self.client?.urlProtocol(self, didFailWithError: error) }
            }
        }
    }
    override func stopLoading() { stateLock.lock(); defer { stateLock.unlock() }; stopped = true }
}
