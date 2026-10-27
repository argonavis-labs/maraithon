import Foundation
import Compression

/// Tiny gzip encoder used by `MaraithonClient` to keep upload sizes
/// reasonable. We avoid pulling in a third-party dep by combining
/// `Compression.framework`'s raw deflate with the gzip header / CRC32 /
/// ISIZE framing the HTTP spec requires.
enum Gzip {
    enum Error: Swift.Error {
        case compressionFailed
    }

    static func compress(_ data: Data) throws -> Data {
        let deflated = try deflate(data)
        var out = Data()
        out.append(contentsOf: gzipHeader)
        out.append(deflated)
        out.append(contentsOf: crc32(data).littleEndianBytes)
        out.append(contentsOf: UInt32(truncatingIfNeeded: data.count).littleEndianBytes)
        return out
    }

    /// Inverse of `compress`. Strips the gzip header / CRC32 / ISIZE
    /// trailer and inflates the raw deflate payload. Used by tests that
    /// want to round-trip a posted body back to its decoded form; the
    /// production client only writes gzip and never reads it.
    ///
    /// Conservative on header parsing: rejects anything that isn't a
    /// "well-known" no-flags gzip stream because we control both the
    /// encoder and the only known consumer (tests). Strict matching here
    /// is cheaper than a permissive parser that silently mis-frames a
    /// future bug.
    static func decompress(_ data: Data) throws -> Data {
        // Minimum gzip envelope: 10-byte header + 8-byte trailer.
        guard data.count >= 18 else { throw Error.compressionFailed }
        let bytes = Array(data)
        guard bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 0x08 else {
            throw Error.compressionFailed
        }
        // We always emit FLG=0, so any flag bits mean a stream we didn't
        // produce — bail rather than guess.
        guard bytes[3] == 0x00 else { throw Error.compressionFailed }
        let payload = Data(bytes[10..<(bytes.count - 8)])
        return try inflate(payload, originalSize: Int(isize(bytes: bytes)))
    }

    // MARK: - Internals

    private static let gzipHeader: [UInt8] = [
        0x1f, 0x8b,         // magic
        0x08,               // method = deflate
        0x00,               // flags
        0x00, 0x00, 0x00, 0x00, // mtime
        0x00,               // xfl
        0xff                // os = unknown
    ]

    /// Raw deflate (no zlib header/trailer). `Compression.framework`'s
    /// `COMPRESSION_ZLIB` algorithm emits raw deflate — the `zlib`-named
    /// constant in the Compression framework is actually raw deflate
    /// (see Apple's docs), which is exactly what we need to wrap in gzip
    /// framing ourselves.
    private static func deflate(_ data: Data) throws -> Data {
        let destinationBufferSize = max(data.count + 64, 64)
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: destinationBufferSize)
        defer { destination.deallocate() }

        return try data.withUnsafeBytes { rawBuffer -> Data in
            guard let baseAddress = rawBuffer.baseAddress else {
                if data.isEmpty {
                    // Compressing empty data still needs a valid empty deflate
                    // stream. Use one empty stored block: 0x03 0x00 isn't
                    // strictly required because we always pass a non-empty
                    // body in practice, but be safe.
                    return Data([0x03, 0x00])
                }
                throw Error.compressionFailed
            }
            let source = baseAddress.assumingMemoryBound(to: UInt8.self)
            let written = compression_encode_buffer(
                destination, destinationBufferSize,
                source, data.count,
                nil, COMPRESSION_ZLIB
            )
            guard written > 0 else { throw Error.compressionFailed }
            return Data(bytes: destination, count: written)
        }
    }

    /// Raw-deflate inflator paired with `deflate`. `originalSize` comes
    /// from the gzip trailer's ISIZE field, which is the uncompressed
    /// size mod 2^32; for the bodies we ship (well under 4GB) it's the
    /// true size and a perfect buffer hint.
    private static func inflate(_ data: Data, originalSize: Int) throws -> Data {
        // Round up to avoid a zero-sized buffer when the payload is
        // empty (unlikely in practice, but defensive).
        let destinationBufferSize = max(originalSize, max(data.count * 4, 64))
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: destinationBufferSize)
        defer { destination.deallocate() }

        return try data.withUnsafeBytes { rawBuffer -> Data in
            guard let baseAddress = rawBuffer.baseAddress, !data.isEmpty else {
                return Data()
            }
            let source = baseAddress.assumingMemoryBound(to: UInt8.self)
            let written = compression_decode_buffer(
                destination, destinationBufferSize,
                source, data.count,
                nil, COMPRESSION_ZLIB
            )
            guard written > 0 else { throw Error.compressionFailed }
            return Data(bytes: destination, count: written)
        }
    }

    private static func isize(bytes: [UInt8]) -> UInt32 {
        let tail = bytes.suffix(4)
        var value: UInt32 = 0
        for (i, byte) in tail.enumerated() {
            value |= UInt32(byte) << (8 * i)
        }
        return value
    }

    /// CRC-32 (IEEE 802.3 polynomial) over the uncompressed bytes.
    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                let mask: UInt32 = (crc & 1) != 0 ? 0xFFFF_FFFF : 0
                crc = (crc >> 1) ^ (0xEDB8_8320 & mask)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension UInt32 {
    var littleEndianBytes: [UInt8] {
        [
            UInt8(truncatingIfNeeded: self),
            UInt8(truncatingIfNeeded: self >> 8),
            UInt8(truncatingIfNeeded: self >> 16),
            UInt8(truncatingIfNeeded: self >> 24)
        ]
    }
}
