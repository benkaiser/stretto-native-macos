import Foundation
import Mpv
import StrettoCore

final class MPVEngine {
    enum Event: Sendable {
        case loaded, ended
        case position(Double), duration(Double)
        case paused(Bool), buffering(Bool), idle(Bool)
        case failed(String)
    }

    private let queue = DispatchQueue(label: "dev.benkaiser.stretto.audio")
    private let queueKey = DispatchSpecificKey<Void>()
    private var handle: OpaquePointer?
    private let onEvent: (Event) -> Void
    private let source: ProgressiveAudioSource?
    private var loaded = false
    private var failure: String?

    init(volume: Double, silentOutput: Bool = false, source: ProgressiveAudioSource? = nil, onEvent: @escaping (Event) -> Void) throws {
        self.onEvent = onEvent
        self.source = source
        queue.setSpecific(key: queueKey, value: ())
        guard let context = mpv_create() else { throw StrettoError.message("Could not create the audio player.") }
        handle = context
        do {
            for (name, value) in [
                ("config", "no"), ("video", "no"), ("idle", "yes"), ("terminal", "no"),
                ("input-default-bindings", "no"),
                ("input-vo-keyboard", "no"), ("keep-open", "no"), ("cache", "yes"),
                ("cache-secs", "20"), ("demuxer-max-bytes", "16MiB"), ("demuxer-max-back-bytes", "4MiB"),
                ("tls-verify", "yes"), ("tls-ca-file", "/etc/ssl/cert.pem"),
                ("volume", String(volume * 100)), ("ao", silentOutput ? "null" : "coreaudio")
            ] {
                try Self.check(mpv_set_option_string(context, name, value), action: "Configure \(name)")
            }
            try Self.check(mpv_initialize(context), action: "Initialize audio playback")
            if let source {
                try Self.check(mpv_stream_cb_add_ro(context, "stretto-audio", Unmanaged.passUnretained(source).toOpaque(), { pointer, uri, info in
                    guard let pointer, let uri, let info else { return MPV_ERROR_LOADING_FAILED.rawValue }
                    let source = Unmanaged<ProgressiveAudioSource>.fromOpaque(pointer).takeUnretainedValue()
                    guard String(cString: uri) == source.playbackURL?.absoluteString else { return MPV_ERROR_LOADING_FAILED.rawValue }
                    do {
                        let reader = try source.openReader()
                        info.pointee.cookie = Unmanaged.passRetained(reader).toOpaque()
                        info.pointee.read_fn = { cookie, buffer, count in
                            guard let cookie, let buffer else { return -1 }
                            return Unmanaged<ProgressiveAudioReader>.fromOpaque(cookie).takeUnretainedValue().read(buffer: buffer, count: count)
                        }
                        info.pointee.seek_fn = { cookie, offset in
                            guard let cookie else { return Int64(MPV_ERROR_GENERIC.rawValue) }
                            return Unmanaged<ProgressiveAudioReader>.fromOpaque(cookie).takeUnretainedValue().seek(offset)
                        }
                        info.pointee.size_fn = { cookie in
                            guard let cookie else { return Int64(MPV_ERROR_GENERIC.rawValue) }
                            return Unmanaged<ProgressiveAudioReader>.fromOpaque(cookie).takeUnretainedValue().size()
                        }
                        info.pointee.cancel_fn = { cookie in
                            guard let cookie else { return }
                            Unmanaged<ProgressiveAudioReader>.fromOpaque(cookie).takeUnretainedValue().interrupt()
                        }
                        info.pointee.close_fn = { cookie in
                            guard let cookie else { return }
                            Unmanaged<ProgressiveAudioReader>.fromOpaque(cookie).takeRetainedValue().close()
                        }
                        return 0
                    } catch {
                        source.reportFailure(error)
                        return MPV_ERROR_LOADING_FAILED.rawValue
                    }
                }), action: "Register streaming audio")
            }
            for (index, property) in ["time-pos", "duration", "pause", "paused-for-cache", "core-idle"].enumerated() {
                let format = index < 2 ? MPV_FORMAT_DOUBLE : MPV_FORMAT_FLAG
                try Self.check(mpv_observe_property(context, UInt64(index + 1), property, format), action: "Observe \(property)")
            }
            mpv_set_wakeup_callback(context, { pointer in
                guard let pointer else { return }
                Unmanaged<MPVEngine>.fromOpaque(pointer).takeUnretainedValue().scheduleEvents()
            }, Unmanaged.passUnretained(self).toOpaque())
        } catch {
            mpv_terminate_destroy(context)
            handle = nil
            throw error
        }
    }

    func load(_ url: URL, paused: Bool) throws {
        try queue.sync {
            guard let handle else { throw StrettoError.message("The audio player has stopped.") }
            loaded = false
            failure = nil
            try Self.check(mpv_set_property_string(handle, "pause", paused ? "yes" : "no"), action: "Set playback state")
            try command(["loadfile", url.isFileURL ? url.path : url.absoluteString, "replace"], handle: handle)
        }
    }

