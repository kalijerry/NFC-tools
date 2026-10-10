#if canImport(CoreNFC)
import CoreNFC
import Foundation

/// The ISO 14443 tag kinds CoreNFC can hand over. Both device tests so far reported the ESL tag
/// as ISO 7816 regardless of the Info.plist AID list; the MIFARE case is kept for other tags.
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
            kind = "ISO 7816 标签，AID \(iso.initialSelectedAID.isEmpty ? "无" : iso.initialSelectedAID)，UID \(Self.hex(iso.identifier))，"
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

    /// Android aborts the session when this write fails. Here a failure is recorded and the session
    /// continues, so a device test still shows whether the ESL frames get through.
    /// CoreNFC's own Type 4 NDEF stack failed on the first device test ("Stack Error"), so after it
    /// fails the Type 4 procedure Android's Ndef stack performs is run as plain APDUs, with every
    /// response traced in full and the write verified by reading NLEN back.
    func writeVendorNDEF(trace: SessionTrace?) async throws {
        let target = ndefTag
        var stage = "queryNDEFStatus"
        do {
            let (status, capacity) = try await queryNDEF(target)
            trace?.record("NDEF CoreNFC 状态 \(Self.statusName(status))，容量 \(capacity)")
            guard status == .readWrite else { throw ESLTransportError.ndefNotWritable(status: Int(status.rawValue)) }
            guard let payload = NFCNDEFPayload.wellKnownTypeTextPayload(string: "汉朔科技E31", locale: Locale(identifier: "zh")) else {
                throw ESLTransportError.ndefPayloadUnavailable
            }
            stage = "writeNDEF"
            try await writeNDEF(target, NFCNDEFMessage(records: [payload]))
            ndefNote = "NDEF 写入成功（CoreNFC）"
            return
        } catch {
            let nsError = error as NSError
            let detail = "\(error.localizedDescription)，\(nsError.domain) \(nsError.code)"
            trace?.record("✕ NDEF CoreNFC \(stage)：\(detail)")
            ndefNote = "NDEF CoreNFC \(stage) 失败（\(detail)）"
        }
        ndefNote += "；" + (await manualType4Write(trace: trace))
    }

    /// Select the NDEF application, read the Capability Container for the NDEF file ID, write the
    /// record, read NLEN back. Returns a one-line verdict; the trace has every byte.
    private func manualType4Write(trace: SessionTrace?) async -> String {
        func step(_ name: String, _ apdu: ESLFrame.APDU) async -> [UInt8]? {
            trace?.record("→ T4T \(name) \(ESLFrame.hex(apdu.serialized))")
            do {
                let response = try await transceiveAPDU(apdu)
                trace?.record("← \(ESLFrame.hex(response))")
                return response
            } catch {
                trace?.record("✕ T4T \(name)：\(error.localizedDescription)")
                return nil
            }
        }
        func ok(_ response: [UInt8]?) -> Bool {
            guard let response else { return false }
            return Array(response.suffix(2)) == [0x90, 0x00]
        }

        guard ok(await step("选NDEF应用", ESLFrame.t4tSelectApplication())) else {
            return "手动 T4T 失败：选 NDEF 应用未返回 9000"
        }
        var fileID = ESLFrame.defaultNDEFFileID
        var ccNote = "CC 未读到，假定文件 E104"
        if ok(await step("选CC", ESLFrame.t4tSelectFile(ESLFrame.ccFileID))),
           let cc = await step("读CC", ESLFrame.t4tReadBinary(offset: 0, length: 15)), ok(cc) {
            let body = Array(cc.dropLast(2))
            if let id = ESLFrame.ndefFileID(fromCC: body) {
                fileID = id
                ccNote = "CC 指向文件 \(ESLFrame.hex(id))"
            } else {
                ccNote = "CC 无法解析（\(ESLFrame.hex(body))），假定文件 E104"
            }
        }
        guard ok(await step("选NDEF文件", ESLFrame.t4tSelectFile(fileID))) else {
            return "手动 T4T 失败：\(ccNote)；选 NDEF 文件未返回 9000"
        }
        _ = await step("读NLEN(写前)", ESLFrame.t4tReadBinary(offset: 0, length: 2))
        let message = ESLFrame.vendorNDEFMessage()
        guard ok(await step("清NLEN", ESLFrame.t4tUpdateBinary(offset: 0, data: [0x00, 0x00]))),
              ok(await step("写记录", ESLFrame.t4tUpdateBinary(offset: 2, data: message))),
              ok(await step("写NLEN", ESLFrame.t4tUpdateBinary(offset: 0, data: [0x00, UInt8(message.count)])))
        else {
            return "手动 T4T 失败：\(ccNote)；写入步骤未全部返回 9000"
        }
        let readBack = await step("读NLEN(写后)", ESLFrame.t4tReadBinary(offset: 0, length: 2))
        if readBack == [0x00, UInt8(message.count), 0x90, 0x00] {
            return "手动 T4T 成功（NLEN 读回 \(message.count)）；\(ccNote)"
        }
        return "手动 T4T 未证实：五步都回 9000，但 NLEN 读回为 \(readBack.map(ESLFrame.hex) ?? "无响应")；\(ccNote)"
    }

    private func queryNDEF(_ target: NFCNDEFTag) async throws -> (NFCNDEFStatus, Int) {
        try await withCheckedThrowingContinuation { continuation in
            target.queryNDEFStatus { status, capacity, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (status, capacity))
                }
            }
        }
    }

    private func writeNDEF(_ target: NFCNDEFTag, _ message: NFCNDEFMessage) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            target.writeNDEF(message) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    /// Raw ESL frames. On an ISO 7816 tag CoreNFC has no raw path, so this throws.
    /// On a MIFARE tag, sendMiFareCommand passes the bytes without APDU framing.
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

    /// ISO 7816-4 APDU. CoreNFC serialises CLA INS P1 P2 Lc data [Le] itself.
    func transceiveAPDU(_ apdu: ESLFrame.APDU) async throws -> [UInt8] {
        let command = NFCISO7816APDU(
            instructionClass: apdu.cla,
            instructionCode: apdu.ins,
            p1Parameter: apdu.p1,
            p2Parameter: apdu.p2,
            data: Data(apdu.data),
            expectedResponseLength: apdu.expectedResponseLength
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

    private static func statusName(_ status: NFCNDEFStatus) -> String {
        switch status {
        case .notSupported: return "notSupported"
        case .readWrite: return "readWrite"
        case .readOnly: return "readOnly"
        @unknown default: return "status \(status.rawValue)"
        }
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
