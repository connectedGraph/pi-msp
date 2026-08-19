#if !canImport(CryptoKit)
import Foundation

// Portable pure-Swift digests used on platforms where CryptoKit is unavailable
// (notably Linux). Interface mirrors the CryptoKit subset consumed by
// MSPDigestAlgorithm / SortRandom: static `hash(data:)`, `init()`,
// `mutating func update(data:)`, and `finalize()` returning raw digest bytes.

private func mspPortableRotateLeft32(_ value: UInt32, _ count: UInt32) -> UInt32 {
    let normalized = count & 31
    guard normalized != 0 else {
        return value
    }
    return (value << normalized) | (value >> (32 - normalized))
}

private func mspPortableRotateRight64(_ value: UInt64, _ count: UInt64) -> UInt64 {
    let normalized = count & 63
    guard normalized != 0 else {
        return value
    }
    return (value >> normalized) | (value << (64 - normalized))
}

// MARK: - MD5 (RFC 1321)

struct MSPPortableMD5: Sendable {
    private static let k: [UInt32] = [
        0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
        0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
        0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
        0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
        0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
        0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
        0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
        0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
        0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
        0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
        0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
        0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
        0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
        0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
        0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
        0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391
    ]

    private static let shifts: [Int] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21
    ]

    private var a: UInt32 = 0x67452301
    private var b: UInt32 = 0xefcdab89
    private var c: UInt32 = 0x98badcfe
    private var d: UInt32 = 0x10325476
    private var buffer: [UInt8] = []
    private var byteCount: UInt64 = 0

    static func hash(data: Data) -> [UInt8] {
        var hasher = MSPPortableMD5()
        hasher.update(data: data)
        return hasher.finalize()
    }

    mutating func update(data: Data) {
        let bytes = [UInt8](data)
        byteCount &+= UInt64(bytes.count)
        buffer.append(contentsOf: bytes)
        while buffer.count >= 64 {
            let block = Array(buffer.prefix(64))
            compress(block)
            buffer.removeFirst(64)
        }
    }

    mutating func finalize() -> [UInt8] {
        let bitCount = byteCount &* 8
        buffer.append(0x80)
        while buffer.count % 64 != 56 {
            buffer.append(0)
        }
        // Little-endian 64-bit bit length.
        for shift in stride(from: 0, through: 56, by: 8) {
            buffer.append(UInt8((bitCount >> UInt64(shift)) & 0xff))
        }
        while buffer.count >= 64 {
            let block = Array(buffer.prefix(64))
            compress(block)
            buffer.removeFirst(64)
        }
        var result = [UInt8]()
        result.reserveCapacity(16)
        for word in [a, b, c, d] {
            result.append(UInt8(word & 0xff))
            result.append(UInt8((word >> 8) & 0xff))
            result.append(UInt8((word >> 16) & 0xff))
            result.append(UInt8((word >> 24) & 0xff))
        }
        return result
    }

    private mutating func compress(_ block: [UInt8]) {
        var m = [UInt32](repeating: 0, count: 16)
        for i in 0..<16 {
            let start = i * 4
            m[i] = UInt32(block[start])
                | (UInt32(block[start + 1]) << 8)
                | (UInt32(block[start + 2]) << 16)
                | (UInt32(block[start + 3]) << 24)
        }

        var aa = a
        var bb = b
        var cc = c
        var dd = d

        for i in 0..<64 {
            let f: UInt32
            let g: Int
            switch i / 16 {
            case 0:
                f = (bb & cc) | ((~bb) & dd)
                g = i
            case 1:
                f = (dd & bb) | ((~dd) & cc)
                g = (5 &* i &+ 1) % 16
            case 2:
                f = bb ^ cc ^ dd
                g = (3 &* i &+ 5) % 16
            default:
                f = cc ^ (bb | (~dd))
                g = (7 &* i) % 16
            }
            let temp = dd
            dd = cc
            cc = bb
            bb = bb &+ mspPortableRotateLeft32(aa &+ f &+ Self.k[i] &+ m[g], UInt32(Self.shifts[i]))
            aa = temp
        }

        a &+= aa
        b &+= bb
        c &+= cc
        d &+= dd
    }
}

