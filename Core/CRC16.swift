/// CRC-16/XMODEM: poly 0x1021, init 0x0000, no reflection, no xorout.
/// Matches `nfc.hs.com.mobilenfc.utils.Crc16.cal` (table-driven in the Android app).
enum CRC16 {
    static func xmodem<C: Collection>(_ bytes: C) -> UInt16 where C.Element == UInt8 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }
}
