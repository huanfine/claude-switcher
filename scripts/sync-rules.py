#!/usr/bin/env python3
"""把 data/claude-rules.json 渲染进各平台的标记块。

功能 / 数据 / 环境三层里的「数据层」。域名与端口清单只允许有一个来源:
本脚本读取的 JSON。各平台代码里的清单块由本脚本生成,不要手改。

    python3 scripts/sync-rules.py            # 生成
    python3 scripts/sync-rules.py --check    # 只校验是否与数据源一致(CI / 测试用)

标记块形如(允许带缩进,便于嵌在函数体里):

    # >>> claude-switcher:rules generated >>>
    ...
    # <<< claude-switcher:rules generated <<<

新增平台时,在 TARGETS 里登记文件、渲染器与缩进即可,数据不用再抄一遍。
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "data/claude-rules.json"
BEGIN = "# >>> claude-switcher:rules generated >>>"
END = "# <<< claude-switcher:rules generated <<<"
BANNER = "# 由 scripts/sync-rules.py 从 data/claude-rules.json 生成,请勿手改。"


def load():
    try:
        data = json.loads(SOURCE.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise SystemExit("FAIL:读不到 data/claude-rules.json(%s)" % type(error).__name__)
    if data.get("schema") != 1:
        raise SystemExit("FAIL:data/claude-rules.json 的 schema 不是 1")
    groups = data.get("domain_groups")
    if not isinstance(groups, list) or not groups:
        raise SystemExit("FAIL:data/claude-rules.json 缺少 domain_groups")
    seen, ordered = set(), []
    for group in groups:
        if not isinstance(group, dict) or not isinstance(group.get("domains"), list):
            raise SystemExit("FAIL:domain_groups 里有非法分组")
        domains = group["domains"]
        if not domains:
            raise SystemExit("FAIL:domain_groups 里有空分组")
        note = group.get("note", "")
        if not isinstance(note, str):
            raise SystemExit("FAIL:分组 note 必须是字符串")
        for domain in domains:
            if not isinstance(domain, str) or not domain or any(c in domain for c in " \t\r\n,"):
                raise SystemExit("FAIL:非法域名 %r" % (domain,))
            if domain in seen:
                raise SystemExit("FAIL:域名重复 %s" % domain)
            seen.add(domain)
            ordered.append((note, domain))
    ports = (data.get("ports") or {}).get("values")
    if not isinstance(ports, list) or not ports or any(type(p) is not int for p in ports):
        raise SystemExit("FAIL:ports.values 必须是整数列表")
    note = data.get("note") or []
    if not isinstance(note, list) or any(not isinstance(n, str) for n in note):
        raise SystemExit("FAIL:note 必须是字符串列表")
    return note, ordered, ports


def head(note, indent):
    return [indent + BEGIN, indent + BANNER] + [indent + ("# " + line if line else "#") for line in note]


def render_python(note, ordered, ports, indent):
    out = head(note, indent)
    out.append(indent + "DOMAINS = (")
    last = None
    for group_note, domain in ordered:
        if group_note and group_note != last:
            out.append(indent + "    # " + group_note)
            last = group_note
        out.append(indent + '    "%s",' % domain)
    out.append(indent + ")")
    out.append(indent + "PORTS = (%s)" % ", ".join(str(p) for p in ports))
    out.append(indent + END)
    return out


def render_bash(note, ordered, ports, indent):
    domains = [domain for _, domain in ordered]
    out = head(note, indent)
    rows = [domains[i:i + 4] for i in range(0, len(domains), 4)]
    for index, row in enumerate(rows):
        prefix = indent + ("for d in " if index == 0 else " " * len("for d in "))
        suffix = "; do" if index == len(rows) - 1 else " \\"
        out.append(prefix + " ".join(row) + suffix)
    out.append(indent + END)
    return out


def render_powershell(note, ordered, ports, indent):
    domains = [domain for _, domain in ordered]
    out = head(note, indent)
    out.append(indent + "$CLAUDE_DOMAINS = @(")
    for start in range(0, len(domains), 4):
        row = domains[start:start + 4]
        out.append(indent + "    " + ", ".join("'%s'" % d for d in row) + ("," if start + 4 < len(domains) else ""))
    out.append(indent + ")")
    out.append(indent + "$CLAUDE_PORTS = @(%s)" % ", ".join("'%d'" % p for p in ports))
    out.append(indent + END)
    return out


# (相对路径, 渲染器, 缩进)
TARGETS = (
    ("core/claude-switch.sh", render_python, ""),
    ("linux/claude-switch.sh", render_bash, "    "),
    ("linux/install.sh", render_bash, "    "),
    ("windows/claude-switch.ps1", render_powershell, ""),
)


def read(path):
    raw = path.read_bytes()
    return raw.decode("utf-8-sig"), raw.startswith(b"\xef\xbb\xbf")


def replace_blocks(text, block, rel):
    pattern = re.compile(
        r"(?m)^[ \t]*" + re.escape(BEGIN) + r"[ \t]*\n.*?^[ \t]*" + re.escape(END) + r"[ \t]*(?=\n|$)",
        re.S)
    matches = pattern.findall(text)
    if not matches:
        raise SystemExit("FAIL:%s 里没有标记块,先手工插入 %s / %s" % (rel, BEGIN, END))
    if text.count(BEGIN) != len(matches) or text.count(END) != len(matches):
        raise SystemExit("FAIL:%s 的标记块不成对" % rel)
    return pattern.sub(lambda _: "\n".join(block), text), len(matches)


def main(argv):
    check = "--check" in argv
    note, ordered, ports = load()
    stale = []
    for rel, renderer, indent in TARGETS:
        path = ROOT / rel
        if not path.exists():
            raise SystemExit("FAIL:缺少目标文件 %s" % rel)
        original, bom = read(path)
        updated, count = replace_blocks(original, renderer(note, ordered, ports, indent), rel)
        if updated == original:
            print("ok    %s (%d 处)" % (rel, count))
            continue
        if check:
            stale.append(rel)
            print("diff  %s (%d 处)" % (rel, count))
            continue
        data = updated.encode("utf-8")
        path.write_bytes((b"\xef\xbb\xbf" + data) if bom else data)
        print("write %s (%d 处)" % (rel, count))
    if stale:
        print("FAIL:以下文件与数据源不一致,请运行 python3 scripts/sync-rules.py:%s"
              % ", ".join(stale))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
