"""Offline tests for the ESL protocol port. No reader or tag needed.

Reference bytes come from an independent Python re-implementation of the Android
logic (oracle). They are the same vectors the Swift Core tests use.
Run:  python3 -m unittest discover -s . -p 'test_*.py'
"""

import unittest

import esl_core as core
import esl_monitor
from esl_core import SW_KEY_ERROR, SW_NO_PAGE, SW_SUCCESS, KeyRejected

KEY = bytes([0xFF] * 16)
ESLID = bytes([0x1C, 0x1D, 0x1E, 0x1F])
ESL_CONTENT = bytes(range(0x10, 0x30))  # 20 bytes; ESL ID is bytes 12..15
CHALLENGE = bytes(range(0xA0, 0xB0))


def h(text: str) -> bytes:
    return bytes.fromhex(text)


# Oracle vectors (key = 16 x 0xFF)
ORACLE = {
    "heartbeat": "00c000110a626102473f70635bb7e9070a255f8afd7777",
    "read_channel": "00c000110c2060b29484f017e238f2405b99001c0152c7",
    "send_esl_id": "00c000010530d0",
    "get_random": "00c0001102c851064f93e89855412717944948e21f2c20",
    "send_random_a0_af": "00c000150800001001fb09d86844a1c42a3bbaae688e876eb895a9",
    "heartbeat_bound": "00c000110a626102473f70635bb7e9070a255f8afdc5d8",
    "read_channel_bound": "00c000110c2060b29484f017e238f2405b99001c012244",
    "light_red_10": "00c0001200e5d043b266e69f7d5bad6bc26c4a88b70000bc",
    "light_blue_30": "00c00012005b763c1a5cbdb87323e20000551dfb4a007072",
    "light_green_20": "00c0001200a8669745fd9a1997e37e670255cfcead003301",
    "shut_frame": "00c00012002f70f523b26d5353184e1703bf8e5dc70011d0",
    "light_red_10_bound": "00c0001200e5d043b266e69f7d5bad6bc26c4a88b700e628",
    "shut_frame_bound": "00c00012002f70f523b26d5353184e1703bf8e5dc700554a",
    "channel_response": "00c000110c35c3b35884717dead42f7f0d386225ed9000",
}


class FakeTag:
    """Simulates the tag side of the Android session.

    A frame is treated as APDU-wrapped when len(frame) == frame[3] + 7. Raw frames have
    len == frame[3] + 6. `accept_apdu` decides whether the fake tag answers APDU frames.
    """

    def __init__(self, accept_apdu: bool = False):
        self.accept_apdu = accept_apdu
        self.challenge = CHALLENGE
        self.heartbeat_status = SW_SUCCESS
        self.channel = 151
        self.ndef_written = False
        self.binding_ok = True
        self.challenge_answered_ok = False
        self.led_plain_seen = None
        self.apdu_frames = []
        self.frames = []
        self.last_eslid = None

    def write_vendor_ndef(self):
        self.ndef_written = True

    def transceive(self, frame: bytes) -> bytes:
        self.frames.append(frame)
        if len(frame) == frame[3] + 7:
            self.apdu_frames.append(frame)
            if not self.accept_apdu:
                return bytes([0x6A, 0x81])
            reply = self._raw(frame[:4] + frame[5:])
            return reply if len(reply) == 2 or reply[-2:] == SW_SUCCESS else reply + SW_SUCCESS
        return self._raw(frame)

    def _raw(self, frame: bytes) -> bytes:
        cmd = frame[4]
        if cmd == core.CMD_SEND_ESL_ID:
            return bytes([0x00, 0xC0, 0x00, 20, 0x00]) + ESL_CONTENT + SW_SUCCESS
        if cmd == core.CMD_GET_RANDOM:
            return self.challenge
        if cmd == core.CMD_SEND_RANDOM:
            encrypted = frame[9:25]
            self.challenge_answered_ok = core.aes_ecb(KEY, encrypted, decrypt=True) == self.challenge
            return SW_SUCCESS
        if cmd == core.CMD_HEARTBEAT:
            self.binding_ok = self.binding_ok and core.bind(frame, ESLID) == frame
            return self.heartbeat_status
        if cmd == core.CMD_READ_CHANNEL:
            self.binding_ok = self.binding_ok and core.bind(frame, ESLID) == frame
            block = core.aes_ecb(KEY, bytes([self.channel]) + bytes(15))
            return bytes([0x00, 0xC0, 0x00, 17, 0x0C]) + block + SW_SUCCESS
        if cmd == core.CMD_LED:
            self.binding_ok = self.binding_ok and core.bind(frame, ESLID) == frame
            payload = frame[5:-2]
            self.led_plain_seen = core.aes_ecb(KEY, payload[:16], decrypt=True) + payload[16:17]
            return SW_SUCCESS
        return bytes([0x6A, 0x81])


