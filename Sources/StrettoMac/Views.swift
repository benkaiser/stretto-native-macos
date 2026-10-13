import AppKit
import SwiftUI
import StrettoCore
import StrettoMedia

private enum Destination: Hashable {
    case library, playlist(String), search, nowPlaying, artists, downloads, spotify, account
}

private enum EditSheet: Identifiable {
    case createPlaylist
    case rename(Playlist)
    case song(Song)
    case importURL
    var id: String {
        switch self {
        case .createPlaylist: return "create"
        case .rename(let playlist): return "rename-\(playlist.id)"
        case .song(let song): return "song-\(song.id)"
        case .importURL: return "import"
        }
    }
}

struct RootView: View {
    @ObservedObject var model: AppModel
    @AppStorage("appearance") private var appearance = "light"
    @State private var destination: Destination? = .library
    @State private var editSheet: EditSheet?
    @State private var authSheet = false
    @State private var reviewingConflict = false
    @State private var libraryTab = "Playlists"
    @State private var filter = ""

    private var colorScheme: ColorScheme? {
        appearance == "system" ? nil : appearance == "dark" ? .dark : .light
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            VStack(spacing: 0) {
                if let message = model.errorMessage {
                    StatusBanner(message: message, symbol: "exclamationmark.triangle", warning: true) {
                        model.errorMessage = nil
                    }
                }
                if model.isBusy {
                    HStack(spacing: 9) {
                        ProgressView().controlSize(.small)
                        Text(model.syncStatus.isEmpty ? "Working… You can keep browsing." : model.syncStatus)
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }.padding(.horizontal, 24).padding(.vertical, 8)
                }
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                if destination != .nowPlaying {
                    PlayerStripView(model: model) { destination = .nowPlaying }
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { destination = .search } label: { Label("Search", systemImage: "magnifyingglass") }
                        .keyboardShortcut("k", modifiers: .command)
                        .help("Search your library, YouTube, and SoundCloud")
                    Menu {
                        Button("Import a URL…") { editSheet = .importURL }
                        Button("Import from Spotify") { destination = .spotify }
                        Button("New Playlist…") { editSheet = .createPlaylist }
                    } label: { Label("Add Music", systemImage: "plus") }
                    Button { Task { await model.sync() } } label: { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
                        .disabled(model.accountEmail == nil || model.isBusy)
                }
            }
        }
        .tint(StrettoBrand.readableBlue)
        .preferredColorScheme(colorScheme)
        .frame(minWidth: 850, minHeight: 590)
        .sheet(item: $editSheet) { sheet in
            switch sheet {
            case .createPlaylist:
                NamePromptView(title: "New playlist", actionTitle: "Create") { title in
                    model.createPlaylist(title: title)
                    destination = .playlist(title)
                }
            case .rename(let playlist):
                NamePromptView(title: "Rename playlist", initialValue: playlist.title, actionTitle: "Save") { title in
                    model.renamePlaylist(playlist, to: title)
                    destination = .playlist(title)
                }
            case .song(let song): SongEditorView(model: model, song: song)
            case .importURL: URLImportView(model: model)
            }
        }
        .sheet(isPresented: $authSheet) { AccountAuthView(model: model) }
        .sheet(isPresented: $reviewingConflict) { ConflictReviewView(model: model) }
        .onChange(of: model.conflict != nil) { _, exists in if exists { reviewingConflict = true } }
        .onChange(of: model.resetToken) { _, token in if !token.isEmpty { authSheet = true } }
        .onAppear {
            if model.conflict != nil { reviewingConflict = true }
            if !model.resetToken.isEmpty { authSheet = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("StrettoShowSearch"))) { _ in destination = .search }
        .onReceive(NotificationCenter.default.publisher(for: .init("StrettoShowNowPlaying"))) { _ in destination = .nowPlaying }
        .onReceive(NotificationCenter.default.publisher(for: .init("StrettoNewPlaylist"))) { _ in editSheet = .createPlaylist }
        .onReceive(NotificationCenter.default.publisher(for: .init("StrettoImportURL"))) { _ in editSheet = .importURL }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            StrettoLogo(size: 38).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 14)
            List(selection: $destination) {
                Section("Your music") {
                    Label("Library", systemImage: "square.grid.2x2").tag(Destination.library)
                    Label("Search", systemImage: "magnifyingglass").tag(Destination.search)
                    Label("Now Playing", systemImage: "waveform").tag(Destination.nowPlaying)
                    Label("Artists", systemImage: "person.2").tag(Destination.artists)
                    Label("Downloads", systemImage: "arrow.down.circle").tag(Destination.downloads)
                    Label("Spotify Import", systemImage: "square.and.arrow.down").tag(Destination.spotify)
                }
                Section {
                    ForEach(model.library.playlists.filter { $0.title != "Library" }) { playlist in
                        Label(playlist.title, systemImage: "music.note.list").tag(Destination.playlist(playlist.id))
                            .contextMenu {
                                Button("Rename…") { editSheet = .rename(playlist) }.disabled(!playlist.editable)
                                Button("Delete Playlist", role: .destructive) { model.deletePlaylist(playlist) }
                                    .disabled(!playlist.editable)
                            }
                    }
                    Button { editSheet = .createPlaylist } label: { Label("New Playlist", systemImage: "plus") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                } header: { Text("Playlists") }
            }.listStyle(.sidebar)
            Divider()
            Button { destination = .account } label: {
                HStack(spacing: 10) {
                    Image(systemName: model.accountEmail == nil ? "person.crop.circle" : "person.crop.circle.fill")
                        .font(.title2).foregroundStyle(StrettoBrand.readableBlue)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.accountEmail ?? "Your account").font(.callout.weight(.medium)).lineLimit(1)
                        Text(model.accountEmail == nil ? "Sign in to sync" : model.syncStatus)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.padding(16).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
    }

    @ViewBuilder private var detail: some View {
        switch destination ?? .library {
        case .library: library
        case .playlist(let id):
            if let playlist = model.library.playlists.first(where: { $0.id == id }) {
                PlaylistDetailView(model: model, playlist: playlist,
                                   rename: { editSheet = .rename(playlist) },
                                   editSong: { editSheet = .song($0) },
                                   deleted: { destination = .library })
            } else {
                EmptyMusicView(title: "Playlist not found", message: "This playlist may have been renamed or removed during sync.", symbol: "music.note.list")
            }
        case .search: MusicSearchView(model: model)
        case .nowPlaying: NowPlayingView(model: model)
        case .artists: ArtistsView(model: model)
        case .downloads: DownloadsView(model: model, downloads: model.downloads)
        case .spotify: SpotifyImportView(model: model)
        case .account:
            AccountSyncView(model: model, signIn: { authSheet = true }, review: { reviewingConflict = true })
        }
    }

    private var library: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeading(eyebrow: "ALL YOUR MUSIC, ONE HOME", title: "Your library",
                            subtitle: "\(model.library.songs.count) songs · \(model.library.playlists.filter { $0.title != "Library" }.count) playlists")
                HStack {
                    Picker("Library view", selection: $libraryTab) {
                        Text("Playlists").tag("Playlists")
                        Text("All songs").tag("All songs")
                        Text("Recently added").tag("Recently added")
                    }.pickerStyle(.segmented).frame(maxWidth: 370)
                    Spacer()
                    if libraryTab != "Playlists" {
                        TextField("Filter songs", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                    }
                }
                if model.library.songs.isEmpty && model.library.playlists.filter({ $0.title != "Library" }).isEmpty {
                    EmptyMusicView(title: "A little room for your soundtrack",
                                   message: "Search YouTube or SoundCloud, import a favorite link, or sign in to bring your Stretto library home.",
                                   symbol: "music.note")
                    HStack {
                        Button("Find music") { destination = .search }.buttonStyle(.borderedProminent)
                        Button("Import a URL…") { editSheet = .importURL }
                        if model.accountEmail == nil { Button("Sign in…") { authSheet = true } }
                    }.frame(maxWidth: .infinity)
                } else if libraryTab == "Playlists" {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 155, maximum: 220), spacing: 20)], alignment: .leading, spacing: 24) {
                        ForEach(model.library.playlists.filter { $0.title != "Library" }) { playlist in
                            Button { destination = .playlist(playlist.id) } label: {
                                PlaylistCardView(playlist: playlist, songs: model.library.songs(in: playlist))
                            }.buttonStyle(.plain)
                        }
                        Button { editSheet = .createPlaylist } label: {
                            VStack(spacing: 12) {
                                Image(systemName: "plus").font(.largeTitle).foregroundStyle(StrettoBrand.readableBlue)
                                    .frame(maxWidth: .infinity).frame(height: 155)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                                Text("New playlist").font(.headline)
                                Text("Make space for a mood").font(.caption).foregroundStyle(.secondary)
                            }
                        }.buttonStyle(.plain)
                    }
                    if !model.library.songs.isEmpty {
                        Text("Recently added").font(.title3.weight(.semibold)).padding(.top, 6)
                        SongListView(model: model, songs: Array(model.library.songs.suffix(6).reversed()),
                                     edit: { editSheet = .song($0) })
                    }
                } else {
                    let songs = libraryTab == "Recently added" ? Array(model.library.songs.reversed()) : model.library.songs
                    SongListView(model: model, songs: songs.filter { matches($0, filter) }, edit: { editSheet = .song($0) })
                }
            }.padding(28)
        }.navigationTitle("Library")
    }
}

