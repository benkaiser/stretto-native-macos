import Foundation
import StrettoCore

struct MP3HLSPlaylist {
    let variant: URL?
    let segments: [URL]

    init(data: Data, url: URL) throws {
        guard DownloadManager.soundCloudURL(url), data.count < 2_000_000,
              let text = String(data: data, encoding: .utf8), text.hasPrefix("#EXTM3U") else {
            throw StrettoError.message("SoundCloud HLS playlist is invalid.")
        }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let media = lines.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        if text.contains("#EXT-X-STREAM-INF") {
            guard let first = media.first, let next = URL(string: first, relativeTo: url)?.absoluteURL,
                  DownloadManager.soundCloudURL(next) else {
                throw StrettoError.message("HLS master playlist has no safe audio variant.")
            }
            variant = next
            segments = []
        } else {
            guard text.contains("#EXT-X-ENDLIST"), !text.contains("#EXT-X-KEY"),
                  !text.contains("#EXT-X-BYTERANGE"), !text.contains("#EXT-X-MAP"),
                  !media.isEmpty, media.count <= 2000 else {
                throw StrettoError.message("Encrypted, live, fragmented, or oversized HLS is not supported by the MP3 stream cache.")
            }
            variant = nil
            segments = try media.map { line in
                guard let segment = URL(string: line, relativeTo: url)?.absoluteURL,
                      DownloadManager.soundCloudURL(segment) else {
                    throw StrettoError.message("HLS contained an unsafe segment URL.")
                }
                return segment
            }
        }
    }
}
