"""Protocol logic for the ESL quick-heartbeat and LED frames.

Ported from the Android app: XModem.java (frames), BaseNfcManagerActy.java (session
order, status words), LightActy.java / ShutLightActy.java (LED colours, counts, frames).
Pure Python, no hardware access. Frames are the exact bytes the Android app passes to
IsoDep.transceive().
"""

from typing import Protocol

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

CMD_LED = 0x00
CMD_GET_RANDOM = 0x02
CMD_SEND_ESL_ID = 0x05
CMD_SEND_RANDOM = 0x08
CMD_HEARTBEAT = 0x0A
CMD_READ_CHANNEL = 0x0C

SW_SUCCESS = bytes([0x90, 0x00])
SW_NO_PAGE = bytes([0x6A, 0x83])
SW_KEY_ERROR = bytes([0x6A, 0x82])

VENDOR_NDEF_TEXT = "汉朔科技E31"

# LightActy radio buttons: red is the default colour (led_color = 2), count default is 10.
LED_COLORS = {"red": 2, "blue": 1, "green": 4}
LED_COUNTS = (10, 20, 30)


class ProtocolError(Exception):
    """A response did not have the expected shape."""


class KeyRejected(ProtocolError):
    """The tag answered the challenge request with 6A 82 (error_code_1 in the app)."""


def crc16_xmodem(data: bytes) -> int:
    """CRC-16/XMODEM: poly 0x1021, init 0, no reflection, no xorout (Crc16.java)."""
    crc = 0
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            if crc & 0x8000:
                crc = ((crc << 1) ^ 0x1021) & 0xFFFF
            else:
                crc = (crc << 1) & 0xFFFF
    return crc


def aes_ecb(key: bytes, data: bytes, decrypt: bool = False) -> bytes:
    """AES/ECB/NoPadding (CipherFrameCodec.java). Key 16, 24 or 32 bytes."""
    if len(key) not in (16, 24, 32):
        raise ValueError(f"AES key must be 16/24/32 bytes, got {len(key)}")
    if len(data) % 16:
        raise ValueError(f"AES input must be a multiple of 16 bytes, got {len(data)}")
    cipher = Cipher(algorithms.AES(key), modes.ECB())
    op = cipher.decryptor() if decrypt else cipher.encryptor()
    return op.update(data) + op.finalize()


def make_packet(payload: bytes, cmd: int) -> bytes:
    """XModem.makePacket: [00 C0 00 LEN CMD payload CRC_lo CRC_hi], LEN = len(payload) + 1."""
    if len(payload) > 240:
        raise ValueError("payload too long for one frame")
    body = bytes([0x00, 0xC0, 0x00, len(payload) + 1, cmd]) + payload
    crc = crc16_xmodem(body)
    return body + bytes([crc & 0xFF, crc >> 8])


def bind(frame: bytes, eslid: bytes) -> bytes:
    """XModem.newPacket: replace the frame CRC with one computed over (frame without CRC) + ESL ID."""
    body = frame[:-2] + eslid
    crc = crc16_xmodem(body)
    return frame[:-2] + bytes([crc & 0xFF, crc >> 8])


def send_esl_id() -> bytes:
    return make_packet(b"", CMD_SEND_ESL_ID)


def get_random(key: bytes) -> bytes:
    return make_packet(aes_ecb(key, bytes([0x00, 0x00, 0x10, 0x01]) + bytes(12)), CMD_GET_RANDOM)


def send_random(encrypted_challenge: bytes) -> bytes:
    return make_packet(bytes([0x00, 0x00, 0x10, 0x01]) + encrypted_challenge, CMD_SEND_RANDOM)


def heartbeat(key: bytes) -> bytes:
    """XModem.hb(): plaintext [03 11 00..]."""
    return make_packet(aes_ecb(key, bytes([0x03, 0x11]) + bytes(14)), CMD_HEARTBEAT)


def read_channel(key: bytes) -> bytes:
    """XModem.readHBCH(): plaintext [01 00..]."""
    return make_packet(aes_ecb(key, bytes([0x01]) + bytes(15)), CMD_READ_CHANNEL)


def led_plain(color: int, count: int) -> bytes:
    """XModem.light(): 17 bytes. Shorts are little-endian after the Java byte reversal."""
    return (
        bytes([0x48, 0xEC, 0x03, color, 0x03, 0x03])
        + (30).to_bytes(2, "little")
        + count.to_bytes(2, "little")
        + bytes(2)
        + bytes([0x00])
        + bytes(4)
    )


def shut_plain() -> bytes:
    """XModem.shutLight(): 17 bytes, same layout with colour 0 and count 0."""
    return bytes([0x48, 0xEC, 0x03, 0x00, 0x00, 0x00]) + bytes(6) + bytes([0x00]) + bytes(4)


def _led_payload(key: bytes, plain: bytes) -> bytes:
    if len(plain) != 17:
        raise ValueError("LED plaintext must be 17 bytes")
    # First 16 bytes are AES-ECB encrypted, the 17th byte is sent in clear (XModem.light).
    return aes_ecb(key, plain[:16]) + plain[16:]


def led(key: bytes, color: str | int, count: int) -> bytes:
    colour = LED_COLORS[color] if isinstance(color, str) else color
    if count not in LED_COUNTS:
        raise ValueError(f"count must be one of {LED_COUNTS}")
    return make_packet(_led_payload(key, led_plain(colour, count)), CMD_LED)


def shut_light(key: bytes) -> bytes:
    return make_packet(_led_payload(key, shut_plain()), CMD_LED)