private func matches(_ song: Song, _ query: String) -> Bool {
    let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty || "\(song.title) \(song.artist) \(song.album)".localizedCaseInsensitiveContains(text)
}

private func canPreview(_ song: Song) -> Bool {
    song.supported || song.fields["deferred"]?.bool == true
}

private func durationText(_ seconds: Double) -> String {
    guard seconds.isFinite && seconds > 0 else { return "0:00" }
    let total = Int(seconds)
    return "\(total / 60):\(String(format: "%02d", total % 60))"
}

struct CoverArtView: View {
    var url: URL?
    var size: CGFloat = 44
    var cornerRadius: CGFloat = 8
    var isPlaying = false

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            ZStack {
                LinearGradient(colors: [StrettoBrand.blue.opacity(0.22), Color.secondary.opacity(0.10)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note").font(.system(size: max(15, size * 0.22), weight: .light))
                    .foregroundStyle(StrettoBrand.readableBlue.opacity(0.65))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay {
            if isPlaying {
                RoundedRectangle(cornerRadius: cornerRadius).fill(.black.opacity(0.55))
                Image(systemName: "waveform").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct PageHeading: View {
    var eyebrow: String
    var title: String
    var subtitle: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(eyebrow).font(.caption2.weight(.semibold)).tracking(1.7).foregroundStyle(.secondary)
            Text(title).font(.system(size: 29, weight: .semibold, design: .default))
            if !subtitle.isEmpty { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
        }
    }
}

private struct EmptyMusicView: View {
    var title: String
    var message: String
    var symbol: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 38, weight: .light)).foregroundStyle(StrettoBrand.readableBlue)
            Text(title).font(.title3.weight(.semibold))
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 430)
        }.frame(maxWidth: .infinity).padding(.vertical, 52).padding(.horizontal, 24)
    }
}

private struct StatusBanner: View {
    var message: String
    var symbol: String
    var warning = false
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(warning ? Color.orange : StrettoBrand.readableBlue)
            Text(message).font(.callout).textSelection(.enabled)
            Spacer(minLength: 8)
            if let dismiss { Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).help("Dismiss message") }
        }.padding(12)
            .background(warning ? Color.orange.opacity(0.10) : StrettoBrand.blue.opacity(0.08))
    }
}

private struct PlaylistCardView: View {
    var playlist: Playlist
    var songs: [Song]
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            CoverArtView(url: songs.first?.coverURL, size: 155, cornerRadius: 12)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "music.note.list").padding(8).background(.regularMaterial, in: Circle()).padding(10)
                }
            Text(playlist.title).font(.headline).lineLimit(2)
            Text("\(songs.count) songs").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
}

struct SongListView: View {
    @ObservedObject var model: AppModel
    var songs: [Song]
    var playlist: Playlist?
    var canAdd = false
    var edit: ((Song) -> Void)?
    var showsChannelMetadata = false

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                VStack(spacing: 0) {
                    SongRowView(model: model, playback: model.playbackActivity, downloads: model.downloads,
                                song: song, songs: songs, index: index, playlist: playlist, canAdd: canAdd,
                                edit: edit.map { callback in { callback(song) } }, showsChannelMetadata: showsChannelMetadata)
                    if index < songs.count - 1 { Divider().padding(.leading, 62) }
                }
            }
        }
    }
}

private struct SongRowView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var playback: PlaybackActivity
    @ObservedObject var downloads: DownloadManager
    var song: Song
    var songs: [Song]
    var index: Int
    var playlist: Playlist?
    var canAdd: Bool
    var edit: (() -> Void)?
    var showsChannelMetadata: Bool
    @State private var confirmingRemoval = false
    @State private var channelSong: Song?
    private var inLibrary: Bool { model.librarySongIDs.contains(song.id) }
    private var current: Bool { playback.selection.songID == song.id }
    private func activate() {
        if current { model.player.resume() } else { Task { await model.play(song, in: songs.filter(\.supported)) } }
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: activate) {
                HStack(spacing: 12) {
                    CoverArtView(url: song.coverURL, size: 42, isPlaying: current && playback.selection.isPlaying)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 5) {
                            Text(song.title.isEmpty ? "Untitled song" : song.title).font(.callout.weight(.medium)).lineLimit(1)
                                .foregroundStyle(current ? StrettoBrand.readableBlue : Color.primary)
                            if song.explicit { Text("E").font(.system(size: 8, weight: .bold)).padding(3).background(.quaternary, in: RoundedRectangle(cornerRadius: 2)) }
                            if downloads.isPinned(song) {
                                Image(systemName: "arrow.down.circle.fill").font(.caption).foregroundStyle(StrettoBrand.readableBlue)
                                    .accessibilityLabel("Available offline")
                            }
                        }
                        Text(showsChannelMetadata ? [song.youtubeViews, song.youtubePublished].filter { !$0.isEmpty }.joined(separator: " · ") :
                             song.artist.isEmpty ? "Unknown artist" : song.artist)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Text(song.album).font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 140, alignment: .leading)
                    Text(song.source).font(.caption2).foregroundStyle(.secondary).frame(width: 72)
                    Text(song.duration > 0 ? durationText(song.duration) : "—").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 42)
                }
                .contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!canPreview(song))
                .help(canPreview(song) ? "Play \(song.title)" : "This source is not supported on Mac")
                .accessibilityLabel("Play \(song.title) by \(song.artist)")
                .accessibilityValue(current && playback.selection.isPlaying ? "Playing" : "")
            if canAdd {
                Button { model.add(song) } label: {
                    Image(systemName: inLibrary ? "checkmark" : "plus")
                }.disabled(inLibrary || !song.supported)
                    .help(inLibrary ? "Already in your library" : song.supported ? "Add to library" : "Play this release to find a YouTube match, then add it from Now Playing")
            }
            DeferredMenuButton(label: "Actions for \(song.title)", makeMenu: actionMenu)
                .frame(width: 24, height: 22)
        }
        .padding(.horizontal, 8).padding(.vertical, 10)
        .background(current ? StrettoBrand.blue.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        .contextMenu {
            Button("Play", action: activate).disabled(!canPreview(song))
            Button(inLibrary ? "In Library" : "Add to Library") { model.add(song) }.disabled(inLibrary || !song.supported)
            if let edit { Button("Edit Details…", action: edit) }
            if song.id.hasPrefix("y_") && !showsChannelMetadata {
                Button("View YouTube Channel") { channelSong = song }
            }
        }
        .sheet(item: $channelSong) { YouTubeChannelView(model: model, song: $0) }
        .confirmationDialog("Remove “\(song.title)” from your library?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove Song", role: .destructive) { model.remove(song) }
        } message: { Text("This also removes the song from your playlists. The original source is not changed.") }
    }

    private func actionMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addAction("Play", enabled: canPreview(song), action: activate)
        if !inLibrary { menu.addAction("Add to Library", enabled: song.supported) { model.add(song) } }
        let playlists = model.library.playlists.filter(\.editable)
        let destinations = NSMenu()
        for destination in playlists {
            destinations.addAction(destination.title) { model.add(song, to: destination.title) }
        }
        let playlistItem = NSMenuItem(title: "Add to Playlist", action: nil, keyEquivalent: "")
        playlistItem.submenu = destinations
        playlistItem.isEnabled = song.supported && !playlists.isEmpty
        menu.addItem(playlistItem)
        if !downloads.isPinned(song) {
            menu.addAction("Download for Offline", enabled: song.supported) { Task { await model.download(song) } }
        } else { menu.addAction("Remove Download") { model.removeDownload(song) } }
        if downloads.localURL(for: song) != nil && !downloads.isPinned(song) {
            menu.addAction("Remove Playback Cache") { model.removeDownload(song) }
        }
        if let url = URL(string: song.url), ["http", "https"].contains(url.scheme ?? "") {
            menu.addAction("Open Original") { NSWorkspace.shared.open(url) }
        }
        if song.id.hasPrefix("y_") && !showsChannelMetadata {
            menu.addAction("View YouTube Channel") { channelSong = song }
        }
        if let edit { menu.addItem(.separator()); menu.addAction("Edit Details…", action: edit) }
        if let playlist, playlist.editable {
            menu.addItem(.separator())
            menu.addAction("Move Up", enabled: index > 0) { model.reorderPlaylist(playlist, from: index, to: index - 1) }
            menu.addAction("Move Down", enabled: index < songs.count - 1) { model.reorderPlaylist(playlist, from: index, to: index + 1) }
            menu.addAction("Remove from Playlist") { model.remove(song, from: playlist) }
        } else if inLibrary && !canAdd {
            menu.addItem(.separator())
            menu.addAction("Remove from Library…") { confirmingRemoval = true }
        }
        return menu
    }
}

