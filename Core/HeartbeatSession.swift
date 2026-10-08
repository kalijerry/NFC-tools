/// One raw ISO-DEP conversation with an ESL tag, plus the NDEF write the Android app
/// performs at the start of every session.
protocol ESLTagTransport {
    /// Writes the NDEF text record "汉朔科技E31" (BaseNfcManagerActy.createTextRecord).
    func writeVendorNDEF() async throws

    /// Sends exactly these bytes and returns the raw response (Android `IsoDep.transceive`).
    func transceive(_ frame: [UInt8]) async throws -> [UInt8]

    /// Sends an ISO 7816-4 APDU and returns response data plus SW1 SW2.
    /// On iOS this is the only path CoreNFC can use for arbitrary bytes (NFCISO7816APDU).
    func transceiveAPDU(_ apdu: ESLFrame.APDU) async throws -> [UInt8]
}

/// How a bound LED frame goes onto the air.
enum LightTransport {
    /// Android's own framing. CoreNFC cannot send this (see ESLTransportError).
    case rawFrame
    /// Experiment: the same bytes wrapped as an ISO 7816-4 APDU.
    case apdu
}

/// Opens a tag session around `body`, closing it when `body` returns or throws.
protocol ESLTagSessionRunner {
    func withTag<T>(_ body: (ESLTagTransport) async throws -> T) async throws -> T
}

/// Outcome of a heartbeat, named after the Android strings shown to the user.
enum HeartbeatOutcome: Equatable {
    case sent            // 90 00 -> "发送成功!"  (send_success)
    case noSuchPage      // 6A 83 -> "无此页!"    (no_such_page)
    case transferFailed  // anything else -> "传输失败!" (send_faile)
}

enum HeartbeatError: Error, Equatable {
    /// The tag answered the challenge request with 6A 82 -> "密钥错误，无法获取信息" (error_code_1).
    case keyError
}

/// The quick-heartbeat sequences from BaseNfcManagerActy.sendEslIdNfcMessage and readHBCH:
///   1. write NDEF "汉朔科技E31"
///   2. sendEslId  -> ESL ID
///   3. getRandom  -> 16-byte challenge (6A 82 = key error)
///   4. sendRandom -> AES(key, challenge)
///   5. send the heartbeat (or read-channel) frame, re-CRC'd with the ESL ID
struct HeartbeatSession {
    let key: [UInt8]
    let transport: ESLTagTransport

    func sendHeartbeat() async throws -> HeartbeatOutcome {
        let frame = try ESLFrame.heartbeat(key: key)
        let eslid = try await authenticate()
        let response = try await transport.transceive(ESLFrame.bind(frame, eslid: eslid))
        return Self.classify(response)
    }

    func readHeartbeatChannel() async throws -> UInt8 {
        let frame = try ESLFrame.readHeartbeatChannel(key: key)
        let eslid = try await authenticate()
        let response = try await transport.transceive(ESLFrame.bind(frame, eslid: eslid))
        return try ESLFrame.channel(fromResponse: response, key: key)
    }

    /// LightActy: handshake, then the bound LED frame (colour, count).
    func flashLight(color: UInt8, count: UInt16, via: LightTransport) async throws -> HeartbeatOutcome {
        let frame = try ESLFrame.led(key: key, color: color, count: count)
        return try await sendBound(frame, via: via)
    }

    /// LightActy's "off" option: handshake, then the shut-off frame.
    func shutLight(via: LightTransport) async throws -> HeartbeatOutcome {
        try await sendBound(try ESLFrame.shutLight(key: key), via: via)
    }

    /// ShutLightActy's path: the shut-off frame goes out directly, with no NDEF write and no handshake.
    func shutLightWithoutHandshake() async throws -> [UInt8] {
        try await transport.transceive(try ESLFrame.shutLight(key: key))
    }

    private func sendBound(_ frame: [UInt8], via: LightTransport) async throws -> HeartbeatOutcome {
        let eslid = try await authenticate()
        let bound = ESLFrame.bind(frame, eslid: eslid)
        switch via {
        case .rawFrame:
            return Self.classify(try await transport.transceive(bound))
        case .apdu:
            return Self.classify(try await transport.transceiveAPDU(ESLFrame.asAPDU(bound)))
        }
    }

    static func classify(_ response: [UInt8]) -> HeartbeatOutcome {
        if response == [0x90, 0x00] { return .sent }
        if response == [0x6A, 0x83] { return .noSuchPage }
        return .transferFailed
    }

    private func authenticate() async throws -> [UInt8] {
        try await transport.writeVendorNDEF()
        let eslid = try ESLFrame.eslid(fromResponse: try await transport.transceive(ESLFrame.sendEslId()))
        let challenge = try await transport.transceive(try ESLFrame.getRandom(key: key))
        if challenge == [0x6A, 0x82] { throw HeartbeatError.keyError }
        let encrypted = try AESECB.encrypt(key: key, challenge)
        _ = try await transport.transceive(ESLFrame.sendRandom(encryptedChallenge: encrypted))
        return eslid
    }
}
