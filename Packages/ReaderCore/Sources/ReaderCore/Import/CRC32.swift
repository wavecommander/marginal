import Foundation

/// CRC-32 (IEEE 802.3, reflected polynomial 0xEDB88320) as used by ZIP. Incremental:
/// `var crc = CRC32(); crc.update(chunk); … crc.value`.
public struct CRC32: Sendable, Hashable {
    private var state: UInt32 = 0xFFFF_FFFF

    public init() {}

    /// The checksum of everything passed to `update` so far.
    public var value: UInt32 { state ^ 0xFFFF_FFFF }

    public mutating func update(_ data: Data) {
        data.withUnsafeBytes { update(UnsafeRawBufferPointer($0)) }
    }

    public mutating func update(_ bytes: UnsafeRawBufferPointer) {
        var crc = state
        let table = CRC32.table
        for byte in bytes {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        state = crc
    }

    /// The checksum of `data` in one go.
    public static func checksum(_ data: Data) -> UInt32 {
        var crc = CRC32()
        crc.update(data)
        return crc.value
    }

    private static let table: [UInt32] = (0..<256).map { index in
        var c = UInt32(index)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }
}
