#if canImport(CoreNFC)
import CoreNFC
import Foundation

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
                continuation.resume(throwing: ESLTransportError.unsupportedTagType)
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
            session.invalidate(errorMessage: ESLTransportError.unsupportedTagType.localizedDescription)
            finish(.failure(ESLTransportError.unsupportedTagType))
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
            throw ESLTransportError.ndefNotWritable
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

    /// Raw ESL frames are not ISO 7816-4 APDUs, and CoreNFC has no other way to send raw ISO-DEP bytes.
    func transceive(_ frame: [UInt8]) async throws -> [UInt8] {
        throw ESLTransportError.frameNotRepresentableAsAPDU(length: frame.count)
    }

    /// ISO 7816-4 APDU. CoreNFC serialises CLA INS P1 P2 Lc data itself.
    func transceiveAPDU(_ apdu: ESLFrame.APDU) async throws -> [UInt8] {
        let command = NFCISO7816APDU(
            instructionClass: apdu.cla,
            instructionCode: apdu.ins,
            p1Parameter: apdu.p1,
            p2Parameter: apdu.p2,
            data: Data(apdu.data),
            expectedResponseLength: -1
        )
        return try await withCheckedThrowingContinuation { continuation in
            tag.sendCommand(apdu: command) { data, sw1, sw2, error in
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
