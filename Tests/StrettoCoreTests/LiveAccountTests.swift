import XCTest
@testable import StrettoCore

final class LiveAccountTests: XCTestCase {
    func testControlledAccountLifecycleAndSync() async throws {
        guard let email = ProcessInfo.processInfo.environment["STRETTO_TEST_EMAIL"],
              let password = ProcessInfo.processInfo.environment["STRETTO_TEST_PASSWORD"] else {
            throw XCTSkip("Set disposable STRETTO_TEST_EMAIL and STRETTO_TEST_PASSWORD for opt-in production contract verification.")
        }
        let api = StrettoAPI()
        let initiallySignedIn = try await api.checkLogin()
        XCTAssertNil(initiallySignedIn)
        try await api.login(email: email, password: password, register: true)
        let authenticatedEmail = try await api.checkLogin()
        XCTAssertEqual(authenticatedEmail, email)
        let cookies = try await api.cookieData()
        let resumed = StrettoAPI()
        try await resumed.restoreCookies(cookies)
        let resumedEmail = try await resumed.checkLogin()
        XCTAssertEqual(resumedEmail, email)
        let config = try await api.configuration()
        XCTAssertFalse(config.youtubeRedirectEndpoint.isEmpty)
        let initialVersion = try await api.latestVersion()
        var library = Library(songs: [Song(id: "y_fixtureonly", title: "Native contract fixture", artist: "Test")],
                              playlists: [Playlist(title: "Native verification", songs: ["y_fixtureonly"])], version: initialVersion)
        library.version = try await api.upload(library)
        let downloaded = try await api.latestData()
        XCTAssertEqual(downloaded, library)
        var stale = library
        stale.version = initialVersion
        do { _ = try await api.upload(stale); XCTFail("A stale upload must fail.") }
        catch { XCTAssertEqual(error as? StrettoError, .conflict) }
        try await api.logout()
        let signedOut = try await api.checkLogin()
        XCTAssertNil(signedOut)
        try await api.login(email: email, password: password)
        let loggedInAgain = try await api.checkLogin()
        XCTAssertEqual(loggedInAgain, email)
        try await api.logout()
    }
}
