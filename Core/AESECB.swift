import CommonCrypto

/// AES/ECB/NoPadding, the cipher used by the Android app's `CipherFrameCodec`.
/// Key length 16, 24 or 32 bytes; input must be a multiple of 16 bytes.
enum AESECB {
    enum Failure: Error, Equatable {
        case badKeyLength(Int)
        case badBlockLength(Int)
        case cryptFailed(Int32)
    }

    private static let blockSize = 16

    static func encrypt(key: [UInt8], _ input: [UInt8]) throws -> [UInt8] {
        try run(CCOperation(kCCEncrypt), key: key, input: input)
    }

    static func decrypt(key: [UInt8], _ input: [UInt8]) throws -> [UInt8] {
        try run(CCOperation(kCCDecrypt), key: key, input: input)
    }

    private static func run(_ operation: CCOperation, key: [UInt8], input: [UInt8]) throws -> [UInt8] {
        guard [16, 24, 32].contains(key.count) else { throw Failure.badKeyLength(key.count) }
        guard input.count % blockSize == 0 else { throw Failure.badBlockLength(input.count) }
        var output = [UInt8](repeating: 0, count: input.count)
        var moved = 0
        let status = CCCrypt(
            operation,
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionECBMode),
            key, key.count,
            nil,
            input, input.count,
            &output, output.count,
            &moved
        )
        guard status == Int32(kCCSuccess) else { throw Failure.cryptFailed(status) }
        return Array(output.prefix(moved))
    }
}
