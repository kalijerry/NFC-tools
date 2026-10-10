#if canImport(CoreNFC)
import CoreNFC
import Foundation

/// The ISO 14443 tag kinds CoreNFC can hand over. Which one an ESL tag shows up as is unknown
/// until a device test: ISO 7816 if it answers SELECT for an AID in Info.plist, otherwise
/// possibly MIFARE.
enum DetectedTag {
    case iso7816(NFCISO7816Tag)
    case miFare(NFCMiFareTag)
}

/// Runs one CoreNFC tag session and hands the tag to `ESLTagTransport` code.
///
/// All session state is touched only on `queue`, which is also the delegate queue. Callbacks from
/// a session that is no longer current are ignored, so a late invalidation of an earlier session
/// cannot resume the next caller.
final class CoreNFCTagSessionRunner: NSObject, ESLTagSessionRunner, NFCTagReaderSessionDelegate {
    private typealias Detection = (NFCTagReaderSession, DetectedTag)

    private let queue = DispatchQueue(label: "PengPengHeartbeat.NFCSession")
    private var session: NFCTagReaderSession?
    private var pendingTag: CheckedContinuation<Detection, Error>?

    func withTag<T>(_ body: (ESLTagTransport) async throws -> T) async throws -> T {
        let (session, tag) = try await waitForTag()
        do {
            let result = try await body(CoreNFCTagTransport(tag: tag))
            end(session, errorMessage: nil)
            return result
        } catch {
            end(session, errorMessage: error.localizedDescription)
            throw error
        }
    }

    private func waitForTag() async throws -> Detection {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard NFCTagReaderSession.readingAvailable else {
                    continuation.resume(throwing: ESLTransportError.nfcUnavailable)
                    return
                }
                guard self.pendingTag == nil else {
                    continuation.resume(throwing: ESLTransportError.sessionBusy)
                    return
                }
                guard let session = NFCTagReaderSession(pollingOption: .iso14443, delegate: self, queue: self.queue) else {
                    continuation.resume(throwing: ESLTransportError.nfcUnavailable)
                    return
                }
                self.pendingTag = continuation
                self.session = session
                session.alertMessage = "将手机靠近价签"
                session.begin()
            }
        }
    }

    /// Closes the session. A failure shows the error style on the system sheet.
    private func end(_ session: NFCTagReaderSession, errorMessage: String?) {
        queue.async {
            if let errorMessage {
                session.invalidate(errorMessage: errorMessage)
            } else {
                session.alertMessage = "完成"
                session.invalidate()
            }
            if self.session === session {
                self.session = nil
            }
        }
    }

    /// Must run on `queue`.
    private func finish(_ session: NFCTagReaderSession, _ result: Result<Detection, Error>) {
        guard session === self.session, let continuation = pendingTag else { return }
        pendingTag = nil
        continuation.resume(with: result)
    }

    // MARK: NFCTagReaderSessionDelegate (delivered on `queue`)

    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        guard session === self.session else { return }
        finish(session, .failure(error))
        self.session = nil
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard session === self.session else { return }
        if tags.count > 1 {
            session.alertMessage = "检测到多个标签，请只靠近一个价签"
            queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, session === self.session else { return }
                session.restartPolling()
            }
            return
        }
        guard let first = tags.first else { return }
        let detected: DetectedTag
        switch first {
        case let .iso7816(tag):
            detected = .iso7816(tag)
        case let .miFare(tag):
            detected = .miFare(tag)
        default:
            session.invalidate(errorMessage: ESLTransportError.unsupportedTagType.localizedDescription)
            finish(session, .failure(ESLTransportError.unsupportedTagType))
            self.session = nil
            return
        }
        session.connect(to: first) { [weak self] error in
            guard let self else { return }
            self.queue.async {
                if let error {
                    session.invalidate(errorMessage: error.localizedDescription)
                    self.finish(session, .failure(error))
                } else {
                    self.finish(session, .success((session, detected)))
                }
            }
        }
    }
}

/// `ESLTagTransport` over whichever tag kind CoreNFC detected.
final class CoreNFCTagTransport: ESLTagTransport {
    private let tag: DetectedTag
    private var ndefNote = "NDEF 未写入"

    init(tag: DetectedTag) {
        self.tag = tag
    }

    var tagSummary: String {
        let kind: String
        switch tag {
        case .iso7816(let iso):
            kind = "ISO 7816 标签，AID \(iso.initialSelectedAID)，UID \(Self.hex(iso.identifier))，"
                + "historical \(Self.hex(iso.historicalBytes))，appData \(Self.hex(iso.applicationData))"
        case .miFare(let mifare):
            kind = "MIFARE 标签（\(Self.familyName(mifare.mifareFamily))），UID \(Self.hex(mifare.identifier))，"
                + "historical \(Self.hex(mifare.historicalBytes))"
        }
        return "\(kind)；\(ndefNote)"
    }

    private var ndefTag: NFCNDEFTag {
        switch tag {
        case .iso7816(let iso): return iso
        case .miFare(let mifare): return mifare
        }
    }

    /// Android aborts the session when this write fails. Here the failure is recorded in the summary
    /// and the session continues, so a device test still shows whether the ESL frames get through.
    func writeVendorNDEF() async throws {
        do {
            try await writeNDEFRecord()
            ndefNote = "NDEF 写入成功"
        } catch {
            ndefNote = "NDEF 写入失败（\(error.localizedDescription)），继续发送帧"
        }
    }

    private func writeNDEFRecord() async throws {
        let target = ndefTag
        let status: NFCNDEFStatus = try await withCheckedThrowingContinuation { continuation in
            target.queryNDEFStatus { status, _, error in
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
            target.writeNDEF(NFCNDEFMessage(records: [payload])) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    /// Raw ESL frames. On an ISO 7816 tag CoreNFC has no raw path, so this throws.
    /// On a MIFARE tag, sendMiFareCommand passes the bytes without APDU framing. Whether the ESL
    /// firmware answers that the way it answers Android's IsoDep.transceive is untested.
    func transceive(_ frame: [UInt8]) async throws -> [UInt8] {
        switch tag {
        case .iso7816:
            throw ESLTransportError.frameNotRepresentableAsAPDU(length: frame.count)
        case .miFare(let mifare):
            return try await withCheckedThrowingContinuation { continuation in
                mifare.sendMiFareCommand(commandPacket: Data(frame)) { data, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: [UInt8](data))
                    }
                }
            }
        }
    }

    /// ISO 7816-4 APDU. CoreNFC serialises CLA INS P1 P2 Lc data itself (expectedResponseLength -1:
    /// no Le byte, the closest match to the raw frame bytes).
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
            let completion: (Data, UInt8, UInt8, Error?) -> Void = { data, sw1, sw2, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: [UInt8](data) + [sw1, sw2])
                }
            }
            switch tag {
            case .iso7816(let iso):
                iso.sendCommand(apdu: command, completionHandler: completion)
            case .miFare(let mifare):
                mifare.sendMiFareISO7816Command(command, completionHandler: completion)
            }
        }
    }

    private static func hex(_ data: Data?) -> String {
        guard let data, !data.isEmpty else { return "无" }
        return data.map { String(format: "%02X", $0) }.joined()
    }

    private static func familyName(_ family: NFCMiFareFamily) -> String {
        switch family {
        case .unknown: return "unknown"
        case .ultralight: return "Ultralight"
        case .plus: return "Plus"
        case .desfire: return "DESFire"
        @unknown default: return "family \(family.rawValue)"
        }
    }
}
#endif
