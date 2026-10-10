"""End-to-end tests of the Mac path, using a simulated reader and simulated tag firmware.

No hardware. These exercise the reader framing (pseudo-APDU InDataExchange), the Type 4 NDEF
write, card presence, and the monitor loop, against the simulated card. Whether a real ACR122U
or a real ESL tag behaves this way is NOT tested here. See simulated_reader.py.
Run:  python3 -m unittest discover -s . -p 'test_*.py'
"""

import unittest

import esl_core as core
import esl_monitor
from acr122_transport import Acr122Tag, PcscTagSource, TagLost
from esl_core import SW_KEY_ERROR, SW_SUCCESS, KeyRejected
from simulated_reader import SimulatedCard, SimulatedEslFirmware, SimulatedReader

KEY = bytes([0xFF] * 16)


def make_tag(firmware: SimulatedEslFirmware, **reader_kwargs) -> tuple[Acr122Tag, SimulatedCard]:
    card = SimulatedCard(firmware)
    reader = SimulatedReader(card, **reader_kwargs)
    return Acr122Tag(reader.createConnection(), write_ndef=True), card


class ReaderAndNdef(unittest.TestCase):
    def test_vendor_ndef_is_written_through_the_reader(self):
        tag, card = make_tag(SimulatedEslFirmware(KEY))
        tag.write_vendor_ndef()
        self.assertEqual(card.ndef.ndef_message(), core.vendor_ndef_message())

    def test_no_ndef_write_when_disabled(self):
        card = SimulatedCard(SimulatedEslFirmware(KEY))
        tag = Acr122Tag(SimulatedReader(card).createConnection(), write_ndef=False)
        tag.write_vendor_ndef()
        self.assertEqual(card.ndef.ndef_message(), b"")

    def test_uid_round_trip(self):
        tag, _ = make_tag(SimulatedEslFirmware(KEY))
        self.assertEqual(tag.uid().hex(), "04a1b2c3d4")


class SessionsOverReader(unittest.TestCase):
    def test_heartbeat_session(self):
        firmware = SimulatedEslFirmware(KEY)
        tag, card = make_tag(firmware)
        self.assertEqual(core.session_heartbeat(tag, KEY), "sent")
        self.assertTrue(firmware.binding_ok)
        self.assertTrue(firmware.challenge_answered_ok)
        self.assertEqual(card.ndef.ndef_message(), core.vendor_ndef_message())
        self.assertEqual(tag.last_eslid.hex(), "1c1d1e1f")

    def test_read_channel_session(self):
        firmware = SimulatedEslFirmware(KEY, channel=77)
        tag, _ = make_tag(firmware)
        self.assertEqual(core.session_read_channel(tag, KEY), 77)

    def test_led_raw_session(self):
        firmware = SimulatedEslFirmware(KEY)
        tag, _ = make_tag(firmware)
        self.assertEqual(core.session_led(tag, KEY, "red", 10), "sent")
        self.assertEqual(firmware.led_plain_seen, core.led_plain(2, 10))
        self.assertTrue(firmware.binding_ok)

    def test_apdu_session_when_firmware_rejects_apdu(self):
        firmware = SimulatedEslFirmware(KEY, accept_apdu=False)
        tag, _ = make_tag(firmware)
        with self.assertRaises(core.ProtocolError):
            core.session_led(tag, KEY, "red", 10, via=core.VIA_APDU)
        self.assertEqual(len(firmware.apdu_payloads), 1)
        self.assertEqual(firmware.apdu_payloads[0], core.as_apdu(core.send_esl_id()))

    def test_apdu_session_when_firmware_accepts_apdu(self):
        firmware = SimulatedEslFirmware(KEY, accept_apdu=True)
        tag, _ = make_tag(firmware)
        self.assertEqual(core.session_led(tag, KEY, "red", 10, via=core.VIA_APDU), "sent")
        self.assertEqual(len(firmware.apdu_payloads), 4)
        self.assertEqual(firmware.led_plain_seen, core.led_plain(2, 10))
        self.assertEqual(core.session_read_channel(make_tag(SimulatedEslFirmware(KEY, accept_apdu=True))[0], KEY,
                                                   via=core.VIA_APDU), 151)

    def test_key_rejected_by_challenge(self):
        firmware = SimulatedEslFirmware(KEY, challenge=SW_KEY_ERROR)
        tag, _ = make_tag(firmware)
        with self.assertRaises(KeyRejected):
            core.session_heartbeat(tag, KEY)

    def test_reader_status_error_becomes_tag_lost(self):
        card = SimulatedCard(SimulatedEslFirmware(KEY))
        reader = SimulatedReader(card)
        reader.reply_status = 0x01  # PN532: timeout, target gone
        tag = Acr122Tag(reader.createConnection(), write_ndef=False)
        with self.assertRaises(TagLost):
            core.session_read_channel(tag, KEY)


class PresenceAndMonitor(unittest.TestCase):
    def test_wait_for_tag_then_removal(self):
        firmware = SimulatedEslFirmware(KEY, channel=151)
        card = SimulatedCard(firmware)
        reader = SimulatedReader(card, absent_polls=2, present_polls=2)
        source = PcscTagSource(reader, poll_seconds=0)
        tag = source.wait_for_tag()
        self.assertEqual(core.session_read_channel(tag, KEY), 151)
        source.wait_for_removal()
        self.assertIsNone(reader.card)

    def test_run_monitor_over_simulated_reader_one_tag(self):
        firmware = SimulatedEslFirmware(KEY, channel=151)
        reader = SimulatedReader(SimulatedCard(firmware), absent_polls=1, present_polls=2)
        source = PcscTagSource(reader, poll_seconds=0)
        rows = esl_monitor.run_monitor(source, KEY, "channel", on_row=lambda row: None, max_tags=1)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["status"], "ok")
        self.assertEqual(rows[0]["channel_raw"], 151)
        self.assertEqual(rows[0]["eslid"], "1c1d1e1f")

    def test_run_monitor_records_errors_and_continues(self):
        class ScriptedSource:
            def __init__(self, tags):
                self.tags = list(tags)
                self.removals = 0

            def wait_for_tag(self):
                return self.tags.pop(0)

            def wait_for_removal(self):
                self.removals += 1

        good, _ = make_tag(SimulatedEslFirmware(KEY, channel=77))
        rejected, _ = make_tag(SimulatedEslFirmware(KEY, challenge=SW_KEY_ERROR))
        other, _ = make_tag(SimulatedEslFirmware(KEY, channel=200))
        source = ScriptedSource([good, rejected, other])
        seen = []
        rows = esl_monitor.run_monitor(source, KEY, "channel", on_row=seen.append, max_tags=3)
        self.assertEqual([row["status"] for row in rows], ["ok", "error", "ok"])
        self.assertIn("6A 82", rows[1]["detail"])
        self.assertEqual(rows[2]["channel_android_signed"], -56)
        self.assertEqual(source.removals, 3)
        self.assertEqual(seen, rows)

    def test_run_monitor_heartbeat_mode(self):
        tag, _ = make_tag(SimulatedEslFirmware(KEY))
        row = esl_monitor.run_one(tag, KEY, "heartbeat")
        self.assertEqual(row["result"], "sent")


if __name__ == "__main__":
    unittest.main()
