#!/usr/bin/env python3
"""Canned OpenAI /chat/completions server for `pixi run local-probe` (test only).

Returns a fixed assistant message so LocalClient's flare HTTP path can be verified
without a real inference-server. Listens on 127.0.0.1:8799.
"""
import json
from http.server import BaseHTTPRequestHandler, HTTPServer


class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("content-length", 0))
        _ = self.rfile.read(n)  # consume request body
        payload = json.dumps({
            "choices": [{"message": {"role": "assistant",
                                     "content": "hi from the local model"}}]
        }).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", 8799), H).serve_forever()
