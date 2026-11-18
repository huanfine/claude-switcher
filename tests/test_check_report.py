"""检查报告 v2 的契约测试。

背景:文本行是给人看的,但 App、自动化和跨平台入口需要一个稳定契约。
这里锁住三件事:
  1. 稳定 ID 与判定口径不随中文显示名漂移;
  2. 缺关键项 / 全 skip / config 都不能被当成 established;
  3. 报告绑定当前环境与核心脚本,环境一变指纹就变。
"""
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "core" / "claude-switch.sh"
EXPECTED_IDS = [
    "proxy_core", "tun", "egress_ip", "ip_stability", "timezone", "locale",
    "ipv6", "dns", "webrtc", "bodyguard", "rules", "client_language", "asn",
    "ip_purity", "ecosystem", "better_node",
]
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


class ReportTests(unittest.TestCase):
    def setUp(self):
        (ROOT / "_trash").mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(prefix="check-report-", dir=ROOT / "_trash")
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name) / "home"
        self.home.mkdir()
        (self.home / ".claude-switcher").mkdir()
        self.env = dict(os.environ, HOME=str(self.home),
                        CLAUDE_SWITCHER_PYTHON=sys.executable, PYTHONUTF8="1")

    def support(self, *args):
        return subprocess.run(["/bin/bash", str(SCRIPT), "_support", *args],
                              env=self.env, text=True, capture_output=True, timeout=30)

    def report(self, text):
        path = Path(self.tmp.name) / "last-check.txt"
        path.write_text(text, encoding="utf-8")
        run = self.support("report", str(path), str(SCRIPT))
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        return json.loads(run.stdout)

    def test_schema_ids_and_summary(self):
        doc = self.report(FULL)
        self.assertEqual(doc["schema"], "claude-switcher-report/2")
        self.assertEqual(doc["protocol"], 2)
        self.assertEqual([c["id"] for c in doc["checks"]], EXPECTED_IDS)
        self.assertEqual(doc["verdict"], "established")
        self.assertEqual(doc["summary"]["expected"], 16)
        self.assertEqual(doc["summary"]["total"], 16)
        self.assertEqual(doc["summary"]["missing"], [])
        self.assertEqual(doc["summary"]["blockers"], [])
        # TUN/时区/地区/规则置顶目前只有状态没有细节。报告必须如实标出来,
        # 不能用“ok”冒充“已验证到某个值”。
        self.assertEqual(set(doc["summary"]["evidence_missing"]),
                         {"TUN网卡", "时区", "地区", "规则置顶"})
        self.assertTrue(doc["report_id"])
        self.assertIn("config_fingerprint", doc)
        self.assertGreater(doc["expires_at"], doc["created_at"])

    def test_missing_critical_is_incomplete_not_established(self):
        doc = self.report("代理内核=ok:x\n出口IP=ok:203.0.113.10/US\n")
        self.assertEqual(doc["verdict"], "incomplete")
        self.assertIn("TUN网卡", doc["summary"]["missing_critical"])
        self.assertIn("保镖", doc["summary"]["missing_critical"])

    def test_all_skipped_is_incomplete(self):
        doc = self.report("".join(
            "%s=skip:用户已禁用\n" % name for name in
            ("代理内核", "TUN网卡", "出口IP", "IP一致", "时区", "地区", "IPv6", "DNS",
             "WebRTC", "保镖", "规则置顶", "客户端语言", "ASN属性", "IP纯净度",
             "生态可达性", "更优节点")))
        self.assertEqual(doc["verdict"], "incomplete")
        self.assertEqual(doc["summary"]["skipped"], 16)

    def test_fail_and_config_are_violated(self):
        text = FULL.replace("时区=ok", "时区=config:环境层未就绪(未取到时区目标) · 点「一键修复」")
        text = text.replace("规则置顶=ok", "规则置顶=fail:内核缺少 Claude 域名")
        doc = self.report(text)
        self.assertEqual(doc["verdict"], "violated")
        self.assertEqual(set(doc["summary"]["blockers"]), {"时区", "规则置顶"})
        self.assertEqual(set(doc["summary"]["critical_blockers"]), {"时区", "规则置顶"})
        timezone = next(c for c in doc["checks"] if c["id"] == "timezone")
        self.assertEqual(timezone["state"], "config")
        self.assertTrue(timezone["remedy"])

    def test_duplicate_rows_are_reported_and_block(self):
        doc = self.report(FULL + "出口IP=ok:203.0.113.10/US\n")
        self.assertEqual(doc["verdict"], "violated")
        self.assertEqual(doc["summary"]["duplicates"], ["出口IP"])

    def test_unknown_check_is_preserved_not_dropped(self):
        doc = self.report(FULL + "未来检查=ok:fixture\n")
        unknown = next(c for c in doc["checks"] if c["name"] == "未来检查")
        self.assertFalse(unknown["known"])
        self.assertFalse(unknown["critical"])
        self.assertTrue(unknown["id"].startswith("unknown-"))
        self.assertEqual(doc["summary"]["unknown"], ["未来检查"])

    def test_fingerprint_changes_when_environment_changes(self):
        first = self.report(FULL)["config_fingerprint"]
        run = self.support("env-set", "country=JP", "timezone=Asia/Tokyo")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        second = self.report(FULL)["config_fingerprint"]
        self.assertNotEqual(first, second)

    def test_checkdetail_json_writes_both_reports(self):
        bin_dir = Path(self.tmp.name) / "bin"
        bin_dir.mkdir()

        def stub(name, body):
            path = bin_dir / name
            path.write_text("#!/bin/bash\n" + body + "\n", encoding="utf-8")
            path.chmod(path.stat().st_mode | stat.S_IXUSR)

        stub("pgrep", "exit 0")
        stub("ifconfig", "echo 'inet 198.18.0.1'")
        stub("curl", """case "$*" in
  *%{time_total}*) printf '200 0.050\\n' ;;
  *cdn-cgi/trace*) printf 'ip=203.0.113.10\\nloc=US\\n' ;;
  *ipinfo.io*) printf '{"org":"Example Residential"}' ;;
  *claude.ai*|*api.anthropic.com*) printf '200' ;;
  *) printf '' ;;
esac""")
        stub("dig", "echo 198.18.0.2")
        stub("defaults", """if [[ "$*" == *AppleLocale* ]]; then echo en_US; else printf '(\\n    en-US,\\n)'; fi""")
        stub("networksetup", "case \"$1\" in -listallnetworkservices) printf 'header\\nWi-Fi\\n' ;; *) echo 'IPv6: Off' ;; esac")
        stub("launchctl", "exit 1")
        stub("readlink", "echo /var/db/timezone/zoneinfo/America/New_York")
        env = dict(self.env, PATH=str(bin_dir) + ":/usr/bin:/bin:/usr/sbin:/sbin")
        run = subprocess.run(["/bin/bash", str(SCRIPT), "checkdetail", "--json"], env=env,
                             text=True, capture_output=True, timeout=90)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        doc = json.loads(run.stdout)
        self.assertEqual(doc["schema"], "claude-switcher-report/2")
        self.assertEqual(len(doc["checks"]), 16)
        self.assertEqual(doc["probes"]["proxy"]["status"], "ok")
        self.assertEqual(doc["probes"]["direct"]["status"], "unknown")
        last_check = self.home / ".claude-switcher" / "last-check.txt"
        last_report = self.home / ".claude-switcher" / "last-report.json"
        self.assertTrue(last_check.exists())
        self.assertTrue(last_report.exists())
        self.assertEqual(json.loads(last_report.read_text(encoding="utf-8"))["protocol"], 2)
        self.assertEqual(stat.S_IMODE(last_report.stat().st_mode), 0o600)


if __name__ == "__main__":
    unittest.main()
