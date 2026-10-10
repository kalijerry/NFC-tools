import SwiftUI

/// The app's only screen: heartbeat, channel and LED actions on an ESL tag.
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

                Section {
                    Picker("发送方式", selection: $model.frameTransport) {
                        Text("ISO 7816 APDU").tag(FrameTransport.apdu)
                        Text("原始帧").tag(FrameTransport.rawFrame)
                    }
                    .pickerStyle(.segmented)
                    Toggle("APDU 附带 Le=00（请求返回数据）", isOn: $model.apduLe)
                        .disabled(model.frameTransport != .apdu)
                } header: {
                    Text("发送方式")
                } footer: {
                    Text("两次真机测试中这块价签都被 iOS 识别为 ISO 7816 标签，原始帧在这种标签上无法发送，会直接报错。APDU 方式把每一帧（包括握手）包装成 ISO 7816 命令。日志记录标签类型、NDEF 写入的每一步，以及每一帧的发送和响应字节。")
                }

                Section("快速心跳") {
                    Button("发送心跳") { Task { await model.sendHeartbeat() } }
                    Button("读取心跳信道") { Task { await model.readHeartbeatChannel() } }
                }
                .disabled(model.isBusy)

                Section("闪灯") {
                    Picker("颜色", selection: $model.ledColor) {
                        Text("红").tag(ESLFrame.LEDColor.red)
                        Text("绿").tag(ESLFrame.LEDColor.green)
                        Text("蓝").tag(ESLFrame.LEDColor.blue)
                    }
                    Picker("数量", selection: $model.ledCount) {
                        ForEach(ESLFrame.ledCounts, id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    }
                    Button("闪灯") { Task { await model.flashLight() } }
                    Button("关灯") { Task { await model.shutLight() } }
                }
                .disabled(model.isBusy)

                Section {
                    if model.log.isEmpty {
                        Text("还没有记录。贴近价签并点一个操作后，这里会显示检测结果和每一帧的字节。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(line.hasPrefix("    ") ? .system(.caption2, design: .monospaced) : .body)
                            .textSelection(.enabled)
                    }
                } header: {
                    HStack {
                        Text("日志")
                        Spacer()
                        Button("复制全部") { model.copyLog() }
                            .disabled(model.log.isEmpty)
                        ShareLink(item: model.logText) {
                            Text("分享")
                        }
                        .disabled(model.log.isEmpty)
                        Button("清空") { model.clearLog() }
                            .disabled(model.log.isEmpty)
                    }
                    .font(.footnote)
                    .textCase(nil)
                } footer: {
                    Text("用「复制全部」或「分享」把整段日志发出来，不要逐行复制。")
                }

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
                    Text("原始帧的十六进制，与 Android 版 logcat 对照用。")
                }
            }
            .navigationTitle("碰碰心跳")
        }
    }
}
