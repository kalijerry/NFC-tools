import SwiftUI

/// The app's only screen: the quick-heartbeat actions.
struct HeartbeatView: View {
    @StateObject private var model: HeartbeatModel

    init(runner: ESLTagSessionRunner) {
        _model = StateObject(wrappedValue: HeartbeatModel(runner: runner))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Base64 密钥", text: $model.keyBase64)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                    Button("保存密钥") { model.saveKey() }
                } header: {
                    Text("密钥")
                } footer: {
                    Text("AES-128 密钥，Base64 编码的 16 字节。Android 版在登录接口返回 data.key 后保存到本机；未登录时为 16 字节 0xFF。必须与价签一致，否则价签返回 6A 82（密钥错误）。")
                }

                Section("快速心跳") {
                    Button("发送心跳") { Task { await model.sendHeartbeat() } }
                    Button("读取心跳信道") { Task { await model.readHeartbeatChannel() } }
                }
                .disabled(model.isBusy)

                Section {
                    ForEach(model.framePreview) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(item.hex)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                } header: {
                    Text("帧预览")
                } footer: {
                    Text("与 Android 版 logcat 中的十六进制帧对照用。")
                }

                Section("日志") {
                    ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                        Text(line)
                    }
                }
            }
            .navigationTitle("快速心跳")
        }
    }
}
