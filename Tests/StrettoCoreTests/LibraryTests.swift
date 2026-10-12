import XCTest
@testable import StrettoCore

private actor FakeTransport: LibraryTransport {
    var remote: Library
    var uploads: [Library] = []
    var race = false
    init(_ remote: Library) { self.remote = remote }
    func latestVersion() -> Double { remote.version }
    func latestData() -> Library { remote }
    func upload(_ library: Library) throws -> Double {
        if race || library.version != remote.version { throw StrettoError.conflict }
        uploads.append(library)
        remote = library; remote.version += 1
        return remote.version
    }
    func uploadCount() -> Int { uploads.count }
    func introduceRace() { race = true }
}

final class LibraryTests: XCTestCase {
    func testUnknownSongFieldsAndAudiusSurviveRoundTrip() throws {
        let data = Data(#"{"songs":[{"id":"a_saved","title":"Keep me","isAudius":true,"future":{"gain":-2}},{"id":"y_abc","title":"Playable","duration":42}],"playlists":[{"title":"Library","songs":["a_saved","y_abc"],"futureFlag":true}],"version":123}"#.utf8)
        let library = try JSONDecoder().decode(Library.self, from: data)
        XCTAssertEqual(library.supportedSongs.count, 1)
        let roundtrip = try JSONDecoder().decode(Library.self, from: JSONEncoder().encode(library))
        XCTAssertEqual(roundtrip, library)
        XCTAssertEqual(roundtrip.songs[0].fields["future"], .object(["gain": .number(-2)]))
        XCTAssertEqual(roundtrip.playlists[0].fields["futureFlag"], .bool(true))
    }

    func testSQLitePersistsJournalAccountIsolationAndConflictBackups() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let song = Song(id: "y_abc", title: "Song", artist: "Artist")
        let state = LocalState(library: Library(songs: [song], version: 10), pendingChanges: ["Added song"])
        do {
            let store = try LibraryStore(url: dir.appendingPathComponent("library.sqlite"))
            try store.save(state, account: "one")
            try store.backup(state.library, account: "one")
            XCTAssertEqual(try store.load(account: "two"), LocalState())
        }
        let reopened = try LibraryStore(url: dir.appendingPathComponent("library.sqlite"))
        XCTAssertEqual(try reopened.load(account: "one"), state)
        XCTAssertEqual(try reopened.backups(account: "one"), [state.library])
    }

    func testFirstLoginDoesNotOverwriteRemoteWithEmptyLocalLibrary() async throws {
        let remote = Library(songs: [Song(id: "y_old", title: "Existing", artist: "")], version: 12)
        let transport = FakeTransport(remote)
        guard case .synced(let state) = try await SyncEngine.sync(LocalState(), transport: transport) else { return XCTFail("Unexpected conflict") }
        XCTAssertEqual(state.library, remote)
        let uploads = await transport.uploadCount()
        XCTAssertEqual(uploads, 0)
    }

    func testDirtyFirstLoginRaisesConflictAndPreservesBothLibraries() async throws {
        let remote = Library(songs: [Song(id: "y_remote", title: "Remote", artist: "")], version: 12)
        let local = Library(songs: [Song(id: "y_local", title: "Local", artist: "")])
        let transport = FakeTransport(remote)
        guard case .conflict(let conflict) = try await SyncEngine.sync(LocalState(library: local, pendingChanges: ["edit"]), transport: transport) else { return XCTFail("Expected conflict") }
        XCTAssertEqual(conflict.local, local)
        XCTAssertEqual(conflict.remote, remote)
        let uploads = await transport.uploadCount()
        XCTAssertEqual(uploads, 0)
    }

    func testVersionMatchedUploadAndExplicitConflictResolution() async throws {
        let base = Library(version: 12)
        let transport = FakeTransport(base)
        let local = Library(songs: [Song(id: "y_new", title: "New", artist: "")], version: 12)
        guard case .synced(let state) = try await SyncEngine.sync(LocalState(library: local, base: base, pendingChanges: ["edit"]), transport: transport) else { return XCTFail("Unexpected conflict") }
        XCTAssertEqual(state.library.version, 13)
        XCTAssertFalse(state.dirty)
        let conflict = SyncConflict(local: local, remote: state.library)
        let resolved = try await SyncEngine.resolve(conflict, useLocal: true, transport: transport)
        XCTAssertEqual(resolved.library.version, 14)
    }

    func testConcurrentServerChangeDoesNotForceUpload() async throws {
        let base = Library(version: 12)
        let transport = FakeTransport(base)
        await transport.introduceRace()
        guard case .conflict = try await SyncEngine.sync(LocalState(library: base, base: base, pendingChanges: ["edit"]), transport: transport) else { return XCTFail("Expected conflict") }
        let uploads = await transport.uploadCount()
        XCTAssertEqual(uploads, 0)
    }

    func testAddingAndPlaylistOrderRemainCompatible() {
        var library = Library(playlists: [Playlist(title: "Library")])
        let first = Song(id: "y_first", title: "First", artist: "")
        let second = Song(id: "s_second", title: "Second", artist: "")
        library.add(first, playlist: "Mix"); library.add(second, playlist: "Mix"); library.add(first, playlist: "Mix")
        XCTAssertEqual(library.songs.count, 2)
        XCTAssertEqual(library.playlists[0].songs, [first.id, second.id])
        XCTAssertEqual(library.songs(in: library.playlists[1]).map(\.id), [first.id, second.id])
    }
}