def as_apdu(frame: bytes) -> bytes:
    """Experimental ISO 7816-4 case-3 wrapping of a frame.

    CLA=00 INS=C0 P1=00 P2=LEN, then Lc and the bytes after the 4-byte header (command
    code, payload, CRC). The Android app never does this. It is here to test whether the
    tag firmware accepts APDU framing. CoreNFC's NFCISO7816APDU serialises the same bytes.
    """
    data = frame[4:]
    return bytes([0x00, 0xC0, 0x00, frame[3], len(data)]) + data


def eslid_from_response(response: bytes) -> bytes:
    """getEslid(): response is [x, x, x, LEN, x, content...]; ESL ID is content[12..<16]."""
    if len(response) < 5:
        raise ProtocolError(f"short sendEslId response ({len(response)} bytes)")
    declared = response[3]
    if declared < 20 or len(response) < 5 + declared:
        raise ProtocolError(f"short ESL ID content (declared {declared}, have {len(response) - 5})")
    return response[5 + 12 : 5 + 16]


def channel_from_response(response: bytes, key: bytes) -> int:
    """readHBCH(..., true): block [5..<21] decrypts to [channel, ...]."""
    if len(response) < 21:
        raise ProtocolError(f"channel response too short ({len(response)} bytes)")
    return aes_ecb(key, response[5:21], decrypt=True)[0]


def classify(response: bytes) -> str:
    if response == SW_SUCCESS:
        return "sent"
    if response == SW_NO_PAGE:
        return "no_such_page"
    return "failed"


def vendor_ndef_message() -> bytes:
    """BaseNfcManagerActy.createTextRecord: one well-known text record, language 'zh'."""
    text = VENDOR_NDEF_TEXT.encode("utf-8")
    payload = bytes([len(b"zh")]) + b"zh" + text
    return bytes([0xD1, 0x01, len(payload), 0x54]) + payload


def t4t_ndef_write_apdus(message: bytes) -> list[bytes]:
    """NFC Forum Type 4 tag write: select the NDEF application and file, clear NLEN, write, set NLEN."""
    if len(message) > 0xFF:
        raise ValueError("message too long for a short UPDATE BINARY")
    n = len(message)
    return [
        bytes.fromhex("00A4040007D2760000850101" + "00"),
        bytes.fromhex("00A4000C02E104"),
        bytes.fromhex("00D6000002") + bytes(2),
        bytes([0x00, 0xD6, 0x00, 0x02, n]) + message,
        bytes([0x00, 0xD6, 0x00, 0x00, 0x02, n >> 8, n & 0xFF]),
    ]


class TagTransport(Protocol):
    """One open tag. Mirrors ESLTagTransport in the iOS Core."""

    def write_vendor_ndef(self) -> None: ...

    def transceive(self, frame: bytes) -> bytes: ...


VIA_RAW = "raw"
VIA_APDU = "apdu"
VIAS = (VIA_RAW, VIA_APDU)


def exchange(tag: TagTransport, frame: bytes, via: str = VIA_RAW) -> bytes:
    """Sends one frame the selected way. Mirrors HeartbeatSession.exchange in the iOS Core.

    raw:  the frame as is (Android IsoDep.transceive).
    apdu: the frame wrapped by as_apdu(). A trailing 90 00 after data is dropped so the parsers see
          the same bytes as on the raw path; a bare status word is passed through. This assumes the
          firmware answers an APDU with its usual reply followed by a status word.
    """
    if via == VIA_RAW:
        return tag.transceive(frame)
    if via == VIA_APDU:
        response = tag.transceive(as_apdu(frame))
        if len(response) > 2 and response[-2:] == SW_SUCCESS:
            return response[:-2]
        return response
    raise ValueError(f"via must be one of {VIAS}")


def authenticate(tag: TagTransport, key: bytes, via: str = VIA_RAW) -> bytes:
    """Steps 0 to 4 of the Android session. Returns the ESL ID."""
    tag.write_vendor_ndef()
    eslid = eslid_from_response(exchange(tag, send_esl_id(), via))
    challenge = exchange(tag, get_random(key), via)
    if challenge == SW_KEY_ERROR:
        raise KeyRejected("challenge answered 6A 82")
    if len(challenge) != 16:
        raise ProtocolError(f"challenge must be 16 bytes, got {len(challenge)}")
    exchange(tag, send_random(aes_ecb(key, challenge)), via)
    tag.last_eslid = eslid  # kept for logging; not part of the protocol
    return eslid


def session_heartbeat(tag: TagTransport, key: bytes, via: str = VIA_RAW) -> str:
    frame = heartbeat(key)
    eslid = authenticate(tag, key, via)
    return classify(exchange(tag, bind(frame, eslid), via))


def session_read_channel(tag: TagTransport, key: bytes, via: str = VIA_RAW) -> int:
    frame = read_channel(key)
    eslid = authenticate(tag, key, via)
    return channel_from_response(exchange(tag, bind(frame, eslid), via), key)


def session_led(tag: TagTransport, key: bytes, color: str | int, count: int, via: str = VIA_RAW) -> str:
    frame = led(key, color, count)
    eslid = authenticate(tag, key, via)
    return classify(exchange(tag, bind(frame, eslid), via))


def session_shut_light(tag: TagTransport, key: bytes, via: str = VIA_RAW) -> str:
    """LightActy's 'off' path: handshake, then the frame."""
    frame = shut_light(key)
    eslid = authenticate(tag, key, via)
    return classify(exchange(tag, bind(frame, eslid), via))


def session_shut_light_raw(tag: TagTransport, key: bytes, via: str = VIA_RAW) -> bytes:
    """ShutLightActy's path: the frame is sent directly, with no NDEF write and no handshake."""
    return exchange(tag, shut_light(key), via)