private struct YouTubeChannelView: View {
    @ObservedObject var model: AppModel
    @StateObject private var browser: YouTubeChannelBrowser
    @Environment(\.dismiss) private var dismiss
    @State private var retry = UUID()

    init(model: AppModel, song: Song) {
        self.model = model
        _browser = StateObject(wrappedValue: YouTubeChannelBrowser(sources: model.sources, song: song))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                CoverArtView(url: browser.channel.flatMap { URL(string: $0.avatar) }, size: 64, cornerRadius: 32)
                VStack(alignment: .leading, spacing: 5) {
                    Text(browser.channel?.title ?? "YouTube channel").font(.title2.weight(.semibold))
                    Text("Public video uploads · Listen, discover, and keep your favorites.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let channel = browser.channel {
                    Button { NSWorkspace.shared.open(channel.url) } label: { Label("YouTube", systemImage: "arrow.up.right") }
                        .help("Open the channel on YouTube")
                }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(22)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Picker("Sort channel videos", selection: $browser.sort) {
                            ForEach(YouTubeChannelSort.allCases) { sort in
                                Text(sort.title).tag(sort).disabled(!browser.availableSorts.contains(sort))
                            }
                        }.pickerStyle(.segmented).frame(maxWidth: 370)
                        Spacer()
                        if let page = browser.page {
                            Text("\(page.songs.count) videos loaded").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let error = browser.errorMessage {
                        StatusBanner(message: error, symbol: "exclamationmark.triangle", warning: true)
                        if browser.page == nil { Button("Retry") { retry = UUID() } }
                    }
                    if browser.isLoading {
                        ProgressView("Loading channel videos…").frame(maxWidth: .infinity).padding(50)
                    } else if let page = browser.page {
                        if page.songs.isEmpty {
                            EmptyMusicView(title: "No public video uploads", message: "This channel has no available videos in its Videos tab.", symbol: "play.rectangle")
                        } else {
                            SongListView(model: model, songs: page.songs, canAdd: true, showsChannelMetadata: true)
                        }
                        if page.continuation != nil {
                            HStack(spacing: 12) {
                                if browser.isLoadingMore { ProgressView().controlSize(.small) }
                                Button(browser.errorMessage == nil ? "Load More" : "Retry Load More") { browser.loadMore() }
                                    .disabled(browser.isLoadingMore)
                            }.frame(maxWidth: .infinity)
                        } else if !page.songs.isEmpty {
                            Text("All available Videos-tab uploads are loaded.").font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    Text("Order comes from YouTube across the entire channel. Dates are upload dates; Shorts and live streams have separate tabs on YouTube.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(22)
            }.id(browser.sort)
            PlayerStripView(model: model) {
                dismiss()
                NotificationCenter.default.post(name: .init("StrettoShowNowPlaying"), object: nil)
            }
        }
        .frame(width: 860, height: 650)
        .task(id: "\(browser.sort.rawValue)-\(retry)") { await browser.load() }
        .onDisappear { browser.cancel() }
        .onChange(of: model.accountEmail) { _, _ in dismiss() }
    }
}

private struct PlaylistDetailView: View {
    @ObservedObject var model: AppModel
    var playlist: Playlist
    var rename: () -> Void
    var editSong: (Song) -> Void
    var deleted: () -> Void
    @State private var confirmingDelete = false
    private var songs: [Song] { model.library.songs(in: playlist) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 24) {
                    CoverArtView(url: songs.first?.coverURL, size: 148, cornerRadius: 13)
                    VStack(alignment: .leading, spacing: 14) {
                        PageHeading(eyebrow: "YOUR PLAYLIST", title: playlist.title,
                                    subtitle: "\(songs.count) songs · \(durationText(songs.reduce(0) { $0 + $1.duration })) total")
                        HStack(spacing: 10) {
                            Button { if let song = songs.first(where: \.supported) { Task { await model.play(song, in: songs.filter(\.supported)) } } }
                            label: { Label("Play", systemImage: "play.fill") }.buttonStyle(.borderedProminent).disabled(!songs.contains(where: \.supported))
                            Button {
                                model.player.shuffle = true
                                if let song = songs.filter(\.supported).randomElement() { Task { await model.play(song, in: songs.filter(\.supported)) } }
                            } label: { Label("Shuffle", systemImage: "shuffle") }.disabled(!songs.contains(where: \.supported))
                            Button {
                                Task { for song in songs where song.supported { await model.download(song) } }
                            } label: { Label("Download", systemImage: "arrow.down") }.disabled(!songs.contains(where: \.supported))
                        }
                    }
                    Spacer(minLength: 0)
                    Menu {
                        Button("Rename…", action: rename)
                        Button("Delete Playlist…", role: .destructive) { confirmingDelete = true }
                    } label: { Image(systemName: "ellipsis") }.fixedSize().disabled(!playlist.editable)
                }
                if songs.contains(where: { !$0.supported }) {
                    StatusBanner(message: "Some tracks use a source unavailable on Mac. They stay in your library and sync safely, but cannot be played here.", symbol: "info.circle")
                }
                if songs.isEmpty {
                    EmptyMusicView(title: "The beginning of a good mix", message: "Use a song’s action menu to add music to this playlist.", symbol: "music.note.list")
                } else {
                    SongListView(model: model, songs: songs, playlist: playlist, edit: editSong)
                }
            }.padding(28)
        }.navigationTitle(playlist.title)
            .confirmationDialog("Delete “\(playlist.title)”?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete Playlist", role: .destructive) { model.deletePlaylist(playlist); deleted() }
            } message: { Text("Your songs remain in the library.") }
    }
}

private struct MusicSearchView: View {
    @ObservedObject var model: AppModel
    @State private var query = ""
    @State private var source = "Library"
    @State private var submitted = false
    @State private var preview = false
    @State private var importURL = false
    @FocusState private var searchFocused: Bool

