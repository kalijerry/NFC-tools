/// One raw ISO-DEP conversation with an ESL tag, plus the NDEF write the Android app
/// performs at the start of every session.
protocol ESLTagTransport {
    /// Writes the NDEF text record "汉朔科技E31" (BaseNfcManagerActy.createTextRecord).
    func writeVendorNDEF() async throws

    /// Sends exactly these bytes and returns the raw response (Android `IsoDep.transceive`).
    func transceive(_ frame: [UInt8]) async throws -> [UInt8]
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
