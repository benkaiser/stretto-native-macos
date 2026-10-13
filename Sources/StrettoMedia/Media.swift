import Foundation
import Combine
import MediaPlayer
import AppKit
import CryptoKit
import StrettoCore

public struct DownloadEntry: Identifiable, Codable {
    public var id: String
    public var song: Song
    public var bytes: Int64
    public var status: String
    public var progress: Double
    var filename: String?
    var pinned: Bool?
    var cachedAt: Date?
    public var isPinned: Bool { pinned ?? true }
    public init(id: String, song: Song, bytes: Int64 = 0, status: String, progress: Double = 0) {
        self.id = id; self.song = song; self.bytes = bytes; self.status = status; self.progress = progress
    }
    init(id: String, song: Song, bytes: Int64, status: String, progress: Double, filename: String?) {
        self.init(id: id, song: song, bytes: bytes, status: status, progress: progress)
        self.filename = filename
    }
}

@MainActor
public final class DownloadManager: ObservableObject {
    @Published public private(set) var entries: [DownloadEntry] = []
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var isDownloading = false
    public var totalBytes: Int64 { entries.reduce(0) { $0 + $1.bytes } }
    private let sources: SourceService
    private let session: URLSession
    private let root: URL
    private var directory: URL
    private var generation = UUID()
    private var accountGeneration = UUID()
    private let storageLimit: Int64 = 2 * 1024 * 1024 * 1024
    private let trackLimit: Int64 = 300 * 1024 * 1024
    private var transfer: AudioTransfer?

