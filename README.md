# 碰碰 → iOS：快速心跳

移植范围：Android 版 `nfc.hs.com.mobilenfc`（5.0.1-rc3）的 **发送心跳** 和 **读取心跳信道**（对应 `HearbeatActy`、`ReadHeartbeatActivity`）。应用打开后直接就是这两个功能。

## 密钥是什么

密钥是 AES-128 对称加密的密钥，用来加密心跳帧和挑战应答，不是登录密码。

- Android 版的来源：登录接口返回 JSON 的 `data.key`（`ui/LoginActy$3.java:58`），以 Base64 字符串存在 SharedPreferences 的 `key` 中。
- 未登录或没有保存过密钥时，使用默认值：16 字节 `0xFF`（Base64 为 `/////////////////////w==`）。
- APK 里没有硬编码的 AES 密钥。之前 README 写过「硬编码的 `SHOPWEBKEY`」，那是错的：`SHOPWEBKEY` 只是 SharedPreferences 的键名 `"key"`（`bean/NFC_Constant.java`）。
- 价签与密钥必须一致：价签返回挑战 `6A 82` 时表示密钥不对，应用会显示「密钥错误，无法获取信息」。

iOS 版没有登录功能，所以需要在界面上手动粘贴 Base64 密钥并保存。这个密钥应来自你们的后台（与 Android 登录返回的 `data.key` 相同）。

## 协议（来自 Android 源码）

| 步骤 | 发送 | 说明 |
|---|---|---|
| 0 | NDEF 写入文本记录「汉朔科技E31」（语言 `zh`） | 每次会话开始都会写 |
| 1 | `00 C0 00 01 05 CRC`（sendEslId） | 响应 `[x,x,x,LEN,x,内容…]`，内容 20 字节，ESL ID 为内容第 12–15 字节 |
| 2 | `00 C0 00 11 02 AES(key,[00 00 10 01 + 12×00])`（getRandom） | 响应为 16 字节挑战；若为 `6A 82` 则密钥错误 |
| 3 | `00 C0 00 15 08 [00 00 10 01] AES(key,挑战)`（sendRandom） | 响应被忽略 |
| 4 | 心跳：`00 C0 00 11 0A AES(key,[03 11 00…])`；读取信道：`00 C0 00 11 0C AES(key,[01 00…])` | CRC 用 ESL ID 重算后发送，ESL ID 本身不发送 |

- CRC 为 CRC-16/XMODEM（多项式 0x1021，初值 0，不反射，无 xorout），低字节在前。
- 心跳结果：`90 00` 成功（发送成功!），`6A 83` 无此页，其他为传输失败。
- 读取信道：响应 `[5..<21]` 解密后第一个字节为信道号，Android 按有符号字节显示。

## iOS 限制（最关键）

Android 版用 `IsoDep.transceive` 直接发送原始 ISO-DEP 帧。iOS 的 CoreNFC 只提供 `NFCISO7816Tag.sendCommand`，只能发送 ISO 7816-4 APDU（`NFCISO7816APDU`）。

ESL 帧不是 APDU 格式：第 5 个字节是命令码（0x0A/0x0C 等），而 APDU 的第 5 个字节是 Lc。例如 23 字节的心跳帧会被解析成 Lc=10 加一段多余的尾部，无法构造。`CoreNFCTagTransport.transceive` 会对这类帧抛出 `frameNotRepresentableAsAPDU`。

因此，**在公开 CoreNFC API 下，iPhone 还无法真正与价签完成心跳**。绑定、亮灯、读取等走同一链路的功能也受影响。能否绕过取决于价签固件是否接受 APDU 形式的变体，需要真机验证。备选方案包括外部支持原始 ISO-DEP 的 NFC 读写器（经蓝牙连接 iPhone）。

## 闪灯与 ISO 7816 APDU

- Android 的亮灯（`LightActy` → `XModem.light`）和关灯（`XModem.shutLight`）帧结构与心跳相同：
  `00 C0 00 12 00 <17 字节明文中前 16 字节 AES 加密> <第 17 字节> CRC`，命令码为 0x00。
- 因此 LED 帧也不是 APDU，和心跳一样不能用 CoreNFC 的原始发送方式发出。
- 另一种思路是把同样的字节包装成 ISO 7816-4 APDU：`CLA=00 INS=C0 P1=00 P2=LEN Lc=数据长度 数据`。
  CoreNFC 的 `NFCISO7816APDU` 可以发送任意 CLA/INS/P1/P2/数据，所以这种包装在 iOS 上是能发出去的。
  Swift 的 `ESLFrame.asAPDU` 和 Python 的 `as_apdu` 都实现了它，并用同一组参考字节测试过。
- App 里有「发送方式」选择器（ISO 7816 APDU / 原始帧），对心跳、读信道、闪灯、关灯和握手统一生效。
  选 APDU 时，握手的每一帧也会包装成 APDU，因为 iOS 把价签识别成 ISO 7816 标签时，根本没有发送原始帧的途径。