    private var localSongs: [Song] { model.library.songs.filter { matches($0, query) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeading(eyebrow: "FIND IT. BRING IT WITH YOU.", title: "Search your next favorite",
                            subtitle: "Your library, YouTube songs and playlists, and SoundCloud.")
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Songs, artists, albums, playlists", text: $query)
                        .textFieldStyle(.plain).focused($searchFocused).onSubmit(runSearch)
                    if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).help("Clear search") }
                    if source != "Library" {
                        Button("Search", action: runSearch).disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.searchBusy)
                    }
                }.padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
                Picker("Search source", selection: $source) {
                    Text("Your library").tag("Library")
                    Text("YouTube").tag("YouTube")
                    Text("SoundCloud").tag("SoundCloud")
                }.pickerStyle(.segmented).frame(maxWidth: 440)
                    .onChange(of: source) { _, _ in submitted = false }
                if source == "Library" {
                    if localSongs.isEmpty {
                        EmptyMusicView(title: query.isEmpty ? "Your library is ready for music" : "No matching songs",
                                       message: "Try searching YouTube or SoundCloud to discover music and add it to your library.", symbol: "magnifyingglass")
                    } else { SongListView(model: model, songs: localSongs) }
                } else {
                    if model.searchBusy { HStack { ProgressView().controlSize(.small); Text("Searching \(source)…").foregroundStyle(.secondary) } }
                    if submitted {
                        if !model.searchResults.playlists.isEmpty {
                            Text("Playlists").font(.title3.weight(.semibold))
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 165, maximum: 215), spacing: 20)], alignment: .leading, spacing: 22) {
                                ForEach(model.searchResults.playlists) { playlist in
                                    Button {
                                        preview = true
                                        Task { await model.openPlaylist(playlist) }
                                    } label: {
                                        VStack(alignment: .leading, spacing: 8) {
                                            CoverArtView(url: URL(string: playlist.cover), size: 155, cornerRadius: 12)
                                            Text(playlist.title).font(.headline).lineLimit(2)
                                            Label("Preview playlist", systemImage: "play.rectangle").font(.caption).foregroundStyle(.secondary)
                                        }.contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                        if !model.searchResults.songs.isEmpty {
                            Text("Songs").font(.title3.weight(.semibold))
                            SongListView(model: model, songs: model.searchResults.songs, canAdd: true)
                        }
                        if model.searchResults.songs.isEmpty && model.searchResults.playlists.isEmpty && !model.searchBusy {
                            EmptyMusicView(title: "No results this time", message: "Try a different title or artist. Source availability can change.", symbol: "magnifyingglass")
                        }
                        if model.searchResults.continuation != nil {
                            Button("Load More") { Task { await model.searchMore() } }.disabled(model.searchBusy).frame(maxWidth: .infinity)
                        }
                    } else if !model.searchBusy {
                        EmptyMusicView(title: source == "YouTube" ? "Songs and whole soundtracks" : "Find a different sound",
                                       message: "Search \(source), preview without adding, then keep the songs you love.", symbol: "play.rectangle")
                    }
                }
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Already have a favorite link?").font(.headline)
                        Text("Import a YouTube song or playlist, or a SoundCloud track.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Import URL…") { importURL = true }
                }.padding(18).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            }.padding(28)
        }.navigationTitle("Search")
            .onAppear { searchFocused = true }
            .sheet(isPresented: $preview) { RemotePlaylistPreviewView(model: model) }
            .sheet(isPresented: $importURL) { URLImportView(model: model) }
    }

    private func runSearch() {
        guard source != "Library", !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        submitted = true
        Task { await model.search(query: query, source: source == "YouTube" ? "youtube" : "soundcloud") }
    }
}

private struct RemotePlaylistPreviewView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.searchBusy ? "Loading playlist…" : model.previewPlaylistTitle ?? "Playlist preview").font(.title2.weight(.semibold))
                    Text("Listen without adding. Keep individual songs or import the whole playlist.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(22)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if model.searchBusy {
                        ProgressView("Loading playlist…").frame(maxWidth: .infinity).padding(50)
                    } else if model.previewSongs.isEmpty {
                        EmptyMusicView(title: "No playable tracks found", message: model.errorMessage ?? "This playlist may be private or unavailable.", symbol: "music.note.list")
                    } else {
                        HStack {
                            Button {
                                if let song = model.previewSongs.first(where: \.supported) {
                                    Task { await model.play(song, in: model.previewSongs.filter(\.supported)) }
                                }
                            } label: { Label("Play Preview", systemImage: "play.fill") }.buttonStyle(.borderedProminent)
                            Spacer()
                            Text("\(model.previewSongs.count) songs").font(.caption).foregroundStyle(.secondary)
                            Button("Add Playlist to Library") { model.importPreview() }
                        }
                        SongListView(model: model, songs: model.previewSongs, canAdd: true)
                    }
                }.padding(22)
            }
        }.frame(width: 790, height: 590)
    }
}

private struct PlayerStripView: View {
    @ObservedObject var model: AppModel
    var expand: () -> Void
    var body: some View { PlayerStripContentView(player: model.player, expand: expand) }
}

private struct PlayerStripContentView: View {
    @ObservedObject var player: PlaybackController
    var expand: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 22) {
                Button(action: expand) {
                    HStack(spacing: 11) {
                        CoverArtView(url: player.currentSong?.coverURL, size: 48)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(player.currentSong?.title ?? "Ready when you are").font(.callout.weight(.medium)).lineLimit(1)
                            Text(player.currentSong?.artist ?? "Choose a song to begin").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).frame(maxWidth: 290).help("Open Now Playing")
                VStack(spacing: 3) {
                    TransportView(player: player, compact: true)
                    SeekBarView(player: player, showsTimes: false)
                }.frame(maxWidth: 390)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Image(systemName: player.volume == 0 ? "speaker.slash" : "speaker.wave.2").foregroundStyle(.secondary)
                    Slider(value: $player.volume, in: 0...1).frame(width: 85).accessibilityLabel("Volume")
                }
                Button(action: expand) { Image(systemName: "list.bullet") }.buttonStyle(.plain).help("Show queue and lyrics")
            }.padding(.horizontal, 22).padding(.vertical, 12)
            if let error = player.errorMessage {
                StatusBanner(message: error, symbol: "exclamationmark.triangle", warning: true) { player.clearError() }
            }
        }.background(.bar)
    }
}

private struct TransportView: View {
    @ObservedObject var player: PlaybackController
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 17 : 24) {
            Button { player.shuffle.toggle() } label: {
                Image(systemName: "shuffle").foregroundStyle(player.shuffle ? StrettoBrand.readableBlue : Color.secondary)
            }.help(player.shuffle ? "Turn shuffle off" : "Turn shuffle on").accessibilityLabel("Shuffle").accessibilityValue(player.shuffle ? "On" : "Off")
            Button { player.previous() } label: { Image(systemName: "backward.end.fill") }.help("Previous track")
            Button { player.toggle() } label: {
                ZStack {
                    Circle().fill(StrettoBrand.blue)
                    if player.isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").foregroundStyle(Color(red: 0.03, green: 0.13, blue: 0.20))
                    }
                }.frame(width: compact ? 30 : 46, height: compact ? 30 : 46)
            }.help(player.isPlaying ? "Pause" : "Play").accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Button { player.next() } label: { Image(systemName: "forward.end.fill") }.help("Next track")
            Button {
                player.repeatMode = player.repeatMode == "off" ? "all" : player.repeatMode == "all" ? "one" : "off"
            } label: {
                Image(systemName: player.repeatMode == "one" ? "repeat.1" : "repeat")
                    .foregroundStyle(player.repeatMode == "off" ? Color.secondary : StrettoBrand.readableBlue)
            }.help("Repeat: \(player.repeatMode)").accessibilityLabel("Repeat").accessibilityValue(player.repeatMode)
        }.buttonStyle(.plain).font(.system(size: compact ? 13 : 18))
            .disabled(player.currentSong == nil)
    }
}

