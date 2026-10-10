"""Simulated PC/SC reader, card and ESL tag firmware, for offline end-to-end tests.

Nothing here has been measured on hardware. Three layers are modelled:

* the reader's pseudo-APDU framing (FF CA for the UID, FF 00 00 00 for InDataExchange),
  following the ACR122U / PN532 documentation as recalled;
* the card's NFC Forum Type 4 NDEF file, which the vendor NDEF write goes through;
* the ESL tag firmware, which answers ISO-DEP payloads the way the Android app expects.
  Its APDU handling is an assumption: `accept_apdu` chooses whether it answers APDU framing.

The tests show that the software layers agree with each other. They do not show that a real
reader or tag behaves this way.
"""

import esl_core as core
from acr122_transport import CardAbsent
from esl_core import SW_KEY_ERROR, SW_NO_PAGE, SW_SUCCESS

NDEF_AID = bytes.fromhex("D2760000850101")
NDEF_FILE_ID = bytes.fromhex("E104")


class SimulatedNdefCard:
    """Type 4 tag: NDEF application, one NDEF file (NLEN in the first two bytes)."""

    def __init__(self, size: int = 256):
        self.file = bytearray(size)
        self._app_selected = False
        self._file_selected = False

    def apdu(self, apdu: bytes) -> bytes:
        ins = apdu[1]
        if ins == 0xA4 and apdu[2] == 0x04:  # SELECT by name
            aid = apdu[5 : 5 + apdu[4]]
            self._app_selected = aid == NDEF_AID
            self._file_selected = False
            return SW_SUCCESS if self._app_selected else bytes([0x6A, 0x82])
        if ins == 0xA4 and apdu[2] == 0x00:  # SELECT by file id
            if self._app_selected and apdu[5:7] == NDEF_FILE_ID:
                self._file_selected = True
                return SW_SUCCESS
            return bytes([0x6A, 0x82])
        if ins == 0xD6:  # UPDATE BINARY
            if not self._file_selected:
                return bytes([0x69, 0x85])
            offset = (apdu[2] << 8) | apdu[3]
            data = apdu[5 : 5 + apdu[4]]
            self.file[offset : offset + len(data)] = data
            return SW_SUCCESS
        if ins == 0xB0:  # READ BINARY
            if not self._file_selected:
                return bytes([0x69, 0x85])
            offset = (apdu[2] << 8) | apdu[3]
            length = apdu[4]
            return bytes(self.file[offset : offset + length]) + SW_SUCCESS
        return bytes([0x6D, 0x00])

    def ndef_message(self) -> bytes:
        nlen = (self.file[0] << 8) | self.file[1]
        return bytes(self.file[2 : 2 + nlen])