// MARK: - SHA-1 (FIPS 180-4)

struct MSPPortableSHA1: Sendable {
    private static let k: [UInt32] = [
        0x5a827999, 0x6ed9eba1, 0x8f1bbcdc, 0xca62c1d6
    ]

    private var h: [UInt32] = [
        0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0
    ]
    private var buffer: [UInt8] = []
    private var byteCount: UInt64 = 0

    static func hash(data: Data) -> [UInt8] {
        var hasher = MSPPortableSHA1()
        hasher.update(data: data)
        return hasher.finalize()
    }

    mutating func update(data: Data) {
        let bytes = [UInt8](data)
        byteCount &+= UInt64(bytes.count)
        buffer.append(contentsOf: bytes)
        while buffer.count >= 64 {
            let block = Array(buffer.prefix(64))
            compress(block)
            buffer.removeFirst(64)
        }
    }

    mutating func finalize() -> [UInt8] {
        let bitCount = byteCount &* 8
        buffer.append(0x80)
        while buffer.count % 64 != 56 {
            buffer.append(0)
        }
        // Big-endian 64-bit bit length.
        for shift in stride(from: 56, through: 0, by: -8) {
            buffer.append(UInt8((bitCount >> UInt64(shift)) & 0xff))
        }
        while buffer.count >= 64 {
            let block = Array(buffer.prefix(64))
            compress(block)
            buffer.removeFirst(64)
        }
        return h.flatMap { word in
            [
                UInt8((word >> 24) & 0xff),
                UInt8((word >> 16) & 0xff),
                UInt8((word >> 8) & 0xff),
                UInt8(word & 0xff)
            ]
        }
    }

    private mutating func compress(_ block: [UInt8]) {
        var w = [UInt32](repeating: 0, count: 80)
        for i in 0..<16 {
            let start = i * 4
            w[i] = (UInt32(block[start]) << 24)
                | (UInt32(block[start + 1]) << 16)
                | (UInt32(block[start + 2]) << 8)
                | UInt32(block[start + 3])
        }
        for i in 16..<80 {
            w[i] = mspPortableRotateLeft32(
                w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16],
                1
            )
        }

        var a = h[0]
        var b = h[1]
        var c = h[2]
        var d = h[3]
        var e = h[4]

        for i in 0..<80 {
            let f: UInt32
            let roundConstant: UInt32
            switch i {
            case 0..<20:
                f = (b & c) | ((~b) & d)
                roundConstant = Self.k[0]
            case 20..<40:
                f = b ^ c ^ d
                roundConstant = Self.k[1]
            case 40..<60:
                f = (b & c) | (b & d) | (c & d)
                roundConstant = Self.k[2]
            default:
                f = b ^ c ^ d
                roundConstant = Self.k[3]
            }
            let temp = mspPortableRotateLeft32(a, 5) &+ f &+ e &+ roundConstant &+ w[i]
            e = d
            d = c
            c = mspPortableRotateLeft32(b, 30)
            b = a
            a = temp
        }

        h[0] &+= a
        h[1] &+= b
        h[2] &+= c
        h[3] &+= d
        h[4] &+= e
    }
}

// MARK: - SHA-256 (FIPS 180-4)

