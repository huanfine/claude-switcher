"""macOS menu-bar regression tests. Only fake scripts under _trash are executed."""
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[1]
SCENARIOS = (
    "startup_once", "multi_account_status", "first_use_cd_note", "legacy_status_fallback",
    "invalid_multi_account_status", "warnings_allowed", "skipped_optional_allowed", "settings_round_trip", "local_status_refresh", "fresh_audit", "failed_check",
    "config_only_failure", "config_and_fail", "check_grouping",
    "incomplete_check", "duplicate_check", "duplicate_overwrite", "empty_check",
    "unknown_check_code", "empty_check_code", "nonzero_check", "timeout_check",
    "invalid_status", "nonzero_status", "switch_note_then_failure", "empty_switch",
    "nonzero_switch", "timeout_switch", "busy_guard", "fix_guard", "failed_fix",
    # 健康分:硬性项失败 = 无法启动,分数必须塌下来,不能被提示项稀释
    "health_score_gates_on_hard_failure",
    # 修复失败要说清为什么,不能只丢一句「需手动处理」
    "fix_note_explains_failure",
    # ⚠(没法验证)既不能标成「已修复」,也不能标成红色「需手动」
    "fix_warn_is_note",
    # 可修清单里的每一项都必须有能认领它的 FIX 输出,否则修完没有回执
    "fix_targets_cover_fixable_names",
    "checking_allows_quit", "hide_after_success", "reopen_cancels_hide",
    "window_lifecycle", "termination_guard",
    # 运行期看门狗:通过才起、没通过不起、收到 STOP 要拦、重新检查要撤掉旧的。
    "watch_after_pass", "watch_not_started_on_failure", "watch_blocks_on_stop",
    "watch_restart_drops_old_guard", "watch_stop_kills_process",
    # 拦截记录:界面要能把「上次为什么被停」翻出来
    "incidents_loaded", "incidents_malformed_ignored", "incidents_missing_file",
    # 节点扫描报告 → 界面只更新「更优节点」这一行
    "node_scan_report_updates_row",
    # 换槽位要先扫节点、有更干净的先换线路再切账号;换失败也不能拖死切账号
    "switch_scans_and_applies_better_node", "switch_survives_node_apply_failure",
    "switch_prefers_slot_bound_node", "slot_node_binding_round_trip",
    # 菜单栏品牌图标：两态同一枚盾牌 + Claude 星芒，拦截态额外感叹号徽章
    "menu_bar_brand_icon",
)


@unittest.skipUnless(platform.system() == "Darwin" and shutil.which("swiftc"),
                     "SwiftUI menu-bar tests require macOS and swiftc")
class MenuBarModelTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        trash = PROJECT / "_trash"
        trash.mkdir(exist_ok=True)
        cls.build = tempfile.TemporaryDirectory(prefix="menu-bar-tests-", dir=trash)
        cls.addClassCleanup(cls.build.cleanup)
        cls.binary = Path(cls.build.name) / "MenuBarModelTests"
        result = subprocess.run(
            ["swiftc", "-parse-as-library", "-warnings-as-errors", "-D", "CLAUDE_SWITCHER_TESTS",
             # 新 SDK 的宏插件默认跑在 sandbox 里,受限环境(CI / 沙箱)会
             # sandbox_apply 失败,连带 @State 宏展开不出来,报成
             # 「SwiftUIMacros.StateMacro could not be found」。与安装器同一处理。
             "-Xfrontend", "-disable-sandbox",
             "-target", f"{platform.machine()}-apple-macos13.0",
             "-module-cache-path", str(Path(cls.build.name) / "module-cache"),
             str(PROJECT / "app/main.swift"),
             str(PROJECT / "tests/MenuBarModelTests.swift"),
             "-o", str(cls.binary), "-framework", "SwiftUI", "-framework", "AppKit"],
            cwd=PROJECT, capture_output=True, text=True, timeout=180,
        )
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)


def scenario_test(name):
    def test(self):
        result = subprocess.run(
            [str(self.binary), name], cwd=PROJECT,
            capture_output=True, text=True, timeout=15,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"PASS {name}", result.stdout)
    return test


for scenario in SCENARIOS:
    setattr(MenuBarModelTests, f"test_{scenario}", scenario_test(scenario))
