"""槽位是否真的隔离了 Claude Code 的状态。

背景:`DATA` 只有 `~/Library/Application Support/Claude`(桌面版),而 Claude
Code 用 `~/.claude/` + `~/.claude.json`。原来槽位只搬前者,于是 A/B/C/D 对
终端里的 claude 来说等于同一个账号 —— 切来切去登录态一份都不变。

这里只测「搬得对不对」:用 _trash 里的假 HOME,不碰真实 ~/.claude,不启动
任何 Claude,不读凭据内容。
"""
import re
from pathlib import Path
import subprocess
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[1]
SOURCE = PROJECT / "core/claude-switch.sh"
TRASH = PROJECT / "_trash"


def function_source(name):
    text = SOURCE.read_text(encoding="utf-8")
    pattern = rf"(?ms)^{re.escape(name)}\(\) \{{\n.*?^\}}"
    match = re.search(pattern, text)
    if match is None:
        raise AssertionError(f"Missing shell function: {name}")
    return match.group(0)


class CliSlotTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        TRASH.mkdir(exist_ok=True)
        cls.archive = function_source("archive_cli")
        cls.restore = function_source("restore_cli")
        cls.has_payload = function_source("cli_slot_has_payload")
        cls.switch = function_source("switch_to")
        cls.valid = function_source("valid_account")

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="cli-slot-", dir=str(TRASH))
        self.addCleanup(self.tmp.cleanup)
        self.fixture = Path(self.tmp.name)
        self.base = self.fixture / "state"
        self.base.mkdir()
        self.data = self.fixture / "live-app"
        self.data.mkdir()
        self.cli_dir = self.fixture / ".claude"
        self.cli_json = self.fixture / ".claude.json"
        self.cli_base = self.base / "cli"

    def run_shell(self, body, *, cli_running="0", functions=None):
        env = {
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": str(self.fixture),
            "BASE": str(self.base),
            "DATA": str(self.data),
            "CLI_DIR": str(self.cli_dir),
            "CLI_JSON": str(self.cli_json),
            "CLI_BASE": str(self.cli_base),
            "FIXTURE": str(self.fixture),
            "CLI_RUNNING": cli_running,
            "LC_ALL": "C",
        }
        parts = [
            "set -u",
            'log() { printf "%s\\n" "$*" >> "$BASE/test.log"; }',
            'copy_tree() { mkdir -p "$2" && cp -R "$1/." "$2/"; }',
            'quit_claude() { return 0; }',
            'open() { :; }',
            'claude_cli_running() { [ "$CLI_RUNNING" = "1" ]; }',
        ]
        parts.extend(functions or [self.has_payload, self.archive, self.restore])
        parts.append(body)
        return subprocess.run(["/bin/bash", "-c", "\n".join(parts)], text=True,
                              capture_output=True, env=env, timeout=60)

    def seed_live(self, tag):
        self.cli_dir.mkdir(exist_ok=True)
        (self.cli_dir / "session").write_text(tag, encoding="utf-8")
        self.cli_json.write_text('{"account":"%s"}' % tag, encoding="utf-8")

    # ---- 归档 ----

    def test_archive_moves_both_paths_into_the_slot(self):
        self.seed_live("A")
        run = self.run_shell('archive_cli A && echo DONE')
        self.assertIn("DONE", run.stdout, run.stderr)
        self.assertFalse(self.cli_dir.exists(), "~/.claude 应被移走,不能留在原位")
        self.assertFalse(self.cli_json.exists(), "~/.claude.json 应被移走")
        slot = self.cli_base / "A"
        self.assertEqual((slot / "home" / "session").read_text(), "A")
        self.assertIn('"A"', (slot / "home.json").read_text())

    def test_archive_refuses_to_clobber_a_pending_stage(self):
        """中断留下的 .new 是唯一副本,不能自动清掉。"""
        (self.cli_base / "A.new").mkdir(parents=True)
        self.seed_live("A")
        run = self.run_shell('archive_cli A || echo REFUSED')
        self.assertIn("REFUSED", run.stdout)
        self.assertTrue((self.cli_base / "A.new").exists(), "暂存目录被删了")
        self.assertTrue(self.cli_dir.exists(), "拒绝之后现场不该被动过")

    def test_archive_tolerates_missing_cli_state(self):
        """从没用过 Claude Code 的机器也要能切,不能因为缺目录就失败。"""
        run = self.run_shell('archive_cli A && echo DONE')
        self.assertIn("DONE", run.stdout, run.stderr)
        self.assertTrue((self.cli_base / "A").is_dir())

    # ---- 还原 ----

    def test_restore_puts_the_slot_state_back(self):
        self.seed_live("A")
        self.run_shell('archive_cli A')
        self.seed_live("B")
        self.run_shell('archive_cli B')
        run = self.run_shell('restore_cli A && echo DONE')
        self.assertIn("DONE", run.stdout, run.stderr)
        self.assertEqual((self.cli_dir / "session").read_text(), "A")
        self.assertIn('"A"', self.cli_json.read_text())

    def test_restore_clears_live_when_slot_has_nothing(self):
        """没存过的槽位必须从空开始,否则接着用上一个账号的登录态 = 没隔离。"""
        self.seed_live("A")
        self.run_shell('archive_cli A')
        # 模拟切到 B:B 没有任何 CLI 存档
        self.seed_live("leftover")
        run = self.run_shell('restore_cli B && echo DONE')
        self.assertIn("DONE", run.stdout, run.stderr)
        self.assertFalse(self.cli_dir.exists(), "上一个账号的 ~/.claude 没清掉")
        self.assertFalse(self.cli_json.exists(), "上一个账号的 ~/.claude.json 没清掉")

    def test_payload_probe_sees_partial_state(self):
        """只有 ~/.claude.json、没有 ~/.claude 也算「有存档」。"""
        (self.cli_base / "A").mkdir(parents=True)
        (self.cli_base / "A" / "home.json").write_text("{}", encoding="utf-8")
        run = self.run_shell('cli_slot_has_payload A && echo YES')
        self.assertIn("YES", run.stdout)
        run = self.run_shell('cli_slot_has_payload B || echo NO')
        self.assertIn("NO", run.stdout)

    # ---- 切换入口 ----

    def test_switch_refuses_while_claude_code_runs(self):
        """终端里开着 claude 时不能切:会把正在写的 ~/.claude 抽走。"""
        run = self.run_shell(
            'switch_to B || echo REFUSED',
            cli_running="1",
            functions=[self.valid, self.switch],
        )
        self.assertIn("REFUSED", run.stdout, run.stderr)
        self.assertIn("Claude Code 正在运行", run.stdout)
        self.assertFalse((self.base / "current").exists(), "被拒绝时不该写 current")