- **能不能被价签接受，无法离线判断**：价签固件是否识别这种包装，只能用真价签测试。
  已离线测试的只有字节格式本身。见 [mac-bridge/README.md](mac-bridge/README.md) 的硬件测试步骤。
- 关灯有两条 Android 路径：`LightActy` 的「灭灯」先握手再发送，`ShutLightActy` 直接发送、无握手无 NDEF 写入。两条都已在 Core 中实现。

## 验证情况

已验证（macOS，`swiftc`，Swift 6.2）：
- `Tests/main.swift`：41 项全部通过（含 APDU 方式的整段会话、闪灯和关灯）。AES 通过 FIPS-197 向量，CRC 通过 `123456789 → 0x31C3`，心跳/读取/sendEslId/getRandom/sendRandom 帧与参考实现逐字节一致，ESL ID 绑定 CRC 正确，完整会话在模拟价签上结果正确（含 `6A 83`、`6A 82` 分支）。
- `Core/` 与 SwiftUI 界面（`App/`，不含入口）通过 macOS SDK 的类型检查。
- `NFC/CoreNFCTagSessionRunner.swift` 只做了语法检查（CoreNFC 不在 macOS SDK 中）。
- `project.yml` 已用 XcodeGen 2.46.0 生成 `PengPengHeartbeat.xcodeproj`。

未验证：
- 参考帧来自我对 Java 逻辑的 Python 重写（AES 用 `cryptography` 库），**没有运行原版 Java**（本机没有 JDK）。
- 本机没有 iOS SDK（只有 Command Line Tools），iOS 编译由 GitHub Actions 完成，至今每次都成功。
- `mac-bridge/`：35 项离线测试通过（协议字节、会话逻辑、模拟读写器和模拟价签的端到端流程）。
- 没有真实价签，没有真机测试。

## 签名安装到自己的 iPhone（Ad Hoc，不走 TestFlight）

工作流 `.github/workflows/build-adhoc.yml` 只能手动触发。它用你的证书和 Ad Hoc 描述文件签名，同时产出两个版本：

| 版本 | Info.plist 里的 AID | 预期 iOS 把价签识别为 | 能测的发送方式 |
|---|---|---|---|
| `ndef-aid` | `D2760000850101`（NDEF 应用） | ISO 7816 标签 | 只有 APDU |
| `no-aid` | `F0000000000001`（不会匹配的占位值） | 可能是 MIFARE 标签 | 原始帧（`sendMiFareCommand`）和 APDU |

两个版本 Bundle ID 相同，装第二个会覆盖第一个。识别结果以 App 日志里的「检测到 …」为准。

一次性准备（在开发者网页上完成）：

1. **证书**：Certificates → + → Apple Distribution，上传 `ESL-tools/signing/PengPengDistribution.certSigningRequest`，下载得到 `.cer`，放进同一个目录。私钥 `distribution.key` 只在这台 Mac 上，不要上传或提交。
2. **设备**：Devices → + → 填入 iPhone 的 UDID。
3. **App ID**：`com.kalijerry.pengpengheartbeat`，勾选 NFC Tag Reading。
4. **描述文件**：Profiles → + → Ad Hoc → 选这个 App ID、这张证书和这台设备 → 下载 `.mobileprovision`，放进 `ESL-tools/signing/`。

然后把证书和私钥合成 `.p12`，和描述文件一起转成 Base64，放进仓库的三个 Secrets：
`BUILD_CERTIFICATE_BASE64`、`P12_PASSWORD`、`ADHOC_PROFILE_BASE64`。之后在 Actions 页面手动运行 “Build signed IPA (Ad Hoc)”。

安装：用数据线连接 iPhone，在 Finder 里选中手机，把 `.ipa` 拖进去；或者使用 Apple Configurator。
仓库是公开的，签名材料只能放在 Secrets 里，建议改为私有仓库。

## 构建与运行

```bash
cd ios/PengPengHeartbeat
xcodegen generate            # 如需重新生成工程
open PengPengHeartbeat.xcodeproj
```

- 需要付费开发者账号开启 NFC 能力（entitlements 中已有 `com.apple.developer.nfc.readersession.formats = TAG`）。
- NFC 只能在真机上运行，模拟器不支持。
- 核心测试（macOS，无需 iOS SDK）：

```bash
swiftc -O Core/*.swift Tests/main.swift -o /tmp/pp_core_tests && /tmp/pp_core_tests
```

## 目录

```
Core/   纯 Swift（Foundation + CommonCrypto）：CRC16、AESECB、ESLFrame、HeartbeatSession
NFC/    CoreNFC 传输层（仅 iOS）
App/    SwiftUI：快速心跳界面（HeartbeatView）与模型（HeartbeatModel）
Tests/  Core 测试（macOS 可直接运行）
project.yml   XcodeGen 配置
```

## 没有包含的内容

- 登录与服务器（`HttpUtils`、`LoginActy`）：快速心跳只需要密钥，目前在界面上手动粘贴。
- 快速组网（`FastBindActy`）、绑定/解绑/亮灯、固件升级（`UpgradeActy`、XModem 固件传输）：不在本次范围。
- 密钥目前保存在 UserDefaults 中，正式版应改用 Keychain。
