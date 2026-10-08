# mac-bridge: PC/SC experiments for the ESL heartbeat, channel and LED frames

A Mac with a PC/SC reader (ACR122U-class) can talk to ESL tags directly. This is the
workaround for the CoreNFC limit: raw ISO-DEP frames go out through the reader's
InDataExchange, the same bytes Android's `IsoDep.transceive` sends.

## What is tested, and what is not

| Item | Status |
|---|---|
| Frame bytes (heartbeat, channel, LED, shut-off, challenge, CRC binding) | Tested offline, against Java-derived oracle vectors |
| ISO 7816 APDU wrapping of the LED frame | Bytes tested offline. Tag response **not tested** (no reader or tag here) |
| Reader I/O (pyscard, ACR122U) | **Not tested**: no reader was connected when this was written |

## Offline tests (no hardware)

```bash
python3 -m pip install -r requirements.txt   # or: pip install cryptography
python3 -m unittest discover -s . -p 'test_*.py' -v
```

## Hardware test (needs an ACR122U-class reader and one spare tag)

```bash
export ESL_KEY_B64='...'   # the key from your backend; default is 16 x 0xFF
python3 esl_monitor.py once --mode channel           # raw frame, same as Android's read-channel
python3 esl_monitor.py once --mode heartbeat         # raw frame, handshake + heartbeat
python3 esl_monitor.py once --mode led --color red --count 10          # raw LED frame
python3 esl_monitor.py once --mode led-apdu --color red --count 10     # ISO 7816 APDU experiment
python3 esl_monitor.py monitor --mode channel --csv channels.csv       # long monitoring
```

Use one tag at a time. Several tags in the field collide.

### How to read the APDU experiment

`led-apdu` sends the bound LED frame wrapped as `00 C0 00 LEN Lc <cmd payload crc>`.
The tag firmware decides what it accepts.

- `90 00` and the LED lights: the APDU route works, and iOS CoreNFC can do the same.
- `6A 81`, `6D 00`, `6E 00` or no reply: the firmware does not accept this framing. Raw
  frames then need another transport, such as an external raw-ISO-DEP reader connected to the iPhone.

Run it on a spare tag first. The LED command is harmless, but an unexpected response on a
live shelf tag is not worth the risk.

## Files

- `esl_core.py`: frame builders, CRC, AES, session logic. No hardware.
- `acr122_transport.py`: pyscard transport and tag source. Needs a reader.
- `esl_monitor.py`: command line (`once`, `monitor`).
- `test_esl_core.py`: offline tests.

## Unverified assumptions in the reader code

- The reply to a pseudo-APDU InDataExchange is `D5 41 <status> <data>` followed by `90 00`.
- An ACR122U-class reader auto-activates the ISO 14443-4 tag (RATS), so the NDEF write and
  raw exchanges work without manual activation.
- NDEF is written with NFC Forum Type 4 APDUs. `--no-ndef` skips the write if the tag
  rejects it.

Each of these is a guess from documentation. The first hardware run will confirm or refute them.
