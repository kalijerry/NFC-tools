// Core tests. Build and run on macOS (no iOS SDK needed):
//   swiftc -O Core/*.swift Tests/main.swift -o /tmp/pp_core_tests && /tmp/pp_core_tests
//
// Reference frames come from an independent Python re-implementation of the Android
// logic (XModem.java / BaseNfcManagerActy.java) using the `cryptography` package.
import Foundation

var failures = 0
var passes = 0

func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    if condition() {
        passes += 1
        print("PASS  \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)")
    }
}

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

func bytes(_ hexString: String) -> [UInt8] {
    var out: [UInt8] = []
    var index = hexString.startIndex
    while index < hexString.endIndex {
        let next = hexString.index(index, offsetBy: 2)
        out.append(UInt8(hexString[index..<next], radix: 16)!)
        index = next
    }
    return out
}

// MARK: - Reference data (oracle output for key = 16 x 0xFF)

let key = [UInt8](repeating: 0xFF, count: 16)
let oracleHeartbeat = "00c000110a626102473f70635bb7e9070a255f8afd7777"
let oracleReadChannel = "00c000110c2060b29484f017e238f2405b99001c0152c7"
let oracleSendEslId = "00c000010530d0"
let oracleGetRandom = "00c0001102c851064f93e89855412717944948e21f2c20"
let oracleSendRandomA0toAF = "00c000150800001001fb09d86844a1c42a3bbaae688e876eb895a9"
let oracleHeartbeatBound = "00c000110a626102473f70635bb7e9070a255f8afdc5d8"
let oracleReadChannelBound = "00c000110c2060b29484f017e238f2405b99001c012244"
let challengeA0toAF: [UInt8] = (0xA0...0xAF).map { UInt8($0) }
let eslidFromOracle: [UInt8] = [0x1c, 0x1d, 0x1e, 0x1f]

// MARK: - Primitives

// FIPS-197 Appendix C.1 (AES-128)
let fipsKey = bytes("000102030405060708090a0b0c0d0e0f")
let fipsPlain = bytes("00112233445566778899aabbccddeeff")
check(hex(try! AESECB.encrypt(key: fipsKey, fipsPlain)) == "69c4e0d86a7b0430d8cdb78070b4c55a", "AES-128 ECB matches FIPS-197 vector")
check(try! AESECB.decrypt(key: fipsKey, bytes("69c4e0d86a7b0430d8cdb78070b4c55a")) == fipsPlain, "AES-128 ECB decrypt round-trips")
check((try? AESECB.encrypt(key: key, [1, 2, 3])) == nil, "AES rejects non-block-multiple input")

check(CRC16.xmodem(Array("123456789".utf8)) == 0x31C3, "CRC-16/XMODEM check value 0x31C3")

// MARK: - Frames match the Android-derived oracle byte-for-byte

check(hex(try! ESLFrame.heartbeat(key: key)) == oracleHeartbeat, "heartbeat frame == oracle")
check(hex(try! ESLFrame.readHeartbeatChannel(key: key)) == oracleReadChannel, "read-channel frame == oracle")
check(hex(ESLFrame.sendEslId()) == oracleSendEslId, "sendEslId frame == oracle")
check(hex(try! ESLFrame.getRandom(key: key)) == oracleGetRandom, "getRandom frame == oracle")
check(hex(ESLFrame.sendRandom(encryptedChallenge: try! AESECB.encrypt(key: key, challengeA0toAF))) == oracleSendRandomA0toAF,
      "sendRandom frame == oracle")
check(hex(ESLFrame.bind(try! ESLFrame.heartbeat(key: key), eslid: eslidFromOracle)) == oracleHeartbeatBound,
      "heartbeat frame bound to ESL ID == oracle")
check(hex(ESLFrame.bind(try! ESLFrame.readHeartbeatChannel(key: key), eslid: eslidFromOracle)) == oracleReadChannelBound,
      "read-channel frame bound to ESL ID == oracle")

// MARK: - Response parsing

let eslidContent: [UInt8] = (0x10..<0x30).map { UInt8($0) }   // 20 bytes
let sendEslIdResponse: [UInt8] = [0x00, 0xC0, 0x00, 20, 0x00] + eslidContent + [0x90, 0x00]
check((try? ESLFrame.eslid(fromResponse: sendEslIdResponse)) == eslidFromOracle, "ESL ID parsed from sendEslId response")
check((try? ESLFrame.eslid(fromResponse: [0x00, 0xC0, 0x00, 10, 0x00, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11])) == nil,
      "ESL ID parse rejects a short content")