    func pause(_ paused: Bool) throws { try set("pause", paused ? "yes" : "no") }
    func setVolume(_ volume: Double) throws { try set("volume", String(volume * 100)) }
    func seek(_ seconds: Double) throws {
        try queue.sync {
            guard let handle else { throw StrettoError.message("The audio player has stopped.") }
            try command(["seek", String(seconds), "absolute+exact"], handle: handle)
        }
    }

    func shutdown() {
        if DispatchQueue.getSpecific(key: queueKey) != nil { destroy() }
        else { queue.sync { destroy() } }
    }

    private func destroy() {
        guard let context = handle else { return }
        handle = nil
        mpv_set_wakeup_callback(context, nil, nil)
        mpv_terminate_destroy(context)
    }

    @MainActor
    static func inspectFile(_ url: URL) async throws -> Double {
        let engine = try MPVEngine(volume: 0, silentOutput: true) { _ in }
        defer { engine.shutdown() }
        try engine.load(url, paused: true)
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            try Task.checkCancellation()
            let status = engine.queue.sync { () -> (Bool, String?, Double) in
                var duration = 0.0
                if let handle = engine.handle {
                    let result = mpv_get_property(handle, "duration", MPV_FORMAT_DOUBLE, &duration)
                    if result < 0 { duration = 0 }
                }
                return (engine.loaded, engine.failure, duration)
            }
            if let error = status.1 { throw StrettoError.message(error) }
            if status.0 && status.2.isFinite && status.2 > 0 { return status.2 }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw StrettoError.message("Downloaded audio did not contain a playable, finite track.")
    }

    private func set(_ name: String, _ value: String) throws {
        try queue.sync {
            guard let handle else { throw StrettoError.message("The audio player has stopped.") }
            try Self.check(mpv_set_property_string(handle, name, value), action: "Set \(name)")
        }
    }

    private func command(_ arguments: [String], handle: OpaquePointer) throws {
        var copies: [UnsafeMutablePointer<CChar>] = []
        defer { for copy in copies { free(copy) } }
        for argument in arguments {
            guard let copy = strdup(argument) else { throw StrettoError.message("Not enough memory for audio playback.") }
            copies.append(copy)
        }
        var pointers = copies.map { Optional(UnsafePointer($0)) }
        pointers.append(nil)
        let result = pointers.withUnsafeMutableBufferPointer { mpv_command(handle, $0.baseAddress) }
        try Self.check(result, action: arguments.first ?? "Audio command")
    }

    private func scheduleEvents() {
        queue.async { [weak self] in self?.drainEvents() }
    }

    private func drainEvents() {
        guard let handle else { return }
        while let pointer = mpv_wait_event(handle, 0), pointer.pointee.event_id != MPV_EVENT_NONE {
            let event = pointer.pointee
            switch event.event_id {
            case MPV_EVENT_FILE_LOADED:
                loaded = true
                onEvent(.loaded)
            case MPV_EVENT_END_FILE:
                guard let data = event.data else { continue }
                let end = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                if end.reason == MPV_END_FILE_REASON_EOF {
                    if let message = source?.failureMessage { failure = message; onEvent(.failed(message)) }
                    else { onEvent(.ended) }
                }
                else if end.reason == MPV_END_FILE_REASON_ERROR {
                    let message = source?.failureMessage ?? Self.message(end.error, action: "Play audio stream")
                    failure = message
                    onEvent(.failed(message))
                }
            case MPV_EVENT_PROPERTY_CHANGE:
                guard let data = event.data else { continue }
                let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
                guard let name = property.name, let value = property.data else { continue }
                let key = String(cString: name)
                if property.format == MPV_FORMAT_DOUBLE {
                    let number = value.assumingMemoryBound(to: Double.self).pointee
                    guard number.isFinite else { continue }
                    if key == "time-pos" { onEvent(.position(max(0, number))) }
                    else if key == "duration" { onEvent(.duration(max(0, number))) }
                } else if property.format == MPV_FORMAT_FLAG {
                    let flag = value.assumingMemoryBound(to: Int32.self).pointee != 0
                    if key == "pause" { onEvent(.paused(flag)) }
                    else if key == "paused-for-cache" { onEvent(.buffering(flag)) }
                    else if key == "core-idle" { onEvent(.idle(flag)) }
                }
            default: break
            }
        }
    }

    private static func check(_ result: Int32, action: String) throws {
        guard result >= 0 else { throw StrettoError.message(message(result, action: action)) }
    }
    private static func message(_ result: Int32, action: String) -> String {
        "\(action): \(String(cString: mpv_error_string(result)))."
    }

    deinit { shutdown() }
}
