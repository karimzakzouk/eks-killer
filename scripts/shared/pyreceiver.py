#!/usr/bin/env python3
import socket
import sys
import os
import hashlib

port = int(sys.argv[1]) if len(sys.argv) > 1 else 7777
out_file = sys.argv[2] if len(sys.argv) > 2 else "/opt/eks-killer/incoming-bundle.tar"

HEADER_MAGIC = b"ESKSUM"
HEADER_TOTAL_BYTES = 129  # 128-byte fixed ASCII header + 1 newline

print(f"[pyreceiver] Listening on port {port} -> {out_file}", flush=True)

def extract_header_fields(header_text: str):
    """Parse the 128-byte ASCII header: "ESKSUM sha256=<64-hex> size=<19-decimal> "
    Returns (expected_sha256_hex, expected_size_int) or raises ValueError."""
    try:
        after_magic = header_text.split("sha256=", 1)[1]
        hash_part, size_part_raw = after_magic.split(" size=", 1)
        expected_hash = hash_part.strip()
        # size field may be right-padded with spaces; stop at first non-decimal
        size_digits = ""
        for ch in size_part_raw:
            if ch.isdigit():
                size_digits += ch
            else:
                break
        expected_size = int(size_digits)
        if len(expected_hash) != 64:
            raise ValueError(f"bad hash length {len(expected_hash)}")
        return expected_hash, expected_size
    except Exception as e:
        raise ValueError(f"header parse failed: {e!r}") from e

def validate_framed_stream(tmp_file: str, expected_hash: str, expected_size: int):
    """Validate that the payload portion (bytes 129..end) matches the declared
    hash + size in the header. Returns the actual payload size on success, or
    raises ValueError describing the failure."""
    actual_size = os.path.getsize(tmp_file) - HEADER_TOTAL_BYTES
    if actual_size < 0:
        raise ValueError(f"stream smaller than framing header ({os.path.getsize(tmp_file)} bytes total)")
    if actual_size != expected_size:
        raise ValueError(f"SIZE MISMATCH: expected {expected_size}, got {actual_size}")
    h = hashlib.sha256()
    with open(tmp_file, "rb") as f:
        f.seek(HEADER_TOTAL_BYTES)
        while True:
            block = f.read(1 << 20)  # 1 MB chunks
            if not block:
                break
            h.update(block)
    actual_hash = h.hexdigest()
    if actual_hash != expected_hash:
        raise ValueError(f"CHECKSUM MISMATCH: expected {expected_hash}, got {actual_hash}")
    return actual_size

def strip_header_to_payload(tmp_file: str, payload_size: int):
    """Rewrite tmp_file in-place to contain only the payload bytes (no header).
    Uses os.replace for atomicity so a partial write never lands in out_file."""
    payload_tmp = tmp_file + ".payload"
    with open(tmp_file, "rb") as fin, open(payload_tmp, "wb") as fout:
        fin.seek(HEADER_TOTAL_BYTES)
        remaining = payload_size
        while remaining > 0:
            block = fin.read(min(1 << 20, remaining))
            if not block:
                break
            fout.write(block)
            remaining -= len(block)
    os.replace(payload_tmp, tmp_file)

try:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(('0.0.0.0', port))
        s.listen(5)
        # Accept loop: readiness probes (nc -z) open empty connections that
        # must be ignored. Only a non-empty transfer counts as the bundle;
        # anything else keeps us listening instead of exiting on a 0-byte file.
        while True:
            conn, addr = s.accept()
            print(f"[pyreceiver] Connection from {addr}", flush=True)
            total = 0
            try:
                with open(out_file + ".tmp", "wb") as f:
                    while True:
                        chunk = conn.recv(65536)
                        if not chunk:
                            break
                        f.write(chunk)
                        total += len(chunk)
            except Exception as e:
                print(f"[pyreceiver] Read error from {addr}: {e}, ignoring", flush=True)
                total = 0

            # ── Empty connection (port probe) -> ignore ──────────────────────
            if total == 0:
                print(f"[pyreceiver] Empty connection from {addr} (port probe?), still listening", flush=True)
                try:
                    conn.close()
                except Exception:
                    pass
                try:
                    os.remove(out_file + ".tmp")
                except Exception:
                    pass
                continue

            # ── Non-empty: inspect first bytes for framed-protocol header ────
            framed_validated = False
            payload_bytes = 0
            head = b""
            try:
                with open(out_file + ".tmp", "rb") as f:
                    head = f.read(HEADER_TOTAL_BYTES)
            except Exception as e:
                print(f"[pyreceiver] Could not read header from tmp file: {e}, aborting stream", flush=True)
                total = 0

            if len(head) == HEADER_TOTAL_BYTES and head[:len(HEADER_MAGIC)] == HEADER_MAGIC and head[-1:] == b"\n":
                # Stream uses the new ESKSUM framed protocol — validate hash + size
                header_text = head[:128].decode("ascii", errors="replace")
                try:
                    expected_hash, expected_size = extract_header_fields(header_text)
                except ValueError as e:
                    print(f"[pyreceiver] Malformed ESKSUM header from {addr}: {e} — aborting (silently dropping)", flush=True)
                    total = 0
                else:
                    try:
                        payload_bytes = validate_framed_stream(out_file + ".tmp", expected_hash, expected_size)
                    except ValueError as e:
                        print(f"[pyreceiver] {e} from {addr} — CORRUPT STREAM, refusing to accept (still listening)", flush=True)
                        total = 0
                    else:
                        framed_validated = True
                        # Success: strip the 129-byte header, leaving only the payload
                        try:
                            strip_header_to_payload(out_file + ".tmp", payload_bytes)
                            total = payload_bytes
                        except Exception as e:
                            print(f"[pyreceiver] Failed stripping header: {e} — aborting", flush=True)
                            total = 0
            else:
                # Back-compat: legacy unframed stream from an old sender. Accept
                # as-is, just warn the user that no integrity check was done.
                print(f"[pyreceiver] WARNING: legacy UNFRAMED stream from {addr} — no checksum verification possible (accepted for back-compat)", flush=True)

            if total == 0:
                # Either an empty stream, or a framed stream whose validation
                # failed above. Clean up the tmp file and keep listening.
                try:
                    os.remove(out_file + ".tmp")
                except Exception:
                    pass
                try:
                    conn.close()
                except Exception:
                    pass
                continue

            os.replace(out_file + ".tmp", out_file)
            mode_note = " (checksum + size verified)" if framed_validated else " (legacy unframed, no checksum)"
            print(f"[pyreceiver] SUCCESS: Received {total} bytes into {out_file}{mode_note}", flush=True)
            try:
                conn.sendall(b"OK\n")
            except Exception:
                pass
            try:
                conn.close()
            except Exception:
                pass
            break
except Exception as e:
    print(f"[pyreceiver] ERROR: {e}", flush=True)
    sys.exit(1)
