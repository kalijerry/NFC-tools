"""Command line for the ESL heartbeat, channel and LED experiments (needs a PC/SC reader).

Examples:
    python3 esl_monitor.py once --mode led --via apdu --color red --count 10
    python3 esl_monitor.py monitor --mode channel --csv channels.csv

The key comes from --key-b64 or the ESL_KEY_B64 environment variable. The default is
16 bytes of 0xFF, which is what the Android app uses when no login has stored a key.
"""

import argparse
import base64
import csv
import datetime
import os
import sys

import esl_core as core
from acr122_transport import PcscTagSource, ReaderError, find_reader
from esl_core import ProtocolError

DEFAULT_KEY_B64 = "/////////////////////w=="
MODES = ("channel", "heartbeat", "led", "shutlight", "shutlight-raw")
MONITOR_MODES = ("channel", "heartbeat")


def load_key(arg_value: str | None) -> bytes:
    raw = arg_value or os.environ.get("ESL_KEY_B64") or DEFAULT_KEY_B64
    key = base64.b64decode(raw, validate=True)
    if len(key) not in (16, 24, 32):
        raise SystemExit(f"key must decode to 16/24/32 bytes, got {len(key)}")
    return key


def run_mode(tag, key: bytes, mode: str, color: str, count: int, via: str = core.VIA_RAW) -> dict:
    """Runs one session. Returns a flat dict so it can go to stdout or CSV."""
    if mode == "channel":
        raw = core.session_read_channel(tag, key, via)
        return {
            "result": f"channel {raw}",
            "channel_raw": raw,
            "channel_android_signed": raw - 256 if raw > 127 else raw,
        }
    if mode == "heartbeat":
        return {"result": core.session_heartbeat(tag, key, via)}
    if mode == "led":
        return {"result": core.session_led(tag, key, color, count, via)}
    if mode == "shutlight":
        return {"result": core.session_shut_light(tag, key, via)}
    if mode == "shutlight-raw":
        return {"result": "response " + core.session_shut_light_raw(tag, key, via).hex()}
    raise SystemExit(f"unknown mode {mode}")


def make_row(mode: str, tag, outcome: dict | None, error: str | None, via: str = core.VIA_RAW) -> dict:
    eslid = getattr(tag, "last_eslid", None)
    row = {
        "time": datetime.datetime.now().isoformat(timespec="seconds"),
        "mode": mode,
        "via": via,
        "eslid": eslid.hex() if eslid else "",
        "status": "error" if error else "ok",
        "detail": error or "",
    }
    if outcome:
        row.update(outcome)
    return row


def run_one(tag, key: bytes, mode: str, color: str = "red", count: int = 10, via: str = core.VIA_RAW) -> dict:
    """One tag, one session. Protocol and reader errors become an 'error' row instead of raising."""
    try:
        return make_row(mode, tag, run_mode(tag, key, mode, color, count, via), None, via)
    except (ProtocolError, ReaderError) as exc:
        return make_row(mode, tag, None, str(exc), via)


def run_monitor(source, key: bytes, mode: str, on_row, max_tags: int = 0, via: str = core.VIA_RAW) -> list[dict]:
    """Loop: wait for a tag, run one session, report, wait for it to leave, repeat.

    `source` needs wait_for_tag() and wait_for_removal(). PcscTagSource is the real one.
    Returns after max_tags tags (0 = never; stop with Ctrl-C from the caller).
    """
    rows = []
    while True:
        tag = source.wait_for_tag()
        row = run_one(tag, key, mode, via=via)
        rows.append(row)
        on_row(row)
        source.wait_for_removal()
        if max_tags and len(rows) >= max_tags:
            return rows


def cmd_once(args) -> int:
    key = load_key(args.key_b64)
    source = PcscTagSource(find_reader(args.reader), write_ndef=not args.no_ndef)
    print("waiting for a tag (Ctrl-C to cancel)...", file=sys.stderr)
    tag = source.wait_for_tag()
    row = run_one(tag, key, args.mode, args.color, args.count, args.via)
    for name, value in row.items():
        print(f"{name:>10}: {value}")
    return 0 if row["status"] == "ok" else 1


def cmd_monitor(args) -> int:
    key = load_key(args.key_b64)
    source = PcscTagSource(find_reader(args.reader), write_ndef=not args.no_ndef)
    sink = open(args.csv, "a", newline="", encoding="utf-8") if args.csv else None
    writer = None

    def on_row(row: dict) -> None:
        nonlocal writer
        print(row)
        if sink is None:
            return
        if writer is None:
            writer = csv.DictWriter(sink, fieldnames=sorted(row.keys()), extrasaction="ignore")
            if sink.tell() == 0:
                writer.writeheader()
        writer.writerow(row)
        sink.flush()

    print(f"monitoring mode={args.mode}. Place one tag at a time. Ctrl-C to stop.", file=sys.stderr)
    try:
        run_monitor(source, key, args.mode, on_row, args.max_tags, args.via)
    except KeyboardInterrupt:
        print("stopped", file=sys.stderr)
    finally:
        if sink:
            sink.close()
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--key-b64", help="AES key, base64 (default: ESL_KEY_B64 or 16 x 0xFF)")
    common.add_argument("--reader", help="substring of the PC/SC reader name")
    common.add_argument("--no-ndef", action="store_true", help="skip the vendor NDEF write before each session")
    common.add_argument("--via", choices=core.VIAS, default=core.VIA_RAW,
                        help="raw: Android framing. apdu: every frame wrapped as ISO 7816 (what iOS can send)")

    once = sub.add_parser("once", parents=[common], help="wait for one tag and run one mode")
    once.add_argument("--mode", choices=MODES, required=True)
    once.add_argument("--color", choices=sorted(core.LED_COLORS), default="red")
    once.add_argument("--count", type=int, choices=core.LED_COUNTS, default=10)
    once.set_defaults(func=cmd_once)

    mon = sub.add_parser("monitor", parents=[common], help="loop: one tag at a time, log each result")
    mon.add_argument("--mode", choices=MONITOR_MODES, required=True)
    mon.add_argument("--csv", help="append results to this CSV file")
    mon.add_argument("--max-tags", type=int, default=0, help="stop after N tags (0 = run until Ctrl-C)")
    mon.set_defaults(func=cmd_monitor)
    return parser


if __name__ == "__main__":
    args = build_parser().parse_args()
    sys.exit(args.func(args))