    public convenience init(sources: SourceService) {
        self.init(sources: sources, root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Stretto/Audio", isDirectory: true))
    }

    init(sources: SourceService, root: URL) {
        self.sources = sources
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 900
        session = URLSession(configuration: config, delegate: AudioRedirectGuard(), delegateQueue: nil)
        self.root = root
        directory = root.appendingPathComponent(Self.hash("guest"), isDirectory: true)
        do { try setAccount("guest") } catch { errorMessage = error.localizedDescription }
    }

    public func setAccount(_ account: String) throws {
        accountGeneration = UUID()
        generation = UUID()
        transfer?.cancel()
        isDownloading = false
        entries = []
        errorMessage = nil
        directory = root.appendingPathComponent(Self.hash(account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let manifest = directory.appendingPathComponent("manifest.json")
        if FileManager.default.fileExists(atPath: manifest.path) {
            entries = try JSONDecoder().decode([DownloadEntry].self, from: Data(contentsOf: manifest))
            entries = entries.filter { entry in
                guard entry.status == "available", let filename = entry.filename,
                      filename == URL(fileURLWithPath: filename).lastPathComponent else { return false }
                let url = directory.appendingPathComponent(filename)
                return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { $0 > 0 && Int64($0) == entry.bytes } == true
            }
        }
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where url.lastPathComponent.hasSuffix(".partial") || url.lastPathComponent.contains(".partial.") {
            try? FileManager.default.removeItem(at: url)
        }
        try persist()
    }

    public func localURL(for song: Song) -> URL? {
        guard let entry = entries.first(where: { $0.id == song.id && $0.status == "available" }), let filename = entry.filename,
              filename == URL(fileURLWithPath: filename).lastPathComponent else { return nil }
        let url = directory.appendingPathComponent(filename)
        guard (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map({ $0 > 0 && Int64($0) == entry.bytes }) == true else { return nil }
        return url
    }

    public func isPinned(_ song: Song) -> Bool {
        entries.contains { $0.id == song.id && $0.status == "available" && $0.isPinned }
    }

    var accountToken: UUID { accountGeneration }

    func cacheCompletedPlayback(_ song: Song, from source: URL, expectedDuration: Double, token: UUID) async throws {
        try ensureCacheAccount(token)
        let deadline = Date().addingTimeInterval(60)
        while entries.contains(where: { $0.id == song.id && $0.status == "downloading" }) {
            guard Date() < deadline else { throw StrettoError.message("The explicit download is still in progress; playback cache was not saved.") }
            try await Task.sleep(for: .milliseconds(100))
            try ensureCacheAccount(token)
        }
        if localURL(for: song) != nil { return }
        let recordedDuration = try await MPVEngine.inspectFile(source)
        guard expectedDuration > 0, abs(recordedDuration - expectedDuration) <= max(2, expectedDuration * 0.01) else {
            throw StrettoError.message("Completed audio was incomplete; it was not cached.")
        }
        try ensureCacheAccount(token)
        let bytes = Int64(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        guard bytes > 0 && bytes <= trackLimit else { throw StrettoError.message("Playback cache exceeded the 300 MB track limit.") }
        try reserveSpace(bytes)
        guard ["webm", "ogg", "m4a", "mp3"].contains(source.pathExtension) else {
            throw StrettoError.message("Completed playback cache has an unsupported container.")
        }
        let filename = "\(Self.hash(song.id)).\(source.pathExtension)"
        let destination = directory.appendingPathComponent(filename)
        let staging = directory.appendingPathComponent("\(UUID().uuidString).partial.\(source.pathExtension)")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: source, to: staging)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
        } else { try FileManager.default.moveItem(at: staging, to: destination) }
        var entry = DownloadEntry(id: song.id, song: song, bytes: bytes, status: "available", progress: 1, filename: filename)
        entry.pinned = false
        entry.cachedAt = Date()
        entries.removeAll { $0.id == song.id }
        entries.append(entry)
        do { try persist() }
        catch {
            entries.removeAll { $0.id == song.id }
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    public func download(_ song: Song) async throws {
        if localURL(for: song) != nil {
            if let index = entries.firstIndex(where: { $0.id == song.id }) {
                let previous = entries[index].pinned
                entries[index].pinned = true
                do { try persist() } catch { entries[index].pinned = previous; throw error }
            }
            return
        }
        guard !isDownloading else { throw StrettoError.message("Another download is in progress. Wait or cancel it before retrying.") }
        guard song.supported else { throw StrettoError.message("Only YouTube and SoundCloud audio can be downloaded.") }
        try reserveSpace(1)
        isDownloading = true
        errorMessage = nil
        let token = generation
        let accountDirectory = directory
        let staging = accountDirectory.appendingPathComponent("\(Self.hash(song.id))-\(UUID().uuidString).partial")
        var typedStaging: URL?
        entries.removeAll { $0.id == song.id }
        entries.append(DownloadEntry(id: song.id, song: song, bytes: 0, status: "downloading", progress: 0))
        defer {
            try? FileManager.default.removeItem(at: staging)
            if let typedStaging { try? FileManager.default.removeItem(at: typedStaging) }
            if generation == token { isDownloading = false }
        }
        do {
            let remote = try await sources.resolve(song: song)
            try ensureAccount(token)
            var kind = try await fetchAudio(remote, to: staging, song: song, token: token)
            var finalSource = staging
            if kind == .hls {
                try? FileManager.default.removeItem(at: staging)
                let typed = accountDirectory.appendingPathComponent("\(UUID().uuidString).partial.mp3")
                typedStaging = typed
                try await saveMP3HLS(remote, to: typed, song: song, token: token)
                kind = .mp3
                finalSource = typed
            } else {
                let typed = accountDirectory.appendingPathComponent("\(UUID().uuidString).partial.\(kind.fileExtension)")
                typedStaging = typed
                try FileManager.default.moveItem(at: staging, to: typed)
                finalSource = typed
            }
            _ = try await MPVEngine.inspectFile(finalSource)
            try ensureAccount(token)
            let bytes = Int64(try finalSource.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            guard bytes > 0 else { throw StrettoError.message("Download contained no audio bytes.") }
            try reserveSpace(bytes)
            let filename = "\(Self.hash(song.id)).\(kind.fileExtension)"
            let destination = accountDirectory.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: finalSource) }
            else { try FileManager.default.moveItem(at: finalSource, to: destination) }
            if let index = entries.firstIndex(where: { $0.id == song.id }) {
                entries[index] = DownloadEntry(id: song.id, song: song, bytes: bytes, status: "available", progress: 1, filename: filename)
            }
            do { try persist() }
            catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        } catch {
            if generation == token {
                if let index = entries.firstIndex(where: { $0.id == song.id }) {
                    entries[index].status = error is CancellationError ? "cancelled" : "failed"
                    entries[index].bytes = 0
                    entries[index].filename = nil
                }
                errorMessage = error is CancellationError ? "Download cancelled." : error.localizedDescription
                try? persist()
            }
            throw error
        }
    }

    public func remove(_ song: Song) throws {
        if entries.contains(where: { $0.id == song.id && $0.status == "downloading" }) {
            throw StrettoError.message("Cancel the active download before removing it.")
        }
        if let entry = entries.first(where: { $0.id == song.id }), let filename = entry.filename,
           filename == URL(fileURLWithPath: filename).lastPathComponent {
            let url = directory.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        entries.removeAll { $0.id == song.id }
        try persist()
    }

    public func cancel() {
        generation = UUID()
        transfer?.cancel()
        for index in entries.indices where entries[index].status == "downloading" { entries[index].status = "cancelled" }
        isDownloading = false
        try? persist()
    }

    public func cancelDownloads() { cancel() }

    public func clearError() { errorMessage = nil }

    enum AudioKind: Equatable {
        case mp3, m4a, webm, ogg, hls
        var fileExtension: String {
            switch self {
            case .mp3: return "mp3"
            case .m4a: return "m4a"
            case .webm: return "webm"
            case .ogg: return "ogg"
            case .hls: return "m3u8"
            }
        }
    }

    private func fetchAudio(_ url: URL, to destination: URL, song: Song, token: UUID) async throws -> AudioKind {
        guard Self.safeURL(url) else { throw StrettoError.message("Audio source returned an unsafe URL.") }
        var request = URLRequest(url: url)
        request.setValue("StrettoNative/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let operation = AudioTransfer()
        transfer = operation
        defer { if transfer === operation { transfer = nil } }
        let result = try await operation.fetch(request, destination: destination, limit: trackLimit) { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.updateProgress(song.id, progress * 0.9)
            }
        }
        try ensureAccount(token)
        return try Self.audioKind(result.header, mime: result.mime)
    }

    nonisolated static func audioKind(_ data: Data, mime: String) throws -> AudioKind {
        let bytes = [UInt8](data)
        if String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") == true { return .hls }
        if bytes.starts(with: [0x1a, 0x45, 0xdf, 0xa3]) { return .webm }
        if bytes.starts(with: Array("OggS".utf8)) { return .ogg }
        if bytes.count > 12 && String(bytes: bytes[4..<8], encoding: .ascii) == "ftyp" { return .m4a }
        if bytes.starts(with: Array("ID3".utf8)) || bytes.count > 1 && bytes[0] == 0xff && bytes[1] & 0xe0 == 0xe0 { return .mp3 }
        throw StrettoError.message("Audio container is unsupported or invalid; no offline file was saved.")
    }

    private func saveMP3HLS(_ initial: URL, to output: URL, song: Song, token: UUID) async throws {
        var playlistURL = initial
        var segments: [URL] = []
        for _ in 0..<3 {
            guard Self.soundCloudURL(playlistURL) else { throw StrettoError.message("HLS offline export only accepts SoundCloud audio hosts.") }
            let (data, response) = try await session.data(from: playlistURL)
            try ensureAccount(token)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let finalURL = http.url else {
                throw StrettoError.message("HLS playlist is invalid.")
            }
            let parsed = try MP3HLSPlaylist(data: data, url: finalURL)
            if let variant = parsed.variant {
                playlistURL = variant
            } else {
                segments = parsed.segments
                break
            }
        }
        guard !segments.isEmpty else { throw StrettoError.message("HLS variant nesting limit exceeded.") }
        guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw StrettoError.message("Could not create HLS offline file.")
        }
        let file = try FileHandle(forWritingTo: output)
        defer { try? file.close() }
        var total: Int64 = 0
        for (index, segment) in segments.enumerated() {
            let (data, response) = try await session.data(from: segment)
            try ensureAccount(token)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  http.url.map(Self.soundCloudURL) == true, data.count < 20_000_000,
                  try Self.audioKind(data.prefix(512), mime: http.mimeType ?? "") == .mp3 else {
                throw StrettoError.message("HLS segment was not complete MP3 audio.")
            }
            total += Int64(data.count)
            guard total <= trackLimit else { throw StrettoError.message("HLS exceeded the 300 MB track limit.") }
            try file.write(contentsOf: data)
            updateProgress(song.id, Double(index + 1) / Double(segments.count) * 0.9)
        }
        try file.synchronize()
    }

    private func ensureAccount(_ token: UUID) throws {
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
    }
    private func ensureCacheAccount(_ token: UUID) throws {
        try Task.checkCancellation()
        guard token == accountGeneration else { throw CancellationError() }
    }
    private func updateProgress(_ id: String, _ value: Double) {
        if let index = entries.firstIndex(where: { $0.id == id }) { entries[index].progress = min(0.99, max(0, value)) }
    }
    private func persist() throws {
        try JSONEncoder().encode(entries).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
    }
    private func reserveSpace(_ bytes: Int64) throws {
        guard bytes <= storageLimit else { throw StrettoError.message("Audio exceeds the 2 GB storage limit.") }
        let cached = entries.filter { !$0.isPinned && $0.status == "available" }
            .sorted { ($0.cachedAt ?? .distantPast) < ($1.cachedAt ?? .distantPast) }
        for entry in cached where totalBytes + bytes > storageLimit {
            try remove(entry.song)
        }
        guard totalBytes + bytes <= storageLimit else {
            throw StrettoError.message("Offline storage limit (2 GB) reached. Remove explicit downloads first.")
        }
    }
    private static func hash(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    nonisolated static func safeURL(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, let host = url.host?.lowercased(),
              host.contains("."), !host.contains(":"), !host.hasSuffix(".local"), !host.hasSuffix(".localhost"),
              host.range(of: "^[0-9.]+$", options: .regularExpression) == nil else { return false }
        return true
    }
    nonisolated static func soundCloudURL(_ url: URL) -> Bool {
        safeURL(url) && (url.host?.hasSuffix(".sndcdn.com") == true || url.host?.hasSuffix(".soundcloud.com") == true)
    }
}

/// URLSession delivers bounded chunks on a serial delegate queue; no per-byte MainActor hopping.
final class AudioTransfer: NSObject, URLSessionDataDelegate {
    struct Result { var header: Data; var mime: String; var url: URL; var bytes: Int64 }
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<Result, Error>?
    private var file: FileHandle?
    private var destination: URL?
    private var limit: Int64 = 0
    private var expected: Int64 = -1
    private var received: Int64 = 0
    private var header = Data()
    private var mime = ""
    private var failure: Error?
    private var progress: ((Double) -> Void)?
    private var consumer: ((Data) throws -> Void)?
    private var finalURL: URL?
    private let lock = NSLock()
    private let protocolClasses: [AnyClass]?

    init(protocolClasses: [AnyClass]? = nil) {
        self.protocolClasses = protocolClasses
        super.init()
    }

    func fetch(_ request: URLRequest, destination: URL?, limit: Int64, consumer: ((Data) throws -> Void)? = nil,
               progress: @escaping (Double) -> Void) async throws -> Result {
        self.destination = destination
        self.limit = limit
        self.progress = progress
        self.consumer = consumer
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let config = URLSessionConfiguration.ephemeral
                config.protocolClasses = protocolClasses
                config.timeoutIntervalForRequest = 60
                config.timeoutIntervalForResource = 300
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                queue.qualityOfService = .utility
                let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
                self.session = session
                let task = session.dataTask(with: request)
                lock.lock()
                self.task = task
                lock.unlock()
                task.resume()
                if Task.isCancelled { task.cancel() }
            }
        } onCancel: { self.cancel() }
    }

    func cancel() {
        lock.lock()
        let task = task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  http.url.map(DownloadManager.safeURL) == true else {
                throw StrettoError.message("Audio download failed; the stream may have expired or been blocked.")
            }
            mime = http.mimeType?.lowercased() ?? ""
            guard mime.hasPrefix("audio/") || mime == "video/mp4" || mime == "video/webm" ||
                  mime.contains("mpegurl") || mime == "application/octet-stream" else {
                throw StrettoError.message("Server returned \(mime.isEmpty ? "unknown content" : mime), not audio.")
            }
            expected = response.expectedContentLength
            if mime.contains("mpegurl") { limit = min(limit, 2_000_000) }
            guard expected <= limit else { throw StrettoError.message("Audio exceeds the available offline storage or 300 MB track limit.") }
            finalURL = http.url
            if let destination {
                guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw StrettoError.message("Unable to create offline audio file.")
                }
                file = try FileHandle(forWritingTo: destination)
            }
            completionHandler(.allow)
        } catch { failure = error; completionHandler(.cancel) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            received += Int64(data.count)
            guard received <= limit else { throw StrettoError.message("Audio download exceeded the offline storage limit.") }
            if header.count < 512 { header.append(data.prefix(512 - header.count)) }
            if consumer != nil { dataTask.suspend() }
            defer { if consumer != nil { dataTask.resume() } }
            try file?.write(contentsOf: data)
            try consumer?(data)
            progress?(expected > 0 ? Double(received) / Double(expected) : 0)
        } catch { failure = error; dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer {
            try? file?.close()
            file = nil
            session.finishTasksAndInvalidate()
            self.session = nil
            self.continuation = nil
            self.progress = nil
            self.consumer = nil
        }
        do {
            if let failure { throw failure }
            if let error { throw error }
            guard received > 0, expected <= 0 || received == expected, let finalURL else {
                throw StrettoError.message("Audio download was empty or incomplete.")
            }
            try file?.synchronize()
            continuation?.resume(returning: Result(header: header, mime: mime, url: finalURL, bytes: received))
        } catch { continuation?.resume(throwing: error) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(DownloadManager.safeURL) == true ? request : nil)
    }
}

private final class AudioRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(DownloadManager.safeURL) == true ? request : nil)
    }
}

