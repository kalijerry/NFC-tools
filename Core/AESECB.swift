import CommonCrypto
import Foundation

/// AES/ECB/NoPadding, the cipher used by the Android app's `CipherFrameCodec`.
/// Key length 16, 24 or 32 bytes; input must be a multiple of 16 bytes.
enum AESECB {
    enum Failure: LocalizedError, Equatable {
        case badKeyLength(Int)
        case badBlockLength(Int)
        case cryptFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .badKeyLength(let count):
                return "AES 密钥长度错误（\(count) 字节，需要 16/24/32）"
            case .badBlockLength(let count):
                return "AES 输入不是 16 字节的整数倍（\(count) 字节）"
            case .cryptFailed(let status):
                return "AES 运算失败（CommonCrypto 状态 \(status)）"
            }
        }
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