struct MSPPortableSHA256: Sendable {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
        0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
        0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
        0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
        0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]

    private var h: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    ]
    private var buffer: [UInt8] = []
    private var byteCount: UInt64 = 0

    static func hash(data: Data) -> [UInt8] {
        var hasher = MSPPortableSHA256()
        hasher.update(data: data)
        return hasher.finalize()
    }

    mutating func update(data: Data) {
        let bytes = [UInt8](data)
        byteCount &+= UInt64(bytes.count)
        buffer.append(contentsOf: bytes)
        while buffer.count >= 64 {
            let block = Array(buffer.prefix(64))
            compress(block)
            buffer.removeFirst(64)
        }
    }

    mutating func finalize() -> [UInt8] {
        let bitCount = byteCount &* 8
        buffer.append(0x80)
        while buffer.count % 64 != 56 {
            buffer.append(0)
        }
        // Big-endian 64-bit bit length.
        for shift in stride(from: 56, through: 0, by: -8) {
            buffer.append(UInt8((bitCount >> UInt64(shift)) & 0xff))
        }
        while buffer.count >= 64 {
            let block = Array(buffer.prefix(64))
            compress(block)
            buffer.removeFirst(64)
        }
        return h.flatMap { word in
            [
                UInt8((word >> 24) & 0xff),
                UInt8((word >> 16) & 0xff),
                UInt8((word >> 8) & 0xff),
                UInt8(word & 0xff)
            ]
        }
    }

    private mutating func compress(_ block: [UInt8]) {
        var w = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 {
            let start = i * 4
            w[i] = (UInt32(block[start]) << 24)
                | (UInt32(block[start + 1]) << 16)
                | (UInt32(block[start + 2]) << 8)
                | UInt32(block[start + 3])
        }
        for i in 16..<64 {
            let s0 = mspChecksumRotateRight(w[i - 15], 7) ^ mspChecksumRotateRight(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = mspChecksumRotateRight(w[i - 2], 17) ^ mspChecksumRotateRight(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }

        var a = h[0]
        var b = h[1]
        var c = h[2]
        var d = h[3]
        var e = h[4]
        var f = h[5]
        var g = h[6]
        var hh = h[7]

        for i in 0..<64 {
            let s1 = mspChecksumRotateRight(e, 6) ^ mspChecksumRotateRight(e, 11) ^ mspChecksumRotateRight(e, 25)
            let ch = (e & f) ^ ((~e) & g)
            let temp1 = hh &+ s1 &+ ch &+ Self.k[i] &+ w[i]
            let s0 = mspChecksumRotateRight(a, 2) ^ mspChecksumRotateRight(a, 13) ^ mspChecksumRotateRight(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = s0 &+ maj
            hh = g
            g = f
            f = e
            e = d &+ temp1
            d = c
            c = b
            b = a
            a = temp1 &+ temp2
        }

        h[0] &+= a
        h[1] &+= b
        h[2] &+= c
        h[3] &+= d
        h[4] &+= e
        h[5] &+= f
        h[6] &+= g
        h[7] &+= hh
    }
}

// MARK: - SHA-512 (FIPS 180-4)

struct MSPPortableSHA512: Sendable {
    private static let k: [UInt64] = [
        0x428a2f98d728ae22, 0x7137449123ef65cd, 0xb5c0fbcfec4d3b2f, 0xe9b5dba58189dbbc,
        0x3956c25bf348b538, 0x59f111f1b605d019, 0x923f82a4af194f9b, 0xab1c5ed5da6d8118,
        0xd807aa98a3030242, 0x12835b0145706fbe, 0x243185be4ee4b28c, 0x550c7dc3d5ffb4e2,
        0x72be5d74f27b896f, 0x80deb1fe3b1696b1, 0x9bdc06a725c71235, 0xc19bf174cf692694,
        0xe49b69c19ef14ad2, 0xefbe4786384f25e3, 0x0fc19dc68b8cd5b5, 0x240ca1cc77ac9c65,
        0x2de92c6f592b0275, 0x4a7484aa6ea6e483, 0x5cb0a9dcbd41fbd4, 0x76f988da831153b5,
        0x983e5152ee66dfab, 0xa831c66d2db43210, 0xb00327c898fb213f, 0xbf597fc7beef0ee4,
        0xc6e00bf33da88fc2, 0xd5a79147930aa725, 0x06ca6351e003826f, 0x142929670a0e6e70,
        0x27b70a8546d22ffc, 0x2e1b21385c26c926, 0x4d2c6dfc5ac42aed, 0x53380d139d95b3df,
        0x650a73548baf63de, 0x766a0abb3c77b2a8, 0x81c2c92e47edaee6, 0x92722c851482353b,
        0xa2bfe8a14cf10364, 0xa81a664bbc423001, 0xc24b8b70d0f89791, 0xc76c51a30654be30,
        0xd192e819d6ef5218, 0xd69906245565a910, 0xf40e35855771202a, 0x106aa07032bbd1b8,
        0x19a4c116b8d2d0c8, 0x1e376c085141ab53, 0x2748774cdf8eeb99, 0x34b0bcb5e19b48a8,
        0x391c0cb3c5c95a63, 0x4ed8aa4ae3418acb, 0x5b9cca4f7763e373, 0x682e6ff3d6b2b8a3,
        0x748f82ee5defb2fc, 0x78a5636f43172f60, 0x84c87814a1f0ab72, 0x8cc702081a6439ec,
        0x90befffa23631e28, 0xa4506cebde82bde9, 0xbef9a3f7b2c67915, 0xc67178f2e372532b,
        0xca273eceea26619c, 0xd186b8c721c0c207, 0xeada7dd6cde0eb1e, 0xf57d4f7fee6ed178,
        0x06f067aa72176fba, 0x0a637dc5a2c898a6, 0x113f9804bef90dae, 0x1b710b35131c471b,
        0x28db77f523047d84, 0x32caab7b40c72493, 0x3c9ebe0a15c9bebc, 0x431d67c49c100d4c,
        0x4cc5d4becb3e42b6, 0x597f299cfc657e2a, 0x5fcb6fab3ad6faec, 0x6c44198c4a475817
    ]

    private var h: [UInt64] = [
        0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
        0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179
    ]
    private var buffer: [UInt8] = []
    private var byteCount: UInt64 = 0

    static func hash(data: Data) -> [UInt8] {
        var hasher = MSPPortableSHA512()
        hasher.update(data: data)
        return hasher.finalize()
    }

    mutating func update(data: Data) {
        let bytes = [UInt8](data)
        byteCount &+= UInt64(bytes.count)
        buffer.append(contentsOf: bytes)
        while buffer.count >= 128 {
            let block = Array(buffer.prefix(128))
            compress(block)
            buffer.removeFirst(128)
        }
    }

    mutating func finalize() -> [UInt8] {
        let bitCount = byteCount &* 8
        buffer.append(0x80)
        while buffer.count % 128 != 112 {
            buffer.append(0)
        }
        // 128-bit big-endian bit length (high 64 bits are always zero here).
        for _ in 0..<8 {
            buffer.append(0)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            buffer.append(UInt8((bitCount >> UInt64(shift)) & 0xff))
        }
        while buffer.count >= 128 {
            let block = Array(buffer.prefix(128))
            compress(block)
            buffer.removeFirst(128)
        }
        return h.flatMap { word in
            [
                UInt8((word >> 56) & 0xff),
                UInt8((word >> 48) & 0xff),
                UInt8((word >> 40) & 0xff),
                UInt8((word >> 32) & 0xff),
                UInt8((word >> 24) & 0xff),
                UInt8((word >> 16) & 0xff),
                UInt8((word >> 8) & 0xff),
                UInt8(word & 0xff)
            ]
        }
    }

    private mutating func compress(_ block: [UInt8]) {
        var w = [UInt64](repeating: 0, count: 80)
        for i in 0..<16 {
            let start = i * 8
            var word: UInt64 = 0
            for byteIndex in 0..<8 {
                word = (word << 8) | UInt64(block[start + byteIndex])
            }
            w[i] = word
        }
        for i in 16..<80 {
            let s0 = mspPortableRotateRight64(w[i - 15], 1) ^ mspPortableRotateRight64(w[i - 15], 8) ^ (w[i - 15] >> 7)
            let s1 = mspPortableRotateRight64(w[i - 2], 19) ^ mspPortableRotateRight64(w[i - 2], 61) ^ (w[i - 2] >> 6)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }

        var a = h[0]
        var b = h[1]
        var c = h[2]
        var d = h[3]
        var e = h[4]
        var f = h[5]
        var g = h[6]
        var hh = h[7]

        for i in 0..<80 {
            let s1 = mspPortableRotateRight64(e, 14) ^ mspPortableRotateRight64(e, 18) ^ mspPortableRotateRight64(e, 41)
            let ch = (e & f) ^ ((~e) & g)
            let temp1 = hh &+ s1 &+ ch &+ Self.k[i] &+ w[i]
            let s0 = mspPortableRotateRight64(a, 28) ^ mspPortableRotateRight64(a, 34) ^ mspPortableRotateRight64(a, 39)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = s0 &+ maj
            hh = g
            g = f
            f = e
            e = d &+ temp1
            d = c
            c = b
            b = a
            a = temp1 &+ temp2
        }

        h[0] &+= a
        h[1] &+= b
        h[2] &+= c
        h[3] &+= d
        h[4] &+= e
        h[5] &+= f
        h[6] &+= g
        h[7] &+= hh
    }
}

// MARK: - SHA-384 (FIPS 180-4, truncated SHA-512)

struct MSPPortableSHA384: Sendable {
    private static let k = MSPPortableSHA512.roundConstants

    private var h: [UInt64] = [
        0xcbbb9d5dc1059ed8, 0x629a292a367cd507, 0x9159015a3070dd17, 0x152fecd8f70e5939,
        0x67332667ffc00b31, 0x8eb44a8768581511, 0xdb0c2e0d64f98fa7, 0x47b5481dbefa4fa4
    ]
    private var buffer: [UInt8] = []
    private var byteCount: UInt64 = 0

    static func hash(data: Data) -> [UInt8] {
        var hasher = MSPPortableSHA384()
        hasher.update(data: data)
        return hasher.finalize()
    }

    mutating func update(data: Data) {
        let bytes = [UInt8](data)
        byteCount &+= UInt64(bytes.count)
        buffer.append(contentsOf: bytes)
        while buffer.count >= 128 {
            let block = Array(buffer.prefix(128))
            compress(block)
            buffer.removeFirst(128)
        }
    }

    mutating func finalize() -> [UInt8] {
        let bitCount = byteCount &* 8
        buffer.append(0x80)
        while buffer.count % 128 != 112 {
            buffer.append(0)
        }
        for _ in 0..<8 {
            buffer.append(0)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            buffer.append(UInt8((bitCount >> UInt64(shift)) & 0xff))
        }
        while buffer.count >= 128 {
            let block = Array(buffer.prefix(128))
            compress(block)
            buffer.removeFirst(128)
        }
        return h.prefix(6).flatMap { word in
            [
                UInt8((word >> 56) & 0xff),
                UInt8((word >> 48) & 0xff),
                UInt8((word >> 40) & 0xff),
                UInt8((word >> 32) & 0xff),
                UInt8((word >> 24) & 0xff),
                UInt8((word >> 16) & 0xff),
                UInt8((word >> 8) & 0xff),
                UInt8(word & 0xff)
            ]
        }
    }

    private mutating func compress(_ block: [UInt8]) {
        var w = [UInt64](repeating: 0, count: 80)
        for i in 0..<16 {
            let start = i * 8
            var word: UInt64 = 0
            for byteIndex in 0..<8 {
                word = (word << 8) | UInt64(block[start + byteIndex])
            }
            w[i] = word
        }
        for i in 16..<80 {
            let s0 = mspPortableRotateRight64(w[i - 15], 1) ^ mspPortableRotateRight64(w[i - 15], 8) ^ (w[i - 15] >> 7)
            let s1 = mspPortableRotateRight64(w[i - 2], 19) ^ mspPortableRotateRight64(w[i - 2], 61) ^ (w[i - 2] >> 6)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }

        var a = h[0]
        var b = h[1]
        var c = h[2]
        var d = h[3]
        var e = h[4]
        var f = h[5]
        var g = h[6]
        var hh = h[7]

        for i in 0..<80 {
            let s1 = mspPortableRotateRight64(e, 14) ^ mspPortableRotateRight64(e, 18) ^ mspPortableRotateRight64(e, 41)
            let ch = (e & f) ^ ((~e) & g)
            let temp1 = hh &+ s1 &+ ch &+ Self.k[i] &+ w[i]
            let s0 = mspPortableRotateRight64(a, 28) ^ mspPortableRotateRight64(a, 34) ^ mspPortableRotateRight64(a, 39)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = s0 &+ maj
            hh = g
            g = f
            f = e
            e = d &+ temp1
            d = c
            c = b
            b = a
            a = temp1 &+ temp2
        }

        h[0] &+= a
        h[1] &+= b
        h[2] &+= c
        h[3] &+= d
        h[4] &+= e
        h[5] &+= f
        h[6] &+= g
        h[7] &+= hh
    }
}

// Expose the shared SHA-512 round constants for the truncated SHA-384 variant.
extension MSPPortableSHA512 {
    static let roundConstants = k
}
#endif
