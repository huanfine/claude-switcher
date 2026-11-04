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

    def test_scan_rejects_unknown_group(self):
        self.mod.controller_config = lambda _cli: (("unix", "/fake.sock", None), "")
        self.mod.api_get = lambda _b, _s, _p: fake_proxies()
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit):
            self.mod.node_scan(self.clash, "不存在的组")


class NodeScanCommandTests(unittest.TestCase):
    """checkdetail 读报告文件的三态,以及命令对外可见性。"""

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
  *cdn-cgi/trace*) printf 'ip=203.0.113.10\\nloc=US\\n' ;;
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
                  "PREFERRED": "", "PREFERRED_MATCH": "-1"}
        values.update(overrides)
        (self.home / ".claude-switcher/node-scan.txt").write_text(
            "".join("%s=%s\n" % (k, v) for k, v in values.items()), encoding="utf-8")

    def test_no_report_is_skip_not_ok(self):
        run = self.run_core("checkdetail")
        value = self.line(run.stdout, "更优节点")
        self.assertIsNotNone(value, run.stdout + run.stderr)
        self.assertTrue(value.startswith("skip:"), value)
        self.assertIn("尚未扫描", value)

    def test_expired_report_is_skip(self):
        self.report(EPOCH="1")
        value = self.line(self.run_core("checkdetail").stdout, "更优节点")
        self.assertTrue(value.startswith("skip:"), value)
        self.assertIn("已过期", value)

    def test_fresh_report_with_better_node_is_warn(self):
        self.report()
        value = self.line(self.run_core("checkdetail").stdout, "更优节点")
        self.assertTrue(value.startswith("warn:"), value)
        self.assertIn("B", value)
        self.assertIn("88 分", value)
        self.assertIn("39 分", value)

    def test_hint_names_the_button_that_really_exists(self):
        """提示词必须和界面按钮对得上,不能叫用户去点一个不存在的东西。

        auto-ok 时面板里真有「应用最优节点」;report-only 时那个按钮不出现,
        就不能许诺它。按钮名统一叫「扫描可用节点」(右上角网络图标的 help)。
        """
        self.report(GATE="auto-ok")
        allowed = self.line(self.run_core("checkdetail").stdout, "更优节点")
        self.assertIn("应用最优节点", allowed)
        self.assertIn("扫描可用节点", allowed)

        self.report(GATE="report-only")
        denied = self.line(self.run_core("checkdetail").stdout, "更优节点")
        self.assertNotIn("应用最优节点", denied, denied)
        self.assertIn("手动切换", denied)

    def test_report_without_better_node_is_ok(self):
        self.report(BEST="", DELTA="0")
        value = self.line(self.run_core("checkdetail").stdout, "更优节点")
        self.assertTrue(value.startswith("ok:"), value)

    def test_fixed_node_is_ok_and_drift_is_warn(self):
        """固定节点后这一项不能假绿;被人改回去要能发现。"""
        self.report(PREFERRED="B", PREFERRED_MATCH="1")
        value = self.line(self.run_core("checkdetail").stdout, "更优节点")
        self.assertTrue(value.startswith("ok:"), value)
        self.assertIn("已固定在 B", value)

        self.report(PREFERRED="B", PREFERRED_MATCH="0", BEST="C")
        value = self.line(self.run_core("checkdetail").stdout, "更优节点")
        self.assertTrue(value.startswith("warn:"), value)
        self.assertIn("已偏离固定节点 B", value)

    def test_help_documents_node_scan(self):
        out = self.run_core("help").stdout
        self.assertIn("node-scan", out)
        self.assertIn("node-apply", out)
        self.assertIn("不切节点", out)
        self.assertIn("只出报告", out)
        self.assertIn("自动回滚", out)

    # ---- node-apply 的执行门禁:必须**先于**任何内核写操作拦住 ----

    def test_apply_rejects_running_claude(self):
        self.report()
        self.stub("pgrep", "exit 0")
        run = self.run_core("node-apply")
        self.assertNotEqual(run.returncode, 0)
        blob = run.stdout + run.stderr
        self.assertIn("已有实例环境", blob)
        self.assertIn("Claude 正在运行", blob)
        self.assertNotIn("读不到运行中的内核节点", blob,
                         "门禁必须在碰内核之前拦住,不能先切了再说")

    def test_apply_rejects_existing_account_slot(self):
        self.report()
        (self.home / ".claude-switcher/accounts/A").mkdir(parents=True)
        run = self.run_core("node-apply")
        blob = run.stdout + run.stderr
        self.assertIn("已有账号槽位", blob)
        self.assertNotIn("读不到运行中的内核节点", blob)

    def test_stale_watch_pidfile_does_not_block_apply(self):
        """看门狗这一条从「pidfile 在不在」升级成「进程真活着吗」。

        残留 pidfile 不该把刚停完守护的 App 卡住;反过来真有守护在跑仍要拦。
        这里 pid 指向一个不存在的进程,应放行到下一步(假环境里内核读不到)。
        """
        self.report()
        (self.home / ".claude-switcher/watch.pid").write_text("999999\t/fake/base\n",
                                                              encoding="utf-8")
        run = self.run_core("node-apply")
        blob = run.stdout + run.stderr
        self.assertNotIn("已有实例环境", blob, blob)
        self.assertIn("读不到运行中的内核节点", blob,
                      "门禁应放行;后面的失败来自假环境没有内核,不是门禁")

    def test_apply_rejects_bad_report(self):
        for overrides, expected in (
            ({"EPOCH": "1"}, "已过期"),
            ({"BEST": ""}, "无需应用"),
        ):
            self.report(**overrides)
            blob = self.run_core("node-apply").stdout + self.run_core("node-apply").stderr
            self.assertIn(expected, blob)
        (self.home / ".claude-switcher/node-scan.txt").unlink()
        blob = self.run_core("node-apply").stdout + self.run_core("node-apply").stderr
        self.assertIn("还没有扫描报告", blob)

    def test_new_check_is_optional_and_accepted_by_config(self):
        """设置页关得掉这一项;写进去的设置不能被 config 校验拒掉。"""
        self.assertIn("更优节点", _optional_keys(SOURCE), "OPTIONAL 白名单漏了新检查项")
        run = subprocess.run(
            ["/bin/bash", str(self.core()), "set-check-config",
             '{"disabled":["更优节点"],"allowOptionalFailures":false,"logging":true}'],
            text=True, capture_output=True, env=self.env, timeout=30)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        saved = subprocess.run(["/bin/bash", str(self.core()), "get-check-config"],
                               text=True, capture_output=True, env=self.env, timeout=30)
        self.assertIn("更优节点", json.loads(saved.stdout)["disabled"])
        value = self.line(self.run_core("checkdetail").stdout, "更优节点")
        self.assertTrue(value.startswith("skip:"), value)


def _optional_keys(source):
    """从脚本里抠出 OPTIONAL 元组,免得测试和源码各存一份清单慢慢走偏。"""
    text = source.read_text(encoding="utf-8")
    match = re.search(r"^OPTIONAL = \((.*?)\)\n", text, re.M | re.S)
    return re.findall(r'"([^"]+)"', match.group(1))


if __name__ == "__main__":
    unittest.main()