private struct SeekBarView: View {
    @ObservedObject var player: PlaybackController
    var showsTimes = true
    @State private var scrubbing = false
    @State private var scrubPosition = 0.0
    private var total: Double { max(1, player.duration.isFinite ? player.duration : 1) }
    var body: some View {
        VStack(spacing: 4) {
            Slider(value: Binding(
                get: { scrubbing ? scrubPosition : min(total, max(0, player.position)) },
                set: { scrubPosition = $0; scrubbing = true }
            ), in: 0...total, onEditingChanged: { editing in
                if editing { scrubPosition = player.position; scrubbing = true }
                else { player.seek(to: scrubPosition); scrubbing = false }
            }).accessibilityLabel("Playback position")
                .disabled(player.currentSong == nil || player.duration <= 0)
            if showsTimes {
                HStack {
                    Text(durationText(scrubbing ? scrubPosition : player.position))
                    Spacer()
                    Text(durationText(player.duration))
                }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}

private struct NowPlayingView: View {
    @ObservedObject var model: AppModel
    var body: some View { NowPlayingContentView(model: model, player: model.player, downloads: model.downloads) }
}

private struct NowPlayingContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var player: PlaybackController
    @ObservedObject var downloads: DownloadManager
    @State private var sideTab = "Queue"
    @State private var channelSong: Song?
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                HStack(alignment: .top, spacing: 32) {
                    VStack(spacing: 20) {
                        Text("NOW PLAYING").font(.caption2.weight(.semibold)).tracking(2).foregroundStyle(.secondary)
                        CoverArtView(url: player.currentSong?.coverURL, size: min(330, max(200, geometry.size.width * 0.42)), cornerRadius: 18)
                            .shadow(color: .black.opacity(0.12), radius: 20, y: 9)
                        VStack(spacing: 7) {
                            Text(player.currentSong?.title ?? "A moment for your music").font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                            Text(player.currentSong.map { [$0.artist, $0.album].filter { !$0.isEmpty }.joined(separator: " · ") } ?? "Choose a song from your library or search.")
                                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        TransportView(player: player)
                        SeekBarView(player: player)
                        HStack {
                            Image(systemName: "speaker.wave.1").foregroundStyle(.secondary)
                            Slider(value: $player.volume, in: 0...1).accessibilityLabel("Volume")
                            Image(systemName: "speaker.wave.3").foregroundStyle(.secondary)
                        }.frame(maxWidth: 220)
                        if let song = player.currentSong {
                            HStack {
                                if !model.library.songs.contains(where: { $0.id == song.id }) {
                                    Button { model.add(song) } label: { Label("Add to Library", systemImage: "plus") }
                                }
                                if song.id.hasPrefix("y_") {
                                    Button { channelSong = song } label: { Label("View YouTube Channel", systemImage: "play.rectangle") }
                                }
                                Button { Task { await model.download(song) } } label: {
                                    Label(downloads.isPinned(song) ? "Downloaded" : "Keep Offline", systemImage: "arrow.down")
                                }.disabled(!song.supported || downloads.isPinned(song))
                            }
                        }
                        if let error = player.errorMessage {
                            StatusBanner(message: error, symbol: "exclamationmark.triangle", warning: true)
                        }
                    }.frame(maxWidth: .infinity).padding(.vertical, 14)
                    VStack(alignment: .leading, spacing: 20) {
                        Picker("Listening panel", selection: $sideTab) {
                            Text("Queue").tag("Queue")
                            Text("Lyrics").tag("Lyrics")
                        }.pickerStyle(.segmented)
                            .onChange(of: sideTab) { _, tab in if tab == "Lyrics" { Task { await model.loadLyrics() } } }
                        if sideTab == "Queue" {
                            Text("Keep the moment going").font(.title3.weight(.semibold))
                            if player.queue.isEmpty {
                                Text("Play a playlist or song collection to build your queue.").font(.callout).foregroundStyle(.secondary)
                            } else {
                                PlaybackQueueView(songs: player.queue, currentSongID: player.currentSong?.id, isPlaying: player.isPlaying) { song in
                                        if player.currentSong?.id == song.id { player.resume() }
                                        else { Task { await model.play(song, in: player.queue) } }
                                } browseChannel: { channelSong = $0 }
                                    .frame(height: max(260, geometry.size.height - 155))
                            }
                        } else {
                            LyricsPanelView(lookup: model.lyrics, hasSong: player.currentSong != nil) {
                                Task { await model.loadLyrics() }
                            }
                        }
                    }.frame(width: max(230, geometry.size.width * 0.36), alignment: .leading)
                        .padding(20).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
                }.padding(28)
            }
        }.navigationTitle("Now Playing")
            .sheet(item: $channelSong) { YouTubeChannelView(model: model, song: $0) }
            .onChange(of: player.currentSong?.id) { _, _ in if sideTab == "Lyrics" { Task { await model.loadLyrics() } } }
    }
}

private struct LyricsPanelView: View {
    @ObservedObject var lookup: LyricsLookup
    var hasSong: Bool
    var reload: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Lyrics").font(.title3.weight(.semibold))
                Spacer()
                Button(action: reload) { Image(systemName: "arrow.clockwise") }
                    .disabled(lookup.isLoading || !hasSong).help("Reload lyrics")
            }
            if lookup.isLoading {
                ProgressView("Finding lyrics…")
            } else if let error = lookup.errorMessage {
                StatusBanner(message: error, symbol: "exclamationmark.triangle", warning: true)
            } else if lookup.text.isEmpty {
                Text("Lyrics aren’t available for every song. Try reloading, or enjoy the music.").foregroundStyle(.secondary)
            } else {
                Text(lookup.text).font(.system(size: 18)).lineSpacing(9).textSelection(.enabled)
            }
            if let url = lookup.browserURL {
                Button { NSWorkspace.shared.open(url) } label: { Label("Search LRCLIB in Browser", systemImage: "arrow.up.right") }
                    .help("Search manually or inspect LRCLIB's availability in your browser")
            }
        }
    }
}

struct PlaybackQueueView: View {
    var songs: [Song]
    var currentSongID: String?
    var isPlaying: Bool
    var play: (Song) -> Void
    var browseChannel: (Song) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(Array(songs.enumerated()), id: \.offset) { _, song in
                    Button { play(song) } label: {
                        HStack(spacing: 11) {
                            CoverArtView(url: song.coverURL, size: 42, isPlaying: currentSongID == song.id && isPlaying)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(song.title).font(.callout.weight(.medium)).lineLimit(2)
                                Text(song.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                        }.padding(8).contentShape(Rectangle())
                            .background(currentSongID == song.id ? StrettoBrand.blue.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).disabled(!song.supported)
                        .contextMenu {
                            if song.id.hasPrefix("y_") {
                                Button("View YouTube Channel") { browseChannel(song) }
                            }
                        }
                }
            }
        }.accessibilityLabel("Playback queue")
    }
}

struct MiniPlayerView: View {
    @ObservedObject var model: AppModel
    @AppStorage("appearance") private var appearance = "light"
    var body: some View {
        MiniPlayerContentView(player: model.player)
            .tint(StrettoBrand.readableBlue)
            .preferredColorScheme(appearance == "system" ? nil : appearance == "dark" ? .dark : .light)
    }
}

