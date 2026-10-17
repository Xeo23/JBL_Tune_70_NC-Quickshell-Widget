#!/usr/bin/env python3
"""JBL Tune 770NC ANC control over Airoha RACE (RFCOMM ch21).

Usage: ./anc.py is_connected | battery | get | on | anc | off | ambient | aware | talkthru | poweroff
"""
import socket
import struct
import sys
import time
import datetime
import subprocess
import re

BD = "{your_headset_bluetooth}"
CHANNEL = 21

MODE_NAMES = {0x00: "OFF", 0x01: "ANC", 0x09: "TalkThru", 0x0A: "AmbientAware"}
SETTERS = {
    "on": "00 0A 01",
    "anc": "00 0A 01",
    "off": "00 0B",
    "ambient": "00 0A 0A",
    "aware": "00 0A 0A",
    "talkthru": "00 0A 09",
}


def build_req(op, payload):
    return struct.pack("<BBH", 0x05, 0x5A, 2 + len(payload)) + struct.pack("<H", op) + payload


def parse(buf):
    frames = []
    while len(buf) >= 6 and buf[0] == 0x05:
        ln = struct.unpack_from("<H", buf, 2)[0]
        if len(buf) < 6 + ln - 2:
            break
        frames.append((buf[1], struct.unpack_from("<H", buf, 4)[0], buf[6:6 + ln - 2]))
        buf = buf[6 + ln - 2:]
        if not buf:
            break
    return frames, buf


def drain(s, secs, label, stop_op=None, min_body_len=0):
    """Read and print complete protocol frames, optionally stopping on a response."""
    buf = b""
    got = False
    end = time.monotonic() + secs
    while True:
        remaining = end - time.monotonic()
        if remaining <= 0:
            break
        # Poll in short intervals so we can react immediately when a full frame arrives,
        # rather than blocking for the socket's original 2-second timeout.
        s.settimeout(min(0.2, remaining))
        try:
            chunk = s.recv(4096)
        except socket.timeout:
            continue
        if not chunk:
            break
        buf += chunk
        frames, buf = parse(buf)
        for t, o, p in frames:
            ts = datetime.datetime.now().strftime("%H:%M:%S")
            extra = ""
            if o == 0x0901 and len(p) >= 4:
                extra = f"  (mode={MODE_NAMES.get(p[3], '0x%02X' % p[3])})"
            print(f"[{ts} {label}] type=0x{t:02X} op=0x{o:04X} body={p.hex(' ')}{extra}", flush=True)
            got = True
            if stop_op is not None and o == stop_op and len(p) >= min_body_len:
                return got
    return got


def connect():
    for attempt in range(3):
        s = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_STREAM, socket.BTPROTO_RFCOMM)
        # Keep connection attempts bounded, but avoid the old 3-second pause
        # between retries. Successful connections proceed straight to the command.
        s.settimeout(2.0)
        try:
            s.connect((BD, CHANNEL))
            return s
        except OSError:
            s.close()
            if attempt < 2:
                time.sleep(0.4)
    raise SystemExit("RFCOMM connect failed (is the headset paired/on?)")


def is_device_connected():
    """Check BlueZ connection state without opening an RFCOMM session."""
    try:
        result = subprocess.run(
            ["bluetoothctl", "info", BD],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        print("DISCONNECTED", flush=True)
        return 1

    info = result.stdout + "\n" + result.stderr
    for line in info.splitlines():
        if line.strip().lower() == "connected: yes":
            print("CONNECTED", flush=True)
            return 0
    print("DISCONNECTED", flush=True)
    return 1


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "get"
    if cmd == "is_connected":
        raise SystemExit(is_device_connected())
    if cmd == "battery":
        try:
            result = subprocess.run(
                ["bluetoothctl", "info", BD], capture_output=True, text=True,
                timeout=5, check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            print("UNKNOWN", flush=True)
            raise SystemExit(1)
        info = result.stdout + "\n" + result.stderr
        # BlueZ commonly reports: Battery Percentage: 0x5a (90)
        # Other versions may print a plain percentage, e.g. 90%.
        match = re.search(r"Battery Percentage:\s*(?:0x[0-9a-fA-F]+\s*)?\((\d{1,3})\)", info, re.I)
        if not match:
            match = re.search(r"Battery Percentage:\s*(\d{1,3})%?\s*$", info, re.I | re.M)
        if match and 0 <= int(match.group(1)) <= 100:
            print(int(match.group(1)), flush=True)
            return
        print("UNKNOWN", flush=True)
        raise SystemExit(1)
    if cmd not in ("get", "poweroff", *SETTERS.keys()):
        raise SystemExit(f"Unknown command: {cmd}")
    s = connect()

    if cmd == "poweroff":
        s.sendall(build_req(0x1101, bytes.fromhex("18 00")))
        print(f"SEND 0x1101 [18 00] ({cmd})", flush=True)
        s.close()
        return
    elif cmd == "get":
        s.sendall(build_req(0x0901, bytes.fromhex("05 00")))
        # A complete 0x0901 frame with the mode byte is enough; don't wait out 3 seconds.
        drain(s, 3, "response", stop_op=0x0901, min_body_len=4)
        s.close()
        return

    payload = bytes.fromhex(SETTERS[cmd])
    print(f"SEND 0x0E06 [{payload.hex(' ')}] ({cmd})", flush=True)
    s.sendall(build_req(0x0E06, payload))
    # Mode-changing commands normally report the resulting mode in a 0x0901
    # frame. Return as soon as that complete response arrives; retain a bounded
    # fallback for devices/commands that do not report it.
    drain(s, 2.5, "response", stop_op=0x0901, min_body_len=4)
    s.close()


if __name__ == "__main__":
    main()
