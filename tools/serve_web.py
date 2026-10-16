#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""《茅山秘录·诡异录》Web Demo 本地一键测试服务器（Phase 1）。

用途：把 `dist/web/` 里的 Godot Web 导出物用 HTTP 服务起来，浏览器直接实测。
只用标准库，不需要 pip 装任何东西。

    python tools/serve_web.py                 # http://localhost:8000/ 并自动开浏览器
    python tools/serve_web.py --port 8123 --no-open
    python tools/serve_web.py --dir dist/web

为什么不能直接双击 index.html：浏览器对 `file://` 下的 .wasm/.pck 有 CORS 限制，
且 Godot Web 需要正确的 MIME（.wasm 必须是 application/wasm），所以必须走 HTTP。

额外做的三件事：
  1) 允许跨域调试（`Access-Control-Allow-Origin: *` + OPTIONS 预检）；
  2) 发 COOP/COEP 头（若以后换成带线程的导出，SharedArrayBuffer 也能直接用）；
  3) 一律 `Cache-Control: no-store`，避免浏览器拿旧包（改完重新导出刷新即最新）。
"""

import argparse
import http.server
import os
import socket
import socketserver
import sys
import threading
import webbrowser

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_DIR = os.path.join(REPO_ROOT, "dist", "web")
DEFAULT_PORT = 8000

# 只补 http.server 里可能缺的几个；.wasm 不对会被浏览器拒绝编译
EXTRA_MIME = {
    ".wasm": "application/wasm",
    ".pck": "application/octet-stream",
    ".js": "text/javascript",
    ".mjs": "text/javascript",
    ".json": "application/json",
    ".svg": "image/svg+xml",
    ".png": "image/png",
    ".ico": "image/x-icon",
    ".css": "text/css",
    ".html": "text/html; charset=utf-8",
}


class Handler(http.server.SimpleHTTPRequestHandler):
    """带 CORS / COOP-COEP / no-store 的静态文件服务。"""

    extensions_map = {**http.server.SimpleHTTPRequestHandler.extensions_map, **EXTRA_MIME}

    def end_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cross-Origin-Resource-Policy", "cross-origin")
        self.send_header("Cache-Control", "no-store, must-revalidate")
        super().end_headers()

    def do_OPTIONS(self):  # noqa: N802 (http.server 的命名约定)
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, fmt, *args):
        sys.stdout.write("  %s  %s\n" % (self.log_date_time_string(), fmt % args))
        sys.stdout.flush()


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def pick_port(host, port, tries=10):
    """端口被占时自动往后找一个（8000 → 8001 → …）。"""
    for i in range(tries):
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                s.bind((host, port + i))
            return port + i
        except OSError:
            continue
    raise SystemExit("RESULT: FAIL 端口 %d-%d 都被占用了" % (port, port + tries - 1))


def main():
    ap = argparse.ArgumentParser(description="Web Demo 本地服务器")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--dir", default=DEFAULT_DIR, help="要服务的目录（默认 dist/web）")
    ap.add_argument("--no-open", action="store_true", help="不自动打开浏览器")
    args = ap.parse_args()

    root = os.path.abspath(args.dir)
    index = os.path.join(root, "index.html")
    if not os.path.isfile(index):
        raise SystemExit(
            "RESULT: FAIL 找不到 %s\n先跑： powershell -NoProfile -ExecutionPolicy Bypass "
            "-File tools\\export_web.ps1" % index
        )

    total = 0
    count = 0
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in filenames:
            count += 1
            total += os.path.getsize(os.path.join(dirpath, name))

    port = pick_port(args.host, args.port)
    handler = lambda *a, **kw: Handler(*a, directory=root, **kw)  # noqa: E731
    httpd = Server((args.host, port), handler)
    url = "http://localhost:%d/index.html" % port

    print("RESULT: OK Web Demo 已启动")
    print("  目录   %s（%d 个文件 / %.1f MB）" % (root, count, total / 1048576.0))
    print("  地址   %s" % url)
    print("  跨域   已开启（Access-Control-Allow-Origin: *）；缓存已关闭")
    print("  停止   Ctrl+C")
    sys.stdout.flush()

    if not args.no_open:
        threading.Timer(0.8, lambda: webbrowser.open(url)).start()

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n已停止。")
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
