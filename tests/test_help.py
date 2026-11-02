"""help 命令的回归测试。

原来只有一行 usage,21 个命令挤在一起、没有分组也没有解释。现在改成分组说明,
但说明一旦和实际分叉,比没有说明更糟 —— 所以用测试把「help 必须覆盖所有对外
命令」锁住:以后加了命令忘了写说明,这里会直接失败。
"""
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "core" / "claude-switch.sh"

# 只给安装器调用的隐藏入口,不该出现在面向用户的说明里。
HIDDEN = {"write-merge-rules"}


def dispatched_commands():
    """从主分发 case 里取出所有对外命令名。"""
    text = SCRIPT.read_text(encoding="utf-8")
    start = text.index('case "$operation" in')
    end = re.search(r"(?m)^esac", text[start:])
    body = text[start:start + end.start()]
    names = set()
    for line in body.splitlines():
        m = re.match(r"^\s{4}([a-z0-9_|*\-]+)\)", line)
        if not m:
            continue
        names.update(n for n in m.group(1).split("|")
                     if n != "*" and not n.startswith("-"))
    return names


class HelpTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # 用临时 HOME,别把 help 的调用写进用户真实的日志。
        cls.tmp = tempfile.TemporaryDirectory()
        cls.env = dict(os.environ, HOME=cls.tmp.name)
        cls.out = subprocess.run(["/bin/bash", str(SCRIPT), "help"], env=cls.env,
                                 text=True, capture_output=True, timeout=20).stdout

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_help_lists_every_dispatched_command(self):
        missing = sorted(n for n in dispatched_commands()
                         if n not in HIDDEN and n not in self.out)
        self.assertEqual(missing, [], "help 漏掉了这些命令: %s" % missing)

    def test_help_explains_every_result_state(self):
        # 结论含义是用户最需要的一段:ok / warn / config / fail / skip 各是什么。
        for state in ("ok", "warn", "config", "fail", "skip"):
            self.assertRegex(self.out, r"(?m)^\s+%s\s+\S" % state)

    def test_unknown_command_points_to_help(self):
        run = subprocess.run(["/bin/bash", str(SCRIPT), "no-such-command"],
                             env=self.env, text=True, capture_output=True, timeout=20)
        self.assertEqual(run.returncode, 2)
        self.assertIn("help", run.stderr + run.stdout)

    def test_bare_invocation_points_to_help(self):
        run = subprocess.run(["/bin/bash", str(SCRIPT)], env=self.env,
                             text=True, capture_output=True, timeout=20)
        self.assertEqual(run.returncode, 2)
        self.assertIn("help", run.stderr + run.stdout)


if __name__ == "__main__":
    unittest.main()
