/// One conversation with an ESL tag, plus the NDEF write the Android app performs at the start
/// of every session.
protocol ESLTagTransport {
    /// What the NFC stack detected (tag type, AID, UID, NDEF write result). Shown in the log so a
    /// device test tells us how iOS sees the ESL tag.
    var tagSummary: String { get }

    /// Writes the NDEF text record "汉朔科技E31" (BaseNfcManagerActy.createTextRecord).
    func writeVendorNDEF() async throws

    /// Sends exactly these bytes and returns the raw response (Android `IsoDep.transceive`).
    func transceive(_ frame: [UInt8]) async throws -> [UInt8]

    /// Sends an ISO 7816-4 APDU and returns response data plus SW1 SW2.
    /// On iOS this is the only path CoreNFC offers for an ISO 7816 tag (NFCISO7816APDU).
    func transceiveAPDU(_ apdu: ESLFrame.APDU) async throws -> [UInt8]
}

/// How every ESL frame of a session goes onto the air.
enum FrameTransport: String, CaseIterable, Identifiable {
    /// Android's own framing (IsoDep.transceive). CoreNFC cannot send it to an ISO 7816 tag.
    case rawFrame
    /// Experiment: each frame wrapped as an ISO 7816-4 APDU (see ESLFrame.asAPDU). Whether the tag
    /// firmware accepts this is unknown until a device test.
    case apdu

    var id: String { rawValue }
}

/// Opens a tag session around `body`, closing it when `body` returns or throws.
protocol ESLTagSessionRunner {
    func withTag<T>(_ body: (ESLTagTransport) async throws -> T) async throws -> T
}

/// Outcome of a frame that answers with a status word, named after the Android strings.
enum HeartbeatOutcome: Equatable {
    case sent            // 90 00 -> "发送成功!"  (send_success)
    case noSuchPage      // 6A 83 -> "无此页!"    (no_such_page)
    case transferFailed  // anything else -> "传输失败!" (send_faile)
}

enum HeartbeatError: Error, Equatable {
    /// The tag answered the challenge request with 6A 82 -> "密钥错误，无法获取信息" (error_code_1).
    case keyError
}

/// The Android session (BaseNfcManagerActy.sendEslIdNfcMessage / readHBCH):
///   1. write NDEF "汉朔科技E31"
///   2. sendEslId  -> ESL ID
///   3. getRandom  -> 16-byte challenge (6A 82 = key error)
///   4. sendRandom -> AES(key, challenge)
///   5. the action frame (heartbeat, read channel, LED), re-CRC'd with the ESL ID
/// `via` decides whether every one of these frames goes raw or APDU-wrapped.
struct HeartbeatSession {
    let key: [UInt8]
    let transport: ESLTagTransport
    var via: FrameTransport = .rawFrame

    func sendHeartbeat() async throws -> HeartbeatOutcome {
        let frame = try ESLFrame.heartbeat(key: key)
        let eslid = try await authenticate()
        return Self.classify(try await exchange(ESLFrame.bind(frame, eslid: eslid)))
    }

    func readHeartbeatChannel() async throws -> UInt8 {
        let frame = try ESLFrame.readHeartbeatChannel(key: key)
        let eslid = try await authenticate()
        let response = try await exchange(ESLFrame.bind(frame, eslid: eslid))
        return try ESLFrame.channel(fromResponse: response, key: key)
    }

    /// LightActy: handshake, then the bound LED frame (colour, count).
    func flashLight(color: UInt8, count: UInt16) async throws -> HeartbeatOutcome {
        let frame = try ESLFrame.led(key: key, color: color, count: count)
        let eslid = try await authenticate()
        return Self.classify(try await exchange(ESLFrame.bind(frame, eslid: eslid)))
    }

    /// LightActy's "off" option: handshake, then the shut-off frame.
    func shutLight() async throws -> HeartbeatOutcome {
        let frame = try ESLFrame.shutLight(key: key)
        let eslid = try await authenticate()
        return Self.classify(try await exchange(ESLFrame.bind(frame, eslid: eslid)))
    }

    /// ShutLightActy's path: the shut-off frame goes out directly, with no NDEF write and no handshake.
    func shutLightWithoutHandshake() async throws -> [UInt8] {
        try await exchange(try ESLFrame.shutLight(key: key))
    }

    static func classify(_ response: [UInt8]) -> HeartbeatOutcome {
        if response == [0x90, 0x00] { return .sent }
        if response == [0x6A, 0x83] { return .noSuchPage }
        return .transferFailed
    }

    /// Sends one frame the selected way. On the APDU path CoreNFC appends SW1 SW2 to the response
    /// data. A trailing 90 00 after data is dropped so the parsers see the same bytes as on the raw
    /// path; a bare status word (for example 90 00 or 6A 82) is passed through unchanged.
    /// This normalisation is an assumption about how the firmware would answer APDUs.
    private func exchange(_ frame: [UInt8]) async throws -> [UInt8] {
        switch via {
        case .rawFrame:
            return try await transport.transceive(frame)
        case .apdu:
            let response = try await transport.transceiveAPDU(ESLFrame.asAPDU(frame))
            if response.count > 2, Array(response.suffix(2)) == [0x90, 0x00] {
                return Array(response.dropLast(2))
            }
            return response
        }
    }

    private func authenticate() async throws -> [UInt8] {
        try await transport.writeVendorNDEF()
        let eslid = try ESLFrame.eslid(fromResponse: try await exchange(ESLFrame.sendEslId()))
        let challenge = try await exchange(try ESLFrame.getRandom(key: key))
        if challenge == [0x6A, 0x82] { throw HeartbeatError.keyError }
        let encrypted = try AESECB.encrypt(key: key, challenge)
        _ = try await exchange(ESLFrame.sendRandom(encryptedChallenge: encrypted))
        return eslid
    }
}
