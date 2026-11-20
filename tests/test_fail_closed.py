"""fail-closed 证据：16 项全绿证明不了「代理挂了会不会直连」。

只有 drill 能证明这件事，所以证据状态必须持续可见。锁住五条：
  1. 没有证据要说「未验证」，不能沉默、更不能当成通过；
  2. violated 要如实报出来，established 过期要降级成 stale；
  3. 老安装件只有 drill.log 时也读得出来；
  4. 它是软信号：不拦启动、不参与 config_fingerprint；
  5. 命令行与界面读的是同一个判定，不能只有界面看得见。
"""
import datetime
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "core" / "claude-switch.sh"
APP = ROOT / "app" / "main.swift"
FULL = textwrap.dedent("""\
    代理内核=ok:Clash Verge 运行中
    TUN网卡=ok
    出口IP=ok:203.0.113.10/US
    IP一致=ok:首次记录
    时区=ok
    地区=ok
    IPv6=ok:已关闭
    DNS=ok:走隧道
    WebRTC=ok:仅暴露代理出口IP
    保镖=ok:待命
    规则置顶=ok
    客户端语言=ok:en-US
    ASN属性=ok:Example Residential
    IP纯净度=ok:100/100 · 住宅宽带
    生态可达性=ok:claude.ai:200 api:200
    更优节点=skip:尚未扫描
""")


class FailClosedEvidenceTests(unittest.TestCase):
    def setUp(self):
        (ROOT / "_trash").mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(prefix="fail-closed-", dir=ROOT / "_trash")
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name) / "home"
        self.base = self.home / ".claude-switcher"
        self.base.mkdir(parents=True)
        self.env = dict(os.environ, HOME=str(self.home),
                        CLAUDE_SWITCHER_PYTHON=sys.executable, PYTHONUTF8="1")
        self.assertEqual(self.support("env-set", "country=US",
                                      "timezone=America/New_York", "locale=en_US").returncode, 0)

    def support(self, *args):
        return subprocess.run(["/bin/bash", str(SCRIPT), "_support", *args],
                              env=self.env, text=True, capture_output=True, timeout=30)

    def state(self):
        run = self.support("fail-closed")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        return run.stdout.strip().split("|")[0]

    def counters(self, result, checked_at):
        (self.base / "drill-counters.json").write_text(json.dumps({
            "schema": "claude-switcher-drill/1", "checked_at": checked_at, "result": result,
            "tcp": {"status": "ok", "success": 0, "failure": 3, "elapsed_ms": 10},
            "dns": {"status": "ok", "success": 0, "failure": 3, "elapsed_ms": 10},
            "webrtc": {"status": "unknown", "success": None, "failure": None, "elapsed_ms": None},
        }), encoding="utf-8")

    def report(self):
        path = Path(self.tmp.name) / "last-check.txt"
        path.write_text(FULL, encoding="utf-8")
        run = self.support("report", str(path), str(SCRIPT))
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        (self.base / "last-report.json").write_text(run.stdout, encoding="utf-8")
        return json.loads(run.stdout)

    @staticmethod
    def stamp(days_ago=0):
        moment = datetime.datetime.now().astimezone() - datetime.timedelta(days=days_ago)
        return moment.isoformat()

    def test_no_evidence_is_unverified(self):
        self.assertEqual(self.state(), "unverified")
        doc = self.report()
        self.assertEqual(doc["fail_closed"]["status"], "unverified")
        # 全绿的报告本身照样成立 —— 证据缺口不改判定,但必须写进报告。
        self.assertEqual(doc["verdict"], "established")

    def test_violated_is_reported(self):
        self.counters("violated:203.0.113.9", self.stamp())
        self.assertEqual(self.state(), "violated")
        self.assertEqual(self.report()["fail_closed"]["status"], "violated")

    def test_fresh_established_is_accepted(self):
        self.counters("established", self.stamp())
        self.assertEqual(self.state(), "established")
        self.assertEqual(self.report()["fail_closed"]["status"], "established")

    def test_old_established_goes_stale(self):
        """演练证明的是当时那套配置,不是永久结论。"""
        self.counters("established", self.stamp(days_ago=8))
        self.assertEqual(self.state(), "stale")

    def test_legacy_drill_log_is_read(self):
        """老安装件只有 drill.log,没有计数器文件。"""
        (self.base / "drill.log").write_text(
            "%d baseline=203.0.113.10 after=none result=violated:198.51.100.7 "
            "tcp=0/3 dns=0/3 webrtc=0/1\n" % int(time.time()), encoding="utf-8")
        self.assertEqual(self.state(), "violated")
        (self.base / "drill.log").write_text(
            "%d baseline=203.0.113.10 after=none result=established "
            "tcp=0/3 dns=0/3 webrtc=0/1\n" % int(time.time()), encoding="utf-8")
        self.assertEqual(self.state(), "established")

    def test_unreadable_record_is_unverified(self):
        self.counters("something-else", self.stamp())
        self.assertEqual(self.state(), "unverified")

    def test_evidence_does_not_change_fingerprint(self):
        """证据不是环境配置:换个演练结论不该让已签发的租约失效。"""
        before = self.report()["config_fingerprint"]
        self.counters("violated:203.0.113.9", self.stamp())
        self.assertEqual(self.report()["config_fingerprint"], before)

    def test_evidence_is_soft_signal(self):
        """没跑过演练不能拦启动 —— 那是拿我们自己的证据缺口去堵用户。"""
        self.counters("violated:203.0.113.9", self.stamp())
        self.report()
        run = self.support("lease", str(self.base / "last-report.json"), str(SCRIPT))
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(self.support("lease-check", str(SCRIPT)).returncode, 0)

    def test_drill_without_probes_sidecar_still_builds_report(self):
        """只有演练计数器、没有 probes sidecar 时不能崩。

        离线 `report` 和 sidecar 失败都会走到这条路:drill-counters.json 是上一次
        演练留下的,probes.json 却只对得上本轮检查。曾经这里对 None 取 .get,
        于是「跑过一次 drill」的用户整份 JSON 报告直接生成失败。
        """
        self.counters("established", self.stamp())
        doc = self.report()
        self.assertNotIn("error", doc)
        self.assertEqual(doc["probes"]["drill"]["result"], "established")
        self.assertIsNone(doc["probes"]["proxy"])
        self.assertIsNone(doc["probes"]["direct"])


