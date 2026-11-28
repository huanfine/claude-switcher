"""更新自检的 JSON 报告与回归判定契约。"""
import copy
import datetime
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "core" / "claude-switch.sh"
NAMES = (
    "代理内核", "TUN网卡", "出口IP", "IP一致", "时区", "地区", "IPv6", "DNS",
    "WebRTC", "保镖", "规则置顶", "客户端语言", "ASN属性", "IP纯净度", "生态可达性",
    "DNS泄露",
)


class UpdateReportContractTests(unittest.TestCase):
    def setUp(self):
        (ROOT / "_trash").mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(prefix="update-report-", dir=ROOT / "_trash")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root / "home"
        base = self.home / ".claude-switcher"
        base.mkdir(parents=True)
        (base / "env.json").write_text(json.dumps({
            "schema": 1, "proxy_mode": "clash-verge", "proxy_group": "g",
            "country": "US", "timezone": "America/Denver", "locale": "en-US",
            "clash_dir": str(self.root / "nonexistent-clash"),
            "fake_ip_range": "198.18.0.0/16",
        }), encoding="utf-8")
        self.env = dict(os.environ, HOME=str(self.home),
                        CLAUDE_SWITCHER_PYTHON=sys.executable, PYTHONUTF8="1")

    def support(self, *args):
        return subprocess.run(["/bin/bash", str(SCRIPT), "_support", *args],
                              env=self.env, text=True, capture_output=True, timeout=30)

    def report(self, overrides=None, omit=()):
        states = {name: "ok:fixture" for name in NAMES}
        states.update(overrides or {})
        path = self.root / "last-check.txt"
        path.write_text("".join(f"{name}={states[name]}\n" for name in NAMES
                                if name not in omit), encoding="utf-8")
        run = self.support("report", str(path), str(SCRIPT))
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        return json.loads(run.stdout)

    def validate(self, document):
        path = self.root / "report.json"
        path.write_text(json.dumps(document, ensure_ascii=False), encoding="utf-8")
        return self.support("validate-update-report", str(path), str(SCRIPT))

    def test_complete_environment_failure_report_is_valid(self):
        document = self.report({"地区": "config:环境层未就绪"})
        run = self.validate(document)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(document["verdict"], "violated")

    def test_missing_stable_id_is_rejected(self):
        run = self.validate(self.report(omit=("DNS泄露",)))
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("DNS泄露", run.stdout + run.stderr)

    def test_duplicate_id_is_rejected(self):
        document = self.report()
        document["checks"].append(copy.deepcopy(document["checks"][0]))
        run = self.validate(document)
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("重复", run.stdout + run.stderr)

    def test_duplicate_name_with_different_id_is_rejected(self):
        document = self.report()
        duplicate = copy.deepcopy(document["checks"][0])
        duplicate["id"] = "unknown-duplicate-name"
        duplicate["known"] = False
        document["checks"].append(duplicate)
        run = self.validate(document)
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("重复", run.stdout + run.stderr)

    def test_unknown_ok_cannot_verify_all_skipped_stable_checks(self):
        document = self.report({name: "skip:用户已禁用" for name in NAMES})
        document["checks"].append({
            "id": "unknown-future", "name": "未来检查", "known": False,
            "critical": False, "state": "ok", "evidence": "fixture",
        })
        run = self.validate(document)
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("没有已验证", run.stdout + run.stderr)

    def test_wrong_state_or_criticality_is_rejected(self):
        document = self.report()
        document["checks"][0]["state"] = "passed"
        self.assertNotEqual(self.validate(document).returncode, 0)
        document = self.report()
        document["checks"][0]["critical"] = False
        self.assertNotEqual(self.validate(document).returncode, 0)

    def test_inconsistent_or_nonempty_duplicate_summary_is_rejected(self):
        document = self.report()
        document["summary"]["duplicates"] = ["地区"]
        self.assertNotEqual(self.validate(document).returncode, 0)
        document = self.report()
        document["summary"]["passed"] -= 1
        self.assertNotEqual(self.validate(document).returncode, 0)

    def test_wrong_fingerprint_or_core_hash_is_rejected(self):
        document = self.report()
        document["config_fingerprint"] = "0" * 64
        self.assertNotEqual(self.validate(document).returncode, 0)
        document = self.report()
        document["core_sha256"] = "0" * 64
        self.assertNotEqual(self.validate(document).returncode, 0)

    def test_expired_report_is_rejected(self):
        document = self.report()
        past = datetime.datetime.now().astimezone() - datetime.timedelta(minutes=1)
        document["expires_at"] = past.isoformat(timespec="seconds")
        self.assertNotEqual(self.validate(document).returncode, 0)

    def test_regression_includes_config_and_preserves_existing_failure(self):
        baseline = self.root / "baseline.txt"
        baseline.write_text("地区=ok:基线通过\nDNS泄露=fail:既有失败\n", encoding="utf-8")
        document = self.report({"地区": "config:环境层未就绪",
                                "DNS泄露": "fail:既有失败"})
        report_path = self.root / "report.json"
        report_path.write_text(json.dumps(document, ensure_ascii=False), encoding="utf-8")
        run = self.support("update-regression", str(baseline), str(report_path), str(SCRIPT))
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("REGRESSED=地区", run.stdout)
        self.assertIn("NEW_FAILS=地区,DNS泄露", run.stdout)

    def test_empty_baseline_is_not_treated_as_ok(self):
        baseline = self.root / "baseline.txt"
        baseline.write_text("# no checks\n", encoding="utf-8")
        document = self.report()
        report_path = self.root / "report.json"
        report_path.write_text(json.dumps(document, ensure_ascii=False), encoding="utf-8")
        run = self.support("update-regression", str(baseline), str(report_path), str(SCRIPT))
        self.assertNotEqual(run.returncode, 0)


if __name__ == "__main__":
    unittest.main()
