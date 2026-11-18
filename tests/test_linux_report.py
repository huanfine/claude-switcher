"""Linux 原生报告入口的契约测试。

Linux 版只有 14 项检查;报告仍使用 16 个稳定 ID,并把缺失的
IP纯净度 / 更优节点 如实写进 summary.missing,不能伪造 ok。
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "linux" / "claude-switch.sh"
FULL = """\
代理内核=ok:Clash Verge 运行中
TUN网卡=ok
出口IP=ok:203.0.113.10/US
IP一致=ok:首次记录
时区=ok
地区=ok
IPv6=ok:已关闭
DNS=ok:走隧道
WebRTC=ok:仅暴露代理IP
保镖=ok:待命
规则置顶=ok
客户端语言=ok:跟随系统
ASN属性=ok:Example Residential
生态可达性=ok:claude.ai:200 api:200
"""


class LinuxReportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="linux-report-", dir=ROOT / "_trash")
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name) / "home"
        self.home.mkdir()
        self.env = dict(os.environ, HOME=str(self.home))

    def report(self, text):
        path = Path(self.tmp.name) / "last-check.txt"
        path.write_text(text, encoding="utf-8")
        run = subprocess.run(["/bin/bash", str(SCRIPT), "report", str(path)],
                             env=self.env, text=True, capture_output=True, timeout=30)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        return json.loads(run.stdout)

    def test_schema_and_missing_platform_checks_are_explicit(self):
        doc = self.report(FULL)
        self.assertEqual(doc["schema"], "claude-switcher-report/2")
        self.assertEqual(doc["protocol"], 2)
        self.assertEqual(doc["summary"]["expected"], 16)
        self.assertEqual(doc["summary"]["total"], 14)
        self.assertEqual(doc["summary"]["missing"], ["IP纯净度", "更优节点"])
        self.assertEqual(doc["verdict"], "established")
        self.assertEqual(doc["platform"], "Linux")
        self.assertEqual(len(doc["checks"]), 14)
        self.assertTrue(doc["report_id"])
        self.assertTrue(doc["config_fingerprint"])

    def test_fingerprint_is_stable_but_report_id_is_not(self):
        first = self.report(FULL)
        second = self.report(FULL)
        self.assertEqual(first["config_fingerprint"], second["config_fingerprint"])
        self.assertNotEqual(first["report_id"], second["report_id"])

    def test_duplicate_and_unknown_rows_are_not_silently_dropped(self):
        doc = self.report(FULL + "未来检查=ok:fixture\n出口IP=ok:203.0.113.10/US\n")
        self.assertEqual(doc["verdict"], "violated")
        self.assertEqual(doc["summary"]["duplicates"], ["出口IP"])
        unknown = next(c for c in doc["checks"] if c["name"] == "未来检查")
        self.assertFalse(unknown["known"])
        self.assertTrue(unknown["id"].startswith("unknown-"))
        self.assertEqual(doc["summary"]["unknown"], ["未来检查"])

    def test_missing_critical_is_incomplete(self):
        doc = self.report("代理内核=ok:x\n出口IP=ok:203.0.113.10/US\n")
        self.assertEqual(doc["verdict"], "incomplete")
        self.assertIn("TUN网卡", doc["summary"]["missing_critical"])

    def test_checkdetail_json_is_wired_but_plain_output_is_unchanged(self):
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertIn('if [ "${2:-}" = "--json" ]', source)
        self.assertIn("report_json \"$OUT\" \"$0\"", source)
        self.assertIn('report) report_json', source)

    def test_checkdetail_json_writes_both_reports_with_stubs(self):
        bin_dir = Path(self.tmp.name) / "bin"
        bin_dir.mkdir()

        def stub(name, body):
            path = bin_dir / name
            path.write_text("#!/bin/bash\n" + body + "\n", encoding="utf-8")
            path.chmod(0o755)

        stub("pgrep", "exit 0")
        stub("ip", """case "$*" in
  *addr*) echo 'inet 198.18.0.1/16 scope global tun0' ;;
  *link*) echo '3: tun0: <POINTOPOINT,UP> mtu 1500' ;;
esac""")
        stub("curl", """case "$*" in
  *cdn-cgi/trace*) printf 'ip=203.0.113.10\\nloc=US\\n' ;;
  *ipinfo.io*) printf '{"org":"Example Residential"}' ;;
  *) printf '200' ;;
esac""")
        stub("dig", "echo 198.18.0.1")
        stub("timedatectl", "echo America/New_York")
        stub("sysctl", "echo 1")
        stub("systemctl", "exit 0")
        (self.home / ".claude-switcher").mkdir()
        (self.home / ".claude-switcher" / "stun-probe.py").write_text(
            'print("RESULT:203.0.113.10")\n', encoding="utf-8")
        env = dict(self.env, LANG="en_US.UTF-8", PATH=str(bin_dir) + ":/usr/bin:/bin:/usr/sbin:/sbin")
        run = subprocess.run(["/bin/bash", str(SCRIPT), "checkdetail", "--json"],
                             env=env, text=True, capture_output=True, timeout=60)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        doc = json.loads(run.stdout)
        self.assertEqual(doc["schema"], "claude-switcher-report/2")
        self.assertEqual(len(doc["checks"]), 14)
        self.assertEqual(doc["summary"]["missing"], ["IP纯净度", "更优节点"])
        self.assertTrue((self.home / ".claude-switcher" / "last-check.txt").exists())
        self.assertTrue((self.home / ".claude-switcher" / "last-report.json").exists())


if __name__ == "__main__":
    unittest.main()
