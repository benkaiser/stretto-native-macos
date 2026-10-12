import Foundation

final class GatedAudioProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var audio = Data()
    private static var request: GatedAudioProtocol?
    private static var sent = 0
    private static var failures = false
    private static var hls = false
    static let url = URL(string: "https://audio-fixture.sndcdn.com/silence.webm")!

    static var sentBytes: Int { lock.withLock { sent } }
    static var totalBytes: Int { lock.withLock { audio.count } }
    static func reset(audio: Data, hls: Bool = false) {
        lock.withLock { self.audio = audio; request = nil; sent = 0; failures = false; self.hls = hls }
    }
    static func releaseRemainder() {
        let payload = lock.withLock { () -> (GatedAudioProtocol, Data)? in
            guard let request else { return nil }
            let remainder = Data(audio.dropFirst(sent))
            sent = audio.count
            self.request = nil
            return (request, remainder)
        }
        guard let (request, remainder) = payload else { return }
        request.client?.urlProtocol(request, didLoad: Data(remainder))
        request.client?.urlProtocolDidFinishLoading(request)
    }
    static func failTransfer() {
        let active = lock.withLock { () -> GatedAudioProtocol? in
            failures = true
            let active = request
            request = nil
            return active
        }
        if let active { active.client?.urlProtocol(active, didFailWithError: URLError(.networkConnectionLost)) }
    }
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == url.host && [url.path, "/first.mp3", "/second.mp3"].contains(request.url?.path ?? "")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let hlsAudio = Self.lock.withLock { Self.hls ? Self.audio : nil }
        if let hlsAudio {
            let isManifest = request.url?.path == Self.url.path
            let isFirst = request.url?.path == "/first.mp3"
            let manifest = Data("#EXTM3U\n#EXT-X-TARGETDURATION:3\n#EXTINF:2.012,\nfirst.mp3\n#EXTINF:2.012,\nsecond.mp3\n#EXT-X-ENDLIST\n".utf8)
            let data = isManifest ? manifest : isFirst ? Data(hlsAudio.prefix(hlsAudio.count / 2)) : Data(hlsAudio.dropFirst(hlsAudio.count / 2))
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Type": isManifest ? "application/vnd.apple.mpegurl" : "audio/mpeg", "Content-Length": String(data.count)
            ])!
            if !isManifest {
                Self.lock.withLock {
                    if isFirst { Self.sent = data.count } else { Self.request = self }
                }
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if isManifest || isFirst {
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            }
            return
        }
        let payload = Self.lock.withLock { () -> (Data, Int, Bool) in
            Self.request = self
            Self.sent = Self.audio.count / 2
            return (Data(Self.audio.prefix(Self.sent)), Self.audio.count, Self.failures)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": "audio/webm", "Content-Length": String(payload.1)
        ])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload.0)
        if payload.2 { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)) }
    }
    override func stopLoading() {
        Self.lock.withLock { if Self.request === self { Self.request = nil } }
    }
}