@MainActor
public final class PlaybackController: ObservableObject {
    @Published public private(set) var currentSong: Song?
    @Published public private(set) var queue: [Song] = []
    @Published public private(set) var isPlaying = false
    @Published public private(set) var isLoading = false
    @Published public private(set) var position: Double = 0
    @Published public private(set) var duration: Double = 0
    @Published public private(set) var errorMessage: String?
    @Published public var shuffle = false
    @Published public var repeatMode = "off" {
        didSet { if !["off", "all", "one"].contains(repeatMode) { repeatMode = "off" } }
    }
    @Published public var volume: Double = 0.8 {
        didSet {
            if !volume.isFinite { volume = 0.8 }
            if volume < 0 || volume > 1 { volume = min(1, max(0, volume)) }
            do { try engine?.setVolume(volume) } catch { errorMessage = error.localizedDescription }
        }
    }
    private let sources: SourceService
    private let downloads: DownloadManager
    private let makeStream: (URL) throws -> ProgressiveAudioSource
    private var engine: MPVEngine?
    private var itemReady = false
    private var paused = true
    private var buffering = false
    private var idle = true
    private var stream: ProgressiveAudioSource?
    private var cacheEligible = false
    private var playbackAccount = UUID()
    private var cacheTasks: [UUID: Task<Void, Never>] = [:]
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    private var artworkTask: Task<Void, Never>?
    private var transportTask: Task<Void, Never>?
    private var generation = UUID()
    private var artwork: MPMediaItemArtwork?
    private var wantsPlayback = false
    private var isResolving = false
    private var usesSourceDuration = false
    private var history: [Song] = []

