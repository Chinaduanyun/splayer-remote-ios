#!/usr/bin/env python3
"""本地 Mock HTTP 服务器：模拟 SPlayer 外部 API 的请求 / 响应契约。

⚠️ 仅用于在电脑或模拟器上验证 App 的网络层，**不能**替代真机联调。
它实现了与上游一致的端点、鉴权与请求校验，便于在本机快速验证：

    python3 mockserver/mock_server.py --host 0.0.0.0 --port 6688 --token devtoken

然后在 App 设置中填入 `<本机 IP>`、端口 `6688`、Token `devtoken`。
"""
import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

FIXTURES = Path(__file__).resolve().parent / "fixtures"


def fixture(name):
    return json.loads((FIXTURES / name).read_text(encoding="utf-8"))


class Handler(BaseHTTPRequestHandler):
    server_version = "SPlayerMock/1.0"

    def _token(self):
        auth = self.headers.get("Authorization", "")
        if auth.lower().startswith("bearer "):
            return auth[7:].strip()
        return self.headers.get("X-SPlayer-Token", "").strip()

    def _send_json(self, status, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            return {}
        try:
            return json.loads(self.rfile.read(length).decode("utf-8"))
        except json.JSONDecodeError:
            return {}

    def _authorized(self):
        return self._token() == self.server.expected_token

    def do_GET(self):
        path = urlparse(self.path).path
        if not path.startswith("/api/external/"):
            return self._send_json(404, {"error": "endpoint not found"})
        if not self._authorized():
            return self._send_json(401, {"error": "UNAUTHORIZED"})

        table = {
            "/api/external/info": "info.json",
            "/api/external/status": "status.json",
            "/api/external/now-playing": "now-playing.json",
            "/api/external/volume": None,
        }
        if path == "/api/external/volume":
            return self._send_json(200, {"volume": fixture("status.json")["volume"]})
        name = table.get(path)
        if not name:
            return self._send_json(404, {"error": "endpoint not found"})
        return self._send_json(200, fixture(name))

    def do_POST(self):
        path = urlparse(self.path).path
        if not path.startswith("/api/external/"):
            return self._send_json(404, {"error": "endpoint not found"})
        if not self._authorized():
            return self._send_json(401, {"error": "UNAUTHORIZED"})

        if path in {
            "/api/external/play",
            "/api/external/pause",
            "/api/external/stop",
            "/api/external/next",
            "/api/external/prev",
        }:
            return self._send_json(200, {"ok": True})

        if path == "/api/external/seek":
            body = self._read_json()
            position = body.get("positionMs")
            if not isinstance(position, int) or position < 0:
                return self._send_json(400, {"error": "positionMs (number, >=0) required"})
            return self._send_json(200, {"ok": True})

        if path == "/api/external/volume":
            body = self._read_json()
            volume = body.get("volume", float("nan"))
            if not isinstance(volume, (int, float)) or not (0 <= volume <= 1):
                return self._send_json(400, {"error": "volume (number, 0..1) required"})
            return self._send_json(200, {"ok": True})

        return self._send_json(404, {"error": "endpoint not found"})

    def log_message(self, fmt, *args):  # 降低噪音，但保留在 stderr
        print("[mock]", fmt % args)


def main():
    parser = argparse.ArgumentParser(description="SPlayer 外部 API mock 服务器")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=6688)
    parser.add_argument("--token", default="devtoken")
    args = parser.parse_args()

    httpd = ThreadingHTTPServer((args.host, args.port), Handler)
    httpd.expected_token = args.token
    print(f"Mock SPlayer 外部 API 运行于 http://{args.host}:{args.port}/api/external/ (token={args.token})")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
