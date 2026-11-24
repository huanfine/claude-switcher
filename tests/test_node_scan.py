"""节点扫描(只读)的口径回归。

这一层最容易出事的不是排序,而是「读了什么」。订阅 / 合并配置里有 uuid、
password、证书;一个整份 YAML 反序列化 + 顺手 print 调试信息,就会把凭据
带进日志和诊断包。所以这里的断言分成两类:

1. 解析层:只认白名单键,凭据一个字都不许出现在输出里;CDN 前置节点必须
   标成「出口未知」而不是拿入口 IP 去打分。
2. 结论层:checkdetail 的「更优节点」只读报告文件,没报告 / 报告过期 /
   有更优节点分别落到 skip / skip / warn,绝不借 ok 冒充「已经比过了」。

夹具只 stub 外部命令与内核 HTTP 响应,不碰真实网络与真实订阅。
"""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "core/claude-switch.sh"


def load_rules_module(destination):
    """把脚本里内嵌的 PY_CLASH_RULES 抽出来当模块导入,好单测里面的纯函数。"""
    text = SOURCE.read_text(encoding="utf-8")
    marker = "<<'PY_CLASH_RULES'"
    start = text.index(marker) + len(marker)
    end = text.index("\nPY_CLASH_RULES\n", start)
    path = destination / "clash_rules_module.py"
    path.write_text(text[start:end], encoding="utf-8")
    spec = importlib.util.spec_from_file_location("clash_rules_under_test", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


FAKE_CONFIG = """\
proxies:
- name: A·美国-直连
  type: vless
  server: 192.0.2.11
  port: 443
  uuid: SUPER-SECRET-UUID-A
  password: SUPER-SECRET-PASSWORD-A
  udp: true
- name: B·CDN前置
  type: vless
  server: 104.19.51.123
  servername: inter-90v.pages.dev
  ws-opts:
    headers:
      Host: inter-90v.pages.dev
  uuid: SUPER-SECRET-UUID-B
- name: C·域名入口
  type: hysteria2
  server: node.example.com
  uuid: SUPER-SECRET-UUID-C
proxy-groups:
- name: 🤖 OpenAi
  type: select
  proxies:
  - 🧠 AI·干净IP
rules:
- DOMAIN-SUFFIX,claude.ai,🤖 OpenAi
"""


def fake_proxies():
    return {"proxies": {
        "🤖 OpenAi": {"type": "Selector", "all": ["🧠 AI·干净IP", "☑️ 手动切换"],
                      "now": "🧠 AI·干净IP"},
        "🧠 AI·干净IP": {"type": "Selector",
                      "all": ["A·美国-直连", "B·CDN前置", "C·域名入口", "🔀 自动最快"],
                      "now": "A·美国-直连"},
        "🔀 自动最快": {"type": "URLTest", "all": ["A·美国-直连", "B·CDN前置"]},
        "☑️ 手动切换": {"type": "Selector", "all": ["Z·别的组"]},
        "Z·别的组": {"type": "Vless"},
        "A·美国-直连": {"type": "Vless"},
        "B·CDN前置": {"type": "Vless"},
        "C·域名入口": {"type": "Hysteria2"},
    }}


class NodeScanParserTests(unittest.TestCase):
    def setUp(self):
        (ROOT / "_trash").mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(prefix="node-scan-", dir=ROOT / "_trash")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.clash = self.root / "clash"
        self.clash.mkdir()
        (self.clash / "clash-verge.yaml").write_text(FAKE_CONFIG, encoding="utf-8")
        self.mod = load_rules_module(self.root)

    def test_parser_reads_only_whitelisted_keys(self):
        entries = self.mod.parse_proxy_entries(self.clash / "clash-verge.yaml")
        self.assertEqual(set(entries), {"A·美国-直连", "B·CDN前置", "C·域名入口"})
        for entry in entries.values():
            self.assertLessEqual(set(entry), self.mod._NODE_KEYS | {"name"})
        blob = json.dumps(entries, ensure_ascii=False)
        for secret in ("SUPER-SECRET-UUID", "SUPER-SECRET-PASSWORD"):
            self.assertNotIn(secret, blob, "解析器把凭据读进来了")

    def test_egress_kind_separates_direct_from_fronted(self):
        entries = self.mod.parse_proxy_entries(self.clash / "clash-verge.yaml")
        self.assertEqual(self.mod._egress_kind(entries["A·美国-直连"]),
                         ("known", "192.0.2.11"))
        self.assertEqual(self.mod._egress_kind(entries["B·CDN前置"])[0], "fronted")
        self.assertEqual(self.mod._egress_kind(entries["C·域名入口"])[0], "domain")
        self.assertEqual(self.mod._egress_kind(None)[0], "missing")

    def test_scan_only_lists_controlling_selector_leaves(self):
        """建议只针对当前控路的 Selector,不能顺手把「手动切换」那组也列进来。"""
        self.mod.controller_config = lambda _cli: (("unix", "/fake.sock", None), "")
        self.mod.api_get = lambda _b, _s, _p: fake_proxies()
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.mod.node_scan(self.clash, "🤖 OpenAi")
        lines = out.getvalue().splitlines()
        nodes = [line.split("\t") for line in lines if line.startswith("NODE\t")]
        self.assertEqual([n[2] for n in nodes],
                         ["A·美国-直连", "B·CDN前置", "C·域名入口"])
        self.assertEqual([n[1] for n in nodes], ["🧠 AI·干净IP"] * 3)
        self.assertEqual([n[4] for n in nodes], ["known", "fronted", "domain"])
        self.assertIn("CURRENT\tA·美国-直连", lines)
        self.assertNotIn("Z·别的组", out.getvalue())
        self.assertNotIn("🔀 自动最快", out.getvalue())
        for secret in ("SUPER-SECRET-UUID", "SUPER-SECRET-PASSWORD"):
            self.assertNotIn(secret, out.getvalue(), "扫描输出里出现了凭据")

    def test_auto_routing_chain_reports_nochoice_instead_of_failing(self):
        """Selector → Fallback:报「无可手动目标」,不是抛错。

        实测配置(2026-11-21):🤖 OpenAi(Selector) 只有 1 个子项,指向
        🧠 AI·干净IP(Fallback),成员是两个固定 IP。旧实现直接 fail,界面把
        「这条链上不需要换节点」显示成「扫描失败：…(退出码 1)」,用户只能
        以为工具坏了,然后被界面反复催着去点一个必然失败的按钮。
        """
        proxies = {"proxies": {
            "🤖 OpenAi": {"type": "Selector", "all": ["🧠 AI·干净IP"],
                          "now": "🧠 AI·干净IP"},
            "🧠 AI·干净IP": {"type": "Fallback",
                          "all": ["🏠 固定IP·经良心云", "🏠 固定IP·美国-阿什本"],
                          "now": "🏠 固定IP·经良心云"},
            "🏠 固定IP·经良心云": {"type": "Http"},
            "🏠 固定IP·美国-阿什本": {"type": "Http"},
        }}
        self.mod.controller_config = lambda _cli: (("unix", "/fake.sock", None), "")
        self.mod.api_get = lambda _b, _s, _p: proxies
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.mod.node_scan(self.clash, "🤖 OpenAi")   # 不再 SystemExit
        text = out.getvalue()
        self.assertIn("NOCHOICE\t🧠 AI·干净IP\tFallback", text)
        self.assertIn("🏠 固定IP·经良心云|🏠 固定IP·美国-阿什本", text)
        self.assertNotIn("NODE\t", text, "自动选路组的成员不该被列成可点候选")

    def test_scan_rejects_unknown_group(self):
        self.mod.controller_config = lambda _cli: (("unix", "/fake.sock", None), "")
        self.mod.api_get = lambda _b, _s, _p: fake_proxies()
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit):
            self.mod.node_scan(self.clash, "不存在的组")


