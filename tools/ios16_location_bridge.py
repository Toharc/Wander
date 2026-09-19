#!/usr/bin/env python3
"""
Wander iOS 16 Location Bridge (Windows)

Why this exists:
- The on-device StikDebug/idevice transport used by Wander targets iOS 17.4+.
- iOS 16 still exposes the classic com.apple.dt.simulatelocation developer service.
- pymobiledevice3 supports that service over USB/lockdown.

Setup:
  py -m pip install -U pymobiledevice3
  py tools\\ios16_location_bridge.py

Keep the iPad connected by USB, unlocked/trusted, and Developer Mode enabled.
The script prints the URL and token to enter in Wander -> Radar Settings.
"""

import argparse
import asyncio
import json
import secrets
import socket
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

try:
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.simulate_location import DtSimulateLocation
except Exception as exc:
    print("ERROR: pymobiledevice3 is not installed.")
    print("Run: py -m pip install -U pymobiledevice3")
    raise SystemExit(2) from exc


def local_ipv4():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


class LocationDriver:
    def __init__(self):
        self.loop = asyncio.new_event_loop()
        self.thread = threading.Thread(target=self._run_loop, daemon=True)
        self.thread.start()
        self.lockdown = None
        self._connect()

    def _run_loop(self):
        asyncio.set_event_loop(self.loop)
        self.loop.run_forever()

    def _submit(self, coro, timeout=10):
        return asyncio.run_coroutine_threadsafe(coro, self.loop).result(timeout=timeout)

    def _connect(self):
        self._submit(self._connect_async())

    async def _connect_async(self):
        if self.lockdown is not None:
            return
        self.lockdown = await create_using_usbmux()

    async def _set_async(self, lat, lon):
        if self.lockdown is None:
            await self._connect_async()
        await DtSimulateLocation(self.lockdown).set(lat, lon)

    async def _clear_async(self):
        if self.lockdown is None:
            await self._connect_async()
        await DtSimulateLocation(self.lockdown).clear()

    def set_location(self, lat, lon):
        try:
            self._submit(self._set_async(lat, lon))
        except Exception:
            self.lockdown = None
            self._connect()
            self._submit(self._set_async(lat, lon))

    def clear_location(self):
        try:
            self._submit(self._clear_async())
        except Exception:
            self.lockdown = None
            self._connect()
            self._submit(self._clear_async())


def try_auto_mount():
    cmd = [sys.executable, "-m", "pymobiledevice3", "mounter", "auto-mount"]
    print("Checking Developer Disk Image...")
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip()
        print("WARNING: auto-mount did not complete successfully.")
        if detail:
            print(detail)
        print("You can retry manually with:")
        print("  py -m pymobiledevice3 mounter auto-mount")
    else:
        print("Developer Disk Image: ready")


class BridgeHandler(BaseHTTPRequestHandler):
    driver = None
    token = ""

    def log_message(self, fmt, *args):
        print("%s - %s" % (self.address_string(), fmt % args))

    def _json(self, status, payload):
        raw = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _authorized(self):
        return self.headers.get("X-Wander-Token", "") == self.token

    def _read_json(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(length) if length else b"{}"
        return json.loads(raw.decode("utf-8"))

    def do_GET(self):
        if not self._authorized():
            self._json(401, {"ok": False, "error": "Invalid bridge token."})
            return
        if self.path.rstrip("/") == "/health":
            self._json(200, {"ok": True, "error": None})
            return
        self._json(404, {"ok": False, "error": "Not found."})

    def do_POST(self):
        if not self._authorized():
            self._json(401, {"ok": False, "error": "Invalid bridge token."})
            return
        try:
            if self.path.rstrip("/") == "/location":
                body = self._read_json()
                lat = float(body["lat"])
                lon = float(body["lon"])
                if not (-90 <= lat <= 90 and -180 <= lon <= 180):
                    raise ValueError("Coordinates out of range.")
                self.driver.set_location(lat, lon)
                self._json(200, {"ok": True, "error": None})
                return

            if self.path.rstrip("/") == "/stop":
                self.driver.clear_location()
                self._json(200, {"ok": True, "error": None})
                return

            self._json(404, {"ok": False, "error": "Not found."})
        except Exception as exc:
            self._json(500, {"ok": False, "error": str(exc)})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--token", default="")
    parser.add_argument("--skip-mount", action="store_true")
    args = parser.parse_args()

    token = args.token.strip() or secrets.token_urlsafe(18)

    if not args.skip_mount:
        try_auto_mount()

    print("Connecting to iPad over Apple Mobile Device / usbmux...")
    driver = LocationDriver()
    print("iPad connection: ready")

    BridgeHandler.driver = driver
    BridgeHandler.token = token

    ip = local_ipv4()
    server = ThreadingHTTPServer(("0.0.0.0", args.port), BridgeHandler)

    print("")
    print("Wander iOS 16 Bridge is running")
    print("Bridge URL: http://%s:%d" % (ip, args.port))
    print("Bridge token: %s" % token)
    print("")
    print("Keep this window open and keep the iPad connected by USB.")
    print("Press Ctrl+C to stop.")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        try:
            driver.clear_location()
        except Exception:
            pass
        server.server_close()


if __name__ == "__main__":
    main()
