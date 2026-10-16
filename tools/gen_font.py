#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成中文字体子集 —— 让 Web/导出包里的中文不再是豆腐块（tofu）。

为什么需要：Godot 在浏览器里拿不到系统字体，内置默认字体只有拉丁字形，
所以 Web 导出后所有中文都渲染成 ▯。解决办法是随包带一份中文字体；
但 Noto Sans SC 全量有 10+ MB，而我们这局游戏用到的汉字不到 2500 个，
所以按"项目实际用到的字符"做子集，产物通常 0.5–1 MB。

数据来源：Google Fonts 的 css2 接口（`text=` 参数直接返回精确子集）。
本机 github.com 不通，但 fonts.googleapis.com / fonts.gstatic.com 可达，
pypi 可达时用 fonttools 合并多个分片（URL 长度上限会 400，所以要分片）。

用法：
    python tools/gen_font.py                 # 收集字符 → 下载 → 合并 → 生成 assets/fonts/NotoSansSC-subset.ttf
    python tools/gen_font.py --check         # 只检查现有字体是否覆盖当前项目的全部字符

改过任何界面/数据文案后重新跑一次，产物变了要重新导出 Web 包。
字体授权：Noto Sans SC = SIL Open Font License 1.1（见 assets/fonts/NOTICE.md）。
"""

# -*- coding: utf-8 -*-

import sys as _sys
for _s in (_sys.stdout, _sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

import argparse
import hashlib
import os
import re
import struct
import sys
import urllib.parse
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_FONT = os.path.join(REPO, "assets", "fonts", "NotoSansSC-subset.ttf")
CACHE = os.path.join(REPO, ".tools", "webfont", "cache")
SKIP_DIRS = {".godot", ".git", ".backups", "dist", "logs", ".shots", "node_modules", ".tools", "tests", "docs"}
CHUNK = 380  # 每片字符数：URL 太长 Google 会回 400
OLD_UA = "Mozilla/4.0 (compatible; MSIE 6.0; Windows NT 5.1)"  # 老 UA → Google 回 TTF（而不是 woff2）
# 汉字字体里缺的符号（▸ ★ ✔ 等）从这些字体补；按顺序试，补上就停
FALLBACK_FAMILIES = ["Noto Sans Symbols 2", "Noto Sans Symbols", "Noto Sans Math", "Noto Emoji"]
# 排版上一定会用到、但可能没出现在文案里的符号
EXTRA = "、。！？：；（）《》「」『』·—…“”‘’【】％～＋－＝×÷0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz .,:;!?'\"()-/"


def collect_chars() -> "tuple[set[str], set[str]]":
    """返回 (必须有字形, 锦上添花)。

    `tools/**` 里的字（✅❌🤖 之类）只出现在命令行/文档输出里，不进游戏画面，
    所以只当"有更好"：不为它们把字体撑大，也不因为它们让工具失败。
    """
    chars = set(EXTRA)
    optional = set()
    for base, dirs, files in os.walk(REPO):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        under_tools = os.path.relpath(base, REPO).replace("\\", "/").split("/")[0] == "tools"
        for name in files:
            ext = os.path.splitext(name)[1].lower()
            if ext not in (".gd", ".json", ".godot"):
                continue
            path = os.path.join(base, name)
            try:
                text = open(path, encoding="utf-8").read()
            except Exception:  # noqa: BLE001
                continue
            if ext == ".gd":
                # 注释里的汉字不必进字体（注释占源码一半以上，会把子集撑大一倍）
                text = "\n".join(ln for ln in text.splitlines() if not ln.lstrip().startswith("#"))
            bucket = optional if under_tools else chars
            for ch in text:
                if ord(ch) > 127 and ch not in "\u200b\ufeff":
                    bucket.add(ch)
    return chars, optional


def fetch(url: str) -> bytes:
    os.makedirs(CACHE, exist_ok=True)
    key = hashlib.sha1(url.encode("utf-8")).hexdigest()[:16]
    path = os.path.join(CACHE, key)
    if os.path.exists(path):
        return open(path, "rb").read()
    req = urllib.request.Request(url, headers={"User-Agent": OLD_UA})
    data = urllib.request.urlopen(req, timeout=120).read()
    open(path, "wb").write(data)
    return data


def strip_gstatic_header(data: bytes) -> bytes:
    """fonts.gstatic.com 的 /l/font 接口返回的是「私有头 + 真字体」。

    实测头 304 字节，第 4..8 字节是载荷长度（小端），载荷就是标准 TTF
    （开头 00 01 00 00）。按长度切尾巴即可，不用猜偏移。
    """
    if len(data) < 8 or data[:4] in (b"wOF2", b"wOFF", b"\x00\x01\x00\x00", b"OTTO", b"true"):
        return data
    (payload_len,) = struct.unpack_from("<I", data, 4)
    if 0 < payload_len <= len(data):
        off = len(data) - payload_len
        if data[off:off + 4] in (b"\x00\x01\x00\x00", b"OTTO", b"true"):
            return data[off:]
    return data


def font_urls_for(chunk: str, family: str = "Noto Sans SC") -> "list[str]":
    url = ("https://fonts.googleapis.com/css2?family=%s:wght@400&display=swap&text="
           % urllib.parse.quote(family.replace(" ", "+"), safe="+")
           + urllib.parse.quote(chunk, safe=""))
    css = fetch(url).decode("utf-8", "replace")
    urls = re.findall(r"url\((https://[^)\"']+)\)", css)
    if not urls:
        raise SystemExit("RESULT: FAIL Google Fonts 没回字体地址（%s / 字符片：%s…）" % (family, chunk[:12]))
    return urls


def grab(family: str, text: str, tag: str) -> "list[str]":
    """按片取某个 family 的子集字体文件，返回落盘路径列表。"""
    out = []
    pieces = [text[i:i + CHUNK] for i in range(0, len(text), CHUNK)]
    for i, piece in enumerate(pieces):
        for url in font_urls_for(piece, family):
            data = strip_gstatic_header(fetch(url))
            ext = ".woff2" if url.endswith(".woff2") else ".ttf"
            path = os.path.join(CACHE, "%s-%02d-%s%s" % (tag, i, hashlib.sha1(url.encode()).hexdigest()[:8], ext))
            open(path, "wb").write(data)
            out.append(path)
    return out


def missing_chars(font_path: str, text: str) -> "list[str]":
    from fontTools.ttLib import TTFont
    font = TTFont(font_path)
    cmap = set()
    for table in font["cmap"].tables:
        cmap.update(table.cmap.keys())
    return sorted(c for c in set(text) if ord(c) not in cmap)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="只校验现有字体的覆盖情况")
    args = ap.parse_args()

    required, optional = collect_chars()
    chars = required | optional
    text = "".join(sorted(chars))
    print("项目用到的非 ASCII 字符：%d 个（必须有字形 %d 个）"
          % (len([c for c in chars if ord(c) > 127]), len([c for c in required if ord(c) > 127])))

    if args.check:
        return check_coverage(required, optional)

    try:
        from fontTools.merge import Merger
        from fontTools import subset
        from fontTools.ttLib import TTFont
    except ImportError:
        print("RESULT: FAIL 需要 fonttools：python -m pip install fonttools brotli")
        return 1

    files = grab("Noto Sans SC", text, "sc")
    print("  Noto Sans SC：%d 个分片" % len(files))

    if len(files) == 1:
        merged_path = files[0]
    else:
        merged = Merger().merge(files)
        merged_path = os.path.join(CACHE, "merged.ttf")
        merged.save(merged_path)
    print("  合并成一个字体：%s" % merged_path)

    # 汉字字体里没有的符号（▸ ★ ✔ 之类）→ 从符号字体补，再合并回去
    missing = [c for c in missing_chars(merged_path, text) if c in required]
    if missing:
        print("  Noto Sans SC 缺 %d 个字符：%s" % (len(missing), "".join(missing)))
    for family in FALLBACK_FAMILIES:
        if not missing:
            break
        try:
            extra = grab(family, "".join(missing), "fb")
        except Exception as exc:  # 某个 family 没这些字形时 Google 会回 400：换下一个
            print("  %s 取不到（%s）→ 试下一个" % (family, exc))
            continue
        if not extra:
            continue
        try:
            merged = Merger().merge([merged_path] + extra)
        except Exception as exc:  # 有些字体（emoji）表结构不同，合不进来：换下一个
            print("  %s 合不进来（%s）→ 试下一个" % (family, exc))
            continue
        merged_path = os.path.join(CACHE, "merged-%s.ttf" % re.sub(r"\W+", "", family))
        merged.save(merged_path)
        before = len(missing)
        missing = [c for c in missing_chars(merged_path, text) if c in required]
        print("  %s 补进 %d 个字符（还缺 %d 个）" % (family, before - len(missing), len(missing)))
    if missing:
        print("  注：这些字符没有字形（只在命令行/文档输出里用到，游戏画面不受影响）：%s" % "".join(missing))

    os.makedirs(os.path.dirname(OUT_FONT), exist_ok=True)
    opts = subset.Options()
    opts.name_IDs = ["*"]
    opts.name_legacy = True
    opts.layout_features = ["*"]
    opts.notdef_outline = True
    opts.recalc_bounds = True
    font = subset.load_font(merged_path, opts)
    sub = subset.Subsetter(options=opts)
    sub.populate(text=text)
    sub.subset(font)
    subset.save_font(font, OUT_FONT, opts)
    print("  子集化并写出：%s（%.1f KB）" % (OUT_FONT, os.path.getsize(OUT_FONT) / 1024.0))

    return check_coverage(required, optional)


def check_coverage(required: "set[str]", optional: "set[str]" = frozenset()) -> int:
    try:
        from fontTools.ttLib import TTFont
    except ImportError:
        print("RESULT: FAIL 需要 fonttools")
        return 1
    if not os.path.isfile(OUT_FONT):
        print("RESULT: FAIL 还没有 %s，先跑 python tools/gen_font.py" % OUT_FONT)
        return 1
    font = TTFont(OUT_FONT)
    cmap = set()
    for table in font["cmap"].tables:
        cmap.update(table.cmap.keys())
    missing = sorted(c for c in required if ord(c) not in cmap)
    extra_missing = sorted(c for c in optional if ord(c) not in cmap)
    size = os.path.getsize(OUT_FONT) / 1024.0
    print("字体覆盖：%d 字码；必须有字形的 %d 个字符里缺 %d 个"
          % (len(cmap), len(required), len(missing)))
    if extra_missing:
        print("  （可选字符没字形，只影响命令行输出：%s）" % "".join(extra_missing[:20]))
    if missing:
        print("  缺字（前 40）：%s" % "".join(missing[:40]))
        print("RESULT: FAIL 字体缺字")
        return 1
    print("RESULT: OK 字体子集完整（%.1f KB，%d 字码）" % (size, len(cmap)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