    public convenience init(sources: SourceService, downloads: DownloadManager) {
        self.init(sources: sources, downloads: downloads, makeStream: { try ProgressiveAudioSource(remote: $0) })
    }

    init(sources: SourceService, downloads: DownloadManager, makeStream: @escaping (URL) throws -> ProgressiveAudioSource) {
        self.sources = sources
        self.downloads = downloads
        self.makeStream = makeStream
        registerCommands()
    }

    public func play(_ song: Song, in songs: [Song] = []) async {
        generation = UUID()
        let token = generation
        playbackAccount = downloads.accountToken
        disposeItem()
        isPlaying = false
        isLoading = true
        isResolving = true
        errorMessage = nil
        wantsPlayback = true
        position = 0
        duration = song.duration.isFinite && song.duration > 0 ? song.duration : 0
        currentSong = song
        if !songs.isEmpty { queue = songs }
        else if !queue.contains(where: { $0.id == song.id }) { queue = [song] }
        artwork = nil
        publishNowPlaying()
        fetchArtwork(song, token: token)
        do {
            var url: URL
            if let local = downloads.localURL(for: song) { url = local }
            else {
                let audio = try await sources.resolveAudio(song: song)
                guard generation == token else { return }
                url = audio.url
                if let seconds = audio.duration { duration = seconds; publishNowPlaying() }
            }
            guard generation == token else { return }
            try Task.checkCancellation()
            guard url.isFileURL || DownloadManager.safeURL(url) else { throw StrettoError.message("Audio source returned an unsafe URL.") }
            cacheEligible = !url.isFileURL
            if cacheEligible {
                let stream = try makeStream(url)
                self.stream = stream
                url = try await stream.prepare()
                guard generation == token else { return }
                try Task.checkCancellation()
                // A growing MP3's decoder duration is the read-ahead horizon, not the track's total length.
                usesSourceDuration = url.pathExtension == "mp3" && duration > 0
            }
            let engine = try MPVEngine(volume: volume, source: stream) { [weak self] event in
                Task { @MainActor [weak self] in self?.receive(event, token: token) }
            }
            self.engine = engine
            try engine.load(url, paused: !wantsPlayback)
            isResolving = false
            isLoading = wantsPlayback
        } catch {
            guard generation == token else { return }
            fail(error is CancellationError ? "Playback cancelled." : error.localizedDescription)
        }
    }

