"""Windows 原生报告入口的静态契约测试。

当前开发机没有 PowerShell,不能执行 Windows 脚本;这里锁住命令接线、
16 个稳定 ID、缺失项显式记录、--json 分支,以及真实集成脚本的 CI 接线。
实际 PS 5.1/7 运行由 tests/windows-report-integration.ps1 在 Windows CI 覆盖。
"""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "windows" / "claude-switch.ps1"
INTEGRATION = ROOT / "tests" / "windows-report-integration.ps1"
CHECKS = ROOT / ".github" / "workflows" / "checks.yml"
IDS = [
    "proxy_core", "tun", "egress_ip", "ip_stability", "timezone", "locale",
    "ipv6", "dns", "webrtc", "bodyguard", "rules", "client_language", "asn",
    "ip_purity", "ecosystem", "better_node",
]


class WindowsReportStaticTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = SCRIPT.read_text(encoding="utf-8-sig")

    def test_report_function_and_commands_are_wired(self):
        self.assertIn("function Get-CheckReport", self.text)
        self.assertIn("'report' {", self.text)
        self.assertIn("'checkdetail' {", self.text)
        self.assertIn("$jsonMode = $args.Count -gt 1 -and [string]$args[1] -eq '--json'", self.text)
        self.assertIn("Get-CheckReport \"$BASE\\last-check.txt\" $PSCommandPath", self.text)
        self.assertIn("last-report.json", self.text)

    def test_all_stable_ids_are_present(self):
        for ident in IDS:
            self.assertIn("id = '%s'" % ident, self.text)

    def test_missing_platform_checks_are_explicit_not_faked(self):
        self.assertIn("missing = @($script:ReportSpecs", self.text)
        self.assertIn("$missingCritical = @($script:ReportSpecs", self.text)
        self.assertIn("if ($duplicates.Count -gt 0 -or $blockers.Count -gt 0) { $verdict = 'violated' }", self.text)
        self.assertIn("'incomplete'", self.text)
        self.assertNotIn("IP纯净度=ok", self.text)
        self.assertNotIn("更优节点=ok", self.text)

    def test_fingerprint_and_unknown_identity_are_stable(self):
        self.assertIn("config_fingerprint = (Get-TextSha256 $material)", self.text)
        self.assertIn("unknown-' + (Get-TextSha256 $name).Substring(0, 12)", self.text)
        self.assertIn("core_sha256 = $coreSha", self.text)
        # PowerShell 7.7 在 [pscustomobject] 字面量里用 @($list) 会抛
        # "Argument types do not match"; List[object] 必须先 ToArray。
        self.assertIn("checks = $checks.ToArray()", self.text)
        self.assertNotIn("checks = @($checks)", self.text)

    def test_windows_integration_script_covers_real_report_contract(self):
        self.assertTrue(INTEGRATION.exists(), "缺少 Windows 报告集成脚本")
        self.assertTrue(
            INTEGRATION.read_bytes().startswith(b"\xef\xbb\xbf"),
            "Windows 报告集成脚本必须保持 UTF-8 BOM",
        )
        integration = INTEGRATION.read_text(encoding="utf-8-sig")
        for marker in (
            "Invoke-Report",
            "-File $core @reportArgs",
            "ConvertFrom-Json",
            "IP纯净度,更优节点",
            "missing_critical",
            "config_fingerprint",
            "all-skip",
            "unknown-",
        ):
            self.assertIn(marker, integration)
        for forbidden in ("Invoke-WebRequest", "curl.exe", "Start-Process"):
            self.assertNotIn(forbidden, integration)

    def test_windows_ci_runs_report_integration_in_both_shells(self):
        workflow = CHECKS.read_text(encoding="utf-8")
        self.assertEqual(
            workflow.count("tests\\windows-report-integration.ps1"),
            2,
            "报告集成测试必须同时接入 Windows PowerShell 5.1 与 pwsh 7",
        )
        self.assertIn("Report integration (Windows PowerShell 5.1)", workflow)
        self.assertIn("Report integration (pwsh 7)", workflow)


if __name__ == "__main__":
    unittest.main()