class ProtocolVectors(unittest.TestCase):
    def test_crc_check_value(self):
        self.assertEqual(core.crc16_xmodem(b"123456789"), 0x31C3)

    def test_aes_fips_197(self):
        key = h("000102030405060708090a0b0c0d0e0f")
        plain = h("00112233445566778899aabbccddeeff")
        self.assertEqual(core.aes_ecb(key, plain).hex(), "69c4e0d86a7b0430d8cdb78070b4c55a")

    def test_raw_frames_match_oracle(self):
        self.assertEqual(core.heartbeat(KEY).hex(), ORACLE["heartbeat"])
        self.assertEqual(core.read_channel(KEY).hex(), ORACLE["read_channel"])
        self.assertEqual(core.send_esl_id().hex(), ORACLE["send_esl_id"])
        self.assertEqual(core.get_random(KEY).hex(), ORACLE["get_random"])
        challenge_enc = core.aes_ecb(KEY, CHALLENGE)
        self.assertEqual(core.send_random(challenge_enc).hex(), ORACLE["send_random_a0_af"])
        self.assertEqual(core.bind(core.heartbeat(KEY), ESLID).hex(), ORACLE["heartbeat_bound"])
        self.assertEqual(core.bind(core.read_channel(KEY), ESLID).hex(), ORACLE["read_channel_bound"])

    def test_led_frames_match_oracle(self):
        self.assertEqual(core.led(KEY, "red", 10).hex(), ORACLE["light_red_10"])
        self.assertEqual(core.led(KEY, "blue", 30).hex(), ORACLE["light_blue_30"])
        self.assertEqual(core.led(KEY, "green", 20).hex(), ORACLE["light_green_20"])
        self.assertEqual(core.shut_light(KEY).hex(), ORACLE["shut_frame"])
        self.assertEqual(core.bind(core.led(KEY, "red", 10), ESLID).hex(), ORACLE["light_red_10_bound"])
        self.assertEqual(core.bind(core.shut_light(KEY), ESLID).hex(), ORACLE["shut_frame_bound"])

    def test_led_plaintext_layout(self):
        plain = core.led_plain(2, 10)
        self.assertEqual(len(plain), 17)
        self.assertEqual(plain.hex(), "48ec030203031e000a0000000000000000")

    def test_vendor_ndef_message(self):
        message = core.vendor_ndef_message()
        self.assertEqual(message.hex(), "d1011254027a68e6b189e69c94e7a791e68a80453331")
        self.assertEqual(len(core.t4t_ndef_write_apdus(message)), 5)

    def test_apdu_wrapping_of_bound_led_frame(self):
        bound = h(ORACLE["light_red_10_bound"])
        apdu = core.as_apdu(bound)
        self.assertEqual(apdu.hex(), "00c0001214" + ORACLE["light_red_10_bound"][8:])
        self.assertEqual(len(apdu), len(bound) + 1)

    def test_eslid_and_channel_parsing(self):
        response = bytes([0x00, 0xC0, 0x00, 20, 0x00]) + ESL_CONTENT + SW_SUCCESS
        self.assertEqual(core.eslid_from_response(response), ESLID)
        self.assertEqual(core.channel_from_response(h(ORACLE["channel_response"]), KEY), 151)

    def test_short_responses_are_rejected(self):
        with self.assertRaises(core.ProtocolError):
            core.eslid_from_response(bytes([0x00, 0xC0, 0x00, 10, 0x00, 1, 2]))
        with self.assertRaises(core.ProtocolError):
            core.channel_from_response(bytes(10), KEY)