let channelResponse = bytes("00c000110c35c3b35884717dead42f7f0d386225ed9000")
check((try? ESLFrame.channel(fromResponse: channelResponse, key: key)) == 151, "channel decoded from read response (151)")

// MARK: - Mock tag that checks the protocol as the real tag would

final class MockTag: ESLTagTransport {
    let key: [UInt8]
    var challenge: [UInt8] = challengeA0toAF
    var heartbeatStatus: [UInt8] = [0x90, 0x00]
    var channel: UInt8 = 151
    var ndefWritten = false
    var bindingValid = true
    var challengeAnsweredCorrectly = false
    var heartbeatFrames = 0
    var acceptAPDU = false
    var ledPlainSeen: [UInt8]?
    var apduFrames: [ESLFrame.APDU] = []

    init(key: [UInt8]) { self.key = key }

    /// Models a tag whose firmware either accepts APDU framing or answers 6A 81 (unknown instruction).
    func transceiveAPDU(_ apdu: ESLFrame.APDU) async throws -> [UInt8] {
        apduFrames.append(apdu)
        return acceptAPDU ? [0x90, 0x00] : [0x6A, 0x81]
    }

    func writeVendorNDEF() async throws {
        ndefWritten = true
    }

    func transceive(_ frame: [UInt8]) async throws -> [UInt8] {
        switch frame[4] {
        case 0x05:
            return [0x00, 0xC0, 0x00, 20, 0x00] + eslidContent + [0x90, 0x00]
        case 0x02:
            return challenge
        case 0x08:
            let encrypted = Array(frame[9..<25])
            challengeAnsweredCorrectly = (try? AESECB.decrypt(key: key, encrypted)) == challenge
            return [0x90, 0x00]
        case 0x0A:
            heartbeatFrames += 1
            bindingValid = bindingValid && ESLFrame.bind(frame, eslid: eslidFromOracle) == frame
            return heartbeatStatus
        case 0x00:
            bindingValid = bindingValid && ESLFrame.bind(frame, eslid: eslidFromOracle) == frame
            let payload = Array(frame[5..<(frame.count - 2)])
            ledPlainSeen = (try? AESECB.decrypt(key: key, Array(payload[0..<16]))).map { $0 + [payload[16]] }
            return [0x90, 0x00]
        case 0x0C:
            bindingValid = bindingValid && ESLFrame.bind(frame, eslid: eslidFromOracle) == frame
            let block = try AESECB.encrypt(key: key, [channel] + [UInt8](repeating: 0, count: 15))
            return [0x00, 0xC0, 0x00, 17, 0x0C] + block + [0x90, 0x00]
        default:
            return [0x6A, 0x81]
        }
    }
}

// MARK: - Session behaviour

