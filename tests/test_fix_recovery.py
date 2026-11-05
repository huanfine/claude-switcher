"""「点了修复没反应」这条链路的回归护栏。

三处一起坏才会出现用户看到的症状:
  1. 核心 fix() 收尾某项判失败就 return 1(哪怕前面都修好了);
  2. App 一见到非零退出就把全部 FIX: 回执清空、phase 打成 .failed;
  3. 诊断包只留 client.log 的命令元数据,看不出卡在哪一步。
这里既钉住修复后的行为,也钉住别再退回旧写法。
"""
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "core/claude-switch.sh"
APP = ROOT / "app/main.swift"
DIAG = ROOT / "scripts/diagnose-fix.sh"


class AppReceiptTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.swift = APP.read_text(encoding="utf-8")

    def test_fix_all_distinguishes_launch_failure_from_partial_success(self):
        self.assertIn('let sawFinish = result.output.contains("FIX:修复流程结束")', self.swift)
        self.assertIn("guard result.succeeded || sawFinish else {", self.swift)
        self.assertIn("self.completeFix(succeeded: result.succeeded)", self.swift)
        self.assertIn("private func completeFix(succeeded: Bool)", self.swift)

    def test_partial_failure_does_not_wipe_receipts(self):
        """completeFix 里不能出现「清空 fixStates / 置 .failed」的旧做法。"""
        body = self.swift.split("private func completeFix(succeeded: Bool) {", 1)[1]
        body = body.split("\n    }\n", 1)[0]
        self.assertNotIn("fixStates = [:]", body)
        self.assertNotIn("phase = .failed", body)
        self.assertIn("phase = .ready", body)

    def test_full_output_is_replayed_and_persisted(self):
        self.assertIn("Self.persistFixOutput(result.output)", self.swift)
        self.assertIn('result.output.split(whereSeparator: \\.isNewline)', self.swift)
        self.assertIn('appendingPathComponent("Logs/claude-switcher"', self.swift)
        self.assertIn('appendingPathComponent("last-fix.log")', self.swift)
        self.assertIn("0o600", self.swift)

    def test_streaming_callback_runs_on_main_queue(self):
        self.assertIn("DispatchQueue.main.async { self?.applyFixLine(line) }", self.swift)

    def test_process_gets_explicit_path(self):
        self.assertIn("p.environment = Self.coreProcessEnvironment()", self.swift)
        helper = self.swift.split("private static func coreProcessEnvironment()", 1)[1]
        helper = helper.split("\n    }", 1)[0]
        for directory in ("/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin",
                          "/usr/sbin", "/sbin"):
            self.assertIn('"' + directory + '"', helper)
        self.assertIn("ProcessInfo.processInfo.environment", helper)

    def test_launch_failure_hint_is_actionable(self):
        hint = self.swift.split("private static func fixLaunchFailureHint", 1)[1]
        hint = hint.split("\n    }", 1)[0]
        self.assertIn("退出码 2", hint)
        self.assertIn("xcode-select --install", hint)
        self.assertIn("diagnose-fix.sh", hint)


class CorePythonResolutionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sh = CORE.read_text(encoding="utf-8")

    def test_resolver_is_defined_before_support_dispatch(self):
        self.assertLess(self.sh.index("resolve_python()"),
                        self.sh.index('if [ "${1:-}" = "_support" ]; then'))

    def test_resolver_respects_explicit_injection(self):
        self.assertIn('if [ -z "${CLAUDE_SWITCHER_PYTHON:-}" ]; then', self.sh)
        self.assertIn("export CLAUDE_SWITCHER_PYTHON", self.sh)

    def test_no_bare_python3_invocation_left(self):
        """裸 python3 会让 GUI 的极简 PATH 再次把 fix 打死在 0 秒。"""
        offenders = []
        for number, line in enumerate(self.sh.splitlines(), 1):
            stripped = line.strip()
            if stripped.startswith("#"):
                continue
            if "CLAUDE_SWITCHER_PYTHON" in line or "command -v python3" in line:
                continue
            if re.search(r"(?:^|[;&|]\s*)python3\s", line):
                offenders.append(f"{number}: {stripped}")
        self.assertEqual([], offenders, "核心脚本里还有裸 python3 调用: " + "; ".join(offenders))

    def test_fix_finish_marker_is_unique(self):
        """App 靠这唯一一句判断「流程跑完了」,多一处就会把前置失败误判成部分成功。"""
        fix = self.sh.split("\nfix() {", 1)[1].split("\n}\n", 1)[0]
        self.assertIn("FIX:修复流程结束", fix)
        self.assertEqual(fix.count("FIX:修复流程结束"), 1)

    def test_fix_is_self_contained_for_trimmed_fixtures(self):
        """test_webrtc_rules 只抽 fix() 函数体出来跑,里面不能依赖顶层函数。"""
        fix = self.sh.split("\nfix() {", 1)[1].split("\n}\n", 1)[0]
        self.assertNotIn("python_works", fix)
        self.assertNotIn("resolve_python", fix)
        self.assertIn("xcode-select --install", fix)
        self.assertIn("修复在前置校验阶段退出", fix)

    def test_policy_preflight_says_nothing_was_touched(self):
        self.assertIn("修复在前置校验阶段退出", self.sh)
        self.assertIn("diagnose-fix.sh", self.sh)

    def test_support_runs_with_minimal_path(self):
        """模拟 Finder 启动的 App:极简 PATH、没有显式注入解释器。"""
        with tempfile.TemporaryDirectory(prefix="fix-recovery-", dir=ROOT / "_trash") as tmp:
            home = Path(tmp) / "home"
            home.mkdir()
            env = {"HOME": str(home), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
            run = subprocess.run(["/bin/bash", str(CORE), "_support", "config"],
                                 text=True, capture_output=True, env=env, timeout=15)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("logging=", run.stdout)

    def test_support_runs_with_no_python_on_path(self):
        """PATH 上完全没有 python3 时,靠绝对路径兜底。"""
        with tempfile.TemporaryDirectory(prefix="fix-recovery-", dir=ROOT / "_trash") as tmp:
            home = Path(tmp) / "home"
            home.mkdir()
            env = {"HOME": str(home), "PATH": "/nonexistent-claude-switcher-bin"}
            run = subprocess.run(["/bin/bash", str(CORE), "_support", "config"],
                                 text=True, capture_output=True, env=env, timeout=15)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("logging=", run.stdout)


class DiagnoseScriptTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = DIAG.read_text(encoding="utf-8")

    def test_is_executable_and_syntax_clean(self):
        self.assertTrue(DIAG.stat().st_mode & stat.S_IXUSR)
        run = subprocess.run(["/bin/bash", "-n", str(DIAG)], text=True,
                             capture_output=True, timeout=10)
        self.assertEqual(run.returncode, 0, run.stderr)

    def test_raw_url_points_at_this_repo(self):
        self.assertIn("https://raw.githubusercontent.com/huanfine/claude-switcher/main/"
                      "scripts/diagnose-fix.sh", self.text)
        self.assertIn("upgrade-core.sh", self.text)

    def test_captures_full_fix_output_and_exit_code(self):
        self.assertIn('"$CORE" fix 2>&1', self.text)
        self.assertIn("FIX_RC=$?", self.text)
        self.assertIn('main 2>&1 | scrub | tee "$OUT"', self.text)

    def test_scrubs_ip_before_writing(self):
        self.assertIn("s/([0-9]{1,3}\\.){3}[0-9]{1,3}/[IP]/g", self.text)
        self.assertNotIn("里面不含 IP、凭据、账号内容", self.text)


if __name__ == "__main__":
    unittest.main()
