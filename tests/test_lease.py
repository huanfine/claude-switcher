"""启动租约：报告只是快照，租约才是一次短授权。

锁住四条：
  1. 只有 established 报告能签发；
  2. 租约不能超出报告有效期，默认 120 秒；
  3. 环境 / 开关 / 核心变化后旧租约不能再放行；
  4. 报告被替换或租约被改过期，`lease-check` 必须拒绝。
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "core" / "claude-switch.sh"
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


class LeaseTests(unittest.TestCase):
    def setUp(self):
        (ROOT / "_trash").mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(prefix="lease-", dir=ROOT / "_trash")
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

    def make_report(self, text=FULL):
        path = Path(self.tmp.name) / "last-check.txt"
        path.write_text(text, encoding="utf-8")
        run = self.support("report", str(path), str(SCRIPT))
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        (self.base / "last-report.json").write_text(run.stdout, encoding="utf-8")
        return json.loads(run.stdout)

    def issue(self):
        self.make_report()
        run = self.support("lease", str(self.base / "last-report.json"), str(SCRIPT))
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        return json.loads((self.base / "lease.json").read_text(encoding="utf-8"))

    def check(self):
        return self.support("lease-check", str(SCRIPT))

    def test_valid_lease_and_check(self):
        lease = self.issue()
        self.assertEqual(lease["schema"], "claude-switcher-lease/1")
        self.assertTrue(lease["report_id"])
        self.assertGreater(lease["expires_at"], lease["issued_at"])
        run = self.check()
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("OK:租约有效至", run.stdout)

    def test_violated_and_all_skipped_reports_are_refused(self):
        self.make_report(FULL.replace("出口IP=ok:203.0.113.10/US", "出口IP=fail:出口在 JP"))
        run = self.support("lease", str(self.base / "last-report.json"), str(SCRIPT))
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("established", run.stderr)

        all_skip = "".join("%s=skip:用户已禁用\n" % name for name in (
            "代理内核", "TUN网卡", "出口IP", "IP一致", "时区", "地区", "IPv6", "DNS",
            "WebRTC", "保镖", "规则置顶", "客户端语言", "ASN属性", "IP纯净度",
            "生态可达性", "更优节点"))
        self.make_report(all_skip)
        run = self.support("lease", str(self.base / "last-report.json"), str(SCRIPT))
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("established", run.stderr)

    def test_environment_change_revokes_lease(self):
        self.issue()
        run = self.support("env-set", "country=JP")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertFalse((self.base / "lease.json").exists())
        run = self.check()
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("租约不存在", run.stderr)

    def test_replaced_report_invalidates_lease(self):
        self.issue()
        # 新报告即使内容一样，report_id 也变了；旧租约不能继续放行。
        self.make_report()
        run = self.check()
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("report_id", run.stderr)

    def test_expired_lease_is_rejected(self):
        self.issue()
        path = self.base / "lease.json"
        lease = json.loads(path.read_text(encoding="utf-8"))
        lease["expires_at"] = "2000-01-01T00:00:00+00:00"
        path.write_text(json.dumps(lease), encoding="utf-8")
        run = self.check()
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("已过期", run.stderr)

    def test_lease_is_private(self):
        self.issue()
        self.assertEqual((self.base / "lease.json").stat().st_mode & 0o777, 0o600)

    def test_switch_gate_rejects_invalid_lease(self):
        import re
        text = SCRIPT.read_text(encoding="utf-8")
        match = re.search(r"(?ms)^require_lease_for_launch\(\) \{\n.*?^\}", text)
        self.assertIsNotNone(match, "缺少 require_lease_for_launch")
        (self.base / "last-report.json").write_text("{}", encoding="utf-8")

        def run(gate_exit):
            harness = "set -u\nBASE=%s\nsupport() { return %d; }\n%s\nrequire_lease_for_launch\n" % (
                str(self.base), gate_exit, match.group(0))
            return subprocess.run(["/bin/bash", "-c", harness], env=self.env,
                                  text=True, capture_output=True, timeout=10)

        denied = run(1)
        self.assertNotEqual(denied.returncode, 0)
        self.assertIn("启动租约无效", denied.stdout)
        self.assertEqual(run(0).returncode, 0)


if __name__ == "__main__":
    unittest.main()
