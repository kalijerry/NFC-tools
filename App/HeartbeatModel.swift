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
        ]
    }

    func saveKey() {
        defaults.set(keyBase64, forKey: Self.defaultsKey)
        append("密钥已保存")
    }

    func sendHeartbeat() async {
        await perform(title: "发送心跳") { session in
            switch try await session.sendHeartbeat() {
            case .sent: return "发送成功!"
            case .noSuchPage: return "无此页!"
            case .transferFailed: return "传输失败!"
            }
        }
    }

    func readHeartbeatChannel() async {
        await perform(title: "读取心跳信道") { session in
            let raw = try await session.readHeartbeatChannel()
            // The Android app shows the byte as a signed Java value, so do the same.
            return "信道 \(Int8(bitPattern: raw))"
        }
    }

    private func perform(title: String, _ action: @escaping (HeartbeatSession) async throws -> String) async {
        guard let key = keyBytes else {
            append("\(title)：密钥格式错误（需要 Base64 编码的 16/24/32 字节）")
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let text = try await runner.withTag { transport in
                try await action(HeartbeatSession(key: key, transport: transport))
            }
            append("\(title)：\(text)")
        } catch HeartbeatError.keyError {
            append("\(title)：密钥错误，无法获取信息")
        } catch {
            append("\(title)：\(error.localizedDescription)")
        }
    }

    private func append(_ line: String) {
        log.append(line)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    private static func hexString(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
