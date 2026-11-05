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
                  "CANDIDATES": "11", "UNIQUE_IPS": "3", "SCAN_TIME": "11-04 09:52",
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

    def test_no_better_node_detail_carries_real_numbers(self):
        """「当前线路最干净」必须挂得上依据,不能是一句看不到证据的空话。

        用户原话:「现在显示的是当前线路是候选里面最干净的,没有具体内容」。
        """
        self.report(BEST="", DELTA="0")
        value = self.line(self.run_core("checkdetail").stdout, "更优节点")
        self.assertTrue(value.startswith("ok:"), value)
        for piece in ("11 候选", "3 出口", "4 合格", "当前 49 分", "11-04 09:52 扫描"):
            self.assertIn(piece, value)

    def test_legacy_report_omits_missing_numbers(self):
        """负例:06:54 那种旧格式报告缺统计字段,逐项省略,不能补 0 冒充实测。"""
        self.report(BEST="", DELTA="0", CANDIDATES="", UNIQUE_IPS="",
                    ELIGIBLE="", SCAN_TIME="", CURRENT_SCORE="")
        value = self.line(self.run_core("checkdetail").stdout, "更优节点")
        self.assertTrue(value.startswith("ok:"), value)
        self.assertNotIn("0 候选", value, value)
        self.assertNotIn("当前  分", value, value)

    def test_no_eligible_candidate_is_skip_not_ok(self):
        """一个过硬门槛的候选都没有 = 这轮没比成,不能报 ok「当前最干净」。"""
        self.report(BEST="", DELTA="0", ELIGIBLE="0")
        value = self.line(self.run_core("checkdetail").stdout, "更优节点")
        self.assertTrue(value.startswith("skip:"), value)
        self.assertIn("没有过硬门槛", value)
        self.assertIn("11 候选", value)

    def test_human_report_lists_all_candidates_and_scan_time(self):
        """面板里给人看的那段要列全部候选(含排除原因),不能只给前三名。"""
        src = SOURCE.read_text(encoding="utf-8")
        self.assertIn("--- 全部候选(可用优先,再按分数;含区间与排除原因) ---", src)
        self.assertIn("SCAN_TIME=", src)
        self.assertNotIn("--- 排名(前 3) ---", src,
                         "只列前三名时,被排除的节点为什么不能选就看不见了")

    def test_conclusion_only_compares_eligible_candidates(self):
        """列了全部候选之后,68 分被硬门槛排除、当前 49 分,不能还说「最干净」。

        全部排名里一眼能看到分数更高的节点,结论必须说清比较范围,
        并解释高分候选为什么不算 —— 否则就是自己跟自己打架。
        """
        src = SOURCE.read_text(encoding="utf-8")
        self.assertIn("过硬门槛内没有更优节点", src)
        self.assertIn("个候选分数更高,但没过硬门槛", src)
        self.assertNotIn("当前线路已是候选里最干净的", src)

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
        self.assertIn("按约定只出报告", blob)
        self.assertIn("Claude 正在运行", blob)
        self.assertNotIn("读不到运行中的内核节点", blob,
                         "门禁必须在碰内核之前拦住,不能先切了再说")

    def test_existing_account_slot_does_not_block_apply(self):
        """存过账号快照不等于有实例在跑。

        这条原来断言的是「已有账号槽位就拒绝」。可槽位是常驻资产:存过一次
        hasA=1 就永远为真,于是 node-apply 对任何用过本工具的人都是永久拒绝,
        界面上「应用最优节点」从不出现 —— 节点切换功能等于没有。
        现在只认「进程在跑」和「看门狗驻守」,槽位在不在不参与判定。
        """
        self.report()
        (self.home / ".claude-switcher/accounts/A").mkdir(parents=True)
        (self.home / ".claude-switcher/accounts/B").mkdir(parents=True)
        blob = self.run_core("node-apply").stdout + self.run_core("node-apply").stderr
        self.assertNotIn("已有账号槽位", blob, blob)
        self.assertNotIn("按约定只出报告", blob, blob)
        self.assertIn("读不到运行中的内核节点", blob,
                      "门禁应放行;后面的失败来自假环境没有内核,不是门禁")

    def test_scan_gate_ignores_existing_slots(self):
        """报告门禁同理:有槽位但没东西在跑,应当给 auto-ok。

        直接抽 node_gate 出来跑:完整 node-scan 要先读到内核,假环境里到不了
        打印门禁那一步,测不出这条。
        """
        (self.home / ".claude-switcher/accounts/A").mkdir(parents=True)
        src = SOURCE.read_text(encoding="utf-8")
        start = src.index("node_gate() {")
        end = src.index("\n}\n", start) + len("\n}\n")
        script = 'BASE="%s"\n%s\nnode_gate\n' % (self.home / ".claude-switcher",
                                                 src[start:end])
        run = subprocess.run(["/bin/bash", "-c", script], text=True,
                             capture_output=True, env=self.env, timeout=10)
        self.assertIn("auto-ok", run.stdout, run.stdout + run.stderr)
        self.assertNotIn("已有账号槽位", run.stdout, run.stdout)

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
        self.assertNotIn("按约定只出报告", blob, blob)
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
