#!/usr/bin/env python3
"""把目录打成 zip，并保证非 ASCII 文件名带 UTF-8 标记（PKWARE bit 11）。

macOS 的 `ditto -c -k` 写 zip 时，中文文件名是 UTF-8 字节却不置 UTF-8 flag，
系统的「归档实用工具」会按 MacRoman 解读，解压后变成
`ä¸é®åè£.command` 这种乱码，用户既点不了入口，安装器也找不到中文路径。
`zipfile` 对非 ASCII 名会自动置位，这里再显式置一次，并保留 Unix 权限位。

用法:
    python3 scripts/make-zip.py <源目录> <输出.zip> [顶层目录名]

不传顶层目录名时，源目录内容直接位于 zip 根（app-only 包用）。
"""
import os
import stat
import sys
import time
import zipfile
from pathlib import Path

SKIP_NAMES = {".DS_Store", "__MACOSX"}


def build(src: Path, out: Path, top: str) -> int:
    if not src.is_dir():
        print(f"FAIL: 源目录不存在: {src}", file=sys.stderr)
        return 1
    if top and ("/" in top or top in (".", "..")):
        print(f"FAIL: 顶层目录名不合法: {top}", file=sys.stderr)
        return 1

    entries = []
    for path in sorted(src.rglob("*")):
        if any(part in SKIP_NAMES for part in path.relative_to(src).parts):
            continue
        rel = path.relative_to(src).as_posix()
        entries.append((path, f"{top}/{rel}" if top else rel))

    out.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(out, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        if top:
            zi = zipfile.ZipInfo(top + "/")
            zi.create_system = 3
            zi.external_attr = (0o40755 << 16) | 0x10
            zi.date_time = time.localtime()[:6]
            zf.writestr(zi, b"")

        for path, arc in entries:
            st = path.lstat()
            is_dir = stat.S_ISDIR(st.st_mode)
            is_link = stat.S_ISLNK(st.st_mode)
            name = arc + "/" if is_dir and not arc.endswith("/") else arc

            zi = zipfile.ZipInfo(name)
            zi.create_system = 3  # Unix，保留可执行位
            zi.external_attr = (st.st_mode & 0xFFFF) << 16
            zi.compress_type = zipfile.ZIP_DEFLATED
            mtime = time.localtime(st.st_mtime)
            zi.date_time = tuple(max(v, 1980) if i == 0 else v
                                 for i, v in enumerate(mtime[:6]))
            if not name.isascii():
                zi.flag_bits |= 0x800  # UTF-8 文件名，macOS 归档实用工具要靠它

            if is_dir:
                zf.writestr(zi, b"")
            elif is_link:
                zf.writestr(zi, os.readlink(path).encode("utf-8"))
            else:
                with path.open("rb") as fh:
                    zf.writestr(zi, fh.read())

    with zipfile.ZipFile(out) as zf:
        bad = [i.filename for i in zf.infolist()
               if not i.filename.isascii() and not (i.flag_bits & 0x800)]
        if bad:
            print(f"FAIL: 这些条目缺 UTF-8 标记: {bad[:3]}", file=sys.stderr)
            return 1
    print(f"OK: {out.name} ({len(entries)} 项, UTF-8 文件名标记已写入)")
    return 0


def main() -> int:
    if len(sys.argv) not in (3, 4):
        print("用法: make-zip.py <源目录> <输出.zip> [顶层目录名]", file=sys.stderr)
        return 2
    return build(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve(),
                 sys.argv[3] if len(sys.argv) == 4 else "")


if __name__ == "__main__":
    sys.exit(main())
