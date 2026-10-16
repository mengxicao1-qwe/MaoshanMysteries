#!/usr/bin/env python3
"""选择性下载 Godot 导出模板里的 Web 模板（不走 GitHub，直接 range 请求官方 tpz）。

原因：本机 github.com 不通（0x80072efd / 超时），但官方下载主机
https://downloads.godotengine.org/ 可达（302 → objectstorage）。整包 tpz 约 1GB，
本机测速 ~90KB/s，整包下载要 3 小时；而我们只需要里面两个 web 模板 zip
（各 30-50MB）⇒ 用 HTTP Range 只取需要的条目：先取尾部读中央目录，再按偏移取条目数据。

用法：
  python tools/fetch_web_templates.py --list          # 只列条目名
  python tools/fetch_web_templates.py                 # 下载 web 模板到 export_templates/4.7.2.stable
"""
from __future__ import annotations

import os
import sys
import time
import urllib.request
import zlib

# 进度同时写进 logs/fetch_web_templates.log（后台任务时 stdio 会被 PowerShell 缓冲，
# 实测 Tee-Object 拿不到任何输出 ⇒ 自己写文件最可靠）。
_LOG_FH = None
try:
    _log_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "logs")
    os.makedirs(_log_dir, exist_ok=True)
    _LOG_FH = open(os.path.join(_log_dir, "fetch_web_templates.log"), "a", encoding="utf-8", buffering=1)
except Exception:  # noqa: BLE001
    _LOG_FH = None

_builtin_print = print


def print(*args, **kwargs):  # noqa: A001
    _builtin_print(*args, **kwargs)
    if _LOG_FH is not None:
        _LOG_FH.write(" ".join(str(a) for a in args) + "\n")
        _LOG_FH.flush()

URL = os.environ.get(
    "GODOT_TPL_URL",
    # 官方跳转层（downloads.godotengine.org?version=...）会 302 到这里；实测直连更快更稳：
    # 官方层 1KB range 能卡住好几分钟，直连 4MB/14s（≈290KB/s）。
    "https://godot-releases.nbg1.your-objectstorage.com/4.7.2-stable/"
    "Godot_v4.7.2-stable_export_templates.tpz",
)
VER_DIR = os.environ.get("GODOT_TPL_VERSION", "4.7.2.stable")
DST_DIR = os.path.join(os.environ["APPDATA"], "Godot", "export_templates", VER_DIR)
WANT = ("web_nothreads_release.zip", "web_nothreads_debug.zip", "web_release.zip")
UA = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) dsh-fetch"}


def _open(start: int, end: int):
    for attempt in range(4):
        try:
            req = urllib.request.Request(URL, headers={**UA, "Range": f"bytes={start}-{end}"})
            return urllib.request.urlopen(req, timeout=90)
        except Exception as exc:  # noqa: BLE001
            print(f"  ! range {start}-{end} 失败({attempt + 1}/4): {exc}", flush=True)
            time.sleep(2 + attempt * 3)
    raise SystemExit(f"RESULT: FAIL 无法读取字节区间 {start}-{end}")


def fetch(start: int, end: int, label: str = "") -> bytes:
    with _open(start, end) as resp:
        data = resp.read()
    if label:
        print(f"  取到 {label}: {len(data)} 字节", flush=True)
    return data


def total_size() -> int:
    with _open(0, 0) as resp:
        cr = resp.headers.get("Content-Range", "")
    if "/" not in cr:
        raise SystemExit(f"RESULT: FAIL 服务器没给 Content-Range: {cr!r}")
    return int(cr.rsplit("/", 1)[1])