private struct MiniPlayerContentView: View {
    @ObservedObject var player: PlaybackController
    var body: some View {
        VStack(spacing: 17) {
            HStack {
                StrettoLogo(size: 25)
                Spacer()
                Button {
                    NotificationCenter.default.post(name: .init("StrettoShowNowPlaying"), object: nil)
                    NSApp.activate(ignoringOtherApps: true)
                } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.buttonStyle(.plain).help("Open Now Playing")
            }
            CoverArtView(url: player.currentSong?.coverURL, size: 238, cornerRadius: 12)
            VStack(spacing: 5) {
                Text(player.currentSong?.title ?? "Ready when you are").font(.headline).lineLimit(2)
                Text(player.currentSong?.artist ?? "Choose a song in Stretto").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity)
            TransportView(player: player)
            SeekBarView(player: player)
            if let error = player.errorMessage { Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
        }.padding(22).frame(width: 282).background(.regularMaterial)
    }
}

struct MenuBarPlayerView: View {
    @ObservedObject var model: AppModel
    var body: some View { MenuBarPlayerContentView(player: model.player) }
}

private struct MenuBarPlayerContentView: View {
    @ObservedObject var player: PlaybackController
    var body: some View {
        VStack(spacing: 15) {
            HStack(spacing: 12) {
                CoverArtView(url: player.currentSong?.coverURL, size: 56)
                VStack(alignment: .leading, spacing: 5) {
                    Text(player.currentSong?.title ?? "Stretto").font(.headline).lineLimit(2)
                    Text(player.currentSong?.artist ?? "Your music is a click away").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            TransportView(player: player)
            SeekBarView(player: player)
            HStack {
                Image(systemName: "speaker.wave.2")
                Slider(value: $player.volume, in: 0...1).accessibilityLabel("Volume")
            }
            Divider()
            Button("Open Stretto") {
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .init("StrettoShowNowPlaying"), object: nil)
            }
        }.padding(18).frame(width: 305).tint(StrettoBrand.readableBlue)
    }
}

private struct ArtistsView: View {
    @ObservedObject var model: AppModel
    @State private var artistName = ""
    @State private var artistID = ""
    @State private var followSheet = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    PageHeading(eyebrow: "THE PEOPLE BEHIND YOUR SOUND", title: "Stay close to the music",
                                subtitle: "Followed artists and their latest releases.")
                    Spacer()
                    Button("Follow Artist…") { followSheet = true }.disabled(model.accountEmail == nil)
                    Button { Task { await model.loadArtists() } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh artists")
                        .disabled(model.accountEmail == nil || model.isBusy)
                }
                if model.accountEmail == nil {
                    EmptyMusicView(title: "Your artists, with your account", message: "Sign in from Your Account to load followed artists and new releases.", symbol: "person.2")
                } else if model.artists.isEmpty {
                    EmptyMusicView(title: "A little less algorithm", message: "Follow an artist using their Apple Music / iTunes artist ID to start your release feed.", symbol: "person.2")
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 18)], spacing: 24) {
                        ForEach(model.artists) { artist in
                            VStack(spacing: 10) {
                                CoverArtView(url: artist.artistCover.flatMap(URL.init(string:)), size: 100, cornerRadius: 50)
                                Text(artist.artistName).font(.headline).lineLimit(2)
                                Button(model.followedArtistIDs.contains(artist.artistId) ? "Following · Unfollow" : "Follow") {
                                    Task {
                                        if model.followedArtistIDs.contains(artist.artistId) { await model.unfollowArtist(artist) }
                                        else { await model.followArtist(artist) }
                                    }
                                }.controlSize(.small)
                                .accessibilityLabel(model.followedArtistIDs.contains(artist.artistId) ? "Unfollow \(artist.artistName)" : "Follow \(artist.artistName)")
                            }.padding(14).frame(maxWidth: .infinity)
                                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                if !model.artistReleases.isEmpty {
                    Text("New releases").font(.title3.weight(.semibold))
                    Text("Preview a release to find its YouTube match. Add the match from Now Playing.").font(.caption).foregroundStyle(.secondary)
                    SongListView(model: model, songs: model.artistReleases, canAdd: true)
                }
            }.padding(28)
        }.navigationTitle("Artists").task { if model.accountEmail != nil { await model.loadArtists() } }
            .sheet(isPresented: $followSheet) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Follow an artist").font(.title2.weight(.semibold))
                    Text("Use the numeric artist ID in an Apple Music or iTunes artist link. Your follows are shared with Stretto web.")
                        .font(.callout).foregroundStyle(.secondary)
                    TextField("Artist name", text: $artistName).textFieldStyle(.roundedBorder)
                    TextField("Apple Music / iTunes artist ID", text: $artistID).textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Cancel") { followSheet = false }.keyboardShortcut(.cancelAction)
                        Spacer()
                        Button("Follow") {
                            guard let id = Int(artistID.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
                            Task { await model.followArtist(Artist(artistId: id, artistName: artistName.trimmingCharacters(in: .whitespacesAndNewlines))) }
                            followSheet = false
                        }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                            .disabled(Int(artistID) == nil || artistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.padding(26).frame(width: 430)
            }
    }
}

private struct DownloadsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var downloads: DownloadManager
    @ObservedObject private var player: PlaybackController
    @State private var filter = ""
    @State private var channelSong: Song?
    init(model: AppModel, downloads: DownloadManager) {
        self.model = model
        self.downloads = downloads
        self.player = model.player
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeading(eyebrow: "GOOD MUSIC. BAD RECEPTION.", title: "Take the music with you",
                            subtitle: "Pinned downloads and completed-listen caches, stored separately from your browser.")
                HStack(spacing: 16) {
                    Image(systemName: "internaldrive").font(.largeTitle).foregroundStyle(StrettoBrand.readableBlue)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(ByteCountFormatter.string(fromByteCount: downloads.totalBytes, countStyle: .file)).font(.title2.weight(.semibold))
                        Text("\(downloads.entries.count) tracks · Stored on this Mac").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if downloads.isDownloading {
                        ProgressView().controlSize(.small)
                        Text("Downloading").font(.callout).foregroundStyle(.secondary)
                        Button("Cancel") { downloads.cancel() }
                    }
                }.padding(20).background(StrettoBrand.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                if let error = downloads.errorMessage {
                    StatusBanner(message: error, symbol: "exclamationmark.triangle", warning: true) { downloads.clearError() }
                }
                if downloads.entries.isEmpty {
                    EmptyMusicView(title: "Room for the road", message: "Download a song from its action menu, or download a playlist. Your library remains available even without a connection.", symbol: "arrow.down.circle")
                } else {
                    TextField("Filter downloads", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                    LazyVStack(spacing: 0) {
                        ForEach(downloads.entries.filter { matches($0.song, filter) }) { entry in
                            HStack(spacing: 14) {
                                Button {
                                    if player.currentSong?.id == entry.song.id { player.resume() }
                                    else { Task { await model.play(entry.song, in: downloads.entries.map(\.song).filter(\.supported)) } }
                                } label: {
                                    HStack(spacing: 14) {
                                        CoverArtView(url: entry.song.coverURL, size: 48, isPlaying: player.currentSong?.id == entry.song.id && player.isPlaying)
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(entry.song.title).font(.callout.weight(.medium))
                                            Text(entry.song.artist).font(.caption).foregroundStyle(.secondary)
                                            HStack {
                                                Text(entry.status == "available" ? (entry.isPinned ? "Downloaded" : "Playback cache") : entry.status)
                                                    .font(.caption).foregroundStyle(.secondary)
                                                if entry.bytes > 0 { Text("· \(ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file))").font(.caption).foregroundStyle(.secondary) }
                                            }
                                            if entry.progress > 0 && entry.progress < 1 { ProgressView(value: entry.progress).frame(maxWidth: 240) }
                                        }
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled(!entry.song.supported)
                                    .help("Play \(entry.song.title)").accessibilityLabel("Play \(entry.song.title)")
                                if downloads.localURL(for: entry.song) == nil {
                                    Button("Retry") { Task { await model.download(entry.song) } }.disabled(downloads.isDownloading)
                                } else if !entry.isPinned {
                                    Button("Keep Offline") { Task { await model.download(entry.song) } }
                                }
                                if entry.song.id.hasPrefix("y_") {
                                    Menu {
                                        Button("View YouTube Channel") { channelSong = entry.song }
                                    } label: { Image(systemName: "ellipsis") }
                                        .menuStyle(.borderlessButton).fixedSize().help("Actions for \(entry.song.title)")
                                }
                                Button { model.removeDownload(entry.song) } label: { Image(systemName: "trash") }
                                    .disabled(entry.status == "downloading").help("Remove download")
                            }.padding(.vertical, 13)
                            Divider()
                        }
                    }
                }
            }.padding(28)
        }.navigationTitle("Downloads")
            .sheet(item: $channelSong) { YouTubeChannelView(model: model, song: $0) }
    }
}