class Sessions(unittest.TestCase):
    def test_heartbeat_success(self):
        tag = FakeTag()
        self.assertEqual(core.session_heartbeat(tag, KEY), "sent")
        self.assertTrue(tag.ndef_written)
        self.assertTrue(tag.binding_ok)
        self.assertTrue(tag.challenge_answered_ok)
        self.assertEqual(tag.last_eslid, ESLID)

    def test_heartbeat_status_mapping(self):
        tag = FakeTag()
        tag.heartbeat_status = SW_NO_PAGE
        self.assertEqual(core.session_heartbeat(tag, KEY), "no_such_page")
        tag.heartbeat_status = bytes([0x6A, 0x00])
        self.assertEqual(core.session_heartbeat(tag, KEY), "failed")

    def test_key_rejected_raises(self):
        tag = FakeTag()
        tag.challenge = SW_KEY_ERROR
        with self.assertRaises(KeyRejected):
            core.session_heartbeat(tag, KEY)

    def test_read_channel(self):
        self.assertEqual(core.session_read_channel(FakeTag(), KEY), 151)

    def test_led_raw_session_sends_expected_plaintext(self):
        tag = FakeTag()
        self.assertEqual(core.session_led(tag, KEY, "red", 10), "sent")
        self.assertEqual(tag.led_plain_seen, core.led_plain(2, 10))
        self.assertTrue(tag.binding_ok)

    def test_apdu_session_rejected_by_fake_firmware_fails_at_first_frame(self):
        tag = FakeTag(accept_apdu=False)
        with self.assertRaises(core.ProtocolError):
            core.session_led(tag, KEY, "red", 10, via=core.VIA_APDU)
        self.assertEqual(len(tag.apdu_frames), 1)
        self.assertEqual(tag.apdu_frames[0], core.as_apdu(core.send_esl_id()))
        self.assertIsNone(tag.led_plain_seen)

    def test_apdu_session_accepted_by_fake_firmware(self):
        tag = FakeTag(accept_apdu=True)
        self.assertEqual(core.session_led(tag, KEY, "red", 10, via=core.VIA_APDU), "sent")
        self.assertEqual(len(tag.apdu_frames), 4)  # sendEslId, getRandom, sendRandom, LED
        self.assertEqual(tag.apdu_frames[3].hex(), "00c0001214" + ORACLE["light_red_10_bound"][8:])
        self.assertEqual(tag.led_plain_seen, core.led_plain(2, 10))
        self.assertTrue(tag.binding_ok and tag.challenge_answered_ok)

    def test_apdu_heartbeat_and_channel(self):
        self.assertEqual(core.session_heartbeat(FakeTag(accept_apdu=True), KEY, via=core.VIA_APDU), "sent")
        self.assertEqual(core.session_read_channel(FakeTag(accept_apdu=True), KEY, via=core.VIA_APDU), 151)

    def test_apdu_key_rejected(self):
        tag = FakeTag(accept_apdu=True)
        tag.challenge = SW_KEY_ERROR
        with self.assertRaises(KeyRejected):
            core.session_heartbeat(tag, KEY, via=core.VIA_APDU)

    def test_shut_light_paths(self):
        tag = FakeTag()
        self.assertEqual(core.session_shut_light(tag, KEY), "sent")
        raw_tag = FakeTag()
        self.assertEqual(core.session_shut_light_raw(raw_tag, KEY), SW_SUCCESS)
        self.assertFalse(raw_tag.ndef_written)
        self.assertEqual(raw_tag.frames[0].hex(), ORACLE["shut_frame"])


class CliHelpers(unittest.TestCase):
    def test_run_mode_channel_reports_signed_value(self):
        tag = FakeTag()
        tag.channel = 200
        outcome = esl_monitor.run_mode(tag, KEY, "channel", "red", 10)
        self.assertEqual(outcome["channel_raw"], 200)
        self.assertEqual(outcome["channel_android_signed"], -56)

    def test_load_key_rejects_bad_length(self):
        with self.assertRaises(SystemExit):
            esl_monitor.load_key("AAAA")


if __name__ == "__main__":
    unittest.main()
