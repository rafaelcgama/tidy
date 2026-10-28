import Foundation

/// A fast, non-cryptographic 64-bit hash of file contents. Only used to bucket candidates:
/// duplicates are always confirmed byte by byte, so a collision costs time, never correctness.
struct ContentHash {
    private var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    private var carry: [UInt8] = []
    private var length: UInt64 = 0

    mutating func update(_ data: Data) {
        length &+= UInt64(data.count)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            // Finish a word left over from the previous chunk, so chunk boundaries don't change the hash.
            if !carry.isEmpty {
                while carry.count < 8, offset < raw.count {
                    carry.append(raw[offset])
                    offset += 1
                }
                if carry.count == 8 {
                    mix(carry.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) })
                    carry.removeAll(keepingCapacity: true)
                }
            }
            while offset + 8 <= raw.count {
                mix(raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
                offset += 8
            }
            while offset < raw.count {
                carry.append(raw[offset])
                offset += 1
            }
        }
    }

    func finalize() -> UInt64 {
        var copy = self
        if !copy.carry.isEmpty {
            var tail: UInt64 = 0
            for (index, byte) in copy.carry.enumerated() {
                tail |= UInt64(byte) << (8 * UInt64(index))
            }
            copy.mix(tail)
        }
        copy.mix(copy.length)
        // splitmix64 finalizer
        var z = copy.state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    private mutating func mix(_ word: UInt64) {
        state = (state ^ word) &* 0xFF51_AFD7_ED55_8CCD
        state ^= state >> 32
    }
}

enum ContentHasher {
    static let chunkSize = 1 << 20
    static let edgeSize = 64 * 1024

    /// Hash of the first and last 64 KB: a cheap way to split same-size files.
    static func quickHash(of url: URL, size: Int64) throws -> UInt64 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = ContentHash()
        hash.update(try handle.read(upToCount: edgeSize) ?? Data())
        if size > Int64(edgeSize * 2) {
            try handle.seek(toOffset: UInt64(size) - UInt64(edgeSize))
            hash.update(try handle.read(upToCount: edgeSize) ?? Data())
        }
        return hash.finalize()
    }

    static func fullHash(of url: URL) throws -> UInt64 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = ContentHash()
        while true {
            if Task.isCancelled { throw CancellationError() }
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            hash.update(chunk)
        }
        return hash.finalize()
    }

    static func sameContents(_ a: URL, _ b: URL) throws -> Bool {
        let first = try FileHandle(forReadingFrom: a)
        defer { try? first.close() }
        let second = try FileHandle(forReadingFrom: b)
        defer { try? second.close() }
        while true {
            if Task.isCancelled { throw CancellationError() }
            let left = try first.read(upToCount: chunkSize) ?? Data()
            let right = try second.read(upToCount: chunkSize) ?? Data()
            if left != right { return false }
            if left.isEmpty { return true }
        }
    }
}
