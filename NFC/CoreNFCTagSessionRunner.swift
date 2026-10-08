#if canImport(CoreNFC)
import CoreNFC
import Foundation

/// Errors specific to the CoreNFC transport.
enum CoreNFCTransportError: LocalizedError {
    case unsupportedTagType
    case ndefNotWritable
    /// CoreNFC can only send ISO 7816-4 APDUs (`NFCISO7816APDU`). The ESL frames are raw
    /// ISO-DEP payloads whose 5th byte is a command code, not an Lc length, so they cannot
    /// be represented. See README "iOS 限制".
    case frameNotRepresentableAsAPDU(length: Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedTagType:
            return "这不是 ISO 14443-4 (IsoDep) 价签"
        case .ndefNotWritable:
            return "价签不可写 NDEF（数据连接超时）"
        case .frameNotRepresentableAsAPDU(let length):
            return "iOS CoreNFC 只能发送 ISO 7816-4 APDU，无法发送 \(length) 字节的原始 ESL 帧"
        }
    }
}

/// Runs one CoreNFC tag session and hands the tag to `ESLTagTransport` code.
final class CoreNFCTagSessionRunner: NSObject, ESLTagSessionRunner, NFCTagReaderSessionDelegate {
    private var session: NFCTagReaderSession?
    private var pendingTag: CheckedContinuation<NFCISO7816Tag, Error>?

    func withTag<T>(_ body: (ESLTagTransport) async throws -> T) async throws -> T {
        let tag = try await waitForTag()
        defer { session?.invalidate() }
        return try await body(CoreNFCTagTransport(tag: tag))
    }

    private func waitForTag() async throws -> NFCISO7816Tag {
        try await withCheckedThrowingContinuation { continuation in
            guard let session = NFCTagReaderSession(pollingOption: .iso14443, delegate: self, queue: nil) else {
                continuation.resume(throwing: CoreNFCTransportError.unsupportedTagType)
                return
            }
            pendingTag = continuation
            session.alertMessage = "将手机靠近价签"
            self.session = session
            session.begin()
        }
    }

    private func finish(_ result: Result<NFCISO7816Tag, Error>) {
        guard let continuation = pendingTag else { return }
        pendingTag = nil
        continuation.resume(with: result)
    }

    // MARK: NFCTagReaderSessionDelegate

    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        finish(.failure(error))
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard let first = tags.first else { return }
        guard case let .iso7816(tag) = first else {
            session.invalidate(errorMessage: CoreNFCTransportError.unsupportedTagType.localizedDescription)
            finish(.failure(CoreNFCTransportError.unsupportedTagType))
            return
        }
        session.connect(to: first) { [weak self] error in
            if let error {
                session.invalidate(errorMessage: error.localizedDescription)
                self?.finish(.failure(error))
            } else {
                self?.finish(.success(tag))
            }
        }
    }
}

/// `ESLTagTransport` over an `NFCISO7816Tag`.
final class CoreNFCTagTransport: ESLTagTransport {
    private let tag: NFCISO7816Tag

    init(tag: NFCISO7816Tag) {
        self.tag = tag
    }

    func writeVendorNDEF() async throws {
        let status: NFCNDEFStatus = try await withCheckedThrowingContinuation { continuation in
            tag.queryNDEFStatus { status, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: status)
                }
            }
        }
        guard status == .readWrite,
              let payload = NFCNDEFPayload.wellKnownTypeTextPayload(string: "汉朔科技E31", locale: Locale(identifier: "zh"))
        else {
            throw CoreNFCTransportError.ndefNotWritable
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            tag.writeNDEF(NFCNDEFMessage(records: [payload])) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    func transceive(_ frame: [UInt8]) async throws -> [UInt8] {
        // Returns nil for anything that is not a well-formed ISO 7816-4 APDU, which is the case
        // for every ESL frame (the Android app uses raw IsoDep.transceive).
        guard let apdu = NFCISO7816APDU(data: Data(frame)) else {
            throw CoreNFCTransportError.frameNotRepresentableAsAPDU(length: frame.count)
        }
        return try await withCheckedThrowingContinuation { continuation in
            tag.sendCommand(apdu: apdu) { data, sw1, sw2, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: [UInt8](data) + [sw1, sw2])
                }
            }
        }
    }
}
#endif
