import Foundation

enum WebMFixture {
    static func audio(seconds: Int) -> Data {
        let header = element(0x1a45dfa3,
            integer(0x4286, 1) + integer(0x42f7, 1) + integer(0x42f2, 4) +
            integer(0x42f3, 8) + element(0x4282, Data("webm".utf8)) +
            integer(0x4287, 4) + integer(0x4285, 2))
        let info = element(0x1549a966,
            integer(0x2ad7b1, 1_000_000) + float(0x4489, Double(seconds * 1000)) +
            element(0x4d80, Data("Stretto test".utf8)) + element(0x5741, Data("Stretto test".utf8)))
        let opusHead = Data("OpusHead".utf8) + Data([1, 1, 0, 0, 0x80, 0xbb, 0, 0, 0, 0, 0])
        let track = element(0x1654ae6b, element(0xae,
            integer(0xd7, 1) + integer(0x73c5, 1) + integer(0x83, 2) +
            element(0x86, Data("A_OPUS".utf8)) + element(0x63a2, opusHead) +
            integer(0x56aa, 0) + integer(0x56bb, 80_000_000) +
            element(0xe1, float(0xb5, 48_000) + integer(0x9f, 1))))
        var clusters = Data()
        for second in 0..<seconds {
            var blocks = integer(0xe7, UInt64(second * 1000))
            for frame in 0..<50 {
                let time = UInt16(frame * 20)
                // A standard Opus silence packet; no copyrighted audio fixture.
                blocks += element(0xa3, Data([0x81, UInt8(time >> 8), UInt8(time & 255), 0x80, 0xf8, 0xff, 0xfe]))
            }
            clusters += element(0x1f43b675, blocks)
        }
        return header + element(0x18538067, info + track + clusters)
    }

    private static func integer(_ id: UInt32, _ value: UInt64) -> Data {
        var number = value
        var bytes: [UInt8] = [UInt8(number & 255)]
        number >>= 8
        while number > 0 { bytes.insert(UInt8(number & 255), at: 0); number >>= 8 }
        return element(id, Data(bytes))
    }
    private static func float(_ id: UInt32, _ value: Double) -> Data {
        var bits = value.bitPattern.bigEndian
        return element(id, withUnsafeBytes(of: &bits) { Data($0) })
    }
    private static func element(_ id: UInt32, _ payload: Data) -> Data {
        var identifier = id
        var bytes: [UInt8] = [UInt8(identifier & 255)]
        identifier >>= 8
        while identifier > 0 { bytes.insert(UInt8(identifier & 255), at: 0); identifier >>= 8 }
        let length = UInt64(payload.count)
        var width = 1
        while length >= (UInt64(1) << (width * 7)) - 1 { width += 1 }
        let encoded = length | (UInt64(1) << (width * 7))
        for index in (0..<width).reversed() { bytes.append(UInt8((encoded >> (index * 8)) & 255)) }
        return Data(bytes) + payload
    }
}