class NodeScanCommandTests(unittest.TestCase):
    """node-scan/node-apply 命令对外可见性。

    「更优节点」检查行已换成「DNS泄露」(2026-11-24):checkdetail 不再读
    node-scan.txt 落三态结论,扫描结论由报告面板承载。命令本身不变。
    """

    def setUp(self):
        (ROOT / "_trash").mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(prefix="node-scan-cmd-", dir=ROOT / "_trash")
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name) / "home"
        (self.home / ".claude-switcher").mkdir(parents=True)
        self.bin = Path(self.tmp.name) / "bin"
        self.bin.mkdir()
        self.env = dict(os.environ, HOME=str(self.home),
                        PATH=str(self.bin) + ":/usr/bin:/bin:/usr/sbin:/sbin",
                        CLAUDE_SWITCHER_PYTHON=sys.executable, PYTHONUTF8="1",
                        TZ_WATCHDOG_FILE=str(Path(self.tmp.name) / "no-watchdog.sh"))
        self.stub("pgrep", "exit 1")
        self.stub("ifconfig", "echo 'inet 198.18.0.1'")
        self.stub("curl", '''case "$*" in
  *cdn-cgi/trace*) printf 'ip=203.0.113.10\nloc=US\n' ;;
  *ipinfo.io*) printf '{"org":"Example Residential"}' ;;
  *claude.ai*|*api.anthropic.com*) printf '200' ;;
esac''')
        self.stub("dig", "echo 198.18.0.2")
        self.stub("defaults", 'echo en_US')
        self.stub("networksetup", 'echo "IPv6: Off"')
        self.stub("launchctl", "exit 1")
        self.stub("readlink", "echo /var/db/timezone/zoneinfo/America/New_York")

    def stub(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/bash\n" + body + "\n", encoding="utf-8")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    def core(self):
        path = Path(self.tmp.name) / "claude-switch.sh"
        path.write_text(SOURCE.read_text(encoding="utf-8"), encoding="utf-8")
        path.chmod(0o755)
        return path

    def run_core(self, *args):
        return subprocess.run(["/bin/bash", str(self.core()), *args], text=True,
                              capture_output=True, env=self.env, timeout=60)

    @staticmethod
    def line(output, name):
        match = re.search(r"(?m)^" + re.escape(name) + r"=(.*)$", output)
        return match.group(1) if match else None

    def report(self, **overrides):
        values = {"EPOCH": str(int(__import__("time").time())), "GROUP": "🤖 OpenAi",
                  "SELECTOR": "🧠 AI·干净IP", "CURRENT": "A", "CURRENT_SCORE": "49",
                  "BEST": "B", "BEST_SCORE": "88", "BEST_IP": "192.0.2.12",
                  "BEST_SELECTOR": "🧠 AI·干净IP",
                  "DELTA": "39", "GATE": "report-only", "ELIGIBLE": "4",
                  "CANDIDATES": "11", "UNIQUE_IPS": "3", "SCAN_TIME": "11-04 09:52",
                  "PREFERRED": "", "PREFERRED_MATCH": "-1"}
        values.update(overrides)
        (self.home / ".claude-switcher/node-scan.txt").write_text(
            "".join("%s=%s\n" % (k, v) for k, v in values.items()), encoding="utf-8")

    def test_checkdetail_carries_dns_leak_not_node_row(self):
        """检查位换成了 DNS泄露;更优节点行不再出现在 checkdetail 输出里。"""
        self.report(PREFERRED="B", PREFERRED_MATCH="1")
        out = self.run_core("checkdetail").stdout
        self.assertIsNone(self.line(out, "更优节点"), "旧行不该残留")
        value = self.line(out, "DNS泄露")
        self.assertIsNotNone(value, "新检查项必须在")
        self.assertNotIn("更优节点=", out)

    def test_help_documents_node_scan(self):
        out = self.run_core("help").stdout
        self.assertIn("node-scan", out)
        self.assertIn("node-apply", out)
        self.assertIn("不切节点", out)


class PurityFailReasonTests(unittest.TestCase):
    """68 分被排除时,报告必须写清「命中的是哪条硬门槛」,不是「风险过高」。

    score 是宽口径 IP 信誉,verdict 是能不能拿它开 Claude 的硬判定。
    代理/VPN 基线 75 分,扣完风险分仍可能 68 分,但代理特征直接判 fail。
    旧版把所有 fail 写成「风险过高(Tor/代理特征)」,高分与结论并排自相矛盾,
    连 Tor、机房转租段、低信誉分这些非代理的 fail 也被错标成代理特征。
    """

    @staticmethod
    def call(fn, *args):
        """把纯函数从脚本里抠出来单独跑,不触发脚本的其它动作。"""
        src = SOURCE.read_text(encoding="utf-8")
        start = src.index(fn + "() {")
        end = src.index("\n}\n", start) + len("\n}\n")
        script = src[start:end] + '\n%s "$@"\n' % fn
        run = subprocess.run(["/bin/bash", "-c", script, "bash", *args],
                             text=True, capture_output=True, timeout=10)
        return run.stdout.strip()

    def helper(self, *args):
        return self.call("purity_fail_reason", *args)

    def test_high_score_proxy_fail_names_the_real_gate(self):
        out = self.helper("vpn", "68", "fail")
        self.assertIn("代理/VPN 特征", out)
        self.assertIn("信誉 68 分", out)
        self.assertIn("分数与判定分开", out)
        self.assertNotIn("风险过高", out)

    def test_other_fail_types_are_not_mislabelled_as_proxy(self):
        tor = self.helper("tor", "47", "fail")
        self.assertIn("Tor 出口", tor)
        self.assertNotIn("代理/VPN 特征", tor)
        hosting = self.helper("hosting", "26", "fail")
        self.assertIn("机房转租段", hosting)
        self.assertNotIn("代理/VPN 特征", hosting)
        low = self.helper("unknown", "42", "fail")
        self.assertIn("信誉分偏低", low)
        self.assertNotIn("代理/VPN 特征", low)

    def test_non_fail_and_bad_score_are_safe(self):
        """只给 fail 加解释;分数不是数字时不能让 bash 算术报错。"""
        self.assertEqual("", self.helper("vpn", "68", "warn"))
        self.assertEqual("", self.helper("residential", "100", "ok"))
        self.assertEqual("代理/VPN 特征", self.helper("vpn", "", "fail"))
        self.assertEqual("代理/VPN 特征", self.helper("vpn", "n/a", "fail"))
        self.assertIn("信誉 49 分", self.helper("vpn", "49", "fail"))

    def test_scan_report_uses_one_shared_reason_and_explains_the_scales(self):
        src = SOURCE.read_text(encoding="utf-8")
        self.assertNotIn("风险过高(Tor/代理特征)", src,
                         "旧文案把 68 分也写成风险过高,且给非代理 fail 扣错帽子")
        self.assertNotIn("出口纯净度低", src)
        self.assertIn('fail) why="硬门槛:$(purity_fail_reason', src)
        self.assertIn("口径:分数 = IP 信誉", src)
        self.assertIn("90-100 优秀", src)
        self.assertIn("读法:先看「可用/不可用」", src)

    def test_udp_hard_gate_follows_the_webrtc_policy(self):
        """reject 策略下 UDP/3478 已在规则层拒绝,不该再按节点 UDP 一票否决。

        否则「一键修复」刚把用户切到 reject,扫描表就把他正在用的 HTTP 节点
        标成「UDP 未标注 · 不可用」,两处结论互相打架。
        """
        src = SOURCE.read_text(encoding="utf-8")
        self.assertIn('wpolicy=$(tr -d', src)
        self.assertIn('if [ -f "$BASE/webrtc-policy" ]', src)
        self.assertIn('[ "$udp" = "0" ] && [ "$wpolicy" != "reject" ]', src)
        self.assertIn('[ "$wpolicy" = "reject" ] && udp_gate_hint=', src)
        # proxy / 策略文件缺失时仍保持原来的保守门禁。
        self.assertIn('local wpolicy="proxy"', src)

    def test_score_bands_answer_how_good_is_good(self):
        """用户原话:「这几个看不懂,多少是好,多少是不好」。

        区间必须能和 verdict 的分数线对上:75 是 ok 线、50 是 warn 线、
        30 是机房转租段的拦线。只给分数不给参照系,49 和 68 就没法判断。
        """
        for score, band in (("100", "优秀"), ("90", "优秀"), ("89", "良好"),
                            ("75", "良好"), ("74", "一般"), ("50", "一般"),
                            ("49", "偏差"), ("30", "偏差"), ("29", "差"),
                            ("0", "差")):
            self.assertEqual(self.call("purity_band", score), band, score)
        for bad in ("", "n/a", "未评级"):
            self.assertEqual(self.call("purity_band", bad), "未评级", bad)

    def test_no_bare_variable_glued_to_a_multibyte_char(self):
        """bash 3.2 会把 `$var` 后面紧跟的顿号/≠ 并进变量名,set -u 下直接 unbound。

        实测:node-scan 报 `line 3214: reasons<乱码>: unbound variable`,
        连带 node_gate 整段输出为空,报告里出现 `门禁:()` 并静默不肯应用。
        中文标点紧跟在变量后面时,一律写成 ${var}。
        """
        pattern = re.compile(r"\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7f]")
        for path in (SOURCE, ROOT / "installer/安装.command", ROOT / "installer/卸载.command"):
            hits = ["L%d %s" % (i, m.group(0))
                    for i, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1)
                    for m in [pattern.search(line)] if m]
            self.assertEqual(hits, [], "%s 里变量名粘上了中文标点: %s" % (path.name, hits))


def _optional_keys(source):
    """从脚本里抠出 OPTIONAL 元组,免得测试和源码各存一份清单慢慢走偏。"""
    text = source.read_text(encoding="utf-8")
    match = re.search(r"^OPTIONAL = \((.*?)\)\n", text, re.M | re.S)
    return re.findall(r'"([^"]+)"', match.group(1))


if __name__ == "__main__":
    unittest.main()
