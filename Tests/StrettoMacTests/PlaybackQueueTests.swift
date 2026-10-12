import AppKit
import SwiftUI
import XCTest
import StrettoCore
@testable import StrettoMac

final class PlaybackQueueTests: XCTestCase {
    @MainActor
    func testTwoThousandSongQueueLaysOutWithoutBuildingTheEntireLibrary() async throws {
        let songs = (0..<2000).map {
            Song(id: "y_\(String(format: "%011d", $0))", title: "Queue track \($0)", artist: "Test artist")
        }
        let queue = PlaybackQueueView(songs: songs, currentSongID: songs[0].id, isPlaying: false,
                                      play: { _ in }, browseChannel: { _ in })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 330, height: 440),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let began = ContinuousClock.now
        let hosting = NSHostingView(rootView: queue.frame(width: 330, height: 440))
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        await Task.yield()
        hosting.layoutSubtreeIfNeeded()
        let elapsed = began.duration(to: .now)
        XCTAssertLessThan(elapsed, .seconds(2), "Opening a 2,000-song queue must not synchronously render every row.")
        XCTAssertEqual(hosting.frame.size, NSSize(width: 330, height: 440))
        try FileHandle.standardError.write(contentsOf: Data("[StrettoQueue] 2000-song bounded lazy layout: \(elapsed)\n".utf8))
        window.contentView = nil
    }
}
