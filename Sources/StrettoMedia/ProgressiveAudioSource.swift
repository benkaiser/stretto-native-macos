import Foundation
import Mpv
import StrettoCore

// libmpv reads on its demux thread; URLSession writes bounded chunks on its delegate queue.
final class ProgressiveAudioSource: @unchecked Sendable {
    private let condition = NSCondition()
    private let directory: URL
    private let remote: URL
    private let makeTransfer: () -> AudioTransfer
    private let identifier = UUID().uuidString
    private var writer: FileHandle?
    private var format: DownloadManager.AudioKind?
    private var received: Int64 = 0
    private var completed = false
    private var cancelled = false
    private var failure: Error?
    private var worker: Task<Void, Never>?
    private var transfer: AudioTransfer?
    private var started = false

    init(remote: URL, makeTransfer: @escaping () -> AudioTransfer = { AudioTransfer() }) throws {
        self.remote = remote
        self.makeTransfer = makeTransfer
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("stretto-stream-\(identifier)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    var failureMessage: String? { locked { failure?.localizedDescription } }
    var isComplete: Bool { locked { completed && failure == nil && !cancelled } }
    var fileURL: URL? { locked { format.map { directory.appendingPathComponent("audio.\($0.fileExtension)") } } }
    var playbackURL: URL? { locked { format.map { URL(string: "stretto-audio://\(identifier)/audio.\($0.fileExtension)")! } } }
    var receivedBytes: Int64 { locked { received } }

    func prepare() async throws -> URL {
        let shouldStart = locked { () -> Bool in
            guard !started else { return false }
            started = true
            return true
        }
        guard shouldStart else { throw StrettoError.message("This audio transfer has already started.") }
        let task = Task.detached { [self] in
            do {
                try await produce()
                locked {
                    do {
                        try writer?.synchronize()
                        try writer?.close()
                        writer = nil
                        completed = true
                    } catch { failure = error }
                    worker = nil
                    condition.broadcast()
                }
            } catch { reportFailure(error) }
        }
        locked { worker = task; if cancelled { task.cancel() } }
        return try await withTaskCancellationHandler {
            while true {
                try Task.checkCancellation()
                let state = locked { (cancelled, failure, received, playbackURLUnlocked, completed) }
                if state.0 { throw CancellationError() }
                if let error = state.1 { throw error }
                if state.2 > 0 && (state.2 >= 512 || state.4), let url = state.3 { return url }
                try await Task.sleep(for: .milliseconds(20))
            }
        } onCancel: { cancel() }
    }

    func cancel() {
        let operations = locked { () -> (Task<Void, Never>?, AudioTransfer?) in
            cancelled = true
            condition.broadcast()
            return (worker, transfer)
        }
        operations.0?.cancel()
        operations.1?.cancel()
    }

    func openReader() throws -> ProgressiveAudioReader {
        guard let fileURL else { throw StrettoError.message("Streaming audio is not ready.") }
        return try ProgressiveAudioReader(source: self, file: fileURL)
    }

    fileprivate func read(_ reader: ProgressiveAudioReader, buffer: UnsafeMutablePointer<CChar>, count: UInt64) -> Int64 {
        if count == 0 { return 0 }
        condition.lock()
        defer { condition.unlock() }
        while reader.position >= received && !completed && failure == nil && !cancelled && !reader.interrupted {
            condition.wait()
        }
        guard failure == nil && !cancelled && !reader.interrupted else { return -1 }
        let available = received - reader.position
        if available <= 0 { return 0 }
        do {
            try reader.file.seek(toOffset: UInt64(reader.position))
            guard let data = try reader.file.read(upToCount: Int(min(count, UInt64(available), 65536))), !data.isEmpty else {
                throw StrettoError.message("Streaming buffer returned incomplete audio.")
            }
            data.withUnsafeBytes { bytes in
                if let base = bytes.baseAddress { memcpy(buffer, base, data.count) }
            }
            reader.position += Int64(data.count)
            return Int64(data.count)
        } catch {
            failure = error
            condition.broadcast()
            return -1
        }
    }

    fileprivate func seek(_ reader: ProgressiveAudioReader, offset: Int64) -> Int64 {
        condition.lock()
        defer { condition.unlock() }
        guard offset >= 0 else { return Int64(MPV_ERROR_UNSUPPORTED.rawValue) }
        while offset > received && !completed && failure == nil && !cancelled && !reader.interrupted { condition.wait() }
        guard failure == nil && !cancelled && !reader.interrupted else { return Int64(MPV_ERROR_GENERIC.rawValue) }
        guard offset <= received else { return Int64(MPV_ERROR_UNSUPPORTED.rawValue) }
        reader.position = offset
        return offset
    }
    fileprivate func size() -> Int64 { locked { completed ? received : Int64(MPV_ERROR_UNSUPPORTED.rawValue) } }
    fileprivate func interrupt(_ reader: ProgressiveAudioReader) {
        locked { reader.interrupted = true; condition.broadcast() }
    }
    func reportFailure(_ error: Error) {
        let operations = locked { () -> (Task<Void, Never>?, AudioTransfer?) in
            failure = error
            let task = worker
            worker = nil
            condition.broadcast()
            return (task, transfer)
        }
        operations.0?.cancel()
        operations.1?.cancel()
    }

    private var playbackURLUnlocked: URL? {
        format.map { URL(string: "stretto-audio://\(identifier)/audio.\($0.fileExtension)")! }
    }

    private func produce() async throws {
        var manifest = Data()
        let initial = AudioHeaderSink { [self] data, kind in
            if kind == .hls {
                guard manifest.count + data.count < 2_000_000 else { throw StrettoError.message("HLS playlist exceeded the 2 MB limit.") }
                manifest.append(data)
            } else { try append(data, kind: kind) }
        }
        let response = try await fetch(remote, limit: 300 * 1024 * 1024, sink: initial)
        if initial.kind != .hls { return }
        var playlistURL = response.url
        var segments: [URL] = []
        for _ in 0..<3 {
            let parsed = try MP3HLSPlaylist(data: manifest, url: playlistURL)
            if let variant = parsed.variant {
                manifest = Data()
                let sink = AudioHeaderSink { data, kind in
                    guard kind == .hls else { throw StrettoError.message("HLS variant was not a playlist.") }
                    manifest.append(data)
                }
                let next = try await fetch(variant, limit: 2_000_000, sink: sink)
                playlistURL = next.url
            } else { segments = parsed.segments; break }
        }
        guard !segments.isEmpty else { throw StrettoError.message("HLS variant nesting limit exceeded.") }
        for segment in segments {
            try Task.checkCancellation()
            let sink = AudioHeaderSink { [self] data, kind in
                guard kind == .mp3 else { throw StrettoError.message("SoundCloud HLS segment was not complete MP3 audio.") }
                try append(data, kind: kind)
            }
            _ = try await fetch(segment, limit: 20_000_000, sink: sink)
        }
    }

    private func fetch(_ url: URL, limit: Int64, sink: AudioHeaderSink) async throws -> AudioTransfer.Result {
        try Task.checkCancellation()
        let operation = makeTransfer()
        locked { transfer = operation }
        defer { locked { transfer = nil } }
        var request = URLRequest(url: url)
        request.setValue("StrettoNative/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let result = try await operation.fetch(request, destination: nil, limit: limit, consumer: sink.receive) { _ in }
        try sink.finish()
        return result
    }

    private func append(_ data: Data, kind: DownloadManager.AudioKind) throws {
        condition.lock()
        defer { condition.unlock() }
        guard !cancelled else { throw CancellationError() }
        if let failure { throw failure }
        guard received + Int64(data.count) <= 300 * 1024 * 1024 else { throw StrettoError.message("Streaming buffer exceeded the 300 MB track limit.") }
        if writer == nil {
            format = kind
            let file = directory.appendingPathComponent("audio.\(kind.fileExtension)")
            guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw StrettoError.message("Could not create the streaming buffer.")
            }
            writer = try FileHandle(forWritingTo: file)
        }
        try writer?.write(contentsOf: data)
        received += Int64(data.count)
        condition.broadcast()
    }

    private func locked<T>(_ body: () -> T) -> T {
        condition.lock()
        defer { condition.unlock() }
        return body()
    }

    deinit {
        do {
            try writer?.close()
            try FileManager.default.removeItem(at: directory)
        } catch { NSLog("Could not remove temporary Stretto streaming buffer: %@", error.localizedDescription) }
    }
}

final class ProgressiveAudioReader {
    fileprivate let source: ProgressiveAudioSource
    fileprivate let file: FileHandle
    fileprivate var position: Int64 = 0
    fileprivate var interrupted = false
    init(source: ProgressiveAudioSource, file: URL) throws {
        self.source = source
        self.file = try FileHandle(forReadingFrom: file)
    }
    func read(buffer: UnsafeMutablePointer<CChar>, count: UInt64) -> Int64 { source.read(self, buffer: buffer, count: count) }
    func seek(_ offset: Int64) -> Int64 { source.seek(self, offset: offset) }
    func size() -> Int64 { source.size() }
    func interrupt() { source.interrupt(self) }
    func close() {
        do { try file.close() } catch { source.reportFailure(error) }
    }
}

private final class AudioHeaderSink {
    private var pending = Data()
    private(set) var kind: DownloadManager.AudioKind?
    private let emit: (Data, DownloadManager.AudioKind) throws -> Void
    init(emit: @escaping (Data, DownloadManager.AudioKind) throws -> Void) { self.emit = emit }
    func receive(_ data: Data) throws {
        if let kind { try emit(data, kind); return }
        pending.append(data)
        if pending.count >= 512 { try finish() }
    }
    func finish() throws {
        guard kind == nil else { return }
        let detected = try DownloadManager.audioKind(pending.prefix(512), mime: "")
        kind = detected
        try emit(pending, detected)
        pending = Data()
    }
}
