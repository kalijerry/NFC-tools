"""PC/SC transport for ACR122U-class readers (pyscard). Needs a physical reader.

Two ways to put bytes on the air, both over the reader's pseudo-APDU interface:

* raw:   PN532 InDataExchange (D4 40 01 <payload>). The payload is an ISO-DEP I-block
         body, the same thing Android's IsoDep.transceive() sends.
* apdu:  the same InDataExchange, but the payload is an ISO 7816-4 APDU. This is the
         experiment that matches what iOS CoreNFC would send through NFCISO7816APDU.

UNVERIFIED on hardware. The reply layout (D5 41 <status> <data>, then SW 90 00 from the
reader) is taken from the PN532 and ACR122U documentation, not from a test run.
"""

import time

from esl_core import ProtocolError, t4t_ndef_write_apdus, vendor_ndef_message


class TagLost(ProtocolError):
    """The PN532 reported that the target is gone."""


class ReaderError(ProtocolError):
    """The reader or the card returned an unexpected status word."""


class Acr122Tag:
    """One activated tag behind a pyscard CardConnection."""

    def __init__(self, connection, write_ndef: bool = True):
        self._conn = connection
        self._write_ndef = write_ndef
        self.last_eslid = None

    def _apdu(self, apdu: bytes) -> bytes:
        data, sw1, sw2 = self._conn.transmit(list(apdu))
        if (sw1, sw2) != (0x90, 0x00):
            raise ReaderError(f"card returned SW {sw1:02X}{sw2:02X} for {apdu.hex()}")
        return bytes(data)

    def uid(self) -> bytes:
        return self._apdu(bytes.fromhex("FFCA000000"))

    def write_vendor_ndef(self) -> None:
        if not self._write_ndef:
            return
        for apdu in t4t_ndef_write_apdus(vendor_ndef_message()):
            self._apdu(apdu)

    def _in_data_exchange(self, payload: bytes) -> bytes:
        pn532 = bytes([0xD4, 0x40, 0x01]) + payload
        pseudo = bytes([0xFF, 0x00, 0x00, 0x00, len(pn532)]) + pn532
        data, sw1, sw2 = self._conn.transmit(list(pseudo))
        if (sw1, sw2) != (0x90, 0x00):
            raise ReaderError(f"reader returned SW {sw1:02X}{sw2:02X}")
        reply = bytes(data)
        if len(reply) < 3 or reply[:2] != bytes([0xD5, 0x41]):
            raise ReaderError(f"unexpected PN532 reply {reply.hex()}")
        if reply[2] != 0x00:
            raise TagLost(f"PN532 status {reply[2]:02X}")
        return reply[3:]

    def transceive(self, frame: bytes) -> bytes:
        """Raw frame: same bytes as Android IsoDep.transceive()."""
        return self._in_data_exchange(frame)

    def transceive_apdu(self, apdu: bytes) -> bytes:
        """ISO 7816-4 APDU carried as the ISO-DEP payload. Returns response data plus SW."""
        return self._in_data_exchange(apdu)


class PcscTagSource:
    """Waits for a tag on a PC/SC reader. Polls because pyscard has no blocking event API here."""

    def __init__(self, reader, poll_seconds: float = 0.3, write_ndef: bool = True):
        self._reader = reader
        self._poll = poll_seconds
        self._write_ndef = write_ndef

    def _connect(self):
        connection = self._reader.createConnection()
        connection.connect()
        return connection

    def wait_for_tag(self) -> Acr122Tag:
        from smartcard.Exceptions import NoCardException

        while True:
            try:
                return Acr122Tag(self._connect(), write_ndef=self._write_ndef)
            except NoCardException:
                time.sleep(self._poll)

    def wait_for_removal(self) -> None:
        from smartcard.Exceptions import NoCardException

        while True:
            try:
                self._connect()
            except NoCardException:
                return
            time.sleep(self._poll)


def find_reader(name_hint: str | None = None):
    from smartcard.System import readers

    available = readers()
    if not available:
        raise SystemExit("no PC/SC reader found. Plug in an ACR122U-class reader and retry.")
    if name_hint:
        for reader in available:
            if name_hint.lower() in str(reader).lower():
                return reader
        raise SystemExit(f"no reader matches {name_hint!r}; available: {available}")
    for reader in available:
        if "acr122" in str(reader).lower():
            return reader
    return available[0]
