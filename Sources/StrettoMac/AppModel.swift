import AppKit
import Combine
import StrettoCore
import StrettoMedia

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var library = Library()
    @Published private(set) var accountEmail: String?
    @Published private(set) var syncStatus = "Local library"
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?
    @Published var conflict: SyncConflict?
    @Published private(set) var searchResults = SearchPage()
    @Published private(set) var searchBusy = false
    @Published private(set) var previewPlaylistTitle: String?
    @Published private(set) var previewSongs: [Song] = []
    @Published private(set) var artists: [Artist] = []
    @Published private(set) var followedArtistIDs: Set<Int> = []
    @Published private(set) var artistReleases: [Song] = []
    @Published private(set) var spotifyPlaylists: [SpotifyPlaylist] = []
    @Published private(set) var spotifyConnected = false
    let lyrics = LyricsLookup()
    @Published var resetToken = ""
    let sources: SourceService
    let downloads: DownloadManager
    let player: PlaybackController
    let api: StrettoAPI
    private let browser = BrowserAuthentication()
    private let spotify: SpotifyClient
    private var store: LibraryStore?
    private var state = LocalState()
    private var activeAccount = "guest"
    private var editRevision = 0
    private var syncRunning = false
    private var searchRevision = 0
    private var libraryDebounce: Task<Void, Never>?
    private var polling: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init() {
        let api = StrettoAPI()
        self.api = api
        sources = SourceService(configuration: PublicConfiguration(
            youtubeRedirectEndpoint: "https://home.kaiser.lol:59436/youtuberedirect",
            soundcloudClientId: "3c2fb8cfc81c40dcfb99bb9f786f561c",
            spotifyClientId: "ac0ebd2b08a04542a8737119ff4350ab"))
        downloads = DownloadManager(sources: sources)
        player = PlaybackController(sources: sources, downloads: downloads)
        spotify = SpotifyClient(api: api)
        do {
            guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw StrettoError.message("macOS could not locate Application Support.")
            }
            store = try LibraryStore(url: support.appendingPathComponent("StrettoNative/library.sqlite"))
            activeAccount = UserDefaults.standard.string(forKey: "lastStrettoAccount") ?? "guest"
            state = try store?.load(account: activeAccount) ?? LocalState()
            library = state.library
            try downloads.setAccount(activeAccount)
            syncStatus = activeAccount == "guest" ? "Local library · Sign in to sync" : "Cached library · Checking session"
        } catch { errorMessage = error.localizedDescription }
        player.$currentSong.dropFirst().sink { [weak self] _ in
            self?.lyrics.reset()
        }.store(in: &cancellables)
        isBusy = true
        Task { await restoreSession() }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(45)) } catch { return }
                guard let self else { return }
                if self.accountEmail != nil && !self.isBusy { await self.sync() }
            }
        }
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification).sink { [weak self] _ in
            guard let self, self.accountEmail != nil else { return }
            Task { await self.sync() }
        }.store(in: &cancellables)
    }

    private func restoreSession() async {
        defer { isBusy = false }
        do {
            if let data = try SecretStore.read("stretto.session") { try await api.restoreCookies(data) }
            if let email = try await api.checkLogin() { try await activate(email); await performSync() }
            else { syncStatus = "Not signed in · Cached changes are safe" }
        } catch { syncStatus = "Offline or signed out · Cached library available"; errorMessage = error.localizedDescription }
        do { await sources.configure(try await api.configuration()) }
        catch { errorMessage = "Could not refresh service configuration: \(error.localizedDescription). The last verified public source settings are in use." }
    }

    private func activate(_ email: String) async throws {
        guard let store else { throw StrettoError.message("The local library database is unavailable.") }
        let nextState = try store.load(account: email)
        try SecretStore.save(await api.cookieData(), account: "stretto.session")
        player.stop()
        try downloads.setAccount(email)
        spotifyConnected = try await spotify.setAccount(email)
        activeAccount = email
        accountEmail = email
        state = nextState
        library = state.library
        conflict = nil
        artists = []; artistReleases = []; followedArtistIDs = []; spotifyPlaylists = []
        searchRevision += 1; searchBusy = false; searchResults = SearchPage()
        previewSongs = []; previewPlaylistTitle = nil
        UserDefaults.standard.set(email, forKey: "lastStrettoAccount")
        syncStatus = "Signed in · Ready to sync"
    }

    func login(email: String, password: String) async { await authenticate(email: email, password: password, register: false) }
    func register(email: String, password: String) async { await authenticate(email: email, password: password, register: true) }
    private func authenticate(email: String, password: String, register: Bool) async {
        guard !isBusy && !syncRunning else { errorMessage = "Wait for the current operation to finish."; return }
        guard !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !password.isEmpty else {
            errorMessage = "Enter your email address and password."; return
        }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await api.login(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password, register: register)
            guard let verified = try await api.checkLogin() else { throw StrettoError.message("Sign-in did not establish a session.") }
            try await activate(verified)
            await performSync()
        } catch { errorMessage = error.localizedDescription }
    }
    func googleLogin() async {
        guard !isBusy && !syncRunning else { errorMessage = "Wait for the current operation to finish."; return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let callback = try await browser.signIn(baseURL: api.baseURL)
            _ = try await api.exchange(code: callback.code, verifier: callback.verifier, state: callback.state)
            guard let email = try await api.checkLogin() else { throw StrettoError.message("Google sign-in did not establish a Stretto session.") }
            try await activate(email)
            await performSync()
        } catch { errorMessage = error.localizedDescription }
    }
    func logout() async {
        guard !isBusy && !syncRunning else { errorMessage = "Wait for the current operation to finish before signing out."; return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await api.logout()
            try SecretStore.delete("stretto.session")
            player.stop()
            try downloads.setAccount("guest")
            _ = try await spotify.setAccount("guest")
            activeAccount = "guest"
            state = try store?.load(account: "guest") ?? LocalState()
            library = state.library
            accountEmail = nil; conflict = nil; spotifyConnected = false
            artists = []; artistReleases = []; followedArtistIDs = []; spotifyPlaylists = []
            searchRevision += 1; searchBusy = false; searchResults = SearchPage()
            previewSongs = []; previewPlaylistTitle = nil
            UserDefaults.standard.removeObject(forKey: "lastStrettoAccount")
            syncStatus = "Signed out · Account library safely cached"
        } catch { errorMessage = error.localizedDescription }
    }
    func forgotPassword(email: String) async {
        guard !email.isEmpty else { errorMessage = "Enter your account email."; return }
        errorMessage = nil
        do { try await api.forgotPassword(email: email); syncStatus = "Recovery requested · Check your email if this account exists" }
        catch { errorMessage = error.localizedDescription }
    }
    func completeReset(email: String, password: String, token: String) async {
        guard !email.isEmpty, !password.isEmpty, !token.isEmpty else { errorMessage = "Enter your email, new password, and reset token from the emailed link."; return }
        errorMessage = nil
        do { try await api.completeReset(email: email, password: password, token: token); syncStatus = "Password reset · Sign in with your new password"; resetToken = "" }
        catch { errorMessage = error.localizedDescription }
    }

    func sync() async {
        guard !isBusy else { return }
        await performSync()
    }
    private func performSync() async {
        guard accountEmail != nil else { syncStatus = "Sign in to sync · Local changes are safe"; return }
        guard !syncRunning else { return }
        guard conflict == nil else { syncStatus = "Review the library conflict before syncing"; return }
        syncRunning = true
        defer { syncRunning = false }
        let snapshot = state
        let account = activeAccount
        let revision = editRevision
        syncStatus = "Syncing with Stretto…"
        do {
            let result = try await SyncEngine.sync(snapshot, transport: api)
            guard activeAccount == account else { return }
            switch result {
            case .synced(let synced):
                var next = synced
                if revision != editRevision {
                    next.library = library
                    next.library.version = synced.library.version
                    next.base = synced.base
                    next.pendingChanges = Array(state.pendingChanges.dropFirst(snapshot.pendingChanges.count))
                    if next.pendingChanges.isEmpty { next.pendingChanges = ["Edits made while syncing"] }
                }
                try commit(next)
                syncStatus = next.dirty ? "New local changes · Ready to sync" : "Library up to date"
                try SecretStore.save(await api.cookieData(), account: "stretto.session")
                if next.dirty { scheduleSync() }
            case .conflict(let detected):
                conflict = SyncConflict(local: library, remote: detected.remote)
                syncStatus = "Changes in two places · Review required"
            }
        } catch {
            if error as? StrettoError == .unauthenticated { accountEmail = nil }
            syncStatus = "Sync failed · Local changes preserved"
            errorMessage = error.localizedDescription
        }
    }
    func resolveConflict(useLocal: Bool) async {
        guard let existing = conflict, !syncRunning && !isBusy else { return }
        syncRunning = true
        defer { syncRunning = false }
        let revision = editRevision
        let snapshot = state
        let choice = SyncConflict(local: library, remote: existing.remote)
        do {
            guard let store else { throw StrettoError.message("Cannot resolve without a local backup database.") }
            try store.backup(choice.local, account: activeAccount)
            try store.backup(choice.remote, account: activeAccount)
            var next = try await SyncEngine.resolve(choice, useLocal: useLocal, transport: api)
            if revision != editRevision {
                next.library = library
                next.library.version = next.base?.version ?? next.library.version
                next.pendingChanges = Array(state.pendingChanges.dropFirst(snapshot.pendingChanges.count))
                if next.pendingChanges.isEmpty { next.pendingChanges = ["Edits made during conflict resolution"] }
            }
            try commit(next)
            conflict = nil
            syncStatus = next.dirty ? "Resolution saved · New local edits pending" : "Resolution saved · Both snapshots backed up"
            if next.dirty { scheduleSync() }
        } catch StrettoError.conflict {
            do { conflict = SyncConflict(local: library, remote: try await api.latestData()) }
            catch { errorMessage = error.localizedDescription }
            syncStatus = "Server changed again · Review the latest version"
        } catch { errorMessage = error.localizedDescription }
    }
    private func commit(_ next: LocalState) throws {
        guard let store else { throw StrettoError.message("The local library database is unavailable; changes were not saved.") }
        try store.save(next, account: activeAccount)
        state = next; library = next.library
    }
    private func edit(_ description: String, _ change: (inout Library) throws -> Void) {
        do {
            var next = state
            try change(&next.library)
            next.pendingChanges.append(description)
            try commit(next)
            editRevision += 1
            syncStatus = accountEmail == nil ? "Saved locally · Sign in to sync" : "Local changes · Sync pending"
            if let existing = conflict { conflict = SyncConflict(local: library, remote: existing.remote) }
            scheduleSync()
        } catch { errorMessage = error.localizedDescription }
    }
    private func scheduleSync() {
        libraryDebounce?.cancel()
        libraryDebounce = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            await self?.sync()
        }
    }
    func add(_ song: Song, to playlist: String? = nil) {
        guard song.supported else { errorMessage = "This source cannot be added from macOS. Play a YouTube match first."; return }
        edit("Added \(song.title)") { $0.add(song, playlist: playlist) }
    }
    func createPlaylist(title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !library.playlists.contains(where: { $0.title == trimmed }) else { errorMessage = "Choose a unique, non-empty playlist name."; return }
        edit("Created playlist \(trimmed)") { $0.playlists.append(Playlist(title: trimmed)) }
    }
    func renamePlaylist(_ playlist: Playlist, to title: String) {
        guard playlist.editable else { errorMessage = "The Library playlist cannot be renamed."; return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !library.playlists.contains(where: { $0.title == trimmed && $0.title != playlist.title }) else { errorMessage = "Choose a unique, non-empty name."; return }
        edit("Renamed playlist") { data in
            guard let index = data.playlists.firstIndex(where: { $0.id == playlist.id }) else { throw StrettoError.message("Playlist no longer exists.") }
            data.playlists[index].title = trimmed
        }
    }
    func deletePlaylist(_ playlist: Playlist) {
        guard playlist.editable else { errorMessage = "The Library playlist cannot be deleted."; return }
        edit("Deleted playlist \(playlist.title)") { $0.playlists.removeAll { $0.id == playlist.id } }
    }
    func remove(_ song: Song, from playlist: Playlist? = nil) {
        edit("Removed \(song.title)") { data in
            if let playlist {
                guard let index = data.playlists.firstIndex(where: { $0.id == playlist.id }) else { throw StrettoError.message("Playlist no longer exists.") }
                data.playlists[index].songs.removeAll { $0 == song.id }
            } else {
                data.songs.removeAll { $0.id == song.id }
                for i in data.playlists.indices { data.playlists[i].songs.removeAll { $0 == song.id } }
            }
        }
    }
    func updateSong(_ song: Song, title: String, artist: String, album: String) {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { errorMessage = "A song needs a title."; return }
        edit("Updated \(song.title)") { data in
            guard let index = data.songs.firstIndex(where: { $0.id == song.id }) else { throw StrettoError.message("Song no longer exists.") }
            data.songs[index].title = title; data.songs[index].artist = artist; data.songs[index].album = album
            data.songs[index].fields["updatedAt"] = .number(Date().timeIntervalSince1970 * 1000)
        }
    }
    func reorderPlaylist(_ playlist: Playlist, from: Int, to: Int) {
        edit("Reordered \(playlist.title)") { data in
            guard let index = data.playlists.firstIndex(where: { $0.id == playlist.id }), data.playlists[index].editable else { throw StrettoError.message("Playlist cannot be reordered.") }
            var ids = data.playlists[index].songs
            guard ids.indices.contains(from), to >= 0, to <= ids.count else { throw StrettoError.message("Invalid track position.") }
            let id = ids.remove(at: from); ids.insert(id, at: min(to, ids.count)); data.playlists[index].songs = ids
        }
    }
    func search(query: String, source: String) async {
        searchRevision += 1
        let request = searchRevision
        searchBusy = true
        defer { if request == searchRevision { searchBusy = false } }
        do {
            let result: SearchPage
            if source.lowercased() == "library" {
                result = SearchPage(songs: library.songs.filter { "\($0.title) \($0.artist) \($0.album)".localizedCaseInsensitiveContains(query) })
            } else { result = try await sources.search(query: query, source: source) }
            if request == searchRevision { searchResults = result }
        } catch { if request == searchRevision { errorMessage = error.localizedDescription } }
    }
    func searchMore() async {
        guard let continuation = searchResults.continuation, !searchBusy else { return }
        searchBusy = true
        let request = searchRevision
        defer { if request == searchRevision { searchBusy = false } }
        do {
            let more = try await sources.loadMore(continuation: continuation)
            guard request == searchRevision else { return }
            searchResults.songs += more.songs.filter { song in !searchResults.songs.contains { $0.id == song.id } }
            searchResults.playlists += more.playlists.filter { playlist in !searchResults.playlists.contains { $0.id == playlist.id } }
            searchResults.continuation = more.continuation
        } catch { if request == searchRevision { errorMessage = error.localizedDescription } }
    }
    func openPlaylist(_ remote: RemotePlaylist) async { await importURL(remote.url.absoluteString) }
    func importURL(_ text: String) async {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https" else { errorMessage = "Enter a valid HTTPS YouTube or SoundCloud URL."; return }
        searchBusy = true
        defer { searchBusy = false }
        do {
            if URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "list" }) == true {
                let result = try await sources.playlist(url: url)
                previewPlaylistTitle = result.title; previewSongs = result.songs
            } else {
                let song = try await sources.song(url: url)
                previewPlaylistTitle = "Imported track"; previewSongs = [song]
            }
        } catch { errorMessage = error.localizedDescription }
    }
    func importPreview() {
        guard !previewSongs.isEmpty else { errorMessage = "Load a playlist or song first."; return }
        let title = previewPlaylistTitle ?? "Imported playlist"
        edit("Imported \(title)") { data in for song in previewSongs where song.supported { data.add(song, playlist: title) } }
    }
    func play(_ song: Song, in songs: [Song]) async {
        if song.fields["deferred"]?.bool == true {
            do {
                let result = try await sources.search(query: "\(song.artist) \(song.title) audio", source: "YouTube")
                guard var match = result.songs.first else { throw StrettoError.message("No YouTube match found for \(song.title).") }
                match.title = song.title; match.artist = song.artist; match.album = song.album
                await player.play(match, in: [match])
            } catch { errorMessage = error.localizedDescription }
        } else { await player.play(song, in: songs.filter(\.supported)) }
    }
    func download(_ song: Song) async {
        do { try await downloads.download(song) } catch { errorMessage = error.localizedDescription }
    }
    func removeDownload(_ song: Song) {
        do { try downloads.remove(song) } catch { errorMessage = error.localizedDescription }
    }
    func loadArtists() async {
        guard accountEmail != nil else { errorMessage = "Sign in to see and follow your artists."; return }
        let account = activeAccount
        do {
            let followed = try await api.artists()
            let suggestions = try await api.artists(path: "/suggest/artists")
            let value = try await api.json(path: "/artists/followed")
            guard case .array = value else { throw StrettoError.message("Artist feed returned an unsupported format.") }
            let releases = try JSONDecoder().decode([Song].self, from: JSONEncoder().encode(value))
            guard activeAccount == account else { return }
            followedArtistIDs = Set(followed.map(\.artistId))
            artists = followed + suggestions.filter { !followedArtistIDs.contains($0.artistId) }
            artistReleases = releases
        } catch { errorMessage = error.localizedDescription }
    }
    func followArtist(_ artist: Artist) async {
        guard accountEmail != nil, !isBusy else { errorMessage = "Sign in and wait for the current operation to finish."; return }
        isBusy = true
        defer { isBusy = false }
        do { try await api.follow(artist); await loadArtists() } catch { errorMessage = error.localizedDescription }
    }
    func unfollowArtist(_ artist: Artist) async {
        guard accountEmail != nil, !isBusy else { errorMessage = "Sign in and wait for the current operation to finish."; return }
        isBusy = true
        defer { isBusy = false }
        do { try await api.follow(artist, remove: true); await loadArtists() } catch { errorMessage = error.localizedDescription }
    }
    func loadLyrics() async {
        let song = player.currentSong.map { current in library.songs.first(where: { $0.id == current.id }) ?? current }
        await lyrics.load(song: song)
    }
    func connectSpotify() async {
        guard accountEmail != nil else { errorMessage = "Sign in to Stretto before connecting Spotify."; return }
        guard !isBusy else { errorMessage = "Wait for the current operation to finish."; return }
        isBusy = true
        defer { isBusy = false }
        do {
            let callback = try await browser.signIn(baseURL: api.baseURL, spotify: true)
            try await spotify.accept(api.exchange(code: callback.code, verifier: callback.verifier, state: callback.state, spotify: true))
            spotifyConnected = true
            await loadSpotifyPlaylists()
        } catch { errorMessage = error.localizedDescription }
    }
    func loadSpotifyPlaylists() async {
        let account = activeAccount
        do {
            let playlists = try await spotify.playlists()
            if activeAccount == account { spotifyPlaylists = playlists }
        } catch { if activeAccount == account { errorMessage = error.localizedDescription } }
    }
    func importSpotifyPlaylist(_ playlist: SpotifyPlaylist) async {
        guard !isBusy else { errorMessage = "Wait for the current import to finish."; return }
        isBusy = true
        defer { isBusy = false }
        do {
            let tracks = try await spotify.tracks(in: playlist)
            var failures: [String] = []
            for (index, track) in tracks.enumerated() {
                if Task.isCancelled { throw CancellationError() }
                syncStatus = "Importing Spotify: \(index + 1)/\(tracks.count)"
                do {
                    let result = try await sources.search(query: "\(track.artist) \(track.title) audio", source: "YouTube")
                    guard var match = result.songs.first else { throw StrettoError.message("No match found.") }
                    match.title = track.title; match.artist = track.artist; match.album = track.album
                    if !track.cover.isEmpty { match.cover = track.cover }
                    match.fields["spotifyId"] = .string(track.id); match.fields["explicit"] = .bool(track.explicit)
                    add(match, to: playlist.name)
                } catch {
                    failures.append(track.title)
                    if failures.count >= 5 { throw StrettoError.message("Spotify import stopped after five unmatched or failed tracks. Imported tracks are saved; retry later.") }
                }
                try await Task.sleep(for: .milliseconds(400))
            }
            syncStatus = "Spotify import finished · \(tracks.count - failures.count) of \(tracks.count) matched"
            if !failures.isEmpty { errorMessage = "Some tracks could not be matched: \(failures.joined(separator: ", ")). Imported tracks are saved." }
            await performSync()
        } catch { errorMessage = error.localizedDescription; syncStatus = "Spotify import stopped · Imported tracks preserved" }
    }
}
