/// Frame builders and response parsers, ported from the Android app's
/// `model/xmodem/XModem.java` and `base/BaseNfcManagerActy.java`.
///
/// Frame layout (XModem.makePacket):
///   [0x00, 0xC0, 0x00, LEN, CMD, payload..., CRC16 low byte, CRC16 high byte]
///   LEN = payload.count + 1, CRC16 = CRC-16/XMODEM over everything before it.
enum ESLFrame {
    enum Command: UInt8 {
        case getRandom = 0x02
        case sendRandom = 0x08
        case sendEslId = 0x05
        case heartbeat = 0x0A
        case readHeartbeatChannel = 0x0C
    }

    enum ParseError: Error, Equatable {
        case shortResponse(Int)
        case shortContent(declared: Int, actual: Int)
        case channelBlockMissing(Int)
    }

    static let maxPayload = 240

    static func make(_ command: Command, payload: [UInt8] = []) -> [UInt8] {
        precondition(payload.count <= maxPayload, "payload too long for one frame")
        let body: [UInt8] = [0x00, 0xC0, 0x00, UInt8(payload.count + 1), command.rawValue] + payload
        let crc = CRC16.xmodem(body)
        return body + [UInt8(crc & 0xFF), UInt8(crc >> 8)]
    }

    /// XModem.sendEslId(): asks the tag for its 20-byte ID record.
    static func sendEslId() -> [UInt8] {
        make(.sendEslId)
    }

    /// XModem.getRandom(): plaintext [00 00 10 01, 12 x 00], AES-encrypted, asks the tag for a challenge.
    static func getRandom(key: [UInt8]) throws -> [UInt8] {
        let plain: [UInt8] = [0x00, 0x00, 0x10, 0x01] + [UInt8](repeating: 0, count: 12)
        return make(.getRandom, payload: try AESECB.encrypt(key: key, plain))
    }

    /// XModem.getSendRandom(): returns the AES-encrypted challenge to the tag.
    static func sendRandom(encryptedChallenge: [UInt8]) -> [UInt8] {
        make(.sendRandom, payload: [0x00, 0x00, 0x10, 0x01] + encryptedChallenge)
    }

    /// XModem.hb(): plaintext [03, 11, 14 x 00], AES-encrypted.
    static func heartbeat(key: [UInt8]) throws -> [UInt8] {
        var plain = [UInt8](repeating: 0, count: 16)
        plain[0] = 0x03
        plain[1] = 0x11
        return make(.heartbeat, payload: try AESECB.encrypt(key: key, plain))
    }

    /// XModem.readHBCH(): plaintext [01, 15 x 00], AES-encrypted.
    static func readHeartbeatChannel(key: [UInt8]) throws -> [UInt8] {
        var plain = [UInt8](repeating: 0, count: 16)
        plain[0] = 0x01
        return make(.readHeartbeatChannel, payload: try AESECB.encrypt(key: key, plain))
    }

    /// XModem.newPacket(): keeps the frame bytes and replaces its CRC with one computed
    /// over (frame without CRC) + ESL ID. The ESL ID itself is not transmitted.
    static func bind(_ frame: [UInt8], eslid: [UInt8]) -> [UInt8] {
        precondition(frame.count >= 2, "frame has no CRC")
        var out = frame
        let crc = CRC16.xmodem(Array(frame.dropLast(2)) + eslid)
        out[out.count - 2] = UInt8(crc & 0xFF)
        out[out.count - 1] = UInt8(crc >> 8)
        return out
    }

    /// XModem.getEslid() + EslId.decode(): response is [x, x, x, LEN, x, content...];
    /// the 20-byte content is master(4) wake(4) extend(4) eslid(4) set/group/esl/mask(4).
    /// The ESL ID is content[12..<16].
    static func eslid(fromResponse response: [UInt8]) throws -> [UInt8] {
        guard response.count >= 5 else { throw ParseError.shortResponse(response.count) }
        let declared = Int(response[3])
        guard declared >= 20, response.count >= 5 + declared else {
            throw ParseError.shortContent(declared: declared, actual: response.count - 5)
        }
        return Array(response[(5 + 12)..<(5 + 16)])
    }

    /// BaseNfcManagerActy.readHBCH(..., true): the 16-byte block at [5..<21] decrypts to
    /// [channel, ...]. ReadHeartbeatActivity shows the first byte.
    static func channel(fromResponse response: [UInt8], key: [UInt8]) throws -> UInt8 {
        guard response.count >= 21 else { throw ParseError.channelBlockMissing(response.count) }
        let plain = try AESECB.decrypt(key: key, Array(response[5..<21]))
        return plain[0]
    }
}