class FailClosedWiringTests(unittest.TestCase):
    """命令行与界面必须读同一个判定,不能只有界面看得见。"""

    def test_gate_output_carries_marker(self):
        text = SCRIPT.read_text(encoding="utf-8")
        start = text.index("check() {")
        body = text[start:text.index("\n}\n", start)]
        self.assertIn('support fail-closed', body)
        for marker in ("fail-closed未验证", "fail-closed演练未通过", "fail-closed证据已过期"):
            self.assertIn(marker, body)
        self.assertIn('${fc:+|$fc}', body)

    def test_app_decodes_field_and_keeps_notice(self):
        text = APP.read_text(encoding="utf-8")
        self.assertIn('case failClosed = "fail_closed"', text)
        # 缺字段按未验证处理,不能因为读不到就当成通过
        self.assertIn('report.failClosed?.status ?? "unverified"', text)
        # 这条没通过时它必须还看得见。形态变过:从「顶部横贯整窗的一条横幅」
        # 收成 hero 卡守护面里的第二行,但「看得见」这件事没变。
        self.assertIn("private var drillState", text)
        self.assertIn("private func drillRow", text)

    def test_drill_entry_pauses_watchdog_first(self):
        """演练会主动让出口消失 —— 先停看门狗,否则它自己就把 Claude 停了。

        漏掉这一步的后果不是「少提醒一次」:看门狗 10 秒一轮、连丢三次就
        执行 stop_claude_now,用户点一下「复验」等于亲手杀掉自己的会话。
        """
        text = APP.read_text(encoding="utf-8")
        start = text.index("func runDrill()")
        body = text[start:text.index("\n    }\n", start)]
        self.assertIn("stopWatch()", body)
        self.assertLess(body.index("stopWatch()"), body.index('"drill", "--auto"'))

    def test_announcement_does_not_overclaim(self):
        """演练可能不通过,公告不能再写「任何场景下零暴露」。"""
        text = APP.read_text(encoding="utf-8")
        self.assertNotIn("确保本地真实出口在任何场景下零暴露", text)
        self.assertIn("故障演练（drill）", text)


if __name__ == "__main__":
    unittest.main()