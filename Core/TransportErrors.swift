import Foundation

/// Failures the transport can report without knowing which NFC stack is underneath.
enum ESLTransportError: LocalizedError, Equatable {
    case unsupportedTagType
    case ndefNotWritable
    /// CoreNFC only sends ISO 7816-4 APDUs. The raw ESL frames are not APDUs (their 5th byte is
    /// a command code, not Lc), so they cannot be sent with `transceive`. Use `transceiveAPDU`.
    case frameNotRepresentableAsAPDU(length: Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedTagType:
            return "这不是 ISO 14443-4 (IsoDep) 价签"
        case .ndefNotWritable:
            return "价签不可写 NDEF（数据连接超时）"
        case .frameNotRepresentableAsAPDU(let length):
            return "iOS CoreNFC 只能发送 ISO 7816-4 APDU，无法直接发送 \(length) 字节的原始 ESL 帧"
        }
    }
}
