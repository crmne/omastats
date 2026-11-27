#!/usr/bin/env python3
"""Public-IP lookup regression tests against a local HTTP server."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import threading
import unittest


ROOT = Path(__file__).resolve().parent.parent
NAMESPACE = {"__name__": "sampler_test", "__file__": str(ROOT / "sampler.py")}
exec(compile((ROOT / "sampler.py").read_bytes(), "sampler.py", "exec"), NAMESPACE)
lookup_public_ip = NAMESPACE["lookup_public_ip"]

BIG = 8 * 1024 * 1024


class Handler(BaseHTTPRequestHandler):
    hits: list[str] = []
    sent: dict[str, int] = {}

    def log_message(self, *args):
        pass

    def send_body(self, code, body_size, extra=None, chunk=b"x" * 65536):
        self.send_response(code)
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.send_header("Content-Length", str(body_size))
        self.end_headers()
        sent = 0
        try:
            while sent < body_size:
                piece = chunk[: body_size - sent]
                self.wfile.write(piece)
                sent += len(piece)
        except (BrokenPipeError, ConnectionResetError):
            pass
        Handler.sent[self.path] = sent

    def do_GET(self):
        Handler.hits.append(self.path)
        port = self.server.server_address[1]
        if self.path == "/redirect":
            self.send_body(302, BIG, {"Location": f"http://127.0.0.1:{port}/elsewhere"})
        elif self.path == "/elsewhere":
            self.send_body(200, 11, chunk=b"192.0.2.66\n")
        elif self.path == "/huge":
            self.send_body(200, BIG, chunk=b"1" * 65536)
        else:
            self.send_body(200, 12, chunk=b"203.0.113.7\n")


class PublicIpTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = f"http://127.0.0.1:{cls.server.server_address[1]}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def setUp(self):
        Handler.hits.clear()
        Handler.sent.clear()

    def test_a_valid_answer_is_returned(self):
        self.assertEqual(lookup_public_ip([f"{self.base}/ok"]), "203.0.113.7")

    def test_redirects_are_not_followed_and_their_body_is_not_read(self):
        result = lookup_public_ip([f"{self.base}/redirect", f"{self.base}/ok"])
        self.assertEqual(result, "203.0.113.7")
        self.assertNotIn("/elsewhere", Handler.hits)
        self.assertEqual(lookup_public_ip([f"{self.base}/redirect"]), "")
        self.assertNotIn("/elsewhere", Handler.hits)

    def test_a_large_answer_is_capped_and_rejected(self):
        self.assertEqual(lookup_public_ip([f"{self.base}/huge"]), "")


if __name__ == "__main__":
    unittest.main()