class SlotNodeBindingTests(unittest.TestCase):
    """槽位 → 出口节点绑定。

    核心脚本写、界面直接读盘(VM.loadSlotNodes),两边各自拼同一个路径。
    这里既验读写语义,也钉住「两边不许各改各的」。
    """

    @classmethod
    def setUpClass(cls):
        TRASH.mkdir(exist_ok=True)
        cls.functions = "\n".join(
            function_source(name) for name in
            ("slot_node_show", "slot_node_list", "slot_node_set", "slot_node_clear")
        )

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="slot-node-", dir=str(TRASH))
        self.addCleanup(self.tmp.cleanup)
        self.fixture = Path(self.tmp.name)
        self.slot_node_dir = self.fixture / "slot-node"
        self.scan_file = self.fixture / "node-scan.txt"
        self.scan_file.write_text("SELECTOR=🧠 AI·干净IP\n", encoding="utf-8")

    def shell(self, body):
        parts = [
            "set -u",
            f'SLOT_NODE_DIR="{self.slot_node_dir}"',
            f'NODE_SCAN_FILE="{self.scan_file}"',
            function_source("valid_account"),
            self.functions,
            body,
        ]
        return subprocess.run(
            ["/bin/bash", "-c", "\n".join(parts)], text=True,
            capture_output=True,
            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"},
            timeout=30,
        )

    def test_set_persists_selector_leaf_and_epoch(self):
        run = self.shell('slot_node_set B "鱼9·日本-东京"')
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("OK:账号B 已绑定节点", run.stdout)
        fields = (self.slot_node_dir / "B").read_text(encoding="utf-8").strip().split("\t")
        self.assertEqual(fields[:2], ["🧠 AI·干净IP", "鱼9·日本-东京"])
        self.assertTrue(fields[2].isdigit(), "第三列应是 epoch")

    def test_show_and_list_round_trip(self):
        self.shell('slot_node_set B "鱼9·日本-东京" >/dev/null')
        show = self.shell("slot_node_show B")
        self.assertEqual(show.stdout.strip().split("\t")[1], "鱼9·日本-东京")
        self.assertEqual(self.shell("slot_node_show C").stdout.strip(), "NONE")
        listed = self.shell("slot_node_list").stdout.strip().splitlines()
        self.assertEqual(len(listed), 1)
        self.assertEqual(listed[0].split("\t")[0], "B")

    def test_clear_removes_only_that_slot(self):
        self.shell('slot_node_set A "鱼1" >/dev/null; slot_node_set B "鱼9" >/dev/null')
        run = self.shell("slot_node_clear B; slot_node_list")
        self.assertIn("OK:已解除账号B", run.stdout)
        self.assertEqual([line.split("\t")[0] for line in run.stdout.strip().splitlines()[1:]], ["A"])

    def test_set_rejects_missing_report_and_invalid_slot(self):
        self.scan_file.unlink()
        run = self.shell('slot_node_set B "鱼9" || true')
        self.assertIn("还没有扫描报告", run.stdout)
        self.scan_file.write_text("SELECTOR=🧠 AI·干净IP\n", encoding="utf-8")
        run = self.shell('slot_node_set Z "鱼9" || true')
        self.assertIn("账号必须是 A、B、C 或 D", run.stdout)
        self.assertFalse((self.slot_node_dir / "Z").exists())

    def test_app_reads_the_same_directory_the_core_writes(self):
        """界面不走核心脚本读绑定,路径写死在 Swift 里 —— 必须和脚本对上。"""
        core = SOURCE.read_text(encoding="utf-8")
        app = (PROJECT / "app/main.swift").read_text(encoding="utf-8")
        self.assertIn('SLOT_NODE_DIR="$BASE/slot-node"', core)
        self.assertIn('appendingPathComponent(".claude-switcher/slot-node")', app)
        # 界面只读第二个字段,脚本必须一直把叶子放在第二列。
        self.assertIn("printf '%s\\t%s\\t%s\\n' \"$sel\" \"$leaf\"", core)
        self.assertIn("func loadSlotNodes()", app)


if __name__ == "__main__":
    unittest.main()