    public func toggle() {
        guard currentSong != nil else { return }
        wantsPlayback.toggle()
        if wantsPlayback && engine == nil && !isResolving {
            if let song = currentSong { launch(song) }
            return
        }
        do { try engine?.pause(!wantsPlayback) } catch { fail(error.localizedDescription); return }
        if !wantsPlayback { isLoading = false }
        publishNowPlaying()
    }
    public func resume() {
        guard currentSong != nil else { return }
        wantsPlayback = true
        if engine == nil && !isResolving {
            if let song = currentSong { launch(song) }
            return
        }
        do { try engine?.pause(false) } catch { fail(error.localizedDescription); return }
        publishNowPlaying()
    }
    public func clearError() { errorMessage = nil }
    public func next() { advance(ended: false) }
    public func previous() {
        if position > 3 { seek(to: 0); return }
        if shuffle, let previous = history.popLast() { launch(previous); return }
        guard let song = currentSong, let index = queue.firstIndex(where: { $0.id == song.id }), !queue.isEmpty else { return }
        if index > 0 { launch(queue[index - 1]) }
        else if repeatMode == "all" { launch(queue[queue.count - 1]) }
        else { seek(to: 0) }
    }
    public func seek(to seconds: Double) {
        guard seconds.isFinite, currentSong != nil else { return }
        let target = duration > 0 ? min(duration, max(0, seconds)) : max(0, seconds)
        cacheEligible = false
        do { try engine?.seek(target) } catch { errorMessage = error.localizedDescription; return }
        position = target
        publishNowPlaying()
    }
    public func stop() {
        generation = UUID()
        transportTask?.cancel()
        transportTask = nil
        artworkTask?.cancel()
        for task in cacheTasks.values { task.cancel() }
        cacheTasks = [:]
        wantsPlayback = false
        isResolving = false
        disposeItem()
        currentSong = nil
        isPlaying = false
        isLoading = false
        position = 0
        duration = 0
        history = []
        artwork = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    private func receive(_ event: MPVEngine.Event, token: UUID) {
        guard generation == token, engine != nil else { return }
        switch event {
        case .loaded: itemReady = true
        case .position(let seconds):
            if position != seconds { position = seconds }
        case .duration(let seconds): if seconds > 0 && !usesSourceDuration && duration != seconds { duration = seconds }
        case .paused(let value): paused = value
        case .buffering(let value): buffering = value
        case .idle(let value): idle = value
        case .failed(let message): fail(message); return
        case .ended: finishPlayback(); return
        }
        let playing = itemReady && wantsPlayback && !paused && !buffering && !idle
        let loading = wantsPlayback && (isResolving || !itemReady || buffering)
        if isPlaying != playing { isPlaying = playing }
        if isLoading != loading { isLoading = loading }
        publishNowPlaying()
    }

    private func finishPlayback() {
        guard duration <= 0 || position >= max(0, duration - 1) else {
            fail("Audio ended before the expected duration. The incomplete track was not cached.")
            return
        }
        if duration > 0 { position = duration }
        let completedStream = stream
        stream = nil
        engine?.shutdown()
        engine = nil
        isPlaying = false
        isLoading = false
        itemReady = false
        if cacheEligible, let completedStream, completedStream.isComplete, let file = completedStream.fileURL, let song = currentSong {
            let account = playbackAccount
            let expectedDuration = duration
            let id = UUID()
            cacheTasks[id] = Task { [weak self, downloads, completedStream] in
                defer { completedStream.cancel(); self?.cacheTasks.removeValue(forKey: id) }
                do {
                    try await downloads.cacheCompletedPlayback(song, from: file, expectedDuration: expectedDuration, token: account)
                } catch is CancellationError {
                    return
                } catch { self?.errorMessage = "Could not cache \(song.title): \(error.localizedDescription)" }
            }
        } else { completedStream?.cancel() }
        advance(ended: true)
    }
    private func advance(ended: Bool) {
        guard let song = currentSong, !queue.isEmpty else { return }
        if ended && repeatMode == "one" { launch(song); return }
        if shuffle {
            let candidates = queue.filter { $0.id != song.id }
            if let next = candidates.randomElement() { history.append(song); launch(next) }
            else if repeatMode == "all" { launch(song) }
            else { wantsPlayback = false; isPlaying = false; publishNowPlaying() }
            return
        }
        guard let index = queue.firstIndex(where: { $0.id == song.id }) else { return }
        if index + 1 < queue.count { launch(queue[index + 1]) }
        else if repeatMode == "all" { launch(queue[0]) }
        else { wantsPlayback = false; isPlaying = false; isLoading = false; publishNowPlaying() }
    }
    private func launch(_ song: Song) {
        transportTask?.cancel()
        transportTask = Task { [weak self] in await self?.play(song) }
    }
    private func fail(_ message: String) {
        disposeItem()
        wantsPlayback = false
        isResolving = false
        isPlaying = false
        isLoading = false
        errorMessage = message
        publishNowPlaying()
    }
    private func disposeItem() {
        stream?.cancel()
        engine?.shutdown()
        engine = nil
        stream = nil
        cacheEligible = false
        usesSourceDuration = false
        itemReady = false
        paused = true
        buffering = false
        idle = true
    }
    private func publishNowPlaying() {
        guard let song = currentSong else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title, MPMediaItemPropertyArtist: song.artist,
            MPMediaItemPropertyAlbumTitle: song.album, MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }
    private func fetchArtwork(_ song: Song, token: UUID) {
        artworkTask?.cancel()
        guard let url = song.coverURL, DownloadManager.safeURL(url) else { return }
        artworkTask = Task { [weak self] in
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 15
            let session = URLSession(configuration: config, delegate: AudioRedirectGuard(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            guard let (data, raw) = try? await session.data(from: url), data.count < 10_000_000,
                  let response = raw as? HTTPURLResponse, (200...299).contains(response.statusCode),
                  response.mimeType?.hasPrefix("image/") == true, let image = NSImage(data: data),
                  let self, self.generation == token, !Task.isCancelled else { return }
            self.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.publishNowPlaying()
        }
    }
    private func registerCommands() {
        let center = MPRemoteCommandCenter.shared()
        func register(_ command: MPRemoteCommand, _ action: @escaping @MainActor (PlaybackController, MPRemoteCommandEvent) -> Void) {
            command.isEnabled = true
            let target = command.addTarget { [weak self] event in
                guard self != nil else { return .commandFailed }
                Task { @MainActor [weak self] in if let self { action(self, event) } }
                return .success
            }
            commandTargets.append((command, target))
        }
        register(center.playCommand) { controller, _ in if !controller.wantsPlayback { controller.toggle() } }
        register(center.pauseCommand) { controller, _ in if controller.wantsPlayback { controller.toggle() } }
        register(center.togglePlayPauseCommand) { controller, _ in controller.toggle() }
        register(center.nextTrackCommand) { controller, _ in controller.next() }
        register(center.previousTrackCommand) { controller, _ in controller.previous() }
        register(center.changePlaybackPositionCommand) { controller, event in
            if let seek = event as? MPChangePlaybackPositionCommandEvent { controller.seek(to: seek.positionTime) }
        }
    }
    deinit {
        transportTask?.cancel()
        artworkTask?.cancel()
        for task in cacheTasks.values { task.cancel() }
        for (command, target) in commandTargets { command.removeTarget(target) }
        stream?.cancel()
        engine?.shutdown()
    }
}
