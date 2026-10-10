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

## 第一次真机测试（2026-10-10，`no-aid` 版本，闪灯 [APDU]）

日志：`检测到 ISO 7816 标签，AID F0000000000001，historical 无，appData 无；NDEF 写入失败（Stack Error）`，随后 `ParseError 0`（价签 ID 响应过短）。

- 价签对占位 AID 的 SELECT 也回成功。只要 Info.plist 里列了任何 AID，CoreNFC 就把它归为 ISO 7816，原始帧路径不可达。由此增加 `no-iso7816-key` 版本。
- CoreNFC 自带的 Type 4 NDEF 流程失败（Stack Error），而 Android 的 `Ndef.writeNdefMessage` 能成功。现在失败后会手动执行 Type 4 流程：选 NDEF 应用 → 读 CC 取得文件号 → 写入 → 读回 NLEN 校验，每一步的完整响应字节都进日志，只有读回一致才算成功。这也是判断"固件是否对任何 APDU 返回数据"最直接的探针。
- APDU 形式的 sendEslId 只收到状态字，没有 ID 记录。当时的 App 没有记录原始响应，不知道是 `90 00` 还是 `6A xx`。现在每一帧的发送和响应字节都进日志，解析错误也带上原始字节。
- 假设（第二次测试后仍待 APDU 日志证实）：固件只匹配原始帧 `00 C0 00 LEN CMD`，APDU 多出的 Lc 字节使其不匹配，于是泛泛回 `90 00`。MIFARE 路径已被第二次测试否定。
- 新增「APDU 附带 Le=00」开关，排除「固件想返回数据但没被请求」的可能。

## 第二次真机测试（2026-10-10，`no-iso7816-key` 版本，闪灯 [原始帧]）

当时的报告是「不能发原始帧，显示 NFC Core 只能是 ISO 7816」，对应 `frameNotRepresentableAsAPDU`。**这个结果现在存疑**：同一 Bundle ID 的早期 `no-aid` 版本界面几乎相同、也会报同一个错误，新包可能并未装上；第三次测试（见下）表明不声明 AID 时价签根本检测不到。CoreNFC 对 ISO 7816 标签只提供 `sendCommand(apdu:)`，没有发原始 ISO-DEP 帧的接口，所以 **在 iPhone 上用公开 API 复现 Android 的 `IsoDep.transceive` 已确认不可行**。剩下的变数只有一个：价签固件对 APDU 包装的帧回了什么（见日志里的 `←` 行）。

## 第三次真机测试（2026-10-10，`1a81d08`，Info.plist 无 AID 键）

手机靠近价签没有任何反应（用户确认价签正常）。这与 CoreNFC 的文档行为一致：没有 `select-identifiers` 时，不是 MIFARE 的 ISO 14443-4 标签不会被上报。由此把 NDEF 应用 AID（`D2760000850101`、`D2760000850100`）加回 Info.plist。

综合三次测试的结论：**声明 AID 才能检测到价签，检测到后一定是 ISO 7816 标签，CoreNFC 对它只有 APDU 接口；不声明 AID 则检测不到。两种情况下都没有原始帧路径。** 还没有拿到的信息：价签对 APDU 包装帧的具体回应（新版日志会完整记录）。

## 验证情况

已验证（macOS，`swiftc`，Swift 6.2）：
- `Tests/main.swift`：57 项全部通过（含 APDU 方式的整段会话、闪灯和关灯）。AES 通过 FIPS-197 向量，CRC 通过 `123456789 → 0x31C3`，心跳/读取/sendEslId/getRandom/sendRandom 帧与参考实现逐字节一致，ESL ID 绑定 CRC 正确，完整会话在模拟价签上结果正确（含 `6A 83`、`6A 82` 分支）。
- `Core/` 与 SwiftUI 界面（`App/`，不含入口）通过 macOS SDK 的类型检查。
- `NFC/CoreNFCTagSessionRunner.swift` 只做了语法检查（CoreNFC 不在 macOS SDK 中）。
- `project.yml` 已用 XcodeGen 2.46.0 生成 `PengPengHeartbeat.xcodeproj`。

未验证：
- 参考帧来自我对 Java 逻辑的 Python 重写（AES 用 `cryptography` 库），**没有运行原版 Java**（本机没有 JDK）。
- 本机没有 iOS SDK（只有 Command Line Tools），iOS 编译由 GitHub Actions 完成，至今每次都成功。
- `mac-bridge/`：35 项离线测试通过（协议字节、会话逻辑、模拟读写器和模拟价签的端到端流程）。
- 没有真实价签，没有真机测试。

## 签名安装到自己的 iPhone（Ad Hoc，不走 TestFlight）

工作流 `.github/workflows/build-adhoc.yml` 只能手动触发。它用你的证书和 Ad Hoc 描述文件签名，只产出一个版本（Info.plist 声明 NDEF 应用 AID；不声明则价签检测不到，见第三次真机测试）。曾经的对比版本如下：

| 版本 | Info.plist 里的 AID | 预期 iOS 把价签识别为 | 能测的发送方式 |
|---|---|---|---|
| `ndef-aid` | `D2760000850101`（NDEF 应用） | ISO 7816 标签 | 只有 APDU |
| `no-aid` | `F0000000000001`（占位值） | 实测：仍是 ISO 7816，价签对任意 AID 的 SELECT 都回成功 | 只有 APDU |
| `no-iso7816-key` | 不声明 | 实测：仍是 ISO 7816 | 只有 APDU（现在唯一保留的版本） |

识别结果以 App 日志里的「检测到 …」为准。

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
