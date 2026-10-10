import Combine
import Foundation

/// One frame the app would send, shown so it can be compared with the Android app's logcat hex dumps.
struct FramePreview: Identifiable {
    let name: String
    let hex: String
    var id: String { name }
}

@MainActor
final class HeartbeatModel: ObservableObject {
    /// Android default when no login has stored a key: 16 bytes of 0xFF (base64).
    static let defaultKeyBase64 = "/////////////////////w=="
    /// Same SharedPreferences key name the Android app uses for the login-provided key.
    private static let defaultsKey = "key"

    @Published var keyBase64: String
    @Published private(set) var log: [String] = []
    @Published private(set) var isBusy = false
    /// APDU by default: on an ISO 7816 tag CoreNFC cannot send raw frames at all.
    @Published var frameTransport: FrameTransport = .apdu
    @Published var ledColor: ESLFrame.LEDColor = .red
    @Published var ledCount: UInt16 = 10

    private let runner: ESLTagSessionRunner
    private let defaults: UserDefaults

    init(runner: ESLTagSessionRunner, defaults: UserDefaults = .standard) {
        self.runner = runner
        self.defaults = defaults
        self.keyBase64 = defaults.string(forKey: Self.defaultsKey) ?? Self.defaultKeyBase64
    }

    var keyBytes: [UInt8]? {
        guard let data = Data(base64Encoded: keyBase64), [16, 24, 32].contains(data.count) else { return nil }
        return [UInt8](data)
    }

    var framePreview: [FramePreview] {
        guard let key = keyBytes else { return [] }
        func hex(_ build: () throws -> [UInt8]) -> String {
            (try? build()).map(Self.hexString) ?? "—"
        }
        return [
            FramePreview(name: "发送心跳 (hb)", hex: hex { try ESLFrame.heartbeat(key: key) }),
            FramePreview(name: "读取心跳信道 (readHBCH)", hex: hex { try ESLFrame.readHeartbeatChannel(key: key) }),
            FramePreview(name: "sendEslId", hex: Self.hexString(ESLFrame.sendEslId())),
            FramePreview(name: "getRandom", hex: hex { try ESLFrame.getRandom(key: key) }),
            FramePreview(name: "闪灯 (light)", hex: hex { try ESLFrame.led(key: key, color: ledColor.rawValue, count: ledCount) }),
        ]
    }

    func saveKey() {
        defaults.set(keyBase64, forKey: Self.defaultsKey)
        append("密钥已保存")
    }

    func sendHeartbeat() async {
        await perform(title: "发送心跳") { session in
            Self.describe(try await session.sendHeartbeat())
        }
    }

    func readHeartbeatChannel() async {
        await perform(title: "读取心跳信道") { session in
            let raw = try await session.readHeartbeatChannel()
            // The Android app shows the byte as a signed Java value, so do the same.
            return "信道 \(Int8(bitPattern: raw))"
        }
    }

    func flashLight() async {
        let color = ledColor.rawValue
        let count = ledCount
        await perform(title: "闪灯") { session in
            Self.describe(try await session.flashLight(color: color, count: count))
        }
    }

    func shutLight() async {
        await perform(title: "关灯") { session in
            Self.describe(try await session.shutLight())
        }
    }

    private static func describe(_ outcome: HeartbeatOutcome) -> String {
        switch outcome {
        case .sent: return "发送成功!"
        case .noSuchPage: return "无此页!"
        case .transferFailed: return "传输失败!"
        }
    }

    private func perform(title: String, _ action: @escaping (HeartbeatSession) async throws -> String) async {
        guard let key = keyBytes else {
            append("\(title)：密钥格式错误（需要 Base64 编码的 16/24/32 字节）")
            return
        }
        let via = frameTransport
        let label = "\(title) [\(via == .apdu ? "APDU" : "原始帧")]"
        isBusy = true
        defer { isBusy = false }
        // Read after the action, so the summary includes the NDEF write result. Kept on failure too:
        // a device test needs to know what iOS detected.
        var summary: String?
        do {
            let text = try await runner.withTag { transport -> String in
                defer { summary = transport.tagSummary }
                return try await action(HeartbeatSession(key: key, transport: transport, via: via))
            }
            if let summary { append("\(label)：检测到 \(summary)") }
            append("\(label)：\(text)")
        } catch {
            if let summary { append("\(label)：检测到 \(summary)") }
            append("\(label)：\(Self.errorText(error))")
        }
    }

    private static func errorText(_ error: Error) -> String {
        if let heartbeatError = error as? HeartbeatError, heartbeatError == .keyError {
            return "密钥错误，无法获取信息"
        }
        return error.localizedDescription
    }

    private func append(_ line: String) {
        log.append(line)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    private static func hexString(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
