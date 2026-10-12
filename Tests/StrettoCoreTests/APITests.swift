import XCTest
@testable import StrettoCore

private final class FixtureProtocol: URLProtocol {
    static var responder: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let responder = Self.responder, let url = request.url else { throw StrettoError.message("Missing fixture response.") }
            let (status, data) = try responder(request)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class APITests: XCTestCase {
    private func api(_ handler: @escaping (URLRequest) throws -> (Int, String)) -> StrettoAPI {
        FixtureProtocol.responder = { request in let (status, body) = try handler(request); return (status, Data(body.utf8)) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        return StrettoAPI(session: URLSession(configuration: config))
    }
    override func tearDown() { FixtureProtocol.responder = nil; super.tearDown() }
    func testLoginUsesOfficialEndpointAndNeverSendsPasswordInURL() async throws {
        let client = api { request in
            XCTAssertEqual(request.url?.path, "/login")
            XCTAssertNil(request.url?.query)
            XCTAssertEqual(request.httpMethod, "POST")
            return (200, #"{"success":true}"#)
        }
        try await client.login(email: "example@example.test", password: "fixture-only")
    }
    func testSession403MeansSignedOutRatherThanSuccess() async throws {
        let client = api { _ in (403, #"{"loggedIn":false}"#) }
        let email = try await client.checkLogin()
        XCTAssertNil(email)
    }
    func testHTTP200FailureIsNotTreatedAsSuccessfulSync() async throws {
        let client = api { _ in (200, #"{"success":false,"error":"version mismatch"}"#) }
        do { _ = try await client.upload(Library()); XCTFail("Should fail") }
        catch { XCTAssertEqual(error as? StrettoError, .conflict) }
    }
    func testAuthAndResetJSONFailuresSurfaceMessage() async throws {
        let client = api { _ in (403, #"{"success":false,"errorMessage":"Incorrect password"}"#) }
        do { try await client.login(email: "example@example.test", password: "fixture-only"); XCTFail("Should fail") }
        catch { XCTAssertEqual(error.localizedDescription, "Incorrect password") }
    }
    func testNativeExchangeUsesVerifierInJSONNotURL() async throws {
        let client = api { request in
            XCTAssertEqual(request.url?.path, "/native/exchange")
            XCTAssertNil(request.url?.query)
            return (200, #"{"success":true,"email":"example@example.test"}"#)
        }
        _ = try await client.exchange(code: "fixture", verifier: "fixture", state: "fixture")
    }
    func testUnexpectedHTMLConfigurationFailsExplicitly() async throws {
        let client = api { _ in (200, "<html>Not a native API</html>") }
        do { _ = try await client.configuration(); XCTFail("Should fail") } catch { XCTAssertTrue(error is DecodingError) }
    }
}