private struct SpotifyImportView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeading(eyebrow: "BRING YOUR FAVORITE MIXES", title: "Spotify import",
                            subtitle: "Import playlists by matching their tracks on YouTube. Spotify itself is not a playback source.")
                if !model.spotifyConnected {
                    VStack(alignment: .leading, spacing: 16) {
                        Label("Connect securely in your browser", systemImage: "safari").font(.headline)
                        Text("Authorize your Spotify account to see playlists you can import. Availability and matches may differ from the originals.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Connect Spotify") { Task { await model.connectSpotify() } }.buttonStyle(.borderedProminent).disabled(model.isBusy)
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                } else {
                    HStack {
                        Label("Spotify connected", systemImage: "checkmark.circle.fill").foregroundStyle(StrettoBrand.readableBlue)
                        Spacer()
                        Button("Refresh Playlists") { Task { await model.loadSpotifyPlaylists() } }.disabled(model.isBusy)
                    }
                    if model.spotifyPlaylists.isEmpty && !model.isBusy {
                        EmptyMusicView(title: "No playlists loaded", message: "Refresh to load playlists from your connected account.", symbol: "music.note.list")
                    }
                    LazyVStack(spacing: 0) {
                        ForEach(model.spotifyPlaylists, id: \.id) { playlist in
                            HStack(spacing: 16) {
                                CoverArtView(url: playlist.image.flatMap(URL.init(string:)), size: 64)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(playlist.name).font(.headline)
                                    Text("\(playlist.trackCount) tracks").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Import") { Task { await model.importSpotifyPlaylist(playlist) } }.disabled(model.isBusy)
                            }.padding(.vertical, 14)
                            Divider()
                        }
                    }
                }
                if model.isBusy { Text(model.syncStatus).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            }.padding(28)
        }.navigationTitle("Spotify Import")
            .task { if model.spotifyConnected { await model.loadSpotifyPlaylists() } }
            .onChange(of: model.spotifyConnected) { _, connected in if connected { Task { await model.loadSpotifyPlaylists() } } }
    }
}

private struct AccountSyncView: View {
    @ObservedObject var model: AppModel
    var signIn: () -> Void
    var review: () -> Void
    @State private var confirmLogout = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeading(eyebrow: "SAME STRETTO. NEW HOME.", title: "One library, everywhere",
                            subtitle: "Your official Stretto account. Your music, safely kept on this Mac.")
                HStack(spacing: 18) {
                    Image(systemName: "person.crop.circle.fill").font(.system(size: 48)).foregroundStyle(StrettoBrand.readableBlue)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(model.accountEmail ?? "Listening locally").font(.title3.weight(.semibold))
                        Text(model.accountEmail == nil ? "Sign in to sync with Stretto web." : model.syncStatus).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.accountEmail == nil { Button("Sign In…", action: signIn).buttonStyle(.borderedProminent) }
                    else { Button("Sync Now") { Task { await model.sync() } }.buttonStyle(.borderedProminent).disabled(model.isBusy) }
                }.padding(24).background(StrettoBrand.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                HStack(spacing: 32) {
                    VStack(alignment: .leading, spacing: 5) { Text("\(model.library.songs.count)").font(.title); Text("Songs").foregroundStyle(.secondary) }
                    VStack(alignment: .leading, spacing: 5) { Text("\(model.library.playlists.count)").font(.title); Text("Playlists").foregroundStyle(.secondary) }
                }.padding(.vertical, 8)
                if model.conflict != nil {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Your library changed in two places", systemImage: "exclamationmark.arrow.triangle.2.circlepath").font(.headline)
                        Text("Nothing is overwritten automatically. Compare your Mac and server libraries, then choose which version to keep.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Review Changes…", action: review)
                    }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                }
                VStack(alignment: .leading, spacing: 10) {
                    Label("Local changes stay with you", systemImage: "externaldrive.badge.checkmark")
                    Text("Stretto syncs a complete library, not individual tracks. If another device edits the server version, you’ll review the conflict before continuing. Downloaded audio remains local.")
                        .font(.callout).foregroundStyle(.secondary)
                }.padding(22).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                if model.accountEmail != nil {
                    Button("Sign Out…", role: .destructive) { confirmLogout = true }.disabled(model.isBusy)
                }
            }.padding(28)
        }.navigationTitle("Account & Sync")
            .confirmationDialog("Sign out of Stretto?", isPresented: $confirmLogout, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) { Task { await model.logout() } }
            } message: { Text("Account libraries are kept separately. Sync pending changes before signing out if you want them on your other devices.") }
    }
}

private struct ConflictReviewView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedLocal: Bool?
    @State private var confirming = false
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Choose your library").font(.title2.weight(.semibold))
            Text("The server changed while this Mac had local edits. Compare both snapshots before replacing either version. A recovery backup is preserved.")
                .font(.callout).foregroundStyle(.secondary)
            if let conflict = model.conflict {
                HStack(alignment: .top, spacing: 18) {
                    comparison("This Mac", library: conflict.local, local: true)
                    comparison("Stretto server", library: conflict.remote, local: false)
                }
                Text("Choosing this Mac uploads its complete library. Choosing the server replaces this Mac’s library. These choices do not merge songs or playlists.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.isBusy { ProgressView("Resolving…") }
                HStack {
                    Button("Keep for Later") { dismiss() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(selectedLocal == true ? "Use This Mac…" : selectedLocal == false ? "Use Server Library…" : "Choose a Version") { confirming = true }
                        .buttonStyle(.borderedProminent).disabled(selectedLocal == nil || model.isBusy)
                }
            } else {
                Label("Your conflict is resolved", systemImage: "checkmark.circle")
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 660)
            .confirmationDialog("Replace with \(selectedLocal == true ? "this Mac’s" : "the server’s") library?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Confirm Choice") {
                    guard let local = selectedLocal else { return }
                    Task { await model.resolveConflict(useLocal: local); if model.conflict == nil { dismiss() } }
                }
            }
    }

    private func comparison(_ title: String, library: Library, local: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Image(systemName: selectedLocal == local ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(StrettoBrand.readableBlue)
            }
            Text("\(library.songs.count) songs · \(library.playlists.count) playlists").font(.callout)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(library.playlists) { playlist in
                        HStack { Text(playlist.title).lineLimit(1); Spacer(); Text("\(playlist.songs.count)").foregroundStyle(.secondary) }.font(.caption)
                    }
                    if library.playlists.isEmpty { Text("No playlists").font(.caption).foregroundStyle(.secondary) }
                }
            }.frame(height: 140)
            Button(local ? "Choose This Mac" : "Choose Server") { selectedLocal = local }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(selectedLocal == local ? StrettoBrand.blue.opacity(0.12) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selectedLocal == local ? StrettoBrand.readableBlue : Color.clear))
    }
}

