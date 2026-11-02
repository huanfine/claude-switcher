"""时区看门狗:目标值必须以 env.json 为准,不能烧死在脚本里。

背景:安装器把 __TZ_TARGET__ 替换成安装当时的目标,之后 set-region / fix 只改
env.json 和系统时区,没人回来改这份副本。看门狗于是守着旧目标,每 5 分钟把
系统时区改回去 —— 用户看到的是「一键修复没生效」,而检查项只看系统时区,
一句话都没提。

夹具把 /etc/localtime 和 /usr/sbin/systemsetup 换成临时路径,不碰真实系统。
"""
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
TEMPLATE = ROOT / "daemons/tz-watchdog.sh"


class TzWatchdogTests(unittest.TestCase):
    def setUp(self):
        (ROOT / "_trash").mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(prefix="tz-watchdog-", dir=ROOT / "_trash")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.home = self.base / "home"
        (self.home / ".claude-switcher").mkdir(parents=True)
        (self.home / "Library/Logs").mkdir(parents=True)

        # 系统时区指针:真实路径只用来比对字符串,目标存不存在无所谓
        self.localtime = self.base / "localtime"
        os.symlink("/var/db/timezone/zoneinfo/America/Los_Angeles", self.localtime)

        self.record = self.base / "systemsetup.log"
        self.fake_systemsetup = self.base / "systemsetup"
        self.fake_systemsetup.write_text(
            "#!/bin/bash\nprintf '%s\\n' \"$*\" >> " + repr(str(self.record)) + "\n",
            encoding="utf-8")
        self.fake_systemsetup.chmod(self.fake_systemsetup.stat().st_mode | stat.S_IXUSR)

    def watchdog(self, baked="Asia/Tokyo"):
        text = TEMPLATE.read_text(encoding="utf-8")
        self.assertIn("__TZ_TARGET__", text)
        self.assertIn("__HOME__", text)
        text = text.replace("__TZ_TARGET__", baked).replace("__HOME__", str(self.home))
        text = text.replace("/usr/sbin/systemsetup", str(self.fake_systemsetup))
        text = text.replace("/etc/localtime", str(self.localtime))
        path = self.base / "tz-watchdog.sh"
        path.write_text(text, encoding="utf-8")
        path.chmod(0o755)
        return path

    def write_env(self, **values):
        payload = {"proxy_mode": "clash-verge", "proxy_group": "G",
                   "country": "US", "timezone": "America/New_York",
                   "locale": "en_US", "schema": 1}
        payload.update(values)
        (self.home / ".claude-switcher/env.json").write_text(
            json.dumps(payload, indent=2), encoding="utf-8")

    def run_watchdog(self, baked="Asia/Tokyo"):
        script = self.watchdog(baked)
        return subprocess.run(["/bin/bash", str(script)], text=True,
                              capture_output=True, timeout=30)

    def applied(self):
        if not self.record.exists():
            return []
        return [line.strip() for line in self.record.read_text(encoding="utf-8").splitlines() if line.strip()]

    # ---- 目标来源 ----

    def test_env_json_wins_over_baked_target(self):
        """env.json 是唯一真相:烧死的那份只是兜底。"""
        self.write_env(timezone="America/New_York")
        self.run_watchdog(baked="Asia/Tokyo")
        self.assertEqual(self.applied(), ["-settimezone America/New_York"])

    def test_baked_target_used_when_env_missing(self):
        """env.json 还没生成(首次安装中途)时退回烧死值,不能什么都不做。"""
        self.run_watchdog(baked="Asia/Tokyo")
        self.assertEqual(self.applied(), ["-settimezone Asia/Tokyo"])

    def test_empty_env_target_falls_back_instead_of_clearing(self):
        """env.json 里时区为空时不能把系统时区改成空 —— 那会把机器搞坏。"""
        self.write_env(timezone="")
        self.run_watchdog(baked="Asia/Tokyo")
        self.assertEqual(self.applied(), ["-settimezone Asia/Tokyo"])

    def test_corrupt_env_does_not_block_guard(self):
        """env.json 坏掉时看门狗仍要工作,不能因为解析失败就放弃纠偏。"""
        (self.home / ".claude-switcher/env.json").write_text("{ not json", encoding="utf-8")
        self.run_watchdog(baked="Asia/Tokyo")
        self.assertEqual(self.applied(), ["-settimezone Asia/Tokyo"])

    # ---- 只在真的偏了才动手 ----

    def test_noop_when_already_on_target(self):
        self.write_env(timezone="America/Los_Angeles")
        self.run_watchdog()
        self.assertEqual(self.applied(), [], "已经对了还去改时区,等于每 5 分钟打扰一次系统")

    def test_logs_the_correction(self):
        """改了什么必须留痕,否则用户查不到「谁动过我的时区」。"""
        self.write_env(timezone="America/New_York")
        self.run_watchdog()
        log = (self.home / "Library/Logs/tz-watchdog.log").read_text(encoding="utf-8")
        self.assertIn("America/Los_Angeles", log)
        self.assertIn("America/New_York", log)


if __name__ == "__main__":
    unittest.main()
