import Foundation

/// Failures the transport can report without knowing which NFC stack is underneath.
enum ESLTransportError: LocalizedError, Equatable {
    case nfcUnavailable
    case sessionBusy
    case unsupportedTagType
    /// CoreNFC's queryNDEFStatus did not report readWrite. The raw NFCNDEFStatus value is kept
    /// (1 notSupported, 2 readWrite, 3 readOnly).
    case ndefNotWritable(status: Int)
    case ndefPayloadUnavailable
    /// CoreNFC only sends ISO 7816-4 APDUs. The raw ESL frames are not APDUs (their 5th byte is
    /// a command code, not Lc), so they cannot be sent with `transceive`. Use `transceiveAPDU`.
    case frameNotRepresentableAsAPDU(length: Int)

    var errorDescription: String? {
        switch self {
        case .nfcUnavailable:
            return "这台设备不支持 NFC 标签读取"
        case .sessionBusy:
            return "上一个 NFC 会话还没有结束"
        case .unsupportedTagType:
            return "这不是 ISO 14443-4 (IsoDep) 价签"
        case .ndefNotWritable(let status):
            let name = [1: "notSupported", 2: "readWrite", 3: "readOnly"][status] ?? "unknown"
            return "CoreNFC 报告 NDEF 状态 \(name)（\(status)），不可写"
        case .ndefPayloadUnavailable:
            return "无法构造 NDEF 文本记录"
        case .frameNotRepresentableAsAPDU(let length):
            return "iOS CoreNFC 对 ISO 7816 标签只能发送 APDU，无法发送 \(length) 字节的原始 ESL 帧"
        }
    }
}
