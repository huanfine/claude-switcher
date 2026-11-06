"""「新界面 + 旧核心」升级脚本的回归。

背景:只装 app-only DMG 时，界面会调 node-scan / slot-node，而 v1.7.1 一带的核心
脚本不认识这两个命令，回退出码 2 + 一行老 usage。旧脚本的 self_update 还写死
指向原上游仓库，直接 `update` 永远升不上来，必须走 upgrade-core.sh。

这里用假 HOME + 假 curl 完整跑一遍安装流程，并验证「自检失败要能自动回滚」。
不碰真实 ~/.local/bin、不联网、不启动 Claude。
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[1]
SCRIPT = PROJECT / "scripts/upgrade-core.sh"
CORE = PROJECT / "core/claude-switch.sh"
TRASH = PROJECT / "_trash"

FAKE_CURL = """\
#!/bin/bash
out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
case "$url" in
  *SHA256SUMS) cp "$CS_SERVE_SUMS" "$out" ;;
  *core/claude-switch.sh) cp "$CS_SERVE_CORE" "$out" ;;
  *) exit 22 ;;
esac
"""


class UpgradeCoreTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        TRASH.mkdir(exist_ok=True)

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="upgrade-core-", dir=str(TRASH))
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root / "home"
        (self.home / ".local/bin").mkdir(parents=True)
        (self.home / ".claude-switcher").mkdir(parents=True)
        self.bin = self.home / ".local/bin/claude-switch.sh"
        (self.home / ".claude-switcher/env.json").write_text(json.dumps({
            "schema": 1, "proxy_mode": "clash-verge", "proxy_group": "🧠 AI·干净IP",
            "country": "US", "timezone": "America/Denver", "locale": "en-US",
            "clash_dir": str(self.root / "nonexistent-clash"),
            "fake_ip_range": "198.18.0.0/16",
        }), encoding="utf-8")
        # 一份「旧核心」：不认识 node-scan，头部写着要迁移的环境值。
        self.old = '#!/bin/bash\nPROXY_GROUP="🧠 AI·干净IP"\nexit 2\n'
        self.bin.write_text(self.old, encoding="utf-8")
        self.bin.chmod(0o755)
        self.serve = self.root / "serve"
        self.serve.mkdir()
        self.fakebin = self.root / "bin"
        self.fakebin.mkdir()
        (self.fakebin / "curl").write_text(FAKE_CURL, encoding="utf-8")
        (self.fakebin / "curl").chmod(0o755)

    def serve_core(self, content):
        core = self.serve / "claude-switch.sh"
        core.write_text(content, encoding="utf-8")
        sums = self.serve / "SHA256SUMS"
        digest = hashlib.sha256(core.read_bytes()).hexdigest()
        sums.write_text(f"{digest}  core/claude-switch.sh\n", encoding="utf-8")
        return digest

    def run_upgrade(self):
        env = {
            "PATH": f"{self.fakebin}:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": str(self.home),
            "CS_SERVE_CORE": str(self.serve / "claude-switch.sh"),
            "CS_SERVE_SUMS": str(self.serve / "SHA256SUMS"),
            "LC_ALL": "C",
        }
        return subprocess.run(["/bin/bash", str(SCRIPT)], text=True,
                              capture_output=True, env=env, timeout=90)

    def test_upgrade_installs_verified_core_and_keeps_a_backup(self):
        self.serve_core(CORE.read_text(encoding="utf-8"))
        run = self.run_upgrade()
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("SHA256 一致", run.stdout)
        self.assertEqual(self.bin.read_text(encoding="utf-8"),
                         CORE.read_text(encoding="utf-8"))
        backups = list((self.home / ".local/bin").glob("claude-switch.sh.bak-*"))
        self.assertEqual(len(backups), 1, "必须留一份旧脚本备份")
        self.assertEqual(backups[0].read_text(encoding="utf-8"), self.old)
        self.assertIn("node-scan", run.stdout + run.stderr + self.bin.read_text(encoding="utf-8"))

    def test_checksum_mismatch_writes_nothing(self):
        self.serve_core(CORE.read_text(encoding="utf-8"))
        (self.serve / "SHA256SUMS").write_text(
            "0" * 64 + "  core/claude-switch.sh\n", encoding="utf-8")
        run = self.run_upgrade()
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("SHA256 不符", run.stderr + run.stdout)
        self.assertEqual(self.bin.read_text(encoding="utf-8"), self.old,
                         "校验没过绝不能动已安装的脚本")
        self.assertEqual(list((self.home / ".local/bin").glob("*.bak-*")), [])

    def test_failed_self_check_rolls_back(self):
        # 校验和是真的，但故意把 help 段里的 node-scan 全抠掉：下载/校验/落盘都会过，
        # 最后一步自检失败，此时必须把旧脚本放回去。只改 help 段，命令分发和
        # 语法都保持原样，才能精确命中「自检」这一道。
        text = CORE.read_text(encoding="utf-8")
        head, marker, rest = text.partition("    cat <<'HELP'\n")
        self.assertTrue(marker, "没找到 help 段")
        body, end, tail = rest.partition("\nHELP\n")
        self.assertTrue(end, "没找到 help 段结尾")
        self.assertIn("node-scan", body)
        broken = head + marker + body.replace("node-scan", "node—scan") + end + tail
        self.serve_core(broken)
        run = self.run_upgrade()
        self.assertNotEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("已回滚", run.stderr + run.stdout)
        self.assertEqual(self.bin.read_text(encoding="utf-8"), self.old,
                         "自检失败后现场必须是升级前那份")

    def test_script_has_no_destructive_operations_on_user_dirs(self):
        text = SCRIPT.read_text(encoding="utf-8")
        self.assertNotIn('rm -rf "$HOME"', text)
        self.assertNotIn('rm -rf "$BIN"', text)
        # 只清 mktemp 出来的临时目录
        self.assertIn('rm -rf "$WORK"', text)
        # 顺序：校验和 → 备份 → 落盘 → 自检 → 成功标记
        order = ["WANT=", "cp -p \"$BIN\" \"$BACKUP\"",
                 "cp \"$WORK/claude-switch.sh\" \"$BIN\"", 'HELP_OUT=', "DONE=1"]
        pos = [text.index(token) for token in order]
        self.assertEqual(pos, sorted(pos), "校验/备份必须发生在写入之前")


class UpgradeDocsContractTests(unittest.TestCase):
    """升级命令散落在 4 个地方，任一处手抄错 URL 都会让用户升不上来。"""

    URL = ("https://raw.githubusercontent.com/huanfine/claude-switcher/"
           "main/scripts/upgrade-core.sh")

    def test_every_surface_points_at_the_same_script(self):
        for name in ("README.md", "README.en.md", "app/main.swift", "AGENTS.md"):
            with self.subTest(file=name):
                text = (PROJECT / name).read_text(encoding="utf-8")
                self.assertIn(self.URL, text, f"{name} 里的升级命令与 App 不一致")
        app = (PROJECT / "app/main.swift").read_text(encoding="utf-8")
        self.assertIn("static let upgradeCoreCommand", app)
        self.assertIn("VM.upgradeCoreCommand", app, "复制按钮要用同一个常量")

    def test_installer_kit_carries_the_rescue_script(self):
        packer = (PROJECT / "scripts/package-macos.sh").read_text(encoding="utf-8")
        self.assertIn('cp "$ROOT/scripts/upgrade-core.sh"', packer)
        self.assertIn('cp "$ROOT/SHA256SUMS"', packer)
        # 以前钉死 `"scripts/upgrade-core.sh; do"` 这个结尾,往必备清单里加第二个
        # 脚本就会假失败。改成解析整个 `for ITEM in \ ... ; do` 块再逐项断言。
        kit_loop = re.search(r"for ITEM in \\\n(.*?); do", packer, re.S)
        self.assertIsNotNone(kit_loop, "找不到 kit 必备文件检查循环")
        required = kit_loop.group(1)
        for item in ("scripts/upgrade-core.sh", "scripts/diagnose-fix.sh"):
            with self.subTest(item=item):
                self.assertIn(item, required, f"kit 必备文件检查要覆盖 {item}")

    def test_upgrade_script_fetches_from_this_fork(self):
        text = SCRIPT.read_text(encoding="utf-8")
        self.assertIn("huanfine/claude-switcher", text)
        # 注释里可以解释旧上游的历史，但任何下载 URL 都不能指回去。
        for host in ("codeload.github.com/YOURSJEYO",
                     "raw.githubusercontent.com/YOURSJEYO"):
            with self.subTest(host=host):
                self.assertNotIn(host, text,
                                 "别再指回旧上游，那正是这个报错的根因")


if __name__ == "__main__":
    unittest.main()