def parse_central_directory(tail: bytes, tail_start: int):
    """返回 [(name, method, comp_size, local_off)]。"""
    eocd64 = tail.rfind(b"PK\x06\x06")
    if eocd64 >= 0:
        cd_size = int.from_bytes(tail[eocd64 + 40:eocd64 + 48], "little")
        cd_off = int.from_bytes(tail[eocd64 + 48:eocd64 + 56], "little")
        print(f"  zip64 EOCD: cd_off={cd_off} cd_size={cd_size}", flush=True)
    else:
        eocd = tail.rfind(b"PK\x05\x06")
        if eocd < 0:
            raise SystemExit("RESULT: FAIL 尾部找不到 EOCD 签名")
        cd_size = int.from_bytes(tail[eocd + 12:eocd + 16], "little")
        cd_off = int.from_bytes(tail[eocd + 16:eocd + 20], "little")
        print(f"  EOCD: cd_off={cd_off} cd_size={cd_size}", flush=True)

    if tail_start <= cd_off and cd_off + cd_size <= tail_start + len(tail):
        cd = tail[cd_off - tail_start:cd_off - tail_start + cd_size]
    else:
        cd = fetch(cd_off, cd_off + cd_size - 1, "中央目录")

    out, pos = [], 0
    while pos + 46 <= len(cd) and cd[pos:pos + 4] == b"PK\x01\x02":
        method = int.from_bytes(cd[pos + 10:pos + 12], "little")
        comp = int.from_bytes(cd[pos + 20:pos + 24], "little")
        name_len = int.from_bytes(cd[pos + 28:pos + 30], "little")
        extra_len = int.from_bytes(cd[pos + 30:pos + 32], "little")
        cmt_len = int.from_bytes(cd[pos + 32:pos + 34], "little")
        off = int.from_bytes(cd[pos + 42:pos + 46], "little")
        name = cd[pos + 46:pos + 46 + name_len].decode("utf-8", "replace")
        extra = cd[pos + 46 + name_len:pos + 46 + name_len + extra_len]
        if comp == 0xFFFFFFFF or off == 0xFFFFFFFF:
            i = 0
            while i + 4 <= len(extra):
                hid = int.from_bytes(extra[i:i + 2], "little")
                hsz = int.from_bytes(extra[i + 2:i + 4], "little")
                if hid == 0x0001:
                    blob, j = extra[i + 4:i + 4 + hsz], 0
                    if comp == 0xFFFFFFFF:
                        comp = int.from_bytes(blob[j:j + 8], "little"); j += 8
                    if off == 0xFFFFFFFF:
                        j += 8  # uncompressed size
                        off = int.from_bytes(blob[j:j + 8], "little")
                    break
                i += 4 + hsz
        out.append((name, method, comp, off))
        pos += 46 + name_len + extra_len + cmt_len
    return out


def extract(entry, dst_path: str) -> int:
    name, method, comp, off = entry
    head = fetch(off, off + 1023, f"{name} 本地头")
    if head[:4] != b"PK\x03\x04":
        raise SystemExit(f"RESULT: FAIL {name} 本地头签名不对: {head[:4]!r}")
    name_len = int.from_bytes(head[26:28], "little")
    extra_len = int.from_bytes(head[28:30], "little")
    data_off = off + 30 + name_len + extra_len
    print(f"  下载 {name}: {comp / 1048576:.1f} MB ({'deflate' if method == 8 else 'stored'})", flush=True)
    chunks, got, step = [], 0, 4 * 1024 * 1024
    while got < comp:
        end = min(got + step, comp) - 1
        chunks.append(fetch(data_off + got, data_off + end))
        got += end + 1 - got
        print(f"    {got / 1048576:.1f}/{comp / 1048576:.1f} MB", flush=True)
    blob = b"".join(chunks)
    data = blob if method == 0 else zlib.decompressobj(-15).decompress(blob)
    os.makedirs(os.path.dirname(dst_path), exist_ok=True)
    with open(dst_path, "wb") as fh:
        fh.write(data)
    print(f"  ✓ {dst_path} ({len(data)} 字节)", flush=True)
    return len(data)


def main() -> None:
    total = total_size()
    print(f"tpz 总大小 {total / 1048576:.1f} MB，读尾部索引…", flush=True)
    tail_len = 256 * 1024
    tail_start = max(0, total - tail_len)
    tail = fetch(tail_start, total - 1, "尾部")
    entries = parse_central_directory(tail, tail_start)
    print(f"中央目录 {len(entries)} 个条目", flush=True)

    if "--list" in sys.argv:
        for name, _, comp, _ in entries:
            print(f"  {comp / 1048576:8.1f} MB  {name}")
        print("RESULT: OK 仅列条目（未下载）")
        return

    want = {w for w in WANT}
    if "--with-debug" not in sys.argv:
        want.discard("web_nothreads_debug.zip")  # 只要 release，省一半带宽
    picked = [e for e in entries if e[0].split("/")[-1] in want]
    if not picked:
        print("可用 web 相关条目：")
        for name, _, comp, _ in entries:
            if "web" in name.lower():
                print(f"  {comp / 1048576:8.1f} MB  {name}")
        raise SystemExit("RESULT: FAIL 没找到想要的 web 模板条目")

    done = []
    for entry in picked:
        base = entry[0].split("/")[-1]
        if base.startswith("web_release") or base.startswith("web_debug"):
            continue  # 只要 nothreads 版；有 nothreads 就够
        size = extract(entry, os.path.join(DST_DIR, base))
        # Godot 有的版本期望 templates/ 子目录，两份都放，省得猜
        alt = os.path.join(DST_DIR, "templates", base)
        os.makedirs(os.path.dirname(alt), exist_ok=True)
        with open(alt, "wb") as fh:
            fh.write(open(os.path.join(DST_DIR, base), "rb").read())
        done.append((base, size))
    print("RESULT: OK 模板就位 " + ", ".join(f"{n}({s / 1048576:.1f}MB)" for n, s in done)
          + f" → {DST_DIR}", flush=True)


if __name__ == "__main__":
    main()