func runSessions() async {
    let tag = MockTag(key: key)
    let session = HeartbeatSession(key: key, transport: tag)
    do {
        let outcome = try await session.sendHeartbeat()
        check(outcome == .sent, "heartbeat session returns .sent on 90 00")
        check(tag.ndefWritten, "heartbeat session writes the vendor NDEF record first")
        check(tag.bindingValid && tag.heartbeatFrames == 1, "heartbeat frame is bound to the ESL ID")
        check(tag.challengeAnsweredCorrectly, "challenge is answered with AES(key, challenge)")
    } catch {
        check(false, "heartbeat session completes (threw \(error))")
    }

    let noPage = MockTag(key: key)
    noPage.heartbeatStatus = [0x6A, 0x83]
    let noPageOutcome = try? await HeartbeatSession(key: key, transport: noPage).sendHeartbeat()
    check(noPageOutcome == .noSuchPage, "6A 83 maps to .noSuchPage")

    let failed = MockTag(key: key)
    failed.heartbeatStatus = [0x6A, 0x00]
    let failedOutcome = try? await HeartbeatSession(key: key, transport: failed).sendHeartbeat()
    check(failedOutcome == .transferFailed, "other status words map to .transferFailed")

    let keyErr = MockTag(key: key)
    keyErr.challenge = [0x6A, 0x82]
    do {
        _ = try await HeartbeatSession(key: key, transport: keyErr).sendHeartbeat()
        check(false, "6A 82 challenge throws keyError")
    } catch {
        check((error as? HeartbeatError) == .keyError, "6A 82 challenge throws keyError")
    }

    let readTag = MockTag(key: key)
    readTag.channel = 151
    let channel = try? await HeartbeatSession(key: key, transport: readTag).readHeartbeatChannel()
    check(channel == 151, "read-channel session returns the channel byte (151)")
    check(readTag.bindingValid, "read-channel frame is bound to the ESL ID")

    // LED (XModem.light) and shut-off (XModem.shutLight) frames, oracle vectors from oracle_light.json
    check(hex(try! ESLFrame.led(key: key, color: 2, count: 10)) == "00c0001200e5d043b266e69f7d5bad6bc26c4a88b70000bc",
          "LED red/10 frame == oracle")
    check(hex(try! ESLFrame.led(key: key, color: 1, count: 30)) == "00c00012005b763c1a5cbdb87323e20000551dfb4a007072",
          "LED blue/30 frame == oracle")
    check(hex(try! ESLFrame.led(key: key, color: 4, count: 20)) == "00c0001200a8669745fd9a1997e37e670255cfcead003301",
          "LED green/20 frame == oracle")
    check(hex(try! ESLFrame.shutLight(key: key)) == "00c00012002f70f523b26d5353184e1703bf8e5dc70011d0",
          "shut-off frame == oracle")
    let boundLED = ESLFrame.bind(try! ESLFrame.led(key: key, color: 2, count: 10), eslid: eslidFromOracle)
    check(hex(boundLED) == "00c0001200e5d043b266e69f7d5bad6bc26c4a88b700e628", "LED red/10 bound to ESL ID == oracle")
    check(hex(ESLFrame.bind(try! ESLFrame.shutLight(key: key), eslid: eslidFromOracle)) == "00c00012002f70f523b26d5353184e1703bf8e5dc700554a",
          "shut-off bound to ESL ID == oracle")
    let ledAPDU = ESLFrame.asAPDU(boundLED)
    check(hex([ledAPDU.cla, ledAPDU.ins, ledAPDU.p1, ledAPDU.p2, UInt8(ledAPDU.data.count)] + ledAPDU.data) == "00c000121400e5d043b266e69f7d5bad6bc26c4a88b700e628",
          "LED as ISO 7816 APDU (CLA INS P1 P2 Lc data) == oracle")
    let ledFrameBytes = try! ESLFrame.led(key: key, color: 2, count: 10)
    let decryptedLED = (try? AESECB.decrypt(key: key, Array(ledFrameBytes[5..<21]))).map { $0 + [ledFrameBytes[21]] }
    check(decryptedLED == ESLFrame.ledPlain(color: 2, count: 10), "LED payload decrypts to the 17-byte plaintext")
    check(ESLFrame.ledPlain(color: 2, count: 10).count == 17 && ESLFrame.shutPlain.count == 17, "LED plaintexts are 17 bytes")

    let ledRawTag = MockTag(key: key)
    let ledRawOutcome = try? await HeartbeatSession(key: key, transport: ledRawTag).flashLight(color: 2, count: 10, via: .rawFrame)
    check(ledRawOutcome == .sent && ledRawTag.ledPlainSeen == ESLFrame.ledPlain(color: 2, count: 10),
          "LED raw session: .sent and tag decrypts the expected plaintext")

    let ledAPDUTag = MockTag(key: key)
    let ledAPDUOutcome = try? await HeartbeatSession(key: key, transport: ledAPDUTag).flashLight(color: 2, count: 10, via: .apdu)
    check(ledAPDUOutcome == .transferFailed && ledAPDUTag.apduFrames.count == 1,
          "LED APDU experiment: firmware answering 6A 81 maps to .transferFailed")

    let ledAPDUAcceptingTag = MockTag(key: key)
    ledAPDUAcceptingTag.acceptAPDU = true
    let acceptedOutcome = try? await HeartbeatSession(key: key, transport: ledAPDUAcceptingTag).flashLight(color: 2, count: 10, via: .apdu)
    check(acceptedOutcome == .sent, "LED APDU experiment: firmware answering 90 00 maps to .sent")

    let shutTag = MockTag(key: key)
    let shutOutcome = try? await HeartbeatSession(key: key, transport: shutTag).shutLight(via: .rawFrame)
    check(shutOutcome == .sent && shutTag.ndefWritten, "shut-off via LightActy path: handshake, then .sent")

    let shutRawTag = MockTag(key: key)
    let shutRaw = try? await HeartbeatSession(key: key, transport: shutRawTag).shutLightWithoutHandshake()
    check(shutRaw == [0x90, 0x00] && !shutRawTag.ndefWritten,
          "shut-off via ShutLightActy path: no NDEF write, no handshake")
}

await runSessions()
print("\n\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