class SimulatedEslFirmware:
    """Assumed tag firmware. Answers ISO-DEP payloads. Not measured on a real tag."""

    def __init__(self, key: bytes, *, accept_apdu: bool = False, eslid: bytes = bytes([0x1C, 0x1D, 0x1E, 0x1F]),
                 challenge: bytes = bytes(range(0xA0, 0xB0)), channel: int = 151):
        self.key = key
        self.accept_apdu = accept_apdu
        self.eslid = eslid
        self.challenge = challenge
        self.channel = channel
        self.heartbeat_status = SW_SUCCESS
        self.binding_ok = True
        self.challenge_answered_ok = False
        self.led_plain_seen = None
        self.apdu_payloads = []
        self.frames = []

    def _content(self) -> bytes:
        return bytes(range(0x10, 0x30))  # 20 bytes; ESL ID is bytes 12..15

    def iso_dep(self, payload: bytes) -> bytes:
        self.frames.append(payload)
        if len(payload) == payload[3] + 7:  # APDU framing: one byte longer than the raw frame
            self.apdu_payloads.append(payload)
            if not self.accept_apdu:
                return bytes([0x6A, 0x81])
            # Assumed behaviour: drop Lc, answer like the raw frame, end the reply with a status word.
            reply = self._raw(payload[:4] + payload[5:])
            return reply if len(reply) == 2 or reply[-2:] == SW_SUCCESS else reply + SW_SUCCESS
        return self._raw(payload)

    def _raw(self, payload: bytes) -> bytes:
        cmd = payload[4]
        if cmd == core.CMD_SEND_ESL_ID:
            return bytes([0x00, 0xC0, 0x00, 20, 0x00]) + self._content() + SW_SUCCESS
        if cmd == core.CMD_GET_RANDOM:
            return self.challenge  # 6A 82 here is how a key error shows up (set challenge = SW_KEY_ERROR)
        if cmd == core.CMD_SEND_RANDOM:
            encrypted = payload[9:25]
            self.challenge_answered_ok = core.aes_ecb(self.key, encrypted, decrypt=True) == self.challenge
            return SW_SUCCESS
        if cmd == core.CMD_HEARTBEAT:
            self.binding_ok = self.binding_ok and core.bind(payload, self.eslid) == payload
            return self.heartbeat_status
        if cmd == core.CMD_READ_CHANNEL:
            self.binding_ok = self.binding_ok and core.bind(payload, self.eslid) == payload
            block = core.aes_ecb(self.key, bytes([self.channel]) + bytes(15))
            return bytes([0x00, 0xC0, 0x00, 17, 0x0C]) + block + SW_SUCCESS
        if cmd == core.CMD_LED:
            self.binding_ok = self.binding_ok and core.bind(payload, self.eslid) == payload
            body = payload[5:-2]
            self.led_plain_seen = core.aes_ecb(self.key, body[:16], decrypt=True) + body[16:17]
            return SW_SUCCESS
        return bytes([0x6A, 0x81])


class SimulatedCard:
    """One tag: NDEF card plus ESL firmware, behind one reader."""

    def __init__(self, firmware: SimulatedEslFirmware):
        self.ndef = SimulatedNdefCard()
        self.firmware = firmware


class SimulatedConnection:
    def __init__(self, reader: "SimulatedReader"):
        self._reader = reader

    def connect(self):
        if not self._reader.card_present():
            raise CardAbsent()

    def transmit(self, apdu_list):
        data, sw1, sw2 = self._reader.transmit(bytes(apdu_list))
        return list(data), sw1, sw2


class SimulatedReader:
    """PC/SC reader with one card.

    absent_polls: connect() calls that report no card before the card appears.
    present_polls: connect() calls that report the card before it leaves the field.
    reply_status: if set, InDataExchange replies with this PN532 status (for error paths).
    """

    def __init__(self, card: SimulatedCard | None, *, absent_polls: int = 0, present_polls: int = 2):
        self.card = card
        self.absent_polls = absent_polls
        self.present_polls = present_polls
        self.reply_status = None

    def createConnection(self):
        return SimulatedConnection(self)

    def card_present(self) -> bool:
        if self.absent_polls > 0:
            self.absent_polls -= 1
            return False
        if self.card is None:
            return False
        if self.present_polls > 0:
            self.present_polls -= 1
            return True
        self.card = None  # the card leaves the field
        return False

    def transmit(self, apdu: bytes):
        if self.card is None:
            raise RuntimeError("transmit with no card in the field")
        if apdu == bytes.fromhex("FFCA000000"):
            return list(bytes.fromhex("04A1B2C3D4")), 0x90, 0x00  # fake UID
        if apdu[:4] == bytes([0xFF, 0x00, 0x00, 0x00]) and apdu[5:8] == bytes([0xD4, 0x40, 0x01]):
            payload = apdu[8:]
            if self.reply_status is not None:
                reply = bytes([0xD5, 0x41, self.reply_status])
            else:
                reply = bytes([0xD5, 0x41, 0x00]) + self.card.firmware.iso_dep(payload)
            return list(reply), 0x90, 0x00
        response = self.card.ndef.apdu(apdu)
        return list(response[:-2]), response[-2], response[-1]
