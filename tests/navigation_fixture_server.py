"""Loopback HTTP fixture for the navigation regression.

Records every request (method, path, body, Cookie header) to a JSON log so the
runner can assert server-side evidence: a POST download must arrive exactly once
with its body and cookie, and must never be followed by a synthetic GET.

The port is chosen by the OS and printed on stdout as ``PORT <n>`` so the runner
can pass it to the app through Info.plist.
"""
import argparse
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

DOWNLOAD_BODY = b"FOCUSDM-NAVIGATION-FIXTURE-PAYLOAD-0123456789"
PAGE = b"""<!doctype html><html><head><meta charset="utf-8"><title>before</title></head>
<body>
<form id="f" method="POST" action="/post-download">
  <input type="hidden" name="token" value="single-use-ticket">
  <input type="hidden" name="payload" value="form-body-marker">
</form>
<button id="go" onclick="document.getElementById('f').submit()">go</button>
<script>document.title = 'page-script-ran';</script>
</body></html>"""


class State:
    def __init__(self):
        self.lock = threading.Lock()
        self.entries = []

    def add(self, entry):
        with self.lock:
            self.entries.append(entry)

    def dump(self):
        with self.lock:
            return list(self.entries)


STATE = State()
LOG_PATH = {"path": None}


def flush_log():
    path = LOG_PATH["path"]
    if not path:
        return
    try:
        Path(path).write_text(json.dumps(STATE.dump()), encoding="utf-8")
    except OSError:
        pass


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # keep CI output clean
        pass

    def _record(self, body):
        STATE.add({
            "method": self.command,
            "path": self.path.split("?")[0],
            "body": body.decode("utf-8", "replace"),
            "cookie": self.headers.get("Cookie", ""),
            "content_type": self.headers.get("Content-Type", ""),
        })
        # Written after every request so the runner can read evidence without stopping the server.
        flush_log()

    def _send(self, status, body, headers=None):
        self.send_response(status)
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]
        self._record(b"")
        if path == "/plain.html":
            self._send(200, PAGE, {"Content-Type": "text/html; charset=utf-8"})
        elif path == "/__log":
            self._send(200, json.dumps(STATE.dump()).encode("utf-8"),
                       {"Content-Type": "application/json"})
        elif path == "/post-download":
            # A GET here means something re-requested the download: that is the failure this
            # fixture exists to detect, so answer with the file to keep the signal unambiguous.
            self._send(200, DOWNLOAD_BODY, {
                "Content-Type": "application/octet-stream",
                "Content-Disposition": 'attachment; filename="report.bin"',
            })
        else:
            self._send(404, b"missing", {"Content-Type": "text/plain"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        path = self.path.split("?")[0]
        self._record(body)
        if path == "/post-download":
            self._send(200, DOWNLOAD_BODY, {
                "Content-Type": "application/octet-stream",
                "Content-Disposition": 'attachment; filename="report.bin"',
            })
        elif path == "/post-page":
            self._send(200, PAGE, {"Content-Type": "text/html; charset=utf-8"})
        else:
            self._send(404, b"missing", {"Content-Type": "text/plain"})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", required=True, help="JSON file the runner reads after the app exits")
    parser.add_argument("--ready", required=True, help="file written once the port is bound")
    options = parser.parse_args()
    LOG_PATH["path"] = options.log
    flush_log()
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    port = server.server_address[1]
    print(f"PORT {port}", flush=True)
    Path(options.ready).write_text(str(port), encoding="utf-8")
    try:
        server.serve_forever(poll_interval=0.05)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        flush_log()
    return 0


if __name__ == "__main__":
    sys.exit(main())
