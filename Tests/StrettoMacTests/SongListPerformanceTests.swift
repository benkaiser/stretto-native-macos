import AppKit
import Combine
import SwiftUI
import XCTest
import StrettoCore
@testable import StrettoMac
@testable import StrettoMedia

final class SongListPerformanceTests: XCTestCase {
    @MainActor
    func testActionMenusAreBuiltOnlyWhenRequestedAndRetainTheirHandlers() {
        var builds = 0
        var activations = 0
        let button = DeferredMenuButton(label: "Track actions") {
            builds += 1
            let menu = NSMenu()
            menu.addAction("Play") { activations += 1 }
            menu.addAction("Unavailable", enabled: false) { XCTFail("Disabled action must stay disabled.") }
            return menu
        }
        let hosting = NSHostingView(rootView: button.frame(width: 24, height: 22))
        hosting.frame = NSRect(x: 0, y: 0, width: 24, height: 22)
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(builds, 0, "Laying out a song row must not build a hidden menu or its playlist submenu.")
        let coordinator = button.makeCoordinator()
        let menu = coordinator.makeMenu()
        XCTAssertEqual(builds, 1)
        XCTAssertFalse(menu.autoenablesItems)
        XCTAssertTrue(menu.items[0].isEnabled)
        XCTAssertFalse(menu.items[1].isEnabled)
        XCTAssertNotNil(menu.items[0].representedObject, "The menu must retain its action target until selection.")
        if let action = menu.items[0].action {
            NSApp.sendAction(action, to: menu.items[0].target, from: menu.items[0])
        } else { XCTFail("The enabled menu item must have an action.") }
        XCTAssertEqual(activations, 1)
    }

    @MainActor
    func testPlaybackTicksDoNotInvalidateSongRowSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = SourceService()
        let downloads = DownloadManager(sources: sources, root: root)
        let player = PlaybackController(sources: sources, downloads: downloads)
        let activity = PlaybackActivity(player: player)
        var changes = 0
        let subscription = activity.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel(); player.stop() }

        for index in 0..<200 { player.seek(to: Double(index) / 10) }
        XCTAssertEqual(changes, 0)
        let song = Song(id: "a_fixture", title: "Unsupported fixture", artist: "")
        await player.play(song)
        XCTAssertEqual(activity.selection.songID, song.id)
        XCTAssertEqual(changes, 1)
        for index in 0..<200 { player.seek(to: Double(index) / 10) }
        XCTAssertEqual(player.position, 19.9, accuracy: 0.001)
        XCTAssertEqual(changes, 1, "Song rows must not be invalidated by position/seek/error updates.")
        player.stop()
        XCTAssertNil(activity.selection.songID)
        XCTAssertEqual(changes, 2)
    }

    @MainActor
    func testChannelSizedListScrollsWithLargeLibraryBehindIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = SourceService()
        let downloads = DownloadManager(sources: sources, root: root)
        let librarySongs = (0..<2000).map {
            Song(id: "y_\(String(format: "%011d", $0))", title: "Library \($0)", artist: "Fixture")
        }
        let playlists = (0..<80).map { Playlist(title: "Playlist \($0)", songs: librarySongs.prefix(30).map(\.id)) }
        let model = AppModel(api: StrettoAPI(), sources: sources, downloads: downloads,
                             library: Library(songs: librarySongs, playlists: playlists))
        await model.player.play(Song(id: "a_fixture", title: "Unsupported fixture", artist: ""))
        XCTAssertEqual(model.librarySongIDs.count, 2000)
        let channelSongs = (2000..<2030).map {
            Song(id: "y_\(String(format: "%011d", $0))", title: "Channel \($0)", artist: "Fixture")
        }
        let content = ZStack {
            ScrollView { SongListView(model: model, songs: librarySongs) }
            ScrollView {
                VStack(spacing: 18) {
                    Text("Channel videos")
                    SongListView(model: model, songs: channelSongs, canAdd: true, showsChannelMetadata: true)
                }.padding(22)
            }.background(Color(nsColor: .windowBackgroundColor))
        }.frame(width: 860, height: 463)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 463),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: content)
        window.contentView = hosting
        defer { window.contentView = nil; model.player.stop() }
        hosting.layoutSubtreeIfNeeded()
        await Task.yield()
        hosting.layoutSubtreeIfNeeded()
        let scrolls = descendants(hosting).compactMap { $0 as? NSScrollView }
        let scroll = try XCTUnwrap(scrolls.last)
        var maximum = Duration.zero
        for offset in stride(from: 0, through: 1450, by: 145) {
            let began = ContinuousClock.now
            model.player.seek(to: Double(offset) / 100)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
            scroll.reflectScrolledClipView(scroll.contentView)
            hosting.layoutSubtreeIfNeeded()
            await Task.yield()
            hosting.layoutSubtreeIfNeeded()
            maximum = max(maximum, began.duration(to: .now))
        }
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 1000, "The test must actually scroll through the channel rows.")
        XCTAssertLessThan(maximum, .milliseconds(50), "Scrolling 30 rows must not stall while a 2,000-song library is behind it.")
        try FileHandle.standardError.write(contentsOf: Data("[StrettoScroll] 30 channel rows over 2000 library songs: max layout \(maximum)\n".utf8))
    }

    @MainActor
    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
