"""
Simple HTTP server with CORS headers required for SharedArrayBuffer.

Emscripten's pthreads support requires SharedArrayBuffer, which in turn
requires Cross-Origin-Opener-Policy and Cross-Origin-Embedder-Policy
headers on every response.

Usage: python3 run_server.py [port]
  Default port: 8000
"""

from http import server
import sys

port = 8000
if len(sys.argv) >= 2:
    port = int(sys.argv[1])


class CORSRequestHandler(server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        server.SimpleHTTPRequestHandler.end_headers(self)


if __name__ == '__main__':
    print(f"Serving on http://localhost:{port}")
    print("COOP/COEP headers enabled for SharedArrayBuffer support")
    server.test(HandlerClass=CORSRequestHandler, port=port)
