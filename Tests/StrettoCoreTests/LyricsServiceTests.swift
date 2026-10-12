import XCTest
@testable import StrettoCore

final class LyricsServiceTests: XCTestCase {
    private let song = Song(id: "y_fixture", title: "Fixture Track", artist: "Fixture Artist", album: "Fixture Album", duration: 180)
    private static let missing = Data(#"{"name":"TrackNotFound","statusCode":404,"message":"Failed to find specified track"}"#.utf8)

    private func record(title: String = "Fixture Track", artist: String = "Fixture Artist",
                        album: String = "Fixture Album", duration: Double? = 180,
                        text: String? = "Original fixture text\n", instrumental: Bool = false, id: Int = 1) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "id": id, "trackName": title, "artistName": artist, "albumName": album,
            "duration": duration.map { $0 as Any } ?? NSNull(), "plainLyrics": text.map { $0 as Any } ?? NSNull(),
            "instrumental": instrumental
        ])
    }

    private func array(_ records: [Data]) -> Data {
        Data(("[" + records.map { String(decoding: $0, as: UTF8.self) }.joined(separator: ",") + "]").utf8)
    }

    private func assertError(_ expected: LyricsError, service: LyricsService, song: Song? = nil,
                             file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await service.lookup(song: song ?? self.song)
            XCTFail("Expected typed lyrics failure", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? LyricsError, expected, file: file, line: line)
            XCTAssertFalse(error.localizedDescription.isEmpty, file: file, line: line)
        }
    }

    func testExactLookupPreservesTextAndEncodesMetadata() async throws {
        let transport = LyricsFixtureTransport()
        let text = "\n  Original fixture attribution © fixture\nSecond fixture line\r\n"
        transport.handler = { request in
            XCTAssertEqual(request.url?.host, "lrclib.net")
            XCTAssertEqual(request.url?.path, "/api/get")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "StrettoNative/0.1 (https://next.kaiserapps.com)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "duration" }?.value, "180.0")
            XCTAssertEqual(query.first { $0.name == "album_name" }?.value, "Fixture Album")
            return .init(data: try self.record(text: text))
        }
        let result = try await LyricsService(session: transport.session).lookup(song: song)
        XCTAssertEqual(result, .found(text))
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testInstrumentalIsNotMissing() async throws {
        let transport = LyricsFixtureTransport()
        transport.handler = { _ in .init(data: try self.record(text: nil, instrumental: true)) }
        let result = try await LyricsService(session: transport.session).lookup(song: song)
        XCTAssertEqual(result, .instrumental)
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testGenuine404FallsBackWithoutAlbumAndReturnsMissing() async throws {
        let transport = LyricsFixtureTransport()
        transport.handler = { request in
            if request.url?.path == "/api/get" { return .init(status: 404, data: Self.missing) }
            XCTAssertEqual(request.url?.path, "/api/search")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(Set(query.map(\.name)), ["track_name", "artist_name"])
            return .init(data: Data("[]".utf8))
        }
        let result = try await LyricsService(session: transport.session).lookup(song: song)
        XCTAssertEqual(result, .notFound)
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testSearchValidatesTitleArtistAndDurationRatherThanFirstHit() async throws {
        let hits = try array([
            record(title: "Fixture Track (Live)", text: "Wrong fixture version"),
            record(artist: "Cover Artist", text: "Wrong fixture artist"),
            record(duration: 195, text: "Wrong fixture duration"),
            record(duration: nil, text: "Unknown fixture duration"),
            record(album: "Reissue", duration: 181.5, text: "Correct fixture version")
        ])
        let transport = LyricsFixtureTransport()
        transport.handler = { request in
            request.url?.path == "/api/get" ? .init(status: 404, data: Self.missing) : .init(data: hits)
        }
        let result = try await LyricsService(session: transport.session).lookup(song: song)
        XCTAssertEqual(result, .found("Correct fixture version"))
    }

    func testSearchPrefersMatchingAlbumAndAllowsIdenticalReissues() async throws {
        let transport = LyricsFixtureTransport()
        var hits = try array([record(album: "Other", text: "Other fixture text"),
                              record(text: "Matching fixture text")])
        transport.handler = { request in
            request.url?.path == "/api/get" ? .init(status: 404, data: Self.missing) : .init(data: hits)
        }
        let service = LyricsService(session: transport.session)
        let first = try await service.lookup(song: song)
        XCTAssertEqual(first, .found("Matching fixture text"))
        hits = try array([record(album: "Reissue One"), record(album: "Reissue Two", id: 2)])
        let duplicate = try await service.lookup(song: song)
        XCTAssertEqual(duplicate, .found("Original fixture text\n"))
    }

    func testConflictingMatchingVersionsAreAmbiguous() async throws {
        let hits = try array([record(text: "First fixture text"), record(text: "Second fixture text", id: 2)])
        let transport = LyricsFixtureTransport()
        transport.handler = { request in
            request.url?.path == "/api/get" ? .init(status: 404, data: Self.missing) : .init(data: hits)
        }
        await assertError(.ambiguousMatch, service: LyricsService(session: transport.session))
    }

    func testWrongMetadataAndEmptyLyricsCannotBecomeFound() async throws {
        let transport = LyricsFixtureTransport()
        transport.handler = { request in
            if request.url?.path == "/api/get" { return .init(data: try self.record(title: "Unrelated Track")) }
            return .init(data: try self.array([self.record(text: " \n"), self.record(title: "Another Track")]))
        }
        let result = try await LyricsService(session: transport.session).lookup(song: song)
        XCTAssertEqual(result, .notFound)
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testMatchingExactEmptyRecordSearchesForAvailableText() async throws {
        let transport = LyricsFixtureTransport()
        transport.handler = { request in
            if request.url?.path == "/api/get" { return .init(data: try self.record(text: nil)) }
            return .init(data: try self.array([self.record()]))
        }
        let result = try await LyricsService(session: transport.session).lookup(song: song)
        XCTAssertEqual(result, .found("Original fixture text\n"))
    }

    func testUnavailableAndThrottledAreNotMissingAndDoNotRetry() async throws {
        for status in [429, 500, 502, 503, 504] {
            let transport = LyricsFixtureTransport()
            transport.handler = { _ in .init(status: status, headers: ["Retry-After": "1"],
                                             data: Data(#"{"name":"ServerOverloaded","statusCode":503}"#.utf8)) }
            let expected: LyricsError = status == 429 ? .throttled(retryAfter: 1) : .unavailable(status: status, retryAfter: 1)
            await assertError(expected, service: LyricsService(session: transport.session))
            XCTAssertEqual(transport.requests.count, 1)
        }
    }

    func testHTMLChallengeAndCloudflareHeaderAreExplicit() async throws {
        for status in [200, 403, 503] {
            let transport = LyricsFixtureTransport()
            transport.handler = { _ in .init(status: status, mime: "text/html",
                                             data: Data("<html><title>Just a moment...</title><script src='/cdn-cgi/challenge-platform/test'></script></html>".utf8)) }
            await assertError(.challenge, service: LyricsService(session: transport.session))
            XCTAssertEqual(transport.requests.count, 1)
        }
        let transport = LyricsFixtureTransport()
        transport.handler = { _ in .init(status: 403, headers: ["cf-mitigated": "challenge"], data: Data()) }
        await assertError(.challenge, service: LyricsService(session: transport.session))
    }

    func testRetryAfterCooldownPreventsImmediateManualRetry() async {
        for status in [429, 503] {
            let transport = LyricsFixtureTransport()
            transport.handler = { _ in .init(status: status, headers: ["Retry-After": "60"], data: Data()) }
            let service = LyricsService(session: transport.session)
            let error: LyricsError = status == 429 ? .throttled(retryAfter: 60) : .unavailable(status: 503, retryAfter: 60)
            await assertError(error, service: service)
            await assertError(error, service: service)
            XCTAssertEqual(transport.requests.count, 1)
        }
    }

    func testInvalidRetryAfterIsIgnoredAndHTTPDateIsSupported() async {
        for value in ["-1", "nan", "malformed"] {
            let transport = LyricsFixtureTransport()
            transport.handler = { _ in .init(status: 503, headers: ["Retry-After": value], data: Data()) }
            await assertError(.unavailable(status: 503, retryAfter: nil), service: LyricsService(session: transport.session))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        let future = formatter.string(from: Date().addingTimeInterval(60))
        let transport = LyricsFixtureTransport()
        transport.handler = { _ in .init(status: 429, headers: ["Retry-After": future], data: Data()) }
        let service = LyricsService(session: transport.session)
        do {
            _ = try await service.lookup(song: song)
            XCTFail("Expected throttling")
        } catch LyricsError.throttled(let delay) {
            XCTAssertNotNil(delay)
            XCTAssertTrue((delay ?? 0) > 50)
            XCTAssertTrue((delay ?? 100) <= 60)
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testOrdinaryUnavailableHTMLIsNotMisdiagnosedAsCaptcha() async throws {
        let transport = LyricsFixtureTransport()
        transport.handler = { _ in .init(status: 503, mime: "text/html", data: Data("<html>Service Unavailable</html>".utf8)) }
        await assertError(.unavailable(status: 503, retryAfter: nil), service: LyricsService(session: transport.session))
    }

    func testInvalidHTTPMIMEJSONAndSchemaAreErrors() async throws {
        let responses: [(LyricsFixtureResponse, LyricsError)] = [
            (.init(status: 403, data: Data("{}".utf8)), .httpStatus(403)),
            (.init(status: 400, mime: "text/plain", data: Data("bad input".utf8)), .httpStatus(400)),
            (.init(status: 404, mime: "text/html", data: Data("<html>Not Found</html>".utf8)), .invalidResponse),
            (.init(status: 404, data: Data(#"{"name":"WrongRoute","statusCode":404}"#.utf8)), .invalidResponse),
            (.init(mime: "text/html", data: try record()), .invalidResponse),
            (.init(data: Data("<html>Not lyrics</html>".utf8)), .invalidResponse),
            (.init(data: Data("{".utf8)), .invalidResponse),
            (.init(data: Data(#"{"plainLyrics":"fixture"}"#.utf8)), .invalidResponse),
            (.init(data: try record(id: -1)), .invalidResponse),
            (.init(data: try record(duration: -1)), .invalidResponse)
        ]
        for (response, expected) in responses {
            let transport = LyricsFixtureTransport()
            transport.handler = { _ in response }
            await assertError(expected, service: LyricsService(session: transport.session))
            XCTAssertEqual(transport.requests.count, 1)
        }
    }

    func testFallbackFailureDoesNotHideTheError() async throws {
        let transport = LyricsFixtureTransport()
        transport.handler = { request in
            request.url?.path == "/api/get" ? .init(status: 404, data: Self.missing) : .init(status: 503, data: Data())
        }
        await assertError(.unavailable(status: 503, retryAfter: nil), service: LyricsService(session: transport.session))
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testMalformedAndOverLimitSearchResponsesAreErrors() async throws {
        for body in [Data("{}".utf8), try array(Array(repeating: record(), count: 21)),
                     Data(#"[{"id":1,"trackName":"Fixture Track"}]"#.utf8)] {
            let transport = LyricsFixtureTransport()
            transport.handler = { request in
                request.url?.path == "/api/get" ? .init(status: 404, data: Self.missing) : .init(data: body)
            }
            await assertError(.invalidResponse, service: LyricsService(session: transport.session))
        }
    }

    func testResponseURLAndSizeAreValidated() async throws {
        let transport = LyricsFixtureTransport()
        for url in ["http://lrclib.net/api/get", "https://lrclib.net.attacker.example/api/get",
                    "https://lrclib.net:444/api/get", "https://lrclib.net/other"] {
            transport.handler = { _ in .init(data: try self.record(), url: URL(string: url)) }
            await assertError(.invalidResponse, service: LyricsService(session: transport.session))
        }
        transport.handler = { _ in .init(headers: ["Content-Length": "2000001"], data: Data()) }
        await assertError(.responseTooLarge, service: LyricsService(session: transport.session))
        transport.handler = { _ in .init(data: Data(repeating: 32, count: 2_000_001)) }
        await assertError(.responseTooLarge, service: LyricsService(session: transport.session))
    }

    func testInvalidMetadataMakesNoRequests() async {
        let transport = LyricsFixtureTransport()
        let service = LyricsService(session: transport.session)
        for invalid in [Song(id: "fixture", title: " ", artist: "Artist"),
                        Song(id: "fixture", title: "Track", artist: ""),
                        Song(id: "fixture", title: String(repeating: "x", count: 513), artist: "Artist"),
                        Song(id: "fixture", title: "Track", artist: "Artist\nInjected"),
                        Song(id: "fixture", title: "Track", artist: "Artist", album: String(repeating: "x", count: 513))] {
            await assertError(.invalidMetadata, service: service, song: invalid)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testUnknownInvalidAndOutOfRangeDurationsAreOmittedAndDisambiguated() async throws {
        for duration in [0, Double.nan, Double.infinity, -1, 3601] {
            let transport = LyricsFixtureTransport()
            transport.handler = { request in
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                XCTAssertFalse(query.contains { $0.name == "duration" })
                if request.url?.path == "/api/get" { return .init(data: try self.record()) }
                return .init(data: try self.array([self.record(), self.record(text: "Alternative fixture", id: 2)]))
            }
            var unknown = song
            unknown.fields["duration"] = .number(duration)
            await assertError(.ambiguousMatch, service: LyricsService(session: transport.session), song: unknown)
            XCTAssertEqual(transport.requests.count, 2)
        }
    }

    func testTransportAndCancellationAreNotMissing() async throws {
        let transport = LyricsFixtureTransport()
        transport.handler = { _ in throw URLError(.timedOut) }
        await assertError(.transport(code: URLError.timedOut.rawValue), service: LyricsService(session: transport.session))
        transport.handler = { _ in throw URLError(.cancelled) }
        do {
            _ = try await LyricsService(session: transport.session).lookup(song: song)
            XCTFail("Cancellation must propagate")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testCancellationBeforeLookupMakesNoRequests() async {
        let transport = LyricsFixtureTransport()
        let service = LyricsService(session: transport.session)
        let lookupSong = song
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.lookup(song: lookupSong)
        }
        do { _ = try await task.value; XCTFail("Cancelled lookup must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testCancellationPreventsFallbackRequest() async {
        let requested = expectation(description: "Exact lookup requested")
        let transport = LyricsFixtureTransport()
        transport.handler = { _ in requested.fulfill(); return .init(status: 404, data: Self.missing) }
        let service = LyricsService(session: transport.session)
        let lookupSong = song
        let task = Task { try await service.lookup(song: lookupSong) }
        await fulfillment(of: [requested], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled lookup must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testNormalizationPreservesRecordingQualifiers() async throws {
        let transport = LyricsFixtureTransport()
        transport.handler = { _ in .init(data: try self.record(title: "  FIXTURE   TRACK ", artist: "fixture artist")) }
        let result = try await LyricsService(session: transport.session).lookup(song: song)
        XCTAssertEqual(result, .found("Original fixture text\n"))
    }

    func testBrowserSearchURLIsTrustedAndCannotInjectPathOrQuery() {
        let unsafe = Song(id: "fixture", title: "Track/?q=bad#fragment%20", artist: "Artist & Unicode é")
        let url = LyricsService.browserSearchURL(for: unsafe)
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "lrclib.net")
        XCTAssertNil(url.query)
        XCTAssertNil(url.fragment)
        XCTAssertNil(url.user)
        XCTAssertTrue(url.absoluteString.contains("%2F"))
        XCTAssertTrue(url.absoluteString.contains("%3F"))
        let encoded = URLComponents(url: url, resolvingAgainstBaseURL: false)!.percentEncodedPath
        XCTAssertEqual(encoded.split(separator: "/").count, 2)
        XCTAssertEqual(LyricsService.browserSearchURL(for: Song(id: "", title: "", artist: "")).absoluteString, "https://lrclib.net/")
    }
}

private struct LyricsFixtureResponse {
    var status = 200
    var mime = "application/json"
    var headers: [String: String] = [:]
    var data: Data
    var url: URL?
}

private final class LyricsFixtureTransport {
    typealias Handler = (URLRequest) throws -> LyricsFixtureResponse
    private let id = UUID().uuidString
    private let lock = NSLock()
    private var captured: [URLRequest] = []
    var handler: Handler = { _ in .init(status: 500, data: Data()) }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return captured }
    lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LyricsFixtureProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Lyrics-Fixture-ID": id]
        LyricsFixtureProtocol.register(id: id) { [weak self] request in
            guard let self else { throw URLError(.cancelled) }
            self.lock.lock()
            self.captured.append(request)
            self.lock.unlock()
            return try self.handler(request)
        }
        return URLSession(configuration: configuration)
    }()
    deinit { LyricsFixtureProtocol.unregister(id: id) }
}

private final class LyricsFixtureProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handlers: [String: LyricsFixtureTransport.Handler] = [:]
    static func register(id: String, handler: @escaping LyricsFixtureTransport.Handler) { lock.lock(); defer { lock.unlock() }; handlers[id] = handler }
    static func unregister(id: String) { lock.lock(); defer { lock.unlock() }; handlers[id] = nil }
    override class func canInit(with request: URLRequest) -> Bool { request.value(forHTTPHeaderField: "X-Lyrics-Fixture-ID") != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handlers[request.value(forHTTPHeaderField: "X-Lyrics-Fixture-ID") ?? ""]
        Self.lock.unlock()
        do {
            let fixture = try XCTUnwrap(handler)(request)
            var headers = fixture.headers
            headers["Content-Type"] = fixture.mime
            let response = HTTPURLResponse(url: fixture.url ?? request.url!, statusCode: fixture.status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: fixture.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
