#!/usr/bin/env python3
import socket
import sys
import os

port = int(sys.argv[1]) if len(sys.argv) > 1 else 7777
out_file = sys.argv[2] if len(sys.argv) > 2 else "/opt/eks-killer/incoming-bundle.tar"

print(f"[pyreceiver] Listening on port {port} -> {out_file}", flush=True)

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
            os.replace(out_file + ".tmp", out_file)
            print(f"[pyreceiver] SUCCESS: Received {total} bytes into {out_file}", flush=True)
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