private struct AccountAuthView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var mode = "Sign in"
    @State private var email = ""
    @State private var password = ""
    @State private var token = ""
    @State private var submitted = false
    @State private var requestRunning = false
    @FocusState private var emailFocused: Bool
    private var hasPassword: Bool { mode != "Recover" }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 25) {
                StrettoLogo(size: 50)
                Text("Your music.\nYour Mac.\nYour moment.").font(.system(size: 31, weight: .semibold))
                Text("The library you love.\nA new way to feel at home.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                if let icon = StrettoBrand.icon { Image(nsImage: icon).resizable().frame(width: 82, height: 82).clipShape(RoundedRectangle(cornerRadius: 18)) }
                Text("Connected to Stretto official").font(.caption).foregroundStyle(.secondary)
            }.padding(32).frame(width: 270).frame(maxHeight: .infinity)
                .background(StrettoBrand.blue.opacity(0.08))
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(mode == "Sign in" ? "Welcome back" : mode == "Create account" ? "Make yourself at home" : "Find your way back")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Close sign in").keyboardShortcut(.cancelAction)
                }
                Picker("Account action", selection: $mode) {
                    Text("Sign in").tag("Sign in")
                    Text("Create account").tag("Create account")
                    Text("Recover").tag("Recover")
                    Text("Reset").tag("Reset")
                }.pickerStyle(.segmented)
                if mode == "Sign in" || mode == "Create account" {
                    Button {
                        submitted = true
                        requestRunning = true
                        model.errorMessage = nil
                        Task { await model.googleLogin(); requestRunning = false }
                    } label: { Label("Continue with Google", systemImage: "safari").frame(maxWidth: .infinity) }
                        .controlSize(.large).disabled(model.isBusy || requestRunning)
                    Text("Google opens your system browser.").font(.caption).foregroundStyle(.secondary)
                    Divider()
                }
                TextField("Email address", text: $email).textFieldStyle(.roundedBorder).focused($emailFocused).textContentType(.emailAddress)
                if hasPassword {
                    SecureField(mode == "Reset" ? "New password" : "Password", text: $password).textFieldStyle(.roundedBorder)
                        .textContentType(mode == "Sign in" ? .password : .newPassword).onSubmit(submit)
                }
                if mode == "Reset" {
                    TextField("Reset token or official recovery link", text: $token).textFieldStyle(.roundedBorder)
                    Text("Paste the token or the complete recovery link from your email.").font(.caption).foregroundStyle(.secondary)
                }
                Button(mode == "Recover" ? "Send Recovery Email" : mode == "Reset" ? "Reset Password" : mode) { submit() }
                    .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                    .disabled(model.isBusy || requestRunning || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (hasPassword && password.isEmpty) || (mode == "Reset" && token.isEmpty))
                if model.isBusy || requestRunning { ProgressView().controlSize(.small) }
                if submitted, let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                else if submitted && mode == "Recover" && !model.isBusy && !requestRunning {
                    Text(model.syncStatus).font(.caption).foregroundStyle(.secondary)
                } else if mode == "Sign in" && model.syncStatus.hasPrefix("Password reset") {
                    Text(model.syncStatus).font(.caption).foregroundStyle(StrettoBrand.readableBlue)
                }
                Spacer(minLength: 5)
                Text("Your account stays with Stretto. You can continue listening locally without signing in.").font(.caption).foregroundStyle(.secondary)
            }.padding(28).frame(width: 390)
        }.frame(height: 470)
            .onAppear {
                emailFocused = true
                if !model.resetToken.isEmpty { mode = "Reset"; token = model.resetToken }
            }
            .onChange(of: model.accountEmail) { _, email in if email != nil { dismiss() } }
            .onChange(of: model.resetToken) { _, value in
                if !value.isEmpty { mode = "Reset"; token = value; submitted = false }
                else if mode == "Reset" && submitted { mode = "Sign in"; password = ""; token = "" }
            }
            .onChange(of: mode) { _, newMode in
                submitted = false
                password = ""
                token = newMode == "Reset" ? model.resetToken : ""
            }
    }

    private func submit() {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isBusy, !requestRunning, !address.isEmpty, (!hasPassword || !password.isEmpty),
              mode != "Reset" || !token.isEmpty else { return }
        submitted = true
        requestRunning = true
        model.errorMessage = nil
        let action = mode
        Task {
            defer { requestRunning = false }
            switch action {
            case "Create account": await model.register(email: address, password: password)
            case "Recover": await model.forgotPassword(email: address)
            case "Reset":
                let items = URLComponents(string: token.trimmingCharacters(in: .whitespacesAndNewlines))?.queryItems
                let extracted = items?.first(where: { ["token", "resetToken"].contains($0.name) })?.value
                await model.completeReset(email: address, password: password, token: extracted ?? token.trimmingCharacters(in: .whitespacesAndNewlines))
            default: await model.login(email: address, password: password)
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @AppStorage("appearance") private var appearance = "light"
    @AppStorage("menuBarPlayer") private var menuBarPlayer = true
    @AppStorage("miniAlwaysOnTop") private var miniAlwaysOnTop = false
    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $appearance) {
                    Text("Match system").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                LabeledContent("Stretto blue") {
                    HStack { Text("#44BBFF").font(.caption.monospaced()).foregroundStyle(.secondary); Circle().fill(StrettoBrand.blue).frame(width: 18, height: 18) }
                }
                Text("System typography, native materials, and accessible blue text adapt to your appearance.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Mac controls") {
                Toggle("Show menu-bar player", isOn: $menuBarPlayer)
                Toggle("Mini player always on top", isOn: $miniAlwaysOnTop)
                Text("Playback integrates with macOS Now Playing and media keys. Use your Mac’s Sound controls to choose the audio output.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Your library") {
                LabeledContent("Account", value: model.accountEmail ?? "Local library")
                LabeledContent("Sync", value: model.syncStatus)
                LabeledContent("Songs", value: "\(model.library.songs.count)")
                Text("Native downloads are independent of your browser’s cache. Unsupported sources remain in your library so sync preserves them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack { StrettoLogo(size: 28); Spacer(); Text("Native macOS companion").font(.caption).foregroundStyle(.secondary) }
            }
        }.formStyle(.grouped).padding(8).frame(width: 490, height: 540)
            .tint(StrettoBrand.readableBlue)
            .preferredColorScheme(appearance == "system" ? nil : appearance == "dark" ? .dark : .light)
    }
}

private struct NamePromptView: View {
    var title: String
    var initialValue = ""
    var actionTitle: String
    var save: (String) -> Void
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.title2.weight(.semibold))
            TextField("Playlist name", text: $name).textFieldStyle(.roundedBorder).focused($focused)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(actionTitle) { save(name.trimmingCharacters(in: .whitespacesAndNewlines)); dismiss() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines) == "Library")
            }
        }.padding(26).frame(width: 400).onAppear { name = initialValue; focused = true }
    }
}

private struct SongEditorView: View {
    @ObservedObject var model: AppModel
    var song: Song
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var artist = ""
    @State private var album = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Edit song details").font(.title2.weight(.semibold))
            HStack(spacing: 14) { CoverArtView(url: song.coverURL, size: 64); Text(song.source).foregroundStyle(.secondary) }
            Form {
                TextField("Title", text: $title)
                TextField("Artist", text: $artist)
                TextField("Album", text: $album)
            }.textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    model.updateSong(song, title: title.trimmingCharacters(in: .whitespacesAndNewlines), artist: artist, album: album)
                    dismiss()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(26).frame(width: 450).onAppear { title = song.title; artist = song.artist; album = song.album }
    }
}

private struct URLImportView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var submitted = false
    @State private var loading = false
    @State private var showingPreview = false
    @FocusState private var focused: Bool
    var body: some View {
        Group {
            if showingPreview {
                RemotePlaylistPreviewView(model: model)
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Bring a favorite with you").font(.title2.weight(.semibold))
                    Text("Paste a YouTube song or playlist URL, or a SoundCloud track URL. Preview first, then add the songs you want.")
                        .font(.callout).foregroundStyle(.secondary)
                    TextField("Music URL", text: $url).textFieldStyle(.roundedBorder).focused($focused).disabled(loading)
                    if loading { ProgressView("Loading preview…").controlSize(.small) }
                    if submitted, let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
                    HStack {
                        Button(loading ? "Keep Browsing" : "Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                        Spacer()
                        Button("Preview") {
                            submitted = true
                            loading = true
                            model.errorMessage = nil
                            let value = url.trimmingCharacters(in: .whitespacesAndNewlines)
                            Task {
                                await model.importURL(value)
                                loading = false
                                if model.errorMessage == nil && !model.previewSongs.isEmpty { showingPreview = true }
                            }
                        }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                            .disabled(loading || model.searchBusy || URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines))?.scheme != "https")
                    }
                }.padding(26).frame(width: 470).onAppear { focused = true }
            }
        }
    }
}
